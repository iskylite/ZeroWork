//! Bridge V2 configuration panels: 358:1367616 / 358:1368844 / 358:1369644.
const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub const width: f32 = 420;
pub const panel_height: f32 = 396;
// Header30 + footer30 + gaps18 + top17/bottom18.
pub const chrome_height: f32 = 113;
pub const inset: f32 = 14;
pub fn overlay() ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 }, .right = .{ .px = 0 }, .bottom = .{ .px = 0 } }, .width = .fill(), .height = .fill(), .display = .none, .z_index = 80, .align_items = .center, .justify = .center, .background = ui.Color.TRANSPARENT, .hit_behavior = .@"opaque" };
}
pub fn panel() ui.BoxStyle {
    return .{ .width = .{ .px = width }, .direction = .column, .padding = .{ .left = inset, .right = inset, .top = 17, .bottom = 18 }, .gap = 9, .background = theme.current().overlay, .border = .{ .radius = 14 }, .shadow = .{ .blur = 32, .offset_y = 24, .color = theme.current().shadow }, .flex_shrink = 0 };
}
pub fn row(height: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = height }, .direction = .row, .gap = 6, .align_items = .center, .flex_shrink = 0 };
}
pub fn column() ui.BoxStyle {
    return .{ .width = .fill(), .direction = .column, .gap = 6, .flex_shrink = 0, .min_width = 0 };
}
pub fn field() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 52 }, .direction = .column, .gap = 4, .flex_shrink = 0, .min_width = 0 };
}
pub fn input() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 32 }, .padding = .{ .left = 10, .right = 10 }, .background = theme.current().well, .border = .{ .radius = 8, .width = 0, .color = theme.current().well_border }, .flex_shrink = 0 };
}
pub fn action(primary: bool, w: f32) ui.BoxStyle {
    return .{ .width = .{ .px = w }, .height = .{ .px = 30 }, .padding = .{}, .background = if (primary) theme.current().accent else theme.current().surface_2, .border = .{ .radius = 8 }, .text_color = if (primary) ui.Color.WHITE else theme.current().fg_2, .font_size = 12, .font_weight = 500, .flex_shrink = 0 };
}
pub fn text(size: f32, weight: u16, secondary: bool) ui.TextStyle {
    return .{ .font_size = size, .font_weight = weight, .line_height = (if (size == 13) @as(f32, 20) else @as(f32, 16)) / size, .color = if (secondary) theme.current().fg_2 else theme.current().fg_1, .selectable = false, .text_overflow = .ellipsis };
}
pub const repaint = @import("quick_connect_styles.zig").repaint;
