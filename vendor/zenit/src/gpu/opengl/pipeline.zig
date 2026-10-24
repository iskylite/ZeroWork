//! Owned configured GL pipelines using explicit offline reflection metadata.
const std = @import("std");
const gl = @import("device.zig");
const shaders = @import("generated/shaders.zig");
const Handle = opaque {};
pub const Binding = extern struct { group: u32, binding: u32, kind: u32, stages: u32 };
pub const Sampler = gl.resources.Sampler;
pub const SamplerDescriptor = gl.resources.SamplerDescriptor;
pub const State = extern struct {
    format: gl.resources.Format = .bgra8_unorm,
    blend_enabled: u32 = 1,
    source_rgb: u32 = 1,
    destination_rgb: u32 = 5,
    rgb_operation: u32 = 0,
    source_alpha: u32 = 1,
    destination_alpha: u32 = 5,
    alpha_operation: u32 = 0,
};
pub const DrawRegion = extern struct { viewport: [6]f32, scissor: [4]u32 };
const ShaderCode = extern struct { code: [*]const u8, length: usize };
const TextureUnit = extern struct {
    unit: u32,
    texture_group: u32,
    texture_binding: u32,
    sampler_group: u32,
    sampler_binding: u32,
    uniform_name: [*:0]const u8,
};
extern fn zenit_gl_pipeline_create_configured(*gl.Handle, *const ShaderCode, *const ShaderCode, [*]const Binding, u32, [*]const TextureUnit, u32, *const State, *?*Handle, *gl.Diagnostic) c_int;
extern fn zenit_gl_pipeline_destroy(?*Handle, *gl.Diagnostic) c_int;
extern fn zenit_gl_pipeline_draw_region(*Handle, *anyopaque, [*]const DrawBinding, u32, u32, u32, u32, u32, ?*const [4]f32, ?*const DrawRegion, *gl.Diagnostic) c_int;
pub const DrawBinding = extern struct {
    group: u32,
    binding: u32,
    kind: u32,
    resource: *anyopaque,
    offset: u64 = 0,
    size: u64 = 0,
    pub fn buffer(group: u32, binding: u32, storage: bool, value: *gl.resources.Buffer, offset: u64, size: u64) gl.Error!DrawBinding {
        return .{ .group = group, .binding = binding, .kind = if (storage) 2 else 0, .resource = @ptrCast(value.handle orelse return error.InvalidDescriptor), .offset = offset, .size = size };
    }
    pub fn texture(group: u32, binding: u32, value: *gl.resources.Texture) gl.Error!DrawBinding {
        return .{ .group = group, .binding = binding, .kind = 1, .resource = @ptrCast(value.handle orelse return error.InvalidDescriptor) };
    }
    pub fn sampler(group: u32, binding: u32, value: *Sampler) gl.Error!DrawBinding {
        return .{ .group = group, .binding = binding, .kind = 4, .resource = @ptrCast(value.handle orelse return error.InvalidDescriptor) };
    }
};
pub const Pipeline = struct {
    handle: ?*Handle,
    pub fn init(device: *gl.Device, vertex: []const u8, vertex_entry: [:0]const u8, fragment: []const u8, fragment_entry: [:0]const u8, bindings: []const Binding, format: gl.resources.Format, diag: *gl.Diagnostic) gl.Error!Pipeline {
        return initConfigured(device, vertex, vertex_entry, fragment, fragment_entry, bindings, .{ .format = format }, diag);
    }
    /// Accept only the validated offline inventory. Metadata owns combined
    /// sampler names and slots; creation consumes rather than borrows strings.
    pub fn initConfigured(device: *gl.Device, vertex: []const u8, vertex_entry: [:0]const u8, fragment: []const u8, fragment_entry: [:0]const u8, bindings: []const Binding, state: State, diag: *gl.Diagnostic) gl.Error!Pipeline {
        const vs_entry = findEntry(vertex_entry) orelse return error.InvalidDescriptor;
        const fs_entry = findEntry(fragment_entry) orelse return error.InvalidDescriptor;
        if (vs_entry.stage != .vertex or fs_entry.stage != .fragment or !std.mem.eql(u8, vs_entry.program, fs_entry.program) or !std.mem.eql(u8, vs_entry.code, vertex) or !std.mem.eql(u8, fs_entry.code, fragment)) return error.InvalidDescriptor;
        var merged: [64]Binding = undefined;
        var count: usize = 0;
        for (bindings) |binding| {
            var found = false;
            for (merged[0..count]) |*existing| {
                if (existing.group != binding.group or existing.binding != binding.binding) continue;
                if (existing.kind != binding.kind) return error.InvalidDescriptor;
                existing.stages |= binding.stages;
                found = true;
                break;
            }
            if (!found) {
                if (count == merged.len) return error.InvalidDescriptor;
                merged[count] = binding;
                count += 1;
            }
        }
        var texture_units: [32]TextureUnit = undefined;
        var unit_count: usize = 0;
        for ([_]shaders.Entry{ vs_entry, fs_entry }) |entry| for (entry.texture_units) |unit| {
            if (unit_count == texture_units.len) return error.InvalidDescriptor;
            texture_units[unit_count] = .{ .unit = unit.unit, .texture_group = unit.texture_group, .texture_binding = unit.texture_binding, .sampler_group = unit.sampler_group orelse std.math.maxInt(u32), .sampler_binding = unit.sampler_binding orelse std.math.maxInt(u32), .uniform_name = unit.uniform.ptr };
            unit_count += 1;
        };
        var handle: ?*Handle = null;
        const vs: ShaderCode = .{ .code = vertex.ptr, .length = vertex.len };
        const fs: ShaderCode = .{ .code = fragment.ptr, .length = fragment.len };
        try gl.check(zenit_gl_pipeline_create_configured(device.handle orelse return error.InvalidDescriptor, &vs, &fs, merged[0..count].ptr, @intCast(count), texture_units[0..unit_count].ptr, @intCast(unit_count), &state, &handle, diag));
        return .{ .handle = handle };
    }
    pub fn destroyChecked(self: *Pipeline, diag: *gl.Diagnostic) gl.Error!void {
        try gl.check(zenit_gl_pipeline_destroy(self.handle, diag));
        self.handle = null;
    }
    pub fn destroy(self: *Pipeline) void {
        var diag: gl.Diagnostic = .{};
        self.destroyChecked(&diag) catch @panic("OpenGL pipeline destruction failed");
    }
    pub fn draw(self: *Pipeline, target: *gl.resources.Texture, bindings: []const DrawBinding, first_vertex: u32, vertices: u32, first_instance: u32, instances: u32, clear: ?[4]f32, diag: *gl.Diagnostic) gl.Error!void {
        try self.drawRegion(target, bindings, first_vertex, vertices, first_instance, instances, clear, null, diag);
    }
    pub fn drawRegion(self: *Pipeline, target: *gl.resources.Texture, bindings: []const DrawBinding, first_vertex: u32, vertices: u32, first_instance: u32, instances: u32, clear: ?[4]f32, region: ?DrawRegion, diag: *gl.Diagnostic) gl.Error!void {
        try gl.check(zenit_gl_pipeline_draw_region(self.handle orelse return error.InvalidDescriptor, @ptrCast(target.handle orelse return error.InvalidDescriptor), bindings.ptr, @intCast(bindings.len), first_vertex, vertices, first_instance, instances, if (clear) |*value| value else null, if (region) |*value| value else null, diag));
    }
};
fn findEntry(name: []const u8) ?shaders.Entry {
    for (shaders.entries) |entry| if (std.mem.eql(u8, name, entry.name)) return entry;
    return null;
}
