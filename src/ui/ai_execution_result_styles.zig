//! Only the new host PTY execution card uses these recipes.
const ui = @import("ui");
const theme = @import("app_theme.zig");
pub const ButtonStyle = @FieldType(ui.widgets.ControlShellConfig, "style");
pub fn card(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .min_width = 0, .background = theme.popupAction(), .corner_radius = 9, .overflow = .hidden, .flex_shrink = 0 };
}
pub fn header(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 32 }, .direction = .row, .align_items = .center, .justify = .start, .gap = 6, .padding = .{ .left = 10, .right = 12 }, .flex_shrink = 0 };
}
pub fn headerButton() ButtonStyle {
    return .{ .width = .fill(), .height = .{ .px = 32 }, .padding = .{ .left = 10, .right = 12 }, .gap = 6, .background = ui.Color.TRANSPARENT, .corner_radius = 9, .flex_shrink = 0 };
}
pub fn title(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 12, .font_weight = 500, .line_height = 1.5, .color = theme.current().fg_1, .text_overflow = .ellipsis };
}
pub fn body(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{ .max = 150 } }, .min_width = 0, .flex_shrink = 0 };
}
pub fn content(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 6, .padding = .{ .left = 12, .right = 12, .top = 4, .bottom = 8 }, .flex_shrink = 0 };
}
pub fn text(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 12, .line_height = 1.5, .wrap = .word, .color = theme.patchInk(theme.current().fg_2, &.{theme.popupAction()}) };
}
pub fn metadata(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10.5, .line_height = 16.0 / 10.5, .wrap = .word, .color = theme.patchInk(theme.current().fg_2, &.{theme.popupAction()}) };
}
pub fn summary(tokens: *const ui.ThemeTokens) ui.TextStyle {
    var style = metadata(tokens);
    style.wrap = .none;
    style.text_overflow = .ellipsis;
    return style;
}
pub fn identity(tokens: *const ui.ThemeTokens) ui.TextStyle {
    var style = metadata(tokens);
    style.use_monospace_font = true;
    return style;
}
pub fn mono(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .line_height = 16.0 / 11.0, .wrap = .word, .use_monospace_font = true, .color = theme.current().fg_1 };
}
pub fn output(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .min_width = 0, .flex_shrink = 0, .background = theme.popupInset(), .corner_radius = 7 };
}
pub fn footer(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .min_height = 34, .direction = .row, .align_items = .center, .flex_wrap = .wrap, .gap = 6, .padding = .{ .left = 8, .right = 8, .top = 3, .bottom = 3 }, .flex_shrink = 0 };
}
pub fn action() ButtonStyle {
    return .{ .width = .{ .fit = .{} }, .height = .{ .px = 28 }, .padding = .{ .left = 8, .right = 8, .top = 4, .bottom = 4 }, .font_size = 12, .font_weight = 500, .background = ui.Color.TRANSPARENT, .text_color = theme.patchInk(theme.current().accent_ink, &.{theme.popupAction()}), .corner_radius = 7, .flex_shrink = 0 };
}
pub fn iconButton() ButtonStyle {
    return .{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .padding = .{}, .background = ui.Color.TRANSPARENT, .corner_radius = 7, .flex_shrink = 0 };
}
