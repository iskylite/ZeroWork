const std = @import("std");

/// Product acceptance budgets from DESIGN 01§8. This module only evaluates
/// measurements supplied by an external benchmark; it never fabricates them.
pub const Budget = struct {
    max_memory_bytes: usize = 120 * 1024 * 1024,
    max_ui_cpu_percent: f32 = 15.0,
    max_input_p95_ms: f32 = 50.0,
    max_projection_ms: f32 = 16.0,
};

pub const Measurement = struct {
    memory_bytes: usize,
    ui_cpu_percent: f32,
    input_p95_ms: f32,
    projection_ms: f32,
};

pub const Failure = enum { memory, ui_cpu, input_latency, projection_latency };
pub const ProjectionSample = struct { bytes: usize, elapsed_ns: u64 };

pub fn projectionMilliseconds(sample: ProjectionSample) f32 {
    if (sample.bytes == 0) return 0;
    return @as(f32, @floatFromInt(sample.elapsed_ns)) / 1_000_000.0;
}

pub fn firstFailure(budget: Budget, measurement: Measurement) ?Failure {
    if (measurement.memory_bytes > budget.max_memory_bytes) return .memory;
    if (measurement.ui_cpu_percent > budget.max_ui_cpu_percent) return .ui_cpu;
    if (measurement.input_p95_ms > budget.max_input_p95_ms) return .input_latency;
    if (measurement.projection_ms > budget.max_projection_ms) return .projection_latency;
    return null;
}

test "projection sample converts nanoseconds to milliseconds" {
    try std.testing.expectEqual(@as(f32, 4.5), projectionMilliseconds(.{ .bytes = 1024, .elapsed_ns = 4_500_000 }));
    try std.testing.expectEqual(@as(f32, 0), projectionMilliseconds(.{ .bytes = 0, .elapsed_ns = 99 }));
}

test "performance budget accepts baseline measurement" {
    const budget: Budget = .{};
    try std.testing.expect(firstFailure(budget, .{ .memory_bytes = 100 * 1024 * 1024, .ui_cpu_percent = 9.5, .input_p95_ms = 21, .projection_ms = 4 }) == null);
}

test "performance budget reports first failing acceptance dimension" {
    const budget: Budget = .{};
    try std.testing.expectEqual(Failure.memory, firstFailure(budget, .{ .memory_bytes = 121 * 1024 * 1024, .ui_cpu_percent = 99, .input_p95_ms = 99, .projection_ms = 99 }).?);
    try std.testing.expectEqual(Failure.input_latency, firstFailure(budget, .{ .memory_bytes = 1, .ui_cpu_percent = 1, .input_p95_ms = 51, .projection_ms = 1 }).?);
}
