//! V3 shared feedback: 340px stack, CSS 10x12 padding, 9px radius,
//! 16px leading icon and 19px close control; host behavior stays coordinated.
const ui = @import("ui");
const theme = @import("app_theme.zig");
pub const edge = 12;
pub const width = 340;
pub const gap = 8;
pub fn overlay(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .position = .absolute, .direction = .column, .width = .{ .px = width }, .height = .{ .fit = .{} }, .gap = ui.arb.px(gap), .hit_behavior = .children_only, .z_index = 120 };
}
pub fn card(_: *const ui.ThemeTokens) ui.BoxStyle {
    // Zenit borders paint inside the box; include the CSS one-pixel border
    // in each content inset without shrinking the reference padding.
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .row, .align_items = .start, .padding = .{ .left = 13, .right = 13, .top = 11, .bottom = 11 }, .gap = ui.arb.px(9), .background = theme.current().overlay, .glass = theme.overlayGlass(), .border = .{ .width = 1, .color = theme.current().border, .radius = ui.arb.px(9) }, .shadow = .{ .offset_y = 24, .blur = 70, .color = theme.current().shadow }, .hit_behavior = .@"opaque", .flex_shrink = 0 };
}
pub fn header(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .min_width = 0, .direction = .column, .gap = 2, .flex = 1 };
}
pub fn title(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = ui.arb.px(12), .font_weight = 500, .line_height = 18.0 / 12.0, .color = theme.current().fg_1, .wrap = .word, .selectable = false };
}
pub fn detail(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = ui.arb.px(11), .line_height = 18.0 / 11.0, .color = theme.current().fg_2, .wrap = .word, .selectable = false };
}
pub fn textBox(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .min_width = 0, .height = .{ .fit = .{} }, .flex = 1 };
}
pub fn close(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = ui.arb.px(19) }, .height = .{ .px = ui.arb.px(19) }, .padding = .ZERO, .gap = 0, .align_items = .center, .justify = .center, .background = ui.Color.TRANSPARENT, .border = .{ .radius = ui.arb.px(7) }, .flex_shrink = 0 };
}
pub fn icon() ui.Style {
    return .{ .width = .{ .px = ui.arb.px(16) }, .height = .{ .px = ui.arb.px(16) }, .margin = .{ .top = ui.arb.px(1) }, .flex_shrink = 0 };
}
pub fn closeIcon() ui.Style {
    return .{ .width = .{ .px = ui.arb.px(12) }, .height = .{ .px = ui.arb.px(12) }, .flex_shrink = 0 };
}
pub fn actions(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .direction = .row, .width = .fill(), .height = .{ .fit = .{} }, .gap = ui.arb.px(8), .flex_wrap = .wrap };
}
pub fn action(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .height = .{ .fit = .{} }, .min_height = ui.arb.px(24), .flex_shrink = 0, .padding = .{ .left = ui.arb.px(6), .right = ui.arb.px(6), .top = 0, .bottom = 0 }, .background = ui.Color.TRANSPARENT };
}

pub fn actionLabel(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .line_height = 18.0 / 11.0, .color = theme.current().fg_1, .wrap = .word, .selectable = false };
}
