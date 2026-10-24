const std = @import("std");
pub const ServiceHandle = @import("../host/session_host.zig").ServiceHandle;
const identity = @import("../host/identity.zig");
pub const window_policy = @import("window_policy.zig");

pub const JobId = u64;
pub const EngineJobId = u64;
pub const Conflict = @import("conflict_types.zig");

pub const Direction = enum { upload, download };

/// Callers may release every input slice after enqueue returns; Manager owns its copy.
pub const JobSpec = struct {
    /// Stable origin; switching the active tab must never retarget a retained job.
    session_id: u64 = 0,
    /// Optional for the legacy single-engine path. A routing engine requires
    /// the original domain transfer service, including owner/generation.
    transfer_binding: ?ServiceHandle = null,
    direction: Direction,
    sources: []const []const u8,
    remote_dir: []const u8,
    local_dir: []const u8,
    rename: ?[]const u8 = null,
    resume_transfer: bool = true,
    md5_check: bool = false,
    /// Frozen per-intent completion notification choice, independent of global policy.
    notify_complete: bool = true,
    /// Frozen logical block/window policy for this intent and every successor.
    chunk_kb: u16 = 64,
    window_chunks: u8 = 16,
    /// Frozen byte rate for an explicitly paced transport; zero is unlimited.
    pacing_kbps: u32 = 0,
    conflict_context: ?Conflict.Context = null,
};

pub const EngineState = enum { running, succeeded, failed, paused, cancelled };
/// A native outcome is not a release receipt. The original engine job remains
/// owned and occupies its concurrency slot until its actual IO is quiescent.
pub const JobCleanup = enum { awaiting, released, unknown };

/// Stable, protocol-independent failure classes exposed by transfer engines.
pub const Failure = enum {
    invalid_request,
    not_found,
    permission_denied,
    conflict,
    connection,
    timeout,
    checksum,
    protocol,
    io,
};

/// Value-only checksum diagnostics from the original engine attempt.
pub const Verification = struct {
    state: enum { pending, reading, repairing, passed, failed, unavailable },
    source_md5: ?[16]u8 = null,
    target_md5: ?[16]u8 = null,
    repair_count: u8 = 0,
    repair_start: ?u64 = null,
    repair_end: ?u64 = null,
};

/// Engine progress is cumulative. `done_bytes` must never decrease or exceed `total_bytes`.
pub const EngineProgress = struct {
    job: EngineJobId,
    done_bytes: u64,
    total_bytes: u64,
    speed_bps: u64 = 0,
    state: EngineState,
    retryable: bool = false,
    failure: ?Failure = null,
    job_cleanup: JobCleanup = .awaiting,
    verification: ?Verification = null,
    skipped_files: u32 = 0,
    skipped_bytes: u64 = 0,
    conflict_waiting: bool = false,
};

pub const TransferEngine = struct {
    ctx: *anyopaque,
    open: *const fn (*anyopaque, JobSpec) anyerror!EngineJobId,
    cancel: *const fn (*anyopaque, EngineJobId) void,
    pause: ?*const fn (*anyopaque, EngineJobId) anyerror!void = null,
    /// Accept a new engine job by exclusively handing off this exact paused
    /// entity. Ordinary rejection must leave the original entity unchanged.
    resume_job: ?*const fn (*anyopaque, EngineJobId) anyerror!EngineJobId = null,
    /// Published capability only; never perform metadata or network IO here.
    can_resume: ?*const fn (*anyopaque, EngineJobId) bool = null,
    conflict_snapshot: ?*const fn (*anyopaque, std.mem.Allocator, EngineJobId) anyerror!?Conflict.OwnedSnapshot = null,
    resolve_conflict: ?*const fn (*anyopaque, EngineJobId, Conflict.Request) anyerror!void = null,
    poll: *const fn (*anyopaque) ?EngineProgress,
};

pub const State = enum {
    queued,
    running,
    retry_wait,
    pausing,
    paused,
    succeeded,
    failed,
    cancelling,
    cancelled,
};

pub const Progress = struct {
    job: JobId,
    done_bytes: u64,
    total_bytes: u64,
    speed_bps: u64,
    state: State,
    attempt: u8,
    retry_at_ms: ?u64,
    failure: ?Failure,
    job_cleanup: JobCleanup = .awaiting,
    verification: ?Verification = null,
    skipped_files: u32 = 0,
    skipped_bytes: u64 = 0,
    conflict_waiting: bool = false,
};

pub const RetryPolicy = struct {
    /// Total engine open attempts, including the first one.
    max_attempts: u8 = 4,
    base_delay_ms: u64 = 1_000,
    max_delay_ms: u64 = 8_000,

    pub fn delay(self: RetryPolicy, failed_attempt: u8) ?u64 {
        if (failed_attempt >= self.max_attempts) return null;
        const shift: u6 = @intCast(@min(failed_attempt - 1, 63));
        return @min(self.base_delay_ms *| (@as(u64, 1) << shift), self.max_delay_ms);
    }
};

const OwnedSpec = struct {
    session_id: u64,
    transfer_binding: ?ServiceHandle,
    direction: Direction,
    sources: [][]u8,
    remote_dir: []u8,
    local_dir: []u8,
    rename: ?[]u8,
    resume_transfer: bool,
    md5_check: bool,
    notify_complete: bool,
    chunk_kb: u16,
    window_chunks: u8,
    pacing_kbps: u32,
    conflict_context: ?Conflict.Context,

    fn clone(allocator: std.mem.Allocator, spec: JobSpec) !OwnedSpec {
        const sources = try allocator.alloc([]u8, spec.sources.len);
        var initialized: usize = 0;
        errdefer {
            for (sources[0..initialized]) |source| allocator.free(source);
            allocator.free(sources);
        }
        for (spec.sources, 0..) |source, i| {
            sources[i] = try allocator.dupe(u8, source);
            initialized += 1;
        }
        const remote_dir = try allocator.dupe(u8, spec.remote_dir);
        errdefer allocator.free(remote_dir);
        const local_dir = try allocator.dupe(u8, spec.local_dir);
        errdefer allocator.free(local_dir);
        const rename = if (spec.rename) |value| try allocator.dupe(u8, value) else null;
        return .{
            .session_id = spec.session_id,
            .transfer_binding = spec.transfer_binding,
            .direction = spec.direction,
            .sources = sources,
            .remote_dir = remote_dir,
            .local_dir = local_dir,
            .rename = rename,
            .resume_transfer = spec.resume_transfer,
            .md5_check = spec.md5_check,
            .notify_complete = spec.notify_complete,
            .chunk_kb = spec.chunk_kb,
            .window_chunks = spec.window_chunks,
            .pacing_kbps = spec.pacing_kbps,
            .conflict_context = spec.conflict_context,
        };
    }

    fn deinit(self: *OwnedSpec, allocator: std.mem.Allocator) void {
        for (self.sources) |source| allocator.free(source);
        allocator.free(self.sources);
        allocator.free(self.remote_dir);
        allocator.free(self.local_dir);
        if (self.rename) |value| allocator.free(value);
        self.* = undefined;
    }

    fn view(self: OwnedSpec) JobSpec {
        return .{
            .session_id = self.session_id,
            .transfer_binding = self.transfer_binding,
            .direction = self.direction,
            .sources = self.sources,
            .remote_dir = self.remote_dir,
            .local_dir = self.local_dir,
            .rename = self.rename,
            .resume_transfer = self.resume_transfer,
            .md5_check = self.md5_check,
            .notify_complete = self.notify_complete,
            .chunk_kb = self.chunk_kb,
            .window_chunks = self.window_chunks,
            .pacing_kbps = self.pacing_kbps,
            .conflict_context = self.conflict_context,
        };
    }

    fn eql(self: OwnedSpec, other: JobSpec) bool {
        if (!std.meta.eql(self.conflict_context, other.conflict_context)) return false;
        if (self.session_id != other.session_id) return false;
        if (!std.meta.eql(self.transfer_binding, other.transfer_binding)) return false;
        if (self.chunk_kb != other.chunk_kb or self.window_chunks != other.window_chunks or self.pacing_kbps != other.pacing_kbps) return false;
        if (self.direction != other.direction or self.resume_transfer != other.resume_transfer or self.md5_check != other.md5_check or self.notify_complete != other.notify_complete or self.sources.len != other.sources.len) return false;
        if (!std.mem.eql(u8, self.remote_dir, other.remote_dir) or !std.mem.eql(u8, self.local_dir, other.local_dir)) return false;
        if ((self.rename == null) != (other.rename == null)) return false;
        if (self.rename) |name| if (!std.mem.eql(u8, name, other.rename.?)) return false;
        for (self.sources, other.sources) |left, right| if (!std.mem.eql(u8, left, right)) return false;
        return true;
    }
};

/// Bounded process-local receipts. Progress samples do not evict state changes.
pub const Event = struct {
    sequence: u64,
    timestamp_ms: ?u64,
    attempt: u8,
    state: State,
    cleanup: JobCleanup,
    failure: ?Failure,
    conflict_waiting: bool,
    verification: ?@FieldType(Verification, "state"),
    binding_wait: bool,
    done_bytes: u64,
    total_bytes: u64,
};
pub const event_capacity = 32;

const Job = struct {
    id: JobId,
    spec: OwnedSpec,
    state: State = .queued,
    engine_job: ?EngineJobId = null,
    attempt: u8 = 0,
    retry_at_ms: u64 = 0,
    done_bytes: u64 = 0,
    total_bytes: u64 = 0,
    speed_bps: u64 = 0,
    failure: ?Failure = null,
    has_progress: bool = false,
    job_cleanup: JobCleanup = .released,
    verification: ?Verification = null,
    skipped_files: u32 = 0,
    skipped_bytes: u64 = 0,
    conflict_waiting: bool = false,
    protocol_fault: bool = false,
    resume_pending: bool = false,
    retained_owner: ?identity.TransferOwner = null,
    binding_wait: bool = false,
    events: [event_capacity]Event = undefined,
    event_count: usize = 0,
    event_sequence: u64 = 0,

    fn record(self: *Job) void {
        const verification = if (self.verification) |value| value.state else null;
        if (self.event_count > 0) {
            const previous = self.events[self.event_count - 1];
            if (previous.attempt == self.attempt and previous.state == self.state and previous.cleanup == self.job_cleanup and previous.failure == self.failure and previous.conflict_waiting == self.conflict_waiting and previous.verification == verification and previous.binding_wait == self.binding_wait) return;
        }
        if (self.event_count == event_capacity) {
            std.mem.copyForwards(Event, self.events[0 .. event_capacity - 1], self.events[1..]);
            self.event_count -= 1;
        }
        var ts: std.c.timespec = undefined;
        const timestamp: ?u64 = if (std.c.clock_gettime(.REALTIME, &ts) == 0 and ts.sec >= 0) @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000 else null;
        self.event_sequence +|= 1;
        self.events[self.event_count] = .{ .sequence = self.event_sequence, .timestamp_ms = timestamp, .attempt = self.attempt, .state = self.state, .cleanup = self.job_cleanup, .failure = self.failure, .conflict_waiting = self.conflict_waiting, .verification = verification, .binding_wait = self.binding_wait, .done_bytes = self.done_bytes, .total_bytes = self.total_bytes };
        self.event_count += 1;
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    engine: TransferEngine,
    jobs: std.ArrayList(Job) = .empty,
    concurrency: u16,
    retry_policy: RetryPolicy,
    next_id: JobId = 1,

    pub fn init(allocator: std.mem.Allocator, engine: TransferEngine, concurrency: u16, retry_policy: RetryPolicy) !Manager {
        if (concurrency == 0 or concurrency > window_policy.max_concurrency or retry_policy.max_attempts == 0) return error.InvalidConfiguration;
        return .{ .allocator = allocator, .engine = engine, .concurrency = concurrency, .retry_policy = retry_policy };
    }

    pub fn deinit(self: *Manager) void {
        for (self.jobs.items) |*job| {
            if (job.engine_job) |engine_job| self.engine.cancel(self.engine.ctx, engine_job);
            job.spec.deinit(self.allocator);
        }
        self.jobs.deinit(self.allocator);
        self.* = undefined;
    }

    /// Returns the existing non-terminal job for an identical spec.
    pub fn enqueue(self: *Manager, spec: JobSpec) !JobId {
        if (spec.sources.len == 0) return error.NoSources;
        for (spec.sources) |source| if (source.len == 0) return error.EmptySource;
        if (spec.direction == .upload and spec.remote_dir.len == 0) return error.MissingRemoteDirectory;
        if (spec.direction == .download and spec.local_dir.len == 0) return error.MissingLocalDirectory;
        if (spec.rename) |rename| {
            if (rename.len == 0 or spec.sources.len != 1) return error.InvalidRename;
        }
        try window_policy.validateWindowPolicy(spec.chunk_kb, spec.window_chunks, self.concurrency);
        if (self.next_id == std.math.maxInt(JobId)) return error.JobIdExhausted;
        for (self.jobs.items) |job| {
            if ((!terminal(job.state) or job.engine_job != null) and job.spec.eql(spec)) return job.id;
        }
        const id = self.next_id;
        var owned = try OwnedSpec.clone(self.allocator, spec);
        errdefer owned.deinit(self.allocator);
        try self.jobs.append(self.allocator, .{ .id = id, .spec = owned });
        self.jobs.items[self.jobs.items.len - 1].record();
        self.next_id += 1;
        return id;
    }

    /// Queue the frozen intent while its independent connection authenticates.
    /// This consumes neither a concurrency slot nor an engine attempt.
    pub fn enqueueWaitingBinding(self: *Manager, spec: JobSpec) !JobId {
        if (spec.transfer_binding == null) return error.MissingTransferBinding;
        const id = try self.enqueue(spec);
        const job = self.find(id).?;
        defer job.record();
        if (job.attempt == 0 and job.engine_job == null) job.binding_wait = true;
        return id;
    }

    pub fn releaseBindingWait(self: *Manager, id: JobId, binding: ServiceHandle) !void {
        const job = self.find(id) orelse return error.UnknownJob;
        defer job.record();
        if (job.retained_owner != null or job.attempt != 0 or job.engine_job != null or job.spec.transfer_binding == null or !job.spec.transfer_binding.?.eql(binding)) return error.StaleBinding;
        if (job.state != .queued and job.state != .paused) return error.InvalidState;
        job.binding_wait = false;
    }

    /// An unstarted intent can retry authentication on a new binding of the
    /// same original owner. No paths/options or local endpoint are replaced.
    pub fn rebindWaitingDraft(self: *Manager, id: JobId, binding: ServiceHandle) !void {
        const job = self.find(id) orelse return error.UnknownJob;
        defer job.record();
        if (job.attempt != 0 or job.engine_job != null or job.retained_owner != null or job.state != .paused or job.job_cleanup != .released) return error.InvalidState;
        const previous = job.spec.transfer_binding orelse return error.MissingTransferBinding;
        if (binding.kind != .transfer or binding.binding_id == 0 or binding.binding_generation == 0 or binding.resource_owner != .session or !binding.resource_owner.eql(previous.resource_owner)) return error.TransferOwnerMismatch;
        if (!previous.eql(binding) and binding.binding_generation <= previous.binding_generation) return error.StaleBinding;
        const owner = binding.resource_owner.session;
        if (binding.origin_session == null or !binding.origin_session.?.eql(owner)) return error.TransferOwnerMismatch;
        if (job.spec.conflict_context) |*context| {
            if (!context.original_owner.eql(owner)) return error.TransferOwnerMismatch;
            for ([_]*@import("conflict.zig").Endpoint{ &context.source_endpoint, &context.target_endpoint }) |endpoint| switch (endpoint.*) {
                .sftp => |*remote| {
                    remote.binding_id = binding.binding_id;
                    remote.binding_generation = binding.binding_generation;
                    remote.resource_owner = binding.resource_owner;
                    remote.origin_session = owner;
                },
                else => {},
            };
        }
        job.spec.transfer_binding = binding;
        job.binding_wait = true;
        job.state = .queued;
    }

    /// Consume all pending engine events, then deterministically schedule FIFO work.
    pub fn tick(self: *Manager, now_ms: u64) void {
        while (self.engine.poll(self.engine.ctx)) |event| self.apply(event, now_ms);
        while (self.activeCount() < self.concurrency) {
            const index = self.nextRunnable(now_ms) orelse break;
            self.start(index, now_ms);
        }
    }

    pub fn pause(self: *Manager, id: JobId) !void {
        const job = self.find(id) orelse return error.UnknownJob;
        defer job.record();
        switch (job.state) {
            .queued, .retry_wait => {
                job.resume_pending = false;
                job.state = .paused;
            },
            .running => {
                const pause_engine = self.engine.pause orelse return error.UnsupportedPause;
                try pause_engine(self.engine.ctx, job.engine_job.?);
                job.state = .pausing;
                job.speed_bps = 0;
            },
            .pausing, .paused => {},
            else => return error.InvalidState,
        }
    }

    pub fn canResume(self: *const Manager, id: JobId) bool {
        for (self.jobs.items) |job| if (job.id == id) {
            if (job.state != .paused or job.job_cleanup != .released or job.attempt == std.math.maxInt(u8)) return false;
            if (job.engine_job) |engine_job| {
                if (self.engine.resume_job == null) return false;
                return if (self.engine.can_resume) |capable| capable(self.engine.ctx, engine_job) else false;
            }
            return true;
        };
        return false;
    }

    pub fn resumeJob(self: *Manager, id: JobId) !void {
        const job = self.find(id) orelse return error.UnknownJob;
        defer job.record();
        if (job.job_cleanup == .unknown) return error.CleanupUnknown;
        if (job.job_cleanup != .released) return error.CleanupPending;
        if (job.state != .paused) return error.InvalidState;
        if (job.retained_owner != null and job.engine_job == null) return error.RetainedAuthenticationRequired;
        if (job.attempt == std.math.maxInt(u8)) return error.AttemptExhausted;
        if (job.engine_job != null) {
            if (!self.canResume(id)) return error.UnsupportedResume;
            // Keep the original ID and entity until FIFO scheduling actually
            // accepts the handoff. Cancel/pause while queued still address it.
            job.resume_pending = true;
        }
        job.state = .queued;
    }

    /// Requeues a terminal failed job while preserving its cumulative progress.
    pub fn retry(self: *Manager, id: JobId) !void {
        const job = self.find(id) orelse return error.UnknownJob;
        defer job.record();
        try requireReleased(job);
        if (job.state != .failed) return error.InvalidState;
        if (job.failure == .checksum) return error.ReviewRequired;
        if (job.attempt == std.math.maxInt(u8)) return error.AttemptExhausted;
        job.state = .queued;
        job.retry_at_ms = 0;
        job.speed_bps = 0;
        job.failure = null;
    }

    pub fn cancel(self: *Manager, id: JobId) !void {
        const job = self.find(id) orelse return error.UnknownJob;
        defer job.record();
        if (job.retained_owner != null and job.engine_job == null and job.state != .cancelled) return error.RetainedCleanupRequired;
        if (job.state == .cancelling or job.state == .cancelled) return;
        job.resume_pending = false;
        if (job.engine_job) |engine_job| {
            self.engine.cancel(self.engine.ctx, engine_job);
            job.state = .cancelling;
            if (job.job_cleanup == .released) job.job_cleanup = .awaiting;
        } else {
            if (terminal(job.state)) return error.InvalidState;
            job.state = .cancelled;
        }
        job.speed_bps = 0;
    }

    /// Snapshot/decisions always route through this exact active attempt.
    pub fn conflictSnapshot(self: *Manager, allocator: std.mem.Allocator, id: JobId) !?Conflict.OwnedSnapshot {
        const job = self.find(id) orelse return error.UnknownJob;
        defer job.record();
        if (job.state != .running or !job.conflict_waiting) return null;
        const engine_id = job.engine_job orelse return null;
        const call = self.engine.conflict_snapshot orelse return error.UnsupportedConflict;
        var result = (try call(self.engine.ctx, allocator, engine_id)) orelse return null;
        var expected = job.spec.conflict_context;
        if (expected) |*context| {
            context.job = job.id;
            context.attempt = job.attempt;
        }
        if (result.value.engine_job != engine_id or !std.meta.eql(result.value.context, expected)) {
            result.deinit();
            return error.EngineProtocolFault;
        }
        return result;
    }

    pub fn resolveConflict(self: *Manager, id: JobId, request: Conflict.Request) !void {
        const job = self.find(id) orelse return error.UnknownJob;
        defer job.record();
        const key = request.key();
        if (job.state != .running or !job.conflict_waiting or key.job != job.id or key.attempt != job.attempt) return error.StaleConflict;
        const context = job.spec.conflict_context orelse return error.MissingConflictContext;
        if (key.intent_id != context.intent_id or !std.meta.eql(key.owner, context.resource_owner) or !std.meta.eql(key.original_owner, context.original_owner)) return error.StaleConflict;
        const engine_id = job.engine_job orelse return error.StaleConflict;
        const call = self.engine.resolve_conflict orelse return error.UnsupportedConflict;
        try call(self.engine.ctx, engine_id, request);
    }

    pub fn progress(self: *const Manager, id: JobId) ?Progress {
        for (self.jobs.items) |job| if (job.id == id) return snapshot(job);
        return null;
    }

    /// Borrowed until the next mutation. UI projections must copy the receipts.
    pub fn eventHistory(self: *const Manager, id: JobId) ?[]const Event {
        for (self.jobs.items) |*job| if (job.id == id) return job.events[0..job.event_count];
        return null;
    }

    pub fn sessionId(self: *const Manager, id: JobId) ?u64 {
        for (self.jobs.items) |job| if (job.id == id) return job.spec.session_id;
        return null;
    }

    pub fn transferBinding(self: *const Manager, id: JobId) ?ServiceHandle {
        for (self.jobs.items) |job| if (job.id == id) return job.spec.transfer_binding;
        return null;
    }

    pub fn engineJob(self: *const Manager, id: JobId) ?EngineJobId {
        for (self.jobs.items) |job| if (job.id == id) return job.engine_job;
        return null;
    }
    pub fn retainedOwner(self: *const Manager, id: JobId) ?identity.TransferOwner {
        for (self.jobs.items) |job| if (job.id == id) return job.retained_owner;
        return null;
    }
    /// Called only after the host owns the actual exported checkpoint and has
    /// retired its exact proxy route. This does not delete or copy that payload.
    pub fn retainPaused(self: *Manager, id: JobId, attempt: u8, expected_engine: ?EngineJobId, owner: identity.TransferOwner) !void {
        const job = self.find(id) orelse return error.UnknownJob;
        defer job.record();
        if (job.attempt != attempt or job.state != .paused or job.job_cleanup != .released or job.protocol_fault or job.resume_pending) return error.CheckpointNotReleased;
        if (@backingInt(owner.id) == 0 or @backingInt(owner.original_handle.session_id) != job.spec.session_id) return error.TransferOwnerMismatch;
        if (job.retained_owner) |existing| {
            if (!std.meta.eql(existing, owner)) return error.TransferOwnerMismatch;
            if (job.engine_job == null) return;
        }
        if (job.engine_job != expected_engine) return error.StaleAttempt;
        if (job.spec.conflict_context) |context| if (!context.original_owner.eql(owner.original_handle)) return error.TransferOwnerMismatch;
        job.engine_job = null;
        job.retained_owner = owner;
        job.binding_wait = false;
        job.conflict_waiting = false;
        job.speed_bps = 0;
    }

    pub fn queueRetainedResume(self: *Manager, id: JobId, attempt: u8, owner: identity.TransferOwner) !void {
        const job = self.find(id) orelse return error.UnknownJob;
        defer job.record();
        if (job.attempt != attempt or job.retained_owner == null or !std.meta.eql(job.retained_owner.?, owner)) return error.StaleAttempt;
        if (job.engine_job != null or job.state != .paused or job.job_cleanup != .released) return error.InvalidState;
        if (attempt == std.math.maxInt(u8)) return error.AttemptExhausted;
        job.state = .queued;
    }

    pub fn canAcceptRetainedResume(self: *const Manager, id: JobId, attempt: u8) bool {
        for (self.jobs.items) |job| if (job.id == id) return job.attempt == attempt and job.retained_owner != null and job.engine_job == null and job.state == .queued and job.job_cleanup == .released and self.activeCount() < self.concurrency and self.fitsWindowBudget(job.spec);
        return false;
    }

    /// The host reserves routes and imports before acknowledging this new
    /// entity. Every rejection before import leaves the original payload owned.
    /// Borrowed frozen values; no asset/current-session reconstruction.
    pub fn retainedSpec(self: *const Manager, id: JobId, attempt: u8) ?JobSpec {
        for (self.jobs.items) |job| if (job.id == id and job.attempt == attempt and job.retained_owner != null) return job.spec.view();
        return null;
    }

    pub fn validateRetainedResume(self: *const Manager, id: JobId, attempt: u8, imported_spec: JobSpec) !void {
        if (!self.canAcceptRetainedResume(id, attempt)) return error.RetainedResumeNotReady;
        const job = for (self.jobs.items) |value| {
            if (value.id == id) break value;
        } else return error.UnknownJob;
        const owner = job.retained_owner.?;
        const binding = imported_spec.transfer_binding orelse return error.MissingTransferBinding;
        if (binding.binding_id == 0 or binding.binding_generation == 0 or binding.kind != .transfer or binding.resource_owner != .retained_transfer or binding.resource_owner.retained_transfer != owner.id or binding.origin_session == null or !binding.origin_session.?.eql(owner.original_handle)) return error.TransferOwnerMismatch;
        var comparable = imported_spec;
        comparable.transfer_binding = job.spec.transfer_binding;
        comparable.conflict_context = job.spec.conflict_context;
        if (!job.spec.eql(comparable)) return error.RetainedSourceChanged;
        if (job.spec.transfer_binding) |previous| {
            if (previous.resource_owner == .retained_transfer and previous.resource_owner.retained_transfer == owner.id and binding.binding_generation <= previous.binding_generation) return error.StaleBinding;
        }
        if (imported_spec.conflict_context) |context| {
            if (job.spec.conflict_context) |previous| if (context.intent_id != previous.intent_id) return error.RetainedSourceChanged;
            if (context.job != id or context.attempt != @as(u32, attempt) + 1 or !context.original_owner.eql(owner.original_handle) or !context.resource_owner.eql(binding.resource_owner)) return error.TransferOwnerMismatch;
        } else if (job.spec.conflict_context != null) return error.MissingConflictContext;
    }

    pub fn acceptRetainedResume(self: *Manager, id: JobId, attempt: u8, imported_spec: JobSpec, engine_id: EngineJobId) !void {
        try self.validateRetainedResume(id, attempt, imported_spec);
        if (engine_id == 0) return error.EngineProtocolFault;
        for (self.jobs.items) |other| if (other.engine_job == engine_id) return error.EngineProtocolFault;
        const job = self.find(id).?;
        defer job.record();
        const binding = imported_spec.transfer_binding.?;
        job.spec.transfer_binding = binding;
        job.spec.conflict_context = imported_spec.conflict_context;
        job.engine_job = engine_id;
        job.attempt += 1;
        job.state = .running;
        job.job_cleanup = .awaiting;
        job.has_progress = false;
        job.protocol_fault = false;
        job.failure = null;
        job.verification = null;
        job.conflict_waiting = false;
    }

    pub fn retainedCancelReceipt(self: *Manager, id: JobId, attempt: u8, owner: identity.TransferOwner, cleanup: JobCleanup) !void {
        const job = self.find(id) orelse return error.UnknownJob;
        defer job.record();
        if (job.attempt != attempt or job.retained_owner == null or !std.meta.eql(job.retained_owner.?, owner) or job.engine_job != null or terminal(job.state)) return error.StaleAttempt;
        job.state = if (cleanup == .released) .cancelled else .cancelling;
        if (job.job_cleanup != .unknown or cleanup == .released) job.job_cleanup = cleanup;
        job.speed_bps = 0;
    }

    /// Check before requeueing work onto an attached connection.
    pub fn validateSession(self: *const Manager, id: JobId, session_id: u64) !void {
        const owner = self.sessionId(id) orelse return error.UnknownJob;
        if (owner != session_id) return error.TransferSessionMismatch;
    }

    /// UI 只读访问器（按入队顺序）：进度快照与首个源名，供状态栏进度行。
    pub fn progressAt(self: *const Manager, index: usize) ?Progress {
        if (index >= self.jobs.items.len) return null;
        return snapshot(self.jobs.items[index]);
    }

    pub fn sourceName(self: *const Manager, index: usize) ?[]const u8 {
        if (index >= self.jobs.items.len) return null;
        const sources = self.jobs.items[index].spec.sources;
        if (sources.len == 0) return null;
        return sources[0];
    }

    pub fn count(self: *const Manager) usize {
        return self.jobs.items.len;
    }

    fn activeCount(self: *const Manager) u16 {
        var count_: u16 = 0;
        for (self.jobs.items) |job| if (job.engine_job != null and job.job_cleanup != .released) {
            count_ +|= 1;
        };
        return count_;
    }

    fn fitsWindowBudget(self: *const Manager, candidate: OwnedSpec) bool {
        var used: u64 = 0;
        for (self.jobs.items) |job| if (job.engine_job != null and job.job_cleanup != .released) {
            const bytes = window_policy.windowBytes(job.spec.chunk_kb, job.spec.window_chunks) catch return false;
            used = std.math.add(u64, used, bytes) catch return false;
        };
        const requested = window_policy.windowBytes(candidate.chunk_kb, candidate.window_chunks) catch return false;
        const next = std.math.add(u64, used, requested) catch return false;
        return next <= window_policy.max_global_window_bytes;
    }

    fn nextRunnable(self: *Manager, now_ms: u64) ?usize {
        for (self.jobs.items, 0..) |job, i| {
            if (job.binding_wait or (job.retained_owner != null and job.engine_job == null)) continue;
            if (job.state == .queued or (job.state == .retry_wait and job.retry_at_ms <= now_ms)) {
                // New concurrency settings cannot multiply older frozen
                // policies beyond the global budget. Preserve FIFO while IO
                // is awaiting/unknown; only its real release frees capacity.
                return if (self.fitsWindowBudget(job.spec)) i else null;
            }
        }
        return null;
    }

    fn start(self: *Manager, index: usize, now_ms: u64) void {
        const job = &self.jobs.items[index];
        defer job.record();
        if (job.resume_pending) {
            self.startResume(job);
            return;
        }
        if (job.attempt == std.math.maxInt(u8)) {
            job.state = .failed;
            job.failure = .invalid_request;
            return;
        }
        job.verification = null;
        job.skipped_files = 0;
        job.skipped_bytes = 0;
        job.conflict_waiting = false;
        job.attempt += 1;
        var engine_spec = job.spec.view();
        if (engine_spec.conflict_context) |*context| {
            context.job = job.id;
            context.attempt = job.attempt;
        }
        const result = self.engine.open(self.engine.ctx, engine_spec);
        if (result) |engine_job| {
            job.engine_job = engine_job;
            job.state = .running;
            job.failure = null;
            job.job_cleanup = .awaiting;
            job.protocol_fault = false;
            // Counters are monotone within an engine attempt. A newly
            // accepted attempt may restart from a revalidated earlier offset.
            job.has_progress = false;
        } else |_| {
            job.failure = .connection;
            self.scheduleRetry(job, now_ms);
        }
    }

    fn startResume(self: *Manager, job: *Job) void {
        const original = job.engine_job.?;
        const resume_engine = self.engine.resume_job orelse {
            resumeRejected(job, error.UnsupportedResume);
            return;
        };
        const capable = self.engine.can_resume orelse {
            resumeRejected(job, error.UnsupportedResume);
            return;
        };
        if (!capable(self.engine.ctx, original)) {
            resumeRejected(job, error.UnsupportedResume);
            return;
        }
        const accepted = resume_engine(self.engine.ctx, original) catch |err| {
            if (err == error.EngineProtocolFault) {
                self.resumeProtocolFault(job, original);
            } else resumeRejected(job, err);
            return;
        };
        if (accepted == original) {
            self.resumeProtocolFault(job, original);
            return;
        }
        job.resume_pending = false;
        job.verification = null;
        job.skipped_files = 0;
        job.skipped_bytes = 0;
        job.conflict_waiting = false;
        job.attempt += 1;
        job.engine_job = accepted;
        job.state = .running;
        job.job_cleanup = .awaiting;
        job.failure = null;
        job.protocol_fault = false;
        job.has_progress = false;
    }

    fn resumeProtocolFault(self: *Manager, job: *Job, original: EngineJobId) void {
        // A backend may already have accepted an ambiguously named entity.
        // Preserve ownership and quarantine it, rather than reopen another one.
        job.resume_pending = false;
        job.protocol_fault = true;
        job.state = .cancelling;
        job.job_cleanup = .unknown;
        job.failure = .protocol;
        self.engine.cancel(self.engine.ctx, original);
    }

    fn apply(self: *Manager, event: EngineProgress, now_ms: u64) void {
        const job = self.findEngine(event.job) orelse return; // retired attempt
        defer job.record();
        if (job.protocol_fault) {
            if (event.job_cleanup == .unknown) job.job_cleanup = .unknown;
            // Keep the original mapping even after invalid progress. Only a
            // subsequent explicit quiescent outcome releases that ownership.
            if (event.state == .paused) {
                if (event.job_cleanup == .released) job.job_cleanup = .awaiting;
            } else if (event.state != .running and event.job_cleanup == .released) {
                job.engine_job = null;
                job.job_cleanup = .released;
                job.state = .failed;
            }
            return;
        }
        const accounted = std.math.add(u64, event.done_bytes, event.skipped_bytes) catch null;
        if (accounted == null or accounted.? > event.total_bytes or
            (job.has_progress and (event.skipped_bytes < job.skipped_bytes or event.skipped_files < job.skipped_files)) or
            (job.has_progress and (event.done_bytes < job.done_bytes or event.total_bytes != job.total_bytes)) or
            (event.state == .running and event.job_cleanup == .released) or
            ((job.state == .paused or job.resume_pending) and job.job_cleanup == .released and event.state == .running) or
            (event.state == .succeeded and (accounted.? != event.total_bytes or event.conflict_waiting)))
        {
            self.engine.cancel(self.engine.ctx, event.job);
            job.protocol_fault = true;
            job.resume_pending = false;
            job.state = .cancelling;
            job.job_cleanup = if (event.job_cleanup == .unknown) .unknown else .awaiting;
            job.speed_bps = 0;
            job.failure = .protocol;
            return;
        }
        // The old paused worker may still have an already published receipt.
        // It cannot revoke a queued, not-yet-accepted resume intention.
        if (job.resume_pending and event.state == .paused and event.job_cleanup == .released) return;
        job.resume_pending = false;
        const stopping = job.state == .pausing or job.state == .cancelling;
        // A paused receipt already queued before a cancel upgrade cannot
        // acknowledge the later cancellation or its temporary-file policy.
        const cancelled_after_pause = job.state == .cancelling and event.state == .paused;
        job.verification = event.verification;
        job.skipped_files = event.skipped_files;
        job.skipped_bytes = event.skipped_bytes;
        job.conflict_waiting = event.conflict_waiting;
        job.done_bytes = event.done_bytes;
        job.total_bytes = event.total_bytes;
        job.speed_bps = if (stopping) 0 else event.speed_bps;
        job.has_progress = true;
        if (job.job_cleanup != .unknown or event.job_cleanup == .released) job.job_cleanup = event.job_cleanup;
        if (cancelled_after_pause) {
            if (job.job_cleanup != .unknown) job.job_cleanup = .awaiting;
            return;
        }
        if (event.state == .running) return;
        if (event.job_cleanup != .released) {
            if (event.state == .failed) {
                job.failure = event.failure orelse .io;
                if (!stopping) job.state = .failed;
            } else if (!stopping) switch (event.state) {
                .paused => job.state = .pausing,
                .cancelled => job.state = .cancelling,
                else => {},
            };
            job.speed_bps = 0;
            return;
        }
        // IO is quiescent after pause, but its original ID still owns retained
        // data and must remain addressable for a later explicit cancel.
        if (event.state != .paused) job.engine_job = null;
        job.speed_bps = 0;
        switch (event.state) {
            .running => unreachable,
            .succeeded => {
                job.state = .succeeded;
                job.failure = null;
            },
            .failed => {
                job.failure = event.failure orelse .io;
                if (event.retryable and !stopping) self.scheduleRetry(job, now_ms) else job.state = .failed;
            },
            .paused => {
                job.state = .paused;
                job.failure = event.failure;
            },
            .cancelled => job.state = .cancelled,
        }
    }

    fn scheduleRetry(self: *Manager, job: *Job, now_ms: u64) void {
        if (self.retry_policy.delay(job.attempt)) |delay_ms| {
            job.state = .retry_wait;
            job.retry_at_ms = now_ms +| delay_ms;
        } else {
            job.state = .failed;
        }
    }

    fn find(self: *Manager, id: JobId) ?*Job {
        for (self.jobs.items) |*job| if (job.id == id) return job;
        return null;
    }

    fn findEngine(self: *Manager, id: EngineJobId) ?*Job {
        for (self.jobs.items) |*job| if (job.engine_job != null and job.engine_job.? == id) return job;
        return null;
    }
};

fn requireReleased(job: *const Job) !void {
    if (job.job_cleanup == .unknown) return error.CleanupUnknown;
    if (job.engine_job != null or job.job_cleanup != .released) return error.CleanupPending;
}

fn resumeRejected(job: *Job, err: anyerror) void {
    job.resume_pending = false;
    job.state = .paused;
    job.speed_bps = 0;
    job.failure = if (err == error.UnsupportedResume) .invalid_request else .connection;
}

fn terminal(state: State) bool {
    return state == .succeeded or state == .failed or state == .cancelled;
}

fn snapshot(job: Job) Progress {
    return .{
        .job = job.id,
        .done_bytes = job.done_bytes,
        .total_bytes = job.total_bytes,
        .speed_bps = job.speed_bps,
        .state = job.state,
        .attempt = job.attempt,
        .retry_at_ms = if (job.state == .retry_wait) job.retry_at_ms else null,
        .failure = job.failure,
        .job_cleanup = job.job_cleanup,
        .verification = job.verification,
        .skipped_files = job.skipped_files,
        .skipped_bytes = job.skipped_bytes,
        .conflict_waiting = job.conflict_waiting,
    };
}
