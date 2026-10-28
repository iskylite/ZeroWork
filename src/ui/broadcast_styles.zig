const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub const width: f32 = 344;
pub const maximum_height: f32 = 360;
pub const fixed_height: f32 = 108;
pub fn panel() ui.BoxStyle {
    return .{ .position = .absolute, .width = .{ .px = width }, .height = .{ .px = maximum_height }, .direction = .column, .padding = ui.Padding.all(14), .gap = 10, .background = theme.current().overlay, .glass = theme.overlayGlass(), .border = .{ .radius = 14 }, .hit_behavior = .@"opaque" };
}
pub fn row() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 32 }, .direction = .row, .align_items = .center, .gap = 8, .flex_shrink = 0 };
}
pub fn header() ui.BoxStyle {
    var style = row();
    style.height = .{ .px = 28 };
    return style;
}
pub fn body() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 10, .flex_shrink = 0 };
}
pub fn member() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 52 }, .direction = .row, .align_items = .center, .gap = 9, .padding = ui.Padding.all(10), .background = theme.popupInset(), .border = .{ .radius = 8 }, .flex_shrink = 0 };
}
pub fn text(strong: bool) ui.TextStyle {
    return .{ .font_size = if (strong) 12 else 10, .font_weight = if (strong) 500 else 400, .line_height = if (strong) 1.5 else 1.6, .color = if (strong) theme.current().fg_1 else theme.current().fg_2, .text_overflow = .ellipsis };
}
pub fn note() ui.TextStyle {
    var style = text(false);
    style.wrap = .word;
    style.text_overflow = .clip;
    return style;
}
pub fn control(primary: bool) @FieldType(ui.widgets.ControlShellConfig, "style") {
    return .{ .width = .{ .px = 88 }, .height = .{ .px = 32 }, .padding = .{}, .background = if (primary) theme.current().action_accent else theme.popupInset(), .text_color = if (primary) theme.actionForeground(theme.current().action_accent) else theme.current().fg_1, .font_size = 11, .corner_radius = 8, .border_width = 0 };
}

pub fn close() @FieldType(ui.widgets.ControlShellConfig, "style") {
    var style = control(false);
    style.width = .{ .px = 22 };
    style.height = .{ .px = 22 };
    style.background = ui.Color.TRANSPARENT;
    return style;
}
pub fn controlHover(primary: bool) @FieldType(ui.widgets.ControlShellConfig, "style") {
    return .{ .background = if (primary) theme.current().action_accent else theme.current().hover, .text_color = if (primary) theme.actionForeground(theme.current().action_accent) else theme.current().fg_1 };
}
