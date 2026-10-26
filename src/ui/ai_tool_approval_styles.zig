//! Figma 401:1871715: compact single-call approval, 152px tall.
const ui = @import("ui");
const theme = @import("app_theme.zig");
pub const ButtonStyle = @FieldType(ui.widgets.ControlShellConfig, "style");
pub fn wrapper(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .padding = .{ .left = 14, .right = 14, .top = 9 }, .flex_shrink = 0, .direction = .column };
}
pub fn panel(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 167.625 }, .padding = ui.Padding.all(11), .flex_shrink = 0, .direction = .column, .background = theme.current().well, .border = .{ .width = 1, .color = theme.current().border, .radius = 9 }, .overflow = .hidden };
}
pub fn header(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 22.5 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .gap = 6, .margin = .{ .bottom = 6 } };
}
pub fn body(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 90.625 }, .flex_shrink = 0 };
}
pub fn content(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 0, .flex_shrink = 0 };
}
pub fn commandRow(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 57 }, .padding = .{ .top = 10, .bottom = 10 }, .flex_shrink = 0, .direction = .row, .gap = 6, .min_width = 0, .align_items = .center };
}
pub fn footer(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 26.5 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .justify = .end, .gap = 6 };
}
pub fn title(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .font_weight = 400, .line_height = 18.15 / 11.0, .color = theme.current().fg_1 };
}
pub fn secondary(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .line_height = 20.625 / 11.0, .color = theme.current().fg_2, .wrap = .word };
}
pub fn command(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10, .line_height = 17.0 / 10.0, .color = theme.current().fg_1, .use_monospace_font = true, .wrap = .word };
}
pub fn impact(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10, .line_height = 13.0 / 10.0, .color = theme.current().warn_ink, .wrap = .word };
}
pub fn iconButton(primary: bool) ButtonStyle {
    return .{ .width = .{ .px = if (primary) 66 else 36 }, .height = .{ .px = 26.5 }, .padding = .{ .left = 8, .right = 8, .top = 5, .bottom = 5 }, .gap = 0, .font_size = 10, .font_weight = 500, .flex_shrink = 0, .corner_radius = 8, .background = if (primary) theme.current().action_accent else theme.current().hover };
}
pub fn disclosureButton() ButtonStyle {
    return .{ .width = .{ .px = 17 }, .height = .{ .px = 17 }, .padding = .{}, .gap = 0, .flex_shrink = 0, .corner_radius = 6, .background = ui.Color.TRANSPARENT };
}
pub fn tail(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 9 }, .flex_shrink = 0 };
}

// Figma 415:1907091 constrains only arguments; target and impact remain reachable
// in the outer body while decisions stay outside both scrolling areas.
pub fn commandViewport(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .flex = 1, .min_width = 0, .height = .{ .px = 37 }, .padding = ui.Padding.all(10), .background = theme.current().well, .corner_radius = 7, .flex_shrink = 0 };
}
pub fn commandContent(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .flex_shrink = 0 };
}

// Figma 603:313815: group compact 32/86/34, standard 32/150/34.
pub fn groupFooter(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 34 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .gap = 6, .padding = .{ .left = 12, .right = 10, .top = 3, .bottom = 3 }, .background = theme.current().well };
}
pub fn groupButton(primary: bool) ButtonStyle {
    return .{ .width = .{ .px = if (primary) 100 else 80 }, .height = .{ .px = 28 }, .padding = .{}, .gap = 0, .flex_shrink = 0, .corner_radius = 8, .font_size = 12, .font_weight = 500, .background = if (primary) theme.current().action_accent else theme.current().surface_2 };
}

// Figma 415:1897823: standard group decisions keep 26px icon controls.
pub fn groupIconFooter(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 34 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .gap = 6, .padding = .{ .left = 12, .right = 10, .top = 4, .bottom = 4 }, .background = theme.current().well };
}
