//! Compact entry in the gap immediately below the title bar.
const ui = @import("ui");
const T = @import("app_theme.zig");
pub const width: f32 = 120;
pub const height: f32 = 6;
pub const State = enum { idle, working, approval, success, failed };
pub fn trigger() ui.BoxStyle {
    return .{ .position = .absolute, .width = .{ .px = width }, .height = .{ .px = height }, .padding = .{}, .background = ui.Color.TRANSPARENT, .align_items = .center, .justify = .center, .z_index = 199, .corner_radius = 3, .flex_shrink = 0 };
}
pub fn lip(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = width }, .height = .{ .px = height }, .padding = .{}, .direction = .row, .justify = .center, .align_items = .center, .gap = 4, .background = T.current().surface_2, .gradient = glassGradient(false), .glass = T.overlayGlass(), .border = .{ .width = 0, .radius = 3 }, .inset_shadows = ui.InsetShadowList.of(&.{ .{ .offset_y = 1, .blur = 2, .color = ui.Color.rgba(255, 255, 255, 32) }, .{ .offset_y = -1, .blur = 2, .color = ui.Color.rgba(0, 0, 0, 28) } }), .flex_shrink = 0 };
}
fn glassGradient(active: bool) ui.Gradient {
    const surface = T.current().surface_2;
    const alpha = surface.a;
    return .{ .from = ui.Color.lerp(surface.withAlpha(255), ui.Color.WHITE, if (active) 0.30 else 0.22).withAlpha(alpha), .to = surface.withAlpha(alpha), .direction = .vertical };
}
pub fn activeLip(active: bool) ui.BoxStyle {
    return .{ .background = T.current().surface_2, .gradient = glassGradient(active) };
}
pub fn dot(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = 3 }, .height = .{ .px = 3 }, .background = T.current().accent_ink, .border = .{ .radius = 2 }, .flex_shrink = 0 };
}
pub fn color(state: State, index: usize, phase: usize) ui.Color {
    const t = T.current();
    const c = switch (state) {
        .idle => t.accent_ink,
        .working => t.accent,
        .approval => t.warn,
        .success => t.ok,
        .failed => t.danger,
    };
    return if ((state == .working or state == .approval) and index != phase % 3) c.withAlpha(95) else c;
}
