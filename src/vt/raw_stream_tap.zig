const std = @import("std");

pub const Checkpoint = struct { sequence: u64, timestamp_ms: i64, stream_offset: u64 };

pub const Tap = struct {
    allocator: std.mem.Allocator,
    buffer: []u8,
    disk_capacity: usize = 0,
    write_index: usize = 0,
    len: usize = 0,
    sequence: u64 = 0,
    checkpoint: ?Checkpoint = null,

    pub fn init(allocator: std.mem.Allocator, requested_capacity: usize) !Tap {
        if (requested_capacity == 0) return error.InvalidCapacity;
        return .{ .allocator = allocator, .buffer = try allocator.alloc(u8, requested_capacity) };
    }
    pub fn deinit(self: *Tap) void {
        @memset(self.buffer, 0);
        self.allocator.free(self.buffer);
        self.* = undefined;
    }
    pub fn capacity(self: *const Tap) usize {
        return if (self.disk_capacity != 0) self.disk_capacity else self.buffer.len;
    }
    /// Only after the caller has successfully persisted the existing payload.
    pub fn useDiskStorage(self: *Tap) void {
        self.disk_capacity = self.capacity();
        self.allocator.free(self.buffer);
        self.buffer = &.{};
    }
    pub fn append(self: *Tap, bytes: []const u8) void {
        self.sequence += bytes.len;
        const cap = self.capacity();
        if (self.disk_capacity != 0) {
            self.write_index = @intCast(self.sequence % cap);
            self.len = @intCast(@min(self.sequence, cap));
            return;
        }
        const skipped = bytes.len - @min(bytes.len, cap);
        const retained = bytes[skipped..];
        const position = (self.write_index + skipped) % cap;
        const first = @min(cap - position, retained.len);
        @memcpy(self.buffer[position..][0..first], retained[0..first]);
        @memcpy(self.buffer[0 .. retained.len - first], retained[first..]);
        self.write_index = (position + retained.len) % cap;
        self.len = @min(self.len + bytes.len, cap);
    }
    pub fn markCheckpoint(self: *Tap, timestamp_ms: i64) void {
        self.checkpoint = .{ .sequence = self.sequence, .timestamp_ms = timestamp_ms, .stream_offset = self.sequence };
    }

    pub fn encodeCheckpoint(self: Tap, out: []u8) ![]u8 {
        const cp = self.checkpoint orelse return error.NoCheckpoint;
        if (out.len < 24) return error.BufferTooSmall;
        std.mem.writeInt(u64, out[0..8], cp.sequence, .little);
        std.mem.writeInt(i64, out[8..16], cp.timestamp_ms, .little);
        std.mem.writeInt(u64, out[16..24], cp.stream_offset, .little);
        return out[0..24];
    }

    pub fn decodeCheckpoint(bytes: []const u8) !Checkpoint {
        if (bytes.len < 24) return error.TruncatedCheckpoint;
        return .{ .sequence = std.mem.readInt(u64, bytes[0..8], .little), .timestamp_ms = std.mem.readInt(i64, bytes[8..16], .little), .stream_offset = std.mem.readInt(u64, bytes[16..24], .little) };
    }

    /// Atomically persists the latest checkpoint as a portable 24-byte record.
    pub fn saveCheckpoint(self: *const Tap, io: std.Io, dir: std.Io.Dir, sub_path: []const u8) !void {
        var bytes: [24]u8 = undefined;
        _ = try self.encodeCheckpoint(&bytes);
        var atomic_buffer: [256]u8 = undefined;
        var atomic = try dir.createFileAtomic(io, sub_path, .{
            .permissions = @as(std.Io.File.Permissions, @fromBackingInt(@intCast(0o600))),
            .make_path = true,
            .replace = true,
        });
        defer atomic.deinit(io);
        var writer = atomic.file.writer(io, &atomic_buffer);
        try writer.interface.writeAll(&bytes);
        try writer.interface.flush();
        try atomic.replace(io);
    }

    /// Loads one checkpoint record without changing the in-memory tap.
    pub fn loadCheckpoint(io: std.Io, dir: std.Io.Dir, allocator: std.mem.Allocator, sub_path: []const u8) !Checkpoint {
        const bytes = try dir.readFileAlloc(io, sub_path, allocator, std.Io.Limit.limited(25));
        defer allocator.free(bytes);
        if (bytes.len != 24) return error.InvalidCheckpointSize;
        return decodeCheckpoint(bytes);
    }

    pub fn snapshot(self: *const Tap, out: []u8) ![]u8 {
        if (self.disk_capacity != 0) return error.DiskBackedTap;
        if (out.len < self.len) return error.BufferTooSmall;
        const start = (self.write_index + self.buffer.len - self.len) % self.buffer.len;
        for (out[0..self.len], 0..) |*dest, i| dest.* = self.buffer[(start + i) % self.buffer.len];
        return out[0..self.len];
    }
};

test "checkpoint encodes and decodes portable metadata" {
    var tap = try Tap.init(std.testing.allocator, 8);
    defer tap.deinit();
    tap.append("abc");
    tap.markCheckpoint(-42);
    var bytes: [24]u8 = undefined;
    const decoded = try Tap.decodeCheckpoint(try tap.encodeCheckpoint(&bytes));
    try std.testing.expectEqual(@as(u64, 3), decoded.sequence);
    try std.testing.expectEqual(@as(i64, -42), decoded.timestamp_ms);
}

test "raw tap records stream checkpoint metadata" {
    var tap = try Tap.init(std.testing.allocator, 8);
    defer tap.deinit();
    tap.append("hello");
    tap.markCheckpoint(1234);
    try std.testing.expectEqual(@as(u64, 5), tap.checkpoint.?.sequence);
    try std.testing.expectEqual(@as(i64, 1234), tap.checkpoint.?.timestamp_ms);
}

test "raw tap checkpoint persists privately and round trips" {
    var tap = try Tap.init(std.testing.allocator, 8);
    defer tap.deinit();
    tap.append("abc");
    tap.markCheckpoint(77);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tap.saveCheckpoint(std.testing.io, tmp.dir, "nested/checkpoint.bin");
    const decoded = try Tap.loadCheckpoint(std.testing.io, tmp.dir, std.testing.allocator, "nested/checkpoint.bin");
    try std.testing.expectEqual(@as(u64, 3), decoded.sequence);
    try std.testing.expectEqual(@as(i64, 77), decoded.timestamp_ms);
    var file = try tmp.dir.openFile(std.testing.io, "nested/checkpoint.bin", .{});
    defer file.close(std.testing.io);
    const stat = try file.stat(std.testing.io);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
}

test "raw tap retains latest bytes in ring order" {
    var tap = try Tap.init(std.testing.allocator, 4);
    defer tap.deinit();
    tap.append("abcdef");
    var out: [4]u8 = undefined;
    try std.testing.expectEqualStrings("cdef", try tap.snapshot(&out));
}

test "disk storage drops the payload allocation and ignores later appends" {
    var tap = try Tap.init(std.testing.allocator, 8);
    defer tap.deinit();
    tap.append("abcdef");
    tap.useDiskStorage();
    try std.testing.expectEqual(@as(usize, 0), tap.buffer.len);
    try std.testing.expectEqual(@as(usize, 8), tap.capacity());
    tap.append("ghij");
    try std.testing.expectEqual(@as(usize, 0), tap.buffer.len);
    try std.testing.expectEqual(@as(usize, 8), tap.capacity());
    try std.testing.expectEqual(@as(u64, 10), tap.sequence);
    try std.testing.expectEqual(@as(usize, 8), tap.len);
    var out: [8]u8 = undefined;
    try std.testing.expectError(error.DiskBackedTap, tap.snapshot(&out));
}
