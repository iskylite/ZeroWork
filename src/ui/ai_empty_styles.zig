//! Empty assistant states: Figma 223:330797 and 236:418549.
const ui = @import("ui");
const theme = @import("app_theme.zig");
pub fn root(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .direction = .column, .gap = 8 };
}
pub fn row(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .direction = .row, .align_items = .center, .gap = 6 };
}
pub fn status(configured: bool) ui.TextStyle {
    return .{ .font_size = 10.5, .line_height = 16.0 / 10.5, .color = if (configured) theme.current().accent else theme.current().warn };
}
pub fn action(configured: bool, primary: bool) ui.BoxStyle {
    return .{ .width = if (configured) .fill() else .{ .px = 144 }, .height = .{ .px = if (configured) 30 else 28 }, .flex = if (configured) 1 else 0, .flex_shrink = 0, .padding = .{ .left = 10, .right = 8 }, .corner_radius = 8, .background = if (primary) theme.current().accent else theme.current().well, .font_size = if (configured) 11.5 else 12 };
}

pub fn statusRow(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 24 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .gap = 6 };
}
pub fn icon() ui.Style {
    return .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .flex_shrink = 0 };
}
