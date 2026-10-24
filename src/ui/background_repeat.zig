//! Integer copies of a background tile. The expanded texture is only a
//! rendering batch: its pixels and window-space phase are the original image.
const std = @import("std");

pub const staging_budget = 1024 * 1024;
pub const minimum_period = 64;
pub const Texture = struct { id: u32, width: u32, height: u32 };
pub const Plan = struct { width: u32, height: u32, bytes: usize };
pub const Pixels = struct { width: u32, height: u32, rgba: []u8 };

pub fn plan(width: u32, height: u32) !?Plan {
    const source_bytes = try byteCount(width, height);
    if (source_bytes >= staging_budget) return null;
    var x: usize = if (width < minimum_period) (minimum_period + width - 1) / width else 1;
    var y: usize = if (height < minimum_period) (minimum_period + height - 1) / height else 1;
    const max_copies = staging_budget / source_bytes;
    if (x * y > max_copies) {
        // Both short edges always fit the budget. Only a long strip can
        // exceed it; use the largest affordable integer copy on its short axis.
        if (x > 1) x = @min(x, max_copies) else y = @min(y, max_copies);
    }
    if (x == 1 and y == 1) return null;
    const result_width = try std.math.mul(u32, width, @intCast(x));
    const result_height = try std.math.mul(u32, height, @intCast(y));
    return .{ .width = result_width, .height = result_height, .bytes = try byteCount(result_width, result_height) };
}

/// A single additional allocation, never larger than staging_budget. Large
/// sources and already adequate periods keep their original texture only.
pub fn expand(allocator: std.mem.Allocator, width: u32, height: u32, source: []const u8) !?Pixels {
    if (source.len != try byteCount(width, height)) return error.InvalidPixels;
    const target = (try plan(width, height)) orelse return null;
    const rgba = try allocator.alloc(u8, target.bytes);
    const row_bytes = @as(usize, width) * 4;
    const expanded_row_bytes = @as(usize, target.width) * 4;
    for (0..height) |row| {
        const original = source[row * row_bytes ..][0..row_bytes];
        var offset = row * expanded_row_bytes;
        for (0..target.width / width) |_| {
            @memcpy(rgba[offset..][0..row_bytes], original);
            offset += row_bytes;
        }
    }
    const band_bytes = @as(usize, height) * expanded_row_bytes;
    for (1..target.height / height) |band| @memcpy(rgba[band * band_bytes ..][0..band_bytes], rgba[0..band_bytes]);
    return .{ .width = target.width, .height = target.height, .rgba = rgba };
}

fn byteCount(width: u32, height: u32) !usize {
    if (width == 0 or height == 0) return error.InvalidPixels;
    return std.math.mul(usize, try std.math.mul(usize, width, height), 4);
}

pub const Grid = struct { first_x: f64, first_y: f64, cols: usize, rows: usize, count: usize };

/// The phase always comes from alignment of the original image. Expanding
/// its integer period must not align the larger texture a second time.
pub fn grid(window_width: f64, window_height: f64, phase_x: f64, phase_y: f64, period_width: f64, period_height: f64) !Grid {
    if (!std.math.isFinite(window_width) or !std.math.isFinite(window_height) or window_width <= 0 or window_height <= 0 or
        !std.math.isFinite(phase_x) or !std.math.isFinite(phase_y) or
        !std.math.isFinite(period_width) or !std.math.isFinite(period_height) or period_width <= 0 or period_height <= 0) return error.InvalidGeometry;
    const first_x = phase_x + @floor(-phase_x / period_width) * period_width;
    const first_y = phase_y + @floor(-phase_y / period_height) * period_height;
    const cols_float = @ceil((window_width - first_x) / period_width);
    const rows_float = @ceil((window_height - first_y) / period_height);
    const limit: f64 = @floatFromInt(std.math.maxInt(usize));
    if (!std.math.isFinite(cols_float) or !std.math.isFinite(rows_float) or cols_float >= limit or rows_float >= limit) return error.InvalidGeometry;
    const cols: usize = @intFromFloat(cols_float);
    const rows: usize = @intFromFloat(rows_float);
    return .{ .first_x = first_x, .first_y = first_y, .cols = cols, .rows = rows, .count = try std.math.mul(usize, cols, rows) };
}

test "background repeat tiny and nondivisible periods stay integer and within the staging budget" {
    const tiny = (try plan(1, 1)).?;
    try std.testing.expectEqual(Plan{ .width = 64, .height = 64, .bytes = 64 * 64 * 4 }, tiny);
    const uneven = (try plan(3, 5)).?;
    try std.testing.expectEqual(@as(u32, 66), uneven.width);
    try std.testing.expectEqual(@as(u32, 65), uneven.height);
    try std.testing.expect(uneven.bytes <= staging_budget);
    try std.testing.expect(try plan(64, 128) == null);
    try std.testing.expect(try plan(512, 512) == null);
    try std.testing.expect(try plan(1024, 512) == null);
    try std.testing.expectError(error.InvalidPixels, plan(0, 1));
}

test "background repeat long strips use the maximum affordable integer copies" {
    const tall = (try plan(1, 16384)).?;
    try std.testing.expectEqual(Plan{ .width = 16, .height = 16384, .bytes = staging_budget }, tall);
    const wide = (try plan(10000, 3)).?;
    try std.testing.expectEqual(@as(u32, 10000), wide.width);
    try std.testing.expectEqual(@as(u32, 24), wide.height);
    try std.testing.expect(wide.bytes <= staging_budget);
    try std.testing.expect(wide.bytes + 10000 * 3 * 4 > staging_budget);
}

test "background repeat copies exact RGBA samples including alpha" {
    const allocator = std.testing.allocator;
    var original: [3 * 5 * 4]u8 = undefined;
    for (&original, 0..) |*byte, index| byte.* = @intCast(index);
    const expanded = (try expand(allocator, 3, 5, &original)).?;
    defer allocator.free(expanded.rgba);
    for (0..expanded.height) |y| for (0..expanded.width) |x| {
        const source_offset = ((y % 5) * 3 + x % 3) * 4;
        const target_offset = (y * expanded.width + x) * 4;
        try std.testing.expectEqualSlices(u8, original[source_offset..][0..4], expanded.rgba[target_offset..][0..4]);
    };
    const single = (try expand(allocator, 1, 1, &.{ 3, 7, 11, 19 })).?;
    defer allocator.free(single.rgba);
    for (0..single.rgba.len / 4) |index| try std.testing.expectEqualSlices(u8, &.{ 3, 7, 11, 19 }, single.rgba[index * 4 ..][0..4]);
    try std.testing.expectError(error.InvalidPixels, expand(allocator, 3, 5, &.{0}));
}

test "background repeat nine alignment phases sample the original image and bound a 1px grid" {
    const tiled = (try plan(3, 5)).?;
    for ([_]f64{ 0, 0.5, 1 }) |align_x| for ([_]f64{ 0, 0.5, 1 }) |align_y| {
        const phase_x = (1439.5 - 3) * align_x;
        const phase_y = (899.5 - 5) * align_y;
        const expanded = try grid(1439.5, 899.5, phase_x, phase_y, @floatFromInt(tiled.width), @floatFromInt(tiled.height));
        try std.testing.expect(expanded.first_x <= 0 and expanded.first_y <= 0);
        try std.testing.expect(expanded.first_x + @as(f64, @floatFromInt(expanded.cols)) * @as(f64, @floatFromInt(tiled.width)) >= 1439.5);
        try std.testing.expect(expanded.first_y + @as(f64, @floatFromInt(expanded.rows)) * @as(f64, @floatFromInt(tiled.height)) >= 899.5);
        for (0..20) |index| {
            const x = 0.25 + @as(f64, @floatFromInt(index)) * 71;
            const y = 0.25 + @as(f64, @floatFromInt(index)) * 43;
            try std.testing.expectEqual(@mod(@floor(x - phase_x), 3), @mod(@floor(x - expanded.first_x), 3));
            try std.testing.expectEqual(@mod(@floor(y - phase_y), 5), @mod(@floor(y - expanded.first_y), 5));
        }
    };
    const tiny = (try plan(1, 1)).?;
    const bounded = try grid(1440, 900, 719.5, 449.5, @floatFromInt(tiny.width), @floatFromInt(tiny.height));
    try std.testing.expect(bounded.count <= 24 * 16);
}
