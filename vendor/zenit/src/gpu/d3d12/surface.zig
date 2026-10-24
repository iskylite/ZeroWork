//! HWND flip-discard Surface over the Device's single ordered queue.
//! Render-thread confined; acquired frames/views must be released before resize.
const std = @import("std");
const gpu = @import("../gpu.zig");
const b = @import("renderer_device.zig");
const resources = @import("renderer_resources.zig");
extern fn zenit_d12_surface_create(*anyopaque, *anyopaque, u32, u32, u32, u32, *?*anyopaque) c_int;
extern fn zenit_d12_surface_resize(*anyopaque, u32, u32, u32) c_int;
extern fn zenit_d12_surface_size(*anyopaque, *u32, *u32) c_int;
extern fn zenit_d12_surface_acquire(*anyopaque, *?*anyopaque) c_int;
extern fn zenit_d12_surface_present(*anyopaque, *anyopaque, u32, *c_int) c_int;
extern fn zenit_d12_surface_discard(*anyopaque, *anyopaque) c_int;
extern fn zenit_d12_surface_destroy(*anyopaque, u32) c_int;
fn status(value: c_int) !void {
    return switch (value) {
        0 => {},
        1 => error.InvalidSurface,
        3 => error.GpuTimeout,
        4 => error.DeviceLost,
        5 => error.SurfaceBusy,
        else => error.NativeGpuFailure,
    };
}
pub const SurfaceUsage = enum { color_target_only, color_target_and_read };
pub const PresentMode = enum { fifo, immediate, mailbox };
pub const AlphaMode = enum { fully_opaque, premultiplied, postmultiplied };
pub const SurfaceConfiguration = struct {
    format: gpu.TextureFormat,
    width: u32,
    height: u32,
    usage: SurfaceUsage = .color_target_only,
    present_mode: PresentMode = .fifo,
    alpha_mode: AlphaMode = .fully_opaque,
    maximum_frame_latency: u32 = 2,
};
pub const Surface = struct {
    hwnd: *anyopaque,
    raw: ?*anyopaque = null,
    context: ?*resources.Context = null,
    config: ?SurfaceConfiguration = null,
    pub fn init(hwnd: *anyopaque) Surface {
        return .{ .hwnd = hwnd };
    }
    pub fn configure(self: *Surface, allocator: std.mem.Allocator, device: *b.Device, config: SurfaceConfiguration) !void {
        _ = allocator;
        if (config.alpha_mode != .fully_opaque) return error.UnsupportedSurfaceAlpha;
        if (config.present_mode == .mailbox) return error.UnsupportedPresentMode;
        if (config.maximum_frame_latency < 1 or config.maximum_frame_latency > 15) return error.InvalidSurface;
        const format: u32 = switch (config.format) {
            .bgra8_unorm => 87,
            .bgra8_unorm_srgb => 91,
            .rgba8_unorm => 28,
            .rgba8_unorm_srgb => 29,
            .rgba16_float => 10,
            else => return error.UnsupportedSurfaceFormat,
        };
        if (self.raw) |raw| {
            if (self.context.? != device.context) return error.InvalidSurfaceDevice;
            const old = self.config.?;
            if (old.format != config.format or old.maximum_frame_latency != config.maximum_frame_latency) return error.UnsupportedSurfaceReconfiguration;
            try status(zenit_d12_surface_resize(raw, config.width, config.height, device.context.timeout_ms));
        } else {
            var raw: ?*anyopaque = null;
            try status(zenit_d12_surface_create(device.context.queue.raw, self.hwnd, config.width, config.height, format, config.maximum_frame_latency + 1, &raw));
            self.raw = raw.?;
            self.context = device.context;
            device.context.resources += 1;
        }
        self.config = config;
    }
    pub fn acquireTexture(self: *Surface, allocator: std.mem.Allocator) !SurfaceTexture {
        _ = allocator;
        const raw = self.raw orelse return error.SurfaceNotConfigured;
        var width: u32 = 0;
        var height: u32 = 0;
        try status(zenit_d12_surface_size(raw, &width, &height));
        var texture: ?*anyopaque = null;
        try status(zenit_d12_surface_acquire(raw, &texture));
        const context = self.context.?;
        context.resources += 1;
        const size: gpu.Extent3D = .{ .width = width, .height = height };
        const format = self.config.?.format;
        return .{ .surface = raw, .interval = if (self.config.?.present_mode == .fifo) 1 else 0, .texture = .{
            .context = context,
            .format = format,
            .size = size,
            .mip_level_count = 1,
            .dimension = .@"2d",
            .memory = .device_local,
            .inner = .{ .raw = @ptrCast(texture.?), .size = size, .format = format, .mip_level_count = 1, .dimension = .@"2d", .memory = .device_local, .sample_count = 1 },
        } };
    }
    pub fn deinitChecked(self: *Surface) !void {
        if (self.raw) |raw| {
            try status(zenit_d12_surface_destroy(raw, self.context.?.timeout_ms));
            self.context.?.resources -= 1;
        }
        self.* = undefined;
    }
    pub fn deinit(self: *Surface) void {
        self.deinitChecked() catch @panic("D3D12 Surface still in use");
    }
};
pub const SurfaceTexture = struct {
    texture: resources.Texture,
    surface: *anyopaque,
    interval: u32,
    presented: bool = false,
    occluded: bool = false,
    pub fn preparePresentChecked(self: *SurfaceTexture, command: *const b.CommandBuffer) !void {
        if (self.presented) return error.SurfaceAlreadyPresented;
        if (command.shared.context != self.texture.context) return error.InvalidSurfaceDevice;
    }
    pub fn preparePresent(self: *SurfaceTexture, command: *const b.CommandBuffer) void {
        self.preparePresentChecked(command) catch @panic("invalid D3D12 present preparation");
    }
    pub fn presentAfterSubmitChecked(self: *SurfaceTexture, command: *const b.CommandBuffer) !void {
        try self.preparePresentChecked(command);
        if (command.shared.serial == null) return error.CommandNotSubmitted;
        var occluded: c_int = 0;
        try status(zenit_d12_surface_present(self.surface, self.texture.inner.raw, self.interval, &occluded));
        self.occluded = occluded != 0;
        self.presented = true;
    }
    pub fn presentAfterSubmit(self: *SurfaceTexture, command: *const b.CommandBuffer) void {
        self.presentAfterSubmitChecked(command) catch @panic("D3D12 present failed");
    }
    pub fn deinit(self: *SurfaceTexture) void {
        if (!self.presented) status(zenit_d12_surface_discard(self.surface, self.texture.inner.raw)) catch @panic("invalid D3D12 frame discard");
        self.texture.destroy();
        self.* = undefined;
    }
};
