const ui = @import("ui");
const theme = @import("app_theme.zig");
pub const width: f32 = 360;
pub const collapsed_height: f32 = 58;
pub fn panel() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .padding = ui.Padding.all(1), .gap = 0, .background = theme.current().overlay, .border = .{ .width = 1, .color = theme.current().border, .radius = 10 }, .shadow = .{ .offset_y = 16, .blur = 40, .color = theme.current().shadow }, .hit_behavior = .@"opaque", .overflow = .hidden };
}
pub fn row() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 2, .padding = .{ .top = 8, .bottom = 8, .left = 12, .right = 12 }, .flex_shrink = 0 };
}
pub fn heading() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 40 }, .padding = .{ .left = 12, .right = 12 }, .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0 };
}
pub fn text(secondary: bool) ui.TextStyle {
    return .{ .font_size = if (secondary) 11 else 12, .font_weight = if (secondary) 400 else 500, .line_height = if (secondary) 18.0 / 11.0 else 1.5, .color = if (secondary) theme.current().fg_2 else theme.current().fg_1, .wrap = .none, .text_overflow = .ellipsis, .selectable = false };
}
pub fn line() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 18 }, .min_width = 0, .flex = 1 };
}
pub fn action() ui.BoxStyle {
    return .{ .height = .{ .px = 22 }, .padding = .{ .left = 6, .right = 6 }, .font_size = 11, .font_weight = 400, .text_color = theme.current().accent_ink, .background = ui.Color.TRANSPARENT, .border = .{ .radius = 5 }, .flex_shrink = 0 };
}
pub fn expand() ui.BoxStyle {
    return .{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .padding = .ZERO, .border = .{ .radius = 5 }, .flex_shrink = 0 };
}
pub fn column() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 0, .flex_shrink = 0 };
}
pub fn policy() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 30 }, .padding = .{ .top = 6, .bottom = 8, .left = 12, .right = 12 }, .flex_shrink = 0 };
}
