/// VirtualList dynamic variable-height **geometry core**.
///
/// Only pure data structures and algorithms here: no Node / Cx / render, so it can be unit
/// tested outside a window. The component side (mod.zig) feeds measured row heights and gets
/// computed ranges.
///
/// Aligned with the TanStack Virtual (@tanstack/virtual-core) dynamic measure model; three key
/// points are taken from it:
///
/// 1. **Two-level cache, two key domains**.
///    - `sizes`: measured height by **item key** (caller-provided, default = index).
///      Keyed by key, not index, so prepending a row doesn't invalidate later measurements;
///      the key follows the data.
///    - `layout`: prefix sum (start, size) by **index**. Position-based, rebuilt.
///
/// 2. **Incremental prefix sum**. A measurement only moves `pending_min` forward; rebuild keeps
///    `[0, pending_min)` untouched and re-walks from `pending_min`. Not a segment tree: an
///    O(n-min) forward walk with a trivial loop body, and min is usually near the viewport.
///
/// 3. **Scroll anchoring**. When a row above the viewport goes from estimated to measured
///    height, scroll_y must be compensated synchronously, else the viewed content bounces.
///    First vs re-measure criteria differ, see `applyMeasurement`.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// stable id for item. default take index, caller can provide key_fn to follow data.
pub const ItemKey = u64;

/// single item layout result (prefix sum cell).
pub const Measurement = struct {
    /// y of this item's top relative content origin.
    start: f32,
    /// this item's height (measured value, or estimate if not measured yet).
    size: f32,

    pub fn end(self: Measurement) f32 {
        return self.start + self.size;
    }
};

/// one measurement's impact on scroll position.
pub const MeasureOutcome = struct {
    /// height truly changed (needs reflow/redraw).
    changed: bool = false,
    /// compensation amount to apply to scroll_y (0 = no move).
    scroll_adjustment: f32 = 0,
};

/// scroll direction, used re-measure to suppress 'chain displacement from row height jitter while
/// scrolling up'.
pub const ScrollDirection = enum { forward, backward, idle };

pub const Options = struct {
    /// total row count.
    count: usize = 0,
    /// estimate height for unmeasured rows (variable per index).
    estimate_fn: ?*const fn (index: usize, ctx: ?*anyopaque) f32 = null,
    estimate_ctx: ?*anyopaque = null,
    /// fixed estimate value (used when estimate_fn == null).
    estimate: f32 = 32,
    /// item -> stable key. null = use index itself.
    key_fn: ?*const fn (index: usize, ctx: ?*anyopaque) ItemKey = null,
    key_ctx: ?*anyopaque = null,
    /// row gap (added after each row, not part of that row's end).
    gap: f32 = 0,
    /// content top padding (start of item 0).
    padding_start: f32 = 0,
};

pub const Measurements = struct {
    allocator: Allocator,
    opts: Options,

    /// key -> measured height. **only measurements** enter here; estimates never written,
    /// else can't distinguish 'measured 32px' from 'guessed 32px', first/re-measure criteria
    /// breaks.
    sizes: std.AutoHashMapUnmanaged(ItemKey, f32) = .{},

    /// index -> prefix sum. length always equals opts.count (realigned on rebuild).
    layout: []Measurement = &.{},

    /// earliest dirty index since last rebuild. null = clean.
    pending_min: ?usize = null,

    /// compensation applied but not yet 'digested' by scroll state. must include when determining
    /// first/re-measure,
    /// else two consecutive measurements same frame each base on old position.
    pending_adjustment: f32 = 0,

    pub fn init(allocator: Allocator, opts: Options) Measurements {
        return .{ .allocator = allocator, .opts = opts };
    }

    pub fn deinit(self: *Measurements) void {
        self.sizes.deinit(self.allocator);
        if (self.layout.len > 0) self.allocator.free(self.layout);
        self.layout = &.{};
    }

    pub fn keyOf(self: *const Measurements, index: usize) ItemKey {
        if (self.opts.key_fn) |f| return f(index, self.opts.key_ctx);
        return @intCast(index);
    }

    /// height to use for item at index: measured first, else estimate.
    pub fn sizeOf(self: *const Measurements, index: usize) f32 {
        if (self.sizes.get(self.keyOf(index))) |measured| return measured;
        return self.estimateOf(index);
    }

    pub fn estimateOf(self: *const Measurements, index: usize) f32 {
        const raw = if (self.opts.estimate_fn) |f|
            f(index, self.opts.estimate_ctx)
        else
            self.opts.estimate;
        // height must be positive and finite: 0 / NaN loops binary search and forward scan forever.
        return if (std.math.isFinite(raw) and raw > 0) raw else 32;
    }

    pub fn hasMeasurement(self: *const Measurements, index: usize) bool {
        return self.sizes.contains(self.keyOf(index));
    }

    /// row count changed. **do not clear sizes**, it's key domain, old key height valid after count
    /// changes
    /// (that's why prepend is cheap). but layout is position-based, must fully rebuild.
    pub fn setCount(self: *Measurements, count: usize) void {
        if (self.opts.count == count) return;
        self.opts.count = count;
        self.pending_min = 0;
    }

    /// discard all measurements, revert to pure estimates (use when data source entirely swapped).
    pub fn resetMeasurements(self: *Measurements) void {
        self.sizes.clearRetainingCapacity();
        self.pending_min = 0;
    }

    /// Invalidate the entire prefix sum but **keep measured values**.
    ///
    /// For when the `estimate_fn` return value itself changes (VirtualList `item_height_fn` mode:
    /// the caller's callback changes are unobservable here). Without this, `sizeOf` reads the live
    /// callback value but `offsetOf` / `totalHeight` read the stale cache, so the geometry
    /// contradicts itself (callback 10->100: itemHeight=100 but totalHeight still 1000).
    ///
    /// Differs from `resetMeasurements`, which drops measurements and reverts to estimates; this
    /// only drops the derived prefix sum.
    pub fn markAllDirty(self: *Measurements) void {
        self.pending_min = 0;
    }

    /// invalidate single row's measurement, revert to estimate and remeasure on next layout.
    pub fn invalidate(self: *Measurements, index: usize) void {
        if (self.sizes.remove(self.keyOf(index))) {
            self.markDirty(index);
        }
    }

    fn markDirty(self: *Measurements, index: usize) void {
        if (self.pending_min) |m| {
            if (index < m) self.pending_min = index;
        } else {
            self.pending_min = index;
        }
    }

    /// Fill in the true height measured by layout. Returns changed + needed scroll compensation.
    ///
    /// Scroll anchoring criteria (from TanStack; two rules by 'first measure'):
    ///
    /// - **first measure**: compensate if the item's **top** is above the viewport line
    ///   (`start < anchor`); the estimate->measured gap must be corrected both ways.
    ///
    /// - **re-measure**: compensate only if the item's **whole self** is above the line
    ///   (`end <= anchor`), and never while scrolling up. An item spanning the viewport line (top
    ///   at the line, bottom below, e.g. a streaming chat bubble) grows **below the anchor**;
    ///   compensating would pull the viewport down once per growth, looking like 'content keeps
    ///   scrolling down'.
    pub fn applyMeasurement(
        self: *Measurements,
        index: usize,
        measured: f32,
        anchor_scroll_y: f32,
        direction: ScrollDirection,
    ) MeasureOutcome {
        if (index >= self.opts.count) return .{};
        if (!std.math.isFinite(measured) or measured <= 0) return .{};

        const key = self.keyOf(index);
        const prev = self.sizes.get(key);
        const is_first_measure = prev == null;
        // compare to old value: on first measure against 'live effective value' (i.e. estimate).
        const old_size = prev orelse self.estimateOf(index);
        const delta = measured - old_size;
        if (@abs(delta) < 0.01) {
            // value unchanged but first measure still records, else every frame looks 'first time
            // measured',
            // re-measure criteria never reached.
            if (is_first_measure) {
                self.sizes.put(self.allocator, key, measured) catch return .{};
            }
            return .{};
        }

        // this item's current start: must read **before** writing new value, else get new geometry.
        const item_start = self.offsetOf(index);
        const anchor = anchor_scroll_y + self.pending_adjustment;

        const should_adjust = if (is_first_measure)
            item_start < anchor
        else
            (item_start + old_size <= anchor) and direction != .backward;

        self.sizes.put(self.allocator, key, measured) catch return .{};
        self.markDirty(index);

        if (should_adjust) {
            self.pending_adjustment += delta;
            return .{ .changed = true, .scroll_adjustment = delta };
        }
        return .{ .changed = true, .scroll_adjustment = 0 };
    }

    /// compensation digested by scroll state, clear book.
    pub fn consumeAdjustment(self: *Measurements) void {
        self.pending_adjustment = 0;
    }

    /// incremental rebuild prefix sum: keep [0, min), re-walk from min onward.
    pub fn ensureBuilt(self: *Measurements) void {
        const count = self.opts.count;
        if (self.layout.len != count) {
            const grown = self.allocator.realloc(self.layout, count) catch {
                // alloc failed: keep old table untouched, force retry next frame. geometry temp
                // mismatch,
                // but no UB, all read points bounds-check against layout.len.
                self.pending_min = 0;
                return;
            };
            const old_len = self.layout.len;
            self.layout = grown;
            // table size changed, new tail is **uninitialized memory**, must re-walk.
            // start point = min(old length, any dirty index): new memory after old length (must
            // write),
            // dirty beyond that (must recalc). note cannot write `pending_min orelse count`, when
            // pending_min null
            // (table was clean) that gives count, loop never runs, new tail stays uninitialized,
            // reads random float.
            const from = @min(old_len, count);
            self.pending_min = if (self.pending_min) |m| @min(m, from) else from;
        }
        const min = self.pending_min orelse return;
        if (count == 0) {
            self.pending_min = null;
            return;
        }

        const start_at = @min(min, count);
        var running: f32 = if (start_at == 0)
            self.opts.padding_start
        else
            self.layout[start_at - 1].end() + self.opts.gap;

        var i = start_at;
        while (i < count) : (i += 1) {
            const size = self.sizeOf(i);
            self.layout[i] = .{ .start = running, .size = size };
            running += size + self.opts.gap;
        }
        self.pending_min = null;
    }

    /// y of item's top. when index == count returns total content height (exclude trailing gap).
    pub fn offsetOf(self: *Measurements, index: usize) f32 {
        self.ensureBuilt();
        if (self.opts.count == 0 or self.layout.len == 0) return self.opts.padding_start;
        if (index >= self.layout.len) return self.layout[self.layout.len - 1].end();
        return self.layout[index].start;
    }

    pub fn sizeAt(self: *Measurements, index: usize) f32 {
        self.ensureBuilt();
        if (index >= self.layout.len) return self.estimateOf(index);
        return self.layout[index].size;
    }

    pub fn totalHeight(self: *Measurements) f32 {
        self.ensureBuilt();
        if (self.layout.len == 0) return self.opts.padding_start;
        return self.layout[self.layout.len - 1].end();
    }

    /// binary search: **max index where start <= value**. requires start monotone non-decreasing
    /// (prefix sum naturally satisfies).
    fn findNearest(self: *const Measurements, value: f32) usize {
        var low: usize = 0;
        var high: usize = self.layout.len - 1;
        while (low <= high) {
            const middle = low + (high - low) / 2;
            const current = self.layout[middle].start;
            if (current < value) {
                low = middle + 1;
            } else if (current > value) {
                if (middle == 0) break;
                high = middle - 1;
            } else {
                return middle;
            }
        }
        return if (low > 0) low - 1 else 0;
    }

    /// visible range [start, end) (half-open). overscan externally expanded by caller.
    pub fn range(self: *Measurements, scroll_y: f32, viewport_h: f32) struct { start: usize, end: usize } {
        self.ensureBuilt();
        const count = self.opts.count;
        if (count == 0 or self.layout.len == 0) return .{ .start = 0, .end = 0 };
        // viewport not measured yet: don't assume entire table visible, don't infer 'initialized'
        // from item 0 alone.
        if (!(viewport_h > 0)) return .{ .start = 0, .end = @min(count, 1) };

        const clamped_y = if (std.math.isFinite(scroll_y) and scroll_y > 0) scroll_y else 0;
        const first = self.findNearest(clamped_y);

        // close with forward linear scan (not second binary search): few visible rows, consistent
        // with
        // TanStack semantics, end strictly less than viewport bottom to keep scanning.
        const limit = clamped_y + viewport_h;
        var last = first;
        while (last < count - 1 and self.layout[last].end() < limit) {
            last += 1;
        }
        return .{ .start = first, .end = last + 1 };
    }
};

// ========== test ==========

const testing = std.testing;

fn fixedEstimate(_: usize, _: ?*anyopaque) f32 {
    return 20;
}

test "measurements: estimate-only prefix sums" {
    var m = Measurements.init(testing.allocator, .{ .count = 5, .estimate = 10 });
    defer m.deinit();

    try testing.expectEqual(@as(f32, 50), m.totalHeight());
    try testing.expectEqual(@as(f32, 0), m.offsetOf(0));
    try testing.expectEqual(@as(f32, 30), m.offsetOf(3));
    try testing.expectEqual(@as(f32, 50), m.offsetOf(5)); // == total
}

test "measurements: measured sizes override estimates" {
    var m = Measurements.init(testing.allocator, .{ .count = 4, .estimate = 10 });
    defer m.deinit();

    _ = m.applyMeasurement(1, 40, 0, .idle);
    try testing.expectEqual(@as(f32, 10), m.sizeAt(0));
    try testing.expectEqual(@as(f32, 40), m.sizeAt(1));
    // Item 1 height +30 -> all subsequent starts shift +30.
    try testing.expectEqual(@as(f32, 50), m.offsetOf(2));
    try testing.expectEqual(@as(f32, 70), m.totalHeight());
}

test "measurements: incremental rebuild keeps clean prefix" {
    var m = Measurements.init(testing.allocator, .{ .count = 100, .estimate = 10 });
    defer m.deinit();
    m.ensureBuilt();
    try testing.expectEqual(@as(?usize, null), m.pending_min);

    // Mutate only item 50 -> pending_min must be 50.
    _ = m.applyMeasurement(50, 30, 0, .idle);
    try testing.expectEqual(@as(?usize, 50), m.pending_min);
    m.ensureBuilt();
    try testing.expectEqual(@as(f32, 500), m.offsetOf(50)); // prefix unaffected
    try testing.expectEqual(@as(f32, 530), m.offsetOf(51)); // subsequent items shift

    // Earlier dirty items pull min forward.
    _ = m.applyMeasurement(70, 25, 0, .idle);
    _ = m.applyMeasurement(10, 15, 0, .idle);
    try testing.expectEqual(@as(?usize, 10), m.pending_min);
}

test "measurements: rebuild only touches the dirty suffix" {
    // Incrementality observable; full re-walk could pass all
    // (same values), incremental path becomes dead code.
    //
    // Technique: build table first, secretly modify estimate.
    // Clean prefix retains old values; new estimate after dirty point.
    var m = Measurements.init(testing.allocator, .{ .count = 10, .estimate = 10 });
    defer m.deinit();
    m.ensureBuilt();
    try testing.expectEqual(@as(f32, 100), m.totalHeight());

    // Change estimate but only dirty index 5.
    m.opts.estimate = 20;
    m.markDirty(5);
    m.ensureBuilt();

    // [0,5) is clean prefix: keep values computed with 10.
    try testing.expectEqual(@as(f32, 10), m.layout[0].size);
    try testing.expectEqual(@as(f32, 40), m.layout[4].start);
    // [5,10) recomputed: use new estimate 20.
    try testing.expectEqual(@as(f32, 20), m.layout[5].size);
    try testing.expectEqual(@as(f32, 50), m.layout[5].start);
    // Total height = 5*10 + 5*20 = 150. Full recompute would yield 200, catching 'degradation to
    // full pass'.
    try testing.expectEqual(@as(f32, 150), m.totalHeight());
}

test "measurements: binary search finds row covering scroll offset" {
    var m = Measurements.init(testing.allocator, .{ .count = 10, .estimate = 10 });
    defer m.deinit();
    m.ensureBuilt();

    // Item i spans [10i, 10i+10).
    try testing.expectEqual(@as(usize, 0), m.findNearest(0));
    try testing.expectEqual(@as(usize, 0), m.findNearest(9.9));
    // Falls exactly on item start -> starting item is **this item**, not previous (right-open
    // interval).
    try testing.expectEqual(@as(usize, 3), m.findNearest(30));
    try testing.expectEqual(@as(usize, 3), m.findNearest(35));
    try testing.expectEqual(@as(usize, 9), m.findNearest(9999));
}

test "measurements: range covers viewport with variable heights" {
    var m = Measurements.init(testing.allocator, .{ .count = 6, .estimate = 10 });
    defer m.deinit();
    // Height 10/50/10/10/10/10 -> start 0/10/60/70/80/90
    _ = m.applyMeasurement(1, 50, 0, .idle);

    const r = m.range(0, 60);
    try testing.expectEqual(@as(usize, 0), r.start);
    // Viewport [0,60): items 0 [0,10) and 1 [10,60) visible; item 2 starts at 60, not included.
    try testing.expectEqual(@as(usize, 2), r.end);

    const r2 = m.range(60, 30);
    try testing.expectEqual(@as(usize, 2), r2.start);
    try testing.expect(r2.end >= 4);
}

test "measurements: zero viewport does not claim everything visible" {
    var m = Measurements.init(testing.allocator, .{ .count = 100, .estimate = 10 });
    defer m.deinit();
    const r = m.range(0, 0);
    try testing.expectEqual(@as(usize, 0), r.start);
    try testing.expectEqual(@as(usize, 1), r.end);
}

test "measurements: first measure above fold adjusts scroll" {
    var m = Measurements.init(testing.allocator, .{ .count = 100, .estimate = 10 });
    defer m.deinit();
    m.ensureBuilt();

    // Viewport at y=500. Item 10 (start=100) completely above, first measure height +20 ->
    // compensate +20.
    const out = m.applyMeasurement(10, 30, 500, .idle);
    try testing.expect(out.changed);
    try testing.expectEqual(@as(f32, 20), out.scroll_adjustment);
    try testing.expectEqual(@as(f32, 20), m.pending_adjustment);
}

test "measurements: first measure below fold does not adjust scroll" {
    var m = Measurements.init(testing.allocator, .{ .count = 100, .estimate = 10 });
    defer m.deinit();
    m.ensureBuilt();

    // Item 80 (start=800) below viewport (y=100) -> height change should not move scroll.
    const out = m.applyMeasurement(80, 50, 100, .idle);
    try testing.expect(out.changed);
    try testing.expectEqual(@as(f32, 0), out.scroll_adjustment);
}

test "measurements: re-measure of fold-straddling item does not drag viewport" {
    var m = Measurements.init(testing.allocator, .{ .count = 100, .estimate = 10 });
    defer m.deinit();
    m.ensureBuilt();

    // First measure item 10 -> 100..160 (crosses viewport line 150).
    _ = m.applyMeasurement(10, 60, 0, .idle);
    m.consumeAdjustment();
    m.ensureBuilt();
    try testing.expectEqual(@as(f32, 100), m.offsetOf(10));

    // Re-measure: spans viewport line 150 (100 <= 150 < 160), height increases **below** anchor,
    // compensation would drag viewport down, must not compensate.
    const out = m.applyMeasurement(10, 80, 150, .forward);
    try testing.expect(out.changed);
    try testing.expectEqual(@as(f32, 0), out.scroll_adjustment);
}

test "measurements: re-measure entirely above fold adjusts, but not when scrolling backward" {
    var m = Measurements.init(testing.allocator, .{ .count = 100, .estimate = 10 });
    defer m.deinit();

    _ = m.applyMeasurement(10, 20, 0, .idle);
    m.consumeAdjustment();
    m.ensureBuilt();
    // Item 10 = [100,120), completely above viewport line 500.
    const fwd = m.applyMeasurement(10, 40, 500, .forward);
    try testing.expectEqual(@as(f32, 20), fwd.scroll_adjustment);

    m.consumeAdjustment();
    // Same geometry but scrolling up: suppress compensation to avoid cascading row jitter on upward
    // scroll.
    const back = m.applyMeasurement(10, 60, 500, .backward);
    try testing.expect(back.changed);
    try testing.expectEqual(@as(f32, 0), back.scroll_adjustment);
}

test "measurements: pending_adjustment participates in the anchor comparison" {
    var m = Measurements.init(testing.allocator, .{ .count = 100, .estimate = 10 });
    defer m.deinit();
    m.ensureBuilt();

    // Item 30 = [300,310). At viewport line 295 it is below -> don't compensate.
    const a = m.applyMeasurement(30, 20, 295, .idle);
    try testing.expectEqual(@as(f32, 0), a.scroll_adjustment);

    // But if there is +20 unprocessed compensation, actual anchor is 315 > 300 -> do compensate.
    var m2 = Measurements.init(testing.allocator, .{ .count = 100, .estimate = 10 });
    defer m2.deinit();
    m2.ensureBuilt();
    m2.pending_adjustment = 20;
    const b = m2.applyMeasurement(30, 20, 295, .idle);
    try testing.expectEqual(@as(f32, 10), b.scroll_adjustment);
}

test "measurements: item keys survive prepend" {
    // key_fn maps index to 'data id': after inserting at head, existing data ids unchanged, only
    // indices shift +1. This is why key-domain caching works.
    const Ctx = struct {
        /// Id sequence in data source; index is the subscript of this table.
        var ids: []const u64 = &[_]u64{ 100, 101, 102 };
        fn key(index: usize, _: ?*anyopaque) ItemKey {
            return if (index < ids.len) ids[index] else 0;
        }
    };
    Ctx.ids = &[_]u64{ 100, 101, 102 };

    var m = Measurements.init(testing.allocator, .{
        .count = 3,
        .estimate = 10,
        .key_fn = Ctx.key,
    });
    defer m.deinit();

    // Measured id=100 row height 55 (currently at index 0).
    _ = m.applyMeasurement(0, 55, 0, .idle);
    try testing.expectEqual(@as(f32, 55), m.sizeAt(0));

    // Insert id=99 at head: same data (id=100) now at index 1.
    Ctx.ids = &[_]u64{ 99, 100, 101, 102 };
    m.setCount(4);
    m.ensureBuilt();
    // Measured values follow key, not lost by index shift; this is why prepend is cheap.
    try testing.expectEqual(@as(f32, 55), m.sizeAt(1));
    // Newly inserted rows not yet measured; use estimate.
    try testing.expectEqual(@as(f32, 10), m.sizeAt(0));
}

test "measurements: invalidate returns a row to estimate state" {
    var m = Measurements.init(testing.allocator, .{ .count = 5, .estimate = 10 });
    defer m.deinit();
    _ = m.applyMeasurement(2, 40, 0, .idle);
    try testing.expectEqual(@as(f32, 40), m.sizeAt(2));
    try testing.expect(m.hasMeasurement(2));

    m.invalidate(2);
    try testing.expect(!m.hasMeasurement(2));
    try testing.expectEqual(@as(f32, 10), m.sizeAt(2));
}

test "measurements: count growth keeps existing measurements" {
    var m = Measurements.init(testing.allocator, .{ .count = 3, .estimate = 10 });
    defer m.deinit();
    _ = m.applyMeasurement(1, 30, 0, .idle);
    try testing.expectEqual(@as(f32, 50), m.totalHeight()); // 10+30+10

    m.setCount(6);
    try testing.expectEqual(@as(f32, 80), m.totalHeight()); // +3*10
    try testing.expectEqual(@as(f32, 30), m.sizeAt(1)); // Measured value not lost
}

test "measurements: count shrink does not read stale tail" {
    var m = Measurements.init(testing.allocator, .{ .count = 50, .estimate = 10 });
    defer m.deinit();
    m.ensureBuilt();
    m.setCount(3);
    try testing.expectEqual(@as(f32, 30), m.totalHeight());
    try testing.expectEqual(@as(usize, 3), m.layout.len);
}

test "measurements: non-finite and non-positive measurements are rejected" {
    var m = Measurements.init(testing.allocator, .{ .count = 3, .estimate = 10 });
    defer m.deinit();
    try testing.expect(!m.applyMeasurement(0, 0, 0, .idle).changed);
    try testing.expect(!m.applyMeasurement(0, -5, 0, .idle).changed);
    try testing.expect(!m.applyMeasurement(0, std.math.nan(f32), 0, .idle).changed);
    try testing.expect(!m.applyMeasurement(0, std.math.inf(f32), 0, .idle).changed);
    try testing.expectEqual(@as(f32, 30), m.totalHeight());
}

test "measurements: gap and padding_start shift the prefix sums" {
    var m = Measurements.init(testing.allocator, .{
        .count = 3,
        .estimate = 10,
        .gap = 5,
        .padding_start = 7,
    });
    defer m.deinit();
    try testing.expectEqual(@as(f32, 7), m.offsetOf(0));
    try testing.expectEqual(@as(f32, 22), m.offsetOf(1)); // 7+10+5
    try testing.expectEqual(@as(f32, 37), m.offsetOf(2));
    // Total height excludes trailing gap.
    try testing.expectEqual(@as(f32, 47), m.totalHeight());
}

test "measurements: estimate_fn allows per-index estimates" {
    var m = Measurements.init(testing.allocator, .{ .count = 4, .estimate_fn = fixedEstimate });
    defer m.deinit();
    try testing.expectEqual(@as(f32, 80), m.totalHeight());
    try testing.expectEqual(@as(f32, 40), m.offsetOf(2));
}

test "measurements: repeated identical measurement is a no-op after the first" {
    var m = Measurements.init(testing.allocator, .{ .count = 5, .estimate = 10 });
    defer m.deinit();
    m.ensureBuilt();

    const first = m.applyMeasurement(0, 25, 0, .idle);
    try testing.expect(first.changed);
    m.ensureBuilt();

    // Re-measure same value: should not re-dirty (else full table rebuilds every frame).
    const again = m.applyMeasurement(0, 25, 0, .idle);
    try testing.expect(!again.changed);
    try testing.expectEqual(@as(?usize, null), m.pending_min);
}

test "measurements: unchanged first measurement is still recorded as measured" {
    // When first-measured value equals estimate (delta==0), still must record; else it stays 'not
    // measured', re-measure check (entire above viewport line) never fires.
    var m = Measurements.init(testing.allocator, .{ .count = 5, .estimate = 10 });
    defer m.deinit();
    m.ensureBuilt();
    _ = m.applyMeasurement(0, 10, 0, .idle);
    try testing.expect(m.hasMeasurement(0));
}
