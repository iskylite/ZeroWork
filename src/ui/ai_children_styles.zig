//! Child list and dialog share the application's current theme tokens.
const ui = @import("ui");
const theme = @import("app_theme.zig");
pub fn popup(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .background = theme.current().overlay, .glass = theme.overlayGlass(), .border = .{ .radius = 12 }, .padding = ui.Padding.all(8), .shadows = ui.ShadowList.of(&.{theme.floatingShadow()}) };
}
pub fn name(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 12, .font_weight = 600, .color = theme.current().fg_1, .text_overflow = .ellipsis };
}
pub fn secondary(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .color = theme.current().fg_2, .text_overflow = .ellipsis };
}
pub fn detail(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .color = theme.current().fg_2, .wrap = .word };
}
pub fn status(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .color = theme.current().accent };
}

pub fn settings(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .background = theme.current().overlay, .glass = theme.overlayGlass(), .border = .{ .width = 0, .radius = 11 }, .direction = .column, .padding = .{}, .overflow_hidden = true, .shadows = ui.ShadowList.of(&.{theme.floatingShadow()}) };
}

pub fn settingsBody(viewport_height: f32) ui.BoxStyle {
    const limit = @max(80, @min(300, viewport_height - 136));
    return .{ .width = .fill(), .height = .{ .fit = .{ .max = limit } }, .max_height = limit, .min_height = 0, .flex_shrink = 0 };
}
pub fn settingsContent(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .padding = .{ .left = 12, .right = 12, .top = 2, .bottom = 12 }, .gap = 8, .flex_shrink = 0 };
}
pub fn settingsRow(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .min_height = 28, .direction = .row, .align_items = .center, .gap = 12, .flex_shrink = 0 };
}
pub fn settingLabel(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 12, .font_weight = 500, .color = theme.current().fg_1, .text_overflow = .ellipsis };
}
pub fn divider(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 1 }, .background = theme.current().border, .flex_shrink = 0 };
}
pub fn settingsFooter(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 40 }, .direction = .row, .align_items = .center, .justify = .end, .padding = .{ .left = 12, .right = 12 }, .border_top_width = 1, .border_top_color = theme.current().border, .flex_shrink = 0 };
}
