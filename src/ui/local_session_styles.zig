const ui = @import("ui");
const theme = @import("app_theme.zig");

// Editable baseline: docs/UI_V3/workspace/session-notice/index.html.
pub fn pane() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .direction = .column, .gap = 0, .background = theme.current().terminal, .border = .{ .radius = 11 } };
}
pub fn banner(starting: bool) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 64 }, .direction = .row, .align_items = .center, .gap = 12, .padding = .{ .left = 16, .right = 16 }, .position = if (starting) .absolute else .relative, .inset = if (starting) .{ .left = .{ .px = 16 }, .right = .{ .px = 16 }, .top = .{ .px = 16 } } else .{}, .z_index = if (starting) 1 else 0, .background = theme.current().surface_2, .border = .{ .radius = 9 }, .flex_shrink = 0 };
}
pub fn icon() ui.Style {
    return .{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .flex_shrink = 0 };
}
pub fn title() ui.TextStyle {
    return .{ .font_size = 13, .font_weight = 600, .color = theme.current().fg_1, .line_height = 20.0 / 13.0, .text_overflow = .ellipsis };
}
pub fn detail() ui.TextStyle {
    return .{ .font_size = 12, .color = theme.current().fg_2, .line_height = 18.0 / 12.0, .text_overflow = .ellipsis };
}
pub fn copy() ui.BoxStyle {
    return .{ .width = .fill(), .min_width = 0, .flex = 1, .direction = .column, .gap = 2 };
}
pub fn action() ui.BoxStyle {
    return .{ .height = .{ .px = 30 }, .padding = .{ .left = 12, .right = 12 }, .border = .{ .radius = 7 }, .flex_shrink = 0 };
}
pub fn cancel() ui.BoxStyle {
    return action();
}
