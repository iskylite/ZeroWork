//! Estimates depend on an immutable owned transcript and model settings, not
//! the display frame, draft keystroke, or caret/animation tick.
const std = @import("std");
const History = @import("wire_history.zig").History;
const Config = @import("provider_config.zig").ProviderConfig;
pub const Summary = struct { tokens: usize, reserved_image_tokens: usize, can_compact: bool };
pub const Cache = struct {
    key: ?u64 = null,
    value: Summary = .{ .tokens = 0, .reserved_image_tokens = 0, .can_compact = false },
    computations: usize = 0,
    pub fn read(self: *Cache, history: *const History, selected: ?Config) Summary {
        var hash = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hash, history.revision);
        if (selected) |model| {
            hash.update(model.model);
            std.hash.autoHash(&hash, .{ model.kind, model.vision, model.image_token_reservation, model.image_token_max_width, model.image_token_max_height });
        }
        const key = hash.final();
        // Borrowed test/integration transcripts have no immutable revision.
        const cacheable = history.revision != 0 or history.messages.len == 0;
        if (cacheable and self.key == key) return self.value;
        var bytes: usize = 0;
        for (history.messages) |message| {
            bytes +|= message.content.len;
            for (message.tool_calls) |call| bytes +|= call.name.len +| call.arguments.len;
        }
        var reserved: usize = 0;
        const tokens = if (selected) |model| estimate: {
            const request = model.chatRequest(.{ .model = model.model, .system = "", .messages = history.messages, .tool_images = model.vision });
            if (!@import("image_budget.zig").supports(model.model)) reserved = @import("image_budget.zig").validate(request) catch 0;
            break :estimate @import("local_text_request.zig").inputTokens(request) catch ((bytes +| 3) / 4);
        } else (bytes +| 3) / 4;
        self.value = .{ .tokens = tokens, .reserved_image_tokens = reserved, .can_compact = @import("context_compaction.zig").cutoff(history.messages) != null };
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
