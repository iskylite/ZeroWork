//! V3 content-edge entry: 88×24 hit target, 72×12 recess and three 3px status dots.
const ui = @import("ui");
const T = @import("app_theme.zig");
pub const State = enum { idle, working, approval, success, failed };
pub fn trigger() ui.BoxStyle {
    return .{ .position = .absolute, .width = .{ .px = 88 }, .height = .{ .px = 24 }, .padding = .{}, .background = ui.Color.TRANSPARENT, .align_items = .center, .justify = .center, .z_index = 199, .corner_radius = 7, .flex_shrink = 0 };
}
pub fn lip(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = 72 }, .height = .{ .px = 12 }, .padding = .{}, .direction = .row, .justify = .center, .align_items = .center, .gap = 4, .background = T.current().well, .corner_radius = 7, .flex_shrink = 0 };
}
pub fn activeLip(active: bool) ui.BoxStyle {
    return .{ .background = if (active) T.current().selection else T.current().well };
}
pub fn dot(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = 3 }, .height = .{ .px = 3 }, .background = T.current().accent_ink, .border = .{ .radius = 2 }, .flex_shrink = 0 };
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
