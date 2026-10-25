//! Captured SSH identity. No native session lookup, reconnection or clipboard
//! access occurs here; actions retain the original complete operation key.
const std = @import("std");
const ui = @import("ui");
pub const details = @import("../proto/ssh/connection_details.zig");
pub const OperationKey = details.OperationKey;
const S = @import("status_connection_styles.zig");
pub const State = enum { unknown, online, disconnected };
pub const Snapshot = struct {
    key: OperationKey,
    revision: u64,
    endpoint: details.Endpoint,
    state: State = .unknown,
    connected_duration_ms: ?u64 = null,
    latency_ms: ?u64 = null,
    cipher_c2s: details.Text(64) = .{},
    cipher_s2c: details.Text(64) = .{},
    route: [details.max_hops]details.Endpoint = @splat(.{}),
    hop_count: usize,
    logs_available: bool = false,
    can_reconnect: bool = false,
};
pub const Callbacks = struct {
    context: *anyopaque,
    copy: *const fn (*anyopaque, OperationKey, []const u8) anyerror!void,
    logs: ?*const fn (*anyopaque, OperationKey) anyerror!void = null,
    reconnect: ?*const fn (*anyopaque, OperationKey) anyerror!void = null,
};
const Action = struct {
    view: *View,
    key: OperationKey,
    kind: enum { close, copy, logs, reconnect },
    fn click(self: *Action) void {
        const view = self.view;
        if (!view.visible or view.source == null or !view.source.?.key.eql(self.key)) return;
        switch (self.kind) {
            .close => view.hide(),
            .copy => view.copyAddress(),
            .logs => {
                if (!view.source.?.logs_available or view.callbacks.logs == null) return;
                view.callbacks.logs.?(view.callbacks.context, self.key) catch {
                    view.feedback("无法打开连接日志", false);
                    return;
                };
                view.hideWithoutFocus();
            },
            .reconnect => {
                if (view.expired or !view.source.?.can_reconnect or view.callbacks.reconnect == null) return;
                view.callbacks.reconnect.?(view.callbacks.context, self.key) catch {
                    view.feedback("暂时无法重新连接", false);
                    return;
                };
                view.hide();
            },
        }
    }
    fn cleanup(self: *Action) void {
        self.view.cx.allocator.destroy(self);
    }
};
pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    callbacks: Callbacks,
    root: *ui.Node = undefined,
    chrome: *ui.Node = undefined,
    content: *ui.Node = undefined,
    open: *ui.Signal(bool),
    reconnect_disabled: *ui.Signal(bool),
    logs_disabled: *ui.Signal(bool),
    source: ?Snapshot = null,
    expired: bool = false,
    visible: bool = false,
    dirty: bool = false,
    rebuild: bool = false,
    content_scope: ?*ui.Scope = null,
    anchor_id: ?u32 = null,
    anchor_rect: ui.widgets.popover.AnchorRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    status_top: f32 = 0,
    viewport: ui.Size = .ZERO,
    pointer: *ui.Node = undefined,
    name: *ui.Node = undefined,
    state: *ui.Node = undefined,
    address: *ui.Node = undefined,
    session: *ui.Node = undefined,
    duration: *ui.Node = undefined,
    route: *ui.Node = undefined,
    hops: *ui.Node = undefined,
    feedback_label: *ui.Node = undefined,
    logs_button: *ui.Node = undefined,
    copy_button: *ui.Node = undefined,
    reconnect_button: *ui.Node = undefined,
    close_button: *ui.Node = undefined,
    scroll: ui.widgets.ScrollAreaResult = undefined,
    latency: *ui.Node = undefined,
    cipher: *ui.Node = undefined,
    footer: *ui.Node = undefined,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, callbacks: Callbacks) !*View {
        const self = try cx.allocator.create(View);
        var registered = false;
        errdefer if (!registered) cx.allocator.destroy(self);
        self.* = .{ .cx = cx, .scope = scope, .callbacks = callbacks, .open = try scope.createSignal(bool, false), .reconnect_disabled = try scope.createSignal(bool, true), .logs_disabled = try scope.createSignal(bool, true) };
        try scope.onCleanup(View, self, cleanup);
        registered = true;
        const focus_guard = try scope.childScope();
        const popup = try ui.widgets.Popover(.{ .open = self.open, .trigger = .manual, .anchor = .{ .virtual = .{ .ctx = self, .getRect = anchor } }, .position = .top, .width = S.width, .max_width = S.width, .offset = .{ .static = S.anchor_gap }, .viewport_padding = S.margin, .constrain_width_to_viewport = true, .flip = false, .shift_main_axis = false, .on_open_change = cx.on(View, self, openChanged) }).mount(scope, cx);
        self.scope = popup.scope;
        self.root = popup.wrapper;
        self.chrome = popup.chrome;
        self.content = popup.content;
        try focus_guard.onCleanup(View, self, releaseFocus);
        self.root.setStyleInline(cx.allocator, S.wrapper());
        self.chrome.setStyleInline(cx.allocator, S.panel(S.height, cx.viewport.width));
        self.chrome.meta.ownership.meta.test_id = "status.connection";
        return self;
    }
    pub fn show(self: *View, source: Snapshot, trigger: *ui.Node, status_top: f32) !void {
        try validate(source);
        if (!std.math.isFinite(status_top) or status_top < 0) return error.InvalidAnchor;
        if (self.visible and self.source != null and self.source.?.key.eql(source.key) and self.anchor_id == trigger.id) {
            self.hide();
            return;
        }
        const changed = self.source == null or !self.source.?.key.eql(source.key);
        if (changed) {
            self.source = source;
            self.expired = false;
            self.rebuild = true;
        } else if (!self.expired) try self.update(source);
        const rect = trigger.globalRect();
        self.anchor_id = trigger.id;
        self.status_top = status_top;
        self.anchor_rect = .{ .x = rect.x, .y = status_top, .w = rect.w, .h = 0 };
        self.visible = true;
        self.open.set(true);
        self.dirty = true;
        try self.flush();
    }
    pub fn update(self: *View, source: Snapshot) !void {
        try validate(source);
        const current = self.source orelse return error.ConnectionNotVisible;
        if (!current.key.eql(source.key)) return error.ConnectionOwnerMismatch;
        if (self.expired or source.revision < current.revision) return error.StaleConnection;
        if (!std.meta.eql(source.endpoint, current.endpoint) or source.hop_count != current.hop_count or !std.meta.eql(source.route, current.route)) return error.FrozenEndpointChanged;
        if (source.revision == current.revision) return;
        self.source = source;
        self.dirty = true;
        self.cx.requestRedraw();
    }
    pub fn invalidate(self: *View, key: OperationKey) void {
        if (self.source == null or !self.source.?.key.eql(key) or self.expired) return;
        self.expired = true;
        self.dirty = true;
        self.cx.requestRedraw();
    }
    pub fn reanchor(self: *View, status_top: f32) void {
        if (!self.visible) return;
        const trigger = find(self.cx.root orelse return, self.anchor_id orelse return) orelse {
            self.hideWithoutFocus();
            return;
        };
        if (trigger.style.display == .none) {
            self.hideWithoutFocus();
            return;
        }
        const rect = trigger.globalRect();
        const next: ui.widgets.popover.AnchorRect = .{ .x = rect.x, .y = status_top, .w = rect.w, .h = 0 };
        if (std.meta.eql(next, self.anchor_rect)) return;
        self.status_top = status_top;
        self.anchor_rect = next;
        self.dirty = true;
        self.chrome.markLayoutDirty();
        self.cx.requestRedraw();
    }
    pub fn flush(self: *View) !void {
        if (!self.visible or self.source == null) return;
        if (!std.meta.eql(self.viewport, self.cx.viewport)) {
            self.viewport = self.cx.viewport;
            self.dirty = true;
        }
        if (self.rebuild or self.content_scope == null) {
            try self.build();
            self.rebuild = false;
            self.dirty = true;
        }
        if (!self.dirty) return;
        self.dirty = false;
        const h = @min(S.height, @max(0, self.status_top - S.anchor_gap - S.margin));
        const w = @min(S.width, @max(0, self.cx.viewport.width - S.margin * 2));
        self.chrome.setStyleInline(self.cx.allocator, S.panel(h, self.cx.viewport.width));
        const x = @min(@max(S.margin, self.anchor_rect.x + (self.anchor_rect.w - w) / 2), @max(S.margin, self.cx.viewport.width - w - S.margin));
        self.pointer.setStyleInline(self.cx.allocator, S.pointer(@min(@max(14, self.anchor_rect.x + self.anchor_rect.w / 2 - x - 6), @max(14, w - 26))));
        try self.refresh();
        self.cx.requestRedraw();
    }
    pub fn retheme(self: *View) !void {
        self.rebuild = true;
        try self.flush();
    }
    pub fn isVisible(self: *const View) bool {
        return self.visible;
    }
    pub fn hide(self: *View) void {
        self.hideWithoutFocus();
        if (find(self.cx.root orelse return, self.anchor_id orelse return)) |trigger| if (trigger.style.display != .none) self.cx.setFocus(trigger);
    }
    /// Context changes must not steal focus back from the newly selected pane.
    pub fn dismiss(self: *View) void {
        self.hideWithoutFocus();
    }
    fn hideWithoutFocus(self: *View) void {
        if (!self.visible and !self.open.peek()) return;
        self.visible = false;
        self.open.set(false);
        self.cx.requestRedraw();
    }
    fn openChanged(self: *View, value: bool) void {
        if (!value and self.visible) self.hide();
    }
    fn build(self: *View) !void {
        clear(self.cx, self.content);
        // Remove custom siblings while retaining the public Popover content.
        var index: usize = 0;
        while (index < self.chrome.children.items.len) {
            const node = self.chrome.children.items[index];
            if (node == self.content or @import("background_layers.zig").isSurface(node)) {
                index += 1;
                continue;
            }
            self.cx.detachChild(self.chrome, node);
            self.cx.destroyDetached(node);
        }
        if (self.content_scope) |old| old.dispose();
        const scope = try self.scope.childScope();
        self.content_scope = scope;
        self.content.setStyleInline(self.cx.allocator, S.content());
        const header = try ui.box(self.cx, S.header(), .{});
        try header.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.terminal, S.theme.current().accent, S.icon(14)));
        _ = try label(self.cx, header, "会话连接", S.title(), S.titleBox());
        try header.appendChild(self.cx.allocator, try ui.spacer(self.cx));
        self.close_button = try self.button(scope, header, .close, "关闭会话连接", "status.connection.close", ui.icons.x, 24, false, null);
        try self.content.appendChild(self.cx.allocator, header);
        try self.content.appendChild(self.cx.allocator, try ui.box(self.cx, .{ .height = .{ .px = 12 }, .flex_shrink = 0 }, .{}));
        self.scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical, .rubber_band_y = false }).mount(scope, self.cx);
        self.scroll.container.setStyleInline(self.cx.allocator, S.scroll());
        self.scroll.container.meta.ownership.meta.test_id = "status.connection.viewport";
        self.scroll.content.setStyleInline(self.cx.allocator, S.body());
        try self.content.appendChild(self.cx.allocator, self.scroll.container);
        self.name = try self.fact("连接", "status.connection.name");
        self.address = try self.fact("身份", "status.connection.address");
        _ = try self.factValue("协议", "SSH · 交互式 Shell", "status.connection.protocol");
        self.state = try self.fact("状态", "status.connection.state");
        self.latency = try self.fact("延迟", "status.connection.latency");
        self.cipher = try self.fact("加密", "status.connection.cipher");
        self.session = try self.fact("会话", "status.connection.session");
        self.duration = try label(self.cx, self.session.parent.?, "", S.infoText(true), .{ .width = .{ .px = 66 }, .height = .{ .px = 18 }, .flex_shrink = 0 });
        self.duration.meta.ownership.meta.test_id = "status.connection.duration";
        self.route = try self.fact("路径", "status.connection.route");
        // Retain the captured hop summary for existing host/test consumers.
        self.hops = try label(self.cx, self.scroll.content, "", S.infoText(true), S.factValue());
        self.hops.setDisplay(.none);
        try self.content.appendChild(self.cx.allocator, try ui.box(self.cx, .{ .height = .{ .px = 14 }, .flex_shrink = 0 }, .{}));
        const actions = try ui.box(self.cx, S.footer(), .{});
        self.footer = actions;
        actions.meta.ownership.meta.test_id = "status.connection.footer";
        self.copy_button = try self.textButton(scope, actions, .copy, "复制信息", "status.connection.copy", 90, true, null);
        self.logs_button = try self.button(scope, actions, .logs, "连接日志", "status.connection.logs", ui.icons.get("list").?, 28, true, self.logs_disabled);
        self.feedback_label = try label(self.cx, actions, "", S.infoText(true), S.feedbackBox());
        self.reconnect_button = try self.textButton(scope, actions, .reconnect, "重新连接", "status.connection.reconnect", 74, false, self.reconnect_disabled);
        try self.content.appendChild(self.cx.allocator, actions);
        self.pointer = try ui.iconTint(self.cx, ui.icons.chevron_down, S.theme.current().fg_3, S.icon(12));
        self.pointer.setDisplay(.none);
        try self.chrome.appendChild(self.cx.allocator, self.pointer);
    }
    fn fact(self: *View, title: []const u8, test_id: []const u8) !*ui.Node {
        return self.factValue(title, "", test_id);
    }
    fn factValue(self: *View, title: []const u8, value: []const u8, test_id: []const u8) !*ui.Node {
        const row = try ui.box(self.cx, S.info(), .{});
        _ = try label(self.cx, row, title, S.infoText(false), S.factLabel());
        const node = try label(self.cx, row, value, S.infoText(true), S.factValue());
        node.meta.ownership.meta.test_id = test_id;
        try self.scroll.content.appendChild(self.cx.allocator, row);
        return node;
    }
    fn textButton(self: *View, scope: *ui.Scope, parent: *ui.Node, kind: @FieldType(Action, "kind"), name: []const u8, test_id: []const u8, width: f32, surface: bool, disabled: ?*ui.Signal(bool)) !*ui.Node {
        const action = try scope.createState(Action, .{ .view = self, .key = self.source.?.key, .kind = kind });
        const node = try ui.widgets.Button(.{ .label = name, .variant = .ghost, .base_style = S.textAction(width, surface), .hover_style = S.hover(), .disabled = disabled orelse try scope.createSignal(bool, false), .on_click = self.cx.on(Action, action, Action.click) }).mount(scope, self.cx);
        node.meta.ownership.meta.test_id = test_id;
        try parent.appendChild(self.cx.allocator, node);
        return node;
    }
    fn button(self: *View, scope: *ui.Scope, parent: *ui.Node, kind: @FieldType(Action, "kind"), name: []const u8, test_id: []const u8, asset: ui.SvgAsset, size: f32, surface: bool, disabled: ?*ui.Signal(bool)) !*ui.Node {
        const action = try self.cx.allocator.create(Action);
        errdefer self.cx.allocator.destroy(action);
        action.* = .{ .view = self, .key = self.source.?.key, .kind = kind };
        try scope.onCleanup(Action, action, Action.cleanup);
        const disabled_signal = disabled orelse try scope.createSignal(bool, false);
        const button_node = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = name, .base_style = S.action(size, surface), .hover_style = S.hover(), .disabled = disabled_signal, .on_click = self.cx.on(Action, action, Action.click) }).mount(scope, self.cx);
        button_node.meta.ownership.meta.test_id = test_id;
        try button_node.appendChild(self.cx.allocator, try ui.iconTint(self.cx, asset, S.theme.current().fg_2, S.icon(if (kind == .close) 14 else 16)));
        try parent.appendChild(self.cx.allocator, try @import("connection_details_view.zig").iconTooltip(self.cx, scope, button_node, name));
        return button_node;
    }
    fn refresh(self: *View) !void {
        const source = &self.source.?;
        try self.name.setTextContent(self.cx.allocator, if (source.endpoint.name.len != 0) source.endpoint.name.slice() else unknown(source.endpoint.host.slice()));
        try self.state.setTextContent(self.cx.allocator, if (self.expired) "已过期" else switch (source.state) {
            .unknown => "未知",
            .online => "在线",
            .disconnected => "已断开",
        });
        const online = !self.expired and source.state == .online;
        self.state.setTextColor(if (online) S.theme.current().ok_ink else S.theme.current().fg_2);

        var buffer: [4096]u8 = undefined;
        try self.latency.setTextContent(self.cx.allocator, if (online and source.latency_ms != null) try std.fmt.bufPrint(&buffer, "{d} ms", .{source.latency_ms.?}) else "未知");
        const outgoing = source.cipher_c2s.slice();
        const incoming = source.cipher_s2c.slice();
        try self.cipher.setTextContent(self.cx.allocator, if (outgoing.len == 0 and incoming.len == 0) "未知" else if (std.mem.eql(u8, outgoing, incoming)) outgoing else try std.fmt.bufPrint(&buffer, "↑ {s} · ↓ {s}", .{ unknown(outgoing), unknown(incoming) }));
        try self.address.setTextContent(self.cx.allocator, try addressText(&buffer, &source.endpoint));
        try self.session.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&buffer, "会话 {d}", .{@backingInt(source.key.owner.session.session_id)}));
        const duration = if (self.expired or source.state != .online) "未知" else if (source.connected_duration_ms) |ms| if (ms >= 60_000) try std.fmt.bufPrint(&buffer, "{d} 分钟", .{ms / 60_000}) else try std.fmt.bufPrint(&buffer, "{d} 秒", .{ms / 1000}) else "未知";
        try self.duration.setTextContent(self.cx.allocator, duration);
        self.duration.setDisplay(if (self.expired or source.state != .online or source.connected_duration_ms == null) .none else .flex);
        var route_text: std.Io.Writer.Allocating = .init(self.cx.allocator);
        defer route_text.deinit();
        if (source.hop_count == 1) try route_text.writer.writeAll("直连") else {
            for (source.route[0 .. source.hop_count - 1], 0..) |*hop, index| {
                if (index != 0) try route_text.writer.writeAll(" → ");
                try route_text.writer.writeAll(if (hop.name.len != 0) hop.name.slice() else unknown(hop.host.slice()));
            }
            try route_text.writer.writeAll(" → 目标");
        }
        try self.route.setTextContent(self.cx.allocator, route_text.writer.buffered());
        try self.hops.setTextContent(self.cx.allocator, if (source.hop_count == 1) "直连" else try std.fmt.bufPrint(&buffer, "{d} 跳", .{source.hop_count - 1}));
        self.logs_disabled.set(!source.logs_available or self.callbacks.logs == null);
        self.reconnect_disabled.set(self.expired or !source.can_reconnect or self.callbacks.reconnect == null);
    }
    pub fn copyAddress(self: *View) void {
        if (!self.visible or self.source == null) return;
        const source = &self.source.?;
        var buffer: [4096]u8 = undefined;
        const endpoint = addressText(&buffer, &source.endpoint) catch {
            self.feedback("复制失败，请重试", false);
            return;
        };
        const report = std.fmt.allocPrint(self.cx.allocator, "连接：{s}\n身份：{s}\n协议：SSH · 交互式 Shell\n状态：{s}\n延迟：{s}\n加密：{s}\n会话：{s}\n时长：{s}\n路径：{s}", .{ self.name.getText().?.content, endpoint, self.state.getText().?.content, self.latency.getText().?.content, self.cipher.getText().?.content, self.session.getText().?.content, self.duration.getText().?.content, self.route.getText().?.content }) catch {
            self.feedback("复制失败，请重试", false);
            return;
        };
        defer self.cx.allocator.free(report);
        self.callbacks.copy(self.callbacks.context, source.key, report) catch {
            self.feedback("复制失败，请重试", false);
            return;
        };
        self.feedback("已复制信息", true);
    }
    fn feedback(self: *View, text: []const u8, success: bool) void {
        self.feedback_label.setTextContent(self.cx.allocator, text) catch {};
        self.feedback_label.setTextColor(if (success) S.theme.current().ok_ink else S.theme.current().danger_ink);
        self.cx.requestRedraw();
    }
    fn anchor(raw: *anyopaque) ui.widgets.popover.AnchorRect {
        const self: *View = @ptrCast(@alignCast(raw));
        if (self.visible) if (self.cx.root) |root| if (self.anchor_id) |id| if (find(root, id)) |trigger| {
            const rect = trigger.globalRect();
            if (trigger.isDisplayedInTree() and rect.w > 0) return .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = 0 };
        };
        return self.anchor_rect;
    }
    fn cleanup(self: *View) void {
        self.cx.allocator.destroy(self);
    }
    fn releaseFocus(self: *View) void {
        const focused = self.cx.focus_manager.current_focus orelse return;
        if (focused.isDescendantOf(self.chrome)) self.cx.clearFocus();
    }
};
pub fn validate(source: Snapshot) !void {
    if (source.key.owner != .session or @backingInt(source.key.owner.session.session_id) == 0 or source.key.owner.session.generation == 0 or source.key.operation_id == 0 or source.key.attempt_id == null or source.key.attempt_id == 0 or source.revision == 0 or source.hop_count == 0 or source.hop_count > details.max_hops) return error.InvalidConnection;
    if (source.cipher_c2s.len > source.cipher_c2s.bytes.len or source.cipher_s2c.len > source.cipher_s2c.bytes.len) return error.InvalidConnection;
    try validateEndpoint(source.endpoint);
    for (source.route[0..source.hop_count]) |endpoint| try validateEndpoint(endpoint);
}
fn validateEndpoint(endpoint: details.Endpoint) !void {
    if (endpoint.host.len > endpoint.host.bytes.len or endpoint.user.len > endpoint.user.bytes.len or endpoint.name.len > endpoint.name.bytes.len or endpoint.port == 0) return error.InvalidEndpoint;
}
fn addressText(buffer: []u8, endpoint: *const details.Endpoint) ![]const u8 {
    const host = unknown(endpoint.host.slice());
    return if (std.mem.indexOfScalar(u8, host, ':') != null) std.fmt.bufPrint(buffer, "{s}@[{s}]:{d}", .{ unknown(endpoint.user.slice()), host, endpoint.port }) else std.fmt.bufPrint(buffer, "{s}@{s}:{d}", .{ unknown(endpoint.user.slice()), host, endpoint.port });
}
fn unknown(value: []const u8) []const u8 {
    return if (value.len == 0) "未知" else value;
}
fn label(cx: *ui.Cx, parent: *ui.Node, text: []const u8, style: ui.TextStyle, box: ui.BoxStyle) !*ui.Node {
    const node = try ui.text(cx, "", style);
    node.setStyleInline(cx.allocator, box);
    try node.setTextContent(cx.allocator, text);
    try parent.appendChild(cx.allocator, node);
    return node;
}
fn clear(cx: *ui.Cx, parent: *ui.Node) void {
    var index: usize = 0;
    while (index < parent.children.items.len) {
        const child = parent.children.items[index];
        if (@import("background_layers.zig").isSurface(child)) {
            index += 1;
            continue;
        }
        cx.detachChild(parent, child);
        cx.destroyDetached(child);
    }
}
fn find(node: *ui.Node, id: u32) ?*ui.Node {
    if (node.id == id) return node;
    for (node.children.items) |child| if (find(child, id)) |found| return found;
    return null;
}
