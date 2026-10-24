const std = @import("std");

pub const Direction = enum { left_to_right, right_to_left };
pub const State = enum { idle, running, left_eof, right_eof, closed, failed };
pub const Relay = struct {
    state: State = .idle,
    left_to_right_bytes: u64 = 0,
    right_to_left_bytes: u64 = 0,

    pub fn start(self: *Relay) !void {
        if (self.state != .idle) return error.InvalidTransition;
        self.state = .running;
    }

    pub fn forwarded(self: *Relay, direction: Direction, count: usize) !void {
        if (self.state != .running) return error.InvalidTransition;
        switch (direction) {
            .left_to_right => self.left_to_right_bytes += count,
            .right_to_left => self.right_to_left_bytes += count,
        }
    }

    pub fn eof(self: *Relay, direction: Direction) !void {
        if (self.state != .running and self.state != .left_eof and self.state != .right_eof) return error.InvalidTransition;
        self.state = switch (direction) {
            .left_to_right => if (self.state == .right_eof) .closed else .left_eof,
            .right_to_left => if (self.state == .left_eof) .closed else .right_eof,
        };
    }

    pub fn fail(self: *Relay) void {
        self.state = .failed;
    }
    pub fn close(self: *Relay) void {
        self.state = .closed;
    }
};

test "relay tracks both directions and closes after both EOFs" {
    var relay: Relay = .{};
    try relay.start();
    try relay.forwarded(.left_to_right, 11);
    try relay.forwarded(.right_to_left, 7);
    try relay.eof(.left_to_right);
    try std.testing.expectEqual(State.left_eof, relay.state);
    try relay.eof(.right_to_left);
    try std.testing.expectEqual(State.closed, relay.state);
    try std.testing.expectEqual(@as(u64, 11), relay.left_to_right_bytes);
    try std.testing.expectEqual(@as(u64, 7), relay.right_to_left_bytes);
}
