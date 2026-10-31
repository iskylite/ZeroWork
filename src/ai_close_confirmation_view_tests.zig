//! Real Popover/Button layout, pointer capture, keyboard and captured tickets.
//! No native window, provider, conversation store or terminal is created.
const std = @import("std");
const ui = @import("ui");
const V = @import("ui/ai_close_confirmation_view.zig");
const theme = @import("ui/app_theme.zig");
const a = std.testing.allocator;
const Fixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    view: *V.View,
    anchor: *ui.Node,
    behind: *ui.Node,
    confirms: usize = 0,
    cancels: usize = 0,
    underlying_clicks: usize = 0,
    last: ?V.Ticket = null,
    fn init(self: *Fixture, width: f32) !void {
        self.* = .{ .cx = try ui.Cx.init(a, std.testing.io), .scope = undefined, .view = undefined, .anchor = undefined, .behind = undefined };
        self.cx.setViewport(width, 360);
        self.cx.setTheme(theme.widgetTheme(theme.currentName()));
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill(), .direction = .column, .padding = .{ .top = 40, .left = 16, .right = 16 }, .gap = 16 }, .{});
        self.scope = try ui.Scope.init(a, null, self.cx.owner);
        const header = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .px = 32 }, .direction = .row, .align_items = .center, .justify = .end, .flex_shrink = 0 }, .{});
        try self.cx.root.?.appendChild(a, header);
        self.anchor = try ui.widgets.Button(.{ .label = "×", .a11y_label = "关闭助手", .base_style = .{ .width = .{ .px = 28 }, .height = .{ .px = 28 }, .padding = .{} } }).mount(self.scope, self.cx);
        try header.appendChild(a, self.anchor);
        self.view = try V.View.mount(self.cx, self.scope, self.anchor, .{ .context = self, .on_confirm = confirm, .on_cancel = cancel });
        try header.appendChild(a, self.view.root);
        self.behind = try ui.widgets.Button(.{ .label = "底层动作", .base_style = .{ .width = .{ .px = 100 }, .height = .{ .px = 28 } }, .on_click = self.cx.on(Fixture, self, underlying) }).mount(self.scope, self.cx);
        try self.cx.root.?.appendChild(a, self.behind);
        self.frame();
    }
    fn deinit(self: *Fixture) void {
        self.cx.clearFocus();
        self.scope.dispose();
        self.cx.deinit();
    }
    fn confirm(raw: *anyopaque, ticket: V.Ticket) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.confirms += 1;
        self.last = ticket;
    }
    fn cancel(raw: *anyopaque, ticket: V.Ticket) void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.cancels += 1;
        self.last = ticket;
    }
    fn underlying(self: *Fixture) void {
        self.underlying_clicks += 1;
    }
    fn show(self: *Fixture, sequence: u64, cid: u8, running: bool, enabled: bool) !V.Ticket {
        const ticket: V.Ticket = .{ .sequence = sequence, .conversation_id = .{ .bytes = @splat(cid) } };
        try self.view.update(.{ .ticket = ticket, .running = running, .enabled = enabled });
        self.frame();
        return ticket;
    }
    fn frame(self: *Fixture) void {
        self.cx.setTestFrameStep(16) catch unreachable;
        for (0..4) |_| {
            self.cx.advanceFrameClock();
            _ = self.cx.render();
        }
    }
    fn click(self: *Fixture, node: *ui.Node) void {
        const r = node.globalRect();
        self.cx.handleMouseDown(r.x + r.w / 2, r.y + r.h / 2, .{});
        self.cx.handleMouseUp(r.x + r.w / 2, r.y + r.h / 2);
        self.frame();
    }
};
fn text(node: *ui.Node) []const u8 {
    if (node.getText()) |t| return t.content;
    for (node.children.items) |child| {
        const value = text(child);
        if (value.len > 0) return value;
    }
    return "";
}
test "AI close confirmation running and idle labels confirm the captured ticket once" {
    for ([_]bool{ true, false }) |running| {
        var f: Fixture = undefined;
        try f.init(600);
        defer f.deinit();
        try std.testing.expect(!f.view.open.peek());
        const ticket = try f.show(4, 1, running, true);
        try std.testing.expectEqualStrings(if (running) "停止本轮并关闭？" else "关闭助手？", text(f.view.title));
        try std.testing.expectEqualStrings("对话和历史会保留", text(f.view.detail));
        try std.testing.expectEqualStrings(if (running) "停止并关闭" else "关闭窗口", text(f.view.confirm));
        f.click(f.view.confirm);
        try std.testing.expectEqual(@as(usize, 1), f.confirms);
        try std.testing.expectEqual(@as(usize, 0), f.cancels);
        try std.testing.expect(ticket.eql(f.last.?));
        try std.testing.expect(!f.view.open.peek());
        // A repeated host snapshot cannot revive a resolved decision.
        _ = try f.show(4, 1, running, true);
        try std.testing.expect(!f.view.open.peek());
        try f.view.update(null);
        _ = try f.show(5, 1, running, true);
        try std.testing.expect(f.view.open.peek());
    }
}
test "AI close confirmation cancel Escape and outside close without click through" {
    var f: Fixture = undefined;
    try f.init(600);
    defer f.deinit();
    _ = try f.show(1, 1, true, true);
    try std.testing.expect(f.cx.isFocused(f.view.cancel));
    f.click(f.view.cancel);
    try std.testing.expectEqual(@as(usize, 1), f.cancels);
    try std.testing.expect(f.cx.isFocused(f.anchor));
    _ = try f.show(2, 1, true, true);
    f.cx.handleKeyDown(.escape, .{});
    f.frame();
    try std.testing.expectEqual(@as(usize, 2), f.cancels);
    try std.testing.expect(!f.view.open.peek());
    _ = try f.show(3, 1, true, true);
    f.click(f.behind);
    try std.testing.expectEqual(@as(usize, 3), f.cancels);
    try std.testing.expectEqual(@as(usize, 0), f.underlying_clicks);
    try std.testing.expectEqual(@as(usize, 0), f.confirms);
    // Once dismissed the same underlying control is usable again.
    f.click(f.behind);
    try std.testing.expectEqual(@as(usize, 1), f.underlying_clicks);
}
test "AI close confirmation replacement and host dismissal revoke captured pointer press" {
    var f: Fixture = undefined;
    try f.init(320);
    defer f.deinit();
    _ = try f.show(1, 1, true, true);
    var r = f.view.confirm.globalRect();
    f.cx.handleMouseDown(r.x + r.w / 2, r.y + r.h / 2, .{});
    const current = try f.show(2, 2, true, true);
    f.cx.handleMouseUp(r.x + r.w / 2, r.y + r.h / 2);
    f.frame();
    try std.testing.expectEqual(@as(usize, 0), f.confirms);
    f.click(f.view.confirm);
    try std.testing.expectEqual(@as(usize, 1), f.confirms);
    try std.testing.expect(current.eql(f.last.?));
    _ = try f.show(3, 2, true, true);
    r = f.view.confirm.globalRect();
    f.cx.handleMouseDown(r.x + r.w / 2, r.y + r.h / 2, .{});
    try f.view.update(null);
    f.frame();
    f.cx.handleMouseUp(r.x + r.w / 2, r.y + r.h / 2);
    f.frame();
    try std.testing.expectEqual(@as(usize, 1), f.confirms);
    try std.testing.expectEqual(@as(usize, 0), f.cancels);
}
test "AI close confirmation disabled confirm still permits cancel and keyboard uses exact ticket" {
    var f: Fixture = undefined;
    try f.init(320);
    defer f.deinit();
    _ = try f.show(1, 1, false, false);
    f.click(f.view.confirm);
    try std.testing.expectEqual(@as(usize, 0), f.confirms);
    f.click(f.view.cancel);
    try std.testing.expectEqual(@as(usize, 1), f.cancels);
    const ticket = try f.show(2, 1, false, true);
    f.cx.setFocus(f.view.confirm);
    f.cx.handleKeyDown(.@"return", .{});
    f.frame();
    try std.testing.expectEqual(@as(usize, 1), f.confirms);
    try std.testing.expect(ticket.eql(f.last.?));
}
test "AI close confirmation compact geometry all themes and theme replay preserve content button widths" {
    defer theme.select(.dark);
    for ([_]theme.Name{ .dark, .light, .sauber }) |name| {
        theme.select(name);
        var f: Fixture = undefined;
        try f.init(320);
        defer f.deinit();
        _ = try f.show(1, 1, true, true);
        f.cx.setTheme(theme.widgetTheme(name));
        f.frame();
        const panel = f.view.panel.globalRect();
        try std.testing.expectEqual(@as(f32, 288), panel.w);
        try std.testing.expectApproxEqAbs(@as(f32, 106), panel.h, 0.1);
        try std.testing.expect(panel.x >= 8 and panel.x + panel.w <= 312);
        try std.testing.expectApproxEqAbs(panel.x + 12, f.view.title.globalRect().x, 0.1);
        try std.testing.expectApproxEqAbs(panel.y + 12, f.view.title.globalRect().y, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 20), f.view.title.globalRect().h, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 18), f.view.detail.globalRect().h, 0.1);
        for ([_]*ui.Node{ f.view.cancel, f.view.confirm }) |button| {
            const r = button.globalRect();
            try std.testing.expectEqual(@as(f32, 28), r.h);
            try std.testing.expect(r.w > 20 and r.w < 100);
            try std.testing.expect(r.x >= panel.x + 12 and r.x + r.w <= panel.x + panel.w - 11.9);
            try std.testing.expectApproxEqAbs(panel.y + panel.h - 12, r.y + r.h, 0.1);
        }
        try std.testing.expect(f.view.cancel.globalRect().w < f.view.confirm.globalRect().w);
    }
}

test "AI close confirmation replay of absent and unchanged snapshots does not request redraw" {
    var f: Fixture = undefined;
    try f.init(320);
    defer f.deinit();
    f.cx.needs_redraw = false;
    try f.view.update(null);
    f.view.dismiss();
    try std.testing.expect(!f.cx.needs_redraw);

    const ticket = try f.show(1, 1, true, true);
    f.cx.needs_redraw = false;
    try f.view.update(.{ .ticket = ticket, .running = true });
    try std.testing.expect(!f.cx.needs_redraw);
    try std.testing.expect(!f.view.focus_pending);

    try f.view.update(.{ .ticket = ticket, .running = false });
    try std.testing.expect(f.cx.needs_redraw);
    try std.testing.expectEqualStrings("关闭助手？", text(f.view.title));
    f.frame();
    f.cx.needs_redraw = false;
    try f.view.update(.{ .ticket = ticket, .running = false });
    try std.testing.expect(!f.cx.needs_redraw);

    f.click(f.view.cancel);
    try std.testing.expect(f.view.resolved_ticket != null);
    f.cx.needs_redraw = false;
    // Clearing the host request forgets its resolution without scheduling a
    // fresh frame for the already-closed surface.
    try f.view.update(null);
    try std.testing.expect(f.view.resolved_ticket == null);
    f.view.dismiss();
    try std.testing.expect(!f.cx.needs_redraw);
}
