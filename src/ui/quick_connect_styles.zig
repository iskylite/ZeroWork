//! Quick-connect hierarchy contract: docs/UI_V3/workspace/quick-connect/.
const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub const width: f32 = 520;
pub const row_height: f32 = 44;
pub const row_gap: f32 = 6;
/// Selection follows the shared state material without replacing its tint.
pub fn selectedFill() ui.Color {
    return theme.popupSelection();
}
pub fn panel() ui.BoxStyle {
    return .{ .width = .{ .px = width }, .height = .{ .fit = .{} }, .direction = .column, .padding = .{}, .background = theme.current().overlay, .glass = theme.overlayGlass(), .border = .{ .width = 0, .radius = 14 }, .shadow = .{ .offset_y = 24, .blur = 48, .color = theme.current().shadow }, .overflow = .hidden, .flex_shrink = 0 };
}
pub fn header() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 48 }, .padding = .{ .left = 16, .right = 14 }, .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0 };
}
pub fn body() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .padding = .{ .top = 8, .left = 16, .right = 16, .bottom = 16 }, .direction = .column, .gap = 6, .min_width = 0, .flex_shrink = 0 };
}
pub fn inputBorder(_: bool) ui.Border {
    return .{ .width = 0, .color = ui.Color.TRANSPARENT, .radius = 8 };
}
pub fn input(height: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = height }, .padding = .{}, .background = theme.popupInset(), .border = inputBorder(false), .flex_shrink = 0 };
}
pub fn inputContent(height: f32, clear: bool) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = height }, .padding = .{ .left = 12, .right = if (clear) 48 else 12 }, .gap = 8, .background = ui.Color.TRANSPARENT, .border = .{ .width = 0, .radius = 8 }, .flex_shrink = 0 };
}
pub fn queryRow() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 40 }, .flex_shrink = 0 };
}
pub fn row(selected: bool) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = row_height }, .padding = .{ .left = 10, .right = 10 }, .direction = .row, .align_items = .center, .justify = .start, .gap = 0, .background = if (selected) selectedFill() else ui.Color.TRANSPARENT, .border = .{ .width = 0, .radius = 8 }, .flex_shrink = 0 };
}
pub fn rowContent() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .direction = .row, .align_items = .center, .gap = 10, .min_width = 0 };
}
pub fn route() ui.BoxStyle {
    return .{ .width = .{ .px = 46 }, .height = .{ .px = 24 }, .direction = .row, .align_items = .center, .justify = .center, .background = theme.popupAction(), .border = .{ .radius = 8 }, .flex_shrink = 0 };
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
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .align_items = .center, .gap = 8, .padding = .{ .top = 20, .bottom = 20, .left = 12, .right = 12 }, .background = ui.Color.TRANSPARENT, .flex_shrink = 0 };
}
pub fn clearButton() ui.BoxStyle {
    return .{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .padding = .{}, .gap = 6, .font_size = 12, .font_weight = 500, .text_color = theme.current().fg_2, .background = theme.current().surface_2, .border = .{ .radius = 7 }, .flex_shrink = 0 };
}
pub fn clearPlacement() ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .top = .{ .px = 8 }, .right = .{ .px = 16 } } };
}
pub fn footer() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 46 }, .padding = .{ .top = 12 }, .direction = .row, .align_items = .center, .gap = 8, .border = .{ .width = 0 }, .flex_shrink = 0 };
}
pub fn actionFill() ui.Color {
    // A slightly deeper action fill also keeps the legacy pale-indigo palettes readable.
    return ui.Color.lerp(theme.current().action_accent, ui.Color.BLACK, 0.02);
}
pub fn button(primary: bool, temporary: bool) ui.BoxStyle {
    return .{ .width = .{ .px = if (temporary) 148 else 144 }, .height = .{ .px = 34 }, .padding = .{}, .background = if (primary) actionFill() else theme.popupAction(), .font_size = 12, .font_weight = 500, .text_color = if (primary) theme.actionForeground(actionFill()) else if (theme.currentName() == .dark) theme.current().fg_2 else theme.current().fg_1, .border = .{ .radius = 8 }, .flex_shrink = 0 };
}
pub fn iconButton() ui.BoxStyle {
    return .{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .padding = .{}, .align_items = .center, .justify = .center, .background = ui.Color.TRANSPARENT, .border = .{ .radius = 8 }, .flex_shrink = 0 };
}
pub fn text(size: f32, weight: u16, secondary: bool) ui.TextStyle {
    return .{ .font_size = size, .font_weight = weight, .line_height = if (size == 13 or size == 14) 20.0 / size else if (size == 12) 1.5 else 16.0 / size, .color = if (secondary) theme.current().fg_2 else theme.current().fg_1, .selectable = false, .text_overflow = .ellipsis };
}
pub fn repaint(node: *ui.Node, previous: theme.Colors) void {
    const background = node.getBackground();
    if (theme.remapUiSurface(background, previous)) |next| {
        node.setBackground(next);
    } else {
        inline for (@typeInfo(theme.Colors).@"struct".field_names) |role| {
            if (ui.Color.eql(background, @field(previous, role))) {
                node.setBackground(@field(theme.current(), role));
                break;
            }
        }
    }
    if (node.getText()) |value| node.setTextColor(theme.remapUiInk(value.color, previous));
    if (node.getIcon()) |value| _ = node.setTint(theme.remapUiInk(value.tint, previous));
    if (node.getImage()) |value| _ = node.setTint(theme.remapUiInk(value.tint, previous));
    for (node.children.items) |child| repaint(child, previous);
}
