//! Compact feedback uses the notification list's typography and text alignment.
const ui = @import("ui");
const theme = @import("app_theme.zig");
pub const edge = 12;
pub const width = 340;
pub const gap = 8;
pub fn overlay(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .position = .absolute, .direction = .column, .width = .{ .px = width }, .height = .{ .fit = .{} }, .gap = ui.arb.px(gap), .hit_behavior = .children_only, .z_index = 120 };
}
pub fn card(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .align_items = .stretch, .padding = .{ .left = 16, .right = 16, .top = 12, .bottom = 12 }, .gap = 4, .background = theme.current().overlay, .glass = theme.overlayGlass(), .border = .{ .width = 0, .radius = ui.arb.px(12) }, .shadow = .{ .offset_y = 16, .blur = 40, .color = theme.current().shadow }, .hit_behavior = .@"opaque", .flex_shrink = 0 };
}
pub fn body(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .min_width = 0, .direction = .column, .padding = .{ .left = 22 }, .gap = 4, .flex_shrink = 0 };
}
pub fn header(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .min_width = 0, .direction = .row, .align_items = .center, .gap = 8 };
}
pub fn title(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = ui.arb.px(12), .font_weight = 500, .line_height = 18.0 / 12.0, .color = theme.current().fg_1, .text_overflow = .ellipsis, .selectable = false };
}
pub fn detail(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = ui.arb.px(11), .line_height = 18.0 / 11.0, .color = theme.current().fg_2, .text_overflow = .ellipsis, .selectable = false };
}
pub fn textBox(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .min_width = 0, .height = .{ .px = 18 }, .flex = 1 };
}
pub fn close(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = ui.arb.px(19) }, .height = .{ .px = ui.arb.px(19) }, .padding = .ZERO, .gap = 0, .align_items = .center, .justify = .center, .background = ui.Color.TRANSPARENT, .border = .{ .radius = ui.arb.px(7) }, .flex_shrink = 0 };
}
pub fn icon() ui.Style {
    return .{ .width = .{ .px = ui.arb.px(14) }, .height = .{ .px = ui.arb.px(14) }, .flex_shrink = 0 };
}
pub fn closeIcon() ui.Style {
    return .{ .width = .{ .px = ui.arb.px(12) }, .height = .{ .px = ui.arb.px(12) }, .flex_shrink = 0 };
}
pub fn actions(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .direction = .row, .width = .fill(), .height = .{ .fit = .{} }, .flex = 1, .min_width = 0, .justify = .end, .gap = ui.arb.px(8), .flex_wrap = .wrap };
}
pub fn action(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .height = .{ .px = 24 }, .flex_shrink = 0, .padding = .{ .left = 10, .right = 10 }, .gap = 0, .align_items = .center, .justify = .center, .background = theme.current().action_accent, .border = .{ .radius = 6 } };
}

pub fn actionLabel(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .font_weight = 500, .line_height = 1.5, .color = theme.current().accent_ink, .text_overflow = .ellipsis, .selectable = false };
}

pub fn line(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .line_height = 18.0 / 11.0, .color = theme.current().fg_2, .text_overflow = .ellipsis, .selectable = false };
}
pub fn lineBox(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 18 }, .min_width = 0, .overflow = .hidden, .flex_shrink = 0 };
}
pub fn footer(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .direction = .row, .align_items = .center, .gap = 8, .flex_shrink = 0 };
}
pub fn statusInk(severity: u8) ui.Color {
    const c = theme.current();
    return switch (severity) {
        1 => c.ok_ink,
        2 => c.warn_ink,
        3 => c.danger_ink,
        else => c.fg_2,
    };
}
pub fn statusTag(severity: u8) ui.BoxStyle {
    const c = theme.current();
    const color = switch (severity) {
        1 => c.ok,
        2 => c.warn,
        3 => c.danger,
        else => c.fg_2,
    };
    return .{ .height = .{ .px = 20 }, .direction = .row, .align_items = .center, .padding = .{ .left = 6, .right = 6 }, .background = color.withAlpha(23), .border = .{ .radius = 4, .width = 0 }, .flex_shrink = 0 };
}
pub fn actionHover() ui.BoxStyle {
    return .{ .background = theme.current().action_accent_2 };
}

pub fn secondaryAction(tokens: *const ui.ThemeTokens) ui.BoxStyle {
    var style = action(tokens);
    style.background = theme.popupAction();
    style.border = .{ .radius = 6, .width = 0 };
    return style;
}
