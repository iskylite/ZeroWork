const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub const width: f32 = 336;
pub fn panel() ui.BoxStyle {
    return .{ .position = .absolute, .width = .{ .px = width }, .height = .{ .px = 360 }, .direction = .column, .gap = 10, .padding = ui.Padding.all(12), .background = theme.current().overlay, .glass = theme.overlayGlass(), .border = .{ .radius = 11 }, .shadow = .{ .blur = 24, .offset_y = 12, .color = theme.current().shadow }, .hit_behavior = .@"opaque", .z_index = 60, .flex_shrink = 0 };
}
pub fn text(size: f32, weight: u16, secondary: bool) ui.TextStyle {
    return .{ .font_size = size, .font_weight = weight, .line_height = 18.0 / size, .color = if (secondary) theme.current().fg_2 else theme.current().fg_1, .selectable = false, .text_overflow = .ellipsis };
}
pub fn row() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .min_height = 61, .direction = .column, .gap = 7, .padding = ui.Padding.all(10), .background = theme.popupInset(), .border = .{ .radius = 8 }, .flex_shrink = 0, .min_width = 0 };
}
