//! Live Figma V2: 223:330801 / 236:568536, 560x360, header48, body16/56.
const std = @import("std");
const ui = @import("ui");
const theme = @import("app_theme.zig");
pub const row_height: f32 = 80;
pub const row_gap: f32 = 10;
pub fn card() ui.BoxStyle {
    return .{ .width = .{ .px = 560 }, .direction = .column, .background = theme.current().overlay, .border = .{ .radius = 14 }, .overflow = .hidden, .flex_shrink = 0 };
}
pub fn header() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 48 }, .direction = .row, .align_items = .center, .padding = .{ .left = 16, .right = 11 }, .gap = 6, .flex_shrink = 0 };
}
pub fn list() ui.BoxStyle {
    return .{ .width = .fill(), .direction = .column, .gap = row_gap, .padding = .{ .left = 16, .right = 16, .top = 8, .bottom = 16 } };
}
pub fn row() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = row_height }, .direction = .column, .padding = ui.Padding.all(10), .gap = 6, .background = theme.current().surface_2, .border = .{ .radius = 9 }, .flex_shrink = 0 };
}
pub fn metadata() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 24 }, .direction = .row, .align_items = .center, .gap = 8, .flex_shrink = 0 };
}
pub fn actions() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 30 }, .direction = .row, .justify = .end, .gap = 8, .flex_shrink = 0 };
}
pub fn button() ui.BoxStyle {
    return .{ .width = .{ .px = 72 }, .height = .{ .px = 30 }, .padding = ui.Padding.all(0), .border = .{ .radius = 8 }, .font_size = 12, .font_weight = 500, .flex_shrink = 0 };
}
pub fn close() ui.BoxStyle {
    return .{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .padding = ui.Padding.all(0), .border = .{ .radius = 8 }, .flex_shrink = 0 };
}
pub fn emptyTitle() ui.TextStyle {
    return .{ .font_size = 13, .font_weight = 500, .line_height = 18.0 / 13.0, .color = theme.current().fg_1, .selectable = false };
}
pub fn text(size: f32, weight: u16, secondary: bool) ui.TextStyle {
    return .{ .font_size = size, .font_weight = weight, .line_height = (if (size == 12) @as(f32, 18) else 16) / size, .color = if (secondary) theme.current().fg_2 else theme.current().fg_1, .text_overflow = .ellipsis, .selectable = false };
}
pub fn chip() ui.BoxStyle {
    return .{ .height = .{ .px = 24 }, .direction = .row, .align_items = .center, .padding = .{ .left = 9, .right = 9 }, .background = theme.current().surface_2, .border = .{ .radius = 8 }, .flex_shrink = 0 };
}
const Time = extern struct { sec: c_int, min: c_int, hour: c_int, day: c_int, month: c_int, year: c_int, week_day: c_int, year_day: c_int, daylight: c_int, offset: c_long, zone: ?[*:0]const u8 };
extern "c" fn localtime_r(*const c_long, *Time) ?*Time;
/// Real recording start in the system timezone, never a design fixture or raw epoch.
pub fn dateLabel(buffer: []u8, wall_ms: i64) []const u8 {
    const seconds: c_long = @intCast(@divFloor(wall_ms, 1000));
    var value: Time = undefined;
    if (localtime_r(&seconds, &value) == null) return "时间未知";
    if (value.year < -1900 or value.month < 0 or value.day < 1 or value.hour < 0 or value.min < 0) return "时间未知";
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ @as(u32, @intCast(value.year + 1900)), @as(u32, @intCast(value.month + 1)), @as(u32, @intCast(value.day)), @as(u32, @intCast(value.hour)), @as(u32, @intCast(value.min)) }) catch "时间未知";
}
pub fn durationLabel(buffer: []u8, duration_ms: u64) []const u8 {
    const minutes = duration_ms / std.time.ms_per_min;
    return if (minutes >= 60) std.fmt.bufPrint(buffer, "{d} 小时 {d} 分钟", .{ minutes / 60, minutes % 60 }) catch "时长未知" else if (minutes > 0) std.fmt.bufPrint(buffer, "{d} 分钟", .{minutes}) catch "时长未知" else std.fmt.bufPrint(buffer, "{d} 秒", .{duration_ms / 1000}) catch "时长未知";
}

pub fn repaint(node: *ui.Node, previous: theme.Colors) void {
    node.setBackground(remap(node.getBackground(), previous));
    if (node.getText()) |value| node.setTextColor(remap(value.color, previous));
    if (node.getIcon()) |value| _ = node.setTint(remap(value.tint, previous));
    for (node.children.items) |child| repaint(child, previous);
}
fn remap(value: ui.Color, previous: theme.Colors) ui.Color {
    const current = theme.current();
    inline for (@typeInfo(theme.Colors).@"struct".field_names) |field| if (ui.Color.eql(value, @field(previous, field))) return @field(current, field);
    return value;
}
