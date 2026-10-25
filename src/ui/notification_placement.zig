//! V3 workspace positionToasts: ordered app-corner candidates with an 8px
//! clearance around every open detail card. Geometry is in window coordinates.
const std = @import("std");
pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };
pub const clearance: f32 = 8;
pub const edge: f32 = 12;
pub const top: f32 = 58;
pub const bottom: f32 = 44;

pub fn separated(a: Rect, b: Rect) bool {
    return a.x + a.w <= b.x - clearance or a.x >= b.x + b.w + clearance or
        a.y + a.h <= b.y - clearance or a.y >= b.y + b.h + clearance;
}

pub fn position(app: Rect, width: f32, height: f32, avoid: []const Rect) Rect {
    const w = @min(width, @max(0, app.w - 2 * edge));
    const h = @max(0, height);
    const left = app.x + @min(edge, @max(0, (app.w - w) / 2));
    const right = @max(left, app.x + app.w - w - edge);
    const min_y = app.y + @min(clearance, @max(0, (app.h - h) / 2));
    const max_y = @max(min_y, app.y + app.h - h - clearance);
    const upper = std.math.clamp(app.y + top, min_y, max_y);
    const lower = std.math.clamp(app.y + app.h - h - bottom, min_y, max_y);
    const candidates = [_]Rect{
        .{ .x = right, .y = upper, .w = w, .h = h },
        .{ .x = left, .y = upper, .w = w, .h = h },
        .{ .x = right, .y = lower, .w = w, .h = h },
        .{ .x = left, .y = lower, .w = w, .h = h },
    };
    for (candidates) |candidate| {
        var free = true;
        for (avoid) |obstacle| {
            if (obstacle.w > 0 and obstacle.h > 0 and !separated(candidate, obstacle)) {
                free = false;
                break;
            }
        }
        if (free) return candidate;
    }
    // Match the prototype's top-left fallback when every corner is occupied.
    return candidates[1];
}

test "V3 ordered corners retain eight-pixel detail clearance" {
    const app: Rect = .{ .x = 0, .y = 0, .w = 1440, .h = 900 };
    const toast = position(app, 320, 48, &.{});
    try std.testing.expectEqual(@as(f32, 1108), toast.x);
    try std.testing.expectEqual(top, toast.y);
    const manager: Rect = .{ .x = 890, .y = 52, .w = 470, .h = 600 };
    const moved = position(app, 320, 48, &.{manager});
    try std.testing.expectEqual(edge, moved.x);
    try std.testing.expect(separated(moved, manager));
    const left: Rect = .{ .x = 0, .y = 50, .w = 360, .h = 80 };
    const lower = position(app, 320, 48, &.{ manager, left });
    try std.testing.expectEqual(toast.x, lower.x);
    try std.testing.expectEqual(@as(f32, 808), lower.y);
    try std.testing.expect(separated(lower, manager));
}

test "V3 avoids all cards and keeps compact and moved app bounds" {
    for ([_]Rect{ .{ .x = 0, .y = 0, .w = 860, .h = 640 }, .{ .x = 30, .y = 20, .w = 1120, .h = 760 } }) |app| {
        const obstacles = [_]Rect{.{ .x = app.x + app.w - 372, .y = app.y + 52, .w = 360, .h = 420 }};
        const result = position(app, 320, 160, &obstacles);
        try std.testing.expect(separated(result, obstacles[0]));
        try std.testing.expect(result.x >= app.x + clearance);
        try std.testing.expect(result.x + result.w <= app.x + app.w - clearance);
        try std.testing.expect(result.y + result.h <= app.y + app.h - clearance);
    }
    const cramped = position(.{ .x = 0, .y = 0, .w = 300, .h = 120 }, 340, 100, &.{});
    try std.testing.expectEqual(@as(f32, 276), cramped.w);
    try std.testing.expectEqual(@as(f32, 12), cramped.y);
}

test "V3 separation includes exact clearance and fallback" {
    const a: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 48 };
    try std.testing.expect(separated(a, .{ .x = 108, .y = 0, .w = 100, .h = 48 }));
    try std.testing.expect(!separated(a, .{ .x = 107, .y = 0, .w = 100, .h = 48 }));
    const expanded: Rect = .{ .x = 22, .y = 51, .w = 760, .h = 359 };
    const compact = position(.{ .x = 0, .y = 0, .w = 860, .h = 480 }, 320, 45, &.{expanded});
    try std.testing.expectEqual(edge, compact.x);
    try std.testing.expectEqual(top, compact.y);
    try std.testing.expect(!separated(compact, expanded));

    const result = position(.{ .x = 0, .y = 0, .w = 860, .h = 640 }, 320, 48, &.{.{ .x = 0, .y = 0, .w = 860, .h = 640 }});
    try std.testing.expectEqual(edge, result.x);
    try std.testing.expectEqual(top, result.y);
}
