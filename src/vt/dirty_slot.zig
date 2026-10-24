const std = @import("std");

/// Single-writer/single-reader generation slot for VT dirty-page publication.
/// The producer writes the inactive buffer, then release-publishes its generation.
pub const DirtySlot = struct {
    buffers: [2][]u32,
    lengths: [2]usize = .{ 0, 0 },
    generation: std.atomic.Value(u64) = .init(0),
    consumed: std.atomic.Value(u64) = .init(0),

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !DirtySlot {
        if (capacity == 0) return error.InvalidCapacity;
        const a = try allocator.alloc(u32, capacity);
        errdefer allocator.free(a);
        const b = try allocator.alloc(u32, capacity);
        return .{ .buffers = .{ a, b } };
    }

    pub fn deinit(self: *DirtySlot, allocator: std.mem.Allocator) void {
        allocator.free(self.buffers[0]);
        allocator.free(self.buffers[1]);
        self.* = undefined;
    }

    pub fn publish(self: *DirtySlot, pages: []const u32) !u64 {
        if (pages.len > self.buffers[0].len) return error.TooManyDirtyPages;
        const current = self.generation.load(.monotonic);
        if (current -% self.consumed.load(.acquire) >= 2) return error.ConsumerBehind;
        const next = current +% 1;
        const index: usize = @intCast(next & 1);
        @memcpy(self.buffers[index][0..pages.len], pages);
        self.lengths[index] = pages.len;
        self.generation.store(next, .release);
        return next;
    }

    pub fn take(self: *DirtySlot, seen_generation: u64, destination: []u32) !?Snapshot {
        const current = self.generation.load(.acquire);
        if (current == seen_generation) return null;
        const index: usize = @intCast(current & 1);
        const length = self.lengths[index];
        if (length > destination.len) return error.DestinationTooSmall;
        @memcpy(destination[0..length], self.buffers[index][0..length]);
        self.consumed.store(current, .release);
        return .{ .generation = current, .pages = destination[0..length] };
    }
};

pub const Snapshot = struct { generation: u64, pages: []const u32 };

test "dirty slot publishes generations without allocation" {
    var slot = try DirtySlot.init(std.testing.allocator, 4);
    defer slot.deinit(std.testing.allocator);
    var destination: [4]u32 = undefined;
    try std.testing.expect(try slot.take(0, &destination) == null);
    const generation = try slot.publish(&.{ 2, 7 });
    const snapshot = (try slot.take(0, &destination)).?;
    try std.testing.expectEqual(generation, snapshot.generation);
    try std.testing.expectEqualSlices(u32, &.{ 2, 7 }, snapshot.pages);
    try std.testing.expect(try slot.take(generation, &destination) == null);
}

test "dirty slot applies backpressure before overwriting unread buffers" {
    var slot = try DirtySlot.init(std.testing.allocator, 1);
    defer slot.deinit(std.testing.allocator);
    _ = try slot.publish(&.{1});
    _ = try slot.publish(&.{2});
    try std.testing.expectError(error.ConsumerBehind, slot.publish(&.{3}));
    var destination: [1]u32 = undefined;
    const snapshot = (try slot.take(0, &destination)).?;
    try std.testing.expectEqual(@as(u32, 2), snapshot.pages[0]);
    _ = try slot.publish(&.{3});
}

test "dirty slot rejects oversized publication" {
    var slot = try DirtySlot.init(std.testing.allocator, 1);
    defer slot.deinit(std.testing.allocator);
    try std.testing.expectError(error.TooManyDirtyPages, slot.publish(&.{ 1, 2 }));
}
