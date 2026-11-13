//! AI assistant floating panel.
const ui = @import("ui");
const theme = @import("app_theme.zig");
const float = @import("../ai/float_model.zig");
pub const ButtonStyle = @FieldType(ui.widgets.ControlShellConfig, "style");
pub fn panel(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .hit_behavior = .@"opaque", .width = .{ .px = 600 }, .height = .{ .px = float.default_height }, .direction = .column, .padding = ui.Padding.all(1), .background = theme.current().overlay, .glass = theme.overlayGlass(), .border = .{ .width = 0, .radius = 14 }, .shadows = ui.ShadowList.of(&.{.{ .color = ui.Color.rgba(0, 0, 0, 119), .blur = 48, .offset_y = 18 }}), .overflow = .hidden };
}
pub fn gripRow(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 14 }, .flex_shrink = 0, .align_items = .center, .justify = .center };
}
pub fn grip(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = 36 }, .height = .{ .px = 4 }, .background = theme.current().fg_3, .border = .{ .radius = 2 } };
}
pub fn header(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 34 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .gap = header_gap, .padding = .{ .left = header_padding_x, .right = header_padding_x, .bottom = 8, .top = 0 } };
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
pub fn countBadge(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .top = .{ .px = -1 }, .right = .{ .px = 0 } }, .height = .{ .px = 14 }, .background = ui.Color.TRANSPARENT, .padding = .{}, .border = .{ .width = 0, .radius = 0 } };
}
pub fn countBadgeText(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 9, .font_weight = 700, .line_height = 12.0 / 9.0, .text_align = .center, .color = theme.current().accent_ink };
}
pub fn controlHover(kind: enum { collapse, maximize, close }) ButtonStyle {
    _ = kind;
    return .{ .background = theme.states().hover };
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
    return .{ .width = .{ .fit = .{} }, .max_width = 160, .height = .{ .px = 20 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .padding = .{ .left = 8, .right = 8 }, .background = theme.popupInset(), .border = .{ .radius = 8 }, .overflow = .hidden };
}
pub fn userBubbleMaxWidth(content_width: f32) f32 {
    return @max(0, content_width) * 0.75;
}
pub fn userBubble(content_width: f32) ui.BoxStyle {
    // Message cards live on the L1 assistant and use L2 material, shared with HTML.
    const paint = theme.userBubblePaint();
    const start = paint.from;
    const end = paint.to;
    return .{ .max_width = userBubbleMaxWidth(content_width), .padding = .{ .left = 13, .right = 13, .top = 9, .bottom = 9 }, .background = start, .gradient = .{ .from = start, .to = end, .direction = .diagonal }, .border = .{ .width = 0, .radius = 12 }, .corner_radii = .{ .each = .{ 12, 12, 4, 12 } } };
}
pub fn userBubbleForeground() ui.Color {
    return theme.userBubblePaint().foreground;
}
pub fn messageRow(user: bool) ui.BoxStyle {
    // Align the measured, max-width-clamped bubble on the cross axis. Row
    // justification uses an unwrapped intrinsic width before the clamp.
    // HTML overlay scrollbars do not reserve a gutter beside the message content.
    return .{ .width = .fill(), .direction = .column, .align_items = if (user) .end else .start, .padding = .{}, .flex_shrink = 0 };
}
pub fn conversation(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .direction = .column, .gap = 6, .padding = .{ .left = 14, .right = 14 }, .height = .{ .fit = .{} }, .flex_shrink = 0 };
}
pub fn turnProcessButton() ui.BoxStyle {
    return .{ .height = .{ .px = 24 }, .padding = .{}, .gap = 4, .font_size = 14, .font_weight = 500, .text_color = theme.current().fg_1 };
}
pub fn markdownSectionGap(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 8 }, .flex_shrink = 0 };
}
// Feedback belongs to the scrollable transcript, never the composer flex stack.
pub fn noticeHolder(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .min_width = 0, .height = .{ .fit = .{} }, .direction = .column, .padding = .{ .left = 14, .right = 14, .top = 8, .bottom = 12 }, .flex_shrink = 0 };
}
pub fn notice(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .min_width = 0, .height = .{ .fit = .{} }, .direction = .row, .align_items = .start, .gap = 8, .padding = .{ .left = 10, .right = 10, .top = 8, .bottom = 8 }, .background = theme.popupInset(), .border = .{ .radius = 8 }, .flex_shrink = 0 };
}
pub fn noticeText(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .line_height = 18.0 / 11.0, .wrap = .word, .color = theme.current().fg_2 };
}
pub fn composer(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 90 }, .flex_shrink = 0, .direction = .column, .gap = 4, .padding = .{ .left = 14, .right = 14, .top = 6, .bottom = 6 }, .background = theme.popupInset(), .border = .{ .radius = 10 } };
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
    return .{ .base_font_size = body_font_size, .code_font_size = 11, .text_color = theme.current().fg_1, .code_color = theme.current().fg_1, .code_bg = theme.popupInset(), .link_color = theme.current().accent_ink, .rule_color = theme.current().border, .heading_color = theme.current().fg_1, .paragraph_gap = 4, .line_height = body_line_height, .code_line_height = 16.0 / 11.0 };
}

pub const table_min_column_width: f32 = 40;
pub const table_wrapped_column_min_width: f32 = 120;
pub const table_preferred_column_max_width: f32 = 480;

pub fn tableCell(width: f32, is_header: bool, first_column: bool) ui.BoxStyle {
    return .{
        .width = .{ .px = width },
        .min_height = 34,
        .padding = .{ .left = 8, .right = 8, .top = 6, .bottom = 6 },
        // Own the bottom/right rules; only the first row/column add top/left.
        // Shared edges therefore stay one logical pixel wide.
        .border = .{ .width = 1, .color = theme.current().fg_3.withAlpha(255) },
        .border_top_width = if (is_header) 1 else 0,
        .border_left_width = if (first_column) 1 else 0,
        .background = if (is_header) theme.current().well else ui.Color.TRANSPARENT,
        .overflow = .hidden,
        .flex_shrink = 0,
    };
}

pub const body_font_size: f32 = 12.5;
pub const body_line_height: f32 = 1.65;
/// Zenit's Markdown renderer emits h1..h6 at `base_font_size * mdHeadingSizeMul(level)`,
/// spanning 1.0×..1.4×. AI bubbles remap that whole range onto these two sizes so
/// all six levels stay visually ordered with a compact per-line rhythm.
pub const heading_scale_max: f32 = 1.4;
pub const heading_font_size: f32 = 13;
pub const heading_max_font_size: f32 = 15.5;

/// Match the floating shell's lower corners without rounding the divider edge.
pub fn finishComposer(cx: *ui.Cx, node: *ui.Node) void {
    node.style.ensureExtPanic(cx.allocator).corner_radius = .{ .each = .{ 10, 10, 10, 10 } };
}

// The header stays outside the bounded, independently scrollable code area.
pub const code_max_height: f32 = 136;
pub const code_header_height: f32 = 28;
pub fn codeBlock() ui.BoxStyle {
    return .{ .width = .fill(), .min_width = 0, .max_height = code_header_height + code_max_height, .direction = .column, .background = theme.popupInset(), .border = .{ .radius = 6 }, .overflow = .hidden, .flex_shrink = 0 };
}
pub fn codeToolbar() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = code_header_height }, .direction = .row, .align_items = .center, .gap = 8, .padding = .{ .left = 10, .right = 6 }, .background = ui.Color.TRANSPARENT, .flex_shrink = 0 };
}
pub fn codeLanguage() ui.TextStyle {
    return .{ .font_size = 10.5, .font_weight = 600, .line_height = 16.0 / 10.5, .color = theme.current().fg_2, .selectable = false, .text_overflow = .ellipsis };
}
pub fn textSelection() ui.Color {
    return theme.current().accent_ink.withAlpha(80);
}

pub fn codeWrapButton(wrapped: bool) ButtonStyle {
    var style = windowControl();
    if (wrapped) style.background = theme.current().accent_ink.withAlpha(40);
    return style;
}

// Same compact body rhythm inside nested lists and blockquotes.
pub fn markdownContainer(quoted: bool) ui.BoxStyle {
    return .{ .width = .fill(), .min_width = 0, .direction = .row, .align_items = .start, .gap = if (quoted) 8 else 6, .padding = if (quoted) .{ .left = 8, .top = 2, .bottom = 2 } else .{}, .flex_shrink = 0 };
}
pub fn markdownQuoteBar() ui.BoxStyle {
    return .{ .width = .{ .px = 3 }, .height = .fill(), .align_self = .stretch, .background = theme.current().border, .flex_shrink = 0 };
}
pub fn markdownListMarker() ui.TextStyle {
    return .{ .font_size = body_font_size, .line_height = body_line_height, .color = theme.current().fg_1 };
}

pub const workspace_min_width: f32 = 40;
pub const workspace_max_width: f32 = 144;
pub const workspace_chrome_width: f32 = 8 * 2 + 5 * 2 + 13 + 10;
pub const header_padding_x: f32 = 14;
pub const header_gap: f32 = 6;

pub fn workspaceSlot(width: f32) ui.BoxStyle {
    return .{ .width = .{ .px = width }, .height = .{ .px = 20 }, .flex_shrink = 0 };
}
pub fn workspaceButton() ButtonStyle {
    return .{ .width = .fill(), .height = .{ .px = 20 }, .min_width = 0, .flex_shrink = 0, .padding = .{ .left = 8, .right = 8 }, .gap = 5, .corner_radius = 8, .background = theme.popupInset() };
}
pub fn workspaceHover() ?ButtonStyle {
    return .{ .background = theme.states().hover };
}
pub fn workspaceName(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .line_height = 16.0 / 11.0, .color = theme.current().fg_2, .text_overflow = .ellipsis };
}
pub fn workspaceDetails(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .line_height = 16.0 / 11.0, .color = theme.current().fg_2, .wrap = .char };
}
pub fn workspacePopup(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .background = theme.current().overlay, .glass = theme.overlayGlass(), .border = .{ .radius = 11 }, .shadow = .{ .offset_y = 12, .blur = 24, .color = theme.current().shadow } };
}
