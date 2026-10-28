//! SSH status controls and their captured, read-only projections. Protocol and
//! clipboard actions belong to the existing connection details host.
const std = @import("std");
const ui = @import("ui");
const Details = @import("connection_details_view.zig");
const Info = @import("status_connection_view.zig");
const Status = @import("status_detail_view.zig");
const Model = @import("status_controller.zig");
const S = @import("status_connection_styles.zig");
const identity = @import("../host/identity.zig");
const sessions = @import("../host/session_host.zig");
pub const TerminalStatus = @import("terminal_status_snapshot.zig");
pub const Active = struct {
    details: Details.Snapshot,
    grid: @FieldType(Model.Projection, "grid") = null,
    utf8: bool = false,
    can_reconnect: bool = false,
    ended: bool = false,

    pub fn fromTerminal(details: Details.Snapshot, terminal: ?TerminalStatus.Snapshot, can_reconnect: bool) Active {
        var value: Active = .{ .details = details, .can_reconnect = can_reconnect };
        if (terminal) |source| if (source.accepts(details.key)) {
            value.grid = .{ .cols = source.cols, .rows = source.rows, .revision = source.revision };
            value.utf8 = source.encoding == .utf8;
        };
        return value;
    }

    pub fn withLifecycle(self: Active, lifecycle: @FieldType(sessions.SessionSnapshot, "lifecycle")) Active {
        var value = self;
        value.ended = switch (lifecycle) {
            .failed, .ended, .closed => true,
            else => false,
        };
        return value;
    }

    fn connectionInfo(self: Active) Info.Snapshot {
        var value = infoSnapshot(self.details, self.can_reconnect);
        if (self.ended) value.state = .disconnected;
        return value;
    }
};
/// File sessions have no terminal publication or SSH RTT store. Project the
/// actual file attachment separately instead of manufacturing either snapshot.
pub const FileActive = struct {
    owner: identity.SessionHandle,
    key: ?Details.OperationKey = null,
    name: Details.details.Text(512),
    state: enum { unknown, connecting, connected, disconnected } = .unknown,

    pub fn fromSession(owner: identity.SessionHandle, tab_id: identity.TabId, file_ready: bool, snapshot: ?sessions.SessionSnapshot, name: []const u8) !FileActive {
        var result: FileActive = .{ .owner = owner, .name = try Details.details.Text(512).init(name) };
        const source = snapshot orelse return result;
        if (!source.handle.eql(owner) or source.plugin_id != .sftp or source.create_operation.owner != .session or !source.create_operation.owner.session.eql(owner) or source.create_operation.operation_id == 0 or source.create_operation.attempt_id == 0) return result;
        result.key = source.create_operation;
        result.state = switch (source.lifecycle) {
            .creating, .ready => .connecting,
            .attached => if (file_ready and source.attachment != null and source.attachment.?.tab_id == tab_id and std.meta.eql(source.attachment.?.target, source.target)) .connected else .unknown,
            .ended, .failed, .closed => .disconnected,
            .closing, .cleanup_unknown => .unknown,
        };
        return result;
    }
};
pub const Hooks = struct {
    context: *anyopaque,
    capture: *const fn (*anyopaque, Details.Snapshot) anyerror!void,
    copy: *const fn (*anyopaque, Details.OperationKey, []const u8) anyerror!void,
    logs: *const fn (*anyopaque, Details.OperationKey) anyerror!void,
    reconnect: *const fn (*anyopaque, Details.OperationKey) anyerror!void,
    hide_chain: *const fn (*anyopaque) void,
};
pub const Controls = struct {
    bar: *ui.Node,
    identity_button: *ui.Node,
    identity_label: *ui.Node,
    state_dot: *ui.Node,
    rtt_button: *ui.Node,
    rtt_label: *ui.Node,
    encoding_button: *ui.Node,
    encoding_label: *ui.Node,
    grid_button: *ui.Node,
    grid_label: *ui.Node,
    more_button: *ui.Node,
    theme_button: *ui.Node,
    theme_label: *ui.Node,
    progress_slot: *ui.Node,
    file_icon: *ui.Node,
    chain_button: *ui.Node,
    chain_label: *ui.Node,
    forward_label: *ui.Node,
    socks_button: *ui.Node,
    broadcast_button: *ui.Node,
    broadcast_icon: *ui.Node,
    broadcast_style: *ui.Signal(S.ButtonStyle),
    broadcast_label: *ui.Node,
    icons: [8]*ui.Node,
    disabled: *ui.Signal(bool),
    theme_disabled: *ui.Signal(bool),
    narrow: bool = false,
    sidebar_width: f32 = 224,

    pub fn setThemeName(self: *Controls, cx: *ui.Cx, name: []const u8) !void {
        if (!std.mem.eql(u8, self.theme_label.getText().?.content, name)) {
            try self.theme_label.setTextContent(cx.allocator, name);
        }
    }
};
pub const StatusBar = struct {
    bar: *ui.Node,
    details: *ui.Node,
    grid: *ui.Node,
    progress_slot: *ui.Node,
    socks_chip: *ui.Node,
    socks_label: *ui.Node,
    chain_trigger: *ui.Node,
    chain_icon: *ui.Node,
    chain_hover: *ui.Signal(?S.ButtonStyle),
    controls: *Controls,
};

pub fn mountStatusBar(cx: *ui.Cx, scope: *ui.Scope, status_node: *ui.Node) !StatusBar {
    const hover = try scope.createSignal(?S.ButtonStyle, S.hover());
    const disabled = try scope.createSignal(bool, true);
    const theme_disabled = try scope.createSignal(bool, true);
    const bar = try ui.boxStyled(cx, @import("shell_styles.zig").status, .{});
    bar.setStyleInline(cx.allocator, .{ .padding = .{ .left = 0, .right = 8 }, .gap = 6 });
    bar.meta.ownership.meta.test_id = "workspace.statusbar";
    const left = try ui.box(cx, .{ .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0 }, .{});
    try bar.appendChild(cx.allocator, left);
    const id = try makeButton(cx, scope, "会话连接", "status.connection.identity", S.identityTrigger(), hover, disabled);
    const id_icon = try ui.iconTint(cx, ui.icons.terminal, S.theme.current().fg_2, .{});
    id_icon.setStyleInline(cx.allocator, S.triggerIcon());
    id_icon.setDisplay(.none);
    try id.appendChild(cx.allocator, id_icon);
    const file_icon = try ui.iconTint(cx, ui.icons.get("folder-open").?, S.theme.current().fg_2, .{});
    file_icon.setStyleInline(cx.allocator, S.triggerIcon());
    file_icon.setDisplay(.none);
    try id.appendChild(cx.allocator, file_icon);
    const dot = try ui.iconTintStyled(cx, ui.icons.activity, S.theme.current().fg_3, S.triggerDot());
    dot.meta.ownership.meta.test_id = "status.connection.heartbeat";
    try id.appendChild(cx.allocator, dot);
    status_node.setStyleInline(cx.allocator, S.triggerName());
    if (status_node.getText()) |current| {
        var props = current;
        props.font_size = 11;
        props.font_weight = 500;
        props.line_height = 16.0 / 11.0;
        props.selectable = false;
        props.text_overflow = .ellipsis;
        status_node.setText(props);
    }
    try id.appendChild(cx.allocator, status_node);
    const chevron = try ui.iconTint(cx, ui.icons.chevron_up, S.theme.current().fg_2, .{});
    chevron.setStyleInline(cx.allocator, S.triggerChevron());
    chevron.setDisplay(.none);
    try id.appendChild(cx.allocator, chevron);
    try left.appendChild(cx.allocator, id);
    const rtt = try metric(cx, scope, left, "往返延迟", "status.connection.rtt", 64, ui.icons.activity, hover, disabled);
    cx.detachChild(rtt.button, rtt.label);
    rtt.label.setStyleInline(cx.allocator, .{ .position = .absolute, .inset = .{ .left = .{ .px = 74 }, .top = .{ .px = 5 } }, .width = .{ .px = 36 }, .height = .{ .px = 16 }, .overflow_hidden = true });
    try id.appendChild(cx.allocator, rtt.label);
    rtt.button.setDisplay(.none);
    const encoding = try metric(cx, scope, left, "终端编码", "status.connection.encoding", 68, ui.icons.get("type").?, hover, disabled);
    const grid = try metric(cx, scope, left, "终端网格", "status.connection.grid", 82, ui.icons.get("move-diagonal").?, hover, disabled);
    try bar.appendChild(cx.allocator, try ui.spacer(cx));
    const more = try makeButton(cx, scope, "更多终端状态", "status.connection.more", S.metricTrigger(28), hover, disabled);
    const more_icon = try ui.iconTint(cx, ui.icons.ellipsis, S.theme.current().fg_2, .{});
    more_icon.setStyleInline(cx.allocator, S.metricIcon());
    try more.appendChild(cx.allocator, more_icon);
    more.setDisplay(.none);
    try bar.appendChild(cx.allocator, more);
    const chain = try makeButton(cx, scope, "通信链路", "status.connection.chain", S.metricTrigger(28), hover, disabled);
    const chain_icon = try ui.iconTint(cx, ui.icons.network, S.theme.current().fg_2, .{});
    chain_icon.setStyleInline(cx.allocator, S.metricIcon());
    try chain.appendChild(cx.allocator, chain_icon);
    const chain_label = try ui.text(cx, "连接链路", S.actionText());
    chain_label.setStyleInline(cx.allocator, S.metricLabel(S.action_width));
    chain_label.meta.ownership.meta.test_id = "status.connection.chain.state";
    chain_icon.meta.ownership.meta.test_id = "status.connection.chain.icon";
    try chain.appendChild(cx.allocator, chain_label);
    try bar.appendChild(cx.allocator, chain);
    const socks = try makeButton(cx, scope, "端口转发", "status.connection.forward", S.metricTrigger(28), hover, disabled);
    const socks_icon = try ui.iconTint(cx, ui.icons.get("plug-zap").?, S.theme.current().fg_2, .{});
    socks_icon.setStyleInline(cx.allocator, S.metricIcon());
    socks_icon.meta.ownership.meta.test_id = "status.connection.forward.icon";
    try socks.appendChild(cx.allocator, socks_icon);
    const forward_label = try ui.text(cx, "端口转发", S.actionText());
    forward_label.setStyleInline(cx.allocator, S.metricLabel(S.action_width));
    try socks.appendChild(cx.allocator, forward_label);
    // Bind the runtime projection to the visible label, including compact layouts.
    const socks_label = forward_label;
    socks_label.meta.ownership.meta.test_id = "status.connection.forward.state";
    try bar.appendChild(cx.allocator, socks);
    const broadcast_enabled = try scope.createSignal(bool, false);
    const broadcast_style = try scope.createSignal(S.ButtonStyle, S.metricTrigger(28));
    const broadcast = try ui.widgets.Button(.{ .a11y_label = "组广播 · 已关闭", .variant = .ghost, .base_style = broadcast_style, .hover_style = hover, .disabled = broadcast_enabled }).mount(scope, cx);
    broadcast.meta.ownership.meta.test_id = "status.group.broadcast";
    const broadcast_icon = try ui.iconTint(cx, ui.icons.get("radio").?, S.theme.current().fg_2, .{});
    broadcast_icon.setStyleInline(cx.allocator, S.metricIcon());
    try broadcast.appendChild(cx.allocator, broadcast_icon);
    const broadcast_label = try ui.text(cx, "", S.triggerText(false));
    try broadcast.appendChild(cx.allocator, broadcast_label);
    broadcast.setDisplay(.none);
    try bar.appendChild(cx.allocator, broadcast);
    cx.detachChild(bar, broadcast);
    try bar.insertChildBefore(cx.allocator, broadcast, chain);
    const theme = try makeButton(cx, scope, "全局主题 · 应用与全部终端", "status.connection.theme", S.themeTrigger(), hover, theme_disabled);
    // This trigger supplies its own icon and live label.
    for (theme.children.items) |child| child.setDisplay(.none);
    const theme_icon = try ui.iconTint(cx, ui.icons.palette, S.theme.current().fg_2, .{});
    theme_icon.setStyleInline(cx.allocator, S.themeIcon());
    try theme.appendChild(cx.allocator, theme_icon);
    const theme_label = try ui.text(cx, "", S.actionText());
    theme_label.setStyleInline(cx.allocator, S.themeLabel());
    theme_label.meta.ownership.meta.test_id = "status.connection.theme.label";
    try theme.appendChild(cx.allocator, theme_label);
    try bar.appendChild(cx.allocator, theme);
    const progress = try ui.box(cx, .{ .height = .fill(), .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0 }, .{});
    try bar.appendChild(cx.allocator, progress);
    const controls = try scope.createState(Controls, .{ .bar = bar, .identity_button = id, .identity_label = status_node, .state_dot = dot, .rtt_button = rtt.button, .rtt_label = rtt.label, .encoding_button = encoding.button, .encoding_label = encoding.label, .grid_button = grid.button, .grid_label = grid.label, .more_button = more, .theme_button = theme, .theme_label = theme_label, .progress_slot = progress, .file_icon = file_icon, .chain_button = chain, .chain_label = chain_label, .forward_label = forward_label, .socks_button = socks, .broadcast_button = broadcast, .broadcast_icon = broadcast_icon, .broadcast_style = broadcast_style, .broadcast_label = broadcast_label, .icons = .{ id_icon, chevron, rtt.icon, encoding.icon, grid.icon, more_icon, socks_icon, theme_icon }, .disabled = disabled, .theme_disabled = theme_disabled });
    return .{ .bar = bar, .details = left, .grid = grid.label, .progress_slot = progress, .socks_chip = socks, .socks_label = socks_label, .chain_trigger = chain, .chain_icon = chain_icon, .chain_hover = hover, .controls = controls };
}
fn makeButton(cx: *ui.Cx, scope: *ui.Scope, name: []const u8, id: []const u8, style: S.ButtonStyle, hover: *ui.Signal(?S.ButtonStyle), disabled: *ui.Signal(bool)) !*ui.Node {
    const button = try ui.widgets.Button(.{ .a11y_label = name, .variant = .ghost, .base_style = style, .hover_style = hover, .disabled = disabled }).mount(scope, cx);
    button.meta.ownership.meta.test_id = id;
    return button;
}
const Metric = struct { button: *ui.Node, icon: *ui.Node, label: *ui.Node };
fn metric(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, name: []const u8, id: []const u8, width: f32, asset: ui.SvgAsset, hover: *ui.Signal(?S.ButtonStyle), disabled: *ui.Signal(bool)) !Metric {
    _ = scope;
    _ = name;
    _ = hover;
    _ = disabled;
    const button = try ui.box(cx, S.staticMetric(width), .{});
    button.meta.ownership.meta.test_id = id;
    const icon = try ui.iconTint(cx, asset, S.theme.current().fg_2, .{});
    icon.setStyleInline(cx.allocator, S.metricIcon());
    try button.appendChild(cx.allocator, icon);
    const label = try ui.text(cx, "未知", S.triggerText(false));
    label.setStyleInline(cx.allocator, S.metricLabel(width));
    try button.appendChild(cx.allocator, label);
    try parent.appendChild(cx.allocator, button);
    return .{ .button = button, .icon = icon, .label = label };
}

pub const Host = struct {
    cx: *ui.Cx,
    hooks: Hooks,
    info: *Info.View,
    detail: *Status.View,
    controls: ?*Controls = null,
    active: ?Active = null,
    file_active: ?FileActive = null,
    revision: u64 = 0,
    theme_hook: ?struct { context: *anyopaque, show: *const fn (*anyopaque, *ui.Node) void } = null,
    colors: ?S.theme.Colors = null,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, hooks: Hooks) !*Host {
        const self = try cx.allocator.create(Host);
        var registered = false;
        errdefer if (!registered) cx.allocator.destroy(self);
        self.* = .{ .cx = cx, .hooks = hooks, .info = undefined, .detail = undefined };
        try scope.onCleanup(Host, self, cleanup);
        registered = true;
        self.info = try Info.View.mount(cx, scope, .{ .context = self, .copy = copy, .logs = logs, .reconnect = reconnect });
        self.detail = try Status.View.mount(cx, scope, .{ .context = self, .theme = themeFromMore });
        self.detail.chrome.meta.ownership.meta.test_id = "status.ssh.detail";
        try cx.root.?.appendChild(cx.allocator, self.info.root);
        try cx.root.?.appendChild(cx.allocator, self.detail.root);
        return self;
    }
    pub fn bind(self: *Host, controls: *Controls, context: *anyopaque, theme: *const fn (*anyopaque, *ui.Node) void) void {
        self.controls = controls;
        self.theme_hook = .{ .context = context, .show = theme };
        controls.theme_disabled.set(false);
        controls.identity_button.behavior.events.on_click = .{ .context = self, .callback = showIdentity };

        controls.theme_button.behavior.events.on_click = .{ .context = self, .callback = showTheme };
    }
    pub fn updateActive(self: *Host, next: ?Active) !void {
        const controls = self.controls orelse return;
        if (next) |source| {
            try Details.validate(source.details);
            if (source.details.key.owner != .session) return error.InvalidOwner;
        }
        const owner_changed = if (next) |source| if (self.active) |previous| !source.details.key.eql(previous.details.key) else true else true;
        if (owner_changed) self.info.dismiss();
        const changed = !std.meta.eql(next, self.active);
        self.active = next;
        self.file_active = null;
        controls.file_icon.setDisplay(.none);
        controls.icons[0].setDisplay(.none);
        controls.icons[1].setDisplay(.none);
        controls.more_button.setDisplay(.none);
        controls.chain_button.setDisplay(if (next == null) .none else .flex);
        controls.socks_button.setDisplay(if (next == null) .none else .flex);
        if (controls.identity_button.behavior.interaction.a11y) |*props| {
            props.label = "会话连接";
            props.description = null;
        }
        controls.disabled.set(next == null);
        if (next) |source| {
            const state = source.connectionInfo().state;
            try self.text(controls.identity_label, switch (state) {
                .online => "已连接",
                .disconnected => "已断开",
                .unknown => switch (source.details.hops[source.details.hop_count - 1].status) {
                    .not_attempted, .negotiating => "连接中",
                    .releasing => "断开中",
                    else => "状态未知",
                },
            });
            const sample = if (source.ended) null else Details.usableTarget(source.details);
            var buffer: [80]u8 = undefined;
            try self.text(controls.rtt_label, if (sample) |value| try std.fmt.bufPrint(&buffer, "{d}ms", .{value.duration_ms.?}) else "—");
            try self.text(controls.encoding_label, if (source.utf8) "UTF-8" else "未知");
            try self.text(controls.grid_label, if (source.grid) |grid| try std.fmt.bufPrint(&buffer, "{d}×{d}", .{ grid.cols, grid.rows }) else "未知");
            _ = controls.state_dot.setTint(if (source.connectionInfo().state == .online) S.theme.current().ok else S.theme.current().fg_3);
            if (changed) {
                if (self.revision == std.math.maxInt(u64)) return error.RevisionExhausted;
                self.revision += 1;
                try self.detail.update(.{ .owner = .{ .session = source.details.key.owner.session }, .owner_kind = .ssh, .source_revision = self.revision, .identity_label = controls.identity_label.getText().?.content, .encoding = if (source.utf8) .utf8 else .unknown, .grid = source.grid, .rtt = if (sample) |value| .{ .milliseconds = value.duration_ms } else null });
            }
        } else {
            // A group may focus a Local pane while retaining its shared bar.
            // Clear the previous SSH identity instead of leaving “已连接”.
            try self.text(controls.identity_label, "未连接");
            try self.text(controls.rtt_label, "—");
            try self.text(controls.encoding_label, "未知");
            try self.text(controls.grid_label, "未知");
            _ = controls.state_dot.setTint(S.theme.current().fg_3);
            if (self.detail.controller.source) |source| self.detail.invalidate(source.value.owner);
        }
        try self.finishUpdate();
    }
    pub fn updateFile(self: *Host, next: FileActive) !void {
        const controls = self.controls orelse return;
        self.info.dismiss();
        if (self.detail.controller.source) |source| self.detail.invalidate(source.value.owner);
        self.active = null;
        self.file_active = next;
        controls.disabled.set(true);
        controls.icons[0].setDisplay(.none);
        controls.icons[1].setDisplay(.none);
        controls.file_icon.setDisplay(.none);
        for ([_]*ui.Node{ controls.encoding_button, controls.grid_button, controls.more_button, controls.chain_button, controls.socks_button }) |node| node.setDisplay(.none);
        try self.text(controls.identity_label, switch (next.state) {
            .connected => "已连接",
            .connecting => "连接中",
            .disconnected => "已断开",
            .unknown => "状态未知",
        });
        try self.text(controls.rtt_label, "—");
        try self.text(controls.encoding_label, "未知");
        try self.text(controls.grid_label, "未知");
        _ = controls.state_dot.setTint(if (next.state == .connected) S.theme.current().ok else S.theme.current().fg_3);
        if (controls.identity_button.behavior.interaction.a11y) |*props| {
            props.label = "文件会话";
            props.description = switch (next.state) {
                .connected => "SFTP · 已连接",
                .connecting => "SFTP · 连接中",
                .disconnected => "SFTP · 已断开",
                .unknown => "SFTP · 状态未知",
            };
        }
        try self.finishUpdate();
    }
    fn finishUpdate(self: *Host) !void {
        const controls = self.controls orelse return;
        const colors = S.theme.current();
        if (self.colors == null or !std.meta.eql(self.colors.?, colors)) {
            controls.identity_label.setTextColor(colors.fg_1);
            for ([_]*ui.Node{ controls.chain_button, controls.socks_button }) |node| node.setBackground(ui.Color.TRANSPARENT);
            for ([_]*ui.Node{ controls.rtt_label, controls.encoding_label, controls.grid_label, controls.theme_label }) |node| node.setTextColor(colors.fg_2);
            for (controls.icons) |node| _ = node.setTint(colors.fg_2);
            _ = controls.file_icon.setTint(colors.fg_2);
            try self.info.retheme();
            self.detail.dirty = true;
            self.colors = colors;
        }
        // Always-visible status projection: independent of opening the chain card.
        const ForwardColors = @import("socks_info_styles.zig");
        var chain_color = colors.fg_2;
        var chain_text: []const u8 = "连接链路 · 未连接";
        if (self.active) |source| {
            const state = source.connectionInfo().state;
            switch (state) {
                .online => {
                    chain_color = ForwardColors.text(.success);
                    chain_text = "连接链路 · 在线";
                },
                .disconnected => {
                    chain_color = ForwardColors.text(.danger);
                    chain_text = "连接链路 · 已断开";
                },
                .unknown => {
                    chain_color = ForwardColors.text(.warning);
                    chain_text = if (source.details.hops[source.details.hop_count - 1].status == .releasing) "连接链路 · 断开中" else "连接链路 · 连接中";
                },
            }
        }
        try self.text(controls.chain_label, "连接链路");
        const chain_ink = ForwardColors.statusBarInk(chain_color);
        controls.chain_label.setTextColor(colors.fg_1);
        if (controls.chain_button.behavior.interaction.a11y) |*props| props.description = chain_text;
        for (controls.chain_button.children.items) |child| if (child.getIcon() != null) {
            _ = child.setTint(chain_ink);
        };
        const identity_width: f32 = if (self.active != null) S.identity_width else 96;
        controls.identity_button.setStyleInline(self.cx.allocator, .{ .width = .{ .px = identity_width } });
        controls.identity_label.setDisplay(.flex);
        controls.icons[1].setDisplay(.none);
        const full_width: f32 = identity_width + 232 + S.action_width * 2 + controls.theme_button.globalRect().w + 20 + controls.progress_slot.globalRect().w;
        const narrow = controls.bar.globalRect().w < full_width;
        const empty = self.active == null and self.file_active == null;
        controls.theme_button.setDisplay(if (empty) .none else .flex);
        controls.narrow = narrow;
        controls.rtt_button.setDisplay(.none);
        controls.rtt_label.setDisplay(if (self.active == null) .none else .flex);
        controls.chain_label.setDisplay(.flex);
        controls.forward_label.setDisplay(.flex);
        controls.chain_button.setStyleInline(self.cx.allocator, .{ .width = .{ .px = S.action_width } });
        controls.socks_button.setStyleInline(self.cx.allocator, .{ .width = .{ .px = S.action_width } });
        for ([_]*ui.Node{ controls.encoding_button, controls.grid_button }) |node| node.setDisplay(if (empty or narrow or self.file_active != null) .none else .flex);
        self.detail.reanchor(controls.bar.globalRect().y);
        try self.detail.flush();
        self.info.reanchor(controls.bar.globalRect().y);
        try self.info.flush();
    }
    pub fn refreshFrozen(self: *Host, snapshot: Details.Snapshot, can_reconnect: bool) void {
        if (self.info.source) |source| if (source.key.eql(snapshot.key)) {
            var value = infoSnapshot(snapshot, can_reconnect);
            if (self.active) |active| if (active.details.key.eql(snapshot.key) and active.ended) {
                value.state = .disconnected;
            };
            self.info.update(value) catch {};
        };
    }
    pub fn invalidate(self: *Host, key: Details.OperationKey) void {
        self.info.invalidate(key);
    }
    pub fn isOpen(self: *const Host) bool {
        return self.info.isVisible() or self.detail.controller.popover != null;
    }
    fn showIdentity(raw: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(raw));
        const controls = self.controls orelse return;
        if (self.info.isVisible()) {
            self.info.hide();
            return;
        }
        const source = self.active orelse return;
        self.hooks.capture(self.hooks.context, source.details) catch return;
        self.detail.hide();
        self.cx.setFocus(controls.identity_button);
        self.info.show(source.connectionInfo(), controls.identity_button, controls.bar.globalRect().y) catch {};
    }
    fn showKind(self: *Host, kind: Model.Kind, trigger: *ui.Node) void {
        const controls = self.controls orelse return;
        if (self.active == null) return;
        self.info.hide();
        self.hooks.hide_chain(self.hooks.context);
        self.cx.setFocus(trigger);
        self.detail.show(kind, trigger, controls.bar.globalRect().y, controls.narrow) catch return;
    }
    fn showEncoding(raw: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(raw));
        self.showKind(.encoding, self.controls.?.encoding_button);
    }
    fn showGrid(raw: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(raw));
        self.showKind(.grid, self.controls.?.grid_button);
    }
    fn showRtt(raw: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(raw));
        self.showKind(.rtt, self.controls.?.rtt_button);
    }
    fn showMore(raw: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(raw));
        self.showKind(.more, self.controls.?.more_button);
    }
    fn themeFromMore(raw: *anyopaque) void {
        showTheme(raw);
    }
    fn showTheme(raw: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(raw));
        const controls = self.controls orelse return;
        const callback = self.theme_hook orelse return;
        self.info.hide();
        self.detail.hide();
        self.hooks.hide_chain(self.hooks.context);
        callback.show(callback.context, if (controls.theme_button.style.display == .none) controls.more_button else controls.theme_button);
    }
    fn copy(raw: *anyopaque, key: Details.OperationKey, content: []const u8) !void {
        const self: *Host = @ptrCast(@alignCast(raw));
        try self.hooks.copy(self.hooks.context, key, content);
    }
    fn logs(raw: *anyopaque, key: Details.OperationKey) !void {
        const self: *Host = @ptrCast(@alignCast(raw));
        try self.hooks.logs(self.hooks.context, key);
    }
    fn reconnect(raw: *anyopaque, key: Details.OperationKey) !void {
        const self: *Host = @ptrCast(@alignCast(raw));
        try self.hooks.reconnect(self.hooks.context, key);
    }
    fn text(self: *Host, node: *ui.Node, value: []const u8) !void {
        if (!std.mem.eql(u8, node.getText().?.content, value)) try node.setTextContent(self.cx.allocator, value);
    }
    fn cleanup(self: *Host) void {
        self.cx.allocator.destroy(self);
    }
};

pub fn infoSnapshot(snapshot: Details.Snapshot, can_reconnect: bool) Info.Snapshot {
    var result: Info.Snapshot = .{ .key = snapshot.key, .revision = snapshot.revision, .endpoint = snapshot.hops[snapshot.hop_count - 1].endpoint, .hop_count = snapshot.hop_count, .logs_available = true, .can_reconnect = can_reconnect };
    var online = snapshot.source == .session;
    for (snapshot.hops[0..snapshot.hop_count], result.route[0..snapshot.hop_count]) |hop, *endpoint| {
        endpoint.* = hop.endpoint;
        online = online and hop.status == .online;
    }
    const target = snapshot.hops[snapshot.hop_count - 1];
    result.cipher_c2s = target.metadata.cipher_c2s;
    result.cipher_s2c = target.metadata.cipher_s2c;
    if (Details.usableTarget(snapshot)) |sample| result.latency_ms = sample.duration_ms;
    result.state = if (online) .online else if (snapshot.hops[snapshot.hop_count - 1].status == .released) .disconnected else .unknown;
    return result;
}
