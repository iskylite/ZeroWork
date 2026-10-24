//! LayoutTable: storage for Node's layout products (SoA, dense, indexed by ElementId).
//!
//! 1:1 with ElementTable: each element creation syncs a layout_table slot allocation. Fields are
//! split (constraints_in / final_rect / baseline / layout_epoch / intrinsic_cache) so the layout
//! pass (reads constraints, writes rect) and paint pass (reads rect) each scan a single field array
//! sequentially, cache-friendly.
//!
//! Do not:
//! - Store "render cache" or "hit proxies" here; those go in PaintTable / InteractionTable
//! - Attach an Allocator per entry; intrinsic_cache is an inline struct (4 entries, no heap alloc)

const std = @import("std");
const testing = std.testing;
const constraint = @import("layout/constraint.zig");
const element_id_mod = @import("element_id.zig");

pub const ElementId = element_id_mod.ElementId;
pub const LayoutInput = constraint.LayoutInput;
pub const LayoutOutput = constraint.LayoutOutput;
pub const Size2D = constraint.Size2D;
pub const IntrinsicCache = constraint.IntrinsicCache;

/// final_rect: element position + measured size in parent space
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub const ZERO: Rect = .{};
};

/// Single LayoutTable record
pub const LayoutData = struct {
    /// Parent -> child constraint (most recent layout input)
    last_input: LayoutInput = .{ .available_space = .{ .width = .max_content, .height = .max_content } },
    /// Measured size (written by perform_layout)
    measured: Size2D = .{},
    /// final_rect (in parent space)
    final_rect: Rect = .{},
    /// First line baseline (for align-items: baseline)
    first_baseline: ?f32 = null,
    /// layout_epoch++ on each recalculation; downstream paint cache uses this to detect
    /// invalidation
    layout_epoch: u64 = 0,
    /// Intrinsic measurement cache (4-entry direct-mapped)
    intrinsic_cache: IntrinsicCache = .{},
};

pub const LayoutTable = struct {
    allocator: std.mem.Allocator,
    items: std.MultiArrayList(LayoutData),
    /// Field arrays of `items`, re-derived only when `ensureSlot` grows it (the
    /// sole structural mutation). Every frame reads rects ~10^5 times through
    /// `rectIfLaidOut`; deriving them per read meant a full `MultiArrayList.slice()`
    /// (pointer math for all six fields, un-inlined in Debug) per lookup.
    final_rects: []Rect = &.{},
    layout_epochs: []u64 = &.{},

    pub fn init(allocator: std.mem.Allocator) LayoutTable {
        return .{ .allocator = allocator, .items = .{} };
    }

    pub fn deinit(self: *LayoutTable) void {
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    /// Ensure slot for the corresponding ElementId exists (direct indexing). Caller must keep in
    /// sync with ElementTable: element create -> layout.ensure(id)
    pub fn ensureSlot(self: *LayoutTable, id: ElementId) !void {
        if (id.isNull()) return;
        const idx = id.index;
        if (self.items.len > idx) return;
        // Refresh even when an append fails midway: the appends that succeeded
        // may already have reallocated the storage.
        defer self.refreshFieldArrays();
        while (self.items.len <= idx) {
            try self.items.append(self.allocator, .{});
        }
    }

    fn refreshFieldArrays(self: *LayoutTable) void {
        const s = self.items.slice();
        self.final_rects = s.items(.final_rect);
        self.layout_epochs = s.items(.layout_epoch);
    }

    pub fn get(self: *const LayoutTable, id: ElementId) ?LayoutData {
        if (id.isNull() or id.index >= self.items.len) return null;
        return self.items.get(id.index);
    }

    pub fn rect(self: *const LayoutTable, id: ElementId) ?Rect {
        if (id.isNull() or id.index >= self.final_rects.len) return null;
        return self.final_rects[id.index];
    }

    pub fn setRect(self: *LayoutTable, id: ElementId, r: Rect) void {
        if (id.isNull() or id.index >= self.final_rects.len) return;
        self.final_rects[id.index] = r;
    }

    /// Reset a dense slot before its ElementTable index is reused by another
    /// generation. Dense auxiliary tables intentionally retain capacity, but no
    /// layout output may cross element ownership.
    pub fn clear(self: *LayoutTable, id: ElementId) void {
        if (id.isNull() or id.index >= self.items.len) return;
        self.items.set(id.index, .{});
    }

    pub fn epoch(self: *const LayoutTable, id: ElementId) u64 {
        if (id.isNull() or id.index >= self.layout_epochs.len) return 0;
        return self.layout_epochs[id.index];
    }

    /// Single combined read of epoch and rect: epoch==0 (seeded, not markLaidOut) returns null.
    /// Hot read path (rectFromWorldOrFallback, ~100k times per frame): reads the cached field
    /// arrays directly.
    pub fn rectIfLaidOut(self: *const LayoutTable, id: ElementId) ?Rect {
        if (id.isNull() or id.index >= self.final_rects.len) return null;
        if (self.layout_epochs[id.index] == 0) return null;
        return self.final_rects[id.index];
    }

    /// Mark id for relayout; epoch++, clear intrinsic cache (input constraint changed)
    pub fn markLaidOut(self: *LayoutTable, id: ElementId, measured: Size2D, r: Rect) void {
        if (id.isNull() or id.index >= self.items.len) return;
        self.items.items(.measured)[id.index] = measured;
        self.final_rects[id.index] = r;
        self.layout_epochs[id.index] +%= 1;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "LayoutTable: ensureSlot grows as needed" {
    var t = LayoutTable.init(testing.allocator);
    defer t.deinit();

    const id_5: ElementId = .{ .index = 5, .generation = 0 };
    try t.ensureSlot(id_5);
    try testing.expectEqual(@as(usize, 6), t.items.len);
}

test "LayoutTable: setRect / rect roundtrip" {
    var t = LayoutTable.init(testing.allocator);
    defer t.deinit();

    const id: ElementId = .{ .index = 0, .generation = 0 };
    try t.ensureSlot(id);
    t.setRect(id, .{ .x = 10, .y = 20, .width = 100, .height = 50 });

    const r = t.rect(id).?;
    try testing.expectEqual(@as(f32, 10), r.x);
    try testing.expectEqual(@as(f32, 100), r.width);
}

test "LayoutTable: markLaidOut bumps epoch" {
    var t = LayoutTable.init(testing.allocator);
    defer t.deinit();

    const id: ElementId = .{ .index = 0, .generation = 0 };
    try t.ensureSlot(id);
    const e0 = t.epoch(id);

    t.markLaidOut(id, .{ .width = 100, .height = 50 }, .{ .x = 0, .y = 0, .width = 100, .height = 50 });
    const e1 = t.epoch(id);
    try testing.expect(e1 > e0);

    t.markLaidOut(id, .{ .width = 200, .height = 50 }, .{ .x = 0, .y = 0, .width = 200, .height = 50 });
    const e2 = t.epoch(id);
    try testing.expect(e2 > e1);
}

test "LayoutTable: invalid id returns null" {
    var t = LayoutTable.init(testing.allocator);
    defer t.deinit();

    const id: ElementId = .{ .index = 99, .generation = 0 };
    try testing.expect(t.get(id) == null);
    try testing.expect(t.rect(id) == null);
    try testing.expectEqual(@as(u64, 0), t.epoch(id));
}

test "LayoutTable: clear resets rect and epoch" {
    var t = LayoutTable.init(testing.allocator);
    defer t.deinit();

    const id: ElementId = .{ .index = 0, .generation = 0 };
    try t.ensureSlot(id);
    t.markLaidOut(id, .{ .width = 100, .height = 50 }, .{ .x = 7, .y = 8, .width = 100, .height = 50 });
    t.clear(id);

    try testing.expectEqual(Rect.ZERO, t.rect(id).?);
    try testing.expectEqual(@as(u64, 0), t.epoch(id));
}
