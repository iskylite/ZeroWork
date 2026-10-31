//! Main-thread task settlement and the existing cleanup-row presentation.
//! Model text ending only requests settlement; execution facts remain owned by
//! the real Driver. No wait, interrupt, journal IO or worker join occurs here.
const std = @import("std");
const ui = @import("ui");
const identity = @import("../host/identity.zig");
const host = @import("../ai/host_tools.zig");
const lifecycle = @import("../host/lifecycle_supervisor.zig");
const Application = @import("application_host.zig").ApplicationHost;
const styles = @import("ai_task_finish_styles.zig");
const theme = @import("app_theme.zig");
pub const Outcome = enum { completed, failed, cancelled };
pub const Decision = enum { keep, close };
pub const Control = enum { stop, takeover };
pub const Phase = enum { working, settling, choice, closing, kept, retained, closed, cleanup_pending, finished };
pub const Gates = struct {
    pending_tool_slots: usize = 0,
    pending_approvals: usize = 0,
    pending_dispatches: usize = 0,
    active_references: usize = 0,
    resource_references_transferred: bool = false,
    pub fn settled(self: Gates) bool {
        return self.pending_tool_slots == 0 and self.pending_approvals == 0 and self.pending_dispatches == 0 and self.active_references == 0 and self.resource_references_transferred;
    }
};
pub const GatesProvider = struct {
    context: *anyopaque,
    /// Must be a nonblocking observation of this exact Task's real slots,
    /// approvals and references. Null means retry a future frame.
    read: *const fn (*anyopaque, host.Context) ?Gates,
};
pub const InputTarget = struct {
    handle: identity.SessionHandle,
    execution_id: identity.ExecutionId,
    input_epoch: u64 = 0,
    name: [80]u8 = @splat(0),
    name_len: usize = 0,
    pub fn label(self: *const InputTarget) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn setName(self: *InputTarget, name: []const u8) void {
        var count = @min(name.len, self.name.len);
        while (count > 0 and !std.unicode.utf8ValidateSlice(name[0..count])) count -= 1;
        @memcpy(self.name[0..count], name[0..count]);
        self.name_len = count;
    }
};
pub const ControlEvent = struct {
    context: host.Context,
    handle: identity.SessionHandle,
    execution_id: identity.ExecutionId,
    phase: enum { requested, released },
};
pub const ExecutionEvidence = struct {
    conversation_id: identity.ConversationId,
    task_id: identity.TaskId,
    revision: u64 = 1,
    model_done: bool = false,
    execution_count: usize = 0,
    active_executions: usize = 0,
    awaiting_input: usize = 0,
    pending_dispatch: usize = 0,
    executions_settled: bool = false,
    input_grants_released: bool = false,
    recordings_settled: bool = false,
    remote_effect_unknown: bool = false,
    output_attribution_unverified: bool = false,
    pending_external_jobs: usize = 0,
    active_references: usize = 0,
    handed_off_observers: usize = 0,
    controlled_executions_settled: ?bool = null,
    pub fn settled(self: ExecutionEvidence) bool {
        const all_settled = self.active_executions == 0 and self.executions_settled and self.recordings_settled and self.active_references == 0;
        const handed = self.handed_off_observers > 0 and self.active_executions == self.handed_off_observers and self.controlled_executions_settled == true and self.active_references <= self.handed_off_observers;
        return self.model_done and self.awaiting_input == 0 and self.pending_dispatch == 0 and self.input_grants_released and (all_settled or handed);
    }
};
pub const InputEvidence = struct {
    execution_id: identity.ExecutionId,
    target: identity.SessionHandle,
    revision: u64,
    state: @import("../host/terminal_execution.zig").State,
    terminal: bool,
    input_handed_off: bool,
    local_released: bool,
    input_ready: bool,
    has_grant: bool,
    fn released(self: InputEvidence) bool {
        return self.input_handed_off and self.local_released and self.input_ready and !self.has_grant;
    }
};
pub const ExecutionSource = struct {
    context: *anyopaque,
    finish_model: *const fn (*anyopaque, host.Context) anyerror!void,
    stop: *const fn (*anyopaque, host.Context) anyerror!void,
    takeover_execution: ?*const fn (*anyopaque, host.Context, identity.ExecutionId) anyerror!void = null,
    input_targets: ?*const fn (*anyopaque, host.Context, []InputTarget) anyerror![]InputTarget = null,
    input_evidence: ?*const fn (*anyopaque, host.Context, identity.ExecutionId) ?InputEvidence = null,
    evidence: *const fn (*anyopaque, identity.TaskId) ?ExecutionEvidence,
    /// Zero-allocation adapter to Driver's nonblocking commands and tryLock
    /// evidence. Generic only so the View/isolated preview needs no Driver.
    pub fn fromDriver(driver: anytype) ExecutionSource {
        const T = @typeInfo(@TypeOf(driver)).pointer.child;
        const Adapter = struct {
            fn finish(raw: *anyopaque, context: host.Context) !void {
                return (@as(*T, @ptrCast(@alignCast(raw)))).finishTask(context);
            }
            fn stop(raw: *anyopaque, context: host.Context) !void {
                return (@as(*T, @ptrCast(@alignCast(raw)))).stopTask(context);
            }
            fn takeover(raw: *anyopaque, context: host.Context, execution_id: identity.ExecutionId) !void {
                var reference: [35]u8 = undefined;
                return (@as(*T, @ptrCast(@alignCast(raw)))).requestTakeover(context, try std.fmt.bufPrint(&reference, "x1:{s}", .{std.fmt.bytesToHex(execution_id.bytes, .lower)}));
            }
            fn inputEvidence(raw: *anyopaque, context: host.Context, id: identity.ExecutionId) ?InputEvidence {
                const fact = (@as(*T, @ptrCast(@alignCast(raw)))).executionInputEvidence(context, id) orelse return null;
                return .{ .execution_id = fact.execution_id, .target = fact.target, .revision = fact.revision, .state = fact.state, .terminal = fact.terminal, .input_handed_off = fact.input_handed_off, .local_released = fact.local_released, .input_ready = fact.input_ready, .has_grant = fact.has_grant };
            }
            fn read(raw: *anyopaque, task: identity.TaskId) ?ExecutionEvidence {
                const fact = (@as(*T, @ptrCast(@alignCast(raw)))).taskEvidence(task) orelse return null;
                return .{ .conversation_id = fact.conversation_id, .task_id = fact.task_id, .revision = fact.revision, .model_done = fact.model_done, .execution_count = fact.execution_count, .active_executions = fact.active_executions, .awaiting_input = @intFromBool(fact.awaiting_input), .pending_dispatch = fact.pending_dispatch, .executions_settled = fact.executions_settled, .input_grants_released = fact.input_grants_released, .recordings_settled = fact.recordings_settled, .remote_effect_unknown = fact.remote_effect_unknown, .output_attribution_unverified = fact.output_attribution_unverified, .pending_external_jobs = @intFromBool(fact.pending_external_jobs), .active_references = fact.active_references, .handed_off_observers = fact.handed_off_observers, .controlled_executions_settled = fact.controlled_executions_settled };
            }
        };
        return .{ .context = driver, .finish_model = Adapter.finish, .stop = Adapter.stop, .takeover_execution = Adapter.takeover, .input_evidence = Adapter.inputEvidence, .evidence = Adapter.read };
    }
};
pub const Resource = struct {
    handle: identity.SessionHandle,
    ownership_revision: u64,
    ownership: lifecycle.Ownership,
    retention: lifecycle.Retention,
    state: lifecycle.State,
    idle: enum { confirmed, active, unknown } = .unknown,
    name: [80]u8 = @splat(0),
    name_len: usize = 0,
    pub fn label(self: *const Resource) []const u8 {
        return self.name[0..self.name_len];
    }
    fn setName(self: *Resource, value: []const u8) void {
        var len = @min(value.len, self.name.len);
        while (len > 0 and !std.unicode.utf8ValidateSlice(value[0..len])) len -= 1;
        @memcpy(self.name[0..len], value[0..len]);
        self.name_len = len;
    }
};
const Selection = struct { handle: identity.SessionHandle, ownership_revision: u64 };
const Task = struct {
    context: host.Context,
    outcome: Outcome = .completed,
    model_ended: bool = false,
    pending_control: ?Control = null,
    takeover_requested: bool = false,
    takeover_sent: bool = false,
    pending_target: ?InputTarget = null,
    targets: std.ArrayList(InputTarget) = .empty,
    order: u64,
    revision: u64 = 1,
    fingerprint: ?u64 = null,
    phase: Phase = .working,
    finish_sent: bool = false,
    stop_sent: bool = false,
    receipt: ?lifecycle.TaskFinishReceipt = null,
    resources: std.ArrayList(Resource) = .empty,
    selection: std.ArrayList(Selection) = .empty,
    decision: ?Decision = null,
    close_cursor: usize = 0,
    close_presented: bool = false,
    active_executions: usize = 0,
    remote_effect_unknown: bool = false,
    feedback: ?[]const u8 = null,
    fn deinit(self: *Task, a: std.mem.Allocator) void {
        self.resources.deinit(a);
        self.selection.deinit(a);
        self.targets.deinit(a);
    }
};
pub const Snapshot = struct {
    context: host.Context,
    sequence: u64 = 0,
    revision: u64,
    phase: Phase,
    resources: []const Resource,
    active_executions: usize,
    remote_effect_unknown: bool,
    feedback: ?[]const u8,
    visible: bool,
    control_pending: bool = false,
    model_done: bool = false,
    targets: []const InputTarget = &.{},
};
pub const Controller = struct {
    allocator: std.mem.Allocator,
    tasks: std.ArrayList(Task) = .empty,
    next_order: u64 = 1,
    control_events: std.ArrayList(ControlEvent) = .empty,
    pub fn init(a: std.mem.Allocator) Controller {
        return .{ .allocator = a };
    }
    pub fn deinit(self: *Controller) void {
        for (self.tasks.items) |*task| task.deinit(self.allocator);
        self.tasks.deinit(self.allocator);
        self.control_events.deinit(self.allocator);
    }
    fn find(self: *Controller, id: identity.TaskId) ?*Task {
        for (self.tasks.items) |*task| if (task.context.task_id.eql(id)) return task;
        return null;
    }
    pub fn registerTask(self: *Controller, context: host.Context) !void {
        try context.validate();
        if (self.find(context.task_id)) |task| {
            if (!task.context.conversation_id.eql(context.conversation_id)) return error.ScopeChanged;
            if (context.grant_revision != task.context.grant_revision or context.binding_revision < task.context.binding_revision) return error.ScopeChanged;
            if (!std.meta.eql(context.binding, task.context.binding)) {
                if (context.binding_revision == task.context.binding_revision or task.context.binding != .session or context.binding != .group) return error.ScopeChanged;
            }
            task.context = context;
            publish(task);
            return;
        }
        if (self.tasks.items.len == 128) return error.TaskFinishLimit;
        const order = self.next_order;
        self.next_order = try identity.advance(self.next_order);
        try self.tasks.append(self.allocator, .{ .context = context, .order = order });
    }
    /// Only the actual provider/tool loop end changes model_ended. Session
    /// takeover keeps this Task alive and only awaits its real input release.
    pub fn modelEnded(self: *Controller, context: host.Context, outcome: Outcome) !void {
        try self.registerTask(context);
        const task = self.find(context.task_id).?;
        if (!task.model_ended or (task.receipt == null and outcome == .cancelled)) task.outcome = outcome;
        task.model_ended = true;
    }
    pub fn control(self: *Controller, task_id: identity.TaskId, revision: u64, action: Control) !void {
        const task = self.find(task_id) orelse return error.NotFound;
        if (task.revision != revision or task.receipt != null or task.active_executions == 0) return error.ScopeChanged;
        if (task.pending_control != null or task.stop_sent or task.takeover_requested) return error.OperationBusy;
        if (action == .takeover) {
            if (task.targets.items.len != 1) return error.TargetSelectionRequired;
            task.pending_target = task.targets.items[0];
        }
        task.pending_control = action;
        if (action == .takeover) task.takeover_requested = true;
    }
    pub fn controlTarget(self: *Controller, task_id: identity.TaskId, revision: u64, handle: identity.SessionHandle, execution_id: identity.ExecutionId) !void {
        const task = self.find(task_id) orelse return error.NotFound;
        if (task.revision != revision or task.receipt != null or task.active_executions == 0) return error.ScopeChanged;
        if (task.pending_control != null or task.stop_sent or task.takeover_requested) return error.OperationBusy;
        for (task.targets.items) |target| if (target.handle.eql(handle) and target.execution_id.eql(execution_id)) {
            task.pending_target = target;
            task.pending_control = .takeover;
            task.takeover_requested = true;
            return;
        };
        return error.ScopeChanged;
    }
    /// Pane controls already freeze the exact live execution. Resolve only the
    /// owning Task revision; never use an active tab or another conversation.
    pub fn controlCurrentTarget(self: *Controller, task_id: identity.TaskId, handle: identity.SessionHandle, execution_id: identity.ExecutionId) !void {
        const task = self.find(task_id) orelse return error.NotFound;
        return self.controlTarget(task_id, task.revision, handle, execution_id);
    }
    pub fn drainControlEvents(self: *Controller, buffer: []ControlEvent) []ControlEvent {
        const count = @min(buffer.len, self.control_events.items.len);
        @memcpy(buffer[0..count], self.control_events.items[0..count]);
        std.mem.copyForwards(ControlEvent, self.control_events.items[0 .. self.control_events.items.len - count], self.control_events.items[count..]);
        self.control_events.items.len -= count;
        return buffer[0..count];
    }
    fn projected(task: *const Task) Snapshot {
        return .{ .context = task.context, .sequence = task.order, .revision = task.revision, .phase = task.phase, .resources = task.resources.items, .targets = task.targets.items, .active_executions = task.active_executions, .remote_effect_unknown = task.remote_effect_unknown, .feedback = task.feedback, .visible = if (task.phase == .working) task.active_executions > 0 else task.resources.items.len > 0 or task.phase == .settling, .control_pending = task.pending_control != null or task.takeover_requested or task.stop_sent, .model_done = task.model_ended };
    }
    pub fn snapshotFor(self: *Controller, context: host.Context) ?Snapshot {
        const task = self.find(context.task_id) orelse return null;
        if (!task.context.conversation_id.eql(context.conversation_id)) return null;
        return projected(task);
    }
    pub fn snapshotForConversation(self: *Controller, conversation: identity.ConversationId) ?Snapshot {
        var latest: ?*Task = null;
        for (self.tasks.items) |*task| if (task.context.conversation_id.eql(conversation) and (latest == null or task.order > latest.?.order)) {
            latest = task;
        };
        return if (latest) |task| projected(task) else null;
    }
    /// Bounded read-only projection in registration order. Each visible old
    /// Task keeps its own controls when the same conversation starts new work.
    pub fn snapshotsForConversation(self: *Controller, conversation: identity.ConversationId, buffer: []Snapshot) ![]Snapshot {
        var count: usize = 0;
        for (self.tasks.items) |*task| {
            if (!task.context.conversation_id.eql(conversation)) continue;
            const snapshot = projected(task);
            if (!snapshot.visible) continue;
            if (count == buffer.len) return error.OutputTooSmall;
            buffer[count] = snapshot;
            count += 1;
        }
        return buffer[0..count];
    }
    pub fn receiptFor(self: *Controller, context: host.Context) ?lifecycle.TaskFinishReceipt {
        const task = self.find(context.task_id) orelse return null;
        return if (task.context.conversation_id.eql(context.conversation_id)) task.receipt else null;
    }
    fn inScope(app: *Application, context: host.Context, handle: identity.SessionHandle) bool {
        return switch (context.binding) {
            .session => |id| id == @backingInt(handle.session_id),
            .group => |id| blk: {
                const roster = app.workspace.group_roster orelse return false;
                const group = roster.findById(std.math.cast(u32, id) orelse return false) orelse return false;
                const legacy = app.legacyForHandle(handle) orelse return false;
                for (group.members.items) |member| if (member.active and member.pane_id == legacy) break :blk true;
                break :blk false;
            },
        };
    }
    fn historicalInScope(app: *Application, context: host.Context, handle: identity.SessionHandle) bool {
        for (app.deferred_closes.items) |close| if (close.handle.eql(handle) and close.snapshot.state == .closed and @import("../ai/host_queries.zig").sameHistoricalBinding(close.context, context)) return true;
        // Settlement may show the final state of its own already-known work
        // resource. This is UI history only, never a content/archive grant.
        if (app.lifecycle_supervisor.resource(handle)) |entry| if (entry.snapshot.state == .closed and @import("../ai/host_queries.zig").sameHistoricalBinding(entry.request.context, context)) return true;
        return false;
    }
    fn readTargets(self: *Controller, task: *Task, app: *Application, source: ?ExecutionSource) !void {
        task.targets.clearRetainingCapacity();
        if (source) |owner| if (owner.input_targets) |read| {
            var buffer: [64]InputTarget = undefined;
            for (try read(owner.context, task.context, &buffer)) |target| if (inScope(app, task.context, target.handle)) try task.targets.append(self.allocator, target);
            return;
        };
        for (app.domain.attachments.items) |host_app| for (host_app.mappings.items) |mapping| {
            if (host_app != app or !inScope(app, task.context, mapping.handle)) continue;
            const tab = host_app.workspace.sessionTab(mapping.legacy_id) orelse continue;
            if (tab.archived or tab.content_owner != .session or !tab.content_owner.session.eql(mapping.handle)) continue;
            const binding = switch (host_app.sessions.queryService(mapping.handle, .terminal)) {
                .available => |value| value,
                else => continue,
            };
            const service = if (mapping.process) |process| process.terminalService(binding) catch continue else if (tab.runtime) |runtime| runtime.terminalService() catch continue else continue;
            const snapshot = service.executionSnapshot() catch continue;
            const grant = snapshot.grant orelse continue;
            const id = snapshot.execution_id orelse continue;
            if (!snapshot.owner.eql(mapping.handle) or !grant.task_id.eql(task.context.task_id) or !grant.execution_id.eql(id)) continue;
            if (task.targets.items.len == 64) return error.ControlTargetLimit;
            var target: InputTarget = .{ .handle = mapping.handle, .execution_id = id, .input_epoch = grant.input_epoch };
            target.setName(tab.titleSlice());
            try task.targets.append(self.allocator, target);
        };
    }
    fn targetInputEvidence(app: *Application, target: InputTarget) ?InputEvidence {
        for (app.domain.attachments.items) |host_app| {
            const mapping = host_app.findHandle(target.handle) orelse continue;
            const tab = host_app.workspace.sessionTab(mapping.legacy_id) orelse return null;
            const binding = switch (host_app.sessions.queryService(target.handle, .terminal)) {
                .available => |value| value,
                else => return null,
            };
            const service = if (mapping.process) |process| process.terminalService(binding) catch return null else if (tab.runtime) |runtime| runtime.terminalService() catch return null else return null;
            const snapshot = service.executionSnapshot() catch return null;
            const id = snapshot.execution_id orelse return null;
            if (!snapshot.owner.eql(target.handle) or !id.eql(target.execution_id)) return null;
            return .{ .execution_id = id, .target = target.handle, .revision = snapshot.revision, .state = snapshot.state, .terminal = switch (snapshot.state) {
                .sealed, .interval_recorded, .cancelled_unsent, .handed_off, .outcome_unknown, .recording_degraded => true,
                else => false,
            }, .input_handed_off = snapshot.input_handed_off, .input_ready = snapshot.input_ready, .local_released = snapshot.local_released, .has_grant = snapshot.grant != null };
        }
        // A newer execution or input epoch proves nothing about whether this
        // original control action handed input to a human. Driver retains its
        // exact original execution evidence for that case.
        return null;
    }
    /// Button callbacks enqueue an exact frozen set. The following safe tick
    /// revalidates ownership before touching resources or showing native close.
    pub fn decide(self: *Controller, task_id: identity.TaskId, revision: u64, decision: Decision) !void {
        const task = self.find(task_id) orelse return error.NotFound;
        if (task.phase != .choice or task.revision != revision) return error.ScopeChanged;
        if (task.decision != null) return error.OperationBusy;
        task.selection.clearRetainingCapacity();
        for (task.resources.items) |resource| if (resource.ownership == .created_task and resource.retention == .ask and resource.state != .closed and resource.state != .failed and resource.state != .cancelled) {
            try task.selection.append(self.allocator, .{ .handle = resource.handle, .ownership_revision = resource.ownership_revision });
        };
        task.decision = decision;
        task.close_cursor = 0;
        task.close_presented = false;
    }
    fn harvest(self: *Controller, task: *Task, app: *Application) !void {
        var index: usize = 0;
        while (index < task.resources.items.len) {
            const handle = task.resources.items[index].handle;
            if (!inScope(app, task.context, handle) and !historicalInScope(app, task.context, handle)) {
                _ = task.resources.orderedRemove(index);
            } else index += 1;
        }
        for (app.lifecycle_supervisor.entries.items) |entry| {
            if (!entry.request.context.task_id.eql(task.context.task_id) or !entry.request.context.conversation_id.eql(task.context.conversation_id)) continue;
            const handle = entry.snapshot.session orelse continue;
            if (!inScope(app, task.context, handle) and !historicalInScope(app, task.context, handle)) continue;
            const resource = for (task.resources.items) |*item| {
                if (item.handle.eql(handle)) break item;
            } else blk: {
                try task.resources.append(self.allocator, .{ .handle = handle, .ownership_revision = entry.snapshot.ownership_revision, .ownership = entry.snapshot.ownership, .retention = entry.snapshot.retention, .state = entry.snapshot.state });
                break :blk &task.resources.items[task.resources.items.len - 1];
            };
            resource.ownership_revision = entry.snapshot.ownership_revision;
            resource.ownership = entry.snapshot.ownership;
            resource.retention = entry.snapshot.retention;
            resource.state = entry.snapshot.state;
            if (app.sessions.queryState(handle)) |state| if (state.lifecycle == .closed) {
                resource.state = .closed;
            };
            if (app.legacyForHandle(handle)) |legacy| if (app.workspace.sessionTab(legacy)) |tab| resource.setName(tab.titleSlice());
            if (resource.name_len == 0) {
                var label: [64]u8 = undefined;
                resource.setName(try std.fmt.bufPrint(&label, "工作终端 #{d}", .{@backingInt(handle.session_id)}));
            }
            resource.idle = .unknown;
            if (resource.state == .ready and resource.ownership == .created_task) {
                const evidence = app.ownedIdleEvidence(handle, task.context.task_id) catch lifecycle.IdleEvidence{};
                resource.idle = if (evidence.canClose()) .confirmed else if (evidence.confirmed) .active else .unknown;
            }
        }
    }
    fn applyDecision(self: *Controller, task: *Task, app: *Application) !void {
        _ = self;
        const decision = task.decision orelse return;
        if (decision == .keep) {
            for (task.selection.items) |selected| {
                if (!inScope(app, task.context, selected.handle)) continue;
                const entry = app.lifecycle_supervisor.resource(selected.handle) orelse continue;
                if (!entry.request.context.task_id.eql(task.context.task_id) or entry.snapshot.ownership != .created_task or entry.snapshot.ownership_revision != selected.ownership_revision) continue;
                app.handedToUserFor(selected.handle, .keep_choice) catch |err| switch (err) {
                    error.AlreadyClosing => continue,
                    else => return err,
                };
            }
            task.phase = .kept;
            task.decision = null;
            return;
        }
        task.phase = .closing;
        while (task.close_cursor < task.selection.items.len) {
            const selected = task.selection.items[task.close_cursor];
            if (!inScope(app, task.context, selected.handle)) {
                task.close_cursor += 1;
                task.close_presented = false;
                continue;
            }
            const entry = app.lifecycle_supervisor.resource(selected.handle) orelse {
                task.close_cursor += 1;
                continue;
            };
            if (!entry.request.context.task_id.eql(task.context.task_id) or entry.snapshot.ownership != .created_task or entry.snapshot.ownership_revision != selected.ownership_revision) {
                task.feedback = "终端所有权已变化，已保留该终端";
                task.close_cursor += 1;
                task.close_presented = false;
                continue;
            }
            const state = app.sessions.queryState(selected.handle) orelse {
                task.close_cursor += 1;
                continue;
            };
            if (state.lifecycle == .closed) {
                task.close_cursor += 1;
                task.close_presented = false;
                continue;
            }
            if (state.lifecycle == .cleanup_unknown) {
                task.phase = .cleanup_pending;
                task.feedback = "关闭结果待核实，未标记已清理";
                task.decision = null;
                return;
            }
            const legacy = app.legacyForHandle(selected.handle) orelse {
                task.close_cursor += 1;
                continue;
            };
            const tab = app.workspace.sessionTab(legacy) orelse {
                task.close_cursor += 1;
                continue;
            };
            if (state.close_operation != null or tab.closing or app.workspace.confirming_id == tab.tab_id) return;
            if (task.close_presented) {
                task.phase = .choice;
                task.feedback = "已取消关闭，任务会话仍保留";
                task.decision = null;
                return;
            }
            // A second close flow already visible belongs to its original
            // caller. Do not replace that dialog or broaden its frozen targets.
            if (app.workspace.confirming_id != null or app.workspace.model.window_close != null) return;
            const index = app.workspace.tabIndexById(tab.tab_id) orelse return;
            task.close_presented = true;
            app.workspace.requestCloseTab(index);
            return;
        }
        task.phase = .closed;
        task.decision = null;
    }
    fn refreshPhase(task: *Task) void {
        if (task.receipt == null or task.decision != null or task.phase == .kept) return;
        var open: usize = 0;
        var asking = false;
        var closing = false;
        var retained = false;
        var unknown = false;
        for (task.resources.items) |resource| {
            if (resource.state == .closed or resource.state == .cancelled or resource.state == .failed) continue;
            open += 1;
            asking = asking or (resource.ownership == .created_task and resource.retention == .ask);
            closing = closing or resource.state == .closing or resource.state == .failed_cleanup_pending;
            unknown = unknown or resource.state == .cleanup_pending;
            retained = retained or resource.ownership != .created_task or resource.retention == .keep or resource.idle != .confirmed;
        }
        task.phase = if (task.resources.items.len == 0) .finished else if (open == 0) .closed else if (unknown) .cleanup_pending else if (asking) .choice else if (closing) .closing else if (retained) .retained else .settling;
    }
    fn publish(task: *Task) void {
        var hash = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hash, task.phase);
        std.hash.autoHash(&hash, task.context.binding);
        std.hash.autoHash(&hash, task.context.binding_revision);
        std.hash.autoHash(&hash, task.active_executions);
        std.hash.autoHash(&hash, task.remote_effect_unknown);
        std.hash.autoHash(&hash, task.pending_control);
        std.hash.autoHash(&hash, task.takeover_requested);
        std.hash.autoHash(&hash, task.stop_sent);
        std.hash.autoHash(&hash, task.model_ended);
        for (task.targets.items) |target| {
            std.hash.autoHash(&hash, target.handle);
            std.hash.autoHash(&hash, target.execution_id);
            std.hash.autoHash(&hash, target.input_epoch);
            hash.update(target.label());
        }
        if (task.feedback) |feedback| hash.update(feedback);
        for (task.resources.items) |resource| {
            std.hash.autoHash(&hash, resource.handle);
            std.hash.autoHash(&hash, resource.ownership_revision);
            std.hash.autoHash(&hash, resource.ownership);
            std.hash.autoHash(&hash, resource.retention);
            std.hash.autoHash(&hash, resource.state);
            std.hash.autoHash(&hash, resource.idle);
            hash.update(resource.label());
        }
        const fingerprint = hash.final();
        if (task.fingerprint == null or task.fingerprint.? != fingerprint) {
            task.fingerprint = fingerprint;
            task.revision +|= 1;
        }
    }
    pub fn tick(self: *Controller, app: *Application, execution: ?ExecutionSource, gates: GatesProvider) !bool {
        var pending = false;
        for (self.tasks.items) |*task| {
            try self.harvest(task, app);
            if (task.receipt == null) try self.readTargets(task, app, execution);
            if (task.pending_control) |action| {
                const source = execution orelse return error.ExecutionUnavailable;
                if (action == .takeover) {
                    if (!task.takeover_sent) {
                        const target = task.pending_target orelse return error.TargetSelectionRequired;
                        try self.control_events.ensureUnusedCapacity(self.allocator, 2);
                        if (source.takeover_execution) |call| call(source.context, task.context, target.execution_id) catch {
                            pending = true;
                            continue;
                        } else return error.TakeoverUnavailable;
                        task.takeover_sent = true;
                        self.control_events.appendAssumeCapacity(.{ .context = task.context, .handle = target.handle, .execution_id = target.execution_id, .phase = .requested });
                    }
                    // The execution controller's accepted exact target invokes
                    // Backend.handedToUser. Queue admission must not hand over
                    // unrelated idle resources or pre-change its fenced scope.
                    task.feedback = "已请求接管；输入释放前仍由执行器保护";
                } else {
                    app.cancelOwnedTask(task.context.task_id);
                    source.stop(source.context, task.context) catch {
                        pending = true;
                        continue;
                    };
                    task.stop_sent = true;
                    task.feedback = "已请求停止，正在等待真实执行与输入释放";
                }
                task.pending_control = null;
            }
            if (task.receipt == null) {
                if (task.model_ended and task.outcome == .cancelled and !task.stop_sent and !task.takeover_requested) {
                    app.cancelOwnedTask(task.context.task_id);
                    if (execution) |source| source.stop(source.context, task.context) catch {
                        pending = true;
                        continue;
                    };
                    task.stop_sent = true;
                }
                if (task.model_ended and !task.finish_sent) {
                    if (execution) |source| source.finish_model(source.context, task.context) catch {
                        pending = true;
                        continue;
                    };
                    task.finish_sent = true;
                }
                const evidence: ExecutionEvidence = if (execution) |source| source.evidence(source.context, task.context.task_id) orelse {
                    pending = true;
                    continue;
                } else .{ .conversation_id = task.context.conversation_id, .task_id = task.context.task_id, .model_done = true, .executions_settled = true, .input_grants_released = true, .recordings_settled = true };
                if (!evidence.conversation_id.eql(task.context.conversation_id) or !evidence.task_id.eql(task.context.task_id)) return error.ScopeChanged;
                task.active_executions = evidence.active_executions + evidence.awaiting_input;
                task.remote_effect_unknown = evidence.remote_effect_unknown;
                if (task.takeover_sent) if (task.pending_target) |target| {
                    const input_fact = if (execution) |owner| if (owner.input_evidence) |read| read(owner.context, task.context, target.execution_id) else targetInputEvidence(app, target) else null;
                    if (input_fact) |input_state| {
                        if (input_state.target.eql(target.handle) and input_state.execution_id.eql(target.execution_id)) {
                            if (input_state.released()) {
                                try self.control_events.append(self.allocator, .{ .context = task.context, .handle = target.handle, .execution_id = target.execution_id, .phase = .released });
                                task.takeover_requested = false;
                                task.takeover_sent = false;
                                task.pending_target = null;
                                task.feedback = "终端输入已交给用户；AI 回合继续，可只读原执行或使用其他终端";
                            } else if (input_state.terminal and !input_state.input_handed_off) {
                                task.takeover_requested = false;
                                task.takeover_sent = false;
                                task.pending_target = null;
                                task.feedback = "原执行已结束，接管未生效；请重新选择当前终端";
                            }
                        }
                    }
                };
                if (!task.model_ended) {
                    task.phase = if (task.takeover_requested or task.stop_sent) .settling else .working;
                    pending = pending or task.active_executions > 0 or task.pending_control != null or task.takeover_requested;
                    publish(task);
                    continue;
                }
                const gate = gates.read(gates.context, task.context) orelse {
                    task.phase = .settling;
                    pending = true;
                    publish(task);
                    continue;
                };
                if (!evidence.settled() or !gate.settled()) {
                    task.phase = if (task.active_executions > 0) .working else .settling;
                    pending = true;
                    publish(task);
                    continue;
                }
                task.receipt = app.finishOwnedTask(task.context.task_id, .{ .provider_finished = true, .pending_tool_slots = false, .pending_approval = false, .pending_dispatch = false, .executions_settled = true, .input_grants_released = true, .cleanup_transferred = true, .model_done = task.outcome == .completed, .failed = task.outcome == .failed, .cancelled = task.outcome == .cancelled, .remote_effect_unknown = evidence.remote_effect_unknown, .pending_external_jobs = evidence.pending_external_jobs }) catch |err| switch (err) {
                    error.TaskStillActive => {
                        task.phase = .settling;
                        pending = true;
                        publish(task);
                        continue;
                    },
                    else => return err,
                };
            }
            try self.applyDecision(task, app);
            try self.harvest(task, app);
            refreshPhase(task);
            publish(task);
            pending = pending or task.phase == .closing or task.phase == .settling;
        }
        return pending;
    }
};

pub const Callbacks = struct { context: *anyopaque, on_decision: *const fn (*anyopaque, identity.TaskId, u64, Decision) anyerror!void, on_control: ?*const fn (*anyopaque, identity.TaskId, u64, Control) anyerror!void = null, on_control_target: ?*const fn (*anyopaque, identity.TaskId, u64, identity.SessionHandle, identity.ExecutionId) anyerror!void = null };
pub const View = struct {
    cx: *ui.Cx,
    root: *ui.Node,
    content: *ui.Node,
    title: *ui.Node,
    detail: *ui.Node,
    resources: *ui.Node,
    resources_viewport: *ui.Node,
    keep_button: *ui.Node,
    close_button: *ui.Node,
    stop_button: *ui.Node = undefined,
    takeover_button: *ui.Node = undefined,
    actions: *ui.Node,
    icon: *ui.Node,
    disabled: *ui.Signal(bool),
    keep_style: *ui.Signal(@FieldType(ui.widgets.ControlShellConfig, "style")),
    close_style: *ui.Signal(@FieldType(ui.widgets.ControlShellConfig, "style")),
    colors: theme.Colors,
    callbacks: Callbacks,
    task_id: ?identity.TaskId = null,
    conversation_id: ?identity.ConversationId = null,
    revision: u64 = 0,
    target_count: usize = 0,
    targets: [64]InputTarget = undefined,
    menu_items: [2][64]ui.widgets.MenuItem = undefined,
    menu_labels: [2][64][128]u8 = undefined,
    menu_ids: [2][64][8]u8 = undefined,
    menu_test_ids: [64][80]u8 = undefined,
    menu_version: u1 = 0,
    menu_open: *ui.Signal(bool) = undefined,
    menu_source: *ui.Signal([]const ui.widgets.MenuItem) = undefined,
    menu_state: ?*ui.widgets.MenuState = null,
    menu_scope: *ui.Scope = undefined,
    menu_wrapper: ?*ui.Node = null,
    menu_height: f32 = 0,
    menu_task: ?identity.TaskId = null,
    menu_conversation: ?identity.ConversationId = null,
    menu_revision: u64 = 0,
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, callbacks: Callbacks) !*View {
        const self = try scope.createState(View, .{ .cx = cx, .root = undefined, .content = undefined, .title = undefined, .detail = undefined, .resources = undefined, .resources_viewport = undefined, .keep_button = undefined, .close_button = undefined, .actions = undefined, .icon = undefined, .disabled = try scope.createSignal(bool, false), .keep_style = try scope.createSignal(@FieldType(ui.widgets.ControlShellConfig, "style"), styles.button(false)), .close_style = try scope.createSignal(@FieldType(ui.widgets.ControlShellConfig, "style"), styles.button(true)), .colors = theme.current(), .callbacks = callbacks });
        self.root = try ui.boxStyled(cx, styles.row, .{});
        self.root.meta.ownership.meta.test_id = "ai.task_finish";
        self.root.setDisplay(.none);
        self.content = try ui.box(cx, .{ .width = .fill(), .min_width = 0, .flex = 1, .direction = .row, .align_items = .center, .gap = 7 }, .{});
        try self.root.appendChild(cx.allocator, self.content);
        self.icon = try ui.iconTint(cx, ui.icons.check, theme.current().ok_ink, .{ .width = .{ .px = 15 }, .height = .{ .px = 15 }, .flex_shrink = 0 });
        try self.content.appendChild(cx.allocator, self.icon);
        const body = try ui.box(cx, .{ .width = .fill(), .min_width = 0, .flex = 1, .direction = .column, .gap = 1 }, .{});
        try self.content.appendChild(cx.allocator, body);
        self.title = try ui.textStyled(cx, styles.title, "任务已结束");
        self.title.meta.ownership.meta.test_id = "ai.task_finish.title";
        try body.appendChild(cx.allocator, self.title);
        const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical, .rubber_band_y = false }).mount(scope, cx);
        self.resources_viewport = scroll.container;
        scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 16 }, .max_height = 80, .flex_shrink = 0 });
        scroll.container.meta.ownership.meta.test_id = "ai.task_finish.resources_viewport";
        self.resources = try ui.textStyled(cx, styles.secondary, "");
        self.resources.setStyleInline(cx.allocator, .{ .width = .fill(), .flex_shrink = 0 });
        self.resources.meta.ownership.meta.test_id = "ai.task_finish.resources";
        try scroll.content.appendChild(cx.allocator, self.resources);
        try body.appendChild(cx.allocator, scroll.container);
        self.detail = try ui.textStyled(cx, styles.secondary, "原会话与会话组保持打开");
        self.detail.setStyleInline(cx.allocator, .{ .width = .fill(), .flex_shrink = 0 });
        self.detail.meta.ownership.meta.test_id = "ai.task_finish.detail";
        try body.appendChild(cx.allocator, self.detail);
        self.actions = try ui.box(cx, .{ .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0 }, .{});
        try self.root.appendChild(cx.allocator, self.actions);
        self.keep_button = try ui.widgets.Button(.{ .label = "交给我保留", .variant = .secondary, .base_style = self.keep_style, .disabled = self.disabled, .on_click = cx.on(View, self, keep) }).mount(scope, cx);
        self.keep_button.meta.ownership.meta.test_id = "ai.task_finish.keep";
        self.close_button = try ui.widgets.Button(.{ .label = "关闭任务会话", .variant = .secondary, .base_style = self.close_style, .disabled = self.disabled, .on_click = cx.on(View, self, close) }).mount(scope, cx);
        self.close_button.meta.ownership.meta.test_id = "ai.task_finish.close";
        try self.actions.appendChild(cx.allocator, self.keep_button);
        try self.actions.appendChild(cx.allocator, self.close_button);
        self.stop_button = try ui.widgets.Button(.{ .label = "停止执行", .variant = .secondary, .base_style = self.keep_style, .disabled = self.disabled, .on_click = cx.on(View, self, stop) }).mount(scope, cx);
        self.stop_button.meta.ownership.meta.test_id = "ai.task_finish.stop";
        self.takeover_button = try ui.widgets.Button(.{ .label = "接管终端", .variant = .secondary, .base_style = self.close_style, .disabled = self.disabled, .on_click = cx.on(View, self, takeover) }).mount(scope, cx);
        self.takeover_button.meta.ownership.meta.test_id = "ai.task_finish.takeover";
        try self.actions.appendChild(cx.allocator, self.stop_button);
        self.menu_open = try scope.createSignal(bool, false);
        self.menu_source = try scope.createSignal([]const ui.widgets.MenuItem, &.{});
        self.menu_scope = scope;
        try self.rebuildMenu(72);
        try scope.onCleanup(View, self, cleanup);
        try cx.addAfterLayoutHook(self, afterLayout);
        return self;
    }
    /// Menu's fit_or_scroll height is a mount-time native property. Rebuild
    /// only its wrapper at a safe update, preserving the existing button and
    /// its recipe/scope; 32px rows + 4px list padding on each side.
    fn rebuildMenu(self: *View, panel_height: f32) !void {
        if (panel_height == self.menu_height) return;
        const menu = try ui.widgets.Menu(.{ .trigger = .manual, .items = self.menu_source, .open = self.menu_open, .on_select = self.cx.on(View, self, selectTarget), .width = 280, .max_height = panel_height, .position = .bottom_end }).mount(self.menu_scope, self.cx);
        errdefer self.cx.destroyDetached(menu.wrapper);
        try menu.trigger.children.ensureUnusedCapacity(self.cx.allocator, 1);
        try self.actions.children.ensureUnusedCapacity(self.cx.allocator, 1);
        self.cancelOwnPress();
        try menu.trigger.appendChild(self.cx.allocator, self.takeover_button);
        try self.actions.appendChild(self.cx.allocator, menu.wrapper);
        if (self.menu_wrapper) |previous| {
            self.cx.detachChild(self.actions, previous);
            self.cx.destroyDetached(previous);
        }
        self.menu_wrapper = menu.wrapper;
        self.menu_state = @ptrCast(@alignCast(menu.wrapper.meta.ownership.debug_slots.state_ptrs[0].?));
        self.menu_height = panel_height;
    }
    fn cleanup(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        if (self.root.style.display == .none or self.root.globalRect().w == 0) return .done;
        // Zenit's wrap layout gives grow children zero main size. Preserve the
        // HTML's 180px text minimum by moving the complete actions below the
        // icon/text row at the actual measured width instead.
        const compact = self.actions.style.display != .none and self.root.globalRect().w < 22 + 15 + 7 + 180 + 7 + self.actions.globalRect().w;
        const direction: ui.Direction = if (compact) .column else .row;
        var dirty = false;
        if (self.menu_state) |state| {
            if (state.menu_node) |node| node.meta.ownership.meta.test_id = "ai.task_finish.takeover.menu";
            for (state.item_nodes[0..state.item_count], 0..) |item, i| if (item) |node| {
                if (i < self.target_count) node.meta.ownership.meta.test_id = std.fmt.bufPrint(&self.menu_test_ids[i], "ai.task_finish.takeover.target.{d}", .{@backingInt(self.targets[i].handle.session_id)}) catch unreachable;
            };
        }
        if (self.root.style.direction != direction) {
            self.root.setStyle(self.cx.allocator, .direction, direction);
            self.content.setStyleInline(self.cx.allocator, .{ .flex = if (compact) 0 else 1, .flex_shrink = 0 });
            self.actions.setStyle(self.cx.allocator, .align_self, if (compact) .end else .center);
            dirty = true;
        }
        const content_height = std.math.clamp(self.resources.globalRect().h, 16, 80);
        if (@abs(self.resources_viewport.globalRect().h - content_height) > 0.5) {
            self.resources_viewport.setStyle(self.cx.allocator, .height, .{ .px = content_height });
            dirty = true;
        }
        return if (dirty) .needs_layout else .done;
    }
    pub fn height(self: *const View) f32 {
        return if (self.root.style.display == .none) 0 else self.root.globalRect().h;
    }
    pub fn update(self: *View, source: ?Snapshot) !void {
        const snapshot = source orelse {
            self.cancelOwnPress();
            self.root.setDisplay(.none);
            self.task_id = null;
            return;
        };
        if (!snapshot.visible) {
            self.cancelOwnPress();
            self.root.setDisplay(.none);
            self.task_id = null;
            return;
        }
        if (self.task_id != null and self.task_id.?.eql(snapshot.context.task_id) and self.conversation_id != null and self.conversation_id.?.eql(snapshot.context.conversation_id) and self.revision == snapshot.revision and std.meta.eql(self.colors, theme.current())) return;
        if (self.task_id == null or !self.task_id.?.eql(snapshot.context.task_id) or self.conversation_id == null or !self.conversation_id.?.eql(snapshot.context.conversation_id) or self.revision != snapshot.revision) self.cancelOwnPress();
        self.colors = theme.current();
        self.keep_style.set(styles.button(false));
        self.close_style.set(styles.button(true));
        self.task_id = snapshot.context.task_id;
        self.conversation_id = snapshot.context.conversation_id;
        self.revision = snapshot.revision;
        self.disabled.set(snapshot.control_pending);
        self.menu_open.set(false);
        self.target_count = @min(snapshot.targets.len, self.targets.len);
        try self.rebuildMenu(@min(220, @as(f32, @floatFromInt(@max(2, self.target_count))) * 32 + 8));
        @memcpy(self.targets[0..self.target_count], snapshot.targets[0..self.target_count]);
        self.menu_version ^= 1;
        const menu_index: usize = self.menu_version;
        for (self.targets[0..self.target_count], 0..) |target, i| {
            self.menu_items[menu_index][i] = .{ .id = try std.fmt.bufPrint(&self.menu_ids[menu_index][i], "{d}", .{i}), .label = try std.fmt.bufPrint(&self.menu_labels[menu_index][i], "{s} · session-{d}", .{ target.label(), @backingInt(target.handle.session_id) }), .icon_asset = ui.icons.terminal };
        }
        self.menu_source.set(self.menu_items[menu_index][0..self.target_count]);
        self.root.setDisplay(.flex);
        self.root.setBackground(theme.popupInset());
        self.title.setTextColor(theme.current().fg_1);
        self.detail.setTextColor(theme.current().fg_2);
        self.resources.setTextColor(theme.current().fg_2);
        const glyph = if (snapshot.phase == .working or snapshot.phase == .settling or snapshot.phase == .closing) ui.icons.clock else if (snapshot.phase == .cleanup_pending) ui.icons.circle_help else ui.icons.check;
        if (glyph.icon_id) |id| if (glyph.pickRep(15)) |rep| self.icon.setIcon(.{ .icon_id = id, .rep = rep, .tint = if (snapshot.phase == .working or snapshot.phase == .settling or snapshot.phase == .closing) theme.current().accent else if (snapshot.phase == .cleanup_pending) theme.current().warn_ink else theme.current().ok_ink });
        const title: []const u8 = switch (snapshot.phase) {
            .working => "执行仍在进行",
            .settling => "正在收尾",
            .choice, .finished => "任务已结束",
            .closing => "正在关闭任务会话",
            .kept => "已保留任务会话",
            .retained => "任务会话已保留",
            .closed => "已清理任务会话",
            .cleanup_pending => "清理待核实",
        };
        try self.title.setTextContent(self.cx.allocator, title);
        var list: std.Io.Writer.Allocating = .init(self.cx.allocator);
        defer list.deinit();
        for (snapshot.resources, 0..) |resource, index| {
            if (index > 0) try list.writer.writeAll("\n");
            try list.writer.print("{s} · {s}", .{ resource.label(), if (resource.state == .closed) @as([]const u8, "已关闭，记录保留") else if (resource.ownership == .handed_to_user) "已交给用户" else if (resource.state == .closing) "正在关闭" else if (resource.state == .cleanup_pending or resource.state == .failed_cleanup_pending) "关闭结果待核实" else switch (resource.idle) {
                .confirmed => "已确认空闲",
                .active => "仍有活动引用",
                .unknown => "空闲状态尚未确认",
            } });
        }
        if (snapshot.resources.len == 0) {
            for (snapshot.targets, 0..) |target, i| {
                if (i != 0) try list.writer.writeAll("\n");
                try list.writer.print("{s} · session-{d} · AI 输入", .{ target.label(), @backingInt(target.handle.session_id) });
            }
            if (snapshot.targets.len == 0) try list.writer.writeAll(if (snapshot.feedback != null) "原执行仍可只读，终端保持打开" else "执行与输入授权尚未结算");
        }
        try self.resources.setTextContent(self.cx.allocator, list.writer.buffered());
        self.resources_viewport.setStyle(self.cx.allocator, .height, .{ .px = @floatFromInt(@as(usize, @min(@max(@as(usize, 1), snapshot.resources.len), 5)) * 16) });
        const detail = snapshot.feedback orelse if (snapshot.phase == .working) (if (snapshot.model_done) "模型答复已结束，前台执行继续运行" else "执行正在运行；可停止或接管终端") else if (snapshot.phase == .cleanup_pending) "关闭结果待核实，未标记已清理" else if (snapshot.remote_effect_unknown) "远端效果未知；原会话与会话组保持打开" else if (snapshot.phase == .choice) "只处理本任务创建的终端；原会话与组保持打开" else "原会话与会话组保持打开";
        try self.detail.setTextContent(self.cx.allocator, detail);
        const can_control = snapshot.phase == .working and snapshot.active_executions > 0 and self.callbacks.on_control != null;
        self.keep_button.setDisplay(if (snapshot.phase == .choice) .flex else .none);
        self.close_button.setDisplay(if (snapshot.phase == .choice) .flex else .none);
        self.stop_button.setDisplay(if (can_control) .flex else .none);
        self.takeover_button.setDisplay(if (can_control and self.target_count > 0) .flex else .none);
        self.actions.setDisplay(if (snapshot.phase == .choice or can_control) .flex else .none);
        self.cx.requestRedraw();
    }
    fn choose(self: *View, decision: Decision) void {
        const task = self.task_id orelse return;
        if (self.disabled.peek()) return;
        self.callbacks.on_decision(self.callbacks.context, task, self.revision, decision) catch |err| {
            self.detail.setTextContent(self.cx.allocator, if (err == error.ScopeChanged) "终端状态已变化，请重新查看后选择" else "处理未完成，请稍后重试") catch {};
            return;
        };
        self.disabled.set(true);
        self.cx.requestRedraw();
    }
    fn cancelOwnPress(self: *View) void {
        var node = self.cx.dispatcher.mouseDownNode();
        while (node) |current| : (node = current.parent) {
            if (current == self.root or (self.menu_state != null and self.menu_state.?.menu_node == current)) {
                self.cx.cancelPointerInteractions(.explicit);
                return;
            }
        }
    }
    fn keep(self: *View) void {
        self.choose(.keep);
    }
    fn close(self: *View) void {
        self.choose(.close);
    }
    fn chooseControl(self: *View, action: Control) void {
        if (self.disabled.peek()) return;
        const task = self.task_id orelse return;
        const callback = self.callbacks.on_control orelse return;
        callback(self.callbacks.context, task, self.revision, action) catch |err| {
            self.detail.setTextContent(self.cx.allocator, if (err == error.ScopeChanged) "执行状态已变化，请重新查看" else "请求尚未接纳，请稍后重试") catch {};
            return;
        };
        self.disabled.set(true);
        self.cx.requestRedraw();
    }
    fn stop(self: *View) void {
        self.chooseControl(.stop);
    }
    fn takeover(self: *View) void {
        if (self.disabled.peek() or self.target_count == 0) return;
        if (self.target_count == 1) return self.chooseTarget(0);
        self.menu_task = self.task_id;
        self.menu_conversation = self.conversation_id;
        self.menu_revision = self.revision;
        self.menu_open.set(true);
        self.cx.requestRedraw();
    }
    fn selectTarget(self: *View, id: []const u8) void {
        if (self.menu_task == null or self.task_id == null or !self.menu_task.?.eql(self.task_id.?) or self.menu_conversation == null or self.conversation_id == null or !self.menu_conversation.?.eql(self.conversation_id.?) or self.menu_revision != self.revision) return;
        self.chooseTarget(std.fmt.parseInt(usize, id, 10) catch return);
    }
    fn chooseTarget(self: *View, index: usize) void {
        if (self.disabled.peek() or index >= self.target_count) return;
        const task = self.task_id orelse return;
        const target = self.targets[index];
        if (self.callbacks.on_control_target) |callback| {
            callback(self.callbacks.context, task, self.revision, target.handle, target.execution_id) catch {
                self.detail.setTextContent(self.cx.allocator, "终端输入状态已变化，请重新查看后选择") catch {};
                return;
            };
            self.disabled.set(true);
            self.cx.requestRedraw();
        } else if (self.target_count == 1) self.chooseControl(.takeover);
    }
};

test "task finish requires execution input recording and reference evidence" {
    const context: host.Context = .{ .conversation_id = .generate(), .task_id = .generate(), .binding = .{ .session = 5 }, .binding_revision = 1, .grant_revision = 1 };
    var evidence: ExecutionEvidence = .{ .conversation_id = context.conversation_id, .task_id = context.task_id, .model_done = true, .execution_count = 1, .active_executions = 1, .executions_settled = false, .input_grants_released = false };
    try std.testing.expect(!evidence.settled());
    evidence.active_executions = 0;
    evidence.executions_settled = true;
    evidence.input_grants_released = true;
    try std.testing.expect(!evidence.settled());
    evidence.recordings_settled = true;
    try std.testing.expect(evidence.settled());
    // Attribution limits affect resource close eligibility, while a saved
    // interval and released input can settle this Task's control responsibility.
    evidence.output_attribution_unverified = true;
    try std.testing.expect(evidence.settled() and !evidence.remote_effect_unknown);
    try std.testing.expect(!(Gates{}).settled());
    try std.testing.expect((Gates{ .resource_references_transferred = true }).settled());
    var controller = Controller.init(std.testing.allocator);
    defer controller.deinit();
    try controller.modelEnded(context, .completed);
    try controller.modelEnded(context, .completed);
    try std.testing.expectEqual(@as(usize, 1), controller.tasks.items.len);
    try std.testing.expect(controller.receiptFor(context) == null);
    try std.testing.expectError(error.ScopeChanged, controller.decide(context.task_id, 1, .keep));
}

test "task finish native choice actions fit compact widths and working has no close action" {
    const a = std.testing.allocator;
    const original = theme.currentName();
    defer theme.select(original);
    for ([_]theme.Name{ .dark, .light, .sauber }) |name| {
        theme.select(name);
        const cx = try ui.Cx.init(a, std.testing.io);
        defer cx.deinit();
        cx.setTheme(theme.widgetTheme(name));
        const scope = try ui.Scope.init(a, null, cx.owner);
        defer scope.dispose();
        cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
        const Capture = struct {
            count: usize = 0,
            choice: ?Decision = null,
            controls: usize = 0,
            last_control: ?Control = null,
            fn choose(raw: *anyopaque, _: identity.TaskId, _: u64, decision: Decision) !void {
                const self: *@This() = @ptrCast(@alignCast(raw));
                self.count += 1;
                self.choice = decision;
            }
            fn control(raw: *anyopaque, _: identity.TaskId, _: u64, action: Control) !void {
                const self: *@This() = @ptrCast(@alignCast(raw));
                self.controls += 1;
                self.last_control = action;
            }
        };
        var captured: Capture = .{};
        const view = try View.mount(cx, scope, .{ .context = &captured, .on_decision = Capture.choose, .on_control = Capture.control });
        try cx.root.?.appendChild(a, view.root);
        var resource: Resource = .{ .handle = .{ .session_id = @fromBackingInt(6) }, .ownership_revision = 1, .ownership = .created_task, .retention = .ask, .state = .ready };
        resource.setName("Local Terminal");
        var target: InputTarget = .{ .handle = resource.handle, .execution_id = .generate() };
        target.setName("Local Terminal");
        var snapshot: Snapshot = .{ .context = .{ .conversation_id = .generate(), .task_id = .generate(), .binding = .{ .group = 3 }, .binding_revision = 1, .grant_revision = 1 }, .revision = 1, .phase = .choice, .resources = &.{resource}, .active_executions = 0, .remote_effect_unknown = false, .feedback = null, .visible = true };
        snapshot.targets = &.{target};
        for ([_]f32{ 600, 360 }) |width| {
            cx.setViewport(width, 240);
            snapshot.revision += 1;
            try view.update(snapshot);
            for (0..4) |_| {
                cx.advanceFrameClock();
                cx.layout();
                _ = cx.render();
                _ = View.afterLayout(view, 0, false);
            }
            try std.testing.expect(view.title.globalRect().w >= 180);
            try std.testing.expect(view.resources.globalRect().w >= 180);
            for ([_]*ui.Node{ view.keep_button, view.close_button }) |button| {
                const rect = button.globalRect();
                try std.testing.expect(rect.x >= 0 and rect.x + rect.w <= width + 0.5);
                try std.testing.expectApproxEqAbs(@as(f32, 28), rect.h, 0.1);
                try std.testing.expect(rect.y + rect.h <= view.root.globalRect().h + 0.5);
            }
        }
        const button = view.keep_button.globalRect();
        cx.handleMouseDown(button.x + button.w / 2, button.y + button.h / 2, .{});
        cx.handleMouseUp(button.x + button.w / 2, button.y + button.h / 2);
        try std.testing.expectEqual(@as(usize, 1), captured.count);
        try std.testing.expectEqual(Decision.keep, captured.choice.?);
        snapshot.phase = .working;
        snapshot.active_executions = 1;
        snapshot.revision += 1;
        try view.update(snapshot);
        try std.testing.expectEqualStrings("执行仍在进行", view.title.getText().?.content);
        try std.testing.expect(view.close_button.style.display == .none);
        try std.testing.expect(view.keep_button.style.display == .none);
        for ([_]Control{ .stop, .takeover }) |action| {
            snapshot.revision += 1;
            try view.update(snapshot);
            for (0..4) |_| {
                cx.advanceFrameClock();
                cx.layout();
                _ = cx.render();
                _ = View.afterLayout(view, 0, false);
            }
            const control_button = if (action == .stop) view.stop_button else view.takeover_button;
            const rect = control_button.globalRect();
            try std.testing.expect(rect.w > 0 and rect.x + rect.w <= 360.5);
            cx.handleMouseDown(rect.x + rect.w / 2, rect.y + rect.h / 2, .{});
            cx.handleMouseUp(rect.x + rect.w / 2, rect.y + rect.h / 2);
            try std.testing.expectEqual(action, captured.last_control.?);
        }
        try std.testing.expectEqual(@as(usize, 2), captured.controls);
        snapshot.revision += 1;
        try view.update(snapshot);
        cx.layout();
        const old_press = view.stop_button.globalRect();
        cx.handleMouseDown(old_press.x + old_press.w / 2, old_press.y + old_press.h / 2, .{});
        snapshot.context.task_id = .generate();
        snapshot.context.conversation_id = .generate();
        try view.update(snapshot);
        cx.handleMouseUp(old_press.x + old_press.w / 2, old_press.y + old_press.h / 2);
        try std.testing.expectEqual(@as(usize, 2), captured.controls);
    }
}

test "task finish task registration advances legal binding without losing takeover intent" {
    var controller = Controller.init(std.testing.allocator);
    defer controller.deinit();
    const initial: host.Context = .{ .conversation_id = .generate(), .task_id = .generate(), .binding = .{ .session = 4 }, .binding_revision = 1, .grant_revision = 3 };
    try controller.registerTask(initial);
    try std.testing.expect(!controller.snapshotFor(initial).?.model_done);
    var grouped = initial;
    grouped.binding = .{ .group = 8 };
    grouped.binding_revision = 2;
    try controller.registerTask(grouped);
    try std.testing.expectEqual(@as(u64, 2), controller.snapshotFor(grouped).?.context.binding_revision);
    try std.testing.expectError(error.ScopeChanged, controller.registerTask(initial));
    var changed_grant = grouped;
    changed_grant.grant_revision += 1;
    try std.testing.expectError(error.ScopeChanged, controller.registerTask(changed_grant));
    controller.find(grouped.task_id).?.active_executions = 1;
    try controller.find(grouped.task_id).?.targets.append(std.testing.allocator, .{ .handle = .{ .session_id = @fromBackingInt(4) }, .execution_id = .generate() });
    try controller.control(grouped.task_id, controller.snapshotFor(grouped).?.revision, .takeover);
    try controller.modelEnded(grouped, .cancelled);
    try std.testing.expect(controller.find(grouped.task_id).?.takeover_requested);
    try std.testing.expect(!controller.find(grouped.task_id).?.stop_sent);
    try std.testing.expectEqual(Control.takeover, controller.find(grouped.task_id).?.pending_control.?);
    var next = grouped;
    next.task_id = .generate();
    try controller.registerTask(next);
    controller.find(next.task_id).?.active_executions = 1;
    var buffer: [2]Snapshot = undefined;
    const visible = try controller.snapshotsForConversation(grouped.conversation_id, &buffer);
    try std.testing.expectEqual(@as(usize, 2), visible.len);
    try std.testing.expect(visible[0].context.task_id.eql(grouped.task_id));
    try std.testing.expect(visible[1].context.task_id.eql(next.task_id));
    try std.testing.expectError(error.OutputTooSmall, controller.snapshotsForConversation(grouped.conversation_id, buffer[0..1]));
    try std.testing.expectEqual(@as(usize, 0), (try controller.snapshotsForConversation(.generate(), &buffer)).len);
}

test "task status does not call an idle owned terminal a running execution" {
    const a = std.testing.allocator;
    var controller = Controller.init(a);
    defer controller.deinit();
    const context: host.Context = .{ .conversation_id = .generate(), .task_id = .generate(), .binding = .{ .session = 1 }, .binding_revision = 1, .grant_revision = 1 };
    try controller.registerTask(context);
    const task = controller.find(context.task_id).?;
    try task.resources.append(a, .{ .handle = .{ .session_id = @fromBackingInt(7), .generation = 1 }, .ownership_revision = 1, .ownership = .created_task, .retention = .auto_idle, .state = .ready });
    try std.testing.expect(!controller.snapshotFor(context).?.visible);
    task.active_executions = 1;
    try std.testing.expect(controller.snapshotFor(context).?.visible);
    task.active_executions = 0;
    task.phase = .retained;
    try std.testing.expect(controller.snapshotFor(context).?.visible);
}
