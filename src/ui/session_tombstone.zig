const std = @import("std");

pub const State = enum { active, ended, reconnecting };

/// UI policy for the read-only session-ended tombstone.
pub const Tombstone = struct {
    state: State = .active,
    reason: ?[]const u8 = null,

    pub fn end(self: *Tombstone, reason: ?[]const u8) void {
        self.state = .ended;
        self.reason = reason;
    }

    pub fn beginReconnect(self: *Tombstone) bool {
        if (!self.canReconnect()) return false;
        self.state = .reconnecting;
        return true;
    }

    pub fn restore(self: *Tombstone) void {
        self.state = .active;
        self.reason = null;
    }

    pub fn canReconnect(self: Tombstone) bool {
        return self.state == .ended;
    }

    pub fn reconnectLabel(self: Tombstone) []const u8 {
        return switch (self.state) {
            .ended => "重新连接",
            .reconnecting => "正在重连…",
            .active => "已连接",
        };
    }

    pub fn allowsRemoteInput(self: Tombstone) bool {
        return self.state == .active;
    }

    pub fn banner(self: Tombstone) []const u8 {
        return switch (self.state) {
            .ended => "连接已断开",
            .reconnecting => "正在重连…",
            .active => "已连接",
        };
    }
};

test "session tombstone becomes read only and can restore" {
    var tombstone: Tombstone = .{};
    try std.testing.expect(tombstone.allowsRemoteInput());
    tombstone.end("socket closed");
    try std.testing.expect(!tombstone.allowsRemoteInput());
    try std.testing.expect(tombstone.canReconnect());
    try std.testing.expectEqualStrings("重新连接", tombstone.reconnectLabel());
    try std.testing.expectEqualStrings("连接已断开", tombstone.banner());
    try std.testing.expect(tombstone.beginReconnect());
    try std.testing.expect(!tombstone.canReconnect());
    try std.testing.expect(!tombstone.allowsRemoteInput());
    try std.testing.expectEqualStrings("正在重连…", tombstone.reconnectLabel());
    try std.testing.expectEqualStrings("正在重连…", tombstone.banner());
    try std.testing.expect(!tombstone.beginReconnect());
    tombstone.restore();
    try std.testing.expect(tombstone.allowsRemoteInput());
}
