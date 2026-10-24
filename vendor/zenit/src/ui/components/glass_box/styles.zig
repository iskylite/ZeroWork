//! GlassBox style layer, header text style.
//! Glass material itself (surface border/tint/blur Resolved* interpolation chain) is runtime
//! rendering logic, stays in mod.zig (changes must eyeball screenshots, see memory).
const core = @import("../../core.zig");
const theme = core.theme;

pub fn glassTitleStyle(t: *const theme.ThemeTokens) core.TextStyle {
    return .{
        .color = t.tokens.color.fg_primary,
        .font_size = 15,
        .font_weight = 650,
    };
}

pub fn glassSubtitleStyle(t: *const theme.ThemeTokens) core.TextStyle {
    return .{
        .color = t.tokens.color.fg_secondary,
        .font_size = 12,
        .font_weight = 450,
    };
}
