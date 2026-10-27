//! Shared scrollback indicator for service and SSH terminal canvases.
const ui = @import("ui");
const theme = @import("app_theme.zig");
pub fn mount(cx: *ui.Cx, parent: *ui.Node) !*ui.Node {
    const node = try ui.box(cx, .{ .position = .absolute, .width = .{ .px = 5 }, .height = .{ .px = 24 }, .border = .{ .radius = 2.5 }, .z_index = 9, .hit_behavior = .pass_through }, .{});
    node.meta.ownership.meta.test_id = "terminal.scrollbar";
    node.setDisplay(.none);
    try parent.appendChild(cx.allocator, node);
    return node;
}
pub fn update(cx: *ui.Cx, node: *ui.Node, total: u64, offset: u64, rows: u64, visible: bool) void {
    const parent = node.parent orelse return;
    const bounds = parent.globalRect();
    const height = @max(0, bounds.h - 8);
    node.setDisplay(if (visible and total > rows and height > 0) .flex else .none);
    if (total <= rows or height <= 0) return;
    const thumb = @min(height, @max(24, height * @as(f32, @floatFromInt(rows)) / @as(f32, @floatFromInt(total))));
    const ratio = @as(f32, @floatFromInt(@min(offset, total - rows))) / @as(f32, @floatFromInt(total - rows));
    node.setStyleInline(cx.allocator, .{ .inset = .{ .right = .{ .px = 3 }, .top = .{ .px = 4 + (height - thumb) * ratio } }, .height = .{ .px = thumb }, .background = theme.current().fg_2.withAlpha(150) });
}
