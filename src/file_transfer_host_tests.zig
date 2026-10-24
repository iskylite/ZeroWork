const std = @import("std");
const module = @import("host/file_transfer_host.zig");
const files = @import("host/file_binding_host.zig");
const factory_mod = @import("host/file_route_factory.zig");
const sftp_adapter = @import("host/sftp_adapter.zig");
const sessions = @import("host/session_host.zig");
const plugins = @import("host/plugin_registry.zig");
const operations = @import("host/operation.zig");
const ssh = @import("proto/ssh/session.zig");
const clock = @import("platform/realtime.zig");
const a = std.testing.allocator;
fn pause() void {
    var unused: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&unused, 0, 2);
}
const Adapter = struct {
    fn create(_: *anyopaque, _: sessions.CreateRequest) !void {}
    fn cancel(_: *anyopaque, _: sessions.OperationKey) sessions.CloseReceipt {
        return .awaiting;
    }
    fn close(_: *anyopaque, _: sessions.SessionHandle, _: sessions.OperationKey) !sessions.CloseReceipt {
        return .awaiting;
    }
    fn stale(_: *anyopaque, _: sessions.SessionHandle, _: sessions.OperationKey) void {}
    fn interface(self: *Adapter) sessions.Adapter {
        return .{ .registration = .{ .plugin_id = .sftp, .workspace_kind = .file, .services = plugins.requiredServices(.sftp) }, .context = self, .vtable = &.{ .create = create, .cancel = cancel, .close = close, .release_stale = stale } };
    }
    fn sshInterface(self: *Adapter) sessions.Adapter {
        return .{ .registration = .{ .plugin_id = .ssh, .workspace_kind = .terminal, .services = plugins.requiredServices(.ssh) }, .context = self, .vtable = &.{ .create = create, .cancel = cancel, .close = close, .release_stale = stale } };
    }
};
fn live(raw: *anyopaque, binding: sessions.ServiceHandle) bool {
    const domain: *sessions.SessionHost = @ptrCast(@alignCast(raw));
    return domain.bindingIsLive(binding);
}
fn spec(address: []const u8, password: []const u8) sessions.SessionCreateSpec {
    return .{ .saved = .{ .connection_id = @fromBackingInt(57), .config_revision = 4, .protocol = .sftp, .immutable_config = .{ .endpoint = .{ .host = address, .user = "root" }, .auth = .{ .password = password } } } };
}
const Gate = struct {
    caller: std.Thread.Id,
    prepares: usize = 0,
    discards: usize = 0,
    reject: bool = false,
    mismatch: bool = false,
    source: ?files.Source = null,
    connecting: std.atomic.Value(bool) = .init(false),
    release_connect: std.atomic.Value(bool) = .init(false),
    closing: std.atomic.Value(bool) = .init(false),
    destroyed: std.atomic.Value(bool) = .init(false),
    receipt: std.atomic.Value(u8) = .init(@backingInt(files.readonly.ReleaseReceipt.awaiting)),
    fn interface(self: *Gate) files.Factory {
        return .{ .context = self, .prepare = prepare, .discard = discard };
    }
    fn prepare(raw: *anyopaque, source: files.Source) !files.readonly.Connector {
        const self: *Gate = @ptrCast(@alignCast(raw));
        self.prepares += 1;
        self.source = source;
        if (self.reject) return error.ControlledPrepareRejected;
        var key = source.open_key;
        if (self.mismatch) key.operation_id += 100;
        return .{ .key = key, .ctx = self, .connect_fn = connect, .close_fn = close, .deinit_fn = destroy };
    }
    fn discard(raw: *anyopaque, _: files.readonly.Connector) void {
        const self: *Gate = @ptrCast(@alignCast(raw));
        std.debug.assert(self.caller == std.Thread.getCurrentId());
        self.discards += 1;
    }
    fn connect(raw: *anyopaque, cancel_: *const std.atomic.Value(bool)) !ssh.Session {
        const self: *Gate = @ptrCast(@alignCast(raw));
        std.debug.assert(self.caller != std.Thread.getCurrentId());
        self.connecting.store(true, .release);
        const deadline = clock.monotonicNs() + 10 * std.time.ns_per_s;
        while (!self.release_connect.load(.acquire) and !cancel_.load(.acquire)) {
            if (clock.monotonicNs() >= deadline) return error.TestTimeout;
            pause();
        }
        return error.ControlledConnectFailure;
    }
    fn close(raw: *anyopaque, session: ?*ssh.Session) files.readonly.ReleaseReceipt {
        const self: *Gate = @ptrCast(@alignCast(raw));
        std.debug.assert(self.caller != std.Thread.getCurrentId() and session == null);
        self.closing.store(true, .release);
        return @fromBackingInt(@intCast(self.receipt.load(.acquire)));
    }
    fn destroy(raw: *anyopaque) void {
        const self: *Gate = @ptrCast(@alignCast(raw));
        std.debug.assert(self.caller != std.Thread.getCurrentId());
        self.destroyed.store(true, .release);
    }
};
const Fixture = struct {
    adapter: Adapter,
    domain: sessions.SessionHost,
    mux: module.routing.Mux,
    gate: Gate,
    host: module.Host,
    request: sftp_adapter.TransferStart,
    fn init(self: *Fixture) !void {
        self.adapter = .{};
        self.domain = try sessions.SessionHost.init(a, &.{self.adapter.interface()});
        self.mux = module.routing.Mux.init(a, .{ .context = &self.domain, .is_live = live });
        self.gate = .{ .caller = std.Thread.getCurrentId() };
        self.host = try module.Host.init(a, &self.domain, &self.mux, self.gate.interface());
        const input = spec("controlled.invalid", "original-password");
        const created = try self.domain.create(input, .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) });
        const binding = try self.domain.reserveService(created.handle, created.operation, .transfer);
        self.request = .{ .source = .{ .owner = created.handle, .create_key = created.operation, .open_key = try self.domain.journal.begin(.{ .session = created.handle }, created.operation.attempt_id), .spec = input }, .binding = binding };
    }
    fn initAuxiliary(self: *Fixture) !void {
        self.adapter = .{};
        self.domain = try sessions.SessionHost.init(a, &.{self.adapter.sshInterface()});
        self.mux = module.routing.Mux.init(a, .{ .context = &self.domain, .is_live = live });
        self.gate = .{ .caller = std.Thread.getCurrentId() };
        self.host = try module.Host.init(a, &self.domain, &self.mux, self.gate.interface());
        var input = spec("controlled.invalid", "original-password");
        input.saved.protocol = .ssh;
        const created = try self.domain.create(input, .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) });
        try std.testing.expect(try self.domain.ready(created.handle, created.operation, plugins.requiredServices(.ssh)));
        try std.testing.expect(try self.domain.attached(created.handle, .{ .target = .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) }, .tab_id = @fromBackingInt(7) }));
        // The unused first reservation owns no Runtime. Its release allows an
        // independent second binding generation on the same original SSH.
        const first = try self.domain.beginAuxiliaryTransfer(created.handle);
        try std.testing.expect(try self.domain.auxiliaryTransferReleased(first.binding, first.key, .released));
        const next = try self.domain.beginAuxiliaryTransfer(created.handle);
        self.request = .{ .source = .{ .owner = created.handle, .create_key = next.key, .open_key = next.key, .spec = next.spec }, .binding = next.binding };
    }
    fn closeRequest(self: *Fixture) sftp_adapter.TransferClose {
        return .{ .owner = self.request.source.owner, .create_key = self.request.source.create_key, .operation = self.request.source.create_key, .binding = self.request.binding };
    }
    fn stop(self: *Fixture) void {
        _ = self.host.shutdownStep();
        self.gate.release_connect.store(true, .release);
        self.gate.receipt.store(@backingInt(files.readonly.ReleaseReceipt.released), .release);
        const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
        while (self.host.safeTick() catch unreachable) {
            if (clock.monotonicNs() >= deadline) @panic("transfer host did not drain");
            pause();
        }
        self.host.deinit() catch unreachable;
        self.mux.deinit() catch unreachable;
        self.domain.deinit();
    }
};

test "file transfer host validates original reserved source and forwards the exact journal key once" {
    var f: Fixture = undefined;
    try f.init();
    defer f.stop();
    const hooks = f.host.hooks();
    var bad = f.request;
    bad.source.owner.generation += 1;
    try std.testing.expectError(error.OwnerMismatch, hooks.start(hooks.context, bad));
    bad = f.request;
    bad.source.create_key.operation_id += 90;
    try std.testing.expectError(error.StaleCreateOperation, hooks.start(hooks.context, bad));
    bad = f.request;
    bad.source.open_key.operation_id += 90;
    try std.testing.expectError(error.UnknownOperation, hooks.start(hooks.context, bad));
    bad = f.request;
    bad.source.spec.saved.immutable_config.endpoint.host = "later-active.invalid";
    try std.testing.expectError(error.TransferSourceChanged, hooks.start(hooks.context, bad));
    bad = f.request;
    bad.source.spec.saved.immutable_config.auth = .{ .password = "later-password" };
    try std.testing.expectError(error.TransferSourceChanged, hooks.start(hooks.context, bad));
    try std.testing.expectEqual(@as(usize, 0), f.gate.prepares);
    try hooks.start(hooks.context, f.request);
    try hooks.start(hooks.context, f.request);
    try std.testing.expectEqual(@as(usize, 1), f.gate.prepares);
    try std.testing.expect(f.gate.source.?.open_key.eql(f.request.source.open_key));
    try std.testing.expect(f.gate.source.?.create_key.eql(f.request.source.create_key));
    try std.testing.expect(f.gate.source.?.owner.eql(f.request.source.owner));
    try std.testing.expectEqualStrings("controlled.invalid", f.gate.source.?.spec.saved.immutable_config.endpoint.host);
    try std.testing.expect(hooks.poll(hooks.context, f.request.binding, f.request.source.create_key) == .pending);
    _ = try f.host.safeTick();
    try std.testing.expectEqual(@as(usize, 0), f.mux.registrations.items.len);
    try std.testing.expect(f.domain.bindingIsPreparing(f.request.binding, f.request.source.create_key));
}

test "file transfer host rejected prepare has no resource and mismatched connector is discarded before IO" {
    var f: Fixture = undefined;
    try f.init();
    defer f.stop();
    const hooks = f.host.hooks();
    f.gate.reject = true;
    try std.testing.expectError(error.ControlledPrepareRejected, hooks.start(hooks.context, f.request));
    try std.testing.expectEqual(@as(usize, 0), f.host.entries.items.len);
    try std.testing.expectEqual(.released, hooks.close(hooks.context, f.closeRequest()));
    f.gate.reject = false;
    f.gate.mismatch = true;
    try std.testing.expectError(error.FactoryOperationMismatch, hooks.start(hooks.context, f.request));
    try std.testing.expectEqual(@as(usize, 1), f.gate.discards);
    try std.testing.expect(!f.gate.connecting.load(.acquire));
    try std.testing.expectEqual(.released, hooks.close(hooks.context, f.closeRequest()));
}

test "file transfer host failure and unknown cleanup stay on original key until real Runtime release" {
    var f: Fixture = undefined;
    try f.init();
    defer f.stop();
    const hooks = f.host.hooks();
    try hooks.start(hooks.context, f.request);
    f.gate.release_connect.store(true, .release);
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (!f.gate.closing.load(.acquire)) {
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
    var status = hooks.poll(hooks.context, f.request.binding, f.request.source.create_key);
    try std.testing.expect(status == .failed);
    try std.testing.expectEqualStrings("ControlledConnectFailure", status.failed.code);
    try std.testing.expectEqual(operations.Cleanup.releasing, status.failed.cleanup);
    var forged = f.closeRequest();
    forged.operation.operation_id += 100;
    try std.testing.expectEqual(.unknown, hooks.close(hooks.context, forged));
    try std.testing.expect(!f.host.entries.items[0].closing);
    forged = f.closeRequest();
    forged.owner.generation += 1;
    try std.testing.expectEqual(.unknown, hooks.close(hooks.context, forged));
    var wrong_create = f.request.source.create_key;
    wrong_create.operation_id += 100;
    try std.testing.expectEqualStrings("stale_transfer_create_operation", hooks.poll(hooks.context, f.request.binding, wrong_create).failed.code);
    f.gate.receipt.store(@backingInt(files.readonly.ReleaseReceipt.unknown), .release);
    while (f.host.entries.items[0].backend.closeReceipt() != .unknown) {
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
    try std.testing.expectEqual(.unknown, hooks.close(hooks.context, f.closeRequest()));
    _ = try f.host.safeTick();
    try std.testing.expectEqual(.unknown, f.host.shutdownStep());
    try std.testing.expectError(error.Busy, f.host.deinit());
    try std.testing.expect(!f.gate.destroyed.load(.acquire));
    status = hooks.poll(hooks.context, f.request.binding, f.request.source.create_key);
    try std.testing.expect(status == .failed);
    try std.testing.expectEqual(operations.Cleanup.unknown, status.failed.cleanup);
    f.gate.receipt.store(@backingInt(files.readonly.ReleaseReceipt.released), .release);
    while (try f.host.safeTick()) {
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
    try std.testing.expect(f.gate.destroyed.load(.acquire));
    try std.testing.expectEqual(.released, hooks.close(hooks.context, f.closeRequest()));
    try std.testing.expectEqual(.released, f.host.shutdownStep());
    try std.testing.expectError(error.TransferHostClosing, hooks.start(hooks.context, f.request));
}

test "file transfer host stale domain revokes only its Runtime without publishing a service" {
    var f: Fixture = undefined;
    try f.init();
    defer f.stop();
    const hooks = f.host.hooks();
    try hooks.start(hooks.context, f.request);
    try std.testing.expect(try f.domain.failed(f.request.source.owner, f.request.source.create_key, .{ .domain = .plugin, .code = "fixture_failed", .cleanup = .releasing, .safe_message = "controlled domain failure" }));
    _ = try f.host.safeTick();
    try std.testing.expect(f.host.entries.items[0].closing);
    try std.testing.expect(f.host.entries.items[0].backend.closing.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), f.mux.registrations.items.len);
    try std.testing.expectEqualStrings("stale_transfer_binding", hooks.poll(hooks.context, f.request.binding, f.request.source.create_key).failed.code);
    try std.testing.expect(f.domain.queryService(f.request.source.owner, .transfer) == .temporarily_unavailable);
}

const HoldPause = struct {
    fn run(_: *anyopaque, _: sessions.SessionHandle, _: operations.OperationKey) !sessions.CloseReceipt {
        return .awaiting;
    }
};

test "file transfer host auxiliary uses exact independent generation and waits for actual released receipt" {
    var f: Fixture = undefined;
    try f.initAuxiliary();
    defer f.stop();
    const hooks = f.host.hooks();
    const owner = f.request.source.owner;
    const key = f.request.source.create_key;
    try std.testing.expect(f.request.binding.binding_generation != owner.generation);
    try std.testing.expect(f.domain.queryState(owner).?.create_operation.operation_id != key.operation_id);
    var bad = f.request;
    bad.binding.binding_generation += 1;
    try std.testing.expectError(error.TransferBindingNotPreparing, hooks.start(hooks.context, bad));
    bad = f.request;
    bad.binding.origin_session.?.generation += 1;
    try std.testing.expectError(error.OwnerMismatch, hooks.start(hooks.context, bad));
    bad = f.request;
    bad.source.open_key.operation_id += 100;
    try std.testing.expectError(error.OwnerMismatch, hooks.start(hooks.context, bad));
    bad = f.request;
    bad.source.spec.saved.immutable_config.endpoint.host = "later-active.invalid";
    try std.testing.expectError(error.TransferSourceChanged, hooks.start(hooks.context, bad));
    try std.testing.expectEqual(@as(usize, 0), f.gate.prepares);
    try hooks.start(hooks.context, f.request);
    try hooks.start(hooks.context, f.request);
    try std.testing.expectEqual(@as(usize, 1), f.gate.prepares);
    try std.testing.expect(f.host.entries.items[0].auxiliary and f.host.entries.items[0].backend.auxiliary);
    _ = try f.host.safeTick();
    try std.testing.expect(!f.host.entries.items[0].closing);
    try std.testing.expect(hooks.poll(hooks.context, f.request.binding, key) == .pending);
    var forged = f.closeRequest();
    forged.operation.operation_id += 100;
    try std.testing.expectEqual(.unknown, hooks.close(hooks.context, forged));
    try std.testing.expect(!f.host.entries.items[0].closing);
    try std.testing.expectEqual(.awaiting, hooks.close(hooks.context, f.closeRequest()));
    try std.testing.expect(!f.domain.auxiliaryTransferOperationIsCurrent(owner, key));
    try std.testing.expectError(error.CleanupNotReleased, f.domain.beginAuxiliaryTransfer(owner));
    f.gate.receipt.store(@backingInt(files.readonly.ReleaseReceipt.unknown), .release);
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (f.host.entries.items[0].backend.closeReceipt() != .unknown) {
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
    _ = try f.host.safeTick();
    try std.testing.expectEqual(.unknown, hooks.close(hooks.context, f.closeRequest()));
    try std.testing.expectError(error.CleanupNotReleased, f.domain.beginAuxiliaryTransfer(owner));
    f.gate.receipt.store(@backingInt(files.readonly.ReleaseReceipt.awaiting), .release);
    while (f.host.entries.items[0].backend.closeReceipt() != .awaiting) {
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
    _ = try f.host.safeTick();
    try std.testing.expectError(error.CleanupNotReleased, f.domain.beginAuxiliaryTransfer(owner));
    f.gate.receipt.store(@backingInt(files.readonly.ReleaseReceipt.released), .release);
    while (try f.host.safeTick()) {
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
    try std.testing.expect(f.gate.destroyed.load(.acquire));
    try std.testing.expect(f.domain.journal.isTerminal(key));
    try std.testing.expectEqual(.released, hooks.close(hooks.context, f.closeRequest()));
    const newer = try f.domain.beginAuxiliaryTransfer(owner);
    try std.testing.expectEqual(f.request.binding.binding_generation + 1, newer.binding.binding_generation);
    try std.testing.expectEqual(.unknown, hooks.close(hooks.context, f.closeRequest()));
    try std.testing.expect(f.domain.auxiliaryTransferOperationIsCurrent(owner, newer.key));
    try std.testing.expect(try f.domain.auxiliaryTransferReleased(newer.binding, newer.key, .released));
}

test "file transfer host auxiliary empty close after prepareRetain accepts original session close operation" {
    var f: Fixture = undefined;
    try f.initAuxiliary();
    defer f.stop();
    const hooks = f.host.hooks();
    try hooks.start(hooks.context, f.request);
    const owner = f.request.source.owner;
    const close_key = try f.domain.requestClose(owner, .{ .pause_transfers = .{ .context = &f, .run = HoldPause.run } });
    try f.host.prepareRetain(owner, close_key);
    _ = try f.host.safeTick();
    try std.testing.expect(!f.host.entries.items[0].closing);
    try std.testing.expect(!f.host.entries.items[0].backend.closing.load(.acquire));
    try std.testing.expect(!f.domain.auxiliaryTransferOperationIsCurrent(owner, f.request.source.create_key));
    var request = f.closeRequest();
    request.operation = close_key;
    try std.testing.expect(!request.create_key.eql(request.operation));
    var forged = request;
    forged.operation.operation_id += 100;
    try std.testing.expectEqual(.unknown, hooks.close(hooks.context, forged));
    try std.testing.expectEqual(.awaiting, hooks.close(hooks.context, request));
    try std.testing.expect(f.host.entries.items[0].closing);
    f.gate.receipt.store(@backingInt(files.readonly.ReleaseReceipt.released), .release);
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (try f.host.safeTick()) {
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
    try std.testing.expect(f.domain.journal.isTerminal(f.request.source.create_key));
    try std.testing.expectEqual(.released, hooks.close(hooks.context, request));
    try std.testing.expect(try f.domain.closeReceipt(owner, close_key, .pause_transfers, .released));
}

test "file transfer host prepareRetain precedes stale cancellation and empty handoff waits for real release" {
    var f: Fixture = undefined;
    try f.init();
    defer f.stop();
    const hooks = f.host.hooks();
    try hooks.start(hooks.context, f.request);
    const owner = f.request.source.owner;
    try std.testing.expect(try f.domain.ready(owner, f.request.source.create_key, plugins.requiredServices(.sftp)));
    try std.testing.expect(try f.domain.attached(owner, .{ .target = .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) }, .tab_id = @fromBackingInt(7) }));
    const retained = try f.domain.retainTransferSource(owner);
    const key = try f.domain.requestClose(owner, .{ .pause_transfers = .{ .context = &f, .run = HoldPause.run } });
    try f.host.prepareRetain(owner, key);
    _ = try f.host.safeTick();
    try std.testing.expect(!f.host.entries.items[0].closing);
    try std.testing.expect(!f.host.entries.items[0].backend.closing.load(.acquire));
    var forged = key;
    forged.operation_id += 1;
    try std.testing.expectError(error.StaleCloseOperation, f.host.prepareRetain(owner, forged));
    try std.testing.expectError(error.StaleCloseOperation, f.host.takeRetained(owner, forged));
    try std.testing.expectEqual(.awaiting, try f.host.retainPaused(owner, key, retained, &.{}));
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (!f.gate.closing.load(.acquire)) {
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
    try std.testing.expect((try f.host.takeRetained(owner, key)) == null);
    f.gate.receipt.store(@backingInt(files.readonly.ReleaseReceipt.unknown), .release);
    while (try f.host.retainPaused(owner, key, retained, &.{}) != .unknown) {
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
    _ = try f.host.safeTick();
    try std.testing.expectError(error.Busy, f.host.deinit());
    try std.testing.expect((try f.host.takeRetained(owner, key)) == null);
    f.gate.receipt.store(@backingInt(files.readonly.ReleaseReceipt.released), .release);
    while (try f.host.retainPaused(owner, key, retained, &.{}) != .released) {
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
    _ = try f.host.safeTick();
    try std.testing.expectEqual(@as(usize, 1), f.host.entries.items.len);
    var batch = (try f.host.takeRetained(owner, key)).?;
    try std.testing.expectEqual(retained, batch.retained_owner);
    try batch.deinit();
    try std.testing.expect((try f.host.takeRetained(owner, key)) == null);
    while (try f.host.safeTick()) {
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
    try std.testing.expect(f.gate.destroyed.load(.acquire));
}

test "file transfer host retained source uses frozen original after close and releases exact new generation" {
    var f: Fixture = undefined;
    try f.init();
    defer f.stop();
    const owner = f.request.source.owner;
    try std.testing.expect(try f.domain.ready(owner, f.request.source.create_key, plugins.requiredServices(.sftp)));
    try std.testing.expect(try f.domain.attached(owner, .{ .target = .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) }, .tab_id = @fromBackingInt(7) }));
    const retained = try f.domain.retainTransferSource(owner);
    const close_key = try f.domain.requestClose(owner, .{});
    try std.testing.expect(try f.domain.closeReceipt(owner, close_key, .close_protocol, .released));
    try std.testing.expectEqual(.closed, f.domain.queryState(owner).?.lifecycle);
    const next = try f.domain.beginRetainedTransfer(retained, owner);
    const request: sftp_adapter.TransferStart = .{ .source = .{ .owner = owner, .retained_owner = retained, .create_key = next.key, .open_key = next.key, .spec = next.spec }, .binding = next.binding };
    const hooks = f.host.hooks();
    var wrong = request;
    wrong.source.spec.saved.immutable_config.endpoint.host = "changed-asset.invalid";
    try std.testing.expectError(error.TransferSourceChanged, hooks.start(hooks.context, wrong));
    wrong = request;
    wrong.source.retained_owner = @fromBackingInt(@backingInt(retained) + 1);
    try std.testing.expectError(error.StaleCreateOperation, hooks.start(hooks.context, wrong));
    try hooks.start(hooks.context, request);
    try std.testing.expectEqual(retained, f.gate.source.?.retained_owner.?);
    try std.testing.expectEqualStrings("controlled.invalid", f.gate.source.?.spec.saved.immutable_config.endpoint.host);
    try std.testing.expect(f.gate.source.?.open_key.eql(next.key));
    try std.testing.expect(hooks.poll(hooks.context, next.binding, next.key) == .pending);
    var checkpoint: module.OwnedCheckpoint = .{};
    try std.testing.expectError(error.TransferNotReady, f.host.importPaused(next.binding, next.key, &checkpoint, .{ .transfer_binding = next.binding, .session_id = @backingInt(owner.session_id), .direction = .download, .sources = &.{"a"}, .remote_dir = "/", .local_dir = "/tmp" }));
    const queued_spec: @import("transfer/manager.zig").JobSpec = .{ .transfer_binding = next.binding, .session_id = @backingInt(owner.session_id), .direction = .download, .sources = &.{"a"}, .remote_dir = "/", .local_dir = "/tmp" };
    const queued: module.RetainedDraft = .{ .original = queued_spec, .job_id = 14, .attempt = 0, .next = queued_spec };
    try std.testing.expectError(error.TransferNotReady, f.host.startRetainedDraft(next.binding, next.key, queued));
    const close_request: sftp_adapter.TransferClose = .{ .owner = owner, .create_key = next.key, .operation = next.key, .binding = next.binding };
    try std.testing.expectEqual(.awaiting, hooks.close(hooks.context, close_request));
    try std.testing.expectError(error.TransferNotReady, f.host.startRetainedDraft(next.binding, next.key, queued));
    try std.testing.expect(!f.domain.retainedTransferOperationIsCurrent(retained, owner, next.key));
    try std.testing.expectError(error.CleanupNotReleased, f.domain.beginRetainedTransfer(retained, owner));
    f.gate.receipt.store(@backingInt(files.readonly.ReleaseReceipt.unknown), .release);
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (f.host.entries.items[0].backend.closeReceipt() != .unknown) {
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
    _ = try f.host.safeTick();
    try std.testing.expectError(error.CleanupNotReleased, f.domain.beginRetainedTransfer(retained, owner));
    f.gate.receipt.store(@backingInt(files.readonly.ReleaseReceipt.released), .release);
    while (try f.host.safeTick()) {
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
    const newer = try f.domain.beginRetainedTransfer(retained, owner);
    try std.testing.expect(newer.binding.binding_generation > next.binding.binding_generation);
    try std.testing.expect(!newer.key.eql(next.key));
    try std.testing.expectError(error.StaleCreateOperation, hooks.start(hooks.context, request));
    try std.testing.expectEqual(.released, hooks.close(hooks.context, close_request));
    try std.testing.expect(f.domain.retainedTransferOperationIsCurrent(retained, owner, newer.key));
    try std.testing.expect(try f.domain.retainedTransferReleased(newer.binding, newer.key, .released));
    try f.domain.releaseRetainedTransfer(retained, owner);
}

test "file transfer host optional VM registers real engine only when live and leaves terminal polling to Manager" {
    const password = std.c.getenv("ZEROWORK_VM_PASSWORD") orelse return error.SkipZigTest;
    var domain_adapter: Adapter = .{};
    var domain = try sessions.SessionHost.init(a, &.{domain_adapter.interface()});
    defer domain.deinit();
    var mux = module.routing.Mux.init(a, .{ .context = &domain, .is_live = live });
    defer mux.deinit() catch unreachable;
    var library = try ssh.Library.init();
    defer library.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(directory);
    const trust_path = try std.fs.path.join(a, &.{ directory, "known_hosts" });
    defer a.free(trust_path);
    const Trust = struct {
        fn observe(_: *anyopaque, _: []const u8, _: u16, _: ssh.HostKeyInfo) ssh.HostKeyDecision {
            return .trust_once;
        }
    };
    var factory: factory_mod.SourceFactory = .{ .library = &library, .known_hosts_path = trust_path, .timeout_ms = 5000, .host_key_observer = .{ .ctx = &domain_adapter, .callback = Trust.observe } };
    var host = try module.Host.init(a, &domain, &mux, factory.interface());
    defer {
        _ = host.shutdownStep();
        const deadline = clock.monotonicNs() + 10 * std.time.ns_per_s;
        while (host.safeTick() catch unreachable) {
            // This is the test's Manager-equivalent consumer, never Host.
            while (mux.poll() != null) {}
            if (clock.monotonicNs() >= deadline) @panic("VM transfer host cleanup timeout");
            pause();
        }
        host.deinit() catch unreachable;
    }
    const input = spec("192.0.2.10", std.mem.span(password));
    const accepted = try domain.create(input, .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) });
    const binding = try domain.reserveService(accepted.handle, accepted.operation, .transfer);
    const open_key = try domain.journal.begin(.{ .session = accepted.handle }, accepted.operation.attempt_id);
    const hooks = host.hooks();
    try hooks.start(hooks.context, .{ .source = .{ .owner = accepted.handle, .create_key = accepted.operation, .open_key = open_key, .spec = input }, .binding = binding });
    const deadline = clock.monotonicNs() + 10 * std.time.ns_per_s;
    while (true) {
        _ = try host.safeTick();
        const status = hooks.poll(hooks.context, binding, accepted.operation);
        if (status == .failed) return error.RealTransferRuntimeFailed;
        if (status == .ready) {
            try std.testing.expect(status.ready.eql(binding));
            break;
        }
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
    try std.testing.expectEqual(@as(usize, 0), mux.registrations.items.len);
    try std.testing.expect(domain.bindingIsPreparing(binding, accepted.operation));
    _ = try domain.journal.publish(open_key, .completed, "real transfer backend ready", null);
    try std.testing.expect(try domain.ready(accepted.handle, accepted.operation, plugins.requiredServices(.sftp)));
    _ = try host.safeTick();
    try std.testing.expectEqual(@as(usize, 1), mux.registrations.items.len);
    try std.testing.expect(mux.registrations.items[0].binding.eql(binding));
    try std.testing.expect(mux.registrations.items[0].guard != null);
    try std.testing.expect(try domain.attached(accepted.handle, .{ .target = .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) }, .tab_id = @fromBackingInt(7) }));
    const job = try mux.open(.{ .transfer_binding = binding, .session_id = @backingInt(accepted.handle.session_id), .direction = .download, .sources = &.{"/etc/os-release"}, .remote_dir = "/etc", .local_dir = directory });
    const engine_owner = host.entries.items[0].backend.backend;
    while (!engine_owner.jobs.items[0].worker_done.load(.acquire)) {
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "os-release", a, .limited(4096));
    defer a.free(bytes);
    try std.testing.expect(std.mem.startsWith(u8, bytes, "NAME="));
    // No Mux.poll yet: native completion cannot mark its routing job terminal.
    // This is deterministic even if the small read has already completed.
    const close_key = try domain.requestClose(accepted.handle, .{});
    const close_request: sftp_adapter.TransferClose = .{ .owner = accepted.handle, .create_key = accepted.operation, .operation = close_key, .binding = binding };
    try std.testing.expectEqual(.awaiting, hooks.close(hooks.context, close_request));
    while (host.entries.items[0].backend.closeReceipt() != .released) {
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
    _ = try host.safeTick();
    try std.testing.expectEqual(@as(usize, 1), host.entries.items.len);
    try std.testing.expectEqual(@as(usize, 1), mux.registrations.items.len);
    try std.testing.expect(!mux.jobs.items[0].terminal);
    try std.testing.expectEqual(.awaiting, hooks.close(hooks.context, close_request));
    try std.testing.expectError(error.Busy, host.deinit());
    var terminal = false;
    while (!terminal) {
        if (mux.poll()) |event| {
            try std.testing.expectEqual(job, event.job);
            if (event.state != .running) terminal = true;
        } else {
            if (clock.monotonicNs() >= deadline) return error.TestTimeout;
            pause();
        }
    }
    while (try host.safeTick()) {
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
    try std.testing.expectEqual(@as(usize, 0), mux.registrations.items.len);
    try std.testing.expectEqual(@as(usize, 0), mux.jobs.items.len);
    try std.testing.expectEqual(.released, hooks.close(hooks.context, close_request));
    try std.testing.expect(try domain.closeReceipt(accepted.handle, close_key, .close_protocol, .released));
    _ = try domain.journal.publish(open_key, .cleanup_released, "real transfer runtime released", null);
    std.debug.print("FILE_TRANSFER_HOST_VM_PASS owner={d}/{d} open_key={d} binding={d}/{d} bytes={d} native_sftp_ready=true register_after_live=true manager_kept_terminal=true cleanup=released\n", .{ @backingInt(accepted.handle.session_id), accepted.handle.generation, open_key.operation_id, binding.binding_id, binding.binding_generation, bytes.len });
}
