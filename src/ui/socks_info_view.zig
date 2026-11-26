//! Production SOCKS card. Values are copied into stable text nodes on the UI thread.
const std = @import("std");
const ui = @import("ui");
const S = @import("socks_info_styles.zig");
const mascot_island = @import("mascot_island.zig");
const ButtonStyle = @FieldType(ui.widgets.ControlShellConfig, "style");

pub const rail_gap: f32 = 12;
const viewport_padding: f32 = 8;
const dock_padding: f32 = 12;

const DockSide = enum { left, right, above, below };

/// Dock in one of the four half-planes *outside* the complete tools
/// footprint. Never ask a generic positioner to shift onto the rail.
/// Rank by a stable size budget so counters, text wrapping, and scroll
/// height changes cannot make the panel repeatedly switch sides.
fn dockRect(bounds: ui.ComputedRect, footprint: mascot_island.ToolFootprint, trigger: ui.ComputedRect, desired_w: f32, height_budget: f32, natural_h: f32) ?ui.ComputedRect {
    const frame = footprint.bounds;
    const near = [2]DockSide{
        if (frame.x + frame.w / 2 > bounds.x + bounds.w / 2) .left else .right,
        if (frame.y + frame.h / 2 > bounds.y + bounds.h / 2) .above else .below,
    };
    const far = [2]DockSide{ if (near[0] == .left) .right else .left, if (near[1] == .above) .below else .above };
    const order = if (footprint.horizontal) [4]DockSide{ near[1], far[1], near[0], far[0] } else [4]DockSide{ near[0], far[0], near[1], far[1] };
    const left = bounds.x + dock_padding;
    const top = bounds.y + dock_padding;
    const right = bounds.x + bounds.w - dock_padding;
    const bottom = bounds.y + bounds.h - dock_padding;
    var best: ?ui.ComputedRect = null;
    var best_rank: f32 = 0;
    for (order) |side| {
        const x1 = if (side == .right) @max(left, frame.x + frame.w + rail_gap) else left;
        const x2 = if (side == .left) @min(right, frame.x - rail_gap) else right;
        const y1 = if (side == .below) @max(top, frame.y + frame.h + rail_gap) else top;
        const y2 = if (side == .above) @min(bottom, frame.y - rail_gap) else bottom;
        const w = @min(desired_w, x2 - x1);
        const available_h = y2 - y1;
        if (w < S.minimum_width or available_h < S.chrome_height + 36) continue;
        const h = @min(natural_h, available_h);
        const rank = w * @min(height_budget, available_h);
        if (rank <= best_rank) continue;
        best_rank = rank;
        const anchor_y = if (trigger.y + trigger.h / 2 > bounds.y + bounds.h / 2) trigger.y + trigger.h - h else trigger.y;
        best = .{
            .x = switch (side) {
                .left => x2 - w,
                .right => x1,
                .above, .below => std.math.clamp(trigger.x + (trigger.w - w) / 2, x1, x2 - w),
            },
            .y = switch (side) {
                .left, .right => std.math.clamp(anchor_y, y1, y2 - h),
                .above => y2 - h,
                .below => y1,
            },
            .w = w,
            .h = h,
        };
    }
    return best;
}

pub const State = enum { off, connecting, running, paused, stopping, failed };
pub const Data = struct {
    mode: @import("../proto/ssh/socks5_listener.zig").ForwardMode = .socks5,
    target_host: []const u8 = "",
    target_port: u16 = 0,
    state: State = .off,
    configured: bool = false,
    read_only: bool = false,
    status_label: ?[]const u8 = null,
    intro_label: ?[]const u8 = null,
    port: ?u16 = null,
    bind: []const u8 = "127.0.0.1",
    host: []const u8 = "",
    /// Stable UI workspace session ID, matching the tab label (not a domain enum).
    session_id: ?u64 = null,
    /// Name of the actually selected authenticated exit (target or intermediate hop).
    exit: []const u8 = "",
    /// Actual route description; empty for a direct connection.
    route: []const u8 = "",
    connections: ?usize = null,
    uploaded: ?u64 = null,
    downloaded: ?u64 = null,
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
    return mountAnchored(cx, scope, hooks, false);
}

/// The workspace mode docks outside the entire live tool rail. The legacy
/// status chip keeps its original automatic top/bottom placement.
pub fn mountAnchored(cx: *ui.Cx, scope: *ui.Scope, hooks: Hooks, dock_to_rail: bool) !*View {
    const self = try cx.allocator.create(View);
    self.* = .{ .dock_to_rail = dock_to_rail, .cx = cx, .scope = scope, .hooks = hooks, .root = undefined, .body = undefined, .header = undefined, .footer = undefined, .status = undefined, .address = undefined, .bind_note = undefined, .exit = undefined, .route = undefined, .statistics = undefined, .message = undefined, .control_text = undefined, .test_button = undefined, .copy_button = undefined, .config_button = undefined, .control_button = undefined, .pointer = undefined, .protocol = undefined, .owner = undefined, .title_icon = undefined, .close_button = undefined, .test_disabled = try scope.createSignal(bool, true), .control_disabled = try scope.createSignal(bool, false) };
    try scope.onCleanup(View, self, View.cleanup);
    const focus_guard = try scope.childScope();
    self.open = try scope.createSignal(bool, false);
    const popup = try ui.widgets.Popover(self.popupProps(S.width, false)).mount(scope, cx);
    self.scope = popup.scope;
    self.wrapper = popup.wrapper;
    self.portaled = popup.portaled;
    self.frame = popup.content;
    self.frame.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .fill(), .min_height = 0, .direction = .column, .gap = 0, .padding = .{} });
    try focus_guard.onCleanup(View, self, View.releaseFocus);
    var panel_style = self.panelStyle();
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
    self.close_button = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .a11y_label = "关闭端口转发信息", .base_style = S.iconButton(28), .hover_style = .{ .background = S.theme.states().hover }, .on_click = cx.on(View, self, View.hide) }).mount(scope, cx);
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
    self.current_content = try ui.box(cx, S.body(), .{});
    try self.body.content.appendChild(cx.allocator, self.current_content);
    self.intro = try text(self, "添加规则后启动转发", 13, 400, .secondary, false);
    self.intro.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 20 }, .flex_shrink = 0 });
    try self.current_content.appendChild(cx.allocator, self.intro);
    self.empty = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 126 }, .direction = .column, .align_items = .center, .justify = .center, .gap = 10, .flex_shrink = 0 }, .{});
    self.empty.meta.ownership.meta.test_id = "socks.info.empty";
    try self.empty.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get("plug-zap").?, S.theme.current().fg_3, S.icon(24)));
    try self.empty.appendChild(cx.allocator, try text(self, "没有转发规则", 12, 500, .primary, false));
    try self.empty.appendChild(cx.allocator, try text(self, "本地 L · 远端 R · 动态 SOCKS5", 10, 400, .secondary, false));
    try self.current_content.appendChild(cx.allocator, self.empty);
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
    self.connections_hint = try scope.createText("", .{});
    self.connections_tip = try ui.widgets.Tooltip(.{ .text = self.connections_hint, .background = S.theme.current().overlay, .text_color = S.theme.current().fg_1 }).mount(scope, cx);
    self.connections_tip.wrapper.setStyleInline(cx.allocator, .{ .flex_shrink = 0 });
    self.connections_text = try text(self, "", 12, 400, .secondary, false);
    self.connections_text.meta.ownership.meta.test_id = "socks.info.connections";
    self.connections_tip.content.meta.ownership.meta.test_id = "socks.info.connections.hint";
    try self.connections_tip.trigger.appendChild(cx.allocator, self.connections_text);
    try identity.appendChild(cx.allocator, self.connections_tip.wrapper);
    try identity.appendChild(cx.allocator, try ui.spacer(cx));
    try self.rule.appendChild(cx.allocator, identity);
    self.mode_label = try text(self, "SOCKS5", 12, 400, .secondary, false);
    try identity.appendChild(cx.allocator, self.mode_label);
    const endpoint = try ui.box(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .row, .gap = 8, .align_items = .center, .flex_shrink = 0 }, .{});
    self.endpoint = endpoint;
    self.address.setStyleInline(cx.allocator, .{ .flex = 1 });
    try endpoint.appendChild(cx.allocator, self.address);
    self.copy_button = try button(self, endpoint, "复制", .copy_export);
    try self.rule.appendChild(cx.allocator, endpoint);
    try self.rule.appendChild(cx.allocator, self.bind_note);
    try self.rule.appendChild(cx.allocator, self.exit);
    try self.rule.appendChild(cx.allocator, self.route);
    self.statistics = try text(self, "0 B ↓ · 0 B ↑", 15, 600, .primary, false);
    self.statistics.setStyleInline(cx.allocator, .{ .margin = .{ .top = 6 }, .padding = .{ .top = 8 }, .flex_shrink = 0 });
    try self.rule.appendChild(cx.allocator, self.statistics);
    const details_row = try ui.box(cx, S.line(34), .{});
    self.details_row = details_row;
    self.protocol = try text(self, "TCP · 不支持 UDP", 12, 400, .primary, false);
    self.protocol.setStyleInline(cx.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0 });
    try details_row.appendChild(cx.allocator, self.protocol);
    self.logs_button = try button(self, details_row, "查看日志", .logs);
    try self.rule.appendChild(cx.allocator, details_row);
    try self.current_content.appendChild(cx.allocator, self.rule);
    self.message = try text(self, "", 12, 400, .secondary, false);
    self.message.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .min_height = 32, .min_width = 0, .margin = .{ .top = 8 }, .flex_shrink = 0 });
    if (self.message.getText()) |old| {
        var style = old;
        style.wrap = .word;
        style.text_overflow = .clip;
        self.message.setText(style);
    }
    self.message.setDisplay(.none);
    try self.current_content.appendChild(cx.allocator, self.message);
    self.logs_open = try scope.createSignal(bool, false);
    const logs_popup = try ui.widgets.Popover(self.popupProps(S.logs_width, true)).mount(scope, cx);
    self.logs_wrapper = logs_popup.wrapper;
    self.logs_portaled = logs_popup.portaled;
    self.logs_root = logs_popup.chrome;
    var logs_style = self.panelStyle();
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
    self.logs_body.container.setStyleInline(cx.allocator, .{ .background = S.theme.popupInset(), .border = .{ .radius = 8, .width = 0, .color = ui.Color.TRANSPARENT } });
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
    try self.rule.appendChild(cx.allocator, foot);
    try self.update(.{});
    try cx.addAfterLayoutHook(self, View.afterLayout);
    return self;
}

pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    hooks: Hooks,
    dock_to_rail: bool,
    mascot: ?*mascot_island.View = null,
    dock_target: ?ui.ComputedRect = null,
    current_content: *ui.Node = undefined,
    current_available: bool = true,
    connections_tip: ui.widgets.TooltipResult = undefined,
    connections_text: *ui.Node = undefined,
    connections_hint: *ui.Signal([]const u8) = undefined,
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
    test_text: *ui.Node = undefined,
    test_button: *ui.Node,
    copy_button: *ui.Node,
    logs_button: *ui.Node = undefined,
    copy_feedback: *@import("copy_button.zig").Button = undefined,
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
    read_only: bool = false,
    details_row: *ui.Node = undefined,
    endpoint: *ui.Node = undefined,
    test_disabled: *ui.Signal(bool),
    control_disabled: *ui.Signal(bool),
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

    fn popupProps(self: *View, width: f32, logs: bool) ui.widgets.popover.PopoverProps {
        const dock = self.dock_to_rail;
        return .{
            .on_group_dismiss = if (logs) self.cx.on(View, self, View.hide) else null,
            .group = @import("floating_surface.zig").workspace_popup,
            .open = .bindTo(if (logs) self.logs_open else self.open),
            .trigger = .manual,
            .close_on_outside_click = logs,
            .position = if (dock) .bottom_start else .top,
            .width = if (dock) null else width,
            .max_width = if (dock) null else width,
            .offset = .{ .static = if (dock) 0 else 6 },
            .viewport_padding = viewport_padding,
            .flip = !dock,
            .shift_main_axis = !dock,
            .constrain_width_to_viewport = !dock,
            .clip_subtree_to_chrome = dock,
            .enter_transition = .none,
            .exit_transition = .none,
            .anchor = .{ .virtual = .{ .ctx = self, .getRect = if (dock) View.dockAnchor else View.anchorRect } },
            .on_open_change = if (logs) self.cx.on(View, self, View.logsOpenChanged) else self.cx.on(View, self, View.openChanged),
        };
    }

    pub fn bindMascot(self: *View, mascot: *mascot_island.View) void {
        self.mascot = mascot;
    }
    fn panelStyle(self: *const View) ui.BoxStyle {
        var style = S.panel();
        // Keep even the visible shadow inside the 12px dock clearance.
        if (self.dock_to_rail) style.shadow = .{ .blur = 8, .offset_y = 3, .color = S.theme.current().shadow };
        return style;
    }

    /// All borrowed strings are copied before return. Nodes and callbacks remain stable,
    /// so callbacks may synchronously update/hide this view without disposing their context.
    pub fn update(self: *View, data: Data) !void {
        const known_port = if (data.port) |p| if (p != 0) p else null else null;
        self.current_available = true;
        self.current_content.setDisplay(.flex);
        self.state = data.state;
        const logs = if (data.logs.len > 0) data.logs else "尚无转发日志，启动后记录关键步骤耗时。";
        if (!std.mem.eql(u8, self.logs_text.getText().?.content, logs))
            try self.logs_text.setTextContent(self.cx.allocator, logs);
        self.message_is_error = data.error_text.len > 0;
        self.read_only = data.read_only;
        self.has_rule = data.configured or data.state != .off;
        const has_endpoint = !data.read_only or data.state == .running;
        self.intro.setDisplay(if (!data.read_only or data.configured) .flex else .none);
        self.empty.setDisplay(if (self.has_rule or data.read_only) .none else .flex);
        self.rule.setDisplay(if (self.has_rule or data.read_only) .flex else .none);
        // The existing controls follow their rule; when unconfigured the same
        // Add action belongs to the empty state rather than an unattached bar.
        const control_parent = if (self.has_rule or data.read_only) self.rule else self.empty;
        if (self.footer.parent != control_parent) {
            if (self.footer.parent) |previous| self.cx.detachChildRetained(previous, self.footer);
            try control_parent.appendChild(self.cx.allocator, self.footer);
        }
        self.footer.setDisplay(if (data.read_only) .none else .flex);
        self.control_button.setDisplay(if (self.has_rule and !data.read_only) .flex else .none);
        self.config_button.setDisplay(if (data.read_only) .none else .flex);
        self.endpoint.setDisplay(if (has_endpoint) .flex else .none);
        self.address.setDisplay(if (has_endpoint) .flex else .none);
        self.bind_note.setDisplay(if (has_endpoint) .flex else .none);
        self.exit.setDisplay(if (!data.read_only or data.exit.len != 0) .flex else .none);
        self.mode_label.setDisplay(if (!data.read_only or data.configured) .flex else .none);
        self.statistics.setDisplay(if (data.uploaded != null or data.downloaded != null) .flex else .none);
        self.details_row.setDisplay(if (!data.read_only or data.configured) .flex else .none);
        try self.config_text.setTextContent(self.cx.allocator, if (self.has_rule) "配置" else "添加转发");
        const config_width: f32 = if (self.has_rule) 60 else 80;
        if (self.config_button.style.width != .px or self.config_button.style.width.px != config_width) {
            self.config_button.setStyleInline(self.cx.allocator, .{ .width = .{ .px = config_width } });
        }
        try self.mode_label.setTextContent(self.cx.allocator, switch (data.mode) {
            .socks5 => "SOCKS5 · 动态目标",
            .local => "本地 L",
            .remote => "远端 R",
        });
        var buffer: [384]u8 = undefined;
        try self.address.setTextContent(self.cx.allocator, if (known_port) |port|
            if (data.mode == .socks5) try std.fmt.bufPrint(&buffer, "{s}:{d}", .{ data.bind, port }) else try std.fmt.bufPrint(&buffer, "{s}:{d} → {s}:{d}", .{ data.bind, port, data.target_host, data.target_port })
        else if (data.port == 0 and data.state != .running and !data.read_only)
            "自动分配端口"
        else
            "尚无监听地址");
        try self.bind_note.setTextContent(self.cx.allocator, if (data.mode == .remote) "SSH 端监听 → 本机目标" else if (std.mem.eql(u8, data.bind, "0.0.0.0")) "本机监听 · 局域网可访问" else "本机监听 · 仅本机可访问");
        try self.exit.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&buffer, "出口 {s}", .{if (data.exit.len > 0) data.exit else if (data.host.len > 0) data.host else "—"}));
        try self.route.setTextContent(self.cx.allocator, data.route);
        self.route.setDisplay(if (data.route.len == 0) .none else .flex);
        var count_buffer: [192]u8 = undefined;
        var down_buf: [32]u8 = undefined;
        var up_buf: [32]u8 = undefined;
        try self.statistics.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&count_buffer, "下载 {s}  ·  上传 {s}", .{ if (data.downloaded) |v| try S.formatBytes(&down_buf, v) else "—", if (data.uploaded) |v| try S.formatBytes(&up_buf, v) else "—" }));
        if (data.state == .running and data.connections != null) {
            const count = data.connections.?;
            try self.connections_text.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&count_buffer, "#{d}", .{count}));
            self.connections_hint.set(try std.fmt.bufPrint(&count_buffer, "{d} 个活跃 TCP 连接", .{count}));
            self.connections_tip.wrapper.setDisplay(.flex);
        } else {
            self.hideConnections();
        }
        try self.protocol.setTextContent(self.cx.allocator, if (data.mode == .socks5) "TCP · 不支持 UDP" else "固定 TCP 目标");
        try self.owner.setTextContent(self.cx.allocator, if (data.host.len > 0) try std.fmt.bufPrint(&count_buffer, "#{s}", .{data.host}) else "");
        try self.logs_owner.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&count_buffer, "{s}  ·  最近 24 条", .{self.owner.getText().?.content}));
        try self.status.setTextContent(self.cx.allocator, data.status_label orelse switch (data.state) {
            .off => "未开启",
            .connecting => "启动中",
            .running => "正在监听",
            .paused => "连接已断开",
            .stopping => "停止中",
            .failed => "启动失败",
        });
        try self.intro.setTextContent(self.cx.allocator, data.intro_label orelse switch (data.state) {
            .running => "监听已就绪，可连接下方地址",
            .connecting => "正在建立转发，请稍候",
            .failed => "转发未运行，请检查错误后重试",
            .paused => "SSH 连接已断开，等待恢复",
            .stopping => "正在释放监听与连接，请稍候",
            .off => if (self.has_rule) "配置已就绪" else "尚未配置转发规则",
        });
        self.test_disabled.set(data.state != .running or data.mode != .socks5 or known_port == null);
        self.copy_button.setDisplay(if (has_endpoint and self.has_rule and data.mode == .socks5) .flex else .none);
        self.test_button.setDisplay(if (!data.read_only and self.has_rule and data.mode == .socks5) .flex else .none);
        self.control_disabled.set(data.state == .stopping);
        const active = data.state == .running or data.state == .paused;
        try self.control_text.setTextContent(self.cx.allocator, if (active) "停止转发" else if (data.state == .connecting) "取消启动" else if (data.state == .stopping) "停止中…" else if (data.state == .failed) "重试" else "启动转发");
        if (self.control_button.behavior.interaction.a11y) |*attrs| attrs.label = self.control_text.getText().?.content;
        if (self.config_button.behavior.interaction.a11y) |*attrs| attrs.label = if (self.has_rule) "编辑转发配置" else "添加转发";
        const message = if (data.error_text.len > 0) data.error_text else data.test_result;
        try self.message.setTextContent(self.cx.allocator, message);
        self.message.setDisplay(if (message.len > 0) .flex else .none);
        self.retheme();
        self.paintState();
    }

    fn hideConnections(self: *View) void {
        if (self.connections_tip.open) |open| open.set(false);
        self.connections_tip.wrapper.setDisplay(.none);
        self.connections_hint.set("");
    }
    /// No current forwarding owner: keep only the application-owned list.
    /// Hidden state cannot dispatch old actions or restore old logs.
    pub fn withoutCurrent(self: *View) void {
        if (!self.current_available) return;
        self.current_available = false;
        self.current_content.setDisplay(.none);
        self.hideConnections();
        self.owner.setTextContent(self.cx.allocator, "") catch {};
        self.logs_visible = false;
        self.logs_open.set(false);
        self.logs_root.setDisplay(.none);
    }

    /// Paint only: retain original nodes, action state, trigger and geometry.
    pub fn retheme(self: *View) void {
        const colors = S.theme.current();
        if (self.paint_colors) |old| if (std.meta.eql(old, colors)) return;
        if (self.paint_colors) |previous| {
            repaintIcons(self.root, previous);
            repaintIcons(self.logs_root, previous);
        }
        self.root.setStyleInline(self.cx.allocator, self.panelStyle());
        self.logs_root.setStyleInline(self.cx.allocator, self.panelStyle());
        self.logs_body.container.setStyleInline(self.cx.allocator, .{ .background = S.theme.popupInset(), .border = .{ .radius = 8, .width = 0, .color = ui.Color.TRANSPARENT } });
        self.rule.setBackground(S.theme.popupInset());
        self.pointer.setStyleInline(self.cx.allocator, S.pointer());
        _ = self.title_icon.setTint(colors.accent);
        _ = self.pointer.setTint(colors.fg_3);
        self.close_button.setStyleInline(self.cx.allocator, S.iconButton(28));
        for ([_]*ui.Node{ self.test_button, self.config_button, self.control_button }) |node|
            ui.hooks.updateFocusRingConfig(self.cx, node, .{ .color = colors.accent_ink, .offset = -2 });
        for (self.painted_text.items) |item| setColor(item.node, S.text(item.role));
        self.paint_colors = colors;
        self.paintState();
    }

    fn paintState(self: *View) void {
        const c = S.theme.current();
        setColor(self.status, switch (self.state) {
            .running => S.text(.success),
            .connecting, .paused, .stopping => S.text(.warning),
            .failed => S.text(.danger),
            .off => c.fg_2,
        });
        self.paintActions();
        setColor(self.message, if (self.message_is_error) c.danger_ink else c.fg_2);
    }
    fn paintActions(self: *View) void {
        // One footer paint owner, after the native widget's state transition
        // tick. Reopening a retained card or changing action role while it is
        // detached must never restore a former button's accent.
        const buttons = [_]*ui.Node{ self.test_button, self.config_button, self.control_button };
        const labels = [_]*ui.Node{ self.test_text, self.config_text, self.control_text };
        for (buttons, labels, [_]Action{ .test_proxy, .config, .start }) |node, label, a| {
            const role = self.buttonRole(a);
            const skin = S.buttonPaint(role);
            self.paintActionFill(node, skin, role != .disabled);
            setColor(label, skin.ink);
        }
        const icon = S.buttonPaint(.icon);
        self.paintActionFill(self.copy_button, icon, !self.test_disabled.peek());
        self.paintActionFill(self.logs_button, icon, true);
    }
    fn paintActionFill(self: *View, node: *ui.Node, skin: S.ButtonPaint, enabled: bool) void {
        const hover = enabled and if (self.cx.hovered_node) |hovered|
            hovered.isDescendantOf(node) and node.globalRect().contains(self.cx.mouse_x, self.cx.mouse_y)
        else
            false;
        const press = hover and if (self.cx.pressed_node) |pressed| pressed.isDescendantOf(node) else false;
        const color = if (press) skin.pressed else if (hover) skin.hover else skin.normal;
        if (!ui.Color.eql(color, node.getBackground())) {
            node.setBackgroundRaw(color);
            node.markRenderDirty();
        }
    }
    fn buttonRole(self: *const View, a: Action) S.ButtonRole {
        return switch (a) {
            .test_proxy => if (self.test_disabled.peek()) .disabled else .secondary,
            .config => if (self.has_rule) .secondary else .primary,
            .start, .stop => switch (self.state) {
                .running, .paused, .connecting => .destructive,
                .stopping => .disabled,
                .off, .failed => .primary,
            },
            .copy_export, .logs => .icon,
            else => .secondary,
        };
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
        if (self.connections_tip.open) |open| open.set(false);
        self.logs_visible = false;
        self.logs_open.set(false);
        self.logs_root.setDisplay(.none);
        self.open.set(false);
        self.root.setDisplay(.none);
        self.dock_target = null;
        self.cx.requestRedraw();
    }
    /// Public for layout tests and host resize integration.
    pub fn updateGeometry(self: *View) bool {
        if (self.dock_to_rail) return self.updateDockGeometry();
        if (self.logs_visible) {
            const upper = availableHeight(self);
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
        const upper = availableHeight(self);
        const available = @max(@as(f32, 1), @min(self.cx.viewport.height - 16, upper - 14));
        const width = @max(@as(f32, 1), @min(S.width, self.cx.viewport.width - 16));
        // Hug the measured content; only a viewport-constrained body scrolls.
        // The popover remains anchored to the same bottom-bar trigger.
        const natural = @max(@as(f32, 1), self.body.content.globalRect().h);
        const chrome_height = S.chrome_height;
        const body_h = @min(natural, @max(@as(f32, 1), available - chrome_height));
        const card_h = body_h + chrome_height;
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

    fn updateDockGeometry(self: *View) bool {
        const logs = self.logs_visible;
        if (!logs and self.root.style.display == .none) return false;
        if (self.anchor_node) |node| if (!node.isDisplayedInTree()) {
            self.hide();
            return true;
        };
        const raw = anchorRect(self);
        const trigger: ui.ComputedRect = .{ .x = raw.x, .y = raw.y, .w = raw.w, .h = raw.h };
        const footprint = if (self.mascot) |mascot| mascot.toolFootprint() orelse {
            self.hide();
            return true;
        } else mascot_island.ToolFootprint{ .bounds = trigger, .horizontal = false };
        const cx = self.cx;
        const workspace = if (self.mascot) |mascot| mascot.root.globalRect() else ui.ComputedRect{ .x = 0, .y = 0, .w = cx.viewport.width, .h = cx.viewport.height };
        const x = @max(cx.safe_area_left, workspace.x);
        const y = @max(cx.safe_area_top, workspace.y);
        const bounds: ui.ComputedRect = .{
            .x = x,
            .y = y,
            .w = @max(0, @min(cx.viewport.width - cx.safe_area_right, workspace.x + workspace.w) - x),
            .h = @max(0, @min(cx.viewport.height - cx.safe_area_bottom, workspace.y + workspace.h) - y),
        };
        const measured = self.body.content.globalRect().h;
        const height_budget = if (logs) S.logs_height else S.normal_height;
        const natural_h = if (logs or measured <= 0) height_budget else S.chrome_height + measured;
        const target = dockRect(bounds, footprint, trigger, if (logs) S.logs_width else S.width, height_budget, natural_h) orelse {
            // Too little room to offer a legible panel. Do not cover the tool
            // strip or place invisible controls over it; leave the strip usable.
            self.hide();
            return true;
        };
        const same_position = if (self.dock_target) |old| std.meta.eql(old, target) else false;
        self.dock_target = target;
        if (!same_position) self.cx.requestRedraw();
        const panel = if (logs) self.logs_root else self.root;
        var changed = sizeNode(self.cx, panel, target.w, target.h);
        if (!logs) changed = sizeNode(self.cx, self.body.container, null, @max(1, target.h - S.chrome_height)) or changed;
        // Zenit applies virtual-anchor placement in its before-render phase,
        // ahead of this frame's final rail layout. Publish this same requested
        // origin now so a drag or resize cannot paint even one stale frame
        // over a newly moved rail. Keep the virtual anchor for its lifecycle.
        if (panel.parent) |parent| {
            const base = parent.globalRect();
            const tx = target.x - base.x;
            const ty = target.y - base.y;
            if (@abs(panel.style.translate_x - tx) > 0.01 or @abs(panel.style.translate_y - ty) > 0.01) {
                panel.style.translate_x = tx;
                panel.style.translate_y = ty;
                panel.markCompositePropDirty();
            }
        }
        return changed;
    }

    fn sizeNode(cx: *ui.Cx, node: *ui.Node, width: ?f32, height: f32) bool {
        const same_w = if (width) |w| node.style.width == .px and @abs(node.style.width.px - w) <= 0.01 else true;
        const same_h = node.style.height == .px and @abs(node.style.height.px - height) <= 0.01;
        if (same_w and same_h) return false;
        node.setStyleInline(cx.allocator, .{ .width = if (width) |w| .{ .px = w } else null, .height = .{ .px = height } });
        return true;
    }
    fn availableHeight(self: *View) f32 {
        const rect = anchorRect(self);
        return if (rect.y < self.cx.viewport.height / 2) self.cx.viewport.height - rect.y - rect.h else rect.y;
    }
    fn anchorRect(raw: *anyopaque) ui.widgets.popover.AnchorRect {
        const self: *View = @ptrCast(@alignCast(raw));
        const rect = if (self.anchor_node) |node| node.globalRect() else self.anchor orelse ui.ComputedRect{ .x = 8, .y = self.cx.viewport.height - 32, .w = 0, .h = 0 };
        return .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
    }
    /// Keep Zenit's popup lifecycle, focus, clipping and escaping. A zero-
    /// area virtual anchor supplies a pre-validated top-left origin; flip
    /// and main-axis shift are explicitly off in workspace mode.
    fn dockAnchor(raw: *anyopaque) ui.widgets.popover.AnchorRect {
        const self: *View = @ptrCast(@alignCast(raw));
        const r = self.dock_target orelse return .{ .x = -1.0e6, .y = -1.0e6, .w = 0, .h = 0 };
        return .{ .x = r.x, .y = r.y, .w = 0, .h = 0 };
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
        if (!self.current_available) return;
        if (self.read_only and requested != .copy_export and requested != .logs and requested != .logs_back) return;
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
        const action = if (requested == .start or requested == .stop) (if (self.state == .running or self.state == .paused or self.state == .connecting) Action.stop else Action.start) else requested;
        if ((action == .test_proxy or action == .copy_export) and self.test_disabled.peek()) return;
        if ((action == .start or action == .stop) and self.state == .stopping) return;
        self.hooks.action(self.hooks.context, action);
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        self.retheme();
        if (self.open.peek()) self.paintActions();
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
        if (ui.Color.eql(value.color, color)) return;
        var next = value;
        next.color = color;
        node.setText(next);
    }
}
fn button(self: *View, parent: *ui.Node, label: []const u8, action: Action) !*ui.Node {
    const icon_only = action == .copy_export or action == .logs;
    const click = try self.cx.allocator.create(Click);
    click.* = .{ .view = self, .action = action };
    try self.scope.onCleanup(Click, click, Click.cleanup);
    const disabled = if (action == .test_proxy or action == .copy_export) self.test_disabled else if (action == .start) self.control_disabled else null;
    const skin = S.buttonPaint(self.buttonRole(action));
    const focus: ui.FocusRingConfig = if (icon_only) .{} else .{ .color = S.theme.current().accent_ink, .offset = -2 };
    const node = try ui.widgets.Button(.{
        .base_style = buttonStyle(action, skin.normal),
        .variant = .ghost,
        .icon_only = icon_only,
        .hover_style = @as(?ButtonStyle, .{ .background = if (icon_only) skin.hover else skin.normal }),
        .pressed_style = @as(?ButtonStyle, .{ .background = if (icon_only) skin.pressed else skin.normal }),
        .a11y_label = label,
        // Opt into a keyboard-only focus outline from mount. A transparent
        // default ring is actually a filled focus surface in Zenit, which
        // would promote a secondary control to its theme accent on focus.
        .focus_ring = focus,
        .disabled = if (disabled) |signal| ui.Source(bool){ .signal = signal } else ui.Source(bool){ .value = false },
        .on_click = self.cx.on(Click, click, Click.invoke),
    }).mount(self.scope, self.cx);
    if (icon_only) {
        try node.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.get(if (action == .copy_export) "copy" else "file-text").?, S.theme.current().fg_2, S.icon(16)));
    } else {
        // Theme recipe uses opacity 0.5 for an unspecified disabled ghost.
        // This family already supplies an opaque, quiet disabled color pair.
        node.setStyleInline(self.cx.allocator, .{ .opacity = 1, .flex_shrink = 0 });
        const copy = try text(self, label, 13, 500, .secondary, false);
        if (action == .start) self.control_text = copy;
        if (action == .config) self.config_text = copy;
        if (action == .test_proxy) self.test_text = copy;
        try node.appendChild(self.cx.allocator, copy);
    }
    if (action == .copy_export) self.copy_feedback = try @import("copy_button.zig").Button.attach(self.cx, self.scope, node);
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

fn buttonStyle(action: Action, background: ui.Color) ButtonStyle {
    const icon_only = action == .copy_export or action == .logs;
    return .{
        .width = .{ .px = switch (action) {
            .copy_export, .logs => 28,
            .logs_back, .test_proxy, .config => 60,
            else => 80,
        } },
        .height = .{ .px = if (icon_only) 28 else S.button_height },
        .background = background,
        .corner_radius = S.button_radius,
        .border_width = 0,
        .padding = if (icon_only) .{} else .{ .left = 8, .right = 8 },
        .gap = 0,
        .flex_shrink = 0,
        .align_items = .center,
        .justify = .center,
    };
}
