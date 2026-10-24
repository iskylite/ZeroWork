const std = @import("std");
const gpu = @import("gpu");
const d12 = @import("gpu").Backend.native;
extern fn zenit_d12_test_debug_check(*anyopaque) void;
var sampled_values: u32 = 0;
fn expectError(expected: anyerror, result: anytype) !void {
    if (result) |_| return error.ExpectedFailure else |actual| if (actual != expected) return actual;
}
fn upload(device: *d12.Device, queue: *d12.Queue, texture: *d12.Texture, mip: u32, layer: u32) !void {
    const region = try texture.fullRegion(mip, layer);
    const layout = try texture.copyLayout(region, 0);
    var buffer = try device.createBuffer(std.heap.page_allocator, .{ .size = layout.required_bytes, .usage = .{ .map_write = true, .copy_src = true } });
    defer buffer.destroy();
    const bytes = try buffer.getMappedRange(0, buffer.size);
    @memset(bytes, 0);
    for (0..region.depth) |z| for (0..region.height) |y| for (0..region.width) |x| {
        const value: f32 = @floatFromInt(layer * 100 + mip * 50 + @as(u32, if (x == 0) 10 else 30));
        const raw = std.mem.asBytes(&value);
        const offset = (z * region.height + y) * layout.row_pitch + x * 4;
        @memcpy(bytes[offset..][0..4], raw);
    };
    var encoder = try device.createCommandEncoder();
    defer encoder.deinit();
    try encoder.copyBufferToTexture(&buffer, 0, layout.row_pitch, texture, region);
    var command = try encoder.finish();
    defer command.deinit();
    _ = try queue.submit(&.{command});
    try queue.waitIdle(5000);
}
fn sample(device: *d12.Device, queue: *d12.Queue, view: *d12.TextureView, descriptor: gpu.SamplerDescriptor, kind: u32, expected: [4]f32) !void {
    var sampler = try device.createSampler(std.heap.page_allocator, descriptor);
    var sampler_live = true;
    defer if (sampler_live) sampler.destroy();
    var output = try device.createBuffer(std.heap.page_allocator, .{ .size = 16, .usage = .{ .storage = true, .copy_src = true } });
    defer output.destroy();
    var readback = try device.createBuffer(std.heap.page_allocator, .{ .size = 16, .usage = .{ .map_read = true, .copy_dst = true } });
    defer readback.destroy();
    var encoder = try device.createCommandEncoder();
    defer encoder.deinit();
    {
        const a = std.heap.page_allocator;
        const dimension: gpu.TextureViewDimension = switch (kind) {
            1 => .@"1d",
            2 => .@"2d",
            3 => .@"2d_array",
            4 => .cube,
            5 => .cube_array,
            6 => .@"3d",
            else => unreachable,
        };
        var bgl = try device.createBindGroupLayout(a, .{ .entries = &.{
            .{ .binding = 0, .visibility = .{ .compute = true }, .ty = .{ .texture = .{ .view_dimension = dimension } } },
            .{ .binding = 1, .visibility = .{ .compute = true }, .ty = .{ .buffer = .{ .ty = .storage } } },
            .{ .binding = 2, .visibility = .{ .compute = true }, .ty = .{ .sampler = .{ .ty = if (descriptor.compare != null) .comparison else .filtering } } },
        } });
        defer bgl.deinit();
        var layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{bgl} });
        defer layout.deinit();
        const types = [_][]const u8{ "Texture1D<float>", "Texture2D<float>", "Texture2DArray<float>", "TextureCube<float>", "TextureCubeArray<float>", "Texture3D<float>" };
        const coords = [_][]const u8{ "u", "float2(u,0.5)", "float3(u,0.5,0)", "float3(1,0,0)", "float4(1,0,0,id.x<2?0:1)", "float3(u,0.5,0.5)" };
        const source = try std.fmt.allocPrint(a, "{s} image:register(t0); {s} sampling:register(s2); RWStructuredBuffer<float> result:register(u1); [numthreads(4,1,1)] void main(uint3 id:SV_DispatchThreadID){{float u=id.x==0?0.25:id.x==1?0.75:id.x==2?0.5:1.25; result[id.x]=image.{s}(sampling,{s},{s});}}", .{ types[kind - 1], if (descriptor.compare != null) @as([]const u8, "SamplerComparisonState") else "SamplerState", if (descriptor.compare != null) @as([]const u8, "SampleCmpLevelZero") else "SampleLevel", coords[kind - 1], if (descriptor.compare != null) @as([]const u8, "110") else "0" });
        defer a.free(source);
        var module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = source, .entry_points = &.{.{ .name = "main", .stage = .compute }} } } });
        defer module.deinit();
        var function = try module.getFunction("main");
        defer function.deinit();
        var pipeline = try device.createComputePipeline(.{ .layout = &layout, .compute_function = &function });
        defer pipeline.deinit();
        var group = try device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &.{
            .{ .binding = 2, .sampler = &sampler },
            .{ .binding = 1, .buffer = &output, .stride = 4 },
            .{ .binding = 0, .texture_view = view },
        } });
        defer group.deinit();
        try encoder.dispatch(&pipeline, &.{group}, 1, 1, 1);
    }
    // Recorded groups retain both the native sampler and the pipeline/layout.
    sampler.destroy();
    sampler_live = false;
    try encoder.copyBufferToBuffer(&output, 0, &readback, 0, 16);
    var command = try encoder.finish();
    defer command.deinit();
    _ = try queue.submit(&.{command});
    try queue.waitIdle(5000);
    const bytes = try readback.getMappedRange(0, 16);
    for (expected, 0..) |value, index| {
        var actual: f32 = undefined;
        @memcpy(std.mem.asBytes(&actual), bytes[index * 4 ..][0..4]);
        if (!std.math.isFinite(actual) or @abs(actual - value) > 0.001) {
            std.debug.print("descriptor sample {d}: got {d}, expected {d}\n", .{ index, actual, value });
            return error.IncorrectSample;
        }
    }
    sampled_values += 4;
}
fn validate(device: *d12.Device, texture: *d12.Texture) !void {
    try expectError(error.InvalidTextureView, texture.createView(.{ .base_mip_level = 2 }));
    try expectError(error.InvalidTextureView, texture.createView(.{ .mip_level_count = 0 }));
    try expectError(error.InvalidTextureView, texture.createView(.{ .base_array_layer = 3 }));
    try expectError(error.InvalidTextureView, texture.createView(.{ .base_array_layer = 2, .array_layer_count = 2 }));
    try expectError(error.InvalidTextureView, texture.createView(.{ .dimension = .@"2d" }));
    try expectError(error.InvalidTextureView, texture.createView(.{ .dimension = .cube }));
    try expectError(error.UnsupportedViewFormat, texture.createView(.{ .format = .r32_uint }));
    try expectError(error.InvalidSamplerDescriptor, device.createSampler(std.heap.page_allocator, .{ .max_anisotropy = 0 }));
    try expectError(error.InvalidSamplerDescriptor, device.createSampler(std.heap.page_allocator, .{ .max_anisotropy = 17 }));
    try expectError(error.InvalidSamplerDescriptor, device.createSampler(std.heap.page_allocator, .{ .max_anisotropy = 2 }));
    try expectError(error.InvalidSamplerDescriptor, device.createSampler(std.heap.page_allocator, .{ .lod_min_clamp = 3, .lod_max_clamp = 2 }));
    try expectError(error.InvalidSamplerDescriptor, device.createSampler(std.heap.page_allocator, .{ .lod_min_clamp = -1 }));
    try expectError(error.InvalidSamplerDescriptor, device.createSampler(std.heap.page_allocator, .{ .lod_max_clamp = std.math.inf(f32) }));
    try expectError(error.InvalidSamplerDescriptor, device.createSampler(std.heap.page_allocator, .{ .lod_min_clamp = std.math.nan(f32) }));
}
fn shape(device: *d12.Device, queue: *d12.Queue, kind: u32) !void {
    const dimension: gpu.TextureDimension = if (kind == 1) .@"1d" else if (kind == 6) .@"3d" else .@"2d";
    const view_dimension: gpu.TextureViewDimension = switch (kind) {
        1 => .@"1d",
        2 => .@"2d",
        4 => .cube,
        5 => .cube_array,
        6 => .@"3d",
        else => unreachable,
    };
    var texture = try device.createTexture(std.heap.page_allocator, .{ .size = .{ .width = 2, .height = if (kind == 4 or kind == 5) 2 else 1, .depth = if (kind == 4) 6 else if (kind == 5) 18 else if (kind == 6) 2 else 1 }, .dimension = dimension, .mip_level_count = 2, .format = .r32_float, .usage = .{ .copy_dst = true, .texture_binding = true } });
    var live = true;
    defer if (live) texture.destroy();
    const layers = if (kind == 6) 1 else texture.size.depth;
    for (0..layers) |layer| for (0..2) |mip| try upload(device, queue, &texture, @intCast(mip), @intCast(layer));
    var view = try texture.createView(.{ .dimension = view_dimension, .base_array_layer = if (kind == 5) 6 else 0, .array_layer_count = if (kind == 5) 12 else if (kind == 4) 6 else 1 });
    defer view.destroy();
    var mip_view = try texture.createView(.{ .dimension = view_dimension, .base_mip_level = 1, .mip_level_count = 1, .base_array_layer = if (kind == 5) 6 else 0, .array_layer_count = if (kind == 5) 12 else if (kind == 4) 6 else 1 });
    defer mip_view.destroy();
    if (kind == 5) {
        try expectError(error.InvalidTextureView, texture.createView(.{ .dimension = .cube_array, .base_array_layer = 1, .array_layer_count = 6 }));
        try expectError(error.InvalidTextureView, texture.createView(.{ .dimension = .cube_array, .array_layer_count = 7 }));
        try expectError(error.InvalidTextureView, texture.createView(.{ .dimension = .cube, .base_array_layer = 6, .array_layer_count = 6 }));
    }
    texture.destroy();
    live = false;
    try sample(device, queue, &view, .{}, kind, if (kind == 4) .{ 30, 30, 30, 30 } else if (kind == 5) .{ 630, 630, 1230, 1230 } else .{ 10, 30, 30, 30 });
    try sample(device, queue, &mip_view, .{}, kind, if (kind == 5) .{ 660, 660, 1260, 1260 } else .{ 60, 60, 60, 60 });
    std.debug.print("PASS: real {s} SRV sampling, selected mips/faces and view ownership\n", .{@tagName(view_dimension)});
}
pub fn run() !void {
    sampled_values = 0;
    var sampler_device = try d12.Device.init(true);
    var owned_sampler = try sampler_device.createSampler(std.heap.page_allocator, .{});
    sampler_device.destroy();
    owned_sampler.destroy();
    var device = try d12.Device.init(true);
    defer device.destroy();
    var queue = try device.createQueue();
    defer queue.deinit(5000) catch @panic("view queue teardown failed");
    var texture = try device.createTexture(std.heap.page_allocator, .{ .size = .{ .width = 2, .height = 1, .depth = 3 }, .mip_level_count = 2, .format = .r32_float, .usage = .{ .copy_dst = true, .texture_binding = true } });
    var texture_live = true;
    defer if (texture_live) texture.destroy();
    for (0..3) |layer| for (0..2) |mip| try upload(&device, &queue, &texture, @intCast(mip), @intCast(layer));
    try validate(&device, &texture);
    var view = try texture.createView(.{ .base_array_layer = 1, .array_layer_count = 1 });
    defer view.destroy();
    var mip_view = try texture.createView(.{ .base_array_layer = 2, .array_layer_count = 1, .base_mip_level = 1, .mip_level_count = 1 });
    defer mip_view.destroy();
    texture.destroy();
    texture_live = false;
    try sample(&device, &queue, &view, .{}, 3, .{ 110, 130, 130, 130 });
    try sample(&device, &queue, &view, .{ .min_filter = .linear, .mag_filter = .linear }, 3, .{ 110, 130, 120, 130 });
    try sample(&device, &queue, &view, .{ .address_mode_u = .repeat }, 3, .{ 110, 130, 130, 110 });
    try sample(&device, &queue, &view, .{ .address_mode_u = .mirror_repeat }, 3, .{ 110, 130, 130, 130 });
    try sample(&device, &queue, &view, .{ .address_mode_u = .clamp_to_border }, 3, .{ 110, 130, 130, 0 });
    try sample(&device, &queue, &view, .{ .lod_min_clamp = 1, .lod_max_clamp = 1 }, 3, .{ 160, 160, 160, 160 });
    try sample(&device, &queue, &mip_view, .{}, 3, .{ 260, 260, 260, 260 });
    try sample(&device, &queue, &view, .{ .mipmap_filter = .linear, .lod_min_clamp = 0.5, .lod_max_clamp = 0.5 }, 3, .{ 135, 145, 145, 145 });
    try sample(&device, &queue, &view, .{ .min_filter = .linear, .mag_filter = .linear, .mipmap_filter = .linear, .max_anisotropy = 4 }, 3, .{ 110, 130, 120, 130 });
    for (std.enums.values(gpu.CompareFunction)) |compare| {
        const expected: [4]f32 = switch (compare) {
            .never, .greater => .{ 0, 0, 0, 0 },
            .less, .not_equal => .{ 0, 1, 1, 1 },
            .equal, .greater_equal => .{ 1, 0, 0, 0 },
            .less_equal, .always => .{ 1, 1, 1, 1 },
        };
        try sample(&device, &queue, &view, .{ .compare = compare }, 3, expected);
    }
    try sample(&device, &queue, &view, .{ .compare = .less, .min_filter = .linear, .mag_filter = .linear }, 3, .{ 0, 1, 0.5, 1 });
    for ([_]u32{ 1, 2, 4, 5, 6 }) |kind| try shape(&device, &queue, kind);
    zenit_d12_test_debug_check(device.raw);
    std.debug.print("PASS: {d} actual shader-sampled values, sampler ownership after Device destruction\n", .{sampled_values});
    std.debug.print("PASS: real SRV/sampler shader sampling: selected array layer/mip, point/linear, repeat/mirror/border, LOD clamp and view-owned texture lifetime\n", .{});
}
