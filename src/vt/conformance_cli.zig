const std = @import("std");
const engine = @import("engine.zig");
const runner = @import("conformance_runner.zig");
const budget = @import("perf_budget.zig");
const adapter = @import("ghostty_adapter.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    var iterations: usize = 20; var warmup: usize = 2;
    var fixture: []const u8 = @embedFile("fixtures/conformance-smoke.vt");
    var fixture_file: ?[]const u8 = null;
    var args = init.minimal.args.iterate();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--iterations=")) iterations = try std.fmt.parseInt(usize, arg[13..], 10)
        else if (std.mem.startsWith(u8, arg, "--warmup=")) warmup = try std.fmt.parseInt(usize, arg[9..], 10)
        else if (std.mem.startsWith(u8, arg, "--fixture=")) fixture = arg[10..]
        else if (std.mem.startsWith(u8, arg, "--fixture-file=")) fixture_file = arg[15..]
        else if (std.mem.eql(u8, arg, "--help")) { std.debug.print("usage: vt-conformance-runner [--iterations=N] [--warmup=N] [--fixture=TEXT] [--fixture-file=PATH]\n", .{}); return; }
        else return error.InvalidArgument;
    }
    var loaded_fixture: ?[]u8 = null;
    defer if (loaded_fixture) |bytes| allocator.free(bytes);
    if (fixture_file) |path| {
        var fixture_io: std.Io.Threaded = .init(allocator, .{});
        defer fixture_io.deinit();
        loaded_fixture = try std.Io.Dir.cwd().readFileAlloc(fixture_io.io(), path, allocator, .limited(16 * 1024 * 1024));
        fixture = loaded_fixture.?;
    }
    var vt = try adapter.Adapter.init(allocator, 24, 80); defer vt.destroy();
    var result = try runner.run(allocator, engine.VtEngine.from(adapter.Adapter, &vt), fixture, .{ .warmup = warmup, .iterations = iterations }); defer result.deinit(allocator);
    const m = result.measurement; const limits: budget.Budget = .{}; var out_buffer: [4096]u8 = undefined; var out = std.Io.Writer.fixed(&out_buffer);
    try out.print("fixture=ghostty input_bytes={d} output_bytes={d} iterations={d} warmup={d}\n", .{ fixture.len, result.output_bytes, iterations, warmup });
    try out.print("samples.input_ns={any}\nsamples.projection_ns={any}\n", .{ result.input_samples_ns, result.projection_samples_ns });
    try out.print("measurement.memory_bytes={d} measurement.ui_cpu_percent=unavailable measurement.input_p95_ms={d:.3} measurement.projection_ms={d:.3}\n", .{ m.memory_bytes, m.input_p95_ms, m.projection_ms });
    try out.print("budget.memory={s} budget.ui_cpu=unavailable budget.input_latency={s} budget.projection_latency={s}\n", .{ if (m.memory_bytes <= limits.max_memory_bytes) "pass" else "fail", if (m.input_p95_ms <= limits.max_input_p95_ms) "pass" else "fail", if (m.projection_ms <= limits.max_projection_ms) "pass" else "fail" });
    if (result.firstFailure(limits)) |failure| { try out.print("result=fail first_failure={s}\n", .{@tagName(failure)}); return error.BudgetExceeded; }
    try out.print("result=pass (external RSS/CPU not sampled)\n", .{});
    var io_threaded: std.Io.Threaded = .init(allocator, .{});
    defer io_threaded.deinit();
    try std.Io.File.stdout().writeStreamingAll(io_threaded.io(), out.buffered());
}
