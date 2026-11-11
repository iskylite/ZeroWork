//! A loopback-only SOCKS5 pump over a generation-bound stream provider. One
//! thread owns accepted sockets and forwarding; only the fixed opener pool
//! calls the provider's blocking open.
const std = @import("std");
const builtin = @import("builtin");
const handshake = @import("web_socks_handshake.zig");
const socks = @import("socks5.zig");
const c = std.c;

pub const Credentials = handshake.Credentials;
pub const Target = handshake.Target;
pub const max_handshakes = 16;
pub const max_pending = 16;
pub const max_openers = 2;
const poll_interval_ms = 15;
const handshake_timeout_ms = 10_000;
const write_timeout_ms = 30_000;
const buffer_size = 16 * 1024;

pub const Counts = packed struct(u32) {
    handshakes: u8 = 0,
    /// Includes requests assigned to an opener.
    pending: u8 = 0,
    opening: u8 = 0,
    active: u8 = 0,
};

pub fn Pump(comptime Stream: type, comptime max_active: usize) type {
    return struct {
        const Self = @This();
        const max_clients = max_handshakes + max_pending + max_active;

        pub const Backend = struct {
            context: *anyopaque,
            open: *const fn (*anyopaque, Target) anyerror!Stream,
            available: *const fn (*anyopaque) bool,
        };

        const Client = struct {
            socket: c.fd_t = -1,
            protocol: handshake.Handshake = .{},
            queued: bool = false,
            opener: ?usize = null,
            stream: ?Stream = null,
            deadline_ms: u64 = 0,
            upload: Direction = .{},
            download: Direction = .{},

            fn close(self: *Client) void {
                if (self.stream) |*stream| stream.close();
                if (self.socket >= 0) _ = c.close(self.socket);
                self.protocol.clear();
                self.socket = -1;
                self.stream = null;
            }
        };

        const Opener = struct {
            job: ?Job = null,
            result: ?anyerror!Stream = null,
            thread: ?std.Thread = null,
        };
        const Job = struct { client_index: usize, target: Target };

        credentials: Credentials,
        backend: Backend,
        cancelled: *std.atomic.Value(bool),
        timeout_ms: u32,
        // Published separately from the allocator-owned client table.
        port: std.atomic.Value(u16) = .init(0),
        counts: std.atomic.Value(Counts) = .init(.{}),
        clients: [max_clients]Client = @splat(.{}),
        next_candidate: usize = 0,
        mutex: c.pthread_mutex_t = .{},
        cond: c.pthread_cond_t = .{},
        openers: [max_openers]Opener = @splat(.{}),
        acceptance_worker_ids: ?*[max_openers]std.atomic.Value(std.Thread.Id) = null,

        /// Run on a worker. On return all client sockets, the listener and
        /// opener workers have stopped, including on partial startup failure.
        /// Provider opens must observe the shared cancellation flag.
        pub fn run(self: *Self, requested_port: u16, on_ready: *const fn (*anyopaque) void) !void {
            var listen_fd: c.fd_t = -1;
            defer {
                self.cancelled.store(true, .release);
                if (listen_fd >= 0) _ = c.close(listen_fd);
                for (&self.clients) |*client| if (client.socket >= 0) client.close();
                self.finishOpeners();
                self.counts.store(.{}, .release);
                self.port.store(0, .release);
                _ = c.pthread_cond_destroy(&self.cond);
                _ = c.pthread_mutex_destroy(&self.mutex);
            }
            const listener = try openListener(requested_port);
            listen_fd = listener.fd;
            for (&self.openers, 0..) |*opener, index| opener.thread = try std.Thread.spawn(.{}, openWorker, .{ self, index });
            self.port.store(listener.port, .release);
            on_ready(self.backend.context);

            var poll_fds: [1 + 2 * max_clients]c.pollfd = undefined;
            while (!self.cancelled.load(.acquire)) {
                if (!self.backend.available(self.backend.context)) return error.TransportDisconnected;
                const now = nowMs();
                self.collectResults();
                for (&self.clients, 0..) |*client, index| {
                    const socket_poll = &poll_fds[1 + 2 * index];
                    const stream_poll = &poll_fds[2 + 2 * index];
                    socket_poll.* = .{ .fd = -1, .events = 0, .revents = 0 };
                    stream_poll.* = .{ .fd = -1, .events = 0, .revents = 0 };
                    if (client.socket < 0 or client.opener != null) continue;
                    if (client.protocol.phase == .stream) {
                        if (client.upload.timedOut(now) or client.download.timedOut(now)) {
                            client.close();
                            continue;
                        }
                    } else if (now >= client.deadline_ms) {
                        if (client.protocol.phase == .opening and client.protocol.pendingReply().len == 0) {
                            client.protocol.finishConnect(.ttl_expired);
                            client.deadline_ms = now + write_timeout_ms;
                        } else {
                            client.close();
                            continue;
                        }
                    }
                    if (client.protocol.phase == .stream) {
                        socket_poll.* = .{
                            .fd = client.socket,
                            .events = client.upload.readEvents() | client.download.writeEvents(),
                            .revents = 0,
                        };
                        stream_poll.* = .{
                            .fd = client.stream.?.fd,
                            .events = client.download.readEvents() | client.upload.writeEvents(),
                            .revents = 0,
                        };
                        // An fd with zero interests can still return HUP and
                        // spin while the opposite direction drains.
                        if (socket_poll.events == 0) socket_poll.fd = -1;
                        if (stream_poll.events == 0) stream_poll.fd = -1;
                    } else if (client.protocol.pendingReply().len != 0) {
                        socket_poll.* = .{ .fd = client.socket, .events = c.POLL.OUT, .revents = 0 };
                    } else if (client.protocol.phase != .opening) {
                        socket_poll.* = .{ .fd = client.socket, .events = c.POLL.IN, .revents = 0 };
                    }
                }
                var stats = self.clientCounts();
                self.assignOpeners(&stats);
                self.counts.store(stats, .release);
                poll_fds[0] = .{ .fd = listener.fd, .events = if (stats.handshakes < max_handshakes) c.POLL.IN else 0, .revents = 0 };
                const ready = c.poll(&poll_fds, poll_fds.len, poll_interval_ms);
                if (ready < 0 and c.errno(ready) != .INTR) return error.ProxyPollFailed;
                if (ready <= 0 or self.cancelled.load(.acquire)) continue;
                if (poll_fds[0].revents & invalid_poll != 0) return error.ProxyListenerFailed;
                if (poll_fds[0].revents & c.POLL.IN != 0) try self.acceptClients(listener.fd, stats.handshakes, now);
                for (&self.clients, 0..) |*client, index| {
                    const socket_poll = poll_fds[1 + 2 * index];
                    const stream_poll = poll_fds[2 + 2 * index];
                    if (socket_poll.revents == 0 and stream_poll.revents == 0) continue;
                    self.stepClient(client, socket_poll.revents, stream_poll.revents, nowMs()) catch client.close();
                }
            }
        }

        fn stepClient(self: *Self, client: *Client, socket_events: c_short, stream_events: c_short, now: u64) !void {
            if (self.cancelled.load(.acquire)) return error.Cancelled;
            if ((socket_events | stream_events) & invalid_poll != 0) return error.ProxySocketFailed;
            if (client.protocol.phase == .stream) {
                const destination = client.stream.?.fd;
                try client.upload.step(client.socket, destination, socket_events, stream_events, now);
                try client.download.step(destination, client.socket, stream_events, socket_events, now);
                if (client.upload.shutdown and client.download.shutdown) client.close();
                return;
            }
            const reply = client.protocol.pendingReply();
            if (reply.len != 0) {
                if (try writeSome(client.socket, reply)) |count| client.protocol.replySent(count);
                if (client.protocol.phase == .closed) client.close();
                return;
            }
            const input = client.protocol.readBuffer();
            const count = (try readSome(client.socket, input)) orelse return;
            if (count == 0) return error.ClientDisconnected;
            client.protocol.received(count, &self.credentials);
            if (client.protocol.phase != .opening) return;
            const counts = self.clientCounts();
            if (counts.pending >= max_pending) {
                client.protocol.finishConnect(.not_allowed);
            } else {
                client.queued = true;
                client.deadline_ms = now + self.timeout_ms;
            }
        }

        fn acceptClients(self: *Self, listener: c.fd_t, initial: u8, now: u64) !void {
            var accepted = initial;
            for (&self.clients) |*client| {
                if (accepted == max_handshakes or self.cancelled.load(.acquire)) break;
                if (client.socket >= 0) continue;
                const fd = c.accept(listener, null, null);
                if (fd < 0) {
                    switch (c.errno(fd)) {
                        .AGAIN => break,
                        .INTR, .CONNABORTED => continue,
                        else => return error.ProxyAcceptFailed,
                    }
                }
                configureSocket(fd) catch {
                    _ = c.close(fd);
                    continue;
                };
                client.* = .{ .socket = fd, .deadline_ms = now + handshake_timeout_ms };
                accepted += 1;
            }
        }

        fn clientCounts(self: *const Self) Counts {
            var stats: Counts = .{};
            for (&self.clients) |*client| {
                if (client.socket < 0) continue;
                if (client.stream != null) {
                    stats.active += 1;
                } else if (client.queued) {
                    stats.pending += 1;
                    if (client.opener != null) stats.opening += 1;
                } else {
                    stats.handshakes += 1;
                }
            }
            return stats;
        }

        fn assignOpeners(self: *Self, stats: *Counts) void {
            _ = c.pthread_mutex_lock(&self.mutex);
            defer _ = c.pthread_mutex_unlock(&self.mutex);
            for (&self.openers, 0..) |*opener, index| {
                if (self.cancelled.load(.acquire) or stats.active + stats.opening >= max_active) break;
                if (opener.job != null) continue;
                for (0..max_clients) |offset| {
                    const client_index = (self.next_candidate + offset) % max_clients;
                    const client = &self.clients[client_index];
                    if (client.socket < 0 or !client.queued or client.opener != null or client.protocol.phase != .opening or client.protocol.pendingReply().len != 0) continue;
                    client.opener = index;
                    opener.job = .{ .client_index = client_index, .target = client.protocol.target };
                    self.next_candidate = (client_index + 1) % max_clients;
                    stats.opening += 1;
                    _ = c.pthread_cond_broadcast(&self.cond);
                    break;
                }
            }
        }

        fn collectResults(self: *Self) void {
            for (&self.openers) |*opener| {
                _ = c.pthread_mutex_lock(&self.mutex);
                const result = opener.result orelse {
                    _ = c.pthread_mutex_unlock(&self.mutex);
                    continue;
                };
                const client = &self.clients[opener.job.?.client_index];
                opener.result = null;
                opener.job = null;
                _ = c.pthread_mutex_unlock(&self.mutex);
                client.opener = null;
                const stream = result catch |err| {
                    client.protocol.finishConnect(socksReply(err));
                    client.deadline_ms = nowMs() + write_timeout_ms;
                    continue;
                };
                configureSocket(stream.fd) catch {
                    var owned = stream;
                    owned.close();
                    client.protocol.finishConnect(.general_failure);
                    client.deadline_ms = nowMs() + write_timeout_ms;
                    continue;
                };
                client.stream = stream;
                client.protocol.finishConnect(.succeeded);
                client.deadline_ms = nowMs() + write_timeout_ms;
            }
        }

        fn openWorker(self: *Self, index: usize) void {
            const opener = &self.openers[index];
            if (self.acceptance_worker_ids) |ids| ids[index].store(std.Thread.getCurrentId(), .release);
            while (true) {
                _ = c.pthread_mutex_lock(&self.mutex);
                while (!self.cancelled.load(.acquire) and (opener.job == null or opener.result != null)) {
                    _ = c.pthread_cond_wait(&self.cond, &self.mutex);
                }
                if (self.cancelled.load(.acquire)) {
                    _ = c.pthread_mutex_unlock(&self.mutex);
                    return;
                }
                const job = opener.job.?;
                _ = c.pthread_mutex_unlock(&self.mutex);

                // Second check after dequeue, before crossing into the
                // provider. OwnedTransport rechecks the same cancellation
                // flag as it admits the stream on its own mailbox lock.
                const result = if (self.cancelled.load(.acquire)) error.Cancelled else self.backend.open(self.backend.context, job.target);
                _ = c.pthread_mutex_lock(&self.mutex);
                opener.result = result;
                _ = c.pthread_mutex_unlock(&self.mutex);
            }
        }

        fn finishOpeners(self: *Self) void {
            _ = c.pthread_mutex_lock(&self.mutex);
            _ = c.pthread_cond_broadcast(&self.cond);
            _ = c.pthread_mutex_unlock(&self.mutex);
            for (&self.openers) |*opener| {
                if (opener.thread) |thread| thread.join();
                if (opener.result) |result| {
                    if (result) |stream| {
                        var owned = stream;
                        owned.close();
                    } else |_| {}
                }
                opener.* = .{};
            }
        }
    };
}

const invalid_poll = c.POLL.ERR | c.POLL.NVAL;
const readable = c.POLL.IN | c.POLL.HUP;

const Direction = struct {
    bytes: [buffer_size]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    eof: bool = false,
    shutdown: bool = false,
    write_deadline_ms: u64 = 0,

    fn readEvents(self: *const Direction) c_short {
        return if (!self.eof and self.start == self.end) c.POLL.IN else 0;
    }

    fn writeEvents(self: *const Direction) c_short {
        return if (self.start != self.end) c.POLL.OUT else 0;
    }

    fn timedOut(self: *const Direction, now: u64) bool {
        return self.start != self.end and now >= self.write_deadline_ms;
    }

    fn step(self: *Direction, from: c.fd_t, to: c.fd_t, read_events: c_short, write_events: c_short, now: u64) !void {
        if (self.timedOut(now)) return error.ProxyWriteTimeout;
        if (self.readEvents() != 0 and read_events & readable != 0) {
            if (try readSome(from, &self.bytes)) |count| {
                self.start = 0;
                self.end = count;
                self.eof = count == 0;
                self.write_deadline_ms = now + write_timeout_ms;
            }
        }
        if (self.writeEvents() != 0 and write_events & (c.POLL.OUT | c.POLL.HUP) != 0) {
            if (try writeSome(to, self.bytes[self.start..self.end])) |count| {
                self.start += count;
                self.write_deadline_ms = now + write_timeout_ms;
            }
        }
        if (self.eof and !self.shutdown and self.start == self.end) {
            _ = c.shutdown(to, c.SHUT.WR);
            self.shutdown = true;
        }
    }
};

fn socksReply(err: anyerror) socks.Reply {
    return switch (err) {
        error.StreamLimit, error.Cancelled => .not_allowed,
        error.StreamOpenTimeout => .ttl_expired,
        error.ConnectionRefused => .connection_refused,
        error.TransportClosed, error.TransportDisconnected => .network_unreachable,
        else => .general_failure,
    };
}

const SockaddrIn = if (builtin.os.tag == .linux) extern struct {
    family: u16 = c.AF.INET,
    port: u16,
    address: [4]u8 = .{ 127, 0, 0, 1 },
    zero: [8]u8 = @splat(0),
} else extern struct {
    len: u8 = 16,
    family: u8 = c.AF.INET,
    port: u16,
    address: [4]u8 = .{ 127, 0, 0, 1 },
    zero: [8]u8 = @splat(0),
};

fn openListener(requested_port: u16) !struct { fd: c.fd_t, port: u16 } {
    const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (fd < 0) return error.ProxySocketUnavailable;
    errdefer _ = c.close(fd);
    try configureSocket(fd);
    const one: c_int = 1;
    if (c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, @ptrCast(&one), @sizeOf(c_int)) != 0) return error.ProxySocketOptionsFailed;
    var address: SockaddrIn = .{ .port = std.mem.nativeToBig(u16, requested_port) };
    if (c.bind(fd, @ptrCast(&address), @sizeOf(SockaddrIn)) != 0) return error.ProxyBindFailed;
    if (c.listen(fd, max_handshakes) != 0) return error.ProxyListenFailed;
    var address_len: c.socklen_t = @sizeOf(SockaddrIn);
    if (c.getsockname(fd, @ptrCast(&address), &address_len) != 0) return error.ProxyAddressUnavailable;
    return .{ .fd = fd, .port = std.mem.bigToNative(u16, address.port) };
}

fn configureSocket(fd: c.fd_t) !void {
    const flags = c.fcntl(fd, c.F.GETFL);
    if (flags < 0) return error.ProxySocketOptionsFailed;
    const nonblocking: c.O = .{ .NONBLOCK = true };
    const nonblocking_bits: c_int = @bitCast(nonblocking);
    if (c.fcntl(fd, c.F.SETFL, flags | nonblocking_bits) < 0) return error.ProxySocketOptionsFailed;
    if (c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) < 0) return error.ProxySocketOptionsFailed;
    if (builtin.os.tag.isDarwin()) {
        const one: c_int = 1;
        if (c.setsockopt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, @ptrCast(&one), @sizeOf(c_int)) < 0) return error.ProxySocketOptionsFailed;
    }
}

fn readSome(fd: c.fd_t, bytes: []u8) !?usize {
    const count = c.recv(fd, bytes.ptr, bytes.len, 0);
    if (count >= 0) return @intCast(count);
    return switch (c.errno(count)) {
        .AGAIN, .INTR => null,
        else => error.ProxyReadFailed,
    };
}

fn writeSome(fd: c.fd_t, bytes: []const u8) !?usize {
    const count = c.send(fd, bytes.ptr, bytes.len, if (builtin.os.tag == .linux) c.MSG.NOSIGNAL else 0);
    if (count > 0) return @intCast(count);
    return switch (c.errno(count)) {
        .AGAIN, .INTR => null,
        else => error.ProxyWriteFailed,
    };
}

fn nowMs() u64 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

const FixtureStream = struct {
    fd: c.fd_t,

    fn close(self: *FixtureStream) void {
        _ = c.close(self.fd);
        self.fd = -1;
    }
};

const FixturePump = Pump(FixtureStream, 16);
const Fixture = struct {
    cancelled: std.atomic.Value(bool) = .init(false),
    open_count: std.atomic.Value(usize) = .init(0),
    stream_fd: c.fd_t = -1,
    wait_for_cancel: bool = false,
    pump: FixturePump,
    requested_port: u16,
    error_after_join: ?anyerror = null,

    fn create(credentials: Credentials, requested_port: u16) !*Fixture {
        const self = try std.testing.allocator.create(Fixture);
        self.* = .{
            .requested_port = requested_port,
            .pump = .{
                .credentials = credentials,
                .backend = .{ .context = self, .open = open, .available = available },
                .cancelled = &self.cancelled,
                .timeout_ms = 2000,
            },
        };
        return self;
    }

    fn open(context: *anyopaque, target: Target) anyerror!FixtureStream {
        const self: *Fixture = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, target.hostname(), "fixture-only.invalid") or target.port != 443) return error.UnexpectedDestination;
        if (self.cancelled.load(.acquire)) return error.Cancelled;
        const open_index = self.open_count.fetchAdd(1, .acq_rel);
        if (self.wait_for_cancel) {
            const deadline = nowMs() + 3_000;
            while (!self.cancelled.load(.acquire) and nowMs() < deadline) fixturePause();
            return error.Cancelled;
        }
        if (open_index != 0 or self.stream_fd < 0) return error.ConnectionRefused;
        return .{ .fd = self.stream_fd };
    }

    fn available(_: *anyopaque) bool {
        return true;
    }

    fn run(self: *Fixture) void {
        self.pump.run(self.requested_port, noop) catch |err| {
            self.error_after_join = err;
        };
    }

    fn noop(_: *anyopaque) void {}

    fn waitForPort(self: *Fixture) !u16 {
        const deadline = nowMs() + 2_000;
        while (nowMs() < deadline) {
            const port = self.pump.port.load(.acquire);
            if (port != 0) return port;
            if (self.cancelled.load(.acquire)) break;
            fixturePause();
        }
        return error.FixtureStartupTimeout;
    }

    fn stop(self: *Fixture, thread: std.Thread) void {
        self.cancelled.store(true, .release);
        thread.join();
    }
};

fn fixturePause() void {
    var no_fds: [0]c.pollfd = .{};
    _ = c.poll(&no_fds, 0, 5);
}

fn fixtureConnect(port: u16) !c.fd_t {
    const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (fd < 0) return error.FixtureSocketUnavailable;
    errdefer _ = c.close(fd);
    const address: SockaddrIn = .{ .port = std.mem.nativeToBig(u16, port) };
    if (c.connect(fd, @ptrCast(&address), @sizeOf(SockaddrIn)) != 0) return error.FixtureConnectFailed;
    try configureSocket(fd);
    return fd;
}

fn fixtureWrite(fd: c.fd_t, payload: []const u8) !void {
    const deadline = nowMs() + 2_000;
    var offset: usize = 0;
    while (offset < payload.len) {
        if (nowMs() >= deadline) return error.FixtureWriteTimeout;
        try fixtureWait(fd, c.POLL.OUT);
        if (try writeSome(fd, payload[offset..])) |count| offset += count;
    }
}

fn fixtureRead(fd: c.fd_t, payload: []u8) !void {
    const deadline = nowMs() + 2_000;
    var offset: usize = 0;
    while (offset < payload.len) {
        if (nowMs() >= deadline) return error.FixtureReadTimeout;
        try fixtureWait(fd, c.POLL.IN);
        if (try readSome(fd, payload[offset..])) |count| {
            if (count == 0) return error.UnexpectedFixtureEof;
            offset += count;
        }
    }
}

fn fixtureWait(fd: c.fd_t, events: c_short) !void {
    var poll: c.pollfd = .{ .fd = fd, .events = events, .revents = 0 };
    const rc = c.poll(@ptrCast(&poll), 1, 2_000);
    if (rc <= 0) return error.FixturePollTimeout;
}

fn fixtureAuth(fd: c.fd_t, credentials: Credentials) !u8 {
    try fixtureWrite(fd, &.{ 5, 2, 0, 2 });
    var reply: [2]u8 = undefined;
    try fixtureRead(fd, &reply);
    try std.testing.expectEqualSlices(u8, &.{ 5, 2 }, &reply);
    const frame = [_]u8{ 1, 32 } ++ credentials.username ++ [_]u8{64} ++ credentials.password;
    try fixtureWrite(fd, &frame);
    try fixtureRead(fd, &reply);
    try std.testing.expectEqual(@as(u8, 1), reply[0]);
    return reply[1];
}

test "web SOCKS pump revokes old credentials on the same port and drains a half-close" {
    const old: Credentials = .{ .username = @splat('a'), .password = @splat('b') };
    const current: Credentials = .{ .username = @splat('c'), .password = @splat('d') };
    const port = previous_generation: {
        const fixture = try Fixture.create(old, 0);
        defer std.testing.allocator.destroy(fixture);
        const thread = try std.Thread.spawn(.{}, Fixture.run, .{fixture});
        defer fixture.stop(thread);
        const assigned_port = try fixture.waitForPort();
        const client = try fixtureConnect(assigned_port);
        defer _ = c.close(client);
        try std.testing.expectEqual(@as(u8, 0), try fixtureAuth(client, old));
        break :previous_generation assigned_port;
    };

    const fixture = try Fixture.create(current, port);
    defer std.testing.allocator.destroy(fixture);
    var pair: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &pair) != 0) return error.FixtureSocketPairFailed;
    defer _ = c.close(pair[1]);
    defer if (fixture.open_count.load(.acquire) == 0) {
        _ = c.close(pair[0]);
    };
    try configureSocket(pair[1]);
    fixture.stream_fd = pair[0];

    const thread = try std.Thread.spawn(.{}, Fixture.run, .{fixture});
    var stopped = false;
    defer if (!stopped) fixture.stop(thread);
    try std.testing.expectEqual(port, try fixture.waitForPort());
    {
        const client = try fixtureConnect(port);
        defer _ = c.close(client);
        try fixtureWrite(client, &.{ 5, 1, 0 });
        var reply: [2]u8 = undefined;
        try fixtureRead(client, &reply);
        try std.testing.expectEqualSlices(u8, &.{ 5, 255 }, &reply);
    }
    {
        const client = try fixtureConnect(port);
        defer _ = c.close(client);
        try std.testing.expectEqual(@as(u8, 1), try fixtureAuth(client, old));
        try std.testing.expectEqual(@as(usize, 0), fixture.open_count.load(.acquire));
    }
    {
        const client = try fixtureConnect(port);
        defer _ = c.close(client);
        try std.testing.expectEqual(@as(u8, 0), try fixtureAuth(client, current));
        var request: [64]u8 = undefined;
        const encoded = try socks.Codec.encodeConnectRequest(.{
            .command = .connect,
            .address = .{ .domain = "fixture-only.invalid" },
            .port = 443,
        }, &request);
        try fixtureWrite(client, encoded);
        try fixtureWrite(client, "question");
        try std.testing.expectEqual(@as(c_int, 0), c.shutdown(client, c.SHUT.WR));

        var reply: [10]u8 = undefined;
        try fixtureRead(client, &reply);
        try std.testing.expectEqual(.succeeded, (try socks.Codec.decodeConnectResponse(&reply)).reply);
        var upstream: [8]u8 = undefined;
        try fixtureRead(pair[1], &upstream);
        try std.testing.expectEqualStrings("question", &upstream);
        try fixtureWait(pair[1], c.POLL.IN);
        try std.testing.expectEqual(@as(?usize, 0), try readSome(pair[1], &upstream));
        try fixtureWrite(pair[1], "answer");
        try std.testing.expectEqual(@as(c_int, 0), c.shutdown(pair[1], c.SHUT.WR));

        var downstream: [6]u8 = undefined;
        try fixtureRead(client, &downstream);
        try std.testing.expectEqualStrings("answer", &downstream);
        try fixtureWait(client, c.POLL.IN);
        try std.testing.expectEqual(@as(?usize, 0), try readSome(client, &downstream));
    }
    fixture.stop(thread);
    stopped = true;
    try std.testing.expectEqual(@as(?anyerror, null), fixture.error_after_join);
    try std.testing.expectEqual(@as(usize, 1), fixture.open_count.load(.acquire));
    try std.testing.expectEqual(Counts{}, fixture.pump.counts.load(.acquire));
    try std.testing.expectEqual(@as(u16, 0), fixture.pump.port.load(.acquire));
}

test "web SOCKS pump bounds pending CONNECTs and revokes them before opening" {
    const credentials: Credentials = .{ .username = @splat('u'), .password = @splat('p') };
    const fixture = try Fixture.create(credentials, 0);
    defer std.testing.allocator.destroy(fixture);
    fixture.wait_for_cancel = true;
    const thread = try std.Thread.spawn(.{}, Fixture.run, .{fixture});
    var stopped = false;
    defer if (!stopped) fixture.stop(thread);
    const port = try fixture.waitForPort();
    var clients: [max_pending + 1]c.fd_t = @splat(-1);
    defer for (clients) |client| {
        if (client >= 0) _ = c.close(client);
    };
    var request: [64]u8 = undefined;
    const encoded = try socks.Codec.encodeConnectRequest(.{
        .command = .connect,
        .address = .{ .domain = "fixture-only.invalid" },
        .port = 443,
    }, &request);
    for (&clients, 0..) |*client, index| {
        client.* = try fixtureConnect(port);
        try std.testing.expectEqual(@as(u8, 0), try fixtureAuth(client.*, credentials));
        try fixtureWrite(client.*, encoded);
        if (index == max_pending) break;
        const deadline = nowMs() + 500;
        while (fixture.pump.counts.load(.acquire).pending < index + 1 and nowMs() < deadline) fixturePause();
        try std.testing.expectEqual(@as(u8, @intCast(index + 1)), fixture.pump.counts.load(.acquire).pending);
    }
    var reply: [10]u8 = undefined;
    try fixtureRead(clients[max_pending], &reply);
    try std.testing.expectEqual(.not_allowed, (try socks.Codec.decodeConnectResponse(&reply)).reply);
    const deadline = nowMs() + 500;
    while (fixture.open_count.load(.acquire) < max_openers and nowMs() < deadline) fixturePause();
    const counts = fixture.pump.counts.load(.acquire);
    try std.testing.expectEqual(@as(u8, max_pending), counts.pending);
    try std.testing.expectEqual(@as(u8, max_openers), counts.opening);
    try std.testing.expectEqual(@as(u8, 0), counts.active);
    fixture.stop(thread);
    stopped = true;
    try std.testing.expectEqual(@as(usize, max_openers), fixture.open_count.load(.acquire));
    try std.testing.expectEqual(Counts{}, fixture.pump.counts.load(.acquire));
    try std.testing.expectEqual(@as(u16, 0), fixture.pump.port.load(.acquire));
}
