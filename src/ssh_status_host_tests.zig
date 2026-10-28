const std = @import("std");
const ui = @import("ui");
const SSH = @import("ui/ssh_status_host.zig");
const D = @import("ui/connection_details_view.zig");
const Logs = @import("ui/connection_logs_view.zig");
const a = std.testing.allocator;
const key: D.OperationKey = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(901), .generation = 1 } }, .operation_id = 4, .attempt_id = 1 };
fn snapshot(captured: D.OperationKey, name: []const u8) !D.Snapshot {
    var value: D.Snapshot = .{ .key = captured, .revision = 1, .source = .session, .hops = @splat(.{}), .hop_count = 2, .target_rtt_sample = null, .sampled_at = null };
    for (value.hops[0..2], 0..) |*hop, index| {
        hop.configured = true;
        hop.status = .online;
        hop.endpoint = .{ .host = try D.details.Text(1024).init(if (index == 0) "edge.example" else "db.example"), .user = try D.details.Text(256).init("admin"), .name = try D.details.Text(512).init(if (index == 0) "Bastion" else name) };
    }
    return value;
}
const Fixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    bar: SSH.StatusBar,
    host: *SSH.Host,
    logs: *Logs.View,
    captures: usize = 0,
    copies: usize = 0,
    reconnects: usize = 0,
    themes: usize = 0,
    captured: ?D.Snapshot = null,
    last_key: ?D.OperationKey = null,
    last_theme_trigger: ?*ui.Node = null,
    copied: ?[]u8 = null,
    fn init(self: *Fixture) !void {
        self.* = .{ .cx = try ui.Cx.init(a, std.testing.io), .scope = undefined, .bar = undefined, .host = undefined, .logs = undefined };
        self.cx.setViewport(1440, 900);
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill() }, .{});
        self.scope = try ui.Scope.init(a, null, self.cx.owner);
        self.bar = try SSH.mountStatusBar(self.cx, self.scope, try ui.text(self.cx, "就绪", .{}));
        self.bar.bar.setStyleInline(a, .{ .position = .absolute, .inset = .{ .left = .{ .px = 8 }, .top = .{ .px = 860 } }, .width = .{ .px = 1424 } });
        try self.cx.root.?.appendChild(a, self.bar.bar);
        try self.bar.progress_slot.appendChild(a, try ui.box(self.cx, .{ .width = .{ .px = 264 }, .height = .{ .px = 26 } }, .{}));
        self.logs = try Logs.View.mount(self.cx, self.scope, .{ .context = self, .copy_logs = copy });
        self.host = try SSH.Host.mount(self.cx, self.scope, .{ .context = self, .capture = capture, .copy = copy, .logs = openLogs, .reconnect = reconnect, .hide_chain = hideChain });
        self.host.bind(self.bar.controls, self, theme);
        try self.bar.controls.setThemeName(self.cx, "Sauber");
        self.cx.layout();
        _ = self.cx.render();
    }
    fn deinit(self: *Fixture) void {
        self.scope.dispose();
        self.cx.deinit();
        if (self.copied) |text| a.free(text);
    }
    fn settle(self: *Fixture) void {
        self.cx.setTestFrameStep(16) catch unreachable;
        for (0..20) |_| {
            self.cx.advanceFrameClock();
            self.cx.layout();
            _ = self.cx.render();
        }
    }
    fn update(self: *Fixture, source: D.Snapshot, retry: bool) !void {
        try self.host.updateActive(.{ .details = source, .utf8 = true, .grid = .{ .cols = 120, .rows = 36, .revision = 1 }, .can_reconnect = retry });
        self.settle();
    }
    fn enter(self: *Fixture, node: *ui.Node) void {
        self.cx.setFocus(node);
        self.cx.handleKeyDown(.@"return", .{});
        self.settle();
    }
    fn click(self: *Fixture, node: *ui.Node) void {
        const rect = node.globalRect();
        self.cx.handleMouseDown(rect.x + rect.w / 2, rect.y + rect.h / 2, .{});
        self.cx.handleMouseUp(rect.x + rect.w / 2, rect.y + rect.h / 2);
        self.settle();
    }
    fn capture(raw: *anyopaque, source: D.Snapshot) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.captures += 1;
        self.captured = source;
    }
    fn copy(raw: *anyopaque, captured: D.OperationKey, text: []const u8) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (self.captured == null or !self.captured.?.key.eql(captured)) return error.StaleConnection;
        const owned = try a.dupe(u8, text);
        if (self.copied) |old| a.free(old);
        self.copied = owned;
        self.copies += 1;
        self.last_key = captured;
    }
    fn openLogs(raw: *anyopaque, captured: D.OperationKey) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (self.captured == null or !self.captured.?.key.eql(captured)) return error.StaleConnection;
        var record: Logs.LogRecord = .{ .key = captured, .entry = .{ .hop_count = 2, .hop = 1, .status = .succeeded, .phase = .ready, .port = 22 } };
        @memcpy(record.entry.host[0..10], "db.example");
        record.entry.host_len = 10;
        try self.logs.show(.{ .key = captured, .revision = 1, .endpoint = self.captured.?.hops[1].endpoint, .records = (&record)[0..1] });
        self.last_key = captured;
    }
    fn reconnect(raw: *anyopaque, captured: D.OperationKey) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (self.captured == null or !self.captured.?.key.eql(captured)) return error.StaleConnection;
        self.reconnects += 1;
        self.last_key = captured;
    }
    fn hideChain(_: *anyopaque) void {}
    fn theme(raw: *anyopaque, trigger: *ui.Node) void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.themes += 1;
        self.last_theme_trigger = trigger;
    }
};
fn id(node: *ui.Node, text: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, text, value)) return node;
    for (node.children.items) |child| if (id(child, text)) |found| return found;
    return null;
}

test "SSH status host mounts exact live bar geometry and publishes only authoritative metrics" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.update(try snapshot(key, "DB-A"), false);
    const theme_width = f.bar.controls.theme_button.globalRect().w;
    const Item = struct { node: *ui.Node, x: f32, w: f32 };
    for ([_]Item{ .{ .node = f.bar.controls.identity_button, .x = 0, .w = 118 }, .{ .node = f.bar.controls.encoding_button, .x = 124, .w = 68 }, .{ .node = f.bar.controls.grid_button, .x = 198, .w = 82 }, .{ .node = f.bar.chain_trigger, .x = 978 - theme_width, .w = 78 }, .{ .node = f.bar.controls.theme_button, .x = 1146 - theme_width, .w = theme_width } }) |item| {
        const r = item.node.globalRect();
        try std.testing.expectApproxEqAbs(8 + item.x, r.x, 0.1);
        try std.testing.expectEqual(item.w, r.w);
        try std.testing.expectEqual(@as(f32, 26), r.h);
        try std.testing.expectApproxEqAbs(f.bar.controls.identity_button.globalRect().y, r.y, 0.1);
    }
    try std.testing.expectEqualStrings("已连接", f.bar.controls.identity_label.getText().?.content);
    try std.testing.expectEqualStrings("UTF-8", f.bar.controls.encoding_label.getText().?.content);
    try std.testing.expectEqualStrings("120×36", f.bar.grid.getText().?.content);
    try std.testing.expectEqualStrings("—", f.bar.controls.rtt_label.getText().?.content);
    var source = try snapshot(key, "DB-A");
    source.revision = 2;
    source.hops[1].rtt_sample = .{ .request_id = 7, .duration_ms = 17, .started_ns = 1, .completed_ns = 17_000_001, .status = .ready, .cleanup = .released };
    source.target_rtt_sample = source.hops[1].rtt_sample;
    try f.update(source, false);
    try std.testing.expectEqualStrings("17ms", f.bar.controls.rtt_label.getText().?.content);
    source.hops[1].metadata.cipher_c2s = try D.details.Text(64).init("aes256-ctr");
    source.hops[1].metadata.cipher_s2c = try D.details.Text(64).init("aes128-ctr");
    const captured_info = SSH.infoSnapshot(source, false);
    try std.testing.expectEqual(@as(?u64, 17), captured_info.latency_ms);
    try std.testing.expectEqualStrings("aes256-ctr", captured_info.cipher_c2s.slice());
    try std.testing.expectEqualStrings("aes128-ctr", captured_info.cipher_s2c.slice());
    try std.testing.expect(f.bar.controls.rtt_label.parent == f.bar.controls.identity_button);
    try std.testing.expect(f.bar.controls.rtt_button.style.display == .none);
    try std.testing.expectEqual(@as(usize, 0), f.captures);
}

test "SSH status host identity keyboard capture copies original owner and context switch dismisses without focus theft" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.update(try snapshot(key, "DB-A"), false);
    f.enter(f.bar.controls.identity_button);
    try std.testing.expect(f.host.info.isVisible());
    try std.testing.expectEqualStrings("未知", f.host.info.duration.getText().?.content);
    f.enter(f.host.info.copy_button);
    try std.testing.expect(std.mem.indexOf(u8, f.copied.?, "身份：admin@db.example:22") != null);
    try std.testing.expect(f.last_key.?.eql(key));
    var next = key;
    next.owner.session.session_id = @fromBackingInt(902);
    next.operation_id += 1;
    const pane_focus = try ui.widgets.Button(.{ .label = "新页签" }).mount(f.scope, f.cx);
    try f.cx.root.?.appendChild(a, pane_focus);
    f.cx.setFocus(pane_focus);
    try f.update(try snapshot(next, "DB-B"), false);
    try std.testing.expect(!f.host.info.isVisible());
    try std.testing.expect(f.cx.isFocused(pane_focus));
    f.host.info.copyAddress();
    try std.testing.expectEqual(@as(usize, 1), f.copies);
    f.enter(f.bar.controls.identity_button);
    try std.testing.expect(f.captured.?.key.eql(next));
    try std.testing.expectEqualStrings("DB-B", f.host.info.name.getText().?.content);
}

test "SSH status host metrics remain static and collapsed state follows sidebar" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.update(try snapshot(key, "DB-A"), false);
    for ([_]*ui.Node{ f.bar.controls.encoding_button, f.bar.controls.grid_button, f.bar.controls.rtt_button }) |node| {
        try std.testing.expect(node.behavior.events.on_click == null);
        f.click(node);
        try std.testing.expect(f.host.detail.controller.popover == null);
    }
    try std.testing.expectEqual(.none, f.bar.controls.more_button.style.display);
    f.bar.controls.sidebar_width = 48;
    try f.update(try snapshot(key, "DB-A"), false);
    try std.testing.expectEqual(@as(f32, 118), f.bar.controls.identity_button.globalRect().w);
    try std.testing.expectEqual(.flex, f.bar.controls.identity_label.style.display);
}

test "SSH status host reuses a single actual log modal and keeps its captured key and focus" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.update(try snapshot(key, "DB-A"), false);
    f.enter(f.bar.controls.identity_button);
    f.enter(f.host.info.logs_button);
    try std.testing.expect(f.logs.isVisible());
    try std.testing.expect(!f.host.info.isVisible());
    try std.testing.expect(f.logs.source.?.key.eql(key));
    const focused = f.cx.focus_manager.current_focus orelse return error.NoModalFocus;
    try std.testing.expect(focused.isDescendantOf(f.logs.dialog));
    try std.testing.expectEqual(@as(usize, 1), f.captures);
    f.logs.copyLogs();
    try std.testing.expect(f.last_key.?.eql(key));
    try std.testing.expectEqualStrings("已复制连接日志", f.logs.feedback.getText().?.content);
    try f.logs.retheme();
    f.settle();
    const rebuilt_focus = f.cx.focus_manager.current_focus orelse return error.NoRebuiltModalFocus;
    try std.testing.expect(rebuilt_focus.isDescendantOf(f.logs.dialog));
    f.cx.handleKeyDown(.escape, .{});
    f.settle();
    try std.testing.expect(!f.logs.isVisible());
    try std.testing.expect(f.captured.?.key.eql(key));
}

test "SSH status host hides empty workspace actions and restores global theme with a session" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.update(try snapshot(key, "DB-A"), false);
    f.enter(f.bar.controls.identity_button);
    try std.testing.expect(f.host.info.reconnect_disabled.peek());
    var source = try snapshot(key, "DB-A");
    source.revision = 2;
    for (source.hops[0..2]) |*hop| hop.status = .released;
    try f.update(source, true);
    f.host.refreshFrozen(source, true);
    try f.host.info.flush();
    f.settle();
    try std.testing.expect(!f.host.info.reconnect_disabled.peek());
    f.enter(f.host.info.reconnect_button);
    try std.testing.expectEqual(@as(usize, 1), f.reconnects);
    try std.testing.expect(f.last_key.?.eql(key));
    try f.host.updateActive(null);
    f.settle();
    try std.testing.expect(f.bar.controls.theme_button.style.display == .none);
    try std.testing.expect(f.bar.controls.more_button.style.display == .none);
    try std.testing.expect(f.bar.controls.chain_button.style.display == .none);
    try f.update(source, true);
    try std.testing.expect(f.bar.controls.theme_button.style.display == .flex);
    f.enter(f.bar.controls.theme_button);
    try std.testing.expectEqual(@as(usize, 1), f.themes);
    try std.testing.expectEqual(f.bar.controls.theme_button, f.last_theme_trigger.?);
}

test "SSH status host projects only the original ready SFTP attachment without terminal capabilities" {
    const sessions = @import("host/session_host.zig");
    const file_owner: @import("host/identity.zig").SessionHandle = .{ .session_id = @fromBackingInt(902), .generation = 3 };
    const file_key: D.OperationKey = .{ .owner = .{ .session = file_owner }, .operation_id = 9, .attempt_id = 1 };
    const tab_id: @import("host/identity.zig").TabId = @fromBackingInt(77);
    const target: sessions.AttachmentTarget = .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) };
    var source: sessions.SessionSnapshot = .{ .handle = file_owner, .plugin_id = .sftp, .lifecycle = .attached, .target = target, .attachment = .{ .target = target, .tab_id = tab_id }, .create_operation = file_key, .close_operation = null, .create_cleanup = .not_started };
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.update(try snapshot(key, "DB-A"), false);
    f.enter(f.bar.controls.identity_button);
    try std.testing.expect(f.host.info.isVisible());
    const file = try SSH.FileActive.fromSession(file_owner, tab_id, true, source, "VM Files");
    try std.testing.expectEqual(.connected, file.state);
    try std.testing.expect(file.key.?.eql(file_key));
    f.cx.setFocus(f.bar.controls.theme_button);
    try f.host.updateFile(file);
    f.settle();
    try std.testing.expect(!f.host.info.isVisible());
    try std.testing.expect(f.host.active == null);
    try std.testing.expect(f.host.file_active.?.owner.eql(file_owner));
    try std.testing.expectEqual(f.bar.controls.theme_button, f.cx.focus_manager.current_focus.?);
    try std.testing.expectEqualStrings("已连接", f.bar.controls.identity_label.getText().?.content);
    try std.testing.expectEqualStrings("SFTP · 已连接", f.bar.controls.identity_button.behavior.interaction.a11y.?.description.?);
    try std.testing.expectEqualDeep(@import("ui/app_theme.zig").current().ok, f.bar.controls.state_dot.getIcon().?.tint);
    try std.testing.expectEqualStrings("—", f.bar.controls.rtt_label.getText().?.content);
    try std.testing.expect(f.bar.controls.disabled.peek());
    for ([_]*ui.Node{ f.bar.controls.rtt_button, f.bar.controls.encoding_button, f.bar.controls.grid_button, f.bar.controls.more_button, f.bar.chain_trigger, f.bar.socks_chip, f.bar.controls.icons[0], f.bar.controls.icons[1] }) |node| try std.testing.expectEqual(.none, node.style.display);
    try std.testing.expectEqual(.none, f.bar.controls.file_icon.style.display);
    const rect = f.bar.controls.identity_button.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 8), rect.x, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 96), rect.w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 26), rect.h, 0.1);
    f.click(f.bar.controls.identity_button);
    try std.testing.expectEqual(@as(usize, 1), f.captures);
    f.enter(f.bar.controls.theme_button);
    try std.testing.expectEqual(@as(usize, 1), f.themes);

    // Same file_ready bit must not paint a replacement generation, mismatched
    // tab, missing domain receipt, or failed lifecycle as connected.
    source.handle.generation += 1;
    try std.testing.expectEqual(.unknown, (try SSH.FileActive.fromSession(file_owner, tab_id, true, source, "VM Files")).state);
    source.handle = file_owner;
    source.attachment.?.tab_id = @fromBackingInt(78);
    try std.testing.expectEqual(.unknown, (try SSH.FileActive.fromSession(file_owner, tab_id, true, source, "VM Files")).state);
    source.attachment.?.tab_id = tab_id;
    try std.testing.expectEqual(.unknown, (try SSH.FileActive.fromSession(file_owner, tab_id, false, source, "VM Files")).state);
    try std.testing.expectEqual(.unknown, (try SSH.FileActive.fromSession(file_owner, tab_id, true, null, "VM Files")).state);
    source.lifecycle = .failed;
    try f.host.updateFile(try SSH.FileActive.fromSession(file_owner, tab_id, true, source, "VM Files"));
    f.settle();
    try std.testing.expectEqualStrings("已断开", f.bar.controls.identity_label.getText().?.content);
    try std.testing.expectEqualStrings("SFTP · 已断开", f.bar.controls.identity_button.behavior.interaction.a11y.?.description.?);
    try std.testing.expectEqualDeep(@import("ui/app_theme.zig").current().fg_3, f.bar.controls.state_dot.getIcon().?.tint);

    try f.update(try snapshot(key, "DB-A"), false);
    try std.testing.expect(f.host.file_active == null);
    for ([_]*ui.Node{ f.bar.controls.rtt_label, f.bar.controls.encoding_button, f.bar.controls.grid_button, f.bar.chain_trigger, f.bar.socks_chip }) |node| try std.testing.expectEqual(.flex, node.style.display);
    try std.testing.expectEqual(.none, f.bar.controls.icons[1].style.display);
    try std.testing.expectEqual(.none, f.bar.controls.file_icon.style.display);
    try std.testing.expectEqualStrings("已连接", f.bar.controls.identity_label.getText().?.content);
    try std.testing.expectEqualStrings("UTF-8", f.bar.controls.encoding_label.getText().?.content);
    try std.testing.expectEqualStrings("120×36", f.bar.grid.getText().?.content);
    f.enter(f.bar.controls.identity_button);
    try std.testing.expectEqual(@as(usize, 2), f.captures);
    try std.testing.expect(f.captured.?.key.eql(key));
}

test "SSH status host failed ended and closed lifecycle override unfinished hops and a new generation starts clean" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var source = try snapshot(key, "failed target");
    try f.update(source, false);
    try std.testing.expectEqualStrings("已连接", f.bar.controls.identity_label.getText().?.content);
    source.hops[0].status = .released;
    source.hops[1].status = .not_attempted;
    for ([_]@FieldType(@import("host/session_host.zig").SessionSnapshot, "lifecycle"){ .failed, .ended, .closed }) |lifecycle| {
        const active = SSH.Active.fromTerminal(source, null, false).withLifecycle(lifecycle);
        try std.testing.expect(active.ended);
        try f.host.updateActive(active);
        f.settle();
        try std.testing.expectEqualStrings("已断开", f.bar.controls.identity_label.getText().?.content);
        try std.testing.expectEqualStrings("—", f.bar.controls.rtt_label.getText().?.content);
        f.enter(f.bar.controls.identity_button);
        try std.testing.expectEqual(@import("ui/status_connection_view.zig").State.disconnected, f.host.info.source.?.state);
        // A later details refresh must not turn the ended lifecycle back into
        // an apparent in-progress connection or depend on retry permission.
        f.host.refreshFrozen(source, false);
        try f.host.info.flush();
        try std.testing.expectEqual(@import("ui/status_connection_view.zig").State.disconnected, f.host.info.source.?.state);
        f.host.info.dismiss();
    }
    var reconnect_key = key;
    reconnect_key.owner.session = try key.owner.session.nextGeneration();
    reconnect_key.operation_id += 1;
    var reconnect = try snapshot(reconnect_key, "new generation");
    for (reconnect.hops[0..2]) |*hop| hop.status = .negotiating;
    try f.host.updateActive(SSH.Active.fromTerminal(reconnect, null, false).withLifecycle(.creating));
    f.settle();
    try std.testing.expect(!f.host.active.?.ended);
    try std.testing.expectEqualStrings("连接中", f.bar.controls.identity_label.getText().?.content);
    for (reconnect.hops[0..2]) |*hop| hop.status = .online;
    reconnect.revision += 1;
    try f.host.updateActive(SSH.Active.fromTerminal(reconnect, null, false).withLifecycle(.attached));
    f.settle();
    try std.testing.expectEqualStrings("已连接", f.bar.controls.identity_label.getText().?.content);
}

test "status transfer ticker displays only the filename and retains a plain filename" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ticker = try @import("ui/status_transfer_view.zig").View.mount(f.cx, f.scope, null);
    try f.bar.progress_slot.appendChild(a, ticker.root);
    const absolute = try a.dupe(u8, "/fixture/远端目录/ticker-one.bin");
    ticker.update(absolute, "25%", "2传·0候", 0.25, false);
    a.free(absolute);
    f.settle();
    try std.testing.expectEqualStrings("ticker-one.bin", ticker.name.getText().?.content);
    try std.testing.expectEqualStrings("25%", ticker.percent.getText().?.content);
    ticker.update("普通文件.txt", "50%", "1传·0候", 0.5, true);
    f.settle();
    try std.testing.expectEqualStrings("普通文件.txt", ticker.name.getText().?.content);
    try std.testing.expectEqualStrings("50%", ticker.percent.getText().?.content);
    try std.testing.expectEqual(@as(f32, 124), ticker.fill.style.width.px);
    ticker.update("传输 · 空闲", "", "", 0, false);
    f.settle();
    const trigger = ticker.root.globalRect();
    const label = ticker.name.globalRect();
    try std.testing.expectEqual(@as(f32, 11), ticker.name.getText().?.font_size);
    try std.testing.expect(trigger.w < 140);
    try std.testing.expectApproxEqAbs(@as(f32, 7), trigger.x + trigger.w - label.x - label.w, 0.1);
}

test "SSH chain bottom bar reports online negotiating and disconnected without opening a card" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const C = @import("ui/socks_info_styles.zig");
    var source = try snapshot(key, "DB-A");
    try f.update(source, false);
    f.settle();
    try std.testing.expect(!f.host.info.isVisible());
    try std.testing.expectEqualStrings("连接链路", f.bar.controls.chain_label.getText().?.content);
    try std.testing.expectEqual(C.theme.current().fg_1, f.bar.controls.chain_label.getText().?.color);
    for (f.bar.controls.chain_button.children.items) |child| if (child.getIcon()) |icon| {
        try std.testing.expectEqual(C.statusBarInk(C.text(.success)), icon.tint);
    };
    source.hops[source.hop_count - 1].status = .negotiating;
    source.revision += 1;
    try f.update(source, false);
    f.settle();
    try std.testing.expectEqualStrings("连接链路", f.bar.controls.chain_label.getText().?.content);
    try std.testing.expectEqual(C.theme.current().fg_1, f.bar.controls.chain_label.getText().?.color);
    for (f.bar.controls.chain_button.children.items) |child| if (child.getIcon()) |icon| {
        try std.testing.expectEqual(C.statusBarInk(C.text(.warning)), icon.tint);
    };
    try f.host.updateActive(.{ .details = source, .ended = true });
    f.settle();
    try std.testing.expectEqualStrings("连接链路", f.bar.controls.chain_label.getText().?.content);
    try std.testing.expectEqual(C.theme.current().fg_1, f.bar.controls.chain_label.getText().?.color);
    for (f.bar.controls.chain_button.children.items) |child| if (child.getIcon()) |icon| {
        try std.testing.expectEqual(C.statusBarInk(C.text(.danger)), icon.tint);
    };
    try std.testing.expect(!f.host.info.isVisible());
}

test "SSH status theme name follows committed display name and fits long names" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.update(try snapshot(key, "DB-A"), false);
    const controls = f.bar.controls;
    const short_width = controls.theme_button.globalRect().w;
    const long_name = "自定义配色 · Catppuccin Mocha Extended";
    try controls.setThemeName(f.cx, long_name);
    f.settle();
    try std.testing.expectEqualStrings(long_name, controls.theme_label.getText().?.content);
    const button = controls.theme_button.globalRect();
    const label = controls.theme_label.globalRect();
    try std.testing.expect(button.w > short_width);
    try std.testing.expectApproxEqAbs(@as(f32, 27), label.x - button.x, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 7), button.x + button.w - label.x - label.w, 0.1);
    try controls.setThemeName(f.cx, "Sauber");
    f.settle();
    try std.testing.expectApproxEqAbs(short_width, controls.theme_button.globalRect().w, 0.1);
}
