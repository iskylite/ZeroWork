//! UI-thread authority adapter for the background execution driver. Only
//! bounded live metadata is read here; approval waits and journal IO stay on
//! their workers. Neither UI focus nor a discovered reference grants input.
const std = @import("std");
const identity = @import("../host/identity.zig");
const terminal = @import("../host/terminal_service.zig");
const execution = terminal.execution;
const host = @import("../ai/host_tools.zig");
const supervisor = @import("../ai/host_execution.zig");
const approvals = @import("../ai/host_approval.zig");
const canonical = @import("../ai/canonical_arguments.zig");
const config = @import("../config/config.zig");
const Application = @import("application_host.zig").ApplicationHost;
const Controller = @import("ai_lifecycle_controller.zig").Controller;
const Store = @import("../ai/assistant_store.zig").Store;
const Roster = @import("group_model.zig").Roster;
const Content = @import("../host/content_context.zig");
const Window = @import("plugin_window_host.zig").Host;
const capacity = 128;

pub const Prepared = struct {
    arena: std.heap.ArenaAllocator,
    invocation: host.Invocation,
    command: []const u8,
    command_hash: [32]u8,
    subject: approvals.Subject,
    pub fn deinit(self: *Prepared) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
/// Worker-only normalization. The owned JSON changes only the normalized
/// command/canonical hash. Raw provider JSON, wire hash, call and operation IDs
/// remain the original correlation evidence shown on the real tool call.
pub fn prepare(invocation: host.Invocation, allocator: std.mem.Allocator) !Prepared {
    try invocation.context.validate();
    try validateRun(invocation);
    if (!std.mem.eql(u8, &execution.digest(invocation.arguments_json), &invocation.arguments_hash)) return error.InvalidArguments;
    const original_hash = try canonical.digest(allocator, invocation.arguments);
    if (!std.mem.eql(u8, &original_hash, &invocation.canonical_arguments_hash)) return error.InvalidArguments;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, a, invocation.arguments_json, .{ .allocate = .alloc_always });
    const parsed_hash = try canonical.digest(a, parsed.value);
    if (!std.mem.eql(u8, &parsed_hash, &original_hash)) return error.InvalidArguments;
    const command = try execution.normalizeCommand(a, try string(invocation.arguments, "command"));
    var normalized = invocation;
    normalized.arguments = parsed.value;
    try normalized.arguments.object.put(a, "command", .{ .string = command });
    normalized.canonical_arguments_hash = try canonical.digest(a, normalized.arguments);
    normalized.approval_sequence = null;
    return .{ .arena = arena, .invocation = normalized, .command = command, .command_hash = execution.digest(command), .subject = subject(normalized, command, "") };
}

pub const ApprovalEvidence = struct {
    bytes: [512]u8 = undefined,
    len: usize = 0,
    pub fn text(self: *const ApprovalEvidence) []const u8 {
        return self.bytes[0..self.len];
    }
};
const Task = struct {
    initial: host.Context,
    config_revision: u64,
    mode: config.ExecutionMode,
    allow_input: bool,
    allow_write: bool,
};
const InputAuthority = struct {
    instance: u64 = 0,
    revision: u64 = 0,
    authorized: bool = false,
    automation: ?Content.Lease = null,
};
const Boundary = struct {
    handle: identity.SessionHandle,
    service: terminal.Service,
    capability_revision: u64,
    ownership_revision: u64,
    membership_revision: u64,
    execution_revision: u64,
    input_epoch: u64,
    next_input: u64,
    input: InputAuthority,
};
const Admission = struct {
    context: host.Context,
    operation_id: u64,
    turn_id: u64,
    call_hash: [32]u8,
    arguments_hash: [32]u8,
    canonical_hash: [32]u8,
    command_hash: [32]u8,
    boundary: Boundary,
    evidence: ApprovalEvidence,
    authorized: bool = false,
    execution_id: ?identity.ExecutionId = null,
    handed_to_user: bool = false,
    cleanup_only: bool = false,
};
pub const Init = struct {
    app: *Application,
    roster: *Roster,
    store: *Store,
    lookup_context: *anyopaque,
    lookup_task: *const fn (*anyopaque, identity.ConversationId, identity.TaskId) ?*Controller,
    approval: *approvals.Broker,
};
pub const Context = struct {
    app: *Application,
    roster: *Roster,
    store: *Store,
    lookup_context: *anyopaque,
    lookup_task: *const fn (*anyopaque, identity.ConversationId, identity.TaskId) ?*Controller,
    approval: *approvals.Broker,
    tasks: [capacity]?Task = @splat(null),
    admissions: [capacity]?Admission = @splat(null),

    pub fn init(options: Init) !Context {
        return .{ .app = options.app, .roster = options.roster, .store = options.store, .lookup_context = options.lookup_context, .lookup_task = options.lookup_task, .approval = options.approval };
    }
    pub fn backend(self: *Context) supervisor.Backend {
        return .{ .context = self, .authorize = authorize, .resolve = resolve, .terminal_call = terminalCall, .handed_to_user = handedToUser };
    }
    /// Trusted UI close acceptance, before releasing the terminal view/native
    /// service. Block future input and return each admitted original Task once;
    /// enqueue Driver.stopTask for these contexts and await its release facts.
    /// This grants only observation/revocation of the already issued execution.
    pub fn beginClose(self: *Context, handle: identity.SessionHandle, out: []host.Context) !usize {
        var count: usize = 0;
        for (self.admissions) |item| if (item) |record| if (record.authorized and record.boundary.handle.eql(handle)) {
            const duplicate = for (out[0..count]) |prior| {
                if (sameTask(prior, record.context)) break true;
            } else false;
            if (!duplicate) {
                if (count == out.len) return error.OutputTooSmall;
                out[count] = record.context;
                count += 1;
            }
        };
        for (&self.admissions) |*item| if (item.*) |*record| if (record.authorized and record.boundary.handle.eql(handle)) {
            record.cleanup_only = true;
        };
        return count;
    }
    /// Call once when configuring this Task, before a subsequent Task reuses
    /// the Bridge. Background executions never inherit that next Task's policy.
    pub fn captureTask(self: *Context, controller: *Controller) !void {
        try controller.authority.validate();
        const policy = controller.bridge.policy;
        const value: Task = .{ .initial = controller.authority, .config_revision = controller.config_revision, .mode = controller.execution_policy.execution_mode, .allow_input = policy.allow_input, .allow_write = policy.allow_write };
        var empty: ?usize = null;
        for (self.tasks, 0..) |item, index| if (item) |task| {
            if (sameTask(task.initial, value.initial)) {
                if (!std.meta.eql(task, value)) return error.ScopeChanged;
                return;
            }
        } else if (empty == null) {
            empty = index;
        };
        self.tasks[empty orelse return error.ExecutionLimit] = value;
    }
    /// UI preflight before publishing the approval card. The returned value
    /// owns its display text. Set Prepared.subject.impact to evidence.text()
    /// while requesting approval on the worker; do not wait here.
    pub fn preflight(self: *Context, invocation: host.Invocation, command: []const u8, hash: [32]u8) !ApprovalEvidence {
        try validateNormalized(invocation, command, hash);
        const controller = try self.current(invocation.context, false);
        const handle = try parseSession(invocation.context, try string(invocation.arguments, "session_ref"));
        const boundary = try self.captureBoundary(controller, handle, true, false);
        try checkForbidden(command);
        const evidence = try describe(invocation.context, boundary);
        const record: Admission = .{ .context = invocation.context, .operation_id = invocation.operation_id, .turn_id = invocation.turn_id, .call_hash = execution.digest(invocation.call_id), .arguments_hash = invocation.arguments_hash, .canonical_hash = invocation.canonical_arguments_hash, .command_hash = hash, .boundary = boundary, .evidence = evidence };
        var empty: ?usize = null;
        for (&self.admissions, 0..) |*item, index| if (item.*) |*prior| {
            if (prior.context.eql(invocation.context) and prior.operation_id == invocation.operation_id) {
                if (prior.authorized) return error.OperationBusy;
                prior.* = record;
                return evidence;
            }
        } else if (empty == null) {
            empty = index;
        };
        self.admissions[empty orelse return error.ExecutionLimit] = record;
        return evidence;
    }
    pub fn validateApproval(self: *Context, invocation: host.Invocation, command: []const u8, hash: [32]u8) !void {
        const record = self.admission(invocation) orelse return error.ApprovalRequired;
        if (!std.mem.eql(u8, &record.command_hash, &hash)) return error.CommandHashMismatch;
        const sequence = invocation.approval_sequence orelse return error.ApprovalRequired;
        const frozen = try self.taskGrant(invocation.context);
        const decision = self.approval.authorizeSubject(.{ .sequence = sequence, .arguments_hash = invocation.arguments_hash }, invocation, subject(invocation, command, record.evidence.text()), frozen.config_revision);
        return switch (decision) {
            .allow => {},
            .approval_required => error.ApprovalRequired,
            .denied => error.PermissionDenied,
            .scope_changed => error.ScopeChanged,
        };
    }
    fn taskGrant(self: *Context, authority: host.Context) !Task {
        for (self.tasks) |item| if (item) |value| if (sameTask(value.initial, authority)) return value;
        return error.TargetNotAuthorized;
    }
    fn current(self: *Context, authority: host.Context, old_execution: bool) !*Controller {
        try authority.validate();
        const frozen = try self.taskGrant(authority);
        const controller = self.lookup_task(self.lookup_context, authority.conversation_id, authority.task_id) orelse return error.TargetNotAuthorized;
        if (!sameTask(controller.authority, authority) or authority.grant_revision != frozen.initial.grant_revision or controller.authority.grant_revision != frozen.initial.grant_revision or controller.config_revision != frozen.config_revision or controller.execution_policy.execution_mode != frozen.mode or self.app.workspace.app_config.config_revision != frozen.config_revision) return error.ScopeChanged;
        if (!frozen.allow_input or !frozen.allow_write) return error.PermissionDenied;
        const state = self.store.findConversation(authority.conversation_id) orelse return error.ConversationNotFound;
        if (state.closed or !state.owner.eql(controller.authority.binding) or state.binding_revision != controller.authority.binding_revision) return error.BindingConflict;
        if (!controller.authority.eql(authority)) {
            if (!old_execution or authority.binding != .session or controller.authority.binding != .group or state.initial_owner == null or !state.initial_owner.?.eql(authority.binding) or authority.binding_revision == std.math.maxInt(u64) or controller.authority.binding_revision != authority.binding_revision + 1) return error.ScopeChanged;
        }
        if (!old_execution) {
            const live = controller.bridge.host_binding orelse return error.ScopeChanged;
            if (!live.context.eql(authority) or controller.bridge.policy_revision != authority.grant_revision or controller.bridge.stopped.load(.acquire) or controller.bridge.policy.allow_input != frozen.allow_input or controller.bridge.policy.allow_write != frozen.allow_write) return error.ScopeChanged;
        }
        if (!old_execution and self.closing()) return error.WorkspaceClosed;
        return controller;
    }
    fn closing(self: *Context) bool {
        return self.app.workspace.shutting_down or self.app.windowClosePending();
    }
    fn membership(self: *Context, controller: *Controller, handle: identity.SessionHandle, legacy: u64) !u64 {
        return switch (controller.authority.binding) {
            .session => |id| if (id == @backingInt(handle.session_id)) 0 else error.TargetOutsideScope,
            .group => |id| blk: {
                const small = std.math.cast(u32, id) orelse return error.StaleReference;
                const group = self.roster.findById(small) orelse return error.StaleReference;
                if (self.app.workspace.groupClosing(small)) return error.GroupClosing;
                const tab = self.app.workspace.groupTabId(small) orelse return error.StaleReference;
                const index = self.app.workspace.model.indexOf(tab) orelse return error.StaleReference;
                const owner = self.app.workspace.model.tabs.items[index].owner;
                if (owner != .group or @backingInt(owner.group.id) != id) return error.TargetOutsideScope;
                const active = for (group.members.items) |member| {
                    if (member.pane_id == legacy and member.active) break true;
                } else false;
                if (!active) return error.TargetOutsideScope;
                break :blk group.membership_revision;
            },
        };
    }
    fn ownership(self: *Context, controller: *Controller, handle: identity.SessionHandle, handed_to_user: bool) !u64 {
        const owned = self.app.lifecycle_supervisor.resource(handle);
        const mode = (try self.taskGrant(controller.authority)).mode;
        if (mode == .isolated_exec) return error.ModeConflict;
        if (owned) |entry| {
            if (entry.snapshot.ownership == .created_task) {
                if (!sameTask(entry.request.context, controller.authority)) return error.OwnershipChanged;
                if (entry.snapshot.state != .ready or !entry.snapshot.membership_committed) return error.SessionNotReady;
            } else if (mode == .new_pty and !handed_to_user) return error.ModeConflict;
            if (entry.snapshot.state == .closing or entry.snapshot.state == .closed) return error.AlreadyClosing;
            return entry.snapshot.ownership_revision;
        }
        if (mode == .new_pty) return error.ModeConflict;
        return 1; // Borrowing never manufactures lifecycle ownership.
    }
    fn inputAuthority(self: *Context, handle: identity.SessionHandle) !InputAuthority {
        const window = Window.forApplication(self.app) orelse return .{};
        const input = window.inputFor(handle) orelse return .{};
        if (input.closed or input.transfer_state == .pending or !input.owner.eql(handle)) return error.StaleInputLease;
        if (input.automation) |lease| if (!input.authorized or lease.authorization_revision != input.authorization_revision or lease.context_instance != input.context_instance) return error.StaleInputLease;
        return .{ .instance = input.context_instance, .revision = input.authorization_revision, .authorized = input.authorized, .automation = input.automation };
    }
    fn captureBoundary(self: *Context, controller: *Controller, handle: identity.SessionHandle, idle: bool, handed_to_user: bool) !Boundary {
        const legacy = self.app.legacyForHandle(handle) orelse return error.StaleReference;
        const state = self.app.sessions.queryState(handle) orelse return error.StaleReference;
        const tab = self.app.workspace.sessionTab(legacy) orelse return error.StaleReference;
        if (!tab.content_owner.eql(.{ .session = handle }) or tab.generation != handle.generation or tab.archived or tab.closing or tab.failed or tab.owned_pending) return error.StaleReference;
        if (state.lifecycle != .ready and state.lifecycle != .attached) return error.SessionNotReady;
        if (state.target.window_id != self.app.window_id or state.target.workspace_id != self.app.workspace_id) return error.TargetOutsideScope;
        const membership_revision = try self.membership(controller, handle, legacy);
        const ownership_revision = try self.ownership(controller, handle, handed_to_user);
        var next_input: u64 = 0;
        const service = if (tab.terminal) |view| if (view.terminal_surface) |surface| blk: {
            if (!surface.owner.eql(handle)) return error.StaleReference;
            if (idle and (surface.pending.items.len != 0 or surface.pending_bytes != 0 or surface.preedit.len != 0 or surface.pending_paste != null or surface.paste_requested != null or surface.trusted_pending != null)) return error.InputConflict;
            next_input = surface.next_input;
            // Execution outlives the input Surface during protocol close.
            // Keep the adapter-owned service, never the document wrapper.
            break :blk surface.composite.raw;
        } else if (tab.runtime) |runtime| try runtime.terminalService() else return error.IntegrationUnavailable else if (tab.runtime) |runtime| try runtime.terminalService() else return error.IntegrationUnavailable;
        if (service.binding.kind != .terminal or service.binding.resource_owner != .session or !service.binding.resource_owner.session.eql(handle) or !self.app.sessions.bindingIsLive(service.binding)) return error.StaleBinding;
        const capability_revision = self.app.sessions.capabilityRevisionFor(handle) orelse return error.CapabilityUnavailable;
        const snapshot = try service.executionSnapshot();
        if (!snapshot.owner.eql(handle)) return error.StaleReference;
        if (!snapshot.interactive_execution or service.vtable.execution_request == null or service.vtable.execution_renew == null or service.vtable.execution_revoke == null or service.vtable.execution_output == null) return error.IntegrationUnavailable;
        if (idle and (!snapshot.input_ready or snapshot.grant != null)) return error.TerminalBusy;
        const input = try self.inputAuthority(handle);
        if (idle and input.automation != null) return error.LeaseConflict;
        return .{ .handle = handle, .service = service, .capability_revision = capability_revision, .ownership_revision = ownership_revision, .membership_revision = membership_revision, .execution_revision = snapshot.revision, .input_epoch = snapshot.input_epoch, .next_input = next_input, .input = input };
    }
    fn admission(self: *Context, invocation: host.Invocation) ?*Admission {
        for (&self.admissions) |*item| if (item.*) |*value| if (value.context.eql(invocation.context) and value.operation_id == invocation.operation_id and value.turn_id == invocation.turn_id and std.mem.eql(u8, &value.call_hash, &execution.digest(invocation.call_id)) and std.mem.eql(u8, &value.arguments_hash, &invocation.arguments_hash) and std.mem.eql(u8, &value.canonical_hash, &invocation.canonical_arguments_hash)) return value;
        return null;
    }
    fn resolveAdmission(self: *Context, record: *Admission, idle: bool) !terminal.Service {
        if (self.closing()) record.cleanup_only = true;
        if (record.cleanup_only) return if (idle) error.WorkspaceClosed else self.cleanupService(record);
        const controller = self.current(record.context, !idle) catch |err| {
            if (!idle) return self.restrictToCleanup(record);
            return err;
        };
        const now = self.captureBoundary(controller, record.boundary.handle, idle, record.handed_to_user) catch |err| {
            if (!idle and err != error.WorkerBusy) return self.restrictToCleanup(record);
            return err;
        };
        const before = record.boundary;
        if (!sameService(now.service, before.service) or now.capability_revision != before.capability_revision) {
            if (!idle) return self.restrictToCleanup(record);
            return error.CapabilityChanged;
        }
        if (now.ownership_revision != before.ownership_revision) {
            const resource = self.app.lifecycle_supervisor.resource(before.handle) orelse return error.OwnershipChanged;
            if (!record.handed_to_user or resource.snapshot.ownership != .handed_to_user) {
                if (!idle) return self.restrictToCleanup(record);
                return error.OwnershipChanged;
            }
        }
        if (!std.meta.eql(now.input, before.input)) {
            if (!idle) return self.restrictToCleanup(record);
            return error.StaleInputLease;
        }
        if (idle and (now.membership_revision != before.membership_revision or now.execution_revision != before.execution_revision or now.input_epoch != before.input_epoch or now.next_input != before.next_input)) return error.InputConflict;
        return now.service;
    }
    fn restrictToCleanup(self: *Context, record: *Admission) !terminal.Service {
        // Authority loss never authorizes a replacement terminal. Prove the
        // exact existing view/service identity before retaining only its old
        // execution receipts and fence-revocation path.
        const service = try self.cleanupService(record);
        record.cleanup_only = true;
        return service;
    }
    fn cleanupService(self: *Context, record: *const Admission) !terminal.Service {
        const handle = record.boundary.handle;
        const legacy = self.app.legacyForHandle(handle) orelse return error.StaleReference;
        const state = self.app.sessions.queryState(handle) orelse return error.StaleReference;
        if (!state.handle.eql(handle) or state.target.window_id != self.app.window_id or state.target.workspace_id != self.app.workspace_id) return error.StaleReference;
        const tab = self.app.workspace.sessionTab(legacy) orelse return error.StaleReference;
        if (!tab.content_owner.eql(.{ .session = handle }) or tab.generation != handle.generation or tab.archived) return error.StaleReference;
        // close_protocol detaches the input Surface before stopping its native
        // runtime. The mapping still owns that exact Service until the host's
        // release_content barrier. Retain only this admitted read/revoke path;
        // it cannot authorize new requests or a replacement generation.
        if (record.cleanup_only and state.close_operation != null and (state.lifecycle == .closing or state.lifecycle == .cleanup_unknown)) {
            const mapping = self.app.findHandle(handle) orelse return error.StaleReference;
            if (mapping.handle.eql(handle) and mapping.legacy_id == legacy and record.boundary.service.binding.resource_owner == .session and record.boundary.service.binding.resource_owner.session.eql(handle)) return record.boundary.service;
        }
        const service = if (tab.terminal) |view| if (view.terminal_surface) |surface| blk: {
            if (!surface.owner.eql(handle)) return error.StaleReference;
            break :blk surface.composite.raw;
        } else if (tab.runtime) |runtime| try runtime.terminalService() else return error.StaleReference else if (tab.runtime) |runtime| try runtime.terminalService() else return error.StaleReference;
        if (!sameService(service, record.boundary.service)) return error.StaleBinding;
        return service;
    }
    fn authorize(raw: *anyopaque, invocation: host.Invocation, reference: []const u8, command: []const u8, hash: [32]u8) !supervisor.Target {
        const self: *Context = @ptrCast(@alignCast(raw));
        try validateNormalized(invocation, command, hash);
        _ = try self.current(invocation.context, false);
        if (!std.mem.eql(u8, reference, try string(invocation.arguments, "session_ref"))) return error.InvalidArguments;
        const record = self.admission(invocation) orelse return error.ApprovalRequired;
        if (record.handed_to_user) return error.OwnershipChanged;
        if (record.cleanup_only) return error.WorkspaceClosed;
        const handle = try parseSession(invocation.context, reference);
        if (!handle.eql(record.boundary.handle)) return error.StaleReference;
        try checkForbidden(command);
        try self.validateApproval(invocation, command, hash);
        const service = try self.resolveAdmission(record, true);
        record.authorized = true;
        return .{ .handle = handle, .service = service, .ownership_revision = record.boundary.ownership_revision };
    }
    fn resolve(raw: *anyopaque, authority: host.Context, handle: identity.SessionHandle) !terminal.Service {
        const self: *Context = @ptrCast(@alignCast(raw));
        // Close can revoke the policy/store binding before Driver.stopTask is
        // consumed. Exact previously admitted owners still need its receipts.
        for (&self.admissions) |*item| if (item.*) |*record| if (record.authorized and record.context.eql(authority) and record.boundary.handle.eql(handle) and (record.cleanup_only or self.closing())) {
            record.cleanup_only = true;
            return self.cleanupService(record);
        };
        const controller = self.current(authority, true) catch |err| {
            for (&self.admissions) |*item| if (item.*) |*record| if (record.authorized and record.context.eql(authority) and record.boundary.handle.eql(handle)) return self.restrictToCleanup(record);
            return err;
        };
        var failure: ?anyerror = null;
        for (&self.admissions) |*item| if (item.*) |*record| if (record.authorized and record.boundary.handle.eql(handle) and (record.context.eql(authority) or (sameTask(record.context, authority) and controller.authority.eql(authority)))) {
            return self.resolveAdmission(record, false) catch |err| {
                failure = err;
                continue;
            };
        };
        if (failure) |err| return err;
        return error.TargetNotAuthorized;
    }
    fn terminalCall(raw: *anyopaque, service: terminal.Service, action: supervisor.TerminalAction) !supervisor.TerminalResult {
        const self: *Context = @ptrCast(@alignCast(raw));
        switch (action) {
            .request => |request| {
                var failure: ?anyerror = null;
                if (self.closing()) return error.WorkspaceClosed;
                for (&self.admissions) |*item| if (item.*) |*record| if (record.authorized and !record.handed_to_user and !record.cleanup_only and record.execution_id == null and record.context.task_id.eql(request.task_id) and sameService(record.boundary.service, service) and std.mem.eql(u8, &record.command_hash, &request.command_hash)) {
                    if (request.ownership_revision != record.boundary.ownership_revision or request.expected_input_epoch != record.boundary.input_epoch) continue;
                    _ = self.resolveAdmission(record, true) catch |err| {
                        failure = err;
                        continue;
                    };
                    const result = try supervisor.performTerminal(service, action);
                    record.execution_id = request.execution_id;
                    return result;
                };
                if (failure) |err| return err;
                return error.TargetNotAuthorized;
            },
            .renew => |grant| {
                if (self.closing()) return error.WorkspaceClosed;
                for (&self.admissions) |*item| if (item.*) |*record| if (record.authorized and record.execution_id != null and record.execution_id.?.eql(grant.execution_id) and record.context.task_id.eql(grant.task_id) and sameService(record.boundary.service, service)) {
                    if (record.handed_to_user) return error.OwnershipChanged;
                    if (record.cleanup_only) return error.WorkspaceClosed;
                    if (grant.ownership_revision != record.boundary.ownership_revision) return error.OwnershipChanged;
                    _ = try self.resolveAdmission(record, false);
                    if (record.cleanup_only) return error.WorkspaceClosed;
                    return supervisor.performTerminal(service, action);
                };
                return error.StaleFence;
            },
            // Revoking an already issued fence must remain possible after its
            // policy/ownership changes. Native service checks the exact grant.
            .revoke => |value| {
                for (self.admissions) |item| if (item) |record| if (record.authorized and record.execution_id != null and record.execution_id.?.eql(value.grant.execution_id) and record.context.task_id.eql(value.grant.task_id) and sameService(record.boundary.service, service)) return supervisor.performTerminal(service, action);
                return error.StaleFence;
            },
            .snapshot, .output => return supervisor.performTerminal(service, action),
        }
    }
    fn handedToUser(raw: *anyopaque, handle: identity.SessionHandle) !void {
        const self: *Context = @ptrCast(@alignCast(raw));
        for (self.admissions) |item| if (item) |record| if (record.authorized and record.boundary.handle.eql(handle)) {
            if (self.app.legacyForHandle(handle) == null) return error.StaleReference;
            if (self.app.lifecycle_supervisor.resource(handle)) |resource| {
                if (resource.snapshot.ownership == .created_task) try self.app.handedToUser(handle);
            }
            for (&self.admissions) |*saved| if (saved.*) |*admitted| if (admitted.authorized and admitted.boundary.handle.eql(handle)) {
                admitted.handed_to_user = true;
            };
            return;
        };
        return error.TargetNotAuthorized;
    }
};
fn sameTask(a: host.Context, b: host.Context) bool {
    return a.conversation_id.eql(b.conversation_id) and a.task_id.eql(b.task_id);
}
fn sameService(a: terminal.Service, b: terminal.Service) bool {
    return a.binding.eql(b.binding) and a.context == b.context and a.vtable == b.vtable;
}
fn string(args: std.json.Value, key: []const u8) ![]const u8 {
    if (args != .object) return error.InvalidArguments;
    const value = args.object.get(key) orelse return error.InvalidArguments;
    return if (value == .string) value.string else error.InvalidArguments;
}
fn validateRun(invocation: host.Invocation) !void {
    if (invocation.authority != .execution_control or !std.mem.eql(u8, invocation.tool_id, "host.run_in_terminal") or invocation.arguments != .object or invocation.arguments.object.count() != 3) return error.InvalidArguments;
    const reference = try string(invocation.arguments, "session_ref");
    const key = try string(invocation.arguments, "request_key");
    _ = try string(invocation.arguments, "command");
    if (reference.len == 0 or reference.len > 128 or key.len == 0 or key.len > 128 or invocation.call_id.len == 0) return error.InvalidArguments;
}
fn validateNormalized(invocation: host.Invocation, command: []const u8, hash: [32]u8) !void {
    try validateRun(invocation);
    try execution.validateCommand(command);
    if (!std.mem.eql(u8, try string(invocation.arguments, "command"), command) or !std.mem.eql(u8, &execution.digest(command), &hash)) return error.CommandHashMismatch;
    var scratch: [256]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&scratch);
    const digest = try canonical.digest(allocator.allocator(), invocation.arguments);
    if (!std.mem.eql(u8, &digest, &invocation.canonical_arguments_hash) or !std.mem.eql(u8, &execution.digest(invocation.arguments_json), &invocation.arguments_hash)) return error.InvalidArguments;
}
fn checkForbidden(command: []const u8) !void {
    // PTY shell aliases/functions/PATH are not proved by an exec prefix list.
    // Keep the existing forbidden rules, and require exact approval for every
    // other command, including seemingly read-only prefixes and auto mode.
    const trimmed = std.mem.trim(u8, command, " \t\n");
    var lines = std.mem.tokenizeAny(u8, trimmed, "\n;|&");
    while (lines.next()) |line| if (@import("../ai/permission.zig").classify(.{}, std.mem.trim(u8, line, " \t"), true) == .deny_exec_copy_only) return error.PermissionDenied;
}
fn subject(invocation: host.Invocation, command: []const u8, impact: []const u8) approvals.Subject {
    return .{ .kind = .terminal_command, .target = string(invocation.arguments, "session_ref") catch "", .detail = command, .impact = impact };
}
fn parseSession(authority: host.Context, text: []const u8) !identity.SessionHandle {
    var parts = std.mem.splitScalar(u8, text, ':');
    if (!std.mem.eql(u8, parts.next() orelse "", "s1") or !std.mem.eql(u8, parts.next() orelse "", &std.fmt.bytesToHex(authority.conversation_id.bytes, .lower))) return error.StaleReference;
    const id = try decimal(parts.next() orelse return error.StaleReference);
    const generation = try decimal(parts.next() orelse return error.StaleReference);
    if (parts.next() != null) return error.StaleReference;
    return .{ .session_id = @fromBackingInt(id), .generation = generation };
}
fn decimal(text: []const u8) !u64 {
    if (text.len == 0 or text.len > 20 or (text.len > 1 and text[0] == '0')) return error.StaleReference;
    for (text) |byte| if (!std.ascii.isDigit(byte)) return error.StaleReference;
    const value = std.fmt.parseInt(u64, text, 10) catch return error.StaleReference;
    return if (value != 0) value else error.StaleReference;
}
fn describe(_: host.Context, _: Boundary) !ApprovalEvidence {
    var result: ApprovalEvidence = .{};
    const text = try std.fmt.bufPrint(&result.bytes, "将在此终端执行上方命令。执行期间由 AI 控制输入；你可随时接管，当前命令会继续运行，需要中断时请按 Ctrl+C。输出保存为同一终端的观测区间，可能含其他来源，也可能缺少结束界标之后的后台输出；输出归属另行标明。此批准仅适用于本次命令。", .{});
    result.len = text.len;
    return result;
}

test {
    _ = @import("ai_execution_backend_tests.zig");
}
