const std = @import("std");

/// Liveness is authenticated SSH packet progress, never terminal output or a
/// successful local send. Run on the owning IO worker after draining reads.
pub const Watch = struct {
    last_packet: ?c_ulong = null,
    last_received_ns: i128 = 0,
    next_send_ns: i128 = 0,

    pub fn step(self: *Watch, now: i128, packet: c_ulong, interval_sec: u16) !bool {
        if (interval_sec == 0) {
            self.* = .{};
            return false;
        }
        const interval = @as(i128, @max(interval_sec, 2)) * std.time.ns_per_s;
        if (self.last_packet == null) {
            self.last_packet = packet;
            self.last_received_ns = now;
            self.next_send_ns = now + interval;
            return false;
        }
        if (self.last_packet.? != packet) {
            self.last_packet = packet;
            self.last_received_ns = now;
        }
        if (now - self.last_received_ns >= interval * 3) return error.KeepaliveTimedOut;
        return now >= self.next_send_ns;
    }

    pub fn sent(self: *Watch, now: i128, rc: c_int, interval_sec: u16) !void {
        if (rc != 0 and rc != -37) return error.KeepaliveSendFailed;
        self.next_send_ns = now + if (rc == -37) 50 * std.time.ns_per_ms else @as(i128, @max(interval_sec, 2)) * std.time.ns_per_s;
    }
};

test "keepalive requires inbound packets; local sends do not hide a blackhole" {
    var watch: Watch = .{};
    const sec = std.time.ns_per_s;
    try std.testing.expect(!try watch.step(0, 4, 2));
    try std.testing.expect(try watch.step(2 * sec, 4, 2));
    try watch.sent(2 * sec, 0, 2);
    try std.testing.expectError(error.KeepaliveTimedOut, watch.step(6 * sec, 4, 2));
    try std.testing.expect(try watch.step(6 * sec, 5, 2));
    try watch.sent(6 * sec, -37, 2);
    try std.testing.expect(!try watch.step(6 * sec + 1, 5, 2));
    try std.testing.expectError(error.KeepaliveSendFailed, watch.sent(7 * sec, -7, 2));
    try std.testing.expect(!try watch.step(100 * sec, 5, 0));
}

test "keepalive accepts sequence wrap and reset on replacement" {
    var watch: Watch = .{};
    _ = try watch.step(0, std.math.maxInt(u32), 2);
    _ = try watch.step(5 * std.time.ns_per_s, 0, 2);
    _ = try watch.step(9 * std.time.ns_per_s, 0, 2);
    watch = .{};
    try std.testing.expect(!try watch.step(100 * std.time.ns_per_s, 0, 2));
}
