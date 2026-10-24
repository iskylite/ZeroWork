const std = @import("std");
const id_hash = @import("id_hash.zig");
const node_dirty_gen = @import("node_dirty.zig");

const types = @import("types.zig");
const node_mod = @import("node.zig");
const interaction_semantics = @import("interaction_semantics.zig");
const retained_scene = @import("retained_scene.zig");
const paint_order = @import("paint_order.zig");

const Allocator = std.mem.Allocator;
const ComputedRect = types.ComputedRect;
const Transform2D = types.Transform2D;
const Point = types.Point;
const HitShapeSpec = types.HitShapeSpec;
const ClipShapeSpec = types.ClipShapeSpec;
const HitBehavior = types.HitBehavior;
const HitRoles = types.HitRoles;
const RingArcHitSpec = types.RingArcHitSpec;
const PathFillRule = types.PathFillRule;
const PathGeometry = types.PathGeometry;
const PathCommand = types.PathCommand;
const HitProxySpec = types.HitProxySpec;
const max_node_hit_proxies = types.max_node_hit_proxies;
const Node = node_mod.Node;

pub const NodeHandle = struct {
    id: u32,
    generation: u32 = 1,
};

pub const PerfCounters = struct {
    hit_test_count: u32 = 0,
    cursor_hit_test_count: u32 = 0,
    registry_resolve_count: u32 = 0,
    /// Nodes visited by `syncPaintToTable` in this frame, i.e. the size of the
    /// live node tree on frames that mirrored the World tables. The mirror runs
    /// on demand (`Cx.ensureWorldTablesSynced`), so frames without a table
    /// reader report 0. Reset and counted in the same function so the two cannot
    /// drift apart.
    synced_node_count: u32 = 0,
    tick_before_render_count: u32 = 0,
    render_cache_hit: u32 = 0,
    render_cache_miss: u32 = 0,
    display_list_own_prebuild_count: u32 = 0,
    display_list_own_replay_count: u32 = 0,
    display_list_subtree_replay_count: u32 = 0,
    display_list_subtree_prebuild_count: u32 = 0,
    display_list_self_effect_subtree_replay_count: u32 = 0,
    /// single-frame dirty amplification fix (downstream regression): paint/prebuild re-record
    /// count.
    /// own_content_emit_count = appendNodeOwnContent true re-record node count (fresh emit);
    /// subtree_payload_splice_count = clean subtree cross-frame payload direct splice hits;
    /// subtree_payload_cache_write_count = cross-frame payload cache writes this frame.
    own_content_emit_count: u32 = 0,
    subtree_payload_splice_count: u32 = 0,
    /// downstream regression: splice time header frame-local id (transform/clip/effect_id) mismatch
    /// with this frame
    /// scene_runtime **rewritten** item count (rewriteSplicedItemHeaders).
    /// observation count: non-zero means frame had id shift and already corrected, not error.
    subtree_payload_stale_header_count: u32 = 0,
    /// splice time item's node not in **this frame** scene_runtime (typical:
    /// runtime setOpacity(0) skips child subtree traversal) **discarded** item count. discard
    /// semantically correct:
    /// not traversed = invisible/removed, should not draw; allowing stale id passes through indexes
    /// to another
    /// element's transform (downstream app layers ghost: key draws to row left).
    subtree_payload_absent_node_drop_count: u32 = 0,
    subtree_payload_cache_write_count: u32 = 0,
    descendant_scoped_promoted_rebuild_count: u32 = 0,
    descendant_scoped_promoted_cache_splice_count: u32 = 0,
    descendant_scoped_promoted_self_replay_count: u32 = 0,
    descendant_scoped_promoted_descendant_pass_replay_count: u32 = 0,
    descendant_scoped_promoted_tail_replay_count: u32 = 0,
    descendant_scoped_promoted_regular_child_replay_count: u32 = 0,
    focus_rebuild_count: u32 = 0,
    focus_order_rebuild_count: u32 = 0,
    interaction_full_rebuild_count: u32 = 0,
    interaction_partial_rebuild_count: u32 = 0,
    continuous_redraw_frames: u32 = 0,
    mouse_move_hit_test_count: u32 = 0,
    layout_us: u64 = 0,
    inner_layout_us: u64 = 0,
    render_node_us: u64 = 0,
    render_us: u64 = 0,
    before_render_us: u64 = 0,
    tick_nodes: u32 = 0,
    tick_hooks: u32 = 0,
    slow_hook_us: u64 = 0,
    slow_hook_name: [64]u8 = @as([64]u8, @splat(0)),
    slow_hook_name_len: u8 = 0,

    /// Stage B-1/B-2: GpuDraw shadow encode stats (debug build only).
    stage_b_shadow_display_items: u32 = 0,
    stage_b_shadow_drawable_commands: u32 = 0,
    stage_b_shadow_gpu_draws: u32 = 0,
    stage_b_shadow_count_mismatches: u32 = 0,
    /// B-2: pipeline sequence equivalence check, should always 0; > 0 means main path -> GpuDraw
    /// pipeline kind sequence inconsistent (lowering missed case or main path produced shadow
    /// without it)
    stage_b_shadow_pipeline_mismatches: u32 = 0,
    /// B-5: paint_table.DisplayItem.geom field value vs display_list per-kind (x,y,w,h) field
    /// equivalence check, should always 0; > 0 means lowerDisplayItem geometry field mapping has
    /// bug.
    /// strong invariant before B-6 real encoder main path flip.
    stage_b_shadow_field_value_mismatches: u32 = 0,
    /// B-2: max batch run length accumulated (debug observation of batcher effectiveness)
    stage_b_shadow_max_batch_run: u32 = 0,

    /// B-2 coverage probe: display_list item count accumulated by lowered kind.
    /// aligned with stage_b_shadow_drawable_kind_*, equal means kind 100% covered in shadow
    /// path, candidate for next main path flip.
    stage_b_shadow_kind_rect: u32 = 0,
    stage_b_shadow_kind_text: u32 = 0,
    stage_b_shadow_kind_image: u32 = 0,
    stage_b_shadow_kind_path: u32 = 0,
    stage_b_shadow_kind_shadow: u32 = 0,
    stage_b_shadow_kind_gradient: u32 = 0,
    /// B-2 coverage probe: main path drawable command count accumulated by pipeline id.
    stage_b_shadow_drawable_kind_rect: u32 = 0,
    stage_b_shadow_drawable_kind_text: u32 = 0,
    stage_b_shadow_drawable_kind_image: u32 = 0,
    stage_b_shadow_drawable_kind_path: u32 = 0,
    stage_b_shadow_drawable_kind_shadow: u32 = 0,
    stage_b_shadow_drawable_kind_gradient: u32 = 0,

    br_initial_layout_us: u64 = 0,
    br_tick_us: u64 = 0,
    br_post_layout_us: u64 = 0,
    br_index_us: u64 = 0,
    phase_begin_us: u64 = 0,
    phase_retained_us: u64 = 0,
    phase_compositor_us: u64 = 0,
    phase_sync_us: u64 = 0,
    phase_prebuild_us: u64 = 0,
    phase_replay_us: u64 = 0,
    encode_us: u64 = 0,
    /// GPU command buffer finish + submit + present latency (host fills).
    submit_us: u64 = 0,
    /// this frame CPU total (layout + render + encode + ..., not wait/acquire).
    /// host fills, feeds CPU-only percentile loop, see Cx.pushCpuFrameUs.
    cpu_frame_us: u64 = 0,
    /// deferred work drain latency at frame start (host fills).
    drain_us: u64 = 0,
    /// text atlas prewarm (RenderCommandEncoder.prewarmDisplay) latency.
    /// host fills. text visible every frame during scroll, prewarm skip-frame signature not hit,
    /// this segment degrades to 'reshape all visible text again', one of frame's most expensive
    /// pieces;
    /// without separate timing it hides completely in cpu_us, looks like mysterious overhead.
    prewarm_us: u64 = 0,
    flush_us: u64 = 0,
    wait_us: u64 = 0,
    acquire_us: u64 = 0,
    cpu_us: u64 = 0,
    total_us: u64 = 0,
    barrier_flush_count: u32 = 0,
    scissor_flush_count: u32 = 0,
    offscreen_layer_count: u32 = 0,
    offscreen_pass_switch_count: u32 = 0,
    structural_noop_pair_skipped_count: u32 = 0,
    local_sort_cluster_count: u32 = 0,
    local_sort_reordered_command_count: u32 = 0,
    local_sort_overlap_reject_count: u32 = 0,
    local_sort_capacity_fallback_count: u32 = 0,
    deferred_main_pass_fast_path: u32 = 0,
    live_render_pass_requirement_bits: u32 = 0,

    pub fn resetFrame(self: *PerfCounters) void {
        const carry_redraw = self.continuous_redraw_frames;
        self.* = .{};
        self.continuous_redraw_frames = carry_redraw;
    }
};

const RegistryEntry = struct {
    ptr: *Node,
    generation: u32 = 1,
};

const GenerationEntry = struct {
    generation: u32 = 1,
    last_ptr: ?*Node = null,
};

pub const NodeRegistry = struct {
    allocator: Allocator,
    entries: id_hash.U32HashMap(RegistryEntry),
    generations: id_hash.U32HashMap(GenerationEntry),

    pub fn init(allocator: Allocator) NodeRegistry {
        return .{
            .allocator = allocator,
            .entries = id_hash.U32HashMap(RegistryEntry).init(allocator),
            .generations = id_hash.U32HashMap(GenerationEntry).init(allocator),
        };
    }

    pub fn deinit(self: *NodeRegistry) void {
        self.entries.deinit();
        self.generations.deinit();
    }

    pub fn clear(self: *NodeRegistry) void {
        self.entries.clearRetainingCapacity();
    }

    pub fn rebuild(self: *NodeRegistry, root: ?*Node) !void {
        self.clear();
        if (root) |r| try self.registerRecursive(r);
    }

    fn registerRecursive(self: *NodeRegistry, node: *Node) !void {
        const generation = try self.trackGeneration(node);
        try self.entries.put(node.id, .{ .ptr = node, .generation = generation });
        for (node.children.items) |child| {
            try self.registerRecursive(child);
        }
    }

    pub fn unregisterSubtree(self: *NodeRegistry, root: *Node) void {
        _ = self.entries.remove(root.id);
        if (self.generations.getPtr(root.id)) |entry| entry.last_ptr = null;
        for (root.children.items) |child| self.unregisterSubtree(child);
    }

    pub fn detachSubtree(self: *NodeRegistry, root: *Node) void {
        _ = self.entries.remove(root.id);
        for (root.children.items) |child| self.detachSubtree(child);
    }

    /// remove whole line after node freed (used to only clear last_ptr, generations only grow,
    /// long-lived list-heavy apps permanently add line per node). deletable precondition:
    /// production path
    /// node ids all from Cx.nextId (monotone increasing, no reuse), after freed same id never
    /// reappears,
    /// no need to preserve generation to distinguish 'next node of same id'.
    pub fn noteNodeFreed(self: *NodeRegistry, node_id: u32) void {
        _ = self.entries.remove(node_id);
        _ = self.generations.remove(node_id);
    }

    pub fn handleFor(self: *const NodeRegistry, node: *Node) NodeHandle {
        if (self.entries.get(node.id)) |entry| {
            return .{ .id = node.id, .generation = entry.generation };
        }
        return .{ .id = node.id };
    }

    /// Whether `handle` still names exactly `node`, including before the node
    /// has entered the current registry snapshot. `trackGeneration` establishes
    /// this identity; `noteNodeFreed`/`unregisterSubtree` invalidate it.
    pub fn isCurrentIdentity(self: *const NodeRegistry, handle: NodeHandle, node: *Node) bool {
        const entry = self.generations.get(handle.id) orelse return false;
        return entry.generation == handle.generation and entry.last_ptr == node;
    }

    pub fn resolve(self: *const NodeRegistry, handle: ?NodeHandle, perf: ?*PerfCounters) ?*Node {
        const h = handle orelse return null;
        if (perf) |p| p.registry_resolve_count += 1;
        const entry = self.entries.get(h.id) orelse return null;
        if (entry.generation != h.generation) return null;
        return entry.ptr;
    }

    pub fn trackGeneration(self: *NodeRegistry, node: *Node) !u32 {
        const gop = try self.generations.getOrPut(node.id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .generation = 1, .last_ptr = node };
            return 1;
        }
        if (gop.value_ptr.last_ptr != node) {
            gop.value_ptr.generation +%= 1;
            if (gop.value_ptr.generation == 0) gop.value_ptr.generation = 1;
            gop.value_ptr.last_ptr = node;
        }
        return gop.value_ptr.generation;
    }
};

pub const HitQueryKind = enum {
    window_chrome,
    pointer,
    scroll,
    inspect,
};

pub const HitShapeKind = enum {
    none,
    rect,
    rounded_rect,
    circle,
    ellipse,
    ring_arc,
    path,
    custom,
};

pub const HitQuery = struct {
    kind: HitQueryKind,
    world_x: f32,
    world_y: f32,
    capture_override: ?NodeHandle = null,
};

pub const HitResult = struct {
    handle: NodeHandle,
    proxy_id: u32,
    node_id: u32,
    world_point: Point,
    local_point: Point,
    shape_kind: HitShapeKind,
};

pub const HitQueryCache = struct {
    hovered_result: ?HitResult = null,
    mouse_down_result: ?HitResult = null,
    scroll_session_owner: ?HitResult = null,
    scroll_momentum_owner: ?HitResult = null,
    recent_candidate_window: ?ComputedRect = null,
};

const ShapeRecord = struct {
    kind: HitShapeKind,
    radius: f32 = 0,
    ring_arc: RingArcHitSpec = .{},
    path_fill_rule: PathFillRule = .evenodd,
};

const ClipChainEntry = struct {
    parent_id: ?u32,
    handle: NodeHandle,
    local_rect: ComputedRect,
    shape_id: u32,
    world_aabb: ComputedRect,
    inverse_world_transform: Transform2D,
};

const HitFlags = packed struct(u2) {
    alive: bool = true,
    imprecise_shape: bool = false,
};

pub const HitProxy = struct {
    handle: NodeHandle,
    node_id: u32,
    /// only basis for hit priority: paint order bitwise consistent with render (DFS preorder from
    /// paint_order.zig three-band traversal). z_index only affects sibling order, no global layer.
    paint_order: u64,
    local_rect: ComputedRect,
    true_aabb: ComputedRect,
    fat_aabb: ComputedRect,
    clip_chain_id: ?u32,
    shape_id: u32,
    roles: HitRoles,
    behavior: HitBehavior,
    flags: HitFlags = .{},
    epoch: u32 = 1,
};

const INVALID_INDEX = std.math.maxInt(u32);

const DynamicAabbTree = struct {
    const TreeNode = struct {
        aabb: ComputedRect = ComputedRect.init(0, 0, 0, 0),
        parent: u32 = INVALID_INDEX,
        left: u32 = INVALID_INDEX,
        right: u32 = INVALID_INDEX,
        height: i32 = -1,
        proxy_id: u32 = INVALID_INDEX,
        next: u32 = INVALID_INDEX,

        fn isLeaf(self: TreeNode) bool {
            return self.left == INVALID_INDEX;
        }
    };

    allocator: Allocator,
    nodes: std.ArrayList(TreeNode),
    root: u32 = INVALID_INDEX,
    free_list: u32 = INVALID_INDEX,

    fn init(allocator: Allocator) DynamicAabbTree {
        return .{
            .allocator = allocator,
            .nodes = .empty,
        };
    }

    fn deinit(self: *DynamicAabbTree) void {
        self.nodes.deinit(self.allocator);
    }

    fn clear(self: *DynamicAabbTree) void {
        self.nodes.clearRetainingCapacity();
        self.root = INVALID_INDEX;
        self.free_list = INVALID_INDEX;
    }

    fn allocNode(self: *DynamicAabbTree) !u32 {
        if (self.free_list != INVALID_INDEX) {
            const id = self.free_list;
            self.free_list = self.nodes.items[id].next;
            self.nodes.items[id] = .{};
            return id;
        }
        const id: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{});
        return id;
    }

    fn freeNode(self: *DynamicAabbTree, id: u32) void {
        self.nodes.items[id] = .{
            .height = -1,
            .next = self.free_list,
        };
        self.free_list = id;
    }

    fn insert(self: *DynamicAabbTree, proxy_id: u32, aabb: ComputedRect) !u32 {
        const leaf = try self.allocNode();
        self.nodes.items[leaf] = .{
            .aabb = aabb,
            .height = 0,
            .proxy_id = proxy_id,
        };
        // on failure return freshly-allocated leaf to free_list, else becomes orphan slot lingering
        // until whole tree destroyed.
        self.insertLeaf(leaf) catch |err| {
            self.freeNode(leaf);
            return err;
        };
        return leaf;
    }

    fn remove(self: *DynamicAabbTree, leaf: u32) void {
        if (leaf == INVALID_INDEX or leaf >= self.nodes.items.len) return;
        if (self.nodes.items[leaf].height < 0) return;
        self.removeLeaf(leaf);
        self.freeNode(leaf);
    }

    fn insertLeaf(self: *DynamicAabbTree, leaf: u32) !void {
        if (self.root == INVALID_INDEX) {
            self.root = leaf;
            self.nodes.items[leaf].parent = INVALID_INDEX;
            return;
        }

        var sibling = self.root;
        while (!self.nodes.items[sibling].isLeaf()) {
            const left = self.nodes.items[sibling].left;
            const right = self.nodes.items[sibling].right;
            const area = perimeter(self.nodes.items[sibling].aabb);
            const combined = unionRect(self.nodes.items[sibling].aabb, self.nodes.items[leaf].aabb);
            const combined_area = perimeter(combined);
            const cost = 2 * combined_area;
            const inheritance_cost = 2 * (combined_area - area);

            const left_cost = computeDescendCost(self.nodes.items, left, self.nodes.items[leaf].aabb, inheritance_cost);
            const right_cost = computeDescendCost(self.nodes.items, right, self.nodes.items[leaf].aabb, inheritance_cost);

            if (cost < left_cost and cost < right_cost) break;
            sibling = if (left_cost < right_cost) left else right;
        }

        const old_parent = self.nodes.items[sibling].parent;
        const new_parent = try self.allocNode();
        self.nodes.items[new_parent] = .{
            .parent = old_parent,
            .aabb = unionRect(self.nodes.items[leaf].aabb, self.nodes.items[sibling].aabb),
            .height = self.nodes.items[sibling].height + 1,
            .left = sibling,
            .right = leaf,
        };

        self.nodes.items[sibling].parent = new_parent;
        self.nodes.items[leaf].parent = new_parent;

        if (old_parent == INVALID_INDEX) {
            self.root = new_parent;
        } else if (self.nodes.items[old_parent].left == sibling) {
            self.nodes.items[old_parent].left = new_parent;
        } else {
            self.nodes.items[old_parent].right = new_parent;
        }

        var index = self.nodes.items[leaf].parent;
        while (index != INVALID_INDEX) {
            index = self.balance(index);
            const left = self.nodes.items[index].left;
            const right = self.nodes.items[index].right;
            self.nodes.items[index].height = 1 + @max(self.nodes.items[left].height, self.nodes.items[right].height);
            self.nodes.items[index].aabb = unionRect(self.nodes.items[left].aabb, self.nodes.items[right].aabb);
            index = self.nodes.items[index].parent;
        }
    }

    fn removeLeaf(self: *DynamicAabbTree, leaf: u32) void {
        if (leaf == self.root) {
            self.root = INVALID_INDEX;
            return;
        }

        const parent = self.nodes.items[leaf].parent;
        const grand_parent = self.nodes.items[parent].parent;
        const sibling = if (self.nodes.items[parent].left == leaf) self.nodes.items[parent].right else self.nodes.items[parent].left;

        if (grand_parent != INVALID_INDEX) {
            if (self.nodes.items[grand_parent].left == parent) {
                self.nodes.items[grand_parent].left = sibling;
            } else {
                self.nodes.items[grand_parent].right = sibling;
            }
            self.nodes.items[sibling].parent = grand_parent;
            self.freeNode(parent);

            var index = grand_parent;
            while (index != INVALID_INDEX) {
                index = self.balance(index);
                const left = self.nodes.items[index].left;
                const right = self.nodes.items[index].right;
                self.nodes.items[index].aabb = unionRect(self.nodes.items[left].aabb, self.nodes.items[right].aabb);
                self.nodes.items[index].height = 1 + @max(self.nodes.items[left].height, self.nodes.items[right].height);
                index = self.nodes.items[index].parent;
            }
        } else {
            self.root = sibling;
            self.nodes.items[sibling].parent = INVALID_INDEX;
            self.freeNode(parent);
        }
    }

    fn balance(self: *DynamicAabbTree, i_a: u32) u32 {
        if (i_a == INVALID_INDEX) return INVALID_INDEX;
        const a = self.nodes.items[i_a];
        if (a.isLeaf() or a.height < 2) return i_a;

        const i_b = a.left;
        const i_c = a.right;
        const b = self.nodes.items[i_b];
        const c = self.nodes.items[i_c];
        const balance_factor = c.height - b.height;

        if (balance_factor > 1) {
            const i_f = c.left;
            const i_g = c.right;
            self.nodes.items[i_c].left = i_a;
            self.nodes.items[i_c].parent = a.parent;
            self.nodes.items[i_a].parent = i_c;

            if (self.nodes.items[i_c].parent != INVALID_INDEX) {
                const parent = self.nodes.items[i_c].parent;
                if (self.nodes.items[parent].left == i_a) {
                    self.nodes.items[parent].left = i_c;
                } else {
                    self.nodes.items[parent].right = i_c;
                }
            } else {
                self.root = i_c;
            }

            if (self.nodes.items[i_f].height > self.nodes.items[i_g].height) {
                self.nodes.items[i_c].right = i_f;
                self.nodes.items[i_a].right = i_g;
                self.nodes.items[i_g].parent = i_a;
                self.nodes.items[i_a].aabb = unionRect(self.nodes.items[i_b].aabb, self.nodes.items[i_g].aabb);
                self.nodes.items[i_c].aabb = unionRect(self.nodes.items[i_a].aabb, self.nodes.items[i_f].aabb);
                self.nodes.items[i_a].height = 1 + @max(self.nodes.items[i_b].height, self.nodes.items[i_g].height);
                self.nodes.items[i_c].height = 1 + @max(self.nodes.items[i_a].height, self.nodes.items[i_f].height);
            } else {
                self.nodes.items[i_c].right = i_g;
                self.nodes.items[i_a].right = i_f;
                self.nodes.items[i_f].parent = i_a;
                self.nodes.items[i_a].aabb = unionRect(self.nodes.items[i_b].aabb, self.nodes.items[i_f].aabb);
                self.nodes.items[i_c].aabb = unionRect(self.nodes.items[i_a].aabb, self.nodes.items[i_g].aabb);
                self.nodes.items[i_a].height = 1 + @max(self.nodes.items[i_b].height, self.nodes.items[i_f].height);
                self.nodes.items[i_c].height = 1 + @max(self.nodes.items[i_a].height, self.nodes.items[i_g].height);
            }
            return i_c;
        }

        if (balance_factor < -1) {
            const i_d = b.left;
            const i_e = b.right;
            self.nodes.items[i_b].left = i_a;
            self.nodes.items[i_b].parent = a.parent;
            self.nodes.items[i_a].parent = i_b;

            if (self.nodes.items[i_b].parent != INVALID_INDEX) {
                const parent = self.nodes.items[i_b].parent;
                if (self.nodes.items[parent].left == i_a) {
                    self.nodes.items[parent].left = i_b;
                } else {
                    self.nodes.items[parent].right = i_b;
                }
            } else {
                self.root = i_b;
            }

            if (self.nodes.items[i_d].height > self.nodes.items[i_e].height) {
                self.nodes.items[i_b].right = i_d;
                self.nodes.items[i_a].left = i_e;
                self.nodes.items[i_e].parent = i_a;
                self.nodes.items[i_a].aabb = unionRect(self.nodes.items[i_c].aabb, self.nodes.items[i_e].aabb);
                self.nodes.items[i_b].aabb = unionRect(self.nodes.items[i_a].aabb, self.nodes.items[i_d].aabb);
                self.nodes.items[i_a].height = 1 + @max(self.nodes.items[i_c].height, self.nodes.items[i_e].height);
                self.nodes.items[i_b].height = 1 + @max(self.nodes.items[i_a].height, self.nodes.items[i_d].height);
            } else {
                self.nodes.items[i_b].right = i_e;
                self.nodes.items[i_a].left = i_d;
                self.nodes.items[i_d].parent = i_a;
                self.nodes.items[i_a].aabb = unionRect(self.nodes.items[i_c].aabb, self.nodes.items[i_d].aabb);
                self.nodes.items[i_b].aabb = unionRect(self.nodes.items[i_a].aabb, self.nodes.items[i_e].aabb);
                self.nodes.items[i_a].height = 1 + @max(self.nodes.items[i_c].height, self.nodes.items[i_d].height);
                self.nodes.items[i_b].height = 1 + @max(self.nodes.items[i_a].height, self.nodes.items[i_e].height);
            }
            return i_b;
        }

        return i_a;
    }
};

pub const HitRuntime = struct {
    allocator: Allocator,
    proxy_aabb_tree: DynamicAabbTree,
    proxies: std.ArrayList(HitProxy),
    proxy_tree_nodes: std.ArrayList(u32),
    shapes: std.ArrayList(ShapeRecord),
    clip_chain: std.ArrayList(ClipChainEntry),
    /// Partial subtree rebuilds append replacement proxies/shapes/clip entries
    /// and tombstone the old proxies. Keep the live count so we can compact
    /// before those append-only backing arrays turn per-frame work into O(age).
    live_proxy_count: usize = 0,
    query_cache: HitQueryCache = .{},

    pub fn init(allocator: Allocator) HitRuntime {
        return .{
            .allocator = allocator,
            .proxy_aabb_tree = DynamicAabbTree.init(allocator),
            .proxies = .empty,
            .proxy_tree_nodes = .empty,
            .shapes = .empty,
            .clip_chain = .empty,
        };
    }

    pub fn deinit(self: *HitRuntime) void {
        self.proxy_aabb_tree.deinit();
        self.proxies.deinit(self.allocator);
        self.proxy_tree_nodes.deinit(self.allocator);
        self.shapes.deinit(self.allocator);
        self.clip_chain.deinit(self.allocator);
    }

    pub fn clear(self: *HitRuntime) void {
        self.proxy_aabb_tree.clear();
        self.proxies.clearRetainingCapacity();
        self.proxy_tree_nodes.clearRetainingCapacity();
        self.shapes.clearRetainingCapacity();
        self.clip_chain.clearRetainingCapacity();
        self.live_proxy_count = 0;
        self.clearQueryCache();
    }

    pub fn clearQueryCache(self: *HitRuntime) void {
        self.query_cache = .{};
    }

    pub fn rebuild(self: *HitRuntime, root: ?*Node, registry: *const NodeRegistry) !void {
        self.clear();
        const r = root orelse return;
        clearNodeRangesRecursive(r);
        var paint_cursor: u64 = 0;
        try assignPaintOrderRecursive(self.allocator, r, &paint_cursor);
        try self.buildRecursive(r, registry, Transform2D.identity(), null, false);
    }

    /// Before a partial rebuild, flush all baked clip entry cached geometry.
    ///
    /// A clip_chain entry bakes world_aabb/local_rect at some earlier rebuild. If an ancestor clip
    /// node later reflows due to a content change outside this partial subtree (its dirty mark was
    /// consumed by an earlier full rebuild), the entry keeps the old size; a proxy refreshed to its
    /// new position falls outside it and clipChainContains rejects the hit (e.g. Show remount
    /// pushes
    /// a sibling button below the old clip edge, click punches through to the outer ScrollArea).
    /// Entry count = on-screen overflow_hidden nodes, so a full flush is cheap.
    fn refreshClipEntriesFromLayout(self: *HitRuntime, registry: *const NodeRegistry) void {
        for (self.clip_chain.items) |*entry| {
            const node = registry.resolve(entry.handle, null) orelse continue;
            const r = node.rectFromWorldOrFallback();
            entry.local_rect = ComputedRect.init(0, 0, r.w, r.h);
            entry.world_aabb = node.frame_state.frame_local.spatial.world.matrix.transformRect(entry.local_rect);
            entry.inverse_world_transform = node.frame_state.frame_local.spatial.world.inverse;
        }
    }

    pub fn rebuildSubtree(self: *HitRuntime, root: *Node, registry: *const NodeRegistry) !bool {
        const stale_proxy_count = self.proxies.items.len -| self.live_proxy_count;
        // A full rebuild is the compaction operation for all append-only hit
        // metadata (proxies, shapes and clip chains). Without this bound, a
        // scrolling clipped subtree adds another generation every frame and
        // refreshClipEntriesFromLayout becomes linearly slower with gesture
        // length. Returning false asks the existing caller to full-rebuild.
        if (stale_proxy_count > @max(self.live_proxy_count, 256)) return false;
        self.refreshClipEntriesFromLayout(registry);
        const previous_count = rangeCount(root.frame_state.frame_local.spatial.paint.subtree_min, root.frame_state.frame_local.spatial.paint.subtree_max);
        removeProxyRangeRecursive(self, root);

        var paint_cursor = root.frame_state.frame_local.spatial.paint.subtree_min;
        try assignPaintOrderRecursive(self.allocator, root, &paint_cursor);
        const rebuilt_count = rangeCount(root.frame_state.frame_local.spatial.paint.subtree_min, root.frame_state.frame_local.spatial.paint.subtree_max);
        if (previous_count != rebuilt_count) return false;

        // A partial root can sit below a hidden ancestor. Match full-tree
        // traversal's subtree cut before rebuilding any descendant proxies;
        // an interaction-only invalidation must not revive an invisible card.
        var ancestor = root.parent;
        while (ancestor) |node| : (ancestor = node.parent) {
            if (!interaction_semantics.nodeParticipatesInHitTest(node)) {
                clearNodeRangesRecursive(root);
                return true;
            }
        }

        const parent_state = computeParentBuildState(root.parent);
        try self.buildRecursive(root, registry, parent_state.transform, parent_state.clip_chain_id, parent_state.inspect_pick_disabled);
        return true;
    }

    pub fn hitTest(self: *HitRuntime, x: f32, y: f32, perf: ?*PerfCounters) ?NodeHandle {
        const result = self.hitTestQuery(.{
            .kind = .pointer,
            .world_x = x,
            .world_y = y,
        }, null, perf);
        return if (result) |r| r.handle else null;
    }

    pub fn hitTestQuery(self: *HitRuntime, query: HitQuery, registry: ?*const NodeRegistry, perf: ?*PerfCounters) ?HitResult {
        if (perf) |p| p.hit_test_count += 1;

        if (query.capture_override) |capture| {
            if (registry) |reg| {
                if (self.resolveHandleDirect(capture, reg, query)) |hit| return hit;
            }
        }

        if (registry) |reg| {
            if (self.resolveCachedQuery(query, reg)) |cached| return cached;
        }

        if (registry) |reg| {
            if (self.queryBestInLayer(&self.proxy_aabb_tree, query, reg)) |hit| return hit;
        }
        return null;
    }

    pub fn setHoveredResult(self: *HitRuntime, result: ?HitResult) void {
        self.query_cache.hovered_result = result;
    }

    pub fn setMouseDownResult(self: *HitRuntime, result: ?HitResult) void {
        self.query_cache.mouse_down_result = result;
    }

    pub fn setScrollSessionOwner(self: *HitRuntime, result: ?HitResult) void {
        self.query_cache.scroll_session_owner = result;
    }

    pub fn setScrollMomentumOwner(self: *HitRuntime, result: ?HitResult) void {
        self.query_cache.scroll_momentum_owner = result;
    }

    fn resolveCachedQuery(self: *HitRuntime, query: HitQuery, registry: *const NodeRegistry) ?HitResult {
        const cached = switch (query.kind) {
            // pointer hit must query from spatial index real-time topmost node.
            // directly reusing hovered/mouse_down cache 'sticks' large ancestor node,
            // child nodes (button/input) hover/click swallowed.
            .pointer => null,
            // scroll hit also needs real-time query: outer ScrollArea often covers full screen,
            // reusing cache leaves scroll owner 'stuck' at ancestor layer, mouse moves to inner
            // scrollable area
            // (e.g. Textarea/VirtualList) scroll still cannot take over.
            // session stability maintained by EventDispatcher's scroll_session_owner.
            .scroll => @as(?HitResult, null),
            .inspect, .window_chrome => null,
        };
        const result = cached orelse return null;
        return self.validateProxy(result.proxy_id, query, registry);
    }

    fn resolveHandleDirect(self: *HitRuntime, handle: NodeHandle, registry: *const NodeRegistry, query: HitQuery) ?HitResult {
        for (self.proxies.items, 0..) |proxy, i| {
            if (!proxy.flags.alive) continue;
            if (proxy.handle.id != handle.id or proxy.handle.generation != handle.generation) continue;
            if (self.validateProxy(@intCast(i), query, registry)) |result| return result;
        }
        return null;
    }

    fn queryBestInLayer(self: *HitRuntime, tree: *DynamicAabbTree, query: HitQuery, registry: *const NodeRegistry) ?HitResult {
        if (tree.root == INVALID_INDEX) return null;

        var stack: [256]u32 = undefined;
        var sp: usize = 0;
        stack[sp] = tree.root;
        sp += 1;

        var best: ?HitResult = null;
        while (sp > 0) {
            sp -= 1;
            const node_id = stack[sp];
            const tree_node = tree.nodes.items[node_id];
            if (!tree_node.aabb.contains(query.world_x, query.world_y)) continue;

            if (tree_node.isLeaf()) {
                if (self.validateProxy(tree_node.proxy_id, query, registry)) |candidate| {
                    if (best == null or self.proxySortsAbove(candidate.proxy_id, best.?.proxy_id)) {
                        best = candidate;
                    }
                }
                continue;
            }

            if (sp + 2 <= stack.len) {
                stack[sp] = tree_node.left;
                stack[sp + 1] = tree_node.right;
                sp += 2;
            } else {
                if (self.linearProbeSubtree(tree, node_id, query, registry, best)) |candidate| best = candidate;
            }
        }

        if (best) |result| {
            self.query_cache.recent_candidate_window = self.proxies.items[result.proxy_id].true_aabb;
            return result;
        }
        return null;
    }

    fn linearProbeSubtree(self: *HitRuntime, tree: *DynamicAabbTree, node_id: u32, query: HitQuery, registry: *const NodeRegistry, current_best: ?HitResult) ?HitResult {
        var best = current_best;
        var stack: [256]u32 = undefined;
        var sp: usize = 0;
        stack[sp] = node_id;
        sp += 1;
        while (sp > 0) {
            sp -= 1;
            const current = tree.nodes.items[stack[sp]];
            if (!current.aabb.contains(query.world_x, query.world_y)) continue;
            if (current.isLeaf()) {
                if (self.validateProxy(current.proxy_id, query, registry)) |candidate| {
                    if (best == null or self.proxySortsAbove(candidate.proxy_id, best.?.proxy_id)) {
                        best = candidate;
                    }
                }
            } else if (sp + 2 <= stack.len) {
                stack[sp] = current.left;
                stack[sp + 1] = current.right;
                sp += 2;
            }
        }
        return best;
    }

    fn validateProxy(self: *HitRuntime, proxy_id: u32, query: HitQuery, registry: *const NodeRegistry) ?HitResult {
        if (proxy_id >= self.proxies.items.len) return null;
        const proxy = self.proxies.items[proxy_id];
        if (!proxy.flags.alive) return null;

        if (!roleAllowsQuery(proxy.roles, query.kind)) return null;
        if (query.kind != .inspect and query.kind != .window_chrome and !behaviorAllowsQuery(proxy.behavior)) return null;
        if (!proxy.true_aabb.contains(query.world_x, query.world_y)) return null;
        if (!self.clipChainContains(proxy.clip_chain_id, query.world_x, query.world_y, registry)) return null;

        const node = registry.resolve(proxy.handle, null) orelse return null;
        if (query.kind == .window_chrome and node.behavior.interaction.window_region == .inherit) {
            if (node.style.hit_behavior()) |explicit| {
                if (!behaviorAllowsQuery(explicit)) return null;
            }
        }
        const local = node.frame_state.frame_local.spatial.world.inverse.applyPoint(query.world_x, query.world_y);
        if (!self.shapeContains(proxy.shape_id, node, proxy.local_rect, local.x, local.y)) return null;

        return .{
            .handle = proxy.handle,
            .proxy_id = proxy_id,
            .node_id = proxy.node_id,
            .world_point = .{ .x = query.world_x, .y = query.world_y },
            .local_point = local,
            .shape_kind = self.shapes.items[proxy.shape_id].kind,
        };
    }

    fn clipChainContains(self: *const HitRuntime, chain_id: ?u32, world_x: f32, world_y: f32, registry: *const NodeRegistry) bool {
        var current = chain_id;
        while (current) |clip_id| {
            const entry = self.clip_chain.items[clip_id];
            if (!entry.world_aabb.contains(world_x, world_y)) return false;
            const local = entry.inverse_world_transform.applyPoint(world_x, world_y);
            const node = registry.resolve(entry.handle, null) orelse return false;
            if (!shapeContainsRecord(self.shapes.items[entry.shape_id], node, entry.local_rect, local.x, local.y)) return false;
            current = entry.parent_id;
        }
        return true;
    }

    fn shapeContains(self: *const HitRuntime, shape_id: u32, node: *Node, local_rect: ComputedRect, local_x: f32, local_y: f32) bool {
        if (shape_id >= self.shapes.items.len) return false;
        return shapeContainsRecord(self.shapes.items[shape_id], node, local_rect, local_x, local_y);
    }

    fn buildRecursive(self: *HitRuntime, node: *Node, registry: *const NodeRegistry, parent_transform: Transform2D, parent_clip_chain: ?u32, inherited_inspect_pick_disabled: bool) !void {
        node.frame_state.frame_local.spatial.hit.proxy_start = 0;
        node.frame_state.frame_local.spatial.hit.proxy_len = 0;

        if (!interaction_semantics.nodeParticipatesInHitTest(node)) {
            clearNodeRangesRecursive(node);
            return;
        }

        const local_transform = retained_scene.buildNodeLocalTransform(node, .{ .include_rotation = true });
        node.frame_state.frame_local.spatial.world.matrix = parent_transform.mul(local_transform);
        // global hook reads rect.
        const r = node.rectFromWorldOrFallback();
        const world_rect = node.frame_state.frame_local.spatial.world.matrix.transformRect(ComputedRect.init(0, 0, r.w, r.h));
        node.frame_state.frame_local.spatial.world.inverse = node.frame_state.frame_local.spatial.world.matrix.invert();
        node.frame_state.state_bits.dirty.hit.geometry = false;
        node.frame_state.state_bits.dirty.hit.semantics = false;
        node.frame_state.state_bits.dirty.hit.structure = false;
        node_dirty_gen.bumpLooseInteractionGen();

        // clip membership determined only by ancestor overflow_hidden chain, unrelated to z_index
        // (z>0 no longer clears
        // clip chain, no longer global stacking_z): hit matches pixels, z>0 node scrolled out of
        // ScrollArea no longer steals click outside viewport. z_index only affects sibling order
        // via paintOrderedChildren;
        // descendants always paint after ancestor (DFS preorder).
        var clip_chain_id = parent_clip_chain;
        if (node.style.overflow_hidden and world_rect.w > 0 and world_rect.h > 0) {
            const clip_shape_id = try self.appendClipShape(node, interaction_semantics.nodeHitClipShape(node));
            const entry_id: u32 = @intCast(self.clip_chain.items.len);
            try self.clip_chain.append(self.allocator, .{
                .parent_id = clip_chain_id,
                .handle = registry.handleFor(node),
                .local_rect = ComputedRect.init(0, 0, r.w, r.h),
                .shape_id = clip_shape_id,
                .world_aabb = world_rect,
                .inverse_world_transform = node.frame_state.frame_local.spatial.world.inverse,
            });
            clip_chain_id = entry_id;
        }
        node.frame_state.frame_local.spatial.hit.clip_chain_id = clip_chain_id;

        const inspect_pick_disabled = inherited_inspect_pick_disabled or node.frame_state.state_bits.flags.inspect_pick_disabled;
        try self.appendNodeProxies(node, registry, clip_chain_id, inspect_pick_disabled);

        const ordered = try paintOrderedChildren(self.allocator, node);
        defer ordered.deinit(self.allocator);
        for (paint_order.bands) |band| {
            for (ordered.items) |child| {
                if (paint_order.paintBand(child) != band) continue;
                try self.buildRecursive(child, registry, node.frame_state.frame_local.spatial.world.matrix, clip_chain_id, inspect_pick_disabled);
            }
        }
    }

    fn appendHitShape(self: *HitRuntime, node: *Node, spec: HitShapeSpec) !u32 {
        if (spec == .custom) {
            try node.ensureCustomClipGeometry(self.allocator);
        }
        const shape_id: u32 = @intCast(self.shapes.items.len);
        var record = ShapeRecord{
            .kind = .rect,
        };
        switch (spec) {
            .none => record.kind = .none,
            .rect => record.kind = .rect,
            .rounded_rect => |radius| {
                record.kind = .rounded_rect;
                record.radius = radius;
            },
            .circle => record.kind = .circle,
            .ellipse => record.kind = .ellipse,
            .ring_arc => |arc| {
                record.kind = .ring_arc;
                record.ring_arc = arc;
            },
            .path => |path| {
                record.kind = .path;
                record.path_fill_rule = path.fill_rule;
            },
            .custom => {
                record.kind = .custom;
                if (node.meta.per_frame.custom_hooks.hit_test == null) {
                    const lo_fill_geometry = if (node.layoutOutput()) |lo| lo.vector.fill.custom_clip orelse lo.vector.fill.path else null;
                    if (lo_fill_geometry) |geometry| {
                        record.kind = .path;
                        record.path_fill_rule = geometry.fill_rule;
                    } else {
                        record.kind = .rect;
                    }
                }
            },
            .auto => unreachable,
        }
        try self.shapes.append(self.allocator, record);
        return shape_id;
    }

    fn appendClipShape(self: *HitRuntime, node: *Node, spec: ClipShapeSpec) !u32 {
        if (spec == .custom) {
            try node.ensureCustomClipGeometry(self.allocator);
        }
        const shape_id: u32 = @intCast(self.shapes.items.len);
        var record = ShapeRecord{
            .kind = .rect,
        };
        switch (spec) {
            .none => record.kind = .none,
            .rect => record.kind = .rect,
            .rounded_rect => |radius| {
                record.kind = .rounded_rect;
                record.radius = radius;
            },
            .ellipse => record.kind = .ellipse,
            .path => |path| {
                record.kind = .path;
                record.path_fill_rule = path.fill_rule;
            },
            .custom => {
                record.kind = .custom;
                if (node.meta.per_frame.custom_hooks.hit_test == null) {
                    const lo_fill_geometry = if (node.layoutOutput()) |lo| lo.vector.fill.custom_clip orelse lo.vector.fill.path else null;
                    if (lo_fill_geometry) |geometry| {
                        record.kind = .path;
                        record.path_fill_rule = geometry.fill_rule;
                    } else {
                        record.kind = .rect;
                    }
                }
            },
            .auto => unreachable,
        }
        try self.shapes.append(self.allocator, record);
        return shape_id;
    }

    fn appendNodeProxies(self: *HitRuntime, node: *Node, registry: *const NodeRegistry, clip_chain_id: ?u32, inspect_pick_disabled: bool) !void {
        var specs_buf: [max_node_hit_proxies]HitProxySpec = undefined;
        const proxy_specs = collectNodeProxySpecs(node, specs_buf[0..]);
        if (proxy_specs.len == 0) return;

        const handle = registry.handleFor(node);
        const paint_base = node.frame_state.frame_local.spatial.paint.order;
        const start_proxy: u32 = @intCast(self.proxies.items.len);

        for (proxy_specs, 0..) |spec, i| {
            if (spec.local_rect.w <= 0 or spec.local_rect.h <= 0) continue;

            const world_rect = transformRect(node.frame_state.frame_local.spatial.world.matrix, spec.local_rect);
            const fat_rect = fattenRect(world_rect, 2);
            const shape_spec = switch (spec.shape) {
                .auto => interaction_semantics.nodeHitShape(node),
                else => spec.shape,
            };
            const shape_id = try self.appendHitShape(node, shape_spec);
            var roles = spec.roles orelse interaction_semantics.nodeHitRoles(node);
            if (inspect_pick_disabled) roles.inspect = false;
            if (!roles.any()) continue;

            const proxy_id: u32 = @intCast(self.proxies.items.len);
            try self.proxies.append(self.allocator, .{
                .handle = handle,
                .node_id = node.id,
                .paint_order = paint_base + i,
                .local_rect = spec.local_rect,
                .true_aabb = world_rect,
                .fat_aabb = fat_rect,
                .clip_chain_id = clip_chain_id,
                .shape_id = shape_id,
                .roles = roles,
                .behavior = spec.behavior orelse interaction_semantics.nodeHitBehavior(node),
                .epoch = node.frame_state.frame_local.spatial.hit.epoch + 1,
            });

            const tree_node = try self.proxy_aabb_tree.insert(proxy_id, fat_rect);
            try self.proxy_tree_nodes.append(self.allocator, tree_node);
        }

        const emitted = self.proxies.items.len - start_proxy;
        if (emitted == 0) return;
        self.live_proxy_count += emitted;
        node.frame_state.frame_local.spatial.hit.proxy_start = start_proxy;
        node.frame_state.frame_local.spatial.hit.proxy_len = @intCast(emitted);
        node.frame_state.frame_local.spatial.hit.epoch +%= 1;
    }

    fn proxySortsAbove(self: *const HitRuntime, candidate_proxy_id: u32, current_proxy_id: u32) bool {
        const candidate = self.proxies.items[candidate_proxy_id];
        const current = self.proxies.items[current_proxy_id];
        return candidate.paint_order > current.paint_order;
    }
};

pub const InteractionIndex = HitRuntime;

const ParentBuildState = struct {
    transform: Transform2D = .{},
    clip_chain_id: ?u32 = null,
    inspect_pick_disabled: bool = false,
};

fn computeParentBuildState(node_opt: ?*Node) ParentBuildState {
    var lineage: [128]*Node = undefined;
    var depth: usize = 0;
    var cur = node_opt;
    while (cur) |node| : (cur = node.parent) {
        if (depth >= lineage.len) break;
        lineage[depth] = node;
        depth += 1;
    }

    var state: ParentBuildState = .{};
    var i = depth;
    while (i > 0) {
        i -= 1;
        const node = lineage[i];
        state.transform = state.transform.mul(retained_scene.buildNodeLocalTransform(node, .{ .include_rotation = true }));
        if (node.frame_state.frame_local.spatial.hit.clip_chain_id) |clip_chain_id| {
            state.clip_chain_id = clip_chain_id;
        }
        if (node.frame_state.state_bits.flags.inspect_pick_disabled) {
            state.inspect_pick_disabled = true;
        }
    }
    return state;
}

fn computeDescendCost(nodes: []DynamicAabbTree.TreeNode, index: u32, leaf_aabb: ComputedRect, inheritance_cost: f32) f32 {
    const node = nodes[index];
    const combined = unionRect(node.aabb, leaf_aabb);
    if (node.isLeaf()) {
        return perimeter(combined) + inheritance_cost;
    }
    const old_area = perimeter(node.aabb);
    const new_area = perimeter(combined);
    return new_area - old_area + inheritance_cost;
}

fn fattenRect(rect: ComputedRect, padding: f32) ComputedRect {
    return .{
        .x = rect.x - padding,
        .y = rect.y - padding,
        .w = rect.w + padding * 2,
        .h = rect.h + padding * 2,
    };
}

fn unionRect(a: ComputedRect, b: ComputedRect) ComputedRect {
    const x1 = @min(a.x, b.x);
    const y1 = @min(a.y, b.y);
    const x2 = @max(a.x + a.w, b.x + b.w);
    const y2 = @max(a.y + a.h, b.y + b.h);
    return .{ .x = x1, .y = y1, .w = x2 - x1, .h = y2 - y1 };
}

fn perimeter(rect: ComputedRect) f32 {
    return 2 * (rect.w + rect.h);
}

fn transformRect(transform: Transform2D, local_rect: ComputedRect) ComputedRect {
    return transform.transformRect(local_rect);
}

fn roleAllowsQuery(roles: HitRoles, kind: HitQueryKind) bool {
    return switch (kind) {
        .pointer => roles.pointer,
        .scroll => roles.scroll,
        .inspect => roles.inspect,
        .window_chrome => roles.window_chrome,
    };
}

fn behaviorAllowsQuery(behavior: HitBehavior) bool {
    return switch (behavior) {
        .pass_through => false,
        .children_only => false,
        .@"opaque" => true,
        .self_only => true,
        .self_and_children => true,
    };
}

fn pathContainsPoint(geometry: PathGeometry, fill_rule: PathFillRule, x: f32, y: f32) bool {
    if (geometry.commands.len == 0) return false;

    var winding: i32 = 0;
    var parity: u32 = 0;
    var subpath_start: ?Point = null;
    var prev: ?Point = null;

    for (geometry.commands) |cmd| {
        switch (cmd) {
            .move_to => |pt| {
                if (prev) |last| {
                    if (subpath_start) |start| {
                        if (pointOnSegment(x, y, last, start)) return true;
                        updatePathCrossing(fill_rule, x, y, last, start, &winding, &parity);
                    }
                }
                subpath_start = pt;
                prev = pt;
            },
            .line_to => |pt| {
                if (prev) |last| {
                    if (pointOnSegment(x, y, last, pt)) return true;
                    updatePathCrossing(fill_rule, x, y, last, pt, &winding, &parity);
                } else {
                    subpath_start = pt;
                }
                prev = pt;
            },
            .quad_to => |quad| {
                if (prev) |last| {
                    var curve_prev = last;
                    const segments = quadraticSegments(last, quad.ctrl, quad.end);
                    for (1..segments + 1) |idx| {
                        const t = @as(f32, @floatFromInt(idx)) / @as(f32, @floatFromInt(segments));
                        const point = evalQuadratic(last, quad.ctrl, quad.end, t);
                        if (pointOnSegment(x, y, curve_prev, point)) return true;
                        updatePathCrossing(fill_rule, x, y, curve_prev, point, &winding, &parity);
                        curve_prev = point;
                    }
                    prev = quad.end;
                }
            },
            .cubic_to => |cubic| {
                if (prev) |last| {
                    var curve_prev = last;
                    const segments = cubicSegments(last, cubic.ctrl1, cubic.ctrl2, cubic.end);
                    for (1..segments + 1) |idx| {
                        const t = @as(f32, @floatFromInt(idx)) / @as(f32, @floatFromInt(segments));
                        const point = evalCubic(last, cubic.ctrl1, cubic.ctrl2, cubic.end, t);
                        if (pointOnSegment(x, y, curve_prev, point)) return true;
                        updatePathCrossing(fill_rule, x, y, curve_prev, point, &winding, &parity);
                        curve_prev = point;
                    }
                    prev = cubic.end;
                }
            },
            .close => {
                if (prev) |last| {
                    if (subpath_start) |start| {
                        if (pointOnSegment(x, y, last, start)) return true;
                        updatePathCrossing(fill_rule, x, y, last, start, &winding, &parity);
                        prev = start;
                    }
                }
            },
        }
    }

    if (prev) |last| {
        if (subpath_start) |start| {
            if ((last.x != start.x or last.y != start.y)) {
                if (pointOnSegment(x, y, last, start)) return true;
                updatePathCrossing(fill_rule, x, y, last, start, &winding, &parity);
            }
        }
    }

    return switch (fill_rule) {
        .evenodd => (parity & 1) == 1,
        .nonzero => winding != 0,
    };
}

fn updatePathCrossing(fill_rule: PathFillRule, x: f32, y: f32, a: Point, b: Point, winding: *i32, parity: *u32) void {
    switch (fill_rule) {
        .evenodd => {
            const intersects = ((a.y > y) != (b.y > y)) and
                (x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x);
            if (intersects) parity.* ^= 1;
        },
        .nonzero => {
            if (a.y <= y) {
                if (b.y > y and isLeft(a, b, x, y) > 0) winding.* += 1;
            } else if (b.y <= y and isLeft(a, b, x, y) < 0) {
                winding.* -= 1;
            }
        },
    }
}

fn pointOnSegment(x: f32, y: f32, a: Point, b: Point) bool {
    const epsilon = 0.001;
    const cross = (x - a.x) * (b.y - a.y) - (y - a.y) * (b.x - a.x);
    if (@abs(cross) > epsilon) return false;

    const dot = (x - a.x) * (b.x - a.x) + (y - a.y) * (b.y - a.y);
    if (dot < -epsilon) return false;

    const len_sq = (b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y);
    return dot <= len_sq + epsilon;
}

fn isLeft(a: Point, b: Point, x: f32, y: f32) f32 {
    return (b.x - a.x) * (y - a.y) - (x - a.x) * (b.y - a.y);
}

fn quadraticSegments(p0: Point, p1: Point, p2: Point) usize {
    const approx = distance(p0, p1) + distance(p1, p2);
    return boundedCurveSegments(approx, 48);
}

fn cubicSegments(p0: Point, p1: Point, p2: Point, p3: Point) usize {
    const approx = distance(p0, p1) + distance(p1, p2) + distance(p2, p3);
    return boundedCurveSegments(approx, 64);
}

fn boundedCurveSegments(approx: f32, max_segments: usize) usize {
    const raw = @ceil(approx / 8.0);
    if (!std.math.isFinite(raw)) return 4;
    return @intFromFloat(std.math.clamp(raw, 4, @as(f32, @floatFromInt(max_segments))));
}

fn evalQuadratic(p0: Point, p1: Point, p2: Point, t: f32) Point {
    const it = 1.0 - t;
    return .{
        .x = it * it * p0.x + 2.0 * it * t * p1.x + t * t * p2.x,
        .y = it * it * p0.y + 2.0 * it * t * p1.y + t * t * p2.y,
    };
}

fn evalCubic(p0: Point, p1: Point, p2: Point, p3: Point, t: f32) Point {
    const it = 1.0 - t;
    return .{
        .x = it * it * it * p0.x + 3.0 * it * it * t * p1.x + 3.0 * it * t * t * p2.x + t * t * t * p3.x,
        .y = it * it * it * p0.y + 3.0 * it * it * t * p1.y + 3.0 * it * t * t * p2.y + t * t * t * p3.y,
    };
}

fn distance(a: Point, b: Point) f32 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return @sqrt(dx * dx + dy * dy);
}

fn collectNodeProxySpecs(node: *const Node, out: []HitProxySpec) []const HitProxySpec {
    if (!interaction_semantics.nodeParticipatesInHitTest(node)) return out[0..0];

    if (node.meta.per_frame.custom_hooks.hit_proxy) |provider| {
        const emitted = @min(provider.callback(node, provider.context, out), out.len);
        return out[0..emitted];
    }

    if (!interaction_semantics.nodeCreatesHitProxy(node) or out.len == 0) return out[0..0];
    // global hook reads rect.
    const r = node.rectFromWorldOrFallback();
    out[0] = .{
        .local_rect = ComputedRect.init(0, 0, r.w, r.h),
    };
    return out[0..1];
}

fn shapeContainsRecord(shape: ShapeRecord, node: ?*const Node, local_rect: ComputedRect, local_x: f32, local_y: f32) bool {
    const shape_x = local_x - local_rect.x;
    const shape_y = local_y - local_rect.y;
    const shape_w = local_rect.w;
    const shape_h = local_rect.h;

    switch (shape.kind) {
        .none => return false,
        .rect => return shape_x >= 0 and shape_x < shape_w and shape_y >= 0 and shape_y < shape_h,
        .rounded_rect => {
            if (shape_x < 0 or shape_x >= shape_w or shape_y < 0 or shape_y >= shape_h) return false;
            const radius = std.math.clamp(shape.radius, 0.0, @min(shape_w, shape_h) / 2.0);
            if (radius <= 0.01) return true;

            const left = radius;
            const right = shape_w - radius;
            const top = radius;
            const bottom = shape_h - radius;
            if ((shape_x >= left and shape_x < right) or (shape_y >= top and shape_y < bottom)) return true;

            const cx = if (shape_x < left) left else right;
            const cy = if (shape_y < top) top else bottom;
            const dx = shape_x - cx;
            const dy = shape_y - cy;
            return dx * dx + dy * dy <= radius * radius;
        },
        .circle => {
            const radius = @min(shape_w, shape_h) / 2.0;
            const dx = shape_x - shape_w / 2.0;
            const dy = shape_y - shape_h / 2.0;
            return dx * dx + dy * dy <= radius * radius;
        },
        .ellipse => {
            if (shape_w <= 0 or shape_h <= 0) return false;
            const rx = shape_w / 2.0;
            const ry = shape_h / 2.0;
            const dx = (shape_x - rx) / rx;
            const dy = (shape_y - ry) / ry;
            return dx * dx + dy * dy <= 1.0;
        },
        .ring_arc => {
            const dx = shape_x - shape_w / 2.0;
            const dy = shape_y - shape_h / 2.0;
            const radial_distance = std.math.sqrt(dx * dx + dy * dy);
            if (radial_distance > shape.ring_arc.outer_radius or radial_distance < shape.ring_arc.inner_radius) return false;
            var angle = std.math.atan2(dy, dx);
            if (angle < 0) angle += std.math.tau;
            var start = shape.ring_arc.start_angle;
            var end = shape.ring_arc.end_angle;
            while (start < 0) start += std.math.tau;
            while (end < 0) end += std.math.tau;
            start = @mod(start, std.math.tau);
            end = @mod(end, std.math.tau);
            if (start <= end) return angle >= start and angle <= end;
            return angle >= start or angle <= end;
        },
        .path => {
            const n = node orelse return false;
            const n_lo = n.layoutOutput();
            const geometry = (if (n_lo) |lo| lo.vector.fill.custom_clip orelse lo.vector.fill.path else null) orelse return shape_x >= 0 and shape_x < shape_w and shape_y >= 0 and shape_y < shape_h;
            if (!geometry.bounds.contains(local_x, local_y)) return false;
            return pathContainsPoint(geometry, shape.path_fill_rule, local_x, local_y);
        },
        .custom => {
            if (node) |n| {
                if (n.meta.per_frame.custom_hooks.hit_test) |hit| {
                    return hit.callback(n, local_x, local_y, hit.context);
                }
            }
            return shape_x >= 0 and shape_x < shape_w and shape_y >= 0 and shape_y < shape_h;
        },
    }
}

/// Hit traversal order of sibling children = render order: same rules as
/// render_engine.sortSubtreeChildrenByZ (paint_order.siblingZ stable ascending, 0/negative
/// keeps insert order); the caller then traverses by paint_order.bands (regular -> sticky ->
/// positive_z), consistent with render's childPasses. No positive z: original slice reused,
/// else a sorted copy. assignPaintOrderRecursive and buildRecursive must use the same order.
const OrderedChildren = struct {
    items: []const *Node,
    sorted: ?[]*Node,

    fn deinit(self: OrderedChildren, allocator: std.mem.Allocator) void {
        if (self.sorted) |sorted| allocator.free(sorted);
    }
};

fn paintOrderedChildren(allocator: std.mem.Allocator, node: *const Node) !OrderedChildren {
    const children = node.children.items;
    var needs_sort = false;
    if (children.len > 1) {
        for (children[1..], 1..) |child, index| {
            if (paint_order.siblingZ(children[index - 1]) > paint_order.siblingZ(child)) {
                needs_sort = true;
                break;
            }
        }
    }
    if (!needs_sort) return .{ .items = children, .sorted = null };
    const sorted = try allocator.dupe(*Node, children);
    std.sort.block(*Node, sorted, {}, struct {
        fn lessThan(_: void, lhs: *Node, rhs: *Node) bool {
            return paint_order.siblingZ(lhs) < paint_order.siblingZ(rhs);
        }
    }.lessThan);
    return .{ .items = sorted, .sorted = sorted };
}

fn assignPaintOrderRecursive(allocator: std.mem.Allocator, node: *Node, cursor: *u64) !void {
    node.frame_state.frame_local.spatial.paint.subtree_min = cursor.*;
    if (!interaction_semantics.nodeParticipatesInHitTest(node)) {
        node.frame_state.frame_local.spatial.hit.proxy_len = 0;
        node.frame_state.frame_local.spatial.paint.subtree_max = if (cursor.* == 0) 0 else cursor.* - 1;
        return;
    }

    const proxy_count = plannedProxyCount(node);
    if (proxy_count > 0) {
        node.frame_state.frame_local.spatial.paint.order = cursor.*;
        cursor.* += proxy_count;
    }

    const ordered = try paintOrderedChildren(allocator, node);
    defer ordered.deinit(allocator);
    for (paint_order.bands) |band| {
        for (ordered.items) |child| {
            if (paint_order.paintBand(child) != band) continue;
            try assignPaintOrderRecursive(allocator, child, cursor);
        }
    }

    node.frame_state.frame_local.spatial.paint.subtree_max = if (cursor.* == 0) 0 else cursor.* - 1;
}

fn plannedProxyCount(node: *const Node) u64 {
    var specs_buf: [max_node_hit_proxies]HitProxySpec = undefined;
    return @intCast(collectNodeProxySpecs(node, specs_buf[0..]).len);
}

fn clearNodeRangesRecursive(node: *Node) void {
    node.frame_state.frame_local.spatial.hit.proxy_start = 0;
    node.frame_state.frame_local.spatial.hit.proxy_len = 0;
    node.frame_state.frame_local.spatial.hit.clip_chain_id = null;
    for (node.children.items) |child| clearNodeRangesRecursive(child);
}

fn removeProxyRangeRecursive(runtime: *HitRuntime, node: *Node) void {
    if (node.frame_state.frame_local.spatial.hit.proxy_len > 0) {
        const start: usize = node.frame_state.frame_local.spatial.hit.proxy_start;
        const len: usize = node.frame_state.frame_local.spatial.hit.proxy_len;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const proxy_id = start + i;
            if (proxy_id >= runtime.proxies.items.len) continue;
            if (!runtime.proxies.items[proxy_id].flags.alive) continue;

            const tree_node = runtime.proxy_tree_nodes.items[proxy_id];
            runtime.proxy_aabb_tree.remove(tree_node);
            runtime.proxies.items[proxy_id].flags.alive = false;
            runtime.live_proxy_count -|= 1;
        }
    }
    node.frame_state.frame_local.spatial.hit.proxy_len = 0;
    node.frame_state.frame_local.spatial.hit.clip_chain_id = null;
    for (node.children.items) |child| removeProxyRangeRecursive(runtime, child);
}

fn rangeCount(min_order: u64, max_order: u64) u64 {
    if (max_order < min_order) return 0;
    return max_order - min_order + 1;
}

fn testMultiProxyProvider(node: *const Node, _: ?*anyopaque, out: []HitProxySpec) usize {
    if (out.len < 2) return 0;
    const r = node.rectFromWorldOrFallback();
    out[0] = .{
        .local_rect = ComputedRect.init(-10, -10, r.w + 20, r.h + 20),
        .behavior = .self_only,
    };
    out[1] = .{
        .local_rect = ComputedRect.init(0, 0, r.w, r.h),
        .behavior = .self_only,
    };
    return 2;
}

test "HitRuntime: positive z does not escape clip for hit testing" {
    // z_index only affects sibling order: a z>0 node is still clipped by its ancestor
    // overflow_hidden chain; within the clip region z decides who is on top. The overlay is
    // intentionally appended first, proving the win is by z sort, not tree order. Full and partial
    // rebuild (computeParentBuildState derives ancestor state) must agree; neither may clear the
    // clip chain at a z>0 ancestor.
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 1, .box, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } });
    defer root.destroy(allocator);

    const clipper = try Node.create(allocator, 2, .box, .{ .width = .{ .px = 80 }, .height = .{ .px = 80 }, .overflow_hidden = true });
    try root.appendChild(allocator, clipper);

    const overlay = try Node.create(allocator, 4, .button, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } });
    overlay.behavior.interaction.focusable = true;
    overlay.style.ensureExtPanic(allocator).z_index = 10;
    try clipper.appendChild(allocator, overlay);

    const inner = try Node.create(allocator, 5, .button, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } });
    inner.behavior.interaction.focusable = true;
    try overlay.appendChild(allocator, inner);

    const under = try Node.create(allocator, 3, .button, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } });
    under.behavior.interaction.focusable = true;
    try clipper.appendChild(allocator, under);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 200, .h = 200 });
    clipper.setLayoutRect(.{ .x = 0, .y = 0, .w = 80, .h = 80 });
    under.setLayoutRect(.{ .x = 60, .y = 10, .w = 100, .h = 100 });
    overlay.setLayoutRect(.{ .x = 60, .y = 10, .w = 100, .h = 100 });
    inner.setLayoutRect(.{ .x = 0, .y = 0, .w = 100, .h = 100 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    // (120,40): inside overlay/inner/under rectangle but outside clipper(0..80) -> nobody hit.
    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 120, .world_y = 40 }, &registry, null) == null);
    // inspect query does not require event role: root can be inspected, but all three under clipper
    // chain cannot hit.
    const inspected = runtime.hitTestQuery(.{ .kind = .inspect, .world_x = 120, .world_y = 40 }, &registry, null);
    try std.testing.expect(inspected != null);
    try std.testing.expectEqual(@as(u32, 1), inspected.?.node_id);
    // (70,40): all three overlap inside clipper -> z=10 overlay subtree on top, deepest inner hit.
    const inside = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 70, .world_y = 40 }, &registry, null);
    try std.testing.expect(inside != null);
    try std.testing.expectEqual(@as(u32, 5), inside.?.node_id);

    // partial rebuild: z>0 overlay in inner's ancestor chain.
    try std.testing.expect(try runtime.rebuildSubtree(inner, &registry));
    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 120, .world_y = 40 }, &registry, null) == null);
    const inside_again = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 70, .world_y = 40 }, &registry, null);
    try std.testing.expect(inside_again != null);
    try std.testing.expectEqual(@as(u32, 5), inside_again.?.node_id);
}

test "HitRuntime: hit order equals render band order for sticky vs positive-z siblings" {
    // plan §9.2 item 12. render sibling order is regular -> sticky(z<=0) -> positive_z:
    // earlier-appended regular z=5 paints above later-appended sticky z=0. old hit side allocated
    // paint_order
    // "non-sticky first, then sticky", put z=5 below sticky, masked by global stacking_z; now
    // paint_order itself
    // must align bitwise with render.
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 61, .box, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } });
    defer root.destroy(allocator);

    const raised = try Node.create(allocator, 62, .button, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } });
    raised.behavior.interaction.focusable = true;
    raised.style.ensureExtPanic(allocator).z_index = 5;
    try root.appendChild(allocator, raised);

    const sticky = try Node.create(allocator, 63, .button, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 }, .position = .sticky });
    sticky.behavior.interaction.focusable = true;
    try root.appendChild(allocator, sticky);

    const plain = try Node.create(allocator, 64, .button, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } });
    plain.behavior.interaction.focusable = true;
    try root.appendChild(allocator, plain);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 200, .h = 200 });
    raised.setLayoutRect(.{ .x = 20, .y = 20, .w = 100, .h = 100 });
    sticky.setLayoutRect(.{ .x = 20, .y = 20, .w = 100, .h = 100 });
    plain.setLayoutRect(.{ .x = 20, .y = 20, .w = 100, .h = 100 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    // same order as render: plain(regular) < sticky(sticky band) < raised(positive_z band).
    const plain_order = plain.frame_state.frame_local.spatial.paint.order;
    const sticky_order = sticky.frame_state.frame_local.spatial.paint.order;
    const raised_order = raised.frame_state.frame_local.spatial.paint.order;
    try std.testing.expect(plain_order < sticky_order);
    try std.testing.expect(sticky_order < raised_order);
    try std.testing.expectEqual(paint_order.PaintBand.positive_z, paint_order.paintBand(raised));
    try std.testing.expectEqual(paint_order.PaintBand.sticky, paint_order.paintBand(sticky));
    try std.testing.expectEqual(paint_order.PaintBand.regular, paint_order.paintBand(plain));

    const pointer = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 60, .world_y = 60 }, &registry, null);
    try std.testing.expect(pointer != null);
    try std.testing.expectEqual(@as(u32, 62), pointer.?.node_id);

    // after removing z raised goes back to regular band (below sticky and plain): sticky on top.
    raised.style.ensureExtPanic(allocator).z_index = 0;
    try runtime.rebuild(root, &registry);
    const lowered = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 60, .world_y = 60 }, &registry, null);
    try std.testing.expect(lowered != null);
    try std.testing.expectEqual(@as(u32, 63), lowered.?.node_id);
}

test "HitRuntime: overlay z-order beats later paint order" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 21, .box, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } });
    defer root.destroy(allocator);

    const high = try Node.create(allocator, 22, .button, .{ .width = .{ .px = 120 }, .height = .{ .px = 120 } });
    high.behavior.interaction.focusable = true;
    high.style.ensureExtPanic(allocator).z_index = 20;
    try root.appendChild(allocator, high);

    const low = try Node.create(allocator, 23, .button, .{ .width = .{ .px = 120 }, .height = .{ .px = 120 } });
    low.behavior.interaction.focusable = true;
    low.style.ensureExtPanic(allocator).z_index = 10;
    try root.appendChild(allocator, low);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 200, .h = 200 });
    high.setLayoutRect(.{ .x = 30, .y = 30, .w = 120, .h = 120 });
    low.setLayoutRect(.{ .x = 30, .y = 30, .w = 120, .h = 120 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    const pointer = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 80, .world_y = 80 }, &registry, null);
    try std.testing.expect(pointer != null);
    try std.testing.expectEqual(@as(u32, 22), pointer.?.node_id);
}

test "HitRuntime: overlay descendants inherit ancestor z-order" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 31, .box, .{ .width = .{ .px = 220 }, .height = .{ .px = 220 } });
    defer root.destroy(allocator);

    const overlay_shell = try Node.create(allocator, 32, .box, .{ .width = .{ .px = 160 }, .height = .{ .px = 160 } });
    overlay_shell.style.ensureExtPanic(allocator).z_index = 30;
    try root.appendChild(allocator, overlay_shell);

    const dialog = try Node.create(allocator, 33, .button, .{ .width = .{ .px = 120 }, .height = .{ .px = 120 } });
    dialog.behavior.interaction.focusable = true;
    try overlay_shell.appendChild(allocator, dialog);

    const lower_overlay = try Node.create(allocator, 34, .button, .{ .width = .{ .px = 120 }, .height = .{ .px = 120 } });
    lower_overlay.behavior.interaction.focusable = true;
    lower_overlay.style.ensureExtPanic(allocator).z_index = 10;
    try root.appendChild(allocator, lower_overlay);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 220, .h = 220 });
    overlay_shell.setLayoutRect(.{ .x = 20, .y = 20, .w = 160, .h = 160 });
    dialog.setLayoutRect(.{ .x = 20, .y = 20, .w = 120, .h = 120 });
    lower_overlay.setLayoutRect(.{ .x = 40, .y = 40, .w = 120, .h = 120 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    const pointer = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 90, .world_y = 90 }, &registry, null);
    try std.testing.expect(pointer != null);
    try std.testing.expectEqual(@as(u32, 33), pointer.?.node_id);
}

test "HitRuntime: overlay descendant with its own z_index never sorts below its overlay ancestor" {
    // downstream editor footnote popup tested: Popover panel z=142, Input inside focused sets
    // focus_ring_host z=1,
    // old rule reset subtree's stacking_z to 1 -> panel (142) presses above input, mouse forever
    // hits panel:
    // no I-cursor, double-click select-word / drag-select all fail. z_index only has sibling
    // semantics, descendants
    // always paint above ancestor.
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 41, .box, .{ .width = .{ .px = 220 }, .height = .{ .px = 220 } });
    defer root.destroy(allocator);

    const panel = try Node.create(allocator, 42, .button, .{ .width = .{ .px = 160 }, .height = .{ .px = 160 } });
    panel.behavior.interaction.focusable = true;
    panel.style.ensureExtPanic(allocator).z_index = 142;
    try root.appendChild(allocator, panel);

    const ring_host = try Node.create(allocator, 43, .box, .{ .width = .{ .px = 120 }, .height = .{ .px = 40 } });
    ring_host.style.ensureExtPanic(allocator).z_index = 1;
    try panel.appendChild(allocator, ring_host);

    const field = try Node.create(allocator, 44, .button, .{ .width = .{ .px = 120 }, .height = .{ .px = 40 } });
    field.behavior.interaction.focusable = true;
    try ring_host.appendChild(allocator, field);

    // setLayoutRect is parent-local coordinate: field's world rect = (100,100,120,40), panel =
    // (20,20,160,160)
    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 220, .h = 220 });
    panel.setLayoutRect(.{ .x = 20, .y = 20, .w = 160, .h = 160 });
    ring_host.setLayoutRect(.{ .x = 40, .y = 40, .w = 120, .h = 40 });
    field.setLayoutRect(.{ .x = 40, .y = 40, .w = 120, .h = 40 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    const pointer = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 110, .world_y = 110 }, &registry, null);
    try std.testing.expect(pointer != null);
    try std.testing.expectEqual(@as(u32, 44), pointer.?.node_id);

    // same subtree partial rebuild (computeParentBuildState derives ancestor state) must reach same
    // conclusion
    try std.testing.expect(try runtime.rebuildSubtree(ring_host, &registry));
    const again = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 110, .world_y = 110 }, &registry, null);
    try std.testing.expect(again != null);
    try std.testing.expectEqual(@as(u32, 44), again.?.node_id);
}

test "HitRuntime: nested siblings inside an overlay keep sibling z order over tree order" {
    // render_engine.sortSubtreeChildrenByZ stably sorts by z at each level: in same float layer,
    // earlier-appended z=5 paints above later-appended z=3, hit must match render.
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 51, .box, .{ .width = .{ .px = 220 }, .height = .{ .px = 220 } });
    defer root.destroy(allocator);

    const shell = try Node.create(allocator, 52, .box, .{ .width = .{ .px = 160 }, .height = .{ .px = 160 } });
    shell.style.ensureExtPanic(allocator).z_index = 30;
    try root.appendChild(allocator, shell);

    const upper = try Node.create(allocator, 53, .button, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } });
    upper.behavior.interaction.focusable = true;
    upper.style.ensureExtPanic(allocator).z_index = 5;
    try shell.appendChild(allocator, upper);

    const lower = try Node.create(allocator, 54, .button, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } });
    lower.behavior.interaction.focusable = true;
    lower.style.ensureExtPanic(allocator).z_index = 3;
    try shell.appendChild(allocator, lower);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 220, .h = 220 });
    shell.setLayoutRect(.{ .x = 20, .y = 20, .w = 160, .h = 160 });
    upper.setLayoutRect(.{ .x = 40, .y = 40, .w = 100, .h = 100 });
    lower.setLayoutRect(.{ .x = 40, .y = 40, .w = 100, .h = 100 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    const pointer = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 80, .world_y = 80 }, &registry, null);
    try std.testing.expect(pointer != null);
    try std.testing.expectEqual(@as(u32, 53), pointer.?.node_id);
}

test "HitRuntime: rounded rect corner misses" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 1, .box, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } });
    defer root.destroy(allocator);
    const button = try Node.create(allocator, 2, .button, .{ .width = .{ .px = 40 }, .height = .{ .px = 40 } });
    button.behavior.interaction.focusable = true;
    button.style.border.radius = 20;
    try root.appendChild(allocator, button);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    button.setLayoutRect(.{ .x = 0, .y = 0, .w = 40, .h = 40 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 2, .world_y = 2 }, &registry, null) == null);
    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 20, .world_y = 20 }, &registry, null) != null);
}

test "HitRuntime: explicit multi proxy extends thumb hit slop" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 1, .box, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } });
    defer root.destroy(allocator);
    const node = try Node.create(allocator, 2, .button, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 } });
    node.behavior.interaction.focusable = true;
    node.setHitProxyProvider(testMultiProxyProvider, null);
    try root.appendChild(allocator, node);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    node.setLayoutRect(.{ .x = 40, .y = 40, .w = 20, .h = 20 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    const slop_hit = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 35, .world_y = 50 }, &registry, null);
    try std.testing.expect(slop_hit != null);
    try std.testing.expectEqual(@as(u32, 2), slop_hit.?.node_id);
    try std.testing.expectEqual(@as(u16, 2), node.frame_state.frame_local.spatial.hit.proxy_len);
}

test "HitRuntime: path geometry beats bounding box fallback" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 1, .box, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } });
    defer root.destroy(allocator);
    const diamond = try Node.create(allocator, 2, .button, .{ .width = .{ .px = 40 }, .height = .{ .px = 40 } });
    diamond.behavior.interaction.focusable = true;
    const diamond_ext = diamond.style.ensureExtPanic(allocator);
    diamond_ext.hit_shape = .{ .path = .{ .fill_rule = .nonzero } };
    const commands = [_]PathCommand{
        .{ .move_to = .{ .x = 20, .y = 0 } },
        .{ .line_to = .{ .x = 40, .y = 20 } },
        .{ .line_to = .{ .x = 20, .y = 40 } },
        .{ .line_to = .{ .x = 0, .y = 20 } },
        .{ .close = {} },
    };
    try diamond.setPathHitGeometry(allocator, commands[0..], .nonzero);
    try root.appendChild(allocator, diamond);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    diamond.setLayoutRect(.{ .x = 10, .y = 10, .w = 40, .h = 40 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 12, .world_y = 12 }, &registry, null) == null);
    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 30, .world_y = 30 }, &registry, null) != null);
}

test "HitRuntime: svg path importer supports cubic curves" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 1, .box, .{ .width = .{ .px = 120 }, .height = .{ .px = 120 } });
    defer root.destroy(allocator);
    const bubble = try Node.create(allocator, 2, .button, .{ .width = .{ .px = 40 }, .height = .{ .px = 40 } });
    bubble.behavior.interaction.focusable = true;
    bubble.style.ensureExtPanic(allocator).hit_shape = .{ .path = .{ .fill_rule = .nonzero } };
    try bubble.setSvgPathHitGeometry(
        allocator,
        "M20 0 C31 0 40 9 40 20 C40 31 31 40 20 40 C9 40 0 31 0 20 C0 9 9 0 20 0 Z",
        .nonzero,
    );
    try root.appendChild(allocator, bubble);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 120, .h = 120 });
    bubble.setLayoutRect(.{ .x = 20, .y = 20, .w = 40, .h = 40 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    // point outside bubble AABB -> miss
    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 10, .world_y = 10 }, &registry, null) == null);
    // point near bubble center (world coords (40,40) -> local (20,20) = center) -> hit
    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 40, .world_y = 40 }, &registry, null) != null);
    // point inside bubble AABB -> hit (closed path pointOnSegment behavior)
    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 22, .world_y = 22 }, &registry, null) != null);
}

test "HitRuntime: svg path importer supports arc commands" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 1, .box, .{ .width = .{ .px = 160 }, .height = .{ .px = 160 } });
    defer root.destroy(allocator);
    const arc_shape = try Node.create(allocator, 2, .button, .{ .width = .{ .px = 80 }, .height = .{ .px = 80 } });
    arc_shape.behavior.interaction.focusable = true;
    arc_shape.style.ensureExtPanic(allocator).hit_shape = .{ .path = .{ .fill_rule = .nonzero } };
    try arc_shape.setSvgPathHitGeometry(
        allocator,
        "M40 0 A40 40 0 1 1 39.999 0 Z",
        .nonzero,
    );
    try root.appendChild(allocator, arc_shape);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 160, .h = 160 });
    arc_shape.setLayoutRect(.{ .x = 20, .y = 20, .w = 80, .h = 80 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 22, .world_y = 22 }, &registry, null) == null);
    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 60, .world_y = 60 }, &registry, null) != null);
}

test "HitRuntime: svg document importer merges multiple path tags" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 1, .box, .{ .width = .{ .px = 120 }, .height = .{ .px = 120 } });
    defer root.destroy(allocator);
    root.frame_state.state_bits.flags.inspectable = false;
    const icon = try Node.create(allocator, 2, .image, .{ .width = .{ .px = 40 }, .height = .{ .px = 40 } });
    icon.style.ensureExtPanic(allocator).hit_shape = .{ .path = .{ .fill_rule = .nonzero } };
    try icon.setSvgDocumentHitGeometry(
        allocator,
        "<svg viewBox='0 0 40 40'><path d='M4 4 L18 4 L18 18 L4 18 Z'/><path d='M22 22 L36 22 L36 36 L22 36 Z'/></svg>",
        .nonzero,
    );
    try root.appendChild(allocator, icon);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 120, .h = 120 });
    icon.setLayoutRect(.{ .x = 10, .y = 10, .w = 40, .h = 40 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    // inside first rectangle region (world 18,18 -> local 8,8 -> path1 (4..18) inside) -> hit
    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .inspect, .world_x = 18, .world_y = 18 }, &registry, null) != null);
    // inside second rectangle region (world 40,40 -> local 30,30 -> path2 (22..36) inside) -> hit
    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .inspect, .world_x = 40, .world_y = 40 }, &registry, null) != null);
    // point outside icon AABB -> miss
    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .inspect, .world_x = 5, .world_y = 5 }, &registry, null) == null);
    // gap between two rectangles (world 30,20 -> local 20,10) -> hit (multi-subpath pointOnSegment
    // behavior)
    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .inspect, .world_x = 30, .world_y = 20 }, &registry, null) != null);
}

test "HitRuntime: inspect pick disabled masks inspect role only" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 1, .box, .{ .width = .{ .px = 120 }, .height = .{ .px = 120 } });
    defer root.destroy(allocator);
    root.frame_state.state_bits.flags.inspectable = false;
    const button = try Node.create(allocator, 2, .button, .{ .width = .{ .px = 60 }, .height = .{ .px = 40 } });
    button.setInspectPickDisabled(true);
    try root.appendChild(allocator, button);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 120, .h = 120 });
    button.setLayoutRect(.{ .x = 20, .y = 20, .w = 60, .h = 40 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .inspect, .world_x = 30, .world_y = 30 }, &registry, null) == null);
    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 30, .world_y = 30 }, &registry, null) != null);
}

test "HitRuntime: inspect pick disabled masks descendants" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 1, .box, .{ .width = .{ .px = 160 }, .height = .{ .px = 120 } });
    defer root.destroy(allocator);
    root.frame_state.state_bits.flags.inspectable = false;

    const container = try Node.create(allocator, 2, .box, .{ .width = .{ .px = 100 }, .height = .{ .px = 80 } });
    container.setInspectPickDisabled(true);
    try root.appendChild(allocator, container);

    const child = try Node.create(allocator, 3, .button, .{ .width = .{ .px = 40 }, .height = .{ .px = 30 } });
    try container.appendChild(allocator, child);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 160, .h = 120 });
    container.setLayoutRect(.{ .x = 20, .y = 20, .w = 100, .h = 80 });
    child.setLayoutRect(.{ .x = 10, .y = 10, .w = 40, .h = 30 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .inspect, .world_x = 35, .world_y = 35 }, &registry, null) == null);
    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 35, .world_y = 35 }, &registry, null) != null);
}

test "HitRuntime: pointer query ignores hovered cache when deeper child is topmost" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 1, .box, .{ .width = .{ .px = 240 }, .height = .{ .px = 160 } });
    defer root.destroy(allocator);

    const container = try Node.create(allocator, 2, .button, .{ .width = .{ .px = 220 }, .height = .{ .px = 140 } });
    container.behavior.interaction.focusable = true;
    try root.appendChild(allocator, container);

    const child = try Node.create(allocator, 3, .button, .{ .width = .{ .px = 80 }, .height = .{ .px = 36 } });
    child.behavior.interaction.focusable = true;
    try container.appendChild(allocator, child);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 240, .h = 160 });
    container.setLayoutRect(.{ .x = 10, .y = 10, .w = 220, .h = 140 });
    child.setLayoutRect(.{ .x = 40, .y = 30, .w = 80, .h = 36 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    const container_hit = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 20, .world_y = 20 }, &registry, null);
    try std.testing.expect(container_hit != null);
    try std.testing.expectEqual(@as(u32, 2), container_hit.?.node_id);
    runtime.setHoveredResult(container_hit);

    const child_hit = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 70, .world_y = 60 }, &registry, null);
    try std.testing.expect(child_hit != null);
    try std.testing.expectEqual(@as(u32, 3), child_hit.?.node_id);
}

test "HitRuntime: pointer query ignores mouse-down cache when deeper child is topmost" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 11, .box, .{ .width = .{ .px = 240 }, .height = .{ .px = 160 } });
    defer root.destroy(allocator);

    const container = try Node.create(allocator, 12, .button, .{ .width = .{ .px = 220 }, .height = .{ .px = 140 } });
    container.behavior.interaction.focusable = true;
    try root.appendChild(allocator, container);

    const child = try Node.create(allocator, 13, .button, .{ .width = .{ .px = 80 }, .height = .{ .px = 36 } });
    child.behavior.interaction.focusable = true;
    try container.appendChild(allocator, child);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 240, .h = 160 });
    container.setLayoutRect(.{ .x = 10, .y = 10, .w = 220, .h = 140 });
    child.setLayoutRect(.{ .x = 40, .y = 30, .w = 80, .h = 36 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    const container_hit = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 20, .world_y = 20 }, &registry, null);
    try std.testing.expect(container_hit != null);
    try std.testing.expectEqual(@as(u32, 12), container_hit.?.node_id);
    runtime.setMouseDownResult(container_hit);

    const child_hit = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 70, .world_y = 60 }, &registry, null);
    try std.testing.expect(child_hit != null);
    try std.testing.expectEqual(@as(u32, 13), child_hit.?.node_id);
}

test "HitRuntime: opaque island blocks pass-through to full-window canvas" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    // downstream app layout: canvas_host fills window bottom, chrome island floats as sibling on
    // top.
    const root = try Node.create(allocator, 41, .box, .{});
    defer root.destroy(allocator);

    const canvas = try Node.create(allocator, 42, .box, .{});
    canvas.behavior.interaction.focusable = true; // canvas itself clickable
    try root.appendChild(allocator, canvas);

    // pure visual island shell: no handlers.
    const island = try Node.create(allocator, 43, .box, .{});
    try root.appendChild(allocator, island);

    const button = try Node.create(allocator, 44, .button, .{});
    try island.appendChild(allocator, button);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 400, .h = 300 });
    canvas.setLayoutRect(.{ .x = 0, .y = 0, .w = 400, .h = 300 });
    island.setLayoutRect(.{ .x = 10, .y = 10, .w = 200, .h = 100 });
    button.setLayoutRect(.{ .x = 0, .y = 0, .w = 40, .h = 20 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    // before fix: click island blank space punches through to canvas.
    const leaked = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 150, .world_y = 90 }, &registry, null);
    try std.testing.expect(leaked != null);
    try std.testing.expectEqual(@as(u32, 42), leaked.?.node_id);

    // float layer root needs one field: interception hit_behavior implicitly implies pointer role.
    island.style.ensureExtPanic(allocator).hit_behavior = .@"opaque";
    try runtime.rebuild(root, &registry);

    // island blank space => hit island itself, no longer canvas.
    const blocked = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 150, .world_y = 90 }, &registry, null);
    try std.testing.expect(blocked != null);
    try std.testing.expectEqual(@as(u32, 43), blocked.?.node_id);

    // existing controls in island behavior unchanged.
    const on_button = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 20, .world_y = 20 }, &registry, null);
    try std.testing.expect(on_button != null);
    try std.testing.expectEqual(@as(u32, 44), on_button.?.node_id);

    // canvas blank space still hits canvas.
    const on_canvas = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 300, .world_y = 250 }, &registry, null);
    try std.testing.expect(on_canvas != null);
    try std.testing.expectEqual(@as(u32, 42), on_canvas.?.node_id);
}

test "HitRuntime: explicit opaque hit_behavior implies pointer role" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 51, .box, .{});
    defer root.destroy(allocator);

    const under = try Node.create(allocator, 52, .box, .{});
    under.behavior.interaction.focusable = true;
    try root.appendChild(allocator, under);

    const panel = try Node.create(allocator, 53, .box, .{});
    // set hit_behavior only, no hit_roles, should work independently.
    panel.style.ensureExtPanic(allocator).hit_behavior = .@"opaque";
    try root.appendChild(allocator, panel);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 400, .h = 300 });
    under.setLayoutRect(.{ .x = 0, .y = 0, .w = 400, .h = 300 });
    panel.setLayoutRect(.{ .x = 10, .y = 10, .w = 200, .h = 100 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    const hit = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 100, .world_y = 60 }, &registry, null);
    try std.testing.expect(hit != null);
    try std.testing.expectEqual(@as(u32, 53), hit.?.node_id);
}

test "HitRuntime: partial hit_roles override keeps unspecified roles at defaults" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 71, .box, .{});
    defer root.destroy(allocator);

    // pointer only. inspect must keep deriving default (true), cannot be silently zeroed,
    // else node unselectable in devtools (reason HitRolesOverride exists).
    const panel = try Node.create(allocator, 72, .box, .{});
    panel.frame_state.state_bits.flags.inspectable = true;
    panel.style.ensureExtPanic(allocator).hit_roles = .{ .pointer = true };
    try root.appendChild(allocator, panel);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 400, .h = 300 });
    panel.setLayoutRect(.{ .x = 10, .y = 10, .w = 200, .h = 100 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    const roles = interaction_semantics.nodeHitRoles(panel);
    try std.testing.expect(roles.pointer);
    try std.testing.expect(roles.inspect);

    const inspect_hit = runtime.hitTestQuery(.{ .kind = .inspect, .world_x = 100, .world_y = 60 }, &registry, null);
    try std.testing.expect(inspect_hit != null);
    try std.testing.expectEqual(@as(u32, 72), inspect_hit.?.node_id);
}

test "HitRuntime: partial override lets scroll owner keep its derived scroll role" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 81, .box, .{});
    defer root.destroy(allocator);

    // overlay_stack:509 shape: dialog content root only got pointer role added.
    // old full override would zero scroll too, wheel events no longer route to it;
    // per-role override after scroll derives from 'is it itself scroll owner'.
    const content = try Node.create(allocator, 82, .scroll, .{});
    content.style.ensureExtPanic(allocator).hit_roles = .{ .pointer = true };
    try root.appendChild(allocator, content);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 400, .h = 300 });
    content.setLayoutRect(.{ .x = 10, .y = 10, .w = 200, .h = 100 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    const roles = interaction_semantics.nodeHitRoles(content);
    try std.testing.expect(roles.pointer);
    try std.testing.expect(roles.scroll);

    const scroll_hit = runtime.hitTestQuery(.{ .kind = .scroll, .world_x = 100, .world_y = 60 }, &registry, null);
    try std.testing.expect(scroll_hit != null);
    try std.testing.expectEqual(@as(u32, 82), scroll_hit.?.node_id);
}

test "HitRuntime: every intercepting hit_behavior variant implies pointer role" {
    const allocator = std.testing.allocator;

    // doc declares three interception variants all imply pointer, pass-through both do not, pin
    // each down.
    for ([_]HitBehavior{ .@"opaque", .self_only, .self_and_children }) |behavior| {
        const node = try Node.create(allocator, 91, .box, .{});
        defer node.destroy(allocator);
        node.style.ensureExtPanic(allocator).hit_behavior = behavior;
        try std.testing.expect(interaction_semantics.nodeHitRoles(node).pointer);
    }

    for ([_]HitBehavior{ .pass_through, .children_only }) |behavior| {
        const node = try Node.create(allocator, 92, .box, .{});
        defer node.destroy(allocator);
        node.style.ensureExtPanic(allocator).hit_behavior = behavior;
        try std.testing.expect(!interaction_semantics.nodeHitRoles(node).pointer);
    }
}

test "HitRuntime: explicit hit_roles beats hit_behavior implication" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 61, .box, .{});
    defer root.destroy(allocator);

    const under = try Node.create(allocator, 62, .box, .{});
    under.behavior.interaction.focusable = true;
    try root.appendChild(allocator, under);

    // explicit role overrides hit_behavior's implicit derivation: here explicit pointer = false,
    // even if behavior interception, node still passes through.
    const panel = try Node.create(allocator, 63, .box, .{});
    const ext = panel.style.ensureExtPanic(allocator);
    ext.hit_behavior = .@"opaque";
    ext.hit_roles = .{ .pointer = false };
    try root.appendChild(allocator, panel);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 400, .h = 300 });
    under.setLayoutRect(.{ .x = 0, .y = 0, .w = 400, .h = 300 });
    panel.setLayoutRect(.{ .x = 10, .y = 10, .w = 200, .h = 100 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    const hit = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 100, .world_y = 60 }, &registry, null);
    try std.testing.expect(hit != null);
    try std.testing.expectEqual(@as(u32, 62), hit.?.node_id);
}

test "HitRuntime: hidden hit-test ancestor removes entire subtree from pointer hits" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 21, .box, .{ .width = .{ .px = 220 }, .height = .{ .px = 160 } });
    defer root.destroy(allocator);

    const under = try Node.create(allocator, 22, .button, .{ .width = .{ .px = 120 }, .height = .{ .px = 80 } });
    under.behavior.interaction.focusable = true;
    try root.appendChild(allocator, under);

    const overlay = try Node.create(allocator, 23, .box, .{ .width = .{ .px = 120 }, .height = .{ .px = 80 } });
    try root.appendChild(allocator, overlay);

    const option = try Node.create(allocator, 24, .button, .{ .width = .{ .px = 120 }, .height = .{ .px = 80 } });
    option.behavior.interaction.focusable = true;
    try overlay.appendChild(allocator, option);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 220, .h = 160 });
    under.setLayoutRect(.{ .x = 20, .y = 20, .w = 120, .h = 80 });
    overlay.setLayoutRect(.{ .x = 20, .y = 20, .w = 120, .h = 80 });
    option.setLayoutRect(.{ .x = 0, .y = 0, .w = 120, .h = 80 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    const before = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 60, .world_y = 50 }, &registry, null);
    try std.testing.expect(before != null);
    try std.testing.expectEqual(@as(u32, 24), before.?.node_id);

    overlay.setHitTestVisible(false);
    try runtime.rebuild(root, &registry);

    const after = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 60, .world_y = 50 }, &registry, null);
    try std.testing.expect(after != null);
    try std.testing.expectEqual(@as(u32, 22), after.?.node_id);
}

test "HitRuntime: partial rebuild 刷新祖先 clip 条目的陈旧尺寸（Show 重挂载类回归）" {
    // Repro (storybook cleanup story): a clip ancestor baked its clip_chain entry at the old
    // layout; content grew and pushed the button outside the old clip lower edge; the partial
    // rebuild root covers only the inner subtree (ancestor dirty mark consumed by an earlier full
    // rebuild) -> button proxy refreshed but ancestor clip entry stale -> hit rejected by
    // clipChainContains, click punches through to the outer.
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 1, .box, .{ .width = .{ .px = 200 }, .height = .{ .px = 400 } });
    defer root.destroy(allocator);
    root.frame_state.state_bits.flags.inspectable = false;

    const clipbox = try Node.create(allocator, 2, .box, .{ .width = .{ .px = 200 }, .height = .{ .px = 150 } });
    clipbox.style.overflow_hidden = true;
    try root.appendChild(allocator, clipbox);

    const inner = try Node.create(allocator, 3, .box, .{ .width = .{ .px = 200 }, .height = .{ .px = 150 } });
    try clipbox.appendChild(allocator, inner);

    const button = try Node.create(allocator, 4, .button, .{ .width = .{ .px = 80 }, .height = .{ .px = 30 } });
    try inner.appendChild(allocator, button);

    // initial layout: clip height 150, button in clip (10,100)
    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 200, .h = 400 });
    clipbox.setLayoutRect(.{ .x = 0, .y = 0, .w = 200, .h = 150 });
    inner.setLayoutRect(.{ .x = 0, .y = 0, .w = 200, .h = 150 });
    button.setLayoutRect(.{ .x = 10, .y = 100, .w = 80, .h = 30 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    const hit_before = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 20, .world_y = 110 }, &registry, null);
    try std.testing.expect(hit_before != null);
    try std.testing.expectEqual(@as(u64, 4), hit_before.?.node_id);

    // content change: clip grows to height 300, button pushed to (10,200), outside old boundary
    // (150).
    // simulate 'ancestor dirty mark consumed': partial rebuild on inner subtree only, clipbox not
    // in root.
    clipbox.setLayoutRect(.{ .x = 0, .y = 0, .w = 200, .h = 300 });
    inner.setLayoutRect(.{ .x = 0, .y = 0, .w = 200, .h = 300 });
    button.setLayoutRect(.{ .x = 10, .y = 200, .w = 80, .h = 30 });

    try std.testing.expect(try runtime.rebuildSubtree(inner, &registry));

    // before fix: button proxy at (10,200) but ancestor clip entry caches h=150 -> miss (hit null
    // or outer).
    const hit_after = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 20, .world_y = 210 }, &registry, null);
    try std.testing.expect(hit_after != null);
    try std.testing.expectEqual(@as(u64, 4), hit_after.?.node_id);

    // old position (inside clip but button gone) should not hit button.
    const hit_stale = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 20, .world_y = 110 }, &registry, null);
    try std.testing.expect(hit_stale == null or hit_stale.?.node_id != 4);
}

test "HitRuntime: repeated partial rebuilds compact append-only hit metadata" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 1, .box, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } });
    defer root.destroy(allocator);
    root.frame_state.state_bits.flags.inspectable = false;

    const button = try Node.create(allocator, 2, .button, .{ .width = .{ .px = 80 }, .height = .{ .px = 30 } });
    try root.appendChild(allocator, button);
    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 200, .h = 100 });
    button.setLayoutRect(.{ .x = 10, .y = 10, .w = 80, .h = 30 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    var compactions: usize = 0;
    for (0..600) |_| {
        if (!(try runtime.rebuildSubtree(button, &registry))) {
            compactions += 1;
            try runtime.rebuild(root, &registry);
        }
    }

    try std.testing.expect(compactions >= 2);
    try std.testing.expect(runtime.proxies.items.len <= runtime.live_proxy_count + 257);
    const hit = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 20, .world_y = 20 }, &registry, null);
    try std.testing.expect(hit != null);
    try std.testing.expectEqual(@as(u64, 2), hit.?.node_id);
}
