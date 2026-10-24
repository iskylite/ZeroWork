//! Figma 416:1912203/2206/2207/2227/2272: default 600×456 float.
const ui = @import("ui");
const theme = @import("app_theme.zig");
pub const ButtonStyle = @FieldType(ui.widgets.ControlShellConfig, "style");
pub fn panel(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .hit_behavior = .@"opaque", .width = .{ .px = 600 }, .height = .{ .px = 456 }, .direction = .column, .background = theme.current().overlay, .border = .{ .radius = 14 }, .shadows = ui.ShadowList.of(&.{.{ .color = theme.current().shadow, .blur = 48, .offset_y = 18 }}), .overflow = .hidden };
}
pub fn gripRow(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 14 }, .flex_shrink = 0, .align_items = .center, .justify = .center };
}
pub fn grip(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = 36 }, .height = .{ .px = 4 }, .background = theme.current().border, .border = .{ .radius = 2 } };
}
pub fn header(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 34 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .gap = 6, .padding = .{ .left = 14, .right = 14, .bottom = 8, .top = 2 } };
}
pub fn title(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 12, .font_weight = 600, .line_height = 18.0 / 12.0, .color = theme.current().fg_1 };
}
pub fn secondary(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10.5, .font_weight = 400, .line_height = 16.0 / 10.5, .color = theme.current().fg_2, .text_overflow = .ellipsis };
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
    return .{ .width = .{ .px = 16 }, .height = .{ .px = 16 } };
}
pub fn regionIcon() ui.Style {
    return .{ .width = .{ .px = 18 }, .height = .{ .px = 18 }, .flex_shrink = 0 };
}
pub fn ownerPill(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .fit = .{} }, .max_width = 184, .height = .{ .px = 20 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .padding = .{ .left = 8, .right = 8 }, .background = theme.current().well, .border = .{ .radius = 8 }, .overflow = .hidden };
}
pub fn userBubbleMaxWidth(content_width: f32) f32 {
    return @max(0, content_width) * 0.75;
}
pub fn userBubble(content_width: f32) ui.BoxStyle {
    // DESIGN_STANDARDS §2.2 R15 action colors, separate from text accent ink.
    const colors: [2]ui.Color = switch (theme.currentName()) {
        .dark => .{ ui.Color.hex(0x6164ec), ui.Color.hex(0x8457ea) },
        .light => .{ ui.Color.hex(0x4f46e5), ui.Color.hex(0x7c3aed) },
        .sauber => .{ ui.Color.hex(0x1345f6), ui.Color.hex(0x2563eb) },
    };
    return .{ .max_width = userBubbleMaxWidth(content_width), .padding = .{ .left = 13, .right = 13, .top = 9, .bottom = 9 }, .gradient = .{ .from = colors[0], .to = colors[1], .direction = .diagonal }, .border = .{ .width = 0, .radius = 12 } };
}
pub fn messageRow(user: bool) ui.BoxStyle {
    // Align the measured, max-width-clamped bubble on the cross axis. Row
    // justification uses an unwrapped intrinsic width before the clamp.
    // Figma conversation viewport reserves a 12px scrollbar gutter after its content.
    return .{ .width = .fill(), .direction = .column, .align_items = if (user) .end else .start, .padding = .{ .right = if (user) 12 else 0 }, .flex_shrink = 0 };
}
pub fn conversation(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .direction = .column, .gap = 6, .padding = .{ .left = 14, .right = 14 }, .height = .{ .fit = .{} }, .flex_shrink = 0 };
}
pub fn composer(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 90 }, .flex_shrink = 0, .direction = .column, .gap = 4, .padding = .{ .left = 14, .right = 14, .top = 6, .bottom = 6 }, .background = theme.current().well };
}
pub fn controls(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 28 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .gap = 6 };
}
pub fn input() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 46 }, .min_height = 46, .flex_shrink = 0, .background = ui.Color.TRANSPARENT, .border = .{ .width = 0, .radius = 8 } };
}
pub fn primary() ButtonStyle {
    // Send and Stop share one stable slot while requests enter/leave the dock.
    return .{ .position = .absolute, .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } }, .width = .{ .px = 28 }, .height = .{ .px = 28 }, .padding = .{}, .gap = 0, .corner_radius = 8, .background = theme.current().accent, .flex_shrink = 0 };
}

pub fn stopIcon(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = 10 }, .height = .{ .px = 10 }, .flex_shrink = 0, .background = theme.current().accent_ink, .border = .{ .radius = 2 } };
}

// HTML .bub-a: ordinary answers are open prose, without another card shell.
pub fn assistantMessage() ui.BoxStyle {
    return .{ .width = .fill(), .min_width = 0, .direction = .column, .gap = 4, .flex_shrink = 0 };
}
pub fn markdownOptions() ui.widgets.MarkdownOptions {
    return .{ .base_font_size = 11.5, .code_font_size = 11, .text_color = theme.current().fg_1, .code_color = theme.current().fg_1, .code_bg = theme.current().well, .link_color = theme.current().accent, .rule_color = theme.current().border, .heading_color = theme.current().fg_1, .paragraph_gap = 4, .line_height = 17.0 / 11.5, .code_line_height = 16.0 / 11.0 };
}

pub const body_font_size: f32 = 11.5;
pub const body_line_height: f32 = 17.0 / body_font_size;
pub const heading_font_size: f32 = 13;

/// Match the floating shell's lower corners without rounding the divider edge.
pub fn finishComposer(cx: *ui.Cx, node: *ui.Node) void {
    node.style.ensureExtPanic(cx.allocator).corner_radius = .{ .each = .{ 0, 0, 14, 14 } };
}
