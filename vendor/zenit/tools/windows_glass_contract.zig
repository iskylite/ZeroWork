//! Flat-slab optical transmission oracle fixture. Curved optics are separate.
const ui = @import("ui");
fn panel(cx: *ui.Cx, row: *ui.Node, id: []const u8, glass: ui.GlassParams, background: ui.Color, radius: f32) !void {
    const node = try ui.box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 }, .flex_shrink = 0, .position = .relative, .background = background }, .{});
    node.meta.ownership.meta.test_id = id;
    try row.appendChild(cx.allocator, node);
    const slab = try ui.box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 }, .position = .absolute, .corner_radius = radius }, .{});
    const ext = try slab.style.ensureExtFallible(cx.allocator);
    ext.inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } };
    ext.glass = glass;
    try node.appendChild(cx.allocator, slab);
}
pub fn mount(cx: *ui.Cx) !*ui.Node {
    const root = try ui.box(cx, .{ .display = .none, .width = .{ .grow = .{} }, .height = .{ .px = 220 }, .flex_shrink = 0, .direction = .column, .gap = 12 }, .{});
    const row = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 100 }, .flex_shrink = 0, .direction = .row, .gap = 12 }, .{});
    try root.appendChild(cx.allocator, row);
    const base: ui.GlassParams = .{ .backdrop_blur = 12, .glass_intensity = 0, .surface = .flat, .bottom_surface = .flat, .center_thickness = 8, .glass_tint = ui.Color.rgba(255, 0, 128, 255) };
    try panel(cx, row, "glass.tint", base, ui.Color.WHITE, 0);
    var thin = base;
    thin.center_thickness = 4;
    try panel(cx, row, "glass.thin", thin, ui.Color.WHITE, 0);
    var thick = base;
    thick.center_thickness = 16;
    try panel(cx, row, "glass.thick", thick, ui.Color.WHITE, 0);
    var neutral = base;
    neutral.glass_tint = ui.Color.rgba(255, 0, 128, 0);
    try panel(cx, row, "glass.transparent", neutral, ui.Color.WHITE, 0);
    neutral.glass_tint = ui.Color.WHITE;
    try panel(cx, row, "glass.white", neutral, ui.Color.WHITE, 0);
    try panel(cx, row, "glass.rounded", base, ui.Color.WHITE, 28);
    const row2 = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 100 }, .flex_shrink = 0, .direction = .row, .gap = 12 }, .{});
    try root.appendChild(cx.allocator, row2);
    var half = base;
    half.glass_tint = ui.Color.rgba(255, 0, 128, 128);
    try panel(cx, row2, "glass.alpha", half, ui.Color.WHITE, 0);
    var zero = base;
    zero.center_thickness = 0;
    try panel(cx, row2, "glass.zero-thickness", zero, ui.Color.WHITE, 0);
    var color = base;
    color.backdrop_saturation = 0;
    color.backdrop_brightness = 0.5;
    try panel(cx, row2, "glass.color", color, ui.Color.rgba(255, 0, 0, 255), 0);
    var bright = base;
    bright.backdrop_brightness = 3;
    try panel(cx, row2, "glass.overbright", bright, ui.Color.WHITE, 0);
    return root;
}
