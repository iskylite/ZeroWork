//! Live Figma R25 603:313828/609:314745..764 and local text 373:1764836.
//! Local preview 373:1765190, fixed body viewport 415:1876847.
//! VT preview 373:1765723/source-info 415:1877078; same 572×194 geometry.
const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub const ButtonStyle = @FieldType(ui.widgets.ControlShellConfig, "style");
pub const rail_height: f32 = 44;
pub const input_gap: f32 = 4;
pub const preview_width: f32 = 572;
pub const preview_height: f32 = 194;
pub const preview_body_height: f32 = 104;
pub const icon_size: f32 = 16;
pub const heading_icon_size: f32 = 14;
pub fn wrapper(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = rail_height + input_gap }, .flex_shrink = 0, .direction = .column, .padding = .{ .left = 14, .right = 14, .bottom = input_gap } };
}
pub fn viewport() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = rail_height }, .flex_shrink = 0, .min_width = 0 };
}
pub fn rail() ui.BoxStyle {
    return .{ .width = .{ .fit = .{} }, .height = .{ .px = rail_height }, .flex_shrink = 0, .direction = .row, .gap = 6, .align_items = .center };
}
pub fn card(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = 184 }, .height = .{ .px = rail_height }, .flex_shrink = 0, .background = theme.current().surface_2, .border = .{ .radius = 8 } };
}
pub fn previewButton() ButtonStyle {
    return .{ .width = .{ .px = 28 }, .height = .{ .px = 28 }, .padding = .{}, .gap = 0, .corner_radius = 6, .background = theme.current().well, .flex_shrink = 0 };
}
pub fn iconButton() ButtonStyle {
    return .{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .padding = .{}, .gap = 0, .corner_radius = 7, .background = ui.Color.TRANSPARENT, .flex_shrink = 0 };
}
pub fn hover() ButtonStyle {
    return .{ .background = theme.current().hover };
}
pub fn previewSlot() ui.BoxStyle {
    return slot(8, 8, 28, 28);
}
pub fn filenameSlot() ui.BoxStyle {
    var value = slot(44, 6, 108, 15);
    value.overflow = .hidden;
    value.overflow_hidden = true;
    value.min_width = 0;
    value.max_width = 108;
    return value;
}
pub fn filenameTrigger() ui.BoxStyle {
    return .{ .width = .{ .px = 108 }, .height = .{ .px = 15 }, .min_width = 0, .max_width = 108, .flex_shrink = 0, .overflow = .hidden, .overflow_hidden = true };
}
pub fn metadataSlot() ui.BoxStyle {
    return slot(44, 24, 132, 14);
}
pub fn removeSlot() ui.BoxStyle {
    return slot(158, 2, 22, 22);
}
pub fn filename(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10.5, .font_weight = 400, .line_height = 15.0 / 10.5, .color = theme.current().fg_1, .text_overflow = .ellipsis };
}
pub fn metadata(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 9.5, .font_weight = 400, .line_height = 14.0 / 9.5, .color = theme.current().fg_2, .text_overflow = .ellipsis };
}
pub fn invisibleWrapper() ui.BoxStyle {
    return .{ .position = .absolute, .width = .{ .px = 0 }, .height = .{ .px = 0 } };
}
pub fn previewPanel() ui.BoxStyle {
    return .{ .width = .{ .px = preview_width }, .height = .{ .px = preview_height }, .direction = .column, .gap = 4, .padding = .{}, .background = theme.current().overlay, .border = .{ .radius = 11, .width = 0 }, .hit_behavior = .@"opaque" };
}
pub fn inlinePreview(_: *const ui.ThemeTokens) ui.BoxStyle {
    return inlinePanel();
}
pub fn inlinePanel() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = preview_height }, .flex_shrink = 0, .direction = .column, .gap = 4, .padding = .{}, .background = ui.Color.TRANSPARENT, .border = .{ .radius = 11, .width = 0 } };
}
pub fn inlineHolder(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .flex_shrink = 0, .direction = .column, .padding = .{ .left = 14, .right = 14 } };
}
pub fn heading(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 24 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .gap = 4 };
}
pub fn headingText(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11.5, .font_weight = 500, .line_height = 18.0 / 11.5, .color = theme.current().fg_1 };
}
pub fn identity(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 32 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .gap = 4, .padding = .{ .left = 8, .right = 6 }, .background = theme.current().well, .border = .{ .radius = 8 } };
}
pub fn identityText(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10.5, .font_weight = 400, .line_height = 16.0 / 10.5, .color = theme.current().fg_1, .text_overflow = .ellipsis };
}
pub fn fillLabel() ui.BoxStyle {
    return .{ .width = .fill(), .flex = 1, .min_width = 0 };
}
pub fn source(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 22 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .gap = 4 };
}
pub fn sourceText(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10.5, .font_weight = 400, .line_height = 16.0 / 10.5, .color = theme.current().fg_2, .text_overflow = .ellipsis };
}
pub fn infoSlot() ui.BoxStyle {
    return .{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .flex_shrink = 0 };
}
pub fn infoTrigger() ui.BoxStyle {
    return .{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .direction = .row, .align_items = .center, .justify = .center, .border = .{ .radius = 6 } };
}
pub fn bodyViewport() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = preview_body_height }, .flex_shrink = 0, .min_width = 0 };
}
pub fn bodyContent() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .flex_shrink = 0, .padding = .{ .left = 8, .right = 8, .top = 8, .bottom = 8 } };
}
pub fn bodyText(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10.5, .font_weight = 400, .line_height = 17.0 / 10.5, .color = theme.current().fg_1, .wrap = .word, .use_monospace_font = true };
}
fn slot(x: f32, y: f32, width: f32, height: f32) ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .left = .{ .px = x }, .top = .{ .px = y } }, .width = .{ .px = width }, .height = .{ .px = height }, .flex_shrink = 0 };
}
