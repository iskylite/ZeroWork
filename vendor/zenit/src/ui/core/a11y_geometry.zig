//! Convex intersections retain shape until the final UIA rectangle is emitted.
const std = @import("std");
const types = @import("types.zig");
pub const Point = struct { x: f64, y: f64 };

pub fn rectangle(rect: types.ComputedRect, transform: types.Transform2D) ![4]Point {
    if (!std.math.isFinite(rect.x) or !std.math.isFinite(rect.y) or
        !std.math.isFinite(rect.w) or !std.math.isFinite(rect.h) or
        !std.math.isFinite(rect.x + rect.w) or !std.math.isFinite(rect.y + rect.h) or
        rect.w < 0 or rect.h < 0) return error.InvalidAccessibilityGeometry;
    const corners = [_]types.Point{
        transform.applyPoint(rect.x, rect.y),
        transform.applyPoint(rect.x + rect.w, rect.y),
        transform.applyPoint(rect.x + rect.w, rect.y + rect.h),
        transform.applyPoint(rect.x, rect.y + rect.h),
    };
    var result: [4]Point = undefined;
    for (corners, &result) |p, *out| {
        if (!std.math.isFinite(p.x) or !std.math.isFinite(p.y)) return error.InvalidAccessibilityGeometry;
        out.* = .{ .x = p.x, .y = p.y };
    }
    return result;
}

fn cross(a: Point, b: Point, p: Point) f64 {
    return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);
}
fn area(points: []const Point) f64 {
    if (points.len < 3) return 0;
    // Translate to the first vertex to avoid cancellation at large origins.
    var result: f64 = 0;
    for (1..points.len - 1) |i| result += cross(points[0], points[i], points[i + 1]);
    return result;
}

/// Clip an oriented line against a convex polygon without expanding it to an
/// AABB. Endpoints keep their original direction and affinity association.
pub fn clipSegment(first: Point, last: Point, clip: []const Point) !?[2]Point {
    if (!std.math.isFinite(first.x) or !std.math.isFinite(first.y) or
        !std.math.isFinite(last.x) or !std.math.isFinite(last.y)) return error.InvalidAccessibilityGeometry;
    for (clip) |point| if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y)) return error.InvalidAccessibilityGeometry;
    if (first.x == last.x and first.y == last.y) return null;
    const signed_area = area(clip);
    if (!std.math.isFinite(signed_area)) return error.InvalidAccessibilityGeometry;
    if (signed_area == 0) return null;
    const direction: f64 = if (signed_area > 0) 1 else -1;
    var lo: f64 = 0;
    var hi: f64 = 1;
    for (clip, 0..) |a, i| {
        const b = clip[(i + 1) % clip.len];
        const d0 = direction * cross(a, b, first);
        const d1 = direction * cross(a, b, last);
        if (!std.math.isFinite(d0) or !std.math.isFinite(d1)) return error.InvalidAccessibilityGeometry;
        if (d0 < 0 and d1 < 0) return null;
        if ((d0 < 0) != (d1 < 0)) {
            const t = d0 / (d0 - d1);
            if (d0 < 0) lo = @max(lo, t) else hi = @min(hi, t);
        }
    }
    if (lo >= hi) return null;
    return .{
        .{ .x = first.x + lo * (last.x - first.x), .y = first.y + lo * (last.y - first.y) },
        .{ .x = first.x + hi * (last.x - first.x), .y = first.y + hi * (last.y - first.y) },
    };
}

pub const Polygon = struct {
    points: std.ArrayList(Point) = .empty,
    scratch: std.ArrayList(Point) = .empty,
    pub fn deinit(self: *Polygon, allocator: std.mem.Allocator) void {
        self.points.deinit(allocator);
        self.scratch.deinit(allocator);
    }
    pub fn set(self: *Polygon, allocator: std.mem.Allocator, points: []const Point) !void {
        self.points.clearRetainingCapacity();
        if (points.len > 4096) return error.AccessibilityGeometryQuota;
        try self.points.appendSlice(allocator, points);
    }
    fn append(self: *Polygon, allocator: std.mem.Allocator, p: Point) !void {
        if (self.scratch.items.len == 4096) return error.AccessibilityGeometryQuota;
        try self.scratch.append(allocator, p);
    }
    pub fn intersect(self: *Polygon, allocator: std.mem.Allocator, clip: []const Point) !void {
        const signed_area = area(clip);
        if (signed_area == 0) {
            self.points.clearRetainingCapacity();
            return;
        }
        const direction: f64 = if (signed_area > 0) 1 else -1;
        for (clip, 0..) |a, index| {
            if (self.points.items.len == 0) break;
            const b = clip[(index + 1) % clip.len];
            self.scratch.clearRetainingCapacity();
            var previous = self.points.items[self.points.items.len - 1];
            var previous_distance = direction * cross(a, b, previous);
            for (self.points.items) |current| {
                const distance = direction * cross(a, b, current);
                if ((distance >= 0) != (previous_distance >= 0)) {
                    const t = previous_distance / (previous_distance - distance);
                    try self.append(allocator, .{
                        .x = previous.x + t * (current.x - previous.x),
                        .y = previous.y + t * (current.y - previous.y),
                    });
                }
                if (distance >= 0) try self.append(allocator, current);
                previous = current;
                previous_distance = distance;
            }
            std.mem.swap(std.ArrayList(Point), &self.points, &self.scratch);
        }
    }
    pub fn bounds(self: *const Polygon) !?types.ComputedRect {
        if (area(self.points.items) == 0) return null;
        var min = self.points.items[0];
        var max = min;
        for (self.points.items) |p| {
            min.x = @min(min.x, p.x);
            min.y = @min(min.y, p.y);
            max.x = @max(max.x, p.x);
            max.y = @max(max.y, p.y);
        }
        const result = types.ComputedRect.init(@floatCast(min.x), @floatCast(min.y), @floatCast(max.x - min.x), @floatCast(max.y - min.y));
        if (!std.math.isFinite(result.x) or !std.math.isFinite(result.y) or
            !std.math.isFinite(result.w) or !std.math.isFinite(result.h) or
            !std.math.isFinite(result.x + result.w) or !std.math.isFinite(result.y + result.h)) return error.InvalidAccessibilityGeometry;
        return if (result.w > 0 and result.h > 0) result else null;
    }
};

test "a11y convex geometry rejects AABB-only overlap and respects reflected winding" {
    const t = std.testing;
    const diamond = [_]Point{ .{ .x = 0, .y = 5 }, .{ .x = 5, .y = 0 }, .{ .x = 10, .y = 5 }, .{ .x = 5, .y = 10 } };
    var polygon: Polygon = .{};
    defer polygon.deinit(t.allocator);
    const outside = try rectangle(.{ .x = 0, .y = 0, .w = 1, .h = 1 }, .{});
    try polygon.set(t.allocator, &outside);
    try polygon.intersect(t.allocator, &diamond);
    try t.expect(try polygon.bounds() == null);
    const partial = try rectangle(.{ .x = 0, .y = 0, .w = 4, .h = 4 }, .{});
    try polygon.set(t.allocator, &partial);
    try polygon.intersect(t.allocator, &diamond);
    try t.expectEqualDeep(types.ComputedRect.init(1, 1, 3, 3), (try polygon.bounds()).?);
    var reversed = diamond;
    std.mem.reverse(Point, &reversed);
    try polygon.set(t.allocator, &partial);
    try polygon.intersect(t.allocator, &reversed);
    try t.expectEqualDeep(types.ComputedRect.init(1, 1, 3, 3), (try polygon.bounds()).?);
    const edge = try rectangle(.{ .x = -1, .y = 4, .w = 1, .h = 2 }, .{});
    try polygon.set(t.allocator, &edge);
    try polygon.intersect(t.allocator, &diamond);
    try t.expect(try polygon.bounds() == null);
}

test "a11y caret line clips preserve orientation and reject polygon AABB corners" {
    const t = std.testing;
    const diamond = [_]Point{ .{ .x = 0, .y = 5 }, .{ .x = 5, .y = 0 }, .{ .x = 10, .y = 5 }, .{ .x = 5, .y = 10 } };
    const line = (try clipSegment(.{ .x = 2, .y = -10 }, .{ .x = 2, .y = 20 }, &diamond)).?;
    try t.expectApproxEqAbs(@as(f64, 3), line[0].y, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 7), line[1].y, 1e-9);
    var reflected = diamond;
    std.mem.reverse(Point, &reflected);
    const reverse = (try clipSegment(.{ .x = 2, .y = 20 }, .{ .x = 2, .y = -10 }, &reflected)).?;
    try t.expectEqualDeep(line[1], reverse[0]);
    try t.expectEqualDeep(line[0], reverse[1]);
    try t.expect(try clipSegment(.{ .x = 1, .y = 0 }, .{ .x = 1, .y = 1 }, &diamond) == null);
    try t.expect(try clipSegment(.{ .x = -1, .y = 4 }, .{ .x = 0, .y = 5 }, &diamond) == null);
}
