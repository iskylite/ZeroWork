//! Vulkan device bootstrap. Linux-only; not yet selected by gpu.Backend.
//! Keep software acceptance explicit while the renderer contract is implemented.
const std = @import("std");
pub const Handle = opaque {};
pub const resources = @import("resources.zig");
pub const pipeline = @import("pipeline.zig");
pub const shaders = @import("renderer_shaders.zig");
pub const renderer_resources = @import("renderer_resources.zig");

pub const DeviceInfo = extern struct {
    name: [256]u8,
    api_version: u32,
    driver_version: u32,
    vendor_id: u32,
    device_id: u32,
    device_type: u32,
    queue_family: u32,
    max_image_dimension_2d: u32,

    pub fn deviceName(self: *const DeviceInfo) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }

    pub fn isSoftware(self: DeviceInfo) bool {
        // Only Vulkan's known GPU categories count toward the accelerated gate.
        return self.device_type != 1 and self.device_type != 2 and self.device_type != 3;
    }
};

pub const Diagnostic = extern struct {
    operation: [128]u8 = @splat(0),
    vk_result: i32 = 0,

    pub fn resultCode(self: *const Diagnostic) i64 {
        return self.vk_result;
    }
    pub fn operationName(self: *const Diagnostic) []const u8 {
        return std.mem.sliceTo(&self.operation, 0);
    }
};

pub const Error = error{
    LoaderUnavailable,
    SymbolUnavailable,
    NoGraphicsDevice,
    SoftwareDeviceRejected,
    VulkanApiFailed,
    InvalidDescriptor,
    OutOfMemory,
    ValidationUnavailable,
    SurfaceOutdated,
    SurfaceLost,
    Timeout,
    PresentationRetirementPending,
    ResourcesAlive,
};

pub fn check(status: c_int) Error!void {
    return switch (status) {
        0 => {},
        1 => error.LoaderUnavailable,
        2 => error.SymbolUnavailable,
        3 => error.NoGraphicsDevice,
        4 => error.SoftwareDeviceRejected,
        5 => error.VulkanApiFailed,
        6 => error.InvalidDescriptor,
        7 => error.OutOfMemory,
        8 => error.ValidationUnavailable,
        9 => error.SurfaceOutdated,
        10 => error.SurfaceLost,
        11 => error.Timeout,
        12 => error.ResourcesAlive,
        else => error.VulkanApiFailed,
    };
}

extern fn zenit_vk_device_create(c_int, c_int, ?*anyopaque, ?*anyopaque, *?*Handle, *DeviceInfo, *Diagnostic) c_int;
extern fn zenit_vk_device_destroy(?*Handle) i32;
extern fn zenit_vk_validation_errors(*const Handle) u32;
extern fn zenit_vk_render_probe(*Handle, u32, u32, [*]u8, usize, [*]const u32, usize, [*]const u32, usize, *Diagnostic) c_int;
extern fn zenit_vk_present_texture(*Handle, *anyopaque, *Diagnostic) c_int;
extern fn zenit_vk_present_clear(*Handle, u32, u32, *const [4]f32, *Diagnostic) c_int;

pub const Device = struct {
    handle: ?*Handle,
    info: DeviceInfo,
    wayland_display: ?*anyopaque = null,
    wayland_surface: ?*anyopaque = null,

    pub const Options = struct {
        allow_software: bool = false,
        require_validation: bool = false,
        wayland_display: ?*anyopaque = null,
        wayland_surface: ?*anyopaque = null,
    };

    pub fn init(options: Options, diagnostic: *Diagnostic) Error!Device {
        var result: Device = .{ .handle = null, .info = undefined };
        try check(zenit_vk_device_create(@intFromBool(options.allow_software), @intFromBool(options.require_validation), options.wayland_display, options.wayland_surface, &result.handle, &result.info, diagnostic));
        result.wayland_display = options.wayland_display;
        result.wayland_surface = options.wayland_surface;
        return result;
    }

    /// Returns validation errors including teardown. Idempotent on success.
    /// If presentation retirement times out, retain ownership for a retry.
    pub fn deinit(self: *Device) Error!u32 {
        const errors = zenit_vk_device_destroy(self.handle);
        if (errors == -2) return error.ResourcesAlive;
        if (errors < 0) return error.PresentationRetirementPending;
        self.handle = null;
        return @intCast(errors);
    }

    pub fn maxTextureDimension2D(self: *const Device) u32 {
        return self.info.max_image_dimension_2d;
    }
    /// Native Vulkan draw/transfer/present operations already complete before returning.
    pub fn completeSubmission(self: *Device) Error!void {
        if (self.handle == null) return error.InvalidDescriptor;
    }
    pub fn validationErrors(self: *const Device) u32 {
        return if (self.handle) |handle| zenit_vk_validation_errors(handle) else 0;
    }

    pub fn createBufferResource(self: *Device, size: u64, usage: u32, diagnostic: *Diagnostic) Error!resources.Buffer {
        return resources.Buffer.init(self, size, usage, diagnostic);
    }

    pub fn createTextureResource(self: *Device, width: u32, height: u32, format: resources.Format, diagnostic: *Diagnostic) Error!resources.Texture {
        return resources.Texture.init(self, width, height, format, diagnostic);
    }

    pub fn renderProbe(self: *Device, width: u32, height: u32, bgra: []u8, vertex: []align(4) const u8, fragment: []align(4) const u8, diagnostic: *Diagnostic) Error!void {
        const handle = self.handle orelse return error.InvalidDescriptor;
        try check(zenit_vk_render_probe(handle, width, height, bgra.ptr, bgra.len, @ptrCast(vertex.ptr), vertex.len, @ptrCast(fragment.ptr), fragment.len, diagnostic));
    }

    pub fn presentTexture(self: *Device, texture: *resources.Texture, diagnostic: *Diagnostic) Error!void {
        try check(zenit_vk_present_texture(self.handle orelse return error.InvalidDescriptor, @ptrCast(texture.handle orelse return error.InvalidDescriptor), diagnostic));
    }

    pub fn presentClear(self: *Device, width: u32, height: u32, rgba: [4]f32, diagnostic: *Diagnostic) Error!void {
        const handle = self.handle orelse return error.InvalidDescriptor;
        try check(zenit_vk_present_clear(handle, width, height, &rgba, diagnostic));
    }
};
