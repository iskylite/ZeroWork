//! Geometry from app-update/styles.css and its exported 900 × 640 DOM snapshot.
//! Paint always comes from the active global application theme.
const ui = @import("ui");
const shared = @import("../settings_styles.zig");
pub const theme = shared.theme;

pub fn column(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .min_width = 0, .direction = .column, .gap = 0, .flex_shrink = 0 };
}
pub fn card(t: *const ui.ThemeTokens) ui.BoxStyle {
    var style = column(t);
    style.padding = .all(16);
    style.background = theme.current().surface_2;
    style.border = .{ .width = 0, .radius = 11 };
    return style;
}
pub fn row(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .min_width = 0, .direction = .row, .align_items = .center, .gap = 12, .flex_shrink = 0 };
}
pub fn identity(t: *const ui.ThemeTokens) ui.BoxStyle {
    var style = row(t);
    style.padding = .{ .bottom = 16 };
    return style;
}
pub fn appMark(_: *const ui.ThemeTokens) ui.BoxStyle {
    const colors = theme.current();
    return .{ .width = .{ .px = 42 }, .height = .{ .px = 42 }, .align_items = .center, .justify = .center, .background = colors.action_accent, .gradient = .{ .from = colors.action_accent, .to = colors.action_accent_2, .direction = .diagonal }, .border = .{ .width = 0, .radius = 11 }, .flex_shrink = 0 };
}
pub fn badge(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .height = .{ .px = 26 }, .padding = .{ .left = 9, .right = 9 }, .justify = .center, .align_items = .center, .background = theme.popupSelection(), .border = .{ .width = 0, .radius = 6 }, .flex_shrink = 0 };
}
pub fn divider(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 1 }, .background = theme.current().border, .flex_shrink = 0 };
}
pub fn detail(t: *const ui.ThemeTokens) ui.BoxStyle {
    var style = row(t);
    style.padding = .{ .top = 15 };
    return style;
}
pub fn versionFooter(t: *const ui.ThemeTokens) ui.BoxStyle {
    var style = row(t);
    style.margin = .{ .top = 13 };
    style.min_height = 24;
    return style;
}
pub fn preferenceHeader(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 20 }, .min_height = 20, .padding = .ZERO, .gap = 0, .border = .{ .width = 0, .radius = 0 }, .background = ui.Color.TRANSPARENT, .flex_shrink = 0 };
}
pub fn preferenceBody(t: *const ui.ThemeTokens) ui.BoxStyle {
    var style = column(t);
    style.margin = .{ .top = 4 };
    style.padding = .ZERO;
    return style;
}
pub fn preferenceRow(t: *const ui.ThemeTokens) ui.BoxStyle {
    var style = row(t);
    style.min_height = 52;
    style.padding = .ZERO;
    style.gap = 20;
    return style;
}
pub fn notes(t: *const ui.ThemeTokens) ui.BoxStyle {
    var style = column(t);
    style.padding = .{ .left = 5, .right = 5, .top = 2 };
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
    style.height = .{ .px = 18 };
    style.font_weight = 400;
    style.gap = 5;
    return style;
}
