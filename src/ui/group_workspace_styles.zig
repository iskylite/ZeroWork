const ui = @import("ui");
const theme = @import("app_theme.zig");
pub const gap: f32 = 4;
pub const header_status_text_min_width: f32 = 180;
pub fn root(vertical: bool) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .direction = if (vertical) .column else .row, .gap = gap, .flex_shrink = 0 };
}
pub fn pane() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .direction = .column, .background = theme.current().terminal, .border = .{ .radius = 11 }, .overflow_hidden = true };
}
pub fn header() ui.BoxStyle {
    return .{
        .width = .fill(),
        .height = .{ .px = 28 },
        .flex_shrink = 0,
        .direction = .row,
        .align_items = .center,
        .gap = 4,
        .padding = .{ .left = 6, .right = 6, .top = 2, .bottom = 2 },
        .background = theme.current().surface_1,
    };
}
pub fn control() ui.BoxStyle {
    return .{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .flex_shrink = 0, .border = .{ .radius = 7 } };
}
pub fn label() ui.TextStyle {
    return .{ .font_size = 12, .color = theme.current().fg_2, .selectable = false, .text_overflow = .ellipsis };
}
pub fn tab(active: bool) ui.BoxStyle {
    return .{ .width = .{ .px = 148 }, .height = .{ .px = 32 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .gap = 6, .padding = .{ .left = 10, .right = 4 }, .background = if (active) theme.current().surface_2 else theme.current().surface_1, .border = .{ .radius = 8 } };
}

// The existing 4pt gutter becomes an interactive native separator.
pub fn separator(vertical: bool) ui.BoxStyle {
    return .{ .width = if (vertical) .fill() else .{ .px = gap }, .height = if (vertical) .{ .px = gap } else .fill(), .flex_shrink = 0, .cursor = if (vertical) .ns_resize else .ew_resize, .hit_behavior = .@"opaque" };
}
