//! ShapingCache: (text_hash, font, width) -> cached GlyphRun.
//!
//! TextShaper.shape() on CoreText costs ~10-100us; reshaping identical text is waste. Key is
//! (content_hash, font_id, max_width). Target hit rate >95%. Reference: HarfBuzz hb_shape_plan_t
//! cache.
//!
//! Pitfalls:
//! - Entry slices have one owner; eviction/replacement releases that owner. Borrows
//!   must be consumed before a cache mutation that can evict their entry.
//! - **do not** set a small hard capacity; default 4096 entries + LRU eviction
//! - **do not** key on `[]const u8` (ptr unstable); key on hash + length, caller passes original to
//!   verify

const std = @import("std");
const testing = std.testing;
const glyph_run = @import("glyph_run.zig");
const text_coordinates = @import("text_core").text_coordinates;

pub const GlyphRun = glyph_run.GlyphRun;
pub const GlyphPosition = glyph_run.GlyphPosition;
pub const Cluster = glyph_run.Cluster;
pub const FontMetrics = glyph_run.FontMetrics;

/// Shaping cache key
pub const ShapingKey = struct {
    /// Source hash (caller generates using std.hash.Wyhash or similar)
    text_hash: u64,
    /// Text length (prevents hash collision + size estimation)
    text_len: u32,
    /// Font id (zenit FontSystem internal id; 0 = default)
    font_id: u32,
    /// max_width (used for line break; 0 = single line no wrap)
    max_width: f32,
    /// Font size
    font_size: f32,

    pub fn hash(self: ShapingKey) u64 {
        var h = std.hash.Wyhash.init(0xDEADBEEFCAFEBABE);
        h.update(std.mem.asBytes(&self.text_hash));
        h.update(std.mem.asBytes(&self.text_len));
        h.update(std.mem.asBytes(&self.font_id));
        h.update(std.mem.asBytes(&self.max_width));
        h.update(std.mem.asBytes(&self.font_size));
        return h.final();
    }

    pub fn eq(a: ShapingKey, b: ShapingKey) bool {
        return a.text_hash == b.text_hash and
            a.text_len == b.text_len and
            a.font_id == b.font_id and
            a.max_width == b.max_width and
            a.font_size == b.font_size;
    }
};

/// Cache entry, owned glyph + cluster slices
pub const Entry = struct {
    key: ShapingKey,
    /// Entry-owned glyph sequence
    glyphs: []GlyphPosition,
    /// Entry-owned cluster sequence
    clusters: []Cluster,
    metrics: FontMetrics,
    direction: glyph_run.Direction,
    total_advance: f32,
    /// LRU timestamp: most recently used frame index
    last_used_frame: u64,

    pub fn toRun(self: Entry) GlyphRun {
        return .{
            .glyphs = self.glyphs,
            .clusters = self.clusters,
            .metrics = self.metrics,
            .direction = self.direction,
            .total_advance = self.total_advance,
        };
    }
};

pub const ShapingCacheStats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
    pub fn hitRate(self: ShapingCacheStats) f64 {
        const total = self.hits + self.misses;
        if (total == 0) return 0;
        return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
    }
};

const KeyContext = struct {
    pub fn hash(_: KeyContext, k: ShapingKey) u64 {
        return k.hash();
    }
    pub fn eql(_: KeyContext, a: ShapingKey, b: ShapingKey) bool {
        return ShapingKey.eq(a, b);
    }
};

const VisualEntry = struct {
    caret_stops: []text_coordinates.CaretStop,
    width: f32,
    ascent: f32,
    descent: f32,
    leading: f32,
    base_direction: text_coordinates.Direction,
    last_used_frame: u64,

    fn toLine(self: VisualEntry, text_len: usize) text_coordinates.VisualLine {
        return .{
            .source_start = .{ .value = 0 },
            .source_end = .{ .value = text_len },
            .caret_stops = self.caret_stops,
            .width = self.width,
            .ascent = self.ascent,
            .descent = self.descent,
            .leading = self.leading,
            .base_direction = self.base_direction,
        };
    }
};

pub const ShapingCache = struct {
    allocator: std.mem.Allocator,
    /// Payload byte ceiling; map metadata is separately bounded by entry capacity.
    max_payload_bytes: usize = 32 * 1024 * 1024,
    /// HashMap key -> entry index
    map: std.HashMapUnmanaged(ShapingKey, Entry, KeyContext, 80),
    visual_map: std.HashMapUnmanaged(ShapingKey, VisualEntry, KeyContext, 80),
    capacity: u32,
    current_frame: u64 = 0,
    stats: ShapingCacheStats = .{},
    live_payload_bytes: usize = 0,
    peak_payload_bytes: usize = 0,

    pub fn init(parent_allocator: std.mem.Allocator, capacity: u32) ShapingCache {
        return .{
            .allocator = parent_allocator,
            .map = .{},
            .visual_map = .{},
            .capacity = @max(capacity, 1),
        };
    }

    pub fn deinit(self: *ShapingCache) void {
        var entries = self.map.valueIterator();
        while (entries.next()) |entry| self.freeEntry(entry.*);
        var visuals = self.visual_map.valueIterator();
        while (visuals.next()) |entry| self.freeVisual(entry.*);
        self.map.deinit(self.allocator);
        self.visual_map.deinit(self.allocator);
        std.debug.assert(self.live_payload_bytes == 0);
        self.* = undefined;
    }

    pub fn beginFrame(self: *ShapingCache) void {
        self.current_frame +%= 1;
    }

    /// Query cache. Hit -> return GlyphRun + bump last_used_frame; miss -> null.
    pub fn lookup(self: *ShapingCache, key: ShapingKey) ?GlyphRun {
        if (self.map.getPtr(key)) |entry| {
            entry.last_used_frame = self.current_frame;
            self.stats.hits += 1;
            return entry.toRun();
        }
        self.stats.misses += 1;
        return null;
    }

    pub fn lookupVisual(self: *ShapingCache, key: ShapingKey) ?text_coordinates.VisualLine {
        if (self.visual_map.getPtr(key)) |entry| {
            entry.last_used_frame = self.current_frame;
            return entry.toLine(key.text_len);
        }
        return null;
    }

    pub fn insertVisual(self: *ShapingCache, key: ShapingKey, line: text_coordinates.VisualLine) !void {
        const bytes = std.math.mul(usize, line.caret_stops.len, @sizeOf(text_coordinates.CaretStop)) catch return error.OutOfMemory;
        if (bytes > self.max_payload_bytes) return error.OutOfMemory;
        const owned = try self.allocator.dupe(text_coordinates.CaretStop, line.caret_stops);
        errdefer self.allocator.free(owned);
        // All fallible work precedes replacement or eviction. Borrowed input may
        // even be the old entry's slice; it is already copied before freeing it.
        try self.visual_map.ensureUnusedCapacity(self.allocator, 1);
        if (self.visual_map.fetchRemove(key)) |old| self.freeVisual(old.value);
        if (self.visual_map.count() >= self.capacity) self.evictOldestVisual();
        self.makeRoom(bytes);
        self.visual_map.putAssumeCapacity(key, .{
            .caret_stops = owned,
            .width = line.width,
            .ascent = line.ascent,
            .descent = line.descent,
            .leading = line.leading,
            .base_direction = line.base_direction,
            .last_used_frame = self.current_frame,
        });
        self.live_payload_bytes += bytes;
        self.peak_payload_bytes = @max(self.peak_payload_bytes, self.live_payload_bytes);
    }

    /// Copies caller slices; a failed insert keeps all old entries and borrows valid.
    pub fn insert(
        self: *ShapingCache,
        key: ShapingKey,
        glyphs: []const GlyphPosition,
        clusters: []const Cluster,
        metrics: FontMetrics,
        direction: glyph_run.Direction,
        total_advance: f32,
    ) !void {
        const gb = std.math.mul(usize, glyphs.len, @sizeOf(GlyphPosition)) catch return error.OutOfMemory;
        const cb = std.math.mul(usize, clusters.len, @sizeOf(Cluster)) catch return error.OutOfMemory;
        const bytes = std.math.add(usize, gb, cb) catch return error.OutOfMemory;
        if (bytes > self.max_payload_bytes) return error.OutOfMemory;
        const owned_glyphs = try self.allocator.dupe(GlyphPosition, glyphs);
        errdefer self.allocator.free(owned_glyphs);
        const owned_clusters = try self.allocator.dupe(Cluster, clusters);
        errdefer self.allocator.free(owned_clusters);
        try self.map.ensureUnusedCapacity(self.allocator, 1);
        if (self.map.fetchRemove(key)) |old| self.freeEntry(old.value);
        if (self.map.count() >= self.capacity) self.evictBatch();
        self.makeRoom(bytes);
        self.map.putAssumeCapacity(key, .{
            .key = key,
            .glyphs = owned_glyphs,
            .clusters = owned_clusters,
            .metrics = metrics,
            .direction = direction,
            .total_advance = total_advance,
            .last_used_frame = self.current_frame,
        });
        self.live_payload_bytes += bytes;
        self.peak_payload_bytes = @max(self.peak_payload_bytes, self.live_payload_bytes);
    }

    fn entryBytes(entry: Entry) usize {
        return entry.glyphs.len * @sizeOf(GlyphPosition) + entry.clusters.len * @sizeOf(Cluster);
    }
    fn freeEntry(self: *ShapingCache, entry: Entry) void {
        self.live_payload_bytes -= entryBytes(entry);
        self.allocator.free(entry.glyphs);
        self.allocator.free(entry.clusters);
    }
    fn freeVisual(self: *ShapingCache, entry: VisualEntry) void {
        self.live_payload_bytes -= entry.caret_stops.len * @sizeOf(text_coordinates.CaretStop);
        self.allocator.free(entry.caret_stops);
    }
    fn evictOldestVisual(self: *ShapingCache) void {
        var key: ?ShapingKey = null;
        var frame: u64 = std.math.maxInt(u64);
        var it = self.visual_map.iterator();
        while (it.next()) |kv| if (key == null or kv.value_ptr.last_used_frame < frame) {
            key = kv.key_ptr.*;
            frame = kv.value_ptr.last_used_frame;
        };
        if (key) |k| {
            self.freeVisual(self.visual_map.fetchRemove(k).?.value);
            self.stats.evictions += 1;
        }
    }
    fn makeRoom(self: *ShapingCache, incoming: usize) void {
        while (self.live_payload_bytes > self.max_payload_bytes - incoming) {
            var key: ?ShapingKey = null;
            var frame: u64 = std.math.maxInt(u64);
            var it = self.map.iterator();
            while (it.next()) |kv| if (key == null or kv.value_ptr.last_used_frame < frame) {
                key = kv.key_ptr.*;
                frame = kv.value_ptr.last_used_frame;
            };
            var visual_frame: u64 = std.math.maxInt(u64);
            var vi = self.visual_map.valueIterator();
            while (vi.next()) |v| visual_frame = @min(visual_frame, v.last_used_frame);
            if (key != null and (self.visual_map.count() == 0 or frame <= visual_frame)) {
                self.freeEntry(self.map.fetchRemove(key.?).?.value);
                self.stats.evictions += 1;
            } else self.evictOldestVisual();
        }
    }

    /// Entries unused for more than this frame count are stale; batch eviction prioritizes clearing
    /// them.
    const STALE_FRAMES: u64 = 120;
    /// Preserve the existing age/quarter-batch policy, now releasing every payload.
    fn evictBatch(self: *ShapingCache) void {
        if (self.map.count() == 0) return;

        const target: u64 = @max(self.capacity / 4, 1);
        // Progressively tighten age threshold: scan all, batch removeByPtr (remove no rehash;
        // deletion during iteration is std.HashMap-supported). First clear STALE_FRAMES unused.
        // If insufficient, halve threshold and rescan; worst O(log(STALE_FRAMES)) rounds until
        // cutoff
        // = current frame, guaranteed to free enough target.
        var age_threshold: u64 = STALE_FRAMES;
        var removed: u64 = 0;
        while (removed < target) {
            const cutoff = self.current_frame -| age_threshold;
            var iter = self.map.iterator();
            while (iter.next()) |kv| {
                if (kv.value_ptr.last_used_frame <= cutoff) {
                    self.freeEntry(kv.value_ptr.*);
                    self.map.removeByPtr(kv.key_ptr);
                    removed += 1;
                }
            }
            if (removed >= target or age_threshold == 0) break;
            age_threshold /= 2;
        }
        self.stats.evictions += removed;
    }

    pub const MemoryStats = struct {
        arena_capacity_bytes: usize,
        arena_used_bytes: usize,
        arena_requested_bytes: usize,
        live_payload_bytes: usize,
        peak_payload_bytes: usize,
        payload_budget_bytes: usize,
        entries: usize,
        visual_entries: usize,
        hits: u64,
        misses: u64,
        evictions: u64,
    };
    /// Entry-owned requested payload; map metadata is reported separately by
    /// subsystem allocation probes. Arena compatibility counters are always zero.
    pub fn memoryStats(self: *const ShapingCache) MemoryStats {
        return .{
            // Compatibility fields intentionally become zero after arena removal.
            .arena_capacity_bytes = 0,
            .arena_used_bytes = 0,
            .arena_requested_bytes = 0,
            .live_payload_bytes = self.live_payload_bytes,
            .peak_payload_bytes = self.peak_payload_bytes,
            .payload_budget_bytes = self.max_payload_bytes,
            .entries = self.map.count(),
            .visual_entries = self.visual_map.count(),
            .hits = self.stats.hits,
            .misses = self.stats.misses,
            .evictions = self.stats.evictions,
        };
    }

    pub fn count(self: *const ShapingCache) u32 {
        return @intCast(self.map.count());
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ShapingKey eq + hash stable" {
    const a = ShapingKey{ .text_hash = 0xCAFE, .text_len = 5, .font_id = 1, .max_width = 200, .font_size = 14 };
    const b = ShapingKey{ .text_hash = 0xCAFE, .text_len = 5, .font_id = 1, .max_width = 200, .font_size = 14 };
    try testing.expect(ShapingKey.eq(a, b));
    try testing.expectEqual(a.hash(), b.hash());
}

test "ShapingKey different params → different hash" {
    const a = ShapingKey{ .text_hash = 1, .text_len = 5, .font_id = 1, .max_width = 200, .font_size = 14 };
    const b = ShapingKey{ .text_hash = 1, .text_len = 5, .font_id = 1, .max_width = 200, .font_size = 16 };
    try testing.expect(!ShapingKey.eq(a, b));
}

test "ShapingCache: insert + lookup hit" {
    var cache = ShapingCache.init(testing.allocator, 16);
    defer cache.deinit();

    const key = ShapingKey{ .text_hash = 0x1, .text_len = 5, .font_id = 0, .max_width = 0, .font_size = 14 };
    const glyphs = [_]GlyphPosition{
        .{ .glyph_id = 1, .x_advance = 10 },
    };
    const clusters = [_]Cluster{
        .{ .byte_offset = 0, .glyph_start = 0, .glyph_end = 1 },
    };
    const metrics = FontMetrics{ .ascent = 12, .descent = 4, .line_gap = 0, .font_size = 14 };

    try cache.insert(key, &glyphs, &clusters, metrics, .ltr, 10);

    const got = cache.lookup(key);
    try testing.expect(got != null);
    try testing.expectEqual(@as(usize, 1), got.?.glyphs.len);
    try testing.expectEqual(@as(f32, 10), got.?.total_advance);
    try testing.expectEqual(@as(u64, 1), cache.stats.hits);
    try testing.expectEqual(@as(u64, 0), cache.stats.misses);
}

test "ShapingCache: lookup miss" {
    var cache = ShapingCache.init(testing.allocator, 16);
    defer cache.deinit();

    const key = ShapingKey{ .text_hash = 0x1, .text_len = 5, .font_id = 0, .max_width = 0, .font_size = 14 };
    try testing.expect(cache.lookup(key) == null);
    try testing.expectEqual(@as(u64, 1), cache.stats.misses);
}

test "ShapingCache: batch eviction keeps recently-used, drops stale" {
    var cache = ShapingCache.init(testing.allocator, 4);
    defer cache.deinit();

    const empty_glyphs: []const GlyphPosition = &.{};
    const empty_clusters: []const Cluster = &.{};
    const m = FontMetrics{ .ascent = 0, .descent = 0, .line_gap = 0, .font_size = 14 };
    const k1 = ShapingKey{ .text_hash = 1, .text_len = 0, .font_id = 0, .max_width = 0, .font_size = 14 };
    const k2 = ShapingKey{ .text_hash = 2, .text_len = 0, .font_id = 0, .max_width = 0, .font_size = 14 };
    const k3 = ShapingKey{ .text_hash = 3, .text_len = 0, .font_id = 0, .max_width = 0, .font_size = 14 };
    const k4 = ShapingKey{ .text_hash = 4, .text_len = 0, .font_id = 0, .max_width = 0, .font_size = 14 };
    const k5 = ShapingKey{ .text_hash = 5, .text_len = 0, .font_id = 0, .max_width = 0, .font_size = 14 };

    cache.beginFrame();
    try cache.insert(k1, empty_glyphs, empty_clusters, m, .ltr, 0);
    try cache.insert(k2, empty_glyphs, empty_clusters, m, .ltr, 0);
    try cache.insert(k3, empty_glyphs, empty_clusters, m, .ltr, 0);
    try cache.insert(k4, empty_glyphs, empty_clusters, m, .ltr, 0);
    try testing.expectEqual(@as(u32, 4), cache.count());

    // Advance 200 frames; k1 continuously used, rest become stale.
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        cache.beginFrame();
        _ = cache.lookup(k1);
    }

    // Capacity full; insert k5 triggers batch eviction, stale k2/k3/k4 cleared, k1 survives.
    try cache.insert(k5, empty_glyphs, empty_clusters, m, .ltr, 0);
    try testing.expect(cache.lookup(k1) != null);
    try testing.expect(cache.lookup(k2) == null);
    try testing.expect(cache.lookup(k3) == null);
    try testing.expect(cache.lookup(k4) == null);
    try testing.expect(cache.lookup(k5) != null);
    try testing.expect(cache.stats.evictions >= 3);
}

test "ShapingCache: hit rate calculation" {
    var stats = ShapingCacheStats{ .hits = 95, .misses = 5 };
    try testing.expectApproxEqAbs(@as(f64, 0.95), stats.hitRate(), 0.001);
}

test "ShapingCache: stats hits + misses tracked" {
    var cache = ShapingCache.init(testing.allocator, 16);
    defer cache.deinit();

    const key = ShapingKey{ .text_hash = 1, .text_len = 5, .font_id = 0, .max_width = 0, .font_size = 14 };
    _ = cache.lookup(key); // miss
    _ = cache.lookup(key); // miss
    try cache.insert(key, &.{}, &.{}, .{ .ascent = 0, .descent = 0, .line_gap = 0, .font_size = 14 }, .ltr, 0);
    _ = cache.lookup(key); // hit
    _ = cache.lookup(key); // hit
    _ = cache.lookup(key); // hit

    try testing.expectEqual(@as(u64, 3), cache.stats.hits);
    try testing.expectEqual(@as(u64, 2), cache.stats.misses);
    try testing.expectApproxEqAbs(@as(f64, 0.6), cache.stats.hitRate(), 0.001);
}

test "ShapingCache: CPU pressure ownership ledger" {
    var cache = ShapingCache.init(testing.allocator, 1024);
    defer cache.deinit();
    const glyphs: [16]GlyphPosition = @splat(.{ .glyph_id = 1, .x_advance = 10 });
    const clusters: [16]Cluster = @splat(.{ .byte_offset = 0, .glyph_start = 0, .glyph_end = 1 });
    for (0..20_000) |i| {
        cache.beginFrame();
        try cache.insert(.{ .text_hash = i, .text_len = 16, .font_id = 0, .max_width = 0, .font_size = 14 }, &glyphs, &clusters, .{ .ascent = 0, .descent = 0, .line_gap = 0, .font_size = 14 }, .ltr, 160);
    }
    const s = cache.memoryStats();
    std.debug.print("CPU_SHAPING_PRESSURE capacity={d} used={d} live={d} entries={d} evictions={d}\n", .{ s.arena_capacity_bytes, s.arena_used_bytes, s.live_payload_bytes, s.entries, s.evictions });
    try testing.expect(s.evictions > 0);
    try testing.expectEqual(@as(usize, 0), s.arena_capacity_bytes);
    try testing.expect(s.live_payload_bytes <= 1024 * 16 * (@sizeOf(GlyphPosition) + @sizeOf(Cluster)));
}

fn checkShapingOwnershipOom(allocator: std.mem.Allocator) !void {
    var cache = ShapingCache.init(allocator, 1);
    defer cache.deinit();
    const key = ShapingKey{ .text_hash = 1, .text_len = 1, .font_id = 0, .max_width = 0, .font_size = 14 };
    const g = [_]GlyphPosition{.{ .glyph_id = 1, .x_advance = 10 }};
    const c = [_]Cluster{.{ .byte_offset = 0, .glyph_start = 0, .glyph_end = 1 }};
    const m = FontMetrics{ .ascent = 0, .descent = 0, .line_gap = 0, .font_size = 14 };
    try cache.insert(key, &g, &c, m, .ltr, 10);
    const old = cache.lookup(key).?;
    var next = key;
    next.text_hash = 2;
    cache.insert(next, &g, &c, m, .ltr, 20) catch |err| {
        try testing.expectEqual(@intFromPtr(old.glyphs.ptr), @intFromPtr(cache.lookup(key).?.glyphs.ptr));
        try testing.expectEqual(@as(f32, 10), cache.lookup(key).?.total_advance);
        return err;
    };
    const stops = [_]text_coordinates.CaretStop{.{ .position = .{ .byte = .{ .value = 0 } }, .x = .{ .value = 0 }, .strong_direction = .ltr }};
    const line = text_coordinates.VisualLine{ .source_start = .{ .value = 0 }, .source_end = .{ .value = 1 }, .caret_stops = &stops, .width = 10 };
    try cache.insertVisual(key, line);
    const visual = cache.lookupVisual(key).?;
    var replacement = visual;
    replacement.width = 20;
    cache.insertVisual(key, replacement) catch |err| {
        try testing.expectEqual(@intFromPtr(visual.caret_stops.ptr), @intFromPtr(cache.lookupVisual(key).?.caret_stops.ptr));
        try testing.expectEqual(@as(f32, 10), cache.lookupVisual(key).?.width);
        return err;
    };
    try testing.expectEqual(@as(f32, 20), cache.lookupVisual(key).?.width);
}

test "ShapingCache: owned payload replacement and eviction exhaustively roll back OOM" {
    try testing.checkAllAllocationFailures(testing.allocator, checkShapingOwnershipOom, .{});
}

test "ShapingCache: byte pressure bounds payload without reducing entry capacity" {
    var counter = @import("counting_allocator.zig").CountingAllocator{ .parent = testing.allocator };
    var cache = ShapingCache.init(counter.allocator(), 128);
    const g = [_]GlyphPosition{.{ .glyph_id = 1, .x_advance = 10 }};
    const c = [_]Cluster{.{ .byte_offset = 0, .glyph_start = 0, .glyph_end = 1 }};
    const m = FontMetrics{ .ascent = 0, .descent = 0, .line_gap = 0, .font_size = 14 };
    cache.max_payload_bytes = 2 * (@sizeOf(GlyphPosition) + @sizeOf(Cluster));
    for (0..100) |i| {
        cache.beginFrame();
        const key = ShapingKey{ .text_hash = i, .text_len = 1, .font_id = 0, .max_width = 0, .font_size = 14 };
        try cache.insert(key, &g, &c, m, .ltr, 10);
        try testing.expect(cache.live_payload_bytes <= cache.max_payload_bytes);
        try testing.expectEqual(@as(u32, 128), cache.capacity);
        try testing.expect(cache.lookup(key) != null);
    }
    try testing.expectEqual(@as(u32, 2), cache.count());
    cache.deinit();
    try testing.expectEqual(@as(usize, 0), counter.live_bytes);
}
