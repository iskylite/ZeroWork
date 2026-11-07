//! Transient feedback for momentary icon actions. Does not own their action,
//! focus, disabled state, status ink or badges.
const ui = @import("ui");
const theme = @import("app_theme.zig");
const Capture = *const fn (ui.events.Event, ?*anyopaque) ui.events.EventResult;

pub const Binding = struct {
    cx: *ui.Cx,
    node: *ui.Node,
    node_id: u32,
    previous_capture: ?Capture,
    previous_context: ?*anyopaque,
    suppressed: bool = false,
    paint: ?ui.Color = null,
    radius: f32 = -1,

    pub fn attach(cx: *ui.Cx, parent_scope: *ui.Scope, node: *ui.Node) !void {
        if (node.behavior.events.on_event_capture == capture) return;
        const scope = node.meta.ownership.scope.scope orelse parent_scope;
        const self = try scope.createState(Binding, .{
            .cx = cx,
            .node = node,
            .node_id = node.id,
            .previous_capture = node.behavior.events.on_event_capture,
            .previous_context = node.behavior.events.capture_context orelse node.behavior.events.event_context,
        });
        try cx.addAfterLayoutHook(self, afterLayout);
        errdefer cx.removeAfterLayoutHook(self);
        try scope.onCleanup(Binding, self, cleanup);
        node.behavior.events.on_event_capture = capture;
        node.behavior.events.capture_context = self;
        // Momentary glyph actions restore a bare surface after a pointer click.
        // Keep the existing focus subscription, using a keyboard-only outline
        // instead of the theme's persistent filled focus surface.
        if (node.meta.per_frame.hooks.slots.focus_ring_anim) |raw| {
            const focus: *ui.hooks.FocusRingAnimState = @ptrCast(@alignCast(raw));
            focus.surface_cx = null;
            ui.hooks.updateFocusRingConfig(cx, node, .{ .color = theme.current().accent, .width = 1, .offset = -1 });
        }
    }

    fn disabled(self: *Binding) bool {
        return if (self.node.behavior.interaction.a11y) |props| props.disabled else false;
    }

    fn capture(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *Binding = @ptrCast(@alignCast(raw orelse return .ignored));
        if (!self.disabled()) switch (event) {
            .mouse_down => self.suppressed = false,
            // Capture runs before the existing action can open a portal or
            // dispose the button. Never read self after invoking that action.
            .click => self.suppressed = true,
            else => {},
        };
        if (self.previous_capture) |handler| return handler(event, self.previous_context);
        return .ignored;
    }

    fn contains(self: *Binding, candidate: ?*ui.Node) bool {
        const node = candidate orelse return false;
        return node == self.node or node.isDescendantOf(self.node);
    }

    fn sync(self: *Binding) bool {
        const entry = self.cx.node_registry.entries.get(self.node_id) orelse return false;
        self.node = entry.ptr;
        if (self.node.meta.per_frame.hooks.slots.focus_ring_anim) |raw| {
            const focus: *ui.hooks.FocusRingAnimState = @ptrCast(@alignCast(raw));
            focus.focus_color = theme.current().accent;
        }
        const r = self.node.globalRect();
        const visible = self.node.isDisplayedInTree() and r.w > 0 and r.h > 0;
        const inside = visible and self.cx.mouse_x >= r.x and self.cx.mouse_x <= r.x + r.w and self.cx.mouse_y >= r.y and self.cx.mouse_y <= r.y + r.h;
        // A portal taking the hover target isn't a physical pointer exit.
        // Keep click suppression until the pointer actually leaves the button.
        if (!inside) self.suppressed = false;
        const enabled = visible and !self.disabled();
        const hovered = enabled and self.contains(self.cx.hovered_node);
        const pressed = enabled and inside and self.contains(self.cx.pressed_node);
        const color = if (pressed) theme.states().pressed else if (hovered and !self.suppressed) theme.states().hover else ui.Color.TRANSPARENT;
        if (self.paint == null or !ui.Color.eql(self.paint.?, color)) {
            self.paint = color;
            self.node.setBackground(color);
            self.cx.requestRedraw();
        }
        if (visible) {
            const radius = @min(r.w, r.h) / 2;
            if (self.radius != radius) {
                self.radius = radius;
                self.node.setStyleInline(self.cx.allocator, .{ .corner_radius = radius, .border = .{ .width = 0, .radius = radius }, .clip_shape = .{ .rounded_rect = radius } });
                return true;
            }
        }
        return false;
    }

    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Binding = @ptrCast(@alignCast(raw));
        return if (self.sync()) .needs_layout else .done;
    }

    fn cleanup(self: *Binding) void {
        self.cx.removeAfterLayoutHook(self);
        if (self.cx.node_registry.entries.get(self.node_id)) |entry| {
            const node = entry.ptr;
            if (node.behavior.events.on_event_capture == capture and node.behavior.events.capture_context == @as(?*anyopaque, @ptrCast(self))) {
                node.behavior.events.on_event_capture = self.previous_capture;
                node.behavior.events.capture_context = self.previous_context;
            }
        }
    }
};

test "icon feedback hover press click reset preserves action focus capture and scope lifetime" {
    const std = @import("std");
    const a = std.testing.allocator;
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    var scope: ?*ui.Scope = try ui.Scope.init(a, null, cx.owner);
    defer if (scope) |value| value.dispose();
    const root = try ui.box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 80 } }, .{});
    cx.root = root;
    const button = try ui.box(cx, .{ .width = .{ .px = 28 }, .height = .{ .px = 28 } }, .{});
    button.behavior.interaction.a11y = .{ .role = .button };
    const icon = try ui.box(cx, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 } }, .{});
    try button.appendChild(a, icon);
    try root.appendChild(a, button);
    var captures: usize = 0;
    var actions: usize = 0;
    const Legacy = struct {
        fn event(_: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
            const count: *usize = @ptrCast(@alignCast(raw.?));
            count.* += 1;
            return .ignored;
        }
        fn action(raw: *anyopaque) void {
            const count: *usize = @ptrCast(@alignCast(raw));
            count.* += 1;
        }
    };
    button.behavior.events.on_event_capture = Legacy.event;
    button.behavior.events.capture_context = &captures;
    button.behavior.events.on_click = .{ .context = &actions, .callback = Legacy.action };
    const hooks_before = cx.after_layout_hooks.items.len;
    try Binding.attach(cx, scope.?, button);
    try Binding.attach(cx, scope.?, button);
    try std.testing.expectEqual(hooks_before + 1, cx.after_layout_hooks.items.len);
    cx.layout();
    const feedback: *Binding = @ptrCast(@alignCast(button.behavior.events.capture_context.?));
    cx.mouse_x = 14;
    cx.mouse_y = 14;
    cx.hovered_node = icon;
    cx.focused_node = button;
    _ = feedback.sync();
    try std.testing.expect(ui.Color.eql(theme.states().hover, button.getBackground()));
    cx.pressed_node = button;
    _ = feedback.sync();
    try std.testing.expect(ui.Color.eql(theme.states().pressed, button.getBackground()));
    cx.pressed_node = null;
    try std.testing.expectEqual(ui.events.EventResult.ignored, Binding.capture(.{ .click = .{ .x = 14, .y = 14 } }, feedback));
    try std.testing.expectEqual(@as(usize, 1), captures);
    try std.testing.expectEqual(@as(usize, 0), actions);
    button.behavior.events.on_click.?.invoke();
    try std.testing.expectEqual(@as(usize, 1), actions);
    _ = feedback.sync();
    try std.testing.expect(ui.Color.eql(ui.Color.TRANSPARENT, button.getBackground()));
    try std.testing.expect(cx.focused_node == button);
    // A menu steals hit ownership, but the pointer did not leave the trigger.
    cx.hovered_node = root;
    _ = feedback.sync();
    cx.hovered_node = button;
    _ = feedback.sync();
    try std.testing.expect(ui.Color.eql(ui.Color.TRANSPARENT, button.getBackground()));
    cx.mouse_x = 90;
    cx.hovered_node = root;
    _ = feedback.sync();
    cx.mouse_x = 14;
    cx.hovered_node = button;
    _ = feedback.sync();
    try std.testing.expect(ui.Color.eql(theme.states().hover, button.getBackground()));
    button.behavior.interaction.a11y.?.disabled = true;
    _ = feedback.sync();
    try std.testing.expect(ui.Color.eql(ui.Color.TRANSPARENT, button.getBackground()));
    scope.?.dispose();
    scope = null;
    try std.testing.expectEqual(hooks_before, cx.after_layout_hooks.items.len);
    try std.testing.expect(button.behavior.events.on_event_capture == Legacy.event);
    try std.testing.expect(button.behavior.events.capture_context == @as(?*anyopaque, @ptrCast(&captures)));
}

test "icon feedback keeps mounted button keyboard focus separate from pointer background" {
    const std = @import("std");
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const button = try ui.widgets.Button(.{ .icon_only = true, .variant = .ghost, .a11y_label = "Action" }).mount(scope, cx);
    cx.root = button;
    try Binding.attach(cx, scope, button);
    const focus: *ui.hooks.FocusRingAnimState = @ptrCast(@alignCast(button.meta.per_frame.hooks.slots.focus_ring_anim.?));
    try std.testing.expect(focus.surface_cx == null);
    try std.testing.expectEqual(@as(f32, 1), focus.focus_width);
    try std.testing.expect(ui.Color.eql(theme.current().accent, focus.focus_color));
    try std.testing.expect(button.behavior.events.on_focus != null);
    try std.testing.expect(button.behavior.events.on_blur != null);
}
