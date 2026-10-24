//! Overlay layer weak-ref + generation-alive-check for trigger/anchor targets, factored out of
//! `overlay_stack.zig`.
//!
//! ## Why
//!
//! An overlay layer holds `trigger_node: ?*Node` (button that opened it) and
//! `anchor.target: ?*Node` (anchor target). These point into the **caller's subtree** and are not
//! owned by the overlay: caller scope dispose / story switch / removePermanently can release the
//! whole subtree while the overlay is still alive. A bare pointer dangles: after the node is freed,
//! outside-click would walk the `isDescendantOf(stale_ptr)` parent chain and read recycled memory.
//!
//! So 'bare pointer + registry generation check' is a function pair:
//!
//!   trackNode(node)          exchange for a generation-baked handle on push/setAnchor
//!   resolveTrackedNode(h, cached_ptr)   validate before every deref
//!
//! resolve's clause semantics are **all invariants of the alive-check**; dropping any one
//! reintroduces dangling pointers:
//!
//!   1. `cached == null`            -> no cached ptr, can't validate -> null
//!   2. no registry                 -> no validation capability, return cached itself: nobody has
//!                                     called trackNode yet (registry is injected by setRegistry,
//!                                     which must be set pre-push); ptr lifetime is the test
//!                                     caller's defer destroy.
//!   3. `h == null`                 -> never tracked (trackNode returns null on missing registry/
//!                                     OOM) -> null. **Must return null, not fall back to cached**:
//!                                     a failed track has no gen to check, trusting cached
//!                                     reverts to dangling.
//!   4. registry.resolve(h) hit     -> gen match, alive -> return
//!   5. resolve miss but isCurrentIdentity
//!      (h, cached) still true      -> node not yet in the frame registry snapshot (identity
//!                                     established by trackGeneration), transient not dangling
//!                                     -> return cached
//!   6. else                        -> node freed or same id swapped object -> null
//!
//! ## Where the interface is cut
//!
//! Cut at 'single node alive-check'. Not moved:
//!   - `OverlayLayer` struct itself (aggregates animation, z order, focus: all layer state;
//!     splitting it splits the layer state machine);
//!   - `handleOutsideClick` check order (content -> trigger -> barrier -> unknown area, whole-stack
//!     semantics, see overlay_stack.zig notes);
//!   - `nestedParentZ` (must walk the stack in index order).
//!
//! Dependency injection, not hard import: `NodeRegistry` is passed as a param (real one is
//! `core/hit_runtime.zig`), so this module doesn't import core.zig and there is no core <->
//! overlay_stack cycle. Tests use the real registry (pure data structure, independently
//! constructible) and pin 'must judge dead after unregisterSubtree'.
//! Collected by `test { _ = @import("overlay_layer_refs.zig"); }` at the end of overlay_stack.zig.
//!
//! OverlayStack-side thin wraps (trackNode/resolveTrigger) stay in overlay_stack.zig: they write
//! back layer fields and are part of the layer state machine.

const std = @import("std");
const node_mod = @import("core/node.zig");
const hit_runtime = @import("core/hit_runtime.zig");

const Node = node_mod.Node;
const NodeHandle = hit_runtime.NodeHandle;
const NodeRegistry = hit_runtime.NodeRegistry;

/// Exchange bare node ptr for generation-baked handle. registry missing or trackGeneration fail
/// (OOM) return null, caller store null, later resolve always judge dead, never fallback
/// bare ptr. Only one point on chain allowed 'degrade to unavailable', degrade direction is
/// safe side (don't deref), not dangerous side (trust old ptr).
pub fn trackNode(registry: ?*NodeRegistry, node: ?*Node) ?NodeHandle {
    const n = node orelse return null;
    const registry_ = registry orelse return null;
    const generation = registry_.trackGeneration(n) catch return null;
    return .{ .id = n.id, .generation = generation };
}

/// See module head 'three-clause semantics' list. cached null judge dead outright, no registry
/// query, no cached means no fallback object.
pub fn resolveTrackedNode(registry: ?*const NodeRegistry, handle: ?NodeHandle, cached: ?*Node) ?*Node {
    const node = cached orelse return null;
    const registry_ = registry orelse return node;
    const h = handle orelse return null;
    return registry_.resolve(h, null) orelse
        if (registry_.isCurrentIdentity(h, node)) node else null;
}

// ── Tests ───────────────────────────────────────────────────────────

test "无 registry 时回退 cached（测试路径），null cached 一律判死" {
    const allocator = std.testing.allocator;
    const node = try Node.create(allocator, 900_001, .button, .{});
    defer node.destroy(allocator);

    try std.testing.expectEqual(@as(?NodeHandle, null), trackNode(null, node));
    try std.testing.expectEqual(@as(?*Node, null), resolveTrackedNode(null, null, null));
    // no registry + have cached: return cached self (see three-clause #2)
    try std.testing.expectEqual(@as(?*Node, node), resolveTrackedNode(null, null, node));
}

test "track → resolve 往返命中；handle 为 null 时即使有 cached 也判死" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    const node = try Node.create(allocator, 900_002, .button, .{});
    defer node.destroy(allocator);
    try registry.rebuild(node);

    const h = trackNode(&registry, node).?;
    try std.testing.expectEqual(@as(?*Node, node), resolveTrackedNode(&registry, h, node));
    // clause 3 invariant: trackNode fail leave null handle must never fallback cached
    try std.testing.expectEqual(@as(?*Node, null), resolveTrackedNode(&registry, null, node));
}

test "unregisterSubtree 之后 resolve 判死 —— 悬垂指针不再沿 parent 链走" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();

    const trigger = try Node.create(allocator, 900_003, .button, .{ .width = .{ .px = 40 } });
    const child = try Node.create(allocator, 900_004, .button, .{});
    try trigger.appendChild(allocator, child);
    defer trigger.destroy(allocator);

    try registry.rebuild(trigger);
    const h = trackNode(&registry, trigger).?;
    try std.testing.expectEqual(@as(?*Node, trigger), resolveTrackedNode(&registry, h, trigger));

    // simulate caller subtree unload/free before registry prune
    registry.unregisterSubtree(trigger);
    try std.testing.expectEqual(@as(?*Node, null), resolveTrackedNode(&registry, h, trigger));
}

test "同 id 复用新节点（代次前进）后旧 handle 判死" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();

    // don't destroy a: directly simulate 'id reused' registry view (destroy then rebuild,
    // under testing.allocator new object may reuse old address, make test UB).
    const a = try Node.create(allocator, 900_005, .button, .{});
    defer a.destroy(allocator);
    const b = try Node.create(allocator, 900_006, .button, .{});
    defer b.destroy(allocator);

    try registry.rebuild(a);
    const stale_handle = trackNode(&registry, a).?;
    registry.unregisterSubtree(a);

    // same id swap object: b reuse a's id (entries/generations keyed by id).
    b.id = a.id;
    try registry.rebuild(b);

    // old handle + old cached both shouldn't resolve anything (gen advanced)
    try std.testing.expectEqual(@as(?*Node, null), resolveTrackedNode(&registry, stale_handle, a));
    // new object resolve normally with own handle
    const fresh = trackNode(&registry, b).?;
    try std.testing.expectEqual(@as(?*Node, b), resolveTrackedNode(&registry, fresh, b));
}

test "registry.resolve 落空但身份仍最新（暂态）→ 回退 cached" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();

    const node = try Node.create(allocator, 900_007, .button, .{});
    defer node.destroy(allocator);
    // only trackGeneration, not put in entries: simulate 'node not yet in frame snapshot'
    const h = trackNode(&registry, node).?;
    try std.testing.expectEqual(@as(?*Node, node), resolveTrackedNode(&registry, h, node));
}
