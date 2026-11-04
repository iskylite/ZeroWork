//! Window-owned panels keep their nodes and Scope while closed, but leave the
//! window tree. This removes hidden settings/assistant nodes from frame scans.
//! Parent and panel are owned by this same window Scope; do not free them
//! independently. Detachment occurs after layout, never inside an input handler.
const std = @import("std");
const ui = @import("ui");

pub const Panel = struct {
    cx: *ui.Cx,
    parent: *ui.Node,
    node: *ui.Node,
    identity: ui.hit.NodeHandle,
    parent_identity: ui.hit.NodeHandle,
    before: ?*ui.Node,
    hook_installed: bool = false,
    attach_failed: bool = false,
    pending_focus: ?struct { node: *ui.Node, identity: ui.hit.NodeHandle, epoch: u64 } = null,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, node: *ui.Node) !*Panel {
        const self = try scope.allocator.create(Panel);
        var registered = false;
        errdefer if (!registered) scope.allocator.destroy(self);
        var before: ?*ui.Node = null;
        for (parent.children.items, 0..) |child, index| if (child == node) {
            if (index + 1 < parent.children.items.len) before = parent.children.items[index + 1];
            break;
        };
        self.* = .{
            .cx = cx,
            .parent = parent,
            .node = node,
            .before = before,
            .identity = .{ .id = node.id, .generation = try cx.node_registry.trackGeneration(node) },
            .parent_identity = .{ .id = parent.id, .generation = try cx.node_registry.trackGeneration(parent) },
        };
        try scope.registerResource(self, destroy);
        registered = true;
        // Resource ownership has transferred; an add-hook error is cleaned by
        // the window Scope, while the still-attached node remains parent-owned.
        try cx.addAfterLayoutHook(self, afterLayout);
        self.hook_installed = true;
        if (node.style.display == .none) self.detach();
        return self;
    }

    fn detach(self: *Panel) void {
        self.cx.detachChildRetained(self.parent, self.node);
        // Detach invalidates captured/queued input identities for the previous
        // geometry. The window Scope still owns this live branch, so establish
        // its next retained identity without reviving any old input handles.
        const generation = self.cx.node_registry.trackGeneration(self.node) catch return;
        self.identity = .{ .id = self.node.id, .generation = generation };
    }

    fn destroy(raw: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Panel = @ptrCast(@alignCast(raw));
        if (self.hook_installed) self.cx.removeAfterLayoutHook(self);
        if (self.cx.node_registry.isCurrentIdentity(self.identity, self.node)) {
            if (self.node.parent == null and !self.node.freeing and self.node.pending_free_cx == null)
                self.cx.freeDetachedNodeAfterScopeDispose(self.node);
        }
        allocator.destroy(self);
    }

    /// A detached control is not yet in the interaction registry. Preserve an
    /// opening focus request until attachment/index publication, without taking
    /// focus back after a newer user or modal focus transition.
    pub fn focusWhenAttached(self: *Panel, target: *ui.Node) void {
        const generation = self.cx.node_registry.trackGeneration(target) catch return;
        const identity: ui.hit.NodeHandle = .{ .id = target.id, .generation = generation };
        if (self.node.parent != null and self.cx.node_registry.resolve(identity, null) == target) {
            self.pending_focus = null;
            self.cx.setFocus(target);
            return;
        }
        self.pending_focus = .{ .node = target, .identity = identity, .epoch = self.cx.focus_manager.transition_epoch };
        self.cx.requestRedraw();
    }

    fn flushFocus(self: *Panel) void {
        const pending = self.pending_focus orelse return;
        if (self.node.style.display == .none or pending.epoch != self.cx.focus_manager.transition_epoch or
            !self.cx.node_registry.isCurrentIdentity(pending.identity, pending.node))
        {
            self.pending_focus = null;
            return;
        }
        if (self.cx.node_registry.resolve(pending.identity, null)) |target| {
            self.pending_focus = null;
            self.cx.setFocus(target);
        } else self.cx.scheduleRedrawAfterNs(std.time.ns_per_ms);
    }

    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Panel = @ptrCast(@alignCast(raw));
        if (!self.cx.node_registry.isCurrentIdentity(self.identity, self.node) or
            !self.cx.node_registry.isCurrentIdentity(self.parent_identity, self.parent)) return .done;
        if (self.node.freeing or self.node.pending_free_cx != null or self.parent.freeing or self.parent.pending_free_cx != null) return .done;
        if (self.node.style.display == .none) {
            self.pending_focus = null;
            if (self.node.parent == self.parent) {
                self.detach();
                return .needs_layout;
            }
        } else if (self.node.parent == null) {
            var before: ?*ui.Node = null;
            // Compare stored identity without dereferencing a possibly removed
            // sibling; append safely if that sibling no longer belongs here.
            for (self.parent.children.items) |child| if (child == self.before) {
                before = child;
                break;
            };
            self.parent.insertChildBefore(self.cx.allocator, self.node, before) catch |err| {
                if (!self.attach_failed) std.log.warn("retained panel attach: {s}", .{@errorName(err)});
                self.attach_failed = true;
                return .done;
            };
            self.attach_failed = false;
            return .needs_layout;
        }
        self.flushFocus();
        return .done;
    }
};
