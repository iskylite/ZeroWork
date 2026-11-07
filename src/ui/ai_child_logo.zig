//! Stable, local vector identities. Names, task status and process restarts do
//! not change the mark; light/dark themes only adjust its ink contrast.
const std = @import("std");
const ui = @import("ui");
const theme = @import("app_theme.zig");
const ir = @import("icon_ir");
const AgentId = @import("../host/identity.zig").AgentId;

pub fn seed(agent: AgentId) u32 {
    return std.hash.Fnv1a_32.hash(&agent.bytes);
}
pub fn ink(agent: AgentId) ui.Color {
    const dark = theme.current().fg_1.r > 128;
    const light_inks = [_]u24{ 0x9e99ec, 0x83afe7, 0x73c6c7, 0xc09bdc, 0x91bfaa, 0xd4ad86 };
    const dark_inks = [_]u24{ 0x6259ae, 0x4774aa, 0x367f83, 0x865ba4, 0x4a7963, 0x94683e };
    const index = seed(agent) % light_inks.len;
    return ui.Color.hex(if (dark) light_inks[index] else dark_inks[index]);
}
fn variantAsset(comptime variant: u32) ir.Asset {
    const Data = struct {
        const antenna_x: f32 = 8 + (variant % 3) * 4;
        const head = [_]ir.Point{ .{ .x = 4, .y = 11 }, .{ .x = 4, .y = 16 }, .{ .x = 4.3, .y = 17.5 }, .{ .x = 5.2, .y = 18.8 }, .{ .x = 6.5, .y = 19.7 }, .{ .x = 8, .y = 20 }, .{ .x = 16, .y = 20 }, .{ .x = 17.5, .y = 19.7 }, .{ .x = 18.8, .y = 18.8 }, .{ .x = 19.7, .y = 17.5 }, .{ .x = 20, .y = 16 }, .{ .x = 20, .y = 11 }, .{ .x = 19.7, .y = 9.5 }, .{ .x = 18.8, .y = 8.2 }, .{ .x = 17.5, .y = 7.3 }, .{ .x = 16, .y = 7 }, .{ .x = 8, .y = 7 }, .{ .x = 6.5, .y = 7.3 }, .{ .x = 5.2, .y = 8.2 }, .{ .x = 4.3, .y = 9.5 } };
        const stem = [_]ir.Point{ .{ .x = antenna_x, .y = 4 }, .{ .x = antenna_x, .y = 7 } };
        const antenna = circle(antenna_x, 3, 1);
        const left_ear = [_]ir.Point{ .{ .x = 2, .y = 11 }, .{ .x = 2, .y = 16 } };
        const right_ear = [_]ir.Point{ .{ .x = 22, .y = 11 }, .{ .x = 22, .y = 16 } };
        const mouth = [_]ir.Point{ .{ .x = 9, .y = 16.5 }, .{ .x = 15, .y = 16.5 } };
        const left_eye = eye(variant / 3, 9);
        const right_eye = eye(variant / 3, 15);
        const shapes = [_]ir.Shape{
            shape(&head, true, false, 1.6),                                                         shape(&stem, false, false, 1.6),                                                         shape(&antenna, true, false, 1.6),
            shape(&left_ear, false, false, 1.6),                                                    shape(&right_ear, false, false, 1.6),                                                    shape(&mouth, false, false, 1.6),
            shape(&left_eye, variant / 3 != 2, variant / 3 != 2, if (variant / 3 == 2) 1.8 else 0), shape(&right_eye, variant / 3 != 2, variant / 3 != 2, if (variant / 3 == 2) 1.8 else 0),
        };
        const reps = [_]ir.Rep{.{ .size = 24, .view_min_x = 0, .view_min_y = 0, .view_width = 24, .view_height = 24, .shapes = &shapes }};
    };
    return .{ .svg_data = "", .default_width = 24, .default_height = 24, .icon_id = @as(u16, 60100 + variant), .reps = &Data.reps };
}
fn shape(comptime points: []const ir.Point, comptime closed: bool, comptime fill: bool, comptime stroke: f32) ir.Shape {
    const Data = struct {
        const contours = [_]ir.Contour{.{ .points = points, .closed = closed }};
    };
    return .{ .contours = &Data.contours, .fill = fill, .stroke_width = stroke };
}
fn circle(comptime x: f32, comptime y: f32, comptime radius: f32) [12]ir.Point {
    var points: [12]ir.Point = undefined;
    for (&points, 0..) |*point, i| {
        const angle: f32 = @as(f32, @floatFromInt(i)) * std.math.tau / 12;
        point.* = .{ .x = x + @cos(angle) * radius, .y = y + @sin(angle) * radius };
    }
    return points;
}
fn eye(comptime kind: u32, comptime x: f32) [12]ir.Point {
    if (kind == 0) return circle(x, 12, 1);
    var points: [12]ir.Point = undefined;
    for (&points, 0..) |*point, i| {
        const step: f32 = @as(f32, @floatFromInt(i % 3)) / 3.0;
        point.* = if (kind == 1) switch (i / 3) {
            0 => .{ .x = x - 1 + step * 2, .y = 11 },
            1 => .{ .x = x + 1, .y = 11 + step * 2 },
            2 => .{ .x = x + 1 - step * 2, .y = 13 },
            else => .{ .x = x - 1, .y = 13 - step * 2 },
        } else .{ .x = x - 1 + @as(f32, @floatFromInt(i)) * 2.0 / 11.0, .y = 12 };
    }
    return points;
}
const variants = blk: {
    var entries: [9]ir.Asset = undefined;
    for (&entries, 0..) |*entry, i| entry.* = variantAsset(i);
    break :blk entries;
};
pub fn asset(agent: AgentId) ir.Asset {
    const value = seed(agent);
    return variants[value / 6 % 3 + value / 18 % 3 * 3];
}
pub fn mount(cx: *ui.Cx, agent: AgentId) !*ui.Node {
    const node = try ui.box(cx, .{ .width = .{ .px = 32 }, .height = .{ .px = 32 }, .align_items = .center, .justify = .center, .background = ink(agent).withAlpha(24), .border = .{ .radius = 9 }, .flex_shrink = 0 }, .{});
    node.meta.ownership.meta.test_id = "ai.child.logo";
    try node.appendChild(cx.allocator, try ui.iconTint(cx, asset(agent), ink(agent), .{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .flex_shrink = 0 }));
    return node;
}
pub fn repaint(node: *ui.Node, agent: AgentId) void {
    node.setBackground(ink(agent).withAlpha(24));
    for (node.children.items) |child| _ = child.setTint(ink(agent));
}

test "v0.4 child logo is deterministic for the stable identity and varies across agents" {
    const agent: AgentId = .{ .bytes = @splat(7) };
    try std.testing.expectEqual(@as(u32, 0x721b8c95), seed(agent));
    try std.testing.expectEqual(@as(u16, 60105), asset(agent).icon_id.?);
    try std.testing.expect(asset(agent).pickRep(22).?.shapes.len == 8);
    try std.testing.expect(seed(agent) != seed(.{ .bytes = @splat(8) }));
}
