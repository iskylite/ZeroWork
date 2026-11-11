//! Activation order for peer, non-modal panels mounted directly in one window.
//! Portaled popovers/tooltips and modal backdrops keep their existing higher bands.
const ui = @import("ui");
const base_z: i16 = 200;
const Capture = *const fn (ui.events.Event, ?*anyopaque) ui.events.EventResult;

pub const Surface = struct {
    cx: *ui.Cx,
    node: *ui.Node,
    order: u64 = 0,
    visible: bool = false,
    previous_capture: ?Capture,
    previous_context: ?*anyopaque,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, node: *ui.Node) !*Surface {
        const self = try scope.createState(Surface, .{ .cx = cx, .node = node, .previous_capture = node.behavior.events.on_event_capture, .previous_context = node.behavior.events.capture_context });
        try cx.addAfterLayoutHook(self, afterLayout);
        errdefer cx.removeAfterLayoutHook(self);
        try scope.onCleanup(Surface, self, cleanup);
        node.behavior.events.on_event_capture = capture;
        node.behavior.events.capture_context = self;
        return self;
    }
    fn fromNode(node: *ui.Node) ?*Surface {
        if (node.behavior.events.on_event_capture != capture) return null;
        return @ptrCast(@alignCast(node.behavior.events.capture_context orelse return null));
    }
    fn displayed(self: *const Surface) bool {
        const root = self.cx.root orelse return false;
        return self.node.isDescendantOf(root) and self.node.isDisplayedInTree();
    }
    /// Opening an already visible panel through its toolbar also activates it.
    pub fn activate(self: *Surface) void {
        const parent = self.node.parent orelse return;
        if (!self.displayed()) return;
        var latest: u64 = self.order;
        for (parent.children.items) |node| if (fromNode(node)) |peer| {
            latest = @max(latest, peer.order);
        };
        self.order = latest +| 1;
        self.visible = true;
        // Recompute small peer ranks instead of letting z-index grow with every
        // click. Modal/settings and portal priority cannot be overtaken over time.
        var changed = false;
        for (parent.children.items) |node| if (fromNode(node)) |peer| {
            if (!peer.displayed()) continue;
            var rank: i16 = 0;
            for (parent.children.items) |other| if (fromNode(other)) |candidate| {
                if (candidate.displayed() and (candidate.order < peer.order or (candidate.order == peer.order and other.id < node.id))) rank +|= 1;
            };
            const z = base_z +| rank;
            if (node.style.z_index() != z) {
                node.setStyle(self.cx.allocator, .z_index, z);
                changed = true;
            }
        };
        if (changed) parent.markOrderDirty();
        self.cx.requestRedraw();
    }
    fn capture(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *Surface = @ptrCast(@alignCast(raw orelse return .ignored));
        if (event == .mouse_down) self.activate();
        return if (self.previous_capture) |previous| previous(event, self.previous_context) else .ignored;
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Surface = @ptrCast(@alignCast(raw));
        const visible = self.displayed();
        if (visible and !self.visible) {
            self.activate();
            return .needs_layout;
        }
        self.visible = visible;
        return .done;
    }
    fn cleanup(self: *Surface) void {
        self.cx.removeAfterLayoutHook(self);
        if (self.node.behavior.events.on_event_capture == capture and self.node.behavior.events.capture_context == @as(?*anyopaque, @ptrCast(self))) {
            self.node.behavior.events.on_event_capture = self.previous_capture;
            self.node.behavior.events.capture_context = self.previous_context;
        }
    }
};
