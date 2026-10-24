/// Tween Animation - smooth transition from a start to a target value over a given time.
///
/// Features:
/// - configurable duration
/// - all easing functions
/// - loop and yoyo
/// - delay
const std = @import("std");
const values = @import("value.zig");
const Easing = @import("easing.zig").Easing;
const AnimationState = @import("mod.zig").AnimationState;
const render_engine = @import("../core/render_engine/mod.zig");

/// Tween config
pub const TweenConfig = struct {
    /// start value
    from: f32 = 0.0,
    /// target value
    to: f32 = 1.0,
    /// duration (seconds)
    duration: f32 = 0.3,
    /// delay (seconds)
    delay: f32 = 0.0,
    /// easing function
    easing: Easing = .ease_out_quad,
    /// loop count (0 = infinite)
    loops: u32 = 1,
    /// yoyo mode (back and forth)
    yoyo: bool = false,
    /// completion callback
    on_complete: ?*const fn (*anyopaque) void = null,
    /// update callback
    on_update: ?*const fn (f32, *anyopaque) void = null,
    /// callback context
    context: ?*anyopaque = null,
};

/// tween animation
pub const Tween = struct {
    config: TweenConfig,
    /// absolute start timestamp (milliseconds)
    start_time_ms: f64 = 0,
    /// timestamp recorded when paused (milliseconds)
    pause_time_ms: f64 = 0,
    state: AnimationState = .idle,
    updating: bool = false,
    control_revision: u64 = 0,
    current_loop: u32 = 0,
    direction: i8 = 1, // 1 = forward, -1 = backward (for yoyo)
    current_value: f32 = 0.0,

    /// create Tween
    pub fn init(config: TweenConfig) Tween {
        var normalized = config;
        normalized.from = values.finiteOr(config.from, 0);
        normalized.to = values.finiteOr(config.to, normalized.from);
        return Tween{ .config = normalized, .current_value = normalized.from };
    }

    /// quick create
    pub fn from(initial: f32) TweenBuilder {
        return TweenBuilder{
            .config = .{ .from = initial, .to = initial },
        };
    }

    /// start playing
    pub fn start(self: *Tween) void {
        self.control_revision +%= 1;
        self.state = .running;
        self.start_time_ms = render_engine.current_frame_time_ms;
        self.current_loop = 0;
        self.direction = 1;
        self.config.from = values.finiteOr(self.config.from, 0);
        self.config.to = values.finiteOr(self.config.to, self.config.from);
        self.current_value = self.config.from;
    }

    /// pause
    pub fn pause(self: *Tween) void {
        if (self.state == .running) {
            self.control_revision +%= 1;
            self.state = .paused;
            self.pause_time_ms = render_engine.current_frame_time_ms;
        }
    }

    /// resume
    pub fn unpause(self: *Tween) void {
        if (self.state == .paused) {
            self.control_revision +%= 1;
            self.state = .running;
            // offset start_time_ms to compensate for time elapsed during pause
            const paused_duration = render_engine.current_frame_time_ms - self.pause_time_ms;
            self.start_time_ms += paused_duration;
        }
    }

    /// stop
    pub fn stop(self: *Tween) void {
        self.control_revision +%= 1;
        self.state = .idle;
    }

    /// reset
    pub fn reset(self: *Tween) void {
        self.control_revision +%= 1;
        self.start_time_ms = render_engine.current_frame_time_ms;
        self.state = .idle;
        self.current_loop = 0;
        self.direction = 1;
        self.config.from = values.finiteOr(self.config.from, 0);
        self.config.to = values.finiteOr(self.config.to, self.config.from);
        self.current_value = self.config.from;
    }

    /// update animation (call every frame)
    /// now_ms: current frame absolute timestamp (milliseconds)
    /// Keep standalone storage alive and stable throughout callbacks.
    pub fn update(self: *Tween, now_ms: f64) void {
        if (self.state != .running or self.updating) return;
        const elapsed = now_ms - self.start_time_ms;
        if (!std.math.isFinite(now_ms) or now_ms < 0 or !std.math.isFinite(elapsed) or @abs(elapsed) > std.math.floatMax(f32)) return;
        if (!std.math.isFinite(self.config.duration) or !std.math.isFinite(self.config.delay)) return;
        const duration_ms = milliseconds(@max(self.config.duration, 0));
        const delay_ms = milliseconds(self.config.delay);
        if (elapsed < delay_ms) return;
        self.updating = true;
        defer self.updating = false;
        const revision = self.control_revision;

        // Catch up once arithmetically, then publish one sample. Never iterate
        // once per missed cycle after a long background pause.
        const cycle_ms = duration_ms + delay_ms;
        const cycles = if (cycle_ms > 0) @max(0, @floor(elapsed / cycle_ms)) else 0;
        const remaining = self.config.loops -| self.current_loop;
        const finished = cycle_ms <= 0 or (self.config.loops > 0 and cycles >= @as(f64, @floatFromInt(remaining)));
        const phase_cycles = if (finished) @as(f64, @floatFromInt(remaining -| 1)) else cycles;
        var sample_direction = self.direction;
        if (self.config.yoyo and @mod(phase_cycles, 2) >= 1) sample_direction = -sample_direction;
        const residual = if (cycle_ms > 0) @mod(@max(0, elapsed), cycle_ms) else 0;
        const waiting = !finished and cycles > 0 and residual < delay_ms;
        const progress: f32 = if (finished or duration_ms <= 0 or waiting) 1 else @floatCast(std.math.clamp((residual - delay_ms) / duration_ms, 0, 1));
        // During a repeated delay, hold the preceding cycle's endpoint.
        const value_direction = if (waiting and self.config.yoyo) -sample_direction else sample_direction;
        var eased = values.eased(self.config.easing, progress);
        if (value_direction < 0) eased = 1 - eased;
        self.current_value = values.interpolate(self.config.from, self.config.to, eased);
        if (self.config.on_update) |callback| {
            if (self.config.context) |ctx| callback(self.current_value, ctx);
        }
        if (self.control_revision != revision or self.state != .running) return;

        self.direction = sample_direction;
        if (finished) {
            self.current_loop = self.config.loops;
            self.state = .completed;
            if (self.config.on_complete) |callback| {
                if (self.config.context) |ctx| callback(ctx);
            }
        } else if (cycles > 0) {
            const room = std.math.maxInt(u32) - self.current_loop;
            self.current_loop = if (cycles >= @as(f64, @floatFromInt(room))) std.math.maxInt(u32) else self.current_loop + @as(u32, @intFromFloat(cycles));
            self.start_time_ms = now_ms - residual;
        }
    }

    // Preserve the public f32 seconds-to-ms boundary (0.3s -> 300ms).
    // Use a wide fallback only when the f32 product cannot represent it.
    fn milliseconds(seconds: f32) f64 {
        const rounded = seconds * 1000;
        return if (std.math.isFinite(rounded)) @as(f64, rounded) else @as(f64, seconds) * 1000;
    }

    /// get current value
    pub fn getValue(self: *const Tween) f32 {
        return self.current_value;
    }

    /// whether running
    pub fn isRunning(self: *const Tween) bool {
        return self.state == .running;
    }

    /// whether completed
    pub fn isCompleted(self: *const Tween) bool {
        return self.state == .completed;
    }
};

/// Tween Builder
pub const TweenBuilder = struct {
    config: TweenConfig,

    pub fn to(self: TweenBuilder, value: f32) TweenBuilder {
        var new = self;
        new.config.to = value;
        return new;
    }

    pub fn duration(self: TweenBuilder, seconds: f32) TweenBuilder {
        var new = self;
        new.config.duration = seconds;
        return new;
    }

    pub fn delay(self: TweenBuilder, seconds: f32) TweenBuilder {
        var new = self;
        new.config.delay = seconds;
        return new;
    }

    pub fn easing(self: TweenBuilder, e: Easing) TweenBuilder {
        var new = self;
        new.config.easing = e;
        return new;
    }

    pub fn loops(self: TweenBuilder, count: u32) TweenBuilder {
        var new = self;
        new.config.loops = count;
        return new;
    }

    pub fn yoyo(self: TweenBuilder, enabled: bool) TweenBuilder {
        var new = self;
        new.config.yoyo = enabled;
        return new;
    }

    pub fn onComplete(self: TweenBuilder, callback: *const fn (*anyopaque) void, context: *anyopaque) TweenBuilder {
        var new = self;
        new.config.on_complete = callback;
        new.config.context = context;
        return new;
    }

    pub fn onUpdate(self: TweenBuilder, callback: *const fn (f32, *anyopaque) void, context: *anyopaque) TweenBuilder {
        var new = self;
        new.config.on_update = callback;
        new.config.context = context;
        return new;
    }

    pub fn build(self: TweenBuilder) Tween {
        return Tween.init(self.config);
    }
};

// ========== tests ==========

/// test helper: set global simulation time
fn setTestTime(ms: f64) void {
    render_engine.current_frame_time_ms = ms;
}

test "Tween: basic animation" {
    setTestTime(1000.0);
    var tween = Tween.from(0.0)
        .to(100.0)
        .duration(1.0)
        .easing(.linear)
        .build();

    tween.start();
    try std.testing.expect(tween.isRunning());

    // simulate 0.5 seconds
    tween.update(1500.0);
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), tween.getValue(), 0.1);

    // finished
    tween.update(2000.0);
    try std.testing.expect(tween.isCompleted());
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), tween.getValue(), 0.1);
}

test "Tween: with delay" {
    setTestTime(1000.0);
    var tween = Tween.from(0.0)
        .to(10.0)
        .duration(1.0)
        .delay(0.5)
        .build();

    tween.start();

    // during delay (300ms < 500ms delay), value unchanged
    tween.update(1300.0);
    try std.testing.expectEqual(@as(f32, 0.0), tween.getValue());

    // after delay ends animation starts (1000ms > 500ms delay)
    tween.update(2000.0);
    try std.testing.expect(tween.getValue() > 0.0);
}

test "Tween: yoyo" {
    setTestTime(1000.0);
    var tween = Tween.from(0.0)
        .to(10.0)
        .duration(0.5)
        .yoyo(true)
        .loops(2)
        .easing(.linear)
        .build();

    tween.start();

    // first forward
    tween.update(1500.0);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), tween.getValue(), 0.1);

    // second reverse (yoyo)
    tween.update(2000.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), tween.getValue(), 0.1);

    try std.testing.expect(tween.isCompleted());
}

test "Tween: callback" {
    setTestTime(1000.0);
    // use single struct to store two states
    const TestState = struct {
        callback_value: f32 = 0,
        complete_called: bool = false,
    };
    var state = TestState{};

    var tween = Tween.from(0.0)
        .to(100.0)
        .duration(0.5)
        .easing(.linear)
        .onUpdate(struct {
            fn handler(value: f32, ctx: *anyopaque) void {
                const ptr: *TestState = @ptrCast(@alignCast(ctx));
                ptr.callback_value = value;
            }
        }.handler, &state)
        .onComplete(struct {
            fn handler(ctx: *anyopaque) void {
                const ptr: *TestState = @ptrCast(@alignCast(ctx));
                ptr.complete_called = true;
            }
        }.handler, &state)
        .build();

    tween.start();
    tween.update(1250.0);
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), state.callback_value, 0.1);

    tween.update(1500.0);
    try std.testing.expect(state.complete_called);
}
