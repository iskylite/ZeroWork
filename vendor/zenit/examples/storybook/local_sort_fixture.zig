//! Two painter-order probes mounted in the real window, only through test RPC.
const std = @import("std");
const ui = @import("ui");
const zenit_app = @import("zenit_app");

fn place(node: *ui.Node, cx: *ui.Cx, x: f32, y: f32) !void {
    node.style.position = .absolute;
    (try node.style.ensureExtFallible(cx.allocator)).inset = .{
        .left = .{ .px = x },
        .top = .{ .px = y },
    };
}

pub fn mount(app: *zenit_app.App, out: []u8) ![]const u8 {
    const cx = app.cx;
    const root = cx.root orelse return error.NoRoot;
    const stage = try ui.box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 300 },
        .background = ui.Color.WHITE,
    }, .{});
    try root.appendChild(cx.allocator, stage);
    try place(stage, cx, 400, 350);
    const texture = try app.renderer.image_renderer.loadTexture(1, 1, &[_]u8{ 0, 0, 255, 255 });
    const shadow_image = try ui.image(cx, texture, .{ .width = .{ .px = 5 }, .height = .{ .px = 10 } });
    shadow_image.meta.ownership.meta.test_id = "review.sort.shadow-image";
    try stage.appendChild(cx.allocator, shadow_image);
    try place(shadow_image, cx, 65, 40);
    const shadow = try ui.box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .{});
    try stage.appendChild(cx.allocator, shadow);
    try place(shadow, cx, 40, 40);
    (try shadow.style.ensureExtFallible(cx.allocator)).setShadow(.{
        .color = ui.Color.BLACK,
        .blur = 1,
        .spread = 30,
        .offset_x = 0,
        .offset_y = 0,
    });
    const letters = try ui.text(cx, "WWW", .{ .font_size = 64, .color = ui.Color.BLACK });
    try stage.appendChild(cx.allocator, letters);
    try place(letters, cx, 0, 170);
    const text_image = try ui.image(cx, texture, .{ .width = .{ .px = 20 }, .height = .{ .px = 80 } });
    text_image.meta.ownership.meta.test_id = "review.sort.text-image";
    try stage.appendChild(cx.allocator, text_image);
    try place(text_image, cx, 150, 170);
    root.markLayoutDirty();
    cx.needs_redraw = true;
    return std.fmt.bufPrint(out, "{{\"mounted\":true}}", .{});
}
