//! Production SOCKS card. Values are copied into stable text nodes on the UI thread.
//! Live V2 Bridge 358:1419344: 360px compact forwarding card with fixed actions.
const std = @import("std");
const ui = @import("ui");
const S = @import("socks_info_styles.zig");

pub const State = enum { off, connecting, running, paused, failed };
pub const Data = struct {
    mode: @import("../proto/ssh/socks5_listener.zig").ForwardMode = .socks5,
    target_host: []const u8 = "",
    target_port: u16 = 0,
    state: State = .off,
    configured: bool = false,
    port: u16 = 1080,
    bind: []const u8 = "127.0.0.1",
    host: []const u8 = "",
    /// Stable UI workspace session ID, matching the tab label (not a domain enum).
    session_id: ?u64 = null,
    /// Name of the actually selected authenticated exit (target or intermediate hop).
    exit: []const u8 = "",
    /// Actual route description; empty for a direct connection.
    route: []const u8 = "",
    connections: usize = 0,
    uploaded: u64 = 0,
    downloaded: u64 = 0,
    /// Real connection/test failure. No error row is shown when empty.
    error_text: []const u8 = "",
    /// Verified test outcome; displayed only after a real test.
    test_result: []const u8 = "",
};
pub const Action = enum { test_proxy, copy_export, config, stop, start };
pub const Hooks = struct {
    context: *anyopaque,
    action: *const fn (*anyopaque, Action) void,
};

pub fn mount(cx: *ui.Cx, scope: *ui.Scope, hooks: Hooks) !*View {
    const self = try cx.allocator.create(View);
    self.* = .{ .cx = cx, .scope = scope, .hooks = hooks, .root = undefined, .body = undefined, .header = undefined, .footer = undefined, .status = undefined, .address = undefined, .bind_note = undefined, .exit = undefined, .route = undefined, .statistics = undefined, .message = undefined, .control_text = undefined, .test_button = undefined, .copy_button = undefined, .config_button = undefined, .control_button = undefined, .pointer = undefined, .protocol = undefined, .owner = undefined, .title_icon = undefined, .close_button = undefined, .test_disabled = try scope.createSignal(bool, true), .control_disabled = try scope.createSignal(bool, false) };
    try scope.onCleanup(View, self, View.cleanup);
    const focus_guard = try scope.childScope();
    self.open = try scope.createSignal(bool, false);
    const popup = try ui.widgets.Popover(.{ .open = self.open, .trigger = .manual, .position = .top, .width = S.width, .max_width = S.width, .offset = .{ .static = @as(f32, 6) }, .viewport_padding = 8, .flip = false, .shift_main_axis = false, .constrain_width_to_viewport = true, .enter_transition = .none, .exit_transition = .none, .anchor = .{ .virtual = .{ .ctx = self, .getRect = View.anchorRect } }, .on_open_change = cx.on(View, self, View.openChanged) }).mount(scope, cx);
    self.scope = popup.scope;
    self.wrapper = popup.wrapper;
    self.portaled = popup.portaled;
    self.frame = popup.content;
    self.frame.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .fill(), .min_height = 0, .direction = .column, .gap = 0, .padding = .{} });
    try focus_guard.onCleanup(View, self, View.releaseFocus);
    var panel_style = S.panel();
    panel_style.position = .absolute;
    panel_style.width = .{ .px = S.width };
    panel_style.height = .{ .px = S.normal_height };
    panel_style.direction = .column;
    panel_style.display = .none;
    panel_style.padding = ui.Padding.all(15);
    panel_style.gap = 0;
    panel_style.flex_shrink = 0;
    self.root = popup.chrome;
    self.root.setStyleInline(cx.allocator, panel_style);
    self.root.meta.ownership.meta.test_id = "socks.info";
    self.pointer = try ui.iconTint(cx, ui.icons.get("chevron-down").?, S.theme.current().fg_3, S.icon(12));
    self.pointer.setDisplay(.none);
    self.pointer.setStyleInline(cx.allocator, .{ .position = .absolute, .inset = .{ .bottom = .{ .px = 0 }, .right = .{ .px = 64 } }, .z_index = 51 });
    try self.root.appendChild(cx.allocator, self.pointer);
    self.header = try ui.box(cx, S.header(), .{});
    self.title_icon = try ui.iconTint(cx, ui.icons.get("plug-zap").?, S.theme.current().accent, S.icon(14));
    try self.header.appendChild(cx.allocator, self.title_icon);
    self.title = try text(self, "端口转发", 12, 700, .primary, false);
    try self.header.appendChild(cx.allocator, self.title);
    try self.header.appendChild(cx.allocator, try ui.spacer(cx));
    self.close_button = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .a11y_label = "关闭端口转发信息", .base_style = S.iconButton(24), .hover_style = .{ .background = S.theme.current().hover }, .on_click = cx.on(View, self, View.hide) }).mount(scope, cx);
    self.close_button.setStyleInline(cx.allocator, S.iconButton(24));
    try self.close_button.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.x, S.theme.current().fg_2, S.icon(14)));
    self.close_button.meta.ownership.meta.test_id = "socks.info.close";
    try self.header.appendChild(cx.allocator, self.close_button);
    try self.frame.appendChild(cx.allocator, self.header);
    self.body = try ui.widgets.ScrollArea(.{ .direction = .vertical }).mount(scope, cx);
    self.body.container.style.width = .fill();
    self.body.container.style.height = .{ .px = S.body_height };
    self.body.container.style.flex_shrink = 0;
    self.body.content.setStyleInline(cx.allocator, S.body());
    try self.frame.appendChild(cx.allocator, self.body.container);
    self.intro = try text(self, "每个 SSH 会话同时运行一个转发，停止后可切换模式。", 10.5, 400, .secondary, false);
    self.intro.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 18 }, .flex_shrink = 0 });
    try self.body.content.appendChild(cx.allocator, self.intro);
    self.empty = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 126 }, .direction = .column, .align_items = .center, .justify = .center, .gap = 10, .flex_shrink = 0 }, .{});
    self.empty.meta.ownership.meta.test_id = "socks.info.empty";
    try self.empty.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get("plug-zap").?, S.theme.current().fg_3, S.icon(24)));
    try self.empty.appendChild(cx.allocator, try text(self, "没有转发规则", 12, 500, .primary, false));
    try self.empty.appendChild(cx.allocator, try text(self, "本地 L · 远端 R · 动态 SOCKS5", 10, 400, .secondary, false));
    try self.body.content.appendChild(cx.allocator, self.empty);
    self.rule = try ui.box(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 6, .padding = ui.Padding.all(10), .margin = .{ .top = 10 }, .background = S.theme.current().well, .border = .{ .radius = 8 }, .flex_shrink = 0 }, .{});
    self.rule.meta.ownership.meta.test_id = "socks.info.rule";
    const identity = try ui.box(cx, S.line(18), .{});
    self.owner = try text(self, "归属", 10, 400, .secondary, false);
    self.owner.setStyleInline(cx.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0 });
    self.exit = try text(self, "—", 9, 400, .secondary, false);
    self.route = try text(self, "", 9, 400, .muted, false);
    self.address = try text(self, "", 11, 500, .primary, true);
    self.address.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 32 }, .flex_shrink = 0 });
    if (self.address.getText()) |old| {
        var style = old;
        style.wrap = .char;
        self.address.setText(style);
    }
    self.bind_note = try text(self, "", 10, 400, .muted, false);
    self.status = try text(self, "未开启", 9, 500, .muted, false);
    try identity.appendChild(cx.allocator, self.owner);
    try identity.appendChild(cx.allocator, self.status);
    try self.rule.appendChild(cx.allocator, identity);
    self.mode_label = try text(self, "SOCKS5", 11, 500, .primary, false);
    try self.rule.appendChild(cx.allocator, self.mode_label);
    try self.rule.appendChild(cx.allocator, self.address);
    try self.rule.appendChild(cx.allocator, self.bind_note);
    try self.rule.appendChild(cx.allocator, self.exit);
    try self.rule.appendChild(cx.allocator, self.route);
    self.statistics = try text(self, "0 B ↓ · 0 B ↑", 11, 500, .primary, false);
    try self.rule.appendChild(cx.allocator, self.statistics);
    self.protocol = try text(self, "0 个活跃连接 · 仅 TCP CONNECT · UDP 不支持", 10, 400, .secondary, false);
    try self.rule.appendChild(cx.allocator, self.protocol);
    try self.body.content.appendChild(cx.allocator, self.rule);
    self.message = try text(self, "", 10.5, 400, .secondary, false);
    self.message.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 32 }, .margin = .{ .top = 8 }, .flex_shrink = 0 });
    if (self.message.getText()) |old| {
        var style = old;
        style.wrap = .word;
        self.message.setText(style);
    }
    self.message.setDisplay(.none);
    try self.body.content.appendChild(cx.allocator, self.message);
    const foot = try ui.box(cx, S.footer(), .{});
    self.footer = foot;
    self.copy_button = try button(self, foot, "复制代理", .copy_export);
    self.test_button = try button(self, foot, "测试", .test_proxy);
    self.config_button = try button(self, foot, "添加转发", .config);
    try foot.appendChild(cx.allocator, try ui.spacer(cx));
    self.control_button = try button(self, foot, "开启", .start);
    self.status.meta.ownership.meta.test_id = "socks.info.status";
    self.address.meta.ownership.meta.test_id = "socks.info.address";
    self.exit.meta.ownership.meta.test_id = "socks.info.exit";
    self.statistics.meta.ownership.meta.test_id = "socks.info.statistics";
    self.test_button.meta.ownership.meta.test_id = "socks.info.test";
    self.copy_button.meta.ownership.meta.test_id = "socks.info.copy";
    self.config_button.meta.ownership.meta.test_id = "socks.info.config";
    self.control_button.meta.ownership.meta.test_id = "socks.info.control";
    try self.frame.appendChild(cx.allocator, foot);
    try self.update(.{});
    try cx.addAfterLayoutHook(self, View.afterLayout);
    return self;
}

pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    hooks: Hooks,
    root: *ui.Node,
    wrapper: *ui.Node = undefined,
    frame: *ui.Node = undefined,
    open: *ui.Signal(bool) = undefined,
    portaled: bool = false,
    body: ui.widgets.ScrollAreaResult,
    header: *ui.Node,
    footer: *ui.Node,
    status: *ui.Node,
    address: *ui.Node,
    bind_note: *ui.Node,
    exit: *ui.Node,
    route: *ui.Node,
    statistics: *ui.Node,
    message: *ui.Node,
    control_text: *ui.Node,
    test_button: *ui.Node,
    copy_button: *ui.Node,
    config_button: *ui.Node,
    control_button: *ui.Node,
    pointer: *ui.Node,
    protocol: *ui.Node,
    owner: *ui.Node,
    title_icon: *ui.Node,
    title: *ui.Node = undefined,
    close_button: *ui.Node,
    intro: *ui.Node = undefined,
    empty: *ui.Node = undefined,
    rule: *ui.Node = undefined,
    mode_label: *ui.Node = undefined,
    config_text: *ui.Node = undefined,
    has_rule: bool = false,
    test_disabled: *ui.Signal(bool),
    control_disabled: *ui.Signal(bool),
    button_paints: [4]struct { style: *ui.Signal(ui.BoxStyle), action: Action } = undefined,
    button_count: usize = 0,
    state: State = .off,
    message_is_error: bool = false,
    paint_colors: ?S.theme.Colors = null,
    painted_text: std.ArrayList(struct { node: *ui.Node, role: S.TextRole }) = .empty,
    anchor: ?ui.ComputedRect = null,
    /// Prefer retaining the trigger node so the card follows reflow, resize,
    /// and status-bar layout changes.  `anchor` remains for callers that only
    /// have a snapshot (and for deterministic unit tests).
    anchor_node: ?*ui.Node = null,

    /// All borrowed strings are copied before return. Nodes and callbacks remain stable,
    /// so callbacks may synchronously update/hide this view without disposing their context.
    pub fn update(self: *View, data: Data) !void {
        self.state = data.state;
        self.message_is_error = data.error_text.len > 0;
        self.has_rule = data.configured or data.state != .off;
        self.empty.setDisplay(if (self.has_rule) .none else .flex);
        self.rule.setDisplay(if (self.has_rule) .flex else .none);
        self.control_button.setDisplay(if (self.has_rule) .flex else .none);
        try self.config_text.setTextContent(self.cx.allocator, if (self.has_rule) "编辑配置" else "＋ 添加转发");
        try self.mode_label.setTextContent(self.cx.allocator, switch (data.mode) {
            .socks5 => "SOCKS5 · 动态目标",
            .local => "本地 L",
            .remote => "远端 R",
        });
        var buffer: [384]u8 = undefined;
        try self.address.setTextContent(self.cx.allocator, if (data.mode == .socks5) try std.fmt.bufPrint(&buffer, "{s}:{d}", .{ data.bind, data.port }) else try std.fmt.bufPrint(&buffer, "{s}:{d} → {s}:{d}", .{ data.bind, data.port, data.target_host, data.target_port }));
        try self.bind_note.setTextContent(self.cx.allocator, if (data.mode == .remote) "监听位于SSH端 · 目标位于本机" else if (std.mem.eql(u8, data.bind, "0.0.0.0")) "局域网可访问" else "仅本机");
        try self.exit.setTextContent(self.cx.allocator, if (data.session_id != null and std.mem.eql(u8, data.host, if (data.exit.len > 0) data.exit else data.host)) "出口" else if (data.exit.len > 0) data.exit else if (data.host.len > 0) data.host else "—");
        try self.route.setTextContent(self.cx.allocator, data.route);
        self.route.setDisplay(if (data.route.len == 0) .none else .flex);
        var count_buffer: [192]u8 = undefined;
        var down_buf: [32]u8 = undefined;
        var up_buf: [32]u8 = undefined;
        try self.statistics.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&count_buffer, "{s} ↓ · {s} ↑", .{ try formatBytes(&down_buf, data.downloaded), try formatBytes(&up_buf, data.uploaded) }));
        try self.protocol.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&count_buffer, "{d} 个活跃连接 · {s}", .{ data.connections, if (data.mode == .socks5) "仅 TCP CONNECT · UDP 不支持" else "固定TCP目标" }));
        if (data.session_id) |session_id| {
            try self.owner.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&count_buffer, "归属 {s} #{d} ·", .{ data.host, session_id }));
        } else {
            try self.owner.setTextContent(self.cx.allocator, if (data.host.len > 0 and !std.mem.eql(u8, data.host, if (data.exit.len > 0) data.exit else data.host)) try std.fmt.bufPrint(&count_buffer, "归属 {s} · 出口", .{data.host}) else "归属");
        }
        try self.status.setTextContent(self.cx.allocator, switch (data.state) {
            .off => "未开启",
            .connecting => "◌ 开启中",
            .running => "正在监听",
            .paused => "◌ 已暂停(断线)",
            .failed => "开启失败",
        });
        self.test_disabled.set(data.state != .running or data.mode != .socks5);
        self.copy_button.setDisplay(if (self.has_rule and data.mode == .socks5) .flex else .none);
        self.test_button.setDisplay(if (self.has_rule and data.mode == .socks5) .flex else .none);
        self.control_disabled.set(data.state == .connecting);
        const active = data.state == .running or data.state == .paused;
        try self.control_text.setTextContent(self.cx.allocator, if (active) "停止" else "开启");
        if (self.control_button.behavior.interaction.a11y) |*attrs| attrs.label = if (active) "停止转发" else "开启转发";
        if (self.config_button.behavior.interaction.a11y) |*attrs| attrs.label = if (self.has_rule) "编辑转发配置" else "添加转发";
        const message = if (data.error_text.len > 0) data.error_text else data.test_result;
        try self.message.setTextContent(self.cx.allocator, message);
        self.message.setDisplay(if (message.len > 0) .flex else .none);
        self.retheme();
        self.paintState();
        self.root.markLayoutDirty();
        self.cx.requestRedraw();
    }

    /// Paint only: retain original nodes, action state, trigger and geometry.
    pub fn retheme(self: *View) void {
        const colors = S.theme.current();
        if (self.paint_colors) |old| if (std.meta.eql(old, colors)) return;
        if (self.paint_colors) |previous| repaintIcons(self.root, previous);
        self.root.setStyleInline(self.cx.allocator, S.panel());
        self.rule.setBackground(colors.well);
        self.pointer.setStyleInline(self.cx.allocator, S.pointer());
        _ = self.title_icon.setTint(colors.accent);
        _ = self.pointer.setTint(colors.fg_3);
        self.close_button.setStyleInline(self.cx.allocator, S.iconButton(24));
        for (self.button_paints[0..self.button_count]) |paint| paint.style.set(buttonStyle(paint.action));
        for (self.painted_text.items) |item| setColor(item.node, S.text(item.role));
        self.paint_colors = colors;
        self.paintState();
    }

    fn paintState(self: *View) void {
        const c = S.theme.current();
        setColor(self.status, switch (self.state) {
            .running => c.ok_ink,
            .connecting, .paused => c.warn_ink,
            .failed => c.danger_ink,
            .off => c.fg_3,
        });
        setColor(self.control_text, c.fg_2);
        setColor(self.config_text, ui.Color.WHITE);
        for (self.button_paints[0..self.button_count]) |paint| if (paint.action == .config) {
            var style = buttonStyle(.config);
            style.background = c.accent;
            paint.style.set(style);
        };
        setColor(self.message, if (self.message_is_error) c.danger_ink else c.fg_2);
    }
    pub fn show(self: *View, anchor: ui.ComputedRect) void {
        self.anchor_node = null;
        self.anchor = anchor;
        self.open.set(true);
        self.root.setDisplay(.flex);
        self.cx.requestRedraw();
    }

    /// Show from the actual trigger node.  Resolving its rect on every layout
    /// keeps the popup attached when the status bar moves after resize/reflow.
    pub fn showNode(self: *View, anchor: *ui.Node) void {
        self.anchor_node = anchor;
        self.anchor = anchor.globalRect();
        self.open.set(true);
        self.root.setDisplay(.flex);
        self.cx.requestRedraw();
    }
    pub fn hide(self: *View) void {
        self.open.set(false);
        self.root.setDisplay(.none);
        self.cx.requestRedraw();
    }
    /// Public for layout tests and host resize integration.
    pub fn updateGeometry(self: *View) bool {
        if (self.root.style.display == .none) return false;
        if (self.anchor_node) |node| if (!node.isDisplayedInTree()) {
            self.hide();
            return false;
        };
        const upper = anchorRect(self).y;
        const available = @max(@as(f32, 1), @min(self.cx.viewport.height - 16, upper - 14));
        const width = @max(@as(f32, 1), @min(S.width, self.cx.viewport.width - 16));
        const natural = @max(S.body_height, self.body.content.globalRect().h);
        const body_h = @min(natural, @max(@as(f32, 1), available - S.chrome_height));
        const card_h = body_h + S.chrome_height;
        var changed = false;
        if (self.root.style.width != .px or @abs(self.root.style.width.px - width) > 0.5) {
            self.root.setStyleInline(self.cx.allocator, .{ .width = .{ .px = width } });
            changed = true;
        }
        if (self.root.style.height != .px or @abs(self.root.style.height.px - card_h) > 0.5) {
            self.root.setStyleInline(self.cx.allocator, .{ .height = .{ .px = card_h } });
            changed = true;
        }
        if (self.body.container.style.height != .px or @abs(self.body.container.style.height.px - body_h) > 0.5) {
            self.body.container.setStyleInline(self.cx.allocator, .{ .height = .{ .px = body_h } });
            changed = true;
        }
        if (changed) {
            self.root.markLayoutDirty();
            self.cx.requestRedraw();
        }
        return changed;
    }
    fn anchorRect(raw: *anyopaque) ui.widgets.popover.AnchorRect {
        const self: *View = @ptrCast(@alignCast(raw));
        const rect = if (self.anchor_node) |node| node.globalRect() else self.anchor orelse ui.ComputedRect{ .x = 8, .y = self.cx.viewport.height - 32, .w = 0, .h = 0 };
        return .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
    }
    fn openChanged(self: *View, value: bool) void {
        if (!value) self.hide();
    }
    fn releaseFocus(self: *View) void {
        if (self.cx.focus_manager.current_focus) |focused| if (focused.isDescendantOf(self.root)) self.cx.clearFocus();
    }
    pub fn dispatch(self: *View, requested: Action) void {
        const action = if (requested == .start or requested == .stop) (if (self.state == .running or self.state == .paused) Action.stop else Action.start) else requested;
        if ((action == .test_proxy or action == .copy_export) and self.state != .running) return;
        if ((action == .start or action == .stop) and self.state == .connecting) return;
        self.hooks.action(self.hooks.context, action);
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        self.retheme();
        return if (self.updateGeometry()) .needs_layout else .done;
    }
    fn cleanup(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
        self.painted_text.deinit(self.cx.allocator);
        self.cx.allocator.destroy(self);
    }
};
const Click = struct {
    view: *View,
    action: Action,
    fn invoke(self: *Click) void {
        self.view.dispatch(self.action);
    }
    fn cleanup(self: *Click) void {
        self.view.cx.allocator.destroy(self);
    }
};
fn text(self: *View, value: []const u8, size: f32, weight: u16, role: S.TextRole, mono: bool) !*ui.Node {
    const node = try ui.text(self.cx, value, .{ .font_size = size, .font_weight = weight, .color = S.text(role), .use_monospace_font = mono, .line_height = (if (size >= 17) @as(f32, 26) else if (size >= 13) @as(f32, 20) else if (size >= 12) @as(f32, 18) else 16) / size, .wrap = .none, .text_overflow = .ellipsis });
    errdefer self.cx.destroyDetached(node);
    try self.painted_text.append(self.cx.allocator, .{ .node = node, .role = role });
    return node;
}
fn setColor(node: *ui.Node, color: ui.Color) void {
    if (node.getText()) |value| {
        var next = value;
        next.color = color;
        node.setText(next);
    }
}
fn formatBytes(buffer: []u8, value: u64) ![]const u8 {
    if (value >= 1024 * 1024) return std.fmt.bufPrint(buffer, "{d:.1} MiB", .{@as(f64, @floatFromInt(value)) / (1024 * 1024)});
    if (value >= 1024) return std.fmt.bufPrint(buffer, "{d:.1} KiB", .{@as(f64, @floatFromInt(value)) / 1024});
    return std.fmt.bufPrint(buffer, "{d} B", .{value});
}
fn button(self: *View, parent: *ui.Node, label: []const u8, action: Action) !*ui.Node {
    const icon_only = action == .copy_export;
    const click = try self.cx.allocator.create(Click);
    click.* = .{ .view = self, .action = action };
    try self.scope.onCleanup(Click, click, Click.cleanup);
    const disabled = if (action == .test_proxy or action == .copy_export) self.test_disabled else if (action == .start) self.control_disabled else null;
    const paint = try self.scope.createSignal(ui.BoxStyle, buttonStyle(action));
    self.button_paints[self.button_count] = .{ .style = paint, .action = action };
    self.button_count += 1;
    const node = try ui.widgets.Button(.{ .base_style = paint, .variant = .ghost, .hover_style = .{ .background = if (action == .config) S.theme.current().accent else S.theme.current().hover }, .icon_only = icon_only, .a11y_label = label, .disabled = if (disabled) |signal| ui.Source(bool){ .signal = signal } else ui.Source(bool){ .value = false }, .on_click = self.cx.on(Click, click, Click.invoke) }).mount(self.scope, self.cx);
    if (icon_only) {
        try node.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.get(if (action == .copy_export) "copy" else "settings-2").?, S.theme.current().fg_2, S.icon(if (action == .config) @as(f32, 14) else 16)));
    } else {
        const copy = try text(self, label, 12, 500, .secondary, false);
        if (action == .start) self.control_text = copy;
        if (action == .config) self.config_text = copy;
        try node.appendChild(self.cx.allocator, copy);
    }
    try parent.appendChild(self.cx.allocator, if (icon_only) try @import("connection_details_view.zig").iconTooltip(self.cx, self.scope, node, label) else node);
    return node;
}

fn repaintIcons(node: *ui.Node, previous: S.theme.Colors) void {
    if (node.getIcon()) |icon| {
        const c = S.theme.current();
        if (ui.Color.eql(icon.tint, previous.fg_2)) {
            _ = node.setTint(c.fg_2);
        } else if (ui.Color.eql(icon.tint, previous.ok_ink)) {
            _ = node.setTint(c.ok_ink);
        } else if (ui.Color.eql(icon.tint, previous.accent)) {
            _ = node.setTint(c.accent);
        }
    }
    for (node.children.items) |child| repaintIcons(child, previous);
}

fn buttonStyle(action: Action) ui.BoxStyle {
    const icon_only = action == .copy_export;
    var skin = S.button(if (action == .config) .icon else .ordinary);
    skin.width = .{ .px = switch (action) {
        .copy_export => 24,
        .config => 96,
        .test_proxy => 58,
        else => 82,
    } };
    skin.height = .{ .px = if (icon_only) 24 else 30 };
    skin.padding = .{};
    skin.gap = 0;
    skin.flex_shrink = 0;
    skin.align_items = .center;
    skin.justify = .center;
    return skin;
}
