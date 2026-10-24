const std = @import("std");
const Reconnect = @import("../vt/reconnect.zig");
const Tombstone = @import("session_tombstone.zig").Tombstone;

pub const Bridge = struct {
    tombstone: Tombstone = .{},

    pub fn onWorkerFailure(self: *Bridge, reason: ?[]const u8) void {
        self.tombstone.end(reason);
    }

    pub fn requestReconnect(self: *Bridge) bool {
        return self.tombstone.beginReconnect();
    }

    pub fn onReconnectReady(self: *Bridge) void {
        self.tombstone.restore();
    }

    pub fn onReconnectFailed(self: *Bridge, reason: ?[]const u8) void {
        self.tombstone.end(reason);
    }

    pub fn inputAllowed(self: Bridge) bool {
        return self.tombstone.allowsRemoteInput();
    }
};

test "reconnect bridge keeps tombstone read only until worker ready" {
    var bridge: Bridge = .{};
    bridge.onWorkerFailure("worker failed");
    try std.testing.expect(!bridge.inputAllowed());
    try std.testing.expect(bridge.requestReconnect());
    try std.testing.expect(!bridge.inputAllowed());
    bridge.onReconnectFailed("retry failed");
    try std.testing.expect(bridge.tombstone.canReconnect());
    try std.testing.expect(bridge.requestReconnect());
    bridge.onReconnectReady();
    try std.testing.expect(bridge.inputAllowed());
}

test "bridge remains compatible with reconnect machine states" {
    const backoff = [_]u8{ 1, 2 };
    var machine = try Reconnect.Machine.init(2, &backoff);
    machine.suspect(null);
    _ = try machine.nextDelay();
    try std.testing.expectEqual(Reconnect.State.reconnecting, machine.state);
}
