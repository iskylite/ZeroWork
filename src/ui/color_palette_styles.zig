const ui = @import("ui");
pub fn palette() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 76 }, .direction = .column, .gap = 12, .flex_shrink = 0 };
}
pub fn row() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 32 }, .direction = .row, .gap = 12, .flex_shrink = 0 };
}
pub fn swatch(color: u32) ui.BoxStyle {
    return .{ .width = .{ .px = 32 }, .height = .{ .px = 32 }, .padding = ui.Padding.ZERO, .background = ui.Color.hex(@intCast(color)), .border = .{ .radius = 8 }, .align_items = .center, .justify = .center, .flex_shrink = 0 };
}
