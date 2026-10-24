//! DirtyFlags - packed dirty state replacing the 13 bools + 2 u32 versions on Node.
//!
//! Strict two groups (avoids the Chromium cc::Layer 18-bool chaos):
//! - **input flags**: upstream writes (what changed)
//! - **output flags**: downstream reads (what stage needs redo)
//!
//! A single set must not flip multiple groups; markStyleChanged, markGeometryChanged
//! etc. decide the input->output mapping, not each call point OR-ing bits.
//!
//! Subtree propagation bits are separate (subtree_*), advanced by markSubtree APIs,
//! never OR'd with a 'self' flag in the same call.
//!
//! Capacity: u32 packed (room for future layer phases). Invariants:
//! 1. after clear() all bits are zero (fully clean)
//! 2. union(other) = set union
//! 3. subtree_* always >= * (local dirty => subtree dirty), enforced by promote()
//! 4. every flag has clear semantics; no duplication

const std = @import("std");
const testing = std.testing;

/// input domain: written by components/animations/events etc upstream; downstream must not read
/// these to make decisions.
pub const InputFlags = packed struct(u8) {
    /// self style property changes (color, opacity, transform etc).
    style_changed: bool = false,
    /// self geometry-related style changes (width/height/padding/margin/flex/grid).
    geometry_changed: bool = false,
    /// text content/font changes.
    text_changed: bool = false,
    /// child node topology changes (add/remove/reorder).
    structure_changed: bool = false,
    /// interaction intent changes (hit_test_visible / pointer-events / focus options).
    interaction_changed: bool = false,
    /// hit geometry (rect/path/clip) changes (usually derived from geometry_changed, explicit
    /// setting allowed).
    hit_geometry_changed: bool = false,

    _reserved: u2 = 0,

    pub const NONE: InputFlags = .{};

    pub fn isEmpty(self: InputFlags) bool {
        const v: u8 = @bitCast(self);
        return v == 0;
    }

    pub fn unionWith(self: InputFlags, other: InputFlags) InputFlags {
        const a: u8 = @bitCast(self);
        const b: u8 = @bitCast(other);
        return @bitCast(a | b);
    }
};

/// output domain: render pipeline reads to decide what to do this frame. all false = zero work this
/// frame (fast skip).
pub const OutputFlags = packed struct(u8) {
    /// needs re-layout
    needs_layout: bool = false,
    /// needs re-generate paint chunks (display items)
    needs_paint: bool = false,
    /// needs re-composite (layer transform/opacity update ok, paint may unchanged)
    needs_composite: bool = false,
    /// needs rebuild hit proxies
    needs_hit_rebuild: bool = false,
    /// needs update interaction semantics (focus tree / aria projection)
    needs_interaction_update: bool = false,
    /// runtime indices (z-order/runtime_index) need resorting
    needs_order_update: bool = false,

    _reserved: u2 = 0,

    pub const NONE: OutputFlags = .{};
    pub const ALL: OutputFlags = .{
        .needs_layout = true,
        .needs_paint = true,
        .needs_composite = true,
        .needs_hit_rebuild = true,
        .needs_interaction_update = true,
        .needs_order_update = true,
    };

    pub fn isEmpty(self: OutputFlags) bool {
        const v: u8 = @bitCast(self);
        return v == 0;
    }

    pub fn unionWith(self: OutputFlags, other: OutputFlags) OutputFlags {
        const a: u8 = @bitCast(self);
        const b: u8 = @bitCast(other);
        return @bitCast(a | b);
    }
};

/// subtree dirty bits: ancestor-direction summary of 'me or descendants dirty', avoids subtree
/// scan.
pub const SubtreeFlags = packed struct(u8) {
    has_layout_dirty: bool = false,
    has_paint_dirty: bool = false,
    has_composite_dirty: bool = false,
    has_hit_rebuild: bool = false,
    has_interaction_update: bool = false,
    has_order_update: bool = false,

    _reserved: u2 = 0,

    pub const NONE: SubtreeFlags = .{};

    pub fn isEmpty(self: SubtreeFlags) bool {
        const v: u8 = @bitCast(self);
        return v == 0;
    }

    pub fn unionWith(self: SubtreeFlags, other: SubtreeFlags) SubtreeFlags {
        const a: u8 = @bitCast(self);
        const b: u8 = @bitCast(other);
        return @bitCast(a | b);
    }

    /// project OutputFlags bits to SubtreeFlags (for propagating self dirty upward).
    pub fn fromOutput(out: OutputFlags) SubtreeFlags {
        return .{
            .has_layout_dirty = out.needs_layout,
            .has_paint_dirty = out.needs_paint,
            .has_composite_dirty = out.needs_composite,
            .has_hit_rebuild = out.needs_hit_rebuild,
            .has_interaction_update = out.needs_interaction_update,
            .has_order_update = out.needs_order_update,
        };
    }
};

/// complete dirty flag collection. 32-bit packed = memory efficient; u64 aligned. not inside Node
/// yet, Phase 3 Node split will move alongside LayoutTable/PaintTable.
pub const DirtyFlags = packed struct(u32) {
    input: InputFlags = .{},
    output: OutputFlags = .{},
    subtree: SubtreeFlags = .{},
    /// 8-bit padding for future expansion
    _reserved: u8 = 0,

    pub const NONE: DirtyFlags = .{};

    pub fn isClean(self: DirtyFlags) bool {
        return self.input.isEmpty() and self.output.isEmpty() and self.subtree.isEmpty();
    }

    pub fn clear(self: *DirtyFlags) void {
        self.* = NONE;
    }

    /// clear only this node's output dirty bits (keep subtree, that's subtree state). render
    /// pipeline calls after consuming a stage.
    pub fn clearOutputs(self: *DirtyFlags) void {
        self.output = .{};
    }

    pub fn clearSubtree(self: *DirtyFlags) void {
        self.subtree = .{};
    }
};

/// InputFlags -> OutputFlags projection. determines which upstream changes trigger which downstream
/// stages. **sole** input->output mapping point, no manual output bit OR elsewhere (except
/// scheduler merging subtree dirty summary).
pub fn outputFromInput(in: InputFlags) OutputFlags {
    var out = OutputFlags.NONE;
    if (in.geometry_changed) {
        out.needs_layout = true;
        out.needs_paint = true;
        out.needs_composite = true;
        out.needs_hit_rebuild = true;
    }
    if (in.text_changed) {
        out.needs_layout = true;
        out.needs_paint = true;
    }
    if (in.style_changed) {
        // pure style (like color) only triggers paint; if geometry_changed also set, it already
        // covers above.
        out.needs_paint = true;
    }
    if (in.structure_changed) {
        out.needs_layout = true;
        out.needs_paint = true;
        out.needs_composite = true;
        out.needs_hit_rebuild = true;
        out.needs_order_update = true;
    }
    if (in.interaction_changed) {
        out.needs_interaction_update = true;
    }
    if (in.hit_geometry_changed) {
        out.needs_hit_rebuild = true;
    }
    return out;
}

// ============================================================================
// Tests
// ============================================================================

test "DirtyFlags is exactly 4 bytes (u32 packed)" {
    try testing.expectEqual(@as(usize, 4), @sizeOf(DirtyFlags));
}

test "DirtyFlags NONE is fully clean" {
    const f = DirtyFlags.NONE;
    try testing.expect(f.isClean());
    try testing.expect(f.input.isEmpty());
    try testing.expect(f.output.isEmpty());
    try testing.expect(f.subtree.isEmpty());
}

test "InputFlags union" {
    const a: InputFlags = .{ .style_changed = true };
    const b: InputFlags = .{ .text_changed = true };
    const c = a.unionWith(b);
    try testing.expect(c.style_changed);
    try testing.expect(c.text_changed);
    try testing.expect(!c.geometry_changed);
}

test "outputFromInput: style_changed → paint only" {
    const out = outputFromInput(.{ .style_changed = true });
    try testing.expect(out.needs_paint);
    try testing.expect(!out.needs_layout);
    try testing.expect(!out.needs_composite);
    try testing.expect(!out.needs_hit_rebuild);
}

test "outputFromInput: geometry_changed → layout + paint + composite + hit" {
    const out = outputFromInput(.{ .geometry_changed = true });
    try testing.expect(out.needs_layout);
    try testing.expect(out.needs_paint);
    try testing.expect(out.needs_composite);
    try testing.expect(out.needs_hit_rebuild);
    try testing.expect(!out.needs_interaction_update);
    try testing.expect(!out.needs_order_update);
}

test "outputFromInput: structure_changed → all major + order" {
    const out = outputFromInput(.{ .structure_changed = true });
    try testing.expect(out.needs_layout);
    try testing.expect(out.needs_paint);
    try testing.expect(out.needs_composite);
    try testing.expect(out.needs_hit_rebuild);
    try testing.expect(out.needs_order_update);
}

test "outputFromInput: interaction_changed → interaction only" {
    const out = outputFromInput(.{ .interaction_changed = true });
    try testing.expect(out.needs_interaction_update);
    try testing.expect(!out.needs_layout);
    try testing.expect(!out.needs_paint);
}

test "outputFromInput: combined inputs accumulate outputs" {
    const out = outputFromInput(.{ .style_changed = true, .interaction_changed = true });
    try testing.expect(out.needs_paint);
    try testing.expect(out.needs_interaction_update);
    try testing.expect(!out.needs_layout);
}

test "SubtreeFlags.fromOutput projection" {
    const out: OutputFlags = .{ .needs_paint = true, .needs_composite = true };
    const sub = SubtreeFlags.fromOutput(out);
    try testing.expect(sub.has_paint_dirty);
    try testing.expect(sub.has_composite_dirty);
    try testing.expect(!sub.has_layout_dirty);
}

test "DirtyFlags.clear / clearOutputs / clearSubtree" {
    var f: DirtyFlags = .{
        .input = .{ .style_changed = true },
        .output = .{ .needs_paint = true },
        .subtree = .{ .has_paint_dirty = true },
    };
    try testing.expect(!f.isClean());

    f.clearOutputs();
    try testing.expect(!f.output.needs_paint);
    try testing.expect(f.input.style_changed);
    try testing.expect(f.subtree.has_paint_dirty);

    f.clearSubtree();
    try testing.expect(!f.subtree.has_paint_dirty);

    f.clear();
    try testing.expect(f.isClean());
}

test "OutputFlags ALL has all six bits set" {
    const a = OutputFlags.ALL;
    try testing.expect(a.needs_layout);
    try testing.expect(a.needs_paint);
    try testing.expect(a.needs_composite);
    try testing.expect(a.needs_hit_rebuild);
    try testing.expect(a.needs_interaction_update);
    try testing.expect(a.needs_order_update);
}
