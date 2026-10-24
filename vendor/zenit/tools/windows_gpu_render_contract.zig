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
const program =
    \\struct V {float4 p:SV_Position;float4 color:TEXCOORD0;};
    \\V generated(uint id:SV_VertexID){V v;v.p=float4(id==0?float2(-1,-1):id==1?float2(3,-1):float2(-1,3),0,1);v.color=float4(1,0,0,0.5);return v;}
    \\V input_vertex(float2 p:TEXCOORD0,float4 color:TEXCOORD1){V v;v.p=float4(p,0,1);v.color=color;return v;}
    \\float4 fragment(V v):SV_Target{return v.color;}
    \\float4 green():SV_Target{return float4(0,1,0,1);}
    \\struct T {float4 color:SV_Target0;uint number:SV_Target1;};
    \\T multiple(){T t;t.color=float4(0,1,1,1);t.number=0xee112233u;return t;}
;
fn render() !void {
    var device = try d12.Device.init(true);
    var device_live = true;
    defer if (device_live) device.destroy();
    var queue = try device.createQueue();
    defer queue.deinit(5000) catch @panic("render queue teardown failed");
    var encoder = try device.createCommandEncoder();
    defer encoder.deinit();
    var texture = try device.createTexture(a, .{ .size = .{ .width = 8, .height = 6 }, .format = .rgba8_unorm, .usage = .{ .render_attachment = true, .copy_src = true } });
    var texture_live = true;
    defer if (texture_live) texture.destroy();
    const region = try texture.fullRegion(0, 0);
    const footprint = try texture.copyLayout(region, 512);
    var readback = try device.createBuffer(a, .{ .size = footprint.required_bytes, .usage = .{ .map_read = true, .copy_dst = true } });
    defer readback.destroy();
    {
        var layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{} });
        defer layout.deinit();
        var module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = program, .entry_points = &.{
            .{ .name = "generated", .stage = .vertex }, .{ .name = "input_vertex", .stage = .vertex }, .{ .name = "fragment", .stage = .fragment }, .{ .name = "green", .stage = .fragment },
        } } } });
        defer module.deinit();
        var vertex = try module.getFunction("generated");
        defer vertex.deinit();
        var input = try module.getFunction("input_vertex");
        defer input.deinit();
        var fragment = try module.getFunction("fragment");
        defer fragment.deinit();
        var green = try module.getFunction("green");
        defer green.deinit();
        var blended = try device.createRenderPipeline(.{ .layout = &layout, .vertex_function = &vertex, .fragment_function = &fragment, .targets = &.{.{ .format = .rgba8_unorm, .blend = gpu.BlendState.ALPHA_BLENDING }} });
        defer blended.deinit();
        var masked = try device.createRenderPipeline(.{ .layout = &layout, .vertex_function = &vertex, .fragment_function = &green, .targets = &.{.{ .format = .rgba8_unorm, .write_mask = .{ .green = true } }} });
        defer masked.deinit();
        var with_input = try device.createRenderPipeline(.{ .layout = &layout, .vertex_function = &input, .fragment_function = &fragment, .targets = &.{.{ .format = .rgba8_unorm }}, .vertex_buffers = &.{
            .{ .array_stride = 8, .attributes = &.{.{ .format = .float32x2, .offset = 0, .shader_location = 0 }} },
            .{ .array_stride = 4, .attributes = &.{} },
            .{ .array_stride = 4, .step_mode = .instance, .attributes = &.{.{ .format = .unorm8x4, .offset = 0, .shader_location = 1 }} },
        } });
        defer with_input.deinit();
        var upload = try device.createBuffer(a, .{ .size = 72, .usage = .{ .map_write = true, .copy_src = true } });
        defer upload.destroy();
        const bytes = try upload.getMappedRange(0, 72);
        @memset(bytes, 0);
        const points = [_]f32{ -1, -1, 3, -1, -1, 3 };
        @memcpy(bytes[24..48], std.mem.sliceAsBytes(&points));
        @memcpy(bytes[68..72], &[_]u8{ 0, 255, 0, 255 });
        var buffer = try device.createBuffer(a, .{ .size = 72, .usage = .{ .vertex = true, .copy_dst = true } });
        defer buffer.destroy();
        try encoder.copyBufferToBuffer(&upload, 0, &buffer, 0, 72);
        try expectError(error.InvalidRenderPass, encoder.beginRenderPass(.{ .color_attachments = &.{.{ .texture = &texture, .clear_value = .{ std.math.nan(f32), 0, 0, 0 } }} }));
        var wrong_format = try device.createRenderPipeline(.{ .layout = &layout, .vertex_function = &vertex, .fragment_function = &fragment, .targets = &.{.{ .format = .bgra8_unorm }} });
        defer wrong_format.deinit();
        var foreign = try d12.Device.init(true);
        defer foreign.destroy();
        var foreign_layout = try foreign.createPipelineLayout(a, .{ .bind_group_layouts = &.{} });
        defer foreign_layout.deinit();
        var foreign_pipeline = try foreign.createRenderPipeline(.{ .layout = &foreign_layout, .vertex_function = &vertex, .fragment_function = &fragment, .targets = &.{.{ .format = .rgba8_unorm }} });
        defer foreign_pipeline.deinit();
        var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .texture = &texture, .load_op = .clear, .clear_value = .{ 0, 0, 1, 1 } }} });
        defer pass.deinit();
        try expectError(error.InvalidEncoderState, encoder.finish());
        try expectError(error.InvalidRenderPass, encoder.beginRenderPass(.{ .color_attachments = &.{.{ .texture = &texture }} }));
        try expectError(error.InvalidTextureCopy, encoder.copyTextureToBuffer(&texture, region, &readback, 512, footprint.row_pitch));
        try expectError(error.InvalidDraw, pass.draw(.{ .pipeline = &blended, .vertex_count = 3, .scissor = .{ .width = 9, .height = 6 } }));
        try expectError(error.InvalidDraw, pass.draw(.{ .pipeline = &wrong_format, .vertex_count = 3 }));
        try expectError(error.InvalidDraw, pass.draw(.{ .pipeline = &foreign_pipeline, .vertex_count = 3 }));
        try expectError(error.InvalidDraw, pass.draw(.{ .pipeline = &blended, .vertex_count = 3, .blend_constant = .{ std.math.nan(f32), 0, 0, 0 } }));
        try pass.draw(.{ .pipeline = &blended, .vertex_count = 3, .scissor = .{ .x = 2, .y = 1, .width = 4, .height = 3 } });
        try pass.draw(.{ .pipeline = &blended, .vertex_count = 0 });
        try pass.end();
        try expectError(error.RenderPassAlreadyEnded, pass.end());
        try expectError(error.RenderPassAlreadyEnded, pass.draw(.{ .pipeline = &blended, .vertex_count = 3 }));
        var second = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .texture = &texture }} });
        defer second.deinit();
        try second.draw(.{ .pipeline = &masked, .vertex_count = 3, .scissor = .{ .width = 2, .height = 2 } });
        const bindings = [_]d12.VertexBinding{ .{ .buffer = &buffer, .slot = 2, .offset = 64, .size = 8 }, .{ .buffer = &buffer, .slot = 0, .offset = 16, .size = 32 } };
        try expectError(error.InvalidDraw, second.draw(.{ .pipeline = &with_input, .vertex_count = 3 }));
        try expectError(error.InvalidDraw, second.draw(.{ .pipeline = &with_input, .vertex_count = 4, .first_vertex = 1, .first_instance = 1, .vertex_buffers = &bindings }));
        try expectError(error.InvalidDraw, second.draw(.{ .pipeline = &with_input, .vertex_count = 3, .first_vertex = 1, .first_instance = 2, .vertex_buffers = &bindings }));
        try second.draw(.{ .pipeline = &with_input, .vertex_count = 3, .first_vertex = 1, .first_instance = 1, .vertex_buffers = &bindings, .scissor = .{ .x = 4, .y = 2, .width = 3, .height = 3 } });
        try second.end();
    }
    try encoder.copyTextureToBuffer(&texture, region, &readback, 512, footprint.row_pitch);
    texture.destroy();
    texture_live = false;
    var command = try encoder.finish();
    const gate = zenit_d12_test_gate_create(device.raw, queue.raw);
    var signaled = false;
    defer {
        if (!signaled) zenit_d12_test_gate_signal(gate);
        queue.waitIdle(5000) catch @panic("render gate teardown failed");
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
    const bytes = try readback.getMappedRange(0, readback.size);
    var pixels: [8 * 6 * 4]u8 = undefined;
    for (0..6) |y| for (0..8) |x| {
        const pixel = bytes[512 + y * footprint.row_pitch + x * 4 ..][0..4];
        @memcpy(pixels[(y * 8 + x) * 4 ..][0..4], pixel);
        if (x >= 4 and x < 7 and y >= 2 and y < 5) {
            if (!std.mem.eql(u8, pixel, &.{ 0, 255, 0, 255 })) return error.IncorrectInstanceVertexDraw;
        } else if (x >= 2 and x < 6 and y >= 1 and y < 4) {
            if (pixel[0] < 127 or pixel[0] > 128 or pixel[1] != 0 or pixel[2] < 127 or pixel[2] > 128 or pixel[3] != 255) return error.IncorrectAlphaBlendPixel;
        } else if (x < 2 and y < 2) {
            if (!std.mem.eql(u8, pixel, &.{ 0, 255, 255, 255 })) return error.IncorrectColorMaskPixel;
        } else if (!std.mem.eql(u8, pixel, &.{ 0, 0, 255, 255 })) return error.IncorrectClearOrLoadPixel;
    };
    std.debug.print("OFFSCREEN_RGBA8_HEX={s}\n", .{std.fmt.bytesToHex(pixels, .lower)});
    std.debug.print("PASS: production RenderPass/DrawInstanced, 48 RGBA pixels, clear/load/scissor/blend/mask, default vertex upload, sparse/shared slots, first vertex/instance, owner destruction and GPU-blocked timeout retry\n", .{});
}
fn mrt() !void {
    var device = try d12.Device.init(true);
    defer device.destroy();
    var queue = try device.createQueue();
    defer queue.deinit(5000) catch @panic("MRT queue teardown failed");
    var encoder = try device.createCommandEncoder();
    defer encoder.deinit();
    var t0 = try device.createTexture(a, .{ .size = .{ .width = 8, .height = 6, .depth = 2 }, .mip_level_count = 2, .format = .rgba8_unorm, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer t0.destroy();
    var t1 = try device.createTexture(a, .{ .size = .{ .width = 8, .height = 6, .depth = 2 }, .mip_level_count = 2, .format = .r32_uint, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer t1.destroy();
    var layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{} });
    defer layout.deinit();
    var module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = program, .entry_points = &.{ .{ .name = "generated", .stage = .vertex }, .{ .name = "multiple", .stage = .fragment } } } } });
    defer module.deinit();
    var vertex = try module.getFunction("generated");
    defer vertex.deinit();
    var fragment = try module.getFunction("multiple");
    defer fragment.deinit();
    var pipeline = try device.createRenderPipeline(.{ .layout = &layout, .vertex_function = &vertex, .fragment_function = &fragment, .targets = &.{ .{ .format = .rgba8_unorm }, .{ .format = .r32_uint } } });
    defer pipeline.deinit();
    try expectError(error.InvalidRenderPass, encoder.beginRenderPass(.{ .color_attachments = &.{ .{ .texture = &t0 }, .{ .texture = &t0 } } }));
    try expectError(error.InvalidRenderPass, encoder.beginRenderPass(.{ .color_attachments = &.{ .{ .texture = &t0 }, .{ .texture = &t1, .mip = 1 } } }));
    var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{ .{ .texture = &t0, .mip = 1, .layer = 1, .load_op = .clear, .clear_value = .{ 0, 0, 0, 1 } }, .{ .texture = &t1, .mip = 1, .layer = 1, .load_op = .clear } } });
    defer pass.deinit();
    try pass.draw(.{ .pipeline = &pipeline, .vertex_count = 3, .scissor = .{ .x = 1, .width = 2, .height = 2 } });
    try pass.end();
    const region = try t0.fullRegion(1, 1);
    const footprint = try t0.copyLayout(region, 0);
    var r0 = try device.createBuffer(a, .{ .size = footprint.required_bytes, .usage = .{ .map_read = true, .copy_dst = true } });
    defer r0.destroy();
    var r1 = try device.createBuffer(a, .{ .size = footprint.required_bytes, .usage = .{ .map_read = true, .copy_dst = true } });
    defer r1.destroy();
    try encoder.copyTextureToBuffer(&t0, region, &r0, 0, footprint.row_pitch);
    try encoder.copyTextureToBuffer(&t1, region, &r1, 0, footprint.row_pitch);
    // Discard contents are undefined; only validate execution/lifecycle, while
    // the already-recorded readback above preserves the asserted pixel evidence.
    var discarded = try encoder.beginRenderPass(.{ .color_attachments = &.{
        .{ .texture = &t0, .mip = 1, .layer = 1, .load_op = .dont_care, .store_op = .discard },
        .{ .texture = &t1, .mip = 1, .layer = 1, .load_op = .dont_care, .store_op = .discard },
    } });
    defer discarded.deinit();
    try discarded.draw(.{ .pipeline = &pipeline, .vertex_count = 3 });
    try discarded.end();
    var command = try encoder.finish();
    defer command.deinit();
    _ = try queue.submit(&.{command});
    try queue.waitIdle(5000);
    const b0 = try r0.getMappedRange(0, r0.size);
    const b1 = try r1.getMappedRange(0, r1.size);
    for (0..3) |y| for (0..4) |x| {
        const inside = x >= 1 and x < 3 and y < 2;
        const offset = y * footprint.row_pitch + x * 4;
        var c0: u32 = undefined;
        var c1: u32 = undefined;
        @memcpy(std.mem.asBytes(&c0), b0[offset..][0..4]);
        @memcpy(std.mem.asBytes(&c1), b1[offset..][0..4]);
        if (c0 != (if (inside) @as(u32, 0xffffff00) else 0xff000000) or c1 != (if (inside) @as(u32, 0xee112233) else 0)) return error.IncorrectMRTDraw;
    };
    std.debug.print("PASS: production float/uint MRT rasterization, array layer1/mip1 RTVs, 24 color/integer pixels checked\n", .{});
}
fn abandonedEncoder() !void {
    var device = try d12.Device.init(true);
    defer device.destroy();
    var texture = try device.createTexture(a, .{ .size = .{ .width = 2, .height = 2 }, .format = .rgba8_unorm, .usage = .{ .render_attachment = true } });
    var encoder = try device.createCommandEncoder();
    var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .texture = &texture, .load_op = .clear }} });
    defer pass.deinit();
    encoder.deinit();
    texture.destroy();
    try pass.end();
    std.debug.print("PASS: open render pass safely retains abandoned encoder/attachment until end\n", .{});
}
fn indexed() !void {
    var device = try d12.Device.init(true);
    defer device.destroy();
    var queue = try device.createQueue();
    defer queue.deinit(5000) catch @panic("indexed queue teardown failed");
    var module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = program, .entry_points = &.{ .{ .name = "input_vertex", .stage = .vertex }, .{ .name = "fragment", .stage = .fragment } } } } });
    defer module.deinit();
    var vertex = try module.getFunction("input_vertex");
    defer vertex.deinit();
    var fragment = try module.getFunction("fragment");
    defer fragment.deinit();
    var layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{} });
    defer layout.deinit();
    var foreign = try d12.Device.init(true);
    defer foreign.destroy();
    var foreign_index = try foreign.createBuffer(a, .{ .size = 32, .usage = .{ .index = true, .map_write = true } });
    defer foreign_index.destroy();
    for ([_]gpu.IndexFormat{ .uint16, .uint32 }) |format| {
        for ([_]bool{ false, true }) |strip| {
            for ([_]i32{ 1, -1 }) |base| {
                var encoder = try device.createCommandEncoder();
                defer encoder.deinit();
                var texture = try device.createTexture(a, .{ .size = .{ .width = 8, .height = 4 }, .format = .rgba8_unorm, .usage = .{ .render_attachment = true, .copy_src = true } });
                defer texture.destroy();
                const region = try texture.fullRegion(0, 0);
                const footprint = try texture.copyLayout(region, 0);
                var readback = try device.createBuffer(a, .{ .size = footprint.required_bytes, .usage = .{ .map_read = true, .copy_dst = true } });
                defer readback.destroy();
                {
                    var upload = try device.createBuffer(a, .{ .size = 160, .usage = .{ .map_write = true, .copy_src = true } });
                    defer upload.destroy();
                    const bytes = try upload.getMappedRange(0, 160);
                    @memset(bytes, 0);
                    const points = [_]f32{ 0, 0, -1, -1, 3, -1, -1, 3 };
                    const split_points = [_]f32{ 0, 0, -1, -1, -0.5, -1, -1, 1, 0.5, -1, 1, -1, 1, 1 };
                    if (strip) @memcpy(bytes[16..72], std.mem.sliceAsBytes(&split_points)) else @memcpy(bytes[16..48], std.mem.sliceAsBytes(&points));
                    @memcpy(bytes[148..152], &[_]u8{ 0, 255, 0, 255 });
                    const shift: u32 = if (base == 1) 0 else 2;
                    const cut: u32 = if (format == .uint16) 0xffff else 0xffffffff;
                    const indices = [_]u32{ 999, shift, shift + 1, shift + 2, cut, shift + 3, shift + 4, shift + 5 };
                    const element: u64 = if (format == .uint16) 2 else 4;
                    for (indices, 0..) |v, i| {
                        if (format == .uint16) std.mem.writeInt(u16, bytes[96 + i * 2 ..][0..2], @intCast(v), .little) else std.mem.writeInt(u32, bytes[96 + i * 4 ..][0..4], v, .little);
                    }
                    var buffer = try device.createBuffer(a, .{ .size = 160, .usage = .{ .vertex = true, .index = true, .copy_dst = true } });
                    defer buffer.destroy();
                    try encoder.copyBufferToBuffer(&upload, 0, &buffer, 0, 160);
                    const mapped_index = format == .uint16 and !strip;
                    var separate_index = try device.createBuffer(a, .{ .size = 32, .usage = .{ .index = true, .map_write = mapped_index, .copy_dst = !mapped_index } });
                    defer separate_index.destroy();
                    if (mapped_index) @memcpy(try separate_index.getMappedRange(0, 32), bytes[96..128]) else try encoder.copyBufferToBuffer(&upload, 96, &separate_index, 0, 32);
                    var pipeline = try device.createRenderPipeline(.{ .layout = &layout, .vertex_function = &vertex, .fragment_function = &fragment, .targets = &.{.{ .format = .rgba8_unorm }}, .primitive = .{ .topology = if (strip) .triangle_strip else .triangle_list, .strip_index_format = if (strip) format else null }, .vertex_buffers = &.{
                        .{ .array_stride = 8, .attributes = &.{.{ .format = .float32x2, .offset = 0, .shader_location = 0 }} },
                        .{ .array_stride = 4, .step_mode = .instance, .attributes = &.{.{ .format = .unorm8x4, .offset = 0, .shader_location = 1 }} },
                    } });
                    defer pipeline.deinit();
                    var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .texture = &texture, .load_op = .clear, .clear_value = .{ 1, 0, 0, 1 } }} });
                    defer pass.deinit();
                    const bindings = [_]d12.VertexBinding{ .{ .buffer = &buffer, .slot = 0, .offset = 16, .size = 64 }, .{ .buffer = &buffer, .slot = 1, .offset = 144, .size = 8 } };
                    var draw = d12.IndexedDrawDescriptor{ .pipeline = &pipeline, .vertex_buffers = &bindings, .index_buffer = .{ .buffer = if (base == 1) &separate_index else &buffer, .format = format, .offset = if (base == 1) 0 else 96, .size = 8 * element }, .index_count = if (strip) 7 else 3, .first_index = 1, .base_vertex = base, .first_instance = 1 };
                    var bad = draw;
                    bad.index_buffer.offset += 1;
                    try expectError(error.InvalidDraw, pass.drawIndexed(bad));
                    bad = draw;
                    bad.first_index = 8;
                    try expectError(error.InvalidDraw, pass.drawIndexed(bad));
                    bad = draw;
                    bad.first_instance = 2;
                    try expectError(error.InvalidDraw, pass.drawIndexed(bad));
                    bad = draw;
                    bad.index_buffer.buffer = &readback;
                    try expectError(error.InvalidDraw, pass.drawIndexed(bad));
                    bad = draw;
                    bad.index_buffer.buffer = &foreign_index;
                    bad.index_buffer.offset = 0;
                    try expectError(error.InvalidDraw, pass.drawIndexed(bad));
                    bad = draw;
                    bad.index_buffer.size = 1;
                    try expectError(error.InvalidDraw, pass.drawIndexed(bad));
                    if (strip) {
                        bad = draw;
                        bad.index_buffer.format = if (format == .uint16) .uint32 else .uint16;
                        try expectError(error.InvalidDraw, pass.drawIndexed(bad));
                    }
                    try pass.drawIndexed(draw);
                    draw.index_count = 0;
                    try pass.drawIndexed(draw);
                    try pass.end();
                    try expectError(error.RenderPassAlreadyEnded, pass.drawIndexed(draw));
                }
                try encoder.copyTextureToBuffer(&texture, region, &readback, 0, footprint.row_pitch);
                var command = try encoder.finish();
                const gate = zenit_d12_test_gate_create(device.raw, queue.raw);
                var signaled = false;
                defer {
                    if (!signaled) zenit_d12_test_gate_signal(gate);
                    queue.waitIdle(5000) catch @panic("indexed gate teardown failed");
                    zenit_d12_test_gate_release(gate);
                }
                _ = try queue.submit(&.{command});
                command.deinit();
                try expectError(error.GpuTimeout, queue.waitIdle(0));
                zenit_d12_test_gate_signal(gate);
                signaled = true;
                try queue.waitIdle(5000);
                const pixels = try readback.getMappedRange(0, readback.size);
                for (0..4) |y| for (0..8) |x| {
                    const green = !strip or ((x == 0 or x == 7) and y >= 1) or ((x == 1 or x == 6) and y == 3);
                    const expected: [4]u8 = if (green) .{ 0, 255, 0, 255 } else .{ 255, 0, 0, 255 };
                    if (!std.mem.eql(u8, pixels[y * footprint.row_pitch + x * 4 ..][0..4], &expected)) return error.IncorrectIndexedPixel;
                };
                std.debug.print("PASS: production indexed {s} strip={} base={d}, shared={} upload-index={}, first index/instance, 32 pixels (strip gap rejects bridging) and blocked-GPU owner retention\n", .{ @tagName(format), strip, base, base == -1, base == 1 and format == .uint16 and !strip });
            }
        }
    }
}
pub fn run() !void {
    try @import("windows_gpu_viewport_contract.zig").run();
    try render();
    try mrt();
    try abandonedEncoder();
    try indexed();
    try @import("windows_gpu_graphics_binding_contract.zig").run();
    try @import("windows_gpu_depth_contract.zig").run();
    try @import("windows_gpu_msaa_contract.zig").run();
    try @import("windows_gpu_depth_sampling_contract.zig").run();
}
