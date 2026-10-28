//! Figma Bridge 236:554015 / 236:554260 / 236:554505.
const ui = @import("ui");
const theme = @import("app_theme.zig");

pub const panel_width: f32 = 360;
pub const panel_height: f32 = 44;
pub const pane_top: f32 = 12;
pub const pane_right: f32 = 14;
pub const padding: f32 = 6;
pub const field_height: f32 = 32;
pub const action_size: f32 = 24;
pub const action_icon_size: f32 = 16;

pub fn panelPaint() ui.BoxStyle {
    return .{ .background = theme.current().overlay, .glass = theme.overlayGlass(), .border_color = ui.Color.TRANSPARENT, .shadow = .{ .blur = 32, .offset_y = 12, .color = theme.current().shadow } };
}
pub fn panel() ui.BoxStyle {
    var value = panelPaint();
    value.position = .absolute;
    value.inset = .{ .top = .{ .px = pane_top }, .right = .{ .px = pane_right } };
    value.width = .{ .px = panel_width };
    value.height = .{ .px = panel_height };
    value.border = .{ .width = 0, .color = ui.Color.TRANSPARENT, .radius = 14 };
    value.padding = ui.Padding.all(padding);
    value.z_index = 30;
    return value;
}
pub fn row() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = field_height }, .direction = .row, .align_items = .center, .gap = 4, .flex_shrink = 0, .min_width = 0 };
}
pub fn counter() ui.TextStyle {
    return .{ .font_size = 11, .line_height = 16.0 / 11.0, .font_weight = 400, .color = theme.current().fg_2, .selectable = false };
}
pub fn counterBox() ui.BoxStyle {
    return .{ .width = .{ .px = 38 }, .height = .{ .px = 16 }, .flex_shrink = 0 };
}
pub fn buttonPaint() ui.BoxStyle {
    return .{ .background = ui.Color.TRANSPARENT, .border_color = ui.Color.TRANSPARENT };
}
pub fn button() ui.BoxStyle {
    var value = buttonPaint();
    value.width = .{ .px = action_size };
    value.height = .{ .px = action_size };
    value.padding = ui.Padding.ZERO;
    value.align_items = .center;
    value.justify = .center;
    value.border = .{ .width = 0, .color = ui.Color.TRANSPARENT, .radius = 8 };
    value.flex_shrink = 0;
    return value;
}
pub fn focusRing() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .position = .absolute, .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 }, .right = .{ .px = 0 }, .bottom = .{ .px = 0 } }, .background = ui.Color.TRANSPARENT, .border = .{ .width = 0, .color = ui.Color.TRANSPARENT, .radius = 8 }, .hit_behavior = .pass_through };
}
pub fn tuneInput(input: ui.widgets.input.InputResult) void {
    input.state.font_size = 12;
    input.state.line_height = 18;
    input.state.char_width = 7.2;
    input.state.padding_h = 12;
    input.state.dirty = true;
    input.node.setStyleInline(input.state.allocator, .{ .width = .{ .grow = .{ .min = 0 } }, .height = .{ .px = field_height }, .flex_shrink = 1, .gap = 0, .min_width = 0 });
    input.input_container.setStyleInline(input.state.allocator, .{ .width = .fill(), .height = .{ .px = field_height }, .padding = ui.Padding.ZERO, .border = .{ .width = 0, .color = ui.Color.TRANSPARENT, .radius = 8 } });
    if (input.state.text_display_node) |text| if (text.getText()) |old| {
        var next = old;
        next.font_size = 12;
        next.line_height = 1.5;
        next.font_weight = 400;
        next.use_monospace_font = false;
        text.setText(next);
        text.setStyleInline(input.state.allocator, .{ .padding = .{ .left = 12 } });
    };
}
pub fn paintInput(cx: *ui.Cx, input: ui.widgets.input.InputResult, focus_ring: *ui.Node) void {
    const c = theme.current();
    input.state.tokens = cx.tokens;
    input.state.placeholder_color = c.fg_2;
    input.state.dirty = true;
    input.input_container.setBackground(if (input.state.focused) theme.popupSelection() else theme.popupInset());
    input.input_container.setBorderColor(ui.Color.TRANSPARENT);
    focus_ring.setStyleInline(cx.allocator, .{ .border = .{ .width = 0, .color = ui.Color.TRANSPARENT, .radius = 8 } });
    input.input_container.markRenderDirty();
}
