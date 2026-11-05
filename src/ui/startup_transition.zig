//! One-shot startup timing. Resource completion/failure releases immediately;
//! a slow image cannot keep the workspace covered indefinitely.
const std = @import("std");

pub const max_wait_ms = 2000;
pub const fade_ms = 180;

pub const Transition = struct {
    started_ms: ?u64 = null,
    fade_started_ms: ?u64 = null,
    finished: bool = false,

    pub fn sample(self: *Transition, now_ms: u64, settled: bool, reduced_motion: bool) f32 {
        if (self.finished) return 0;
        const started = self.started_ms orelse blk: {
            self.started_ms = now_ms;
            break :blk now_ms;
        };
        if (self.fade_started_ms == null and (settled or now_ms -| started >= max_wait_ms)) {
            // Fast startup has no minimum splash duration or mandatory fade.
            if (reduced_motion or now_ms == started) {
                self.finished = true;
                return 0;
            }
            self.fade_started_ms = now_ms;
        }
        if (self.fade_started_ms) |fade_started| {
            const elapsed = now_ms -| fade_started;
            if (reduced_motion or elapsed >= fade_ms) {
                self.finished = true;
                return 0;
            }
            const remaining = 1 - @as(f32, @floatFromInt(elapsed)) / fade_ms;
            return remaining * remaining;
        }
        return 1;
    }
};

test "startup transition releases fast ready resources without a minimum delay" {
    var state: Transition = .{};
    try std.testing.expectEqual(@as(f32, 0), state.sample(100, true, false));
    try std.testing.expect(state.finished);
    try std.testing.expectEqual(@as(f32, 0), state.sample(110, false, false));
}

test "startup transition fades on completion or failure and never restarts" {
    var state: Transition = .{};
    try std.testing.expectEqual(@as(f32, 1), state.sample(100, false, false));
    try std.testing.expectEqual(@as(f32, 1), state.sample(140, true, false));
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), state.sample(230, false, false), 0.001);
    try std.testing.expectEqual(@as(f32, 0), state.sample(320, false, false));
    try std.testing.expectEqual(@as(f32, 0), state.sample(400, false, false));
}

test "startup transition has a bounded wait and respects reduced motion" {
    var state: Transition = .{};
    _ = state.sample(0, false, false);
    try std.testing.expectEqual(@as(f32, 1), state.sample(max_wait_ms - 1, false, false));
    _ = state.sample(max_wait_ms, false, false);
    try std.testing.expectEqual(@as(f32, 0), state.sample(max_wait_ms + fade_ms, false, false));
    var reduced: Transition = .{};
    _ = reduced.sample(0, false, true);
    try std.testing.expectEqual(@as(f32, 0), reduced.sample(40, true, true));
}
