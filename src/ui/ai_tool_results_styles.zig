//! Figma 415:1898195/415:1898241: 32 header +150 body +34 fixed actions.
const ui = @import("ui");
const theme = @import("app_theme.zig");
pub const ButtonStyle = @FieldType(ui.widgets.ControlShellConfig, "style");
pub fn list(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 8, .padding = .{ .right = 12 }, .flex_shrink = 0 };
}
pub fn card(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 216 }, .direction = .column, .flex_shrink = 0, .background = theme.current().surface_1, .border = .{ .radius = 11 }, .shadows = ui.ShadowList.of(&.{.{ .color = theme.current().shadow, .blur = 3, .offset_y = 1 }}), .overflow = .hidden };
}
pub fn header(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 32 }, .direction = .row, .align_items = .center, .padding = .{ .left = 10, .right = 12 }, .gap = 6, .flex_shrink = 0, .background = theme.current().well, .border = .{ .radius = 11 } };
}
pub fn body(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 150 }, .flex_shrink = 0 };
}
pub fn content(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .padding = .{ .left = 12, .right = 12, .top = 4, .bottom = 6 }, .gap = 4, .flex_shrink = 0 };
}
pub fn footer(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 34 }, .direction = .row, .align_items = .center, .padding = .{ .left = 10, .right = 10, .top = 4, .bottom = 4 }, .gap = 6, .flex_shrink = 0, .background = theme.current().well };
}
pub fn outputViewport(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 104 }, .flex_shrink = 0, .background = theme.current().well };
}
pub fn outputContent(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .fit = .{} }, .height = .{ .fit = .{} }, .padding = .{ .left = 6, .right = 6, .top = 4, .bottom = 4 }, .direction = .column, .flex_shrink = 0 };
}
pub fn text(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10.5, .line_height = 16.0 / 10.5, .wrap = .word, .color = theme.current().fg_2 };
}
pub fn title(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11.5, .font_weight = 500, .line_height = 16.0 / 11.5, .color = theme.current().fg_1 };
}
pub fn output(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .line_height = 16.0 / 11.0, .wrap = .none, .use_monospace_font = true, .color = theme.current().fg_1 };
}
pub fn button(size: f32) ButtonStyle {
    return .{ .width = .{ .px = size }, .height = .{ .px = size }, .padding = .{}, .flex_shrink = 0, .corner_radius = 6, .background = ui.Color.TRANSPARENT };
}
pub fn targetButton() ButtonStyle {
    return .{ .width = .fill(), .height = .{ .px = 26 }, .padding = .{ .left = 0, .right = 0 }, .gap = 6, .font_size = 10.5, .flex_shrink = 0, .corner_radius = 4, .background = ui.Color.TRANSPARENT };
}
pub fn headerTitle(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = 84 }, .height = .{ .px = 16 }, .flex_shrink = 0 };
}
pub fn headerSummary(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 16 }, .flex = 1, .min_width = 0, .overflow = .hidden };
}
pub fn elapsedSlot(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = 44 }, .height = .{ .px = 16 }, .margin = .{ .left = 4 }, .flex_shrink = 0 };
}
pub fn elapsed(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10.5, .line_height = 16.0 / 10.5, .use_monospace_font = true, .text_align = .end, .color = theme.current().fg_2 };
}
pub fn targetRow(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 26 }, .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0 };
}
pub fn targetLabel(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = 186 }, .height = .{ .px = 16 }, .flex_shrink = 0, .overflow = .hidden };
}
pub fn targetStatus(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 16 }, .flex = 1, .min_width = 0, .overflow = .hidden };
}
pub fn targetText(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10.5, .line_height = 16.0 / 10.5, .color = theme.current().fg_2 };
}
pub fn commandRow(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 27 }, .direction = .row, .align_items = .start, .gap = 6, .flex_shrink = 0, .min_width = 0 };
}
pub fn commandViewport(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 27 }, .flex = 1, .min_width = 0, .flex_shrink = 0 };
}

pub fn resultImage(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 112 }, .flex_shrink = 0 };
}
