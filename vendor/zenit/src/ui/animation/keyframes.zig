/// Keyframe animation with multi-segment progress interpolation
///
/// Usage:
/// ```zig
/// const kf = KeyframeAnimation.init(&.{
///     .{ .progress = 0.0, .value = 0, .easing = .linear },
///     .{ .progress = 0.3, .value = 1.2, .easing = .ease_out_back },
///     .{ .progress = 1.0, .value = 1.0, .easing = .ease_in_out_quad },
/// }, 500, 0); // 500ms, no loop
/// // Each frame:
/// const value = kf.update(dt);
/// ```
const std = @import("std");
const values = @import("value.zig");
const Easing = @import("easing.zig").Easing;
const render_engine = @import("../core/render_engine/mod.zig");

/// single keyframe
pub const Keyframe = struct {
    /// normalized progress (0.0 ~ 1.0)
    progress: f32,
    /// value at this frame
    value: f32,
    /// easing function to next frame
    easing: Easing = .linear,
};

/// keyframe animation
pub const KeyframeAnimation = struct {
    keyframes: []const Keyframe,
    /// total duration (milliseconds)
    duration_ms: f32,
    /// loop count (0 = infinite)
    loops: u32 = 1,
    /// absolute start timestamp (milliseconds)
    start_time_ms: f64 = 0,
    /// completed loop count
    completed_loops: u32 = 0,
    /// whether all loops completed
    completed: bool = false,
    /// Last value published by update; invalid input leaves it unchanged.
    current_value: f32 = 0,

    /// create keyframe animation. keyframes must be sorted ascending by progress, first and last
    /// 0.0 and 1.0
    pub fn init(keyframes: []const Keyframe, duration_ms: f32, loops: u32) KeyframeAnimation {
        return .{
            .keyframes = keyframes,
            .duration_ms = duration_ms,
            .loops = loops,
            .current_value = if (keyframes.len > 0) values.finiteOr(keyframes[0].value, 0) else 0,
        };
    }

    /// reset animation (use current global time)
    pub fn reset(self: *KeyframeAnimation) void {
        self.resetWithTime(render_engine.current_frame_time_ms);
    }

    /// reset animation (use specified time); invalid time preserves current state.
    pub fn resetWithTime(self: *KeyframeAnimation, now_ms: f64) void {
        if (!std.math.isFinite(now_ms) or now_ms < 0 or now_ms > std.math.floatMax(f32)) return;
        self.start_time_ms = now_ms;
        self.completed_loops = 0;
        self.completed = false;
        self.current_value = self.valueAtProgress(0);
    }

    /// drive per frame (absolute time model), return current interpolation
    pub fn update(self: *KeyframeAnimation, now_ms: f64) f32 {
        if (self.completed) {
            return self.current_value;
        }

        // Catch up arithmetically. A 1 ms infinite animation returning after an
        // hour in the background must not execute 3.6 million loop iterations.
        const duration = @as(f64, self.duration_ms);
        if (!std.math.isFinite(duration) or !std.math.isFinite(now_ms) or !std.math.isFinite(self.start_time_ms)) {
            return self.current_value;
        }
        const elapsed = now_ms - self.start_time_ms;
        if (now_ms < 0 or !std.math.isFinite(elapsed) or @abs(elapsed) > std.math.floatMax(f32)) return self.current_value;
        if (duration <= 0) {
            self.completed = true;
            self.completed_loops = self.loops;
            self.current_value = self.valueAtProgress(1);
            return self.current_value;
        }
        if (elapsed >= duration) {
            const elapsed_cycles = @floor(elapsed / duration);
            if (self.loops > 0) {
                const remaining = self.loops -| self.completed_loops;
                if (elapsed_cycles >= @as(f64, @floatFromInt(remaining))) {
                    self.completed_loops = self.loops;
                    self.completed = true;
                    self.current_value = self.valueAtProgress(1);
                    return self.current_value;
                }
                const cycles: u32 = @intFromFloat(elapsed_cycles);
                self.completed_loops += cycles;
                self.start_time_ms += @as(f64, @floatFromInt(cycles)) * duration;
            } else {
                const count_room = std.math.maxInt(u32) - self.completed_loops;
                if (elapsed_cycles >= @as(f64, @floatFromInt(count_room))) {
                    self.completed_loops = std.math.maxInt(u32);
                } else {
                    self.completed_loops += @intFromFloat(elapsed_cycles);
                }
                self.start_time_ms += elapsed_cycles * duration;
            }
        }

        const current_elapsed: f32 = @floatCast(now_ms - self.start_time_ms);
        const progress = if (self.duration_ms > 0)
            std.math.clamp(current_elapsed / self.duration_ms, 0.0, 1.0)
        else
            1.0;

        self.current_value = self.valueAtProgress(progress);
        return self.current_value;
    }

    /// compute interpolation from elapsed milliseconds (called by AnimationController)
    pub fn valueAtTime(self: *const KeyframeAnimation, elapsed_ms: f32) f32 {
        if (!std.math.isFinite(self.duration_ms) or !std.math.isFinite(elapsed_ms)) return self.valueAtProgress(0.0);
        if (self.duration_ms <= 0) return self.valueAtProgress(1.0);
        const progress = std.math.clamp(elapsed_ms / self.duration_ms, 0.0, 1.0);
        return self.valueAtProgress(progress);
    }

    /// compute interpolation from normalized progress
    pub fn valueAtProgress(self: *const KeyframeAnimation, progress: f32) f32 {
        if (self.keyframes.len == 0) return 0;
        if (self.keyframes.len == 1) return values.finiteOr(self.keyframes[0].value, 0);

        const safe_progress = if (std.math.isFinite(progress)) std.math.clamp(progress, 0.0, 1.0) else 0.0;

        // find interval [kf_a, kf_b] containing progress
        var kf_a = self.keyframes[0];
        var kf_b = self.keyframes[self.keyframes.len - 1];

        for (self.keyframes[1..], 1..) |kf, i| {
            if (safe_progress <= kf.progress) {
                kf_a = self.keyframes[i - 1];
                kf_b = kf;
                break;
            }
        }

        // compute local progress within interval
        if (!std.math.isFinite(kf_a.progress) or !std.math.isFinite(kf_b.progress)) return values.finiteOr(kf_a.value, 0);
        const span = @as(f64, kf_b.progress) - kf_a.progress;
        if (span <= 0) return values.finiteOr(kf_b.value, values.finiteOr(kf_a.value, 0));

        const local_t: f32 = @floatCast(std.math.clamp((@as(f64, safe_progress) - kf_a.progress) / span, 0.0, 1.0));
        return values.sample(kf_a.value, kf_b.value, kf_a.easing, local_t);
    }

    /// check if still playing
    pub fn isAnimating(self: *const KeyframeAnimation) bool {
        return !self.completed;
    }

    /// check if completed
    pub fn isCompleted(self: *const KeyframeAnimation) bool {
        return self.completed;
    }
};

/// test helper: set global simulated time
fn setTestTime(ms: f64) void {
    render_engine.current_frame_time_ms = ms;
}

test "KeyframeAnimation: basic two-keyframe" {
    setTestTime(1000.0);
    var kf = KeyframeAnimation.init(&.{
        .{ .progress = 0.0, .value = 0, .easing = .linear },
        .{ .progress = 1.0, .value = 100, .easing = .linear },
    }, 1000, 1); // 1000ms
    kf.start_time_ms = 1000.0;

    // half-second later should be ~50
    const v = kf.update(1500.0);
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), v, 1.0);
    try std.testing.expect(kf.isAnimating());
}

test "KeyframeAnimation: completion" {
    setTestTime(1000.0);
    var kf = KeyframeAnimation.init(&.{
        .{ .progress = 0.0, .value = 0, .easing = .linear },
        .{ .progress = 1.0, .value = 100, .easing = .linear },
    }, 100, 1); // 100ms
    kf.start_time_ms = 1000.0;

    // beyond duration
    const v = kf.update(1200.0);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), v, 0.1);
    try std.testing.expect(kf.isCompleted());
}

test "KeyframeAnimation: three keyframes" {
    setTestTime(1000.0);
    var kf = KeyframeAnimation.init(&.{
        .{ .progress = 0.0, .value = 0, .easing = .linear },
        .{ .progress = 0.5, .value = 100, .easing = .linear },
        .{ .progress = 1.0, .value = 50, .easing = .linear },
    }, 1000, 1);
    kf.start_time_ms = 1000.0;

    // 25% progress -> in [0, 0.5] segment, local 50% -> value = 50
    const v = kf.update(1250.0);
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), v, 1.0);
}

test "KeyframeAnimation: infinite loop" {
    setTestTime(1000.0);
    var kf = KeyframeAnimation.init(&.{
        .{ .progress = 0.0, .value = 0, .easing = .linear },
        .{ .progress = 1.0, .value = 1, .easing = .linear },
    }, 100, 0); // infinite loop
    kf.start_time_ms = 1000.0;

    // running after 5 cycles (300 frames @ 60fps = 5s = 50 cycles)
    const dt_ms: f64 = 1000.0 / 60.0;
    var now: f64 = 1000.0;
    for (0..300) |_| {
        now += dt_ms;
        _ = kf.update(now);
    }
    try std.testing.expect(kf.isAnimating());
}

test "KeyframeAnimation: 帧停滞多个周期后相位正确（批量补循环）" {
    // regression: single if adds one cycle per frame, after 2.5 cycles stalls progress clamped 1.0
    // frozen
    var kf = KeyframeAnimation.init(&.{
        .{ .progress = 0.0, .value = 0, .easing = .linear },
        .{ .progress = 1.0, .value = 100, .easing = .linear },
    }, 1000, 0); // infinite loop
    kf.start_time_ms = 0;

    // one frame spans 2500ms: should land at 50% of cycle 3 (value ~= 50), not clamped at 100
    const v = kf.update(2500.0);
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), v, 1.0);
    try std.testing.expectEqual(@as(u32, 2), kf.completed_loops);

    // finite loop: span 10 cycles complete once
    var kf2 = KeyframeAnimation.init(&.{
        .{ .progress = 0.0, .value = 0, .easing = .linear },
        .{ .progress = 1.0, .value = 100, .easing = .linear },
    }, 100, 3);
    kf2.start_time_ms = 0;
    _ = kf2.update(10_000.0);
    try std.testing.expect(kf2.completed);
}

test "KeyframeAnimation: long pause catches up in constant time" {
    var kf = KeyframeAnimation.init(&.{
        .{ .progress = 0.0, .value = 0, .easing = .linear },
        .{ .progress = 1.0, .value = 1, .easing = .linear },
    }, 1, 0);
    kf.start_time_ms = 0;

    const value = kf.update(60 * 60 * 1000);
    try std.testing.expectApproxEqAbs(@as(f32, 0), value, 0.001);
    try std.testing.expectEqual(@as(u32, 3_600_000), kf.completed_loops);
}

test "KeyframeAnimation: non-finite timing inputs are deterministic" {
    var kf = KeyframeAnimation.init(&.{
        .{ .progress = 0.0, .value = 10, .easing = .linear },
        .{ .progress = 1.0, .value = 20, .easing = .linear },
    }, std.math.nan(f32), 1);
    try std.testing.expectEqual(@as(f32, 10), kf.update(100));
    try std.testing.expectEqual(@as(f32, 10), kf.valueAtTime(50));
    try std.testing.expectEqual(@as(f32, 10), kf.valueAtProgress(std.math.nan(f32)));
}
