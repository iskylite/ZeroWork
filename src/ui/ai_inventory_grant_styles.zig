//! On-demand inventory approval, reusing the native host approval surface.
const ui = @import("ui");
const theme = @import("app_theme.zig");
const approval = @import("ai_tool_approval_styles.zig");
pub const ButtonStyle = approval.ButtonStyle;
pub fn root(tokens: *const ui.ThemeTokens) ui.BoxStyle {
    var value = approval.panel(tokens);
    value.height = .{ .fit = .{} };
    value.min_width = 0;
    value.gap = 8;
    return value;
}
pub fn header(tokens: *const ui.ThemeTokens) ui.BoxStyle {
    var value = approval.header(tokens);
    value.margin = .{};
    return value;
}
pub const title = approval.title;
pub fn text(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 12, .line_height = 18.0 / 12.0, .color = theme.current().fg_2, .wrap = .word };
}
pub fn secondary(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .line_height = 16.0 / 11.0, .color = theme.current().fg_2, .wrap = .word };
}
pub fn actions(tokens: *const ui.ThemeTokens) ui.BoxStyle {
    var value = approval.footer(tokens);
    value.height = .{ .fit = .{} };
    value.min_height = 26.5;
    value.flex_wrap = .no_wrap;
    return value;
}
pub fn button(primary: bool) approval.ButtonStyle {
    var value = approval.iconButton(primary);
    // Background material never fades foreground text, including disabled state.
    value.opacity = 1;
    value.text_color = if (primary) theme.actionForeground(theme.current().action_accent) else theme.current().fg_1;
    value.width = .{ .px = 76 };
    return value;
}
/// Button's public frame forwards dimensions/background but omits gradient and
/// shadow. Apply the existing V3 primary paint directly to its native node.
pub fn primaryPaint(enabled: bool) ui.BoxStyle {
    const value = @import("shell_styles.zig").emptyButton(true);
    return .{
        .background = if (enabled) theme.current().action_accent else theme.popupAction(),
        .gradient = if (enabled) value.gradient else .{ .from = theme.popupAction(), .to = theme.popupAction(), .direction = .diagonal },
        .shadow = if (enabled) value.shadow else .{ .blur = 0, .color = ui.Color.TRANSPARENT },
        .inset_shadow = if (enabled) value.inset_shadow else .{ .blur = 0, .color = ui.Color.TRANSPARENT },
    };
}
