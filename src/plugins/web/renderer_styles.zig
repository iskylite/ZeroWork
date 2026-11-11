const ui = @import("ui");
const theme = @import("../../ui/app_theme.zig");

pub const tool_size: f32 = 28;
pub const bookmark_gap: f32 = 4;
pub const bookmark_min: f32 = 74;
pub const bookmark_max: f32 = 104;
pub const strip_max: f32 = 328;

pub fn toolbar() ui.BoxStyle {
    const colors = theme.current();
    return .{
        .width = .fill(),
        .height = .{ .px = 44 },
        .flex_shrink = 0,
        .direction = .row,
        .align_items = .center,
        .gap = 4,
        .padding = .{ .left = 8, .right = 8 },
        .background = colors.surface_1,
        .border = .{ .width = 1, .radius = 16, .color = colors.border },
    };
}

pub fn address(focused: bool) ui.BoxStyle {
    return .{
        .width = .fill(),
        .min_width = 132,
        .height = .{ .px = 32 },
        .direction = .row,
        .align_items = .center,
        .gap = 6,
        .padding = .{ .left = 9, .right = 3 },
        .background = theme.current().well,
        .border = .{ .radius = 9, .width = if (focused) 1.5 else 0, .color = theme.current().accent_ink },
    };
}

pub fn document() ui.BoxStyle {
    return .{
        .width = .fill(),
        .height = .fill(),
        .min_height = 0,
        .overflow = .hidden,
        .align_items = .center,
        .justify = .center,
        .background = theme.current().surface_2,
        .border = .{ .radius = 10 },
    };
}

pub fn tool() ui.BoxStyle {
    return .{
        .width = .{ .px = tool_size },
        .height = .{ .px = tool_size },
        .min_width = tool_size,
        .flex_shrink = 0,
        .padding = ui.Padding.ZERO,
        .border = .{ .radius = 14 },
    };
}

pub fn toolHover() ?ui.BoxStyle {
    return .{ .background = theme.current().hover };
}

pub fn bookmark(width: f32, selected: bool) ui.BoxStyle {
    const colors = theme.current();
    return .{
        .width = .{ .px = width },
        .height = .{ .px = tool_size },
        .flex_shrink = 0,
        .overflow = .hidden,
        .padding = .{ .left = 10, .right = 10 },
        .background = if (selected) colors.selection else colors.well,
        .border = .{ .radius = 7 },
    };
}

pub fn menuRow() ui.BoxStyle {
    return .{
        .width = .fill(),
        .height = .{ .px = 30 },
        .flex_shrink = 0,
        .overflow = .hidden,
        .justify = .start,
        .padding = .{ .left = 9, .right = 9 },
    };
}

pub fn popover() ui.BoxStyle {
    const colors = theme.current();
    return .{
        .background = colors.overlay.withAlpha(255),
        .border = .{ .width = 1, .radius = 10, .color = colors.border },
        .shadow = theme.floatingShadow(),
    };
}
