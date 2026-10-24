//! Figma local Bridge, 2026-10-20: 358:1346170 (direct),
//! 358:1349154 (one jump), 358:1355146 (two jumps), 235:404979 (node).
const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub const ButtonStyle = @FieldType(ui.widgets.ControlShellConfig, "style");
pub const width: f32 = 560;
pub const node_width: f32 = 430;
pub const node_height: f32 = 370;
pub const margin: f32 = 8;
pub const anchor_gap: f32 = 6;
pub const gap: f32 = 6;
pub const pointer_size: f32 = 12;

pub fn height(hops: usize) f32 {
    return 288 + @as(f32, @floatFromInt(hops -| 1)) * 52;
}
pub fn panel(h: f32, viewport_width: f32) ui.BoxStyle {
    const c = theme.current();
    return .{ .width = .{ .px = @min(width, @max(0, viewport_width - margin * 2)) }, .height = .{ .px = h }, .direction = .column, .padding = ui.Padding.all(12), .gap = 0, .background = c.overlay, .border = .{ .radius = 14 }, .shadow = .{ .offset_y = 24, .blur = 32, .color = c.shadow } };
}
pub fn wrapper() ui.BoxStyle {
    return .{ .position = .absolute, .width = .{ .px = 0 }, .height = .{ .px = 0 } };
}
pub fn header() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 28 }, .direction = .row, .align_items = .center, .gap = gap, .flex_shrink = 0 };
}
pub fn spacer(h: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = h }, .flex_shrink = 0 };
}
pub fn scroll() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0 };
}
pub fn stack() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = gap, .flex_shrink = 0 };
}
pub fn row(h: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = h }, .direction = .row, .align_items = .center, .gap = gap, .flex_shrink = 0 };
}
pub fn info() ui.BoxStyle {
    var result = row(26);
    result.padding = .{ .left = 6, .right = 6 };
    result.border = .{ .radius = 7 };
    return result;
}
pub fn card() ButtonStyle {
    // Button keeps its empty default content slot. The explicit cardContent
    // owns the Figma 8 px gaps so that slot adds no extra horizontal gap.
    return .{ .width = .fill(), .height = .{ .px = 46 }, .direction = .row, .align_items = .center, .justify = .start, .gap = 0, .padding = ui.Padding.all(8), .corner_radius = 9, .border_width = 0, .background = theme.current().surface_2, .flex_shrink = 0 };
}
pub fn cardContent() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .direction = .row, .align_items = .center, .gap = 8, .min_width = 0 };
}
pub fn identity() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .flex = 1, .min_width = 0, .direction = .column, .gap = 0 };
}
pub fn cardIdentity() ui.BoxStyle {
    return .{ .width = .{ .px = 400 }, .height = .{ .fit = .{} }, .min_width = 0, .flex_shrink = 1, .direction = .column, .gap = 1 };
}
pub fn cardState() ui.BoxStyle {
    return .{ .width = .{ .px = 64 }, .height = .{ .px = 16 }, .flex_shrink = 0 };
}
pub fn labelBox(h: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = h }, .min_width = 0, .flex_shrink = 0 };
}
pub fn infoLabel() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 16 }, .min_width = 0, .flex = 1 };
}
pub fn titleBox() ui.BoxStyle {
    var result = infoLabel();
    result.height = .{ .px = 20 };
    return result;
}
pub fn trailing() ui.BoxStyle {
    return .{ .width = .{ .px = 100 }, .height = .{ .px = 16 }, .flex_shrink = 0 };
}
pub fn text(size: f32, weight: u16, line: f32, mono: bool) ui.TextStyle {
    return .{ .font_size = size, .font_weight = weight, .line_height = line / size, .color = if (weight >= 500) theme.current().fg_1 else theme.current().fg_2, .use_monospace_font = mono, .selectable = false, .text_overflow = .ellipsis };
}
pub fn title() ui.TextStyle {
    return text(13, 700, 20, false);
}
pub fn name() ui.TextStyle {
    return text(11.5, 500, 18, false);
}
pub fn endpoint() ui.TextStyle {
    return text(10.5, 400, 17, true);
}
pub fn infoText(trailing_value: bool) ui.TextStyle {
    var result = text(if (trailing_value) 10.5 else 11, if (trailing_value) 500 else 400, 16, false);
    result.color = if (trailing_value) theme.current().fg_2 else theme.current().fg_1;
    result.text_align = if (trailing_value) .end else .start;
    return result;
}
pub fn paragraph(size: f32, weight: u16, line: f32, mono: bool) ui.TextStyle {
    var result = text(size, weight, line, mono);
    result.wrap = if (mono) .char else .word;
    result.text_overflow = .clip;
    result.selectable = true;
    return result;
}
pub fn icon(size: f32) ui.Style {
    return .{ .width = .{ .px = size }, .height = .{ .px = size }, .flex_shrink = 0 };
}
pub fn action(size: f32, surface: bool) ButtonStyle {
    return .{ .width = .{ .px = size }, .height = .{ .px = size }, .padding = .{}, .gap = 0, .corner_radius = 7, .border_width = 0, .background = if (surface) theme.current().surface_2 else ui.Color.TRANSPARENT, .flex_shrink = 0 };
}
pub fn hover() ButtonStyle {
    return .{ .background = theme.current().hover };
}
pub fn footer() ui.BoxStyle {
    return row(30);
}
pub fn pointer(left: f32) ui.BoxStyle {
    return .{ .position = .absolute, .width = .{ .px = pointer_size }, .height = .{ .px = pointer_size }, .inset = .{ .left = .{ .px = left }, .bottom = .{ .px = 0 } }, .hit_behavior = .pass_through };
}
pub fn fade() ui.BoxStyle {
    const c = theme.current();
    return .{ .width = .fill(), .height = .{ .px = 72 }, .position = .absolute, .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } }, .gradient = .{ .from = c.well_border.withAlpha(184), .to = ui.Color.lerp(c.surface_1, c.overlay, 0.6).withAlpha(140) }, .border = .{ .radius = 14 }, .hit_behavior = .pass_through, .z_index = -1 };
}
pub fn nodePanel(viewport: ui.Size) ui.BoxStyle {
    return .{ .width = .{ .px = @min(node_width, @max(160, viewport.width - margin * 2)) }, .height = .{ .px = @min(node_height, @max(160, viewport.height - margin * 2)) }, .direction = .column, .gap = 0, .padding = .{}, .background = theme.current().overlay, .border = .{ .radius = 14 }, .overflow_hidden = true };
}
// Figma 358:1349121 (route status action): 28×26, r7,
// 14×14 network icon at (7,6). Default is transparent; hover is theme well.
pub fn trigger() ButtonStyle {
    return .{ .width = .{ .px = 28 }, .height = .{ .px = 26 }, .padding = .{}, .gap = 0, .corner_radius = 7, .background = ui.Color.TRANSPARENT, .border_width = 0, .flex_shrink = 0 };
}
pub fn triggerHover() ButtonStyle {
    return .{ .background = theme.current().hover };
}
pub fn nodeHeader() ui.BoxStyle {
    var result = row(40);
    result.padding = .{ .left = 12, .right = 12 };
    return result;
}
pub fn nodeBody() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0, .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 12 }, .direction = .column, .gap = gap };
}
pub fn nodeIdentity() ui.BoxStyle {
    var result = row(44);
    result.gap = 12;
    return result;
}
pub fn chips() ui.BoxStyle {
    var result = row(24);
    result.gap = 8;
    return result;
}
pub fn chip(online: bool) ui.BoxStyle {
    return .{ .height = .{ .px = 24 }, .direction = .row, .padding = .{ .left = 9, .right = 9 }, .align_items = .center, .justify = .center, .background = if (online) theme.current().ok.withAlpha(33) else theme.current().surface_2, .border = .{ .radius = 8 }, .flex_shrink = 0 };
}
pub fn facts() ui.BoxStyle {
    var result = stack();
    result.padding = ui.Padding.all(12);
    result.background = theme.current().surface_2;
    result.border = .{ .radius = 9 };
    result.min_height = 86;
    return result;
}
pub fn fingerprint() ui.BoxStyle {
    var result = stack();
    result.padding = ui.Padding.all(10);
    result.gap = 4;
    result.background = theme.current().well;
    result.border = .{ .radius = 9 };
    result.min_height = 56;
    return result;
}
pub fn nodeFooter() ui.BoxStyle {
    var result = row(34);
    result.gap = 8;
    return result;
}
pub fn primary() ButtonStyle {
    return .{ .width = .{ .px = 112 }, .height = .{ .px = 34 }, .padding = .{}, .corner_radius = 8, .background = theme.current().accent, .border_width = 0, .flex_shrink = 0 };
}
