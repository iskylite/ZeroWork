//! Bridge 342:1184716 (260/28px context) and 342:1217445 (340px history).
const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub const ButtonStyle = @FieldType(ui.widgets.ControlShellConfig, "style");
pub fn panel(history: bool) ui.BoxStyle {
    return .{ .width = .{ .px = if (history) 340 else 260 }, .height = .{ .fit = .{} }, .direction = .column, .gap = 0, .padding = ui.Padding.all(10), .background = theme.current().overlay, .border = .{ .radius = 14 }, .shadow = .{ .blur = 28, .offset_y = 10, .color = theme.current().shadow } };
}
pub fn row() ButtonStyle {
    return .{ .width = .fill(), .height = .{ .px = 28 }, .direction = .row, .justify = .start, .align_items = .center, .padding = .{ .left = 0, .right = 0 }, .font_size = 11, .font_weight = 400, .text_color = theme.current().fg_1, .background = ui.Color.TRANSPARENT, .corner_radius = 7, .border_width = 0 };
}
pub fn hover() ButtonStyle {
    return .{ .background = theme.current().hover };
}
pub fn heading(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11.5, .font_weight = 500, .line_height = 18.0 / 11.5, .color = theme.current().fg_1 };
}
pub fn feedback(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10.5, .line_height = 16.0 / 10.5, .color = theme.current().danger, .wrap = .word };
}
