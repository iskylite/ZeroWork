//! Live Bridge: 297:532457 / 358:1407255, 360×208 session connection.
//! Status triggers: 358:1407192; retained fixed hit areas and icon positions.
const ui = @import("ui");
pub const identity_width: f32 = 112;
const shared = @import("connection_details_styles.zig");
pub const theme = shared.theme;
pub const ButtonStyle = shared.ButtonStyle;
pub const width: f32 = 360;
pub const height: f32 = 208;
pub const margin: f32 = 8;
pub const anchor_gap: f32 = 6;

pub fn wrapper() ui.BoxStyle {
    return shared.wrapper();
}
pub fn panel(h: f32, viewport_width: f32) ui.BoxStyle {
    var result = shared.panel(h, viewport_width);
    result.width = .{ .px = @min(width, @max(0, viewport_width - margin * 2)) };
    result.gap = 6;
    result.padding = ui.Padding.all(12);
    return result;
}
pub fn content() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .min_height = 0, .direction = .column, .gap = 6 };
}
pub fn header() ui.BoxStyle {
    var result = shared.header();
    result.height = .{ .px = 28 };
    return result;
}
pub fn body() ui.BoxStyle {
    return shared.stack();
}
pub fn info() ui.BoxStyle {
    return shared.info();
}
pub fn row(h: f32) ui.BoxStyle {
    return shared.row(h);
}
pub fn scroll() ui.BoxStyle {
    return shared.scroll();
}
pub fn title() ui.TextStyle {
    return shared.title();
}
pub fn titleBox() ui.BoxStyle {
    return .{ .width = .{ .px = 72 }, .height = .{ .px = 20 }, .flex_shrink = 0 };
}
pub fn infoText(is_trailing: bool) ui.TextStyle {
    return shared.infoText(is_trailing);
}
pub fn labelBox() ui.BoxStyle {
    return shared.infoLabel();
}
pub fn trailing() ui.BoxStyle {
    return shared.trailing();
}
pub fn address() ui.TextStyle {
    var result = shared.text(11, 400, 18, true);
    result.color = theme.current().fg_1;
    result.selectable = true;
    return result;
}
pub fn addressBox() ui.BoxStyle {
    return shared.labelBox(18);
}
pub fn action(size: f32, surface: bool) ButtonStyle {
    return shared.action(size, surface);
}
pub fn hover() ButtonStyle {
    return shared.hover();
}
pub fn icon(size: f32) ui.Style {
    return shared.icon(size);
}
pub fn fade() ui.BoxStyle {
    return shared.fade();
}
pub fn pointer(left: f32) ui.BoxStyle {
    return shared.pointer(left);
}
pub fn feedbackBox() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 16 }, .min_width = 0, .flex = 1 };
}

pub fn identityTrigger() ButtonStyle {
    return .{ .width = .{ .px = identity_width }, .height = .{ .px = 26 }, .padding = .{}, .gap = 0, .corner_radius = 7, .background = ui.Color.TRANSPARENT, .border_width = 0, .flex_shrink = 0 };
}
pub fn triggerIcon() ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .left = .{ .px = 8 }, .top = .{ .px = 6 } }, .width = .{ .px = 14 }, .height = .{ .px = 14 } };
}
pub fn triggerDot() ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .left = .{ .px = 18.5 }, .top = .{ .px = 10.5 } }, .width = .{ .px = 5 }, .height = .{ .px = 5 }, .border = .{ .radius = 2.5 } };
}
pub fn triggerName() ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .left = .{ .px = 29.5 }, .top = .{ .px = 5 } }, .width = .{ .px = 44 }, .height = .{ .px = 16 }, .overflow_hidden = true };
}
pub fn triggerChevron() ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .left = .{ .px = 79.5 }, .top = .{ .px = 6 } }, .width = .{ .px = 14 }, .height = .{ .px = 14 } };
}
pub fn metricTrigger(w: f32) ButtonStyle {
    var result = identityTrigger();
    result.width = .{ .px = w };
    return result;
}
pub fn metricIcon() ui.BoxStyle {
    var result = triggerIcon();
    result.inset = .{ .left = .{ .px = 7 }, .top = .{ .px = 6 } };
    return result;
}
pub fn metricLabel(w: f32) ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .left = .{ .px = 27 }, .top = .{ .px = 5 } }, .width = .{ .px = w - 34 }, .height = .{ .px = 16 }, .overflow_hidden = true };
}
pub fn triggerText(primary: bool) ui.TextStyle {
    return shared.text(if (primary) 11 else 10.5, if (primary) 500 else 400, 16, false);
}

pub fn staticMetric(w: f32) ui.BoxStyle {
    return .{ .width = .{ .px = w }, .height = .{ .px = 26 }, .flex_shrink = 0 };
}
