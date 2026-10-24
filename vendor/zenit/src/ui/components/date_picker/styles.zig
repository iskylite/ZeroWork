//! DatePicker styling layer, trigger/panel/Today button style and interaction
//! color pure functions (zenit-styling-revamp). mount init and runtime update
//! (syncTriggerVisual/updateDisplayLabel) share same color source.
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const Padding = core.Padding;
const Shadow = core.Shadow;

// ========== Named style functions (styling layer) ==========
// Migrated from mount/syncTriggerVisual/updateDisplayLabel inline styles and
// color decisions; values kept as-is (zenit-styling-revamp).

pub const panel_radius: f32 = 14;

/// trigger border color switches three states with open / has_value (mount init +
/// syncTriggerVisual shared)
pub fn triggerBorderColor(open: bool, has_value: bool, t: *const theme.ThemeTokens) Color {
    return if (open) t.tokens.color.border_focus else if (has_value) t.tokens.color.border_strong else t.tokens.color.border;
}

pub fn displayTextColor(has_value: bool, t: *const theme.ThemeTokens) Color {
    return if (has_value) t.tokens.color.fg_primary else t.tokens.color.fg_tertiary;
}

pub fn leadingIconTint(has_value: bool, t: *const theme.ThemeTokens) Color {
    return if (has_value) t.tokens.color.fg_secondary else t.tokens.color.fg_tertiary;
}

pub fn chevronTint(open: bool, t: *const theme.ThemeTokens) Color {
    return if (open) t.tokens.color.accent else t.tokens.color.fg_tertiary;
}

pub fn panelStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = 300 },
        .height = .{ .fit = .{} },
        .direction = .column,
        .gap = 16,
        .padding = Padding.all(20),
        .background = t.tokens.color.bg_primary,
        .border = .{ .width = 1, .color = t.tokens.color.border, .radius = panel_radius },
        .shadow = Shadow{ .color = Color.rgba(0, 0, 0, 18), .blur = 24, .offset_x = 0, .offset_y = 8 },
    };
}

/// Today button: overlay on Button(.secondary) with light fill, no border, fills panel width.
/// Height / font size / radius from control metrics (no hardcoded 34 / 13 / 10).
pub fn todayBtnOverride(t: *const theme.ThemeTokens) core.StyleOverride {
    return .{
        .width = .{ .grow = .{} },
        .background = t.tokens.color.bg_hover,
        .border = .{ .width = 0, .color = t.tokens.color.border },
    };
}
