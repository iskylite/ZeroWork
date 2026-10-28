//! Immutable latest viewport. The lock protects only a pointer/refcount handoff;
//! allocation, projection, cloning and destruction never hold the handoff lock.
const std = @import("std");
const Projection = @import("snapshot.zig").Projection;
const allocator = std.heap.page_allocator;
pub const Frame = struct {
    projection: Projection,
    geometry_revision: u64 = 1,
    references: std.atomic.Value(usize) = .init(1),
    pub fn release(self: *Frame) void {
        if (self.references.fetchSub(1, .acq_rel) == 1) {
            self.projection.deinit(allocator);
            allocator.destroy(self);
        }
    }
};
pub const Slot = struct {
    mutex: std.atomic.Mutex = .unlocked,
    current: ?*Frame = null,
    version: std.atomic.Value(u64) = .init(0),
    pub fn deinit(self: *Slot) void {
        if (self.current) |frame| frame.release();
        self.current = null;
    }
    /// Takes ownership only on success. A busy UI handoff defers publication;
    /// it never blocks the transport or prevents VT bytes from being parsed.
    pub fn publish(self: *Slot, projection: Projection, geometry_revision: u64) !void {
        const next = try allocator.create(Frame);
        errdefer allocator.destroy(next);
        next.* = .{ .projection = projection, .geometry_revision = geometry_revision };
        if (!self.mutex.tryLock()) return error.ConsumerBehind;
        const previous = self.current;
        self.current = next;
        self.version.store(projection.version, .release);
        self.mutex.unlock();
        if (previous) |old| old.release();
    }
    pub fn acquire(self: *Slot) !*Frame {
        if (!self.mutex.tryLock()) return error.WorkerBusy;
        defer self.mutex.unlock();
        const frame = self.current orelse return error.WorkerBusy;
        _ = frame.references.fetchAdd(1, .monotonic);
        return frame;
    }
};

test "projection handoff keeps a retained frame alive across replacement" {
    var vt = try @import("ghostty_adapter.zig").Adapter.init(allocator, 2, 20);
    defer vt.destroy();
    var slot: Slot = .{};
    defer slot.deinit();
    _ = try vt.feed("old");
    try slot.publish(try vt.copyProjection(allocator), 1);
    const old = try slot.acquire();
    defer old.release();
    _ = try vt.feed("new");
    try slot.publish(try vt.copyProjection(allocator), 2);
    const next = try slot.acquire();
    defer next.release();
    try std.testing.expect(old.projection.version < next.projection.version);
    try std.testing.expectEqual(@as(u64, 1), old.geometry_revision);
    try std.testing.expectEqual(@as(u64, 2), next.geometry_revision);
    try std.testing.expect(slot.mutex.tryLock());
    try std.testing.expectError(error.WorkerBusy, slot.acquire());
    slot.mutex.unlock();
}
