const ui = @import("ui");
const T = @import("app_theme.zig");
pub fn listSurface() ui.BoxStyle {
    return .{
        .width = .fill(),
        .height = .{ .px = 0 },
        .max_height = 160,
        .flex_shrink = 0,
        .display = .flex,
        .background = ui.Color.TRANSPARENT,
        .corner_radius = 10,
    };
}
pub fn menu() ui.BoxStyle {
    return .{ .width = .fill(), .direction = .column, .padding = ui.Padding.all(6), .gap = 2 };
}
pub fn heading() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 24 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .gap = 8, .padding = .{ .left = 8, .right = 8 } };
}
pub fn rowBackground(active: bool, hovered: bool) ui.BoxStyle {
    return .{ .background = if (hovered) T.current().hover else if (active) T.current().accent.withAlpha(24) else ui.Color.TRANSPARENT, .corner_radius = 7 };
}
pub fn actionHover(danger: bool) ui.BoxStyle {
    return .{ .background = if (danger) T.current().danger.withAlpha(20) else T.current().hover, .corner_radius = 5 };
}
pub fn row() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 30 }, .direction = .row, .align_items = .center, .gap = 6, .padding = .{ .left = 8, .right = 8 }, .flex_shrink = 0 };
}
pub fn text(primary: bool) ui.TextStyle {
    return .{ .font_size = if (primary) 11.5 else 10.5, .font_weight = if (primary) 500 else 400, .line_height = if (primary) 16.0 / 11.5 else 14.0 / 10.5, .color = if (primary) T.current().fg_1 else T.current().fg_2, .text_overflow = .ellipsis };
}
pub fn dialogDetail() ui.TextStyle {
    var result = text(false);
    result.font_size = 11;
    result.font_weight = 400;
    result.line_height = 16.0 / 11.0;
    result.wrap = .word;
    return result;
}
pub fn dialog() ui.BoxStyle {
    return .{ .width = .{ .px = 320 }, .height = .{ .px = 148 }, .background = T.current().overlay, .border = .{ .radius = 12 } };
}
pub fn body() ui.BoxStyle {
    return .{ .width = .fill(), .direction = .column, .padding = .{ .top = 16, .bottom = 16, .left = 16, .right = 16 }, .gap = 12 };
}
pub fn actions() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 28 }, .direction = .row, .justify = .end, .gap = 8 };
}
pub fn control(danger: bool) ui.BoxStyle {
    return .{ .width = .{ .px = if (danger) 96 else 60 }, .height = .{ .px = 28 }, .padding = .{}, .font_size = 11.5, .font_weight = 500, .background = if (danger) dangerBackground() else T.current().surface_2, .text_color = if (danger) T.actionForeground(T.current().action_danger) else T.current().fg_1, .corner_radius = 8, .border = .{ .width = 0, .radius = 8 }, .flex_shrink = 0 };
}

fn dangerBackground() ui.Color {
    return T.current().action_danger;
}

pub fn popover() ui.BoxStyle {
    return .{ .width = .{ .px = 440 }, .direction = .column, .padding = .{}, .background = T.current().overlay, .border = .{ .width = 0, .radius = 11 }, .shadow = .{ .color = T.current().shadow, .blur = 24, .offset_y = 12 } };
}
