//! Main-thread lifecycle hooks. All effects use real application identities and
//! bounded controller APIs; durable IO remains in ai/lifecycle_runtime.zig.
const std = @import("std");
const identity = @import("../host/identity.zig");
const host = @import("../ai/host_tools.zig");
const runtime = @import("../ai/lifecycle_runtime.zig");
const tools = @import("../ai/host_lifecycle.zig");
const scope = @import("../ai/tool_scope.zig");
const config = @import("../config/config.zig");
const Application = @import("application_host.zig");
const Workspace = @import("workspace.zig").Workspace;
const groups = @import("group_model.zig");
const assistants = @import("../ai/assistant_store.zig");
const Bridge = @import("ai_tools.zig").Bridge;
const lifecycle = tools.lifecycle;

pub const Callbacks = struct {
    context: ?*anyopaque = null,
    on_handoff: ?*const fn (*anyopaque, identity.ConversationId, scope.Owner, u64, u64) void = null,
    on_membership_changed: ?*const fn (*anyopaque, identity.ConversationId, identity.GroupOwner, u64, u64) void = null,
};
pub const Init = struct {
    allocator: std.mem.Allocator,
    app: *Application.ApplicationHost,
    roster: *groups.Roster,
    store: *assistants.Store,
    bridge: *Bridge,
    authority: host.Context,
    execution_policy: config.ExecutionPolicy,
    notice_revision: u64 = 0,
    /// Frozen exact user selections. Inventory/discovery never fills these.
    /// Compatibility only: historical selections no longer grant authority.
    selected_sessions: []const identity.SessionHandle = &.{},
    selected_sources: []const identity.AssetOwner = &.{},
    callbacks: Callbacks = .{},
};
const Prepared = struct {
    operation: identity.HostOperationId,
    context: host.Context,
    source: identity.SessionHandle,
    group: groups.Roster.PreparedGroup,
    handoff: assistants.Store.Handoff,
    view: Workspace.PreparedGroupView,
    notice_revision: u64,
    published: bool = false,
};
const OpenAuthorization = struct { operation: identity.HostOperationId, authorized: runtime.Authorized };
const CloseTarget = struct { operation: identity.HostOperationId, session: identity.SessionHandle };
pub const Controller = struct {
    allocator: std.mem.Allocator,
    app: *Application.ApplicationHost,
    roster: *groups.Roster,
    store: *assistants.Store,
    bridge: *Bridge,
    authority: host.Context,
    execution_policy: config.ExecutionPolicy,
    config_revision: u64,
    notice_revision: u64,
    callbacks: Callbacks,
    prepared: std.ArrayList(*Prepared) = .empty,
    close_targets: std.ArrayList(CloseTarget) = .empty,
    open_authorizations: std.ArrayList(OpenAuthorization) = .empty,
    last_authorization: ?struct { kind: tools.Kind, value: runtime.Authorized } = null,

    pub fn init(options: Init) !Controller {
        try options.authority.validate();
        if ((options.callbacks.on_handoff != null or options.callbacks.on_membership_changed != null) and options.callbacks.context == null) return error.InvalidCallbacks;
        var self: Controller = .{ .allocator = options.allocator, .app = options.app, .roster = options.roster, .store = options.store, .bridge = options.bridge, .authority = options.authority, .execution_policy = options.execution_policy, .config_revision = options.app.workspace.app_config.config_revision, .notice_revision = options.notice_revision, .callbacks = options.callbacks };
        try self.validateAuthority(options.authority);
        return self;
    }
    pub fn available(self: *Controller, tool_id: []const u8) bool {
        const kind = tools.kind(tool_id) orelse return false;
        return switch (kind) {
            .create_group => self.authority.binding == .session,
            .open_session, .rename_group, .add_group_member, .remove_group_member => self.authority.binding == .group,
            .disconnect_session => blk: {
                for (self.app.mappings.items) |mapping| if (self.inBinding(mapping.handle) and self.app.supportsSessionDisconnect(mapping.handle)) break :blk true;
                break :blk false;
            },
            .reconnect_session => blk: {
                for (self.app.mappings.items) |mapping| if (self.inBinding(mapping.handle) and self.app.supportsIntegration(mapping.handle, "transport_loss")) break :blk true;
                break :blk false;
            },
            else => true,
        };
    }
    pub fn handle(self: *Controller) runtime.Controller {
        return .{ .context = self, .invoke = invoke };
    }
    /// Main-thread safe round boundary, after all original tool pairs closed.
    /// Updating authority does not change historical call/journal ownership.
    pub fn refreshAuthority(self: *Controller, authority: host.Context) !void {
        try authority.validate();
        if (!authority.conversation_id.eql(self.authority.conversation_id) or !authority.task_id.eql(self.authority.task_id)) return error.ScopeChanged;
        const state = self.store.findConversation(authority.conversation_id) orelse return error.ConversationNotFound;
        if (state.closed or !state.owner.eql(authority.binding) or state.binding_revision != authority.binding_revision or self.bridge.policy_revision != self.config_revision or authority.grant_revision != self.authority.grant_revision or self.app.workspace.app_config.config_revision != self.config_revision) return error.ScopeChanged;
        self.authority = authority;
    }
    /// Called on the controller thread only after its worker joined. This is
    /// also the Stop fallback if Bridge refused a cancelled release callback.
    pub fn deinitAfterWorker(self: *Controller) void {
        for (self.prepared.items) |plan| self.destroyPlan(plan);
        self.prepared.deinit(self.allocator);
        self.close_targets.deinit(self.allocator);
        self.open_authorizations.deinit(self.allocator);
        self.* = undefined;
    }
    fn validateAuthority(self: *Controller, context: host.Context) !void {
        if (!self.authority.eql(context) or self.bridge.policy_revision != self.config_revision or self.app.workspace.app_config.config_revision != self.config_revision) return error.ScopeChanged;
        const state = self.store.findConversation(context.conversation_id) orelse return error.ConversationNotFound;
        if (state.closed or !state.owner.eql(context.binding) or state.binding_revision != context.binding_revision) return error.BindingConflict;
        if (self.app.workspace.shutting_down or self.app.windowClosePending()) return error.WorkspaceClosed;
    }
    fn validateIdentity(self: *Controller, handle_: identity.SessionHandle, require_ready: bool) !u64 {
        const legacy = self.app.legacyForHandle(handle_) orelse return error.StaleReference;
        const state = self.app.sessions.queryState(handle_) orelse return error.StaleReference;
        const tab = self.app.workspace.sessionTab(legacy) orelse return error.StaleReference;
        if (!tab.content_owner.eql(.{ .session = handle_ }) or tab.archived or tab.closing or tab.owned_pending) return error.StaleReference;
        if (require_ready and (state.lifecycle != .ready and state.lifecycle != .attached)) return error.SourceChanged;
        if (require_ready and (tab.terminal == null or self.app.workspace.model.indexOf(tab.tab_id) == null)) return error.CapabilityUnavailable;
        return legacy;
    }
    fn groupOwner(self: *Controller, id: u64) !identity.GroupOwner {
        const small = std.math.cast(u32, id) orelse return error.StaleReference;
        _ = self.roster.findById(small) orelse return error.StaleReference;
        if (self.app.workspace.groupClosing(small)) return error.GroupClosing;
        const tab = self.app.workspace.groupTabId(small) orelse return error.StaleReference;
        const index = self.app.workspace.model.indexOf(tab) orelse return error.StaleReference;
        const owner = self.app.workspace.model.tabs.items[index].owner;
        if (owner != .group or @backingInt(owner.group.id) != id) return error.StaleReference;
        return owner.group;
    }
    pub fn inBinding(self: *Controller, handle_: identity.SessionHandle) bool {
        return switch (self.authority.binding) {
            .session => |id| id == @backingInt(handle_.session_id),
            .group => |id| blk: {
                const group = self.roster.findById(std.math.cast(u32, id) orelse return false) orelse return false;
                const legacy = self.app.legacyForHandle(handle_) orelse return false;
                for (group.members.items) |member| if (member.active and member.pane_id == legacy) break :blk true;
                break :blk false;
            },
        };
    }
    /// Closed content requires an exact host close receipt from this
    /// conversation and binding, including receipts from an earlier Task. Historical ownership alone never authorizes a live outsider.
    pub fn permitsHistoricalOwner(self: *Controller, handle_: identity.SessionHandle) bool {
        for (self.app.deferred_closes.items) |close| {
            if (!@import("../ai/host_queries.zig").sameHistoricalBinding(close.context, self.authority) or !close.handle.eql(handle_) or close.snapshot.state != .closed) continue;
            const state = self.app.sessions.queryState(handle_) orelse return false;
            return state.lifecycle == .closed;
        }
        return false;
    }
    pub fn permitsHistoricalRecording(self: *Controller, handle_: identity.SessionHandle, id: [32]u8, generation: u64) bool {
        if (!self.permitsHistoricalOwner(handle_)) return false;
        for (self.app.deferred_closes.items) |close| {
            if (!@import("../ai/host_queries.zig").sameHistoricalBinding(close.context, self.authority) or !close.handle.eql(handle_) or close.snapshot.state != .closed) continue;
            const expected = close.retained_metadata.recording_id orelse continue;
            if (close.retained_metadata.recording_generation == generation and std.mem.eql(u8, &expected, &id)) return true;
        }
        return false;
    }
    fn authorizeAsset(self: *Controller, source: identity.AssetOwner) !void {
        // Static saved-host sources are an independent allowed domain. They
        // never authorize access to any already-open external session.
        const index = self.app.workspace.registry.indexOf(source.id) orelse return error.StaleReference;
        const saved = self.app.workspace.registry.hosts[index];
        if (saved.revision != source.revision) return error.SourceChanged;
        if (!std.mem.eql(u8, saved.protocolId(), "ssh")) return error.UnsupportedSource;
    }
    fn checkMembershipDependencies(self: *Controller, session: identity.SessionHandle) !void {
        const legacy = try self.validateIdentity(session, true);
        if (self.bridge.writeRisk(session)) return error.ActiveExecutionConflict;
        const close = self.app.workspace.close_bridge;
        if (close.risk) |risk| if (risk(close.context, legacy).any()) return error.ActiveReference;
        if (close.impact) |probe| {
            const impact = probe(close.context, legacy);
            if (impact.transfer != 0 or impact.socks != 0 or impact.unknown != 0 or impact.remote_effect_unknown) return error.ActiveReference;
        }
    }
    /// Model-facing preflight also runs before idempotent receipt reuse, so
    /// a former member cannot be revived by a historical request key.
    pub fn validateRequestScope(self: *Controller, context: host.Context, request: tools.Request) !void {
        try self.validateAuthority(context);
        if (request.group) |group| if (context.binding != .group or context.binding.group != @backingInt(group.id)) return error.TargetNotAuthorized;
        if (request.session) |target| if (!self.inBinding(target) and !((request.kind == .close_session or request.kind == .wait_session_ready) and self.permitsHistoricalOwner(target))) return error.TargetNotAuthorized;
        if (request.source) |target| if (!self.inBinding(target)) return error.TargetNotAuthorized;
        if (request.saved_source) |source| try self.authorizeAsset(source);
        if (request.operation) |operation| {
            const entry = self.app.lifecycle_supervisor.find(operation) orelse return error.TargetNotAuthorized;
            if (!entry.request.context.eql(context)) return error.TargetNotAuthorized;
            // A task's own opening operation precedes membership commit.
            // Once committed, removal takes effect immediately.
            if (entry.snapshot.membership_committed) {
                const target = entry.snapshot.session orelse return error.TargetNotAuthorized;
                if (!self.inBinding(target)) return error.TargetNotAuthorized;
            }
        }
    }
    fn authorize(self: *Controller, context: host.Context, request: tools.Request) !runtime.Authorized {
        try self.validateRequestScope(context, request);
        // Every existing-object ref is rejected before identity/state/source
        // metadata lookup. Existence, generation and old selections cannot
        // affect the external-target error.
        if (request.session) |target| if (!self.inBinding(target)) return error.TargetNotAuthorized;
        if (request.source) |target| if (!self.inBinding(target)) return error.TargetNotAuthorized;
        var result: runtime.Authorized = .{ .session = request.session, .source = request.source, .saved_source = request.saved_source, .retention = request.retention orelse self.execution_policy.session_retention, .approval_required = true, .policy_revision = self.config_revision };
        if (request.group) |group| {
            if (context.binding != .group or context.binding.group != @backingInt(group.id)) return error.TargetNotAuthorized;
            result.group = try self.groupOwner(@backingInt(group.id));
            const entry = self.roster.findById(@intCast(@backingInt(group.id))).?;
            result.membership_revision = entry.membership_revision;
            if (request.kind == .add_group_member or request.kind == .remove_group_member) {
                if (self.roster.find(entry.name).?.id != entry.id) return error.ToolNotAvailable;
                if (entry.membership_revision == std.math.maxInt(u64)) return error.RevisionExhausted;
            }
        }
        switch (request.kind) {
            .create_group => {
                if (context.binding != .session) return error.AlreadyGroup;
                const target = request.session orelse return error.InvalidArguments;
                if (!self.inBinding(target)) return error.SourceChanged;
                _ = try self.validateIdentity(target, true);
            },
            .open_session => {
                if (result.group == null or (request.source == null) == (request.saved_source == null)) return error.InvalidArguments;
                if (request.source) |source| {
                    if (!self.inBinding(source)) return error.TargetNotAuthorized;
                    _ = try self.validateIdentity(source, true);
                    const mapping = self.app.findHandle(source).?;
                    if (mapping.process != null and request.connection_policy != .new_only) return error.UnsupportedSource;
                } else {
                    try self.authorizeAsset(request.saved_source.?);
                    if (request.connection_policy == .reuse_only) return error.ReuseUnavailable;
                }
                // Shell integration belongs to the terminal's default startup.
                // A PTY request never authorizes remote helper deployment.
                // Actual execution readiness is discovered from the live service.
                // Exact approval explicitly includes any new transport fallback.
                result.allow_new_fallback = request.connection_policy == .prefer_reuse;
            },
            .rename_group => {},
            .add_group_member => {
                const target = request.session orelse return error.InvalidArguments;
                _ = try self.validateIdentity(target, true);
                try self.checkMembershipDependencies(target);
            },
            .remove_group_member => {
                const target = request.session orelse return error.InvalidArguments;
                if (!self.inBinding(target)) return error.TargetNotAuthorized;
                try self.checkMembershipDependencies(target);
            },
            .close_session => {
                const target = request.session orelse return error.InvalidArguments;
                _ = try self.validateIdentity(target, false);
                // Broker's exact close approval is mandatory for borrowed and
                // task-owned resources alike. The worker gates queue_close.
                result.explicit_user_close = true;
                if (self.app.lifecycle_supervisor.resource(target)) |entry| result.ownership_revision = entry.snapshot.ownership_revision;
                const close = self.app.workspace.close_bridge;
                if (close.impact) |probe| {
                    const impact = probe(close.context, self.app.legacyForHandle(target).?);
                    var hash = std.hash.Wyhash.init(0);
                    std.hash.autoHash(&hash, .{ impact.command, impact.transfer, impact.ai, impact.socks, impact.unknown, impact.remote_effect_unknown });
                    result.impact_revision = hash.final();
                }
            },
            .set_session_retention => {
                const target = request.session orelse return error.InvalidArguments;
                _ = try self.validateIdentity(target, false);
                const owned = try self.app.resolveOwnedSession(target, context);
                if (owned.ownership != .created_task) return error.OwnershipChanged;
                result.ownership_revision = owned.ownership_revision;
                if (owned.state == .closing or owned.state == .closed) return error.AlreadyClosing;
            },
            .disconnect_session => {
                const target = request.session orelse return error.InvalidArguments;
                _ = try self.validateIdentity(target, false);
                if (self.bridge.writeRisk(target)) return error.ActiveExecutionConflict;
                const preflight = try self.app.preflightSessionDisconnect(target);
                result.create_operation = preflight.create_operation;
                result.disconnect_binding = preflight.binding;
                result.impact_revision = preflight.impact_revision;
                if (self.app.lifecycle_supervisor.resource(target)) |entry| result.ownership_revision = entry.snapshot.ownership_revision;
            },
            .reconnect_session => {
                const target = request.session orelse return error.InvalidArguments;
                _ = try self.validateIdentity(target, false);
                if (request.connection_policy != .new_only or !self.app.supportsIntegration(target, "transport_loss")) return error.ToolNotAvailable;
                const live = self.app.sessions.queryState(target).?;
                if (live.lifecycle != .failed and live.lifecycle != .ended) return error.AlreadyConnected;
                if (self.bridge.writeRisk(target)) return error.ActiveExecutionConflict;
            },
            .wait_session_ready => return error.InvalidArguments,
        }
        return result;
    }
    fn checkLastAuthorization(self: *Controller, kind: tools.Kind, current: runtime.Authorized) !void {
        const frozen = self.last_authorization orelse return error.ScopeChanged;
        if (frozen.kind != kind or !std.meta.eql(frozen.value, current)) return error.ScopeChanged;
    }
    fn findPlan(self: *Controller, token: *anyopaque) !*Prepared {
        for (self.prepared.items) |plan| if (@as(*anyopaque, plan) == token) return plan;
        return error.StaleGroupPlan;
    }
    fn prepareGroup(self: *Controller, context: host.Context, input: anytype) !runtime.GroupPlan {
        const authorized = try self.authorize(context, input.request);
        if (!std.meta.eql(authorized, input.authorized)) return error.ScopeChanged;
        const source = input.request.session orelse return error.InvalidArguments;
        const legacy = try self.validateIdentity(source, true);
        const plan = try self.allocator.create(Prepared);
        errdefer self.allocator.destroy(plan);
        try self.prepared.ensureUnusedCapacity(self.allocator, 1);
        var group = try self.roster.prepareNew(input.request.name orelse "工作终端组", 0xff818cf8, legacy);
        errdefer group.deinit();
        const handoff = try self.store.prepareHandoff(context.conversation_id, context.binding, context.binding_revision, group.id);
        var view = try self.app.workspace.prepareGroupView(group.id, group.entry.?.name, legacy);
        errdefer view.deinit();
        const revision = if (self.notice_revision == 0) @as(u64, 1) else try identity.advance(self.notice_revision);
        plan.* = .{ .operation = input.operation, .context = context, .source = source, .group = group, .handoff = handoff, .view = view, .notice_revision = revision };
        self.notice_revision = revision;
        self.prepared.appendAssumeCapacity(plan);
        return .{ .id = group.id, .token = plan, .binding_revision = handoff.next_revision, .notice_revision = revision };
    }
    fn commitGroup(self: *Controller, context: host.Context, receipt: runtime.GroupPlan) !void {
        const plan = try self.findPlan(receipt.token);
        if (plan.published or plan.group.id != receipt.id or plan.handoff.next_revision != receipt.binding_revision or plan.notice_revision != receipt.notice_revision or !plan.context.eql(context)) return error.StaleGroupPlan;
        try self.validateAuthority(context);
        _ = try self.validateIdentity(plan.source, true);
        if (!self.inBinding(plan.source)) return error.SourceChanged;
        try plan.view.validate();
        if (plan.group.entry == null or self.roster.findById(plan.group.id) != null) return error.GroupIdentityConflict;
        const rechecked = try self.store.prepareHandoff(context.conversation_id, context.binding, context.binding_revision, plan.group.id);
        if (!std.meta.eql(rechecked, plan.handoff)) return error.BindingConflict;
        // This callback is the single controller safe point. All fallible
        // checks/allocation precede publication; these commits cannot diverge.
        _ = plan.group.commit() catch unreachable;
        self.store.commitHandoff(plan.handoff) catch unreachable;
        plan.view.commit(self.roster) catch unreachable;
        plan.published = true;
        if (self.bridge.route_broker) |broker| {
            var next = context;
            next.binding = plan.handoff.to;
            next.binding_revision = plan.handoff.next_revision;
            broker.execution_route.handoff(context, next, plan.source) catch {};
        }
        self.bridge.bindingChanged(plan.handoff.to);
        if (self.callbacks.on_handoff) |notify| notify(self.callbacks.context.?, context.conversation_id, plan.handoff.to, plan.handoff.next_revision, plan.notice_revision);
    }
    fn routeCreate(request: @import("../host/lifecycle_supervisor.zig").OpenRequest) @import("../ai/execution_routing.zig").Create {
        const route = @import("../ai/execution_routing.zig");
        return .{ .operation_id = request.operation_ref, .request_hash = route.digest(&request.operation_ref.bytes), .source = if (request.source) |source| .{ .session = source } else .{ .saved = request.saved_source.? }, .retention = request.retention, .policy = @fromBackingInt(@intCast(@backingInt(request.connection_policy))) };
    }
    pub fn adoptRouteSession(self: *Controller, context: host.Context, operation: identity.HostOperationId, snapshot: @import("../host/lifecycle_supervisor.zig").Snapshot) void {
        const broker = self.bridge.route_broker orelse return;
        const entry = self.app.lifecycle_supervisor.find(operation) orelse return;
        if (!entry.request.context.eql(context) or !snapshot.context.eql(context) or snapshot.state != .ready or !snapshot.membership_committed or snapshot.ownership != .created_task or snapshot.session == null or entry.snapshot.session == null or !entry.snapshot.session.?.eql(snapshot.session.?)) return;
        broker.execution_route.created(context, routeCreate(entry.request), snapshot.session.?) catch {};
    }
    fn destroyPlan(self: *Controller, plan: *Prepared) void {
        plan.view.deinit();
        plan.group.deinit();
        self.allocator.destroy(plan);
    }
    fn releaseGroup(self: *Controller, receipt: runtime.GroupPlan) !void {
        const plan = try self.findPlan(receipt.token);
        if (plan.group.id != receipt.id or plan.handoff.next_revision != receipt.binding_revision or plan.notice_revision != receipt.notice_revision) return error.StaleGroupPlan;
        for (self.prepared.items, 0..) |item, index| if (item == plan) {
            _ = self.prepared.orderedRemove(index);
            self.destroyPlan(plan);
            return;
        };
    }
    fn closeSnapshot(target: CloseTarget, receipt: Application.DeferredCloseSnapshot) runtime.CloseSnapshot {
        return .{ .operation_ref = receipt.operation_ref, .session = target.session, .state = switch (receipt.state) {
            .accepted => .awaiting_result,
            .closing => .closing,
            .closed => .closed,
            .cleanup_pending => .cleanup_pending,
            .cancelled_unsent => .cancelled_unsent,
        }, .local_released = receipt.local_released, .remote_effect_unknown = receipt.remote_effect_unknown, .error_code = receipt.error_code, .recording_id = receipt.recording_id, .recording_generation = receipt.recording_generation, .recording_unavailable_reason = receipt.recording_unavailable_reason };
    }
    fn closeTarget(self: *Controller, operation: identity.HostOperationId) !CloseTarget {
        for (self.close_targets.items) |target| if (target.operation.eql(operation)) return target;
        return error.NotFound;
    }
    fn mutate(self: *Controller, context: host.Context, input: anytype) !runtime.MutationReceipt {
        const checked = try self.authorize(context, input.request);
        if (!std.meta.eql(checked, input.authorized)) return error.ScopeChanged;
        const request = input.request;
        if (request.kind == .disconnect_session) {
            const snapshot = try self.app.requestSessionDisconnect(input.operation, context, request.session.?, checked.create_operation.?, checked.disconnect_binding.?, checked.impact_revision.?);
            // Exact SessionHost service revocation fences all old exec/input
            // handles. A route grant for this attempt must also be consumed.
            if (self.bridge.route_broker) |broker| broker.execution_route.revoke();
            return disconnectReceipt(snapshot);
        }
        if (request.kind == .reconnect_session) {
            try self.app.requestSshReconnect(try self.validateIdentity(request.session.?, false));
            return .{ .state = .pending, .source_revision = self.config_revision, .session = request.session };
        }
        const owner = checked.group orelse return error.InvalidArguments;
        const id: u32 = @intCast(@backingInt(owner.id));
        const group = self.roster.findById(id).?;
        const tab_id = self.app.workspace.groupTabId(id).?;
        const tab_index = self.app.workspace.model.indexOf(tab_id).?;
        const revision = if (self.notice_revision == 0) @as(u64, 1) else try identity.advance(self.notice_revision);
        switch (request.kind) {
            .rename_group => {
                const name = request.name orelse return error.InvalidArguments;
                const owned = try self.roster.allocator.dupe(u8, name);
                errdefer self.roster.allocator.free(owned);
                var label: [128]u8 = undefined;
                const full = try std.fmt.bufPrint(&label, "组 · {s}", .{name});
                var count = @min(full.len, self.app.workspace.model.tabs.items[tab_index].title.len);
                while (count > 0 and !std.unicode.utf8ValidateSlice(full[0..count])) count -= 1;
                const tab = self.app.workspace.model.tabs.items[tab_index];
                try self.app.workspace.model.rename(.{ .tab = tab_id, .owner = .{ .group = owner }, .revision = tab.revision }, full[0..count]);
                self.roster.allocator.free(group.name);
                group.name = owned;
                self.app.workspace.tab_rebuild_pending = true;
                self.app.workspace.refreshGroup(id);
                self.app.workspace.cx.requestRedraw();
                return .{ .state = .committed, .source_revision = self.app.workspace.model.tabs.items[tab_index].revision, .group = owner, .membership_revision = group.membership_revision };
            },
            .add_group_member, .remove_group_member => {
                const handle_ = request.session.?;
                const legacy = try self.validateIdentity(handle_, true);
                const contains = group.contains(legacy);
                if ((request.kind == .add_group_member and contains) or (request.kind == .remove_group_member and !contains)) return .{ .state = .committed, .source_revision = group.membership_revision, .group = owner, .session = handle_, .membership_revision = group.membership_revision };
                // Existing roster APIs use names. Do not let a duplicate name
                // retarget a stable GroupRef to a different group.
                if (self.roster.find(group.name).?.id != id) return error.ToolNotAvailable;
                if (request.kind == .add_group_member) {
                    _ = try self.roster.join(group.name, legacy, group.color);
                    const session_tab = self.app.workspace.sessionTab(legacy).?;
                    self.app.workspace.model.setContainer(session_tab.tab_id, tab_id) catch unreachable;
                } else if (group.contains(legacy)) try self.roster.leave(group.name, legacy);
                self.notice_revision = revision;
                self.app.workspace.refreshGroup(id);
                const membership_revision = group.membership_revision;
                if (self.callbacks.on_membership_changed) |notify| notify(self.callbacks.context.?, context.conversation_id, owner, membership_revision, revision);
                return .{ .state = .committed, .source_revision = membership_revision, .group = owner, .session = handle_, .membership_revision = membership_revision, .notice_revision = revision };
            },
            else => return error.ToolNotAvailable,
        }
    }
    fn disconnectReceipt(snapshot: Application.DisconnectSnapshot) runtime.MutationReceipt {
        return .{ .state = switch (snapshot.state) {
            .pending => .pending,
            .disconnected => .disconnected,
            .outcome_unknown => .outcome_unknown,
        }, .operation_ref = snapshot.operation_ref, .session = snapshot.session, .source_revision = snapshot.revision, .local_released = snapshot.local_released, .remote_effect_unknown = snapshot.remote_effect_unknown, .error_code = snapshot.error_code };
    }
    pub fn invoke(raw: *anyopaque, call: *runtime.Call) !void {
        const self: *Controller = @ptrCast(@alignCast(raw));
        // Exact cleanup tokens remain valid after a successful handoff changed
        // the conversation binding, or after a policy cancellation.
        switch (call.action) {
            .release_group => |receipt| return self.releaseGroup(receipt),
            .cancel_open => |operation| {
                call.result = .{ .session = try self.app.cancelOwnedSession(operation, call.context) };
                return;
            },
            else => try self.validateAuthority(call.context),
        }
        switch (call.action) {
            .authorize => |request| {
                const authorized = try self.authorize(call.context, request);
                self.last_authorization = .{ .kind = request.kind, .value = authorized };
                call.result = .{ .authorized = authorized };
            },
            .prepare_group => |request| call.result = .{ .group_plan = try self.prepareGroup(call.context, request) },
            .commit_group => |receipt| try self.commitGroup(call.context, receipt),
            .queue_open => |request| {
                if (!request.context.eql(call.context)) return error.ScopeChanged;
                // Validate exact sources again at the actual enqueue boundary.
                const previous = self.last_authorization orelse return error.ScopeChanged;
                const proposal: tools.Request = .{ .kind = .open_session, .group = request.group, .source = request.source, .saved_source = request.saved_source, .connection_policy = request.connection_policy, .retention = request.retention, .interactive_execution = previous.value.bootstrap_required };
                const authorized = try self.authorize(call.context, proposal);
                if (request.allow_new_fallback != authorized.allow_new_fallback or request.membership_revision != authorized.membership_revision) return error.ScopeChanged;
                try self.checkLastAuthorization(.open_session, authorized);
                try self.open_authorizations.ensureUnusedCapacity(self.allocator, 1);
                call.result = .{ .session = try self.app.queueOwnedSession(request) };
                if (authorized.bootstrap_required) try self.app.requireOwnedBootstrap(request.operation_ref, call.context);
                self.open_authorizations.appendAssumeCapacity(.{ .operation = request.operation_ref, .authorized = authorized });
                if (self.bridge.route_broker) |broker| broker.execution_route.bindCreate(call.context, routeCreate(request)) catch {};
            },
            .probe_bootstrap => |operation| call.result = .{ .bootstrap_probe = try self.app.probeOwnedBootstrap(operation, call.context) },
            .install_bootstrap => |prepared| try self.app.installOwnedBootstrap(prepared, call.context),
            .query_open => |operation| {
                const snapshot = try self.app.queryOwnedSession(operation, call.context);
                self.adoptRouteSession(call.context, operation, snapshot);
                call.result = .{ .session = snapshot };
            },
            .resolve_owned => |handle_| {
                if (!self.inBinding(handle_)) return error.TargetNotAuthorized;
                const snapshot = try self.app.resolveOwnedSession(handle_, call.context);
                self.adoptRouteSession(call.context, snapshot.operation_ref, snapshot);
                call.result = .{ .session = snapshot };
            },
            .query_disconnect => |operation| call.result = .{ .mutation = disconnectReceipt(try self.app.querySessionDisconnect(operation, call.context)) },
            .authorize_open => |request| {
                const entry = self.app.lifecycle_supervisor.find(request.operation) orelse return error.NotFound;
                const open_request = entry.request;
                const wants_bootstrap = for (self.open_authorizations.items) |frozen| {
                    if (frozen.operation.eql(request.operation)) break frozen.authorized.bootstrap_required;
                } else return error.ScopeChanged;
                const checked = try self.authorize(call.context, .{ .kind = .open_session, .group = open_request.group, .source = open_request.source, .saved_source = open_request.saved_source, .connection_policy = open_request.connection_policy, .retention = open_request.retention, .interactive_execution = wants_bootstrap });
                var found = false;
                for (self.open_authorizations.items) |frozen| if (frozen.operation.eql(request.operation)) {
                    if (!std.meta.eql(frozen.authorized, checked)) return error.ScopeChanged;
                    found = true;
                    break;
                };
                if (!found) return error.ScopeChanged;
                call.result = .{ .session = try self.app.authorizeOwnedSessionDispatch(request.operation, call.context, request.revision, request.session) };
            },
            .queue_close => |request| {
                const authorized = try self.authorize(call.context, .{ .kind = .close_session, .session = request.session });
                try self.checkLastAuthorization(.close_session, authorized);
                try self.close_targets.ensureUnusedCapacity(self.allocator, 1);
                const receipt = try self.app.queueSessionClose(request.operation, call.context, request.session, request.explicit_user_close);
                const target: CloseTarget = .{ .operation = request.operation, .session = request.session };
                var found = false;
                for (self.close_targets.items) |old| if (old.operation.eql(request.operation)) {
                    found = true;
                    if (!old.session.eql(request.session)) return error.IdempotencyConflict;
                };
                if (!found) self.close_targets.appendAssumeCapacity(target);
                call.result = .{ .close = closeSnapshot(target, receipt) };
            },
            .query_close => |operation| call.result = .{ .close = closeSnapshot(try self.closeTarget(operation), try self.app.querySessionClose(operation, call.context)) },
            .acknowledge_close => |operation| {
                _ = try self.app.querySessionClose(operation, call.context);
                try self.app.acknowledgeSessionCloseResult(operation);
            },
            .set_retention => |request| {
                const authorized = try self.authorize(call.context, .{ .kind = .set_session_retention, .session = request.session, .retention = request.retention });
                try self.checkLastAuthorization(.set_session_retention, authorized);
                call.result = .{ .session = try self.app.setOwnedSessionRetention(request.session, call.context.task_id, request.retention) };
            },
            .mutate => |request| call.result = .{ .mutation = try self.mutate(call.context, request) },
            .release_group, .cancel_open => unreachable,
        }
    }
};

const TestFixture = struct {
    const ui = @import("ui");
    cx: *ui.Cx,
    scope_: *ui.Scope,
    app: *Application.ApplicationHost,
    workspace: *Workspace,
    config_: config.Config = .{},
    tmp: @TypeOf(std.testing.tmpDir(.{})),
    path: [:0]u8,
    directory: [:0]u8,
    previous_zdotdir: ?[:0]u8 = null,
    previous_data_dir: ?[:0]u8 = null,
    reject_bootstrap_deployment: bool = false,
    bootstrap_approvals_seen: usize = 0,
    acknowledge_ssh_frames: bool = false,
    extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
    extern "c" fn unsetenv([*:0]const u8) c_int;
    fn init(self: *@This()) !void {
        const a = std.testing.allocator;
        self.* = .{ .cx = try ui.Cx.init(a, std.testing.io), .scope_ = undefined, .app = undefined, .workspace = undefined, .tmp = std.testing.tmpDir(.{}), .path = undefined, .directory = undefined };
        self.cx.setViewport(1100, 720);
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
        self.scope_ = try ui.Scope.init(a, null, self.cx.owner);
        var nodes: [4]*ui.Node = undefined;
        for (&nodes) |*node| {
            node.* = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .px = 100 } }, .{});
            try self.cx.root.?.appendChild(a, node.*);
        }
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "hosts.toml", .data = "" });
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".zshenv", .data = "setopt NO_RCS\nPROMPT=''\nRPROMPT=''\n" });
        self.path = try self.tmp.dir.realPathFileAlloc(std.testing.io, "hosts.toml", a);
        self.directory = try self.tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
        self.previous_zdotdir = if (std.c.getenv("ZDOTDIR")) |value| try a.dupeSentinel(u8, std.mem.span(value), 0) else null;
        self.previous_data_dir = if (std.c.getenv("ZEROWORK_DATA_DIR")) |value| try a.dupeSentinel(u8, std.mem.span(value), 0) else null;
        if (setenv("ZDOTDIR", self.directory.ptr, 1) != 0) return error.EnvironmentFailed;
        if (setenv("ZEROWORK_DATA_DIR", self.directory.ptr, 1) != 0) return error.EnvironmentFailed;
        self.workspace = try Workspace.init(a, self.cx, self.scope_, std.testing.io, &self.config_, self.path, nodes[0], nodes[1], nodes[2], nodes[3]);
        self.app = try Application.ApplicationHost.init(a, self.workspace);
        try self.scope_.onCleanup(Application.ApplicationHost, self.app, Application.ApplicationHost.deinit);
        self.app.install();
    }
    fn tick(self: *@This(), bridge: ?*Bridge) !void {
        _ = try self.app.safeTick();
        // The loopback lifecycle fixture mounts no terminal text consumer.
        // Acknowledge presentation frames only in that headless test mode;
        // the worker's timeline and execution recording retain all output.
        if (self.acknowledge_ssh_frames) for (self.workspace.tabs.items) |tab| {
            if (tab.runtime) |session_runtime| if (!session_runtime.torn_down) {
                _ = session_runtime.textSlot().acknowledge(0);
            };
        };
        if (bridge) |value| value.pump(self.app);
        self.cx.advanceFrameClock();
        self.cx.layout();
        _ = self.cx.render();
        var empty: [1]std.c.pollfd = undefined;
        _ = std.c.poll(&empty, 0, 2);
    }
    fn local(self: *@This()) !identity.SessionHandle {
        const source = try self.app.createLocal(self.directory);
        const deadline = @import("../platform/realtime.zig").monotonicNs() + 8 * std.time.ns_per_s;
        while (self.app.sessions.queryState(source.handle).?.lifecycle != .attached) {
            try self.tick(null);
            if (@import("../platform/realtime.zig").monotonicNs() > deadline) return error.LocalSessionNotReady;
        }
        return source.handle;
    }
    fn deinit(self: *@This()) void {
        const a = std.testing.allocator;
        for (self.app.mappings.items) |mapping| _ = self.app.requestCloseLegacy(mapping.legacy_id) catch {};
        const deadline = @import("../platform/realtime.zig").monotonicNs() + 8 * std.time.ns_per_s;
        while (self.workspace.tabs.items.len != 0 or self.app.local_adapter.shutdownStep() != .released) {
            self.tick(null) catch |err| std.debug.panic("controller fixture cleanup: {s}", .{@errorName(err)});
            if (@import("../platform/realtime.zig").monotonicNs() > deadline) @panic("controller fixture cleanup timed out");
        }
        self.cx.clearFocus();
        self.scope_.dispose();
        self.cx.deinit();
        if (self.previous_zdotdir) |previous| {
            if (setenv("ZDOTDIR", previous.ptr, 1) != 0) @panic("cannot restore fixture environment");
            a.free(previous);
        } else if (unsetenv("ZDOTDIR") != 0) @panic("cannot restore fixture environment");
        if (self.previous_data_dir) |previous| {
            if (setenv("ZEROWORK_DATA_DIR", previous.ptr, 1) != 0) @panic("cannot restore fixture environment");
            a.free(previous);
        } else if (unsetenv("ZEROWORK_DATA_DIR") != 0) @panic("cannot restore fixture environment");
        a.free(self.path);
        a.free(self.directory);
        self.tmp.cleanup();
    }
};
fn testContext(store: *assistants.Store, source: identity.SessionHandle) !host.Context {
    const state = try store.create(.{ .session = @backingInt(source.session_id) });
    return .{ .conversation_id = state.conversation_id, .task_id = identity.TaskId.generate(), .binding = state.owner, .binding_revision = state.binding_revision, .grant_revision = 1 };
}
fn testScheduler(raw: *anyopaque, context: *anyopaque, run: *const fn (*anyopaque) anyerror!void, cancel: ?*@import("../ai/provider.zig").CancelToken) !void {
    try @as(*Bridge, @ptrCast(@alignCast(raw))).callController(context, run, cancel);
}
fn testInvoke(fixture: *TestFixture, controller: *Controller, backend: *runtime.Runtime, broker: *@import("../ai/host_approval.zig").Broker, tool: []const u8, arguments: []const u8) !host.Result {
    const a = std.testing.allocator;
    const json = try std.json.parseFromSlice(std.json.Value, a, arguments, .{});
    defer json.deinit();
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(arguments, &hash, .{});
    try broker.configure(controller.authority, controller.config_revision);
    const Worker = struct {
        backend: *runtime.Runtime,
        bridge: *Bridge,
        invocation: host.Invocation,
        result: ?host.Result = null,
        failure: ?anyerror = null,
        done: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            self.result = self.backend.execute(.{ .context = self.bridge, .call = testScheduler }, self.invocation, a, null) catch |err| blk: {
                self.failure = err;
                break :blk null;
            };
            self.done.store(true, .release);
        }
    };
    var worker: Worker = .{ .backend = backend, .bridge = controller.bridge, .invocation = .{ .context = controller.authority, .authority = .lifecycle, .operation_id = 1, .turn_id = 1, .call_id = "controller-real-call", .tool_id = tool, .arguments = json.value, .arguments_json = arguments, .arguments_hash = hash, .canonical_arguments_hash = try @import("../ai/canonical_arguments.zig").digest(a, json.value) } };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    defer thread.join();
    errdefer {
        broker.stop();
        controller.bridge.shutdown(fixture.app);
    }
    const deadline = @import("../platform/realtime.zig").monotonicNs() + 8 * std.time.ns_per_s;
    while (!worker.done.load(.acquire)) {
        if (broker.snapshot()) |approval| {
            const deployment = std.mem.eql(u8, approval.target.text(), "SSH BootstrapV1：本次临时 helper 部署");
            if (deployment) fixture.bootstrap_approvals_seen += 1;
            try broker.decide(approval.sequence, approval.arguments_hash, !deployment or !fixture.reject_bootstrap_deployment);
        }
        try fixture.tick(controller.bridge);
        if (@import("../platform/realtime.zig").monotonicNs() > deadline) {
            broker.stop();
            controller.bridge.shutdown(fixture.app);
            return error.ControllerWorkerTimeout;
        }
    }
    if (worker.failure) |err| return err;
    return worker.result orelse error.MissingHostResult;
}
fn testMetadata(fixture: *TestFixture, roster: *groups.Roster, context: host.Context, tool: []const u8, arguments: []const u8) !host.Result {
    const a = std.testing.allocator;
    const json = try std.json.parseFromSlice(std.json.Value, a, arguments, .{});
    defer json.deinit();
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(arguments, &hash, .{});
    return @import("ai_host_queries.zig").execute(fixture.app, roster, context.binding, .{ .execution_policy = .{ .execution_mode = .auto, .session_retention = .keep }, .permission_mode = .confirm, .host_contributions = &tools.contributions }, @splat(17), .{ .context = context, .authority = .conversation_context, .operation_id = 1, .turn_id = 1, .call_id = "closed-metadata-fixture", .tool_id = tool, .arguments = json.value, .arguments_json = arguments, .arguments_hash = hash, .canonical_arguments_hash = hash }, a);
}

test "lifecycle controller real Local group open and close preserve conversation and source" {
    const a = std.testing.allocator;
    var fixture: TestFixture = undefined;
    try fixture.init();
    var roster = groups.Roster.init(a);
    defer roster.deinit();
    defer fixture.deinit();
    const source = try fixture.local();
    var store = assistants.Store.init(a);
    defer store.deinit();
    var bridge = Bridge.init(a);
    defer bridge.deinit();
    const context = try testContext(&store, source);
    store.findConversation(context.conversation_id).?.draft = try a.dupe(u8, "保留草稿");
    var controller = try Controller.init(.{ .allocator = a, .app = fixture.app, .roster = &roster, .store = &store, .bridge = &bridge, .authority = context, .execution_policy = .{ .execution_mode = .auto, .session_retention = .auto_idle } });
    defer controller.deinitAfterWorker();
    const owner = try runtime.ProcessJournal.acquire(.{ .data_root = fixture.directory, .path = "controller-lifecycle.json" });
    defer owner.release();
    var broker: @import("../ai/host_approval.zig").Broker = .{};
    var backend: runtime.Runtime = .{ .journal_owner = owner, .controller = controller.handle(), .approval = &broker };
    const source_ref = try @import("../ai/host_queries.zig").sessionRef(a, context, source);
    defer a.free(source_ref);
    const create_args = try std.json.Stringify.valueAlloc(a, .{ .initial_session_ref = source_ref, .name = "真实工作组", .request_key = "controller-group" }, .{});
    defer a.free(create_args);
    var created = try testInvoke(&fixture, &controller, &backend, &broker, "host.create_group", create_args);
    defer created.deinit(a);
    try std.testing.expectEqual(@import("../ai/plugin_tools.zig").Status.succeeded, created.status);
    const moved = store.findConversation(context.conversation_id).?;
    try std.testing.expectEqualStrings("保留草稿", moved.draft.?);
    try std.testing.expectEqual(@as(usize, 1), roster.groups.items.len);
    try std.testing.expect(moved.owner == .group);
    var next = context;
    next.binding = moved.owner;
    next.binding_revision = moved.binding_revision;
    moved.controls.execution_mode = .attached_pty;
    moved.controls.session_retention = .keep;
    try controller.refreshAuthority(next);
    try std.testing.expectEqual(config.ExecutionMode.auto, controller.execution_policy.execution_mode);
    try std.testing.expectEqual(config.SessionRetention.auto_idle, controller.execution_policy.session_retention);
    const group_ref = try @import("../ai/host_queries.zig").groupRef(a, next, next.binding.group);
    defer a.free(group_ref);
    const open_args = try std.json.Stringify.valueAlloc(a, .{ .group_ref = group_ref, .source_ref = source_ref, .connection_policy = "new_only", .request_key = "controller-open" }, .{});
    defer a.free(open_args);
    var opened = try testInvoke(&fixture, &controller, &backend, &broker, "host.open_session", open_args);
    defer opened.deinit(a);
    try std.testing.expectEqual(@import("../ai/plugin_tools.zig").Status.succeeded, opened.status);
    const entry = &fixture.app.lifecycle_supervisor.entries.items[0];
    const owned = entry.snapshot.session.?;
    const open_op = entry.snapshot.operation_ref;
    const deadline = @import("../platform/realtime.zig").monotonicNs() + 8 * std.time.ns_per_s;
    while ((try fixture.app.queryOwnedSession(open_op, next)).state != .ready) {
        try fixture.tick(&bridge);
        if (@import("../platform/realtime.zig").monotonicNs() > deadline) return error.OwnedSessionNotReady;
    }
    try std.testing.expectEqual(@as(usize, 2), roster.groups.items[0].members.items.len);
    var repeated = try testInvoke(&fixture, &controller, &backend, &broker, "host.open_session", open_args);
    defer repeated.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), fixture.app.lifecycle_supervisor.entries.items.len);
    const owned_ref = try @import("../ai/host_queries.zig").sessionRef(a, next, owned);
    defer a.free(owned_ref);
    const query_args = try std.json.Stringify.valueAlloc(a, .{ .session_ref = owned_ref }, .{});
    defer a.free(query_args);
    const live_binding = switch (fixture.app.sessions.queryService(owned, .terminal)) {
        .available => |binding| binding,
        else => return error.TerminalServiceUnavailable,
    };
    const live_service = try fixture.app.findHandle(owned).?.process.?.terminalService(live_binding);
    var live_recording: @import("../host/terminal_service.zig").RecordingIdentity = undefined;
    while (true) {
        live_recording = live_service.recordingIdentity() catch |err| {
            if (err != error.WorkerBusy) return err;
            try fixture.tick(&bridge);
            if (@import("../platform/realtime.zig").monotonicNs() > deadline) return error.RecordingIdentityTimeout;
            continue;
        };
        break;
    }
    try std.testing.expect(live_recording.available and live_recording.recording_id != null);
    // A normal recorded terminal has an identity before any AI execution.
    try std.testing.expect((try live_service.executionSnapshot()).recording_id == null);
    const close_args = try std.json.Stringify.valueAlloc(a, .{ .session_ref = owned_ref, .request_key = "controller-close" }, .{});
    defer a.free(close_args);
    var accepted = try testInvoke(&fixture, &controller, &backend, &broker, "host.close_session", close_args);
    defer accepted.deinit(a);
    try accepted.validate(next, 1);
    const close_body = try std.json.parseFromSlice(std.json.Value, a, accepted.blocks[0].structured, .{});
    defer close_body.deinit();
    try std.testing.expectEqualStrings("closing", close_body.value.object.get("state").?.string);
    const recording_ref = close_body.value.object.get("recording_ref").?.string;
    const recording = try @import("../ai/host_terminal_queries.zig").resolveRecording(next, recording_ref);
    try std.testing.expectEqualStrings(&live_recording.recording_id.?, &recording.id);
    try std.testing.expectEqual(live_recording.recording_generation, recording.generation);
    const close_op = try tools.operationId(next, close_body.value.object.get("operation_ref").?.string);
    try fixture.tick(&bridge);
    try std.testing.expect((try fixture.app.querySessionClose(close_op, next)).state == .accepted);
    try std.testing.expectEqual(@as(usize, 2), fixture.workspace.tabs.items.len);
    var before_close = try testMetadata(&fixture, &roster, next, "host.list_sessions", "{\"state_filter\":\"closed\"}");
    defer before_close.deinit(a);
    const before_rows = try std.json.parseFromSlice(std.json.Value, a, before_close.blocks[0].structured, .{});
    defer before_rows.deinit();
    try std.testing.expectEqual(@as(usize, 0), before_rows.value.object.get("sessions").?.array.items.len);
    const Ack = struct {
        backend: *runtime.Runtime,
        bridge: *Bridge,
        context: host.Context,
        operation: identity.HostOperationId,
        failure: ?anyerror = null,
        done: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            self.backend.acknowledgeResult(.{ .context = self.bridge, .call = testScheduler }, self.context, self.operation) catch |err| {
                self.failure = err;
            };
            self.done.store(true, .release);
        }
    };
    var ack: Ack = .{ .backend = &backend, .bridge = &bridge, .context = next, .operation = close_op };
    const ack_thread = try std.Thread.spawn(.{}, Ack.run, .{&ack});
    while (!ack.done.load(.acquire)) try fixture.tick(&bridge);
    ack_thread.join();
    if (ack.failure) |err| return err;
    while ((try fixture.app.querySessionClose(close_op, next)).state != .closed) {
        try fixture.tick(&bridge);
        if (@import("../platform/realtime.zig").monotonicNs() > deadline) return error.OwnedSessionCloseTimeout;
    }
    try std.testing.expect(controller.permitsHistoricalOwner(owned));
    var closed_metadata = try testMetadata(&fixture, &roster, next, "host.get_session", query_args);
    defer closed_metadata.deinit(a);
    const closed_metadata_json = try std.json.parseFromSlice(std.json.Value, a, closed_metadata.blocks[0].structured, .{});
    defer closed_metadata_json.deinit();
    const closed_row = closed_metadata_json.value.object.get("session").?.object;
    try std.testing.expectEqualStrings("closed", closed_row.get("state").?.string);
    try std.testing.expectEqualStrings(recording_ref, closed_row.get("recording_ref").?.string);
    try std.testing.expect(!closed_row.get("current_member").?.bool);
    var closed_list = try testMetadata(&fixture, &roster, next, "host.list_sessions", "{\"state_filter\":\"closed\"}");
    defer closed_list.deinit(a);
    const closed_rows = try std.json.parseFromSlice(std.json.Value, a, closed_list.blocks[0].structured, .{});
    defer closed_rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), closed_rows.value.object.get("sessions").?.array.items.len);
    var repeated_close = try testInvoke(&fixture, &controller, &backend, &broker, "host.close_session", close_args);
    defer repeated_close.deinit(a);
    const repeated_body = try std.json.parseFromSlice(std.json.Value, a, repeated_close.blocks[0].structured, .{});
    defer repeated_body.deinit();
    try std.testing.expectEqualStrings("closed", repeated_body.value.object.get("state").?.string);
    try std.testing.expect(repeated_body.value.object.get("idempotent_reuse").?.bool);
    try std.testing.expectEqualStrings(recording_ref, repeated_body.value.object.get("recording_ref").?.string);
    try std.testing.expectEqual(@as(usize, 1), fixture.app.deferred_closes.items.len);
    var other_task = next;
    other_task.task_id.bytes[0] ^= 1;
    var later_metadata = try testMetadata(&fixture, &roster, other_task, "host.get_session", query_args);
    defer later_metadata.deinit(a);
    var later_controller = try Controller.init(.{ .allocator = a, .app = fixture.app, .roster = &roster, .store = &store, .bridge = &bridge, .authority = other_task, .execution_policy = .{ .execution_mode = .auto, .session_retention = .keep } });
    defer later_controller.deinitAfterWorker();
    try std.testing.expect(later_controller.permitsHistoricalOwner(owned));
    try std.testing.expect(later_controller.permitsHistoricalRecording(owned, recording.id, recording.generation));
    var historical = try @import("ai_recording_query_access.zig").Access.init(a, .{ .allocator = a, .io = std.testing.io, .dir = fixture.tmp.dir }, other_task);
    defer historical.deinit();
    try historical.captureClosedReceipts(fixture.app);
    try std.testing.expectEqual(@as(usize, 1), historical.candidates.items.len);
    const historical_arguments = try std.json.Stringify.valueAlloc(a, .{ .recording_ref = recording_ref }, .{});
    defer a.free(historical_arguments);
    const historical_parsed = try std.json.parseFromSlice(std.json.Value, a, historical_arguments, .{});
    defer historical_parsed.deinit();
    const historical_call: host.Invocation = .{ .context = other_task, .authority = .conversation_context, .operation_id = 1, .turn_id = 1, .call_id = "later-task-own-history", .tool_id = "host.read_terminal", .arguments = historical_parsed.value, .arguments_json = historical_arguments, .arguments_hash = @splat(0), .canonical_arguments_hash = @splat(0) };
    try std.testing.expect((try historical.candidateOwner(historical_call)).eql(owned));
    var historical_result = try historical.execute(historical_call, a);
    defer historical_result.deinit(a);
    try historical_result.validate(other_task, 1);
    var unrelated = other_task;
    unrelated.conversation_id.bytes[0] ^= 1;
    const unrelated_ref = try @import("../ai/host_queries.zig").sessionRef(a, unrelated, owned);
    defer a.free(unrelated_ref);
    const unrelated_args = try std.json.Stringify.valueAlloc(a, .{ .session_ref = unrelated_ref }, .{});
    defer a.free(unrelated_args);
    try std.testing.expectError(error.TargetNotAuthorized, testMetadata(&fixture, &roster, unrelated, "host.get_session", unrelated_args));
    var wrong_generation = owned;
    wrong_generation.generation += 1;
    const stale_ref = try @import("../ai/host_queries.zig").sessionRef(a, next, wrong_generation);
    defer a.free(stale_ref);
    const stale_args = try std.json.Stringify.valueAlloc(a, .{ .session_ref = stale_ref }, .{});
    defer a.free(stale_args);
    try std.testing.expectError(error.StaleReference, testMetadata(&fixture, &roster, next, "host.get_session", stale_args));
    try std.testing.expect(fixture.app.sessions.queryState(source).?.lifecycle == .attached);
    try std.testing.expect(store.findConversation(context.conversation_id).?.owner == .group);
    try std.testing.expect(fixture.workspace.groupTabId(@intCast(next.binding.group)) != null);
}

test "lifecycle controller Local disconnect is NotSupported and preserves the real process and tab" {
    const a = std.testing.allocator;
    var fixture: TestFixture = undefined;
    try fixture.init();
    var roster = groups.Roster.init(a);
    defer roster.deinit();
    defer fixture.deinit();
    const source = try fixture.local();
    const legacy = fixture.app.legacyForHandle(source).?;
    const tab_id = fixture.workspace.sessionTab(legacy).?.tab_id;
    var store = assistants.Store.init(a);
    defer store.deinit();
    var bridge = Bridge.init(a);
    defer bridge.deinit();
    const context = try testContext(&store, source);
    var controller = try Controller.init(.{ .allocator = a, .app = fixture.app, .roster = &roster, .store = &store, .bridge = &bridge, .authority = context, .execution_policy = .{ .execution_mode = .auto, .session_retention = .auto_idle } });
    defer controller.deinitAfterWorker();
    try std.testing.expect(!controller.available("host.disconnect_session"));
    var request: runtime.Call = .{ .context = context, .action = .{ .authorize = .{ .kind = .disconnect_session, .session = source, .request_key = "local-is-not-network" } } };
    try std.testing.expectError(error.NotSupported, Controller.invoke(&controller, &request));
    try std.testing.expectEqual(@as(usize, 0), fixture.app.disconnects.entries.items.len);
    try std.testing.expectEqual(tab_id, fixture.workspace.sessionTab(legacy).?.tab_id);
    try std.testing.expectEqual(@import("../host/session_host.zig").Lifecycle.attached, fixture.app.sessions.queryState(source).?.lifecycle);
    try std.testing.expect(fixture.app.findHandle(source).?.process != null);
}

test "lifecycle controller keeps exact metadata grant distinct from configuration revision" {
    const a = std.testing.allocator;
    var fixture: TestFixture = undefined;
    try fixture.init();
    var roster = groups.Roster.init(a);
    defer roster.deinit();
    defer fixture.deinit();
    const source = try fixture.local();
    var store = assistants.Store.init(a);
    defer store.deinit();
    var bridge = Bridge.init(a);
    defer bridge.deinit();
    bridge.policy_revision = fixture.workspace.app_config.config_revision;
    var context = try testContext(&store, source);
    context.grant_revision = bridge.policy_revision + 5;
    var controller = try Controller.init(.{ .allocator = a, .app = fixture.app, .roster = &roster, .store = &store, .bridge = &bridge, .authority = context, .execution_policy = .{ .execution_mode = .auto, .session_retention = .auto_idle } });
    defer controller.deinitAfterWorker();
    try controller.refreshAuthority(context);
    var authorize_call: runtime.Call = .{ .context = context, .action = .{ .authorize = .{ .kind = .create_group, .session = source, .request_key = "separate-grant" } } };
    try Controller.invoke(&controller, &authorize_call);
    authorize_call.context.grant_revision += 1;
    try std.testing.expectError(error.ScopeChanged, Controller.invoke(&controller, &authorize_call));
    bridge.policy_revision += 1;
    try std.testing.expectError(error.ScopeChanged, controller.refreshAuthority(context));
}

test "lifecycle controller invalidated group plan publishes no ghost and releases after grant change" {
    const a = std.testing.allocator;
    var fixture: TestFixture = undefined;
    try fixture.init();
    var roster = groups.Roster.init(a);
    defer roster.deinit();
    defer fixture.deinit();
    const source = try fixture.local();
    var store = assistants.Store.init(a);
    defer store.deinit();
    var bridge = Bridge.init(a);
    defer bridge.deinit();
    const context = try testContext(&store, source);
    var controller = try Controller.init(.{ .allocator = a, .app = fixture.app, .roster = &roster, .store = &store, .bridge = &bridge, .authority = context, .execution_policy = .{ .execution_mode = .auto, .session_retention = .auto_idle } });
    defer controller.deinitAfterWorker();
    const request: tools.Request = .{ .kind = .create_group, .request_key = "fault", .session = source, .name = "不可见预留组" };
    var authorize_call: runtime.Call = .{ .context = context, .action = .{ .authorize = request } };
    try Controller.invoke(&controller, &authorize_call);
    var prepare: runtime.Call = .{ .context = context, .action = .{ .prepare_group = .{ .operation = identity.HostOperationId.generate(), .request = request, .authorized = authorize_call.result.authorized } } };
    try Controller.invoke(&controller, &prepare);
    const plan = prepare.result.group_plan;
    const legacy = fixture.app.legacyForHandle(source).?;
    const tab = fixture.workspace.sessionTab(legacy).?;
    const model_index = fixture.workspace.model.indexOf(tab.tab_id).?;
    const model_tab = fixture.workspace.model.tabs.items[model_index];
    try fixture.workspace.model.rename(.{ .tab = model_tab.id, .owner = model_tab.owner, .revision = model_tab.revision }, "用户改动了原终端");
    var commit: runtime.Call = .{ .context = context, .action = .{ .commit_group = plan } };
    try std.testing.expectError(error.SourceChanged, Controller.invoke(&controller, &commit));
    try std.testing.expectEqual(@as(usize, 0), roster.groups.items.len);
    try std.testing.expect(store.findConversation(context.conversation_id).?.owner == .session);
    try std.testing.expect(fixture.workspace.groupTabId(@intCast(plan.id)) == null);
    bridge.policy_revision += 1;
    var release: runtime.Call = .{ .context = context, .action = .{ .release_group = plan } };
    try Controller.invoke(&controller, &release);
    try std.testing.expectEqual(@as(usize, 0), roster.reserved_groups);
    try std.testing.expectEqual(@as(usize, 0), fixture.workspace.prepared_group_views);
    try std.testing.expectEqual(@as(usize, 0), controller.prepared.items.len);
}

test "lifecycle controller group publication is allocation free after validated preparation" {
    const a = std.testing.allocator;
    var fixture: TestFixture = undefined;
    try fixture.init();
    var roster = groups.Roster.init(a);
    defer roster.deinit();
    defer fixture.deinit();
    const source = try fixture.local();
    var store = assistants.Store.init(a);
    defer store.deinit();
    var bridge = Bridge.init(a);
    defer bridge.deinit();
    const context = try testContext(&store, source);
    var controller = try Controller.init(.{ .allocator = a, .app = fixture.app, .roster = &roster, .store = &store, .bridge = &bridge, .authority = context, .execution_policy = .{ .execution_mode = .auto, .session_retention = .auto_idle } });
    defer controller.deinitAfterWorker();
    const request: tools.Request = .{ .kind = .create_group, .request_key = "noalloc", .session = source, .name = "已预分配工作组" };
    var authorize_call: runtime.Call = .{ .context = context, .action = .{ .authorize = request } };
    try Controller.invoke(&controller, &authorize_call);
    var prepare: runtime.Call = .{ .context = context, .action = .{ .prepare_group = .{ .operation = identity.HostOperationId.generate(), .request = request, .authorized = authorize_call.result.authorized } } };
    try Controller.invoke(&controller, &prepare);
    const plan = prepare.result.group_plan;
    var failure = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    controller.allocator = failure.allocator();
    roster.allocator = failure.allocator();
    store.allocator = failure.allocator();
    fixture.workspace.allocator = failure.allocator();
    var commit: runtime.Call = .{ .context = context, .action = .{ .commit_group = plan } };
    const committed = Controller.invoke(&controller, &commit);
    controller.allocator = a;
    roster.allocator = a;
    store.allocator = a;
    fixture.workspace.allocator = a;
    try committed;
    try std.testing.expectEqual(@as(usize, 1), roster.groups.items.len);
    try std.testing.expectEqual(@as(usize, 0), roster.reserved_groups);
    try std.testing.expectEqual(@as(usize, 0), fixture.workspace.prepared_group_views);
    try std.testing.expectEqual(plan.id, store.findConversation(context.conversation_id).?.owner.group);
    try std.testing.expect(fixture.workspace.groupTabId(@intCast(plan.id)) != null);
    var release: runtime.Call = .{ .context = context, .action = .{ .release_group = plan } };
    try Controller.invoke(&controller, &release);
    var next = context;
    next.binding = .{ .group = plan.id };
    next.binding_revision = plan.binding_revision;
    try controller.refreshAuthority(next);
    const rename: tools.Request = .{ .kind = .rename_group, .group = .{ .id = @fromBackingInt(plan.id) }, .name = "过期审批不应重命名", .request_key = "stale-membership" };
    var approved: runtime.Call = .{ .context = next, .action = .{ .authorize = rename } };
    try Controller.invoke(&controller, &approved);
    roster.groups.items[0].membership_revision += 1;
    var stale: runtime.Call = .{ .context = next, .action = .{ .mutate = .{ .operation = identity.HostOperationId.generate(), .request = rename, .authorized = approved.result.authorized } } };
    try std.testing.expectError(error.ScopeChanged, Controller.invoke(&controller, &stale));
    try std.testing.expectEqualStrings("已预分配工作组", roster.groups.items[0].name);
    fixture.config_.config_revision += 1;
    try std.testing.expectError(error.ScopeChanged, controller.refreshAuthority(next));
}

test "current-tab lifecycle rejects existing external selected handles and removed members before metadata" {
    const a = std.testing.allocator;
    var fixture: TestFixture = undefined;
    try fixture.init();
    var roster = groups.Roster.init(a);
    defer roster.deinit();
    defer fixture.deinit();
    const source = try fixture.local();
    const external = try fixture.local();
    var store = assistants.Store.init(a);
    defer store.deinit();
    var bridge = Bridge.init(a);
    defer bridge.deinit();
    const context = try testContext(&store, source);
    const external_asset: identity.AssetOwner = .{ .id = @fromBackingInt(999), .revision = 7 };
    var controller = try Controller.init(.{ .allocator = a, .app = fixture.app, .roster = &roster, .store = &store, .bridge = &bridge, .authority = context, .selected_sessions = &.{external}, .selected_sources = &.{external_asset}, .execution_policy = .{ .execution_mode = .auto, .session_retention = .auto_idle } });
    defer controller.deinitAfterWorker();
    for ([_]identity.SessionHandle{ external, .{ .session_id = @fromBackingInt(999999), .generation = 98 } }) |outside| {
        for ([_]tools.Kind{ .create_group, .add_group_member, .remove_group_member, .close_session, .disconnect_session, .reconnect_session, .set_session_retention, .wait_session_ready }) |kind| {
            try std.testing.expectError(error.TargetNotAuthorized, controller.validateRequestScope(context, .{ .kind = kind, .session = outside }));
            try std.testing.expectError(error.TargetNotAuthorized, controller.authorize(context, .{ .kind = kind, .session = outside }));
        }
        try std.testing.expectError(error.TargetNotAuthorized, controller.validateRequestScope(context, .{ .kind = .open_session, .source = outside }));
    }
    try std.testing.expectError(error.StaleReference, controller.authorizeAsset(external_asset));
    // The existing own session can still create its group, keeping the CID.
    const request: tools.Request = .{ .kind = .create_group, .request_key = "bounded-group", .session = source, .name = "current group" };
    const authorized = try controller.authorize(context, request);
    const plan = try controller.prepareGroup(context, .{ .operation = identity.HostOperationId.generate(), .request = request, .authorized = authorized });
    try controller.commitGroup(context, plan);
    try controller.releaseGroup(plan);
    var next = context;
    next.binding = .{ .group = plan.id };
    next.binding_revision = plan.binding_revision;
    try controller.refreshAuthority(next);
    const own_group: identity.GroupOwner = .{ .id = @fromBackingInt(plan.id) };
    _ = try controller.authorize(next, .{ .kind = .open_session, .group = own_group, .source = source, .connection_policy = .new_only });
    const legacy = fixture.app.legacyForHandle(source).?;
    roster.findById(@intCast(plan.id)).?.members.items[0].active = false;
    try std.testing.expect(!controller.inBinding(source));
    try std.testing.expectError(error.TargetNotAuthorized, controller.validateRequestScope(next, .{ .kind = .add_group_member, .group = own_group, .session = source }));
    try std.testing.expectError(error.TargetNotAuthorized, controller.validateRequestScope(next, .{ .kind = .open_session, .group = own_group, .source = source }));
    roster.findById(@intCast(plan.id)).?.members.items[0].active = true;
    try std.testing.expect(roster.findById(@intCast(plan.id)).?.contains(legacy));
    try std.testing.expect(controller.inBinding(source));
}

/// Real host-tool/Driver acceptance over the same product SSH service. The
/// loopback peer supplies only a PTY shell, never execution receipts.
const ShellProductExecution = struct {
    const execution = @import("../host/terminal_execution.zig");
    const Backend = @import("ai_execution_backend.zig");
    const Driver = @import("../ai/host_execution_driver.zig").Driver;
    const approvals = @import("../ai/host_approval.zig");
    const a = std.testing.allocator;
    const View = struct { snapshot: execution.Snapshot, output: []const u8, execution_ref: []const u8 };
    fixture: *TestFixture,
    controller: *Controller,
    broker: *approvals.Broker,
    backend: Backend.Context,
    driver: *Driver,
    sequence: u64 = 100,
    fn lookup(raw: *anyopaque, conversation: identity.ConversationId, task: identity.TaskId) ?*Controller {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return if (self.controller.authority.conversation_id.eql(conversation) and self.controller.authority.task_id.eql(task)) self.controller else null;
    }
    fn unavailable(_: *anyopaque, _: host.Invocation, _: std.mem.Allocator) !host.Result {
        return error.ToolNotAvailable;
    }
    fn init(self: *@This(), fixture: *TestFixture, controller: *Controller, broker: *approvals.Broker, journal: *runtime.ProcessJournal) !void {
        self.* = .{ .fixture = fixture, .controller = controller, .broker = broker, .backend = undefined, .driver = undefined };
        controller.bridge.host_binding = .{ .context = controller.authority, .handler_context = self, .invoke = unavailable, .contributions = &@import("../ai/host_execution.zig").contributions };
        self.backend = try Backend.Context.init(.{ .app = fixture.app, .roster = controller.roster, .store = controller.store, .lookup_context = self, .lookup_task = lookup, .approval = broker });
        try self.backend.captureTask(controller);
        self.driver = try Driver.start(a, journal, .{ .context = controller.bridge, .call = testScheduler }, self.backend.backend());
    }
    fn deinit(self: *@This()) void {
        self.driver.requestShutdown();
        while (!self.driver.shutdownReady()) self.fixture.tick(self.controller.bridge) catch unreachable;
        self.driver.finish() catch unreachable;
        self.controller.bridge.host_binding = null;
    }
    fn invoke(self: *@This(), tool: []const u8, arguments: anytype) !host.Result {
        const raw = try std.json.Stringify.valueAlloc(a, arguments, .{});
        defer a.free(raw);
        var parsed = try std.json.parseFromSlice(std.json.Value, a, raw, .{});
        defer parsed.deinit();
        self.sequence += 1;
        const call_id = try std.fmt.allocPrint(a, "shell-product-{d}", .{self.sequence});
        defer a.free(call_id);
        var invocation: host.Invocation = .{ .context = self.controller.authority, .authority = .execution_control, .operation_id = self.sequence, .turn_id = 2, .call_id = call_id, .tool_id = tool, .arguments = parsed.value, .arguments_json = raw, .arguments_hash = execution.digest(raw), .canonical_arguments_hash = try @import("../ai/canonical_arguments.zig").digest(a, parsed.value) };
        var prepared: ?Backend.Prepared = null;
        defer if (prepared) |*value| value.deinit();
        var input_prepared: ?Backend.InputPrepared = null;
        defer if (input_prepared) |*value| value.deinit();
        var evidence: Backend.ApprovalEvidence = undefined;
        var subject: ?approvals.Subject = null;
        const deadline = @import("../platform/realtime.zig").monotonicNs() + 10 * std.time.ns_per_s;
        if (std.mem.eql(u8, tool, "host.run_in_terminal")) {
            prepared = try Backend.prepare(invocation, a);
            invocation = prepared.?.invocation;
            while (true) {
                evidence = self.backend.preflight(invocation, prepared.?.command, prepared.?.command_hash) catch |err| {
                    // No dispatch occurs during preflight. A completed SSH
                    // interval can precede its next ready A/B prompt.
                    if ((err != error.WorkerBusy and err != error.TerminalBusy) or @import("../platform/realtime.zig").monotonicNs() > deadline) return err;
                    try self.fixture.tick(self.controller.bridge);
                    continue;
                };
                break;
            }
            prepared.?.subject.impact = evidence.text();
            subject = prepared.?.subject;
        } else if (std.mem.eql(u8, tool, "host.send_execution_input")) {
            while (true) {
                input_prepared = self.backend.preflightInput(invocation, a) catch |err| {
                    if (err != error.WorkerBusy or @import("../platform/realtime.zig").monotonicNs() > deadline) return err;
                    try self.fixture.tick(self.controller.bridge);
                    continue;
                };
                break;
            }
            subject = input_prepared.?.subject;
        }
        var permit: ?approvals.Permit = null;
        defer if (permit) |value| self.broker.finish(value);
        if (subject) |value| {
            try self.broker.configure(invocation.context, self.controller.config_revision);
            permit = try self.broker.beginSubject(invocation, value, self.controller.config_revision, a);
            try self.broker.decide(permit.?.sequence, permit.?.arguments_hash, true);
            invocation.approval_sequence = permit.?.sequence;
        }
        const Call = struct {
            driver: *Driver,
            invocation: host.Invocation,
            result: ?host.Result = null,
            failure: ?anyerror = null,
            done: std.atomic.Value(bool) = .init(false),
            fn run(call: *@This()) void {
                call.result = call.driver.executeAlloc(call.invocation, a, null) catch |err| blk: {
                    call.failure = err;
                    break :blk null;
                };
                call.done.store(true, .release);
            }
        };
        var call: Call = .{ .driver = self.driver, .invocation = invocation };
        const thread = try std.Thread.spawn(.{}, Call.run, .{&call});
        while (!call.done.load(.acquire)) {
            self.fixture.tick(self.controller.bridge) catch {
                self.driver.requestShutdown();
            };
            if (@import("../platform/realtime.zig").monotonicNs() > deadline) self.driver.requestShutdown();
        }
        thread.join();
        if (call.failure) |failure| return failure;
        var result = call.result orelse return error.MissingHostResult;
        errdefer result.deinit(a);
        try result.validate(invocation.context, invocation.operation_id);
        return result;
    }
    fn expectPromptBusy(self: *@This(), reference: []const u8) !void {
        const raw = try std.json.Stringify.valueAlloc(a, .{ .session_ref = reference, .command = "printf NEVER_ADMITTED", .request_key = "draft-must-stay-blocked" }, .{});
        defer a.free(raw);
        var parsed = try std.json.parseFromSlice(std.json.Value, a, raw, .{});
        defer parsed.deinit();
        self.sequence += 1;
        const invocation: host.Invocation = .{ .context = self.controller.authority, .authority = .execution_control, .operation_id = self.sequence, .turn_id = 2, .call_id = "blocked-draft-call", .tool_id = "host.run_in_terminal", .arguments = parsed.value, .arguments_json = raw, .arguments_hash = execution.digest(raw), .canonical_arguments_hash = try @import("../ai/canonical_arguments.zig").digest(a, parsed.value) };
        var prepared = try Backend.prepare(invocation, a);
        defer prepared.deinit();
        const deadline = @import("../platform/realtime.zig").monotonicNs() + 3 * std.time.ns_per_s;
        while (true) {
            _ = self.backend.preflight(prepared.invocation, prepared.command, prepared.command_hash) catch |err| {
                if (err == error.WorkerBusy and @import("../platform/realtime.zig").monotonicNs() < deadline) {
                    try self.fixture.tick(self.controller.bridge);
                    continue;
                }
                try std.testing.expectEqual(error.TerminalBusy, err);
                return;
            };
            return error.DraftWasAuthorized;
        }
    }
    fn run(self: *@This(), reference: []const u8, command: []const u8, key: []const u8) ![]u8 {
        var result = try self.invoke("host.run_in_terminal", .{ .session_ref = reference, .command = command, .request_key = key });
        defer result.deinit(a);
        try std.testing.expectEqual(@import("../ai/plugin_tools.zig").Status.succeeded, result.status);
        var view = try std.json.parseFromSlice(View, a, result.blocks[0].structured, .{ .ignore_unknown_fields = true });
        defer view.deinit();
        return a.dupe(u8, view.value.execution_ref);
    }
    const WaitFor = union(enum) { finished, input_ready, written: u64 };
    fn wait(self: *@This(), reference: []const u8, target: WaitFor) !host.Result {
        const deadline = @import("../platform/realtime.zig").monotonicNs() + 10 * std.time.ns_per_s;
        while (true) {
            var result = try self.invoke("host.wait_execution", .{ .execution_ref = reference, .wait_ms = 50, .output_cursor = "0", .max_bytes = 8192 });
            errdefer result.deinit(a);
            var view = try std.json.parseFromSlice(View, a, result.blocks[0].structured, .{ .ignore_unknown_fields = true });
            const snapshot = view.value.snapshot;
            view.deinit();
            const reached = switch (target) {
                .finished => snapshot.state == .interval_recorded,
                .input_ready => snapshot.state == .running and snapshot.input_wait != null,
                .written => |sequence| if (snapshot.input_receipt) |receipt| receipt.input_sequence == sequence and receipt.stage == .written else false,
            };
            if (reached) return result;
            if (snapshot.remote_effect_unknown or snapshot.state == .cancelled_unsent or snapshot.state == .recording_degraded or @import("../platform/realtime.zig").monotonicNs() > deadline) {
                std.debug.print("shell product AI wait failed: {s}\n", .{result.blocks[0].structured});
                return error.ShellProductExecutionNotFinished;
            }
            result.deinit(a);
        }
    }
    fn expectFinished(self: *@This(), reference: []const u8, owner: identity.SessionHandle, exit_code: u8, output: []const u8) !void {
        var result = try self.wait(reference, .finished);
        defer result.deinit(a);
        var view = try std.json.parseFromSlice(View, a, result.blocks[0].structured, .{ .ignore_unknown_fields = true });
        defer view.deinit();
        const snapshot = view.value.snapshot;
        try std.testing.expect(snapshot.owner.eql(owner) and snapshot.interval_saved and snapshot.recording_settled);
        try std.testing.expectEqual(execution.CompletionSource.shell_reported, snapshot.completion_source);
        try std.testing.expectEqual(@as(?u8, exit_code), snapshot.process.?.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, view.value.output, output) != null);
        try execution.PublicReceipt.fromSnapshot(snapshot).?.validate();
    }
    fn takeoverAndFinish(self: *@This(), reference: []const u8, owner: identity.SessionHandle, ssh_service: ?@import("../host/terminal_service.zig").Service) !void {
        const id = try identity.ExecutionId.parse(reference[3..]);
        const deadline = @import("../platform/realtime.zig").monotonicNs() + 8 * std.time.ns_per_s;
        // The real start boundary must exist before requesting human input.
        while (true) {
            var observed = try self.invoke("host.get_execution", .{ .execution_ref = reference });
            defer observed.deinit(a);
            var view = try std.json.parseFromSlice(View, a, observed.blocks[0].structured, .{ .ignore_unknown_fields = true });
            defer view.deinit();
            const accepted = view.value.snapshot.completion_source == .shell_reported or view.value.snapshot.command_accepted;
            if (view.value.snapshot.start != null and view.value.snapshot.grant != null and accepted and view.value.snapshot.submit_sent and view.value.snapshot.state == .running and outputLine(view.value.output, "TAKEOVER_BEGIN")) break;
            if (@import("../platform/realtime.zig").monotonicNs() > deadline) return error.TakeoverExecutionNotRunning;
        }
        if (ssh_service) |service| try shellProductControlledInput(self.fixture, service);
        try self.driver.requestTakeover(self.controller.authority, reference);
        while (true) {
            try self.fixture.tick(self.controller.bridge);
            if (self.driver.executionInputEvidence(self.controller.authority, id)) |fact| if (fact.input_handed_off and fact.local_released and !fact.has_grant) break;
            if (@import("../platform/realtime.zig").monotonicNs() > deadline) return error.TakeoverInputNotReleased;
        }
        var mid = try self.invoke("host.get_execution", .{ .execution_ref = reference });
        defer mid.deinit(a);
        var middle = try std.json.parseFromSlice(View, a, mid.blocks[0].structured, .{ .ignore_unknown_fields = true });
        defer middle.deinit();
        try std.testing.expect(middle.value.snapshot.input_handed_off and middle.value.snapshot.local_released and middle.value.snapshot.process == null);
        try std.testing.expect(!middle.value.snapshot.remote_effect_unknown and !middle.value.snapshot.recording_settled);
        try std.testing.expect(outputLine(middle.value.output, "TAKEOVER_BEGIN") and !outputLine(middle.value.output, "TAKEOVER_END"));
        if (ssh_service) |service| try shellProductHumanInput(self.fixture, service);
        // Model completion must not stop or reacquire the human's terminal.
        try self.driver.finishTask(self.controller.authority);
        var completion = try self.wait(reference, .finished);
        completion.deinit(a);
        var final = try self.invoke("host.get_execution", .{ .execution_ref = reference });
        defer final.deinit(a);
        var ended = try std.json.parseFromSlice(View, a, final.blocks[0].structured, .{ .ignore_unknown_fields = true });
        defer ended.deinit();
        try std.testing.expect(ended.value.snapshot.input_handed_off and ended.value.snapshot.grant == null and ended.value.snapshot.process.?.foreground_finished);
        try std.testing.expect(ended.value.snapshot.owner.eql(owner) and ended.value.snapshot.interval_saved and ended.value.snapshot.recording_settled);
        try std.testing.expectEqual(@as(?u8, 0), ended.value.snapshot.process.?.exit_code);
        try execution.PublicReceipt.fromSnapshot(ended.value.snapshot).?.validate();
        try std.testing.expect(outputLine(ended.value.output, "TAKEOVER_BEGIN") and outputLine(ended.value.output, "TAKEOVER_END"));
        if (ssh_service != null) try std.testing.expect(outputLine(ended.value.output, "TAKEOVER_HUMAN:human-after-takeover"));
        while (true) {
            try self.fixture.tick(self.controller.bridge);
            if (self.driver.taskEvidence(self.controller.authority.task_id)) |fact| if (fact.model_done and fact.executions_settled and fact.input_grants_released and fact.recordings_settled and fact.active_references == 0) break;
            if (@import("../platform/realtime.zig").monotonicNs() > deadline) return error.TakeoverTaskNotSettled;
        }
    }
    fn outputLine(output: []const u8, line: []const u8) bool {
        // The first output can follow a VT mode prefix on the same raw line.
        // Require the *actual* LF after a marker, not the echoed '\\n' input.
        var offset: usize = 0;
        while (std.mem.indexOfPos(u8, output, offset, line)) |at| {
            offset = at + line.len;
            var end = offset;
            if (end < output.len and output[end] == '\r') end += 1;
            if (end < output.len and output[end] == '\n') return true;
        }
        return false;
    }
};

test "lifecycle real Local takeover keeps original observation until natural finish and task settlement" {
    const a = std.testing.allocator;
    var fixture: TestFixture = undefined;
    try fixture.init();
    // This fixture's lifecycle-only default disables all RCS. The execution
    // test needs the normal private Local shell integration startup instead.
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".zshenv", .data = "PROMPT=''\nRPROMPT=''\n" });
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".zshrc", .data = "bindkey -e\n" });
    try fixture.app.local_adapter.configureRecording(.{ .io = std.testing.io, .directory = fixture.directory, .log = .{ .ring_mb = 2, .checkpoint_sec = 1 } });
    var roster = groups.Roster.init(a);
    defer roster.deinit();
    defer fixture.deinit();
    const source = try fixture.local();
    const ready_deadline = @import("../platform/realtime.zig").monotonicNs() + 8 * std.time.ns_per_s;
    while (true) {
        try fixture.tick(null);
        if (fixture.app.legacyForHandle(source)) |legacy| if (fixture.workspace.sessionTab(legacy)) |tab| if (tab.terminal) |view| if (view.terminal_surface) |surface| {
            const snapshot = surface.service.executionSnapshot() catch |err| {
                if (err == error.WorkerBusy) continue;
                return err;
            };
            if (snapshot.interactive_execution and snapshot.input_ready) break;
        };
        if (@import("../platform/realtime.zig").monotonicNs() > ready_deadline) return error.LocalExecutionNotReady;
    }
    var store = assistants.Store.init(a);
    defer store.deinit();
    var bridge = Bridge.init(a);
    defer bridge.deinit();
    const context = try testContext(&store, source);
    var controller = try Controller.init(.{ .allocator = a, .app = fixture.app, .roster = &roster, .store = &store, .bridge = &bridge, .authority = context, .execution_policy = .{ .execution_mode = .attached_pty, .session_retention = .keep } });
    defer controller.deinitAfterWorker();
    const journal = try runtime.ProcessJournal.acquire(.{ .data_root = fixture.directory, .path = "local-takeover-finish.json" });
    defer journal.release();
    var broker: @import("../ai/host_approval.zig").Broker = .{};
    var execution_driver: ShellProductExecution = undefined;
    try execution_driver.init(&fixture, &controller, &broker, journal);
    defer execution_driver.deinit();
    const reference = try @import("../ai/host_queries.zig").sessionRef(a, context, source);
    defer a.free(reference);
    const active = try execution_driver.run(reference, "printf 'TAKEOVER_BEGIN\\n'; sleep 2; printf 'TAKEOVER_END\\n'", "local-takeover-finish");
    defer a.free(active);
    try execution_driver.takeoverAndFinish(active, source, null);
    std.debug.print("LOCAL_PRODUCT_TAKEOVER_PASS same_execution=true natural_end=true complete_output=true task_settled=true\n", .{});
}

// Uses the real SSH Provider/encoder and the fixture's interactive shell. A
// no-op native event must not dirty its prompt; actual editing remains gated
// until the shell reports a fresh A/B after the explicit user interrupt.
fn shellProductPromptReadiness(fixture: *TestFixture, service: @import("../host/terminal_service.zig").Service, driver: *ShellProductExecution, reference: []const u8) !void {
    const Terminal = @import("../host/terminal_service.zig");
    const deadline = @import("../platform/realtime.zig").monotonicNs() + 8 * std.time.ns_per_s;
    var initial: Terminal.execution.Snapshot = undefined;
    var mode: u64 = 0;
    var geometry: u64 = 0;
    while (true) {
        if (@import("../platform/realtime.zig").monotonicNs() > deadline) return error.ShellPromptNotReady;
        try fixture.tick(null);
        initial = service.executionSnapshot() catch |err| {
            if (err == error.WorkerBusy) continue;
            return err;
        };
        _ = service.status() catch |err| {
            if (err == error.WorkerBusy) continue;
            return err;
        };
        var screen = service.snapshot(std.testing.allocator) catch |err| {
            if (err == error.WorkerBusy) continue;
            return err;
        };
        defer screen.deinit(std.testing.allocator);
        if (initial.input_ready) {
            mode = screen.projection.mode_revision;
            geometry = screen.geometry_revision;
            break;
        }
        if (@import("../platform/realtime.zig").monotonicNs() > deadline) return error.ShellPromptNotReady;
    }
    const mouse = try shellProductSubmit(fixture, service, Terminal.Service.writeMouse, Terminal.MouseRequest{ .input_sequence = 1, .mode_revision = mode, .geometry_revision = geometry, .event = .{ .action = .press, .button = .left, .x = 10, .y = 10, .screen_width = 640, .screen_height = 480, .cell_width = 8, .cell_height = 16 } });
    try std.testing.expectEqual(@as(usize, 0), mouse.queued_bytes);
    const modifier = try shellProductSubmit(fixture, service, Terminal.Service.writeKey, Terminal.KeyRequest{ .input_sequence = 2, .mode_revision = mode, .event = .{ .key = .unidentified, .modifiers = .{ .shift = true } } });
    try std.testing.expectEqual(@as(usize, 0), modifier.queued_bytes);
    // No worker tick is needed: this checks admission itself, before any
    // remote output could accidentally make the prompt ready again.
    const untouched = try shellProductExecutionSnapshot(fixture, service);
    try std.testing.expect(untouched.input_ready and untouched.grant == null);
    try std.testing.expectEqual(initial.input_epoch, untouched.input_epoch);
    std.debug.print("SHELL_PRODUCT_NOOP_INPUT_PASS mouse_bytes=0 modifier_bytes=0 epoch_unchanged=true ready=true\n", .{});

    _ = try shellProductSubmit(fixture, service, Terminal.Service.write, Terminal.WriteRequest{ .input_sequence = 3, .mode_revision = mode, .bytes = "printf NEVER_EXECUTE_DRAFT" });
    // Require the real shell's editor echo before testing its clear operation.
    while (true) {
        try fixture.tick(null);
        if (try shellProductScreenContains(service, "NEVER_EXECUTE_DRAFT")) break;
        if (@import("../platform/realtime.zig").monotonicNs() > deadline) return error.ShellDraftNotEchoed;
    }
    try std.testing.expect(!(try shellProductExecutionSnapshot(fixture, service)).input_ready);
    _ = try shellProductSubmit(fixture, service, Terminal.Service.write, Terminal.WriteRequest{ .input_sequence = 4, .mode_revision = mode, .bytes = "\x15" });
    // Ctrl+U is explicit fixture user input. Its visible edit is not trusted
    // as an empty-editor receipt and must never authorize AI injection.
    while (true) {
        try fixture.tick(null);
        const present = shellProductScreenContains(service, "NEVER_EXECUTE_DRAFT") catch |err| {
            if (err == error.WorkerBusy) continue;
            return err;
        };
        if (!present) break;
        if (@import("../platform/realtime.zig").monotonicNs() > deadline) return error.ShellDraftNotCleared;
    }
    const cleared = try shellProductExecutionSnapshot(fixture, service);
    try std.testing.expect(!cleared.input_ready and cleared.grant == null);
    try driver.expectPromptBusy(reference);
    // A user's interrupt produces the real next shell prompt; the application
    // never sends recovery keys to silently erase or submit a user's draft.
    _ = try shellProductSubmit(fixture, service, Terminal.Service.write, Terminal.WriteRequest{ .input_sequence = 5, .mode_revision = mode, .bytes = "\x03" });
    while (true) {
        try fixture.tick(null);
        const restored = try shellProductExecutionSnapshot(fixture, service);
        if (restored.input_ready) {
            try std.testing.expect(restored.owner.eql(initial.owner));
            try std.testing.expectEqual(Terminal.execution.CompletionSource.shell_reported, restored.completion_source);
            break;
        }
        if (@import("../platform/realtime.zig").monotonicNs() > deadline) return error.ShellPromptNotRestored;
    }
    std.debug.print("SHELL_PRODUCT_DRAFT_GATE_PASS draft_blocked=true ctrl_u_still_blocked=true ctrl_c_shell_prompt_restored=true same_session=true\n", .{});
}

fn shellProductControlledInput(fixture: *TestFixture, service: @import("../host/terminal_service.zig").Service) !void {
    const Terminal = @import("../host/terminal_service.zig");
    const provider: *@import("../plugins/ssh/terminal_service.zig").Provider = @ptrCast(@alignCast(service.context));
    const before = provider.input_sequence;
    const epoch = (try shellProductExecutionSnapshot(fixture, service)).input_epoch;
    try std.testing.expectError(error.TerminalControlled, shellProductSubmit(fixture, service, Terminal.Service.write, Terminal.WriteRequest{ .input_sequence = before + 1, .bytes = "NEVER_READONLY_WRITE" }));
    try std.testing.expectError(error.TerminalControlled, shellProductSubmit(fixture, service, Terminal.Service.writeKey, Terminal.KeyRequest{ .input_sequence = before + 1, .mode_revision = 1, .event = .{ .key = .enter } }));
    try std.testing.expectError(error.TerminalControlled, shellProductSubmit(fixture, service, Terminal.Service.writeKey, Terminal.KeyRequest{ .input_sequence = before + 1, .mode_revision = 1, .event = .{ .key = .c, .utf8 = "c", .unshifted_codepoint = 'c', .modifiers = .{ .control = true } } }));
    var paste = try shellProductPreparePaste(fixture, service, "NEVER_READONLY_PASTE");
    defer paste.deinit(std.testing.allocator);
    const deadline = @import("../platform/realtime.zig").monotonicNs() + 3 * std.time.ns_per_s;
    while (true) {
        _ = service.commitPaste(paste, before + 1, false) catch |err| {
            if (err == error.WorkerBusy and @import("../platform/realtime.zig").monotonicNs() < deadline) {
                try fixture.tick(null);
                continue;
            }
            try std.testing.expectEqual(error.TerminalControlled, err);
            break;
        };
        return error.ReadOnlyPasteWasQueued;
    }
    try std.testing.expectEqual(before, provider.input_sequence);
    try std.testing.expect(provider.pending_paste == null);
    try std.testing.expectEqual(@as(usize, 0), provider.native.worker.input.pending());
    try std.testing.expectEqual(epoch, (try shellProductExecutionSnapshot(fixture, service)).input_epoch);
    std.debug.print("SHELL_PRODUCT_READONLY_PASS write=true key=true ctrl_c=true paste=true pending=0 sequence_unchanged=true epoch_unchanged=true\n", .{});
}

fn shellProductPreparePaste(fixture: *TestFixture, service: @import("../host/terminal_service.zig").Service, text: []const u8) !@import("../host/terminal_service.zig").Paste {
    const deadline = @import("../platform/realtime.zig").monotonicNs() + 3 * std.time.ns_per_s;
    while (true) return service.preparePaste(std.testing.allocator, text) catch |err| {
        if (err != error.WorkerBusy or @import("../platform/realtime.zig").monotonicNs() > deadline) return err;
        try fixture.tick(null);
        continue;
    };
}

fn shellProductHumanInput(fixture: *TestFixture, service: @import("../host/terminal_service.zig").Service) !void {
    const Terminal = @import("../host/terminal_service.zig");
    const provider: *@import("../plugins/ssh/terminal_service.zig").Provider = @ptrCast(@alignCast(service.context));
    try std.testing.expect(provider.pending_paste == null);
    try std.testing.expectEqual(@as(usize, 0), provider.native.worker.input.pending());
    var paste = try shellProductPreparePaste(fixture, service, "human-after-takeover");
    defer paste.deinit(std.testing.allocator);
    const sequence = provider.input_sequence + 1;
    const deadline = @import("../platform/realtime.zig").monotonicNs() + 3 * std.time.ns_per_s;
    while (true) {
        _ = service.commitPaste(paste, sequence, false) catch |err| {
            if (err != error.WorkerBusy or @import("../platform/realtime.zig").monotonicNs() > deadline) return err;
            try fixture.tick(null);
            continue;
        };
        break;
    }
    while (provider.pending_paste != null) {
        _ = service.takeWriteReceipt() catch |err| {
            if (err != error.WorkerBusy or @import("../platform/realtime.zig").monotonicNs() > deadline) return err;
            try fixture.tick(null);
            continue;
        };
        try fixture.tick(null);
    }
    _ = try shellProductSubmit(fixture, service, Terminal.Service.writeKey, Terminal.KeyRequest{ .input_sequence = sequence + 1, .mode_revision = 1, .event = .{ .key = .enter } });
    std.debug.print("SHELL_PRODUCT_HUMAN_INPUT_PASS old_payload=0 new_paste=true enter=true same_execution=true\n", .{});
}

fn shellProductScreenContains(service: @import("../host/terminal_service.zig").Service, marker: []const u8) !bool {
    const a = std.testing.allocator;
    var screen = try service.snapshot(a);
    defer screen.deinit(a);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    for (screen.projection.cells) |cell| try text.appendSlice(a, screen.projection.grapheme(cell));
    return std.mem.indexOf(u8, text.items, marker) != null;
}

fn shellProductSubmit(fixture: *TestFixture, service: @import("../host/terminal_service.zig").Service, comptime method: anytype, request: anytype) !@import("../host/terminal_service.zig").Submission {
    const deadline = @import("../platform/realtime.zig").monotonicNs() + 3 * std.time.ns_per_s;
    while (true) {
        const status = service.status() catch |err| {
            if (err != error.WorkerBusy or @import("../platform/realtime.zig").monotonicNs() > deadline) return err;
            try fixture.tick(null);
            continue;
        };
        var current = request;
        current.mode_revision = status.mode_revision;
        if (@hasField(@TypeOf(request), "geometry_revision")) current.geometry_revision = status.geometry.revision;
        return @call(.auto, method, .{ service, current }) catch |err| {
            // These are pre-admission races with real PTY mode/resize updates;
            // retry only unaccepted user input with freshly observed metadata.
            if ((err != error.WorkerBusy and err != error.StaleMode and err != error.StaleGeometry) or @import("../platform/realtime.zig").monotonicNs() > deadline) return err;
            try fixture.tick(null);
            continue;
        };
    }
}

fn shellProductExecutionSnapshot(fixture: *TestFixture, service: @import("../host/terminal_service.zig").Service) !@import("../host/terminal_service.zig").execution.Snapshot {
    const deadline = @import("../platform/realtime.zig").monotonicNs() + 3 * std.time.ns_per_s;
    while (true) {
        return service.executionSnapshot() catch |err| {
            if (err != error.WorkerBusy or @import("../platform/realtime.zig").monotonicNs() > deadline) return err;
            try fixture.tick(null);
            continue;
        };
    }
}

test "lifecycle default shell integration opens SSH work terminal without helper approval" {
    const raw_port = std.c.getenv("ZW_TEST_BOOTSTRAP_PRODUCT_PORT") orelse return error.SkipZigTest;
    const isolated = std.c.getenv("ZEROWORK_DATA_DIR") orelse return error.IsolatedBootstrapTestDirectoryRequired;
    if (!std.mem.startsWith(u8, std.mem.span(isolated), "/tmp/zw-bootstrap-product")) return error.IsolatedBootstrapTestDirectoryRequired;
    const port = try std.fmt.parseInt(u16, std.mem.span(raw_port), 10);
    const a = std.testing.allocator;
    var fixture: TestFixture = undefined;
    try fixture.init();
    // Reject any legacy deployment approval; default session creation must never ask for one.
    fixture.reject_bootstrap_deployment = true;
    fixture.acknowledge_ssh_frames = true;
    fixture.config_.ssh.auto_reconnect = false;
    fixture.config_.ssh.reconnect_max = 0;
    var roster = groups.Roster.init(a);
    defer roster.deinit();
    defer fixture.deinit();
    const index = try fixture.workspace.appendHost(.{ .connection_id = @fromBackingInt(88001), .revision = 1, .name = "controlled-bootstrap-product", .host = "127.0.0.1", .port = port, .user = "bootstrap-fixture", .auth_mode = .password, .password = "fixture-only", .strict_host_key_checking = false });
    const accepted = try fixture.app.create(fixture.workspace.registry.hosts[index], fixture.workspace.hostId(index).?, index, "");
    const source = accepted.handle;
    const source_deadline = @import("../platform/realtime.zig").monotonicNs() + 8 * std.time.ns_per_s;
    while (fixture.app.sessions.queryState(source).?.lifecycle != .attached) {
        for (fixture.workspace.connect_jobs.items) |job| if (job.host_key_bridge.snapshot()) |challenge| {
            try std.testing.expectEqualStrings("127.0.0.1", challenge.hostSlice());
            try std.testing.expectEqual(port, challenge.port);
            const key = challenge.operation_key orelse return error.MissingOperation;
            try std.testing.expect(key.owner == .session and key.owner.session.eql(source));
            try std.testing.expect(job.host_key_bridge.decideScoped(.{ .key = key, .hop_index = challenge.hop_index, .request_id = challenge.generation }, .trust_once));
        };
        try fixture.tick(null);
        if (@import("../platform/realtime.zig").monotonicNs() > source_deadline) return error.BootstrapSourceNotReady;
    }
    var store = assistants.Store.init(a);
    defer store.deinit();
    var bridge = Bridge.init(a);
    defer bridge.deinit();
    const context = try testContext(&store, source);
    var controller = try Controller.init(.{ .allocator = a, .app = fixture.app, .roster = &roster, .store = &store, .bridge = &bridge, .authority = context, .execution_policy = .{ .execution_mode = .new_pty, .session_retention = .keep } });
    defer controller.deinitAfterWorker();
    const journal_owner = try runtime.ProcessJournal.acquire(.{ .data_root = fixture.directory, .path = "ssh-bootstrap-product.json" });
    defer journal_owner.release();
    var broker: @import("../ai/host_approval.zig").Broker = .{};
    var backend: runtime.Runtime = .{ .journal_owner = journal_owner, .controller = controller.handle(), .approval = &broker };
    const source_ref = try @import("../ai/host_queries.zig").sessionRef(a, context, source);
    defer a.free(source_ref);
    const group_args = try std.json.Stringify.valueAlloc(a, .{ .initial_session_ref = source_ref, .name = "bootstrap-product-group", .request_key = "product-group" }, .{});
    defer a.free(group_args);
    var grouped = try testInvoke(&fixture, &controller, &backend, &broker, "host.create_group", group_args);
    defer grouped.deinit(a);
    try std.testing.expectEqual(@import("../ai/plugin_tools.zig").Status.succeeded, grouped.status);
    const moved = store.findConversation(context.conversation_id).?;
    var next = context;
    next.binding = moved.owner;
    next.binding_revision = moved.binding_revision;
    try controller.refreshAuthority(next);
    const group_ref = try @import("../ai/host_queries.zig").groupRef(a, next, next.binding.group);
    defer a.free(group_ref);
    for ([_]@import("../host/lifecycle_supervisor.zig").ConnectionPolicy{ .reuse_only, .new_only, .prefer_reuse }) |policy| {
        const allowed = try controller.authorize(next, .{ .kind = .open_session, .group = try controller.groupOwner(next.binding.group), .source = source, .connection_policy = policy, .interactive_execution = true });
        try std.testing.expect(!allowed.bootstrap_required);
        try std.testing.expectEqual(policy == .prefer_reuse, allowed.allow_new_fallback);
    }
    const args = try std.json.Stringify.valueAlloc(a, .{ .group_ref = group_ref, .source_ref = source_ref, .connection_policy = "reuse_only", .interactive_execution = true, .request_key = "product-open" }, .{});
    defer a.free(args);
    var opened = try testInvoke(&fixture, &controller, &backend, &broker, "host.open_session", args);
    defer opened.deinit(a);
    if (opened.status != .succeeded) std.debug.print("bootstrap product open receipt: {s}\n", .{opened.blocks[0].structured});
    try std.testing.expectEqual(@import("../ai/plugin_tools.zig").Status.succeeded, opened.status);
    const operation = fixture.app.lifecycle_supervisor.entries.items[0].request.operation_ref;
    const owned = fixture.app.lifecycle_supervisor.entries.items[0].snapshot.session.?;
    const deadline = @import("../platform/realtime.zig").monotonicNs() + 8 * std.time.ns_per_s;
    var last_execution: ?@import("../host/terminal_execution.zig").Snapshot = null;
    while (true) {
        try fixture.tick(&bridge);
        const snapshot = try fixture.app.queryOwnedSession(operation, next);
        if (snapshot.state == .failed or snapshot.state == .cleanup_pending) {
            std.debug.print("bootstrap product session error: {s}\n", .{snapshot.error_code orelse "unknown"});
            return error.BootstrapProductSessionFailed;
        }
        const mapping = fixture.app.findHandle(owned);
        if (snapshot.state == .ready and mapping != null) {
            const tab = fixture.workspace.sessionTab(mapping.?.legacy_id).?;
            const service = try tab.runtime.?.terminalService();
            const execution = service.executionSnapshot() catch |err| switch (err) {
                error.WorkerBusy => continue,
                else => return err,
            };
            last_execution = execution;
            if (execution.interactive_execution) {
                try std.testing.expectEqual(@import("../host/terminal_execution.zig").CompletionSource.shell_reported, execution.completion_source);
                break;
            }
        }
        if (@import("../platform/realtime.zig").monotonicNs() > deadline) {
            if (last_execution) |value| std.debug.print("shell product execution timeout state={s} source={s} capability={} input_ready={} failure={?s}\n", .{ @tagName(value.state), @tagName(value.completion_source), value.interactive_execution, value.input_ready, value.failure });
            return error.ShellIntegrationSessionNotReady;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), fixture.bootstrap_approvals_seen);
    try std.testing.expectEqual(@as(usize, 2), roster.findById(@intCast(next.binding.group)).?.members.items.len);
    const source_mapping = fixture.app.findHandle(source).?;
    const source_runtime = fixture.workspace.sessionTab(source_mapping.legacy_id).?.runtime.?;
    const source_terminal = try source_runtime.terminalService();
    const source_execution = try source_terminal.executionSnapshot();
    try std.testing.expectEqual(@import("../host/terminal_execution.zig").CompletionSource.shell_reported, source_execution.completion_source);
    try std.testing.expectEqual(@import("../host/session_host.zig").Lifecycle.attached, fixture.app.sessions.queryState(source).?.lifecycle);
    try std.testing.expect(!source.eql(owned));
    const registered_terminal = switch (fixture.app.sessions.queryService(owned, .terminal)) {
        .available => |value| value,
        else => return error.TerminalServiceUnavailable,
    };
    const owned_mapping = fixture.app.findHandle(owned).?;
    const owned_service = try fixture.workspace.sessionTab(owned_mapping.legacy_id).?.runtime.?.terminalService();
    try std.testing.expect(owned_service.binding.eql(registered_terminal));
    try std.testing.expect(fixture.app.sessions.bindingIsLive(owned_service.binding));
    var execution_driver: ShellProductExecution = undefined;
    try execution_driver.init(&fixture, &controller, &broker, journal_owner);
    defer execution_driver.deinit();
    const owned_ref = try @import("../ai/host_queries.zig").sessionRef(a, next, owned);
    defer a.free(owned_ref);
    try shellProductPromptReadiness(&fixture, owned_service, &execution_driver, owned_ref);
    const first = try execution_driver.run(owned_ref, "cd /tmp; ZW_AI_STATE=persistent; printf 'AI_READY:%s\\n' \"$ZW_AI_STATE\"", "ai-state-first");
    defer a.free(first);
    try execution_driver.expectFinished(first, owned, 0, "AI_READY:persistent");
    const second = try execution_driver.run(owned_ref, "printf 'AI_STATE:%s:%s\\n' \"$PWD\" \"$ZW_AI_STATE\"; (exit 7)", "ai-state-second");
    defer a.free(second);
    try execution_driver.expectFinished(second, owned, 7, "AI_STATE:/tmp:persistent");
    const interactive = try execution_driver.run(owned_ref, "read -r -t 5 ZW_AI_ANSWER; printf 'AI_ANSWER:%s\\n' \"$ZW_AI_ANSWER\"", "ai-input-run");
    defer a.free(interactive);
    var waiting = try execution_driver.wait(interactive, .input_ready);
    waiting.deinit(a);
    var typed = try execution_driver.invoke("host.send_execution_input", .{ .execution_ref = interactive, .request_key = "ai-input-text", .text = "ordinary-answer" });
    defer typed.deinit(a);
    var typed_receipt = try std.json.parseFromSlice(struct { input_receipt: @import("../host/terminal_execution.zig").InputReceipt }, a, typed.blocks[0].structured, .{ .ignore_unknown_fields = true });
    defer typed_receipt.deinit();
    var written = try execution_driver.wait(interactive, .{ .written = typed_receipt.value.input_receipt.input_sequence });
    written.deinit(a);
    var entered = try execution_driver.invoke("host.send_execution_input", .{ .execution_ref = interactive, .request_key = "ai-input-enter", .key = "enter" });
    entered.deinit(a);
    try execution_driver.expectFinished(interactive, owned, 0, "AI_ANSWER:ordinary-answer");
    const takeover = try execution_driver.run(owned_ref, "printf 'TAKEOVER_BEGIN\\n'; read -r -t 5 ZW_HUMAN; printf 'TAKEOVER_HUMAN:%s\\n' \"$ZW_HUMAN\"; sleep 0.3; printf 'TAKEOVER_END\\n'", "ssh-takeover-finish");
    defer a.free(takeover);
    try execution_driver.takeoverAndFinish(takeover, owned, owned_service);
    std.debug.print("SHELL_PRODUCT_TAKEOVER_PASS same_execution=true natural_end=true complete_output=true task_settled=true\n", .{});
    // A shell's next input prompt is not this Task's native lease. Finish the
    // real Driver and wait for its execution/input/recording settlement facts.
    try execution_driver.driver.finishTask(controller.authority);
    const settlement_deadline = @import("../platform/realtime.zig").monotonicNs() + 5 * std.time.ns_per_s;
    while (true) {
        try fixture.tick(controller.bridge);
        if (execution_driver.driver.taskEvidence(controller.authority.task_id)) |fact| if (fact.model_done and fact.executions_settled and fact.input_grants_released and fact.recordings_settled and fact.active_references == 0) break;
        if (@import("../platform/realtime.zig").monotonicNs() > settlement_deadline) return error.ShellProductTaskNotSettled;
    }
    std.debug.print("SHELL_PRODUCT_SETTLED model_done=true input_released=true recordings_settled=true\n", .{});
    std.debug.print("SHELL_PRODUCT_AI_PASS run=3 wait=true input=text+enter same_session=true source=shell_reported exits=0,7,0\n", .{});
}

// Include the narrow real Provider admission tests in the root test runner.
test {
    _ = @import("../plugins/ssh/terminal_service.zig");
}
