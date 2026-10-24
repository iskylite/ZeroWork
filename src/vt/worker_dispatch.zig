const std = @import("std");
const Ready = @import("../platform/kqueue.zig").Ready;

pub const Handler = struct {
    ctx: *anyopaque,
    on_readable: *const fn (*anyopaque) anyerror!void,
    on_writable: *const fn (*anyopaque) anyerror!void,
    on_closed: *const fn (*anyopaque) void,
};

pub fn dispatch(ready: Ready, handler: Handler) !void {
    if (ready.error_code) |code| return errorFromCode(code);
    if (ready.readable) try handler.on_readable(handler.ctx);
    if (ready.writable) try handler.on_writable(handler.ctx);
    if (ready.eof) handler.on_closed(handler.ctx);
}

fn errorFromCode(_: i32) anyerror {
    return error.SocketEventError;
}

const Recorder = struct {
    reads: usize = 0,
    writes: usize = 0,
    closes: usize = 0,
    pub fn read(ctx: *anyopaque) !void {
        @as(*Recorder, @ptrCast(@alignCast(ctx))).reads += 1;
    }
    pub fn write(ctx: *anyopaque) !void {
        @as(*Recorder, @ptrCast(@alignCast(ctx))).writes += 1;
    }
    pub fn close(ctx: *anyopaque) void {
        @as(*Recorder, @ptrCast(@alignCast(ctx))).closes += 1;
    }
    pub fn handler(self: *Recorder) Handler {
        return .{ .ctx = self, .on_readable = read, .on_writable = write, .on_closed = close };
    }
};

test "worker dispatcher invokes readiness handlers in one event" {
    var recorder: Recorder = .{};
    try dispatch(.{ .fd = 1, .readable = true, .writable = true, .eof = true }, recorder.handler());
    try std.testing.expectEqual(@as(usize, 1), recorder.reads);
    try std.testing.expectEqual(@as(usize, 1), recorder.writes);
    try std.testing.expectEqual(@as(usize, 1), recorder.closes);
}

test "worker dispatcher rejects kernel event errors before IO" {
    var recorder: Recorder = .{};
    try std.testing.expectError(error.SocketEventError, dispatch(.{ .fd = 1, .readable = true, .error_code = 54 }, recorder.handler()));
    try std.testing.expectEqual(@as(usize, 0), recorder.reads);
}
