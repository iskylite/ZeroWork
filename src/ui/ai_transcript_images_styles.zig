const ui = @import("ui");
const theme = @import("app_theme.zig");
pub fn card(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .padding = .{ .left = 10, .right = 10, .top = 10, .bottom = 10 }, .gap = 6, .flex_shrink = 0, .background = theme.popupInset(), .corner_radius = 8 };
}
pub fn metadata(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .line_height = 1.65, .wrap = .word, .color = theme.current().fg_2 };
}
pub fn button(_: *const ui.ThemeTokens) @FieldType(ui.widgets.ControlShellConfig, "style") {
    return .{ .height = .{ .px = 28 }, .padding = .{ .left = 9, .right = 9, .top = 5, .bottom = 5 }, .font_size = 12.5, .corner_radius = 6 };
}
