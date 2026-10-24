const std = @import("std");
const gpu = @import("gpu");
const d12 = @import("gpu").Backend.native;
const a = std.heap.page_allocator;
var verified_pixels: usize = 0;
extern fn zenit_d12_test_gate_create(*anyopaque, *anyopaque) *anyopaque;
extern fn zenit_d12_test_gate_signal(*anyopaque) void;
extern fn zenit_d12_test_gate_release(*anyopaque) void;
fn expectError(expected: anyerror, result: anytype) !void {
    if (result) |_| return error.ExpectedFailure else |actual| if (actual != expected) return actual;
}
fn execute(kind: u32, format: gpu.TextureFormat, gated: bool) !void {
    var device = try d12.Device.init(true);
    var device_live = true;
    defer if (device_live) device.destroy();
    var queue = try device.createQueue();
    defer queue.deinit(5000) catch @panic("storage queue teardown failed");
    var shader_readback = try device.createBuffer(a, .{ .size = 4, .usage = .{ .map_read = true, .copy_dst = true } });
    defer shader_readback.destroy();
    try expectError(error.InvalidTextureDescriptor, device.createTexture(a, .{ .size = .{ .width = 2, .height = 1 }, .format = .rgba8_unorm_srgb, .usage = .{ .storage_binding = true } }));
    var encoder = try device.createCommandEncoder();
    defer encoder.deinit();
    var texture = try device.createTexture(a, .{ .size = .{ .width = 4, .height = if (kind == 1) 1 else 2, .depth = if (kind == 3 or kind == 6) 4 else 1 }, .dimension = if (kind == 1) .@"1d" else if (kind == 6) .@"3d" else .@"2d", .mip_level_count = 3, .format = format, .usage = .{ .storage_binding = true, .texture_binding = true, .copy_src = true, .copy_dst = true } });
    var texture_live = true;
    defer if (texture_live) texture.destroy();
    const layers: usize = if (kind == 6) 1 else texture.size.depth;
    // Initialize every subresource so preservation can be checked after writes.
    for (0..layers) |layer| for (0..3) |mip| {
        const region = try texture.fullRegion(@intCast(mip), @intCast(layer));
        const layout = try texture.copyLayout(region, 0);
        var upload = try device.createBuffer(a, .{ .size = layout.required_bytes, .usage = .{ .map_write = true, .copy_src = true } });
        defer upload.destroy();
        @memset(try upload.getMappedRange(0, upload.size), 0);
        try encoder.copyBufferToTexture(&upload, 0, layout.row_pitch, &texture, region);
    };
    {
        const dimension: gpu.TextureViewDimension = switch (kind) {
            1 => .@"1d",
            2 => .@"2d",
            3 => .@"2d_array",
            6 => .@"3d",
            else => unreachable,
        };
        var view = try texture.createStorageView(.{ .dimension = dimension, .base_mip_level = 1, .base_array_layer = if (kind == 3) 1 else 0, .array_layer_count = if (kind == 3) 2 else 1 });
        defer view.destroy();
        try expectError(error.InvalidTextureView, texture.createStorageView(.{ .base_mip_level = 3 }));
        try expectError(error.InvalidTextureView, texture.createStorageView(.{ .mip_level_count = 2 }));
        try expectError(error.InvalidTextureView, texture.createStorageView(.{ .dimension = .cube }));
        try expectError(error.UnsupportedViewFormat, texture.createStorageView(.{ .format = .r8_uint }));
        const binding: gpu.BindGroupLayoutEntry = .{ .binding = 0, .visibility = .{ .compute = true }, .ty = .{ .storage_texture = .{ .format = format, .view_dimension = dimension } } };
        var bgl = try device.createBindGroupLayout(a, .{ .entries = &.{binding} });
        defer bgl.deinit();
        var layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{bgl} });
        defer layout.deinit();
        var group = try device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &.{.{ .binding = 0, .texture_view = &view }} });
        defer group.deinit();
        var srv = try texture.createView(.{ .dimension = dimension });
        defer srv.destroy();
        try expectError(error.InvalidBindGroup, device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &.{.{ .binding = 0, .texture_view = &srv }} }));
        var bad_bgl = try device.createBindGroupLayout(a, .{ .entries = &.{.{ .binding = 0, .visibility = .{ .compute = true }, .ty = .{ .storage_texture = .{ .format = .r8_uint, .view_dimension = dimension } } }} });
        defer bad_bgl.deinit();
        var bad_layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{bad_bgl} });
        defer bad_layout.deinit();
        try expectError(error.InvalidBindGroup, device.createBindGroup(a, .{ .layout = &bad_layout, .group = 0, .entries = &.{.{ .binding = 0, .texture_view = &view }} }));
        const ty: []const u8 = switch (format) {
            .r32_uint => "uint",
            .r32_sint => "int",
            .rgba8_unorm => "float4",
            else => "float",
        };
        const value: []const u8 = switch (format) {
            .r32_uint => "4000000000u+id.x",
            .r32_sint => "-100-int(id.x)",
            .rgba8_unorm => "float4(id.x%2?0:1,1,0,1)",
            else => "100+id.x",
        };
        const tex_type: []const u8 = switch (kind) {
            1 => "RWTexture1D",
            2 => "RWTexture2D",
            3 => "RWTexture2DArray",
            6 => "RWTexture3D",
            else => unreachable,
        };
        const coordinate: []const u8 = if (kind == 1) "id.x" else if (kind == 2) "uint2(id.x,0)" else "uint3(id.x%2,0,id.x/2)";
        const source = try std.fmt.allocPrint(a, "{s}<{s}> image:register(u0); [numthreads(4,1,1)] void main(uint3 id:SV_DispatchThreadID){{if(id.x>={d})return;image[{s}]={s};}}", .{ tex_type, ty, if (kind == 1 or kind == 2) @as(u32, 2) else 4, coordinate, value });
        defer a.free(source);
        var module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = source, .entry_points = &.{.{ .name = "main", .stage = .compute }} } } });
        defer module.deinit();
        var function = try module.getFunction("main");
        defer function.deinit();
        var pipeline = try device.createComputePipeline(.{ .layout = &layout, .compute_function = &function });
        defer pipeline.deinit();
        var alias_bgl = try device.createBindGroupLayout(a, .{ .entries = &.{ binding, .{ .binding = 1, .visibility = .{ .compute = true }, .ty = .{ .texture = .{ .view_dimension = dimension, .sample_type = if (format == .r32_uint) .uint else if (format == .r32_sint) .sint else .float } } } } });
        defer alias_bgl.deinit();
        var alias_layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{alias_bgl} });
        defer alias_layout.deinit();
        var alias_group = try device.createBindGroup(a, .{ .layout = &alias_layout, .group = 0, .entries = &.{ .{ .binding = 0, .texture_view = &view }, .{ .binding = 1, .texture_view = &srv } } });
        defer alias_group.deinit();
        var alias_pipeline = try device.createComputePipeline(.{ .layout = &alias_layout, .compute_function = &function });
        defer alias_pipeline.deinit();
        try expectError(error.InvalidDispatch, encoder.dispatch(&alias_pipeline, &.{alias_group}, 1, 1, 1));
        try encoder.dispatch(&pipeline, &.{group}, 1, 1, 1);
        try encoder.dispatch(&pipeline, &.{group}, 1, 1, 1);
        // Read the just-written UAV through a production SRV dispatch in the
        // same command list, before the independent pixel readback checks.
        var result = try device.createBuffer(a, .{ .size = 4, .usage = .{ .storage = true, .copy_src = true } });
        defer result.destroy();
        var read_bgl = try device.createBindGroupLayout(a, .{ .entries = &.{ alias_bgl.entries[1], .{ .binding = 2, .visibility = .{ .compute = true }, .ty = .{ .buffer = .{ .ty = .storage } } } } });
        defer read_bgl.deinit();
        var read_layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{read_bgl} });
        defer read_layout.deinit();
        var read_group = try device.createBindGroup(a, .{ .layout = &read_layout, .group = 0, .entries = &.{ .{ .binding = 1, .texture_view = &srv }, .{ .binding = 2, .buffer = &result, .stride = 4 } } });
        defer read_group.deinit();
        const load_coordinate: []const u8 = switch (kind) {
            1 => "int2(0,1)",
            2 => "int3(0,0,1)",
            3 => "int4(0,0,1,1)",
            6 => "int4(0,0,0,1)",
            else => unreachable,
        };
        const read_source = try std.fmt.allocPrint(a, "{s}<{s}> image:register(t1); RWStructuredBuffer<uint> result:register(u2); [numthreads(1,1,1)] void main(){{result[0]=asuint(image.Load({s}){s});}}", .{ tex_type[2..], ty, load_coordinate, if (format == .rgba8_unorm) @as([]const u8, ".x") else "" });
        defer a.free(read_source);
        var read_module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = read_source, .entry_points = &.{.{ .name = "main", .stage = .compute }} } } });
        defer read_module.deinit();
        var read_function = try read_module.getFunction("main");
        defer read_function.deinit();
        var read_pipeline = try device.createComputePipeline(.{ .layout = &read_layout, .compute_function = &read_function });
        defer read_pipeline.deinit();
        try encoder.dispatch(&read_pipeline, &.{read_group}, 1, 1, 1);
        try encoder.copyBufferToBuffer(&result, 0, &shader_readback, 0, 4);
    }
    var readbacks: [12]d12.Buffer = undefined;
    var footprints: [12]d12.TextureCopyLayout = undefined;
    var regions: [12]d12.TextureRegion = undefined;
    var count: usize = 0;
    defer for (readbacks[0..count]) |*buffer| buffer.destroy();
    for (0..layers) |layer| for (0..3) |mip| {
        const region = try texture.fullRegion(@intCast(mip), @intCast(layer));
        const footprint = try texture.copyLayout(region, 512);
        readbacks[count] = try device.createBuffer(a, .{ .size = footprint.required_bytes, .usage = .{ .map_read = true, .copy_dst = true } });
        count += 1;
        footprints[count - 1] = footprint;
        regions[count - 1] = region;
        try encoder.copyTextureToBuffer(&texture, region, &readbacks[count - 1], 512, footprint.row_pitch);
    };
    texture.destroy();
    texture_live = false;
    var command = try encoder.finish();
    const gate = if (gated) zenit_d12_test_gate_create(device.raw, queue.raw) else null;
    var signaled = false;
    defer if (gate) |g| {
        if (!signaled) zenit_d12_test_gate_signal(g);
        queue.waitIdle(5000) catch @panic("storage gate teardown failed");
        zenit_d12_test_gate_release(g);
    };
    _ = try queue.submit(&.{command});
    command.deinit();
    device.destroy();
    device_live = false;
    if (gate) |g| {
        try expectError(error.GpuTimeout, queue.waitIdle(0));
        try expectError(error.GpuTimeout, queue.deinit(0));
        zenit_d12_test_gate_signal(g);
        signaled = true;
    }
    try queue.waitIdle(5000);
    var actual_shader: u32 = undefined;
    @memcpy(std.mem.asBytes(&actual_shader), try shader_readback.getMappedRange(0, 4));
    const expected_shader: u32 = switch (format) {
        .r32_uint => 4000000000,
        .r32_sint => @bitCast(@as(i32, -100)),
        .rgba8_unorm => @bitCast(@as(f32, 1)),
        else => @bitCast(@as(f32, 100)),
    };
    if (actual_shader != expected_shader) return error.IncorrectStorageToSampleTransition;
    for (readbacks[0..count], footprints[0..count], regions[0..count]) |*buffer, footprint, region| {
        const bytes = try buffer.getMappedRange(0, buffer.size);
        for (0..region.depth) |z| for (0..region.height) |y| for (0..region.width) |x| {
            const changed = region.mip == 1 and (kind != 3 or (region.layer == 1 or region.layer == 2));
            const index: u32 = @intCast(x + if (kind == 3 and changed) (region.layer - 1) * 2 else if (kind == 6) z * 2 else 0);
            var expected: u32 = 0;
            if (changed) expected = switch (format) {
                .r32_uint => 4000000000 + index,
                .r32_sint => @bitCast(-100 - @as(i32, @intCast(index))),
                .rgba8_unorm => if (index % 2 == 0) 0xff00ffff else 0xff00ff00,
                else => @bitCast(@as(f32, @floatFromInt(100 + index))),
            };
            var actual: u32 = undefined;
            const offset = 512 + (z * region.height + y) * footprint.row_pitch + x * 4;
            @memcpy(std.mem.asBytes(&actual), bytes[offset..][0..4]);
            if (actual != expected) return error.IncorrectStorageTexturePixel;
            verified_pixels += 1;
        };
    }
    std.debug.print("PASS: production storage texture kind={d} format={s}, selected mip/layers, repeated UAV writes, untouched subresources, owner destruction{s}\n", .{ kind, @tagName(format), if (gated) @as([]const u8, " and GPU-blocked timeout/retry") else "" });
}
pub fn run() !void {
    verified_pixels = 0;
    for ([_]u32{ 1, 2, 3, 6 }) |kind| try execute(kind, .r32_float, kind == 6);
    for ([_]gpu.TextureFormat{ .r32_uint, .r32_sint, .rgba8_unorm }) |format| try execute(3, format, false);
    std.debug.print("PASS: {d} storage pixel checks and seven production UAV-to-SRV shader results\n", .{verified_pixels});
}
