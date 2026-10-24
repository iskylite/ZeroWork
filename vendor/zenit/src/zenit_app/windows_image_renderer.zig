//! Windows RGBA texture facade matching the public App image-renderer API.
const std = @import("std");
const image = @import("render");
extern fn zenit_d3d11_texture_load(native: *anyopaque, width: u32, height: u32, rgba: [*]const u8) u32;
extern fn zenit_d3d11_texture_unload(native: *anyopaque, id: u32) void;
extern fn zenit_d3d11_texture_size(native: *anyopaque, id: u32, size: *[2]u32) c_int;
extern fn zenit_d3d11_texture_stats(native: *anyopaque, count: *u32, bytes: *u64) void;

pub const ImageRenderer = struct {
    native: *anyopaque,

    pub fn loadTexture(self: *ImageRenderer, width: u32, height: u32, rgba: []const u8) !u32 {
        if (width == 0 or height == 0 or width > 16384 or height > 16384) return error.InvalidDimensions;
        const bytes = try std.math.mul(usize, try std.math.mul(usize, width, height), 4);
        if (rgba.len != bytes) return error.InvalidPixelData;
        const id = zenit_d3d11_texture_load(self.native, width, height, rgba.ptr);
        if (id == 0) return error.TextureUploadFailed;
        return id;
    }

    pub fn unloadTexture(self: *ImageRenderer, id: u32) void {
        zenit_d3d11_texture_unload(self.native, id);
    }

    pub fn getTextureSize(self: *const ImageRenderer, id: u32) ?[2]u32 {
        var size: [2]u32 = undefined;
        if (zenit_d3d11_texture_size(self.native, id, &size) == 0) return null;
        return size;
    }

    pub fn getTextureMemoryStats(self: *const ImageRenderer) image.TextureMemoryStats {
        var count: u32 = 0;
        var bytes: u64 = 0;
        zenit_d3d11_texture_stats(self.native, &count, &bytes);
        return .{ .texture_count = count, .estimated_bytes = bytes, .atlas_page_count = 0, .slots_used = count, .slots_total = 4096 };
    }
};
