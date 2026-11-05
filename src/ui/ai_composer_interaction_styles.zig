//! Measured baseline: docs/UI_V3/ai/composer-interactions.html, 600×456, 1×.
const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub const ButtonStyle = @FieldType(ui.widgets.ControlShellConfig, "style");
pub fn panel(question: bool, routing: bool) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = if (question) 180 else if (routing) 164 else 132 }, .min_height = 0, .flex_shrink = 0 };
}
pub fn content() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 8, .padding = .{ .top = 6 }, .flex_shrink = 0 };
}
pub fn heading() ui.BoxStyle {
    return .{ .width = .fill(), .direction = .row, .align_items = .start, .gap = 6, .flex_shrink = 0 };
}
pub fn text(size: f32, line: f32, weight: u16, secondary: bool) ui.TextStyle {
    return .{ .font_size = size, .line_height = line / size, .font_weight = weight, .wrap = .word, .color = if (secondary) theme.current().fg_2 else theme.current().fg_1 };
}
pub fn action(primary: bool) ButtonStyle {
    return .{ .width = .{ .fit = .{} }, .height = .{ .px = 24 }, .padding = .{ .left = 8, .right = 8 }, .gap = 4, .font_size = 10, .font_weight = 400, .corner_radius = 8, .background = if (primary) theme.current().action_accent else theme.popupAction(), .flex_shrink = 0 };
}
pub fn hover() ui.BoxStyle {
    return .{ .background = theme.states().hover };
}
pub fn actions() ui.BoxStyle {
    return .{ .width = .fill(), .flex = 1, .min_width = 0, .height = .{ .px = 28 }, .direction = .row, .align_items = .center, .gap = 8 };
}
pub fn pending() ButtonStyle {
    var style = action(false);
    style.height = .{ .px = 26 };
    style.font_size = 11;
    style.gap = 6;
    style.background = theme.current().surface_2;
    return style;
}
pub fn icon(size: f32) ui.Style {
    return .{ .width = .{ .px = size }, .height = .{ .px = size }, .flex_shrink = 0 };
}
pub fn option(selected: bool) ui.BoxStyle {
    return .{ .width = .fill(), .min_height = 36, .height = .{ .fit = .{} }, .direction = .row, .align_items = .center, .gap = 8, .padding = .{ .top = 4, .bottom = 4, .left = 8, .right = 8 }, .border = .{ .radius = 7 }, .background = if (selected) theme.popupSelection() else ui.Color.TRANSPARENT, .flex_shrink = 0 };
}
