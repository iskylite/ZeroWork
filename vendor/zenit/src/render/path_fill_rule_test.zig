const std = @import("std");
const fill = @import("path_fill_rule.zig");
const Point = fill.Point;
const a = std.testing.allocator;

fn square(comptime x0: f32, comptime y0: f32, comptime size: f32, comptime positive: bool) [4]Point {
    const ccw = [4]Point{ .{ .x = x0, .y = y0 }, .{ .x = x0 + size, .y = y0 }, .{ .x = x0 + size, .y = y0 + size }, .{ .x = x0, .y = y0 + size } };
    return if (positive) ccw else .{ ccw[3], ccw[2], ccw[1], ccw[0] };
}

test "evenodd: a nested contour is a hole whatever its orientation" {
    const outer = square(0, 0, 10, true);
    const inner = square(3, 3, 4, true);
    const plan = try fill.plan(a, &.{ &outer, &inner }, .evenodd);
    defer plan.deinit(a);
    try std.testing.expectEqualSlices(fill.Role, &.{ .outer, .hole }, plan.roles);
    try std.testing.expectEqual(@as(u32, 0), plan.owner[1]);
}

test "nonzero: same orientation stays filled, opposite orientation cuts a hole" {
    const outer = square(0, 0, 10, true);
    const same = square(3, 3, 4, true);
    const opposite = square(3, 3, 4, false);
    const p1 = try fill.plan(a, &.{ &same, &outer }, .nonzero);
    defer p1.deinit(a);
    try std.testing.expectEqualSlices(fill.Role, &.{ .skip, .outer }, p1.roles);
    const p2 = try fill.plan(a, &.{ &outer, &opposite }, .nonzero);
    defer p2.deinit(a);
    try std.testing.expectEqualSlices(fill.Role, &.{ .outer, .hole }, p2.roles);
}

test "evenodd: three nested contours alternate, separate shapes are independent" {
    const big = square(0, 0, 20, true);
    const mid = square(4, 4, 12, false);
    const small = square(8, 8, 4, true);
    const apart = square(30, 0, 5, false);
    const plan = try fill.plan(a, &.{ &small, &apart, &big, &mid }, .evenodd);
    defer plan.deinit(a);
    try std.testing.expectEqualSlices(fill.Role, &.{ .outer, .outer, .outer, .hole }, plan.roles);
    try std.testing.expectEqual(@as(u32, 2), plan.owner[3]);
}

test "bridgeHoles joins a hole into one ring with the hole's area removed" {
    const outer = square(0, 0, 10, true);
    const hole = square(3, 3, 4, false);
    var ring: std.ArrayList(Point) = .empty;
    defer ring.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), try fill.bridgeHoles(a, &ring, &outer, &.{&hole}));
    try std.testing.expectEqual(@as(usize, 4 + 4 + 2), ring.items.len);
    try std.testing.expectApproxEqAbs(@as(f32, 2 * (100 - 16)), fill.signedArea2(ring.items), 1e-3);
}

test "bridgeHoles: two holes side by side, the right one first, both joined" {
    const outer = square(0, 0, 20, true);
    const left = square(2, 2, 4, false);
    const right = square(12, 10, 4, false);
    var ring: std.ArrayList(Point) = .empty;
    defer ring.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), try fill.bridgeHoles(a, &ring, &outer, &.{ &left, &right }));
    try std.testing.expectApproxEqAbs(@as(f32, 2 * (400 - 32)), fill.signedArea2(ring.items), 1e-3);
}
