//! Figma 416:1912203/2206/2207/2227/2272: default 600×456 float.
const ui = @import("ui");
const theme = @import("app_theme.zig");
pub const ButtonStyle = @FieldType(ui.widgets.ControlShellConfig, "style");
pub fn panel(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .hit_behavior = .@"opaque", .width = .{ .px = 600 }, .height = .{ .px = 456 }, .direction = .column, .padding = ui.Padding.all(1), .background = theme.current().overlay, .border = .{ .width = 1, .color = theme.current().accent_ink.withAlpha(36), .radius = 14 }, .shadows = ui.ShadowList.of(&.{.{ .color = ui.Color.rgba(0, 0, 0, 119), .blur = 48, .offset_y = 18 }}), .overflow = .hidden };
}
pub fn gripRow(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 14 }, .flex_shrink = 0, .align_items = .center, .justify = .center };
}
pub fn grip(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = 36 }, .height = .{ .px = 4 }, .background = switch (theme.currentName()) {
        .dark => ui.Color.hex(0x3a3a42),
        .light => ui.Color.hex(0xd4d4d8),
        .sauber => ui.Color.hex(0xb9d6ae),
    }, .border = .{ .radius = 2 } };
}
pub fn header(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 34 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .gap = 6, .padding = .{ .left = 14, .right = 14, .bottom = 8, .top = 0 } };
}
pub fn title(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 13, .font_weight = 700, .line_height = 18.5 / 13.0, .color = theme.current().fg_1 };
}
pub fn secondary(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .font_weight = 400, .line_height = 16.0 / 11.0, .color = theme.current().fg_2, .text_overflow = .ellipsis };
}
pub fn ownerText(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .line_height = 20.0 / 11.0, .color = theme.current().fg_2, .text_overflow = .ellipsis };
}
pub fn windowControl() ButtonStyle {
    return .{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .padding = .{}, .gap = 0, .corner_radius = 6, .background = ui.Color.TRANSPARENT, .flex_shrink = 0 };
}
pub fn controlHover(kind: enum { collapse, maximize, close }) ButtonStyle {
    _ = kind;
    return .{ .background = theme.current().hover };
}
pub fn icon() ui.Style {
    return .{ .width = .{ .px = 14 }, .height = .{ .px = 14 } };
}
pub fn windowIcon() ui.Style {
    return icon();
}
pub fn regionIcon() ui.Style {
    return .{ .width = .{ .px = 18 }, .height = .{ .px = 18 }, .flex_shrink = 0 };
}
pub fn ownerPill(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .fit = .{} }, .max_width = 160, .height = .{ .px = 20 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .padding = .{ .left = 8, .right = 8 }, .background = theme.current().well, .border = .{ .radius = 8 }, .overflow = .hidden };
}
pub fn userBubbleMaxWidth(content_width: f32) f32 {
    return @max(0, content_width) * 0.75;
}
pub fn userBubble(content_width: f32) ui.BoxStyle {
    // Theme action hue with the global overlay alpha, shared with HTML.
    const c = theme.current();
    const start = c.action_accent.withAlpha(theme.materialAlpha("overlay"));
    const end = c.action_accent_2.withAlpha(start.a);
    return .{ .max_width = userBubbleMaxWidth(content_width), .padding = .{ .left = 13, .right = 13, .top = 9, .bottom = 9 }, .background = start, .gradient = .{ .from = start, .to = end, .direction = .diagonal }, .border = .{ .width = 0, .radius = 12 }, .corner_radii = .{ .each = .{ 12, 12, 4, 12 } } };
}
pub fn userBubbleForeground() ui.Color {
    const c = theme.baseColors();
    const alpha = @as(f32, @floatFromInt(theme.materialAlpha("overlay"))) / 255;
    return theme.actionForeground(ui.Color.lerp(c.overlay, c.action_accent, alpha));
}
pub fn messageRow(user: bool) ui.BoxStyle {
    // Align the measured, max-width-clamped bubble on the cross axis. Row
    // justification uses an unwrapped intrinsic width before the clamp.
    // HTML overlay scrollbars do not reserve a gutter beside the message content.
    return .{ .width = .fill(), .direction = .column, .align_items = if (user) .end else .start, .padding = .{}, .flex_shrink = 0 };
}
pub fn conversation(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .direction = .column, .gap = 12, .padding = .{ .left = 14, .right = 14 }, .height = .{ .fit = .{} }, .flex_shrink = 0 };
}
pub fn composer(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 90 }, .flex_shrink = 0, .direction = .column, .gap = 4, .padding = .{ .left = 14, .right = 14, .top = 6, .bottom = 6 }, .background = theme.current().well, .border = .{ .radius = 10 } };
}
pub fn controls(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 28 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .gap = 6 };
}
pub fn input() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 46 }, .min_height = 46, .flex_shrink = 0, .background = ui.Color.TRANSPARENT, .border = .{ .width = 0, .radius = 8 } };
}
pub fn primary() ButtonStyle {
    // Send and Stop share one stable slot while requests enter/leave the dock.
    return .{ .position = .absolute, .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } }, .width = .{ .px = 28 }, .height = .{ .px = 28 }, .min_width = 28, .min_height = 28, .padding = .{}, .gap = 0, .corner_radius = 8, .background = theme.current().surface_2, .flex_shrink = 0 };
}

pub fn stopIcon(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = 10 }, .height = .{ .px = 10 }, .flex_shrink = 0, .background = theme.current().fg_1, .border = .{ .radius = 2 } };
}

// HTML .bub-a: ordinary answers are open prose, without another card shell.
pub fn assistantMessage() ui.BoxStyle {
    return .{ .width = .fill(), .min_width = 0, .direction = .column, .gap = 4, .flex_shrink = 0 };
}
pub fn markdownOptions() ui.widgets.MarkdownOptions {
    return .{ .base_font_size = 12.5, .code_font_size = 11, .text_color = theme.current().fg_1, .code_color = theme.current().fg_1, .code_bg = theme.current().well, .link_color = theme.current().accent, .rule_color = theme.current().border, .heading_color = theme.current().fg_1, .paragraph_gap = 4, .line_height = 1.65, .code_line_height = 16.0 / 11.0 };
}

pub const body_font_size: f32 = 12.5;
pub const body_line_height: f32 = 1.65;
pub const heading_font_size: f32 = 13;

/// Match the floating shell's lower corners without rounding the divider edge.
pub fn finishComposer(cx: *ui.Cx, node: *ui.Node) void {
    node.style.ensureExtPanic(cx.allocator).corner_radius = .{ .each = .{ 10, 10, 10, 10 } };
}
