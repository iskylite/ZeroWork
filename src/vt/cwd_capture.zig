//! Bounded, one-shot capture of the interactive shell's directory report.
//! Keeps the application's query echo out of the terminal document.
const std = @import("std");
pub const Capture = struct {
    requested: std.atomic.Value(bool) = .init(false),
    active: bool = false,
    bytes: [16 * 1024]u8 = undefined,
    len: usize = 0,
    started: i128 = 0,
    pub fn arm(self: *Capture) void {
        self.requested.store(true, .release);
    }
    pub fn finish(self: *Capture, sink: anytype) !void {
        self.requested.store(false, .release);
        if (self.active and self.len > 0) try sink.feedOutput(self.bytes[0..self.len]);
        self.active = false;
        self.len = 0;
    }
    pub fn feed(self: *Capture, sink: anytype, data: []const u8, now: i128) !void {
        if (self.requested.swap(false, .acq_rel)) {
            if (self.active and self.len > 0) try sink.feedOutput(self.bytes[0..self.len]);
            self.active = true;
            self.len = 0;
            self.started = now;
        }
        if (!self.active) return sink.feedOutput(data);
        if (now - self.started > 5 * std.time.ns_per_s or data.len > self.bytes.len - self.len) {
            self.active = false;
            try sink.feedOutput(self.bytes[0..self.len]);
            self.len = 0;
            return sink.feedOutput(data);
        }
        @memcpy(self.bytes[self.len..][0..data.len], data);
        self.len += data.len;
        const bytes = self.bytes[0..self.len];
        const start = std.mem.indexOf(u8, bytes, "\x1b]7;file://localhost") orelse return;
        _ = std.mem.indexOfScalarPos(u8, bytes, start, 7) orelse return;
        self.active = false;
        // The shell redraws its prompt after the report. Replace its previous
        // prompt, rather than appending a duplicate or retaining query wraps.
        try sink.feedOutput("\r\x1b[K");
        try sink.feedOutput(bytes[start..]);
        self.len = 0;
    }
};
test "directory capture handles split report and retains all output on timeout" {
    const Sink = struct {
        data: std.ArrayList(u8) = .empty,
        pub fn feedOutput(self: *@This(), bytes: []const u8) !void {
            try self.data.appendSlice(std.testing.allocator, bytes);
        }
    };
    var sink: Sink = .{};
    defer sink.data.deinit(std.testing.allocator);
    var capture: Capture = .{};
    capture.arm();
    try capture.feed(&sink, "query echo\r\n\x1b]7;file://local", 0);
    try std.testing.expectEqual(@as(usize, 0), sink.data.items.len);
    try capture.feed(&sink, "host/tmp\x07prompt", 1);
    try std.testing.expectEqualStrings("\r\x1b[K\x1b]7;file://localhost/tmp\x07prompt", sink.data.items);
    sink.data.clearRetainingCapacity();
    capture.arm();
    try capture.feed(&sink, "ordinary output", 2);
    try capture.feed(&sink, "still here", 6 * std.time.ns_per_s);
    try std.testing.expectEqualStrings("ordinary outputstill here", sink.data.items);
    sink.data.clearRetainingCapacity();
    capture.arm();
    try capture.feed(&sink, "before EOF", 7 * std.time.ns_per_s);
    try capture.finish(&sink);
    try std.testing.expectEqualStrings("before EOF", sink.data.items);
    sink.data.clearRetainingCapacity();
    capture.arm();
    try capture.feed(&sink, "prefix", 0);
    const huge: [16 * 1024 + 1]u8 = @splat('x');
    try capture.feed(&sink, &huge, 1);
    try std.testing.expectEqual(@as(usize, 6 + huge.len), sink.data.items.len);
    try std.testing.expectEqualSlices(u8, &huge, sink.data.items[6..]);
}
