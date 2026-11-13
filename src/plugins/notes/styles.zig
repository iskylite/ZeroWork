const ui = @import("ui");
pub const theme = @import("../../ui/app_theme.zig");

pub const directory_width: f32 = 252;
pub const directory_gap: f32 = 16;
pub const compact_width: f32 = 900;
pub const toolbar_height: f32 = 64;
pub const floating_header_height: f32 = 52;
pub const floating_header_padding: f32 = 22;
pub const floating_header_icon_size: f32 = 16;
pub const floating_header_gap: f32 = 8;
pub const floating_title_left = floating_header_padding + floating_header_icon_size + floating_header_gap;
pub const floating_island_height: f32 = 36;
pub const floating_header_compact_width: f32 = 680;
pub const outline_width: f32 = 228;
pub const outline_max_height: f32 = 400;
pub const outline_vertical_inset: f32 = 12;
pub const outline_header_height: f32 = 32;
pub const outline_row_height: f32 = 28;
pub const outline_row_gap: f32 = 2;
pub const outline_padding: f32 = 6;
pub const floating_card_top: f32 = 4;

pub fn root() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .direction = .row, .gap = directory_gap, .min_width = 0, .min_height = 0, .overflow_hidden = true };
}

pub fn main() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .direction = .column, .min_width = 0, .min_height = 0 };
}

pub fn navigation(compact: bool) ui.BoxStyle {
    return .{
        .width = .{ .px = directory_width },
        .max_width = if (compact) null else directory_width,
        .height = .fill(),
        .direction = .column,
        .position = if (compact) .absolute else .relative,
        .inset = if (compact) .{ .top = .{ .px = 0 }, .right = .{ .px = 0 }, .bottom = .{ .px = 0 } } else .{},
        .flex_shrink = 0,
        .border = .{ .radius = 12 },
        .background = theme.current().surface_1,
        .hit_behavior = .@"opaque",
        .overflow_hidden = true,
        .z_index = if (compact) 2 else 0,
    };
}

pub fn floatingCard(width: f32, height: f32, inset: ui.Inset) ui.BoxStyle {
    var style = navigation(true);
    style.inset = inset;
    style.width = .{ .px = width };
    style.max_width = width;
    style.height = .{ .px = height };
    style.shadow = .{ .blur = 16, .offset_y = 6, .color = theme.current().shadow };
    return style;
}

pub fn floatingSurface() ui.BoxStyle {
    const colors = theme.current();
    return .{
        .background = colors.overlay,
        .border = .{ .radius = 12, .width = 0.7, .color = floatingDivider() },
        .shadow = .{ .blur = 16, .offset_x = -3, .color = colors.shadow },
    };
}

pub fn floatingDivider() ui.Color {
    var color = theme.current().border;
    color.a /= 2;
    return color;
}

pub fn floatingIsland() ui.BoxStyle {
    var style = row(floating_island_height, 2);
    style.width = .{ .fit = .{} };
    style.padding = .{ .left = 4, .right = 4 };
    style.background = floatingIslandFill();
    style.border = .{ .radius = floating_island_height / 2, .width = 0.7, .color = floatingDivider() };
    return style;
}

pub fn floatingIslandFill() ui.Color {
    return theme.current().fg_1.withAlpha(12);
}

pub fn row(height: f32, gap: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = height }, .flex_shrink = 0, .direction = .row, .gap = gap, .align_items = .center, .min_width = 0 };
}

pub fn stack(gap: f32) ui.BoxStyle {
    return .{ .width = .fill(), .direction = .column, .gap = gap, .min_width = 0, .flex_shrink = 0 };
}

pub fn tool() ui.BoxStyle {
    return .{ .width = .{ .px = 28 }, .height = .{ .px = 28 }, .flex_shrink = 0, .padding = .{}, .border = .{ .radius = 14 } };
}

pub fn treeRow(depth: u8, selected: bool) ui.BoxStyle {
    var style = row(32, 6);
    style.padding = .{ .left = 8 + 12 * @as(f32, @floatFromInt(depth)), .right = 6 };
    style.border = .{ .radius = 8 };
    style.background = if (selected) theme.current().selection else ui.Color.TRANSPARENT;
    return style;
}

pub fn editor(rows: u32) ui.BoxStyle {
    return .{
        .width = .fill(),
        .height = .{ .px = @as(f32, @floatFromInt(rows)) * 20 },
        .flex_shrink = 0,
        .background = theme.current().well,
        .border = .{ .radius = 8 },
    };
}

pub fn text(size: f32, weight: u16, color: ui.Color) ui.TextStyle {
    return .{ .font_size = size, .font_weight = weight, .line_height = 1.4, .color = color };
}
