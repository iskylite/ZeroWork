/// Metal Pipeline implementation. Provides ShaderModule and RenderPipeline wrapper.
const std = @import("std");
const gpu = @import("../gpu.zig");
const mtl = @import("metal_bindings.zig");
const conv = @import("conv.zig");
const Device = @import("device.zig").Device;

/// ShaderModule - shader module. Encapsulates MTLLibrary, contains compiled
/// shader functions.
pub const ShaderModule = struct {
    library: *mtl.MTLLibrary,

    /// Created from Metal Shading Language source.
    pub fn initFromSource(
        device: *Device,
        source: []const u8,
    ) !ShaderModule {
        var pool = mtl.AutoreleasePool.init();
        defer pool.deinit();

        // Requires null-terminated string (shader source can be large, use
        // page_allocator).
        const source_z = try std.heap.page_allocator.dupeSentinel(u8, source, 0);
        defer std.heap.page_allocator.free(source_z);

        var compile_error: ?[*:0]u8 = null;
        const library = mtl.metal_device_new_library_from_source(
            device.raw_device,
            source_z.ptr,
            &compile_error,
        ) orelse {
            if (compile_error) |msg| {
                defer std.c.free(msg);
                std.log.err("Metal shader compilation failed: {s}", .{std.mem.span(msg)});
            } else {
                std.log.err("Metal shader compilation failed (no diagnostic returned)", .{});
            }
            return error.ShaderCompilationFailed;
        };

        return ShaderModule{
            .library = library,
        };
    }

    /// Get function.
    pub fn getFunction(self: *ShaderModule, name: []const u8) !ShaderFunction {
        // Function names typically short (< 128 bytes); use stack buffer to avoid
        // page_allocator mmap overhead.
        var buf: [128]u8 = undefined;
        if (name.len < buf.len) {
            @memcpy(buf[0..name.len], name);
            buf[name.len] = 0;
            const raw = mtl.metal_library_new_function(self.library, @ptrCast(buf[0..name.len :0])) orelse
                return error.FunctionNotFound;
            return .{ .raw = raw };
        }
        // Very long names fall back to page_allocator.
        const name_z = try std.heap.page_allocator.dupeSentinel(u8, name, 0);
        defer std.heap.page_allocator.free(name_z);
        const raw = mtl.metal_library_new_function(self.library, name_z.ptr) orelse
            return error.FunctionNotFound;
        return .{ .raw = raw };
    }

    pub fn deinit(self: *ShaderModule) void {
        mtl.release(self.library);
    }
};

/// Backend-owned shader entry point.
///
/// Renderer code owns this wrapper and never handles or releases a native
/// `MTLFunction`. The raw handle is consumed only inside this backend module.
pub const ShaderFunction = struct {
    raw: *mtl.MTLFunction,

    pub fn deinit(self: *ShaderFunction) void {
        mtl.release(self.raw);
        self.* = undefined;
    }
};

/// RenderPipeline - render pipeline. Encapsulates MTLRenderPipelineState.
pub const RenderPipeline = struct {
    raw: *mtl.MTLRenderPipelineState,

    pub fn deinit(self: *RenderPipeline) void {
        mtl.release(self.raw);
    }
};

/// RenderPipelineDescriptor - render pipeline descriptor. Configuration used to
/// create RenderPipeline.
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

/// Vertex buffer layout descriptor.
pub const VertexBufferLayoutDescriptor = struct {
    stride: u64,
    step_mode: gpu.VertexStepMode = .vertex,
    attributes: []const VertexAttributeDescriptor,
};

/// Vertex attribute descriptor.
pub const VertexAttributeDescriptor = struct {
    format: gpu.VertexFormat,
    offset: u64,
    shader_location: u32,
};

/// Blend state.
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

/// Create RenderPipeline.
///
/// WARNING: Do not add a descriptor-hash PSO cache. Shader functions in the
/// descriptor can only be fingerprinted by `MTLFunction` **object address**. Callers
/// (ensureBlurPipeline, buildGlassPipeline, etc.) `defer func.deinit()` right after
/// PSO creation, so the address is reclaimed and reused by ObjC. The glass descriptor
/// then gets the same fingerprint as Kawase blur, the cache returns the blur PSO as
/// the glass PSO, and glass degrades to an opaque milky disk. e2e pixel assertions
/// do not catch 'wrong shader'; only screenshots show it.
///
/// The cache also has no benefit: over the full storybook lifetime PSOs are created
/// only 10 times (1.26ms total), with zero repeats. Callsites already have
/// `if (pipeline != null) return` + PersistentGpuCache cross-frame dedup (see
/// PersistentGpuCache in command_encoder.zig).
///
/// If revisiting, first gather evidence of actual PSO re-compilation.
pub fn createRenderPipeline(
    device: *Device,
    desc: RenderPipelineDescriptor,
) !RenderPipeline {
    var pool = mtl.AutoreleasePool.init();
    defer pool.deinit();

    // Create pipeline descriptor.
    const pipeline_desc = mtl.metal_render_pipeline_descriptor_new();
    defer mtl.release(pipeline_desc);

    // Set vertex and fragment functions.
    mtl.metal_render_pipeline_descriptor_set_vertex_function(
        pipeline_desc,
        if (desc.vertex_function) |function| function.raw else null,
    );
    mtl.metal_render_pipeline_descriptor_set_fragment_function(
        pipeline_desc,
        if (desc.fragment_function) |function| function.raw else null,
    );

    // Set color attachment format.
    for (desc.color_attachment_formats, 0..) |format, i| {
        const mtl_format = conv.toMetalPixelFormat(format);
        mtl.metal_render_pipeline_descriptor_set_color_attachment_format(
            pipeline_desc,
            @intCast(i),
            @backingInt(mtl_format),
        );

        // Set blend state.
        if (desc.blend_state) |blend| {
            mtl.metal_render_pipeline_color_attachment_set_blending_enabled(pipeline_desc, @intCast(i), 1);
            mtl.metal_render_pipeline_color_attachment_set_source_rgb_blend_factor(pipeline_desc, @intCast(i), @backingInt(blend.source_rgb));
            mtl.metal_render_pipeline_color_attachment_set_destination_rgb_blend_factor(pipeline_desc, @intCast(i), @backingInt(blend.destination_rgb));
            mtl.metal_render_pipeline_color_attachment_set_rgb_blend_operation(pipeline_desc, @intCast(i), @backingInt(blend.rgb_operation));
            mtl.metal_render_pipeline_color_attachment_set_source_alpha_blend_factor(pipeline_desc, @intCast(i), @backingInt(blend.source_alpha));
            mtl.metal_render_pipeline_color_attachment_set_destination_alpha_blend_factor(pipeline_desc, @intCast(i), @backingInt(blend.destination_alpha));
            mtl.metal_render_pipeline_color_attachment_set_alpha_blend_operation(pipeline_desc, @intCast(i), @backingInt(blend.alpha_operation));
        }
    }

    // Set depth attachment format.
    if (desc.depth_attachment_format) |format| {
        const mtl_format = conv.toMetalPixelFormat(format);
        mtl.metal_render_pipeline_descriptor_set_depth_attachment_format(
            pipeline_desc,
            @backingInt(mtl_format),
        );
    }

    // Set stencil attachment format.
    if (desc.stencil_attachment_format) |format| {
        const mtl_format = conv.toMetalPixelFormat(format);
        mtl.metal_render_pipeline_descriptor_set_stencil_attachment_format(
            pipeline_desc,
            @backingInt(mtl_format),
        );
    }

    // Set sample count.
    mtl.metal_render_pipeline_descriptor_set_sample_count(pipeline_desc, desc.sample_count);

    // Set vertex descriptor.
    if (desc.vertex_buffers.len > 0) {
        const vertex_desc = mtl.metal_vertex_descriptor_new();
        defer mtl.release(vertex_desc);

        for (desc.vertex_buffers, 0..) |buffer_layout, buffer_index| {
            // Set layout.
            mtl.metal_vertex_descriptor_set_layout_stride(
                vertex_desc,
                @intCast(buffer_index),
                buffer_layout.stride,
            );

            const step_function: c_ulong = switch (buffer_layout.step_mode) {
                .vertex => 1, // MTLVertexStepFunctionPerVertex
                .instance => 2, // MTLVertexStepFunctionPerInstance
            };
            mtl.metal_vertex_descriptor_set_layout_step_function(
                vertex_desc,
                @intCast(buffer_index),
                step_function,
            );
            mtl.metal_vertex_descriptor_set_layout_step_rate(
                vertex_desc,
                @intCast(buffer_index),
                1,
            );

            // Set attributes.
            for (buffer_layout.attributes) |attr| {
                const mtl_format = vertexFormatToMetal(attr.format);
                mtl.metal_vertex_descriptor_set_attribute_format(
                    vertex_desc,
                    attr.shader_location,
                    @backingInt(mtl_format),
                );
                mtl.metal_vertex_descriptor_set_attribute_offset(
                    vertex_desc,
                    attr.shader_location,
                    attr.offset,
                );
                mtl.metal_vertex_descriptor_set_attribute_buffer_index(
                    vertex_desc,
                    attr.shader_location,
                    @intCast(buffer_index),
                );
            }
        }

        mtl.metal_render_pipeline_descriptor_set_vertex_descriptor(pipeline_desc, vertex_desc);
    }

    // Create pipeline state (no error_out for simplicity).
    const pipeline_state = mtl.metal_device_new_render_pipeline_state(
        device.raw_device,
        pipeline_desc,
        null,
    ) orelse {
        std.log.err(
            "Metal render pipeline creation failed (color_attachments={d} sample_count={d})",
            .{ desc.color_attachment_formats.len, desc.sample_count },
        );
        return error.PipelineCreationFailed;
    };

    return RenderPipeline{
        .raw = pipeline_state,
    };
}

/// Convert vertex format to Metal.
fn vertexFormatToMetal(format: gpu.VertexFormat) mtl.MTLVertexFormat {
    return switch (format) {
        .uint8x2 => .UChar2,
        .uint8x4 => .UChar4,
        .sint8x2 => .Char2,
        .sint8x4 => .Char4,
        .unorm8x2 => .UChar2Normalized,
        .unorm8x4 => .UChar4Normalized,
        .snorm8x2 => .Char2Normalized,
        .snorm8x4 => .Char4Normalized,
        .uint16x2 => .UShort2,
        .uint16x4 => .UShort4,
        .sint16x2 => .Short2,
        .sint16x4 => .Short4,
        .unorm16x2 => .UShort2Normalized,
        .unorm16x4 => .UShort4Normalized,
        .snorm16x2 => .Short2Normalized,
        .snorm16x4 => .Short4Normalized,
        .float16x2 => .Half2,
        .float16x4 => .Half4,
        .float32 => .Float,
        .float32x2 => .Float2,
        .float32x3 => .Float3,
        .float32x4 => .Float4,
        .uint32 => .UInt,
        .uint32x2 => .UInt2,
        .uint32x3 => .UInt3,
        .uint32x4 => .UInt4,
        .sint32 => .Int,
        .sint32x2 => .Int2,
        .sint32x3 => .Int3,
        .sint32x4 => .Int4,
    };
}
