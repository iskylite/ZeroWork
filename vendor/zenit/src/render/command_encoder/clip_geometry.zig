//! Clip geometry algebra: pure functions decoupled from encoder state.
//!
//! This cluster answers: **are two clip shapes equivalent / what is the intersection of two
//! rectangles / how do external duck-typed polygons normalize to the encoder's fixed-length
//! ClipPolygon**. All take and return values only: no self, no allocation, no side effects. Stack
//! **push/pop** stays in the encoder (clip_depth / logical_clip_stack / effective_rect_clip_stack);
//! **comparison and normalization** of stack elements live here.
//!
//! Equivalence always uses approxEqAbs(1e-4): clip coords go through world->local projection and
//! DPI scaling, so bitwise comparison would treat the same clip as different and rebuild the clip
//! mask every frame.
//!
//! command_encoder.zig re-exports the same names (including pub intersectClipRects).

const std = @import("std");

/// These types still owned by command_encoder.zig (its public API surface), received here per
/// struct contract; passing comptime type params makes signature more complex than migration
/// itself, so use anytype + explicit return type keeps call sites zero-change.
pub fn clipPolygonEqual(a: anytype, b: @TypeOf(a)) bool {
    if (a.point_count != b.point_count or a.contour_count != b.contour_count or a.fill_rule != b.fill_rule) return false;
    const max_contours = a.contour_end_points.len;
    const max_points = a.points.len;
    const contour_count = @min(@as(usize, a.contour_count), max_contours);
    for (0..contour_count) |i| {
        if (a.contour_end_points[i] != b.contour_end_points[i]) return false;
    }
    const count = @min(@as(usize, a.point_count), max_points);
    for (0..count) |i| {
        if (!std.math.approxEqAbs(f32, a.points[i][0], b.points[i][0], 0.0001) or
            !std.math.approxEqAbs(f32, a.points[i][1], b.points[i][1], 0.0001))
        {
            return false;
        }
    }
    return true;
}

/// Rounded clip state equivalence. null == null treated as equivalent (both mean 'no rounded
/// clip').
pub fn roundedClipEqual(a: anytype, b: @TypeOf(a)) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    const lhs = a.?;
    const rhs = b.?;
    return std.math.approxEqAbs(f32, lhs.x, rhs.x, 0.0001) and
        std.math.approxEqAbs(f32, lhs.y, rhs.y, 0.0001) and
        std.math.approxEqAbs(f32, lhs.w, rhs.w, 0.0001) and
        std.math.approxEqAbs(f32, lhs.h, rhs.h, 0.0001) and
        std.math.approxEqAbs(f32, lhs.radius, rhs.radius, 0.0001) and
        lhs.shape_kind == rhs.shape_kind and
        clipPolygonEqual(lhs.polygon, rhs.polygon);
}

/// Intersect two [x, y, w, h] rects. No overlap returns zero-area rect (keep top-left so caller's
/// scissor stays legal input not negative width/height).
pub fn intersectClipRects(a: [4]f32, b: [4]f32) [4]f32 {
    const x1 = @max(a[0], b[0]);
    const y1 = @max(a[1], b[1]);
    const x2 = @min(a[0] + a[2], b[0] + b[2]);
    const y2 = @min(a[1] + a[3], b[1] + b[3]);
    if (x2 <= x1 or y2 <= y1) return .{ x1, y1, 0, 0 };
    return .{ x1, y1, x2 - x1, y2 - y1 };
}

/// Duck-typed external polygon -> encoder fixed-length ClipPolygon.
///
/// `Out` is command_encoder.ClipPolygon; `coerceFillRule` converts source fill_rule enum to encoder
/// side same-sequence enum. Source types missing fields degrade to empty polygon, points/outlines
/// exceeding fixed-length capacity clamped to limit (encoder clip polygon is fixed array).
pub fn coerceClipPolygon(
    comptime Out: type,
    polygon: anytype,
    comptime coerceFillRule: anytype,
) Out {
    var out = Out.empty();
    if (!@hasField(@TypeOf(polygon), "point_count") or !@hasField(@TypeOf(polygon), "points")) {
        return out;
    }
    const max_points = out.points.len;
    const max_contours = out.contour_end_points.len;
    const count = @min(@as(usize, polygon.point_count), max_points);
    out.point_count = @intCast(count);
    if (@hasField(@TypeOf(polygon), "fill_rule")) {
        out.fill_rule = coerceFillRule(polygon.fill_rule);
    }
    if (@hasField(@TypeOf(polygon), "contour_count") and @hasField(@TypeOf(polygon), "contour_end_points")) {
        const contour_count = @min(@as(usize, polygon.contour_count), max_contours);
        out.contour_count = @intCast(contour_count);
        for (0..contour_count) |i| {
            out.contour_end_points[i] = @min(polygon.contour_end_points[i], out.point_count);
        }
    } else if (count > 0) {
        out.contour_count = 1;
        out.contour_end_points[0] = out.point_count;
    }
    for (0..count) |i| {
        out.points[i] = polygon.points[i];
    }
    return out;
}
