const std = @import("std");
const d12 = @import("gpu").Backend.native;
const p = d12.renderer_pipeline;
const r = d12.renderer_resources;
const c = d12.renderer_commands;
const a = std.heap.page_allocator;
extern fn zenit_d12_test_draw_profile(c_int) void;
extern fn zenit_d12_test_check_draw_profile(*anyopaque) c_int;
extern fn zenit_d12_test_gate_create(*anyopaque, *anyopaque) *anyopaque;
extern fn zenit_d12_test_gate_signal(*anyopaque) void;
extern fn zenit_d12_test_gate_release(*anyopaque) void;
fn expectError(expected: anyerror, result: anytype) !void {
    if (result) |_| return error.ExpectedFailure else |err| if (err != expected) return err;
}
const Instance = extern struct { rect: [4]f32, color: [4]f32 };
const program =
    \\// zenit-entry: vertex vertex
    \\// zenit-entry: fragment fragment
++ "\n" ++ p.draw_info_source ++ "\n" ++
    \\struct Instance {float4 rect;float4 color;};
    \\StructuredBuffer<Instance> instances:register(t1,space0);
    \\ByteAddressBuffer raw_values:register(t2,space1);
    \\static const float2 corners[7]={float2(7,7),float2(0,0),float2(1,0),float2(0,1),float2(0,1),float2(1,0),float2(1,1)};
    \\struct V {float4 position:SV_Position;float4 color:TEXCOORD0;};
    \\V vertex(uint id:SV_VertexID,uint instance_id:SV_InstanceID){Instance i=instances[zenitInstanceIndex(instance_id)];V v;v.position=float4(i.rect.xy+corners[zenitVertexIndex(id)]*i.rect.zw,0,1);v.color=i.color;return v;}
    \\float4 fragment(V v):SV_Target{return v.color*asfloat(raw_values.Load4(0));}
;
pub fn run() !void {
    var device = try d12.Device.init(true);
    defer device.destroy();
    const context = try r.Context.init(a, &device);
    defer context.deinit() catch @panic("instance context cleanup");
    var queue = c.Queue.init(context);
    defer queue.deinit();
    var target = try context.createTexture(a, .{ .size = .{ .width = 8, .height = 4 }, .format = .bgra8_unorm, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer target.destroy();
    var view = target.binding().createView();
    defer view.destroy();
    zenit_d12_test_draw_profile(1);
    defer zenit_d12_test_draw_profile(0);
    var encoder = try c.CommandEncoder.init(&queue);
    zenit_d12_test_draw_profile(0);
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
        defer pipeline.deinit();
        const info = pipeline.bindingLayout().describe();
        if (info.groups != 2 or info.bindings.len != 2 or try pipeline.bufferStride(0, 1) != 32 or try pipeline.bufferStride(1, 2) != 0) return error.IncorrectInstanceReflection;
        pass.setPipeline(&pipeline);
        const sentinel = Instance{ .rect = .{ -1, -1, 2, 2 }, .color = .{ 0, 0, 1, 1 } };
        const values = [_]Instance{ sentinel, sentinel, .{ .rect = .{ -1, -1, 1, 2 }, .color = .{ 1, 0, 0, 1 } }, .{ .rect = .{ 0, -1, 1, 2 }, .color = .{ 0, 1, 0, 1 } }, sentinel };
        var buffer = try context.createBuffer(a, .{ .size = @sizeOf(@TypeOf(values)), .usage = .{ .vertex = true }, .mapped_at_creation = true });
        if (!buffer.usage.storage or !buffer.usage.uniform or !buffer.usage.map_write) return error.IncorrectRendererBufferPolicy;
        @memcpy(try buffer.getMappedRange(0, buffer.size), std.mem.sliceAsBytes(&values));
        pass.setVertexBuffer(1, &buffer, 4); // Invalid structured element alignment.
        try expectError(error.InvalidBindGroup, pass.drawChecked(6, 2, 1, 1));
        pass.setVertexBuffer(1, &buffer, 32);
        buffer.destroy();
        var raw = try context.createBuffer(a, .{ .size = 32, .usage = .{ .vertex = true, .map_write = true } });
        const raw_bytes = try raw.getMappedRange(0, 32);
        @memset(raw_bytes, 0);
        const factor = [_]f32{ 1, 1, 1, 1 };
        @memcpy(raw_bytes[16..32], std.mem.sliceAsBytes(&factor));
        pass.setFragmentBuffer(2, &raw, 4);
        try expectError(error.InvalidBindGroup, pass.drawChecked(6, 2, 1, 1));
        pass.setFragmentBuffer(2, &raw, 16);
        raw.destroy();
        pass.draw(6, 2, 1, 1);
        // Replacing the instance snapshot must not change the first draw.
        const inline_values = [_]Instance{ sentinel, sentinel, sentinel };
        pass.setVertexBytes(1, std.mem.sliceAsBytes(&inline_values));
        pass.setScissorRect(0, 3, 8, 1);
        try pass.drawChecked(6, 1, 1, 1);
        // Exhaust diagnostic capacity without dropping or changing any draw.
        for (0..512) |_| try pass.drawChecked(6, 1, 1, 1);
    }
    if (c.CommandBuffer.error_count.load(.monotonic) != errors_before) return error.UnexpectedInstanceDrawFailure;
    pass.end();
    var command = try encoder.finish();
    defer command.deinit();
    const gate = zenit_d12_test_gate_create(device.raw, context.queue.raw);
    var signaled = false;
    defer {
        if (!signaled) zenit_d12_test_gate_signal(gate);
        context.queue.waitIdle(5000) catch @panic("instance gate cleanup");
        zenit_d12_test_gate_release(gate);
    }
    try command.submitChecked();
    try expectError(error.GpuTimeout, command.waitChecked(0));
    zenit_d12_test_gate_signal(gate);
    signaled = true;
    try command.waitChecked(5000);
    if (zenit_d12_test_check_draw_profile(command.shared.inner.raw) != 0) return error.IncorrectDrawProfile;
    std.debug.print("PASS: 514 draws preserve pixels with 512 bounded timestamp pairs and two explicit dropped samples; owned shader labels survive pipeline release; all intervals lie within the frame\n", .{});
    var output: [128]u8 = undefined;
    try target.readBgra8(8, 4, &output, 32);
    var pixels: [128]u8 = undefined;
    for (0..4) |y| for (0..8) |x| {
        const pixel = output[(y * 8 + x) * 4 ..][0..4];
        const expected: [4]u8 = if (y == 3) .{ 255, 0, 0, 255 } else if (x < 4) .{ 0, 0, 255, 255 } else .{ 0, 255, 0, 255 };
        if (!std.mem.eql(u8, pixel, &expected)) {
            std.debug.print("instance mismatch x={d} y={d} actual={any} expected={any}\n", .{ x, y, pixel.*, expected });
            return error.IncorrectRendererInstancePixel;
        }
        @memcpy(pixels[(y * 8 + x) * 4 ..][0..4], &[_]u8{ pixel[2], pixel[1], pixel[0], pixel[3] });
    };
    std.debug.print("RENDERER_INSTANCE_RGBA8_HEX={s}\nPASS: renderer StructuredBuffer/ByteAddressBuffer, 32 instance pixels, stride32/raw, buffer and inline snapshots, SRV offsets, nonzero first vertex/instance and blocked-GPU early-owner retention\n", .{std.fmt.bytesToHex(pixels, .lower)});
}
