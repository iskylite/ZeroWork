const std = @import("std");
const ui = @import("ui");
const Workspace = @import("workspace.zig").Workspace;
const ApplicationHost = @import("application_host.zig").ApplicationHost;
const View = @import("connection_details_view.zig").View;
const OperationKey = @import("../host/operation.zig").OperationKey;
const theme = @import("app_theme.zig");
const S = @import("connection_details_styles.zig");
const AssetOwner = @import("../host/identity.zig").AssetOwner;
const Logs = @import("connection_logs_view.zig");
const Progress = @import("connection_progress_view.zig");
const Endpoint = @import("../proto/ssh/connection_details.zig").Endpoint;
const SSH = @import("ssh_status_host.zig");

pub const Host = struct {
    cx: *ui.Cx,
    workspace: *Workspace,
    application: *ApplicationHost,
    view: *View,
    logs: *Logs.View = undefined,
    ssh_status: *SSH.Host = undefined,
    log_records: [128]Progress.LogRecord = undefined,
    log_count: usize = 0,
    log_dropped: usize = 0,
    log_revision: u64 = 1,
    log_endpoint: Endpoint = .{},
    log_expired: bool = false,
    trigger: *ui.Node,
    trigger_icon: *ui.Node,
    trigger_hover: *ui.Signal(?S.ButtonStyle),
    status_bar: *ui.Node,
    key: ?OperationKey = null,
    colors: ?theme.Colors = null,
    feedback: ui.widgets.popover.PopoverResult = undefined,
    feedback_label: *ui.Node = undefined,
    feedback_until_ms: ?f64 = null,
    editor: ?struct { context: *anyopaque, open: *const fn (*anyopaque, AssetOwner) anyerror!void } = null,

    pub fn bindEditor(self: *Host, context: *anyopaque, open: *const fn (*anyopaque, AssetOwner) anyerror!void) void {
        self.editor = .{ .context = context, .open = open };
        self.view.callbacks.edit = edit;
    }
    pub fn bindStatus(self: *Host, controls: *SSH.Controls, context: *anyopaque, theme_action: *const fn (*anyopaque, *ui.Node) void) void {
        self.ssh_status.bind(controls, context, theme_action);
    }

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, workspace: *Workspace, application: *ApplicationHost, trigger: *ui.Node, trigger_icon: *ui.Node, trigger_hover: *ui.Signal(?S.ButtonStyle), status_bar: *ui.Node) !*Host {
        const self = try cx.allocator.create(Host);
        var registered = false;
        errdefer if (!registered) cx.allocator.destroy(self);
        self.* = .{ .cx = cx, .workspace = workspace, .application = application, .view = undefined, .trigger = trigger, .trigger_icon = trigger_icon, .trigger_hover = trigger_hover, .status_bar = status_bar };
        // The view cancels its own pending sample during cleanup; retain its
        // callback context until that cleanup has run.
        try scope.onCleanup(Host, self, cleanup);
        registered = true;
        self.feedback = try ui.widgets.Popover(.{ .trigger = .manual, .position = .top, .anchor = .{ .virtual = .{ .ctx = self, .getRect = feedbackAnchor } }, .tier = .toast, .close_on_escape = false, .close_on_outside_click = false, .max_width = @as(f32, 360), .size_policy = .fit_content, .enter_transition = .none, .exit_transition = .none }).mount(scope, cx);
        self.feedback.content.meta.ownership.meta.test_id = "sidebar.chain.feedback";
        self.feedback.content.setStyleInline(cx.allocator, @import("sidebar_styles.zig").hint());
        self.feedback.content.behavior.interaction.a11y = .{ .role = .status, .live = "polite" };
        self.feedback_label = try ui.text(cx, "", .{ .font_size = 12, .color = theme.current().fg_1, .wrap = .word });
        self.feedback_label.setStyleInline(cx.allocator, .{ .max_width = 340 });
        try self.feedback.content.appendChild(cx.allocator, self.feedback_label);
        try cx.root.?.appendChild(cx.allocator, self.feedback.wrapper);
        const owner: @import("scoped_modal.zig").Owner = .{ .resolve = .{ .context = self, .get = resolveOwner } };
        self.logs = try Logs.View.mountWithOwner(cx, scope, .{ .context = self, .copy_logs = copy }, owner);
        self.view = try View.mount(cx, scope, .{ .context = self, .request_sample = requestSample, .cancel_sample = cancelSample, .copy = copy, .logs = openLogs });
        self.view.node_owner = owner;
        try cx.root.?.appendChild(cx.allocator, self.view.root);
        self.ssh_status = try SSH.Host.mount(cx, scope, .{ .context = self, .capture = captureStatus, .copy = copy, .logs = openLogs, .reconnect = reconnect, .hide_chain = hideChain });
        try cx.addAfterLayoutHook(self, hook);
        trigger.behavior.events.on_click = .{ .context = self, .callback = clicked };
        return self;
    }

    fn resolveOwner(raw: *anyopaque) ?*ui.Node {
        const self: *Host = @ptrCast(@alignCast(raw));
        const key = self.key orelse return null;
        return if (key.owner == .session) self.workspace.overlayOwner(key.owner.session) else null;
    }

    fn captureStatus(raw: *anyopaque, snapshot: @import("connection_details_view.zig").Snapshot) !void {
        const self: *Host = @ptrCast(@alignCast(raw));
        try @import("connection_details_view.zig").validate(snapshot);
        self.view.hide();
        self.logs.hide();
        self.capture(snapshot);
    }
    fn capture(self: *Host, snapshot: @import("connection_details_view.zig").Snapshot) void {
        if (self.key == null or !self.key.?.eql(snapshot.key)) {
            self.key = snapshot.key;
            self.log_count = 0;
            self.log_dropped = 0;
            self.log_revision = 1;
            self.log_expired = false;
            self.log_endpoint = snapshot.hops[snapshot.hop_count - 1].endpoint;
        }
        self.captureLogs(snapshot.key);
    }
    fn hideChain(raw: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(raw));
        self.view.hide();
    }
    fn canReconnect(self: *Host, key: OperationKey) bool {
        if (key.owner != .session or self.workspace.shutting_down or self.application.windowClosePending()) return false;
        const state = self.application.sessions.queryState(key.owner.session) orelse return false;
        return state.lifecycle == .failed or state.lifecycle == .ended;
    }
    fn reconnect(raw: *anyopaque, key: OperationKey) !void {
        const self: *Host = @ptrCast(@alignCast(raw));
        try self.validate(key);
        if (!self.canReconnect(key)) return error.LifecycleDoesNotAllowRetry;
        const id = self.application.legacyForHandle(key.owner.session) orelse return error.StaleSession;
        try self.application.requestSshReconnect(id);
    }

    fn refreshStatus(self: *Host) !void {
        const index = self.workspace.active_tab orelse {
            try self.ssh_status.updateActive(null);
            return;
        };
        if (index >= self.workspace.tabs.items.len) {
            try self.ssh_status.updateActive(null);
            return;
        }
        const tab = self.workspace.tabs.items[index];
        if (tab.local or tab.archived or tab.content_owner != .session) {
            try self.ssh_status.updateActive(null);
            return;
        }
        if (tab.plugin_renderer) |renderer| if (renderer.vtable.connection_status) |project| {
            try self.ssh_status.updateGraphical(project(renderer.context));
            return;
        };
        if (tab.file_scope != null) {
            const owner = tab.content_owner.session;
            const source = tab.host_snapshot orelse {
                try self.ssh_status.updateActive(null);
                return;
            };
            const file = try SSH.FileActive.fromSession(owner, tab.tab_id, tab.file_ready and !tab.failed and !tab.closing, self.application.sessions.queryState(owner), if (source.value.name.len != 0) source.value.name else source.value.host);
            try self.ssh_status.updateFile(file);
            return;
        }
        if (tab.closing) {
            try self.ssh_status.updateActive(null);
            return;
        }
        const snapshot = self.application.sshConnectionDetails(tab.content_owner.session) catch |err| {
            if (err == error.WorkerBusy) {
                self.cx.scheduleRedrawAfterNs(33 * std.time.ns_per_ms);
                return;
            }
            try self.ssh_status.updateActive(null);
            return;
        };
        // ApplicationHost.terminalSnapshot is the local TerminalService path;
        // SSH still publishes owned v2 TextSlot frames through TerminalView.
        const terminal = if (self.workspace.tabs.items[index].terminal) |*value| value.statusSnapshot(snapshot.key) else null;
        var active = SSH.Active.fromTerminal(snapshot, terminal, self.canReconnect(snapshot.key));
        if (self.application.sessions.queryState(tab.content_owner.session)) |state| active = active.withLifecycle(state.lifecycle);
        try self.ssh_status.updateActive(active);
    }

    fn captureLogs(self: *Host, key: OperationKey) void {
        const source = self.workspace.connectionProgress(key) orelse return;
        var changed = self.log_count != source.log_count or self.log_dropped != source.dropped;
        for (source.logs[0..source.log_count], 0..) |record, index| {
            const next: Progress.LogRecord = .{ .key = record.key, .entry = record.entry };
            if (!changed and !std.meta.eql(self.log_records[index], next)) changed = true;
            self.log_records[index] = next;
        }
        self.log_count = source.log_count;
        self.log_dropped = source.dropped;
        if (changed) self.log_revision +|= 1;
    }

    fn logSnapshot(self: *Host) Logs.Snapshot {
        return .{ .key = self.key.?, .revision = self.log_revision, .endpoint = self.log_endpoint, .records = self.log_records[0..self.log_count], .dropped = self.log_dropped, .expired = self.log_expired };
    }

    fn openLogs(raw: *anyopaque, key: OperationKey) !void {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (self.key == null or !self.key.?.eql(key)) return error.StaleConnection;
        self.captureLogs(key);
        self.view.hide();
        try self.logs.show(self.logSnapshot());
    }

    fn clicked(raw: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (self.view.isVisible()) {
            self.view.hide();
            return;
        }
        self.showForTab(self.workspace.active_tab orelse return);
    }

    pub fn showForTab(self: *Host, index: usize) void {
        if (index >= self.workspace.tabs.items.len) return;
        const tab = self.workspace.tabs.items[index];
        if (tab.plugin_renderer) |renderer| if (renderer.vtable.show_connection_details) |show| {
            self.logs.hide();
            self.view.dismiss();
            self.ssh_status.info.dismiss();
            self.ssh_status.detail.hide();
            show(renderer.context);
            return;
        };
        if (tab.file_scope != null) {
            self.showFeedback("SFTP 暂不支持查看实时连接链路");
            return;
        }
        if (tab.plugin_renderer != null) {
            self.showFeedback("该连接类型暂不支持查看连接详情");
            return;
        }
        if (tab.content_owner != .session or tab.local or tab.archived or tab.closing) return;
        self.feedback.close.invoke();
        self.feedback_until_ms = null;
        const snapshot = self.application.sshConnectionDetails(tab.content_owner.session) catch |err| {
            self.workspace.statusFailure(@errorName(err));
            return;
        };
        self.logs.hide();
        if (snapshot.hop_count == 0 or snapshot.hop_count > snapshot.hops.len) return;
        self.ssh_status.info.dismiss();
        self.ssh_status.detail.hide();
        self.capture(snapshot);
        self.view.show(snapshot, self.trigger, self.status_bar.globalRect().y) catch |err| self.workspace.statusFailure(@errorName(err));
    }
    pub fn showFeedback(self: *Host, message: []const u8) void {
        self.view.dismiss();
        self.logs.hide();
        self.feedback_label.setTextContent(self.cx.allocator, message) catch return;
        self.feedback_until_ms = self.cx.frame_time_ms + 3000;
        self.feedback.show.invoke();
        self.cx.scheduleRedrawAfterNs(3000 * std.time.ns_per_ms);
        self.cx.requestRedraw();
    }
    fn feedbackAnchor(raw: *anyopaque) ui.widgets.popover.AnchorRect {
        const self: *Host = @ptrCast(@alignCast(raw));
        return .{ .x = self.cx.viewport.width / 2, .y = self.cx.viewport.height - 40, .w = 0, .h = 0 };
    }

    fn hook(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (self.feedback_until_ms) |deadline| {
            if (self.cx.frame_time_ms >= deadline) {
                self.feedback_until_ms = null;
                self.feedback.close.invoke();
            } else self.cx.scheduleRedrawAfterNs(@intFromFloat((deadline - self.cx.frame_time_ms) * std.time.ns_per_ms));
        }
        self.refreshStatus() catch {};
        const colors = theme.current();
        if (self.colors == null or !std.meta.eql(self.colors.?, colors)) {
            self.trigger_hover.set(S.triggerHover());
            // The SSH status host owns the trigger's live state tint.
            self.view.retheme() catch {};
            self.logs.retheme() catch {};
            self.feedback.content.setStyleInline(self.cx.allocator, @import("sidebar_styles.zig").hint());
            self.feedback_label.setTextColor(theme.current().fg_1);
            self.colors = colors;
        }
        if (!self.view.isVisible() and !self.logs.isVisible() and !self.ssh_status.info.isVisible()) return .done;
        const key = self.key orelse return .done;
        if (key.owner != .session) return .done;
        if (self.workspace.overlayOwner(key.owner.session) == null) {
            self.view.dismiss();
            self.logs.hide();
            self.ssh_status.info.dismiss();
            return .done;
        }
        const snapshot = self.application.sshConnectionDetails(key.owner.session) catch |err| {
            // A contended snapshot is not a stale session. Invalidating here
            // cancels the live RTT and permanently expires the open card.
            if (err == error.WorkerBusy) {
                self.cx.scheduleRedrawAfterNs(33 * std.time.ns_per_ms);
                return .done;
            }
            self.view.invalidate(key);
            self.ssh_status.invalidate(key);
            self.log_expired = true;
            self.logs.invalidate(key);
            self.view.flush() catch {};
            self.logs.flush() catch {};
            self.ssh_status.info.flush() catch {};
            return .done;
        };
        if (!snapshot.key.eql(key)) {
            self.view.invalidate(key);
            self.ssh_status.invalidate(key);
            self.log_expired = true;
            self.logs.invalidate(key);
        } else {
            self.view.update(snapshot) catch {};
            self.ssh_status.refreshFrozen(snapshot, self.canReconnect(key));
        }
        self.captureLogs(key);
        if (self.logs.isVisible() and !self.log_expired) self.logs.update(self.logSnapshot()) catch {};
        self.view.reanchor(self.status_bar.globalRect().y);
        self.view.flush() catch {};
        self.logs.flush() catch {};
        self.ssh_status.info.flush() catch {};
        self.cx.scheduleRedrawAfterNs(33 * std.time.ns_per_ms);
        return .done;
    }

    fn validate(self: *Host, key: OperationKey) !void {
        if (self.key == null or !self.key.?.eql(key) or key.owner != .session) return error.StaleConnection;
        const snapshot = try self.application.sshConnectionDetails(key.owner.session);
        if (!snapshot.key.eql(key)) return error.StaleConnection;
    }

    fn requestSample(raw: *anyopaque, key: OperationKey, hop: ?usize) !u64 {
        const self: *Host = @ptrCast(@alignCast(raw));
        try self.validate(key);
        return self.application.requestSshRtt(key.owner.session, hop);
    }
    fn cancelSample(raw: *anyopaque, key: OperationKey, request: u64) !void {
        const self: *Host = @ptrCast(@alignCast(raw));
        try self.validate(key);
        try self.application.cancelSshRtt(key.owner.session, request);
    }
    fn copy(raw: *anyopaque, key: OperationKey, text: []const u8) !void {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (self.key == null or !self.key.?.eql(key)) return error.StaleConnection;
        if (!ui.platform_services.clipboardSetText(self.cx.system_sdk, text)) return error.ClipboardUnavailable;
    }
    fn edit(raw: *anyopaque, key: OperationKey, owner: AssetOwner) !void {
        const self: *Host = @ptrCast(@alignCast(raw));
        try self.validate(key);
        _ = try self.workspace.registry.get(owner);
        const editor = self.editor orelse return error.EditorUnavailable;
        try editor.open(editor.context, owner);
        self.view.hide();
    }
    fn cleanup(self: *Host) void {
        self.cx.removeAfterLayoutHook(self);
        self.cx.allocator.destroy(self);
    }
};
