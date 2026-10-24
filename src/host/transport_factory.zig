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
pub const max_streams = 16;
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
    operation_key: ?@import("operation.zig").OperationKey = null,
    failed_open_owner: ?FailedOpenOwner = null,

    pub fn prepareOwned(self: Factory, owner: identity.ResourceOwner, route: *const resolution.FrozenRoute, purpose: Purpose, cancel: ?*const std.atomic.Value(bool)) !*OwnedTransport {
        if (route.hops.len > resolution.max_jumps) return error.TooManyJumps;
        if (cancel) |token| if (token.load(.acquire)) return error.Cancelled;
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
};
pub const OwnedStream = struct {
    transport: *OwnedTransport,
    index: usize,
    generation: u64,
    /// Borrowed until close or transport close. IO never calls libssh2.
    fd: c_int,
    pub fn close(self: *OwnedStream) void {
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

    pub fn start(self: *OwnedTransport) !void {
        if (self.started) return error.TransportAlreadyStarted;
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
        if (destination.host.len == 0 or destination.host.len > 255 or std.mem.indexOfAny(u8, destination.host, "\x00\r\n") != null or destination.port == 0) return error.InvalidDestination;
        self.mutex.lock();
        if (self.closing.load(.acquire) or self.done.load(.acquire)) {
            self.mutex.unlock();
            return error.TransportClosed;
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
        slot.* = .{ .generation = generation, .state = .pending, .port = destination.port, .host_len = destination.host.len, .open_deadline_ns = @import("../platform/realtime.zig").monotonicNs() + @as(i128, self.factory.timeout_ms) * std.time.ns_per_ms };
        @memcpy(slot.host[0..destination.host.len], destination.host);
        self.mutex.unlock();
        while (true) {
            self.mutex.lock();
            const state = slot.state;
            const fd = slot.fd;
            const failure = slot.failure;
            if (state == .failed) slot.state = .free;
            self.mutex.unlock();
            if (state == .active) return .{ .transport = self, .index = index, .generation = generation, .fd = fd };
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
        return self.closing.load(.acquire) or (if (self.external_cancel) |token| token.load(.acquire) else false);
    }
    fn run(self: *OwnedTransport) void {
        self.connect() catch |err| {
            self.failure = err;
            self.ready.store(true, .release);
            self.releaseNative();
            return;
        };
        self.ready.store(true, .release);
        while (!self.cancelled()) {
            self.mutex.lock();
            self.step();
            self.mutex.unlock();
            pause();
        }
        self.releaseNative();
    }
    fn connect(self: *OwnedTransport) !void {
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
            const fd = c.zw_ssh_socket_connect_cancellable(host.ptr, slot.port, self.factory.timeout_ms, isCancelled, self);
            if (fd < 0) return if (self.cancelled()) error.Cancelled else error.TcpConnectFailed;
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
};
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
