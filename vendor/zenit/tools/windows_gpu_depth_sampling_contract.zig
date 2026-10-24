const std = @import("std");
const gpu = @import("gpu");
const d12 = @import("gpu").Backend.native;
const a = std.heap.page_allocator;
extern fn zenit_d12_test_gate_create(*anyopaque, *anyopaque) *anyopaque;
extern fn zenit_d12_test_gate_signal(*anyopaque) void;
extern fn zenit_d12_test_gate_release(*anyopaque) void;
fn expectError(expected: anyerror, result: anytype) !void {
    if (result) |_| return error.ExpectedFailure else |actual| if (actual != expected) return actual;
}
const code =
    \\Texture2DArray<float> image:register(t0); SamplerState point_sampler:register(s1); SamplerComparisonState compare:register(s2);
    \\RWStructuredBuffer<float4> output:register(u3); Texture2DArray<float> other:register(t4);
    \\float4 position(uint id){return float4(id==0?float2(-1,-1):id==1?float2(3,-1):float2(-1,3),0,1);}
    \\float4 writer(uint id:SV_VertexID):SV_Position{return position(id);}
    \\float depth():SV_Depth{return 0.25;}
    \\struct V{float4 p:SV_Position;float d:TEXCOORD0;};
    \\V vertex(uint id:SV_VertexID){V v;v.p=position(id);v.d=image.Load(int4(0,0,0,0));return v;}
    \\float4 fragment(V v):SV_Target {uint2 p=uint2(v.p.xy);float3 uv=float3((p+0.5)/float2(4,2),0);return float4(image.Load(int4(p,0,0)),v.d,image.SampleCmpLevelZero(compare,uv,0.5),1);}
    \\[numthreads(4,2,1)] void compute(uint3 id:SV_DispatchThreadID){float3 uv=float3((id.xy+0.5)/float2(4,2),0);output[id.y*4+id.x]=float4(image.Load(int4(id.xy,0,0)),image.SampleLevel(point_sampler,uv,0),image.SampleCmpLevelZero(compare,uv,0.5),other.Load(int4(id.xy,0,0)));}
;
pub fn run() !void {
    var device = try d12.Device.init(true);
    defer device.destroy();
    var queue = try device.createQueue();
    defer queue.deinit(5000) catch @panic("depth sampling teardown failed");
    for ([_]gpu.TextureFormat{ .depth16_unorm, .depth24_plus, .depth32_float, .depth24_plus_stencil8, .depth32_float_stencil8 }) |format| {
        var encoder = try device.createCommandEncoder();
        defer encoder.deinit();
        var readback = try device.createBuffer(a, .{ .size = 1024, .usage = .{ .map_read = true, .copy_dst = true } });
        defer readback.destroy();
        {
            var texture = try device.createTexture(a, .{ .size = .{ .width = 8, .height = 4, .depth = 2 }, .mip_level_count = 2, .format = format, .usage = .{ .render_attachment = true, .texture_binding = true } });
            defer texture.destroy();
            var image = try texture.createView(.{ .base_mip_level = 1, .mip_level_count = 1, .base_array_layer = 1, .array_layer_count = 1 });
            defer image.destroy();
            var other = try texture.createView(.{ .base_mip_level = 1, .mip_level_count = 1, .base_array_layer = 0, .array_layer_count = 1 });
            defer other.destroy();
            var sampler = try device.createSampler(a, .{});
            defer sampler.destroy();
            var comparison = try device.createSampler(a, .{ .compare = .less });
            defer comparison.destroy();
            var output = try device.createBuffer(a, .{ .size = 128, .usage = .{ .storage = true, .copy_src = true } });
            defer output.destroy();
            var color = try device.createTexture(a, .{ .size = .{ .width = 4, .height = 2, .depth = 2 }, .format = .rgba8_unorm, .usage = .{ .render_attachment = true, .copy_src = true, .texture_binding = true } });
            defer color.destroy();
            var color_view = try color.createView(.{});
            defer color_view.destroy();
            var bgl = try device.createBindGroupLayout(a, .{ .entries = &.{
                .{ .binding = 0, .visibility = .{ .compute = true, .vertex = true, .fragment = true }, .ty = .{ .texture = .{ .sample_type = .depth, .view_dimension = .@"2d_array" } } },
                .{ .binding = 1, .visibility = .{ .compute = true }, .ty = .{ .sampler = .{ .ty = .non_filtering } } },
                .{ .binding = 2, .visibility = .{ .compute = true, .fragment = true }, .ty = .{ .sampler = .{ .ty = .comparison } } },
                .{ .binding = 3, .visibility = .{ .compute = true }, .ty = .{ .buffer = .{ .ty = .storage } } },
                .{ .binding = 4, .visibility = .{ .compute = true }, .ty = .{ .texture = .{ .sample_type = .depth, .view_dimension = .@"2d_array" } } },
            } });
            defer bgl.deinit();
            var layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{bgl} });
            defer layout.deinit();
            var empty = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{} });
            defer empty.deinit();
            var module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = code, .entry_points = &.{
                .{ .name = "writer", .stage = .vertex }, .{ .name = "depth", .stage = .fragment }, .{ .name = "vertex", .stage = .vertex }, .{ .name = "fragment", .stage = .fragment }, .{ .name = "compute", .stage = .compute },
            } } } });
            defer module.deinit();
            var writer = try module.getFunction("writer");
            defer writer.deinit();
            var depth = try module.getFunction("depth");
            defer depth.deinit();
            var vertex = try module.getFunction("vertex");
            defer vertex.deinit();
            var fragment = try module.getFunction("fragment");
            defer fragment.deinit();
            var compute = try module.getFunction("compute");
            defer compute.deinit();
            var write = try device.createRenderPipeline(.{ .layout = &empty, .vertex_function = &writer, .fragment_function = &depth, .targets = &.{}, .depth_stencil = .{ .format = format, .depth_write_enabled = true, .depth_compare = .always } });
            defer write.deinit();
            var draw = try device.createRenderPipeline(.{ .layout = &layout, .vertex_function = &vertex, .fragment_function = &fragment, .targets = &.{.{ .format = .rgba8_unorm }} });
            defer draw.deinit();
            var dispatch = try device.createComputePipeline(.{ .layout = &layout, .compute_function = &compute });
            defer dispatch.deinit();
            var entries = [_]d12.BindGroupEntry{ .{ .binding = 0, .texture_view = &image }, .{ .binding = 1, .sampler = &sampler }, .{ .binding = 2, .sampler = &comparison }, .{ .binding = 3, .buffer = &output, .stride = 16 }, .{ .binding = 4, .texture_view = &other } };
            var group = try device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &entries });
            defer group.deinit();
            entries[2].sampler = &sampler;
            try expectError(error.InvalidBindGroup, device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &entries }));
            entries[2].sampler = &comparison;
            entries[0].texture_view = &color_view;
            try expectError(error.InvalidBindGroup, device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &entries }));
            entries[0].texture_view = &image;
            var float_entries = [_]gpu.BindGroupLayoutEntry{ bgl.entries[0], bgl.entries[1], bgl.entries[2], bgl.entries[3], bgl.entries[4] };
            float_entries[0].ty.texture.sample_type = .float;
            var float_bgl = try device.createBindGroupLayout(a, .{ .entries = &float_entries });
            defer float_bgl.deinit();
            var float_layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{float_bgl} });
            defer float_layout.deinit();
            try expectError(error.InvalidBindGroup, device.createBindGroup(a, .{ .layout = &float_layout, .group = 0, .entries = &entries }));
            var wrong_module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = "Texture2DArray<uint> image:register(t0); RWStructuredBuffer<float4> output:register(u3); [numthreads(1,1,1)] void bad(){output[0]=image.Load(int4(0,0,0,0));}", .entry_points = &.{.{ .name = "bad", .stage = .compute }} } } });
            defer wrong_module.deinit();
            var wrong_function = try wrong_module.getFunction("bad");
            defer wrong_function.deinit();
            var wrong_pipeline = try device.createComputePipeline(.{ .layout = &layout, .compute_function = &wrong_function });
            defer wrong_pipeline.deinit();
            try expectError(error.InvalidDispatch, encoder.dispatch(&wrong_pipeline, &.{group}, 1, 1, 1));
            var sentinel = try encoder.beginRenderPass(.{ .depth_stencil_attachment = .{ .texture = &texture, .mip = 1, .layer = 0, .depth_load_op = .clear, .depth_clear_value = 0.625 } });
            defer sentinel.deinit();
            try sentinel.end();
            var first = try encoder.beginRenderPass(.{ .depth_stencil_attachment = .{ .texture = &texture, .mip = 1, .layer = 1, .depth_load_op = .clear, .depth_clear_value = 0.75 } });
            defer first.deinit();
            try first.draw(.{ .pipeline = &write, .vertex_count = 3, .scissor = .{ .width = 2, .height = 2 } });
            try first.end();
            try encoder.dispatch(&dispatch, &.{group}, 1, 1, 1);
            var second = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .texture = &color, .load_op = .clear }} });
            defer second.deinit();
            try second.draw(.{ .pipeline = &draw, .vertex_count = 3, .bind_groups = &.{group} });
            try second.end();
            try encoder.copyBufferToBuffer(&output, 0, &readback, 0, 128);
            try encoder.copyTextureToBuffer(&color, try color.fullRegion(0, 0), &readback, 512, 256);
        }
        var command = try encoder.finish();
        const gate = zenit_d12_test_gate_create(device.raw, queue.raw);
        var signaled = false;
        defer {
            if (!signaled) zenit_d12_test_gate_signal(gate);
            queue.waitIdle(5000) catch @panic("depth sampling gate teardown failed");
            zenit_d12_test_gate_release(gate);
        }
        _ = try queue.submit(&.{command});
        command.deinit();
        try expectError(error.GpuTimeout, queue.waitIdle(0));
        try expectError(error.GpuTimeout, queue.deinit(0));
        zenit_d12_test_gate_signal(gate);
        signaled = true;
        try queue.waitIdle(5000);
        const bytes = try readback.getMappedRange(0, readback.size);
        var frame: [4 * 2 * 4]u8 = undefined;
        for (0..2) |y| for (0..4) |x| {
            var value: [4]f32 = undefined;
            @memcpy(std.mem.asBytes(&value), bytes[(y * 4 + x) * 16 ..][0..16]);
            const d: f32 = if (x < 2) 0.25 else 0.75;
            const compared: f32 = if (x < 2) 0 else 1;
            for (value, [_]f32{ d, d, compared, 0.625 }) |actual, expected| if (!std.math.isFinite(actual) or @abs(actual - expected) > 0.00002) return error.IncorrectDepthSample;
            const c = bytes[512 + y * 256 + x * 4 ..][0..4];
            @memcpy(frame[(y * 4 + x) * 4 ..][0..4], c);
            const expected = [_]u8{ if (x < 2) 64 else 191, 64, if (x < 2) 0 else 255, 255 };
            for (c, expected) |actual, e| if (@abs(@as(i16, actual) - @as(i16, e)) > 1) return error.IncorrectGraphicsDepthSample;
        };
        if (format == .depth32_float) std.debug.print("DEPTH_SAMPLE_RGBA8_HEX={s}\n", .{std.fmt.bytesToHex(frame, .lower)});
        std.debug.print("PASS: production sampled depth {s}, selected mip/layer, compute Load/SampleLevel/SampleCmp, VS/PS depth reads, 32 floats/eight colors and blocked-GPU early-owner retention\n", .{@tagName(format)});
    }
}
