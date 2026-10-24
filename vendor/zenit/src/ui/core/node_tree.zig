//! node_tree: tree-structure subdomain extracted from node.zig (7 methods +
//! structure callback unit). Node-typed free functions + @import("node.zig") cyclic
//! import; node.zig keeps thin delegates (original pub/private visibility).
//! appendChild/removeChild call dirty / lifecycle.fireCleanupCallbacks /
//! interaction.markCustomDrawSubtree. The structure callback unit (StructureKind /
//! StructureNotifyFn / g_structure_notify / setStructureNotifyCallback) lives here;
//! node.zig re-exports it to keep the public API (core.zig calls
//! setStructureNotifyCallback).

const std = @import("std");
const world_mod = @import("world.zig");
const node_mod = @import("node.zig");

const Node = node_mod.Node;
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Structure callback unit (moved wholesale from node.zig)
// appendChild/removeChild syncs parent-child links to World.elements.
// ---------------------------------------------------------------------------

pub const StructureKind = enum(u8) { append, unlink };
pub const StructureNotifyFn = *const fn (parent_raw: u32, child_raw: u32, kind: StructureKind) void;
var g_structure_notify: ?StructureNotifyFn = null;

// UI tree operations are serialized, as are the existing structure/dirty hooks.
// A callback can reorder a list without changing its length or the current slot;
// an epoch detects those changes without allocating a snapshot or growing Node.
var g_structure_revision: u64 = 0;
pub fn structureRevision() u64 {
    return g_structure_revision;
}

/// Sync one parent-child chain change to the node's owner World's elements table.
///
/// Prefers the direct `world_ref`; null (cx-less mock) falls back to the global
/// callback. Includes reparent pre-unlink (when child has a parent, it must be
/// unlinked first or the sibling chain corrupts).
fn syncWorldStructure(parent: anytype, child: anytype, kind: StructureKind) void {
    if (parent.element_id_raw == 0xFFFFFFFF or child.element_id_raw == 0xFFFFFFFF) return;
    // Use parent's owner; after append child belongs to parent's World.
    if (parent.world_ref) |w| {
        const parent_eid = world_mod.ElementId.fromRaw(parent.element_id_raw);
        const child_eid = world_mod.ElementId.fromRaw(child.element_id_raw);
        if (!w.elements.isValid(parent_eid) or !w.elements.isValid(child_eid)) return;
        switch (kind) {
            .append => {
                // Reparent scenario: when child has parent, unlink first or chain corrupts.
                const existing = w.elements.links(child_eid) orelse return;
                if (!existing.parent.isNull()) w.elements.unlink(child_eid);
                w.elements.appendChild(parent_eid, child_eid);
            },
            .unlink => w.elements.unlink(child_eid),
        }
        return;
    }
    if (g_structure_notify) |notify| {
        notify(parent.element_id_raw, child.element_id_raw, kind);
    }
}

pub fn setStructureNotifyCallback(notify: ?StructureNotifyFn) void {
    g_structure_notify = notify;
}

// ---------------------------------------------------------------------------
// Tree structure methods
// ---------------------------------------------------------------------------

/// Walk parent chain upward; self is descendent of ancestor (including self)
/// return true.
pub fn isDescendantOf(self: *Node, ancestor: *Node) bool {
    var current: ?*Node = self;
    while (current) |n| {
        if (n == ancestor) return true;
        current = n.parent;
    }
    return false;
}

fn validateChild(parent: *Node, child: *Node) !void {
    if (parent.isDescendantOf(child)) return error.CyclicNodeTree;
    if (parent.world_ref != null and child.world_ref != null and parent.world_ref != child.world_ref)
        return error.CrossWorldNode;
    if (child.parent) |old_parent| {
        if (std.mem.indexOfScalar(*Node, old_parent.children.items, child) == null)
            return error.InvalidChildParent;
    }
}

pub fn appendChild(self: *Node, allocator: Allocator, child: *Node) !void {
    try validateChild(self, child);
    if (child.parent == self) {
        if (self.children.items[self.children.items.len - 1] == child) return;
    } else {
        // No parent links, dirty flags or World links change before allocation.
        try self.children.ensureUnusedCapacity(allocator, 1);
    }
    if (child.parent) |old_parent| old_parent.removeChildRetained(child);
    self.children.appendAssumeCapacity(child);
    g_structure_revision +%= 1;
    child.parent = self;
    // Child has custom_draw -> bubble mark.
    if (child.frame_state.state_bits.flags.has_custom_draw_subtree) {
        self.markCustomDrawSubtree();
    }
    // Child text / before_render flags merge to parent chain (same maintenance as
    // has_custom_draw_subtree).
    if (child.frame_state.state_bits.flags.has_text_subtree) self.markSubtreeText();
    if (child.frame_state.state_bits.flags.has_before_render_subtree) self.markSubtreeBeforeRenderHook();
    child.frame_state.state_bits.dirty.runtime.dirty = true;
    child.frame_state.state_bits.dirty.runtime.subtree_dirty = true;
    child.frame_state.state_bits.dirty.runtime.full_rebuild = false;
    child.frame_state.state_bits.dirty.runtime.subtree_full_rebuild = false;
    self.bubbleChildRuntimeIndexDirty(false);
    self.markLayoutDirty();
    // P0-3 phase 3: sync parent-child chain directly to owner World; no more
    // process-level callback.
    syncWorldStructure(self, child, .append);
}

/// Insert child before anchor; null anchor is equivalent to appendChild. Anchor
/// must be a direct child of self; otherwise error.InvalidAnchor (no silent append:
/// control flow uses anchor position; an anchor not in parent means the caller's
/// region bookkeeping is already broken). A child already under self is moved
/// (unlink then insert), consistent with appendChild's reparent semantics.
pub fn insertChildBefore(self: *Node, allocator: Allocator, child: *Node, before: ?*Node) !void {
    const anchor = before orelse return appendChild(self, allocator, child);
    if (anchor == child) return;
    if (anchor.parent != self) return error.InvalidAnchor;
    try validateChild(self, child);
    if (child.parent != self) {
        // No parent links, dirty flags or World links change before allocation.
        try self.children.ensureUnusedCapacity(allocator, 1);
    }
    if (child.parent) |old_parent| old_parent.removeChildRetained(child);
    // Reposition after unlink: when child was under self and before anchor, index
    // shifts down.
    const index = std.mem.indexOfScalar(*Node, self.children.items, anchor) orelse unreachable;
    self.children.insertAssumeCapacity(index, child);
    g_structure_revision +%= 1;
    child.parent = self;
    if (child.frame_state.state_bits.flags.has_custom_draw_subtree) self.markCustomDrawSubtree();
    if (child.frame_state.state_bits.flags.has_text_subtree) self.markSubtreeText();
    if (child.frame_state.state_bits.flags.has_before_render_subtree) self.markSubtreeBeforeRenderHook();
    child.frame_state.state_bits.dirty.runtime.dirty = true;
    child.frame_state.state_bits.dirty.runtime.subtree_dirty = true;
    child.frame_state.state_bits.dirty.runtime.full_rebuild = false;
    child.frame_state.state_bits.dirty.runtime.subtree_full_rebuild = false;
    self.bubbleChildRuntimeIndexDirty(false);
    self.markOrderDirty();
    self.markLayoutDirty();
    syncWorldInsertBefore(self, child, anchor, index);
}

/// World sync for insertChildBefore. O(1) linked-list insert with world_ref;
/// cx-less old path's global callback only has append/unlink; relink successors one
/// by one, matches Node.children order (only mock tests hit this).
fn syncWorldInsertBefore(self: *Node, child: *Node, anchor: *Node, index: usize) void {
    if (self.element_id_raw == 0xFFFFFFFF or child.element_id_raw == 0xFFFFFFFF) return;
    if (self.world_ref) |w| fast: {
        // Anchor not in World table (old-path node) has no insertable list position;
        // fall through to bulk relink below.
        if (anchor.element_id_raw == 0xFFFFFFFF) break :fast;
        const parent_eid = world_mod.ElementId.fromRaw(self.element_id_raw);
        const child_eid = world_mod.ElementId.fromRaw(child.element_id_raw);
        const before_eid = world_mod.ElementId.fromRaw(anchor.element_id_raw);
        if (!w.elements.isValid(parent_eid) or !w.elements.isValid(child_eid)) return;
        if (!w.elements.isValid(before_eid)) break :fast;
        // Anchor's parent in World differs from Node tree (tables diverged); table-layer
        // insertBefore degrades to append, leaving silent order split; switch to bulk
        // relink using children as source to rewrite order suffix.
        const before_links = w.elements.links(before_eid) orelse break :fast;
        if (!before_links.parent.eql(parent_eid)) break :fast;
        const existing = w.elements.links(child_eid) orelse return;
        if (!existing.parent.isNull()) w.elements.unlink(child_eid);
        w.elements.insertBefore(parent_eid, child_eid, before_eid);
        return;
    }
    for (self.children.items[index..]) |sib| syncWorldStructure(self, sib, .unlink);
    for (self.children.items[index..]) |sib| syncWorldStructure(self, sib, .append);
}

/// Reorder children using existing node pointers. No create/destroy, no runtime
/// registry rebuild; only marks order/layout dirty. The World.elements sibling list
/// must be synced on reorder (appendChild/removeChild* both sync). The render path
/// reads Node.children today, but the migration target is the World list; a silent
/// split between the two tables would corrupt render order.
pub fn replaceChildOrder(self: *Node, allocator: Allocator, ordered_children: []const *Node) !void {
    if (std.mem.eql(*Node, self.children.items, ordered_children)) return;

    // Callers may pass a slice of self.children. Snapshot before any capacity
    // change or write, and reject duplicates before publishing either tree.
    const order = try allocator.dupe(*Node, ordered_children);
    defer allocator.free(order);
    var seen: std.AutoHashMapUnmanaged(*Node, void) = .{};
    defer seen.deinit(allocator);
    var membership_changed = order.len != self.children.items.len;
    for (order) |child| {
        try validateChild(self, child);
        const entry = try seen.getOrPut(allocator, child);
        if (entry.found_existing) return error.DuplicateChild;
        membership_changed = membership_changed or child.parent != self;
    }
    try self.children.ensureTotalCapacity(allocator, order.len);

    // Retain omitted nodes and their resources, matching removeChildRetained.
    // Ownership stays with the caller; this operation never runs cleanup.
    for (self.children.items) |child| {
        syncWorldStructure(self, child, .unlink);
        child.parent = null;
    }
    self.children.clearRetainingCapacity();
    g_structure_revision +%= 1;
    for (order) |child| {
        if (child.parent) |old_parent| old_parent.removeChildRetained(child);
        self.children.appendAssumeCapacity(child);
        child.parent = self;
        if (child.frame_state.state_bits.flags.has_custom_draw_subtree) self.markCustomDrawSubtree();
        if (child.frame_state.state_bits.flags.has_text_subtree) self.markSubtreeText();
        if (child.frame_state.state_bits.flags.has_before_render_subtree) self.markSubtreeBeforeRenderHook();
        if (membership_changed) {
            child.frame_state.state_bits.dirty.runtime.dirty = true;
            child.frame_state.state_bits.dirty.runtime.subtree_dirty = true;
        }
        syncWorldStructure(self, child, .append);
    }
    if (membership_changed) self.markRuntimeIndexDirty();
    self.markOrderDirty();
    self.markLayoutDirty();
}

/// Remove child from parent, recursively fire onCleanup. Note: doesn't free child
/// memory; caller must manually `cx.freeNode(child)`. on_cleanup is one-shot
/// (fires and detaches); reattaching same node goes through removeChildRetained
/// which doesn't fire or consume cleanup.
pub fn removeChild(self: *Node, child: *Node) void {
    removeChildInternal(self, child, true);
}

pub fn removeChildIncremental(self: *Node, child: *Node) void {
    removeChildInternal(self, child, false);
}

pub fn removeChildRetained(self: *Node, child: *Node) void {
    removeChildRetainedInternal(self, child, false);
}

fn removeChildInternal(self: *Node, child: *Node, full_runtime_rebuild: bool) void {
    if (child.parent != self or std.mem.indexOfScalar(*Node, self.children.items, child) == null) return;
    node_mod.fireCleanupCallbacks(child);
    removeChildRetainedInternal(self, child, full_runtime_rebuild);
}

fn removeChildRetainedInternal(self: *Node, child: *Node, full_runtime_rebuild: bool) void {
    if (child.parent != self) return;
    const index = std.mem.indexOfScalar(*Node, self.children.items, child) orelse return;
    _ = self.children.orderedRemove(index);
    g_structure_revision +%= 1;
    if (full_runtime_rebuild) {
        self.markRuntimeIndexFullRebuild();
    }
    child.parent = null;
    self.markLayoutDirty();
    // P0-3 phase 3: same as above, direct owner World.
    syncWorldStructure(self, child, .unlink);
}

/// Remove all children, recursively fire onCleanup. Note: doesn't free memory;
/// caller must manually `cx.freeNode()` each child.
pub fn removeAllChildren(self: *Node) void {
    // Cleanup callbacks may synchronously detach/reparent children. Never keep
    // an iterator over the old ArrayList slice across those callbacks: removal
    // shifts entries and poisons the vacated tail in Debug builds.
    while (self.children.items.len > 0) {
        removeChildInternal(self, self.children.items[0], false);
    }
    self.markRuntimeIndexDirty();
    self.markLayoutDirty();
}
