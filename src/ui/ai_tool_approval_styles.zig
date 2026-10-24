//! Figma 401:1871715: compact single-call approval, 152px tall.
const ui = @import("ui");
const theme = @import("app_theme.zig");
pub const ButtonStyle = @FieldType(ui.widgets.ControlShellConfig, "style");
pub fn wrapper(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .padding = .{ .left = 20, .right = 20 }, .flex_shrink = 0, .direction = .column };
}
pub fn panel(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 152 }, .flex_shrink = 0, .direction = .column, .background = theme.current().surface_1, .border = .{ .radius = 11 }, .overflow = .hidden };
}
pub fn header(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 32 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .gap = 6, .padding = .{ .left = 10, .right = 12 }, .background = theme.current().warn.withAlpha(26), .border = .{ .radius = 11 } };
}
pub fn body(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 73 }, .flex_shrink = 0 };
}
pub fn content(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 3, .padding = .{ .top = 4, .bottom = 4, .left = 12, .right = 12 }, .flex_shrink = 0 };
}
pub fn commandRow(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 27 }, .flex_shrink = 0, .direction = .row, .gap = 6, .min_width = 0, .align_items = .start };
}
pub fn footer(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 38 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .gap = 6, .padding = .{ .left = 12, .right = 12, .top = 6, .bottom = 6 }, .background = theme.current().well, .border = .{ .radius = 7 } };
}
pub fn title(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11.5, .font_weight = 500, .line_height = 16.0 / 11.5, .color = theme.current().fg_1 };
}
pub fn secondary(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10.5, .line_height = 16.0 / 10.5, .color = theme.current().fg_2, .wrap = .word };
}
pub fn command(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11.5, .line_height = 19.0 / 11.5, .color = theme.current().fg_1, .use_monospace_font = true, .wrap = .word };
}
pub fn impact(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10.5, .line_height = 16.0 / 10.5, .color = theme.current().warn_ink, .wrap = .word };
}
pub fn iconButton(primary: bool) ButtonStyle {
    return .{ .width = .{ .px = if (primary) 84 else 60 }, .height = .{ .px = 26 }, .padding = .{}, .gap = 4, .font_size = 11.5, .font_weight = 500, .flex_shrink = 0, .corner_radius = 7, .background = if (primary) theme.current().accent else theme.current().surface_2 };
}
pub fn disclosureButton() ButtonStyle {
    return .{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .padding = .{}, .gap = 0, .flex_shrink = 0, .corner_radius = 6, .background = ui.Color.TRANSPARENT };
}
pub fn tail(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 9 }, .flex_shrink = 0 };
}

// Figma 415:1907091 constrains only arguments; target and impact remain reachable
// in the outer body while decisions stay outside both scrolling areas.
pub fn commandViewport(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .flex = 1, .min_width = 0, .height = .{ .px = 27 }, .flex_shrink = 0 };
}
pub fn commandContent(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .flex_shrink = 0 };
}

// Figma 603:313815: group compact 32/86/34, standard 32/150/34.
pub fn groupFooter(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 34 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .gap = 6, .padding = .{ .left = 12, .right = 10, .top = 3, .bottom = 3 }, .background = theme.current().well };
}
pub fn groupButton(primary: bool) ButtonStyle {
    return .{ .width = .{ .px = if (primary) 100 else 80 }, .height = .{ .px = 28 }, .padding = .{}, .gap = 0, .flex_shrink = 0, .corner_radius = 8, .font_size = 12, .font_weight = 500, .background = if (primary) theme.current().accent else theme.current().surface_2 };
}

// Figma 415:1897823: standard group decisions keep 26px icon controls.
pub fn groupIconFooter(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 34 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .gap = 6, .padding = .{ .left = 12, .right = 10, .top = 4, .bottom = 4 }, .background = theme.current().well };
}
