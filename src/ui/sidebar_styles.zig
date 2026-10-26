//! Figma Local Bridge: 274:913661, 499:657547, 300:593434.
const std = @import("std");
const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub const expanded_width: f32 = 300;
pub const collapsed_width: f32 = 48;
pub const host_height: f32 = 36;
pub const group_height: f32 = 26;
pub const tail_width: f32 = 36;
pub const action_size: f32 = 24;

pub fn panel(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = expanded_width }, .height = .fill(), .direction = .column, .flex_shrink = 0, .background = theme.current().surface_1, .border = .{ .radius = 11 }, .overflow = .hidden };
}
pub fn full() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .direction = .column, .min_height = 0, .padding = .{ .top = 12, .left = 10, .right = 10, .bottom = 10 }, .gap = 14 };
}
pub fn header() ui.BoxStyle {
    return .{ .height = .{ .px = 24 }, .direction = .row, .align_items = .center, .gap = 6, .padding = .{ .left = 3, .right = 3 }, .flex_shrink = 0 };
}
pub fn search() ui.BoxStyle {
    return .{ .height = .{ .px = 34 }, .direction = .row, .align_items = .center, .padding = .{ .left = 9, .right = 9 }, .gap = 7, .background = theme.current().well, .border = .{ .radius = 8 }, .flex_shrink = 0 };
}
pub fn viewport() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0 };
}
pub fn list() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 6, .min_width = 0 };
}

/// Main workspace Sidebar 233:335283: each asset group is one inset surface.
pub fn groupCard() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 0, .padding = ui.Padding.all(3), .background = theme.current().surface_2, .border = .{ .radius = 9 }, .flex_shrink = 0, .min_width = 0 };
}
pub fn members() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 1, .min_width = 0 };
}
pub fn footer() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 34 }, .padding = .{ .left = 10, .right = 10 }, .direction = .row, .align_items = .center, .justify = .center, .gap = 6, .background = theme.current().surface_2, .border = .{ .radius = 8 }, .font_size = 12, .font_weight = 400, .text_color = theme.current().fg_1, .flex_shrink = 0 };
}
pub fn footerSlot(empty: bool) ui.BoxStyle {
    // Current Figma: workspace 233:334511 ends 8px above the panel;
    // empty state 392:1835642 ends 2px above it. Both wells are 34px high.
    return .{ .width = .fill(), .height = .{ .px = 34 }, .margin = if (empty) .{ .left = 8, .right = 8, .bottom = 2 } else .{}, .direction = .row, .flex_shrink = 0 };
}
pub fn footerFrame() ui.Style {
    return .{ .position = .absolute, .width = .{ .px = 208 }, .height = .{ .px = 34 } };
}
pub fn emptyFooter() ui.BoxStyle {
    var value = footer();
    value.background = theme.current().well;
    value.border = .{ .radius = 9 };
    return value;
}
pub fn headerAction() ui.BoxStyle {
    var value = action(24);
    value.border = .{ .radius = 8 };
    return value;
}
pub fn railAction(size: f32) ui.BoxStyle {
    var value = action(size);
    value.border = .{ .radius = 8 };
    return value;
}
pub fn action(size: f32) ui.BoxStyle {
    return .{ .width = .{ .px = size }, .height = .{ .px = size }, .padding = .{}, .align_items = .center, .justify = .center, .background = ui.Color.TRANSPARENT, .border = .{ .radius = 7 }, .flex_shrink = 0 };
}
pub fn host(selected: bool, hot: bool) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = host_height }, .direction = .row, .align_items = .center, .gap = 9, .padding = .{ .left = 9, .right = 9 }, .background = if (selected) theme.current().selection else if (hot) theme.current().selection else ui.Color.TRANSPARENT, .border = .{ .radius = 9 }, .flex_shrink = 0, .min_width = 0 };
}
pub fn content() ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } }, .width = .fill(), .height = .fill(), .direction = .row, .align_items = .center, .gap = 9, .padding = .{ .left = 9, .right = 9 }, .min_width = 0 };
}
pub fn titleViewport() ui.BoxStyle {
    return .{ .height = .{ .px = 18 }, .width = .fill(), .flex = 1, .min_width = 0, .overflow = .hidden, .align_items = .center };
}
pub fn tail() ui.BoxStyle {
    return .{ .width = .{ .px = tail_width }, .height = .{ .px = action_size }, .direction = .row, .align_items = .center, .justify = .end, .gap = 4, .flex_shrink = 0 };
}
pub fn route() ui.BoxStyle {
    return .{ .width = .{ .px = 36 }, .height = .{ .px = 20 }, .direction = .row, .align_items = .center, .justify = .end, .gap = 4, .flex_shrink = 0 };
}
pub fn icon(size: f32) ui.Style {
    return .{ .width = .{ .px = size }, .height = .{ .px = size }, .flex_shrink = 0 };
}
pub fn text(size: f32, weight: u16, secondary: bool) ui.TextStyle {
    return .{ .font_size = size, .font_weight = weight, .line_height = if (size == 13) 20.0 / 13.0 else if (size == 12) 1.5 else 16.0 / size, .color = if (secondary) theme.current().fg_2 else theme.current().fg_1, .selectable = false, .text_overflow = .ellipsis };
}
pub fn marker() ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 7 } }, .width = .{ .px = 3 }, .height = .{ .px = 22 }, .background = theme.current().accent, .border = .{ .radius = 1.25 } };
}
pub fn status(online: bool) ui.BoxStyle {
    return .{ .width = .{ .px = 6 }, .height = .{ .px = 6 }, .background = if (online) theme.current().ok else theme.current().fg_3, .border = .{ .radius = 3 }, .flex_shrink = 0 };
}
pub fn group() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = group_height }, .padding = .{ .left = 8, .right = 8 }, .direction = .row, .align_items = .center, .gap = 6, .background = ui.Color.TRANSPARENT, .border = .{ .radius = 7 }, .flex_shrink = 0 };
}
pub fn groupContent() ui.BoxStyle {
    var value = content();
    value.padding = .{ .left = 8, .right = 8 };
    value.gap = 6;
    return value;
}
pub fn badge() ui.BoxStyle {
    return .{ .width = .{ .fit = .{} }, .height = .{ .px = 14 }, .direction = .row, .align_items = .center, .justify = .center, .background = theme.current().well, .padding = .{ .left = 7, .right = 7 }, .border = .{ .radius = 8 }, .flex_shrink = 0 };
}
pub fn badgeText() ui.TextStyle {
    return .{ .font_size = 10, .font_weight = 400, .line_height = 1.4, .color = theme.current().fg_2, .selectable = false, .text_overflow = .clip };
}
pub fn badgeLabel() ui.BoxStyle {
    return .{ .height = .{ .px = 14 }, .flex_shrink = 0 };
}
pub fn menu(height: f32) ui.BoxStyle {
    return .{ .width = .{ .px = 258 }, .height = .{ .px = height }, .direction = .column, .gap = 1, .padding = ui.Padding.all(14), .background = theme.current().overlay, .border = .{ .radius = 11 }, .shadow = .{ .offset_y = 4, .blur = 10, .color = theme.current().shadow.withAlpha(if (theme.currentName() == .dark) 51 else if (theme.currentName() == .light) 18 else 20) } };
}
pub fn menuRow() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 30 }, .direction = .row, .align_items = .center, .justify = .start, .gap = 6, .padding = ui.Padding.all(6), .background = ui.Color.TRANSPARENT, .border = .{ .radius = 7 }, .flex_shrink = 0 };
}
pub fn hint() ui.BoxStyle {
    return .{ .padding = .{ .top = 8, .bottom = 8, .left = 10, .right = 10 }, .direction = .column, .gap = 4, .background = theme.current().overlay, .border = .{ .radius = 8 } };
}
pub fn rail(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = collapsed_width }, .height = .fill(), .direction = .column, .align_items = .center, .gap = 10, .padding = .{ .top = 12, .bottom = 8 }, .background = theme.current().surface_1, .border = .{ .radius = 11 }, .flex_shrink = 0 };
}
pub fn collectionEntry() ui.BoxStyle {
    var value = action(32);
    value.background = theme.current().accent;
    value.border = .{ .radius = 8 };
    return value;
}
pub fn detail() ui.BoxStyle {
    return .{ .width = .{ .px = 344 }, .height = .{ .px = 128 }, .min_height = 128, .direction = .column, .padding = .{ .top = 10, .bottom = 14, .left = 14, .right = 14 }, .gap = 0, .background = theme.current().overlay, .border = .{ .radius = 14 }, .shadow = .{ .offset_y = 4, .blur = 10, .color = theme.current().shadow.withAlpha(if (theme.currentName() == .dark) 51 else if (theme.currentName() == .light) 18 else 20) } };
}
pub fn repaint(node: *ui.Node, old: theme.Colors) void {
    node.setBackground(remap(node.getBackground(), old));
    node.setBorderColor(remap(node.style.border.color, old));
    if (node.getText()) |value| node.setTextColor(remap(value.color, old));
    if (node.getIcon()) |value| _ = node.setTint(remap(value.tint, old));
    if (node.getImage()) |value| _ = node.setTint(remap(value.tint, old));
    for (node.children.items) |child| repaint(child, old);
}
fn remap(value: ui.Color, old: theme.Colors) ui.Color {
    const current = theme.current();
    inline for (@typeInfo(theme.Colors).@"struct".field_names) |field| if (ui.Color.eql(value, @field(old, field))) return @field(current, field);
    return value;
}

pub fn railHost(selected: bool) ui.BoxStyle {
    var value = railAction(32);
    if (selected) {
        // Figma 231 selected rail: Dark #6164ec, Light/Sauber accent.
        // The selected surface is a light tint; status remains the icon tint.
        // Only the complete default Dark palette has the prototype's
        // #6164ec exception; custom palettes retain their own accent hue.
        value.background = (if (std.meta.eql(theme.baseColors(), theme.colors(.dark))) ui.Color.hex(0x6164ec) else theme.current().accent).withAlpha(64);
    }
    return value;
}
pub fn railDetail() ui.BoxStyle {
    return .{ .width = .{ .px = 320 }, .height = .{ .fit = .{} }, .direction = .column, .padding = ui.Padding.all(14), .gap = 8, .background = theme.current().overlay, .border = .{ .radius = 11 }, .flex_shrink = 0 };
}
pub fn railDetailButton(width: f32) ui.BoxStyle {
    return .{ .width = .{ .px = width }, .height = .{ .px = 30 }, .padding = ui.Padding.all(0), .font_size = 12, .font_weight = 500, .border = .{ .radius = 8 }, .flex_shrink = 0 };
}
