//! Bounded value-only diagnostics; copied across the native owner/UI boundary.
const std = @import("std");
const clock = @import("../../platform/realtime.zig");
pub const Record = struct {
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
        self.records[self.count] = .{ .step = step, .elapsed_us = if (started) |ns| @intCast(@max(0, clock.monotonicNs() - ns) / std.time.ns_per_us) else null, .failure = failure };
        self.count += 1;
    }
    pub fn format(self: *const Journal, buffer: []u8) []const u8 {
        var used: usize = 0;
        for (self.records[0..self.count]) |record| {
            const line = if (record.elapsed_us) |us|
                std.fmt.bufPrint(buffer[used..], "{s} · {d}.{d:0>3} ms{s}{s}\n", .{ record.step, us / 1000, us % 1000, if (record.failure != null) " · " else "", if (record.failure) |err| @errorName(err) else "" }) catch break
            else
                std.fmt.bufPrint(buffer[used..], "{s}{s}{s}\n", .{ record.step, if (record.failure != null) " · " else "", if (record.failure) |err| @errorName(err) else "" }) catch break;
            used += line.len;
        }
        if (self.dropped > 0) {
            const line = std.fmt.bufPrint(buffer[used..], "仅保留最近 24 条，已省略 {d} 条\n", .{self.dropped}) catch return buffer[0..used];
            used += line.len;
        }
        return buffer[0..used];
    }
};
