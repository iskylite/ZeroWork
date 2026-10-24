//! timing_ring: cross-frame timing sample ring (noise-resistant statistics source
//! for the GPU perf gate). Deliberately standalone and **imports no zenit modules**:
//! renderer.zig pulls the Metal/ObjC bridge and can't compile in the normal test
//! target; percentile math is pure logic and must be covered by `zig build test`,
//! or the gate looks present but never runs.

const std = @import("std");

/// One frame's timing sample (subset of renderer.FrameStats timing).
pub const Sample = struct {
    gpu_execute_us: u64 = 0,
    cpu_frame_us: u64 = 0,
    total_frame_us: u64 = 0,
};

/// Single-frame timing can't be asserted: drawable fetch, dispatch jitter and
/// first-frame PSO compile cause huge variance, so any single-frame threshold is
/// permanently green or randomly red. Gates use 'P95 of last N frames'. The ring
/// collects **only frames that actually rendered** (frame() full path push);
/// idle-skip frames stay out, else many near-zero samples tank P95 into a false green.
pub const TimingRing = struct {
    pub const CAPACITY = 120;

    gpu_execute_us: [CAPACITY]u64 = @splat(0),
    cpu_frame_us: [CAPACITY]u64 = @splat(0),
    total_frame_us: [CAPACITY]u64 = @splat(0),
    /// Ring write cursor.
    head: usize = 0,
    /// Valid sample count (max CAPACITY).
    len: usize = 0,

    pub fn push(self: *TimingRing, s: Sample) void {
        self.gpu_execute_us[self.head] = s.gpu_execute_us;
        self.cpu_frame_us[self.head] = s.cpu_frame_us;
        self.total_frame_us[self.head] = s.total_frame_us;
        self.head = (self.head + 1) % CAPACITY;
        if (self.len < CAPACITY) self.len += 1;
    }

    pub fn reset(self: *TimingRing) void {
        self.head = 0;
        self.len = 0;
    }

    /// P-th percentile (p in [0,100]), nearest-rank: after sort take
    /// ceil(p/100*n)-th rank (1-based). No samples return 0.
    fn percentileOf(samples: []const u64, len: usize, p: u32) u64 {
        if (len == 0) return 0;
        var buf: [CAPACITY]u64 = undefined;
        @memcpy(buf[0..len], samples[0..len]);
        std.mem.sort(u64, buf[0..len], {}, std.sort.asc(u64));
        const rank = (@as(usize, p) * len + 99) / 100;
        const idx = if (rank == 0) 0 else rank - 1;
        return buf[@min(idx, len - 1)];
    }

    pub fn gpuPercentile(self: *const TimingRing, p: u32) u64 {
        return percentileOf(&self.gpu_execute_us, self.len, p);
    }
    pub fn cpuPercentile(self: *const TimingRing, p: u32) u64 {
        return percentileOf(&self.cpu_frame_us, self.len, p);
    }
    pub fn totalPercentile(self: *const TimingRing, p: u32) u64 {
        return percentileOf(&self.total_frame_us, self.len, p);
    }
};

/// Frame interval sample exceeding this threshold is idle-resume gap (first
/// frame after pause); discard no sample. Not stutter; idle pause is framework
/// power-saving; showing red / lowering FPS is false positive.
pub const IDLE_RESUME_GAP_US: u64 = 500_000;

/// DevTools FPS sample window (pure function for unit testing):
/// - interval > IDLE_RESUME_GAP_US -> null (idle resume frame, skip history);
/// - else clamp to >= display refresh period: event bursts can shrink frame intervals far below
///   vsync period, clamping prevents false FPS above refresh rate.
pub fn frameIntervalSampleUs(raw_interval_us: u64, display_period_us: u64) ?u64 {
    if (raw_interval_us > IDLE_RESUME_GAP_US) return null;
    return @max(raw_interval_us, display_period_us);
}

// ── tests ──

const testing = std.testing;

test "TimingRing: 空环所有百分位为 0" {
    const ring = TimingRing{};
    try testing.expectEqual(@as(u64, 0), ring.gpuPercentile(95));
    try testing.expectEqual(@as(u64, 0), ring.cpuPercentile(50));
    try testing.expectEqual(@as(u64, 0), ring.totalPercentile(100));
}

test "TimingRing: nearest-rank 百分位取值正确" {
    var ring = TimingRing{};
    // One sample each for 1..100 microseconds.
    var i: u64 = 1;
    while (i <= 100) : (i += 1) {
        ring.push(.{ .gpu_execute_us = i });
    }
    try testing.expectEqual(@as(usize, 100), ring.len);
    // nearest-rank: P95 -> 95th rank -> value 95; P50 -> 50th rank -> 50.
    try testing.expectEqual(@as(u64, 95), ring.gpuPercentile(95));
    try testing.expectEqual(@as(u64, 50), ring.gpuPercentile(50));
    try testing.expectEqual(@as(u64, 100), ring.gpuPercentile(100));
    try testing.expectEqual(@as(u64, 1), ring.gpuPercentile(0));
}

test "TimingRing: nearest-rank 用 ceil 而非 floor（样本数非 100 倍数时才可区分）" {
    // n=10: P95's ceil(0.95*10)=10 -> 10th rank; floor gives 9th. Last case n=100
    // both are equal, can't distinguish truncation direction; add this case or change
    // ceil to floor and test still green (measured false signal).
    var ring = TimingRing{};
    var i: u64 = 1;
    while (i <= 10) : (i += 1) ring.push(.{ .gpu_execute_us = i * 10 });
    try testing.expectEqual(@as(u64, 100), ring.gpuPercentile(95)); // 10th rank.
    try testing.expectEqual(@as(u64, 30), ring.gpuPercentile(25)); // ceil(2.5)=3 -> 3rd rank.
    try testing.expectEqual(@as(u64, 10), ring.gpuPercentile(1)); // ceil(0.1)=1 -> 1st rank.
}

test "TimingRing: 单个离群值不会污染 P95（抗噪的核心性质）" {
    var ring = TimingRing{};
    var i: usize = 0;
    while (i < 100) : (i += 1) ring.push(.{ .gpu_execute_us = 1000 });
    // One 100ms outlier frame.
    ring.push(.{ .gpu_execute_us = 100_000 });
    // P95 should still be steady-state, not outlier, or gate randomly pulled red by
    // single-frame jitter.
    try testing.expectEqual(@as(u64, 1000), ring.gpuPercentile(95));
    try testing.expectEqual(@as(u64, 100_000), ring.gpuPercentile(100));
}

test "TimingRing: 持续变慢会推高 P95（门禁必须能变红）" {
    var ring = TimingRing{};
    var i: usize = 0;
    while (i < TimingRing.CAPACITY) : (i += 1) ring.push(.{ .gpu_execute_us = 1000 });
    try testing.expectEqual(@as(u64, 1000), ring.gpuPercentile(95));
    // Entire ring filled with slow frames -> P95 must rise (reverse verify logic
    // base).
    i = 0;
    while (i < TimingRing.CAPACITY) : (i += 1) ring.push(.{ .gpu_execute_us = 20_000 });
    try testing.expectEqual(@as(u64, 20_000), ring.gpuPercentile(95));
}

test "TimingRing: 环绕后只保留最近 CAPACITY 个样本" {
    var ring = TimingRing{};
    // Fill entire ring with slow samples, then fill entire ring with fast samples.
    var i: usize = 0;
    while (i < TimingRing.CAPACITY) : (i += 1) ring.push(.{ .cpu_frame_us = 9999 });
    i = 0;
    while (i < TimingRing.CAPACITY) : (i += 1) ring.push(.{ .cpu_frame_us = 7 });
    try testing.expectEqual(@as(usize, TimingRing.CAPACITY), ring.len);
    // Old 9999 should be completely squeezed out.
    try testing.expectEqual(@as(u64, 7), ring.cpuPercentile(100));
}

test "TimingRing: 三路计时各自独立统计" {
    var ring = TimingRing{};
    ring.push(.{ .gpu_execute_us = 10, .cpu_frame_us = 20, .total_frame_us = 30 });
    ring.push(.{ .gpu_execute_us = 11, .cpu_frame_us = 21, .total_frame_us = 31 });
    try testing.expectEqual(@as(u64, 11), ring.gpuPercentile(100));
    try testing.expectEqual(@as(u64, 21), ring.cpuPercentile(100));
    try testing.expectEqual(@as(u64, 31), ring.totalPercentile(100));
}

test "TimingRing: reset 清空样本" {
    var ring = TimingRing{};
    ring.push(.{ .gpu_execute_us = 500 });
    ring.reset();
    try testing.expectEqual(@as(usize, 0), ring.len);
    try testing.expectEqual(@as(u64, 0), ring.gpuPercentile(95));
}

test "frameIntervalSampleUs: 正常间隔原样通过" {
    try testing.expectEqual(@as(?u64, 20_000), frameIntervalSampleUs(20_000, 16_666));
}

test "frameIntervalSampleUs: 短于刷新周期被钳到周期（FPS 不超刷新率）" {
    try testing.expectEqual(@as(?u64, 16_666), frameIntervalSampleUs(2_000, 16_666));
}

test "frameIntervalSampleUs: idle-resume gap 丢弃" {
    try testing.expectEqual(@as(?u64, null), frameIntervalSampleUs(IDLE_RESUME_GAP_US + 1, 16_666));
    // Boundary: exactly at threshold still counts as slow frame, retain.
    try testing.expectEqual(@as(?u64, IDLE_RESUME_GAP_US), frameIntervalSampleUs(IDLE_RESUME_GAP_US, 16_666));
}
test {
    _ = @import("render_pacing.zig");
}
