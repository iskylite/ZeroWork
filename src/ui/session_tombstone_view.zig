const std = @import("std");
const Tombstone = @import("session_tombstone.zig").Tombstone;

pub const Snapshot = struct { reconnect_visible: bool, read_only: bool, label: []const u8, banner: []const u8 };

pub fn snapshot(tombstone: Tombstone) Snapshot {
    return .{ .reconnect_visible = tombstone.canReconnect(), .read_only = !tombstone.allowsRemoteInput(), .label = tombstone.reconnectLabel(), .banner = tombstone.banner() };
}

test "tombstone snapshot exposes reconnect and read-only UI state" {
    var tombstone: Tombstone = .{};
    var current = snapshot(tombstone);
    try std.testing.expect(!current.reconnect_visible);
    try std.testing.expect(!current.read_only);
    tombstone.end("worker failed");
    current = snapshot(tombstone);
    try std.testing.expect(current.reconnect_visible);
    try std.testing.expect(current.read_only);
    try std.testing.expectEqualStrings("重新连接", current.label);
    try std.testing.expect(tombstone.beginReconnect());
    current = snapshot(tombstone);
    try std.testing.expect(!current.reconnect_visible);
    try std.testing.expect(current.read_only);
}
