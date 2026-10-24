const std = @import("std");
const engine = @import("vt_engine");
const runner = @import("vt_runner");
const budget = @import("vt_budget");
const adapter = @import("vt_libvterm");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var iterations: usize = 20;
    var warmup: usize = 2;
    var fixture: []const u8 = "\x1b[2J\x1b[HZeroWork VT fixture\r\n\x1b[32m界\x1b[0m\r\n";
    var args = std.process.args();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--iterations=")) iterations = try std.fmt.parseInt(usize, arg[13..], 10)
        else if (std.mem.startsWith(u8, arg, "--warmup=")) warmup = try std.fmt.parseInt(usize, arg[9..], 10)
        else if (std.mem.startsWith(u8, arg, "--fixture=")) fixture = arg[10..]
        else if (std.mem.eql(u8, arg, "--help")) { printHelp(); return; }
        else return error.InvalidArgument;
    }

    var vt = try adapter.Adapter.init(allocator, 24, 80);
    defer vt.destroy();
    const result = try runner.run(allocator, engine.VtEngine.from(adapter.Adapter, &vt), fixture, .{ .warmup = warmup, .iterations = iterations });
    defer result.deinit(allocator);
    const measurement = result.measurement;
    const limits: budget.Budget = .{};
    const out = std.io.getStdOut().writer();
    try out.print("fixture=libvterm input_bytes={d} output_bytes={d} iterations={d} warmup={d}\n", .{ fixture.len, result.output_bytes, iterations, warmup });
    try out.print("samples.input_ns={any}\nsamples.projection_ns={any}\n", .{ result.input_samples_ns, result.projection_samples_ns });
    try out.print("measurement.memory_bytes={d} measurement.ui_cpu_percent=unavailable measurement.input_p95_ms={d:.3} measurement.projection_ms={d:.3}\n", .{ measurement.memory_bytes, measurement.input_p95_ms, measurement.projection_ms });
    try out.print("budget.memory={s} budget.ui_cpu=unavailable budget.input_latency={s} budget.projection_latency={s}\n", .{
        if (measurement.memory_bytes <= limits.max_memory_bytes) "pass" else "fail",
        if (measurement.input_p95_ms <= limits.max_input_p95_ms) "pass" else "fail",
        if (measurement.projection_ms <= limits.max_projection_ms) "pass" else "fail",
    });
    if (result.firstFailure(.{})) |failure| {
        if (failure == .ui_cpu) return error.BudgetExceeded;
        try out.print("result=fail first_failure={s}\n", .{@tagName(failure)});
        return error.BudgetExceeded;
    }
    try out.print("result=pass (external RSS/CPU not sampled)\n", .{});
}

fn printHelp() void {
    std.debug.print("usage: vt-conformance-runner [--iterations=N] [--warmup=N] [--fixture=TEXT]\n", .{});
}
