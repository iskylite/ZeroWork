//! NumberStepper style layer.
const core = @import("../../core.zig");

pub fn stepBtnStyle(t: *const core.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = 32 },
        .height = .{ .grow = .{} },
        .justify = .center,
        .align_items = .center,
        .background = t.tokens.color.bg_secondary,
    };
}

pub fn stepBtnLabelStyle(disabled: bool, t: *const core.ThemeTokens) core.TextStyle {
    return .{
        .color = if (disabled) t.tokens.color.fg_disabled else t.tokens.color.fg_primary,
        .font_size = 16,
        .font_weight = 600,
    };
}

pub fn stepperWrapperStyle(width: f32, t: *const core.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = width },
        .height = .{ .px = 32 },
        .direction = .row,
        .align_items = .center,
        .background = t.tokens.color.bg_primary,
        .border = .{ .width = 1, .color = t.tokens.color.input_border, .radius = 6 },
    };
}

pub fn stepperValueStyle(disabled: bool, t: *const core.ThemeTokens) core.TextStyle {
    return .{
        .color = if (disabled) t.tokens.color.fg_disabled else t.tokens.color.fg_primary,
        .font_size = 14,
    };
}
