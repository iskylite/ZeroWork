/// Transition
///
/// CSS-style transition animation; detects value changes and creates animation.
///
/// Features:
/// - auto-transition: setting a new value auto-starts animation
/// - configurable: duration, easing, delay
/// - interruptible: new values transition smoothly to the new target
const std = @import("std");
const Easing = @import("easing.zig").Easing;
const AnimationState = @import("mod.zig").AnimationState;

/// transition config
pub const TransitionConfig = struct {
    /// duration (ms)
    duration_ms: f32 = 200,
    /// delay (ms)
    delay_ms: f32 = 0,
    /// easing function
    easing: Easing = .ease_out_quad,
    /// update callback
    on_update: ?*const fn (f32, *anyopaque) void = null,
    /// completion callback
    on_complete: ?*const fn (*anyopaque) void = null,
    /// callback context
    context: ?*anyopaque = null,
};

/// CSS-style transition
pub const Transition = struct {
    config: TransitionConfig,
    current_value: f32,
    target_value: f32,
    start_value: f32,
    start_time_ms: f64 = 0,
    state: AnimationState = .completed, // initial completed state

    /// create transition
    pub fn init(initial_value: f32, config: TransitionConfig) Transition {
        return Transition{
            .config = config,
            .current_value = initial_value,
            .target_value = initial_value,
            .start_value = initial_value,
        };
    }

    /// builder-style creation
    pub fn create(initial_value: f32) TransitionBuilder {
        return TransitionBuilder{
            .initial = initial_value,
            .config = .{},
        };
    }

    /// set new target value (auto-start transition)
    pub fn setTo(self: *Transition, value: f32, now_ms: f64) void {
        // use relative+absolute hybrid threshold to avoid false 'no change' on large value ranges
        const delta = @abs(value - self.target_value);
        const scale = @max(@abs(self.target_value), 1.0);
        if (delta / scale < 1e-5) {
            return; // value didn't change significantly
        }

        self.target_value = value;
        self.start_value = self.current_value;
        self.start_time_ms = now_ms;
        self.state = .running;
    }

    /// set value immediately (skip animation)
    pub fn setImmediate(self: *Transition, value: f32) void {
        self.current_value = value;
        self.target_value = value;
        self.start_value = value;
        self.state = .completed;
    }

    /// update transition (call each frame, pass absolute timestamp ms)
    pub fn update(self: *Transition, now_ms: f64) void {
        if (self.state != .running) return;

        const elapsed = @as(f32, @floatCast(now_ms - self.start_time_ms));

        // check delay
        if (elapsed < self.config.delay_ms) {
            return;
        }

        const active_time = elapsed - self.config.delay_ms;
        // if duration_ms <= 0 complete immediately, avoid divide-by-zero
        const progress = if (self.config.duration_ms <= 0)
            @as(f32, 1.0)
        else
            std.math.clamp(active_time / self.config.duration_ms, 0.0, 1.0);

        // apply easing
        const eased = self.config.easing.apply(progress);

        // interpolate
        self.current_value = self.start_value + (self.target_value - self.start_value) * eased;

        // call update callback
        if (self.config.on_update) |callback| {
            if (self.config.context) |ctx| {
                callback(self.current_value, ctx);
            }
        }

        // check completion
        if (progress >= 1.0) {
            self.current_value = self.target_value;
            self.state = .completed;

            if (self.config.on_complete) |callback| {
                if (self.config.context) |ctx| {
                    callback(ctx);
                }
            }
        }
    }

    /// get current value
    pub fn getValue(self: *const Transition) f32 {
        return self.current_value;
    }

    /// get target value
    pub fn getTarget(self: *const Transition) f32 {
        return self.target_value;
    }

    /// is transitioning
    pub fn isTransitioning(self: *const Transition) bool {
        return self.state == .running;
    }
};

/// Transition Builder
pub const TransitionBuilder = struct {
    initial: f32,
    config: TransitionConfig,

    pub fn duration_ms(self: TransitionBuilder, ms: f32) TransitionBuilder {
        var new = self;
        new.config.duration_ms = ms;
        return new;
    }

    pub fn delay_ms(self: TransitionBuilder, ms: f32) TransitionBuilder {
        var new = self;
        new.config.delay_ms = ms;
        return new;
    }

    pub fn easing(self: TransitionBuilder, e: Easing) TransitionBuilder {
        var new = self;
        new.config.easing = e;
        return new;
    }

    pub fn onUpdate(self: TransitionBuilder, callback: *const fn (f32, *anyopaque) void, context: *anyopaque) TransitionBuilder {
        var new = self;
        new.config.on_update = callback;
        new.config.context = context;
        return new;
    }

    pub fn onComplete(self: TransitionBuilder, callback: *const fn (*anyopaque) void, context: *anyopaque) TransitionBuilder {
        var new = self;
        new.config.on_complete = callback;
        new.config.context = context;
        return new;
    }

    pub fn build(self: TransitionBuilder) Transition {
        return Transition.init(self.initial, self.config);
    }
};

// ========== tests ==========

test "Transition: no change" {
    var trans = Transition.create(50.0)
        .duration_ms(300)
        .build();

    // initial state should not be transitioning
    try std.testing.expect(!trans.isTransitioning());
    try std.testing.expectEqual(@as(f32, 50.0), trans.getValue());
}

test "Transition: basic" {
    var trans = Transition.create(0.0)
        .duration_ms(1000)
        .easing(.linear)
        .build();

    const t0: f64 = 1000.0; // start timestamp
    trans.setTo(100.0, t0);
    try std.testing.expect(trans.isTransitioning());

    // midpoint (t0 + 500ms)
    trans.update(t0 + 500.0);
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), trans.getValue(), 0.1);

    // complete (t0 + 1000ms)
    trans.update(t0 + 1000.0);
    try std.testing.expect(!trans.isTransitioning());
    try std.testing.expectEqual(@as(f32, 100.0), trans.getValue());
}

test "Transition: interruption" {
    var trans = Transition.create(0.0)
        .duration_ms(1000)
        .easing(.linear)
        .build();

    const t0: f64 = 1000.0;
    trans.setTo(100.0, t0);
    trans.update(t0 + 500.0); // reach 50

    // change target mid-transition (t1 = t0 + 500)
    const t1: f64 = t0 + 500.0;
    trans.setTo(0.0, t1);

    // should transition from current position (~50) to 0
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), trans.getValue(), 0.1);

    // complete (t1 + 1000ms)
    trans.update(t1 + 1000.0);
    try std.testing.expectEqual(@as(f32, 0.0), trans.getValue());
}

test "Transition: immediate" {
    var trans = Transition.create(0.0)
        .duration_ms(1000)
        .build();

    trans.setImmediate(100.0);

    try std.testing.expect(!trans.isTransitioning());
    try std.testing.expectEqual(@as(f32, 100.0), trans.getValue());
}

test "Transition: callback" {
    const TestState = struct {
        update_count: u32 = 0,
        completed: bool = false,
    };
    var state = TestState{};

    var trans = Transition.create(0.0)
        .duration_ms(500)
        .onUpdate(struct {
            fn handler(_: f32, ctx: *anyopaque) void {
                const ptr: *TestState = @ptrCast(@alignCast(ctx));
                ptr.update_count += 1;
            }
        }.handler, &state)
        .onComplete(struct {
            fn handler(ctx: *anyopaque) void {
                const ptr: *TestState = @ptrCast(@alignCast(ctx));
                ptr.completed = true;
            }
        }.handler, &state)
        .build();

    const t0: f64 = 1000.0;
    trans.setTo(10.0, t0);

    // multiple updates (every 100ms)
    trans.update(t0 + 100.0);
    trans.update(t0 + 200.0);
    trans.update(t0 + 300.0);
    trans.update(t0 + 400.0);
    trans.update(t0 + 500.0);

    try std.testing.expect(state.update_count >= 4);
    try std.testing.expect(state.completed);
}
