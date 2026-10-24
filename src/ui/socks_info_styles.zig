//! Palette/material roles read from Figma SOCKS panels 358:1419344 (Dark),
//! 358:1420003 (Light), 358:1420766 (Sauber). Compact geometry follows the live V2 nodes.
const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub const TextRole = enum { primary, secondary, muted, warning, success, danger };
pub const ButtonRole = enum { test_proxy, control, ordinary, icon };

pub fn text(role: TextRole) ui.Color {
    const c = theme.current();
    return switch (role) {
        .primary => c.fg_1,
        .secondary => c.fg_2,
        .muted => c.fg_3,
        .warning => c.warn_ink,
        .success => c.ok_ink,
        .danger => c.danger_ink,
    };
}

pub fn panel() ui.BoxStyle {
    const c = theme.current();
    return .{
        .background = c.overlay,
        // The shared image layer owns blur. Blurring this card's backdrop
        // would also include terminal text and apply the global blur twice.
        .glass = .{ .backdrop_blur = 0, .glass_intensity = 0, .specular_opacity = 0, .refraction_level = 0, .warp_gain = 0 },
        .border = .{ .width = 0, .color = c.border, .radius = 14 },
        .shadow = .{ .blur = 32, .offset_y = 24, .color = c.shadow },
    };
}

pub fn pointer() ui.BoxStyle {
    return .{ .background = ui.Color.TRANSPARENT, .border = .{ .width = 0 } };
}

pub fn button(role: ButtonRole) ui.BoxStyle {
    return .{ .background = if (role == .icon) ui.Color.TRANSPARENT else theme.current().surface_2, .border = .{ .width = 0, .radius = if (role == .icon) 7 else 8 } };
}
pub const width: f32 = 360;
pub const normal_height: f32 = 212;
pub const body_height: f32 = 102;
pub const chrome_height: f32 = 110;
pub fn header() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 30 }, .direction = .row, .align_items = .center, .gap = 6, .margin = .{ .bottom = 9 }, .flex_shrink = 0 };
}
pub fn body() ui.BoxStyle {
    return .{ .width = .fill(), .direction = .column, .gap = 6, .flex_shrink = 0, .min_width = 0 };
}
pub fn line(height: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = height }, .direction = .row, .align_items = .center, .gap = 4, .flex_shrink = 0, .min_width = 0, .overflow_hidden = true };
}
pub fn footer() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 30 }, .direction = .row, .align_items = .center, .gap = 6, .margin = .{ .top = 6 }, .flex_shrink = 0 };
}
pub fn icon(size: f32) ui.Style {
    return .{ .width = .{ .px = size }, .height = .{ .px = size }, .flex_shrink = 0 };
}
pub fn iconButton(size: f32) ui.BoxStyle {
    return .{ .width = .{ .px = size }, .height = .{ .px = size }, .padding = .{}, .gap = 0, .background = ui.Color.TRANSPARENT, .border = .{ .radius = 7 }, .flex_shrink = 0, .align_items = .center, .justify = .center };
}
