//! A native window supports one chooser; each accepted command remains its own
//! owner-bound request. No file IO, terminal probing or native UI in admission.
const std = @import("std");

pub fn Queue(comptime Intent: type) type {
    return struct {
        const Self = @This();
        pending: std.ArrayList(Intent) = .empty,
        pub fn push(self: *Self, a: std.mem.Allocator, intent: Intent) !void {
            if (self.pending.items.len >= 32) return error.FileSelectionQueueFull;
            try self.pending.append(a, intent);
        }
        pub fn take(self: *Self, native_busy: bool) ?Intent {
            if (native_busy or self.pending.items.len == 0) return null;
            return self.pending.orderedRemove(0);
        }
        pub fn deinit(self: *Self, a: std.mem.Allocator) void {
            self.pending.deinit(a);
        }
    };
}

pub fn retryDirectory(err: anyerror, elapsed_ms: u64) bool {
    return (err == error.WorkerBusy or err == error.Full) and elapsed_ms < 5000;
}

test "back to back upload chooser keeps each original receipt and owner; cancellation does not consume the next request" {
    const Request = struct { owner: u64, receipt: u64, source: []const u8 };
    var q: Queue(Request) = .{};
    defer q.deinit(std.testing.allocator);
    try q.push(std.testing.allocator, .{ .owner = 7, .receipt = 3, .source = "first" });
    const first = q.take(false).?;
    try q.push(std.testing.allocator, .{ .owner = 7, .receipt = 4, .source = "second" });
    try q.push(std.testing.allocator, .{ .owner = 9, .receipt = 1, .source = "third" });
    try std.testing.expect(q.take(true) == null);
    try std.testing.expectEqual(@as(u64, 3), first.receipt);
    try std.testing.expectEqualDeep(Request{ .owner = 7, .receipt = 4, .source = "second" }, q.take(false).?);
    try std.testing.expectEqualDeep(Request{ .owner = 9, .receipt = 1, .source = "third" }, q.take(false).?);
    try std.testing.expect(q.take(false) == null);
    for (0..32) |_| try q.push(std.testing.allocator, first);
    try std.testing.expectError(error.FileSelectionQueueFull, q.push(std.testing.allocator, first));
}

test "directory probe retries only an unaccepted transient request and never waits unbounded" {
    try std.testing.expect(retryDirectory(error.WorkerBusy, 0));
    try std.testing.expect(retryDirectory(error.Full, 4999));
    try std.testing.expect(!retryDirectory(error.WorkerBusy, 5000));
    try std.testing.expect(!retryDirectory(error.TerminalControlled, 10));
}
