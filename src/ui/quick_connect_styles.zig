//! Figma Bridge 233:339497, 318:681986 and 318:682044.
const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub const width: f32 = 520;
pub const row_height: f32 = 28;
pub fn panel() ui.BoxStyle {
    return .{ .width = .{ .px = width }, .height = .{ .fit = .{} }, .direction = .column, .padding = .{}, .background = theme.current().overlay, .border = .{ .radius = 14 }, .shadow = .{ .offset_y = 24, .blur = 32, .color = theme.current().shadow }, .overflow = .hidden, .flex_shrink = 0 };
}
pub fn header() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 48 }, .padding = .{ .left = 16, .right = 14 }, .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0 };
}
pub fn body() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .padding = .{ .top = 8, .left = 16, .right = 16, .bottom = 16 }, .direction = .column, .gap = 6, .min_width = 0, .flex_shrink = 0 };
}
pub fn input(height: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = height }, .padding = .{ .left = 12, .right = 12 }, .background = theme.current().well, .border = .{ .radius = 8 }, .flex_shrink = 0 };
}
pub fn queryInput(no_match: bool) ui.BoxStyle {
    var style = input(40);
    style.padding = .{ .left = 12, .right = if (no_match) 48 else 12 };
    style.gap = 8;
    return style;
}
pub fn queryRow() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 40 }, .flex_shrink = 0 };
}
pub fn row(selected: bool) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = row_height }, .padding = .{ .left = 8, .right = 8 }, .direction = .row, .align_items = .center, .justify = .start, .gap = 0, .background = if (selected) theme.current().accent.withAlpha(18) else ui.Color.TRANSPARENT, .border = .{ .radius = 8 }, .flex_shrink = 0 };
}
pub fn rowContent() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .direction = .row, .align_items = .center, .gap = 6, .min_width = 0 };
}
pub fn route() ui.BoxStyle {
    return .{ .width = .{ .px = 46 }, .height = .{ .px = 24 }, .direction = .row, .align_items = .center, .justify = .center, .background = theme.current().surface_2, .border = .{ .radius = 8 }, .flex_shrink = 0 };
}
pub fn column() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 6, .min_width = 0, .flex_shrink = 0 };
}
pub fn line(height: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = height }, .flex_shrink = 0 };
}
pub fn field(width_: ?f32) ui.BoxStyle {
    return .{ .width = if (width_) |value| .{ .px = value } else .fill(), .height = .{ .px = 52 }, .direction = .column, .gap = 4, .flex_shrink = 0 };
}
pub fn fieldRow() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 52 }, .direction = .row, .gap = 12, .flex_shrink = 0 };
}
pub fn notice(invalid: bool) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 62 }, .direction = .column, .gap = 4, .padding = ui.Padding.all(12), .background = (if (invalid) theme.current().danger else theme.current().accent).withAlpha(23), .border = .{ .radius = 9 }, .flex_shrink = 0 };
}
pub fn noMatch() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 6, .padding = .{ .top = 10, .bottom = 10 }, .background = ui.Color.TRANSPARENT, .flex_shrink = 0 };
}
pub fn clearButton() ui.BoxStyle {
    return .{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .padding = .{}, .gap = 6, .font_size = 12, .font_weight = 500, .text_color = theme.current().fg_2, .background = theme.current().surface_2, .border = .{ .radius = 7 }, .flex_shrink = 0 };
}
pub fn clearPlacement() ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .top = .{ .px = 8 }, .right = .{ .px = 16 } } };
}
pub fn footer() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 34 }, .direction = .row, .align_items = .center, .gap = 8, .flex_shrink = 0 };
}
pub fn button(primary: bool, temporary: bool) ui.BoxStyle {
    return .{ .width = .{ .px = if (temporary) 148 else 144 }, .height = .{ .px = 34 }, .padding = .{}, .background = if (primary) theme.current().accent else theme.current().surface_2, .font_size = 12, .font_weight = 500, .text_color = if (primary) ui.Color.WHITE else theme.current().fg_2, .border = .{ .radius = 8 }, .flex_shrink = 0 };
}
pub fn iconButton() ui.BoxStyle {
    return .{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .padding = .{}, .align_items = .center, .justify = .center, .background = ui.Color.TRANSPARENT, .border = .{ .radius = 8 }, .flex_shrink = 0 };
}
pub fn text(size: f32, weight: u16, secondary: bool) ui.TextStyle {
    return .{ .font_size = size, .font_weight = weight, .line_height = if (size == 13 or size == 14) 20.0 / size else if (size == 12) 1.5 else 16.0 / size, .color = if (secondary) theme.current().fg_2 else theme.current().fg_1, .selectable = false, .text_overflow = .ellipsis };
}
pub fn repaint(node: *ui.Node, previous: theme.Colors) void {
    inline for (@typeInfo(theme.Colors).@"struct".field_names) |color_name| {
        if (ui.Color.eql(node.getBackground(), @field(previous, color_name))) node.setBackground(@field(theme.current(), color_name));
        if (node.getText()) |value| if (ui.Color.eql(value.color, @field(previous, color_name))) node.setTextColor(@field(theme.current(), color_name));
        if (node.getImage()) |value| {
            if (ui.Color.eql(value.tint, @field(previous, color_name))) _ = node.setTint(@field(theme.current(), color_name));
        }
    }
    for (node.children.items) |child| repaint(child, previous);
}
