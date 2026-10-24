//! Paint band: sole source of truth for render and hit test.
//!
//! `z_index` expresses only "draw and hit order among siblings under the same parent" (each node is
//! a stacking context for its children) and **doesn't affect clipping**: clipping always comes from
//! the ancestor `overflow_hidden` chain. To draw outside all containers only a structural portal
//! works (`cx.ensurePopoverPortalRoot()` / OverlayStack).
//!
//! Sibling order = stable-sort by `siblingZ` (negative z clamped to 0), then traverse three bands
//! `regular -> sticky -> positive_z` in order; equivalent to a stable sort by (band, z)
//! lexicographic `siblingOrderKey`. Both render_engine (`sortSubtreeChildrenByZ` + `childPasses`)
//! and hit_runtime (`paintOrderedChildren` + three-band traversal) must go through here, else paint
//! order diverges from pixels.
//!
//! Circular import with node.zig for the Node type is fine, like node_inherit.zig and other
//! siblings.

const node_mod = @import("node.zig");

const Node = node_mod.Node;

pub const PaintBand = enum(u2) {
    /// Regular flow siblings (non-sticky, z<=0), insertion order.
    regular,
    /// Sticky siblings z<=0: paint after same-level regular, insertion order.
    sticky,
    /// Siblings z>0 (including z>0 sticky): paint last, stable ascending z order.
    positive_z,
};

/// Three-band traversal order.
pub const bands = [_]PaintBand{ .regular, .sticky, .positive_z };

pub fn paintBand(child: *const Node) PaintBand {
    if (child.style.z_index() > 0) return .positive_z;
    return if (child.style.position == .sticky) .sticky else .regular;
}

/// Z for sibling sort: negative values clamp to 0 (negative z currently ineffective, preserve
/// insertion order).
pub fn siblingZ(node: *const Node) i16 {
    return @max(node.style.z_index(), 0);
}

pub const SiblingOrderKey = struct {
    band: PaintBand,
    z: i16,

    pub fn lessThan(lhs: SiblingOrderKey, rhs: SiblingOrderKey) bool {
        if (lhs.band != rhs.band) return @backingInt(lhs.band) < @backingInt(rhs.band);
        return lhs.z < rhs.z;
    }
};

/// Sibling order key: (band, z) dictionary order + stable sort (same key preserve insertion order).
pub fn siblingOrderKey(child: *const Node) SiblingOrderKey {
    return .{ .band = paintBand(child), .z = siblingZ(child) };
}
