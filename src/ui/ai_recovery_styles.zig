//! Figma 339:1016605 / 358:1487295–7321: recovery stays in the scrollable conversation.
const ui = @import("ui");
const theme = @import("app_theme.zig");
pub fn root(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .direction = .column, .gap = 6, .padding = .{}, .flex_shrink = 0 };
}
pub fn row(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 30 }, .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0 };
}
pub fn text(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 12.5, .line_height = 1.65, .color = theme.current().fg_2, .wrap = .word };
}
pub fn warning(_: *const ui.ThemeTokens) ui.TextStyle {
    var value = text(undefined);
    value.color = theme.current().danger_ink;
    value.font_size = 11;
    value.line_height = 1.65;
    return value;
}
pub fn action(primary: bool, edit: bool, enabled: bool) ui.BoxStyle {
    return .{ .width = .{ .px = if (primary) 53 else if (edit) 28 else 79 }, .height = .{ .px = if (edit) 28 else 38.625 }, .padding = .{ .left = if (edit) 0 else 14, .right = if (edit) 0 else 14, .top = if (edit) 0 else 6, .bottom = if (edit) 0 else 6 }, .flex_shrink = 0, .corner_radius = 8, .font_size = 11, .font_weight = 500, .opacity = if (enabled) 1 else 0.72, .background = theme.current().hover, .text_color = theme.current().fg_1 };
}
pub fn statusRow(_: *const ui.ThemeTokens) ui.BoxStyle {
    var value = row(undefined);
    value.height = .{ .fit = .{} };
    value.min_height = 18.15;
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
