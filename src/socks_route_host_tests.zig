const std = @import("std");
const socks = @import("host/socks_route_host.zig");
const sessions = @import("host/session_host.zig");
const plugins = @import("host/plugin_registry.zig");
const ssh = @import("proto/ssh/session.zig");
const Forward = @import("proto/ssh/forward_service.zig");

const Adapter = struct {
    fn interface(self: *Adapter) sessions.Adapter {
        return .{ .context = self, .registration = .{ .plugin_id = .ssh, .workspace_kind = .terminal, .services = plugins.builtin_descriptors[1].services }, .vtable = &.{ .create = create, .cancel = cancel, .close = close, .release_stale = stale } };
    }
    fn create(_: *anyopaque, _: sessions.CreateRequest) !void {}
    fn cancel(_: *anyopaque, _: sessions.OperationKey) sessions.CloseReceipt {
        return .released;
    }
    fn close(_: *anyopaque, _: sessions.SessionHandle, _: sessions.OperationKey) !sessions.CloseReceipt {
        return .released;
    }
    fn stale(_: *anyopaque, _: sessions.SessionHandle, _: sessions.OperationKey) void {}
};
fn source() sessions.SessionCreateSpec {
    return .{ .saved = .{ .connection_id = @fromBackingInt(3), .config_revision = 7, .protocol = .ssh, .immutable_config = .{ .endpoint = .{ .host = "target.test", .user = "target" }, .auth = .{ .password = "target-secret" }, .strict_host_key_checking = false, .startup_commands = &.{"must-not-execute"} }, .route_snapshot = &.{
        .{ .owner = .{ .id = @fromBackingInt(1), .revision = 3 }, .display_name = "first", .endpoint = .{ .host = "first.test", .user = "first" }, .auth = .password_prompt, .strict_host_key_checking = true },
        .{ .owner = .{ .id = @fromBackingInt(2), .revision = 4 }, .display_name = "second", .endpoint = .{ .host = "second.test", .user = "second" }, .auth = .keyboard_interactive, .strict_host_key_checking = false },
    } } };
}
test "socks route reads the provider engine snapshot behind an open envelope" {
    var adapter: Adapter = .{};
    var domain = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.interface()});
    defer domain.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const envelope = try @import("config/connection_envelope.zig").fromLegacy(arena.allocator(), .{ .connection_id = @fromBackingInt(3), .revision = 7, .name = "forward source", .host = "target.test", .user = "target" });
    const accepted = try domain.open(envelope, .{ .request_key = 1, .target = .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) } });
    try domain.bindEngineSpec(accepted.handle, accepted.operation, source());
    _ = try domain.ready(accepted.handle, accepted.operation, plugins.builtin_descriptors[1].services);
    var library: ssh.Library = .{ .active = false };
    var host = try socks.Host.init(std.testing.allocator, &domain, .{ .library = &library, .known_hosts_path = "/tmp/socks-envelope-no-io-known-hosts" });
    defer host.deinit() catch unreachable;
    try std.testing.expectError(error.LibraryNotInitialized, host.start(accepted.handle, .{ .exit_index = 1 }));
    try std.testing.expectEqual(@as(usize, 0), host.entries.items.len);
    try std.testing.expectEqualStrings(envelope.payload, domain.connectionEnvelope(accepted.handle).?.payload);
}

test "socks route selected exit preserves exact hop owner policy and preceding route" {
    const selected = try socks.selectExit(source(), 1);
    try std.testing.expectEqual(@as(u64, 2), @backingInt(selected.saved.connection_id));
    try std.testing.expectEqual(@as(u64, 4), selected.saved.config_revision);
    try std.testing.expectEqualStrings("second.test", selected.saved.immutable_config.endpoint.host);
    try std.testing.expectEqual(sessions.AuthOptions.keyboard_interactive, selected.saved.immutable_config.auth);
    try std.testing.expect(!selected.saved.immutable_config.strict_host_key_checking);
    try std.testing.expectEqual(@as(usize, 1), selected.saved.route_snapshot.len);
    try std.testing.expectEqual(@as(usize, 0), selected.saved.immutable_config.startup_commands.len);
    try std.testing.expectEqualStrings("first.test", selected.saved.route_snapshot[0].endpoint.host);
    try selected.validate();
    const first = try socks.selectExit(source(), 0);
    try std.testing.expectEqual(@as(usize, 0), first.saved.route_snapshot.len);
    try std.testing.expectEqual(@as(u64, 1), @backingInt(first.saved.connection_id));
    try std.testing.expectError(error.InvalidSocksExit, socks.selectExit(source(), 2));
    try std.testing.expectError(error.UnsupportedProtocol, socks.selectExit(.{ .local = .{} }, null));
}
test "socks route host rejects unavailable stale or invalid authority before native IO" {
    var adapter: Adapter = .{};
    var domain = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.interface()});
    defer domain.deinit();
    var library: ssh.Library = .{ .active = false };
    var host = try socks.Host.init(std.testing.allocator, &domain, .{ .library = &library, .known_hosts_path = "/tmp/socks-route-no-io-known-hosts" });
    defer host.deinit() catch unreachable;
    const accepted = try domain.create(source(), .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) });
    try std.testing.expectError(error.ForwardServiceUnavailable, host.start(accepted.handle, .{}));
    try std.testing.expect(try domain.ready(accepted.handle, accepted.operation, plugins.builtin_descriptors[1].services));
    try std.testing.expectError(error.InvalidSocksExit, host.start(accepted.handle, .{ .exit_index = 3 }));
    try std.testing.expectError(error.ExposureConfirmationRequired, host.start(accepted.handle, .{ .listener = .{ .bind127 = false } }));
    // A disabled library reaches the production SourceFactory, yet cannot do
    // network IO. Its failure/cleanup pair uses the domain's original owner.
    try std.testing.expectError(error.LibraryNotInitialized, host.start(accepted.handle, .{}));
    try std.testing.expectEqual(@as(usize, 0), host.entries.items.len);
    try std.testing.expectEqual(@as(usize, 1), domain.journal.records.items.len);
    try std.testing.expectEqual(sessions.CloseReceipt.released, host.requestStop(accepted.handle));
    try std.testing.expect(!(try host.safeTick()));
    var next = accepted.handle;
    next.generation += 1;
    try std.testing.expectError(error.StaleSession, host.start(next, .{}));
    while (domain.journal.take()) |received| {
        var event = received;
        defer event.deinit();
        try std.testing.expect(event.value.key.owner.session.eql(accepted.handle));
    }
}

test "shared forward rejects foreign generations and a queued stop never creates native resources" {
    const owner: sessions.SessionHandle = .{ .session_id = @fromBackingInt(51), .generation = 3 };
    const original: sessions.OperationKey = .{ .owner = .{ .session = owner }, .operation_id = 1, .attempt_id = 4 };
    var key = original;
    key.operation_id = 2;
    const binding: sessions.ServiceHandle = .{ .resource_owner = .{ .session = owner }, .origin_session = owner, .kind = .forward, .binding_id = 5, .binding_generation = 3 };
    const service = try Forward.Service.init(std.testing.allocator, original);
    defer service.deinitLocal() catch unreachable;
    var wrong = binding;
    wrong.binding_generation += 1;
    try std.testing.expectError(error.InvalidForwardAuthority, service.start(original, wrong, key, .{}));
    var stale = original;
    stale.operation_id += 10;
    try std.testing.expectError(error.StaleForwardOrigin, service.start(stale, binding, key, .{}));
    try std.testing.expectError(error.ExposureConfirmationRequired, service.start(original, binding, key, .{ .bind127 = false }));
    try std.testing.expectError(error.InvalidForwardLimit, service.start(original, binding, key, .{ .max_connections = 0 }));
    try service.start(original, binding, key, .{});
    try std.testing.expectEqual(ssh.ReleaseReceipt.released, service.requestStop(wrong));
    try std.testing.expect(!service.stop_requested.load(.acquire));
    try std.testing.expectEqual(ssh.ReleaseReceipt.released, service.requestParentClose(stale, binding));
    try std.testing.expect(!service.parentCloseRequested());
    try std.testing.expectEqual(ssh.ReleaseReceipt.awaiting, service.requestStop(binding));
    try std.testing.expect(!service.parentCloseRequested());
    try std.testing.expectEqual(ssh.ReleaseReceipt.awaiting, service.requestParentClose(original, binding));
    try std.testing.expect(service.parentCloseRequested());
    try service.stepPaused();
    try std.testing.expect(service.listener == null and service.pending == null);
    try std.testing.expectEqual(Forward.Phase.off, service.snapshot().phase);
    try std.testing.expectEqual(ssh.ReleaseReceipt.released, service.snapshot().cleanup);
}

test "shared SOCKS controller archives actual release before the original worker facade may be destroyed" {
    const Provider = struct {
        service: *Forward.Service,
        calls: usize = 0,
        fn get(raw: *anyopaque, _: sessions.ServiceHandle, _: ?usize) !*Forward.Service {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return self.service;
        }
    };
    var adapter: Adapter = .{};
    var domain = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.interface()});
    defer domain.deinit();
    const target: sessions.AttachmentTarget = .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) };
    const accepted = try domain.create(source(), target);
    try std.testing.expect(try domain.ready(accepted.handle, accepted.operation, plugins.builtin_descriptors[1].services));
    try std.testing.expect(try domain.attached(accepted.handle, .{ .target = target, .tab_id = @fromBackingInt(1) }));
    const service = try Forward.Service.init(std.testing.allocator, accepted.operation);
    var provider: Provider = .{ .service = service };
    const library: ssh.Library = .{ .active = false };
    var host = try socks.Host.init(std.testing.allocator, &domain, .{ .library = &library, .known_hosts_path = "/tmp/socks-shared-no-io-known-hosts", .shared_provider = .{ .context = &provider, .get = Provider.get } });
    defer host.deinit() catch unreachable;
    const key = try host.start(accepted.handle, .{ .exit_index = 1, .listener = .{ .requested_port = 0, .max_connections = 17 } });
    try std.testing.expectEqual(@as(usize, 1), provider.calls);
    try std.testing.expectEqual(@as(usize, 0), host.entries.items.len);
    try std.testing.expect(host.snapshot(accepted.handle).?.key.eql(key));
    try std.testing.expectEqualStrings("second", host.exitHost(accepted.handle).?.name);
    try std.testing.expectEqual(sessions.CloseReceipt.awaiting, host.requestStop(accepted.handle));
    try service.stepPaused();
    try std.testing.expectEqual(sessions.CloseReceipt.released, host.requestStop(accepted.handle));
    try std.testing.expect(host.shared_entries.items[0].service == null);
    try service.deinitLocal();
    // These read only archived values; no pointer into the destroyed original
    // Worker service remains after the released close hook returned.
    try std.testing.expectEqual(socks.Phase.closed, host.snapshot(accepted.handle).?.phase);
    try std.testing.expect(!(try host.safeTick()));
    try std.testing.expectEqual(@as(usize, 1), domain.journal.records.items.len);
    try std.testing.expect(domain.journal.records.items[0].key.eql(accepted.operation));
}
