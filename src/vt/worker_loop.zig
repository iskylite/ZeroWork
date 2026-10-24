const std = @import("std");
const kqueue = @import("../platform/kqueue.zig");
const Interest = @import("worker_interest.zig").Interest;
const Handler = @import("worker_dispatch.zig").Handler;
const dispatch = @import("worker_dispatch.zig").dispatch;

/// Worker-thread orchestration for one SSH socket. Protocol adapters own the
/// Session and WorkerIo; this type owns readiness registration and dispatch.
pub const Loop = struct {
    queue: kqueue.Queue,
    socket_fd: i32,
    handler: Handler,
    /// Starts fully disabled so the first setInterest() really registers the
    /// filters (Interest.read defaults to true, which would otherwise produce
    /// an empty change plan and kqueue would never wake the loop).
    interest: Interest = .{ .read = false, .write = false },
    stopped: bool = false,
    wakeup: ?*const @import("../platform/wakeup.zig").Wakeup = null,

    pub fn setWakeup(self: *Loop, wake: *const @import("../platform/wakeup.zig").Wakeup) !void {
        if (self.stopped) return error.WorkerStopped;
        try self.queue.apply(wake.read_fd, .{ .read = false }, .{ .read = true });
        self.wakeup = wake;
    }

    pub fn init(socket_fd: i32, handler: Handler) !Loop {
        return .{ .queue = try kqueue.Queue.init(), .socket_fd = socket_fd, .handler = handler };
    }
    pub fn deinit(self: *Loop) void {
        self.queue.deinit();
        self.stopped = true;
    }
    pub fn setInterest(self: *Loop, next: Interest) !void {
        if (self.stopped) return error.WorkerStopped;
        try self.queue.apply(self.socket_fd, self.interest, next);
        self.interest = next;
    }
    /// Wait once and dispatch all socket events returned by kqueue.
    pub fn step(self: *Loop, timeout_ms: u32) !void {
        if (self.stopped) return error.WorkerStopped;
        var events: [8]std.posix.Kevent = undefined;
        const ready = try self.queue.wait(&events, timeout_ms);
        for (ready) |event| {
            if (self.wakeup) |wake| if (event.ident == @as(usize, @intCast(wake.read_fd))) {
                wake.drain();
                continue;
            };
            try dispatch(kqueue.decode(event), self.handler);
        }
    }
};

test "worker loop rejects interest updates after shutdown" {
    var loop = try Loop.init(1, undefined);
    loop.deinit();
    try std.testing.expectError(error.WorkerStopped, loop.setInterest(.{}));
    var wake = try @import("../platform/wakeup.zig").Wakeup.init();
    defer wake.deinit();
    try std.testing.expectError(error.WorkerStopped, loop.setWakeup(&wake));
}

test "queued input wakes a blocked worker without socket readiness and survives loop replacement" {
    const Wakeup = @import("../platform/wakeup.zig").Wakeup;
    const InputQueue = @import("input_queue.zig").InputQueue;
    const realtime = @import("../platform/realtime.zig");
    const Fixture = struct {
        socket_events: usize = 0,
        fn event(ctx: *anyopaque) !void {
            @as(*@This(), @ptrCast(@alignCast(ctx))).socket_events += 1;
        }
        fn closed(ctx: *anyopaque) void {
            @as(*@This(), @ptrCast(@alignCast(ctx))).socket_events += 1;
        }
        fn produce(queue: *InputQueue) void {
            var delay: std.c.timespec = .{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&delay, null);
            queue.push("x") catch unreachable;
        }
    };
    var wake = try Wakeup.init();
    defer wake.deinit();
    var input = try InputQueue.init(std.testing.allocator, 16);
    defer input.deinit(std.testing.allocator);
    input.wakeup = &wake;
    var socket: [2]c_int = undefined;
    if (std.c.pipe(&socket) != 0) return error.PipeFailed;
    defer _ = std.c.close(socket[0]);
    defer _ = std.c.close(socket[1]);
    var fixture: Fixture = .{};
    const handler: Handler = .{ .ctx = &fixture, .on_readable = Fixture.event, .on_writable = Fixture.event, .on_closed = Fixture.closed };
    {
        var loop = try Loop.init(socket[0], handler);
        defer loop.deinit();
        try loop.setInterest(.{ .read = true });
        try loop.setWakeup(&wake);
        const producer = try std.Thread.spawn(.{}, Fixture.produce, .{&input});
        defer producer.join();
        const started = realtime.monotonicNs();
        try loop.step(2000);
        // A missing wake would sleep for the entire two-second timeout.
        try std.testing.expect(realtime.monotonicNs() - started < std.time.ns_per_s);
        var bytes: [16]u8 = undefined;
        try std.testing.expectEqualStrings("x", input.drain(&bytes));
        try std.testing.expectEqual(@as(usize, 0), fixture.socket_events);
        var events: [2]std.posix.Kevent = undefined;
        try std.testing.expectEqual(@as(usize, 0), (try loop.queue.wait(&events, 0)).len);
    }
    // The worker owns the pipe across transport teardown and re-registration.
    try input.push("reconnected");
    var replacement = try Loop.init(socket[0], handler);
    defer replacement.deinit();
    try replacement.setWakeup(&wake);
    const started = realtime.monotonicNs();
    try replacement.step(2000);
    try std.testing.expect(realtime.monotonicNs() - started < std.time.ns_per_s);
    var bytes: [16]u8 = undefined;
    try std.testing.expectEqualStrings("reconnected", input.drain(&bytes));
    try std.testing.expectEqual(@as(usize, 0), fixture.socket_events);
}

test "worker input wake remains pending when the notification pipe is full" {
    const Wakeup = @import("../platform/wakeup.zig").Wakeup;
    const InputQueue = @import("input_queue.zig").InputQueue;
    const Fixture = struct {
        fn unexpected(_: *anyopaque) !void {
            return error.UnexpectedSocketEvent;
        }
        fn closed(_: *anyopaque) void {
            unreachable;
        }
    };
    var wake = try Wakeup.init();
    defer wake.deinit();
    // Fill the pipe to a proven EAGAIN, rather than assuming its capacity.
    const bytes: [256]u8 = @splat('w');
    while (std.c.write(wake.write_fd, &bytes, bytes.len) >= 0) {}
    try std.testing.expectEqual(@backingInt(std.c.E.AGAIN), std.c._errno().*);
    var input = try InputQueue.init(std.testing.allocator, 8);
    defer input.deinit(std.testing.allocator);
    input.wakeup = &wake;
    try input.push("full");
    var loop = try Loop.init(-1, .{ .ctx = undefined, .on_readable = Fixture.unexpected, .on_writable = Fixture.unexpected, .on_closed = Fixture.closed });
    defer loop.deinit();
    try loop.setWakeup(&wake);
    const started = @import("../platform/realtime.zig").monotonicNs();
    try loop.step(2000);
    try std.testing.expect(@import("../platform/realtime.zig").monotonicNs() - started < std.time.ns_per_s);
    var output: [8]u8 = undefined;
    try std.testing.expectEqualStrings("full", input.drain(&output));
    var events: [2]std.posix.Kevent = undefined;
    try std.testing.expectEqual(@as(usize, 0), (try loop.queue.wait(&events, 0)).len);
    try input.push("next");
    try loop.step(2000);
    try std.testing.expectEqualStrings("next", input.drain(&output));
}
