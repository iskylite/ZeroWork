const std = @import("std");
const gpu = @import("gpu");
const d12 = @import("gpu").Backend.native;
extern fn zenit_d12_test_gate_create(*anyopaque, *anyopaque) *anyopaque;
extern fn zenit_d12_test_gate_signal(*anyopaque) void;
extern fn zenit_d12_test_gate_release(*anyopaque) void;
const a = std.heap.page_allocator;
const compute: gpu.ShaderStages = .{ .compute = true };
fn expectError(expected: anyerror, result: anytype) !void {
    if (result) |_| return error.ExpectedFailure else |actual| if (actual != expected) return actual;
}
fn integerLoad(signed: bool) !void {
    var device = try d12.Device.init(true);
    defer device.destroy();
    var queue = try device.createQueue();
    defer queue.deinit(5000) catch @panic("integer binding teardown failed");
    var texture = try device.createTexture(a, .{ .size = .{ .width = 2, .height = 1 }, .format = if (signed) .r32_sint else .r32_uint, .usage = .{ .texture_binding = true, .copy_dst = true } });
    defer texture.destroy();
    var view = try texture.createView(.{});
    defer view.destroy();
    const region = try texture.fullRegion(0, 0);
    const footprint = try texture.copyLayout(region, 0);
    var upload = try device.createBuffer(a, .{ .size = footprint.required_bytes, .usage = .{ .map_write = true, .copy_src = true } });
    defer upload.destroy();
    const values = if (signed) [_]u32{ @bitCast(@as(i32, -7)), @bitCast(@as(i32, -500000)) } else [_]u32{ 7, 4000000000 };
    @memcpy(try upload.getMappedRange(0, 8), std.mem.sliceAsBytes(&values));
    var output = try device.createBuffer(a, .{ .size = 16, .usage = .{ .storage = true, .copy_src = true } });
    defer output.destroy();
    var readback = try device.createBuffer(a, .{ .size = 16, .usage = .{ .map_read = true, .copy_dst = true } });
    defer readback.destroy();
    var bgl = try device.createBindGroupLayout(a, .{ .entries = &.{
        .{ .binding = 0, .visibility = compute, .ty = .{ .texture = .{ .sample_type = if (signed) .sint else .uint } } },
        .{ .binding = 1, .visibility = compute, .ty = .{ .buffer = .{ .ty = .storage } } },
    } });
    defer bgl.deinit();
    var layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{bgl} });
    defer layout.deinit();
    const entries = [_]d12.BindGroupEntry{ .{ .binding = 0, .texture_view = &view }, .{ .binding = 1, .buffer = &output, .stride = 4 } };
    var group = try device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &entries });
    defer group.deinit();
    const source = try std.fmt.allocPrint(a, "Texture2D<{s}> image:register(t0); RWStructuredBuffer<uint> output:register(u1); [numthreads(4,1,1)] void main(uint3 id:SV_DispatchThreadID){{output[id.x]=asuint(image.Load(int3(id.x%2,0,0)));}}", .{if (signed) @as([]const u8, "int") else "uint"});
    defer a.free(source);
    var module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = source, .entry_points = &.{.{ .name = "main", .stage = .compute }} } } });
    defer module.deinit();
    var function = try module.getFunction("main");
    defer function.deinit();
    var pipeline = try device.createComputePipeline(.{ .layout = &layout, .compute_function = &function });
    defer pipeline.deinit();
    var encoder = try device.createCommandEncoder();
    defer encoder.deinit();
    // The layout accepts this view, but the float shader does not.
    var wrong_module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = "Texture2D<float> image:register(t0); RWStructuredBuffer<uint> output:register(u1); [numthreads(4,1,1)] void main(uint3 id:SV_DispatchThreadID){output[id.x]=asuint(image.Load(int3(id.x%2,0,0)));}", .entry_points = &.{.{ .name = "main", .stage = .compute }} } } });
    defer wrong_module.deinit();
    var wrong_function = try wrong_module.getFunction("main");
    defer wrong_function.deinit();
    var wrong_pipeline = try device.createComputePipeline(.{ .layout = &layout, .compute_function = &wrong_function });
    defer wrong_pipeline.deinit();
    try expectError(error.InvalidDispatch, encoder.dispatch(&wrong_pipeline, &.{group}, 1, 1, 1));
    for ([_]gpu.TextureBindingLayout{
        .{}, .{ .sample_type = if (signed) .uint else .sint }, .{ .sample_type = if (signed) .sint else .uint, .view_dimension = .@"1d" },
    }) |binding| {
        var bad_bgl = try device.createBindGroupLayout(a, .{ .entries = &.{ .{ .binding = 0, .visibility = compute, .ty = .{ .texture = binding } }, bgl.entries[1] } });
        defer bad_bgl.deinit();
        var bad_layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{bad_bgl} });
        defer bad_layout.deinit();
        try expectError(error.InvalidBindGroup, device.createBindGroup(a, .{ .layout = &bad_layout, .group = 0, .entries = &entries }));
    }
    try encoder.copyBufferToTexture(&upload, 0, footprint.row_pitch, &texture, region);
    try encoder.dispatch(&pipeline, &.{group}, 1, 1, 1);
    try encoder.copyBufferToBuffer(&output, 0, &readback, 0, 16);
    var command = try encoder.finish();
    defer command.deinit();
    _ = try queue.submit(&.{command});
    try queue.waitIdle(5000);
    const bytes = try readback.getMappedRange(0, 16);
    for (0..4) |i| {
        var actual: u32 = undefined;
        @memcpy(std.mem.asBytes(&actual), bytes[i * 4 ..][0..4]);
        if (actual != values[i % 2]) return error.IncorrectIntegerTextureLoad;
    }
    std.debug.print("PASS: production {s} texture Load, type/dimension guards, four GPU integer values\n", .{if (signed) @as([]const u8, "sint") else "uint"});
}
fn retainedArrays() !void {
    var device = try d12.Device.init(true);
    var device_live = true;
    defer if (device_live) device.destroy();
    var queue = try device.createQueue();
    defer queue.deinit(5000) catch @panic("retained texture teardown failed");
    var readback = try device.createBuffer(a, .{ .size = 16, .usage = .{ .map_read = true, .copy_dst = true } });
    defer readback.destroy();
    var encoder = try device.createCommandEncoder();
    defer encoder.deinit();
    {
        var texture = try device.createTexture(a, .{ .size = .{ .width = 2, .height = 1 }, .format = .r32_float, .usage = .{ .copy_dst = true, .texture_binding = true } });
        defer texture.destroy();
        var view = try texture.createView(.{});
        defer view.destroy();
        var other_view = try texture.createView(.{});
        defer other_view.destroy();
        var sampler = try device.createSampler(a, .{});
        defer sampler.destroy();
        var linear = try device.createSampler(a, .{ .min_filter = .linear, .mag_filter = .linear });
        defer linear.destroy();
        var comparison = try device.createSampler(a, .{ .compare = .less });
        defer comparison.destroy();
        const region = try texture.fullRegion(0, 0);
        const footprint = try texture.copyLayout(region, 0);
        var upload = try device.createBuffer(a, .{ .size = footprint.required_bytes, .usage = .{ .map_write = true, .copy_src = true } });
        defer upload.destroy();
        const values = [_]f32{ 10, 30 };
        @memcpy(try upload.getMappedRange(0, 8), std.mem.sliceAsBytes(&values));
        var output = try device.createBuffer(a, .{ .size = 16, .usage = .{ .storage = true, .copy_src = true } });
        defer output.destroy();
        var b0 = try device.createBindGroupLayout(a, .{ .entries = &.{
            .{ .binding = 3, .count = 2, .visibility = compute, .ty = .{ .sampler = .{ .ty = .non_filtering } } },
            .{ .binding = 0, .count = 2, .visibility = compute, .ty = .{ .texture = .{} } },
            .{ .binding = 5, .visibility = compute, .ty = .{ .buffer = .{ .ty = .storage } } },
        } });
        defer b0.deinit();
        var b1 = try device.createBindGroupLayout(a, .{ .entries = &.{
            .{ .binding = 2, .visibility = compute, .ty = .{ .sampler = .{ .ty = .non_filtering } } },
            .{ .binding = 0, .visibility = compute, .ty = .{ .texture = .{} } },
        } });
        defer b1.deinit();
        var layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{ b0, b1 } });
        defer layout.deinit();
        var entries0 = [_]d12.BindGroupEntry{
            .{ .binding = 0, .array_index = 1, .texture_view = &other_view },
            .{ .binding = 5, .buffer = &output, .stride = 4 },
            .{ .binding = 3, .array_index = 1, .sampler = &sampler },
            .{ .binding = 0, .texture_view = &view },
            .{ .binding = 3, .sampler = &sampler },
        };
        const entries1 = [_]d12.BindGroupEntry{ .{ .binding = 0, .texture_view = &view }, .{ .binding = 2, .sampler = &sampler } };
        entries0[3].sampler = &sampler;
        try expectError(error.InvalidBindGroup, device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &entries0 }));
        entries0[3].sampler = null;
        var g0 = try device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &entries0 });
        defer g0.deinit();
        var g1 = try device.createBindGroup(a, .{ .layout = &layout, .group = 1, .entries = &entries1 });
        defer g1.deinit();
        entries0[4].sampler = &linear;
        try expectError(error.InvalidBindGroup, device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &entries0 }));
        entries0[4].sampler = &comparison;
        try expectError(error.InvalidBindGroup, device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &entries0 }));
        entries0[4].sampler = &sampler;
        entries0[0].array_index = 0;
        try expectError(error.InvalidBindGroup, device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &entries0 }));
        entries0[0].array_index = 2;
        try expectError(error.InvalidBindGroup, device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &entries0 }));
        entries0[0].array_index = 1;
        var foreign = try d12.Device.init(true);
        defer foreign.destroy();
        var foreign_sampler = try foreign.createSampler(a, .{});
        defer foreign_sampler.destroy();
        entries0[4].sampler = &foreign_sampler;
        try expectError(error.InvalidBindGroup, device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &entries0 }));
        var module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = "Texture2D<float> images[2]:register(t0); SamplerState sampling[2]:register(s3); RWStructuredBuffer<float> output:register(u5); Texture2D<float> other:register(t0,space1); SamplerState otherSampling:register(s2,space1); [numthreads(4,1,1)] void main(uint3 id:SV_DispatchThreadID){float2 p=float2(id.x%2?0.75:0.25,0.5);output[id.x]=images[0].SampleLevel(sampling[0],p,0)+images[1].SampleLevel(sampling[1],p,0)+other.SampleLevel(otherSampling,p,0);}", .entry_points = &.{.{ .name = "main", .stage = .compute }} } } });
        defer module.deinit();
        var function = try module.getFunction("main");
        defer function.deinit();
        var pipeline = try device.createComputePipeline(.{ .layout = &layout, .compute_function = &function });
        defer pipeline.deinit();
        var wrong_module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = "Texture2D<float> images[2]:register(t0); SamplerComparisonState sampling[2]:register(s3); RWStructuredBuffer<float> output:register(u5); [numthreads(4,1,1)] void main(uint3 id:SV_DispatchThreadID){output[id.x]=images[0].SampleCmpLevelZero(sampling[0],float2(0.5,0.5),0);}", .entry_points = &.{.{ .name = "main", .stage = .compute }} } } });
        defer wrong_module.deinit();
        var wrong_function = try wrong_module.getFunction("main");
        defer wrong_function.deinit();
        var wrong_pipeline = try device.createComputePipeline(.{ .layout = &layout, .compute_function = &wrong_function });
        defer wrong_pipeline.deinit();
        try expectError(error.InvalidDispatch, encoder.dispatch(&wrong_pipeline, &.{ g0, g1 }, 1, 1, 1));
        // Two independent views of one texture must merge their read transitions.
        try encoder.copyBufferToTexture(&upload, 0, footprint.row_pitch, &texture, region);
        try encoder.dispatch(&pipeline, &.{ g0, g1 }, 1, 1, 1);
        try encoder.dispatch(&pipeline, &.{ g0, g1 }, 1, 1, 1);
        try encoder.copyBufferToBuffer(&output, 0, &readback, 0, 16);
    }
    // All caller-owned views, textures, samplers, groups, layouts and pipelines
    // have been released before finishing or submitting the command.
    var command = try encoder.finish();
    const gate = zenit_d12_test_gate_create(device.raw, queue.raw);
    var signaled = false;
    defer {
        if (!signaled) zenit_d12_test_gate_signal(gate);
        queue.waitIdle(5000) catch @panic("texture gate teardown failed");
        zenit_d12_test_gate_release(gate);
    }
    _ = try queue.submit(&.{command});
    command.deinit();
    device.destroy();
    device_live = false;
    try expectError(error.GpuTimeout, queue.waitIdle(0));
    try expectError(error.GpuTimeout, queue.deinit(0));
    zenit_d12_test_gate_signal(gate);
    signaled = true;
    try queue.waitIdle(5000);
    const bytes = try readback.getMappedRange(0, 16);
    for ([_]f32{ 30, 90, 30, 90 }, 0..) |expected, i| {
        var actual: f32 = undefined;
        @memcpy(std.mem.asBytes(&actual), bytes[i * 4 ..][0..4]);
        if (actual != expected) return error.IncorrectRetainedTextureSample;
    }
    std.debug.print("PASS: production texture/sampler arrays across two groups, merged view states, pre-finish owner destruction, blocked-GPU timeout/retry and four GPU values\n", .{});
}
pub fn run() !void {
    try integerLoad(false);
    try integerLoad(true);
    try retainedArrays();
}
