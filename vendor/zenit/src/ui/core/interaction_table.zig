//! InteractionTable: interaction/focus/gesture state split from Node.
//!
//! Unlike the Element/Layout/Paint tables it is **sparse**: not every element has interaction.
//! Inside is an ElementId.raw() -> InteractionData hash map with the cheap id hash from
//! id_hash.zig (looked up for every node on every frame by the world sync pass).
//!
//! - don't store hit_test_AABB geometry in the table, hit_runtime AABB tree holds that
//!   (table stores semantics only: focus_index, scroll_state ref, listened events)
//!
//! Hash degeneration: std HashMapUnmanaged deletes via tombstones; a long-lived table under
//! scroll churn (remove eventless nodes, add new ones each frame) accumulates tombstones and
//! get/remove probe chains lengthen. Two counters:
//!   1. contains check before remove: for nonexistent keys (the vast majority in churn) no
//!      tombstone write; probe cost is the same but nothing is written.
//!   2. removed_since_rehash exceeding max(64, live) triggers rehash(), which clears all
//!      tombstones (std/hash_map.zig rehash docs describe this use).

const std = @import("std");
const testing = std.testing;
const element_id_mod = @import("element_id.zig");
const id_hash = @import("id_hash.zig");

pub const ElementId = element_id_mod.ElementId;

pub const HitBehavior = enum(u8) {
    /// Default: self-hittable, events bubble
    bubble,
    /// Passthrough: self not hittable (mouse pierces through), events don't reach
    pass_through,
    /// Stop propagation: self hittable and consumes event
    capture_only,
};

pub const FocusFlags = packed struct(u8) {
    focusable: bool = false,
    /// Whether in tab sequence (meaningless when focusable=false)
    tabbable: bool = true,
    /// Whether currently focused
    focused: bool = false,
    /// Mouse over state
    hovered: bool = false,
    // Had focus_trap bit once, never read/written anywhere, real focus trap is
    // FocusScopeConfig.trap (different struct, same-name semantic, has test coverage).
    // Keeping it only suggests 'set this get trap effect', deleted.
    _reserved: u4 = 0,
};

pub const InteractionData = struct {
    behavior: HitBehavior = .bubble,
    focus: FocusFlags = .{},
    /// tab-index (HTML semantic: 0/null = tree order; positive = priority; -1 = exclude)
    tab_index: i16 = 0,
    /// Reference PropertyTree.scrolls id; INVALID = not scroll container
    scroll_id: u32 = std.math.maxInt(u32),
    /// Listened event mask (bit positions represent event types; specifics in events.zig)
    event_mask: u32 = 0,
    /// User a11y role (currently using u16 equal to a11y.role enum; Phase 6 rework a11y migrate
    /// there)
    a11y_role: u16 = 0,
    /// User a11y label hash (avoid storing []const u8); Phase 6 provide full a11y tree
    a11y_label_hash: u64 = 0,
};

pub const InteractionTable = struct {
    allocator: std.mem.Allocator,
    /// Sparse storage: ElementId.raw() -> InteractionData
    data: id_hash.U32HashMapUnmanaged(InteractionData),
    /// Successful delete count since last rehash (tombstone generation count lower bound)
    removed_since_rehash: usize = 0,
    /// Live entry count (put new key +1 / remove hit -1; identical to data.count(),
    /// held separately so threshold check doesn't duplicate probe)
    live_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) InteractionTable {
        return .{ .allocator = allocator, .data = .{} };
    }

    pub fn deinit(self: *InteractionTable) void {
        self.data.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn put(self: *InteractionTable, id: ElementId, data: InteractionData) !void {
        if (id.isNull()) return;
        const key = id.raw();
        if (!self.data.contains(key)) self.live_count += 1;
        try self.data.put(self.allocator, key, data);
    }

    pub fn get(self: *const InteractionTable, id: ElementId) ?InteractionData {
        if (id.isNull()) return null;
        return self.data.get(id.raw());
    }

    pub fn getPtr(self: *InteractionTable, id: ElementId) ?*InteractionData {
        if (id.isNull()) return null;
        return self.data.getPtr(id.raw());
    }

    /// Delete entry. Returns whether actually deleted.
    ///
    /// contains check first. std HashMapUnmanaged remove on a nonexistent key also probes without
    /// writing a tombstone, but getIndex doesn't early-stop in tombstone regions, so consecutive
    /// removes of now-nonexistent keys after churn double the probe cost. Probe cost is identical;
    /// the real win is that removed_since_rehash counts only actual deletes, so empty removes
    /// don't push the rehash threshold.
    pub fn remove(self: *InteractionTable, id: ElementId) bool {
        if (id.isNull()) return false;
        const key = id.raw();
        if (!self.data.contains(key)) return false;
        const removed = self.data.remove(key);
        if (removed) {
            self.live_count -= 1;
            self.removed_since_rehash += 1;
            // Tombstone accumulation over live entry scale triggers full rehash (O(capacity),
            // amortized O(1) per entry). std docs: rehash clears all tombstones.
            if (self.removed_since_rehash > @max(64, self.live_count)) {
                self.data.rehash(id_hash.U32Context{});
                self.removed_since_rehash = 0;
            }
        }
        return removed;
    }

    pub fn count(self: *const InteractionTable) usize {
        return self.data.count();
    }

    /// Mark element focused/blurred (hot path, use getPtr)
    pub fn setFocused(self: *InteractionTable, id: ElementId, focused: bool) void {
        if (self.getPtr(id)) |d| d.focus.focused = focused;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "InteractionTable: put/get/remove" {
    var t = InteractionTable.init(testing.allocator);
    defer t.deinit();

    const id: ElementId = .{ .index = 5, .generation = 1 };
    try testing.expect(t.get(id) == null);

    try t.put(id, .{ .behavior = .bubble, .tab_index = 3 });
    const got = t.get(id).?;
    try testing.expectEqual(@as(i16, 3), got.tab_index);

    try testing.expect(t.remove(id));
    try testing.expect(t.get(id) == null);
}

test "InteractionTable: setFocused via getPtr" {
    var t = InteractionTable.init(testing.allocator);
    defer t.deinit();

    const id: ElementId = .{ .index = 0, .generation = 0 };
    try t.put(id, .{});

    t.setFocused(id, true);
    try testing.expect(t.get(id).?.focus.focused);

    t.setFocused(id, false);
    try testing.expect(!t.get(id).?.focus.focused);
}

test "InteractionTable: count tracks live entries" {
    var t = InteractionTable.init(testing.allocator);
    defer t.deinit();
    try testing.expectEqual(@as(usize, 0), t.count());

    try t.put(.{ .index = 0, .generation = 0 }, .{});
    try t.put(.{ .index = 1, .generation = 0 }, .{});
    try testing.expectEqual(@as(usize, 2), t.count());

    _ = t.remove(.{ .index = 0, .generation = 0 });
    try testing.expectEqual(@as(usize, 1), t.count());
}

test "FocusFlags is 1 byte" {
    try testing.expectEqual(@as(usize, 1), @sizeOf(FocusFlags));
}

test "InteractionTable: NULL id is no-op" {
    var t = InteractionTable.init(testing.allocator);
    defer t.deinit();

    try t.put(ElementId.NULL, .{});
    try testing.expect(t.get(ElementId.NULL) == null);
    try testing.expectEqual(@as(usize, 0), t.count());
}

test "InteractionTable: remove of absent key makes no tombstone / no rehash trigger" {
    var t = InteractionTable.init(testing.allocator);
    defer t.deinit();

    // Empty remove doesn't count in removed_since_rehash, doesn't touch live_count
    try testing.expect(!t.remove(.{ .index = 42, .generation = 0 }));
    try testing.expectEqual(@as(usize, 0), t.removed_since_rehash);
    try testing.expectEqual(@as(usize, 0), t.live_count);

    // Only real deletes count
    try t.put(.{ .index = 42, .generation = 0 }, .{});
    try testing.expect(t.remove(.{ .index = 42, .generation = 0 }));
    try testing.expectEqual(@as(usize, 1), t.removed_since_rehash);
    try testing.expectEqual(@as(usize, 0), t.live_count);
    try testing.expectEqual(@as(usize, 0), t.count());
}

test "InteractionTable: rehash fires when removals outgrow live set" {
    var t = InteractionTable.init(testing.allocator);
    defer t.deinit();

    // live=0 threshold max(64, 0)=64: delete 65 (each put then delete) should trigger one rehash
    // clear
    var i: u32 = 0;
    while (i < 65) : (i += 1) {
        try t.put(.{ .index = @intCast(i), .generation = 0 }, .{});
        _ = t.remove(.{ .index = @intCast(i), .generation = 0 });
    }
    try testing.expectEqual(@as(usize, 0), t.removed_since_rehash);
    try testing.expectEqual(@as(usize, 0), t.count());
    try testing.expectEqual(@as(usize, 0), t.live_count);

    // Rehash doesn't lose data while entry still in table
    var j: u32 = 0;
    while (j < 40) : (j += 1) {
        try t.put(.{ .index = @intCast(1000 + j), .generation = 3 }, .{ .tab_index = @intCast(j) });
    }
    var k: u32 = 0;
    while (k < 200) : (k += 1) {
        try t.put(.{ .index = @intCast(5000 + k), .generation = 0 }, .{});
        _ = t.remove(.{ .index = @intCast(5000 + k), .generation = 0 });
    }
    // 200 real deletes, live=40 -> threshold 64: at least one rehash in between, remaining count
    // necessarily <= threshold
    try testing.expect(t.removed_since_rehash <= @max(64, t.live_count));
    try testing.expectEqual(@as(usize, 40), t.count());
    var m: u32 = 0;
    while (m < 40) : (m += 1) {
        const d = t.get(.{ .index = @intCast(1000 + m), .generation = 3 }).?;
        try testing.expectEqual(@as(i16, @intCast(m)), d.tab_index);
    }
}

/// Churn baseline: N rounds 'insert M keys -> delete M-K of them', swap key range each round.
/// Return measured ns per 10k gets.
fn churnGetCost(comptime do_churn: bool) u64 {
    const ROUNDS = 200;
    const KEYS = 2000;
    const KEEP = 100; // delete 1900 per round

    var t = InteractionTable.init(std.heap.page_allocator);
    defer t.deinit();

    var r: u32 = 0;
    while (r < ROUNDS) : (r += 1) {
        const base = @as(u32, KEYS) * r;
        var i: u32 = 0;
        while (i < KEYS) : (i += 1) {
            t.put(
                .{ .index = @intCast((base + i) & element_id_mod.MAX_INDEX), .generation = @intCast((base + i) >> 24 & 0xFF) },
                .{ .tab_index = @intCast(i & 0x7F) },
            ) catch @panic("oom");
        }
        if (do_churn) {
            var d: u32 = 0;
            while (d < KEYS - KEEP) : (d += 1) {
                _ = t.remove(.{ .index = @intCast((base + d) & element_id_mod.MAX_INDEX), .generation = @intCast((base + d) >> 24 & 0xFF) });
            }
        }
    }

    // End state: (a) count matches live_count
    assert(t.count() == t.live_count);

    // (b) 10k gets (cross multiple key ranges, churn range and keep range)
    var timer = @import("zenit_time").Timer.start(std.testing.io) catch @panic("no timer");
    var sink: i64 = 0;
    var probe: u32 = 0;
    while (probe < 10_000) : (probe += 1) {
        const eid = ElementId{
            .index = @intCast((probe * 7919) & element_id_mod.MAX_INDEX),
            .generation = @intCast((probe * 7919) >> 24 & 0xFF),
        };
        if (t.get(eid)) |d| sink += d.tab_index;
    }
    std.mem.doNotOptimizeAway(sink);
    return timer.read();
}

fn assert(ok: bool) void {
    if (!ok) @panic("assert failed");
}

test "InteractionTable: churn does not degrade get latency (<=3x fresh)" {
    if (builtin_mode == .debug) {
        // Debug hash/probe constants large, noise high, threshold relaxed 3x still must test.
    }
    const churned = churnGetCost(true);
    const fresh = churnGetCost(false);
    // Fresh table (never removed) 40k live entries same, fairest baseline.
    const ratio = @as(f64, @floatFromInt(churned)) / @as(f64, @floatFromInt(fresh));
    const limit: f64 = 3.0;
    std.debug.print(
        "churn get={d}ns fresh get={d}ns ratio={d:.2} (limit {d:.1})\n",
        .{ churned, fresh, ratio, limit },
    );
    try testing.expect(ratio <= limit);
}

const builtin_mode = @import("builtin").mode;
