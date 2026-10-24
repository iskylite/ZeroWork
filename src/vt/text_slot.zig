const std = @import("std");

/// SPSC text handoff: the worker publishes an owned UTF-8 terminal frame and
/// the UI consumes it without touching the worker-owned VT engine.
///
/// Buffer depth is 3 (triple buffering). Depth 2 left exactly one frame of
/// slack: whenever the UI missed a single vsync (window drag, heavy frame),
/// the worker's next publish hit ConsumerBehind and the frame waited a full
/// worker poll (~50ms) for retry — perceived as periodic micro-stutter during
/// continuous output like `dmesg -T`. Depth 3 absorbs a missed UI tick: the
/// worker keeps publishing while the UI catches up on the next frame.
pub const TextSlot = struct {
    /// Slot capacity shared by the producer buffers and the UI-side scratch
    /// destination. Keeping them equal guarantees take() never fails with
    /// DestinationTooSmall for a frame the slot accepted.
    pub const default_capacity: usize = 1024 * 1024;

    /// Producer-side ring depth. Generation N lands in buffer N % depth.
    const depth: usize = 3;

    buffers: [depth][]u8,
    lengths: [depth]usize = @splat(0),
    generation: std.atomic.Value(u64) = .init(0),
    consumed: std.atomic.Value(u64) = .init(0),

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !TextSlot {
        if (capacity == 0) return error.InvalidCapacity;
        var buffers: [depth][]u8 = undefined;
        var allocated: usize = 0;
        errdefer for (buffers[0..allocated]) |buf| allocator.free(buf);
        for (&buffers) |*buf| {
            buf.* = try allocator.alloc(u8, capacity);
            allocated += 1;
        }
        return .{ .buffers = buffers };
    }
    pub fn deinit(self: *TextSlot, allocator: std.mem.Allocator) void {
        for (self.buffers) |buf| allocator.free(buf);
        self.* = undefined;
    }
    pub fn publish(self: *TextSlot, bytes: []const u8) !u64 {
        return self.publishParts(&.{bytes});
    }

    /// Producer-side capacity probe: true when a publish would fit right now.
    /// Lets the worker skip the expensive full-viewport projection when the
    /// UI is already a full ring behind (projection-then-fail wasted the CPU
    /// that drove the periodic stutter under continuous output).
    pub fn canPublish(self: *TextSlot) bool {
        const current = self.generation.load(.monotonic);
        return current -% self.consumed.load(.acquire) < depth;
    }

    /// Publishes several slices as one contiguous generation. Lets the worker
    /// prepend a fixed metadata header without building an intermediate
    /// concatenation buffer (the slot buffer is the single copy target).
    pub fn publishParts(self: *TextSlot, parts: []const []const u8) !u64 {
        var total: usize = 0;
        for (parts) |part| total += part.len;
        if (total > self.buffers[0].len) return error.TooLarge;
        const current = self.generation.load(.monotonic);
        if (current -% self.consumed.load(.acquire) >= depth) return error.ConsumerBehind;
        const next = current +% 1;
        const index: usize = @intCast(next % depth);
        var offset: usize = 0;
        for (parts) |part| {
            @memcpy(self.buffers[index][offset .. offset + part.len], part);
            offset += part.len;
        }
        self.lengths[index] = total;
        self.generation.store(next, .release);
        @import("../platform/presentation_wakeup.zig").notify();
        return next;
    }

    /// Structured snapshot consumers need only the version; acknowledge without
    /// copying the legacy text payload. Single-consumer ownership is unchanged.
    pub fn acknowledge(self: *TextSlot, seen: u64) ?u64 {
        const current = self.generation.load(.acquire);
        if (current == seen) return null;
        self.consumed.store(current, .release);
        return current;
    }

    pub fn take(self: *TextSlot, seen_generation: u64, destination: []u8) !?Snapshot {
        const current = self.generation.load(.acquire);
        if (current == seen_generation) return null;
        const index: usize = @intCast(current % depth);
        const length = self.lengths[index];
        if (length > destination.len) return error.DestinationTooSmall;
        @memcpy(destination[0..length], self.buffers[index][0..length]);
        self.consumed.store(current, .release);
        return .{ .generation = current, .text = destination[0..length] };
    }
};

pub const Snapshot = struct { generation: u64, text: []const u8 };

test "text slot hands off frames without exposing worker storage" {
    var slot = try TextSlot.init(std.testing.allocator, 32);
    defer slot.deinit(std.testing.allocator);
    _ = try slot.publish("first");
    var destination: [32]u8 = undefined;
    const frame = (try slot.take(0, &destination)).?;
    try std.testing.expectEqualStrings("first", frame.text);
    try std.testing.expect(try slot.take(frame.generation, &destination) == null);
}

test "text slot applies backpressure and size limits" {
    var slot = try TextSlot.init(std.testing.allocator, 4);
    defer slot.deinit(std.testing.allocator);
    try std.testing.expectError(error.TooLarge, slot.publish("large"));
    _ = try slot.publish("one");
    _ = try slot.publish("two");
    // Triple depth: a third unconsumed publish fits; the fourth fails.
    _ = try slot.publish("tri");
    try std.testing.expectError(error.ConsumerBehind, slot.publish("fou"));
    var destination: [4]u8 = undefined;
    const frame = (try slot.take(0, &destination)).?;
    try std.testing.expectEqualStrings("tri", frame.text);
}

test "text slot publishes parts as one contiguous generation" {
    var slot = try TextSlot.init(std.testing.allocator, 16);
    defer slot.deinit(std.testing.allocator);
    const header = "\x00\x03\x07\x00\x00\x00";
    _ = try slot.publishParts(&.{ header, "world" });
    var destination: [16]u8 = undefined;
    const frame = (try slot.take(0, &destination)).?;
    try std.testing.expectEqualStrings("\x00\x03\x07\x00\x00\x00world", frame.text);
    // Same generation, so a second take reports nothing new.
    try std.testing.expect(try slot.take(frame.generation, &destination) == null);
}

test "text slot deep frames keep wrapping across the ring" {
    var slot = try TextSlot.init(std.testing.allocator, 8);
    defer slot.deinit(std.testing.allocator);
    var destination: [8]u8 = undefined;
    // Fill the ring and drain repeatedly; index math must wrap cleanly.
    var round: u64 = 0;
    while (round < 4) : (round += 1) {
        _ = try slot.publish("AAAAAAAA");
        _ = try slot.publish("BBBBBBBB");
        _ = try slot.publish("CCCCCCCC");
        const latest = (try slot.take(0, &destination)).?;
        try std.testing.expectEqualStrings("CCCCCCCC", latest.text);
    }
}

test "structured consumer acknowledges latest generation without copying and releases backpressure" {
    var slot = try TextSlot.init(std.testing.allocator, 8);
    defer slot.deinit(std.testing.allocator);
    _ = try slot.publish("a");
    _ = try slot.publish("b");
    const latest = try slot.publish("c");
    try std.testing.expect(!slot.canPublish());
    try std.testing.expectEqual(latest, slot.acknowledge(0).?);
    try std.testing.expect(slot.canPublish());
    try std.testing.expect(slot.acknowledge(latest) == null);
    _ = try slot.publish("next");
    var bytes: [8]u8 = undefined;
    try std.testing.expectEqualStrings("next", (try slot.take(latest, &bytes)).?.text);
}
