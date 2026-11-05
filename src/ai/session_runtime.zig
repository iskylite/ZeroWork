//! Non-UI application service. Controller calls are serialized; each agent's
//! stable runner owns its Manager, IO, provider handle, cancellation and stream.
const std = @import("std");
const identity = @import("../host/identity.zig");
const lifecycle = @import("session_lifecycle.zig");
pub const input = @import("session_input.zig");
const provider = @import("provider.zig");
const wire = @import("wire_history.zig");
const scope = @import("tool_scope.zig");
const Manager = @import("turn_manager.zig").Manager;
const tools = @import("tool_loop.zig");
const stream = @import("stream_mailbox.zig");

pub const Context = struct {
    fence: input.Fence,
    task: identity.TaskId,
    turn: u64,
    owner: scope.Owner,
    submission: identity.SubmissionId = .{},
    approvals: ?*@import("host_approval.zig").Broker = null,
    questions: ?*@import("user_interaction.zig").Broker = null,
    pub fn authority(self: Context) @import("host_tools.zig").Context {
        return .{ .conversation_id = self.fence.conversation, .task_id = self.task, .binding = self.owner, .binding_revision = self.fence.binding, .grant_revision = self.fence.environment };
    }
};
pub const Prepared = struct {
    provider: provider.Provider,
    request: provider.ChatRequest,
    scope: scope.Scope,
    host: ?tools.Host = null,
    policy: @import("permission.zig").Engine = .{},
    limits: tools.Limits = .{},
    observer: ?Manager.Observer = null,
    policy_revision: u64 = 1,
    compaction: ?@import("provider_config.zig").ProviderConfig = null,
    /// Worker-owned allocations/bridges are disposed only after the IO call
    /// and all tool consumers have returned. No UI Scope or Node may be held.
    context: ?*anyopaque = null,
    destroy: ?*const fn (*anyopaque) void = null,
    fn deinit(self: *Prepared) void {
        if (self.destroy) |release| release(self.context.?);
    }
};
pub const Backend = struct {
    context: *anyopaque,
    prepare: *const fn (*anyopaque, std.mem.Allocator, std.Io, Context) anyerror!Prepared,
    capture: ?*const fn (*anyopaque, Context) anyerror!void = null,
    completed: ?*const fn (*anyopaque, *Runner) anyerror!void = null,
    stop: ?*const fn (*anyopaque, Context) void = null,
    /// Nonblocking controller query. Required for a tool backend: worker
    /// completion alone never proves a PTY/input lease has been released.
    local_released: ?*const fn (*anyopaque, Context) bool = null,
    /// Wake only this agent's approval/question wait, without approving it or
    /// cancelling an already dispatched operation. The bridge returns a real
    /// superseded/unsent receipt and rechecks the dispatch fence after waiting.
    supersede: ?*const fn (*anyopaque, Context) void = null,
};
pub const Native = struct {
    arena: std.heap.ArenaAllocator,
    config: @import("provider_config.zig").ProviderConfig,
    pub fn init(a: std.mem.Allocator, config: @import("provider_config.zig").ProviderConfig) !Native {
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const owned = arena.allocator();
        var frozen = config;
        frozen.endpoint = try owned.dupe(u8, config.endpoint);
        frozen.model = try owned.dupe(u8, config.model);
        frozen.auth = switch (config.auth) {
            .none => .none,
            .bearer_memory => |value| .{ .bearer_memory = try owned.dupe(u8, value) },
            .anthropic_memory => |value| .{ .anthropic_memory = try owned.dupe(u8, value) },
        };
        return .{ .arena = arena, .config = frozen };
    }
    pub fn deinit(self: *Native) void {
        if (self.config.auth.value()) |secret| std.crypto.secureZero(u8, @constCast(secret));
        self.arena.deinit();
    }
    /// Native and its owned frozen config outlive the joined runtime.
    pub fn backend(self: *Native) Backend {
        return .{ .context = self, .prepare = prepare };
    }
    fn prepare(raw: *anyopaque, a: std.mem.Allocator, io: std.Io, context: Context) !Prepared {
        const self: *Native = @ptrCast(@alignCast(raw));
        try self.config.validate();
        const Owned = struct {
            allocator: std.mem.Allocator,
            native: @import("provider_transport.zig").NativeContext,
            client: @import("provider_client.zig").Client,
            binding: @import("provider_client.zig").Client.Binding,
            fn release(ptr: *anyopaque) void {
                const value: *@This() = @ptrCast(@alignCast(ptr));
                value.allocator.destroy(value);
            }
        };
        const owned = try a.create(Owned);
        errdefer a.destroy(owned);
        owned.allocator = a;
        owned.native = .{ .io = io };
        owned.client = @import("provider_client.zig").Client.native(a, &owned.native, switch (self.config.kind) {
            .anthropic => .anthropic,
            .ollama => .ollama,
            .openai_compat => .openai_compat,
        });
        owned.binding = .{ .client = &owned.client, .config = self.config };
        return .{ .provider = owned.binding.asProvider(), .request = self.config.chatRequest(.{ .model = self.config.model, .system = "", .messages = &.{} }), .scope = .{ .owner = context.owner, .members = .{} }, .limits = .{ .context_window = self.config.context_window }, .context = owned, .destroy = Owned.release };
    }
};
pub const Runner = struct {
    allocator: std.mem.Allocator,
    agent: *lifecycle.Agent,
    backend: Backend,
    manager: Manager,
    output: stream.Mailbox,
    cancel: provider.CancelToken = .{},
    thread: ?std.Thread = null,
    state: std.atomic.Value(enum(u8) { idle, running, done, failed, stopped }) = .init(.idle),
    context: ?Context = null,
    commit_fence: ?input.Fence = null,
    historical_messages: usize = 0,
    record: ?*lifecycle.Record = null,
    base: wire.History = .{},
    result: wire.History = .{},
    failure: ?anyerror = null,
    persistence_failure: ?anyerror = null,
    stats: provider.ChatStats = .{},
    has_tools: bool = false,
    pending_commit: bool = false,
    pending_notify: bool = false,
    controller_busy: bool = false,
    saved: bool = true,
    capture_failed: bool = false,
    capture_final: bool = false,
    answer_only: bool = false,
    approvals: @import("host_approval.zig").Broker = .{},
    questions: @import("user_interaction.zig").Broker = .{},

    fn resetOutput(raw: *anyopaque) void {
        const self: *Runner = @ptrCast(@alignCast(raw));
        self.output.reset();
    }
    fn delta(raw: *anyopaque, value: provider.Delta) !void {
        const self: *Runner = @ptrCast(@alignCast(raw));
        switch (value) {
            .text => |bytes| try self.output.append(bytes),
            .thinking => |bytes| try self.output.appendThinking(bytes),
            else => {},
        }
    }
    fn run(self: *Runner) void {
        var io: std.Io.Threaded = .init(self.allocator, .{});
        defer io.deinit();
        const completed = self.execute(io.io());
        if (completed) |value| {
            self.stats = value;
        } else |err| {
            self.failure = err;
        }
        self.state.store(if (self.cancel.isCancelled()) .stopped else if (self.failure != null) .failed else .done, .release);
    }
    fn execute(self: *Runner, io: std.Io) !provider.ChatStats {
        var prepared = try self.backend.prepare(self.backend.context, self.allocator, io, self.context.?);
        defer prepared.deinit();
        if (!prepared.scope.owner.eql(self.context.?.owner)) return error.BindingChanged;
        self.has_tools = prepared.host != null;
        if (self.has_tools and self.backend.local_released == null) return error.HostCleanupContractRequired;
        if (prepared.request.tool_table) |table| if (table.host_context) |captured| {
            if (!captured.conversation_id.eql(self.context.?.fence.conversation) or !captured.task_id.eql(self.context.?.task) or captured.binding_revision != self.context.?.fence.binding) return error.InvalidHostAuthority;
        };
        self.manager.scope = prepared.scope;
        self.manager.tool_host = prepared.host;
        self.manager.permission_engine = prepared.policy;
        self.manager.tool_limits = prepared.limits;
        self.manager.policy_revision = prepared.policy_revision;
        self.manager.compaction_config = prepared.compaction;
        self.manager.input = &self.record.?.inbox;
        self.manager.turn_id = self.context.?.turn;
        self.manager.observer = prepared.observer orelse .{ .context = self, .reset = resetOutput, .delta = delta };
        var request = prepared.request;
        request.messages = self.base.messages;
        request.cancel = &self.cancel;
        var projection: Projection = .{ .allocator = self.allocator, .original = prepared.provider, .context = self.context.?, .historical_messages = self.historical_messages };
        const adapter: provider.Provider = .{ .ctx = &projection, .chat = Projection.chat, .models = Projection.models };
        const result = if (self.answer_only) self.manager.resumeAnswer(adapter, &self.cancel) else self.manager.run(adapter, request);
        const succeeded = if (result) |_| true else |_| false;
        // Preserve the actual ledger even when Stop/budget wins. Never invent
        // a tool output to make a dangling transcript appear recoverable.
        self.capture_final = succeeded and !self.cancel.isCancelled();
        try self.capture();
        return result;
    }
    fn capture(self: *Runner) !void {
        self.capture_failed = true;
        if (self.manager.tool_run) |loop| {
            try loop.sealInterrupted();
            const snapshot = try wire.History.copy(self.allocator, loop.messages.items, if (self.capture_final and self.manager.saw_done and !loop.uncertain) self.manager.round_text.items else "");
            self.result.deinit();
            self.result = snapshot;
        }
        self.capture_failed = false;
    }
    const Projection = struct {
        allocator: std.mem.Allocator,
        original: provider.Provider,
        context: Context,
        historical_messages: usize,
        fn models(raw: *anyopaque, a: std.mem.Allocator) ![]provider.ModelInfo {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.original.models(self.original.ctx, a);
        }
        fn chat(raw: *anyopaque, request: provider.ChatRequest, sink: *const fn (*anyopaque, provider.Delta) void, ctx: *anyopaque) !provider.ChatStats {
            const self: *@This() = @ptrCast(@alignCast(raw));
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var projected = request;
            projected.system = try std.fmt.allocPrint(a, "{s}\n本轮起始绑定版本 {d}，环境版本 {d}；当前范围以最新宿主上下文通知和工具表为准。历史环境的连接、目录、执行和审批标识不提供当前操作权；仅当前工具表及本轮查询可确定目标。", .{ request.system, self.context.fence.binding, self.context.fence.environment });
            const messages = try a.dupe(provider.Message, request.messages);
            for (messages[0..@min(self.historical_messages, messages.len)]) |*message| {
                message.content = try std.fmt.allocPrint(a, "[历史环境，仅作记录]\n{s}", .{message.content});
                message.image_owner = null;
                message.image_transform = 0;
                const offloaded = try a.dupe(provider.OffloadedImage, message.offloaded_images);
                for (offloaded) |*value| value.owner = null;
                message.offloaded_images = offloaded;
            }
            projected.messages = messages;
            return self.original.chat(self.original.ctx, projected, sink, ctx);
        }
    };
    fn deinit(self: *Runner) void {
        self.cancel.cancel();
        if (self.thread) |thread| thread.join();
        self.base.deinit();
        self.result.deinit();
        self.manager.deinit();
        self.output.deinit();
        self.allocator.destroy(self);
    }
};
pub const Service = struct {
    allocator: std.mem.Allocator,
    store: lifecycle.Store,
    runners: std.ArrayList(*Runner) = .empty,
    next_turn: u64 = 1,
    mode: input.Mode = .steer,
    pub fn init(a: std.mem.Allocator) Service {
        return .{ .allocator = a, .store = lifecycle.Store.init(a) };
    }
    pub fn applySettings(self: *Service, ai: @import("../config/config.zig").Ai) void {
        self.mode = ai.follow_up_mode;
    }
    pub fn deinit(self: *Service) void {
        for (self.runners.items) |runner| runner.cancel.cancel();
        for (self.runners.items) |runner| runner.deinit();
        self.runners.deinit(self.allocator);
        self.store.deinit();
    }
    pub fn attach(self: *Service, owner: scope.Owner, backend: Backend) !*Runner {
        const agent = try self.store.attach(owner);
        for (self.runners.items) |runner| if (runner.agent.id.eql(agent.id)) return runner;
        try self.runners.ensureUnusedCapacity(self.allocator, 1);
        const runner = try self.allocator.create(Runner);
        runner.* = .{ .allocator = self.allocator, .agent = agent, .backend = backend, .manager = Manager.init(self.allocator), .output = stream.Mailbox.init(self.allocator) };
        self.runners.appendAssumeCapacity(runner);
        return runner;
    }
    pub fn runnerFor(self: *Service, agent: identity.AgentId) ?*Runner {
        for (self.runners.items) |runner| if (runner.agent.id.eql(agent)) return runner;
        return null;
    }
    pub fn retire(self: *Service, agent_id: identity.AgentId) !void {
        const runner = self.runnerFor(agent_id) orelse return error.AgentNotFound;
        if (runner.controller_busy or runner.thread != null or runner.pending_commit or runner.pending_notify or !runner.saved) return error.ResourceCleanupPending;
        try self.store.retire(agent_id);
        runner.approvals.stop();
        runner.questions.stop();
    }
    pub fn submit(self: *Service, ticket: input.Fence, id: identity.SubmissionId, message: provider.Message, override: ?input.Mode) !input.Receipt {
        const record = try self.store.validate(ticket);
        const runner = self.runnerFor(ticket.agent) orelse return error.AgentNotFound;
        const previous = record.inbox.receipt(id);
        const accepted = try record.inbox.admit(ticket, id, message, override orelse if (previous) |prior| prior.mode else self.mode);
        if (previous == null and accepted.route == .steer) {
            runner.approvals.supersede();
            runner.questions.supersede();
            if (runner.backend.supersede) |wake| if (runner.context) |context| wake(runner.backend.context, context);
        }
        // Admission has succeeded. Startup failure must leave the input owned
        // and observable, never return a false "not accepted" to the sender.
        self.pump(runner) catch |err| {
            runner.failure = err;
            record.inbox.pauseAll(.failure);
        };
        return record.inbox.receipt(accepted.id).?;
    }
    pub fn createAndSubmit(self: *Service, agent_id: identity.AgentId, id: identity.SubmissionId, message: provider.Message, override: ?input.Mode) !input.Receipt {
        const runner = self.runnerFor(agent_id) orelse return error.AgentNotFound;
        if (runner.agent.current) |current| {
            const record = self.store.find(current).?;
            if (record.inbox.receipt(id) == null) return error.BindingConflict;
            return self.submit(try self.store.fence(current), id, message, override);
        }
        const ticket = try self.store.createWithInput(agent_id, id, message, override orelse self.mode);
        const record = self.store.find(ticket.conversation).?;
        self.pump(runner) catch |err| {
            runner.failure = err;
            record.inbox.pauseAll(.failure);
        };
        return record.inbox.receipt(id).?;
    }
    pub fn pump(self: *Service, runner: *Runner) !void {
        if (runner.controller_busy or runner.thread != null or runner.agent.busy or runner.pending_commit or runner.pending_notify) return;
        const conversation = runner.agent.current orelse return;
        if (!readyForNext(runner)) return;
        const record = self.store.find(conversation).?;
        if (record.ending != null) return;
        const queued = record.inbox.next() orelse return;
        try self.start(runner, record, queued);
    }
    fn start(self: *Service, runner: *Runner, record: *lifecycle.Record, queued: input.Receipt) !void {
        if (runner.pending_commit or runner.pending_notify) return error.ResourceCleanupPending;
        if (!readyForNext(runner)) return error.ResourceCleanupPending;
        const conversation = record.id;
        const ticket = try self.store.fence(conversation);
        if (record.last_turn != 0) self.next_turn = @max(self.next_turn, try identity.advance(record.last_turn));
        const next = try identity.advance(self.next_turn);
        var base = try wire.History.copy(self.allocator, record.history.messages, "");
        var owned = true;
        errdefer if (owned) base.deinit();
        const context: Context = .{ .fence = ticket, .task = identity.TaskId.generate(), .turn = self.next_turn, .owner = runner.agent.owner, .submission = queued.id, .approvals = &runner.approvals, .questions = &runner.questions };
        try runner.approvals.configure(context.authority(), ticket.environment);
        runner.questions.configure(context.authority());
        _ = try record.inbox.claim(queued.id, queued.revision, null, self.next_turn, .start);
        runner.base.deinit();
        runner.base = base;
        owned = false;
        runner.result.deinit();
        runner.failure = null;
        runner.stats = .{};
        runner.cancel = .{};
        runner.saved = false;
        runner.capture_failed = false;
        runner.capture_final = false;
        runner.answer_only = false;
        runner.context = context;
        runner.commit_fence = ticket;
        runner.historical_messages = record.historical_messages;
        runner.record = record;
        runner.has_tools = runner.backend.local_released != null;
        self.next_turn = next;
        runner.manager.discardTranscript();
        if (runner.backend.capture) |capture| capture(runner.backend.context, context) catch |err| {
            runner.failure = err;
            runner.saved = true;
            runner.pending_notify = true;
            runner.state.store(.failed, .release);
            record.inbox.finish(context.turn, .failure);
            return err;
        };
        runner.agent.busy = true;
        runner.state.store(.running, .release);
        runner.thread = std.Thread.spawn(.{}, Runner.run, .{runner}) catch |err| {
            runner.agent.busy = false;
            runner.state.store(.failed, .release);
            runner.failure = err;
            record.inbox.finish(runner.context.?.turn, .failure);
            runner.saved = true;
            runner.pending_notify = true;
            return err;
        };
    }
    fn readyForNext(runner: *Runner) bool {
        if (!runner.has_tools) return true;
        const context = runner.context orelse return true;
        const check = runner.backend.local_released orelse return false;
        return check(runner.backend.context, context);
    }
    /// Serialized controller tick; join only after release-store. A durable
    /// store performs IO here, so use the application coordinator, not a view
    /// render/input callback, when a journal is bound.
    pub fn poll(self: *Service) !void {
        var failure: ?anyerror = null;
        for (self.runners.items) |runner| self.pollRunner(runner) catch |err| {
            if (failure == null) failure = err;
        };
        if (failure) |err| return err;
    }
    fn pollRunner(self: *Service, runner: *Runner) !void {
        const state = runner.state.load(.acquire);
        if (runner.thread != null and state != .running) {
            runner.thread.?.join();
            runner.thread = null;
            runner.pending_commit = true;
        }
        if (runner.pending_commit) {
            if (runner.capture_failed) try runner.capture();
            const context = runner.context.?;
            const record = runner.record.?;
            if (runner.result.messages.len != 0) {
                self.store.checkpoint(runner.commit_fence.?, context.turn, runner.result.messages, true) catch |err| {
                    runner.persistence_failure = err;
                    record.inbox.pauseAll(.failure);
                    return err;
                };
                runner.persistence_failure = null;
                if (runner.commit_fence.?.environment != context.fence.environment) record.historical_messages = record.history.messages.len;
            }
            runner.saved = true;
            runner.pending_commit = false;
            record.inbox.finish(context.turn, if (state == .done and runner.failure == null) null else if (state == .stopped) .stop else .failure);
            runner.agent.busy = false;
            runner.pending_notify = true;
        }
        if (runner.pending_notify) {
            if (runner.backend.completed) |completed| try completed(runner.backend.context, runner);
            runner.pending_notify = false;
            const record = runner.record.?;
            if (record.ending) |ending| {
                try self.finishEnd(runner, ending);
            }
        } else if (runner.thread == null and !runner.pending_commit and runner.record != null) {
            if (runner.record.?.ending) |ending| try self.finishEnd(runner, ending);
        }
        if (runner.thread == null and !runner.agent.busy) self.pump(runner) catch |err| {
            runner.failure = err;
            if (runner.record) |record| record.inbox.pauseAll(.failure);
            return err;
        };
    }
    fn finishEnd(self: *Service, runner: *Runner, ending: lifecycle.End) !void {
        if (runner.controller_busy or runner.pending_commit or runner.pending_notify) return;
        const released = if (runner.backend.local_released) |check| if (runner.context) |context| check(runner.backend.context, context) else true else !runner.has_tools;
        if (!released) return;
        try self.store.commitEnd(ending.fence, ending.operation, .{ .worker_joined = runner.thread == null, .dispatch_closed = true, .local_released = released, .transcript_saved = runner.saved });
        // An unbound record can now be removed. Keep no executor pointer into
        // its inbox or lifecycle state after publishing the release receipt.
        runner.record = null;
        runner.context = null;
        runner.commit_fence = null;
        runner.manager.input = null;
        runner.has_tools = false;
    }
    pub fn stop(self: *Service, ticket: input.Fence) !void {
        const record = try self.store.validate(ticket);
        const runner = self.runnerFor(ticket.agent).?;
        record.inbox.pauseAll(.stop);
        runner.cancel.cancel();
        if (runner.backend.stop) |stop_backend| if (runner.context) |context| stop_backend(runner.backend.context, context);
        runner.approvals.stop();
        runner.questions.stop();
        if (runner.backend.supersede) |wake| if (runner.context) |context| wake(runner.backend.context, context);
    }
    pub fn resumeConversation(self: *Service, id: identity.ConversationId, agent_id: identity.AgentId, revision: u64) !input.Fence {
        const runner = self.runnerFor(agent_id) orelse return error.AgentNotFound;
        if (runner.controller_busy or runner.thread != null or runner.pending_commit or runner.pending_notify or !runner.saved) return error.ResourceCleanupPending;
        const ticket = try self.store.resumeConversation(id, agent_id, revision);
        runner.record = self.store.find(id);
        runner.context = null;
        runner.has_tools = false;
        return ticket;
    }
    pub fn forkAndUse(self: *Service, source: identity.ConversationId, revision: u64, agent_id: identity.AgentId) !input.Fence {
        const runner = self.runnerFor(agent_id) orelse return error.AgentNotFound;
        if (runner.controller_busy or runner.thread != null or runner.pending_commit or runner.pending_notify or !runner.saved) return error.ResourceCleanupPending;
        const ticket = try self.store.forkAndUse(source, revision, agent_id);
        runner.record = self.store.find(ticket.conversation);
        runner.context = null;
        runner.has_tools = false;
        return ticket;
    }
    pub fn continueQueue(self: *Service, ticket: input.Fence) !void {
        const record = try self.store.validate(ticket);
        try record.inbox.continueQueue(ticket);
        try self.pump(self.runnerFor(ticket.agent) orelse return error.AgentNotFound);
    }
    /// Answer-only recovery reuses the joined Task's ledger. It creates no
    /// input or permission, exposes no tools, and cannot replay dispatches.
    pub fn resumeAnswer(self: *Service, ticket: input.Fence) !void {
        const record = try self.store.validate(ticket);
        const runner = self.runnerFor(ticket.agent) orelse return error.AgentNotFound;
        if (record.ending != null or runner.controller_busy or runner.thread != null or runner.agent.busy or runner.pending_commit or runner.pending_notify) return error.ResourceCleanupPending;
        var context = runner.context orelse return error.NoToolTurnToResume;
        if (!context.fence.conversation.eql(ticket.conversation) or runner.manager.tool_run == null) return error.BindingChanged;
        context.fence = ticket;
        context.owner = runner.agent.owner;
        record.inbox.lock();
        defer record.inbox.unlock();
        if (!record.inbox.admission) return error.ConversationEnding;
        runner.context = context;
        runner.commit_fence = ticket;
        runner.cancel = .{};
        runner.result.deinit();
        runner.failure = null;
        runner.saved = false;
        runner.answer_only = true;
        runner.capture_final = false;
        runner.capture_failed = false;
        runner.stats = .{};
        record.inbox.active_turn = context.turn;
        record.inbox.closing = true;
        runner.agent.busy = true;
        runner.state.store(.running, .release);
        runner.thread = std.Thread.spawn(.{}, Runner.run, .{runner}) catch |err| {
            runner.agent.busy = false;
            runner.saved = true;
            runner.state.store(.failed, .release);
            record.inbox.active_turn = null;
            record.inbox.closing = false;
            return err;
        };
    }
    pub fn reissue(self: *Service, ticket: input.Fence, original: identity.SubmissionId, revision: u64, id: identity.SubmissionId, current_payload: provider.Message) !input.Receipt {
        const record = try self.store.validate(ticket);
        const runner = self.runnerFor(ticket.agent) orelse return error.AgentNotFound;
        _ = try record.inbox.reissue(ticket, original, revision, id, current_payload, .queue);
        self.pump(runner) catch |err| {
            runner.failure = err;
            record.inbox.pauseAll(.failure);
        };
        return record.inbox.receipt(id).?;
    }
    /// Resource invalidation is immediate. The stopped worker can commit only
    /// its audit history; pending old-environment inputs stay paused.
    pub fn environmentChanged(self: *Service, ticket: input.Fence) !input.Fence {
        _ = try self.store.validate(ticket);
        const runner = self.runnerFor(ticket.agent) orelse return error.AgentNotFound;
        const next = try self.store.environmentChanged(ticket.agent);
        runner.commit_fence = next;
        try self.stop(next);
        return next;
    }
    /// Host-confirmed session-to-group handoff preserves this Task and worker.
    /// The backend's existing authority-refresh hook rebuilds the next table.
    pub fn handoff(self: *Service, ticket: input.Fence, owner: scope.Owner) !input.Fence {
        const runner = self.runnerFor(ticket.agent) orelse return error.AgentNotFound;
        const next = try self.store.handoff(ticket, owner);
        runner.commit_fence = next;
        runner.approvals.supersede();
        runner.questions.supersede();
        if (runner.backend.supersede) |wake| if (runner.context) |context| wake(runner.backend.context, context);
        return next;
    }
    /// Explicit queue-to-steer keeps the submission identity. Idle send-now
    /// starts the selected item, rather than silently consuming another head.
    pub fn sendNow(self: *Service, ticket: input.Fence, id: identity.SubmissionId, revision: u64) !input.Receipt {
        const record = try self.store.validate(ticket);
        const runner = self.runnerFor(ticket.agent) orelse return error.AgentNotFound;
        if (runner.controller_busy) return error.ResourceCleanupPending;
        const item = record.inbox.receipt(id) orelse return error.SubmissionNotFound;
        if (item.revision != revision) return error.QueueChanged;
        if (runner.agent.busy) {
            const turn = runner.context orelse return error.TurnChanged;
            _ = try record.inbox.claim(id, revision, null, turn.turn, .steer);
            runner.approvals.supersede();
            runner.questions.supersede();
            if (runner.backend.supersede) |wake| wake(runner.backend.context, turn);
        } else {
            if (runner.thread != null or runner.pending_commit or runner.pending_notify) return error.ResourceCleanupPending;
            try self.start(runner, record, item);
        }
        return record.inbox.receipt(id).?;
    }
    pub fn endConversation(self: *Service, ticket: input.Fence, operation: identity.HostOperationId) !void {
        const completed = self.store.beginEnd(ticket, operation) catch |err| {
            if (self.store.find(ticket.conversation)) |record| if (record.ending) |ending| if (ending.failed and ending.fence.eql(ticket)) {
                if (self.runnerFor(ticket.agent)) |runner| {
                    runner.cancel.cancel();
                    if (runner.backend.stop) |stop_backend| if (runner.context) |context| stop_backend(runner.backend.context, context);
                    runner.approvals.stop();
                    runner.questions.stop();
                    if (runner.backend.supersede) |wake| if (runner.context) |context| wake(runner.backend.context, context);
                }
            };
            return err;
        };
        if (completed) return;
        const runner = self.runnerFor(ticket.agent) orelse return error.AgentNotFound;
        runner.cancel.cancel();
        if (runner.backend.stop) |stop_backend| if (runner.context) |context| stop_backend(runner.backend.context, context);
        runner.approvals.stop();
        runner.questions.stop();
        if (runner.backend.supersede) |wake| if (runner.context) |context| wake(runner.backend.context, context);
        runner.record = self.store.find(ticket.conversation);
        if (runner.thread == null) try self.finishEnd(runner, runner.record.?.ending.?);
    }
};
