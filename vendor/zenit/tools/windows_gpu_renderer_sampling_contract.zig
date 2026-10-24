const std = @import("std");
const d12 = @import("gpu").Backend.native;
const p = d12.renderer_pipeline;
const r = d12.renderer_resources;
const c = d12.renderer_commands;
const a = std.heap.page_allocator;
extern fn zenit_d12_test_gate_create(*anyopaque, *anyopaque) *anyopaque;
extern fn zenit_d12_test_gate_signal(*anyopaque) void;
extern fn zenit_d12_test_gate_release(*anyopaque) void;
fn expectError(expected: anyerror, result: anytype) !void {
    if (result) |_| return error.ExpectedFailure else |err| if (err != expected) return err;
}
const program =
    \\// zenit-entry: vertex vertex
    \\// zenit-entry: fragment fragment
    \\cbuffer Params:register(b1,space0){float4 params;}
    \\Texture2D<float4> image:register(t0,space2);
    \\SamplerState image_sampler:register(s0,space3);
    \\float4 vertex(uint id:SV_VertexID):SV_Position{return float4(id==0?float2(-1,-1):id==1?float2(3,-1):float2(-1,3),0,1);}
    \\float4 fragment(float4 p:SV_Position):SV_Target{float2 uv=params.x==0?float2((uint(p.x)%4+0.5)/4.,p.y/4.):float2(0.5,0.5);return image.SampleLevel(image_sampler,uv,0);}
;
pub fn run() !void {
    var device = try d12.Device.init(true);
    defer device.destroy();
    const context = try r.Context.init(a, &device);
    defer context.deinit() catch @panic("sampling context cleanup");
    var queue = c.Queue.init(context);
    defer queue.deinit();
    var target = try context.createTexture(a, .{ .size = .{ .width = 8, .height = 4 }, .format = .bgra8_unorm, .usage = .{ .render_attachment = true, .texture_binding = true, .copy_src = true } });
    defer target.destroy();
    var view = target.binding().createView();
    defer view.destroy();
    var first = try context.createTexture(a, .{ .size = .{ .width = 2, .height = 2 }, .format = .rgba8_unorm, .memory = .host_upload, .usage = .{ .texture_binding = true } });
    var first_live = true;
    defer if (first_live) first.destroy();
    const rgba = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255 };
    try first.writeRegion(0, 0, 0, 2, 2, &rgba, 8);
    var second = try context.createTexture(a, .{ .size = .{ .width = 2, .height = 2 }, .format = .bgra8_unorm, .memory = .host_upload, .usage = .{ .texture_binding = true } });
    var second_live = true;
    defer if (second_live) second.destroy();
    const bgra = [_]u8{ 0, 255, 255, 255, 255, 255, 0, 255, 255, 0, 255, 255, 0, 0, 0, 255 };
    try second.writeRegion(0, 0, 0, 2, 2, &bgra, 8);
    var encoder = try c.CommandEncoder.init(&queue);
    defer encoder.deinit();
    var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store }} });
    const errors_before = c.CommandBuffer.error_count.load(.monotonic);
    {
        var module = try p.ShaderModule.initFromSource(&device, program);
        defer module.deinit();
        var vertex = try module.getFunction("vertex");
        defer vertex.deinit();
        var fragment = try module.getFunction("fragment");
        defer fragment.deinit();
        var pipeline = try p.createRenderPipeline(&device, .{ .vertex_function = &vertex, .fragment_function = &fragment, .color_attachment_formats = &.{.bgra8_unorm} });
        const reflected = pipeline.bindingLayout().describe();
        if (reflected.groups != 4 or reflected.bindings.len != 3) return error.IncorrectAutomaticSamplingLayout;
        defer pipeline.deinit();
        pass.setPipeline(&pipeline);
        var mode: [4]f32 = .{ 0, 0, 0, 0 };
        pass.setFragmentBytes(1, std.mem.asBytes(&mode));
        try expectError(error.TextureNotSet, pass.drawChecked(3, 1, 0, 0));
        pass.setFragmentTexture(0, &first);
        try expectError(error.SamplerNotSet, pass.drawChecked(3, 1, 0, 0));
        try expectError(error.InvalidTextureBinding, pass.setFragmentTextureBindingChecked(32, first.binding()));
        var point_sampler = try device.createSampler(a, .{});
        pass.setFragmentSampler(0, &point_sampler);
        point_sampler.destroy();
        first.destroy();
        first_live = false;
        pass.setScissorRect(0, 0, 4, 4);
        pass.draw(3, 1, 0, 0);
        // Same slot replacement must preserve the first draw's resource tables.
        pass.setFragmentTextureBinding(0, second.binding());
        pass.setFragmentSampler(0, null);
        try expectError(error.SamplerNotSet, pass.drawChecked(3, 1, 0, 0));
        var comparison = try device.createSampler(a, .{ .compare = .less });
        pass.setFragmentSampler(0, &comparison);
        comparison.destroy();
        try expectError(error.InvalidBindGroup, pass.drawChecked(3, 1, 0, 0));
        var linear = try device.createSampler(a, .{ .min_filter = .linear, .mag_filter = .linear });
        pass.setFragmentSampler(0, &linear);
        linear.destroy();
        pass.setFragmentTextureBinding(0, target.binding());
        try expectError(error.InvalidDraw, pass.drawChecked(3, 1, 0, 0));
        pass.setFragmentTextureBinding(0, second.binding());
        second.destroy();
        second_live = false;
        mode[0] = 1;
        pass.setFragmentBytes(1, std.mem.asBytes(&mode));
        pass.setScissorRect(4, 0, 4, 4);
        try pass.drawChecked(3, 1, 0, 0);
    }
    if (c.CommandBuffer.error_count.load(.monotonic) != errors_before) return error.UnexpectedSamplingErrorCounter;
    pass.end();
    var command = try encoder.finish();
    defer command.deinit();
    const gate = zenit_d12_test_gate_create(device.raw, context.queue.raw);
    var signaled = false;
    defer {
        if (!signaled) zenit_d12_test_gate_signal(gate);
        context.queue.waitIdle(5000) catch @panic("sampling gate cleanup");
        zenit_d12_test_gate_release(gate);
    }
    try command.submitChecked();
    try expectError(error.GpuTimeout, command.waitChecked(0));
    zenit_d12_test_gate_signal(gate);
    signaled = true;
    try command.waitChecked(5000);
    var output: [128]u8 = undefined;
    try target.readBgra8(8, 4, &output, 32);
    var pixels: [128]u8 = undefined;
    for (0..4) |y| for (0..8) |x| {
        const pixel = output[(y * 8 + x) * 4 ..][0..4];
        if (x < 4) {
            const color = rgba[((y / 2) * 2 + x / 2) * 4 ..][0..4];
            const expected: [4]u8 = .{ color[2], color[1], color[0], color[3] };
            if (!std.mem.eql(u8, pixel, &expected)) return error.IncorrectPointSamplerPixel;
        } else if (pixel[0] != 128 or pixel[1] != 128 or pixel[2] != 128 or pixel[3] != 255) return error.IncorrectLinearSamplerPixel;
        @memcpy(pixels[(y * 8 + x) * 4 ..][0..4], &[_]u8{ pixel[2], pixel[1], pixel[0], pixel[3] });
    };
    std.debug.print("RENDERER_SAMPLE_RGBA8_HEX={s}\nPASS: renderer fragment texture/sampler 32 pixels, RGBA/BGRA, point/linear switching, empty group, missing/null/comparison guards, attachment feedback rejection and blocked-GPU early-owner retention\n", .{std.fmt.bytesToHex(pixels, .lower)});
}
