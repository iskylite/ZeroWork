//! Local Figma Bridge: 339:1019169, 235:370377, 235:371322,
//! 299:587764, 235:378249, 319:702700, 321:890421,
//! SFTP 342:1210942 / 342:1207116 / 319:704376.
const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub const width: f32 = 760;
pub const max_height: f32 = 710;
pub const ButtonStyle = @FieldType(ui.widgets.ControlShellConfig, "style");
pub const chrome_height: f32 = 168;

pub fn panel(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = width }, .height = .{ .px = max_height }, .max_height = max_height, .padding = .{}, .gap = 0, .direction = .column, .background = theme.current().overlay, .border = .{ .radius = 14 }, .overflow_hidden = true, .flex_shrink = 0 };
}
pub fn editorSlot(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .min_height = 0, .flex = 1, .flex_shrink = 1, .direction = .column, .gap = 0 };
}
pub fn stack(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 6, .flex_shrink = 0 };
}
pub fn formSection(_: *const ui.ThemeTokens) ui.BoxStyle {
    var style = stack(undefined);
    style.gap = 14;
    return style;
}
// Measured HTML identity fields start at y230.5 (1280×720), with
// 55.5px field rows separated by 12px.
pub fn identitySection(tokens: *const ui.ThemeTokens) ui.BoxStyle {
    var style = formSection(tokens);
    style.gap = 17.5;
    return style;
}
pub fn identityFields(tokens: *const ui.ThemeTokens) ui.BoxStyle {
    var style = formSection(tokens);
    style.gap = 12;
    return style;
}
pub fn card(_: *const ui.ThemeTokens) ui.BoxStyle {
    var style = stack(undefined);
    style.padding = ui.Padding.all(12);
    style.background = theme.current().surface_2;
    style.border = .{ .radius = 9 };
    return style;
}
pub fn header() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 52 }, .padding = .{ .left = 20, .right = 20, .top = 14, .bottom = 14 }, .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0 };
}
pub fn modalBody() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0, .padding = ui.Padding.all(0), .gap = 0, .direction = .column };
}
pub fn body() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0, .direction = .column, .padding = .{ .left = 20, .right = 20 }, .gap = 14 };
}
pub fn row(h: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = h }, .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0 };
}
pub fn footer() ui.BoxStyle {
    var style = row(62);
    style.padding = .{ .left = 24, .right = 24, .top = 14, .bottom = 14 };
    style.background = theme.current().surface_2;
    return style;
}
pub fn scroll() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0 };
}
pub fn field(w: ?f32) ui.BoxStyle {
    return .{ .width = if (w) |v| .{ .px = v } else .fill(), .height = .{ .px = 55.5 }, .direction = .column, .gap = 5, .min_width = 0, .flex_shrink = 1 };
}
// zenit draws borders inside the box; include the CSS 1px border in content insets.
pub fn input() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 34 }, .padding = .{ .left = 11, .right = 11, .top = 6, .bottom = 6 }, .background = theme.current().well, .border = .{ .radius = 8, .width = 1, .color = ui.Color.TRANSPARENT }, .font_size = 12 };
}
pub fn button(w: f32, h: f32, primary: bool) ui.BoxStyle {
    return .{ .width = .{ .px = w }, .height = .{ .px = h }, .padding = .{}, .direction = .row, .align_items = .center, .justify = .center, .gap = 6, .background = if (primary) theme.current().action_accent else theme.current().well, .gradient = if (primary) .{ .from = theme.current().action_accent, .to = theme.current().action_accent_2, .direction = .diagonal } else null, .border = .{ .radius = 8 }, .flex_shrink = 0 };
}
pub fn disclosure() ui.BoxStyle {
    var style = row(18);
    style.padding = .{};
    style.justify = .start;
    style.gap = 0;
    style.background = ui.Color.TRANSPARENT;
    return style;
}
pub fn step(selected: bool) ui.BoxStyle {
    return .{ .width = .fill(), .flex = 1, .min_width = 0, .height = .{ .px = 36 }, .padding = .{ .left = 8, .right = 8, .top = 5, .bottom = 5 }, .direction = .row, .align_items = .center, .justify = .center, .gap = 12, .background = if (selected) theme.current().selection else ui.Color.TRANSPARENT, .border = .{ .radius = 7 }, .flex_shrink = 0 };
}
pub fn stepCopy() ui.BoxStyle {
    return .{ .width = .{ .fit = .{} }, .height = .{ .px = 18 }, .direction = .column, .gap = 0, .flex_shrink = 0 };
}
pub fn stepTitle(selected: bool) ui.TextStyle {
    var style = text(12, 400, false);
    style.line_height = 18.0 / 12.0;
    style.color = if (selected) theme.current().accent_ink else theme.current().fg_2;
    return style;
}
pub fn stepNumber() ui.TextStyle {
    var style = text(12, 400, false);
    style.line_height = 1.5;
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
pub const test_action_width: f32 = 76;
pub const test_action_height: f32 = 34;
pub const unavailable_test_width: f32 = 196;
pub const unavailable_test_height: f32 = 32;
pub fn number(_: bool) ui.BoxStyle {
    // The approved HTML uses an ordinary step numeral, without a badge.
    return .{ .width = .{ .px = 8 }, .height = .{ .px = 18 }, .align_items = .center, .justify = .center, .background = ui.Color.TRANSPARENT, .flex_shrink = 0 };
}
pub fn accessChoice(selected: bool) ButtonStyle {
    return .{ .width = .fill(), .height = .{ .px = 61 }, .flex = 1, .min_width = 0, .flex_shrink = 0, .background = if (selected) theme.current().selection else theme.current().well, .corner_radius = 8, .border_width = 0, .padding = .{} };
}
pub fn routeHop() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 51 }, .direction = .row, .align_items = .center, .padding = .{ .left = 10, .right = 10, .top = 8, .bottom = 8 }, .gap = 8, .background = ui.Color.TRANSPARENT, .border_bottom_width = 1, .border_bottom_color = theme.current().border, .flex_shrink = 0 };
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
    var style = text(11, 400, false);
    style.line_height = 1.5;
    return style;
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
    var style = text(12, 400, false);
    style.line_height = 1.5;
    style.color = theme.current().fg_1;
    return style;
}

// Compact discard confirmation: one consequence and two adjacent actions.
pub const discard_width: f32 = 440;
pub const discard_height: f32 = 192;
pub fn discardCard() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .padding = .{ .top = 10, .bottom = 12 }, .background = ui.Color.TRANSPARENT, .min_width = 0 };
}
pub fn discardFooter() ui.BoxStyle {
    var value = row(62);
    value.padding = .{ .left = 20, .right = 20, .top = 14, .bottom = 14 };
    value.justify = .end;
    value.gap = 8;
    return value;
}
pub fn discardText(_: bool) ui.TextStyle {
    return .{ .font_size = 12, .font_weight = 400, .line_height = 1.5, .color = theme.current().fg_2, .wrap = .word };
}

pub fn topFade(_: *const ui.ThemeTokens) ui.BoxStyle {
    const c = theme.current();
    return .{ .width = .fill(), .height = .{ .px = 72 }, .position = .absolute, .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } }, .gradient = .{ .from = c.well_border.withAlpha(48), .to = c.overlay.withAlpha(0) }, .border = .{ .radius = 14 }, .hit_behavior = .pass_through };
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
// Radios communicate selection through their circle; the theme's transparent
// focus token otherwise opts the entire option into a filled focus surface.
pub fn radioFocus() ui.FocusRingConfig {
    return .{ .color = theme.current().accent, .width = 0, .offset = 0 };
}

pub fn fieldRow() ui.BoxStyle {
    var value = row(52);
    value.height = .{ .fit = .{} };
    value.align_items = .start;
    value.gap = 16;
    return value;
}
pub fn errorLabel() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 16 }, .min_width = 0, .flex_shrink = 0 };
}

// Frozen V3 connection review: identity header, two-column values and plain route.
pub fn reviewStack(_: *const ui.ThemeTokens) ui.BoxStyle {
    var value = stack(undefined);
    value.gap = 16;
    value.padding = .{ .left = 4, .right = 4 };
    return value;
}
pub fn reviewIdentity() ui.BoxStyle {
    var value = row(66);
    value.gap = 12;
    value.padding = ui.Padding.all(14);
    value.background = theme.current().well;
    value.border = .{ .radius = 10 };
    return value;
}
pub fn reviewFields(_: *const ui.ThemeTokens) ui.BoxStyle {
    var value = stack(undefined);
    value.gap = 12;
    value.padding = .{ .left = 2, .right = 2 };
    return value;
}
pub fn reviewFieldRow() ui.BoxStyle {
    var value = row(39);
    value.gap = 18;
    value.align_items = .start;
    return value;
}
pub fn reviewField() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 39 }, .min_width = 0, .flex = 1, .direction = .column, .gap = 4, .flex_shrink = 0 };
}
pub fn reviewRoute() ui.BoxStyle {
    var value = stack(undefined);
    value.gap = 10;
    value.padding = ui.Padding.all(14);
    value.background = theme.current().well;
    value.border = .{ .radius = 10 };
    return value;
}

// Frozen V3 details: plain disclosure, 18px preceding margin and 12px body gap.
pub fn advancedSection(_: *const ui.ThemeTokens) ui.BoxStyle {
    var value = stack(undefined);
    value.gap = 12;
    value.margin = .{ .top = 4 };
    return value;
}

pub fn disclosureHover() ButtonStyle {
    return .{ .background = ui.Color.TRANSPARENT };
}

pub fn copyHeader() ui.BoxStyle {
    var value = header();
    value.height = .{ .px = 52 };
    value.padding = .{ .left = 20, .right = 20, .top = 14, .bottom = 14 };
    return value;
}
pub fn copyFooter() ui.BoxStyle {
    var value = footer();
    value.height = .{ .px = 62 };
    value.padding = .{ .left = 24, .right = 24, .top = 14, .bottom = 14 };
    return value;
}

pub fn commandField(_: *const ui.ThemeTokens) ui.BoxStyle {
    var value = stack(undefined);
    value.gap = 5;
    return value;
}

// Frozen HTML connectionTest: compact header and per-hop stage list. Rich
// diagnostics stay in the existing disclosure beneath this summary.
pub fn testResult(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .padding = ui.Padding.all(14), .gap = 0, .background = theme.current().well, .border = .{ .radius = 10 }, .flex_shrink = 0 };
}
pub fn testStage() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 54.6 }, .direction = .row, .align_items = .start, .padding = .{ .top = 8, .bottom = 8 }, .gap = 10, .flex_shrink = 0 };
}
pub fn testStageTitle() ui.TextStyle {
    var value = text(11, 500, false);
    value.line_height = 1.5;
    return value;
}
pub fn testStageDetail() ui.TextStyle {
    var value = text(11, 400, false);
    value.line_height = 1.6;
    return value;
}
