//! The group adds a header and soft top/bottom edges, never an enclosing card.
const ui = @import("ui");
const theme = @import("app_theme.zig");
pub const steps = @import("ai_tool_results_styles.zig");
pub fn root(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .flex_shrink = 0 };
}
pub fn header(tokens: *const ui.ThemeTokens) ui.BoxStyle {
    var style = steps.header(tokens);
    style.background = theme.popupAction();
    return style;
}
pub fn content(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 6, .padding = .{ .top = 6, .bottom = 6 }, .flex_shrink = 0 };
}
pub fn summary(tokens: *const ui.ThemeTokens) ui.BoxStyle {
    var style = steps.headerSummary(tokens);
    style.direction = .row;
    style.align_items = .center;
    style.gap = 6;
    return style;
}
pub fn count(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .fit = .{} }, .height = .{ .px = 16 }, .flex_shrink = 0 };
}
pub fn edge(_: *const ui.ThemeTokens) ui.BoxStyle {
    const ink = theme.current().fg_2;
    // A soft multi-stop falloff replaces CSS's tiny blurred gradient. No blur
    // is applied to the cards, text, or the background beneath the group.
    return .{ .position = .absolute, .width = .fill(), .height = .{ .px = 6 }, .border = .{ .width = 0, .radius = 3 }, .multi_gradient = ui.MultiGradient.fromSlice(&.{
        .{ .color = ink.withAlpha(0), .position = 0 },
        .{ .color = ink.withAlpha(2), .position = 0.12 },
        .{ .color = ink.withAlpha(12), .position = 0.28 },
        .{ .color = ink.withAlpha(20), .position = 0.42 },
        .{ .color = ink.withAlpha(10), .position = 0.62 },
        .{ .color = ink.withAlpha(2), .position = 0.82 },
        .{ .color = ink.withAlpha(0), .position = 1 },
    }, .vertical) };
}
