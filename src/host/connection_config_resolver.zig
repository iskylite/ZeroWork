//! Read-only resolution. Call on the AssetStore owning thread, or while its
//! read lock is held. No runtime Session/forward registry is consulted.
const std = @import("std");
const hosts = @import("../config/hosts.zig");
const identity = hosts.identity;
pub const max_jumps = 8;
pub const ConfigSnapshot = struct {
    arena: std.heap.ArenaAllocator,
    asset_id: identity.ConnectionId,
    revision: u64,
    store_revision: u64,
    nonsecret_config: hosts.HostConfig,
    credential_reference: identity.AssetOwner,
    pub fn deinit(self: *ConfigSnapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
pub const FrozenHop = struct {
    asset_id: identity.ConnectionId,
    revision: u64,
    nonsecret_config: hosts.HostConfig,
    credential_reference: identity.AssetOwner,
};
/// Only authenticated SSH nodes. TCP destinations never enter this array.
pub const FrozenRoute = struct {
    arena: std.heap.ArenaAllocator,
    store_revision: u64,
    hops: []const FrozenHop,
    pub fn deinit(self: *FrozenRoute) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
pub const Resolver = struct {
    registry: *const hosts.Registry,
    pub fn init(registry: *const hosts.Registry) Resolver {
        return .{ .registry = registry };
    }
    pub fn resolve(self: Resolver, asset_id: identity.ConnectionId, expected_protocol: []const u8, backing: std.mem.Allocator) !ConfigSnapshot {
        const revision = self.registry.revision;
        const host = self.registry.hosts[self.registry.indexOf(asset_id) orelse return error.ConnectionNotFound];
        try check(host, expected_protocol);
        var arena: std.heap.ArenaAllocator = .init(backing);
        errdefer arena.deinit();
        const nonsecret = try freeze(arena.allocator(), host);
        if (revision != self.registry.revision) return error.RevisionConflict;
        return .{ .arena = arena, .asset_id = asset_id, .revision = host.revision, .store_revision = revision, .nonsecret_config = nonsecret, .credential_reference = host.owner() };
    }
    pub fn freezeRoute(self: Resolver, ids: []const identity.ConnectionId, backing: std.mem.Allocator) !FrozenRoute {
        if (ids.len > max_jumps) return error.TooManyJumps;
        const revision = self.registry.revision;
        var arena: std.heap.ArenaAllocator = .init(backing);
        errdefer arena.deinit();
        const a = arena.allocator();
        const hops = try a.alloc(FrozenHop, ids.len);
        for (ids, 0..) |id, i| {
            for (ids[0..i]) |previous| if (previous == id) return error.DuplicateRoute;
            const host = self.registry.hosts[self.registry.indexOf(id) orelse return error.MissingRouteReference];
            try check(host, "ssh");
            for (hops[0..i]) |previous| if (sameEndpoint(previous.nonsecret_config, host)) return error.DuplicateEndpoint;
            hops[i] = .{ .asset_id = id, .revision = host.revision, .nonsecret_config = try freeze(a, host), .credential_reference = host.owner() };
        }
        if (revision != self.registry.revision) return error.RevisionConflict;
        return .{ .arena = arena, .store_revision = revision, .hops = hops };
    }
    /// Offline save checks only structure and explicit references; it does not
    /// request credentials, resolve DNS or open a network connection.
    pub fn validateOffline(self: Resolver, host: hosts.HostConfig) !void {
        try host.validate();
        var route = try self.freezeRoute(host.route, std.heap.page_allocator);
        defer route.deinit();
        for (route.hops) |hop| {
            if (hop.asset_id == host.connection_id or sameEndpoint(hop.nonsecret_config, host)) return error.RouteCycle;
        }
    }
};
fn check(host: hosts.HostConfig, expected: []const u8) !void {
    if (!std.mem.eql(u8, host.protocolId(), expected)) return error.ProtocolMismatch;
    if (host.payload_version != 1) return error.UnsupportedPayloadVersion;
    try host.validate();
}
fn freeze(a: std.mem.Allocator, original: hosts.HostConfig) !hosts.HostConfig {
    // Whitelist connection inputs. Shell startup, PTY/environment, legacy
    // secret literals, plugin extension bytes and listener state never escape.
    const value: hosts.HostConfig = .{
        .connection_id = original.connection_id,
        .revision = original.revision,
        .protocol = original.protocol,
        .protocol_id = original.protocol_id,
        .payload_version = original.payload_version,
        .name = original.name,
        .host = original.host,
        .port = original.port,
        .user = original.user,
        .auth_mode = original.auth_mode,
        .identity_file = original.identity_file,
        .strict_host_key_checking = original.strict_host_key_checking,
        .compression = original.compression,
        .keepalive = original.keepalive,
    };
    return hosts.cloneConfig(a, value);
}
fn canonicalHost(value: []const u8) []const u8 {
    var host = std.mem.trim(u8, value, " \t\r\n");
    if (host.len > 1 and host[0] == '[' and host[host.len - 1] == ']') host = host[1 .. host.len - 1];
    return std.mem.trimEnd(u8, host, ".");
}
pub fn sameEndpoint(a: hosts.HostConfig, b: hosts.HostConfig) bool {
    if (a.port != b.port) return false;
    const left = canonicalHost(a.host);
    const right = canonicalHost(b.host);
    const left_ip = std.Io.net.IpAddress.parse(left, a.port) catch return std.ascii.eqlIgnoreCase(left, right);
    const right_ip = std.Io.net.IpAddress.parse(right, b.port) catch return false;
    return std.meta.eql(left_ip, right_ip);
}

test "flat route freezes revisions, ignores nested routes, permits 8 SSH nodes and no TCP target" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var registry: hosts.Registry = .{ .arena = .init(std.testing.allocator), .hosts = &.{} };
    defer registry.deinit();
    for (0..8) |i| _ = try registry.add(.{ .name = try std.fmt.allocPrint(arena.allocator(), "h{d}", .{i}), .host = try std.fmt.allocPrint(arena.allocator(), "h{d}.invalid", .{i}), .user = "u", .password = "secret" });
    var ids: [9]identity.ConnectionId = undefined;
    for (registry.hosts, 0..) |host, i| ids[i] = host.connection_id;
    registry.hosts[0].route = &.{ids[1]};
    var frozen = try Resolver.init(&registry).freezeRoute(ids[0..8], std.testing.allocator);
    defer frozen.deinit();
    try std.testing.expectEqual(@as(usize, 8), frozen.hops.len);
    try std.testing.expectEqual(@as(usize, 0), frozen.hops[0].nonsecret_config.route.len);
    try std.testing.expect(frozen.hops[0].nonsecret_config.password == null);
    registry.hosts[0].revision += 1;
    try std.testing.expectEqual(@as(u64, 1), frozen.hops[0].revision);
    try std.testing.expectError(error.TooManyJumps, Resolver.init(&registry).freezeRoute(&ids, std.testing.allocator));
    try std.testing.expectError(error.DuplicateRoute, Resolver.init(&registry).freezeRoute(&.{ ids[0], ids[0] }, std.testing.allocator));
    var empty = try Resolver.init(&registry).freezeRoute(&.{}, std.testing.allocator);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.hops.len);
}

test "resolver rejects missing wrong-version wrong-protocol duplicate endpoints and offline unresolved references" {
    var registry: hosts.Registry = .{ .arena = .init(std.testing.allocator), .hosts = &.{} };
    defer registry.deinit();
    const one = try registry.add(.{ .name = "one", .host = "EXAMPLE.invalid.", .user = "u", .auth_mode = .password });
    const two = try registry.add(.{ .name = "two", .host = "example.invalid", .user = "u" });
    const sftp = try registry.add(.{ .name = "files", .host = "files.invalid", .user = "u", .protocol = .sftp });
    const resolution = Resolver.init(&registry);
    try std.testing.expectError(error.DuplicateEndpoint, resolution.freezeRoute(&.{ one.id, two.id }, std.testing.allocator));
    try std.testing.expectError(error.ProtocolMismatch, resolution.freezeRoute(&.{sftp.id}, std.testing.allocator));
    try std.testing.expectError(error.MissingRouteReference, resolution.freezeRoute(&.{@fromBackingInt(999)}, std.testing.allocator));
    try std.testing.expectError(error.ConnectionNotFound, resolution.resolve(@fromBackingInt(999), "ssh", std.testing.allocator));
    try std.testing.expectError(error.ProtocolMismatch, resolution.resolve(one.id, "sftp", std.testing.allocator));
    registry.hosts[1].payload_version = 99;
    try std.testing.expectError(error.UnsupportedPayloadVersion, resolution.resolve(two.id, "ssh", std.testing.allocator));
    registry.hosts[1].payload_version = 1;
    var saved = try resolution.resolve(one.id, "ssh", std.testing.allocator);
    defer saved.deinit();
    registry.hosts[0].revision += 1;
    var reconnected = try resolution.resolve(one.id, "ssh", std.testing.allocator);
    defer reconnected.deinit();
    try std.testing.expectEqual(@as(u64, 1), saved.revision);
    try std.testing.expectEqual(@as(u64, 2), reconnected.revision);
    // Password is requested only at connect time, so offline save succeeds.
    try resolution.validateOffline(.{ .name = "offline", .host = "offline.invalid", .user = "u", .auth_mode = .password, .route = &.{one.id} });
    try std.testing.expectError(error.MissingRouteReference, resolution.validateOffline(.{ .name = "offline", .host = "offline.invalid", .user = "u", .route = &.{@fromBackingInt(999)} }));
    try registry.remove(.{ .id = one.id, .revision = 2 });
    try std.testing.expectEqualStrings("EXAMPLE.invalid.", saved.nonsecret_config.host);
    try std.testing.expectError(error.ConnectionNotFound, Resolver.init(&registry).resolve(one.id, "ssh", std.testing.allocator));
}

test "resolver canonical endpoints compare IPv6 literals without network or DNS" {
    const a: hosts.HostConfig = .{ .name = "a", .host = "[::1]", .user = "u" };
    const b: hosts.HostConfig = .{ .name = "b", .host = "0:0:0:0:0:0:0:1", .user = "u" };
    try std.testing.expect(sameEndpoint(a, b));
}
