//! Bridge 370:1640095 / 370:1649531: 572 wide, gap4, row32, list104.
const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub const ButtonStyle = @FieldType(ui.widgets.ControlShellConfig, "style");
pub fn root(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 4, .flex_shrink = 0, .padding = .{ .left = 14, .right = 14 } };
}
pub fn row(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 24 }, .direction = .row, .gap = 4, .align_items = .center, .flex_shrink = 0 };
}
pub fn text(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10.5, .line_height = 16.0 / 10.5, .color = theme.current().fg_2, .text_overflow = .ellipsis };
}
pub fn heading(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11.5, .line_height = 18.0 / 11.5, .font_weight = 500, .color = theme.current().fg_1 };
}
pub fn input() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 32 }, .background = theme.current().well, .padding = .{ .left = 8, .right = 6 }, .border = .{ .radius = 8 }, .flex_shrink = 0 };
}
pub fn button() ButtonStyle {
    return .{ .height = .{ .px = 22 }, .padding = .{ .left = 6, .right = 6 }, .corner_radius = 6, .background = ui.Color.TRANSPARENT, .flex_shrink = 0 };
}
pub fn option() ButtonStyle {
    return .{ .width = .fill(), .height = .{ .px = 32 }, .padding = .{ .left = 8, .right = 6 }, .corner_radius = 8, .background = theme.current().well, .justify = .start };
}
pub fn hover() ButtonStyle {
    return .{ .background = theme.current().hover };
}
pub fn list() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 104 }, .min_height = 0, .flex_shrink = 0 };
}
