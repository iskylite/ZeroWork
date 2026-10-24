//! Owned EGL/OpenGL device for Linux Wayland. Thread confined; the Wayland
//! display and surface are borrowed until checked deinit succeeds.
const std = @import("std");
pub const renderer_pipeline = @import("renderer_pipeline.zig");
pub const Handle = opaque {};
pub const resources = @import("resources.zig");
pub const pipeline = @import("pipeline.zig");
pub const manifest = @import("generated/shaders.zig");
pub const shaders = @import("renderer_shaders.zig");
pub const renderer_resources = @import("renderer_resources.zig");
pub const Info = extern struct {
    vendor: [256]u8,
    renderer: [256]u8,
    version: [256]u8,
    driver: [128]u8,
    software: u32,
    egl_major: u32,
    egl_minor: u32,
    max_texture_size: u32,
    uniform_buffer_bindings: u32,
    uniform_block_size: u32,
    storage_buffer_bindings: u32,
    vertex_storage_blocks: u32,
    fragment_storage_blocks: u32,
    fragment_texture_units: u32,
    combined_texture_units: u32,
    pub fn deviceName(self: *const Info) []const u8 {
        return std.mem.sliceTo(&self.renderer, 0);
    }
    pub fn driverName(self: *const Info) []const u8 {
        return std.mem.sliceTo(&self.driver, 0);
    }
    pub fn isSoftware(self: Info) bool {
        return self.software != 0;
    }
};
pub const Diagnostic = extern struct {
    operation: [128]u8 = @splat(0),
    api_result: u32 = 0,
    pub fn resultCode(self: *const Diagnostic) i64 {
        return self.api_result;
    }
    pub fn operationName(self: *const Diagnostic) []const u8 {
        return std.mem.sliceTo(&self.operation, 0);
    }
};
pub const Error = error{ InvalidDescriptor, LoaderUnavailable, SymbolUnavailable, OpenGlApiFailed, SoftwareDeviceRejected, OutOfMemory, RenderThreadViolation, DisplayAlreadyOwned, ResourcesAlive, Timeout };
pub fn check(status: c_int) Error!void {
    return switch (status) {
        0 => {},
        1 => error.InvalidDescriptor,
        2 => error.LoaderUnavailable,
        3 => error.SymbolUnavailable,
        4 => error.OpenGlApiFailed,
        5 => error.SoftwareDeviceRejected,
        6 => error.OutOfMemory,
        7 => error.RenderThreadViolation,
        8 => error.DisplayAlreadyOwned,
        9 => error.ResourcesAlive,
        else => error.OpenGlApiFailed,
    };
}
extern fn zenit_gl_device_create(*anyopaque, *anyopaque, u32, u32, c_int, c_int, *?*Handle, *Info, *Diagnostic) c_int;
extern fn zenit_gl_device_destroy(?*Handle, *u32, *Diagnostic) c_int;
extern fn zenit_gl_make_current(*Handle, *Diagnostic) c_int;
extern fn zenit_gl_release_current(*Handle, *Diagnostic) c_int;
extern fn zenit_gl_resize(*Handle, u32, u32, *Diagnostic) c_int;
extern fn zenit_gl_present(*Handle, *Diagnostic) c_int;
extern fn zenit_gl_present_texture(*Handle, *anyopaque, u32, u32, *Diagnostic) c_int;
extern fn zenit_gl_get_proc(*Handle, [*:0]const u8) ?*anyopaque;
extern fn zenit_gl_validation_errors(*const Handle) u32;
extern fn zenit_gl_timer_begin(*Handle, *Diagnostic) c_int;
extern fn zenit_gl_timer_end(*Handle, *Diagnostic) c_int;
extern fn zenit_gl_timer_finish(*Handle, *u64, *u32, *Diagnostic) c_int;
extern fn zenit_gl_retain_resource(*Handle, *Diagnostic) c_int;
extern fn zenit_gl_release_resource(*Handle, *Diagnostic) c_int;

/// Move-only. Explicit resource leases keep checked teardown from invalidating
/// borrowed native GL objects. A failed close retains the caller's handle.
pub const Device = struct {
    handle: ?*Handle,
    info: Info,
    wayland_display: ?*anyopaque,
    wayland_surface: ?*anyopaque,
    submission_fence: ?resources.Fence = null,
    pub const Options = struct {
        wayland_display: ?*anyopaque = null,
        wayland_surface: ?*anyopaque = null,
        width: u32 = 1,
        height: u32 = 1,
        allow_software: bool = false,
        require_validation: bool = false,
    };
    pub fn init(options: Options, diag: *Diagnostic) Error!Device {
        var handle: ?*Handle = null;
        var info: Info = undefined;
        try check(zenit_gl_device_create(options.wayland_display orelse return error.InvalidDescriptor, options.wayland_surface orelse return error.InvalidDescriptor, options.width, options.height, @intFromBool(options.allow_software), @intFromBool(options.require_validation), &handle, &info, diag));
        return .{ .handle = handle, .info = info, .wayland_display = options.wayland_display, .wayland_surface = options.wayland_surface };
    }
    pub fn deinit(self: *Device) Error!u32 {
        var diag: Diagnostic = .{};
        return self.deinitChecked(&diag);
    }
    pub fn deinitChecked(self: *Device, diag: *Diagnostic) Error!u32 {
        if (self.submission_fence) |*fence| {
            if (!try fence.retire(10_000_000_000, diag)) return error.Timeout;
            self.submission_fence = null;
        }
        var errors: u32 = 0;
        try check(zenit_gl_device_destroy(self.handle, &errors, diag));
        self.handle = null;
        return errors;
    }
    pub fn createBufferResource(self: *Device, size: u64, usage: u32, diag: *Diagnostic) Error!resources.Buffer {
        return resources.Buffer.init(self, size, usage, diag);
    }
    pub fn createTextureResource(self: *Device, width: u32, height: u32, format: resources.Format, diag: *Diagnostic) Error!resources.Texture {
        return resources.Texture.init(self, width, height, format, diag);
    }
    pub fn maxTextureDimension2D(self: *const Device) u32 {
        return self.info.max_texture_size;
    }
    pub fn beginSubmissionTiming(self: *Device) Error!void {
        var diagnostic: Diagnostic = .{};
        try check(zenit_gl_timer_begin(self.handle orelse return error.InvalidDescriptor, &diagnostic));
    }
    pub fn finishSubmissionTiming(self: *Device) Error!?u64 {
        var diagnostic: Diagnostic = .{};
        var nanoseconds: u64 = 0;
        var valid: u32 = 0;
        try check(zenit_gl_timer_finish(self.handle orelse return error.InvalidDescriptor, &nanoseconds, &valid, &diagnostic));
        return if (valid != 0) nanoseconds else null;
    }
    pub fn endSubmissionTiming(self: *Device) Error!void {
        var diagnostic: Diagnostic = .{};
        try check(zenit_gl_timer_end(self.handle orelse return error.InvalidDescriptor, &diagnostic));
    }
    /// One GPU completion boundary per recorded command batch. A timeout
    /// preserves the owned fence for checked device retirement or retry.
    pub fn completeSubmission(self: *Device) Error!void {
        var diag: Diagnostic = .{};
        if (self.submission_fence == null) self.submission_fence = try resources.Fence.init(self, &diag);
        if (!try self.submission_fence.?.retire(10_000_000_000, &diag)) return error.Timeout;
        self.submission_fence = null;
    }
    pub fn presentTexture(self: *Device, texture: *resources.Texture, diag: *Diagnostic) Error!void {
        try check(zenit_gl_present_texture(self.handle orelse return error.InvalidDescriptor, @ptrCast(texture.handle orelse return error.InvalidDescriptor), texture.width, texture.height, diag));
    }
    pub fn makeCurrent(self: *Device, diag: *Diagnostic) Error!void {
        try check(zenit_gl_make_current(self.handle orelse return error.InvalidDescriptor, diag));
    }
    pub fn releaseCurrent(self: *Device, diag: *Diagnostic) Error!void {
        try check(zenit_gl_release_current(self.handle orelse return error.InvalidDescriptor, diag));
    }
    pub fn resize(self: *Device, width: u32, height: u32, diag: *Diagnostic) Error!void {
        try check(zenit_gl_resize(self.handle orelse return error.InvalidDescriptor, width, height, diag));
    }
    /// Swap and release current context. The caller renders/blits before this.
    pub fn present(self: *Device, diag: *Diagnostic) Error!void {
        try check(zenit_gl_present(self.handle orelse return error.InvalidDescriptor, diag));
    }
    pub fn getProc(self: *Device, name: [:0]const u8) ?*anyopaque {
        return zenit_gl_get_proc(self.handle orelse return null, name.ptr);
    }
    pub fn validationErrors(self: *const Device) u32 {
        return zenit_gl_validation_errors(self.handle orelse return 0);
    }
    pub fn retainResource(self: *Device, diag: *Diagnostic) Error!void {
        try check(zenit_gl_retain_resource(self.handle orelse return error.InvalidDescriptor, diag));
    }
    pub fn releaseResource(self: *Device, diag: *Diagnostic) Error!void {
        try check(zenit_gl_release_resource(self.handle orelse return error.InvalidDescriptor, diag));
    }
};
comptime {
    if (@sizeOf(Info) != 940 or @sizeOf(Diagnostic) != 132) @compileError("OpenGL native ABI mismatch");
}

extern fn zenit_gl_snapshot_equal([*]const u8, [*]const u8, usize) c_int;
pub fn snapshotBytesEqual(lhs: []const u8, rhs: []const u8) bool {
    return lhs.len == rhs.len and zenit_gl_snapshot_equal(lhs.ptr, rhs.ptr, lhs.len) != 0;
}
