//! A single owner pumps a borrowed direct-tcpip channel into a socketpair.
//! The hop Session must outlive this relay; no other thread may use that
//! libssh2 Session until stopAndJoin returns.
const std = @import("std");
const c = @import("generated_ssh_session");
const Channel = @import("channel.zig").Channel;
const Session = @import("session.zig").Session;
const Forward = @import("forward_service.zig").Service;

pub const Pair = struct {
    target_fd: c_int,
    relay_fd: c_int,
    pub fn create() !Pair {
        var pair: Pair = .{ .target_fd = -1, .relay_fd = -1 };
        if (c.zw_ssh_socketpair(&pair.target_fd, &pair.relay_fd) != 0) return error.SocketPairFailed;
        return pair;
    }
};

pub const Relay = struct {
    allocator: std.mem.Allocator,
    native: *c.ZW_SSH_RELAY,
    thread: ?std.Thread = null,
    cancel: std.atomic.Value(bool) = .init(false),
    state: std.atomic.Value(u8) = .init(0), // 0 running, 1 EOF, 2 failure, 3 cancelled
    session: ?*Session = null,
    forward: std.atomic.Value(?*Forward) = .init(null),
    forwards_mutex: std.atomic.Mutex = .unlocked,
    shared_forwards: ?*Forward = null,

    /// Consumes fd on success and failure; channel remains owned by its Session.
    pub fn start(allocator: std.mem.Allocator, fd: c_int, channel: *Channel) !*Relay {
        return startOwned(allocator, fd, channel, null, null);
    }
    pub fn startSession(allocator: std.mem.Allocator, fd: c_int, channel: *Channel, session: *Session) !*Relay {
        return startOwned(allocator, fd, channel, session, null);
    }
    pub fn startSessionWithForward(allocator: std.mem.Allocator, fd: c_int, channel: *Channel, session: *Session, forward: ?*Forward) !*Relay {
        return startOwned(allocator, fd, channel, session, forward);
    }
    fn startOwned(allocator: std.mem.Allocator, fd: c_int, channel: *Channel, session: ?*Session, forward: ?*Forward) !*Relay {
        const native = c.zw_ssh_relay_create(fd, @ptrCast(channel.handle)) orelse return error.RelayCreateFailed;
        errdefer c.zw_ssh_relay_destroy(native);
        const self = try allocator.create(Relay);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .native = native, .session = session, .forward = .init(forward) };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    fn run(self: *Relay) void {
        // An upstream transport failure must wake every downstream Session.
        // Keep the descriptor owned until stopAndJoin + native destroy; this
        // publishes EOF without an early close/reuse race in the ledger.
        defer c.zw_ssh_relay_interrupt(self.native);
        defer if (self.forward.load(.acquire)) |forward| forward.transportLost() catch {};
        while (!self.cancel.load(.acquire)) {
            // This relay is the parent transport's sole native owner. The
            // target worker/controller only submit to its bounded mailbox.
            if (self.session) |session| session.stepRtt(@import("../../platform/realtime.zig").monotonicNs()) catch |err| {
                std.log.err("relay RTT IO owner violation: {s}", .{@errorName(err)});
                self.state.store(2, .release);
                return;
            };
            if (self.forward.load(.acquire)) |forward| if (self.session) |session| forward.step(session) catch |err| {
                std.log.err("relay forward IO owner violation: {s}", .{@errorName(err)});
                self.state.store(2, .release);
                return;
            };
            self.stepSharedForwards() catch |err| {
                std.log.err("relay shared forward IO owner violation: {s}", .{@errorName(err)});
                self.state.store(2, .release);
                return;
            };
            const result = c.zw_ssh_relay_step(self.native);
            if (result != 0) {
                self.state.store(if (result > 0) 1 else 2, .release);
                return;
            }
            const session = self.session;
            c.zw_ssh_relay_wait(self.native, if (session) |s| s.socket_fd else -1, if (session) |s| s.handle else null, if (self.forward.load(.acquire) != null) 5 else 20);
        }
        self.state.store(3, .release);
    }

    /// A fully initialized Worker publishes its stable facade after all
    /// fallible initialization. Only this Relay then performs native work.
    pub fn bindForward(self: *Relay, forward: *Forward) void {
        self.forward.store(forward, .release);
    }
    fn lockForwards(self: *Relay) void {
        while (!self.forwards_mutex.tryLock()) std.atomic.spinLoopHint();
    }
    pub fn bindSharedForward(self: *Relay, forward: *Forward) void {
        self.lockForwards();
        defer self.forwards_mutex.unlock();
        std.debug.assert(!forward.relay_registered.load(.acquire));
        forward.relay_detach.store(false, .release);
        forward.relay_next = self.shared_forwards;
        forward.relay_registered.store(true, .release);
        self.shared_forwards = forward;
    }
    fn stepSharedForwards(self: *Relay) !void {
        const session = self.session orelse return;
        self.lockForwards();
        defer self.forwards_mutex.unlock();
        var link = &self.shared_forwards;
        while (link.*) |forward| {
            if (forward.relay_detach.load(.acquire)) {
                if (try forward.detachSharedStep() == .released) {
                    link.* = forward.relay_next;
                    forward.relay_next = null;
                    // Last access: the owning Worker can now destroy/rebind it.
                    forward.relay_registered.store(false, .release);
                    continue;
                }
            } else try forward.stepShared(session);
            link = &forward.relay_next;
        }
    }
    /// Transfer unfinished facades with the joined parent graph. Their owners
    /// remain blocked until Route publishes actual native child release.
    pub fn takeSharedForwards(self: *Relay) ?*Forward {
        self.stopAndJoin();
        const forwards = self.shared_forwards;
        self.shared_forwards = null;
        return forwards;
    }

    pub fn stopAndJoin(self: *Relay) void {
        self.cancel.store(true, .release);
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }
    pub fn deinit(self: *Relay) void {
        self.stopAndJoin();
        c.zw_ssh_relay_destroy(self.native);
        self.allocator.destroy(self);
    }
};

test "socketpair creates distinct owned endpoints" {
    const pair = try Pair.create();
    defer c.zw_ssh_socket_close(pair.target_fd);
    defer c.zw_ssh_socket_close(pair.relay_fd);
    try std.testing.expect(pair.target_fd >= 0 and pair.relay_fd >= 0);
    try std.testing.expect(pair.target_fd != pair.relay_fd);
}

test "stopped relay propagates EOF without releasing or recycling its owned socketpair descriptor" {
    const pair = try Pair.create();
    defer c.zw_ssh_socket_close(pair.target_fd);
    // Interrupt never calls libssh2; this fixture exercises only actual local
    // descriptor lifetime, with no native Session/channel allocation.
    const native = c.zw_ssh_relay_create(pair.relay_fd, null) orelse return error.OutOfMemory;
    var released = false;
    defer if (!released) c.zw_ssh_relay_destroy(native);
    c.zw_ssh_relay_interrupt(native);
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 0), std.c.read(pair.target_fd, &byte, byte.len));
    try std.testing.expect(std.c.fcntl(pair.relay_fd, std.c.F.GETFL, @as(c_int, 0)) >= 0);
    c.zw_ssh_relay_destroy(native);
    released = true;
    try std.testing.expectEqual(@as(c_int, -1), std.c.fcntl(pair.relay_fd, std.c.F.GETFL, @as(c_int, 0)));
}
