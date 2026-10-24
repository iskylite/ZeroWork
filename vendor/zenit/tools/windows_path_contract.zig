const std = @import("std");
const ui = @import("ui");
const Commands = ui.path.PathCommand;
const Geometry = ui.path.PathGeometry;
const squares = [_]Commands{
    .{ .move_to = .{ .x = 10, .y = 10 } }, .{ .line_to = .{ .x = 90, .y = 10 } }, .{ .line_to = .{ .x = 90, .y = 90 } }, .{ .line_to = .{ .x = 10, .y = 90 } }, .{ .close = {} },
    .{ .move_to = .{ .x = 30, .y = 30 } }, .{ .line_to = .{ .x = 70, .y = 30 } }, .{ .line_to = .{ .x = 70, .y = 70 } }, .{ .line_to = .{ .x = 30, .y = 70 } }, .{ .close = {} },
};
const quad = [_]Commands{ .{ .move_to = .{ .x = 10, .y = 80 } }, .{ .quad_to = .{ .ctrl = .{ .x = 50, .y = -40 }, .end = .{ .x = 90, .y = 80 } } }, .{ .close = {} } };
const cubic = [_]Commands{ .{ .move_to = .{ .x = 10, .y = 80 } }, .{ .cubic_to = .{ .ctrl1 = .{ .x = 10, .y = 0 }, .ctrl2 = .{ .x = 90, .y = 0 }, .end = .{ .x = 90, .y = 80 } } }, .{ .close = {} } };
const corner = [_]Commands{ .{ .move_to = .{ .x = 10, .y = 50 } }, .{ .line_to = .{ .x = 50, .y = 10 } }, .{ .line_to = .{ .x = 90, .y = 50 } } };
const acute = [_]Commands{ .{ .move_to = .{ .x = 40, .y = 80 } }, .{ .line_to = .{ .x = 50, .y = 10 } }, .{ .line_to = .{ .x = 60, .y = 80 } } };
const Spec = struct { geometry: Geometry, stroke: bool = false, join: ui.path.LineJoin = .miter, opacity: f32 = 1 };
var specs = [_]Spec{
    .{ .geometry = .{ .commands = &squares, .fill_rule = .evenodd } },
    .{ .geometry = .{ .commands = &squares, .fill_rule = .nonzero } },
    .{ .geometry = .{ .commands = &quad }, .opacity = 0.5 },
    .{ .geometry = .{ .commands = &cubic } },
    .{ .geometry = .{ .commands = &corner }, .stroke = true, .join = .miter },
    .{ .geometry = .{ .commands = &corner }, .stroke = true, .join = .bevel },
    .{ .geometry = .{ .commands = &corner }, .stroke = true, .join = .round },
    .{ .geometry = .{ .commands = &acute }, .stroke = true, .join = .miter },
};
fn draw(ctx: ui.DrawContext, context: ?*anyopaque) anyerror!void {
    const spec: *const Spec = @ptrCast(@alignCast(context orelse return));
    if (ctx.display_list) |dl| {
        if (ctx.display_header) |header| {
            if (spec.stroke) try dl.append(.{ .stroke_path = .{ .header = header, .geometry = &spec.geometry, .color = ui.Color.WHITE, .width = 10, .line_join = spec.join } }) else try dl.append(.{ .fill_path = .{ .header = header, .geometry = &spec.geometry, .color = ui.Color.WHITE, .opacity = spec.opacity } });
        }
    }
}
fn shape(cx: *ui.Cx, parent: *ui.Node, id: []const u8, index: usize) !void {
    const node = try ui.box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 }, .flex_shrink = 0 }, .{});
    node.meta.ownership.meta.test_id = id;
    node.setCustomDraw(draw, &specs[index]);
    try parent.appendChild(cx.allocator, node);
}
fn legacyLayer(ctx: ui.DrawContext, _: ?*anyopaque) anyerror!void {
    const dl = ctx.display_list orelse return;
    const header = ctx.display_header orelse return;
    try dl.append(.{ .begin_opacity_layer = .{ .header = header, .x = ctx.render_x, .y = ctx.render_y, .w = 40, .h = 40, .draw_x = ctx.render_x + 50, .draw_y = ctx.render_y + 10, .draw_w = 40, .draw_h = 40, .opacity = 0.5 } });
    try dl.append(.{ .fill_rect = .{ .header = header, .x = 0, .y = 0, .w = 40, .h = 40, .color = ui.Color.WHITE } });
    try dl.append(.{ .begin_opacity_layer = .{ .header = header, .x = ctx.render_x + 10, .y = ctx.render_y + 10, .w = 10, .h = 10, .draw_x = ctx.render_x + 20, .draw_y = ctx.render_y + 20, .draw_w = 20, .draw_h = 10, .opacity = 1 } });
    try dl.append(.{ .fill_rect = .{ .header = header, .x = 10, .y = 10, .w = 10, .h = 10, .color = ui.Color.rgba(0, 0, 255, 255) } });
    try dl.append(.{ .end_opacity_layer = .{ .header = header } });
    try dl.append(.{ .end_opacity_layer = .{ .header = header } });
}
const GradientSpec = struct { direction: u8, alpha: bool = false, hole: bool = false, curve: bool = false, angle: f32 = 0 };
var gradient_specs = [_]GradientSpec{
    .{ .direction = 2 },                .{ .direction = 1 },                         .{ .direction = 3 },               .{ .direction = 4 },
    .{ .direction = 2, .alpha = true }, .{ .direction = 2, .hole = true },           .{ .direction = 2 },               .{ .direction = 2, .curve = true },
    .{ .direction = 5 },                .{ .direction = 5, .angle = 1.57079632679 }, .{ .direction = 5, .hole = true }, .{ .direction = 5, .alpha = true },
};
var gradient_geometry: [gradient_specs.len]Geometry = undefined;
const empty_gradient_commands = [_]Commands{ .{ .move_to = .{ .x = 10, .y = 5 } }, .{ .line_to = .{ .x = 90, .y = 5 } }, .{ .close = {} } };
const empty_gradient_geometry: Geometry = .{ .commands = &empty_gradient_commands };
fn gradientPath(ctx: ui.DrawContext, context: ?*anyopaque) anyerror!void {
    const index: *const usize = @ptrCast(@alignCast(context orelse return));
    const spec = gradient_specs[index.*];
    const dl = ctx.display_list orelse return;
    const header = ctx.display_header orelse return;
    var colors = @as([16]ui.Color, @splat(ui.Color.TRANSPARENT));
    var positions = @as([16]f32, @splat(0));
    colors[0] = if (spec.alpha) ui.Color.TRANSPARENT else ui.Color.rgb(255, 0, 0);
    colors[1] = ui.Color.rgb(0, 255, 0);
    colors[2] = ui.Color.rgb(0, 0, 255);
    positions[1] = 0.25;
    positions[2] = 1;
    try dl.append(.{ .fill_path = .{
        .header = header,
        .geometry = &gradient_geometry[index.*],
        .color = ui.Color.WHITE,
        .offset_x = 3,
        .offset_y = 2,
        .opacity = if (spec.alpha) 0.5 else 1,
        .gradient_direction = spec.direction,
        .gradient_stop_count = 3,
        .gradient_stop_colors = colors,
        .gradient_stop_positions = positions,
        .gradient_center_x = 0.25,
        .gradient_center_y = 0.4,
        .gradient_start_angle = spec.angle,
    } });
    if (index.* == 0) try dl.append(.{ .fill_path = .{
        .header = header,
        .geometry = &empty_gradient_geometry,
        .color = ui.Color.WHITE,
        .gradient_direction = 2,
        .gradient_stop_count = 3,
        .gradient_stop_colors = colors,
        .gradient_stop_positions = positions,
    } });
}
var gradient_indices = [_]usize{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
// Overlapping full-coverage shapes exercise group alpha, not per-shape tint.
// The icon boxes are 80x100: the viewBox has the same 4:5 aspect so the
// solid fill covers the whole box under SVG `meet` scaling (shared renderer,
// and macOS) exactly as under the legacy painter's stretch. A square viewBox
// left 10 pt empty bands above and below, where these samples are taken.
const solid_icon = ui.SvgAsset{
    .svg_data = "<svg viewBox='0 0 24 30'><path d='M0 0H24V30H0Z'/><path d='M6 0H18V30H6Z'/></svg>",
    .icon_id = 65000,
    .reps = &.{.{ .size = 100, .view_height = 30, .shapes = &.{
        .{ .fill = true, .contours = &.{.{ .closed = true, .points = &.{ .{ .x = 0, .y = 0 }, .{ .x = 24, .y = 0 }, .{ .x = 24, .y = 30 }, .{ .x = 0, .y = 30 } } }} },
        .{ .fill = true, .contours = &.{.{ .closed = true, .points = &.{ .{ .x = 6, .y = 0 }, .{ .x = 18, .y = 0 }, .{ .x = 18, .y = 30 }, .{ .x = 6, .y = 30 } } }} },
    } }},
};

pub fn mount(cx: *ui.Cx) !*ui.Node {
    const root = try ui.box(cx, .{ .display = .none, .width = .{ .grow = .{} }, .height = .{ .px = 700 }, .flex_shrink = 0, .direction = .column, .gap = 20 }, .{});
    const top = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 100 }, .direction = .row, .gap = 12 }, .{});
    const bottom = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 100 }, .direction = .row, .gap = 12 }, .{});
    try root.appendChild(cx.allocator, top);
    try root.appendChild(cx.allocator, bottom);
    try shape(cx, top, "path.evenodd", 0);
    try shape(cx, top, "path.nonzero", 1);
    try shape(cx, top, "path.quad", 2);
    try shape(cx, top, "path.cubic", 3);
    const clip = try ui.box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 100 }, .overflow_hidden = true }, .{});
    try top.appendChild(cx.allocator, clip);
    try shape(cx, clip, "path.clipped", 1);
    try shape(cx, bottom, "path.miter", 4);
    try shape(cx, bottom, "path.bevel", 5);
    try shape(cx, bottom, "path.round", 6);
    try shape(cx, bottom, "path.miter-limit", 7);
    const rounded = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 100 }, .direction = .row, .gap = 12 }, .{});
    try root.appendChild(cx.allocator, rounded);
    const ids = [_][]const u8{ "round.fill", "round.border", "round.gradient", "round.clamp", "round.wide-border", "round.clip" };
    for (ids, 0..) |id, index| {
        const node = try ui.box(cx, .{
            .width = .{ .px = 100 },
            .height = .{ .px = if (index == 3) 40 else 100 },
            .flex_shrink = 0,
            .background = if (index == 0 or index == 3) ui.Color.WHITE else ui.Color.TRANSPARENT,
            .border = .{ .width = if (index == 1) 6 else if (index == 4) 60 else 0, .color = ui.Color.WHITE },
            .opacity = if (index == 5) 0.5 else 1,
            .rotate = if (index == 5) std.math.pi / 2.0 else 0,
            .overflow_hidden = index == 5,
        }, .{});
        node.meta.ownership.meta.test_id = id;
        const ext = try node.style.ensureExtFallible(cx.allocator);
        ext.corner_radius = if (index == 5) .{ .all = 30 } else .{ .each = if (index == 3) .{ 1000, 0, 0, 0 } else .{ 40, 0, 20, 10 } };
        if (index == 2) ext.gradient = .{ .from = ui.Color.WHITE, .to = ui.Color.WHITE };
        if (index == 5) {
            const child = try ui.box(cx, .{ .width = .{ .px = 120 }, .height = .{ .px = 120 }, .flex_shrink = 0, .background = ui.Color.WHITE }, .{});
            try node.appendChild(cx.allocator, child);
        }
        try rounded.appendChild(cx.allocator, node);
    }
    const legacy = try ui.box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 }, .flex_shrink = 0 }, .{});
    legacy.meta.ownership.meta.test_id = "layer.legacy";
    legacy.setCustomDraw(legacyLayer, null);
    const gradients = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 100 }, .direction = .row, .gap = 12 }, .{});
    try root.appendChild(cx.allocator, gradients);
    try gradients.appendChild(cx.allocator, legacy);
    const gradient_ids = [_][]const u8{ "path.gradient-horizontal", "path.gradient-vertical", "path.gradient-diagonal", "path.gradient-radial", "path.gradient-alpha", "path.gradient-hole", "path.gradient-clipped", "path.gradient-curve", "path.conic", "path.conic-angle", "path.conic-hole", "path.conic-alpha" };
    const conic_row = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 100 }, .flex_shrink = 0, .direction = .row, .gap = 12 }, .{});
    try root.appendChild(cx.allocator, conic_row);
    for (gradient_ids, 0..) |id, i| {
        gradient_geometry[i] = .{ .commands = if (gradient_specs[i].curve) &quad else &squares, .fill_rule = if (gradient_specs[i].hole) .evenodd else .nonzero };
        const parent = if (i == 6) blk: {
            const gradient_clip = try ui.box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 100 }, .flex_shrink = 0, .overflow_hidden = true }, .{});
            try gradients.appendChild(cx.allocator, gradient_clip);
            break :blk gradient_clip;
        } else if (i >= 8) conic_row else gradients;
        const node = try ui.box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 }, .flex_shrink = 0 }, .{});
        node.meta.ownership.meta.test_id = id;
        node.setCustomDraw(gradientPath, &gradient_indices[i]);
        try parent.appendChild(cx.allocator, node);
    }
    const polygon_row = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 100 }, .flex_shrink = 0, .direction = .row, .gap = 12 }, .{});
    try root.appendChild(cx.allocator, polygon_row);
    const polygon_ids = [_][]const u8{ "clip.triangle", "clip.evenodd", "clip.nonzero", "clip.opacity", "clip.nested" };
    for (polygon_ids, 0..) |id, i| {
        const node = try ui.box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 }, .flex_shrink = 0, .overflow_hidden = true, .opacity = if (i == 3) 0.5 else 1 }, .{});
        node.meta.ownership.meta.test_id = id;
        const rule: ui.path.PathFillRule = if (i == 1 or i == 3) .evenodd else .nonzero;
        (try node.style.ensureExtFallible(cx.allocator)).clip_shape = .{ .path = .{ .fill_rule = rule } };
        try node.setSvgPathHitGeometry(cx.allocator, if (i == 0 or i == 4)
            "M20 20 L80 20 L50 80 Z"
        else
            "M10 10 L90 10 L90 90 L10 90 Z M30 30 L70 30 L70 70 L30 70 Z", rule);
        const content = try ui.box(cx, .{ .width = .{ .px = if (i == 4) 50 else 100 }, .height = .{ .px = 100 }, .flex_shrink = 0, .overflow_hidden = i == 4 }, .{});
        const fill = try ui.box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 }, .flex_shrink = 0, .background = ui.Color.WHITE }, .{});
        try content.appendChild(cx.allocator, fill);
        try node.appendChild(cx.allocator, content);
        try polygon_row.appendChild(cx.allocator, node);
    }
    return root;
}

pub fn mountIcons(cx: *ui.Cx) !*ui.Node {
    const icons = try ui.box(cx, .{ .display = .none, .width = .{ .grow = .{} }, .height = .{ .px = 100 }, .flex_shrink = 0, .direction = .row, .gap = 24 }, .{});
    const icon_ids = [_][]const u8{ "icon.square", "icon.rounded", "icon.rotated", "icon.opacity", "icon.tint-alpha", "icon.nested" };
    for (icon_ids, 0..) |id, index| {
        const parent = if (index == 5) blk: {
            const clipped = try ui.box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 100 }, .overflow_hidden = true, .flex_shrink = 0, .opacity = 0.5 }, .{});
            try icons.appendChild(cx.allocator, clipped);
            break :blk clipped;
        } else icons;
        const node = try ui.iconTintStyled(cx, solid_icon, if (index == 4) ui.Color.rgba(255, 255, 255, 128) else ui.Color.WHITE, .{
            .width = .{ .px = 80 },
            .height = .{ .px = 100 },
            .flex_shrink = 0,
            .corner_radius = if (index == 0 or index == 3 or index == 4) 0 else 32,
            .rotate = if (index == 2) std.math.pi / 6.0 else 0,
            .opacity = if (index == 3 or index == 4 or index == 5) 0.5 else 1,
        });
        node.meta.ownership.meta.test_id = id;
        try parent.appendChild(cx.allocator, node);
    }
    return icons;
}
