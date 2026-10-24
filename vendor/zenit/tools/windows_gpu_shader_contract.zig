const std = @import("std");
const gpu = @import("gpu");
const d12 = @import("gpu").Backend.native;
extern fn zenit_d12_test_live_shaders() c_long;
extern fn zenit_d12_test_shader_dispatch(*anyopaque, *anyopaque, *anyopaque, *anyopaque) void;
const program =
    \\RWStructuredBuffer<float> result:register(u0);
    \\[numthreads(4,1,1)] void compute_main(uint3 id:SV_DispatchThreadID){result[id.x]=17+id.x*3;}
    \\float4 vertex_main(uint id:SV_VertexID):SV_Position{return float4(id,0,0,1);}
    \\float4 fragment_main():SV_Target{return float4(1,0,0,1);}
;
const entries = [_]gpu.HlslEntryPoint{ .{ .name = "vertex_main", .stage = .vertex }, .{ .name = "fragment_main", .stage = .fragment }, .{ .name = "compute_main", .stage = .compute } };
fn expectError(expected: anyerror, result: anytype) !void {
    if (result) |_| return error.ExpectedFailure else |actual| if (actual != expected) return actual;
}
fn rejection(allocator: std.mem.Allocator, source: gpu.HlslSource, expected: anyerror, compiler_message: bool) !void {
    var diagnostic: ?[]u8 = null;
    defer if (diagnostic) |message| allocator.free(message);
    try expectError(expected, d12.ShaderModule.compileWithDiagnostics(allocator, source, &diagnostic));
    if (compiler_message and (diagnostic == null or diagnostic.?.len == 0)) return error.MissingCompilerDiagnostic;
    if (!compiler_message and diagnostic != null) return error.UnexpectedDiagnostic;
}
fn allocationFailures(allocator: std.mem.Allocator) !void {
    const baseline = zenit_d12_test_live_shaders();
    var failures: usize = 0;
    var first_success: ?usize = null;
    for (0..32) |fail_index| {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        var diagnostic: ?[]u8 = null;
        const a = failing.allocator();
        if (d12.ShaderModule.compileWithDiagnostics(a, .{ .code = program, .entry_points = &entries }, &diagnostic)) |result| {
            var module = result;
            module.deinit();
            first_success = fail_index;
        } else |err| {
            if (err != error.OutOfMemory) return err;
            failures += 1;
        }
        if (diagnostic) |message| a.free(message);
        if (failing.allocated_bytes != failing.freed_bytes or zenit_d12_test_live_shaders() != baseline) return error.ShaderFailureCleanupLeak;
        if (first_success != null) break;
    }
    if (first_success == null or failures < 3) return error.AllocationFailureCoverageMissing;
    std.debug.print("PASS: {d} shader allocator failure points, native shader count restored each time\n", .{failures});
}
pub fn run() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() != .ok) @panic("shader allocator leaked");
    const allocator = gpa.allocator();
    try allocationFailures(allocator);
    var device = try d12.Device.init(true);
    defer device.destroy();
    try rejection(allocator, .{ .code = "", .entry_points = &entries }, error.InvalidShaderDescriptor, false);
    try rejection(allocator, .{ .code = "abc\x00def", .entry_points = &entries }, error.InvalidShaderDescriptor, false);
    try rejection(allocator, .{ .code = program, .entry_points = &.{} }, error.InvalidShaderDescriptor, false);
    try rejection(allocator, .{ .code = program, .entry_points = &.{.{ .name = "", .stage = .compute }} }, error.InvalidShaderDescriptor, false);
    try rejection(allocator, .{ .code = program, .entry_points = &.{ entries[0], entries[0] } }, error.DuplicateShaderEntry, false);
    try rejection(allocator, .{ .code = "invalid HLSL syntax", .entry_points = &entries }, error.ShaderCompilationFailed, true);
    // A later entry fails after the first compiled: verify partial module cleanup.
    try rejection(allocator, .{ .code = program, .entry_points = &.{ entries[0], .{ .name = "missing", .stage = .compute } } }, error.ShaderCompilationFailed, true);
    try rejection(allocator, .{ .code = "#include \"nonexistent.hlsl\"\n" ++ program, .entry_points = &entries }, error.ShaderCompilationFailed, true);
    try expectError(error.UnsupportedShaderSource, device.createShaderModule(allocator, .{ .source = .{ .msl = "metal source" } }));
    var module = try device.createShaderModule(allocator, .{ .source = .{ .hlsl = .{ .code = program, .entry_points = &entries } } });
    var live = true;
    defer if (live) module.deinit();
    try expectError(error.FunctionNotFound, module.getFunction("unknown"));
    var vertex = try module.getFunction("vertex_main");
    defer vertex.deinit();
    var fragment = try module.getFunction("fragment_main");
    defer fragment.deinit();
    var compute = try module.getFunction("compute_main");
    defer compute.deinit();
    if (vertex.stage != .vertex or fragment.stage != .fragment or compute.stage != .compute) return error.IncorrectShaderStage;
    for ([_]*const d12.ShaderFunction{ &vertex, &fragment, &compute }) |function| {
        const bytes = function.bytecode();
        if (bytes.len < 32 or !std.mem.eql(u8, bytes[0..4], "DXBC")) return error.MissingShaderBytecode;
    }
    var queue = try device.createQueue();
    defer queue.deinit(5000) catch @panic("shader queue teardown failed");
    var output = try device.createBuffer(allocator, .{ .size = 16, .usage = .{ .storage = true, .copy_src = true } });
    defer output.destroy();
    var readback = try device.createBuffer(allocator, .{ .size = 16, .usage = .{ .map_read = true, .copy_dst = true } });
    defer readback.destroy();
    module.deinit();
    live = false;
    // Retained compiled function executes after its module and name storage die.
    zenit_d12_test_shader_dispatch(device.raw, queue.raw, compute.raw, output.raw);
    var encoder = try device.createCommandEncoder();
    defer encoder.deinit();
    try encoder.copyBufferToBuffer(&output, 0, &readback, 0, 16);
    var command = try encoder.finish();
    defer command.deinit();
    _ = try queue.submit(&.{command});
    try queue.waitIdle(5000);
    const bytes = try readback.getMappedRange(0, 16);
    for ([_]f32{ 17, 20, 23, 26 }, 0..) |expected, i| {
        var actual: f32 = undefined;
        @memcpy(std.mem.asBytes(&actual), bytes[i * 4 ..][0..4]);
        if (actual != expected) return error.IncorrectCompiledShaderOutput;
    }
    std.debug.print("PASS: production HLSL vertex/pixel/compute modules, owned diagnostics, partial failure cleanup, retained function GPU execution and no allocator leaks\n", .{});
}
