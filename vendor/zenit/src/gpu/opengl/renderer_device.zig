//! Renderer factories over a stable, owned OpenGL context.
//! Device is move-only. Queues and shader functions borrow its context; live
//! resources and recorded commands prevent checked device teardown.
const std = @import("std");
const gpu = @import("../gpu.zig");
const native = @import("device.zig");
const resources = @import("renderer_resources.zig");
const commands = @import("renderer_commands.zig");
const pipelines = @import("renderer_pipeline.zig");
pub const shaders = @import("renderer_shaders.zig");

pub const Buffer = resources.Buffer;
pub const Texture = resources.Texture;
pub const TextureBinding = resources.TextureBinding;
pub const TextureView = resources.TextureView;
pub const Sampler = resources.Sampler;
pub const Queue = commands.Queue;
pub const CommandEncoder = commands.CommandEncoder;
pub const CommandBuffer = commands.CommandBuffer;
pub const RenderPass = commands.RenderPass;
pub const BlitPass = commands.BlitPass;
pub const ShaderFunction = shaders.ShaderFunction;
pub const RenderPipeline = pipelines.RenderPipeline;
pub const RenderPipelineDescriptor = pipelines.RenderPipelineDescriptor;
pub const VertexBufferLayoutDescriptor = pipelines.VertexBufferLayoutDescriptor;
pub const VertexAttributeDescriptor = pipelines.VertexAttributeDescriptor;
pub const BlendState = pipelines.BlendState;
pub const FrameSync = @import("frame_sync.zig").FrameSync;
pub const Surface = @import("surface.zig").Surface;
pub const SurfaceTexture = @import("surface.zig").SurfaceTexture;
pub const SurfaceConfiguration = @import("surface.zig").SurfaceConfiguration;
pub const NativeSurface = @import("surface.zig").NativeSurface;
extern fn zenit_linux_write_png_rgba([*:0]const u8, [*]const u8, usize, u32, u32, u32) c_int;
pub fn writePngRgba(path: [:0]const u8, rgba: []const u8, width: u32, height: u32, bytes_per_row: u32) bool {
    return zenit_linux_write_png_rgba(path.ptr, rgba.ptr, rgba.len, width, height, bytes_per_row) != 0;
}

/// Conservative capabilities of the validated GL 4.3 UI subset. Queried
/// device limits bound advertised bindings; arrays, compute and storage images
/// stay unsupported. Core SSBO size minima cover the native binding range.
fn supportedLimits(device: *const native.Device) gpu.Limits {
    var limits = std.mem.zeroes(gpu.Limits);
    limits.max_texture_dimension_2d = device.maxTextureDimension2D();
    limits.max_texture_array_layers = 1;
    limits.max_bind_groups = 4;
    limits.max_bindings_per_bind_group = 64;
    limits.max_sampled_textures_per_shader_stage = @min(16, device.info.fragment_texture_units);
    limits.max_samplers_per_shader_stage = @min(16, device.info.fragment_texture_units);
    limits.max_storage_buffers_per_shader_stage = @min(4, @min(device.info.vertex_storage_blocks, device.info.fragment_storage_blocks));
    limits.max_uniform_buffers_per_shader_stage = @min(12, device.info.uniform_buffer_bindings);
    limits.max_uniform_buffer_binding_size = @min(16384, device.info.uniform_block_size);
    limits.max_storage_buffer_binding_size = 134217728;
    return limits;
}

pub const Instance = struct {
    allocator: std.mem.Allocator,
    options: native.Device.Options,
    pub fn init(allocator: std.mem.Allocator, desc: gpu.InstanceDescriptor) !Instance {
        return initWithOptions(allocator, desc, .{});
    }
    pub fn initWithOptions(allocator: std.mem.Allocator, desc: gpu.InstanceDescriptor, options: native.Device.Options) !Instance {
        if (!desc.backends.gl) return error.BackendDisabled;
        return .{ .allocator = allocator, .options = options };
    }
    /// One selected graphics/present adapter. Native selection applies the
    /// explicit software policy; this does not enumerate every physical GPU.
    pub fn enumerateAdapters(self: *Instance) ![]Adapter {
        var diagnostic: native.Diagnostic = .{};
        var device = try native.Device.init(self.options, &diagnostic);
        errdefer _ = device.deinit() catch {};
        const adapters = try self.allocator.alloc(Adapter, 1);
        adapters[0] = .{ .native_device = device };
        return adapters;
    }
    pub fn deinit(self: *Instance) void {
        _ = self;
    }
};
pub const Adapter = struct {
    native_device: native.Device,
    pub fn isSoftware(self: *const Adapter) bool {
        return self.native_device.info.isSoftware();
    }
    pub fn requestDevice(self: *Adapter, allocator: std.mem.Allocator, desc: gpu.DeviceDescriptor) !struct { device: Device, queue: Queue } {
        if (self.native_device.handle == null) return error.DeviceAlreadyRequested;
        if (@as(u64, @bitCast(desc.required_features)) != 0) return error.UnsupportedFeatures;
        const supported = supportedLimits(&self.native_device);
        if (desc.required_limits) |required| inline for (@typeInfo(gpu.Limits).@"struct".field_names) |field_name| {
            if (@field(required, field_name) > @field(supported, field_name)) return error.UnsupportedLimits;
        };
        var device = try Device.initOwned(allocator, &self.native_device);
        return .{ .device = device, .queue = try device.createQueue() };
    }
    pub fn deinit(self: *Adapter) void {
        _ = self.native_device.deinit() catch @panic("OpenGL adapter teardown failed");
    }
};

pub const Device = struct {
    context: ?*resources.Context,
    features: gpu.Features = .{},
    limits: gpu.Limits,

    /// Takes ownership only after allocation succeeds. Capability negotiation
    /// belongs to Adapter.requestDevice, which is not wired into Backend yet.
    pub fn initOwned(allocator: std.mem.Allocator, device: *native.Device) !Device {
        const limits = supportedLimits(device);
        return .{ .context = try resources.Context.init(allocator, device), .limits = limits };
    }

    pub fn liveContext(self: *const Device) !*resources.Context {
        return self.context orelse error.DeviceDestroyed;
    }

    pub fn createBuffer(self: *Device, allocator: std.mem.Allocator, desc: gpu.BufferDescriptor) !Buffer {
        return (try self.liveContext()).createBuffer(allocator, desc);
    }
    pub fn createTexture(self: *Device, allocator: std.mem.Allocator, desc: gpu.TextureDescriptor) !Texture {
        return (try self.liveContext()).createTexture(allocator, desc);
    }
    pub fn createSampler(self: *Device, allocator: std.mem.Allocator, desc: gpu.SamplerDescriptor) !Sampler {
        return (try self.liveContext()).createSampler(allocator, desc);
    }
    pub fn createQueue(self: *Device) !Queue {
        return Queue.init(try self.liveContext());
    }
    pub fn supportsSampleCount(self: *const Device, format: gpu.TextureFormat, count: u32) !bool {
        _ = try self.liveContext();
        return count == 1 and switch (format) {
            .r8_unorm, .rgba8_unorm, .bgra8_unorm => true,
            else => false,
        };
    }
    pub fn supportsVertexViewportIndex(self: *const Device) bool {
        _ = self;
        return false;
    }
    pub fn isSoftware(self: *const Device) bool {
        return if (self.context) |context| context.device.info.isSoftware() else false;
    }
    /// On failure ownership stays intact, allowing resources to be released
    /// before retrying. A successful destroy is idempotent.
    pub fn deinitChecked(self: *Device) !void {
        const context = self.context orelse return;
        const validation_errors = try context.deinit();
        self.context = null;
        if (validation_errors != 0) return error.OpenGLValidationErrors;
    }
    pub fn deinit(self: *Device) void {
        self.deinitChecked() catch @panic("OpenGL renderer Device teardown failed");
    }
};

pub const ShaderModule = struct {
    inner: shaders.ShaderModule,
    pub fn initFromSource(device: *Device, source: []const u8) !ShaderModule {
        const context = try device.liveContext();
        return .{ .inner = try shaders.ShaderModule.initFromSource(&context.device, source) };
    }
    pub fn getFunction(self: *const ShaderModule, name: []const u8) !ShaderFunction {
        return self.inner.getFunction(name);
    }
    pub fn deinit(self: *ShaderModule) void {
        self.inner.deinit();
    }
};

pub fn createRenderPipeline(device: *Device, desc: RenderPipelineDescriptor) !RenderPipeline {
    return pipelines.createRenderPipeline(try device.liveContext(), desc);
}
