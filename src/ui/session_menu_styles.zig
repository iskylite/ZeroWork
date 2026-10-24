const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub const ButtonStyle = @FieldType(ui.widgets.ControlShellConfig, "style");
pub const width: f32 = 336;
pub const padding: f32 = 10;
pub const gap: f32 = 6;
pub const row_height: f32 = 32;
pub const group_max_height: f32 = 108;

pub fn panel() ui.BoxStyle {
    const c = theme.current();
    return .{ .width = .{ .px = width }, .height = .{ .fit = .{} }, .direction = .column, .gap = gap, .padding = .{ .left = padding, .right = padding, .top = padding, .bottom = padding }, .background = c.overlay, .border = .{ .width = 0, .radius = 14 }, .shadow = .{ .blur = 28, .offset_y = 10, .color = c.shadow } };
}
pub fn search() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = row_height }, .background = theme.current().well, .border = .{ .width = 0, .color = theme.current().well_border, .radius = 8 } };
}
pub fn group() ui.BoxStyle {
    return .{ .width = .fill(), .direction = .column, .padding = .{ .left = 4, .right = 4, .top = 4, .bottom = 4 }, .gap = 2, .background = theme.current().surface_1, .border = .{ .width = 0, .radius = 9 } };
}
pub fn row(selected: bool, height: f32, inset: f32) ButtonStyle {
    const c = theme.current();
    return .{ .width = .fill(), .height = .{ .px = height }, .direction = .row, .align_items = .center, .justify = .start, .gap = 0, .background = if (selected) c.selection else ui.Color.TRANSPARENT, .text_color = c.fg_1, .font_size = 12, .font_weight = 500, .padding = .{ .left = inset, .right = inset }, .corner_radius = 8, .border_width = 0 };
}
pub fn rowContent() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .min_width = 0, .direction = .row, .align_items = .center, .justify = .start, .gap = 8 };
}
pub fn hover() ButtonStyle {
    return .{ .background = theme.current().hover };
}
pub fn label() ui.TextStyle {
    return .{ .font_size = 12, .font_weight = 500, .line_height = 1.5, .color = theme.current().fg_1, .text_overflow = .ellipsis };
}
pub fn protocol() ui.TextStyle {
    return .{ .font_size = 10.5, .line_height = 16.0 / 10.5, .color = theme.current().fg_2, .use_monospace_font = true };
}
pub fn savedLabel() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 22 }, .direction = .row, .align_items = .center, .justify = .start, .padding = .{ .left = 10, .right = 10 }, .gap = 8, .flex_shrink = 0 };
}
pub fn savedLabelText() ui.TextStyle {
    return .{ .font_size = 10.5, .line_height = 16.0 / 10.5, .color = theme.current().fg_2 };
}
