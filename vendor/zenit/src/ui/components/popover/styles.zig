/// Popover, style layer
///
/// Floating panel appearance declaration; overlay lifecycle / portal / positioning logic in
/// mod.zig.
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const Border = core.Border;
const Shadow = core.Shadow;

/// Panel corner radius, border.radius and hit/clip shape share same scalar
pub fn popoverRadius(t: *const theme.ThemeTokens) f32 {
    return t.tokens.radius.md;
}

pub fn popoverContentBackground(t: *const theme.ThemeTokens) Color {
    return t.tokens.color.bg_secondary;
}

pub fn popoverContentBorder(t: *const theme.ThemeTokens) Border {
    return .{
        .width = 1,
        .color = t.tokens.color.border,
        .radius = popoverRadius(t),
    };
}

/// Main shadow layer, token shadow.md
pub fn popoverKeyShadow(t: *const theme.ThemeTokens) Shadow {
    return t.tokens.shadow.md;
}

/// Ambient light shadow layer: large-extent soft shadow simulates elevation (MD3 double-shadow
/// style)
pub const popover_ambient_shadow: Shadow = .{
    .color = Color.rgba(0, 0, 0, 18),
    .blur = 40,
    .offset_x = 0,
    .offset_y = 16,
};
