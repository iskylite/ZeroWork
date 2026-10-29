//! Resolve floating paint from its live owner chain, including portaled content.
//! Inline cards/inputs remain part of their containing surface, not new layers.
const ui = @import("ui");
const theme = @import("app_theme.zig");

pub const Policy = struct {
    cx: *ui.Cx,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope) !void {
        const self = try scope.createState(Policy, .{ .cx = cx });
        try cx.addAfterLayoutHook(self, afterLayout);
        errdefer cx.removeAfterLayoutHook(self);
        try scope.onCleanup(Policy, self, cleanup);
    }
    fn cleanup(self: *Policy) void {
        self.cx.removeAfterLayoutHook(self);
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Policy = @ptrCast(@alignCast(raw));
        self.sync();
        return .done;
    }
    pub fn sync(self: *Policy) void {
        for (self.cx.overlay_stack.layers) |slot| {
            const layer = slot orelse continue;
            if (layer.suspended) continue;
            const content = layer.content_node orelse continue;
            const level = 1 + self.ownerLevel(trigger(self.cx, layer), 3);
            content.setBackground(theme.layerBackground(level));
            content.setBorderColor(ui.Color.TRANSPARENT);
            if (content.style.outline()) |outline| if (outline.width != 0) {
                content.setStyleInline(self.cx.allocator, .{ .outline = .{ .width = 0, .color = ui.Color.TRANSPARENT } });
            };
            const glass = theme.overlayGlass();
            if (content.style.glass_params() == null or content.style.glass_params().?.backdrop_blur != glass.backdrop_blur) {
                content.setStyleInline(self.cx.allocator, .{ .glass = glass });
            }
        }
    }
    fn trigger(cx: *ui.Cx, layer: anytype) ?*ui.Node {
        if (layer.trigger_handle) |handle| {
            if (cx.node_registry.resolve(handle, null)) |node| return node;
            // Hidden/reopened triggers can be outside the current frame's hit
            // snapshot while their generation and object identity remain live.
            // Match OverlayStack's weak-reference contract, never trust a stale
            // raw pointer after unregister/destroy or a failed track operation.
            if (layer.trigger_node) |node| {
                if (cx.node_registry.isCurrentIdentity(handle, node)) return node;
                // detachChild invalidates a generation even when the same
                // retained node is reattached. Reacquire it only through a live
                // tree with both its monotone ID and pointer matching. The
                // cached pointer is compared, never dereferenced on this path.
                if (cx.root) |root| if (liveTrigger(root, handle.id, node)) |live| return live;
                for (cx.overlay_stack.layers) |slot| if (slot) |parent| {
                    if (parent.suspended) continue;
                    if (parent.content_node) |content| if (liveTrigger(content, handle.id, node)) |live| return live;
                };
            }
            return null;
        }
        if (layer.trigger_node == null) {
            if (layer.previous_focus) |handle| return cx.node_registry.resolve(handle, null);
        }
        return null;
    }
    fn liveTrigger(root: *ui.Node, id: u32, cached: *ui.Node) ?*ui.Node {
        if (root == cached and root.id == id) return root;
        for (root.children.items) |child| if (liveTrigger(child, id, cached)) |live| return live;
        return null;
    }
    fn ownerLevel(self: *Policy, node: ?*ui.Node, remaining: usize) usize {
        if (remaining == 0) return 3;
        var cursor = node;
        while (cursor) |current| : (cursor = current.parent) {
            // Portal DOM ancestry stops at the portal; resume at its live trigger.
            for (self.cx.overlay_stack.layers) |slot| {
                const layer = slot orelse continue;
                if (layer.suspended or layer.content_node != current) continue;
                return 1 + self.ownerLevel(trigger(self.cx, layer), remaining - 1);
            }
            // Existing manually positioned floating shells (AI/settings/etc.)
            // declare their material through overlay paint, not widget names.
            const paint = current.getBackground();
            const base = theme.baseColors().overlay;
            if (current.style.glass_params() != null and paint.a > 0 and paint.r == base.r and paint.g == base.g and paint.b == base.b) {
                return 1 + self.ownerLevel(current.parent, remaining - 1);
            }
        }
        return 0;
    }
};
