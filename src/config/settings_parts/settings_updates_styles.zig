//! Geometry for the About/update page.
//! Paint always comes from the active global application theme.
const ui = @import("ui");
const std = @import("std");
const shared = @import("../settings_styles.zig");
pub const theme = shared.theme;

pub fn column(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .min_width = 0, .direction = .column, .gap = 0, .flex_shrink = 0 };
}
pub fn card(t: *const ui.ThemeTokens) ui.BoxStyle {
    var style = column(t);
    style.padding = .all(16);
    style.gap = 12;
    style.background = theme.settingsCard();
    style.border = .{ .width = 0, .radius = 11 };
    return style;
}
pub fn row(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .min_width = 0, .direction = .row, .align_items = .center, .gap = 12, .flex_shrink = 0 };
}
pub fn identity(t: *const ui.ThemeTokens) ui.BoxStyle {
    return row(t);
}
pub fn appMark(_: *const ui.ThemeTokens) ui.BoxStyle {
    const colors = theme.current();
    return .{ .width = .{ .px = 40 }, .height = .{ .px = 40 }, .align_items = .center, .justify = .center, .background = colors.action_accent, .border = .{ .width = 0, .radius = 10 }, .flex_shrink = 0 };
}
pub fn badge(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .fit = .{} }, .height = .{ .px = 24 }, .padding = .{ .left = 10, .right = 10 }, .justify = .center, .align_items = .center, .background = theme.current().fg_2.withAlpha(26), .border = .{ .width = 0, .radius = 6 }, .flex_shrink = 0 };
}
pub fn badgeInk(state: []const u8, label: []const u8) ui.Color {
    const colors = theme.current();
    if (std.mem.eql(u8, state, "failed") or std.mem.eql(u8, state, "draining")) return colors.warn_ink;
    if (std.mem.eql(u8, state, "ready") or std.mem.eql(u8, label, "无需更新")) return colors.ok_ink;
    if (state.len == 0 or std.mem.eql(u8, state, "idle")) return colors.fg_2;
    return colors.accent_ink;
}
pub fn detail(t: *const ui.ThemeTokens) ui.BoxStyle {
    return row(t);
}
pub fn preferenceRow(t: *const ui.ThemeTokens) ui.BoxStyle {
    var style = row(t);
    style.min_height = 37;
    style.padding = .{ .top = 10, .bottom = 10 };
    style.gap = 16;
    return style;
}
pub fn notes(t: *const ui.ThemeTokens) ui.BoxStyle {
    var style = column(t);
    style.padding = .all(4);
    style.gap = 6;
    return style;
}
pub fn primaryButton() shared.ButtonStyle {
    var style = shared.actionControl(false);
    style.background = theme.current().action_accent;
    style.text_color = theme.actionForeground(theme.current().action_accent);
    style.font_size = 12;
    style.font_weight = 500;
    style.width = .{ .fit = .{} };
    return style;
}
pub fn textButton() shared.ButtonStyle {
    var style = shared.textButton();
    style.width = .{ .fit = .{} };
    style.height = .{ .px = 24 };
    style.padding = .ZERO;
    style.background = ui.Color.TRANSPARENT;
    style.text_color = theme.current().accent_ink;
    style.font_size = 11;
    style.font_weight = 500;
    return style;
}

pub fn sourceButton() shared.ButtonStyle {
    var style = textButton();
    style.height = .{ .px = 16 };
    style.font_weight = 400;
    style.gap = 5;
    return style;
}
