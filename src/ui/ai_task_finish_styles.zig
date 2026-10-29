//! Existing ai-session-execution .cleanup-row: 9/11 padding, 7 gap,
//! 8 radius, 15 icon, 11.5 title and 10.5 secondary, 28px buttons.
const ui = @import("ui");
const theme = @import("app_theme.zig");
pub fn row(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .row, .align_items = .center, .gap = 7, .padding = .{ .top = 9, .bottom = 9, .left = 11, .right = 11 }, .background = theme.popupInset(), .corner_radius = 8, .flex_shrink = 0 };
}
pub fn title(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11.5, .font_weight = 500, .line_height = 18.0 / 11.5, .color = theme.current().fg_1, .wrap = .word };
}
pub fn secondary(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10.5, .line_height = 16.0 / 10.5, .color = theme.current().fg_2, .wrap = .word };
}
pub fn button(close: bool) @FieldType(ui.widgets.ControlShellConfig, "style") {
    return .{ .height = .{ .px = 28 }, .padding = .{ .left = 11, .right = 11 }, .font_size = 11.5, .font_weight = 400, .corner_radius = 7, .background = if (close) theme.popupAction() else theme.popupInset(), .flex_shrink = 0 };
}
