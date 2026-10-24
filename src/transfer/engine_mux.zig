//! Controller-thread router over caller-owned transfer engines. It neither
//! opens Sessions nor borrows an active tab. All jobs keep their original
//! ServiceHandle and engine; backend-local job IDs are never exposed upstream.
const std = @import("std");
const transfer = @import("manager.zig");
const identity = @import("../host/identity.zig");
pub const ServiceHandle = transfer.ServiceHandle;
pub const ReleaseReceipt = enum { released, awaiting, unknown };
pub const Authority = struct {
    context: *anyopaque,
    /// Memory-only domain liveness check, repeated at registration and open.
    is_live: *const fn (*anyopaque, ServiceHandle) bool,
};
pub const CleanupGuard = struct {
    context: *anyopaque,
    /// Nonblocking receipt for this original engine's actual IO release. It
    /// must not perform UI-thread file/network IO or join an active worker.
    receipt: *const fn (*anyopaque, ServiceHandle) ReleaseReceipt,
};
const Registration = struct {
    binding: ServiceHandle,
    engine: transfer.TransferEngine,
    guard: ?CleanupGuard = null,
    protocol_fault: bool = false,
};
const Job = struct {
    id: transfer.EngineJobId,
    binding: ServiceHandle,
    engine: transfer.TransferEngine,
    local_id: transfer.EngineJobId,
    terminal: bool = false,
    cancelled: bool = false,
    pause_requested: bool = false,
    paused_released: bool = false,
};

pub const Mux = struct {
    allocator: std.mem.Allocator,
    authority: Authority,
    registrations: std.ArrayList(Registration) = .empty,
    jobs: std.ArrayList(Job) = .empty,
    next_id: transfer.EngineJobId = 1,
    cursor: usize = 0,

    pub fn init(allocator: std.mem.Allocator, authority: Authority) Mux {
        return .{ .allocator = allocator, .authority = authority };
    }

    /// Engines remain owned by the caller until detach succeeds. A single
    /// engine ctx cannot be registered for multiple physical bindings.
    pub fn register(self: *Mux, binding: ServiceHandle, engine_: transfer.TransferEngine) !void {
        try validateBinding(binding);
        if (!self.authority.is_live(self.authority.context, binding)) return error.StaleBinding;
        for (self.registrations.items) |registered| {
            if (registered.binding.eql(binding)) {
                if (!sameEngine(registered.engine, engine_)) return error.BindingAlreadyRegistered;
                return;
            }
            if (registered.binding.binding_id == binding.binding_id) return error.BindingGenerationBusy;
            if (registered.engine.ctx == engine_.ctx) return error.EngineAlreadyRegistered;
        }
        try self.registrations.append(self.allocator, .{ .binding = binding, .engine = engine_ });
    }

    /// Exact in-memory acceptance gate; domain-ready alone does not prove
    /// that a Runtime has installed its engine and cleanup guard here.
    pub fn isRegistered(self: *const Mux, binding: ServiceHandle) bool {
        for (self.registrations.items) |registered| if (registered.binding.eql(binding)) return registered.guard != null and !registered.protocol_fault;
        return false;
    }

    pub fn setCleanupGuard(self: *Mux, binding: ServiceHandle, guard: ?CleanupGuard) !void {
        const registered = self.findRegistration(binding) orelse return error.UnknownBinding;
        registered.guard = guard;
    }

    pub fn engine(self: *Mux) transfer.TransferEngine {
        return .{ .ctx = self, .open = dispatchOpen, .cancel = dispatchCancel, .pause = dispatchPause, .resume_job = dispatchResume, .can_resume = dispatchCanResume, .conflict_snapshot = dispatchConflictSnapshot, .resolve_conflict = dispatchResolveConflict, .poll = dispatchPoll };
    }

    pub fn open(self: *Mux, spec: transfer.JobSpec) !transfer.EngineJobId {
        const binding = spec.transfer_binding orelse return error.MissingTransferBinding;
        try validateBinding(binding);
        const registered = self.findRegistration(binding) orelse return error.StaleBinding;
        if (!self.authority.is_live(self.authority.context, binding)) return error.StaleBinding;
        try validateOrigin(binding, spec.session_id);
        if (registered.protocol_fault) return error.EngineProtocolFault;
        if (self.next_id == std.math.maxInt(transfer.EngineJobId)) return error.JobIdExhausted;
        // Reserve before open: no allocation may fail after the backend has
        // acquired a job. Backend IDs must be unique within a registration,
        // the same precondition as Manager's original single-engine contract.
        try self.jobs.ensureUnusedCapacity(self.allocator, 1);
        const id = self.next_id;
        const local_id = try registered.engine.open(registered.engine.ctx, spec);
        self.next_id += 1;
        var duplicate = false;
        for (self.jobs.items) |job| if (job.binding.eql(binding) and job.local_id == local_id) {
            duplicate = true;
            break;
        };
        self.jobs.appendAssumeCapacity(.{ .id = id, .binding = binding, .engine = registered.engine, .local_id = local_id });
        if (duplicate) {
            // A broken backend cannot make an ambiguous new job disappear.
            // Quarantine it and retain the references; detach never treats
            // this protocol failure as evidence that its IO was released.
            registered.protocol_fault = true;
            registered.engine.cancel(registered.engine.ctx, local_id);
            return error.EngineProtocolFault;
        }
        return id;
    }

    pub fn cancel(self: *Mux, id: transfer.EngineJobId) void {
        for (self.jobs.items) |*job| if (job.id == id) {
            if (!job.terminal and !job.cancelled) {
                job.cancelled = true;
                job.paused_released = false;
                job.engine.cancel(job.engine.ctx, job.local_id);
            }
            return;
        };
    }

    /// Resolve capabilities on the frozen original job, including mixed
    /// registrations added after Manager retained this router's interface.
    pub fn pause(self: *Mux, id: transfer.EngineJobId) !void {
        for (self.jobs.items) |*job| if (job.id == id) {
            if (job.terminal) return error.JobTerminal;
            if (job.cancelled) return error.CancellationPending;
            const registered = self.findRegistration(job.binding) orelse return error.UnknownBinding;
            if (registered.protocol_fault) return error.EngineProtocolFault;
            if (job.pause_requested) return;
            const pause_engine = job.engine.pause orelse return error.UnsupportedPause;
            try pause_engine(job.engine.ctx, job.local_id);
            job.pause_requested = true;
            return;
        };
        return error.UnknownJob;
    }

    /// A router callback alone does not establish native resume support. Query
    /// only the original paused entity and binding; this never performs IO.
    pub fn canResume(self: *const Mux, id: transfer.EngineJobId) bool {
        for (self.jobs.items) |job| if (job.id == id) {
            if (job.terminal or job.cancelled or !job.paused_released or job.engine.resume_job == null) return false;
            const can_resume = job.engine.can_resume orelse return false;
            if (!self.authority.is_live(self.authority.context, job.binding)) return false;
            for (self.registrations.items) |registered| if (registered.binding.eql(job.binding)) {
                return !registered.protocol_fault and can_resume(job.engine.ctx, job.local_id);
            };
            return false;
        };
        return false;
    }

    /// Accept a new engine entity only after reserving this layer's proxy.
    /// Failure retains the old paused route; success transfers its ownership
    /// to a distinct native/proxy ID without selecting another binding.
    pub fn resumeJob(self: *Mux, id: transfer.EngineJobId) !transfer.EngineJobId {
        for (self.jobs.items, 0..) |original, old_index| if (original.id == id) {
            if (original.terminal) return error.JobTerminal;
            if (original.cancelled) return error.CancellationPending;
            if (!original.paused_released) return error.CleanupPending;
            const registered = self.findRegistration(original.binding) orelse return error.UnknownBinding;
            if (registered.protocol_fault) return error.EngineProtocolFault;
            if (!self.authority.is_live(self.authority.context, original.binding)) return error.StaleBinding;
            const resume_job = original.engine.resume_job orelse return error.UnsupportedResume;
            const can_resume = original.engine.can_resume orelse return error.UnsupportedResume;
            if (!can_resume(original.engine.ctx, original.local_id)) return error.UnsupportedResume;
            if (self.next_id == 0 or self.next_id == std.math.maxInt(transfer.EngineJobId)) return error.JobIdExhausted;
            try self.jobs.ensureUnusedCapacity(self.allocator, 1);
            const proxy_id = self.next_id;
            const local_id = try resume_job(original.engine.ctx, original.local_id);
            self.next_id += 1;
            var invalid = local_id == 0;
            for (self.jobs.items) |job| if (job.binding.eql(original.binding) and job.local_id == local_id) {
                invalid = true;
                break;
            };
            self.jobs.appendAssumeCapacity(.{ .id = proxy_id, .binding = original.binding, .engine = original.engine, .local_id = local_id });
            if (invalid) {
                registered.protocol_fault = true;
                original.engine.cancel(original.engine.ctx, local_id);
                return error.EngineProtocolFault;
            }
            // ensureUnusedCapacity may have moved jobs; never retain its old
            // element pointer across allocation or the accepted backend call.
            self.jobs.items[old_index].terminal = true;
            self.jobs.items[old_index].paused_released = false;
            return proxy_id;
        };
        return error.UnknownJob;
    }

    fn conflictJob(self: *Mux, id: transfer.EngineJobId) !Job {
        for (self.jobs.items) |job| if (job.id == id) {
            if (job.terminal or job.cancelled or job.pause_requested) return error.JobTerminal;
            const registered = self.findRegistration(job.binding) orelse return error.UnknownBinding;
            if (registered.protocol_fault) return error.EngineProtocolFault;
            if (!self.authority.is_live(self.authority.context, job.binding)) return error.StaleBinding;
            return job;
        };
        return error.UnknownJob;
    }
    pub fn conflictSnapshot(self: *Mux, allocator: std.mem.Allocator, id: transfer.EngineJobId) !?transfer.Conflict.OwnedSnapshot {
        const job = try self.conflictJob(id);
        const call = job.engine.conflict_snapshot orelse return error.UnsupportedConflict;
        var result = (try call(job.engine.ctx, allocator, job.local_id)) orelse return null;
        if (result.value.engine_job != job.local_id) {
            result.deinit();
            return error.EngineProtocolFault;
        }
        result.value.engine_job = id;
        return result;
    }
    pub fn resolveConflict(self: *Mux, id: transfer.EngineJobId, request: transfer.Conflict.Request) !void {
        const job = try self.conflictJob(id);
        const call = job.engine.resolve_conflict orelse return error.UnsupportedConflict;
        return call(job.engine.ctx, job.local_id, request);
    }
    pub fn pausedNativeId(self: *Mux, id: transfer.EngineJobId, binding: ServiceHandle) !transfer.EngineJobId {
        for (self.jobs.items) |job| if (job.id == id) {
            if (!job.binding.eql(binding)) return error.TransferOwnerMismatch;
            if (job.terminal or job.cancelled or !job.paused_released) return error.CheckpointNotReleased;
            const registered = self.findRegistration(binding) orelse return error.UnknownBinding;
            if (registered.protocol_fault) return error.EngineProtocolFault;
            return job.local_id;
        };
        return error.UnknownJob;
    }

    /// The host calls this only after taking the actual exported payload.
    /// The original Runtime's real close receipt gates releasing its route.
    pub fn retireExportedPaused(self: *Mux, id: transfer.EngineJobId, binding: ServiceHandle, native_id: transfer.EngineJobId) !void {
        if (try self.pausedNativeId(id, binding) != native_id) return error.StaleAttempt;
        const registered = self.findRegistration(binding).?;
        const guard = registered.guard orelse return error.CleanupGuardMissing;
        switch (guard.receipt(guard.context, binding)) {
            .awaiting => return error.CleanupPending,
            .unknown => return error.CleanupUnknown,
            .released => {},
        }
        for (self.jobs.items) |*job| if (job.id == id) {
            job.terminal = true;
            job.paused_released = false;
            return;
        };
        unreachable;
    }

    /// Reserve routing storage before the host imports its unique checkpoint.
    /// The callback performs only the new Runtime's in-memory acceptance.
    pub fn importPaused(self: *Mux, binding: ServiceHandle, context: *anyopaque, accept: *const fn (*anyopaque) anyerror!transfer.EngineJobId) !transfer.EngineJobId {
        try validateBinding(binding);
        const registered = self.findRegistration(binding) orelse return error.StaleBinding;
        if (!self.authority.is_live(self.authority.context, binding)) return error.StaleBinding;
        if (registered.protocol_fault) return error.EngineProtocolFault;
        if (self.next_id == std.math.maxInt(transfer.EngineJobId)) return error.JobIdExhausted;
        try self.jobs.ensureUnusedCapacity(self.allocator, 1);
        const id = self.next_id;
        const local_id = try accept(context);
        self.next_id += 1;
        var duplicate = local_id == 0;
        for (self.jobs.items) |job| if (job.binding.eql(binding) and job.local_id == local_id) {
            duplicate = true;
            break;
        };
        self.jobs.appendAssumeCapacity(.{ .id = id, .binding = binding, .engine = registered.engine, .local_id = local_id });
        if (duplicate) {
            registered.protocol_fault = true;
            registered.engine.cancel(registered.engine.ctx, local_id);
            return error.EngineProtocolFault;
        }
        return id;
    }

    /// Each returned event advances the next starting engine. One call visits
    /// each registration at most once; a noisy backend cannot starve a sibling.
    /// Stale domain bindings still drain their original workers for cleanup.
    pub fn poll(self: *Mux) ?transfer.EngineProgress {
        const count = self.registrations.items.len;
        if (count == 0) return null;
        for (0..count) |_| {
            const index = self.cursor % count;
            self.cursor = (index + 1) % count;
            const registered = &self.registrations.items[index];
            const event = registered.engine.poll(registered.engine.ctx) orelse continue;
            if (registered.protocol_fault) continue;
            for (self.jobs.items) |*job| {
                if (!job.binding.eql(registered.binding) or job.local_id != event.job or job.terminal) continue;
                var routed = event;
                routed.job = job.id;
                job.paused_released = !job.cancelled and event.state == .paused and event.job_cleanup == .released;
                if (event.job_cleanup == .released) switch (event.state) {
                    .running => {},
                    // Paused IO is quiescent, but its retained temporary file
                    // still belongs to this commandable original engine job.
                    // A later cancel must reach it and return its own receipt.
                    .paused => {},
                    .succeeded, .failed, .cancelled => job.terminal = true,
                };
                return routed;
            }
        }
        return null;
    }

    /// A cancellation request or business terminal alone cannot release a
    /// borrowed engine. The host supplies actual worker/handle cleanup evidence.
    pub fn detach(self: *Mux, binding: ServiceHandle) !void {
        for (self.registrations.items, 0..) |registered, index| {
            if (!registered.binding.eql(binding)) continue;
            if (registered.protocol_fault) return error.EngineProtocolFault;
            for (self.jobs.items) |job| if (job.binding.eql(binding) and !job.terminal) return error.JobsActive;
            const guard = registered.guard orelse return error.CleanupGuardMissing;
            switch (guard.receipt(guard.context, binding)) {
                .awaiting => return error.CleanupPending,
                .unknown => return error.CleanupUnknown,
                .released => {},
            }
            var job_index: usize = 0;
            while (job_index < self.jobs.items.len) {
                if (self.jobs.items[job_index].binding.eql(binding)) {
                    _ = self.jobs.orderedRemove(job_index);
                } else job_index += 1;
            }
            _ = self.registrations.orderedRemove(index);
            if (self.registrations.items.len == 0) self.cursor = 0 else self.cursor %= self.registrations.items.len;
            return;
        }
        return error.UnknownBinding;
    }

    pub fn deinit(self: *Mux) error{Busy}!void {
        if (self.registrations.items.len != 0 or self.jobs.items.len != 0) return error.Busy;
        self.registrations.deinit(self.allocator);
        self.jobs.deinit(self.allocator);
        self.* = undefined;
    }

    fn findRegistration(self: *Mux, binding: ServiceHandle) ?*Registration {
        for (self.registrations.items) |*registered| if (registered.binding.eql(binding)) return registered;
        return null;
    }
};

fn sameEngine(left: transfer.TransferEngine, right: transfer.TransferEngine) bool {
    return left.ctx == right.ctx and left.open == right.open and left.cancel == right.cancel and left.pause == right.pause and left.resume_job == right.resume_job and left.can_resume == right.can_resume and left.conflict_snapshot == right.conflict_snapshot and left.resolve_conflict == right.resolve_conflict and left.poll == right.poll;
}
fn validateBinding(binding: ServiceHandle) !void {
    if (binding.kind != .transfer) return error.ServiceKindMismatch;
    if (binding.binding_id == 0 or binding.binding_generation == 0) return error.InvalidBinding;
    switch (binding.resource_owner) {
        .session => |owner| {
            if (@backingInt(owner.session_id) == 0 or owner.generation == 0) return error.InvalidOwner;
            // Independent auxiliary connections advance their own binding
            // generation. Exact issuance/liveness is checked by Authority.
            if (binding.origin_session) |origin| if (!origin.eql(owner)) return error.OwnerMismatch;
        },
        .retained_transfer => |owner| if (@backingInt(owner) == 0) return error.InvalidOwner,
    }
    if (binding.origin_session) |origin| if (@backingInt(origin.session_id) == 0 or origin.generation == 0) return error.InvalidOwner;
}
fn validateOrigin(binding: ServiceHandle, session_id: u64) !void {
    if (session_id == 0) return;
    const origin: identity.SessionHandle = binding.origin_session orelse switch (binding.resource_owner) {
        .session => |owner| owner,
        .retained_transfer => return error.OwnerMismatch,
    };
    if (@backingInt(origin.session_id) != session_id) return error.OwnerMismatch;
}
fn dispatchOpen(raw: *anyopaque, spec: transfer.JobSpec) !transfer.EngineJobId {
    const self: *Mux = @ptrCast(@alignCast(raw));
    return self.open(spec);
}
fn dispatchCancel(raw: *anyopaque, id: transfer.EngineJobId) void {
    const self: *Mux = @ptrCast(@alignCast(raw));
    self.cancel(id);
}
fn dispatchPause(raw: *anyopaque, id: transfer.EngineJobId) !void {
    const self: *Mux = @ptrCast(@alignCast(raw));
    try self.pause(id);
}
fn dispatchResume(raw: *anyopaque, id: transfer.EngineJobId) !transfer.EngineJobId {
    const self: *Mux = @ptrCast(@alignCast(raw));
    return self.resumeJob(id);
}
fn dispatchCanResume(raw: *anyopaque, id: transfer.EngineJobId) bool {
    const self: *Mux = @ptrCast(@alignCast(raw));
    return self.canResume(id);
}
fn dispatchPoll(raw: *anyopaque) ?transfer.EngineProgress {
    const self: *Mux = @ptrCast(@alignCast(raw));
    return self.poll();
}

fn dispatchConflictSnapshot(raw: *anyopaque, allocator: std.mem.Allocator, id: transfer.EngineJobId) !?transfer.Conflict.OwnedSnapshot {
    const self: *Mux = @ptrCast(@alignCast(raw));
    return self.conflictSnapshot(allocator, id);
}
fn dispatchResolveConflict(raw: *anyopaque, id: transfer.EngineJobId, request: transfer.Conflict.Request) !void {
    const self: *Mux = @ptrCast(@alignCast(raw));
    return self.resolveConflict(id, request);
}
