/// AnimatedValue
///
/// Animatable value wrapper with multiple animation modes.
///
/// Features:
/// - unified interface: choose tween or spring animation
/// - auto-interpolation: value changes auto-start animation
/// - Signal-style: can integrate with the reactive system
const std = @import("std");
const Tween = @import("tween.zig").Tween;
const TweenConfig = @import("tween.zig").TweenConfig;
const Spring = @import("spring.zig").Spring;
const SpringConfig = @import("spring.zig").SpringConfig;
const SpringPreset = @import("spring.zig").SpringPreset;
const Transition = @import("transition.zig").Transition;
const TransitionConfig = @import("transition.zig").TransitionConfig;
const Easing = @import("easing.zig").Easing;

/// animation type
pub const AnimationType = enum {
    tween,
    spring,
    transition,
    none, // immediate update, no animation
};

/// AnimatedValue config
pub const AnimatedValueConfig = struct {
    /// animation type
    animation_type: AnimationType = .transition,
    /// tween config
    tween_config: TweenConfig = .{},
    /// spring config
    spring_config: SpringConfig = SpringPreset.default,
    /// transition config
    transition_config: TransitionConfig = .{},
};

/// animatable value
pub const AnimatedValue = struct {
    current_value: f32,
    target_value: f32,

    /// internal animation state, tagged union, stores only active animation type
    animator: Animator,

    const Animator = union(AnimationType) {
        tween: Tween,
        spring: Spring,
        transition: Transition,
        none: void,
    };

    /// create AnimatedValue
    pub fn init(initial_value: f32, config: AnimatedValueConfig) AnimatedValue {
        return AnimatedValue{
            .current_value = initial_value,
            .target_value = initial_value,
            .animator = switch (config.animation_type) {
                .tween => .{ .tween = Tween.init(.{ .from = initial_value, .to = initial_value, .duration = config.tween_config.duration, .easing = config.tween_config.easing }) },
                .spring => .{ .spring = Spring.init(initial_value, initial_value, config.spring_config) },
                .transition => .{ .transition = Transition.init(initial_value, config.transition_config) },
                .none => .{ .none = {} },
            },
        };
    }

    /// builder-style creation
    pub fn create(initial_value: f32) AnimatedValueBuilder {
        return AnimatedValueBuilder{ .initial = initial_value };
    }

    /// set target value (triggers animation)
    pub fn setTo(self: *AnimatedValue, value: f32, now_ms: f64) void {
        // use relative+absolute hybrid threshold
        const delta = @abs(value - self.target_value);
        const scale = @max(@abs(self.target_value), 1.0);
        if (delta / scale < 1e-5) {
            return;
        }

        self.target_value = value;

        switch (self.animator) {
            .tween => |*tw| {
                tw.config.from = self.current_value;
                tw.config.to = value;
                tw.start();
            },
            .spring => |*sp| {
                sp.from = self.current_value;
                sp.setTarget(value);
            },
            .transition => |*tr| {
                tr.setTo(value, now_ms);
            },
            .none => {
                self.current_value = value;
            },
        }
    }

    /// set value immediately
    pub fn setImmediate(self: *AnimatedValue, value: f32) void {
        self.current_value = value;
        self.target_value = value;
        switch (self.animator) {
            .tween => |*tw| tw.reset(),
            .spring => |*sp| sp.reset(),
            .transition => |*tr| tr.setImmediate(value),
            .none => {},
        }
    }

    /// update animation (now_ms: absolute timestamp ms; dt_s no longer used, kept for signature
    /// compat)
    pub fn update(self: *AnimatedValue, now_ms: f64, dt_s: f32) void {
        _ = dt_s;
        switch (self.animator) {
            .tween => |*tw| {
                // Tween.update takes absolute ms timestamp (same track as spring/transition).
                // Misguided dt_s (~0.016): elapsed = 0.016 - absolute_ms always huge negative,
                // blocked by delay check -> tween frozen at from.
                tw.update(now_ms);
                self.current_value = tw.getValue();
            },
            .spring => |*sp| {
                sp.update(now_ms);
                self.current_value = sp.getValue();
            },
            .transition => |*tr| {
                tr.update(now_ms);
                self.current_value = tr.getValue();
            },
            .none => {},
        }
    }

    /// get current value
    pub fn get(self: *const AnimatedValue) f32 {
        return self.current_value;
    }

    /// get target value
    pub fn getTarget(self: *const AnimatedValue) f32 {
        return self.target_value;
    }

    /// is animating
    pub fn isAnimating(self: *const AnimatedValue) bool {
        return switch (self.animator) {
            .tween => |tw| tw.isRunning(),
            .spring => |sp| sp.isRunning(),
            .transition => |tr| tr.isTransitioning(),
            .none => false,
        };
    }
};

/// AnimatedValue Builder
pub const AnimatedValueBuilder = struct {
    initial: f32,
    config: AnimatedValueConfig = .{},

    pub fn useSpring(self: AnimatedValueBuilder) AnimatedValueBuilder {
        var new = self;
        new.config.animation_type = .spring;
        return new;
    }

    pub fn useTransition(self: AnimatedValueBuilder) AnimatedValueBuilder {
        var new = self;
        new.config.animation_type = .transition;
        return new;
    }

    pub fn noAnimation(self: AnimatedValueBuilder) AnimatedValueBuilder {
        var new = self;
        new.config.animation_type = .none;
        return new;
    }

    pub fn duration_ms(self: AnimatedValueBuilder, ms: f32) AnimatedValueBuilder {
        var new = self;
        new.config.tween_config.duration = ms / 1000.0;
        new.config.transition_config.duration_ms = ms;
        return new;
    }

    pub fn easing(self: AnimatedValueBuilder, e: Easing) AnimatedValueBuilder {
        var new = self;
        new.config.tween_config.easing = e;
        new.config.transition_config.easing = e;
        return new;
    }

    pub fn stiffness(self: AnimatedValueBuilder, s: f32) AnimatedValueBuilder {
        var new = self;
        new.config.spring_config.stiffness = s;
        return new;
    }

    pub fn damping(self: AnimatedValueBuilder, d: f32) AnimatedValueBuilder {
        var new = self;
        new.config.spring_config.damping = d;
        return new;
    }

    pub fn build(self: AnimatedValueBuilder) AnimatedValue {
        return AnimatedValue.init(self.initial, self.config);
    }
};

// ========== convenience functions ==========

/// create animated value using transition
pub fn animated(initial: f32) AnimatedValue {
    return AnimatedValue.create(initial).useTransition().build();
}

/// create animated value using spring
pub fn springValue(initial: f32) AnimatedValue {
    return AnimatedValue.create(initial).useSpring().build();
}

// ========== tests ==========

test "AnimatedValue: transition mode" {
    var value = AnimatedValue.create(0.0)
        .useTransition()
        .duration_ms(500)
        .easing(.linear)
        .build();

    try std.testing.expectEqual(@as(f32, 0.0), value.get());

    const t0: f64 = 1000.0;
    value.setTo(100.0, t0);
    try std.testing.expect(value.isAnimating());

    value.update(t0 + 250.0, 0.25);
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), value.get(), 1.0);

    value.update(t0 + 500.0, 0.25);
    try std.testing.expect(!value.isAnimating());
    try std.testing.expectEqual(@as(f32, 100.0), value.get());
}

test "AnimatedValue: spring mode" {
    var value = AnimatedValue.create(0.0)
        .useSpring()
        .stiffness(500)
        .damping(50)
        .build();

    const dt_s: f32 = 1.0 / 60.0;
    value.setTo(10.0, 0);
    try std.testing.expect(value.isAnimating());

    // run enough frames
    var i: usize = 0;
    var t: f64 = 0;
    while (i < 300 and value.isAnimating()) : (i += 1) {
        t += @as(f64, dt_s) * 1000.0;
        value.update(t, dt_s);
    }

    try std.testing.expectApproxEqAbs(@as(f32, 10.0), value.get(), 0.01);
}

test "AnimatedValue: no animation" {
    var value = AnimatedValue.create(0.0)
        .noAnimation()
        .build();

    value.setTo(100.0, 0);
    try std.testing.expect(!value.isAnimating());
    try std.testing.expectEqual(@as(f32, 100.0), value.get());
}

test "AnimatedValue: immediate set" {
    var value = AnimatedValue.create(0.0)
        .useTransition()
        .duration_ms(1000)
        .build();

    const t0: f64 = 1000.0;
    value.setTo(50.0, t0);
    value.update(t0 + 100.0, 0.1); // start animation

    // set immediately
    value.setImmediate(100.0);
    try std.testing.expect(!value.isAnimating());
    try std.testing.expectEqual(@as(f32, 100.0), value.get());
}

test "animated convenience function" {
    var value = animated(0.0);
    value.setTo(10.0, 0);
    try std.testing.expect(value.isAnimating());
}

test "springValue convenience function" {
    var value = springValue(0.0);
    value.setTo(10.0, 0);
    try std.testing.expect(value.isAnimating());
}

test "AnimatedValue: tween mode 真的会动（now_ms 轨道回归）" {
    // regression: update misused dt_s (frame interval seconds) as absolute ms passed to Tween,
    // elapsed always huge negative blocked by delay, tween frozen at from. This pattern currently
    // has no builder entry (zero consumers), construct directly via init.
    var value = AnimatedValue.init(0.0, .{
        .animation_type = .tween,
        .tween_config = .{ .from = 0, .to = 100, .duration = 0.5, .easing = .linear },
    });

    // Tween.start anchors global frame clock, set explicitly, eliminate test order dependency
    const t0: f64 = 1000.0;
    @import("../core/render_engine/mod.zig").current_frame_time_ms = t0;
    value.setTo(100.0, t0);
    // should reach ~50% by 250ms, must never stick at 0
    value.update(t0 + 250.0, 1.0 / 60.0);
    try std.testing.expect(value.get() > 10.0);
    // reach target after full run
    value.update(t0 + 600.0, 1.0 / 60.0);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), value.get(), 0.5);
}
