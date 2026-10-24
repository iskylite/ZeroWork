const ui = @import("ui");
const theme = @import("app_theme.zig");
// Live Bridge 358:1395890: 360×248, r14, padding12, header28, content154, actions30.
pub fn panel() ui.BoxStyle {
    return .{ .width = .{ .px = 360 }, .height = .{ .px = 248 }, .direction = .column, .padding = ui.Padding.all(12), .gap = 6, .background = theme.current().overlay, .border = .{ .radius = 14 }, .z_index = 90, .display = .none, .hit_behavior = .@"opaque" };
}
pub fn row() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 30 }, .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0 };
}
pub fn text(strong: bool) ui.TextStyle {
    return .{ .font_size = if (strong) 13 else 11, .font_weight = if (strong) 500 else 400, .color = if (strong) theme.current().fg_1 else theme.current().fg_2, .wrap = .word };
}

// Figma primary button label is white; keep body and secondary roles unchanged.
pub fn primaryButtonText() ui.TextStyle {
    var value = text(false);
    value.color = ui.Color.rgb(255, 255, 255);
    return value;
}

pub fn header() ui.BoxStyle {
    var value = row();
    value.height = .{ .px = 28 };
    return value;
}
