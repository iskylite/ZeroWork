//! Display groups follow timeline prose boundaries, never provider rounds.
const std = @import("std");
const turns = @import("conversation_turn.zig");
const events = @import("step_events.zig");

/// Stable ownership keeps disclosure state alive through streaming rebuilds,
/// history moves, and disposal of a view after a provider retry.
pub const State = struct {
    allocator: std.mem.Allocator,
    references: usize = 1,
    first: usize,
    expanded: bool,
    pub fn create(a: std.mem.Allocator, first: usize, expanded: bool) !*State {
        const self = try a.create(State);
        self.* = .{ .allocator = a, .first = first, .expanded = expanded };
        return self;
    }
    pub fn retain(self: *State) void {
        self.references += 1;
    }
    pub fn release(self: *State) void {
        self.references -= 1;
        if (self.references == 0) self.allocator.destroy(self);
    }
};

pub fn boundary(item: turns.TimelineItem) bool {
    // Independent host notices must remain visible in chronological position.
    return switch (item) {
        .message => |segment| std.mem.trim(u8, @import("history_environment.zig").assistantText(segment.text.items), " \t\r\n").len != 0,
        .notice, .input => true,
        else => false,
    };
}
pub fn rangeEnd(turn: *const turns.Turn, first: usize) usize {
    var end = first;
    while (end < turn.timeline.items.len and !boundary(turn.timeline.items[end])) : (end += 1) {}
    return end;
}
pub fn toolVisible(step: events.Step) bool {
    // Only pending confirmation controls need an always-accessible surface.
    // Every settled outcome belongs to the same consecutive step group.
    return step.phase != .assembling and step.phase != .approval;
}
pub const Summary = struct {
    count: usize = 0,
    latest: ?turns.TimelineItem = null,
    elapsed_ms: u64 = 0,
    phase: events.Phase = .succeeded,
    live: bool = false,
    thinking_projection: ?[]const u8 = null,
};
/// Shared with the thinking card: project the latest line of the streamed
/// content. Completed thinking never overrides the group's normal summary.
pub fn thinkingProjection(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |offset| trimmed[offset + 1 ..] else trimmed;
}
pub fn summarize(turn: *const turns.Turn, first: usize, end: usize, now: u64) Summary {
    const clock = turn.displayClock(now);
    var result: Summary = .{};
    for (turn.timeline.items[first..end]) |item| {
        var phase: events.Phase = .succeeded;
        switch (item) {
            .thinking => |segment| {
                result.elapsed_ms +|= (segment.ended_ms orelse clock) -| segment.started_ms;
                if (segment.ended_ms == null) {
                    phase = .running;
                    const projection = thinkingProjection(segment.text.items);
                    if (projection.len != 0) result.thinking_projection = projection;
                }
            },
            .tool => |index| {
                const step = turn.steps.items[index];
                if (!toolVisible(step)) continue;
                phase = step.phase;
                result.elapsed_ms +|= step.elapsedAt(clock);
            },
            else => continue,
        }
        result.count += 1;
        result.latest = item;
        if (phase == .running or phase == .approved) result.live = true;
        // A later cancellation or completed step must not hide an earlier failure.
        if (phase == .failed or (phase == .rejected and result.phase != .failed) or (phase == .cancelled and result.phase != .failed and result.phase != .rejected)) result.phase = phase;
    }
    if (result.phase == .succeeded and result.live) result.phase = .running;
    if (turn.restored_interrupted) result.live = false;
    return result;
}
pub fn find(turn: *const turns.Turn, first: usize) ?*State {
    for (turn.step_groups.items) |state| if (state.first == first) return state;
    return null;
}
/// Called for every display event, so a changed setting affects only new groups.
pub fn sync(a: std.mem.Allocator, turn: *turns.Turn, expanded: bool) !void {
    var first: usize = 0;
    while (first < turn.timeline.items.len) {
        if (boundary(turn.timeline.items[first])) {
            first += 1;
            continue;
        }
        const end = rangeEnd(turn, first);
        if (summarize(turn, first, end, 0).count != 0 and find(turn, first) == null) {
            const state = try State.create(a, first, expanded);
            errdefer state.release();
            try turn.step_groups.append(a, state);
        }
        first = end;
    }
}
