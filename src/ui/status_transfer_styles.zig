//! Bottom-bar transfer display. The existing popover is owned by its host.
const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub const ButtonStyle = @FieldType(ui.widgets.ControlShellConfig, "style");
pub const preferred_width: f32 = 300;
pub const completed_width: f32 = 220;
pub fn button(idle: bool) ButtonStyle {
    return .{ .width = if (idle) .{ .fit = .{} } else .{ .px = preferred_width }, .height = .{ .px = 26 }, .padding = .{}, .gap = 0, .background = if (idle) ui.Color.TRANSPARENT else theme.popupInset(), .corner_radius = 7, .border_width = 0, .flex_shrink = 0 };
}
pub fn hover() ButtonStyle {
    return .{ .background = theme.states().hover };
}
pub fn row(idle: bool) ui.BoxStyle {
    return .{ .width = if (idle) .{ .fit = .{} } else .fill(), .height = .{ .px = 26 }, .direction = .row, .align_items = .center, .gap = 6, .padding = .{ .left = 7, .right = 7 }, .min_width = 0 };
}
pub fn icon() ui.Style {
    return .{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .flex_shrink = 0 };
}
pub fn label(w: f32) ui.BoxStyle {
    return .{ .width = .{ .px = w }, .height = .{ .px = 16 }, .flex_shrink = 0, .overflow_hidden = true };
}
pub fn text(primary: bool) ui.TextStyle {
    return .{ .font_size = if (primary) 10.5 else 10, .font_weight = 400, .line_height = if (primary) 16.0 / 10.5 else 1.6, .color = if (primary) theme.current().fg_1 else theme.current().fg_2, .text_overflow = if (primary) .ellipsis_smart else .ellipsis, .selectable = false, .use_monospace_font = !primary, .text_align = if (primary) .start else .end };
}
pub fn badge() ui.BoxStyle {
    return .{ .width = .{ .px = 18 }, .height = .{ .px = 18 }, .direction = .row, .align_items = .center, .justify = .center, .flex_shrink = 0, .background = theme.current().accent.withAlpha(32), .border = .{ .radius = 9 } };
}
pub fn track(w: f32) ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .left = .{ .px = 7 }, .top = .{ .px = 23 } }, .width = .{ .px = w }, .height = .{ .px = 2 }, .background = theme.current().fg_2.withAlpha(46), .border = .{ .radius = 1 } };
}
pub fn fill(w: f32) ui.BoxStyle {
    return .{ .width = .{ .px = w }, .height = .{ .px = 2 }, .background = theme.current().accent, .border = .{ .radius = 1 } };
}
