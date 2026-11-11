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
    submission: ?identity.SubmissionId = null,
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
        result.* = .{ .allocator = a, .started_ms = self.started_ms, .ended_ms = self.ended_ms, .expanded = self.expanded, .submission = self.submission };
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
    input: *Segment,
    thinking: *Segment,
    tool: usize,
    notice: usize,
    fn deinit(self: TimelineItem, a: std.mem.Allocator) void {
        _ = a;
        switch (self) {
            .message, .thinking, .input => |segment| segment.release(),
            .tool, .notice => {},
        }
    }
    fn clone(self: TimelineItem, a: std.mem.Allocator) !TimelineItem {
        return switch (self) {
            .message => |segment| .{ .message = try segment.clone(a) },
            .thinking => |segment| .{ .thinking = try segment.clone(a) },
            .input => |segment| .{ .input = try segment.clone(a) },
            .tool, .notice => self,
        };
    }
};
pub const Turn = struct {
    file_source: ?@import("terminal_file_source.zig").Source = null,
    id: u64 = 0,
    task_id: ?identity.TaskId = null,
    sent_at_ms: u64 = 0,
    ended_at_ms: ?u64 = null,
    started_mono_ms: u64 = 0,
    elapsed_ms: u64 = 0,
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    request_count: ?u64 = null,
    before: wire.History = .{},
    after: wire.History = .{},
    answer: []u8 = &.{},
    process_expanded: bool = false,
    timeline: std.ArrayList(TimelineItem) = .empty,
    step_groups: std.ArrayList(*@import("step_groups.zig").State) = .empty,
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
        if (self.file_source) |*source| source.deinit(a);
        self.before.deinit();
        self.after.deinit();
        a.free(self.answer);
        for (self.timeline.items) |item| item.deinit(a);
        self.timeline.deinit(a);
        for (self.step_groups.items) |group| group.release();
        self.step_groups.deinit(a);
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
            .input => {
                const id = event.submission orelse return error.InvalidSubmission;
                if (self.hasInput(id)) return;
                const segment = try a.create(Segment);
                segment.* = .{ .allocator = a, .started_ms = event.at_ms, .ended_ms = event.at_ms, .submission = id };
                errdefer segment.release();
                try segment.text.appendSlice(a, event.detail);
                try self.timeline.ensureUnusedCapacity(a, 1);
                self.finishSegment(event.at_ms);
                self.timeline.appendAssumeCapacity(.{ .input = segment });
            },
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
                // Groups created by the discarded attempt must not donate their
                // disclosure state to a new attempt at the same timeline index.
                var kept_groups: usize = 0;
                for (self.step_groups.items) |group| {
                    if (group.first < self.round_timeline_len) {
                        self.step_groups.items[kept_groups] = group;
                        kept_groups += 1;
                    } else group.release();
                }
                self.step_groups.shrinkRetainingCapacity(kept_groups);
                self.open_segment = null;
                var retained = self.round_timeline_len;
                for (self.timeline.items[self.round_timeline_len..]) |item| {
                    if (item == .notice or item == .input) {
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
    pub fn hasInput(self: *const Turn, id: identity.SubmissionId) bool {
        for (self.timeline.items) |item| if (item == .input) {
            if (item.input.submission) |stored| if (stored.eql(id)) return true;
        };
        return false;
    }
    pub fn appendNotice(self: *Turn, a: std.mem.Allocator, notice: HostNotice, at_ms: u64) !void {
        try self.host_notices.ensureUnusedCapacity(a, 1);
        try self.timeline.ensureUnusedCapacity(a, 1);
        self.finishSegment(at_ms);
        self.host_notices.appendAssumeCapacity(notice);
        self.timeline.appendAssumeCapacity(.{ .notice = self.host_notices.items.len - 1 });
    }
    pub fn inputSegment(self: *const Turn, id: identity.SubmissionId) ?*Segment {
        for (self.timeline.items) |item| if (item == .input) {
            if (item.input.submission) |submission| if (submission.eql(id)) return item.input;
        };
        return null;
    }
    /// Match inputs in order, including repeated text. Refuse a compacted or
    /// incomplete checkpoint rather than patching an unrelated user message.
    pub fn inputLocation(self: *const Turn, id: identity.SubmissionId) !struct { timeline: usize, wire: usize } {
        if (self.after.messages.len <= self.before.messages.len) return error.NoStableCheckpoint;
        for (self.before.messages, self.after.messages[0..self.before.messages.len]) |before, after| {
            if (before.role != after.role or !std.mem.eql(u8, before.content, after.content)) return error.NoStableCheckpoint;
        }
        if (self.after.messages[self.before.messages.len].role != .user) return error.NoStableCheckpoint;
        var offset = self.before.messages.len + 1;
        for (self.timeline.items, 0..) |item, index| if (item == .input) {
            while (offset < self.after.messages.len and self.after.messages[offset].role != .user) : (offset += 1) {}
            if (offset == self.after.messages.len or !std.mem.eql(u8, self.after.messages[offset].content, item.input.text.items)) return error.NoStableCheckpoint;
            if (item.input.submission) |submission| if (submission.eql(id)) return .{ .timeline = index, .wire = offset };
            offset += 1;
        };
        return error.StaleTurn;
    }
    pub fn prefixBeforeInput(self: *const Turn, a: std.mem.Allocator, id: identity.SubmissionId) !Turn {
        const location = try self.inputLocation(id);
        var result = try self.clone(a);
        errdefer result.deinit(a);
        var after = try wire.History.copy(a, self.after.messages[0..location.wire], "");
        errdefer after.deinit();
        result.after.deinit();
        result.after = after;
        after = .{};
        for (result.timeline.items[location.timeline..]) |item| item.deinit(a);
        result.timeline.shrinkRetainingCapacity(location.timeline);
        result.open_segment = null;
        result.prose.clearRetainingCapacity();
        result.thinking.clearRetainingCapacity();
        var steps: usize = 0;
        var notices: usize = 0;
        for (result.timeline.items) |item| switch (item) {
            .message => |segment| try result.prose.appendSlice(a, segment.text.items),
            .thinking => |segment| try result.thinking.appendSlice(a, segment.text.items),
            .tool => |index| steps = @max(steps, index + 1),
            .notice => |index| notices = @max(notices, index + 1),
            .input => {},
        };
        for (result.steps.items[steps..]) |*step| step.deinit(a);
        result.steps.shrinkRetainingCapacity(steps);
        for (result.host_notices.items[notices..]) |notice| a.free(notice.text);
        result.host_notices.shrinkRetainingCapacity(notices);
        var kept: usize = 0;
        for (result.step_groups.items) |group| {
            if (group.first < location.timeline) {
                result.step_groups.items[kept] = group;
                kept += 1;
            } else group.release();
        }
        result.step_groups.shrinkRetainingCapacity(kept);
        const answer = try a.dupe(u8, result.prose.items);
        a.free(result.answer);
        result.answer = answer;
        result.round_timeline_len = result.timeline.items.len;
        result.round_steps_len = steps;
        result.round_text_offset = result.prose.items.len;
        result.round_thinking_offset = result.thinking.items.len;
        result.input_tokens = null;
        result.output_tokens = null;
        result.request_count = null;
        return result;
    }
    /// Locate the retained final response, including split text segments. The
    /// process view stops here; the authoritative final answer renders once.
    pub fn finalResponseStart(self: *const Turn) usize {
        if (self.answer.len == 0) return self.timeline.items.len;
        var remaining = self.answer.len;
        var i = self.timeline.items.len;
        while (i > 0) {
            i -= 1;
            switch (self.timeline.items[i]) {
                .thinking => {},
                .message => |segment| {
                    const text = segment.text.items;
                    if (text.len > remaining or !std.mem.endsWith(u8, self.answer[0..remaining], text)) break;
                    remaining -= text.len;
                    if (remaining == 0) return i;
                },
                else => break,
            }
        }
        return self.timeline.items.len;
    }
    pub fn clone(self: *const Turn, a: std.mem.Allocator) !Turn {
        var result: Turn = .{ .id = self.id, .task_id = self.task_id, .sent_at_ms = self.sent_at_ms, .ended_at_ms = self.ended_at_ms, .started_mono_ms = self.started_mono_ms, .elapsed_ms = self.elapsed_ms, .input_tokens = self.input_tokens, .output_tokens = self.output_tokens, .request_count = self.request_count, .thinking_started_ms = self.thinking_started_ms, .thinking_ended_ms = self.thinking_ended_ms, .thinking_expanded = self.thinking_expanded, .process_expanded = self.process_expanded };
        errdefer result.deinit(a);
        result.file_source = if (self.file_source) |source| try source.clone(a) else null;
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
        for (self.step_groups.items) |group| {
            const copy = try @import("step_groups.zig").State.create(a, group.first, group.expanded);
            result.step_groups.append(a, copy) catch |err| {
                copy.release();
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

test "steering timeline splits groups and survives retries cloning and presentation restore" {
    const a = std.testing.allocator;
    const groups = @import("step_groups.zig");
    var turn: Turn = .{ .id = 7 };
    defer turn.deinit(a);
    const id = identity.SubmissionId.generate();
    try turn.applyEvent(a, .{ .kind = .thinking, .detail = "before", .phase = .running, .at_ms = 1 });
    try turn.applyEvent(a, .{ .call_id = "old", .name = "read_terminal", .detail = "not_dispatched_due_to_new_input", .phase = .skipped, .at_ms = 2 });
    try turn.applyEvent(a, .{ .kind = .input, .submission = id, .detail = "补充消息", .phase = .succeeded, .at_ms = 3 });
    try turn.applyEvent(a, .{ .kind = .round_start, .phase = .assembling, .at_ms = 4 });
    try turn.applyEvent(a, .{ .kind = .thinking, .detail = "discarded attempt", .phase = .running, .at_ms = 5 });
    try groups.sync(a, &turn, false);
    try std.testing.expectEqual(@as(usize, 2), turn.step_groups.items.len);
    try turn.applyEvent(a, .{ .kind = .reset, .phase = .assembling, .at_ms = 6 });
    try turn.applyEvent(a, .{ .kind = .thinking, .detail = "after", .phase = .running, .at_ms = 7 });
    try groups.sync(a, &turn, false);
    try std.testing.expectEqual(@as(usize, 2), turn.step_groups.items.len);
    try std.testing.expectEqual(@as(usize, 2), groups.rangeEnd(&turn, 0));
    try std.testing.expectEqual(events.Phase.succeeded, groups.summarize(&turn, 0, 2, 8).phase);
    try std.testing.expect(turn.hasInput(id));
    try std.testing.expectEqualStrings("补充消息", turn.timeline.items[2].input.text.items);
    try std.testing.expectEqualStrings("after", turn.timeline.items[3].thinking.text.items);
    var copy = try turn.clone(a);
    defer copy.deinit(a);
    try std.testing.expect(copy.hasInput(id));
    const snapshot = try @import("conversation_presentation.zig").capture(a, &.{.{ .user = true, .text = @constCast("initial"), .turn = turn }}, null, &.{});
    defer a.free(snapshot);
    var restored = try @import("conversation_presentation.zig").restore(a, snapshot, 0);
    defer {
        for (restored.items) |*message| message.deinit(a);
        restored.deinit(a);
    }
    const recovered = &restored.items[0].turn.?;
    try std.testing.expect(recovered.hasInput(id));
    try std.testing.expectEqualStrings("补充消息", recovered.timeline.items[2].input.text.items);
    try std.testing.expectEqual(@as(usize, 2), recovered.step_groups.items.len);
    // Reconciliation/retry must not insert an already consumed message twice.
    try recovered.applyEvent(a, .{ .kind = .input, .submission = id, .detail = "补充消息", .phase = .succeeded, .at_ms = 9 });
    try std.testing.expectEqual(@as(usize, 4), recovered.timeline.items.len);
}

test "steering message actions locate repeated inputs and preserve the exact rollback prefix" {
    const a = std.testing.allocator;
    var turn: Turn = .{ .id = 5, .ended_at_ms = 100 };
    defer turn.deinit(a);
    const first = identity.SubmissionId.generate();
    const second = identity.SubmissionId.generate();
    turn.before = try wire.History.copy(a, &.{.{ .content = "older turn" }}, "");
    turn.after = try wire.History.copy(a, &.{
        .{ .content = "older turn" },                  .{ .content = "initial" },
        .{ .role = .assistant, .content = "before" },  .{ .content = "same text" },
        .{ .role = .assistant, .content = "between" }, .{ .content = "same text" },
        .{ .role = .assistant, .content = "after" },
    }, "");
    try turn.applyEvent(a, .{ .kind = .text, .phase = .succeeded, .detail = "before", .at_ms = 1 });
    try turn.applyEvent(a, .{ .call_id = "prior", .phase = .succeeded, .at_ms = 2 });
    try turn.applyEvent(a, .{ .kind = .input, .phase = .succeeded, .submission = first, .detail = "same text", .at_ms = 3 });
    try turn.applyEvent(a, .{ .kind = .text, .phase = .succeeded, .detail = "between", .at_ms = 4 });
    try turn.applyEvent(a, .{ .kind = .input, .phase = .succeeded, .submission = second, .detail = "same text", .at_ms = 5 });
    try turn.applyEvent(a, .{ .call_id = "later", .phase = .succeeded, .at_ms = 6 });
    try turn.applyEvent(a, .{ .kind = .text, .phase = .succeeded, .detail = "after", .at_ms = 7 });
    try @import("step_groups.zig").sync(a, &turn, false);
    try std.testing.expectEqual(@as(usize, 3), (try turn.inputLocation(first)).wire);
    try std.testing.expectEqual(@as(usize, 5), (try turn.inputLocation(second)).wire);
    var edited = (try turn.after.editedUser(a, (try turn.inputLocation(second)).wire, "same text", "edited second")).?;
    defer edited.deinit();
    try std.testing.expectEqualStrings("same text", edited.messages[3].content);
    try std.testing.expectEqualStrings("edited second", edited.messages[5].content);
    var prefix = try turn.prefixBeforeInput(a, second);
    defer prefix.deinit(a);
    try std.testing.expect(prefix.hasInput(first) and !prefix.hasInput(second));
    try std.testing.expectEqual(@as(usize, 5), prefix.after.messages.len);
    try std.testing.expectEqual(@as(usize, 1), prefix.steps.items.len);
    try std.testing.expectEqualStrings("prior", prefix.steps.items[0].call_id);
    try std.testing.expectEqualStrings("beforebetween", prefix.answer);
    try std.testing.expectEqual(@as(usize, 4), prefix.timeline.items.len);
    try std.testing.expectEqual(@as(usize, 1), prefix.step_groups.items.len);
    try std.testing.expect(turn.hasInput(second));
    var immediate: Turn = .{ .ended_at_ms = 100 };
    defer immediate.deinit(a);
    immediate.after = try wire.History.copy(a, &.{ .{ .content = "initial" }, .{ .content = "same text" } }, "");
    try immediate.applyEvent(a, .{ .kind = .input, .phase = .succeeded, .submission = first, .detail = "same text", .at_ms = 1 });
    var empty_prefix = try immediate.prefixBeforeInput(a, first);
    defer empty_prefix.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), empty_prefix.timeline.items.len);
    try std.testing.expectEqual(@as(usize, 1), empty_prefix.after.messages.len);
    // The original survives a compacted/mismatched context; never guess by text.
    turn.before.deinit();
    turn.before = try wire.History.copy(a, &.{.{ .content = "compacted" }}, "");
    try std.testing.expectError(error.NoStableCheckpoint, turn.inputLocation(second));
}

test "steering message rollback prefix allocation failures preserve the original" {
    const Scenario = struct {
        fn run(a: std.mem.Allocator) !void {
            var turn: Turn = .{ .ended_at_ms = 20 };
            defer turn.deinit(a);
            const id = identity.SubmissionId.generate();
            turn.after = try wire.History.copy(a, &.{ .{ .content = "first" }, .{ .role = .assistant, .content = "before" }, .{ .content = "steer" } }, "");
            try turn.applyEvent(a, .{ .kind = .text, .phase = .succeeded, .detail = "before", .at_ms = 1 });
            try turn.applyEvent(a, .{ .kind = .input, .phase = .succeeded, .submission = id, .detail = "steer", .at_ms = 2 });
            var prefix = try turn.prefixBeforeInput(a, id);
            defer prefix.deinit(a);
            try std.testing.expect(turn.hasInput(id));
            try std.testing.expectEqualStrings("before", prefix.answer);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Scenario.run, .{});
}
