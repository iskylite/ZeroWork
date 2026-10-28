//! Production SOCKS card. Values are copied into stable text nodes on the UI thread.
//! Editable reference: docs/UI_V3/workspace/forwarding/index.html.
const std = @import("std");
const ui = @import("ui");
const S = @import("socks_info_styles.zig");
const ButtonStyle = @FieldType(ui.widgets.ControlShellConfig, "style");

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
    logs: []const u8 = "",
};
pub const Action = enum { test_proxy, copy_export, config, stop, start, logs, logs_back };
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
    const popup = try ui.widgets.Popover(.{ .open = self.open, .trigger = .manual, .close_on_outside_click = false, .position = .top, .width = S.width, .max_width = S.width, .offset = .{ .static = @as(f32, 6) }, .viewport_padding = 8, .flip = false, .shift_main_axis = false, .constrain_width_to_viewport = true, .enter_transition = .none, .exit_transition = .none, .anchor = .{ .virtual = .{ .ctx = self, .getRect = View.anchorRect } }, .on_open_change = cx.on(View, self, View.openChanged) }).mount(scope, cx);
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
    panel_style.padding = ui.Padding.all(16);
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
    self.title_icon = try ui.iconTint(cx, ui.icons.get("plug-zap").?, S.theme.current().accent, S.icon(16));
    try self.header.appendChild(cx.allocator, self.title_icon);
    self.title = try text(self, "端口转发", 15, 600, .primary, false);
    try self.header.appendChild(cx.allocator, self.title);
    self.owner = try text(self, "", 12, 400, .secondary, false);
    self.owner.setStyleInline(cx.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0 });
    try self.header.appendChild(cx.allocator, self.owner);
    self.close_button = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .a11y_label = "关闭端口转发信息", .base_style = S.iconButton(28), .hover_style = .{ .background = S.theme.current().hover }, .on_click = cx.on(View, self, View.hide) }).mount(scope, cx);
    self.close_button.setStyleInline(cx.allocator, S.iconButton(28));
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
    self.intro = try text(self, "添加规则后启动转发", 13, 400, .secondary, false);
    self.intro.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 20 }, .flex_shrink = 0 });
    try self.body.content.appendChild(cx.allocator, self.intro);
    self.empty = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 126 }, .direction = .column, .align_items = .center, .justify = .center, .gap = 10, .flex_shrink = 0 }, .{});
    self.empty.meta.ownership.meta.test_id = "socks.info.empty";
    try self.empty.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get("plug-zap").?, S.theme.current().fg_3, S.icon(24)));
    try self.empty.appendChild(cx.allocator, try text(self, "没有转发规则", 12, 500, .primary, false));
    try self.empty.appendChild(cx.allocator, try text(self, "本地 L · 远端 R · 动态 SOCKS5", 10, 400, .secondary, false));
    try self.body.content.appendChild(cx.allocator, self.empty);
    self.rule = try ui.box(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 6, .padding = ui.Padding.all(12), .margin = .{ .top = 10 }, .background = S.theme.popupInset(), .border = .{ .radius = 8 }, .flex_shrink = 0 }, .{});
    self.rule.meta.ownership.meta.test_id = "socks.info.rule";
    const identity = try ui.box(cx, S.line(24), .{});
    self.exit = try text(self, "—", 12, 400, .secondary, false);
    self.route = try text(self, "", 12, 400, .muted, false);
    self.address = try text(self, "", 18, 600, .primary, true);
    self.address.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .min_height = 32, .min_width = 0, .flex_shrink = 0 });
    if (self.address.getText()) |old| {
        var style = old;
        style.wrap = .char;
        style.text_overflow = .clip;
        self.address.setText(style);
    }
    self.bind_note = try text(self, "", 12, 400, .secondary, false);
    self.status = try text(self, "未开启", 15, 600, .muted, false);
    try identity.appendChild(cx.allocator, self.status);
    try identity.appendChild(cx.allocator, try ui.spacer(cx));
    try self.rule.appendChild(cx.allocator, identity);
    self.mode_label = try text(self, "SOCKS5", 12, 400, .secondary, false);
    try identity.appendChild(cx.allocator, self.mode_label);
    const endpoint = try ui.box(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .row, .gap = 8, .align_items = .center, .flex_shrink = 0 }, .{});
    self.address.setStyleInline(cx.allocator, .{ .flex = 1 });
    try endpoint.appendChild(cx.allocator, self.address);
    self.copy_button = try button(self, endpoint, "复制代理", .copy_export);
    try self.rule.appendChild(cx.allocator, endpoint);
    try self.rule.appendChild(cx.allocator, self.bind_note);
    try self.rule.appendChild(cx.allocator, self.exit);
    try self.rule.appendChild(cx.allocator, self.route);
    self.statistics = try text(self, "0 B ↓ · 0 B ↑", 15, 600, .primary, false);
    self.statistics.setStyleInline(cx.allocator, .{ .margin = .{ .top = 6 }, .padding = .{ .top = 8 }, .flex_shrink = 0 });
    try self.rule.appendChild(cx.allocator, self.statistics);
    const details_row = try ui.box(cx, S.line(34), .{});
    self.protocol = try text(self, "0 个活跃连接 · TCP · 不支持 UDP", 12, 400, .primary, false);
    self.protocol.setStyleInline(cx.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0 });
    try details_row.appendChild(cx.allocator, self.protocol);
    _ = try button(self, details_row, "查看日志", .logs);
    try self.rule.appendChild(cx.allocator, details_row);
    try self.body.content.appendChild(cx.allocator, self.rule);
    self.message = try text(self, "", 12, 400, .secondary, false);
    self.message.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .min_height = 32, .min_width = 0, .margin = .{ .top = 8 }, .flex_shrink = 0 });
    if (self.message.getText()) |old| {
        var style = old;
        style.wrap = .word;
        style.text_overflow = .clip;
        self.message.setText(style);
    }
    self.message.setDisplay(.none);
    try self.body.content.appendChild(cx.allocator, self.message);
    self.logs_open = try scope.createSignal(bool, false);
    const logs_popup = try ui.widgets.Popover(.{ .open = self.logs_open, .trigger = .manual, .position = .top, .width = S.logs_width, .max_width = S.logs_width, .offset = .{ .static = @as(f32, 6) }, .viewport_padding = 8, .flip = false, .shift_main_axis = false, .constrain_width_to_viewport = true, .enter_transition = .none, .exit_transition = .none, .anchor = .{ .virtual = .{ .ctx = self, .getRect = View.anchorRect } }, .on_open_change = cx.on(View, self, View.logsOpenChanged) }).mount(scope, cx);
    self.logs_wrapper = logs_popup.wrapper;
    self.logs_portaled = logs_popup.portaled;
    self.logs_root = logs_popup.chrome;
    var logs_style = S.panel();
    logs_style.position = .absolute;
    logs_style.width = .{ .px = S.logs_width };
    logs_style.height = .{ .px = S.logs_height };
    logs_style.direction = .column;
    logs_style.padding = ui.Padding.all(16);
    logs_style.gap = 0;
    logs_style.display = .none;
    self.logs_root.setStyleInline(cx.allocator, logs_style);
    self.logs_root.meta.ownership.meta.test_id = "socks.logs";
    const logs_header = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 28 }, .direction = .row, .align_items = .center, .gap = 8, .flex_shrink = 0 }, .{});
    try logs_header.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get("file-text").?, S.theme.current().accent, S.icon(16)));
    try logs_header.appendChild(cx.allocator, try text(self, "端口转发日志", 14, 600, .primary, false));
    self.logs_owner = try text(self, "", 12, 400, .secondary, false);
    try logs_header.appendChild(cx.allocator, try ui.spacer(cx));
    self.logs_close = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .a11y_label = "关闭端口转发日志", .base_style = S.iconButton(28), .on_click = cx.on(View, self, View.closeLogs) }).mount(scope, cx);
    self.logs_close.meta.ownership.meta.test_id = "socks.logs.close";
    try self.logs_close.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.x, S.theme.current().fg_2, S.icon(14)));
    try logs_header.appendChild(cx.allocator, self.logs_close);
    try logs_popup.content.appendChild(cx.allocator, logs_header);
    self.logs_owner.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 18 }, .margin = .{ .top = 2, .bottom = 14 }, .flex_shrink = 0 });
    try logs_popup.content.appendChild(cx.allocator, self.logs_owner);
    self.logs_body = try ui.widgets.ScrollArea(.{ .direction = .vertical }).mount(scope, cx);
    self.logs_body.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0 });
    self.logs_body.container.setStyleInline(cx.allocator, .{ .background = S.theme.popupInset(), .border = .{ .radius = 8, .width = 1, .color = S.theme.current().border } });
    self.logs_body.content.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .padding = ui.Padding.all(12), .flex_shrink = 0 });
    self.logs_text = try text(self, "尚无转发日志", 12, 400, .secondary, true);
    self.logs_text.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .flex_shrink = 0 });
    if (self.logs_text.getText()) |old| {
        var style = old;
        style.wrap = .word;
        style.line_height = 21.0 / 12.0;
        style.text_overflow = .clip;
        self.logs_text.setText(style);
    }
    self.logs_text.meta.ownership.meta.test_id = "socks.info.logs.content";
    try self.logs_body.content.appendChild(cx.allocator, self.logs_text);
    try logs_popup.content.appendChild(cx.allocator, self.logs_body.container);
    if (!self.logs_portaled) try self.wrapper.appendChild(cx.allocator, self.logs_wrapper);
    const foot = try ui.box(cx, S.footer(), .{});
    self.footer = foot;
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
    button_paints: [6]struct { style: *ui.Signal(ButtonStyle), interaction: *ui.Signal(?ButtonStyle), action: Action } = undefined,
    button_count: usize = 0,
    logs_text: *ui.Node = undefined,
    logs_visible: bool = false,
    logs_root: *ui.Node = undefined,
    logs_wrapper: *ui.Node = undefined,
    logs_portaled: bool = false,
    logs_open: *ui.Signal(bool) = undefined,
    logs_owner: *ui.Node = undefined,
    logs_close: *ui.Node = undefined,
    logs_body: ui.widgets.ScrollAreaResult = undefined,
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
        const logs = if (data.logs.len > 0) data.logs else "尚无转发日志，启动后记录关键步骤耗时。";
        if (!std.mem.eql(u8, self.logs_text.getText().?.content, logs))
            try self.logs_text.setTextContent(self.cx.allocator, logs);
        self.message_is_error = data.error_text.len > 0;
        self.has_rule = data.configured or data.state != .off;
        self.empty.setDisplay(if (self.has_rule) .none else .flex);
        self.rule.setDisplay(if (self.has_rule) .flex else .none);
        self.control_button.setDisplay(if (self.has_rule) .flex else .none);
        try self.config_text.setTextContent(self.cx.allocator, if (self.has_rule) "配置" else "添加转发");
        try self.mode_label.setTextContent(self.cx.allocator, switch (data.mode) {
            .socks5 => "SOCKS5 · 动态目标",
            .local => "本地 L",
            .remote => "远端 R",
        });
        var buffer: [384]u8 = undefined;
        try self.address.setTextContent(self.cx.allocator, if (data.mode == .socks5) try std.fmt.bufPrint(&buffer, "{s}:{d}", .{ data.bind, data.port }) else try std.fmt.bufPrint(&buffer, "{s}:{d} → {s}:{d}", .{ data.bind, data.port, data.target_host, data.target_port }));
        try self.bind_note.setTextContent(self.cx.allocator, if (data.mode == .remote) "SSH 端监听 → 本机目标" else if (std.mem.eql(u8, data.bind, "0.0.0.0")) "本机监听 · 局域网可访问" else "本机监听 · 仅本机可访问");
        try self.exit.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&buffer, "出口 {s}", .{if (data.exit.len > 0) data.exit else if (data.host.len > 0) data.host else "—"}));
        try self.route.setTextContent(self.cx.allocator, data.route);
        self.route.setDisplay(if (data.route.len == 0) .none else .flex);
        var count_buffer: [192]u8 = undefined;
        var down_buf: [32]u8 = undefined;
        var up_buf: [32]u8 = undefined;
        try self.statistics.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&count_buffer, "下载 {s}  ·  上传 {s}", .{ try formatBytes(&down_buf, data.downloaded), try formatBytes(&up_buf, data.uploaded) }));
        try self.protocol.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&count_buffer, "{d} 个活跃连接 · {s}", .{ data.connections, if (data.mode == .socks5) "TCP · 不支持 UDP" else "固定TCP目标" }));
        try self.owner.setTextContent(self.cx.allocator, if (data.host.len > 0) try std.fmt.bufPrint(&count_buffer, "#{s}", .{data.host}) else "");
        try self.logs_owner.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&count_buffer, "{s}  ·  最近 24 条", .{self.owner.getText().?.content}));
        try self.status.setTextContent(self.cx.allocator, switch (data.state) {
            .off => "未开启",
            .connecting => "启动中",
            .running => "正在监听",
            .paused => "连接已断开",
            .failed => "启动失败",
        });
        try self.intro.setTextContent(self.cx.allocator, switch (data.state) {
            .running => "监听已就绪，可连接下方地址",
            .connecting => "正在建立转发，请稍候",
            .failed => "转发未运行，请检查错误后重试",
            .paused => "SSH 连接已断开，等待恢复",
            .off => if (self.has_rule) "配置已就绪，点击启动转发" else "添加规则后启动转发",
        });
        self.test_disabled.set(data.state != .running or data.mode != .socks5);
        self.copy_button.setDisplay(if (self.has_rule and data.mode == .socks5) .flex else .none);
        self.test_button.setDisplay(if (self.has_rule and data.mode == .socks5) .flex else .none);
        self.control_disabled.set(data.state == .connecting);
        const active = data.state == .running or data.state == .paused;
        try self.control_text.setTextContent(self.cx.allocator, if (active) "停止转发" else if (data.state == .connecting) "启动中…" else if (data.state == .failed) "重试" else "启动转发");
        if (self.control_button.behavior.interaction.a11y) |*attrs| attrs.label = if (active) "停止转发" else "开启转发";
        if (self.config_button.behavior.interaction.a11y) |*attrs| attrs.label = if (self.has_rule) "编辑转发配置" else "添加转发";
        const message = if (data.error_text.len > 0) data.error_text else data.test_result;
        try self.message.setTextContent(self.cx.allocator, message);
        self.message.setDisplay(.flex);
        self.retheme();
        self.paintState();
    }

    /// Paint only: retain original nodes, action state, trigger and geometry.
    pub fn retheme(self: *View) void {
        const colors = S.theme.current();
        if (self.paint_colors) |old| if (std.meta.eql(old, colors)) return;
        if (self.paint_colors) |previous| {
            repaintIcons(self.root, previous);
            repaintIcons(self.logs_root, previous);
        }
        self.root.setStyleInline(self.cx.allocator, S.panel());
        self.logs_root.setStyleInline(self.cx.allocator, S.panel());
        self.logs_body.container.setStyleInline(self.cx.allocator, .{ .background = S.theme.popupInset(), .border = .{ .radius = 8, .width = 1, .color = colors.border } });
        self.rule.setBackground(S.theme.popupInset());
        self.pointer.setStyleInline(self.cx.allocator, S.pointer());
        _ = self.title_icon.setTint(colors.accent);
        _ = self.pointer.setTint(colors.fg_3);
        self.close_button.setStyleInline(self.cx.allocator, S.iconButton(28));
        for (self.button_paints[0..self.button_count]) |paint| paint.style.set(buttonStyle(paint.action));
        for (self.painted_text.items) |item| setColor(item.node, S.text(item.role));
        self.paint_colors = colors;
        self.paintState();
    }

    fn paintState(self: *View) void {
        const c = S.theme.current();
        setColor(self.status, switch (self.state) {
            .running => S.text(.success),
            .connecting, .paused => S.text(.warning),
            .failed => S.text(.danger),
            .off => c.fg_2,
        });
        const active = self.state == .running or self.state == .paused;
        setColor(self.control_text, if (active) c.danger_ink else if (self.state == .connecting) c.fg_3 else ui.Color.WHITE);
        setColor(self.config_text, if (self.has_rule) c.fg_2 else ui.Color.WHITE);
        for (self.button_paints[0..self.button_count]) |paint| {
            var style = buttonStyle(paint.action);
            if (paint.action == .config and !self.has_rule) style.background = c.accent;
            if (paint.action == .start) style.background = if (active or self.state == .connecting) S.theme.popupAction() else c.accent;
            paint.style.set(style);
            paint.interaction.set(.{ .background = if (paint.action == .start) style.background else c.hover });
        }
        // Publish the settled action color after layout: the widget transition
        // can otherwise retain its previous gray paint in an idle native window.
        const control_background = if (active or self.state == .connecting) S.theme.popupAction() else c.accent;
        if (!ui.Color.eql(self.control_button.getBackground(), control_background)) {
            self.control_button.setBackgroundRaw(control_background);
            self.control_button.markRenderDirty();
        }
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
        self.logs_visible = false;
        self.logs_open.set(false);
        self.logs_root.setDisplay(.none);
        self.open.set(false);
        self.root.setDisplay(.none);
        self.cx.requestRedraw();
    }
    /// Public for layout tests and host resize integration.
    pub fn updateGeometry(self: *View) bool {
        if (self.logs_visible) {
            const upper = anchorRect(self).y;
            const height = @max(@as(f32, 1), @min(S.logs_height, @min(self.cx.viewport.height - 16, upper - 14)));
            const width = @max(@as(f32, 1), @min(S.logs_width, self.cx.viewport.width - 16));
            const changed = self.logs_root.style.width != .px or self.logs_root.style.height != .px or @abs(self.logs_root.style.width.px - width) > 0.5 or @abs(self.logs_root.style.height.px - height) > 0.5;
            if (changed) self.logs_root.setStyleInline(self.cx.allocator, .{ .width = .{ .px = width }, .height = .{ .px = height } });
            return changed;
        }
        if (self.root.style.display == .none) return false;
        if (self.anchor_node) |node| if (!node.isDisplayedInTree()) {
            self.hide();
            return false;
        };
        const upper = anchorRect(self).y;
        const available = @max(@as(f32, 1), @min(self.cx.viewport.height - 16, upper - 14));
        const width = @max(@as(f32, 1), @min(S.width, self.cx.viewport.width - 16));
        // Content changes must never move the bottom-anchored popup.
        const natural = S.body_height;
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
    fn closeLogs(self: *View) void {
        if (!self.logs_visible) return;
        self.logs_visible = false;
        self.logs_open.set(false);
        self.logs_root.setDisplay(.none);
        self.open.set(true);
        self.root.setDisplay(.flex);
        self.cx.requestRedraw();
    }
    fn logsOpenChanged(self: *View, value: bool) void {
        if (!value) self.closeLogs();
    }
    fn openChanged(self: *View, value: bool) void {
        if (!value and !self.logs_visible) self.hide();
    }
    fn releaseFocus(self: *View) void {
        if (self.cx.focus_manager.current_focus) |focused| if (focused.isDescendantOf(self.root) or focused.isDescendantOf(self.logs_root)) self.cx.clearFocus();
    }
    pub fn dispatch(self: *View, requested: Action) void {
        if (requested == .logs) {
            self.logs_visible = true;
            self.open.set(false);
            self.root.setDisplay(.none);
            self.logs_open.set(true);
            self.logs_root.setDisplay(.flex);
            self.cx.requestRedraw();
            return;
        }
        if (requested == .logs_back) {
            self.closeLogs();
            return;
        }
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
    const node = try ui.text(self.cx, value, .{ .font_size = size, .font_weight = weight, .color = S.text(role), .use_monospace_font = mono, .line_height = (if (size >= 21) @as(f32, 30) else if (size >= 17) @as(f32, 26) else if (size >= 13) @as(f32, 20) else if (size >= 12) @as(f32, 18) else 16) / size, .wrap = .none, .text_overflow = .ellipsis });
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
    const icon_only = action == .copy_export or action == .logs;
    const click = try self.cx.allocator.create(Click);
    click.* = .{ .view = self, .action = action };
    try self.scope.onCleanup(Click, click, Click.cleanup);
    const disabled = if (action == .test_proxy or action == .copy_export) self.test_disabled else if (action == .start) self.control_disabled else null;
    const paint = try self.scope.createSignal(ButtonStyle, buttonStyle(action));
    const interaction = try self.scope.createSignal(?ButtonStyle, .{ .background = S.theme.current().hover });
    self.button_paints[self.button_count] = .{ .style = paint, .interaction = interaction, .action = action };
    self.button_count += 1;
    const node = try ui.widgets.Button(.{ .base_style = ui.Source(ButtonStyle){ .signal = paint }, .variant = .ghost, .hover_style = ui.Source(?ButtonStyle){ .signal = interaction }, .pressed_style = ui.Source(?ButtonStyle){ .signal = interaction }, .icon_only = icon_only, .a11y_label = label, .disabled = if (disabled) |signal| ui.Source(bool){ .signal = signal } else ui.Source(bool){ .value = false }, .on_click = self.cx.on(Click, click, Click.invoke) }).mount(self.scope, self.cx);
    if (action == .start) node.applyTransition(self.cx.allocator, &(comptime ui.transition("background 0ms")));
    if (icon_only) {
        try node.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.get(if (action == .copy_export) "copy" else "file-text").?, S.theme.current().fg_2, S.icon(if (action == .config) @as(f32, 14) else 16)));
    } else {
        const copy = try text(self, label, 13, 500, .secondary, false);
        if (action == .start) self.control_text = copy;
        if (action == .config) self.config_text = copy;
        try node.appendChild(self.cx.allocator, copy);
    }
    if (action == .logs) node.meta.ownership.meta.test_id = "socks.info.logs";
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

fn buttonStyle(action: Action) ButtonStyle {
    const icon_only = action == .copy_export or action == .logs;
    return .{
        .width = .{ .px = switch (action) {
            .copy_export, .logs => 28,
            .logs_back, .config, .test_proxy => 72,
            else => 88,
        } },
        .height = .{ .px = if (icon_only) 28 else 30 },
        .background = S.theme.popupAction(),
        .corner_radius = 8,
        .border_width = 0,
        .padding = .{},
        .gap = 0,
        .flex_shrink = 0,
        .align_items = .center,
        .justify = .center,
    };
}
