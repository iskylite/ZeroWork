//! DataTable style layer, all visual decisions here, mod.zig's mount only consumes.
const core = @import("../../core.zig");
const Padding = core.Padding;

pub fn dataTableRootStyle(w: f32) core.BoxStyle {
    return .{
        .width = .{ .px = w },
        .height = .{ .fit = .{} },
        .direction = .column,
        .gap = 8,
    };
}

pub fn dataTableBorderWrapStyle(w: f32, t: *const core.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = w },
        .height = .{ .fit = .{} },
        .direction = .column,
        .background = t.tokens.color.bg_primary,
        .border = .{ .width = 1, .color = t.tokens.color.border, .radius = t.tokens.radius.sm },
        .padding = Padding.all(1),
    };
}

pub fn dataTableHeaderStyle(header_height: f32, t: *const core.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .px = header_height },
        .direction = .row,
        .align_items = .center,
        .background = t.tokens.color.bg_secondary,
    };
}

pub fn dataTableHeaderCellStyle(w: f32) core.BoxStyle {
    return .{
        .width = .{ .px = w },
        .height = .{ .grow = .{} },
        .direction = .row,
        .align_items = .center,
        .padding = Padding.symmetric(0, 12),
    };
}

pub fn dataTableHeaderTextStyle(t: *const core.ThemeTokens) core.TextStyle {
    return .{
        .color = t.tokens.color.fg_secondary,
        .font_size = 13,
        .font_weight = 600,
    };
}

pub fn resizeHandleStyle() core.BoxStyle {
    return .{
        .width = .{ .px = 6 },
        .height = .{ .grow = .{} },
        .cursor = .ew_resize,
    };
}

/// Row background triple (selected / even / odd), striped determines if odd uses bg_secondary
pub const RowColors = struct { selection: core.Color, even: core.Color, odd: core.Color };

pub fn dataTableRowColors(striped: bool, t: *const core.ThemeTokens) RowColors {
    return .{
        .selection = t.tokens.color.list_selection_bg,
        .even = t.tokens.color.bg_primary,
        .odd = if (striped) t.tokens.color.bg_secondary else t.tokens.color.bg_primary,
    };
}

pub fn dataTableRowStyle(bg: core.Color, row_height: f32) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .px = row_height },
        .direction = .row,
        .align_items = .center,
        .background = bg,
    };
}

pub fn dataTableCellStyle(w: f32) core.BoxStyle {
    return .{
        .width = .{ .px = w },
        .height = .{ .grow = .{} },
        .direction = .row,
        .align_items = .center,
        .padding = Padding.symmetric(0, 12),
        .overflow_hidden = true,
    };
}

pub fn dataTableCellTextStyle(t: *const core.ThemeTokens) core.TextStyle {
    return .{
        .color = t.tokens.color.fg_primary,
        .font_size = 13,
    };
}

pub fn dataTablePagerStyle() core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .row,
        .align_items = .center,
        .gap = 8,
    };
}

pub fn dataTablePageLabelText(t: *const core.ThemeTokens) core.TextStyle {
    return .{
        .color = t.tokens.color.fg_secondary,
        .font_size = 13,
    };
}
