//! Palette/material roles read from Figma SOCKS panels 358:1419344 (Dark),
//! 358:1420003 (Light), 358:1420766 (Sauber). Compact geometry follows the live V2 nodes.
const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub const TextRole = enum { primary, secondary, muted, warning, success, danger };
pub const ButtonRole = enum { test_proxy, control, ordinary, icon };

pub fn text(role: TextRole) ui.Color {
    const c = theme.current();
    if (theme.currentName() == .dark) switch (role) {
        .success => return ui.Color.rgba(0x4b, 0xd1, 0x8a, 255),
        .warning => return ui.Color.rgba(0xe8, 0xbd, 0x71, 255),
        .danger => return ui.Color.rgba(0xff, 0x9d, 0x9d, 255),
        else => {},
    };
    return switch (role) {
        .primary => c.fg_1,
        .secondary => c.fg_2,
        .muted => c.fg_3,
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

pub fn button(role: ButtonRole) ui.BoxStyle {
    return .{ .background = if (role == .icon) ui.Color.TRANSPARENT else theme.current().surface_2, .border = .{ .width = 0, .radius = if (role == .icon) 7 else 8 } };
}
pub const width: f32 = 380;
pub const normal_height: f32 = 290;
pub const body_height: f32 = 159;
pub const chrome_height: f32 = 131;
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
    return .{ .width = .fill(), .height = .{ .px = 45 }, .direction = .row, .align_items = .center, .gap = 8, .padding = .{ .top = 12, .bottom = 2 }, .margin = .{ .top = 14 }, .flex_shrink = 0 };
}
pub fn icon(size: f32) ui.Style {
    return .{ .width = .{ .px = size }, .height = .{ .px = size }, .flex_shrink = 0 };
}
pub fn iconButton(size: f32) ui.BoxStyle {
    return .{ .width = .{ .px = size }, .height = .{ .px = size }, .padding = .{}, .gap = 0, .background = ui.Color.TRANSPARENT, .border = .{ .radius = 7 }, .flex_shrink = 0, .align_items = .center, .justify = .center };
}
