//! Shared assistant card language. HTML: shared/ai-conversation-input.css.
const ui = @import("ui");
const T = @import("app_theme.zig");
pub fn root() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .padding = .{ .left = 14, .right = 14, .bottom = 4 }, .flex_shrink = 0 };
}
pub fn surface() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .padding = .{ .top = 2, .bottom = 2, .left = 8, .right = 8 }, .background = T.popupInset(), .border = .{ .width = 0, .radius = 8 }, .flex_shrink = 0 };
}
pub fn card() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 18 }, .direction = .row, .align_items = .center, .gap = 4, .flex_shrink = 0 };
}
pub fn row() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 18 }, .direction = .row, .align_items = .center, .gap = 4, .flex_shrink = 0 };
}
pub fn queueText(secondary: bool) ui.TextStyle {
    return .{ .font_size = if (secondary) 9 else 10, .line_height = if (secondary) 12.0 / 9.0 else 1.4, .font_weight = 400, .color = T.current().fg_2, .text_overflow = .ellipsis };
}
// Existing consumers outside the queue retain their current style.
pub fn text(secondary: bool) ui.TextStyle {
    return .{ .font_size = if (secondary) 10 else 11.5, .line_height = if (secondary) 1.4 else 16.0 / 11.5, .font_weight = 400, .color = if (secondary) T.current().fg_2 else T.current().fg_1, .text_overflow = .ellipsis };
}
pub fn action() @FieldType(ui.widgets.ControlShellConfig, "style") {
    return .{ .width = .{ .fit = .{} }, .height = .{ .px = 20 }, .padding = .{ .left = 6, .right = 6 }, .font_size = 10, .corner_radius = 6, .background = ui.Color.TRANSPARENT, .text_color = T.current().fg_2, .flex_shrink = 0 };
}
pub fn iconAction() @FieldType(ui.widgets.ControlShellConfig, "style") {
    return .{ .width = .{ .px = 18 }, .height = .{ .px = 18 }, .padding = .{}, .corner_radius = 6, .background = ui.Color.TRANSPARENT, .text_color = T.current().fg_2, .flex_shrink = 0 };
}
