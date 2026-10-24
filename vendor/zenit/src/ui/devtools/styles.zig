//! DevTools presentation colors derived from the application's theme.
const core = @import("../core.zig");
const Color = core.Color;

pub const Palette = struct {
    row_selected_bg: Color,
    row_hover_bg: Color,
    component_label: Color,
    text_preview: Color,
    state_card_bg: Color,
    event_name: Color,
    muted: Color,
};

pub fn palette(tokens: *const core.theme.ThemeTokens) Palette {
    const c = tokens.tokens.color;
    const is_dark = tokens.scheme == .dark;
    return .{
        .row_selected_bg = c.selection_bg.withAlpha(if (is_dark) 110 else 70),
        .row_hover_bg = c.list_hover_bg.withAlpha(if (is_dark) 130 else 70),
        .component_label = c.warning,
        .text_preview = c.success,
        .state_card_bg = c.bg_hover.withAlpha(if (is_dark) 120 else 55),
        .event_name = c.warning,
        .muted = if (is_dark) Color.hex(0x6B6B6B) else Color.hex(0x999999),
    };
}
