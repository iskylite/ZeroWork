//! History stashing during user edit transactions (value binding rejection restores
//! undo/redo stacks, binding.zig).
//!
//! Edit pressure on history does two irreversible things: clear redo stack; evict oldest
//! undo on full. In transaction, both become lazy, undoable:
//! - Redo stack detaches in-place: set count 0, entries stay, ownership to stash.
//!   Before writing redo stack must `settleRedo`; detached entries freed, slots returned.
//! - Evict entries: move to small fixed array (ownership transfer). Max one edit/push per event,
//!   `max_evicted` buffered; if full, free per original logic (no recovery).
//!
//! Edit rejected: `restore` pops pushed snapshots, restores evicted to stack bottom, redo
//! count reset -> history identical to pre-edit. Transaction normal end: `discard` frees.
//! Zero allocations, no stash-fail paths. Preserves external-write-semantics guarantee.
//! No parallel-with-history-stack array: TextInputState has size budget (< 32 KiB).

const std = @import("std");

/// Max evicted entries stashed per transaction (max one push per event)
pub const max_evicted: usize = 4;

pub fn HistoryStash(comptime Entry: type, comptime cap: usize) type {
    return struct {
        const Self = @This();

        /// Redo stack [0, detached_redo): entries delinked from count, ownership in stash
        redo_detached: bool = false,
        detached_redo: u8 = 0,
        /// Evicted undo entries, ordered by eviction time
        evicted: [max_evicted]Entry = @as([max_evicted]Entry, @splat(.{})),
        evicted_count: u8 = 0,

        /// Clear redo stack in transaction: first time set count 0, keep entries, return true;
        /// already detached (clear again same transaction) return false, caller frees per original
        /// logic.
        pub fn detachRedo(self: *Self, redo_count: *u8) bool {
            if (self.redo_detached) return false;
            self.redo_detached = true;
            self.detached_redo = redo_count.*;
            redo_count.* = 0;
            return true;
        }

        /// Call before writing redo stack: detached entries freed now (reuse slots), no recovery
        /// after
        pub fn settleRedo(self: *Self, redo: *[cap]Entry, allocator: std.mem.Allocator) void {
            if (!self.redo_detached) return;
            for (0..self.detached_redo) |i| {
                redo[i].deinit(allocator);
                redo[i] = .{};
            }
            self.detached_redo = 0;
            self.redo_detached = false;
        }

        /// Evict oldest undo on transaction stack full: move to stash return true; stash full
        /// return false (caller frees)
        pub fn keepEvicted(self: *Self, entry: Entry) bool {
            if (self.evicted_count == max_evicted) return false;
            self.evicted[self.evicted_count] = entry;
            self.evicted_count += 1;
            return true;
        }

        pub fn isEmpty(self: *const Self) bool {
            return !self.redo_detached and self.evicted_count == 0;
        }

        /// Edit rejected: pop `pushes` snapshots pushed this time, restore evicted entries to stack
        /// bottom
        /// in original order, redo count reset. Stash then empty.
        pub fn restore(
            self: *Self,
            undo: *[cap]Entry,
            undo_count: *u8,
            redo: *[cap]Entry,
            redo_count: *u8,
            pushes: u8,
            allocator: std.mem.Allocator,
        ) void {
            var n = pushes;
            while (n > 0 and undo_count.* > 0) : (n -= 1) {
                undo_count.* -= 1;
                undo[undo_count.*].deinit(allocator);
                undo[undo_count.*] = .{};
            }
            // Later-evicted restored first: final stack bottom order matches pre-eviction
            while (self.evicted_count > 0) {
                self.evicted_count -= 1;
                var entry = self.evicted[self.evicted_count];
                self.evicted[self.evicted_count] = .{};
                if (undo_count.* == cap) {
                    // Popped count < evicted (shouldn't happen): can't restore, free per original
                    // logic
                    entry.deinit(allocator);
                    continue;
                }
                var i: usize = undo_count.*;
                while (i > 0) : (i -= 1) undo[i] = undo[i - 1];
                undo[0] = entry;
                undo_count.* += 1;
            }
            if (self.redo_detached) {
                // After detach, must settle before writing redo stack, so redo stack is empty here:
                // count
                // reset restores. Defense: if transaction-generated entries exist, free per
                // original then reset
                for (0..redo_count.*) |i| {
                    redo[i].deinit(allocator);
                    redo[i] = .{};
                }
                redo_count.* = self.detached_redo;
                self.detached_redo = 0;
                self.redo_detached = false;
            }
        }

        /// Transaction normal end / history fully cleared: free stashed entries
        pub fn discard(self: *Self, redo: *[cap]Entry, allocator: std.mem.Allocator) void {
            self.settleRedo(redo, allocator);
            for (0..self.evicted_count) |i| {
                self.evicted[i].deinit(allocator);
                self.evicted[i] = .{};
            }
            self.evicted_count = 0;
        }
    };
}

const testing = std.testing;

const TestEntry = struct {
    text: ?[]u8 = null,
    fn deinit(self: *TestEntry, allocator: std.mem.Allocator) void {
        if (self.text) |t| allocator.free(t);
        self.text = null;
    }
};

fn makeEntry(text: []const u8) !TestEntry {
    return .{ .text = try testing.allocator.dupe(u8, text) };
}

test "HistoryStash: 淘汰 + 清重做后 restore 逐条还原；discard 释放" {
    const S = HistoryStash(TestEntry, 3);
    var undo = @as([3]TestEntry, @splat(.{}));
    var redo = @as([3]TestEntry, @splat(.{}));
    var undo_count: u8 = 3;
    var redo_count: u8 = 1;
    undo[0] = try makeEntry("a");
    undo[1] = try makeEntry("b");
    undo[2] = try makeEntry("c");
    redo[0] = try makeEntry("r");
    const a_ptr = undo[0].text.?.ptr;
    const r_ptr = redo[0].text.?.ptr;

    var stash = S{};
    // Simulate one push: stack full evict a, clear redo, push d
    try testing.expect(stash.detachRedo(&redo_count));
    try testing.expectEqual(@as(u8, 0), redo_count);
    try testing.expect(stash.keepEvicted(undo[0]));
    undo[0] = undo[1];
    undo[1] = undo[2];
    undo[2] = try makeEntry("d");

    stash.restore(&undo, &undo_count, &redo, &redo_count, 1, testing.allocator);
    try testing.expect(stash.isEmpty());
    try testing.expectEqual(@as(u8, 3), undo_count);
    try testing.expectEqual(a_ptr, undo[0].text.?.ptr);
    try testing.expectEqualStrings("b", undo[1].text.?);
    try testing.expectEqualStrings("c", undo[2].text.?);
    try testing.expectEqual(@as(u8, 1), redo_count);
    try testing.expectEqual(r_ptr, redo[0].text.?.ptr);

    // Second transaction: normal end, discard frees detached redo entries
    try testing.expect(stash.detachRedo(&redo_count));
    try testing.expect(!stash.detachRedo(&redo_count));
    stash.discard(&redo, testing.allocator);
    try testing.expect(stash.isEmpty());
    try testing.expectEqual(@as(?[]u8, null), redo[0].text);
    for (&undo) |*e| e.deinit(testing.allocator);
}

test "HistoryStash: 一个事务里两次淘汰，放回后栈底顺序与淘汰前一致" {
    const S = HistoryStash(TestEntry, 3);
    var undo = @as([3]TestEntry, @splat(.{}));
    var redo = @as([3]TestEntry, @splat(.{}));
    var undo_count: u8 = 3;
    var redo_count: u8 = 0;
    undo[0] = try makeEntry("a");
    undo[1] = try makeEntry("b");
    undo[2] = try makeEntry("c");
    var stash = S{};
    // Two pushes: evict a, then b
    for ([_][]const u8{ "d", "e" }) |t| {
        try testing.expect(stash.keepEvicted(undo[0]));
        undo[0] = undo[1];
        undo[1] = undo[2];
        undo[2] = try makeEntry(t);
    }
    stash.restore(&undo, &undo_count, &redo, &redo_count, 2, testing.allocator);
    try testing.expectEqual(@as(u8, 3), undo_count);
    try testing.expectEqualStrings("a", undo[0].text.?);
    try testing.expectEqualStrings("b", undo[1].text.?);
    try testing.expectEqualStrings("c", undo[2].text.?);
    for (&undo) |*e| e.deinit(testing.allocator);
}

test "HistoryStash: 往重做栈写入前 settle 释放脱离的条目，之后不再还原" {
    const S = HistoryStash(TestEntry, 3);
    var redo = @as([3]TestEntry, @splat(.{}));
    var redo_count: u8 = 2;
    redo[0] = try makeEntry("x");
    redo[1] = try makeEntry("y");
    var stash = S{};
    try testing.expect(stash.detachRedo(&redo_count));
    stash.settleRedo(&redo, testing.allocator);
    try testing.expect(stash.isEmpty());
    try testing.expectEqual(@as(?[]u8, null), redo[0].text);
    try testing.expectEqual(@as(?[]u8, null), redo[1].text);
    // Settled: discard won't free again
    stash.discard(&redo, testing.allocator);
}
