//! Editable baseline: docs/UI_V3/app-update/{index.html,styles.css}.
const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub fn dialog(width: f32, height: f32, target: f32) ui.BoxStyle {
    // Modal's YSS declares corner_radius and shadows. Override those exact
    // fields: border.radius / shadow alone lose to its retained ext values.
    return .{ .width = .{ .px = @min(520, @max(1, width - 32)) }, .height = .{ .px = @min(target, @max(1, height - 32)) }, .padding = .ZERO, .background = theme.current().overlay, .glass = theme.overlayGlass(), .border = .{ .width = 0, .radius = 14 }, .corner_radius = 14, .shadows = ui.ShadowList.of(&.{.{ .offset_y = 24, .blur = 48, .color = theme.current().shadow }}) };
}
pub const Metrics = struct { padding: f32, body_top: f32, summary_gap: f32, summary_padding: f32, row_height: f32, footer_gap: f32 };
pub fn metrics(height: f32) Metrics {
    return if (height <= 600)
        .{ .padding = 16, .body_top = 10, .summary_gap = 10, .summary_padding = 10, .row_height = 30, .footer_gap = 12 }
    else
        .{ .padding = 20, .body_top = 14, .summary_gap = 14, .summary_padding = 12, .row_height = 34, .footer_gap = 18 };
}
pub fn body(height: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .direction = .column, .padding = .all(metrics(height).padding) };
}
pub fn text(size: f32, line: f32, weight: u16) ui.TextStyle {
    return .{ .font_size = size, .line_height = line / size, .font_weight = weight, .color = theme.current().fg_1, .wrap = .word, .selectable = false };
}
pub fn button(primary: bool, danger: bool, width: f32) ui.BoxStyle {
    return .{ .width = .{ .px = width }, .height = .{ .px = 32 }, .padding = .{ .left = 12, .right = 12 }, .gap = 0, .font_size = 12, .font_weight = 500, .text_color = if (primary) ui.Color.WHITE else theme.current().fg_1, .background = if (danger) theme.current().action_danger else if (primary) theme.current().action_accent else theme.popupAction(), .border = .{ .width = 0, .radius = 8 }, .flex_shrink = 0 };
}
pub fn summary(height: f32) ui.BoxStyle {
    const m = metrics(height);
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .margin = .{ .top = m.summary_gap, .bottom = m.summary_gap }, .padding = .all(m.summary_padding), .background = theme.current().surface_2, .border = .{ .width = 0, .radius = 10 }, .flex_shrink = 0 };
}

pub fn helpButton() ui.BoxStyle {
    return .{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .padding = .ZERO, .flex_shrink = 0 };
}
pub fn progress() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 18 }, .margin = .{ .top = 8 }, .flex_shrink = 0 };
}
