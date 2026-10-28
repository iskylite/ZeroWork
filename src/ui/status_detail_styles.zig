const ui = @import("ui");
pub const theme = @import("app_theme.zig");
const shared = @import("connection_details_styles.zig");
pub const ButtonStyle = @FieldType(ui.widgets.ControlShellConfig, "style");

pub fn panel() ui.BoxStyle {
    const c = theme.current();
    return .{ .width = .fill(), .direction = .column, .padding = ui.Padding.all(12), .gap = 6, .background = c.overlay, .glass = theme.overlayGlass(), .border = .{ .width = 0, .color = c.border, .radius = 14 }, .shadow = .{ .offset_y = 24, .blur = 32, .color = c.shadow } };
}
pub fn header() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 28 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .gap = 6 };
}
pub fn body() ui.BoxStyle {
    return .{ .width = .fill(), .direction = .column, .gap = 6 };
}
pub fn row(height: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = height }, .flex_shrink = 0, .direction = .row, .align_items = .center, .gap = 8 };
}
pub fn text() ui.TextStyle {
    return .{ .font_size = 11.5, .line_height = 16.0 / 11.5, .color = theme.current().fg_2, .text_overflow = .ellipsis };
}
pub fn title() ui.TextStyle {
    return .{ .font_size = 13, .font_weight = 700, .line_height = 20.0 / 13.0, .color = theme.current().fg_1, .selectable = false };
}
pub fn value() ui.TextStyle {
    return .{ .font_size = 18, .font_weight = 600, .line_height = 24.0 / 18.0, .color = theme.current().fg_1, .selectable = false };
}

pub fn headerIcon() ui.BoxStyle {
    return .{ .width = .{ .px = 18 }, .height = .{ .px = 18 }, .flex_shrink = 0 };
}
pub fn infoRow() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 26 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .padding = .{ .left = 6, .right = 6 }, .gap = 6, .border = .{ .radius = 7 } };
}
pub fn infoText(secondary: bool) ui.TextStyle {
    return .{ .font_size = if (secondary) 10.5 else 11, .font_weight = if (secondary) 500 else 400, .line_height = if (secondary) 16.0 / 10.5 else 16.0 / 11.0, .color = if (secondary) theme.current().fg_2 else theme.current().fg_1, .text_align = if (secondary) .end else .start, .text_overflow = .ellipsis };
}
pub fn pointer(left: f32) ui.BoxStyle {
    return shared.pointer(left);
}
pub fn fade() ui.BoxStyle {
    return shared.fade();
}
pub fn action() ButtonStyle {
    return .{ .width = .fill(), .height = .{ .px = 26 }, .padding = .{}, .gap = 0, .direction = .row, .justify = .start, .align_items = .center, .corner_radius = 7, .border_width = 0, .background = theme.popupAction(), .flex_shrink = 0 };
}
pub fn actionContent() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .min_width = 0, .direction = .row, .align_items = .center, .padding = .{ .left = 6, .right = 6 }, .gap = 6 };
}
pub fn labelBox(h: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = h }, .min_width = 0, .flex = 1 };
}
pub fn trailingBox(width: f32) ui.BoxStyle {
    return .{ .width = .{ .px = width }, .height = .{ .px = 16 }, .flex_shrink = 0 };
}
pub fn close(local: bool) ButtonStyle {
    return shared.action(if (local) 24 else 26, false);
}
pub fn icon(size: f32) ui.Style {
    return shared.icon(size);
}
pub fn iconBox(size: f32) ui.BoxStyle {
    return .{ .width = .{ .px = size }, .height = .{ .px = size }, .flex_shrink = 0 };
}
pub fn hover() ButtonStyle {
    return shared.hover();
}
pub fn localTitle() ui.TextStyle {
    var result = title();
    result.font_weight = 500;
    result.line_height = 18.0 / 13.0;
    return result;
}
pub fn localText(kind: enum { machine, shell, cwd }) ui.TextStyle {
    return .{ .font_size = if (kind == .cwd) 11 else 12, .font_weight = if (kind == .machine) 500 else 400, .line_height = 18.0 / @as(f32, if (kind == .cwd) 11 else 12), .color = if (kind == .cwd) theme.current().fg_2 else theme.current().fg_1, .use_monospace_font = kind != .machine, .text_overflow = .ellipsis, .selectable = true };
}
