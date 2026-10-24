const std = @import("std");
const gpu = @import("gpu");
const d12 = gpu.Backend.native;
const a = std.heap.page_allocator;
extern fn zenit_d12_test_debug_check(*anyopaque) void;

fn compute(device: *d12.Device, raw: bool) !void {
    var bindings = try device.createBindGroupLayout(a, .{ .entries = &.{
        .{ .binding = 3, .count = 2, .visibility = .{ .compute = true }, .ty = .{ .buffer = .{ .ty = .storage } } },
        .{ .binding = 7, .count = 2, .visibility = .{ .compute = true }, .ty = .{ .buffer = .{ .ty = .read_only_storage } } },
    } });
    defer bindings.deinit();
    var layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{bindings} });
    defer layout.deinit();
    const structured_source =
        \\StructuredBuffer<uint> source[2]:register(t7); RWStructuredBuffer<uint> result[2]:register(u3);
        \\[numthreads(4,1,1)] void initialize(uint3 id:SV_DispatchThreadID){uint n,s;source[1].GetDimensions(n,s);result[0][id.x]=source[0][id.x]+10+n;result[1][id.x]=source[1][id.x]+20;}
        \\[numthreads(4,1,1)] void update(uint3 id:SV_DispatchThreadID){uint old;InterlockedAdd(result[1][id.x],30,old);InterlockedAdd(result[NonUniformResourceIndex(id.x%2)][id.x],100+source[NonUniformResourceIndex(id.x%2)][id.x],old);}
    ;
    const raw_source =
        \\ByteAddressBuffer source[2]:register(t7); RWByteAddressBuffer result[2]:register(u3);
        \\[numthreads(4,1,1)] void initialize(uint3 id:SV_DispatchThreadID){uint n;source[1].GetDimensions(n);result[0].Store(id.x*4,source[0].Load(id.x*4)+10+n/4);result[1].Store(id.x*4,source[1].Load(id.x*4)+20);}
        \\[numthreads(4,1,1)] void update(uint3 id:SV_DispatchThreadID){uint old;result[1].InterlockedAdd(id.x*4,30,old);result[NonUniformResourceIndex(id.x%2)].InterlockedAdd(id.x*4,100+source[NonUniformResourceIndex(id.x%2)].Load(id.x*4),old);}
    ;
    var module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = if (raw) raw_source else structured_source, .entry_points = &.{ .{ .name = "initialize", .stage = .compute }, .{ .name = "update", .stage = .compute } } } } });
    defer module.deinit();
    var initialize = try module.getFunction("initialize");
    defer initialize.deinit();
    var update = try module.getFunction("update");
    defer update.deinit();
    var first = try device.createComputePipeline(.{ .layout = &layout, .compute_function = &initialize });
    defer first.deinit();
    if (!try update.requiresNonUniformUavBufferArrayAtomics() or try initialize.requiresNonUniformUavBufferArrayAtomics()) return error.IncorrectAtomicFeatureClassification;
    var second = try device.createComputePipeline(.{ .layout = &layout, .compute_function = &update });
    defer second.deinit();
    if (second.atomic_switch_workaround != device.driverBugs().non_uniform_uav_buffer_array_atomics or first.atomic_switch_workaround) return error.IncorrectAtomicWorkaroundSelection;
    var input = try device.createBuffer(a, .{ .size = 64, .usage = .{ .storage = true, .map_write = true } });
    defer input.destroy();
    const numbers = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    @memcpy(try input.getMappedRange(0, 64), std.mem.sliceAsBytes(&numbers));
    var out0 = try device.createBuffer(a, .{ .size = 16, .usage = .{ .storage = true, .copy_src = true } });
    defer out0.destroy();
    var out1 = try device.createBuffer(a, .{ .size = 16, .usage = .{ .storage = true, .copy_src = true } });
    defer out1.destroy();
    const stride: u32 = if (raw) 0 else 4;
    var group = try device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &.{
        .{ .binding = 7, .array_index = 1, .buffer = &input, .offset = 32, .size = 16, .stride = stride },
        .{ .binding = 3, .array_index = 0, .buffer = &out0, .stride = stride },
        .{ .binding = 7, .array_index = 0, .buffer = &input, .offset = 16, .size = 16, .stride = stride },
        .{ .binding = 3, .array_index = 1, .buffer = &out1, .stride = stride },
    } });
    defer group.deinit();
    var readback = try device.createBuffer(a, .{ .size = 64, .usage = .{ .map_read = true, .copy_dst = true } });
    defer readback.destroy();
    var queue = try device.createQueue();
    defer queue.deinit(5000) catch @panic("array queue teardown failed");
    var encoder = try device.createCommandEncoder();
    defer encoder.deinit();
    try encoder.dispatch(&first, &.{group}, 1, 1, 1);
    try encoder.copyBufferToBuffer(&out0, 0, &readback, 0, 16);
    try encoder.copyBufferToBuffer(&out1, 0, &readback, 16, 16);
    try encoder.dispatch(&second, &.{group}, 1, 1, 1);
    try encoder.copyBufferToBuffer(&out0, 0, &readback, 32, 16);
    try encoder.copyBufferToBuffer(&out1, 0, &readback, 48, 16);
    var command = try encoder.finish();
    defer command.deinit();
    _ = try queue.submit(&.{command});
    try queue.waitIdle(5000);
    zenit_d12_test_debug_check(device.raw);
    const bytes = try readback.getMappedRange(0, 64);
    const expected = [_]u32{ 19, 20, 21, 22, 29, 30, 31, 32, 124, 20, 128, 22, 59, 170, 61, 174 };
    for (expected, 0..) |value, i| {
        const actual = std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little);
        std.debug.print("array raw={} phase={s} buffer={} element={} actual={} expected={}\n", .{ raw, if (i < 8) "initialize" else "update", (i / 4) % 2, i % 4, actual, value });
    }
    if (!std.mem.eql(u8, bytes, std.mem.sliceAsBytes(&expected))) {
        std.debug.print("buffer array writes mismatch raw={} bytes={s}\n", .{ raw, std.fmt.bytesToHex(bytes[0..64].*, .lower) });
        return error.IncorrectBufferArrayWrites;
    }
}

fn atomicOperations(device: *d12.Device, raw: bool, signed: bool) !void {
    var empty = try device.createBindGroupLayout(a, .{ .entries = &.{} });
    defer empty.deinit();
    var bindings = try device.createBindGroupLayout(a, .{ .entries = &.{.{ .binding = 5, .count = 3, .visibility = .{ .compute = true }, .ty = .{ .buffer = .{ .ty = .storage } } }} });
    defer bindings.deinit();
    var layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{ empty, empty, bindings } });
    defer layout.deinit();
    const structured_source =
        \\RWStructuredBuffer<uint> result[3]:register(u5,space2);
        \\[numthreads(48,1,1)] void update(uint3 id:SV_DispatchThreadID){
        \\uint i=(id.x+1)%3,b=id.x*16,old;result[NonUniformResourceIndex(i)][b+0]=10;
        \\[loop] for(uint k=0;k<2;++k){InterlockedAdd(result[NonUniformResourceIndex(i)][b],2,old);result[NonUniformResourceIndex(i)][b+1+k]=old;}
        \\InterlockedAnd(result[NonUniformResourceIndex(i)][b],7,old);result[NonUniformResourceIndex(i)][b+3]=old;
        \\InterlockedOr(result[NonUniformResourceIndex(i)][b],16,old);result[NonUniformResourceIndex(i)][b+4]=old;
        \\InterlockedXor(result[NonUniformResourceIndex(i)][b],3,old);result[NonUniformResourceIndex(i)][b+5]=old;
        \\InterlockedMin(result[NonUniformResourceIndex(i)][b],9,old);result[NonUniformResourceIndex(i)][b+6]=old;
        \\InterlockedMax(result[NonUniformResourceIndex(i)][b],25,old);result[NonUniformResourceIndex(i)][b+7]=old;
        \\InterlockedExchange(result[NonUniformResourceIndex(i)][b],31,old);result[NonUniformResourceIndex(i)][b+8]=old;
        \\InterlockedCompareExchange(result[NonUniformResourceIndex(i)][b],31,41,old);result[NonUniformResourceIndex(i)][b+9]=old;
        \\InterlockedCompareStore(result[NonUniformResourceIndex(i)][b],41,51);
        \\InterlockedAdd(result[NonUniformResourceIndex(i)][1535],1,old);result[NonUniformResourceIndex(i)][b+10]=old;
        \\}
    ;
    const raw_source =
        \\RWByteAddressBuffer result[3]:register(u5,space2);
        \\[numthreads(48,1,1)] void update(uint3 id:SV_DispatchThreadID){
        \\uint i=(id.x+1)%3,b=id.x*16,old;result[NonUniformResourceIndex(i)].Store((b+0)*4,10);
        \\[loop] for(uint k=0;k<2;++k){result[NonUniformResourceIndex(i)].InterlockedAdd(b*4,2,old);result[NonUniformResourceIndex(i)].Store((b+1+k)*4,old);}
        \\result[NonUniformResourceIndex(i)].InterlockedAnd(b*4,7,old);result[NonUniformResourceIndex(i)].Store((b+3)*4,old);
        \\result[NonUniformResourceIndex(i)].InterlockedOr(b*4,16,old);result[NonUniformResourceIndex(i)].Store((b+4)*4,old);
        \\result[NonUniformResourceIndex(i)].InterlockedXor(b*4,3,old);result[NonUniformResourceIndex(i)].Store((b+5)*4,old);
        \\result[NonUniformResourceIndex(i)].InterlockedMin(b*4,9,old);result[NonUniformResourceIndex(i)].Store((b+6)*4,old);
        \\result[NonUniformResourceIndex(i)].InterlockedMax(b*4,25,old);result[NonUniformResourceIndex(i)].Store((b+7)*4,old);
        \\result[NonUniformResourceIndex(i)].InterlockedExchange(b*4,31,old);result[NonUniformResourceIndex(i)].Store((b+8)*4,old);
        \\result[NonUniformResourceIndex(i)].InterlockedCompareExchange(b*4,31,41,old);result[NonUniformResourceIndex(i)].Store((b+9)*4,old);
        \\result[NonUniformResourceIndex(i)].InterlockedCompareStore(b*4,41,51);
        \\result[NonUniformResourceIndex(i)].InterlockedAdd(1535*4,1,old);result[NonUniformResourceIndex(i)].Store((b+10)*4,old);
        \\}
    ;
    const signed_source = try std.mem.replaceOwned(u8, a, structured_source, "RWStructuredBuffer<uint>", "RWStructuredBuffer<int>");
    defer a.free(signed_source);
    const signed_old = try std.mem.replaceOwned(u8, a, signed_source, "b=id.x*16,old;", "b=id.x*16;int old;");
    defer a.free(signed_old);
    const signed_min = try std.mem.replaceOwned(u8, a, signed_old, "[b],9,old", "[b],-9,old");
    defer a.free(signed_min);
    var module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = if (signed) signed_min else if (raw) raw_source else structured_source, .entry_points = &.{.{ .name = "update", .stage = .compute }} } } });
    defer module.deinit();
    var function = try module.getFunction("update");
    defer function.deinit();
    if (!try function.requiresNonUniformUavBufferArrayAtomics()) return error.IncorrectAtomicFeatureClassification;
    var pipeline = try device.createComputePipeline(.{ .layout = &layout, .compute_function = &function });
    defer pipeline.deinit();
    if (pipeline.atomic_switch_workaround != device.driverBugs().non_uniform_uav_buffer_array_atomics) return error.IncorrectAtomicWorkaroundSelection;
    const size = 96 * 16 * 4;
    var outputs: [3]d12.Buffer = undefined;
    var created: usize = 0;
    defer for (outputs[0..created]) |*buffer| buffer.destroy();
    for (&outputs) |*buffer| {
        buffer.* = try device.createBuffer(a, .{ .size = size, .usage = .{ .storage = true, .copy_dst = true, .copy_src = true } });
        created += 1;
    }
    var zero = try device.createBuffer(a, .{ .size = size, .usage = .{ .map_write = true, .copy_src = true } });
    defer zero.destroy();
    @memset(try zero.getMappedRange(0, size), 0);
    var group = try device.createBindGroup(a, .{ .layout = &layout, .group = 2, .entries = &.{
        .{ .binding = 5, .array_index = 0, .buffer = &outputs[0], .stride = if (raw) 0 else 4 },
        .{ .binding = 5, .array_index = 1, .buffer = &outputs[1], .stride = if (raw) 0 else 4 },
        .{ .binding = 5, .array_index = 2, .buffer = &outputs[2], .stride = if (raw) 0 else 4 },
    } });
    defer group.deinit();
    var readback = try device.createBuffer(a, .{ .size = size * 3, .usage = .{ .map_read = true, .copy_dst = true } });
    defer readback.destroy();
    var queue = try device.createQueue();
    defer queue.deinit(5000) catch @panic("atomic operations queue teardown failed");
    var encoder = try device.createCommandEncoder();
    defer encoder.deinit();
    for (&outputs) |*buffer| try encoder.copyBufferToBuffer(&zero, 0, buffer, 0, size);
    var g0 = try device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &.{} });
    defer g0.deinit();
    var g1 = try device.createBindGroup(a, .{ .layout = &layout, .group = 1, .entries = &.{} });
    defer g1.deinit();
    try encoder.dispatch(&pipeline, &.{ g0, g1, group }, 2, 1, 1);
    for (&outputs, 0..) |*buffer, index| try encoder.copyBufferToBuffer(buffer, 0, &readback, index * size, size);
    var command = try encoder.finish();
    defer command.deinit();
    _ = try queue.submit(&.{command});
    try queue.waitIdle(5000);
    const bytes = try readback.getMappedRange(0, size * 3);
    const expected = [_]u32{ 51, 10, 12, 14, 6, 22, 21, 9, 25, 31, 0, 0, 0, 0, 0, 0 };
    var old_values = std.mem.zeroes([3][32]bool);
    for (0..3) |buffer| for (0..96) |lane| for (expected, 0..) |value, slot| {
        const want = if (lane == 95 and slot == 15) 32 else if (buffer == (lane + 1) % 3) (if (signed and slot == 7) @as(u32, @bitCast(@as(i32, -9))) else value) else 0;
        const offset = buffer * size + (lane * 16 + slot) * 4;
        const actual = std.mem.readInt(u32, bytes[offset..][0..4], .little);
        if (slot == 10 and buffer == (lane + 1) % 3) {
            if (actual >= 32 or old_values[buffer][actual]) return error.IncorrectContendedAtomicReturn;
            old_values[buffer][actual] = true;
            continue;
        }
        if (actual != want) {
            std.debug.print("atomic op raw={} buffer={} lane={} slot={} actual={} expected={}\n", .{ raw, buffer, lane, slot, actual, want });
            return error.IncorrectAtomicOperation;
        }
    };
    zenit_d12_test_debug_check(device.raw);
    std.debug.print("PASS: atomic operations raw={} signed={}: 3 descriptors, space2/u5, 96 lanes, loop, old values and contended counters; 4608 exact readbacks; workaround={}\n", .{ raw, signed, pipeline.atomic_switch_workaround });
}

fn graphics(device: *d12.Device) !void {
    var empty = try device.createBindGroupLayout(a, .{ .entries = &.{} });
    defer empty.deinit();
    var bindings = try device.createBindGroupLayout(a, .{ .entries = &.{.{ .binding = 4, .count = 2, .visibility = .{ .vertex = true, .fragment = true }, .ty = .{ .buffer = .{ .ty = .read_only_storage } } }} });
    defer bindings.deinit();
    var layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{ empty, bindings } });
    defer layout.deinit();
    const source =
        \\StructuredBuffer<float> values[2]:register(t4,space1);
        \\struct V{float4 position:SV_Position;float value:TEXCOORD0;};
        \\V vertex(uint id:SV_VertexID){V v;v.position=float4(id==0?float2(-1,-1):id==1?float2(3,-1):float2(-1,3),0,1);v.value=values[1][0];return v;}
        \\uint fragment(V v):SV_Target{return uint(v.value+values[1][0]+100*values[NonUniformResourceIndex(uint(v.position.x)%2)][0]);}
    ;
    var module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = source, .entry_points = &.{ .{ .name = "vertex", .stage = .vertex }, .{ .name = "fragment", .stage = .fragment } } } } });
    defer module.deinit();
    var vertex = try module.getFunction("vertex");
    defer vertex.deinit();
    var fragment = try module.getFunction("fragment");
    defer fragment.deinit();
    var pipeline = try device.createRenderPipeline(.{ .layout = &layout, .vertex_function = &vertex, .fragment_function = &fragment, .targets = &.{.{ .format = .r32_uint }} });
    defer pipeline.deinit();
    var input = try device.createBuffer(a, .{ .size = 32, .usage = .{ .map_write = true, .storage = true } });
    defer input.destroy();
    const numbers = [_]f32{ 5, 0, 0, 0, 9, 0, 0, 0 };
    @memcpy(try input.getMappedRange(0, 32), std.mem.sliceAsBytes(&numbers));
    var g0 = try device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &.{} });
    defer g0.deinit();
    var g1 = try device.createBindGroup(a, .{ .layout = &layout, .group = 1, .entries = &.{
        .{ .binding = 4, .array_index = 0, .buffer = &input, .size = 16, .stride = 4 },
        .{ .binding = 4, .array_index = 1, .buffer = &input, .offset = 16, .size = 16, .stride = 4 },
    } });
    defer g1.deinit();
    var texture = try device.createTexture(a, .{ .size = .{ .width = 4, .height = 2 }, .format = .r32_uint, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer texture.destroy();
    const region = try texture.fullRegion(0, 0);
    const footprint = try texture.copyLayout(region, 0);
    var readback = try device.createBuffer(a, .{ .size = footprint.required_bytes, .usage = .{ .map_read = true, .copy_dst = true } });
    defer readback.destroy();
    var queue = try device.createQueue();
    defer queue.deinit(5000) catch @panic("array graphics queue teardown failed");
    var encoder = try device.createCommandEncoder();
    defer encoder.deinit();
    var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .texture = &texture, .load_op = .clear }} });
    defer pass.deinit();
    try pass.draw(.{ .pipeline = &pipeline, .bind_groups = &.{ g0, g1 }, .vertex_count = 3 });
    try pass.end();
    try encoder.copyTextureToBuffer(&texture, region, &readback, 0, footprint.row_pitch);
    var command = try encoder.finish();
    defer command.deinit();
    _ = try queue.submit(&.{command});
    try queue.waitIdle(5000);
    const bytes = try readback.getMappedRange(0, readback.size);
    for (0..2) |y| for (0..4) |x| {
        const actual = std.mem.readInt(u32, bytes[y * footprint.row_pitch + x * 4 ..][0..4], .little);
        if (actual != (if (x % 2 == 0) @as(u32, 518) else 918)) return error.IncorrectBufferArrayPixel;
    };
}

fn fragmentAtomics(device: *d12.Device) !void {
    var empty = try device.createBindGroupLayout(a, .{ .entries = &.{} });
    defer empty.deinit();
    var bindings = try device.createBindGroupLayout(a, .{ .entries = &.{.{ .binding = 4, .count = 2, .visibility = .{ .fragment = true }, .ty = .{ .buffer = .{ .ty = .storage } } }} });
    defer bindings.deinit();
    var layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{ empty, bindings } });
    defer layout.deinit();
    const source =
        \\RWStructuredBuffer<uint> values[2]:register(u4,space1);
        \\struct V{float4 position:SV_Position;float value:TEXCOORD0;};
        \\V vertex(uint id:SV_VertexID){V v;v.position=float4(id==0?float2(-1,-1):id==1?float2(3,-1):float2(-1,3),0,1);v.value=0;return v;}
        \\uint fragment(V v):SV_Target{uint old;InterlockedAdd(values[NonUniformResourceIndex(uint(v.position.x)%2)][0],1,old);return old;}
    ;
    var module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = source, .entry_points = &.{ .{ .name = "vertex", .stage = .vertex }, .{ .name = "fragment", .stage = .fragment } } } } });
    defer module.deinit();
    var vertex = try module.getFunction("vertex");
    defer vertex.deinit();
    var fragment = try module.getFunction("fragment");
    defer fragment.deinit();
    var pipeline = try device.createRenderPipeline(.{ .layout = &layout, .vertex_function = &vertex, .fragment_function = &fragment, .targets = &.{.{ .format = .r32_uint }} });
    defer pipeline.deinit();
    if (pipeline.atomic_switch_workaround != device.driverBugs().non_uniform_uav_buffer_array_atomics) return error.IncorrectAtomicWorkaroundSelection;
    var zero = try device.createBuffer(a, .{ .size = 4, .usage = .{ .map_write = true, .copy_src = true } });
    defer zero.destroy();
    @memset(try zero.getMappedRange(0, 4), 0);
    var out0 = try device.createBuffer(a, .{ .size = 4, .usage = .{ .storage = true, .copy_src = true, .copy_dst = true } });
    defer out0.destroy();
    var out1 = try device.createBuffer(a, .{ .size = 4, .usage = .{ .storage = true, .copy_src = true, .copy_dst = true } });
    defer out1.destroy();
    var g0 = try device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &.{} });
    defer g0.deinit();
    var g1 = try device.createBindGroup(a, .{ .layout = &layout, .group = 1, .entries = &.{
        .{ .binding = 4, .array_index = 0, .buffer = &out0, .size = 4, .stride = 4 },
        .{ .binding = 4, .array_index = 1, .buffer = &out1, .size = 4, .stride = 4 },
    } });
    defer g1.deinit();
    var texture = try device.createTexture(a, .{ .size = .{ .width = 4, .height = 2 }, .format = .r32_uint, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer texture.destroy();
    const region = try texture.fullRegion(0, 0);
    const footprint = try texture.copyLayout(region, 0);
    var readback = try device.createBuffer(a, .{ .size = footprint.required_bytes + 8, .usage = .{ .map_read = true, .copy_dst = true } });
    defer readback.destroy();
    var queue = try device.createQueue();
    defer queue.deinit(5000) catch @panic("array graphics queue teardown failed");
    var encoder = try device.createCommandEncoder();
    defer encoder.deinit();
    try encoder.copyBufferToBuffer(&zero, 0, &out0, 0, 4);
    try encoder.copyBufferToBuffer(&zero, 0, &out1, 0, 4);
    var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .texture = &texture, .load_op = .clear }} });
    defer pass.deinit();
    try pass.draw(.{ .pipeline = &pipeline, .bind_groups = &.{ g0, g1 }, .vertex_count = 3 });
    try pass.end();
    try encoder.copyTextureToBuffer(&texture, region, &readback, 0, footprint.row_pitch);
    try encoder.copyBufferToBuffer(&out0, 0, &readback, footprint.required_bytes, 4);
    try encoder.copyBufferToBuffer(&out1, 0, &readback, footprint.required_bytes + 4, 4);
    var command = try encoder.finish();
    defer command.deinit();
    _ = try queue.submit(&.{command});
    try queue.waitIdle(5000);
    const bytes = try readback.getMappedRange(0, readback.size);
    var seen = std.mem.zeroes([2][4]bool);
    for (0..2) |y| for (0..4) |x| {
        const actual = std.mem.readInt(u32, bytes[y * footprint.row_pitch + x * 4 ..][0..4], .little);
        if (actual >= 4 or seen[x % 2][actual]) return error.IncorrectFragmentAtomicReturn;
        seen[x % 2][actual] = true;
    };
    for (0..2) |index| if (std.mem.readInt(u32, bytes[footprint.required_bytes + index * 4 ..][0..4], .little) != 4) return error.IncorrectFragmentAtomicCount;
    zenit_d12_test_debug_check(device.raw);
    std.debug.print("PASS: fragment UAV array contended atomics and exact old-value permutations; workaround={}\n", .{pipeline.atomic_switch_workaround});
}

pub fn run() !void {
    const override: ?[]u8 = @import("zenit_environment").getOwned(a, "ZENIT_D3D12_UAV_ATOMIC_SWITCH") catch null;
    defer if (override) |value| a.free(value);
    for ([_]bool{ false, true }) |warp| {
        var device = try d12.Device.init(warp);
        defer device.destroy();
        const info = device.driverInfo();
        std.debug.print("array adapter vendor={x:0>4} device={x:0>4} version={any} software={}\n", .{ info.vendor_id, info.device_id, info.driver_version, info.software });
        const version = info.driver_version orelse .{ 0, 0, 0, 0 };
        const measured = !info.software and info.vendor_id == 0x8086 and info.device_id == 0x7d51 and std.mem.eql(u16, &version, &.{ 32, 0, 101, 8826 });
        const expected_workaround: ?bool = if (override) |value| std.mem.eql(u8, value, "1") else if (info.software) false else if (measured) true else null;
        const features = device.getFeatures();
        if (!features.non_uniform_uav_buffer_array_atomics or device.driverBugs().non_uniform_uav_buffer_array_atomics) return error.IncorrectDriverBugCapability;
        if (warp and !features.non_uniform_uav_buffer_array_atomics) return error.WarpAtomicCapabilityDisabled;
        var adapter: d12.renderer_device.Adapter = .{ .native_device = device.retained() };
        defer adapter.deinit();
        var dq = try adapter.requestDevice(a, .{});
        defer dq.device.deinit();
        defer dq.queue.deinit();
        if (dq.device.features.non_uniform_uav_buffer_array_atomics != features.non_uniform_uav_buffer_array_atomics or dq.device.driverBugs().non_uniform_uav_buffer_array_atomics) return error.IncorrectPublicAtomicCapability;
        const required: gpu.DeviceDescriptor = .{ .required_features = .{ .non_uniform_uav_buffer_array_atomics = true } };
        var supported = try adapter.requestDevice(a, required);
        defer supported.device.deinit();
        defer supported.queue.deinit();
        if (!supported.device.features.non_uniform_uav_buffer_array_atomics) return error.RequiredAtomicFeatureMissing;
        std.debug.print("PASS: lazy atomic capability and required-feature negotiation; known_tuple={} nonuniform_uav_buffer_array_atomics={}\n", .{ measured, features.non_uniform_uav_buffer_array_atomics });
        try compute(&device, false);
        if (expected_workaround) |expected| {
            if (device.driverBugs().non_uniform_uav_buffer_array_atomics != expected) return error.IncorrectMeasuredAtomicWorkaround;
        }
        if (dq.device.driverBugs().non_uniform_uav_buffer_array_atomics != device.driverBugs().non_uniform_uav_buffer_array_atomics) return error.IncorrectSharedAtomicDecision;
        try compute(&device, true);
        try atomicOperations(&device, false, false);
        try atomicOperations(&device, false, true);
        try atomicOperations(&device, true, false);
        try graphics(&device);
        try fragmentAtomics(&device);
        zenit_d12_test_debug_check(device.raw);
        std.debug.print("PASS: buffer arrays: original 40 exact readbacks, expanded operations and fragment contention (forced_warp={})\n", .{warp});
    }
}
