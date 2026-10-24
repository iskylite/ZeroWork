/// Physics primitives, reusable by any component (extracted from ScrollArea).
///
/// Modules:
/// - RubberBand: Apple UIScrollView-class rubber band damping
/// - FadeIndicator: auto fade in/out indicator (e.g., scrollbar)
const std = @import("std");

/// Apple UIScrollView-level rubber band damping
///
/// Rational function: f(x) = x*d*c / (d + c*x)
/// - Small displacement near-linear (responsive feel)
/// - Large displacement approaches d (smooth decay)
///
/// Usage:
/// ```zig
/// const rb = RubberBand{};
/// const visual = rb.clamp(raw_overscroll, viewport_size);
/// ```
pub const RubberBand = struct {
    /// Damping coefficient (Apple standard = 0.55).
    coefficient: f32 = 0.55,

    /// Map raw input distance to visual distance (damped).
    pub fn clamp(self: RubberBand, input: f32, dimension: f32) f32 {
        const c = self.coefficient;
        const d = @max(dimension, 1.0);
        const abs_x = @abs(input);
        const clamped = (abs_x * d * c) / (d + c * abs_x);
        return if (input < 0) -clamped else clamped;
    }

    /// Precise inverse of clamp: recover raw distance from visual value.
    pub fn unclamp(self: RubberBand, visual: f32, dimension: f32) f32 {
        const c = self.coefficient;
        const d = @max(dimension, 1.0);
        const abs_v = @abs(visual);
        if (abs_v == 0) return 0;
        // Rational function asymptotes to d; clamp to d*0.999 to avoid division by
        // zero.
        const max_visual = d * 0.999;
        const safe = @min(abs_v, max_visual);
        const denom = c * d - c * safe;
        // Small denominator returns reasonable large value relative to dimension.
        const saturated = d * 100;
        if (denom < 1e-6) return if (visual < 0) -saturated else saturated;
        const raw = safe * d / denom;
        return if (visual < 0) -raw else raw;
    }

    /// iOS-style incremental update: inverse recovers raw -> add delta -> remap.
    pub fn applyDelta(self: RubberBand, current_bonus: f32, raw_delta: f32, dimension: f32) f32 {
        const raw = self.unclamp(current_bonus, dimension) + raw_delta;
        return self.clamp(raw, dimension);
    }
};

/// Auto fade-in/fade-out indicator
///
/// Shows when active, auto-fades after idle time. Stays visible on hover.
///
/// Usage:
/// ```zig
/// var indicator = FadeIndicator{};
/// indicator.onActivity();   // call on scroll
/// indicator.tick();         // call each frame
/// const alpha = indicator.opacity;
/// ```
pub const FadeIndicator = struct {
    /// Current opacity [0, 1].
    opacity: f32 = 0,
    /// Idle frame count.
    idle_frames: u32 = 0,
    /// Whether hovered (no fade on hover).
    hovered: bool = false,
    /// Delay frames before fade (default 90 frames ~ 1.5s at 60fps).
    fade_delay: u32 = 90,
    /// Fade per frame (default 1/36 ~ 0.6s to fully fade).
    fade_speed: f32 = 1.0 / 36.0,
    /// Initial opacity when active.
    active_opacity: f32 = 0.7,

    /// Mark active (call on scroll/interaction).
    pub fn onActivity(self: *FadeIndicator) void {
        self.idle_frames = 0;
        if (self.opacity < self.active_opacity) {
            self.opacity = self.active_opacity;
        }
    }

    /// Per-frame tick: handle fade logic.
    pub fn tick(self: *FadeIndicator) void {
        // Stay 100% opaque on hover.
        if (self.hovered) {
            self.opacity = 1.0;
            self.idle_frames = 0;
            return;
        }

        if (self.opacity <= 0) return;

        self.idle_frames +|= 1; // Saturating add prevents overflow.
        if (self.idle_frames > self.fade_delay) {
            self.opacity -= self.fade_speed;
            if (self.opacity < 0) self.opacity = 0;
        }
    }

    /// Whether visible.
    pub fn isVisible(self: *const FadeIndicator) bool {
        return self.opacity > 0;
    }
};

// ========== Tests ==========

test "RubberBand: clamp/unclamp round-trip" {
    const rb = RubberBand{};
    const dim: f32 = 200;
    const inputs = [_]f32{ 5, 20, 50, 100, -10, -80 };
    for (inputs) |input| {
        const clamped = rb.clamp(input, dim);
        const recovered = rb.unclamp(clamped, dim);
        try std.testing.expectApproxEqAbs(input, recovered, 0.1);
    }
}

test "RubberBand: asymptotic behavior" {
    const rb = RubberBand{};
    const dim: f32 = 200;

    // Small input: damped but close to input.
    const small = rb.clamp(10, dim);
    try std.testing.expect(small > 0);
    try std.testing.expect(small <= 10.0);

    // Large input: asymptotes to dim.
    const large = rb.clamp(10000, dim);
    try std.testing.expect(large > 0);
    try std.testing.expect(large <= dim);

    // Monotone increasing.
    try std.testing.expect(large > small);

    // Negative input symmetric.
    const neg = rb.clamp(-50, dim);
    try std.testing.expect(neg < 0);
}

test "RubberBand: applyDelta cumulative" {
    const rb = RubberBand{};
    const dim: f32 = 200;

    // Continuous overshoot: accumulated damping.
    const first = rb.applyDelta(0, -5, dim);
    try std.testing.expect(first < 0);

    const second = rb.applyDelta(first, -5, dim);
    const second_increment = @abs(second - first);
    const first_increment = @abs(first);
    try std.testing.expect(second_increment < first_increment);
}

test "RubberBand: custom coefficient" {
    const rb = RubberBand{ .coefficient = 0.3 };
    const rb_standard = RubberBand{};
    const dim: f32 = 200;

    // Lower coefficient = stronger damping.
    const custom = rb.clamp(50, dim);
    const standard = rb_standard.clamp(50, dim);
    try std.testing.expect(custom < standard);
}

test "FadeIndicator: activity triggers visibility" {
    var fi = FadeIndicator{};
    try std.testing.expect(!fi.isVisible());

    fi.onActivity();
    try std.testing.expect(fi.isVisible());
    try std.testing.expectEqual(@as(f32, 0.7), fi.opacity);
}

test "FadeIndicator: fade after delay" {
    var fi = FadeIndicator{};
    fi.onActivity();

    // Within delay: no fade.
    for (0..90) |_| fi.tick();
    try std.testing.expectEqual(@as(f32, 0.7), fi.opacity);

    // After delay: start fade.
    fi.tick();
    try std.testing.expect(fi.opacity < 0.7);

    // Run enough frames: fully fade.
    for (0..40) |_| fi.tick();
    try std.testing.expectEqual(@as(f32, 0), fi.opacity);
    try std.testing.expect(!fi.isVisible());
}

test "FadeIndicator: hover suppresses fade" {
    var fi = FadeIndicator{};
    fi.onActivity();

    fi.hovered = true;
    fi.tick();
    try std.testing.expectEqual(@as(f32, 1.0), fi.opacity);

    // Never fade even past delay on hover.
    for (0..200) |_| fi.tick();
    try std.testing.expectEqual(@as(f32, 1.0), fi.opacity);
}

test "FadeIndicator: activity resets fade" {
    var fi = FadeIndicator{};
    fi.onActivity();

    // Wait until fade starts.
    for (0..95) |_| fi.tick();
    try std.testing.expect(fi.opacity < 0.7);

    // Become active again.
    fi.onActivity();
    try std.testing.expectEqual(@as(f32, 0.7), fi.opacity);

    // Delay timer restarts.
    for (0..90) |_| fi.tick();
    try std.testing.expectEqual(@as(f32, 0.7), fi.opacity);
}
