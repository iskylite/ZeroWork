/// Metal Backend - Metal backend entry point
///
/// This file exports all Metal backend types for gpu.zig

// Metal bindings and conversions
pub const metal_bindings = @import("metal_bindings.zig");
pub const conv = @import("conv.zig");

// Core types
pub const Instance = @import("instance.zig").Instance;
pub const Adapter = @import("adapter.zig").Adapter;
pub const Device = @import("device.zig").Device;
pub const Queue = @import("queue.zig").Queue;

// Resource types
const resources = @import("resources.zig");
pub const Buffer = resources.Buffer;
pub const Texture = resources.Texture;
pub const TextureBinding = resources.TextureBinding;
pub const TextureView = resources.TextureView;
pub const Sampler = resources.Sampler;

/// Backend image encoding utility used by diagnostics/E2E capture. Renderer
/// code passes ordinary bytes and never observes an Objective-C handle.
pub fn writePngRgba(path: [:0]const u8, rgba: []const u8, width: u32, height: u32, bytes_per_row: u32) bool {
    const required = @as(usize, bytes_per_row) * @as(usize, height);
    if (width == 0 or height == 0 or bytes_per_row < width * 4 or rgba.len < required) return false;
    return metal_bindings.macos_write_png_from_rgba(path.ptr, rgba.ptr, width, height, bytes_per_row) == 0;
}

/// Explicit backend escape hatch for borrowing an externally owned Metal
/// texture. Renderer-owned images should use `Texture.binding()` instead.
pub fn importTextureBinding(texture: *metal_bindings.MTLTexture) TextureBinding {
    return .{
        .raw = texture,
        .width = metal_bindings.metal_texture_get_width(texture),
        .height = metal_bindings.metal_texture_get_height(texture),
    };
}

// Surface
const surface_mod = @import("surface.zig");
pub const Surface = surface_mod.Surface;
pub const SurfaceTexture = surface_mod.SurfaceTexture;
pub const SurfaceConfiguration = surface_mod.SurfaceConfiguration;

// Command encoding
const command_encoder_mod = @import("command_encoder.zig");
pub const CommandEncoder = command_encoder_mod.CommandEncoder;
pub const CommandBuffer = command_encoder_mod.CommandBuffer;
pub const RenderPass = command_encoder_mod.RenderPass;
pub const ComputePass = command_encoder_mod.ComputePass;
pub const BlitPass = command_encoder_mod.BlitPass;

// Pipeline
const pipeline_mod = @import("pipeline.zig");
pub const ShaderModule = pipeline_mod.ShaderModule;
pub const ShaderFunction = pipeline_mod.ShaderFunction;
pub const RenderPipeline = pipeline_mod.RenderPipeline;
pub const RenderPipelineDescriptor = pipeline_mod.RenderPipelineDescriptor;
pub const VertexBufferLayoutDescriptor = pipeline_mod.VertexBufferLayoutDescriptor;
pub const VertexAttributeDescriptor = pipeline_mod.VertexAttributeDescriptor;
pub const BlendState = pipeline_mod.BlendState;
pub const createRenderPipeline = pipeline_mod.createRenderPipeline;

// ComputePipeline (placeholder)
pub const ComputePipeline = command_encoder_mod.ComputePipeline;

// BindGroup system
const bind_group_mod = @import("bind_group.zig");
pub const BindGroupLayout = bind_group_mod.BindGroupLayout;
pub const BindGroup = bind_group_mod.BindGroup;
pub const PipelineLayout = bind_group_mod.PipelineLayout;

// ============================================================================
// Frame synchronization primitives; platform-agnostic CPU/GPU sync interface
// Metal: dispatch_semaphore_t
// Vulkan (future): VkFence + VkSemaphore
// ============================================================================

pub const FrameSync = struct {
    semaphore: ?metal_bindings.dispatch_semaphore_t,

    /// Create frame sync primitive (allow max_frames_in_flight in-flight frames)
    pub fn init(max_frames_in_flight: u32) FrameSync {
        return .{
            .semaphore = metal_bindings.dispatch_semaphore_create(@intCast(max_frames_in_flight)),
        };
    }

    /// Wait, CPU blocks until buffer slot available
    pub fn waitForNextFrame(self: *FrameSync) error{}!void {
        if (self.semaphore) |sem| {
            _ = metal_bindings.dispatch_semaphore_wait(sem, metal_bindings.DISPATCH_TIME_FOREVER);
        }
    }

    /// Register GPU completion callback, signal when command buffer finishes
    pub fn signalOnCompletion(self: *FrameSync, cmd_buffer: *const CommandBuffer) void {
        if (self.semaphore) |sem| {
            metal_bindings.metal_command_buffer_add_completed_handler(cmd_buffer.raw, sem, &signalCallback);
        }
    }

    /// Return slot manually (error path, prevent semaphore leak stalling next frame)
    pub fn signal(self: *FrameSync) void {
        if (self.semaphore) |sem| {
            _ = metal_bindings.dispatch_semaphore_signal(sem);
        }
    }

    /// Release semaphore. Must drain first (unbalanced release triggers GCD assertion crash;
    /// dispatch_semaphore requires release value >= initial).
    pub fn deinit(self: *FrameSync) void {
        if (self.semaphore) |sem| {
            metal_bindings.dispatch_release(sem);
            self.semaphore = null;
        }
    }

    /// Wait for all in-flight frames (call before destroy)
    pub fn drain(self: *FrameSync, max_frames: u32) void {
        if (self.semaphore) |sem| {
            for (0..max_frames) |_| {
                _ = metal_bindings.dispatch_semaphore_wait(sem, metal_bindings.DISPATCH_TIME_FOREVER);
            }
            for (0..max_frames) |_| {
                _ = metal_bindings.dispatch_semaphore_signal(sem);
            }
        }
    }

    fn signalCallback(context: ?*anyopaque) callconv(.c) void {
        if (context) |sem| {
            _ = metal_bindings.dispatch_semaphore_signal(sem);
        }
    }
};
