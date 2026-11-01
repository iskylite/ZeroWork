//! One background owner advances execution, waits, durable journal receipts and
//! lease renewal independently of the provider. UI/native mailbox calls cross
//! the supplied scheduler; this thread never reads Cx or SessionHost directly.
const std = @import("std");
const execution = @import("host_execution.zig");
const host = @import("host_tools.zig");
const terminal = @import("../host/terminal_service.zig");
const identity = @import("../host/identity.zig");
const lifecycle = @import("lifecycle_runtime.zig");
const provider = @import("provider.zig");
const queries = @import("host_terminal_queries.zig");
const Wakeup = @import("../platform/wakeup.zig").Wakeup;
const capacity = 32;
/// Cached owner-thread facts. A missing/busy snapshot is never an idle proof.
pub const TaskEvidence = struct {
    conversation_id: identity.ConversationId,
    task_id: identity.TaskId,
    revision: u64 = 1,
    model_done: bool = false,
    execution_count: usize = 0,
    active_executions: usize = 0,
    /// Still-running read-only observations whose input belongs to the user.
    handed_off_observers: usize = 0,
    awaiting_input: bool = false,
    pending_dispatch: usize = 0,
    pending_waits: usize = 0,
    cleanup_pending: bool = false,
    executions_settled: bool = true,
    /// Only input/control responsibility. Total execution/record facts above
    /// remain unsettled while a handed-off foreground continues to run.
    controlled_executions_settled: bool = true,
    input_grants_released: bool = true,
    recordings_settled: bool = true,
    remote_effect_unknown: bool = false,
    /// An observed PTY interval cannot prove exclusive output ownership or
    /// confirmed idle, even when no concurrent owner was observed.
    output_attribution_unverified: bool = false,
    pending_external_jobs: bool = false,
    active_references: usize = 0,
};
pub const TargetEvidence = struct {
    target: identity.SessionHandle,
    revision: u64 = 1,
    execution_count: usize = 0,
    active_executions: usize = 0,
    pending_dispatch: usize = 0,
    input_grants_released: bool = true,
    recordings_settled: bool = true,
    remote_effect_unknown: bool = false,
    output_attribution_unverified: bool = false,
};
/// Facts for one original execution, never inferred from a successor's epoch.
/// A terminal execution without input_handed_off cannot confirm user takeover.
pub const ExecutionInputEvidence = struct {
    execution_id: identity.ExecutionId,
    target: identity.SessionHandle,
    revision: u64 = 1,
    state: terminal.execution.State,
    terminal: bool,
    input_handed_off: bool,
    local_released: bool,
    input_ready: bool,
    has_grant: bool,
};
const ExecutionInputRecord = struct {
    conversation_id: identity.ConversationId,
    task_id: identity.TaskId,
    value: ExecutionInputEvidence,
};
const CommandRecord = struct {
    conversation_id: identity.ConversationId,
    target: identity.SessionHandle,
    execution_id: identity.ExecutionId,
    command: []const u8,
    submitted_at_ms: i64,
    revision: u64,
    verified: bool,
    exit_code: ?i32,
    complete: bool,
};
const Request = struct {
    kind: union(enum) { execute: host.Invocation, stop_task: host.Context, finish_task: host.Context, takeover_task: host.Context, stop_target: struct { context: host.Context, target: identity.SessionHandle }, stop_execution: struct { context: host.Context, reference: [128]u8, length: usize }, takeover: struct { context: host.Context, reference: [128]u8, length: usize } },
    completed: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),
    cancel: ?*provider.CancelToken = null,
    wake: ?Wakeup = null,
    detached: bool = false,
    wait: ?execution.Wait = null,
    deadline: i64 = 0,
    result: ?host.Result = null,
    failure: ?anyerror = null,
};
pub const Driver = struct {
    allocator: std.mem.Allocator,
    /// Independently retained until the background owner exits.
    journal_owner: *lifecycle.ProcessJournal,
    scheduler: lifecycle.Scheduler,
    backend: execution.Backend,
    controller: execution.Controller,
    mutex: std.atomic.Mutex = .unlocked,
    queue: [capacity]?*Request = @splat(null),
    read_index: usize = 0,
    write_index: usize = 0,
    queued: usize = 0,
    waiting: [capacity]?*Request = @splat(null),
    wake: Wakeup,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),
    work: std.atomic.Value(usize) = .init(0),
    callers: std.atomic.Value(usize) = .init(0),
    scheduler_cancel: provider.CancelToken = .{},
    active_request: ?*Request = null,
    evidence_mutex: std.atomic.Mutex = .unlocked,
    evidence: [128]?TaskEvidence = @splat(null),
    target_evidence: [128]?TargetEvidence = @splat(null),
    execution_input_evidence: [128]?ExecutionInputRecord = @splat(null),
    closing_targets: [128]?identity.SessionHandle = @splat(null),
    command_records: [128]?CommandRecord = @splat(null),

    /// Configuration/acquisition itself performs no journal IO. The caller's
    /// allocator must support calls from the owner and UI scheduler threads;
    /// page_allocator is suitable. Returned Results use this same allocator.
    pub fn start(allocator: std.mem.Allocator, journal_owner: *lifecycle.ProcessJournal, scheduler: lifecycle.Scheduler, backend: execution.Backend) !*Driver {
        const retained = try lifecycle.ProcessJournal.acquire(.{ .data_root = journal_owner.data_root, .path = journal_owner.path });
        errdefer retained.release();
        const self = try allocator.create(Driver);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .journal_owner = retained, .scheduler = scheduler, .backend = backend, .controller = undefined, .wake = try Wakeup.init() };
        errdefer self.wake.deinit();
        self.controller = execution.Controller.initWithJournal(allocator, execution.JournalAccess.from(lifecycle.ProcessJournal, retained), .{ .context = self, .authorize = authorize, .resolve = resolve, .handed_to_user = handedToUser, .terminal_call = terminalCall, .should_cancel = shouldCancel, .authorize_input = authorizeInput, .request_secret = requestSecret, .authorize_read = authorizeRead });
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    /// Called by a tool worker, outside Bridge/UI locks. Invocation strings and
    /// JSON stay borrowed until this call returns. Cancellation still waits for
    /// the owner acknowledgment, so no callback can use a freed request arena.
    pub fn execute(self: *Driver, invocation: host.Invocation, cancel: ?*provider.CancelToken) !host.Result {
        _ = self.callers.fetchAdd(1, .acq_rel);
        defer _ = self.callers.fetchSub(1, .release);
        var request: Request = .{ .kind = .{ .execute = invocation }, .cancel = cancel, .wake = try Wakeup.init(), .deadline = now() + 30_000 };
        defer request.wake.?.deinit();
        try self.enqueue(&request);
        while (!request.completed.load(.acquire)) {
            if (cancel) |token| if (token.isCancelled()) {
                request.cancelled.store(true, .release);
                self.wake.notify();
            };
            request.wake.?.wait(-1, false, 50);
        }
        if (request.failure) |failure| return failure;
        return request.result orelse error.InvalidControllerReceipt;
    }
    /// Transfer the immutable response into the tool loop's own allocator.
    /// The outer caller reference covers the clone too, so finish() cannot
    /// free Driver while this method still needs its allocation owner.
    pub fn executeAlloc(self: *Driver, invocation: host.Invocation, allocator: std.mem.Allocator, cancel: ?*provider.CancelToken) !host.Result {
        _ = self.callers.fetchAdd(1, .acq_rel);
        defer _ = self.callers.fetchSub(1, .release);
        var original = try self.execute(invocation, cancel);
        defer original.deinit(self.allocator);
        const blocks = try allocator.alloc(host.Block, original.blocks.len);
        var count: usize = 0;
        errdefer {
            for (blocks[0..count]) |block| switch (block) {
                .text, .structured => |text| allocator.free(text),
            };
            allocator.free(blocks);
        }
        for (original.blocks, blocks) |block, *copy| {
            copy.* = switch (block) {
                .text => |text| .{ .text = try allocator.dupe(u8, text) },
                .structured => |text| .{ .structured = try allocator.dupe(u8, text) },
            };
            count += 1;
        }
        var result = original;
        result.blocks = blocks;
        return result;
    }
    /// UI-safe nonblocking stop request. Queue admission is not native input
    /// release or process exit; taskEvidence/targetEvidence supply release facts.
    pub fn stopTask(self: *Driver, context: host.Context) !void {
        const request = try self.allocator.create(Request);
        errdefer self.allocator.destroy(request);
        request.* = .{ .kind = .{ .stop_task = context }, .detached = true };
        try self.enqueue(request);
    }
    /// Compatibility mailbox for Controller's unique-live-target check. UI
    /// uses requestTakeover(context, reference) to choose the exact execution.
    /// This does not finish/cancel the Task. Queue admission is not release;
    /// taskEvidence/targetEvidence remain the source of the actual drain fact.
    pub fn takeoverTask(self: *Driver, context: host.Context) !void {
        const request = try self.allocator.create(Request);
        errdefer self.allocator.destroy(request);
        request.* = .{ .kind = .{ .takeover_task = context }, .detached = true };
        try self.enqueue(request);
    }
    pub fn stopTarget(self: *Driver, context: host.Context, target: identity.SessionHandle) !void {
        const request = try self.allocator.create(Request);
        errdefer self.allocator.destroy(request);
        request.* = .{ .kind = .{ .stop_target = .{ .context = context, .target = target } }, .detached = true };
        try self.enqueue(request);
    }
    /// Immutable bounded deep copy of actual submitted command facts. Command
    /// strings belong to the Controller and are never expanded with input text.
    pub fn commandIndex(self: *Driver, allocator: std.mem.Allocator, conversation_id: identity.ConversationId, target: identity.SessionHandle) !queries.CommandSnapshot {
        _ = self.callers.fetchAdd(1, .acq_rel);
        defer _ = self.callers.fetchSub(1, .release);
        if (!self.evidence_mutex.tryLock()) return error.WorkerBusy;
        defer self.evidence_mutex.unlock();
        var records: std.ArrayList(queries.Command) = .empty;
        errdefer {
            for (records.items) |record| {
                allocator.free(record.reference);
                allocator.free(record.submitted_command);
            }
            records.deinit(allocator);
        }
        var hash = std.hash.Wyhash.init(0);
        for (self.command_records) |item| if (item) |record| {
            if (!record.conversation_id.eql(conversation_id) or !record.target.eql(target)) continue;
            const reference = try std.fmt.allocPrint(allocator, "c1:{s}:{d}:{d}:{s}", .{ std.fmt.bytesToHex(conversation_id.bytes, .lower), @backingInt(target.session_id), target.generation, std.fmt.bytesToHex(record.execution_id.bytes, .lower) });
            errdefer allocator.free(reference);
            const command = try allocator.dupe(u8, record.command);
            errdefer allocator.free(command);
            try records.append(allocator, .{ .reference = reference, .submitted_command = command, .execution_id = record.execution_id, .submitted_at_ms = if (record.submitted_at_ms > 0) record.submitted_at_ms else null, .verified = record.verified, .exit_code = record.exit_code, .complete = record.complete });
            hash.update(reference);
            hash.update(std.mem.asBytes(&record.revision));
        };
        return .{ .records = try records.toOwnedSlice(allocator), .revision = @max(1, hash.final()) };
    }
    pub fn targetEvidence(self: *Driver, target: identity.SessionHandle) ?TargetEvidence {
        if (!self.evidence_mutex.tryLock()) return null;
        defer self.evidence_mutex.unlock();
        for (self.target_evidence) |value| if (value) |fact| if (fact.target.eql(target)) return fact;
        return null;
    }
    pub fn finishTask(self: *Driver, context: host.Context) !void {
        const request = try self.allocator.create(Request);
        errdefer self.allocator.destroy(request);
        request.* = .{ .kind = .{ .finish_task = context }, .detached = true };
        try self.enqueue(request);
    }
    pub fn taskEvidence(self: *Driver, task_id: identity.TaskId) ?TaskEvidence {
        if (!self.evidence_mutex.tryLock()) return null;
        defer self.evidence_mutex.unlock();
        for (self.evidence) |value| if (value) |fact| if (fact.task_id.eql(task_id)) return fact;
        return null;
    }
    pub fn taskEvidenceFor(self: *Driver, context: host.Context) ?TaskEvidence {
        const fact = self.taskEvidence(context.task_id) orelse return null;
        return if (fact.conversation_id.eql(context.conversation_id)) fact else null;
    }
    /// UI-safe bounded copy. null means busy/unregistered, never confirmation.
    /// Binding revisions may move; the original CID/Task/Exec identity cannot.
    pub fn executionInputEvidence(self: *Driver, context: host.Context, id: identity.ExecutionId) ?ExecutionInputEvidence {
        if (!self.evidence_mutex.tryLock()) return null;
        defer self.evidence_mutex.unlock();
        for (self.execution_input_evidence) |item| if (item) |record| {
            if (record.conversation_id.eql(context.conversation_id) and record.task_id.eql(context.task_id) and record.value.execution_id.eql(id)) return record.value;
        };
        return null;
    }
    pub fn requestTakeover(self: *Driver, context: host.Context, reference: []const u8) !void {
        if (reference.len == 0 or reference.len > 128) return error.InvalidArguments;
        const request = try self.allocator.create(Request);
        errdefer self.allocator.destroy(request);
        request.* = .{ .kind = .{ .takeover = .{ .context = context, .reference = undefined, .length = reference.len } }, .detached = true };
        @memcpy(request.kind.takeover.reference[0..reference.len], reference);
        try self.enqueue(request);
    }
    /// Stop only the referenced execution while it still owns the current
    /// native input grant. An old card never authorizes stopping a later run.
    /// Queue admission is not a process-exit or input-release receipt.
    pub fn requestStopExecution(self: *Driver, context: host.Context, reference: []const u8) !void {
        if (reference.len == 0 or reference.len > 128) return error.InvalidArguments;
        const request = try self.allocator.create(Request);
        errdefer self.allocator.destroy(request);
        request.* = .{ .kind = .{ .stop_execution = .{ .context = context, .reference = undefined, .length = reference.len } }, .detached = true };
        @memcpy(request.kind.stop_execution.reference[0..reference.len], reference);
        try self.enqueue(request);
    }
    pub fn hasWork(self: *const Driver) bool {
        return self.work.load(.acquire) != 0;
    }
    pub fn shutdownReady(self: *const Driver) bool {
        return self.finished.load(.acquire) and self.callers.load(.acquire) == 0;
    }
    pub fn requestShutdown(self: *Driver) void {
        self.stopping.store(true, .release);
        // Cancels a scheduler wait when UI teardown can no longer pump it.
        self.scheduler_cancel.cancel();
        self.wake.notify();
    }
    /// Never joins a running owner. Call after requestShutdown while continuing
    /// the normal UI pump, or poll until it succeeds. No self-join path exists.
    pub fn finish(self: *Driver) !void {
        if (!self.shutdownReady()) return error.WorkerRunning;
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.wake.deinit();
        self.allocator.destroy(self);
    }
    fn lock(self: *Driver) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    fn enqueue(self: *Driver, request: *Request) !void {
        self.lock();
        defer self.mutex.unlock();
        if (self.stopping.load(.acquire)) return error.ExecutionDriverStopped;
        if (self.queued == capacity) return error.OperationBusy;
        self.queue[self.write_index] = request;
        self.write_index = (self.write_index + 1) % capacity;
        self.queued += 1;
        _ = self.work.fetchAdd(1, .release);
        self.wake.notify();
    }
    fn take(self: *Driver) ?*Request {
        self.lock();
        defer self.mutex.unlock();
        if (self.queued == 0) return null;
        const request = self.queue[self.read_index].?;
        self.queue[self.read_index] = null;
        self.read_index = (self.read_index + 1) % capacity;
        self.queued -= 1;
        return request;
    }
    fn complete(self: *Driver, request: *Request, failure: ?anyerror) void {
        request.failure = failure;
        if (request.detached) {
            self.allocator.destroy(request);
            return;
        }
        request.wake.?.notify();
        request.completed.store(true, .release);
    }
    fn cancelled(request: *Request) bool {
        if (request.cancelled.load(.acquire)) return true;
        return if (request.cancel) |token| token.isCancelled() else false;
    }
    fn requestFailure(request: *Request, clock: i64) ?anyerror {
        if (cancelled(request)) return error.CancelledBeforeDispatch;
        // A wait returns a bounded observation at its deadline; it is not a
        // new effect. Its window is capped when it enters the waiting set.
        if (request.wait == null and clock >= request.deadline) return error.Timeout;
        return null;
    }
    fn process(self: *Driver, request: *Request, clock: i64) bool {
        switch (request.kind) {
            .stop_target => |value| {
                var slot: ?usize = null;
                var registered = false;
                for (self.closing_targets, 0..) |target, index| {
                    if (target) |prior| {
                        if (prior.eql(value.target)) registered = true;
                    } else if (slot == null) slot = index;
                }
                if (!registered) self.closing_targets[
                    slot orelse {
                        self.complete(request, error.ExecutionLimit);
                        return true;
                    }
                ] = value.target;
                self.controller.stopTarget(value.context, value.target);
                self.complete(request, null);
                return true;
            },
            .finish_task => |context| {
                self.controller.finishTask(context) catch |err| {
                    self.complete(request, err);
                    return true;
                };
                self.complete(request, null);
                return true;
            },
            .stop_task => |context| {
                self.controller.stopTask(context);
                self.complete(request, null);
                return true;
            },
            .takeover_task => |context| {
                self.controller.takeoverTask(context, clock) catch |err| {
                    if (err == error.WorkerBusy) return false;
                    self.complete(request, err);
                    return true;
                };
                self.complete(request, null);
                return true;
            },
            .takeover => |value| {
                _ = self.controller.takeover(value.context, value.reference[0..value.length], clock) catch |err| {
                    if (err == error.WorkerBusy) return false;
                    self.complete(request, err);
                    return true;
                };
                self.complete(request, null);
                return true;
            },
            .stop_execution => |value| {
                _ = self.controller.stopExecution(value.context, value.reference[0..value.length], clock) catch |err| {
                    if (err == error.WorkerBusy) return false;
                    self.complete(request, err);
                    return true;
                };
                self.complete(request, null);
                return true;
            },
            .execute => |invocation| {
                self.active_request = request;
                defer self.active_request = null;
                if (requestFailure(request, clock)) |failure| {
                    if (failure == error.CancelledBeforeDispatch) self.controller.stopTask(invocation.context);
                    self.complete(request, if (failure == error.Timeout) error.ExecutionDeadlineBeforeDispatch else failure);
                    return true;
                }
                if (request.wait) |wait| {
                    const result = self.controller.pollWait(wait, clock) catch |err| {
                        if (err == error.WorkerBusy and now() < wait.deadline) return false;
                        self.complete(request, if (err == error.WorkerBusy) error.Timeout else err);
                        return true;
                    };
                    if (result) |value| {
                        request.result = value;
                        self.complete(request, null);
                        return true;
                    }
                    return false;
                }
                const response = self.controller.execute(invocation, clock) catch |err| {
                    const failure = requestFailure(request, now()) orelse err;
                    if (failure == error.WorkerBusy) return false;
                    self.complete(request, if (failure == error.Timeout and (err == error.WorkerBusy or err == error.CancelledBeforeDispatch)) error.ExecutionDeadlineBeforeDispatch else failure);
                    return true;
                };
                switch (response) {
                    .result => |result| {
                        if (cancelled(request)) self.controller.stopTask(invocation.context);
                        request.result = result;
                        self.complete(request, null);
                        return true;
                    },
                    .wait => |wait| {
                        var bounded = wait;
                        bounded.deadline = @min(wait.deadline, request.deadline);
                        request.wait = bounded;
                        return false;
                    },
                }
            },
        }
    }
    fn run(self: *Driver) void {
        while (!self.stopping.load(.acquire)) {
            while (self.take()) |request| {
                if (!self.process(request, now())) {
                    var admitted = false;
                    for (&self.waiting) |*slot| if (slot.* == null) {
                        slot.* = request;
                        admitted = true;
                        break;
                    };
                    if (!admitted) self.complete(request, error.OperationBusy);
                }
            }
            for (&self.waiting) |*slot| if (slot.*) |request| {
                if (self.process(request, now())) slot.* = null;
            };
            self.controller.tick(now());
            self.publishEvidence();
            var count: usize = 0;
            for (self.waiting) |slot| if (slot != null) {
                count += 1;
            };
            for (self.controller.entries.items) |entry| if (entry.dispatch_pending != null or !entry.snapshot.recording_settled or !entry.snapshot.local_released) {
                count += 1;
            };
            self.lock();
            count += self.queued;
            self.work.store(count, .release);
            self.mutex.unlock();
            self.wake.wait(-1, false, 100);
        }
        while (self.take()) |request| self.complete(request, error.ExecutionDriverStopped);
        for (&self.waiting) |*slot| if (slot.*) |request| {
            self.complete(request, error.ExecutionDriverStopped);
            slot.* = null;
        };
        while (!self.evidence_mutex.tryLock()) std.atomic.spinLoopHint();
        self.command_records = @splat(null);
        self.evidence_mutex.unlock();
        self.controller.deinit();
        self.journal_owner.release();
        self.work.store(0, .release);
        self.finished.store(true, .release);
    }
    fn publishEvidence(self: *Driver) void {
        var next: [128]?TaskEvidence = @splat(null);
        var targets: [128]?TargetEvidence = @splat(null);
        var inputs: [128]?ExecutionInputRecord = @splat(null);
        var input_count: usize = 0;
        var commands: [128]?CommandRecord = @splat(null);
        var command_count: usize = 0;
        for (self.closing_targets) |target| if (target) |value| {
            _ = targetIndex(&targets, value);
        };
        for (self.controller.finished_tasks) |context| if (context) |value| {
            const index = evidenceIndex(&next, value) orelse continue;
            next[index].?.model_done = true;
        };
        for (self.controller.entries.items) |entry| {
            const snapshot = entry.snapshot;
            if (entry.submitted_command) |command| if (snapshot.submit_sent and snapshot.execution_id != null and snapshot.execution_id.?.eql(entry.id) and snapshot.owner.eql(entry.target) and command_count < commands.len) {
                commands[command_count] = .{ .conversation_id = entry.context.conversation_id, .target = entry.target, .execution_id = entry.id, .command = command, .submitted_at_ms = snapshot.started_at, .revision = snapshot.revision, .verified = snapshot.command_accepted and snapshot.submit_ack_sequence != 0 and snapshot.native_wake_written, .exit_code = if (snapshot.process) |process_receipt| if (process_receipt.exit_code) |code| @as(i32, code) else null else null, .complete = snapshot.state == .sealed and snapshot.output_scope == .exact };
                command_count += 1;
            };

            const terminal_state = switch (snapshot.state) {
                .sealed, .interval_recorded, .cancelled_unsent, .outcome_unknown, .recording_degraded => true,
                else => false,
            };
            if (input_count < inputs.len) {
                inputs[input_count] = .{ .conversation_id = entry.context.conversation_id, .task_id = entry.context.task_id, .value = .{ .execution_id = entry.id, .target = entry.target, .state = snapshot.state, .terminal = terminal_state, .input_handed_off = snapshot.input_handed_off, .local_released = snapshot.local_released, .input_ready = snapshot.input_ready, .has_grant = snapshot.grant != null } };
                input_count += 1;
            }
            const index = evidenceIndex(&next, entry.context) orelse continue;
            const fact = &next[index].?;
            const target_index = targetIndex(&targets, entry.target) orelse continue;
            const target_fact = &targets[target_index].?;
            target_fact.execution_count += 1;
            fact.execution_count += 1;
            fact.awaiting_input = fact.awaiting_input or snapshot.input_wait != null;
            const pending = entry.dispatch_pending != null;
            const active = pending or !terminal_state;
            if (pending) {
                fact.pending_dispatch += 1;
                target_fact.pending_dispatch += 1;
            }
            if (active) {
                fact.active_executions += 1;
                target_fact.active_executions += 1;
            }
            // input_ready is the empty editor/prompt gate for a *new* AI
            // command. SSH reports completion before the next prompt and a
            // human draft clears that gate again. Neither retains this
            // execution's lease. local_released includes native input drain.
            const released = snapshot.local_released and snapshot.grant == null;
            if (active and snapshot.input_handed_off) fact.handed_off_observers += 1;
            fact.controlled_executions_settled = fact.controlled_executions_settled and if (snapshot.input_handed_off and !pending) released else terminal_state and released and snapshot.recording_settled;
            fact.input_grants_released = fact.input_grants_released and released;
            target_fact.input_grants_released = target_fact.input_grants_released and released;
            target_fact.recordings_settled = target_fact.recordings_settled and snapshot.recording_settled;
            target_fact.remote_effect_unknown = target_fact.remote_effect_unknown or snapshot.remote_effect_unknown;
            const attribution_unverified = snapshot.output_scope == .session_interval and snapshot.command_accepted;
            target_fact.output_attribution_unverified = target_fact.output_attribution_unverified or attribution_unverified;
            fact.output_attribution_unverified = fact.output_attribution_unverified or attribution_unverified;
            fact.recordings_settled = fact.recordings_settled and snapshot.recording_settled;
            fact.executions_settled = fact.executions_settled and terminal_state and released and snapshot.recording_settled;
            fact.remote_effect_unknown = fact.remote_effect_unknown or snapshot.remote_effect_unknown;
            // Interval attribution failures do not observe an actual external
            // job. Preserve that uncertainty in the receipt and close gate.
            if (snapshot.process) |process_receipt| fact.pending_external_jobs = fact.pending_external_jobs or process_receipt.background_jobs or (snapshot.output_scope == .exact and process_receipt.background_jobs_unknown);
            if (active or !released) fact.active_references += 1;
        }
        for (self.waiting) |request| if (request) |pending| if (pending.kind == .execute) {
            const index = evidenceIndex(&next, pending.kind.execute.context) orelse continue;
            if (pending.wait != null) next[index].?.pending_waits += 1;
        };
        for (&next) |*value| if (value.*) |*fact| {
            fact.cleanup_pending = !fact.input_grants_released or !fact.recordings_settled;
        };
        var changed = false;
        while (!self.evidence_mutex.tryLock()) std.atomic.spinLoopHint();
        for (&next) |*value| if (value.*) |*fact| {
            for (self.evidence) |old| if (old) |prior| if (prior.task_id.eql(fact.task_id)) {
                fact.revision = prior.revision;
                if (!std.meta.eql(prior, fact.*)) fact.revision +|= 1;
                break;
            };
        };
        for (&targets) |*value| if (value.*) |*fact| {
            for (self.target_evidence) |old| if (old) |prior| if (prior.target.eql(fact.target)) {
                fact.revision = prior.revision;
                if (!std.meta.eql(prior, fact.*)) fact.revision +|= 1;
                break;
            };
        };
        for (&inputs) |*value| if (value.*) |*record| {
            for (self.execution_input_evidence) |old| if (old) |prior| {
                if (prior.conversation_id.eql(record.conversation_id) and prior.task_id.eql(record.task_id) and prior.value.execution_id.eql(record.value.execution_id)) {
                    record.value.revision = prior.value.revision;
                    if (!std.meta.eql(prior.value, record.value)) record.value.revision +|= 1;
                    break;
                }
            };
        };
        changed = !std.meta.eql(self.evidence, next) or !std.meta.eql(self.target_evidence, targets) or !std.meta.eql(self.execution_input_evidence, inputs);
        self.evidence = next;
        self.target_evidence = targets;
        self.execution_input_evidence = inputs;
        self.command_records = commands;
        self.evidence_mutex.unlock();
        if (changed) @import("../platform/presentation_wakeup.zig").notify();
    }
    fn scheduled(self: *Driver, raw: *anyopaque, function: *const fn (*anyopaque) anyerror!void, admission: bool) !void {
        const Scope = struct {
            driver: *Driver,
            request: ?*Request,
            fn stopped(context: *const anyopaque) bool {
                const state: *const @This() = @ptrCast(@alignCast(context));
                return state.driver.scheduler_cancel.isCancelled() or if (state.request) |request| requestFailure(request, now()) != null else false;
            }
        };
        // Admission borrows the current caller through scheduler completion.
        // Lease release, snapshots and owner cleanup must remain available
        // after caller cancellation, using only the driver's shutdown token.
        const scope: Scope = .{ .driver = self, .request = if (admission) self.active_request else null };
        var cancel: provider.CancelToken = .{ .source = .{ .context = &scope, .poll = Scope.stopped } };
        try self.scheduler.call(self.scheduler.context, raw, function, &cancel);
    }
    fn checkAdmission(self: *Driver) !void {
        if (self.active_request) |request| if (requestFailure(request, now()) != null) return error.CancelledBeforeDispatch;
    }
    fn authorize(raw: *anyopaque, invocation: host.Invocation, reference: []const u8, command: []const u8, hash: [32]u8) !execution.Target {
        const self: *Driver = @ptrCast(@alignCast(raw));
        const Exchange = struct {
            driver: *Driver,
            invocation: host.Invocation,
            reference: []const u8,
            command: []const u8,
            hash: [32]u8,
            result: ?execution.Target = null,
            fn invoke(context: *anyopaque) !void {
                const value: *@This() = @ptrCast(@alignCast(context));
                value.result = try value.driver.backend.authorize(value.driver.backend.context, value.invocation, value.reference, value.command, value.hash);
            }
        };
        var exchange: Exchange = .{ .driver = self, .invocation = invocation, .reference = reference, .command = command, .hash = hash };
        try self.scheduled(&exchange, Exchange.invoke, true);
        try self.checkAdmission();
        return exchange.result orelse error.InvalidControllerReceipt;
    }
    fn authorizeRead(raw: *anyopaque, context: host.Context, original: host.Context, owner: identity.SessionHandle, id: identity.ExecutionId) !void {
        const self: *Driver = @ptrCast(@alignCast(raw));
        const authorize_read = self.backend.authorize_read orelse {
            if (!context.conversation_id.eql(original.conversation_id) or !context.task_id.eql(original.task_id)) return error.ExecutionNotFound;
            return;
        };
        const Exchange = struct {
            driver: *Driver,
            current: host.Context,
            original: host.Context,
            owner: identity.SessionHandle,
            id: identity.ExecutionId,
            callback: *const fn (*anyopaque, host.Context, host.Context, identity.SessionHandle, identity.ExecutionId) anyerror!void,
            fn invoke(raw_exchange: *anyopaque) !void {
                const value: *@This() = @ptrCast(@alignCast(raw_exchange));
                try value.callback(value.driver.backend.context, value.current, value.original, value.owner, value.id);
            }
        };
        var exchange: Exchange = .{ .driver = self, .current = context, .original = original, .owner = owner, .id = id, .callback = authorize_read };
        try self.scheduled(&exchange, Exchange.invoke, true);
        try self.checkAdmission();
    }
    fn authorizeInput(raw: *anyopaque, invocation: host.Invocation, owner: identity.SessionHandle, id: identity.ExecutionId, request: terminal.execution.InputRequest) !void {
        const self: *Driver = @ptrCast(@alignCast(raw));
        const Exchange = struct {
            driver: *Driver,
            invocation: host.Invocation,
            owner: identity.SessionHandle,
            id: identity.ExecutionId,
            request: terminal.execution.InputRequest,
            fn invoke(context: *anyopaque) !void {
                const value: *@This() = @ptrCast(@alignCast(context));
                const input_authorize = value.driver.backend.authorize_input orelse return error.PermissionDenied;
                try input_authorize(value.driver.backend.context, value.invocation, value.owner, value.id, value.request);
            }
        };
        var exchange: Exchange = .{ .driver = self, .invocation = invocation, .owner = owner, .id = id, .request = request };
        try self.scheduled(&exchange, Exchange.invoke, true);
        try self.checkAdmission();
    }
    fn requestSecret(raw: *anyopaque, invocation: host.Invocation, owner: identity.SessionHandle, id: identity.ExecutionId, request: terminal.execution.InputRequest) !terminal.execution.InputReceipt {
        const self: *Driver = @ptrCast(@alignCast(raw));
        const Exchange = struct {
            driver: *Driver,
            result: ?terminal.execution.InputReceipt = null,
            invocation: host.Invocation,
            owner: identity.SessionHandle,
            id: identity.ExecutionId,
            request: terminal.execution.InputRequest,
            fn invoke(context: *anyopaque) !void {
                const value: *@This() = @ptrCast(@alignCast(context));
                const callback = value.driver.backend.request_secret orelse return error.HostSecretUnavailable;
                value.result = try callback(value.driver.backend.context, value.invocation, value.owner, value.id, value.request);
            }
        };
        var exchange: Exchange = .{ .driver = self, .invocation = invocation, .owner = owner, .id = id, .request = request };
        try self.scheduled(&exchange, Exchange.invoke, true);
        return exchange.result orelse error.InvalidControllerReceipt;
    }
    fn resolve(raw: *anyopaque, context: host.Context, owner: identity.SessionHandle) !terminal.Service {
        const self: *Driver = @ptrCast(@alignCast(raw));
        const Exchange = struct {
            driver: *Driver,
            context: host.Context,
            owner: identity.SessionHandle,
            result: ?terminal.Service = null,
            fn invoke(raw_exchange: *anyopaque) !void {
                const value: *@This() = @ptrCast(@alignCast(raw_exchange));
                value.result = try value.driver.backend.resolve(value.driver.backend.context, value.context, value.owner);
            }
        };
        var exchange: Exchange = .{ .driver = self, .context = context, .owner = owner };
        try self.scheduled(&exchange, Exchange.invoke, false);
        return exchange.result orelse error.InvalidControllerReceipt;
    }
    fn handedToUser(raw: *anyopaque, owner: identity.SessionHandle) !void {
        const self: *Driver = @ptrCast(@alignCast(raw));
        if (self.backend.handed_to_user == null) return error.TakeoverUnavailable;
        const Exchange = struct {
            driver: *Driver,
            owner: identity.SessionHandle,
            fn invoke(context: *anyopaque) !void {
                const value: *@This() = @ptrCast(@alignCast(context));
                try value.driver.backend.handed_to_user.?(value.driver.backend.context, value.owner);
            }
        };
        var exchange: Exchange = .{ .driver = self, .owner = owner };
        try self.scheduled(&exchange, Exchange.invoke, true);
    }
    fn shouldCancel(raw: *anyopaque) bool {
        const self: *Driver = @ptrCast(@alignCast(raw));
        return self.stopping.load(.acquire) or if (self.active_request) |request| cancelled(request) else false;
    }
    fn terminalCall(raw: *anyopaque, service: terminal.Service, action: execution.TerminalAction) !execution.TerminalResult {
        const self: *Driver = @ptrCast(@alignCast(raw));
        const Exchange = struct {
            driver: *Driver,
            service: terminal.Service,
            action: execution.TerminalAction,
            result: ?execution.TerminalResult = null,
            fn invoke(context: *anyopaque) !void {
                const value: *@This() = @ptrCast(@alignCast(context));
                value.result = if (value.driver.backend.terminal_call) |call| try call(value.driver.backend.context, value.service, value.action) else try execution.performTerminal(value.service, value.action);
            }
        };
        var exchange: Exchange = .{ .driver = self, .service = service, .action = action };
        const admission = switch (action) {
            .input => true,
            .request => |pending| match: {
                const active = self.active_request orelse break :match false;
                // run() may also tick previously submitted commands. Their
                // owner work must not inherit this caller's deadline.
                for (self.controller.entries.items) |entry| if (entry.id.eql(pending.execution_id)) {
                    break :match entry.invocation_id == active.kind.execute.operation_id and entry.context.task_id.eql(active.kind.execute.context.task_id) and entry.context.conversation_id.eql(active.kind.execute.context.conversation_id);
                };
                break :match false;
            },
            else => false,
        };
        try self.scheduled(&exchange, Exchange.invoke, admission);
        return exchange.result orelse error.InvalidControllerReceipt;
    }
};
fn now() i64 {
    return @intCast(@divTrunc(@import("../platform/realtime.zig").monotonicNs(), std.time.ns_per_ms));
}

fn evidenceIndex(values: *[128]?TaskEvidence, context: host.Context) ?usize {
    var available: ?usize = null;
    for (values, 0..) |value, index| {
        if (value) |fact| {
            if (fact.task_id.eql(context.task_id) and fact.conversation_id.eql(context.conversation_id)) return index;
        } else if (available == null) available = index;
    }
    const index = available orelse return null;
    values[index] = .{ .conversation_id = context.conversation_id, .task_id = context.task_id };
    return index;
}

fn targetIndex(values: *[128]?TargetEvidence, target: identity.SessionHandle) ?usize {
    var available: ?usize = null;
    for (values, 0..) |value, index| {
        if (value) |fact| {
            if (fact.target.eql(target)) return index;
        } else if (available == null) available = index;
    }
    const index = available orelse return null;
    values[index] = .{ .target = target };
    return index;
}
test {
    _ = @import("host_execution_driver_tests.zig");
}

const AdmissionTest = struct {
    request: *Request,
    mode: enum { none, stop, expire, expire_after, busy } = .none,
    effects: usize = 0,
    snapshot: terminal.execution.Snapshot = .{ .owner = .{ .session_id = @fromBackingInt(1), .generation = 1 }, .state = .running, .revision = 1, .interactive_execution = true },
    fn schedule(raw: *anyopaque, context: *anyopaque, function: *const fn (*anyopaque) anyerror!void, cancel: ?*provider.CancelToken) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        switch (self.mode) {
            .none, .expire_after => {},
            .busy => return error.WorkerBusy,
            .stop => self.request.cancelled.store(true, .release),
            .expire => self.request.deadline = 0,
        }
        if (cancel) |token| if (token.isCancelled()) return error.CancelledBeforeDispatch;
        try function(context);
        if (self.mode == .expire_after) self.request.deadline = 0;
    }
    fn authorize(raw: *anyopaque, _: host.Invocation, _: []const u8, _: []const u8, _: [32]u8) !execution.Target {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.effects += 1;
        if (self.mode == .expire_after) return .{ .handle = self.snapshot.owner, .service = try resolve(raw, undefined, self.snapshot.owner), .ownership_revision = 1 };
        return error.UnexpectedDispatch;
    }
    fn resolve(raw: *anyopaque, _: host.Context, _: identity.SessionHandle) !terminal.Service {
        return .{ .context = raw, .binding = undefined, .vtable = undefined };
    }
    fn call(raw: *anyopaque, _: terminal.Service, action: execution.TerminalAction) !execution.TerminalResult {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return switch (action) {
            .snapshot => .{ .snapshot = self.snapshot },
            .output => |value| .{ .output = .{ .bytes = try value.allocator.alloc(u8, 0), .start_cursor = 0, .next_cursor = 0, .gap = false, .truncated = false } },
            else => result: {
                self.effects += 1;
                break :result .done;
            },
        };
    }
    fn driver(self: *@This()) Driver {
        const backend: execution.Backend = .{ .context = self, .authorize = authorize, .resolve = resolve, .terminal_call = call };
        return .{ .allocator = std.testing.allocator, .journal_owner = undefined, .scheduler = .{ .context = self, .call = schedule }, .backend = backend, .controller = .{ .allocator = std.testing.allocator, .journal = undefined, .backend = undefined }, .wake = undefined, .active_request = self.request };
    }
    fn invocation() host.Invocation {
        return .{ .context = .{ .conversation_id = .{ .bytes = @splat(1) }, .task_id = .{ .bytes = @splat(2) }, .binding = .{ .session = 1 }, .binding_revision = 1, .grant_revision = 1 }, .authority = .execution_control, .operation_id = 9, .turn_id = 1, .call_id = "fixture", .tool_id = "host.run_in_terminal", .arguments = .null, .arguments_json = "", .arguments_hash = @splat(0), .canonical_arguments_hash = @splat(0) };
    }
};
test "execution deadline admission scheduler observes Stop and elapsed budget before effects" {
    for ([_]AdmissionTest{ .{ .request = undefined, .mode = .stop }, .{ .request = undefined, .mode = .expire } }) |mode| {
        var request: Request = .{ .kind = .{ .execute = AdmissionTest.invocation() }, .deadline = std.math.maxInt(i64) };
        var fixture = mode;
        fixture.request = &request;
        var driver = fixture.driver();
        try std.testing.expectError(error.CancelledBeforeDispatch, Driver.authorize(&driver, request.kind.execute, "0", "true", @splat(0)));
        try std.testing.expectEqual(@as(usize, 0), fixture.effects);
    }
}
test "execution deadline owner revoke survives caller cancellation but respects driver shutdown" {
    var request: Request = .{ .kind = .{ .execute = AdmissionTest.invocation() }, .deadline = 0 };
    request.cancelled.store(true, .release);
    var fixture: AdmissionTest = .{ .request = &request };
    var driver = fixture.driver();
    const service = try AdmissionTest.resolve(&fixture, request.kind.execute.context, fixture.snapshot.owner);
    const grant: terminal.execution.Grant = .{ .execution_id = .{ .bytes = @splat(3) }, .task_id = request.kind.execute.context.task_id, .fence = 1, .input_epoch = 1, .ownership_revision = 1 };
    _ = try Driver.terminalCall(&driver, service, .{ .revoke = .{ .grant = grant, .takeover = false } });
    try std.testing.expectEqual(@as(usize, 1), fixture.effects);
    driver.scheduler_cancel.cancel();
    try std.testing.expectError(error.CancelledBeforeDispatch, Driver.terminalCall(&driver, service, .{ .revoke = .{ .grant = grant, .takeover = false } }));
    try std.testing.expectEqual(@as(usize, 1), fixture.effects);
}
test "execution deadline queued expired request cannot enter the controller" {
    var request: Request = .{ .kind = .{ .execute = AdmissionTest.invocation() }, .deadline = 70, .wake = try Wakeup.init() };
    defer request.wake.?.deinit();
    var fixture: AdmissionTest = .{ .request = &request };
    var driver = fixture.driver();
    try std.testing.expect(driver.process(&request, 70));
    try std.testing.expectEqual(error.ExecutionDeadlineBeforeDispatch, request.failure.?);
    try std.testing.expect(request.completed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), fixture.effects);
}
test "execution deadline terminal admission belongs only to its original invocation" {
    for (0..4) |case| {
        const same_invocation = case == 0;
        var request: Request = .{ .kind = .{ .execute = AdmissionTest.invocation() }, .deadline = 0 };
        var fixture: AdmissionTest = .{ .request = &request };
        var driver = fixture.driver();
        const id: identity.ExecutionId = .{ .bytes = @splat(3) };
        var original_context = request.kind.execute.context;
        if (case == 2) original_context.task_id.bytes[0] += 1;
        if (case == 3) original_context.conversation_id.bytes[0] += 1;
        try driver.controller.entries.append(std.testing.allocator, .{ .context = original_context, .invocation_id = if (case == 1) 10 else 9, .id = id, .target = fixture.snapshot.owner, .journal = undefined, .journal_revision = 1, .journal_stage = .running, .snapshot = fixture.snapshot, .next_renew_at = std.math.maxInt(i64) });
        defer driver.controller.entries.deinit(std.testing.allocator);
        const service = try AdmissionTest.resolve(&fixture, request.kind.execute.context, fixture.snapshot.owner);
        const action: execution.TerminalAction = .{ .request = .{ .execution_id = id, .task_id = request.kind.execute.context.task_id, .expected_input_epoch = 1, .ownership_revision = 1, .command = "true", .command_hash = @splat(0) } };
        if (same_invocation) {
            try std.testing.expectError(error.CancelledBeforeDispatch, Driver.terminalCall(&driver, service, action));
            try std.testing.expectEqual(@as(usize, 0), fixture.effects);
        } else {
            _ = try Driver.terminalCall(&driver, service, action);
            try std.testing.expectEqual(@as(usize, 1), fixture.effects);
        }
    }
}
test "execution deadline wait observation spends queue time and retains the running execution" {
    var request: Request = .{ .kind = .{ .execute = AdmissionTest.invocation() }, .deadline = 70, .wake = try Wakeup.init() };
    defer request.wake.?.deinit();
    var fixture: AdmissionTest = .{ .request = &request };
    var driver = fixture.driver();
    driver.controller.backend = .{ .context = &driver, .authorize = Driver.authorize, .resolve = Driver.resolve, .terminal_call = Driver.terminalCall };
    const id: identity.ExecutionId = .{ .bytes = @splat(3) };
    fixture.snapshot.execution_id = id;
    try driver.controller.entries.append(std.testing.allocator, .{ .context = request.kind.execute.context, .id = id, .target = fixture.snapshot.owner, .journal = undefined, .journal_revision = 1, .journal_stage = .running, .snapshot = fixture.snapshot, .next_renew_at = std.math.maxInt(i64) });
    defer driver.controller.entries.deinit(std.testing.allocator);
    var json: [256]u8 = undefined;
    const wire = try std.fmt.bufPrint(&json, "{{\"execution_ref\":\"x1:{s}\",\"wait_ms\":100,\"after_revision\":1}}", .{std.fmt.bytesToHex(id.bytes, .lower)});
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, wire, .{});
    defer parsed.deinit();
    request.kind.execute.tool_id = "host.wait_execution";
    request.kind.execute.arguments = parsed.value;
    try std.testing.expect(!driver.process(&request, 60));
    try std.testing.expectEqual(@as(i64, 70), request.wait.?.deadline);
    try std.testing.expect(driver.process(&request, 70));
    try std.testing.expect(request.failure == null);
    var result = request.result.?;
    defer result.deinit(std.testing.allocator);
    var body = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result.blocks[0].structured, .{});
    defer body.deinit();
    try std.testing.expect(body.value.object.get("timed_out").?.bool);
    try std.testing.expectEqualStrings("running", body.value.object.get("state").?.string);
    try std.testing.expectEqual(@as(usize, 0), fixture.effects);
}

test "execution deadline completed authorization cannot publish a late admission" {
    var request: Request = .{ .kind = .{ .execute = AdmissionTest.invocation() }, .deadline = std.math.maxInt(i64) };
    var fixture: AdmissionTest = .{ .request = &request, .mode = .expire_after };
    var driver = fixture.driver();
    // Do not format the deliberately unbound service on an unexpected success.
    if (Driver.authorize(&driver, request.kind.execute, "0", "true", @splat(0))) |_| return error.TestExpectedError else |err| try std.testing.expectEqual(error.CancelledBeforeDispatch, err);
    try std.testing.expectEqual(@as(usize, 1), fixture.effects);
}

test "execution deadline expired busy observation cannot retry forever or stop the command" {
    var request: Request = .{ .kind = .{ .execute = AdmissionTest.invocation() }, .deadline = 70, .wake = try Wakeup.init() };
    defer request.wake.?.deinit();
    var fixture: AdmissionTest = .{ .request = &request, .mode = .busy };
    var driver = fixture.driver();
    driver.controller.backend = .{ .context = &driver, .authorize = Driver.authorize, .resolve = Driver.resolve, .terminal_call = Driver.terminalCall };
    const id: identity.ExecutionId = .{ .bytes = @splat(3) };
    try driver.controller.entries.append(std.testing.allocator, .{ .context = request.kind.execute.context, .id = id, .target = fixture.snapshot.owner, .journal = undefined, .journal_revision = 1, .journal_stage = .running, .snapshot = fixture.snapshot, .next_renew_at = std.math.maxInt(i64) });
    defer driver.controller.entries.deinit(std.testing.allocator);
    request.wait = .{ .context = request.kind.execute.context, .operation_id = 9, .index = 0, .after_revision = 1, .deadline = 70, .output_cursor = 0, .max_bytes = 128 };
    try std.testing.expect(driver.process(&request, 70));
    try std.testing.expectEqual(error.Timeout, request.failure.?);
    try std.testing.expectEqual(@as(usize, 0), fixture.effects);
    try std.testing.expectEqual(terminal.execution.State.running, driver.controller.entries.items[0].snapshot.state);
}
