//! V2 live Bridge 359:1538413, identity/actions 415:1879957/66/69.
const ui = @import("ui");
const shared = @import("ai_attachments_styles.zig");
pub fn retrySlot() ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .left = .{ .px = 134 }, .top = .{ .px = 2 } }, .width = .{ .px = 22 }, .height = .{ .px = 22 } };
}
pub fn previewStyle() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = shared.preview_body_height }, .flex_shrink = 0, .background = shared.theme.current().well, .overflow = .hidden };
}
/// Raster remains in proportion inside the fixed preview viewport.
pub fn raster(width: u32, height: u32) ui.BoxStyle {
    const h = shared.preview_body_height;
    const w = @min(shared.preview_width, h * @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height)));
    return .{ .width = .{ .px = w }, .height = .{ .px = @min(h, w * @as(f32, @floatFromInt(height)) / @as(f32, @floatFromInt(width))) }, .flex_shrink = 0 };
}
