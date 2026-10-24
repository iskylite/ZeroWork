/// Tooltip, style layer
///
/// Content bubble style constants and coloring functions; overlay lifecycle and mount logic in
/// mod.zig.
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const Padding = core.Padding;

/// Bubble corner radius, border.radius and hit/clip shape share same scalar
pub const tooltip_radius: f32 = 4;

pub const tooltip_content_padding: Padding = Padding.symmetric(4, 8);

/// Bubble background, props override priority, default tooltip_bg token
pub fn tooltipContentBackground(override: ?Color, t: *const theme.ThemeTokens) Color {
    return override orelse t.tokens.color.tooltip_bg;
}

/// Bubble text, font_size parameterized by props
pub fn tooltipLabelStyle(text_color_override: ?Color, font_size: f32, t: *const theme.ThemeTokens) core.TextStyle {
    return .{
        .font_size = font_size,
        .color = text_color_override orelse t.tokens.color.tooltip_fg,
    };
}
