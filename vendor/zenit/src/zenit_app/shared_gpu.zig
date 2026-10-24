//! Heap-stable process GPU owner. Borrowing windows must all die before deinit.
const std = @import("std");
const gpu = @import("gpu");
const render = @import("render");
const platform = @import("platform");

pub const SharedGpu = struct {
    allocator: std.mem.Allocator,
    instance: gpu.Backend.Instance,
    device: gpu.Backend.Device,
    queue: gpu.Backend.Queue,
    images: render.ImageTextureStore,

    pub fn init(allocator: std.mem.Allocator, window: ?*platform.Window, allow_software: bool, require_validation: bool) !*SharedGpu {
        const self = try allocator.create(SharedGpu);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.instance = if (comptime gpu.backend_kind == .vulkan or gpu.backend_kind == .opengl) blk: {
            const native = try (window orelse return error.WindowRequired).nativeSurface();
            break :blk try gpu.Backend.Instance.initWithOptions(allocator, .{}, .{
                .allow_software = allow_software,
                .require_validation = require_validation,
                .wayland_display = native.display,
                .wayland_surface = native.surface,
            });
        } else try gpu.Backend.Instance.init(allocator, .{});
        errdefer self.instance.deinit();
        const adapters = try self.instance.enumerateAdapters();
        defer allocator.free(adapters);
        defer for (adapters) |*adapter| adapter.deinit();
        if (adapters.len == 0) return error.NoGPU;
        const dq = try adapters[0].requestDevice(allocator, .{});
        self.device = dq.device;
        self.queue = dq.queue;
        self.images.init(allocator, &self.device, true);
        return self;
    }

    /// Establish an ordered completion boundary before releasing shared textures.
    pub fn drain(self: *SharedGpu) void {
        if (comptime gpu.is_direct3d) {
            self.queue.context.flushUploads() catch @panic("shared GPU upload drain failed");
            self.queue.context.queue.waitIdle(self.queue.context.timeout_ms) catch @panic("shared GPU queue drain failed");
        } else if (comptime gpu.backend_kind == .metal) {
            var encoder = gpu.Backend.CommandEncoder.init(&self.queue) catch @panic("shared GPU drain encoder failed");
            defer encoder.deinit();
            var command = encoder.finish() catch @panic("shared GPU drain command failed");
            defer command.deinit();
            command.submit();
            command.waitUntilCompleted();
        }
        // Linux submissions (including uploads) complete synchronously; Null has no GPU work.
    }

    pub fn deinit(self: *SharedGpu) void {
        self.drain();
        self.images.deinit();
        self.queue.deinit();
        self.device.deinit();
        self.instance.deinit();
        self.allocator.destroy(self);
    }
};
