//! Captured-owner SOCKS configuration using the inspected V2 panel roles.
const std = @import("std");
const ui = @import("ui");
const S = @import("socks_config_styles.zig");
const forwarding = @import("../proto/ssh/socks5_listener.zig");

pub const Draft = struct {
    mode: forwarding.ForwardMode = .socks5,
    target_host: []const u8 = "127.0.0.1",
    target_port: u16 = 8080,
    port: u16 = 1080,
    bind: []const u8 = "127.0.0.1",
    exit: ?usize = null,
    auto_start: bool = false,
    max_connections: u16 = 64,
    persist: bool = true,
    pub fn copy(self: Draft, allocator: std.mem.Allocator) !Draft {
        return .{ .mode = self.mode, .target_host = try allocator.dupe(u8, self.target_host), .target_port = self.target_port, .port = self.port, .bind = try allocator.dupe(u8, self.bind), .exit = self.exit, .auto_start = self.auto_start, .max_connections = self.max_connections, .persist = self.persist };
    }
    pub fn deinit(self: *Draft, allocator: std.mem.Allocator) void {
        allocator.free(self.bind);
        allocator.free(self.target_host);
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
    frame: *ui.Node = undefined,
    modal_open: *ui.Signal(bool) = undefined,
    portaled: bool = false,
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
    input_parts: [5]ui.widgets.input.InputResult = undefined,
    picker: ui.widgets.SelectResult = undefined,
    route_options: *ui.Signal([]const ui.widgets.SelectOption) = undefined,
    route_value: *ui.Signal(?[]const u8) = undefined,
    auto_value: *ui.Signal(bool) = undefined,
    persist_value: *ui.Signal(bool) = undefined,
    target_host_signal: *ui.Signal([]const u8) = undefined,
    target_port_signal: *ui.Signal([]const u8) = undefined,
    target_group: *ui.Node = undefined,
    listen_label: *ui.Node = undefined,
    mode_buttons: [3]*ui.Node = undefined,
    mode_highlights: [3]*ui.Node = undefined,
    auto_row: *ui.Node = undefined,
    persist_row: *ui.Node = undefined,
    mode_hint: *ui.Node = undefined,
    paint_version: u32 = 0,
    colors: S.theme.Colors = undefined,
    feedback_success: bool = false,
    picker_scope: ?*ui.Scope = null,
    material: ?*@import("background_layers.zig").View = null,
    picker_parent: *ui.Node = undefined,
    button_paints: [7]struct { style: *ui.Signal(ui.BoxStyle), primary: bool, width: f32, mode: ?forwarding.ForwardMode } = undefined,
    button_count: usize = 0,
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, hooks: Hooks) !*View {
        const self = try cx.allocator.create(View);
        self.* = .{ .cx = cx, .scope = scope, .hooks = hooks, .root = undefined, .card = undefined, .port = undefined, .bind = undefined, .exit = undefined, .max = undefined, .auto = undefined, .persist = undefined, .error_label = undefined };
        try scope.onCleanup(View, self, cleanup);
        self.port_signal = try scope.createText("1080", .{});
        self.bind_signal = try scope.createText("127.0.0.1", .{});
        self.max_signal = try scope.createText("64", .{});
        self.target_host_signal = try scope.createText("127.0.0.1", .{});
        self.target_port_signal = try scope.createText("8080", .{});
        self.auto_value = try scope.createSignal(bool, false);
        self.persist_value = try scope.createSignal(bool, true);
        self.route_options = try scope.createList(ui.widgets.SelectOption, &.{});
        self.route_value = try scope.createSignal(?[]const u8, null);
        self.modal_open = try scope.createSignal(bool, false);
        const modal = try ui.widgets.Modal(.{ .open = self.modal_open, .width = S.width, .max_height = S.panel_height, .background = S.theme.current().overlay, .close_on_overlay = false, .enter_transition = .none, .exit_transition = .none, .on_open_change = cx.on(View, self, modalChanged) }).mount(scope, cx);
        self.root = modal.overlay;
        self.root.setDisplay(.none);
        self.card = modal.dialog;
        self.frame = modal.body;
        self.portaled = modal.portaled;
        self.card.setStyleInline(cx.allocator, S.panel());
        self.frame.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .fill(), .min_height = 0, .direction = .column, .gap = 12, .flex_shrink = 0 });
        self.frame.setStyleInline(cx.allocator, .{ .padding = .{ .left = S.inset, .right = S.inset, .top = 18, .bottom = 18 } });
        self.root.meta.ownership.meta.test_id = "socks.config";
        self.card.meta.ownership.meta.test_id = "socks.config.card";
        const header = try ui.box(cx, S.row(30), .{});
        try self.frame.appendChild(cx.allocator, header);
        try header.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.settings_2, S.theme.current().accent, .{ .width = .{ .px = 18 }, .height = .{ .px = 18 }, .flex_shrink = 0 }));
        self.title = try ui.text(cx, "端口转发配置", .{ .font_size = 16, .font_weight = 600, .line_height = 1.5, .color = S.theme.current().fg_1 });
        try header.appendChild(cx.allocator, self.title);
        try header.appendChild(cx.allocator, try ui.spacer(cx));
        _ = try button(self, header, "×", .cancel, "socks.config.close", 26);
        self.scrolling = try ui.widgets.ScrollArea(.{ .direction = .vertical }).mount(scope, cx);
        self.scrolling.container.style.width = .fill();
        self.scrolling.container.style.height = .{ .fit = .{} };
        self.scrolling.container.style.flex_shrink = 0;
        self.content = self.scrolling.content;
        self.content.setStyleInline(cx.allocator, S.column());
        try self.frame.appendChild(cx.allocator, self.scrolling.container);
        self.owner_label = try ui.text(cx, "", S.text(11, 400, false));
        self.owner_label.style.height = .{ .px = 26 };
        self.owner_label.meta.ownership.meta.test_id = "socks.config.owner";
        self.owner_label.setDisplay(.none);
        try self.content.appendChild(cx.allocator, self.owner_label);
        const modes = try ui.box(cx, S.row(54), .{});
        modes.setStyleInline(cx.allocator, .{ .gap = 8 });
        try self.content.appendChild(cx.allocator, modes);
        self.mode_buttons[1] = try modeCard(self, modes, "本地 L", "本机监听", .mode_local, "forward.mode.local");
        self.mode_buttons[2] = try modeCard(self, modes, "远端 R", "SSH 端监听", .mode_remote, "forward.mode.remote");
        self.mode_buttons[0] = try modeCard(self, modes, "SOCKS5", "动态目标", .mode_socks5, "forward.mode.socks5");
        self.mode_hint = try ui.text(cx, "", S.text(10.5, 400, true));
        self.mode_hint.style.height = .{ .px = 32 };
        if (self.mode_hint.getText()) |old| {
            var style = old;
            style.wrap = .word;
            self.mode_hint.setText(style);
        }
        try self.content.appendChild(cx.allocator, self.mode_hint);
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
        self.target_group = try ui.box(cx, S.row(52), .{});
        try self.content.appendChild(cx.allocator, self.target_group);
        const target_host = try field(self, self.target_group, "目标地址", self.target_host_signal, 3);
        target_host.meta.ownership.meta.test_id = "forward.target.host";
        const target_port = try field(self, self.target_group, "目标端口", self.target_port_signal, 4);
        target_port.parent.?.style.width = .{ .px = 100 };
        target_port.meta.ownership.meta.test_id = "forward.target.port";
        self.auto = try toggleRow(self, "自动开启", self.auto_value, false);
        self.auto_row = self.auto.parent.?;
        self.max = try field(self, self.content, "并发上限", self.max_signal, 2);
        self.persist = try toggleRow(self, "保存到主机配置", self.persist_value, true);
        self.persist_row = self.persist.parent.?;
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
        try self.frame.appendChild(cx.allocator, self.footer);
        self.colors = S.theme.current();
        self.paint_version = cx.theme_version;
        self.retheme();
        try cx.addAfterLayoutHook(self, geometryHook);
        return self;
    }
    /// draft and route strings are deep copied; hooks borrow the current draft only during callback.
    pub fn show(self: *View, draft: Draft, routes: []const Route) !void {
        // Select option records shallow-copy their label slices and retain equal records.
        // Keep their backing strings until this retained view is disposed.
        if (self.owned == null) self.owned = std.heap.ArenaAllocator.init(self.cx.allocator);
        const a = self.owned.?.allocator();
        self.draft = draft;
        self.draft.bind = try a.dupe(u8, draft.bind);
        self.draft.target_host = try a.dupe(u8, draft.target_host);
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
        self.target_host_signal.set(draft.target_host);
        self.target_port_signal.set(try std.fmt.bufPrint(&buffer, "{d}", .{draft.target_port}));
        self.refreshMode();
        self.refreshToggles();
        self.setError("");
        if (self.picker.open) |open| open.set(false);
        ui.widgets.setScrollY(self.scrolling.state, self.scrolling.content, 0);
        self.focus_pending = true;
        self.visible = true;
        self.modal_open.set(true);
        self.root.setDisplay(.flex);
        self.cx.requestRedraw();
    }
    pub fn setOwner(self: *View, name: []const u8, session_id: u64) void {
        const value = std.fmt.allocPrint(self.cx.allocator, "归属 {s} · 会话 #{d}", .{ name, session_id }) catch return;
        defer self.cx.allocator.free(value);
        self.owner_label.setTextContent(self.cx.allocator, value) catch {};
        self.owner_label.setDisplay(.flex);
    }
    fn refreshMode(self: *View) void {
        const fixed = self.draft.mode != .socks5;
        self.target_group.setDisplay(if (fixed) .flex else .none);
        self.auto_row.setDisplay(if (fixed) .none else .flex);
        self.persist_row.setDisplay(if (fixed) .none else .flex);
        self.mode_hint.setTextContent(self.cx.allocator, switch (self.draft.mode) {
            .socks5 => "本机监听 · 动态目标 · 每会话一个活动转发",
            .local => "本机监听 → SSH端目标 · 仅当前会话",
            .remote => "SSH端监听 → 本机目标IP / localhost · 仅当前会话",
        }) catch {};
        self.listen_label.setTextContent(self.cx.allocator, if (self.draft.mode == .remote) "远端监听端口" else "本地监听端口") catch {};
        self.paintModes();
        self.cx.requestRedraw();
    }
    fn paintModes(self: *View) void {
        for (self.button_paints[0..self.button_count]) |paint| if (paint.mode != null) paint.style.set(S.modeCard(false));
        for (self.mode_buttons, 0..) |node, i| {
            const selected = i == @backingInt(self.draft.mode);
            self.mode_highlights[i].setBackground(S.theme.current().selection);
            self.mode_highlights[i].setDisplay(if (selected) .flex else .none);
            if (node.behavior.interaction.a11y) |*access| access.pressed = selected;
            tintMode(node, if (selected) S.theme.current().accent else S.theme.current().fg_1);
        }
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
        const result = try ui.widgets.Select(.{ .options = self.route_options, .value = self.route_value, .width = S.width - 2 * S.inset, .size = .sm, .on_change = self.cx.on(View, self, routeChanged) }).mount(scope, self.cx);
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
        for (self.button_paints[0..self.button_count]) |paint| paint.style.set(if (paint.mode != null) S.modeCard(false) else S.action(paint.primary, paint.width));
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
        self.paintModes();
        self.paint_version = self.cx.theme_version;
        self.cx.requestRedraw();
    }
    pub fn updateGeometry(self: *View) bool {
        if (!self.visible) return false;
        if (self.paint_version != self.cx.theme_version or !std.meta.eql(self.colors, S.theme.current())) self.retheme();
        const bounds: ui.ComputedRect = .{ .x = 0, .y = 0, .w = self.cx.viewport.width, .h = self.cx.viewport.height };
        const width = @max(@as(f32, 1), @min(S.width, bounds.w - 32));
        const natural = @max(@as(f32, 1), self.content.globalRect().h);
        const body_h = @max(@as(f32, 1), @min(natural, @min(S.panel_height - S.chrome_height, bounds.h - 32 - S.chrome_height)));
        var changed = false;
        if (self.frame.style.padding.left != S.inset or self.frame.style.padding.top != 18) {
            self.frame.setStyleInline(self.cx.allocator, .{ .padding = .{ .left = S.inset, .right = S.inset, .top = 18, .bottom = 18 } });
            changed = true;
        }
        const total = body_h + S.chrome_height;
        if (self.card.style.height != .px or @abs(self.card.style.height.px - total) > 0.5) {
            self.card.setStyleInline(self.cx.allocator, .{ .height = .{ .px = total } });
            changed = true;
        }
        if (self.card.style.width != .px or @abs(self.card.style.width.px - width) > 0.5) {
            self.card.setStyleInline(self.cx.allocator, .{ .width = .{ .px = width } });
            changed = true;
        }
        if (self.scrolling.container.style.height != .px or @abs(self.scrolling.container.style.height.px - body_h) > 0.5) {
            self.scrolling.container.setStyleInline(self.cx.allocator, .{ .height = .{ .px = body_h } });
            changed = true;
        }
        if (changed) {
            self.card.markLayoutDirty();
            self.cx.requestRedraw();
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
    fn modalChanged(self: *View, value: bool) void {
        if (!value and self.visible) self.act(.cancel);
    }
    pub fn hide(self: *View) void {
        if (self.picker.open) |open| open.set(false);
        self.visible = false;
        self.modal_open.set(false);
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
        if (action == .mode_socks5 or action == .mode_local or action == .mode_remote) {
            self.draft.mode = switch (action) {
                .mode_local => .local,
                .mode_remote => .remote,
                else => .socks5,
            };
            self.refreshMode();
            self.setError("");
            return;
        }
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
        if (self.draft.mode != .socks5) {
            self.draft.target_host = self.target_host_signal.get();
            self.draft.target_port = std.fmt.parseInt(u16, self.target_port_signal.get(), 10) catch {
                self.setError("目标端口必须为 1–65535");
                return;
            };
            const target = forwarding.Target.init(self.draft.target_host, self.draft.target_port) catch {
                self.setError("请输入目标地址及有效端口");
                return;
            };
            if (self.draft.mode == .remote and @import("generated_ssh_session").zw_ssh_forward_target_valid(target.name().ptr) == 0) {
                self.setError("远端转发的本机目标需填写IPv4、IPv6或localhost");
                return;
            }
            self.draft.persist = false;
            self.draft.auto_start = false;
        }
        const d = self.draft;
        if (action == .save or action == .test_proxy) {
            if (self.draft.bind.len == 0 or self.draft.port == 0 or self.draft.max_connections == 0) {
                self.setError("端口、绑定地址和并发上限不能为空");
                return;
            }
            self.setError("");
            if (std.mem.eql(u8, self.draft.bind, "0.0.0.0") and !self.hooks.confirm_exposure(self.hooks.context, self.draft.bind)) return;
            if (action == .save) self.hooks.save(self.hooks.context, d) else self.hooks.test_cb(self.hooks.context, d);
        }
    }
    pub const Action = enum { save, test_proxy, cancel, mode_socks5, mode_local, mode_remote };
    fn cleanup(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
        if (self.owned) |*owned| owned.deinit();
        self.cx.allocator.destroy(self);
    }
};
fn field(self: *View, parent: *ui.Node, label: []const u8, value: *ui.Signal([]const u8), index: usize) !*ui.Node {
    const column = try ui.box(self.cx, S.field(), .{});
    try parent.appendChild(self.cx.allocator, column);
    const label_node = try ui.text(self.cx, label, S.text(10.5, 400, true));
    if (index == 0) self.listen_label = label_node;
    try column.appendChild(self.cx.allocator, label_node);
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
    const mode: ?forwarding.ForwardMode = switch (action) {
        .mode_socks5 => .socks5,
        .mode_local => .local,
        .mode_remote => .remote,
        else => null,
    };
    if (mode != null) paint.set(S.modeCard(false));
    self.button_paints[self.button_count] = .{ .style = paint, .primary = action == .save, .width = width, .mode = mode };
    self.button_count += 1;
    const node = try ui.widgets.Button(.{ .label = if (mode != null) "" else label, .a11y_label = label, .block = mode != null, .variant = @as(ui.widgets.button.ButtonVariant, if (action == .save) .primary else .secondary), .base_style = paint, .on_click = self.cx.on(Click, click, Click.run) }).mount(self.scope, self.cx);
    node.meta.ownership.meta.test_id = id;
    if (mode == null) node.setStyleInline(self.cx.allocator, S.action(action == .save, width)) else node.setStyleInline(self.cx.allocator, .{ .flex = 1, .min_width = 0, .flex_shrink = 1 });
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

fn modeCard(self: *View, parent: *ui.Node, title: []const u8, detail: []const u8, action: View.Action, id: []const u8) !*ui.Node {
    const node = try button(self, parent, title, action, id, 140);
    const highlight = try ui.box(self.cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = 0 }, .right = .{ .px = 0 }, .top = .{ .px = 0 }, .bottom = .{ .px = 0 } }, .width = .fill(), .height = .fill(), .background = S.theme.current().selection, .border = .{ .radius = 9 }, .hit_behavior = .pass_through }, .{});
    try node.appendChild(self.cx.allocator, highlight);
    self.mode_highlights[switch (action) { .mode_socks5 => @as(usize, 0), .mode_local => 1, .mode_remote => 2, else => unreachable }] = highlight;
    const content = try ui.box(self.cx, .{ .width = .fill(), .height = .fill(), .direction = .column, .gap = 4, .min_width = 0 }, .{});
    const name = try ui.text(self.cx, title, S.text(11, 700, false));
    name.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .px = 16 } });
    try content.appendChild(self.cx.allocator, name);
    const note = try ui.text(self.cx, detail, S.text(10, 400, true));
    note.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .px = 14 } });
    try content.appendChild(self.cx.allocator, note);
    try node.appendChild(self.cx.allocator, content);
    return node;
}
fn tintMode(node: *ui.Node, color: ui.Color) void {
    if (node.getText()) |old| if (!std.meta.eql(old.color, color)) node.setTextColor(color);
    for (node.children.items) |child| tintMode(child, color);
}
