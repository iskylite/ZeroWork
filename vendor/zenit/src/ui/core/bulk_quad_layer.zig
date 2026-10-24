//! BulkQuad: batch rect layer, a stateful render subsystem extracted from Cx.
//!
//! Manages one thing: bypassing the Node tree for a batch of isomorphic rects, lowering them to
//! display items at the end of the paint pass and inserting them into the display list at the
//! correct position.
//!
//! Its only Cx dependencies are six read-only inputs:
//!
//!   display_list / property_tree / scene_runtime / root / frame_arena / allocator
//!
//! Interface boundary: the Host packages these six inputs; this module does not know Cx exists
//! (Cx.appendBulkQuads is a one-line delegation, see core.zig). The three setBulkQuads* are
//! public Host API with external consumers (downstream apps) and stay as thin delegates on Cx;
//! moving them breaks the API.
//!
//! Logic that would otherwise be drivable only via full Cx.render() (three-level insertion point,
//! z merge, z inherit, null anchor degradation) is testable with a hand-rolled display list +
//! Node tree (see module-end tests).
//!
//! WARNING: two integration points stay in Cx, do not move them here:
//!   - Cx.render end calls cx.appendBulkQuads() (after the paint pass);
//!   - Cx.invalidateReferencesToEx clears anchors (see the dropIfInsideSubtree comment, which
//!     records a SIGSEGV lesson).

const std = @import("std");

const types = @import("types.zig");
const node_mod = @import("node.zig");
const display_list_mod = @import("display_list.zig");
const property_tree_mod = @import("property_tree.zig");
const scene_runtime_mod = @import("scene_runtime.zig");

const Allocator = std.mem.Allocator;
const Node = node_mod.Node;
const DisplayItem = display_list_mod.DisplayItem;
const ItemHeader = display_list_mod.ItemHeader;
const Color = types.Color;
const ComputedRect = types.ComputedRect;
const Shadow = types.Shadow;
const InsetShadow = types.InsetShadow;
const MultiGradient = types.MultiGradient;

/// Batch rect: submit unit for a batch of isomorphic rects that bypass the Node tree.
///
/// Motivation: Node cost is per-node mount, layout and paint traversal. Thousands of independent,
/// isomorphic small rects that take no part in layout/hit/focus/a11y (canvas objects, map symbols,
/// tile grids, scatter dots) would pay for capabilities they never use.
/// Unwrapped, 17727 nodes cost layout 10.5ms + paint 32.2ms vs 0.8ms total: pure per-node constant.
///
/// Semantics (deliberately constrained; use Node for anything more):
///   - Coords are viewport-absolute (no parent transform / layout / scroll offset);
///   - No hit test, focus, a11y tree, animation, effect stack;
///   - Z and clip follow the setBulkQuads anchor (see Cx.setBulkQuads): anchored quads draw at the
///     Node's content position and get its clip, like normal children; unanchored quads draw atop
///     the whole Node tree, unclipped (overlay-only);
///   - Within the group, render in array order (later covers earlier);
///   - Data is retained across frames until the host calls setBulkQuads again (no cross-frame
///     diff).
///     See Cx.setBulkQuads "Lifespan" section.
///
/// Pixel equivalence: lowered fill_rect / stroke_rect use the same SDF pipeline and params as the
/// Node path, so output is bitwise identical (core/tests.zig Node-vs-bulk comparison).
pub const BulkQuad = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    /// Fill color. alpha=0 means no fill (stroke only).
    color: Color,
    /// Four-corner radius (order like Node: TL/TR/BR/BL).
    radius: [4]f32 = .{ 0, 0, 0, 0 },
    /// Stroke width; 0 means no stroke.
    border_width: f32 = 0,
    border_color: Color = Color.TRANSPARENT,
    /// This quad's z_index among the anchor subtree's sibling order.
    ///
    /// null (default) = whole layer is one plane inserted after the anchor subtree's static
    /// content,
    /// i.e. draws over all Node objects (for batch items that are only on screen).
    ///
    /// Given a value, the quad is inserted before the first Node item with z_index > this, so batch
    /// and Node interleave per item. The host passes object z through as-is.
    ///
    /// Needed because one plane can't express 'some objects under certain Nodes, others over'. Real
    /// scenes keep some objects in the Node path (text), z spans the whole range, and a single
    /// plane
    /// at any cut paints the wrong side.
    z_index: ?i16 = null,

    /// Per-side stroke width (Node order: top/right/bottom/left). All-zero = use uniform
    /// border_width path (same as InstanceData.border_widths). Nonzero ignores border_width.
    ///
    /// GPU InstanceData already has float4 border_widths and DisplayItem.border_per_side exists;
    /// this is the pass-through.
    border_widths: [4]f32 = .{ 0, 0, 0, 0 },

    /// Shadow. null = no shadow, zero overhead.
    ///
    /// The SDF fragment shader computes shadow analytically (same instanced draw as fill, no
    /// offscreen pass). Exposed here so shadowed objects don't fall back to the Node path (53x
    /// slower).
    shadow: ?Shadow = null,

    /// Inner shadow. null = none. Also analytic; packed_flags bit24 has flag.
    inset_shadow: ?InsetShadow = null,

    /// Gradient fill. null = use `color` solid.
    ///
    /// Same path as shadow: InstanceData has gradient_stop_offset / gradient_stop_count and
    /// DisplayItem
    /// has multi_gradient_rect (16 stops); this is the pass-through.
    ///
    /// With a gradient, `color` is ignored (but set it sensibly for the degraded path).
    gradient: ?MultiGradient = null,
    /// Radial/angular gradient center and start angle (meaningful only for direction).
    gradient_center: [2]f32 = .{ 0.5, 0.5 },
    gradient_start_angle: f32 = 0,

    /// Extra clip rect (viewport-absolute x/y/w/h). null = only the anchor clip.
    ///
    /// Given a value, the quad is clipped to (anchor_clip AND this rect). A property-tree ClipNode
    /// is
    /// built per distinct rect (same rect in one frame = one node, parent is the anchor clip), and
    /// lowering keeps the clip prefix so adjacent same-clip quads share push/pop.
    /// SDF/text/image renderers all support per-instance clip (host case: canvas frame clips
    /// children).
    clip_rect: ?[4]f32 = null,

    pub fn hasPerSideBorder(self: BulkQuad) bool {
        return self.border_widths[0] != 0 or self.border_widths[1] != 0 or
            self.border_widths[2] != 0 or self.border_widths[3] != 0;
    }
};

/// Max DisplayItems per BulkQuad: shadow + fill + stroke + inner shadow. Capacity only
/// (write uses append, underestimate just one realloc, doesn't hurt correctness). See
/// appendQuadItems.
pub const MAX_ITEMS_PER_QUAD: usize = 4;

/// This module's sole Host dependency: six read-only inputs.
///
/// Not *Cx directly: that would reverse-import core.zig, recompile on any Cx field change, and
/// make the logic (insertion point / z merge / lower) untestable without a full tree.
/// Same Host pattern as text_input_session.zig: bundles of dependency values/pointers keep the
/// module independently compilable and testable.
pub const Host = struct {
    /// Target display list (write: batch layer lowers/inserts here).
    display_list: *display_list_mod.DisplayList,
    /// Build ClipNode here for per-quad extra clip (BulkQuad.clip_rect).
    property_tree: *property_tree_mod.PropertyTree,
    /// Anchor's clip source: look up clip_id by anchor.id.
    scene_runtime: *const scene_runtime_mod.SceneRuntime,
    /// Post-anchor sibling positioning (level 3 of three-level insertion point) traverse
    /// from root.
    root: ?*Node = null,
    /// Frame arena. Insertion-point one-time sets (ids / overlay_ids / item_z) all allocate
    /// here, vanish with arena frame-end.
    frame_arena: Allocator,
    /// display list / staged buffer long-term allocator (Cx.allocator).
    allocator: Allocator,
};

pub const BulkQuadLayer = struct {
    /// Batch rect layer (see BulkQuad / Cx.setBulkQuads). Host directly submits batch
    /// absolute-coord rects, bypasses Node mount/layout/paint traverse.
    quads: std.ArrayListUnmanaged(BulkQuad) = .empty,
    /// Node batch rects anchor to (see Cx.setBulkQuads). null = unanchored (draw atop
    /// entire tree, unclipped). Render inserts quads per Node display item span and
    /// clip/transform id.
    anchor: ?*Node = null,
    /// "Interactive overlay" z_index start in anchor subtree (see Cx.setBulkQuadsEx). null
    /// = entire anchor subtree is static content.
    overlay_z: ?i16 = null,
    /// Host-declared batch layer content version (see Cx.setBulkQuadsVersioned).
    version: ?u64 = null,
    /// This frame batch layer content same as last (determined by version).
    unchanged: bool = false,

    pub fn deinit(self: *BulkQuadLayer, allocator: Allocator) void {
        self.quads.deinit(allocator);
    }

    /// Lower batch rects to display items, written into host.display_list.
    ///
    /// Isomorphic to the Node path: background -> fill_rect, stroke -> stroke_rect, params match
    /// item by item, so same geometry/color/radius/stroke_width gives bitwise identical pixels.
    pub fn append(self: *BulkQuadLayer, host: Host) !void {
        if (self.quads.items.len == 0) return;

        // When anchored: use Node's clip (=> receives overflow clipping) and insert at end of
        // Node's subtree display items (=> later siblings still cover). transform still identity:
        // BulkQuad coords are viewport-absolute, anchor only determines "z + clip", no parent
        // transform (would double-transform coords).
        var clip_id: u32 = display_list_mod.INVALID_ID;
        var node_id: u32 = 0;
        var insert_at: ?usize = null;
        if (self.anchor) |anchor| {
            // Anchored semantics must fail safe: better skip this frame's batch layer than degrade
            // to "append end + no clip". Latter lets 20k quads blanket sidebar / Inspector /
            // toolbar
            // (user screenshot "objects blur into UI chrome"). Missing a frame just lacks content,
            // next frame fixes it; painted on UI is unacceptable destructive regression.
            const rt = host.scene_runtime.get(anchor.id) orelse return;
            clip_id = rt.clip_id;
            node_id = anchor.id;
            // Insert point = last item after the anchor subtree in the display list. Don't use
            // scene_runtime's subtree_display_item_*: they are cached splice/replay bookkeeping
            // rewritten
            // elsewhere (stale points land past later siblings). Scan by ownership instead; it runs
            // once per
            // batch-submitting frame and is negligible vs 20k quads.
            //
            // insertPoint returns null only when nothing follows the anchor; tail-append is then
            // correct.
            insert_at = self.insertPoint(anchor, host);
        }

        const header = ItemHeader{
            // transform 0 = identity (property_tree root), coords are viewport-absolute.
            .transform_id = 0,
            .clip_id = clip_id,
            .node_id = node_id,
        };
        // Per-quad extra clip (BulkQuad.clip_rect) ClipNode cache.
        var clip_cache = BulkClipCache{};

        // Segmented path: any quad with z_index triggers group-by-z; each group locates its
        // insertion
        // point so batch interleaves with Node (see BulkQuad.z_index).
        //
        // Grouping splits only on adjacent-same-z, no global sort: host submit order is render
        // order
        // (BulkQuad contract), and reordering would break same-z sequence.
        if (self.anchor != null) {
            var any_z = false;
            for (self.quads.items) |q| {
                if (q.z_index != null) {
                    any_z = true;
                    break;
                }
            }
            if (any_z) {
                try self.appendSegmented(host, header, insert_at, &clip_cache);
                return;
            }
        }

        // Insert point at tail (no anchor, or anchor after last) skips staging, direct
        // display_list tail write, 20k quad scale saves one full-layer copy.
        const at_tail = insert_at == null or insert_at.? == host.display_list.items.items.len;
        if (at_tail) {
            try host.display_list.items.ensureUnusedCapacity(
                host.allocator,
                self.quads.items.len * MAX_ITEMS_PER_QUAD,
            );
            for (self.quads.items) |q| {
                // Shared lower with two other degrade paths; three separate writes tech debt, field
                // adds inevitably miss one (shadow/per-side nearly missed).
                try appendQuadItems(&host.display_list.items, host.allocator, q, clip_cache.headerFor(host, q, header));
            }
            return;
        }

        // Mid-insert: lower in staging, then insertSlice once (preserves in-group array order).
        var staged: std.ArrayListUnmanaged(DisplayItem) = .empty;
        defer staged.deinit(host.allocator);
        try staged.ensureTotalCapacity(host.allocator, self.quads.items.len * MAX_ITEMS_PER_QUAD);

        for (self.quads.items) |q| {
            try appendQuadItems(&staged, host.allocator, q, clip_cache.headerFor(host, q, header));
        }
        if (staged.items.len == 0) return;
        try host.display_list.items.insertSlice(host.allocator, insert_at.?, staged.items);
    }

    /// Batch layer insertion point: after anchor static content, before interactive overlay.
    ///
    /// Z model (bottom -> top), batch layer = tier 1:
    ///   1. Canvas static: Node-path big objects + batch small (interleave by submit/doc order);
    ///   2. Canvas interactive overlay: selection boxes / resize handles / size labels /
    ///      hover highlights / snap lines - anchor children but must cover batch;
    ///   3. UI chrome (sidebar / Inspector / toolbar) - anchor siblings, naturally after;
    ///   4. overlay / modal.
    ///
    /// Host declares tier 2 start via overlay_z_threshold (this layer's overlay_z field):
    /// anchor subtree nodes with z_index >= threshold are interactive; batch inserts before them.
    /// Unset (null) = whole subtree static.
    ///
    /// Three-level location, all required:
    ///   1. Anchor subtree has a static item => insert after its last (don't cross overlay).
    ///   2. No static item but has overlay (object selected, all canvas objects downgraded to
    ///      batch)
    ///      => insert before the first overlay item.
    ///   3. Anchor produced zero items (no own background + empty/downgraded children) => fall back
    ///      to before the first item of the siblings that come after the anchor. Returning null here is wrong: the
    ///      caller treats null as 'append tail', batch blankets chrome and flickers/blurs (see
    ///      core/tests.zig "anchor subtree no item" regression).
    /// Only when all three fail (nothing after anchor) return null; tail-append is then correct.
    pub fn insertPoint(self: *const BulkQuadLayer, anchor: *Node, host: Host) ?usize {
        const arena = host.frame_arena;

        // Anchor subtree node ids (once per frame, count = canvas container subtree, tiny).
        // overlay_ids = subset with z_index >= threshold interactive (includes children).
        var ids = std.AutoHashMapUnmanaged(u32, void){};
        defer ids.deinit(arena);
        collectSubtreeIds(anchor, &ids, arena) catch return null;

        var overlay_ids: std.AutoHashMapUnmanaged(u32, void) = .{};
        defer overlay_ids.deinit(arena);
        if (self.overlay_z) |threshold| {
            collectOverlayIds(anchor, threshold, false, &overlay_ids, arena) catch return null;
        }

        // First interactive overlay item: batch never crosses it.
        //
        // This scan (and the two below) must use DisplayItem.header() for all 25 item types, not a
        // switch over fill_rect/stroke_rect/text_run only. Missing types (begin_blur_layer,
        // image_quad /
        // icon_rep, shadow_rect / gradient_rect) can make a wrapper with no background produce zero
        // items => the three-level scan finds no landmark => returns null => caller degrades to
        // 'append tail + no clip' => batch quads blanket the UI.
        var first_overlay: ?usize = null;
        if (overlay_ids.count() != 0) {
            for (host.display_list.items.items, 0..) |it, idx| {
                if (it.isControl()) continue;
                if (overlay_ids.contains(it.header().node_id)) {
                    first_overlay = idx;
                    break;
                }
            }
        }

        var last: ?usize = null;
        for (host.display_list.items.items, 0..) |it, idx| {
            // Control tokens (with real node_id) don't count: scroll-clip pair appended in paint
            // pass lands at display_list end; counting them makes insertion point skip all chrome.
            if (it.isControl()) continue;
            const nid = it.header().node_id;
            // Position by static content only; overlay doesn't participate in "last item" calc.
            if (ids.contains(nid) and !overlay_ids.contains(nid)) last = idx;
        }
        if (last) |l| {
            const at = l + 1;
            // 1. After static content, never cross interactive overlay.
            if (first_overlay) |fo| return @min(at, fo);
            return at;
        }
        // 2. Static empty but has overlay => insert before overlay.
        if (first_overlay) |fo| return fo;

        // 3. Anchor subtree empty: use "nodes after anchor" instead. Collect all node ids in paint
        // order after anchor subtree, take their first display list item, insert batch layer before
        // it,
        // still covered by chrome.
        const root = host.root orelse return null;
        var after: std.AutoHashMapUnmanaged(u32, void) = .{};
        defer after.deinit(arena);
        var seen_anchor = false;
        collectIdsAfterSubtree(root, anchor, &seen_anchor, &after, arena) catch return null;
        if (after.count() == 0) return null;

        for (host.display_list.items.items, 0..) |it, idx| {
            if (after.contains(it.header().node_id)) return idx;
        }
        return null;
    }

    /// Segmented submit: merge z-bearing batch quads with the anchor subtree's Node items into a
    /// new
    /// display list.
    ///
    /// Single-pass merge, not per-segment scan: the latter is O(n^2) at 20k segments x 20k items
    /// (1.1s -> 5.7s per screenshot).
    ///
    /// Merge rule: ascending z, same z Node items first (matches zenit sibling sort: equal z keeps
    /// insertion order, Node output first).
    fn appendSegmented(
        self: *BulkQuadLayer,
        host: Host,
        header: ItemHeader,
        tail_insert_at: ?usize,
        clip_cache: *BulkClipCache,
    ) !void {
        const arena = host.frame_arena;
        const anchor = self.anchor.?;
        var item_z: std.ArrayListUnmanaged(?i16) = .empty;
        defer item_z.deinit(arena);
        collectItemZ(anchor, host, &item_z, arena) catch return;

        const src = host.display_list.items.items;
        const tail = tail_insert_at orelse src.len;

        var merged: std.ArrayListUnmanaged(DisplayItem) = .empty;
        defer merged.deinit(host.allocator);
        try merged.ensureTotalCapacity(
            host.allocator,
            src.len + self.quads.items.len * MAX_ITEMS_PER_QUAD,
        );

        var qi: usize = 0;
        for (src, 0..) |it, idx| {
            // Merge only within anchor subtree static span; outside (chrome etc) unchanged.
            if (idx < tail) {
                const nz = item_z.items[idx];
                if (nz) |z| {
                    // Emit all quads with z strictly less than current item first.
                    while (qi < self.quads.items.len) : (qi += 1) {
                        const q = self.quads.items[qi];
                        const qz = q.z_index orelse break;
                        if (qz >= z) break;
                        try appendQuadItems(&merged, host.allocator, q, clip_cache.headerFor(host, q, header));
                    }
                }
            }
            if (idx == tail) {
                // Reach insertion point: remaining quads all land here (they're after any subtree
                // Node),
                // following items are chrome, must cover batch.
                while (qi < self.quads.items.len) : (qi += 1) {
                    const q = self.quads.items[qi];
                    try appendQuadItems(&merged, host.allocator, q, clip_cache.headerFor(host, q, header));
                }
            }
            try merged.append(host.allocator, it);
        }
        // Finish: only append remaining quads to end if insertion point is already entire display
        // list end. Else they already landed at idx==tail, append again lets batch cross chrome
        // post-anchor (sidebar / Inspector / toolbar) - the "objects blur into UI" regression.
        if (tail >= src.len) {
            while (qi < self.quads.items.len) : (qi += 1) {
                const q = self.quads.items[qi];
                try appendQuadItems(&merged, host.allocator, q, clip_cache.headerFor(host, q, header));
            }
        }

        host.display_list.items.clearRetainingCapacity();
        try host.display_list.items.appendSlice(host.allocator, merged.items);
    }

    /// Each display item in anchor subtree's owning Node z_index (null if unowned). Once per
    /// frame, for segmented merge single-pass combine.
    pub fn collectItemZ(
        anchor: *Node,
        host: Host,
        out: *std.ArrayListUnmanaged(?i16),
        arena: Allocator,
    ) !void {
        var zmap = std.AutoHashMapUnmanaged(u32, i16){};
        defer zmap.deinit(arena);
        try collectSubtreeZ(anchor, &zmap, arena);
        try out.ensureTotalCapacity(arena, host.display_list.items.items.len);
        for (host.display_list.items.items) |it| {
            out.appendAssumeCapacity(if (it.isControl()) null else zmap.get(it.header().node_id));
        }
    }

    /// Replace this frame's batch rect layer (see BulkQuad). Internally copies; caller can
    /// immediately reuse/free quads. Pass empty slice to disable layer (anchor / overlay_z still
    /// overwritten, matches Cx.setBulkQuadsEx existing behavior).
    pub fn set(
        self: *BulkQuadLayer,
        host: Host,
        anchor: ?*Node,
        quads: []const BulkQuad,
        overlay_z_threshold: ?i16,
    ) !void {
        self.quads.clearRetainingCapacity();
        self.anchor = anchor;
        self.overlay_z = overlay_z_threshold;
        if (quads.len == 0) return;
        try self.quads.ensureTotalCapacity(host.allocator, quads.len);
        self.quads.appendSliceAssumeCapacity(quads);
    }

    /// setBulkQuadsVersioned version check: same version as last frame => unchanged true
    /// (clean-frame fast path holds); pass null => degrade to conservative redraw.
    pub fn setVersioned(
        self: *BulkQuadLayer,
        host: Host,
        anchor: ?*Node,
        quads: []const BulkQuad,
        overlay_z_threshold: ?i16,
        version: ?u64,
    ) !void {
        self.unchanged = if (version) |v| blk: {
            const same = self.version != null and self.version.? == v;
            self.version = v;
            break :blk same;
        } else blk: {
            self.version = null;
            break :blk false;
        };
        return self.set(host, anchor, quads, overlay_z_threshold);
    }

    /// Anchor destruction backstop: anchor in subtree_root => clear anchor AND disable layer.
    ///
    /// Anchor is a bare *Node (see Cx.setBulkQuads Lifespan section). The host contract is
    /// 'resubmit
    /// before destroy', but the destruction path must backstop it: the host may render a frame
    /// after
    /// subtree removal and before the next setBulkQuads, leaving the anchor dangling; append would
    /// then dereference anchor.id and read an unmapped address in Cx.render.
    ///
    /// Clear the anchor together with the quads: clearing only the pointer degrades to 'append tail
    /// +
    /// no clip' (null-anchor semantics), so 20k quads blanket the chrome.
    /// Returns whether actually cleared (false = anchor not in subtree, untouched).
    pub fn dropIfInsideSubtree(self: *BulkQuadLayer, subtree_root: *Node) bool {
        const anchor = self.anchor orelse return false;
        var current: ?*Node = anchor;
        while (current) |n| {
            if (n == subtree_root) {
                self.anchor = null;
                self.overlay_z = null;
                self.quads.clearRetainingCapacity();
                return true;
            }
            current = n.parent;
        }
        return false;
    }
};

/// Per-frame cache for BulkQuad.clip_rect -> ClipNode (same rect = one node; typical host
/// all children share one rect per frame). Map in frame_arena, vanish with arena frame-end,
/// no explicit cleanup.
pub const BulkClipCache = struct {
    map: std.AutoHashMapUnmanaged(u128, u32) = .{},

    /// Parse header for one quad: no clip_rect return as-is; with clip_rect swap clip_id to
    /// ad-hoc ClipNode with parent=anchor clip, chained emit = viewport clip AND quad clip.
    /// ClipNode create fail degrades safe to anchor clip (this frame skip one clip, not drop
    /// entire batch).
    pub fn headerFor(
        cache: *BulkClipCache,
        host: Host,
        q: BulkQuad,
        base: ItemHeader,
    ) ItemHeader {
        const rect = q.clip_rect orelse return base;
        const key: u128 = @bitCast(rect);
        const gop = cache.map.getOrPut(host.frame_arena, key) catch return base;
        if (!gop.found_existing) {
            const cr = ComputedRect.init(rect[0], rect[1], rect[2], rect[3]);
            gop.value_ptr.* = host.property_tree.appendClip(.{
                .parent = base.clip_id,
                // transform 0 = identity: BulkQuad coords are viewport-absolute.
                .transform_id = 0,
                .node_id = base.node_id,
                .local_rect = cr,
                .world_aabb = cr,
            }) catch {
                _ = cache.map.remove(key);
                return base;
            };
        }
        var h = base;
        h.clip_id = gop.value_ptr.*;
        return h;
    }
};

fn collectSubtreeIds(
    node: *Node,
    out: *std.AutoHashMapUnmanaged(u32, void),
    allocator: Allocator,
) !void {
    try out.put(allocator, node.id, {});
    for (node.children.items) |child| {
        try collectSubtreeIds(child, out, allocator);
    }
}

/// Collect interactive overlay node ids in anchor subtree: z_index >= threshold and
/// entire subtrees (children inherit parent overlay status, size label text follows capsule).
/// inherited = ancestor already crossed threshold.
fn collectOverlayIds(
    node: *Node,
    threshold: i16,
    inherited: bool,
    out: *std.AutoHashMapUnmanaged(u32, void),
    allocator: Allocator,
) !void {
    const is_overlay = inherited or node.style.z_index() >= threshold;
    if (is_overlay) try out.put(allocator, node.id, {});
    for (node.children.items) |child| {
        try collectOverlayIds(child, threshold, is_overlay, out, allocator);
    }
}

/// Paint-order traverse node, collect node ids after anchor subtree into out. seen_anchor
/// state: set after seeing anchor, thereafter nodes count "after". Anchor subtree itself
/// neither before nor after (skip entire).
fn collectIdsAfterSubtree(
    node: *Node,
    anchor: *Node,
    seen_anchor: *bool,
    out: *std.AutoHashMapUnmanaged(u32, void),
    allocator: Allocator,
) !void {
    if (node == anchor) {
        seen_anchor.* = true;
        return; // Skip entire anchor subtree.
    }
    if (seen_anchor.*) try out.put(allocator, node.id, {});
    for (node.children.items) |child| {
        try collectIdsAfterSubtree(child, anchor, seen_anchor, out, allocator);
    }
}

fn collectSubtreeZ(
    node: *Node,
    out: *std.AutoHashMapUnmanaged(u32, i16),
    allocator: Allocator,
) !void {
    try collectSubtreeZInherited(node, node.style.z_index(), out, allocator);
}

/// Subtree z ownership: descendants inherit the ancestor z_index (an explicit own value overrides).
/// Batch merge compares 'item z' to decide whether a quad goes before/after it, and z is a
/// sibling-level notion: children of a z=3 object container belong to its tier and need no z of
/// their own. Reading the child's own z_index (default 0) would treat a z=3 container's text as
/// z=0, so a z=2 batch quad lands after the text and covers it.
fn collectSubtreeZInherited(
    node: *Node,
    inherited_z: i16,
    out: *std.AutoHashMapUnmanaged(u32, i16),
    allocator: Allocator,
) !void {
    try out.put(allocator, node.id, inherited_z);
    for (node.children.items) |child| {
        // Child explicit positive z_index starts new tier; else inherit (0 = unset).
        const child_z = child.style.z_index();
        const effective = if (child_z != 0) child_z else inherited_z;
        try collectSubtreeZInherited(child, effective, out, allocator);
    }
}

/// One BulkQuad lowers to 1-4 DisplayItems.
///
/// Order = render order, same as the Node path (node_style_render.zig): shadow -> fill -> stroke ->
/// inner shadow. Shadow goes before fill (else it covers the object); inner shadow after fill.
///
/// Not combined: encoder .rect kind treats fill (stroke_width=0) and stroke (stroke_width > 0) as
/// mutually exclusive (see command_encoder.zig), so one instance can't draw both; the Node path
/// also emits two.
fn appendQuadItems(
    out: *std.ArrayListUnmanaged(DisplayItem),
    allocator: Allocator,
    q: BulkQuad,
    header: ItemHeader,
) !void {
    if (q.shadow) |s| {
        if (s.color.a > 0) {
            try out.append(allocator, .{ .shadow_rect = .{
                .header = header,
                .x = q.x,
                .y = q.y,
                .w = q.w,
                .h = q.h,
                .color = s.color,
                .blur = s.blur,
                .offset_x = s.offset_x,
                .offset_y = s.offset_y,
                .radius = q.radius,
            } });
        }
    }
    if (q.gradient) |g| {
        // Gradient priority over solid: given gradient skip fill_rect, else solid covers gradient
        // (render order: later covers earlier).
        if (g.stop_count >= 2) {
            var item: DisplayItem = .{ .multi_gradient_rect = .{
                .header = header,
                .x = q.x,
                .y = q.y,
                .w = q.w,
                .h = q.h,
                .direction = g.direction,
                .radius = q.radius,
                .stop_count = g.stop_count,
                .radial_center_x = q.gradient_center[0],
                .radial_center_y = q.gradient_center[1],
                .conic_start_angle = q.gradient_start_angle,
            } };
            for (g.stops[0..g.stop_count], 0..) |st, i| {
                item.multi_gradient_rect.stop_colors[i] = st.color;
                item.multi_gradient_rect.stop_positions[i] = st.position;
            }
            try out.append(allocator, item);
        }
    } else if (q.color.a > 0) {
        try out.append(allocator, .{ .fill_rect = .{
            .header = header,
            .x = q.x,
            .y = q.y,
            .w = q.w,
            .h = q.h,
            .color = q.color,
            .radius = q.radius,
        } });
    }
    if (q.border_color.a > 0) {
        // Per-side first: if the four values are not all zero => use border_per_side, border_width
        // ignored (same semantics as InstanceData.border_widths "all-zero = use border_width").
        if (q.hasPerSideBorder()) {
            try out.append(allocator, .{ .border_per_side = .{
                .header = header,
                .x = q.x,
                .y = q.y,
                .w = q.w,
                .h = q.h,
                .color = q.border_color,
                .widths = q.border_widths,
                .radius = q.radius,
            } });
        } else if (q.border_width > 0) {
            try out.append(allocator, .{ .stroke_rect = .{
                .header = header,
                .x = q.x,
                .y = q.y,
                .w = q.w,
                .h = q.h,
                .color = q.border_color,
                .width = q.border_width,
                .radius = q.radius,
            } });
        }
    }
    if (q.inset_shadow) |s| {
        if (s.color.a > 0) {
            // Note inset_shadow_rect has fill built-in, draws bottom color in shader (see
            // sdf_primitives.metal
            // inset branch). Pass TRANSPARENT here: bottom already drawn by fill_rect above, redraw
            // makes
            // semi-transparent fill stack one layer deeper.
            try out.append(allocator, .{ .inset_shadow_rect = .{
                .header = header,
                .x = q.x,
                .y = q.y,
                .w = q.w,
                .h = q.h,
                .fill = Color.TRANSPARENT,
                .shadow_color = s.color,
                .blur = s.blur,
                .offset_x = s.offset_x,
                .offset_y = s.offset_y,
                .radius = q.radius,
            } });
        }
    }
}

// -- Tests --
//
// Because the layer is split out, the three-level insertion point, z merge, z inherit and
// null-anchor degrade paths are testable with a hand-rolled display list and Node tree, without
// a full Cx.render() pass. A failure pinpoints this layer, not the whole frame.

const testing = std.testing;

/// Hand-rolled display item simplest form: fill_rect with specified node_id.
fn fillFor(node_id: u32) DisplayItem {
    return .{ .fill_rect = .{
        .header = .{ .transform_id = 0, .clip_id = display_list_mod.INVALID_ID, .node_id = node_id },
        .x = 0,
        .y = 0,
        .w = 8,
        .h = 8,
        .color = Color.hex(0xFF00FF),
    } };
}

/// Test scaffold: frame_arena + short-lived allocator combo isomorphic to Cx.render
/// (Cx.allocator long-holds display list, frame_arena only frame-local temp sets).
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    list: display_list_mod.DisplayList,
    tree: property_tree_mod.PropertyTree,
    runtime: scene_runtime_mod.SceneRuntime,

    fn init() Fixture {
        return .{
            .arena = std.heap.ArenaAllocator.init(testing.allocator),
            .list = display_list_mod.DisplayList.init(testing.allocator),
            .tree = property_tree_mod.PropertyTree.init(testing.allocator),
            .runtime = scene_runtime_mod.SceneRuntime.init(testing.allocator),
        };
    }
    fn deinit(self: *Fixture) void {
        self.list.deinit();
        self.tree.deinit();
        self.runtime.deinit();
        self.arena.deinit();
    }
    fn host(self: *Fixture, root: ?*Node) Host {
        return .{
            .display_list = &self.list,
            .property_tree = &self.tree,
            .scene_runtime = &self.runtime,
            .root = root,
            .frame_arena = self.arena.allocator(),
            .allocator = testing.allocator,
        };
    }

    /// Anchor's clip source for anchored semantics: append looks it up by anchor.id; on a miss the
    /// whole layer safely skips the frame (see append's defense against objects blurring into the
    /// UI).
    /// The real render pass writes it; a hand-rolled fixture must fill it, else append silently
    /// exits early and no batch items reach the display list. Only node_id / clip_id / transform_id
    /// need filling; this layer consumes just those three.
    fn registerRuntime(self: *Fixture, node: *Node, clip_id: u32) !void {
        try self.runtime.put(.{
            .node_id = node.id,
            .local_rect = ComputedRect.init(0, 0, 0, 0),
            .world_bounds = ComputedRect.init(0, 0, 0, 0),
            .transform_id = 0,
            .clip_id = clip_id,
        });
    }
};

/// Write z_index to node (StyleExt field). Not via Node.setStyle: that path also
/// markRenderDirty / markWorldDirty, pushes fixture node into some other Cx's World dirty_set
/// (Node.create depends on process-level hook, prior init Cx in process catches it). Here just
/// need style.z_index() readable, alloc ext directly; Node.destroy frees.
fn setZ(a: Allocator, node: *Node, z: i16) !void {
    const ext = try a.create(types.StyleExt);
    ext.* = .{};
    ext.z_index = z;
    node.style.ext = ext;
}

/// buildTree return shape (canvas / obj / overlay / chrome pointers each).
const TestTree = struct {
    root: *Node,
    canvas: *Node,
    obj: *Node,
    overlay: *Node,
    chrome: *Node,
};

/// Hand-roll three-segment tree: canvas (anchor) hangs obj (static) and overlay (interactive),
/// canvas after is chrome sibling. z_index only node state insertPoint needs.
fn buildTree(a: Allocator) !TestTree {
    const root = try node_mod.Node.create(a, 1, .box, .{});
    const canvas = try node_mod.Node.create(a, 2, .box, .{});
    const obj = try node_mod.Node.create(a, 3, .box, .{});
    const overlay = try node_mod.Node.create(a, 4, .box, .{});
    const chrome = try node_mod.Node.create(a, 5, .box, .{});
    try setZ(a, overlay, 31000);
    try root.appendChild(a, canvas);
    try root.appendChild(a, chrome);
    try canvas.appendChild(a, obj);
    try canvas.appendChild(a, overlay);
    return .{ .root = root, .canvas = canvas, .obj = obj, .overlay = overlay, .chrome = chrome };
}

fn freeTree(a: Allocator, root: *Node) void {
    root.destroy(a);
}

test "insertPoint ①：静态内容之后，且不越过交互叠加" {
    var f = Fixture.init();
    defer f.deinit();
    const tree = try buildTree(testing.allocator);
    defer freeTree(testing.allocator, tree.root);

    // display list: [obj(3)] [overlay(4)] [chrome(5)]
    try f.list.append(fillFor(tree.obj.id));
    try f.list.append(fillFor(tree.overlay.id));
    try f.list.append(fillFor(tree.chrome.id));

    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    layer.overlay_z = 31000;
    const h = f.host(tree.root);

    // 1. After static (obj=0), before overlay (idx 1) => 1.
    try testing.expectEqual(@as(?usize, 1), layer.insertPoint(tree.canvas, h));
}

test "insertPoint ①：静态内容末尾越过叠加时被夹回叠加之前" {
    var f = Fixture.init();
    defer f.deinit();
    const tree = try buildTree(testing.allocator);
    defer freeTree(testing.allocator, tree.root);

    // Overlay paint before static (z 31000 child paints first): last_static=1 (obj) => at=2,
    // but first_overlay=0 => @min => 0.
    try f.list.append(fillFor(tree.overlay.id));
    try f.list.append(fillFor(tree.obj.id));
    try f.list.append(fillFor(tree.chrome.id));

    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    layer.overlay_z = 31000;
    try testing.expectEqual(@as(?usize, 0), layer.insertPoint(tree.canvas, f.host(tree.root)));
}

test "insertPoint ②：静态内容为空但有叠加 ⇒ 插到第一个叠加之前" {
    var f = Fixture.init();
    defer f.deinit();
    const tree = try buildTree(testing.allocator);
    defer freeTree(testing.allocator, tree.root);

    // Canvas static all downgrade to batch, only interactive remains (selected). Doc order chrome
    // after canvas subtree: [overlay, chrome].
    try f.list.append(fillFor(tree.overlay.id));
    try f.list.append(fillFor(tree.chrome.id));

    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    layer.overlay_z = 31000;
    // Insert before first overlay (idx 0) => batch doesn't reach selection handles/size labels.
    try testing.expectEqual(@as(?usize, 0), layer.insertPoint(tree.canvas, f.host(tree.root)));
}

test "insertPoint ③：锚点子树零 item ⇒ 退到锚点之后兄弟的第一个 item 之前" {
    var f = Fixture.init();
    defer f.deinit();
    const tree = try buildTree(testing.allocator);
    defer freeTree(testing.allocator, tree.root);

    // Canvas small to all-batch exactly this tier: canvas subtree zero items.
    try f.list.append(fillFor(tree.chrome.id));

    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    // No overlay threshold still hits 3 (overlay_ids empty => 1/2 direct fail).
    try testing.expectEqual(@as(?usize, 0), layer.insertPoint(tree.canvas, f.host(tree.root)));
}

test "insertPoint 三级全落空（锚点后无任何内容）才返回 null" {
    var f = Fixture.init();
    defer f.deinit();
    const tree = try buildTree(testing.allocator);
    defer freeTree(testing.allocator, tree.root);

    // Nothing after root => null = tail-append, equivalent to correct point.
    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    try testing.expectEqual(@as(?usize, null), layer.insertPoint(tree.canvas, f.host(tree.root)));
}

test "insertPoint 用 header() 认全部 item 种类（不只 fill/stroke/text）" {
    var f = Fixture.init();
    defer f.deinit();
    const tree = try buildTree(testing.allocator);
    defer freeTree(testing.allocator, tree.root);

    // Chrome only emits image_quad (once-missed by three-pick switch => 3 can't find landmark).
    try f.list.append(.{ .image_quad = .{
        .header = .{ .transform_id = 0, .clip_id = display_list_mod.INVALID_ID, .node_id = tree.chrome.id },
        .x = 0,
        .y = 0,
        .w = 4,
        .h = 4,
        .texture_id = 0,
    } });

    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    try testing.expectEqual(@as(?usize, 0), layer.insertPoint(tree.canvas, f.host(tree.root)));
}

test "insertPoint 跳过控制 token（scroll-clip 带真实 node_id 也不算内容）" {
    var f = Fixture.init();
    defer f.deinit();
    const tree = try buildTree(testing.allocator);
    defer freeTree(testing.allocator, tree.root);

    // Paint pass end scroll-clip pair lands at list end with obj node_id: counting as "last
    // static item" makes insertion point cross all chrome.
    try f.list.append(fillFor(tree.obj.id));
    try f.list.append(.{ .push_clip = .{
        .header = .{ .transform_id = 0, .clip_id = display_list_mod.INVALID_ID, .node_id = tree.obj.id },
        .x = 0,
        .y = 0,
        .w = 8,
        .h = 8,
    } });
    try f.list.append(.{ .pop_clip = .{
        .header = .{ .transform_id = 0, .clip_id = display_list_mod.INVALID_ID, .node_id = tree.obj.id },
    } });
    try f.list.append(fillFor(tree.chrome.id));

    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    // Token excluded => last_static=0 => at=1; chrome-after token uninvolved.
    try testing.expectEqual(@as(?usize, 1), layer.insertPoint(tree.canvas, f.host(tree.root)));
}

test "collectItemZ：z 继承（容器 z=3 的子节点归 3，自身显式才另起）" {
    var f = Fixture.init();
    defer f.deinit();
    const a = testing.allocator;
    const tree = try buildTree(a);
    // holder hung in canvas subtree => root.destroy recursively frees, can't destroy alone.
    defer freeTree(a, tree.root);

    // Container z=3, two children: one unset z (should inherit 3), one z=7.
    const holder = try node_mod.Node.create(a, 6, .box, .{});
    try setZ(a, holder, 3);
    const plain_child = try node_mod.Node.create(a, 7, .box, .{});
    const z_child = try node_mod.Node.create(a, 8, .box, .{});
    try setZ(a, z_child, 7);
    try holder.appendChild(a, plain_child);
    try holder.appendChild(a, z_child);
    try tree.canvas.appendChild(a, holder);

    try f.list.append(fillFor(plain_child.id));
    try f.list.append(fillFor(z_child.id));

    var item_z: std.ArrayListUnmanaged(?i16) = .empty;
    defer item_z.deinit(f.arena.allocator());
    try BulkQuadLayer.collectItemZ(tree.canvas, f.host(tree.root), &item_z, f.arena.allocator());

    // Node outside anchor subtree (chrome) null unowned; inheritance plain_child=3, z_child=7.
    try testing.expectEqual(@as(?i16, 3), item_z.items[0]);
    try testing.expectEqual(@as(?i16, 7), item_z.items[1]);
}

test "appendSegmented：z 归并按 z 升序，同 z 时 Node 在前" {
    var f = Fixture.init();
    defer f.deinit();
    const tree = try buildTree(testing.allocator);
    defer freeTree(testing.allocator, tree.root);
    // Anchored semantics must find anchor runtime, else append entire layer degraded skip.
    try f.registerRuntime(tree.canvas, display_list_mod.INVALID_ID);

    // One z=50 Node; batch has z=10 (green) and z=90 (blue) segments. Correct order must be
    // green -> Node -> blue.
    try setZ(testing.allocator, tree.obj, 50);
    try f.list.append(fillFor(tree.obj.id));

    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    layer.anchor = tree.canvas;
    try layer.quads.appendSlice(testing.allocator, &.{
        .{ .x = 0, .y = 0, .w = 4, .h = 4, .color = Color.hex(0x00FF00), .z_index = 10 },
        .{ .x = 0, .y = 0, .w = 4, .h = 4, .color = Color.hex(0x0000FF), .z_index = 90 },
    });

    try layer.append(f.host(tree.root));

    var gi: ?usize = null;
    var ri: ?usize = null;
    var bi: ?usize = null;
    for (f.list.items.items, 0..) |it, idx| {
        switch (it) {
            .fill_rect => |fr| {
                if (std.meta.eql(fr.color, Color.hex(0x00FF00))) gi = idx;
                if (std.meta.eql(fr.color, Color.hex(0xFF00FF))) ri = idx;
                if (std.meta.eql(fr.color, Color.hex(0x0000FF))) bi = idx;
            },
            else => {},
        }
    }
    try testing.expect(gi != null and ri != null and bi != null);
    try testing.expect(gi.? < ri.?); // z=10 batch item under z=50 Node.
    try testing.expect(ri.? < bi.?); // z=90 batch item over z=50 Node.
}

test "appendSegmented：同 z 段内保持提交顺序（后者盖前者）" {
    var f = Fixture.init();
    defer f.deinit();
    const tree = try buildTree(testing.allocator);
    defer freeTree(testing.allocator, tree.root);
    try f.registerRuntime(tree.canvas, display_list_mod.INVALID_ID);

    try f.list.append(fillFor(tree.obj.id));

    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    layer.anchor = tree.canvas;
    try layer.quads.appendSlice(testing.allocator, &.{
        .{ .x = 0, .y = 0, .w = 4, .h = 4, .color = Color.hex(0x111111), .z_index = 5 },
        .{ .x = 0, .y = 0, .w = 4, .h = 4, .color = Color.hex(0x222222), .z_index = 5 },
    });
    try layer.append(f.host(tree.root));

    var first_idx: ?usize = null;
    var second_idx: ?usize = null;
    for (f.list.items.items, 0..) |it, idx| {
        switch (it) {
            .fill_rect => |fr| {
                if (std.meta.eql(fr.color, Color.hex(0x111111))) first_idx = idx;
                if (std.meta.eql(fr.color, Color.hex(0x222222))) second_idx = idx;
            },
            else => {},
        }
    }
    try testing.expect(first_idx != null and second_idx != null);
    try testing.expect(first_idx.? < second_idx.?);
}

test "appendSegmented：尾部落位后不再追加（不越过 chrome）" {
    var f = Fixture.init();
    defer f.deinit();
    const tree = try buildTree(testing.allocator);
    defer freeTree(testing.allocator, tree.root);

    // Chrome is anchor post-sibling; z=90 segment later than any subtree Node, must land
    // before chrome, not skip past and reappend.
    try f.registerRuntime(tree.canvas, display_list_mod.INVALID_ID);
    try f.list.append(fillFor(tree.obj.id));
    try f.list.append(fillFor(tree.chrome.id));

    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    layer.anchor = tree.canvas;
    try layer.quads.appendSlice(testing.allocator, &.{
        .{ .x = 0, .y = 0, .w = 4, .h = 4, .color = Color.hex(0x00FF00), .z_index = 90 },
    });
    try layer.append(f.host(tree.root));

    var gi: ?usize = null;
    var ci: ?usize = null;
    var green_count: usize = 0;
    for (f.list.items.items, 0..) |it, idx| {
        switch (it) {
            .fill_rect => |fr| {
                if (std.meta.eql(fr.color, Color.hex(0x00FF00))) {
                    gi = idx;
                    green_count += 1;
                }
                if (fr.header.node_id == tree.chrome.id) ci = idx;
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 1), green_count); // Don't reappend second time.
    try testing.expect(gi != null and ci != null);
    try testing.expect(gi.? < ci.?); // Chrome still covers batch.
}

test "append：锚点为 null 时降级为末尾追加且不带裁剪" {
    var f = Fixture.init();
    defer f.deinit();

    try f.list.append(fillFor(1));

    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    layer.anchor = null; // Full-screen overlay semantics.
    try layer.quads.appendSlice(testing.allocator, &.{
        .{ .x = 5, .y = 6, .w = 7, .h = 8, .color = Color.hex(0x00FF00) },
    });
    try layer.append(f.host(null));

    try testing.expectEqual(@as(usize, 2), f.list.items.items.len);
    const last = f.list.items.items[1].fill_rect;
    try testing.expectEqual(@as(f32, 5), last.x);
    try testing.expectEqual(@as(u32, 0), last.header.node_id); // No anchor => node_id 0.
    try testing.expectEqual(display_list_mod.INVALID_ID, last.header.clip_id); // Unclipped.
    try testing.expectEqual(@as(u32, 0), last.header.transform_id); // identity
}

test "append：锚点子树零 item 时仍插在 chrome 之下（三级定位的 ③）" {
    var f = Fixture.init();
    defer f.deinit();
    const tree = try buildTree(testing.allocator);
    defer freeTree(testing.allocator, tree.root);

    try f.registerRuntime(tree.canvas, display_list_mod.INVALID_ID);
    try f.list.append(fillFor(tree.chrome.id));

    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    layer.anchor = tree.canvas;
    try layer.quads.appendSlice(testing.allocator, &.{
        .{ .x = 0, .y = 0, .w = 4, .h = 4, .color = Color.hex(0x00FF00) },
    });
    try layer.append(f.host(tree.root));

    var bulk_idx: ?usize = null;
    var chrome_idx: ?usize = null;
    for (f.list.items.items, 0..) |it, idx| {
        switch (it) {
            .fill_rect => |fr| {
                if (fr.header.node_id == tree.canvas.id) bulk_idx = idx;
                if (fr.header.node_id == tree.chrome.id) chrome_idx = idx;
            },
            else => {},
        }
    }
    try testing.expect(bulk_idx != null and chrome_idx != null);
    try testing.expect(bulk_idx.? < chrome_idx.?);
}

test "append：clip_rect 建按矩形寻址的 ClipNode，同帧同矩形只建一个" {
    var f = Fixture.init();
    defer f.deinit();
    const tree = try buildTree(testing.allocator);
    defer freeTree(testing.allocator, tree.root);

    // Anchor clip = 7 (arbitrary): ClipNode parent must hang it, clip_rect with anchor clip
    // intersection semantics hold (see BulkClipCache.headerFor).
    try f.registerRuntime(tree.canvas, 7);
    try f.list.append(fillFor(tree.chrome.id));

    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    layer.anchor = tree.canvas;
    const clip = [4]f32{ 1, 2, 3, 4 };
    try layer.quads.appendSlice(testing.allocator, &.{
        .{ .x = 0, .y = 0, .w = 4, .h = 4, .color = Color.hex(0x00FF00), .clip_rect = clip },
        .{ .x = 8, .y = 8, .w = 4, .h = 4, .color = Color.hex(0x00FF00), .clip_rect = clip },
    });
    const clips_before = f.tree.clips.items.len;
    try layer.append(f.host(tree.root));

    var bulk_clip_ids: [2]u32 = .{ 0, 0 };
    var bulk_n: usize = 0;
    var chrome_clip: u32 = 0;
    for (f.list.items.items) |it| {
        switch (it) {
            .fill_rect => |fr| {
                if (fr.header.node_id == tree.canvas.id) {
                    bulk_clip_ids[bulk_n] = fr.header.clip_id;
                    bulk_n += 1;
                } else chrome_clip = fr.header.clip_id;
            },
            else => {},
        }
    }
    // Batch layer indeed emitted two quads (else assertion void-passes below).
    try testing.expectEqual(@as(usize, 2), bulk_n);
    try testing.expect(bulk_clip_ids[0] != display_list_mod.INVALID_ID);
    // Same rect = one ClipNode, both quads share same clip_id.
    try testing.expectEqual(bulk_clip_ids[0], bulk_clip_ids[1]);
    try testing.expectEqual(@as(usize, clips_before + 1), f.tree.clips.items.len);
    const node = f.tree.clips.items[bulk_clip_ids[0]];
    try testing.expectEqual(@as(f32, 1), node.local_rect.x);
    try testing.expectEqual(@as(f32, 2), node.local_rect.y);
    try testing.expectEqual(@as(f32, 3), node.local_rect.w);
    try testing.expectEqual(@as(f32, 4), node.local_rect.h);
    // New ClipNode parent hangs anchor clip => chained emit = anchor clip AND quad clip.
    try testing.expectEqual(@as(u32, 7), node.parent);
    // Chrome item unaffected (hand-rolled still unclipped).
    try testing.expectEqual(display_list_mod.INVALID_ID, chrome_clip);
}

test "set：空切片关闭该层并保留容量；quads 被拷贝可立即复用" {
    var f = Fixture.init();
    defer f.deinit();

    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    const src = [_]BulkQuad{.{ .x = 1, .y = 2, .w = 3, .h = 4, .color = Color.hex(0xABCDEF) }};
    try layer.set(f.host(null), null, &src, null);
    try testing.expectEqual(@as(usize, 1), layer.quads.items.len);

    // Modify source array after submit doesn't affect copy inside layer.
    var mutated = src;
    mutated[0].x = 99;
    try testing.expectEqual(@as(f32, 1), layer.quads.items[0].x);

    try layer.set(f.host(null), null, &.{}, null);
    try testing.expectEqual(@as(usize, 0), layer.quads.items.len);
    try testing.expect(layer.quads.capacity > 0); // Retain capacity, avoid repeated realloc.
}

test "setVersioned：同版本 ⇒ unchanged，换版本 / 传 null ⇒ 保守重画" {
    var f = Fixture.init();
    defer f.deinit();

    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    const q = [_]BulkQuad{.{ .x = 0, .y = 0, .w = 4, .h = 4, .color = Color.hex(0x00FF00) }};

    // First submit: no prior frame version => same=false.
    try layer.setVersioned(f.host(null), null, &q, null, 7);
    try testing.expect(!layer.unchanged);
    // Same version again => unchanged=true (clean-frame fast path holds).
    try layer.setVersioned(f.host(null), null, &q, null, 7);
    try testing.expect(layer.unchanged);
    // Version changed => redraw.
    try layer.setVersioned(f.host(null), null, &q, null, 8);
    try testing.expect(!layer.unchanged);
    // Pass null = can't self-prove => degrade conservative redraw, version cleared.
    try layer.setVersioned(f.host(null), null, &q, null, null);
    try testing.expect(!layer.unchanged);
    try testing.expectEqual(@as(?u64, null), layer.version);
}

test "dropIfInsideSubtree：锚点在子树内 ⇒ 清锚点并关层；否则不动" {
    var f = Fixture.init();
    defer f.deinit();
    const tree = try buildTree(testing.allocator);
    defer freeTree(testing.allocator, tree.root);

    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    layer.anchor = tree.canvas;
    layer.overlay_z = 31000;
    try layer.quads.appendSlice(testing.allocator, &.{
        .{ .x = 0, .y = 0, .w = 4, .h = 4, .color = Color.hex(0x00FF00) },
    });

    // Anchor not in subtree (destroying chrome) => untouched.
    try testing.expect(!layer.dropIfInsideSubtree(tree.chrome));
    try testing.expect(layer.anchor == tree.canvas);
    try testing.expectEqual(@as(usize, 1), layer.quads.items.len);

    // Destroy canvas subtree itself => anchor cleared, layer disabled.
    try testing.expect(layer.dropIfInsideSubtree(tree.canvas));
    try testing.expect(layer.anchor == null);
    try testing.expectEqual(@as(?i16, null), layer.overlay_z);
    try testing.expectEqual(@as(usize, 0), layer.quads.items.len);
}

test "dropIfInsideSubtree：锚点是子树深处的后代也算" {
    var f = Fixture.init();
    defer f.deinit();
    const tree = try buildTree(testing.allocator);
    defer freeTree(testing.allocator, tree.root);

    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    // Anchor in obj (canvas grandchild), destroying entire canvas subtree.
    layer.anchor = tree.obj;
    try testing.expect(layer.dropIfInsideSubtree(tree.canvas));
    try testing.expect(layer.anchor == null);
}

test "BulkQuad.hasPerSideBorder" {
    var q = BulkQuad{ .x = 0, .y = 0, .w = 1, .h = 1, .color = Color.WHITE };
    try testing.expect(!q.hasPerSideBorder());
    q.border_widths = .{ 0, 1, 0, 0 };
    try testing.expect(q.hasPerSideBorder());
}

test "appendQuadItems：一条 quad 最多 MAX_ITEMS_PER_QUAD 个 item，顺序 投影→填充→描边→内阴影" {
    var out: std.ArrayListUnmanaged(DisplayItem) = .empty;
    defer out.deinit(testing.allocator);

    const q = BulkQuad{
        .x = 1,
        .y = 2,
        .w = 3,
        .h = 4,
        .color = Color.hex(0x00FF00),
        .border_color = Color.hex(0x000000),
        .border_width = 1.5,
        .shadow = .{ .color = Color.rgba(0, 0, 0, 80), .blur = 8 },
        .inset_shadow = .{ .color = Color.rgba(0, 0, 0, 80), .blur = 4 },
    };
    const header = ItemHeader{ .transform_id = 0, .node_id = 42 };
    try appendQuadItems(&out, testing.allocator, q, header);
    try testing.expectEqual(@as(usize, 4), out.items.len);
    try testing.expect(out.items[0] == .shadow_rect);
    try testing.expect(out.items[1] == .fill_rect);
    try testing.expect(out.items[2] == .stroke_rect);
    try testing.expect(out.items[3] == .inset_shadow_rect);
    // Inner shadow can't redraw bottom color (fill=TRANSPARENT, see comment).
    try testing.expect(std.meta.eql(Color.TRANSPARENT, out.items[3].inset_shadow_rect.fill));
}
