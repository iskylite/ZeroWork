//! DateRangePicker styling layer (zenit-styling-revamp): trigger/panel/month panel/
//! date cell style functions + interaction color pure functions + day cell state color
//! matrix (DayCellVisual / computeDayCellVisual). Depends on mod.zig's State and date
//! comparison logic (circular import, Zig lazy analysis allows).
const control_shell = @import("../control_shell/mod.zig");
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const Padding = core.Padding;
const Shadow = core.Shadow;
const mod = @import("mod.zig");
const DateRangePickerState = mod.DateRangePickerState;
const SimpleDate = @import("../calendar/mod.zig").SimpleDate;

// ========== Named style functions (styling layer) ==========
// Inline styles and color decisions from mount/mountMonthSection/buildMonthGrid/
// updateDisplayLabel/syncTriggerVisual (zenit-styling-revamp).
// Day cell state color matrix lives in computeDayCellVisual (pure function, styling layer).

pub const nav_icon_size: f32 = 16;
pub const panel_radius: f32 = 14;
pub const day_cell_size: f32 = 32;
pub const day_font_size: f32 = 13;

pub fn triggerBorderColor(open: bool, has_value: bool, t: *const theme.ThemeTokens) Color {
    return if (open) t.tokens.color.border_focus else if (has_value) t.tokens.color.border_strong else t.tokens.color.border;
}

pub fn leadingIconTint(has_value: bool, t: *const theme.ThemeTokens) Color {
    return if (has_value) t.tokens.color.fg_secondary else t.tokens.color.fg_tertiary;
}

pub fn chevronTint(open: bool, t: *const theme.ThemeTokens) Color {
    return if (open) t.tokens.color.accent else t.tokens.color.fg_tertiary;
}

pub fn valueTextColor(has_value: bool, t: *const theme.ThemeTokens) Color {
    return if (has_value) t.tokens.color.fg_primary else t.tokens.color.fg_tertiary;
}

pub fn dashColor(has_any_value: bool, t: *const theme.ThemeTokens) Color {
    return if (has_any_value) t.tokens.color.fg_secondary else t.tokens.color.fg_tertiary;
}

pub fn rangeTextStyle(t: *const theme.ThemeTokens, cm: control_shell.ControlMetrics) core.TextStyle {
    return .{ .color = t.tokens.color.fg_tertiary, .font_size = cm.font_size, .line_height = cm.line_height };
}

pub fn panelStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .fit = .{} },
        .height = .{ .fit = .{} },
        .direction = .row,
        .background = t.tokens.color.bg_primary,
        .border = .{ .width = 1, .color = t.tokens.color.border, .radius = panel_radius },
        .shadow = Shadow{ .color = Color.rgba(0, 0, 0, 18), .blur = 24, .offset_x = 0, .offset_y = 8 },
    };
}

pub fn panelDividerStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = 1 },
        .height = .{ .grow = .{} },
        .background = t.tokens.color.border,
    };
}

pub fn monthSectionStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = 300 },
        .height = .{ .fit = .{} },
        .direction = .column,
        .gap = 16,
        .padding = Padding.all(20),
    };
}

pub fn monthHeaderStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 32 },
        .direction = .row,
        .align_items = .center,
        .justify = .space_between,
    };
}

pub fn monthTitleTextStyle(t: *const theme.ThemeTokens) core.TextStyle {
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

pub fn monthGridStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .fit = .{} },
        .height = .{ .fit = .{} },
        .direction = .column,
        .gap = 4,
    };
}

pub fn weekRowStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .fit = .{} },
        .height = .{ .px = day_cell_size },
        .direction = .row,
        .gap = 0,
    };
}

pub fn dayPlaceholderStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = day_cell_size },
        .height = .{ .px = day_cell_size },
    };
}

/// day cell box style = computeDayCellVisual's geometry/color mapping to BoxStyle
pub fn dayCellBoxStyle(visual: DayCellVisual) core.BoxStyle {
    return .{
        .width = .{ .px = day_cell_size },
        .height = .{ .px = day_cell_size },
        .justify = .center,
        .align_items = .center,
        .background = visual.bg_color,
        .border = .{ .width = visual.border_width, .color = visual.border_color, .radius = visual.corner_radius.resolve() },
    };
}

pub fn iconBtnStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = 32 },
        .height = .{ .px = 32 },
        .direction = .row,
        .justify = .center,
        .align_items = .center,
        .background = t.tokens.color.bg_hover,
        .border = .{ .width = 0, .color = t.tokens.color.border, .radius = 8 },
    };
}

/// Month nav button hover animation color source (useAnimatedBackground)
pub fn iconBtnAnimColors(t: *const theme.ThemeTokens) struct { normal: Color, hover: Color } {
    return .{ .normal = t.tokens.color.bg_hover, .hover = t.tokens.color.bg_active };
}

pub const DayCellVisual = struct {
    bg_color: Color,
    text_color: Color,
    border_width: f32,
    border_color: Color,
    corner_radius: core.CornerRadius,
    font_weight: u16,
    hover_enabled: bool,
};

pub fn computeDayCellVisual(state: *const DateRangePickerState, date: SimpleDate, in_current_month: bool) DayCellVisual {
    const t = state.cx.tokens;
    const resolved_end = mod.effectiveRangeEnd(state.start_date, state.end_date, state.preview_end_date);
    const is_start = if (state.start_date) |d| d.eql(date) else false;
    const is_end = if (resolved_end) |d| d.eql(date) else false;
    const is_today = if (state.today_date) |d| d.eql(date) else false;
    const in_range = mod.isDateInRange(date, state.start_date, resolved_end);

    return .{
        .bg_color = if (is_start or is_end)
            t.tokens.color.accent
        else if (in_range)
            t.tokens.color.accent_subtle
        else
            Color.TRANSPARENT,
        .text_color = if (is_start or is_end)
            t.tokens.color.fg_inverse
        else if (in_range)
            t.tokens.color.accent
        else if (in_current_month)
            t.tokens.color.fg_primary
        else
            t.tokens.color.fg_tertiary,
        .border_width = if (is_today and !(is_start or is_end)) 1 else 0,
        .border_color = t.tokens.color.accent,
        .corner_radius = if (is_start and is_end)
            core.CornerRadius.uniform(10)
        else if (is_start)
            core.CornerRadius{ .each = .{ 10, 0, 0, 10 } }
        else if (is_end)
            core.CornerRadius{ .each = .{ 0, 10, 10, 0 } }
        else if (in_range)
            core.CornerRadius.uniform(0)
        else
            core.CornerRadius.uniform(10),
        .font_weight = if (is_start or is_end or is_today) 600 else 400,
        .hover_enabled = !(is_start or is_end or in_range),
    };
}
