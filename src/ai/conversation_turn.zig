//! A user submission owns its display steps and exact model context boundaries.
const std = @import("std");
const wire = @import("wire_history.zig");
const events = @import("step_events.zig");
const identity = @import("../host/identity.zig");
pub const HostNotice = struct {
    revision: u64,
    target: identity.SessionHandle,
    execution_id: ?identity.ExecutionId = null,
    text: []u8,
};
pub const Turn = struct {
    id: u64 = 0,
    task_id: ?identity.TaskId = null,
    sent_at_ms: u64 = 0,
    ended_at_ms: ?u64 = null,
    started_mono_ms: u64 = 0,
    elapsed_ms: u64 = 0,
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    before: wire.History = .{},
    after: wire.History = .{},
    answer: []u8 = &.{},
    thinking: std.ArrayList(u8) = .empty,
    thinking_started_ms: ?u64 = null,
    thinking_ended_ms: ?u64 = null,
    thinking_expanded: bool = false,
    thinking_scroll: ?*ThinkingScroll = null,
    steps: std.ArrayList(events.Step) = .empty,
    host_notices: std.ArrayList(HostNotice) = .empty,
    pub fn deinit(self: *Turn, a: std.mem.Allocator) void {
        self.before.deinit();
        self.after.deinit();
        a.free(self.answer);
        self.thinking.deinit(a);
        if (self.thinking_scroll) |scroll| scroll.release();
        for (self.steps.items) |*step| step.deinit(a);
        self.steps.deinit(a);
        for (self.host_notices.items) |notice| a.free(notice.text);
        self.host_notices.deinit(a);
        self.* = .{};
    }
    pub fn clone(self: *const Turn, a: std.mem.Allocator) !Turn {
        var result: Turn = .{ .id = self.id, .task_id = self.task_id, .sent_at_ms = self.sent_at_ms, .ended_at_ms = self.ended_at_ms, .started_mono_ms = self.started_mono_ms, .elapsed_ms = self.elapsed_ms, .input_tokens = self.input_tokens, .output_tokens = self.output_tokens, .thinking_started_ms = self.thinking_started_ms, .thinking_ended_ms = self.thinking_ended_ms, .thinking_expanded = self.thinking_expanded };
        errdefer result.deinit(a);
        result.before = try wire.History.copy(a, self.before.messages, "");
        result.after = try wire.History.copy(a, self.after.messages, "");
        result.answer = try a.dupe(u8, self.answer);
        try result.thinking.appendSlice(a, self.thinking.items);
        if (self.thinking_scroll) |scroll| {
            result.thinking_scroll = try ThinkingScroll.create(a);
            result.thinking_scroll.?.offset = scroll.offset;
            result.thinking_scroll.?.following = scroll.following;
        }
        for (self.steps.items) |step| {
            var copy = try step.clone(a);
            result.steps.append(a, copy) catch |err| {
                copy.deinit(a);
                return err;
            };
        }
        for (self.host_notices.items) |notice| {
            const text = try a.dupe(u8, notice.text);
            errdefer a.free(text);
            try result.host_notices.append(a, .{ .revision = notice.revision, .target = notice.target, .execution_id = notice.execution_id, .text = text });
        }
        return result;
    }
};

/// Kept stable while a streaming turn moves into history or its view rebuilds.
pub const ThinkingScroll = struct {
    allocator: std.mem.Allocator,
    references: usize = 1,
    offset: f32 = 0,
    following: bool = true,

    pub fn create(a: std.mem.Allocator) !*ThinkingScroll {
        const self = try a.create(ThinkingScroll);
        self.* = .{ .allocator = a };
        return self;
    }
    pub fn retain(self: *ThinkingScroll) void {
        self.references += 1;
    }
    pub fn release(self: *ThinkingScroll) void {
        self.references -= 1;
        if (self.references == 0) self.allocator.destroy(self);
    }
};

test "host input handoff remains an independent fact when a turn moves to history" {
    const a = std.testing.allocator;
    const task = identity.TaskId.generate();
    const target: identity.SessionHandle = .{ .session_id = @fromBackingInt(42), .generation = 3 };
    const execution_id = identity.ExecutionId.generate();
    var original: Turn = .{ .id = 9, .task_id = task };
    try original.host_notices.append(a, .{ .revision = 17, .target = target, .execution_id = execution_id, .text = try a.dupe(u8, "用户接管；命令与AI回合继续") });
    var archived = try original.clone(a);
    defer archived.deinit(a);
    original.deinit(a);
    try std.testing.expect(archived.task_id.?.eql(task));
    try std.testing.expect(archived.ended_at_ms == null);
    try std.testing.expectEqual(@as(usize, 0), archived.steps.items.len);
    try std.testing.expectEqual(@as(usize, 0), archived.after.messages.len);
    const notice = archived.host_notices.items[0];
    try std.testing.expect(notice.target.eql(target) and notice.execution_id.?.eql(execution_id));
    try std.testing.expectEqual(@as(u64, 17), notice.revision);
    try std.testing.expectEqualStrings("用户接管；命令与AI回合继续", notice.text);
}
