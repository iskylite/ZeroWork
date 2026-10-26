//! Editable V3 workspace remote attachment modal: width760, table rows43.
const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub const ButtonStyle = @FieldType(ui.widgets.ControlShellConfig, "style");
pub fn root(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 4, .flex_shrink = 0, .padding = .{ .left = 14, .right = 14 } };
}
pub fn row(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 24 }, .direction = .row, .gap = 4, .align_items = .center, .flex_shrink = 0 };
}
pub fn text(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10.5, .line_height = 16.0 / 10.5, .color = theme.current().fg_2, .text_overflow = .ellipsis };
}
pub fn heading(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 14, .line_height = 20.0 / 14.0, .font_weight = 600, .color = theme.current().fg_1 };
}
pub fn input() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 32 }, .background = theme.current().well, .padding = .{ .left = 8, .right = 6 }, .border = .{ .radius = 8 }, .flex_shrink = 0 };
}
pub fn button() ButtonStyle {
    return .{ .height = .{ .px = 22 }, .padding = .{ .left = 6, .right = 6 }, .corner_radius = 6, .background = ui.Color.TRANSPARENT, .flex_shrink = 0 };
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
    return .{ .width = .fill(), .height = .{ .px = 172 }, .min_height = 0, .flex_shrink = 0 };
}
