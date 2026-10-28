//! Editable V3 workspace remote attachment modal: width760, height438, table rows43.
const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub const ButtonStyle = @FieldType(ui.widgets.ControlShellConfig, "style");
pub fn root(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 4, .flex_shrink = 0, .padding = .{ .left = 14, .right = 14 } };
}
pub fn row(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 24 }, .direction = .row, .gap = 8, .align_items = .center, .flex_shrink = 0 };
}
pub fn text(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .line_height = 16.0 / 11.0, .color = theme.current().fg_2, .text_overflow = .ellipsis };
}
pub fn heading(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 16, .line_height = 24.0 / 16.0, .font_weight = 600, .color = theme.current().fg_1 };
}
pub fn input() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 32 }, .background = theme.popupInset(), .padding = .{ .left = 8, .right = 6 }, .border = .{ .radius = 8 }, .flex_shrink = 0 };
}
pub fn button() ButtonStyle {
    return .{ .height = .{ .px = 32 }, .padding = .{ .left = 12, .right = 12 }, .corner_radius = 6, .background = theme.popupInset(), .flex_shrink = 0 };
}
pub fn option() ButtonStyle {
    return .{ .width = .fill(), .min_width = 0, .height = .{ .px = 32 }, .padding = .{ .left = 0, .right = 6 }, .corner_radius = 0, .background = ui.Color.TRANSPARENT, .justify = .start, .overflow = .hidden };
}
pub fn filenameLabel() ui.BoxStyle {
    return .{ .width = .fill(), .min_width = 0, .height = .{ .px = 16 }, .flex = 1 };
}
pub fn hover() ButtonStyle {
    return .{ .background = theme.current().hover };
}
pub fn list() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 129 }, .min_height = 0, .flex_shrink = 0 };
}

pub fn primary() ButtonStyle {
    var style = button();
    style.background = theme.current().action_accent;
    return style;
}
pub fn table(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 158 }, .direction = .column, .background = theme.popupInset(), .border = .{ .radius = 8 }, .overflow = .hidden, .flex_shrink = 0 };
}
pub fn empty(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 129 }, .align_items = .center, .justify = .center, .flex_shrink = 0 };
}

pub fn closeButton() ButtonStyle {
    return .{ .height = .{ .px = 24 }, .padding = .{ .left = 6, .right = 6 }, .corner_radius = 6, .background = ui.Color.TRANSPARENT, .flex_shrink = 0 };
}

pub fn filename(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 12, .line_height = 16.0 / 12.0, .color = theme.current().fg_1, .text_overflow = .ellipsis };
}
