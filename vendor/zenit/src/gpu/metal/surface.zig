/// Metal Surface implementation
///
/// Wraps CAMetalLayer, provides cross-frame texture acquisition and presentation.
/// Reference: wgpu-hal/src/metal/surface.rs
const std = @import("std");
const gpu = @import("../gpu.zig");
const mtl = @import("metal_bindings.zig");
const conv = @import("conv.zig");
const Device = @import("device.zig").Device;
const resources = @import("resources.zig");

/// Surface - window surface (data only)
pub const Surface = struct {
    layer: *mtl.CAMetalLayer,
    format: ?gpu.TextureFormat = null,
    extent: gpu.Extent3D = .{ .width = 0, .height = 0, .depth = 1 },

    /// Create Surface from platform-native surface handle.
    ///
    /// Parameter is intentionally `*anyopaque`, not `*mtl.CAMetalLayer`: the caller
    /// (`zenit_app/runtime.zig`) gets an opaque pointer from `window.getNativeSurfaceHandle()`;
    /// requiring metal_bindings + `@ptrCast` there would hardcode Metal into the backend
    /// abstraction and block a second backend from compiling.
    ///
    /// Each backend interprets the handle: Metal treats it as CAMetalLayer, Null ignores it.
    pub fn init(layer: *anyopaque) Surface {
        const metal_layer: *mtl.CAMetalLayer = @ptrCast(@alignCast(layer));
        return Surface{
            .layer = mtl.retain(metal_layer),
            .format = null,
            .extent = .{ .width = 0, .height = 0, .depth = 1 },
        };
    }

    /// Configure Surface.
    /// Reference: wgpu-hal surface.rs configure() (61-110)
    pub fn configure(
        self: *Surface,
        allocator: std.mem.Allocator,
        device: *Device,
        config: SurfaceConfiguration,
    ) !void {
        _ = allocator;

        var pool = mtl.AutoreleasePool.init();
        defer pool.deinit();

        // Save configuration
        self.format = config.format;
        self.extent = .{
            .width = config.width,
            .height = config.height,
            .depth = 1,
        };

        // Configure layer
        mtl.metal_layer_set_device(self.layer, device.raw_device);
        mtl.metal_layer_set_pixel_format(
            self.layer,
            @backingInt(conv.toMetalPixelFormat(config.format)),
        );

        // Performance optimization
        const framebuffer_only: c_int = if (config.usage == .color_target_only) 1 else 0;
        mtl.metal_layer_set_framebuffer_only(self.layer, framebuffer_only);

        // Frame buffer control
        mtl.metal_layer_set_maximum_drawable_count(
            self.layer,
            config.maximum_frame_latency + 1,
        );

        // VSync
        const display_sync: c_int = if (config.present_mode == .fifo) 1 else 0;
        mtl.metal_layer_set_display_sync_enabled(self.layer, display_sync);

        // Timeout control (critical!): **disable** nextDrawable timeout.
        //
        // WARNING - don't 'improve' to a bounded wait. A bounded timeout (e.g. 1s, acquireTexture
        // reports error.SurfaceTimeout -> skip frame) makes heavy-blur scenarios (glasslab class)
        // hit
        // the timeout repeatedly; a skipped frame means **nothing drawn**, which looks like no
        // refresh
        // (storybook e2e dropped from 87/87 to 78/87).
        //
        // The worry 'unbounded block freezes UI on GPU stall' doesn't hold: drawable pool
        // exhaustion
        // was caused by a leak (see acquireTexture ABI contract comment), now fixed; under normal
        // load
        // nextDrawable waiting is vsync backpressure and should wait. A bounded timeout turns
        // 'wait a bit' into 'frame dropped', a net loss for heavy GPU scenarios.
        mtl.metal_layer_set_allows_next_drawable_timeout(self.layer, 0);

        // Alpha mode
        const is_opaque_val: c_int = if (config.alpha_mode == AlphaMode.fully_opaque) 1 else 0;
        mtl.metal_layer_set_opaque(self.layer, is_opaque_val);

        // HDR support
        const wants_hdr: c_int = if (config.format == .rgba16_float) 1 else 0;
        mtl.metal_layer_set_wants_edr(self.layer, wants_hdr);

        // Set size
        mtl.metal_layer_set_drawable_size(self.layer, config.width, config.height);
    }

    /// Get current drawable texture.
    /// Reference: wgpu-hal surface.rs acquire_texture() (116-154)
    pub fn acquireTexture(
        self: *Surface,
        allocator: std.mem.Allocator,
    ) !SurfaceTexture {
        _ = allocator;

        var pool = mtl.AutoreleasePool.init();
        defer pool.deinit();

        // Get drawable (critical: in autorelease pool).
        // ABI contract: metal_layer_next_drawable uses __bridge_retained returning +1 owned
        // (metal_bridge.m:566); take over directly, **do not retain again**.
        // An extra retain with a single release in SurfaceTexture.deinit leaks one CAMetalDrawable
        // per frame; the pool has only 2-3, is exhausted in seconds, nextDrawable blocks forever
        // and the screen freezes.
        const drawable = mtl.metal_layer_next_drawable(self.layer) orelse
            return error.SurfaceTimeout;
        errdefer mtl.release(drawable);

        // WARNING—ABI exception: metal_drawable_get_texture defined in metal_bridge.m,
        // uses __bridge (**+0 borrow**), opposite the __bridge_retained contract of other getters
        // here.
        // Thus retain here is **required**, can't delete alongside above.
        const texture_raw = mtl.metal_drawable_get_texture(drawable);
        _ = mtl.retain(texture_raw);
        errdefer mtl.release(texture_raw);

        // Construct Texture (if format unconfigured, errdefer releases above retained resource)
        const texture = resources.Texture{
            .raw = texture_raw,
            .format = self.format orelse return error.SurfaceNotConfigured,
            .size = .{ .width = mtl.metal_texture_get_width(texture_raw), .height = mtl.metal_texture_get_height(texture_raw), .depth = 1 },
            .mip_level_count = 1,
            .dimension = .@"2d",
            .memory = .device_local,
        };

        return SurfaceTexture{
            .texture = texture,
            .drawable = drawable,
            .present_with_transaction = mtl.metal_layer_presents_with_transaction(self.layer) != 0,
        };
    }

    /// Destroy Surface
    pub fn deinit(self: *Surface) void {
        mtl.release(self.layer);
    }
};

/// SurfaceTexture - presentable texture
pub const SurfaceTexture = struct {
    texture: resources.Texture,
    drawable: *mtl.CAMetalDrawable,
    present_with_transaction: bool,

    /// Prepare present before submit.
    /// In transaction mode can't wait for scheduled here, command buffer not yet committed.
    pub fn preparePresent(self: *SurfaceTexture, command_buffer: *gpu.Backend.CommandBuffer) void {
        var pool = mtl.AutoreleasePool.init();
        defer pool.deinit();

        if (!self.present_with_transaction) {
            command_buffer.presentDrawable(self.drawable);
        }
    }

    /// Complete present after submit.
    /// During live resize `presentsWithTransaction=YES`, must wait until command buffer committed
    /// and enters scheduled state before direct present drawable, else main thread blocks on
    /// uncommitted buffer.
    pub fn presentAfterSubmit(self: *SurfaceTexture, command_buffer: *gpu.Backend.CommandBuffer) void {
        if (!self.present_with_transaction) return;

        var pool = mtl.AutoreleasePool.init();
        defer pool.deinit();

        mtl.metal_command_buffer_wait_until_scheduled(command_buffer.raw);
        mtl.metal_drawable_present(self.drawable);
    }

    /// Destroy (release drawable and texture)
    pub fn deinit(self: *SurfaceTexture) void {
        mtl.release(self.texture.raw);
        mtl.release(self.drawable);
    }
};

/// Surface configuration
pub const SurfaceConfiguration = struct {
    format: gpu.TextureFormat,
    width: u32,
    height: u32,
    usage: SurfaceUsage = .color_target_only,
    present_mode: PresentMode = .fifo,
    alpha_mode: AlphaMode = .fully_opaque,
    maximum_frame_latency: u32 = 2,
};

/// Surface usage
pub const SurfaceUsage = enum {
    color_target_only,
    color_target_and_read,
};

/// Present mode
pub const PresentMode = enum {
    fifo, // VSync
    immediate, // Don't wait for VSync
    mailbox, // Triple buffering
};

/// Alpha blend mode
pub const AlphaMode = enum {
    fully_opaque,
    premultiplied,
    postmultiplied,
};
