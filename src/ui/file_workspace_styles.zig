//! Local Bridge: 223:330815, 317:676623, 319:717894; stale 236:417691.
const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub const row_height: f32 = 28;
pub const min_columns: f32 = 490;
pub const columns_fixed: f32 = 274;
pub const path_font: f32 = 11.5;
pub const ButtonStyle = @FieldType(ui.widgets.ControlShellConfig, "style");
pub fn root(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .direction = .row, .gap = 6, .min_width = 0, .min_height = 0 };
}
pub fn card(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .min_width = 0, .min_height = 0, .direction = .column, .gap = 6, .padding = ui.Padding.all(10), .background = theme.current().surface_1, .border = .{ .radius = 11 }, .overflow = .hidden, .overflow_hidden = true };
}
pub fn line(height: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = height }, .flex_shrink = 0, .direction = .row, .gap = 6, .align_items = .center, .min_width = 0 };
}
pub fn flexible() ui.BoxStyle {
    return .{ .width = .fill(), .flex = 1, .min_width = 0, .overflow = .hidden, .overflow_hidden = true };
}
pub fn title(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 12, .font_weight = 500, .line_height = 1.5, .color = theme.current().fg_1, .wrap = .none, .text_overflow = .ellipsis };
}
pub fn secondary(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10.5, .line_height = 16.0 / 10.5, .color = theme.current().fg_2, .wrap = .none };
}
pub fn numeric(t: *const ui.ThemeTokens) ui.TextStyle {
    var value = secondary(t);
    value.text_align = .end;
    return value;
}
pub fn subtitle(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10.5, .line_height = 18.0 / 10.5, .color = theme.current().fg_2, .wrap = .none };
}
pub fn filename(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 12, .line_height = 1.5, .color = theme.current().fg_1, .wrap = .none, .text_overflow = .ellipsis };
}
pub fn badge(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .height = .{ .px = 22 }, .padding = .{ .left = 8, .right = 8 }, .align_items = .center, .justify = .center, .background = theme.current().surface_2, .border = .{ .radius = 6 }, .flex_shrink = 0 };
}
pub fn iconButton(size: f32) ButtonStyle {
    return .{ .width = .{ .px = size }, .height = .{ .px = size }, .padding = .{}, .gap = 0, .flex_shrink = 0, .corner_radius = 7, .background = ui.Color.TRANSPARENT };
}
pub fn pathField(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 32 }, .flex = 1, .min_width = 0, .direction = .row, .align_items = .center, .padding = .{ .left = 10, .right = 8 }, .gap = 6, .background = theme.current().well, .border = .{ .radius = 8 }, .overflow = .hidden, .overflow_hidden = true };
}
pub fn pathInput() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 32 }, .flex = 1, .min_width = 0, .padding = .{}, .border = .{ .width = 0 }, .background = ui.Color.TRANSPARENT };
}
pub fn table(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0, .min_width = 0, .direction = .column, .background = theme.current().surface_2, .border = .{ .radius = 9 }, .overflow = .hidden, .overflow_hidden = true };
}
pub fn headerClip(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 28 }, .flex_shrink = 0, .overflow = .hidden, .overflow_hidden = true };
}
pub fn columns(width: f32) ui.BoxStyle {
    return .{ .width = .{ .px = width }, .height = .{ .px = 28 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .padding = .{ .left = 8, .right = 8 }, .gap = 6 };
}
pub fn column(width: f32) ui.BoxStyle {
    return .{ .width = .{ .px = width }, .height = .{ .px = 28 }, .flex_shrink = 0, .min_width = 0, .direction = .row, .align_items = .center, .gap = 6, .overflow = .hidden, .overflow_hidden = true };
}
pub fn sortButton(width: f32) ButtonStyle {
    return .{ .width = .{ .px = width }, .height = .{ .px = 28 }, .padding = .{}, .gap = 0, .flex_shrink = 0, .background = ui.Color.TRANSPARENT };
}
pub fn fileRow(width: f32, selected: bool, focused: bool) ButtonStyle {
    return .{ .width = .{ .px = width }, .height = .{ .px = 28 }, .padding = .{}, .gap = 0, .flex_shrink = 0, .corner_radius = 6, .background = if (selected or focused) theme.current().selection else ui.Color.TRANSPARENT, .border_width = 0 };
}
pub fn viewport() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0, .min_width = 0 };
}
pub fn empty(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .position = .absolute, .width = .fill(), .height = .{ .px = 128 }, .direction = .column, .align_items = .center, .gap = 10, .padding = .{ .top = 10 }, .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 28 } } };
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
    return .{ .width = .fill(), .height = .{ .px = 74 }, .flex_shrink = 0, .direction = .column, .gap = 4, .padding = ui.Padding.all(8), .background = theme.current().surface_2, .border = .{ .radius = 9 } };
}

/// V2 Bridge 342:1091861, target-card frozen transfer draft.
pub fn copyConfirmation(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 132 }, .flex_shrink = 0, .direction = .column, .padding = .{ .top = 8, .bottom = 8, .left = 8, .right = 8 }, .gap = 4, .background = theme.current().surface_2, .border = .{ .radius = 9 } };
}
