const std = @import("std");
const VtEngine = @import("engine.zig").VtEngine;
const perf = @import("perf_budget.zig");

pub const Options = struct {
    warmup: usize = 2,
    iterations: usize = 20,
};

pub const Result = struct {
    measurement: perf.Measurement,
    input_samples_ns: []u64,
    projection_samples_ns: []u64,
    output_bytes: usize,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.input_samples_ns);
        allocator.free(self.projection_samples_ns);
        self.* = undefined;
    }

    pub fn firstFailure(self: Result, budget: perf.Budget) ?perf.Failure {
        return perf.firstFailure(budget, self.measurement);
    }
};

/// Runs deterministic feed -> projection samples against any VtEngine adapter.
/// The memory figure is an explicit observed working-set estimate: input bytes,
/// projected output bytes, and both sample arrays. It intentionally does not
/// pretend to be a process RSS measurement.
pub fn run(
    allocator: std.mem.Allocator,
    engine: VtEngine,
    input: []const u8,
    options: Options,
) !Result {
    if (options.iterations == 0) return error.InvalidIterations;
    var input_samples = try allocator.alloc(u64, options.iterations);
    errdefer allocator.free(input_samples);
    var projection_samples = try allocator.alloc(u64, options.iterations);
    errdefer allocator.free(projection_samples);
    var output_bytes: usize = 0;

    for (0..options.warmup) |_| {
        _ = try engine.feed(input);
        const text = try renderText(engine, allocator);
        allocator.free(text);
    }
    for (0..options.iterations) |index| {
        const input_start = monotonicNs();
        _ = try engine.feed(input);
        input_samples[index] = monotonicNs() - input_start;
        const projection_start = monotonicNs();
        const text = try renderText(engine, allocator);
        projection_samples[index] = monotonicNs() - projection_start;
        output_bytes = text.len;
        allocator.free(text);
    }
    std.sort.heap(u64, input_samples, {}, std.sort.asc(u64));
    std.sort.heap(u64, projection_samples, {}, std.sort.asc(u64));
    const input_p95 = percentile(input_samples, 95);
    const projection_p95 = percentile(projection_samples, 95);
    const memory = input.len + output_bytes + input_samples.len * @sizeOf(u64) + projection_samples.len * @sizeOf(u64);
    return .{
        .measurement = .{
            .memory_bytes = memory,
            .ui_cpu_percent = 0,
            .input_p95_ms = @as(f32, @floatFromInt(input_p95)) / 1_000_000.0,
            .projection_ms = @as(f32, @floatFromInt(projection_p95)) / 1_000_000.0,
        },
        .input_samples_ns = input_samples,
        .projection_samples_ns = projection_samples,
        .output_bytes = output_bytes,
    };
}

fn renderText(vt: VtEngine, allocator: std.mem.Allocator) ![]u8 {
    const snapshot = vt.snapshot();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    for (0..snapshot.rows) |row| {
        if (vt.lineAt(snapshot.scroll_offset + row)) |line| {
            var end = line.cells.len;
            while (end > 0 and (line.cells[end - 1].codepoint == 0 or line.cells[end - 1].codepoint == ' ')) end -= 1;
            for (line.cells[0..end]) |cell| if (cell.width != .wide_tail) {
                var bytes: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(if (cell.codepoint == 0) ' ' else cell.codepoint, &bytes) catch 1;
                try output.appendSlice(allocator, bytes[0..n]);
            };
        }
        if (row + 1 < snapshot.rows) try output.append(allocator, '\n');
    }
    return output.toOwnedSlice(allocator);
}

fn monotonicNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn percentile(sorted: []const u64, percentile_value: usize) u64 {
    const index = @min(sorted.len - 1, (sorted.len * percentile_value + 99) / 100 - 1);
    return sorted[index];
}

const Probe = struct {
    versions: [1]u64 = .{1},
    cells: [8]@import("cell.zig").Cell = .{
        @import("cell.zig").Cell.fromCodepoint('o'), @import("cell.zig").Cell.fromCodepoint('k'), .{}, .{},
        .{}, .{}, .{}, .{},
    },
    pub fn destroy(_: *Probe) void {}
    pub fn feed(_: *Probe, _: []const u8) !@import("engine.zig").FeedResult { return .{ .dirty_pages = &.{}, .cursor_moved = true, .bell = false }; }
    pub fn resize(_: *Probe, _: u16, _: u16) !void {}
    pub fn snapshot(_: *Probe) @import("engine.zig").Snapshot { return .{ .cols = 4, .rows = 2, .cursor = .{}, .page_versions = &.{1}, .scroll_offset = 0 }; }
    pub fn lineAt(self: *Probe, row: u64) ?@import("engine.zig").LineView {
        if (row >= 2) return null;
        const start: usize = @intCast(row * 4);
        return .{ .abs_row = row, .cells = self.cells[start .. start + 4], .received_at_ms = 0 };
    }
    pub fn selectionText(_: *Probe, _: @import("engine.zig").Selection, _: @import("engine.zig").CopyMode, allocator: std.mem.Allocator) ![]u8 { return allocator.dupe(u8, ""); }
    pub fn setOscCallback(_: *Probe, _: ?@import("engine.zig").OscCallback) void {}
};

test "conformance runner samples feed and projection p95" {
    var probe: Probe = .{};
    var result = try run(std.testing.allocator, VtEngine.from(Probe, &probe), "\x1b[2J", .{ .warmup = 1, .iterations = 5 });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), result.output_bytes);
    try std.testing.expect(result.input_samples_ns.len == 5);
    try std.testing.expect(result.measurement.input_p95_ms >= 0);
    try std.testing.expect(result.firstFailure(.{}) == null or result.firstFailure(.{}) == .projection_latency);
}

test "conformance runner rejects empty sample count" {
    var probe: Probe = .{};
    try std.testing.expectError(error.InvalidIterations, run(std.testing.allocator, VtEngine.from(Probe, &probe), "x", .{ .iterations = 0 }));
}
