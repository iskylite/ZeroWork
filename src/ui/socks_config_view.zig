//! Captured-owner SOCKS configuration using the inspected V2 panel roles.
const std = @import("std");
const ui = @import("ui");
const S = @import("socks_config_styles.zig");

pub const Draft = struct {
    port: u16 = 1080,
    bind: []const u8 = "127.0.0.1",
    exit: ?usize = null,
    auto_start: bool = false,
    max_connections: u16 = 64,
    persist: bool = true,
    pub fn copy(self: Draft, allocator: std.mem.Allocator) !Draft {
        return .{ .port = self.port, .bind = try allocator.dupe(u8, self.bind), .exit = self.exit, .auto_start = self.auto_start, .max_connections = self.max_connections, .persist = self.persist };
    }
    pub fn deinit(self: *Draft, allocator: std.mem.Allocator) void {
        allocator.free(self.bind);
        self.* = undefined;
    }
};
pub const Hooks = struct { context: *anyopaque, save: *const fn (*anyopaque, Draft) void, test_cb: *const fn (*anyopaque, Draft) void, cancel: *const fn (*anyopaque) void, confirm_exposure: *const fn (*anyopaque, []const u8) bool };
pub const Route = struct { label: []const u8, index: ?usize = null };

pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    hooks: Hooks,
    root: *ui.Node,
    card: *ui.Node,
    port: *ui.Node,
    bind: *ui.Node,
    exit: *ui.Node,
    max: *ui.Node,
    auto: *ui.Node,
    persist: *ui.Node,
    error_label: *ui.Node,
    draft: Draft = .{},
    routes: []const Route = &.{},
    visible: bool = false,
    pending_action: Action = .save,
    focus_pending: bool = false,
    owned: ?std.heap.ArenaAllocator = null,
    port_signal: *ui.Signal([]const u8) = undefined,
    bind_signal: *ui.Signal([]const u8) = undefined,
    max_signal: *ui.Signal([]const u8) = undefined,
    scrolling: ui.widgets.ScrollAreaResult = undefined,
    content: *ui.Node = undefined,
    title: *ui.Node = undefined,
    route_menu: *ui.Node = undefined,
    owner_label: *ui.Node = undefined,
    footer: *ui.Node = undefined,
    input_parts: [3]ui.widgets.input.InputResult = undefined,
    picker: ui.widgets.SelectResult = undefined,
    route_options: *ui.Signal([]const ui.widgets.SelectOption) = undefined,
    route_value: *ui.Signal(?[]const u8) = undefined,
    auto_value: *ui.Signal(bool) = undefined,
    persist_value: *ui.Signal(bool) = undefined,
    paint_version: u32 = 0,
    colors: S.theme.Colors = undefined,
    feedback_success: bool = false,
    picker_scope: ?*ui.Scope = null,
    material: ?*@import("background_layers.zig").View = null,
    picker_parent: *ui.Node = undefined,
    button_paints: [4]struct { style: *ui.Signal(ui.BoxStyle), primary: bool, width: f32 } = undefined,
    button_count: usize = 0,
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, hooks: Hooks) !*View {
        const self = try cx.allocator.create(View);
        self.* = .{ .cx = cx, .scope = scope, .hooks = hooks, .root = undefined, .card = undefined, .port = undefined, .bind = undefined, .exit = undefined, .max = undefined, .auto = undefined, .persist = undefined, .error_label = undefined };
        try scope.onCleanup(View, self, cleanup);
        self.port_signal = try scope.createText("1080", .{});
        self.bind_signal = try scope.createText("127.0.0.1", .{});
        self.max_signal = try scope.createText("64", .{});
        self.auto_value = try scope.createSignal(bool, false);
        self.persist_value = try scope.createSignal(bool, true);
        self.route_options = try scope.createList(ui.widgets.SelectOption, &.{});
        self.route_value = try scope.createSignal(?[]const u8, null);
        self.root = try ui.box(cx, S.overlay(), .{});
        self.card = try ui.box(cx, S.panel(), .{});
        self.root.meta.ownership.meta.test_id = "socks.config";
        self.card.meta.ownership.meta.test_id = "socks.config.card";
        try self.root.appendChild(cx.allocator, self.card);
        const header = try ui.box(cx, S.row(30), .{});
        try self.card.appendChild(cx.allocator, header);
        try header.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.settings_2, S.theme.current().accent, .{ .width = .{ .px = 18 }, .height = .{ .px = 18 }, .flex_shrink = 0 }));
        self.title = try ui.text(cx, "SOCKS5 配置", S.text(13, 700, false));
        try header.appendChild(cx.allocator, self.title);
        try header.appendChild(cx.allocator, try ui.spacer(cx));
        _ = try button(self, header, "×", .cancel, "socks.config.close", 26);
        self.scrolling = try ui.widgets.ScrollArea(.{ .direction = .vertical }).mount(scope, cx);
        self.scrolling.container.style.width = .fill();
        self.scrolling.container.style.height = .{ .fit = .{} };
        self.scrolling.container.style.flex_shrink = 0;
        self.content = self.scrolling.content;
        self.content.setStyleInline(cx.allocator, S.column());
        try self.card.appendChild(cx.allocator, self.scrolling.container);
        self.owner_label = try ui.text(cx, "", S.text(11, 400, false));
        self.owner_label.style.height = .{ .px = 26 };
        self.owner_label.meta.ownership.meta.test_id = "socks.config.owner";
        self.owner_label.setDisplay(.none);
        try self.content.appendChild(cx.allocator, self.owner_label);
        const endpoints = try ui.box(cx, S.row(52), .{});
        try self.content.appendChild(cx.allocator, endpoints);
        self.port = try field(self, endpoints, "本地端口", self.port_signal, 0);
        self.port.parent.?.style.width = .{ .px = 126 };
        self.bind = try field(self, endpoints, "绑定地址", self.bind_signal, 1);
        self.bind.parent.?.style.width = .{ .grow = .{ .min = 0 } };
        const exit_field = try ui.box(cx, S.field(), .{});
        try exit_field.appendChild(cx.allocator, try ui.text(cx, "出口节点", S.text(10.5, 400, true)));
        self.picker_scope = try scope.childScope();
        self.picker_parent = exit_field;
        self.picker = try self.mountPicker(self.picker_scope.?);
        self.exit = self.picker.trigger;
        self.exit.meta.ownership.meta.test_id = "socks.config.exit";
        self.route_menu = self.picker.panel;
        self.picker.wrapper.style.width = .fill();
        try exit_field.appendChild(cx.allocator, self.picker.wrapper);
        try self.content.appendChild(cx.allocator, exit_field);
        self.auto = try toggleRow(self, "自动开启", self.auto_value, false);
        self.max = try field(self, self.content, "并发上限", self.max_signal, 2);
        self.persist = try toggleRow(self, "保存到主机配置", self.persist_value, true);
        self.error_label = try ui.text(cx, "", S.text(10.5, 400, true));
        self.error_label.meta.ownership.meta.test_id = "socks.config.error";
        self.port.meta.ownership.meta.test_id = "socks.config.port";
        self.bind.meta.ownership.meta.test_id = "socks.config.bind";
        self.max.meta.ownership.meta.test_id = "socks.config.max";
        self.auto.meta.ownership.meta.test_id = "socks.config.auto";
        self.persist.meta.ownership.meta.test_id = "socks.config.persist";
        self.error_label.setDisplay(.none);
        try self.content.appendChild(cx.allocator, self.error_label);
        self.footer = try ui.box(cx, S.row(30), .{});
        // Testing stays available as an actual action; prototype annotations
        // about transport implementation are not shipped as field hints.
        _ = try button(self, self.footer, "测试代理", .test_proxy, "socks.config.test", 88);
        try self.footer.appendChild(cx.allocator, try ui.spacer(cx));
        _ = try button(self, self.footer, "取消", .cancel, "socks.config.cancel", 88);
        _ = try button(self, self.footer, "应用配置", .save, "socks.config.save", 120);
        try self.card.appendChild(cx.allocator, self.footer);
        self.colors = S.theme.current();
        self.paint_version = cx.theme_version;
        self.retheme();
        try cx.addAfterLayoutHook(self, geometryHook);
        return self;
    }
    /// draft and route strings are deep copied; hooks borrow the current draft only during callback.
    pub fn show(self: *View, draft: Draft, routes: []const Route) !void {
        if (self.owned) |*old| old.deinit();
        self.owned = std.heap.ArenaAllocator.init(self.cx.allocator);
        const a = self.owned.?.allocator();
        self.draft = draft;
        self.draft.bind = try a.dupe(u8, draft.bind);
        const copies = try a.alloc(Route, routes.len);
        for (routes, 0..) |r, i| copies[i] = .{ .label = try a.dupe(u8, r.label), .index = r.index };
        self.routes = copies;
        const options = try a.alloc(ui.widgets.SelectOption, routes.len);
        for (copies, 0..) |r, i| options[i] = .{ .label = r.label, .value = routeId(i), .test_id = routeTestId(i) };
        self.route_options.set(options);
        var buffer: [16]u8 = undefined;
        self.port_signal.set(try std.fmt.bufPrint(&buffer, "{d}", .{draft.port}));
        self.bind_signal.set(draft.bind);
        self.max_signal.set(try std.fmt.bufPrint(&buffer, "{d}", .{draft.max_connections}));
        self.refreshToggles();
        self.setError("");
        if (self.picker.open) |open| open.set(false);
        self.focus_pending = true;
        self.visible = true;
        self.root.setDisplay(.flex);
        self.cx.requestRedraw();
    }
    pub fn setOwner(self: *View, name: []const u8, session_id: u64) void {
        const value = std.fmt.allocPrint(self.cx.allocator, "归属 {s} · 会话 #{d}", .{ name, session_id }) catch return;
        defer self.cx.allocator.free(value);
        self.owner_label.setTextContent(self.cx.allocator, value) catch {};
        self.owner_label.setDisplay(.flex);
    }
    fn refreshToggles(self: *View) void {
        self.auto_value.set(self.draft.auto_start);
        self.persist_value.set(self.draft.persist);
        var selected: ?[]const u8 = null;
        for (self.routes, 0..) |r, i| if (r.index == self.draft.exit) {
            selected = routeId(i);
            break;
        };
        self.route_value.set(selected);
    }
    fn autoChanged(self: *View, value: bool) void {
        self.draft.auto_start = value;
    }
    fn persistChanged(self: *View, value: bool) void {
        self.draft.persist = value;
    }
    fn routeChanged(self: *View, value: ?[]const u8) void {
        const id = value orelse return;
        const i = std.fmt.parseInt(usize, id, 10) catch return;
        self.selectRoute(i);
    }
    pub fn selectRoute(self: *View, i: usize) void {
        if (i >= self.routes.len) return;
        self.draft.exit = self.routes[i].index;
        if (self.picker.open) |open| open.set(false);
        self.refreshToggles();
    }
    fn mountPicker(self: *View, scope: *ui.Scope) !ui.widgets.SelectResult {
        const result = try ui.widgets.Select(.{ .options = self.route_options, .value = self.route_value, .width = 392, .size = .sm, .on_change = self.cx.on(View, self, routeChanged) }).mount(scope, self.cx);
        result.chrome.setBackground(S.theme.current().overlay);
        if (self.material) |material| try material.isolate(result.scope, result.chrome);
        return result;
    }
    pub fn bindMaterial(self: *View, material: *@import("background_layers.zig").View) !void {
        try material.isolate(self.picker.scope, self.picker.chrome);
        self.material = material;
    }
    // Select caches its palette at mount. Recreate only that control after
    // publication at the layout safe point; all editor/input state survives.
    fn refreshPickerTheme(self: *View) !void {
        const scope = try self.scope.childScope();
        errdefer scope.dispose();
        const fresh = try self.mountPicker(scope);
        self.cx.invalidateReferencesTo(self.picker.wrapper);
        if (self.picker_scope) |old| old.dispose();
        self.cx.detachChild(self.picker_parent, self.picker.wrapper);
        self.cx.destroyDetached(self.picker.wrapper);
        self.picker = fresh;
        self.picker_scope = scope;
        self.exit = fresh.trigger;
        self.exit.meta.ownership.meta.test_id = "socks.config.exit";
        self.route_menu = fresh.panel;
        fresh.wrapper.style.width = .fill();
        try self.picker_parent.appendChild(self.cx.allocator, fresh.wrapper);
    }
    pub fn retheme(self: *View) void {
        if (self.paint_version != self.cx.theme_version or !std.meta.eql(self.colors, S.theme.current())) self.refreshPickerTheme() catch {};
        S.repaint(self.card, self.colors);
        self.colors = S.theme.current();
        self.card.setBackground(self.colors.overlay);
        for (self.button_paints[0..self.button_count]) |paint| paint.style.set(S.action(paint.primary, paint.width));
        for (&self.input_parts) |*input| {
            input.input_container.setStyleInline(self.cx.allocator, S.input());
            input.state.tokens = self.cx.tokens;
            input.state.dirty = true;
        }
        self.exit.setStyleInline(self.cx.allocator, S.input());
        // The stable chrome/surface owns the tint once. Options must reveal
        // that image plane, rather than tinting the material a second time.
        self.picker.panel.setBackground(ui.Color.TRANSPARENT);
        self.picker.chrome.setBackground(self.colors.overlay);
        self.error_label.setTextColor(if (self.feedback_success) self.colors.ok_ink else self.colors.danger_ink);
        self.paint_version = self.cx.theme_version;
        self.cx.requestRedraw();
    }
    pub fn updateGeometry(self: *View) bool {
        if (!self.visible) return false;
        if (self.paint_version != self.cx.theme_version or !std.meta.eql(self.colors, S.theme.current())) self.retheme();
        const bounds = if (self.root.parent) |parent| parent.globalRect() else ui.ComputedRect{ .x = 0, .y = 0, .w = self.cx.viewport.width, .h = self.cx.viewport.height };
        const width = @max(@as(f32, 1), @min(S.width, bounds.w - 32));
        const body_h = @max(@as(f32, 1), @min(S.panel_height - S.chrome_height, bounds.h - 32 - S.chrome_height));
        var changed = false;
        if (self.card.style.width != .px or @abs(self.card.style.width.px - width) > 0.5) {
            self.card.style.width = .{ .px = width };
            changed = true;
        }
        if (self.scrolling.container.style.height != .px or @abs(self.scrolling.container.style.height.px - body_h) > 0.5) {
            self.scrolling.container.style.height = .{ .px = body_h };
            changed = true;
        }
        if (changed) {
            self.card.markLayoutDirty();
            return true;
        }
        if (self.focus_pending) {
            self.cx.setFocus(self.input_parts[0].input_container);
            self.focus_pending = false;
        }
        return false;
    }
    fn geometryHook(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const v: *View = @ptrCast(@alignCast(raw));
        return if (v.updateGeometry()) .needs_layout else .done;
    }
    fn submit(self: *View, _: []const u8) void {
        self.act(.save);
    }
    pub fn hide(self: *View) void {
        if (self.picker.open) |open| open.set(false);
        self.visible = false;
        self.root.setDisplay(.none);
        self.cx.requestRedraw();
    }
    pub fn setError(self: *View, message: []const u8) void {
        self.feedback_success = false;
        self.setFeedback(message, S.theme.current().danger_ink);
    }

    /// Show a completed proxy test using the success treatment.  Test output
    /// is feedback, not validation failure, so it must not use the red error
    /// style even though both occupy the same compact row in the mockup.
    pub fn setSuccess(self: *View, message: []const u8) void {
        self.feedback_success = true;
        self.setFeedback(message, S.theme.current().ok_ink);
    }

    fn setFeedback(self: *View, message: []const u8, color: ui.Color) void {
        self.error_label.setTextContent(self.cx.allocator, message) catch {};
        if (self.error_label.getText()) |value| {
            var next = value;
            next.color = color;
            self.error_label.setText(next);
        }
        self.error_label.setDisplay(if (message.len == 0) .none else .flex);
    }
    pub fn act(self: *View, action: Action) void {
        self.pending_action = action;
        if (action == .cancel) {
            self.hide();
            self.hooks.cancel(self.hooks.context);
            return;
        }
        self.draft.port = std.fmt.parseInt(u16, self.port_signal.get(), 10) catch {
            self.setError("端口必须为 1–65535");
            return;
        };
        self.draft.max_connections = std.fmt.parseInt(u16, self.max_signal.get(), 10) catch {
            self.setError("并发上限必须为正整数");
            return;
        };
        self.draft.bind = self.bind_signal.get();
        if (!std.mem.eql(u8, self.draft.bind, "127.0.0.1") and !std.mem.eql(u8, self.draft.bind, "0.0.0.0")) {
            self.setError("绑定地址仅支持 127.0.0.1 或 0.0.0.0");
            return;
        }
        if (self.draft.exit != null) {
            var found = false;
            for (self.routes) |r| if (r.index == self.draft.exit) {
                found = true;
                break;
            };
            if (!found) {
                self.setError("请选择已认证的出口节点");
                return;
            }
        }
        const d = self.draft;
        if (action == .save or action == .test_proxy) {
            if (self.draft.bind.len == 0 or self.draft.port == 0 or self.draft.max_connections == 0) {
                self.setError("端口、绑定地址和并发上限不能为空");
                return;
            }
            if (std.mem.eql(u8, self.draft.bind, "0.0.0.0") and !self.hooks.confirm_exposure(self.hooks.context, self.draft.bind)) return;
            if (action == .save) self.hooks.save(self.hooks.context, d) else self.hooks.test_cb(self.hooks.context, d);
        }
    }
    pub const Action = enum { save, test_proxy, cancel };
    fn cleanup(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
        if (self.owned) |*owned| owned.deinit();
        self.cx.allocator.destroy(self);
    }
};
fn field(self: *View, parent: *ui.Node, label: []const u8, value: *ui.Signal([]const u8), index: usize) !*ui.Node {
    const column = try ui.box(self.cx, S.field(), .{});
    try parent.appendChild(self.cx.allocator, column);
    try column.appendChild(self.cx.allocator, try ui.text(self.cx, label, S.text(10.5, 400, true)));
    const input = try ui.widgets.Input(.{ .value = value, .on_submit = self.cx.on(View, self, View.submit) }).mountResult(self.scope, self.cx);
    input.node.style.width = .fill();
    input.state.font_size = 11.5;
    input.state.line_height = 17;
    input.state.dirty = true;
    input.input_container.setStyleInline(self.cx.allocator, S.input());
    self.input_parts[index] = input;
    try column.appendChild(self.cx.allocator, input.node);
    return input.node;
}
fn toggleRow(self: *View, label: []const u8, value: *ui.Signal(bool), persist: bool) !*ui.Node {
    const row = try ui.box(self.cx, S.row(26), .{});
    try row.appendChild(self.cx.allocator, try ui.text(self.cx, label, S.text(11, 400, false)));
    try row.appendChild(self.cx.allocator, try ui.spacer(self.cx));
    const toggle = try ui.widgets.Switch(.{ .checked = value, .on_change = if (persist) self.cx.on(View, self, View.persistChanged) else self.cx.on(View, self, View.autoChanged) }).mount(self.scope, self.cx);
    try row.appendChild(self.cx.allocator, toggle);
    try self.content.appendChild(self.cx.allocator, row);
    return toggle;
}
fn button(self: *View, parent: *ui.Node, label: []const u8, action: View.Action, id: []const u8, width: f32) !*ui.Node {
    const click = try self.scope.createState(Click, .{ .view = self, .action = action });
    const paint = try self.scope.createSignal(ui.BoxStyle, S.action(action == .save, width));
    self.button_paints[self.button_count] = .{ .style = paint, .primary = action == .save, .width = width };
    self.button_count += 1;
    const node = try ui.widgets.Button(.{ .label = label, .variant = @as(ui.widgets.button.ButtonVariant, if (action == .save) .primary else .secondary), .base_style = paint, .on_click = self.cx.on(Click, click, Click.run) }).mount(self.scope, self.cx);
    node.meta.ownership.meta.test_id = id;
    node.setStyleInline(self.cx.allocator, S.action(action == .save, width));
    try parent.appendChild(self.cx.allocator, node);
    return node;
}
const Click = struct {
    view: *View,
    action: View.Action,
    fn run(self: *Click) void {
        self.view.act(self.action);
    }
};
fn routeId(index: usize) []const u8 {
    return switch (index) {
        0 => "0",
        1 => "1",
        2 => "2",
        3 => "3",
        4 => "4",
        5 => "5",
        6 => "6",
        7 => "7",
        else => "8",
    };
}
fn routeTestId(index: usize) []const u8 {
    return switch (index) {
        0 => "socks.config.route.0",
        1 => "socks.config.route.1",
        2 => "socks.config.route.2",
        3 => "socks.config.route.3",
        4 => "socks.config.route.4",
        5 => "socks.config.route.5",
        6 => "socks.config.route.6",
        7 => "socks.config.route.7",
        else => "socks.config.route.8",
    };
}
