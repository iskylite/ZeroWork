const std = @import("std");
const gpu = @import("gpu");
const d12 = @import("gpu").Backend.native;
const a = std.heap.page_allocator;
extern fn zenit_d12_test_render_pipeline_owned(*anyopaque) c_int;
var pipelines_created: usize = 0;
fn expectError(expected: anyerror, result: anytype) !void {
    if (result) |_| return error.ExpectedFailure else |actual| if (actual != expected) return actual;
}
const source =
    \\struct V {float4 p:SV_Position;float2 uv:TEXCOORD0;};
    \\V vertex(float2 p:TEXCOORD0){V v;v.p=float4(p,0,1);v.uv=p;return v;}
    \\V generated(uint id:SV_VertexID){V v;v.p=float4(id,0,0,1);v.uv=float2(0,0);return v;}
    \\float4 fragment(V v):SV_Target{return float4(v.uv,0,1);}
    \\float4 missing(float2 uv:TEXCOORD1):SV_Target{return float4(uv,0,1);}
    \\struct T {float4 a:SV_Target0;uint b:SV_Target1;};
    \\T multiple(){T t;t.a=float4(1,0,0,1);t.b=19;return t;}
    \\uint unsigned_fragment():SV_Target{return 4000000000u;}
    \\int signed_fragment():SV_Target{return -17;}
    \\[numthreads(1,1,1)] void compute_main(){}
;
fn basicsAndRejections() !void {
    var device = try d12.Device.init(true);
    var device_live = true;
    defer if (device_live) device.destroy();
    var layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{} });
    var layout_live = true;
    defer if (layout_live) layout.deinit();
    var module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = source, .entry_points = &.{
        .{ .name = "vertex", .stage = .vertex },              .{ .name = "generated", .stage = .vertex },
        .{ .name = "fragment", .stage = .fragment },          .{ .name = "missing", .stage = .fragment },
        .{ .name = "unsigned_fragment", .stage = .fragment }, .{ .name = "signed_fragment", .stage = .fragment },
        .{ .name = "compute_main", .stage = .compute },       .{ .name = "multiple", .stage = .fragment },
    } } } });
    var module_live = true;
    defer if (module_live) module.deinit();
    var vertex = try module.getFunction("vertex");
    var generated = try module.getFunction("generated");
    var fragment = try module.getFunction("fragment");
    var functions_live = true;
    defer if (functions_live) {
        vertex.deinit();
        generated.deinit();
        fragment.deinit();
    };
    var missing = try module.getFunction("missing");
    defer missing.deinit();
    var unsigned = try module.getFunction("unsigned_fragment");
    defer unsigned.deinit();
    var signed = try module.getFunction("signed_fragment");
    defer signed.deinit();
    var compute = try module.getFunction("compute_main");
    defer compute.deinit();
    var multiple = try module.getFunction("multiple");
    defer multiple.deinit();
    const targets = [_]gpu.ColorTargetState{.{ .format = .rgba8_unorm }};
    const attribute: gpu.VertexAttribute = .{ .format = .float32x2, .offset = 0, .shader_location = 0 };
    const buffers = [_]gpu.VertexBufferLayout{.{ .array_stride = 8, .attributes = &.{attribute} }};
    var desc: d12.RenderPipelineDescriptor = .{ .layout = &layout, .vertex_function = &vertex, .fragment_function = &fragment, .vertex_buffers = &buffers, .targets = &targets };
    var pipeline = try device.createRenderPipeline(desc);
    defer pipeline.deinit();
    pipelines_created += 1;
    desc.vertex_function = &generated;
    desc.vertex_buffers = &.{};
    for (std.enums.values(gpu.PrimitiveTopology)) |topology| {
        desc.primitive.topology = topology;
        var p = try device.createRenderPipeline(desc);
        defer p.deinit();
        pipelines_created += 1;
    }
    desc.primitive = .{ .topology = .triangle_strip, .strip_index_format = .uint16, .front_face = .cw, .cull_mode = .back, .polygon_mode = .line, .unclipped_depth = true };
    {
        var p = try device.createRenderPipeline(desc);
        defer p.deinit();
        pipelines_created += 1;
    }
    desc.primitive.strip_index_format = .uint32;
    {
        var p = try device.createRenderPipeline(desc);
        defer p.deinit();
        pipelines_created += 1;
    }
    desc.primitive = .{};
    desc.fragment_function = &unsigned;
    desc.targets = &.{.{ .format = .r32_uint }};
    {
        var p = try device.createRenderPipeline(desc);
        defer p.deinit();
        pipelines_created += 1;
    }
    desc.fragment_function = &signed;
    desc.targets = &.{.{ .format = .r32_sint }};
    {
        var p = try device.createRenderPipeline(desc);
        defer p.deinit();
        pipelines_created += 1;
    }
    desc.fragment_function = &multiple;
    desc.targets = &.{ .{ .format = .rgba8_unorm, .blend = gpu.BlendState.ALPHA_BLENDING }, .{ .format = .r32_uint, .write_mask = .{ .red = true } } };
    {
        var p = try device.createRenderPipeline(desc);
        defer p.deinit();
        pipelines_created += 1;
    }
    desc.targets = &targets;
    try expectError(error.InvalidRenderPipeline, device.createRenderPipeline(desc)); // missing SV_Target1
    desc.fragment_function = &fragment;
    desc.targets = &targets;
    desc.vertex_function = &compute;
    try expectError(error.InvalidShaderStage, device.createRenderPipeline(desc));
    // Forged public stage still cannot bypass native bytecode reflection.
    var forged = compute;
    forged.stage = .vertex;
    desc.vertex_function = &forged;
    try expectError(error.InvalidRenderPipeline, device.createRenderPipeline(desc));
    desc.vertex_function = &vertex;
    try expectError(error.InvalidRenderPipeline, device.createRenderPipeline(desc)); // missing input buffer
    desc.vertex_buffers = &buffers;
    desc.fragment_function = &missing;
    try expectError(error.InvalidRenderPipeline, device.createRenderPipeline(desc));
    desc.fragment_function = &unsigned;
    desc.targets = &targets;
    try expectError(error.InvalidRenderPipeline, device.createRenderPipeline(desc));
    desc.fragment_function = &fragment;
    desc.targets = &.{.{ .format = .r32_uint }};
    try expectError(error.InvalidRenderPipeline, device.createRenderPipeline(desc));
    desc.targets = &.{.{ .format = .r32_uint, .blend = gpu.BlendState.ALPHA_BLENDING }};
    try expectError(error.InvalidRenderPipeline, device.createRenderPipeline(desc));
    desc.targets = &targets;
    const invalid_buffers = [_]gpu.VertexBufferLayout{
        .{ .array_stride = 4, .attributes = &.{attribute} },
        .{ .array_stride = 0, .attributes = &.{} },
        .{ .array_stride = 6, .attributes = &.{attribute} },
        .{ .array_stride = 2052, .attributes = &.{attribute} },
        .{ .array_stride = 8, .attributes = &.{ attribute, attribute } },
        .{ .array_stride = 8, .attributes = &.{.{ .format = .uint32x2, .offset = 0, .shader_location = 0 }} },
        .{ .array_stride = 8, .attributes = &.{.{ .format = .float32x2, .offset = 2, .shader_location = 0 }} },
    };
    for (invalid_buffers) |buffer| {
        desc.vertex_buffers = &.{buffer};
        try expectError(error.InvalidRenderPipeline, device.createRenderPipeline(desc));
    }
    desc.vertex_buffers = &buffers;
    desc.targets = &.{};
    try expectError(error.InvalidRenderPipeline, device.createRenderPipeline(desc));
    desc.targets = &targets;
    desc.multisample.count = 3;
    try expectError(error.UnsupportedMultisampling, device.createRenderPipeline(desc));
    desc.multisample = .{};
    desc.primitive.polygon_mode = .point;
    try expectError(error.UnsupportedPointPolygonMode, device.createRenderPipeline(desc));
    desc.primitive = .{ .strip_index_format = .uint16 };
    try expectError(error.InvalidRenderPipeline, device.createRenderPipeline(desc));
    desc.primitive = .{};
    desc.depth_stencil = .{ .format = .stencil8, .depth_write_enabled = true, .depth_compare = .less };
    try expectError(error.UnsupportedDepthStencil, device.createRenderPipeline(desc));
    desc.depth_stencil = null;
    var foreign = try d12.Device.init(true);
    defer foreign.destroy();
    try expectError(error.InvalidRenderPipeline, foreign.createRenderPipeline(desc));
    // Every function actually used by the retained PSO is gone before inspection.
    vertex.deinit();
    generated.deinit();
    fragment.deinit();
    functions_live = false;
    module.deinit();
    module_live = false;
    layout.deinit();
    layout_live = false;
    device.destroy();
    device_live = false;
    if (zenit_d12_test_render_pipeline_owned(pipeline.raw) != 1) return error.RenderPipelineOwnerLost;
    std.debug.print("PASS: production graphics PSO creation, topology/strip/cull/typed targets, retained root/device; stage/input/link/output/usage rejection guards\n", .{});
}
fn formatsAndBlend() !void {
    var device = try d12.Device.init(true);
    defer device.destroy();
    var layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{} });
    defer layout.deinit();
    var pixel = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = "float4 fragment():SV_Target{return float4(1,0,0,1);}", .entry_points = &.{.{ .name = "fragment", .stage = .fragment }} } } });
    defer pixel.deinit();
    var fragment = try pixel.getFunction("fragment");
    defer fragment.deinit();
    for (std.enums.values(gpu.VertexFormat)) |format| {
        const name = @tagName(format);
        const ty: []const u8 = if (std.mem.startsWith(u8, name, "uint")) "uint4" else if (std.mem.startsWith(u8, name, "sint")) "int4" else "float4";
        const code = try std.fmt.allocPrint(a, "float4 vertex({s} p:TEXCOORD0):SV_Position{{return float4(p);}}", .{ty});
        defer a.free(code);
        var module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = code, .entry_points = &.{.{ .name = "vertex", .stage = .vertex }} } } });
        defer module.deinit();
        var function = try module.getFunction("vertex");
        defer function.deinit();
        var pipeline = try device.createRenderPipeline(.{ .layout = &layout, .vertex_function = &function, .fragment_function = &fragment, .vertex_buffers = &.{.{ .array_stride = 32, .step_mode = .instance, .attributes = &.{.{ .format = format, .offset = 4, .shader_location = 0 }} }}, .targets = &.{.{ .format = .rgba8_unorm }} });
        defer pipeline.deinit();
        pipelines_created += 1;
    }
    var module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = "float4 vertex(uint id:SV_VertexID):SV_Position{return float4(id,0,0,1);}", .entry_points = &.{.{ .name = "vertex", .stage = .vertex }} } } });
    defer module.deinit();
    var function = try module.getFunction("vertex");
    defer function.deinit();
    for (std.enums.values(gpu.BlendFactor)) |factor| for (std.enums.values(gpu.BlendOperation)) |operation| {
        const component: gpu.BlendComponent = .{ .src_factor = factor, .dst_factor = factor, .operation = operation };
        var pipeline = try device.createRenderPipeline(.{ .layout = &layout, .vertex_function = &function, .fragment_function = &fragment, .targets = &.{.{ .format = .bgra8_unorm, .blend = .{ .color = component, .alpha = component }, .write_mask = .{ .red = true, .alpha = true } }} });
        defer pipeline.deinit();
        pipelines_created += 1;
    };
    std.debug.print("PASS: all 30 vertex formats with instance input and 65 blend-factor/operation combinations accepted by native PSO creation\n", .{});
}
fn visibility() !void {
    var device = try d12.Device.init(true);
    defer device.destroy();
    var module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = "cbuffer P:register(b0,space1){float4 color;} float4 vertex(uint id:SV_VertexID):SV_Position{return float4(id,0,0,1)+color;} float4 fragment():SV_Target{return color;}", .entry_points = &.{ .{ .name = "vertex", .stage = .vertex }, .{ .name = "fragment", .stage = .fragment } } } } });
    defer module.deinit();
    var vertex = try module.getFunction("vertex");
    defer vertex.deinit();
    var fragment = try module.getFunction("fragment");
    defer fragment.deinit();
    var empty = try device.createBindGroupLayout(a, .{ .entries = &.{} });
    defer empty.deinit();
    for ([_]gpu.ShaderStages{ .{ .vertex = true }, .{ .fragment = true }, .{ .compute = true }, .{ .vertex = true, .fragment = true } }, 0..) |stage, i| {
        var bgl = try device.createBindGroupLayout(a, .{ .entries = &.{.{ .binding = 0, .visibility = stage, .ty = .{ .buffer = .{} } }} });
        defer bgl.deinit();
        var layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{ empty, bgl } });
        defer layout.deinit();
        const desc: d12.RenderPipelineDescriptor = .{ .layout = &layout, .vertex_function = &vertex, .fragment_function = &fragment, .targets = &.{.{ .format = .rgba8_unorm }} };
        if (i == 3) {
            var pipeline = try device.createRenderPipeline(desc);
            defer pipeline.deinit();
            pipelines_created += 1;
        } else try expectError(error.InvalidRenderPipeline, device.createRenderPipeline(desc));
    }
    std.debug.print("PASS: production graphics reflection enforces vertex/fragment visibility in register space1\n", .{});
}
pub fn run() !void {
    pipelines_created = 0;
    try basicsAndRejections();
    try formatsAndBlend();
    try visibility();
    std.debug.print("PASS: {d} real graphics PSOs created; rendering/output pixels remain a separate pending contract\n", .{pipelines_created});
}
