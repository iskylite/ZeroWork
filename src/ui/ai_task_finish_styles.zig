//! Existing ai-session-execution .cleanup-row: 9/11 padding, 7 gap,
//! 8 radius, 15 icon, 11.5 title and 10.5 secondary, 28px buttons.
const ui = @import("ui");
const theme = @import("app_theme.zig");
pub fn row(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .align_items = .start, .gap = 2, .padding = .{ .top = 9, .bottom = 9, .left = 11, .right = 11 }, .background = theme.popupInset(), .corner_radius = 8, .flex_shrink = 0 };
}
pub fn title(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11.5, .font_weight = 500, .line_height = 18.0 / 11.5, .color = theme.current().fg_1, .wrap = .word };
}
pub fn secondary(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10.5, .line_height = 16.0 / 10.5, .color = theme.current().fg_2, .wrap = .word };
}
pub const session_tag_padding: f32 = 6;
pub const session_tag_max_width: f32 = 320;

pub fn sessionTagBackground() ui.Color {
    return theme.current().fg_2.withAlpha(24);
}
pub fn sessionTag() ui.BoxStyle {
    return .{ .height = .{ .px = 18 }, .align_items = .center, .padding = .{ .left = session_tag_padding, .right = session_tag_padding }, .background = sessionTagBackground(), .corner_radius = 4 };
}
pub fn sessionTagText(tokens: *const ui.ThemeTokens) ui.TextStyle {
    var text = secondary(tokens);
    text.wrap = .none;
    text.text_overflow = .ellipsis;
    return text;
}
pub fn button(close: bool) @FieldType(ui.widgets.ControlShellConfig, "style") {
    return .{ .height = .{ .px = 28 }, .padding = .{ .left = 11, .right = 11 }, .font_size = 11.5, .font_weight = 400, .corner_radius = 7, .background = if (close) theme.popupAction() else theme.popupInset(), .flex_shrink = 0 };
}
