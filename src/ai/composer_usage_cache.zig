//! Cache immutable transcript estimates and a validated provider input baseline.
const std = @import("std");
const History = @import("wire_history.zig").History;
const Config = @import("provider_config.zig").ProviderConfig;
const usage = @import("context_usage.zig");
const budget = @import("local_text_request.zig");
pub const Summary = struct {
    tokens: usize = 0,
    reserved_image_tokens: usize = 0,
    can_compact: bool = false,
    measured_tokens: ?usize = null,
    added_tokens: usize = 0,
    estimated: bool = true,
};
pub const Cache = struct {
    key: ?u64 = null,
    value: Summary = .{},
    computations: usize = 0,
    pub fn read(self: *Cache, history: *History, selected: ?Config) Summary {
        return self.readWithFixed(history, selected, .{});
    }
    /// fixed is already part of provider input; never add it twice.
    pub fn readWithFixed(self: *Cache, history: *History, selected: ?Config, fixed: usage.Fixed) Summary {
        const model_key = if (selected) |model| usage.modelKey(model) else 0;
        if (history.usage) |baseline| {
            if (selected == null or baseline.model_key != model_key or baseline.sample.fixed.fingerprint != fixed.fingerprint) history.usage = null;
        }
        var hash = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hash, .{ history.revision, model_key, fixed.fingerprint, fixed.tokens(), history.usage });
        const key = hash.final();
        const cacheable = history.revision != 0 or history.messages.len == 0;
        if (cacheable and self.key == key) return self.value;
        if (history.usage) |baseline| if (!baseline.sample.matches(history.messages)) {
            history.usage = null;
        };
        const start = if (history.usage) |baseline| baseline.sample.prefix_count else 0;
        const messages = history.messages[start..];
        var bytes: usize = 0;
        for (messages) |message| {
            bytes +|= message.content.len +| 32;
            if (message.tool_call_id) |id| bytes +|= id.len;
            for (message.tool_calls) |call| bytes +|= call.id.len +| call.name.len +| call.arguments.len +| 64;
        }
        var reserved: usize = 0;
        const added = if (selected) |model| estimate: {
            const request = model.chatRequest(.{ .model = model.model, .system = "", .messages = messages, .tool_images = model.vision });
            if (!@import("image_budget.zig").supports(model.model)) reserved = @import("image_budget.zig").validate(request) catch 0;
            break :estimate budget.inputTokens(request) catch budget.textTokens(bytes);
        } else budget.textTokens(bytes);
        const measured = if (history.usage) |baseline| baseline.sample.input_tokens else null;
        self.value = .{
            .tokens = (measured orelse fixed.tokens()) +| added,
            .reserved_image_tokens = reserved,
            .can_compact = @import("context_compaction.zig").cutoff(history.messages) != null,
            .measured_tokens = measured,
            .added_tokens = added,
            .estimated = measured == null or messages.len != 0,
        };
        self.key = if (cacheable) key else null;
        self.computations += 1;
        return self.value;
    }
};
test "material composer usage cache invalidates equal-length history replacements and model changes" {
    const a = std.testing.allocator;
    var history = try History.copy(a, &.{ .{ .role = .user, .content = "one" }, .{ .role = .assistant, .content = "answer" } }, "");
    defer history.deinit();
    var cache: Cache = .{};
    const first = cache.read(&history, null);
    _ = cache.read(&history, null);
    try std.testing.expectEqual(@as(usize, 1), cache.computations);
    var replacement = try History.copy(a, &.{ .{ .role = .user, .content = "a much longer replacement" }, .{ .role = .assistant, .content = "answer" } }, "");
    defer replacement.deinit();
    try std.testing.expect(cache.read(&replacement, null).tokens > first.tokens);
    const model: Config = .{ .kind = .openai_compat, .endpoint = "http://127.0.0.1:9", .model = "fixture", .auth = .none };
    _ = cache.read(&replacement, model);
    try std.testing.expectEqual(@as(usize, 3), cache.computations);
}

const test_model: Config = .{ .kind = .openai_compat, .endpoint = "http://127.0.0.1:9", .model = "fixture", .auth = .none };
const test_request: @import("provider.zig").ChatRequest = .{ .model = "fixture", .system = "fixed system prompt", .messages = &.{.{ .content = "question" }}, .tools = &.{.{ .tool = .read_terminal, .session_ids = &.{101} }} };
fn measuredHistory(final_text: []const u8) !History {
    var history = try History.copy(std.testing.allocator, test_request.messages, final_text);
    history.usage = .{ .sample = try usage.Sample.capture(test_request, 12000), .model_key = usage.modelKey(test_model) };
    return history;
}
test "context usage uses measured input plus only retained new content without duplicating fixed costs" {
    var history = try measuredHistory("answer");
    defer history.deinit();
    var cache: Cache = .{};
    const fixed = try usage.Fixed.capture(test_request);
    const result = cache.readWithFixed(&history, test_model, fixed);
    const tail = try budget.inputTokens(test_model.chatRequest(.{ .model = "fixture", .system = "", .messages = history.messages[1..] }));
    try std.testing.expectEqual(@as(?usize, 12000), result.measured_tokens);
    try std.testing.expectEqual(12000 + tail, result.tokens);
    try std.testing.expectEqual(tail, result.added_tokens);
    try std.testing.expect(result.estimated);
    const computations = cache.computations;
    _ = cache.readWithFixed(&history, test_model, fixed);
    try std.testing.expectEqual(computations, cache.computations);
}
test "context usage unchanged measured prefix is exact and prefix edits cannot reuse its measurement" {
    var history = try measuredHistory("");
    defer history.deinit();
    var cache: Cache = .{};
    const fixed = try usage.Fixed.capture(test_request);
    const result = cache.readWithFixed(&history, test_model, fixed);
    try std.testing.expectEqual(@as(usize, 12000), result.tokens);
    try std.testing.expect(!result.estimated);
    var edited = (try history.editedUser(std.testing.allocator, 0, "question", "changed!\n")).?;
    defer edited.deinit();
    try std.testing.expect(edited.usage == null);
    // Even an accidentally carried measurement must fail the prefix check.
    edited.usage = history.usage;
    const changed = cache.readWithFixed(&edited, test_model, fixed);
    try std.testing.expect(changed.measured_tokens == null);
    try std.testing.expect(edited.usage == null);
    try std.testing.expect(changed.tokens < 12000);
}
test "context usage replacement and compaction drop the old measurement" {
    var history = try measuredHistory("answer");
    defer history.deinit();
    var replacement = try History.copy(std.testing.allocator, history.messages, "");
    defer replacement.deinit();
    var compacted = try History.copy(std.testing.allocator, &.{.{ .content = "summary" }}, "");
    defer compacted.deinit();
    try std.testing.expect(replacement.usage == null);
    compacted.usage = history.usage;
    var cache: Cache = .{};
    try std.testing.expect(cache.readWithFixed(&compacted, test_model, try usage.Fixed.capture(test_request)).measured_tokens == null);
}
test "context usage changing model or endpoint invalidates permanently including switching back" {
    for (0..2) |change| {
        var history = try measuredHistory("answer");
        defer history.deinit();
        var cache: Cache = .{};
        const fixed = try usage.Fixed.capture(test_request);
        var other = test_model;
        if (change == 0) other.model = "other-model" else other.endpoint = "http://127.0.0.1:10";
        try std.testing.expect(cache.readWithFixed(&history, other, fixed).measured_tokens == null);
        try std.testing.expect(history.usage == null);
        try std.testing.expect(cache.readWithFixed(&history, test_model, fixed).measured_tokens == null);
    }
}
test "context usage changed system or equal length tool schema invalidates measurement" {
    for (0..2) |change| {
        var history = try measuredHistory("answer");
        defer history.deinit();
        var cache: Cache = .{};
        var changed = test_request;
        if (change == 0) changed.system = "other system prompt" else changed.tools = &.{.{ .tool = .read_terminal, .session_ids = &.{102} }};
        const result = cache.readWithFixed(&history, test_model, try usage.Fixed.capture(changed));
        try std.testing.expect(result.measured_tokens == null);
        try std.testing.expect(history.usage == null);
    }
}
test "context usage missing measurement estimates complete input including fixed costs" {
    var history = try History.copy(std.testing.allocator, test_request.messages, "answer");
    defer history.deinit();
    var cache: Cache = .{};
    const result = cache.readWithFixed(&history, test_model, try usage.Fixed.capture(test_request));
    var request = test_request;
    request.messages = history.messages;
    try std.testing.expectEqual(try budget.inputTokens(request), result.tokens);
    try std.testing.expect(result.measured_tokens == null);
    try std.testing.expect(result.estimated);
}
