//! Production welcome rows: constrained layout, full-title Tooltip and real
//! Button pointer/keyboard handlers, without provider or conversation storage.
const std = @import("std");
const ui = @import("ui");
const V = @import("ui/ai_empty_view.zig");
const theme = @import("ui/app_theme.zig");
const a = std.testing.allocator;
const titles = [_][]const u8{
    "请检查 Nginx 服务的 error 日志，解释这个 SSH 连接超时问题，并给出每一步的排查方法与处理建议 Please inspect the complete application error log and explain the connection timeout in detail",
    "👩🏽‍💻 检查宽字符 ＡＢＣＤＥＦＧ 与中文日志 🧑‍🚀🚀🌍，保留整个原始问题并检查所有错误信息，尤其是终端输出中的启动失败 👩🏽‍💻 检查宽字符 ＡＢＣＤＥＦＧ 与中文日志 🧑‍🚀🚀🌍",
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
};
const Fixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    view: *ui.Node,
    clicks: usize = 0,
    selected: ?u64 = null,
    fn init(self: *Fixture, title: []const u8) !void {
        self.* = .{ .cx = try ui.Cx.init(a, std.testing.io), .scope = undefined, .view = undefined };
        self.cx.setViewport(600, 276);
        self.cx.setTheme(theme.widgetTheme(theme.currentName()));
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill(), .direction = .column, .padding = .{ .left = 14, .right = 14 } }, .{});
        self.scope = try ui.Scope.init(a, null, self.cx.owner);
        self.view = try V.mount(self.cx, self.scope, true, .{ .context = self, .summarize = ignore, .logs = ignore, .settings = ignore, .ollama = ignore, .select = select, .recent = &.{ .{ .id = 17, .title = title }, .{ .id = 29, .title = "普通短标题" } } });
        try self.cx.root.?.appendChild(a, self.view);
        self.settle();
    }
    fn deinit(self: *Fixture) void {
        self.cx.clearFocus();
        self.scope.dispose();
        self.cx.deinit();
    }
    fn select(raw: *anyopaque, id: u64) void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.clicks += 1;
        self.selected = id;
    }
    fn ignore(_: *anyopaque) void {}
    fn settle(self: *Fixture) void {
        self.cx.setTestFrameStep(16) catch unreachable;
        for (0..4) |_| {
            self.cx.advanceFrameClock();
            _ = self.cx.render();
        }
    }
    fn node(self: *Fixture, id: []const u8) *ui.Node {
        return find(self.cx.root.?, id) orelse @panic("missing recent test node");
    }
    fn clickAt(self: *Fixture, x: f32, y: f32) void {
        self.cx.handleMouseDown(x, y, .{});
        self.cx.handleMouseUp(x, y);
        self.settle();
    }
    fn expectBounds(self: *Fixture) !void {
        const view = self.view.globalRect();
        const group = self.node("ai.empty.recent").globalRect();
        const row = self.node("ai.empty.recent.link").globalRect();
        const icon = self.node("ai.empty.recent.icon").globalRect();
        const label = self.node("ai.empty.recent.title");
        const title = label.globalRect();
        const arrow = self.node("ai.empty.recent.arrow").globalRect();
        try std.testing.expect(group.x >= view.x and group.x + group.w <= view.x + view.w + 0.1);
        try std.testing.expectApproxEqAbs(group.w, row.w, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 30), row.h, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 16), icon.w, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 16), arrow.w, 0.1);
        try std.testing.expectApproxEqAbs(icon.x + icon.w + 8, title.x, 0.1);
        try std.testing.expectApproxEqAbs(title.x + title.w + 8, arrow.x, 0.1);
        try std.testing.expectApproxEqAbs(row.x + row.w, arrow.x + arrow.w, 0.1);
        try std.testing.expectEqual(ui.types.TextOverflow.ellipsis, label.getText().?.text_overflow);
        try std.testing.expectEqual(ui.TextWrap.none, label.getText().?.wrap);
        try std.testing.expect(label.style.overflow_hidden);
        try std.testing.expect(title.w > 0 and title.h == 16);
    }
};
fn find(node: *ui.Node, id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, value, id)) return node;
    for (node.children.items) |child| if (find(child, id)) |result| return result;
    return null;
}
fn text(node: *ui.Node) []const u8 {
    if (node.getText()) |value| return value.content;
    for (node.children.items) |child| {
        const value = text(child);
        if (value.len > 0) return value;
    }
    return "";
}
test "AI welcome recent long mixed wide and unbroken titles stay bounded after resize and theme replay" {
    const previous = theme.currentName();
    defer theme.select(previous);
    for (titles) |title| {
        var f: Fixture = undefined;
        try f.init(title);
        defer f.deinit();
        for ([_]theme.Name{ .dark, .light, .sauber }) |name| {
            theme.select(name);
            f.cx.setTheme(theme.widgetTheme(name));
            for ([_]f32{ 360, 480, 600 }) |width| {
                f.cx.setViewport(width, 276);
                f.settle();
                try f.expectBounds();
                try std.testing.expectEqualStrings(title, text(f.node("ai.empty.recent.title")));
                try std.testing.expectEqualStrings(title, f.node("ai.empty.recent.link").behavior.interaction.a11y.?.label.?);
                const wrapper = f.node("ai.empty.recent.link").parent.?.parent.?;
                wrapper.behavior.events.on_hover.?.invoke();
                for (0..8) |_| f.settle();
                const tooltip = f.node("ai.empty.recent.tooltip");
                try std.testing.expect(tooltip.getOpacity() > 0.99);
                try std.testing.expect(tooltip.globalRect().w <= width - 16);
                try std.testing.expectEqualStrings(title, text(tooltip));
                wrapper.behavior.events.on_leave.?.invoke();
                for (0..5) |_| f.settle();
            }
        }
    }
}
test "AI welcome recent full title tooltip retains complete row pointer and keyboard selection" {
    var f: Fixture = undefined;
    try f.init(titles[0]);
    defer f.deinit();
    const button = f.node("ai.empty.recent.link");
    const wrapper = button.parent.?.parent.?;
    wrapper.behavior.events.on_hover.?.invoke();
    for (0..8) |_| f.settle();
    try std.testing.expectEqualStrings(titles[0], text(f.node("ai.empty.recent.tooltip")));
    const r = button.globalRect();
    for ([_]f32{ r.x + 2, r.x + r.w / 2, r.x + r.w - 2 }) |x| {
        f.clickAt(x, r.y + r.h / 2);
        try std.testing.expectEqual(@as(?u64, 17), f.selected);
    }
    f.cx.setFocus(button);
    f.cx.handleKeyDown(.@"return", .{});
    f.settle();
    try std.testing.expectEqual(@as(usize, 4), f.clicks);
    try std.testing.expectEqual(@as(?u64, 17), f.selected);
}
