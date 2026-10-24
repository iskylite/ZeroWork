const ui = @import("ui");
const std = @import("std");
var stripes: [300]*ui.Node = undefined;
var stripe_count: usize = 0;
var original_colors: [300]ui.Color = undefined;
var fading: *ui.Node = undefined;
var panel_nodes: [12]*ui.Node = undefined;
var fading_container: *ui.Node = undefined;
pub fn isolate() void {
    for (panel_nodes[0..owner_count]) |node| if (node != fading_container) {
        node.setDisplay(.none);
    };
}
var fade_stage: usize = 0;
pub fn fade() void {
    const alpha = [_]f32{ 0.75, 0.5, 0.25, 0, 0.25, 0.5, 0.75, 1 };
    fading.setOpacity(alpha[fade_stage % alpha.len]);
    fade_stage += 1;
}
var owners: [12]u32 = undefined;
var owner_count: usize = 0;

pub fn describe(cx: *ui.Cx, buffer: []u8) []const u8 {
    var used: usize = 0;
    const prefix = std.fmt.bufPrint(buffer, "n={d}; values=", .{cx.backdrop_luminance_region_count}) catch return "overflow";
    used += prefix.len;
    for (owners[0..owner_count], 0..) |owner, index| {
        var value: f32 = -1;
        for (cx.backdrop_luminance_regions[0..cx.backdrop_luminance_region_count]) |region| {
            if (region.node_id == owner) value = region.lum;
        }
        const part = std.fmt.bufPrint(buffer[used..], "{s}{d:.4}", .{ if (index == 0) "" else ",", value }) catch return "overflow";
        used += part.len;
    }
    return buffer[0..used];
}

pub fn change() void {
    for (stripes[0..stripe_count]) |node| node.setBackground(ui.Color.rgba(0, 255, 0, 255));
}

pub fn reset() void {
    fade_stage = 0;
    fading.setOpacity(1);
    for (panel_nodes[0..owner_count]) |node| node.setDisplay(.flex);
    for (stripes[0..stripe_count], original_colors[0..stripe_count]) |node, color| node.setBackground(color);
}

pub fn solid() void {
    const colors = [_]ui.Color{
        ui.Color.BLACK,                  ui.Color.rgba(128, 128, 128, 255), ui.Color.WHITE,
        ui.Color.rgba(255, 0, 0, 255),   ui.Color.rgba(0, 255, 0, 255),     ui.Color.rgba(0, 0, 255, 255),
        ui.Color.rgba(255, 255, 0, 255), ui.Color.rgba(0, 255, 255, 255),   ui.Color.rgba(255, 0, 255, 255),
        ui.Color.rgba(32, 32, 32, 255),  ui.Color.rgba(192, 192, 192, 255), ui.Color.rgba(64, 64, 64, 255),
    };
    for (stripes[0..stripe_count], 0..) |node, index| node.setBackground(colors[index / 25]);
}

fn panel(cx: *ui.Cx, row: *ui.Node, id: []const u8, glass: ui.GlassParams, radius: f32, colored: bool) !void {
    const node = try ui.box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 }, .flex_shrink = 0, .position = .relative }, .{});
    node.meta.ownership.meta.test_id = id;
    try row.appendChild(cx.allocator, node);
    for (0..25) |i| {
        const color = if (colored)
            (if (i % 2 == 0) ui.Color.rgba(255, 0, 0, 255) else ui.Color.rgba(0, 0, 255, 255))
        else
            (if (i % 2 == 0) ui.Color.WHITE else ui.Color.BLACK);
        const stripe = try ui.box(cx, .{ .width = .{ .px = 4 }, .height = .{ .px = 100 }, .position = .absolute, .background = color }, .{});
        (try stripe.style.ensureExtFallible(cx.allocator)).inset = .{ .left = .{ .px = @floatFromInt(i * 4) }, .top = .{ .px = 0 } };
        try node.appendChild(cx.allocator, stripe);
        stripes[stripe_count] = stripe;
        original_colors[stripe_count] = color;
        stripe_count += 1;
    }
    const blur = try ui.box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 }, .position = .absolute, .corner_radius = radius }, .{});
    const ext = try blur.style.ensureExtFallible(cx.allocator);
    ext.inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } };
    ext.glass = glass;
    if (std.mem.eql(u8, id, "blur.uniform")) {
        fading = blur;
        ext.composited_group = true;
        fading_container = node;
    }
    panel_nodes[owner_count] = node;
    owners[owner_count] = blur.id;
    owner_count += 1;
    try node.appendChild(cx.allocator, blur);
}

pub fn mount(cx: *ui.Cx) !*ui.Node {
    stripe_count = 0;
    owner_count = 0;
    const root = try ui.box(cx, .{ .display = .none, .width = .{ .grow = .{} }, .height = .{ .px = 220 }, .flex_shrink = 0, .direction = .column, .gap = 12 }, .{});
    const row = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 100 }, .flex_shrink = 0, .direction = .row, .gap = 12 }, .{});
    try root.appendChild(cx.allocator, row);
    const plain: ui.GlassParams = .{ .backdrop_blur = 12, .glass_intensity = 0 };
    var sharp = plain;
    sharp.blur_level = 0;
    try panel(cx, row, "blur.sharp", sharp, 0, false);
    try panel(cx, row, "blur.uniform", plain, 0, false);
    var half = plain;
    half.blur_level = 0.5;
    try panel(cx, row, "blur.half", half, 0, false);
    var gradient = plain;
    gradient.blur_level = 0;
    gradient.blur_gradient = .{ .direction = .to_bottom, .strength = 1, .stops = .{ .{ .pos = 0, .strength = 1 }, .{ .pos = 1, .strength = 0 }, .{}, .{} }, .stop_count = 2 };
    try panel(cx, row, "blur.gradient", gradient, 0, false);
    try panel(cx, row, "blur.rounded", plain, 28, false);
    var top = gradient;
    top.blur_gradient.direction = .to_top;
    try panel(cx, row, "blur.top", top, 0, false);
    const row2 = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 100 }, .flex_shrink = 0, .direction = .row, .gap = 12 }, .{});
    try root.appendChild(cx.allocator, row2);
    var color = plain;
    color.backdrop_saturation = 0;
    color.backdrop_brightness = 0.5;
    try panel(cx, row2, "blur.color", color, 0, true);
    var zero = plain;
    zero.backdrop_blur = 0;
    try panel(cx, row2, "blur.zero", zero, 0, false);
    var left = gradient;
    left.blur_gradient.direction = .to_left;
    try panel(cx, row2, "blur.left", left, 0, false);
    var right = gradient;
    right.blur_gradient.direction = .to_right;
    try panel(cx, row2, "blur.right", right, 0, false);
    var inactive = gradient;
    inactive.blur_level = 1;
    inactive.blur_gradient.strength = 0;
    try panel(cx, row2, "blur.inactive", inactive, 0, false);
    var four = gradient;
    four.blur_gradient.stops = .{ .{ .pos = 0, .strength = 0 }, .{ .pos = 0.4, .strength = 1 }, .{ .pos = 0.6, .strength = 0 }, .{ .pos = 1, .strength = 0 } };
    four.blur_gradient.stop_count = 4;
    try panel(cx, row2, "blur.four", four, 0, false);
    return root;
}
