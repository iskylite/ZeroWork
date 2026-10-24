//! Native GL buffers. Byte transfers are owned by the device's render thread;
//! checked destruction preserves the handle when native teardown is rejected.
const gl = @import("device.zig");
const BufferHandle = opaque {};
const TextureHandle = opaque {};
pub const Format = enum(u32) { r8_unorm = 1, rgba8_unorm = 2, bgra8_unorm = 3, rgba16_float = 4 };
extern fn zenit_gl_buffer_create(*gl.Handle, u64, u32, *?*BufferHandle, *gl.Diagnostic) c_int;
extern fn zenit_gl_buffer_destroy(?*BufferHandle, *gl.Diagnostic) c_int;
extern fn zenit_gl_buffer_write(*BufferHandle, u64, [*]const u8, usize, *gl.Diagnostic) c_int;
extern fn zenit_gl_buffer_read(*BufferHandle, u64, [*]u8, usize, *gl.Diagnostic) c_int;
extern fn zenit_gl_buffer_copy(*BufferHandle, u64, *BufferHandle, u64, u64, *gl.Diagnostic) c_int;
pub const Buffer = struct {
    handle: ?*BufferHandle,
    size: u64,
    pub fn init(device: *gl.Device, size: u64, usage: u32, diag: *gl.Diagnostic) gl.Error!Buffer {
        var handle: ?*BufferHandle = null;
        try gl.check(zenit_gl_buffer_create(device.handle orelse return error.InvalidDescriptor, size, usage, &handle, diag));
        return .{ .handle = handle, .size = size };
    }
    pub fn destroyChecked(self: *Buffer, diag: *gl.Diagnostic) gl.Error!void {
        try gl.check(zenit_gl_buffer_destroy(self.handle, diag));
        self.handle = null;
    }
    pub fn destroy(self: *Buffer) void {
        var diag: gl.Diagnostic = .{};
        self.destroyChecked(&diag) catch @panic("OpenGL buffer destruction failed");
    }
    pub fn write(self: *Buffer, offset: u64, bytes: []const u8, diag: *gl.Diagnostic) gl.Error!void {
        try gl.check(zenit_gl_buffer_write(self.handle orelse return error.InvalidDescriptor, offset, bytes.ptr, bytes.len, diag));
    }
    pub fn read(self: *Buffer, offset: u64, bytes: []u8, diag: *gl.Diagnostic) gl.Error!void {
        try gl.check(zenit_gl_buffer_read(self.handle orelse return error.InvalidDescriptor, offset, bytes.ptr, bytes.len, diag));
    }
    pub fn copyTo(self: *Buffer, src_offset: u64, destination: *Buffer, dst_offset: u64, size: u64, diag: *gl.Diagnostic) gl.Error!void {
        try gl.check(zenit_gl_buffer_copy(self.handle orelse return error.InvalidDescriptor, src_offset, destination.handle orelse return error.InvalidDescriptor, dst_offset, size, diag));
    }
};

extern fn zenit_gl_texture_create(*gl.Handle, u32, u32, u32, *?*TextureHandle, *gl.Diagnostic) c_int;
extern fn zenit_gl_texture_clear(*TextureHandle, *const [4]f32, *gl.Diagnostic) c_int;
extern fn zenit_gl_texture_copy(*TextureHandle, u32, u32, *TextureHandle, u32, u32, u32, u32, *gl.Diagnostic) c_int;
extern fn zenit_gl_texture_destroy(?*TextureHandle, *gl.Diagnostic) c_int;
extern fn zenit_gl_texture_transfer(*TextureHandle, u32, u32, u32, u32, [*]u8, usize, u32, c_int, *gl.Diagnostic) c_int;

pub const Texture = struct {
    handle: ?*TextureHandle,
    width: u32,
    height: u32,
    format: Format,

    pub fn init(device: *gl.Device, width: u32, height: u32, format: Format, diagnostic: *gl.Diagnostic) gl.Error!Texture {
        var handle: ?*TextureHandle = null;
        try gl.check(zenit_gl_texture_create(device.handle orelse return error.InvalidDescriptor, width, height, @backingInt(format), &handle, diagnostic));
        return .{ .handle = handle, .width = width, .height = height, .format = format };
    }

    pub fn destroyChecked(self: *Texture, diag: *gl.Diagnostic) gl.Error!void {
        try gl.check(zenit_gl_texture_destroy(self.handle, diag));
        self.handle = null;
    }
    pub fn destroy(self: *Texture) void {
        var diag: gl.Diagnostic = .{};
        self.destroyChecked(&diag) catch @panic("OpenGL texture destruction failed");
    }

    pub fn clear(self: *Texture, rgba: [4]f32, diagnostic: *gl.Diagnostic) gl.Error!void {
        try gl.check(zenit_gl_texture_clear(self.handle orelse return error.InvalidDescriptor, &rgba, diagnostic));
    }

    pub fn copyTo(self: *Texture, x: u32, y: u32, destination: *Texture, destination_x: u32, destination_y: u32, width: u32, height: u32, diagnostic: *gl.Diagnostic) gl.Error!void {
        try gl.check(zenit_gl_texture_copy(self.handle orelse return error.InvalidDescriptor, x, y, destination.handle orelse return error.InvalidDescriptor, destination_x, destination_y, width, height, diagnostic));
    }

    pub fn writeRegion(self: *Texture, x: u32, y: u32, width: u32, height: u32, bytes: []const u8, stride: u32, diagnostic: *gl.Diagnostic) gl.Error!void {
        try gl.check(zenit_gl_texture_transfer(self.handle orelse return error.InvalidDescriptor, x, y, width, height, @constCast(bytes.ptr), bytes.len, stride, 1, diagnostic));
    }

    pub fn readRegion(self: *Texture, x: u32, y: u32, width: u32, height: u32, bytes: []u8, stride: u32, diagnostic: *gl.Diagnostic) gl.Error!void {
        try gl.check(zenit_gl_texture_transfer(self.handle orelse return error.InvalidDescriptor, x, y, width, height, bytes.ptr, bytes.len, stride, 0, diagnostic));
    }
};

const SamplerHandle = opaque {};
pub const SamplerDescriptor = extern struct {
    mag_filter: u32 = 0,
    min_filter: u32 = 0,
    mipmap_filter: u32 = 0,
    address_u: u32 = 0,
    address_v: u32 = 0,
    address_w: u32 = 0,
    lod_min: f32 = 0,
    lod_max: f32 = 0,
};
extern fn zenit_gl_sampler_create_descriptor(*gl.Handle, *const SamplerDescriptor, *?*SamplerHandle, *gl.Diagnostic) c_int;
extern fn zenit_gl_sampler_destroy(?*SamplerHandle, *gl.Diagnostic) c_int;
pub const Sampler = struct {
    handle: ?*SamplerHandle,
    pub fn init(device: *gl.Device, linear: bool, repeat: bool, diag: *gl.Diagnostic) gl.Error!Sampler {
        return initDescriptor(device, .{ .mag_filter = @intFromBool(linear), .min_filter = @intFromBool(linear), .address_u = @intFromBool(repeat), .address_v = @intFromBool(repeat), .address_w = @intFromBool(repeat) }, diag);
    }
    pub fn initDescriptor(device: *gl.Device, desc: SamplerDescriptor, diag: *gl.Diagnostic) gl.Error!Sampler {
        var handle: ?*SamplerHandle = null;
        try gl.check(zenit_gl_sampler_create_descriptor(device.handle orelse return error.InvalidDescriptor, &desc, &handle, diag));
        return .{ .handle = handle };
    }
    pub fn destroyChecked(self: *Sampler, diag: *gl.Diagnostic) gl.Error!void {
        try gl.check(zenit_gl_sampler_destroy(self.handle, diag));
        self.handle = null;
    }
    pub fn destroy(self: *Sampler) void {
        var diag: gl.Diagnostic = .{};
        self.destroyChecked(&diag) catch @panic("OpenGL sampler destruction failed");
    }
};
const FenceHandle = opaque {};
extern fn zenit_gl_fence_create(*gl.Handle, *?*FenceHandle, *gl.Diagnostic) c_int;
extern fn zenit_gl_fence_wait(*FenceHandle, u64, *u32, *gl.Diagnostic) c_int;
extern fn zenit_gl_fence_retire(?*FenceHandle, u64, *u32, *gl.Diagnostic) c_int;
/// A device lease until GPU completion and successful checked retirement.
/// Recorded-command owners must hold referenced resources through retirement.
pub const Fence = struct {
    handle: ?*FenceHandle,
    pub fn init(device: *gl.Device, diag: *gl.Diagnostic) gl.Error!Fence {
        var handle: ?*FenceHandle = null;
        try gl.check(zenit_gl_fence_create(device.handle orelse return error.InvalidDescriptor, &handle, diag));
        return .{ .handle = handle };
    }
    pub fn wait(self: *Fence, timeout_ns: u64, diag: *gl.Diagnostic) gl.Error!bool {
        var completed: u32 = 0;
        try gl.check(zenit_gl_fence_wait(self.handle orelse return error.InvalidDescriptor, timeout_ns, &completed, diag));
        return completed != 0;
    }
    /// False leaves the fence owned and retryable; success retires the handle.
    pub fn retire(self: *Fence, timeout_ns: u64, diag: *gl.Diagnostic) gl.Error!bool {
        var completed: u32 = 0;
        try gl.check(zenit_gl_fence_retire(self.handle, timeout_ns, &completed, diag));
        if (completed != 0) self.handle = null;
        return completed != 0;
    }
};
