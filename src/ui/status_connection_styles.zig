//! V3 workspace identity popover: 344px, labeled facts and fixed actions.
//! Status triggers: 358:1407192; retained fixed hit areas and icon positions.
const ui = @import("ui");
pub const identity_width: f32 = 118;
const shared = @import("connection_details_styles.zig");
pub const theme = shared.theme;
pub const ButtonStyle = shared.ButtonStyle;
pub const width: f32 = 380;
// Duration shares the session row; the existing route summary adds one 27px row.
pub const height: f32 = 348;
pub const margin: f32 = 8;
pub const anchor_gap: f32 = 6;

pub fn wrapper() ui.BoxStyle {
    return shared.wrapper();
}
pub fn panel(h: f32, viewport_width: f32) ui.BoxStyle {
    var result = shared.panel(h, viewport_width);
    result.width = .{ .px = @min(width, @max(0, viewport_width - margin * 2)) };
    result.gap = 0;
    result.padding = ui.Padding.all(16);
    result.border = .{ .radius = 11 };
    return result;
}
pub fn content() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .min_height = 0, .direction = .column, .gap = 0 };
}
pub fn header() ui.BoxStyle {
    var result = shared.header();
    result.height = .{ .px = 28 };
    return result;
}
pub fn body() ui.BoxStyle {
    var result = shared.stack();
    result.gap = 9;
    return result;
}
pub fn info() ui.BoxStyle {
    return shared.row(18);
}
pub fn row(h: f32) ui.BoxStyle {
    return shared.row(h);
}
pub fn scroll() ui.BoxStyle {
    return shared.scroll();
}
pub fn title() ui.TextStyle {
    return shared.text(15, 600, 20, false);
}
pub fn titleBox() ui.BoxStyle {
    return .{ .width = .{ .px = 88 }, .height = .{ .px = 20 }, .flex_shrink = 0 };
}
pub fn infoText(is_trailing: bool) ui.TextStyle {
    var style = shared.text(12, 400, 18, is_trailing);
    style.color = if (is_trailing) theme.current().fg_1 else theme.current().fg_2;
    style.text_align = if (is_trailing) .end else .start;
    style.selectable = is_trailing;
    return style;
}
pub fn labelBox() ui.BoxStyle {
    return shared.infoLabel();
}
pub fn trailing() ui.BoxStyle {
    return shared.trailing();
}
pub fn address() ui.TextStyle {
    var result = shared.text(12, 400, 18, true);
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
    return .{ .position = .absolute, .inset = .{ .left = .{ .px = 138 }, .top = .{ .px = 6 } }, .width = .{ .px = 14 }, .height = .{ .px = 14 } };
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

pub fn factLabel() ui.BoxStyle {
    return .{ .width = .{ .px = 48 }, .height = .{ .px = 18 }, .flex_shrink = 0 };
}
pub fn factValue() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 18 }, .min_width = 0, .flex = 1 };
}
pub fn footer() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 45 }, .direction = .row, .gap = 8, .align_items = .center, .padding = .{ .top = 12, .bottom = 2 }, .flex_shrink = 0 };
}
pub fn textAction(w: f32, surface: bool) ButtonStyle {
    var style = shared.action(30, surface);
    style.width = .{ .px = w };
    style.text_color = theme.current().fg_1;
    style.font_size = 13;
    style.corner_radius = 8;
    return style;
}
