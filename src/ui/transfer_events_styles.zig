//! Figma 321:878950: four rows yield 520x162, viewport 496x104 at (12,46).
//! Event rows are at least 20px high with 8px gaps; long content caps at 184px.
const ui = @import("ui");
const theme = @import("app_theme.zig");
pub fn dialog(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = 520 }, .max_width = 520, .height = .{ .px = 242 }, .padding = .ZERO, .background = theme.current().overlay, .glass = theme.overlayGlass(), .border = .{ .radius = 14 }, .shadow = .{ .offset_y = 24, .blur = 64, .color = theme.current().shadow } };
}
pub fn body(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .direction = .column, .padding = ui.Padding.all(12), .gap = 0 };
}
pub fn row(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 28 }, .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0 };
}
pub fn viewport(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 184 }, .margin = .{ .top = 6 }, .flex_shrink = 0 };
}
pub fn title(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 13, .font_weight = 700, .line_height = 20.0 / 13.0, .color = theme.current().fg_1 };
}
pub fn entries(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10.5, .line_height = 16.0 / 10.5, .use_monospace_font = true, .wrap = .char, .color = theme.current().fg_1 };
}
pub fn eventList(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 8, .flex_shrink = 0 };
}
pub fn eventRow(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .min_height = 20, .flex_shrink = 0 };
}
pub fn note(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10.5, .line_height = 16.0 / 10.5, .color = theme.current().fg_2 };
}
pub fn button(width: f32) ui.BoxStyle {
    return .{ .width = .{ .px = width }, .height = .{ .px = 30 }, .padding = .ZERO, .background = theme.current().surface_2, .text_color = theme.current().fg_2, .font_size = 12, .border = .{ .radius = 8 } };
}
