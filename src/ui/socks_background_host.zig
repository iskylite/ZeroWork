//! No-Tab forwarding bridge. Presentation never owns a native SSH pointer.
const std = @import("std");
const ui = @import("ui");
const ws = @import("workspace.zig");
const identity = @import("../host/identity.zig");
const sessions = @import("../host/session_host.zig");
const operations = @import("../host/operation.zig");
const Application = @import("application_host.zig").ApplicationHost;
const M = @import("socks_background_model.zig");
pub const List = @import("socks_background_view.zig");
const Exposure = @import("socks_exposure_confirm.zig");
const applog = @import("../platform/applog.zig");
const Pending = struct { host_id: ws.HostId, asset: identity.AssetOwner, options: M.Routes.StartOptions };
pub const Host = struct {
    cx: *ui.Cx,
    workspace: *ws.Workspace,
    application: *Application,
    backend: *M.Routes.Host,
    model: *M.Model,
    view: *List.View,
    exposure: *Exposure.View,
    pending: ?Pending = null,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, workspace: *ws.Workspace, application: *Application, backend: *M.Routes.Host) !*Host {
        const self = try scope.createState(Host, .{ .cx = cx, .workspace = workspace, .application = application, .backend = backend, .model = undefined, .view = undefined, .exposure = undefined });
        const tasks = application.domain.tasks orelse return error.TaskDomainUnavailable;
        self.model = tasks.bindBackgrounds(.{ .context = application.domain, .create = rejectCreate, .snapshots = snapshots, .listener = listener, .start = start, .close_listener = closeListener, .close_owner = closeOwner, .reconnect = reconnect });
        self.view = try List.View.mount(cx, scope, .{ .context = self, .action = action });
        self.exposure = try Exposure.View.mount(cx, scope, .{ .context = self, .confirm = confirmExposure, .cancel = cancelExposure });
        workspace.setBackgroundForwardBridge(.{ .context = self, .badge = badge });
        try cx.addAfterLayoutHook(self, afterLayout);
        try scope.onCleanup(Host, self, cleanup);
        return self;
    }
    pub fn hasAsset(self: *const Host, asset: identity.AssetOwner) bool {
        return self.model.hasAsset(asset);
    }
    pub fn showAsset(self: *Host, asset: identity.AssetOwner, anchor: ui.ComputedRect) void {
        self.view.showAt(asset.id, anchor);
        self.cx.requestRedraw();
    }
    pub fn requestStart(self: *Host, host_id: ws.HostId, asset: identity.AssetOwner) !void {
        const index = self.workspace.hostIndex(host_id) orelse return error.StaleAsset;
        const host = try self.workspace.registry.get(asset);
        if (self.workspace.registry.hosts[index].connection_id != asset.id or host.protocol != .ssh) return error.StaleAsset;
        if (self.model.hasAsset(asset)) return error.BackgroundAlreadyActive;
        const bind = if (host.socks_enabled) host.socks_bind else self.workspace.app_config.ssh.socks_bind;
        if (!std.mem.eql(u8, bind, "127.0.0.1") and !std.mem.eql(u8, bind, "0.0.0.0")) return error.InvalidSocksBind;
        const options: M.Routes.StartOptions = .{ .exit_index = host.socks_exit, .listener = .{ .requested_port = if (host.socks_enabled) host.socks_port else self.workspace.app_config.ssh.socks_port, .bind127 = std.mem.eql(u8, bind, "127.0.0.1"), .max_connections = host.socks_max_connections } };
        if (!options.listener.bind127) {
            self.pending = .{ .host_id = host_id, .asset = asset, .options = options };
            try self.exposure.show(bind);
            return;
        }
        try self.begin(.{ .host_id = host_id, .asset = asset, .options = options });
    }
    fn begin(self: *Host, pending: Pending) !void {
        const host = try self.workspace.registry.get(pending.asset);
        _ = try self.model.startSavedWith(.{ .host_id = pending.host_id, .asset = pending.asset, .name = host.name, .options = pending.options }, self, create);
        self.workspace.status("正在建立后台转发连接…");
        self.cx.scheduleRedrawAfterNs(10 * std.time.ns_per_ms);
    }
    fn confirmExposure(raw: *anyopaque, bind: []const u8) void {
        const self = cast(raw);
        var pending = self.pending orelse return;
        self.pending = null;
        if (!std.mem.eql(u8, bind, "0.0.0.0")) return;
        pending.options.listener.exposure_confirmed = true;
        self.begin(pending) catch |err| self.workspace.status(@errorName(err));
    }
    fn cancelExposure(raw: *anyopaque) void {
        cast(raw).pending = null;
    }
    fn cast(raw: *anyopaque) *Host {
        return @ptrCast(@alignCast(raw));
    }
    fn create(raw: *anyopaque, id: u64, asset: identity.AssetOwner) !sessions.Accepted {
        const self = cast(raw);
        const index = self.workspace.hostIndex(id) orelse return error.StaleAsset;
        _ = try self.workspace.registry.get(asset);
        if (self.workspace.registry.hosts[index].connection_id != asset.id) return error.StaleAsset;
        return self.application.createBackgroundSaved(id);
    }
    fn domain(raw: *anyopaque) *@import("application_host.zig").Domain {
        return @ptrCast(@alignCast(raw));
    }
    fn rejectCreate(_: *anyopaque, _: u64, _: identity.AssetOwner) !sessions.Accepted {
        return error.BackgroundCreationRequiresWindow;
    }
    fn snapshots(raw: *anyopaque, allocator: std.mem.Allocator) ![]M.Runtime.Snapshot {
        return if (domain(raw).backgrounds) |host| host.snapshots(allocator) else allocator.alloc(M.Runtime.Snapshot, 0);
    }
    fn listener(raw: *anyopaque, owner: identity.SessionHandle) ?M.Routes.Snapshot {
        return domain(raw).tasks.?.socks.snapshot(owner);
    }
    fn start(raw: *anyopaque, owner: identity.SessionHandle, options: M.Routes.StartOptions) !operations.OperationKey {
        return domain(raw).tasks.?.socks.start(owner, options);
    }
    fn closeListener(raw: *anyopaque, owner: identity.SessionHandle) sessions.CloseReceipt {
        return domain(raw).tasks.?.socks.requestSessionClose(owner);
    }
    fn closeOwner(raw: *anyopaque, owner: identity.SessionHandle) !operations.OperationKey {
        return domain(raw).stopBackgroundOwner(owner);
    }
    fn reconnect(raw: *anyopaque, owner: identity.SessionHandle) !void {
        _ = try (domain(raw).backgrounds orelse return error.StaleSession).retry(owner);
    }
    fn action(raw: *anyopaque, owner: identity.SessionHandle, requested: List.Action) void {
        const self = cast(raw);
        const row = self.model.currentRow(owner) orelse {
            self.workspace.status("后台连接已变化，请重新打开列表");
            return;
        };
        switch (requested) {
            .stop => self.model.stop(owner) catch |err| self.workspace.status(@errorName(err)),
            .reconnect => self.model.reconnect(owner) catch |err| self.workspace.status(@errorName(err)),
            .open_terminal => {
                _ = self.workspace.registry.get(row.source) catch |err| {
                    self.workspace.status(@errorName(err));
                    return;
                };
                const index = self.workspace.registry.indexOf(row.source.id) orelse return;
                // A new interactive owner is created by the normal factory.
                // The no-shell background owner is never attached to a Tab.
                self.workspace.newSession(index) catch |err| self.workspace.status(@errorName(err));
            },
        }
        self.cx.scheduleRedrawAfterNs(10 * std.time.ns_per_ms);
    }
    fn badge(raw: ?*anyopaque, asset: identity.AssetOwner) ?@import("sidebar_view.zig").ForwardBadge {
        const self = cast(raw orelse return null);
        for (self.model.rows.items) |row| if (row.source.id == asset.id) return .{ .port = row.local_port, .phase = row.phase };
        return null;
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self = cast(raw);
        const active = self.model.refresh() catch |err| {
            applog.warn(.ui, "background forward snapshot: {s}", .{@errorName(err)});
            self.cx.scheduleRedrawAfterNs(100 * std.time.ns_per_ms);
            return .done;
        };
        const previous = self.view.last_hash;
        self.view.update(self.model.rows.items) catch |err| applog.warn(.ui, "background forward view: {s}", .{@errorName(err)});
        self.workspace.refreshBackgroundForwardBadges();
        if (active or self.model.entries.items.len != 0) self.cx.scheduleRedrawAfterNs(40 * std.time.ns_per_ms);
        return if (previous == null or !std.meta.eql(previous, self.view.last_hash)) .needs_layout else .done;
    }
    fn cleanup(self: *Host) void {
        self.cx.removeAfterLayoutHook(self);
        if (self.workspace.background_forward_bridge.context == @as(?*anyopaque, self)) self.workspace.background_forward_bridge = .{};
        // The shared model and its source snapshots outlive this window.
    }
};
