//! Tab-bar dock: 72×12 concave glass, without an outline or outer drop shadow.
const ui = @import("ui");
const T = @import("app_theme.zig");
pub const State = enum { idle, working, approval, success, failed };
pub fn trigger() ui.BoxStyle {
    return .{ .position = .absolute, .width = .{ .px = 88 }, .height = .{ .px = 24 }, .padding = .{}, .background = ui.Color.TRANSPARENT, .align_items = .center, .justify = .center, .z_index = 40, .corner_radius = 7, .flex_shrink = 0 };
}
pub fn lip(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = 72 }, .height = .{ .px = 12 }, .direction = .row, .justify = .center, .align_items = .center, .gap = 4, .background = T.current().surface_2.withAlpha(30), .gradient = .{ .from = ui.Color.rgba(0, 0, 0, 28), .to = ui.Color.rgba(255, 255, 255, 18), .direction = .vertical }, .glass = .{ .backdrop_blur = 12, .surface = .concave, .glass_intensity = 0.38, .specular_opacity = 0.12, .refraction_level = 0.28, .warp_gain = 0.25, .center_thickness = 1.5, .edge_field_strength = 0.6 }, .border = .{ .width = 0, .radius = 6 }, .flex_shrink = 0 };
}
pub fn dot(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = 3 }, .height = .{ .px = 3 }, .background = T.current().accent, .border = .{ .radius = 1.5 }, .flex_shrink = 0 };
}
pub fn color(state: State, index: usize, phase: usize) ui.Color {
    const t = T.current();
    const c = switch (state) {
        .idle => t.accent,
        .working => if (index == 1) t.accent else if (index == 0) ui.Color.hex(0x06b6d4) else ui.Color.hex(0x8b5cf6),
        .approval => t.warn,
        .success => t.ok,
        .failed => t.danger,
    };
    return if ((state == .working or state == .approval) and index != phase % 3) c.withAlpha(95) else c;
}
