//! V3 workspace HTML: independent dual cards, 40 point rows and fixed 36 point footer.
const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub const row_height: f32 = 40;
pub const header_height: f32 = 34;
pub const min_columns: f32 = 490;
pub const columns_fixed: f32 = 282;
pub const path_font: f32 = 11.5;
pub const ButtonStyle = @FieldType(ui.widgets.ControlShellConfig, "style");
pub fn root(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .direction = .row, .gap = 6, .min_width = 0, .min_height = 0, .background = theme.current().app };
}
/// Each side owns a file card plus an optional sibling transfer card.
/// Hidden transfer roots do not contribute a gap or reserve any height.
pub fn columnStack(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .min_width = 0, .min_height = 0, .direction = .column, .gap = 6 };
}
pub fn card(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .min_width = 0, .min_height = 0, .direction = .column, .gap = 0, .padding = ui.Padding.all(1), .background = theme.current().surface_1, .border = .{ .radius = 11, .width = 1, .color = theme.current().border }, .overflow = .hidden, .overflow_hidden = true };
}
pub fn toolbar(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .flex_shrink = 0, .direction = .column, .gap = 10, .padding = .{ .top = 14, .right = 13, .bottom = 11, .left = 13 }, .border = .{ .width = 0, .side_widths = .{ 0, 0, 1, 0 }, .color = theme.current().border } };
}
pub fn footer(_: *const ui.ThemeTokens) ui.BoxStyle {
    var value = line(36);
    value.padding = .{ .left = 13, .right = 13 };
    value.gap = 8;
    value.border = .{ .width = 0, .side_widths = .{ 1, 0, 0, 0 }, .color = theme.current().border };
    return value;
}
pub fn line(height: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = height }, .flex_shrink = 0, .direction = .row, .gap = 6, .align_items = .center, .min_width = 0 };
}
pub fn flexible() ui.BoxStyle {
    return .{ .width = .fill(), .flex = 1, .min_width = 0, .overflow = .hidden, .overflow_hidden = true };
}
pub fn title(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 13, .font_weight = 700, .line_height = 18.5 / 13.0, .color = theme.current().fg_1, .wrap = .none, .text_overflow = .ellipsis };
}
pub fn secondary(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .line_height = 16.0 / 11.0, .color = theme.current().fg_2, .wrap = .none };
}
pub fn numeric(t: *const ui.ThemeTokens) ui.TextStyle {
    var value = secondary(t);
    value.font_size = 12;
    value.use_monospace_font = true;
    return value;
}
pub fn modified(t: *const ui.ThemeTokens) ui.TextStyle {
    var value = secondary(t);
    value.use_monospace_font = true;
    return value;
}
pub fn subtitle(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10.5, .line_height = 18.0 / 10.5, .color = theme.current().fg_2, .wrap = .none };
}
pub fn filename(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 12, .line_height = 1.5, .color = theme.current().fg_1, .wrap = .none, .text_overflow = .ellipsis };
}
pub fn badge(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .height = .{ .px = 19 }, .padding = .{ .left = 6, .right = 6 }, .align_items = .center, .justify = .center, .background = theme.current().surface_2, .border = .{ .radius = 6 }, .flex_shrink = 0 };
}
pub fn iconButton(size: f32) ButtonStyle {
    return .{ .width = .{ .px = size }, .height = .{ .px = size }, .padding = .{}, .gap = 0, .flex_shrink = 0, .corner_radius = 7, .background = ui.Color.TRANSPARENT };
}
pub fn pathField(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 30 }, .flex = 1, .min_width = 0, .direction = .row, .align_items = .center, .padding = .{ .left = 10, .right = 8 }, .gap = 6, .background = theme.current().well, .border = .{ .radius = 8 }, .overflow = .hidden, .overflow_hidden = true };
}
pub fn pathInput() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 30 }, .flex = 1, .min_width = 0, .padding = .{}, .border = .{ .width = 0 }, .background = ui.Color.TRANSPARENT };
}
pub fn table(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0, .min_width = 0, .direction = .column, .background = theme.current().surface_1, .border = .{ .radius = 0 }, .overflow = .hidden, .overflow_hidden = true };
}
pub fn headerClip(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = header_height }, .flex_shrink = 0, .overflow = .hidden, .overflow_hidden = true };
}
pub fn columns(width: f32) ui.BoxStyle {
    return .{ .width = .{ .px = width }, .height = .{ .px = row_height }, .flex_shrink = 0, .direction = .row, .align_items = .center, .padding = .{ .left = 14, .right = 0 }, .gap = 0 };
}
pub fn column(width: f32) ui.BoxStyle {
    return .{ .width = .{ .px = width }, .height = .{ .px = row_height }, .flex_shrink = 0, .min_width = 0, .direction = .row, .align_items = .center, .gap = 6, .overflow = .hidden, .overflow_hidden = true };
}
pub fn sortButton(width: f32) ButtonStyle {
    return .{ .width = .{ .px = width }, .height = .{ .px = header_height }, .padding = .{ .left = 7, .right = 7 }, .gap = 0, .flex_shrink = 0, .background = ui.Color.TRANSPARENT };
}
pub fn fileRow(width: f32, selected: bool, focused: bool) ButtonStyle {
    return .{ .width = .{ .px = width }, .height = .{ .px = row_height }, .padding = .{}, .gap = 0, .flex_shrink = 0, .corner_radius = 0, .background = if (selected or focused) theme.current().selection else ui.Color.TRANSPARENT, .border = .{ .width = 0, .side_widths = .{ 0, 0, 1, 0 }, .color = theme.current().border } };
}
pub fn viewport() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0, .min_width = 0 };
}
pub fn empty(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .position = .absolute, .width = .fill(), .height = .{ .px = 128 }, .direction = .column, .align_items = .center, .gap = 10, .padding = .{ .top = 10 }, .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = header_height } } };
}
pub fn errorBox(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .flex_shrink = 0, .direction = .column, .gap = 4, .padding = ui.Padding.all(8), .background = theme.current().surface_2, .border = .{ .radius = 9 }, .overflow = .hidden, .overflow_hidden = true };
}
pub fn errorText(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11.5, .line_height = 18.0 / 11.5, .color = theme.current().danger_ink, .wrap = .none };
}
pub fn icon(size: f32) ui.Style {
    return .{ .width = .{ .px = size }, .height = .{ .px = size }, .flex_shrink = 0 };
}
pub fn repaint(node: *ui.Node, previous: theme.Colors) void {
    node.setBackground(remap(node.getBackground(), previous));
    if (node.getText()) |text| node.setTextColor(remap(text.color, previous));
    if (node.getIcon()) |icon_| _ = node.setTint(remap(icon_.tint, previous));
    if (node.getImage()) |image_| _ = node.setTint(remap(image_.tint, previous));
    for (node.children.items) |child| repaint(child, previous);
}
fn remap(color: ui.Color, previous: theme.Colors) ui.Color {
    inline for (@typeInfo(theme.Colors).@"struct".field_names) |field| {
        if (ui.Color.eql(color, @field(previous, field))) return @field(theme.current(), field);
    }
    return color;
}

/// Bridge 342:1084206: target-card drag preview, 574×74, padding8/gap4/r9.
pub fn dragPreview(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .left = .{ .px = 8 }, .right = .{ .px = 8 }, .bottom = .{ .px = 40 } }, .height = .{ .px = 74 }, .flex_shrink = 0, .direction = .column, .gap = 4, .padding = ui.Padding.all(8), .background = theme.current().surface_2, .border = .{ .radius = 9 }, .hit_behavior = .pass_through };
}



pub fn dragGhost() ui.BoxStyle {
    return .{ .position = .absolute, .width = .{ .px = 220 }, .height = .{ .px = 36 }, .padding = ui.Padding.all(8), .background = theme.current().overlay, .border = .{ .radius = 8 }, .shadow = .{ .blur = 16, .offset_y = 4, .color = theme.current().shadow }, .z_index = 80, .hit_behavior = .pass_through };
}
