//! Asynchronous SOCKS5 CONNECT probe. Only contacts a local listener; the caller
//! supplies the actual target through that listener (never a public default).
//! A success proves SOCKS negotiation and remote TCP CONNECT, not HTTP/TLS health.
//! poll() borrows Job-owned result; takeResult() transfers its owned host string.
const std = @import("std");
const builtin = @import("builtin");
const socks = @import("socks5.zig");

pub const Options = struct {
    local_port: u16,
    target_host: []const u8,
    target_port: u16,
    timeout_ms: u32 = 5000,
};
pub const Status = enum { succeeded, failed, timed_out, cancelled };
pub const Result = struct {
    allocator: std.mem.Allocator,
    target_host: []const u8,
    target_port: u16,
    local_port: u16,
    status: Status = .failed,
    elapsed_ms: u64 = 0,
    failure: ?anyerror = null,
    reply: ?socks.Reply = null,
    pub fn deinit(self: *Result) void {
        self.allocator.free(self.target_host);
        self.* = undefined;
    }
};
const SockaddrIn = if (builtin.os.tag == .linux) extern struct {
    family: u16 = std.c.AF.INET,
    port: u16 = 0,
    addr: u32 = 0,
    zero: [8]u8 = @splat(0),
} else extern struct {
    len: u8 = 16,
    family: u8 = std.c.AF.INET,
    port: u16 = 0,
    addr: u32 = 0,
    zero: [8]u8 = @splat(0),
};
fn nowMs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

pub const Job = struct {
    allocator: std.mem.Allocator,
    result: ?Result,
    timeout_ms: u32,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),
    deadline: u64 = 0,

    pub fn start(allocator: std.mem.Allocator, options: Options) !*Job {
        if (options.local_port == 0 or options.target_port == 0 or options.timeout_ms == 0 or options.target_host.len == 0 or options.target_host.len > 255 or std.mem.indexOfScalar(u8, options.target_host, 0) != null) return error.InvalidOptions;
        const host = try allocator.dupe(u8, options.target_host);
        errdefer allocator.free(host);
        const self = try allocator.create(Job);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .timeout_ms = options.timeout_ms, .result = .{ .allocator = allocator, .target_host = host, .target_port = options.target_port, .local_port = options.local_port } };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    pub fn cancel(self: *Job) void {
        self.cancelled.store(true, .release);
    }
    pub fn poll(self: *Job) ?*const Result {
        if (!self.done.load(.acquire)) return null;
        if (self.result) |*result| return result;
        return null;
    }
    pub fn takeResult(self: *Job) ?Result {
        if (!self.done.load(.acquire)) return null;
        if (self.thread) |thread| thread.join();
        self.thread = null;
        const result = self.result;
        self.result = null;
        return result;
    }
    /// Cancellation is checked every <=25ms in all socket waits; no UI worker IO.
    pub fn deinit(self: *Job) void {
        self.cancel();
        if (self.thread) |thread| thread.join();
        if (self.result) |*result| result.deinit();
        self.allocator.destroy(self);
    }
    fn run(self: *Job) void {
        const started = nowMs();
        self.deadline = started + self.timeout_ms;
        self.probe() catch |err| {
            self.result.?.failure = err;
            self.result.?.status = switch (err) {
                error.Cancelled => .cancelled,
                error.TimedOut => .timed_out,
                else => .failed,
            };
        };
        self.result.?.elapsed_ms = nowMs() -| started;
        self.done.store(true, .release);
    }
    fn guard(self: *Job) !void {
        if (self.cancelled.load(.acquire)) return error.Cancelled;
        if (nowMs() >= self.deadline) return error.TimedOut;
    }
    fn wait(self: *Job, fd: std.posix.fd_t, events: i16) !void {
        while (true) {
            try self.guard();
            var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
            const remaining = self.deadline -| nowMs();
            const ready = std.posix.poll(&fds, @intCast(@min(remaining, 25))) catch return error.PollFailed;
            if (ready == 0) continue;
            if (fds[0].revents & std.posix.POLL.NVAL != 0) return error.SocketClosed;
            return;
        }
    }
    fn readExact(self: *Job, fd: std.posix.fd_t, bytes: []u8) !void {
        var cursor: usize = 0;
        while (cursor < bytes.len) {
            try self.wait(fd, std.posix.POLL.IN);
            const n = std.posix.read(fd, bytes[cursor..]) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            if (n == 0) return error.EndOfStream;
            cursor += n;
        }
    }
    fn writeAll(self: *Job, fd: std.posix.fd_t, bytes: []const u8) !void {
        var cursor: usize = 0;
        while (cursor < bytes.len) {
            try self.wait(fd, std.posix.POLL.OUT);
            const rc = std.c.send(fd, bytes.ptr + cursor, bytes.len - cursor, if (builtin.os.tag == .linux) std.c.MSG.NOSIGNAL else 0);
            if (rc < 0) {
                switch (std.c.errno(rc)) {
                    .AGAIN, .INTR => continue,
                    else => return error.WriteFailed,
                }
            }
            if (rc == 0) return error.EndOfStream;
            cursor += @intCast(rc);
        }
    }
    fn probe(self: *Job) !void {
        try self.guard();
        const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketCreateFailed;
        defer _ = std.c.close(fd);
        if (builtin.os.tag == .macos) {
            const one: c_int = 1;
            _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.NOSIGPIPE, @ptrCast(&one), @sizeOf(c_int));
        }
        const flags = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
        if (flags < 0) return error.SocketConfigureFailed;
        const nonblock: std.c.O = .{ .NONBLOCK = true };
        if (std.c.fcntl(fd, std.c.F.SETFL, flags | @as(c_int, @bitCast(nonblock))) < 0) return error.SocketConfigureFailed;
        var address: SockaddrIn = .{ .port = std.mem.nativeToBig(u16, self.result.?.local_port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        const rc = std.c.connect(fd, @ptrCast(&address), @sizeOf(SockaddrIn));
        if (rc != 0) {
            if (std.c.errno(rc) != .INPROGRESS) return error.ConnectFailed;
            try self.wait(fd, std.posix.POLL.OUT);
            var socket_error: c_int = 0;
            var length: std.c.socklen_t = @sizeOf(c_int);
            if (std.c.getsockopt(fd, std.c.SOL.SOCKET, std.c.SO.ERROR, @ptrCast(&socket_error), &length) != 0 or socket_error != 0) return error.ConnectFailed;
        }
        var frame: [512]u8 = undefined;
        try self.writeAll(fd, try socks.Codec.greeting(&.{.no_auth}, &frame));
        var selected: [2]u8 = undefined;
        try self.readExact(fd, &selected);
        if (selected[0] != socks.version) return error.InvalidMethodResponse;
        if (selected[1] != @backingInt(socks.Method.no_auth)) return error.MethodRejected;
        try self.writeAll(fd, try socks.Codec.encodeConnectRequest(.{ .command = .connect, .address = .{ .domain = self.result.?.target_host }, .port = self.result.?.target_port }, &frame));
        try self.readExact(fd, frame[0..4]);
        if (frame[0] != socks.version or frame[2] != 0 or frame[1] > 8) return error.InvalidConnectResponse;
        var total: usize = 0;
        switch (frame[3]) {
            1 => total = 10,
            4 => total = 22,
            3 => {
                try self.readExact(fd, frame[4..5]);
                total = 7 + @as(usize, frame[4]);
            },
            else => return error.InvalidConnectResponse,
        }
        const prefix: usize = if (frame[3] == 3) 5 else 4;
        try self.readExact(fd, frame[prefix..total]);
        // Codec historically requires >=10 bytes even for short domain replies.
        // Wire-valid domain replies shorter than that are classified locally.
        const reply: socks.Reply = @fromBackingInt(@intCast(frame[1]));
        self.result.?.reply = reply;
        if (reply != .succeeded) return error.ConnectRejected;
        try self.guard();
        self.result.?.status = .succeeded;
    }
};

const Fake = struct {
    fd: std.posix.fd_t,
    port: u16,
    mode: enum { success, rejected_method, refused, stalled, malformed, fragmented },
    thread: ?std.Thread = null,
    fn init(mode: @FieldType(Fake, "mode")) !Fake {
        const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketCreateFailed;
        errdefer _ = std.c.close(fd);
        var address: SockaddrIn = .{ .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        if (std.c.bind(fd, @ptrCast(&address), @sizeOf(SockaddrIn)) != 0 or std.c.listen(fd, 1) != 0) return error.ListenFailed;
        var length: std.c.socklen_t = @sizeOf(SockaddrIn);
        if (std.c.getsockname(fd, @ptrCast(&address), &length) != 0) return error.SocketNameFailed;
        return .{ .fd = fd, .port = std.mem.bigToNative(u16, address.port), .mode = mode };
    }
    fn start(self: *Fake) !void {
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }
    fn deinit(self: *Fake) void {
        if (self.thread) |thread| thread.join();
        _ = std.c.close(self.fd);
    }
    fn read(fd: std.posix.fd_t, bytes: []u8) bool {
        var cursor: usize = 0;
        while (cursor < bytes.len) {
            var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
            if ((std.posix.poll(&fds, 1000) catch return false) == 0) return false;
            const rc = std.c.read(fd, bytes.ptr + cursor, bytes.len - cursor);
            if (rc <= 0) return false;
            cursor += @intCast(rc);
        }
        return true;
    }
    fn serve(self: *Fake) void {
        const fd = std.c.accept(self.fd, null, null);
        if (fd < 0) return;
        defer _ = std.c.close(fd);
        if (builtin.os.tag == .macos) {
            const one: c_int = 1;
            _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.NOSIGPIPE, @ptrCast(&one), @sizeOf(c_int));
        }
        var greeting: [3]u8 = undefined;
        if (!read(fd, &greeting) or !std.mem.eql(u8, &greeting, &.{ 5, 1, 0 })) return;
        if (self.mode == .stalled) {
            const delay: std.c.timespec = .{ .sec = 0, .nsec = 150_000_000 };
            _ = std.c.nanosleep(&delay, null);
            return;
        }
        const method = [_]u8{ 5, if (self.mode == .rejected_method) 255 else 0 };
        if (std.c.write(fd, &method, method.len) != method.len or self.mode == .rejected_method) return;
        var request: [512]u8 = undefined;
        if (!read(fd, request[0..5]) or !std.mem.eql(u8, request[0..4], &.{ 5, 1, 0, 3 })) return;
        const len: usize = request[4];
        if (!read(fd, request[5 .. 7 + len])) return;
        if (!std.mem.eql(u8, request[5 .. 5 + len], "controlled.local") or std.mem.readInt(u16, request[5 + len ..][0..2], .big) != 2222) return;
        var reply = [_]u8{ 5, if (self.mode == .refused) 5 else 0, 0, 1, 127, 0, 0, 1, 0, 0 };
        if (self.mode == .malformed) reply[1] = 255;
        if (self.mode == .fragmented) {
            for (reply) |byte| {
                const one = [_]u8{byte};
                if (std.c.write(fd, &one, 1) != 1) return;
            }
        } else {
            _ = std.c.write(fd, &reply, reply.len);
        }
    }
};
fn waitJob(job: *Job) !*const Result {
    const deadline = nowMs() + 2000;
    while (job.poll() == null) {
        if (nowMs() >= deadline) return error.TestTimedOut;
        const delay: std.c.timespec = .{ .sec = 0, .nsec = 1_000_000 };
        _ = std.c.nanosleep(&delay, null);
    }
    return job.poll().?;
}

test "probe uses actual SOCKS CONNECT and owns results after take" {
    var fake = try Fake.init(.success);
    defer fake.deinit();
    try fake.start();
    const job = try Job.start(std.testing.allocator, .{ .local_port = fake.port, .target_host = "controlled.local", .target_port = 2222 });
    try std.testing.expectEqual(Status.succeeded, (try waitJob(job)).status);
    var result = job.takeResult().?;
    job.deinit();
    defer result.deinit();
    try std.testing.expectEqualStrings("controlled.local", result.target_host);
    try std.testing.expectEqual(socks.Reply.succeeded, result.reply.?);
}

test "probe distinguishes method rejection CONNECT refusal malformed response and timeout" {
    const cases = [_]struct { mode: @FieldType(Fake, "mode"), status: Status, failure: anyerror }{
        .{ .mode = .rejected_method, .status = .failed, .failure = error.MethodRejected },
        .{ .mode = .refused, .status = .failed, .failure = error.ConnectRejected },
        .{ .mode = .malformed, .status = .failed, .failure = error.InvalidConnectResponse },
        .{ .mode = .stalled, .status = .timed_out, .failure = error.TimedOut },
    };
    for (cases) |case| {
        var fake = try Fake.init(case.mode);
        defer fake.deinit();
        try fake.start();
        const job = try Job.start(std.testing.allocator, .{ .local_port = fake.port, .target_host = "controlled.local", .target_port = 2222, .timeout_ms = 70 });
        defer job.deinit();
        const result = try waitJob(job);
        try std.testing.expectEqual(case.status, result.status);
        try std.testing.expectEqual(case.failure, result.failure.?);
    }
}

test "probe cancellation and fragmented protocol responses" {
    for ([_]@FieldType(Fake, "mode"){ .stalled, .fragmented }) |mode| {
        var fake = try Fake.init(mode);
        defer fake.deinit();
        try fake.start();
        const job = try Job.start(std.testing.allocator, .{ .local_port = fake.port, .target_host = "controlled.local", .target_port = 2222 });
        defer job.deinit();
        if (mode == .stalled) job.cancel();
        try std.testing.expectEqual(if (mode == .stalled) Status.cancelled else Status.succeeded, (try waitJob(job)).status);
        // Cancellation may precede connect. Wake the fake accept without external IO.
        if (mode == .stalled) {
            const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
            defer _ = std.c.close(fd);
            var address: SockaddrIn = .{ .port = std.mem.nativeToBig(u16, fake.port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
            _ = std.c.connect(fd, @ptrCast(&address), @sizeOf(SockaddrIn));
        }
    }
}

test "listening address alone does not imply working proxy" {
    // Reserve an ephemeral loopback port without listening; connect must fail.
    const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketCreateFailed;
    defer _ = std.c.close(fd);
    var address: SockaddrIn = .{ .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (std.c.bind(fd, @ptrCast(&address), @sizeOf(SockaddrIn)) != 0) return error.BindFailed;
    var length: std.c.socklen_t = @sizeOf(SockaddrIn);
    if (std.c.getsockname(fd, @ptrCast(&address), &length) != 0) return error.SocketNameFailed;
    const job = try Job.start(std.testing.allocator, .{ .local_port = std.mem.bigToNative(u16, address.port), .target_host = "controlled.local", .target_port = 2222, .timeout_ms = 100 });
    defer job.deinit();
    const result = try waitJob(job);
    try std.testing.expect(result.status == .failed or result.status == .timed_out);
}

test "probe validates explicit endpoint options" {
    try std.testing.expectError(error.InvalidOptions, Job.start(std.testing.allocator, .{ .local_port = 1080, .target_host = "", .target_port = 22 }));
    try std.testing.expectError(error.InvalidOptions, Job.start(std.testing.allocator, .{ .local_port = 1080, .target_host = "controlled.local", .target_port = 22, .timeout_ms = 0 }));
}
