//! Owned Vulkan resources. Transfer operations complete before returning.
//! Resources must be destroyed before their device; values must not be copied
//! into multiple owners. A failed transfer never yields a successful readback.
const vk = @import("device.zig");
const BufferHandle = opaque {};
const TextureHandle = opaque {};
pub const Format = enum(u32) { r8_unorm = 1, rgba8_unorm = 2, bgra8_unorm = 3, rgba16_float = 4 };

extern fn zenit_vk_buffer_create(*vk.Handle, u64, u32, *?*BufferHandle, *vk.Diagnostic) c_int;
extern fn zenit_vk_buffer_destroy(?*BufferHandle) void;
extern fn zenit_vk_buffer_write(*BufferHandle, u64, [*]const u8, usize, *vk.Diagnostic) c_int;
extern fn zenit_vk_buffer_read(*BufferHandle, u64, [*]u8, usize, *vk.Diagnostic) c_int;
extern fn zenit_vk_buffer_copy(*BufferHandle, u64, *BufferHandle, u64, u64, *vk.Diagnostic) c_int;
extern fn zenit_vk_texture_create(*vk.Handle, u32, u32, u32, *?*TextureHandle, *vk.Diagnostic) c_int;
extern fn zenit_vk_texture_clear(*TextureHandle, *const [4]f32, *vk.Diagnostic) c_int;
extern fn zenit_vk_texture_copy(*TextureHandle, u32, u32, *TextureHandle, u32, u32, u32, u32, *vk.Diagnostic) c_int;
extern fn zenit_vk_texture_destroy(?*TextureHandle) void;
extern fn zenit_vk_texture_transfer(*TextureHandle, u32, u32, u32, u32, [*]u8, usize, u32, c_int, *vk.Diagnostic) c_int;

pub const Buffer = struct {
    handle: ?*BufferHandle,
    size: u64,

    pub fn init(device: *vk.Device, size: u64, usage: u32, diagnostic: *vk.Diagnostic) vk.Error!Buffer {
        var handle: ?*BufferHandle = null;
        try vk.check(zenit_vk_buffer_create(device.handle orelse return error.InvalidDescriptor, size, usage, &handle, diagnostic));
        return .{ .handle = handle, .size = size };
    }

    pub fn destroy(self: *Buffer) void {
        zenit_vk_buffer_destroy(self.handle);
        self.handle = null;
    }

    pub fn write(self: *Buffer, offset: u64, bytes: []const u8, diagnostic: *vk.Diagnostic) vk.Error!void {
        try vk.check(zenit_vk_buffer_write(self.handle orelse return error.InvalidDescriptor, offset, bytes.ptr, bytes.len, diagnostic));
    }

    pub fn read(self: *Buffer, offset: u64, bytes: []u8, diagnostic: *vk.Diagnostic) vk.Error!void {
        try vk.check(zenit_vk_buffer_read(self.handle orelse return error.InvalidDescriptor, offset, bytes.ptr, bytes.len, diagnostic));
    }

    pub fn copyTo(self: *Buffer, src_offset: u64, destination: *Buffer, dst_offset: u64, size: u64, diagnostic: *vk.Diagnostic) vk.Error!void {
        try vk.check(zenit_vk_buffer_copy(self.handle orelse return error.InvalidDescriptor, src_offset, destination.handle orelse return error.InvalidDescriptor, dst_offset, size, diagnostic));
    }
};

pub const Texture = struct {
    handle: ?*TextureHandle,
    width: u32,
    height: u32,
    format: Format,

    pub fn init(device: *vk.Device, width: u32, height: u32, format: Format, diagnostic: *vk.Diagnostic) vk.Error!Texture {
        var handle: ?*TextureHandle = null;
        try vk.check(zenit_vk_texture_create(device.handle orelse return error.InvalidDescriptor, width, height, @backingInt(format), &handle, diagnostic));
        return .{ .handle = handle, .width = width, .height = height, .format = format };
    }

    pub fn destroy(self: *Texture) void {
        zenit_vk_texture_destroy(self.handle);
        self.handle = null;
    }

    pub fn clear(self: *Texture, rgba: [4]f32, diagnostic: *vk.Diagnostic) vk.Error!void {
        try vk.check(zenit_vk_texture_clear(self.handle orelse return error.InvalidDescriptor, &rgba, diagnostic));
    }

    pub fn copyTo(self: *Texture, x: u32, y: u32, destination: *Texture, destination_x: u32, destination_y: u32, width: u32, height: u32, diagnostic: *vk.Diagnostic) vk.Error!void {
        try vk.check(zenit_vk_texture_copy(self.handle orelse return error.InvalidDescriptor, x, y, destination.handle orelse return error.InvalidDescriptor, destination_x, destination_y, width, height, diagnostic));
    }

    pub fn writeRegion(self: *Texture, x: u32, y: u32, width: u32, height: u32, bytes: []const u8, stride: u32, diagnostic: *vk.Diagnostic) vk.Error!void {
        try vk.check(zenit_vk_texture_transfer(self.handle orelse return error.InvalidDescriptor, x, y, width, height, @constCast(bytes.ptr), bytes.len, stride, 1, diagnostic));
    }

    pub fn readRegion(self: *Texture, x: u32, y: u32, width: u32, height: u32, bytes: []u8, stride: u32, diagnostic: *vk.Diagnostic) vk.Error!void {
        try vk.check(zenit_vk_texture_transfer(self.handle orelse return error.InvalidDescriptor, x, y, width, height, bytes.ptr, bytes.len, stride, 0, diagnostic));
    }
};
