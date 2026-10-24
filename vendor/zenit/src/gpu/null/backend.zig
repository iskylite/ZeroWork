//! Null Backend: deterministic reference impl without device.
//!
//! ## Why it exists
//!
//! With a single (Metal) impl it is unanswerable whether `gpu.Backend.*` signatures are
//! backend-neutral or accidentally welded to Metal semantics.
//!
//! This backend runs the **exact same renderer code as Metal**; `src/render`, `src/ui`,
//! `src/zenit_app` are unchanged, only `-Dgpu-backend=null` is on.
//! Compiles: abstraction holds. Compile fails: abstraction leaks.
//!
//! ## What it verifies, what it doesn't
//!
//! **Verifies**: symbol completeness, signature compat, resource lifecycle (alloc/free pairs),
//! pass nesting & type (render/blit non-interleaved), stale pass rejection.
//!
//! **Doesn't verify**: pixels. No rasterization. Pixel correctness is the job of Metal
//! integration tests and real-window E2E.
const std = @import("std");
const gpu = @import("../gpu.zig");

/// Process-scope allocator. Null backend resources are real memory (so getMappedRange returns
/// writable slice, renderer flush path runs to end), but GPU-uninvolved.
const alloc = std.heap.page_allocator;

/// Bytes-per-pixel. `gpu.TextureFormat` itself lacks this query (Metal backend uses
/// `conv.zig` to MTLPixelFormat, Metal handles it); Null backend self-computes
/// alloc size, needs minimal map here, covers only formats renderer uses.
fn bytesPerPixel(format: gpu.TextureFormat) u32 {
    return switch (format) {
        .r8_unorm, .r8_snorm, .r8_uint, .r8_sint => 1,
        .r16_uint, .r16_sint, .r16_float, .rg8_unorm, .rg8_snorm, .rg8_uint, .rg8_sint => 2,
        .rgba8_unorm, .rgba8_unorm_srgb, .rgba8_snorm, .rgba8_uint, .rgba8_sint, .bgra8_unorm, .bgra8_unorm_srgb, .r32_float, .r32_uint, .r32_sint, .rg16_uint, .rg16_sint, .rg16_float => 4,
        .rg32_float, .rg32_uint, .rg32_sint, .rgba16_uint, .rgba16_sint, .rgba16_float => 8,
        .rgba32_float, .rgba32_uint, .rgba32_sint => 16,
        else => 4,
    };
}

// ============================================================================
// Diagnostic counters to make abstract bypassing observable
// ============================================================================

/// Cross-backend instance counts. Tests assert resources paired-freed (leak detection).
pub var stats: Stats = .{};

pub const Stats = struct {
    buffers_created: u64 = 0,
    buffers_destroyed: u64 = 0,
    textures_created: u64 = 0,
    textures_destroyed: u64 = 0,
    samplers_created: u64 = 0,
    render_passes: u64 = 0,
    blit_passes: u64 = 0,
    draws: u64 = 0,
    submits: u64 = 0,

    pub fn reset() void {
        stats = .{};
    }

    /// Resource balance. Assertion that renderer didn't leak.
    pub fn balanced() bool {
        return stats.buffers_created == stats.buffers_destroyed and
            stats.textures_created == stats.textures_destroyed;
    }
};

// ============================================================================
// Resources
// ============================================================================

pub const Buffer = struct {
    bytes: []u8,
    size: u64,

    pub fn getMappedRange(self: *Buffer, offset: u64, size: u64) ![]u8 {
        // Same boundary semantics as Metal backend: out-of-bounds is error not UB. Assertion here
        // is
        // **deterministically testable** in Null backend, device-dependent in Metal.
        if (offset + size > self.size) return error.OutOfBounds;
        return self.bytes[@intCast(offset)..@intCast(offset + size)];
    }

    pub fn destroy(self: *Buffer) void {
        alloc.free(self.bytes);
        self.bytes = &.{};
        stats.buffers_destroyed += 1;
    }

    pub fn deinit(self: *Buffer) void {
        self.destroy();
    }
};

pub const TextureBinding = struct {
    /// Opaque id. Metal backend here `*MTLTexture`; Null backend uses monotonic id,
    /// semantically only needs 'comparable', `eql` is renderer's only dependency.
    id: u64,
    width: u32,
    height: u32,

    pub fn eql(self: TextureBinding, other: TextureBinding) bool {
        return self.id == other.id;
    }

    pub fn createView(self: TextureBinding) TextureView {
        return .{ .id = self.id };
    }

    /// See Metal backend same-name function: backend-neutral test constructor.
    pub fn testBinding(token: u64, width: u32, height: u32) TextureBinding {
        return .{ .id = token, .width = width, .height = height };
    }
};

pub const TextureView = struct {
    id: u64,

    pub fn destroy(self: *TextureView) void {
        self.id = 0;
    }
};

var next_texture_id: u64 = 1;

pub const Texture = struct {
    id: u64,
    bytes: []u8,
    format: gpu.TextureFormat,
    size: gpu.Extent3D,
    mip_level_count: u32,
    dimension: gpu.TextureDimension,
    memory: gpu.TextureMemory,

    pub fn writeRegion(
        self: *Texture,
        mip_level: u32,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
        bytes: []const u8,
        bytes_per_row: u32,
    ) !void {
        _ = mip_level;
        // Matches Metal backend: device-local textures not directly writable. Keep this error;
        // renderer branches depending on it get coverage in Null backend.
        if (self.memory != .host_upload) return error.TextureNotHostWritable;
        if (width == 0 or height == 0) return;
        if (x + width > self.size.width or y + height > self.size.height)
            return error.InvalidTextureRegion;
        const bpp = bytesPerPixel(self.format);
        const dst_stride = self.size.width * bpp;
        var row: u32 = 0;
        while (row < height) : (row += 1) {
            const src_off = row * bytes_per_row;
            const dst_off = (y + row) * dst_stride + x * bpp;
            const len = width * bpp;
            if (src_off + len > bytes.len) return error.InvalidTextureRegion;
            @memcpy(self.bytes[dst_off .. dst_off + len], bytes[src_off .. src_off + len]);
        }
    }

    pub fn readBgra8(self: *const Texture, width: u32, height: u32, bytes: []u8, bytes_per_row: u32) !void {
        const bpp = bytesPerPixel(self.format);
        const stride = self.size.width * bpp;
        var row: u32 = 0;
        while (row < @min(height, self.size.height)) : (row += 1) {
            const dst_off = row * bytes_per_row;
            const src_off = row * stride;
            const len = @min(@min(stride, bytes_per_row), width * bpp);
            if (dst_off + len > bytes.len) return;
            @memcpy(bytes[dst_off .. dst_off + len], self.bytes[src_off .. src_off + len]);
        }
    }

    pub fn nativeHandleForRecording(self: *const Texture) ?*anyopaque {
        _ = self;
        return null;
    }

    /// Test-only: construct metadata-only fake texture (matches Metal backend intent).
    /// `bytes` empty slice, so `destroy` doesn't mistakenly free.
    pub fn fakeForTesting(width: u32, height: u32, format: gpu.TextureFormat) Texture {
        const id = next_texture_id;
        next_texture_id += 1;
        return .{
            .id = id,
            .bytes = &.{},
            .format = format,
            .size = .{ .width = width, .height = height },
            .mip_level_count = 1,
            .dimension = .@"2d",
            .memory = .device_local,
        };
    }

    pub fn binding(self: *const Texture) TextureBinding {
        return .{ .id = self.id, .width = self.size.width, .height = self.size.height };
    }

    pub fn destroy(self: *Texture) void {
        if (self.bytes.len > 0) {
            alloc.free(self.bytes);
            self.bytes = &.{};
            stats.textures_destroyed += 1;
        }
    }

    pub fn deinit(self: *Texture) void {
        self.destroy();
    }
};

pub const Sampler = struct {
    id: u64,

    pub fn destroy(self: *Sampler) void {
        self.id = 0;
    }

    pub fn deinit(self: *Sampler) void {
        self.destroy();
    }
};

// ============================================================================
// Device / Queue / Instance / Adapter
// ============================================================================

pub const Device = struct {
    features: gpu.Features = .{},
    limits: gpu.Limits = .{},
    buffer_count: usize = 0,
    texture_count: usize = 0,
    sampler_count: usize = 0,

    pub fn createBuffer(
        self: *Device,
        allocator: std.mem.Allocator,
        desc: gpu.BufferDescriptor,
    ) !Buffer {
        _ = allocator;
        if (desc.size == 0) return error.InvalidDescriptor;
        const bytes = try alloc.alloc(u8, @intCast(desc.size));
        @memset(bytes, 0);
        self.buffer_count += 1;
        stats.buffers_created += 1;
        return .{ .bytes = bytes, .size = desc.size };
    }

    pub fn createTexture(
        self: *Device,
        allocator: std.mem.Allocator,
        desc: gpu.TextureDescriptor,
    ) !Texture {
        _ = allocator;
        if (desc.size.width == 0 or desc.size.height == 0) return error.InvalidDescriptor;
        if (desc.size.width > self.limits.max_texture_dimension_2d or
            desc.size.height > self.limits.max_texture_dimension_2d)
            return error.InvalidDescriptor;
        const bpp = bytesPerPixel(desc.format);
        const bytes = try alloc.alloc(u8, @as(usize, desc.size.width) * desc.size.height * bpp);
        @memset(bytes, 0);
        const id = next_texture_id;
        next_texture_id += 1;
        self.texture_count += 1;
        stats.textures_created += 1;
        return .{
            .id = id,
            .bytes = bytes,
            .format = desc.format,
            .size = desc.size,
            .mip_level_count = desc.mip_level_count,
            .dimension = desc.dimension,
            .memory = desc.memory,
        };
    }

    pub fn createSampler(
        self: *Device,
        allocator: std.mem.Allocator,
        desc: gpu.SamplerDescriptor,
    ) !Sampler {
        _ = allocator;
        _ = desc;
        self.sampler_count += 1;
        stats.samplers_created += 1;
        return .{ .id = 1 };
    }

    pub fn deinit(self: *Device) void {
        self.* = .{};
    }
};

pub const Queue = struct {
    pub fn deinit(self: *Queue) void {
        _ = self;
    }
};

pub const Adapter = struct {
    pub fn requestDevice(
        self: *Adapter,
        allocator: std.mem.Allocator,
        desc: anytype,
    ) !struct { device: Device, queue: Queue } {
        _ = self;
        _ = allocator;
        if (@hasField(@TypeOf(desc), "required_features")) {
            if (@hasField(@TypeOf(desc.required_features), "non_uniform_uav_buffer_array_atomics") and desc.required_features.non_uniform_uav_buffer_array_atomics)
                return error.UnsupportedFeatures;
        }
        return .{ .device = .{}, .queue = .{} };
    }

    pub fn deinit(self: *Adapter) void {
        _ = self;
    }
};

pub const Instance = struct {
    adapters_storage: [1]Adapter = .{.{}},

    pub fn init(allocator: std.mem.Allocator, desc: anytype) !Instance {
        _ = allocator;
        _ = desc;
        return .{};
    }

    pub fn enumerateAdapters(self: *Instance) ![]Adapter {
        return self.adapters_storage[0..];
    }

    pub fn deinit(self: *Instance) void {
        _ = self;
    }
};

// ============================================================================
// Pipeline
// ============================================================================

pub const ShaderFunction = struct {
    /// Stable copy of function name. Metal backend here `*MTLFunction`; Null backend keeps name,
    /// letting pipeline creation discriminate meaningfully (also proves 'name'-based shader
    /// identification works, see pipeline.zig PSO cache flip lesson).
    name: [64]u8 = @as([64]u8, @splat(0)),
    name_len: usize = 0,

    pub fn deinit(self: *ShaderFunction) void {
        self.name_len = 0;
    }
};

pub const ShaderModule = struct {
    /// Source length. Null backend doesn't compile MSL; only proves module->function lifecycle
    /// contract holds. Real second **graphics** backend needs another shader source, way bigger
    /// scope.
    source_len: usize,

    pub fn initFromSource(device: *Device, source: []const u8) !ShaderModule {
        _ = device;
        if (source.len == 0) return error.ShaderCompilationFailed;
        return .{ .source_len = source.len };
    }

    pub fn getFunction(self: *ShaderModule, name: []const u8) !ShaderFunction {
        _ = self;
        if (name.len == 0 or name.len > 64) return error.FunctionNotFound;
        var f = ShaderFunction{};
        @memcpy(f.name[0..name.len], name);
        f.name_len = name.len;
        return f;
    }

    pub fn deinit(self: *ShaderModule) void {
        self.source_len = 0;
    }
};

pub const RenderPipeline = struct {
    id: u64,

    pub fn deinit(self: *RenderPipeline) void {
        self.id = 0;
    }
};

/// Descriptor family aligned per-field with Metal backend. Intentionally each backend
/// carries own copy not in gpu.zig: they hold `?*const ShaderFunction` references to
/// backend-specific types.
pub const BlendFactor = enum(c_ulong) {
    zero = 0,
    one = 1,
    src_color = 2,
    one_minus_src_color = 3,
    src_alpha = 4,
    one_minus_src_alpha = 5,
    dst_color = 6,
    one_minus_dst_color = 7,
    dst_alpha = 8,
    one_minus_dst_alpha = 9,
    src_alpha_saturated = 10,
    blend_color = 11,
    one_minus_blend_color = 12,
    blend_alpha = 13,
    one_minus_blend_alpha = 14,
};

pub const BlendOperation = enum(c_ulong) {
    add = 0,
    subtract = 1,
    reverse_subtract = 2,
    min = 3,
    max = 4,
};

pub const BlendState = struct {
    source_rgb: BlendFactor = .one,
    destination_rgb: BlendFactor = .zero,
    rgb_operation: BlendOperation = .add,
    source_alpha: BlendFactor = .one,
    destination_alpha: BlendFactor = .zero,
    alpha_operation: BlendOperation = .add,

    pub const ALPHA_BLENDING = BlendState{
        .source_rgb = .src_alpha,
        .destination_rgb = .one_minus_src_alpha,
        .rgb_operation = .add,
        .source_alpha = .one,
        .destination_alpha = .one_minus_src_alpha,
        .alpha_operation = .add,
    };
};

pub const VertexAttributeDescriptor = struct {
    format: gpu.VertexFormat,
    offset: u64,
    shader_location: u32,
};

pub const VertexBufferLayoutDescriptor = struct {
    stride: u64,
    step_mode: gpu.VertexStepMode = .vertex,
    attributes: []const VertexAttributeDescriptor,
};

pub const RenderPipelineDescriptor = struct {
    vertex_function: ?*const ShaderFunction = null,
    fragment_function: ?*const ShaderFunction = null,
    color_attachment_formats: []const gpu.TextureFormat = &.{},
    depth_attachment_format: ?gpu.TextureFormat = null,
    stencil_attachment_format: ?gpu.TextureFormat = null,
    sample_count: u32 = 1,
    vertex_buffers: []const VertexBufferLayoutDescriptor = &.{},
    blend_state: ?BlendState = null,
};

var next_pipeline_id: u64 = 1;

pub fn createRenderPipeline(device: *Device, desc: RenderPipelineDescriptor) !RenderPipeline {
    _ = device;
    _ = desc;
    const id = next_pipeline_id;
    next_pipeline_id += 1;
    return .{ .id = id };
}

// ============================================================================
// Command encoding; pass state machine is the most valuable part of this backend
// ============================================================================

const PassKind = enum { none, render, blit };

/// Pass state machine isomorphic to Metal backend. Metal backend uses `generation` to reject stale
/// pass (ObjC object addresses are immediately reused, the root cause of GlassBox blit crash). Null
/// backend replicates same semantics, allowing this invariant to be verified in **device-free
/// deterministic tests** instead of relying on real window E2E.
pub const CommandEncoder = struct {
    state: PassKind = .none,
    next_generation: u64 = 1,
    active_generation: u64 = 0,
    finished: bool = false,

    pub fn init(queue: *Queue) !CommandEncoder {
        _ = queue;
        return .{};
    }

    fn activate(self: *CommandEncoder, kind: PassKind) u64 {
        std.debug.assert(self.state == .none);
        const g = self.next_generation;
        self.next_generation +%= 1;
        if (self.next_generation == 0) self.next_generation = 1;
        self.active_generation = g;
        self.state = kind;
        return g;
    }

    fn close(self: *CommandEncoder, kind: PassKind, generation: u64) void {
        if (self.state != kind or self.active_generation != generation)
            @panic("stale or wrong-kind GPU pass used after its lifetime ended");
        self.state = .none;
        self.active_generation = 0;
    }

    fn isActive(self: *const CommandEncoder, kind: PassKind, generation: u64) bool {
        return self.state == kind and self.active_generation == generation;
    }

    pub fn beginRenderPass(self: *CommandEncoder, desc: gpu.RenderPassDescriptor) !RenderPass {
        if (self.state != .none) return error.InvalidEncoderState;
        _ = desc;
        const g = self.activate(.render);
        stats.render_passes += 1;
        return .{ .command_encoder = self, .generation = g };
    }

    pub fn beginBlitPass(self: *CommandEncoder) !BlitPass {
        if (self.state != .none) return error.InvalidEncoderState;
        const g = self.activate(.blit);
        stats.blit_passes += 1;
        return .{ .command_encoder = self, .generation = g };
    }

    pub fn finish(self: *CommandEncoder) !CommandBuffer {
        if (self.finished) return error.EncoderAlreadyFinished;
        if (self.state != .none) return error.InvalidEncoderState;
        self.finished = true;
        return .{};
    }

    pub fn deinit(self: *CommandEncoder) void {
        _ = self;
    }
};

pub const RenderPass = struct {
    command_encoder: *CommandEncoder,
    generation: u64,

    /// type-level counter with same name and type as Metal backend
    /// (`src/render/command_encoder.zig` zeroes it each frame). Must exist across backends, else
    /// renderer fails to compile.
    pub var frame_draw_call_count: u32 = 0;

    fn assertActive(self: *const RenderPass) void {
        if (!self.command_encoder.isActive(.render, self.generation))
            @panic("stale or wrong-kind GPU pass used after its lifetime ended");
    }

    pub fn isActive(self: *const RenderPass) bool {
        return self.command_encoder.isActive(.render, self.generation);
    }

    pub fn setPipeline(self: *RenderPass, pipeline: *const RenderPipeline) void {
        self.assertActive();
        _ = pipeline;
    }

    pub fn setViewport(self: *RenderPass, x: f32, y: f32, w: f32, h: f32, min_d: f32, max_d: f32) void {
        self.assertActive();
        _ = .{ x, y, w, h, min_d, max_d };
    }

    pub fn setScissorRect(self: *RenderPass, x: u32, y: u32, w: u32, h: u32) void {
        self.assertActive();
        _ = .{ x, y, w, h };
    }

    pub fn setVertexBuffer(self: *RenderPass, slot: u32, buffer: *const Buffer, offset: u64) void {
        self.assertActive();
        _ = .{ slot, buffer, offset };
    }

    pub fn setFragmentBuffer(self: *RenderPass, slot: u32, buffer: *const Buffer, offset: u64) void {
        self.assertActive();
        _ = .{ slot, buffer, offset };
    }

    pub fn setFragmentTexture(self: *RenderPass, slot: u32, texture: *const Texture) void {
        self.assertActive();
        _ = .{ slot, texture };
    }

    pub fn setFragmentTextureBinding(self: *RenderPass, slot: u32, texture: TextureBinding) void {
        self.assertActive();
        _ = .{ slot, texture };
    }

    pub fn setFragmentSampler(self: *RenderPass, slot: u32, sampler: ?*const Sampler) void {
        self.assertActive();
        _ = .{ slot, sampler };
    }

    pub fn setVertexBytes(self: *RenderPass, slot: u32, data: []const u8) void {
        self.assertActive();
        _ = .{ slot, data };
    }

    pub fn setFragmentBytes(self: *RenderPass, slot: u32, data: []const u8) void {
        self.assertActive();
        _ = .{ slot, data };
    }

    pub fn draw(self: *RenderPass, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
        self.assertActive();
        _ = .{ first_vertex, first_instance };
        if (vertex_count == 0 or instance_count == 0) return;
        frame_draw_call_count += 1;
        stats.draws += 1;
    }

    pub fn end(self: *RenderPass) void {
        self.assertActive();
        self.command_encoder.close(.render, self.generation);
    }
};

pub const BlitPass = struct {
    command_encoder: *CommandEncoder,
    generation: u64,

    fn assertActive(self: *const BlitPass) void {
        if (!self.command_encoder.isActive(.blit, self.generation))
            @panic("stale or wrong-kind GPU pass used after its lifetime ended");
    }

    pub fn isActive(self: *const BlitPass) bool {
        return self.command_encoder.isActive(.blit, self.generation);
    }

    pub fn copyTextureRegion(
        self: *BlitPass,
        source: TextureBinding,
        source_x: u32,
        source_y: u32,
        width: u32,
        height: u32,
        destination: TextureBinding,
        destination_x: u32,
        destination_y: u32,
    ) !void {
        self.assertActive();
        // region validation aligned byte-for-byte with Metal backend; this contract is
        // deterministically testable in Null backend.
        if (width == 0 or height == 0 or
            source_x > source.width or width > source.width - source_x or
            source_y > source.height or height > source.height - source_y or
            destination_x > destination.width or width > destination.width - destination_x or
            destination_y > destination.height or height > destination.height - destination_y)
        {
            return error.InvalidTextureRegion;
        }
    }

    pub fn end(self: *BlitPass) void {
        self.assertActive();
        self.command_encoder.close(.blit, self.generation);
    }
};

pub const CommandBuffer = struct {
    completed: bool = true,

    pub fn submit(self: *CommandBuffer) void {
        _ = self;
        stats.submits += 1;
    }

    pub fn retained(self: *const CommandBuffer) CommandBuffer {
        return .{ .completed = self.completed };
    }

    pub fn waitUntilCompleted(self: *const CommandBuffer) void {
        _ = self;
    }

    pub fn isCompleted(self: *const CommandBuffer) bool {
        return self.completed;
    }

    pub fn gpuElapsedMicros(self: *const CommandBuffer) ?u64 {
        _ = self;
        return null;
    }

    /// type-level error counter with same name as Metal backend (observation point for cmd buffer
    /// submit failure).
    pub var error_count: std.atomic.Value(u64) = .init(0);

    pub fn presentDrawable(self: *CommandBuffer, drawable: *anyopaque) void {
        _ = .{ self, drawable };
    }

    pub fn deinit(self: *CommandBuffer) void {
        _ = self;
    }
};

// ============================================================================
// Surface
// ============================================================================

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

pub const SurfaceTexture = struct {
    texture: Texture,
    present_with_transaction: bool = false,

    pub fn preparePresent(self: *SurfaceTexture, command_buffer: *CommandBuffer) void {
        _ = .{ self, command_buffer };
    }

    pub fn presentAfterSubmit(self: *SurfaceTexture, command_buffer: *CommandBuffer) void {
        _ = .{ self, command_buffer };
    }

    pub fn deinit(self: *SurfaceTexture) void {
        self.texture.destroy();
    }
};

pub const Surface = struct {
    format: ?gpu.TextureFormat = null,
    extent: gpu.Extent3D = .{ .width = 0, .height = 0, .depth = 1 },

    /// platform handle is ignored, which is the point of `*anyopaque` signature: Null backend need
    /// not know what CAMetalLayer is.
    pub fn init(layer: *anyopaque) Surface {
        _ = layer;
        return .{};
    }

    pub fn configure(
        self: *Surface,
        allocator: std.mem.Allocator,
        device: *Device,
        config: SurfaceConfiguration,
    ) !void {
        _ = .{ allocator, device };
        self.format = config.format;
        self.extent = .{ .width = config.width, .height = config.height, .depth = 1 };
    }

    pub fn acquireTexture(self: *Surface, allocator: std.mem.Allocator) !SurfaceTexture {
        _ = allocator;
        const format = self.format orelse return error.SurfaceNotConfigured;
        const bpp = bytesPerPixel(format);
        const bytes = try alloc.alloc(u8, @as(usize, self.extent.width) * self.extent.height * bpp);
        @memset(bytes, 0);
        const id = next_texture_id;
        next_texture_id += 1;
        stats.textures_created += 1;
        return .{ .texture = .{
            .id = id,
            .bytes = bytes,
            .format = format,
            .size = self.extent,
            .mip_level_count = 1,
            .dimension = .@"2d",
            .memory = .device_local,
        } };
    }

    pub fn deinit(self: *Surface) void {
        self.format = null;
    }
};

// ============================================================================
// FrameSync
// ============================================================================

/// Metal backend uses `dispatch_semaphore_t` (Darwin-specific). Interface itself leaks no type, so
/// we can use portable `std.Io.Semaphore` here, which also proves FrameSync's abstraction is
/// clean.
pub const FrameSync = struct {
    sem: std.Io.Semaphore,
    io: std.Io,

    pub fn init(max_frames_in_flight: u32, io: std.Io) FrameSync {
        return .{ .io = io, .sem = .{ .permits = max_frames_in_flight } };
    }

    pub fn waitForNextFrame(self: *FrameSync) error{}!void {
        self.sem.waitUncancelable(self.io);
    }

    pub fn signalOnCompletion(self: *FrameSync, command_buffer: *const CommandBuffer) void {
        _ = command_buffer;
        self.sem.post(self.io);
    }

    pub fn signal(self: *FrameSync) void {
        self.sem.post(self.io);
    }

    /// aligned with Metal backend: drain then release sync primitive (std semaphore has no system
    /// resources, no-op semantics).
    pub fn deinit(self: *FrameSync) void {
        _ = self;
    }

    pub fn drain(self: *FrameSync, max_frames: u32) void {
        var i: u32 = 0;
        while (i < max_frames) : (i += 1) self.sem.waitUncancelable(self.io);
        i = 0;
        while (i < max_frames) : (i += 1) self.sem.post(self.io);
    }
};

// ============================================================================
// Miscellaneous
// ============================================================================

/// GPU-agnostic diagnostic tool (screenshot dump). Null backend does not write files.
pub fn writePngRgba(path: [:0]const u8, rgba: []const u8, width: u32, height: u32, bytes_per_row: u32) bool {
    _ = .{ path, rgba, width, height, bytes_per_row };
    return false;
}
