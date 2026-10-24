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
    \\// zenit-entry: vertex shared_vertex
    \\// zenit-entry: fragment shared_fragment
    \\cbuffer VSData:register(b2,space0){float4 vs_color;}
    \\cbuffer PSData:register(b2,space1){float4 ps_color;}
    \\cbuffer Shared:register(b3,space2){float4 shared_color;}
    \\struct V {float4 position:SV_Position;float4 color:TEXCOORD0;};
    \\float4 make_position(uint id){return float4(id==0?float2(-1,-1):id==1?float2(3,-1):float2(-1,3),0,1);}
    \\V vertex(uint id:SV_VertexID){V v;v.position=make_position(id);v.color=vs_color;return v;}
    \\float4 fragment(V v):SV_Target{return v.color*ps_color;}
    \\V shared_vertex(uint id:SV_VertexID){V v;v.position=make_position(id);v.color=shared_color;return v;}
    \\float4 shared_fragment(V v):SV_Target{return v.color*shared_color;}
;
pub fn run() !void {
    var device = try d12.Device.init(true);
    defer device.destroy();
    const context = try r.Context.init(a, &device);
    defer context.deinit() catch @panic("uniform context cleanup");
    var queue = c.Queue.init(context);
    defer queue.deinit();
    var target = try context.createTexture(a, .{ .size = .{ .width = 8, .height = 4 }, .format = .bgra8_unorm, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer target.destroy();
    var view = target.binding().createView();
    defer view.destroy();
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
        var shared_vertex = try module.getFunction("shared_vertex");
        defer shared_vertex.deinit();
        var shared_fragment = try module.getFunction("shared_fragment");
        defer shared_fragment.deinit();
        var pipeline = try p.createRenderPipeline(&device, .{ .vertex_function = &vertex, .fragment_function = &fragment, .color_attachment_formats = &.{.bgra8_unorm} });
        defer pipeline.deinit();
        pass.setPipeline(&pipeline);
        try expectError(error.UniformNotSet, pass.drawChecked(3, 1, 0, 0));
        var tint: [4]f32 = .{ 1, 0, 0, 1 };
        var factor: [4]f32 = .{ 1, 1, 1, 1 };
        pass.setVertexBytes(2, std.mem.asBytes(&tint));
        pass.setFragmentBytes(2, std.mem.asBytes(&factor));
        tint = .{ 0, 0, 1, 1 };
        factor = .{ 0, 0, 0, 0 }; // Source memory is no longer borrowed.
        pass.setScissorRect(0, 0, 4, 4);
        pass.draw(3, 1, 0, 0);
        tint = .{ 0, 1, 0, 1 };
        factor = .{ 0.5, 0.5, 0.5, 1 };
        try pass.setVertexBytesChecked(2, std.mem.asBytes(&tint));
        try pass.setFragmentBytesChecked(2, std.mem.asBytes(&factor));
        const too_large: [4097]u8 = @splat(0);
        try expectError(error.InvalidUniformData, pass.setVertexBytesChecked(2, &too_large));
        try expectError(error.InvalidUniformData, pass.setFragmentBytesChecked(32, std.mem.asBytes(&factor)));
        try expectError(error.InvalidUniformData, pass.setFragmentBytesChecked(2, &.{}));
        pass.setScissorRect(4, 0, 4, 4);
        try pass.drawChecked(3, 1, 0, 0);
        var shared_pipeline = try p.createRenderPipeline(&device, .{ .vertex_function = &shared_vertex, .fragment_function = &shared_fragment, .color_attachment_formats = &.{.bgra8_unorm} });
        const shared_info = shared_pipeline.bindingLayout().describe();
        if (shared_info.groups != 3 or shared_info.bindings.len != 1 or shared_info.bindings[0].visibility != 3 or shared_info.bindings[0].min_size != 16) return error.IncorrectMergedUniformLayout;
        defer shared_pipeline.deinit();
        pass.setPipeline(&shared_pipeline);
        tint = .{ 0, 0, 1, 1 };
        try pass.setVertexBytesChecked(3, std.mem.asBytes(&tint));
        try pass.setFragmentBytesChecked(3, std.mem.asBytes(&factor));
        try expectError(error.SharedUniformMismatch, pass.drawChecked(3, 1, 0, 0));
        try pass.setFragmentBytesChecked(3, std.mem.asBytes(&tint));
        pass.setScissorRect(0, 0, 8, 1);
        try pass.drawChecked(3, 1, 0, 0);
        pass.setPipeline(&pipeline);
        var buffer = try device.createBuffer(a, .{ .size = 98304, .usage = .{ .map_write = true, .uniform = true } });
        const mapped = try buffer.getMappedRange(0, 98304);
        @memset(mapped, 0);
        tint = .{ 1, 1, 0, 1 };
        factor = .{ 0.25, 0, 1, 1 };
        @memcpy(mapped[256..272], std.mem.asBytes(&tint));
        @memcpy(mapped[512..528], std.mem.asBytes(&factor));
        pass.setVertexBuffer(2, &buffer, 256);
        pass.setFragmentBuffer(2, &buffer, 512);
        buffer.destroy();
        pass.setScissorRect(0, 3, 8, 1);
        try pass.drawChecked(3, 1, 0, 0);
    }
    if (c.CommandBuffer.error_count.load(.monotonic) != errors_before) return error.UnexpectedUniformErrorCounter;
    pass.end(); // Caller pipeline/layout/function/module and setter owners are gone.
    var command = try encoder.finish();
    defer command.deinit();
    const gate = zenit_d12_test_gate_create(device.raw, context.queue.raw);
    var signaled = false;
    defer {
        if (!signaled) zenit_d12_test_gate_signal(gate);
        context.queue.waitIdle(5000) catch @panic("uniform gate cleanup");
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
        const expected: [4]u8 = if (y == 0) .{ 255, 0, 0, 255 } else if (y == 3) .{ 0, 0, 64, 255 } else if (x < 4) .{ 0, 0, 255, 255 } else .{ 0, 128, 0, 255 };
        if (!std.mem.eql(u8, pixel, &expected)) return error.IncorrectRendererUniformPixel;
        @memcpy(pixels[(y * 8 + x) * 4 ..][0..4], &[_]u8{ pixel[2], pixel[1], pixel[0], pixel[3] });
    };
    std.debug.print("RENDERER_UNIFORM_RGBA8_HEX={s}\nPASS: renderer stage uniforms 32 pixels, same slot different register spaces, immutable byte snapshots, shared VS/PS CBV equality, aligned buffer offsets, empty groups and blocked-GPU early-owner retention\n", .{std.fmt.bytesToHex(pixels, .lower)});
}
