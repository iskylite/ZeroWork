//! Per-frame paint invariant self-check (e2e / test mode, see Cx.paint_invariant_check).
//!
//! Criterion: the same node emits an identical fill or stroke rect (geometry, color, corner,
//! shape, width) more than once per frame = duplicate emission. Text / images are excluded:
//! offscreen composite paths legitimately paint the same content twice (false positives).
//! This targets the "cached replay + emit own content again" bug family: the duplicate is
//! usually after descendants, so an opaque background covers children (child disappears) or
//! alpha darkens them, only in a cached-replay frame (screenshots can't catch it).
//! Don't use "parent after descendants" as criterion: scrollbars and edge fade drawn by a
//! container after content are legitimate.
const std = @import("std");
const display_list = @import("display_list.zig");
const DisplayItem = display_list.DisplayItem;

const Key = struct {
    /// 0 = fill_rect, 1 = stroke_rect
    kind: u8,
    node_id: u32,
    stroke_width: u32 = 0,
    geom: [4]u32,
    radius: [4]u32,
    color: u32,
    shape: u8,
};

pub const Result = struct {
    /// Count of duplicate fill / stroke rects this frame
    duplicates: usize = 0,
    /// First duplicate node (for troubleshooting; 0 = none)
    first_node: u32 = 0,
};

/// Count duplicate fill / stroke rects in frame commands. `scratch` uses frame arena
/// (recovered at frame end); allocation failure returns error (not treated as pass).
pub fn duplicateFills(scratch: std.mem.Allocator, items: []const DisplayItem) !Result {
    var seen = std.AutoHashMap(Key, void).init(scratch);
    defer seen.deinit();
    var out: Result = .{};
    for (items) |item| {
        const key: Key = switch (item) {
            .fill_rect => |f| .{ .kind = 0, .node_id = f.header.node_id, .geom = geomOf(f), .radius = radiusOf(f.radius), .color = packColor(f.color), .shape = f.shape },
            .stroke_rect => |f| .{ .kind = 1, .node_id = f.header.node_id, .stroke_width = @bitCast(f.width), .geom = geomOf(f), .radius = radiusOf(f.radius), .color = packColor(f.color), .shape = f.shape },
            else => continue,
        };
        const gop = try seen.getOrPut(key);
        if (gop.found_existing) {
            out.duplicates += 1;
            if (out.first_node == 0) out.first_node = key.node_id;
        }
    }
    return out;
}

fn geomOf(f: anytype) [4]u32 {
    return .{ @bitCast(f.x), @bitCast(f.y), @bitCast(f.w), @bitCast(f.h) };
}

fn radiusOf(r: [4]f32) [4]u32 {
    return .{ @bitCast(r[0]), @bitCast(r[1]), @bitCast(r[2]), @bitCast(r[3]) };
}

fn packColor(c: anytype) u32 {
    return @as(u32, c.r) << 24 | @as(u32, c.g) << 16 | @as(u32, c.b) << 8 | c.a;
}

test "duplicateFills：同一节点同一矩形发两次计 1；不同节点 / 不同几何不算" {
    const h0: display_list.ItemHeader = .{ .transform_id = 0, .node_id = 7 };
    const h1: display_list.ItemHeader = .{ .transform_id = 0, .node_id = 8 };
    const c = @import("types.zig").Color.rgba(30, 34, 48, 255);
    const a: DisplayItem = .{ .fill_rect = .{ .header = h0, .x = 0, .y = 0, .w = 10, .h = 6, .color = c } };
    const other_node: DisplayItem = .{ .fill_rect = .{ .header = h1, .x = 0, .y = 0, .w = 10, .h = 6, .color = c } };
    const other_geom: DisplayItem = .{ .fill_rect = .{ .header = h0, .x = 0, .y = 0, .w = 4, .h = 6, .color = c } };
    const r = try duplicateFills(std.testing.allocator, &.{ a, other_node, other_geom, a });
    try std.testing.expectEqual(@as(usize, 1), r.duplicates);
    try std.testing.expectEqual(@as(u32, 7), r.first_node);
    try std.testing.expectEqual(@as(usize, 0), (try duplicateFills(std.testing.allocator, &.{ a, other_node, other_geom })).duplicates);
    // Stroke likewise; fill and stroke with same geometry don't count as duplicate
    const s0: DisplayItem = .{ .stroke_rect = .{ .header = h0, .x = 0, .y = 0, .w = 10, .h = 6, .color = c, .width = 1 } };
    try std.testing.expectEqual(@as(usize, 0), (try duplicateFills(std.testing.allocator, &.{ a, s0 })).duplicates);
    try std.testing.expectEqual(@as(usize, 1), (try duplicateFills(std.testing.allocator, &.{ s0, a, s0 })).duplicates);
    try std.testing.expectError(error.OutOfMemory, duplicateFills(std.testing.failing_allocator, &.{a}));
}
