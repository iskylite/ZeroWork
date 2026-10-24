//! Figma 358:1390912: six-point edges, fourteen-point corners; invisible hit areas.
const ui = @import("ui");
const Edge = @import("../ai/float_model.zig").Edge;

pub fn cursor(edge: Edge) ui.CursorShape {
    return switch (edge) {
        .n, .s => .ns_resize,
        .w, .e => .ew_resize,
        .nw, .se => .nwse_resize,
        .ne, .sw => .nesw_resize,
    };
}

pub fn handle(edge: Edge, width: f32, height: f32) ui.BoxStyle {
    const corner = edge != .n and edge != .s and edge != .w and edge != .e;
    const box_width: f32 = if (corner) 14 else if (edge == .w or edge == .e) 6 else @max(0, width - 28);
    const box_height: f32 = if (corner) 14 else if (edge == .n or edge == .s) 6 else @max(0, height - 28);
    const x: f32 = if (edge.east()) @max(0, width - box_width) else if (edge == .n or edge == .s) 14 else 0;
    const y: f32 = if (edge.south()) @max(0, height - box_height) else if (edge == .w or edge == .e) 14 else 0;
    return .{ .position = .absolute, .inset = .{ .left = .{ .px = x }, .top = .{ .px = y } }, .width = .{ .px = box_width }, .height = .{ .px = box_height }, .flex_shrink = 0, .background = ui.Color.TRANSPARENT, .hit_behavior = .@"opaque", .cursor = cursor(edge), .z_index = if (corner) 11 else 10 };
}
