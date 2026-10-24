const ui = @import("ui");
const theme = @import("app_theme.zig");

// Bridge readback: 444:181167 (starting), 444:187017/444:187772
// (ended/failed). Pane-relative geometry, unchanged at compact window sizes.
pub fn pane() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .direction = .column, .gap = 0, .background = theme.current().terminal, .border = .{ .radius = 11 } };
}
pub fn banner(starting: bool) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = if (starting) 34 else 38 }, .direction = .row, .align_items = .center, .gap = 6, .padding = .{ .left = if (starting) 8 else 12, .right = if (starting) 8 else 12 }, .position = if (starting) .absolute else .relative, .inset = if (starting) .{ .left = .{ .px = 16 }, .right = .{ .px = 16 }, .top = .{ .px = 16 } } else .{}, .z_index = if (starting) 1 else 0, .background = theme.current().surface_2, .border = .{ .radius = if (starting) 8 else 9 }, .flex_shrink = 0 };
}
pub fn icon() ui.Style {
    return .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .flex_shrink = 0 };
}
pub fn title() ui.TextStyle {
    return .{ .font_size = 12, .font_weight = 500, .color = theme.current().fg_1, .line_height = 1.5, .text_overflow = .ellipsis };
}
pub fn detail() ui.TextStyle {
    return .{ .font_size = 11, .color = theme.current().fg_2, .line_height = 16.0 / 11.0, .text_overflow = .ellipsis };
}
pub fn action() ui.BoxStyle {
    return .{ .width = .{ .px = 130 }, .height = .{ .px = 28 }, .padding = .{}, .background = theme.current().surface_2, .border = .{ .radius = 8 }, .flex_shrink = 0 };
}
pub fn cancel() ui.BoxStyle {
    return .{ .width = .{ .px = 26 }, .height = .{ .px = 26 }, .padding = .{}, .background = ui.Color.TRANSPARENT, .border = .{ .radius = 7 }, .flex_shrink = 0 };
}
