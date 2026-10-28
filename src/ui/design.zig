const ui = @import("ui");

pub const color = struct {
    pub const bg = ui.Color.hex(0xECFFE5);
    pub const chrome = ui.Color.hex(0xE3F6DE);
    pub const sidebar = ui.Color.hex(0xE6F9E0);
    pub const inactive_tab = ui.Color.hex(0xDBF0E6);
    pub const fg = ui.Color.hex(0x1345F6);
    pub const ink = ui.Color.hex(0x0F172A);
    pub const surface = ui.Color.hex(0xF6FFF3);
    pub const secondary = ui.Color.hex(0x616D6F);
    pub const muted = ui.Color.hex(0x64748B);
    pub const accent = ui.Color.hex(0x1345F6);
    pub const border = ui.Color.hex(0xCBDCC9);
    pub const success = ui.Color.hex(0x10B981);
    pub const danger = ui.Color.hex(0xDC4C3F);
    pub const warning = ui.Color.hex(0xD49A0C);
    pub const status = ui.Color.hex(0xE3F6DE);
};

// Widgets and hand-built chrome use the same Sauber colors, independent of
// the operating system's light/dark preference.
pub const sauber: ui.ThemeTokens = blk: {
    var tokens = ui.theme.light;
    tokens.name = "sauber";
    tokens.tokens.color.bg_base = color.bg;
    tokens.tokens.color.bg_primary = color.surface;
    tokens.tokens.color.bg_secondary = color.sidebar;
    tokens.tokens.color.bg_tertiary = color.chrome;
    tokens.tokens.color.bg_hover = ui.Color.rgba(19, 69, 246, 15);
    tokens.tokens.color.bg_active = ui.Color.rgba(19, 69, 246, 26);
    tokens.tokens.color.bg_inset = ui.Color.hex(0xF6FFF3);
    tokens.tokens.color.fg_primary = color.fg;
    tokens.tokens.color.fg_secondary = color.secondary;
    tokens.tokens.color.fg_tertiary = color.muted;
    tokens.tokens.color.fg_disabled = color.muted;
    tokens.tokens.color.fg_inverse = ui.Color.WHITE;
    tokens.tokens.color.accent = color.accent;
    tokens.tokens.color.accent_hover = ui.Color.hex(0x2563EB);
    tokens.tokens.color.accent_subtle = ui.Color.rgba(19, 69, 246, 18);
    tokens.tokens.color.accent_muted = ui.Color.rgba(19, 69, 246, 13);
    tokens.tokens.color.success = color.success;
    tokens.tokens.color.warning = color.warning;
    tokens.tokens.color.danger = color.danger;
    tokens.tokens.color.border = ui.Color.TRANSPARENT;
    tokens.tokens.color.border_strong = ui.Color.TRANSPARENT;
    tokens.tokens.color.border_focus = ui.Color.TRANSPARENT;
    tokens.tokens.color.focus_ring = ui.Color.TRANSPARENT;
    tokens.tokens.color.selection_bg = ui.Color.hex(0xB3D7FF);
    tokens.tokens.color.button_primary_bg = color.accent;
    tokens.tokens.color.button_primary_fg = ui.Color.WHITE;
    tokens.tokens.color.button_secondary_bg = ui.Color.hex(0xF6FFF3);
    tokens.tokens.color.button_secondary_fg = color.secondary;
    tokens.tokens.color.input_bg = color.surface;
    tokens.tokens.color.input_border = ui.Color.TRANSPARENT;
    tokens.tokens.color.checkbox_bg = color.surface;
    tokens.tokens.color.checkbox_border = ui.Color.TRANSPARENT;
    tokens.tokens.color.switch_thumb = color.surface;
    tokens.tokens.color.switch_track_on = color.accent;
    tokens.tokens.color.switch_track_off = ui.Color.hex(0xCBDCC9);
    tokens.tokens.color.list_hover_bg = ui.Color.rgba(19, 69, 246, 10);
    tokens.tokens.color.list_selection_bg = ui.Color.rgba(19, 69, 246, 20);
    tokens.tokens.color.separator = ui.Color.TRANSPARENT;
    tokens.tokens.color.tooltip_bg = ui.Color.rgba(15, 23, 42, 235);
    tokens.tokens.color.tooltip_fg = color.surface;
    tokens.tokens.size.switch_width = 34;
    tokens.tokens.size.switch_height = 19;
    break :blk tokens;
};

pub const FieldStyle = struct {
    font_size: f32 = 12,
    height: f32 = 32,
    embedded: bool = false,
};

pub fn input(cx: *ui.Cx, scope: *ui.Scope, props: anytype, style: FieldStyle) !*ui.Node {
    var builder = ui.widgets.Input(props);
    builder.props.embedded = style.embedded;
    builder.props.placeholder_color = color.muted;
    const result = try builder.mountResult(scope, cx);
    if (!style.embedded) @import("app_theme.zig").styleInput(result);
    result.state.font_size = style.font_size;
    result.state.line_height = style.font_size * 1.5;
    result.state.char_width = style.font_size * 0.6;
    result.state.dirty = true;
    result.node.style.width = .{ .grow = .{ .min = 0 } };
    result.node.style.flex_shrink = 1;
    if (!style.embedded) result.input_container.style.height = .{ .px = style.height };
    if (result.state.text_display_node) |text| {
        if (text.getText()) |current| {
            var next = current;
            next.font_size = style.font_size;
            next.line_height = 1.5;
            text.setText(next);
        }
    }
    return result.node;
}
