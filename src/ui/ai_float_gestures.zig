//! Owner-local float geometry. The host keeps Model's address stable and cancels before owner moves.
const std = @import("std");
const ui = @import("ui");
const float = @import("../ai/float_model.zig");
const drag = ui.interaction.drag;
const S = @import("ai_float_gesture_styles.zig");
const edges = [_]float.Edge{ .n, .s, .w, .e, .nw, .ne, .sw, .se };
const ids = [_][]const u8{ "ai.float.resize.n", "ai.float.resize.s", "ai.float.resize.w", "ai.float.resize.e", "ai.float.resize.nw", "ai.float.resize.ne", "ai.float.resize.sw", "ai.float.resize.se" };
const Kind = union(enum) { move, resize: float.Edge };
const Part = struct { view: *View, kind: Kind };
const Active = struct { geometry: float.Geometry, rect: float.Rect };

pub const View = struct {
    cx: *ui.Cx,
    card: *ui.Node,
    grip: *ui.Node,
    model: *float.Model,
    pane: float.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    window: float.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    bounds_ready: bool = false,
    handles: [8]*ui.Node = undefined,
    bindings: [9]?*drag.Binding = @splat(null),
    active: ?Active = null,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, card: *ui.Node, grip: *ui.Node, model: *float.Model) !*View {
        const self = try scope.createState(View, .{ .cx = cx, .card = card, .grip = grip, .model = model });
        try scope.onCleanup(View, self, cleanup);
        const moving = try scope.createState(Part, .{ .view = self, .kind = .move });
        self.bindings[0] = try drag.Binding.attach(scope, cx, grip, .{ .enabled = false, .can_start = canStart }, changed, moving);
        grip.meta.ownership.meta.test_id = "ai.float.drag";
        grip.behavior.interaction.pointer_down_focus = .preserve;
        grip.behavior.events.on_event_capture = gripCapture;
        grip.behavior.events.capture_context = self;
        grip.setStyleInline(cx.allocator, .{ .hit_behavior = .@"opaque", .cursor = .grab });
        for (edges, 0..) |edge, index| {
            const node = try ui.box(cx, S.handle(edge, 600, 456), .{});
            self.handles[index] = node;
            node.meta.ownership.meta.test_id = ids[index];
            node.behavior.interaction.pointer_down_focus = .preserve;
            const part = try scope.createState(Part, .{ .view = self, .kind = .{ .resize = edge } });
            self.bindings[index + 1] = try drag.Binding.attach(scope, cx, node, .{ .enabled = false, .activation_distance = 0, .active_cursor = S.cursor(edge), .can_start = canStart }, changed, part);
            node.setDisplay(.none);
            try card.appendChild(cx.allocator, node);
        }
        return self;
    }

    fn cleanup(self: *View) void {
        self.cancel();
        for (self.bindings, 0..) |binding, index| if (binding) |value| {
            const node = if (index == 0) self.grip else self.handles[index - 1];
            if (node.behavior.events.event_context == @as(*anyopaque, @ptrCast(value))) {
                node.behavior.events.on_event = null;
                node.behavior.events.event_context = null;
            }
        };
        if (self.grip.behavior.events.capture_context == @as(*anyopaque, @ptrCast(self))) {
            self.grip.behavior.events.on_event_capture = null;
            self.grip.behavior.events.capture_context = null;
        }
    }

    pub fn updateBounds(self: *View, pane: float.Rect, window: float.Rect) void {
        if (self.bounds_ready and (!std.meta.eql(self.pane, pane) or !std.meta.eql(self.window, window))) self.cancel();
        self.pane = pane;
        self.window = window;
        self.bounds_ready = true;
        self.model.updateBounds(pane, window);
        self.syncHandles();
    }

    pub fn cancel(self: *View) void {
        for (self.bindings) |binding| if (binding) |value| value.cancel(.explicit);
    }

    pub fn toggleMaximized(self: *View) void {
        if (!self.bounds_ready) return;
        self.cancel();
        self.model.toggleMaximized(self.pane, self.window);
        self.syncHandles();
        self.cx.requestRedraw();
    }

    fn syncHandles(self: *View) void {
        const rect = self.model.rect(self.pane, self.window);
        const enabled = self.bounds_ready and self.model.visible and self.model.expanded and !self.model.maximized and rect.width > 0 and rect.height > 0;
        for (self.bindings) |binding| if (binding) |value| value.setEnabled(enabled);
        for (self.handles, edges) |node, edge| {
            node.setDisplay(if (enabled) .flex else .none);
            node.setStyleInline(self.cx.allocator, S.handle(edge, rect.width, rect.height));
        }
    }

    fn canStart(_: drag.StartRequest, raw: *anyopaque) bool {
        const part: *Part = @ptrCast(@alignCast(raw));
        const self = part.view;
        return self.bounds_ready and self.model.visible and self.model.expanded and !self.model.maximized;
    }

    fn changed(event: drag.Event, raw: *anyopaque) void {
        const part: *Part = @ptrCast(@alignCast(raw));
        const self = part.view;
        if (event.phase == .cancel) {
            if (self.active) |active| {
                self.active = null;
                self.model.restoreGeometry(active.geometry);
                self.model.updateBounds(self.pane, self.window);
                self.syncHandles();
                self.cx.requestRedraw();
            }
            return;
        }
        if (event.phase == .start) self.active = .{ .geometry = self.model.geometry(), .rect = self.model.rect(self.pane, self.window) };
        const active = self.active orelse return;
        if (!std.math.isFinite(event.delta.x) or !std.math.isFinite(event.delta.y)) {
            self.cancel();
            return;
        }
        var next = active.rect;
        switch (part.kind) {
            .move => {
                next.x += event.delta.x;
                next.y += event.delta.y;
            },
            .resize => |edge| next = float.resized(active.rect, edge, event.delta.x, event.delta.y, self.pane, self.window),
        }
        self.model.setRectangle(next, self.pane, self.window);
        if (event.phase == .end) self.active = null;
        self.syncHandles();
        self.cx.requestRedraw();
    }

    fn gripCapture(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *View = @ptrCast(@alignCast(raw orelse return .ignored));
        if (event != .double_click or self.model.maximized) return .ignored;
        self.cancel();
        self.model.resetPosition(self.pane, self.window);
        self.syncHandles();
        self.cx.requestRedraw();
        return .stop;
    }
};
