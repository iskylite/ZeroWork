const ui = @import("ui");
const theme = @import("app_theme.zig");

pub const height = @import("v3_geometry.zig").tab_height;
pub const gap: f32 = 4;
pub const title_font: f32 = 12;
pub const title_weight: u16 = 500;
pub const attention_border_width: f32 = 1;
pub const picker_width: f32 = 420;
pub const picker_height: f32 = 270;
pub const picker_padding: f32 = 14;
pub const picker_row_height: f32 = 54;
pub const rename_width: f32 = 320;
pub const rename_height: f32 = 118;
pub const field_height: f32 = 32;

pub fn strip() ui.BoxStyle {
    return .{ .height = .{ .px = height }, .direction = .row, .align_items = .center, .gap = gap, .flex_shrink = 0 };
}
pub fn tab(width: f32, active: bool) ui.BoxStyle {
    const c = theme.current();
    return .{ .shadow = if (active) .{ .blur = if (theme.currentName() == .dark) 8 else 6, .offset_y = if (theme.currentName() == .dark) 2 else 1, .color = c.shadow.withAlpha(if (theme.currentName() == .dark) 89 else 18) } else .{ .color = ui.Color.TRANSPARENT, .blur = 0, .offset_y = 0 }, .width = .{ .px = width }, .height = .{ .px = height }, .direction = .row, .align_items = .center, .background = if (active) c.tab_on else ui.Color.TRANSPARENT, .border = .{ .width = if (active) 1 else 0, .color = c.fg_1.withAlpha(18), .radius = 9 }, .flex_shrink = 0 };
}
pub fn underline(width: f32) ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .left = .{ .px = 12 }, .top = .{ .px = height - 5 } }, .width = .{ .px = width - 24 }, .height = .{ .px = 2 }, .background = theme.current().accent, .border = .{ .radius = 1.25 } };
}
pub fn title() ui.TextStyle {
    return .{ .font_size = title_font, .font_weight = title_weight, .color = theme.current().fg_1, .line_height = 1.5, .text_overflow = .ellipsis, .selectable = false };
}
pub fn iconSlot() ui.BoxStyle {
    return .{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .position = .absolute, .inset = .{ .left = .{ .px = 10 }, .top = .{ .px = (height - 14) / 2 } }, .align_items = .center, .justify = .center, .flex_shrink = 0 };
}
pub fn close(width: f32) ui.BoxStyle {
    return .{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .position = .absolute, .inset = .{ .left = .{ .px = width - 26 }, .top = .{ .px = (height - 20) / 2 } }, .padding = ui.Padding.ZERO, .align_items = .center, .justify = .center, .gap = 0, .background = ui.Color.TRANSPARENT, .border = .{ .radius = 5 }, .flex_shrink = 0 };
}
pub fn control(width: f32) ui.BoxStyle {
    return .{ .width = .{ .px = width }, .height = .{ .px = 28 }, .padding = .{}, .border = .{ .radius = 6 }, .flex_shrink = 0 };
}
pub fn panel() ui.BoxStyle {
    const c = theme.current();
    return .{ .direction = .column, .padding = .{ .left = picker_padding, .right = picker_padding, .top = picker_padding, .bottom = picker_padding }, .gap = 8, .background = c.overlay, .border = .{ .width = 0, .color = c.border, .radius = 14 }, .shadow = .{ .blur = 32, .offset_y = 12, .color = c.shadow } };
}
pub fn pickerRow(selected: bool) ui.BoxStyle {
    const c = theme.current();
    return .{ .width = .fill(), .height = .{ .px = picker_row_height }, .direction = .row, .align_items = .center, .padding = .{ .left = 10, .right = 10, .top = 8, .bottom = 8 }, .gap = 10, .background = if (selected) c.selection else c.well, .border = .{ .width = 0, .color = if (selected) c.accent else c.border, .radius = 8 }, .flex_shrink = 0 };
}
pub fn field() ui.BoxStyle {
    const c = theme.current();
    return .{ .width = .fill(), .height = .{ .px = field_height }, .background = c.well, .border = .{ .width = 0, .color = c.well_border, .radius = 7 } };
}
pub fn smallText() ui.TextStyle {
    return .{ .font_size = 10, .color = theme.current().fg_2, .line_height = 1.4, .selectable = false };
}

pub fn tuneInput(input: *ui.widgets.input.InputResult) void {
    input.state.font_size = 12;
    input.state.line_height = 18;
    input.state.char_width = 7.2;
    input.state.dirty = true;
    if (input.state.text_display_node) |node| if (node.getText()) |text| {
        var next = text;
        next.font_size = 12;
        next.line_height = 1.5;
        node.setText(next);
    };
}

// Figma Local Bridge 236:547754: anchored 320x172 editor, header36,
// content at12,40, input at0,21, footer at0,89.
pub fn renameDialog(has_error: bool) ui.BoxStyle {
    return .{ .width = .{ .px = rename_width }, .height = .{ .px = rename_height + @as(f32, if (has_error) 24 else 0) }, .padding = ui.Padding.all(0), .background = theme.current().overlay, .glass = theme.overlayGlass(), .border = .{ .radius = 11 }, .shadow = .{ .offset_y = 12, .blur = 24, .color = theme.current().shadow } };
}
pub fn renameBody() ui.BoxStyle {
    return .{ .padding = ui.Padding.all(0), .width = .fill(), .height = .fill(), .direction = .column, .gap = 0 };
}
pub fn renameContent() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .direction = .column, .gap = 8, .padding = .{ .left = 12, .right = 12, .top = 4, .bottom = 12 } };
}
pub fn renameActions() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 30 }, .direction = .row, .justify = .end, .gap = 8, .flex_shrink = 0 };
}
pub fn renameHeader() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 32 }, .direction = .row, .align_items = .center, .gap = 6, .padding = .{ .left = 12, .right = 12 }, .flex_shrink = 0 };
}
pub fn renameTitle() ui.TextStyle {
    return .{ .font_size = 13, .font_weight = 700, .line_height = 20.0 / 13.0, .color = theme.current().fg_1 };
}
pub fn renameIcon() ui.Style {
    return .{ .width = .{ .px = 18 }, .height = .{ .px = 18 }, .flex_shrink = 0 };
}
pub fn renameClose() ui.BoxStyle {
    return .{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .padding = ui.Padding.all(0), .border = .{ .radius = 8 }, .flex_shrink = 0 };
}
pub fn renameField() ui.BoxStyle {
    var value = field();
    value.border = .{ .width = 0, .color = theme.current().well_border, .radius = 8 };
    return value;
}
pub fn renameLabel() ui.TextStyle {
    return .{ .font_size = 11, .font_weight = 500, .color = theme.current().fg_2, .line_height = 16.0 / 11.0 };
}
pub fn renameHint() ui.TextStyle {
    return .{ .font_size = 11, .color = theme.current().fg_2, .line_height = 16.0 / 11.0, .selectable = false };
}
pub fn renameButton(width: f32) ui.BoxStyle {
    return .{ .width = .{ .px = width }, .height = .{ .px = 30 }, .border = .{ .radius = 8 } };
}
pub fn repaintRename(root: *ui.Node, previous: theme.Colors) void {
    root.setBackground(remapRename(root.getBackground(), previous));
    if (root.getText()) |value| root.setTextColor(remapRename(value.color, previous));
    if (root.getIcon()) |value| _ = root.setTint(remapRename(value.tint, previous));
    if (root.getImage()) |value| _ = root.setTint(remapRename(value.tint, previous));
    for (root.children.items) |child| repaintRename(child, previous);
}
fn remapRename(value: ui.Color, previous: theme.Colors) ui.Color {
    const next = theme.current();
    inline for (@typeInfo(theme.Colors).@"struct".field_names) |role| if (ui.Color.eql(value, @field(previous, role))) return @field(next, role);
    return value;
}

// Figma 259:241008: insertion seam spans the 32px tab, 4px wide, radius2.
pub fn dragGap() ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } }, .width = .{ .px = 4 }, .height = .{ .px = height }, .background = theme.current().accent, .border = .{ .radius = 2 }, .flex_shrink = 0 };
}

// Figma 259:240992 / 259:240997: group identity tint and marker.
pub fn groupTint(color: ui.Color) ui.Color {
    return color.withAlpha(20);
}
pub fn groupMarker(color: ui.Color) ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = (height - 18) / 2 } }, .width = .{ .px = 2.5 }, .height = .{ .px = 18 }, .background = color, .border = .{ .radius = 1 }, .flex_shrink = 0 };
}

// V3 #tooltip: independent floating content, max-width300, inset7/10, radius7.
pub fn tooltip() ui.BoxStyle {
    return .{ .width = .{ .fit = .{ .max = 300 } }, .max_width = 300, .padding = .{ .left = 10, .right = 10, .top = 7, .bottom = 7 }, .border = .{ .radius = 7 }, .background = theme.current().overlay, .shadow = .{ .offset_y = 8, .blur = 24, .color = theme.current().shadow } };
}
