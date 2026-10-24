/// Metal BindGroup implementation.
/// Metal has no native BindGroup concept. This module implements wgpu-style
/// BindGroup/BindGroupLayout/PipelineLayout API via logical binding tables.
/// setBindGroup in RenderPass/ComputePass expands to setVertexBuffer / setFragmentBuffer
/// / setFragmentTexture etc. Metal calls.
const std = @import("std");
const gpu = @import("../gpu.zig");
const mtl = @import("metal_bindings.zig");

/// BindGroupLayout: describes layout of binding group.
/// Stores type and visibility info per binding slot; used for validation and pipeline creation.
pub const BindGroupLayout = struct {
    entries: []const gpu.BindGroupLayoutEntry,
    label: ?[]const u8 = null,

    /// Create BindGroupLayout from descriptor.
    pub fn init(allocator: std.mem.Allocator, desc: gpu.BindGroupLayoutDescriptor) !BindGroupLayout {
        const entries = try allocator.dupe(gpu.BindGroupLayoutEntry, desc.entries);
        return .{
            .entries = entries,
            .label = desc.label,
        };
    }

    pub fn deinit(self: *BindGroupLayout, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
    }
};

/// PipelineLayout: combines multiple BindGroupLayouts.
pub const PipelineLayout = struct {
    bind_group_layouts: []const BindGroupLayout,
    label: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, desc: gpu.PipelineLayoutDescriptor) !PipelineLayout {
        const layouts = try allocator.dupe(BindGroupLayout, desc.bind_group_layouts);
        return .{
            .bind_group_layouts = layouts,
            .label = desc.label,
        };
    }

    pub fn deinit(self: *PipelineLayout, allocator: std.mem.Allocator) void {
        allocator.free(self.bind_group_layouts);
    }
};

/// Concrete resource references (runtime data).
pub const BoundResource = union(enum) {
    buffer: struct {
        raw: *mtl.MTLBuffer,
        offset: u64,
        size: ?u64,
    },
    texture: struct {
        raw: *mtl.MTLTexture,
    },
    sampler: struct {
        raw: *mtl.MTLSamplerState,
    },
};

/// BindGroup: set of bound resources.
/// In Metal, setBindGroup expands to series of setVertexBuffer/setFragmentTexture calls.
/// Binding number maps directly to Metal buffer/texture/sampler index.
pub const BindGroup = struct {
    layout: BindGroupLayout,
    bindings: []const Binding,

    pub const Binding = struct {
        slot: u32,
        visibility: gpu.ShaderStages,
        resource: BoundResource,
    };

    /// Create BindGroup from descriptor.
    pub fn init(allocator: std.mem.Allocator, desc: gpu.BindGroupDescriptor) !BindGroup {
        const layout = desc.layout;

        // Validate every buffer range before retaining anything, keeping the
        // failure path allocation- and ownership-neutral.
        for (desc.entries) |entry| switch (entry.resource) {
            .buffer => |buf| {
                if (buf.offset > buf.buffer.size) return error.InvalidBufferBinding;
                if (buf.size) |size| {
                    if (size == 0 or size > buf.buffer.size - buf.offset) {
                        return error.InvalidBufferBinding;
                    }
                }
            },
            else => {},
        };

        const bindings = try allocator.alloc(Binding, desc.entries.len);
        errdefer allocator.free(bindings);

        for (desc.entries, 0..) |entry, i| {
            // Look up visibility from layout.
            const visibility = findVisibility(layout, entry.binding);

            bindings[i] = .{
                .slot = entry.binding,
                .visibility = visibility,
                .resource = switch (entry.resource) {
                    .buffer => |buf| .{
                        .buffer = .{
                            // A BindGroup owns references independently of the
                            // descriptor wrappers supplied by its caller.
                            .raw = mtl.retain(buf.buffer.raw),
                            .offset = buf.offset,
                            .size = buf.size,
                        },
                    },
                    .texture_view => |tv| .{ .texture = .{
                        .raw = mtl.retain(tv.raw),
                    } },
                    .sampler => |s| .{ .sampler = .{
                        .raw = mtl.retain(s.raw),
                    } },
                },
            };
        }

        return .{
            .layout = layout,
            .bindings = bindings,
        };
    }

    pub fn deinit(self: *BindGroup, allocator: std.mem.Allocator) void {
        for (self.bindings) |binding| switch (binding.resource) {
            .buffer => |buf| mtl.release(buf.raw),
            .texture => |texture| mtl.release(texture.raw),
            .sampler => |sampler| mtl.release(sampler.raw),
        };
        allocator.free(self.bindings);
    }

    /// Apply BindGroup to Metal RenderEncoder.
    /// group_index: BindGroup index in PipelineLayout; offsets buffer slot to avoid
    /// collision with other BindGroups.
    /// Offset strategy:
    ///   - buffer slot = group_index * MAX_BINDINGS_PER_GROUP + binding
    ///   - texture slot = binding (no offset; Metal texture slots independent)
    ///   - sampler slot = binding (same).
    pub fn applyToRenderEncoder(
        self: *const BindGroup,
        encoder: *mtl.MTLRenderCommandEncoder,
        group_index: u32,
    ) void {
        const buffer_offset = group_index * MAX_BINDINGS_PER_GROUP;

        for (self.bindings) |binding| {
            switch (binding.resource) {
                .buffer => |buf| {
                    const slot = buffer_offset + binding.slot;
                    if (binding.visibility.vertex) {
                        mtl.metal_render_encoder_set_vertex_buffer(
                            encoder,
                            buf.raw,
                            buf.offset,
                            slot,
                        );
                    }
                    if (binding.visibility.fragment) {
                        mtl.metal_render_encoder_set_fragment_buffer(
                            encoder,
                            buf.raw,
                            buf.offset,
                            slot,
                        );
                    }
                },
                .texture => |tex| {
                    if (binding.visibility.vertex) {
                        mtl.metal_render_encoder_set_vertex_texture(
                            encoder,
                            tex.raw,
                            binding.slot,
                        );
                    }
                    if (binding.visibility.fragment) {
                        mtl.metal_render_encoder_set_fragment_texture(
                            encoder,
                            tex.raw,
                            binding.slot,
                        );
                    }
                },
                .sampler => |smp| {
                    if (binding.visibility.vertex) {
                        mtl.metal_render_encoder_set_vertex_sampler(
                            encoder,
                            smp.raw,
                            binding.slot,
                        );
                    }
                    if (binding.visibility.fragment) {
                        mtl.metal_render_encoder_set_fragment_sampler(
                            encoder,
                            smp.raw,
                            binding.slot,
                        );
                    }
                },
            }
        }
    }

    /// Apply BindGroup to Metal ComputeEncoder.
    pub fn applyToComputeEncoder(
        self: *const BindGroup,
        encoder: *mtl.MTLComputeCommandEncoder,
        group_index: u32,
    ) void {
        const buffer_offset = group_index * MAX_BINDINGS_PER_GROUP;

        for (self.bindings) |binding| {
            switch (binding.resource) {
                .buffer => |buf| {
                    mtl.metal_compute_encoder_set_buffer(
                        encoder,
                        buf.raw,
                        buf.offset,
                        buffer_offset + binding.slot,
                    );
                },
                .texture => |tex| {
                    mtl.metal_compute_encoder_set_texture(
                        encoder,
                        tex.raw,
                        binding.slot,
                    );
                },
                .sampler => {
                    // Metal compute encoder has no setSampler; samplers passed via argument buffer
                    // typically.
                },
            }
        }
    }
};

/// Max binding count per BindGroup (for buffer slot offset).
const MAX_BINDINGS_PER_GROUP: u32 = 16;

/// Look up visibility for binding in layout.
fn findVisibility(layout: BindGroupLayout, binding: u32) gpu.ShaderStages {
    for (layout.entries) |entry| {
        if (entry.binding == binding) return entry.visibility;
    }
    // Default: vertex + fragment.
    return .{ .vertex = true, .fragment = true };
}

// ============================================================================
// Tests
// ============================================================================

test "BindGroupLayout: init and deinit" {
    const allocator = std.testing.allocator;

    const entries = [_]gpu.BindGroupLayoutEntry{
        .{
            .binding = 0,
            .visibility = .{ .vertex = true, .fragment = true },
            .ty = .{ .buffer = .{ .ty = .uniform } },
        },
        .{
            .binding = 1,
            .visibility = .{ .fragment = true },
            .ty = .{ .texture = .{} },
        },
    };

    var layout = try BindGroupLayout.init(allocator, .{
        .entries = &entries,
    });
    defer layout.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), layout.entries.len);
    try std.testing.expectEqual(@as(u32, 0), layout.entries[0].binding);
    try std.testing.expectEqual(@as(u32, 1), layout.entries[1].binding);
}

test "PipelineLayout: init and deinit" {
    const allocator = std.testing.allocator;

    const entries = [_]gpu.BindGroupLayoutEntry{
        .{
            .binding = 0,
            .visibility = .{ .vertex = true },
            .ty = .{ .buffer = .{} },
        },
    };

    var bg_layout = try BindGroupLayout.init(allocator, .{
        .entries = &entries,
    });
    defer bg_layout.deinit(allocator);

    const layouts = [_]BindGroupLayout{bg_layout};
    var pipeline_layout = try PipelineLayout.init(allocator, .{
        .bind_group_layouts = &layouts,
    });
    defer pipeline_layout.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), pipeline_layout.bind_group_layouts.len);
}

test "findVisibility: returns correct stages" {
    const entries = [_]gpu.BindGroupLayoutEntry{
        .{
            .binding = 0,
            .visibility = .{ .vertex = true },
            .ty = .{ .buffer = .{} },
        },
        .{
            .binding = 1,
            .visibility = .{ .fragment = true },
            .ty = .{ .texture = .{} },
        },
    };

    const layout = BindGroupLayout{
        .entries = &entries,
    };

    const vis0 = findVisibility(layout, 0);
    try std.testing.expect(vis0.vertex);
    try std.testing.expect(!vis0.fragment);

    const vis1 = findVisibility(layout, 1);
    try std.testing.expect(!vis1.vertex);
    try std.testing.expect(vis1.fragment);

    // Non-existent binding returns default.
    const vis_default = findVisibility(layout, 99);
    try std.testing.expect(vis_default.vertex);
    try std.testing.expect(vis_default.fragment);
}
