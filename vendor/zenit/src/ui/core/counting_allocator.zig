//! Opt-in requested-byte ownership ledger. This wrapper does not change the
//! parent allocator or equate requested bytes with resident/physical bytes.
//! Owner and allocations live on the UI thread; keep this object at a stable address.
const std = @import("std");
pub const CountingAllocator = struct {
    parent: std.mem.Allocator,
    live_bytes: usize = 0,
    peak_bytes: usize = 0,
    allocated_bytes: usize = 0,
    allocations: usize = 0,
    failures: usize = 0,
    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn change(self: *CountingAllocator, old: usize, new: usize) void {
        self.live_bytes = self.live_bytes - old + new;
        self.peak_bytes = @max(self.peak_bytes, self.live_bytes);
        self.allocated_bytes += new -| old;
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.parent.rawAlloc(len, alignment, ra) orelse {
            self.failures += 1;
            return null;
        };
        self.allocations += 1;
        self.change(0, len);
        return p;
    }
    fn resize(ctx: *anyopaque, old: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.parent.rawResize(old, alignment, len, ra)) return false;
        self.change(old.len, len);
        return true;
    }
    fn remap(ctx: *anyopaque, old: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.parent.rawRemap(old, alignment, len, ra) orelse return null;
        self.change(old.len, len);
        return p;
    }
    fn free(ctx: *anyopaque, old: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(old, alignment, ra);
        self.change(old.len, 0);
    }
};
test "CountingAllocator forwards reallocation free and OOM without false live bytes" {
    var counter = CountingAllocator{ .parent = std.testing.allocator };
    const a = counter.allocator();
    var bytes = try a.alloc(u8, 100);
    bytes = try a.realloc(bytes, 10000);
    try std.testing.expectEqual(@as(usize, 10000), counter.live_bytes);
    bytes = try a.realloc(bytes, 20);
    try std.testing.expectEqual(@as(usize, 20), counter.live_bytes);
    a.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), counter.live_bytes);
    var fail = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var failed = CountingAllocator{ .parent = fail.allocator() };
    try std.testing.expectError(error.OutOfMemory, failed.allocator().alloc(u8, 123));
    try std.testing.expectEqual(@as(usize, 0), failed.live_bytes);
    try std.testing.expectEqual(@as(usize, 1), failed.failures);
}
