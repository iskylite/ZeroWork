//! Production SOCKS card. Values are copied into stable text nodes on the UI thread.
//! Live V2 Bridge 358:1419344: 360px compact forwarding card with fixed actions.
const std = @import("std");
const ui = @import("ui");
const S = @import("socks_info_styles.zig");

pub const State = enum { off, connecting, running, paused, failed };
pub const Data = struct {
    state: State = .off,
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
    var panel_style = S.panel();
    panel_style.position = .absolute;
    panel_style.inset = .{ .right = .{ .px = 24 }, .bottom = .{ .px = 62 } };
    panel_style.width = .{ .px = S.width };
    panel_style.height = .{ .px = S.normal_height };
    panel_style.direction = .column;
    panel_style.display = .none;
    panel_style.padding = .{ .left = 14, .right = 14, .top = 17, .bottom = 18 };
    panel_style.gap = 0;
    panel_style.z_index = 50;
    panel_style.flex_shrink = 0;
    self.root = try ui.box(cx, panel_style, .{});
    self.root.meta.ownership.meta.test_id = "socks.info";
    self.pointer = try ui.iconTint(cx, ui.icons.get("chevron-down").?, S.theme.current().fg_3, S.icon(12));
    self.pointer.setStyleInline(cx.allocator, .{ .position = .absolute, .inset = .{ .bottom = .{ .px = 0 }, .right = .{ .px = 64 } }, .z_index = 51 });
    try self.root.appendChild(cx.allocator, self.pointer);
    self.header = try ui.box(cx, S.header(), .{});
    self.title_icon = try ui.iconTint(cx, ui.icons.get("plug-zap").?, S.theme.current().accent, S.icon(18));
    try self.header.appendChild(cx.allocator, self.title_icon);
    try self.header.appendChild(cx.allocator, try text(self, "SOCKS5 转发", 13, 700, .primary, false));
    try self.header.appendChild(cx.allocator, try ui.spacer(cx));
    self.close_button = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .a11y_label = "关闭 SOCKS5 信息", .on_click = cx.on(View, self, View.hide) }).mount(scope, cx);
    self.close_button.setStyleInline(cx.allocator, S.iconButton(26));
    try self.close_button.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.x, S.theme.current().fg_2, S.icon(14)));
    self.close_button.meta.ownership.meta.test_id = "socks.info.close";
    try self.header.appendChild(cx.allocator, self.close_button);
    try self.root.appendChild(cx.allocator, self.header);
    self.body = try ui.widgets.ScrollArea(.{ .direction = .vertical }).mount(scope, cx);
    self.body.container.style.width = .fill();
    self.body.container.style.height = .{ .px = S.body_height };
    self.body.container.style.flex_shrink = 0;
    self.body.content.setStyleInline(cx.allocator, S.body());
    try self.root.appendChild(cx.allocator, self.body.container);
    const identity = try ui.box(cx, S.line(16), .{});
    self.owner = try text(self, "归属", 9.5, 400, .secondary, false);
    self.exit = try text(self, "—", 9.5, 400, .secondary, false);
    self.route = try text(self, "", 9.5, 400, .muted, false);
    self.address = try text(self, "", 9.5, 400, .primary, true);
    self.bind_note = try text(self, "", 9.5, 400, .muted, false);
    self.bind_note.setDisplay(.none);
    try identity.appendChild(cx.allocator, self.owner);
    try identity.appendChild(cx.allocator, self.exit);
    try identity.appendChild(cx.allocator, self.route);
    try identity.appendChild(cx.allocator, self.address);
    try identity.appendChild(cx.allocator, self.bind_note);
    try self.body.content.appendChild(cx.allocator, identity);
    var listener_style = S.line(26);
    listener_style.padding = .{ .left = 6, .right = 6 };
    listener_style.gap = 6;
    const listener = try ui.box(cx, listener_style, .{});
    try listener.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get("plug-zap").?, S.theme.current().ok_ink, S.icon(14)));
    try listener.appendChild(cx.allocator, try text(self, "监听状态", 11, 400, .primary, false));
    try listener.appendChild(cx.allocator, try ui.spacer(cx));
    self.status = try text(self, "未开启", 10.5, 500, .muted, false);
    try listener.appendChild(cx.allocator, self.status);
    try self.body.content.appendChild(cx.allocator, listener);
    const statistics = try ui.box(cx, S.line(26), .{});
    self.statistics = try text(self, "0 B ↓ · 0 B ↑", 17, 500, .primary, false);
    try statistics.appendChild(cx.allocator, self.statistics);
    try self.body.content.appendChild(cx.allocator, statistics);
    self.protocol = try text(self, "0 个活跃连接 · 仅 TCP CONNECT · UDP 不支持", 10, 400, .secondary, false);
    try self.body.content.appendChild(cx.allocator, self.protocol);
    self.message = try text(self, "", 10.5, 400, .secondary, false);
    self.message.setDisplay(.none);
    try self.body.content.appendChild(cx.allocator, self.message);
    const foot = try ui.box(cx, S.footer(), .{});
    self.footer = foot;
    self.copy_button = try button(self, foot, "复制代理", .copy_export);
    self.test_button = try button(self, foot, "测试", .test_proxy);
    self.config_button = try button(self, foot, "配置 SOCKS5", .config);
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
    try self.root.appendChild(cx.allocator, foot);
    try self.update(.{});
    try cx.addAfterLayoutHook(self, View.afterLayout);
    return self;
}

pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    hooks: Hooks,
    root: *ui.Node,
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
    close_button: *ui.Node,
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
        var buffer: [128]u8 = undefined;
        try self.address.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&buffer, "{s}:{d}", .{ data.bind, data.port }));
        try self.bind_note.setTextContent(self.cx.allocator, if (std.mem.eql(u8, data.bind, "0.0.0.0")) "局域网可访问" else "仅本机");
        try self.exit.setTextContent(self.cx.allocator, if (data.session_id != null and std.mem.eql(u8, data.host, if (data.exit.len > 0) data.exit else data.host)) "出口" else if (data.exit.len > 0) data.exit else if (data.host.len > 0) data.host else "—");
        try self.route.setTextContent(self.cx.allocator, data.route);
        var count_buffer: [192]u8 = undefined;
        var down_buf: [32]u8 = undefined;
        var up_buf: [32]u8 = undefined;
        try self.statistics.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&count_buffer, "{s} ↓ · {s} ↑", .{ try formatBytes(&down_buf, data.downloaded), try formatBytes(&up_buf, data.uploaded) }));
        try self.protocol.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&count_buffer, "{d} 个活跃连接 · 仅 TCP CONNECT · UDP 不支持", .{data.connections}));
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
        self.test_disabled.set(data.state != .running);
        self.control_disabled.set(data.state == .connecting);
        const active = data.state == .running or data.state == .paused;
        try self.control_text.setTextContent(self.cx.allocator, if (active) "停止" else "开启");
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
        self.pointer.setStyleInline(self.cx.allocator, S.pointer());
        _ = self.title_icon.setTint(colors.accent);
        _ = self.pointer.setTint(colors.fg_3);
        self.close_button.setStyleInline(self.cx.allocator, S.iconButton(26));
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
        setColor(self.message, if (self.message_is_error) c.danger_ink else c.fg_2);
    }
    pub fn show(self: *View, anchor: ui.ComputedRect) void {
        self.anchor_node = null;
        self.anchor = anchor;
        self.root.setDisplay(.flex);
        self.cx.requestRedraw();
    }

    /// Show from the actual trigger node.  Resolving its rect on every layout
    /// keeps the popup attached when the status bar moves after resize/reflow.
    pub fn showNode(self: *View, anchor: *ui.Node) void {
        self.anchor_node = anchor;
        self.anchor = anchor.globalRect();
        self.root.setDisplay(.flex);
        self.cx.requestRedraw();
    }
    pub fn hide(self: *View) void {
        self.root.setDisplay(.none);
        self.cx.requestRedraw();
    }
    /// Public for layout tests and host resize integration.
    pub fn updateGeometry(self: *View) bool {
        if (self.root.style.display == .none) return false;
        const parent = self.root.parent orelse return false;
        const bounds = parent.globalRect();
        if (bounds.w <= 0 or bounds.h <= 0) return false;
        const width = @max(@as(f32, 1), @min(S.width, bounds.w - 16));
        const available = @max(@as(f32, 1), bounds.h - 16);
        const natural: f32 = S.body_height + (if (self.message.style.display != .none or self.state != .running) @as(f32, 22) else 0);
        const fixed: f32 = S.chrome_height;
        const body_h = @min(natural, @max(@as(f32, 1), available - fixed));
        const card_h = body_h + fixed;
        // Original card is at the lower-right, 34px above the statusbar. The
        // status chip is the trigger, not a floating object over terminal text.
        const anchor = if (self.anchor_node) |node| node.globalRect() else self.anchor orelse ui.ComputedRect{ .x = bounds.x, .y = bounds.y + bounds.h - 28, .w = 0, .h = 0 };
        const status_top = if (self.anchor_node) |node| if (node.parent) |parent_node| if (parent_node.meta.ownership.meta.test_id != null and std.mem.eql(u8, parent_node.meta.ownership.meta.test_id.?, "workspace.statusbar")) parent_node.globalRect().y else anchor.y else anchor.y else anchor.y;
        const ideal_y = status_top - bounds.y - 6 - card_h;
        const top = std.math.clamp(ideal_y, @as(f32, 8), @max(@as(f32, 8), bounds.h - card_h - 8));
        // Center the card on the live trigger first, then clamp it inside the
        // parent.  A fixed right inset makes the card appear stuck while the
        // status chip moves during resize/reflow.
        const desired_root_x = anchor.x + anchor.w / 2 - width / 2;
        const desired_right = bounds.x + bounds.w - desired_root_x - width;
        const right = std.math.clamp(desired_right, @as(f32, 8), @max(@as(f32, 8), bounds.w - width - 8));
        const ext = self.root.style.ensureExtPanic(self.cx.allocator);
        // Keep the pointer centered on the trigger, clamped inside the card.
        // A fixed `right: 64px` drifts when the chip width or window changes.
        const root_x = bounds.x + bounds.w - right - width;
        const pointer_left = std.math.clamp(anchor.x + anchor.w / 2 - root_x - 6, @as(f32, 8), @max(@as(f32, 8), width - 20));
        const pointer_right = width - pointer_left - 12;
        var changed = false;
        if (self.root.style.width != .px or @abs(self.root.style.width.px - width) > 0.5) {
            self.root.style.width = .{ .px = width };
            changed = true;
        }
        if (self.root.style.height != .px or @abs(self.root.style.height.px - card_h) > 0.5) {
            self.root.style.height = .{ .px = card_h };
            changed = true;
        }
        if (self.body.container.style.height != .px or @abs(self.body.container.style.height.px - body_h) > 0.5) {
            self.body.container.style.height = .{ .px = body_h };
            self.body.container.markLayoutDirty();
            changed = true;
        }
        if (ext.inset.top != .px or @abs(ext.inset.top.px - top) > 0.5 or ext.inset.right != .px or @abs(ext.inset.right.px - right) > 0.5) {
            ext.inset.top = .{ .px = top };
            ext.inset.right = .{ .px = right };
            ext.inset.bottom = .auto;
            changed = true;
        }
        const pointer_ext = self.pointer.style.ensureExtPanic(self.cx.allocator);
        if (pointer_ext.inset.right != .px or @abs(pointer_ext.inset.right.px - pointer_right) > 0.5) {
            pointer_ext.inset.right = .{ .px = pointer_right };
            changed = true;
        }
        if (changed) self.root.markLayoutDirty();
        return changed;
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
    const icon_only = action == .copy_export or action == .config;
    const click = try self.cx.allocator.create(Click);
    click.* = .{ .view = self, .action = action };
    try self.scope.onCleanup(Click, click, Click.cleanup);
    const disabled = if (action == .test_proxy or action == .copy_export) self.test_disabled else if (action == .start) self.control_disabled else null;
    const paint = try self.scope.createSignal(ui.BoxStyle, buttonStyle(action));
    self.button_paints[self.button_count] = .{ .style = paint, .action = action };
    self.button_count += 1;
    const node = try ui.widgets.Button(.{ .base_style = paint, .variant = .ghost, .icon_only = icon_only, .a11y_label = label, .disabled = if (disabled) |signal| ui.Source(bool){ .signal = signal } else ui.Source(bool){ .value = false }, .on_click = self.cx.on(Click, click, Click.invoke) }).mount(self.scope, self.cx);
    if (icon_only) {
        try node.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.get(if (action == .copy_export) "copy" else "settings-2").?, S.theme.current().fg_2, S.icon(if (action == .config) @as(f32, 14) else 16)));
    } else {
        const copy = try text(self, label, 12, 500, .secondary, false);
        if (action == .start) self.control_text = copy;
        try node.appendChild(self.cx.allocator, copy);
    }
    try parent.appendChild(self.cx.allocator, node);
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
    const icon_only = action == .copy_export or action == .config;
    var skin = S.button(if (action == .config) .icon else .ordinary);
    skin.width = .{ .px = switch (action) {
        .copy_export, .config => 28,
        .test_proxy => 58,
        else => 82,
    } };
    skin.height = .{ .px = if (action == .config) 26 else if (icon_only) 28 else 30 };
    skin.padding = .{};
    skin.gap = 0;
    skin.flex_shrink = 0;
    skin.align_items = .center;
    skin.justify = .center;
    return skin;
}
