//! V3 workspace command-record decorations. These are presentation metadata;
//! command/result copy and exported source text never include these labels.
const ui = @import("ui");
const theme = @import("app_theme.zig");
pub const marker_width: f32 = @import("terminal_record_geometry.zig").marker_width;
pub const marker_height: f32 = 18;
pub const marker_size: f32 = 10;
pub const marker_gap: f32 = 10;
pub const result_icon_width: f32 = 12;
pub const result_icon_gap: f32 = 7;
pub fn markerText(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = marker_size, .line_height = marker_height / marker_size, .color = theme.current().accent_ink, .selectable = false };
}
pub fn resultText(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 14, .line_height = 22.0 / 14.0, .color = theme.current().fg_2, .selectable = false };
}
pub fn markerBox(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .position = .absolute, .width = .{ .px = marker_width }, .height = .{ .px = marker_height }, .padding = .{ .left = 5, .right = 5 }, .background = theme.current().accent.withAlpha(31), .border = .{ .radius = 4 }, .hit_behavior = .pass_through };
}
pub fn resultColor(kind: u8) ui.Color {
    return switch (kind) {
        2 => theme.current().ok_ink,
        3 => theme.current().danger_ink,
        else => theme.current().fg_2,
    };
}
pub fn tint(kind: u8) ui.Color {
    return if (kind == 3) theme.current().danger.withAlpha(13) else theme.current().accent.withAlpha(20);
}

pub fn colors() [3]u24 {
    const t = theme.current();
    return .{ rgb(t.accent_ink), rgb(t.ok_ink), rgb(t.danger_ink) };
}
fn rgb(c: ui.Color) u24 {
    return (@as(u24, c.r) << 16) | (@as(u24, c.g) << 8) | @as(u24, c.b);
}

pub fn place(cx: *ui.Cx, node: *ui.Node, x: f32, y: f32, width: f32, height: f32) void {
    node.setStyleInline(cx.allocator, .{ .position = .absolute, .inset = .{ .left = .{ .px = x }, .top = .{ .px = y } }, .width = .{ .px = width }, .height = .{ .px = height }, .hit_behavior = .pass_through });
}

pub fn recordTime(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .line_height = 2, .color = theme.current().fg_3, .text_align = .end, .use_monospace_font = true, .selectable = false };
}
