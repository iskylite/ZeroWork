//! Shared Linux renderer contracts; instantiated with the native driver.
pub fn For(comptime Driver: type) type {
    return struct {
        //! Renderer pipeline descriptors over precompiled SPIR-V. Commands retain the
        //! owned pipeline and use reflected byte ranges rather than source heuristics.
        const std = @import("std");
        const gpu = @import("../gpu.zig");
        const vk = Driver;
        const resources = @import("renderer_resources.zig").For(Driver);
        pub const ShaderFunction = vk.shaders.ShaderFunction;
        pub const VertexAttributeDescriptor = gpu.VertexAttribute;
        pub const VertexBufferLayoutDescriptor = struct { stride: u64, step_mode: gpu.VertexStepMode = .vertex, attributes: []const VertexAttributeDescriptor };
        pub const BlendFactor = enum(u32) { zero, one, src_color, one_minus_src_color, src_alpha, one_minus_src_alpha, dst_color, one_minus_dst_color, dst_alpha, one_minus_dst_alpha, src_alpha_saturated, blend_color, one_minus_blend_color, blend_alpha, one_minus_blend_alpha };
        pub const BlendOperation = gpu.BlendOperation;
        pub const BlendState = struct {
            source_rgb: BlendFactor = .one,
            destination_rgb: BlendFactor = .zero,
            rgb_operation: BlendOperation = .add,
            source_alpha: BlendFactor = .one,
            destination_alpha: BlendFactor = .zero,
            alpha_operation: BlendOperation = .add,
            pub const ALPHA_BLENDING: BlendState = .{ .source_rgb = .src_alpha, .destination_rgb = .one_minus_src_alpha, .destination_alpha = .one_minus_src_alpha };
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
        pub const Binding = struct { group: u32, binding: u32, kind: u32, stages: u32, min_size: u32, stride: u32 };
        pub const Owner = struct {
            context: *resources.Context,
            inner: vk.pipeline.Pipeline,
            bindings: []Binding,
            format: gpu.TextureFormat,
            instance_indexed: bool = false,
            refs: usize = 1,
        };
        pub const RenderPipeline = struct {
            owner: ?*Owner,
            pub fn retained(self: *const RenderPipeline) RenderPipeline {
                if (self.owner) |owner| owner.refs += 1;
                return self.*;
            }
            pub fn deinit(self: *RenderPipeline) void {
                const owner = self.owner orelse return;
                self.owner = null;
                owner.refs -= 1;
                if (owner.refs != 0) return;
                const a = owner.context.allocator;
                owner.inner.destroy();
                a.free(owner.bindings);
                owner.context.resources -= 1;
                a.destroy(owner);
            }
        };
        pub fn createRenderPipeline(context: *resources.Context, desc: RenderPipelineDescriptor) !RenderPipeline {
            const vertex = desc.vertex_function orelse return error.InvalidRenderPipeline;
            const fragment = desc.fragment_function orelse return error.InvalidRenderPipeline;
            if (context.device.handle == null or vertex.device != &context.device or fragment.device != &context.device) return error.InvalidDescriptor;
            if (vertex.entry.stage != .vertex or fragment.entry.stage != .fragment) return error.InvalidShaderStage;
            if (vertex.entry.code.len < 20 or fragment.entry.code.len < 20) return error.InvalidShaderFunction;
            if (!std.mem.eql(u8, vertex.entry.program, fragment.entry.program)) return error.ConflictingShaderProgram;
            if (desc.color_attachment_formats.len != 1 or desc.depth_attachment_format != null or desc.stencil_attachment_format != null or desc.sample_count != 1 or desc.vertex_buffers.len != 0) return error.UnsupportedRenderPipeline;
            const format = desc.color_attachment_formats[0];
            const native_format: vk.resources.Format = switch (format) {
                .r8_unorm => .r8_unorm,
                .rgba8_unorm => .rgba8_unorm,
                .bgra8_unorm => .bgra8_unorm,
                .rgba16_float => .rgba16_float,
                else => return error.UnsupportedRenderPipeline,
            };
            const a = context.allocator;
            var entries: std.ArrayList(Binding) = .empty;
            defer entries.deinit(a);
            for ([_]ShaderFunction{ vertex.*, fragment.* }, 0..) |function, stage| {
                for (function.entry.bindings) |binding| {
                    var found = false;
                    for (entries.items) |*entry| {
                        if (entry.group != binding.group or entry.binding != binding.binding) continue;
                        if (entry.kind != binding.kind or entry.stride != binding.stride) return error.ConflictingShaderBinding;
                        entry.stages |= if (stage == 0) @as(u32, 1) else 2;
                        entry.min_size = @max(entry.min_size, binding.min_size);
                        found = true;
                        break;
                    }
                    if (!found) {
                        if (entries.items.len == 64) return error.BindingCapacityExceeded;
                        try entries.append(a, .{ .group = binding.group, .binding = binding.binding, .kind = binding.kind, .stages = if (stage == 0) 1 else 2, .min_size = binding.min_size, .stride = binding.stride });
                    }
                }
            }
            var native_bindings: [64]vk.pipeline.Binding = undefined;
            for (entries.items, 0..) |entry, i| native_bindings[i] = .{ .group = entry.group, .binding = entry.binding, .kind = entry.kind, .stages = entry.stages };
            var state: vk.pipeline.State = .{ .format = native_format, .blend_enabled = 0, .destination_rgb = 0, .destination_alpha = 0 };
            if (desc.blend_state) |blend| state = .{ .format = native_format, .source_rgb = @backingInt(blend.source_rgb), .destination_rgb = @backingInt(blend.destination_rgb), .rgb_operation = @backingInt(blend.rgb_operation), .source_alpha = @backingInt(blend.source_alpha), .destination_alpha = @backingInt(blend.destination_alpha), .alpha_operation = @backingInt(blend.alpha_operation) };
            var diag: vk.Diagnostic = .{};
            var inner = try vk.pipeline.Pipeline.initConfigured(&context.device, vertex.entry.code, vertex.entry.name, fragment.entry.code, fragment.entry.name, native_bindings[0..entries.items.len], state, &diag);
            errdefer inner.destroy();
            const owner = try a.create(Owner);
            errdefer a.destroy(owner);
            const instance_indexed = for ([_][]const u8{ "sdf_vertex_main", "sdf_tiled_rect_vertex_main", "sdf_shadow_ring_vertex_main", "sdf_dual_shadow_vertex_main", "text_vertex_main", "image_vertex_main", "icon_vertex_main" }) |name| {
                if (std.mem.eql(u8, vertex.entry.name, name)) break true;
            } else false;
            owner.* = .{ .context = context, .inner = inner, .bindings = try entries.toOwnedSlice(a), .format = format, .instance_indexed = instance_indexed };
            context.resources += 1;
            return .{ .owner = owner };
        }
    };
}
