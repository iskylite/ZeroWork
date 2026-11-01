//! BMC endpoints are TCP destinations, never a ninth SSH login hop.
//! Prepare on the configuration owner thread; connect/close only on a worker.
const std = @import("std");
const identity = @import("../../host/identity.zig");
const contexts = @import("../../host/host_context.zig");
const probes = @import("../../host/probe_contract.zig");
const resolution = @import("../../host/connection_config_resolver.zig");
const transports = @import("../../host/transport_factory.zig");

pub const Plan = struct {
    arena: std.heap.ArenaAllocator,
    route: resolution.FrozenRoute,
    destination: transports.Destination,
    owner: identity.SessionHandle,

    pub fn init(allocator: std.mem.Allocator, owner: identity.SessionHandle, resolver: ?resolution.Resolver, ids: []const identity.ConnectionId, destination: transports.Destination) !Plan {
        if (@backingInt(owner.session_id) == 0 or owner.generation == 0) return error.InvalidOwner;
        try validateDestination(destination);
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();
        var route: resolution.FrozenRoute = if (resolver) |source|
            try source.freezeRoute(ids, allocator)
        else if (ids.len == 0)
            .{ .arena = .init(allocator), .store_revision = 0, .hops = &.{} }
        else
            return error.MissingConfigResolver;
        errdefer route.deinit();
        const host = try arena.allocator().dupe(u8, destination.host);
        return .{ .arena = arena, .route = route, .owner = owner, .destination = .{ .host = host, .port = destination.port } };
    }

    pub fn deinit(self: *Plan) void {
        self.route.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Pair = struct {
    owner: identity.SessionHandle,
    transport: *transports.OwnedTransport,
    destination: transports.Destination,
    management: ?transports.OwnedStream = null,
    video: ?transports.OwnedStream = null,
    connected: bool = false,
    closed: bool = false,

    /// Credentials are resolved here before any network worker starts.
    pub fn prepare(context: contexts.HostContext, plan: *const Plan, cancel: *const std.atomic.Value(bool)) !Pair {
        try context.requireOwner(plan.owner);
        if (context.operation.owner != .session or !context.operation.owner.session.eql(plan.owner)) return error.InvalidOperationOwner;
        var factory = context.transports orelse return error.MissingOwnedTransport;
        factory.operation_key = context.operation;
        const owned = try factory.prepareOwned(.{ .session = plan.owner }, &plan.route, .connection, cancel);
        return .{ .owner = plan.owner, .transport = owned, .destination = plan.destination };
    }

    /// Probe scopes use their actual child owner/operation and never acquire a
    /// presentation context or borrow the editor's live connection.
    pub fn prepareProbe(context: probes.ProbeContext, plan: *const Plan, cancel: *const std.atomic.Value(bool)) !Pair {
        try context.requireOwner(plan.owner, context.operation);
        if (context.operation.owner != .session or !context.operation.owner.session.eql(plan.owner) or context.operation.operation_id == 0) return error.InvalidOperationOwner;
        if (context.cancelled()) return error.Cancelled;
        var factory = context.transports orelse return error.MissingOwnedTransport;
        factory.operation_key = context.operation;
        const owned = try factory.prepareOwned(.{ .session = plan.owner }, &plan.route, .probe, cancel);
        return .{ .owner = plan.owner, .transport = owned, .destination = plan.destination };
    }

    /// A single caller owns this pair. Each call creates fresh native resources.
    pub fn connect(self: *Pair) !void {
        try self.connectManagement();
        errdefer {
            if (self.management) |*stream| stream.close();
            self.management = null;
            self.connected = false;
        }
        self.video = try self.transport.openTcpStream(self.destination);
    }

    /// Read-only probes open exactly one independent TCP stream.
    pub fn connectManagement(self: *Pair) !void {
        if (self.closed) return error.RouteClosed;
        if (self.connected) return error.AlreadyConnected;
        try self.transport.start();
        self.management = try self.transport.openTcpStream(self.destination);
        self.connected = true;
    }

    /// May join native IO. Must run on the protocol/cleanup worker, never UI.
    pub fn close(self: *Pair) transports.ReleaseReceipt {
        if (!self.closed) {
            if (self.video) |*stream| stream.close();
            if (self.management) |*stream| stream.close();
            self.video = null;
            self.management = null;
            self.closed = true;
        }
        return self.transport.close();
    }

    /// The host adopts unresolved transport cleanup using the original owner.
    pub fn deinit(self: *Pair) !void {
        if (self.close() != .released) return error.CleanupIncomplete;
        try self.transport.deinit();
        self.* = undefined;
    }
};

pub fn validateDestination(destination: transports.Destination) !void {
    if (destination.port == 0 or destination.host.len == 0 or destination.host.len > 253 or !std.unicode.utf8ValidateSlice(destination.host)) return error.InvalidBmcEndpoint;
    for (destination.host) |byte| if (byte <= 0x20 or byte == 0x7f or byte == '/' or byte == '\\' or byte == '@' or byte == '#' or byte == '?') return error.InvalidBmcEndpoint;
}

test "BMC route freezes flat SSH assets and keeps TCP destination separate" {
    const hosts = @import("../../config/hosts.zig");
    var registry = try hosts.Registry.parse(std.testing.allocator, "");
    defer registry.deinit();
    const one = try registry.add(.{ .name = "one", .host = "one.invalid", .user = "u" });
    const two = try registry.add(.{ .name = "two", .host = "two.invalid", .user = "u", .route = &.{one.id} });
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(11) };
    var plan = try Plan.init(std.testing.allocator, owner, resolution.Resolver.init(&registry), &.{two.id}, .{ .host = "bmc.internal", .port = 8443 });
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), plan.route.hops.len);
    try std.testing.expectEqual(two.id, plan.route.hops[0].asset_id);
    try std.testing.expectEqualStrings("bmc.internal", plan.destination.host);
    try std.testing.expectEqual(@as(u16, 8443), plan.destination.port);
    registry.hosts[1].host = "edited.invalid";
    try std.testing.expectEqualStrings("two.invalid", plan.route.hops[0].nonsecret_config.host);
}

test "BMC route validates endpoint and missing references before any IO" {
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(11) };
    var direct = try Plan.init(std.testing.allocator, owner, null, &.{}, .{ .host = "2001:db8::1", .port = 443 });
    defer direct.deinit();
    try std.testing.expectEqual(@as(usize, 0), direct.route.hops.len);
    try std.testing.expectError(error.MissingConfigResolver, Plan.init(std.testing.allocator, owner, null, &.{@fromBackingInt(1)}, .{ .host = "bmc.internal", .port = 443 }));
    try std.testing.expectError(error.InvalidBmcEndpoint, validateDestination(.{ .host = "bmc\r\nHost: evil", .port = 443 }));
}
