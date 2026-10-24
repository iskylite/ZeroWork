const std = @import("std");
const d12 = @import("gpu").Backend.native;
const a = std.heap.page_allocator;
const program =
    \\float4 vertex(uint id:SV_VertexID):SV_Position{return float4(id==0?float2(-1,-1):id==1?float2(3,-1):float2(-1,3),0,1);}
    \\float4 fragment(float4 p:SV_Position):SV_Target{return float4(p.z,1,0,1);}
;
pub fn run() !void {
    var device = try d12.Device.init(true);
    defer device.destroy();
    var queue = try device.createQueue();
    defer queue.deinit(5000) catch @panic("viewport queue cleanup");
    var encoder = try device.createCommandEncoder();
    defer encoder.deinit();
    var target = try device.createTexture(a, .{ .size = .{ .width = 8, .height = 4 }, .format = .rgba8_unorm, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer target.destroy();
    const region = try target.fullRegion(0, 0);
    const footprint = try target.copyLayout(region, 0);
    var readback = try device.createBuffer(a, .{ .size = footprint.required_bytes, .usage = .{ .map_read = true, .copy_dst = true } });
    defer readback.destroy();
    {
        var layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{} });
        defer layout.deinit();
        var module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = program, .entry_points = &.{ .{ .name = "vertex", .stage = .vertex }, .{ .name = "fragment", .stage = .fragment } } } } });
        defer module.deinit();
        var vertex = try module.getFunction("vertex");
        defer vertex.deinit();
        var fragment = try module.getFunction("fragment");
        defer fragment.deinit();
        var pipeline = try device.createRenderPipeline(.{ .layout = &layout, .vertex_function = &vertex, .fragment_function = &fragment, .targets = &.{.{ .format = .rgba8_unorm }} });
        defer pipeline.deinit();
        var indices = try device.createBuffer(a, .{ .size = 8, .usage = .{ .map_write = true, .index = true } });
        defer indices.destroy();
        const index_data = [_]u16{ 0, 1, 2, 0 };
        @memcpy(try indices.getMappedRange(0, 8), std.mem.sliceAsBytes(&index_data));
        var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .texture = &target, .load_op = .clear, .clear_value = .{ 0, 0, 1, 1 } }} });
        defer pass.deinit();
        const invalid = [_]d12.Viewport{
            .{ .width = -1, .height = 4 },                                      .{ .width = 4, .height = -1 },
            .{ .x = -32769, .width = 4, .height = 4 },                          .{ .x = 32766, .width = 4, .height = 4 },
            .{ .width = 4, .height = 4, .min_depth = -0.1 },                    .{ .width = 4, .height = 4, .max_depth = 1.1 },
            .{ .width = 4, .height = 4, .min_depth = 0.75, .max_depth = 0.25 }, .{ .x = std.math.nan(f32), .width = 4, .height = 4 },
            .{ .width = std.math.inf(f32), .height = 4 },                       .{ .width = 4, .height = 4, .min_depth = std.math.nan(f32) },
        };
        for (invalid) |v| {
            if (pass.draw(.{ .pipeline = &pipeline, .vertex_count = 3, .viewport = v })) |_| return error.AcceptedInvalidViewport else |err| if (err != error.InvalidDraw) return err;
        }
        try pass.draw(.{ .pipeline = &pipeline, .vertex_count = 3, .viewport = .{ .x = 2, .y = 1, .width = 4, .height = 2, .min_depth = 0.25, .max_depth = 0.75 } });
        // Null must reset a preceding custom viewport, also through indexed recording.
        try pass.drawIndexed(.{ .pipeline = &pipeline, .index_buffer = .{ .buffer = &indices, .format = .uint16 }, .index_count = 3, .scissor = .{ .width = 1, .height = 4 } });
        try pass.drawIndexed(.{ .pipeline = &pipeline, .index_buffer = .{ .buffer = &indices, .format = .uint16 }, .index_count = 3, .viewport = .{ .x = -2, .width = 4, .height = 4, .min_depth = 0.75, .max_depth = 0.75 }, .scissor = .{ .x = 1, .width = 1, .height = 4 } });
        try pass.draw(.{ .pipeline = &pipeline, .vertex_count = 3, .viewport = .{ .x = 6.25, .y = 0.25, .width = 1, .height = 3, .min_depth = 0.5 } });
        try pass.draw(.{ .pipeline = &pipeline, .vertex_count = 3, .viewport = .{ .width = 0, .height = 4 } });
        try pass.end();
    }
    try encoder.copyTextureToBuffer(&target, region, &readback, 0, footprint.row_pitch);
    var command = try encoder.finish();
    _ = try queue.submit(&.{command});
    command.deinit();
    try queue.waitIdle(5000);
    const bytes = try readback.getMappedRange(0, readback.size);
    var pixels: [128]u8 = undefined;
    for (0..4) |y| for (0..8) |x| {
        const pixel = bytes[y * footprint.row_pitch + x * 4 ..][0..4];
        @memcpy(pixels[(y * 8 + x) * 4 ..][0..4], pixel);
        const red: ?u8 = if (x == 0) 0 else if (x == 1) 191 else if (x >= 2 and x < 6 and y >= 1 and y < 3) 64 else if (x == 6 and y < 3) 128 else null;
        if (red) |r| {
            if (pixel[0] != r or pixel[1] != 255 or pixel[2] != 0 or pixel[3] != 255) return error.IncorrectViewportPixel;
        } else if (!std.mem.eql(u8, pixel, &.{ 0, 0, 255, 255 })) return error.IncorrectViewportBackground;
    };
    std.debug.print("VIEWPORT_RGBA8_HEX={s}\nPASS: 32 viewport pixels, negative/fractional origins, scissor intersection, depth mapping, indexed/default reset, zero extent, 10 invalid descriptors\n", .{std.fmt.bytesToHex(pixels, .lower)});
}
