//! Main-thread, allocation-free video counters. A render-loop iteration is not
//! a video frame: presentation requires a successful window submission and a
//! new (generation, revision) selected by the video view in that UI frame.
const std = @import("std");

pub const Meter = struct {
    const Bucket = struct { tick: u64 = std.math.maxInt(u64), count: u64 = 0, max_gap_ms: u64 = 0 };
    buckets: [100]Bucket = @splat(.{}),
    started_ms: ?u64 = null,
    last_ms: ?u64 = null,

    pub fn record(self: *Meter, now: u64, count: u64) void {
        if (count == 0) return;
        if (self.last_ms) |last| {
            if (now < last) self.* = .{};
        }
        if (self.started_ms == null) self.started_ms = now;
        const tick = now / 100;
        const bucket = &self.buckets[tick % self.buckets.len];
        if (bucket.tick != tick) bucket.* = .{ .tick = tick };
        bucket.count +|= count;
        if (self.last_ms) |last| bucket.max_gap_ms = @max(bucket.max_gap_ms, now - last);
        self.last_ms = now;
    }

    /// One-second rolling count in 100 ms buckets. Keep warmup distinct from 0.
    pub fn fps(self: *const Meter, now: u64) ?f64 {
        const start = self.started_ms orelse return null;
        if (now < start or now - start < 1000) return null;
        const tick = now / 100;
        var count: u64 = 0;
        for (self.buckets) |b| if (b.tick <= tick and tick - b.tick < 10) {
            count +|= b.count;
        };
        return @floatFromInt(count);
    }

    pub fn maxGap(self: *const Meter, now: u64) u64 {
        const tick = now / 100;
        var gap: u64 = 0;
        for (self.buckets) |b| if (b.tick <= tick and tick - b.tick < 100) {
            gap = @max(gap, b.max_gap_ms);
        };
        return gap;
    }
};

pub const Presentation = struct {
    const Candidate = struct { ui_frame: u64, generation: u64, revision: u64 };
    candidate: ?Candidate = null,
    last_render_frame: ?u64 = null,
    generation: u64 = 0,
    revision: u64 = 0,
    meter: Meter = .{},

    pub fn stage(self: *Presentation, ui_frame: u64, generation: u64, revision: u64) void {
        self.candidate = if (generation != 0 and revision != 0) .{ .ui_frame = ui_frame, .generation = generation, .revision = revision } else null;
    }

    pub fn finish(self: *Presentation, ui_frame: u64, render_frame: u64, presented: bool, now_ms: u64) void {
        if (!presented or self.last_render_frame == render_frame) return;
        self.last_render_frame = render_frame;
        const c = self.candidate orelse return;
        if (c.ui_frame != ui_frame) return;
        if (c.generation == self.generation and c.revision <= self.revision) return;
        if (c.generation != self.generation) self.meter = .{};
        self.generation = c.generation;
        self.revision = c.revision;
        self.meter.record(now_ms, 1);
    }
};

test "BMC FPS counts new presented video revisions, not redraws or failed submissions" {
    var p: Presentation = .{};
    p.stage(1, 1, 10);
    p.finish(1, 1, false, 100);
    try std.testing.expect(p.meter.last_ms == null);
    p.finish(1, 1, true, 120);
    p.finish(1, 1, true, 130);
    p.stage(2, 1, 10);
    p.finish(2, 2, true, 140);
    try std.testing.expectEqual(@as(?u64, 120), p.meter.last_ms);
    p.stage(3, 1, 12); // intermediate revision never reached the window
    p.finish(3, 3, true, 220);
    try std.testing.expectEqual(@as(u64, 2), p.meter.buckets[1].count + p.meter.buckets[2].count);
    p.finish(4, 4, true, 240); // hidden/unmounted view did not stage this frame
    try std.testing.expectEqual(@as(?u64, 220), p.meter.last_ms);
    p.stage(5, 2, 1);
    p.finish(5, 5, true, 300);
    try std.testing.expectEqual(@as(u64, 0), p.meter.maxGap(300));
    try std.testing.expect(p.meter.fps(300) == null);
}

test "BMC FPS rolling windows expire without new video and preserve recent gaps" {
    var m: Meter = .{};
    for (0..21) |i| m.record(i * 100, 1);
    try std.testing.expectEqual(@as(?f64, 10), m.fps(2000));
    try std.testing.expectEqual(@as(?f64, 0), m.fps(3100));
    try std.testing.expectEqual(@as(u64, 100), m.maxGap(3100));
    try std.testing.expectEqual(@as(u64, 0), m.maxGap(12000));
    m.record(100, 1); // clock discontinuity resets, never underflows
    try std.testing.expect(m.fps(100) == null);
}
