//! iOS tab bar selection lens dynamics, fitted to native UITabBar traces.
//!
//! Measured on the iOS 26.5 Simulator (iPhone 17 Pro) with XCUITest touches and a per-frame
//! presentation-layer trace (scripts/glass_native_model/ios/run_uitest.sh, gesture `tabbar`; fit:
//! ios/fit_tab_dynamics.py; frame-by-frame replay comparison: ios/compare_tab_dynamics.py). The selection is a `_UILiquidLensView` holding an opaque plate
//! (`_UITabSelectionView`) and a clear glass lens; a second, accent-colored set of tab buttons is
//! masked to it.
//!
//! - Touch-down on a tab sends the lens there at once (not on release), the finger still down.
//! - While the finger is down the lens lifts: it grows to 1.23 x 1.36 of the tab button, the
//!   plate fades out (the clear glass lens shows) and the content inside it magnifies. A held lens
//!   sent to another tab runs there wide and flat, then rises and rings down (speed- and
//!   acceleration-driven held shape).
//! - A tapped lens (finger up) travels narrow and tall, then rings wide: a travel lift and
//!   height / width oscillators driven by its acceleration.
//! - Dragging after the press moves the lens with the finger (a softer spring); on release it
//!   settles on the nearest tab, which becomes selected.
//! - The whole platter grows by 5 % about its centre while the finger is down, and the lens
//!   positions spread out with it (fitted spread 1.16 x the growth).
//!
//! Native timings carry a ~20-30 ms touch-to-presentation latency; it is not reproduced (it is
//! the input pipeline, not the animation).
const std = @import("std");

/// Fitted constants (ios/fit_tab_dynamics.py `P`). Springs are (response s, damping fraction).
pub const Spec = struct {
    /// Travel to a tapped tab and the release snap
    pos: [2]f32 = .{ 0.3744, 0.8367 },
    /// Following the finger while dragging: near-critical (a lens flung at 1500-2500 pt/s stops
    /// without overshooting, native `fastdrag` recording; 0.6 damping overshot ~10 pt)
    drag: [2]f32 = .{ 0.1561, 0.9583 },
    /// Held shape (finger down), per axis {width, height}: a spring toward
    /// press + k_speed * (|v| / 1000 pt/s) + k_accel * (acceleration along the motion / 1e4 pt/s^2).
    /// Fitted jointly to the `tabbar` (taps, a press that sends the lens to another tab, a slow
    /// drag) and `fastdrag` (presses flung at 1500 / 2500 pt/s) recordings: a press in place
    /// rises to ~1.21 x 1.36 of the button without overshoot (native), and a flung lens swings
    /// once rather than ringing (the earlier single-recording fit, damping 0.34 / 0.17, read the
    /// lens's run to the pressed tab as ringing: it wobbled like jelly when flung).
    press: [2]f32 = .{ 0.2047, 0.3762 },
    k_speed: [2]f32 = .{ 0.0293, -0.1484 },
    k_accel: [2]f32 = .{ 0.0568, 0.0435 },
    shape_w: [2]f32 = .{ 0.3572, 0.6886 },
    shape_h: [2]f32 = .{ 0.3131, 1.1245 },
    /// The held shape releasing (finger up): native held 122 x 74 -> rest within ~0.2 s
    release_w: [2]f32 = .{ 0.3746, 0.7519 },
    release_h: [2]f32 = .{ 0.2121, 0.9345 },
    /// Tapped shape (finger up, lens on its way): travel lift spring toward `fast` and its size
    /// gain {width, height}, plus height / width oscillators driven by the acceleration along the
    /// motion (per 1e5 pt/s^2): a tap travels narrow and tall, then rings wide.
    travel_lift: [2]f32 = .{ 0.0703, 0.5871 },
    travel_size: [2]f32 = .{ -0.1057, 0.1118 },
    wobble_h: [2]f32 = .{ 0.3445, 1.1088 },
    wobble_h_gain: f32 = -2.8544,
    wobble_w: [2]f32 = .{ 0.3195, 0.628 },
    wobble_w_gain: f32 = -4.939,
    /// Signed squash: the lens's horizontal scale follows its signed velocity (per 1000 pt/s)
    /// through a spring, with its own response, damping and gain per touch state, and the
    /// height scales by `squash_ratio` times as much. Native (the lens view's transform
    /// sx / sy, `flings` and `taps_lr` recordings): a held lens flung right stretches (sx 1.13)
    /// and swings back (0.90), flung left the mirror image; a tapped lens squeezes on its way
    /// (0.84 going right, 1.11 going left). A model driven by |v| alone (fitted to rightward
    /// motion only) got every leftward move backwards.
    squash_down: [2]f32 = .{ 0.517, 0.30 },
    squash_down_gain: f32 = 0.173,
    squash_up: [2]f32 = .{ 0.289, 0.302 },
    squash_up_gain: f32 = -0.110,
    /// ... plus the lens's distance from its goal (per 100 pt): a held lens flung past the
    /// finger (the platter's spread) stays squeezed until it is back (native sx 0.90 held
    /// 0.3 s); without it a fit read that as a slow underdamped ring (damping 0.13).
    squash_down_pull: f32 = -0.087,
    squash_up_pull: f32 = -0.099,
    squash_ratio: f32 = -1.137,
    /// "Travelling" (plate off, accent on, finger up) is a speed: a lens on its way to a tab (not
    /// following a dragging finger) faster than `fast` pt/s, smoothly. Native tap: the plate
    /// starts back at ~50 pt/s; a released drag settling a few pt never hides it.
    fast: [2]f32 = .{ 28.52, 85.45 },
    /// Plate opacity first-order time constant (s): 0 while down or travelling, else 1
    plate_tau: f32 = 0.0667,
    /// Accent content magnification (the portal of the bar content inside the lens): the same
    /// while held and while a tapped lens travels (trace: 1.160 held, 1.157 on a tap), reached
    /// monotonically and then held still whatever the lens does (Home accent sx 1.160 and cx
    /// 70.9 constant while the lens rings 106..129 x 65..78).
    accent: [2]f32 = .{ 0.1991, 1.1116 },
    /// Drawn gain: the trace's transform (1.16) understates the drawn accent (1.23 on the held
    /// capture, Library glyph and label: interaction/tabbar_hold_t8/t9.png).
    accent_gain: f32 = 0.23,
    /// Platter growth while the finger is down: spring and gain (fraction of its size)
    platter: [2]f32 = .{ 0.352, 0.5957 },
    platter_gain: f32 = 0.0514,
    /// Lens positions spread from the platter centre by this times the platter growth
    spread: f32 = 1.1628,
};

pub const spec = Spec{};

const Spring = struct {
    x: f32 = 0,
    v: f32 = 0,

    fn step(self: *Spring, target: f32, s: [2]f32, dt: f32) void {
        const w = 2.0 * std.math.pi / s[0];
        const a = -w * w * (self.x - target) - 2.0 * s[1] * w * self.v;
        self.v += a * dt;
        self.x += self.v * dt;
    }

    fn still(self: Spring, target: f32, eps: f32) bool {
        return @abs(self.x - target) < eps and @abs(self.v) < eps * 10;
    }
};

fn smoothstep(e0: f32, e1: f32, x: f32) f32 {
    const t = std.math.clamp((x - e0) / (e1 - e0), 0, 1);
    return t * t * (3 - 2 * t);
}

/// Lens state in platter coordinates (x along the bar).
pub const TabMotion = struct {
    spec: *const Spec = &spec,
    /// Lens rest size (the tab button) and the platter centre x
    rest: [2]f32,
    centre: f32,
    x: Spring,
    target: f32,
    held_w: Spring = .{},
    held_h: Spring = .{},
    travel_lift: Spring = .{},
    wobble_h: Spring = .{},
    wobble_w: Spring = .{},
    accent: Spring = .{},
    platter: Spring = .{},
    squash: Spring = .{},
    plate: f32 = 1,
    prev_v: f32 = 0,
    down: bool = false,
    dragging: bool = false,

    pub fn init(rest: [2]f32, centre: f32, x: f32) TabMotion {
        return .{ .rest = rest, .centre = centre, .x = .{ .x = x }, .target = x };
    }

    /// Finger down: the lens heads for `x` (a tab centre) and lifts.
    pub fn press(self: *TabMotion, x: f32) void {
        self.down = true;
        self.dragging = false;
        self.target = x;
    }

    /// Finger moved while down: the lens follows `x` (clamped by the caller).
    pub fn drag(self: *TabMotion, x: f32) void {
        self.dragging = true;
        self.target = x;
    }

    /// Finger up (or the touch was cancelled): settle on `x`.
    pub fn release(self: *TabMotion, x: f32) void {
        self.down = false;
        self.dragging = false;
        self.target = x;
    }

    /// Move to `x` without a touch (programmatic selection change).
    pub fn goTo(self: *TabMotion, x: f32) void {
        if (!self.down) self.target = x;
    }

    /// Target in the grown platter's frame.
    fn goal(self: *const TabMotion) f32 {
        return self.centre + (self.target - self.centre) * (1 + self.spec.spread * self.platter.x);
    }

    /// Advance by `dt` seconds (fixed 240 Hz substeps).
    pub fn step(self: *TabMotion, dt: f32) void {
        const h: f32 = 1.0 / 240.0;
        var left = std.math.clamp(dt, 0, 0.1);
        while (left > 1e-6) {
            const d = @min(h, left);
            self.substep(d);
            left -= d;
        }
    }

    fn substep(self: *TabMotion, dt: f32) void {
        const s = self.spec;
        const g = self.goal();
        self.x.step(g, if (self.dragging) s.drag else s.pos, dt);
        const along = (self.x.v - self.prev_v) / dt * @as(f32, if (g >= self.x.x) 1 else -1);
        self.prev_v = self.x.v;
        const speed = @abs(self.x.v);
        // Travelling = fast on the way to a tab (see Spec.fast)
        const fast: f32 = if (self.dragging) 0 else smoothstep(s.fast[0], s.fast[1], speed);
        // Held shape while down, released when up
        const hw: f32 = if (self.down) s.press[0] + s.k_speed[0] * speed * 1e-3 + s.k_accel[0] * along * 1e-4 else 0;
        const hh: f32 = if (self.down) s.press[1] + s.k_speed[1] * speed * 1e-3 + s.k_accel[1] * along * 1e-4 else 0;
        // bounded: the speed / acceleration terms were fitted up to 3000 pt/s flings
        self.held_w.step(std.math.clamp(hw, -0.6, 0.8), if (self.down) s.shape_w else s.release_w, dt);
        self.held_h.step(std.math.clamp(hh, -0.6, 0.8), if (self.down) s.shape_h else s.release_h, dt);
        // Tapped shape: only while the finger is up
        const drive: f32 = if (self.down) 0 else along * 1e-5;
        self.travel_lift.step(if (self.down) 0 else fast, s.travel_lift, dt);
        self.wobble_h.step(s.wobble_h_gain * drive, s.wobble_h, dt);
        self.wobble_w.step(s.wobble_w_gain * drive, s.wobble_w, dt);
        self.accent.step(if (self.down) s.accent_gain else s.accent_gain * fast, s.accent, dt);
        self.platter.step(if (self.down) s.platter_gain else 0, s.platter, dt);
        const pull = (g - self.x.x) * 1e-2;
        const sq_drive = if (self.down) s.squash_down_gain * self.x.v * 1e-3 + s.squash_down_pull * pull else s.squash_up_gain * self.x.v * 1e-3 + s.squash_up_pull * pull;
        self.squash.step(sq_drive, if (self.down) s.squash_down else s.squash_up, dt);
        const plate_goal: f32 = if (self.down) 0 else 1 - fast;
        self.plate += (plate_goal - self.plate) * (1.0 - @exp(-dt / s.plate_tau));
    }

    /// Lens {centre x, width, height} (centre y is the row's).
    pub fn lens(self: *const TabMotion) [3]f32 {
        const s = self.spec;
        const gw = self.held_w.x + self.travel_lift.x * s.travel_size[0] + std.math.clamp(self.wobble_w.x, -0.4, 0.4);
        const gh = self.held_h.x + self.travel_lift.x * s.travel_size[1] + std.math.clamp(self.wobble_h.x, -0.4, 0.4);
        const sq = std.math.clamp(self.squash.x, -0.4, 0.4);
        return .{ self.x.x, @max(self.rest[0] * (1 + gw) * (1 + sq), 1), @max(self.rest[1] * (1 + gh) * (1 + s.squash_ratio * sq), 1) };
    }

    /// Opacity of the opaque selection plate (1 at rest); the clear lens shows as 1 - plate.
    pub fn plateAlpha(self: *const TabMotion) f32 {
        return std.math.clamp(self.plate, 0, 1);
    }

    pub fn accentScale(self: *const TabMotion) f32 {
        return 1 + @max(self.accent.x, 0);
    }

    pub fn platterScale(self: *const TabMotion) f32 {
        return 1 + self.platter.x;
    }

    /// Everything the layers read: lens, plate, accent and platter scale.
    pub fn pose(self: *const TabMotion) [6]f32 {
        const l = self.lens();
        return .{ l[0], l[1], l[2], self.plateAlpha(), self.accentScale(), self.platterScale() };
    }

    pub fn poseStill(a: [6]f32, b: [6]f32) bool {
        for (a, b) |x, y| if (@abs(x - y) > 1e-4) return false;
        return true;
    }

    pub fn settled(self: *const TabMotion) bool {
        return !self.down and self.x.still(self.target, 0.05) and self.held_w.still(0, 1e-3) and self.held_h.still(0, 1e-3) and
            self.travel_lift.still(0, 1e-3) and self.wobble_h.still(0, 1e-3) and self.wobble_w.still(0, 1e-3) and
            self.accent.still(0, 1e-3) and self.platter.still(0, 1e-4) and self.squash.still(0, 1e-3) and self.plate > 0.999;
    }

    /// Snap every channel to rest at the target.
    pub fn settle(self: *TabMotion) void {
        self.* = .{ .spec = self.spec, .rest = self.rest, .centre = self.centre, .x = .{ .x = self.target }, .target = self.target };
    }
};

fn run(m: *TabMotion, seconds: f32) void {
    var t: f32 = 0;
    while (t < seconds) : (t += 1.0 / 60.0) m.step(1.0 / 60.0);
}

test "TabMotion: tap travels, plate dips and returns, lens settles at rest size" {
    var m = TabMotion.init(.{ 100.7, 54 }, 145, 75.35);
    m.press(166.05);
    run(&m, 0.065);
    m.release(166.05);
    var min_plate: f32 = 1;
    var t: f32 = 0;
    while (t < 0.3) : (t += 1.0 / 60.0) {
        m.step(1.0 / 60.0);
        min_plate = @min(min_plate, m.plateAlpha());
    }
    // native: the plate all but vanishes mid-travel (0.02) and the lens has covered most of it
    try std.testing.expect(min_plate < 0.1);
    try std.testing.expect(m.lens()[0] > 150);
    run(&m, 2.0);
    try std.testing.expect(m.settled());
    const r = m.lens();
    try std.testing.expectApproxEqAbs(@as(f32, 166.05), r[0], 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 100.7), r[1], 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 54), r[2], 0.1);
}

test "TabMotion: long press lifts, drag follows the finger, release snaps" {
    var m = TabMotion.init(.{ 100.7, 54 }, 145, 75.35);
    m.press(75.35);
    run(&m, 0.8);
    // the lens spreads out with the grown platter (native: Home 75.35 -> 69.2)
    try std.testing.expectApproxEqAbs(@as(f32, 145 - (145 - 75.35) * (1 + 1.1628 * 0.0514)), m.lens()[0], 0.5);
    // lifted: 1.21 x 1.34 of the button, plate gone, platter grown 5 %
    const l = m.lens();
    try std.testing.expectApproxEqAbs(@as(f32, 100.7 * 1.215), l[1], 3);
    try std.testing.expectApproxEqAbs(@as(f32, 54 * 1.343), l[2], 3);
    try std.testing.expect(m.plateAlpha() < 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0514), m.platterScale(), 0.005);
    var x: f32 = 75.35;
    while (x < 200) : (x += 3) {
        m.drag(x);
        m.step(1.0 / 60.0);
    }
    m.drag(200);
    run(&m, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 145 + (200 - 145) * (1 + 1.1628 * 0.0514)), m.lens()[0], 2);
    try std.testing.expect(!m.settled());
    m.release(166.05);
    run(&m, 2.5);
    try std.testing.expect(m.settled());
    try std.testing.expectApproxEqAbs(@as(f32, 166.05), m.lens()[0], 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 1), m.plateAlpha(), 0.001);
}

test "TabMotion: held accent holds still while the lens wobbles; release settles like native" {
    // Long press the middle tab (no travel): the accent reaches its gain and then holds still
    var m = TabMotion.init(.{ 100.7, 54 }, 145, 166.05);
    m.press(166.05);
    run(&m, 0.3);
    const a0 = m.accentScale();
    var t: f32 = 0;
    while (t < 0.6) : (t += 1.0 / 60.0) {
        m.step(1.0 / 60.0);
        try std.testing.expectApproxEqAbs(a0, m.accentScale(), 0.003);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 1.23), m.accentScale(), 0.01);
    // Drag a little and release: native plate 0.79 at 0.13 s, everything back by 0.3 s
    m.drag(172);
    run(&m, 0.5);
    m.release(166.05);
    run(&m, 0.133);
    try std.testing.expect(m.plateAlpha() > 0.7);
    try std.testing.expect(m.lens()[1] < 107);
    run(&m, 0.167);
    try std.testing.expect(m.plateAlpha() > 0.95);
    try std.testing.expectApproxEqAbs(@as(f32, 100.7), m.lens()[1], 2.5);
    try std.testing.expectApproxEqAbs(@as(f32, 54), m.lens()[2], 2.5);
    try std.testing.expect(m.accentScale() < 1.02);
}
