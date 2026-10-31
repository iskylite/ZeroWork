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
/// A segment owns one uninterrupted provider channel, never a whole turn.
/// Stable allocation preserves disclosure/scroll state while the timeline grows.
pub const Segment = struct {
    allocator: std.mem.Allocator,
    references: usize = 1,
    text: std.ArrayList(u8) = .empty,
    started_ms: u64,
    ended_ms: ?u64 = null,
    expanded: bool = false,
    scroll: ?*ThinkingScroll = null,
    pub fn retain(self: *Segment) void {
        self.references += 1;
    }
    pub fn release(self: *Segment) void {
        self.references -= 1;
        if (self.references != 0) return;
        self.text.deinit(self.allocator);
        if (self.scroll) |scroll| scroll.release();
        self.allocator.destroy(self);
    }
    fn clone(self: *const Segment, a: std.mem.Allocator) !*Segment {
        const result = try a.create(Segment);
        result.* = .{ .allocator = a, .started_ms = self.started_ms, .ended_ms = self.ended_ms, .expanded = self.expanded };
        errdefer result.release();
        try result.text.appendSlice(a, self.text.items);
        if (self.scroll) |scroll| {
            result.scroll = try ThinkingScroll.create(a);
            result.scroll.?.offset = scroll.offset;
            result.scroll.?.following = scroll.following;
        }
        return result;
    }
};
pub const TimelineItem = union(enum) {
    message: *Segment,
    thinking: *Segment,
    tool: usize,
    notice: usize,
    fn deinit(self: TimelineItem, a: std.mem.Allocator) void {
        _ = a;
        switch (self) {
            .message, .thinking => |segment| segment.release(),
            .tool, .notice => {},
        }
    }
    fn clone(self: TimelineItem, a: std.mem.Allocator) !TimelineItem {
        return switch (self) {
            .message => |segment| .{ .message = try segment.clone(a) },
            .thinking => |segment| .{ .thinking = try segment.clone(a) },
            .tool, .notice => self,
        };
    }
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
    timeline: std.ArrayList(TimelineItem) = .empty,
    open_segment: ?usize = null,
    round_timeline_len: usize = 0,
    round_steps_len: usize = 0,
    round_thinking_offset: usize = 0,
    prose: std.ArrayList(u8) = .empty,
    round_text_offset: usize = 0,
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
        for (self.timeline.items) |item| item.deinit(a);
        self.timeline.deinit(a);
        self.prose.deinit(a);
        self.thinking.deinit(a);
        if (self.thinking_scroll) |scroll| scroll.release();
        for (self.steps.items) |*step| step.deinit(a);
        self.steps.deinit(a);
        for (self.host_notices.items) |notice| a.free(notice.text);
        self.host_notices.deinit(a);
        self.* = .{};
    }
    pub fn finishSegment(self: *Turn, at_ms: u64) void {
        if (self.open_segment) |index| switch (self.timeline.items[index]) {
            .thinking, .message => |segment| segment.ended_ms = at_ms,
            else => {},
        };
        self.open_segment = null;
    }
    fn appendSegment(self: *Turn, a: std.mem.Allocator, thinking: bool, text: []const u8, at_ms: u64) !void {
        if (text.len == 0) return;
        if (self.open_segment) |index| {
            const current = self.timeline.items[index];
            if ((thinking and current == .thinking) or (!thinking and current == .message)) {
                const segment = if (thinking) current.thinking else current.message;
                try segment.text.appendSlice(a, text);
                return;
            }
        }
        const segment = try a.create(Segment);
        segment.* = .{ .allocator = a, .started_ms = at_ms };
        errdefer segment.release();
        try segment.text.appendSlice(a, text);
        try self.timeline.ensureUnusedCapacity(a, 1);
        self.finishSegment(at_ms);
        self.timeline.appendAssumeCapacity(if (thinking) .{ .thinking = segment } else .{ .message = segment });
        self.open_segment = self.timeline.items.len - 1;
    }
    /// This is the display event log. Updating an existing call never inserts
    /// it again or moves it ahead of model content emitted in the meantime.
    pub fn applyEvent(self: *Turn, a: std.mem.Allocator, event: events.Event) !void {
        switch (event.kind) {
            .text => {
                try self.appendSegment(a, false, event.detail, event.at_ms);
                try self.prose.appendSlice(a, event.detail);
            },
            .thinking => {
                try self.appendSegment(a, true, event.detail, event.at_ms);
                if (self.thinking_started_ms == null) self.thinking_started_ms = event.at_ms;
                self.thinking_ended_ms = null;
                try self.thinking.appendSlice(a, event.detail);
            },
            .round_start => {
                self.finishSegment(event.at_ms);
                self.round_timeline_len = self.timeline.items.len;
                self.round_steps_len = self.steps.items.len;
                self.round_text_offset = self.prose.items.len;
                self.round_thinking_offset = self.thinking.items.len;
            },
            .reset => {
                self.open_segment = null;
                var retained = self.round_timeline_len;
                for (self.timeline.items[self.round_timeline_len..]) |item| {
                    if (item == .notice) {
                        // Host facts are independent of a failed provider attempt.
                        self.timeline.items[retained] = item;
                        retained += 1;
                    } else item.deinit(a);
                }
                self.timeline.shrinkRetainingCapacity(retained);
                for (self.steps.items[self.round_steps_len..]) |*step| step.deinit(a);
                self.steps.shrinkRetainingCapacity(self.round_steps_len);
                self.prose.shrinkRetainingCapacity(self.round_text_offset);
                self.thinking.shrinkRetainingCapacity(self.round_thinking_offset);
                if (self.thinking.items.len == 0) {
                    self.thinking_started_ms = null;
                    self.thinking_ended_ms = null;
                }
            },
            .step, .plan => {
                const existing = for (self.steps.items, 0..) |step, index| {
                    if (std.mem.eql(u8, step.call_id, event.call_id)) break index;
                } else null;
                const has_slot = if (existing) |index| for (self.timeline.items) |item| {
                    if (item == .tool and item.tool == index) break true;
                } else false else false;
                const append_slot = event.kind == .step and !has_slot;
                if (append_slot) try self.timeline.ensureUnusedCapacity(a, 1);
                var ordered = event;
                ordered.text_offset = self.prose.items.len;
                try events.apply(a, &self.steps, ordered);
                if (append_slot) {
                    self.finishSegment(event.at_ms);
                    self.timeline.appendAssumeCapacity(.{ .tool = existing orelse (self.steps.items.len - 1) });
                } else if (event.kind == .plan and existing == null) {
                    // A declaration closes the current text run, but execution
                    // gets a slot only when the gateway actually handles it.
                    self.finishSegment(event.at_ms);
                }
            },
        }
        if (event.kind != .thinking and self.thinking.items.len > 0 and self.thinking_ended_ms == null) self.thinking_ended_ms = event.at_ms;
    }
    pub fn appendNotice(self: *Turn, a: std.mem.Allocator, notice: HostNotice, at_ms: u64) !void {
        try self.host_notices.ensureUnusedCapacity(a, 1);
        try self.timeline.ensureUnusedCapacity(a, 1);
        self.finishSegment(at_ms);
        self.host_notices.appendAssumeCapacity(notice);
        self.timeline.appendAssumeCapacity(.{ .notice = self.host_notices.items.len - 1 });
    }
    pub fn clone(self: *const Turn, a: std.mem.Allocator) !Turn {
        var result: Turn = .{ .id = self.id, .task_id = self.task_id, .sent_at_ms = self.sent_at_ms, .ended_at_ms = self.ended_at_ms, .started_mono_ms = self.started_mono_ms, .elapsed_ms = self.elapsed_ms, .input_tokens = self.input_tokens, .output_tokens = self.output_tokens, .thinking_started_ms = self.thinking_started_ms, .thinking_ended_ms = self.thinking_ended_ms, .thinking_expanded = self.thinking_expanded };
        errdefer result.deinit(a);
        result.before = try wire.History.copy(a, self.before.messages, "");
        result.after = try wire.History.copy(a, self.after.messages, "");
        result.answer = try a.dupe(u8, self.answer);
        try result.prose.appendSlice(a, self.prose.items);
        result.round_text_offset = self.round_text_offset;
        result.round_thinking_offset = self.round_thinking_offset;
        result.round_timeline_len = self.round_timeline_len;
        result.round_steps_len = self.round_steps_len;
        result.open_segment = self.open_segment;
        for (self.timeline.items) |item| {
            const copy = try item.clone(a);
            result.timeline.append(a, copy) catch |err| {
                copy.deinit(a);
                return err;
            };
        }
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

test "timeline preserves interleaved thinking messages and tools without regrouping" {
    const a = std.testing.allocator;
    var turn: Turn = .{};
    defer turn.deinit(a);
    try turn.applyEvent(a, .{ .kind = .round_start, .phase = .assembling, .at_ms = 1 });
    try turn.applyEvent(a, .{ .kind = .thinking, .detail = "think-one", .phase = .assembling, .at_ms = 10 });
    try turn.applyEvent(a, .{ .kind = .thinking, .detail = " streamed", .phase = .assembling, .at_ms = 11 });
    try turn.applyEvent(a, .{ .kind = .text, .detail = "message-one", .phase = .assembling, .at_ms = 20 });
    try turn.applyEvent(a, .{ .kind = .thinking, .detail = "think-two", .phase = .assembling, .at_ms = 30 });
    try turn.applyEvent(a, .{ .kind = .text, .detail = "message-two", .phase = .assembling, .at_ms = 40 });
    try turn.applyEvent(a, .{ .call_id = "tool-one", .name = "read_terminal", .phase = .assembling, .at_ms = 50 });
    try turn.applyEvent(a, .{ .kind = .round_start, .phase = .assembling, .at_ms = 60 });
    try turn.applyEvent(a, .{ .kind = .thinking, .detail = "think-three", .phase = .assembling, .at_ms = 70 });
    try turn.applyEvent(a, .{ .kind = .text, .detail = "message-three", .phase = .assembling, .at_ms = 80 });
    try turn.applyEvent(a, .{ .call_id = "tool-one", .phase = .succeeded, .at_ms = 85 });
    try turn.applyEvent(a, .{ .kind = .text, .detail = " tail", .phase = .assembling, .at_ms = 90 });
    try std.testing.expectEqual(@as(usize, 7), turn.timeline.items.len);
    try std.testing.expectEqualStrings("think-one streamed", turn.timeline.items[0].thinking.text.items);
    try std.testing.expectEqualStrings("message-one", turn.timeline.items[1].message.text.items);
    try std.testing.expectEqualStrings("think-two", turn.timeline.items[2].thinking.text.items);
    try std.testing.expectEqualStrings("message-two", turn.timeline.items[3].message.text.items);
    try std.testing.expectEqual(@as(usize, 0), turn.timeline.items[4].tool);
    try std.testing.expectEqualStrings("think-three", turn.timeline.items[5].thinking.text.items);
    try std.testing.expectEqualStrings("message-three tail", turn.timeline.items[6].message.text.items);
    try std.testing.expectEqual(@as(u64, 20), turn.timeline.items[0].thinking.ended_ms.?);
    try std.testing.expectEqual(@as(u64, 40), turn.timeline.items[2].thinking.ended_ms.?);
}

test "timeline clone keeps independent thinking disclosures scroll and ordering" {
    const a = std.testing.allocator;
    var turn: Turn = .{};
    defer turn.deinit(a);
    try turn.applyEvent(a, .{ .kind = .thinking, .detail = "first", .phase = .assembling, .at_ms = 10 });
    try turn.applyEvent(a, .{ .kind = .text, .detail = "between", .phase = .assembling, .at_ms = 20 });
    try turn.applyEvent(a, .{ .kind = .thinking, .detail = "second", .phase = .assembling, .at_ms = 30 });
    turn.timeline.items[0].thinking.expanded = true;
    turn.timeline.items[0].thinking.scroll = try ThinkingScroll.create(a);
    turn.timeline.items[0].thinking.scroll.?.offset = -48;
    var copy = try turn.clone(a);
    defer copy.deinit(a);
    try std.testing.expect(copy.timeline.items[0].thinking != turn.timeline.items[0].thinking);
    try std.testing.expect(copy.timeline.items[0].thinking.expanded);
    try std.testing.expect(!copy.timeline.items[2].thinking.expanded);
    try std.testing.expectEqual(@as(f32, -48), copy.timeline.items[0].thinking.scroll.?.offset);
    try copy.applyEvent(a, .{ .kind = .thinking, .detail = " copy-only", .phase = .assembling, .at_ms = 31 });
    try std.testing.expectEqualStrings("second", turn.timeline.items[2].thinking.text.items);
    try std.testing.expectEqualStrings("second copy-only", copy.timeline.items[2].thinking.text.items);
}

test "timeline retry replaces only the failed round and preserves host facts" {
    const a = std.testing.allocator;
    var turn: Turn = .{};
    defer turn.deinit(a);
    try turn.applyEvent(a, .{ .kind = .text, .detail = "earlier", .phase = .assembling, .at_ms = 1 });
    try turn.applyEvent(a, .{ .call_id = "done", .phase = .succeeded, .at_ms = 2 });
    try turn.applyEvent(a, .{ .kind = .round_start, .phase = .assembling, .at_ms = 3 });
    try turn.applyEvent(a, .{ .kind = .thinking, .detail = "discard", .phase = .assembling, .at_ms = 4 });
    const retired = turn.timeline.items[2].thinking;
    retired.retain(); // A mounted disclosure still reads its segment at cleanup.
    defer retired.release();
    try turn.applyEvent(a, .{ .kind = .text, .detail = "discard", .phase = .assembling, .at_ms = 5 });
    try turn.applyEvent(a, .{ .call_id = "retry-id", .phase = .assembling, .at_ms = 6 });
    try turn.appendNotice(a, .{ .revision = 1, .target = .{ .session_id = @fromBackingInt(1), .generation = 1 }, .text = try a.dupe(u8, "host fact") }, 7);
    try turn.applyEvent(a, .{ .kind = .reset, .phase = .assembling, .at_ms = 8 });
    try std.testing.expectEqualStrings("discard", retired.text.items);
    try std.testing.expectEqual(@as(usize, 3), turn.timeline.items.len);
    try std.testing.expectEqual(@as(usize, 0), turn.timeline.items[2].notice);
    try std.testing.expectEqual(@as(usize, 1), turn.steps.items.len);
    try std.testing.expectEqualStrings("earlier", turn.prose.items);
    try turn.applyEvent(a, .{ .kind = .thinking, .detail = "retry", .phase = .assembling, .at_ms = 9 });
    try turn.applyEvent(a, .{ .call_id = "retry-id", .phase = .assembling, .at_ms = 10 });
    try std.testing.expectEqual(@as(usize, 1), turn.timeline.items[4].tool);
}

test "timeline provider round boundary starts another message even on the same channel" {
    const a = std.testing.allocator;
    var turn: Turn = .{};
    defer turn.deinit(a);
    try turn.applyEvent(a, .{ .kind = .text, .detail = "round-one", .phase = .assembling, .at_ms = 1 });
    try turn.applyEvent(a, .{ .kind = .round_start, .phase = .assembling, .at_ms = 2 });
    try turn.applyEvent(a, .{ .kind = .text, .detail = "round-two", .phase = .assembling, .at_ms = 3 });
    turn.finishSegment(4);
    try std.testing.expectEqual(@as(usize, 2), turn.timeline.items.len);
    try std.testing.expectEqualStrings("round-one", turn.timeline.items[0].message.text.items);
    try std.testing.expectEqualStrings("round-two", turn.timeline.items[1].message.text.items);
    try std.testing.expectEqual(@as(u64, 2), turn.timeline.items[0].message.ended_ms.?);
    try std.testing.expectEqual(@as(u64, 4), turn.timeline.items[1].message.ended_ms.?);
}

test "timeline adds tool slots at gateway time rather than out of order declaration fragments" {
    const a = std.testing.allocator;
    var turn: Turn = .{};
    defer turn.deinit(a);
    try turn.applyEvent(a, .{ .kind = .text, .detail = "before plans", .phase = .assembling, .at_ms = 1 });
    try turn.applyEvent(a, .{ .kind = .plan, .call_id = "second-tool", .phase = .assembling, .at_ms = 2 });
    try turn.applyEvent(a, .{ .kind = .plan, .call_id = "first-tool", .phase = .assembling, .at_ms = 3 });
    try turn.applyEvent(a, .{ .kind = .text, .detail = "explanation before dispatch", .phase = .assembling, .at_ms = 4 });
    try std.testing.expectEqual(@as(usize, 2), turn.timeline.items.len);
    try turn.applyEvent(a, .{ .call_id = "first-tool", .phase = .approval, .at_ms = 5 });
    try turn.applyEvent(a, .{ .call_id = "first-tool", .phase = .succeeded, .at_ms = 6 });
    try turn.applyEvent(a, .{ .call_id = "second-tool", .phase = .running, .at_ms = 7 });
    try std.testing.expectEqualStrings("before plans", turn.timeline.items[0].message.text.items);
    try std.testing.expectEqualStrings("explanation before dispatch", turn.timeline.items[1].message.text.items);
    try std.testing.expectEqualStrings("first-tool", turn.steps.items[turn.timeline.items[2].tool].call_id);
    try std.testing.expectEqualStrings("second-tool", turn.steps.items[turn.timeline.items[3].tool].call_id);
}
