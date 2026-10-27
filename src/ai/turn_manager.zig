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
}

/// 将 Provider 的增量事件汇聚为可消费的 CardStream，并维护一次 Turn 的生命周期。
pub const Manager = struct {
    pub const Observer = struct {
        context: *anyopaque,
        reset: *const fn (*anyopaque) void,
        delta: *const fn (*anyopaque, provider.Delta) anyerror!void,
    };
    allocator: std.mem.Allocator,
    observer: ?Observer = null,
    turn: turn_model.Turn,
    cards: card_stream.Stream,
    audit_log: audit.Log,
    permission_engine: permission.Engine = .{},
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
        if (self.tool_run) |previous| {
            if (self.scope) |current| {
                if (previous.turn_id == self.turn_id and tool_scope.Owner.eql(previous.scope.owner, current.owner)) {
                    for (previous.records.items) |record| if (record.dispatched) return error.ToolTurnAlreadyDispatched;
                }
            }
        }
        if (self.observer) |observer| observer.reset(observer.context);
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

        errdefer self.turn.abort();
        if (self.tool_host != null or (self.scope != null and request.tools.len == 0)) {
            const scope = self.scope orelse return error.ToolScopeUnavailable;
            const loop = try self.allocator.create(tool_loop.Loop);
            loop.* = tool_loop.Loop.init(self.allocator, scope, self.turn_id, self.tool_limits);
            loop.start(request) catch |err| {
                loop.deinit();
                self.allocator.destroy(loop);
                return err;
            };
            self.tool_run = loop;
        } else if (request.tools.len != 0) return error.ToolHostUnavailable;

        const frozen_policy = self.permission_engine;
        const frozen_policy_revision = self.policy_revision;
        var total: provider.ChatStats = .{};
        while (true) {
            const current = if (self.tool_run) |loop| try loop.nextRequest() else request;
            self.turn.state = .streaming;
            const stats = try self.runRound(p, current);
            total.input_tokens +|= stats.input_tokens;
            total.output_tokens +|= stats.output_tokens;
            total.usage_reported = total.usage_reported and stats.usage_reported;
            if (self.pending_tools.items.len == 0 or self.tool_run == null) {
                try self.turn.done();
                try self.audit_log.append(.{ .timestamp_ms = self.timestamp_ms, .turn_id = self.turn_id, .command = self.command, .verdict = "stream_done", .target = request.model });
                return total;
            }
            try self.completeTools(current.cancel, frozen_policy, frozen_policy_revision);
            if (current.cancel) |token| if (token.isCancelled()) return error.Cancelled;
            if (self.tool_run.?.uncertain) return error.ToolOutcomeUnknown;
        }
    }

    /// An explicit answer-only retry preserves the original turn, transcript
    /// and completed-call ledger. It exposes no tools and cannot dispatch new
    /// effects, even if a misbehaving provider returns a tool call anyway.
    pub fn resumeAnswer(self: *Manager, p: provider.Provider, cancel: ?*provider.CancelToken) !provider.ChatStats {
        if (self.cooldownRemainingMs() != 0) return error.ProviderCoolingDown;
        const loop = self.tool_run orelse return error.NoToolTurnToResume;
        if (loop.uncertain) return error.ToolOutcomeUnknown;
        if (self.turn_id != loop.turn_id or self.scope == null or !tool_scope.Owner.eql(self.scope.?.owner, loop.scope.owner)) return error.ToolOwnerChanged;
        if (self.turn.state != .idle) return error.InvalidTransition;
        try self.turn.begin();
        try self.turn.stream();
        errdefer self.turn.abort();
        if (self.observer) |observer| observer.reset(observer.context);
        var resumed = loop.request;
        resumed.messages = loop.messages.items;
        resumed.tools = &.{};
        resumed.cancel = cancel;
        // Do not mutate the original request/token snapshot to retry it.
        try loop.checkRequestBudget();
        const stats = try self.runRound(p, resumed);
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
    fn runRound(self: *Manager, p: provider.Provider, request: provider.ChatRequest) !provider.ChatStats {
        self.clearPending();
        self.round_text.clearRetainingCapacity();
        self.saw_done = false;
        self.last_error = null;
        self.open_text_card = null;
        const cards_start = self.cards.count();
        const reasoning_start = self.reasoning.items.len;

        var attempt: u8 = 0;
        self.retry_attempt = 0;
        const started_ms = monotonicMs();
        while (true) {
            if (request.cancel) |token| if (token.isCancelled()) {
                self.turn.abort();
                try self.recordFailure(request.model);
                return error.Cancelled;
            };
            const audit_start = self.audit_log.len();
            var retry_after_ms: ?u32 = null;
            var attempt_request = request;
            const elapsed_ms = monotonicMs() -| started_ms;
            attempt_request.timeout_ms = request.timeout_ms -| @as(u32, @intCast(@min(elapsed_ms, std.math.maxInt(u32))));
            if (attempt_request.timeout_ms == 0) {
                self.turn.abort();
                try self.recordFailure(request.model);
                return error.Timeout;
            }
            attempt_request.retry_after_ms = &retry_after_ms;
            self.retry_attempt = attempt;
            const result = p.chat(p.ctx, attempt_request, receive, self);
            if (retry_after_ms) |delay| self.cooldown_deadline_ms = monotonicMs() +| delay;
            if (result) |stats| {
                if (request.cancel) |token| if (token.isCancelled()) {
                    self.audit_log.truncate(audit_start);
                    self.turn.abort();
                    try self.recordFailure(request.model);
                    return error.Cancelled;
                };
                if (self.last_error != null or !self.saw_done) {
                    self.audit_log.truncate(audit_start);
                    self.turn.abort();
                    try self.recordFailure(request.model);
                    return if (self.last_error != null) error.StreamCallbackFailed else error.ProviderMissingDone;
                }
                return stats;
            } else |err| {
                self.audit_log.truncate(audit_start);
                if (!retry.isRetryable(err)) {
                    self.turn.abort();
                    try self.recordFailure(request.model);
                    return err;
                }
                if (self.retry_policy.delay(attempt)) |delay_ms| {
                    const actual_delay = @max(delay_ms, retry_after_ms orelse 0);
                    // Do not retry ahead of Retry-After or wait indefinitely
                    // when the server asks for a delay beyond this turn's budget.
                    const spent_ms = monotonicMs() -| started_ms;
                    if (actual_delay >= request.timeout_ms -| @as(u32, @intCast(@min(spent_ms, std.math.maxInt(u32))))) {
                        self.turn.abort();
                        try self.recordFailure(request.model);
                        return error.Timeout;
                    }
                    retry.wait(actual_delay, request.cancel) catch |wait_err| {
                        self.turn.abort();
                        try self.recordFailure(request.model);
                        return wait_err;
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
                if (self.round_text.items.len + value.len > self.tool_limits.max_transcript_bytes) {
                    self.last_error = "provider response too large";
                    return;
                }
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
        self.turn.state = if (invocation.verdict == .need_confirm) .await_confirm else .executing;
        const host = self.tool_host.?;
        return host.execute(host.context, invocation, allocator, cancel);
    }

    fn executeDynamic(raw: *anyopaque, invocation: @import("plugin_tools.zig").DynamicInvocation, allocator: std.mem.Allocator, cancel: ?*provider.CancelToken) ![]@import("plugin_tools.zig").ToolResult {
        const self: *Manager = @ptrCast(@alignCast(raw));
        self.turn.state = if (try @import("plugin_tools.zig").callNeedsApproval(invocation.parsed, .{ .engine = self.permission_engine, .full_control = self.permission_engine.mode == .auto }, invocation.table.captured_scope.owner == .group)) .await_confirm else .executing;
        const host = self.tool_host.?;
        const execute_dynamic = host.execute_dynamic orelse return error.DynamicToolHostUnavailable;
        return execute_dynamic(host.context, invocation, allocator, cancel);
    }

    fn completeTools(self: *Manager, cancel: ?*provider.CancelToken, policy: permission.Engine, policy_revision: u64) !void {
        defer self.clearPending();
        var calls: [provider.max_tool_calls]provider.ToolCall = undefined;
        var count: usize = 0;
        // Provider tool indices, rather than fragment arrival order, define
        // assistant transcript and result ordering.
        for (0..provider.max_tool_calls) |index| {
            for (self.pending_tools.items) |tool| {
                if (tool.index != index) continue;
                calls[count] = .{ .id = tool.call_id orelse return error.MissingToolCallId, .name = tool.name orelse return error.MissingToolName, .arguments = tool.arguments.items };
                count += 1;
            }
        }
        const loop = self.tool_run.?;
        const records_start = loop.records.items.len;
        try loop.complete(self.round_text.items, calls[0..count], .{ .context = self, .execute = execute, .execute_dynamic = executeDynamic }, policy, policy_revision, cancel);
        self.open_text_card = null;
        for (loop.records.items[records_start..]) |record| {
            try self.audit_log.append(.{ .timestamp_ms = self.timestamp_ms, .turn_id = self.turn_id, .command = record.arguments, .verdict = if (record.dispatched) "tool_result" else "tool_rejected", .target = record.name, .call_id = record.key.call_id });
            // Structured facts live in the owned ledger/transcript. Do not
            // render protocol JSON as an assistant answer or map unknown to
            // the legacy Card.Phase.failed/aborted projection.
        }
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
            .verdict = permission.classify(self.permission_engine, value, false),
            .call_id = call_id,
        } });
    }

    fn queueTool(self: *Manager, index: u32, call_id: ?[]const u8, name: ?[]const u8, arguments: []const u8) !void {
        if (index >= 16) return error.TooManyTools;
        if (call_id) |id| if (id.len == 0 or id.len > provider.max_tool_call_id_bytes or std.mem.indexOfScalar(u8, id, 0) != null) return error.InvalidToolCall;
        if (name) |value| if (value.len == 0 or value.len > provider.max_tool_name_bytes) return error.InvalidToolCall;
        var found: ?usize = null;
        for (self.pending_tools.items, 0..) |tool, i| if (tool.index == index) {
            found = i;
            break;
        };
        if (found == null) {
            if (self.pending_tools.items.len == 16) return error.TooManyTools;
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
        if (arguments.len + tool.arguments.items.len > 64 * 1024) return error.ToolArgumentsTooLarge;
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
                    .verdict = if (call.tool == .run_command) permission.classify(self.permission_engine, command, scope.owner == .group) else .allow_auto,
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

test "empty text in a tool round produces no observer text or blank answer card before final response" {
    const Fixture = struct {
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
            return .{};
        }
        fn models(_: *anyopaque, allocator: std.mem.Allocator) ![]provider.ModelInfo {
            return allocator.alloc(provider.ModelInfo, 0);
        }
        fn execute(raw: *anyopaque, invocation: tool_loop.Invocation, allocator: std.mem.Allocator, _: ?*provider.CancelToken) !tool_loop.Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try std.testing.expectEqualStrings("df -h", invocation.call.command);
            self.executions += 1;
            return tool_loop.Outcome.copy(allocator, &.{.{ .session_id = 101, .status = .succeeded, .transport = .local, .stdout = "Filesystem Size Used Avail Capacity Mounted on", .exit = 0, .local_released = true }});
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
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    manager.scope = .{ .owner = .{ .session = 101 }, .members = .{ .ids = .{101} ++ @as([15]u64, @splat(0)), .len = 1 } };
    manager.turn_id = 901;
    manager.tool_host = .{ .context = &fixture, .execute = Fixture.execute };
    manager.observer = .{ .context = &fixture, .reset = Fixture.reset, .delta = Fixture.observe };
    _ = try manager.run(.{ .ctx = &fixture, .chat = Fixture.chat, .models = Fixture.models }, .{ .model = "two-round-fixture", .system = "", .messages = &.{.{ .content = "read capacity" }}, .tools = &.{.{ .tool = .run_command, .session_ids = &.{101} }} });
    try std.testing.expectEqual(@as(usize, 2), fixture.rounds);
    try std.testing.expectEqual(@as(usize, 1), fixture.executions);
    try std.testing.expectEqual(@as(usize, 1), fixture.tool_events);
    try std.testing.expectEqual(@as(usize, 2), fixture.done_events);
    try std.testing.expectEqual(@as(usize, 0), fixture.empty_text_events);
    try std.testing.expectEqual(@as(usize, 1), fixture.text_events);
    try std.testing.expectEqual(@as(usize, 1), manager.cards.count());
    try std.testing.expectEqualStrings("DF_READONLY_DONE", manager.cards.cards.items[0].text);
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
