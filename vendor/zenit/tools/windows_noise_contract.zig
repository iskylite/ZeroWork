const std = @import("std");
const ui = @import("ui");
var multiply_node: *ui.Node = undefined;
const Actions = struct {
    pub fn cache(_: *@This()) void {
        multiply_node.setDisplay(.none);
    }
};
const Spec = struct {
    mode: u8 = 1,
    seed: u8 = 0,
    scale: f32 = 8,
    fill: ui.Color = ui.Color.rgb(128, 128, 128),
    rounded: bool = false,
    rotate: f32 = 0,
    opacity: f32 = 1,
    multiply: bool = false,
};
var specs = [_]Spec{
    .{},                              .{},                            .{ .seed = 31 },                              .{ .scale = 16 },
    .{ .mode = 2 },                   .{ .mode = 0 },                 .{ .fill = ui.Color.rgba(32, 96, 160, 128) }, .{ .rounded = true },
    .{ .rotate = std.math.pi / 2.0 }, .{ .mode = 2, .opacity = 0.5 }, .{ .multiply = true },                        .{ .mode = 2, .fill = ui.Color.TRANSPARENT },
};
fn draw(ctx: ui.DrawContext, context: ?*anyopaque) anyerror!void {
    const spec: *const Spec = @ptrCast(@alignCast(context orelse return));
    const dl = ctx.display_list orelse return;
    const header = ctx.display_header orelse return;
    try dl.append(.{ .noise_rect = .{
        .header = header,
        .x = 0,
        .y = 0,
        .w = ctx.local_w,
        .h = ctx.local_h,
        .fill = spec.fill,
        .mode = spec.mode,
        .scale = spec.scale,
        .intensity = 0.6,
        .seed = spec.seed,
        .radius = if (spec.rounded) .{ 30, 0, 20, 10 } else .{ 0, 0, 0, 0 },
    } });
}
pub fn mount(cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
    const root = try ui.box(cx, .{ .display = .none, .width = .{ .grow = .{} }, .height = .{ .px = 460 }, .flex_shrink = 0, .direction = .column, .gap = 40 }, .{});
    const ids = [_][]const u8{ "noise.value", "noise.value-copy", "noise.seed", "noise.scale", "noise.film", "noise.disabled", "noise.alpha", "noise.rounded", "noise.rotated", "noise.film-opacity", "noise.multiply", "noise.transparent" };
    var row: *ui.Node = undefined;
    for (ids, 0..) |id, i| {
        if (i % 4 == 0) {
            row = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 96 }, .flex_shrink = 0, .direction = .row, .gap = 48 }, .{});
            try root.appendChild(cx.allocator, row);
        }
        const node = try ui.box(cx, .{ .width = .{ .px = 160 }, .height = .{ .px = 96 }, .flex_shrink = 0, .opacity = specs[i].opacity, .rotate = specs[i].rotate }, .{});
        if (specs[i].multiply) (try node.style.ensureExtFallible(cx.allocator)).blend_mode = .multiply;
        if (i == 1 or i == 4) (try node.style.ensureExtFallible(cx.allocator)).composited_group = true;
        if (i == 10) multiply_node = node;
        node.meta.ownership.meta.test_id = id;
        node.setCustomDraw(draw, &specs[i]);
        try row.appendChild(cx.allocator, node);
    }
    const actions = try cx.bindState(Actions, .{});
    const button = try ui.widgets.Button(.{ .label = "Check retained noise", .on_click = cx.on(Actions, actions, Actions.cache) }).mount(scope, cx);
    button.meta.ownership.meta.test_id = "noise.cache";
    try root.appendChild(cx.allocator, button);
    return root;
}
