/// ComboBox, styling layer. Named style functions and shared geometry
/// constants; logic / State / portal mounted in mod.zig.
const core = @import("../../core.zig");
const theme = core.theme;

/// Pvnqs / Select option: 14px text + 8px top/bottom padding. Panel scroll
/// geometry (ComboBoxState.item_h) shared with row style.
pub const combo_item_height: f32 = 36;

/// Pvnqs / Select panel chrome.
pub fn comboPanelRadius(t: *const theme.ThemeTokens) f32 {
    return t.tokens.radius.xl;
}

pub fn comboPanelStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    const radius = comboPanelRadius(t);
    return .{
        .direction = .column,
        .gap = 2,
        .padding = core.Padding.all(4),
        .background = t.tokens.color.bg_primary,
        .border = .{ .width = 1, .color = t.tokens.color.border, .radius = radius },
        .corner_radius = radius,
        .shadow = .{
            .color = core.Color.rgba(0, 0, 0, 18),
            .blur = 12,
            .offset_x = 0,
            .offset_y = 4,
        },
    };
}

pub fn comboItemStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .direction = .row,
        .width = .{ .grow = .{} },
        .height = .{ .px = combo_item_height },
        .padding = core.Padding.symmetric(8, 12),
        .justify = .space_between,
        .align_items = .center,
        .overflow_hidden = true,
        .corner_radius = t.tokens.radius.lg,
    };
}

/// Empty row: same geometry as option row but initially collapsed (height 0)
pub fn comboEmptyStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    var s = comboItemStyle(t);
    s.justify = .center;
    s.display = .none; // Default collapsed; applyFilter toggles by match count
    return s;
}

pub fn comboItemTextStyle(disabled: bool, t: *const theme.ThemeTokens) core.TextStyle {
    return .{
        .color = if (disabled) t.tokens.color.fg_disabled else t.tokens.color.fg_primary,
        .font_size = 14,
    };
}

pub fn comboEmptyTextStyle(t: *const theme.ThemeTokens) core.TextStyle {
    return .{
        .color = t.tokens.color.fg_tertiary,
        .font_size = 14,
    };
}

/// Keyboard/hover highlight row bg, driven by highlight logic at runtime
pub fn comboHighlightBg(t: *const theme.ThemeTokens) core.Color {
    return t.tokens.color.list_hover_bg;
}
