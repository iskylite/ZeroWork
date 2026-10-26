//! V3 shared feedback uses one fixed app-relative origin.
const std = @import("std");
pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };
pub const clearance: f32 = 8;
pub const edge: f32 = 20;
pub const top: f32 = 62;
pub const bottom: f32 = 44;

pub fn separated(a: Rect, b: Rect) bool {
    return a.x + a.w <= b.x - clearance or a.x >= b.x + b.w + clearance or
        a.y + a.h <= b.y - clearance or a.y >= b.y + b.h + clearance;
}

/// Global feedback has one stable origin. Overlap is handled by pausing its
/// presentation, never by moving the stack to an unrelated corner.
pub fn position(app: Rect, width: f32, height: f32, _: []const Rect) Rect {
    const w = @min(width, @max(0, app.w - 2 * edge));
    const h = @min(@max(0, height), @max(0, app.h - 2 * clearance));
    return .{ .x = app.x + @max(clearance, app.w - w - edge), .y = app.y + @min(top, @max(clearance, app.h - h - clearance)), .w = w, .h = h };
}

test "fixed feedback origin stays right twenty top sixty-two despite overlays" {
    const app: Rect = .{ .x = 0, .y = 0, .w = 1440, .h = 900 };
    const first = position(app, 340, 48, &.{});
    try std.testing.expectEqual(@as(f32, 1080), first.x);
    try std.testing.expectEqual(@as(f32, 62), first.y);
    const covered = position(app, 340, 48, &.{.{ .x = 1000, .y = 50, .w = 400, .h = 500 }});
    try std.testing.expectEqual(first, covered);
    const compact = position(.{ .x = 30, .y = 20, .w = 860, .h = 480 }, 340, 200, &.{});
    try std.testing.expectEqual(@as(f32, 530), compact.x);
    try std.testing.expectEqual(@as(f32, 82), compact.y);
}
