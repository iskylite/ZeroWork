//! Bridge 342:1184716 (260/28px context) and 342:1217445 (340px history).
const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub const ButtonStyle = @FieldType(ui.widgets.ControlShellConfig, "style");
pub fn panel(history: bool) ui.BoxStyle {
    return .{ .width = .{ .px = if (history) 340 else 224 }, .height = .{ .fit = .{} }, .direction = .column, .gap = 0, .padding = ui.Padding.all(if (history) 10 else 6), .background = theme.current().overlay, .glass = theme.overlayGlass(), .border = .{ .radius = if (history) 14 else 10 }, .shadow = .{ .blur = 28, .offset_y = 10, .color = theme.current().shadow } };
}
pub fn row(history: bool) ButtonStyle {
    return .{ .width = .fill(), .height = .{ .px = if (history) 28 else 34 }, .direction = .row, .justify = .start, .align_items = .center, .padding = .{ .left = 10, .right = 10 }, .font_size = if (history) 11 else 12, .font_weight = 400, .text_color = theme.current().fg_1, .background = ui.Color.TRANSPARENT, .corner_radius = 7, .border_width = 0 };
}
pub fn hover() ButtonStyle {
    return .{ .background = theme.current().hover };
}
pub fn heading(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 13, .font_weight = 700, .line_height = 18.0 / 13.0, .color = theme.current().fg_1 };
}
pub fn feedback(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10.5, .line_height = 16.0 / 10.5, .color = theme.current().danger, .wrap = .word };
}
