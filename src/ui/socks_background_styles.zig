//! The unified port-forwarding card and its asset-scoped counterpart share row geometry.
const ui = @import("ui");
const M = @import("socks_background_model.zig");
const shared = @import("connection_details_styles.zig");
pub const theme = shared.theme;
pub fn panel(height: f32, viewport_width: f32) ui.BoxStyle {
    var value = shared.panel(height, viewport_width);
    value.width = .{ .px = @min(360, @max(0, viewport_width - 16)) };
    value.padding = ui.Padding.all(14);
    value.gap = 9;
    return value;
}
pub fn count() ui.BoxStyle {
    return .{ .height = .{ .px = 26 }, .direction = .row, .align_items = .center, .justify = .center, .gap = 5, .padding = .{ .left = 7, .right = 7 }, .border = .{ .radius = 7 }, .background = ui.Color.TRANSPARENT, .font_size = 10.5, .font_weight = 500, .text_color = theme.current().fg_2, .flex_shrink = 0 };
}
pub fn row() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 62 }, .direction = .column, .gap = 2, .padding = .{ .left = 12, .right = 8, .top = 7, .bottom = 6 }, .background = theme.popupInset(), .border = .{ .radius = 8 }, .min_width = 0, .flex_shrink = 0 };
}
pub fn action(size: f32) ui.BoxStyle {
    return .{ .width = .{ .px = size }, .height = .{ .px = size }, .padding = .{}, .direction = .row, .align_items = .center, .justify = .center, .border = .{ .radius = 7 }, .background = ui.Color.TRANSPARENT, .flex_shrink = 0 };
}
pub fn ink(phase: M.Phase) ui.Color {
    const c = theme.current();
    return switch (phase) {
        .listening => c.ok_ink,
        .failed, .cleanup_unknown => c.danger_ink,
        .paused => c.warn_ink,
        else => c.fg_2,
    };
}
pub fn text(size: f32, weight: u16, line: f32, color: ui.Color) ui.TextStyle {
    return .{ .font_size = size, .font_weight = weight, .line_height = line / size, .color = color, .selectable = false, .text_overflow = .ellipsis };
}
