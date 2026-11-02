//! Input boundaries for interactive floating surfaces. Display-only overlays
//! keep their explicit pass-through or tooltip semantics.
const ui = @import("ui");

pub fn protect(cx: *ui.Cx, node: *ui.Node) void {
    if (node.style.hit_behavior() == .pass_through) return;
    if (node.behavior.interaction.a11y) |a11y| if (a11y.role == .tooltip) return;
    const roles = node.style.hit_roles();
    if (roles.pointer != true or roles.scroll != true or node.style.hit_behavior() != .@"opaque") {
        node.setStyleInline(cx.allocator, .{ .hit_behavior = .@"opaque", .hit_roles = .{ .pointer = true, .scroll = true } });
    }
    // Child buttons/inputs/ScrollAreas handle their own events first. Blank
    // chrome and exhausted inner scrolling stop here, before a terminal parent.
    if (node.behavior.events.on_event == null) node.behavior.events.on_event = consumeInput;
    if (node.behavior.events.on_scroll == null) node.behavior.events.on_scroll = consumeScroll;
}

fn consumeInput(event: ui.events.Event, _: ?*anyopaque) ui.events.EventResult {
    return switch (event) {
        .mouse_down, .mouse_up, .click, .double_click, .mouse_move, .scroll => .stop,
        else => .ignored,
    };
}
fn consumeScroll(_: ui.events.ScrollEvent, _: ?*anyopaque) ui.events.EventResult {
    return .stop;
}

const LayerSlots = @FieldType(@FieldType(ui.Cx, "overlay_stack"), "layers");
pub const Policy = struct {
    cx: *ui.Cx,
    active: [@typeInfo(LayerSlots).array.len]?u32 = @splat(null),

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
        var opened = false;
        for (&self.cx.overlay_stack.layers, 0..) |*slot, index| {
            const layer = if (slot.*) |*value| value else {
                self.active[index] = null;
                continue;
            };
            const content = layer.content_node orelse continue;
            const passive = if (content.behavior.interaction.a11y) |a11y| a11y.role == .tooltip else false;
            if (passive) {
                // Keep Tooltip passive across retained close/reopen cycles too.
                layer.config.content_hit_test_visible = false;
                content.setHitTestVisible(false);
            } else if (layer.config.content_hit_test_visible) protect(self.cx, content);
            if (layer.barrier_node) |barrier| protect(self.cx, barrier);
            const active = !passive and !layer.suspended and layer.state != .exiting;
            const id: ?u32 = if (active) layer.handle.id else null;
            if (id != null and self.active[index] != id) opened = true;
            self.active[index] = id;
        }
        // A newly opened layer must not inherit a trackpad gesture captured by
        // the terminal/parent surface before it appeared.
        if (opened) self.cx.dispatcher.cancelScrollGesture();
    }
};
