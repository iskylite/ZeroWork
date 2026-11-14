//! Worker-owned accounting; the UI only copies a fixed-size numeric snapshot.
const std = @import("std");
const provider = @import("provider.zig");
const usage = @import("context_usage.zig");
const budget = @import("local_text_request.zig");
pub const Snapshot = struct {
    fixed: usage.Fixed,
    summary: @import("composer_usage_cache.zig").Summary,
};
pub const Tracker = struct {
    baseline: ?usage.Sample = null,
    snapshot: ?Snapshot = null,
    response_bytes: usize = 0,

    /// Called only by the worker at request/transcript boundaries. Full prefix
    /// validation and token estimation never run under the mailbox lock.
    pub fn update(self: *Tracker, request: provider.ChatRequest, measured: ?u32, response_bytes: usize) !Snapshot {
        const fixed = try usage.Fixed.capture(request);
        if (measured) |tokens| {
            if (tokens > 0) self.baseline = try usage.Sample.capture(request, tokens);
        }
        if (self.baseline) |sample| {
            if (sample.fixed.fingerprint != fixed.fingerprint or !sample.matches(request.messages)) self.baseline = null;
        }
        var tail = request;
        tail.system = "";
        tail.tools = &.{};
        const start = if (self.baseline) |sample| sample.prefix_count else 0;
        tail.messages = request.messages[start..];
        const messages = try budget.messageTextTokens(tail.messages);
        const images = try @import("image_budget.zig").validate(tail);
        const added = messages +| images;
        const reserved = if (!@import("image_budget.zig").supports(request.model)) images else 0;
        const input = if (self.baseline) |sample| sample.input_tokens else fixed.tokens();
        self.response_bytes = response_bytes;
        self.snapshot = .{ .fixed = fixed, .summary = .{
            .tokens = input +| added,
            .measured_tokens = if (self.baseline) |sample| sample.input_tokens else null,
            .measured_sources = if (self.baseline) |sample| sample.sources else null,
            .added_tokens = added,
            .reserved_image_tokens = reserved,
            .image_tokens = images,
            .estimated = self.baseline == null or tail.messages.len != 0,
        } };
        return self.current().?;
    }
    pub fn appendText(self: *Tracker, bytes: usize) ?Snapshot {
        self.response_bytes +|= bytes;
        return self.current();
    }
    pub fn current(self: *const Tracker) ?Snapshot {
        var value = self.snapshot orelse return null;
        // Same framing as retained assistant messages, without borrowing bytes.
        const tokens = if (self.response_bytes == 0) 0 else budget.textTokens(self.response_bytes +| 32);
        value.summary.tokens +|= tokens;
        value.summary.added_tokens +|= tokens;
        value.summary.estimated = value.summary.estimated or tokens != 0;
        return value;
    }
};

pub const Mailbox = struct {
    mutex: std.atomic.Mutex = .unlocked,
    turn: u64 = 0,
    value: ?Snapshot = null,
    fn lock(self: *Mailbox) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    /// Reset only before starting a joined worker's next turn.
    pub fn reset(self: *Mailbox, turn: u64) void {
        self.lock();
        defer self.mutex.unlock();
        self.turn = turn;
        self.value = null;
    }
    pub fn publish(self: *Mailbox, turn: u64, value: Snapshot) void {
        self.lock();
        defer self.mutex.unlock();
        if (self.turn == turn) self.value = value;
    }
    pub fn read(self: *Mailbox, turn: u64) ?Snapshot {
        self.lock();
        defer self.mutex.unlock();
        return if (self.turn == turn) self.value else null;
    }
};

const test_request: provider.ChatRequest = .{ .model = "fixture", .system = "system prompt", .messages = &.{.{ .content = "检查当前终端" }}, .tools = &.{.{ .tool = .run_command, .session_ids = &.{101} }} };
test "live context usage uses each request measurement and counts retained tool arguments and output once" {
    var tracker: Tracker = .{};
    const initial = try tracker.update(test_request, null, 0);
    try std.testing.expectEqual(try budget.inputTokens(test_request), initial.summary.tokens);
    try std.testing.expect(initial.summary.estimated);
    const measured = try tracker.update(test_request, 125494, 0);
    try std.testing.expectEqual(@as(usize, 125494), measured.summary.tokens);
    try std.testing.expect(!measured.summary.estimated);
    const generated = tracker.appendText(100).?;
    try std.testing.expectEqual(125494 + budget.textTokens(132), generated.summary.tokens);
    const large_output = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(large_output);
    @memset(large_output, 'x');
    const messages = [_]provider.Message{ test_request.messages[0], .{ .role = .assistant, .content = "done", .tool_calls = &.{.{ .id = "call1", .name = "run_command", .arguments = "{\"command\":\"printf DONE\"}" }} }, .{ .role = .tool, .content = large_output, .tool_call_id = "call1" } };
    var next = test_request;
    next.messages = &messages;
    const before_next_response = try tracker.update(next, null, 0);
    var tail = next;
    tail.messages = messages[1..];
    tail.system = "";
    tail.tools = &.{};
    try std.testing.expectEqual(125494 + try budget.inputTokens(tail), before_next_response.summary.tokens);
    try std.testing.expect(before_next_response.summary.tokens > generated.summary.tokens);
    const next_measured = try tracker.update(next, 150000, 0);
    try std.testing.expectEqual(@as(usize, 150000), next_measured.summary.tokens);
    try std.testing.expectEqual(@as(usize, 0), next_measured.summary.added_tokens);
    try std.testing.expect(!next_measured.summary.estimated);
}

test "live context usage retry discards failed output and compaction invalidates the measured prefix" {
    var tracker: Tracker = .{};
    _ = try tracker.update(test_request, 120000, 0);
    _ = tracker.appendText(4096);
    const retry = try tracker.update(test_request, null, 0);
    try std.testing.expectEqual(@as(usize, 120000), retry.summary.tokens);
    var compacted = test_request;
    compacted.messages = &.{.{ .content = "summary" }};
    const compact = try tracker.update(compacted, null, 0);
    try std.testing.expect(compact.summary.measured_tokens == null);
    try std.testing.expectEqual(try budget.inputTokens(compacted), compact.summary.tokens);
    _ = try tracker.update(test_request, 120000, 0);
    var changed = test_request;
    changed.system = "different system";
    const fixed_changed = try tracker.update(changed, null, 0);
    try std.testing.expect(fixed_changed.summary.measured_tokens == null);
    try std.testing.expectEqual(try budget.inputTokens(changed), fixed_changed.summary.tokens);
}

test "live context usage mailbox rejects previous turns and UI reads never inspect the transcript" {
    var mailbox: Mailbox = .{};
    mailbox.reset(1);
    var tracker: Tracker = .{};
    const old = try tracker.update(test_request, 120000, 0);
    mailbox.publish(1, old);
    try std.testing.expectEqualDeep(old, mailbox.read(1).?);
    mailbox.reset(2);
    mailbox.publish(1, old);
    try std.testing.expect(mailbox.read(2) == null);
    const current = try tracker.update(test_request, 130000, 0);
    mailbox.publish(2, current);
    tracker = .{}; // Consumer has no tracker, request bytes or allocations.
    const started = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    for (0..100000) |_| try std.testing.expectEqual(@as(usize, 130000), mailbox.read(2).?.summary.tokens);
    const elapsed = started.durationTo(std.Io.Clock.Timestamp.now(std.testing.io, .awake)).raw.toMicroseconds();
    std.debug.print("LIVE_CONTEXT_UI_READS count=100000 elapsed_us={d}\n", .{elapsed});
    try std.testing.expect(mailbox.read(1) == null);
}

test "live context usage concurrent mailbox publishes complete snapshots" {
    const Producer = struct {
        mailbox: *Mailbox,
        done: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            defer self.done.store(true, .release);
            for (1..10001) |i| self.mailbox.publish(7, .{ .fixed = .{}, .summary = .{ .tokens = i * 3, .measured_tokens = i, .added_tokens = i * 2 } });
        }
    };
    var mailbox: Mailbox = .{};
    mailbox.reset(7);
    var producer: Producer = .{ .mailbox = &mailbox };
    const thread = try std.Thread.spawn(.{}, Producer.run, .{&producer});
    defer thread.join();
    while (!producer.done.load(.acquire)) {
        if (mailbox.read(7)) |snapshot| try std.testing.expectEqual(snapshot.summary.measured_tokens.? + snapshot.summary.added_tokens, snapshot.summary.tokens);
    }
    try std.testing.expectEqual(@as(usize, 30000), mailbox.read(7).?.summary.tokens);
}
