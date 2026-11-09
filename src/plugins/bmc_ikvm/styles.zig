//! Native KVM content aligned to the approved Mist workspace geometry.
//! Product palette and materials follow the existing theme registry.
const ui = @import("ui");
pub const theme = @import("../../ui/app_theme.zig");
const shell = @import("../../ui/shell_styles.zig");
pub const toolbar_height: f32 = 44;
// Identity (108), five 64-point actions, six gaps and outer padding.
pub const expanded_toolbar_width: f32 = 480;
// Outer padding (22), monitor/status (58), five icons (160), six gaps (24).
pub const icon_toolbar_width: f32 = 264;
// Round the outer video surface only. Its 8-point black inset preserves every
// source pixel and all edge input targets in both fit and original modes.
pub const video_card_radius: f32 = 16;
pub const popup_width: f32 = 296;
pub const boot_width: f32 = 312;
pub const select_width: f32 = 180;
pub const popup_header_height: f32 = 55.5;
pub const display_header_height: f32 = 44;
pub const progress_width: f32 = 520;
pub const progress_height: f32 = 441;
pub const progress_header_height: f32 = 26;
pub const progress_padding: f32 = 20;
pub const progress_gap: f32 = 12;
pub const progress_action_height: f32 = 32;
pub const log_width: f32 = 760;

pub fn root(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .direction = .column, .gap = 0, .min_width = 0, .min_height = 0, .overflow_hidden = true };
}
pub fn workspaceRoot(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .min_width = 0, .min_height = 0, .direction = .column, .gap = 16, .padding = .{}, .background = ui.Color.TRANSPARENT };
}
pub fn toolbar(t: *const ui.ThemeTokens) ui.BoxStyle {
    var style = shell.floating(t);
    style.width = .fill();
    style.padding = .{ .left = 16, .right = 6, .top = 6, .bottom = 6 };
    style.min_width = 0;
    style.gap = 4;
    return style;
}
pub fn connectionIdentity(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .min_width = 0, .direction = .row, .align_items = .center, .gap = 8 };
}
pub fn connectionTitle(tokens: *const ui.ThemeTokens) ui.TextStyle {
    var style = title(tokens);
    style.text_overflow = .ellipsis;
    return style;
}
pub fn disconnect() ui.BoxStyle {
    var style = tool();
    style.width = .{ .px = 82 };
    style.opacity = 1;
    return style;
}
pub fn tool() ui.BoxStyle {
    return .{ .width = .{ .px = 64 }, .height = .{ .px = 32 }, .min_height = 32, .padding = .{ .left = 8, .right = 8 }, .gap = 4, .border = .{ .width = 0, .radius = 8 }, .font_size = 12, .font_weight = 500, .text_color = theme.current().fg_1, .background = ui.Color.TRANSPARENT, .flex_shrink = 0 };
}
pub fn iconTool() ui.BoxStyle {
    var style = tool();
    style.width = .{ .px = 32 };
    style.padding = ui.Padding.ZERO;
    style.border = .{ .width = 0, .radius = 16 };
    return style;
}
pub fn moreRow() ui.BoxStyle {
    var style = tool();
    style.width = .fill();
    style.height = .{ .px = 40 };
    style.padding = .{ .left = 12, .right = 30 };
    style.gap = 12;
    style.justify = .start;
    return style;
}
pub fn toolHover() ui.BoxStyle {
    return .{ .background = theme.states().hover };
}
pub fn videoWorkspace(_: *const ui.ThemeTokens) ui.BoxStyle {
    // workspaceRoot owns the 16-point gap below the floating toolbar.
    return .{ .width = .fill(), .height = .fill(), .min_width = 0, .min_height = 0, .padding = .{}, .gap = 0 };
}
pub fn videoCard(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .min_width = 0, .min_height = 0, .padding = ui.Padding.all(8), .gap = 0, .background = ui.Color.BLACK, .border = .{ .width = 0, .radius = video_card_radius }, .overflow_hidden = true, .clip_shape = .{ .rounded_rect = video_card_radius } };
}
pub fn video() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .min_width = 0, .min_height = 0, .background = ui.Color.BLACK, .padding = ui.Padding.ZERO, .gap = 0, .border = .{ .width = 0, .radius = 0 }, .overflow_hidden = true, .clip_shape = .{ .rounded_rect = 0 }, .hit_behavior = .@"opaque" };
}
pub fn image() ui.Style {
    return .{ .position = .absolute, .width = .{ .px = 1 }, .height = .{ .px = 1 }, .flex_shrink = 0, .border = .{ .width = 0, .radius = 0 } };
}
pub fn popup() ui.BoxStyle {
    return .{ .direction = .column, .gap = 0, .padding = ui.Padding.ZERO, .min_width = 0, .background = theme.current().overlay, .glass = theme.overlayGlass(), .border = .{ .width = 0, .radius = 12 }, .shadow = .{ .offset_y = 20, .blur = 50, .color = theme.current().shadow }, .hit_behavior = .@"opaque" };
}
// Same nested menu material as the shared SSH surfaces. bg_primary is an
// inline workspace material and must not back a Select above another popup.
pub fn selectDropdown() ui.BoxStyle {
    return .{ .direction = .column, .gap = 0, .padding = ui.Padding.all(5), .background = theme.layerBackground(2), .glass = theme.overlayGlass(), .border = .{ .width = 0, .radius = 10 }, .corner_radius = 10, .hit_shape = .{ .rounded_rect = 10 }, .clip_shape = .{ .rounded_rect = 10 }, .hit_behavior = .@"opaque", .shadow = .{ .offset_y = 12, .blur = 24, .color = theme.current().shadow } };
}
pub fn selectOption() ui.BoxStyle {
    return .{ .height = .{ .px = 32 }, .min_height = 32, .padding = .{ .top = 7, .bottom = 7, .left = 9, .right = 9 }, .border = .{ .width = 0, .radius = 7 }, .corner_radius = 7, .flex_shrink = 0 };
}
pub fn popupBody(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 12, .padding = ui.Padding.all(12), .min_width = 0, .flex_shrink = 0 };
}
pub fn popupHead(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = popup_header_height }, .direction = .row, .align_items = .center, .gap = 8, .padding = ui.Padding.all(12), .flex_shrink = 0, .min_width = 0 };
}
pub fn title(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 13, .font_weight = 700, .line_height = 1.5, .color = theme.current().fg_1, .selectable = false };
}
pub fn body(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 12, .font_weight = 400, .line_height = 1.5, .color = theme.current().fg_1, .selectable = false };
}
pub fn confirmationDetail(tokens: *const ui.ThemeTokens) ui.TextStyle {
    var style = body(tokens);
    style.wrap = .word;
    return style;
}
pub fn value(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .font_weight = 700, .line_height = 1.5, .color = theme.current().fg_1, .selectable = false, .text_overflow = .ellipsis };
}
pub fn hint(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .font_weight = 400, .line_height = 1.5, .color = theme.current().fg_2, .wrap = .word, .selectable = false };
}
pub fn well(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .direction = .row, .align_items = .center, .justify = .space_between, .padding = .{ .top = 9, .bottom = 9, .left = 10, .right = 10 }, .gap = 8, .background = theme.current().well, .border = .{ .radius = 8 }, .min_width = 0, .flex_shrink = 0 };
}
pub fn field(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 32 }, .direction = .row, .align_items = .center, .justify = .space_between, .gap = 8, .min_width = 0, .flex_shrink = 0 };
}
pub fn actions(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .direction = .row, .justify = .end, .align_items = .center, .gap = 8, .flex_shrink = 0 };
}
pub fn action() ui.BoxStyle {
    return .{ .width = .{ .fit = .{ .min = 78 } }, .height = .{ .px = 30 }, .min_height = 30, .padding = .{ .left = 12, .right = 12, .top = 3, .bottom = 3 }, .border = .{ .radius = 7 }, .font_size = 12 };
}
pub fn close() ui.BoxStyle {
    return .{ .width = .{ .px = 27.9140625 }, .height = .{ .px = 31.5 }, .padding = ui.Padding.ZERO, .border = .{ .radius = 7 }, .background = ui.Color.TRANSPARENT };
}
pub fn keyRow(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .direction = .row, .gap = 6, .flex_shrink = 0 };
}
pub fn keyButton() ui.BoxStyle {
    return .{ .height = .{ .px = 32 }, .min_height = 32, .width = .fill(), .min_width = 0, .padding = ui.Padding.all(8), .font_size = 11, .background = theme.current().well, .border = .{ .width = 0, .radius = 7 } };
}
pub fn waiting(_: *const ui.ThemeTokens) ui.BoxStyle {
    return progressCard();
}
pub fn waitingTitle(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 18, .font_weight = 500, .line_height = 1.4, .color = ui.arb.hex(0xf4f4f5), .text_align = .center, .wrap = .word };
}
pub fn waitingHint(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 12, .line_height = 1.5, .color = ui.arb.hex(0xa4a4ad), .text_align = .center, .wrap = .word };
}
/// Connection progress: 520px card, 20px
/// padding, 12px gap; the header and actions stay outside its body scroller.
pub fn progressCard() ui.BoxStyle {
    const appearance = theme.currentName();
    // Keep the outer shadow on the layout owner so the renderer can paint it
    // beyond the card bounds.
    return .{ .position = .absolute, .width = .{ .px = progress_width }, .height = .{ .px = progress_height }, .max_width = progress_width, .direction = .column, .align_items = .stretch, .gap = 0, .padding = ui.Padding.ZERO, .min_width = 0, .min_height = 0, .background = ui.Color.TRANSPARENT, .border = .{ .width = 0, .radius = 12 }, .shadow = .{ .offset_y = 16, .blur = 48, .color = ui.Color.BLACK.withAlpha(switch (appearance) {
        .dark => 71,
        .light => 36,
        .sauber => 41,
    }) }, .overflow_hidden = true, .hit_behavior = .@"opaque", .flex_shrink = 0 };
}
pub fn progressSurface(_: *const ui.ThemeTokens) ui.BoxStyle {
    // This card can cover arbitrary video pixels, so its text needs a stable
    // theme surface independent of the global wallpaper transparency.
    return .{ .width = .fill(), .height = .fill(), .direction = .column, .align_items = .stretch, .gap = progress_gap, .padding = ui.Padding.all(progress_padding), .min_width = 0, .min_height = 0, .background = theme.current().overlay.withAlpha(255), .border = .{ .width = 0, .radius = 12 } };
}
pub fn progressSecondary() ui.Color {
    return theme.current().fg_2;
}
pub fn progressCurrentFill() ui.Color {
    return theme.current().accent_ink.withAlpha(if (theme.currentName() == .dark) 26 else 20);
}
pub fn progressHeader(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = progress_header_height }, .direction = .column, .gap = 6, .min_width = 0, .flex_shrink = 0 };
}
pub fn progressTitle(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 18, .font_weight = 500, .line_height = 26.0 / 18.0, .color = theme.current().fg_1, .selectable = false, .text_overflow = .ellipsis };
}
pub fn progressTiming(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .line_height = 1.5, .color = progressSecondary(), .use_monospace_font = true, .text_align = .end, .selectable = false };
}
pub fn progressTimingLabel(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .line_height = 1.5, .color = progressSecondary(), .selectable = false };
}
pub fn progressDetail(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 12, .line_height = 1.5, .color = progressSecondary(), .wrap = .word, .selectable = false };
}
pub fn progressNotice(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .line_height = 18.0 / 11.0, .color = progressSecondary(), .selectable = false, .text_overflow = .ellipsis };
}
pub fn progressSteps(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 8, .min_width = 0, .flex_shrink = 0 };
}
pub fn progressStep(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .min_height = 34, .direction = .row, .align_items = .center, .justify = .start, .gap = 8, .padding = .{ .top = 8, .bottom = 8, .left = 10, .right = 10 }, .min_width = 0, .flex_shrink = 0, .background = ui.Color.TRANSPARENT, .border = .{ .width = 0, .radius = 8 } };
}
pub fn progressStepBackdrop(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .min_height = 34, .direction = .row, .gap = 0, .padding = ui.Padding.ZERO, .min_width = 0, .flex_shrink = 0, .background = ui.Color.TRANSPARENT, .border = .{ .width = 0, .radius = 8 } };
}
pub fn progressDiagnostic(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .line_height = 1.7, .color = theme.current().fg_1, .wrap = .word, .selectable = false, .use_monospace_font = true };
}
pub fn progressText(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 12, .line_height = 1.5, .color = theme.current().fg_1, .wrap = .word, .selectable = false };
}
pub fn progressState(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .line_height = 18.0 / 11.0, .color = progressSecondary(), .text_align = .end, .selectable = false };
}
pub fn progressRoute(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .line_height = 1.7, .color = theme.current().fg_1, .wrap = .word, .use_monospace_font = true, .selectable = false };
}
pub fn progressRouteLabel(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .line_height = 1.5, .color = progressSecondary(), .selectable = false };
}
pub fn progressRouteBox(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 4, .padding = ui.Padding.all(10), .background = theme.current().well.withAlpha(255), .border = .{ .width = 0, .radius = 8 }, .min_width = 0, .flex_shrink = 0 };
}
pub fn progressActions(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .row, .justify = .end, .align_items = .center, .gap = 8, .min_width = 0, .flex_shrink = 0 };
}
pub fn progressAction() ui.BoxStyle {
    return .{ .width = .{ .px = 76 }, .height = .{ .px = progress_action_height }, .min_height = progress_action_height, .padding = .{ .left = 14, .right = 14, .top = 6, .bottom = 6 }, .font_size = 12, .font_weight = 500, .border = .{ .radius = 7 }, .flex_shrink = 0 };
}
pub fn logText(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .line_height = 1.7, .color = theme.current().fg_1, .wrap = .word, .selectable = false, .use_monospace_font = true };
}
pub fn logFooter(compact: bool) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .row, .justify = .end, .align_items = .center, .padding = if (compact) .{ .top = 10, .bottom = 10, .left = 18, .right = 18 } else .{ .top = 14, .bottom = 14, .left = 24, .right = 24 }, .background = theme.current().surface_2, .min_width = 0, .flex_shrink = 0 };
}
pub fn logClose() ui.BoxStyle {
    return .{ .width = .{ .fit = .{} }, .height = .{ .px = 34 }, .min_height = 34, .padding = .{ .left = 14, .right = 14, .top = 8, .bottom = 8 }, .font_size = 12, .font_weight = 500, .border = .{ .radius = 7 }, .flex_shrink = 0 };
}
pub fn inputHint(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .line_height = 1.5, .color = ui.arb.hex(0xf4f4f5), .wrap = .word, .selectable = false };
}
pub fn inputHintBox() ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .left = .{ .px = 14 }, .right = .{ .px = 14 }, .bottom = .{ .px = 12 } }, .padding = .{ .left = 9, .right = 9, .top = 5, .bottom = 5 }, .background = ui.arb.hexA(0, 0.65), .border = .{ .radius = 5 }, .hit_behavior = .pass_through, .z_index = 2 };
}
pub fn orderText(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .line_height = 2.0, .color = theme.current().fg_1, .wrap = .word, .selectable = false, .use_monospace_font = true };
}
pub fn orderRow() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .min_width = 0, .flex_shrink = 0 };
}
pub fn segment(selected: bool) ui.BoxStyle {
    return .{ .height = .{ .px = 28 }, .min_height = 28, .width = .fill(), .min_width = 0, .padding = .{}, .font_size = 13, .font_weight = 500, .text_color = if (selected) theme.current().accent_ink else theme.current().fg_1, .background = if (selected) theme.current().overlay else ui.Color.TRANSPARENT, .border = .{ .width = 0, .radius = 6 } };
}

// Display panel: 296-point panel, 16-point content inset.
pub fn displayBody(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 0, .padding = .{}, .min_width = 0, .flex_shrink = 0 };
}
pub fn displayHead(t: *const ui.ThemeTokens) ui.BoxStyle {
    var s = popupHead(t);
    s.height = .{ .px = display_header_height };
    s.padding = .{ .left = 16, .right = 12 };
    return s;
}
pub fn displayTitle(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 14, .font_weight = 600, .color = theme.current().fg_1, .selectable = false };
}
pub fn displayControls(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 8, .padding = .{ .top = 4, .left = 16, .right = 16, .bottom = 16 }, .min_width = 0, .flex_shrink = 0 };
}
pub fn displayScale(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 34 }, .direction = .row, .gap = 3, .padding = ui.Padding.all(3), .background = theme.current().well, .border = .{ .width = 0, .radius = 8 }, .min_width = 0, .flex_shrink = 0 };
}
pub fn displayAction() ui.BoxStyle {
    return .{ .height = .{ .px = 32 }, .min_height = 32, .padding = .{ .left = 10, .right = 10 }, .gap = 6, .font_size = 13, .font_weight = 500, .border = .{ .width = 0, .radius = 8 }, .flex_shrink = 0 };
}
pub fn displayPerformance(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 0, .padding = .{ .left = 16, .right = 16, .bottom = 14 }, .min_width = 0, .flex_shrink = 0 };
}
pub fn displayDivider(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 1 }, .background = theme.current().border, .flex_shrink = 0 };
}
pub fn displaySwitch(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 28 }, .direction = .row_reverse, .justify = .space_between, .align_items = .center, .margin = .{ .top = 12 }, .flex_shrink = 0 };
}
pub fn displayStats(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 4, .margin = .{ .top = 8 }, .min_width = 0, .flex_shrink = 0 };
}
pub fn displayStatRow(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 20 }, .direction = .row, .justify = .space_between, .align_items = .center, .gap = 12, .min_width = 0, .flex_shrink = 0 };
}
pub fn displayStatLabel(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 13, .line_height = 20.0 / 13.0, .color = theme.current().fg_2, .selectable = false };
}
pub fn displayStatValue(t: *const ui.ThemeTokens) ui.TextStyle {
    var s = displayStatLabel(t);
    s.color = theme.current().fg_1;
    s.text_align = .end;
    return s;
}
pub fn displayFooter(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .row, .gap = 8, .padding = .{ .top = 12, .left = 16, .right = 16, .bottom = 16 }, .min_width = 0, .flex_shrink = 0 };
}

// Video-local contrast is stable across shell themes; never intercept input.
pub fn fpsHud(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .top = .{ .px = 12 }, .right = .{ .px = 12 } }, .direction = .column, .gap = 2, .padding = .{ .top = 6, .bottom = 6, .left = 10, .right = 10 }, .background = ui.Color.rgba(18, 20, 24, 199), .border = .{ .radius = 7 }, .hit_behavior = .pass_through, .hit_roles = .{ .pointer = false, .scroll = false }, .flex_shrink = 0 };
}
pub fn fpsPrimary(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .line_height = 16.0 / 11.0, .font_weight = 500, .use_monospace_font = true, .color = ui.Color.hex(0xf3f4f6), .selectable = false };
}
pub fn fpsSecondary(t: *const ui.ThemeTokens) ui.TextStyle {
    var s = fpsPrimary(t);
    s.font_weight = 400;
    s.color = ui.Color.hex(0xc6cad1);
    return s;
}
