//! One Manager over the existing unbound engine and the bound-file Mux.
//! Both engines stay caller-owned. Install before submitting jobs and keep
//! this dispatcher as their sole progress consumer until every job terminates.
const std = @import("std");
const transfer = @import("manager.zig");
const Backend = enum(u1) { legacy, bound };
const Job = struct {
    proxy_id: transfer.EngineJobId,
    backend: Backend,
    backend_id: transfer.EngineJobId,
    cancelled: bool = false,
    terminal: bool = false,
    pause_requested: bool = false,
    paused_released: bool = false,
};

pub const Dispatch = struct {
    allocator: std.mem.Allocator,
    backends: [2]transfer.TransferEngine,
    jobs: std.ArrayList(Job) = .empty,
    next_id: transfer.EngineJobId = 1,
    cursor: u1 = 0,
    protocol_fault: [2]bool = .{ false, false },

    pub fn init(allocator: std.mem.Allocator, legacy: transfer.TransferEngine, bound: transfer.TransferEngine) Dispatch {
        return .{ .allocator = allocator, .backends = .{ legacy, bound } };
    }
    /// The context needs stable storage before Manager retains this interface.
    pub fn engine(self: *Dispatch) transfer.TransferEngine {
        return .{ .ctx = self, .open = engineOpen, .cancel = engineCancel, .pause = enginePause, .resume_job = engineResume, .can_resume = engineCanResume, .conflict_snapshot = engineConflictSnapshot, .resolve_conflict = engineResolveConflict, .poll = enginePoll };
    }
    pub fn deinit(self: *Dispatch) error{Busy}!void {
        for (self.protocol_fault) |fault| if (fault) return error.Busy;
        for (self.jobs.items) |job| if (!job.terminal) return error.Busy;
        self.jobs.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn open(self: *Dispatch, spec: transfer.JobSpec) !transfer.EngineJobId {
        const side: Backend = if (spec.transfer_binding == null) .legacy else .bound;
        const i = @backingInt(side);
        if (self.protocol_fault[i]) return error.EngineProtocolFault;
        if (self.next_id == 0 or self.next_id == std.math.maxInt(transfer.EngineJobId)) return error.JobIdExhausted;
        // No allocation can fail after a backend accepts the job. Manager and
        // SFTP retain their own spec copies; this seam forwards every field.
        try self.jobs.ensureUnusedCapacity(self.allocator, 1);
        const backend = self.backends[i];
        const backend_id = try backend.open(backend.ctx, spec);
        const proxy_id = self.next_id;
        self.next_id += 1;
        var duplicate = false;
        for (self.jobs.items) |job| if (job.backend == side and job.backend_id == backend_id) {
            duplicate = true;
            break;
        };
        self.jobs.appendAssumeCapacity(.{ .proxy_id = proxy_id, .backend = side, .backend_id = backend_id });
        if (duplicate) {
            // Cross-backend collisions are normal. Reusing an ID within one
            // backend is ambiguous; retain accepted ownership rather than
            // attributing its future terminal to a different job.
            self.protocol_fault[i] = true;
            backend.cancel(backend.ctx, backend_id);
            return error.EngineProtocolFault;
        }
        return proxy_id;
    }
    pub fn cancel(self: *Dispatch, proxy_id: transfer.EngineJobId) void {
        for (self.jobs.items) |*job| if (job.proxy_id == proxy_id) {
            if (!job.terminal and !job.cancelled) {
                job.cancelled = true;
                job.paused_released = false;
                const backend = self.backends[@backingInt(job.backend)];
                backend.cancel(backend.ctx, job.backend_id);
            }
            return;
        };
    }
    pub fn pause(self: *Dispatch, proxy_id: transfer.EngineJobId) !void {
        for (self.jobs.items) |*job| if (job.proxy_id == proxy_id) {
            if (job.terminal) return error.JobTerminal;
            if (job.cancelled) return error.CancellationPending;
            const index = @backingInt(job.backend);
            if (self.protocol_fault[index]) return error.EngineProtocolFault;
            if (job.pause_requested) return;
            const backend = self.backends[index];
            const pause_engine = backend.pause orelse return error.UnsupportedPause;
            try pause_engine(backend.ctx, job.backend_id);
            job.pause_requested = true;
            return;
        };
        return error.UnknownJob;
    }
    pub fn canResume(self: *const Dispatch, proxy_id: transfer.EngineJobId) bool {
        for (self.jobs.items) |job| if (job.proxy_id == proxy_id) {
            const index = @backingInt(job.backend);
            if (job.terminal or job.cancelled or !job.paused_released or self.protocol_fault[index]) return false;
            const backend = self.backends[index];
            if (backend.resume_job == null) return false;
            const can_resume = backend.can_resume orelse return false;
            return can_resume(backend.ctx, job.backend_id);
        };
        return false;
    }
    pub fn resumeJob(self: *Dispatch, proxy_id: transfer.EngineJobId) !transfer.EngineJobId {
        for (self.jobs.items, 0..) |original, old_index| if (original.proxy_id == proxy_id) {
            if (original.terminal) return error.JobTerminal;
            if (original.cancelled) return error.CancellationPending;
            if (!original.paused_released) return error.CleanupPending;
            const index = @backingInt(original.backend);
            if (self.protocol_fault[index]) return error.EngineProtocolFault;
            const backend = self.backends[index];
            const resume_job = backend.resume_job orelse return error.UnsupportedResume;
            const can_resume = backend.can_resume orelse return error.UnsupportedResume;
            if (!can_resume(backend.ctx, original.backend_id)) return error.UnsupportedResume;
            if (self.next_id == 0 or self.next_id == std.math.maxInt(transfer.EngineJobId)) return error.JobIdExhausted;
            try self.jobs.ensureUnusedCapacity(self.allocator, 1);
            const new_proxy_id = self.next_id;
            const backend_id = try resume_job(backend.ctx, original.backend_id);
            self.next_id += 1;
            var invalid = backend_id == 0;
            for (self.jobs.items) |job| if (job.backend == original.backend and job.backend_id == backend_id) {
                invalid = true;
                break;
            };
            self.jobs.appendAssumeCapacity(.{ .proxy_id = new_proxy_id, .backend = original.backend, .backend_id = backend_id });
            if (invalid) {
                self.protocol_fault[index] = true;
                backend.cancel(backend.ctx, backend_id);
                return error.EngineProtocolFault;
            }
            self.jobs.items[old_index].terminal = true;
            self.jobs.items[old_index].paused_released = false;
            return new_proxy_id;
        };
        return error.UnknownJob;
    }
    pub fn conflictSnapshot(self: *Dispatch, allocator: std.mem.Allocator, id: transfer.EngineJobId) !?transfer.Conflict.OwnedSnapshot {
        for (self.jobs.items) |job| if (job.proxy_id == id) {
            if (job.terminal or job.cancelled or job.pause_requested) return error.JobTerminal;
            const index = @backingInt(job.backend);
            if (self.protocol_fault[index]) return error.EngineProtocolFault;
            const backend = self.backends[index];
            const call = backend.conflict_snapshot orelse return error.UnsupportedConflict;
            var result = (try call(backend.ctx, allocator, job.backend_id)) orelse return null;
            if (result.value.engine_job != job.backend_id) {
                result.deinit();
                return error.EngineProtocolFault;
            }
            result.value.engine_job = id;
            return result;
        };
        return error.UnknownJob;
    }
    pub fn resolveConflict(self: *Dispatch, id: transfer.EngineJobId, request: transfer.Conflict.Request) !void {
        for (self.jobs.items) |job| if (job.proxy_id == id) {
            if (job.terminal or job.cancelled or job.pause_requested) return error.JobTerminal;
            const index = @backingInt(job.backend);
            if (self.protocol_fault[index]) return error.EngineProtocolFault;
            const backend = self.backends[index];
            const call = backend.resolve_conflict orelse return error.UnsupportedConflict;
            return call(backend.ctx, job.backend_id, request);
        };
        return error.UnknownJob;
    }
    pub fn pausedBoundRoute(self: *const Dispatch, id: transfer.EngineJobId) !transfer.EngineJobId {
        for (self.jobs.items) |job| if (job.proxy_id == id) {
            if (job.backend != .bound) return error.NotBoundTransfer;
            if (job.terminal or job.cancelled or !job.paused_released) return error.CheckpointNotReleased;
            if (self.protocol_fault[@backingInt(job.backend)]) return error.EngineProtocolFault;
            return job.backend_id;
        };
        return error.UnknownJob;
    }

    pub fn retireExportedPaused(self: *Dispatch, id: transfer.EngineJobId, expected_bound_id: transfer.EngineJobId) !void {
        if (try self.pausedBoundRoute(id) != expected_bound_id) return error.StaleAttempt;
        for (self.jobs.items) |*job| if (job.proxy_id == id) {
            job.terminal = true;
            job.paused_released = false;
            return;
        };
        unreachable;
    }

    /// Reserve this outer proxy before the callback imports through the Mux.
    pub fn importBoundPaused(self: *Dispatch, context: *anyopaque, accept: *const fn (*anyopaque) anyerror!transfer.EngineJobId) !transfer.EngineJobId {
        const side: Backend = .bound;
        const index = @backingInt(side);
        if (self.protocol_fault[index]) return error.EngineProtocolFault;
        if (self.next_id == 0 or self.next_id == std.math.maxInt(transfer.EngineJobId)) return error.JobIdExhausted;
        try self.jobs.ensureUnusedCapacity(self.allocator, 1);
        const backend_id = try accept(context);
        const id = self.next_id;
        self.next_id += 1;
        var duplicate = backend_id == 0;
        for (self.jobs.items) |job| if (job.backend == side and job.backend_id == backend_id) {
            duplicate = true;
            break;
        };
        self.jobs.appendAssumeCapacity(.{ .proxy_id = id, .backend = side, .backend_id = backend_id });
        if (duplicate) {
            self.protocol_fault[index] = true;
            const backend = self.backends[index];
            backend.cancel(backend.ctx, backend_id);
            return error.EngineProtocolFault;
        }
        return id;
    }

    /// At most one poll per backend per call. The next starting backend follows
    /// the last visited one, so a noisy legacy engine cannot starve file jobs.
    pub fn poll(self: *Dispatch) ?transfer.EngineProgress {
        for (0..2) |_| {
            const i = self.cursor;
            self.cursor +%= 1;
            const backend = self.backends[i];
            const event = backend.poll(backend.ctx) orelse continue;
            if (self.protocol_fault[i]) continue;
            for (self.jobs.items) |*job| {
                if (@backingInt(job.backend) != i or job.backend_id != event.job or job.terminal) continue;
                var routed = event;
                routed.job = job.proxy_id;
                job.paused_released = !job.cancelled and event.state == .paused and event.job_cleanup == .released;
                if (event.job_cleanup == .released) switch (event.state) {
                    .running => {},
                    // Retained paused data remains cancellable on this ID.
                    .paused => {},
                    .succeeded, .failed, .cancelled => job.terminal = true,
                };
                return routed;
            }
        }
        return null;
    }
};

fn engineOpen(raw: *anyopaque, spec: transfer.JobSpec) !transfer.EngineJobId {
    const self: *Dispatch = @ptrCast(@alignCast(raw));
    return self.open(spec);
}
fn engineCancel(raw: *anyopaque, job: transfer.EngineJobId) void {
    const self: *Dispatch = @ptrCast(@alignCast(raw));
    self.cancel(job);
}
fn enginePause(raw: *anyopaque, job: transfer.EngineJobId) !void {
    const self: *Dispatch = @ptrCast(@alignCast(raw));
    try self.pause(job);
}
fn engineResume(raw: *anyopaque, job: transfer.EngineJobId) !transfer.EngineJobId {
    const self: *Dispatch = @ptrCast(@alignCast(raw));
    return self.resumeJob(job);
}
fn engineCanResume(raw: *anyopaque, job: transfer.EngineJobId) bool {
    const self: *Dispatch = @ptrCast(@alignCast(raw));
    return self.canResume(job);
}
fn enginePoll(raw: *anyopaque) ?transfer.EngineProgress {
    const self: *Dispatch = @ptrCast(@alignCast(raw));
    return self.poll();
}

fn engineConflictSnapshot(raw: *anyopaque, allocator: std.mem.Allocator, id: transfer.EngineJobId) !?transfer.Conflict.OwnedSnapshot {
    const self: *Dispatch = @ptrCast(@alignCast(raw));
    return self.conflictSnapshot(allocator, id);
}
fn engineResolveConflict(raw: *anyopaque, id: transfer.EngineJobId, request: transfer.Conflict.Request) !void {
    const self: *Dispatch = @ptrCast(@alignCast(raw));
    return self.resolveConflict(id, request);
}
