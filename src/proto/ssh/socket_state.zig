//! Observe a stream without consuming data or changing O_NONBLOCK. A peer
//! half-close can be readable EOF without POLLHUP, especially on macOS.
const std = @import("std");

pub fn disconnected(fd: c_int) bool {
    if (fd < 0) return false;
    var descriptor = [_]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 }};
    if (std.c.poll(&descriptor, 1, 0) <= 0) return false;
    if (descriptor[0].revents & (std.c.POLL.ERR | std.c.POLL.NVAL) != 0) return true;
    if (descriptor[0].revents & std.c.POLL.IN == 0) return descriptor[0].revents & std.c.POLL.HUP != 0;
    var byte: u8 = undefined;
    return std.c.recv(fd, @ptrCast(&byte), 1, std.c.MSG.PEEK | std.c.MSG.DONTWAIT) == 0;
}

test "SFTP transport detects orderly EOF without consuming live bytes" {
    var pair: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &pair));
    defer _ = std.c.close(pair[0]);
    defer _ = std.c.close(pair[1]);
    try std.testing.expect(!disconnected(pair[0]));
    const value = [_]u8{'x'};
    try std.testing.expectEqual(@as(isize, 1), std.c.send(pair[1], &value, 1, 0));
    try std.testing.expectEqual(@as(c_int, 0), std.c.shutdown(pair[1], std.c.SHUT.WR));
    try std.testing.expect(!disconnected(pair[0]));
    var read: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 1), std.c.recv(pair[0], &read, 1, 0));
    try std.testing.expectEqual(value, read);
    try std.testing.expect(disconnected(pair[0]));
}
