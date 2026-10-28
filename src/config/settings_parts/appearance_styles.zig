//! Live Bridge readback: session-mvdcsln0-2cvyti / page214:329905.
//! Theme340:1023115; font236:528529; image355:1291651 current540:*.
const ui = @import("ui");
pub const base = @import("../settings_styles.zig");
pub const theme = base.theme;
pub const ButtonStyle = base.ButtonStyle;
pub const g = struct {
    pub const gap: f32 = 6;
    pub const card_padding: f32 = 10;
    pub const card_radius: f32 = 9;
    pub const row: f32 = 52;
    pub const control: f32 = 32;
    pub const control_width: f32 = 220;
    pub const icon: f32 = 16;
    pub const tile_height: f32 = 56;
    pub const thumbnail_width: f32 = 40;
    pub const thumbnail_height: f32 = 28;
    pub const material_row: f32 = 32;
    pub const material_label: f32 = 140;
    pub const material_number: f32 = 100;
};
pub fn column(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = g.gap, .flex_shrink = 0, .min_width = 0 };
}
pub const card = base.section;
pub const header = base.sectionHeader;
pub const label = base.label;
pub const value = base.value;
pub const note = base.note;
pub const errorNote = base.errorNote;
pub fn pageTitle(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 13, .font_weight = 600, .line_height = 20.0 / 13.0, .color = theme.current().fg_1 };
}
pub fn row(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .min_height = g.row, .padding = .{ .top = 8, .bottom = 8 }, .direction = .row, .align_items = .center, .gap = 20, .flex_shrink = 0, .min_width = 0 };
}
pub fn labelGroup(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .flex = 1, .min_width = 0, .direction = .column, .gap = 3, .align_items = .start };
}
pub fn control(width: f32, height: f32) ButtonStyle {
    const c = theme.current();
    return .{ .width = .{ .px = width }, .height = .{ .px = height }, .background = c.well, .text_color = c.fg_1, .font_size = 11.5, .font_weight = 400, .padding = .{ .left = 10, .right = 8 }, .corner_radius = 8, .border_width = 0, .flex_shrink = 0 };
}
pub fn field(width: f32, height: f32) ui.BoxStyle {
    const c = theme.current();
    return .{ .width = .{ .px = width }, .height = .{ .px = height }, .min_width = 0, .background = c.well, .padding = .{ .left = 10, .right = 8 }, .border = .{ .width = 0, .radius = 8 }, .flex_shrink = 0 };
}
pub fn plainButton(width: f32, height: f32, selected: bool) ButtonStyle {
    const c = theme.current();
    return .{ .width = .{ .px = width }, .height = .{ .px = height }, .padding = .ZERO, .background = if (selected) theme.popupSelection() else ui.Color.TRANSPARENT, .text_color = if (selected) c.accent_ink else c.fg_2, .corner_radius = 7, .border_width = 0, .font_size = 10.5, .font_weight = 400 };
}
pub fn menu(width: f32, padding: f32, gap: f32) ui.BoxStyle {
    const c = theme.current();
    return .{ .width = .{ .px = width }, .height = .{ .fit = .{} }, .direction = .column, .gap = gap, .padding = .{ .left = padding, .right = padding, .top = padding, .bottom = padding }, .background = c.overlay, .border = .{ .width = 0, .radius = 14 }, .shadow = .{ .blur = 28, .offset_y = 10, .color = c.shadow } };
}
pub fn menuRow(height: f32, selected: bool) ButtonStyle {
    var s = plainButton(200, height, selected);
    s.width = .fill();
    s.padding = .{ .left = 8, .right = 8 };
    s.font_size = 12;
    s.text_color = theme.current().fg_1;
    s.direction = .row;
    s.justify = .start;
    s.align_items = .center;
    s.gap = 6;
    return s;
}
pub fn notice(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 28 }, .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0 };
}
pub const tuneInput = base.tuneInput;
pub fn thumbnail(background: ui.Color) ui.BoxStyle {
    return .{ .width = .{ .px = g.thumbnail_width }, .height = .{ .px = g.thumbnail_height }, .direction = .row, .align_items = .center, .gap = 3, .padding = .{ .left = 6 }, .background = background, .border = .{ .radius = 5 }, .flex_shrink = 0 };
}
pub fn dismissedTheme(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 44 }, .direction = .row, .align_items = .center, .gap = 8, .padding = .{ .left = 8, .right = 8 }, .background = theme.current().surface_2, .border = .{ .radius = 7 }, .flex_shrink = 0 };
}
pub fn previewBadge(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = 88 }, .height = .{ .px = 22 }, .direction = .row, .align_items = .center, .justify = .center, .background = theme.popupSelection(), .border = .{ .radius = 6 }, .flex_shrink = 0 };
}
pub fn tile(width: f32, selected: bool) ButtonStyle {
    var s = plainButton(width, g.tile_height, selected);
    s.background = if (selected) theme.popupSelection() else theme.current().well;
    s.corner_radius = 8;
    s.direction = .row;
    s.align_items = .center;
    s.justify = .start;
    s.padding = .{ .left = 8, .right = 30 };
    s.gap = 8;
    return s;
}
pub fn tileTitle(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10.5, .font_weight = 500, .line_height = 15.0 / 10.5, .color = theme.current().fg_1, .text_overflow = .ellipsis };
}
pub fn tileIdentity(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 9.5, .line_height = 14.0 / 9.5, .color = theme.current().fg_2, .text_overflow = .ellipsis };
}
pub fn toggle(enabled: bool) ButtonStyle {
    return .{ .width = .{ .px = 30 }, .height = .{ .px = 18 }, .direction = .row, .align_items = .center, .justify = if (enabled) .end else .start, .padding = .{ .left = 2, .right = 2 }, .background = if (enabled) theme.current().action_accent else theme.switchTrackOff(), .corner_radius = 9, .border_width = 0, .gap = 0 };
}
pub fn toggleKnob(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .background = ui.Color.WHITE, .border = .{ .radius = 7 }, .flex_shrink = 0 };
}
pub fn materialRow(_: *const ui.ThemeTokens) ui.BoxStyle {
    var s = row(undefined);
    s.height = .{ .px = 32 };
    s.min_height = 32;
    s.padding = .ZERO;
    s.gap = 6;
    return s;
}
pub fn previewBar(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 48 }, .direction = .row, .align_items = .center, .padding = .{ .left = 12, .right = 12 }, .gap = 8, .background = theme.current().overlay, .border = .{ .radius = 14 }, .flex_shrink = 0 };
}
