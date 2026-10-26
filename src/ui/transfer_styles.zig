//! Current transfer contract: 76px shallow cards, direct actions and hover details.
const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub const path_line_height: f32 = 18;
// Existing header 48 + inner top/bottom 8/16 + footer gap/height 10/34.
// Body height is measured from its real children, including validation errors.
pub const confirmation_chrome_height: f32 = 48 + 8 + 16 + 10 + 34;
pub const row_height: f32 = 76;
pub const row_pitch: f32 = 84;
pub const detail_height: f32 = 176;
pub fn panel(window: bool) ui.BoxStyle {
    return .{ .width = .{ .px = if (window) 840 else 620 }, .height = .{ .px = if (window) 578 else 330 }, .direction = .column, .padding = .{ .top = 17, .left = 14, .right = 14, .bottom = if (window) 16 else 18 }, .background = theme.current().overlay, .border = .{ .radius = 14 }, .overflow = .hidden, .flex_shrink = 0 };
}
pub fn row(h: f32, spacing: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = h }, .direction = .row, .align_items = .center, .gap = spacing, .min_width = 0, .flex_shrink = 0 };
}
pub fn stack() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .direction = .column, .min_width = 0, .min_height = 0 };
}
pub fn gap(h: f32) ui.BoxStyle {
    return .{ .height = .{ .px = h }, .flex_shrink = 0 };
}
pub fn text(size: f32, weight: u16, secondary: bool) ui.TextStyle {
    return .{ .font_size = size, .font_weight = weight, .line_height = 1.5, .color = if (secondary) theme.current().fg_2 else theme.current().fg_1 };
}
pub fn label(w: f32) ui.BoxStyle {
    return .{ .width = .{ .px = w }, .min_width = 0, .flex_shrink = 0, .overflow = .hidden };
}
pub fn flexibleLabel() ui.BoxStyle {
    return .{ .width = .fill(), .min_width = 0, .flex = 1, .overflow = .hidden };
}
pub fn icon(size: f32) ui.Style {
    return .{ .width = .{ .px = size }, .height = .{ .px = size }, .flex_shrink = 0 };
}
pub fn action(size: f32) ui.BoxStyle {
    return .{ .width = .{ .px = size }, .height = .{ .px = size }, .padding = .{}, .align_items = .center, .justify = .center, .background = ui.Color.TRANSPARENT, .border = .{ .radius = 7 }, .flex_shrink = 0 };
}
pub fn badge(width: f32, color: ui.Color) ui.BoxStyle {
    return .{ .width = .{ .px = width }, .height = .{ .px = 22 }, .padding = .{ .left = 8, .right = 8 }, .align_items = .center, .justify = .center, .background = color.withAlpha(25), .border = .{ .radius = 6 }, .flex_shrink = 0 };
}
pub fn task(selected: bool) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = row_height }, .direction = .column, .gap = 7, .padding = .{ .top = 9, .left = 10, .right = 10, .bottom = 9 }, .background = if (selected) theme.current().selection else theme.current().surface_2, .border = .{ .radius = 8 }, .flex_shrink = 0 };
}
pub fn detail() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 120 }, .direction = .column, .gap = 4, .padding = .{ .top = 8, .left = 10, .right = 10, .bottom = 8 }, .background = ui.Color.TRANSPARENT, .border = .{ .radius = 8 }, .flex_shrink = 0, .overflow = .hidden };
}
pub fn track() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 3 }, .background = theme.current().well, .border = .{ .radius = 1 }, .flex_shrink = 0 };
}
pub fn fill(fraction: f32, color: ui.Color) ui.BoxStyle {
    return .{ .width = .{ .percent = fraction * 100 }, .height = .fill(), .background = color, .border = .{ .radius = 1 } };
}
pub fn viewport() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0, .min_width = 0 };
}
// Vanta empty list: use the available list viewport, with one centered status.
pub fn emptyState() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0, .min_width = 0, .direction = .column, .align_items = .center, .justify = .center, .gap = 12, .overflow = .hidden };
}
pub fn errorLine() ui.BoxStyle {
    return .{ .width = .fill(), .min_height = 24, .padding = .{ .top = 3, .bottom = 3 }, .flex_shrink = 0 };
}

pub fn repaint(node: *ui.Node, previous: theme.Colors) void {
    node.setBackground(remap(node.getBackground(), previous));
    if (node.getText()) |text_value| node.setTextColor(remap(text_value.color, previous));
    if (node.getIcon()) |icon_value| _ = node.setTint(remap(icon_value.tint, previous));
    for (node.children.items) |child| repaint(child, previous);
}
fn remap(color: ui.Color, previous: theme.Colors) ui.Color {
    const next = theme.current();
    inline for (@typeInfo(theme.Colors).@"struct".field_names) |field| {
        if (ui.Color.eql(color, @field(previous, field))) return @field(next, field);
    }
    return color;
}

pub fn confirmation(h: f32) ui.BoxStyle {
    return .{ .width = .{ .px = 520 }, .height = .{ .px = h }, .padding = .{}, .direction = .column, .background = theme.current().overlay, .border = .{ .radius = 14 }, .shadow = .{ .offset_y = 24, .blur = 32, .color = theme.current().shadow }, .overflow = .hidden };
}
pub fn confirmationHeader() ui.BoxStyle {
    var value = row(48, 6);
    value.padding = .{ .left = 16, .right = 14 };
    return value;
}
pub fn confirmationInner() ui.BoxStyle {
    var value = stack();
    value.flex = 1;
    value.padding = .{ .top = 8, .left = 16, .right = 16, .bottom = 16 };
    return value;
}
pub fn confirmationStack() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 10, .flex_shrink = 0 };
}
pub fn confirmationIdentity() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 4, .padding = ui.Padding.all(12), .background = theme.current().surface_2, .border = .{ .radius = 9 }, .flex_shrink = 0 };
}
pub fn confirmationSources() ui.BoxStyle {
    return confirmationStack();
}
pub fn confirmationHint() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 16 }, .flex_shrink = 0 };
}
pub fn pathRow() ui.BoxStyle {
    var value = row(32, 6);
    value.padding = .{ .left = 8, .right = 8 };
    value.background = theme.current().well;
    value.border = .{ .radius = 8 };
    return value;
}
pub fn option() ui.BoxStyle {
    return .{ .width = .{ .px = 98 }, .height = .{ .px = 24 }, .padding = .{}, .background = theme.current().surface_2, .border = .{ .radius = 7 }, .flex_shrink = 0 };
}
pub fn confirmationPrimary() ui.BoxStyle {
    return .{ .width = .{ .px = 120 }, .height = .{ .px = 34 }, .padding = .{}, .background = theme.current().action_accent, .border = .{ .radius = 8 }, .flex_shrink = 0 };
}
pub fn sourceHint() ui.BoxStyle {
    return .{ .direction = .column, .gap = 4, .padding = ui.Padding.all(8), .background = theme.current().overlay, .border = .{ .radius = 7 } };
}

pub fn topFade(_: *const ui.ThemeTokens) ui.BoxStyle {
    const c = theme.current();
    return .{ .width = .fill(), .height = .{ .px = 72 }, .position = .absolute, .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } }, .gradient = .{ .from = c.well_border.withAlpha(48), .to = c.overlay.withAlpha(0) }, .border = .{ .radius = 14 }, .hit_behavior = .pass_through };
}
pub fn grip(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .top = .{ .px = 7 }, .left = .{ .percent = 50 } }, .width = .{ .px = 32 }, .height = .{ .px = 3 }, .margin = .{ .left = -16 }, .background = theme.current().fg_3, .border = .{ .radius = 1.5 }, .hit_behavior = .pass_through };
}

// Shared compact transfer row and bounded popover presentations.
pub const v3_card_height: f32 = row_height;
pub const v3_card_pitch: f32 = row_pitch;
pub fn v3Panel(global: bool) ui.BoxStyle {
    // Transparent HTML border consumes 1px in addition to the 12px padding.
    return .{ .width = .{ .px = if (global) 720 else 680 }, .height = .{ .px = 199 }, .direction = .column, .padding = ui.Padding.all(13), .background = theme.current().overlay, .border = .{ .radius = 11 }, .overflow = .hidden, .flex_shrink = 0, .hit_behavior = .@"opaque" };
}
pub fn v3EmptyState() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .min_width = 0, .min_height = 0, .direction = .row, .align_items = .center, .gap = 10, .padding = .{ .top = 8, .bottom = 8, .left = 4, .right = 4 }, .overflow = .hidden };
}
pub fn v3EmptyIcon() ui.BoxStyle {
    return .{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .align_items = .center, .justify = .center, .flex_shrink = 0 };
}
pub fn v3Segment() ui.BoxStyle {
    var s = row(30, 3);
    s.padding = ui.Padding.all(3);
    s.background = theme.current().well;
    s.border = .{ .radius = 8 };
    return s;
}
pub fn v3Filter(selected: bool) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .padding = .{ .top = 4, .bottom = 4, .left = 8, .right = 8 }, .font_size = 11, .font_weight = 400, .text_color = if (selected) theme.current().accent_ink else theme.current().fg_2, .background = if (selected) theme.current().selection else theme.current().surface_2, .border = .{ .radius = 6 }, .shadow = .{}, .align_items = .center, .justify = .center };
}
pub fn v3Card() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = v3_card_height }, .direction = .column, .padding = .{ .left = 10, .right = 10, .top = 7, .bottom = 9 }, .background = theme.current().well, .border = .{ .radius = 7 }, .flex_shrink = 0 };
}
pub fn v3TextAction() ui.BoxStyle {
    return .{ .height = .{ .px = 24 }, .padding = .{ .left = 6, .right = 6, .top = 2, .bottom = 2 }, .font_size = 11, .font_weight = 400, .text_color = theme.current().accent_ink, .background = ui.Color.TRANSPARENT, .border = .{ .radius = 4 }, .shadow = .{}, .flex_shrink = 0 };
}

pub fn v3Footer() ui.BoxStyle {
    var s = row(38, 8);
    s.padding = .{ .top = 8 };
    return s;
}
pub fn v3FooterButton(primary: bool) ui.BoxStyle {
    return .{ .height = .{ .px = 30 }, .min_width = if (primary) 88 else 76, .padding = .{ .top = 6, .bottom = 6, .left = 10, .right = 10 }, .font_size = 11, .font_weight = 500, .text_color = if (primary) theme.actionForeground(theme.current().action_accent) else theme.current().fg_1, .background = if (primary) theme.current().action_accent else theme.current().hover, .border = .{ .radius = 8 }, .shadow = .{}, .flex_shrink = 0, .align_items = .center, .justify = .center };
}

/// Embedded SFTP tray shares exactly the same task renderer as both popovers.
pub fn sessionTray() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 127 }, .min_width = 0, .flex_shrink = 0, .direction = .column, .padding = .{ .top = 9, .right = 12, .bottom = 8, .left = 12 }, .background = theme.current().surface_1, .border = .{ .radius = 11 }, .overflow = .hidden };
}

pub fn hoverDetail() ui.BoxStyle {
    return .{ .width = .{ .px = 420 }, .height = .{ .fit = .{} }, .min_width = 0, .direction = .column, .gap = 12, .padding = ui.Padding.all(14), .background = theme.current().overlay, .border = .{ .radius = 10 }, .shadow = .{ .offset_y = 8, .blur = 28, .color = theme.current().shadow }, .overflow = .hidden };
}

pub fn hoverDetailField() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .min_width = 0, .direction = .column, .gap = 4, .flex_shrink = 0 };
}

pub fn hoverDetailIdentity() ui.BoxStyle {
    return .{ .width = .fill(), .min_width = 0, .padding = .{ .top = 7, .bottom = 7, .left = 8, .right = 8 }, .background = theme.current().well, .border = .{ .radius = 8 }, .flex_shrink = 0 };
}

pub fn optionTag(enabled: bool) ui.BoxStyle {
    return .{ .height = .{ .px = 24 }, .padding = .{ .left = 8, .right = 8, .top = 3, .bottom = 3 }, .background = (if (enabled) theme.current().ok else theme.current().fg_2).withAlpha(28), .border = .{ .radius = 5 }, .flex_shrink = 0 };
}
