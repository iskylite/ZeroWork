//! Bridge 342:1075461/1075906/1076348 and 342:1182436/1185191.
const ui = @import("ui");
const theme = @import("app_theme.zig");
pub fn dialog(has_receipt: bool) ui.BoxStyle {
    return .{ .width = .{ .px = 440 }, .height = .{ .px = if (has_receipt) 172 else 146 }, .padding = .ZERO, .background = theme.current().overlay, .border = .{ .width = 0, .radius = 14 }, .shadow = .{ .offset_y = 24, .blur = 32, .color = theme.current().shadow } };
}
pub fn body() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .direction = .column, .padding = .{ .left = 12, .right = 12, .top = 12, .bottom = 12 }, .gap = 8 };
}
pub fn row(height: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = height }, .flex_shrink = 0, .direction = .row, .align_items = .center, .gap = 6 };
}
pub fn stack(has_receipt: bool) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = if (has_receipt) 70 else 44 }, .flex_shrink = 0, .direction = .column, .gap = 4 };
}
pub fn close() ui.BoxStyle {
    return .{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .padding = .ZERO, .background = theme.current().surface_2, .border = .{ .width = 0, .radius = 7 }, .flex_shrink = 0 };
}
pub fn button(primary: bool, destructive: bool) ui.BoxStyle {
    const c = theme.current();
    return .{ .width = .{ .px = 96 }, .height = .{ .px = 34 }, .padding = .ZERO, .background = if (destructive) danger() else if (primary) c.action_accent else c.surface_2, .border = .{ .width = 0, .radius = 8 }, .flex_shrink = 0 };
}
pub fn danger() ui.Color {
    return theme.current().action_danger;
}
pub fn warning() ui.Color {
    const base = theme.baseColors();
    if (!ui.Color.eql(base.danger_ink, theme.colors(theme.currentName()).danger_ink)) return base.danger_ink;
    return if (theme.currentName() == .dark) ui.Color.rgb(0xff, 0x85, 0x85) else ui.Color.rgb(0xa7, 0x2c, 0x2c);
}
pub fn text(size: f32, height: f32, weight: u16) ui.TextStyle {
    return .{ .font_size = size, .line_height = height / size, .font_weight = weight, .color = theme.current().fg_1, .wrap = .word, .selectable = false };
}
pub fn textBox(height: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = height }, .flex_shrink = 0, .overflow = .hidden };
}
