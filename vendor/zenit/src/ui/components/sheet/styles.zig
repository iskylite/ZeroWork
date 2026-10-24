/// Sheet, style layer
///
/// Overlay / panel coloring, shadow and content area styles; overlay lifecycle and slide-in
/// animation in mod.zig.
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const Padding = core.Padding;
const Shadow = core.Shadow;

/// Overlay color, props override priority, default overlay token
pub fn sheetBarrierColor(override: ?Color, t: *const theme.ThemeTokens) Color {
    return override orelse t.tokens.color.overlay;
}

/// Panel background, props override priority
pub fn sheetPanelBackground(override: ?Color, t: *const theme.ThemeTokens) Color {
    return override orelse t.tokens.color.bg_secondary;
}

/// Main shadow layer, token shadow.lg
pub fn sheetKeyShadow(t: *const theme.ThemeTokens) Shadow {
    return t.tokens.shadow.lg;
}

/// Ambient light shadow layer: sheet slides in from side, horizontal offset shadow emphasizes depth
pub const sheet_ambient_shadow: Shadow = .{
    .color = Color.rgba(0, 0, 0, 20),
    .blur = 60,
    .offset_x = -8,
    .offset_y = 0,
};

pub fn sheetContentStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .direction = .column,
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
        .padding = Padding.all(16),
    };
}
