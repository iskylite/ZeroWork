const ui = @import("ui");
const Spec = struct {
    direction: ui.GradientDirection = .horizontal,
    alpha: bool = false,
    multi: bool = false,
    center: [2]f32 = .{ 0, 0 },
    radius: [2]f32 = .{ 0.5, 0.5 },
    extend: @FieldType(@FieldType(ui.DisplayItem, "multi_gradient_rect"), "extend_mode") = .pad,
    shape: u8 = 0,
    rounded: bool = false,
    single: bool = false,
    legacy: bool = false,
    angle: f32 = 0,
};
var specs = [_]Spec{
    .{},                                                                     .{ .direction = .vertical, .multi = true },                               .{ .direction = .diagonal },
    .{ .alpha = true },                                                      .{ .direction = .radial },                                                .{ .direction = .radial, .center = .{ -0.25, -0.1 }, .radius = .{ 0.75, 0.3 } },
    .{ .direction = .radial, .radius = .{ 0.25, 0.25 }, .extend = .repeat }, .{ .direction = .radial, .radius = .{ 0.25, 0.25 }, .extend = .reflect }, .{ .shape = 1 },
    .{ .rounded = true, .multi = true },                                     .{ .single = true },                                                      .{ .legacy = true },
    .{ .direction = .conic },                                                .{ .direction = .conic, .multi = true, .angle = 1.57079632679 },          .{ .direction = .conic, .alpha = true },
    .{ .direction = .conic, .legacy = true, .angle = -1.57079632679 },       .{ .direction = .conic, .rounded = true },                                .{ .direction = .conic, .single = true, .shape = 1 },
};
fn draw(ctx: ui.DrawContext, context: ?*anyopaque) anyerror!void {
    const spec: *const Spec = @ptrCast(@alignCast(context orelse return));
    const dl = ctx.display_list orelse return;
    const header = ctx.display_header orelse return;
    if (spec.legacy) {
        try dl.append(.{ .gradient_rect = .{ .header = header, .x = 0, .y = 0, .w = ctx.local_w, .h = ctx.local_h, .from = ui.Color.rgb(255, 0, 0), .to = ui.Color.rgb(0, 0, 255), .direction = spec.direction, .conic_start_angle = spec.angle } });
        return;
    }
    var colors = @as([16]ui.Color, @splat(ui.Color.TRANSPARENT));
    var positions = @as([16]f32, @splat(0));
    colors[0] = if (spec.alpha) ui.Color.rgba(255, 0, 0, 0) else ui.Color.rgb(255, 0, 0);
    colors[1] = if (spec.multi) ui.Color.rgb(0, 255, 0) else ui.Color.rgb(0, 0, 255);
    colors[2] = ui.Color.rgb(0, 0, 255);
    positions[1] = if (spec.multi) 0.25 else 1;
    positions[2] = 1;
    if (spec.single) colors[0] = ui.Color.rgb(0, 255, 255);
    try dl.append(.{ .multi_gradient_rect = .{
        .header = header,
        .x = 0,
        .y = 0,
        .w = ctx.local_w,
        .h = ctx.local_h,
        .direction = spec.direction,
        .conic_start_angle = spec.angle,
        .stop_colors = colors,
        .stop_positions = positions,
        .stop_count = if (spec.single) 1 else if (spec.multi) 3 else 2,
        .radial_center_x = spec.center[0],
        .radial_center_y = spec.center[1],
        .radial_radius_x = spec.radius[0],
        .radial_radius_y = spec.radius[1],
        .extend_mode = spec.extend,
        .shape = spec.shape,
        .radius = if (spec.rounded) .{ 30, 0, 20, 10 } else .{ 0, 0, 0, 0 },
    } });
}
pub fn mount(cx: *ui.Cx) !*ui.Node {
    const root = try ui.box(cx, .{ .display = .none, .width = .{ .grow = .{} }, .height = .{ .px = 672 }, .flex_shrink = 0, .direction = .column, .gap = 12 }, .{});
    const ids = [_][]const u8{ "gradient.linear", "gradient.multi", "gradient.diagonal", "gradient.alpha", "gradient.radial", "gradient.offset", "gradient.repeat", "gradient.reflect", "gradient.ellipse", "gradient.rounded", "gradient.single", "gradient.legacy", "gradient.conic", "gradient.conic-angle", "gradient.conic-alpha", "gradient.conic-legacy", "gradient.conic-rounded", "gradient.conic-single" };
    var row: *ui.Node = undefined;
    for (ids, 0..) |id, i| {
        if (i % 3 == 0) {
            row = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 100 }, .flex_shrink = 0, .direction = .row, .gap = 12 }, .{});
            try root.appendChild(cx.allocator, row);
        }
        const node = try ui.box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 }, .flex_shrink = 0 }, .{});
        node.meta.ownership.meta.test_id = id;
        node.setCustomDraw(draw, &specs[i]);
        try row.appendChild(cx.allocator, node);
    }
    return root;
}
