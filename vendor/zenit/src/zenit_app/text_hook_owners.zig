//! Ownership stack for process-level text hooks (font resolver, drawn-width measure,
//! no-context measure fallback).
//!
//! Hooks are process-global but several Apps exist (main window, DevTools, ...). A deinit must not
//! clear another App's hooks, or the main window falls back to platform measure (cursor
//! misaligned).
//! Rule: hooks point to the stack top (latest init / setFontSelector App). Deinit removes only its
//! own entry; hooks fall back to the new top, empty stack clears to null. Order-independent.
//! Capacity is not a limit: spill to heap, never drop entries. Pure data structure, no ObjC/Metal
//! dependency (see build.zig test-text-hook-owners).

const std = @import("std");

pub fn OwnerStack(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            owner: *const anyopaque,
            ctx: *anyopaque,
        };

        /// regular case (<=capacity Apps) uses inline storage only, zero allocation.
        inline_entries: [capacity]Entry = undefined,
        /// heap storage when exceeding capacity. **cannot drop entries**: capacity comes from
        /// single MultiWindowApp's limit, independent App.init not constrained by it, process can
        /// have more owners than capacity. old impl dropped oldest entry when full (often main
        /// window), after closing other windows stack becomes empty and hooks cleared to null, main
        /// window still alive.
        heap_entries: ?[]Entry = null,
        len: usize = 0,
        /// only used on overflow; process-level global stack defaults page_allocator, tests can
        /// switch to testing.allocator to check leaks.
        allocator: std.mem.Allocator = std.heap.page_allocator,

        fn storage(self: *Self) []Entry {
            return self.heap_entries orelse &self.inline_entries;
        }

        fn constStorage(self: *const Self) []const Entry {
            return self.heap_entries orelse &self.inline_entries;
        }

        /// register / update owner's ctx and place it at stack top. return new stack-top ctx. only
        /// 'new owner and storage full' allocates; update of registered owner (setFontSelector)
        /// never fails. on alloc failure stack remains unchanged.
        pub fn push(self: *Self, owner: *const anyopaque, ctx: *anyopaque) error{OutOfMemory}!*anyopaque {
            const was_registered = self.removeEntry(owner);
            if (!was_registered and self.len == self.storage().len) try self.grow();
            self.storage()[self.len] = .{ .owner = owner, .ctx = ctx };
            self.len += 1;
            return ctx;
        }

        /// remove owner's entry, return stack-top ctx after removal (empty stack is null).
        pub fn remove(self: *Self, owner: *const anyopaque) ?*anyopaque {
            _ = self.removeEntry(owner);
            if (self.len == 0) self.releaseHeap();
            return self.top();
        }

        pub fn top(self: *const Self) ?*anyopaque {
            return if (self.len == 0) null else self.constStorage()[self.len - 1].ctx;
        }

        fn grow(self: *Self) error{OutOfMemory}!void {
            const old = self.storage();
            const bigger = try self.allocator.alloc(Entry, old.len * 2);
            @memcpy(bigger[0..self.len], old[0..self.len]);
            if (self.heap_entries) |h| self.allocator.free(h);
            self.heap_entries = bigger;
        }

        fn releaseHeap(self: *Self) void {
            if (self.heap_entries) |h| self.allocator.free(h);
            self.heap_entries = null;
        }

        fn removeEntry(self: *Self, owner: *const anyopaque) bool {
            const entries = self.storage();
            var found = false;
            var i: usize = 0;
            while (i < self.len) {
                if (entries[i].owner == owner) {
                    std.mem.copyForwards(Entry, entries[i .. self.len - 1], entries[i + 1 .. self.len]);
                    self.len -= 1;
                    found = true;
                } else i += 1;
            }
            return found;
        }
    };
}

const testing = std.testing;

test "关闭后开的辅助窗口：钩子回落到仍存活的主窗口 selector" {
    var stack: OwnerStack(4) = .{};
    var main_app: u8 = 0;
    var devtools_app: u8 = 0;
    var main_sel: u32 = 1;
    var devtools_sel: u32 = 2;
    try testing.expectEqual(@as(*anyopaque, &main_sel), try stack.push(&main_app, &main_sel));
    try testing.expectEqual(@as(*anyopaque, &devtools_sel), try stack.push(&devtools_app, &devtools_sel));
    // close DevTools: hooks must still point to main window, not cleared.
    try testing.expectEqual(@as(?*anyopaque, &main_sel), stack.remove(&devtools_app));
    try testing.expectEqual(@as(?*anyopaque, null), stack.remove(&main_app));
}

test "先关主窗口：栈顶的辅助窗口保持不变" {
    var stack: OwnerStack(4) = .{};
    var a: u8 = 0;
    var b: u8 = 0;
    var sel_a: u32 = 1;
    var sel_b: u32 = 2;
    _ = try stack.push(&a, &sel_a);
    _ = try stack.push(&b, &sel_b);
    try testing.expectEqual(@as(?*anyopaque, &sel_b), stack.remove(&a));
    try testing.expectEqual(@as(?*anyopaque, null), stack.remove(&b));
}

test "setFontSelector 更新同一 owner：不重复登记，析构后不残留旧 selector" {
    var stack: OwnerStack(4) = .{};
    var a: u8 = 0;
    var b: u8 = 0;
    var builtin_a: u32 = 1;
    var host_a: u32 = 3;
    var sel_b: u32 = 2;
    _ = try stack.push(&a, &builtin_a);
    _ = try stack.push(&b, &sel_b);
    _ = try stack.push(&a, &host_a);
    try testing.expectEqual(@as(usize, 2), stack.len);
    try testing.expectEqual(@as(?*anyopaque, &host_a), stack.top());
    try testing.expectEqual(@as(?*anyopaque, &sel_b), stack.remove(&a));
    // unregistered owner: no-op
    var stranger: u8 = 0;
    try testing.expectEqual(@as(?*anyopaque, &sel_b), stack.remove(&stranger));
}

test "栈满扩容而不是丢条目；全部移除后释放堆存储" {
    var stack: OwnerStack(2) = .{ .allocator = testing.allocator };
    var o: [5]u8 = .{ 0, 0, 0, 0, 0 };
    var s: [5]u32 = .{ 0, 1, 2, 3, 4 };
    for (0..5) |i| _ = try stack.push(&o[i], &s[i]);
    try testing.expectEqual(@as(usize, 5), stack.len);
    // registered owner update doesn't grow capacity.
    _ = try stack.push(&o[0], &s[0]);
    try testing.expectEqual(@as(?*anyopaque, &s[0]), stack.top());
    try testing.expectEqual(@as(?*anyopaque, &s[4]), stack.remove(&o[0]));
    try testing.expectEqual(@as(?*anyopaque, &s[4]), stack.remove(&o[2]));
    try testing.expectEqual(@as(?*anyopaque, &s[3]), stack.remove(&o[4]));
    try testing.expectEqual(@as(?*anyopaque, &s[1]), stack.remove(&o[3]));
    try testing.expectEqual(@as(?*anyopaque, null), stack.remove(&o[1]));
    try testing.expect(stack.heap_entries == null);
}

test "扩容分配失败：返回错误且栈保持原样" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var stack: OwnerStack(1) = .{ .allocator = failing.allocator() };
    var a: u8 = 0;
    var b: u8 = 0;
    var sel_a: u32 = 1;
    var sel_b: u32 = 2;
    _ = try stack.push(&a, &sel_a);
    try testing.expectError(error.OutOfMemory, stack.push(&b, &sel_b));
    try testing.expectEqual(@as(usize, 1), stack.len);
    try testing.expectEqual(@as(?*anyopaque, &sel_a), stack.top());
    // registered owner update doesn't allocate or fail even at full stack.
    _ = try stack.push(&a, &sel_b);
    try testing.expectEqual(@as(?*anyopaque, &sel_b), stack.top());
}

test "超过容量：主窗口不被挤掉，其余窗口全关后钩子仍指向主窗口" {
    // real scenario: OwnerStack is process-level, capacity comes from MultiWindowApp.max_windows,
    // but limit only applies to single MultiWindowApp; independent App.init unconstrained. so
    // 'independent main window + full MultiWindowApp' = capacity+1 owners. old impl dropped oldest
    // (= main window) when full, after closing other windows stack became empty -> hooks cleared to
    // null, main window still alive, measure fell back to platform (cursor/selection misaligned).
    var stack: OwnerStack(2) = .{ .allocator = testing.allocator };
    var main_app: u8 = 0;
    var main_sel: u32 = 100;
    var o: [2]u8 = .{ 0, 0 };
    var s: [2]u32 = .{ 1, 2 };
    _ = try stack.push(&main_app, &main_sel);
    for (0..2) |i| _ = try stack.push(&o[i], &s[i]);
    try testing.expectEqual(@as(?*anyopaque, &s[1]), stack.top());
    try testing.expectEqual(@as(?*anyopaque, &s[0]), stack.remove(&o[1]));
    try testing.expectEqual(@as(?*anyopaque, &main_sel), stack.remove(&o[0]));
    try testing.expectEqual(@as(?*anyopaque, null), stack.remove(&main_app));
}
