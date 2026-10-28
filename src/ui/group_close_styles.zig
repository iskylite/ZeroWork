//! Exact Bridge readback: 603:313848 / 603:313874, 480×294 / 480×248.
const ui = @import("ui");
const theme = @import("app_theme.zig");
pub fn dialog(partial: bool) ui.BoxStyle {
    return .{ .width = .{ .px = 480 }, .height = .{ .px = if (partial) 248 else 294 }, .padding = .{}, .background = theme.current().overlay, .glass = theme.overlayGlass(), .border = .{ .radius = 11 } };
}
pub fn body() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .position = .relative, .padding = .{} };
}
pub fn slot(y: f32, height: f32) ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .left = .{ .px = 12 }, .top = .{ .px = y } }, .width = .{ .px = 456 }, .height = .{ .px = height }, .flex_shrink = 0 };
}
pub fn title() ui.TextStyle {
    return .{ .font_size = 13, .font_weight = 700, .color = theme.current().fg_1, .line_height = 20.0 / 13.0 };
}
pub fn text(strong: bool) ui.TextStyle {
    return .{ .font_size = 12, .color = if (strong) theme.current().fg_1 else theme.current().fg_2, .line_height = 1.5, .wrap = .word };
}
pub fn note() ui.TextStyle {
    return .{ .font_size = 10.5, .color = theme.current().fg_2, .line_height = 16.0 / 10.5, .wrap = .word };
}
pub fn list() ui.BoxStyle {
    return .{ .direction = .column, .width = .fill(), .gap = 6, .margin = .{ .bottom = 6 }, .padding = ui.Padding.all(8), .background = theme.popupInset(), .border = .{ .radius = 8 } };
}
pub fn scroll(partial: bool) ui.BoxStyle {
    return slot(64, if (partial) 132 else 180);
}
pub fn actions(partial: bool) ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .left = .{ .px = 12 }, .top = .{ .px = if (partial) 202 else 250 } }, .width = .{ .px = 456 }, .height = .{ .px = if (partial) 34 else 32 }, .direction = .row, .align_items = .center, .justify = .end, .gap = 6 };
}
pub fn button(partial: bool, primary: bool) ui.BoxStyle {
    return .{ .width = .{ .px = if (primary) (if (partial) @as(f32, 156) else 150) else (if (partial) @as(f32, 104) else 88) }, .height = .{ .px = if (partial and primary) 34 else 32 }, .translate_y = if (partial and !primary) 1 else 0, .padding = .{}, .flex_shrink = 0, .background = if (primary) (if (partial) theme.current().action_accent else danger()) else theme.popupAction(), .border = .{ .radius = 8 } };
}

pub fn scrollContent() ui.BoxStyle {
    return .{ .direction = .column, .width = .fill(), .gap = 0 };
}
pub fn notice() ui.BoxStyle {
    return .{ .width = .fill(), .flex_shrink = 0, .margin = .{ .bottom = 6 } };
}
pub fn danger() ui.Color {
    return theme.current().action_danger;
}
