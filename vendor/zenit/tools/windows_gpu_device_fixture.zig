//! Complete RGBA uploads for Windows texture ownership and replacement contracts.
const std = @import("std");

pub const width: u32 = 2;
pub const height: u32 = 2;
pub const bytes_per_row: u32 = width * 4;
pub const pixels: [width * height][4]u8 = @splat(.{ 1, 2, 3, 255 });

pub fn bytes() []const u8 {
    return std.mem.asBytes(&pixels);
}

test "cross-context fixture supplies every pixel in the two RGBA rows" {
    try std.testing.expectEqual(@as(usize, 16), bytes().len);
    try std.testing.expectEqual(@as(usize, bytes_per_row * height), bytes().len);
    for (0..height) |y| for (0..width) |x| {
        const offset = y * bytes_per_row + x * 4;
        try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255 }, bytes()[offset..][0..4]);
    };
}

pub const green_pixels: [width * height][4]u8 = @splat(.{ 0, 255, 0, 255 });

pub fn greenReplacementBytes() []const u8 {
    return std.mem.asBytes(&green_pixels);
}

test "gallery replacement fixture supplies four opaque green RGBA pixels" {
    const replacement = greenReplacementBytes();
    try std.testing.expectEqual(@as(usize, 16), replacement.len);
    try std.testing.expectEqual(@as(usize, bytes_per_row * height), replacement.len);
    for (0..height) |y| for (0..width) |x| {
        const offset = y * bytes_per_row + x * 4;
        try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, replacement[offset..][0..4]);
    };
}
