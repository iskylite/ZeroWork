//! Bounded remote-frame crop/scale and PNG encoding. No window, file, clipboard,
//! URL or transport access is available here. The caller retains its FrameLease
//! until this synchronous copy has finished.
const std = @import("std");
const frames = @import("framebuffer.zig");
const images = @import("../../ai/image_attachments.zig");

pub const max_width = 1920;
pub const max_height = 1200;
pub const Region = struct { x: u32 = 0, y: u32 = 0, width: u32, height: u32 };
pub const Point = struct { x: f64, y: f64 };
pub const RemotePoint = struct { x: u16, y: u16 };
pub const Transform = struct {
    region: Region,
    output_width: u32,
    output_height: u32,

    /// The model uses the exact returned image's pixel space. The same integer
    /// nearest-neighbour transform is used for pixels and remote coordinates.
    /// Coordinates outside that image are rejected, never clamped.
    pub fn remote(self: Transform, point: Point) !RemotePoint {
        if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y) or point.x < 0 or point.y < 0 or point.x >= @as(f64, @floatFromInt(self.output_width)) or point.y >= @as(f64, @floatFromInt(self.output_height))) return error.CoordinateOutOfBounds;
        const x = self.region.x + @as(u32, @intCast(@as(u64, @intFromFloat(@floor(point.x))) * self.region.width / self.output_width));
        const y = self.region.y + @as(u32, @intCast(@as(u64, @intFromFloat(@floor(point.y))) * self.region.height / self.output_height));
        return .{ .x = std.math.cast(u16, x) orelse return error.CoordinateOutOfBounds, .y = std.math.cast(u16, y) orelse return error.CoordinateOutOfBounds };
    }
};

pub fn transform(width: u32, height: u32, region: ?Region, requested_width: u32, requested_height: u32) !Transform {
    if (width == 0 or height == 0 or width > 65536 or height > 65536) return error.InvalidFrame;
    const crop = region orelse Region{ .width = width, .height = height };
    if (crop.width == 0 or crop.height == 0 or crop.x >= width or crop.y >= height or crop.width > width - crop.x or crop.height > height - crop.y) return error.InvalidRegion;
    if (requested_width == 0 or requested_height == 0 or requested_width > max_width or requested_height > max_height) return error.InvalidOutputSize;
    var output_width = crop.width;
    var output_height = crop.height;
    // No upscaling. Keep aspect ratio and round down so both bounds hold.
    if (@as(u64, crop.width) * requested_height > @as(u64, crop.height) * requested_width) {
        if (output_width > requested_width) {
            output_width = requested_width;
            output_height = @max(1, @as(u32, @intCast(@as(u64, crop.height) * requested_width / crop.width)));
        }
    } else if (output_height > requested_height) {
        output_height = requested_height;
        output_width = @max(1, @as(u32, @intCast(@as(u64, crop.width) * requested_height / crop.height)));
    }
    return .{ .region = crop, .output_width = output_width, .output_height = output_height };
}

pub fn copyPixels(a: std.mem.Allocator, snapshot: frames.Snapshot, mapping: Transform) ![]u8 {
    if (snapshot.format != .rgba8 or snapshot.width == 0 or snapshot.height == 0) return error.InvalidFrame;
    const row = try std.math.mul(usize, snapshot.width, 4);
    const preceding = try std.math.mul(usize, snapshot.height - 1, snapshot.stride);
    const required = try std.math.add(usize, preceding, row);
    if (snapshot.stride < row or snapshot.pixels.len < required) return error.InvalidFrame;
    // Reject forged transforms as well as malformed framebuffer snapshots.
    _ = try transform(snapshot.width, snapshot.height, mapping.region, max_width, max_height);
    if (mapping.output_width == 0 or mapping.output_height == 0 or mapping.output_width > max_width or mapping.output_height > max_height or mapping.output_width > mapping.region.width or mapping.output_height > mapping.region.height) return error.InvalidOutputSize;
    const bytes = try a.alloc(u8, @as(usize, mapping.output_width) * mapping.output_height * 4);
    errdefer a.free(bytes);
    for (0..mapping.output_height) |y| {
        const sy = mapping.region.y + @as(u32, @intCast(@as(u64, y) * mapping.region.height / mapping.output_height));
        for (0..mapping.output_width) |x| {
            const sx = mapping.region.x + @as(u32, @intCast(@as(u64, x) * mapping.region.width / mapping.output_width));
            const source = @as(usize, sy) * snapshot.stride + @as(usize, sx) * 4;
            const destination = (y * mapping.output_width + x) * 4;
            @memcpy(bytes[destination..][0..4], snapshot.pixels[source..][0..4]);
        }
    }
    return bytes;
}

/// Exact output-pixel comparison on an existing immutable frame lease. A new
/// sequence can carry identical pixels; no encoding/allocation is needed then.
pub fn matchesPixels(snapshot: frames.Snapshot, mapping: Transform, content: images.Content) bool {
    if (content.width != mapping.output_width or content.height != mapping.output_height or snapshot.stride < @as(usize, snapshot.width) * 4) return false;
    if (mapping.region.width == mapping.output_width and mapping.region.height == mapping.output_height) {
        const row_bytes = @as(usize, mapping.output_width) * 4;
        for (0..mapping.output_height) |y| {
            const source = (@as(usize, mapping.region.y) + y) * snapshot.stride + @as(usize, mapping.region.x) * 4;
            const destination = y * row_bytes;
            if (source + row_bytes > snapshot.pixels.len or destination + row_bytes > content.pixels.len or !std.mem.eql(u8, snapshot.pixels[source..][0..row_bytes], content.pixels[destination..][0..row_bytes])) return false;
        }
        return true;
    }
    for (0..mapping.output_height) |y| {
        const sy = mapping.region.y + @as(u32, @intCast(@as(u64, y) * mapping.region.height / mapping.output_height));
        for (0..mapping.output_width) |x| {
            const sx = mapping.region.x + @as(u32, @intCast(@as(u64, x) * mapping.region.width / mapping.output_width));
            const source = @as(usize, sy) * snapshot.stride + @as(usize, sx) * 4;
            const destination = (y * mapping.output_width + x) * 4;
            if (source + 4 > snapshot.pixels.len or destination + 4 > content.pixels.len or !std.mem.eql(u8, snapshot.pixels[source..][0..4], content.pixels[destination..][0..4])) return false;
        }
    }
    return true;
}

const Ref = *const anyopaque;
extern "c" fn CFDataCreateMutable(?Ref, isize) ?Ref;
extern "c" fn CFDataGetLength(Ref) isize;
extern "c" fn CFDataGetBytePtr(Ref) [*]const u8;
extern "c" fn CFRelease(Ref) void;
extern "c" fn CGColorSpaceCreateDeviceRGB() ?Ref;
extern "c" fn CGDataProviderCreateWithData(?*anyopaque, [*]const u8, usize, ?*const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void) ?Ref;
extern "c" fn CGImageCreate(usize, usize, usize, usize, usize, Ref, u32, Ref, ?[*]const f64, bool, i32) ?Ref;
extern "c" fn CGImageDestinationCreateWithData(Ref, Ref, usize, ?Ref) ?Ref;
extern "c" fn CGImageDestinationAddImage(Ref, Ref, ?Ref) void;
extern "c" fn CGImageDestinationFinalize(Ref) bool;
extern "c" fn CFStringCreateWithCString(?Ref, [*:0]const u8, u32) ?Ref;

/// The image bytes are immutable ContentRef data. Its source label is not a
/// filesystem path and must not be serialized to a provider as image content.
pub fn capture(a: std.mem.Allocator, snapshot: frames.Snapshot, mapping: Transform, captured_ms: u64) !images.ContentRef {
    const pixels = try copyPixels(a, snapshot, mapping);
    errdefer a.free(pixels);
    const space = CGColorSpaceCreateDeviceRGB() orelse return error.OutOfMemory;
    defer CFRelease(space);
    const provider = CGDataProviderCreateWithData(null, pixels.ptr, pixels.len, null) orelse return error.OutOfMemory;
    defer CFRelease(provider);
    const native = CGImageCreate(mapping.output_width, mapping.output_height, 8, 32, @as(usize, mapping.output_width) * 4, space, 1 | (4 << 12), provider, null, false, 0) orelse return error.InvalidImage;
    defer CFRelease(native);
    const data = CFDataCreateMutable(null, 0) orelse return error.OutOfMemory;
    defer CFRelease(data);
    const uti = CFStringCreateWithCString(null, "public.png", 0x08000100) orelse return error.OutOfMemory;
    defer CFRelease(uti);
    const destination = CGImageDestinationCreateWithData(data, uti, 1, null) orelse return error.InvalidImage;
    defer CFRelease(destination);
    CGImageDestinationAddImage(destination, native, null);
    if (!CGImageDestinationFinalize(destination)) return error.InvalidImage;
    const length = CFDataGetLength(data);
    if (length <= 0) return error.InvalidImage;
    if (length > images.max_bytes) return error.ImageTooLarge;
    return images.ContentRef.fromHostPng(a, CFDataGetBytePtr(data)[0..@intCast(length)], pixels, mapping.output_width, mapping.output_height, std.math.cast(i64, captured_ms) orelse return error.InvalidCaptureTime);
}
