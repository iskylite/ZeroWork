//! Figma 235:387850 / 390361 / 392866 / 397888 / 399541, read through
//! the local Bridge in ZeroWork · 交互原型, page 214:329905.
const ui = @import("ui");
const auth = @import("../proto/ssh/auth_challenge.zig");
pub const theme = @import("app_theme.zig");
pub const header_height: f32 = 40;
pub const footer_height: f32 = 34;
pub const padding: f32 = 12;
pub const gap: f32 = 6;
pub const field_height: f32 = 38;

pub fn width(kind: auth.Kind) f32 {
    return if (kind == .keyboard_interactive) 380 else 430;
}
pub fn height(kind: auth.Kind) f32 {
    return switch (kind) {
        .password => 380,
        .private_key_passphrase => 400,
        .keyboard_interactive => 346,
        .host_key_unknown => 378,
        .host_key_changed => 458,
    };
}
pub fn panel(w: f32, h: f32) ui.BoxStyle {
    return .{ .width = .{ .px = w }, .height = .{ .px = h }, .padding = .{}, .gap = 0, .direction = .column, .background = theme.current().overlay, .border = .{ .radius = 14 }, .overflow_hidden = true };
}
pub fn inlineRoot() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .display = .none };
}
pub fn form(w: f32, h: f32, inline_form: bool) ui.BoxStyle {
    var result = panel(w, h);
    // The dialog inherits the shared translucent overlay in every background mode.
    // Content must not paint another overlay over that already tinted floor.
    result.background = ui.Color.TRANSPARENT;
    if (inline_form) result.width = .fill();
    return result;
}
pub fn header() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = header_height }, .direction = .row, .align_items = .center, .gap = gap, .padding = .{ .left = 12, .right = 12 }, .flex_shrink = 0 };
}
pub fn body() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .min_height = 0, .direction = .column, .padding = .{ .left = padding, .right = padding, .top = 8, .bottom = padding }, .gap = 6 };
}
pub fn scroll() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .min_height = 0 };
}
pub fn stack() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = gap, .flex_shrink = 0 };
}
pub fn row(h: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = h }, .direction = .row, .align_items = .center, .gap = gap, .flex_shrink = 0 };
}
pub fn identity() ui.BoxStyle {
    var result = row(44);
    result.gap = 12;
    return result;
}
pub fn identityText() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 2 };
}
pub fn icon(size: f32) ui.Style {
    return .{ .width = .{ .px = size }, .height = .{ .px = size } };
}
pub fn text(size: f32, weight: u16, mono: bool) ui.TextStyle {
    return .{ .font_size = size, .font_weight = weight, .color = if (weight >= 500) theme.current().fg_1 else theme.current().fg_2, .line_height = (if (size >= 13) @as(f32, 20) else if (size >= 12) @as(f32, 18) else @as(f32, 16)) / size, .wrap = .word, .use_monospace_font = mono, .selectable = false };
}
pub fn well() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .min_height = 56, .direction = .column, .gap = 4, .padding = ui.Padding.all(10), .background = theme.current().well, .border = .{ .radius = 9 }, .flex_shrink = 0 };
}
pub fn notice(kind: auth.Kind) ui.BoxStyle {
    var result = well();
    const c = theme.current();
    const color = switch (kind) {
        .host_key_unknown => c.warn,
        .host_key_changed => c.danger,
        else => c.accent,
    };
    result.background = ui.Color.rgba(color.r, color.g, color.b, 23);
    result.padding = ui.Padding.all(12);
    result.min_height = if (kind == .host_key_changed) 64 else 62;
    return result;
}
pub fn field() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 4, .flex_shrink = 0 };
}
pub fn input(h: f32, has_eye: bool) ui.BoxStyle {
    const c = theme.current();
    return .{ .width = .fill(), .height = .{ .px = h }, .min_height = h, .padding = .{ .left = 12, .right = if (has_eye) 40 else 12 }, .background = c.well, .border = .{ .width = 0, .color = c.well_border, .radius = 8 }, .flex_shrink = 0 };
}
pub fn inputWrapper(h: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = h }, .flex_shrink = 0 };
}
pub fn eye(h: f32) ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .right = .{ .px = 6 }, .top = .{ .px = (h - 26) / 2 } }, .width = .{ .px = 26 }, .height = .{ .px = 26 }, .padding = .{}, .background = ui.Color.TRANSPARENT, .border = .{ .radius = 6 }, .align_items = .center, .justify = .center };
}
pub fn close() ui.BoxStyle {
    return .{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .padding = .{}, .background = ui.Color.TRANSPARENT, .border = .{ .radius = 8 }, .flex_shrink = 0 };
}
pub fn footer() ui.BoxStyle {
    var result = row(footer_height);
    result.gap = 8;
    result.justify = .end;
    return result;
}
pub fn button(w: f32, primary: bool, danger: bool) ui.BoxStyle {
    const c = theme.current();
    return .{ .width = .{ .px = w }, .height = .{ .px = footer_height }, .padding = .{}, .background = if (danger) c.action_danger else if (primary) c.action_accent else c.surface_2, .border = .{ .radius = 8 }, .justify = .center, .align_items = .center, .flex_shrink = 0 };
}
pub fn actionText(primary: bool) ui.TextStyle {
    var result = text(12, 500, false);
    result.color = actionColor(primary, false);
    return result;
}
pub fn actionColor(primary: bool, disabled: bool) ui.Color {
    if (disabled) return theme.current().fg_3;
    return if (primary) theme.widgetTheme(theme.currentName()).tokens.color.button_primary_fg else theme.current().fg_2;
}
pub fn tuneInput(input_result: *ui.widgets.input.InputResult) void {
    const state = input_result.state;
    state.font_size = 12;
    state.line_height = 18;
    state.char_width = 7.2;
    state.dirty = true;
    if (state.text_display_node) |node| if (node.getText()) |old| {
        var value = old;
        value.font_size = 12;
        value.line_height = 1.5;
        node.setText(value);
    };
}
