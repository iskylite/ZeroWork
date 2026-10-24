//! Gesture recognizer: gesture arbitration layer.
//!
//! Generic "recognizer state machine": tap / drag / long_press / triple_click / pinch / pan
//! all share the same lifecycle management.
//!
//! Integration status: GestureArena is implemented but **the dispatcher has 0 callers**;
//! event_dispatcher.mouse_{down,move,up} do not feed it, and input/state.zig still runs its own
//! click_count / drag_anchor impl. Full integration (Node.on_gesture slot + input component
//! migration) is not done yet.
//!
//! Design references:
//! - UIKit UIGestureRecognizer (state machine: possible / began / changed / ended / failed /
//!   cancelled)
//! - Android GestureDetector
//! - Flutter GestureRecognizer + GestureArenaManager
//!
//! Design rules:
//! - **Don't** embed each gesture type inside event_dispatcher (current click/double_click does
//!   this, hard to extend)
//! - **Don't** have implicit priority between recognizers (arbitration is an explicit
//!   requireFailure relation)
//! - **Don't** have recognizers hold *Node (use ElementId for cross-frame safety)
//!
//! State machine (UIKit style):
//!     possible -+-> began --> changed* --> ended
//!              |                      |
//!              +-> failed             cancelled
//!
//! - possible: waiting for recognition conditions (entered on touchDown)
//! - began: recognition conditions met (e.g. after long_press for 500ms)
//! - changed: recognition in progress, params updated (drag in motion)
//! - ended: natural completion (touch up)
//! - failed: conditions not met (e.g. finger moved beyond threshold during tap)
//! - cancelled: external cancellation (system-level interruption)

const std = @import("std");
const testing = std.testing;
const element_id_mod = @import("../core/element_id.zig");

pub const ElementId = element_id_mod.ElementId;

pub const GestureState = enum(u8) {
    possible,
    began,
    changed,
    ended,
    failed,
    cancelled,
};

pub const GestureKind = enum(u8) {
    tap,
    double_tap,
    triple_tap,
    long_press,
    pan, // drag
    pinch, // two-finger pinch
    rotation,
    fling, // fling (pan end with speed > threshold)
};

/// Single gesture event callback context
pub const GestureEvent = struct {
    kind: GestureKind,
    state: GestureState,
    target: ElementId,
    /// Start point (set during possible/began)
    origin_x: f32 = 0,
    origin_y: f32 = 0,
    /// Current point
    current_x: f32 = 0,
    current_y: f32 = 0,
    /// Velocity (pan/fling)
    velocity_x: f32 = 0,
    velocity_y: f32 = 0,
    /// Two-finger distance (pinch)
    pinch_scale: f32 = 1.0,
    /// Rotation radians
    rotation_rad: f32 = 0,
    /// Click count (tap/double_tap/triple_tap shared)
    click_count: u8 = 1,
};

pub const GestureCallback = *const fn (event: GestureEvent, ctx: *anyopaque) void;

/// Recognizer config + current state
pub const Recognizer = struct {
    kind: GestureKind,
    /// Which element has this recognizer
    target: ElementId,
    /// Current state
    state: GestureState = .possible,
    /// User config parameters
    config: Config = .{},
    /// Trigger callback
    callback: ?GestureCallback = null,
    /// User context
    ctx: ?*anyopaque = null,

    /// Internal state fields
    started_ns: i128 = 0,
    origin_x: f32 = 0,
    origin_y: f32 = 0,
    current_x: f32 = 0,
    current_y: f32 = 0,
    last_x: f32 = 0,
    last_y: f32 = 0,
    last_t_ns: i128 = 0,
    velocity_x: f32 = 0,
    velocity_y: f32 = 0,
    click_count: u8 = 0,
    /// Last tap up time; multi_tap_interval_ms timeout check (0 = never tapped)
    last_tap_ns: i128 = 0,
    /// Must fail after another recognizer (requireFailure dependency); NULL = no dependency
    require_failure_of: u32 = std.math.maxInt(u32),

    pub const Config = struct {
        /// tap: move over this distance fails
        tap_max_movement_px: f32 = 8.0,
        /// long_press: held over this time triggers began
        long_press_min_duration_ms: u32 = 500,
        /// pan: move over this distance triggers began (pan vs tap distinction)
        pan_min_movement_px: f32 = 10.0,
        /// double_tap: max interval between two taps
        multi_tap_interval_ms: u32 = 450,
        /// fling: velocity over this value triggers on release
        fling_min_velocity_px_per_s: f32 = 300,
    };
};

/// Multi-recognizer arbitrator: manages recognizer coordination over one touch sequence.
/// Simplified: all recognizers receive events; each maintains state independently;
/// requireFailure: A.require_failure_of = B means A begins only after B fails.
pub const GestureArena = struct {
    allocator: std.mem.Allocator,
    recognizers: std.ArrayListUnmanaged(Recognizer),

    pub fn init(allocator: std.mem.Allocator) GestureArena {
        return .{ .allocator = allocator, .recognizers = .empty };
    }

    pub fn deinit(self: *GestureArena) void {
        self.recognizers.deinit(self.allocator);
        self.* = undefined;
    }

    /// Add recognizer, return index (for requireFailure reference)
    pub fn addRecognizer(self: *GestureArena, r: Recognizer) !u32 {
        const idx: u32 = @intCast(self.recognizers.items.len);
        try self.recognizers.append(self.allocator, r);
        return idx;
    }

    /// Set a must wait for b to fail before success
    pub fn requireFailure(self: *GestureArena, a: u32, b: u32) void {
        if (a >= self.recognizers.items.len) return;
        self.recognizers.items[a].require_failure_of = b;
    }

    /// Reset all recognizers to possible (new touch sequence). click_count / last_tap_ns kept
    /// intentionally: multi-tap count must survive across touch sequences (host resets each
    /// mouse-down), expiry is checked by onTouchUp per multi_tap_interval_ms. Previously reset
    /// cleared the count, which made multi-tap unreachable.
    pub fn reset(self: *GestureArena) void {
        for (self.recognizers.items) |*r| {
            r.state = .possible;
            r.velocity_x = 0;
            r.velocity_y = 0;
            // Zero to sentinel: else tick uses stale timestamp from previous sequence to judge
            // long_press
            // (tick runs before touchDown too)
            r.started_ns = 0;
        }
    }

    /// Receive touchDown event
    pub fn onTouchDown(self: *GestureArena, x: f32, y: f32, now_ns: i128) void {
        for (self.recognizers.items) |*r| {
            if (r.state != .possible) continue;
            r.started_ns = now_ns;
            r.origin_x = x;
            r.origin_y = y;
            r.current_x = x;
            r.current_y = y;
            r.last_x = x;
            r.last_y = y;
            r.last_t_ns = now_ns;
        }
    }

    /// Receive touchMove event
    pub fn onTouchMove(self: *GestureArena, x: f32, y: f32, now_ns: i128) void {
        for (self.recognizers.items) |*r| {
            if (r.state == .ended or r.state == .failed or r.state == .cancelled) continue;

            const dx = x - r.origin_x;
            const dy = y - r.origin_y;
            const dist_sq = dx * dx + dy * dy;

            // Velocity estimation (last point -> current)
            const dt_s = @as(f32, @floatFromInt(now_ns - r.last_t_ns)) / @as(f32, std.time.ns_per_s);
            if (dt_s > 0) {
                r.velocity_x = (x - r.last_x) / dt_s;
                r.velocity_y = (y - r.last_y) / dt_s;
            }
            r.last_x = x;
            r.last_y = y;
            r.last_t_ns = now_ns;
            r.current_x = x;
            r.current_y = y;

            switch (r.kind) {
                .tap, .double_tap, .triple_tap => {
                    // Move over threshold -> fail
                    const max_d = r.config.tap_max_movement_px;
                    if (dist_sq > max_d * max_d) {
                        r.state = .failed;
                        emit(r, .failed);
                    }
                },
                .pan => {
                    if (r.state == .possible) {
                        const min_d = r.config.pan_min_movement_px;
                        if (dist_sq > min_d * min_d) {
                            // Check requireFailure
                            if (r.require_failure_of != std.math.maxInt(u32)) {
                                const dep_idx = r.require_failure_of;
                                if (dep_idx < self.recognizers.items.len) {
                                    if (self.recognizers.items[dep_idx].state != .failed) continue;
                                }
                            }
                            r.state = .began;
                            emit(r, .began);
                        }
                    } else if (r.state == .began or r.state == .changed) {
                        r.state = .changed;
                        emit(r, .changed);
                    }
                },
                .long_press => {
                    // Move over threshold -> fail
                    const max_d = r.config.tap_max_movement_px;
                    if (dist_sq > max_d * max_d) {
                        r.state = .failed;
                        emit(r, .failed);
                    } else if (r.state == .began or r.state == .changed) {
                        r.state = .changed;
                        emit(r, .changed);
                    }
                },
                else => {},
            }
        }
    }

    /// Receive touchUp event
    pub fn onTouchUp(self: *GestureArena, x: f32, y: f32, now_ns: i128) void {
        for (self.recognizers.items) |*r| {
            if (r.state == .ended or r.state == .failed or r.state == .cancelled) continue;
            r.current_x = x;
            r.current_y = y;

            switch (r.kind) {
                .tap, .double_tap, .triple_tap => {
                    if (r.state == .possible) {
                        // History count past multi-tap interval expires (count as new first tap).
                        // Previously
                        // `_ = now_ns` discarded it; two taps 10s apart counted as double_tap.
                        const interval_ns: i128 = @as(i128, r.config.multi_tap_interval_ms) * std.time.ns_per_ms;
                        if (r.last_tap_ns != 0 and now_ns - r.last_tap_ns > interval_ns) {
                            r.click_count = 0;
                        }
                        r.click_count += 1;
                        r.last_tap_ns = now_ns;
                        const expected: u8 = switch (r.kind) {
                            .tap => 1,
                            .double_tap => 2,
                            .triple_tap => 3,
                            else => unreachable,
                        };
                        if (r.click_count >= expected) {
                            r.state = .ended;
                            emit(r, .ended);
                            r.click_count = 0;
                        }
                        // Otherwise wait for next tap
                    }
                },
                .pan => {
                    if (r.state == .began or r.state == .changed) {
                        r.state = .ended;
                        emit(r, .ended);
                    } else {
                        r.state = .failed;
                    }
                },
                .long_press => {
                    if (r.state == .began or r.state == .changed) {
                        r.state = .ended;
                        emit(r, .ended);
                    } else {
                        r.state = .failed;
                    }
                },
                else => {},
            }
        }
    }

    /// System-level interrupt (window blur / session cancel): in-flight gestures all -> cancelled.
    /// Previously .cancelled only read, never written; recognizers stuck in began/changed after
    /// interrupt.
    pub fn onTouchCancel(self: *GestureArena, now_ns: i128) void {
        _ = now_ns;
        for (self.recognizers.items) |*r| {
            switch (r.state) {
                .possible, .began, .changed => {
                    // possible not yet successful, silently -> cancelled no event; began/changed
                    // already announced,
                    // must send cancelled to close
                    const announced = r.state != .possible;
                    r.state = .cancelled;
                    if (announced) emit(r, .cancelled);
                },
                .ended, .failed, .cancelled => {},
            }
            r.started_ns = 0;
        }
    }

    /// tick for time-related checks (long_press). Caller invokes once per frame.
    pub fn tick(self: *GestureArena, now_ns: i128) void {
        for (self.recognizers.items) |*r| {
            if (r.state != .possible) continue;
            if (r.kind == .long_press) {
                // started_ns == 0 is "sequence not yet touchDown" sentinel (default/reset value).
                // Caller
                // ticks with epoch timestamp every frame; elapsed would be ~5.7e13 ms, far
                // exceeding u32;
                // negative elapsed from clock rewind/out-of-order. Neither constitutes "held".
                if (r.started_ns == 0) continue;
                const elapsed_ns = now_ns - r.started_ns;
                if (elapsed_ns < 0) continue;
                const elapsed_ms: u32 = @intCast(@min(
                    @divTrunc(elapsed_ns, std.time.ns_per_ms),
                    std.math.maxInt(u32),
                ));
                if (elapsed_ms >= r.config.long_press_min_duration_ms) {
                    if (r.require_failure_of != std.math.maxInt(u32)) {
                        const dep_idx = r.require_failure_of;
                        if (dep_idx < self.recognizers.items.len) {
                            if (self.recognizers.items[dep_idx].state != .failed) continue;
                        }
                    }
                    r.state = .began;
                    emit(r, .began);
                }
            }
        }
    }
};

fn emit(r: *Recognizer, state: GestureState) void {
    if (r.callback) |cb| {
        const event = GestureEvent{
            .kind = r.kind,
            .state = state,
            .target = r.target,
            .origin_x = r.origin_x,
            .origin_y = r.origin_y,
            .current_x = r.current_x,
            .current_y = r.current_y,
            .velocity_x = r.velocity_x,
            .velocity_y = r.velocity_y,
            .click_count = r.click_count,
        };
        cb(event, r.ctx orelse undefined);
    }
}

// ============================================================================
// Tests
// ============================================================================

const TestSink = struct {
    events: std.ArrayListUnmanaged(GestureEvent) = .empty,
    allocator: std.mem.Allocator,

    fn cb(event: GestureEvent, ctx: *anyopaque) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx));
        self.events.append(self.allocator, event) catch {};
    }

    fn deinit(self: *TestSink) void {
        self.events.deinit(self.allocator);
    }
};

test "GestureArena: tap recognized on quick down/up without movement" {
    var sink = TestSink{ .allocator = testing.allocator };
    defer sink.deinit();

    var arena = GestureArena.init(testing.allocator);
    defer arena.deinit();

    _ = try arena.addRecognizer(.{
        .kind = .tap,
        .target = .{ .index = 1, .generation = 0 },
        .callback = &TestSink.cb,
        .ctx = &sink,
    });

    arena.onTouchDown(50, 50, 0);
    arena.onTouchUp(51, 51, 1_000_000); // 1ms later
    try testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try testing.expectEqual(GestureKind.tap, sink.events.items[0].kind);
    try testing.expectEqual(GestureState.ended, sink.events.items[0].state);
}

test "GestureArena: tap fails when movement exceeds threshold" {
    var sink = TestSink{ .allocator = testing.allocator };
    defer sink.deinit();

    var arena = GestureArena.init(testing.allocator);
    defer arena.deinit();

    _ = try arena.addRecognizer(.{
        .kind = .tap,
        .target = .{ .index = 1, .generation = 0 },
        .callback = &TestSink.cb,
        .ctx = &sink,
        .config = .{ .tap_max_movement_px = 8 },
    });

    arena.onTouchDown(50, 50, 0);
    arena.onTouchMove(100, 100, 1_000_000); // move 70px >> 8px
    try testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try testing.expectEqual(GestureState.failed, sink.events.items[0].state);
}

test "GestureArena: pan recognized after sufficient movement" {
    var sink = TestSink{ .allocator = testing.allocator };
    defer sink.deinit();

    var arena = GestureArena.init(testing.allocator);
    defer arena.deinit();

    _ = try arena.addRecognizer(.{
        .kind = .pan,
        .target = .{ .index = 1, .generation = 0 },
        .callback = &TestSink.cb,
        .ctx = &sink,
        .config = .{ .pan_min_movement_px = 10 },
    });

    arena.onTouchDown(50, 50, 0);
    arena.onTouchMove(70, 70, 1_000_000); // move ~28px > 10px
    try testing.expect(sink.events.items.len >= 1);
    try testing.expectEqual(GestureKind.pan, sink.events.items[0].kind);
    try testing.expectEqual(GestureState.began, sink.events.items[0].state);

    arena.onTouchMove(100, 100, 2_000_000);
    // another changed
    try testing.expect(sink.events.items.len >= 2);

    arena.onTouchUp(120, 120, 3_000_000);
    // ended
    const last = sink.events.items[sink.events.items.len - 1];
    try testing.expectEqual(GestureState.ended, last.state);
}

test "GestureArena: long_press triggers via tick" {
    var sink = TestSink{ .allocator = testing.allocator };
    defer sink.deinit();

    var arena = GestureArena.init(testing.allocator);
    defer arena.deinit();

    _ = try arena.addRecognizer(.{
        .kind = .long_press,
        .target = .{ .index = 1, .generation = 0 },
        .callback = &TestSink.cb,
        .ctx = &sink,
        .config = .{ .long_press_min_duration_ms = 500 },
    });

    // use non-zero down timestamp: started_ns == 0 is sentinel for "sequence not yet touchDown"
    arena.onTouchDown(50, 50, 1 * std.time.ns_per_ms);
    // tick after 600ms
    arena.tick(601 * std.time.ns_per_ms);
    try testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try testing.expectEqual(GestureKind.long_press, sink.events.items[0].kind);
    try testing.expectEqual(GestureState.began, sink.events.items[0].state);
}

test "GestureArena: tick before any touch must not panic on epoch timestamps" {
    // Regression: core.zig ticks with @import("zenit_time").monotonicTimestamp(std.testing.io) (epoch, ~1.8e18 ns) each frame.
    // long_press registered, before first touchDown started_ns defaults to 0, elapsed_ms ~5.7e13
    // far exceeds u32, old code @intCast panicked on first frame.
    var arena = GestureArena.init(testing.allocator);
    defer arena.deinit();

    _ = try arena.addRecognizer(.{
        .kind = .long_press,
        .target = .{ .index = 1, .generation = 0 },
    });

    arena.tick(@import("zenit_time").monotonicTimestamp(std.testing.io));
    // shouldn't trigger without press
    try testing.expectEqual(GestureState.possible, arena.recognizers.items[0].state);
}

test "GestureArena: tick tolerates clock going backwards and reset clears started_ns" {
    var arena = GestureArena.init(testing.allocator);
    defer arena.deinit();

    _ = try arena.addRecognizer(.{
        .kind = .long_press,
        .target = .{ .index = 1, .generation = 0 },
        .config = .{ .long_press_min_duration_ms = 500 },
    });

    arena.onTouchDown(50, 50, 1_000 * std.time.ns_per_ms);
    // clock rewind (out-of-order timestamp): negative elapsed must not panic or trigger
    arena.tick(900 * std.time.ns_per_ms);
    try testing.expectEqual(GestureState.possible, arena.recognizers.items[0].state);

    // after reset started_ns zeroed: tick before new sequence starts must not trigger with stale
    // timestamp
    arena.reset();
    arena.tick(1_000_000 * std.time.ns_per_ms);
    try testing.expectEqual(GestureState.possible, arena.recognizers.items[0].state);
}

test "GestureArena: requireFailure relation - tap blocks pan from triggering immediately" {
    var sink = TestSink{ .allocator = testing.allocator };
    defer sink.deinit();

    var arena = GestureArena.init(testing.allocator);
    defer arena.deinit();

    const tap_idx = try arena.addRecognizer(.{
        .kind = .tap,
        .target = .{ .index = 1, .generation = 0 },
        .callback = &TestSink.cb,
        .ctx = &sink,
        .config = .{ .tap_max_movement_px = 8 },
    });
    const pan_idx = try arena.addRecognizer(.{
        .kind = .pan,
        .target = .{ .index = 1, .generation = 0 },
        .callback = &TestSink.cb,
        .ctx = &sink,
        .config = .{ .pan_min_movement_px = 10 },
    });
    arena.requireFailure(pan_idx, tap_idx);

    arena.onTouchDown(50, 50, 0);
    arena.onTouchMove(60, 60, 1_000_000); // move ~14px: tap fail, pan can trigger

    // tap should fail
    var saw_tap_fail = false;
    var saw_pan_began = false;
    for (sink.events.items) |e| {
        if (e.kind == .tap and e.state == .failed) saw_tap_fail = true;
        if (e.kind == .pan and e.state == .began) saw_pan_began = true;
    }
    try testing.expect(saw_tap_fail);
    try testing.expect(saw_pan_began);
}

test "GestureArena: reset returns all recognizers to possible" {
    var arena = GestureArena.init(testing.allocator);
    defer arena.deinit();

    _ = try arena.addRecognizer(.{
        .kind = .tap,
        .target = .{ .index = 1, .generation = 0 },
    });

    arena.onTouchDown(50, 50, 0);
    arena.onTouchUp(51, 51, 1_000_000);
    try testing.expectEqual(GestureState.ended, arena.recognizers.items[0].state);

    arena.reset();
    try testing.expectEqual(GestureState.possible, arena.recognizers.items[0].state);
}

test "GestureArena: double_tap 超过 multi_tap_interval_ms 不得触发" {
    var sink = TestSink{ .allocator = testing.allocator };
    defer sink.deinit();

    var arena = GestureArena.init(testing.allocator);
    defer arena.deinit();

    _ = try arena.addRecognizer(.{
        .kind = .double_tap,
        .target = .{ .index = 1, .generation = 0 },
        .callback = &TestSink.cb,
        .ctx = &sink,
        .config = .{ .multi_tap_interval_ms = 450 },
    });

    // first tap
    arena.onTouchDown(50, 50, 1_000 * std.time.ns_per_ms);
    arena.onTouchUp(50, 50, 1_050 * std.time.ns_per_ms);
    // second tap 10s later, far exceeds 450ms interval, must count as new first tap
    arena.reset();
    arena.onTouchDown(50, 50, 11_000 * std.time.ns_per_ms);
    arena.onTouchUp(50, 50, 11_050 * std.time.ns_per_ms);

    for (sink.events.items) |e| {
        try testing.expect(!(e.kind == .double_tap and e.state == .ended));
    }
}

test "GestureArena: double_tap 间隔内两击触发" {
    var sink = TestSink{ .allocator = testing.allocator };
    defer sink.deinit();

    var arena = GestureArena.init(testing.allocator);
    defer arena.deinit();

    _ = try arena.addRecognizer(.{
        .kind = .double_tap,
        .target = .{ .index = 1, .generation = 0 },
        .callback = &TestSink.cb,
        .ctx = &sink,
        .config = .{ .multi_tap_interval_ms = 450 },
    });

    arena.onTouchDown(50, 50, 1_000 * std.time.ns_per_ms);
    arena.onTouchUp(50, 50, 1_050 * std.time.ns_per_ms);
    // new sequence (host resets each down), but count must survive within interval
    arena.reset();
    arena.onTouchDown(50, 50, 1_200 * std.time.ns_per_ms);
    arena.onTouchUp(50, 50, 1_250 * std.time.ns_per_ms);

    var fired = false;
    for (sink.events.items) |e| {
        if (e.kind == .double_tap and e.state == .ended) fired = true;
    }
    try testing.expect(fired);
}

test "GestureArena: onTouchCancel 把进行中的手势转 cancelled" {
    var sink = TestSink{ .allocator = testing.allocator };
    defer sink.deinit();

    var arena = GestureArena.init(testing.allocator);
    defer arena.deinit();

    _ = try arena.addRecognizer(.{
        .kind = .pan,
        .target = .{ .index = 1, .generation = 0 },
        .callback = &TestSink.cb,
        .ctx = &sink,
        .config = .{ .pan_min_movement_px = 10 },
    });

    arena.onTouchDown(50, 50, 1_000_000);
    arena.onTouchMove(80, 80, 2_000_000); // move ~42px -> pan began
    arena.onTouchCancel(3_000_000);

    try testing.expectEqual(GestureState.cancelled, arena.recognizers.items[0].state);
    var saw_cancel = false;
    for (sink.events.items) |e| {
        if (e.kind == .pan and e.state == .cancelled) saw_cancel = true;
    }
    try testing.expect(saw_cancel);

    // after cancel tick/move must not revive
    arena.onTouchMove(90, 90, 4_000_000);
    try testing.expectEqual(GestureState.cancelled, arena.recognizers.items[0].state);
}
