//! Shared extension list geometry from docs/UI_V4/mcp-services*.svg and skills*.svg.
const ui = @import("ui");
const S = @import("settings_styles.zig");
pub fn skillsToolbar(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 28 }, .min_width = 0, .direction = .row, .align_items = .center, .gap = 12, .flex_shrink = 0 };
}
pub fn service(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .min_width = 0, .min_height = 66, .direction = .column, .gap = 6, .padding = .{ .left = 10, .right = 10, .top = 12, .bottom = 12 }, .background = S.theme.current().well, .border = .{ .radius = 10 }, .flex_shrink = 0 };
}
pub fn identity(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .flex = 1, .min_width = 0, .height = .{ .fit = .{} }, .direction = .column, .gap = 3 };
}
pub fn title(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 12.5, .font_weight = 600, .line_height = 18.0 / 12.5, .color = S.theme.current().fg_1, .text_overflow = .ellipsis, .selectable = false };
}
pub fn metadata(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .line_height = 16.0 / 11.0, .color = S.theme.current().fg_2, .text_overflow = .ellipsis, .selectable = false };
}
pub fn testAction() S.ButtonStyle {
    return .{ .height = .{ .px = 28 }, .padding = .{ .left = 12, .right = 12 }, .background = S.theme.current().selection, .text_color = S.theme.current().accent_ink, .font_size = 12, .font_weight = 500, .corner_radius = 14, .border_width = 0, .flex_shrink = 0 };
}
pub fn moreAction() S.ButtonStyle {
    return .{ .width = .{ .px = 28 }, .height = .{ .px = 28 }, .padding = .{}, .background = ui.Color.TRANSPARENT, .text_color = S.theme.current().fg_2, .corner_radius = 14, .border_width = 0, .flex_shrink = 0 };
}
