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
                if (cancelled(request)) {
                    self.controller.stopTask(invocation.context);
                    self.complete(request, error.CancelledBeforeDispatch);
                    return true;
                }
                if (request.wait) |wait| {
                    const result = self.controller.pollWait(wait, clock) catch |err| {
                        if (err == error.WorkerBusy) return false;
                        self.complete(request, err);
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
                    if (err == error.WorkerBusy and clock < request.deadline) return false;
                    self.complete(request, err);
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
                        request.wait = wait;
                        return false;
                    },
                }
            },
        }
    }
    fn run(self: *Driver) void {
        while (!self.stopping.load(.acquire)) {
            const clock = now();
            while (self.take()) |request| {
                if (!self.process(request, clock)) {
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
                if (self.process(request, clock)) slot.* = null;
            };
            self.controller.tick(clock);
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
    fn scheduled(self: *Driver, raw: *anyopaque, function: *const fn (*anyopaque) anyerror!void) !void {
        try self.scheduler.call(self.scheduler.context, raw, function, &self.scheduler_cancel);
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
        try self.scheduled(&exchange, Exchange.invoke);
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
        try self.scheduled(&exchange, Exchange.invoke);
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
        try self.scheduled(&exchange, Exchange.invoke);
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
        try self.scheduled(&exchange, Exchange.invoke);
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
        try self.scheduled(&exchange, Exchange.invoke);
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
        try self.scheduled(&exchange, Exchange.invoke);
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
        try self.scheduled(&exchange, Exchange.invoke);
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
