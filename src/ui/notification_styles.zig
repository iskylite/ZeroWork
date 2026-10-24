//! Bridge-read Vanta toast 236:563266 (2026-10-23), plus §6.1 host
//! specification: r14, 340px, inset12, 16px lead, 24px close hit area.
const ui = @import("ui");
const theme = @import("app_theme.zig");
pub const edge = 12;
pub const width = 340;
pub const gap = 8;
pub fn overlay(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .position = .absolute, .direction = .column, .width = .{ .px = width }, .height = .{ .fit = .{} }, .gap = ui.arb.px(gap), .hit_behavior = .children_only, .z_index = 120 };
}
pub fn card(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .min_height = ui.arb.px(48), .direction = .column, .padding = ui.Padding.all(ui.arb.px(edge)), .gap = ui.arb.px(4), .background = theme.current().overlay.withAlpha(240), .border = .{ .radius = ui.arb.px(14) }, .hit_behavior = .@"opaque", .flex_shrink = 0 };
}
pub fn header(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .direction = .row, .align_items = .center, .gap = ui.arb.px(4), .flex_shrink = 0 };
}
pub fn title(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = ui.arb.px(11.5), .font_weight = 500, .line_height = 18.0 / 11.5, .color = theme.current().fg_1, .wrap = .word, .selectable = false };
}
pub fn detail(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = ui.arb.px(11), .line_height = 17.0 / 11.0, .color = theme.current().fg_2, .wrap = .word, .selectable = false };
}
pub fn textBox(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .min_width = 0, .height = .{ .fit = .{} }, .flex = 1 };
}
pub fn close(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = ui.arb.px(24) }, .height = .{ .px = ui.arb.px(24) }, .padding = .ZERO, .gap = 0, .align_items = .center, .justify = .center, .background = ui.Color.TRANSPARENT, .border = .{ .radius = ui.arb.px(7) }, .flex_shrink = 0 };
}
pub fn icon() ui.Style {
    return .{ .width = .{ .px = ui.arb.px(16) }, .height = .{ .px = ui.arb.px(16) }, .flex_shrink = 0 };
}
pub fn closeIcon() ui.Style {
    return .{ .width = .{ .px = ui.arb.px(14) }, .height = .{ .px = ui.arb.px(14) }, .flex_shrink = 0 };
}
pub fn actions(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .direction = .row, .width = .fill(), .height = .{ .fit = .{} }, .gap = ui.arb.px(8) };
}
pub fn action(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .height = .{ .px = ui.arb.px(24) }, .padding = .{ .left = ui.arb.px(6), .right = ui.arb.px(6), .top = 0, .bottom = 0 }, .background = ui.Color.TRANSPARENT };
}
