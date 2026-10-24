//! Layout Constraints, Taffy-style LayoutInput / AvailableSpace.
//!
//! A child algorithm receives LayoutInput and returns LayoutOutput; constraints flow
//! parent->child only, with no 'read child size after layout then revise self' extra passes.
//!
//! Design points:
//! 1. AvailableSpace three-state enum (Definite/MinContent/MaxContent) covers CSS constraint
//!    semantics
//! 2. run_mode separates 'measure only' from 'real layout' (cache-friendly intrinsic measurement)
//! 3. known_dimensions lets the parent pass known values so the child avoids recalculation
//!
//! design reference:
//! - Taffy LayoutInput (DioxusLabs/taffy/src/tree/layout.rs)
//! - Flutter BoxConstraints (flutter/lib/src/rendering/box.dart)
//! - CSS 'Available space' / 'Min/Max-content contributions'

const std = @import("std");
const testing = std.testing;

/// available space on one axis. CSS spec § 'available space'.
pub const AvailableSpace = union(enum) {
    /// definite floating-point pixel value
    definite: f32,
    /// 'min-content': minimum content need (each child gets own min-content)
    min_content,
    /// 'max-content': content preference (each child gets own max-content)
    max_content,

    pub fn isDefinite(self: AvailableSpace) bool {
        return self == .definite;
    }

    /// extract definite value; non-definite returns fallback
    pub fn definiteOr(self: AvailableSpace, fallback: f32) f32 {
        return switch (self) {
            .definite => |v| v,
            else => fallback,
        };
    }

    /// new AvailableSpace after subtracting definite value (child padding/margin deduction)
    pub fn subtractDefinite(self: AvailableSpace, x: f32) AvailableSpace {
        return switch (self) {
            .definite => |v| .{ .definite = @max(0, v - x) },
            else => self,
        };
    }

    /// take min with max, definite; non-definite unchanged
    pub fn clampMax(self: AvailableSpace, max: f32) AvailableSpace {
        return switch (self) {
            .definite => |v| .{ .definite = @min(v, max) },
            else => self,
        };
    }
};

/// 2D vector (uncoupled from current types.Size / Point, avoid circular import)
pub const Vec2 = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub const ZERO: Vec2 = .{};

    pub fn eq(a: Vec2, b: Vec2) bool {
        return a.x == b.x and a.y == b.y;
    }
};

pub const Size2D = struct {
    width: f32 = 0,
    height: f32 = 0,

    pub const ZERO: Size2D = .{};

    pub fn add(a: Size2D, b: Size2D) Size2D {
        return .{ .width = a.width + b.width, .height = a.height + b.height };
    }
};

/// 2D AvailableSpace
pub const AvailableSpaceXY = struct {
    width: AvailableSpace,
    height: AvailableSpace,

    pub fn definite(w: f32, h: f32) AvailableSpaceXY {
        return .{ .width = .{ .definite = w }, .height = .{ .definite = h } };
    }

    pub fn maxContent() AvailableSpaceXY {
        return .{ .width = .max_content, .height = .max_content };
    }
};

/// known dimensions (parent-determined child size; child doesn't recalculate self). null = unknown.
pub const KnownDimensions = struct {
    width: ?f32 = null,
    height: ?f32 = null,

    pub const NONE: KnownDimensions = .{};
};

/// run_mode = layout child-algorithm run mode
/// - perform_layout: full layout, write final_rect, bubble subtree
/// - measure: only measure return size; don't write persistent layout result (for intrinsic probe)
pub const RunMode = enum(u8) {
    perform_layout,
    measure,
};

/// parent->child layout input.
pub const LayoutInput = struct {
    /// how much space can parent give me (per axis one AvailableSpace)
    available_space: AvailableSpaceXY,
    /// parent already determined size for me (I don't decide, use directly)
    known_dimensions: KnownDimensions = .{},
    /// parent's own size (for percentage resolution)
    parent_size: Size2D = .{},
    /// primary-axis direction (flex/grid child algorithm use)
    /// 0 = horizontal/row, 1 = vertical/column
    axis: u2 = 0,
    /// run mode
    run_mode: RunMode = .perform_layout,

    pub fn forMeasure(available: AvailableSpaceXY) LayoutInput {
        return .{ .available_space = available, .run_mode = .measure };
    }
};

/// child->parent layout output.
pub const LayoutOutput = struct {
    /// measured content size (no outer margin)
    size: Size2D,
    /// first-line baseline distance from size.height's y offset; null = no baseline concept
    first_baseline: ?f32 = null,
    /// last-line baseline; for align-items: last baseline
    last_baseline: ?f32 = null,

    pub const ZERO: LayoutOutput = .{ .size = Size2D.ZERO };
};

/// Intrinsic size cache, same node same input measure reuses result. simple 4-entry direct-mapped
/// cache (cache-line friendly; lookup O(1)). Phase 3 unpacking Node hung by LayoutTable side.
pub const IntrinsicCache = struct {
    pub const ENTRY_COUNT: usize = 4;

    const Entry = struct {
        valid: bool = false,
        input_hash: u64 = 0,
        output: LayoutOutput = .ZERO,
    };

    entries: [ENTRY_COUNT]Entry = @as([ENTRY_COUNT]Entry, @splat(.{})),

    pub fn get(self: *const IntrinsicCache, input_hash: u64) ?LayoutOutput {
        const slot = @as(usize, input_hash) % ENTRY_COUNT;
        const e = self.entries[slot];
        if (e.valid and e.input_hash == input_hash) return e.output;
        return null;
    }

    pub fn put(self: *IntrinsicCache, input_hash: u64, output: LayoutOutput) void {
        const slot = @as(usize, input_hash) % ENTRY_COUNT;
        self.entries[slot] = .{
            .valid = true,
            .input_hash = input_hash,
            .output = output,
        };
    }

    pub fn invalidate(self: *IntrinsicCache) void {
        for (&self.entries) |*e| e.valid = false;
    }
};

/// compute LayoutInput stable hash, used for intrinsic cache index.
pub fn hashLayoutInput(input: LayoutInput) u64 {
    var hasher = std.hash.Wyhash.init(0xCAFEBABE);
    hashAvailable(&hasher, input.available_space.width);
    hashAvailable(&hasher, input.available_space.height);
    hashOptF32(&hasher, input.known_dimensions.width);
    hashOptF32(&hasher, input.known_dimensions.height);
    hasher.update(std.mem.asBytes(&input.parent_size.width));
    hasher.update(std.mem.asBytes(&input.parent_size.height));
    hasher.update(&[_]u8{ input.axis, @backingInt(input.run_mode) });
    return hasher.final();
}

fn hashAvailable(h: *std.hash.Wyhash, a: AvailableSpace) void {
    switch (a) {
        .definite => |v| {
            h.update(&[_]u8{0});
            h.update(std.mem.asBytes(&v));
        },
        .min_content => h.update(&[_]u8{1}),
        .max_content => h.update(&[_]u8{2}),
    }
}

fn hashOptF32(h: *std.hash.Wyhash, x: ?f32) void {
    if (x) |v| {
        h.update(&[_]u8{1});
        h.update(std.mem.asBytes(&v));
    } else {
        h.update(&[_]u8{0});
    }
}

// ============================================================================
// Tests
// ============================================================================

test "AvailableSpace: definite operations" {
    const a: AvailableSpace = .{ .definite = 100 };
    try testing.expect(a.isDefinite());
    try testing.expectEqual(@as(f32, 100), a.definiteOr(0));

    const b = a.subtractDefinite(30);
    try testing.expectEqual(AvailableSpace{ .definite = 70 }, b);

    const c = a.clampMax(50);
    try testing.expectEqual(AvailableSpace{ .definite = 50 }, c);

    const d = a.subtractDefinite(200);
    try testing.expectEqual(AvailableSpace{ .definite = 0 }, d); // clamp to 0
}

test "AvailableSpace: indefinite operations are no-op" {
    const mc: AvailableSpace = .min_content;
    try testing.expect(!mc.isDefinite());
    try testing.expectEqual(@as(f32, 99), mc.definiteOr(99));

    const after_sub = mc.subtractDefinite(10);
    try testing.expectEqual(AvailableSpace.min_content, after_sub);
}

test "AvailableSpaceXY: constructors" {
    const a = AvailableSpaceXY.definite(100, 200);
    try testing.expectEqual(AvailableSpace{ .definite = 100 }, a.width);
    try testing.expectEqual(AvailableSpace{ .definite = 200 }, a.height);

    const m = AvailableSpaceXY.maxContent();
    try testing.expectEqual(AvailableSpace.max_content, m.width);
}

test "LayoutInput: forMeasure shortcut" {
    const i = LayoutInput.forMeasure(AvailableSpaceXY.maxContent());
    try testing.expectEqual(RunMode.measure, i.run_mode);
}

test "hashLayoutInput: same input → same hash" {
    const a = LayoutInput{
        .available_space = AvailableSpaceXY.definite(100, 200),
        .parent_size = .{ .width = 800, .height = 600 },
    };
    const b = LayoutInput{
        .available_space = AvailableSpaceXY.definite(100, 200),
        .parent_size = .{ .width = 800, .height = 600 },
    };
    try testing.expectEqual(hashLayoutInput(a), hashLayoutInput(b));
}

test "hashLayoutInput: different input → different hash" {
    const a = LayoutInput{ .available_space = AvailableSpaceXY.definite(100, 200) };
    const b = LayoutInput{ .available_space = AvailableSpaceXY.definite(101, 200) };
    try testing.expect(hashLayoutInput(a) != hashLayoutInput(b));
}

test "IntrinsicCache: get/put/invalidate" {
    var cache = IntrinsicCache{};
    const out = LayoutOutput{ .size = .{ .width = 100, .height = 50 } };

    try testing.expect(cache.get(0xDEADBEEF) == null);

    cache.put(0xDEADBEEF, out);
    const got = cache.get(0xDEADBEEF).?;
    try testing.expectEqual(@as(f32, 100), got.size.width);

    cache.invalidate();
    try testing.expect(cache.get(0xDEADBEEF) == null);
}

test "IntrinsicCache: collision overwrites slot" {
    var cache = IntrinsicCache{};
    const out_a = LayoutOutput{ .size = .{ .width = 100, .height = 50 } };
    const out_b = LayoutOutput{ .size = .{ .width = 200, .height = 60 } };

    // two hash mod ENTRY_COUNT equal -> latter overwrites
    cache.put(0, out_a);
    cache.put(IntrinsicCache.ENTRY_COUNT, out_b);

    try testing.expect(cache.get(0) == null); // overwrite
    const got = cache.get(IntrinsicCache.ENTRY_COUNT).?;
    try testing.expectEqual(@as(f32, 200), got.size.width);
}
