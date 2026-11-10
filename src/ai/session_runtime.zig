//! Non-UI application service. Controller calls are serialized; each agent's
//! stable runner keeps identity and commit state; its optional Worker owns
//! the model transcript, cancellation, approvals and stream until End releases it.
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
pub const task_budget = @import("task_budget.zig");

pub const Context = struct {
    fence: input.Fence,
    task: identity.TaskId,
    turn: u64,
    worker_generation: u64 = 0,
    child_origin: ?@import("host_tools.zig").ChildOrigin = null,
    parent_task: ?identity.TaskId = null,
    root_task: identity.TaskId = .{},
    owner: scope.Owner,
    submission: identity.SubmissionId = .{},
    approvals: ?*@import("host_approval.zig").Broker = null,
    questions: ?*@import("user_interaction.zig").Broker = null,
    pub fn authority(self: Context) @import("host_tools.zig").Context {
        return .{ .conversation_id = self.fence.conversation, .task_id = self.task, .binding = self.owner, .binding_revision = self.fence.binding, .grant_revision = self.fence.environment, .child_origin = self.child_origin };
    }
};
pub const Prepared = struct {
    reasoning: ?*const @import("live_reasoning.zig").State = null,
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
    /// Controller-safe End barrier, after join/capture/completed and local
    /// release. Save final presentation and release backend request resources.
    /// May return ResourceCleanupPending; retry without publishing an unbind.
    release_worker: ?*const fn (*anyopaque) anyerror!void = null,
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
pub const Worker = struct {
    manager: Manager,
    output: stream.Mailbox,
    cancel: provider.CancelToken = .{},
    base: wire.History = .{},
    result: wire.History = .{},
    approvals: @import("host_approval.zig").Broker = .{},
    questions: @import("user_interaction.zig").Broker = .{},

    fn deinit(self: *Worker, a: std.mem.Allocator) void {
        self.approvals.stop();
        self.questions.stop();
        self.manager.deinit();
        self.base.deinit();
        self.result.deinit();
        self.output.deinit();
        a.destroy(self);
    }
};
pub const Runner = struct {
    allocator: std.mem.Allocator,
    agent: *lifecycle.Agent,
    backend: Backend,
    worker: ?*Worker = null,
    worker_generation: u64 = 0,
    worker_released: bool = false,
    parent_task: ?identity.TaskId = null,
    root_task: ?identity.TaskId = null,
    task_root: ?*task_budget.Root = null,
    auto_end: bool = false,
    end_when_idle: bool = false,
    pending_task: ?identity.TaskId = null,
    task_outcome: task_budget.Status = .failed,
    slots: ?*task_budget.Slots = null,
    thread: ?std.Thread = null,
    state: std.atomic.Value(enum(u8) { idle, running, done, failed, stopped }) = .init(.idle),
    context: ?Context = null,
    commit_fence: ?input.Fence = null,
    historical_messages: usize = 0,
    record: ?*lifecycle.Record = null,
    failure: ?anyerror = null,
    persistence_failure: ?anyerror = null,
    stats: provider.ChatStats = .{},
    has_tools: bool = false,
    pending_commit: bool = false,
    checkpoint_write: ?lifecycle.Persistence.Write = null,
    pending_notify: bool = false,
    persistence_retry_at_ns: i128 = 0,
    controller_busy: bool = false,
    saved: bool = true,
    capture_failed: bool = false,
    capture_final: bool = false,
    answer_only: bool = false,
    observation_only: bool = false,

    pub fn persistenceRetryDelayNs(self: *const Runner) u64 {
        return @intCast(@max(0, self.persistence_retry_at_ns - @import("../platform/realtime.zig").monotonicNs()));
    }

    fn resetOutput(raw: *anyopaque) void {
        const self: *Runner = @ptrCast(@alignCast(raw));
        self.worker.?.output.reset();
    }
    fn delta(raw: *anyopaque, value: provider.Delta) !void {
        const self: *Runner = @ptrCast(@alignCast(raw));
        switch (value) {
            .text => |bytes| try self.worker.?.output.append(bytes),
            .thinking => |bytes| try self.worker.?.output.appendThinking(bytes),
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
        self.state.store(if (self.worker.?.cancel.isCancelled()) .stopped else if (self.failure != null) .failed else .done, .release);
    }
    fn execute(self: *Runner, io: std.Io) !provider.ChatStats {
        var prepared = try self.backend.prepare(self.backend.context, self.allocator, io, self.context.?);
        defer prepared.deinit();
        if (!prepared.scope.owner.eql(self.context.?.owner)) return error.BindingChanged;
        if (prepared.request.run_timeout_ms) |timeout_ms| try self.task_root.?.configure(self.context.?.task, timeout_ms);
        self.has_tools = prepared.host != null;
        if (self.has_tools and self.backend.local_released == null) return error.HostCleanupContractRequired;
        if (prepared.request.tool_table) |table| if (table.host_context) |captured| {
            if (!captured.conversation_id.eql(self.context.?.fence.conversation) or !captured.task_id.eql(self.context.?.task) or captured.binding_revision != self.context.?.fence.binding or !std.meta.eql(captured.child_origin, self.context.?.child_origin)) return error.InvalidHostAuthority;
        };
        if (self.context.?.child_origin != null) {
            if (prepared.host != null and prepared.request.tool_table == null) return error.InvalidHostAuthority;
            for (prepared.scope.memberIds()) |id| {
                for (self.agent.targets) |target| if (@backingInt(target.session_id) == id) break else {} else return error.TargetOutsideAssistant;
            }
            if (prepared.request.tool_table) |table| {
                for (table.captured_scope.memberIds()) |id| {
                    for (self.agent.targets) |target| if (@backingInt(target.session_id) == id) break else {} else return error.TargetOutsideAssistant;
                }
                for (table.entries) |entry| for (entry.targets) |binding| {
                    for (self.agent.targets) |target| if (target.eql(binding.owner)) break else {} else return error.TargetOutsideAssistant;
                };
            }
        }
        self.worker.?.manager.read_only = self.observation_only;
        self.worker.?.manager.scope = prepared.scope;
        self.worker.?.manager.tool_host = prepared.host;
        self.worker.?.manager.permission_engine = prepared.policy;
        self.worker.?.manager.tool_limits = prepared.limits;
        self.worker.?.manager.policy_revision = prepared.policy_revision;
        self.worker.?.manager.compaction_config = prepared.compaction;
        self.worker.?.manager.input = &self.record.?.inbox;
        self.worker.?.manager.shared_task = .{ .root = self.task_root.?, .task = self.context.?.task };
        self.worker.?.manager.turn_id = self.context.?.turn;
        self.worker.?.manager.observer = prepared.observer orelse .{ .context = self, .reset = resetOutput, .delta = delta };
        var request = prepared.request;
        request.messages = self.worker.?.base.messages;
        var task_control: TaskControl = .{ .runner = self };
        var task_cancel: provider.CancelToken = .{ .source = .{ .context = &task_control, .poll = TaskControl.cancelled, .user_wait = TaskControl.userWait, .resource_wait = TaskControl.resourceWait } };
        request.cancel = &task_cancel;
        var projection: Projection = .{ .allocator = self.allocator, .original = prepared.provider, .context = self.context.?, .historical_messages = self.historical_messages, .root = self.task_root.?, .slots = self.slots.?, .read_only = self.observation_only, .reasoning = prepared.reasoning };
        const adapter: provider.Provider = .{ .ctx = &projection, .chat = Projection.chat, .models = Projection.models };
        if (self.answer_only) {
            if (self.worker.?.manager.tool_run) |loop| loop.request.cancel = &task_cancel;
        }
        defer if (self.worker.?.manager.tool_run) |loop| {
            loop.request.cancel = &self.worker.?.cancel;
        };
        const result = if (self.answer_only) self.worker.?.manager.resumeAnswer(adapter, &self.worker.?.cancel) else self.worker.?.manager.run(adapter, request);
        const succeeded = if (result) |_| true else |_| false;
        // Preserve the actual ledger even when Stop/budget wins. Never invent
        // a tool output to make a dangling transcript appear recoverable.
        self.capture_final = succeeded and !self.worker.?.cancel.isCancelled();
        try self.capture();
        if (result) |stats| return stats else |err| {
            if (err == error.Cancelled and !self.worker.?.cancel.isCancelled()) self.task_root.?.check() catch |reason| return reason;
            return err;
        }
    }
    fn capture(self: *Runner) !void {
        self.capture_failed = true;
        if (self.worker.?.manager.tool_run) |loop| {
            try loop.sealInterrupted();
            const snapshot = try wire.History.copy(self.allocator, loop.messages.items, if (self.capture_final and self.worker.?.manager.saw_done and !loop.uncertain) self.worker.?.manager.round_text.items else "");
            self.worker.?.result.deinit();
            self.worker.?.result = snapshot;
        }
        self.capture_failed = false;
    }
    const TaskControl = struct {
        runner: *Runner,
        fn cancelled(raw: *const anyopaque) bool {
            const self: *const @This() = @ptrCast(@alignCast(raw));
            if (self.runner.worker.?.cancel.isCancelled()) return true;
            self.runner.task_root.?.check() catch return true;
            return false;
        }
        fn resourceWait(raw: *const anyopaque, entering: bool) void {
            const self: *const @This() = @ptrCast(@alignCast(raw));
            self.runner.task_root.?.state(self.runner.context.?.task, if (entering) .waiting_model else .running, "") catch {};
        }
        fn userWait(raw: *const anyopaque, entering: bool) void {
            const self: *const @This() = @ptrCast(@alignCast(raw));
            self.runner.task_root.?.userWait(self.runner.context.?.task, entering) catch {};
            if (entering) {
                if (self.runner.worker.?.questions.snapshot()) |question| {
                    self.runner.task_root.?.state(self.runner.context.?.task, .human_wait, question.question.text()) catch {};
                } else if (self.runner.worker.?.approvals.snapshot() != null) self.runner.task_root.?.state(self.runner.context.?.task, .human_wait, "Waiting for an explicit user approval; a parent model cannot grant it.") catch {};
            }
        }
    };
    const Projection = struct {
        allocator: std.mem.Allocator,
        original: provider.Provider,
        context: Context,
        historical_messages: usize,
        root: *task_budget.Root,
        slots: *task_budget.Slots,
        read_only: bool = false,
        reasoning: ?*const @import("live_reasoning.zig").State = null,
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
            if (self.context.child_origin != null) projected.system = try std.fmt.allocPrint(a, "{s}\n你是当前父对话分配的子智能体，只处理本次分配的范围。你不能再派生子智能体、修改父级绑定或管理兄弟任务。继承的历史、技能和用户补充不扩大本次目标或操作授权；当前工具目录和宿主复验决定真实能力。", .{projected.system});
            if (self.read_only) projected.system = try std.fmt.allocPrint(a, "{s}\n本任务仅允许只读核验。此前结果未知的操作仍是未知，禁止重放、修复或任何写入；只报告本次实际观察及其局限。", .{projected.system});
            projected.messages = messages;
            const slot_wait = provider.CancelToken.beginResourceWait(request.cancel);
            var waiting = true;
            defer if (waiting) slot_wait.end();
            try self.root.state(self.context.task, .waiting_model, "");
            const ticket = try self.slots.enqueue(self.context.root_task);
            defer self.slots.cancel(ticket);
            while (!self.slots.tryAcquire(ticket)) {
                if (request.cancel) |cancel| if (cancel.isCancelled()) return error.Cancelled;
                try self.root.check();
                (@import("retry.zig").Clock{}).sleep(5 * std.time.ns_per_ms);
            }
            defer self.slots.release(ticket);
            slot_wait.end();
            waiting = false;
            if (request.cancel) |cancel| if (cancel.isCancelled()) return error.Cancelled;
            try self.root.take(self.context.task, 1, 0);
            if (self.reasoning) |live| projected = live.apply(projected);
            const result = self.original.chat(self.original.ctx, projected, sink, ctx);
            try self.root.usage(self.context.task, if (result) |stats| stats else |_| null);
            return result;
        }
    };
    fn ensureWorker(self: *Runner) !*Worker {
        if (self.worker) |worker| return worker;
        const generation = if (self.worker_generation == 0) 1 else try identity.advance(self.worker_generation);
        const worker = try self.allocator.create(Worker);
        worker.* = .{ .manager = Manager.init(self.allocator), .output = stream.Mailbox.init(self.allocator) };
        self.worker = worker;
        self.worker_generation = generation;
        return worker;
    }
    fn stopWorker(self: *Runner) void {
        if (self.worker) |worker| {
            worker.cancel.cancel();
            worker.approvals.stop();
            worker.questions.stop();
        }
    }
    fn supersedeWorker(self: *Runner) void {
        if (self.worker) |worker| {
            worker.approvals.supersede();
            worker.questions.supersede();
        }
    }
    fn releaseWorker(self: *Runner) void {
        if (self.worker) |worker| worker.deinit(self.allocator);
        self.worker = null;
        // A failed durable unbind retains only the fence/record and saved
        // receipt; no pointer in Context may keep the destroyed brokers alive.
        if (self.context) |*context| {
            context.approvals = null;
            context.questions = null;
        }
    }
    fn deinit(self: *Runner) void {
        self.stopWorker();
        if (self.thread) |thread| thread.join();
        if (self.checkpoint_write) |write| write.release(write.context);
        self.checkpoint_write = null;
        self.releaseWorker();
        self.allocator.destroy(self);
    }
};
pub const Service = struct {
    allocator: std.mem.Allocator,
    store: lifecycle.Store,
    runners: std.ArrayList(*Runner) = .empty,
    next_turn: u64 = 1,
    task_roots: std.ArrayList(*task_budget.Root) = .empty,
    slots: task_budget.Slots = .{},
    mode: input.Mode = .steer,
    pub fn init(a: std.mem.Allocator) Service {
        return .{ .allocator = a, .store = lifecycle.Store.init(a) };
    }
    pub fn applySettings(self: *Service, ai: @import("../config/config.zig").Ai) void {
        self.mode = ai.follow_up_mode;
    }
    pub fn deinit(self: *Service) void {
        for (self.runners.items) |runner| runner.stopWorker();
        for (self.runners.items) |runner| runner.deinit();
        self.runners.deinit(self.allocator);
        for (self.task_roots.items) |root| {
            root.deinit();
            self.allocator.destroy(root);
        }
        self.task_roots.deinit(self.allocator);
        self.store.deinit();
    }
    pub fn attach(self: *Service, owner: scope.Owner, backend: Backend) !*Runner {
        const agent = try self.store.attach(owner);
        for (self.runners.items) |runner| if (runner.agent.id.eql(agent.id)) return runner;
        try self.runners.ensureUnusedCapacity(self.allocator, 1);
        const runner = try self.allocator.create(Runner);
        runner.* = .{ .allocator = self.allocator, .agent = agent, .backend = backend };
        self.runners.appendAssumeCapacity(runner);
        return runner;
    }
    /// Main-thread binding/factory publication. This does not start a model;
    /// the caller submits an explicit owned task input through the same inbox.
    pub fn useChild(self: *Service, parent: input.Fence, agent_id: identity.AgentId, revision: u64, live: scope.Scope, targets: []const identity.SessionHandle, backend: Backend, parent_task: ?identity.TaskId) !*Runner {
        if (parent_task) |task| {
            const parent_runner = self.runnerFor(parent.agent) orelse return error.NoActiveParentTask;
            const context = parent_runner.context orelse return error.NoActiveParentTask;
            if (!context.root_task.valid() or !context.task.eql(task) or !context.fence.conversation.eql(parent.conversation)) return error.NoActiveParentTask;
        }
        const record = try self.store.childFor(parent, agent_id);
        if (parent_task != null and record.closed_revision != null and !record.child.?.info.reusable) return error.ChildNotReusable;
        const existing = self.runnerFor(agent_id);
        if (existing) |runner| if (runner.worker != null or runner.thread != null or runner.pending_commit or runner.pending_notify or !runner.saved or runner.agent.current != null) return error.ResourceCleanupPending;
        try self.runners.ensureUnusedCapacity(self.allocator, @intFromBool(existing == null));
        const fresh = if (existing == null) try self.allocator.create(Runner) else null;
        errdefer if (fresh) |runner| self.allocator.destroy(runner);
        const ticket = try self.store.bindChild(parent, agent_id, revision, live, targets);
        const runner = existing orelse fresh.?;
        if (existing == null) {
            runner.* = .{ .allocator = self.allocator, .agent = self.store.agent(agent_id).?, .backend = backend };
            self.runners.appendAssumeCapacity(runner);
        } else runner.backend = backend;
        runner.record = record;
        runner.commit_fence = ticket;
        runner.context = null;
        runner.has_tools = false;
        runner.worker_released = false;
        runner.parent_task = null;
        runner.root_task = null;
        runner.observation_only = false;
        runner.auto_end = false;
        runner.end_when_idle = false;
        runner.pending_task = null;
        runner.task_root = null;
        if (parent_task != null) {
            const context = self.runnerFor(parent.agent).?.context.?;
            runner.parent_task = context.task;
            runner.root_task = context.root_task;
        }
        return runner;
    }
    pub fn adoptChild(self: *Service, record: *lifecycle.Record, backend: Backend, root: *task_budget.Root, fact: task_budget.Fact) !*Runner {
        const agent_id = record.child.?.info.agent;
        const runner = self.runnerFor(agent_id) orelse fresh: {
            try self.runners.ensureUnusedCapacity(self.allocator, 1);
            const fresh = try self.allocator.create(Runner);
            fresh.* = .{ .allocator = self.allocator, .agent = self.store.agent(agent_id).?, .backend = backend };
            self.runners.appendAssumeCapacity(fresh);
            break :fresh fresh;
        };
        runner.backend = backend;
        runner.observation_only = fact.read_only;
        runner.context = null;
        runner.record = record;
        runner.commit_fence = try self.store.fence(record.id);
        runner.parent_task = fact.parent;
        runner.root_task = fact.root;
        runner.task_root = root;
        runner.slots = &self.slots;
        runner.pending_task = fact.task;
        runner.auto_end = true;
        runner.end_when_idle = false;
        runner.worker_released = false;
        runner.saved = true;
        return runner;
    }
    pub fn validateAuthority(self: *Service, authority: @import("host_tools.zig").Context) !*lifecycle.Record {
        try authority.validate();
        const record = self.store.find(authority.conversation_id) orelse return error.ScopeChanged;
        const ticket = self.store.fence(record.id) catch return error.ScopeChanged;
        _ = self.store.validateExecution(ticket) catch return error.ScopeChanged;
        const runner = self.runnerFor(ticket.agent) orelse return error.ScopeChanged;
        const context = runner.context orelse return error.ScopeChanged;
        const current_fence = runner.commit_fence orelse context.fence;
        if (runner.worker == null or runner.worker_released or !context.fence.conversation.eql(authority.conversation_id) or !context.task.eql(authority.task_id) or !runner.agent.owner.eql(authority.binding) or current_fence.binding != authority.binding_revision or !std.meta.eql(context.child_origin, authority.child_origin)) return error.ScopeChanged;
        return record;
    }
    pub fn runnerFor(self: *Service, agent: identity.AgentId) ?*Runner {
        for (self.runners.items) |runner| if (runner.agent.id.eql(agent)) return runner;
        return null;
    }
    pub fn retire(self: *Service, agent_id: identity.AgentId) !void {
        const runner = self.runnerFor(agent_id) orelse return error.AgentNotFound;
        if (runner.controller_busy or runner.thread != null or runner.pending_commit or runner.pending_notify or !runner.saved) return error.ResourceCleanupPending;
        try self.store.retire(agent_id);
        runner.stopWorker();
    }
    pub fn previewInput(self: *Service, ticket: input.Fence, mode: input.Mode) !input.Route {
        const record = try self.store.validateExecution(ticket);
        const runner = self.runnerFor(ticket.agent) orelse return error.AgentNotFound;
        const route = record.inbox.previewRoute(mode);
        if (route == .start and (runner.controller_busy or runner.thread != null or runner.agent.busy or runner.pending_commit or runner.pending_notify or !readyForNext(runner))) return .queue;
        return route;
    }
    pub fn submit(self: *Service, ticket: input.Fence, id: identity.SubmissionId, message: provider.Message, override: ?input.Mode) !input.Receipt {
        const record = try self.store.validateExecution(ticket);
        const runner = self.runnerFor(ticket.agent) orelse return error.AgentNotFound;
        const previous = record.inbox.receipt(id);
        const accepted = try record.inbox.admit(ticket, id, message, override orelse if (previous) |prior| prior.mode else self.mode);
        if (previous == null and accepted.route == .steer) {
            runner.supersedeWorker();
            if (!runner.worker_released) if (runner.backend.supersede) |wake| if (runner.context) |context| wake(runner.backend.context, context);
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
        if (runner.pending_commit or runner.pending_notify or (record.task_pending and runner.pending_task == null)) return error.ResourceCleanupPending;
        if (!readyForNext(runner)) return error.ResourceCleanupPending;
        _ = try runner.ensureWorker();
        runner.worker_released = false;
        const conversation = record.id;
        const ticket = try self.store.fence(conversation);
        _ = try self.store.validateExecution(ticket);
        if (record.last_turn != 0) self.next_turn = @max(self.next_turn, try identity.advance(record.last_turn));
        const next = try identity.advance(self.next_turn);
        var base = try wire.History.copy(self.allocator, record.history.messages, "");
        var owned = true;
        errdefer if (owned) base.deinit();
        const task = runner.pending_task orelse identity.TaskId.generate();
        const context: Context = .{ .child_origin = if (runner.agent.parent_binding) |parent| .{ .agent = runner.agent.id, .parent = parent, .worker_generation = runner.worker_generation, .scope_revision = runner.agent.environment } else null, .parent_task = runner.parent_task, .root_task = runner.root_task orelse task, .fence = ticket, .task = task, .turn = self.next_turn, .worker_generation = runner.worker_generation, .owner = runner.agent.owner, .submission = queued.id, .approvals = &runner.worker.?.approvals, .questions = &runner.worker.?.questions };
        if (runner.parent_task != null) {
            const parent_runner = self.runnerFor(runner.agent.parent_binding.?.agent) orelse return error.NoActiveParentTask;
            runner.task_root = parent_runner.task_root orelse return error.NoActiveParentTask;
        } else {
            try self.task_roots.ensureUnusedCapacity(self.allocator, 1);
            const root = try self.allocator.create(task_budget.Root);
            root.* = task_budget.Root.init(self.allocator);
            root.persist = .{ .context = &self.store, .write = lifecycle.Store.persistTask };
            self.task_roots.appendAssumeCapacity(root);
            runner.task_root = root;
        }
        runner.slots = &self.slots;
        if (runner.pending_task == null) try runner.task_root.?.add(.{ .root = context.root_task, .task = context.task, .parent = context.parent_task, .conversation = record.id, .agent = runner.agent.id, .generation = runner.worker_generation, .read_only = runner.observation_only, .targets = if (runner.agent.role == .child) runner.agent.targets else null });
        record.task_pending = true;
        try runner.worker.?.approvals.configure(context.authority(), ticket.environment);
        runner.worker.?.questions.configure(context.authority());
        _ = try record.inbox.claim(queued.id, queued.revision, null, self.next_turn, .start);
        record.inbox.setWorkPhase(context.turn, .starting);
        runner.worker.?.base.deinit();
        runner.worker.?.base = base;
        owned = false;
        runner.worker.?.result.deinit();
        runner.failure = null;
        runner.persistence_retry_at_ns = 0;
        runner.stats = .{};
        runner.worker.?.cancel = .{};
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
        runner.pending_task = null;
        runner.worker.?.manager.discardTranscript();
        if (runner.backend.capture) |capture| capture(runner.backend.context, context) catch |err| {
            std.log.warn("AI request capture failed: {s}", .{@errorName(err)});
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
    fn commitSync(self: *Service, runner: *Runner, turn: u64) !void {
        self.store.checkpoint(runner.commit_fence.?, turn, runner.worker.?.result.messages, true) catch |err| {
            runner.persistence_failure = err;
            runner.record.?.inbox.pauseAll(.failure);
            return err;
        };
    }
    fn readyForNext(runner: *Runner) bool {
        if (runner.worker_released or !runner.has_tools) return true;
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
            // A full/conflicted/unwritable journal cannot recover on the next
            // display frame. Keep the durable work pending without a hot loop.
            switch (err) {
                error.JournalLimit, error.JournalConflict, error.NoSpaceLeft, error.DiskQuota, error.InputOutput, error.AccessDenied => runner.persistence_retry_at_ns = @import("../platform/realtime.zig").monotonicNs() + 5 * std.time.ns_per_s,
                else => {},
            }
            if (failure == null) failure = err;
        };
        if (failure) |err| return err;
    }
    fn pollRunner(self: *Service, runner: *Runner) !void {
        if (runner.persistenceRetryDelayNs() != 0) return;
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
            if (runner.worker.?.result.messages.len != 0) {
                if (self.store.persist) |persistence| if (persistence.checkpoint) |begin| {
                    if (runner.checkpoint_write == null) {
                        _ = try self.store.validate(runner.commit_fence.?);
                        _ = try identity.advance(record.content_revision);
                        runner.checkpoint_write = begin(persistence.context, .{ .kind = .checkpoint, .conversation = record.id, .agent = runner.commit_fence.?.agent, .revision = record.revision, .turn = context.turn, .messages = runner.worker.?.result.messages, .recoverable = true }) catch |err| {
                            if (err == error.WorkerBusy) return;
                            runner.persistence_failure = err;
                            record.inbox.pauseAll(.failure);
                            return err;
                        };
                    }
                    const write = runner.checkpoint_write.?;
                    if (!write.ready(write.context)) return;
                    write.finish(write.context) catch |err| {
                        write.release(write.context);
                        runner.checkpoint_write = null;
                        runner.persistence_failure = err;
                        record.inbox.pauseAll(.failure);
                        return err;
                    };
                    write.release(write.context);
                    runner.checkpoint_write = null;
                    try self.store.publishDurableCheckpoint(runner.commit_fence.?, context.turn, &runner.worker.?.result, true);
                } else {
                    try self.commitSync(runner, context.turn);
                } else try self.commitSync(runner, context.turn);
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
            if (runner.task_root) |root| if (runner.context) |context| {
                runner.task_outcome = if (runner.worker.?.manager.tool_run != null and runner.worker.?.manager.tool_run.?.uncertain) .outcome_unknown else if (state == .stopped) .cancelled else if (runner.failure != null) .failed else .succeeded;
                const summary = if (runner.worker) |worker| if (worker.manager.saw_done) worker.manager.round_text.items else "" else "";
                const queued_input = runner.end_when_idle and queuedInputs(runner.record.?);
                if (queued_input) {
                    const ready = runner.record.?.inbox.next() != null;
                    try root.state(context.task, if (ready) .settling else .human_wait, if (ready) summary else "排队输入等待继续或处理");
                } else if (!runner.end_when_idle and (context.parent_task == null or !runner.auto_end)) {
                    try root.state(context.task, runner.task_outcome, summary);
                    runner.record.?.task_pending = false;
                } else {
                    try root.state(context.task, .settling, summary);
                    if (runner.record.?.ending == null) _ = try self.store.beginEnd(runner.commit_fence.?, identity.HostOperationId.generate());
                }
            };
            runner.pending_notify = false;
            const record = runner.record.?;
            if (record.ending) |ending| {
                try self.finishEnd(runner, ending);
            }
        } else if (runner.thread == null and !runner.pending_commit and runner.record != null) {
            if (runner.record.?.ending) |ending| {
                try self.finishEnd(runner, ending);
            } else if (runner.worker_released and runner.record.?.task_pending) {
                // Unbind may already be durable while the final task fact is
                // still pending. Keep retrying the same completed End receipt.
                if (runner.record.?.last_end) |ending| try self.finishEnd(runner, ending);
            }
        }
        if (runner.end_when_idle and runner.record != null and runner.record.?.ending == null and runner.thread == null and !runner.pending_commit and !runner.pending_notify and runner.record.?.task_pending and runner.record.?.inbox.next() != null and readyForNext(runner)) {
            try self.continueChildQueue(runner);
        }
        if (runner.thread == null and !runner.agent.busy) self.pump(runner) catch |err| {
            runner.failure = err;
            if (runner.record) |record| record.inbox.pauseAll(.failure);
            return err;
        };
    }
    fn queuedInputs(record: *lifecycle.Record) bool {
        record.inbox.lock();
        defer record.inbox.unlock();
        for (record.inbox.entries.items) |entry| if (!entry.receipt.archived and (entry.receipt.delivery == .queued or entry.receipt.delivery == .accepted or entry.receipt.delivery == .submitting or entry.receipt.delivery == .outcome_unknown)) return true;
        return false;
    }
    fn continueChildQueue(self: *Service, runner: *Runner) !void {
        const context = runner.context orelse return error.TurnChanged;
        if (!runner.worker_released) {
            if (runner.backend.release_worker) |release| try release(runner.backend.context);
            runner.releaseWorker();
            runner.worker_released = true;
        }
        const root = runner.task_root.?;
        if (context.parent_task != null) {
            const next_task = identity.TaskId.generate();
            try root.rollover(context.task, runner.task_outcome, .{ .root = context.root_task, .task = next_task, .parent = context.parent_task, .conversation = context.fence.conversation, .agent = runner.agent.id, .generation = try identity.advance(runner.worker_generation), .read_only = runner.observation_only, .targets = runner.agent.targets });
            runner.pending_task = next_task;
        } else try root.state(context.task, runner.task_outcome, "");
        runner.record.?.task_pending = false;
        _ = self;
    }
    fn finishEnd(self: *Service, runner: *Runner, ending: lifecycle.End) !void {
        if (runner.controller_busy or runner.thread != null or runner.pending_commit or runner.pending_notify or !runner.saved or self.store.hasBoundChildren(ending.fence.conversation)) return;
        const released = runner.worker_released or if (runner.backend.local_released) |check| if (runner.context) |context| check(runner.backend.context, context) else true else !runner.has_tools;
        if (!released) return;
        if (!runner.worker_released) {
            if (runner.backend.release_worker) |release| release(runner.backend.context) catch |err| {
                if (err == error.ResourceCleanupPending) return;
                return err;
            };
            runner.releaseWorker();
            runner.worker_released = true;
        }
        try self.store.commitEnd(ending.fence, ending.operation, .{ .worker_joined = runner.thread == null, .dispatch_closed = true, .local_released = released, .transcript_saved = runner.saved });
        // An unbound record can now be removed. Keep no executor pointer into
        // its inbox or lifecycle state after publishing the release receipt.
        if (runner.task_root) |root| if (runner.context) |context| if (context.parent_task != null or runner.end_when_idle) {
            try root.state(context.task, runner.task_outcome, "");
        };
        if (runner.record) |record| record.task_pending = false;
        runner.record = null;
        runner.context = null;
        runner.commit_fence = null;
        runner.has_tools = false;
    }
    pub fn stop(self: *Service, ticket: input.Fence) !void {
        const record = try self.store.validate(ticket);
        const runner = self.runnerFor(ticket.agent).?;
        record.inbox.pauseAll(.stop);
        runner.stopWorker();
        if (!runner.worker_released) if (runner.backend.stop) |stop_backend| if (runner.context) |context| stop_backend(runner.backend.context, context);
        if (!runner.worker_released) if (runner.backend.supersede) |wake| if (runner.context) |context| wake(runner.backend.context, context);
        if (runner.context) |context| for (self.runners.items) |child_runner| {
            const child_context = child_runner.context orelse continue;
            const direct_parent = child_runner.agent.parent_binding orelse continue;
            const parent_task = child_context.parent_task orelse continue;
            if (direct_parent.conversation.eql(ticket.conversation) and parent_task.eql(context.task) and child_runner.agent.current != null) try self.stop(try self.store.fence(child_runner.agent.current.?));
        };
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
        if (runner.worker == null) return error.NoToolTurnToResume;
        var context = runner.context orelse return error.NoToolTurnToResume;
        if (!context.fence.conversation.eql(ticket.conversation) or runner.worker.?.manager.tool_run == null) return error.BindingChanged;
        context.fence = ticket;
        context.owner = runner.agent.owner;
        record.inbox.lock();
        defer record.inbox.unlock();
        if (!record.inbox.admission) return error.ConversationEnding;
        try runner.task_root.?.resumeAnswer(context.task);
        record.task_pending = true;
        runner.context = context;
        runner.commit_fence = ticket;
        runner.worker.?.cancel = .{};
        runner.worker.?.result.deinit();
        runner.failure = null;
        runner.saved = false;
        runner.answer_only = true;
        runner.persistence_retry_at_ns = 0;
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
        runner.supersedeWorker();
        if (!runner.worker_released) if (runner.backend.supersede) |wake| if (runner.context) |context| wake(runner.backend.context, context);
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
            runner.supersedeWorker();
            if (!runner.worker_released) if (runner.backend.supersede) |wake| wake(runner.backend.context, turn);
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
                    runner.stopWorker();
                    if (!runner.worker_released) if (runner.backend.stop) |stop_backend| if (runner.context) |context| stop_backend(runner.backend.context, context);
                    if (!runner.worker_released) if (runner.backend.supersede) |wake| if (runner.context) |context| wake(runner.backend.context, context);
                }
            };
            return err;
        };
        if (completed) return;
        const runner = self.runnerFor(ticket.agent) orelse return error.AgentNotFound;
        runner.stopWorker();
        if (!runner.worker_released) if (runner.backend.stop) |stop_backend| if (runner.context) |context| stop_backend(runner.backend.context, context);
        if (!runner.worker_released) if (runner.backend.supersede) |wake| if (runner.context) |context| wake(runner.backend.context, context);
        runner.record = self.store.find(ticket.conversation);
        var child_failure: ?anyerror = null;
        for (self.store.records.items) |record| if (record.child) |owned| {
            if (!owned.info.owning_parent_conversation.eql(ticket.conversation) or record.binding == null) continue;
            const child_ticket = try self.store.fence(record.id);
            const child_operation = if (record.ending) |ending| ending.operation else identity.HostOperationId.generate();
            self.endConversation(child_ticket, child_operation) catch |err| {
                if (child_failure == null) child_failure = err;
            };
        };
        if (child_failure) |err| return err;
        if (runner.thread == null) try self.finishEnd(runner, runner.record.?.ending.?);
    }
    /// One main-thread poll. The parent task/root stays alive; no join or wait
    /// occurs under a UI/Bridge lock. poll() owns final worker/fact settlement.
    pub fn quiesceChildren(self: *Service, parent: input.Fence, operation: identity.HostOperationId) !bool {
        try self.store.beginTransition(parent, operation);
        var failure: ?anyerror = null;
        for (self.store.records.items) |record| if (record.child) |owned| {
            if (!owned.info.owning_parent_conversation.eql(parent.conversation) or record.binding == null) continue;
            // A committed End is already being driven by poll(); do not write
            // the same request on every waiting frame. Failed saves may retry.
            if (record.ending) |pending| if (!pending.failed) continue;
            const ticket = try self.store.fence(record.id);
            const ending = if (record.ending) |pending| pending.operation else identity.HostOperationId.generate();
            self.endConversation(ticket, ending) catch |err| {
                if (failure == null) failure = err;
            };
        };
        if (failure) |err| return err;
        return !self.store.hasBoundChildren(parent.conversation);
    }
};
