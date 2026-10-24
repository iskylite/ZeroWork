const std = @import("std");
const Interest = @import("worker_interest.zig").Interest;

pub const State = enum { idle, running, paused_for_ui, closed, failed };

pub const Machine = struct {
    state: State = .idle,
    interest: Interest = .{},

    pub fn start(self: *Machine) !void {
        if (self.state != .idle) return error.InvalidTransition;
        self.state = .running;
        self.interest = .{};
    }

    pub fn onConsumerBehind(self: *Machine, has_pending_input: bool) !void {
        if (self.state != .running) return error.InvalidTransition;
        self.state = .paused_for_ui;
        self.interest = .{ .read = false, .write = has_pending_input, .paused_for_ui = true };
    }

    pub fn onUiConsumed(self: *Machine, has_pending_input: bool) !void {
        if (self.state != .paused_for_ui) return error.InvalidTransition;
        self.state = .running;
        self.interest = .{ .read = true, .write = has_pending_input };
    }

    pub fn close(self: *Machine) void {
        self.state = .closed;
        self.interest = .{};
    }

    pub fn fail(self: *Machine) void {
        self.state = .failed;
        self.interest = .{};
    }
};

test "worker state pauses and resumes around UI backpressure" {
    var machine: Machine = .{};
    try machine.start();
    try machine.onConsumerBehind(true);
    try std.testing.expectEqual(State.paused_for_ui, machine.state);
    try std.testing.expect(!machine.interest.read and machine.interest.write);
    try machine.onUiConsumed(false);
    try std.testing.expectEqual(State.running, machine.state);
    try std.testing.expect(machine.interest.read and !machine.interest.write);
}

test "worker state rejects invalid transitions" {
    var machine: Machine = .{};
    try std.testing.expectError(error.InvalidTransition, machine.onUiConsumed(false));
    machine.close();
    try std.testing.expectError(error.InvalidTransition, machine.start());
}
