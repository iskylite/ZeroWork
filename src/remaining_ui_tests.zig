const std = @import("std");
const ui = @import("ui");
const History = @import("ui/ai_history_view.zig");
const a = std.testing.allocator;
fn frames(cx: *ui.Cx, outer: ui.widgets.ScrollAreaResult, count: usize) void {
    for (0..count) |_| {
        cx.advanceFrameClock();
        _ = cx.render();
        outer.state.content_height = outer.content.globalRect().h;
        outer.state.viewport_height = outer.container.globalRect().h;
    }
}
test "remaining UI virtual history bounds resident rows preserves live content and uses one scroll transform" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    try cx.setTestFrameStep(16);
    cx.reduced_motion = true;
    cx.setViewport(700, 500);
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    const outer = try ui.widgets.ScrollArea(.{ .height = 400, .rubber_band_y = false }).mount(scope, cx);
    try cx.root.?.appendChild(a, outer.container);
    var heights: History.Heights = .{};
    defer heights.deinit(a);
    var keys: [1000]usize = undefined;
    for (&keys, 0..) |*key, i| key.* = i;
    var context: u8 = 0;
    const renderer = struct {
        fn render(_: *anyopaque, i: usize, row_scope: *ui.Scope, c: *ui.Cx) !*ui.Node {
            const row = try ui.box(c, .{ .width = .fill(), .height = .{ .px = 72 }, .flex_shrink = 0 }, .{});
            const value = try std.fmt.allocPrint(c.allocator, "历史 {d}", .{i});
            defer c.allocator.free(value);
            const text = try row_scope.createText(value, .{});
            try row.appendChild(c.allocator, try ui.text(c, text.peek(), .{ .font_size = 12 }));
            return row;
        }
    };
    const view = try History.View.mount(cx, scope, outer, &keys, &heights, &context, renderer.render);
    try outer.content.appendChild(a, view.root);
    const live = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 100 }, .flex_shrink = 0 }, .{});
    try outer.content.appendChild(a, live);
    frames(cx, outer, 8);
    try std.testing.expect(view.state.pool_size < 40);
    for ([_]f32{ 40000, 90000, 0 }) |offset| {
        ui.widgets.setScrollY(outer.state, outer.content, offset);
        frames(cx, outer, 8);
        const actual = view.state.content_node.style.translate_y;
        try std.testing.expectApproxEqAbs(@as(f32, 0), actual, 0.01);
        try std.testing.expectEqual(live, outer.content.children.items[1]);
        try std.testing.expect(view.state.prev_end - view.state.prev_start < 32);
        if (offset > 0) try std.testing.expect(view.state.prev_start > 50);
    }
    // Retired rows leave only their measurements, never a full historical tree.
    try std.testing.expect(heights.count() < 100);
    frames(cx, outer, 80);
    try std.testing.expect(!cx.hasPendingSceneWork());
}
