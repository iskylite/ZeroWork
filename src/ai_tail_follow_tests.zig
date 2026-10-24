const std = @import("std");
const ui = @import("ui");
const Follow = @import("ui/ai_tail_follow.zig").Follow;
const a = std.testing.allocator;
const Fixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    follow: Follow,
    fn init(self: *Fixture) !void {
        const cx = try ui.Cx.init(a, std.testing.io);
        const scope = try ui.Scope.init(a, null, cx.owner);
        cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
        cx.setViewport(600, 240);
        const scroll = try ui.widgets.ScrollArea(.{ .height = 120, .direction = .vertical }).mount(scope, cx);
        scroll.container.setStyleInline(a, .{ .width = .fill(), .height = .{ .px = 120 }, .flex_shrink = 0 });
        scroll.content.setStyleInline(a, .{ .width = .fill(), .direction = .column });
        try cx.root.?.appendChild(a, scroll.container);
        self.* = .{ .cx = cx, .scope = scope, .follow = .{ .scroll = scroll } };
    }
    fn append(self: *Fixture, height: f32) !*ui.Node {
        const row = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .px = height }, .flex_shrink = 0 }, .{});
        try self.follow.scroll.content.appendChild(a, row);
        return row;
    }
    fn settle(self: *Fixture) void {
        for (0..3) |_| {
            self.cx.advanceFrameClock();
            self.cx.layout();
            self.follow.update();
            _ = self.cx.render();
        }
    }
    fn wheel(self: *Fixture, delta: f32) void {
        const r = self.follow.scroll.container.globalRect();
        self.cx.handleScroll(.{ .x = r.x + 30, .y = r.y + r.h / 2, .dy = delta, .dx = 0 });
        self.settle();
    }
    fn deinit(self: *Fixture) void {
        self.scope.dispose();
        self.cx.deinit();
    }
};
test "AI tail follows new content and viewport changes through the actual ScrollArea" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.append(300);
    f.settle();
    const last = try f.append(30);
    f.settle();
    const scroll = f.follow.scroll;
    try std.testing.expectApproxEqAbs(scroll.state.maxScrollY(), scroll.state.scroll_y, 0.01);
    const view = scroll.container.globalRect();
    const row = last.globalRect();
    try std.testing.expect(row.y >= view.y - 0.01 and row.y + row.h <= view.y + view.h + 0.01);
    scroll.container.setStyleInline(a, .{ .height = .{ .px = 80 } });
    f.settle();
    try std.testing.expectApproxEqAbs(scroll.state.maxScrollY(), scroll.state.scroll_y, 0.01);
}
test "AI tail respects real reader scroll and resumes on bottom or a new turn" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.append(600);
    f.settle();
    f.wheel(80);
    try std.testing.expect(!f.follow.following);
    const saved = f.follow.scroll.state.scroll_y;
    _ = try f.append(50);
    f.settle();
    try std.testing.expectApproxEqAbs(saved, f.follow.scroll.state.scroll_y, 0.01);
    f.wheel(-10000);
    try std.testing.expect(f.follow.following);
    _ = try f.append(40);
    f.settle();
    try std.testing.expectApproxEqAbs(f.follow.scroll.state.maxScrollY(), f.follow.scroll.state.scroll_y, 0.01);
    f.wheel(80);
    try std.testing.expect(!f.follow.following);
    f.follow.reset();
    f.settle();
    try std.testing.expect(f.follow.following);
    try std.testing.expectApproxEqAbs(f.follow.scroll.state.maxScrollY(), f.follow.scroll.state.scroll_y, 0.01);
}
