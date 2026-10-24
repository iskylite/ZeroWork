//! FileUpload style layer, wrapper / drop zone / file row / remove button styles and drop hover
//! coloring (zenit-styling-revamp).
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const Padding = core.Padding;

// ========== Named style functions (style layer) ==========
// Migrated from mountFileUpload / addFile / setDropHover inline styles and color decisions;
// numeric values preserved as-is (zenit-styling-revamp).

pub fn wrapperStyle(w: f32) core.BoxStyle {
    return .{
        .width = .{ .px = w },
        .height = .{ .fit = .{} },
        .direction = .column,
        .gap = 8,
    };
}

pub fn dropZoneStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    const colors = dropZoneColors(false, t);
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 72 },
        .direction = .column,
        .justify = .center,
        .align_items = .center,
        .gap = 6,
        .background = colors.bg,
        .border = .{ .width = 1, .color = colors.border, .radius = 8 },
    };
}

/// drop hover highlight two-state coloring (consumed by setDropHover)
pub fn dropZoneColors(hover_active: bool, t: *const theme.ThemeTokens) struct { bg: Color, border: Color } {
    return if (hover_active)
        .{ .bg = t.tokens.color.bg_hover, .border = t.tokens.color.accent }
    else
        .{ .bg = t.tokens.color.bg_secondary, .border = t.tokens.color.border };
}

pub fn hintTextStyle(t: *const theme.ThemeTokens) core.TextStyle {
    return .{ .color = t.tokens.color.fg_secondary, .font_size = 13 };
}

pub fn listStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .column,
        .gap = 4,
    };
}

pub fn fileRowStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .padding = Padding.symmetric(0, 8),
        .background = t.tokens.color.bg_secondary,
        .border = .{ .radius = 4 },
    };
}

pub fn fileNameTextStyle(t: *const theme.ThemeTokens) core.TextStyle {
    return .{ .color = t.tokens.color.fg_primary, .font_size = 13 };
}

pub fn removeBtnStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = 18 },
        .height = .{ .px = 18 },
        .justify = .center,
        .align_items = .center,
    };
}

pub fn removeGlyphTextStyle(t: *const theme.ThemeTokens) core.TextStyle {
    return .{ .color = t.tokens.color.fg_secondary, .font_size = 12 };
}
