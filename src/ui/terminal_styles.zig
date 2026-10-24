//! Exact Local terminal values read from Figma 444:180044 / 486:557191,
//! 444:180066 / 555:397028 on session-mvdcsln0-2cvyti. Design remains read-only.
const ui = @import("ui");
const theme = @import("app_theme.zig");
pub const inset: f32 = 8;
pub const gutter: f32 = 68;
pub const timestamp_x: f32 = 12;
pub const timestamp_y: f32 = 4;
pub const timestamp_width: f32 = 48;
pub const timestamp_size: f32 = 9.5;
pub const timestamp_height: f32 = 14;
pub const body_size: f32 = 14;
pub const body_height: f32 = 22;

pub fn surface(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .direction = .column, .overflow = .hidden };
}
pub fn row(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .position = .absolute, .height = .{ .px = body_height }, .flex_shrink = 0 };
}
pub fn timestamp(t: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = ui.arb.px(timestamp_size), .line_height = timestamp_height / timestamp_size, .color = t.tokens.color.fg_secondary, .use_monospace_font = true, .text_align = .end };
}
pub fn inputHighlight(t: *const ui.ThemeTokens) ui.Color {
    return t.tokens.color.accent.withAlpha(15);
}
pub fn selection(t: *const ui.ThemeTokens) ui.Color {
    return t.tokens.color.accent.withAlpha(55);
}

// Bridge copied states 236:563266 / 236:563499 / 236:563732. Insets are
// relative to the owning terminal pane, not the window or the active tab.
pub const message_duration_ns = 3 * @import("std").time.ns_per_s;
pub const message_inset: f32 = 12;
pub const message_width: f32 = 340;
pub const message_height: f32 = 48;
pub const message_icon_size: f32 = 16;
pub const message_close_size: f32 = 20;

pub fn copiedMessage(_: *const ui.ThemeTokens) ui.BoxStyle {
    const c = theme.current();
    const base = theme.baseColors().app;
    const dark = @as(u32, base.r) * 299 + @as(u32, base.g) * 587 + @as(u32, base.b) * 114 < 128000;
    return .{ .position = .absolute, .inset = .{ .right = .{ .px = message_inset }, .top = .{ .px = message_inset } }, .width = .{ .px = message_width }, .height = .{ .px = message_height }, .direction = .row, .align_items = .center, .gap = 4, .padding = ui.Padding.all(message_inset), .background = c.overlay.withAlpha(@min(c.overlay.a, if (dark) @as(u8, 240) else 245)), .border = .{ .radius = 14 }, .hit_behavior = .@"opaque", .z_index = 8, .flex_shrink = 0 };
}
pub fn errorMessage(width: f32, y: f32, height: f32, background: ui.Color) ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .left = .{ .px = inset }, .top = .{ .px = y } }, .width = .{ .px = width }, .height = .{ .px = height }, .direction = .row, .align_items = .center, .gap = 0, .padding = .ZERO, .background = background, .border = .{ .radius = 0 }, .hit_behavior = .pass_through, .z_index = 8, .flex_shrink = 0 };
}
pub fn copiedText(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11.5, .font_weight = 500, .line_height = 18.0 / 11.5, .color = theme.current().fg_1, .selectable = false };
}
pub fn messageTextBox(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .position = .relative, .width = .fill(), .height = .{ .px = 18 }, .flex = 1, .min_width = 0, .overflow = .hidden };
}
pub fn messageClose(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = message_close_size }, .height = .{ .px = message_close_size }, .padding = .ZERO, .gap = 0, .align_items = .center, .justify = .center, .background = ui.Color.TRANSPARENT, .border = .{ .radius = 7 }, .flex_shrink = 0 };
}
pub fn messageCloseHover() ui.BoxStyle {
    return .{ .background = theme.current().hover };
}
pub fn messageIcon() ui.Style {
    return .{ .width = .{ .px = message_icon_size }, .height = .{ .px = message_icon_size }, .flex_shrink = 0 };
}
