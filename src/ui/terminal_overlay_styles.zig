//! Figma Bridge command catalogs 415:1888221 / 415:1888404 / 415:1888584
//! and local history popup 415:1882838 share the global overlay, text and
//! selection roles. Catalogue geometry follows the exact native Figma nodes.
const ui = @import("ui");
const theme = @import("app_theme.zig");
const completion = @import("completion.zig");

pub const catalogue_width: f32 = 430;
pub const catalogue_padding: f32 = 12;
pub const catalogue_gap: f32 = 6;
pub const catalogue_header_height: f32 = 24;
pub const catalogue_viewport_height: f32 = 200;
pub const catalogue_footer_height: f32 = 16;
pub const catalogue_row_height: f32 = 30;
pub const catalogue_row_gap: f32 = 4;
pub const catalogue_row_pitch: f32 = catalogue_row_height + catalogue_row_gap;
pub const catalogue_chrome_height: f32 = 2 * catalogue_padding + 2 * catalogue_gap + catalogue_header_height + catalogue_footer_height;

pub fn cataloguePanel() ui.BoxStyle {
    const c = theme.current();
    return .{ .position = .absolute, .width = .{ .px = catalogue_width }, .direction = .column, .gap = catalogue_gap, .padding = ui.Padding.all(catalogue_padding), .background = c.overlay, .glass = theme.overlayGlass(), .border = .{ .width = 0, .color = ui.Color.TRANSPARENT, .radius = 14 }, .shadow = .{ .color = c.shadow, .blur = 28, .offset_y = 10 }, .overflow_hidden = true, .min_width = 0, .min_height = 0, .z_index = 30, .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } } };
}
pub fn catalogueHeader() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = catalogue_header_height }, .direction = .row, .align_items = .center, .gap = catalogue_gap, .flex_shrink = 0, .min_width = 0 };
}
pub fn catalogueFooter() ui.BoxStyle {
    var value = catalogueHeader();
    value.height = .{ .px = catalogue_footer_height };
    value.gap = 0;
    return value;
}
pub fn catalogueTitle() ui.TextStyle {
    return .{ .font_size = 12, .font_weight = 500, .line_height = 1.5, .color = theme.current().fg_1, .selectable = false, .text_overflow = .ellipsis };
}
pub fn catalogueHint() ui.TextStyle {
    return .{ .font_size = 10, .font_weight = 400, .line_height = 1.6, .color = theme.current().fg_2, .selectable = false, .text_overflow = .ellipsis };
}
// A complete short count may paint into the footer's spare space. It must
// not enter the single-line ellipsis path on fractional glyph-width rounding.
pub fn catalogueCount() ui.TextStyle {
    var value = catalogueHint();
    value.text_overflow = .clip;
    return value;
}
pub fn catalogueRows() ui.BoxStyle {
    return .{ .width = .fill(), .direction = .column, .gap = catalogue_row_gap, .padding = .{ .right = 6 }, .min_width = 0, .flex_shrink = 0 };
}
pub fn catalogueRow(selected: bool) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = catalogue_row_height }, .direction = .row, .align_items = .center, .gap = catalogue_gap, .padding = ui.Padding.ZERO, .background = rowBackground(selected), .flex_shrink = 0, .min_width = 0 };
}
pub fn catalogueIcon() ui.Style {
    return .{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .flex_shrink = 0 };
}
pub fn catalogueName() ui.TextStyle {
    return .{ .font_size = 10.5, .font_weight = 400, .line_height = 18.0 / 10.5, .color = theme.current().accent_ink, .use_monospace_font = true, .selectable = false, .text_overflow = .ellipsis };
}
pub fn catalogueDescription() ui.TextStyle {
    var value = catalogueName();
    value.use_monospace_font = false;
    value.color = theme.current().fg_1;
    return value;
}

pub fn panelPaint() ui.BoxStyle {
    const c = theme.current();
    return .{ .background = c.overlay, .glass = theme.overlayGlass(), .border_color = c.border, .shadow = .{ .color = c.shadow, .blur = 28, .offset_x = 0, .offset_y = 10 } };
}

pub fn rowBackground(selected: bool) ui.Color {
    return if (selected) theme.popupSelection() else ui.Color.TRANSPARENT;
}

pub fn badgeForeground(source: completion.Source) ui.Color {
    const c = theme.current();
    return switch (source) {
        .history => c.ok_ink,
        .path => c.accent_ink,
        .builtin => c.fg_2,
    };
}

pub fn badgeBackground(source: completion.Source) ui.Color {
    const c = theme.current();
    return switch (source) {
        .history => c.ok.withAlpha(26),
        .path => c.accent.withAlpha(26),
        .builtin => c.surface_2,
    };
}

pub fn timestampText(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .line_height = 2, .color = theme.current().fg_2, .use_monospace_font = true, .wrap = .none };
}
