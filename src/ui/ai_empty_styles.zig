//! Empty assistant states: Figma 223:330797 and 236:418549.
const ui = @import("ui");
const theme = @import("app_theme.zig");
pub fn root(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .direction = .column, .gap = 6 };
}
pub fn row(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .direction = .row, .align_items = .center, .gap = 6 };
}
pub fn status(configured: bool) ui.TextStyle {
    return .{ .font_size = 10.5, .line_height = 16.0 / 10.5, .color = if (configured) theme.current().accent else theme.current().warn };
}
pub fn action(configured: bool, primary: bool) ui.BoxStyle {
    return .{ .width = if (configured) .fill() else .{ .px = 144 }, .height = .{ .px = if (configured) 30 else 28 }, .flex = if (configured) 1 else 0, .flex_shrink = 0, .padding = .{ .left = 10, .right = 8 }, .corner_radius = 8, .background = if (primary) theme.current().accent else if (configured) theme.current().surface_2 else theme.current().well, .font_size = if (configured) 11 else 12 };
}

pub fn statusRow(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 24 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .gap = 6 };
}
pub fn icon() ui.Style {
    return .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .flex_shrink = 0 };
}

pub fn ink() ui.Color {
    return theme.current().fg_1;
}
pub fn muted() ui.Color {
    return theme.current().fg_2;
}
pub fn success() ui.Color {
    return theme.current().ok_ink;
}
pub fn label() ui.TextStyle {
    return .{ .font_size = 11, .line_height = 16.0 / 11.0, .color = ink(), .selectable = false };
}
pub fn recent() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 32 }, .direction = .row, .align_items = .center, .justify = .start, .gap = 8, .padding = .{ .left = 10, .right = 10 }, .corner_radius = 9, .background = ui.Color.lerp(theme.current().well, theme.current().ok_ink, 0.08), .flex_shrink = 0 };
}

pub fn accentInk() ui.Color {
    return theme.current().accent_ink;
}
pub fn setup() ui.BoxStyle {
    return .{ .width = .fill(), .direction = .column, .align_items = .center, .gap = 12, .flex_shrink = 0 };
}
pub fn setupTitle() ui.TextStyle {
    return .{ .font_size = 12, .font_weight = 700, .line_height = 20.0 / 12.0, .color = ink() };
}
pub fn setupDescription() ui.TextStyle {
    return .{ .font_size = 11, .line_height = 1.65, .color = muted() };
}
pub fn setupAction(primary: bool) ui.BoxStyle {
    const color = switch (theme.currentName()) {
        .dark => ui.Color.hex(0x6164ec),
        .light => ui.Color.hex(0x4f46e5),
        .sauber => ui.Color.hex(0x1345f6),
    };
    return .{ .height = .{ .px = if (primary) 34.5 else 29.5 }, .min_height = if (primary) 34 else 0, .padding = if (primary) .{ .left = 14, .right = 14, .top = 9, .bottom = 9 } else ui.Padding.all(6), .font_size = 12, .font_weight = if (primary) 500 else 400, .corner_radius = if (primary) 8 else 5, .background = if (primary) color else ui.Color.TRANSPARENT, .text_color = if (primary) ui.Color.WHITE else accentInk() };
}
