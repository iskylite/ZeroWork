const std = @import("std");
const d12 = @import("gpu").Backend.native;
const p = d12.renderer_pipeline;
const r = d12.renderer_resources;
const c = d12.renderer_commands;
const a = std.heap.page_allocator;
fn expectError(expected: anyerror, result: anytype) !void {
    if (result) |_| return error.ExpectedFailure else |err| if (err != expected) return err;
}
const program =
    \\// zenit-entry: vertex vertex
    \\// zenit-entry: fragment fragment
    \\float4 vertex(float2 point_position:TEXCOORD0):SV_Position{return float4(point_position,0,1);}
    \\float4 fragment():SV_Target{return float4(1,0,0,0.5);}
;
const bad_space =
    \\// zenit-entry: fragment fragment
    \\Texture2D<float4> image:register(t0,space5);
    \\float4 fragment():SV_Target{return image.Load(int3(0,0,0));}
;
const collision =
    \\// zenit-entry: fragment fragment
    \\Texture2D<float4> image:register(t0,space0);
    \\SamplerState image_sampler:register(s0,space0);
    \\float4 fragment():SV_Target{return image.SampleLevel(image_sampler,float2(0.5,0.5),0);}
;
const structured =
    \\// zenit-entry: fragment fragment
    \\RWStructuredBuffer<float4> values:register(u0,space0);
    \\float4 fragment():SV_Target{return values[0];}
;
pub fn run() !void {
    var device = try d12.Device.init(true);
    defer device.destroy();
    try expectError(error.MissingShaderManifest, p.ShaderModule.initFromSource(&device, "float4 fragment():SV_Target{return 0;}"));
    try expectError(error.InvalidShaderManifest, p.ShaderModule.initFromSource(&device, "// zenit-entry: pixel fragment\n"));
    try expectError(error.InvalidShaderManifest, p.ShaderModule.initFromSource(&device, "// zenit-entry: vertex vertex extra\n"));
    try expectError(error.DuplicateShaderEntry, p.ShaderModule.initFromSource(&device, "// zenit-entry: vertex vertex\n// zenit-entry: fragment vertex\n"));
    var module = try p.ShaderModule.initFromSource(&device, program);
    defer module.deinit();
    var vertex = try module.getFunction("vertex");
    defer vertex.deinit();
    var fragment = try module.getFunction("fragment");
    defer fragment.deinit();
    try expectError(error.InvalidShaderStage, p.createRenderPipeline(&device, .{ .vertex_function = &fragment, .fragment_function = &fragment, .color_attachment_formats = &.{.bgra8_unorm} }));
    for ([_][]const u8{ bad_space, collision, structured }, [_]anyerror{ error.UnsupportedRegisterSpace, error.ConflictingShaderBinding, error.UnsupportedShaderResource }) |source, expected| {
        var candidate = try p.ShaderModule.initFromSource(&device, source);
        defer candidate.deinit();
        var function = try candidate.getFunction("fragment");
        defer function.deinit();
        try expectError(expected, p.createRenderPipeline(&device, .{ .vertex_function = &vertex, .fragment_function = &function, .color_attachment_formats = &.{.bgra8_unorm} }));
    }
    const context = try r.Context.init(a, &device);
    defer context.deinit() catch @panic("pipeline context cleanup");
    var queue = c.Queue.init(context);
    defer queue.deinit();
    var target = try context.createTexture(a, .{ .size = .{ .width = 4, .height = 2 }, .format = .bgra8_unorm, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer target.destroy();
    var view = target.binding().createView();
    defer view.destroy();
    var pipeline = try p.createRenderPipeline(&device, .{ .vertex_function = &vertex, .fragment_function = &fragment, .color_attachment_formats = &.{.bgra8_unorm}, .blend_state = p.BlendState.ALPHA_BLENDING, .vertex_buffers = &.{.{ .stride = 8, .attributes = &.{.{ .format = .float32x2, .offset = 0, .shader_location = 0 }} }} });
    defer pipeline.deinit();
    if (pipeline.bindingLayout().describe().groups != 0 or pipeline.vertex_slots != 1) return error.IncorrectAutomaticGeometryLayout;
    var encoder = try c.CommandEncoder.init(&queue);
    defer encoder.deinit();
    var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .{ .r = 0, .g = 0, .b = 1, .a = 1 } }} });
    pass.setPipeline(&pipeline);
    const points = [_]f32{ -1, -1, 3, -1, -1, 3 };
    pass.setVertexBytes(0, std.mem.sliceAsBytes(&points));
    try pass.drawChecked(3, 1, 0, 0);
    pass.end();
    var command = try encoder.finish();
    defer command.deinit();
    try command.submitChecked();
    try command.waitChecked(5000);
    var output: [32]u8 = undefined;
    try target.readBgra8(4, 2, &output, 16);
    for (0..8) |i| {
        const pixel = output[i * 4 ..][0..4];
        if (pixel[0] < 127 or pixel[0] > 128 or pixel[1] != 0 or pixel[2] < 127 or pixel[2] > 128 or pixel[3] != 255) return error.IncorrectRendererPipelineAlpha;
    }
    std.debug.print("PASS: renderer shader manifest and reflected pipeline factory, eight alpha-blended pixels, vertex descriptor/inline geometry, empty layout, stage/manifest/space/collision/unsupported-resource guards\n", .{});
}
