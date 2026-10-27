const ui = @import("ui");
const theme = @import("app_theme.zig");
const terminal = @import("terminal_styles.zig");
const notification = @import("notification_styles.zig");

// Status, bounded output preview, then compact metadata and action.
pub fn panel(width: f32) ui.BoxStyle {
    var style = notification.card(&ui.theme.dark);
    const anchor = terminal.copiedMessage(&ui.theme.dark);
    style.position = anchor.position;
    style.inset = anchor.inset;
    style.width = .{ .px = @min(terminal.message_width, @max(0, width - terminal.message_inset * 2)) };
    style.height = .{ .fit = .{} };
    style.direction = .column;
    style.align_items = .stretch;
    style.z_index = 32;
    return style;
}
pub fn header(_: *const ui.ThemeTokens) ui.BoxStyle {
    var style = notification.header(&ui.theme.dark);
    style.flex_shrink = 0;
    return style;
}
pub fn title(_: *const ui.ThemeTokens) ui.TextStyle {
    return notification.title(&ui.theme.dark);
}
pub fn detail(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .font_weight = 400, .line_height = 18.0 / 11.0, .color = theme.current().fg_2, .selectable = false };
}
pub fn textBox(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 18 }, .min_width = 0, .overflow = .hidden, .flex = 1 };
}
pub fn actions(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 24 }, .direction = .row, .gap = 12, .justify = .space_between, .align_items = .center, .flex_shrink = 0 };
}
pub fn open(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .height = .{ .px = 24 }, .padding = .{ .left = 10, .right = 10 }, .gap = 0, .align_items = .center, .justify = .center, .background = theme.current().action_accent, .border = .{ .radius = 6 }, .flex_shrink = 0 };
}
pub fn openHover() ui.BoxStyle {
    return .{ .background = theme.current().action_accent_2 };
}
pub fn actionText(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .font_weight = 500, .line_height = 1.5, .color = theme.actionForeground(theme.current().action_accent), .selectable = false };
}

pub fn summary(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .line_height = 18.0 / 11.0, .color = theme.current().fg_2, .text_overflow = .ellipsis, .selectable = false };
}

pub fn exitTag(_: *const ui.ThemeTokens) ui.BoxStyle {
    return exitTagFor(1);
}

// Interrupted/terminated commands use warning; other nonzero results are errors.
pub fn exitInk(code: i32) ui.Color {
    const c = theme.current();
    return if (code == 0) c.ok_ink else if (code == 130 or code == 143) c.warn_ink else c.danger_ink;
}
pub fn exitTagFor(code: i32) ui.BoxStyle {
    const c = theme.current();
    const color = if (code == 0) c.ok else if (code == 130 or code == 143) c.warn else c.danger;
    return .{ .height = .{ .px = 20 }, .padding = .{ .left = 6, .right = 6 }, .align_items = .center, .justify = .center, .background = color.withAlpha(23), .border = .{ .radius = 4, .width = 1, .color = color.withAlpha(64) }, .flex_shrink = 0 };
}
