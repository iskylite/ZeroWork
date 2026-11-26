//! Palette/material roles read from Figma SOCKS panels 358:1419344 (Dark),
//! 358:1420003 (Light), 358:1420766 (Sauber). Compact geometry follows the live V2 nodes.
const ui = @import("ui");
const std = @import("std");
pub const theme = @import("app_theme.zig");
pub const TextRole = enum { primary, secondary, muted, warning, success, danger };
pub const ButtonRole = enum { secondary, primary, destructive, disabled, icon };
pub const ButtonPaint = struct { normal: ui.Color, hover: ui.Color, pressed: ui.Color, ink: ui.Color };

pub fn text(role: TextRole) ui.Color {
    const c = theme.current();
    return switch (role) {
        .primary => c.fg_1,
        .secondary => c.fg_2,
        .muted => c.fg_2,
        .warning => c.warn_ink,
        .success => c.ok_ink,
        .danger => c.danger_ink,
    };
}

/// Bottom-bar status stays readable without competing with the content pane.
pub fn statusBarInk(color: ui.Color) ui.Color {
    return ui.Color.lerp(color, theme.current().fg_2, 0.25);
}

pub fn panel() ui.BoxStyle {
    const c = theme.current();
    return .{
        .background = c.overlay,

        // Filter the existing window backdrop locally so workspace text does
        // not compete with foreground content; the global image is drawn once.
        .glass = theme.overlayGlass(),
        .border = .{ .width = 0, .color = c.border, .radius = 11 },
        .shadow = .{ .blur = 32, .offset_y = 24, .color = c.shadow },
    };
}

pub fn pointer() ui.BoxStyle {
    return .{ .background = ui.Color.TRANSPARENT, .border = .{ .width = 0 } };
}

/// The footer owns one geometry. Role only decides the fill, feedback and ink.
/// Disabled labels remain readable without making the control interactive.
pub fn buttonPaint(role: ButtonRole) ButtonPaint {
    const c = theme.current();
    const s = theme.states();
    return switch (role) {
        .primary => .{ .normal = s.primary, .hover = s.primary_hover, .pressed = s.primary_pressed, .ink = s.primary_ink },
        .secondary => materialButtonPaint(s.action, s.hover, s.pressed, c.fg_2),
        .destructive => blk: {
            const hover = ui.Color.lerp(s.tag_danger, s.danger, 0.14);
            const pressed = ui.Color.lerp(s.tag_danger, s.danger, 0.25);
            break :blk materialButtonPaint(s.tag_danger, hover, pressed, c.danger_ink);
        },
        .disabled => materialButtonPaint(s.disabled, s.disabled, s.disabled, c.fg_3),
        .icon => .{ .normal = s.action, .hover = s.hover, .pressed = s.pressed, .ink = c.fg_2 },
    };
}
fn materialButtonPaint(normal: ui.Color, hover: ui.Color, pressed: ui.Color, ink: ui.Color) ButtonPaint {
    // Preserve the theme's material alpha; choose the same readable ink on
    // both the role's RGB tone and its composition over the card and rule.
    const c = theme.current();
    const underlying = theme.patchPaint(theme.popupInset(), theme.patchPaint(c.overlay, c.terminal.withAlpha(255)));
    const fills = [_]ui.Color{ normal, hover, pressed, theme.patchPaint(normal, underlying), theme.patchPaint(hover, underlying), theme.patchPaint(pressed, underlying) };
    return .{ .normal = normal, .hover = hover, .pressed = pressed, .ink = theme.patchInk(ink, &fills) };
}
pub const width: f32 = 380;
pub const minimum_width: f32 = 288;
pub const button_height: f32 = 30;
pub const button_radius: f32 = 8;
pub const logs_width: f32 = 560;
pub const logs_height: f32 = 420;
pub const normal_height: f32 = 451;
pub const body_height: f32 = 320;
// Panel padding (2 × 16), header (28) and its bottom gap (12).
pub const chrome_height: f32 = 72;
pub fn header() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 28 }, .direction = .row, .align_items = .center, .gap = 8, .margin = .{ .bottom = 12 }, .flex_shrink = 0 };
}
pub fn body() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 0, .flex_shrink = 0, .min_width = 0 };
}
pub fn line(height: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = height }, .direction = .row, .align_items = .center, .gap = 4, .flex_shrink = 0, .min_width = 0, .overflow_hidden = true };
}
pub fn footer() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = button_height }, .direction = .row, .align_items = .center, .gap = 8, .margin = .{ .top = 3 }, .flex_shrink = 0 };
}
pub fn icon(size: f32) ui.Style {
    return .{ .width = .{ .px = size }, .height = .{ .px = size }, .flex_shrink = 0 };
}
pub fn iconButton(size: f32) ui.BoxStyle {
    return .{ .width = .{ .px = size }, .height = .{ .px = size }, .padding = .{}, .gap = 0, .background = ui.Color.TRANSPARENT, .border = .{ .radius = 7 }, .flex_shrink = 0, .align_items = .center, .justify = .center };
}

/// Same cumulative traffic units for session and application-owned listeners.
pub fn formatBytes(buf: []u8, value: u64) ![]const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB" };
    var divisor: u64 = 1;
    var n: usize = 0;
    while (n + 1 < units.len and value / divisor >= 1024) : (n += 1) divisor *= 1024;
    if (value % divisor == 0) return std.fmt.bufPrint(buf, "{d} {s}", .{ value / divisor, units[n] });
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ @as(f64, @floatFromInt(value)) / @as(f64, @floatFromInt(divisor)), units[n] });
}
