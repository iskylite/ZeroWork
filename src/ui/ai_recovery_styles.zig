//! Figma 339:1016605 / 358:1487295–7321: recovery stays in the scrollable conversation.
const ui = @import("ui");
const theme = @import("app_theme.zig");
pub fn root(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .direction = .column, .gap = 8, .padding = .{ .right = 12 }, .flex_shrink = 0 };
}
pub fn row(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 28 }, .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0 };
}
pub fn text(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10.5, .line_height = 16.0 / 10.5, .color = theme.current().fg_2, .wrap = .word };
}
pub fn warning(_: *const ui.ThemeTokens) ui.TextStyle {
    var value = text(undefined);
    value.color = theme.current().warn_ink;
    return value;
}
pub fn action(primary: bool, edit: bool, enabled: bool) ui.BoxStyle {
    
    return .{ .width = .{ .px = if (primary) 140 else if (edit) 28 else 88 }, .height = .{ .px = 28 }, .padding = .{}, .flex_shrink = 0, .corner_radius = 8, .font_size = 12, .font_weight = 500, .opacity = if (enabled) 1 else 0.72, .background = if (primary and enabled) theme.current().accent else theme.current().surface_2, .text_color = if (primary and enabled) ui.Color.WHITE else theme.current().fg_2 };
}
pub fn statusRow(_: *const ui.ThemeTokens) ui.BoxStyle {
    var value = row(undefined);
    value.height = .{ .fit = .{} };
    value.min_height = 24;
    return value;
}
pub fn attemptsRow(_: *const ui.ThemeTokens) ui.BoxStyle {
    var value = row(undefined);
    value.height = .{ .px = 26 };
    return value;
}
pub fn badge(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = 126 }, .height = .{ .px = 22 }, .direction = .row, .align_items = .center, .padding = .{ .left = 8, .right = 8 }, .background = theme.current().surface_2, .border = .{ .radius = 8 }, .flex_shrink = 0 };
}
pub fn icon() ui.Style {
    return .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .flex_shrink = 0 };
}
