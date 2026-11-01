//! RFB true-colour pixels. Written from the public RFB wire specification;
//! no vendor SPA or third-party implementation is included.
const std = @import("std");

pub const PixelFormat = struct {
    bits_per_pixel: u8 = 32,
    depth: u8 = 24,
    big_endian: bool = false,
    red_max: u16 = 255,
    green_max: u16 = 255,
    blue_max: u16 = 255,
    red_shift: u8 = 16,
    green_shift: u8 = 8,
    blue_shift: u8 = 0,

    pub fn parse(bytes: []const u8) !PixelFormat {
        // RFC 6143 §7.4 defines both flags as zero/any-nonzero, not 0/1.
        // The observed BMC uses 255 for true-colour in ServerInit.
        if (bytes.len < 16 or bytes[3] == 0) return error.UnsupportedPixelFormat;
        const result: PixelFormat = .{
            .bits_per_pixel = bytes[0],
            .depth = bytes[1],
            .big_endian = bytes[2] != 0,
            .red_max = std.mem.readInt(u16, bytes[4..6], .big),
            .green_max = std.mem.readInt(u16, bytes[6..8], .big),
            .blue_max = std.mem.readInt(u16, bytes[8..10], .big),
            .red_shift = bytes[10],
            .green_shift = bytes[11],
            .blue_shift = bytes[12],
        };
        try result.validate();
        return result;
    }

    pub fn validate(self: PixelFormat) !void {
        if ((self.bits_per_pixel != 8 and self.bits_per_pixel != 16 and self.bits_per_pixel != 32) or
            self.depth == 0 or self.depth > self.bits_per_pixel) return error.UnsupportedPixelFormat;
        var used: u32 = 0;
        var colour_bits: u8 = 0;
        const maximums = [_]u16{ self.red_max, self.green_max, self.blue_max };
        const shifts = [_]u8{ self.red_shift, self.green_shift, self.blue_shift };
        for (maximums, shifts) |maximum, shift| {
            if (maximum == 0 or (maximum & (maximum +% 1)) != 0) return error.UnsupportedPixelFormat;
            const bits: u8 = @intCast(16 - @clz(maximum));
            if (shift >= self.bits_per_pixel or @as(u16, shift) + bits > self.bits_per_pixel) return error.UnsupportedPixelFormat;
            const mask = @as(u32, maximum) << @intCast(shift);
            if (used & mask != 0) return error.UnsupportedPixelFormat;
            used |= mask;
            colour_bits += bits;
        }
        if (colour_bits > self.depth) return error.UnsupportedPixelFormat;
    }

    pub fn write(self: PixelFormat, out: *[16]u8) void {
        out.* = @splat(0);
        out[0] = self.bits_per_pixel;
        out[1] = self.depth;
        out[2] = @intFromBool(self.big_endian);
        out[3] = 1;
        std.mem.writeInt(u16, out[4..6], self.red_max, .big);
        std.mem.writeInt(u16, out[6..8], self.green_max, .big);
        std.mem.writeInt(u16, out[8..10], self.blue_max, .big);
        out[10] = self.red_shift;
        out[11] = self.green_shift;
        out[12] = self.blue_shift;
    }

    pub fn bytesPerPixel(self: PixelFormat) usize {
        return self.bits_per_pixel / 8;
    }
    pub fn compact(self: PixelFormat) bool {
        return self.bits_per_pixel == 32 and self.depth == 24 and self.red_max == 255 and self.green_max == 255 and self.blue_max == 255;
    }
    pub fn tightBytesPerPixel(self: PixelFormat) usize {
        return if (self.compact()) 3 else self.bytesPerPixel();
    }

    pub fn components(self: PixelFormat, bytes: []const u8, tight: bool) [3]u16 {
        if (tight and self.compact()) return .{ bytes[0], bytes[1], bytes[2] };
        var value: u32 = 0;
        for (bytes[0..self.bytesPerPixel()], 0..) |b, i| {
            const shift: u5 = @intCast((if (self.big_endian) self.bytesPerPixel() - 1 - i else i) * 8);
            value |= @as(u32, b) << shift;
        }
        return .{
            @intCast((value >> @intCast(self.red_shift)) & self.red_max),
            @intCast((value >> @intCast(self.green_shift)) & self.green_max),
            @intCast((value >> @intCast(self.blue_shift)) & self.blue_max),
        };
    }
    pub fn rgba(self: PixelFormat, bytes: []const u8, tight: bool) [4]u8 {
        return self.componentsRgba(self.components(bytes, tight));
    }
    pub fn componentsRgba(self: PixelFormat, value: [3]u16) [4]u8 {
        return .{ scale(value[0], self.red_max), scale(value[1], self.green_max), scale(value[2], self.blue_max), 255 };
    }
};

fn scale(value: u16, maximum: u16) u8 {
    return @intCast((@as(u32, value) * 255 + maximum / 2) / maximum);
}

pub const Rect = struct { x: u16, y: u16, width: u16, height: u16 };

pub fn byteLength(width: u32, height: u32, bytes_per_pixel: usize) !usize {
    return std.math.mul(usize, try std.math.mul(usize, width, height), bytes_per_pixel) catch error.FrameLimitExceeded;
}
pub fn checkRectangle(rect: Rect, width: u16, height: u16) !void {
    if (rect.width == 0 or rect.height == 0 or
        @as(u32, rect.x) + rect.width > width or @as(u32, rect.y) + rect.height > height) return error.RectangleOutOfBounds;
}
pub fn put(frame: []u8, frame_width: u16, rect: Rect, index: usize, colour: [4]u8) void {
    const offset = ((@as(usize, rect.y) + index / rect.width) * frame_width + rect.x + index % rect.width) * 4;
    @memcpy(frame[offset..][0..4], &colour);
}

test "pixel format endian, arbitrary shifts, 565 scaling and invalid masks" {
    const t = std.testing;
    const rgb565: PixelFormat = .{ .bits_per_pixel = 16, .depth = 16, .big_endian = true, .red_max = 31, .green_max = 63, .blue_max = 31, .red_shift = 11, .green_shift = 5, .blue_shift = 0 };
    try rgb565.validate();
    try t.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, &rgb565.rgba(&.{ 0xf8, 0x00 }, false));
    try t.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, &rgb565.rgba(&.{ 0x07, 0xe0 }, false));
    const shifted: PixelFormat = .{ .red_shift = 0, .green_shift = 16, .blue_shift = 8, .big_endian = true };
    try shifted.validate();
    try t.expectEqualSlices(u8, &.{ 3, 1, 2, 255 }, &shifted.rgba(&.{ 0, 1, 2, 3 }, false));
    try t.expectEqualSlices(u8, &.{ 7, 8, 9, 255 }, &shifted.rgba(&.{ 7, 8, 9 }, true));
    var bad = shifted;
    bad.red_shift = 8;
    try t.expectError(error.UnsupportedPixelFormat, bad.validate());
    bad = shifted;
    bad.red_max = 254;
    try t.expectError(error.UnsupportedPixelFormat, bad.validate());
}
