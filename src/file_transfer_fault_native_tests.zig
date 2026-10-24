//! Opt-in real no-GUI libssh2 Runtime transport-fault checks. The peer owns
//! only loopback sockets and immutable bytes; default tests do not use a VM.
const std = @import("std");
const runtime = @import("host/file_transfer_runtime.zig");
const sessions = @import("host/session_host.zig");
const identity = @import("host/identity.zig");
const factory_mod = @import("host/file_route_factory.zig");
const files = @import("host/file_binding_host.zig");
const ssh = @import("proto/ssh/session.zig");
const clock = @import("platform/realtime.zig");
const hosts = @import("host/file_transfer_host.zig");
const plugins = @import("host/plugin_registry.zig");
const routing = @import("transfer/engine_mux.zig");
const transfer = @import("transfer/manager.zig");
const engine_mod = @import("transfer/sftp_engine.zig");
const a = std.testing.allocator;
const io = std.testing.io;

fn pause() void {
    var unused: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&unused, 0, 2);
}
const Fixture = struct {
    port: u16,
    controls: []const u8,
    fingerprint: []const u8,
    trusted: std.atomic.Value(bool) = .init(false),

    fn fromEnvironment() !Fixture {
        const raw = std.c.getenv("ZEROWORK_SFTP_FAULT_PORT") orelse return error.SkipZigTest;
        return .{ .port = try std.fmt.parseInt(u16, std.mem.span(raw), 10), .controls = std.mem.span(std.c.getenv("ZEROWORK_SFTP_FAULT_CONTROLS") orelse return error.MissingFixtureControls), .fingerprint = std.mem.span(std.c.getenv("ZEROWORK_SFTP_FAULT_FINGERPRINT") orelse return error.MissingFingerprint) };
    }
    fn trust(raw: *anyopaque, host: []const u8, port: u16, value: ssh.HostKeyInfo) ssh.HostKeyDecision {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (std.mem.eql(u8, host, "127.0.0.1") and port == self.port and value.status == .unknown and std.mem.eql(u8, value.fingerprint, self.fingerprint)) {
            self.trusted.store(true, .release);
            return .trust_once;
        }
        return .reject_unknown;
    }
    fn signal(self: Fixture, name: []const u8) !void {
        const path = try std.fs.path.join(a, &.{ self.controls, name });
        defer a.free(path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "ready\n" });
    }
    fn wait(self: Fixture, name: []const u8) !void {
        const path = try std.fs.path.join(a, &.{ self.controls, name });
        defer a.free(path);
        const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
        while (true) {
            std.Io.Dir.cwd().access(io, path, .{}) catch |err| {
                if (err != error.FileNotFound) return err;
                if (clock.monotonicNs() >= deadline) return error.PeerSignalTimeout;
                pause();
                continue;
            };
            return;
        }
    }
};

test "file transfer fault native idle FIN revokes ready without cancelling a task" {
    var fixture = try Fixture.fromEnvironment();
    var library = try ssh.Library.init();
    defer library.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    const known = try std.fs.path.join(a, &.{ directory, "known_hosts" });
    defer a.free(known);
    var factory: factory_mod.SourceFactory = .{ .library = &library, .known_hosts_path = known, .timeout_ms = 3000, .host_key_observer = .{ .ctx = &fixture, .callback = Fixture.trust } };
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(501), .generation = 1 };
    const key: sessions.OperationKey = .{ .owner = .{ .session = owner }, .operation_id = 701, .attempt_id = 1 };
    const binding: sessions.ServiceHandle = .{ .resource_owner = .{ .session = owner }, .origin_session = owner, .kind = .transfer, .binding_id = 801, .binding_generation = 1 };
    const source: files.Source = .{ .owner = owner, .create_key = key, .open_key = key, .spec = .{ .saved = .{ .connection_id = @fromBackingInt(901), .config_revision = 1, .protocol = .ssh, .immutable_config = .{ .endpoint = .{ .host = "127.0.0.1", .port = fixture.port, .user = "idle" }, .auth = .{ .password = "fault-fixture" } } } } };
    const api = factory.interface();
    const connector = try api.prepare(api.context, source);
    const value = runtime.Runtime.startAuxiliary(a, binding, connector) catch |err| {
        api.discard(api.context, connector);
        return err;
    };
    defer {
        value.requestRetainedCancel() catch unreachable;
        const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
        while (!value.done.load(.acquire)) {
            if (clock.monotonicNs() >= deadline) @panic("fault Runtime cleanup did not release");
            pause();
        }
        value.deinit() catch @panic("fault Runtime still owns resources");
    }
    const ready_deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (value.state() != .ready) {
        if (clock.monotonicNs() >= ready_deadline) return error.RuntimeNotReady;
        pause();
    }
    try std.testing.expect(fixture.trusted.load(.acquire));
    try fixture.signal("idle.fin");
    try fixture.wait("idle.fin-sent");
    const fault_deadline = clock.monotonicNs() + std.time.ns_per_s;
    while (value.state() == .ready and clock.monotonicNs() < fault_deadline) pause();
    try std.testing.expect(value.state() != .ready);
    try std.testing.expect(value.failureReason() != null);
    const engine = value.engine();
    try std.testing.expectError(error.TransferNotReady, engine.open(engine.ctx, .{ .transfer_binding = binding, .sources = &.{"/retained-fixture.bin"}, .direction = .download, .remote_dir = "/", .local_dir = directory }));
    std.debug.print("TRANSFER_FAULT_NATIVE idle_fin_nonready=true io_owner_preserved=true\n", .{});
}

const Adapter = struct {
    fn create(_: *anyopaque, _: sessions.CreateRequest) !void {}
    fn cancel(_: *anyopaque, _: sessions.OperationKey) sessions.CloseReceipt {
        return .released;
    }
    fn close(_: *anyopaque, _: sessions.SessionHandle, _: sessions.OperationKey) !sessions.CloseReceipt {
        return .released;
    }
    fn stale(_: *anyopaque, _: sessions.SessionHandle, _: sessions.OperationKey) void {}
    fn interface(self: *Adapter) sessions.Adapter {
        return .{ .registration = .{ .plugin_id = .ssh, .workspace_kind = .terminal, .services = plugins.requiredServices(.ssh) }, .context = self, .vtable = &.{ .create = create, .cancel = cancel, .close = close, .release_stale = stale } };
    }
};
fn live(raw: *anyopaque, binding: sessions.ServiceHandle) bool {
    return @as(*sessions.SessionHost, @ptrCast(@alignCast(raw))).bindingIsLive(binding);
}

/// Holds only the cleanup receipt; actual connect/SFTP/close still delegate
/// to the native connector on its original Runtime worker.
const GatedFactory = struct {
    actual: files.Factory,
    receipt: std.atomic.Value(u8) = .init(@backingInt(files.readonly.ReleaseReceipt.released)),
    close_entered: std.atomic.Value(bool) = .init(false),
    const Context = struct { parent: *GatedFactory, inner: files.readonly.Connector };
    fn interface(self: *GatedFactory) files.Factory {
        return .{ .context = self, .prepare = prepare, .discard = discard };
    }
    fn prepare(raw: *anyopaque, source: files.Source) !files.readonly.Connector {
        const self: *GatedFactory = @ptrCast(@alignCast(raw));
        const context = try a.create(Context);
        errdefer a.destroy(context);
        const inner = try self.actual.prepare(self.actual.context, source);
        context.* = .{ .parent = self, .inner = inner };
        return .{ .key = inner.key, .ctx = context, .connect_fn = connect, .close_fn = close, .deinit_fn = deinit };
    }
    fn discard(_: *anyopaque, connector: files.readonly.Connector) void {
        const context: *Context = @ptrCast(@alignCast(connector.ctx));
        context.parent.actual.discard(context.parent.actual.context, context.inner);
        a.destroy(context);
    }
    fn connect(raw: *anyopaque, cancelled: *const std.atomic.Value(bool)) !ssh.Session {
        const context: *Context = @ptrCast(@alignCast(raw));
        return context.inner.connect_fn(context.inner.ctx, cancelled);
    }
    fn close(raw: *anyopaque, session: ?*ssh.Session) files.readonly.ReleaseReceipt {
        const context: *Context = @ptrCast(@alignCast(raw));
        context.parent.close_entered.store(true, .release);
        const receipt: files.readonly.ReleaseReceipt = @fromBackingInt(@intCast(context.parent.receipt.load(.acquire)));
        if (receipt != .released) return receipt;
        return context.inner.close_fn(context.inner.ctx, session);
    }
    fn deinit(raw: *anyopaque) void {
        const context: *Context = @ptrCast(@alignCast(raw));
        context.inner.deinit_fn(context.inner.ctx);
        a.destroy(context);
    }
};

test "file transfer fault native auxiliary then retained FIN preserve nonzero checkpoint and exact handoff" {
    var fixture = try Fixture.fromEnvironment();
    var library = try ssh.Library.init();
    defer library.deinit();
    var adapter: Adapter = .{};
    var domain = try sessions.SessionHost.init(a, &.{adapter.interface()});
    defer domain.deinit();
    var mux = routing.Mux.init(a, .{ .context = &domain, .is_live = live });
    var manager = try transfer.Manager.init(a, mux.engine(), 1, .{ .max_attempts = 1 });
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    const known = try std.fs.path.join(a, &.{ directory, "known_hosts" });
    defer a.free(known);
    var factory: factory_mod.SourceFactory = .{ .library = &library, .known_hosts_path = known, .timeout_ms = 3000, .host_key_observer = .{ .ctx = &fixture, .callback = Fixture.trust } };
    var gated: GatedFactory = .{ .actual = factory.interface() };
    var host = try hosts.Host.init(a, &domain, &mux, gated.interface());
    defer {
        gated.receipt.store(@backingInt(files.readonly.ReleaseReceipt.released), .release);
        manager.deinit();
        const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
        while (host.shutdownStep() != .released) {
            _ = host.safeTick() catch {};
            while (mux.poll()) |_| {}
            if (clock.monotonicNs() >= deadline) @panic("fault Host cleanup retained resources");
            pause();
        }
        host.deinit() catch unreachable;
        mux.deinit() catch unreachable;
    }
    const source_spec: sessions.SessionCreateSpec = .{ .saved = .{ .connection_id = @fromBackingInt(57), .config_revision = 4, .protocol = .ssh, .immutable_config = .{ .endpoint = .{ .host = "127.0.0.1", .port = fixture.port, .user = "aux" }, .auth = .{ .password = "fault-fixture" } } } };
    const accepted = try domain.create(source_spec, .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) });
    try std.testing.expect(try domain.ready(accepted.handle, accepted.operation, plugins.requiredServices(.ssh)));
    try std.testing.expect(try domain.attached(accepted.handle, .{ .target = .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) }, .tab_id = @fromBackingInt(7) }));
    const hooks = host.hooks();
    const first = try domain.beginAuxiliaryTransfer(accepted.handle);
    var current_binding = first.binding;
    var current_key = first.key;
    var retained_owner: ?identity.RetainedTransferOwnerId = null;
    var checkpoint: ?engine_mod.OwnedCheckpoint = null;
    defer if (checkpoint) |*value| {
        const Cancel = struct {
            fn run(cp: *engine_mod.OwnedCheckpoint) void {
                std.debug.assert(cp.cancel(std.testing.io) == .released);
            }
        };
        const thread = std.Thread.spawn(.{}, Cancel.run, .{value}) catch unreachable;
        thread.join();
        value.deinit() catch unreachable;
    };
    var job: transfer.JobId = 0;
    for (0..2) |round| {
        const label = if (round == 0) "aux-1" else "aux-2";
        const request: @import("host/sftp_adapter.zig").TransferStart = .{ .binding = current_binding, .source = .{ .owner = accepted.handle, .retained_owner = if (round == 0) null else retained_owner, .create_key = current_key, .open_key = current_key, .spec = source_spec } };
        try hooks.start(hooks.context, request);
        const deadline = clock.monotonicNs() + 10 * std.time.ns_per_s;
        while (true) {
            _ = try host.safeTick();
            switch (hooks.poll(hooks.context, current_binding, current_key)) {
                .pending => {},
                .ready => |binding| {
                    if (!domain.bindingIsLive(binding)) {
                        try std.testing.expect(if (round == 0) try domain.auxiliaryTransferReady(binding, current_key) else try domain.retainedTransferReady(binding, current_key));
                    }
                    _ = try host.safeTick();
                    if (mux.isRegistered(binding)) break;
                },
                .failed => |failure| {
                    std.debug.print("FAULT_START_FAILURE {s}\n", .{failure.code});
                    return error.NativeFaultSetupFailed;
                },
            }
            if (clock.monotonicNs() >= deadline) return error.NativeFaultSetupTimeout;
            pause();
        }
        if (round == 0) {
            job = try manager.enqueue(.{ .transfer_binding = current_binding, .session_id = @backingInt(accepted.handle.session_id), .direction = .download, .sources = &.{"/retained-fixture.bin"}, .remote_dir = "/", .local_dir = directory, .md5_check = true, .conflict_context = .{ .intent_id = 11, .original_owner = accepted.handle, .resource_owner = current_binding.resource_owner, .source_endpoint = .{ .sftp = .{ .binding_id = current_binding.binding_id, .binding_generation = current_binding.binding_generation, .resource_owner = current_binding.resource_owner, .origin_session = accepted.handle, .connection_snapshot_id = 77 } }, .target_endpoint = .{ .local_fs = .{ .binding_id = 999, .binding_generation = 1 } } } });
            manager.tick(0);
        } else {
            const attempt = manager.progress(job).?.attempt;
            try manager.queueRetainedResume(job, attempt, .{ .id = retained_owner.?, .original_handle = accepted.handle });
            var spec = manager.retainedSpec(job, attempt).?;
            spec.transfer_binding = current_binding;
            spec.conflict_context.?.job = job;
            spec.conflict_context.?.resource_owner = current_binding.resource_owner;
            spec.conflict_context.?.attempt = @as(u32, attempt) + 1;
            const endpoint = &spec.conflict_context.?.source_endpoint.sftp;
            endpoint.binding_id = current_binding.binding_id;
            endpoint.binding_generation = current_binding.binding_generation;
            endpoint.resource_owner = current_binding.resource_owner;
            const Import = struct {
                host: *hosts.Host,
                binding: sessions.ServiceHandle,
                key: sessions.OperationKey,
                cp: *engine_mod.OwnedCheckpoint,
                spec: transfer.JobSpec,
                fn accept(raw: *anyopaque) !transfer.EngineJobId {
                    const self: *@This() = @ptrCast(@alignCast(raw));
                    return self.host.importPaused(self.binding, self.key, self.cp, self.spec);
                }
            };
            var import: Import = .{ .host = &host, .binding = current_binding, .key = current_key, .cp = &checkpoint.?, .spec = spec };
            try manager.validateRetainedResume(job, attempt, spec);
            const proxy = try mux.importPaused(current_binding, &import, Import.accept);
            try manager.acceptRetainedResume(job, attempt, spec, proxy);
            try checkpoint.?.deinit();
            checkpoint = null;
        }
        const entered = try std.fmt.allocPrint(a, "{s}.read-entered", .{label});
        defer a.free(entered);
        const release = try std.fmt.allocPrint(a, "{s}.read-release", .{label});
        defer a.free(release);
        defer fixture.signal(release) catch {};
        try fixture.wait(entered);
        try manager.pause(job);
        try fixture.signal(release);
        while (manager.progress(job).?.state != .paused or manager.progress(job).?.job_cleanup != .released) {
            manager.tick(0);
            if (clock.monotonicNs() >= deadline) return error.NativeFaultPauseTimeout;
            pause();
        }
        const paused = manager.progress(job).?;
        try std.testing.expect(paused.done_bytes > 0 and paused.done_bytes < 2 * 1024 * 1024 + 17);
        const proxy = manager.engineJob(job).?;
        const native = try mux.pausedNativeId(proxy, current_binding);
        const temp = (try host.entries.items[0].backend.backend.retainedTemp(a, native)).?;
        defer a.free(temp);
        const before = try std.Io.Dir.cwd().statFile(io, temp, .{});
        const fin = try std.fmt.allocPrint(a, "{s}.fin", .{label});
        defer a.free(fin);
        const sent = try std.fmt.allocPrint(a, "{s}.fin-sent", .{label});
        defer a.free(sent);
        try fixture.signal(fin);
        try fixture.wait(sent);
        var fault: hosts.FaultSnapshot = while (true) {
            _ = try host.safeTick();
            if (host.fault(current_binding, current_key)) |value| break value;
            if (clock.monotonicNs() >= deadline) return error.NativeFaultNotPublished;
            pause();
        };
        try std.testing.expect(fault.binding.eql(current_binding) and fault.key.eql(current_key) and fault.owner.eql(accepted.handle));
        try std.testing.expectEqual(.transport, fault.failure.domain);
        try std.testing.expectEqualStrings("TransferTransportClosed", fault.failure.code);
        try std.testing.expect(!domain.bindingIsLive(current_binding));
        try std.testing.expect(!manager.canResume(job));
        try std.testing.expectEqual(paused.attempt, manager.progress(job).?.attempt);
        const after = try std.Io.Dir.cwd().statFile(io, temp, .{});
        try std.testing.expectEqual(before.inode, after.inode);
        try std.testing.expectEqual(before.size, after.size);
        const retained = try domain.retainFaultTransferSource(current_binding, current_key);
        if (retained_owner) |previous| try std.testing.expectEqual(previous, retained) else retained_owner = retained;
        var wrong = current_key;
        wrong.operation_id += 1000;
        try std.testing.expect(host.fault(current_binding, wrong) == null);
        try std.testing.expectError(error.StaleTransferFault, host.retainFault(current_binding, wrong, retained, &.{}));
        const jobs = [_]hosts.RetainJob{.{ .job_id = job, .attempt = paused.attempt, .proxy_id = proxy, .native_id = native }};
        gated.close_entered.store(false, .release);
        gated.receipt.store(@backingInt(files.readonly.ReleaseReceipt.awaiting), .release);
        try std.testing.expectEqual(.awaiting, try host.retainFault(current_binding, current_key, retained, &jobs));
        while (!gated.close_entered.load(.acquire)) {
            if (clock.monotonicNs() >= deadline) return error.NativeFaultCloseNotEntered;
            pause();
        }
        try std.testing.expect((try host.takeFaultRetained(current_binding, current_key)) == null);
        try std.testing.expectError(error.Busy, host.deinit());
        gated.receipt.store(@backingInt(files.readonly.ReleaseReceipt.unknown), .release);
        while (host.entries.items[0].backend.closeReceipt() != .unknown) {
            if (clock.monotonicNs() >= deadline) return error.NativeFaultUnknownNotPublished;
            pause();
        }
        _ = try host.safeTick();
        try std.testing.expectEqual(.unknown, try host.retainFault(current_binding, current_key, retained, &jobs));
        try std.testing.expect((try host.takeFaultRetained(current_binding, current_key)) == null);
        try std.testing.expectError(error.CleanupNotReleased, domain.beginRetainedTransfer(retained, accepted.handle));
        const held = try std.Io.Dir.cwd().statFile(io, temp, .{});
        try std.testing.expectEqual(before.inode, held.inode);
        try std.testing.expectEqual(before.size, held.size);
        gated.receipt.store(@backingInt(files.readonly.ReleaseReceipt.released), .release);
        while (try host.retainFault(current_binding, current_key, retained, &jobs) != .released) {
            _ = try host.safeTick();
            if (clock.monotonicNs() >= deadline) return error.NativeFaultRetainTimeout;
            pause();
        }
        var batch = (try host.takeFaultRetained(current_binding, current_key)).?;
        try std.testing.expect(batch.binding.eql(current_binding) and batch.close_key.eql(current_key));
        checkpoint = try batch.takeCheckpoint(0);
        try batch.deinit();
        const info = checkpoint.?.describe().?;
        try std.testing.expectEqual(job, info.spec.conflict_context.?.job);
        try std.testing.expectEqual(paused.attempt, info.spec.conflict_context.?.attempt);
        try std.testing.expectEqual(paused.done_bytes, info.done_bytes);
        try std.testing.expectEqualStrings(temp, info.temp_path.?);
        try std.testing.expect((try host.takeFaultRetained(current_binding, current_key)) == null);
        try mux.retireExportedPaused(proxy, current_binding, native);
        try manager.retainPaused(job, paused.attempt, proxy, .{ .id = retained, .original_handle = accepted.handle });
        while (try host.safeTick()) {
            if (clock.monotonicNs() >= deadline) return error.NativeFaultCollectTimeout;
            pause();
        }
        try std.testing.expectEqual(.attached, domain.queryState(accepted.handle).?.lifecycle);
        try std.testing.expect(!domain.bindingIsLive(current_binding));
        if (round == 0) {
            const next = try domain.beginRetainedTransfer(retained, accepted.handle);
            current_binding = next.binding;
            current_key = next.key;
        }
        fault.cleanup = .released;
        std.debug.print("TRANSFER_FAULT_NATIVE kind={s} job={d} attempt={d} bytes={d} checkpoint_preserved=true released=true original_session_attached=true\n", .{ if (round == 0) "auxiliary" else "retained", job, paused.attempt, paused.done_bytes });
    }
    const Cancel = struct {
        fn run(cp: *engine_mod.OwnedCheckpoint) void {
            std.debug.assert(cp.cancel(std.testing.io) == .released);
        }
    };
    const cleanup = try std.Thread.spawn(.{}, Cancel.run, .{&checkpoint.?});
    cleanup.join();
    try checkpoint.?.deinit();
    checkpoint = null;
    const ended = manager.progress(job).?;
    try manager.retainedCancelReceipt(job, ended.attempt, manager.retainedOwner(job).?, .released);
}
