const ui = @import("ui");
const theme = @import("app_theme.zig");
const terminal = @import("terminal_styles.zig");

// Reuse the pane toast's Bridge geometry, 392:1833356 / 3701 / 4046.
pub fn panel(width: f32) ui.BoxStyle {
    var style = terminal.copiedMessage(&ui.theme.dark);
    style.width = .{ .px = @min(terminal.message_width, @max(0, width - terminal.message_inset * 2)) };
    style.height = .{ .px = 100 };
    style.direction = .column;
    style.align_items = .stretch;
    style.z_index = 32;
    return style;
}
pub fn header(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 24 }, .direction = .row, .align_items = .center, .gap = 4, .flex_shrink = 0 };
}
pub fn title(_: *const ui.ThemeTokens) ui.TextStyle {
    return terminal.copiedText(&ui.theme.dark);
}
pub fn detail(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10.5, .font_weight = 400, .line_height = 16.0 / 10.5, .color = theme.current().fg_2, .selectable = false };
}
pub fn textBox(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 18 }, .min_width = 0, .overflow = .hidden, .flex = 1 };
}
pub fn actions(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 28 }, .direction = .row, .justify = .end, .align_items = .center, .flex_shrink = 0 };
}
pub fn open(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = 108 }, .height = .{ .px = 28 }, .padding = .ZERO, .gap = 0, .align_items = .center, .justify = .center, .background = theme.current().surface_2, .border = .{ .radius = 8 }, .flex_shrink = 0 };
}
pub fn actionText(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 12, .font_weight = 500, .line_height = 1.5, .color = theme.current().fg_2, .selectable = false };
}
