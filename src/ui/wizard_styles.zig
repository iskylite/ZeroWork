//! Local Figma Bridge: 339:1019169, 235:370377, 235:371322,
//! 299:587764, 235:378249, 319:702700, 321:890421,
//! SFTP 342:1210942 / 342:1207116 / 319:704376.
const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub const width: f32 = 720;
pub const max_height: f32 = 650;
pub const chrome_height: f32 = 168;

pub fn panel(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = width }, .height = .{ .px = 636 }, .max_height = max_height, .padding = .{}, .gap = 0, .direction = .column, .background = theme.current().overlay, .border = .{ .radius = 14 }, .overflow_hidden = true, .flex_shrink = 0 };
}
pub fn stack(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 6, .flex_shrink = 0 };
}
pub fn card(_: *const ui.ThemeTokens) ui.BoxStyle {
    var style = stack(undefined);
    style.padding = ui.Padding.all(12);
    style.background = theme.current().surface_2;
    style.border = .{ .radius = 9 };
    return style;
}
pub fn header() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 56 }, .padding = .{ .left = 14, .right = 14, .top = 17, .bottom = 9 }, .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0 };
}
pub fn modalBody() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .min_height = 0, .padding = ui.Padding.all(0), .gap = 0, .direction = .column };
}
pub fn body() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .min_height = 0, .direction = .column, .padding = .{ .left = 14, .right = 14 }, .gap = 6 };
}
pub fn row(h: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = h }, .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0 };
}
pub fn footer() ui.BoxStyle {
    var style = row(62);
    style.padding = .{ .left = 14, .right = 14, .top = 14, .bottom = 14 };
    return style;
}
pub fn scroll() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .min_height = 0 };
}
pub fn field(w: ?f32) ui.BoxStyle {
    return .{ .width = if (w) |v| .{ .px = v } else .fill(), .height = .{ .px = 52 }, .direction = .column, .gap = 4, .min_width = 0, .flex_shrink = 1 };
}
pub fn input() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 32 }, .padding = .{ .left = 10, .right = 8 }, .background = theme.current().well, .border = .{ .radius = 8 }, .font_size = 11.5 };
}
pub fn button(w: f32, h: f32, primary: bool) ui.BoxStyle {
    return .{ .width = .{ .px = w }, .height = .{ .px = h }, .padding = .{}, .direction = .row, .align_items = .center, .justify = .center, .gap = 6, .background = if (primary) theme.current().accent else theme.current().well, .border = .{ .radius = 8 }, .flex_shrink = 0 };
}
pub fn disclosure() ui.BoxStyle {
    var style = row(28);
    style.padding = .{};
    style.background = ui.Color.TRANSPARENT;
    return style;
}
pub fn step(selected: bool) ui.BoxStyle {
    return .{ .width = .{ .px = 214 }, .height = .{ .px = 44 }, .padding = .{ .left = 8, .right = 8, .top = 5, .bottom = 5 }, .direction = .row, .align_items = .center, .justify = .start, .gap = 8, .background = if (selected) theme.current().selection else ui.Color.TRANSPARENT, .border = .{ .radius = 7 }, .flex_shrink = 0 };
}
pub fn stepCopy() ui.BoxStyle {
    return .{ .width = .{ .px = 152 }, .height = .{ .px = 16 }, .direction = .column, .gap = 0, .flex_shrink = 0 };
}
pub fn stepTitle(selected: bool) ui.TextStyle {
    var style = text(12, 500, false);
    style.line_height = 16.0 / 12.0;
    style.color = if (selected) theme.current().fg_1 else theme.current().fg_2;
    return style;
}
pub fn stepNumber() ui.TextStyle {
    var style = text(11, 500, false);
    style.text_align = .center;
    return style;
}
pub fn icon(size: f32) ui.Style {
    return .{ .width = .{ .px = size }, .height = .{ .px = size }, .flex_shrink = 0 };
}
pub fn iconBox(size: f32) ui.BoxStyle {
    return .{ .width = .{ .px = size }, .height = .{ .px = size }, .flex_shrink = 0 };
}
// 358:1508903 (direct) / 358:1507656 (routed, unavailable).
pub const test_action_width: f32 = 112;
pub const test_action_height: f32 = 30;
pub const unavailable_test_width: f32 = 196;
pub const unavailable_test_height: f32 = 32;
pub fn number(selected: bool) ui.BoxStyle {
    return .{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .align_items = .center, .justify = .center, .background = if (selected) theme.current().accent else theme.current().well, .border = .{ .radius = 12 }, .flex_shrink = 0 };
}
pub fn routeNode(_: bool) ui.BoxStyle {
    return .{ .width = .{ .px = 146 }, .height = .{ .px = 76 }, .padding = ui.Padding.all(10), .direction = .column, .gap = 2, .background = theme.current().well, .border = .{ .radius = 9 }, .flex_shrink = 0 };
}
// Review/test nodes: Bridge 358:1328872 / 1328884, 146×76, p10, g3.
pub fn testNode() ui.BoxStyle {
    var style = routeNode(false);
    style.gap = 3;
    style.border.?.width = 0;
    return style;
}
pub fn testNodeText(kind: enum { name, address, status }) ui.TextStyle {
    var style = text(switch (kind) {
        .name => 11,
        .address => 9,
        .status => 9.5,
    }, if (kind == .name) 500 else 400, false);
    style.line_height = (if (kind == .address) @as(f32, 14) else 16) / style.font_size;
    return style;
}
// 358:1328935 / 1328950 / 1328988: 28+4+80+4+26 = 142.
pub fn testLogs() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 4, .background = theme.current().well, .border = .{ .radius = 9, .width = 0 }, .flex_shrink = 0 };
}
pub fn testLogText(column: usize) ui.TextStyle {
    var style = text(if (column == 3) 10.5 else 9.5, 400, false);
    style.line_height = 16 / style.font_size;
    return style;
}
pub fn text(size: f32, weight: u16, mono: bool) ui.TextStyle {
    const line: f32 = if (size >= 13) 20 else if (size >= 12) 18 else if (size < 10) 14 else 16;
    return .{ .font_size = size, .font_weight = weight, .line_height = line / size, .color = if (weight >= 500) theme.current().fg_1 else theme.current().fg_2, .selectable = false, .text_overflow = .ellipsis, .use_monospace_font = mono };
}
pub fn label(_: *const ui.ThemeTokens) ui.TextStyle {
    return text(10.5, 400, false);
}
pub fn title(_: *const ui.ThemeTokens) ui.TextStyle {
    return text(12, 500, false);
}
pub fn hint(_: *const ui.ThemeTokens) ui.TextStyle {
    var style = text(10.5, 400, false);
    style.color = theme.current().fg_3;
    return style;
}
pub fn paragraph(_: *const ui.ThemeTokens) ui.TextStyle {
    var style = text(10.5, 400, false);
    style.wrap = .word;
    style.text_overflow = .clip;
    return style;
}
pub fn logs(_: *const ui.ThemeTokens) ui.TextStyle {
    var style = paragraph(undefined);
    style.use_monospace_font = true;
    style.selectable = true;
    return style;
}
pub fn action(primary: bool) ui.TextStyle {
    var style = text(12, 500, false);
    style.text_overflow = .clip;
    style.color = if (primary) theme.widgetTheme(theme.currentName()).tokens.color.button_primary_fg else theme.current().fg_2;
    return style;
}
pub fn testActionText() ui.TextStyle {
    var style = action(false);
    style.text_align = .center;
    style.text_overflow = .clip;
    return style;
}
pub fn testActionLabel() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 18 }, .flex_shrink = 0 };
}

pub fn readonlyValue(_: *const ui.ThemeTokens) ui.TextStyle {
    var style = text(11.5, 400, false);
    style.color = theme.current().fg_1;
    return style;
}

// Figma 235:386917 / 358:1343982: 720×286 shell, 692×118 card.
pub const discard_height: f32 = 286;
pub fn discardCard() ui.BoxStyle {
    var value = card(undefined);
    value.height = .{ .px = 118 };
    return value;
}
pub fn discardLine() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 16 }, .min_width = 0, .flex_shrink = 0 };
}
pub fn discardText(secondary: bool) ui.TextStyle {
    var value = text(if (secondary) 11 else 12, 400, false);
    value.color = if (secondary) theme.current().fg_2 else theme.current().fg_1;
    value.line_height = 16.0 / @as(f32, if (secondary) 11 else 12);
    return value;
}

pub fn topFade(_: *const ui.ThemeTokens) ui.BoxStyle {
    const c = theme.current();
    return .{ .width = .fill(), .height = .{ .px = 72 }, .position = .absolute, .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } }, .gradient = .{ .from = c.well_border.withAlpha(184), .to = c.overlay.withAlpha(0) }, .border = .{ .radius = 14 }, .hit_behavior = .pass_through };
}
pub fn grip(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .top = .{ .px = 7 }, .left = .{ .percent = 50 } }, .width = .{ .px = 32 }, .height = .{ .px = 3 }, .margin = .{ .left = -16 }, .background = theme.current().fg_3, .border = .{ .radius = 1.5 }, .hit_behavior = .pass_through };
}

pub fn summaryName() ui.TextStyle {
    var value = text(12, 500, false);
    value.line_height = 16.0 / 12.0;
    return value;
}
pub fn summaryField(w: f32) ui.BoxStyle {
    return .{ .width = .{ .px = w }, .height = .{ .px = 16 }, .min_width = 0, .flex_shrink = 1 };
}
pub fn summaryOptions(_: *const ui.ThemeTokens) ui.TextStyle {
    var value = text(11, 400, false);
    value.wrap = .word;
    value.text_overflow = .clip;
    return value;
}

// Field error prototype 319:703127: 10.5px / 16px, input32 + gap4 + error16.
pub fn fieldRow() ui.BoxStyle {
    var value = row(52);
    value.height = .{ .fit = .{} };
    value.align_items = .start;
    return value;
}
pub fn errorLabel() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 16 }, .min_width = 0, .flex_shrink = 0 };
}
