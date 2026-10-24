//! Local Bridge session-mvgeqdxp-kmw89t: 223:330800,
//! 236:475949 / 477759 / 481403, 321:911916.
const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub const Mode = enum { choice, rename, remote_confirmation, local_confirmation };
pub const chrome_height: f32 = 88;
pub fn width(mode: Mode) f32 {
    return switch (mode) {
        .choice, .rename => 620,
        .remote_confirmation => 460,
        .local_confirmation => 480,
    };
}
pub fn height(mode: Mode) f32 {
    return switch (mode) {
        .choice => 381,
        .rename => 395,
        .remote_confirmation => 256,
        .local_confirmation => 200,
    };
}
pub fn panel(mode: Mode, size: ui.Size, natural: f32) ui.BoxStyle {
    return .{ .width = .{ .px = @min(width(mode), @max(0, size.width - 16)) }, .height = .{ .px = @min((if (natural > 0) natural + chrome_height + @as(f32, if (mode == .remote_confirmation) 8 else 0) else height(mode)), @max(0, size.height - 16)) }, .direction = .column, .padding = .{}, .gap = 0, .background = theme.current().overlay, .border = .{ .radius = 14 }, .overflow_hidden = true, .flex_shrink = 0 };
}
pub fn form() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .min_height = 0, .direction = .column, .padding = .{}, .gap = 0 };
}
// 321:851447/449: 72px theme-derived topfade and centered 32×3 grip at y7.
pub fn fade() ui.BoxStyle {
    const c = theme.current();
    return .{ .width = .fill(), .height = .{ .px = 72 }, .position = .absolute, .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } }, .gradient = .{ .from = c.well_border.withAlpha(184), .to = ui.Color.lerp(c.surface_1, c.overlay, 0.6).withAlpha(140) }, .border = .{ .radius = 14 }, .hit_behavior = .pass_through };
}
pub fn gripRow() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 3 }, .position = .absolute, .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 7 } }, .align_items = .center, .justify = .center, .hit_behavior = .pass_through };
}
pub fn grip() ui.BoxStyle {
    return .{ .width = .{ .px = 32 }, .height = .{ .px = 3 }, .background = theme.current().fg_3, .border = .{ .radius = 1.5 }, .hit_behavior = .pass_through };
}
pub fn header(_: Mode) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 40 }, .direction = .row, .align_items = .center, .padding = .{ .left = 12, .right = 12 }, .gap = 6, .flex_shrink = 0 };
}
pub fn viewport(mode: Mode) ui.BoxStyle {
    const remote = mode == .remote_confirmation;
    return .{ .width = .fill(), .height = .fill(), .min_height = 0, .margin = .{ .left = 12, .right = 12, .top = if (remote) 8 else 0 } };
}
pub fn stack(gap: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = gap, .min_width = 0, .flex_shrink = 0 };
}
pub fn footer(mode: Mode) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 48 }, .direction = .row, .align_items = .center, .justify = .end, .padding = .{ .left = 12, .right = 12, .top = 7, .bottom = 7 }, .gap = if (mode == .remote_confirmation) 8 else 6, .flex_shrink = 0 };
}
pub fn choice(selected: bool) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 34 }, .direction = .row, .align_items = .center, .justify = .start, .padding = ui.Padding.all(8), .gap = 8, .background = if (selected) theme.current().selection else theme.current().surface_2, .border = .{ .radius = 7, .width = 0 }, .flex_shrink = 0 };
}
pub fn radioGlyph() ui.BoxStyle {
    return .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .padding = .{}, .border = .{ .width = 0 }, .background = ui.Color.TRANSPARENT, .align_items = .center, .justify = .center, .flex_shrink = 0 };
}
pub fn input() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 31 }, .padding = .{ .left = 10, .right = 8 }, .background = theme.current().well, .border = .{ .radius = 8 }, .flex_shrink = 0 };
}
pub fn checkbox() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 24 }, .direction = .row, .align_items = .center, .gap = 8, .flex_shrink = 0 };
}
pub fn notice() ui.BoxStyle {
    var style = stack(4);
    style.padding = ui.Padding.all(12);
    style.min_height = 62;
    style.background = theme.current().danger.withAlpha(23);
    style.border = .{ .radius = 9 };
    return style;
}
pub fn localNotice() ui.BoxStyle {
    var style = stack(0);
    style.min_height = 22;
    style.padding = .{};
    style.background = ui.Color.TRANSPARENT;
    style.border = .{ .radius = 0, .width = 0 };
    return style;
}
pub fn label(min: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .min_height = min, .min_width = 0, .flex_shrink = 0 };
}
pub fn button(w: f32, h: f32, primary: bool, danger: bool) ui.BoxStyle {
    return .{ .width = .{ .px = w }, .height = .{ .px = h }, .padding = .{}, .gap = 0, .corner_radius = 8, .border_width = 0, .background = if (danger) theme.current().danger else if (primary) theme.current().accent else theme.current().surface_2, .font_size = 12, .font_weight = 500, .text_color = if (primary) theme.widgetTheme(theme.currentName()).tokens.color.button_primary_fg else theme.current().fg_2, .flex_shrink = 0 };
}
// The prototype mutes fill and label to 40%, keeping the primary hue. Button's
// generic disabled recipe substitutes a neutral fill; this state is the local
// persistent inline layer over that recipe, removed again when enabled.
pub fn disabledPrimary(danger: bool) ui.BoxStyle {
    return .{ .background = if (danger) theme.current().danger else theme.current().accent, .opacity = 0.4 };
}
pub fn iconButton(size: f32) ui.BoxStyle {
    var style = button(size, size, false, false);
    style.background = ui.Color.TRANSPARENT;
    style.corner_radius = 7;
    return style;
}
pub fn hover() ui.BoxStyle {
    return .{ .background = theme.current().hover };
}
pub fn icon(size: f32) ui.Style {
    return .{ .width = .{ .px = size }, .height = .{ .px = size }, .flex_shrink = 0 };
}
pub fn text(size: f32, weight: u16, mono: bool, line: f32) ui.TextStyle {
    return .{ .font_size = size, .font_weight = weight, .line_height = line / size, .color = if (weight >= 500) theme.current().fg_1 else theme.current().fg_2, .wrap = .word, .text_overflow = .clip, .use_monospace_font = mono, .selectable = false };
}
pub fn title() ui.TextStyle {
    return text(13, 700, false, 20);
}
pub fn caption() ui.TextStyle {
    return text(12, 500, false, 18);
}
pub fn path() ui.TextStyle {
    var style = text(10.5, 400, true, 17);
    style.color = theme.current().fg_1;
    style.wrap = .char;
    style.selectable = true;
    return style;
}
pub fn detail() ui.TextStyle {
    return text(10.5, 400, false, 17);
}
pub fn choiceText(danger: bool) ui.TextStyle {
    var style = text(11.5, 400, false, 18);
    style.color = if (danger) theme.current().danger_ink else theme.current().fg_1;
    return style;
}
