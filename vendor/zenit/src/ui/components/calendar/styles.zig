//! Calendar styling layer, named style functions and constants (zenit-styling-revamp).
//! Migrated from mount/buildGrid inline styles; values kept as-is. mod.zig only
//! consumes function returns, makes no inline style or color decisions.
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const Padding = core.Padding;

pub const nav_icon_size: f32 = 16;

pub fn containerStyle(panel_width: f32, t: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = panel_width },
        .height = .{ .fit = .{} },
        .direction = .column,
        // White-background panel (same surface as Card / Popover), date cells distinguished by
        // hover / today / selected.
        .background = t.tokens.color.bg_primary,
        .border = .{ .width = 1, .color = t.tokens.color.border, .radius = 14 },
        .padding = Padding.all(20),
        .gap = 16,
    };
}

pub fn headerStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 32 },
        .direction = .row,
        .align_items = .center,
        .justify = .space_between,
    };
}

pub fn monthLabelTextStyle(t: *const theme.ThemeTokens) core.TextStyle {
    return .{ .color = t.tokens.color.fg_primary, .font_size = 14, .font_weight = 600 };
}

pub fn weekdayCellStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = 34 },
        .height = .{ .px = 28 },
        .justify = .center,
        .align_items = .center,
    };
}

pub fn weekdayTextStyle(t: *const theme.ThemeTokens) core.TextStyle {
    return .{ .color = t.tokens.color.fg_tertiary, .font_size = 11, .font_weight = 600 };
}

pub fn gridStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .column,
        .gap = 4,
    };
}

pub fn weekRowStyle(cell_size: f32) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .px = cell_size },
        .direction = .row,
        .justify = .space_between,
    };
}

/// date cell state flags -> visual decision input for dayCellStyle/dayTextStyle
pub const DayCellFlags = struct {
    selected: bool,
    today: bool,
    keyboard_focus: bool,
    current_month: bool,
};

pub fn dayCellStyle(f: DayCellFlags, cell_size: f32, t: *const theme.ThemeTokens) core.BoxStyle {
    // Panel is white: non-selected cells match panel, adjacent-month dates distinguished
    // by fg_tertiary text only.
    const bg: Color = if (f.selected) t.tokens.color.accent else t.tokens.color.bg_primary;
    // keyboard focus priority > today border > normal; selected already strong visual, no
    // ring
    const border_width: f32 = if (f.keyboard_focus and !f.selected)
        2
    else if (f.today and !f.selected)
        1
    else
        0;
    const border_color: Color = if (f.keyboard_focus and !f.selected)
        t.tokens.color.accent
    else if (f.today and !f.selected)
        t.tokens.color.border_strong
    else
        t.tokens.color.border;
    return .{
        .width = .{ .px = cell_size },
        .height = .{ .px = cell_size },
        .justify = .center,
        .align_items = .center,
        .background = bg,
        .border = .{ .width = border_width, .color = border_color, .radius = 10 },
    };
}

pub fn dayTextStyle(f: DayCellFlags, t: *const theme.ThemeTokens) core.TextStyle {
    return .{
        .color = if (f.selected)
            t.tokens.color.fg_inverse
        else if (f.current_month)
            t.tokens.color.fg_primary
        else
            t.tokens.color.fg_tertiary,
        .font_size = 13,
        .font_weight = if (f.selected) 600 else 400,
    };
}

pub fn dayHoverBg(current_month: bool, t: *const theme.ThemeTokens) Color {
    return if (current_month) t.tokens.color.bg_hover else Color.lerp(t.tokens.color.bg_primary, t.tokens.color.bg_hover, 0.55);
}
