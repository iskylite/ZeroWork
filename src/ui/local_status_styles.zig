const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub const ButtonStyle = @FieldType(ui.widgets.ControlShellConfig, "style");

// Bridge: Local 444:179999; shared collapsed identity 358:1459369.
pub const height: f32 = 30;
pub const chip_height: f32 = 26;
pub const gap: f32 = 6;
// Local status has no latency: 29.5px icon/label inset + 44px state + trailing padding.
pub const identity_width: f32 = 82;
pub const collapsed_identity_width: f32 = 48;
pub const encoding_width: f32 = 68;
pub const grid_width: f32 = 82;
pub const cwd_width: f32 = 440;
pub const right_padding: f32 = 8;

pub fn bar() ui.BoxStyle {
    const c = theme.current();
    return .{ .width = .fill(), .height = .{ .px = height }, .direction = .row, .align_items = .center, .gap = gap, .padding = .{ .right = right_padding }, .background = c.surface_1, .inset_shadow = @import("shell_styles.zig").cardHighlight(), .border = .{ .radius = 11 }, .shadow = .{ .offset_y = 2, .blur = 4.4, .color = c.shadow }, .flex_shrink = 0 };
}
pub fn barPaint() ui.BoxStyle {
    const c = theme.current();
    return .{ .background = c.surface_1, .inset_shadow = @import("shell_styles.zig").cardHighlight(), .shadow = .{ .offset_y = 2, .blur = 4.4, .color = c.shadow } };
}
pub fn chip(width: f32) ButtonStyle {
    return .{ .width = .{ .px = width }, .height = .{ .px = chip_height }, .direction = .row, .justify = .start, .align_items = .center, .gap = 0, .padding = .{}, .flex_shrink = 0, .background = ui.Color.TRANSPARENT, .corner_radius = 7, .border_width = 0 };
}
pub fn metricContent() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .min_width = 0, .direction = .row, .align_items = .center, .gap = gap };
}
pub fn hover() ButtonStyle {
    return .{ .background = theme.current().hover };
}
pub fn buttonLayout(style: ButtonStyle) ButtonStyle {
    var result = style;
    // Native Button state recipes retain ownership of background/hover.
    result.background = null;
    return result;
}
pub fn identityIcon() ui.BoxStyle {
    return .{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .position = .absolute, .inset = .{ .left = .{ .px = 8 }, .top = .{ .px = 6 } } };
}
pub fn stateDot() ui.BoxStyle {
    return .{ .width = .{ .px = 5 }, .height = .{ .px = 5 }, .position = .absolute, .inset = .{ .left = .{ .px = 18.5 }, .top = .{ .px = 10.5 } }, .border = .{ .radius = 2.5 }, .background = theme.current().fg_3 };
}
pub fn identityTextBox() ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .left = .{ .px = 29.5 }, .top = .{ .px = 5 } }, .width = .{ .px = 44 }, .height = .{ .px = 16 }, .overflow_hidden = true };
}
pub fn chevron() ui.BoxStyle {
    return .{ .width = .{ .px = 12 }, .height = .{ .px = 12 }, .position = .absolute, .inset = .{ .left = .{ .px = 79.5 }, .top = .{ .px = 6 } } };
}
pub fn icon() ui.Style {
    return .{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .flex_shrink = 0 };
}
pub fn label(primary: bool) ui.TextStyle {
    return .{ .font_size = if (primary) 11 else 10.5, .font_weight = if (primary) 500 else 400, .line_height = if (primary) 16.0 / 11.0 else 16.0 / 10.5, .color = if (primary) theme.current().fg_1 else theme.current().fg_2, .text_overflow = .ellipsis, .selectable = false };
}
pub fn labelBox(width: f32) ui.BoxStyle {
    return .{ .width = .{ .px = width }, .height = .{ .px = 16 }, .min_width = 0, .overflow_hidden = true, .flex_shrink = 1 };
}
pub fn cwd(width: f32) ui.BoxStyle {
    return .{ .width = .{ .px = width }, .height = .{ .px = chip_height }, .direction = .row, .align_items = .center, .gap = gap, .min_width = 0, .flex_shrink = 0, .overflow_hidden = true };
}
pub fn action() ButtonStyle {
    return .{ .width = .{ .px = chip_height }, .height = .{ .px = chip_height }, .padding = .{}, .gap = 0, .background = ui.Color.TRANSPARENT, .corner_radius = 7, .border_width = 0, .flex_shrink = 0 };
}
pub fn actionIcon() ui.BoxStyle {
    return .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .position = .absolute, .inset = .{ .left = .{ .px = 5 }, .top = .{ .px = 5 } } };
}

pub fn staticMetric(width: f32) ui.BoxStyle {
    return .{ .width = .{ .px = width }, .height = .{ .px = chip_height }, .direction = .row, .align_items = .center, .padding = .{ .left = 7 }, .flex_shrink = 0 };
}
