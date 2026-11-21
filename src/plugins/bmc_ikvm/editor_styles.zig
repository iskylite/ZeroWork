//! KVM connection form styles aligned with the shared wizard shell.
const ui = @import("ui");
pub const host = @import("../../ui/wizard_styles.zig");
pub const theme = host.theme;
pub const width: f32 = host.width;

pub fn root(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .min_height = 0, .direction = .column, .gap = 0, .flex = 1 };
}
pub fn content(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .padding = .{ .bottom = 12 }, .gap = 12, .flex_shrink = 0 };
}
pub fn row(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .row, .align_items = .start, .gap = 16, .min_width = 0, .flex_shrink = 0 };
}
pub fn field(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 5, .min_width = 0, .flex = 1, .flex_shrink = 1 };
}
pub fn label(tokens: *const ui.ThemeTokens) ui.TextStyle {
    return host.label(tokens);
}
pub fn section(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 18 }, .direction = .row, .align_items = .center, .gap = 10, .flex_shrink = 0 };
}
pub fn sectionLabel(_: *const ui.ThemeTokens) ui.TextStyle {
    return host.text(12, 700, false);
}
pub fn input(_: *const ui.ThemeTokens) ui.BoxStyle {
    return host.input();
}
pub fn inputSlot(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .min_height = 34, .min_width = 0, .flex_shrink = 0 };
}
pub fn footer(_: *const ui.ThemeTokens) ui.BoxStyle {
    return host.footer();
}
pub fn action(primary: bool) ui.BoxStyle {
    var value = host.button(0, 34, primary);
    value.width = .{ .fit = .{} };
    value.padding = .{ .left = 14, .right = 14, .top = 8, .bottom = 8 };
    value.border.?.radius = 8;
    value.font_size = 12;
    value.font_weight = 500;
    value.text_color = if (primary) host.action(true).color else theme.current().fg_2;
    return value;
}
pub fn feedback(_: *const ui.ThemeTokens) ui.TextStyle {
    var value = host.paragraph(undefined);
    value.font_size = 11;
    value.line_height = 17.0 / 11.0;
    value.color = theme.current().fg_2;
    return value;
}
pub fn feedbackArea(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{
        .width = .fill(),
        .height = .{ .fit = .{} },
        .min_height = 36,
        .direction = .row,
        .align_items = .center,
        .gap = 10,
        .margin = .{ .left = 24, .right = 24, .bottom = 8 },
        .padding = .{ .left = 14, .right = 14, .top = 8, .bottom = 8 },
        .background = theme.popupInset(),
        .border = .{ .radius = 8 },
        .flex_shrink = 0,
    };
}
pub fn logAction() ui.BoxStyle {
    var value = action(false);
    value.width = .{ .px = 26 };
    value.height = .{ .px = 26 };
    value.padding = .{};
    value.background = ui.Color.TRANSPARENT;
    value.font_size = 11;
    value.text_color = theme.current().accent;
    return value;
}
pub fn logBody(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .padding = ui.Padding.all(16), .gap = 12, .min_height = 0 };
}
pub fn logText(_: *const ui.ThemeTokens) ui.TextStyle {
    var value = feedback(undefined);
    value.line_height = 20.0 / 11.0;
    value.use_monospace_font = true;
    return value;
}
pub fn errorText(_: *const ui.ThemeTokens) ui.TextStyle {
    var value = host.paragraph(undefined);
    value.color = theme.current().danger_ink;
    return value;
}
pub fn savePassword(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .height = .{ .px = 34 }, .width = .{ .fit = .{} }, .gap = 8, .align_items = .center, .flex_shrink = 0 };
}
