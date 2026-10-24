const std = @import("std");

pub const Gutter = struct { enabled: bool = false, width: u16 = 64, separator: []const u8 = "  " };

pub fn formatTimestamp(buffer: []u8, timestamp_ms: i64) ![]const u8 {
    const seconds = @divFloor(timestamp_ms, 1000);
    const millis = @mod(timestamp_ms, 1000);
    const digits: [3]u8 = .{ @intCast(@divTrunc(millis, 100)), @intCast(@rem(@divTrunc(millis, 10), 10)), @intCast(@rem(millis, 10)) };
    return std.fmt.bufPrint(buffer, "[{d}.{d}{d}{d}]", .{ seconds, digits[0], digits[1], digits[2] });
}

pub fn prefixLine(gutter: Gutter, buffer: []u8, timestamp_ms: i64, line: []const u8) ![]const u8 {
    if (!gutter.enabled) return if (line.len <= buffer.len) line else error.BufferTooSmall;
    var stamp: [32]u8 = undefined;
    const prefix = try formatTimestamp(&stamp, timestamp_ms);
    if (prefix.len + gutter.separator.len + line.len > buffer.len) return error.BufferTooSmall;
    @memcpy(buffer[0..prefix.len], prefix);
    @memcpy(buffer[prefix.len .. prefix.len + gutter.separator.len], gutter.separator);
    @memcpy(buffer[prefix.len + gutter.separator.len ..][0..line.len], line);
    return buffer[0 .. prefix.len + gutter.separator.len + line.len];
}

test "timestamp gutter is optional and prefixes lines" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hello", try prefixLine(.{}, &buffer, 0, "hello"));
    const line = try prefixLine(.{ .enabled = true }, &buffer, 1234, "hello");
    try std.testing.expectEqualStrings("[1.234]  hello", line);
}
