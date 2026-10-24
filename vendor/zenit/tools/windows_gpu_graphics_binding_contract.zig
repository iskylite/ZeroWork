const std = @import("std");
const gpu = @import("gpu");
const d12 = @import("gpu").Backend.native;
const a = std.heap.page_allocator;
extern fn zenit_d12_test_gate_create(*anyopaque, *anyopaque) *anyopaque;
extern fn zenit_d12_test_gate_signal(*anyopaque) void;
extern fn zenit_d12_test_gate_release(*anyopaque) void;
extern fn zenit_d12_test_descriptor_pages(*anyopaque, u32) u32;
fn expectError(expected: anyerror, result: anytype) !void {
    if (result) |_| return error.ExpectedFailure else |actual| if (actual != expected) return actual;
}
const code =
    \\cbuffer Config:register(b0,space0){float4 tint;float4 offset;};
    \\Texture2D<float4> images[2]:register(t2,space0);
    \\SamplerState samplers[2]:register(s5,space0);
    \\StructuredBuffer<float4> offsets:register(t3,space1);
    \\RWStructuredBuffer<uint> output:register(u4,space1);
    \\float4 vertex(uint id:SV_VertexID):SV_Position {
    \\ float2 p=id==0?float2(-1,-1):id==1?float2(3,-1):float2(-1,3);
    \\ return float4(p*images[1].Load(int3(0,0,0)).a+offset.xy+offsets[0].xy,0,1);
    \\}
    \\float4 fragment(float4 p:SV_Position):SV_Target {
    \\ uint2 id=uint2(p.xy); float4 c=id.x<3?images[0].SampleLevel(samplers[0],float2(0.25,0.5),0):images[1].SampleLevel(samplers[1],float2(0.75,0.5),0);
    \\ output[id.y*6+id.x]=tint.x>0.75?123u:456u;
    \\ return c*tint+offsets[0];
    \\}
;
pub fn run() !void {
    var device = try d12.Device.init(true);
    defer device.destroy();
    var queue = try device.createQueue();
    defer queue.deinit(5000) catch @panic("graphics bindings teardown failed");
    var encoder = try device.createCommandEncoder();
    defer encoder.deinit();
    var target = try device.createTexture(a, .{ .size = .{ .width = 6, .height = 4 }, .format = .rgba8_unorm, .usage = .{ .render_attachment = true, .copy_src = true, .texture_binding = true } });
    defer target.destroy();
    const target_region = try target.fullRegion(0, 0);
    const target_footprint = try target.copyLayout(target_region, 0);
    var pixels = try device.createBuffer(a, .{ .size = target_footprint.required_bytes, .usage = .{ .map_read = true, .copy_dst = true } });
    defer pixels.destroy();
    var values = try device.createBuffer(a, .{ .size = 96, .usage = .{ .map_read = true, .copy_dst = true } });
    defer values.destroy();
    {
        var texture = try device.createTexture(a, .{ .size = .{ .width = 2, .height = 1 }, .format = .rgba8_unorm, .usage = .{ .texture_binding = true, .copy_dst = true } });
        defer texture.destroy();
        var view = try texture.createView(.{});
        defer view.destroy();
        var sampler = try device.createSampler(a, .{});
        defer sampler.destroy();
        var linear = try device.createSampler(a, .{ .min_filter = .linear, .mag_filter = .linear });
        defer linear.destroy();
        const region = try texture.fullRegion(0, 0);
        const footprint = try texture.copyLayout(region, 0);
        var upload = try device.createBuffer(a, .{ .size = footprint.required_bytes, .usage = .{ .map_write = true, .copy_src = true } });
        defer upload.destroy();
        @memcpy(try upload.getMappedRange(0, 8), &[_]u8{ 255, 0, 0, 255, 0, 255, 0, 255 });
        try encoder.copyBufferToTexture(&upload, 0, footprint.row_pitch, &texture, region);
        var uniform = try device.createBuffer(a, .{ .size = 512, .usage = .{ .uniform = true, .map_write = true } });
        defer uniform.destroy();
        const uniform_bytes = try uniform.getMappedRange(0, 512);
        @memset(uniform_bytes, 0);
        const white = [_]f32{ 1, 1, 1, 1 };
        const dim = [_]f32{ 0.5, 0.5, 1, 1 };
        @memcpy(uniform_bytes[0..16], std.mem.sliceAsBytes(&white));
        @memcpy(uniform_bytes[256..272], std.mem.sliceAsBytes(&dim));
        var source = try device.createBuffer(a, .{ .size = 96, .usage = .{ .storage = true, .map_write = true } });
        defer source.destroy();
        @memset(try source.getMappedRange(0, 96), 0);
        var output = try device.createBuffer(a, .{ .size = 96, .usage = .{ .storage = true, .copy_src = true } });
        defer output.destroy();
        const both: gpu.ShaderStages = .{ .vertex = true, .fragment = true };
        var b0 = try device.createBindGroupLayout(a, .{ .entries = &.{
            .{ .binding = 0, .visibility = both, .ty = .{ .buffer = .{ .ty = .uniform } } },
            .{ .binding = 2, .visibility = both, .count = 2, .ty = .{ .texture = .{} } },
            .{ .binding = 5, .visibility = .{ .fragment = true }, .count = 2, .ty = .{ .sampler = .{ .ty = .filtering } } },
        } });
        defer b0.deinit();
        var b1 = try device.createBindGroupLayout(a, .{ .entries = &.{
            .{ .binding = 3, .visibility = both, .ty = .{ .buffer = .{ .ty = .read_only_storage } } },
            .{ .binding = 4, .visibility = .{ .fragment = true }, .ty = .{ .buffer = .{ .ty = .storage } } },
        } });
        defer b1.deinit();
        var layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{ b0, b1 } });
        defer layout.deinit();
        var module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = code, .entry_points = &.{ .{ .name = "vertex", .stage = .vertex }, .{ .name = "fragment", .stage = .fragment } } } } });
        defer module.deinit();
        var vertex = try module.getFunction("vertex");
        defer vertex.deinit();
        var fragment = try module.getFunction("fragment");
        defer fragment.deinit();
        var pipeline = try device.createRenderPipeline(.{ .layout = &layout, .vertex_function = &vertex, .fragment_function = &fragment, .targets = &.{.{ .format = .rgba8_unorm }} });
        defer pipeline.deinit();
        var entries = [_]d12.BindGroupEntry{
            .{ .binding = 5, .array_index = 1, .sampler = &linear },
            .{ .binding = 2, .array_index = 1, .texture_view = &view },
            .{ .binding = 0, .buffer = &uniform, .size = 32 },
            .{ .binding = 5, .sampler = &sampler },
            .{ .binding = 2, .texture_view = &view },
        };
        var g0 = try device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &entries });
        defer g0.deinit();
        entries[2].offset = 256;
        var dim_group = try device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &entries });
        defer dim_group.deinit();
        entries[2].size = 16;
        var undersized = try device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &entries });
        defer undersized.deinit();
        var feedback_view = try target.createView(.{});
        defer feedback_view.destroy();
        entries[2].size = 32;
        entries[1].texture_view = &feedback_view;
        var feedback = try device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &entries });
        defer feedback.deinit();
        var other_entries = [_]d12.BindGroupEntry{ .{ .binding = 4, .buffer = &output, .stride = 4 }, .{ .binding = 3, .buffer = &source, .stride = 16 } };
        var g1 = try device.createBindGroup(a, .{ .layout = &layout, .group = 1, .entries = &other_entries });
        defer g1.deinit();
        other_entries[1].stride = 4;
        var wrong_stride = try device.createBindGroup(a, .{ .layout = &layout, .group = 1, .entries = &other_entries });
        defer wrong_stride.deinit();
        other_entries[1] = .{ .binding = 3, .buffer = &output, .stride = 16 };
        var alias = try device.createBindGroup(a, .{ .layout = &layout, .group = 1, .entries = &other_entries });
        defer alias.deinit();
        const integer_code = "Texture2D<uint4> images[2]:register(t2); float4 vertex(uint id:SV_VertexID):SV_Position {float2 p=id==0?float2(-1,-1):id==1?float2(3,-1):float2(-1,3);return float4(p*images[1].Load(int3(0,0,0)).a,0,1);} float4 fragment(float4 p:SV_Position):SV_Target {return images[0].Load(int3(0,0,0))+images[1].Load(int3(1,0,0));}";
        var integer_module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = integer_code, .entry_points = &.{ .{ .name = "vertex", .stage = .vertex }, .{ .name = "fragment", .stage = .fragment } } } } });
        defer integer_module.deinit();
        var integer_vertex = try integer_module.getFunction("vertex");
        defer integer_vertex.deinit();
        var integer_fragment = try integer_module.getFunction("fragment");
        defer integer_fragment.deinit();
        var wrong_vertex_type = try device.createRenderPipeline(.{ .layout = &layout, .vertex_function = &integer_vertex, .fragment_function = &fragment, .targets = &.{.{ .format = .rgba8_unorm }} });
        defer wrong_vertex_type.deinit();
        var wrong_fragment_type = try device.createRenderPipeline(.{ .layout = &layout, .vertex_function = &vertex, .fragment_function = &integer_fragment, .targets = &.{.{ .format = .rgba8_unorm }} });
        defer wrong_fragment_type.deinit();
        var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .texture = &target, .load_op = .clear }} });
        defer pass.deinit();
        try expectError(error.InvalidDraw, pass.draw(.{ .pipeline = &pipeline, .vertex_count = 3 }));
        try expectError(error.InvalidDraw, pass.draw(.{ .pipeline = &pipeline, .vertex_count = 3, .bind_groups = &.{ g1, g0 } }));
        try expectError(error.InvalidDraw, pass.draw(.{ .pipeline = &pipeline, .vertex_count = 3, .bind_groups = &.{ undersized, g1 } }));
        try expectError(error.InvalidDraw, pass.draw(.{ .pipeline = &pipeline, .vertex_count = 3, .bind_groups = &.{ g0, wrong_stride } }));
        try expectError(error.InvalidDraw, pass.draw(.{ .pipeline = &pipeline, .vertex_count = 3, .bind_groups = &.{ feedback, g1 } }));
        try expectError(error.InvalidDraw, pass.draw(.{ .pipeline = &pipeline, .vertex_count = 3, .bind_groups = &.{ g0, alias } }));
        try expectError(error.InvalidDraw, pass.draw(.{ .pipeline = &wrong_vertex_type, .vertex_count = 3, .bind_groups = &.{ g0, g1 } }));
        try expectError(error.InvalidDraw, pass.draw(.{ .pipeline = &wrong_fragment_type, .vertex_count = 3, .bind_groups = &.{ g0, g1 } }));
        try pass.draw(.{ .pipeline = &pipeline, .vertex_count = 3, .bind_groups = &.{ g0, g1 } });
        // Cross both descriptor page boundaries. These tiny scissored draws
        // must not overwrite the first full-target draw's descriptors, even
        // though every owner is released before the blocked GPU can execute.
        for (0..300) |i| {
            try pass.draw(.{ .pipeline = &pipeline, .vertex_count = 3, .bind_groups = &.{ if (i % 2 == 0) g0 else dim_group, g1 }, .scissor = .{ .x = 2, .y = 1, .width = 1, .height = 1 } });
        }
        const resource_pages = zenit_d12_test_descriptor_pages(encoder.raw.?, 0);
        const sampler_pages = zenit_d12_test_descriptor_pages(encoder.raw.?, 1);
        if (resource_pages < 2 or sampler_pages < 2 or resource_pages > 4 or sampler_pages > 4)
            return error.DescriptorPagesNotReusedOrRolledOver;
        std.debug.print("graphics descriptor rollover: 301 draws, resource pages={d}, sampler pages={d}\n", .{ resource_pages, sampler_pages });
        // The second draw uses different immutable descriptors in the same pass.
        var indices = try device.createBuffer(a, .{ .size = 6, .usage = .{ .index = true, .map_write = true } });
        defer indices.destroy();
        const index_values = [_]u16{ 0, 1, 2 };
        @memcpy(try indices.getMappedRange(0, 6), std.mem.sliceAsBytes(&index_values));
        try pass.drawIndexed(.{ .pipeline = &pipeline, .index_count = 3, .index_buffer = .{ .buffer = &indices, .format = .uint16 }, .bind_groups = &.{ dim_group, g1 }, .scissor = .{ .x = 2, .y = 1, .width = 3, .height = 2 } });
        try pass.end();
        try encoder.copyBufferToBuffer(&output, 0, &values, 0, 96);
    }
    try encoder.copyTextureToBuffer(&target, target_region, &pixels, 0, target_footprint.row_pitch);
    var command = try encoder.finish();
    const gate = zenit_d12_test_gate_create(device.raw, queue.raw);
    var signaled = false;
    defer {
        if (!signaled) zenit_d12_test_gate_signal(gate);
        queue.waitIdle(5000) catch @panic("graphics binding gate teardown failed");
        zenit_d12_test_gate_release(gate);
    }
    _ = try queue.submit(&.{command});
    command.deinit();
    try expectError(error.GpuTimeout, queue.waitIdle(0));
    try expectError(error.GpuTimeout, queue.deinit(0));
    zenit_d12_test_gate_signal(gate);
    signaled = true;
    try queue.waitIdle(5000);
    const colors = try pixels.getMappedRange(0, pixels.size);
    const numbers = try values.getMappedRange(0, 96);
    var frame: [6 * 4 * 4]u8 = undefined;
    for (0..4) |y| for (0..6) |x| {
        const dimmed = x >= 2 and x < 5 and y >= 1 and y < 3;
        const c = colors[y * target_footprint.row_pitch + x * 4 ..][0..4];
        @memcpy(frame[(y * 6 + x) * 4 ..][0..4], c);
        const channel = if (x < 3) c[0] else c[1];
        if (c[2] != 0 or c[3] != 255 or (if (x < 3) c[1] else c[0]) != 0) return error.IncorrectGraphicsSample;
        if (dimmed) {
            if (channel < 127 or channel > 128) return error.IncorrectGraphicsTint;
        } else if (channel != 255) return error.IncorrectGraphicsTint;
        if (std.mem.readInt(u32, numbers[(y * 6 + x) * 4 ..][0..4], .little) != @as(u32, if (dimmed) 456 else 123)) return error.IncorrectPixelUav;
    };
    std.debug.print("GRAPHICS_RGBA8_HEX={s}\n", .{std.fmt.bytesToHex(frame, .lower)});
    try storageTexture();
    std.debug.print("PASS: production graphics descriptors, two groups, VS/PS uniform and texture reads, sampler arrays, PS UAV writes, indexed descriptor switch, 24 color/24 storage values, feedback/alias/stride/size guards and blocked-GPU owner retention\n", .{});
}

fn storageTexture() !void {
    var device = try d12.Device.init(true);
    defer device.destroy();
    var queue = try device.createQueue();
    defer queue.deinit(5000) catch @panic("graphics texture queue teardown failed");
    var encoder = try device.createCommandEncoder();
    defer encoder.deinit();
    var readback = try device.createBuffer(a, .{ .size = 1792, .usage = .{ .map_read = true, .copy_dst = true } });
    defer readback.destroy();
    {
        var target = try device.createTexture(a, .{ .size = .{ .width = 4, .height = 3 }, .format = .r32_uint, .usage = .{ .render_attachment = true, .copy_src = true } });
        defer target.destroy();
        var storage = try device.createTexture(a, .{ .size = .{ .width = 4, .height = 3 }, .format = .r32_uint, .usage = .{ .storage_binding = true, .texture_binding = true, .copy_src = true } });
        defer storage.destroy();
        var uav = try storage.createStorageView(.{});
        defer uav.destroy();
        var srv = try storage.createView(.{});
        defer srv.destroy();
        const generated = "float4 vertex(uint id:SV_VertexID):SV_Position {return float4(id==0?float2(-1,-1):id==1?float2(3,-1):float2(-1,3),0,1);}";
        const write_code = generated ++ "RWTexture2D<uint> image:register(u1); uint fragment(float4 p:SV_Position):SV_Target {uint2 xy=uint2(p.xy);image[xy]=0xabcdu+xy.x+xy.y*4;return 0x123u;}";
        const read_code = generated ++ "Texture2D<uint> image:register(t1); uint fragment(float4 p:SV_Position):SV_Target {return image.Load(int3(uint2(p.xy),0))+1u;}";
        var write_module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = write_code, .entry_points = &.{ .{ .name = "vertex", .stage = .vertex }, .{ .name = "fragment", .stage = .fragment } } } } });
        defer write_module.deinit();
        var read_module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = read_code, .entry_points = &.{ .{ .name = "vertex", .stage = .vertex }, .{ .name = "fragment", .stage = .fragment } } } } });
        defer read_module.deinit();
        var vertex = try write_module.getFunction("vertex");
        defer vertex.deinit();
        var write_fragment = try write_module.getFunction("fragment");
        defer write_fragment.deinit();
        var read_fragment = try read_module.getFunction("fragment");
        defer read_fragment.deinit();
        var write_bgl = try device.createBindGroupLayout(a, .{ .entries = &.{.{ .binding = 1, .visibility = .{ .fragment = true }, .ty = .{ .storage_texture = .{ .format = .r32_uint, .access = .write_only } } }} });
        defer write_bgl.deinit();
        var read_bgl = try device.createBindGroupLayout(a, .{ .entries = &.{.{ .binding = 1, .visibility = .{ .fragment = true }, .ty = .{ .texture = .{ .sample_type = .uint } } }} });
        defer read_bgl.deinit();
        var write_layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{write_bgl} });
        defer write_layout.deinit();
        var read_layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{read_bgl} });
        defer read_layout.deinit();
        var write_pipeline = try device.createRenderPipeline(.{ .layout = &write_layout, .vertex_function = &vertex, .fragment_function = &write_fragment, .targets = &.{.{ .format = .r32_uint }} });
        defer write_pipeline.deinit();
        var read_pipeline = try device.createRenderPipeline(.{ .layout = &read_layout, .vertex_function = &vertex, .fragment_function = &read_fragment, .targets = &.{.{ .format = .r32_uint }} });
        defer read_pipeline.deinit();
        var write_group = try device.createBindGroup(a, .{ .layout = &write_layout, .group = 0, .entries = &.{.{ .binding = 1, .texture_view = &uav }} });
        defer write_group.deinit();
        var read_group = try device.createBindGroup(a, .{ .layout = &read_layout, .group = 0, .entries = &.{.{ .binding = 1, .texture_view = &srv }} });
        defer read_group.deinit();
        var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .texture = &target, .load_op = .clear }} });
        defer pass.deinit();
        try pass.draw(.{ .pipeline = &write_pipeline, .vertex_count = 3, .bind_groups = &.{write_group} });
        try pass.end();
        const region = try storage.fullRegion(0, 0);
        try encoder.copyTextureToBuffer(&storage, region, &readback, 0, 256);
        var second = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .texture = &target }} });
        defer second.deinit();
        try expectError(error.InvalidDraw, second.draw(.{ .pipeline = &read_pipeline, .vertex_count = 3, .bind_groups = &.{write_group} }));
        try second.draw(.{ .pipeline = &read_pipeline, .vertex_count = 3, .bind_groups = &.{read_group} });
        try second.end();
        try encoder.copyTextureToBuffer(&target, try target.fullRegion(0, 0), &readback, 1024, 256);
    }
    var command = try encoder.finish();
    defer command.deinit();
    _ = try queue.submit(&.{command});
    try queue.waitIdle(5000);
    const bytes = try readback.getMappedRange(0, readback.size);
    for (0..3) |y| for (0..4) |x| {
        const n: u32 = @intCast(0xabcd + x + y * 4);
        if (std.mem.readInt(u32, bytes[y * 256 + x * 4 ..][0..4], .little) != n or
            std.mem.readInt(u32, bytes[1024 + y * 256 + x * 4 ..][0..4], .little) != n + 1) return error.IncorrectGraphicsStorageTexture;
    };
    std.debug.print("PASS: production PS storage texture writes, subsequent PS uint texture Load, changed graphics root/layout, 24 integer pixels and pre-finish owner destruction\n", .{});
}
