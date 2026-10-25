const std = @import("std");
const ui = @import("ui");
const C = @import("ui/status_connection_view.zig");
const S = @import("ui/status_connection_styles.zig");
const a = std.testing.allocator;

test "idle connection details dismiss does not request another frame" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.view.dismiss();
    f.cx.needs_redraw = false;
    f.view.dismiss();
    try std.testing.expect(!f.cx.needs_redraw);
    try std.testing.expectEqual(@as(usize, 0), f.reconnects);
}
const key: C.OperationKey = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(101), .generation = 1 } }, .operation_id = 4, .attempt_id = 1 };
fn snapshot() !C.Snapshot {
    const endpoint: C.details.Endpoint = .{ .name = try C.details.Text(512).init("K8s-Node01"), .host = try C.details.Text(1024).init("10.0.1.11"), .user = try C.details.Text(256).init("ubuntu") };
    var source: C.Snapshot = .{ .key = key, .revision = 1, .endpoint = endpoint, .state = .online, .connected_duration_ms = 42 * 60 * 1000, .hop_count = 2, .logs_available = true, .can_reconnect = true };
    source.route[0] = .{ .name = try C.details.Text(512).init("Bastion-01"), .host = try C.details.Text(1024).init("edge.example"), .user = try C.details.Text(256).init("ops") };
    source.route[1] = endpoint;
    return source;
}
const Fixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    trigger: *ui.Node,
    view: *C.View,
    copies: usize = 0,
    log_calls: usize = 0,
    reconnects: usize = 0,
    fail: bool = false,
    copied: ?[]u8 = null,
    last_key: ?C.OperationKey = null,
    logs_modal: ?*ui.Signal(bool) = null,
    fn init(self: *Fixture) !void {
        self.* = .{ .cx = try ui.Cx.init(a, std.testing.io), .scope = undefined, .trigger = undefined, .view = undefined };
        self.cx.setViewport(1440, 900);
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill() }, .{});
        self.scope = try ui.Scope.init(a, null, self.cx.owner);
        self.trigger = try ui.widgets.Button(.{ .a11y_label = "会话连接", .base_style = S.identityTrigger() }).mount(self.scope, self.cx);
        self.trigger.setStyleInline(a, .{ .position = .absolute, .inset = .{ .left = .{ .px = 8 }, .top = .{ .px = 863 } } });
        try self.cx.root.?.appendChild(a, self.trigger);
        self.view = try C.View.mount(self.cx, self.scope, .{ .context = self, .copy = copy, .logs = logs, .reconnect = reconnect });
        try self.cx.root.?.appendChild(a, self.view.root);
        self.cx.layout();
        _ = self.cx.render();
    }
    fn deinit(self: *Fixture) void {
        self.scope.dispose();
        self.cx.deinit();
        if (self.copied) |text| a.free(text);
    }
    fn copy(raw: *anyopaque, captured: C.OperationKey, text: []const u8) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (self.fail) return error.ClipboardUnavailable;
        const owned = try a.dupe(u8, text);
        if (self.copied) |old| a.free(old);
        self.copied = owned;
        self.copies += 1;
        self.last_key = captured;
    }
    fn logs(raw: *anyopaque, captured: C.OperationKey) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (self.fail) return error.Unavailable;
        self.log_calls += 1;
        self.last_key = captured;
        if (self.logs_modal) |open| open.set(true);
    }
    fn reconnect(raw: *anyopaque, captured: C.OperationKey) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (self.fail) return error.CleanupPending;
        self.reconnects += 1;
        self.last_key = captured;
    }
    fn settle(self: *Fixture) void {
        self.cx.setTestFrameStep(16) catch unreachable;
        for (0..20) |_| {
            self.cx.advanceFrameClock();
            self.cx.layout();
            _ = self.cx.render();
        }
    }
    fn show(self: *Fixture, source: C.Snapshot) !void {
        try self.view.show(source, self.trigger, 860);
        self.settle();
    }
    fn click(self: *Fixture, node: *ui.Node) void {
        const r = node.globalRect();
        self.cx.handleMouseDown(r.x + r.w / 2, r.y + r.h / 2, .{});
        self.cx.handleMouseUp(r.x + r.w / 2, r.y + r.h / 2);
    }
};

test "status connection view follows V3 labeled facts geometry and copies source values" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var source = try snapshot();
    try f.show(source);
    const r = f.view.chrome.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 8), r.x, 0.1);
    try std.testing.expectApproxEqAbs(f.trigger.globalRect().y - 6 - S.height, r.y, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 344), r.w, 0.1);
    try std.testing.expectApproxEqAbs(S.height, r.h, 0.1);
    try std.testing.expectApproxEqAbs(r.x + 15, f.view.name.parent.?.globalRect().x, 0.1);
    try std.testing.expectApproxEqAbs(r.y + 53, f.view.name.parent.?.globalRect().y, 0.1);
    try std.testing.expectApproxEqAbs(r.y + 80, f.view.address.globalRect().y, 0.1);
    const footer = f.view.footer.globalRect();
    try std.testing.expect(footer.y >= f.view.scroll.container.globalRect().y + f.view.scroll.container.globalRect().h);
    try std.testing.expect(footer.y + footer.h <= r.y + r.h - 14.5);
    try std.testing.expectEqual(@as(f32, 90), f.view.copy_button.globalRect().w);
    try std.testing.expectEqual(@as(f32, 74), f.view.reconnect_button.globalRect().w);
    try std.testing.expectEqualStrings("ubuntu@10.0.1.11:22", f.view.address.getText().?.content);
    try std.testing.expectEqualStrings("会话 101", f.view.session.getText().?.content);
    try std.testing.expectEqualStrings("42 分钟", f.view.duration.getText().?.content);
    try std.testing.expectEqualStrings("Bastion-01 → 目标", f.view.route.getText().?.content);
    try std.testing.expectEqualStrings("1 跳", f.view.hops.getText().?.content);
    source.endpoint.host.bytes[0] = 'x';
    source.route[0].name.bytes[0] = 'x';
    try std.testing.expectEqualStrings("10.0.1.11", f.view.source.?.endpoint.host.slice());
    try std.testing.expectEqualStrings("Bastion-01", f.view.source.?.route[0].name.slice());
}

test "status connection view mouse and keyboard copy use the captured endpoint and actual acknowledgement" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var source = try snapshot();
    source.endpoint.host = try C.details.Text(1024).init("2001:db8::1");
    source.route[1] = source.endpoint;
    try f.show(source);
    f.click(f.view.copy_button);
    try std.testing.expectEqual(@as(usize, 1), f.copies);
    try std.testing.expect(f.last_key.?.eql(key));
    try std.testing.expect(std.mem.indexOf(u8, f.copied.?, "身份：ubuntu@[2001:db8::1]:22") != null);
    try std.testing.expect(std.mem.indexOf(u8, f.copied.?, "协议：SSH · 交互式 Shell") != null);
    f.cx.setFocus(f.view.copy_button);
    f.cx.handleKeyDown(.@"return", .{});
    try std.testing.expectEqual(@as(usize, 2), f.copies);
    f.fail = true;
    f.click(f.view.copy_button);
    try std.testing.expectEqual(@as(usize, 2), f.copies);
    try std.testing.expectEqualStrings("复制失败，请重试", f.view.feedback_label.getText().?.content);
}

test "status connection view rejects other generations old revisions and endpoint changes without redirection" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var source = try snapshot();
    source.revision = 4;
    try f.show(source);
    var other = source;
    other.key.owner.session.generation += 1;
    try std.testing.expectError(error.ConnectionOwnerMismatch, f.view.update(other));
    other = source;
    other.revision = 3;
    try std.testing.expectError(error.StaleConnection, f.view.update(other));
    other = source;
    other.revision = 5;
    other.endpoint.user = try C.details.Text(256).init("different");
    try std.testing.expectError(error.FrozenEndpointChanged, f.view.update(other));
    other = source;
    other.revision = 5;
    other.state = .unknown;
    other.connected_duration_ms = null;
    try f.view.update(other);
    try f.view.flush();
    f.settle();
    try std.testing.expectEqualStrings("未知", f.view.state.getText().?.content);
    try std.testing.expectEqualStrings("未知", f.view.duration.getText().?.content);
    f.click(f.view.copy_button);
    try std.testing.expect(f.last_key.?.eql(key));
}

test "status connection view logs and reconnect are explicit callbacks and close or escape has no session action" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const source = try snapshot();
    try f.show(source);
    f.cx.setFocus(f.view.close_button);
    f.cx.handleKeyDown(.escape, .{});
    try std.testing.expect(!f.view.isVisible());
    try std.testing.expect(f.cx.isFocused(f.trigger));
    try std.testing.expectEqual(@as(usize, 0), f.reconnects);
    try f.show(source);
    f.click(f.view.logs_button);
    try std.testing.expectEqual(@as(usize, 1), f.log_calls);
    try std.testing.expect(f.last_key.?.eql(key));
    try std.testing.expect(!f.view.isVisible());
    try f.show(source);
    f.fail = true;
    f.click(f.view.reconnect_button);
    try std.testing.expectEqual(@as(usize, 0), f.reconnects);
    try std.testing.expect(f.view.isVisible());
    try std.testing.expectEqualStrings("暂时无法重新连接", f.view.feedback_label.getText().?.content);
    f.fail = false;
    f.click(f.view.reconnect_button);
    try std.testing.expectEqual(@as(usize, 1), f.reconnects);
    try std.testing.expect(f.last_key.?.eql(key));
    try std.testing.expect(!f.view.isVisible());
}

test "status connection view expired capture keeps copy and logs but cannot advertise online or reconnect" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const source = try snapshot();
    try f.show(source);
    var other = key;
    other.operation_id += 1;
    f.view.invalidate(other);
    try std.testing.expect(!f.view.expired);
    f.view.invalidate(key);
    try f.view.flush();
    f.settle();
    try std.testing.expectEqualStrings("已过期", f.view.state.getText().?.content);
    try std.testing.expectEqualStrings("未知", f.view.duration.getText().?.content);
    try std.testing.expect(f.view.reconnect_disabled.peek());
    f.click(f.view.reconnect_button);
    try std.testing.expectEqual(@as(usize, 0), f.reconnects);
    f.click(f.view.copy_button);
    try std.testing.expectEqual(@as(usize, 1), f.copies);
    try std.testing.expectError(error.StaleConnection, f.view.update(source));
    f.view.hide();
    try f.show(source);
    try std.testing.expectEqualStrings("已过期", f.view.state.getText().?.content);
}

test "status connection view reanchors and rethemes a bounded scroll card without replacing its owner" {
    const previous = S.theme.currentName();
    defer S.theme.select(previous);
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const source = try snapshot();
    try f.show(source);
    const before = f.view.chrome.getBackground();
    S.theme.select(if (previous == .dark) .light else .dark);
    try f.view.retheme();
    f.settle();
    try std.testing.expect(!std.meta.eql(before, f.view.chrome.getBackground()));
    try std.testing.expect(f.view.source.?.key.eql(key));
    f.cx.setViewport(480, 240);
    f.trigger.setStyleInline(a, .{ .inset = .{ .left = .{ .px = 248 }, .top = .{ .px = 193 } } });
    f.cx.layout();
    f.view.reanchor(190);
    try f.view.flush();
    f.settle();
    const r = f.view.chrome.globalRect();
    try std.testing.expect(r.x >= 8 and r.x + r.w <= 472.1 and r.y >= 8);
    try std.testing.expectApproxEqAbs(f.trigger.globalRect().y - 6, r.y + r.h, 0.1);
    try std.testing.expect(f.view.scroll.content.globalRect().h > f.view.scroll.container.globalRect().h);
    f.trigger.setDisplay(.none);
    f.view.reanchor(190);
    try std.testing.expect(!f.view.isVisible());
    try std.testing.expectEqual(@as(usize, 0), f.reconnects);
}

fn visibleHint(node: *ui.Node, text: []const u8) bool {
    if (node.meta.ownership.meta.component_name) |name| {
        if (std.mem.eql(u8, name, "TooltipContent") and node.getOpacity() > 0.9 and hintText(node, text)) return true;
    }
    for (node.children.items) |child| if (visibleHint(child, text)) return true;
    return false;
}
fn hintText(node: *ui.Node, text: []const u8) bool {
    if (node.getText()) |value| if (std.mem.eql(u8, value.content, text)) return true;
    for (node.children.items) |child| if (hintText(child, text)) return true;
    return false;
}
test "status connection view icon tooltips appear on keyboard focus and hover without changing hit areas" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.show(try snapshot());
    const before = f.view.copy_button.globalRect();
    f.cx.setFocus(f.view.copy_button);
    f.settle();
    f.settle();
    try std.testing.expectEqualStrings("复制信息", f.view.copy_button.behavior.interaction.a11y.?.label.?);
    try std.testing.expectEqual(before, f.view.copy_button.globalRect());
    f.cx.clearFocus();
    const logs_rect = f.view.logs_button.globalRect();
    f.cx.handleMouseMove(logs_rect.x + logs_rect.w / 2, logs_rect.y + logs_rect.h / 2);
    f.settle();
    f.settle();
    try std.testing.expect(visibleHint(f.cx.root.?, "连接日志"));
    // A focused icon can be torn down by retheming without a stale blur target.
    f.cx.setFocus(f.view.copy_button);
    try f.view.retheme();
    f.settle();
    try std.testing.expect(f.view.source.?.key.eql(key));
}

test "status connection view hands keyboard focus to the actual log modal after its action" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const open = try f.scope.createSignal(bool, false);
    f.logs_modal = open;
    const modal = try ui.widgets.Modal(.{ .open = open, .title = "连接日志", .width = 760 }).mount(f.scope, f.cx);
    if (!modal.portaled) try f.cx.root.?.appendChild(a, modal.overlay);
    const close = try ui.widgets.Button(.{ .label = "关闭" }).mount(f.scope, f.cx);
    try modal.body.appendChild(a, close);
    try f.show(try snapshot());
    f.cx.setFocus(f.view.logs_button);
    f.cx.handleKeyDown(.@"return", .{});
    f.settle();
    try std.testing.expect(open.peek());
    try std.testing.expect(!f.view.isVisible());
    const focused = f.cx.focus_manager.current_focus orelse return error.MissingModalFocus;
    try std.testing.expect(focused.isDescendantOf(modal.dialog));
    try std.testing.expect(f.last_key.?.eql(key));
}
