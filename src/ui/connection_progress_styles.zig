//! Native connection attempt, aligned with UI_V3/connection modal and stage rows.
const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub const width: f32 = 760;
pub const normal_height: f32 = 348;
pub const failed_height: f32 = 364;
pub const log_extra_height: f32 = 130;
pub const authentication_height: f32 = 346;
pub const max_hops = 9;

pub fn panel(h: f32, viewport_width: f32) ui.BoxStyle {
    return .{ .width = .{ .px = @min(width, @max(160, viewport_width - 16)) }, .height = .{ .px = h }, .padding = .{}, .gap = 0, .direction = .column, .background = theme.current().overlay, .border = .{ .radius = 14 }, .overflow_hidden = true };
}
pub fn header() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 40 }, .direction = .row, .align_items = .center, .gap = 6, .padding = .{ .left = 12, .right = 12 }, .flex_shrink = 0 };
}
pub fn attemptHeader(compact: bool) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = if (compact) 48 else 52 }, .direction = .row, .align_items = .center, .gap = 12, .padding = .{ .left = if (compact) 18 else 20, .right = if (compact) 18 else 20 }, .flex_shrink = 0 };
}
pub fn body(compact: bool) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .min_height = 0, .direction = .column, .padding = .{ .left = if (compact) 18 else 24, .right = if (compact) 18 else 24, .top = 0, .bottom = if (compact) 12 else 20 }, .gap = 12 };
}
pub fn stack() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 12, .flex_shrink = 0 };
}
pub fn row(h: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = h }, .direction = .row, .align_items = .center, .gap = 8, .flex_shrink = 0 };
}
pub fn scroll() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .min_height = 0 };
}
pub fn chainScroll() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .flex_shrink = 0 };
}
pub fn chain(count: usize, available: f32) ui.BoxStyle {
    _ = count;
    _ = available;
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 12, .flex_shrink = 0 };
}
pub fn card(selected: bool) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 42 }, .direction = .row, .align_items = .center, .padding = .{ .left = 12, .right = 12, .top = 10, .bottom = 10 }, .gap = 12, .background = if (selected) theme.current().selection else theme.current().well, .border = .{ .radius = 8 }, .flex_shrink = 0 };
}
pub fn footer(compact: bool) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = if (compact) 54 else 62 }, .direction = .row, .align_items = .center, .gap = 8, .padding = .{ .left = if (compact) 18 else 24, .right = if (compact) 18 else 24, .top = if (compact) 10 else 14, .bottom = if (compact) 10 else 14 }, .background = theme.current().surface_2, .flex_shrink = 0 };
}
pub fn connector() ui.BoxStyle {
    return .{ .width = .{ .px = 24 }, .height = .{ .px = 52 }, .direction = .column, .align_items = .center, .justify = .center, .gap = 4, .flex_shrink = 0 };
}
pub fn connectorText() ui.TextStyle {
    var result = text(8.5, 400, false);
    result.line_height = 12.0 / 8.5;
    result.text_align = .center;
    return result;
}
pub fn text(size: f32, weight: u16, mono: bool) ui.TextStyle {
    const line: f32 = if (size >= 13) 20 else if (size >= 12) 18 else if (size <= 10) 14 else 16;
    return .{ .font_size = size, .font_weight = weight, .line_height = line / size, .color = if (weight >= 500) theme.current().fg_1 else theme.current().fg_2, .selectable = false, .text_overflow = .ellipsis, .use_monospace_font = mono };
}
pub fn paragraph(size: f32, weight: u16) ui.TextStyle {
    var result = text(size, weight, false);
    result.line_height = (if (size >= 12) @as(f32, 18) else 16) / size;
    result.wrap = .word;
    result.text_overflow = .clip;
    return result;
}
pub fn icon(size: f32) ui.Style {
    return .{ .width = .{ .px = size }, .height = .{ .px = size }, .flex_shrink = 0 };
}
pub fn chip() ui.BoxStyle {
    return .{ .width = .{ .fit = .{} }, .min_width = 56, .height = .{ .px = 24 }, .direction = .row, .padding = .{ .left = 9, .right = 9 }, .background = theme.current().surface_2, .border = .{ .radius = 8 }, .align_items = .center, .justify = .center, .flex_shrink = 0 };
}
pub fn attemptLabel() ui.BoxStyle {
    return .{ .width = .{ .fit = .{} }, .min_width = 38, .height = .{ .px = 16 }, .flex_shrink = 0 };
}
pub fn attemptText() ui.TextStyle {
    var result = text(10.5, 500, false);
    result.color = theme.current().fg_2;
    result.text_overflow = .clip;
    return result;
}
pub fn notice(failed: bool) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .min_height = if (failed) 78 else 62, .padding = ui.Padding.all(12), .gap = 4, .direction = .column, .background = theme.current().well, .border = .{ .radius = 9 }, .flex_shrink = 0 };
}
pub fn logs() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 124 }, .background = theme.current().well, .border = .{ .radius = 9 }, .flex_shrink = 0, .overflow_hidden = true };
}
pub fn logContent() ui.BoxStyle {
    var result = stack();
    result.padding = ui.Padding.all(12);
    result.gap = 0;
    return result;
}
pub fn button(w: f32, h: f32, primary: bool) ui.BoxStyle {
    return .{ .width = .{ .px = w }, .height = .{ .px = h }, .padding = .{}, .background = if (primary) theme.current().action_accent else theme.current().surface_2, .border = .{ .radius = 8 }, .align_items = .center, .justify = .center, .flex_shrink = 0 };
}
pub fn iconButton(size: f32) ui.BoxStyle {
    var result = button(size, size, false);
    result.background = ui.Color.TRANSPARENT;
    return result;
}
pub fn actionText(primary: bool) ui.TextStyle {
    var result = text(12, 500, false);
    result.color = if (primary) theme.widgetTheme(theme.currentName()).tokens.color.button_primary_fg else theme.current().fg_2;
    return result;
}
pub fn authentication() ui.BoxStyle {
    var result = stack();
    result.display = .none;
    return result;
}
