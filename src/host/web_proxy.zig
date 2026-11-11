//! Host-owned proxy for a single web session generation. All preparation
//! that touches saved asset credentials stays on the configuration thread.
const std = @import("std");
const identity = @import("identity.zig");
const OperationKey = @import("operation.zig").OperationKey;
const resolution = @import("connection_config_resolver.zig");
const transports = @import("transport_factory.zig");
const forwarder = @import("../proto/ssh/web_socks_proxy.zig");
const wakeup = @import("../platform/presentation_wakeup.zig");

const Pump = forwarder.Pump(transports.OwnedStream, transports.max_streams);
pub var acceptance_hold_native_cleanup: std.atomic.Value(bool) = .init(false);

pub const Phase = enum { prepared, connecting, ready, closing, failed, closed };
pub const Snapshot = struct {
    owner: identity.SessionHandle,
    operation: OperationKey,
    phase: Phase,
    cleanup: transports.ReleaseReceipt,
    failure: ?anyerror,
    counts: forwarder.Counts,
};

/// Keep the endpoint private to the native view's proxy configuration. The
/// password and port are neither connection data nor presentation state.
pub const Endpoint = struct { port: u16, credentials: forwarder.Credentials };

pub const Proxy = struct {
    allocator: std.mem.Allocator,
    owner: identity.SessionHandle,
    operation: OperationKey,
    transport: ?*transports.OwnedTransport = null,
    pump: Pump,
    cancelled: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),
    cleanup_raw: std.atomic.Value(u8) = .init(@backingInt(transports.ReleaseReceipt.awaiting)),
    started: bool = false,
    failure: ?anyerror = null,
    acceptance_worker_ids: [2]std.atomic.Value(std.Thread.Id) = @splat(.init(0)),
    acceptance_opener_ids: [forwarder.max_openers]std.atomic.Value(std.Thread.Id) = @splat(.init(0)),

    pub fn prepare(
        factory: transports.Factory,
        owner: identity.SessionHandle,
        operation: OperationKey,
        route: *const resolution.FrozenRoute,
    ) !*Proxy {
        if (route.hops.len == 0) return error.MissingSshRoute;
        if (@backingInt(owner.session_id) == 0 or owner.generation == 0 or
            operation.operation_id == 0 or operation.owner != .session or !operation.owner.session.eql(owner))
            return error.InvalidOperationOwner;
        if (factory.operation_key) |key| if (!key.eql(operation)) return error.InvalidOperationOwner;
        if (factory.timeout_ms == 0) return error.InvalidProxyTimeout;

        const self = try factory.allocator.create(Proxy);
        errdefer factory.allocator.destroy(self);
        self.* = .{
            .allocator = factory.allocator,
            .owner = owner,
            .operation = operation,
            .pump = .{
                .credentials = forwarder.Credentials.generate(),
                .cancelled = &self.cancelled,
                .timeout_ms = factory.timeout_ms,
                .backend = .{ .context = self, .open = open, .available = available },
            },
        };
        errdefer self.clearCredentials();
        var owned_factory = factory;
        owned_factory.operation_key = operation;
        owned_factory.keep_established_until_close = false;
        owned_factory.cleanup_destination = null;
        owned_factory.detect_socket_disconnect = true;
        self.transport = try owned_factory.prepareOwned(.{ .session = owner }, route, .connection, &self.cancelled);
        return self;
    }

    /// Main thread. No join or network operation on this thread.
    pub fn start(self: *Proxy) !void {
        if (self.started) return error.ProxyAlreadyStarted;
        if (self.cancelled.load(.acquire)) return error.Cancelled;
        const thread = try std.Thread.spawn(.{}, run, .{self});
        self.started = true;
        thread.detach();
    }

    pub fn endpoint(self: *const Proxy, owner: identity.SessionHandle, operation: OperationKey) ?Endpoint {
        if (!self.owner.eql(owner) or !self.operation.eql(operation) or self.cancelled.load(.acquire)) return null;
        const port = self.pump.port.load(.acquire);
        if (port == 0 or self.cancelled.load(.acquire)) return null;
        return .{ .port = port, .credentials = self.pump.credentials };
    }

    pub fn snapshot(self: *const Proxy) Snapshot {
        const finished = self.finished.load(.acquire);
        const stopped = self.cancelled.load(.acquire);
        const ready = self.pump.port.load(.acquire) != 0;
        const failure = if (finished) self.failure else null;
        return .{
            .owner = self.owner,
            .operation = self.operation,
            .phase = if (finished)
                (if (failure != null) .failed else .closed)
            else if (stopped)
                .closing
            else if (ready)
                .ready
            else if (self.started)
                .connecting
            else
                .prepared,
            .cleanup = self.receipt(),
            .failure = failure,
            .counts = self.pump.counts.load(.acquire),
        };
    }

    pub fn observeAcceptanceWorkers(self: *Proxy) void {
        std.debug.assert(!self.started);
        self.pump.acceptance_worker_ids = &self.acceptance_opener_ids;
    }

    pub fn acceptanceWorkers(self: *const Proxy) [2 + forwarder.max_openers]std.Thread.Id {
        var ids: [2 + forwarder.max_openers]std.Thread.Id = undefined;
        for (&ids, 0..) |*id, index| {
            id.* = if (index < 2)
                self.acceptance_worker_ids[index].load(.acquire)
            else
                self.acceptance_opener_ids[index - 2].load(.acquire);
        }
        return ids;
    }

    pub fn requestStop(self: *Proxy) void {
        self.cancelled.store(true, .release);
    }

    /// Retain the same owner/operation and dependency lifetimes while native
    /// cleanup remains incomplete. The caller's reservation stays occupied.
    pub fn retryCleanup(self: *Proxy) !void {
        if (!self.finished.load(.acquire)) return error.CleanupInProgress;
        if (self.receipt() == .released) return;
        self.finished.store(false, .release);
        errdefer self.finished.store(true, .release);
        const thread = try std.Thread.spawn(.{}, retryWorker, .{self});
        thread.detach();
    }

    pub fn deinit(self: *Proxy) !void {
        self.requestStop();
        if (self.started) {
            if (!self.finished.load(.acquire) or self.receipt() != .released) return error.CleanupInProgress;
        } else if (self.transport) |transport| {
            // The prepared transport has never opened a socket or thread.
            try transport.deinit();
        }
        self.clearCredentials();
        self.allocator.destroy(self);
    }

    fn receipt(self: *const Proxy) transports.ReleaseReceipt {
        return @fromBackingInt(@intCast(self.cleanup_raw.load(.acquire)));
    }

    fn clearCredentials(self: *Proxy) void {
        std.crypto.secureZero(u8, &self.pump.credentials.username);
        std.crypto.secureZero(u8, &self.pump.credentials.password);
    }

    fn run(self: *Proxy) void {
        const transport = self.transport.?;
        if (transport.start()) |_| {
            if (@import("builtin").os.tag == .macos and self.pump.acceptance_worker_ids != null) {
                self.acceptance_worker_ids[0].store(std.Thread.getCurrentId(), .release);
                var id: u64 = 0;
                if (transport.thread) |thread| {
                    if (std.c.pthread_threadid_np(thread.getHandle(), &id) == 0) {
                        self.acceptance_worker_ids[1].store(id, .release);
                    }
                }
            }
            self.pump.run(0, notifyReady) catch |err| {
                self.failure = err;
            };
        } else |err| {
            if (err != error.Cancelled) self.failure = err;
        }
        self.cancelled.store(true, .release);
        self.cleanupWorker();
    }

    fn cleanupWorker(self: *Proxy) void {
        const transport = self.transport.?;
        const release = transport.close();
        if (release == .released) {
            transport.deinit() catch unreachable;
            self.transport = null;
        }
        self.cleanup_raw.store(@backingInt(release), .release);
        self.finished.store(true, .release);
        wakeup.notify();
    }

    fn retryWorker(self: *Proxy) void {
        // Unknown native resources remain owned between attempts. Pace
        // retries off the UI thread so shutdown can publish the unknown
        // receipt without continuously redrawing the workspace.
        const clock = @import("../platform/realtime.zig");
        const deadline = clock.monotonicNs() + std.time.ns_per_s;
        while (true) {
            const remaining = deadline - clock.monotonicNs();
            if (remaining <= 0) break;
            const wait_ms: c_int = @intCast(@divTrunc(remaining + std.time.ns_per_ms - 1, std.time.ns_per_ms));
            var no_fds: [0]std.c.pollfd = .{};
            _ = std.c.poll(&no_fds, 0, wait_ms);
        }
        self.cleanupWorker();
    }

    fn open(context: *anyopaque, target: forwarder.Target) anyerror!transports.OwnedStream {
        const self: *Proxy = @ptrCast(@alignCast(context));
        return self.transport.?.openTcpStreamWithOwnedFd(.{ .host = target.hostname(), .port = target.port });
    }

    fn available(context: *anyopaque) bool {
        const self: *Proxy = @ptrCast(@alignCast(context));
        return !self.transport.?.isStopping();
    }

    fn notifyReady(_: *anyopaque) void {
        wakeup.notify();
    }
};

test "web SOCKS host rejects a direct transport before any preparation" {
    const ssh = @import("../proto/ssh/session.zig");
    var library: ssh.Library = .{ .active = false };
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(1) };
    const operation: OperationKey = .{ .owner = .{ .session = owner }, .operation_id = 1 };
    var route: resolution.FrozenRoute = .{ .arena = .init(std.testing.allocator), .store_revision = 1, .hops = &.{} };
    defer route.deinit();
    try std.testing.expectError(error.MissingSshRoute, Proxy.prepare(.{
        .allocator = std.testing.allocator,
        .library = &library,
    }, owner, operation, &route));
}

test "web SOCKS host cancels a pending loopback SSH greeting and releases its reservation" {
    const testing = std.testing;
    const c = std.c;
    const Reservation = struct {
        count: std.atomic.Value(usize) = .init(0),

        fn reserve(context: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.count.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return error.FixtureBudgetExceeded;
        }

        fn release(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = self.count.fetchSub(1, .acq_rel);
        }

        fn adopt(_: *anyopaque, _: *transports.OwnedTransport) void {
            @panic("proxy must retain its original owner while closing");
        }
    };

    const listener = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (listener < 0) return error.FixtureSocketUnavailable;
    defer _ = c.close(listener);
    var address: c.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (c.bind(listener, @ptrCast(&address), @sizeOf(@TypeOf(address))) != 0 or c.listen(listener, 1) != 0) return error.FixtureListenFailed;
    var address_len: c.socklen_t = @sizeOf(@TypeOf(address));
    if (c.getsockname(listener, @ptrCast(&address), &address_len) != 0) return error.FixtureAddressUnavailable;

    const ssh = @import("../proto/ssh/session.zig");
    var library = try ssh.Library.init();
    defer library.deinit();
    var registry: @import("../config/hosts.zig").Registry = .{ .arena = .init(testing.allocator), .hosts = &.{} };
    defer registry.deinit();
    const fixture = try registry.add(.{
        .name = "Disposable fixture",
        .host = "127.0.0.1",
        .port = std.mem.bigToNative(u16, address.port),
        .user = "fixture",
    });
    var route = try resolution.Resolver.init(&registry).freezeRoute(&.{fixture.id}, testing.allocator);
    defer route.deinit();
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(2) };
    const operation: OperationKey = .{ .owner = .{ .session = owner }, .operation_id = 2 };
    var reservation: Reservation = .{};
    const proxy = try Proxy.prepare(.{
        .allocator = testing.allocator,
        .library = &library,
        .timeout_ms = 1000,
        .failed_open_owner = .{
            .context = &reservation,
            .reserve = Reservation.reserve,
            .release = Reservation.release,
            .adopt = Reservation.adopt,
        },
    }, owner, operation, &route);
    defer {
        proxy.requestStop();
        var no_fds: [0]c.pollfd = .{};
        const clock = @import("../platform/realtime.zig");
        const deadline = clock.monotonicNs() + 3 * std.time.ns_per_s;
        while (proxy.started and !proxy.finished.load(.acquire) and clock.monotonicNs() < deadline) {
            _ = c.poll(&no_fds, 0, 5);
        }
        proxy.deinit() catch @panic("loopback fixture left a transport owner");
    }
    try testing.expectEqual(@as(usize, 1), reservation.count.load(.acquire));
    try proxy.start();
    var fds = [_]c.pollfd{.{ .fd = listener, .events = c.POLL.IN, .revents = 0 }};
    if (c.poll(&fds, fds.len, 1500) <= 0) return error.FixtureAcceptTimeout;
    const peer = c.accept(listener, null, null);
    if (peer < 0) return error.FixtureAcceptFailed;
    defer _ = c.close(peer);
    try testing.expectEqual(.connecting, proxy.snapshot().phase);
    try testing.expectEqual(@as(?Endpoint, null), proxy.endpoint(owner, operation));
    proxy.requestStop();
    var no_fds: [0]c.pollfd = .{};
    const clock = @import("../platform/realtime.zig");
    const deadline = clock.monotonicNs() + 2 * std.time.ns_per_s;
    while (!proxy.finished.load(.acquire) and clock.monotonicNs() < deadline) {
        _ = c.poll(&no_fds, 0, 5);
    }
    try testing.expectEqual(.released, proxy.snapshot().cleanup);
    try proxy.retryCleanup();
    try testing.expectEqual(@as(usize, 0), reservation.count.load(.acquire));
    try testing.expectEqual(forwarder.Counts{}, proxy.snapshot().counts);
}
