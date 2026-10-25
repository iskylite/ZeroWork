//! V3 content-edge entry: 100×14, with three 4px status dots.
const ui = @import("ui");
const T = @import("app_theme.zig");
pub const State = enum { idle, working, approval, success, failed };
pub fn trigger() ui.BoxStyle {
    return .{ .position = .absolute, .width = .{ .px = 100 }, .height = .{ .px = 14 }, .padding = .{}, .background = ui.Color.TRANSPARENT, .align_items = .center, .justify = .center, .z_index = 40, .corner_radius = 7, .flex_shrink = 0 };
}
pub fn lip(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = 100 }, .height = .{ .px = 14 }, .padding = .{ .top = 2, .bottom = 2, .left = 7, .right = 7 }, .direction = .row, .justify = .center, .align_items = .center, .gap = 5, .background = ui.Color.TRANSPARENT, .gradient = .{ .from = ui.Color.rgba(255, 255, 255, 4), .to = ui.Color.rgba(255, 255, 255, 10), .direction = .vertical }, .glass = T.overlayGlass(), .border = .{ .width = 1, .color = ui.Color.rgba(255, 255, 255, 13), .radius = 12 }, .corner_radii = .{ .each = .{ 0, 0, 12, 12 } }, .shadow = .{ .offset_y = 3, .blur = 10, .color = ui.Color.rgba(0, 0, 0, 34) }, .flex_shrink = 0 };
}
pub fn activeLip(active: bool) ui.BoxStyle {
    return .{ .background = if (active) T.current().selection else ui.Color.TRANSPARENT, .gradient = .{ .from = if (active) ui.Color.TRANSPARENT else ui.Color.rgba(255, 255, 255, 4), .to = if (active) ui.Color.TRANSPARENT else ui.Color.rgba(255, 255, 255, 10), .direction = .vertical } };
}
pub fn dot(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = 4 }, .height = .{ .px = 4 }, .background = T.current().accent_ink, .border = .{ .radius = 2 }, .flex_shrink = 0 };
}
pub fn color(state: State, index: usize, phase: usize) ui.Color {
    const t = T.current();
    const c = switch (state) {
        .idle => t.accent_ink,
        .working => if (index == 1) t.accent else if (index == 0) ui.Color.hex(0x06b6d4) else ui.Color.hex(0x8b5cf6),
        .approval => t.warn,
        .success => t.ok,
        .failed => t.danger,
    };
    return if ((state == .working or state == .approval) and index != phase % 3) c.withAlpha(95) else c;
}
