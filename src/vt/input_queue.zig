const std = @import("std");

/// Fixed-capacity single-producer/single-consumer byte queue for UI-to-worker input.
pub const InputQueue = struct {
    buffer: []u8,
    wakeup: ?*const @import("../platform/wakeup.zig").Wakeup = null,
    write_index: std.atomic.Value(usize) = .init(0),
    read_index: std.atomic.Value(usize) = .init(0),

    pub fn init(allocator: std.mem.Allocator, requested_capacity: usize) !InputQueue {
        if (requested_capacity < 2) return error.InvalidCapacity;
        return .{ .buffer = try allocator.alloc(u8, requested_capacity) };
    }

    pub fn deinit(self: *InputQueue, allocator: std.mem.Allocator) void {
        allocator.free(self.buffer);
        self.* = undefined;
    }

    pub fn push(self: *InputQueue, bytes: []const u8) !void {
        const write = self.write_index.load(.monotonic);
        const read = self.read_index.load(.acquire);
        const used = write -% read;
        if (bytes.len > self.buffer.len - used) return error.Full;
        for (bytes, 0..) |byte, offset| self.buffer[(write +% offset) % self.buffer.len] = byte;
        self.write_index.store(write +% bytes.len, .release);
        if (bytes.len > 0) if (self.wakeup) |wake| wake.notify();
    }

    pub fn peek(self: *const InputQueue, destination: []u8) []u8 {
        const read = self.read_index.load(.monotonic);
        const write = self.write_index.load(.acquire);
        const count = @min(destination.len, write -% read);
        for (destination[0..count], 0..) |*byte, offset| byte.* = self.buffer[(read +% offset) % self.buffer.len];
        return destination[0..count];
    }

    pub fn consume(self: *InputQueue, count: usize) !void {
        const read = self.read_index.load(.monotonic);
        const write = self.write_index.load(.acquire);
        if (count > write -% read) return error.ConsumeBeyondAvailable;
        self.read_index.store(read +% count, .release);
    }

    pub fn drain(self: *InputQueue, destination: []u8) []u8 {
        const bytes = self.peek(destination);
        self.consume(bytes.len) catch unreachable;
        return bytes;
    }

    pub fn pending(self: *const InputQueue) usize {
        const write = self.write_index.load(.acquire);
        const read = self.read_index.load(.monotonic);
        return write -% read;
    }

    pub fn capacity(self: *const InputQueue) usize {
        return self.buffer.len;
    }

    pub fn freeCapacity(self: *const InputQueue) usize {
        return self.capacity() - self.pending();
    }
};

test "input queue preserves bytes across ring wrap" {
    var queue = try InputQueue.init(std.testing.allocator, 5);
    defer queue.deinit(std.testing.allocator);
    try queue.push("abc");
    var first: [2]u8 = undefined;
    try std.testing.expectEqualStrings("ab", queue.drain(&first));
    try queue.push("de");
    var rest: [3]u8 = undefined;
    try std.testing.expectEqualStrings("cde", queue.drain(&rest));
}

test "input queue retains unconsumed bytes after partial worker write" {
    var queue = try InputQueue.init(std.testing.allocator, 6);
    defer queue.deinit(std.testing.allocator);
    try queue.push("hello");
    var output: [5]u8 = undefined;
    try std.testing.expectEqualStrings("hello", queue.peek(&output));
    try queue.consume(2);
    try std.testing.expectEqualStrings("llo", queue.peek(&output));
    try std.testing.expectError(error.ConsumeBeyondAvailable, queue.consume(4));
}

test "input queue reports backpressure and preserves queued data" {
    var queue = try InputQueue.init(std.testing.allocator, 3);
    defer queue.deinit(std.testing.allocator);
    try queue.push("abc");
    try std.testing.expectError(error.Full, queue.push("d"));
    var output: [3]u8 = undefined;
    try std.testing.expectEqualStrings("abc", queue.drain(&output));
}
