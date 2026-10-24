const std = @import("std");
const Interest = @import("../vt/worker_interest.zig").Interest;
const planner = @import("kqueue_plan.zig");

pub const Ready = struct {
    fd: i32,
    readable: bool = false,
    writable: bool = false,
    eof: bool = false,
    error_code: ?i32 = null,
};

pub fn decode(event: std.posix.Kevent) Ready {
    return .{
        .fd = @intCast(event.ident),
        .readable = event.filter == std.c.EVFILT.READ,
        .writable = event.filter == std.c.EVFILT.WRITE,
        .eof = event.flags & std.c.EV.EOF != 0,
        .error_code = if (event.flags & std.c.EV.ERROR != 0 and event.data != 0) @intCast(event.data) else null,
    };
}

pub const Queue = struct {
    fd: i32,

    pub fn init() !Queue {
        const fd = std.c.kqueue();
        if (fd < 0) return error.KqueueFailed;
        return .{ .fd = fd };
    }
    pub fn deinit(self: *Queue) void {
        _ = std.c.close(self.fd);
        self.* = undefined;
    }

    pub fn apply(self: Queue, socket_fd: i32, previous: Interest, next: Interest) !void {
        var changes_buf: [2]planner.Change = undefined;
        const changes = planner.plan(previous, next, &changes_buf);
        if (changes.len == 0) return;
        var event_buf: [2]std.posix.Kevent = undefined;
        const encoded = planner.encodeDarwin(socket_fd, changes, &event_buf);
        const rc = std.c.kevent(self.fd, encoded.ptr, @intCast(encoded.len), event_buf[0..].ptr, 0, null);
        if (rc < 0) return error.KeventFailed;
    }

    pub fn wait(self: Queue, events: []std.posix.Kevent, timeout_ms: u32) ![]std.posix.Kevent {
        const timeout: std.posix.timespec = .{ .sec = timeout_ms / 1000, .nsec = @as(isize, @intCast(timeout_ms % 1000)) * std.time.ns_per_ms };
        const count = std.c.kevent(self.fd, events.ptr, 0, events.ptr, @intCast(events.len), &timeout);
        if (count < 0) return error.KeventFailed;
        return events[0..@intCast(count)];
    }
};

test "kqueue accepts read and write interest transitions" {
    var queue = try Queue.init();
    defer queue.deinit();
    var pipe: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&pipe) != 0) return error.PipeFailed;
    defer _ = std.c.close(pipe[0]);
    defer _ = std.c.close(pipe[1]);
    try queue.apply(pipe[0], .{ .read = false }, .{ .read = true });
    try queue.apply(pipe[0], .{ .read = true }, .{ .read = false });
    try queue.apply(pipe[1], .{}, .{ .write = true });
    try queue.apply(pipe[1], .{ .write = true }, .{});
}

test "kqueue wait reports readable pipe data" {
    var queue = try Queue.init();
    defer queue.deinit();
    var pipe: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&pipe) != 0) return error.PipeFailed;
    defer _ = std.c.close(pipe[0]);
    defer _ = std.c.close(pipe[1]);
    try queue.apply(pipe[0], .{ .read = false }, .{ .read = true });
    if (std.c.write(pipe[1], "x".ptr, 1) < 0) return error.WriteFailed;
    var events: [2]std.posix.Kevent = undefined;
    const ready = try queue.wait(&events, 50);
    try std.testing.expectEqual(@as(usize, 1), ready.len);
    try std.testing.expectEqual(@as(usize, @intCast(pipe[0])), ready[0].ident);
    try std.testing.expectEqual(@as(i16, std.c.EVFILT.READ), ready[0].filter);
    const decoded = decode(ready[0]);
    try std.testing.expect(decoded.readable and !decoded.writable);
    try std.testing.expectEqual(pipe[0], decoded.fd);
}

test "kqueue decoder exposes eof and error flags" {
    const event: std.posix.Kevent = .{ .ident = 7, .filter = std.c.EVFILT.WRITE, .flags = std.c.EV.EOF | std.c.EV.ERROR, .fflags = 0, .data = 54, .udata = 0 };
    const decoded = decode(event);
    try std.testing.expect(decoded.writable and decoded.eof);
    try std.testing.expectEqual(@as(?i32, 54), decoded.error_code);
}
