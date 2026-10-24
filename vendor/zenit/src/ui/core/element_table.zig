//! ElementTable: SoA storage for Node's logical tree.
//!
//! Node is a 107-field god-object mixing logical-tree / layout / render-cache / hit / focus. This
//! table stores only the logical tree (like React Element / Flutter Widget): tag, parent, children
//! linked list, component owner, key (for reconcile).
//!
//! Design points:
//! - **MultiArrayList**: independent contiguous field arrays, cache-line friendly; dirty frames
//!   scan only needed fields
//! - **ElementId generational handle**: cross-frame ownership doesn't dangle (generation prevents
//!   ABA)
//! - **linked-list subtree**: parent + first_child + next_sibling, no std.ArrayList(Children); O(1)
//!   add/remove, O(n) traversal; no children-array reallocation churn
//! - **owner_component**: which component instance created this element (for reconcile / dispose)
//!
//! Constraints:
//! - cc::Layer lesson: no layout / render / interaction fields here (LayoutTable / PaintTable /
//!   InteractionTable)
//! - no *Node pointers; index everything by ElementId

const std = @import("std");
const testing = std.testing;
const element_id = @import("element_id.zig");

pub const ElementId = element_id.ElementId;
// Re-export SlotMap so bench doesn't need separate import of element_id (avoids conflicts).
pub const SlotMap = element_id.SlotMap;

/// Element tag used for fast reconcile diff checks (is it the same kind). Currently covers main
/// categories, extensible later.
pub const ElementTag = enum(u16) {
    /// Container: div / box / vstack / hstack / scroll_area
    container,
    /// Text node
    text,
    /// Image / icon / svg
    image,
    /// Input / textarea
    input,
    /// Custom component root (owner_component != NULL)
    component,
    /// Placeholder (temporary fill during reconcile)
    placeholder,
    /// Debug / test use
    debug,
};

/// Subtree linking with singly-linked list (first_child + next_sibling)
/// to avoid dynamic array growth.
pub const ElementLinks = struct {
    parent: ElementId = ElementId.NULL,
    first_child: ElementId = ElementId.NULL,
    last_child: ElementId = ElementId.NULL,
    next_sibling: ElementId = ElementId.NULL,
    prev_sibling: ElementId = ElementId.NULL,
};

/// SoA field set; MultiArrayList takes a struct type, one independent array per field.
pub const Element = struct {
    tag: ElementTag,
    /// For reconcile: (tag, key) uniquely identifies a child under the same parent; NULL key falls
    /// back to sequential matching.
    key: u64,
    /// Id of the component instance that created this element (NULL = not created by a
    /// component).
    owner_component: ElementId = ElementId.NULL,
    /// Subtree links.
    links: ElementLinks = .{},
    /// User marker bits (debug name index or source location).
    user_tag: u32 = 0,
};

pub const ElementTable = struct {
    allocator: std.mem.Allocator,
    /// SoA storage; MultiArrayList provides .items(.field_name) for each field's independent
    /// array.
    elements: std.MultiArrayList(Element),
    /// generation per slot
    generations: std.ArrayListUnmanaged(u8),
    /// Free list (slot index).
    free_list: std.ArrayListUnmanaged(u24),
    /// Retired slots remain allocated but are not live elements.
    live_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) ElementTable {
        return .{
            .allocator = allocator,
            .elements = .{},
            .generations = .empty,
            .free_list = .empty,
        };
    }

    pub fn deinit(self: *ElementTable) void {
        self.elements.deinit(self.allocator);
        self.generations.deinit(self.allocator);
        self.free_list.deinit(self.allocator);
        self.* = undefined;
    }

    /// Create a new element, return ElementId.
    ///
    /// Generation retirement (anti-ABA): even generation = live, odd = dead.
    /// Once generation wraps, stale ids would become live again. Same strategy as
    /// element_id.SlotMap: slots at MAX_GEN retire permanently
    /// (never allocated again, never added to free_list).
    ///
    /// Both create and destroy advance it once; either reaching MAX_GEN retires the slot;
    /// otherwise create advances to 255 then destroy's `+%=` wraps to 0. MAX_GEN is also NULL's
    /// generation; normal ids never carry it.
    ///
    /// Slot budget: ~128 lifetimes per slot, 16M total slots = ~10^9 destroy calls;
    /// exhaustion yields error.ElementTableFull, not UB.
    pub fn create(self: *ElementTable, e: Element) !ElementId {
        while (self.free_list.pop()) |idx| {
            const next_gen = self.generations.items[idx] +% 1;
            if (next_gen == element_id.MAX_GEN) {
                // Retire: pin at MAX_GEN (!= any issued id); slot is never reused.
                self.generations.items[idx] = element_id.MAX_GEN;
                continue;
            }
            self.elements.set(idx, e);
            self.generations.items[idx] = next_gen;
            self.live_count += 1;
            return .{ .index = idx, .generation = next_gen };
        }
        const idx = self.elements.len;
        if (idx >= element_id.MAX_INDEX) return error.ElementTableFull;
        // Reserve all parallel storage before publishing a slot. Reserving a
        // free-list entry for every slot makes destruction allocation-free,
        // including rollback while the allocator is still failing.
        try self.elements.ensureTotalCapacity(self.allocator, idx + 1);
        try self.generations.ensureTotalCapacity(self.allocator, idx + 1);
        try self.free_list.ensureTotalCapacity(self.allocator, idx + 1);
        self.elements.appendAssumeCapacity(e);
        self.generations.appendAssumeCapacity(0);
        self.live_count += 1;
        return .{ .index = @intCast(idx), .generation = 0 };
    }

    /// Destroy element: unlink from parent chain, generation++ to prevent ABA, slot returns to
    /// free list. The caller destroys the subtree recursively (not done here to avoid implicit
    /// cascades).
    pub fn destroy(self: *ElementTable, id: ElementId) void {
        if (!self.isValid(id)) return;
        // Unlink from parent/child chain
        self.unlink(id);
        self.live_count -= 1;
        self.generations.items[id.index] +%= 1;
        // Generation retirement: a slot advanced to MAX_GEN is not returned to free_list (see
        // create).
        if (self.generations.items[id.index] == element_id.MAX_GEN) return;
        self.free_list.appendAssumeCapacity(id.index);
    }

    pub fn isValid(self: *const ElementTable, id: ElementId) bool {
        if (id.isNull()) return false;
        // Fresh/live generations are even; destroy makes them odd. Reject
        // handles reconstructed from a dead slot's current generation too.
        if (id.generation & 1 != 0) return false;
        if (id.index >= self.elements.len) return false;
        return self.generations.items[id.index] == id.generation;
    }

    /// Read a copy of the whole Element.
    pub fn get(self: *const ElementTable, id: ElementId) ?Element {
        if (!self.isValid(id)) return null;
        return self.elements.get(id.index);
    }

    /// Read tag (called frequently, goes straight to SoA).
    pub fn tag(self: *const ElementTable, id: ElementId) ?ElementTag {
        if (!self.isValid(id)) return null;
        return self.elements.items(.tag)[id.index];
    }

    /// Read links (frequent, used for traversal).
    pub fn links(self: *const ElementTable, id: ElementId) ?ElementLinks {
        if (!self.isValid(id)) return null;
        return self.elements.items(.links)[id.index];
    }

    fn linksMut(self: *ElementTable, id: ElementId) *ElementLinks {
        return &self.elements.items(.links)[id.index];
    }

    // --- Tree operations ---

    /// Append child to parent's last_child. Child must not be linked to any parent.
    pub fn appendChild(self: *ElementTable, parent: ElementId, child: ElementId) void {
        if (!self.isValid(parent) or !self.isValid(child)) return;
        const child_links = self.linksMut(child);
        std.debug.assert(child_links.parent.isNull()); // reparent without unlink is not allowed
        child_links.parent = parent;
        child_links.next_sibling = ElementId.NULL;

        const parent_links = self.linksMut(parent);
        if (parent_links.first_child.isNull()) {
            parent_links.first_child = child;
            parent_links.last_child = child;
            child_links.prev_sibling = ElementId.NULL;
        } else {
            // Symmetric with unlink / insertBefore: don't write invalid last (slot may be reused).
            const last = parent_links.last_child;
            if (self.isValid(last)) {
                child_links.prev_sibling = last;
                self.linksMut(last).next_sibling = child;
            } else {
                child_links.prev_sibling = ElementId.NULL;
                parent_links.first_child = child;
            }
            parent_links.last_child = child;
        }
    }

    /// Insert child before parent's `before` node; null `before` acts like appendChild.
    /// Child must not be linked to any parent. When `before` is not a child of parent, degrades to
    /// append (no error here; caller node_tree.syncWorldInsertBefore validates before's parent and
    /// reroutes to full re-parenting if inconsistent, so this case isn't reached).
    pub fn insertBefore(self: *ElementTable, parent: ElementId, child: ElementId, before: ElementId) void {
        if (!self.isValid(parent) or !self.isValid(child)) return;
        if (before.isNull() or !self.isValid(before) or !self.linksMut(before).parent.eql(parent)) {
            self.appendChild(parent, child);
            return;
        }
        const child_links = self.linksMut(child);
        std.debug.assert(child_links.parent.isNull()); // reparent without unlink is not allowed
        // prev must go through isValid, same as unlink: if a stale prev was reused, a raw write
        // would modify the new element. When stale, treat child as the list head (the original
        // predecessor no longer exists).
        const raw_prev = self.linksMut(before).prev_sibling;
        const prev = if (!raw_prev.isNull() and self.isValid(raw_prev)) raw_prev else ElementId.NULL;
        child_links.parent = parent;
        child_links.next_sibling = before;
        child_links.prev_sibling = prev;
        self.linksMut(before).prev_sibling = child;
        if (prev.isNull()) {
            self.linksMut(parent).first_child = child;
        } else {
            self.linksMut(prev).next_sibling = child;
        }
    }

    /// Unlink child from parent's chain (does not destroy the element).
    ///
    /// parent/prev/next must pass isValid: when the parent is destroyed before its children, the
    /// child's parent id is stale (slot may be reused by a new element), and raw linksMut would
    /// write
    /// through to the reused element's first_child/last_child (silent list corruption).
    /// Mirrors appendChild's bidirectional checks.
    pub fn unlink(self: *ElementTable, id: ElementId) void {
        if (!self.isValid(id)) return;
        const my_links = self.linksMut(id);
        if (my_links.parent.isNull()) return; // Already detached

        const prev = my_links.prev_sibling;
        const next = my_links.next_sibling;
        const parent = my_links.parent;

        if (!prev.isNull()) {
            if (self.isValid(prev)) self.linksMut(prev).next_sibling = next;
        } else if (self.isValid(parent)) {
            // I am first_child
            self.linksMut(parent).first_child = next;
        }
        if (!next.isNull()) {
            if (self.isValid(next)) self.linksMut(next).prev_sibling = prev;
        } else if (self.isValid(parent)) {
            // I am last_child
            self.linksMut(parent).last_child = prev;
        }

        my_links.parent = ElementId.NULL;
        my_links.prev_sibling = ElementId.NULL;
        my_links.next_sibling = ElementId.NULL;
    }

    /// Child traversal helper.
    pub const ChildIterator = struct {
        table: *const ElementTable,
        next_id: ElementId,

        pub fn next(self: *ChildIterator) ?ElementId {
            if (self.next_id.isNull()) return null;
            const cur = self.next_id;
            const lk = self.table.links(cur) orelse return null;
            self.next_id = lk.next_sibling;
            return cur;
        }
    };

    pub fn children(self: *const ElementTable, parent: ElementId) ChildIterator {
        const lk = self.links(parent) orelse return .{ .table = self, .next_id = ElementId.NULL };
        return .{ .table = self, .next_id = lk.first_child };
    }

    pub fn count(self: *const ElementTable) usize {
        return self.live_count;
    }

    /// Count children of a parent (O(n)).
    pub fn childCount(self: *const ElementTable, parent: ElementId) u32 {
        var iter = self.children(parent);
        var n: u32 = 0;
        while (iter.next() != null) n += 1;
        return n;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ElementTable: create/get/destroy" {
    var t = ElementTable.init(testing.allocator);
    defer t.deinit();

    const id = try t.create(.{ .tag = .container, .key = 42 });
    const e = t.get(id).?;
    try testing.expectEqual(ElementTag.container, e.tag);
    try testing.expectEqual(@as(u64, 42), e.key);

    t.destroy(id);
    try testing.expect(t.get(id) == null);
    try testing.expect(!t.isValid(id));
}

test "ElementTable: appendChild builds linked list" {
    var t = ElementTable.init(testing.allocator);
    defer t.deinit();

    const root = try t.create(.{ .tag = .container, .key = 0 });
    const c1 = try t.create(.{ .tag = .text, .key = 1 });
    const c2 = try t.create(.{ .tag = .text, .key = 2 });
    const c3 = try t.create(.{ .tag = .text, .key = 3 });

    t.appendChild(root, c1);
    t.appendChild(root, c2);
    t.appendChild(root, c3);

    try testing.expectEqual(@as(u32, 3), t.childCount(root));

    var iter = t.children(root);
    const ids = [_]ElementId{ c1, c2, c3 };
    var i: usize = 0;
    while (iter.next()) |got| {
        try testing.expect(got.eql(ids[i]));
        i += 1;
    }
    try testing.expectEqual(@as(usize, 3), i);
}

test "ElementTable: insertBefore 链头 / 链中 / NULL 退化为追加，前后指针双向一致" {
    var t = ElementTable.init(testing.allocator);
    defer t.deinit();

    const root = try t.create(.{ .tag = .container, .key = 0 });
    const a = try t.create(.{ .tag = .text, .key = 1 });
    const b = try t.create(.{ .tag = .text, .key = 2 });
    const c = try t.create(.{ .tag = .text, .key = 3 });
    const d = try t.create(.{ .tag = .text, .key = 4 });

    t.appendChild(root, c);
    t.insertBefore(root, a, c); // list head
    t.insertBefore(root, b, c); // mid-list
    t.insertBefore(root, d, ElementId.NULL); // append

    const want = [_]ElementId{ a, b, c, d };
    var iter = t.children(root);
    var i: usize = 0;
    while (iter.next()) |got| : (i += 1) try testing.expect(got.eql(want[i]));
    try testing.expectEqual(want.len, i);

    // Reverse links and first/last pointers
    const lk = t.links(root).?;
    try testing.expect(lk.first_child.eql(a));
    try testing.expect(lk.last_child.eql(d));
    var back = lk.last_child;
    var j: usize = want.len;
    while (!back.isNull()) {
        j -= 1;
        try testing.expect(back.eql(want[j]));
        back = t.links(back).?.prev_sibling;
    }
    try testing.expectEqual(@as(usize, 0), j);
}

test "ElementTable: insertBefore 遇到失效的 prev 不写穿被复用的 slot" {
    var t = ElementTable.init(testing.allocator);
    defer t.deinit();

    const root = try t.create(.{ .tag = .container, .key = 0 });
    const a = try t.create(.{ .tag = .text, .key = 1 });
    const b = try t.create(.{ .tag = .text, .key = 2 });
    t.appendChild(root, a);
    t.appendChild(root, b);
    // Simulate a stale prev left in the list: a's slot was destroyed and reused by another
    // element, b.prev still points at old a
    const stale_a = a;
    t.elements.items(.links)[a.index] = .{};
    t.destroy(a);
    const reused = try t.create(.{ .tag = .text, .key = 9 });
    try testing.expectEqual(stale_a.index, reused.index);
    t.elements.items(.links)[b.index].prev_sibling = stale_a;

    const c = try t.create(.{ .tag = .text, .key = 3 });
    t.insertBefore(root, c, b);
    try testing.expect(t.links(reused).?.next_sibling.isNull()); // reused slot was not overwritten
    try testing.expect(t.links(root).?.first_child.eql(c));
    try testing.expect(t.links(c).?.next_sibling.eql(b));
}

test "ElementTable: insertBefore 的 before 不是该 parent 的子节点时退化为追加" {
    var t = ElementTable.init(testing.allocator);
    defer t.deinit();

    const root = try t.create(.{ .tag = .container, .key = 0 });
    const other = try t.create(.{ .tag = .container, .key = 9 });
    const stranger = try t.create(.{ .tag = .text, .key = 8 });
    const a = try t.create(.{ .tag = .text, .key = 1 });
    const b = try t.create(.{ .tag = .text, .key = 2 });
    t.appendChild(other, stranger);
    t.appendChild(root, a);

    t.insertBefore(root, b, stranger);
    try testing.expect(t.links(root).?.last_child.eql(b));
    try testing.expect(t.links(b).?.prev_sibling.eql(a));
    try testing.expectEqual(@as(u32, 1), t.childCount(other));
}

test "ElementTable: unlink middle child" {
    var t = ElementTable.init(testing.allocator);
    defer t.deinit();

    const root = try t.create(.{ .tag = .container, .key = 0 });
    const c1 = try t.create(.{ .tag = .text, .key = 1 });
    const c2 = try t.create(.{ .tag = .text, .key = 2 });
    const c3 = try t.create(.{ .tag = .text, .key = 3 });

    t.appendChild(root, c1);
    t.appendChild(root, c2);
    t.appendChild(root, c3);

    t.unlink(c2);
    try testing.expectEqual(@as(u32, 2), t.childCount(root));

    // Order should be c1 -> c3
    var iter = t.children(root);
    try testing.expect(iter.next().?.eql(c1));
    try testing.expect(iter.next().?.eql(c3));
    try testing.expect(iter.next() == null);

    // c2 is detached
    const c2_links = t.links(c2).?;
    try testing.expect(c2_links.parent.isNull());
    try testing.expect(c2_links.prev_sibling.isNull());
    try testing.expect(c2_links.next_sibling.isNull());
}

test "ElementTable: unlink first child updates first_child" {
    var t = ElementTable.init(testing.allocator);
    defer t.deinit();

    const root = try t.create(.{ .tag = .container, .key = 0 });
    const c1 = try t.create(.{ .tag = .text, .key = 1 });
    const c2 = try t.create(.{ .tag = .text, .key = 2 });

    t.appendChild(root, c1);
    t.appendChild(root, c2);

    t.unlink(c1);
    const root_links = t.links(root).?;
    try testing.expect(root_links.first_child.eql(c2));
    try testing.expect(root_links.last_child.eql(c2));
}

test "ElementTable: unlink last child updates last_child" {
    var t = ElementTable.init(testing.allocator);
    defer t.deinit();

    const root = try t.create(.{ .tag = .container, .key = 0 });
    const c1 = try t.create(.{ .tag = .text, .key = 1 });
    const c2 = try t.create(.{ .tag = .text, .key = 2 });

    t.appendChild(root, c1);
    t.appendChild(root, c2);

    t.unlink(c2);
    const root_links = t.links(root).?;
    try testing.expect(root_links.first_child.eql(c1));
    try testing.expect(root_links.last_child.eql(c1));
}

test "ElementTable: destroy auto-unlinks" {
    var t = ElementTable.init(testing.allocator);
    defer t.deinit();

    const root = try t.create(.{ .tag = .container, .key = 0 });
    const c1 = try t.create(.{ .tag = .text, .key = 1 });
    t.appendChild(root, c1);

    t.destroy(c1);
    const root_links = t.links(root).?;
    try testing.expect(root_links.first_child.isNull());
    try testing.expect(root_links.last_child.isNull());
}

test "ElementTable: free list reuses slots, generation differs" {
    var t = ElementTable.init(testing.allocator);
    defer t.deinit();

    const a = try t.create(.{ .tag = .text, .key = 1 });
    const idx_a = a.index;
    t.destroy(a);

    const b = try t.create(.{ .tag = .text, .key = 2 });
    try testing.expectEqual(idx_a, b.index);
    try testing.expect(a.generation != b.generation);
    try testing.expect(!t.isValid(a));
    try testing.expect(t.isValid(b));
}

test "ElementTable: SoA tag access" {
    var t = ElementTable.init(testing.allocator);
    defer t.deinit();

    const a = try t.create(.{ .tag = .container, .key = 0 });
    const b = try t.create(.{ .tag = .text, .key = 1 });
    try testing.expectEqual(ElementTag.container, t.tag(a).?);
    try testing.expectEqual(ElementTag.text, t.tag(b).?);
}

test "ElementTable: count tracks live elements" {
    var t = ElementTable.init(testing.allocator);
    defer t.deinit();

    const a = try t.create(.{ .tag = .text, .key = 0 });
    _ = try t.create(.{ .tag = .text, .key = 1 });
    _ = try t.create(.{ .tag = .text, .key = 2 });
    try testing.expectEqual(@as(usize, 3), t.count());

    t.destroy(a);
    try testing.expectEqual(@as(usize, 2), t.count());
}

test "ElementTable: 世代回卷前 slot 永久退役（ABA 防线）" {
    var t = ElementTable.init(testing.allocator);
    defer t.deinit();

    // Repeated create/destroy on a single slot: generation +2 per cycle (create reuse +1, destroy
    // +1). With the old `+%=` wrap, the 256th reuse would make the earliest id isValid again
    // (ABA).
    const first = try t.create(.{ .tag = .container, .key = 0 });
    t.destroy(first);

    var cycles: u32 = 0;
    while (cycles < 200) : (cycles += 1) {
        const id = t.create(.{ .tag = .container, .key = 1 }) catch break;
        // Once the slot retires, create takes the fresh-append path and allocates a new index
        if (id.index != first.index) break;
        try testing.expect(!t.isValid(first)); // A stale id must never come back to life at any time
        t.destroy(id);
    }
    // Loop breaks on slot retirement changing index (correct), or runs 200 cycles.
    // 200*2 > 255, old impl must have wrapped, isValid assert above catches it.
    try testing.expect(cycles < 200);
    try testing.expect(!t.isValid(first));
}

test "ElementTable: 先销毁父再销毁子不得写穿复用 slot" {
    var t = ElementTable.init(testing.allocator);
    defer t.deinit();

    const parent = try t.create(.{ .tag = .container, .key = 0 });
    const child = try t.create(.{ .tag = .text, .key = 1 });
    t.appendChild(parent, child);

    // Violate the usual order: destroy parent first (destroy unlinks itself but child.links.parent
    // still points at the old slot). Note destroy(parent) only unlinks parent itself, not
    // recursive; child's parent reference dangles.
    t.destroy(parent);

    // Parent slot reused by new element with its own children,
    // list fields non-NULL, write-through is observable (NULL over NULL isn't).
    const reused = try t.create(.{ .tag = .container, .key = 2 });
    try testing.expectEqual(parent.index, reused.index);
    const grandchild = try t.create(.{ .tag = .text, .key = 3 });
    t.appendChild(reused, grandchild);
    const reused_links_before = t.links(reused).?;
    try testing.expect(!reused_links_before.first_child.isNull());

    // Destroying child: unlink has stale parent id (prev/next both NULL -> takes
    // first_child/last_child branch), must not clear reused list fields to NULL.
    t.destroy(child);
    const reused_links_after = t.links(reused).?;
    try testing.expectEqual(reused_links_before.first_child.raw(), reused_links_after.first_child.raw());
    try testing.expectEqual(reused_links_before.last_child.raw(), reused_links_after.last_child.raw());
}
