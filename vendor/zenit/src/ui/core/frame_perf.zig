//! Frame perf sample history, an independent value type used by `Cx`.
//!
//! `Sampler` is an independently testable ring buffer; `FramePerf` gathers four of them (frame
//! total / frame interval / drawable acquire / CPU-only frame). Touches no other `Cx` state;
//! `Cx` holds a single `frame_perf: FramePerf` field.

const std = @import("std");

/// Samples retained per path. 120 frames ~= 2 seconds @60Hz.
pub const history_size: usize = 120;

/// Fixed-capacity ring buffer + percentile/mean/extremum stats.
///
/// After full overwrite oldest; `len` monotone-grows until full, then constant at `history_size`.
pub const Sampler = struct {
    samples: [history_size]u64 = @as([history_size]u64, @splat(0)),
    /// Next write position, **always modulo samples.len**.
    ///
    /// WARNING - don't make this u8 relying on `+%= 1` wrap: u8 wraps at 256, but samples.len = 120
    /// and **120 doesn't divide 256**. After 256+ pushes `write % 120` no longer equals the true
    /// write
    /// position, so latest()/atFromOldest() read wrong slots (60fps: ~4.3 seconds), and DevTools
    /// frame interval readings silently alias to old samples.
    ///
    /// push takes an explicit modulo len, so wrap aligns with capacity regardless of width.
    write: usize = 0,
    len: u8 = 0,

    pub fn push(self: *Sampler, value: u64) void {
        self.samples[self.write] = value;
        self.write = (self.write + 1) % self.samples.len;
        if (@as(usize, self.len) < self.samples.len) self.len += 1;
    }

    pub fn reset(self: *Sampler) void {
        self.write = 0;
        self.len = 0;
        @memset(&self.samples, 0);
    }

    pub fn count(self: *const Sampler) usize {
        return @min(@as(usize, self.len), self.samples.len);
    }

    pub fn isEmpty(self: *const Sampler) bool {
        return self.count() == 0;
    }

    /// The `percentile` percentile (0-100, over 100 treated 100). null if empty.
    pub fn percentile(self: *const Sampler, pct: u8) ?u64 {
        const len = self.count();
        if (len == 0) return null;
        var sorted: [history_size]u64 = undefined;
        @memcpy(sorted[0..len], self.samples[0..len]);
        std.mem.sort(u64, sorted[0..len], {}, std.sort.asc(u64));
        const bounded = @min(pct, 100);
        return sorted[@min(len - 1, (len - 1) * @as(usize, bounded) / 100)];
    }

    pub fn average(self: *const Sampler) ?u64 {
        const len = self.count();
        if (len == 0) return null;
        var sum: u64 = 0;
        for (self.samples[0..len]) |s| sum += s;
        return sum / @as(u64, @intCast(len));
    }

    pub fn maximum(self: *const Sampler) ?u64 {
        const len = self.count();
        if (len == 0) return null;
        var result: u64 = 0;
        for (self.samples[0..len]) |s| result = @max(result, s);
        return result;
    }

    /// Most recent write sample.
    pub fn latest(self: *const Sampler) ?u64 {
        if (self.count() == 0) return null;
        const cap = self.samples.len;
        return self.samples[(self.write + cap - 1) % cap];
    }

    /// Get Nth sample in 'oldest to newest' order, null if out of bounds.
    /// DevTools frame interval bar chart uses this to read time-axis order.
    pub fn atFromOldest(self: *const Sampler, idx: usize) ?u64 {
        const len = self.count();
        if (idx >= len) return null;
        const cap = self.samples.len;
        const oldest = (self.write + cap - len) % cap;
        return self.samples[(oldest + idx) % cap];
    }
};

/// Four time cost paths for one frame render.
pub const FramePerf = struct {
    /// Most recent frame frame_start->frame_end wall clock total cost (us).
    frame_total_us: u64 = 0,
    /// Most recent frame true presentation rhythm interval (us, clamped per display refresh rate
    /// floor).
    frame_interval_us: u64 = 0,

    /// Full frame total cost history. Includes vsync wait, drawable acquire, frame-end idle.
    total: Sampler = .{},
    /// True presentation rhythm history.
    interval: Sampler = .{},
    /// drawable acquire cost history.
    acquire: Sampler = .{},
    /// **CPU section only** cost history.
    ///
    /// Differs from `total`, which stores wall clock including vsync wait, drawable acquire, and
    /// idle gaps after rendering. A P95 over `total` reports 26ms 'CPU P95' when the CPU spent 8ms
    /// but was stretched by display rhythm or (e2e) RPC round-trip; it looks like a stall but the
    /// CPU
    /// was idle. Judge 'render work within budget' with this one.
    cpu: Sampler = .{},

    pub fn pushFrameTotalUs(self: *FramePerf, value: u64) void {
        self.frame_total_us = value;
        self.total.push(value);
    }

    pub fn pushFrameIntervalUs(self: *FramePerf, value: u64) void {
        self.frame_interval_us = value;
        self.interval.push(value);
    }

    pub fn reset(self: *FramePerf) void {
        self.frame_total_us = 0;
        self.frame_interval_us = 0;
        self.total.reset();
        self.interval.reset();
        self.acquire.reset();
        self.cpu.reset();
    }
};

test "Sampler: 空时统计量全为 null" {
    var s = Sampler{};
    try std.testing.expect(s.isEmpty());
    try std.testing.expectEqual(@as(?u64, null), s.percentile(95));
    try std.testing.expectEqual(@as(?u64, null), s.average());
    try std.testing.expectEqual(@as(?u64, null), s.maximum());
    try std.testing.expectEqual(@as(?u64, null), s.latest());
    try std.testing.expectEqual(@as(?u64, null), s.atFromOldest(0));
}

test "Sampler: 基本统计" {
    var s = Sampler{};
    for ([_]u64{ 10, 20, 30, 40 }) |v| s.push(v);
    try std.testing.expectEqual(@as(usize, 4), s.count());
    try std.testing.expectEqual(@as(?u64, 40), s.latest());
    try std.testing.expectEqual(@as(?u64, 40), s.maximum());
    try std.testing.expectEqual(@as(?u64, 25), s.average());
    try std.testing.expectEqual(@as(?u64, 10), s.percentile(0));
    try std.testing.expectEqual(@as(?u64, 40), s.percentile(100));
}

test "Sampler: 写满后覆盖最旧，len 封顶" {
    var s = Sampler{};
    for (0..history_size + 10) |i| s.push(@intCast(i));
    try std.testing.expectEqual(history_size, s.count());
    try std.testing.expectEqual(@as(?u64, history_size + 9), s.latest());
    // Oldest sample should be 10th (0..9 overwritten)
    try std.testing.expectEqual(@as(?u64, 10), s.atFromOldest(0));
    try std.testing.expectEqual(@as(?u64, null), s.atFromOldest(history_size));
}

test "Sampler: atFromOldest 在回绕后仍按时间序" {
    var s = Sampler{};
    for (0..history_size + 5) |i| s.push(@intCast(i * 2));
    var prev: u64 = 0;
    for (0..s.count()) |i| {
        const v = s.atFromOldest(i).?;
        if (i > 0) try std.testing.expect(v > prev);
        prev = v;
    }
}

test "Sampler: percentile 超过 100 按 100 处理" {
    var s = Sampler{};
    for ([_]u64{ 1, 2, 3 }) |v| s.push(v);
    try std.testing.expectEqual(s.percentile(100), s.percentile(200));
}

test "Sampler: reset 清空" {
    var s = Sampler{};
    for ([_]u64{ 5, 6, 7 }) |v| s.push(v);
    s.reset();
    try std.testing.expect(s.isEmpty());
    try std.testing.expectEqual(@as(?u64, null), s.latest());
}

test "FramePerf: push 同时更新 latest 标量与历史" {
    var p = FramePerf{};
    p.pushFrameTotalUs(100);
    p.pushFrameIntervalUs(200);
    p.acquire.push(30);
    p.cpu.push(40);

    try std.testing.expectEqual(@as(u64, 100), p.frame_total_us);
    try std.testing.expectEqual(@as(u64, 200), p.frame_interval_us);
    try std.testing.expectEqual(@as(?u64, 100), p.total.latest());
    try std.testing.expectEqual(@as(?u64, 200), p.interval.latest());
    try std.testing.expectEqual(@as(?u64, 30), p.acquire.latest());
    try std.testing.expectEqual(@as(?u64, 40), p.cpu.latest());

    p.reset();
    try std.testing.expectEqual(@as(u64, 0), p.frame_total_us);
    try std.testing.expectEqual(@as(u64, 0), p.frame_interval_us);
    try std.testing.expect(p.total.isEmpty());
    try std.testing.expect(p.cpu.isEmpty());
}

test "Sampler: write 计数器回绕 256 之后仍指向正确样本" {
    // Regression test: write is u8 and wraps at 256, but samples length is 120 and
    // **120 doesn't divide 256**. After 256+ pushes `write % 120` no longer equals the
    // true write position, so latest()/atFromOldest() read wrong slots.
    //
    // At 60fps this hits after 257 frames (~4.3 seconds); DevTools frame interval readings
    // silently alias to old samples.
    var s = Sampler{};
    for (0..300) |i| s.push(@intCast(i));

    // 300th push writes value 299
    try std.testing.expectEqual(@as(?u64, 299), s.latest());

    // Oldest should be 300-120 = 180
    try std.testing.expectEqual(@as(?u64, 180), s.atFromOldest(0));
    try std.testing.expectEqual(@as(?u64, 299), s.atFromOldest(119));

    // Oldest to newest must strictly increase (wrap can't scramble time)
    var prev: u64 = 0;
    for (0..s.count()) |i| {
        const v = s.atFromOldest(i).?;
        if (i > 0) try std.testing.expect(v == prev + 1);
        prev = v;
    }
}
