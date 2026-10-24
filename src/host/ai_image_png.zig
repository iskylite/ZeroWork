//! Clipboard TIFF normalization. All decoding/encoding stays on its reader worker.
const std = @import("std");
const asset = @import("../config/background_asset.zig");
const images = @import("../ai/image_attachments.zig");
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
pub fn convert(allocator: std.mem.Allocator, bytes: []const u8, requested: images.Limits) ![]u8 {
    const limits = requested.effective();
    var image = try asset.decode(allocator, bytes, .{ .source_bytes = limits.bytes, .dimension = limits.dimension, .pixels = limits.pixels });
    defer image.deinit(allocator);
    const space = CGColorSpaceCreateDeviceRGB() orelse return error.OutOfMemory;
    defer CFRelease(space);
    const provider = CGDataProviderCreateWithData(null, image.pixels.ptr, image.pixels.len, null) orelse return error.OutOfMemory;
    defer CFRelease(provider);
    const native = CGImageCreate(image.width, image.height, 8, 32, @as(usize, image.width) * 4, space, 1 | (4 << 12), provider, null, false, 0) orelse return error.InvalidImage;
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
    if (length > limits.bytes) return error.ImageTooLarge;
    return allocator.dupe(u8, CFDataGetBytePtr(data)[0..@intCast(length)]);
}
