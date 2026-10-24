/// AnimatedColor - four-channel color animation on Transition with premultiplied alpha
/// interpolation.
///
/// Replaces the simple lerp of core.AnimatedColor with better easing control.
///
/// Features:
/// - stores/interpolates in premultiplied alpha space, avoiding dark flicker when
///   transitioning through transparency
/// - API uses straight alpha Color
/// - CSS-style easing functions, configurable duration
/// - same tick signature as core.AnimatedColor
const std = @import("std");
const Transition = @import("transition.zig").Transition;
const TransitionConfig = @import("transition.zig").TransitionConfig;
const Easing = @import("easing.zig").Easing;
const Color = @import("../core.zig").Color;

/// AnimatedColor config
pub const AnimatedColorConfig = struct {
    /// transition duration (ms)
    duration_ms: f32 = 150,
    /// easing function
    easing: Easing = .ease_out_quad,
};

/// color animation based on Transition (premultiplied alpha internal)
pub const AnimatedColor = struct {
    /// internal storage of premultiplied values: pr = r * (a/255), pg = g * (a/255), pb = b *
    /// (a/255)
    pr: Transition,
    pg: Transition,
    pb: Transition,
    a: Transition,
    target: Color,

    /// return type of tick
    pub const TickResult = struct { color: Color, animating: bool };

    /// default frame interval (seconds), assumes 60 FPS
    const default_dt: f32 = 1.0 / 60.0;

    // ---- premultiplied conversion helpers ----

    fn toPremul(color: Color) struct { pr: f32, pg: f32, pb: f32, a: f32 } {
        const af: f32 = @floatFromInt(color.a);
        const factor = af / 255.0;
        return .{
            .pr = @as(f32, @floatFromInt(color.r)) * factor,
            .pg = @as(f32, @floatFromInt(color.g)) * factor,
            .pb = @as(f32, @floatFromInt(color.b)) * factor,
            .a = af,
        };
    }

    fn fromPremul(pr: f32, pg: f32, pb: f32, af: f32) Color {
        const a_clamped = std.math.clamp(af, 0, 255);
        if (a_clamped < 0.5) {
            // fully transparent, RGB meaningless, return all zeros
            return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        }
        const inv = 255.0 / a_clamped;
        return .{
            .r = @intFromFloat(@round(std.math.clamp(pr * inv, 0, 255))),
            .g = @intFromFloat(@round(std.math.clamp(pg * inv, 0, 255))),
            .b = @intFromFloat(@round(std.math.clamp(pb * inv, 0, 255))),
            .a = @intFromFloat(@round(a_clamped)),
        };
    }

    // ---- public API ----

    /// create AnimatedColor (default config)
    pub fn init(color: Color) AnimatedColor {
        return initWithConfig(color, .{});
    }

    /// create AnimatedColor (custom config)
    pub fn initWithConfig(color: Color, config: AnimatedColorConfig) AnimatedColor {
        const tc = TransitionConfig{
            .duration_ms = config.duration_ms,
            .easing = config.easing,
        };
        const pm = toPremul(color);
        return .{
            .pr = Transition.init(pm.pr, tc),
            .pg = Transition.init(pm.pg, tc),
            .pb = Transition.init(pm.pb, tc),
            .a = Transition.init(pm.a, tc),
            .target = color,
        };
    }

    /// set target color (auto-start transition, interpolate in premultiplied space)
    pub fn setTarget(self: *AnimatedColor, color: Color, now_ms: f64) void {
        if (Color.eql(self.target, color)) return;
        self.target = color;
        const pm = toPremul(color);
        self.pr.setTo(pm.pr, now_ms);
        self.pg.setTo(pm.pg, now_ms);
        self.pb.setTo(pm.pb, now_ms);
        self.a.setTo(pm.a, now_ms);
    }

    /// jump to target color (skip animation)
    pub fn setImmediate(self: *AnimatedColor, color: Color) void {
        self.target = color;
        const pm = toPremul(color);
        self.pr.setImmediate(pm.pr);
        self.pg.setImmediate(pm.pg);
        self.pb.setImmediate(pm.pb);
        self.a.setImmediate(pm.a);
    }

    /// call every frame, reads global frame timestamp. identical signature to
    /// core.AnimatedColor.tick()
    pub fn tick(self: *AnimatedColor) TickResult {
        const render_engine = @import("../core/render_engine/mod.zig");
        return self.tickWithTime(render_engine.current_frame_time_ms);
    }

    /// frame-rate-independent tick, accepts absolute timestamp (ms)
    pub fn tickWithTime(self: *AnimatedColor, now_ms: f64) TickResult {
        self.pr.update(now_ms);
        self.pg.update(now_ms);
        self.pb.update(now_ms);
        self.a.update(now_ms);

        const animating = self.pr.isTransitioning() or
            self.pg.isTransitioning() or
            self.pb.isTransitioning() or
            self.a.isTransitioning();

        return .{
            .color = self.currentColor(),
            .animating = animating,
        };
    }

    /// get current color (does not advance animation)
    pub fn getColor(self: *const AnimatedColor) Color {
        return self.currentColor();
    }

    /// compute straight alpha Color from premultiplied internal
    fn currentColor(self: *const AnimatedColor) Color {
        return fromPremul(
            self.pr.getValue(),
            self.pg.getValue(),
            self.pb.getValue(),
            self.a.getValue(),
        );
    }

    /// whether transitioning
    pub fn isAnimating(self: *const AnimatedColor) bool {
        return self.pr.isTransitioning() or
            self.pg.isTransitioning() or
            self.pb.isTransitioning() or
            self.a.isTransitioning();
    }
};

// ========== tests ==========

/// test helper: simulate frame advance (default 150ms duration, 60 FPS -> ~16.67ms per frame)
const test_dt_ms: f64 = 1000.0 / 60.0;

test "AnimatedColor: init" {
    const color = Color.hex(0xFF8040);
    var anim = AnimatedColor.init(color);
    const result = anim.tickWithTime(0);

    try std.testing.expect(Color.eql(result.color, color));
    try std.testing.expect(!result.animating);
}

test "AnimatedColor: setTarget starts transition" {
    const start = Color.hex(0x000000);
    const target = Color.hex(0xFFFFFF);
    var anim = AnimatedColor.init(start);

    const t0: f64 = 1000.0;
    anim.setTarget(target, t0);

    // first frame: should start animation
    const result = anim.tickWithTime(t0 + test_dt_ms);
    try std.testing.expect(result.animating);
    // color should have started changing (no longer 0x000000)
    try std.testing.expect(result.color.r > 0 or result.color.g > 0 or result.color.b > 0);
}

test "AnimatedColor: tick converges to target" {
    const start = Color.hex(0x000000);
    const target = Color.hex(0xFFFFFF);
    var anim = AnimatedColor.init(start);

    const t0: f64 = 1000.0;
    anim.setTarget(target, t0);

    // run enough frames (150ms duration / ~16.67ms = 9 frames, run extra to ensure convergence)
    var t = t0;
    for (0..30) |_| {
        t += test_dt_ms;
        _ = anim.tickWithTime(t);
    }

    t += test_dt_ms;
    const result = anim.tickWithTime(t);
    try std.testing.expect(!result.animating);
    try std.testing.expect(Color.eql(result.color, target));
}

test "AnimatedColor: mid-flight target change" {
    const start = Color.hex(0x000000);
    const mid_target = Color.hex(0xFFFFFF);
    const final_target = Color.hex(0x808080);

    var anim = AnimatedColor.init(start);
    const t0: f64 = 1000.0;
    anim.setTarget(mid_target, t0);

    // run a few frames, still transitioning
    var t = t0;
    for (0..3) |_| {
        t += test_dt_ms;
        _ = anim.tickWithTime(t);
    }
    try std.testing.expect(anim.isAnimating());

    // switch target midway
    anim.setTarget(final_target, t);
    try std.testing.expect(anim.isAnimating());

    // run until convergence
    for (0..60) |_| {
        t += test_dt_ms;
        _ = anim.tickWithTime(t);
    }

    t += test_dt_ms;
    const result = anim.tickWithTime(t);
    try std.testing.expect(!result.animating);
    try std.testing.expect(Color.eql(result.color, final_target));
}

test "AnimatedColor: setTarget with same color is no-op" {
    const color = Color.hex(0xFF0000);
    var anim = AnimatedColor.init(color);

    anim.setTarget(color, 0);
    const result = anim.tickWithTime(test_dt_ms);
    try std.testing.expect(!result.animating);
}

test "AnimatedColor: setImmediate skips animation" {
    const start = Color.hex(0x000000);
    const target = Color.hex(0xFFFFFF);
    var anim = AnimatedColor.init(start);

    anim.setImmediate(target);

    const result = anim.tickWithTime(test_dt_ms);
    try std.testing.expect(!result.animating);
    try std.testing.expect(Color.eql(result.color, target));
}

test "AnimatedColor: custom config" {
    const start = Color.hex(0x000000);
    const target = Color.hex(0xFF0000);
    var anim = AnimatedColor.initWithConfig(start, .{
        .duration_ms = 500,
        .easing = .linear,
    });

    const t0: f64 = 1000.0;
    anim.setTarget(target, t0);

    // at halfway point of 500ms linear (15 frames ~= 250ms) should be ~halfway
    var t = t0;
    for (0..15) |_| {
        t += test_dt_ms;
        _ = anim.tickWithTime(t);
    }
    const mid = anim.getColor();
    // R channel should be in range 100-160 (about 127)
    try std.testing.expect(mid.r > 80 and mid.r < 180);
}

test "AnimatedColor: transparent to opaque no dark flash" {
    // key scenario: rgba(0,0,0,0) -> rgba(238,241,248,255) should not have dark intermediate frames
    const transparent = Color.rgba(0, 0, 0, 0);
    const opaque_color = Color.rgba(238, 241, 248, 255);
    var anim = AnimatedColor.initWithConfig(transparent, .{
        .duration_ms = 150,
        .easing = .linear,
    });

    const t0: f64 = 1000.0;
    anim.setTarget(opaque_color, t0);

    // check each frame, RGB should not be dark
    var t = t0;
    for (0..12) |_| {
        t += test_dt_ms;
        const result = anim.tickWithTime(t);
        const c = result.color;
        if (c.a > 10) {
            // when alpha is visible, RGB should approach target color (not black)
            try std.testing.expect(c.r > 180);
            try std.testing.expect(c.g > 180);
            try std.testing.expect(c.b > 190);
        }
    }
}

test "AnimatedColor: low-alpha hover to opaque active no dark flash" {
    // scenario: hover rgba(0,0,0,15) -> active rgba(238,241,248,255)
    const hover_bg = Color.rgba(0, 0, 0, 15);
    const active_bg = Color.rgba(238, 241, 248, 255);
    var anim = AnimatedColor.initWithConfig(hover_bg, .{
        .duration_ms = 150,
        .easing = .linear,
    });

    const t0: f64 = 1000.0;
    anim.setTarget(active_bg, t0);

    var t = t0;
    for (0..12) |_| {
        t += test_dt_ms;
        const result = anim.tickWithTime(t);
        const c = result.color;
        if (c.a > 30) {
            // should not have dark (r/g/b should not be much lower than target)
            try std.testing.expect(c.r > 100);
            try std.testing.expect(c.g > 100);
        }
    }
}
