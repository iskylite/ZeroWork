const std = @import("std");
const d12 = @import("gpu").Backend.native;
const r = d12.renderer_resources;
const c = d12.renderer_commands;
const a = std.heap.page_allocator;
fn expectError(expected: anyerror, result: anytype) !void {
    if (result) |_| return error.ExpectedFailure else |err| if (err != expected) return err;
}
const program =
    \\float4 vertex(float2 p:TEXCOORD0):SV_Position{return float4(p,0,1);}
    \\float4 generated(uint id:SV_VertexID):SV_Position{return float4(id==0?float2(-1,-1):id==1?float2(3,-1):float2(-1,3),0,1);}
    \\float4 fragment():SV_Target{return float4(1,0,0,1);}
;
pub fn run() !void {
    var device = try d12.Device.init(true);
    defer device.destroy();
    const context = try r.Context.init(a, &device);
    defer context.deinit() catch @panic("renderer render context cleanup");
    var queue = c.Queue.init(context);
    defer queue.deinit();
    var target = try context.createTexture(a, .{ .size = .{ .width = 8, .height = 4 }, .format = .bgra8_unorm, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer target.destroy();
    var view = target.binding().createView();
    defer view.destroy();
    var staging = try context.createTexture(a, .{ .size = target.size, .format = .bgra8_unorm, .usage = .{ .copy_src = true, .copy_dst = true } });
    defer staging.destroy();
    var encoder = try c.CommandEncoder.init(&queue);
    defer encoder.deinit();
    const errors_before = c.CommandBuffer.error_count.load(.monotonic);
    const draws_before = c.RenderPass.frame_draw_call_count;
    var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .{ .r = 0, .g = 0, .b = 1, .a = 1 } }} });
    try expectError(error.PipelineNotSet, pass.drawChecked(3, 1, 0, 0));
    try expectError(error.InvalidEncoderState, encoder.beginBlitPass());
    try expectError(error.InvalidEncoderState, encoder.finish());
    {
        var layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{} });
        defer layout.deinit();
        var module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = program, .entry_points = &.{ .{ .name = "vertex", .stage = .vertex }, .{ .name = "generated", .stage = .vertex }, .{ .name = "fragment", .stage = .fragment } } } } });
        defer module.deinit();
        var vertex = try module.getFunction("vertex");
        defer vertex.deinit();
        var generated = try module.getFunction("generated");
        defer generated.deinit();
        var fragment = try module.getFunction("fragment");
        defer fragment.deinit();
        var pipeline = try device.createRenderPipeline(.{ .layout = &layout, .vertex_function = &vertex, .fragment_function = &fragment, .targets = &.{.{ .format = .bgra8_unorm }}, .vertex_buffers = &.{.{ .array_stride = 8, .attributes = &.{.{ .format = .float32x2, .offset = 0, .shader_location = 0 }} }} });
        pass.setPipeline(&pipeline);
        pipeline.deinit(); // Setter owns pipeline before draw recording.
        try expectError(error.VertexBufferNotSet, pass.drawChecked(3, 1, 0, 0));
        var buffer = try device.createBuffer(a, .{ .size = 32, .usage = .{ .map_write = true, .vertex = true } });
        const points = [_]f32{ 0, 0, -1, -1, 3, -1, -1, 3 };
        @memcpy(try buffer.getMappedRange(0, 32), std.mem.sliceAsBytes(&points));
        pass.setVertexBuffer(0, &buffer, 0);
        pass.setVertexBuffer(0, &buffer, 8); // Release replaced retain.
        buffer.destroy(); // Setter owns buffer before draw recording.
        pass.setViewport(2, 1, 4, 2, 0, 1);
        pass.setScissorRect(3, 0, 5, 4);
        pass.draw(3, 1, 0, 0);
        var no_input = try device.createRenderPipeline(.{ .layout = &layout, .vertex_function = &generated, .fragment_function = &fragment, .targets = &.{.{ .format = .bgra8_unorm }} });
        defer no_input.deinit();
        pass.setPipeline(&no_input); // Ignore previously bound unused vertex slots.
        pass.setViewport(0, 0, 8, 4, 0, 1);
        pass.setScissorRect(0, 0, 1, 4);
        try pass.drawChecked(3, 1, 0, 0);
        try pass.drawChecked(0, 1, 0, 0);
    }
    if (c.CommandBuffer.error_count.load(.monotonic) != errors_before) return error.RendererDrawFailed;
    if (c.RenderPass.frame_draw_call_count != draws_before + 2) return error.IncorrectRendererDrawCounter;
    pass.end();
    if (pass.isActive()) return error.EndedRenderStillActive;
    var blit = try encoder.beginBlitPass();
    if (pass.isActive()) return error.RenderReactivatedAsBlit;
    try expectError(error.InvalidEncoderState, pass.drawChecked(3, 1, 0, 0));
    try blit.copyTextureRegion(target.binding(), 0, 0, 8, 4, staging.binding(), 0, 0);
    blit.end();
    var command = try encoder.finish();
    defer command.deinit();
    try command.submitChecked();
    try command.waitChecked(5000);
    var bytes: [128]u8 = undefined;
    try staging.readBgra8(8, 4, &bytes, 32);
    var pixels: [128]u8 = undefined;
    for (0..4) |y| for (0..8) |x| {
        const pixel = bytes[(y * 8 + x) * 4 ..][0..4];
        const red = x == 0 or (x >= 3 and x < 6 and y >= 1 and y < 3);
        const expected: [4]u8 = if (red) .{ 0, 0, 255, 255 } else .{ 255, 0, 0, 255 };
        if (!std.mem.eql(u8, pixel, &expected)) return error.IncorrectRendererRenderPixel;
        @memcpy(pixels[(y * 8 + x) * 4 ..][0..4], &[_]u8{ pixel[2], pixel[1], pixel[0], pixel[3] });
    };
    var abandoned = try c.CommandEncoder.init(&queue);
    var abandoned_pass = try abandoned.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .load, .store_op = .store }} });
    abandoned.deinit();
    if (abandoned_pass.isActive()) return error.AbandonedRenderActive;
    try expectError(error.InvalidEncoderState, abandoned_pass.drawChecked(3, 1, 0, 0));
    std.debug.print("RENDERER_RENDER_RGBA8_HEX={s}\nPASS: renderer RenderPass -> BlitPass -> readback, 32 pixels, clear/viewport/scissor, vertex offset, pipeline switch, early setter-owner destruction and abandoned pass cleanup\n", .{std.fmt.bytesToHex(pixels, .lower)});
}
