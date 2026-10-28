//! User-approved read-only log modal using the existing Vanta modal chrome.
//! Log well: Figma 233:339485 (728×124, p12, r9); text:
//! I233:339486;233:339409 (JetBrains Mono 10, line height 16).
const ui = @import("ui");
const progress_styles = @import("connection_progress_styles.zig");
pub const theme = @import("app_theme.zig");
pub const ButtonStyle = @FieldType(ui.widgets.ControlShellConfig, "style");
// The independent log reader retains its approved diagnostic viewport.
pub const width: f32 = 760;
pub const header_height: f32 = 40;
pub const identity_height: f32 = 24;
pub const meta_height: f32 = 16;
pub const well_height: f32 = 124;
pub const footer_height: f32 = 34;
pub const margin: f32 = 8;
// Content-hug: existing chrome + identity + metadata + the exact 124px well.
pub const height: f32 = header_height + 8 + identity_height + 6 + meta_height + 6 + well_height + 12 + footer_height + 12;

pub fn panel(viewport: ui.Size) ui.BoxStyle {
    var result = progress_styles.panel(@min(height, @max(160, viewport.height - margin * 2)), viewport.width);
    result.width = .{ .px = @min(width, @max(0, viewport.width - margin * 2)) };
    return result;
}
pub fn form() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .direction = .column, .padding = .{}, .gap = 0, .min_height = 0 };
}
pub fn header() ui.BoxStyle {
    return progress_styles.header();
}
pub fn body() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0, .direction = .column, .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 12 }, .gap = 6 };
}
pub fn row(h: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = h }, .direction = .row, .align_items = .center, .gap = 8, .flex_shrink = 0 };
}
pub fn titleBox() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 20 }, .flex = 1, .min_width = 0 };
}
pub fn labelBox(h: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = h }, .min_width = 0, .flex_shrink = 0 };
}
pub fn feedbackBox() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 16 }, .flex = 1, .min_width = 0 };
}
pub fn well() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0, .background = theme.current().well, .border = .{ .radius = 9 }, .overflow_hidden = true };
}
pub fn logContent() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .padding = ui.Padding.all(12), .gap = 0, .flex_shrink = 0 };
}
pub fn logTextBox() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .min_width = 0, .flex_shrink = 0 };
}
pub fn logs() ui.TextStyle {
    return .{ .font_size = 10.5, .font_weight = 400, .line_height = 16.0 / 10.5, .color = theme.current().fg_1, .use_monospace_font = true, .wrap = .char, .selectable = true, .text_overflow = .clip };
}
pub fn title() ui.TextStyle {
    return progress_styles.text(13, 700, false);
}
pub fn identity() ui.TextStyle {
    var result = progress_styles.text(11, 400, true);
    result.color = theme.current().fg_1;
    result.selectable = true;
    return result;
}
pub fn meta() ui.TextStyle {
    return progress_styles.text(11, 400, false);
}
pub fn footer() ui.BoxStyle {
    var result = row(footer_height);
    // The log viewport gets the remaining height; these controls never scroll.
    result.margin = .{ .top = 6 };
    return result;
}
pub fn button(w: f32, h: f32, primary: bool) ButtonStyle {
    return .{ .width = .{ .px = w }, .height = .{ .px = h }, .padding = .{}, .gap = 0, .corner_radius = 8, .border_width = 0, .background = if (primary) theme.current().accent else theme.current().surface_2, .flex_shrink = 0 };
}
pub fn closeIcon() ButtonStyle {
    var result = button(22, 22, false);
    result.background = ui.Color.TRANSPARENT;
    return result;
}
pub fn hover() ButtonStyle {
    return .{ .background = theme.current().hover };
}
pub fn icon(size: f32) ui.Style {
    return progress_styles.icon(size);
}
