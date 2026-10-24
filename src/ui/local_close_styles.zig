const ui = @import("ui");
const theme = @import("app_theme.zig");
// Figma Bridge 444:188511: 480×220, padding12, gap6.
pub fn dialog() ui.BoxStyle {
    var value = dialogPaint();
    value.width = .{ .px = 480 };
    value.height = .{ .px = 220 };
    value.padding = .{};
    value.border = .{ .radius = 14 };
    return value;
}
pub fn dialogPaint() ui.BoxStyle {
    const c = theme.current();
    return .{ .background = c.overlay, .shadow = .{ .offset_y = 24, .blur = 32, .color = c.shadow } };
}
pub fn body() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .direction = .column, .gap = 6, .padding = ui.Padding.all(12) };
}
pub fn row(height: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = height }, .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0 };
}
pub fn risk() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 56 }, .direction = .column, .gap = 4, .padding = ui.Padding.all(8), .background = theme.current().surface_2, .border = .{ .radius = 9 }, .flex_shrink = 0 };
}
pub fn text(size: f32, strong: bool) ui.TextStyle {
    return .{ .font_size = size, .font_weight = if (strong) 500 else 400, .color = if (strong) theme.current().fg_1 else theme.current().fg_2, .line_height = (if (size == 11) @as(f32, 16) else 18) / size, .text_overflow = .ellipsis };
}
pub fn button(width: f32, danger: bool) ui.BoxStyle {
    return .{ .width = .{ .px = width }, .height = .{ .px = 30 }, .padding = .{}, .background = if (danger) ui.Color.rgb(0xd5, 0x3d, 0x3d) else theme.current().surface_2, .border = .{ .radius = 8 }, .flex_shrink = 0 };
}
