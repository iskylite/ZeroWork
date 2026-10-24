const std = @import("std");
const files = @import("host/file_binding_host.zig");
const sessions = @import("host/session_host.zig");
const plugins = @import("host/plugin_registry.zig");
const identity = @import("host/identity.zig");
const operations = @import("host/operation.zig");
const ssh = @import("proto/ssh/session.zig");
const clock = @import("platform/realtime.zig");

// A controlled domain adapter supplies actual SessionHost-issued handles.
// This fixture is never registered by ApplicationHost or used as app readiness.
const Adapter = struct {
    file_host: ?*files.FileBindingHost = null,
    fn create(_: *anyopaque, _: sessions.CreateRequest) !void {}
    fn cancel(_: *anyopaque, _: operations.OperationKey) sessions.CloseReceipt {
        return .released;
    }
    fn close(raw: *anyopaque, owner: identity.SessionHandle, key: operations.OperationKey) !sessions.CloseReceipt {
        const self: *Adapter = @ptrCast(@alignCast(raw));
        return if (self.file_host) |host| switch (try host.requestClose(owner, key)) {
            .released => .released,
            .awaiting => .awaiting,
            .unknown => .unknown,
        } else .released;
    }
    fn stale(_: *anyopaque, _: identity.SessionHandle, _: operations.OperationKey) void {}
    fn interface(self: *Adapter) sessions.Adapter {
        return .{ .registration = .{ .plugin_id = .sftp, .workspace_kind = .file, .services = plugins.requiredServices(.sftp) }, .context = self, .vtable = &.{ .create = create, .cancel = cancel, .close = close, .release_stale = stale } };
    }
};
const Gate = struct {
    caller: std.Thread.Id,
    source: ?files.Source = null,
    connect_entered: std.atomic.Value(bool) = .init(false),
    connect_release: std.atomic.Value(bool) = .init(false),
    close_entered: std.atomic.Value(bool) = .init(false),
    close_state: std.atomic.Value(u8) = .init(@backingInt(ssh.ReleaseReceipt.awaiting)),
    destroyed: std.atomic.Value(bool) = .init(false),
    prepares: usize = 0,
    fn factory(self: *Gate) files.Factory {
        return .{ .context = self, .prepare = prepare, .discard = discard };
    }
    fn prepare(raw: *anyopaque, source: files.Source) !files.readonly.Connector {
        const self: *Gate = @ptrCast(@alignCast(raw));
        self.source = source;
        self.prepares += 1;
        return .{ .key = source.open_key, .ctx = self, .connect_fn = connect, .close_fn = close, .deinit_fn = destroy };
    }
    fn discard(_: *anyopaque, _: files.readonly.Connector) void {}
    fn connect(raw: *anyopaque, _: *const std.atomic.Value(bool)) !ssh.Session {
        const self: *Gate = @ptrCast(@alignCast(raw));
        if (self.caller == std.Thread.getCurrentId()) return error.WrongThread;
        self.connect_entered.store(true, .release);
        try wait(&self.connect_release);
        return error.ControlledConnectionFailure;
    }
    fn close(raw: *anyopaque, session: ?*ssh.Session) ssh.ReleaseReceipt {
        const self: *Gate = @ptrCast(@alignCast(raw));
        std.debug.assert(session == null and self.caller != std.Thread.getCurrentId());
        self.close_entered.store(true, .release);
        return @fromBackingInt(@intCast(self.close_state.load(.acquire)));
    }
    fn destroy(raw: *anyopaque) void {
        const self: *Gate = @ptrCast(@alignCast(raw));
        self.destroyed.store(true, .release);
    }
};
fn pause() void {
    var unused: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&unused, 0, 2);
}
fn wait(flag: *const std.atomic.Value(bool)) !void {
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (!flag.load(.acquire)) {
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
}
fn closeAll(host: *files.FileBindingHost, gate: *Gate) void {
    gate.connect_release.store(true, .release);
    gate.close_state.store(@backingInt(ssh.ReleaseReceipt.released), .release);
    host.requestCloseAll();
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (host.safeTick() catch unreachable) {
        if (clock.monotonicNs() >= deadline) unreachable;
        pause();
    }
    host.deinit() catch unreachable;
}
fn createDomain(host: *sessions.SessionHost, input: sessions.SessionCreateSpec) !sessions.Accepted {
    const accepted = try host.create(input, .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) });
    try std.testing.expect(try host.ready(accepted.handle, accepted.operation, plugins.requiredServices(.sftp)));
    try std.testing.expect(try host.attached(accepted.handle, .{ .target = .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) }, .tab_id = @fromBackingInt(1) }));
    return accepted;
}
fn handles(host: *sessions.SessionHost, owner: identity.SessionHandle) files.Bindings {
    return .{ .directory = host.queryService(owner, .directory).available, .file_read = host.queryService(owner, .file_read).available };
}
fn spec(address: []const u8) sessions.SessionCreateSpec {
    return .{ .saved = .{ .connection_id = @fromBackingInt(81), .config_revision = 7, .protocol = .sftp, .immutable_config = .{ .endpoint = .{ .host = address, .user = "root" }, .auth = .{ .password = "fixture" } } } };
}
test "file binding resolves a public envelope to its provider frozen engine spec" {
    var adapter: Adapter = .{};
    var domain = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.interface()});
    defer domain.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const envelope = try @import("config/connection_envelope.zig").fromLegacy(arena.allocator(), .{ .connection_id = @fromBackingInt(81), .revision = 7, .protocol = .sftp, .name = "file envelope", .host = "original.test", .user = "root" });
    const target: sessions.AttachmentTarget = .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) };
    const accepted = try domain.open(envelope, .{ .request_key = 1, .target = target });
    try domain.bindEngineSpec(accepted.handle, accepted.operation, spec("original.test"));
    _ = try domain.ready(accepted.handle, accepted.operation, plugins.requiredServices(.sftp));
    _ = try domain.attached(accepted.handle, .{ .target = target, .tab_id = @fromBackingInt(1) });
    var gate: Gate = .{ .caller = std.Thread.getCurrentId() };
    var host = try files.FileBindingHost.init(std.testing.allocator, &domain, gate.factory());
    defer closeAll(&host, &gate);
    adapter.file_host = &host;
    _ = try host.attach(accepted.handle, handles(&domain, accepted.handle));
    try wait(&gate.connect_entered);
    try std.testing.expect(gate.source.?.spec == .saved);
    try std.testing.expectEqualStrings("original.test", gate.source.?.spec.saved.immutable_config.endpoint.host);
    try std.testing.expectEqualStrings("fixture", gate.source.?.spec.saved.immutable_config.auth.password);
    try std.testing.expectEqualStrings(envelope.payload, domain.connectionEnvelope(accepted.handle).?.payload);
}
test "file binding host uses saved domain spec journal keys and per-kind physical mapping" {
    var adapter: Adapter = .{};
    var domain = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.interface()});
    defer domain.deinit();
    var address = "original.test".*;
    const accepted = try createDomain(&domain, spec(&address));
    address[0] = 'x';
    const logical = handles(&domain, accepted.handle);
    var gate: Gate = .{ .caller = std.Thread.getCurrentId() };
    var host = try files.FileBindingHost.init(std.testing.allocator, &domain, gate.factory());
    defer closeAll(&host, &gate);
    adapter.file_host = &host;
    const endpoint = try host.attach(accepted.handle, logical);
    try wait(&gate.connect_entered);
    try std.testing.expectEqual(logical.directory.binding_id, endpoint.binding_id);
    try std.testing.expect(logical.file_read.binding_id != endpoint.binding_id);
    try std.testing.expect(gate.source.?.create_key.eql(accepted.operation));
    try std.testing.expect(gate.source.?.open_key.owner.session.eql(accepted.handle));
    try std.testing.expectEqualStrings("original.test", gate.source.?.spec.saved.immutable_config.endpoint.host);
    try std.testing.expect((try host.attach(accepted.handle, logical)).eql(endpoint));
    try std.testing.expectEqual(@as(usize, 1), gate.prepares);
    const original_path = try std.testing.allocator.dupe(u8, "/original a,b");
    const read_key = host.begin(logical.file_read, .{ .path = original_path, .action = .{ .read_text = .{} } });
    std.testing.allocator.free(original_path);
    const key = try read_key;
    try std.testing.expect(key.operation_id > gate.source.?.open_key.operation_id);
    try std.testing.expect(key.owner.session.eql(accepted.handle));
    try std.testing.expect(domain.journal.isTerminal(accepted.operation));
    try std.testing.expect(!domain.journal.isTerminal(key));
    try std.testing.expectError(error.ServiceKindMismatch, host.begin(logical.directory, .{ .path = "/a", .action = .{ .read_text = .{} } }));
    try std.testing.expectError(error.UnknownOperation, host.submit(logical.file_read, .{ .owner = .{ .session = accepted.handle }, .operation_id = 999 }, .{ .path = "/a", .action = .{ .read_text = .{} } }));
    var stale = logical.file_read;
    stale.binding_generation += 1;
    try std.testing.expectError(error.StaleBinding, host.begin(stale, .{ .path = "/a", .action = .{ .read_text = .{} } }));
    var other_key = key;
    other_key.owner.session.generation += 1;
    try std.testing.expect(!host.cancel(other_key));
    try std.testing.expect(host.cancel(key));
    gate.connect_release.store(true, .release);
    try wait(&gate.close_entered);
    _ = try host.safeTick();
    var response = host.take(key).?;
    defer response.deinit();
    try std.testing.expect(response.binding.eql(logical.file_read));
    try std.testing.expectEqualStrings("/original a,b", response.result.value.requested_path);
    try std.testing.expect(response.result.value.body == .cancelled);
    try std.testing.expectEqual(ssh.ReleaseReceipt.released, host.cleanupReceipt(key));
    try host.retire(key);
    try std.testing.expectError(error.Busy, host.deinit());
    try std.testing.expect(!gate.destroyed.load(.acquire));
    gate.close_state.store(@backingInt(ssh.ReleaseReceipt.unknown), .release);
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (host.state(logical.directory).?.phase != .cleanup_unknown) {
        _ = try host.safeTick();
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
    try std.testing.expect(!gate.destroyed.load(.acquire));
    try std.testing.expectError(error.Busy, host.deinit());
}
test "file binding host stale owner cancels original result and close waits for real release" {
    var adapter: Adapter = .{};
    var domain = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.interface()});
    defer domain.deinit();
    const accepted = try createDomain(&domain, spec("original.test"));
    const logical = handles(&domain, accepted.handle);
    var gate: Gate = .{ .caller = std.Thread.getCurrentId() };
    var host = try files.FileBindingHost.init(std.testing.allocator, &domain, gate.factory());
    defer closeAll(&host, &gate);
    adapter.file_host = &host;
    _ = try host.attach(accepted.handle, logical);
    try wait(&gate.connect_entered);
    const key = try host.begin(logical.directory, .{ .path = "/", .action = .{ .list = .{} }, .directory_revision = 9 });
    const close_key = try domain.requestClose(accepted.handle, .{});
    try std.testing.expectEqual(sessions.Lifecycle.closing, domain.queryState(accepted.handle).?.lifecycle);
    try std.testing.expectEqual(ssh.ReleaseReceipt.awaiting, try host.requestClose(accepted.handle, close_key));
    try std.testing.expectError(error.StaleCloseOperation, host.requestClose(accepted.handle, key));
    try std.testing.expectError(error.StaleBinding, host.begin(logical.directory, .{ .path = "/new", .action = .stat }));
    gate.connect_release.store(true, .release);
    try wait(&gate.close_entered);
    _ = try host.safeTick();
    var response = host.take(key).?;
    defer response.deinit();
    try std.testing.expect(response.stale);
    try std.testing.expect(response.result.value.body == .cancelled);
    try std.testing.expect(response.result.value.key.eql(key));
    try std.testing.expectEqual(@as(u64, 9), response.result.value.directory_revision);
    gate.close_state.store(@backingInt(ssh.ReleaseReceipt.released), .release);
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (try host.safeTick()) {
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
    try std.testing.expect(gate.destroyed.load(.acquire));
    try std.testing.expect(try domain.closeReceipt(accepted.handle, close_key, .close_protocol, .released));
    try std.testing.expectEqual(sessions.Lifecycle.closed, domain.queryState(accepted.handle).?.lifecycle);
    try host.retire(key);
}
test "file binding direct factory rejects route before native IO and owns explicit policy" {
    var library = try ssh.Library.init();
    defer library.deinit();
    var native: files.DirectFactory = .{ .library = &library, .known_hosts_path = "/tmp/zerowork-file-host-test-known-hosts" };
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(51), .generation = 3 };
    const source: files.Source = .{ .owner = owner, .create_key = .{ .owner = .{ .session = owner }, .operation_id = 2 }, .open_key = .{ .owner = .{ .session = owner }, .operation_id = 3 }, .spec = .{ .saved = .{
        .connection_id = @fromBackingInt(91),
        .config_revision = 8,
        .protocol = .ssh,
        .immutable_config = .{ .endpoint = .{ .host = "target.invalid", .user = "root" } },
        .route_snapshot = &.{.{ .endpoint = .{ .host = "jump.invalid", .user = "jump" } }},
    } } };
    const factory = native.interface();
    try std.testing.expectError(error.ProxyJumpTransportUnavailable, factory.prepare(factory.context, source));
}

test "file binding host revalidates buffered file content at delivery after domain close" {
    var adapter: Adapter = .{};
    var domain = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.interface()});
    defer domain.deinit();
    const accepted = try createDomain(&domain, spec("original.test"));
    const logical = handles(&domain, accepted.handle);
    var gate: Gate = .{ .caller = std.Thread.getCurrentId() };
    var host = try files.FileBindingHost.init(std.testing.allocator, &domain, gate.factory());
    defer host.deinit() catch unreachable;
    const endpoint: files.readonly.EndpointRef = .{ .binding_id = logical.directory.binding_id, .binding_generation = logical.directory.binding_generation, .resource_owner = .{ .session = accepted.handle } };
    const key = try domain.journal.begin(.{ .session = accepted.handle }, 1);
    _ = try domain.journal.completeReleased(key, "worker result already buffered");
    host.pending.appendAssumeCapacity(.{ .key = key, .endpoint = endpoint, .binding = logical.file_read, .terminal = true, .cleanup = .released });
    // This is the owned result queue boundary; the worker has already closed
    // its file. Closing the domain before take must still suppress the bytes.
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    const text = try arena.allocator().dupe(u8, "old private file content");
    host.responses.appendAssumeCapacity(.{ .binding = logical.file_read, .stale = false, .result = .{ .arena = arena, .value = .{
        .key = key,
        .endpoint = endpoint,
        .request_id = key.operation_id,
        .directory_revision = 0,
        .requested_path = "/old",
        .body = .{ .text = .{ .text = text, .original_size = text.len, .read_bytes = text.len, .captured_at_ms = 0, .truncated = false } },
    } } });
    _ = try domain.requestClose(accepted.handle, .{});
    var response = host.take(key).?;
    defer response.deinit();
    try std.testing.expect(response.stale);
    try std.testing.expect(response.result.value.body == .cancelled);
    try host.retire(key);
}
