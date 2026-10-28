const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub const width: f32 = 240;
// HTML inset5 plus its 1px transparent border = 6 logical pixels.
pub fn panel() ui.BoxStyle {
    return .{ .width = .{ .px = width }, .height = .{ .fit = .{} }, .direction = .column, .gap = 0, .padding = ui.Padding.all(6), .background = theme.current().overlay, .glass = theme.overlayGlass(), .border = .{ .width = 0, .color = ui.Color.TRANSPARENT, .radius = 11 }, .shadow = .{ .blur = 24, .offset_y = 8, .color = theme.current().shadow } };
}
pub fn row() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 33 }, .padding = .{ .left = 10, .right = 10 }, .direction = .row, .align_items = .center, .justify = .start, .gap = 9, .font_size = 11, .font_weight = 400, .background = ui.Color.TRANSPARENT, .border = .{ .width = 0, .radius = 7 }, .flex_shrink = 0 };
}
pub fn highlight() ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .left = .{ .px = 0 }, .right = .{ .px = 0 }, .top = .{ .px = 0 }, .bottom = .{ .px = 0 } }, .width = .fill(), .height = .fill(), .background = theme.popupSelection(), .border = .{ .radius = 7 }, .hit_behavior = .pass_through };
}
pub fn rowContent() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .direction = .row, .align_items = .center, .gap = 9, .min_width = 0 };
}
pub fn label() ui.TextStyle {
    return .{ .font_size = 11, .font_weight = 400, .line_height = 15.0 / 11.0, .color = theme.current().fg_1, .selectable = false };
}
pub fn separator() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 26 }, .padding = .{ .left = 10, .right = 4, .top = 7, .bottom = 3 }, .flex_shrink = 0 };
}
