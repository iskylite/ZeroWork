const std = @import("std");
/// Maintenance retry state, independent of redraw and GPU frame admission.
/// A permanently pending fence must not wake the idle app every five ms.
pub const MaintenanceRetry = struct {
    deadline_ns: u64 = 0,
    stage: u2 = 0,
    stopped: bool = false,
    pub fn pending(self: *MaintenanceRetry, now_ns: u64) void {
        const ms = [_]u64{ 5, 50, 500 };
        self.deadline_ns = now_ns +| ms[self.stage] * std.time.ns_per_ms;
        self.stage = @min(self.stage + 1, 2);
    }
    pub fn reset(self: *MaintenanceRetry) void {
        self.* = .{};
    }
    pub fn delay(self: *const MaintenanceRetry, now_ns: u64) ?u64 {
        return if (self.stopped) null else self.deadline_ns -| now_ns;
    }
};

test "maintenance retries back off saturate reset and stop on device loss" {
    var retry: MaintenanceRetry = .{};
    var now: u64 = 0;
    for ([_]u64{ 5, 50, 500, 500 }) |ms| {
        retry.pending(now);
        try std.testing.expectEqual(ms * std.time.ns_per_ms, retry.delay(now).?);
        now = retry.deadline_ns;
    }
    retry.reset();
    try std.testing.expectEqual(@as(u64, 0), retry.delay(now).?);
    retry.stopped = true;
    try std.testing.expect(retry.delay(now) == null);
    // Successful submission replaces the lost fence and restarts maintenance.
    retry.reset();
    try std.testing.expectEqual(@as(u64, 0), retry.delay(now).?);
}
