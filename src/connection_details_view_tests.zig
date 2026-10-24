//! Real Popover/Modal/widgets over the frozen production snapshot. No window,
//! native SSH session or fabricated network completion is involved.
const std = @import("std");
const ui = @import("ui");
const D = @import("ui/connection_details_view.zig");
const S = @import("ui/connection_details_styles.zig");
const theme = @import("ui/app_theme.zig");
const a = std.testing.allocator;
const key: D.OperationKey = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(73), .generation = 1 } }, .operation_id = 16, .attempt_id = 1 };

fn snapshot(count: usize) !D.Snapshot {
    var source: D.Snapshot = .{ .key = key, .revision = 1, .source = .session, .hops = @splat(.{}), .hop_count = count, .target_rtt_sample = null, .sampled_at = null };
    for (source.hops[0..count], 0..) |*hop, index| {
        hop.configured = true;
        hop.status = .online;
        hop.endpoint = .{ .host = try D.details.Text(1024).init(if (index + 1 == count) "db.example" else "bastion.example"), .user = try D.details.Text(256).init(if (index + 1 == count) "admin" else "ops"), .name = try D.details.Text(512).init(if (index + 1 == count) "DB-Master" else "Bastion"), .asset_owner = .{ .id = @fromBackingInt(@intCast(index + 1)), .revision = 4 } };
        hop.metadata = .{ .host_key_algorithm = try D.details.Text(64).init("ssh-ed25519"), .fingerprint = try D.details.Text(128).init("SHA256:actual_frozen_fingerprint"), .cipher_c2s = try D.details.Text(64).init("aes256-gcm@openssh.com"), .cipher_s2c = try D.details.Text(64).init("chacha20-poly1305@openssh.com"), .accepted_auth_methods = .init(.{ .private_key = true, .keyboard_interactive = true }) };
        hop.rtt_sample = .{ .request_id = 8, .started_ns = 100, .completed_ns = 8_000_100, .duration_ms = @intCast(index + 1), .status = .ready, .cleanup = .released };
    }
    source.target_rtt_sample = source.hops[count - 1].rtt_sample;
    return source;
}
const Fixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    trigger: *ui.Node,
    view: *D.View,
    samples: usize = 0,
    cancellations: usize = 0,
    copies: usize = 0,
    edits: usize = 0,
    log_calls: usize = 0,
    last_key: ?D.OperationKey = null,
    last_request: ?u64 = null,
    last_asset: ?@import("host/identity.zig").AssetOwner = null,
    copied: ?[]u8 = null,
    copy_error: bool = false,
    fn init(self: *Fixture) !void {
        self.* = .{ .cx = try ui.Cx.init(a, std.testing.io), .scope = undefined, .trigger = undefined, .view = undefined };
        self.cx.setViewport(1440, 900);
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill() }, .{});
        self.scope = try ui.Scope.init(a, null, self.cx.owner);
        self.trigger = try ui.widgets.Button(.{ .a11y_label = "通信链路", .base_style = S.trigger(), .hover_style = S.triggerHover() }).mount(self.scope, self.cx);
        self.trigger.setStyleInline(a, .{ .position = .absolute, .inset = .{ .right = .{ .px = 12 }, .bottom = .{ .px = 12 } } });
        try self.cx.root.?.appendChild(a, self.trigger);
        self.view = try D.View.mount(self.cx, self.scope, .{ .context = self, .request_sample = request, .cancel_sample = cancel, .copy = copy, .logs = logs, .edit = edit });
        try self.cx.root.?.appendChild(a, self.view.root);
        self.cx.layout();
    }
    fn deinit(self: *Fixture) void {
        self.scope.dispose();
        self.cx.deinit();
        if (self.copied) |value| a.free(value);
    }
    fn show(self: *Fixture, source: D.Snapshot) !void {
        try self.view.show(source, self.trigger, 860);
        self.cx.layout();
    }
    fn request(raw: *anyopaque, captured: D.OperationKey, hop: ?usize) !u64 {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        try std.testing.expect(hop == null);
        self.samples += 1;
        self.last_key = captured;
        return 42;
    }
    fn cancel(raw: *anyopaque, captured: D.OperationKey, id: u64) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.cancellations += 1;
        self.last_key = captured;
        self.last_request = id;
    }
    fn copy(raw: *anyopaque, captured: D.OperationKey, text: []const u8) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (self.copy_error) return error.ClipboardUnavailable;
        const own = try a.dupe(u8, text);
        if (self.copied) |previous| a.free(previous);
        self.copied = own;
        self.copies += 1;
        self.last_key = captured;
    }
    fn logs(raw: *anyopaque, captured: D.OperationKey) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.log_calls += 1;
        self.last_key = captured;
    }
    fn edit(raw: *anyopaque, captured: D.OperationKey, owner: @import("host/identity.zig").AssetOwner) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.edits += 1;
        self.last_key = captured;
        self.last_asset = owner;
    }
    fn click(self: *Fixture, node: *ui.Node) void {
        _ = self.cx.dispatcher.dispatch(.{ .click = .{ .x = 0, .y = 0 } }, node);
    }
};

fn findId(node: *ui.Node, id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |test_id| if (std.mem.eql(u8, id, test_id)) return node;
    for (node.children.items) |child| if (findId(child, id)) |found| return found;
    return null;
}
fn hasText(node: *ui.Node, text: []const u8) bool {
    if (node.getText()) |value| if (std.mem.indexOf(u8, value.content, text) != null) return true;
    for (node.children.items) |child| if (hasText(child, text)) return true;
    return false;
}

test "connection details view copies direct and ordered route facts at the three Figma heights" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    for (1..4) |count| {
        var source = try snapshot(count);
        source.revision = count;
        try f.show(source);
        try std.testing.expectEqual(@as(f32, 560), f.view.chrome.globalRect().w);
        try std.testing.expectEqual(S.height(count), f.view.chrome.globalRect().h);
        try std.testing.expectEqual(count + 1, f.view.row_count);
        try std.testing.expectEqual(@as(f32, 46), f.view.rows[1].?.globalRect().h);
        try std.testing.expectApproxEqAbs(@as(f32, 32), f.view.row_names[1].?.globalRect().x - f.view.rows[1].?.globalRect().x, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 5), f.view.row_names[1].?.globalRect().y - f.view.rows[1].?.globalRect().y, 0.01);
        try std.testing.expectEqual(@as(f32, 332), f.view.source_label.?.parent.?.globalRect().w);
        try std.testing.expectEqualStrings("DB-Master", f.view.row_names[count].?.getText().?.content);
        source.hops[count - 1].endpoint.name.bytes[0] = 'x';
        try std.testing.expectEqualStrings("DB-Master", f.view.row_names[count].?.getText().?.content);
        try std.testing.expect(hasText(f.view.chrome, "admin@db.example:22"));
        try std.testing.expect(hasText(f.view.chrome, "交互认证"));
        try std.testing.expect(!hasText(f.view.chrome, "OTP"));
    }
    try std.testing.expectEqual(@as(usize, 1), f.samples);
}

test "connection details view rejects other owners old revisions and stale generations without replacing the capture" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var source = try snapshot(2);
    try f.show(source);
    source.key.owner.session.session_id = @fromBackingInt(888);
    try std.testing.expectError(error.DetailsOwnerMismatch, f.view.update(source));
    source = try snapshot(2);
    source.revision = 0;
    try std.testing.expectError(error.StaleDetails, f.view.update(source));
    f.view.invalidate(source.key);
    try f.view.flush();
    try std.testing.expect(f.view.isVisible());
    try std.testing.expectEqualStrings("已过期", f.view.source_status.?.getText().?.content);
    try std.testing.expectEqualStrings("已过期", f.view.rtt_label.?.getText().?.content);
    try std.testing.expect(!hasText(f.view.chrome, "在线"));
    try std.testing.expectEqual(D.details.Status.online, f.view.source.?.hops[0].status);
    try std.testing.expectError(error.StaleDetails, f.view.update(try snapshot(2)));
    try std.testing.expectEqual(@as(usize, 1), f.cancellations);
    try std.testing.expect(f.last_key.?.eql(key));
}

test "connection details view uses only the real target sample and shows pending unavailable or unconfirmed cleanup" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var source = try snapshot(3);
    source.hops[0].rtt_sample.?.duration_ms = 100;
    source.hops[1].rtt_sample.?.duration_ms = 200;
    source.hops[2].rtt_sample.?.duration_ms = 7;
    source.target_rtt_sample = source.hops[2].rtt_sample;
    try f.show(source);
    try std.testing.expectEqualStrings("7ms", f.view.rtt_label.?.getText().?.content);
    source.revision += 1;
    source.hops[2].rtt_sample.?.status = .pending;
    source.target_rtt_sample = null;
    try f.view.update(source);
    try f.view.flush();
    try std.testing.expectEqualStrings("采样中", f.view.rtt_label.?.getText().?.content);
    source.revision += 1;
    source.hops[2].rtt_sample.?.status = .unavailable;
    try f.view.update(source);
    try f.view.flush();
    try std.testing.expectEqualStrings("不可用", f.view.rtt_label.?.getText().?.content);
    source.revision += 1;
    source.hops[2].rtt_sample.?.status = .ready;
    source.hops[2].rtt_sample.?.cleanup = .unknown;
    try f.view.update(source);
    try f.view.flush();
    try std.testing.expectEqualStrings("待核实", f.view.rtt_label.?.getText().?.content);
    try std.testing.expect(D.usableTarget(source) == null);
}

test "connection details view released test and missing metadata cannot advertise online or a live RTT" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var source = try snapshot(1);
    source.key.owner = .app;
    source.source = .@"test";
    source.hops[0].status = .released;
    source.hops[0].metadata = .{};
    try f.show(source);
    try std.testing.expectEqualStrings("最近检测", f.view.source_label.?.getText().?.content);
    try std.testing.expectEqualStrings("已释放", f.view.source_status.?.getText().?.content);
    try std.testing.expectEqualStrings("—", f.view.rtt_label.?.getText().?.content);
    try std.testing.expect(!hasText(f.view.chrome, "在线"));
    try std.testing.expect(hasText(f.view.chrome, "未知"));
    try std.testing.expectEqual(@as(usize, 0), f.samples);
}

test "connection details view click callbacks capture key asset and exact own sample once" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const source = try snapshot(2);
    try f.show(source);
    try f.show(source);
    try std.testing.expectEqual(@as(usize, 1), f.samples);
    f.click(findId(f.view.chrome, "connection.details.logs").?);
    f.click(findId(f.view.chrome, "connection.details.edit").?);
    try std.testing.expectEqual(@as(usize, 1), f.log_calls);
    try std.testing.expectEqual(@as(usize, 1), f.edits);
    try std.testing.expectEqual(@as(u64, 2), @backingInt(f.last_asset.?.id));
    try std.testing.expectEqual(@as(u64, 4), f.last_asset.?.revision);
    try std.testing.expect(f.last_key.?.eql(key));
    f.view.hide();
    f.view.hide();
    try std.testing.expectEqual(@as(usize, 1), f.cancellations);
    try std.testing.expectEqual(@as(?u64, 42), f.last_request);
}

test "connection details view native widgets defer node mount and preserve full fingerprints and both cipher directions" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var source = try snapshot(2);
    source.hops[0].endpoint.host = try D.details.Text(1024).init("2001:db8::1");
    try f.show(source);
    f.click(f.view.rows[1].?);
    try std.testing.expect(f.view.node_modal == null);
    try f.view.flush();
    f.cx.layout();
    try std.testing.expect(f.view.node_open.peek());
    try std.testing.expectEqual(@as(f32, 430), f.view.node_modal.?.dialog.globalRect().w);
    for (0..4) |_| {
        _ = f.cx.render();
        f.cx.layout();
    }
    try std.testing.expect(f.view.node_modal.?.dialog.globalRect().h <= 370);
    const dialog_rect = f.view.node_modal.?.dialog.globalRect();
    const body_rect = f.view.node_modal.?.body.globalRect();
    try std.testing.expectApproxEqAbs(dialog_rect.x, body_rect.x, 0.01);
    try std.testing.expectEqual(@as(f32, 430), body_rect.w);
    const done_rect = findId(f.view.node_modal.?.body, "connection.details.node-done").?.globalRect();
    try std.testing.expectEqual(@as(f32, 34), done_rect.h);
    try std.testing.expect(done_rect.y + done_rect.h <= dialog_rect.y + dialog_rect.h - 12);
    const node_scroll = findId(f.view.node_modal.?.body, "connection.details.node-scroll").?;
    const node_content = findId(f.view.node_modal.?.body, "connection.details.node-content").?;
    const scroll_rect = node_scroll.globalRect();
    try std.testing.expect(scroll_rect.h <= 270);
    try std.testing.expect(node_content.globalRect().h >= scroll_rect.h);
    f.cx.handleScroll(.{ .x = scroll_rect.x + 20, .y = scroll_rect.y + 20, .dx = 0, .dy = -500 });
    f.cx.layout();
    if (node_content.globalRect().h > scroll_rect.h) try std.testing.expect(node_content.style.translate_y < 0) else try std.testing.expectApproxEqAbs(@as(f32, 0), node_content.style.translate_y, 0.1);
    try std.testing.expectEqual(done_rect, findId(f.view.node_modal.?.body, "connection.details.node-done").?.globalRect());
    try std.testing.expectEqualStrings("SHA256:actual_frozen_fingerprint", f.view.node_fingerprint.?.getText().?.content);
    try std.testing.expect(hasText(f.view.node_modal.?.body, "ops@[2001:db8::1]:22"));
    try std.testing.expect(hasText(f.view.node_modal.?.body, "aes256-gcm@openssh.com"));
    try std.testing.expect(hasText(f.view.node_modal.?.body, "chacha20-poly1305@openssh.com"));
    f.view.copyFingerprint();
    try std.testing.expectEqualStrings("SHA256:actual_frozen_fingerprint", f.copied.?);
    f.click(findId(f.view.node_modal.?.body, "connection.details.node-done").?);
    try std.testing.expect(!f.view.node_open.peek());
    try std.testing.expect(f.view.isVisible());
}

test "connection details view report copy uses captured metadata and actual clipboard acknowledgement" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.show(try snapshot(3));
    f.view.copyReport();
    try std.testing.expectEqual(@as(usize, 1), f.copies);
    try std.testing.expect(std.mem.indexOf(u8, f.copied.?, "1. Bastion") != null);
    try std.testing.expect(std.mem.indexOf(u8, f.copied.?, "3. DB-Master") != null);
    try std.testing.expect(std.mem.indexOf(u8, f.copied.?, "SHA256:actual_frozen_fingerprint") != null);
    try std.testing.expectEqualStrings("已复制链路", f.view.feedback_label.?.getText().?.content);
    f.copy_error = true;
    f.view.copyReport();
    try std.testing.expectEqual(@as(usize, 1), f.copies);
    try std.testing.expectEqualStrings("复制失败，请重试", f.view.feedback_label.?.getText().?.content);
}

test "connection details view small viewport keeps a bounded scroll region and retheme preserves its owner" {
    const previous = theme.currentName();
    defer theme.select(previous);
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.cx.setViewport(480, 480);
    f.cx.layout();
    try f.view.show(try snapshot(9), f.trigger, 440);
    f.cx.layout();
    try std.testing.expect(f.view.chrome.globalRect().w <= 464);
    try std.testing.expect(f.view.chrome.globalRect().h <= 426);
    try std.testing.expectApproxEqAbs(f.view.pointer.?.style.inset().left.px, f.view.pointer.?.globalRect().x - f.view.chrome.globalRect().x, 0.01);
    const first = f.view.chrome.getBackground();
    theme.select(.light);
    try f.view.retheme();
    try std.testing.expect(!std.meta.eql(first, f.view.chrome.getBackground()));
    try std.testing.expect(f.view.source.?.key.eql(key));
    try std.testing.expectEqual(@as(usize, 1), f.samples);
    try std.testing.expectEqual(@as(f32, 28), S.trigger().width.?.px);
    try std.testing.expectEqual(@as(f32, 26), S.trigger().height.?.px);
}

test "connection details view disposes focused route and node hints before their scoped signals" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.show(try snapshot(2));
    f.cx.setFocus(findId(f.view.chrome, "connection.details.copy").?);
    try f.view.retheme();
    f.cx.layout();
    f.click(f.view.rows[1].?);
    try f.view.flush();
    f.cx.layout();
    f.cx.setFocus(findId(f.view.node_modal.?.body, "connection.details.copy-fingerprint").?);
    // Fixture disposal deliberately retains node-modal focus until its view guard runs.
    try std.testing.expect(f.view.source.?.key.eql(key));
}

test "connection details view protocol switch dismisses its original sample without stealing new pane focus" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.show(try snapshot(1));
    const destination = try ui.widgets.Button(.{ .label = "Files" }).mount(f.scope, f.cx);
    try f.cx.root.?.appendChild(a, destination);
    f.cx.setFocus(destination);
    f.view.dismiss();
    f.cx.layout();
    try std.testing.expect(!f.view.isVisible());
    try std.testing.expectEqual(destination, f.cx.focus_manager.current_focus.?);
    try std.testing.expectEqual(@as(usize, 1), f.cancellations);
    try std.testing.expect(f.last_key.?.eql(key));
    f.view.dismiss();
    try std.testing.expectEqual(@as(usize, 1), f.cancellations);
}
