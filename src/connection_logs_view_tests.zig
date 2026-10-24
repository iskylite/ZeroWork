//! Actual Modal, Button and ScrollArea layout over copied connection records.
//! No native window, transport, session cancellation or system clipboard.
const std = @import("std");
const ui = @import("ui");
const Logs = @import("ui/connection_logs_view.zig");
const S = @import("ui/connection_logs_styles.zig");
const theme = @import("ui/app_theme.zig");
const a = std.testing.allocator;
const key: Logs.OperationKey = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(73), .generation = 1 } }, .operation_id = 16, .attempt_id = 1 };

fn record(captured: Logs.OperationKey, sequence: u64) Logs.LogRecord {
    var value: Logs.LogRecord = .{ .key = captured, .entry = .{ .sequence = sequence, .timestamp_ns = @as(i128, sequence) * 50 * std.time.ns_per_ms, .hop = 0, .hop_count = 1, .port = 22, .phase = .ready, .status = .succeeded } };
    const host = "db.example";
    @memcpy(value.entry.host[0..host.len], host);
    value.entry.host_len = host.len;
    return value;
}
fn snapshot(records: []const Logs.LogRecord) !Logs.Snapshot {
    return .{ .key = key, .records = records, .endpoint = .{ .name = try Logs.details.Text(512).init("DB-Master"), .host = try Logs.details.Text(1024).init("db.example"), .user = try Logs.details.Text(256).init("admin") } };
}
const Fixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    view: *Logs.View,
    copies: usize = 0,
    copy_error: bool = false,
    copied: ?[]u8 = null,
    last_key: ?Logs.OperationKey = null,
    fn init(self: *Fixture) !void {
        self.* = .{ .cx = try ui.Cx.init(a, std.testing.io), .scope = undefined, .view = undefined };
        self.cx.setViewport(1440, 900);
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill() }, .{});
        self.scope = try ui.Scope.init(a, null, self.cx.owner);
        self.view = try Logs.View.mount(self.cx, self.scope, .{ .context = self, .copy_logs = copy });
    }
    fn deinit(self: *Fixture) void {
        self.scope.dispose();
        self.cx.deinit();
        if (self.copied) |text| a.free(text);
    }
    fn copy(raw: *anyopaque, captured: Logs.OperationKey, text: []const u8) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (self.copy_error) return error.ClipboardUnavailable;
        const owned = try a.dupe(u8, text);
        if (self.copied) |old| a.free(old);
        self.copied = owned;
        self.copies += 1;
        self.last_key = captured;
    }
    fn settle(self: *Fixture) !void {
        self.cx.layout();
        try self.view.flush();
        self.cx.layout();
    }
    fn show(self: *Fixture, source: Logs.Snapshot) !void {
        try self.view.show(source);
        try self.settle();
    }
    fn click(self: *Fixture, node: *ui.Node) void {
        _ = self.cx.dispatcher.dispatch(.{ .click = .{ .x = 0, .y = 0 } }, node);
    }
};
fn contains(node: *ui.Node, text: []const u8) bool {
    return std.mem.indexOf(u8, node.getText().?.content, text) != null;
}

test "connection logs view copies input records and uses the existing well dimensions and typography" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var records = [_]Logs.LogRecord{ record(key, 0), record(key, 1), record(key, 2) };
    var source = try snapshot(&records);
    try f.show(source);
    records[0].entry.host[0] = 'x';
    source.endpoint.name.bytes[0] = 'x';
    try std.testing.expectEqualStrings("db.example", f.view.source.?.records[0].entry.hostSlice());
    try std.testing.expectEqualStrings("DB-Master", f.view.source.?.endpoint.name.slice());
    try std.testing.expect(contains(f.view.identity, "DB-Master · admin@db.example:22"));
    try std.testing.expect(contains(f.view.meta, "只读 · 尝试 1 · 3 条记录"));
    try std.testing.expect(!contains(f.view.meta, "连接中"));
    try std.testing.expectEqual(@as(f32, 760), f.view.dialog.globalRect().w);
    try std.testing.expectEqual(S.height, f.view.dialog.globalRect().h);
    try std.testing.expectEqual(@as(f32, 736), f.view.logs_scroll.container.globalRect().w);
    try std.testing.expectEqual(@as(f32, 124), f.view.logs_scroll.container.globalRect().h);
    try std.testing.expectApproxEqAbs(@as(f32, 12), f.view.logs_text.globalRect().x - f.view.logs_scroll.content.globalRect().x, 0.01);
    try std.testing.expectEqual(@as(f32, 10.5), f.view.logs_text.getText().?.font_size);
    try std.testing.expectEqual(@as(f32, 16.0 / 10.5), f.view.logs_text.getText().?.line_height);
    try std.testing.expect(f.view.logs_text.getText().?.use_monospace_font);
    try std.testing.expect(f.view.root.parent != null);
}

test "connection logs view rejects foreign keys older revisions and changed endpoints" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const records = [_]Logs.LogRecord{record(key, 0)};
    var source = try snapshot(&records);
    source.revision = 3;
    try f.show(source);
    var other = source;
    other.key.owner.session.session_id = @fromBackingInt(88);
    other.records = &.{};
    try std.testing.expectError(error.LogOwnerMismatch, f.view.update(other));
    other = source;
    other.revision = 2;
    try std.testing.expectError(error.StaleLogs, f.view.update(other));
    other = source;
    other.revision = 4;
    other.endpoint.host = try Logs.details.Text(1024).init("different.example");
    try std.testing.expectError(error.FrozenEndpointChanged, f.view.update(other));
    other = source;
    other.records = &.{};
    try f.view.update(other);
    try std.testing.expectEqual(@as(usize, 1), f.view.source.?.records.len);
    try std.testing.expectEqual(@as(u64, 3), f.view.source.?.revision);
    try std.testing.expect(f.view.source.?.key.eql(key));
}

test "connection logs view reports only real clipboard success for its captured key and close has no side effects" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var records = [_]Logs.LogRecord{record(key, 0)};
    records[0].entry.phase = .authentication;
    records[0].entry.status = .failed;
    records[0].entry.failure = error.AuthenticationFailed;
    var source = try snapshot(&records);
    source.endpoint.host = try Logs.details.Text(1024).init("2001:db8::1");
    source.dropped = 11;
    try f.show(source);
    f.click(f.view.copy_button);
    try std.testing.expectEqual(@as(usize, 1), f.copies);
    try std.testing.expect(f.last_key.?.eql(key));
    try std.testing.expect(std.mem.indexOf(u8, f.copied.?, "admin@[2001:db8::1]:22") != null);
    try std.testing.expect(std.mem.indexOf(u8, f.copied.?, "已省略 11 条旧日志") != null);
    try std.testing.expect(std.mem.indexOf(u8, f.copied.?, "服务器未接受认证信息") != null);
    try std.testing.expectEqualStrings("已复制连接日志", f.view.feedback.getText().?.content);
    f.copy_error = true;
    f.click(f.view.copy_button);
    try std.testing.expectEqual(@as(usize, 1), f.copies);
    try std.testing.expectEqualStrings("复制失败，请重试", f.view.feedback.getText().?.content);
    f.click(f.view.close_button);
    try std.testing.expect(!f.view.isVisible());
    try std.testing.expect(!f.view.open.peek());
    f.view.copyLogs();
    try std.testing.expectEqual(@as(usize, 1), f.copies);
    try std.testing.expectEqual(@as(usize, 1), f.view.source.?.records.len);
}

test "connection logs view expired captures remain readable and cannot be revived or retargeted" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const records = [_]Logs.LogRecord{record(key, 0)};
    var source = try snapshot(&records);
    try f.show(source);
    var foreign = key;
    foreign.operation_id += 1;
    f.view.invalidate(foreign);
    try std.testing.expect(!f.view.invalidated);
    f.view.invalidate(key);
    try f.view.flush();
    try std.testing.expect(contains(f.view.meta, "已过期"));
    try std.testing.expect(f.view.isVisible());
    source.revision = 2;
    source.records = &.{};
    try std.testing.expectError(error.StaleLogs, f.view.update(source));
    f.view.hide();
    try f.show(source);
    try std.testing.expect(f.view.invalidated);
    try std.testing.expectEqual(@as(usize, 1), f.view.source.?.records.len);
    f.view.copyLogs();
    try std.testing.expect(std.mem.indexOf(u8, f.copied.?, "已过期") != null);
    try std.testing.expect(f.last_key.?.eql(key));
    var next_key = key;
    next_key.owner.session.generation += 1;
    next_key.operation_id += 1;
    next_key.attempt_id = 2;
    const next_records = [_]Logs.LogRecord{record(next_key, 0)};
    source.key = next_key;
    source.revision = 1;
    source.records = &next_records;
    try f.show(source);
    try std.testing.expect(!f.view.invalidated);
    f.click(f.view.copy_button);
    try std.testing.expect(f.last_key.?.eql(next_key));
}

test "connection logs view preserves retry history while rejecting foreign history and reversed sequence" {
    var next_key = key;
    next_key.owner.session.generation = 2;
    next_key.operation_id = 17;
    next_key.attempt_id = 2;
    var records = [_]Logs.LogRecord{ record(key, 0), record(key, 1), record(next_key, 0) };
    var source = try snapshot(&records);
    source.key = next_key;
    try Logs.validate(source);
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.show(source);
    try std.testing.expect(contains(f.view.logs_text, "尝试 1 · #1"));
    try std.testing.expect(contains(f.view.logs_text, "尝试 2 · #0"));
    records[0].key.owner.session.session_id = @fromBackingInt(88);
    try std.testing.expectError(error.InvalidLogOwner, Logs.validate(source));
    records[0] = record(key, 2);
    try std.testing.expectError(error.InvalidLogOrder, Logs.validate(source));
    records[0] = record(key, 0);
    records[0].key.owner.session.generation = 2;
    try std.testing.expectError(error.InvalidLogOwner, Logs.validate(source));
    source.records = &.{};
    source.key = .{ .owner = .app, .operation_id = 44, .attempt_id = 1 };
    try Logs.validate(source);
    var app_record = record(source.key, 0);
    app_record.key.operation_id = 45;
    source.records = (&app_record)[0..1];
    try std.testing.expectError(error.InvalidLogOwner, Logs.validate(source));
}

test "connection logs view keeps footer fixed while scrolling the bounded journal at 860 by 480" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.cx.setViewport(860, 480);
    var records: [128]Logs.LogRecord = undefined;
    for (&records, 0..) |*value, index| value.* = record(key, @intCast(index));
    var source = try snapshot(&records);
    try f.show(source);
    const footer_y = f.view.footer.globalRect().y;
    try std.testing.expectEqual(@as(f32, 124), f.view.logs_scroll.container.globalRect().h);
    try std.testing.expectEqual(@as(f32, 34), f.view.footer.globalRect().h);
    try std.testing.expectApproxEqAbs(f.view.dialog.globalRect().y + f.view.dialog.globalRect().h - 12, footer_y + 34, 0.01);
    try std.testing.expect(f.view.logs_scroll.state.maxScrollY() > 0);
    try std.testing.expectApproxEqAbs(f.view.logs_scroll.state.maxScrollY(), f.view.logs_scroll.state.scroll_y, 0.01);
    ui.widgets.scroll_area.setScrollY(f.view.logs_scroll.state, f.view.logs_scroll.content, 0);
    try f.view.flush();
    try std.testing.expect(!f.view.following);
    for (&records, 0..) |*value, index| value.* = record(key, @intCast(index + 1));
    source.revision += 1;
    source.dropped = 1;
    try f.view.update(source);
    try f.settle();
    try std.testing.expectEqual(@as(usize, 1), f.view.new_records);
    try std.testing.expectEqualStrings("1 条新日志", f.view.feedback.getText().?.content);
    try std.testing.expectEqual(@as(f32, 0), f.view.logs_scroll.state.scroll_y);
    try std.testing.expectEqual(@as(@TypeOf(f.view.bottom_button.style.display), .flex), f.view.bottom_button.style.display);
    f.click(f.view.bottom_button);
    try f.settle();
    try std.testing.expect(f.view.following);
    try std.testing.expectEqual(@as(usize, 0), f.view.new_records);
    try std.testing.expectEqualStrings("", f.view.feedback.getText().?.content);
    try std.testing.expectApproxEqAbs(f.view.logs_scroll.state.maxScrollY(), f.view.logs_scroll.state.scroll_y, 0.01);
    try std.testing.expectEqual(footer_y, f.view.footer.globalRect().y);
    try std.testing.expectEqual(@as(usize, 128), f.view.source.?.records.len);
    try std.testing.expect(contains(f.view.meta, "已省略 1 条旧日志"));
}

test "connection logs view disables empty copy and rethemes without changing its frozen capture" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.show(try snapshot(&.{}));
    try std.testing.expect(f.view.copy_disabled.peek());
    try std.testing.expectEqualStrings("暂无连接阶段日志", f.view.logs_text.getText().?.content);
    f.click(f.view.copy_button);
    f.view.copyLogs();
    try std.testing.expectEqual(@as(usize, 0), f.copies);
    const original_theme = theme.currentName();
    defer theme.select(original_theme);
    const original_background = f.view.dialog.getBackground();
    theme.select(if (original_theme == .light) .dark else .light);
    try f.view.retheme();
    try f.settle();
    try std.testing.expect(!std.meta.eql(original_background, f.view.dialog.getBackground()));
    try std.testing.expect(f.view.source.?.key.eql(key));
    try std.testing.expectEqualStrings("DB-Master", f.view.source.?.endpoint.name.slice());
    f.cx.setViewport(700, 480);
    try f.view.flush();
    try f.settle();
    try std.testing.expectEqual(@as(f32, 684), f.view.dialog.globalRect().w);
    try std.testing.expectEqual(@as(f32, 34), f.view.copy_button.globalRect().h);
}
