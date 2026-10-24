//! NSAccessibility Router: a11y_tree -> platform bridge routing.
//!
//! Converts the AccessibilityTree dirty queue to platform bridge calls:
//! - role/state/value changes -> bridge.notifyPropertyChange
//! - focus change -> bridge.notifyFocusChange
//! - live region announce -> bridge.announceText
//! - structure change -> bridge.notifyChildrenChanged (re-pull children)
//!
//! ObjC side: native/macos/window_bridge.m ZenitA11yElement implements the NSAccessibility
//! protocol (roles/subroles, value/min/max, focus, hit-test, table protocol, AXTextArea suite
//! incl. selectedTextRange / frameForRange / rangeForLine / insertionPointLineNumber,
//! UTF-8<->UTF-16
//! offsets). Router + a11y_macos_bridge are wired in src/ui/core.zig / ui.zig.
//! Not done: attributed run (bold/link/spell) announce, AXCustomRotor, custom actions beyond
//! press/increment/decrement, real VoiceOver acceptance.

const std = @import("std");
const testing = std.testing;
const tree_mod = @import("tree.zig");
const element_id_mod = @import("../core/element_id.zig");

pub const ElementId = element_id_mod.ElementId;
pub const AXId = tree_mod.AXId;
pub const A11yNode = tree_mod.A11yNode;
pub const A11yDirtyFlag = tree_mod.A11yDirtyFlag;
pub const AccessibilityTree = tree_mod.AccessibilityTree;

/// Router receives dirty notifications, call appropriate platform bridge.
/// Platform bridge is trait-style vtable, lets different platforms implement + unit-test stub.
pub const PlatformBridge = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        notify_property: *const fn (ctx: *anyopaque, id: AXId, node: A11yNode, flag: A11yDirtyFlag) void,
        /// `node == null` means focus left the retained Zenit tree. Platforms
        /// should move accessibility focus back to the host/window, not retain
        /// a stale virtual element.
        notify_focus: *const fn (ctx: *anyopaque, id: AXId, node: ?A11yNode) void,
        notify_children_changed: *const fn (ctx: *anyopaque, id: AXId) void,
        announce: *const fn (ctx: *anyopaque, id: AXId, text_hash: u64, live: tree_mod.LiveRegion) void,
        /// aria-activedescendant change -> platform AXSelectedChildren (NSAccessibility)
        /// or IA2_STATE_ACTIVE (Windows IA2). Optional: null -> skip.
        notify_active_descendant: ?*const fn (ctx: *anyopaque, container: AXId, active: AXId) void = null,
        /// Node leaves tree (deleted or replaced by new generation in slot). Platform should
        /// post UIElementDestroyed and discard corresponding native proxy, else VoiceOver cursor
        /// may stop on nonexistent element. Optional: null skip.
        notify_destroyed: ?*const fn (ctx: *anyopaque, id: AXId) void = null,
        /// Flush ends. Platform can coalesce accumulated layout notifications (one ancestor,
        /// one send). Optional: null skip.
        flush_end: ?*const fn (ctx: *anyopaque) void = null,
    };

    pub fn notifyProperty(self: PlatformBridge, id: AXId, node: A11yNode, flag: A11yDirtyFlag) void {
        self.vtable.notify_property(self.ctx, id, node, flag);
    }
    pub fn notifyFocus(self: PlatformBridge, id: AXId, node: ?A11yNode) void {
        self.vtable.notify_focus(self.ctx, id, node);
    }
    pub fn notifyChildrenChanged(self: PlatformBridge, id: AXId) void {
        self.vtable.notify_children_changed(self.ctx, id);
    }
    pub fn announce(self: PlatformBridge, id: AXId, text_hash: u64, live: tree_mod.LiveRegion) void {
        self.vtable.announce(self.ctx, id, text_hash, live);
    }
    pub fn notifyDestroyed(self: PlatformBridge, id: AXId) void {
        if (self.vtable.notify_destroyed) |cb| cb(self.ctx, id);
    }

    pub fn notifyActiveDescendant(self: PlatformBridge, container: AXId, active: AXId) void {
        if (self.vtable.notify_active_descendant) |cb| cb(self.ctx, container, active);
    }
};

/// Flush a11y tree dirty queue to platform.
pub fn flushToBridge(
    tree: *AccessibilityTree,
    bridge: PlatformBridge,
) void {
    const Ctx = struct {
        tree: *AccessibilityTree,
        bridge: PlatformBridge,
        focus_changed: bool = false,
    };
    var ctx = Ctx{ .tree = tree, .bridge = bridge };
    tree.drainDirty(&ctx, &dispatch);
    // Coalesce old-focus/new-focus records into one notification for final retained state.
    // Hash-map iteration must never decide AX focus. Send layout notification first, focus last:
    // VoiceOver only announces final focus event (AccessKit experience), layout after makes
    // it recalculate cursor position.
    if (bridge.vtable.flush_end) |cb| cb(bridge.ctx);
    if (ctx.focus_changed) {
        const focused = tree.focused;
        ctx.bridge.notifyFocus(focused, tree.get(focused));
    }
}

fn dispatch(ctx_ptr: *anyopaque, id: AXId, flag: A11yDirtyFlag) void {
    const Ctx = struct {
        tree: *AccessibilityTree,
        bridge: PlatformBridge,
        focus_changed: bool = false,
    };
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));

    if (flag.structure_changed) {
        if (ctx.tree.structureChange(id)) |change| {
            if (change.had_old and !change.old_hidden) {
                ctx.bridge.notifyChildrenChanged(change.old_parent);
            }
            if (change.has_new and !change.new_hidden and
                (!change.had_old or change.old_hidden or !change.old_parent.eql(change.new_parent)))
            {
                ctx.bridge.notifyChildrenChanged(change.new_parent);
            }
            // A same-parent reorder is already covered by the old-parent
            // notification above; do not post the identical layout change
            // twice.
            if (change.had_old and !change.has_new) ctx.bridge.notifyDestroyed(id);
        }
    }
    const node = ctx.tree.get(id);
    if (node != null and (flag.role_changed or flag.state_changed or flag.label_changed or
        flag.value_changed or flag.geometry_changed or flag.selection_changed or flag.row_count_changed))
    {
        ctx.bridge.notifyProperty(id, node.?, flag);
    }
    if (flag.focus_changed) {
        ctx.focus_changed = true;
    }
    if (flag.live_announce and node != null) {
        ctx.bridge.announce(id, tree_mod.announcementHash(node.?), node.?.live);
    }
    if (flag.active_descendant_changed and node != null) {
        ctx.bridge.notifyActiveDescendant(id, node.?.active_descendant);
    }
}

// ============================================================================
// Tests
// ============================================================================

const TestBridge = struct {
    property_calls: std.ArrayListUnmanaged(AXId) = .empty,
    focus_calls: std.ArrayListUnmanaged(AXId) = .empty,
    children_calls: std.ArrayListUnmanaged(AXId) = .empty,
    announce_calls: std.ArrayListUnmanaged(u64) = .empty,
    active_desc_calls: std.ArrayListUnmanaged(struct { container: AXId, active: AXId }) = .empty,
    destroyed_calls: std.ArrayListUnmanaged(AXId) = .empty,
    allocator: std.mem.Allocator,

    fn vtable() *const PlatformBridge.VTable {
        const Static = struct {
            const v = PlatformBridge.VTable{
                .notify_property = TestBridge.notifyProperty,
                .notify_focus = TestBridge.notifyFocus,
                .notify_children_changed = TestBridge.notifyChildrenChanged,
                .announce = TestBridge.announce,
                .notify_active_descendant = TestBridge.notifyActiveDescendant,
                .notify_destroyed = TestBridge.notifyDestroyed,
            };
        };
        return &Static.v;
    }

    fn bridge(self: *TestBridge) PlatformBridge {
        return .{ .ctx = self, .vtable = vtable() };
    }

    fn notifyProperty(ctx: *anyopaque, id: AXId, node: A11yNode, flag: A11yDirtyFlag) void {
        const self: *TestBridge = @ptrCast(@alignCast(ctx));
        self.property_calls.append(self.allocator, id) catch {};
        _ = node;
        _ = flag;
    }
    fn notifyFocus(ctx: *anyopaque, id: AXId, node: ?A11yNode) void {
        const self: *TestBridge = @ptrCast(@alignCast(ctx));
        self.focus_calls.append(self.allocator, id) catch {};
        _ = node;
    }
    fn notifyChildrenChanged(ctx: *anyopaque, id: AXId) void {
        const self: *TestBridge = @ptrCast(@alignCast(ctx));
        self.children_calls.append(self.allocator, id) catch {};
    }
    fn announce(ctx: *anyopaque, id: AXId, text_hash: u64, live: tree_mod.LiveRegion) void {
        const self: *TestBridge = @ptrCast(@alignCast(ctx));
        self.announce_calls.append(self.allocator, text_hash) catch {};
        _ = id;
        _ = live;
    }
    fn notifyActiveDescendant(ctx: *anyopaque, container: AXId, active: AXId) void {
        const self: *TestBridge = @ptrCast(@alignCast(ctx));
        self.active_desc_calls.append(self.allocator, .{ .container = container, .active = active }) catch {};
    }

    fn notifyDestroyed(ctx: *anyopaque, id: AXId) void {
        const self: *TestBridge = @ptrCast(@alignCast(ctx));
        self.destroyed_calls.append(self.allocator, id) catch {};
    }

    fn deinit(self: *TestBridge) void {
        self.destroyed_calls.deinit(self.allocator);
        self.property_calls.deinit(self.allocator);
        self.focus_calls.deinit(self.allocator);
        self.children_calls.deinit(self.allocator);
        self.announce_calls.deinit(self.allocator);
        self.active_desc_calls.deinit(self.allocator);
    }
};

test "router: structure_changed triggers notifyChildrenChanged on parent" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var bridge = TestBridge{ .allocator = testing.allocator };
    defer bridge.deinit();

    const parent = AXId.node(.{ .index = 0, .generation = 0 });
    const child = AXId.node(.{ .index = 1, .generation = 0 });
    try tree.upsert(.{ .element = parent, .role = .group });
    try tree.upsert(.{ .element = child, .parent = parent, .role = .button });

    flushToBridge(&tree, bridge.bridge());

    try testing.expect(bridge.children_calls.items.len >= 1);
}

test "router: state_changed → notifyProperty" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var bridge = TestBridge{ .allocator = testing.allocator };
    defer bridge.deinit();

    const id = AXId.node(.{ .index = 0, .generation = 0 });
    try tree.upsert(.{ .element = id, .role = .checkbox });
    flushToBridge(&tree, bridge.bridge());
    bridge.property_calls.clearRetainingCapacity();

    try tree.upsert(.{ .element = id, .role = .checkbox, .state = .{ .checked = true } });
    flushToBridge(&tree, bridge.bridge());

    try testing.expectEqual(@as(usize, 1), bridge.property_calls.items.len);
}

test "router: focus_changed + focused=true → notifyFocus" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var bridge = TestBridge{ .allocator = testing.allocator };
    defer bridge.deinit();

    const id = AXId.node(.{ .index = 0, .generation = 0 });
    try tree.upsert(.{ .element = id, .role = .button });
    flushToBridge(&tree, bridge.bridge());
    bridge.focus_calls.clearRetainingCapacity();

    try tree.upsert(.{ .element = id, .role = .button, .state = .{ .focused = true, .focusable = true } });
    flushToBridge(&tree, bridge.bridge());

    try testing.expectEqual(@as(usize, 1), bridge.focus_calls.items.len);
}

test "router: removed children and roots invalidate their former containers" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var bridge = TestBridge{ .allocator = testing.allocator };
    defer bridge.deinit();

    const root = AXId.node(.{ .index = 0, .generation = 0 });
    const child = AXId.node(.{ .index = 1, .generation = 0 });
    try tree.upsert(.{ .element = root, .role = .group });
    try tree.upsert(.{ .element = child, .parent = root, .role = .button });
    flushToBridge(&tree, bridge.bridge());
    bridge.children_calls.clearRetainingCapacity();

    try tree.remove(child);
    flushToBridge(&tree, bridge.bridge());
    try testing.expectEqual(@as(usize, 1), bridge.children_calls.items.len);
    try testing.expect(bridge.children_calls.items[0].eql(root));

    bridge.children_calls.clearRetainingCapacity();
    try tree.remove(root);
    flushToBridge(&tree, bridge.bridge());
    try testing.expectEqual(@as(usize, 1), bridge.children_calls.items.len);
    try testing.expect(bridge.children_calls.items[0].isNull());
}

test "router: reparent and reorder invalidate every affected container" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var bridge = TestBridge{ .allocator = testing.allocator };
    defer bridge.deinit();

    const a = AXId.node(.{ .index = 0, .generation = 0 });
    const b = AXId.node(.{ .index = 1, .generation = 0 });
    const child = AXId.node(.{ .index = 2, .generation = 0 });
    try tree.upsert(.{ .element = a, .role = .group });
    try tree.upsert(.{ .element = b, .role = .group });
    try tree.upsert(.{ .element = child, .parent = a, .role = .button });
    flushToBridge(&tree, bridge.bridge());
    bridge.children_calls.clearRetainingCapacity();

    try tree.upsert(.{ .element = child, .parent = b, .role = .button });
    flushToBridge(&tree, bridge.bridge());
    try testing.expectEqual(@as(usize, 2), bridge.children_calls.items.len);
    var saw_a = false;
    var saw_b = false;
    for (bridge.children_calls.items) |id| {
        saw_a = saw_a or id.eql(a);
        saw_b = saw_b or id.eql(b);
    }
    try testing.expect(saw_a and saw_b);

    bridge.children_calls.clearRetainingCapacity();
    try tree.upsert(.{ .element = child, .parent = b, .role = .button, .sibling_index = 7 });
    flushToBridge(&tree, bridge.bridge());
    try testing.expectEqual(@as(usize, 1), bridge.children_calls.items.len);
    try testing.expect(bridge.children_calls.items[0].eql(b));
}

test "router: focus changes coalesce to final element and clear on removal" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var bridge = TestBridge{ .allocator = testing.allocator };
    defer bridge.deinit();

    const a = AXId.node(.{ .index = 0, .generation = 0 });
    const b = AXId.node(.{ .index = 1, .generation = 0 });
    try tree.upsert(.{ .element = a, .role = .button, .state = .{ .focused = true, .focusable = true } });
    try tree.upsert(.{ .element = b, .role = .button });
    flushToBridge(&tree, bridge.bridge());
    try testing.expectEqual(@as(usize, 1), bridge.focus_calls.items.len);
    try testing.expect(bridge.focus_calls.items[0].eql(a));

    bridge.focus_calls.clearRetainingCapacity();
    try tree.upsert(.{ .element = b, .role = .button, .state = .{ .focused = true, .focusable = true } });
    flushToBridge(&tree, bridge.bridge());
    try testing.expectEqual(@as(usize, 1), bridge.focus_calls.items.len);
    try testing.expect(bridge.focus_calls.items[0].eql(b));

    bridge.focus_calls.clearRetainingCapacity();
    try tree.remove(b);
    flushToBridge(&tree, bridge.bridge());
    try testing.expectEqual(@as(usize, 1), bridge.focus_calls.items.len);
    try testing.expect(bridge.focus_calls.items[0].isNull());
}

test "router: live_announce on text_hash change in live region" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var bridge = TestBridge{ .allocator = testing.allocator };
    defer bridge.deinit();

    const id = AXId.node(.{ .index = 0, .generation = 0 });
    try tree.upsert(.{ .element = id, .role = .status, .live = .polite, .text_hash = 100 });
    flushToBridge(&tree, bridge.bridge());
    bridge.announce_calls.clearRetainingCapacity();

    try tree.upsert(.{ .element = id, .role = .status, .live = .polite, .text_hash = 200 });
    flushToBridge(&tree, bridge.bridge());

    try testing.expectEqual(@as(usize, 1), bridge.announce_calls.items.len);
    try testing.expectEqual(@as(u64, 200), bridge.announce_calls.items[0]);
}

test "router: active_descendant change → notifyActiveDescendant" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var bridge = TestBridge{ .allocator = testing.allocator };
    defer bridge.deinit();

    const container = AXId.node(.{ .index = 0, .generation = 0 });
    const opt_a = AXId.node(.{ .index = 1, .generation = 0 });
    const opt_b = AXId.node(.{ .index = 2, .generation = 0 });

    try tree.upsert(.{ .element = container, .role = .combobox });
    flushToBridge(&tree, bridge.bridge());
    bridge.active_desc_calls.clearRetainingCapacity();

    // Container declares active_descendant=A
    try tree.upsert(.{ .element = container, .role = .combobox, .active_descendant = opt_a });
    flushToBridge(&tree, bridge.bridge());
    try testing.expectEqual(@as(usize, 1), bridge.active_desc_calls.items.len);
    try testing.expect(bridge.active_desc_calls.items[0].container.eql(container));
    try testing.expect(bridge.active_desc_calls.items[0].active.eql(opt_a));

    // Switch to B
    bridge.active_desc_calls.clearRetainingCapacity();
    try tree.upsert(.{ .element = container, .role = .combobox, .active_descendant = opt_b });
    flushToBridge(&tree, bridge.bridge());
    try testing.expectEqual(@as(usize, 1), bridge.active_desc_calls.items.len);
    try testing.expect(bridge.active_desc_calls.items[0].active.eql(opt_b));

    // Unchanged -> don't emit
    bridge.active_desc_calls.clearRetainingCapacity();
    try tree.upsert(.{ .element = container, .role = .combobox, .active_descendant = opt_b });
    flushToBridge(&tree, bridge.bridge());
    try testing.expectEqual(@as(usize, 0), bridge.active_desc_calls.items.len);
}

test "router: 节点删除发 destroyed；换父只是移动，不算销毁" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var tb = TestBridge{ .allocator = testing.allocator };
    defer tb.deinit();

    const a = AXId.node(.{ .index = 1, .generation = 0 });
    const b = AXId.node(.{ .index = 2, .generation = 0 });
    const child = AXId.node(.{ .index = 3, .generation = 0 });
    try tree.upsert(.{ .element = a, .role = .group });
    try tree.upsert(.{ .element = b, .role = .group });
    try tree.upsert(.{ .element = child, .parent = a, .role = .button });
    flushToBridge(&tree, tb.bridge());
    tb.destroyed_calls.clearRetainingCapacity();

    // Parent change: not destruction.
    try tree.upsert(.{ .element = child, .parent = b, .role = .button });
    flushToBridge(&tree, tb.bridge());
    try testing.expectEqual(@as(usize, 0), tb.destroyed_calls.items.len);

    // Deletion: destruction.
    try tree.remove(child);
    flushToBridge(&tree, tb.bridge());
    try testing.expectEqual(@as(usize, 1), tb.destroyed_calls.items.len);
    try testing.expect(tb.destroyed_calls.items[0].eql(child));

    // New generation replaces in slot: old one destroyed.
    const stale = AXId.node(.{ .index = 2, .generation = 0 });
    const replacement = AXId.node(.{ .index = 2, .generation = 1 });
    tb.destroyed_calls.clearRetainingCapacity();
    try tree.upsert(.{ .element = replacement, .role = .button });
    flushToBridge(&tree, tb.bridge());
    try testing.expectEqual(@as(usize, 1), tb.destroyed_calls.items.len);
    try testing.expect(tb.destroyed_calls.items[0].eql(stale));
}
