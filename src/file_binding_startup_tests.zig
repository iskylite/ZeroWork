const std = @import("std");
const files = @import("host/file_binding_host.zig");
const sessions = @import("host/session_host.zig");
const identity = @import("host/identity.zig");
const plugins = @import("host/plugin_registry.zig");
const clock = @import("platform/realtime.zig");

comptime {
    _ = @import("file_binding_host_tests.zig");
}

// Controlled startup identity/cleanup fixture, never an ApplicationHost adapter
// registration or a claim that transfer/SFTP services are production ready.
const Adapter = struct {
    host: ?*files.FileBindingHost = null,
    cancel_receipt: sessions.CloseReceipt = .released,
    stale_releases: usize = 0,
    fn interface(self: *Adapter) sessions.Adapter {
        return .{ .registration = .{ .plugin_id = .sftp, .workspace_kind = .file, .services = plugins.requiredServices(.sftp) }, .context = self, .vtable = &.{ .create = create, .cancel = cancel, .close = close, .release_stale = stale } };
    }
    fn create(_: *anyopaque, _: sessions.CreateRequest) !void {}
    fn cancel(raw: *anyopaque, key: sessions.OperationKey) sessions.CloseReceipt {
        const self: *Adapter = @ptrCast(@alignCast(raw));
        if (self.host) |host| return convert(host.cancelPreparing(key.owner.session, key) catch return .unknown);
        return self.cancel_receipt;
    }
    fn close(_: *anyopaque, _: identity.SessionHandle, _: sessions.OperationKey) !sessions.CloseReceipt {
        return .released;
    }
    fn stale(raw: *anyopaque, _: identity.SessionHandle, _: sessions.OperationKey) void {
        const self: *Adapter = @ptrCast(@alignCast(raw));
        self.stale_releases += 1;
    }
};
const Gate = struct {
    caller: std.Thread.Id,
    entered: std.atomic.Value(bool) = .init(false),
    release_connect: std.atomic.Value(bool) = .init(false),
    close_entered: std.atomic.Value(bool) = .init(false),
    close_state: std.atomic.Value(u8) = .init(@backingInt(files.readonly.ReleaseReceipt.awaiting)),
    destroyed: std.atomic.Value(bool) = .init(false),
    token: ?*const std.atomic.Value(bool) = null,
    source: ?files.Source = null,
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
    fn connect(raw: *anyopaque, token: *const std.atomic.Value(bool)) !@import("proto/ssh/session.zig").Session {
        const self: *Gate = @ptrCast(@alignCast(raw));
        std.debug.assert(self.caller != std.Thread.getCurrentId());
        self.token = token;
        self.entered.store(true, .release);
        try wait(&self.release_connect);
        return if (token.load(.acquire)) error.Cancelled else error.ControlledConnectFailure;
    }
    fn close(raw: *anyopaque, _: ?*@import("proto/ssh/session.zig").Session) files.readonly.ReleaseReceipt {
        const self: *Gate = @ptrCast(@alignCast(raw));
        std.debug.assert(self.caller != std.Thread.getCurrentId());
        self.close_entered.store(true, .release);
        return @fromBackingInt(@intCast(self.close_state.load(.acquire)));
    }
    fn destroy(raw: *anyopaque) void {
        const self: *Gate = @ptrCast(@alignCast(raw));
        std.debug.assert(self.close_state.load(.acquire) == @backingInt(files.readonly.ReleaseReceipt.released));
        self.destroyed.store(true, .release);
    }
};
const target: sessions.AttachmentTarget = .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) };
fn spec() sessions.SessionCreateSpec {
    return .{ .saved = .{ .connection_id = @fromBackingInt(17), .config_revision = 8, .protocol = .sftp, .immutable_config = .{ .endpoint = .{ .host = "original.invalid", .user = "root" } } } };
}
fn reserve(host: *sessions.SessionHost, accepted: sessions.Accepted) !files.Bindings {
    return .{ .directory = try host.reserveService(accepted.handle, accepted.operation, .directory), .file_read = try host.reserveService(accepted.handle, accepted.operation, .file_read) };
}
fn convert(receipt: files.readonly.ReleaseReceipt) sessions.CloseReceipt {
    return switch (receipt) {
        .released => .released,
        .awaiting => .awaiting,
        .unknown => .unknown,
    };
}
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
fn stop(host: *files.FileBindingHost, gate: *Gate) void {
    gate.release_connect.store(true, .release);
    gate.close_state.store(@backingInt(files.readonly.ReleaseReceipt.released), .release);
    host.requestCloseAll();
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (host.safeTick() catch unreachable) {
        if (clock.monotonicNs() >= deadline) unreachable;
        pause();
    }
    host.deinit() catch unreachable;
}

test "startup reservation uses one domain counter and ready publishes the identical handles once" {
    var adapter: Adapter = .{};
    var domain = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.interface()});
    defer domain.deinit();
    const accepted = try domain.create(spec(), target);
    const before = domain.next_binding;
    const logical = try reserve(&domain, accepted);
    try std.testing.expectEqual(before, logical.directory.binding_id);
    try std.testing.expectEqual(before + 1, logical.file_read.binding_id);
    try std.testing.expect(logical.directory.resource_owner.session.eql(accepted.handle));
    try std.testing.expect(logical.directory.origin_session.?.eql(accepted.handle));
    try std.testing.expect(logical.directory.eql(try domain.reserveService(accepted.handle, accepted.operation, .directory)));
    try std.testing.expectEqual(before + 2, domain.next_binding);
    try std.testing.expect(domain.bindingIsPreparing(logical.directory, accepted.operation));
    try std.testing.expect(!domain.bindingIsLive(logical.directory));
    try std.testing.expect(domain.queryService(accepted.handle, .directory) == .temporarily_unavailable);
    try std.testing.expect(domain.queryService(accepted.handle, .file_read) == .temporarily_unavailable);
    const wrong_key = try domain.journal.begin(.{ .session = accepted.handle }, 1);
    try std.testing.expectError(error.StaleCreateOperation, domain.reserveService(accepted.handle, wrong_key, .directory));
    try std.testing.expect(!domain.bindingIsPreparing(logical.directory, wrong_key));
    try std.testing.expectError(error.ServiceNotRegistered, domain.reserveService(accepted.handle, accepted.operation, .terminal));
    var forged = logical.directory;
    forged.binding_id += 100;
    try std.testing.expect(!domain.bindingIsPreparing(forged, accepted.operation));
    try std.testing.expect(try domain.ready(accepted.handle, accepted.operation, plugins.requiredServices(.sftp)));
    try std.testing.expect(domain.queryService(accepted.handle, .directory).available.eql(logical.directory));
    try std.testing.expect(domain.queryService(accepted.handle, .file_read).available.eql(logical.file_read));
    try std.testing.expectEqual(before + @as(u64, @popCount(plugins.requiredServices(.sftp).bits)), domain.next_binding);
    try std.testing.expect(!domain.bindingIsPreparing(logical.directory, accepted.operation));
    try std.testing.expect(domain.bindingIsLive(logical.directory));
    const after = domain.next_binding;
    try std.testing.expect(!try domain.ready(accepted.handle, accepted.operation, plugins.requiredServices(.sftp)));
    try std.testing.expectEqual(after, domain.next_binding);
    try std.testing.expectError(error.SessionNotCreating, domain.reserveService(accepted.handle, accepted.operation, .directory));
}

test "startup reservation cancel failure retry and allocation failure never expose old identities" {
    var adapter: Adapter = .{ .cancel_receipt = .awaiting };
    var domain = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.interface()});
    defer domain.deinit();
    const first = try domain.create(spec(), target);
    const old = try reserve(&domain, first);
    try std.testing.expect(try domain.cancel(first.operation));
    try std.testing.expect(!domain.bindingIsPreparing(old.directory, first.operation));
    try std.testing.expect(!domain.bindingIsLive(old.directory));
    try std.testing.expect(domain.queryService(first.handle, .directory) == .temporarily_unavailable);
    try std.testing.expect(!try domain.ready(first.handle, first.operation, plugins.requiredServices(.sftp)));
    try std.testing.expectError(error.CleanupNotReleased, domain.retry(first.handle));
    try std.testing.expect(try domain.createCleanupReceipt(first.handle, first.operation, .released));
    const next = try domain.retry(first.handle);
    const fresh = try reserve(&domain, next);
    try std.testing.expect(fresh.directory.binding_id > old.file_read.binding_id);
    try std.testing.expectEqual(first.handle.generation + 1, fresh.directory.binding_generation);
    try std.testing.expectError(error.StaleCreateOperation, domain.reserveService(next.handle, first.operation, .directory));
    try std.testing.expect(!domain.bindingIsPreparing(old.directory, next.operation));
    try std.testing.expect(try domain.failed(next.handle, next.operation, .{ .domain = .plugin, .code = "directory_denied", .cleanup = .released, .safe_message = "fixture" }));
    try std.testing.expect(!domain.bindingIsPreparing(fresh.directory, next.operation));
    try std.testing.expect(domain.queryService(next.handle, .directory) == .temporarily_unavailable);

    const last = try domain.retry(next.handle);
    domain.next_binding = std.math.maxInt(u64);
    const reserved = try domain.reserveService(last.handle, last.operation, .directory);
    try std.testing.expectError(error.BindingExhausted, domain.ready(last.handle, last.operation, plugins.requiredServices(.sftp)));
    try std.testing.expect(domain.bindingIsPreparing(reserved, last.operation));
    try std.testing.expect(reserved.eql(try domain.reserveService(last.handle, last.operation, .directory)));
    try std.testing.expect(domain.queryService(last.handle, .directory) == .temporarily_unavailable);
}

test "file binding startup permits only original reserved directory validation and awaits real cancel cleanup" {
    var adapter: Adapter = .{};
    var domain = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.interface()});
    defer domain.deinit();
    const accepted = try domain.create(spec(), target);
    const logical = try reserve(&domain, accepted);
    var gate: Gate = .{ .caller = std.Thread.getCurrentId() };
    var host = try files.FileBindingHost.init(std.testing.allocator, &domain, gate.factory());
    defer stop(&host, &gate);
    adapter.host = &host;
    try std.testing.expectError(error.StaleBinding, host.attach(accepted.handle, logical));
    var forged = logical;
    forged.file_read.binding_id += 100;
    try std.testing.expectError(error.StaleBinding, host.attachPreparing(accepted.handle, accepted.operation, forged));
    const other = try domain.journal.begin(.{ .session = accepted.handle }, 1);
    try std.testing.expectError(error.StaleCreateOperation, host.attachPreparing(accepted.handle, other, logical));
    try std.testing.expectEqual(@as(usize, 0), gate.prepares);
    const endpoint = try host.attachPreparing(accepted.handle, accepted.operation, logical);
    try std.testing.expect(endpoint.eql(try host.attachPreparing(accepted.handle, accepted.operation, logical)));
    try std.testing.expectEqual(@as(usize, 1), gate.prepares);
    try wait(&gate.entered);
    try std.testing.expect(gate.source.?.create_key.eql(accepted.operation));
    _ = try host.safeTick();
    try std.testing.expect(!gate.token.?.load(.acquire)); // creating is retained, not auto-closed as stale.
    try std.testing.expectError(error.StaleBinding, host.begin(logical.directory, .{ .path = ".", .action = .realpath }));
    try std.testing.expectError(error.StaleBinding, host.submit(logical.directory, other, .{ .path = ".", .action = .realpath }));
    try std.testing.expectError(error.StartupActionNotAllowed, host.beginPreparing(logical.directory, accepted.operation, .{ .path = "/a", .action = .{ .read_text = .{} } }));
    try std.testing.expectError(error.StartupActionNotAllowed, host.beginPreparing(logical.directory, accepted.operation, .{ .path = "/", .action = .{ .mkdir = .{ .name = "must-not-create-during-probe" } } }));
    try std.testing.expectError(error.ServiceKindMismatch, host.beginPreparing(logical.file_read, accepted.operation, .{ .path = "/", .action = .stat }));
    const realpath = try host.beginPreparing(logical.directory, accepted.operation, .{ .path = ".", .action = .realpath });
    const list = try host.beginPreparing(logical.directory, accepted.operation, .{ .path = "/", .action = .{ .list = .{} }, .directory_revision = 44 });
    try std.testing.expect(!domain.journal.isTerminal(accepted.operation));
    try std.testing.expectError(error.StaleCreateOperation, host.cancelPreparing(accepted.handle, other));
    try std.testing.expect(!gate.token.?.load(.acquire));
    try std.testing.expect(try domain.cancel(accepted.operation));
    try std.testing.expect(gate.token.?.load(.acquire));
    try std.testing.expectEqual(sessions.Lifecycle.failed, domain.queryState(accepted.handle).?.lifecycle);
    try std.testing.expectEqual(@import("host/operation.zig").Cleanup.releasing, domain.queryState(accepted.handle).?.create_cleanup);
    try std.testing.expectError(error.CleanupNotReleased, domain.retry(accepted.handle));
    try std.testing.expectError(error.SessionNotCreating, host.beginPreparing(logical.directory, accepted.operation, .{ .path = ".", .action = .realpath }));
    gate.release_connect.store(true, .release);
    try wait(&gate.close_entered);
    _ = try host.safeTick();
    for ([_]sessions.OperationKey{ realpath, list }) |key| {
        var response = host.take(key) orelse return error.ResponseMissing;
        defer response.deinit();
        try std.testing.expect(response.stale and response.result.value.final);
        try std.testing.expect(response.result.value.body == .cancelled);
        try std.testing.expect(response.result.value.key.eql(key));
        try host.retire(key);
    }
    try std.testing.expectEqual(files.readonly.ReleaseReceipt.awaiting, try host.cancelPreparing(accepted.handle, accepted.operation));
    try std.testing.expect(!gate.destroyed.load(.acquire));
    try std.testing.expect(domain.queryService(accepted.handle, .directory) == .temporarily_unavailable);
    gate.close_state.store(@backingInt(files.readonly.ReleaseReceipt.released), .release);
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (try host.safeTick()) {
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
    try std.testing.expect(gate.destroyed.load(.acquire));
    try std.testing.expectEqual(files.readonly.ReleaseReceipt.released, try host.cancelPreparing(accepted.handle, accepted.operation));
    try std.testing.expect(try domain.createCleanupReceipt(accepted.handle, accepted.operation, .released));
    const replacement = try domain.retry(accepted.handle);
    const fresh = try reserve(&domain, replacement);
    try std.testing.expect(fresh.directory.binding_id > logical.file_read.binding_id);
    try std.testing.expectError(error.StaleSession, host.attachPreparing(accepted.handle, accepted.operation, logical));
    try std.testing.expect(!try domain.ready(accepted.handle, accepted.operation, plugins.requiredServices(.sftp)));
    try std.testing.expect(domain.queryService(replacement.handle, .directory) == .temporarily_unavailable);
}
