//! Real Manager/Mux/Dispatch/SessionHost with controlled engine progress and
//! synthetic checkpoint metadata. OwnedCheckpoint cancellation uses real local
//! tmp files; no SSH, SFTP or user VM is contacted by these tests.
const std = @import("std");
const module = @import("host/retained_transfer_store.zig");
const transfer = @import("transfer/manager.zig");
const routing = @import("transfer/engine_mux.zig");
const dispatching = @import("transfer/engine_dispatch.zig");
const sessions = @import("host/session_host.zig");
const plugins = @import("host/plugin_registry.zig");
const identity = @import("host/identity.zig");
const operations = @import("host/operation.zig");
const clock = @import("platform/realtime.zig");
const a = std.testing.allocator;

test "retained store separates original shared and dedicated bindings under one session close" {
    var f: Fixture = undefined;
    try f.init(0);
    defer f.stop();
    const shared = try f.store.prepareBinding(f.owner, f.close_key, f.retained_id, 0, f.binding);
    try std.testing.expect(shared == try f.store.prepareBinding(f.owner, f.close_key, f.retained_id, 0, f.binding));
    var other = f.binding;
    other.binding_id += 1;
    const second = try f.store.prepareBinding(f.owner, f.close_key, f.retained_id, 0, other);
    const dedicated = try f.store.prepare(f.owner, f.close_key, f.retained_id, 0);
    try std.testing.expect(shared != second and shared != dedicated and second != dedicated);
    try std.testing.expectEqual(@as(usize, 3), f.store.batches.items.len);
    try std.testing.expect(shared.source_binding.?.eql(f.binding));
    try std.testing.expect(second.source_binding.?.eql(other));
    try std.testing.expect(dedicated.source_binding == null);
    try std.testing.expectError(error.RetainedBatchChanged, f.store.prepareBinding(f.owner, f.close_key, f.retained_id, 1, f.binding));
}
const Adapter = struct {
    fn create(_: *anyopaque, _: sessions.CreateRequest) !void {}
    fn cancel(_: *anyopaque, _: operations.OperationKey) sessions.CloseReceipt {
        return .released;
    }
    fn close(_: *anyopaque, _: identity.SessionHandle, _: operations.OperationKey) !sessions.CloseReceipt {
        return .released;
    }
    fn stale(_: *anyopaque, _: identity.SessionHandle, _: operations.OperationKey) void {}
    fn interface(self: *Adapter) sessions.Adapter {
        return .{ .registration = .{ .plugin_id = .sftp, .workspace_kind = .file, .services = plugins.requiredServices(.sftp) }, .context = self, .vtable = &.{ .create = create, .cancel = cancel, .close = close, .release_stale = stale } };
    }
    fn sshInterface(self: *Adapter) sessions.Adapter {
        return .{ .registration = .{ .plugin_id = .ssh, .workspace_kind = .terminal, .services = plugins.requiredServices(.ssh) }, .context = self, .vtable = &.{ .create = create, .cancel = cancel, .close = close, .release_stale = stale } };
    }
};
const Backend = struct {
    next: u64 = 1,
    specs: std.ArrayList(transfer.JobSpec) = .empty,
    events: std.ArrayList(transfer.EngineProgress) = .empty,
    cleanup: routing.ReleaseReceipt = .released,
    inject_dispatch_fault: ?*dispatching.Dispatch = null,
    fn interface(self: *Backend) transfer.TransferEngine {
        return .{ .ctx = self, .open = open, .cancel = cancel, .pause = pauseJob, .poll = poll };
    }
    fn open(raw: *anyopaque, spec: transfer.JobSpec) !u64 {
        const self: *Backend = @ptrCast(@alignCast(raw));
        try self.specs.append(a, spec);
        defer self.next += 1;
        return self.next;
    }
    fn cancel(raw: *anyopaque, id: u64) void {
        const self: *Backend = @ptrCast(@alignCast(raw));
        self.push(id, .cancelled) catch unreachable;
    }
    fn pauseJob(_: *anyopaque, _: u64) !void {}
    fn push(self: *Backend, id: u64, state: transfer.EngineState) !void {
        try self.events.append(a, .{ .job = id, .state = state, .done_bytes = 0, .total_bytes = 100, .job_cleanup = if (state == .running) .awaiting else .released });
    }
    fn poll(raw: *anyopaque) ?transfer.EngineProgress {
        const self: *Backend = @ptrCast(@alignCast(raw));
        return if (self.events.items.len == 0) null else self.events.orderedRemove(0);
    }
    fn receipt(raw: *anyopaque, _: sessions.ServiceHandle) routing.ReleaseReceipt {
        const self: *Backend = @ptrCast(@alignCast(raw));
        if (self.inject_dispatch_fault) |dispatch| {
            dispatch.protocol_fault[1] = true;
            self.inject_dispatch_fault = null;
        }
        return self.cleanup;
    }
    fn deinit(self: *Backend) void {
        self.specs.deinit(a);
        self.events.deinit(a);
    }
};
fn live(raw: *anyopaque, binding: sessions.ServiceHandle) bool {
    const host: *sessions.SessionHost = @ptrCast(@alignCast(raw));
    return host.bindingIsLive(binding);
}
const Fixture = struct {
    adapter: Adapter,
    domain: sessions.SessionHost,
    owner: identity.SessionHandle,
    binding: sessions.ServiceHandle,
    close_key: operations.OperationKey,
    retained_id: identity.RetainedTransferOwnerId,
    mux: routing.Mux,
    dispatch: dispatching.Dispatch,
    manager: transfer.Manager,
    backend: Backend,
    legacy: Backend,
    store: module.Store,
    tmp: std.testing.TmpDir,
    directory: [:0]u8,
    fn init(self: *Fixture, count: usize) !void {
        try self.initMode(count, false);
    }
    fn initFault(self: *Fixture, count: usize) !void {
        try self.initMode(count, true);
    }
    fn initMode(self: *Fixture, count: usize, fault: bool) !void {
        self.tmp = std.testing.tmpDir(.{});
        self.directory = try self.tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
        self.adapter = .{};
        self.domain = try sessions.SessionHost.init(a, &.{if (fault) self.adapter.sshInterface() else self.adapter.interface()});
        const accepted = try self.domain.create(.{ .saved = .{ .connection_id = @fromBackingInt(91), .config_revision = 2, .protocol = if (fault) .ssh else .sftp, .immutable_config = .{ .endpoint = .{ .host = "retained-store-unit.invalid", .user = "fixture" } } } }, .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) });
        try std.testing.expect(try self.domain.ready(accepted.handle, accepted.operation, plugins.requiredServices(if (fault) .ssh else .sftp)));
        try std.testing.expect(try self.domain.attached(accepted.handle, .{ .target = .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) }, .tab_id = @fromBackingInt(1) }));
        self.owner = accepted.handle;
        if (fault) {
            const auxiliary = try self.domain.beginAuxiliaryTransfer(self.owner);
            self.binding = auxiliary.binding;
            self.close_key = auxiliary.key;
            try std.testing.expect(try self.domain.auxiliaryTransferReady(self.binding, self.close_key));
        } else self.binding = self.domain.queryService(self.owner, .transfer).available;
        self.backend = .{};
        self.legacy = .{};
        self.mux = routing.Mux.init(a, .{ .context = &self.domain, .is_live = live });
        try self.mux.register(self.binding, self.backend.interface());
        try self.mux.setCleanupGuard(self.binding, .{ .context = &self.backend, .receipt = Backend.receipt });
        self.dispatch = dispatching.Dispatch.init(a, self.legacy.interface(), self.mux.engine());
        self.manager = try transfer.Manager.init(a, self.dispatch.engine(), 4, .{});
        for (0..count) |index| {
            var job_spec = self.spec();
            job_spec.conflict_context.?.intent_id += index;
            const id = try self.manager.enqueue(job_spec);
            self.manager.tick(index);
            try self.manager.pause(id);
            try self.backend.push(@intCast(index + 1), .paused);
            self.manager.tick(index + 1);
        }
        if (fault) {
            try std.testing.expect(try self.domain.auxiliaryTransferReleased(self.binding, self.close_key, .awaiting));
            self.retained_id = try self.domain.retainFaultTransferSource(self.binding, self.close_key);
        } else {
            self.retained_id = try self.domain.retainTransferSource(self.owner);
            self.close_key = try self.domain.requestClose(self.owner, .{});
        }
        self.store = module.Store.init(a, std.testing.io, &self.manager, &self.mux, &self.dispatch, &self.domain);
    }
    fn spec(self: *Fixture) transfer.JobSpec {
        return .{ .session_id = @backingInt(self.owner.session_id), .transfer_binding = self.binding, .direction = .download, .sources = &.{"/remote/source"}, .remote_dir = "/remote", .local_dir = self.directory, .conflict_context = .{ .intent_id = 101, .original_owner = self.owner, .resource_owner = self.binding.resource_owner, .source_endpoint = .{ .sftp = .{ .binding_id = self.binding.binding_id, .binding_generation = self.binding.binding_generation, .resource_owner = self.binding.resource_owner, .origin_session = self.owner } }, .target_endpoint = .{ .local_fs = .{ .binding_id = 90, .binding_generation = 1 } } } };
    }
    fn original(self: *Fixture) !module.OwnedRetainedBatch {
        const jobs = try a.alloc(@import("host/file_transfer_runtime.zig").RetainedJob, self.manager.count());
        for (jobs, 0..) |*job, index| {
            const manager_id: u64 = @intCast(index + 1);
            const outer_id = self.manager.engineJob(manager_id).?;
            const mux_id = try self.dispatch.pausedBoundRoute(outer_id);
            const native_id = try self.mux.pausedNativeId(mux_id, self.binding);
            var name: [48]u8 = undefined;
            const temp_name = try std.fmt.bufPrint(&name, "checkpoint-{d}.part", .{manager_id});
            try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = temp_name, .data = "owned incomplete payload" });
            const path = try std.fs.path.join(a, &.{ self.directory, temp_name });
            defer a.free(path);
            job.* = .{ .original = .{ .job_id = manager_id, .attempt = 1, .proxy_id = mux_id, .native_id = native_id }, .checkpoint = try syntheticCheckpoint(self.backend.specs.items[index], native_id, path) };
        }
        return .{ .allocator = a, .owner = self.owner, .retained_owner = self.retained_id, .close_key = self.close_key, .binding = self.binding, .jobs = jobs };
    }
    fn accept(self: *Fixture) !*module.Batch {
        var original_batch = try self.original();
        defer original_batch.deinit() catch unreachable;
        const batch = try self.store.prepare(self.owner, self.close_key, self.retained_id, original_batch.jobs.len);
        try self.store.accept(batch, &original_batch);
        try std.testing.expectEqual(@as(usize, 0), original_batch.jobs.len);
        return batch;
    }
    fn drain(self: *Fixture) !void {
        const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
        while (try self.store.poll()) {
            if (clock.monotonicNs() > deadline) return error.TestTimeout;
            std.Io.sleep(std.testing.io, .fromNanoseconds(std.time.ns_per_ms), .awake) catch {};
        }
    }
    fn stop(self: *Fixture) void {
        self.backend.cleanup = .released;
        _ = self.store.shutdownStep();
        self.drain() catch @panic("retained Store did not release its test checkpoints");
        self.store.deinit() catch unreachable;
        self.manager.deinit();
        while (self.backend.events.items.len != 0 or self.legacy.events.items.len != 0) _ = self.dispatch.poll();
        self.dispatch.deinit() catch unreachable;
        self.mux.detach(self.binding) catch unreachable;
        self.mux.deinit() catch unreachable;
        self.backend.deinit();
        self.legacy.deinit();
        self.domain.deinit();
        a.free(self.directory);
        self.tmp.cleanup();
    }
};

/// Test-owned metadata only. The production OwnedCheckpoint.cancel code owns
/// the c-allocator storage and the real inode-checked local temporary artifact.
fn syntheticCheckpoint(spec: transfer.JobSpec, native: u64, temp_path: []const u8) !module.OwnedCheckpoint {
    const ca = std.heap.c_allocator;
    const sources = try ca.alloc([]u8, spec.sources.len);
    for (sources, spec.sources) |*copy, source| copy.* = try ca.dupe(u8, source);
    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, temp_path, .{ .follow_symlinks = false });
    return .{ ._payload = .{ .spec = .{ .session_id = spec.session_id, .transfer_binding = spec.transfer_binding, .conflict_context = spec.conflict_context, .direction = spec.direction, .sources = sources, .remote_dir = try ca.dupe(u8, spec.remote_dir), .local_dir = try ca.dupe(u8, spec.local_dir), .rename = null, .resume_transfer = spec.resume_transfer, .md5_check = spec.md5_check }, .original_engine_job = native, .continuation = .{ .outcome = .paused }, .temp = .{ .path = try ca.dupe(u8, temp_path), .inode = stat.inode, .created = true }, .done_bytes = 0, .total_bytes = 100, .total_ready = true, .skipped_files = 0, .skipped_bytes = 0, .verification = null, .remaining_policy = null } };
}

test "retained store preallocates and uniquely moves original batch without a second allocation" {
    var f: Fixture = undefined;
    try f.init(1);
    defer f.stop();
    var tracking = std.testing.FailingAllocator.init(a, .{});
    f.store.allocator = tracking.allocator();
    const batch = try f.store.prepare(f.owner, f.close_key, f.retained_id, 1);
    try std.testing.expect(batch == try f.store.prepare(f.owner, f.close_key, f.retained_id, 1));
    var original = try f.original();
    defer original.deinit() catch unreachable;
    const address = original.jobs.ptr;
    tracking.fail_index = tracking.alloc_index;
    try f.store.accept(batch, &original);
    try f.store.adopt(batch);
    try std.testing.expect(batch.payload.?.jobs.ptr == address);
    try std.testing.expectEqual(@as(usize, 0), original.jobs.len);
    try std.testing.expect(f.manager.engineJob(1) == null);
    try std.testing.expectEqual(f.retained_id, f.manager.retainedOwner(1).?.id);
    try std.testing.expectError(error.CheckpointNotConsumed, f.store.consumeImported(1, 1));
}

test "retained store rejects stale owner attempt native and count before consuming caller ownership" {
    var f: Fixture = undefined;
    try f.init(1);
    defer f.stop();
    var original = try f.original();
    defer original.deinit() catch unreachable;
    var stale = f.owner;
    stale.generation += 1;
    try std.testing.expectError(error.StaleCloseOperation, f.store.prepare(stale, f.close_key, f.retained_id, 1));
    const batch = try f.store.prepare(f.owner, f.close_key, f.retained_id, 1);
    try std.testing.expectError(error.RetainedBatchChanged, f.store.prepare(f.owner, f.close_key, f.retained_id, 2));
    original.jobs[0].original.attempt = 2;
    try std.testing.expectError(error.RetainedJobIdentityMismatch, f.store.accept(batch, &original));
    original.jobs[0].original.attempt = 1;
    original.jobs[0].original.native_id += 1;
    try std.testing.expectError(error.RetainedJobIdentityMismatch, f.store.accept(batch, &original));
    original.jobs[0].original.native_id -= 1;
    try std.testing.expectEqual(@as(usize, 1), original.jobs.len);
    try std.testing.expect(!f.dispatch.jobs.items[0].terminal and !f.mux.jobs.items[0].terminal);
    try f.store.accept(batch, &original);
    try f.store.adopt(batch);
}

test "retained store cleanup guard awaiting leaves actual payload and both routes resumable for adopt retry" {
    var f: Fixture = undefined;
    try f.init(1);
    defer f.stop();
    const batch = try f.accept();
    f.backend.cleanup = .awaiting;
    try std.testing.expectError(error.CleanupPending, f.store.adopt(batch));
    try std.testing.expect(!batch.slots[0].adopted and !batch.slots[0].mux_retired and !batch.slots[0].dispatch_retired);
    try std.testing.expect(f.store.checkpoint(1, 1) == null);
    try std.testing.expect(!f.dispatch.jobs.items[0].terminal and !f.mux.jobs.items[0].terminal);
    try std.testing.expectError(error.Busy, f.store.deinit());
    f.backend.cleanup = .released;
    try f.store.adopt(batch);
    try f.store.adopt(batch);
    try std.testing.expect(batch.slots[0].adopted and f.dispatch.jobs.items[0].terminal and f.mux.jobs.items[0].terminal);
    try std.testing.expect(f.store.checkpoint(1, 1) != null);
}

test "retained store cancel publishes only joined original receipt and clears only its own tmp" {
    var f: Fixture = undefined;
    try f.init(2);
    defer f.stop();
    const batch = try f.accept();
    try f.store.adopt(batch);
    const original_path = try a.dupe(u8, f.store.checkpoint(1, 1).?.describe().?.temp_path.?);
    defer a.free(original_path);
    const sibling_path = try a.dupe(u8, f.store.checkpoint(2, 1).?.describe().?.temp_path.?);
    defer a.free(sibling_path);
    try std.testing.expectError(error.UnknownRetainedJob, f.store.cancel(1, 2));
    try f.store.cancel(1, 1);
    try std.testing.expect(f.store.checkpoint(1, 1) == null);
    try std.testing.expectEqual(transfer.State.cancelling, f.manager.progress(1).?.state);
    try std.testing.expectError(error.Busy, f.store.deinit());
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (f.manager.progress(1).?.state != .cancelled) {
        _ = try f.store.poll();
        if (clock.monotonicNs() > deadline) return error.TestTimeout;
        std.Io.sleep(std.testing.io, .fromNanoseconds(std.time.ns_per_ms), .awake) catch {};
    }
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, original_path, .{}));
    _ = try std.Io.Dir.cwd().statFile(std.testing.io, sibling_path, .{});
    try std.testing.expectEqual(transfer.State.paused, f.manager.progress(2).?.state);
    try std.testing.expect(batch.payload.?.jobs[0].checkpoint == null and batch.payload.?.jobs[1].checkpoint != null);
    try f.store.cancel(1, 1);
}

test "retained store unknown inode cleanup keeps checkpoint replacement and shutdown Busy until explicit retry" {
    var f: Fixture = undefined;
    try f.init(1);
    defer f.stop();
    const batch = try f.accept();
    try f.store.adopt(batch);
    const path = try a.dupe(u8, f.store.checkpoint(1, 1).?.describe().?.temp_path.?);
    defer a.free(path);
    // Keep the old inode alive, then replace the original pathname.
    const old = try std.fs.path.join(a, &.{ f.directory, "moved-original.part" });
    defer a.free(old);
    try std.Io.Dir.cwd().rename(path, std.Io.Dir.cwd(), old, std.testing.io);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "replacement must survive" });
    try f.store.cancel(1, 1);
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (f.manager.progress(1).?.job_cleanup != .unknown) {
        _ = try f.store.poll();
        if (clock.monotonicNs() > deadline) return error.TestTimeout;
        std.Io.sleep(std.testing.io, .fromNanoseconds(std.time.ns_per_ms), .awake) catch {};
    }
    try std.testing.expect(batch.payload.?.jobs[0].checkpoint.?.describe() != null);
    try std.testing.expect(f.store.checkpoint(1, 1) == null);
    try std.testing.expectEqual(sessions.CloseReceipt.unknown, f.store.shutdownStep());
    try std.testing.expectError(error.Busy, f.store.deinit());
    const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(1024));
    defer a.free(contents);
    try std.testing.expectEqualStrings("replacement must survive", contents);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, path);
    try f.store.cancel(1, 1);
    // A retry request does not revoke the previous unknown cleanup receipt.
    try std.testing.expectEqual(sessions.CloseReceipt.unknown, f.store.shutdownStep());
    try f.drain();
    try f.domain.releaseRetainedTransfer(f.retained_id, f.owner);
    try std.testing.expectEqual(sessions.CloseReceipt.released, f.store.shutdownStep());
    try std.testing.expectEqual(transfer.State.cancelled, f.manager.progress(1).?.state);
}

test "retained store consumed checkpoint slot clears only after the external unique move" {
    var f: Fixture = undefined;
    try f.init(1);
    defer f.stop();
    const batch = try f.accept();
    try f.store.adopt(batch);
    const source = f.store.checkpoint(1, 1).?;
    var external = source.*;
    source.* = .{}; // Controlled importer: exact unique move, no IO claimed.
    defer {
        _ = external.cancel(std.testing.io);
        external.deinit() catch unreachable;
    }
    try f.store.consumeImported(1, 1);
    try std.testing.expect(batch.payload.?.jobs[0].checkpoint == null);
    try std.testing.expectEqual(sessions.CloseReceipt.released, f.store.shutdownStep());
    try std.testing.expectError(error.StoreClosing, f.store.prepare(f.owner, f.close_key, f.retained_id, 1));
    try std.testing.expect(f.store.checkpoint(1, 1) == null);
}

test "retained store allocation failure occurs before accepting an original exported payload" {
    var f: Fixture = undefined;
    try f.init(1);
    defer f.stop();
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    f.store.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, f.store.prepare(f.owner, f.close_key, f.retained_id, 1));
    try std.testing.expectEqual(@as(usize, 0), f.store.batches.items.len);
    f.store.allocator = a;
    const batch = try f.accept();
    try f.store.adopt(batch);
}

test "retained store partial route retirement preserves stage and checkpoint for exact retry" {
    var f: Fixture = undefined;
    try f.init(1);
    defer f.stop();
    const batch = try f.accept();
    f.backend.inject_dispatch_fault = &f.dispatch;
    try std.testing.expectError(error.EngineProtocolFault, f.store.adopt(batch));
    try std.testing.expect(batch.slots[0].mux_retired and !batch.slots[0].dispatch_retired and !batch.slots[0].adopted);
    try std.testing.expect(batch.payload.?.jobs[0].checkpoint.?.describe() != null);
    try std.testing.expect(f.manager.engineJob(1) != null and f.manager.retainedOwner(1) == null);
    f.dispatch.protocol_fault[1] = false;
    try f.store.adopt(batch);
    try std.testing.expect(batch.slots[0].adopted);
    try std.testing.expect(f.manager.engineJob(1) == null);
    try std.testing.expect(f.store.checkpoint(1, 1) != null);
}

test "retained store fault rejects forged tuple without moving checkpoint then adopts exact open key" {
    var f: Fixture = undefined;
    try f.initFault(1);
    defer f.stop();
    try std.testing.expectEqual(sessions.Lifecycle.attached, f.domain.queryState(f.owner).?.lifecycle);
    try std.testing.expect(f.domain.queryState(f.owner).?.close_operation == null);
    const terminal = f.domain.queryService(f.owner, .terminal).available;
    var original = try f.original();
    defer original.deinit() catch unreachable;
    const jobs = original.jobs.ptr;
    const artifact = try a.dupe(u8, original.jobs[0].checkpoint.?.describe().?.temp_path.?);
    defer a.free(artifact);
    var wrong_key = f.close_key;
    wrong_key.operation_id += 1;
    var wrong_binding = f.binding;
    wrong_binding.binding_generation += 1;
    const wrong_id: identity.RetainedTransferOwnerId = @fromBackingInt(@backingInt(f.retained_id) + 1);
    try std.testing.expectError(error.StaleCloseOperation, f.store.prepareFault(f.owner, f.binding, wrong_key, f.retained_id, 1));
    try std.testing.expectError(error.StaleCloseOperation, f.store.prepareFault(f.owner, wrong_binding, f.close_key, f.retained_id, 1));
    try std.testing.expectError(error.StaleCloseOperation, f.store.prepareFault(f.owner, f.binding, f.close_key, wrong_id, 1));
    try std.testing.expectEqual(@as(usize, 0), f.store.batches.items.len);
    const batch = try f.store.prepareFault(f.owner, f.binding, f.close_key, f.retained_id, 1);
    try std.testing.expect(batch == try f.store.prepareFault(f.owner, f.binding, f.close_key, f.retained_id, 1));
    try std.testing.expectError(error.RetainedBatchChanged, f.store.prepareFault(f.owner, f.binding, f.close_key, f.retained_id, 2));
    original.close_key = wrong_key;
    try std.testing.expectError(error.RetainedBatchChanged, f.store.accept(batch, &original));
    original.close_key = f.close_key;
    original.retained_owner = wrong_id;
    try std.testing.expectError(error.RetainedBatchChanged, f.store.accept(batch, &original));
    original.retained_owner = f.retained_id;
    original.binding = wrong_binding;
    try std.testing.expectError(error.RetainedBatchChanged, f.store.accept(batch, &original));
    original.binding = f.binding;
    original.jobs[0].checkpoint.?._payload.?.spec.transfer_binding = wrong_binding;
    try std.testing.expectError(error.TransferOwnerMismatch, f.store.accept(batch, &original));
    original.jobs[0].checkpoint.?._payload.?.spec.transfer_binding = f.binding;
    original.jobs[0].original.native_id += 1;
    try std.testing.expectError(error.RetainedJobIdentityMismatch, f.store.accept(batch, &original));
    original.jobs[0].original.native_id -= 1;
    try std.testing.expect(original.jobs.ptr == jobs and original.jobs.len == 1);
    try std.testing.expect(batch.payload == null and original.jobs[0].checkpoint.?.describe() != null);
    try std.testing.expect(!f.mux.jobs.items[0].terminal and !f.dispatch.jobs.items[0].terminal);
    try std.testing.expectEqual(@as(u64, "owned incomplete payload".len), (try std.Io.Dir.cwd().statFile(std.testing.io, artifact, .{})).size);
    try f.store.accept(batch, &original);
    try std.testing.expect(original.jobs.len == 0 and batch.payload.?.jobs.ptr == jobs);
    try f.store.adopt(batch);
    try std.testing.expect(f.store.checkpoint(1, 1) != null);
    try std.testing.expectEqual(f.retained_id, f.manager.retainedOwner(1).?.id);
    try std.testing.expect(f.manager.engineJob(1) == null);
    try std.testing.expect(f.domain.bindingIsLive(terminal));
    try std.testing.expectError(error.CleanupNotReleased, f.domain.beginRetainedTransfer(f.retained_id, f.owner));
    try f.store.cancel(1, 1);
    try f.drain();
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, artifact, .{}));
    try std.testing.expectEqual(transfer.State.cancelled, f.manager.progress(1).?.state);
    // A checkpoint's cleanup does not release the original physical transport.
    try std.testing.expectError(error.CleanupNotReleased, f.domain.releaseRetainedTransfer(f.retained_id, f.owner));
    try std.testing.expect(try f.domain.auxiliaryTransferReleased(f.binding, f.close_key, .released));
    try f.domain.releaseRetainedTransfer(f.retained_id, f.owner);
    try std.testing.expect(f.domain.bindingIsLive(terminal));
}

test "retained store accepts a second fault from the same retained owner only on its exact new binding" {
    var f: Fixture = undefined;
    try f.initFault(0);
    defer f.stop();
    const first_binding = f.binding;
    const first_key = f.close_key;
    try std.testing.expect(try f.domain.auxiliaryTransferReleased(first_binding, first_key, .released));
    try f.mux.detach(first_binding);
    const resumed = try f.domain.beginRetainedTransfer(f.retained_id, f.owner);
    try std.testing.expect(try f.domain.retainedTransferReady(resumed.binding, resumed.key));
    f.binding = resumed.binding;
    f.close_key = resumed.key;
    try f.mux.register(f.binding, f.backend.interface());
    try f.mux.setCleanupGuard(f.binding, .{ .context = &f.backend, .receipt = Backend.receipt });
    const job = try f.manager.enqueue(f.spec());
    f.manager.tick(0);
    try f.manager.pause(job);
    try f.backend.push(1, .paused);
    f.manager.tick(1);
    try std.testing.expect(try f.domain.retainedTransferReleased(f.binding, f.close_key, .awaiting));
    try std.testing.expectEqual(f.retained_id, try f.domain.retainFaultTransferSource(f.binding, f.close_key));
    try std.testing.expect(f.domain.faultTransferSourceIsCurrent(f.retained_id, f.owner, first_binding, first_key));
    try std.testing.expect(f.domain.faultTransferSourceIsCurrent(f.retained_id, f.owner, f.binding, f.close_key));
    const old_batch = try f.store.prepareFault(f.owner, first_binding, first_key, f.retained_id, 1);
    const batch = try f.store.prepareFault(f.owner, f.binding, f.close_key, f.retained_id, 1);
    var original = try f.original();
    defer original.deinit() catch unreachable;
    const checkpoint = original.jobs[0].checkpoint.?.describe().?;
    try std.testing.expectError(error.RetainedBatchChanged, f.store.accept(old_batch, &original));
    try std.testing.expect(original.jobs.len == 1 and original.jobs[0].checkpoint.?.describe() != null);
    try std.testing.expectEqualStrings(checkpoint.temp_path.?, original.jobs[0].checkpoint.?.describe().?.temp_path.?);
    try f.store.accept(batch, &original);
    try f.store.adopt(batch);
    try std.testing.expectEqual(f.retained_id, f.manager.retainedOwner(job).?.id);
    try std.testing.expect(f.store.checkpoint(job, 1) != null);
    try std.testing.expectEqual(sessions.Lifecycle.attached, f.domain.queryState(f.owner).?.lifecycle);
    try std.testing.expectError(error.CleanupNotReleased, f.domain.beginRetainedTransfer(f.retained_id, f.owner));
    try f.store.cancel(job, 1);
    try f.drain();
    try std.testing.expect(try f.domain.retainedTransferReleased(f.binding, f.close_key, .released));
    try f.domain.releaseRetainedTransfer(f.retained_id, f.owner);
}
