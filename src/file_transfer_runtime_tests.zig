const std = @import("std");
const runtime = @import("host/file_transfer_runtime.zig");
const sessions = @import("host/session_host.zig");
const plugins = @import("host/plugin_registry.zig");
const files = @import("host/file_binding_host.zig");
const factory_mod = @import("host/file_route_factory.zig");
const ssh = @import("proto/ssh/session.zig");
const clock = @import("platform/realtime.zig");
const transfer = @import("transfer/manager.zig");
const sftp = @import("transfer/sftp_engine.zig");

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
        return .{ .registration = .{ .plugin_id = .sftp, .workspace_kind = .file, .services = plugins.requiredServices(.sftp) }, .context = self, .vtable = &.{ .create = create, .cancel = cancel, .close = close, .release_stale = stale } };
    }
};
fn spec(password: []const u8) sessions.SessionCreateSpec {
    return .{ .saved = .{ .connection_id = @fromBackingInt(19), .config_revision = 4, .protocol = .sftp, .immutable_config = .{ .endpoint = .{ .host = "192.0.2.10", .user = "root" }, .auth = .{ .password = password } } } };
}
fn pause() void {
    var unused: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&unused, 0, 2);
}
fn awaitPhase(value: *runtime.Runtime, phase: runtime.Phase) !void {
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (value.state() != phase) {
        if (clock.monotonicNs() >= deadline) return error.RuntimePhaseTimeout;
        pause();
    }
}
fn dispose(value: *runtime.Runtime) void {
    value.requestClose();
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (true) {
        value.deinit() catch {
            if (clock.monotonicNs() >= deadline) @panic("transfer runtime retained IO during test cleanup");
            pause();
            continue;
        };
        return;
    }
}
const Gate = struct {
    caller: std.Thread.Id,
    close_entered: std.atomic.Value(bool) = .init(false),
    destroyed: std.atomic.Value(bool) = .init(false),
    receipt: std.atomic.Value(u8) = .init(@backingInt(files.readonly.ReleaseReceipt.awaiting)),
    fn connect(raw: *anyopaque, _: *const std.atomic.Value(bool)) !ssh.Session {
        const self: *Gate = @ptrCast(@alignCast(raw));
        std.debug.assert(self.caller != std.Thread.getCurrentId());
        return error.ControlledConnectFailure;
    }
    fn close(raw: *anyopaque, value: ?*ssh.Session) files.readonly.ReleaseReceipt {
        const self: *Gate = @ptrCast(@alignCast(raw));
        std.debug.assert(self.caller != std.Thread.getCurrentId() and value == null);
        self.close_entered.store(true, .release);
        return @fromBackingInt(@intCast(self.receipt.load(.acquire)));
    }
    fn destroy(raw: *anyopaque) void {
        const self: *Gate = @ptrCast(@alignCast(raw));
        std.debug.assert(self.caller != std.Thread.getCurrentId());
        self.destroyed.store(true, .release);
    }
};

test "file transfer runtime retains failed connector until actual cleanup releases" {
    var adapter: Adapter = .{};
    var domain = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.interface()});
    defer domain.deinit();
    const accepted = try domain.create(spec("unused"), .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) });
    const binding = try domain.reserveService(accepted.handle, accepted.operation, .transfer);
    const key = try domain.journal.begin(.{ .session = accepted.handle }, 1);
    var gate: Gate = .{ .caller = std.Thread.getCurrentId() };
    const connector: files.readonly.Connector = .{ .key = key, .ctx = &gate, .connect_fn = Gate.connect, .close_fn = Gate.close, .deinit_fn = Gate.destroy };
    var foreign = binding;
    foreign.binding_generation += 1;
    try std.testing.expectError(error.TransferOwnerMismatch, runtime.Runtime.start(std.testing.allocator, foreign, connector));
    try std.testing.expect(!gate.close_entered.load(.acquire));
    const value = try runtime.Runtime.start(std.testing.allocator, binding, connector);
    defer {
        gate.receipt.store(@backingInt(files.readonly.ReleaseReceipt.released), .release);
        dispose(value);
    }
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (!gate.close_entered.load(.acquire)) {
        if (clock.monotonicNs() >= deadline) return error.CloseNotEntered;
        pause();
    }
    try std.testing.expectEqual(error.ControlledConnectFailure, value.failureReason().?);
    try std.testing.expectError(error.Busy, value.deinit());
    const engine = value.engine();
    try std.testing.expectError(error.TransferNotReady, engine.open(engine.ctx, .{ .transfer_binding = binding, .direction = .download, .sources = &.{"/etc/os-release"}, .remote_dir = "/etc", .local_dir = "/tmp" }));
    gate.receipt.store(@backingInt(files.readonly.ReleaseReceipt.unknown), .release);
    try awaitPhase(value, .cleanup_unknown);
    const conflict_engine = value.engine();
    try std.testing.expectError(error.TransferNotReady, conflict_engine.conflict_snapshot.?(conflict_engine.ctx, std.testing.allocator, 1));
    const decision: @import("transfer/manager.zig").Conflict.Request = .{ .select = .{
        .key = .{ .intent_id = 1, .owner = binding.resource_owner, .original_owner = accepted.handle, .entry = 0, .job = 1, .attempt = 1, .revision = 1 },
        .selection = .{ .choice = .skip },
    } };
    try std.testing.expectError(error.TransferNotReady, conflict_engine.resolve_conflict.?(conflict_engine.ctx, 1, decision));
    const guard = value.cleanupGuard();
    try std.testing.expectEqual(.unknown, guard.receipt(guard.context, binding));
    try std.testing.expectError(error.Busy, value.deinit());
    try std.testing.expect(!gate.destroyed.load(.acquire));
    gate.receipt.store(@backingInt(files.readonly.ReleaseReceipt.released), .release);
    try awaitPhase(value, .closed);
    try std.testing.expectEqual(.released, value.closeReceipt());
    try std.testing.expect(gate.destroyed.load(.acquire));
    try std.testing.expectEqual(.unknown, guard.receipt(guard.context, foreign));
    try std.testing.expect(domain.queryService(accepted.handle, .transfer) == .temporarily_unavailable);
}

test "file transfer runtime auxiliary accepts independent generation only through the typed start" {
    const owner: sessions.SessionHandle = .{ .session_id = @fromBackingInt(91), .generation = 7 };
    const binding: sessions.ServiceHandle = .{ .resource_owner = .{ .session = owner }, .origin_session = owner, .kind = .transfer, .binding_id = 45, .binding_generation = 2 };
    const key: sessions.OperationKey = .{ .owner = .{ .session = owner }, .operation_id = 72, .attempt_id = 1 };
    var gate: Gate = .{ .caller = std.Thread.getCurrentId() };
    const connector: files.readonly.Connector = .{ .key = key, .ctx = &gate, .connect_fn = Gate.connect, .close_fn = Gate.close, .deinit_fn = Gate.destroy };
    try std.testing.expectError(error.TransferOwnerMismatch, runtime.Runtime.start(std.testing.allocator, binding, connector));
    var bad = binding;
    bad.origin_session.?.generation += 1;
    try std.testing.expectError(error.TransferOwnerMismatch, runtime.Runtime.startAuxiliary(std.testing.allocator, bad, connector));
    bad = binding;
    bad.origin_session = null;
    try std.testing.expectError(error.TransferOwnerMismatch, runtime.Runtime.startAuxiliary(std.testing.allocator, bad, connector));
    var wrong_key = connector;
    wrong_key.key.attempt_id = null;
    try std.testing.expectError(error.TransferOwnerMismatch, runtime.Runtime.startAuxiliary(std.testing.allocator, binding, wrong_key));
    try std.testing.expect(!gate.close_entered.load(.acquire));
    const value = try runtime.Runtime.startAuxiliary(std.testing.allocator, binding, connector);
    defer {
        gate.receipt.store(@backingInt(files.readonly.ReleaseReceipt.released), .release);
        dispose(value);
    }
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (!gate.close_entered.load(.acquire)) {
        if (clock.monotonicNs() >= deadline) return error.CloseNotEntered;
        pause();
    }
    try std.testing.expect(value.auxiliary);
    try std.testing.expect(value.binding.eql(binding) and value.connector.key.eql(key));
    try std.testing.expectEqual(error.ControlledConnectFailure, value.failureReason().?);
}

test "file transfer runtime retained owner validates new operation without dereferencing original session union" {
    const original: sessions.SessionHandle = .{ .session_id = @fromBackingInt(91), .generation = 7 };
    const id: @import("host/identity.zig").RetainedTransferOwnerId = @fromBackingInt(13);
    const binding: sessions.ServiceHandle = .{ .resource_owner = .{ .retained_transfer = id }, .origin_session = original, .kind = .transfer, .binding_id = 45, .binding_generation = 2 };
    const key: sessions.OperationKey = .{ .owner = .{ .transfer_owner = .{ .id = id, .original_handle = original } }, .operation_id = 72, .attempt_id = 2 };
    var gate: Gate = .{ .caller = std.Thread.getCurrentId() };
    var connector: files.readonly.Connector = .{ .key = key, .ctx = &gate, .connect_fn = Gate.connect, .close_fn = Gate.close, .deinit_fn = Gate.destroy };
    var bad = binding;
    bad.origin_session.?.generation += 1;
    try std.testing.expectError(error.TransferOwnerMismatch, runtime.Runtime.start(std.testing.allocator, bad, connector));
    bad = binding;
    bad.resource_owner.retained_transfer = @fromBackingInt(14);
    try std.testing.expectError(error.TransferOwnerMismatch, runtime.Runtime.start(std.testing.allocator, bad, connector));
    connector.key.attempt_id = connector.key.attempt_id.? + 1;
    try std.testing.expectError(error.TransferOwnerMismatch, runtime.Runtime.start(std.testing.allocator, binding, connector));
    try std.testing.expect(!gate.close_entered.load(.acquire));
    connector.key = key;
    const value = try runtime.Runtime.start(std.testing.allocator, binding, connector);
    defer {
        gate.receipt.store(@backingInt(files.readonly.ReleaseReceipt.released), .release);
        dispose(value);
    }
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (!gate.close_entered.load(.acquire)) {
        if (clock.monotonicNs() >= deadline) return error.CloseNotEntered;
        pause();
    }
    try std.testing.expectEqual(error.ControlledConnectFailure, value.failureReason().?);
    var checkpoint: @import("transfer/sftp_engine.zig").OwnedCheckpoint = .{};
    try std.testing.expectError(error.TransferNotReady, value.importPaused(&checkpoint, .{ .transfer_binding = binding, .session_id = @backingInt(original.session_id), .direction = .download, .sources = &.{"/readonly"}, .remote_dir = "/", .local_dir = "/tmp" }));
    try std.testing.expectError(error.Busy, value.deinit());
}

test "file transfer runtime empty retained batch waits for actual close and moves once without implicit destruction" {
    const owner: sessions.SessionHandle = .{ .session_id = @fromBackingInt(92), .generation = 3 };
    const binding: sessions.ServiceHandle = .{ .resource_owner = .{ .session = owner }, .origin_session = owner, .kind = .transfer, .binding_id = 46, .binding_generation = owner.generation };
    const key: sessions.OperationKey = .{ .owner = .{ .session = owner }, .operation_id = 73, .attempt_id = 1 };
    const close_key: sessions.OperationKey = .{ .owner = .{ .session = owner }, .operation_id = 74, .attempt_id = 1 };
    var gate: Gate = .{ .caller = std.Thread.getCurrentId() };
    const value = try runtime.Runtime.start(std.testing.allocator, binding, .{ .key = key, .ctx = &gate, .connect_fn = Gate.connect, .close_fn = Gate.close, .deinit_fn = Gate.destroy });
    defer {
        gate.receipt.store(@backingInt(files.readonly.ReleaseReceipt.released), .release);
        value.requestRetainedCancel() catch unreachable;
        dispose(value);
    }
    try value.requestRetain(owner, close_key, @fromBackingInt(3), &.{});
    try std.testing.expect((try value.takeRetained()) == null);
    try std.testing.expectError(error.RetainAlreadyRequested, value.requestRetain(owner, close_key, @fromBackingInt(4), &.{}));
    gate.receipt.store(@backingInt(files.readonly.ReleaseReceipt.unknown), .release);
    try awaitPhase(value, .cleanup_unknown);
    try std.testing.expect((try value.takeRetained()) == null);
    try std.testing.expectError(error.Busy, value.deinit());
    gate.receipt.store(@backingInt(files.readonly.ReleaseReceipt.released), .release);
    try awaitPhase(value, .closed);
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    var batch: runtime.OwnedRetainedBatch = while (true) {
        if (try value.takeRetained()) |result| break result;
        if (clock.monotonicNs() >= deadline) return error.RetainedBatchTimeout;
        pause();
    };
    defer batch.deinit() catch unreachable;
    try std.testing.expectEqual(@as(usize, 0), batch.jobs.len);
    try std.testing.expect(batch.owner.eql(owner) and batch.close_key.eql(close_key) and batch.binding.eql(binding));
    try std.testing.expect((try value.takeRetained()) == null);
}

const FreshPeer = struct {
    const OpenRead = @FieldType(@FieldType(sftp.SftpEngine, "remote_files"), "open_read");
    const Purpose = @typeInfo(@typeInfo(OpenRead).pointer.child).@"fn".param_types[3].?;
    const bytes = "fresh retained queued draft\n";
    caller: std.Thread.Id,
    session: *ssh.Session,
    offset: usize = 0,
    active: bool = false,
    metadata_calls: usize = 0,
    prefix_opens: usize = 0,
    source_opens: usize = 0,
    fn check(self: *FreshPeer) void {
        std.debug.assert(self.caller != std.Thread.getCurrentId());
    }
    fn of(raw: ?*anyopaque) *FreshPeer {
        return @ptrCast(@alignCast(raw.?));
    }
    fn attributes() ssh.SftpAttributes {
        return .{ .kind = .file, .size = bytes.len, .modified_at = 1_700_000_000 };
    }
    fn size(raw: ?*anyopaque, session: *ssh.Session, path: [:0]const u8) !u64 {
        const self = of(raw);
        self.check();
        std.debug.assert(session == self.session and std.mem.eql(u8, path, "/readonly/a"));
        self.metadata_calls += 1;
        return bytes.len;
    }
    fn stat(raw: ?*anyopaque, session: *ssh.Session, path: [:0]const u8) !ssh.SftpAttributes {
        const self = of(raw);
        self.check();
        std.debug.assert(session == self.session and std.mem.eql(u8, path, "/readonly/a"));
        return attributes();
    }
    fn openRead(raw: ?*anyopaque, session: *ssh.Session, path: [:0]const u8, purpose: Purpose) !ssh.SftpHandle {
        const self = of(raw);
        self.check();
        std.debug.assert(session == self.session and std.mem.eql(u8, path, "/readonly/a") and !self.active);
        self.active = true;
        self.offset = 0;
        self.source_opens += 1;
        if (purpose == .prefix) self.prefix_opens += 1;
        return .{ .handle = @ptrCast(self) };
    }
    fn statHandle(raw: ?*anyopaque, session: *ssh.Session, _: *ssh.SftpHandle) !ssh.SftpAttributes {
        const self = of(raw);
        self.check();
        std.debug.assert(session == self.session and self.active);
        return attributes();
    }
    fn read(raw: ?*anyopaque, _: *ssh.SftpHandle, buffer: []u8) !usize {
        const self = of(raw);
        self.check();
        const count = @min(buffer.len, bytes.len - self.offset);
        @memcpy(buffer[0..count], bytes[self.offset..][0..count]);
        self.offset += count;
        return count;
    }
    fn close(raw: ?*anyopaque, _: *ssh.SftpHandle) ssh.SftpCloseResult {
        const self = of(raw);
        self.check();
        std.debug.assert(self.active);
        self.active = false;
        return .{ .consumed = true, .receipt = .released };
    }
    fn release(raw: ?*anyopaque, _: *ssh.Session) ssh.ReleaseReceipt {
        of(raw).check();
        return .released;
    }
};

test "file transfer runtime retained queued draft rejects changed frozen inputs before accept then completes fresh preflight" {
    const owner: sessions.SessionHandle = .{ .session_id = @fromBackingInt(94), .generation = 3 };
    const original_binding: sessions.ServiceHandle = .{ .resource_owner = .{ .session = owner }, .origin_session = owner, .kind = .transfer, .binding_id = 53, .binding_generation = 2 };
    const binding: sessions.ServiceHandle = .{ .resource_owner = .{ .retained_transfer = @fromBackingInt(19) }, .origin_session = owner, .kind = .transfer, .binding_id = 63, .binding_generation = 2 };
    const original: transfer.JobSpec = .{ .session_id = @backingInt(owner.session_id), .transfer_binding = original_binding, .direction = .download, .sources = &.{"a"}, .remote_dir = "/readonly", .local_dir = "", .md5_check = true, .notify_complete = false, .conflict_context = .{ .intent_id = 8, .original_owner = owner, .resource_owner = original_binding.resource_owner, .source_endpoint = .{ .sftp = .{ .binding_id = 51, .binding_generation = owner.generation, .resource_owner = original_binding.resource_owner, .origin_session = owner, .connection_snapshot_id = 55 } }, .target_endpoint = .{ .local_fs = .{ .binding_id = 991, .binding_generation = 4 } } } };
    var local = std.testing.tmpDir(.{});
    defer local.cleanup();
    try local.dir.writeFile(std.testing.io, .{ .sub_path = "a.part", .data = "stranger partial must remain" });
    const path = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var draft: runtime.RetainedDraft = .{ .original = original, .job_id = 12, .attempt = 0, .next = original };
    draft.original.local_dir = path;
    draft.next.local_dir = path;
    draft.next.transfer_binding = binding;
    draft.next.conflict_context.?.resource_owner = binding.resource_owner;
    draft.next.conflict_context.?.job = draft.job_id;
    draft.next.conflict_context.?.attempt = 1;
    draft.next.conflict_context.?.source_endpoint.sftp.binding_id = binding.binding_id;
    draft.next.conflict_context.?.source_endpoint.sftp.binding_generation = binding.binding_generation;
    draft.next.conflict_context.?.source_endpoint.sftp.resource_owner = binding.resource_owner;
    const backend = try sftp.SftpEngine.init(std.testing.allocator);
    defer backend.deinit();
    var session: ssh.Session = .{};
    backend.attachSession(&session);
    var peer: FreshPeer = .{ .caller = std.Thread.getCurrentId(), .session = &session };
    backend.remote_metadata = .{ .context = &peer, .size = FreshPeer.size, .stat = FreshPeer.stat };
    backend.remote_files = .{ .context = &peer, .open_read = FreshPeer.openRead, .stat_handle = FreshPeer.statHandle, .read = FreshPeer.read, .close = FreshPeer.close, .release = FreshPeer.release };
    var gate: Gate = .{ .caller = std.Thread.getCurrentId() };
    var value: runtime.Runtime = .{ .allocator = std.testing.allocator, .binding = binding, .backend = backend, .phase = .init(.ready), .connector = .{ .key = .{ .owner = .{ .transfer_owner = .{ .id = binding.resource_owner.retained_transfer, .original_handle = owner } }, .operation_id = 91, .attempt_id = binding.binding_generation }, .ctx = &gate, .connect_fn = Gate.connect, .close_fn = Gate.close, .deinit_fn = Gate.destroy } };
    const Mutation = enum { path, source, direction, rename, resume_option, md5, notification, chunk, window, pacing, attempt, old_attempt, next_attempt, binding, owner, original_owner, job, intent, endpoint, snapshot };
    for (std.enums.values(Mutation)) |mutation| {
        var changed = draft;
        const expected: anyerror = switch (mutation) {
            .path => blk: {
                changed.next.local_dir = "/mutated";
                break :blk error.RetainedDraftSourceChanged;
            },
            .source => blk: {
                changed.next.sources = &.{"b"};
                break :blk error.RetainedDraftSourceChanged;
            },
            .direction => blk: {
                changed.next.direction = .upload;
                break :blk error.RetainedDraftSourceChanged;
            },
            .rename => blk: {
                changed.next.rename = "renamed";
                break :blk error.RetainedDraftSourceChanged;
            },
            .resume_option => blk: {
                changed.next.resume_transfer = false;
                break :blk error.RetainedDraftSourceChanged;
            },
            .md5 => blk: {
                changed.next.md5_check = false;
                break :blk error.RetainedDraftSourceChanged;
            },
            .notification => blk: {
                changed.next.notify_complete = true;
                break :blk error.RetainedDraftSourceChanged;
            },
            .chunk => blk: {
                changed.next.chunk_kb += 1;
                break :blk error.RetainedDraftSourceChanged;
            },
            .window => blk: {
                changed.next.window_chunks += 1;
                break :blk error.RetainedDraftSourceChanged;
            },
            .pacing => blk: {
                changed.next.pacing_kbps = 2048;
                break :blk error.RetainedDraftSourceChanged;
            },
            .attempt => blk: {
                changed.attempt = 1;
                break :blk error.InvalidRetainedDraftAttempt;
            },
            .old_attempt => blk: {
                changed.original.conflict_context.?.attempt = 1;
                break :blk error.InvalidRetainedDraftAttempt;
            },
            .next_attempt => blk: {
                changed.next.conflict_context.?.attempt = 2;
                break :blk error.RetainedDraftIdentityMismatch;
            },
            .binding => blk: {
                changed.next.transfer_binding.?.binding_generation += 1;
                break :blk error.TransferOwnerMismatch;
            },
            .owner => blk: {
                changed.next.conflict_context.?.resource_owner.retained_transfer = @fromBackingInt(20);
                break :blk error.RetainedDraftOwnerMismatch;
            },
            .original_owner => blk: {
                changed.original.conflict_context.?.original_owner.generation += 1;
                break :blk error.RetainedDraftOwnerMismatch;
            },
            .job => blk: {
                changed.next.conflict_context.?.job += 1;
                break :blk error.RetainedDraftIdentityMismatch;
            },
            .intent => blk: {
                changed.next.conflict_context.?.intent_id += 1;
                break :blk error.RetainedDraftIdentityMismatch;
            },
            .endpoint => blk: {
                changed.next.conflict_context.?.source_endpoint.sftp.binding_id += 1;
                break :blk error.RetainedDraftEndpointMismatch;
            },
            .snapshot => blk: {
                changed.next.conflict_context.?.source_endpoint.sftp.connection_snapshot_id = 56;
                break :blk error.RetainedDraftEndpointMismatch;
            },
        };
        try std.testing.expectError(expected, value.startRetainedDraft(changed));
        try std.testing.expectEqual(@as(usize, 0), backend.jobs.items.len);
        try std.testing.expectEqual(@as(usize, 0), peer.metadata_calls);
    }
    const generic = value.engine();
    try std.testing.expectError(error.RetainedImportRequired, generic.open(generic.ctx, draft.next));
    const id = try value.startRetainedDraft(draft);
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (!backend.owner_done.load(.acquire)) {
        if (clock.monotonicNs() >= deadline) return error.FreshPreflightTimeout;
        pause();
    }
    const event = backend.poll().?;
    try std.testing.expectEqual(id, event.job);
    try std.testing.expectEqual(transfer.EngineState.succeeded, event.state);
    try std.testing.expectEqual(transfer.JobCleanup.released, event.job_cleanup);
    try std.testing.expectEqual(.passed, event.verification.?.state);
    try std.testing.expectEqual(@as(usize, 1), peer.metadata_calls);
    try std.testing.expect(peer.source_opens >= 3 and peer.prefix_opens == 0 and !peer.active);
    const bytes = try local.dir.readFileAlloc(std.testing.io, "a", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(FreshPeer.bytes, bytes);
    const stranger = try local.dir.readFileAlloc(std.testing.io, "a.part", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(stranger);
    try std.testing.expectEqualStrings("stranger partial must remain", stranger);
}

test "file transfer runtime optional VM prepares real SFTP before ready then downloads and closes" {
    const raw = std.c.getenv("ZEROWORK_VM_PASSWORD") orelse return error.SkipZigTest;
    var adapter: Adapter = .{};
    var domain = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.interface()});
    defer domain.deinit();
    const source_spec = spec(std.mem.span(raw));
    const accepted = try domain.create(source_spec, .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) });
    const binding = try domain.reserveService(accepted.handle, accepted.operation, .transfer);
    const key = try domain.journal.begin(.{ .session = accepted.handle }, 1);
    var library = try ssh.Library.init();
    defer library.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const trust_path = try std.fs.path.join(std.testing.allocator, &.{ directory, "known_hosts" });
    defer std.testing.allocator.free(trust_path);
    var factory: factory_mod.SourceFactory = .{ .library = &library, .known_hosts_path = trust_path, .timeout_ms = 5000 };
    // This controlled test uses trust_once; it never mutates the user's store.
    const Trust = struct {
        fn observe(_: *anyopaque, _: []const u8, _: u16, _: ssh.HostKeyInfo) ssh.HostKeyDecision {
            return .trust_once;
        }
    };
    factory.host_key_observer = .{ .ctx = &adapter, .callback = Trust.observe };
    const api = factory.interface();
    const connector = try api.prepare(api.context, .{ .owner = accepted.handle, .create_key = accepted.operation, .open_key = key, .spec = source_spec });
    const value = runtime.Runtime.start(std.testing.allocator, binding, connector) catch |err| {
        api.discard(api.context, connector);
        return err;
    };
    defer dispose(value);
    try awaitPhase(value, .ready);
    try std.testing.expect(domain.bindingIsPreparing(binding, accepted.operation));
    try std.testing.expect(domain.queryService(accepted.handle, .transfer) == .temporarily_unavailable);
    try std.testing.expect(try domain.ready(accepted.handle, accepted.operation, plugins.requiredServices(.sftp)));
    try std.testing.expect(domain.queryService(accepted.handle, .transfer).available.eql(binding));
    const engine = value.engine();
    const id = try engine.open(engine.ctx, .{ .transfer_binding = binding, .direction = .download, .sources = &.{"/etc/os-release"}, .remote_dir = "/etc", .local_dir = directory });
    const deadline = clock.monotonicNs() + 10 * std.time.ns_per_s;
    var succeeded = false;
    while (!succeeded) {
        if (clock.monotonicNs() >= deadline) return error.DownloadTimeout;
        if (engine.poll(engine.ctx)) |event| {
            try std.testing.expectEqual(id, event.job);
            if (event.state == .failed) return error.DownloadFailed;
            succeeded = event.state == .succeeded;
        }
        pause();
    }
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "os-release", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.startsWith(u8, bytes, "NAME="));
    value.requestClose();
    try awaitPhase(value, .closed);
    try std.testing.expectEqual(.released, value.closeReceipt());
    std.debug.print("FILE_TRANSFER_RUNTIME_VM_PASS bytes={d} sftp_ready_before_domain=true shell=false cleanup=released\n", .{bytes.len});
}
