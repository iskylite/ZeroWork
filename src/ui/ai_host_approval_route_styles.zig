//! Local route selector, measured from host-approval.html?route=ask.
const ui = @import("ui");
const theme = @import("app_theme.zig");
const S = @import("ai_tool_approval_styles.zig");
pub fn row(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 32 }, .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0 };
}
pub fn reason(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .line_height = 20.0 / 11.0, .color = theme.current().fg_2, .wrap = .word };
}
pub fn button(selected: bool) S.ButtonStyle {
    return .{ .width = .{ .fit = .{} }, .height = .{ .px = 26.5 }, .padding = .{ .left = 8, .right = 8, .top = 4, .bottom = 4 }, .font_size = 12, .font_weight = 500, .corner_radius = 8, .background = if (selected) theme.popupSelection() else theme.popupAction(), .flex_shrink = 0 };
}
