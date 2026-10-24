const std = @import("std");

pub const Chunk = struct {
    index: u64,
    offset: u64,
    len: u32,
};

pub const Window = struct {
    total_bytes: u64,
    chunk_bytes: u32,
    capacity: u16,
    next_index: u64 = 0,
    acknowledged: u64 = 0,
    in_flight: u16 = 0,
    ack_mask: u256 = 0,

    pub fn init(total_bytes: u64, chunk_bytes: u32, capacity: u16) !Window {
        if (chunk_bytes == 0 or capacity == 0 or capacity > 255) return error.InvalidWindow;
        return .{ .total_bytes = total_bytes, .chunk_bytes = chunk_bytes, .capacity = capacity };
    }

    pub fn remaining(self: Window) u64 {
        const sent = @min(self.next_index *| self.chunk_bytes, self.total_bytes);
        return self.total_bytes -| sent;
    }

    pub fn next(self: *Window) ?Chunk {
        if (self.in_flight >= self.capacity or self.next_index - self.acknowledged >= self.capacity) return null;
        if (self.next_index >= self.chunkCount()) return null;
        const offset = self.next_index * self.chunk_bytes;
        if (offset >= self.total_bytes) return null;
        const len: u32 = @intCast(@min(@as(u64, self.chunk_bytes), self.total_bytes - offset));
        const chunk = Chunk{ .index = self.next_index, .offset = offset, .len = len };
        self.next_index += 1;
        self.in_flight += 1;
        return chunk;
    }

    pub fn ack(self: *Window, index: u64) !void {
        if (self.in_flight == 0 or index < self.acknowledged or index >= self.next_index) return error.InvalidAck;
        const relative = index - self.acknowledged;
        if (relative >= self.capacity) return error.InvalidAck;
        const bit = @as(u256, 1) << @intCast(relative);
        if (self.ack_mask & bit != 0) return error.DuplicateAck;
        self.ack_mask |= bit;
        self.in_flight -= 1;
        while (self.ack_mask & 1 != 0) {
            self.ack_mask >>= 1;
            self.acknowledged += 1;
        }
    }

    pub fn resumeAt(self: *Window, offset: u64) !void {
        if (offset > self.total_bytes or offset % self.chunk_bytes != 0) return error.InvalidResumeOffset;
        self.next_index = offset / self.chunk_bytes;
        self.acknowledged = self.next_index;
        self.in_flight = 0;
        self.ack_mask = 0;
    }

    pub fn complete(self: Window) bool {
        return self.acknowledged == self.chunkCount() and self.in_flight == 0;
    }

    pub fn chunkCount(self: Window) u64 {
        return self.total_bytes / self.chunk_bytes + @intFromBool(self.total_bytes % self.chunk_bytes != 0);
    }
};

pub fn md5(bytes: []const u8) [16]u8 {
    var hash: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(bytes, &hash, .{});
    return hash;
}

test "window emits bounded chunks and completes on acks" {
    var window = try Window.init(10, 4, 2);
    const a = window.next().?;
    const b = window.next().?;
    try std.testing.expect(window.next() == null);
    try std.testing.expectEqual(@as(u32, 4), a.len);
    try std.testing.expectEqual(@as(u32, 2), (Chunk{ .index = 2, .offset = 8, .len = 2 }).len);
    try window.ack(a.index);
    _ = window.next().?;
    try window.ack(b.index);
    try window.ack(2);
    try std.testing.expect(window.complete());
}

test "window tracks out of order ACKs and rejects duplicates" {
    var window = try Window.init(12, 4, 3);
    const first = window.next().?;
    const second = window.next().?;
    _ = window.next().?;
    try window.ack(second.index);
    try std.testing.expectEqual(@as(u64, 0), window.acknowledged);
    try std.testing.expectError(error.DuplicateAck, window.ack(second.index));
    try window.ack(first.index);
    try std.testing.expectEqual(@as(u64, 2), window.acknowledged);
    try window.ack(2);
    try std.testing.expect(window.complete());
}

test "window resumes only on aligned offsets" {
    var window = try Window.init(100, 16, 4);
    try std.testing.expectError(error.InvalidResumeOffset, window.resumeAt(3));
    try window.resumeAt(32);
    try std.testing.expectEqual(@as(u64, 2), window.next_index);
    try std.testing.expectEqual(@as(u64, 68), window.remaining());
}

test "md5 helper returns stable digest" {
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x5d, 0x41, 0x40, 0x2a, 0xbc, 0x4b, 0x2a, 0x76, 0xb9, 0x71, 0x9d, 0x91, 0x10, 0x17, 0xc5, 0x92 }, &md5("hello"));
}

test "window admits all 255 configured slots and preserves the oldest unacknowledged span" {
    var window = try Window.init(400 * 1024, 1024, 255);
    for (0..255) |index| try std.testing.expectEqual(@as(u64, @intCast(index)), window.next().?.index);
    try std.testing.expect(window.next() == null);
    // Later ACKs cannot let the pending head escape the bounded ACK bitmap.
    var index: u64 = 254;
    while (index > 0) : (index -= 1) try window.ack(index);
    try std.testing.expect(window.next() == null);
    try std.testing.expectError(error.DuplicateAck, window.ack(254));
    try window.ack(0);
    try std.testing.expectEqual(@as(u64, 255), window.acknowledged);
    while (window.next()) |chunk| try window.ack(chunk.index);
    try std.testing.expect(window.complete());
    try std.testing.expectError(error.InvalidWindow, Window.init(1, 1, 256));
}

test "window keeps out of order acknowledgements within its configured span" {
    var window = try Window.init(10, 1, 2);
    _ = window.next().?;
    _ = window.next().?;
    try window.ack(1);
    try std.testing.expect(window.next() == null);
    try window.ack(0);
    try std.testing.expectEqual(@as(u64, 2), window.next().?.index);
}

test "window final logical block does not overflow maximum file length" {
    const size = std.math.maxInt(u64);
    var window = try Window.init(size, 64 * 1024, 16);
    const count = size / (64 * 1024) + 1;
    try std.testing.expectEqual(count, window.chunkCount());
    try window.resumeAt((count - 1) * (64 * 1024));
    const last = window.next().?;
    try std.testing.expectEqual(@as(u32, 64 * 1024 - 1), last.len);
    try std.testing.expectEqual(@as(u64, 0), window.remaining());
    try std.testing.expect(window.next() == null);
    try window.ack(last.index);
    try std.testing.expect(window.complete());
}
