//! Independent no-shell transports. Only the worker calls native SSH APIs;
//! callers receive bounded kernel socketpairs, never borrowed native Sessions.
const std = @import("std");
const ssh = @import("../proto/ssh/session.zig");
const c = @import("generated_ssh_session");
const Channel = @import("../proto/ssh/channel.zig").Channel;
const resolution = @import("connection_config_resolver.zig");
const identity = @import("identity.zig");
const policy = @import("../proto/ssh/connection_policy.zig");
pub const ReleaseReceipt = ssh.ReleaseReceipt;
pub const Purpose = enum { connection, probe, file, management };
pub const Destination = struct { host: []const u8, port: u16 };
pub const max_streams = c.ZW_SSH_RELAY_WAIT_MAX;
pub const Credentials = struct {
    context: *anyopaque,
    /// Read controlled references for this owner; never query a live Session.
    /// Callback runs on the AssetStore owning caller thread before worker start.
    resolve: *const fn (*anyopaque, identity.ResourceOwner, identity.AssetOwner, std.mem.Allocator) anyerror!ssh.Auth,
};
pub const FailedOpenOwner = struct {
    context: *anyopaque,
    reserve: *const fn (*anyopaque) anyerror!void,
    release: *const fn (*anyopaque) void,
    /// Consumes the reservation and transport. Must not allocate or fail.
    adopt: *const fn (*anyopaque, *OwnedTransport) void,
};
pub const Factory = struct {
    allocator: std.mem.Allocator,
    library: *const ssh.Library,
    credentials: ?Credentials = null,
    host_key_store: ?*policy.HostKeyStore = null,
    host_key_decision: ssh.HostKeyDecision = .reject_unknown,
    host_key_observer: ?ssh.HostKeyObserver = null,
    auth_interaction: ?ssh.AuthInteraction = null,
    timeout_ms: u32 = 15_000,
    /// Passive socket hangup observation for consumers with an idle listener.
    detect_socket_disconnect: bool = false,
    /// Explicit protocol owners may retain existing streams after operation
    /// cancellation for bounded remote cleanup. Cancellation still prevents
    /// ordinary connects/stream opens; close() remains mandatory.
    keep_established_until_close: bool = false,
    /// Explicit cleanup capability, frozen at prepare. Only an endpoint that
    /// already admitted a normal stream may receive at most two cleanup dials
    /// on this live transport. Ordinary cancellation rules remain unchanged.
    cleanup_destination: ?Destination = null,
    operation_key: ?@import("operation.zig").OperationKey = null,
    failed_open_owner: ?FailedOpenOwner = null,
    /// App acceptance fixtures can hold native resources across cleanup retries.
    acceptance_hold_native_cleanup: ?*const std.atomic.Value(bool) = null,

    pub fn prepareOwned(self: Factory, owner: identity.ResourceOwner, route: *const resolution.FrozenRoute, purpose: Purpose, cancel: ?*const std.atomic.Value(bool)) !*OwnedTransport {
        if (route.hops.len > resolution.max_jumps) return error.TooManyJumps;
        if (cancel) |token| if (token.load(.acquire)) return error.Cancelled;
        if (self.cleanup_destination) |destination| {
            if (!self.keep_established_until_close) return error.InvalidCleanupPolicy;
            try validateTcpDestination(destination);
        }
        if (self.operation_key) |key| switch (owner) {
            .session => |handle| if (key.owner != .session or !key.owner.session.eql(handle)) return error.InvalidOperationOwner,
            .retained_transfer => |id| if (key.owner != .transfer_owner or key.owner.transfer_owner.id != id) return error.InvalidOperationOwner,
        };
        for (route.hops, 0..) |hop, index| {
            const config = hop.nonsecret_config;
            try config.validate();
            if (hop.asset_id != config.connection_id or hop.revision != config.revision or hop.credential_reference.id != hop.asset_id or hop.credential_reference.revision != hop.revision) return error.InvalidFrozenRoute;
            for (route.hops[0..index]) |previous| {
                if (previous.asset_id == hop.asset_id) return error.DuplicateRoute;
                if (resolution.sameEndpoint(previous.nonsecret_config, config)) return error.DuplicateEndpoint;
            }
        }
        if (self.failed_open_owner) |retainer| try retainer.reserve(retainer.context) else if (route.hops.len != 0) return error.MissingFailedOpenOwner;
        errdefer if (self.failed_open_owner) |retainer| retainer.release(retainer.context);
        const transport = try self.allocator.create(OwnedTransport);
        errdefer self.allocator.destroy(transport);
        transport.* = .{ .factory = self, .owner = owner, .purpose = purpose, .external_cancel = cancel, .arena = .init(self.allocator), .reserved_cleanup = self.failed_open_owner != null };
        if (self.cleanup_destination) |destination| {
            @memcpy(transport.cleanup_host[0..destination.host.len], destination.host);
            transport.cleanup_host_len = destination.host.len;
            transport.cleanup_port = destination.port;
        }
        transport.arena = .init(ZeroingAllocator.wrap(&transport.factory.allocator));
        errdefer transport.arena.deinit();
        const a = transport.arena.allocator();
        if (route.hops.len != 0) transport.ledger = try ssh.ResourceLedger.init(self.operation_key, route.hops.len);
        transport.options = try a.alloc(ssh.Options, route.hops.len);
        for (route.hops, transport.options) |hop, *option| {
            const host = hop.nonsecret_config;
            if (!std.mem.eql(u8, host.protocolId(), "ssh") or host.payload_version != 1) return error.UnsupportedProtocol;
            const auth: ssh.Auth = if (self.credentials) |provider| try provider.resolve(provider.context, owner, hop.credential_reference, a) else switch (host.auth_mode) {
                .agent => .agent,
                .password => .password_prompt,
                .private_key => .{ .private_key = .{ .path = try a.dupeSentinel(u8, host.identity_file orelse return error.MissingIdentityFile, 0) } },
            };
            option.* = .{ .host = try a.dupeSentinel(u8, host.host, 0), .port = host.port, .user = try a.dupeSentinel(u8, host.user, 0), .auth = try cloneAuth(a, auth), .source_owner = hop.credential_reference, .operation_key = self.operation_key, .attempt_id = if (self.operation_key) |key| key.attempt_id orelse 0 else 0, .resource_ledger = if (transport.ledger) |*ledger| ledger else null, .open_shell = false, .strict_host_key_checking = host.strict_host_key_checking, .compression = host.compression, .host_key_store = self.host_key_store, .host_key_decision = self.host_key_decision, .host_key_observer = self.host_key_observer, .auth_interaction = self.auth_interaction, .cancel_token = cancel orelse &transport.closing, .connect_timeout_ms = self.timeout_ms };
        }
        return transport;
    }
    /// Synchronous convenience for non-UI callers. Controllers prepare on the
    /// AssetStore thread, then call attempt.start() from their own worker.
    pub fn openOwned(self: Factory, owner: identity.ResourceOwner, route: *const resolution.FrozenRoute, purpose: Purpose, cancel: ?*const std.atomic.Value(bool)) !*OwnedTransport {
        const attempt = try self.prepareOwned(owner, route, purpose, cancel);
        attempt.start() catch |err| {
            _ = try attempt.adoptFailedOpen();
            return err;
        };
        return attempt;
    }
};
pub const TransportFactory = Factory;

const State = enum { free, pending, active, closing, failed, ended };
const Slot = struct {
    state: State = .free,
    generation: u64 = 0,
    host: [256:0]u8 = @splat(0),
    host_len: usize = 0,
    port: u16 = 0,
    fd: c_int = -1,
    channel: ?Channel = null,
    relay: ?*c.ZW_SSH_RELAY = null,
    failure: ?anyerror = null,
    open_deadline_ns: i128 = 0,
    cleanup_only: bool = false,
};
pub const OwnedStream = struct {
    transport: *OwnedTransport,
    index: usize,
    generation: u64,
    /// Borrowed until close unless requested via openTcpStreamWithOwnedFd.
    /// The stream handle must be closed before its transport is destroyed.
    fd: c_int,
    owns_fd: bool = false,

    pub fn close(self: *OwnedStream) void {
        if (self.fd < 0) return;
        if (self.owns_fd) _ = std.c.close(self.fd);
        self.transport.mutex.lock();
        defer self.transport.mutex.unlock();
        const slot = &self.transport.slots[self.index];
        if (slot.generation == self.generation and slot.state != .free and slot.state != .failed and slot.state != .ended) slot.state = .closing;
        self.fd = -1;
    }
};
pub const OwnedTransport = struct {
    factory: Factory,
    owner: identity.ResourceOwner,
    purpose: Purpose,
    external_cancel: ?*const std.atomic.Value(bool),
    arena: std.heap.ArenaAllocator,
    options: []ssh.Options = &.{},
    thread: ?std.Thread = null,
    started: bool = false,
    reserved_cleanup: bool = false,
    mutex: Mutex = .{},
    closing: std.atomic.Value(bool) = .init(false),
    ready: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    receipt: ReleaseReceipt = .awaiting,
    session: ?ssh.Session = null,
    ledger: ?ssh.ResourceLedger = null,
    route: ?*ssh.JumpTransport.Route = null,
    slots: [max_streams]Slot = @splat(.{}),
    next_slot: usize = 0,
    opening: ?usize = null,
    native_session_identity: std.atomic.Value(usize) = .init(0),
    cleanup_host: [256:0]u8 = @splat(0),
    cleanup_host_len: usize = 0,
    cleanup_port: u16 = 0,
    cleanup_admitted: bool = false,
    cleanup_open_count: u8 = 0,

    pub fn start(self: *OwnedTransport) !void {
        if (self.started) return error.TransportAlreadyStarted;
        if (self.cancelled()) return error.Cancelled;
        self.started = true;
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
            self.failure = err;
            self.ready.store(true, .release);
            self.done.store(true, .release);
            self.receipt = .released;
            return err;
        };
        while (!self.ready.load(.acquire)) pause();
        if (self.failure) |failure| return failure;
        // Keep one bounded cleanup reservation until this owner is destroyed.
        // A later stream/protocol failure can then transfer without allocation.
    }
    /// Consume a failed attempt. Released attempts are destroyed; incomplete
    /// cleanup transfers to the pre-reserved host owner with its actual receipt.
    pub fn adoptFailedOpen(self: *OwnedTransport) !ReleaseReceipt {
        const receipt = self.close();
        if (receipt == .released) {
            try self.deinit();
            return receipt;
        }
        const retainer = self.factory.failed_open_owner orelse return error.MissingFailedOpenOwner;
        if (!self.reserved_cleanup) return error.MissingCleanupReservation;
        self.reserved_cleanup = false;
        retainer.adopt(retainer.context, self);
        return receipt;
    }
    fn releaseReservation(self: *OwnedTransport) void {
        if (!self.reserved_cleanup) return;
        self.reserved_cleanup = false;
        const retainer = self.factory.failed_open_owner.?;
        retainer.release(retainer.context);
    }
    pub fn openTcpStream(self: *OwnedTransport, destination: Destination) !OwnedStream {
        return self.openStream(destination, false, false);
    }
    /// A separate CLOEXEC descriptor remains valid if the transport worker
    /// reclaims its slot. The consumer owns it until OwnedStream.close().
    pub fn openTcpStreamWithOwnedFd(self: *OwnedTransport, destination: Destination) !OwnedStream {
        return self.openStream(destination, false, true);
    }
    pub fn isStopping(self: *const OwnedTransport) bool {
        return self.cancelled() or self.done.load(.acquire);
    }
    /// No destination argument and no native-session start/reconnect. The
    /// caller may use the returned fd only for its already-owned remote cleanup.
    pub fn openCleanupTcpStream(self: *OwnedTransport) !OwnedStream {
        if (self.cleanup_host_len == 0) return error.CleanupStreamForbidden;
        return self.openStream(.{ .host = self.cleanup_host[0..self.cleanup_host_len], .port = self.cleanup_port }, true, false);
    }
    fn openStream(self: *OwnedTransport, destination: Destination, cleanup_only: bool, own_fd: bool) !OwnedStream {
        try validateTcpDestination(destination);
        self.mutex.lock();
        if (!cleanup_only and self.externalCancelled()) {
            self.mutex.unlock();
            return error.Cancelled;
        }
        if (cleanup_only and (!self.factory.keep_established_until_close or !self.started or !self.ready.load(.acquire) or !self.cleanup_admitted)) {
            self.mutex.unlock();
            return error.CleanupStreamForbidden;
        }
        if (self.closing.load(.acquire) or self.done.load(.acquire)) {
            self.mutex.unlock();
            return error.TransportClosed;
        }
        if (cleanup_only) {
            if (self.cleanup_open_count >= 2) {
                self.mutex.unlock();
                return error.CleanupStreamLimit;
            }
            self.cleanup_open_count += 1;
        }
        var selected: ?usize = null;
        for (&self.slots, 0..) |*slot, i| if (slot.state == .free or slot.state == .ended) {
            selected = i;
            break;
        };
        const index = selected orelse {
            self.mutex.unlock();
            return error.StreamLimit;
        };
        const slot = &self.slots[index];
        const generation = slot.generation + 1;
        slot.* = .{ .generation = generation, .state = .pending, .port = destination.port, .host_len = destination.host.len, .cleanup_only = cleanup_only, .open_deadline_ns = @import("../platform/realtime.zig").monotonicNs() + @as(i128, if (cleanup_only) 1000 else self.factory.timeout_ms) * std.time.ns_per_ms };
        @memcpy(slot.host[0..destination.host.len], destination.host);
        self.mutex.unlock();
        while (true) {
            self.mutex.lock();
            if (self.closing.load(.acquire) or (!cleanup_only and self.externalCancelled())) {
                // A just-opened stream must not escape a cancelled request.
                // Its worker retains sole ownership of native release.
                if (slot.generation == generation and (slot.state == .pending or slot.state == .active)) slot.state = .closing;
                self.mutex.unlock();
                return if (self.closing.load(.acquire)) error.TransportClosed else error.Cancelled;
            }
            if (slot.generation != generation or slot.state == .ended) {
                self.mutex.unlock();
                return error.StreamClosedDuringOpen;
            }
            const state = slot.state;
            const fd = if (state == .active and own_fd) std.c.fcntl(slot.fd, std.c.F.DUPFD_CLOEXEC, @as(c_int, 0)) else slot.fd;
            if (state == .active and own_fd and fd < 0) {
                slot.state = .closing;
                self.mutex.unlock();
                return error.StreamDescriptorUnavailable;
            }
            const failure = slot.failure;
            if (state == .failed) slot.state = .free;
            if (state == .active and !cleanup_only and destination.port == self.cleanup_port and std.mem.eql(u8, destination.host, self.cleanup_host[0..self.cleanup_host_len])) self.cleanup_admitted = true;
            self.mutex.unlock();
            if (state == .active) return .{ .transport = self, .index = index, .generation = generation, .fd = fd, .owns_fd = own_fd };
            if (state == .failed) return failure orelse error.StreamOpenFailed;
            if (self.done.load(.acquire)) return error.TransportClosed;
            pause();
        }
    }
    /// Independent resource identity, exposed as diagnostics without a native handle.
    pub fn nativeSessionIdentity(self: *const OwnedTransport) usize {
        return self.native_session_identity.load(.acquire);
    }
    pub fn close(self: *OwnedTransport) ReleaseReceipt {
        self.closing.store(true, .release);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        } else if ((!self.started or self.done.load(.acquire)) and self.receipt != .released) {
            // The worker has joined; this caller temporarily owns cleanup.
            // Retained unknown native state is retried, never merely relabeled.
            self.releaseNative();
        }
        return self.receipt;
    }
    pub fn deinit(self: *OwnedTransport) !void {
        if (self.close() != .released) return error.CleanupIncomplete;
        // Auth strings live only in this arena. Wipe the whole allocation space
        // before returning it to the allocator, including connect-time secrets.
        for (self.options) |option| switch (option.auth) {
            .password => |secret| @memset(@constCast(secret), 0),
            .private_key => |key| if (key.passphrase) |secret| {
                @memset(@constCast(secret), 0);
            },
            else => {},
        };
        self.releaseReservation();
        self.arena.deinit();
        self.factory.allocator.destroy(self);
    }
    fn cancelled(self: *const OwnedTransport) bool {
        return self.closing.load(.acquire) or self.externalCancelled();
    }
    fn externalCancelled(self: *const OwnedTransport) bool {
        return if (self.external_cancel) |token| token.load(.acquire) else false;
    }
    fn run(self: *OwnedTransport) void {
        self.connect() catch |err| {
            self.failure = err;
            self.ready.store(true, .release);
            self.releaseNative();
            return;
        };
        self.ready.store(true, .release);
        var productive_rounds: usize = 0;
        while (!self.closing.load(.acquire) and (self.factory.keep_established_until_close or !self.externalCancelled())) {
            if (self.factory.detect_socket_disconnect and self.socketDisconnected()) {
                self.closing.store(true, .release);
                break;
            }
            self.mutex.lock();
            self.step();
            var relays: [max_streams]?*c.ZW_SSH_RELAY = undefined;
            var count: usize = 0;
            for (self.slots) |slot| if (slot.state == .active) if (slot.relay) |relay| {
                relays[count] = relay;
                count += 1;
            };
            const session = self.nativeSession();
            self.mutex.unlock();
            // Only this worker frees relays/session; callers merely enqueue
            // state changes. Poll outside the mailbox lock, bounded to 2 ms.
            // This is an idle/readiness bound, not a delay per relay batch:
            // productive siblings drain immediately, yielding every 16 rounds.
            if (c.zw_ssh_relay_wait_many(&relays, count, if (session) |s| s.socket_fd else -1, if (session) |s| s.handle else null, 2) != 0) {
                productive_rounds += 1;
                if (productive_rounds == 16) {
                    std.Thread.yield() catch {};
                    productive_rounds = 0;
                }
            } else productive_rounds = 0;
        }
        self.releaseNative();
    }
    fn socketDisconnected(self: *OwnedTransport) bool {
        const session = self.nativeSession() orelse return false;
        var poll: std.c.pollfd = .{ .fd = session.socket_fd, .events = std.c.POLL.IN, .revents = 0 };
        if (std.c.poll(@ptrCast(&poll), 1, 0) <= 0) return false;
        if (poll.revents & (std.c.POLL.HUP | std.c.POLL.ERR | std.c.POLL.NVAL) != 0) return true;
        if (poll.revents & std.c.POLL.IN == 0) return false;
        var byte: u8 = undefined;
        return std.c.recv(session.socket_fd, @ptrCast(&byte), 1, std.c.MSG.PEEK | std.c.MSG.DONTWAIT) == 0;
    }

    fn connect(self: *OwnedTransport) !void {
        if (self.cancelled()) return error.Cancelled;
        if (self.options.len == 0) return;
        if (self.options.len == 1) self.session = try ssh.Session.connect(self.factory.library, self.options[0]) else {
            self.route = try ssh.JumpTransport.Route.connect(self.factory.allocator, self.factory.library, self.options);
        }
        const session = self.nativeSession().?;
        c.zw_libssh2_session_nonblocking(session.handle.?);
        self.native_session_identity.store(@intFromPtr(session.handle.?), .release);
    }
    fn nativeSession(self: *OwnedTransport) ?*ssh.Session {
        if (self.route) |route| return route.target();
        if (self.session) |*session| return session;
        return null;
    }
    fn step(self: *OwnedTransport) void {
        // Every live stream receives one bounded relay step per round, even
        // while a new channel open is waiting for its server response.
        for (0..max_streams) |offset| {
            const index = (self.next_slot + offset) % max_streams;
            const slot = &self.slots[index];
            if (slot.state == .active) if (slot.relay) |relay| {
                const result = c.zw_ssh_relay_step(relay);
                if (result != 0) slot.state = .closing;
            };
            if (slot.state == .closing) self.releaseSlot(slot);
        }
        self.next_slot = (self.next_slot + 1) % max_streams;
        if (self.cancelled()) {
            // Cancellation blocks every ordinary pending channel. Only the
            // separately admitted, fixed-endpoint cleanup dials may proceed.
            for (&self.slots) |*slot| if (slot.state == .pending and (self.closing.load(.acquire) or !slot.cleanup_only)) {
                slot.failure = error.Cancelled;
                slot.state = .closing;
                self.releaseSlot(slot);
                slot.state = .failed;
            };
            if (self.opening) |index| if (self.slots[index].state != .pending) {
                self.opening = null;
            };
        }
        if (self.opening == null) for (self.slots, 0..) |slot, i| if (slot.state == .pending) {
            self.opening = i;
            break;
        };
        const index = self.opening orelse return;
        const slot = &self.slots[index];
        if (slot.state != .pending) {
            self.opening = null;
            return;
        }
        self.openSlot(slot) catch |err| {
            if (err == error.WouldBlock) {
                if (@import("../platform/realtime.zig").monotonicNs() < slot.open_deadline_ns) return;
                slot.failure = error.StreamOpenTimeout;
                slot.state = .failed;
                self.closing.store(true, .release);
                self.opening = null;
                return;
            }
            slot.failure = err;
            slot.state = .failed;
            self.opening = null;
            return;
        };
        slot.state = .active;
        self.opening = null;
    }
    fn openSlot(self: *OwnedTransport, slot: *Slot) !void {
        const host: [:0]const u8 = slot.host[0..slot.host_len :0];
        const session = self.nativeSession() orelse {
            const fd = c.zw_ssh_socket_connect_cancellable(host.ptr, slot.port, if (slot.cleanup_only) 1000 else self.factory.timeout_ms, if (slot.cleanup_only) isCleanupCancelled else isCancelled, self);
            if (fd < 0) return if (self.closing.load(.acquire) or (!slot.cleanup_only and self.externalCancelled())) error.Cancelled else error.TcpConnectFailed;
            slot.fd = fd;
            return;
        };
        slot.channel = session.openDirectTcpip(host, slot.port) catch |err| {
            if (c.zw_libssh2_session_last_error(session.handle.?) == -37) return error.WouldBlock;
            return err;
        };
        errdefer {
            _ = session.closeChannelReceipt(&slot.channel.?);
            slot.channel = null;
        }
        const pair = try ssh.SocketRelay.Pair.create();
        errdefer c.zw_ssh_socket_close(pair.target_fd);
        slot.relay = c.zw_ssh_relay_create(pair.relay_fd, @ptrCast(slot.channel.?.handle)) orelse return error.RelayCreateFailed;
        slot.fd = pair.target_fd;
    }
    fn releaseSlot(self: *OwnedTransport, slot: *Slot) void {
        if (slot.fd >= 0) {
            c.zw_ssh_socket_close(slot.fd);
            slot.fd = -1;
        }
        if (slot.relay) |relay| {
            c.zw_ssh_relay_destroy(relay);
            slot.relay = null;
        }
        if (slot.channel) |*channel| {
            if (self.nativeSession()) |session| if (session.closeChannelReceipt(channel) != .released) return;
            slot.channel = null;
        }
        slot.state = .ended;
    }
    fn releaseNative(self: *OwnedTransport) void {
        // Streams first; JumpTransport then joins relays and releases SSH nodes
        // strictly from the destination back to the first authenticated hop.
        self.mutex.lock();
        defer self.mutex.unlock();
        var index = self.slots.len;
        while (index > 0) {
            index -= 1;
            const slot = &self.slots[index];
            if (slot.state != .free) self.releaseSlot(slot);
        }
        if (self.factory.acceptance_hold_native_cleanup) |hold| {
            if (hold.load(.acquire) and (self.route != null or self.session != null)) {
                self.receipt = .unknown;
                self.done.store(true, .release);
                return;
            }
        }
        self.receipt = if (self.route) |route| route.closeReceipt() else if (self.session) |*session| session.closeReceipt() else .released;
        if (self.receipt == .released) for (&self.slots) |*slot| {
            slot.channel = null;
        };
        if (self.receipt == .released) if (self.ledger) |*ledger| {
            self.receipt = ledger.drainRetained();
        };
        if (self.receipt == .released) {
            if (self.route) |route| route.deinit();
            self.route = null;
            self.session = null;
            for (&self.slots) |*slot| {
                slot.channel = null;
                slot.state = .ended;
            }
        }
        self.done.store(true, .release);
    }
    fn isCancelled(context: ?*anyopaque) callconv(.c) c_int {
        const self: *OwnedTransport = @ptrCast(@alignCast(context.?));
        return @intFromBool(self.cancelled());
    }
    fn isCleanupCancelled(context: ?*anyopaque) callconv(.c) c_int {
        const self: *OwnedTransport = @ptrCast(@alignCast(context.?));
        return @intFromBool(self.closing.load(.acquire));
    }
};
fn validateTcpDestination(destination: Destination) !void {
    if (destination.host.len == 0 or destination.host.len > 255 or std.mem.indexOfAny(u8, destination.host, "\x00\r\n") != null or destination.port == 0) return error.InvalidDestination;
}
fn pause() void {
    var fds: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&fds, 0, 2);
}

test "transport rejects cancelled creation before allocating native resources" {
    var library: ssh.Library = .{ .active = false };
    var cancelled: std.atomic.Value(bool) = .init(true);
    var route: resolution.FrozenRoute = .{ .arena = .init(std.testing.allocator), .store_revision = 1, .hops = &.{} };
    defer route.deinit();
    const factory: Factory = .{ .allocator = std.testing.allocator, .library = &library };
    try std.testing.expectError(error.Cancelled, factory.openOwned(.{ .session = .{ .session_id = @fromBackingInt(1) } }, &route, .probe, &cancelled));
}

fn cloneAuth(a: std.mem.Allocator, auth: ssh.Auth) !ssh.Auth {
    return switch (auth) {
        .password => |secret| .{ .password = try a.dupeSentinel(u8, secret, 0) },
        .private_key => |key| .{ .private_key = .{ .path = try a.dupeSentinel(u8, key.path, 0), .passphrase = if (key.passphrase) |secret| try a.dupeSentinel(u8, secret, 0) else null } },
        else => auth,
    };
}

const Mutex = struct {
    held: std.atomic.Value(bool) = .init(false),
    fn lock(self: *Mutex) void {
        while (self.held.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Mutex) void {
        self.held.store(false, .release);
    }
};

/// Used beneath the transport arena: all allocations, including credentials
/// returned by a provider into the supplied allocator, are zeroed on release.
const ZeroingAllocator = struct {
    fn wrap(backing: *std.mem.Allocator) std.mem.Allocator {
        return .{ .ptr = backing, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn child(context: *anyopaque) *std.mem.Allocator {
        return @ptrCast(@alignCast(context));
    }
    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        return child(context).rawAlloc(len, alignment, ra);
    }
    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        // No shrink: never return a tail containing old secret bytes.
        if (new_len < memory.len) return false;
        return child(context).rawResize(memory, alignment, new_len, ra);
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }
    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        @memset(memory, 0);
        std.mem.doNotOptimizeAway(memory.ptr);
        child(context).rawFree(memory, alignment, ra);
    }
};

test "transport rejects mismatched operation owner and frozen references before IO" {
    var library: ssh.Library = .{ .active = false };
    var registry: @import("../config/hosts.zig").Registry = .{ .arena = .init(std.testing.allocator), .hosts = &.{} };
    defer registry.deinit();
    const asset = try registry.add(.{ .name = "offline", .host = "offline.invalid", .user = "u" });
    var route = try resolution.Resolver.init(&registry).freezeRoute(&.{asset.id}, std.testing.allocator);
    defer route.deinit();
    var factory: Factory = .{ .allocator = std.testing.allocator, .library = &library, .operation_key = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(1), .generation = 2 } }, .operation_id = 1 } };
    const owner: identity.ResourceOwner = .{ .session = .{ .session_id = @fromBackingInt(1), .generation = 1 } };
    try std.testing.expectError(error.InvalidOperationOwner, factory.openOwned(owner, &route, .probe, null));
    factory.operation_key = null;
    @constCast(route.hops)[0].credential_reference.revision += 1;
    try std.testing.expectError(error.InvalidFrozenRoute, factory.openOwned(owner, &route, .probe, null));
}

test "transport retained unknown cleanup remains unknown on repeated close" {
    var library: ssh.Library = .{ .active = false };
    var ledger = try ssh.ResourceLedger.init(null, 1);
    try std.testing.expect(ledger.record(null, 0, .transport, .owned));
    try std.testing.expect(ledger.record(null, 0, .transport, .unknown));
    var transport: OwnedTransport = .{ .factory = .{ .allocator = std.testing.allocator, .library = &library }, .owner = .{ .session = .{ .session_id = @fromBackingInt(1) } }, .purpose = .probe, .external_cancel = null, .arena = .init(std.testing.allocator), .ledger = ledger, .done = .init(true), .receipt = .unknown };
    defer transport.arena.deinit();
    try std.testing.expectEqual(ReleaseReceipt.unknown, transport.close());
    try std.testing.expectEqual(ReleaseReceipt.unknown, transport.close());
}

const CleanupLoopback = struct {
    fd: c_int,
    port: u16,
    fn init() !CleanupLoopback {
        const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = std.c.close(fd);
        var address: std.c.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        if (std.c.bind(fd, @ptrCast(&address), @sizeOf(@TypeOf(address))) != 0 or std.c.listen(fd, 8) != 0) return error.ListenFailed;
        var len: std.c.socklen_t = @sizeOf(@TypeOf(address));
        if (std.c.getsockname(fd, @ptrCast(&address), &len) != 0) return error.AddressFailed;
        return .{ .fd = fd, .port = std.mem.bigToNative(u16, address.port) };
    }
    fn deinit(self: CleanupLoopback) void {
        _ = std.c.close(self.fd);
    }
    fn destination(self: CleanupLoopback) Destination {
        return .{ .host = "127.0.0.1", .port = self.port };
    }
    fn acceptAndClose(self: CleanupLoopback) !void {
        var fds = [_]std.c.pollfd{.{ .fd = self.fd, .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&fds, 1, 1000) <= 0) return error.AcceptTimeout;
        const fd = std.c.accept(self.fd, null, null);
        if (fd < 0) return error.AcceptFailed;
        _ = std.c.close(fd);
    }
};

test "BMC transport cleanup defaults to forbidden without widening ordinary cancellation" {
    const listener = try CleanupLoopback.init();
    defer listener.deinit();
    var library: ssh.Library = .{ .active = false };
    var route: resolution.FrozenRoute = .{ .arena = .init(std.testing.allocator), .store_revision = 1, .hops = &.{} };
    defer route.deinit();
    var cancel: std.atomic.Value(bool) = .init(false);
    var factory: Factory = .{ .allocator = std.testing.allocator, .library = &library, .keep_established_until_close = true };
    const owner: identity.ResourceOwner = .{ .session = .{ .session_id = @fromBackingInt(907) } };
    const owned = try factory.prepareOwned(owner, &route, .connection, &cancel);
    defer owned.deinit() catch unreachable;
    try std.testing.expectError(error.CleanupStreamForbidden, owned.openCleanupTcpStream());
    try owned.start();
    var stream = try owned.openTcpStream(listener.destination());
    defer stream.close();
    try listener.acceptAndClose();
    cancel.store(true, .release);
    try std.testing.expectError(error.CleanupStreamForbidden, owned.openCleanupTcpStream());
    try std.testing.expectError(error.Cancelled, owned.openTcpStream(listener.destination()));
    try std.testing.expectError(error.Cancelled, factory.prepareOwned(owner, &route, .connection, &cancel));
    cancel.store(false, .release);
    factory.keep_established_until_close = false;
    factory.cleanup_destination = listener.destination();
    try std.testing.expectError(error.InvalidCleanupPolicy, factory.prepareOwned(owner, &route, .connection, &cancel));
}

test "BMC transport cleanup freezes its admitted endpoint permits two cancelled dials and never reopens a closed owner" {
    const target = try CleanupLoopback.init();
    defer target.deinit();
    const other = try CleanupLoopback.init();
    defer other.deinit();
    var library: ssh.Library = .{ .active = false };
    var route: resolution.FrozenRoute = .{ .arena = .init(std.testing.allocator), .store_revision = 1, .hops = &.{} };
    defer route.deinit();
    var cancel: std.atomic.Value(bool) = .init(false);
    var host = "127.0.0.1".*;
    var factory: Factory = .{ .allocator = std.testing.allocator, .library = &library, .keep_established_until_close = true, .cleanup_destination = .{ .host = &host, .port = target.port } };
    const owner: identity.ResourceOwner = .{ .session = .{ .session_id = @fromBackingInt(908) } };
    const owned = try factory.prepareOwned(owner, &route, .connection, &cancel);
    defer owned.deinit() catch unreachable;
    const unstarted = try factory.prepareOwned(owner, &route, .connection, &cancel);
    defer unstarted.deinit() catch unreachable;
    host[0] = '9';
    factory.cleanup_destination = other.destination();
    owned.factory.cleanup_destination = other.destination();
    try std.testing.expectError(error.CleanupStreamForbidden, owned.openCleanupTcpStream());
    try owned.start();
    // A successful ordinary stream to another endpoint grants no cleanup
    // authority, even if the caller tries to replace the prepared policy.
    var unrelated = try owned.openTcpStream(other.destination());
    defer unrelated.close();
    try other.acceptAndClose();
    try std.testing.expectError(error.CleanupStreamForbidden, owned.openCleanupTcpStream());
    var admitted = try owned.openTcpStream(target.destination());
    defer admitted.close();
    try target.acceptAndClose();
    cancel.store(true, .release);
    try std.testing.expectError(error.Cancelled, unstarted.start());
    try std.testing.expectError(error.CleanupStreamForbidden, unstarted.openCleanupTcpStream());
    try std.testing.expectError(error.Cancelled, owned.openTcpStream(target.destination()));
    for (0..2) |_| {
        var cleanup = try owned.openCleanupTcpStream();
        try target.acceptAndClose();
        cleanup.close();
    }
    try std.testing.expectEqual(@as(u8, 2), owned.cleanup_open_count);
    try std.testing.expectError(error.CleanupStreamLimit, owned.openCleanupTcpStream());
    try std.testing.expectEqual(ReleaseReceipt.released, owned.close());
    try std.testing.expectError(error.TransportClosed, owned.openCleanupTcpStream());
}

test "web SOCKS owned stream fd remains valid after the transport releases its fd" {
    const testing = std.testing;
    const listener = try CleanupLoopback.init();
    defer listener.deinit();
    var library: ssh.Library = .{ .active = false };
    var route: resolution.FrozenRoute = .{ .arena = .init(testing.allocator), .store_revision = 1, .hops = &.{} };
    defer route.deinit();
    const factory: Factory = .{ .allocator = testing.allocator, .library = &library, .timeout_ms = 1000 };
    const owner: identity.ResourceOwner = .{ .session = .{ .session_id = @fromBackingInt(909) } };
    const transport = try factory.prepareOwned(owner, &route, .connection, null);
    defer transport.deinit() catch unreachable;
    try transport.start();
    var stream = try transport.openTcpStreamWithOwnedFd(listener.destination());
    defer stream.close();
    try listener.acceptAndClose();
    const fd = stream.fd;
    try testing.expectEqual(.released, transport.close());
    try testing.expectEqual(@as(c_int, std.c.FD_CLOEXEC), std.c.fcntl(fd, std.c.F.GETFD));
    stream.close();
    try testing.expectEqual(@as(c_int, -1), std.c.fcntl(fd, std.c.F.GETFD));
}
