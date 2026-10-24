//! Cx runtime index rebuild: interaction index / node registry / focus order full
//! and partial-root rebuild, plus post-rebuild focus reconciliation. Split from
//! core.zig; thin delegate left on Cx.

const std = @import("std");
const core = @import("../core.zig");
const Cx = core.Cx;
const NodeHandle = core.NodeHandle;
const Node = core.Node;

fn rebuildInteractionIndex(self: *Cx) !void {
    self.perf.interaction_full_rebuild_count += 1;
    try self.interaction_index.rebuild(self.root, &self.node_registry);
    if (self.root) |root| clearInteractionDirtyRecursive(self, root);
}

pub fn collectPartialInteractionRoots(self: *Cx, node: *Node, roots: *PartialInteractionRoots) void {
    if ((!node.frame_state.state_bits.dirty.core.subtree_layout and !node.frame_state.state_bits.dirty.pipeline.subtree_interaction) or roots.overflow) return;
    if (node.frame_state.state_bits.dirty.core.layout or node.frame_state.state_bits.dirty.pipeline.interaction) {
        const candidate = partialInteractionRootForLayoutNode(node) orelse return;
        roots.add(self, candidate);
        return;
    }
    const roots_before = roots.len;
    for (node.children.items) |child| {
        collectPartialInteractionRoots(self, child, roots);
        if (roots.overflow) return;
    }
    // Orphaned dirty flag fix: subtree_interaction_dirty bubbles up; partial rebuild
    // clears source interaction_dirty via clearInteractionDirtyRecursive, but ancestor
    // subtree_interaction_dirty stays set. Clear orphaned flag to prevent full rebuild
    // every frame.
    if (roots.len == roots_before and node.frame_state.state_bits.dirty.pipeline.subtree_interaction and !node.frame_state.state_bits.dirty.core.subtree_layout) {
        node.frame_state.state_bits.dirty.pipeline.subtree_interaction = false;
    }
}

fn collectPartialInteractionRootsFallback(self: *Cx, node: *Node, roots: *PartialInteractionRoots) void {
    if (roots.overflow) return;
    if (node.frame_state.state_bits.dirty.core.layout or node.frame_state.state_bits.dirty.pipeline.interaction) {
        const candidate = partialInteractionRootForLayoutNode(node) orelse return;
        roots.add(self, candidate);
        return;
    }
    for (node.children.items) |child| {
        collectPartialInteractionRootsFallback(self, child, roots);
        if (roots.overflow) return;
    }
}

pub fn collectPartialInteractionRootsWithFallback(self: *Cx, node: *Node, roots: *PartialInteractionRoots) void {
    if (node.frame_state.state_bits.dirty.core.subtree_layout or node.frame_state.state_bits.dirty.pipeline.subtree_interaction) {
        collectPartialInteractionRoots(self, node, roots);
        if (roots.len > 0 or roots.overflow) return;
    }
    if (subtreeHasLooseInteractionDirty(self, node)) {
        collectPartialInteractionRootsFallback(self, node, roots);
    }
}

pub fn rebuildInteractionIndexWithPartialRoots(self: *Cx, roots: PartialInteractionRoots) !void {
    if (self.node_registry.entries.count() == 0) {
        const root = self.root orelse return;
        try fullRebuildRuntimeIndexes(self, root);
        return;
    }

    if (roots.overflow or roots.len == 0) {
        try rebuildInteractionIndex(self);
        return;
    }

    for (roots.items[0..roots.len]) |handle| {
        const node = self.node_registry.resolve(handle, null) orelse {
            try rebuildInteractionIndex(self);
            return;
        };
        if (!(try self.interaction_index.rebuildSubtree(node, &self.node_registry))) {
            try rebuildInteractionIndex(self);
            return;
        }
        self.perf.interaction_partial_rebuild_count += 1;
        clearInteractionDirtyRecursive(self, node);
    }
    // After partial rebuild, clear orphaned subtree_interaction_dirty on ancestor
    // chain. clearInteractionDirtyRecursive only clears partial-root subtree;
    // ancestor's subtree flag still true, triggering invalid full rebuild next frame.
    if (self.root) |root| {
        clearStaleSubtreeInteractionDirty(self, root);
        // Layout may leave hit geometry outside the bubbled partial roots.
        // Consume that residual work too, or every idle host tick sees it.
        if (subtreeHasLooseInteractionDirty(self, root)) try rebuildInteractionIndex(self);
    }
    // After partial rebuild, rebuild spatial grid.
}

fn partialInteractionRootForLayoutNode(node: *Node) ?*Node {
    // An in-flow child size change (e.g., Accordion content expand) **relayouts the
    // parent** and shifts **all following siblings**. Rebuilding only the changed
    // node's subtree leaves shifted siblings' hit areas at old positions, so hit-test
    // uses the old layout. Hence the rebuild root is raised to the **parent**, covering
    // all reflowed siblings. Only for in-flow: absolute/out-of-flow size changes don't
    // affect sibling layout, so raising would waste coverage. No parent (root) -> self.
    if (node.style.position != .absolute) {
        if (node.parent) |parent| return parent;
    }
    return node;
}

/// The loose bits (pipeline.interaction / hit.geometry / hit.semantics) don't
/// bubble, so they need a whole-tree scan (up to 6 callsites per frame). Memoized
/// by (root, node_dirty.g_loose_interaction_gen): all set/clear sites bump gen
/// (see node_dirty.bumpLooseInteractionGen contract); unchanged gen => unchanged
/// bits => same result as scanning each time.
pub fn subtreeHasLooseInteractionDirty(self: *const Cx, node: *Node) bool {
    // Mutating an observation cache does not mutate scene state. Each Cx keeps
    // its own root slot, so alternating windows do not evict one another.
    const memo = &@constCast(self).loose_interaction_memo;
    const cur_gen = @import("node_dirty.zig").g_loose_interaction_gen;
    if (memo.root == node and memo.gen == cur_gen) return memo.result;
    memo.result = subtreeHasLooseInteractionDirtyScan(node);
    memo.root = node;
    memo.gen = cur_gen;
    memo.scans += 1;
    return memo.result;
}

fn subtreeHasLooseInteractionDirtyScan(node: *Node) bool {
    if (node.frame_state.state_bits.dirty.pipeline.interaction or node.frame_state.state_bits.dirty.hit.geometry or node.frame_state.state_bits.dirty.hit.semantics) return true;
    for (node.children.items) |child| {
        if (subtreeHasLooseInteractionDirtyScan(child)) return true;
    }
    return false;
}

fn isDescendantNode(node: *Node, ancestor: *Node) bool {
    var current: ?*Node = node;
    while (current) |n| {
        if (n == ancestor) return true;
        current = n.parent;
    }
    return false;
}

pub fn rebuildRuntimeIndexes(self: *Cx) !void {
    const root = self.root orelse return;
    // Diagnostic flag: ZENIT_FULL_RUNTIME_REBUILD=1 forces full runtime index
    // rebuild every time (debug partial repaint order with still-subtree interleave).
    const needs_full_rebuild = self.node_registry.entries.count() == 0 or
        root.frame_state.state_bits.dirty.runtime.subtree_full_rebuild or
        @import("zenit_environment").has("ZENIT_FULL_RUNTIME_REBUILD");
    if (needs_full_rebuild) {
        try fullRebuildRuntimeIndexes(self, root);
    } else {
        var partial_interaction_roots = PartialInteractionRoots{};
        collectRuntimeDirtyRoots(self, root, &partial_interaction_roots);
        try rebuildDirtyRuntimeSubtrees(self, root);
        self.focus_manager.finalizeFocusOrder();
        reconcileFocusedAfterRuntimeRebuild(self);
        try rebuildInteractionIndexWithPartialRoots(self, partial_interaction_roots);
    }
}

pub fn rebuildRuntimeIndexesForTest(self: *Cx) !void {
    return rebuildRuntimeIndexes(self);
}

fn rebuildRuntimeStateRecursive(self: *Cx, node: *Node) !void {
    node.frame_state.state_bits.dirty.runtime.dirty = false;
    node.frame_state.state_bits.dirty.runtime.subtree_dirty = false;
    node.frame_state.state_bits.dirty.runtime.full_rebuild = false;
    node.frame_state.state_bits.dirty.runtime.subtree_full_rebuild = false;
    node.frame_state.state_bits.dirty.pipeline.order = false;
    node.frame_state.state_bits.dirty.pipeline.subtree_order = false;
    node.frame_state.state_bits.dirty.pipeline.interaction = false;
    node.frame_state.state_bits.dirty.pipeline.subtree_interaction = false;
    node.frame_state.state_bits.dirty.hit.geometry = false;
    node.frame_state.state_bits.dirty.hit.semantics = false;
    node.frame_state.state_bits.dirty.hit.structure = false;
    @import("node_dirty.zig").bumpLooseInteractionGen();
    const generation = try self.node_registry.trackGeneration(node);
    try self.node_registry.entries.put(node.id, .{ .ptr = node, .generation = generation });
    try self.focus_manager.appendFocusableUnsorted(node);
    for (node.children.items) |child| {
        try rebuildRuntimeStateRecursive(self, child);
    }
}

pub fn fullRebuildRuntimeIndexes(self: *Cx, root: *Node) !void {
    self.perf.focus_rebuild_count += 1;
    self.node_registry.clear();
    self.focus_manager.clearFocusOrder();
    try rebuildRuntimeStateRecursive(self, root);
    self.focus_manager.finalizeFocusOrder();
    reconcileFocusedAfterRuntimeRebuild(self);
    try rebuildInteractionIndex(self);
}

fn rebuildDirtyRuntimeSubtrees(self: *Cx, node: *Node) !void {
    if (!node.frame_state.state_bits.dirty.runtime.subtree_dirty) return;
    if (node.frame_state.state_bits.dirty.runtime.dirty) {
        // Partial rebuild only removes/re-adds this subtree from registry/focus_order;
        // it doesn't destroy nodes. unregisterFocusableSubtree clears current_focus if it
        // lands in the subtree (correct for subtrees about to be freed), so focus must be
        // restored after re-adding; otherwise any "refresh current-focus row" component
        // (e.g., VirtualList row selection) silently loses keyboard focus.
        const focused_before = self.focus_manager.current_focus;
        const focus_was_inside = if (focused_before) |f| isDescendantNode(f, node) else false;
        self.node_registry.detachSubtree(node);
        self.focus_manager.unregisterFocusableSubtree(node);
        try rebuildRuntimeStateRecursive(self, node);
        if (focus_was_inside) {
            if (focused_before) |f| {
                // Restore focus only if node re-registers with partial rebuild (same id, same
                // pointer); if detached from tree between mark-dirty and rebuild, maintain clear
                // semantics.
                if (self.node_registry.entries.get(f.id)) |entry| {
                    if (entry.ptr == f) {
                        self.focus_manager.restoreFocusAfterSubtreeRebuild(f);
                    }
                }
            }
        }
        return;
    }
    for (node.children.items) |child| {
        try rebuildDirtyRuntimeSubtrees(self, child);
    }
    node.frame_state.state_bits.dirty.runtime.subtree_dirty = false;
    node.frame_state.state_bits.dirty.runtime.subtree_full_rebuild = false;
}

fn collectRuntimeDirtyRoots(self: *Cx, node: *Node, roots: *PartialInteractionRoots) void {
    if (!node.frame_state.state_bits.dirty.runtime.subtree_dirty or roots.overflow) return;
    if (node.frame_state.state_bits.dirty.runtime.dirty) {
        // A newly registered/reparented node has no authoritative global
        // paint range. Rebuilding it alone can reuse the default [0,0]
        // range, placing a new topmost sibling underneath existing nodes.
        // Recompute at the parent boundary so sibling order is committed
        // together; changed range size still falls back to a full rebuild.
        roots.add(self, node.parent orelse node);
        return;
    }
    for (node.children.items) |child| {
        collectRuntimeDirtyRoots(self, child, roots);
        if (roots.overflow) return;
    }
}

pub fn rebuildOrderIndexes(self: *Cx) !void {
    const root = self.root orelse return;
    if (orderDirtyAffectsFocus(self, root)) {
        if (!(try rebuildDirtyFocusOrderIncremental(self, root))) {
            self.perf.focus_order_rebuild_count += 1;
            try self.focus_manager.collectFocusableNodes(root);
        }
        reconcileFocusedAfterRuntimeRebuild(self);
    }
    if (!(try rebuildDirtyInteractionSubtrees(self, root))) {
        try rebuildInteractionIndex(self);
    } else {
        // After partial subtree rebuild succeeds, rebuild spatial grid.
    }
    clearOrderDirtyRecursive(self, root);
}

fn clearOrderDirtyRecursive(self: *Cx, node: *Node) void {
    node.frame_state.state_bits.dirty.pipeline.order = false;
    node.frame_state.state_bits.dirty.pipeline.subtree_order = false;
    for (node.children.items) |child| {
        clearOrderDirtyRecursive(self, child);
    }
}

fn clearInteractionDirtyRecursive(self: *Cx, node: *Node) void {
    @import("node_dirty.zig").bumpLooseInteractionGen();
    node.frame_state.state_bits.dirty.pipeline.interaction = false;
    node.frame_state.state_bits.dirty.pipeline.subtree_interaction = false;
    node.frame_state.state_bits.dirty.hit.geometry = false;
    node.frame_state.state_bits.dirty.hit.semantics = false;
    node.frame_state.state_bits.dirty.hit.structure = false;
    for (node.children.items) |child| {
        clearInteractionDirtyRecursive(self, child);
    }
}

/// Bottom-up clear subtree_interaction_dirty: if all children are clean, node's
/// own subtree_interaction_dirty should clear too.
fn clearStaleSubtreeInteractionDirty(self: *Cx, node: *Node) void {
    if (!node.frame_state.state_bits.dirty.pipeline.subtree_interaction) return;
    if (node.frame_state.state_bits.dirty.pipeline.interaction) return; // Node itself is dirty, don't clear.
    for (node.children.items) |child| {
        clearStaleSubtreeInteractionDirty(self, child);
    }
    // Check all children are clean.
    for (node.children.items) |child| {
        if (child.frame_state.state_bits.dirty.pipeline.interaction or child.frame_state.state_bits.dirty.pipeline.subtree_interaction) return;
    }
    node.frame_state.state_bits.dirty.pipeline.subtree_interaction = false;
}

fn orderDirtyAffectsFocus(self: *Cx, node: *Node) bool {
    if (!node.frame_state.state_bits.dirty.pipeline.subtree_order) return false;
    if (node.frame_state.state_bits.dirty.pipeline.order) {
        return subtreeContainsFocusableOrderParticipant(node);
    }
    for (node.children.items) |child| {
        if (orderDirtyAffectsFocus(self, child)) return true;
    }
    return false;
}

fn rebuildDirtyFocusOrderIncremental(self: *Cx, node: *Node) !bool {
    if (!node.frame_state.state_bits.dirty.pipeline.subtree_order) return true;
    if (node.frame_state.state_bits.dirty.pipeline.order) {
        if (!subtreeSupportsIncrementalFocusRepair(node)) return false;
        try self.focus_manager.replaceDefaultOrderSubtree(node);
        return true;
    }
    for (node.children.items) |child| {
        if (!(try rebuildDirtyFocusOrderIncremental(self, child))) return false;
    }
    return true;
}

fn rebuildDirtyInteractionSubtrees(self: *Cx, node: *Node) !bool {
    if (!node.frame_state.state_bits.dirty.pipeline.subtree_order) return true;
    if (node.frame_state.state_bits.dirty.pipeline.order) {
        if (!(try self.interaction_index.rebuildSubtree(node, &self.node_registry))) {
            return false;
        }
        self.perf.interaction_partial_rebuild_count += 1;
        return true;
    }
    for (node.children.items) |child| {
        if (!(try rebuildDirtyInteractionSubtrees(self, child))) return false;
    }
    return true;
}

fn subtreeContainsFocusableOrderParticipant(node: *Node) bool {
    if (node.behavior.interaction.focus_scope != null) return true;
    if (nodeParticipatesInFocusOrder(node)) return true;
    for (node.children.items) |child| {
        if (subtreeContainsFocusableOrderParticipant(child)) return true;
    }
    return false;
}

fn nodeParticipatesInFocusOrder(node: *Node) bool {
    const is_focusable = node.behavior.interaction.focusable or node.behavior.interaction.tab_index != null;
    const excluded_from_tab = if (node.behavior.interaction.tab_index) |ti| ti < 0 else false;
    return is_focusable and !excluded_from_tab;
}

fn subtreeSupportsIncrementalFocusRepair(node: *Node) bool {
    if (node.behavior.interaction.focus_scope != null) return false;
    if (node.behavior.interaction.tab_index) |ti| {
        if (ti > 0) return false;
    }
    for (node.children.items) |child| {
        if (!subtreeSupportsIncrementalFocusRepair(child)) return false;
    }
    return true;
}

/// Runtime-index rebuilds are the **second** boundary at which the
/// effective focus can change (the first is setFocusWithReason, which
/// reconciles via on_focus_settled). A rebuild detaches the subtree from
/// registry/focus_order and re-registers it, so focus can be cleared and
/// restored, `restoreFocusAfterSubtreeRebuild` writes the fields directly
/// and deliberately fires no blur/focus events.
///
/// The window-level native IME gate is *derived* from focus, so it has to
/// be reconciled wherever focus settles, not only where focus events are
/// dispatched. Leaving it out is silent and permanent: the gate is a single
/// window-global switch, so a focused editor whose gate was closed by a
/// previous client (a popover Input, a freed node's deactivate) never gets
/// another chance to reopen it, and accepts no IME input until the user
/// clicks away and back. refreshTextInputSession is idempotent, so calling
/// it on every settle costs nothing when the state already matches.
fn reconcileFocusedAfterRuntimeRebuild(self: *Cx) void {
    if (self.focus_manager.getFocused()) |focused| {
        if (!self.node_registry.entries.contains(focused.id)) {
            // Partial rebuild leaves index coverage gaps: missing entries != dead nodes. Only
            // generations (noteNodeFreed sets last_ptr=null / pointer generation advanced)
            // clear focus; live nodes temporarily out of the index retain focus, and the next
            // full rebuild re-indexes them. Otherwise a partial rebuild clears focus on a live
            // node (e.g., sidebar row focus lost when editor syntax prewarm rebuilds).
            const alive = if (self.node_registry.generations.get(focused.id)) |g|
                g.last_ptr == focused
            else
                false;
            if (!alive) {
                // clearFocus goes through setFocusWithReason -> on_focus_settled already
                // flushed native gate; no need to repeat.
                self.focus_manager.clearFocus();
                self.focused_node = null;
                self.focused_handle = null;
                return;
            }
            // Handle keeps old value: entries return and resolve naturally restores.
            self.focused_node = focused;
            self.refreshTextInputSession();
            return;
        }
        self.focused_node = focused;
        self.focused_handle = self.node_registry.handleFor(focused);
        self.refreshTextInputSession();
        return;
    }
    self.focused_node = null;
    self.focused_handle = null;
    self.refreshTextInputSession();
}

pub const PartialInteractionRoots = struct {
    items: [64]NodeHandle = undefined,
    len: usize = 0,
    overflow: bool = false,

    fn add(self: *PartialInteractionRoots, cx: *Cx, node: *Node) void {
        if (self.overflow) return;

        const handle = cx.node_registry.handleFor(node);

        var i: usize = 0;
        while (i < self.len) {
            const existing_handle = self.items[i];
            const existing = cx.node_registry.resolve(existing_handle, null) orelse {
                self.items[i] = self.items[self.len - 1];
                self.len -= 1;
                continue;
            };
            if (existing == node) return;
            if (isDescendantNode(node, existing)) return;
            if (isDescendantNode(existing, node)) {
                self.items[i] = self.items[self.len - 1];
                self.len -= 1;
                continue;
            }
            i += 1;
        }

        if (self.len >= self.items.len) {
            self.overflow = true;
            self.len = 0;
            return;
        }
        self.items[self.len] = handle;
        self.len += 1;
    }
};
