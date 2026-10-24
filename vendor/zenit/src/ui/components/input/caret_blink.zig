//! Caret blink phase, split out of `TextInputState`.
//!
//! Pure time arithmetic: touches no other input state (buffer / cursor / selection / IME).
//! Phase calculation is unit-testable with **constructed timestamps** (blink half-period,
//! same-frame reset on Tab refocus).
//!
//! **Interface cut**: this module answers 'should caret show now' and 'time until next phase flip'.
//! `last_blink_visible` (prior frame visibility, used to dirty-mark only on flip) belongs to
//! the caller's render dirty-mark bookkeeping, not to the phase itself.

const std = @import("std");

/// Blink half-period: visible 500ms, invisible 500ms.
pub const half_period_ns: u64 = 500 * std.time.ns_per_ms;

pub const CaretBlink = struct {
    /// Phase start point. null = phase not started yet (first query auto-fills now).
    epoch: ?@import("zenit_time").Instant = null,

    /// Set phase back to 'just lit up'. Any action making caret immediately visible should call it
    /// (typing, cursor move, gain focus...), else user sees caret disappear while typing.
    ///
    /// Instant.now() failure store null: next query retries, better than caching wrong time.
    pub fn reset(self: *CaretBlink, io: std.Io) void {
        self.epoch = @import("zenit_time").Instant.now(io) catch null;
    }

    /// Should current phase display caret.
    ///
    /// No phase yet auto-fill here (so `*CaretBlink` not const).
    pub fn visible(self: *CaretBlink, now: @import("zenit_time").Instant) bool {
        if (self.epoch == null) self.epoch = now;
        const epoch = self.epoch orelse return true;
        // WARNING—safe subtraction: epoch can be later than now, Tab focus-switch same frame
        // reset then query, two Instants' sample points can invert. Raw subtract underflows to
        // huge number, caret random flicker.
        const elapsed = now.since(epoch);
        return ((elapsed / half_period_ns) % 2) == 0;
    }

    /// Nanoseconds until next phase flip. Caller uses it to decide next wake time,
    /// avoid idle loop spin just to blink caret.
    pub fn nextDelayNs(self: *const CaretBlink, now: @import("zenit_time").Instant) u64 {
        const epoch = self.epoch orelse return half_period_ns;
        const elapsed = now.since(epoch);
        const phase_index = elapsed / half_period_ns;
        return ((phase_index + 1) * half_period_ns) - elapsed;
    }
};

// ── test ───────────────────────────────────────────────────────────────
//
// Previously three functions testable only by running real app, watching caret with eyes.
// After extraction can directly construct timestamps assert phase.

/// Construct Instant delta_ns later than base.
fn advance(base: @import("zenit_time").Instant, delta_ns: u64) @import("zenit_time").Instant {
    return .{ .timestamp = base.timestamp + delta_ns };
}

test "未起相位时 visible 返回 true 并就地起相位" {
    var b = CaretBlink{};
    // SKIP-REASON: platform lacks monotonic clock so Instant.now() fails, this phase test can't
    // construct timestamps
    const now = @import("zenit_time").Instant.now(std.testing.io) catch return error.SkipZigTest;
    try std.testing.expect(b.visible(now));
    try std.testing.expect(b.epoch != null);
}

test "相位在半周期处翻转，一个整周期后回到可见" {
    // SKIP-REASON: platform lacks monotonic clock so Instant.now() fails, this phase test can't
    // construct timestamps
    const base = @import("zenit_time").Instant.now(std.testing.io) catch return error.SkipZigTest;
    var b = CaretBlink{ .epoch = base };

    try std.testing.expect(b.visible(base)); // t=0 lit
    try std.testing.expect(b.visible(advance(base, half_period_ns - 1)));
    try std.testing.expect(!b.visible(advance(base, half_period_ns))); // flip
    try std.testing.expect(!b.visible(advance(base, half_period_ns * 2 - 1)));
    try std.testing.expect(b.visible(advance(base, half_period_ns * 2))); // back to lit
}

test "reset 把相位拨回刚亮起" {
    // SKIP-REASON: platform lacks monotonic clock so Instant.now() fails, this phase test can't
    // construct timestamps
    const base = @import("zenit_time").Instant.now(std.testing.io) catch return error.SkipZigTest;
    var b = CaretBlink{ .epoch = base };
    // reach invisible phase
    try std.testing.expect(!b.visible(advance(base, half_period_ns)));
    b.reset(std.testing.io);
    // after reset use its own new epoch query, must be lit
    const after = b.epoch.?;
    try std.testing.expect(b.visible(after));
}

test "nextDelayNs 给出到下次翻转的剩余时间" {
    // SKIP-REASON: platform lacks monotonic clock so Instant.now() fails, this phase test can't
    // construct timestamps
    const base = @import("zenit_time").Instant.now(std.testing.io) catch return error.SkipZigTest;
    var b = CaretBlink{ .epoch = base };

    try std.testing.expectEqual(half_period_ns, b.nextDelayNs(base));
    try std.testing.expectEqual(@as(u64, 1), b.nextDelayNs(advance(base, half_period_ns - 1)));
    // just past flip point => entire half-period until next flip
    try std.testing.expectEqual(half_period_ns, b.nextDelayNs(advance(base, half_period_ns)));
}

test "未起相位时 nextDelayNs 回退到半周期" {
    const b = CaretBlink{};
    // SKIP-REASON: platform lacks monotonic clock so Instant.now() fails, this phase test can't
    // construct timestamps
    const now = @import("zenit_time").Instant.now(std.testing.io) catch return error.SkipZigTest;
    try std.testing.expectEqual(half_period_ns, b.nextDelayNs(now));
}

test "epoch 比 now 更晚时不下溢（Tab 切焦点同帧 reset 的形状）" {
    // SKIP-REASON: platform lacks monotonic clock so Instant.now() fails, this phase test can't
    // construct timestamps
    const base = @import("zenit_time").Instant.now(std.testing.io) catch return error.SkipZigTest;
    // epoch in 'future': safeElapsedNs must clamp to 0, not underflow to huge
    var b = CaretBlink{ .epoch = advance(base, half_period_ns) };
    try std.testing.expect(b.visible(base)); // elapsed=0 => lit
    try std.testing.expectEqual(half_period_ns, b.nextDelayNs(base));
}
