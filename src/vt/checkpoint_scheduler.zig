const std = @import("std");

/// Deterministic scheduler for periodic raw-stream checkpoint writes.
pub const Scheduler = struct {
    interval_ms: i64,
    next_due_ms: i64,
    last_checkpoint_ms: ?i64 = null,

    pub fn init(interval_sec: u16, now_ms: i64) !Scheduler {
        if (interval_sec == 0) return error.InvalidInterval;
        const interval_ms = @as(i64, interval_sec) * std.time.ms_per_s;
        return .{ .interval_ms = interval_ms, .next_due_ms = now_ms + interval_ms };
    }

    pub fn due(self: *const Scheduler, now_ms: i64) bool {
        return now_ms >= self.next_due_ms;
    }

    /// Advances the deadline without catch-up storms after a long pause.
    pub fn checkpointed(self: *Scheduler, now_ms: i64) void {
        self.last_checkpoint_ms = now_ms;
        self.next_due_ms = now_ms + self.interval_ms;
    }
};

test "checkpoint scheduler waits and advances after a checkpoint" {
    var scheduler = try Scheduler.init(30, 1_000);
    try std.testing.expect(!scheduler.due(30_999));
    try std.testing.expect(scheduler.due(31_000));
    scheduler.checkpointed(31_250);
    try std.testing.expectEqual(@as(i64, 61_250), scheduler.next_due_ms);
    try std.testing.expectEqual(@as(?i64, 31_250), scheduler.last_checkpoint_ms);
    try std.testing.expect(!scheduler.due(61_249));
}

test "checkpoint scheduler rejects zero interval" {
    try std.testing.expectError(error.InvalidInterval, Scheduler.init(0, 0));
}
