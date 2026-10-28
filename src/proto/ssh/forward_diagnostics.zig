//! Bounded value-only diagnostics; copied across the native owner/UI boundary.
const std = @import("std");
const clock = @import("../../platform/realtime.zig");
pub const Record = struct {
    timestamp_ms: i64 = 0,
    step: []const u8 = "",
    elapsed_us: ?u64 = null,
    failure: ?anyerror = null,
};
pub const Journal = struct {
    records: [24]Record = @splat(.{}),
    count: usize = 0,
    dropped: usize = 0,
    pub fn add(self: *Journal, step: []const u8, started: ?i128, failure: ?anyerror) void {
        if (self.count == self.records.len) {
            std.mem.copyForwards(Record, self.records[0 .. self.records.len - 1], self.records[1..]);
            self.count -= 1;
            self.dropped += 1;
        }
        self.records[self.count] = .{ .timestamp_ms = clock.milliseconds(undefined), .step = step, .elapsed_us = if (started) |ns| @intCast(@max(0, clock.monotonicNs() - ns) / std.time.ns_per_us) else null, .failure = failure };
        self.count += 1;
    }
    pub fn format(self: *const Journal, buffer: []u8) []const u8 {
        var used: usize = 0;
        for (self.records[0..self.count]) |record| {
            var timestamp_buffer: [32]u8 = undefined;
            const timestamp = formatTimestamp(&timestamp_buffer, record.timestamp_ms);
            const line = if (record.elapsed_us) |us|
                std.fmt.bufPrint(buffer[used..], "{s} - {s}{s}{s} - {d}.{d:0>3} ms\n", .{ timestamp, record.step, if (record.failure != null) ": " else "", if (record.failure) |err| @errorName(err) else "", us / 1000, us % 1000 }) catch break
            else
                std.fmt.bufPrint(buffer[used..], "{s} - {s}{s}{s}\n", .{ timestamp, record.step, if (record.failure != null) ": " else "", if (record.failure) |err| @errorName(err) else "" }) catch break;
            used += line.len;
        }
        if (self.dropped > 0) {
            const line = std.fmt.bufPrint(buffer[used..], "仅保留最近 24 条，已省略 {d} 条\n", .{self.dropped}) catch return buffer[0..used];
            used += line.len;
        }
        return buffer[0..used];
    }
};

const Time = extern struct { sec: c_int, min: c_int, hour: c_int, day: c_int, month: c_int, year: c_int, week_day: c_int, year_day: c_int, daylight: c_int, offset: c_long, zone: ?[*:0]const u8 };
extern "c" fn localtime_r(*const c_long, *Time) ?*Time;
pub fn formatTimestamp(buffer: []u8, wall_ms: i64) []const u8 {
    const seconds: c_long = @intCast(@divFloor(wall_ms, 1000));
    var value: Time = undefined;
    if (localtime_r(&seconds, &value) == null) return "时间未知";
    return std.fmt.bufPrint(buffer, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{ value.hour, value.min, value.sec, @mod(wall_ms, 1000) }) catch "时间未知";
}
