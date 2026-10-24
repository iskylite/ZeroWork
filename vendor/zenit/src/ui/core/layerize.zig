//! Layerization: groups PaintChunks into a LayerTree.
//!
//! Replaces compositor_plan.zig's per-frame O(N*M) linear scan. Follows Chromium
//! PaintArtifactCompositor::LayerizeGroup:
//!
//! 1. traverse by element order (matches paint order)
//! 2. for each element check whether it needs 'promotion' to an independent layer:
//!    - during transform animation -> promote
//!    - during opacity animation and 0 < alpha < 1 -> promote
//!    - overflow: scroll/auto -> promote (enables layer-transform scrolling)
//!    - will-change: transform | opacity -> promote
//! 3. no promotion needed -> add to the 'current group' (keep merging into parent layer)
//! 4. when a group forms a new layer:
//!    - area < min_layer_area_px2: merge back to parent
//!    - layer count at limit: merge back to parent
//!
//! Pitfalls:
//! - **do not** run layerization every frame, only when element topology/style/
//!   promotion-reason changes; reuse the layer tree otherwise (PropertyTree epoch hit)
//! - **do not** make one layer per chunk
//! - **do not** statically promote transform/opacity (no benefit without animation)
//!
//! Input: World (ElementTable / PaintTable / PropertyTree); PromotionHints (set by
//! reactive/animation). Output: LayerTree write.

const std = @import("std");
const testing = std.testing;
const element_id_mod = @import("element_id.zig");
const layer_tree_mod = @import("layer_tree.zig");
const paint_table_mod = @import("paint_table.zig");

pub const ElementId = element_id_mod.ElementId;
pub const LayerTree = layer_tree_mod.LayerTree;
pub const LayerId = layer_tree_mod.LayerId;
pub const PromotionReason = layer_tree_mod.PromotionReason;
pub const Bounds = paint_table_mod.Bounds;

/// individual element promotion hint, set by reactive/animation/scroll during prepass phase
pub const PromotionHint = packed struct(u8) {
    transform_animating: bool = false,
    opacity_animating: bool = false,
    is_scroll_container: bool = false,
    will_change: bool = false,
    has_filter: bool = false, // Phase 6+
    has_3d_transform: bool = false, // Phase 6+
    _reserved: u2 = 0,

    pub const NONE: PromotionHint = .{};

    pub fn shouldPromote(self: PromotionHint) bool {
        return self.transform_animating or
            self.opacity_animating or
            self.is_scroll_container or
            self.will_change;
    }

    pub fn primaryReason(self: PromotionHint) PromotionReason {
        if (self.transform_animating) return .transform_animating;
        if (self.opacity_animating) return .opacity_animating;
        if (self.is_scroll_container) return .scroll;
        if (self.will_change) return .will_change;
        if (self.has_filter) return .filter;
        if (self.has_3d_transform) return .transform_3d;
        return .root;
    }
};

/// simplified layerize: given set of (element_id, hint, bounds), build LayerTree. Real integration
/// called by render pipeline, feeds entire World's paint chunks.
pub fn layerize(
    tree: *LayerTree,
    items: []const LayerizeInput,
) !void {
    // first create a root layer
    if (tree.root.isNull()) {
        const root_layer = try tree.createLayer(ElementId.NULL, .root, LayerId.NULL);
        tree.root = root_layer;
    }
    const root_id = tree.root;

    var current_group_layer: LayerId = root_id;
    // TODO Phase 4 later: use min_layer_area_px2 threshold to decide when to merge small groups to
    // parent; currently focus on correctness, performance tuning reserved.

    for (items) |item| {
        if (item.hint.shouldPromote()) {
            // check if reached layer count limit
            if (tree.liveLayerCount() >= tree.config.max_layer_count) {
                // downgrade: merge to current group
                try tree.assignElement(current_group_layer, item.element);
                continue;
            }

            // promote to new layer, parent = root (Phase 4 doesn't do nested layers yet;
            // optimization later)
            const reason = item.hint.primaryReason();
            const new_layer = try tree.createLayer(item.element, reason, root_id);
            try tree.assignElement(new_layer, item.element);

            // sync bounds to layer
            if (tree.getMut(new_layer)) |l| {
                l.world_bounds = item.world_bounds;
                l.property_state = item.property_state;
            }

            // subsequent non-promoted elements follow this new layer
            current_group_layer = new_layer;
        } else {
            // no promotion -> merge to current group layer
            try tree.assignElement(current_group_layer, item.element);
            if (tree.getMut(current_group_layer)) |l| {
                l.world_bounds = l.world_bounds.unionWith(item.world_bounds);
            }
        }
    }
}

pub const LayerizeInput = struct {
    element: ElementId,
    hint: PromotionHint = .NONE,
    world_bounds: Bounds = .ZERO,
    property_state: paint_table_mod.PropertyStateRef = .NONE,
};

// ============================================================================
// Tests
// ============================================================================

test "PromotionHint: shouldPromote" {
    try testing.expect(!PromotionHint.NONE.shouldPromote());

    var h: PromotionHint = .{};
    h.transform_animating = true;
    try testing.expect(h.shouldPromote());
    try testing.expectEqual(PromotionReason.transform_animating, h.primaryReason());

    h = .{ .is_scroll_container = true };
    try testing.expect(h.shouldPromote());
    try testing.expectEqual(PromotionReason.scroll, h.primaryReason());
}

test "layerize: empty input creates only root layer" {
    var t = LayerTree.init(testing.allocator, .{});
    defer t.deinit();
    try layerize(&t, &.{});
    try testing.expectEqual(@as(u32, 1), t.liveLayerCount());
    try testing.expect(!t.root.isNull());
}

test "layerize: non-promoted elements all join root" {
    var t = LayerTree.init(testing.allocator, .{});
    defer t.deinit();

    const e1: ElementId = .{ .index = 1, .generation = 0 };
    const e2: ElementId = .{ .index = 2, .generation = 0 };
    const e3: ElementId = .{ .index = 3, .generation = 0 };

    try layerize(&t, &.{
        .{ .element = e1, .world_bounds = .{ .min_x = 0, .min_y = 0, .max_x = 100, .max_y = 100 } },
        .{ .element = e2, .world_bounds = .{ .min_x = 100, .min_y = 0, .max_x = 200, .max_y = 100 } },
        .{ .element = e3, .world_bounds = .{ .min_x = 0, .min_y = 100, .max_x = 200, .max_y = 200 } },
    });

    try testing.expectEqual(@as(u32, 1), t.liveLayerCount());
    try testing.expect(t.layerOf(e1).?.eql(t.root));
    try testing.expect(t.layerOf(e2).?.eql(t.root));
    try testing.expect(t.layerOf(e3).?.eql(t.root));
}

test "layerize: scroll container is promoted to its own layer" {
    var t = LayerTree.init(testing.allocator, .{});
    defer t.deinit();

    const root_elem: ElementId = .{ .index = 1, .generation = 0 };
    const scroll_elem: ElementId = .{ .index = 2, .generation = 0 };
    const child_in_scroll: ElementId = .{ .index = 3, .generation = 0 };

    try layerize(&t, &.{
        .{ .element = root_elem, .world_bounds = .{ .min_x = 0, .min_y = 0, .max_x = 800, .max_y = 600 } },
        .{
            .element = scroll_elem,
            .hint = .{ .is_scroll_container = true },
            .world_bounds = .{ .min_x = 100, .min_y = 100, .max_x = 700, .max_y = 500 },
        },
        .{ .element = child_in_scroll, .world_bounds = .{ .min_x = 100, .min_y = 100, .max_x = 200, .max_y = 200 } },
    });

    // 1 root layer + 1 scroll layer
    try testing.expectEqual(@as(u32, 2), t.liveLayerCount());

    const scroll_layer = t.layerOf(scroll_elem).?;
    try testing.expect(!scroll_layer.eql(t.root));
    try testing.expectEqual(PromotionReason.scroll, t.get(scroll_layer).?.reason);

    // child_in_scroll follows scroll layer
    try testing.expect(t.layerOf(child_in_scroll).?.eql(scroll_layer));
}

test "layerize: transform-animating element gets its own layer" {
    var t = LayerTree.init(testing.allocator, .{});
    defer t.deinit();

    const animating: ElementId = .{ .index = 5, .generation = 0 };
    try layerize(&t, &.{
        .{
            .element = animating,
            .hint = .{ .transform_animating = true },
            .world_bounds = .{ .min_x = 0, .min_y = 0, .max_x = 100, .max_y = 100 },
        },
    });

    const layer = t.layerOf(animating).?;
    try testing.expect(!layer.eql(t.root));
    try testing.expectEqual(PromotionReason.transform_animating, t.get(layer).?.reason);
}

test "layerize: max_layer_count cap downgrades extra promotions to current group" {
    var t = LayerTree.init(testing.allocator, .{ .max_layer_count = 3 }); // 1 root + at most 2 promoted
    defer t.deinit();

    const e1: ElementId = .{ .index = 1, .generation = 0 };
    const e2: ElementId = .{ .index = 2, .generation = 0 };
    const e3: ElementId = .{ .index = 3, .generation = 0 };
    const e4: ElementId = .{ .index = 4, .generation = 0 };

    try layerize(&t, &.{
        .{ .element = e1, .hint = .{ .transform_animating = true }, .world_bounds = .{ .min_x = 0, .min_y = 0, .max_x = 100, .max_y = 100 } },
        .{ .element = e2, .hint = .{ .transform_animating = true }, .world_bounds = .{ .min_x = 0, .min_y = 0, .max_x = 100, .max_y = 100 } },
        .{ .element = e3, .hint = .{ .transform_animating = true }, .world_bounds = .{ .min_x = 0, .min_y = 0, .max_x = 100, .max_y = 100 } },
        .{ .element = e4, .hint = .{ .transform_animating = true }, .world_bounds = .{ .min_x = 0, .min_y = 0, .max_x = 100, .max_y = 100 } },
    });

    // total layer count not exceeding 3 (root + e1 + e2, e3/e4 downgraded to e2 group)
    try testing.expect(t.liveLayerCount() <= 3);
    try testing.expect(t.layerOf(e1) != null);
    try testing.expect(t.layerOf(e3) != null);
}
