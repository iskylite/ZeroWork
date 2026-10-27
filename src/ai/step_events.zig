//! Owned worker events; the UI never reads the live tool loop.
const std = @import("std");
pub const Phase = enum { assembling, running, approval, approved, rejected, succeeded, failed, cancelled };
pub const Event = struct {
    call_id: []const u8,
    name: []const u8 = "",
    command: []const u8 = "",
    detail: []const u8 = "",
    phase: Phase,
    at_ms: u64,
    pub fn deinit(self: Event, a: std.mem.Allocator) void {
        a.free(self.call_id);
        a.free(self.name);
        a.free(self.command);
        a.free(self.detail);
    }
};
pub const Mailbox = struct {
    allocator: std.mem.Allocator,
    mutex: std.atomic.Mutex = .unlocked,
    pending: std.ArrayList(Event) = .empty,
    pub fn init(a: std.mem.Allocator) Mailbox {
        return .{ .allocator = a };
    }
    fn lock(self: *Mailbox) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    pub fn push(self: *Mailbox, event: Event) !void {
        self.lock();
        defer self.mutex.unlock();
        const a = self.allocator;
        const id = try a.dupe(u8, event.call_id);
        errdefer a.free(id);
        const name = try a.dupe(u8, event.name);
        errdefer a.free(name);
        const command = try a.dupe(u8, event.command);
        errdefer a.free(command);
        const detail = try a.dupe(u8, event.detail);
        errdefer a.free(detail);
        try self.pending.append(a, .{ .call_id = id, .name = name, .command = command, .detail = detail, .phase = event.phase, .at_ms = event.at_ms });
    }
    pub fn drain(self: *Mailbox) ![]Event {
        self.lock();
        defer self.mutex.unlock();
        return self.pending.toOwnedSlice(self.allocator);
    }
    pub fn deinit(self: *Mailbox) void {
        for (self.pending.items) |e| e.deinit(self.allocator);
        self.pending.deinit(self.allocator);
    }
};
pub const Step = struct {
    call_id: []u8,
    name: []u8,
    command: []u8,
    detail: []u8,
    phase: Phase,
    started_ms: u64,
    ended_ms: ?u64 = null,
    decision: ?bool = null,
    expanded: bool = false,
    pub fn deinit(self: *Step, a: std.mem.Allocator) void {
        a.free(self.call_id);
        a.free(self.name);
        a.free(self.command);
        a.free(self.detail);
    }
    pub fn clone(self: Step, a: std.mem.Allocator) !Step {
        const id = try a.dupe(u8, self.call_id);
        errdefer a.free(id);
        const name = try a.dupe(u8, self.name);
        errdefer a.free(name);
        const command = try a.dupe(u8, self.command);
        errdefer a.free(command);
        return .{ .call_id = id, .name = name, .command = command, .detail = try a.dupe(u8, self.detail), .phase = self.phase, .started_ms = self.started_ms, .ended_ms = self.ended_ms, .decision = self.decision, .expanded = self.expanded };
    }
};
pub fn apply(a: std.mem.Allocator, steps: *std.ArrayList(Step), e: Event) !void {
    for (steps.items) |*step| if (std.mem.eql(u8, step.call_id, e.call_id)) {
        const name = if (e.name.len > 0) try a.dupe(u8, e.name) else null;
        errdefer if (name) |value| a.free(value);
        const command = if (e.command.len > 0) try a.dupe(u8, e.command) else null;
        errdefer if (command) |value| a.free(value);
        const detail = if (e.detail.len > 0) try a.dupe(u8, e.detail) else null;
        if (detail) |value| {
            a.free(step.detail);
            step.detail = value;
        }
        if (name) |value| {
            a.free(step.name);
            step.name = value;
        }
        if (command) |value| {
            a.free(step.command);
            step.command = value;
        }
        step.phase = e.phase;
        if (e.phase == .approved or e.phase == .rejected) step.decision = e.phase == .approved;
        if (terminal(e.phase)) step.ended_ms = e.at_ms;
        return;
    };
    var step = try (Step{ .call_id = @constCast(e.call_id), .name = @constCast(e.name), .command = @constCast(e.command), .detail = @constCast(e.detail), .phase = e.phase, .started_ms = e.at_ms }).clone(a);
    errdefer step.deinit(a);
    try steps.append(a, step);
}
pub fn terminal(phase: Phase) bool {
    return switch (phase) {
        .succeeded, .failed, .cancelled, .rejected => true,
        else => false,
    };
}

test "step events preserve approval and tool identity until the actual result" {
    const a = std.testing.allocator;
    var mailbox = Mailbox.init(a);
    defer mailbox.deinit();
    var steps: std.ArrayList(Step) = .empty;
    defer {
        for (steps.items) |*s| s.deinit(a);
        steps.deinit(a);
    }
    try mailbox.push(.{ .call_id = "one", .name = "run_command", .command = "date", .phase = .running, .at_ms = 10 });
    try mailbox.push(.{ .call_id = "one", .phase = .approval, .at_ms = 15 });
    try mailbox.push(.{ .call_id = "one", .phase = .approved, .at_ms = 30 });
    try mailbox.push(.{ .call_id = "one", .phase = .succeeded, .detail = "actual stdout", .at_ms = 50 });
    const events = try mailbox.drain();
    defer a.free(events);
    for (events) |e| {
        defer e.deinit(a);
        try apply(a, &steps, e);
    }
    try std.testing.expectEqual(@as(usize, 1), steps.items.len);
    try std.testing.expectEqualStrings("date", steps.items[0].command);
    try std.testing.expectEqualStrings("actual stdout", steps.items[0].detail);
    try std.testing.expect(steps.items[0].decision.?);
    try std.testing.expectEqual(@as(u64, 40), steps.items[0].ended_ms.? - steps.items[0].started_ms);
}
