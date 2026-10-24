//! Coalescing, nonblocking notification pipe. Queue contents remain the source
//! of truth. The owner closes this only after producers/consumer have stopped.
const std = @import("std");
pub const Wakeup = struct {
    read_fd: c_int,
    write_fd: c_int,
    pub fn init() !Wakeup {
        var fds: [2]c_int = undefined;
        if (std.c.pipe(&fds) != 0) return error.WakeupInitFailed;
        errdefer {
            _ = std.c.close(fds[0]);
            _ = std.c.close(fds[1]);
        }
        const nonblock: std.c.O = .{ .NONBLOCK = true };
        for (fds) |fd| {
            const flags = std.c.fcntl(fd, std.c.F.GETFL);
            if (flags < 0 or std.c.fcntl(fd, std.c.F.SETFL, flags | @as(c_int, @bitCast(nonblock))) < 0 or std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, 1)) < 0) return error.WakeupInitFailed;
        }
        return .{ .read_fd = fds[0], .write_fd = fds[1] };
    }
    pub fn deinit(self: *Wakeup) void {
        _ = std.c.close(self.read_fd);
        _ = std.c.close(self.write_fd);
        self.* = undefined;
    }
    pub fn notify(self: *const Wakeup) void {
        // EAGAIN means a wake is already pending; never block an input producer.
        while (std.c.write(self.write_fd, "w", 1) < 0) {
            if (std.c._errno().* != @backingInt(std.c.E.INTR)) break;
        }
    }
    pub fn drain(self: *const Wakeup) void {
        var bytes: [256]u8 = undefined;
        while (true) {
            if (std.c.read(self.read_fd, &bytes, bytes.len) > 0) continue;
            if (std.c._errno().* == @backingInt(std.c.E.INTR)) continue;
            break;
        }
    }
    pub fn wait(self: *const Wakeup, fd: c_int, writable: bool, timeout_ms: c_int) void {
        self.waitExtra(fd, writable, -1, false, timeout_ms);
    }
    pub fn waitExtra(self: *const Wakeup, fd: c_int, writable: bool, extra_fd: c_int, extra_writable: bool, timeout_ms: c_int) void {
        var fds = [_]std.c.pollfd{
            .{ .fd = self.read_fd, .events = std.c.POLL.IN, .revents = 0 },
            .{ .fd = extra_fd, .events = std.c.POLL.IN | (if (extra_writable) @as(c_short, std.c.POLL.OUT) else 0), .revents = 0 },
            .{ .fd = fd, .events = std.c.POLL.IN | (if (writable) @as(c_short, std.c.POLL.OUT) else 0), .revents = 0 },
        };
        _ = std.c.poll(&fds, fds.len, timeout_ms);
        self.drain();
    }
};

test "notification survives notify before wait and drains coalesced bursts" {
    var wake = try Wakeup.init();
    defer wake.deinit();
    for (0..10000) |_| wake.notify();
    var fds = [_]std.c.pollfd{.{ .fd = wake.read_fd, .events = std.c.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(c_int, 1), std.c.poll(&fds, 1, 0));
    wake.wait(-1, false, 1000);
    try std.testing.expectEqual(@as(c_int, 0), std.c.poll(&fds, 1, 0));
    wake.notify();
    try std.testing.expectEqual(@as(c_int, 1), std.c.poll(&fds, 1, 0));
}
