const ui = @import("ui");
pub const wizard = @import("../../ui/wizard_styles.zig");
pub const theme = wizard.theme;

pub const width: f32 = 628;
pub const control_height: f32 = 34;

pub fn layout(_: *const ui.ThemeTokens) ui.BoxStyle {
    return wizard.editorSlot(undefined);
}

pub fn body(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{
        .width = .fill(),
        .height = .{ .fit = .{} },
        .direction = .column,
        .padding = .{ .left = 24, .right = 24, .top = 16, .bottom = 16 },
        .gap = 10,
        .flex_shrink = 0,
    };
}

pub fn field(_: *const ui.ThemeTokens) ui.BoxStyle {
    var result = wizard.stack(undefined);
    result.gap = 5;
    result.min_width = 0;
    return result;
}

pub fn input() ui.BoxStyle {
    var result = wizard.input();
    result.font_size = 13;
    return result;
}

pub fn footer(_: *const ui.ThemeTokens) ui.BoxStyle {
    var result = wizard.footer();
    result.gap = 8;
    return result;
}

pub fn action(primary: bool) ui.BoxStyle {
    var result = wizard.button(0, control_height, primary);
    result.width = .{ .fit = .{} };
    result.padding = .{ .left = 14, .right = 14 };
    result.font_size = 12;
    result.font_weight = 600;
    result.text_color = if (primary) wizard.action(true).color else theme.current().fg_1;
    return result;
}

pub fn segmentTrack(_: *const ui.ThemeTokens) ui.BoxStyle {
    var result = wizard.row(control_height);
    result.gap = 3;
    result.padding = ui.Padding.all(3);
    result.background = theme.popupInset();
    result.border = .{ .radius = 8 };
    return result;
}

pub fn segment(selected: bool) ui.BoxStyle {
    var result = wizard.button(0, 28, false);
    result.width = .fill();
    result.flex = 1;
    result.min_width = 0;
    result.flex_shrink = 1;
    result.background = if (selected) theme.current().overlay else ui.Color.TRANSPARENT;
    result.border = .{ .radius = 6 };
    result.font_size = 12;
    result.font_weight = if (selected) 640 else 500;
    result.text_color = if (selected) theme.current().accent_ink else theme.current().fg_2;
    return result;
}

pub fn feedback(_: *const ui.ThemeTokens) ui.TextStyle {
    var result = wizard.paragraph(undefined);
    result.color = theme.current().danger_ink;
    result.font_size = 12;
    return result;
}
