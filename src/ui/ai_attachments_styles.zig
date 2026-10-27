//! Live Figma R25 603:313828/609:314745..764 and local text 373:1764836.
//! Local preview 373:1765190, fixed body viewport 415:1876847.
//! VT preview 373:1765723/source-info 415:1877078; same 572×194 geometry.
const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub const ButtonStyle = @FieldType(ui.widgets.ControlShellConfig, "style");
pub const rail_height: f32 = 20;
pub const input_gap: f32 = 9;
pub const preview_width: f32 = 572;
pub const preview_height: f32 = 194;
pub const preview_body_height: f32 = 104;
pub const icon_size: f32 = 12;
pub const heading_icon_size: f32 = 14;
pub fn wrapper(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = rail_height + 5 }, .flex_shrink = 0, .direction = .column, .padding = .{ .bottom = 5 } };
}
pub fn viewport() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = rail_height }, .flex_shrink = 0, .min_width = 0 };
}
pub fn rail() ui.BoxStyle {
    return .{ .width = .{ .fit = .{} }, .height = .{ .px = rail_height }, .flex_shrink = 0, .direction = .row, .gap = 6, .align_items = .center };
}
pub fn card(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .fit = .{} }, .height = .{ .px = rail_height }, .direction = .row, .align_items = .center, .gap = 5, .padding = .{ .left = 6, .right = 6, .top = 3, .bottom = 3 }, .flex_shrink = 0, .background = theme.current().well, .border = .{ .radius = 5 } };
}
pub fn previewButton() ButtonStyle {
    return .{ .width = .{ .fit = .{} }, .min_width = 12, .height = .{ .px = 14 }, .padding = .{}, .gap = 0, .corner_radius = 6, .background = ui.Color.TRANSPARENT, .flex_shrink = 0 };
}
pub fn iconButton() ButtonStyle {
    return .{ .width = .{ .px = 18.6171875 }, .height = .{ .px = 14 }, .padding = .{}, .gap = 0, .corner_radius = 7, .background = ui.Color.TRANSPARENT, .flex_shrink = 0 };
}
pub fn hover() ButtonStyle {
    return .{ .background = theme.current().hover };
}
pub fn previewSlot() ui.BoxStyle {
    return .{ .width = .{ .fit = .{} }, .min_width = 12, .height = .{ .px = 14 }, .direction = .row, .align_items = .center, .gap = 5, .padding = .{}, .flex_shrink = 0 };
}
pub fn filenameSlot() ui.BoxStyle {
    return filenameTrigger();
}
pub fn filenameTrigger() ui.BoxStyle {
    return .{ .width = .{ .fit = .{} }, .height = .{ .px = 14 }, .max_width = 180, .min_width = 0, .flex_shrink = 0, .overflow = .hidden };
}
pub fn metadataSlot() ui.BoxStyle {
    return .{ .display = .none };
}
pub fn removeSlot() ui.BoxStyle {
    return .{ .width = .{ .px = 18.6171875 }, .height = .{ .px = 14 }, .padding = .{}, .flex_shrink = 0 };
}
pub fn filename(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10, .font_weight = 400, .line_height = 14.0 / 10.0, .color = theme.current().fg_1, .text_overflow = .ellipsis };
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
    return .{ .font_size = 13, .font_weight = 700, .line_height = 18.0 / 13.0, .color = theme.current().fg_1 };
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
    return .{ .width = .{ .px = 18.6171875 }, .height = .{ .px = 14 }, .flex_shrink = 0 };
}
pub fn infoTrigger() ui.BoxStyle {
    return .{ .width = .{ .px = 18.6171875 }, .min_width = 12, .height = .{ .px = 14 }, .direction = .row, .align_items = .center, .justify = .center, .border = .{ .radius = 6 } };
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
