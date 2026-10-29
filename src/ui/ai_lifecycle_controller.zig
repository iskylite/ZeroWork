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
    selected_sessions: []const identity.SessionHandle,
    selected_sources: []const identity.AssetOwner,
    callbacks: Callbacks,
    prepared: std.ArrayList(*Prepared) = .empty,
    close_targets: std.ArrayList(CloseTarget) = .empty,
    open_authorizations: std.ArrayList(OpenAuthorization) = .empty,
    last_authorization: ?struct { kind: tools.Kind, value: runtime.Authorized } = null,

    pub fn init(options: Init) !Controller {
        try options.authority.validate();
        if ((options.callbacks.on_handoff != null or options.callbacks.on_membership_changed != null) and options.callbacks.context == null) return error.InvalidCallbacks;
        const sessions = try options.allocator.dupe(identity.SessionHandle, options.selected_sessions);
        errdefer options.allocator.free(sessions);
        const sources = try options.allocator.dupe(identity.AssetOwner, options.selected_sources);
        errdefer options.allocator.free(sources);
        var self: Controller = .{ .allocator = options.allocator, .app = options.app, .roster = options.roster, .store = options.store, .bridge = options.bridge, .authority = options.authority, .execution_policy = options.execution_policy, .config_revision = options.app.workspace.app_config.config_revision, .notice_revision = options.notice_revision, .selected_sessions = sessions, .selected_sources = sources, .callbacks = options.callbacks };
        try self.validateAuthority(options.authority);
        return self;
    }
    pub fn available(self: *Controller, tool_id: []const u8) bool {
        const kind = tools.kind(tool_id) orelse return false;
        return switch (kind) {
            .create_group => self.authority.binding == .session,
            .open_session, .rename_group, .add_group_member, .remove_group_member => self.authority.binding == .group,
            .disconnect_session => false,
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
        if (state.closed or !state.owner.eql(authority.binding) or state.binding_revision != authority.binding_revision or self.bridge.policy_revision != authority.grant_revision or authority.grant_revision != self.authority.grant_revision or self.app.workspace.app_config.config_revision != self.config_revision) return error.ScopeChanged;
        self.authority = authority;
    }
    /// Called on the controller thread only after its worker joined. This is
    /// also the Stop fallback if Bridge refused a cancelled release callback.
    pub fn deinitAfterWorker(self: *Controller) void {
        for (self.prepared.items) |plan| self.destroyPlan(plan);
        self.prepared.deinit(self.allocator);
        self.close_targets.deinit(self.allocator);
        self.open_authorizations.deinit(self.allocator);
        self.allocator.free(self.selected_sessions);
        self.allocator.free(self.selected_sources);
        self.* = undefined;
    }
    fn validateAuthority(self: *Controller, context: host.Context) !void {
        if (!self.authority.eql(context) or self.bridge.policy_revision != context.grant_revision or self.app.workspace.app_config.config_revision != self.config_revision) return error.ScopeChanged;
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
    fn inBinding(self: *Controller, handle_: identity.SessionHandle) bool {
        const legacy = self.app.legacyForHandle(handle_) orelse return false;
        return switch (self.authority.binding) {
            .session => |id| id == @backingInt(handle_.session_id),
            .group => |id| if (self.roster.findById(std.math.cast(u32, id) orelse return false)) |group| group.contains(legacy) else false,
        };
    }
    fn selected(self: *Controller, handle_: identity.SessionHandle) bool {
        for (self.selected_sessions) |item| if (item.eql(handle_)) return true;
        return false;
    }
    fn taskOwned(self: *Controller, handle_: identity.SessionHandle) bool {
        const entry = self.app.lifecycle_supervisor.resource(handle_) orelse return false;
        return entry.request.context.conversation_id.eql(self.authority.conversation_id) and entry.request.context.task_id.eql(self.authority.task_id) and entry.snapshot.ownership == .created_task;
    }
    fn associatedAsset(self: *Controller, handle_: identity.SessionHandle) ?identity.AssetOwner {
        const mapping = self.app.findHandle(handle_) orelse return null;
        if (mapping.source) |source| {
            const saved = source.value.host;
            if (@backingInt(saved.connection_id) != 0) return .{ .id = saved.connection_id, .revision = saved.revision };
        }
        const envelope = self.app.sessions.connectionEnvelope(handle_) orelse return null;
        return if (@backingInt(envelope.id) != 0) .{ .id = envelope.id, .revision = envelope.revision } else null;
    }
    fn authorizeAsset(self: *Controller, source: identity.AssetOwner) !void {
        const index = self.app.workspace.registry.indexOf(source.id) orelse return error.StaleReference;
        const saved = self.app.workspace.registry.hosts[index];
        if (saved.revision != source.revision) return error.SourceChanged;
        if (!std.mem.eql(u8, saved.protocolId(), "ssh")) return error.UnsupportedSource;
        for (self.selected_sources) |selected_source| if (std.meta.eql(source, selected_source)) return;
        // Only immutable source identities actually associated with this
        // binding's live members are allowed. Never scan all registry assets.
        for (self.app.mappings.items) |mapping| {
            if (!self.inBinding(mapping.handle)) continue;
            if (self.associatedAsset(mapping.handle)) |associated| if (std.meta.eql(associated, source)) return;
        }
        return error.TargetNotAuthorized;
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
    fn authorize(self: *Controller, context: host.Context, request: tools.Request) !runtime.Authorized {
        try self.validateAuthority(context);
        var result: runtime.Authorized = .{ .session = request.session, .source = request.source, .saved_source = request.saved_source, .retention = request.retention orelse self.execution_policy.session_retention, .approval_required = true, .policy_revision = self.config_revision };
        if (request.group) |group| {
            if (context.binding != .group or context.binding.group != @backingInt(group.id)) return error.TargetOutsideScope;
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
                    if (!self.inBinding(source)) return error.TargetOutsideScope;
                    _ = try self.validateIdentity(source, true);
                    const mapping = self.app.findHandle(source).?;
                    if (mapping.process != null and request.connection_policy != .new_only) return error.UnsupportedSource;
                } else {
                    try self.authorizeAsset(request.saved_source.?);
                    if (request.connection_policy == .reuse_only) return error.ReuseUnavailable;
                }
                // Exact approval explicitly includes any new transport fallback.
                result.allow_new_fallback = request.connection_policy == .prefer_reuse;
            },
            .rename_group => {},
            .add_group_member => {
                const target = request.session orelse return error.InvalidArguments;
                _ = try self.validateIdentity(target, true);
                if (!self.inBinding(target) and !self.selected(target)) return error.TargetNotAuthorized;
                try self.checkMembershipDependencies(target);
            },
            .remove_group_member => {
                const target = request.session orelse return error.InvalidArguments;
                if (!self.inBinding(target)) return error.TargetOutsideScope;
                try self.checkMembershipDependencies(target);
            },
            .close_session => {
                const target = request.session orelse return error.InvalidArguments;
                _ = try self.validateIdentity(target, false);
                if (!self.inBinding(target) and !self.selected(target) and !self.taskOwned(target)) return error.TargetOutsideScope;
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
            .disconnect_session => return error.ToolNotAvailable, // no bounded disconnect controller exists
            .reconnect_session => {
                const target = request.session orelse return error.InvalidArguments;
                _ = try self.validateIdentity(target, false);
                if (!self.inBinding(target) and !self.selected(target)) return error.TargetOutsideScope;
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
        self.bridge.bindingChanged(plan.handoff.to);
        if (self.callbacks.on_handoff) |notify| notify(self.callbacks.context.?, context.conversation_id, plan.handoff.to, plan.handoff.next_revision, plan.notice_revision);
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
        }, .local_released = receipt.local_released, .remote_effect_unknown = receipt.remote_effect_unknown, .error_code = receipt.error_code };
    }
    fn closeTarget(self: *Controller, operation: identity.HostOperationId) !CloseTarget {
        for (self.close_targets.items) |target| if (target.operation.eql(operation)) return target;
        return error.NotFound;
    }
    fn mutate(self: *Controller, context: host.Context, input: anytype) !runtime.MutationReceipt {
        const checked = try self.authorize(context, input.request);
        if (!std.meta.eql(checked, input.authorized)) return error.ScopeChanged;
        const request = input.request;
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
                const proposal: tools.Request = .{ .kind = .open_session, .group = request.group, .source = request.source, .saved_source = request.saved_source, .connection_policy = request.connection_policy, .retention = request.retention };
                const authorized = try self.authorize(call.context, proposal);
                if (request.allow_new_fallback != authorized.allow_new_fallback or request.membership_revision != authorized.membership_revision) return error.ScopeChanged;
                try self.checkLastAuthorization(.open_session, authorized);
                try self.open_authorizations.ensureUnusedCapacity(self.allocator, 1);
                call.result = .{ .session = try self.app.queueOwnedSession(request) };
                self.open_authorizations.appendAssumeCapacity(.{ .operation = request.operation_ref, .authorized = authorized });
            },
            .query_open => |operation| call.result = .{ .session = try self.app.queryOwnedSession(operation, call.context) },
            .resolve_owned => |handle_| call.result = .{ .session = try self.app.resolveOwnedSession(handle_, call.context) },
            .authorize_open => |request| {
                const entry = self.app.lifecycle_supervisor.find(request.operation) orelse return error.NotFound;
                const open_request = entry.request;
                const checked = try self.authorize(call.context, .{ .kind = .open_session, .group = open_request.group, .source = open_request.source, .saved_source = open_request.saved_source, .connection_policy = open_request.connection_policy, .retention = open_request.retention });
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
        if (setenv("ZDOTDIR", self.directory.ptr, 1) != 0) return error.EnvironmentFailed;
        self.workspace = try Workspace.init(a, self.cx, self.scope_, std.testing.io, &self.config_, self.path, nodes[0], nodes[1], nodes[2], nodes[3]);
        self.app = try Application.ApplicationHost.init(a, self.workspace);
        try self.scope_.onCleanup(Application.ApplicationHost, self.app, Application.ApplicationHost.deinit);
        self.app.install();
    }
    fn tick(self: *@This(), bridge: ?*Bridge) !void {
        _ = try self.app.safeTick();
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
        if (broker.snapshot()) |approval| try broker.decide(approval.sequence, approval.arguments_hash, true);
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
    const close_args = try std.json.Stringify.valueAlloc(a, .{ .session_ref = owned_ref, .request_key = "controller-close" }, .{});
    defer a.free(close_args);
    var accepted = try testInvoke(&fixture, &controller, &backend, &broker, "host.close_session", close_args);
    defer accepted.deinit(a);
    try accepted.validate(next, 1);
    const close_body = try std.json.parseFromSlice(std.json.Value, a, accepted.blocks[0].structured, .{});
    defer close_body.deinit();
    const close_op = try tools.operationId(next, close_body.value.object.get("operation_ref").?.string);
    try fixture.tick(&bridge);
    try std.testing.expect((try fixture.app.querySessionClose(close_op, next)).state == .accepted);
    try std.testing.expectEqual(@as(usize, 2), fixture.workspace.tabs.items.len);
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
    try std.testing.expect(fixture.app.sessions.queryState(source).?.lifecycle == .attached);
    try std.testing.expect(store.findConversation(context.conversation_id).?.owner == .group);
    try std.testing.expect(fixture.workspace.groupTabId(@intCast(next.binding.group)) != null);
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
