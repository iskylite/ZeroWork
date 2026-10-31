//! Editable baseline: docs/UI_V3/ai-close-confirmation.html (320×360, 100%).
//! Measured panel 288×106, 12px padding; title 20, detail 18, actions 28.
const ui = @import("ui");
const theme = @import("app_theme.zig");
pub const width: f32 = 288;
pub const ButtonStyle = @FieldType(ui.widgets.ControlShellConfig, "style");
pub fn chrome(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .background = theme.current().overlay.withAlpha(255), .border = .{ .width = 0, .radius = 10 }, .corner_radius = 10, .padding = .{}, .shadows = ui.ShadowList.of(&.{ .{ .offset_y = 8, .blur = 24, .color = ui.arb.hexA(0x000000, 0.13) }, .{ .offset_y = 2, .blur = 6, .color = ui.arb.hexA(0x000000, 0.13) } }) };
}
pub fn panel(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .min_width = 0, .direction = .column, .padding = ui.Padding.all(12), .gap = 4, .flex_shrink = 0 };
}
pub fn title(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 13, .font_weight = 600, .line_height = 20.0 / 13.0, .color = theme.current().fg_1, .wrap = .word };
}
pub fn detail(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 12, .line_height = 18.0 / 12.0, .color = theme.current().fg_2, .wrap = .word };
}
pub fn actions(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 28 }, .direction = .row, .align_items = .center, .justify = .end, .gap = 8, .margin = .{ .top = 8 }, .flex_shrink = 0 };
}
pub fn button(primary: bool) ButtonStyle {
    return .{ .width = .{ .fit = .{} }, .height = .{ .px = 28 }, .min_width = 0, .padding = .{ .left = 10, .right = 10 }, .gap = 0, .font_size = 12, .font_weight = 500, .flex_shrink = 0, .corner_radius = 7, .background = if (primary) theme.current().action_accent else theme.popupAction(), .text_color = if (primary) theme.actionForeground(theme.current().action_accent) else theme.current().fg_1 };
}
