//! Reuse native snapshot buffers without keeping their pages resident while
//! idle. Only arena bookkeeping pages remain live between captures.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Region = struct { ptr: [*]u8, len: usize, reusable: bool = false };

pub const Scratch = struct {
    arena: ?std.heap.ArenaAllocator = null,
    regions: std.ArrayList(Region) = .empty,

    pub fn begin(self: *Scratch) *std.heap.ArenaAllocator {
        if (self.arena == null) self.arena = .init(.{ .ptr = self, .vtable = &vtable });
        if (builtin.os.tag == .macos) for (self.regions.items) |*region| {
            if (region.reusable) {
                if (!advise(region.*, std.c.MADV.FREE_REUSE)) {
                    _ = self.arena.?.reset(.free_all);
                    break;
                }
                region.reusable = false;
            }
        };
        return &self.arena.?;
    }
    pub fn end(self: *Scratch) void {
        if (builtin.os.tag != .macos) {
            _ = self.arena.?.reset(.free_all);
            return;
        }
        _ = self.arena.?.reset(.{ .retain_with_limit = 128 * 1024 * 1024 });
        for (self.regions.items) |*region| {
            if (!advise(region.*, std.c.MADV.FREE_REUSABLE)) {
                _ = self.arena.?.reset(.free_all);
                break;
            }
            region.reusable = true;
        }
    }
    pub fn deinit(self: *Scratch) void {
        if (self.arena) |arena| arena.deinit();
        self.regions.deinit(std.heap.c_allocator);
    }
    fn advise(region: Region, advice: u32) bool {
        const page = std.heap.pageSize();
        // The arena's linked-list metadata lives at the start of each child
        // block. Never discard that first page, or partial boundary pages.
        const start = std.mem.alignForward(usize, @intFromPtr(region.ptr) + 1, page);
        const finish = std.mem.alignBackward(usize, @intFromPtr(region.ptr) + region.len, page);
        return finish <= start or std.c.madvise(@ptrFromInt(start), finish - start, advice) == 0;
    }
    fn get(raw: *anyopaque) *Scratch {
        return @ptrCast(@alignCast(raw));
    }
    fn index(self: *Scratch, ptr: [*]u8) usize {
        for (self.regions.items, 0..) |region, i| if (region.ptr == ptr) return i;
        unreachable;
    }
    fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self = get(raw);
        const ptr = std.heap.page_allocator.rawAlloc(len, alignment, address) orelse return null;
        self.regions.append(std.heap.c_allocator, .{ .ptr = ptr, .len = len }) catch {
            std.heap.page_allocator.rawFree(ptr[0..len], alignment, address);
            return null;
        };
        return ptr;
    }
    fn resize(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, address: usize) bool {
        if (!std.heap.page_allocator.rawResize(memory, alignment, len, address)) return false;
        const self = get(raw);
        self.regions.items[self.index(memory.ptr)].len = len;
        return true;
    }
    fn remap(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, address: usize) ?[*]u8 {
        const ptr = std.heap.page_allocator.rawRemap(memory, alignment, len, address) orelse return null;
        const self = get(raw);
        self.regions.items[self.index(memory.ptr)] = .{ .ptr = ptr, .len = len };
        return ptr;
    }
    fn free(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self = get(raw);
        _ = self.regions.swapRemove(self.index(memory.ptr));
        std.heap.page_allocator.rawFree(memory, alignment, address);
    }
    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
};

test "snapshot scratch reuses bounded work buffers across resets" {
    var scratch: Scratch = .{};
    defer scratch.deinit();
    for (0..4) |i| {
        const arena = scratch.begin();
        const buffer = try arena.allocator().alloc(u8, 1024 * 1024);
        @memset(buffer, @intCast(i));
        try std.testing.expectEqual(@as(u8, @intCast(i)), buffer[buffer.len - 1]);
        scratch.end();
        try std.testing.expect(scratch.arena.?.queryCapacity() <= 128 * 1024 * 1024);
        if (builtin.os.tag == .macos) {
            try std.testing.expect(scratch.arena.?.queryCapacity() > 0);
            for (scratch.regions.items) |region| try std.testing.expect(region.reusable);
        }
    }
}
