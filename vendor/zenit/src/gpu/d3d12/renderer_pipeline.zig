//! Renderer pipeline descriptor adapter. HLSL entry stages are explicit in
//! source comments; bindings come from bytecode reflection, never source guesses.
const std = @import("std");
const gpu = @import("../gpu.zig");
const d12 = @import("resources.zig");
const a = std.heap.page_allocator;
/// SM5.1 equivalent of Metal's absolute vertex_id/instance_id semantics.
pub const draw_info_source =
    \\cbuffer ZenitDrawInfo:register(b0,space4){uint zenit_first_vertex;uint zenit_first_instance;uint2 zenit_reserved;}
    \\uint zenitVertexIndex(uint local_index){return local_index+zenit_first_vertex;}
    \\uint zenitInstanceIndex(uint local_index){return local_index+zenit_first_instance;}
;
pub const ShaderFunction = d12.ShaderFunction;
pub const RenderPipeline = d12.RenderPipeline;
pub const ShaderModule = struct {
    inner: d12.ShaderModule,
    /// Source must declare each entry as `// zenit-entry: vertex name` or
    /// `// zenit-entry: fragment name`. Compute entries also compile explicitly.
    pub fn initFromSource(device: *d12.Device, source: []const u8) !ShaderModule {
        var entries: std.ArrayList(gpu.HlslEntryPoint) = .empty;
        defer entries.deinit(a);
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            const prefix = "// zenit-entry:";
            if (!std.mem.startsWith(u8, trimmed, prefix)) continue;
            var words = std.mem.tokenizeAny(u8, trimmed[prefix.len..], " \t");
            const stage = words.next() orelse return error.InvalidShaderManifest;
            const name = words.next() orelse return error.InvalidShaderManifest;
            if (words.next() != null) return error.InvalidShaderManifest;
            const value: gpu.ShaderStage = if (std.mem.eql(u8, stage, "vertex")) .vertex else if (std.mem.eql(u8, stage, "fragment")) .fragment else if (std.mem.eql(u8, stage, "compute")) .compute else return error.InvalidShaderManifest;
            try entries.append(a, .{ .name = name, .stage = value });
        }
        if (entries.items.len == 0) return error.MissingShaderManifest;
        return .{ .inner = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = source, .entry_points = entries.items } } }) };
    }
    pub fn getFunction(self: *const ShaderModule, name: []const u8) !ShaderFunction {
        return self.inner.getFunction(name);
    }
    pub fn deinit(self: *ShaderModule) void {
        self.inner.deinit();
    }
};
pub const VertexAttributeDescriptor = gpu.VertexAttribute;
pub const VertexBufferLayoutDescriptor = struct { stride: u64, step_mode: gpu.VertexStepMode = .vertex, attributes: []const VertexAttributeDescriptor };
pub const BlendFactor = enum { zero, one, src_color, one_minus_src_color, src_alpha, one_minus_src_alpha, dst_color, one_minus_dst_color, dst_alpha, one_minus_dst_alpha, src_alpha_saturated, blend_color, one_minus_blend_color, blend_alpha, one_minus_blend_alpha };
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
    dual_source_blending: bool = false,
};
fn blendFactor(factor: BlendFactor) !gpu.BlendFactor {
    return switch (factor) {
        .zero => .zero,
        .one => .one,
        .src_color => .src,
        .one_minus_src_color => .one_minus_src,
        .src_alpha => .src_alpha,
        .one_minus_src_alpha => .one_minus_src_alpha,
        .dst_color => .dst,
        .one_minus_dst_color => .one_minus_dst,
        .dst_alpha => .dst_alpha,
        .one_minus_dst_alpha => .one_minus_dst_alpha,
        .src_alpha_saturated => .src_alpha_saturated,
        .blend_color => .constant,
        .one_minus_blend_color => .one_minus_constant,
        // Shared GPU blend factors do not distinguish constant color/alpha.
        .blend_alpha, .one_minus_blend_alpha => return error.UnsupportedBlendFactor,
    };
}
pub fn createRenderPipeline(device: *d12.Device, desc: RenderPipelineDescriptor) !RenderPipeline {
    const vertex = desc.vertex_function orelse return error.InvalidRenderPipeline;
    const fragment = desc.fragment_function orelse return error.InvalidRenderPipeline;
    if (vertex.stage != .vertex or fragment.stage != .fragment) return error.InvalidShaderStage;
    if (desc.stencil_attachment_format != null) return error.UnsupportedRendererStencilPipeline;
    const vs = try vertex.resourceBindings(a);
    defer a.free(vs);
    const ps = try fragment.resourceBindings(a);
    defer a.free(ps);
    var lists: [4]std.ArrayList(gpu.BindGroupLayoutEntry) = @splat(.empty);
    defer for (&lists) |*list| list.deinit(a);
    var strides: [4]std.ArrayList(u32) = @splat(.empty);
    defer for (&strides) |*list| list.deinit(a);
    var group_count: usize = 0;
    for ([_][]const @import("shader.zig").ResourceBinding{ vs, ps }, 0..) |bindings, stage| for (bindings) |binding| {
        if (binding.group == 4 and binding.binding == 0 and binding.kind == 0 and binding.count == 1 and binding.min_size <= 16 and stage == 0) continue;
        if (binding.group >= 4) return error.UnsupportedRegisterSpace;
        group_count = @max(group_count, binding.group + 1);
        const visibility = gpu.ShaderStages{ .vertex = stage == 0, .fragment = stage == 1 };
        const ty: gpu.BindingType = switch (binding.kind) {
            0 => .{ .buffer = .{ .ty = .uniform, .min_binding_size = binding.min_size } },
            2 => .{ .buffer = .{ .ty = .read_only_storage } },
            1 => .{ .texture = .{ .view_dimension = switch (binding.dimension) {
                1 => .@"1d",
                2 => .@"2d",
                3 => .@"2d_array",
                4 => .cube,
                5 => .cube_array,
                6 => .@"3d",
                else => return error.UnsupportedShaderResource,
            }, .sample_type = switch (binding.sample_type) {
                1 => .float,
                4 => .sint,
                5 => .uint,
                else => return error.UnsupportedShaderResource,
            } } },
            4 => .{ .sampler = .{ .ty = if (binding.sampler_type == 3) .comparison else .filtering } },
            else => return error.UnsupportedShaderResource,
        };
        var found = false;
        for (lists[binding.group].items, 0..) |*entry, index| {
            if (entry.binding != binding.binding) continue;
            if (entry.count.? != binding.count) return error.ConflictingShaderBinding;
            if (entry.ty == .buffer and ty == .buffer) {
                if (entry.ty.buffer.ty != ty.buffer.ty or strides[binding.group].items[index] != binding.stride) return error.ConflictingShaderBinding;
                entry.ty.buffer.min_binding_size = @max(entry.ty.buffer.min_binding_size orelse 0, ty.buffer.min_binding_size orelse 0);
            } else if (!std.meta.eql(entry.ty, ty)) return error.ConflictingShaderBinding;
            entry.visibility.vertex = entry.visibility.vertex or visibility.vertex;
            entry.visibility.fragment = entry.visibility.fragment or visibility.fragment;
            found = true;
            break;
        }
        if (!found) {
            try lists[binding.group].append(a, .{ .binding = binding.binding, .count = binding.count, .visibility = visibility, .ty = ty });
            try strides[binding.group].append(a, binding.stride);
        }
    };
    var groups: [4]d12.BindGroupLayout = undefined;
    var created: usize = 0;
    defer for (groups[0..created]) |*group| group.deinit();
    for (lists[0..group_count], 0..) |list, index| {
        groups[index] = try device.createBindGroupLayout(a, .{ .entries = list.items });
        created += 1;
    }
    var layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = groups[0..created] });
    defer layout.deinit();
    const vertices = try a.alloc(gpu.VertexBufferLayout, desc.vertex_buffers.len);
    defer a.free(vertices);
    for (desc.vertex_buffers, vertices) |input, *output| output.* = .{ .array_stride = input.stride, .step_mode = input.step_mode, .attributes = input.attributes };
    const targets = try a.alloc(gpu.ColorTargetState, desc.color_attachment_formats.len);
    defer a.free(targets);
    var blend: ?gpu.BlendState = null;
    if (desc.blend_state) |b| blend = .{ .color = .{ .src_factor = try blendFactor(b.source_rgb), .dst_factor = try blendFactor(b.destination_rgb), .operation = b.rgb_operation }, .alpha = .{ .src_factor = try blendFactor(b.source_alpha), .dst_factor = try blendFactor(b.destination_alpha), .operation = b.alpha_operation } };
    for (desc.color_attachment_formats, targets) |format, *target| target.* = .{ .format = format, .blend = blend };
    return device.createRenderPipeline(.{ .vertex_function = vertex, .fragment_function = fragment, .dual_source_blending = desc.dual_source_blending, .layout = &layout, .vertex_buffers = vertices, .targets = targets, .multisample = .{ .count = desc.sample_count }, .depth_stencil = if (desc.depth_attachment_format) |format| .{ .format = format, .depth_write_enabled = false, .depth_compare = .always } else null });
}
