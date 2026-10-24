//! Notification pure logic layer: dock geometry, stack geometry, enter/exit curves, timing.
//!
//! No Node access; the render layer writes these values to transform / alpha each frame.
//! All time quantities derive from wallclock timestamps (born / left_at / deadline), not
//! per-frame accumulation on the object, so dropped frames don't drift phase.
const std = @import("std");
const easing_mod = @import("../../animation/easing.zig");

// ============================================================================
// Types
// ============================================================================

/// One notification's form (kind in data model).
pub const Kind = enum {
    /// Icon + title + body (+ optional buttons / reply / avatar).
    default,
    /// Spinner + definite progress bar + n / N count, no lifebar.
    progress,
    /// Countdown ring (center shows remaining seconds) + Undo button.
    undo,
    /// Text hint (16.13): 36h glass capsule, one line only (+ optional badge / keycap / button),
    /// same stack as card, no title/timestamp/close/lifebar.
    hint,
};

/// Semantic hue. oklch same lightness and chroma, hue only (design 16.9).
pub const Tone = enum {
    success,
    @"error",
    warning,
    info,
    violet,
    quiet,
};

/// Eight dock positions (design 16.1). Default bottom_center.
pub const Position = enum(u3) {
    top_left,
    top_center,
    top_right,
    right_center,
    bottom_right,
    bottom_center,
    bottom_left,
    left_center,

    /// Stack growth direction symbol: top anchor +1 (down), bottom -1 (up),
    /// side midpoint +1 (down, overall vertical center preserved).
    pub fn sign(self: Position) f32 {
        return switch (self) {
            .bottom_left, .bottom_center, .bottom_right => -1,
            else => 1,
        };
    }

    pub const HAlign = enum { left, center, right };

    pub fn hAlign(self: Position) HAlign {
        return switch (self) {
            .top_left, .bottom_left, .left_center => .left,
            .top_center, .bottom_center => .center,
            .top_right, .bottom_right, .right_center => .right,
        };
    }

    pub const VAnchor = enum { top, bottom, middle };

    pub fn vAnchor(self: Position) VAnchor {
        return switch (self) {
            .top_left, .top_center, .top_right => .top,
            .bottom_left, .bottom_center, .bottom_right => .bottom,
            .left_center, .right_center => .middle,
        };
    }

    /// Enter initial displacement (window coords, px). Top/bottom use Y, left/right midpoint use X.
    pub fn entryOffset(self: Position, distance: f32) struct { x: f32, y: f32 } {
        return switch (self) {
            .top_left, .top_center, .top_right => .{ .x = 0, .y = -distance },
            .bottom_left, .bottom_center, .bottom_right => .{ .x = 0, .y = distance },
            .right_center => .{ .x = distance, .y = 0 },
            .left_center => .{ .x = -distance, .y = 0 },
        };
    }

    /// Allowed throw direction: left can only left, right only right, center either.
    /// Returns -1 / +1 / 0 (0 = either side).
    pub fn flingDirection(self: Position) f32 {
        return switch (self.hAlign()) {
            .left => -1,
            .right => 1,
            .center => 0,
        };
    }

    /// Badge (StackPill) glued to which stack side: true = visually above.
    /// Top anchor below; bottom anchor and side midpoints above (design 16.1 table).
    pub fn pillAbove(self: Position) bool {
        return switch (self.vAnchor()) {
            .top => false,
            .bottom, .middle => true,
        };
    }
};

// ============================================================================
// Spec constants (design 16.2 / 16.4 / 16.5 / 16.7)
// ============================================================================

pub const Spec = struct {
    pub const card_width: f32 = 392;
    pub const edge_inset: f32 = 22;
    pub const stack_gap: f32 = 9;
    pub const peek: f32 = 9;
    pub const collapsed_scale_step: f32 = 0.038;
    pub const collapsed_scale_max_steps: f32 = 3;
    pub const collapsed_visible_layers: f32 = 3;
    pub const hover_slop: f32 = 18;
    pub const max_on_screen: usize = 6;
    pub const default_max_visible: u8 = 4;

    // Animation: clean, crisp finish—short duration, strong deceleration, small displacement, no
    // staggered timing or icon bounce.
    pub const enter_ms: f64 = 300;
    pub const enter_distance: f32 = 10;
    pub const enter_scale_from: f32 = 0.98;
    /// Opacity completes within first 55% of entrance time to avoid semi-transparent ghosting.
    pub const enter_fade_portion: f32 = 0.55;
    /// Layered stagger: 20ms spacing, each layer 220ms at 4px offset; last layer (60+220=280ms)
    /// ends simultaneously with card entrance (300ms) to preserve stagger feel while keeping total
    /// duration constant.
    pub const stagger_ms: f64 = 220;
    pub const stagger_offset: f32 = 4;
    pub const title_delay_ms: f64 = 20;
    pub const body_delay_ms: f64 = 40;
    pub const progress_delay_ms: f64 = 50;
    pub const footer_delay_ms: f64 = 60;
    /// No reflow transitions during this post-entrance period (frame-driven updates and transitions
    /// cannot overlap).
    pub const young_ms: f64 = 380;

    pub const exit_ms: f64 = 200;
    pub const exit_scale_loss: f32 = 0.03;
    pub const exit_drift: f32 = 4;
    pub const exit_fling_gain: f32 = 1.1;

    pub const reflow_ms: f64 = 300;
    pub const expand_ms: f64 = 320;
    pub const icon_pop_ms: f64 = 240;
    pub const crossfade_ms: f64 = 160;
    /// 'Clear All' button expands / collapses.
    pub const clear_reveal_ms: f64 = 200;
    pub const close_fade_ms: f64 = 140;

    pub const swipe_threshold: f32 = 84;
    pub const swipe_fling: f32 = 70;
    pub const swipe_fade_span: f32 = 190;
    pub const swipe_min_alpha: f32 = 0.25;
};

/// Default retention time (ms) by type. null = sticky. Design spec 16.2.
pub const Durations = struct {
    pub const success: u32 = 3600;
    pub const warning: u32 = 5600;
    pub const progress_done: u32 = 3400;
    pub const undo: u32 = 7000;
    pub const quiet: u32 = 2800;
    pub const info: u32 = 4200;
    pub const accept_settle: u32 = 2600;
    pub const reply_settle: u32 = 2200;
    pub const undo_settle: u32 = 2400;
    pub const retry_progress: u32 = 5200;
};

/// Text hint default retention time (16.13); in-progress notifications remain sticky.
pub const HintDurations = struct {
    /// Plain text / success.
    pub const plain: u32 = 2000;
    /// Error / keyboard shortcut.
    pub const emphasis: u32 = 3000;
    /// Undoable (with action button).
    pub const action: u32 = 4000;
};

// Easing

pub fn clamp01(v: f32) f32 {
    return std.math.clamp(v, 0, 1);
}

pub fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// easeOutCubic = 1 − (1−p)³, unified easing (16.5).
pub fn easeOutCubic(p: f32) f32 {
    const q = 1 - clamp01(p);
    return 1 - q * q * q;
}

/// Reflow curve cubic-bezier(.22,.92,.24,1).
pub fn reflowEase(p: f32) f32 {
    return easing_mod.Easing.cubicBezier(0.22, 0.92, 0.24, 1).apply(clamp01(p));
}

/// Progress (0..1), returns 0 if elapsed < 0 (not started / delayed).
pub fn progressOf(elapsed_ms: f64, duration_ms: f64) f32 {
    if (duration_ms <= 0) return 1;
    return clamp01(@floatCast(elapsed_ms / duration_ms));
}

// Entrance / Exit / Staggered layering

pub const Motion = struct {
    /// Displacement multiplier along entrance axis (0 = in place; 1 = full 22px initial offset).
    offset: f32 = 0,
    scale: f32 = 1,
    alpha: f32 = 1,
};

/// Strong deceleration (≈ easeOutExpo): fast start, clean finish, no trailing drag.
pub fn enterEase(p: f32) f32 {
    return easing_mod.Easing.cubicBezier(0.16, 1, 0.3, 1).apply(clamp01(p));
}

/// Card body entrance: translate 10→0 · scale .98→1 over 300ms strong deceleration; alpha completes
/// in first 55%.
pub fn enterMotion(elapsed_ms: f64) Motion {
    const raw = progressOf(elapsed_ms, Spec.enter_ms);
    const p = enterEase(raw);
    return .{
        .offset = 1 - p,
        .scale = lerp(Spec.enter_scale_from, 1, p),
        .alpha = easeOutCubic(clamp01(raw / Spec.enter_fade_portion)),
    };
}

/// Layered elements (title / content / progress / buttons): run for 440ms after delay, 8px offset +
/// alpha.
pub fn staggerMotion(elapsed_ms: f64, delay_ms: f64) struct { offset: f32, alpha: f32 } {
    const p = easeOutCubic(progressOf(elapsed_ms - delay_ms, Spec.stagger_ms));
    return .{ .offset = (1 - p) * Spec.stagger_offset, .alpha = p };
}

/// Icon appears: scale .9→1, no overshoot or rotation (reused when swapping icons in place).
pub fn iconPop(elapsed_ms: f64, duration_ms: f64) struct { scale: f32, rotate_deg: f32 } {
    const p = enterEase(progressOf(elapsed_ms, duration_ms));
    return .{ .scale = lerp(0.9, 1, p), .rotate_deg = 0 };
}

pub const ExitMotion = struct {
    alpha: f32,
    scale: f32,
    /// Drift along stack growth direction (px, unsigned).
    drift: f32,
    /// Height contribution coefficient: subsequent cards position themselves based on this.
    weight: f32,
    /// Fling displacement multiplier (only meaningful when drag-triggered with non-zero
    /// displacement).
    fling_gain: f32,
    done: bool,
};

/// Exit over 200ms: alpha (1−p)^1.6, scale ×(1−0.03p), drift 4px,
/// height contribution eases to 0 (cards below reposition fast then slow), fling X×(1+1.1p).
pub fn exitMotion(elapsed_ms: f64) ExitMotion {
    const p = progressOf(elapsed_ms, Spec.exit_ms);
    return .{
        .alpha = std.math.pow(f32, 1 - p, 1.6),
        .scale = 1 - Spec.exit_scale_loss * p,
        .drift = Spec.exit_drift * p,
        .weight = 1 - easeOutCubic(p),
        .fling_gain = 1 + Spec.exit_fling_gain * p,
        .done = p >= 1,
    };
}

/// Drag opacity: max(0.25, 1 − |dx| / 190).
pub fn swipeAlpha(dx: f32) f32 {
    return @max(Spec.swipe_min_alpha, 1 - @abs(dx) / Spec.swipe_fade_span);
}

/// Constrain drag displacement to allowed direction by position; apply 0.2 rubber-band damping in
/// reverse.
pub fn constrainSwipe(position: Position, dx: f32) f32 {
    const dir = position.flingDirection();
    if (dir == 0) return dx;
    if (dx * dir >= 0) return dx;
    return dx * 0.2;
}

/// Release threshold: exceed 84px (and allowed direction) to close and fling out.
pub fn swipeCommits(position: Position, dx: f32) bool {
    if (@abs(dx) < Spec.swipe_threshold) return false;
    const dir = position.flingDirection();
    return dir == 0 or dx * dir > 0;
}

// Stack geometry (16.4)

/// Single stack input: sorted by z-order (0 = newest, closest to anchor).
pub const StackInput = struct {
    /// Card natural height (unclipped).
    height: f32,
    /// Card natural width (card is always full-width; text hint capsule follows content). 0 =
    /// doesn't participate in width collapse.
    width: f32 = 0,
    /// Height contribution weight: normal 1; during exit 1−p, continuously reaching 0.
    weight: f32 = 1,
    /// Exiting cards are not used as clipping reference for the topmost card.
    leaving: bool = false,
};

/// Single output: all relative to anchor edge, render layer converts to window coordinates.
pub const StackOutput = struct {
    /// Distance from this card's near-anchor edge to the anchor (along growth direction, >=0).
    offset: f32,
    /// Visible height (collapsed state clipped to topmost card height).
    clip_height: f32,
    /// Visible width: collapsed state shrinks layers to topmost card width (avoid capsule side
    /// exposure when widths differ),
    /// expanded state recovers natural width by expand progress.
    clip_width: f32 = 0,
    scale: f32,
    /// Content alpha: 0 for non-topmost layers in collapsed state, else 9px edge exposure cuts text
    /// in half.
    content_alpha: f32,
    /// Card visibility: 0 for layer 4+ in collapsed state; 0 if exceeds max_visible in expanded
    /// state.
    visibility: f32,
    /// Cumulative layer depth (Σ weight of preceding cards).
    depth: f32,
};

pub const StackParams = struct {
    /// Expand progress 0 = collapsed, 1 = expanded.
    expand: f32 = 0,
    max_visible: u8 = Spec.default_max_visible,
};

/// Solve entire stack with single geometry (anchor + sign).
/// Collapsed offset = 9 × depth; expanded offset = Σ(preceding card heights + 9) × weight;
/// interpolate between states by expand.
pub fn solveStack(inputs: []const StackInput, params: StackParams, out: []StackOutput) void {
    std.debug.assert(out.len >= inputs.len);
    const e = clamp01(params.expand);

    // Clipping reference in collapsed state: height and width of topmost non-exiting card.
    var front_height: f32 = 0;
    var front_width: f32 = 0;
    for (inputs) |in| {
        if (!in.leaving) {
            front_height = in.height;
            front_width = in.width;
            break;
        }
    } else if (inputs.len > 0) {
        front_height = inputs[0].height;
        front_width = inputs[0].width;
    }

    var depth: f32 = 0;
    var expanded_offset: f32 = 0;
    const max_visible: f32 = @floatFromInt(@max(params.max_visible, 1));
    for (inputs, 0..) |in, i| {
        const collapsed_offset = Spec.peek * depth;
        const offset = lerp(collapsed_offset, expanded_offset, e);

        const depth1 = @min(depth, 1);
        const collapsed_scale = 1 - @min(depth, Spec.collapsed_scale_max_steps) * Spec.collapsed_scale_step;
        const collapsed_clip = lerp(in.height, front_height, depth1);
        const collapsed_width = if (in.width > 0 and front_width > 0) lerp(in.width, front_width, depth1) else in.width;
        const collapsed_content = 1 - depth1;
        const collapsed_vis = clamp01(Spec.collapsed_visible_layers - depth);
        const expanded_vis = clamp01(max_visible - depth);

        out[i] = .{
            .offset = offset,
            .clip_height = lerp(collapsed_clip, in.height, e),
            .clip_width = lerp(collapsed_width, in.width, e),
            .scale = lerp(collapsed_scale, 1, e),
            .content_alpha = lerp(collapsed_content, 1, e),
            .visibility = lerp(collapsed_vis, expanded_vis, e),
            .depth = depth,
        };

        const w = clamp01(in.weight);
        depth += w;
        expanded_offset += (in.height + Spec.stack_gap) * w;
    }
}

/// Stack outer edge along growth direction (far edge of farthest card), used by badge and hover
/// bounds.
pub fn stackExtent(outputs: []const StackOutput) f32 {
    var extent: f32 = 0;
    for (outputs) |o| {
        if (o.visibility <= 0.01) continue;
        extent = @max(extent, o.offset + o.clip_height);
    }
    return extent;
}

// Timing (lifecycle)

/// Remaining lifespan: deadline model. Pause freezes remaining, resume resets deadline from current
/// time.
pub const Life = struct {
    /// Initial duration (ms); 0 = sticky.
    duration_ms: f64 = 0,
    /// Deadline during running (frame clock ms).
    deadline_ms: f64 = 0,
    /// Remaining time frozen during pause.
    frozen_remaining_ms: ?f64 = null,

    pub fn sticky() Life {
        return .{};
    }

    pub fn start(duration_ms: f64, now_ms: f64) Life {
        return .{ .duration_ms = duration_ms, .deadline_ms = now_ms + duration_ms };
    }

    pub fn isSticky(self: Life) bool {
        return self.duration_ms <= 0;
    }

    pub fn remaining(self: Life, now_ms: f64) f64 {
        if (self.isSticky()) return std.math.inf(f64);
        if (self.frozen_remaining_ms) |r| return r;
        return @max(0, self.deadline_ms - now_ms);
    }

    /// Remaining ratio (life bar / countdown ring), always 1 for sticky.
    pub fn fraction(self: Life, now_ms: f64) f32 {
        if (self.isSticky()) return 1;
        return clamp01(@floatCast(self.remaining(now_ms) / self.duration_ms));
    }

    pub fn pause(self: *Life, now_ms: f64) void {
        if (self.isSticky() or self.frozen_remaining_ms != null) return;
        self.frozen_remaining_ms = self.remaining(now_ms);
    }

    pub fn @"resume"(self: *Life, now_ms: f64) void {
        const r = self.frozen_remaining_ms orelse return;
        self.frozen_remaining_ms = null;
        self.deadline_ms = now_ms + r;
    }

    pub fn expired(self: Life, now_ms: f64) bool {
        if (self.isSticky()) return false;
        return self.remaining(now_ms) <= 0;
    }
};

// Reposition transition: 540ms tween when target jumps,
// follow target directly during frame-driven updates

pub const Follow = struct {
    value: f32 = 0,
    from: f32 = 0,
    target: f32 = 0,
    start_ms: f64 = 0,
    active: bool = false,
    initialized: bool = false,

    /// When continuous = true (card exiting / this card entrance < 620ms / expand/collapse in
    /// progress),
    /// directly track frame-driven target; transitions and frame-driven updates cannot overlap.
    /// Otherwise target jump triggers 540ms tween.
    pub fn step(self: *Follow, target: f32, now_ms: f64, continuous: bool) f32 {
        if (!self.initialized or continuous) {
            self.* = .{ .value = target, .from = target, .target = target, .initialized = true };
            return target;
        }
        if (@abs(target - self.target) > 0.25) {
            self.from = self.value;
            self.target = target;
            self.start_ms = now_ms;
            self.active = true;
        }
        if (self.active) {
            const p = progressOf(now_ms - self.start_ms, Spec.reflow_ms);
            self.value = lerp(self.from, self.target, reflowEase(p));
            if (p >= 1) {
                self.value = self.target;
                self.active = false;
            }
        } else {
            self.value = self.target;
        }
        return self.value;
    }

    /// Anchor pan (window size change): current value, tween start, and target all shift together,
    /// in-progress reflow tween continues without restarting. Window change is rigid translation,
    /// not reflow;
    /// treating it as target jump would cause trailing in normal resize and stall mid-animation
    /// during live resize
    /// (after AppKit stops rendering once drag stops, stack falls below window bottom).
    pub fn shift(self: *Follow, delta: f32) void {
        if (!self.initialized) return;
        self.value += delta;
        self.from += delta;
        self.target += delta;
    }
};

// Timestamp text

pub const RelativeTime = union(enum) {
    now,
    minutes: u32,
    hours: u32,
    days: u32,
};

pub fn relativeTime(elapsed_ms: i64) RelativeTime {
    const s = @divTrunc(@max(elapsed_ms, 0), 1000);
    if (s < 60) return .now;
    const m = @divTrunc(s, 60);
    if (m < 60) return .{ .minutes = @intCast(m) };
    const h = @divTrunc(m, 60);
    if (h < 24) return .{ .hours = @intCast(h) };
    return .{ .days = @intCast(@divTrunc(h, 24)) };
}

// Tests

const testing = std.testing;

test "Position: sign / entry / fling / pill follow the 16.1 table" {
    try testing.expectEqual(@as(f32, -1), Position.bottom_center.sign());
    try testing.expectEqual(@as(f32, 1), Position.top_left.sign());
    try testing.expectEqual(@as(f32, 1), Position.left_center.sign());
    try testing.expectEqual(@as(f32, 22), Position.bottom_right.entryOffset(22).y);
    try testing.expectEqual(@as(f32, -22), Position.top_center.entryOffset(22).y);
    try testing.expectEqual(@as(f32, 22), Position.right_center.entryOffset(22).x);
    try testing.expectEqual(@as(f32, -22), Position.left_center.entryOffset(22).x);
    try testing.expectEqual(@as(f32, -1), Position.bottom_left.flingDirection());
    try testing.expectEqual(@as(f32, 0), Position.top_center.flingDirection());
    try testing.expect(!Position.top_right.pillAbove());
    try testing.expect(Position.bottom_center.pillAbove());
    try testing.expect(Position.right_center.pillAbove());
}

test "solveStack: collapsed geometry — 9px peek, width steps, clipped to front, content hidden" {
    const inputs = [_]StackInput{ .{ .height = 70 }, .{ .height = 124 }, .{ .height = 90 }, .{ .height = 80 } };
    var out: [4]StackOutput = undefined;
    solveStack(&inputs, .{ .expand = 0 }, &out);
    try testing.expectApproxEqAbs(@as(f32, 0), out[0].offset, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 9), out[1].offset, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 18), out[2].offset, 1e-4);
    // Later layer clipped to topmost card height, edge exposure equal width and height.
    try testing.expectApproxEqAbs(@as(f32, 70), out[1].clip_height, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 70), out[2].clip_height, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1 - 0.038), out[1].scale, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1 - 3 * 0.038), out[3].scale, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1), out[0].content_alpha, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), out[1].content_alpha, 1e-4);
    // Layer 4+ not visible, deferred to badge.
    try testing.expectApproxEqAbs(@as(f32, 1), out[2].visibility, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), out[3].visibility, 1e-4);
}

test "solveStack: expanded geometry — real heights, gap 9" {
    const inputs = [_]StackInput{ .{ .height = 70 }, .{ .height = 124 }, .{ .height = 90 }, .{ .height = 80 }, .{ .height = 60 } };
    var out: [5]StackOutput = undefined;
    solveStack(&inputs, .{ .expand = 1, .max_visible = 4 }, &out);
    try testing.expectApproxEqAbs(@as(f32, 0), out[0].offset, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 79), out[1].offset, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 79 + 133), out[2].offset, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 124), out[1].clip_height, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1), out[3].scale, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1), out[3].visibility, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), out[4].visibility, 1e-4);
}

test "solveStack: a leaving middle card collapses its height contribution continuously" {
    var inputs = [_]StackInput{ .{ .height = 70 }, .{ .height = 100 }, .{ .height = 80 } };
    var out: [3]StackOutput = undefined;
    var prev: f32 = std.math.inf(f32);
    var p: f32 = 0;
    while (p <= 1.0001) : (p += 0.05) {
        inputs[1].weight = 1 - p;
        inputs[1].leaving = true;
        solveStack(&inputs, .{ .expand = 1 }, &out);
        // Card below repositions monotonically, continuously: each step <= (100+9)×0.05.
        try testing.expect(out[2].offset <= prev + 1e-3);
        if (prev != std.math.inf(f32)) try testing.expect(prev - out[2].offset <= 109 * 0.05 + 1e-3);
        prev = out[2].offset;
    }
    try testing.expectApproxEqAbs(@as(f32, 79), out[2].offset, 1e-3);
}

test "solveStack: leaving front card does not become the collapsed clip reference" {
    const inputs = [_]StackInput{ .{ .height = 140, .leaving = true, .weight = 0.5 }, .{ .height = 70 }, .{ .height = 90 } };
    var out: [3]StackOutput = undefined;
    solveStack(&inputs, .{ .expand = 0 }, &out);
    try testing.expectApproxEqAbs(@as(f32, 70), out[2].clip_height, 1e-4);
}

test "solveStack: 后层宽度折叠时收拢到最前那张、展开时按进度恢复自身宽度" {
    const inputs = [_]StackInput{
        .{ .height = 36, .width = 95 },
        .{ .height = 36, .width = 220 },
        .{ .height = 90, .width = 392 },
    };
    var out: [3]StackOutput = undefined;
    solveStack(&inputs, .{ .expand = 0 }, &out);
    for (out) |o| try std.testing.expectApproxEqAbs(@as(f32, 95), o.clip_width, 1e-4);
    solveStack(&inputs, .{ .expand = 1 }, &out);
    for (out, inputs) |o, in| try std.testing.expectApproxEqAbs(in.width, o.clip_width, 1e-4);
    // Expand in progress: continuous interpolation (tween), no jumps.
    solveStack(&inputs, .{ .expand = 0.5 }, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 95), out[0].clip_width, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, (95.0 + 220.0) / 2.0), out[1].clip_width, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, (95.0 + 392.0) / 2.0), out[2].clip_width, 1e-4);
    // Inputs without width remain 0 (don't participate in collapse).
    const legacy = [_]StackInput{ .{ .height = 60 }, .{ .height = 80 } };
    var out2: [2]StackOutput = undefined;
    solveStack(&legacy, .{}, &out2);
    try std.testing.expectEqual(@as(f32, 0), out2[1].clip_width);
}

test "enter / exit / stagger curves hit their endpoints" {
    const e0 = enterMotion(0);
    try testing.expectApproxEqAbs(@as(f32, 1), e0.offset, 1e-4);
    try testing.expectApproxEqAbs(Spec.enter_scale_from, e0.scale, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), e0.alpha, 1e-4);
    const e1 = enterMotion(Spec.enter_ms);
    try testing.expectApproxEqAbs(@as(f32, 0), e1.offset, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1), e1.alpha, 1e-4);

    const x0 = exitMotion(0);
    try testing.expectApproxEqAbs(@as(f32, 1), x0.alpha, 1e-4);
    try testing.expect(!x0.done);
    const xm = exitMotion(Spec.exit_ms / 2);
    try testing.expectApproxEqAbs(std.math.pow(f32, 0.5, 1.6), xm.alpha, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1 - easeOutCubic(0.5)), xm.weight, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1 - Spec.exit_scale_loss / 2), xm.scale, 1e-4);
    try testing.expect(exitMotion(Spec.exit_ms).done);

    // Layered stagger: maintain initial offset during delay, last layer no later than card entrance
    // ends.
    try testing.expectApproxEqAbs(Spec.stagger_offset, staggerMotion(Spec.title_delay_ms, Spec.title_delay_ms).offset, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), staggerMotion(0, Spec.body_delay_ms).alpha, 1e-4);
    try testing.expect(Spec.footer_delay_ms + Spec.stagger_ms <= Spec.enter_ms);
    // Opacity finishes before offset.
    try testing.expectApproxEqAbs(@as(f32, 1), enterMotion(Spec.enter_ms * Spec.enter_fade_portion).alpha, 1e-4);

    const pop = iconPop(0, Spec.icon_pop_ms);
    try testing.expectApproxEqAbs(@as(f32, 0.9), pop.scale, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), pop.rotate_deg, 1e-4);
    // No overshoot.
    var t: f64 = 0;
    while (t <= Spec.icon_pop_ms) : (t += 10) try testing.expect(iconPop(t, Spec.icon_pop_ms).scale <= 1.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), iconPop(Spec.icon_pop_ms, Spec.icon_pop_ms).scale, 1e-4);
}

test "swipe: threshold, direction constraint, alpha floor" {
    try testing.expect(!swipeCommits(.bottom_center, 40));
    try testing.expect(swipeCommits(.bottom_center, 84));
    try testing.expect(swipeCommits(.bottom_center, -90));
    try testing.expect(!swipeCommits(.bottom_right, -120));
    try testing.expect(swipeCommits(.bottom_right, 120));
    try testing.expectApproxEqAbs(@as(f32, -4), constrainSwipe(.top_right, -20), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.25), swipeAlpha(400), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1 - 40.0 / 190.0), swipeAlpha(-40), 1e-4);
}

test "Life: pause freezes remaining, resume continues from the frozen point" {
    var life = Life.start(3600, 1000);
    try testing.expectApproxEqAbs(@as(f64, 2600), life.remaining(2000), 1e-6);
    life.pause(2000);
    try testing.expectApproxEqAbs(@as(f64, 2600), life.remaining(9000), 1e-6);
    try testing.expect(!life.expired(9000));
    life.@"resume"(9000);
    try testing.expectApproxEqAbs(@as(f64, 2600), life.remaining(9000), 1e-6);
    try testing.expect(life.expired(11600));
    try testing.expect(!Life.sticky().expired(1e12));
    try testing.expectApproxEqAbs(@as(f32, 1), Life.sticky().fraction(5), 1e-6);
}

test "Follow: tweens on target jumps, follows directly while continuous" {
    var f = Follow{};
    try testing.expectApproxEqAbs(@as(f32, 0), f.step(0, 0, false), 1e-4);
    _ = f.step(100, 1000, false);
    const mid = f.step(100, 1270, false);
    try testing.expect(mid > 0 and mid < 100);
    try testing.expectApproxEqAbs(@as(f32, 100), f.step(100, 1540, false), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 42), f.step(42, 1541, true), 1e-4);
}

test "relativeTime buckets" {
    try testing.expectEqual(RelativeTime.now, relativeTime(59_000));
    try testing.expectEqual(RelativeTime{ .minutes = 1 }, relativeTime(60_000));
    try testing.expectEqual(RelativeTime{ .hours = 2 }, relativeTime(2 * 3_600_000 + 5));
    try testing.expectEqual(RelativeTime{ .days = 1 }, relativeTime(25 * 3_600_000));
}
