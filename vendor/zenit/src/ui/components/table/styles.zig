//! Table style layer, all visual decisions here, mod.zig's mount/render only consume.
//! Direct render and virtual scroll paths share same style functions.
const core = @import("../../core.zig");
const Color = core.Color;
const Padding = core.Padding;
const mod = @import("mod.zig");
const ColumnAlign = mod.ColumnAlign;
const ColumnDef = mod.ColumnDef;

pub fn colJustify(a: ColumnAlign) core.JustifyContent {
    return switch (a) {
        .left => .start,
        .center => .center,
        .right => .end,
    };
}

pub fn tableBorderWrapStyle(w: f32, h: f32, t: *const core.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = w },
        .height = .{ .px = h },
        .direction = .column,
        .background = t.tokens.color.bg_primary,
        .border = .{ .width = 1, .color = t.tokens.color.border, .radius = t.tokens.radius.sm },
        .padding = Padding.all(1),
    };
}

pub fn tableInnerStyle(t: *const core.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
        .direction = .column,
        .background = t.tokens.color.bg_primary,
        .overflow_hidden = true,
    };
}

pub fn tableHeaderRowStyle(header_height: f32, t: *const core.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .px = header_height },
        .direction = .row,
        .align_items = .center,
        .background = t.tokens.color.bg_secondary,
        .border = .{ .width = 1, .color = t.tokens.color.separator },
    };
}

pub fn tableHeaderCellStyle(col: ColumnDef) core.BoxStyle {
    return .{
        .width = .{ .px = col.width },
        .height = .{ .grow = .{} },
        .direction = .row,
        .align_items = .center,
        .justify = colJustify(col.col_align),
        .padding = Padding.symmetric(0, 12),
    };
}

pub fn tableHeaderTextStyle(t: *const core.ThemeTokens) core.TextStyle {
    return .{
        .color = t.tokens.color.fg_secondary,
        .font_size = t.tokens.font_size.xs,
        .font_weight = 600,
    };
}

pub fn sortIndicatorBoxStyle() core.BoxStyle {
    return .{
        .width = .{ .fit = .{} },
        .height = .{ .fit = .{} },
        .padding = Padding.symmetric(0, 4),
    };
}

pub fn sortIndicatorText(t: *const core.ThemeTokens) core.TextStyle {
    return .{
        .color = t.tokens.color.fg_disabled,
        .font_size = 8,
    };
}

/// Row default background (striped uses bg_secondary for odd rows)
pub fn tableRowBg(striped: bool, is_even: bool, t: *const core.ThemeTokens) Color {
    return if (striped and !is_even) t.tokens.color.bg_secondary else Color.TRANSPARENT;
}

pub fn tableRowStyle(row_bg: Color, row_height: f32) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .px = row_height },
        .direction = .row,
        .align_items = .center,
        .background = row_bg,
    };
}

pub fn tableCellStyle(col: ColumnDef) core.BoxStyle {
    return .{
        .width = .{ .px = col.width },
        .height = .{ .grow = .{} },
        .direction = .row,
        .align_items = .center,
        .justify = colJustify(col.col_align),
        .padding = Padding.symmetric(0, 12),
    };
}

pub fn tableSeparatorStyle(separator_color: Color) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 1 },
        .background = separator_color,
    };
}
