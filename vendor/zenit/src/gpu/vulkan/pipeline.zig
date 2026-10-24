//! Vulkan pipeline resources with explicit SPIR-V stage/descriptor contracts.
const vk = @import("device.zig");
const Handle = opaque {};
pub const Binding = extern struct { group: u32, binding: u32, kind: u32, stages: u32 };
pub const State = extern struct {
    format: vk.resources.Format = .bgra8_unorm,
    blend_enabled: u32 = 1,
    source_rgb: u32 = 1,
    destination_rgb: u32 = 5,
    rgb_operation: u32 = 0,
    source_alpha: u32 = 1,
    destination_alpha: u32 = 5,
    alpha_operation: u32 = 0,
};
pub const DrawRegion = extern struct {
    viewport: [6]f32,
    scissor: [4]u32,
};
const ShaderCode = extern struct { code: [*]const u32, length: usize, entry: [*:0]const u8 };
extern fn zenit_vk_pipeline_create(*vk.Handle, *const ShaderCode, *const ShaderCode, [*]const Binding, u32, u32, *?*Handle, *vk.Diagnostic) c_int;
extern fn zenit_vk_pipeline_create_configured(*vk.Handle, *const ShaderCode, *const ShaderCode, [*]const Binding, u32, *const State, *?*Handle, *vk.Diagnostic) c_int;
extern fn zenit_vk_pipeline_destroy(?*Handle) void;

const SamplerHandle = opaque {};
extern fn zenit_vk_sampler_create(*vk.Handle, c_int, c_int, *?*SamplerHandle, *vk.Diagnostic) c_int;
pub const SamplerDescriptor = extern struct {
    mag_filter: u32,
    min_filter: u32,
    mipmap_filter: u32,
    address_u: u32,
    address_v: u32,
    address_w: u32,
    lod_min: f32,
    lod_max: f32,
};
extern fn zenit_vk_sampler_create_descriptor(*vk.Handle, *const SamplerDescriptor, *?*SamplerHandle, *vk.Diagnostic) c_int;
extern fn zenit_vk_sampler_destroy(?*SamplerHandle) void;
extern fn zenit_vk_pipeline_draw_region(*Handle, *anyopaque, [*]const DrawBinding, u32, u32, u32, u32, u32, ?*const [4]f32, ?*const DrawRegion, *vk.Diagnostic) c_int;
extern fn zenit_vk_pipeline_draw(*Handle, *anyopaque, [*]const DrawBinding, u32, u32, u32, u32, u32, ?*const [4]f32, *vk.Diagnostic) c_int;

pub const Sampler = struct {
    handle: ?*SamplerHandle,

    pub fn init(device: *vk.Device, linear: bool, repeat: bool, diagnostic: *vk.Diagnostic) vk.Error!Sampler {
        var handle: ?*SamplerHandle = null;
        try vk.check(zenit_vk_sampler_create(device.handle orelse return error.InvalidDescriptor, @intFromBool(linear), @intFromBool(repeat), &handle, diagnostic));
        return .{ .handle = handle };
    }

    pub fn initDescriptor(device: *vk.Device, desc: SamplerDescriptor, diagnostic: *vk.Diagnostic) vk.Error!Sampler {
        var handle: ?*SamplerHandle = null;
        try vk.check(zenit_vk_sampler_create_descriptor(device.handle orelse return error.InvalidDescriptor, &desc, &handle, diagnostic));
        return .{ .handle = handle.? };
    }
    pub fn destroy(self: *Sampler) void {
        zenit_vk_sampler_destroy(self.handle);
        self.handle = null;
    }
};

pub const DrawBinding = extern struct {
    group: u32,
    binding: u32,
    kind: u32,
    resource: *anyopaque,
    offset: u64 = 0,
    size: u64 = 0,

    pub fn buffer(group: u32, binding: u32, storage: bool, value: *vk.resources.Buffer, offset: u64, size: u64) vk.Error!DrawBinding {
        return .{ .group = group, .binding = binding, .kind = if (storage) 2 else 0, .resource = @ptrCast(value.handle orelse return error.InvalidDescriptor), .offset = offset, .size = size };
    }

    pub fn texture(group: u32, binding: u32, value: *vk.resources.Texture) vk.Error!DrawBinding {
        return .{ .group = group, .binding = binding, .kind = 1, .resource = @ptrCast(value.handle orelse return error.InvalidDescriptor) };
    }

    pub fn sampler(group: u32, binding: u32, value: *Sampler) vk.Error!DrawBinding {
        return .{ .group = group, .binding = binding, .kind = 4, .resource = @ptrCast(value.handle orelse return error.InvalidDescriptor) };
    }
};

pub const Pipeline = struct {
    handle: ?*Handle,

    pub fn init(device: *vk.Device, vertex: []align(4) const u8, vertex_entry: [:0]const u8, fragment: []align(4) const u8, fragment_entry: [:0]const u8, bindings: []const Binding, format: vk.resources.Format, diagnostic: *vk.Diagnostic) vk.Error!Pipeline {
        var handle: ?*Handle = null;
        const vs: ShaderCode = .{ .code = @ptrCast(vertex.ptr), .length = vertex.len, .entry = vertex_entry.ptr };
        const fs: ShaderCode = .{ .code = @ptrCast(fragment.ptr), .length = fragment.len, .entry = fragment_entry.ptr };
        try vk.check(zenit_vk_pipeline_create(device.handle orelse return error.InvalidDescriptor, &vs, &fs, bindings.ptr, @intCast(bindings.len), @backingInt(format), &handle, diagnostic));
        return .{ .handle = handle };
    }

    pub fn initConfigured(device: *vk.Device, vertex: []align(4) const u8, vertex_entry: [:0]const u8, fragment: []align(4) const u8, fragment_entry: [:0]const u8, bindings: []const Binding, state: State, diagnostic: *vk.Diagnostic) vk.Error!Pipeline {
        var handle: ?*Handle = null;
        const vs: ShaderCode = .{ .code = @ptrCast(vertex.ptr), .length = vertex.len, .entry = vertex_entry.ptr };
        const fs: ShaderCode = .{ .code = @ptrCast(fragment.ptr), .length = fragment.len, .entry = fragment_entry.ptr };
        try vk.check(zenit_vk_pipeline_create_configured(device.handle orelse return error.InvalidDescriptor, &vs, &fs, bindings.ptr, @intCast(bindings.len), &state, &handle, diagnostic));
        return .{ .handle = handle };
    }

    pub fn drawRegion(self: *Pipeline, target: *vk.resources.Texture, bindings: []const DrawBinding, first_vertex: u32, vertices: u32, first_instance: u32, instances: u32, clear: ?[4]f32, region: ?DrawRegion, diagnostic: *vk.Diagnostic) vk.Error!void {
        try vk.check(zenit_vk_pipeline_draw_region(self.handle orelse return error.InvalidDescriptor, @ptrCast(target.handle orelse return error.InvalidDescriptor), bindings.ptr, @intCast(bindings.len), first_vertex, vertices, first_instance, instances, if (clear) |*rgba| rgba else null, if (region) |*r| r else null, diagnostic));
    }

    pub fn draw(self: *Pipeline, target: *vk.resources.Texture, bindings: []const DrawBinding, first_vertex: u32, vertices: u32, first_instance: u32, instances: u32, clear: ?[4]f32, diagnostic: *vk.Diagnostic) vk.Error!void {
        try vk.check(zenit_vk_pipeline_draw(self.handle orelse return error.InvalidDescriptor, @ptrCast(target.handle orelse return error.InvalidDescriptor), bindings.ptr, @intCast(bindings.len), first_vertex, vertices, first_instance, instances, if (clear) |*rgba| rgba else null, diagnostic));
    }

    pub fn destroy(self: *Pipeline) void {
        zenit_vk_pipeline_destroy(self.handle);
        self.handle = null;
    }
};
