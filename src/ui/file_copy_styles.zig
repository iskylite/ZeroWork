//! V3 transfer confirmation: 480x398, explicit title/body/footer hierarchy.
const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub fn root() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 398 }, .direction = .column, .gap = 0, .padding = .ZERO, .background = theme.current().overlay, .border = .{ .radius = 14 }, .flex_shrink = 0 };
}
pub fn row(height: f32, gap: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = height }, .direction = .row, .align_items = .center, .gap = gap, .min_width = 0, .flex_shrink = 0 };
}
pub fn text(size: f32, weight: u16, secondary: bool) ui.TextStyle {
    return .{ .font_size = size, .font_weight = weight, .line_height = 1.4, .color = if (secondary) theme.current().fg_2 else theme.current().fg_1, .text_overflow = .ellipsis };
}
pub fn header() ui.BoxStyle {
    var s = row(72, 12);
    s.padding = .{ .left = 20, .right = 16, .top = 16, .bottom = 12 };
    return s;
}
pub fn body() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 264 }, .direction = .column, .gap = 12, .padding = .{ .left = 20, .right = 20, .bottom = 16 }, .flex_shrink = 0 };
}
pub fn summary() ui.BoxStyle {
    var s = row(56, 10);
    s.padding = ui.Padding.all(12);
    s.background = theme.current().well;
    s.border = .{ .radius = 8 };
    return s;
}
pub fn field() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 52 }, .direction = .column, .gap = 4, .min_width = 0, .flex_shrink = 0 };
}
pub fn path() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 32 }, .padding = .{ .left = 10, .right = 10, .top = 8, .bottom = 8 }, .background = theme.current().well, .border = .{ .radius = 8 }, .min_width = 0, .flex_shrink = 0, .overflow = .hidden, .overflow_hidden = true };
}
pub fn footer() ui.BoxStyle {
    var s = row(62, 8);
    s.padding = .{ .left = 20, .right = 20, .top = 14, .bottom = 14 };
    return s;
}
pub fn button(primary: bool) ui.BoxStyle {
    return .{ .width = .{ .px = if (primary) 112 else 68 }, .height = .{ .px = 34 }, .padding = .ZERO, .background = if (primary) theme.current().action_accent else theme.current().surface_2, .border = .{ .radius = 8 }, .font_size = 12, .font_weight = 500, .flex_shrink = 0 };
}
