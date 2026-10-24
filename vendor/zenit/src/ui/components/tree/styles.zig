/// Tree, style layer
///
/// Named style functions; business logic / State / event handling in mod.zig.
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const Padding = core.Padding;

pub fn treeContainerStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .column,
    };
}

pub fn treeRowStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .padding = Padding.symmetric(0, 4),
        .background = Color.TRANSPARENT,
    };
}

/// Selected row background, driven at runtime by applySelectionStyles
pub fn treeSelectionBg(t: *const theme.ThemeTokens) Color {
    return t.tokens.color.list_selection_bg;
}

pub fn treeIndicatorBoxStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = 16 },
        .height = .{ .px = 16 },
        .justify = .center,
        .align_items = .center,
    };
}

pub fn treeExpandIconStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = 10 },
        .height = .{ .px = 10 },
    };
}

pub fn treeIndicatorTextStyle(t: *const theme.ThemeTokens) core.TextStyle {
    return .{
        .color = t.tokens.color.fg_secondary,
        .font_size = 8,
    };
}

pub fn treeLabelBoxStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .padding = Padding.symmetric(0, 4),
    };
}

pub fn treeLabelTextStyle(disabled: bool, t: *const theme.ThemeTokens) core.TextStyle {
    return .{
        .color = if (disabled) t.tokens.color.fg_disabled else t.tokens.color.fg_primary,
        .font_size = t.tokens.font_size.sm,
    };
}
