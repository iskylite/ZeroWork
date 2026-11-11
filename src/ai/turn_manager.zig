const std = @import("std");
const provider = @import("provider.zig");
const permission = @import("permission.zig");
const turn_model = @import("turn.zig");
const card_stream = @import("card_stream.zig");
const audit = @import("audit.zig");
const retry = @import("retry.zig");
const tool_scope = @import("tool_scope.zig");
pub const tool_loop = @import("tool_loop.zig");
test {
    _ = @import("tool_loop_tests.zig");
    _ = @import("live_context_usage.zig");
}

fn RequestBudget(comptime Timing: type) type {
    return struct {
        timing: Timing,
        deadline_ns: i128,
        stop: ?*provider.CancelToken,
        mutex: std.atomic.Mutex = .unlocked,
        user_waits: usize = 0,
        wait_started_ns: i128 = 0,
        expired_before_wait: bool = false,
        fn lock(self: *const @This()) *@This() {
            const mutable = @constCast(self);
            while (!mutable.mutex.tryLock()) std.atomic.spinLoopHint();
            return mutable;
        }
        fn userWait(raw: *const anyopaque, entering: bool) void {
            const self: *const @This() = @ptrCast(@alignCast(raw));
            if (self.stop) |stop| if (stop.source) |source| if (source.user_wait) |notify| notify(source.context, entering);
            self.changeWait(entering);
        }
        fn resourceWait(raw: *const anyopaque, entering: bool) void {
            const self: *const @This() = @ptrCast(@alignCast(raw));
            if (self.stop) |stop| if (stop.source) |source| if (source.resource_wait) |notify| notify(source.context, entering);
            self.changeWait(entering);
        }
        fn changeWait(self: *const @This(), entering: bool) void {
            const mutable = self.lock();
            defer mutable.mutex.unlock();
            const now = self.timing.now();
            if (entering) {
                if (mutable.user_waits == 0) {
                    mutable.wait_started_ns = now;
                    // Entering a human wait cannot revive an already expired run.
                    mutable.expired_before_wait = mutable.expired_before_wait or now >= self.deadline_ns;
                }
                mutable.user_waits += 1;
            } else if (mutable.user_waits != 0) {
                mutable.user_waits -= 1;
                if (mutable.user_waits == 0) mutable.deadline_ns +|= @max(0, now - mutable.wait_started_ns);
            }
        }
        fn reason(self: *const @This()) ?anyerror {
            if (self.stop) |token| if (token.isCancelled()) return error.Cancelled;
            const mutable = self.lock();
            defer mutable.mutex.unlock();
            if (self.expired_before_wait) return error.Timeout;
            return if (self.user_waits == 0 and self.timing.now() >= self.deadline_ns) error.Timeout else null;
        }
        fn check(self: *const @This()) !void {
            if (self.reason()) |err| return err;
        }
        fn deadline(self: *const @This()) i128 {
            const mutable = self.lock();
            defer mutable.mutex.unlock();
            return mutable.deadline_ns;
        }
        fn cancelled(raw: *const anyopaque) bool {
            const self: *const @This() = @ptrCast(@alignCast(raw));
            return self.reason() != null;
        }
        fn childToken(self: *const @This()) provider.CancelToken {
            return .{ .source = .{ .context = self, .poll = cancelled, .user_wait = userWait, .resource_wait = resourceWait } };
        }
    };
}

/// 将 Provider 的增量事件汇聚为可消费的 CardStream，并维护一次 Turn 的生命周期。
pub const Manager = struct {
    pub const Observer = struct {
        context: *anyopaque,
        reset: *const fn (*anyopaque) void,
        delta: *const fn (*anyopaque, provider.Delta) anyerror!void,
        /// Calls rejected by parsing or preflight may never reach the tool host.
        round_start: ?*const fn (*anyopaque) void = null,
        input_consumed: ?*const fn (*anyopaque, @import("../host/identity.zig").SubmissionId, []const u8) anyerror!void = null,
        tool_rejected: ?*const fn (*anyopaque, provider.ToolCall, []const u8) anyerror!void = null,
        context_usage: ?*const fn (*anyopaque, u64, @import("live_context_usage.zig").Snapshot) void = null,
    };
    allocator: std.mem.Allocator,
    read_only: bool = false,
    input: ?*@import("session_input.zig").Inbox = null,
    shared_task: ?struct { root: *@import("task_budget.zig").Root, task: @import("../host/identity.zig").TaskId } = null,
    compaction_config: ?@import("provider_config.zig").ProviderConfig = null,
    last_context_usage: ?@import("context_usage.zig").Sample = null,
    live_context_usage: @import("live_context_usage.zig").Tracker = .{},
    observer: ?Observer = null,
    turn: turn_model.Turn,
    cards: card_stream.Stream,
    audit_log: audit.Log,
    permission_engine: permission.Engine = .{},
    live_permission: permission.LiveMode = .{},
    retry_policy: retry.Policy = .{},
    timestamp_ms: i64 = 0,
    turn_id: u64 = 0,
    command: []const u8 = "ai.chat",
    last_error: ?[]const u8 = null,
    last_error_storage: [4096]u8 = undefined,
    saw_done: bool = false,
    retry_attempt: u8 = 0,
    cooldown_deadline_ms: u64 = 0,
    /// Index of the currently-aggregating .text card for this turn, or null
    /// when the next text delta should open a new card. Streaming deltas of
    /// one logical response merge into ONE card (a real provider turn sends
    /// 100+ fragment chunks).
    open_text_card: ?usize = null,
    /// Provider reasoning is a separate channel, never an answer fragment.
    /// Retain it for a future explicit reasoning disclosure instead of
    /// concatenating private reasoning with the user-visible response.
    reasoning: std.ArrayList(u8) = .empty,
    scope: ?tool_scope.Scope = null,
    tool_host: ?tool_loop.Host = null,
    tool_limits: tool_loop.Limits = .{},
    policy_revision: u64 = 0,
    /// Worker-owned until join. Includes actual outcomes even if Stop or the
    /// next-round context limit prevents a final answer.
    tool_run: ?*tool_loop.Loop = null,
    round_text: std.ArrayList(u8) = .empty,
    pending_tools: std.ArrayList(PendingTool) = .empty,
    const PendingTool = struct {
        index: u32,
        call_id: ?[]u8 = null,
        name: ?[]u8 = null,
        arguments: std.ArrayList(u8) = .empty,
    };

    fn clearPending(self: *Manager) void {
        for (self.pending_tools.items) |*tool| {
            if (tool.call_id) |id| self.allocator.free(id);
            if (tool.name) |name| self.allocator.free(name);
            tool.arguments.deinit(self.allocator);
        }
        self.pending_tools.clearRetainingCapacity();
    }

    pub fn init(allocator: std.mem.Allocator) Manager {
        return .{
            .allocator = allocator,
            .turn = turn_model.Turn.init(allocator),
            .cards = card_stream.Stream.init(allocator),
            .audit_log = audit.Log.init(allocator),
        };
    }

    pub fn permissionEngine(self: *const Manager) permission.Engine {
        return self.live_permission.apply(self.permission_engine);
    }
    pub fn setPermissionMode(self: *Manager, mode: permission.Mode) void {
        self.live_permission.set(mode);
    }
    fn currentPermission(raw: *anyopaque) permission.Engine {
        return @as(*Manager, @ptrCast(@alignCast(raw))).permissionEngine();
    }

    pub fn deinit(self: *Manager) void {
        self.clearToolRun();
        self.round_text.deinit(self.allocator);
        self.clearPending();
        self.pending_tools.deinit(self.allocator);
        self.reasoning.deinit(self.allocator);
        self.audit_log.deinit();
        self.cards.deinit();
        self.turn.deinit();
        self.* = undefined;
    }

    pub fn run(self: *Manager, p: provider.Provider, request: provider.ChatRequest) !provider.ChatStats {
        try @import("../update/admission.zig").require();
        return self.runWithTiming(p, request, retry.Clock{});
    }

    fn runWithTiming(self: *Manager, p: provider.Provider, request: provider.ChatRequest, timing: anytype) !provider.ChatStats {
        var budget: RequestBudget(@TypeOf(timing)) = .{ .timing = timing, .deadline_ns = if (request.run_timeout_ms) |timeout_ms| timing.now() + @as(i128, timeout_ms) * std.time.ns_per_ms else std.math.maxInt(i128), .stop = request.cancel };
        var cancel = budget.childToken();
        return self.runWithinBudget(p, request, &budget, &cancel) catch |err| return budget.reason() orelse err;
    }

    fn runWithinBudget(self: *Manager, p: provider.Provider, request: provider.ChatRequest, budget: anytype, cancel: *provider.CancelToken) !provider.ChatStats {
        defer if (self.tool_run) |loop| {
            loop.compaction_provider = null;
            loop.request.cancel = request.cancel;
        };
        try budget.check();
        if (self.tool_run) |previous| {
            // Only a retry of the same turn inherits its dispatch ledger.
            // A later tools-free turn keeps historical tool messages as
            // context without requiring the previous turn's live authority.
            if (previous.turn_id == self.turn_id) if (self.scope) |current| {
                const same_conversation = if (previous.tool_table) |table| if (table.host_context) |context| same: {
                    const next = request.tool_table orelse return error.InvalidHostAuthority;
                    const other = next.host_context orelse return error.InvalidHostAuthority;
                    break :same context.conversation_id.eql(other.conversation_id);
                } else tool_scope.Owner.eql(previous.scope.owner, current.owner) else tool_scope.Owner.eql(previous.scope.owner, current.owner);
                if (same_conversation) {
                    for (previous.records.items) |record| if (record.dispatched) return error.ToolTurnAlreadyDispatched;
                }
            };
        }
        errdefer self.turn.abort();
        if (self.observer) |observer| {
            if (observer.round_start) |notify| notify(observer.context);
            try budget.check();
            observer.reset(observer.context);
            try budget.check();
        }
        self.last_context_usage = null;
        self.live_context_usage = .{};
        try self.turn.resetForRun();
        self.last_error = null;
        self.saw_done = false;
        self.open_text_card = null;
        self.reasoning.clearRetainingCapacity();
        self.clearPending();
        self.clearToolRun();
        self.round_text.clearRetainingCapacity();
        self.cards.clearRetainingCapacity();
        try self.turn.begin();
        try self.turn.stream();

        if (request.tools.len != 0 and self.tool_host == null) return error.ToolHostUnavailable;
        if (self.input != null or self.tool_host != null or (self.scope != null and request.tools.len == 0)) {
            const scope = self.scope orelse return error.ToolScopeUnavailable;
            const loop = try self.allocator.create(tool_loop.Loop);
            loop.* = tool_loop.Loop.init(self.allocator, scope, self.turn_id, self.tool_limits);
            loop.read_only = self.read_only;
            loop.compaction_config = self.compaction_config;
            loop.compaction_provider = p;
            var initial_request = request;
            initial_request.cancel = cancel;
            loop.start(initial_request) catch |err| {
                if (loop.compaction_failure != null) {
                    self.tool_run = loop;
                    return err;
                }
                loop.deinit();
                self.allocator.destroy(loop);
                return err;
            };
            self.tool_run = loop;
        } else if (request.tools.len != 0) return error.ToolHostUnavailable;

        errdefer if (self.input != null) if (self.tool_run) |loop| loop.sealInterrupted() catch {};
        const frozen_policy_revision = self.policy_revision;
        var total: provider.ChatStats = .{};
        while (true) {
            try budget.check();
            if (self.input) |inbox| inbox.setWorkPhase(self.turn_id, .continuing);
            if (self.tool_run) |loop| if (self.tool_host) |host| {
                if (loop.request.workspace_revision != null) loop.refreshAuthority(host, cancel) catch |err| {
                    if (err == error.AuthorityRefreshStale) continue;
                    return err;
                };
            };
            if (self.tool_run) |loop| try loop.prepareNextRequest();
            const input_revision = if (self.input != null) (try self.consumeInputs() orelse {
                // A newer accepted input or workspace won before request freeze.
                continue;
            }) else 0;
            var current = if (self.tool_run) |loop| loop.frozenNextRequest() else request;
            if (self.input) |inbox| self.tool_run.?.dispatch_gate = .{ .context = inbox, .revision = input_revision, .current = inputPlanCurrent };
            // Keep only the caller's token in the retained snapshot. This
            // bounded token borrows the active run and must never escape it.
            current.cancel = cancel;
            self.turn.state = .streaming;
            if (self.input) |inbox| inbox.setWorkPhase(self.turn_id, .response);
            const stats = try self.runRoundUntil(p, current, budget.deadline_ns, budget.timing);
            try budget.check();
            if (self.tool_run) |loop| if (self.tool_host) |host| try loop.acknowledgeNotice(host, cancel);
            try budget.check();
            total.input_tokens +|= stats.input_tokens;
            total.output_tokens +|= stats.output_tokens;
            total.request_count +|= stats.request_count;
            total.usage_reported = total.usage_reported and stats.usage_reported;
            if (self.pending_tools.items.len == 0 or self.tool_run == null) {
                if (self.shared_task) |shared| if (self.tool_run) |loop| if (shared.root.needsChildren(shared.task)) {
                    if (self.round_text.items.len != 0) loop.appendPrepared(try loop.prepareMessage(.{ .role = .assistant, .content = self.round_text.items }));
                    const dependency_wait = provider.CancelToken.beginUserWait(cancel);
                    defer dependency_wait.end();
                    try shared.root.state(shared.task, .waiting_children, "");
                    while (shared.root.childrenRunning(shared.task)) {
                        if (shared.root.unreportedHuman(shared.task) or self.hasSteeringInput()) break;
                        try budget.check();
                        try shared.root.check();
                        (@import("retry.zig").Clock{}).sleep(5 * std.time.ns_per_ms);
                    }
                    try shared.root.state(shared.task, .running, "");
                    continue;
                };

                if (self.input) |inbox| if (!inbox.tryCloseAtWorkspace(self.tool_run.?.request.workspace_revision)) {
                    const loop = self.tool_run.?;
                    if (self.round_text.items.len != 0) loop.appendPrepared(try loop.prepareMessage(.{ .role = .assistant, .content = self.round_text.items }));
                    continue;
                };
                try self.turn.done();
                try self.audit_log.append(.{ .timestamp_ms = self.timestamp_ms, .turn_id = self.turn_id, .command = self.command, .verdict = "stream_done", .target = request.model });
                return total;
            }
            if (self.shared_task) |shared| try shared.root.take(shared.task, 0, @intCast(self.pending_tools.items.len));
            if (self.input) |inbox| inbox.setWorkPhase(self.turn_id, .tools);
            try self.completeTools(current.cancel, self.permissionEngine(), frozen_policy_revision);
            try budget.check();
            if (self.tool_run.?.uncertain and !self.tool_run.?.host_observation_only) return error.ToolOutcomeUnknown;
            if (self.tool_host) |host| if (self.tool_run.?.request.workspace_revision == null) try self.tool_run.?.refreshAuthority(host, current.cancel);
            try budget.check();
        }
    }

    fn inputPlanCurrent(raw: *anyopaque, revision: u64) bool {
        const inbox: *@import("session_input.zig").Inbox = @ptrCast(@alignCast(raw));
        return inbox.planCurrent(revision);
    }
    fn hasSteeringInput(self: *Manager) bool {
        return if (self.input) |inbox| inbox.hasPending() else false;
    }
    fn consumeInputs(self: *Manager) !?u64 {
        const input = @import("session_input.zig");
        const inbox = self.input.?;
        const loop = self.tool_run.?;
        var entries: std.ArrayList(*input.Entry) = .empty;
        defer entries.deinit(self.allocator);
        const revision = snapshot: {
            inbox.lock();
            defer inbox.unlock();
            if (!inbox.admission) return error.Cancelled;
            if (inbox.workspace_changing or (loop.request.workspace_revision != null and loop.request.workspace_revision.? != inbox.workspace_revision)) {
                if (self.tool_host == null) return error.WorkspaceChanged;
                return null;
            }
            for (inbox.entries.items) |entry| if (inbox.eligibleLocked(entry)) try entries.append(self.allocator, entry);
            break :snapshot inbox.revision;
        };
        if (loop.request.workspace_revision != null and loop.round_index == 0 and entries.items.len == 0) return error.WorkspaceChanged;
        const payloads = try self.allocator.alloc(provider.Message, entries.items.len);
        defer self.allocator.free(payloads);
        for (entries.items, payloads) |entry, *payload| payload.* = entry.payload.messages[0];
        const prepared = try loop.prepareInputBatch(payloads);
        const rows = try self.allocator.alloc(input.Consumption, entries.items.len);
        defer self.allocator.free(rows);
        if (!try inbox.reserveConsumption(loop.request.workspace_revision, revision, entries.items, rows, loop.round_index +| 1)) return null;
        inbox.persistConsumption(rows, loop.preparedInputTranscript(prepared)) catch |err| {
            inbox.publishConsumption(entries.items, rows, false);
            return err;
        };
        inbox.publishConsumption(entries.items, rows, true);
        for (prepared) |message| loop.appendPrepared(message);
        for (rows) |row| if (row.receipt.route == .steer) if (self.observer) |observer| if (observer.input_consumed) |notify| {
            try notify(observer.context, row.receipt.id, row.payload[0].content);
        };
        return revision;
    }

    /// An explicit answer-only retry preserves the original turn, transcript
    /// and completed-call ledger. It exposes no tools and cannot dispatch new
    /// effects, even if a misbehaving provider returns a tool call anyway.
    pub fn resumeAnswer(self: *Manager, p: provider.Provider, cancel: ?*provider.CancelToken) !provider.ChatStats {
        try @import("../update/admission.zig").require();
        return self.resumeAnswerWithTiming(p, cancel, retry.Clock{});
    }

    fn resumeAnswerWithTiming(self: *Manager, p: provider.Provider, stop: ?*provider.CancelToken, timing: anytype) !provider.ChatStats {
        if (stop) |token| if (token.isCancelled()) return error.Cancelled;
        const started = timing.now();
        const loop = self.tool_run orelse return error.NoToolTurnToResume;
        // A user-initiated answer retry is a fresh attempt, not an automatic
        // continuation. It keeps the original snapshot and dispatch ledger.
        var budget: RequestBudget(@TypeOf(timing)) = .{ .timing = timing, .deadline_ns = started + @as(i128, loop.request.timeout_ms) * std.time.ns_per_ms, .stop = stop };
        var cancel = budget.childToken();
        return self.resumeAnswerWithinBudget(p, loop, &budget, &cancel) catch |err| return budget.reason() orelse err;
    }

    fn resumeAnswerWithinBudget(self: *Manager, p: provider.Provider, loop: *tool_loop.Loop, budget: anytype, cancel: *provider.CancelToken) !provider.ChatStats {
        loop.compaction_provider = p;
        defer loop.compaction_provider = null;
        const original_cancel = loop.request.cancel;
        loop.request.cancel = cancel;
        defer loop.request.cancel = original_cancel;
        try budget.check();
        if (self.cooldownRemainingMs() != 0) return error.ProviderCoolingDown;
        if (self.turn_id != loop.turn_id or self.scope == null or !tool_scope.Owner.eql(self.scope.?.owner, loop.scope.owner)) return error.ToolOwnerChanged;
        if (self.turn.state != .idle) return error.InvalidTransition;
        try self.turn.begin();
        try self.turn.stream();
        errdefer self.turn.abort();
        if (self.observer) |observer| {
            if (observer.round_start) |notify| notify(observer.context);
            try budget.check();
            observer.reset(observer.context);
            try budget.check();
        }
        // Include recovery guidance in admission without changing the frozen
        // system snapshot. Unknown receipts remain unknown after this answer.
        const original_system = loop.request.system;
        const answer_system = if (loop.uncertain) try std.fmt.allocPrint(self.allocator, "{s}\n\n[Answer-only recovery]\nGenerate an answer using only the retained transcript and tool results. No tools are available: do not request or replay any operation. Distinguish completed, failed, skipped and unknown results using the recorded receipts. Partial output is not proof of completion. Unknown remote effects or cleanup remain unverified; do not claim success or that cleanup finished. Explain missing evidence and any verification still needed.\nRead-only observations (they do not clear prior unknown outcomes):\n{s}", .{ original_system, loop.verification_notes.items }) else null;
        defer if (answer_system) |text| self.allocator.free(text);
        if (answer_system) |text| loop.request.system = text;
        defer loop.request.system = original_system;
        try loop.checkRequestBudget();
        var resumed = loop.request;
        resumed.messages = loop.messages.items;
        resumed.tools = &.{};
        resumed.cancel = cancel;
        // The retry uses the updated transcript after budget compaction.
        try budget.check();
        const stats = try self.runRoundUntil(p, resumed, budget.deadline_ns, budget.timing);
        try budget.check();
        if (self.pending_tools.items.len != 0) return error.ToolInvocationDuringAnswerRetry;
        try self.turn.done();
        try self.audit_log.append(.{ .timestamp_ms = self.timestamp_ms, .turn_id = loop.turn_id, .command = self.command, .verdict = "answer_retry_done", .target = resumed.model });
        return stats;
    }

    pub fn cooldownRemainingMs(self: *const Manager) u64 {
        return self.cooldown_deadline_ms -| monotonicMs();
    }

    /// Idle UI rollback releases discarded provider/tool context while keeping
    /// the already prepared next-request policy and tool host configuration.
    pub fn discardTranscript(self: *Manager) void {
        self.clearToolRun();
        self.clearPending();
        self.round_text.clearRetainingCapacity();
        self.reasoning.clearRetainingCapacity();
        self.cards.clearRetainingCapacity();
        self.open_text_card = null;
        self.last_error = null;
        self.saw_done = false;
    }

    fn clearToolRun(self: *Manager) void {
        if (self.tool_run) |loop| {
            loop.deinit();
            self.allocator.destroy(loop);
            self.tool_run = null;
        }
    }

    /// Retries only this provider round. Tool dispatch is outside the retry
    /// region; already completed calls and their transcript never run again.
    fn runRoundWithTiming(self: *Manager, p: provider.Provider, request: provider.ChatRequest, timing: anytype) !provider.ChatStats {
        const deadline_ns = timing.now() + @as(i128, request.timeout_ms) * std.time.ns_per_ms;
        return self.runRoundUntil(p, request, deadline_ns, timing);
    }

    fn runRoundUntil(self: *Manager, p: provider.Provider, request: provider.ChatRequest, parent_deadline_ns: i128, timing: anytype) !provider.ChatStats {
        // Queueing for model capacity suspends this round's retry budget as
        // well as the enclosing run. Provider work and backoff still share it.
        var round_budget: RequestBudget(@TypeOf(timing)) = .{ .timing = timing, .deadline_ns = @min(parent_deadline_ns, timing.now() + @as(i128, request.timeout_ms) * std.time.ns_per_ms), .stop = request.cancel };
        var round_cancel = round_budget.childToken();
        if (self.observer) |observer| if (observer.round_start) |notify| notify(observer.context);
        self.clearPending();
        self.round_text.clearRetainingCapacity();
        self.saw_done = false;
        self.last_error = null;
        self.open_text_card = null;
        const cards_start = self.cards.count();
        const reasoning_start = self.reasoning.items.len;

        var attempt: u8 = 0;
        self.retry_attempt = 0;
        while (true) {
            if (request.cancel) |token| if (token.isCancelled()) {
                self.turn.abort();
                try self.recordFailure(request.model);
                return error.Cancelled;
            };
            const audit_start = self.audit_log.len();
            var retry_after_ms: ?u32 = null;
            var attempt_request = request;
            attempt_request.cancel = &round_cancel;
            const deadline_ns = round_budget.deadline();
            const remaining_ns: i128 = @min(deadline_ns - timing.now(), if (self.shared_task) |shared| @as(i128, try shared.root.remainingNs()) else std.math.maxInt(i128));
            if (remaining_ns <= 0) {
                self.turn.abort();
                try self.recordFailure(request.model);
                return error.Timeout;
            }
            // The transport accepts milliseconds; round up its local limit,
            // then enforce the exact shared deadline again on completion.
            attempt_request.timeout_ms = @intCast(@divTrunc(remaining_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms));
            attempt_request.retry_after_ms = &retry_after_ms;
            self.retry_attempt = attempt;
            self.publishContextUsage(attempt_request, null, 0);
            const result = p.chat(p.ctx, attempt_request, receive, self);
            if (retry_after_ms) |delay| self.cooldown_deadline_ms = monotonicMs() +| delay;
            // Stop wins on both success and failure. Providers and their
            // epilogues must also stay within the original retry budget.
            const cancelled = round_cancel.cancelled.load(.acquire) or if (request.cancel) |token| token.isCancelled() else false;
            const timed_out = round_budget.reason() != null or if (self.shared_task) |shared| expired: {
                shared.root.check() catch break :expired true;
                break :expired false;
            } else false;
            if (cancelled or timed_out) {
                self.audit_log.truncate(audit_start);
                self.turn.abort();
                try self.recordFailure(request.model);
                return if (cancelled) error.Cancelled else error.Timeout;
            }
            if (result) |stats| {
                if (self.last_error != null or !self.saw_done) {
                    self.audit_log.truncate(audit_start);
                    self.turn.abort();
                    try self.recordFailure(request.model);
                    return if (self.last_error != null) error.StreamCallbackFailed else error.ProviderMissingDone;
                }
                if (stats.usage_reported and stats.input_tokens > 0) self.last_context_usage = @import("context_usage.zig").Sample.capture(attempt_request, stats.input_tokens) catch null;
                self.publishContextUsage(attempt_request, if (stats.usage_reported and stats.input_tokens > 0) stats.input_tokens else null, self.round_text.items.len);
                var reported = stats;
                reported.request_count = @as(u32, attempt) + 1;
                return reported;
            } else |err| {
                self.audit_log.truncate(audit_start);
                if (!retry.isRetryable(err) or (request.workspace_revision != null and err != error.RequestRejected and err != error.RateLimited)) {
                    self.turn.abort();
                    try self.recordFailure(request.model);
                    return err;
                }
                if (self.retry_policy.delay(attempt)) |delay_ms| {
                    const actual_delay = @max(delay_ms, retry_after_ms orelse 0);
                    // Do not retry ahead of Retry-After or wait indefinitely
                    // when the server asks for a delay beyond this turn's budget.
                    const retry_deadline = @min(round_budget.deadline(), if (self.shared_task) |shared| timing.now() + @as(i128, try shared.root.remainingNs()) else std.math.maxInt(i128));
                    if (@as(i128, actual_delay) * std.time.ns_per_ms >= retry_deadline - timing.now()) {
                        self.turn.abort();
                        try self.recordFailure(request.model);
                        return error.Timeout;
                    }
                    retry.waitWithTiming(actual_delay, request.cancel, retry_deadline, timing) catch |wait_err| {
                        self.turn.abort();
                        try self.recordFailure(request.model);
                        return wait_err;
                    };
                    if (self.input) |inbox| if (request.workspace_revision) |revision| {
                        if (inbox.workspaceRevision() != revision) return error.WorkspaceChanged;
                    };
                    attempt += 1;
                    if (self.observer) |observer| observer.reset(observer.context);
                    self.truncateCards(cards_start);
                    self.open_text_card = null; // retry restarts the text run
                    self.reasoning.shrinkRetainingCapacity(reasoning_start);
                    self.round_text.clearRetainingCapacity();
                    self.clearPending();
                    self.last_error = null;
                    self.saw_done = false;
                    continue;
                } else |_| {
                    self.turn.abort();
                    try self.audit_log.append(.{
                        .timestamp_ms = self.timestamp_ms,
                        .turn_id = self.turn_id,
                        .command = self.command,
                        .verdict = "stream_failed",
                        .target = request.model,
                    });
                    return err;
                }
            }
        }
    }

    fn receive(ctx: *anyopaque, delta: provider.Delta) void {
        const self: *Manager = @ptrCast(@alignCast(ctx));
        if (delta == .text and delta.text.len == 0) return;
        if (self.saw_done) {
            if (delta != .done) self.last_error = "delta after completed provider round";
            return;
        }
        if (delta != .tool_plan) if (self.observer) |observer| observer.delta(observer.context, delta) catch {
            self.last_error = "live output delivery failed";
        };
        switch (delta) {
            .text => |value| {
                if (self.live_context_usage.appendText(value.len)) |snapshot| self.notifyContextUsage(snapshot);
                self.round_text.appendSlice(self.allocator, value) catch {
                    self.last_error = "response allocation failed";
                };
                self.appendText(value) catch {
                    self.last_error = "card allocation failed";
                };
            },
            .thinking => |value| {
                self.reasoning.appendSlice(self.allocator, value) catch {
                    self.last_error = "card allocation failed";
                };
            },
            .tool_plan => |value| {
                self.queueTool(value.index, value.call_id, value.name, value.arguments) catch {
                    self.last_error = "invalid or oversized tool stream";
                };
            },
            .done => {
                if (self.tool_run == null) self.flushTools() catch {
                    self.last_error = "invalid tool call";
                };
                self.saw_done = true;
            },
            .err => |value| self.retainProviderError(value),
        }
    }

    fn retainProviderError(self: *Manager, message: []const u8) void {
        var keep = @min(message.len, self.last_error_storage.len);
        while (keep > 0 and !std.unicode.utf8ValidateSlice(message[0..keep])) keep -= 1;
        @memcpy(self.last_error_storage[0..keep], message[0..keep]);
        self.last_error = self.last_error_storage[0..keep];
    }

    fn recordFailure(self: *Manager, target: []const u8) !void {
        try self.audit_log.append(.{
            .timestamp_ms = self.timestamp_ms,
            .turn_id = self.turn_id,
            .command = self.command,
            .verdict = "stream_failed",
            .target = target,
        });
    }

    fn execute(raw: *anyopaque, invocation: tool_loop.Invocation, allocator: std.mem.Allocator, cancel: ?*provider.CancelToken) !tool_loop.Outcome {
        const self: *Manager = @ptrCast(@alignCast(raw));
        self.publishTranscriptUsage();
        self.turn.state = if (invocation.verdict == .need_confirm) .await_confirm else .executing;
        const host = self.tool_host.?;
        return host.execute(host.context, invocation, allocator, cancel);
    }

    fn executeDynamic(raw: *anyopaque, invocation: @import("plugin_tools.zig").DynamicInvocation, allocator: std.mem.Allocator, cancel: ?*provider.CancelToken) ![]@import("plugin_tools.zig").ToolResult {
        const self: *Manager = @ptrCast(@alignCast(raw));
        self.publishTranscriptUsage();
        const engine = self.permissionEngine();
        self.turn.state = if (try @import("plugin_tools.zig").callNeedsApproval(invocation.parsed, .{ .engine = engine, .full_control = engine.mode == .auto }, invocation.table.captured_scope.owner == .group)) .await_confirm else .executing;
        const host = self.tool_host.?;
        const execute_dynamic = host.execute_dynamic orelse return error.DynamicToolHostUnavailable;
        return execute_dynamic(host.context, invocation, allocator, cancel);
    }
    fn executeHost(raw: *anyopaque, invocation: @import("host_tools.zig").Invocation, allocator: std.mem.Allocator, cancel: ?*provider.CancelToken) !@import("host_tools.zig").Result {
        const self: *Manager = @ptrCast(@alignCast(raw));
        self.publishTranscriptUsage();
        self.turn.state = .executing;
        const host = self.tool_host.?;
        const execute_host = host.execute_host orelse return error.ToolNotAvailable;
        return execute_host(host.context, invocation, allocator, cancel);
    }
    fn acceptedHostResult(raw: *anyopaque, context: @import("host_tools.zig").Context, name: []const u8, result: *const @import("host_tools.zig").Result, cancel: ?*provider.CancelToken) !void {
        const self: *Manager = @ptrCast(@alignCast(raw));
        const host = self.tool_host orelse return error.ToolHostUnavailable;
        if (host.accepted_host_result) |accepted| try accepted(host.context, context, name, result, cancel);
    }

    fn completeTools(self: *Manager, cancel: ?*provider.CancelToken, policy: permission.Engine, policy_revision: u64) !void {
        defer self.publishTranscriptUsage();
        defer self.clearPending();
        // Sort the received slots, without allocating from a provider-supplied
        // index or imposing a fixed batch size.
        std.mem.sort(PendingTool, self.pending_tools.items, {}, struct {
            fn less(_: void, left: PendingTool, right: PendingTool) bool {
                return left.index < right.index;
            }
        }.less);
        const calls = try self.allocator.alloc(provider.ToolCall, self.pending_tools.items.len);
        defer self.allocator.free(calls);
        for (self.pending_tools.items, calls) |tool, *call| {
            call.* = .{ .id = tool.call_id orelse return error.MissingToolCallId, .name = tool.name orelse return error.MissingToolName, .arguments = tool.arguments.items };
        }
        const loop = self.tool_run.?;
        const records_start = loop.records.items.len;
        try loop.complete(self.round_text.items, calls, .{ .context = self, .execute = execute, .current_permission = currentPermission, .execute_dynamic = executeDynamic, .execute_host = executeHost, .accepted_host_result = acceptedHostResult }, policy, policy_revision, cancel);
        if (self.observer) |observer| if (observer.tool_rejected) |notify| {
            for (calls) |call| {
                const record = blk: {
                    for (loop.records.items) |*record| if (std.mem.eql(u8, record.key.call_id, call.id)) break :blk record;
                    break :blk null;
                };
                if (record) |result| {
                    if (!result.dispatched) try notify(observer.context, call, result.result_body orelse "工具未执行");
                } else try notify(observer.context, call, "缺少工具调用回执");
            }
        };
        self.open_text_card = null;
        for (loop.records.items[records_start..]) |record| {
            try self.audit_log.append(.{ .timestamp_ms = self.timestamp_ms, .turn_id = self.turn_id, .command = record.arguments, .verdict = if (record.dispatched) "tool_result" else "tool_rejected", .target = record.name, .call_id = record.key.call_id });
            // Structured facts live in the owned ledger/transcript. Do not
            // render protocol JSON as an assistant answer or map unknown to
            // the legacy Card.Phase.failed/aborted projection.
        }
    }

    fn notifyContextUsage(self: *Manager, snapshot: @import("live_context_usage.zig").Snapshot) void {
        if (self.observer) |observer| if (observer.context_usage) |notify| notify(observer.context, self.turn_id, snapshot);
    }
    fn publishContextUsage(self: *Manager, request: provider.ChatRequest, measured: ?u32, response_bytes: usize) void {
        const observer = self.observer orelse return;
        if (observer.context_usage == null) return;
        const snapshot = self.live_context_usage.update(request, measured, response_bytes) catch return;
        self.notifyContextUsage(snapshot);
    }
    fn publishTranscriptUsage(self: *Manager) void {
        const loop = self.tool_run orelse return;
        var request = loop.request;
        request.messages = loop.messages.items;
        self.publishContextUsage(request, null, 0);
    }

    fn truncateCards(self: *Manager, count: usize) void {
        for (self.cards.cards.items[count..]) |card| switch (card) {
            .text => |text| self.allocator.free(text),
            .code => |value| {
                self.allocator.free(value.lang);
                self.allocator.free(value.body);
            },
            .exec_plan => |value| {
                self.allocator.free(value.cmd);
                if (value.call_id) |id| self.allocator.free(id);
            },
            .exec_state => |value| self.allocator.free(value.summary),
            .file_ref => |value| self.allocator.free(value.path),
        };
        self.cards.cards.shrinkRetainingCapacity(count);
    }

    fn appendText(self: *Manager, value: []const u8) !void {
        // Delta aggregation: merge into the open card of this turn; a
        // non-text card (exec plan etc.) in between closes the run.
        if (self.open_text_card) |index| {
            return self.cards.appendText(index, value);
        }
        const index = try self.cards.append(.{ .text = value });
        self.open_text_card = index;
    }

    fn appendPlan(self: *Manager, call_id: ?[]const u8, value: []const u8) !void {
        self.open_text_card = null; // tool call breaks the text run
        try self.audit_log.append(.{ .timestamp_ms = self.timestamp_ms, .turn_id = self.turn_id, .command = value, .verdict = "tool_plan", .target = "provider", .call_id = call_id });
        _ = try self.cards.append(.{ .exec_plan = .{
            .cmd = value,
            .verdict = permission.classify(self.permissionEngine(), value, false),
            .call_id = call_id,
        } });
    }

    fn queueTool(self: *Manager, index: u32, call_id: ?[]const u8, name: ?[]const u8, arguments: []const u8) !void {
        if (call_id) |id| if (id.len == 0 or id.len > provider.max_tool_call_id_bytes or std.mem.indexOfScalar(u8, id, 0) != null) return error.InvalidToolCall;
        if (name) |value| if (value.len == 0 or value.len > provider.max_tool_name_bytes) return error.InvalidToolCall;
        var found: ?usize = null;
        for (self.pending_tools.items, 0..) |tool, i| if (tool.index == index) {
            found = i;
            break;
        };
        if (found == null) {
            try self.pending_tools.append(self.allocator, .{ .index = index });
            found = self.pending_tools.items.len - 1;
        }
        const tool = &self.pending_tools.items[found.?];
        if (call_id) |id| {
            if (tool.call_id) |old| {
                if (!std.mem.eql(u8, old, id)) return error.ToolIdChanged;
            } else tool.call_id = try self.allocator.dupe(u8, id);
        }
        if (name) |tool_name| {
            if (tool.name) |old| {
                if (!std.mem.eql(u8, old, tool_name)) return error.ToolNameChanged;
            } else tool.name = try self.allocator.dupe(u8, tool_name);
        }
        var argument_limit: usize = 64 * 1024;
        if (self.tool_run) |active_loop| if (active_loop.tool_table) |*table| if (tool.name) |tool_name| if (table.lookup(tool_name)) |entry| {
            argument_limit = entry.definition.max_argument_bytes;
        };
        if (arguments.len > argument_limit -| tool.arguments.items.len) return error.ToolArgumentsTooLarge;
        try tool.arguments.appendSlice(self.allocator, arguments);
        if (self.observer) |observer| try observer.delta(observer.context, .{ .tool_plan = .{ .index = index, .call_id = tool.call_id, .name = tool.name, .arguments = tool.arguments.items } });
    }

    fn flushTools(self: *Manager) !void {
        defer self.clearPending();
        for (self.pending_tools.items) |tool| {
            if (self.scope) |scope| {
                const name = tool.name orelse return error.MissingToolName;
                var parsed = try tool_scope.parse(self.allocator, scope, name, tool.arguments.items);
                defer parsed.deinit();
                if (tool.call_id == null) return error.MissingToolCallId;
                self.open_text_card = null;
                const call = parsed.call;
                const command = if (call.tool == .run_command) call.command else call.path;
                _ = try self.cards.append(.{ .exec_plan = .{
                    .cmd = command,
                    .call_id = tool.call_id,
                    .tool = call.tool,
                    .owner = scope.owner,
                    .targets = call.targets,
                    .verdict = if (call.tool == .run_command) permission.classify(self.permissionEngine(), command, scope.owner == .group) else .allow_auto,
                } });
                try self.audit_log.append(.{ .timestamp_ms = self.timestamp_ms, .turn_id = self.turn_id, .command = tool.arguments.items, .verdict = "scoped_tool_plan", .target = name, .call_id = tool.call_id });
            } else {
                // Legacy unbound test providers remain display-only. No
                // command may acquire execution authority from UI focus.
                try self.appendPlan(tool.call_id, tool.arguments.items);
                self.cards.cards.items[self.cards.count() - 1].exec_plan.verdict = .deny_exec_copy_only;
            }
        }
    }
};

fn monotonicMs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

const TestRetryTiming = struct {
    ns: i128 = 0,
    oversleep_ns: ?u64 = null,
    sleeps: usize = 0,
    stop_on_wake: ?*provider.CancelToken = null,
    pub fn now(self: *@This()) i128 {
        return self.ns;
    }
    pub fn sleep(self: *@This(), ns: u64) void {
        self.sleeps += 1;
        self.ns += self.oversleep_ns orelse ns;
        if (self.stop_on_wake) |token| token.cancel();
    }
};
const TestRetryProvider = struct {
    const Step = struct { work_ms: u32 = 0, resource_wait_ms: u32 = 0, err: ?anyerror = null, hint_ms: ?u32 = null, stop: bool = false };
    timing: *TestRetryTiming,
    steps: []const Step,
    calls: usize = 0,
    budgets: [4]u32 = @splat(0),
    fn chat(raw: *anyopaque, request: provider.ChatRequest, sink: *const fn (*anyopaque, provider.Delta) void, ctx: *anyopaque) !provider.ChatStats {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.calls >= self.steps.len or self.calls >= self.budgets.len) return error.UnexpectedRetry;
        self.budgets[self.calls] = request.timeout_ms;
        const step = self.steps[self.calls];
        self.calls += 1;
        const waiting = provider.CancelToken.beginResourceWait(request.cancel);
        self.timing.ns += @as(i128, step.resource_wait_ms) * std.time.ns_per_ms;
        waiting.end();
        self.timing.ns += @as(i128, step.work_ms) * std.time.ns_per_ms;
        if (step.hint_ms) |hint| request.retry_after_ms.?.* = hint;
        if (step.stop) request.cancel.?.cancel();
        if (step.err) |err| return err;
        sink(ctx, .done);
        return .{ .output_tokens = 1 };
    }
    fn models(_: *anyopaque, allocator: std.mem.Allocator) ![]provider.ModelInfo {
        return allocator.alloc(provider.ModelInfo, 0);
    }
    fn interface(self: *@This()) provider.Provider {
        return .{ .ctx = self, .chat = chat, .models = models };
    }
};
test "retry deadline attempts share provider work and Retry-After wait budget" {
    var timing: TestRetryTiming = .{};
    var scripted: TestRetryProvider = .{ .timing = &timing, .steps = &.{
        .{ .work_ms = 20, .err = error.RequestRejected, .hint_ms = 10 },
        .{ .work_ms = 30, .err = error.Transient },
        .{},
    } };
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    manager.retry_policy = .{ .delays_ms = .{ 5, 15, 0 } };
    _ = try manager.runRoundWithTiming(scripted.interface(), .{ .model = "fixture", .system = "", .messages = &.{}, .timeout_ms = 100 }, &timing);
    try std.testing.expectEqual(@as(usize, 3), scripted.calls);
    try std.testing.expectEqualSlices(u32, &.{ 100, 70, 25 }, scripted.budgets[0..3]);
    try std.testing.expectEqual(@as(usize, 2), timing.sleeps);
}
test "retry deadline model capacity wait pauses only waiting time across retries" {
    var timing: TestRetryTiming = .{};
    var scripted: TestRetryProvider = .{ .timing = &timing, .steps = &.{
        .{ .resource_wait_ms = 800, .work_ms = 20, .err = error.Transient },
        .{ .resource_wait_ms = 1200, .work_ms = 30 },
    } };
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    manager.retry_policy = .{ .delays_ms = .{ 10, 0, 0 } };
    _ = try manager.runRoundWithTiming(scripted.interface(), .{ .model = "fixture", .system = "", .messages = &.{}, .timeout_ms = 100 }, &timing);
    try std.testing.expectEqualSlices(u32, &.{ 100, 70 }, scripted.budgets[0..2]);
    try std.testing.expectEqual(@as(i128, 2060 * std.time.ns_per_ms), timing.ns);
}
test "retry deadline overslept backoff stops at the original request budget" {
    var timing: TestRetryTiming = .{ .oversleep_ns = 125 * std.time.ns_per_ms };
    var scripted: TestRetryProvider = .{ .timing = &timing, .steps = &.{.{ .work_ms = 20, .err = error.RequestRejected, .hint_ms = 60 }} };
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    manager.retry_policy = .{ .delays_ms = .{ 0, 0, 0 } };
    try std.testing.expectError(error.Timeout, manager.runRoundWithTiming(scripted.interface(), .{ .model = "fixture", .system = "", .messages = &.{}, .timeout_ms = 100 }, &timing));
    try std.testing.expectEqual(@as(usize, 1), timing.sleeps);
    try std.testing.expectEqual(@as(usize, 1), scripted.calls);
    try std.testing.expectEqual(turn_model.State.idle, manager.turn.state);
}
test "retry deadline delayed backoff wake does not spend its nominal delay again" {
    var timing: TestRetryTiming = .{ .oversleep_ns = 125 * std.time.ns_per_ms };
    var scripted: TestRetryProvider = .{ .timing = &timing, .steps = &.{ .{ .work_ms = 20, .err = error.Transient }, .{} } };
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    manager.retry_policy = .{ .delays_ms = .{ 60, 0, 0 } };
    _ = try manager.runRoundWithTiming(scripted.interface(), .{ .model = "fixture", .system = "", .messages = &.{}, .timeout_ms = 500 }, &timing);
    try std.testing.expectEqualSlices(u32, &.{ 500, 355 }, scripted.budgets[0..2]);
    try std.testing.expectEqual(@as(usize, 1), timing.sleeps);
}
test "retry deadline Stop racing failure wins over fatal exhausted and oversized backoff paths" {
    for ([_]anyerror{ error.ProviderFailure, error.RequestRejected, error.Timeout, error.Transient }) |failure| {
        var token: provider.CancelToken = .{};
        var timing: TestRetryTiming = .{};
        var scripted: TestRetryProvider = .{ .timing = &timing, .steps = &.{.{ .err = failure, .hint_ms = 2000, .stop = true }} };
        var manager = Manager.init(std.testing.allocator);
        defer manager.deinit();
        manager.retry_policy = .{ .max_attempts = if (failure == error.RequestRejected) 3 else 0 };
        try std.testing.expectError(error.Cancelled, manager.runRoundWithTiming(scripted.interface(), .{ .model = "fixture", .system = "", .messages = &.{}, .timeout_ms = 100, .cancel = &token }, &timing));
        try std.testing.expectEqual(@as(usize, 1), scripted.calls);
        try std.testing.expectEqual(@as(usize, 0), timing.sleeps);
    }
}
test "retry deadline late success or exhausted failure cannot escape the total budget" {
    for ([_]?anyerror{ null, error.Transient }) |failure| {
        var timing: TestRetryTiming = .{};
        var scripted: TestRetryProvider = .{ .timing = &timing, .steps = &.{.{ .work_ms = 70, .err = failure }} };
        var manager = Manager.init(std.testing.allocator);
        defer manager.deinit();
        manager.retry_policy.max_attempts = 0;
        try std.testing.expectError(error.Timeout, manager.runRoundWithTiming(scripted.interface(), .{ .model = "fixture", .system = "", .messages = &.{}, .timeout_ms = 70 }, &timing));
        try std.testing.expectEqual(@as(usize, 1), scripted.calls);
        try std.testing.expectEqual(turn_model.State.idle, manager.turn.state);
    }
}
test "retry deadline Stop during backoff prevents a second provider call" {
    var token: provider.CancelToken = .{};
    var timing: TestRetryTiming = .{ .stop_on_wake = &token };
    var scripted: TestRetryProvider = .{ .timing = &timing, .steps = &.{.{ .err = error.RequestRejected, .hint_ms = 60_000 }} };
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    try std.testing.expectError(error.Cancelled, manager.runRoundWithTiming(scripted.interface(), .{ .model = "fixture", .system = "", .messages = &.{}, .timeout_ms = 120_000, .cancel = &token }, &timing));
    try std.testing.expectEqual(@as(usize, 1), scripted.calls);
    try std.testing.expectEqual(@as(usize, 1), timing.sleeps);
}
test "retry deadline valid predeadline completion remains successful" {
    var timing: TestRetryTiming = .{};
    var scripted: TestRetryProvider = .{ .timing = &timing, .steps = &.{.{ .work_ms = 69 }} };
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    const stats = try manager.runRoundWithTiming(scripted.interface(), .{ .model = "fixture", .system = "", .messages = &.{}, .timeout_ms = 70 }, &timing);
    try std.testing.expectEqual(@as(u32, 1), stats.output_tokens);
    try std.testing.expect(manager.saw_done);
}

test "retry deadline native HTTP 429 long backoff can be stopped and joined" {
    const Fixture = struct {
        server: std.Io.net.Server,
        fn serve(self: *@This()) !void {
            const connection = try self.server.accept(std.testing.io);
            defer connection.close(std.testing.io);
            var buffer: [4096]u8 = undefined;
            var reader = connection.reader(std.testing.io, &buffer);
            var length: usize = 0;
            while (true) {
                const line = try reader.interface.takeDelimiterInclusive('\n');
                if (std.ascii.startsWithIgnoreCase(line, "content-length:")) length = try std.fmt.parseInt(usize, std.mem.trim(u8, line[15..], " \r\n"), 10);
                if (std.mem.eql(u8, line, "\r\n")) break;
            }
            try reader.interface.discardAll(length);
            var writer = connection.writer(std.testing.io, &.{});
            try writer.interface.writeAll("HTTP/1.1 429 Too Many Requests\r\nRetry-After: 60\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            try writer.interface.flush();
        }
    };
    const LiveTiming = struct {
        sleeping: std.atomic.Value(bool) = .init(false),
        max_sleep_ns: u64 = 0,
        pub fn now(_: *@This()) i128 {
            return (retry.Clock{}).now();
        }
        pub fn sleep(self: *@This(), ns: u64) void {
            self.max_sleep_ns = @max(self.max_sleep_ns, ns);
            self.sleeping.store(true, .release);
            (retry.Clock{}).sleep(ns);
        }
    };
    const Worker = struct {
        manager: *Manager,
        p: provider.Provider,
        request: provider.ChatRequest,
        timing: *LiveTiming,
        done: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) !provider.ChatStats {
            defer self.done.store(true, .release);
            return self.manager.runRoundWithTiming(self.p, self.request, self.timing);
        }
    };
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var fixture: Fixture = .{ .server = try address.listen(std.testing.io, .{}) };
    defer fixture.server.deinit(std.testing.io);
    var serving = try std.Io.concurrent(std.testing.io, Fixture.serve, .{&fixture});
    defer _ = serving.cancel(std.testing.io) catch {};
    var endpoint_buffer: [128]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "http://127.0.0.1:{d}/v1/chat/completions", .{fixture.server.socket.address.getPort()});
    const transport = @import("provider_transport.zig");
    var context: transport.NativeContext = .{ .io = std.testing.io };
    var client = @import("provider_client.zig").Client.native(std.testing.allocator, &context, .openai_compat);
    var binding = @import("provider_client.zig").Client.Binding{ .client = &client, .config = @import("provider_config.zig").defaults(.openai_compat) };
    binding.config.endpoint = endpoint;
    binding.config.auth = .none;
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    var token: provider.CancelToken = .{};
    var timing: LiveTiming = .{};
    var worker: Worker = .{ .manager = &manager, .p = binding.asProvider(), .request = .{ .model = "fixture", .system = "", .messages = &.{}, .timeout_ms = 120_000, .cancel = &token }, .timing = &timing };
    var running = try std.Io.concurrent(std.testing.io, Worker.run, .{&worker});
    defer {
        token.cancel();
        _ = running.cancel(std.testing.io) catch {};
    }
    const started = (retry.Clock{}).now();
    while (!timing.sleeping.load(.acquire) and !worker.done.load(.acquire) and (retry.Clock{}).now() - started < 5 * std.time.ns_per_s) try retry.wait(1, null);
    if (!timing.sleeping.load(.acquire) and worker.done.load(.acquire)) _ = try running.await(std.testing.io);
    try std.testing.expect(timing.sleeping.load(.acquire));
    const stopped = (retry.Clock{}).now();
    token.cancel();
    try std.testing.expectError(error.Cancelled, running.await(std.testing.io));
    const stop_ms = @divTrunc((retry.Clock{}).now() - stopped, std.time.ns_per_ms);
    try serving.await(std.testing.io);
    try std.testing.expect(timing.max_sleep_ns <= 50 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u8, 0), manager.retry_attempt);
    try std.testing.expectEqual(turn_model.State.idle, manager.turn.state);
    std.debug.print("native HTTP backoff Stop joined in {d}ms\n", .{stop_ms});
}

const TestMultiRun = struct {
    const Step = struct { work_ms: u32 = 0, calls: []const []const u8 = &.{}, err: ?anyerror = null };
    const scope: tool_scope.Scope = .{ .owner = .{ .session = 101 }, .members = .{ .ids = .{101} ++ @as([15]u64, @splat(0)), .len = 1 } };
    timing: *TestRetryTiming,
    steps: []const Step,
    provider_calls: usize = 0,
    host_calls: usize = 0,
    budgets: [8]u32 = @splat(0),
    tool_work_ms: u32 = 20,
    user_wait_ms: u32 = 0,
    wait_for_cancel: bool = false,
    stop_in_tool: ?*provider.CancelToken = null,
    stop_in_ack: ?*provider.CancelToken = null,
    notice_manager: ?*Manager = null,

    fn chat(raw: *anyopaque, request: provider.ChatRequest, sink: *const fn (*anyopaque, provider.Delta) void, ctx: *anyopaque) !provider.ChatStats {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.provider_calls >= self.steps.len) return error.UnexpectedRound;
        self.budgets[self.provider_calls] = request.timeout_ms;
        const step = self.steps[self.provider_calls];
        self.provider_calls += 1;
        self.timing.ns += @as(i128, step.work_ms) * std.time.ns_per_ms;
        if (step.err) |err| return err;
        for (step.calls, 0..) |id, index| sink(ctx, .{ .tool_plan = .{ .call_id = id, .name = "read_terminal", .index = @intCast(index), .arguments = "{\"session_ids\":[101]}" } });
        sink(ctx, .done);
        return .{ .output_tokens = 1 };
    }
    fn execute(raw: *anyopaque, _: tool_loop.Invocation, allocator: std.mem.Allocator, cancel: ?*provider.CancelToken) !tool_loop.Outcome {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.host_calls += 1;
        if (self.user_wait_ms != 0) {
            const waiting = provider.CancelToken.beginUserWait(cancel);
            defer waiting.end();
            self.timing.ns += @as(i128, self.user_wait_ms) * std.time.ns_per_ms;
            if (cancel.?.isCancelled()) return error.UserWaitExpired;
        }
        self.timing.ns += @as(i128, self.tool_work_ms) * std.time.ns_per_ms;
        if (self.wait_for_cancel) {
            var ticks: usize = 0;
            while (!cancel.?.isCancelled() and ticks < 100) : (ticks += 1) self.timing.ns += 10 * std.time.ns_per_ms;
            if (!cancel.?.isCancelled()) return error.DeadlineNotPropagated;
        }
        if (self.stop_in_tool) |token| token.cancel();
        if (self.notice_manager) |manager| manager.tool_run.?.notice_revision = 1;
        return tool_loop.Outcome.copy(allocator, &.{.{ .session_id = 101, .status = if (self.wait_for_cancel) .cancelled else .succeeded, .stdout = "retained exact result", .exit = if (self.wait_for_cancel) null else 0 }});
    }
    fn acknowledge(raw: *anyopaque, _: u64, _: ?*provider.CancelToken) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.stop_in_ack) |token| token.cancel();
    }
    fn interface(self: *@This()) provider.Provider {
        return .{ .ctx = self, .chat = chat, .models = TestRetryProvider.models };
    }
    fn makeManager(self: *@This()) Manager {
        var result = Manager.init(std.testing.allocator);
        result.scope = scope;
        result.turn_id = 91;
        result.tool_host = .{ .context = self, .execute = execute, .acknowledge_notice = acknowledge };
        result.retry_policy = .{ .delays_ms = .{ 0, 0, 0 } };
        return result;
    }
    fn makeRequest(stop: ?*provider.CancelToken, ms: u32) provider.ChatRequest {
        return .{ .model = "fixture", .system = "", .messages = &.{}, .tools = &.{.{ .tool = .read_terminal, .session_ids = &.{101} }}, .timeout_ms = ms, .run_timeout_ms = ms, .cancel = stop };
    }
};
const TestRunSetup = struct {
    timing: *TestRetryTiming,
    work_ms: u32,
    resets: usize = 0,
    fn reset(raw: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.resets == 0) self.timing.ns += @as(i128, self.work_ms) * std.time.ns_per_ms;
        self.resets += 1;
    }
    fn delta(_: *anyopaque, _: provider.Delta) !void {}
    fn observer(self: *@This()) Manager.Observer {
        return .{ .context = self, .reset = reset, .delta = delta };
    }
};
test "tool deadline provider and tool rounds consume one automatic run budget" {
    var timing: TestRetryTiming = .{};
    var fixture: TestMultiRun = .{ .timing = &timing, .tool_work_ms = 10, .steps = &.{
        .{ .work_ms = 30, .calls = &.{"first"} },
        .{ .work_ms = 40, .calls = &.{"second"} },
        .{ .work_ms = 5 },
    } };
    var manager = fixture.makeManager();
    defer manager.deinit();
    var stop: provider.CancelToken = .{};
    _ = try manager.runWithTiming(fixture.interface(), TestMultiRun.makeRequest(&stop, 100), &timing);
    try std.testing.expectEqualSlices(u32, &.{ 100, 60, 10 }, fixture.budgets[0..3]);
    try std.testing.expectEqual(@as(usize, 2), fixture.host_calls);
    try std.testing.expectEqual(@as(usize, 2), manager.tool_run.?.records.items.len);
    try std.testing.expectEqual(&stop, manager.tool_run.?.request.cancel.?);
    try std.testing.expect(!stop.isCancelled());
}
test "tool deadline a late followup cannot receive a fresh original timeout" {
    var timing: TestRetryTiming = .{};
    var fixture: TestMultiRun = .{ .timing = &timing, .steps = &.{ .{ .work_ms = 40, .calls = &.{"first"} }, .{ .work_ms = 50 } } };
    var manager = fixture.makeManager();
    defer manager.deinit();
    try std.testing.expectError(error.Timeout, manager.runWithTiming(fixture.interface(), TestMultiRun.makeRequest(null, 100), &timing));
    try std.testing.expectEqual(@as(u32, 40), fixture.budgets[1]);
    try std.testing.expectEqual(@as(usize, 1), fixture.host_calls);
    try std.testing.expectEqualStrings("retained exact result", manager.tool_run.?.records.items[0].outcome.?.targets[0].stdout);
    try std.testing.expectEqual(turn_model.State.idle, manager.turn.state);
}
test "tool deadline expiry after a known result prevents remaining batch dispatch" {
    var timing: TestRetryTiming = .{};
    var fixture: TestMultiRun = .{ .timing = &timing, .tool_work_ms = 60, .steps = &.{.{ .work_ms = 40, .calls = &.{ "first", "second" } }} };
    var manager = fixture.makeManager();
    defer manager.deinit();
    try std.testing.expectError(error.Timeout, manager.runWithTiming(fixture.interface(), TestMultiRun.makeRequest(null, 100), &timing));
    const run = manager.tool_run.?;
    try std.testing.expectEqual(@as(usize, 1), fixture.host_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.provider_calls);
    try std.testing.expect(run.records.items[0].dispatched);
    try std.testing.expect(!run.records.items[1].dispatched);
    try std.testing.expectEqual(@as(?i32, 0), run.records.items[0].outcome.?.targets[0].exit);
    try @import("provider_http.zig").validateToolMessages(run.request);
}
test "tool deadline blocked tool observes expiry without cancelling the caller Stop token" {
    var timing: TestRetryTiming = .{};
    var fixture: TestMultiRun = .{ .timing = &timing, .wait_for_cancel = true, .steps = &.{.{ .calls = &.{"waiting"} }} };
    var manager = fixture.makeManager();
    defer manager.deinit();
    var stop: provider.CancelToken = .{};
    try std.testing.expectError(error.Timeout, manager.runWithTiming(fixture.interface(), TestMultiRun.makeRequest(&stop, 100), &timing));
    try std.testing.expect(!stop.isCancelled());
    try std.testing.expectEqual(tool_loop.Status.cancelled, manager.tool_run.?.records.items[0].outcome.?.targets[0].status);
    try std.testing.expectEqual(@as(usize, 1), fixture.host_calls);
}
test "tool deadline external Stop preserves the completed result and wins before continuation" {
    var stop: provider.CancelToken = .{};
    var timing: TestRetryTiming = .{};
    var fixture: TestMultiRun = .{ .timing = &timing, .stop_in_tool = &stop, .steps = &.{.{ .calls = &.{"completed"} }} };
    var manager = fixture.makeManager();
    defer manager.deinit();
    try std.testing.expectError(error.Cancelled, manager.runWithTiming(fixture.interface(), TestMultiRun.makeRequest(&stop, 100), &timing));
    try std.testing.expectEqual(tool_loop.Status.succeeded, manager.tool_run.?.records.items[0].outcome.?.targets[0].status);
    try std.testing.expectEqual(@as(usize, 1), fixture.provider_calls);
}
test "tool deadline initial preparation belongs to the original run budget" {
    var timing: TestRetryTiming = .{};
    var fixture: TestMultiRun = .{ .timing = &timing, .steps = &.{.{}} };
    var manager = fixture.makeManager();
    defer manager.deinit();
    try manager.turn.begin();
    try manager.turn.stream();
    try manager.turn.done();
    var setup: TestRunSetup = .{ .timing = &timing, .work_ms = 100 };
    manager.observer = setup.observer();
    try std.testing.expectError(error.Timeout, manager.runWithTiming(fixture.interface(), TestMultiRun.makeRequest(null, 100), &timing));
    try std.testing.expectEqual(@as(usize, 0), fixture.provider_calls);
    try std.testing.expectEqual(turn_model.State.idle, manager.turn.state);
}
test "tool deadline Stop during notice acknowledgement cannot finish the run" {
    var stop: provider.CancelToken = .{};
    var timing: TestRetryTiming = .{};
    var fixture: TestMultiRun = .{ .timing = &timing, .stop_in_ack = &stop, .steps = &.{ .{ .calls = &.{"completed"} }, .{} } };
    var manager = fixture.makeManager();
    defer manager.deinit();
    fixture.notice_manager = &manager;
    try std.testing.expectError(error.Cancelled, manager.runWithTiming(fixture.interface(), TestMultiRun.makeRequest(&stop, 100), &timing));
    try std.testing.expectEqual(@as(u64, 0), manager.tool_run.?.wire_notice_revision);
    try std.testing.expectEqual(turn_model.State.idle, manager.turn.state);
}
test "tool deadline manual answer retry gets one fresh budget including setup and automatic retries" {
    var timing: TestRetryTiming = .{};
    var fixture: TestMultiRun = .{ .timing = &timing, .steps = &.{ .{ .work_ms = 40, .calls = &.{"completed"} }, .{ .err = error.Transient }, .{ .work_ms = 20, .err = error.Transient }, .{ .work_ms = 2 } } };
    var manager = fixture.makeManager();
    defer manager.deinit();
    manager.retry_policy.max_attempts = 0;
    var original_stop: provider.CancelToken = .{};
    try std.testing.expectError(error.Transient, manager.runWithTiming(fixture.interface(), TestMultiRun.makeRequest(&original_stop, 100), &timing));
    const saved = manager.tool_run.?;
    original_stop.cancel();
    timing.ns += 10_000 * std.time.ns_per_ms;
    var setup: TestRunSetup = .{ .timing = &timing, .work_ms = 70 };
    manager.observer = setup.observer();
    manager.retry_policy = .{ .max_attempts = 1, .delays_ms = .{ 5, 0, 0 } };
    var resumed_stop: provider.CancelToken = .{};
    _ = try manager.resumeAnswerWithTiming(fixture.interface(), &resumed_stop, &timing);
    try std.testing.expectEqualSlices(u32, &.{ 30, 5 }, fixture.budgets[2..4]);
    try std.testing.expectEqual(@as(usize, 1), fixture.host_calls);
    try std.testing.expectEqual(saved, manager.tool_run.?);
    try std.testing.expectEqual(&original_stop, saved.request.cancel.?);
    try std.testing.expect(!resumed_stop.isCancelled());
}
test "tool deadline manual answer retry cannot restart its budget after preparation" {
    var timing: TestRetryTiming = .{};
    var fixture: TestMultiRun = .{ .timing = &timing, .steps = &.{ .{ .calls = &.{"completed"} }, .{ .err = error.Transient }, .{} } };
    var manager = fixture.makeManager();
    defer manager.deinit();
    manager.retry_policy.max_attempts = 0;
    try std.testing.expectError(error.Transient, manager.runWithTiming(fixture.interface(), TestMultiRun.makeRequest(null, 100), &timing));
    var setup: TestRunSetup = .{ .timing = &timing, .work_ms = 100 };
    manager.observer = setup.observer();
    try std.testing.expectError(error.Timeout, manager.resumeAnswerWithTiming(fixture.interface(), null, &timing));
    try std.testing.expectEqual(@as(usize, 2), fixture.provider_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.host_calls);
    try std.testing.expectEqual(turn_model.State.idle, manager.turn.state);
}
test "tool deadline cancelled answer retry wins over cooldown without touching the ledger" {
    var timing: TestRetryTiming = .{};
    var fixture: TestMultiRun = .{ .timing = &timing, .steps = &.{.{ .err = error.Transient }} };
    var manager = fixture.makeManager();
    defer manager.deinit();
    manager.retry_policy.max_attempts = 0;
    try std.testing.expectError(error.Transient, manager.runWithTiming(fixture.interface(), TestMultiRun.makeRequest(null, 100), &timing));
    const saved = manager.tool_run.?;
    manager.cooldown_deadline_ms = monotonicMs() + 60_000;
    var stop: provider.CancelToken = .{};
    stop.cancel();
    try std.testing.expectError(error.Cancelled, manager.resumeAnswerWithTiming(fixture.interface(), &stop, &timing));
    try std.testing.expectEqual(saved, manager.tool_run.?);
    try std.testing.expectEqual(@as(usize, 1), fixture.provider_calls);
}

test "tool deadline native pending controller acknowledgement exits on Stop and total timeout" {
    const Bridge = @import("../ui/ai_tools.zig").Bridge;
    const Fixture = struct {
        bridge: *Bridge,
        manager: *Manager,
        chats: usize = 0,
        executions: usize = 0,
        fn chat(raw: *anyopaque, _: provider.ChatRequest, sink: *const fn (*anyopaque, provider.Delta) void, ctx: *anyopaque) !provider.ChatStats {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.chats += 1;
            if (self.chats == 1) sink(ctx, .{ .tool_plan = .{ .call_id = "completed", .name = "read_terminal", .arguments = "{\"session_ids\":[101]}" } });
            sink(ctx, .done);
            return .{};
        }
        fn execute(raw: *anyopaque, _: tool_loop.Invocation, allocator: std.mem.Allocator, _: ?*provider.CancelToken) !tool_loop.Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.executions += 1;
            self.manager.tool_run.?.notice_revision = 1;
            return tool_loop.Outcome.copy(allocator, &.{.{ .session_id = 101, .status = .succeeded, .exit = 0, .stdout = "native retained fact" }});
        }
        fn unexpected(_: *anyopaque) !void {
            return error.UnexpectedControllerDispatch;
        }
        fn acknowledge(raw: *anyopaque, _: u64, cancel: ?*provider.CancelToken) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try self.bridge.callController(self, unexpected, cancel);
        }
    };
    const Worker = struct {
        manager: *Manager,
        p: provider.Provider,
        request: provider.ChatRequest,
        done: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) !provider.ChatStats {
            defer self.done.store(true, .release);
            return self.manager.run(self.p, self.request);
        }
    };
    for ([_]bool{ true, false }) |explicit_stop| {
        var bridge = Bridge.init(std.testing.allocator);
        defer bridge.deinit();
        var manager = Manager.init(std.testing.allocator);
        defer manager.deinit();
        manager.scope = TestMultiRun.scope;
        var fixture: Fixture = .{ .bridge = &bridge, .manager = &manager };
        manager.tool_host = .{ .context = &fixture, .execute = Fixture.execute, .acknowledge_notice = Fixture.acknowledge };
        var stop: provider.CancelToken = .{};
        var worker: Worker = .{ .manager = &manager, .p = .{ .ctx = &fixture, .chat = Fixture.chat, .models = TestRetryProvider.models }, .request = TestMultiRun.makeRequest(&stop, if (explicit_stop) 10_000 else 500) };
        var running = try std.Io.concurrent(std.testing.io, Worker.run, .{&worker});
        defer {
            stop.cancel();
            _ = running.cancel(std.testing.io) catch {};
        }
        const start = (retry.Clock{}).now();
        while (bridge.quiescent() != false and !worker.done.load(.acquire) and (retry.Clock{}).now() - start < 5 * std.time.ns_per_s) try retry.wait(1, null);
        try std.testing.expectEqual(@as(?bool, false), bridge.quiescent());
        const stop_at = (retry.Clock{}).now();
        if (explicit_stop) stop.cancel();
        // A failed deadline implementation must fail instead of hanging this
        // fixture. The cleanup token is never mistaken for a passed timeout.
        while (!worker.done.load(.acquire) and (retry.Clock{}).now() - start < 5 * std.time.ns_per_s) try retry.wait(1, null);
        if (!worker.done.load(.acquire)) stop.cancel();
        try std.testing.expectError(if (explicit_stop) error.Cancelled else error.Timeout, running.await(std.testing.io));
        const elapsed = @divTrunc((retry.Clock{}).now() - if (explicit_stop) stop_at else start, std.time.ns_per_ms);
        try std.testing.expectEqual(@as(?bool, true), bridge.quiescent());
        try std.testing.expectEqual(@as(usize, 1), fixture.executions);
        try std.testing.expectEqual(@as(usize, 2), fixture.chats);
        try std.testing.expectEqual(@as(u64, 0), manager.tool_run.?.wire_notice_revision);
        try std.testing.expectEqualStrings("native retained fact", manager.tool_run.?.records.items[0].outcome.?.targets[0].stdout);
        if (!explicit_stop) try std.testing.expect(!stop.isCancelled());
        std.debug.print("native tool controller {s} joined in {d}ms\n", .{ if (explicit_stop) "Stop" else "deadline", elapsed });
    }
}

test "turn manager maps provider deltas into cards and audit" {
    var mock: @import("provider_mock.zig").Mock = .{ .allocator = std.testing.allocator, .response = "hello" };
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    manager.turn_id = 7;
    manager.timestamp_ms = 11;
    _ = try manager.run(mock.interface(), .{ .model = "mock", .effort = .low, .system = "", .messages = &.{} });
    try std.testing.expectEqual(@as(usize, 1), manager.cards.count());
    try std.testing.expectEqual(@as(usize, 1), manager.audit_log.len());
    try std.testing.expectEqual(turn_model.State.done, manager.turn.state);
}

test "fragmented tool call produces one plan with model selected targets" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    manager.scope = .{ .owner = .{ .group = 7 }, .members = .{ .ids = .{ 101, 102 } ++ @as([14]u64, @splat(0)), .len = 2 } };
    Manager.receive(&manager, .{ .tool_plan = .{ .call_id = "call-1", .name = "run_command", .arguments = "{\"session_ids\":[102]," } });
    Manager.receive(&manager, .{ .tool_plan = .{ .call_id = null, .arguments = "\"command\":\"df -h\"}" } });
    try std.testing.expectEqual(@as(usize, 0), manager.cards.count());
    Manager.receive(&manager, .done);
    try std.testing.expect(manager.last_error == null);
    try std.testing.expectEqual(@as(usize, 1), manager.cards.count());
    const plan = manager.cards.cards.items[0].exec_plan;
    try std.testing.expectEqualStrings("df -h", plan.cmd);
    try std.testing.expectEqualStrings("call-1", plan.call_id.?);
    try std.testing.expectEqualSlices(u64, &.{102}, plan.targets.slice());
    try std.testing.expectEqual(@as(u64, 7), plan.owner.?.group);
}

test "out of scope tool calls never produce an execution plan" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    manager.scope = .{ .owner = .{ .session = 101 }, .members = .{ .ids = .{101} ++ @as([15]u64, @splat(0)), .len = 1 } };
    Manager.receive(&manager, .{ .tool_plan = .{ .call_id = "call-2", .name = "read_remote_file", .arguments = "{\"session_ids\":[999],\"path\":\"/etc/hosts\"}" } });
    Manager.receive(&manager, .done);
    try std.testing.expect(manager.last_error != null);
    try std.testing.expectEqual(@as(usize, 0), manager.cards.count());
}

test "turn manager aggregates streamed text deltas into one card" {
    // Real-stream regression: a mimo turn delivers 100+ tiny text deltas;
    // they must merge into ONE response card, not one card per chunk.
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    try manager.turn.resetForRun();
    manager.saw_done = false;
    manager.open_text_card = null;
    manager.cards.clearRetainingCapacity();
    try manager.appendText("Hel");
    try manager.appendText("lo, ");
    try manager.appendText("world!");
    try std.testing.expectEqual(@as(usize, 1), manager.cards.count());
    try std.testing.expectEqualStrings("Hello, world!", manager.cards.cards.items[0].text);
    // A tool-plan card closes the text run; the next delta opens a new card.
    try manager.appendPlan(null, "ls");
    try manager.appendText("after");
    try std.testing.expectEqual(@as(usize, 3), manager.cards.count());
}

test "provider reasoning stays separate from the answer card across runs" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    Manager.receive(&manager, .{ .thinking = "internal reasoning" });
    Manager.receive(&manager, .{ .text = "AI_UI_FLOW_OK" });
    try std.testing.expectEqualStrings("internal reasoning", manager.reasoning.items);
    try std.testing.expectEqual(@as(usize, 1), manager.cards.count());
    try std.testing.expectEqualStrings("AI_UI_FLOW_OK", manager.cards.cards.items[0].text);
    var mock: @import("provider_mock.zig").Mock = .{ .allocator = std.testing.allocator, .response = "next answer" };
    _ = try manager.run(mock.interface(), .{ .model = "mock", .effort = .low, .system = "", .messages = &.{} });
    try std.testing.expectEqual(@as(usize, 0), manager.reasoning.items.len);
    try std.testing.expectEqualStrings("next answer", manager.cards.cards.items[0].text);
}

test "turn manager retries provider failures without stale cards" {
    const Flaky = struct {
        calls: u8 = 0,
        fn chat(ctx: *anyopaque, request: provider.ChatRequest, sink: *const fn (*anyopaque, provider.Delta) void, sink_ctx: *anyopaque) !provider.ChatStats {
            _ = request;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            if (self.calls == 1) {
                sink(sink_ctx, .{ .text = "partial" });
                return error.Transient;
            }
            sink(sink_ctx, .{ .text = "final" });
            sink(sink_ctx, .done);
            return .{ .output_tokens = 1 };
        }
        fn models(ctx: *anyopaque, allocator: std.mem.Allocator) ![]provider.ModelInfo {
            _ = ctx;
            return allocator.alloc(provider.ModelInfo, 0);
        }
    };
    var flaky: Flaky = .{};
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    manager.retry_policy = .{ .max_attempts = 2, .delays_ms = .{ 0, 0, 0 } };
    const p: provider.Provider = .{ .ctx = &flaky, .chat = Flaky.chat, .models = Flaky.models };
    _ = try manager.run(p, .{ .model = "flaky", .effort = .low, .system = "", .messages = &.{} });
    try std.testing.expectEqual(@as(u8, 2), flaky.calls);
    try std.testing.expectEqual(@as(usize, 1), manager.cards.count());
    try std.testing.expectEqualStrings("final", manager.cards.cards.items[0].text);
}

test "turn manager propagates cancellation without presenting a provider error" {
    const CancelledProvider = struct {
        fn chat(ctx: *anyopaque, request: provider.ChatRequest, sink: *const fn (*anyopaque, provider.Delta) void, sink_ctx: *anyopaque) !provider.ChatStats {
            _ = ctx;
            sink(sink_ctx, .{ .text = "partial" });
            if (request.cancel) |token| token.cancel();
            return error.Cancelled;
        }
        fn models(ctx: *anyopaque, allocator: std.mem.Allocator) ![]provider.ModelInfo {
            _ = ctx;
            return allocator.alloc(provider.ModelInfo, 0);
        }
    };
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    var token: provider.CancelToken = .{};
    const p: provider.Provider = .{ .ctx = undefined, .chat = CancelledProvider.chat, .models = CancelledProvider.models };
    try std.testing.expectError(error.Cancelled, manager.run(p, .{ .model = "cancel", .effort = .low, .system = "", .messages = &.{}, .cancel = &token }));
    try std.testing.expectEqual(turn_model.State.idle, manager.turn.state);
    try std.testing.expectEqual(@as(usize, 1), manager.cards.count());
}

test "turn manager reuses completed manager across runs" {
    var mock: @import("provider_mock.zig").Mock = .{ .allocator = std.testing.allocator, .response = "again" };
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    const request: provider.ChatRequest = .{ .model = "mock", .effort = .low, .system = "", .messages = &.{} };
    _ = try manager.run(mock.interface(), request);
    _ = try manager.run(mock.interface(), request);
    try std.testing.expectEqual(turn_model.State.done, manager.turn.state);
    try std.testing.expectEqual(@as(usize, 1), manager.cards.count());
    try std.testing.expectEqual(@as(usize, 2), manager.audit_log.len());
}

test "turn manager classifies tool plans" {
    const PlanProvider = struct {
        fn chat(ctx: *anyopaque, request: provider.ChatRequest, sink: *const fn (*anyopaque, provider.Delta) void, sink_ctx: *anyopaque) !provider.ChatStats {
            _ = ctx;
            _ = request;
            sink(sink_ctx, .{ .tool_plan = .{ .call_id = null, .arguments = "rm -rf /" } });
            sink(sink_ctx, .done);
            return .{};
        }
        fn models(ctx: *anyopaque, allocator: std.mem.Allocator) ![]provider.ModelInfo {
            _ = ctx;
            return allocator.alloc(provider.ModelInfo, 0);
        }
    };
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    var ctx: u8 = 0;
    const p: provider.Provider = .{ .ctx = &ctx, .chat = PlanProvider.chat, .models = PlanProvider.models };
    _ = try manager.run(p, .{ .model = "x", .effort = .low, .system = "", .messages = &.{} });
    try std.testing.expectEqual(permission.Verdict.deny_exec_copy_only, manager.cards.cards.items[0].exec_plan.verdict);
}

test "HTTP 429 resumes through transport client and turn manager" {
    const transport = @import("provider_transport.zig");
    const Client = @import("provider_client.zig").Client;
    const Mock = struct {
        calls: usize = 0,
        fn send(raw: *anyopaque, _: @import("provider_http.zig").RequestPlan, _: []const u8, allocator: std.mem.Allocator) !transport.Response {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            if (self.calls <= 2) return .{ .status = 429, .retry_after_ms = 0, .body = try allocator.dupe(u8, "rate limited") };
            return .{ .status = 200, .body = try allocator.dupe(u8, "data: {\"choices\":[{\"delta\":{\"content\":\"recovered\"}}]}\n\ndata: [DONE]\n\n") };
        }
    };
    var mock: Mock = .{};
    var client = Client.init(std.testing.allocator, .{ .ctx = &mock, .send = Mock.send }, .openai_compat);
    var binding = Client.Binding{ .client = &client, .config = @import("provider_config.zig").defaults(.openai_compat) };
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    manager.retry_policy = .{ .delays_ms = .{ 0, 0, 0 } };
    _ = try manager.run(binding.asProvider(), .{ .model = "m", .effort = .low, .system = "", .messages = &.{} });
    try std.testing.expectEqual(@as(usize, 3), mock.calls);
    try std.testing.expectEqual(turn_model.State.done, manager.turn.state);
    try std.testing.expectEqual(@as(usize, 1), manager.cards.count());
    try std.testing.expectEqualStrings("recovered", manager.cards.cards.items[0].text);
    try std.testing.expectEqual(@as(usize, 1), manager.audit_log.len());
}

test "Retry-After exceeding turn wait budget stops without early request" {
    const Limited = struct {
        calls: usize = 0,
        fn chat(raw: *anyopaque, request: provider.ChatRequest, _: *const fn (*anyopaque, provider.Delta) void, _: *anyopaque) !provider.ChatStats {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            request.retry_after_ms.?.* = 2000;
            return error.RequestRejected;
        }
        fn models(_: *anyopaque, allocator: std.mem.Allocator) ![]provider.ModelInfo {
            return allocator.alloc(provider.ModelInfo, 0);
        }
    };
    var limited: Limited = .{};
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    manager.retry_policy = .{ .delays_ms = .{ 0, 0, 0 } };
    try std.testing.expectError(error.Timeout, manager.run(.{ .ctx = &limited, .chat = Limited.chat, .models = Limited.models }, .{ .model = "m", .effort = .low, .system = "", .messages = &.{}, .timeout_ms = 1000 }));
    try std.testing.expectEqual(@as(usize, 1), limited.calls);
    try std.testing.expectEqual(turn_model.State.idle, manager.turn.state);
}

test "rate limit retries share the elapsed request deadline" {
    const Slow = struct {
        calls: usize = 0,
        first_budget: u32 = 0,
        fn chat(raw: *anyopaque, request: provider.ChatRequest, sink: *const fn (*anyopaque, provider.Delta) void, ctx: *anyopaque) !provider.ChatStats {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            if (self.calls == 1) {
                self.first_budget = request.timeout_ms;
                try retry.wait(20, null);
                return error.RequestRejected;
            }
            try std.testing.expect(request.timeout_ms < self.first_budget);
            sink(ctx, .done);
            return .{};
        }
        fn models(_: *anyopaque, allocator: std.mem.Allocator) ![]provider.ModelInfo {
            return allocator.alloc(provider.ModelInfo, 0);
        }
    };
    var slow: Slow = .{};
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    manager.retry_policy = .{ .delays_ms = .{ 0, 0, 0 } };
    _ = try manager.run(.{ .ctx = &slow, .chat = Slow.chat, .models = Slow.models }, .{ .model = "m", .effort = .low, .system = "", .messages = &.{}, .timeout_ms = 1000 });
    try std.testing.expectEqual(@as(usize, 2), slow.calls);
}

test "cancelled turn does not call provider and accepts a subsequent request" {
    var mock: @import("provider_mock.zig").Mock = .{ .allocator = std.testing.allocator, .response = "next" };
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    var token: provider.CancelToken = .{};
    token.cancel();
    try std.testing.expectError(error.Cancelled, manager.run(mock.interface(), .{ .model = "m", .effort = .low, .system = "", .messages = &.{}, .cancel = &token }));
    try std.testing.expectEqual(turn_model.State.idle, manager.turn.state);
    _ = try manager.run(mock.interface(), .{ .model = "m", .effort = .low, .system = "", .messages = &.{} });
    try std.testing.expectEqual(turn_model.State.done, manager.turn.state);
}

test "Stop racing provider completion cannot record stream_done" {
    const Racing = struct {
        token: *provider.CancelToken,
        fn chat(raw: *anyopaque, _: provider.ChatRequest, sink: *const fn (*anyopaque, provider.Delta) void, ctx: *anyopaque) !provider.ChatStats {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.token.cancel();
            sink(ctx, .done);
            return .{};
        }
        fn models(_: *anyopaque, allocator: std.mem.Allocator) ![]provider.ModelInfo {
            return allocator.alloc(provider.ModelInfo, 0);
        }
    };
    var token: provider.CancelToken = .{};
    var racing: Racing = .{ .token = &token };
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    try std.testing.expectError(error.Cancelled, manager.run(.{ .ctx = &racing, .chat = Racing.chat, .models = Racing.models }, .{ .model = "m", .effort = .low, .system = "", .messages = &.{}, .cancel = &token }));
    try std.testing.expectEqual(turn_model.State.idle, manager.turn.state);
    try std.testing.expectEqualStrings("stream_failed", manager.audit_log.entries.items[0].verdict);
}

test "live context usage empty text in a tool round produces no observer text or blank answer card before final response" {
    const Fixture = struct {
        usage_mailbox: @import("live_context_usage.zig").Mailbox = .{},
        rounds: usize = 0,
        executions: usize = 0,
        text_events: usize = 0,
        empty_text_events: usize = 0,
        tool_events: usize = 0,
        done_events: usize = 0,
        fn chat(raw: *anyopaque, request: provider.ChatRequest, sink: *const fn (*anyopaque, provider.Delta) void, ctx: *anyopaque) !provider.ChatStats {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.rounds += 1;
            sink(ctx, .{ .text = "" });
            switch (self.rounds) {
                1 => sink(ctx, .{ .tool_plan = .{ .call_id = "empty-delta-df", .name = "run_command", .arguments = "{\"session_ids\":[101],\"command\":\"df -h\"}" } }),
                2 => {
                    try std.testing.expectEqual(@as(usize, 1), self.executions);
                    const live = self.usage_mailbox.read(901).?;
                    try std.testing.expectEqual(@as(?usize, 1000), live.summary.measured_tokens);
                    try std.testing.expect(live.summary.tokens > 1000); // Real result already counted before the next response.

                    try std.testing.expectEqual(@as(usize, 3), request.messages.len);
                    const original = request.messages[1];
                    try std.testing.expectEqual(provider.Role.assistant, original.role);
                    try std.testing.expectEqual(@as(usize, 0), original.content.len);
                    try std.testing.expectEqual(@as(usize, 1), original.tool_calls.len);
                    try std.testing.expectEqualStrings("empty-delta-df", original.tool_calls[0].id);
                    const result = request.messages[2];
                    try std.testing.expectEqual(provider.Role.tool, result.role);
                    try std.testing.expectEqualStrings("empty-delta-df", result.tool_call_id.?);
                    sink(ctx, .{ .text = "DF_READONLY_DONE" });
                    sink(ctx, .{ .text = "" });
                },
                else => return error.UnexpectedProviderRound,
            }
            sink(ctx, .done);
            return .{ .input_tokens = @intCast(self.rounds * 1000), .output_tokens = 50 };
        }
        fn models(_: *anyopaque, allocator: std.mem.Allocator) ![]provider.ModelInfo {
            return allocator.alloc(provider.ModelInfo, 0);
        }
        fn execute(raw: *anyopaque, invocation: tool_loop.Invocation, allocator: std.mem.Allocator, _: ?*provider.CancelToken) !tool_loop.Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try std.testing.expectEqualStrings("df -h", invocation.call.command);
            const live = self.usage_mailbox.read(901).?;
            try std.testing.expectEqual(@as(?usize, 1000), live.summary.measured_tokens);
            try std.testing.expect(live.summary.tokens > 1000); // Current tool call is counted while the command is still running.

            self.executions += 1;
            return tool_loop.Outcome.copy(allocator, &.{.{ .session_id = 101, .status = .succeeded, .transport = .local, .stdout = "Filesystem Size Used Avail Capacity Mounted on", .exit = 0, .local_released = true }});
        }
        fn usage(raw: *anyopaque, turn: u64, snapshot: @import("live_context_usage.zig").Snapshot) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.usage_mailbox.publish(turn, snapshot);
        }
        fn reset(_: *anyopaque) void {}
        fn observe(raw: *anyopaque, delta: provider.Delta) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (delta) {
                .text => |text| {
                    self.text_events += 1;
                    if (text.len == 0) self.empty_text_events += 1;
                },
                .tool_plan => self.tool_events += 1,
                .done => self.done_events += 1,
                else => {},
            }
        }
    };
    var fixture: Fixture = .{};
    fixture.usage_mailbox.reset(901);
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    manager.scope = .{ .owner = .{ .session = 101 }, .members = .{ .ids = .{101} ++ @as([15]u64, @splat(0)), .len = 1 } };
    manager.turn_id = 901;
    manager.tool_host = .{ .context = &fixture, .execute = Fixture.execute };
    manager.observer = .{ .context = &fixture, .reset = Fixture.reset, .delta = Fixture.observe, .context_usage = Fixture.usage };
    const usage = try manager.run(.{ .ctx = &fixture, .chat = Fixture.chat, .models = Fixture.models }, .{ .model = "two-round-fixture", .system = "", .messages = &.{.{ .content = "read capacity" }}, .tools = &.{.{ .tool = .run_command, .session_ids = &.{101} }} });
    try std.testing.expectEqual(@as(usize, 2), fixture.rounds);
    try std.testing.expectEqual(@as(u32, 2), usage.request_count);
    try std.testing.expectEqual(@as(u32, 3000), usage.input_tokens);
    try std.testing.expectEqual(@as(usize, 2000), manager.last_context_usage.?.input_tokens);
    const live = fixture.usage_mailbox.read(901).?;
    try std.testing.expectEqual(@as(?usize, 2000), live.summary.measured_tokens);
    try std.testing.expectEqual(2000 + @import("local_text_request.zig").draftTokens("DF_READONLY_DONE"), live.summary.tokens);

    try std.testing.expect(manager.last_context_usage.?.matches(manager.tool_run.?.messages.items));
    try std.testing.expectEqual(@as(usize, 1), fixture.executions);
    try std.testing.expectEqual(@as(usize, 1), fixture.tool_events);
    try std.testing.expectEqual(@as(usize, 2), fixture.done_events);
    try std.testing.expectEqual(@as(usize, 0), fixture.empty_text_events);
    try std.testing.expectEqual(@as(usize, 1), fixture.text_events);
    try std.testing.expectEqual(@as(usize, 1), manager.cards.count());
    try std.testing.expectEqualStrings("DF_READONLY_DONE", manager.cards.cards.items[0].text);
    try std.testing.expectEqual(turn_model.State.done, manager.turn.state);
}

test "turn manager forwards accepted host results only after the entire batch closes" {
    const tools = @import("plugin_tools.zig");
    const identity = @import("../host/identity.zig");
    const a = std.testing.allocator;
    const authority: tools.host.Context = .{ .conversation_id = identity.ConversationId.generate(), .task_id = identity.TaskId.generate(), .binding = .{ .group = 7 }, .binding_revision = 2, .grant_revision = 3 };
    const scope: tool_scope.Scope = .{ .owner = authority.binding, .members = .{} };
    var table = try tools.RequestTable.initWithHost(a, scope, &.{}, &.{}, authority, &.{.{ .definition = .{ .id = "host.get_current_context", .schema = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}" }, .authority = .conversation_context }});
    defer table.deinit();
    const wire = try tools.providerDefinitions(&table, table.arena.allocator());
    const Fixture = struct {
        manager: *Manager,
        name: []const u8,
        authority: tools.host.Context,
        rounds: usize = 0,
        executions: usize = 0,
        accepted: usize = 0,
        fn chat(raw: *anyopaque, _: provider.ChatRequest, sink: *const fn (*anyopaque, provider.Delta) void, ctx: *anyopaque) !provider.ChatStats {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.rounds += 1;
            switch (self.rounds) {
                1 => {
                    sink(ctx, .{ .tool_plan = .{ .index = 0, .call_id = "closed-a", .name = self.name, .arguments = "{}" } });
                    sink(ctx, .{ .tool_plan = .{ .index = 1, .call_id = "closed-b", .name = self.name, .arguments = "{}" } });
                },
                2 => {
                    try std.testing.expectEqual(@as(usize, 2), self.accepted);
                    sink(ctx, .{ .text = "closed batch observed before provider continues" });
                },
                else => return error.UnexpectedProviderRound,
            }
            sink(ctx, .done);
            return .{};
        }
        fn models(_: *anyopaque, allocator: std.mem.Allocator) ![]provider.ModelInfo {
            return allocator.alloc(provider.ModelInfo, 0);
        }
        fn legacy(_: *anyopaque, _: tool_loop.Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !tool_loop.Outcome {
            return error.UnexpectedLegacyDispatch;
        }
        fn execute(raw: *anyopaque, invocation: tools.host.Invocation, allocator: std.mem.Allocator, _: ?*provider.CancelToken) !tools.host.Result {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.executions += 1;
            const blocks = try allocator.alloc(tools.host.Block, 1);
            blocks[0] = .{ .structured = try allocator.dupe(u8, "{}") };
            return .{ .status = .succeeded, .blocks = blocks, .receipt = .{ .conversation_id = invocation.context.conversation_id, .task_id = invocation.context.task_id, .operation_id = invocation.operation_id, .binding_revision = invocation.context.binding_revision } };
        }
        fn acceptedResult(raw: *anyopaque, context: tools.host.Context, name: []const u8, result: *const tools.host.Result, _: ?*provider.CancelToken) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try std.testing.expect(context.eql(self.authority));
            try std.testing.expectEqualStrings(self.name, name);
            try std.testing.expectEqual(tools.Status.succeeded, result.status);
            try std.testing.expectEqual(@as(usize, 2), self.executions);
            const run = self.manager.tool_run.?;
            try std.testing.expectEqual(@as(usize, 2), run.records.items.len);
            try @import("provider_http.zig").validateToolMessages(run.request);
            try std.testing.expectEqual(provider.Role.tool, run.messages.items[run.messages.items.len - 1].role);
            self.accepted += 1;
        }
    };
    var manager = Manager.init(a);
    defer manager.deinit();
    var fixture: Fixture = .{ .manager = &manager, .name = wire[0].name(), .authority = authority };
    manager.scope = scope;
    manager.turn_id = 1;
    manager.tool_host = .{ .context = &fixture, .execute = Fixture.legacy, .execute_host = Fixture.execute, .accepted_host_result = Fixture.acceptedResult };
    _ = try manager.run(.{ .ctx = &fixture, .chat = Fixture.chat, .models = Fixture.models }, .{ .model = "closed-host-batch", .system = "", .messages = &.{}, .tools = wire, .tool_table = &table });
    try std.testing.expectEqual(@as(usize, 2), fixture.accepted);
    try std.testing.expectEqual(turn_model.State.done, manager.turn.state);
}

test "provider error remains owned after its serialized response buffer is reused" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    var message = "actual provider failure detail".*;
    Manager.receive(&manager, .{ .err = &message });
    @memset(&message, 'x');
    try std.testing.expectEqualStrings("actual provider failure detail", manager.last_error.?);
    // A subsequent provider error replaces the owned value in bounded space.
    Manager.receive(&manager, .{ .err = "second error" });
    try std.testing.expectEqualStrings("second error", manager.last_error.?);
}

test "approval human wait pauses the automatic run budget across provider rounds" {
    var timing: TestRetryTiming = .{};
    var fixture: TestMultiRun = .{ .timing = &timing, .tool_work_ms = 10, .user_wait_ms = 12 * 60 * 60 * 1000, .steps = &.{ .{ .work_ms = 20, .calls = &.{"approval"} }, .{ .work_ms = 30 } } };
    var manager = fixture.makeManager();
    defer manager.deinit();
    _ = try manager.runWithTiming(fixture.interface(), TestMultiRun.makeRequest(null, 100), &timing);
    try std.testing.expectEqualSlices(u32, &.{ 100, 70 }, fixture.budgets[0..2]);
    try std.testing.expectEqual(@as(usize, 1), fixture.host_calls);
}

test "approval budget nesting preserves remaining time and explicit Stop during human wait" {
    var timing: TestRetryTiming = .{};
    var stop: provider.CancelToken = .{};
    var budget: RequestBudget(*TestRetryTiming) = .{ .timing = &timing, .deadline_ns = 100 * std.time.ns_per_ms, .stop = &stop };
    var token = budget.childToken();
    timing.ns = 20 * std.time.ns_per_ms;
    const outer = provider.CancelToken.beginUserWait(&token);
    timing.ns += std.time.ns_per_hour;
    const inner = provider.CancelToken.beginUserWait(&token);
    timing.ns += std.time.ns_per_hour;
    inner.end();
    try std.testing.expect(!token.isCancelled());
    outer.end();
    timing.ns += 79 * std.time.ns_per_ms;
    try std.testing.expect(!token.isCancelled());
    timing.ns += std.time.ns_per_ms;
    try std.testing.expect(token.isCancelled());
    const late = provider.CancelToken.beginUserWait(&token);
    try std.testing.expectEqual(error.Timeout, budget.reason().?);
    late.end();
    const again = provider.CancelToken.beginUserWait(&token);
    defer again.end();
    try std.testing.expectEqual(error.Timeout, budget.reason().?);
    stop.cancel();
    try std.testing.expectEqual(error.Cancelled, budget.reason().?);
}

test "approval explicit Stop interrupts a valid paused budget" {
    var timing: TestRetryTiming = .{};
    var stop: provider.CancelToken = .{};
    var budget: RequestBudget(*TestRetryTiming) = .{ .timing = &timing, .deadline_ns = 100 * std.time.ns_per_ms, .stop = &stop };
    var token = budget.childToken();
    const waiting = provider.CancelToken.beginUserWait(&token);
    defer waiting.end();
    timing.ns += 30 * std.time.ns_per_day;
    try std.testing.expect(!token.isCancelled());
    stop.cancel();
    try std.testing.expectEqual(error.Cancelled, budget.reason().?);
    try std.testing.expect(token.isCancelled());
}

test "v0.4.3 a no-tool response refreshes workspace without sending paused steering" {
    const input = @import("session_input.zig");
    const identity = @import("../host/identity.zig");
    const dynamic = @import("plugin_tools.zig");
    const a = std.testing.allocator;
    const fence: input.Fence = .{ .agent = identity.AgentId.generate(), .conversation = identity.ConversationId.generate(), .binding = 1, .environment = 1 };
    var inbox = input.Inbox.init(a, fence);
    defer inbox.deinit();
    const first = try inbox.admit(fence, identity.SubmissionId.generate(), .{ .content = "initial task" }, .queue);
    _ = try inbox.claim(first.id, first.revision, null, 31, .start);
    const current: tool_scope.Scope = .{ .owner = .{ .group = 8 }, .members = .{} };
    const context: dynamic.host.Context = .{ .conversation_id = fence.conversation, .task_id = identity.TaskId.generate(), .binding = current.owner, .binding_revision = 1, .grant_revision = 1 };
    var table = try dynamic.RequestTable.initWithHost(a, current, &.{}, &.{}, context, &.{});
    defer table.deinit();
    const Fixture = struct {
        inbox: *input.Inbox,
        steer: ?identity.SubmissionId = null,
        rounds: u32 = 0,
        notices_acked: u32 = 0,
        refreshed: bool = false,

        fn chat(raw: *anyopaque, req: provider.ChatRequest, sink: *const fn (*anyopaque, provider.Delta) void, receiver: *anyopaque) !provider.ChatStats {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.rounds += 1;
            switch (self.rounds) {
                1 => {
                    try std.testing.expectEqual(@as(?u64, 1), req.workspace_revision);
                    try std.testing.expectEqualStrings("workspace A", req.system);
                    try std.testing.expectEqualStrings("initial task", req.messages[0].content);
                    const receipt = try self.inbox.admit(self.inbox.fence, identity.SubmissionId.generate(), .{ .content = "stale steer" }, .steer);
                    try std.testing.expectEqual(input.Delivery.accepted, receipt.delivery);
                    self.steer = receipt.id;
                    try self.inbox.beginWorkspaceChange();
                    self.inbox.setWorkspaceRevision(2);
                    self.inbox.endWorkspaceChange();
                },
                2 => {
                    try std.testing.expectEqual(@as(?u64, 2), req.workspace_revision);
                    try std.testing.expectEqualStrings("workspace B", req.system);
                    try std.testing.expectEqual(@as(u32, 0), self.notices_acked);
                    try std.testing.expectEqual(@as(usize, 2), req.messages.len);
                    try std.testing.expect(req.messages[1].origin == .host_context_notice);
                    try std.testing.expectEqualStrings("B replaced A", req.messages[1].content);
                },
                else => return error.UnexpectedProviderRequest,
            }
            sink(receiver, .done);
            return .{ .request_count = 1 };
        }
        fn refresh(raw: *anyopaque, previous: *const dynamic.RequestTable, allocator: std.mem.Allocator, _: ?*provider.CancelToken) !?tool_loop.AuthorityRefresh {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.refreshed or self.inbox.workspaceRevision() == 1) return null;
            var next = try dynamic.cloneTable(previous, allocator);
            errdefer next.deinit();
            const system = try allocator.dupe(u8, "workspace B");
            errdefer allocator.free(system);
            const notice = try allocator.dupe(u8, "B replaced A");
            self.refreshed = true;
            return .{ .table = next, .system = system, .notice = notice, .notice_revision = 3, .workspace_revision = 2 };
        }
        fn ack(raw: *anyopaque, revision: u64, _: ?*provider.CancelToken) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try std.testing.expectEqual(@as(u64, 3), revision);
            try std.testing.expectEqual(@as(u32, 2), self.rounds);
            self.notices_acked += 1;
        }
        fn execute(_: *anyopaque, _: tool_loop.Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !tool_loop.Outcome {
            return error.UnexpectedTool;
        }
    };
    var fixture: Fixture = .{ .inbox = &inbox };
    var manager = Manager.init(a);
    defer manager.deinit();
    manager.input = &inbox;
    manager.scope = current;
    manager.turn_id = 31;
    manager.tool_host = .{ .context = &fixture, .execute = Fixture.execute, .refresh_authority = Fixture.refresh, .acknowledge_notice = Fixture.ack };
    _ = try manager.run(.{ .ctx = &fixture, .chat = Fixture.chat, .models = TestRetryProvider.models }, .{
        .model = "fixture",
        .system = "workspace A",
        .messages = &.{},
        .tool_table = &table,
        .workspace_revision = 1,
    });
    try std.testing.expectEqual(@as(u32, 2), fixture.rounds);
    try std.testing.expectEqual(@as(u32, 1), fixture.notices_acked);
    try std.testing.expectEqual(input.Pause.workspace_changed, inbox.receipt(fixture.steer.?).?.pause.?);
    try std.testing.expectEqual(input.Delivery.consumed, inbox.receipt(first.id).?.delivery);
}

test "v0.4.3 workspace refresh compacts completed history before publishing and acknowledging the notice" {
    const input = @import("session_input.zig");
    const identity = @import("../host/identity.zig");
    const dynamic = @import("plugin_tools.zig");
    const budget = @import("local_text_request.zig");
    const a = std.testing.allocator;
    const current: tool_scope.Scope = .{ .owner = .{ .group = 8 }, .members = .{} };
    const Scenario = enum { completed, summary_failure, new_steer };
    const Fixture = struct {
        const old = "old workspace";
        const next = "new workspace " ++ @as([3_000]u8, @splat('s'));
        const notice = "B replaced A " ++ @as([3_000]u8, @splat('n'));
        const result = "large observation " ++ @as([8_000]u8, @splat('r'));
        const steer = "new steering input " ++ @as([16_000]u8, @splat('u'));

        inbox: *input.Inbox,
        tool_name: []const u8,
        scenario: Scenario,
        rounds: u32 = 0,
        summaries: u32 = 0,
        published_revision: u64 = 1,
        acknowledgements: u32 = 0,
        disposed: u32 = 0,

        fn chat(raw: *anyopaque, req: provider.ChatRequest, sink: *const fn (*anyopaque, provider.Delta) void, receiver: *anyopaque) !provider.ChatStats {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (req.workspace_revision == null) {
                self.summaries += 1;
                try std.testing.expectEqual(@as(u64, if (self.summaries == 1) 1 else 2), self.published_revision);
                try std.testing.expectEqual(@as(u32, 0), self.acknowledgements);
                try std.testing.expect(std.mem.indexOf(u8, req.system, next) == null);
                for (req.messages) |message| try std.testing.expect(std.mem.indexOf(u8, message.content, notice) == null);
                if (self.scenario == .summary_failure) return error.SummaryUnavailable;
                sink(receiver, .{ .text = "Earlier workspace investigation." });
            } else {
                self.rounds += 1;
                switch (self.rounds) {
                    1 => {
                        try std.testing.expectEqual(@as(?u64, 1), req.workspace_revision);
                        try std.testing.expectEqualStrings(old, req.system);
                        sink(receiver, .{ .tool_plan = .{ .call_id = "large-observation", .name = self.tool_name, .arguments = "{}" } });
                    },
                    2 => {
                        try std.testing.expectEqual(@as(?u64, 2), req.workspace_revision);
                        try std.testing.expectEqual(@as(u64, 2), self.published_revision);
                        try std.testing.expectEqual(@as(u32, 0), self.acknowledgements);
                        try std.testing.expectEqualStrings(next, req.system);
                        try std.testing.expect(std.mem.indexOf(u8, req.messages[0].content, "Earlier workspace investigation.") != null);
                        const notice_index = req.messages.len - @as(usize, if (self.scenario == .new_steer) 2 else 1);
                        if (self.scenario == .new_steer) {
                            try std.testing.expectEqualStrings(steer, req.messages[notice_index + 1].content);
                        } else {
                            const observation = req.messages[notice_index - 1];
                            try std.testing.expectEqualStrings("large-observation", observation.tool_call_id.?);
                            try std.testing.expect(std.mem.indexOf(u8, observation.content, result) != null);
                        }
                        const latest = req.messages[notice_index];
                        try std.testing.expectEqual(.host_context_notice, latest.origin);
                        try std.testing.expectEqualStrings(notice, latest.content);
                        try @import("provider_http.zig").validateToolMessages(req);
                        try budget.checkContext(req, 8192);
                        sink(receiver, .{ .text = "Completed in workspace B." });
                    },
                    else => return error.UnexpectedProviderRequest,
                }
            }
            sink(receiver, .done);
            return .{ .request_count = 1 };
        }
        fn refresh(raw: *anyopaque, previous: *const dynamic.RequestTable, allocator: std.mem.Allocator, _: ?*provider.CancelToken) !?tool_loop.AuthorityRefresh {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.inbox.workspaceRevision() == 1 or self.published_revision == 2) return null;
            var table = try dynamic.cloneTable(previous, allocator);
            errdefer table.deinit();
            const system = try allocator.dupe(u8, next);
            errdefer allocator.free(system);
            return .{
                .table = table,
                .notice = try allocator.dupe(u8, notice),
                .notice_revision = 3,
                .system = system,
                .workspace_revision = 2,
                .publication = .{ .context = raw, .publish = publish, .destroy = destroy },
            };
        }
        fn publish(raw: *anyopaque, _: ?*provider.CancelToken) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try std.testing.expectEqual(@as(u32, 1), self.summaries);
            try std.testing.expectEqual(@as(u64, 1), self.published_revision);
            if (self.scenario == .new_steer) {
                const receipt = try self.inbox.admit(self.inbox.fence, identity.SubmissionId.generate(), .{ .content = steer }, .steer);
                try std.testing.expectEqual(input.Delivery.accepted, receipt.delivery);
            }
            self.published_revision = 2;
        }
        fn destroy(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.disposed += 1;
        }
        fn ack(raw: *anyopaque, revision: u64, _: ?*provider.CancelToken) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try std.testing.expectEqual(@as(u64, 3), revision);
            try std.testing.expectEqual(@as(u32, 2), self.rounds);
            self.acknowledgements += 1;
        }
        fn execute(_: *anyopaque, _: tool_loop.Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !tool_loop.Outcome {
            return error.UnexpectedLegacyTool;
        }
        fn invoke(raw: *anyopaque, invocation: dynamic.host.Invocation, allocator: std.mem.Allocator, _: ?*provider.CancelToken) !dynamic.host.Result {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try std.testing.expectEqual(@as(?u64, 1), invocation.workspace_revision);
            try self.inbox.beginWorkspaceChange();
            self.inbox.setWorkspaceRevision(2);
            self.inbox.endWorkspaceChange();
            const blocks = try allocator.alloc(dynamic.host.Block, 1);
            errdefer allocator.free(blocks);
            blocks[0] = .{ .text = try allocator.dupe(u8, result) };
            return .{ .status = .succeeded, .blocks = blocks, .receipt = .{
                .conversation_id = invocation.context.conversation_id,
                .task_id = invocation.context.task_id,
                .operation_id = invocation.operation_id,
                .binding_revision = invocation.context.binding_revision,
            } };
        }
    };
    for ([_]Scenario{ .completed, .summary_failure, .new_steer }) |scenario| {
        const fence: input.Fence = .{ .agent = identity.AgentId.generate(), .conversation = identity.ConversationId.generate(), .binding = 1, .environment = 1 };
        var inbox = input.Inbox.init(a, fence);
        defer inbox.deinit();
        const first = try inbox.admit(fence, identity.SubmissionId.generate(), .{ .content = "current task" }, .queue);
        _ = try inbox.claim(first.id, first.revision, null, 31, .start);
        const context: dynamic.host.Context = .{ .conversation_id = fence.conversation, .task_id = identity.TaskId.generate(), .binding = current.owner, .binding_revision = 1, .grant_revision = 1 };
        var table = try dynamic.RequestTable.initWithHost(a, current, &.{}, &.{}, context, &.{.{ .authority = .conversation_context, .definition = .{ .id = "host.get_current_context", .schema = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}" } }});
        defer table.deinit();
        const definitions = try dynamic.providerDefinitions(&table, table.arena.allocator());
        var fixture: Fixture = .{ .inbox = &inbox, .tool_name = definitions[0].name(), .scenario = scenario };
        var manager = Manager.init(a);
        defer manager.deinit();
        manager.input = &inbox;
        manager.scope = current;
        manager.turn_id = 31;
        manager.compaction_config = .{ .kind = .openai_compat, .endpoint = "http://127.0.0.1:1", .model = "fixture", .auth = .none, .context_window = 8192 };
        manager.tool_host = .{ .context = &fixture, .execute = Fixture.execute, .execute_host = Fixture.invoke, .refresh_authority = Fixture.refresh, .acknowledge_notice = Fixture.ack };
        const result = manager.run(.{ .ctx = &fixture, .chat = Fixture.chat, .models = TestRetryProvider.models }, .{
            .model = "fixture",
            .system = Fixture.old,
            .messages = &.{
                .{ .content = "old user turn " ++ @as([18_000]u8, @splat('h')) },
                .{ .role = .assistant, .content = "old assistant response" },
                .{ .content = "recent user turn" },
                .{ .role = .assistant, .content = "recent assistant response" },
            },
            .tools = definitions,
            .tool_table = &table,
            .workspace_revision = 1,
            .max_output = 1024,
        });
        const run = manager.tool_run.?;
        try std.testing.expectEqual(@as(u32, if (scenario == .new_steer) 2 else 1), fixture.summaries);
        try std.testing.expectEqual(@as(u32, 1), fixture.disposed);
        if (scenario == .summary_failure) {
            try std.testing.expectError(error.ContextCompactionFailed, result);
            try std.testing.expectEqual(error.SummaryUnavailable, run.compaction_failure.?);
            try std.testing.expectEqual(@as(u32, 1), fixture.rounds);
            try std.testing.expectEqual(@as(u32, 0), fixture.acknowledgements);
            try std.testing.expectEqual(@as(u64, 1), fixture.published_revision);
            try std.testing.expectEqual(@as(?u64, 1), run.request.workspace_revision);
            try std.testing.expectEqual(@as(u64, 0), run.notice_revision);
            try std.testing.expectEqualStrings(Fixture.old, run.request.system);
            try std.testing.expectEqualStrings("large-observation", run.messages.items[run.messages.items.len - 1].tool_call_id.?);
        } else {
            _ = try result;
            try std.testing.expectEqual(@as(u32, 2), fixture.rounds);
            try std.testing.expectEqual(@as(u32, 1), fixture.acknowledgements);
            try std.testing.expectEqual(@as(u64, 3), run.wire_notice_revision);
        }
    }
}
