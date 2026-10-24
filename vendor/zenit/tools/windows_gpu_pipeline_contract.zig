const std = @import("std");
const gpu = @import("gpu");
const d12 = @import("gpu").Backend.native;
extern fn zenit_d12_test_warp_shader_parser() c_int;
extern fn zenit_d12_test_gate_create(*anyopaque, *anyopaque) *anyopaque;
extern fn zenit_d12_test_gate_signal(*anyopaque) void;
extern fn zenit_d12_test_gate_release(*anyopaque) void;

fn expectError(expected: anyerror, result: anytype) !void {
    if (result) |_| return error.ExpectedFailure else |actual| if (actual != expected) return actual;
}
fn execute(group: u32) !void {
    var device = try d12.Device.init(true);
    var device_live = true;
    defer if (device_live) device.destroy();
    const allocator = std.heap.page_allocator;
    var empty = try device.createBindGroupLayout(allocator, .{ .entries = &.{} });
    defer empty.deinit();
    var group_layout = try device.createBindGroupLayout(allocator, .{ .entries = &.{.{ .binding = 0, .visibility = .{ .compute = true }, .ty = .{ .buffer = .{ .ty = .storage } } }} });
    var group_live = true;
    defer if (group_live) group_layout.deinit();
    var groups = [_]d12.BindGroupLayout{ empty, empty, empty, empty };
    groups[group] = group_layout;
    var layout = try device.createPipelineLayout(allocator, .{ .bind_group_layouts = groups[0 .. group + 1] });
    var layout_live = true;
    defer if (layout_live) layout.deinit();
    if (layout.tableIndex(group, false) != 0 or layout.tableIndex(group, true) != null) return error.IncorrectRootTable;
    const source = try std.fmt.allocPrint(allocator, "RWStructuredBuffer<float> result:register(u0,space{d}); [numthreads(4,1,1)] void main(uint3 id:SV_DispatchThreadID){{result[id.x]=31+id.x*7;}}", .{group});
    defer allocator.free(source);
    var module = try device.createShaderModule(allocator, .{ .source = .{ .hlsl = .{ .code = source, .entry_points = &.{.{ .name = "main", .stage = .compute }} } } });
    var module_live = true;
    defer if (module_live) module.deinit();
    var function = try module.getFunction("main");
    var function_live = true;
    defer if (function_live) function.deinit();
    var pipeline = try device.createComputePipeline(.{ .layout = &layout, .compute_function = &function });
    var pipeline_live = true;
    defer if (pipeline_live) pipeline.deinit();
    var output = try device.createBuffer(allocator, .{ .size = 16, .usage = .{ .storage = true, .copy_src = true } });
    var output_live = true;
    defer if (output_live) output.destroy();
    var bound: [4]d12.BindGroup = undefined;
    var created: usize = 0;
    defer for (bound[0..created]) |*binding| binding.deinit();
    while (created <= group) : (created += 1) {
        bound[created] = try device.createBindGroup(allocator, .{ .layout = &layout, .group = @intCast(created), .entries = if (created == group) &.{.{ .binding = 0, .buffer = &output, .stride = 4 }} else &.{} });
    }
    // Pipeline and groups retain their native root layout after caller release.
    group_layout.deinit();
    group_live = false;
    layout.deinit();
    layout_live = false;
    module.deinit();
    module_live = false;
    function.deinit();
    function_live = false;
    var readback = try device.createBuffer(allocator, .{ .size = 16, .usage = .{ .map_read = true, .copy_dst = true } });
    defer readback.destroy();
    var queue = try device.createQueue();
    defer queue.deinit(5000) catch @panic("pipeline teardown failed");
    var encoder = try device.createCommandEncoder();
    defer encoder.deinit();
    try expectError(error.InvalidDispatch, encoder.dispatch(&pipeline, bound[0..created], 65536, 1, 1));
    try encoder.dispatch(&pipeline, bound[0..created], 1, 1, 1);
    // Two dispatches exercise UAV state restoration and distinct descriptor heaps.
    try encoder.dispatch(&pipeline, bound[0..created], 1, 1, 1);
    try encoder.copyBufferToBuffer(&output, 0, &readback, 0, 16);
    output.destroy();
    output_live = false;
    pipeline.deinit();
    pipeline_live = false;
    for (bound[0..created]) |*binding| binding.deinit();
    created = 0;
    var command = try encoder.finish();
    const gate = zenit_d12_test_gate_create(device.raw, queue.raw);
    var gate_signaled = false;
    defer {
        if (!gate_signaled) zenit_d12_test_gate_signal(gate);
        queue.waitIdle(5000) catch @panic("dispatch gate teardown failed");
        zenit_d12_test_gate_release(gate);
    }
    _ = try queue.submit(&.{command});
    command.deinit();
    device.destroy();
    device_live = false;
    try expectError(error.GpuTimeout, queue.waitIdle(0));
    try expectError(error.GpuTimeout, queue.deinit(0));
    zenit_d12_test_gate_signal(gate);
    gate_signaled = true;
    try queue.waitIdle(5000);
    const bytes = try readback.getMappedRange(0, 16);
    for ([_]f32{ 31, 38, 45, 52 }, 0..) |expected, i| {
        var actual: f32 = undefined;
        @memcpy(std.mem.asBytes(&actual), bytes[i * 4 ..][0..4]);
        if (actual != expected) return error.IncorrectPipelineOutput;
    }
    std.debug.print("PASS: production binding/dispatch/copy space{d}, early buffer/group/pipeline destruction, four actual GPU results\n", .{group});
}
fn invalidLayouts() !void {
    var device = try d12.Device.init(true);
    defer device.destroy();
    const a = std.heap.page_allocator;
    const writable: gpu.BindGroupLayoutEntry = .{ .binding = 0, .visibility = .{ .compute = true }, .ty = .{ .buffer = .{ .ty = .storage } } };
    try expectError(error.DuplicateBinding, device.createBindGroupLayout(a, .{ .entries = &.{ writable, writable } }));
    try expectError(error.InvalidBindGroupLayout, device.createBindGroupLayout(a, .{ .entries = &.{.{ .binding = 0, .visibility = .{}, .ty = writable.ty }} }));
    try expectError(error.UnsupportedDynamicOffsets, device.createBindGroupLayout(a, .{ .entries = &.{.{ .binding = 0, .visibility = writable.visibility, .ty = .{ .buffer = .{ .has_dynamic_offset = true } } }} }));
    try expectError(error.InvalidBindGroupLayout, device.createBindGroupLayout(a, .{ .entries = &.{.{ .binding = 0, .visibility = writable.visibility, .ty = writable.ty, .count = 0 }} }));
    var overlap = try device.createBindGroupLayout(a, .{ .entries = &.{
        .{ .binding = 0, .visibility = writable.visibility, .ty = .{ .texture = .{} }, .count = 2 },
        .{ .binding = 1, .visibility = writable.visibility, .ty = .{ .buffer = .{ .ty = .read_only_storage } } },
    } });
    defer overlap.deinit();
    try expectError(error.InvalidPipelineLayout, device.createPipelineLayout(a, .{ .bind_group_layouts = &.{overlap} }));
    var sampler_budget = try device.createBindGroupLayout(a, .{ .entries = &.{.{ .binding = 0, .visibility = writable.visibility, .ty = .{ .sampler = .{} }, .count = 1025 }} });
    defer sampler_budget.deinit();
    try expectError(error.InvalidPipelineLayout, device.createPipelineLayout(a, .{ .bind_group_layouts = &.{ sampler_budget, sampler_budget } }));
    var empty = try device.createBindGroupLayout(a, .{ .entries = &.{} });
    defer empty.deinit();
    try expectError(error.InvalidPipelineLayout, device.createPipelineLayout(a, .{ .bind_group_layouts = &.{ empty, empty, empty, empty, empty } }));
    var empty_layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{} });
    defer empty_layout.deinit();
    var module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = "RWStructuredBuffer<float> result:register(u0); [numthreads(4,1,1)] void main(uint3 id:SV_DispatchThreadID){result[id.x]=9;} float4 vertex():SV_Position{return float4(0,0,0,1);}", .entry_points = &.{ .{ .name = "main", .stage = .compute }, .{ .name = "vertex", .stage = .vertex } } } } });
    defer module.deinit();
    var function = try module.getFunction("main");
    defer function.deinit();
    var vertex = try module.getFunction("vertex");
    defer vertex.deinit();
    try expectError(error.InvalidShaderStage, device.createComputePipeline(.{ .layout = &empty_layout, .compute_function = &vertex }));
    try expectError(error.ShaderLayoutMismatch, device.createComputePipeline(.{ .layout = &empty_layout, .compute_function = &function }));
    const variants = [_]gpu.BindGroupLayoutEntry{
        .{ .binding = 0, .visibility = writable.visibility, .ty = .{ .buffer = .{ .ty = .read_only_storage } } },
        .{ .binding = 0, .visibility = .{ .vertex = true }, .ty = writable.ty },
        .{ .binding = 1, .visibility = writable.visibility, .ty = writable.ty },
    };
    for (variants) |entry| {
        var bgl = try device.createBindGroupLayout(a, .{ .entries = &.{entry} });
        defer bgl.deinit();
        var layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{bgl} });
        defer layout.deinit();
        try expectError(error.ShaderLayoutMismatch, device.createComputePipeline(.{ .layout = &layout, .compute_function = &function }));
    }
    var good = try device.createBindGroupLayout(a, .{ .entries = &.{writable} });
    defer good.deinit();
    var layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{good} });
    defer layout.deinit();
    var counter_module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = "AppendStructuredBuffer<float> result:register(u0); [numthreads(1,1,1)] void main(){result.Append(1);}", .entry_points = &.{.{ .name = "main", .stage = .compute }} } } });
    defer counter_module.deinit();
    var counter_function = try counter_module.getFunction("main");
    defer counter_function.deinit();
    try expectError(error.ShaderLayoutMismatch, device.createComputePipeline(.{ .layout = &layout, .compute_function = &counter_function }));
    var foreign = try d12.Device.init(true);
    defer foreign.destroy();
    try expectError(error.ShaderLayoutMismatch, foreign.createComputePipeline(.{ .layout = &layout, .compute_function = &function }));
    std.debug.print("PASS: compute reflection rejects wrong kind/register/visibility, missing layout bindings, stage and device mismatch; invalid layout guards\n", .{});
}
fn mixedBindings(force_warp: bool) !void {
    const a = std.heap.page_allocator;
    var device = try d12.Device.init(force_warp);
    defer device.destroy();
    const compute: gpu.ShaderStages = .{ .compute = true };
    var b0 = try device.createBindGroupLayout(a, .{ .entries = &.{
        .{ .binding = 3, .visibility = compute, .ty = .{ .buffer = .{ .ty = .storage, .min_binding_size = 16 } } },
        .{ .binding = 0, .visibility = compute, .ty = .{ .buffer = .{ .ty = .uniform } } },
        .{ .binding = 2, .visibility = compute, .ty = .{ .buffer = .{ .ty = .read_only_storage } } },
        .{ .binding = 1, .visibility = compute, .ty = .{ .buffer = .{ .ty = .read_only_storage } } },
    } });
    defer b0.deinit();
    var b1 = try device.createBindGroupLayout(a, .{ .entries = &.{.{ .binding = 4, .visibility = compute, .ty = .{ .buffer = .{ .ty = .read_only_storage } }, .count = 2 }} });
    defer b1.deinit();
    var layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{ b0, b1 } });
    defer layout.deinit();
    var module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = "cbuffer P:register(b0){float add;float3 padding;} StructuredBuffer<float2> source:register(t1); ByteAddressBuffer raw:register(t2); RWStructuredBuffer<float> output:register(u3); StructuredBuffer<float> array[2]:register(t4,space1); [numthreads(4,1,1)] void main(uint3 id:SV_DispatchThreadID){output[id.x]=add+source[id.x].x+asfloat(raw.Load(id.x*4))+array[0][id.x]+array[1][id.x];}", .entry_points = &.{.{ .name = "main", .stage = .compute }} } } });
    defer module.deinit();
    var function = try module.getFunction("main");
    defer function.deinit();
    var pipeline = try device.createComputePipeline(.{ .layout = &layout, .compute_function = &function });
    defer pipeline.deinit();
    var uniform = try device.createBuffer(a, .{ .size = 272, .usage = .{ .uniform = true, .map_write = true } });
    defer uniform.destroy();
    @memset(try uniform.getMappedRange(0, 272), 0);
    const add: f32 = 100;
    @memcpy(try uniform.getMappedRange(256, 4), std.mem.asBytes(&add));
    var input = try device.createBuffer(a, .{ .size = 64, .usage = .{ .storage = true, .map_write = true } });
    defer input.destroy();
    const numbers = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    @memcpy(try input.getMappedRange(0, 64), std.mem.sliceAsBytes(&numbers));
    var output = try device.createBuffer(a, .{ .size = 64, .usage = .{ .storage = true, .copy_src = true } });
    defer output.destroy();
    var readback = try device.createBuffer(a, .{ .size = 112, .usage = .{ .map_read = true, .copy_dst = true } });
    defer readback.destroy();
    var entries = [_]d12.BufferBinding{
        .{ .binding = 0, .buffer = &uniform, .offset = 256, .size = 16 },
        .{ .binding = 1, .buffer = &input, .offset = 8, .size = 32, .stride = 8 },
        .{ .binding = 2, .buffer = &input, .offset = 16, .size = 16 },
        .{ .binding = 3, .buffer = &output, .offset = 16, .size = 16, .stride = 4 },
    };
    var group0 = try device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &entries });
    defer group0.deinit();
    const arrays = [_]d12.BufferBinding{
        .{ .binding = 4, .array_index = 1, .buffer = &input, .offset = 32, .size = 16, .stride = 4 },
        .{ .binding = 4, .array_index = 0, .buffer = &input, .offset = 16, .size = 16, .stride = 4 },
    };
    var group1 = try device.createBindGroup(a, .{ .layout = &layout, .group = 1, .entries = &arrays });
    defer group1.deinit();
    var queue = try device.createQueue();
    defer queue.deinit(5000) catch @panic("mixed queue teardown failed");
    var encoder = try device.createCommandEncoder();
    defer encoder.deinit();
    try expectError(error.InvalidBindGroup, device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = entries[0..3] }));
    var foreign = try d12.Device.init(true);
    defer foreign.destroy();
    try expectError(error.InvalidBindGroup, foreign.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &entries }));
    var foreign_encoder = try foreign.createCommandEncoder();
    defer foreign_encoder.deinit();
    try expectError(error.InvalidDispatch, foreign_encoder.dispatch(&pipeline, &.{ group0, group1 }, 1, 1, 1));
    entries[0].size = 4;
    var short_uniform = try device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &entries });
    defer short_uniform.deinit();
    try expectError(error.InvalidDispatch, encoder.dispatch(&pipeline, &.{ short_uniform, group1 }, 1, 1, 1));
    entries[0].size = 16;
    entries[0].offset = 4;
    try expectError(error.InvalidBindGroup, device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &entries }));
    entries[0].offset = 256;
    entries[3].size = 12;
    try expectError(error.InvalidBindGroup, device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &entries }));
    entries[3].size = 16;
    entries[2].offset = 4;
    try expectError(error.InvalidBindGroup, device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &entries }));
    entries[2].offset = 16;
    entries[1].stride = 4;
    var wrong = try device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &entries });
    defer wrong.deinit();
    try expectError(error.InvalidDispatch, encoder.dispatch(&pipeline, &.{ wrong, group1 }, 1, 1, 1));
    entries[1].stride = 8;
    entries[3].buffer = &input;
    try expectError(error.InvalidBindGroup, device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &entries }));
    entries[3].buffer = &output;
    entries[2].buffer = &output;
    var alias = try device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &entries });
    defer alias.deinit();
    try expectError(error.InvalidDispatch, encoder.dispatch(&pipeline, &.{ alias, group1 }, 1, 1, 1));
    try expectError(error.InvalidDispatch, encoder.dispatch(&pipeline, &.{group0}, 1, 1, 1));
    try expectError(error.InvalidDispatch, encoder.dispatch(&pipeline, &.{ group1, group0 }, 1, 1, 1));
    try encoder.dispatch(&pipeline, &.{ group0, group1 }, 1, 1, 1);
    try encoder.copyBufferToBuffer(&output, 16, &readback, 0, 16);
    var raw_module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = "cbuffer P:register(b0){float add;float3 padding;} StructuredBuffer<float2> source:register(t1); RWByteAddressBuffer output:register(u3); [numthreads(4,1,1)] void main(uint3 id:SV_DispatchThreadID){output.Store(id.x*4,asuint(add+source[id.x].x));}", .entry_points = &.{.{ .name = "main", .stage = .compute }} } } });
    defer raw_module.deinit();
    var raw_function = try raw_module.getFunction("main");
    defer raw_function.deinit();
    var raw_pipeline = try device.createComputePipeline(.{ .layout = &layout, .compute_function = &raw_function });
    defer raw_pipeline.deinit();
    try expectError(error.InvalidDispatch, encoder.dispatch(&raw_pipeline, &.{ group0, group1 }, 1, 1, 1));
    entries[2].buffer = &input;
    entries[3].stride = 0;
    var raw_group = try device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &entries });
    defer raw_group.deinit();
    try encoder.dispatch(&raw_pipeline, &.{ raw_group, group1 }, 1, 1, 1);
    try encoder.copyBufferToBuffer(&output, 16, &readback, 16, 16);
    // Weight each descriptor independently so an array element alias cannot hide
    // behind the combined result. The SRVs share storage but use distinct offsets.
    var probe_module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = "ByteAddressBuffer raw:register(t2); StructuredBuffer<float> array[2]:register(t4,space1); RWStructuredBuffer<float> output:register(u3); [numthreads(4,1,1)] void main(uint3 id:SV_DispatchThreadID){output[id.x]=asfloat(raw.Load(id.x*4))+100*array[0][id.x]+10000*array[1][id.x];}", .entry_points = &.{.{ .name = "main", .stage = .compute }} } } });
    defer probe_module.deinit();
    var probe_function = try probe_module.getFunction("main");
    defer probe_function.deinit();
    var probe_pipeline = try device.createComputePipeline(.{ .layout = &layout, .compute_function = &probe_function });
    defer probe_pipeline.deinit();
    try encoder.dispatch(&probe_pipeline, &.{ group0, group1 }, 1, 1, 1);
    try encoder.copyBufferToBuffer(&output, 16, &readback, 32, 16);
    const array_sources = [_][]const u8{
        "StructuredBuffer<float> array[2]:register(t4,space1); RWStructuredBuffer<float> output:register(u3); [numthreads(4,1,1)] void main(uint3 id:SV_DispatchThreadID){output[id.x]=array[1][id.x];}",
        "StructuredBuffer<float> array[2]:register(t4,space1); RWStructuredBuffer<float> output:register(u3); [numthreads(4,1,1)] void main(uint3 id:SV_DispatchThreadID){output[id.x]=array[NonUniformResourceIndex(id.x%2)][id.x];}",
        "StructuredBuffer<float> first:register(t4,space1); StructuredBuffer<float> second:register(t5,space1); RWStructuredBuffer<float> output:register(u3); [numthreads(4,1,1)] void main(uint3 id:SV_DispatchThreadID){output[id.x]=100*first[id.x]+second[id.x];}",
        "StructuredBuffer<float> array[2]:register(t4,space1); RWStructuredBuffer<float> output:register(u3); [numthreads(4,1,1)] void main(uint3 id:SV_DispatchThreadID){output[id.x]=array[1][id.x]+100*array[NonUniformResourceIndex(id.x%2)][id.x];}",
    };
    for (array_sources, 0..) |source, index| {
        var array_module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = source, .entry_points = &.{.{ .name = "main", .stage = .compute }} } } });
        defer array_module.deinit();
        var array_function = try array_module.getFunction("main");
        defer array_function.deinit();
        var array_pipeline = try device.createComputePipeline(.{ .layout = &layout, .compute_function = &array_function });
        defer array_pipeline.deinit();
        try encoder.dispatch(&array_pipeline, &.{ group0, group1 }, 1, 1, 1);
        try encoder.copyBufferToBuffer(&output, 16, &readback, 48 + index * 16, 16);
    }
    var command = try encoder.finish();
    defer command.deinit();
    _ = try queue.submit(&.{command});
    try queue.waitIdle(5000);
    const bytes = try readback.getMappedRange(0, 112);
    for ([_]f32{ 122, 127, 132, 137, 103, 105, 107, 109, 90505, 100606, 110707, 120808, 9, 10, 11, 12, 5, 10, 7, 12, 509, 610, 711, 812, 509, 1010, 711, 1212 }, 0..) |expected, i| {
        var actual: f32 = undefined;
        @memcpy(std.mem.asBytes(&actual), bytes[i * 4 ..][0..4]);
        if (actual != expected) {
            std.debug.print("mixed output mismatch index={d} actual={d} expected={d} bytes={s}\n", .{ i, actual, expected, std.fmt.bytesToHex(bytes[0..112].*, .lower) });
            return error.IncorrectMixedOutput;
        }
    }
    std.debug.print("PASS: production CBV/structured and raw SRV/UAV, offsets, arrays, two register spaces, descriptor reordering, stride/alias/range guards (forced_warp={})\n", .{force_warp});
}
pub fn run(io: std.Io) !void {
    if (zenit_d12_test_warp_shader_parser() != 0) return error.InvalidWarpShaderParser;
    try @import("windows_gpu_buffer_array_contract.zig").run();
    try @import("windows_gpu_shader_cache_contract.zig").run(io);
    try invalidLayouts();
    try execute(0);
    try execute(1);
    try execute(3);
    try mixedBindings(false);
    try mixedBindings(true);
}
