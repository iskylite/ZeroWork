//! Native Bridge data-cleanup panel: existing Vanta radius, spacing, type and controls.
const ui = @import("ui");
pub const theme = @import("app_theme.zig");
const record = @import("record_cleanup_styles.zig");
pub const width: f32 = 520;
pub const height: f32 = 300;
pub const max_height: f32 = 360;
pub fn dialog(viewport_width: f32) ui.BoxStyle {
    return .{ .width = .{ .px = @min(width, @max(1, viewport_width - 32)) }, .height = .{ .px = height }, .padding = .ZERO, .background = theme.current().overlay, .glass = theme.overlayGlass(), .border = .{ .width = 0, .radius = 14 }, .shadow = .{ .offset_y = 24, .blur = 32, .color = theme.current().shadow } };
}
pub fn body() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .direction = .column, .padding = .{ .left = 12, .right = 12, .top = 12, .bottom = 12 }, .gap = 8 };
}
pub fn row() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 34 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .justify = .space_between, .gap = 6 };
}
pub fn textBox(height_px: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = height_px }, .flex_shrink = 0 };
}
pub fn text(size: f32, line: f32, weight: u16) ui.TextStyle {
    return .{ .font_size = size, .line_height = line / size, .font_weight = weight, .color = theme.current().fg_1, .wrap = .word, .selectable = false };
}
pub fn button(primary: bool, disabled: bool) ui.BoxStyle {
    var result = record.button(primary, primary);
    if (disabled) result.opacity = 0.45;
    return result;
}
pub fn warning() ui.Color {
    return record.warning();
}
