//! Background SOCKS domain contracts. No native transport or UI is started.
const std = @import("std");
const domain = @import("host/session_host.zig");
const plugins = @import("host/plugin_registry.zig");
const operations = @import("host/operation.zig");
const a = std.testing.allocator;
const target: domain.AttachmentTarget = .{ .window_id = @fromBackingInt(7), .workspace_id = @fromBackingInt(8) };

const Adapter = struct {
    creates: usize = 0,
    cancels: usize = 0,
    closes: usize = 0,
    stale: usize = 0,
    cancel_result: domain.CloseReceipt = .released,
    close_result: domain.CloseReceipt = .released,
    last: ?domain.CreateRequest = null,
    close_key: ?domain.OperationKey = null,
    fn interface(self: *Adapter, forward: bool) domain.Adapter {
        var services = plugins.requiredServices(.ssh);
        if (forward) services.bits |= domain.backgroundServices().bits;
        return .{ .registration = .{ .plugin_id = .ssh, .workspace_kind = .terminal, .services = services }, .context = self, .vtable = &.{ .create = create, .cancel = cancel, .close = close, .release_stale = staleRelease } };
    }
    fn create(raw: *anyopaque, request: domain.CreateRequest) !void {
        const self: *Adapter = @ptrCast(@alignCast(raw));
        self.creates += 1;
        self.last = request;
    }
    fn cancel(raw: *anyopaque, _: domain.OperationKey) domain.CloseReceipt {
        const self: *Adapter = @ptrCast(@alignCast(raw));
        self.cancels += 1;
        return self.cancel_result;
    }
    fn close(raw: *anyopaque, _: domain.SessionHandle, key: domain.OperationKey) !domain.CloseReceipt {
        const self: *Adapter = @ptrCast(@alignCast(raw));
        self.closes += 1;
        self.close_key = key;
        return self.close_result;
    }
    fn staleRelease(raw: *anyopaque, _: domain.SessionHandle, _: domain.OperationKey) void {
        const self: *Adapter = @ptrCast(@alignCast(raw));
        self.stale += 1;
    }
};

fn source() domain.SessionCreateSpec {
    return .{ .saved = .{ .connection_id = @fromBackingInt(71), .config_revision = 9, .protocol = .ssh, .immutable_config = .{ .endpoint = .{ .host = "target.example", .user = "operator" }, .auth = .{ .password = "target-secret" }, .strict_host_key_checking = true, .startup_commands = &.{"original interactive command"} }, .route_snapshot = &.{.{ .owner = .{ .id = @fromBackingInt(61), .revision = 4 }, .display_name = "Original bastion", .endpoint = .{ .host = "bridge.example", .user = "jump" }, .auth = .{ .private_key = .{ .path = "/fixture/key", .passphrase = "key-secret" } }, .strict_host_key_checking = false }}, .private_options = "127.0.0.1:1080" } };
}

test "background SOCKS creates a real original owner and only forward services without a Tab" {
    var adapter: Adapter = .{};
    var host = try domain.SessionHost.init(a, &.{adapter.interface(true)});
    defer host.deinit();
    const original_source = source();
    const accepted = try host.createBackground(original_source, target);
    try std.testing.expectEqual(domain.SessionPurpose.interactive, original_source.purpose());
    try std.testing.expectEqual(domain.SessionPurpose.socks_background, adapter.last.?.spec.purpose());
    try std.testing.expect(adapter.last.?.key.eql(accepted.operation));
    try std.testing.expect(accepted.operation.owner == .session and accepted.operation.owner.session.eql(accepted.handle));
    try std.testing.expect(!host.journal.isTerminal(accepted.operation));
    try std.testing.expect(host.queryState(accepted.handle).?.attachment == null);
    const binding = try host.reserveService(accepted.handle, accepted.operation, .forward);
    try std.testing.expect(host.bindingIsPreparing(binding, accepted.operation));
    try std.testing.expect(!host.bindingIsLive(binding));
    for ([_]domain.ServiceKind{ .terminal, .process, .cwd, .exec, .transfer, .directory, .file_read }) |kind| {
        try std.testing.expectError(error.UnsupportedSessionService, host.reserveService(accepted.handle, accepted.operation, kind));
        try std.testing.expect(host.queryService(accepted.handle, kind) == .unsupported);
    }
    try std.testing.expectError(error.InvalidSessionPurpose, host.ready(accepted.handle, accepted.operation, domain.backgroundServices()));
    try std.testing.expectEqual(domain.Lifecycle.creating, host.queryState(accepted.handle).?.lifecycle);
    try std.testing.expect(!host.journal.isTerminal(accepted.operation));
    try std.testing.expect(try host.readyBackground(accepted.handle, accepted.operation, domain.backgroundServices()));
    const ready = host.queryState(accepted.handle).?;
    try std.testing.expectEqual(domain.SessionPurpose.socks_background, ready.purpose);
    try std.testing.expectEqual(domain.Lifecycle.ready, ready.lifecycle);
    try std.testing.expect(ready.attachment == null);
    try std.testing.expect(host.journal.isTerminal(accepted.operation));
    try std.testing.expect(host.bindingIsLive(binding));
    try std.testing.expectEqualDeep(binding, host.queryService(accepted.handle, .forward).available);
    try std.testing.expectError(error.UnsupportedSessionService, host.retainTransferSource(accepted.handle));
    try std.testing.expect(!host.bindingIsPreparing(binding, accepted.operation));
    try std.testing.expect(!try host.attached(accepted.handle, .{ .target = target, .tab_id = @fromBackingInt(99) }));
    try std.testing.expect(host.queryState(accepted.handle).?.attachment == null);
    try std.testing.expect(!try host.cancel(accepted.operation));
    try std.testing.expectEqual(@as(usize, 0), adapter.cancels);
    try std.testing.expect(!try host.readyBackground(accepted.handle, accepted.operation, domain.backgroundServices()));
    try std.testing.expectEqual(@as(usize, 0), adapter.stale);
    try std.testing.expect(host.bindingIsLive(binding));
    var completed: usize = 0;
    while (host.journal.take()) |received| {
        var event = received;
        defer event.deinit();
        try std.testing.expect(event.value.kind != .cleanup_released);
        if (event.value.kind == .completed) completed += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), completed);
}

test "background SOCKS freezes original route and each authentication value for generation retry" {
    var adapter: Adapter = .{};
    var host = try domain.SessionHost.init(a, &.{adapter.interface(true)});
    defer host.deinit();
    var endpoint = "target.example".*;
    var password = "target-secret".*;
    var hop_host = "bridge.example".*;
    var key_path = "/fixture/key".*;
    var passphrase = "key-secret".*;
    var seed = "JBSWY3DPEHPK3PXP".*;
    var options = "127.0.0.1:1080".*;
    var hops = [_]domain.RouteHop{.{ .owner = .{ .id = @fromBackingInt(61), .revision = 4 }, .endpoint = .{ .host = &hop_host, .user = "jump" }, .auth = .{ .private_key = .{ .path = &key_path, .passphrase = &passphrase } }, .totp_secret = &seed, .strict_host_key_checking = false }};
    var spec = source();
    spec.saved.immutable_config.endpoint.host = &endpoint;
    spec.saved.immutable_config.auth = .{ .password = &password };
    spec.saved.immutable_config.totp_secret = &seed;
    spec.saved.route_snapshot = &hops;
    spec.saved.private_options = &options;
    const first = try host.createBackground(spec, target);
    @memset(&endpoint, 'x');
    @memset(&password, 'x');
    @memset(&hop_host, 'x');
    @memset(&key_path, 'x');
    @memset(&passphrase, 'x');
    @memset(&seed, 'x');
    @memset(&options, 'x');
    hops[0].owner.?.revision = 999;
    try std.testing.expect(try host.readyBackground(first.handle, first.operation, domain.backgroundServices()));
    const old = host.queryService(first.handle, .forward).available;
    try std.testing.expect(try host.transportLost(first.handle, first.operation, .{ .domain = .transport, .code = "fixture FIN", .cleanup = .unknown, .safe_message = "closed" }));
    try std.testing.expect(!host.bindingIsLive(old));
    try std.testing.expectError(error.CleanupNotReleased, host.retry(first.handle));
    var stale = first.operation;
    stale.attempt_id = (stale.attempt_id orelse 0) + 1;
    try std.testing.expect(!try host.createCleanupReceipt(first.handle, stale, .released));
    _ = try host.createCleanupReceipt(first.handle, first.operation, .awaiting);
    try std.testing.expectEqual(operations.Cleanup.releasing, host.queryState(first.handle).?.create_cleanup);
    try std.testing.expectError(error.CleanupNotReleased, host.retry(first.handle));
    _ = try host.createCleanupReceipt(first.handle, first.operation, .released);
    const next = try host.retry(first.handle);
    try std.testing.expectEqual(first.handle.generation + 1, next.handle.generation);
    try std.testing.expectEqual((first.operation.attempt_id orelse 0) + 1, next.operation.attempt_id.?);
    try std.testing.expect(!next.operation.eql(first.operation));
    const frozen = adapter.last.?.spec.saved;
    try std.testing.expectEqual(domain.SessionPurpose.socks_background, frozen.purpose);
    try std.testing.expectEqual(@as(u64, 9), frozen.config_revision);
    try std.testing.expectEqualStrings("target.example", frozen.immutable_config.endpoint.host);
    try std.testing.expectEqualStrings("target-secret", frozen.immutable_config.auth.password);
    try std.testing.expectEqualStrings("JBSWY3DPEHPK3PXP", frozen.immutable_config.totp_secret.?);
    try std.testing.expectEqualStrings("bridge.example", frozen.route_snapshot[0].endpoint.host);
    try std.testing.expectEqualStrings("/fixture/key", frozen.route_snapshot[0].auth.private_key.path);
    try std.testing.expectEqualStrings("key-secret", frozen.route_snapshot[0].auth.private_key.passphrase.?);
    try std.testing.expectEqualStrings("JBSWY3DPEHPK3PXP", frozen.route_snapshot[0].totp_secret.?);
    try std.testing.expectEqual(@as(u64, 4), frozen.route_snapshot[0].owner.?.revision);
    try std.testing.expect(!frozen.route_snapshot[0].strict_host_key_checking);
    try std.testing.expectEqualStrings("127.0.0.1:1080", frozen.private_options);
    try std.testing.expect(!try host.readyBackground(first.handle, first.operation, domain.backgroundServices()));
    try std.testing.expect(try host.readyBackground(next.handle, next.operation, domain.backgroundServices()));
    try std.testing.expect(host.queryState(next.handle).?.attachment == null);
    const current = host.queryService(next.handle, .forward).available;
    try std.testing.expect(!old.eql(current));
    try std.testing.expect(host.bindingIsLive(current));
    try std.testing.expectEqual(@as(usize, 2), adapter.creates);
}

test "background SOCKS close waits exact forward and protocol receipts without cancelling active ready resources" {
    const Gate = struct {
        calls: usize = 0,
        owner: ?domain.SessionHandle = null,
        key: ?domain.OperationKey = null,
        fn close(raw: *anyopaque, owner: domain.SessionHandle, key: domain.OperationKey) !domain.CloseReceipt {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            self.owner = owner;
            self.key = key;
            return .awaiting;
        }
    };
    var gate: Gate = .{};
    var adapter: Adapter = .{ .close_result = .awaiting };
    var host = try domain.SessionHost.init(a, &.{adapter.interface(true)});
    defer host.deinit();
    const original = try host.createBackground(source(), target);
    _ = try host.readyBackground(original.handle, original.operation, domain.backgroundServices());
    const binding = host.queryService(original.handle, .forward).available;
    const key = try host.requestClose(original.handle, .{ .release_forwards = .{ .context = &gate, .run = Gate.close } });
    try std.testing.expect(key.owner == .session and key.owner.session.eql(original.handle));
    try std.testing.expect(!key.eql(original.operation));
    try std.testing.expect(gate.owner.?.eql(original.handle) and gate.key.?.eql(key));
    try std.testing.expect(!host.bindingIsLive(binding));
    try std.testing.expectEqual(@as(usize, 0), adapter.cancels);
    try std.testing.expectEqual(@as(usize, 0), adapter.closes);
    try std.testing.expect(key.eql(try host.requestClose(original.handle, .{})));
    try std.testing.expectEqual(@as(usize, 1), gate.calls);
    try std.testing.expect(!try host.closeReceipt(original.handle, original.operation, .release_forwards, .released));
    try std.testing.expect(!try host.closeReceipt(original.handle, key, .close_protocol, .released));
    try std.testing.expect(try host.closeReceipt(original.handle, key, .release_forwards, .released));
    try std.testing.expectEqual(@as(usize, 1), adapter.closes);
    try std.testing.expect(adapter.close_key.?.eql(key));
    try std.testing.expect(!try host.createCleanupReceipt(original.handle, original.operation, .released));
    try std.testing.expect(try host.closeReceipt(original.handle, key, .close_protocol, .unknown));
    try std.testing.expectEqual(domain.Lifecycle.cleanup_unknown, host.queryState(original.handle).?.lifecycle);
    try std.testing.expect(key.eql(try host.requestClose(original.handle, .{})));
    try std.testing.expectEqual(@as(usize, 1), adapter.closes);
    try std.testing.expect(!try host.readyBackground(original.handle, original.operation, domain.backgroundServices()));
    try std.testing.expect(try host.closeReceipt(original.handle, key, .close_protocol, .released));
    try std.testing.expectEqual(domain.Lifecycle.closed, host.queryState(original.handle).?.lifecycle);
    try std.testing.expect(host.queryState(original.handle).?.attachment == null);
    try std.testing.expect(!host.bindingIsLive(binding));
}

test "background SOCKS rejects missing or terminal capabilities through original cleanup gate" {
    for ([_]bool{ false, true }) |add_terminal| {
        var adapter: Adapter = .{ .cancel_result = .unknown };
        var host = try domain.SessionHost.init(a, &.{adapter.interface(true)});
        defer host.deinit();
        const original = try host.createBackground(source(), target);
        var wrong = if (add_terminal) domain.backgroundServices() else plugins.requiredServices(.ssh);
        if (add_terminal) wrong.bits |= plugins.Services.of(&.{.terminal}).bits;
        try std.testing.expectError(error.InvalidReadyServices, host.readyBackground(original.handle, original.operation, wrong));
        try std.testing.expectEqual(domain.Lifecycle.failed, host.queryState(original.handle).?.lifecycle);
        try std.testing.expect(host.queryState(original.handle).?.attachment == null);
        try std.testing.expectEqual(@as(usize, 1), adapter.cancels);
        try std.testing.expect(host.queryService(original.handle, .forward) == .temporarily_unavailable);
        try std.testing.expect(host.queryService(original.handle, .terminal) == .unsupported);
        try std.testing.expectError(error.CleanupNotReleased, host.retry(original.handle));
        _ = try host.createCleanupReceipt(original.handle, original.operation, .released);
        const next = try host.retry(original.handle);
        try std.testing.expect(try host.readyBackground(next.handle, next.operation, domain.backgroundServices()));
    }
}

test "background SOCKS rejects unsupported sources and an adapter without real forward capability before owner allocation" {
    var adapter: Adapter = .{};
    var host = try domain.SessionHost.init(a, &.{adapter.interface(false)});
    defer host.deinit();
    try std.testing.expectError(error.MissingRequiredService, host.createBackground(source(), target));
    try std.testing.expectError(error.InvalidSessionPurpose, host.createBackground(.{ .local = .{} }, target));
    try std.testing.expectError(error.InvalidSessionPurpose, host.createBackground(.{ .temporary_ssh = .{ .structured_endpoint = .{ .host = "target.example", .user = "test" } } }, target));
    var sftp = source();
    sftp.saved.protocol = .sftp;
    try std.testing.expectError(error.InvalidSessionPurpose, host.createBackground(sftp, target));
    sftp.saved.purpose = .socks_background;
    try std.testing.expectError(error.InvalidSessionPurpose, host.create(sftp, target));
    try std.testing.expectEqual(@as(usize, 0), host.sessions.items.len);
    try std.testing.expectEqual(@as(usize, 0), host.journal.records.items.len);
    try std.testing.expectEqual(@as(usize, 0), adapter.creates);
}

test "background SOCKS ready publication OOM keeps original operation unready and safely retryable" {
    var adapter: Adapter = .{};
    var host = try domain.SessionHost.init(a, &.{adapter.interface(true)});
    defer host.deinit();
    const original = try host.createBackground(source(), target);
    const forward = try host.reserveService(original.handle, original.operation, .forward);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    host.journal.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, host.readyBackground(original.handle, original.operation, domain.backgroundServices()));
    host.journal.allocator = a;
    try std.testing.expect(!host.journal.isTerminal(original.operation));
    try std.testing.expectEqual(domain.Lifecycle.creating, host.queryState(original.handle).?.lifecycle);
    try std.testing.expect(host.queryState(original.handle).?.attachment == null);
    try std.testing.expect(host.bindingIsPreparing(forward, original.operation));
    try std.testing.expect(!host.bindingIsLive(forward));
    try std.testing.expect(try host.readyBackground(original.handle, original.operation, domain.backgroundServices()));
    try std.testing.expectEqualDeep(forward, host.queryService(original.handle, .forward).available);
    try std.testing.expectEqual(@as(usize, 1), adapter.creates);
    try std.testing.expectEqual(@as(usize, 0), adapter.cancels);
}

test "background SOCKS purpose does not alter ordinary SSH readiness and Tab attachment" {
    var adapter: Adapter = .{};
    var host = try domain.SessionHost.init(a, &.{adapter.interface(true)});
    defer host.deinit();
    const original = try host.create(source(), target);
    try std.testing.expectEqual(domain.SessionPurpose.interactive, adapter.last.?.spec.purpose());
    try std.testing.expectError(error.InvalidSessionPurpose, host.readyBackground(original.handle, original.operation, domain.backgroundServices()));
    try std.testing.expect(try host.ready(original.handle, original.operation, plugins.requiredServices(.ssh)));
    try std.testing.expect(!host.journal.isTerminal(original.operation));
    try std.testing.expect(try host.attached(original.handle, .{ .target = target, .tab_id = @fromBackingInt(42) }));
    try std.testing.expectEqual(domain.Lifecycle.attached, host.queryState(original.handle).?.lifecycle);
    try std.testing.expect(host.queryState(original.handle).?.attachment.?.tab_id == @as(@import("host/identity.zig").TabId, @fromBackingInt(42)));
    try std.testing.expect(host.queryService(original.handle, .terminal) == .available);
}
