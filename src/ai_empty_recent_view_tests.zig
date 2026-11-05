//! Welcome uses the same phase, binding and icon action contract as history.
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
    last_action: ?@import("ui/ai_session_row.zig").Action = null,
    fn init(self: *Fixture, title: []const u8) !void {
        self.* = .{ .cx = try ui.Cx.init(a, std.testing.io), .scope = undefined, .view = undefined };
        self.cx.setViewport(600, 276);
        self.cx.setTheme(theme.widgetTheme(theme.currentName()));
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill(), .direction = .column, .padding = .{ .left = 14, .right = 14 } }, .{});
        self.scope = try ui.Scope.init(a, null, self.cx.owner);
        self.view = try V.mount(self.cx, self.scope, true, .{ .context = self, .summarize = ignore, .logs = ignore, .settings = ignore, .ollama = ignore, .session_hooks = .{ .context = self, .select = select, .request_close = select, .remove = select, .act = act }, .recent = &.{ .{ .id = 17, .title = title, .owner = "1 · Local Terminal", .phase = .running, .bound = true, .can_copy = true, .can_remove = false }, .{ .id = 29, .title = "普通短标题", .owner = "历史连接环境", .phase = .stopped, .can_restore = true, .can_copy = true }, .{ .id = 30, .title = "不应显示第三条", .owner = "" } } });
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
    fn act(raw: *anyopaque, id: u64, action: @import("ui/ai_session_row.zig").Action) void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.last_action = action;
        select(raw, id);
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
        const row = self.node("ai.session.row.17").globalRect();
        const label = self.node("ai.session.title");
        const title = label.globalRect();
        const tag = self.node("ai.session.phase_tag").globalRect();
        const first = self.node("ai.session.first_line").globalRect();
        const second = self.node("ai.session.second_line").globalRect();
        try std.testing.expect(group.x >= view.x and group.x + group.w <= view.x + view.w + 0.1);
        try std.testing.expectApproxEqAbs(group.w, row.w, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 56), row.h, 0.1);
        try std.testing.expect(title.x + title.w <= tag.x);
        try std.testing.expectApproxEqAbs(first.x + first.w, tag.x + tag.w, 0.1);
        try std.testing.expect(first.y + first.h <= second.y);
        try std.testing.expectEqual(ui.types.TextOverflow.ellipsis, label.getText().?.text_overflow);
        try std.testing.expectEqual(ui.TextWrap.none, label.getText().?.wrap);
        try std.testing.expect(label.style.overflow_hidden);
        try std.testing.expect(title.w > 0 and title.h == 16.5);
        for ([_][]const u8{ "ai.session.jump.17", "ai.session.locate.17", "ai.session.copy_use.17" }) |id| {
            const action = self.node(id).globalRect();
            try std.testing.expectApproxEqAbs(@as(f32, 24), action.w, 0.1);
            try std.testing.expectApproxEqAbs(@as(f32, 24), action.h, 0.1);
            try std.testing.expect(action.x + action.w <= second.x + second.w + 0.1);
            try std.testing.expect(action.y >= second.y and action.y + action.h <= second.y + second.h + 0.1);
        }
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
                try std.testing.expectEqualStrings(title, text(f.node("ai.session.title")));
                const wrapper = f.node("ai.session.title").parent.?.parent.?;
                wrapper.behavior.events.on_hover.?.invoke();
                for (0..8) |_| f.settle();
                const tooltip = f.node("ai.session.title.tooltip");
                try std.testing.expect(tooltip.getOpacity() > 0.99);
                try std.testing.expect(tooltip.globalRect().w <= width - 16);
                try std.testing.expectEqualStrings(title, text(tooltip));
                wrapper.behavior.events.on_leave.?.invoke();
                for (0..5) |_| f.settle();
            }
        }
    }
}
test "AI welcome recent actions preserve history semantics and phase updates" {
    var f: Fixture = undefined;
    try f.init(titles[0]);
    defer f.deinit();
    try std.testing.expect(find(f.view, "ai.session.row.30") == null);
    try std.testing.expect(find(f.view, "ai.session.restore.17") == null);
    try std.testing.expectEqual(@as(@TypeOf(f.node("ai.session.delete.17").style.display), .none), f.node("ai.session.delete.17").style.display);
    const row = f.node("ai.session.row.17").globalRect();
    f.clickAt(row.x + 10, row.y + 10);
    try std.testing.expectEqual(@as(usize, 0), f.clicks);
    inline for (.{ "jump", "locate", "copy_use" }, .{ .view, .locate, .copy_use }) |action, expected| {
        const button = f.node("ai.session." ++ action ++ ".17");
        const rect = button.globalRect();
        f.clickAt(rect.x + rect.w / 2, rect.y + rect.h / 2);
        try std.testing.expectEqual(expected, f.last_action.?);
        try std.testing.expectEqual(@as(?u64, 17), f.selected);
    }
    const restore = f.node("ai.session.restore.29");
    f.cx.setFocus(restore);
    f.cx.handleKeyDown(.@"return", .{});
    f.settle();
    try std.testing.expectEqual(@import("ui/ai_session_row.zig").Action.restore, f.last_action.?);
    try std.testing.expectEqual(@as(?u64, 29), f.selected);
    const remove = f.node("ai.session.delete.29").globalRect();
    f.clickAt(remove.x + remove.w / 2, remove.y + remove.h / 2);
    try std.testing.expectEqual(@as(usize, 5), f.clicks);
    inline for (.{ .idle, .running, .approval, .done, .failed, .stopped }, .{ "未开始", "运行中", "待确认", "已完成", "失败", "已暂停" }) |phase, label| {
        V.updateRecentPhase(f.cx, f.view, 17, phase);
        f.settle();
        try std.testing.expectEqualStrings(label, text(f.node("ai.session.phase_tag")));
    }
}
