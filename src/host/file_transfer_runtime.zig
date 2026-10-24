//! One dedicated transfer connection per original service binding. Connection
//! and final protocol teardown never run on the application controller thread.
const std = @import("std");
const sessions = @import("session_host.zig");
const readonly = @import("../proto/ssh/sftp_readonly.zig");
const ssh = @import("../proto/ssh/session.zig");
const sftp = @import("../transfer/sftp_engine.zig");
const transfer = @import("../transfer/manager.zig");
const mux = @import("../transfer/engine_mux.zig");
const clock = @import("../platform/realtime.zig");
const c = @import("generated_ssh_session");
const identity = @import("identity.zig");
const operations = @import("operation.zig");

pub const RetainJob = struct {
    job_id: transfer.JobId,
    attempt: u8,
    proxy_id: transfer.EngineJobId,
    native_id: transfer.EngineJobId,
};
pub const RetainedJob = struct {
    original: RetainJob,
    checkpoint: ?sftp.OwnedCheckpoint = null,
};
/// The application supplies this from the unchanged queued Manager record,
/// after proving it has no checkpoint/native attempt and reserving its budget.
pub const RetainedDraft = struct {
    original: transfer.JobSpec,
    job_id: transfer.JobId,
    attempt: u8,
    next: transfer.JobSpec,
};
/// Move each checkpoint, then clear its original optional slot. Destroying a
/// batch never performs IO or silently abandons an owned temporary artifact.
pub const OwnedRetainedBatch = struct {
    allocator: std.mem.Allocator,
    owner: identity.SessionHandle,
    retained_owner: identity.RetainedTransferOwnerId,
    close_key: operations.OperationKey,
    binding: sessions.ServiceHandle,
    jobs: []RetainedJob,

    pub fn takeCheckpoint(self: *OwnedRetainedBatch, index: usize) !sftp.OwnedCheckpoint {
        if (index >= self.jobs.len) return error.InvalidRetainedIndex;
        const checkpoint = self.jobs[index].checkpoint orelse return error.CheckpointAlreadyTaken;
        self.jobs[index].checkpoint = null;
        return checkpoint;
    }
    pub fn deinit(self: *OwnedRetainedBatch) error{Busy}!void {
        for (self.jobs) |*job| if (job.checkpoint) |*checkpoint| try checkpoint.deinit();
        self.allocator.free(self.jobs);
        self.jobs = &.{};
    }
};

pub const Phase = enum(u8) { connecting, ready, failed, closing, cleanup_unknown, closed };
pub const Runtime = struct {
    allocator: std.mem.Allocator,
    binding: sessions.ServiceHandle,
    connector: readonly.Connector,
    backend: *sftp.SftpEngine,
    thread: ?std.Thread = null,
    closing: std.atomic.Value(bool) = .init(false),
    phase: std.atomic.Value(Phase) = .init(.connecting),
    receipt: std.atomic.Value(u8) = .init(@backingInt(readonly.ReleaseReceipt.awaiting)),
    done: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    session: ?ssh.Session = null,
    auxiliary: bool = false,
    // Controller initializes this before closing's release-store. Thereafter
    // only the worker writes it until done's acquire-load permits a unique move.
    retained: ?OwnedRetainedBatch = null,
    retain_cancel: std.atomic.Value(bool) = .init(false),
    transport_fault: std.atomic.Value(bool) = .init(false),
    fault_handoff: std.atomic.Value(bool) = .init(false),

    /// The caller prepares the connector using the frozen source and the same
    /// SessionHost journal. Ownership transfers only when start succeeds.
    pub fn start(allocator: std.mem.Allocator, binding: sessions.ServiceHandle, connector: readonly.Connector) !*Runtime {
        return startInternal(allocator, binding, connector, false);
    }

    /// SessionHost auxiliary transfers have their own binding generation,
    /// independent of the attached SSH session generation. Only its Host may
    /// call this after the exact auxiliary preparing authority is validated.
    pub fn startAuxiliary(allocator: std.mem.Allocator, binding: sessions.ServiceHandle, connector: readonly.Connector) !*Runtime {
        return startInternal(allocator, binding, connector, true);
    }

    fn startInternal(allocator: std.mem.Allocator, binding: sessions.ServiceHandle, connector: readonly.Connector, auxiliary: bool) !*Runtime {
        if (binding.kind != .transfer or binding.binding_id == 0 or binding.binding_generation == 0) return error.InvalidTransferBinding;
        if (connector.key.operation_id == 0) return error.InvalidTransferOperation;
        _ = try bindingOwner(binding, connector.key, auxiliary);
        const self = try allocator.create(Runtime);
        errdefer allocator.destroy(self);
        const backend = try sftp.SftpEngine.init(allocator);
        errdefer backend.deinit();
        self.* = .{ .allocator = allocator, .binding = binding, .connector = connector, .backend = backend, .auxiliary = auxiliary };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    pub fn state(self: *const Runtime) Phase {
        return self.phase.load(.acquire);
    }

    /// Failure is published before phase changes, and never changed afterward.
    pub fn failureReason(self: *const Runtime) ?anyerror {
        const phase = self.state();
        if (phase == .connecting or phase == .ready or phase == .closing) return null;
        return self.failure;
    }

    pub fn transportFailure(self: *const Runtime) ?anyerror {
        return if (self.transport_fault.load(.acquire)) error.TransferTransportClosed else null;
    }

    pub fn engine(self: *Runtime) transfer.TransferEngine {
        return .{ .ctx = self, .open = open, .pause = pauseJob, .resume_job = resumeJob, .can_resume = canResumeJob, .conflict_snapshot = conflictSnapshot, .resolve_conflict = resolveConflict, .cancel = cancel, .poll = poll };
    }

    pub fn cleanupGuard(self: *Runtime) mux.CleanupGuard {
        return .{ .context = self, .receipt = cleanup };
    }

    pub fn requestClose(self: *Runtime) void {
        self.closing.store(true, .release);
    }

    /// Memory-only acceptance. This must precede ordinary requestClose; native
    /// export, engine detach and connector teardown remain on the original owner.
    pub fn requestRetain(self: *Runtime, owner: identity.SessionHandle, close_key: operations.OperationKey, retained_owner: identity.RetainedTransferOwnerId, jobs: []const RetainJob) !void {
        if (self.binding.resource_owner != .session or !self.binding.resource_owner.session.eql(owner) or close_key.owner != .session or !close_key.owner.session.eql(owner) or close_key.operation_id == 0 or @backingInt(retained_owner) == 0) return error.TransferOwnerMismatch;
        if (self.retain_cancel.load(.acquire)) return error.RetainCancelled;
        if (self.retained) |batch| {
            if (!batch.owner.eql(owner) or !batch.close_key.eql(close_key) or batch.retained_owner != retained_owner or batch.jobs.len != jobs.len) return error.RetainAlreadyRequested;
            for (batch.jobs, jobs) |saved, requested| if (!std.meta.eql(saved.original, requested)) return error.RetainAlreadyRequested;
            return;
        }
        if (self.closing.load(.acquire)) return error.TransferRuntimeClosing;
        for (jobs, 0..) |job, index| {
            if (job.job_id == 0 or job.attempt == 0 or job.proxy_id == 0 or job.native_id == 0) return error.InvalidRetainedJob;
            for (jobs[0..index]) |previous| if (previous.job_id == job.job_id or previous.proxy_id == job.proxy_id or previous.native_id == job.native_id) return error.DuplicateRetainedJob;
            if (self.state() != .ready or !self.backend.canResume(job.native_id)) return error.CheckpointNotReleased;
        }
        const owned = try self.allocator.alloc(RetainedJob, jobs.len);
        for (owned, jobs) |*destination, original| destination.* = .{ .original = original };
        self.retained = .{ .allocator = self.allocator, .owner = owner, .retained_owner = retained_owner, .close_key = close_key, .binding = self.binding, .jobs = owned };
        self.closing.store(true, .release);
    }

    /// An exact failed connector operation, not an invented session-close key.
    /// The Host/domain authorizes retained_owner before this memory-only move.
    pub fn requestFaultRetain(self: *Runtime, key: operations.OperationKey, retained_owner: identity.RetainedTransferOwnerId, jobs: []const RetainJob) !void {
        if (!key.eql(self.connector.key) or self.transportFailure() == null) return error.StaleTransferFault;
        const owner = try bindingOwner(self.binding, key, self.auxiliary);
        if (@backingInt(retained_owner) == 0 or (self.binding.resource_owner == .retained_transfer and self.binding.resource_owner.retained_transfer != retained_owner)) return error.TransferOwnerMismatch;
        if (self.retain_cancel.load(.acquire)) return error.RetainCancelled;
        if (self.fault_handoff.load(.acquire)) {
            const batch = self.retained orelse return error.CheckpointAlreadyTaken;
            if (!batch.close_key.eql(key) or batch.retained_owner != retained_owner or batch.jobs.len != jobs.len) return error.RetainAlreadyRequested;
            for (batch.jobs, jobs) |saved, requested| if (!std.meta.eql(saved.original, requested)) return error.RetainAlreadyRequested;
            return;
        }
        if (self.retained != null) return error.RetainAlreadyRequested;
        if (self.backend.faultJobCount() != jobs.len) return error.RetainedJobSetChanged;
        for (jobs, 0..) |job, index| {
            if (job.job_id == 0 or job.attempt == 0 or job.proxy_id == 0 or job.native_id == 0) return error.InvalidRetainedJob;
            for (jobs[0..index]) |previous| if (previous.job_id == job.job_id or previous.proxy_id == job.proxy_id or previous.native_id == job.native_id) return error.DuplicateRetainedJob;
            if (!self.backend.canExportPaused(job.native_id)) return error.CheckpointNotReleased;
        }
        const owned = try self.allocator.alloc(RetainedJob, jobs.len);
        for (owned, jobs) |*destination, original| destination.* = .{ .original = original };
        self.retained = .{ .allocator = self.allocator, .owner = owner, .retained_owner = retained_owner, .close_key = key, .binding = self.binding, .jobs = owned };
        // This separate release/acquire edge remains necessary if a previous
        // close request already set closing while the fault held its payload.
        self.fault_handoff.store(true, .release);
        self.closing.store(true, .release);
    }

    pub fn takeRetained(self: *Runtime) !?OwnedRetainedBatch {
        if (!self.done.load(.acquire) or self.closeReceipt() != .released) return null;
        if (self.retain_cancel.load(.acquire)) return null;
        const batch = self.retained orelse return null;
        for (batch.jobs) |job| if (job.checkpoint == null) return error.IncompleteRetainedBatch;
        self.retained = null;
        return batch;
    }

    /// Explicit application shutdown only. A finished connector worker can be
    /// replaced with a checkpoint cleanup owner; no filesystem IO runs here.
    pub fn requestRetainedCancel(self: *Runtime) !void {
        self.retain_cancel.store(true, .release);
        self.requestClose();
        if (!self.done.load(.acquire) or self.retained == null) return;
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.done.store(false, .release);
        self.receipt.store(@backingInt(readonly.ReleaseReceipt.awaiting), .release);
        self.phase.store(.closing, .release);
        self.thread = std.Thread.spawn(.{}, cancelRetainedWorker, .{self}) catch |err| {
            self.phase.store(.cleanup_unknown, .release);
            self.receipt.store(@backingInt(readonly.ReleaseReceipt.unknown), .release);
            self.done.store(true, .release);
            return err;
        };
    }

    pub fn importPaused(self: *Runtime, checkpoint: *sftp.OwnedCheckpoint, spec: transfer.JobSpec) !transfer.EngineJobId {
        try self.validateSpec(spec);
        return self.backend.importPaused(checkpoint, spec);
    }

    /// Unlike checkpoint import, this creates a fresh preflight for a draft
    /// which never had an engine attempt. It cannot resume a foreign partial.
    pub fn startRetainedDraft(self: *Runtime, draft: RetainedDraft) !transfer.EngineJobId {
        try self.validateSpec(draft.next);
        try validateRetainedDraft(self.binding, draft);
        return self.backend.open(draft.next);
    }

    pub fn closeReceipt(self: *const Runtime) readonly.ReleaseReceipt {
        return @fromBackingInt(@intCast(self.receipt.load(.acquire)));
    }

    pub fn canDestroy(self: *const Runtime) bool {
        return self.done.load(.acquire) and self.closeReceipt() == .released and self.retained == null;
    }

    /// Caller must detach its Mux registration before destroying this context.
    pub fn deinit(self: *Runtime) error{Busy}!void {
        if (!self.canDestroy()) return error.Busy;
        if (self.thread) |thread| thread.join();
        self.backend.deinit();
        self.allocator.destroy(self);
    }

    fn open(raw: *anyopaque, spec: transfer.JobSpec) !transfer.EngineJobId {
        const self: *Runtime = @ptrCast(@alignCast(raw));
        try self.validateSpec(spec);
        if (self.binding.resource_owner == .retained_transfer) return error.RetainedImportRequired;
        return self.backend.open(spec);
    }

    fn validateSpec(self: *Runtime, spec: transfer.JobSpec) !void {
        if (self.closing.load(.acquire) or self.state() != .ready) return error.TransferNotReady;
        if (spec.transfer_binding == null or !spec.transfer_binding.?.eql(self.binding)) return error.TransferOwnerMismatch;
        const owner = try bindingOwner(self.binding, self.connector.key, self.auxiliary);
        if (spec.session_id != 0 and spec.session_id != @backingInt(owner.session_id)) return error.TransferOwnerMismatch;
    }

    fn pauseJob(raw: *anyopaque, job: transfer.EngineJobId) !void {
        const self: *Runtime = @ptrCast(@alignCast(raw));
        try self.backend.pause(job);
    }

    fn canResumeJob(raw: *anyopaque, job: transfer.EngineJobId) bool {
        const self: *Runtime = @ptrCast(@alignCast(raw));
        if (self.closing.load(.acquire) or self.state() != .ready) return false;
        return self.backend.canResume(job);
    }

    fn resumeJob(raw: *anyopaque, job: transfer.EngineJobId) !transfer.EngineJobId {
        const self: *Runtime = @ptrCast(@alignCast(raw));
        if (self.closing.load(.acquire) or self.state() != .ready) return error.TransferNotReady;
        return self.backend.resumeJob(job);
    }

    fn conflictSnapshot(raw: *anyopaque, allocator: std.mem.Allocator, job: transfer.EngineJobId) !?transfer.Conflict.OwnedSnapshot {
        const self: *Runtime = @ptrCast(@alignCast(raw));
        if (self.closing.load(.acquire) or self.state() != .ready) return error.TransferNotReady;
        return self.backend.conflictSnapshot(allocator, job);
    }

    fn resolveConflict(raw: *anyopaque, job: transfer.EngineJobId, request: transfer.Conflict.Request) !void {
        const self: *Runtime = @ptrCast(@alignCast(raw));
        if (self.closing.load(.acquire) or self.state() != .ready) return error.TransferNotReady;
        try self.backend.resolveConflict(job, request);
    }

    fn cancel(raw: *anyopaque, job: transfer.EngineJobId) void {
        const self: *Runtime = @ptrCast(@alignCast(raw));
        self.backend.cancel(job);
    }

    fn poll(raw: *anyopaque) ?transfer.EngineProgress {
        const self: *Runtime = @ptrCast(@alignCast(raw));
        const event = self.backend.poll() orelse return null;
        if (@import("../platform/runtime_mode.zig").automation) if (event.verification) |v| {
            if (v.source_md5 != null and v.target_md5 != null) std.debug.print("FILE_TRANSFER_VERIFICATION {{\"binding_id\":{d},\"generation\":{d},\"engine_job\":{d},\"engine_state\":\"{s}\",\"verification_state\":\"{s}\",\"source_md5\":\"{s}\",\"target_md5\":\"{s}\",\"repair_count\":{d}}}\n", .{ self.binding.binding_id, self.binding.binding_generation, event.job, @tagName(event.state), @tagName(v.state), std.fmt.bytesToHex(v.source_md5.?, .lower), std.fmt.bytesToHex(v.target_md5.?, .lower), v.repair_count });
        };
        return event;
    }

    fn cleanup(raw: *anyopaque, binding: sessions.ServiceHandle) mux.ReleaseReceipt {
        const self: *Runtime = @ptrCast(@alignCast(raw));
        if (!binding.eql(self.binding)) return .unknown;
        return switch (self.closeReceipt()) {
            .released => .released,
            .awaiting => .awaiting,
            .unknown => .unknown,
        };
    }

    fn run(self: *Runtime) void {
        self.session = self.connector.connect_fn(self.connector.ctx, &self.closing) catch |err| {
            self.failure = err;
            self.phase.store(.failed, .release);
            self.finish();
            return;
        };
        if (self.session.?.state != .active or self.session.?.channel != null or self.session.?.handle == null or self.session.?.socket_fd < 0) {
            self.failure = error.InvalidTransferSession;
            self.phase.store(.failed, .release);
            self.finish();
            return;
        }
        if (!self.closing.load(.acquire)) {
            self.initializeSftp() catch |err| {
                self.failure = err;
                self.phase.store(.failed, .release);
                self.finish();
                return;
            };
        }
        if (!self.closing.load(.acquire)) {
            self.backend.attachSession(&self.session.?);
            self.phase.store(.ready, .release);
            if (@import("../platform/runtime_mode.zig").automation) std.debug.print("FILE_TRANSFER_READY {{\"binding_id\":{d},\"generation\":{d},\"channel_absent\":{}}}\n", .{ self.binding.binding_id, self.binding.binding_generation, self.session.?.channel == null });
        }
        while (!self.closing.load(.acquire)) {
            if (transportClosed(self.session.?.socket_fd)) {
                self.backend.transportFailed();
                self.failure = error.TransferTransportClosed;
                self.phase.store(.failed, .release);
                self.transport_fault.store(true, .release);
                break;
            }
            pause();
        }
        if (self.transport_fault.load(.acquire)) {
            // Even an ordinary Host close cannot consume paused data. Only
            // the explicit handoff or application shutdown may leave this gate.
            while (!self.fault_handoff.load(.acquire) and !self.retain_cancel.load(.acquire)) {
                if (self.closing.load(.acquire) and self.backend.faultJobCount() == 0) break;
                pause();
            }
            if (self.retain_cancel.load(.acquire) and !self.fault_handoff.load(.acquire)) {
                self.backend.cancelFaulted();
                while (!self.backend.detachIfIdle()) pause();
            }
        }
        self.phase.store(.closing, .release);
        // This worker may wait for native operations; the UI only observes the
        // receipt. The Session remains alive until the engine owner has left it.
        if (self.retained != null) self.retainOnWorker() else if (!self.transport_fault.load(.acquire)) self.backend.detachSession() else while (!self.backend.detachIfIdle()) pause();
        self.finish();
    }

    fn retainOnWorker(self: *Runtime) void {
        while (true) {
            if (self.retain_cancel.load(.acquire)) {
                self.cancelBatchOnWorker();
                self.backend.detachSession();
                return;
            }
            var ready = true;
            for (self.retained.?.jobs) |*job| {
                if (job.checkpoint != null) continue;
                job.checkpoint = self.backend.exportPaused(job.original.native_id) catch |err| {
                    ready = false;
                    if (err != error.OutOfMemory) {
                        self.failure = err;
                        self.receipt.store(@backingInt(readonly.ReleaseReceipt.unknown), .release);
                        self.phase.store(.cleanup_unknown, .release);
                        while (!self.retain_cancel.load(.acquire)) pause();
                    }
                    break;
                };
                const info = job.checkpoint.?.describe().?;
                const context = info.spec.conflict_context;
                if (info.original_engine_job != job.original.native_id or info.spec.transfer_binding == null or !info.spec.transfer_binding.?.eql(self.binding) or context == null or context.?.job != job.original.job_id or context.?.attempt != job.original.attempt or !context.?.original_owner.eql(self.retained.?.owner) or !context.?.resource_owner.eql(self.binding.resource_owner)) {
                    self.failure = error.RetainedJobIdentityMismatch;
                    self.receipt.store(@backingInt(readonly.ReleaseReceipt.unknown), .release);
                    self.phase.store(.cleanup_unknown, .release);
                    while (!self.retain_cancel.load(.acquire)) pause();
                    ready = false;
                    break;
                }
            }
            if (ready and self.backend.detachIfIdle()) return;
            pause();
        }
    }

    fn cancelBatchOnWorker(self: *Runtime) void {
        var threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
        defer threaded.deinit();
        while (self.retained != null) {
            var released = true;
            for (self.retained.?.jobs) |*job| if (job.checkpoint) |*checkpoint| {
                if (checkpoint.cancel(threaded.io()) != .released) {
                    released = false;
                } else {
                    checkpoint.deinit() catch unreachable;
                    job.checkpoint = null;
                }
            };
            if (released) {
                self.retained.?.deinit() catch unreachable;
                self.retained = null;
                return;
            }
            self.receipt.store(@backingInt(readonly.ReleaseReceipt.unknown), .release);
            self.phase.store(.cleanup_unknown, .release);
            pause();
        }
    }

    fn cancelRetainedWorker(self: *Runtime) void {
        self.cancelBatchOnWorker();
        self.phase.store(.closed, .release);
        self.receipt.store(@backingInt(readonly.ReleaseReceipt.released), .release);
        self.done.store(true, .release);
    }

    fn initializeSftp(self: *Runtime) !void {
        const session = &self.session.?;
        c.zw_libssh2_session_nonblocking(session.handle.?);
        const deadline = clock.monotonicNs() + 30 * std.time.ns_per_s;
        while (true) {
            if (self.closing.load(.acquire)) return error.Cancelled;
            if (clock.monotonicNs() >= deadline) return error.Timeout;
            session.sftpReadonlyInit() catch |err| {
                if (err != error.WouldBlock) return err;
                // Retry this same native initialization, or abandon the whole
                // dedicated binding on cancel. No other owner uses it yet.
                pause();
                continue;
            };
            // Existing transfer engine APIs require a blocking dedicated
            // Session. Change mode only after startup's native step completes.
            session.setBlocking();
            return;
        }
    }

    fn finish(self: *Runtime) void {
        while (true) {
            const result = self.connector.close_fn(self.connector.ctx, if (self.session) |*value| value else null);
            if (result == .released) break;
            self.receipt.store(@backingInt(result), .release);
            if (result == .unknown) self.phase.store(.cleanup_unknown, .release);
            pause();
        }
        self.session = null;
        self.connector.deinit_fn(self.connector.ctx);
        self.phase.store(.closed, .release);
        self.receipt.store(@backingInt(readonly.ReleaseReceipt.released), .release);
        self.done.store(true, .release);
    }
};

/// Observes only the descriptor, never consumes SSH bytes or calls libssh2.
/// The Runtime owns its fd until the sole engine IO owner has been detached.
fn transportClosed(fd: c_int) bool {
    if (fd < 0) return true;
    var descriptor = [_]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 }};
    if (std.c.poll(&descriptor, 1, 0) <= 0) return false;
    return descriptor[0].revents & (std.c.POLL.ERR | std.c.POLL.HUP | std.c.POLL.NVAL) != 0;
}

fn bindingOwner(binding: sessions.ServiceHandle, key: operations.OperationKey, auxiliary: bool) !identity.SessionHandle {
    switch (binding.resource_owner) {
        .session => |owner| {
            if (key.owner != .session) return error.InvalidTransferOwner;
            if (!owner.eql(key.owner.session) or (!auxiliary and binding.binding_generation != owner.generation) or @backingInt(owner.session_id) == 0 or owner.generation == 0) return error.TransferOwnerMismatch;
            if (auxiliary and (binding.origin_session == null or key.attempt_id == null or key.attempt_id.? == 0)) return error.TransferOwnerMismatch;
            if (binding.origin_session) |origin| if (!origin.eql(owner)) return error.TransferOwnerMismatch;
            return owner;
        },
        .retained_transfer => |id| {
            if (auxiliary) return error.InvalidTransferOwner;
            if (key.owner != .transfer_owner) return error.InvalidTransferOwner;
            const origin = binding.origin_session orelse return error.TransferOwnerMismatch;
            if (@backingInt(id) == 0 or @backingInt(origin.session_id) == 0 or origin.generation == 0 or key.owner.transfer_owner.id != id or !key.owner.transfer_owner.original_handle.eql(origin) or key.attempt_id != binding.binding_generation) return error.TransferOwnerMismatch;
            return origin;
        },
    }
}

fn validateRetainedDraft(binding: sessions.ServiceHandle, draft: RetainedDraft) !void {
    if (binding.resource_owner != .retained_transfer) return error.InvalidTransferOwner;
    const origin = binding.origin_session orelse return error.TransferOwnerMismatch;
    if (draft.job_id == 0 or draft.attempt != 0) return error.InvalidRetainedDraftAttempt;
    const old = draft.original;
    const next = draft.next;
    const previous = old.transfer_binding orelse return error.MissingTransferBinding;
    if (previous.kind != .transfer or previous.binding_id == 0 or previous.binding_generation == 0 or previous.resource_owner != .session or !previous.resource_owner.session.eql(origin) or previous.origin_session == null or !previous.origin_session.?.eql(origin)) return error.RetainedDraftOwnerMismatch;
    if (old.session_id != @backingInt(origin.session_id) or old.session_id != next.session_id) return error.RetainedDraftOwnerMismatch;
    if (previous.eql(binding)) return error.StaleTransferBinding;
    if (old.chunk_kb != next.chunk_kb or old.window_chunks != next.window_chunks or old.pacing_kbps != next.pacing_kbps or old.direction != next.direction or old.resume_transfer != next.resume_transfer or old.md5_check != next.md5_check or old.notify_complete != next.notify_complete or old.sources.len != next.sources.len or !std.mem.eql(u8, old.local_dir, next.local_dir) or !std.mem.eql(u8, old.remote_dir, next.remote_dir) or (old.rename == null) != (next.rename == null)) return error.RetainedDraftSourceChanged;
    if (old.rename) |name| if (!std.mem.eql(u8, name, next.rename.?)) return error.RetainedDraftSourceChanged;
    for (old.sources, next.sources) |source, replacement| if (!std.mem.eql(u8, source, replacement)) return error.RetainedDraftSourceChanged;
    const original = old.conflict_context orelse return error.MissingConflictContext;
    const current = next.conflict_context orelse return error.MissingConflictContext;
    if (original.attempt != 0 or (original.job != 0 and original.job != draft.job_id)) return error.InvalidRetainedDraftAttempt;
    if (original.intent_id == 0 or current.intent_id != original.intent_id or current.job != draft.job_id or current.attempt != 1) return error.RetainedDraftIdentityMismatch;
    if (!original.original_owner.eql(origin) or !original.resource_owner.eql(previous.resource_owner) or !current.original_owner.eql(origin) or !current.resource_owner.eql(binding.resource_owner)) return error.RetainedDraftOwnerMismatch;
    try validateDraftEndpoint(original.source_endpoint, current.source_endpoint, previous, binding);
    try validateDraftEndpoint(original.target_endpoint, current.target_endpoint, previous, binding);
}

fn validateDraftEndpoint(old: @FieldType(transfer.Conflict.Context, "source_endpoint"), next: @FieldType(transfer.Conflict.Context, "source_endpoint"), previous: sessions.ServiceHandle, binding: sessions.ServiceHandle) !void {
    switch (old) {
        .local_fs => if (!old.eql(next)) return error.RetainedDraftEndpointMismatch,
        .sftp => |source| {
            if (next != .sftp) return error.RetainedDraftEndpointMismatch;
            const target = next.sftp;
            const origin = binding.origin_session.?;
            if (source.binding_id == 0 or source.binding_generation == 0 or !source.resource_owner.eql(previous.resource_owner) or source.origin_session == null or !source.origin_session.?.eql(origin)) return error.RetainedDraftEndpointMismatch;
            if (target.binding_id != binding.binding_id or target.binding_generation != binding.binding_generation or !target.resource_owner.eql(binding.resource_owner) or target.origin_session == null or !target.origin_session.?.eql(origin) or target.connection_snapshot_id != source.connection_snapshot_id) return error.RetainedDraftEndpointMismatch;
        },
    }
}

fn pause() void {
    var unused: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&unused, 0, 10);
}

test "file transfer runtime exact checkpoint handoff gates native release and rejects mismatched job identity" {
    const T = struct {
        const OpenRead = @FieldType(@FieldType(sftp.SftpEngine, "remote_files"), "open_read");
        const Purpose = @typeInfo(@typeInfo(OpenRead).pointer.child).@"fn".param_types[3].?;
        caller: std.Thread.Id,
        entered: std.atomic.Value(bool) = .init(false),
        release: std.atomic.Value(bool) = .init(false),
        close_entered: std.atomic.Value(bool) = .init(false),
        receipt: std.atomic.Value(u8) = .init(@backingInt(readonly.ReleaseReceipt.awaiting)),
        fn size(raw: ?*anyopaque, _: *ssh.Session, _: [:0]const u8) !u64 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            std.debug.assert(self.caller != std.Thread.getCurrentId());
            self.entered.store(true, .release);
            while (!self.release.load(.acquire)) pause();
            return 4096;
        }
        fn stat(_: ?*anyopaque, _: *ssh.Session, _: [:0]const u8) !ssh.SftpAttributes {
            return error.UnexpectedPostPauseStat;
        }
        fn read(_: ?*anyopaque, _: *ssh.Session, _: [:0]const u8, _: Purpose) !ssh.SftpHandle {
            return error.UnexpectedPostPauseRead;
        }
        fn connect(_: *anyopaque, _: *const std.atomic.Value(bool)) !ssh.Session {
            return error.NotUsed;
        }
        fn close(raw: *anyopaque, session: ?*ssh.Session) readonly.ReleaseReceipt {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(self.caller != std.Thread.getCurrentId() and session == null);
            self.close_entered.store(true, .release);
            return @fromBackingInt(@intCast(self.receipt.load(.acquire)));
        }
        fn destroy(_: *anyopaque) void {}
        fn work(value: *Runtime) void {
            value.retainOnWorker();
            value.finish();
        }
        fn cancelCheckpoint(checkpoint: *sftp.OwnedCheckpoint, caller: std.Thread.Id) void {
            std.debug.assert(caller != std.Thread.getCurrentId());
            var threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
            defer threaded.deinit();
            std.debug.assert(checkpoint.cancel(threaded.io()) == .released);
        }
        fn wait(flag: *const std.atomic.Value(bool)) !void {
            const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
            while (!flag.load(.acquire)) {
                if (clock.monotonicNs() >= deadline) return error.TestTimeout;
                pause();
            }
        }
    };
    inline for (.{ false, true }) |mismatched| {
        var gate: T = .{ .caller = std.Thread.getCurrentId() };
        const backend = try sftp.SftpEngine.init(std.testing.allocator);
        var value: ?*Runtime = null;
        defer {
            gate.release.store(true, .release);
            gate.receipt.store(@backingInt(readonly.ReleaseReceipt.released), .release);
            if (value) |live| {
                live.requestRetainedCancel() catch unreachable;
                T.wait(&live.done) catch @panic("retained Runtime test cleanup did not release");
                live.deinit() catch @panic("retained Runtime test kept a checkpoint");
            } else backend.deinit();
        }
        var session: ssh.Session = .{};
        backend.attachSession(&session);
        backend.remote_metadata = .{ .context = &gate, .size = T.size, .stat = T.stat };
        backend.remote_files.open_read = T.read;
        const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(93), .generation = 3 };
        const binding: sessions.ServiceHandle = .{ .resource_owner = .{ .session = owner }, .origin_session = owner, .kind = .transfer, .binding_id = 52, .binding_generation = owner.generation };
        const native_id = try backend.open(.{ .session_id = @backingInt(owner.session_id), .transfer_binding = binding, .direction = .download, .sources = &.{"unwritten"}, .remote_dir = "/readonly", .local_dir = "/tmp", .conflict_context = .{ .intent_id = 7, .job = 11, .attempt = 1, .original_owner = owner, .resource_owner = binding.resource_owner, .source_endpoint = .{ .sftp = .{ .binding_id = binding.binding_id, .binding_generation = binding.binding_generation, .resource_owner = binding.resource_owner, .origin_session = owner } }, .target_endpoint = .{ .local_fs = .{ .binding_id = 1, .binding_generation = 1 } } } });
        try T.wait(&gate.entered);
        try backend.pause(native_id);
        gate.release.store(true, .release);
        const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
        while (!backend.canResume(native_id)) {
            if (clock.monotonicNs() >= deadline) return error.CheckpointPauseTimeout;
            pause();
        }
        const ptr = try std.testing.allocator.create(Runtime);
        ptr.* = .{ .allocator = std.testing.allocator, .binding = binding, .connector = .{ .key = .{ .owner = .{ .session = owner }, .operation_id = 81, .attempt_id = 1 }, .ctx = &gate, .connect_fn = T.connect, .close_fn = T.close, .deinit_fn = T.destroy }, .backend = backend, .phase = .init(.ready) };
        value = ptr;
        const close_key: operations.OperationKey = .{ .owner = .{ .session = owner }, .operation_id = 82, .attempt_id = 1 };
        try ptr.requestRetain(owner, close_key, @fromBackingInt(17), &.{.{ .job_id = if (mismatched) 12 else 11, .attempt = 1, .proxy_id = 91, .native_id = native_id }});
        ptr.thread = try std.Thread.spawn(.{}, T.work, .{ptr});
        if (mismatched) {
            while (ptr.state() != .cleanup_unknown) {
                if (clock.monotonicNs() >= deadline) return error.RetainMismatchTimeout;
                pause();
            }
            try std.testing.expectEqual(error.RetainedJobIdentityMismatch, ptr.failureReason().?);
            try std.testing.expect(!gate.close_entered.load(.acquire));
            try std.testing.expect((try ptr.takeRetained()) == null);
            try ptr.requestRetainedCancel();
        }
        try T.wait(&gate.close_entered);
        try std.testing.expect(backend.session == null);
        try std.testing.expect((try ptr.takeRetained()) == null);
        gate.receipt.store(@backingInt(readonly.ReleaseReceipt.released), .release);
        try T.wait(&ptr.done);
        if (!mismatched) {
            try std.testing.expectError(error.Busy, ptr.deinit());
            var batch = (try ptr.takeRetained()).?;
            try std.testing.expectEqual(@as(usize, 1), batch.jobs.len);
            try std.testing.expectEqual(@as(u64, 91), batch.jobs[0].original.proxy_id);
            try std.testing.expectError(error.Busy, batch.deinit());
            var checkpoint = try batch.takeCheckpoint(0);
            defer {
                const cleanup = std.Thread.spawn(.{}, T.cancelCheckpoint, .{ &checkpoint, std.Thread.getCurrentId() }) catch unreachable;
                cleanup.join();
                checkpoint.deinit() catch unreachable;
            }
            try batch.deinit();
            try std.testing.expectEqual(@as(u64, 11), checkpoint.describe().?.spec.conflict_context.?.job);
            try std.testing.expectEqual(@as(u64, 0), checkpoint.describe().?.done_bytes);
            try std.testing.expect(checkpoint.describe().?.temp_path == null);
            try std.testing.expect((try ptr.takeRetained()) == null);
        }
    }
}
