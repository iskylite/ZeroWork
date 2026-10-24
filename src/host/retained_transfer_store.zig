//! Application-owned, unique storage for checkpoints exported by the original
//! transfer Runtime. Only the background cancellation thread touches local IO.
const std = @import("std");
const transfer = @import("../transfer/manager.zig");
const routing = @import("../transfer/engine_mux.zig");
const dispatching = @import("../transfer/engine_dispatch.zig");
const sessions = @import("session_host.zig");
const runtime = @import("file_transfer_runtime.zig");
const identity = @import("identity.zig");
const operations = @import("operation.zig");
pub const OwnedCheckpoint = @import("../transfer/sftp_engine.zig").OwnedCheckpoint;
pub const OwnedRetainedBatch = runtime.OwnedRetainedBatch;

const Slot = struct {
    dispatch_id: ?transfer.EngineJobId = null,
    mux_retired: bool = false,
    dispatch_retired: bool = false,
    adopted: bool = false,
    cancel_requested: bool = false,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    result: transfer.JobCleanup = .awaiting,
    last_cleanup: transfer.JobCleanup = .awaiting,
    receipt_pending: bool = false,
    checkpoint_ptr: ?*OwnedCheckpoint = null,
    io: std.Io = undefined,

    fn cancelWorker(self: *Slot) void {
        self.result = self.checkpoint_ptr.?.cancel(self.io);
        self.done.store(true, .release);
    }
};

pub const Batch = struct {
    owner: identity.SessionHandle,
    close_key: operations.OperationKey,
    retained_id: identity.RetainedTransferOwnerId,
    fault_binding: ?sessions.ServiceHandle = null,
    source_binding: ?sessions.ServiceHandle = null,
    /// Null until accept receives the original Host-owned batch. The caller
    /// may inspect presence, but must never move or mutate its checkpoints.
    payload: ?OwnedRetainedBatch = null,
    slots: []Slot,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    manager: *transfer.Manager,
    mux: *routing.Mux,
    dispatch: *dispatching.Dispatch,
    domain: *sessions.SessionHost,
    batches: std.ArrayList(*Batch) = .empty,
    closing: bool = false,

    /// All dependencies must remain at stable addresses until deinit succeeds.
    /// io is used only by the unique checkpoint cancellation worker.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, manager: *transfer.Manager, mux: *routing.Mux, dispatch: *dispatching.Dispatch, domain: *sessions.SessionHost) Store {
        return .{ .allocator = allocator, .io = io, .manager = manager, .mux = mux, .dispatch = dispatch, .domain = domain };
    }

    /// Allocate every Store-owned slot before Host.takeRetained moves native
    /// ownership. Repeated preparation of the exact close is idempotent.
    pub fn prepare(self: *Store, owner: identity.SessionHandle, close_key: operations.OperationKey, retained_id: identity.RetainedTransferOwnerId, count: usize) !*Batch {
        return self.prepareSource(owner, close_key, retained_id, count, null, null);
    }

    /// An original SSH can carry shared jobs while an older dedicated batch
    /// finishes. Each physical binding exports its own unique checkpoint set.
    pub fn prepareBinding(self: *Store, owner: identity.SessionHandle, close_key: operations.OperationKey, retained_id: identity.RetainedTransferOwnerId, count: usize, binding: sessions.ServiceHandle) !*Batch {
        return self.prepareSource(owner, close_key, retained_id, count, null, binding);
    }

    pub fn prepareFault(self: *Store, owner: identity.SessionHandle, binding: sessions.ServiceHandle, key: operations.OperationKey, retained_id: identity.RetainedTransferOwnerId, count: usize) !*Batch {
        return self.prepareSource(owner, key, retained_id, count, binding, null);
    }

    fn prepareSource(self: *Store, owner: identity.SessionHandle, close_key: operations.OperationKey, retained_id: identity.RetainedTransferOwnerId, count: usize, fault_binding: ?sessions.ServiceHandle, source_binding: ?sessions.ServiceHandle) !*Batch {
        if (self.closing) return error.StoreClosing;
        try self.validateSource(owner, close_key, retained_id, fault_binding);
        for (self.batches.items) |batch| if (batch.owner.eql(owner) and batch.close_key.eql(close_key) and std.meta.eql(batch.source_binding, source_binding)) {
            if (batch.retained_id != retained_id or batch.slots.len != count or !std.meta.eql(batch.fault_binding, fault_binding)) return error.RetainedBatchChanged;
            return batch;
        };
        try self.batches.ensureUnusedCapacity(self.allocator, 1);
        const batch = try self.allocator.create(Batch);
        errdefer self.allocator.destroy(batch);
        const slots = try self.allocator.alloc(Slot, count);
        for (slots) |*slot| slot.* = .{};
        batch.* = .{ .owner = owner, .close_key = close_key, .retained_id = retained_id, .fault_binding = fault_binding, .source_binding = source_binding, .slots = slots };
        self.batches.appendAssumeCapacity(batch);
        return batch;
    }

    /// No allocation or IO after the original batch has been received. A
    /// rejection leaves caller.jobs and every checkpoint uniquely caller-owned.
    pub fn accept(self: *Store, batch: *Batch, original: *OwnedRetainedBatch) !void {
        if (self.closing) return error.StoreClosing;
        if (!self.contains(batch)) return error.UnknownRetainedBatch;
        if (batch.payload != null) return error.RetainedBatchAlreadyAccepted;
        try self.validateSource(batch.owner, batch.close_key, batch.retained_id, batch.fault_binding);
        if (!original.owner.eql(batch.owner) or !original.close_key.eql(batch.close_key) or original.retained_owner != batch.retained_id or original.jobs.len != batch.slots.len) return error.RetainedBatchChanged;
        try validateBinding(original.binding, batch);
        if (batch.source_binding) |binding| if (!binding.eql(original.binding)) return error.RetainedBatchChanged;
        if (batch.fault_binding) |binding| if (!binding.eql(original.binding)) return error.RetainedBatchChanged;
        for (original.jobs, 0..) |*job, index| {
            try validateCheckpoint(job, original.binding, batch.owner);
            for (original.jobs[0..index]) |previous| if (previous.original.job_id == job.original.job_id or previous.original.proxy_id == job.original.proxy_id or previous.original.native_id == job.original.native_id) return error.DuplicateRetainedJob;
            for (self.batches.items) |other| if (other.payload) |payload| {
                for (payload.jobs) |existing| if (existing.original.job_id == job.original.job_id and existing.original.attempt == job.original.attempt) return error.DuplicateRetainedJob;
            };
        }
        batch.payload = original.*;
        original.jobs = &.{};
    }

    /// Freeze all identities before retiring any route. Per-slot phase flags
    /// preserve unique ownership if an original cleanup guard is still waiting.
    pub fn adopt(self: *Store, batch: *Batch) !void {
        if (!self.contains(batch)) return error.UnknownRetainedBatch;
        const payload = if (batch.payload) |*value| value else return error.RetainedBatchNotAccepted;
        var pending = false;
        for (batch.slots) |slot| if (!slot.adopted) {
            pending = true;
            break;
        };
        if (!pending) return;
        try self.validateSource(batch.owner, batch.close_key, batch.retained_id, batch.fault_binding);
        for (payload.jobs, batch.slots) |*job, *slot| {
            if (slot.adopted) continue;
            try validateCheckpoint(job, payload.binding, batch.owner);
            try self.validateManager(batch, job);
            const dispatch_id = self.manager.engineJob(job.original.job_id) orelse return error.StaleAttempt;
            if (slot.dispatch_id) |frozen| {
                if (frozen != dispatch_id) return error.StaleAttempt;
            } else slot.dispatch_id = dispatch_id;
            if (!slot.dispatch_retired and try self.dispatch.pausedBoundRoute(dispatch_id) != job.original.proxy_id) return error.StaleAttempt;
            if (!slot.mux_retired and try self.mux.pausedNativeId(job.original.proxy_id, payload.binding) != job.original.native_id) return error.StaleAttempt;
        }
        for (payload.jobs, batch.slots) |*job, *slot| {
            if (slot.adopted) continue;
            if (!slot.mux_retired) {
                try self.mux.retireExportedPaused(job.original.proxy_id, payload.binding, job.original.native_id);
                slot.mux_retired = true;
            }
            if (!slot.dispatch_retired) {
                try self.dispatch.retireExportedPaused(slot.dispatch_id.?, job.original.proxy_id);
                slot.dispatch_retired = true;
            }
            try self.manager.retainPaused(job.original.job_id, job.original.attempt, slot.dispatch_id, transferOwner(batch));
            slot.adopted = true;
        }
    }

    /// Borrowed until the next call that imports/cancels this exact slot.
    /// Cancellation and shutdown never race an importer for the payload.
    pub fn checkpoint(self: *Store, job_id: transfer.JobId, attempt: u8) ?*OwnedCheckpoint {
        if (self.closing) return null;
        const found = self.find(job_id, attempt) orelse return null;
        if (!found.slot.adopted or found.slot.cancel_requested or found.slot.thread != null or found.slot.receipt_pending) return null;
        const job = &found.batch.payload.?.jobs[found.index];
        return if (job.checkpoint) |*value| value else null;
    }

    /// Import must already have uniquely consumed the checkpoint. This method
    /// never treats a live payload as imported and never cancels it implicitly.
    pub fn consumeImported(self: *Store, job_id: transfer.JobId, attempt: u8) !void {
        const found = self.find(job_id, attempt) orelse return error.UnknownRetainedJob;
        if (!found.slot.adopted or found.slot.cancel_requested or found.slot.thread != null or found.slot.receipt_pending) return error.CheckpointBusy;
        const job = &found.batch.payload.?.jobs[found.index];
        if (job.checkpoint) |*value| {
            if (value.describe() != null) return error.CheckpointNotConsumed;
            try value.deinit();
            job.checkpoint = null;
        }
    }

    /// Thread acceptance is the only asynchronous mutation here. Actual local
    /// unlink runs in cancelWorker; only poll publishes a completion receipt.
    pub fn cancel(self: *Store, job_id: transfer.JobId, attempt: u8) !void {
        const found = self.find(job_id, attempt) orelse return error.UnknownRetainedJob;
        try self.startCancel(found);
    }

    pub fn poll(self: *Store) !bool {
        var active = false;
        for (self.batches.items) |batch| if (batch.payload) |*payload| {
            for (payload.jobs, batch.slots) |*job, *slot| {
                if (slot.thread) |thread| {
                    if (!slot.done.load(.acquire)) {
                        active = true;
                        continue;
                    }
                    thread.join();
                    slot.thread = null;
                    slot.checkpoint_ptr = null;
                    slot.receipt_pending = true;
                }
                if (slot.receipt_pending) {
                    // If the Manager rejects the original identity, retain the
                    // pending receipt and storage instead of claiming release.
                    slot.last_cleanup = slot.result;
                    try self.manager.retainedCancelReceipt(job.original.job_id, job.original.attempt, transferOwner(batch), slot.result);
                    slot.receipt_pending = false;
                    if (slot.result == .released) {
                        if (job.checkpoint) |*value| {
                            if (value.describe() != null) return error.InvalidCleanupReceipt;
                            try value.deinit();
                            job.checkpoint = null;
                        }
                    }
                }
                if (job.checkpoint != null) active = true;
            }
        };
        return active;
    }

    /// Nonblocking. An unknown result is retained until an explicit cancel
    /// retry; shutdown cannot turn a failed artifact check into "released".
    pub fn shutdownStep(self: *Store) sessions.CloseReceipt {
        self.closing = true;
        var result: sessions.CloseReceipt = .released;
        for (self.batches.items) |batch| if (batch.payload) |*payload| {
            self.adopt(batch) catch |err| {
                result = combine(result, if (err == error.CleanupPending or err == error.CheckpointNotReleased) .awaiting else .unknown);
                continue;
            };
            for (payload.jobs, batch.slots, 0..) |*job, *slot, index| {
                if (job.checkpoint == null) continue;
                if (!slot.cancel_requested) self.startCancel(.{ .batch = batch, .slot = slot, .index = index }) catch {
                    result = combine(result, .unknown);
                    continue;
                };
                result = combine(result, if (slot.last_cleanup == .unknown) .unknown else .awaiting);
            }
        };
        return result;
    }

    pub fn deinit(self: *Store) error{Busy}!void {
        for (self.batches.items) |batch| {
            for (batch.slots) |slot| if (slot.thread != null or slot.receipt_pending) return error.Busy;
            if (batch.payload) |payload| for (payload.jobs) |job| if (job.checkpoint != null) return error.Busy;
        }
        for (self.batches.items) |batch| {
            if (batch.payload) |*payload| payload.deinit() catch unreachable;
            self.allocator.free(batch.slots);
            self.allocator.destroy(batch);
        }
        self.batches.deinit(self.allocator);
        self.* = undefined;
    }

    const Found = struct { batch: *Batch, slot: *Slot, index: usize };
    fn find(self: *Store, job_id: transfer.JobId, attempt: u8) ?Found {
        for (self.batches.items) |batch| if (batch.payload) |payload| {
            for (payload.jobs, batch.slots, 0..) |job, *slot, index| if (job.original.job_id == job_id and job.original.attempt == attempt) return .{ .batch = batch, .slot = slot, .index = index };
        };
        return null;
    }
    fn contains(self: *Store, requested: *Batch) bool {
        for (self.batches.items) |batch| if (batch == requested) return true;
        return false;
    }
    fn validateSource(self: *Store, owner: identity.SessionHandle, close_key: operations.OperationKey, retained_id: identity.RetainedTransferOwnerId, fault_binding: ?sessions.ServiceHandle) !void {
        if (fault_binding) |binding| {
            if (!self.domain.faultTransferSourceIsCurrent(retained_id, owner, binding, close_key)) return error.StaleCloseOperation;
            return;
        }
        if (close_key.operation_id == 0 or close_key.owner != .session or !close_key.owner.session.eql(owner)) return error.StaleCloseOperation;
        const original = self.domain.queryState(owner) orelse return error.StaleSession;
        if (original.close_operation == null or !original.close_operation.?.eql(close_key)) return error.StaleCloseOperation;
        if (self.domain.retainedTransferSource(retained_id, owner) == null) return error.UnknownRetainedTransfer;
    }
    fn validateManager(self: *Store, batch: *Batch, job: *runtime.RetainedJob) !void {
        const progress = self.manager.progress(job.original.job_id) orelse return error.UnknownJob;
        if (progress.attempt != job.original.attempt or progress.state != .paused or progress.job_cleanup != .released) return error.CheckpointNotReleased;
        if (self.manager.sessionId(job.original.job_id) != @backingInt(batch.owner.session_id)) return error.TransferOwnerMismatch;
        const binding = self.manager.transferBinding(job.original.job_id) orelse return error.MissingTransferBinding;
        if (!binding.eql(batch.payload.?.binding)) return error.TransferOwnerMismatch;
        if (self.manager.retainedOwner(job.original.job_id)) |existing| if (!std.meta.eql(existing, transferOwner(batch))) return error.TransferOwnerMismatch;
    }
    fn startCancel(self: *Store, found: Found) !void {
        const job = &found.batch.payload.?.jobs[found.index];
        const slot = found.slot;
        if (!slot.adopted) return error.CheckpointNotAdopted;
        if (slot.thread != null or slot.receipt_pending or job.checkpoint == null) return;
        if (self.manager.retainedOwner(job.original.job_id)) |owner| {
            if (!std.meta.eql(owner, transferOwner(found.batch))) return error.TransferOwnerMismatch;
        } else return error.TransferOwnerMismatch;
        const progress = self.manager.progress(job.original.job_id) orelse return error.UnknownJob;
        if (progress.attempt != job.original.attempt or self.manager.engineJob(job.original.job_id) != null or progress.state == .cancelled or progress.state == .succeeded or progress.state == .failed) return error.StaleAttempt;
        slot.checkpoint_ptr = &job.checkpoint.?;
        slot.io = self.io;
        slot.result = .awaiting;
        slot.done.store(false, .release);
        slot.thread = std.Thread.spawn(.{}, Slot.cancelWorker, .{slot}) catch |err| {
            slot.checkpoint_ptr = null;
            return err;
        };
        slot.cancel_requested = true;
        // This is only acceptance; the worker's completion remains poll-owned.
        try self.manager.retainedCancelReceipt(job.original.job_id, job.original.attempt, transferOwner(found.batch), .awaiting);
    }
};

fn transferOwner(batch: *const Batch) identity.TransferOwner {
    return .{ .id = batch.retained_id, .original_handle = batch.owner };
}
fn validateBinding(binding: sessions.ServiceHandle, batch: *const Batch) !void {
    if (binding.kind != .transfer or binding.binding_id == 0 or binding.binding_generation == 0) return error.TransferOwnerMismatch;
    switch (binding.resource_owner) {
        .session => |owner| if (!owner.eql(batch.owner)) return error.TransferOwnerMismatch,
        .retained_transfer => |id| if (batch.fault_binding == null or id != batch.retained_id) return error.TransferOwnerMismatch,
    }
    if (binding.origin_session) |origin| if (!origin.eql(batch.owner)) return error.TransferOwnerMismatch;
}
fn validateCheckpoint(job: *const runtime.RetainedJob, binding: sessions.ServiceHandle, owner: identity.SessionHandle) !void {
    const info = if (job.checkpoint) |*checkpoint_| checkpoint_.describe() orelse return error.CheckpointAlreadyConsumed else return error.CheckpointAlreadyConsumed;
    const original = job.original;
    if (original.job_id == 0 or original.attempt == 0 or original.proxy_id == 0 or original.native_id == 0 or info.original_engine_job != original.native_id) return error.RetainedJobIdentityMismatch;
    if (info.spec.session_id != @backingInt(owner.session_id) or info.spec.transfer_binding == null or !info.spec.transfer_binding.?.eql(binding)) return error.TransferOwnerMismatch;
    const context = info.spec.conflict_context orelse return error.MissingConflictContext;
    if (context.job != original.job_id or context.attempt != original.attempt or !context.original_owner.eql(owner) or !context.resource_owner.eql(binding.resource_owner)) return error.RetainedJobIdentityMismatch;
}
fn combine(left: sessions.CloseReceipt, right: sessions.CloseReceipt) sessions.CloseReceipt {
    if (left == .unknown or right == .unknown) return .unknown;
    if (left == .awaiting or right == .awaiting) return .awaiting;
    return .released;
}
