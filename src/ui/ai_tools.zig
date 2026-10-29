//! The assistant consumes registered tool contributions and captured typed
//! services. Builtin engines are opaque provider-contributed bridge instances.
const std = @import("std");
const Application = @import("application_host.zig");
const identity = @import("../host/identity.zig");
const loop = @import("../ai/tool_loop.zig");
const provider = @import("../ai/provider.zig");
const scope = @import("../ai/tool_scope.zig");
const tools = @import("../ai/plugin_tools.zig");
const legacy = @import("../ai/legacy_adapter.zig");
const typed = @import("../host/plugin_services.zig");
const operations = @import("../host/operation_store.zig");
const approvals = @import("../ai/host_approval.zig");
const routing = approvals.routing;
const host_tools = @import("../ai/host_tools.zig");
pub const HostBinding = struct {
    context: host_tools.Context,
    handler_context: *anyopaque,
    invoke: *const fn (*anyopaque, host_tools.Invocation, std.mem.Allocator) anyerror!host_tools.Result,
    invoke_worker: ?*const fn (*anyopaque, *Bridge, host_tools.Invocation, std.mem.Allocator, ?*provider.CancelToken) anyerror!host_tools.Result = null,
    contributions: []const host_tools.Contribution,
    refresh: ?*const fn (*anyopaque, *Bridge, *const tools.RequestTable, std.mem.Allocator, ?*provider.CancelToken) anyerror!?loop.AuthorityRefresh = null,
    acknowledge_notice: ?*const fn (*anyopaque, u64) anyerror!void = null,
    accepted_result: ?*const fn (*anyopaque, host_tools.Context, []const u8, *const host_tools.Result) anyerror!void = null,
};
pub const Approval = legacy.Approval;
const Child = struct {
    owner: identity.SessionHandle,
    adapter: ?legacy.Adapter = null,
    invocation_context: legacy.InvocationContext = undefined,
    member: tools.Member,
    live_services: std.ArrayList(typed.Binding) = .empty,
};
const ApprovalExchange = struct { invocation: tools.DynamicInvocation, ticket: *tools.ApprovalTicket, sequence: u64, decision: enum { pending, approved, rejected } = .pending };
const ControllerExchange = struct {
    target: tools.TargetBinding,
    invocation: tools.Invocation,
    allocator: std.mem.Allocator,
    ready: std.atomic.Value(bool) = .init(false),
    result: ?tools.ToolResult = null,
    failure: ?anyerror = null,
    cancel: ?*provider.CancelToken,
};
const HostExchange = struct {
    invocation: host_tools.Invocation,
    allocator: std.mem.Allocator,
    cancel: ?*provider.CancelToken,
    processing: bool = false,
    ready: bool = false,
    result: ?host_tools.Result = null,
    failure: ?anyerror = null,
};
const ControllerTask = struct {
    context: *anyopaque,
    invoke: *const fn (*anyopaque) anyerror!void,
    processing: bool = false,
    ready: bool = false,
    failure: ?anyerror = null,
};
pub const Bridge = struct {
    allocator: std.mem.Allocator,
    events: ?*@import("../ai/step_events.zig").Mailbox = null,
    children: std.ArrayList(*Child) = .empty,
    captured_scope: ?scope.Scope = null,
    table: ?tools.RequestTable = null,
    wire: []provider.ToolDefinition = &.{},
    files: ?*@import("file_application_host.zig").Host = null,
    policy: tools.Policy = .{},
    execution_mode: @import("../config/config.zig").ExecutionMode = .auto,
    session_retention: @import("../config/config.zig").SessionRetention = .auto_idle,
    route_broker: ?*approvals.Broker = null,
    active_route: ?struct { permit: approvals.Permit, invocation: host_tools.Invocation, subject: approvals.Subject } = null,
    policy_revision: u64 = 1,
    roster: ?*@import("group_model.zig").Roster = null,
    roster_revision: u64 = 0,
    mutex: std.atomic.Mutex = .unlocked,
    pending: ?*ApprovalExchange = null,
    controller: ?*ControllerExchange = null,
    host_binding: ?HostBinding = null,
    host_exchange: ?*HostExchange = null,
    controller_task: ?*ControllerTask = null,
    pending_binding: ?scope.Owner = null,
    running: ?tools.DynamicInvocation = null,
    sequence: u64 = 0,
    approval_target: [4096]u8 = undefined,
    stopped: std.atomic.Value(bool) = .init(false),
    owned_history: operations.Store,
    shared_history: ?*operations.Store = null,
    validation_arena: std.heap.ArenaAllocator,
    capture_arena: std.heap.ArenaAllocator,
    /// Joined Tasks can still own an adapter whose native cleanup is pending.
    /// Keep that exact capture alive while a fresh Task queries host metadata.
    retired: std.ArrayList(*Bridge) = .empty,
    queries_only: bool = false,

    pub fn init(allocator: std.mem.Allocator) Bridge {
        return .{ .allocator = allocator, .owned_history = operations.Store.init(allocator), .validation_arena = .init(allocator), .capture_arena = .init(allocator) };
    }
    pub fn operationHistory(self: *Bridge) *operations.Store {
        return self.shared_history orelse &self.owned_history;
    }
    pub fn queryOperation(self: *Bridge, allocator: std.mem.Allocator, owner: identity.SessionHandle, operation_id: u64) !?operations.Snapshot {
        return self.operationHistory().snapshot(allocator, owner, operation_id);
    }
    fn lock(self: *Bridge) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    pub fn configurePolicy(self: *Bridge, engine: @import("../ai/permission.zig").Engine, revision: u64) void {
        self.policy = .{ .engine = engine, .full_control = engine.mode == .auto };
        self.policy_revision = revision;
    }
    pub fn configureFiles(self: *Bridge, files: ?*@import("file_application_host.zig").Host) void {
        self.files = files;
    }
    pub fn configureHost(self: *Bridge, binding: HostBinding) !void {
        if (self.captured_scope != null or self.host_exchange != null) return error.ToolCleanupPending;
        try binding.context.validate();
        self.host_binding = binding;
        if (self.queries_only) self.host_binding.?.contributions = &@import("../ai/host_queries.zig").contributions;
    }
    /// Submitted is the current trusted composer submission. A model or tool
    /// argument has no entry point for creating an intent grant.
    pub fn configureRouting(self: *Bridge, broker: *approvals.Broker, context: host_tools.Context, submitted: []const u8, selected: ?identity.SessionHandle) !void {
        if (self.queries_only) {
            self.route_broker = null;
            return;
        }
        try broker.execution_route.captureIntent(context, submitted, selected, self.session_retention);
        self.route_broker = broker;
    }
    /// Before backend preflight, freeze any trusted intent to this exact
    /// command. The backend still owns capability, forbidden and mode gates.
    pub fn prepareHostRoute(self: *Bridge, invocation: host_tools.Invocation, subject: *approvals.Subject, target: identity.SessionHandle, proposed: routing.Route, allocator: std.mem.Allocator) !?host_tools.Result {
        if (self.queries_only) return error.ToolNotAvailable;
        const broker = self.route_broker orelse return null;
        const resolution = broker.execution_route.resolve(invocation.context, target, subject.detail, routing.fixedRoute(self.execution_mode, proposed));
        if (resolution.trusted and (resolution.route != proposed or resolution.needs_creation)) return try planChange(invocation, allocator, resolution.route, resolution.needs_creation);
        if (!resolution.trusted and self.execution_mode != .auto and self.execution_mode != .ask and routing.fixedRoute(self.execution_mode, proposed) != proposed) return error.ModeConflict;
        const choice: routing.Choice = resolution.choice orelse .{ .route = resolution.route, .source = .{ .session = target }, .retention = self.session_retention };
        if (resolution.trusted and !resolution.approved) try broker.execution_route.select(invocation.context, choice, subject.detail, false);
        subject.route = .{ .proposed = proposed, .choice = choice, .target = target, .selectable = self.execution_mode == .ask and !resolution.trusted, .reason = if (resolution.trusted) "按本次用户明确指令；仅覆盖此命令。" else "按本次命令选择运行方式；权限确认与选择合并。" };
        return null;
    }
    pub fn requestHostRoute(self: *Bridge, invocation: host_tools.Invocation, subject: approvals.Subject, allocator: std.mem.Allocator, cancel: ?*provider.CancelToken) !approvals.Permit {
        if (self.queries_only) return error.ToolNotAvailable;
        const broker = self.route_broker orelse return error.RouteSelectionUnavailable;
        if (try broker.beginGrantedSubject(invocation, subject, self.policy_revision, allocator)) |permit| return permit;
        return broker.requestSubject(invocation, subject, self.policy_revision, allocator, cancel);
    }
    pub fn hostRouteChange(self: *Bridge, invocation: host_tools.Invocation, subject: approvals.Subject, permit: approvals.Permit, allocator: std.mem.Allocator) !?host_tools.Result {
        const proposed = (subject.route orelse return null).proposed;
        const selected = try (self.route_broker orelse return error.RouteSelectionUnavailable).selectedRoute(permit);
        if (selected.route != proposed) return try planChange(invocation, allocator, selected.route, selected.route == .new_terminal or selected.create_new);
        return null;
    }
    pub fn consumeHostRoute(self: *Bridge, invocation: host_tools.Invocation, target: identity.SessionHandle, command: []const u8) void {
        if (self.route_broker) |broker| broker.execution_route.consume(invocation.context, target, command);
    }
    fn planChange(invocation: host_tools.Invocation, allocator: std.mem.Allocator, selected: routing.Route, requires_creation: bool) !host_tools.Result {
        const body = try std.json.Stringify.valueAlloc(allocator, .{ .error_code = "requires_plan_change", .state = "cancelled_unsent", .selected_route = @tagName(selected), .requires_new_session = requires_creation, .host_fact = "用户已为这一条精确命令选择运行方式。当前工具没有派发；下一轮请生成所选方式的真实工具调用，所需创建步骤仍按精确依赖验证。", .next_tool = if (requires_creation and selected == .batch) "host.create_group/host.open_session/run_command" else if (selected == .batch) "run_command" else if (selected == .current_terminal) "host.run_in_terminal" else "host.create_group/host.open_session/host.run_in_terminal", .side_effect_started = false }, .{});
        errdefer allocator.free(body);
        const blocks = try allocator.alloc(host_tools.Block, 1);
        blocks[0] = .{ .structured = body };
        return .{ .status = .cancelled_unsent, .blocks = blocks, .receipt = .{ .conversation_id = invocation.context.conversation_id, .task_id = invocation.context.task_id, .operation_id = invocation.operation_id, .binding_revision = invocation.context.binding_revision } };
    }
    /// Called only after the previous participant worker joined. Failure to
    /// release a native adapter narrows the next Task; it never drops ownership.
    pub fn beginRequest(self: *Bridge) !void {
        if (self.quiescent() != true) return error.ToolCleanupPending;
        self.reapRetired();
        self.clearPrepared() catch |err| {
            if (err != error.ToolCleanupPending) return err;
            try self.retainPrepared();
        };
        self.queries_only = self.retired.items.len != 0;
    }
    fn retainPrepared(self: *Bridge) !void {
        // While one old Task is unsettled, every subsequent Task is metadata
        // only and creates no adapters. Never accumulate native owners.
        if (self.retired.items.len != 0) return error.ToolCleanupPending;
        const retained = try self.allocator.create(Bridge);
        errdefer self.allocator.destroy(retained);
        try self.retired.append(self.allocator, retained);
        retained.* = Bridge.init(self.allocator);
        retained.children = self.children;
        retained.captured_scope = self.captured_scope;
        retained.capture_arena.deinit();
        retained.capture_arena = self.capture_arena;
        retained.table = self.table;
        retained.wire = self.wire;
        retained.roster = self.roster;
        retained.roster_revision = self.roster_revision;
        retained.policy = self.policy;
        retained.policy_revision = self.policy_revision;
        retained.shared_history = self.shared_history orelse &self.owned_history;
        retained.stopped.store(self.stopped.load(.acquire), .release);
        self.children = .empty;
        self.capture_arena = .init(self.allocator);
        self.captured_scope = null;
        self.table = null;
        self.wire = &.{};
        self.host_binding = null;
        self.roster = null;
        self.pending_binding = null;
        self.queries_only = true;
    }
    fn reapRetired(self: *Bridge) void {
        var index: usize = 0;
        while (index < self.retired.items.len) {
            const retained = self.retired.items[index];
            retained.clear() catch {
                index += 1;
                continue;
            };
            retained.deinit();
            self.allocator.destroy(retained);
            _ = self.retired.orderedRemove(index);
        }
    }
    pub fn prepare(self: *Bridge, app: *Application.ApplicationHost, owner: identity.SessionHandle) !void {
        // Scope IDs select a directory entry; they cannot refresh a stale
        // caller's generation into the replacement session's authority.
        for (app.workspace.tabs.items) |tab| {
            if (tab.content_owner == .session and tab.content_owner.session.eql(owner)) break;
        } else return error.StaleSession;
        var captured: scope.Scope = .{ .owner = .{ .session = @backingInt(owner.session_id) }, .members = .{} };
        captured.members.ids[0] = @backingInt(owner.session_id);
        captured.members.len = 1;
        try self.prepareScope(app, captured);
    }
    pub fn prepareGroup(self: *Bridge, app: *Application.ApplicationHost, roster: *@import("group_model.zig").Roster, captured: scope.Scope) !void {
        if (captured.owner != .group) return error.InvalidGroupOwner;
        const group = roster.findById(std.math.cast(u32, captured.owner.group) orelse return error.UnknownGroup) orelse return error.UnknownGroup;
        self.roster = roster;
        self.roster_revision = group.membership_revision;
        try self.prepareScope(app, captured);
    }
    fn prepareScope(self: *Bridge, app: *Application.ApplicationHost, input: scope.Scope) !void {
        if (self.captured_scope != null or self.pending != null or self.controller != null) return error.ToolCleanupPending;
        const captured = try input.clone(self.capture_arena.allocator());
        self.shared_history = &app.domain.operation_history;
        self.captured_scope = captured;
        self.stopped.store(false, .release);
        errdefer self.clear() catch {};
        var definitions: std.ArrayList(tools.ToolDefinition) = .empty;
        defer definitions.deinit(self.allocator);
        var members: std.ArrayList(tools.Member) = .empty;
        defer members.deinit(self.allocator);
        for (captured.memberIds()) |id| {
            if (self.queries_only) break;
            const owner = for (app.workspace.tabs.items) |tab| {
                if (tab.content_owner == .session and @backingInt(tab.content_owner.session.session_id) == id) break tab.content_owner.session;
            } else return error.StaleSession;
            const manifest = app.sessions.manifestFor(owner) orelse return error.AdapterNotConnected;
            if (!manifest.integration.ai) continue;
            // Metadata authority is independent of terminal service readiness.
            // A failed/opening session remains in the real captured scope but
            // contributes no executable target until its services are ready.
            const bindings = app.sessions.typedBindingsFor(owner) orelse continue;
            const child = try self.allocator.create(Child);
            child.* = .{ .owner = owner, .member = .{ .owner = owner, .plugin_id = manifest.id, .context = manifest.session_factory.?.context, .bindings = manifest.tools, .services = bindings, .capability_revision = app.sessions.capabilityRevisionFor(owner) orelse 0, .policy_revision = self.policy_revision } };
            self.children.append(self.allocator, child) catch |err| {
                self.allocator.destroy(child);
                return err;
            };
            try child.live_services.appendSlice(self.allocator, bindings);
            child.member.services = child.live_services.items;
            if (manifest.ai_adapter_factory) |factory| {
                child.adapter = try factory(self.allocator);
                const adapter = child.adapter.?;
                adapter.vtable.delegate(adapter.context, if (captured.owner == .group) captured.owner else null);
                adapter.vtable.files(adapter.context, if (self.files) |files| files else null);
                adapter.vtable.prepare(adapter.context, app, owner) catch |err| switch (err) {
                    error.ServiceUnavailable, error.AdapterNotConnected, error.RequiredServiceUnavailable, error.WorkerBusy => {
                        // A fresh adapter has dispatched no operation. Keep it
                        // owned if even this failed preparation cannot release.
                        try adapter.vtable.clear(adapter.context);
                        adapter.vtable.destroy(adapter.context, self.allocator);
                        child.live_services.deinit(self.allocator);
                        self.allocator.destroy(child);
                        _ = self.children.pop();
                        continue;
                    },
                    else => return err,
                };
                child.invocation_context = .{ .host = adapter.vtable.interface(adapter.context), .captured_scope = captured, .policy_revision = self.policy_revision };
                child.member.context = &child.invocation_context;
            }
            for (manifest.tool_definitions) |definition| {
                var found = false;
                for (definitions.items) |existing| if (std.mem.eql(u8, existing.id, definition.id)) {
                    if (!tools.sameDefinition(existing, definition)) return error.ToolDefinitionConflict;
                    found = true;
                    break;
                };
                if (!found) try definitions.append(self.allocator, definition);
            }
            try members.append(self.allocator, child.member);
        }
        self.table = if (self.host_binding) |binding| try tools.RequestTable.initWithHost(self.allocator, captured, definitions.items, members.items, binding.context, binding.contributions) else try tools.RequestTable.init(self.allocator, captured, definitions.items, members.items);
        self.wire = try tools.providerDefinitions(&self.table.?, self.table.?.arena.allocator());
    }
    pub fn requestTable(self: *Bridge) ?*const tools.RequestTable {
        return if (self.table) |*table| table else null;
    }
    pub fn fill(self: *Bridge, out: []provider.ToolDefinition) !usize {
        if (out.len < self.wire.len) return error.ToolDefinitionCapacity;
        @memcpy(out[0..self.wire.len], self.wire);
        return self.wire.len;
    }
    pub fn toolIds(self: *Bridge, tool: scope.Tool) !scope.Targets {
        var ids: scope.Targets = .{};
        const table = self.requestTable() orelse return ids;
        const entry = table.lookup(@tagName(tool)) orelse return ids;
        if (entry.targets.len > scope.max_targets) return error.TargetProjectionRequired;
        for (entry.targets) |target| {
            ids.ids[ids.len] = @backingInt(target.owner.session_id);
            ids.len += 1;
        }
        return ids;
    }
    pub fn remoteFilesAvailable(self: *Bridge) bool {
        const table = self.requestTable() orelse return false;
        const entry = table.lookup("read_remote_file") orelse return false;
        return entry.targets.len != 0;
    }
    pub fn interface(self: *Bridge) loop.Host {
        return .{ .context = self, .execute = unsupportedLegacy, .execute_dynamic = executeDynamic, .execute_host = executeHost, .refresh_authority = refreshAuthority, .acknowledge_notice = acknowledgeNotice, .accepted_host_result = acceptedResult };
    }
    fn refreshAuthority(raw: *anyopaque, table: *const tools.RequestTable, allocator: std.mem.Allocator, cancel: ?*provider.CancelToken) !?loop.AuthorityRefresh {
        const self: *Bridge = @ptrCast(@alignCast(raw));
        const binding = self.host_binding orelse return null;
        const refresh_fn = binding.refresh orelse return null;
        return refresh_fn(binding.handler_context, self, table, allocator, cancel);
    }
    fn acknowledgeNotice(raw: *anyopaque, revision: u64) !void {
        const self: *Bridge = @ptrCast(@alignCast(raw));
        const binding = self.host_binding orelse return;
        if (binding.acknowledge_notice) |acknowledge| try acknowledge(binding.handler_context, revision);
    }
    fn acceptedResult(raw: *anyopaque, context: host_tools.Context, name: []const u8, result: *const host_tools.Result) !void {
        const self: *Bridge = @ptrCast(@alignCast(raw));
        const binding = self.host_binding orelse return;
        if (binding.accepted_result) |accepted| try accepted(binding.handler_context, context, name, result);
    }
    /// The participant worker is parked at a round boundary. Replace only
    /// prepared resources; retain its mutex, mailboxes and controller exchange.
    pub fn replacePrepared(self: *Bridge, next: *Bridge) !void {
        if (self.pending != null or self.controller != null or self.host_exchange != null or self.running != null) return error.ToolCleanupPending;
        const preserve_queries_only = self.queries_only;
        self.clearPrepared() catch |err| {
            if (err != error.ToolCleanupPending) return err;
            try self.retainPrepared();
            try next.restrictToHostQueries();
        };
        if ((preserve_queries_only or self.retired.items.len != 0) and !next.queries_only) try next.restrictToHostQueries();
        self.children.deinit(self.allocator);
        self.capture_arena.deinit();
        self.lock();
        self.children = next.children;
        next.children = .empty;
        self.table = next.table;
        next.table = null;
        self.wire = next.wire;
        next.wire = &.{};
        self.captured_scope = next.captured_scope;
        next.captured_scope = null;
        self.capture_arena = next.capture_arena;
        next.capture_arena = .init(next.allocator);
        self.roster = next.roster;
        self.roster_revision = next.roster_revision;
        self.policy = next.policy;
        self.execution_mode = next.execution_mode;
        self.policy_revision = next.policy_revision;
        self.shared_history = next.shared_history;
        self.host_binding = next.host_binding;
        next.host_binding = null;
        self.queries_only = next.queries_only;
        self.pending_binding = null;
        self.mutex.unlock();
    }
    fn restrictToHostQueries(self: *Bridge) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const captured = try (self.captured_scope orelse return error.AssistantOwnerChanged).clone(arena.allocator());
        const roster = self.roster;
        const revision = self.roster_revision;
        var binding = self.host_binding orelse return error.InvalidHostAuthority;
        try self.clearPrepared();
        self.queries_only = true;
        binding.contributions = &@import("../ai/host_queries.zig").contributions;
        self.host_binding = binding;
        self.captured_scope = try captured.clone(self.capture_arena.allocator());
        self.roster = roster;
        self.roster_revision = revision;
        self.table = try tools.RequestTable.initWithHost(self.allocator, self.captured_scope.?, &.{}, &.{}, binding.context, binding.contributions);
        self.wire = try tools.providerDefinitions(&self.table.?, self.table.?.arena.allocator());
    }
    fn executeHost(raw: *anyopaque, invocation: host_tools.Invocation, allocator: std.mem.Allocator, cancel: ?*provider.CancelToken) !host_tools.Result {
        const self: *Bridge = @ptrCast(@alignCast(raw));
        self.emitHostStep(invocation, .running, "");
        const result = self.dispatchHost(invocation, allocator, cancel) catch |err| {
            self.emitHostStep(invocation, if (err == error.CancelledBeforeDispatch) .cancelled else .failed, @errorName(err));
            return err;
        };
        self.emitHostStep(invocation, switch (result.status) {
            .succeeded => .succeeded,
            .rejected => .rejected,
            .cancelled_unsent => .cancelled,
            else => .failed,
        }, "");
        return result;
    }
    fn dispatchHost(self: *Bridge, invocation: host_tools.Invocation, allocator: std.mem.Allocator, cancel: ?*provider.CancelToken) !host_tools.Result {
        self.lock();
        const binding = self.host_binding;
        const stopped = self.stopped.load(.acquire);
        self.mutex.unlock();
        const current = binding orelse return error.ToolNotAvailable;
        if (stopped or !current.context.eql(invocation.context)) return error.ScopeChanged;
        if (self.queries_only and !@import("../ai/host_queries.zig").supports(invocation.tool_id)) return error.ToolNotAvailable;
        if (current.invoke_worker) |worker_fn| return worker_fn(current.handler_context, self, invocation, allocator, cancel);
        return self.exchangeHost(invocation, allocator, cancel);
    }
    pub fn queryHost(self: *Bridge, invocation: host_tools.Invocation, allocator: std.mem.Allocator, cancel: ?*provider.CancelToken) !host_tools.Result {
        return self.exchangeHost(invocation, allocator, cancel);
    }
    /// A busy lock or a live mailbox cannot prove Task resource settlement.
    pub fn quiescent(self: *Bridge) ?bool {
        if (!self.mutex.tryLock()) return null;
        defer self.mutex.unlock();
        return self.pending == null and self.controller == null and self.running == null and self.host_exchange == null and self.controller_task == null;
    }
    /// A tool worker may ask for a bounded controller operation, but callbacks
    /// only validate/prepare/commit/enqueue; they must never join that worker.
    pub fn callController(self: *Bridge, context: *anyopaque, invoke_fn: *const fn (*anyopaque) anyerror!void, cancel: ?*provider.CancelToken) !void {
        var task: ControllerTask = .{ .context = context, .invoke = invoke_fn };
        self.lock();
        if (self.controller_task != null or self.stopped.load(.acquire)) {
            self.mutex.unlock();
            return error.CancelledBeforeDispatch;
        }
        self.controller_task = &task;
        self.mutex.unlock();
        defer {
            self.lock();
            self.controller_task = null;
            self.mutex.unlock();
        }
        while (true) {
            self.lock();
            if (task.ready) {
                self.mutex.unlock();
                break;
            }
            if (!task.processing and (self.stopped.load(.acquire) or (if (cancel) |value| value.isCancelled() else false))) {
                self.mutex.unlock();
                return error.CancelledBeforeDispatch;
            }
            self.mutex.unlock();
            pause();
        }
        if (task.failure) |err| return err;
    }
    fn pumpControllerTask(self: *Bridge) void {
        self.lock();
        const task = self.controller_task orelse {
            self.mutex.unlock();
            return;
        };
        if (task.ready or task.processing) {
            self.mutex.unlock();
            return;
        }
        task.processing = true;
        self.mutex.unlock();
        const result = task.invoke(task.context);
        self.lock();
        if (result) |_| {} else |err| task.failure = err;
        task.ready = true;
        self.mutex.unlock();
    }
    pub fn bindingChanged(self: *Bridge, owner: scope.Owner) void {
        self.lock();
        self.pending_binding = owner;
        self.mutex.unlock();
    }
    fn emitHostStep(self: *Bridge, invocation: host_tools.Invocation, phase: @import("../ai/step_events.zig").Phase, detail: []const u8) void {
        const events = self.events orelse return;
        events.push(.{ .call_id = invocation.call_id, .name = invocation.tool_id, .command = invocation.arguments_json, .detail = detail, .phase = phase, .at_ms = @intCast(timeNow(self)) }) catch {};
    }
    fn exchangeHost(self: *Bridge, invocation: host_tools.Invocation, allocator: std.mem.Allocator, cancel: ?*provider.CancelToken) !host_tools.Result {
        var exchange: HostExchange = .{ .invocation = invocation, .allocator = allocator, .cancel = cancel };
        self.lock();
        const binding = self.host_binding orelse {
            self.mutex.unlock();
            return error.ToolNotAvailable;
        };
        if (self.host_exchange != null or self.stopped.load(.acquire) or !binding.context.eql(invocation.context)) {
            self.mutex.unlock();
            return error.ScopeChanged;
        }
        self.host_exchange = &exchange;
        self.mutex.unlock();
        defer {
            self.lock();
            self.host_exchange = null;
            self.mutex.unlock();
        }
        while (true) {
            self.lock();
            if (exchange.ready) {
                self.mutex.unlock();
                break;
            }
            if (!exchange.processing and (self.stopped.load(.acquire) or (if (cancel) |token| token.isCancelled() else false))) {
                self.mutex.unlock();
                return error.CancelledBeforeDispatch;
            }
            self.mutex.unlock();
            pause();
        }
        if (exchange.failure) |err| return err;
        return exchange.result orelse error.ToolOutcomeUnknown;
    }
    fn pumpHost(self: *Bridge) void {
        self.lock();
        const current = self.host_exchange orelse {
            self.mutex.unlock();
            return;
        };
        if (current.ready or current.processing) {
            self.mutex.unlock();
            return;
        }
        const binding = self.host_binding orelse {
            current.failure = error.ScopeChanged;
            current.ready = true;
            self.mutex.unlock();
            return;
        };
        if (self.stopped.load(.acquire) or (if (current.cancel) |token| token.isCancelled() else false) or !binding.context.eql(current.invocation.context)) {
            current.failure = error.CancelledBeforeDispatch;
            current.ready = true;
            self.mutex.unlock();
            return;
        }
        current.processing = true;
        self.mutex.unlock();
        // A controller callback must never run while the worker's exchange
        // mutex is held. Read-only callbacks cannot stop/join this worker.
        const result = binding.invoke(binding.handler_context, current.invocation, current.allocator);
        self.lock();
        if (result) |value| current.result = value else |err| current.failure = err;
        current.ready = true;
        self.mutex.unlock();
    }
    fn unsupportedLegacy(_: *anyopaque, _: loop.Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !loop.Outcome {
        return error.ToolNotInRequest;
    }
    fn executeDynamic(raw: *anyopaque, invocation: tools.DynamicInvocation, allocator: std.mem.Allocator, cancel: ?*provider.CancelToken) ![]tools.ToolResult {
        const self: *Bridge = @ptrCast(@alignCast(raw));
        if (self.queries_only) return error.ToolNotAvailable;
        if (self.route_broker == null and std.mem.eql(u8, invocation.parsed.entry.definition.id, "run_command") and (self.execution_mode == .attached_pty or self.execution_mode == .new_pty)) return error.ModeConflict;
        _ = self.validation_arena.reset(.retain_capacity);
        self.lock();
        self.running = invocation;
        self.mutex.unlock();
        defer {
            self.lock();
            self.running = null;
            self.mutex.unlock();
        }
        for (self.children.items) |child| child.invocation_context.cancel = cancel;
        self.emitStep(invocation, .assembling, "");
        var route_subject: approvals.Subject = undefined;
        var route_label: [128]u8 = undefined;
        var route_invocation: host_tools.Invocation = undefined;
        var route_permit: ?approvals.Permit = null;
        defer {
            self.active_route = null;
            if (route_permit) |permit| self.route_broker.?.finish(permit);
        }
        const batch_command = std.mem.eql(u8, invocation.parsed.entry.definition.id, "run_command");
        if (batch_command and self.route_broker != null) {
            // Complete target/capability and forbidden preflight before showing
            // a route card. An approval never makes a blocked command legal.
            try tools.preflight(invocation.table, invocation.parsed, try liveScope(self), try liveMembers(self));
            _ = try tools.callNeedsApproval(invocation.parsed, self.policy, invocation.table.captured_scope.owner == .group);
            if (invocation.parsed.targets.len != 1) {
                if (self.execution_mode == .ask) return error.TargetSelectionRequired;
            } else {
                const id = invocation.parsed.targets.slice()[0];
                const target = for (invocation.parsed.entry.targets) |entry| {
                    if (@backingInt(entry.owner.session_id) == id) break entry.owner;
                } else return error.ToolCapabilityUnavailable;
                const command_value = invocation.parsed.json.value.object.get("command") orelse return error.InvalidToolArguments;
                if (command_value != .string) return error.InvalidToolArguments;
                const binding = self.host_binding orelse return error.InvalidHostAuthority;
                route_invocation = .{ .context = binding.context, .authority = .execution_control, .operation_id = invocation.operation_id, .turn_id = invocation.turn_id, .call_id = invocation.call_id, .tool_id = "run_command", .arguments = invocation.parsed.json.value, .arguments_json = invocation.arguments, .arguments_hash = invocation.parsed.arguments_hash, .canonical_arguments_hash = try @import("../ai/canonical_arguments.zig").digest(allocator, invocation.parsed.json.value) };
                route_subject = .{ .kind = .terminal_command, .target = try std.fmt.bufPrint(&route_label, "会话 #{d} · generation {d}", .{ @backingInt(target.session_id), target.generation }), .detail = command_value.string, .impact = "仅执行上述完整命令。新工作终端将以此会话为来源，创建步骤需精确确认；保留按本次任务策略。" };
                if (try self.prepareHostRoute(route_invocation, &route_subject, target, .batch, allocator)) |changed| return try dynamicRouteResult(invocation, target, changed, allocator);
                if (self.execution_mode == .ask or route_subject.route.?.choice.route == .batch and self.route_broker.?.execution_route.resolve(binding.context, target, command_value.string, .batch).trusted) {
                    const permit = try self.requestHostRoute(route_invocation, route_subject, allocator, cancel);
                    route_permit = permit;
                    if (try self.hostRouteChange(route_invocation, route_subject, permit, allocator)) |changed| return try dynamicRouteResult(invocation, target, changed, allocator);
                    self.active_route = .{ .permit = permit, .invocation = route_invocation, .subject = route_subject };
                }
            }
        }
        const runtime: tools.Runtime = .{ .context = self, .live_scope = liveScope, .live_members = liveMembers, .current_policy = currentPolicy, .now_ms = timeNow, .approval = askApproval, .operations = self.operationHistory(), .invoke = invoke };
        if (route_permit != null) {
            const target = route_subject.route.?.target;
            self.consumeHostRoute(route_invocation, target, route_subject.detail);
        }
        const results = runtime.execute(invocation, allocator, cancel) catch |err| {
            self.emitStep(invocation, if (err == error.CancelledBeforeDispatch or (if (cancel) |token| token.isCancelled() else false)) .cancelled else .failed, @errorName(err));
            return err;
        };
        var detail: std.ArrayList(u8) = .empty;
        defer detail.deinit(allocator);
        var phase: @import("../ai/step_events.zig").Phase = .succeeded;
        for (results) |result| {
            if (result.status != .succeeded) phase = if (result.status == .rejected) .rejected else if (result.status == .cancelled_unsent) .cancelled else .failed;
            const label = std.fmt.allocPrint(allocator, "#{d} · {s}\n", .{ @backingInt(result.receipt.owner.session_id), @tagName(result.status) }) catch "";
            defer if (label.len != 0) allocator.free(label);
            detail.appendSlice(allocator, label) catch {};
            for (result.blocks) |block| switch (block) {
                .text, .structured => |bytes| {
                    detail.appendSlice(allocator, bytes) catch {};
                    detail.append(allocator, '\n') catch {};
                },
                else => {},
            };
        }
        self.emitStep(invocation, phase, detail.items);
        return results;
    }
    fn dynamicRouteResult(invocation: tools.DynamicInvocation, target: identity.SessionHandle, changed: host_tools.Result, allocator: std.mem.Allocator) ![]tools.ToolResult {
        var owned = changed;
        defer owned.deinit(allocator);
        const blocks = try allocator.alloc(tools.ContentBlock, changed.blocks.len);
        errdefer allocator.free(blocks);
        for (changed.blocks, blocks) |block, *output| output.* = switch (block) {
            .structured => |value| .{ .structured = try allocator.dupe(u8, value) },
            .text => |value| .{ .text = try allocator.dupe(u8, value) },
        };
        const results = try allocator.alloc(tools.ToolResult, 1);
        results[0] = .{ .status = .cancelled_unsent, .blocks = blocks, .receipt = .{ .owner = target, .operation_id = invocation.operation_id } };
        return results;
    }
    fn emitStep(self: *Bridge, invocation: tools.DynamicInvocation, phase: @import("../ai/step_events.zig").Phase, detail: []const u8) void {
        const events = self.events orelse return;
        const name = invocation.parsed.entry.definition.id;
        const args = invocation.parsed.json.value;
        const command = if (args == .object) blk: {
            for ([_][]const u8{ "command", "path" }) |key| if (args.object.get(key)) |value| if (value == .string) break :blk value.string;
            break :blk invocation.arguments;
        } else invocation.arguments;
        events.push(.{ .call_id = invocation.call_id, .name = name, .command = command, .detail = detail, .phase = phase, .at_ms = @intCast(timeNow(self)) }) catch {};
    }
    fn liveScope(raw: *anyopaque) !scope.Scope {
        const self: *Bridge = @ptrCast(@alignCast(raw));
        if (self.stopped.load(.acquire)) return error.CancelledBeforeDispatch;
        self.lock();
        defer self.mutex.unlock();
        var captured = self.captured_scope orelse return error.AssistantOwnerChanged;
        if (self.pending_binding) |owner| captured.owner = owner;
        return captured;
    }
    fn liveMembers(raw: *anyopaque) ![]const tools.Member {
        const self: *Bridge = @ptrCast(@alignCast(raw));
        self.lock();
        defer self.mutex.unlock();
        const a = self.validation_arena.allocator();
        const members = try a.alloc(tools.Member, self.children.items.len);
        for (self.children.items, members) |child, *member| {
            member.* = child.member;
            member.services = try a.dupe(typed.Binding, child.member.services);
        }
        return members;
    }
    fn currentPolicy(raw: *anyopaque) tools.Policy {
        return @as(*Bridge, @ptrCast(@alignCast(raw))).policy;
    }
    fn timeNow(_: *anyopaque) i64 {
        return @intCast(@divTrunc(@import("../platform/realtime.zig").monotonicNs(), std.time.ns_per_ms));
    }
    fn askApproval(raw: *anyopaque, invocation: tools.DynamicInvocation, ticket: *tools.ApprovalTicket, cancel: ?*provider.CancelToken) !bool {
        const self: *Bridge = @ptrCast(@alignCast(raw));
        if (self.active_route) |route| {
            if (!std.mem.eql(u8, &ticket.arguments_hash, &route.invocation.arguments_hash)) return error.StaleApproval;
            if (self.route_broker.?.authorizeSubject(route.permit, route.invocation, route.subject, self.policy_revision) != .allow) return error.ScopeChanged;
            return true;
        }
        self.lock();
        if (self.pending != null or self.stopped.load(.acquire)) {
            self.mutex.unlock();
            return error.CancelledBeforeDispatch;
        }
        self.sequence = try identity.advance(self.sequence +| @intFromBool(self.sequence == 0));
        var exchange: ApprovalExchange = .{ .invocation = invocation, .ticket = ticket, .sequence = self.sequence };
        self.pending = &exchange;
        self.emitStep(invocation, .approval, "等待用户确认");
        @import("../ai/tool_trace.zig").emit(.{ .event = "dynamic_approval_pending", .call_id = invocation.call_id, .tool_id = invocation.parsed.entry.definition.id, .owner = invocation.table.captured_scope.owner, .sequence = exchange.sequence, .arguments_hash = std.fmt.bytesToHex(ticket.arguments_hash, .lower), .expires_at_ms = ticket.expires_at_ms });
        self.mutex.unlock();
        defer {
            self.lock();
            self.pending = null;
            self.mutex.unlock();
        }
        while (true) {
            self.lock();
            const decision = exchange.decision;
            self.mutex.unlock();
            if (self.stopped.load(.acquire) or (if (cancel) |token| token.isCancelled() else false)) return error.CancelledBeforeDispatch;
            if (timeNow(self) >= ticket.expires_at_ms) return error.ToolApprovalExpired;
            switch (decision) {
                .approved => return true,
                .rejected => return false,
                .pending => pause(),
            }
        }
    }
    pub fn pendingApproval(self: *Bridge) ?Approval {
        self.lock();
        defer self.mutex.unlock();
        const current = self.pending orelse return null;
        if (current.decision != .pending or self.stopped.load(.acquire)) return null;
        const group = current.invocation.table.captured_scope.owner == .group;
        var target_writer: std.Io.Writer = .fixed(&self.approval_target);
        for (current.ticket.targets[0..current.ticket.len], 0..) |target, index| {
            var label: []const u8 = "会话";
            for (self.children.items) |child| if (child.owner.eql(target.owner)) {
                label = if (child.adapter) |adapter| adapter.vtable.label(adapter.context) else child.member.plugin_id;
                break;
            };
            if (index != 0) target_writer.writeAll("、") catch {};
            target_writer.writeAll(label) catch {};
            if (group) target_writer.print(" · #{d}", .{@backingInt(target.owner.session_id)}) catch {};
        }
        const tool_id = current.invocation.parsed.entry.definition.id;
        const arguments = current.invocation.parsed.json.value;
        const command = if (std.mem.eql(u8, tool_id, "run_command") and arguments == .object) blk: {
            const value = arguments.object.get("command") orelse break :blk current.invocation.arguments;
            break :blk if (value == .string) value.string else current.invocation.arguments;
        } else current.invocation.arguments;
        return .{ .group = group, .target = target_writer.buffered(), .tool_id = tool_id, .owner = current.ticket.targets[0].owner, .cwd = null, .sequence = current.sequence, .arguments_hash = current.invocation.parsed.arguments_hash, .command = command, .call_id = current.invocation.call_id };
    }
    pub fn decide(self: *Bridge, sequence: u64, hash: [32]u8, approved: bool) !void {
        self.lock();
        defer self.mutex.unlock();
        const current = self.pending orelse return error.StaleApproval;
        if (current.sequence != sequence or current.decision != .pending or !std.mem.eql(u8, &hash, &current.ticket.arguments_hash) or timeNow(self) >= current.ticket.expires_at_ms or self.stopped.load(.acquire)) return error.StaleApproval;
        current.decision = if (approved) .approved else .rejected;
        self.emitStep(current.invocation, if (approved) .approved else .rejected, if (approved) "用户已批准" else "用户已拒绝");
        @import("../ai/tool_trace.zig").emit(.{ .event = "dynamic_approval_decision", .call_id = current.invocation.call_id, .tool_id = current.invocation.parsed.entry.definition.id, .sequence = sequence, .approved = approved, .arguments_hash = std.fmt.bytesToHex(hash, .lower) });
    }
    fn invoke(raw: *anyopaque, target: tools.TargetBinding, request: tools.Invocation, allocator: std.mem.Allocator, cancel: ?*provider.CancelToken) !tools.ToolResult {
        const self: *Bridge = @ptrCast(@alignCast(raw));
        if (target.binding.execution == .worker) {
            if (self.stopped.load(.acquire) or (if (cancel) |token| token.isCancelled() else false)) return error.CancelledBeforeDispatch;
            try tools.markSent(self.operationHistory(), request.owner, request.operation_id, request.call_id, request.tool_id, request.arguments_hash);
            if (self.stopped.load(.acquire) or (if (cancel) |token| token.isCancelled() else false)) return error.CancelledBeforeDispatch;
            if (self.running) |running| self.emitStep(running, .running, "");
            return target.binding.handler(target.context, request, allocator);
        }
        var exchange: ControllerExchange = .{ .target = target, .invocation = request, .allocator = allocator, .cancel = cancel };
        self.lock();
        if (self.controller != null or self.stopped.load(.acquire)) {
            self.mutex.unlock();
            return error.CancelledBeforeDispatch;
        }
        self.controller = &exchange;
        self.mutex.unlock();
        defer {
            self.lock();
            self.controller = null;
            self.mutex.unlock();
        }
        while (!exchange.ready.load(.acquire)) pause();
        if (exchange.failure) |err| return err;
        return exchange.result orelse error.ToolOutcomeUnknown;
    }
    pub fn pump(self: *Bridge, app: *Application.ApplicationHost) void {
        self.lock();
        var roster_valid = true;
        if (self.roster) |roster| if (self.captured_scope) |captured| {
            const group = roster.findById(@intCast(captured.owner.group));
            roster_valid = if (group) |value| value.membership_revision == self.roster_revision else false;
        };
        for (self.children.items) |child| {
            const current = app.sessions.typedBindingsFor(child.owner);
            child.member.authorized = roster_valid and current != null and app.legacyForHandle(child.owner) != null;
            child.member.capability_revision = app.sessions.capabilityRevisionFor(child.owner) orelse 0;
            child.member.policy_revision = app.workspace.app_config.config_revision;
            child.live_services.clearRetainingCapacity();
            if (current) |bindings| child.live_services.appendSlice(self.allocator, bindings) catch {
                child.member.authorized = false;
            };
            child.member.services = child.live_services.items;
        }
        if (self.controller) |current| if (!current.ready.load(.acquire)) {
            if (self.stopped.load(.acquire) or (if (current.cancel) |token| token.isCancelled() else false)) current.failure = error.CancelledBeforeDispatch else {
                // Controller effects recheck the current owner and full group
                // authority in the immediately preceding runtime preflight.
                const live_members = self.allocator.alloc(tools.Member, self.children.items.len) catch {
                    current.failure = error.OutOfMemory;
                    current.ready.store(true, .release);
                    self.mutex.unlock();
                    return;
                };
                defer self.allocator.free(live_members);
                for (self.children.items, 0..) |child, index| live_members[index] = child.member;
                const running = self.running orelse {
                    current.failure = error.ToolOperationAlreadyRecorded;
                    current.ready.store(true, .release);
                    self.mutex.unlock();
                    return;
                };
                tools.preflight(running.table, running.parsed, self.captured_scope.?, live_members[0..self.children.items.len]) catch |err| {
                    current.failure = err;
                    current.ready.store(true, .release);
                    self.mutex.unlock();
                    return;
                };
                if (current.invocation.effect == .remote_input) {
                    @import("plugin_window_host.zig").Host.authorizeInput(app, current.invocation.owner, true, self.policy_revision) catch |err| {
                        current.failure = err;
                        current.ready.store(true, .release);
                        self.mutex.unlock();
                        return;
                    };
                }
                defer if (current.invocation.effect == .remote_input) {
                    @import("plugin_window_host.zig").Host.authorizeInput(app, current.invocation.owner, false, self.policy_revision) catch {};
                };
                tools.markSent(self.operationHistory(), current.invocation.owner, current.invocation.operation_id, current.invocation.call_id, current.invocation.tool_id, current.invocation.arguments_hash) catch |err| {
                    current.failure = err;
                    current.ready.store(true, .release);
                    self.mutex.unlock();
                    return;
                };
                self.emitStep(running, .running, "");
                current.result = current.target.binding.handler(current.target.context, current.invocation, current.allocator) catch |err| blk: {
                    current.failure = err;
                    break :blk null;
                };
            }
            current.ready.store(true, .release);
        };
        self.mutex.unlock();
        self.pumpHost();
        self.pumpControllerTask();
        for (self.children.items) |child| if (child.adapter) |adapter| {
            if (self.stopped.load(.acquire) or !child.member.authorized or child.member.policy_revision != self.policy_revision) _ = adapter.vtable.stop(adapter.context, child.owner);
            adapter.vtable.pump(adapter.context, app);
        };
        for (self.retired.items) |retained| retained.pump(app);
        self.reapRetired();
    }
    pub fn sourceOwner(self: *Bridge, id: u64) ?identity.SessionHandle {
        for (self.children.items) |child| if (@backingInt(child.owner.session_id) == id) return child.owner;
        return null;
    }
    pub fn resultSources(self: *Bridge, allocator: std.mem.Allocator) ![]const @import("../ai/tool_results.zig").Source {
        const out = try allocator.alloc(@import("../ai/tool_results.zig").Source, self.children.items.len);
        for (self.children.items, 0..) |child, i| out[i] = .{ .owner = child.owner, .label = if (child.adapter) |adapter| adapter.vtable.label(adapter.context) else child.member.plugin_id };
        return out[0..self.children.items.len];
    }
    pub fn stopAll(self: *Bridge) void {
        for (self.children.items) |child| _ = self.stopOwner(child.owner);
        for (self.retired.items) |retained| retained.stopAll();
    }
    pub fn writeRisk(self: *Bridge, owner: identity.SessionHandle) bool {
        for (self.retired.items) |retained| if (retained.writeRisk(owner)) return true;
        for (self.children.items) |child| if (child.owner.eql(owner)) if (child.adapter) |adapter| if (adapter.vtable.risk(adapter.context, owner)) return true;
        self.lock();
        defer self.mutex.unlock();
        if (self.pending) |pending| for (pending.invocation.parsed.targets.slice()) |id| if (id == @backingInt(owner.session_id)) return true;
        return false;
    }
    pub fn closeImpact(self: *Bridge, owner: identity.SessionHandle) @import("group_close_controller.zig").Impact {
        var result: @import("group_close_controller.zig").Impact = .{};
        for (self.children.items) |child| if (child.owner.eql(owner)) if (child.adapter) |adapter| {
            mergeImpact(&result, adapter.vtable.impact(adapter.context, owner));
        };
        for (self.retired.items) |retained| mergeImpact(&result, retained.closeImpact(owner));
        result.ai = @max(result.ai, @intFromBool(self.writeRisk(owner)));
        return result;
    }
    fn mergeImpact(result: *@import("group_close_controller.zig").Impact, value: @import("group_close_controller.zig").Impact) void {
        result.command +|= value.command;
        result.transfer +|= value.transfer;
        result.ai +|= value.ai;
        result.socks +|= value.socks;
        result.unknown +|= value.unknown;
        result.remote_effect_unknown = result.remote_effect_unknown or value.remote_effect_unknown;
        if (result.detail_len == 0) result.setDetail(value.detailText());
    }
    pub fn stopOwner(self: *Bridge, owner: identity.SessionHandle) Application.CloseReceipt {
        var receipt: Application.CloseReceipt = .released;
        for (self.children.items) |child| if (child.owner.eql(owner)) {
            // Closing one member releases that member's authority. The group
            // conversation and unrelated tools keep their original Task.
            if (self.captured_scope) |captured| if (captured.owner == .session and captured.owner.session == @backingInt(owner.session_id)) self.stopped.store(true, .release);
            child.member.authorized = false;
            self.cancelOwnHistory(owner);
            if (child.adapter) |adapter| receipt = adapter.vtable.stop(adapter.context, owner);
        };
        for (self.retired.items) |retained| {
            const current = retained.stopOwner(owner);
            if (current == .unknown or current == .awaiting and receipt == .released) receipt = current;
        }
        return receipt;
    }
    pub fn stopGroup(self: *Bridge, group_id: u64) Application.CloseReceipt {
        var receipt: Application.CloseReceipt = .released;
        if (self.captured_scope) |captured| if (captured.owner == .group and captured.owner.group == group_id) {
            self.stopped.store(true, .release);
            for (self.children.items) |child| {
                const current = self.stopOwner(child.owner);
                if (current == .unknown or current == .awaiting and receipt == .released) receipt = current;
            }
        };
        for (self.retired.items) |retained| {
            const current = retained.stopGroup(group_id);
            if (current == .unknown or current == .awaiting and receipt == .released) receipt = current;
        }
        return receipt;
    }
    pub fn shutdown(self: *Bridge, app: ?*Application.ApplicationHost) void {
        self.stopped.store(true, .release);
        for (self.children.items) |child| {
            self.cancelOwnHistory(child.owner);
            if (child.adapter) |adapter| adapter.vtable.shutdown(adapter.context, if (app) |host| host else null);
        }
        for (self.retired.items) |retained| retained.shutdown(app);
    }
    fn cancelOwnHistory(self: *Bridge, owner: identity.SessionHandle) void {
        self.lock();
        const operation_id: ?u64 = if (self.running) |current| blk: {
            for (current.parsed.entry.targets) |target| if (target.owner.eql(owner)) break :blk current.operation_id;
            break :blk null;
        } else null;
        self.mutex.unlock();
        // A window/Bridge stop cancels only its own in-flight operation. The
        // owner may be alive in another window; never mark it globally closed.
        if (operation_id) |id| self.operationHistory().cancel(owner, id) catch {};
    }
    fn clearPrepared(self: *Bridge) !void {
        for (self.children.items) |child| if (child.adapter) |adapter| try adapter.vtable.clear(adapter.context);
        if (self.table) |*table| table.deinit();
        self.table = null;
        self.wire = &.{};
        for (self.children.items) |child| {
            if (child.adapter) |adapter| adapter.vtable.destroy(adapter.context, self.allocator);
            child.live_services.deinit(self.allocator);
            self.allocator.destroy(child);
        }
        self.children.clearRetainingCapacity();
        self.captured_scope = null;
        _ = self.capture_arena.reset(.free_all);
        self.roster = null;
        self.host_binding = null;
        self.pending_binding = null;
    }
    pub fn clear(self: *Bridge) !void {
        if (self.quiescent() != true) return error.ToolCleanupPending;
        try self.clearPrepared();
        self.reapRetired();
        if (self.retired.items.len != 0) return error.ToolCleanupPending;
    }
    pub fn deinit(self: *Bridge) void {
        self.clear() catch unreachable;
        self.children.deinit(self.allocator);
        self.retired.deinit(self.allocator);
        self.owned_history.deinit();
        self.validation_arena.deinit();
        self.capture_arena.deinit();
        self.* = undefined;
    }
};
fn pause() void {
    var duration: std.c.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&duration, null);
}

test "host metadata remains available for opening and failed sessions without terminal targets" {
    const a = std.testing.allocator;
    const Session = @import("../host/session_host.zig");
    const plugins = @import("../host/plugin_registry.zig");
    const queries = @import("../ai/host_queries.zig");
    const Projection = @import("ai_host_queries.zig");
    const Driver = struct {
        creates: usize = 0,
        fn create(raw: *anyopaque, _: Session.CreateRequest) !void {
            (@as(*@This(), @ptrCast(@alignCast(raw)))).creates += 1;
        }
        fn cancel(_: *anyopaque, _: Session.OperationKey) Session.CloseReceipt {
            return .released;
        }
        fn close(_: *anyopaque, _: identity.SessionHandle, _: Session.OperationKey) !Session.CloseReceipt {
            return .released;
        }
        fn stale(_: *anyopaque, _: identity.SessionHandle, _: Session.OperationKey) void {}
        fn query(_: *anyopaque, _: host_tools.Invocation, _: std.mem.Allocator) !host_tools.Result {
            return error.UnexpectedDispatch;
        }
    };
    var driver: Driver = .{};
    const advertised = plugins.requiredServices(.ssh);
    const adapter: Session.Adapter = .{ .registration = .{ .plugin_id = .ssh, .workspace_kind = .terminal, .services = advertised }, .context = &driver, .vtable = &.{ .create = Driver.create, .cancel = Driver.cancel, .close = Driver.close, .release_stale = Driver.stale } };
    var sessions = try Session.SessionHost.init(a, &.{adapter});
    defer sessions.deinit();
    const accepted = try sessions.create(.{ .temporary_ssh = .{ .structured_endpoint = .{ .host = "metadata-fixture.invalid", .user = "fixture" }, .auth_options = .password_prompt } }, .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) });
    var domain: Application.Domain = undefined;
    domain.operation_history = operations.Store.init(a);
    defer domain.operation_history.deinit();
    var config: @import("../config/config.zig").Config = .{};
    var workspace: @import("workspace.zig").Workspace = undefined;
    workspace.app_config = &config;
    workspace.tabs = .empty;
    defer workspace.tabs.deinit(a);
    var tab: @import("workspace.zig").SessionTab = .{ .id = 1, .tab_id = @fromBackingInt(1), .content_owner = .{ .session = accepted.handle }, .host_id = 1, .host_index = 0, .host_snapshot = null, .root = undefined };
    try workspace.tabs.append(a, &tab);
    var app: Application.ApplicationHost = undefined;
    app.workspace = &workspace;
    app.domain = &domain;
    app.sessions = &sessions;
    app.mappings = .empty;
    app.lifecycle_supervisor = Application.lifecycle.Supervisor.init(a);
    defer app.lifecycle_supervisor.deinit();
    // Projection also reads retained close receipts for this exact Task.
    // This partial host intentionally has no accepted close operations.
    app.deferred_closes = .empty;
    var bridge = Bridge.init(a);
    defer bridge.deinit();
    const authority: host_tools.Context = .{ .conversation_id = identity.ConversationId.generate(), .task_id = identity.TaskId.generate(), .binding = .{ .session = @backingInt(accepted.handle.session_id) }, .binding_revision = 1, .grant_revision = 1 };
    var invocation: host_tools.Invocation = .{ .context = authority, .authority = .conversation_context, .operation_id = 1, .turn_id = 1, .call_id = "metadata", .tool_id = "host.list_sessions", .arguments = .{ .object = .empty }, .arguments_json = "{}", .arguments_hash = @splat(0), .canonical_arguments_hash = @splat(0) };
    // This is the production SessionHost state machine with an inert create
    // callback; no SSH transport, terminal reader or credential lookup exists.
    for ([_]bool{ false, true }) |failed| {
        if (failed) {
            try bridge.beginRequest();
            try std.testing.expect(try sessions.failed(accepted.handle, accepted.operation, .{ .domain = .transport, .code = "ConnectionTimedOut", .cleanup = .released, .safe_message = "fixture" }));
            workspace.tabs.items[0].failed = true;
        }
        try bridge.configureHost(.{ .context = authority, .handler_context = &driver, .invoke = Driver.query, .contributions = &queries.contributions });
        try bridge.prepare(&app, accepted.handle);
        const table = bridge.requestTable().?;
        try std.testing.expectEqual(@as(usize, 6), table.entries.len);
        try std.testing.expect(table.lookup("read_terminal") == null);
        try std.testing.expect(table.lookup("run_command") == null);
        try std.testing.expectEqual(@as(usize, 0), bridge.children.items.len);
        for (table.entries) |entry| {
            try std.testing.expect(entry.authority == .conversation_context);
            try std.testing.expectEqual(@as(usize, 0), entry.targets.len);
            try std.testing.expect(std.mem.indexOf(u8, entry.definition.schema, "session_ids") == null);
        }
        var result = try Projection.execute(&app, null, authority.binding, .{ .execution_policy = .{ .execution_mode = .auto, .session_retention = .keep }, .permission_mode = .confirm, .host_contributions = &queries.contributions }, @splat(1), invocation, a);
        defer result.deinit(a);
        try result.validate(authority, 1);
        const body = result.blocks[0].structured;
        try std.testing.expect(std.mem.indexOf(u8, body, if (failed) "\"state\":\"failed\"" else "\"state\":\"creating\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"read_terminal\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"batch_execution\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"trusted_pty_execution\":false") != null);
        var name: [64]u8 = undefined;
        try std.testing.expectError(error.InvalidToolArguments, table.parse(a, try tools.encodeName(&name, "host.get_current_context"), "{\"session_ids\":[1]}"));
    }
    try std.testing.expectError(error.StaleSession, bridge.prepare(&app, try accepted.handle.nextGeneration()));
    // References retain the actual session generation and conversation grant.
    const current_ref = try queries.sessionRef(a, authority, accepted.handle);
    defer a.free(current_ref);
    const snapshot: queries.Snapshot = .{ .context = authority, .initial_binding = authority.binding, .execution_policy = .{ .execution_mode = .auto, .session_retention = .keep }, .permission_mode = .confirm, .observed_at = 1, .source_revision = 1, .cursor_key = @splat(1), .sessions = &.{.{ .handle = try accepted.handle.nextGeneration(), .title = "replacement", .protocol = "ssh", .state = "creating", .ready = false }}, .groups = &.{} };
    try std.testing.expectError(error.StaleReference, queries.resolveSession(snapshot, current_ref));
    invocation.context.task_id = identity.TaskId.generate();
    try std.testing.expectError(error.ScopeChanged, bridge.dispatchHost(invocation, a, null));
    invocation.context = authority;
    invocation.context.grant_revision += 1;
    try std.testing.expectError(error.ScopeChanged, bridge.dispatchHost(invocation, a, null));
    invocation.context = authority;
    invocation.context.binding_revision += 1;
    try std.testing.expectError(error.ScopeChanged, bridge.dispatchHost(invocation, a, null));
    invocation.context = authority;
    invocation.context.conversation_id = identity.ConversationId.generate();
    try std.testing.expectError(error.ScopeChanged, bridge.dispatchHost(invocation, a, null));
    try std.testing.expectEqual(@as(usize, 1), driver.creates);
    // A ready contributed service still publishes its normal terminal target.
    // Replace only the adapter factory with the plugin's native typed handlers;
    // the production readiness and capability-revocation paths remain intact.
    var manifest = sessions.registry.find("ssh").?.*;
    manifest.ai_adapter_factory = null;
    var ready_sessions = try Session.SessionHost.initPlugins(a, &.{manifest}, &.{});
    defer ready_sessions.deinit();
    const ready = try ready_sessions.create(.{ .temporary_ssh = .{ .structured_endpoint = .{ .host = "metadata-fixture.invalid", .user = "fixture" }, .auth_options = .password_prompt } }, .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) });
    try std.testing.expect(try ready_sessions.ready(ready.handle, ready.operation, advertised));
    try bridge.beginRequest();
    app.sessions = &ready_sessions;
    tab.content_owner = .{ .session = ready.handle };
    tab.failed = false;
    try bridge.configureHost(.{ .context = authority, .handler_context = &driver, .invoke = Driver.query, .contributions = &queries.contributions });
    try bridge.prepare(&app, ready.handle);
    const ready_table = bridge.requestTable().?;
    try std.testing.expectEqual(@as(usize, 1), ready_table.lookup("read_terminal").?.targets.len);
    try std.testing.expectEqual(@as(usize, 1), ready_table.lookup("run_command").?.targets.len);
    invocation.context = authority;
    var ready_result = try Projection.execute(&app, null, authority.binding, .{ .execution_policy = .{ .execution_mode = .auto, .session_retention = .keep }, .permission_mode = .confirm, .host_contributions = &queries.contributions }, @splat(1), invocation, a);
    defer ready_result.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, ready_result.blocks[0].structured, "\"read_terminal\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, ready_result.blocks[0].structured, "\"batch_execution\":true") != null);
    try std.testing.expect(try ready_sessions.failed(ready.handle, ready.operation, .{ .domain = .transport, .code = "Revoked", .cleanup = .released, .safe_message = "fixture" }));
    bridge.pump(&app);
    try std.testing.expect(!bridge.children.items[0].member.authorized);
    var revoked_result = try Projection.execute(&app, null, authority.binding, .{ .execution_policy = .{ .execution_mode = .auto, .session_retention = .keep }, .permission_mode = .confirm, .host_contributions = &queries.contributions }, @splat(1), invocation, a);
    defer revoked_result.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, revoked_result.blocks[0].structured, "\"read_terminal\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, revoked_result.blocks[0].structured, "\"batch_execution\":false") != null);
}

const QueryCleanupProbe = struct {
    pending: bool = true,
    receipt: Application.CloseReceipt = .unknown,
    pumps: usize = 0,
    stops: usize = 0,
    shutdowns: usize = 0,
    destroyed: usize = 0,
    fn cast(raw: *anyopaque) *@This() {
        return @ptrCast(@alignCast(raw));
    }
    fn clear(raw: *anyopaque) !void {
        if (cast(raw).pending) return error.ToolCleanupPending;
    }
    fn destroy(raw: *anyopaque, _: std.mem.Allocator) void {
        cast(raw).destroyed += 1;
    }
    fn pump(raw: *anyopaque, _: *anyopaque) void {
        cast(raw).pumps += 1;
    }
    fn risk(raw: *anyopaque, _: identity.SessionHandle) bool {
        return cast(raw).pending;
    }
    fn impact(raw: *anyopaque, _: identity.SessionHandle) @import("group_close_controller.zig").Impact {
        return .{ .unknown = @intFromBool(cast(raw).pending), .remote_effect_unknown = cast(raw).pending };
    }
    fn stop(raw: *anyopaque, _: identity.SessionHandle) Application.CloseReceipt {
        cast(raw).stops += 1;
        return if (cast(raw).pending) cast(raw).receipt else .released;
    }
    fn shutdown(raw: *anyopaque, _: ?*anyopaque) void {
        cast(raw).shutdowns += 1;
    }
    fn query(_: *anyopaque, _: host_tools.Invocation, _: std.mem.Allocator) !host_tools.Result {
        return error.UnexpectedDispatch;
    }
    fn worker(_: *anyopaque, _: *Bridge, invocation: host_tools.Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !host_tools.Result {
        return .{ .status = .succeeded, .receipt = .{ .conversation_id = invocation.context.conversation_id, .task_id = invocation.context.task_id, .operation_id = invocation.operation_id, .binding_revision = invocation.context.binding_revision } };
    }
    fn install(self: *@This(), bridge: *Bridge, owner: identity.SessionHandle, hooks: *const legacy.Adapter.VTable) !void {
        const child = try bridge.allocator.create(Child);
        child.* = .{ .owner = owner, .adapter = .{ .context = self, .vtable = hooks }, .member = .{ .owner = owner, .plugin_id = "fixture", .context = self, .bindings = &.{} } };
        try bridge.children.append(bridge.allocator, child);
    }
    fn table(bridge: *Bridge, authority: host_tools.Context, contributions: []const host_tools.Contribution) !void {
        try bridge.configureHost(.{ .context = authority, .handler_context = bridge, .invoke = query, .invoke_worker = worker, .contributions = contributions });
        bridge.captured_scope = .{ .owner = authority.binding, .members = .{} };
        bridge.table = try tools.RequestTable.initWithHost(bridge.allocator, bridge.captured_scope.?, &.{}, &.{}, authority, bridge.host_binding.?.contributions);
        bridge.wire = try tools.providerDefinitions(&bridge.table.?, bridge.table.?.arena.allocator());
    }
    fn vtable() legacy.Adapter.VTable {
        // Only cleanup/metadata hooks can be touched in these tests. Undefined
        // command/content callbacks make accidental invocation fail loudly.
        var value: legacy.Adapter.VTable = undefined;
        value.clear = clear;
        value.destroy = destroy;
        value.pump = pump;
        value.risk = risk;
        value.impact = impact;
        value.stop = stop;
        value.shutdown = shutdown;
        return value;
    }
};

test "host bridge member close revokes only that member while group Task continues" {
    var bridge = Bridge.init(std.testing.allocator);
    defer bridge.deinit();
    var probe: QueryCleanupProbe = .{ .pending = false };
    var hooks = QueryCleanupProbe.vtable();
    const first: identity.SessionHandle = .{ .session_id = @fromBackingInt(41), .generation = 3 };
    const second: identity.SessionHandle = .{ .session_id = @fromBackingInt(42), .generation = 1 };
    const authority: host_tools.Context = .{ .conversation_id = identity.ConversationId.generate(), .task_id = identity.TaskId.generate(), .binding = .{ .group = 7 }, .binding_revision = 1, .grant_revision = 1 };
    try QueryCleanupProbe.table(&bridge, authority, &@import("../ai/host_queries.zig").contributions);
    try probe.install(&bridge, first, &hooks);
    try probe.install(&bridge, second, &hooks);
    try std.testing.expectEqual(Application.CloseReceipt.released, bridge.stopOwner(first));
    try std.testing.expect(!bridge.stopped.load(.acquire));
    try std.testing.expect(!bridge.children.items[0].member.authorized);
    try std.testing.expect(bridge.children.items[1].member.authorized);
    try std.testing.expect(bridge.host_binding.?.context.eql(authority));
    _ = bridge.stopGroup(7);
    try std.testing.expect(bridge.stopped.load(.acquire));
}

test "host metadata Tasks retain one unknown cleanup owner and reject all effect paths" {
    const a = std.testing.allocator;
    const contributions = @import("../ai/host_queries.zig").contributions ++ @import("../ai/host_execution.zig").contributions ++ @import("../ai/host_lifecycle.zig").contributions ++ @import("../ai/fetch_url.zig").contributions;
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(41), .generation = 3 };
    const original: host_tools.Context = .{ .conversation_id = identity.ConversationId.generate(), .task_id = identity.TaskId.generate(), .binding = .{ .session = 41 }, .binding_revision = 1, .grant_revision = 1 };
    var bridge = Bridge.init(a);
    defer bridge.deinit();
    var probe: QueryCleanupProbe = .{};
    defer probe.pending = false;
    var vtable = QueryCleanupProbe.vtable();
    try QueryCleanupProbe.table(&bridge, original, &contributions);
    try probe.install(&bridge, owner, &vtable);
    // The native owner may have already returned an unknown ToolResult. Its
    // identity, table, scope and cleanup callbacks must survive the next Task.
    try bridge.beginRequest();
    try std.testing.expect(bridge.queries_only);
    try std.testing.expectEqual(@as(usize, 1), bridge.retired.items.len);
    const retained = bridge.retired.items[0];
    try std.testing.expectEqual(owner, retained.children.items[0].owner);
    try std.testing.expect(retained.requestTable().?.host_context.?.eql(original));
    try std.testing.expect(bridge.writeRisk(owner));
    try std.testing.expect(bridge.closeImpact(owner).remote_effect_unknown);
    probe.receipt = .awaiting;
    try std.testing.expectEqual(Application.CloseReceipt.awaiting, bridge.stopOwner(owner));
    probe.receipt = .unknown;
    try std.testing.expectEqual(Application.CloseReceipt.unknown, bridge.stopOwner(owner));
    var current = original;
    for (0..3) |_| {
        current.task_id = identity.TaskId.generate();
        try QueryCleanupProbe.table(&bridge, current, &contributions);
        try std.testing.expectEqual(@as(usize, 6), bridge.requestTable().?.entries.len);
        try std.testing.expectEqual(@as(usize, 1), bridge.retired.items.len);
        try std.testing.expect(bridge.retired.items[0] == retained);
        var invocation: host_tools.Invocation = .{ .context = current, .authority = .conversation_context, .operation_id = 1, .turn_id = 1, .call_id = "query", .tool_id = "host.get_current_context", .arguments = .{ .object = .empty }, .arguments_json = "{}", .arguments_hash = @splat(0), .canonical_arguments_hash = @splat(0) };
        var result = try bridge.dispatchHost(invocation, a, null);
        defer result.deinit(a);
        try result.validate(current, 1);
        invocation.tool_id = "host.run_in_terminal";
        try std.testing.expectError(error.ToolNotAvailable, bridge.dispatchHost(invocation, a, null));
        invocation.tool_id = "host.open_session";
        try std.testing.expectError(error.ToolNotAvailable, bridge.dispatchHost(invocation, a, null));
        invocation.tool_id = "host.fetch_url";
        try std.testing.expectError(error.ToolNotAvailable, bridge.dispatchHost(invocation, a, null));
        invocation.context = original;
        try std.testing.expectError(error.ScopeChanged, bridge.dispatchHost(invocation, a, null));
        try bridge.beginRequest();
    }
    // The collection is explicitly bounded even if a caller violates the
    // metadata-only preparation contract.
    try std.testing.expectError(error.ToolCleanupPending, bridge.retainPrepared());
    var sessions = try @import("../host/session_host.zig").SessionHost.init(a, &.{});
    defer sessions.deinit();
    var config: @import("../config/config.zig").Config = .{};
    var workspace: @import("workspace.zig").Workspace = undefined;
    workspace.app_config = &config;
    var app: Application.ApplicationHost = undefined;
    app.workspace = &workspace;
    app.sessions = &sessions;
    app.mappings = .empty;
    bridge.pump(&app);
    try std.testing.expectEqual(@as(usize, 1), probe.pumps);
    try std.testing.expectEqual(@as(usize, 0), probe.destroyed);
    bridge.shutdown(&app);
    try std.testing.expectEqual(@as(usize, 1), probe.shutdowns);
    try std.testing.expectError(error.ToolCleanupPending, bridge.clear());
    probe.pending = false;
    bridge.pump(&app);
    try std.testing.expectEqual(@as(usize, 1), probe.destroyed);
    try std.testing.expectEqual(@as(usize, 0), bridge.retired.items.len);
    try std.testing.expect(!bridge.writeRisk(owner));
    // A running metadata Task remains narrowed; only a new Task can regain
    // its freshly captured normal catalog after actual cleanup succeeded.
    try std.testing.expect(bridge.queries_only);
    try bridge.beginRequest();
    try std.testing.expect(!bridge.queries_only);
    try QueryCleanupProbe.table(&bridge, current, &contributions);
    try std.testing.expect(bridge.requestTable().?.entries.len > 6);
}

test "host authority refresh narrows its cloned directory while preserving original cleanup ownership" {
    const a = std.testing.allocator;
    const contributions = @import("../ai/host_queries.zig").contributions ++ @import("../ai/host_execution.zig").contributions;
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(8), .generation = 2 };
    const original: host_tools.Context = .{ .conversation_id = identity.ConversationId.generate(), .task_id = identity.TaskId.generate(), .binding = .{ .session = 8 }, .binding_revision = 1, .grant_revision = 1 };
    var bridge = Bridge.init(a);
    defer bridge.deinit();
    var probe: QueryCleanupProbe = .{};
    defer probe.pending = false;
    var vtable = QueryCleanupProbe.vtable();
    try QueryCleanupProbe.table(&bridge, original, &contributions);
    try probe.install(&bridge, owner, &vtable);
    var refreshed = original;
    refreshed.binding = .{ .group = 7 };
    refreshed.binding_revision += 1;
    var next = Bridge.init(a);
    defer next.deinit();
    try QueryCleanupProbe.table(&next, refreshed, &contributions);
    try bridge.replacePrepared(&next);
    var cloned = try tools.cloneTable(bridge.requestTable().?, a);
    defer cloned.deinit();
    try std.testing.expect(bridge.queries_only);
    try std.testing.expect(cloned.host_context.?.eql(refreshed));
    try std.testing.expectEqual(@as(usize, 6), cloned.entries.len);
    try std.testing.expect(bridge.retired.items[0].requestTable().?.host_context.?.eql(original));
    try std.testing.expect(bridge.writeRisk(owner));
    try std.testing.expectEqual(@as(usize, 0), probe.destroyed);
    // A later refresh cannot widen the same metadata Task by passing a fresh
    // candidate with a normal catalog, even while old cleanup is unchanged.
    var later = Bridge.init(a);
    defer later.deinit();
    refreshed.binding_revision += 1;
    try QueryCleanupProbe.table(&later, refreshed, &contributions);
    try bridge.replacePrepared(&later);
    try std.testing.expect(bridge.queries_only);
    try std.testing.expectEqual(@as(usize, 6), bridge.requestTable().?.entries.len);
    try std.testing.expectEqual(@as(usize, 1), bridge.retired.items.len);
}

test "host controller exchange releases its lock and cancels an undispatched query" {
    const a = std.testing.allocator;
    var bridge = Bridge.init(a);
    defer bridge.deinit();
    const authority: host_tools.Context = .{ .conversation_id = identity.ConversationId.generate(), .task_id = identity.TaskId.generate(), .binding = .{ .group = 7 }, .binding_revision = 1, .grant_revision = 1 };
    const Fixture = struct {
        bridge: *Bridge,
        calls: usize = 0,
        fn handle(raw: *anyopaque, invocation: host_tools.Invocation, _: std.mem.Allocator) !host_tools.Result {
            const self: *@This() = @ptrCast(@alignCast(raw));
            // The worker also takes this mutex briefly while observing ready.
            // Distinguish ordinary contention from a lock held across callback.
            var attempts: usize = 0;
            while (!self.bridge.mutex.tryLock()) : (attempts += 1) {
                if (attempts == 128) return error.ControllerLockHeld;
                var delay: std.c.timespec = .{ .sec = 0, .nsec = 100_000 };
                _ = std.c.nanosleep(&delay, null);
            }
            self.bridge.mutex.unlock();
            self.calls += 1;
            return .{ .status = .succeeded, .receipt = .{ .conversation_id = invocation.context.conversation_id, .task_id = invocation.context.task_id, .operation_id = invocation.operation_id, .binding_revision = invocation.context.binding_revision } };
        }
    };
    var fixture: Fixture = .{ .bridge = &bridge };
    try bridge.configureHost(.{ .context = authority, .handler_context = &fixture, .invoke = Fixture.handle, .contributions = &@import("../ai/host_queries.zig").contributions });
    const Worker = struct {
        bridge: *Bridge,
        request: host_tools.Invocation,
        cancel: provider.CancelToken = .{},
        result: ?host_tools.Result = null,
        failure: ?anyerror = null,
        done: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            self.result = Bridge.executeHost(self.bridge, self.request, a, &self.cancel) catch |err| blk: {
                self.failure = err;
                break :blk null;
            };
            self.done.store(true, .release);
        }
    };
    var worker: Worker = .{ .bridge = &bridge, .request = .{ .context = authority, .authority = .conversation_context, .operation_id = 1, .turn_id = 1, .call_id = "query", .tool_id = "host.get_current_context", .arguments = .{ .object = .empty }, .arguments_json = "{}", .arguments_hash = @splat(0), .canonical_arguments_hash = @splat(0) } };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    var spins: usize = 0;
    while (!worker.done.load(.acquire) and spins < 400) : (spins += 1) {
        bridge.pumpHost();
        pause();
    }
    worker.cancel.cancel();
    thread.join();
    try std.testing.expect(worker.failure == null);
    var result = worker.result orelse return error.MissingHostResult;
    defer result.deinit(a);
    try result.validate(authority, 1);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    worker.result = null;
    worker.failure = null;
    worker.done.store(false, .release);
    const cancelled_thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    cancelled_thread.join();
    try std.testing.expectEqual(error.CancelledBeforeDispatch, worker.failure.?);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expect(bridge.host_exchange == null);
}

test "large dynamic directory availability never overflows legacy target projection" {
    var bridge = Bridge.init(std.testing.allocator);
    defer bridge.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const targets = try arena.allocator().alloc(tools.TargetBinding, 300);
    const entries = try arena.allocator().alloc(tools.Entry, 1);
    entries[0] = .{ .definition = .{ .id = "read_remote_file", .schema = "{\"type\":\"object\"}" }, .provider_name = "read_remote_file", .targets = targets };
    bridge.table = .{ .arena = arena, .captured_scope = .{ .owner = .{ .group = 7 }, .members = .{} }, .entries = entries };
    try std.testing.expect(bridge.remoteFilesAvailable());
    try std.testing.expectError(error.TargetProjectionRequired, bridge.toolIds(.read_remote_file));
}

test "fixed PTY mode rejects isolated command before any bridge mailbox or target dispatch" {
    const a = std.testing.allocator;
    var bridge = Bridge.init(a);
    defer bridge.deinit();
    const entry: tools.Entry = .{ .definition = .{ .id = "run_command", .schema = "{\"type\":\"object\"}" }, .provider_name = "run_command", .targets = &.{} };
    var table: tools.RequestTable = .{ .arena = .init(a), .captured_scope = .{ .owner = .{ .session = 1 }, .members = .{} }, .entries = &.{entry} };
    defer table.deinit();
    const json = try std.json.parseFromSlice(std.json.Value, a, "{}", .{});
    defer json.deinit();
    const invocation: tools.DynamicInvocation = .{ .table = &table, .parsed = .{ .json = json, .entry = &entry, .targets = .{}, .arguments_hash = @splat(0) }, .turn_id = 1, .call_id = "fixed-mode", .arguments = "{}", .operation_id = 1 };
    for ([_]@import("../config/config.zig").ExecutionMode{ .attached_pty, .new_pty }) |mode| {
        bridge.execution_mode = mode;
        try std.testing.expectError(error.ModeConflict, Bridge.executeDynamic(&bridge, invocation, a, null));
        try std.testing.expect(bridge.running == null and bridge.pending == null and bridge.controller == null);
        try std.testing.expectEqual(@as(usize, 0), bridge.children.items.len);
    }
    bridge.queries_only = true;
    bridge.execution_mode = .auto;
    try std.testing.expectError(error.ToolNotAvailable, Bridge.executeDynamic(&bridge, invocation, a, null));
}

test "routing run_command to current terminal returns real plan change with zero target calls" {
    const a = std.testing.allocator;
    const Fixture = struct {
        calls: usize = 0,
        fn invoke(raw: *anyopaque, _: tools.Invocation, _: std.mem.Allocator) !tools.ToolResult {
            @as(*@This(), @ptrCast(@alignCast(raw))).calls += 1;
            return error.UnexpectedDispatch;
        }
        fn hostInvoke(_: *anyopaque, _: host_tools.Invocation, _: std.mem.Allocator) !host_tools.Result {
            return error.UnexpectedDispatch;
        }
    };
    var fixture: Fixture = .{};
    const target: identity.SessionHandle = .{ .session_id = @fromBackingInt(1), .generation = 3 };
    const ctx: host_tools.Context = .{ .conversation_id = identity.ConversationId.generate(), .task_id = identity.TaskId.generate(), .binding = .{ .session = 1 }, .binding_revision = 1, .grant_revision = 1 };
    var broker: approvals.Broker = .{};
    try broker.configure(ctx, 1);
    var bridge = Bridge.init(a);
    defer bridge.deinit();
    bridge.execution_mode = .ask;
    bridge.captured_scope = .{ .owner = ctx.binding, .members = .{ .ids = .{1} ++ @as([15]u64, @splat(0)), .len = 1 } };
    bridge.host_binding = .{ .context = ctx, .handler_context = &fixture, .invoke = Fixture.hostInvoke, .contributions = &.{} };
    try bridge.configureRouting(&broker, ctx, "请检查", target);
    const binding: tools.ToolBinding = .{ .plugin_id = "route-fixture", .definition_id = "run_command", .handler = Fixture.invoke, .execution = .worker };
    const child = try a.create(Child);
    child.* = .{ .owner = target, .member = .{ .owner = target, .plugin_id = "route-fixture", .context = &fixture, .bindings = &.{binding} } };
    try bridge.children.append(a, child);
    const entry: tools.Entry = .{ .definition = .{ .id = "run_command", .schema = "{\"type\":\"object\"}", .effect = .remote_input, .approval_policy = .always_confirm }, .provider_name = "run_command", .targets = &.{.{ .owner = target, .binding = binding, .context = &fixture, .capability_revision = 1, .policy_revision = 1, .services = &.{} }} };
    var table: tools.RequestTable = .{ .arena = .init(a), .captured_scope = bridge.captured_scope.?, .host_context = ctx, .entries = &.{entry} };
    defer table.deinit();
    const json = "{\"command\":\"pwd\",\"session_ids\":[1]}";
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    const invocation: tools.DynamicInvocation = .{ .table = &table, .parsed = .{ .json = parsed, .entry = &entry, .targets = bridge.captured_scope.?.members, .arguments_hash = routing.digest(json) }, .turn_id = 1, .call_id = "route-one", .arguments = json, .operation_id = 1 };
    const Worker = struct {
        bridge: *Bridge,
        invocation: tools.DynamicInvocation,
        result: ?[]tools.ToolResult = null,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.result = Bridge.executeDynamic(self.bridge, self.invocation, std.testing.allocator, null) catch |err| {
                self.failure = err;
                return;
            };
        }
    };
    var worker: Worker = .{ .bridge = &bridge, .invocation = invocation };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    var pending: ?approvals.Snapshot = null;
    for (0..1000) |_| {
        pending = broker.snapshot();
        if (pending != null) break;
        @import("../ai/retry.zig").wait(1, null) catch unreachable;
    }
    if (pending) |snapshot| {
        try broker.chooseRoute(snapshot.sequence, snapshot.arguments_hash, .current_terminal);
        try broker.decide(snapshot.sequence, snapshot.arguments_hash, true);
    } else broker.stop();
    thread.join();
    try std.testing.expect(pending != null);
    if (worker.failure) |err| return err;
    const results = worker.result.?;
    defer a.free(results);
    defer for (results) |*result| result.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expectEqual(tools.Status.cancelled_unsent, results[0].status);
    try std.testing.expect(std.mem.indexOf(u8, results[0].blocks[0].structured, "requires_plan_change") != null);
    try std.testing.expect(broker.execution_route.resolve(ctx, target, "pwd", .batch).approved);
}

test "routing intent and approval grants cannot expand retired metadata only bridge" {
    const a = std.testing.allocator;
    var bridge = Bridge.init(a);
    defer bridge.deinit();
    bridge.queries_only = true;
    const ctx: host_tools.Context = .{ .conversation_id = identity.ConversationId.generate(), .task_id = identity.TaskId.generate(), .binding = .{ .session = 1 }, .binding_revision = 1, .grant_revision = 1 };
    var broker: approvals.Broker = .{};
    try broker.configure(ctx, 1);
    const handle: identity.SessionHandle = .{ .session_id = @fromBackingInt(1), .generation = 1 };
    try broker.execution_route.select(ctx, .{ .route = .current_terminal, .source = .{ .session = handle } }, "pwd", true);
    try bridge.configureRouting(&broker, ctx, "这次在当前终端执行 `pwd`", handle);
    try std.testing.expect(bridge.route_broker == null);
    const invocation: host_tools.Invocation = .{ .context = ctx, .authority = .execution_control, .operation_id = 1, .turn_id = 1, .call_id = "retired-route", .tool_id = "host.run_in_terminal", .arguments = .{ .object = .empty }, .arguments_json = "{}", .arguments_hash = routing.digest("{}"), .canonical_arguments_hash = routing.digest("{}") };
    var subject: approvals.Subject = .{ .kind = .terminal_command, .target = "session 1", .detail = "pwd" };
    try std.testing.expectError(error.ToolNotAvailable, bridge.prepareHostRoute(invocation, &subject, handle, .current_terminal, a));
    try std.testing.expectError(error.ToolNotAvailable, bridge.requestHostRoute(invocation, subject, a, null));
}
