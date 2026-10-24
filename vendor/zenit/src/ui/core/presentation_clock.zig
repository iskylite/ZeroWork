//! A presentation transaction starts at its first sampled display frame.
//! Wall-clock input time is retained separately for hosts without display ticks.
const std = @import("std");

pub const Sample = struct {
    tick: u64,
    /// Absolute display-target time on a platform clock. Only differences on
    /// this clock are used; it is never subtracted from Cx's event clock.
    target_time_ms: ?f64,
    period_ms: f64,
};

pub const TransactionClock = struct {
    first_tick: ?u64 = null,
    target_anchor_ms: ?f64 = null,
    last_target_tick: ?u64 = null,
    last_frame_time_ms: ?f64 = null,
    last_elapsed_ms: f64 = 0,

    pub fn elapsed(self: *TransactionClock, event_time_ms: f64, frame_time_ms: f64, sample: ?Sample) f64 {
        const previous_frame_time = self.last_frame_time_ms;
        self.last_frame_time_ms = frame_time_ms;
        if (sample) |display| {
            if (self.first_tick == null) {
                self.first_tick = display.tick;
                // A mid-animation host change keeps the existing timeline.
                // A new presentation transaction starts with its current pose.
                if (self.last_elapsed_ms > 0) {
                    if (previous_frame_time) |previous| {
                        self.last_elapsed_ms += @max(frame_time_ms - previous, 0);
                    }
                }
                if (display.target_time_ms) |target| {
                    self.target_anchor_ms = target - self.last_elapsed_ms;
                    self.last_target_tick = display.tick;
                }
                return self.last_elapsed_ms;
            }
            if (display.target_time_ms) |target| {
                if (self.last_target_tick) |last_tick| {
                    // Forced screenshots/input can redraw the same display
                    // frame. CPU time passing does not advance its pose.
                    if (display.tick <= last_tick) return self.last_elapsed_ms;
                }
                if (self.target_anchor_ms == null) {
                    // An input frame can restart a stopped display link before
                    // it has a fresh target. That frame is transaction tick 0;
                    // the first callback advances by actual elapsed ticks.
                    const ticks = display.tick -| self.first_tick.?;
                    const tick_elapsed = @as(f64, @floatFromInt(ticks)) * display.period_ms;
                    self.last_elapsed_ms = @max(self.last_elapsed_ms, tick_elapsed);
                    self.target_anchor_ms = target - self.last_elapsed_ms;
                }
                self.last_target_tick = display.tick;
                self.last_elapsed_ms = @max(self.last_elapsed_ms, target - self.target_anchor_ms.?);
            }
            return self.last_elapsed_ms;
        }
        // Poll/manual/headless hosts preserve the event clock, including slow
        // frames. Losing display sampling midway cannot rewind the animation.
        const wall_elapsed = if (self.first_tick == null)
            @max(frame_time_ms - event_time_ms, 0)
        else if (previous_frame_time) |previous|
            self.last_elapsed_ms + @max(frame_time_ms - previous, 0)
        else
            self.last_elapsed_ms;
        self.last_elapsed_ms = @max(self.last_elapsed_ms, wall_elapsed);
        return self.last_elapsed_ms;
    }
};

test "presentation transaction clock starts at its first display target" {
    var clock: TransactionClock = .{};
    const t = std.testing;
    try t.expectEqual(@as(f64, 0), clock.elapsed(100, 109, .{ .tick = 37, .target_time_ms = 80000, .period_ms = 1000.0 / 60.0 }));
    // CPU sampling jitter and the event-to-display phase do not affect poses.
    try t.expectApproxEqAbs(@as(f64, 1000.0 / 60.0), clock.elapsed(100, 122, .{ .tick = 38, .target_time_ms = 80000 + 1000.0 / 60.0, .period_ms = 1000.0 / 60.0 }), 1e-8);
    try t.expectApproxEqAbs(@as(f64, 1000.0 / 60.0), clock.elapsed(100, 131, .{ .tick = 38, .target_time_ms = 80000 + 1000.0 / 60.0, .period_ms = 1000.0 / 60.0 }), 1e-8);
}

test "presentation transaction clock restarts after idle without a stale target" {
    var clock: TransactionClock = .{};
    const t = std.testing;
    try t.expectEqual(@as(f64, 0), clock.elapsed(2248.7, 2248.742, .{ .tick = 36, .target_time_ms = null, .period_ms = 1000.0 / 60.0 }));
    // R10's first callback came about 12ms after input. A completed display
    // tick advances by one display period, rather than that partial CPU dt.
    try t.expectApproxEqAbs(@as(f64, 1000.0 / 60.0), clock.elapsed(2248.7, 2260.695, .{ .tick = 37, .target_time_ms = 1847119940.386, .period_ms = 1000.0 / 60.0 }), 1e-6);
    try t.expectApproxEqAbs(@as(f64, 1000.0 / 30.0), clock.elapsed(2248.7, 2277.382, .{ .tick = 38, .target_time_ms = 1847119940.386 + 1000.0 / 60.0, .period_ms = 1000.0 / 60.0 }), 1e-6);
}

test "presentation transaction clock retains missed display periods and refresh rate" {
    const t = std.testing;
    var clock: TransactionClock = .{};
    _ = clock.elapsed(5000, 5000, .{ .tick = 10, .target_time_ms = null, .period_ms = 1000.0 / 120.0 });
    try t.expectEqual(@as(f64, 100), clock.elapsed(5000, 5064, .{ .tick = 22, .target_time_ms = 100000, .period_ms = 1000.0 / 120.0 }));
    // Subsequent advancement uses target differences, so a 180ms skipped
    // interval is preserved even if a physics integrator clamps its dt.
    try t.expectEqual(@as(f64, 280), clock.elapsed(5000, 5164, .{ .tick = 40, .target_time_ms = 100180, .period_ms = 1000.0 / 100.0 }));
}

test "presentation transaction clock falls back to event time and preserves host changes" {
    const t = std.testing;
    var clock: TransactionClock = .{};
    try t.expectEqual(@as(f64, 60), clock.elapsed(1000, 1060, null));
    try t.expectEqual(@as(f64, 240), clock.elapsed(1000, 1240, null));
    try t.expectEqual(@as(f64, 250), clock.elapsed(1000, 1250, .{ .tick = 3, .target_time_ms = 50000, .period_ms = 1000.0 / 60.0 }));
    try t.expectEqual(@as(f64, 300), clock.elapsed(1000, 1300, null));
    try t.expectEqual(@as(f64, 300), clock.elapsed(1000, 1300, .{ .tick = 6, .target_time_ms = 50050, .period_ms = 1000.0 / 60.0 }));
}

test "presentation transaction clock holds on missing or older display samples" {
    const t = std.testing;
    var clock: TransactionClock = .{};
    _ = clock.elapsed(0, 0, .{ .tick = 4, .target_time_ms = 90000, .period_ms = 16 });
    try t.expectEqual(@as(f64, 32), clock.elapsed(0, 30, .{ .tick = 6, .target_time_ms = 90032, .period_ms = 16 }));
    try t.expectEqual(@as(f64, 32), clock.elapsed(0, 40, .{ .tick = 7, .target_time_ms = null, .period_ms = 16 }));
    try t.expectEqual(@as(f64, 32), clock.elapsed(0, 45, .{ .tick = 5, .target_time_ms = 90016, .period_ms = 16 }));
    try t.expectEqual(@as(f64, 48), clock.elapsed(0, 46, .{ .tick = 7, .target_time_ms = 90048, .period_ms = 16 }));
}

test "presentation transaction clock ignores an event hook before its first render" {
    const t = std.testing;
    var clock: TransactionClock = .{};
    // Hit-test freshness may run a before-render hook in an event. Its old
    // frozen wall clock precedes this new transaction's real event time.
    try t.expectEqual(@as(f64, 0), clock.elapsed(2000, 100, null));
    try t.expectEqual(@as(f64, 0), clock.elapsed(2000, 2001, .{ .tick = 40, .target_time_ms = 90000, .period_ms = 16 }));
    try t.expectEqual(@as(f64, 16), clock.elapsed(2000, 2013, .{ .tick = 41, .target_time_ms = 90016, .period_ms = 16 }));
}
