//! Optical parameters on a known linear ramp, with real surrounding backdrop.
const ui = @import("ui");
const std = @import("std");
var slabs: [24]*ui.Node = undefined;
var color_marker: u8 = 1;
pub fn change() void {
    slabs[18].style.ext.?.glass.?.specular_saturation = 12;
    slabs[22].style.ext.?.glass.?.glass_intensity = 1;
    slabs[2].style.ext.?.glass.?.bezel_width = 0.45;
    slabs[5].style.ext.?.glass.?.bottom_bezel_width = 0.4;
    slabs[20].style.ext.?.glass.?.blur_gradient = .{ .direction = .to_left, .strength = 0.25, .stops = .{ .{ .pos = 0, .strength = 0 }, .{ .pos = 0.3, .strength = 1 }, .{ .pos = 0.6, .strength = 0 }, .{ .pos = 1, .strength = 1 } }, .stop_count = 4 };
    for ([_]usize{ 2, 5, 20 }) |i| slabs[i].markRenderDirty();
    slabs[18].markRenderDirty();
    slabs[22].markRenderDirty();
}
fn ramp(ctx: ui.DrawContext, context: ?*anyopaque) anyerror!void {
    const dl = ctx.display_list orelse return;
    const header = ctx.display_header orelse return;
    var colors = @as([16]ui.Color, @splat(ui.Color.TRANSPARENT));
    var positions = @as([16]f32, @splat(0));
    // The saturation control needs chroma headroom: pure primaries are already
    // clamped and cannot show a further increase in specular saturation.
    for (0..11) |i| {
        colors[i] = if (context != null) (if (i % 2 == 0) ui.Color.rgb(192, 64, 64) else ui.Color.rgb(64, 64, 192)) else (if (i % 2 == 0) ui.Color.BLACK else ui.Color.WHITE);
        positions[i] = @as(f32, @floatFromInt(i)) / 10.0;
    }
    try dl.append(.{ .multi_gradient_rect = .{ .header = header, .x = 0, .y = 0, .w = ctx.local_w, .h = ctx.local_h, .stop_colors = colors, .stop_positions = positions, .stop_count = 11, .direction = .horizontal } });
}
pub fn mount(cx: *ui.Cx) !*ui.Node {
    const root = try ui.box(cx, .{ .display = .none, .width = .{ .grow = .{} }, .height = .{ .px = 476 }, .flex_shrink = 0, .direction = .column, .gap = 12 }, .{});
    const ids = [_][]const u8{ "optical.base", "optical.circle", "optical.squircle", "optical.concave", "optical.mixed", "optical.bottom", "optical.warp-zero", "optical.warp-three", "optical.refraction-zero", "optical.thick", "optical.magnify", "optical.radius", "optical.falloff", "optical.scale", "optical.edge", "optical.gap", "optical.light-right", "optical.light-left", "optical.spec-saturation", "optical.tint", "optical.gradient", "optical.rounded", "optical.intensity-two", "optical.blur" };
    var row: *ui.Node = undefined;
    for (ids, 0..) |id, i| {
        if (i % 6 == 0) {
            row = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 110 }, .flex_shrink = 0, .direction = .row, .gap = 12 }, .{});
            try root.appendChild(cx.allocator, row);
        }
        const node = try ui.box(cx, .{ .width = .{ .px = 110 }, .height = .{ .px = 110 }, .flex_shrink = 0, .position = .relative }, .{});
        try row.appendChild(cx.allocator, node);
        // A custom draw replaces its subtree: keep the ramp and slab siblings.
        const background = try ui.box(cx, .{ .width = .{ .px = 110 }, .height = .{ .px = 110 }, .position = .absolute }, .{});
        background.setCustomDraw(ramp, if (i == 18) &color_marker else null);
        try node.appendChild(cx.allocator, background);
        var glass: ui.GlassParams = .{ .backdrop_blur = 0.5, .blur_level = 0, .glass_intensity = 1, .center_thickness = 12, .warp_gain = 2, .surface = .convex_circle, .specular_opacity = 0, .specular_angle = -std.math.pi / 2.0 };
        switch (i) {
            0 => glass.glass_intensity = 0,
            2 => glass.surface = .convex_squircle,
            3 => glass.surface = .concave,
            4 => glass.surface = .lip,
            5 => glass.bottom_surface = .convex_circle,
            6 => glass.warp_gain = 0,
            7 => glass.warp_gain = 3,
            8 => glass.refraction_level = 0,
            9 => glass.center_thickness = 20,
            10 => glass.magnification = 0.8,
            11 => glass.center_zoom_radius = 1.4,
            12 => glass.center_zoom_falloff = 0.5,
            13 => glass.scale_ratio = 0.4,
            14 => glass.edge_field_strength = 3,
            15 => glass.backdrop_distance = 12,
            16 => {
                glass.specular_opacity = 1;
                glass.specular_angle = 0;
            },
            17 => {
                glass.specular_opacity = 1;
                glass.specular_angle = std.math.pi;
            },
            18 => {
                glass.specular_opacity = 1;
                glass.specular_saturation = 1;
            },
            19 => glass.glass_tint = ui.Color.rgba(255, 0, 128, 255),
            20 => {
                glass.backdrop_blur = 8;
                glass.blur_gradient = .{ .direction = .to_bottom, .strength = 1 };
            },
            22 => {
                glass.glass_intensity = 2;
                glass.specular_opacity = 1;
            },
            23 => {
                glass.backdrop_blur = 8;
                glass.blur_level = 1;
            },
            else => {},
        }
        const slab = try ui.box(cx, .{ .width = .{ .px = 80 }, .height = .{ .px = 80 }, .position = .absolute, .corner_radius = if (i == 21) 24 else 0 }, .{});
        slabs[i] = slab;
        slab.meta.ownership.meta.test_id = id;
        const ext = try slab.style.ensureExtFallible(cx.allocator);
        ext.inset = .{ .left = .{ .px = 15 }, .top = .{ .px = 15 } };
        ext.glass = glass;
        try node.appendChild(cx.allocator, slab);
    }
    return root;
}
