//! Opt-in test-build output diagnostics. Logs sizes/timing only, never payloads.
const std = @import("std");
const automation = @import("../platform/runtime_mode.zig").automation;
pub var enabled = false;
extern "c" fn getenv([*:0]const u8) ?[*:0]const u8;
pub fn configure() void {
    if (comptime automation) enabled = getenv("ZEROWORK_OUTPUT_TIMING") != null;
}
pub fn now() i128 {
    return @import("../platform/realtime.zig").monotonicNs();
}
pub fn read(id: usize, started: i128, parsed: i128, bytes: usize, reason: []const u8, retries: u32) void {
    const finished = now();
    std.debug.print("[terminal-output-read] worker={d} at_us={d} bytes={d} reason={s} retries={d} read_us={d} feed_us={d}\n", .{ id, @divTrunc(started, 1000), bytes, reason, retries, @divTrunc(parsed - started, 1000), @divTrunc(finished - parsed, 1000) });
}
pub fn wait(fd: i32, started: i128, requested_ms: u32, events: usize) void {
    std.debug.print("[terminal-output-wait] fd={d} at_us={d} requested_ms={d} wait_us={d} events={d}\n", .{ fd, @divTrunc(started, 1000), requested_ms, @divTrunc(now() - started, 1000), events });
}
