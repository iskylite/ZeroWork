//! Local Figma Bridge: 339:1019169, 235:370377, 235:371322,
//! 299:587764, 235:378249, 319:702700, 321:890421,
//! SFTP 342:1210942 / 342:1207116 / 319:704376.
const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub const width: f32 = 760;
pub const max_height: f32 = 710;
pub const ButtonStyle = @FieldType(ui.widgets.ControlShellConfig, "style");
pub const chrome_height: f32 = 168;

pub fn compactWindow(window_width: f32, window_height: f32) bool {
    return window_width <= 860 or window_height <= 480;
}

pub fn availableModalWidth(window_width: f32) f32 {
    return @max(1, window_width - 32);
}

pub fn availableModalHeight(window_height: f32, compact: bool) f32 {
    return @max(1, window_height - @as(f32, if (compact) 48 else 32));
}

pub fn panel(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = width }, .height = .{ .px = max_height }, .max_height = max_height, .padding = .{}, .gap = 0, .direction = .column, .background = theme.current().overlay, .glass = theme.overlayGlass(), .border = .{ .radius = 14 }, .overflow_hidden = true, .flex_shrink = 0 };
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
pub fn identityPanelColor() ui.Color {
    const colors = theme.current();
    return ui.Color.lerp(colors.overlay, colors.app.withAlpha(colors.overlay.a), 0.45);
}
pub fn identitySection(tokens: *const ui.ThemeTokens) ui.BoxStyle {
    var style = identityPanel(tokens);
    style.width = .fill();
    style.min_width = 0;
    style.min_height = 238;
    style.flex = 1;
    style.gap = 8;
    return style;
}
pub fn identityPanel(tokens: *const ui.ThemeTokens) ui.BoxStyle {
    var style = stack(tokens);
    style.padding = .{ .left = 16, .right = 16, .top = 12, .bottom = 16 };
    style.background = identityPanelColor();
    style.border = .{ .radius = 10 };
    return style;
}
pub fn identityFields(tokens: *const ui.ThemeTokens) ui.BoxStyle {
    var style = stack(tokens);
    style.gap = 4.5;
    return style;
}
pub fn card(_: *const ui.ThemeTokens) ui.BoxStyle {
    var style = stack(undefined);
    style.padding = ui.Padding.all(12);
    style.background = theme.popupAction();
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
    style.background = theme.popupAction();
    return style;
}
pub fn saveError() ui.BoxStyle {
    return .{
        .width = .fill(),
        .height = .{ .fit = .{} },
        .min_height = 52,
        .direction = .row,
        .align_items = .center,
        .flex_shrink = 0,
        .gap = 10,
        .margin = .{ .left = 24, .right = 24, .bottom = 8 },
        .padding = .{ .left = 16, .right = 16, .top = 8, .bottom = 8 },
        .background = saveErrorBackground(),
        .border = .{ .radius = 8 },
    };
}
pub fn saveErrorBackground() ui.Color {
    const colors = theme.current();
    const surface = theme.states().feedback_danger;
    return ui.Color.lerp(surface, colors.action_danger.withAlpha(surface.a), 0.22);
}
pub fn scroll() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0 };
}
pub fn field(w: ?f32) ui.BoxStyle {
    return .{ .width = if (w) |v| .{ .px = v } else .fill(), .height = .{ .px = 55.5 }, .direction = .column, .gap = 5, .min_width = 0, .flex_shrink = 1 };
}
// zenit draws borders inside the box; include the CSS 1px border in content insets.
pub fn input() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 34 }, .padding = .{ .left = 11, .right = 11, .top = 6, .bottom = 6 }, .background = theme.popupInset(), .border = .{ .radius = 8, .width = 0, .color = ui.Color.TRANSPARENT }, .font_size = 11 };
}
pub fn groupControl() ui.BoxStyle {
    var style = input();
    style.background = theme.current().overlay;
    style.padding = .{};
    style.direction = .row;
    style.gap = 0;
    style.min_width = 0;
    return style;
}
pub fn groupInput() ui.BoxStyle {
    var style = input();
    style.background = ui.Color.TRANSPARENT;
    style.border.?.radius = 0;
    return style;
}
pub fn groupPicker() ui.BoxStyle {
    var style = groupInput();
    style.width = .{ .px = 32 };
    style.padding = .{};
    style.align_items = .center;
    style.justify = .center;
    style.flex_shrink = 0;
    return style;
}
pub fn button(w: f32, h: f32, primary: bool) ui.BoxStyle {
    return .{ .width = .{ .px = w }, .height = .{ .px = h }, .padding = .{}, .direction = .row, .align_items = .center, .justify = .center, .gap = 6, .background = if (primary) theme.current().action_accent else theme.popupInset(), .gradient = if (primary) .{ .from = theme.current().action_accent, .to = theme.current().action_accent_2, .direction = .diagonal } else null, .border = .{ .radius = 8 }, .flex_shrink = 0 };
}
pub fn disclosure() ui.BoxStyle {
    var style = row(18);
    style.padding = .{};
    style.justify = .start;
    style.gap = 0;
    style.background = ui.Color.TRANSPARENT;
    return style;
}
pub fn advancedToggle() ui.BoxStyle {
    var style = disclosure();
    style.height = .{ .px = 30 };
    return style;
}
pub fn step(_: bool) ui.BoxStyle {
    return .{ .width = .{ .fit = .{} }, .flex = 0, .min_width = 0, .height = .{ .px = 36 }, .padding = .{}, .direction = .row, .align_items = .center, .justify = .start, .gap = 10, .background = ui.Color.TRANSPARENT, .border = .{ .radius = 7 }, .flex_shrink = 0 };
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
pub fn number(selected: bool) ui.BoxStyle {
    return .{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .align_items = .center, .justify = .center, .background = if (selected) theme.current().action_accent else theme.popupInset(), .border = .{ .radius = 11 }, .flex_shrink = 0 };
}
pub fn accessChoice(selected: bool) ButtonStyle {
    return .{ .width = .fill(), .height = .{ .px = 61 }, .flex = 1, .min_width = 0, .flex_shrink = 0, .background = if (selected) theme.popupSelection() else theme.popupInset(), .corner_radius = 8, .border_width = 0, .padding = .{} };
}
pub fn routeEndpointFill() ui.Color {
    return theme.current().fg_2.withAlpha(14);
}
pub fn routeHop() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 51 }, .direction = .row, .align_items = .center, .padding = .{ .left = 10, .right = 10, .top = 8, .bottom = 8 }, .gap = 8, .background = ui.Color.TRANSPARENT, .border_bottom_width = 0, .border_bottom_color = ui.Color.TRANSPARENT, .flex_shrink = 0 };
}
pub fn routeNode(_: bool) ui.BoxStyle {
    return .{ .width = .{ .px = 146 }, .height = .{ .px = 76 }, .padding = ui.Padding.all(10), .direction = .column, .gap = 2, .background = theme.popupInset(), .border = .{ .radius = 9 }, .flex_shrink = 0 };
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
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 4, .background = theme.popupInset(), .border = .{ .radius = 9, .width = 0 }, .flex_shrink = 0 };
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
    style.color = theme.current().fg_2;
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
    return .{ .width = .{ .fit = .{} }, .height = .{ .px = 18 }, .flex_shrink = 0 };
}

pub fn readonlyValue(_: *const ui.ThemeTokens) ui.TextStyle {
    var style = text(12, 400, false);
    style.line_height = 1.5;
    style.color = theme.current().fg_1;
    return style;
}

pub fn topFade(_: *const ui.ThemeTokens) ui.BoxStyle {
    const c = theme.current();
    return .{ .width = .fill(), .height = .{ .px = 72 }, .position = .absolute, .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } }, .gradient = .{ .from = c.well_border.withAlpha(48), .to = c.overlay.withAlpha(0) }, .border = .{ .radius = 14 }, .hit_behavior = .pass_through };
}
pub fn grip(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .top = .{ .px = 7 }, .left = .{ .percent = 50 } }, .width = .{ .px = 32 }, .height = .{ .px = 3 }, .margin = .{ .left = -16 }, .background = theme.current().fg_2, .border = .{ .radius = 1.5 }, .hit_behavior = .pass_through };
}

pub fn summaryName() ui.TextStyle {
    var value = text(22, 650, false);
    value.line_height = 26.0 / 22.0;
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
// Keep keyboard focus visible without the theme's filled focus surface.
// A zero-width outline reaches the renderer as a filled rectangle.
pub fn radioFocus() ui.FocusRingConfig {
    return .{ .color = theme.current().accent, .width = 1, .offset = 2 };
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

pub const remote_max_height: f32 = 596;
pub const review_height: f32 = 492;
pub const review_compact_height: f32 = 432;

pub fn reviewRouteRowHeight(compact: bool) f32 {
    return if (compact) 32 else 40;
}

pub fn reviewStepTrack(compact: bool) ui.BoxStyle {
    var style = row(36);
    style.padding = ui.Padding.all(3);
    style.margin = .{ .top = if (compact) 4 else 8 };
    style.gap = 0;
    style.background = theme.popupInset();
    style.border = .{ .radius = 9 };
    return style;
}

pub fn reviewStep(current: bool) ui.BoxStyle {
    var style = step(current);
    style.width = .fill();
    style.height = .{ .px = 30 };
    style.flex = 1;
    style.justify = .center;
    style.gap = 8;
    style.background = if (current) theme.popupSelection() else ui.Color.TRANSPARENT;
    return style;
}

pub fn remoteStepNumber(current: bool) ui.BoxStyle {
    var style = number(current);
    style.width = .{ .px = 18 };
    style.height = .{ .px = 18 };
    style.border = .{ .radius = 9 };
    if (!current) style.background = theme.popupAction();
    return style;
}

pub fn reviewStack(_: *const ui.ThemeTokens) ui.BoxStyle {
    var value = stack(undefined);
    value.gap = 16;
    return value;
}
pub fn reviewIdentity() ui.BoxStyle {
    var value = row(78);
    value.gap = 14;
    value.padding = .{ .left = 16, .right = 16 };
    value.background = theme.popupSelection();
    value.border = .{ .radius = 10 };
    return value;
}
pub fn reviewColumns() ui.BoxStyle {
    var value = stack(undefined);
    value.direction = .row;
    value.gap = 16;
    return value;
}
pub fn reviewRoute() ui.BoxStyle {
    var value = stack(undefined);
    value.height = .{ .px = 178 };
    value.min_width = 0;
    value.flex = 1;
    value.gap = 4;
    value.padding = .{ .left = 16, .right = 16, .top = 12 };
    value.background = theme.popupInset();
    value.border = .{ .radius = 10 };
    return value;
}

pub fn reviewIconTile(size: f32, highlighted: bool) ui.BoxStyle {
    var value = iconBox(size);
    value.justify = .center;
    value.align_items = .center;
    value.background = if (highlighted) theme.popupSelection() else theme.popupAction();
    value.border = .{ .radius = if (size == 44) 9 else 6 };
    return value;
}

pub fn advancedSection(_: *const ui.ThemeTokens) ui.BoxStyle {
    var style = stack(undefined);
    style.gap = 0;
    return style;
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
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .padding = .{ .left = 16, .right = 16 }, .gap = 0, .background = theme.popupInset(), .border = .{ .radius = 8 }, .flex_shrink = 0 };
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
