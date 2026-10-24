//! Opt-in, read-only production TransportFactory acceptance. Credentials enter
//! through environment variables; logs contain resource/status evidence only.
const std = @import("std");
const transports = @import("host/transport_factory.zig");
const resolver = @import("host/connection_config_resolver.zig");
const hosts = @import("config/hosts.zig");
const ssh = @import("proto/ssh/session.zig");
const clock = @import("platform/realtime.zig");

fn emit(value: anytype) void {
    const json = std.json.Stringify.valueAlloc(std.heap.c_allocator, value, .{}) catch return;
    defer std.heap.c_allocator.free(json);
    std.debug.print("OWNED_TRANSPORT {s}\n", .{json});
}
const Auth = struct {
    fn resolve(_: *anyopaque, _: hosts.identity.ResourceOwner, _: hosts.identity.AssetOwner, a: std.mem.Allocator) !ssh.Auth {
        if (std.c.getenv("ZEROWORK_TRANSPORT_KEY")) |key| return .{ .private_key = .{ .path = try a.dupeSentinel(u8, std.mem.span(key), 0) } };
        const password = std.c.getenv("ZEROWORK_TRANSPORT_PASSWORD") orelse return error.MissingCredential;
        return .{ .password = try a.dupeSentinel(u8, std.mem.span(password), 0) };
    }
};
fn banner(stream: transports.OwnedStream) !void {
    var bytes: [256]u8 = undefined;
    var count: usize = 0;
    const deadline = clock.monotonicNs() + 8 * std.time.ns_per_s;
    while (clock.monotonicNs() < deadline) {
        var fds = [_]std.c.pollfd{.{ .fd = stream.fd, .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&fds, 1, 50) > 0) {
            const n = std.c.read(stream.fd, bytes[count..].ptr, bytes.len - count);
            if (n > 0) {
                count += @intCast(n);
                if (std.mem.indexOfScalar(u8, bytes[0..count], '\n') != null) {
                    if (!std.mem.startsWith(u8, bytes[0..count], "SSH-2.0-")) return error.UnexpectedBanner;
                    return;
                }
                if (count == bytes.len) return error.OversizeBanner;
            } else if (n == 0) return error.UnexpectedEof;
        }
    }
    return error.BannerTimeout;
}
fn env(key: [:0]const u8, default: []const u8) []const u8 {
    return if (std.c.getenv(key)) |value| std.mem.span(value) else default;
}
pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const mode = args.next() orelse "dual";
    const a = init.gpa;
    var registry: hosts.Registry = .{ .arena = .init(a), .hosts = &.{} };
    defer registry.deinit();
    const source = try registry.add(.{ .name = "acceptance source", .host = std.mem.span(std.c.getenv("ZEROWORK_TRANSPORT_HOST") orelse return error.MissingHost), .port = try std.fmt.parseInt(u16, env("ZEROWORK_TRANSPORT_PORT", "22"), 10), .user = env("ZEROWORK_TRANSPORT_USER", "root"), .auth_mode = if (std.c.getenv("ZEROWORK_TRANSPORT_KEY") != null) .private_key else .password, .identity_file = if (std.c.getenv("ZEROWORK_TRANSPORT_KEY")) |key| std.mem.span(key) else null });
    var route_ids: std.ArrayList(hosts.identity.ConnectionId) = .empty;
    defer route_ids.deinit(a);
    try route_ids.append(a, source.id);
    if (std.c.getenv("ZEROWORK_TRANSPORT_EXTRA_PORTS")) |ports| {
        var parts = std.mem.splitScalar(u8, std.mem.span(ports), ',');
        while (parts.next()) |part| {
            if (part.len == 0) continue;
            const name = try std.fmt.allocPrint(a, "acceptance hop {d}", .{route_ids.items.len});
            defer a.free(name);
            var config = registry.hosts[0];
            config.name = name;
            config.port = try std.fmt.parseInt(u16, part, 10);
            const hop = try registry.add(config);
            try route_ids.append(a, hop.id);
        }
    }
    if (std.c.getenv("ZEROWORK_TRANSPORT_DIRECT") != null) route_ids.clearRetainingCapacity();
    var frozen = try resolver.Resolver.init(&registry).freezeRoute(route_ids.items, a);
    defer frozen.deinit();
    var library = try ssh.Library.init();
    defer library.deinit();
    var retainer: Retainer = .{};
    defer retainer.drain();
    var context: u8 = 0;
    const factory: transports.Factory = .{ .allocator = a, .library = &library, .credentials = .{ .context = &context, .resolve = Auth.resolve }, .host_key_decision = .trust_once, .timeout_ms = try std.fmt.parseInt(u32, env("ZEROWORK_TRANSPORT_TIMEOUT_MS", "4000"), 10), .failed_open_owner = retainer.interface() };
    const first = factory.openOwned(.{ .session = .{ .session_id = @fromBackingInt(93001) } }, &frozen, .probe, null) catch |err| {
        emit(.{ .phase = "source_failed", .failure = @errorName(err), .native_library_owners = ssh.Library.activeOwners() });
        return err;
    };
    defer first.deinit() catch {};
    emit(.{ .phase = "source_ready", .authenticated_ssh_nodes = frozen.hops.len, .shell = false, .known_hosts_written = false });
    const destination: transports.Destination = .{ .host = env("ZEROWORK_TRANSPORT_DESTINATION", "127.0.0.1"), .port = try std.fmt.parseInt(u16, env("ZEROWORK_TRANSPORT_DESTINATION_PORT", "22"), 10) };
    if (std.mem.eql(u8, mode, "unreachable")) {
        var unexpected = first.openTcpStream(destination) catch |err| {
            const receipt = first.close();
            emit(.{ .phase = "destination_failed", .failure = @errorName(err), .ssh_nodes = 1, .destination_ssh_login = false, .cleanup = @tagName(receipt) });
            if (receipt != .released) return error.CleanupIncomplete;
            return;
        };
        unexpected.close();
        return error.ExpectedUnreachable;
    }
    var one = first.openTcpStream(destination) catch |err| {
        emit(.{ .phase = "stream_failed", .failure = @errorName(err), .cleanup = @tagName(first.close()) });
        return err;
    };
    defer one.close();
    var two = try first.openTcpStream(destination);
    defer two.close();
    try verify(one, mode);
    try verify(two, mode);
    emit(.{ .phase = "first_owner_dual_streams_verified", .streams = 2, .tcp_destination_authenticated = false });
    var fixture_pair = @import("plugins/fixture_probe/transport.zig").Pair.open(factory, .{ .session_id = @fromBackingInt(93002) }, &frozen, destination, null) catch |err| {
        emit(.{ .phase = "second_owner_failed", .failure = @errorName(err), .first_cleanup = @tagName(first.close()) });
        return err;
    };
    defer fixture_pair.deinit() catch {};
    const second = fixture_pair.owned;
    emit(.{ .phase = "second_owner_ready", .native_session_distinct = first.nativeSessionIdentity() != second.nativeSessionIdentity() });
    if (frozen.hops.len != 0 and (first.nativeSessionIdentity() == 0 or first.nativeSessionIdentity() == second.nativeSessionIdentity())) return error.SharedNativeSession;
    const other_one = fixture_pair.observation;
    const other_two = fixture_pair.management;
    const first_receipt = first.close();
    try verify(other_one, mode);
    try verify(other_two, mode);
    var after_close = try second.openTcpStream(destination);
    defer after_close.close();
    try verify(after_close, mode);
    const second_receipt = second.close();
    emit(.{ .phase = "complete", .owners = 2, .distinct_native_sessions = frozen.hops.len != 0, .simultaneous_streams_per_owner = 2, .first_close_preserved_second = true, .second_new_stream_after_first_close = true, .ssh_nodes_per_owner = frozen.hops.len, .tcp_destination_authenticated = false, .first_cleanup = @tagName(first_receipt), .second_cleanup = @tagName(second_receipt) });
    if (first_receipt != .released or second_receipt != .released) return error.CleanupIncomplete;
}

fn verify(stream: transports.OwnedStream, mode: []const u8) !void {
    if (!std.mem.eql(u8, mode, "fixture")) return banner(stream);
    var payload: [16384]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @truncate(i);
    const deadline = clock.monotonicNs() + 8 * std.time.ns_per_s;
    var sent: usize = 0;
    var received: usize = 0;
    var result: [16384]u8 = undefined;
    while (received < payload.len) {
        if (clock.monotonicNs() > deadline) return error.PayloadTimeout;
        if (sent < payload.len) {
            const n = std.c.write(stream.fd, payload[sent..].ptr, payload.len - sent);
            if (n > 0) sent += @intCast(n);
        }
        const n = std.c.read(stream.fd, result[received..].ptr, result.len - received);
        if (n > 0) received += @intCast(n) else if (n == 0) return error.PayloadEof;
        var fds: [1]std.c.pollfd = undefined;
        _ = std.c.poll(&fds, 0, 2);
    }
    if (!std.mem.eql(u8, &payload, &result)) return error.PayloadMismatch;
}

pub const Retainer = struct {
    entries: [16]?*transports.OwnedTransport = @splat(null),
    pending: usize = 0,
    fn interface(self: *Retainer) transports.FailedOpenOwner {
        return .{ .context = self, .reserve = reserve, .release = release, .adopt = adopt };
    }
    fn reserve(raw: *anyopaque) !void {
        const self: *Retainer = @ptrCast(@alignCast(raw));
        var count = self.pending;
        for (self.entries) |entry| if (entry != null) {
            count += 1;
        };
        if (count == self.entries.len) return error.CleanupCapacity;
        self.pending += 1;
    }
    fn release(raw: *anyopaque) void {
        const self: *Retainer = @ptrCast(@alignCast(raw));
        std.debug.assert(self.pending > 0);
        self.pending -= 1;
    }
    fn adopt(raw: *anyopaque, owned: *transports.OwnedTransport) void {
        const self: *Retainer = @ptrCast(@alignCast(raw));
        release(raw);
        for (&self.entries) |*entry| if (entry.* == null) {
            entry.* = owned;
            return;
        };
        unreachable; // reserve guaranteed capacity before any allocation or IO.
    }
    fn drain(self: *Retainer) void {
        for (&self.entries) |*entry| if (entry.*) |owned| {
            if (owned.close() == .released) {
                owned.deinit() catch unreachable;
                entry.* = null;
            }
        };
    }
};

test "failed open unknown graph transfers into pre-reserved cleanup owner and later releases" {
    var library: ssh.Library = .{ .active = false };
    var retainer: Retainer = .{};
    try Retainer.reserve(&retainer);
    const owned = try std.testing.allocator.create(transports.OwnedTransport);
    owned.* = .{ .factory = .{ .allocator = std.testing.allocator, .library = &library, .failed_open_owner = retainer.interface() }, .owner = .{ .session = .{ .session_id = @fromBackingInt(812), .generation = 2 } }, .purpose = .probe, .external_cancel = null, .arena = .init(std.testing.allocator), .started = true, .reserved_cleanup = true, .done = .init(true), .receipt = .unknown, .ledger = try ssh.ResourceLedger.init(null, 1) };
    try std.testing.expect(owned.ledger.?.record(null, 0, .transport, .owned));
    try std.testing.expect(owned.ledger.?.record(null, 0, .transport, .unknown));
    try std.testing.expectEqual(transports.ReleaseReceipt.unknown, try owned.adoptFailedOpen());
    try std.testing.expectEqual(@as(usize, 0), retainer.pending);
    try std.testing.expect(retainer.entries[0] == owned);
    try std.testing.expectEqual(@as(u64, 2), retainer.entries[0].?.owner.session.generation);
    retainer.drain();
    try std.testing.expect(retainer.entries[0] != null);
    // Only the real native release acknowledgement can advance this receipt.
    try std.testing.expect(retainer.entries[0].?.ledger.?.record(null, 0, .transport, .released));
    retainer.drain();
    try std.testing.expect(retainer.entries[0] == null);
}
