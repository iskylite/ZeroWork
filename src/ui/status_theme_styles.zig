const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub const ButtonStyle = @FieldType(ui.widgets.ControlShellConfig, "style");

// Bridge 274:912835 / 358:1425300, live 360x260 content-hug card.
pub const width: f32 = 360;
pub const row_height: f32 = 26;
pub const row_gap: f32 = 6;
pub const visible_rows: usize = 3;
pub const fixed_height: f32 = 170; // chrome, header, scope, manage and feedback

pub fn panel() ui.BoxStyle {
    const c = theme.current();
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .padding = .{ .left = 14, .right = 14, .top = 17, .bottom = 18 }, .background = c.overlay, .border = .{ .radius = 14 }, .shadow = .{ .offset_y = 24, .blur = 32, .color = c.shadow } };
}
pub fn content() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 9, .min_height = 0 };
}
pub fn header() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 30 }, .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0 };
}
pub fn title() ui.TextStyle {
    return .{ .font_size = 13, .font_weight = 700, .line_height = 20.0 / 13.0, .color = theme.current().fg_1, .selectable = false };
}
pub fn body() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = row_gap, .min_height = 0 };
}
pub fn row() ButtonStyle {
    const c = theme.current();
    return .{ .width = .fill(), .height = .{ .px = row_height }, .direction = .row, .align_items = .center, .justify = .start, .gap = 0, .padding = .{}, .background = c.surface_2, .corner_radius = 7, .border_width = 0, .flex_shrink = 0 };
}
pub fn hover() ButtonStyle {
    return .{ .background = theme.current().hover };
}
pub fn rowContent() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .min_width = 0, .direction = .row, .align_items = .center, .gap = row_gap, .padding = .{ .left = 6, .right = 6 } };
}
pub fn passiveRow() ui.BoxStyle {
    var result = rowContent();
    result.height = .{ .px = row_height };
    result.flex = 0;
    result.flex_shrink = 0;
    return result;
}
pub fn label() ui.TextStyle {
    return .{ .font_size = 11, .line_height = 16.0 / 11.0, .color = theme.current().fg_1, .text_overflow = .ellipsis, .selectable = false };
}
pub fn tag() ui.TextStyle {
    return .{ .font_size = 10.5, .font_weight = 500, .line_height = 16.0 / 10.5, .color = theme.current().accent_ink, .text_align = .end, .selectable = false };
}
pub fn labelBox() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 16 }, .flex = 1, .min_width = 0, .overflow_hidden = true };
}
pub fn close() ButtonStyle {
    return .{ .width = .{ .px = 26 }, .height = .{ .px = 26 }, .padding = .{}, .gap = 0, .corner_radius = 7, .background = ui.Color.TRANSPARENT, .border_width = 0, .flex_shrink = 0 };
}
pub fn icon(size: f32) ui.Style {
    return .{ .width = .{ .px = size }, .height = .{ .px = size }, .flex_shrink = 0 };
}
pub fn fade() ui.BoxStyle {
    const c = theme.current();
    return .{ .width = .fill(), .height = .{ .px = 72 }, .position = .absolute, .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 }, .right = .{ .px = 0 } }, .gradient = .{ .from = c.well_border.withAlpha(48), .to = ui.Color.lerp(c.surface_1, c.overlay, 0.6) }, .border = .{ .radius = 14 }, .hit_behavior = .pass_through, .z_index = -1 };
}
pub fn scrollHint(left: f32) ui.BoxStyle {
    return .{ .width = .{ .px = 12 }, .height = .{ .px = 12 }, .position = .absolute, .inset = .{ .left = .{ .px = left }, .bottom = .{ .px = 0 } }, .hit_behavior = .pass_through };
}
