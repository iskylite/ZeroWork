//! Startup window styles.
const ui = @import("ui");
const theme = @import("app_theme.zig");

pub fn root() ui.BoxStyle {
    return .{ .position = .absolute, .width = .fill(), .height = .fill(), .inset = .{ .top = .{ .px = 0 }, .right = .{ .px = 0 }, .bottom = .{ .px = 0 }, .left = .{ .px = 0 } }, .direction = .column, .align_items = .center, .justify = .center, .background = theme.baseColors().app.withAlpha(255), .z_index = 5000, .hit_behavior = .@"opaque", .composited_group = true };
}
pub fn identity() ui.BoxStyle {
    return .{ .direction = .column, .align_items = .center, .flex_shrink = 0 };
}
pub fn logo() ui.BoxStyle {
    return .{ .width = .{ .px = 80 }, .height = .{ .px = 80 }, .margin = .{ .bottom = 20 }, .flex_shrink = 0 };
}
pub fn name() ui.TextStyle {
    return .{ .font_size = 18, .font_weight = 600, .line_height = 24.0 / 18.0, .color = theme.baseColors().fg_1 };
}
pub fn status() ui.TextStyle {
    return .{ .font_size = 12, .font_weight = 400, .line_height = 1.5, .color = theme.baseColors().fg_2 };
}
