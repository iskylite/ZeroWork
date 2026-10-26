//! Local Bridge R25: 603:313837 / 608:314528/537/547/555; popovers 358:1420081 / 1416361 /
//! 1425377 / 1446740; attachment menu 414:1872239.
const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub const Kind = enum { attachment, permission, model, effort, usage };
pub fn width(kind: Kind) f32 {
    return switch (kind) {
        .attachment => 300,
        .permission => 344,
        .model => 336,
        .effort => 276,
        .usage => 344,
    };
}
pub fn height(kind: Kind) f32 {
    return switch (kind) {
        .attachment => 166,
        .permission => 194,
        .model => 321.5,
        .effort => 86,
        .usage => 156,
    };
}
pub fn row() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 28 }, .direction = .row, .align_items = .center, .gap = 8, .flex_shrink = 0, .min_width = 0 };
}
pub fn trailing() ui.BoxStyle {
    return .{ .position = .relative, .width = .{ .px = 28 }, .height = .{ .px = 28 }, .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0 };
}
pub fn chip(w: f32, radius: f32) ui.BoxStyle {
    return .{ .width = .{ .px = w }, .height = .{ .px = 24 }, .direction = .row, .align_items = .center, .justify = .start, .padding = .{ .left = 8, .right = 8 }, .gap = 4, .background = theme.current().surface_2, .border = .{ .width = 0, .radius = radius }, .flex_shrink = 0 };
}
pub fn iconButton(radius: f32) ui.BoxStyle {
    var result = chip(24, radius);
    result.padding = .{};
    result.justify = .center;
    return result;
}
// R25 fixed chip slots keep native Button focus and click behavior while
// matching the declared dot, icon, label and chevron positions.
pub fn chipIcon(kind: Kind) ui.BoxStyle {
    const size: f32 = if (kind == .usage) 8 else if (kind == .permission) 12 else if (kind == .effort) 14 else 10;
    return slot(8, (24 - size) / 2, size, size);
}
pub fn chipLabel(kind: Kind) ui.BoxStyle {
    return switch (kind) {
        .permission => slot(24, 5, 50, 14),
        .model => slot(22, 4, 108, 16),
        .usage => slot(20, 5, 30, 14),
        .effort => slot(26, 4, 32, 16),
        else => unreachable,
    };
}
pub fn chipChevron(kind: Kind) ui.BoxStyle {
    return if (kind == .permission) slot(78, 6, 12, 12) else slot(if (kind == .effort) 62 else 170, 7, 10, 10);
}
pub fn modelVision() ui.BoxStyle {
    return .{ .width = .{ .px = 12 }, .height = .{ .px = 12 }, .flex_shrink = 0 };
}
fn slot(x: f32, y: f32, slot_width: f32, slot_height: f32) ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .left = .{ .px = x }, .top = .{ .px = y } }, .width = .{ .px = slot_width }, .height = .{ .px = slot_height }, .flex_shrink = 0, .min_width = 0 };
}
pub fn hover() ui.BoxStyle {
    return .{ .background = theme.current().hover };
}
pub fn icon(size: f32) ui.Style {
    return .{ .width = .{ .px = size }, .height = .{ .px = size }, .flex_shrink = 0 };
}
pub fn text(size: f32, weight: u16, line: f32, secondary: bool) ui.TextStyle {
    return .{ .font_size = size, .font_weight = weight, .line_height = line / size, .color = if (secondary) theme.current().fg_2 else theme.current().fg_1, .selectable = false, .text_overflow = .ellipsis };
}
pub fn label(w: f32, h: f32) ui.BoxStyle {
    return .{ .width = .{ .px = w }, .height = .{ .px = h }, .min_width = 0, .flex_shrink = 0 };
}
pub fn flexibleLabel(h: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = h }, .flex = 1, .min_width = 0 };
}
pub fn wrapper() ui.BoxStyle {
    return .{ .position = .absolute, .width = .{ .px = 0 }, .height = .{ .px = 0 }, .padding = .{}, .gap = 0 };
}
pub fn panel(kind: Kind, viewport: ui.Size) ui.BoxStyle {
    const panel_height = @min(height(kind), @max(0, viewport.height - 16));
    return .{ .width = .{ .px = @min(width(kind), @max(0, viewport.width - 16)) }, .height = .{ .px = panel_height }, .min_height = panel_height, .direction = .column, .padding = if (kind == .model) ui.Padding.all(15) else if (kind == .attachment) ui.Padding.all(10) else if (kind == .usage) ui.Padding.all(14) else .{ .top = 10, .left = 12, .right = 12, .bottom = 12 }, .gap = if (kind == .attachment or kind == .model) 6 else 8, .background = theme.current().overlay, .border = .{ .width = if (kind == .model or kind == .usage) 1 else 0, .color = theme.current().border, .radius = if (kind == .attachment or kind == .usage or kind == .model) 11 else 14 }, .shadow = .{ .offset_y = 12, .blur = 24, .color = theme.current().shadow } };
}
pub fn header() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 28 }, .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0 };
}
pub fn close() ui.BoxStyle {
    var result = iconButton(6);
    result.width = .{ .px = 22 };
    result.height = .{ .px = 22 };
    return result;
}
pub fn body(kind: Kind) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .min_height = 0, .direction = .column, .gap = if (kind == .model) 6 else if (kind == .effort) 2 else 6, .padding = .{ .right = if (kind == .usage or kind == .model or kind == .permission) 0 else 12 }, .flex = 1 };
}
pub fn option(h: f32, selected: bool) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = h }, .direction = .row, .align_items = .center, .justify = .start, .padding = ui.Padding.all(6), .gap = 6, .background = if (selected) theme.current().selection else theme.current().surface_2, .border = .{ .width = 0, .radius = 7 }, .flex_shrink = 0, .min_width = 0 };
}
pub fn models() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .min_height = 0, .flex = 1 };
}
pub fn attachmentRow() ui.BoxStyle {
    var result = option(32, false);
    result.padding = ui.Padding.all(4);
    result.background = ui.Color.TRANSPARENT;
    result.border = .{ .width = 0, .radius = 0 };
    return result;
}
pub fn sliderArea() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 28 }, .direction = .column, .flex_shrink = 0 };
}
pub fn slider() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 16 }, .padding = .{ .left = 12, .right = 12, .top = 5, .bottom = 0 }, .flex_shrink = 0 };
}
pub fn sliderTick(index: usize, count: usize) ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .left = .{ .percent = @as(f32, @floatFromInt(index)) * 100 / @as(f32, @floatFromInt(@max(2, count) - 1)) }, .top = .{ .px = 4 } }, .margin = .{ .left = -2 }, .width = .{ .px = 4 }, .height = .{ .px = 4 }, .background = theme.current().accent, .border = .{ .radius = 2 } };
}
pub fn sliderThumb() ui.BoxStyle {
    return .{ .background = theme.current().accent, .border = .{ .width = 0, .radius = 6 }, .shadow = .{ .color = ui.Color.TRANSPARENT } };
}
pub fn ticks() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 12 }, .direction = .row, .justify = .space_between, .align_items = .center, .flex_shrink = 0 };
}
pub fn usageRow() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 20 }, .direction = .row, .align_items = .center, .gap = 8, .flex_shrink = 0 };
}
pub fn ring() ui.BoxStyle {
    return .{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .flex_shrink = 0 };
}

pub fn usageColor(index: usize) ui.Color {
    const colors = theme.current();
    return switch (index % 3) {
        0 => colors.fg_3,
        1 => colors.accent,
        else => colors.ok_ink,
    };
}
pub fn usageTrack() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 4 }, .direction = .row, .gap = 1, .background = theme.current().well, .border = .{ .radius = 2 }, .overflow = .hidden, .flex_shrink = 0, .margin = .{ .bottom = 4 } };
}
pub fn usageSegment(ratio: f32, index: usize) ui.BoxStyle {
    return .{ .width = .{ .percent = ratio * 100 }, .height = .fill(), .background = usageColor(index), .flex_shrink = 0 };
}
pub fn usageSwatch(index: usize) ui.BoxStyle {
    return .{ .width = .{ .px = 8 }, .height = .{ .px = 8 }, .background = usageColor(index), .border = .{ .radius = 2 }, .flex_shrink = 0 };
}

pub fn modelCard(h: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = h }, .direction = .column, .padding = ui.Padding.all(6), .gap = 2, .background = theme.current().surface_2, .border = .{ .radius = 8 }, .flex_shrink = 0, .min_height = 0 };
}
pub fn modelHeader() ui.BoxStyle {
    var s = header();
    s.height = .{ .px = 26 };
    s.padding = .{ .top = 2 };
    s.margin = .{ .bottom = 6 };
    s.gap = 8;
    return s;
}
pub fn modelListCard(h: f32) ui.BoxStyle {
    var s = modelCard(h);
    s.padding = .{ .top = 4, .bottom = 4, .left = 6, .right = 6 };
    s.gap = 0;
    s.flex_shrink = 0;
    return s;
}
pub fn groupLabel() ui.BoxStyle {
    var s = option(24, false);
    s.background = ui.Color.TRANSPARENT;
    return s;
}
pub fn combinedEffortLabel() ui.BoxStyle {
    return slot(134, 4, 32, 16);
}

pub fn modelOption(selected: bool) ui.BoxStyle {
    var s = option(30, selected);
    s.padding = .{ .left = 6, .right = 6 };
    s.gap = 8;
    s.background = if (selected) theme.current().selection else ui.Color.TRANSPARENT;
    s.border = .{ .radius = 6 };
    return s;
}
pub fn modelRowWrapper() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 30 }, .min_width = 0 };
}

pub fn tuneInput(input: *ui.widgets.input.InputResult) void {
    input.state.font_size = 11.5;
    input.state.line_height = 17;
    input.state.char_width = 6.9;
    input.state.dirty = true;
    if (input.state.text_display_node) |node| if (node.getText()) |text_value| {
        var next = text_value;
        next.font_size = 11.5;
        next.line_height = 17.0 / 11.5;
        next.color = theme.current().fg_1;
        node.setText(next);
    };
}

pub fn naturalChip() ui.BoxStyle {
    var result = chip(0, 8);
    result.width = .{ .fit = .{} };
    return result;
}
pub fn compactModelWidth(model_width: f32, effort_width: f32, vision: bool) f32 {
    return 32 + (if (vision) @as(f32, 16) else 0) + model_width + (if (effort_width > 0) effort_width + 4 else 0);
}
pub fn compactModelLabel(_: f32, _: bool) ui.BoxStyle {
    return .{ .position = .relative, .inset = .{}, .width = .{ .fit = .{} }, .height = .{ .px = 14 }, .max_width = 100, .flex_shrink = 0 };
}
pub fn compactEffortLabel(_: f32, _: f32, _: bool) ui.BoxStyle {
    return .{ .position = .relative, .inset = .{}, .width = .{ .fit = .{} }, .height = .{ .px = 14 }, .flex_shrink = 0 };
}
pub fn compactModelChevron(_: f32, _: f32, _: bool) ui.BoxStyle {
    return .{ .position = .relative, .inset = .{}, .width = .{ .px = 12 }, .height = .{ .px = 12 }, .flex_shrink = 0 };
}

pub fn visionTarget() ui.BoxStyle {
    return .{ .width = .{ .px = 12 }, .height = .{ .px = 12 }, .flex_shrink = 0 };
}

pub fn modelMarker() ui.BoxStyle {
    return .{ .width = .{ .px = 12 }, .height = .{ .px = 16 }, .direction = .row, .align_items = .center, .justify = .center, .flex_shrink = 0 };
}
pub fn modelMarkerDot() ui.BoxStyle {
    return .{ .width = .{ .px = 4 }, .height = .{ .px = 4 }, .background = theme.current().fg_3, .border = .{ .radius = 2 }, .flex_shrink = 0 };
}
pub fn modelMarkerText() ui.TextStyle {
    var value = text(12, 600, 16, false);
    value.color = theme.current().accent;
    value.text_align = .center;
    return value;
}

// The usage panel owns the full-width native action, matching its option rows.
pub fn compactionButton() ui.BoxStyle {
    var style = option(28, false);
    style.width = .{ .px = 112 };
    style.flex_shrink = 0;
    return style;
}

pub fn compactionStatus() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 84 }, .direction = .row, .background = theme.current().well, .border = .{ .radius = 8 }, .overflow = .hidden, .margin = .{ .top = 8, .left = 1, .right = 1 }, .flex_shrink = 0 };
}
pub fn compactionStatusBody() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .min_width = 0, .direction = .column, .padding = .{ .top = 10, .bottom = 10, .left = 12, .right = 12 }, .gap = 4 };
}
pub fn compactionFooter() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 28 }, .direction = .row, .justify = .end, .align_items = .center, .gap = 8, .flex_shrink = 0 };
}
