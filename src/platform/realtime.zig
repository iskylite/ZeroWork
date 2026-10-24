const std = @import("std");

/// Returns POSIX epoch milliseconds using the native macOS realtime clock.
pub fn milliseconds(_: *anyopaque) i64 {
    var ts: std.c.timespec = undefined;
    const rc = std.c.clock_gettime(.REALTIME, &ts);
    if (rc != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

test "realtime clock returns a plausible epoch timestamp" {
    const value = milliseconds(undefined);
    try std.testing.expect(value > 1_500_000_000_000);
}

/// Monotonic nanoseconds for pipeline stage timing (never jumps backwards).
pub fn monotonicNs() i128 {
    var ts: std.c.timespec = undefined;
    const rc = std.c.clock_gettime(.MONOTONIC, &ts);
    if (rc != 0) return 0;
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}
