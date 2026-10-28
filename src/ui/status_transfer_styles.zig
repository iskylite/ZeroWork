//! Current-session ticker: 264x26 while active; idle content fits with 7px side padding.
const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub const ButtonStyle = @FieldType(ui.widgets.ControlShellConfig, "style");
pub fn button() ButtonStyle {
    return .{ .width = .{ .px = 264 }, .height = .{ .px = 26 }, .padding = .{}, .gap = 0, .background = ui.Color.TRANSPARENT, .corner_radius = 7, .border_width = 0, .flex_shrink = 0 };
}
pub fn hover() ButtonStyle {
    return .{ .background = theme.current().hover };
}
pub fn row() ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .left = .{ .px = 7 }, .top = .{ .px = 0 } }, .width = .{ .px = 248 }, .height = .{ .px = 26 }, .direction = .row, .align_items = .center, .gap = 6 };
}
pub fn icon() ui.Style {
    return .{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .flex_shrink = 0 };
}
pub fn label(w: f32) ui.BoxStyle {
    return .{ .width = .{ .px = w }, .height = .{ .px = 16 }, .flex_shrink = 0, .overflow_hidden = true };
}
pub fn text(primary: bool) ui.TextStyle {
    return .{ .font_size = if (primary) 10.5 else 10, .font_weight = 400, .line_height = if (primary) 16.0 / 10.5 else 1.6, .color = theme.current().fg_2, .text_overflow = .ellipsis, .selectable = false };
}
pub fn track() ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .left = .{ .px = 8 }, .top = .{ .px = 23 } }, .width = .{ .px = 248 }, .height = .{ .px = 2 }, .background = theme.current().well, .border = .{ .radius = 1 } };
}
pub fn fill(w: f32) ui.BoxStyle {
    return .{ .width = .{ .px = w }, .height = .{ .px = 2 }, .background = theme.current().accent, .border = .{ .radius = 1 } };
}
