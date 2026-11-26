//! The anchored task strip uses the same glass and corner treatment as workspace tools.
const ui = @import("ui");
const theme = @import("app_theme.zig");

pub const body_size: f32 = 44;
pub const slot_size: f32 = 28;
pub const slot_gap: f32 = 4;
pub const rail_padding: f32 = 4;
pub const rail_gap: f32 = 7;
pub const margin: f32 = 16;

pub fn root() ui.BoxStyle {
    return .{ .position = .absolute, .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 }, .right = .{ .px = 0 }, .bottom = .{ .px = 0 } }, .width = .fill(), .height = .fill(), .padding = .{}, .hit_roles = .{ .pointer = false, .scroll = false }, .z_index = 320 };
}

pub fn body() ui.BoxStyle {
    const c = theme.current();
    return .{ .position = .absolute, .width = .{ .px = body_size }, .height = .{ .px = body_size }, .padding = .{}, .align_items = .center, .justify = .center, .background = c.surface_1, .glass = theme.overlayGlass(), .border = .{ .width = 0, .color = ui.Color.TRANSPARENT, .radius = body_size / 2 }, .shadow = .{ .offset_y = 6, .blur = 18, .color = c.shadow }, .cursor = .grab, .hit_behavior = .@"opaque" };
}

pub fn logo() ui.BoxStyle {
    return .{ .width = .{ .px = 34 }, .height = .{ .px = 34 }, .padding = .{}, .hit_behavior = .pass_through };
}

pub fn grab() ui.BoxStyle {
    return .{ .position = .absolute, .width = .{ .px = body_size }, .height = .{ .px = body_size }, .padding = .{}, .background = ui.Color.TRANSPARENT, .border = .{ .width = 0, .color = ui.Color.TRANSPARENT, .radius = body_size / 2 }, .cursor = .grab, .hit_behavior = .@"opaque" };
}

pub fn rail() ui.BoxStyle {
    const c = theme.current();
    return .{ .position = .absolute, .padding = .{}, .background = c.overlay, .glass = theme.overlayGlass(), .border = .{ .radius = 14 }, .shadow = .{ .offset_y = 4, .blur = 12, .color = c.shadow }, .hit_behavior = .pass_through };
}

pub fn slot() ui.BoxStyle {
    return .{ .position = .absolute, .width = .{ .px = slot_size }, .height = .{ .px = slot_size }, .padding = .{}, .align_items = .center, .justify = .center };
}

pub fn activeDot() ui.BoxStyle {
    const c = theme.current();
    return .{ .position = .absolute, .inset = .{ .right = .{ .px = 0 }, .top = .{ .px = 0 } }, .width = .{ .px = 6 }, .height = .{ .px = 6 }, .padding = .{}, .background = c.ok, .border = .{ .width = 0, .color = c.ok, .radius = 3 }, .z_index = 4, .hit_behavior = .pass_through };
}
