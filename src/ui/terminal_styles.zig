//! Native terminal grid values. The timestamp column follows the final V3
//! workspace CSS: 64px time + 12px gap, 11px text on the 22px row baseline.
const ui = @import("ui");
const theme = @import("app_theme.zig");
// Final workspace CSS: .terminal-scroll and .pane-group .terminal-scroll.
pub fn contentPadding(grouped: bool) ui.Padding {
    return if (grouped) .{ .top = 14, .right = 13, .bottom = 14, .left = 13 } else .{ .top = 18, .right = 20, .bottom = 18, .left = 20 };
}
pub const gutter: f32 = 76;
pub const timestamp_x: f32 = 0;
pub const timestamp_y: f32 = 0;
pub const timestamp_width: f32 = 64;
pub const timestamp_size: f32 = 11;
pub const timestamp_height: f32 = 22;
pub const body_size: f32 = 14;
pub const body_height: f32 = 22;

pub fn surface(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .direction = .column, .overflow = .hidden };
}
/// PATCH §12: controls belong to the exact terminal pane, above its canvas.
pub fn aiControlTag(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .right = .{ .px = 12 }, .bottom = .{ .px = 10 } }, .height = .{ .px = 28 }, .direction = .row, .align_items = .center, .gap = 6, .z_index = 9, .hit_behavior = .@"opaque", .flex_shrink = 0 };
}
pub fn aiControlBadge(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .height = .{ .px = 28 }, .direction = .row, .align_items = .center, .justify = .center, .gap = 5, .padding = .{ .left = 9, .right = 9 }, .background = theme.popupSelection(), .corner_radius = 5, .flex_shrink = 0 };
}
pub fn aiControlText(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .line_height = 20.0 / 11.0, .color = theme.current().accent, .selectable = false };
}
pub fn aiControlButton() @FieldType(ui.widgets.ControlShellConfig, "style") {
    return .{ .height = .{ .px = 28 }, .padding = .{ .left = 9, .right = 9 }, .font_size = 11, .font_weight = 500, .corner_radius = 7, .background = theme.popupAction(), .flex_shrink = 0 };
}
pub fn row(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .position = .absolute, .height = .{ .px = body_height }, .flex_shrink = 0 };
}
pub fn timestamp(t: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = ui.arb.px(timestamp_size), .line_height = timestamp_height / timestamp_size, .color = t.tokens.color.fg_secondary, .use_monospace_font = true, .text_align = .start };
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
    return .{ .position = .absolute, .inset = .{ .right = .{ .px = message_inset }, .top = .{ .px = message_inset } }, .width = .{ .px = message_width }, .height = .{ .px = message_height }, .direction = .row, .align_items = .center, .gap = 4, .padding = ui.Padding.all(message_inset), .background = c.overlay, .border = .{ .radius = 14 }, .hit_behavior = .@"opaque", .z_index = 8, .flex_shrink = 0 };
}
pub fn errorMessage(x: f32, width: f32, y: f32, height: f32, background: ui.Color) ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .left = .{ .px = x }, .top = .{ .px = y } }, .width = .{ .px = width }, .height = .{ .px = height }, .direction = .row, .align_items = .center, .gap = 0, .padding = .ZERO, .background = background.withAlpha(@min(background.a, 64)), .border = .{ .radius = 0 }, .hit_behavior = .pass_through, .z_index = 8, .flex_shrink = 0 };
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

/// In-flow history controls: a fixed-height card above the terminal viewport.
pub fn historyCard(_: *const ui.ThemeTokens) ui.BoxStyle {
    const c = theme.current();
    return .{
        .height = .{ .px = 44 },
        .width = .fill(),
        .flex_shrink = 0,
        .direction = .row,
        .align_items = .center,
        .gap = 12,
        .padding = .{ .left = 14, .right = 14 },
        .margin = .{ .bottom = 8 },
        .background = c.surface_1,
        .border = .{ .width = 0, .radius = 11 },
    };
}
