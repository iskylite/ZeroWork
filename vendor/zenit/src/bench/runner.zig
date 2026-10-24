//! Bench runner, perf baseline tool.
//!
//! Design goals:
//! - Simple and repeatable: black-box timing + warmup + median of multiple samples
//! - Dual output: human stdout table + machine JSON (for CI diff)
//! - No external crates; pure std
//! - Each bench registers name + setup + body; the runner executes them uniformly
//!
//! Usage: register cases in src/bench/main.zig, add a bench step in build.zig:
//!     zig build bench               # run all
//!     zig build bench -- name=...   # filter
//!     zig build bench -- json=path  # output JSON

const std = @import("std");

pub const BenchOptions = struct {
    /// Warmup iterations (not measured).
    warmup_iters: u32 = 5,
    /// Measurement samples (median + p95).
    sample_iters: u32 = 50,
    /// Inner loop iterations per sample (amortize small-op noise). 0 = adaptive.
    inner_iters: u32 = 0,
    /// Single case total time soft limit (ns), timeout early exit, prevent slow case hanging CI.
    soft_budget_ns: u64 = 5 * std.time.ns_per_s,
};

pub const BenchResult = struct {
    name: []const u8,
    iters_per_sample: u32,
    samples: u32,
    median_ns_per_iter: f64,
    p95_ns_per_iter: f64,
    min_ns_per_iter: f64,
    mean_ns_per_iter: f64,
};

pub const BenchFn = *const fn (allocator: std.mem.Allocator, ctx: *BenchCtx) anyerror!void;

pub const BenchCase = struct {
    name: []const u8,
    setup: ?*const fn (allocator: std.mem.Allocator, io: std.Io) anyerror!*anyopaque = null,
    teardown: ?*const fn (allocator: std.mem.Allocator, state: *anyopaque) void = null,
    body: BenchFn,
    opts: BenchOptions = .{},
};

/// Runtime context, body can read setup output + control inner loop.
pub const BenchCtx = struct {
    state: ?*anyopaque,
    iter_index: u32,

    /// Prevent LLVM dead-code-eliminating body result.
    pub fn blackbox(self: *BenchCtx, value: anytype) void {
        _ = self;
        // Force volatile sink write; LLVM can't optimize away.
        const T = @TypeOf(value);
        std.mem.doNotOptimizeAway(@as(T, value));
    }
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    cases: []const BenchCase,
    filter: ?[]const u8,
    json_out: ?std.Io.File,
) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const w = &stdout_w.interface;

    try w.print("\n{s:<48} {s:>14} {s:>14} {s:>14}\n", .{ "name", "median ns/it", "p95 ns/it", "min ns/it" });
    try w.print("{s:-<48} {s:->14} {s:->14} {s:->14}\n", .{ "", "", "", "" });
    try w.flush();

    var results = std.ArrayList(BenchResult).empty;
    defer results.deinit(allocator);

    for (cases) |case| {
        if (filter) |f| {
            if (std.mem.indexOf(u8, case.name, f) == null) continue;
        }
        const r = runCase(allocator, io, case) catch |err| {
            try w.print("{s:<48} ERROR: {s}\n", .{ case.name, @errorName(err) });
            try w.flush();
            continue;
        };
        try w.print("{s:<48} {d:>14.1} {d:>14.1} {d:>14.1}\n", .{
            r.name,
            r.median_ns_per_iter,
            r.p95_ns_per_iter,
            r.min_ns_per_iter,
        });
        try w.flush();
        try results.append(allocator, r);
    }

    try w.flush();

    if (json_out) |f| {
        var json_buffer: [4096]u8 = undefined;
        var json_w = f.writerStreaming(io, &json_buffer);
        const jw = &json_w.interface;
        // Traceability: baseline with bare numbers, can't judge if gate failed from code regression
        // or machine/load change. src/bench/baselines/main.json went red for 1+ months from missing
        // commit. ZENIT_BENCH_COMMIT injected by CI / refresh script; local run defaults "unknown",
        // doesn't affect comparison, only traceability.
        const commit = @import("zenit_environment").getOwned(allocator, "ZENIT_BENCH_COMMIT") catch null;
        defer if (commit) |c| allocator.free(c);
        const host = @import("zenit_environment").getOwned(allocator, "ZENIT_BENCH_HOST") catch null;
        defer if (host) |h| allocator.free(h);
        try jw.print(
            "{{\n  \"commit\": \"{s}\",\n  \"host\": \"{s}\",\n  \"unix_time\": {d},\n  \"results\": [\n",
            .{ commit orelse "unknown", host orelse "unknown", std.Io.Clock.real.now(io).toSeconds() },
        );
        for (results.items, 0..) |r, i| {
            try jw.print(
                "    {{\"name\":\"{s}\",\"median_ns\":{d:.3},\"p95_ns\":{d:.3},\"min_ns\":{d:.3},\"mean_ns\":{d:.3},\"samples\":{d},\"iters_per_sample\":{d}}}{s}\n",
                .{ r.name, r.median_ns_per_iter, r.p95_ns_per_iter, r.min_ns_per_iter, r.mean_ns_per_iter, r.samples, r.iters_per_sample, if (i + 1 == results.items.len) "" else "," },
            );
        }
        try jw.writeAll("  ]\n}\n");
        try jw.flush();
    }
}

fn runCase(allocator: std.mem.Allocator, io: std.Io, case: BenchCase) !BenchResult {
    const state: ?*anyopaque = if (case.setup) |s| try s(allocator, io) else null;
    defer if (case.teardown) |t| {
        if (state) |st| t(allocator, st);
    };

    var inner = case.opts.inner_iters;
    if (inner == 0) {
        inner = try calibrateInner(allocator, io, case, state);
    }

    // Warmup
    var ctx = BenchCtx{ .state = state, .iter_index = 0 };
    var i: u32 = 0;
    while (i < case.opts.warmup_iters) : (i += 1) {
        ctx.iter_index = i;
        var j: u32 = 0;
        while (j < inner) : (j += 1) {
            try case.body(allocator, &ctx);
        }
    }

    // Sample
    const samples = try allocator.alloc(f64, case.opts.sample_iters);
    defer allocator.free(samples);
    const t_start = std.Io.Clock.awake.now(io).toNanoseconds();
    var s_i: u32 = 0;
    while (s_i < case.opts.sample_iters) : (s_i += 1) {
        const t0 = std.Io.Clock.awake.now(io).toNanoseconds();
        var k: u32 = 0;
        while (k < inner) : (k += 1) {
            ctx.iter_index = s_i * inner + k;
            try case.body(allocator, &ctx);
        }
        const t1 = std.Io.Clock.awake.now(io).toNanoseconds();
        const elapsed: f64 = @floatFromInt(t1 - t0);
        samples[s_i] = elapsed / @as(f64, @floatFromInt(inner));

        // Soft budget overrun early exit.
        if (@as(u64, @intCast(t1 - t_start)) > case.opts.soft_budget_ns) {
            break;
        }
    }
    const used = s_i;
    const slice = samples[0..used];

    std.mem.sort(f64, slice, {}, std.sort.asc(f64));
    const median = slice[used / 2];
    const p95 = slice[@min(used - 1, (used * 95) / 100)];
    const min_v = slice[0];

    var sum: f64 = 0;
    for (slice) |v| sum += v;
    const mean_v = sum / @as(f64, @floatFromInt(used));

    return .{
        .name = case.name,
        .iters_per_sample = inner,
        .samples = used,
        .median_ns_per_iter = median,
        .p95_ns_per_iter = p95,
        .min_ns_per_iter = min_v,
        .mean_ns_per_iter = mean_v,
    };
}

/// Adaptive inner iteration count: make each sample take at least ~50us so timer jitter does not
/// dominate.
fn calibrateInner(allocator: std.mem.Allocator, io: std.Io, case: BenchCase, state: ?*anyopaque) !u32 {
    var inner: u32 = 1;
    while (inner < 1_000_000) : (inner *= 2) {
        var ctx = BenchCtx{ .state = state, .iter_index = 0 };
        const t0 = std.Io.Clock.awake.now(io).toNanoseconds();
        var j: u32 = 0;
        while (j < inner) : (j += 1) {
            try case.body(allocator, &ctx);
        }
        const t1 = std.Io.Clock.awake.now(io).toNanoseconds();
        const elapsed: u64 = @intCast(t1 - t0);
        if (elapsed >= 50_000) return inner;
    }
    return 1_000_000;
}
