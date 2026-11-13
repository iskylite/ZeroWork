//! Statusbar previews share the existing click action and retained panel.
const std = @import("std");
const ui = @import("ui");
const clock = @import("../platform/realtime.zig");

pub const Group = struct {
    pinned: ?*Preview = null,

    pub fn dismissOnOutsidePress(self: *Group, target: *ui.Node) void {
        const pinned = self.pinned orelse return;
        if (!pinned.open.peek() or target.isDescendantOf(pinned.trigger) or
            @import("floating_input.zig").containsPress(pinned.cx, pinned.panel, target)) return;
        pinned.close.invoke();
        pinned.preview = false;
        pinned.pinned = false;
        pinned.leave_ns = null;
        self.pinned = null;
        pinned.cx.requestRedraw();
    }
};

pub const Preview = struct {
    group: *Group,
    cx: *ui.Cx,
    trigger: *ui.Node,
    panel: *ui.Node,
    open: *ui.Signal(bool),
    action: ui.HandlerRef,
    close: ui.HandlerRef,
    hover_enabled: bool = true,
    /// External veto sampled each frame before hover invokes the action. A
    /// graphical session (web/BMC) repoints the identity trigger at a sticky
    /// native popover; hover must not open those, only a real click may.
    hover_veto: ?struct { context: *anyopaque, blocked: *const fn (*anyopaque) bool } = null,
    preview: bool = false,
    pinned: bool = false,
    suppressed: bool = false,
    leave_ns: ?i128 = null,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, group: *Group, trigger: *ui.Node, panel: *ui.Node, open: *ui.Signal(bool), close: ui.HandlerRef) !void {
        _ = try mountWithHover(cx, scope, group, trigger, panel, open, close, true);
    }
    /// Toolbar actions share click/toggle/exclusion behavior, without previews.
    pub fn mountClick(cx: *ui.Cx, scope: *ui.Scope, group: *Group, trigger: *ui.Node, panel: *ui.Node, open: *ui.Signal(bool), close: ui.HandlerRef) !void {
        _ = try mountWithHover(cx, scope, group, trigger, panel, open, close, false);
    }
    /// Hover preview with an external veto: while blocked() returns true the
    /// hover path stays inert; a genuine click still runs the action.
    pub fn mountVetoed(cx: *ui.Cx, scope: *ui.Scope, group: *Group, trigger: *ui.Node, panel: *ui.Node, open: *ui.Signal(bool), close: ui.HandlerRef, context: *anyopaque, blocked: *const fn (*anyopaque) bool) !void {
        if (try mountWithHover(cx, scope, group, trigger, panel, open, close, true)) |self| {
            self.hover_veto = .{ .context = context, .blocked = blocked };
        }
    }
    fn mountWithHover(cx: *ui.Cx, scope: *ui.Scope, group: *Group, trigger: *ui.Node, panel: *ui.Node, open: *ui.Signal(bool), close: ui.HandlerRef, hover_enabled: bool) !?*Preview {
        const action = trigger.behavior.events.on_click orelse return null;
        const self = try scope.createState(Preview, .{ .group = group, .cx = cx, .trigger = trigger, .panel = panel, .open = open, .action = action, .close = close, .hover_enabled = hover_enabled });
        trigger.behavior.events.on_click = cx.on(Preview, self, click);
        try cx.addAfterLayoutHook(self, tick);
        return self;
    }
    fn contains(self: *Preview, node: *ui.Node) bool {
        if (!node.isDisplayedInTree()) return false;
        const r = node.globalRect();
        return r.w > 0 and r.h > 0 and self.cx.mouse_x >= r.x and self.cx.mouse_x <= r.x + r.w and self.cx.mouse_y >= r.y and self.cx.mouse_y <= r.y + r.h;
    }
    fn click(self: *Preview) void {
        if (self.group.pinned) |previous| if (previous != self) {
            previous.close.invoke();
            previous.preview = false;
            previous.pinned = false;
            self.group.pinned = null;
        };
        if (!self.hover_enabled) {
            if (self.open.peek()) self.close.invoke() else self.action.invoke();
            self.pinned = self.open.peek();
            self.group.pinned = if (self.pinned) self else null;
            self.cx.requestRedraw();
            return;
        }
        if (self.preview and self.open.peek() and !self.pinned) {
            self.pinned = true;
        } else {
            self.action.invoke();
            self.preview = self.open.peek();
            self.pinned = self.preview;
            self.suppressed = !self.preview;
        }
        self.group.pinned = if (self.pinned) self else null;
        self.leave_ns = null;
        self.cx.requestRedraw();
    }
    fn tick(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Preview = @ptrCast(@alignCast(raw));
        // Status projection updates can replace the underlying click action
        // (terminal/file/BMC). Retain hover-to-pin routing around that action.
        const handler = self.cx.on(Preview, self, click);
        if (self.trigger.behavior.events.on_click) |current| {
            if (current.callback != handler.callback or current.context != handler.context) {
                self.action = current;
                self.trigger.behavior.events.on_click = handler;
            }
        }
        if (!self.hover_enabled) {
            if (!self.open.peek() and self.group.pinned == self) self.group.pinned = null;
            return .done;
        }
        const inside = self.contains(self.trigger);
        const shown = self.open.peek();
        if (self.preview and !shown) {
            self.preview = false;
            self.pinned = false;
            self.suppressed = true;
        }
        if (!inside) self.suppressed = false;
        if (self.group.pinned) |pinned| {
            if (!pinned.open.peek()) self.group.pinned = null;
        }
        const vetoed = if (self.hover_veto) |veto| veto.blocked(veto.context) else false;
        const peer_open = !shown and self.cx.overlay_stack.hasGroup(@import("floating_surface.zig").workspace_popup);
        if (inside and (vetoed or peer_open)) {
            // Keep the preview suppressed until the pointer leaves the trigger.
            self.suppressed = true;
            self.cx.scheduleRedrawAfterNs(50 * std.time.ns_per_ms);
            return .done;
        }
        if (inside and !shown and !self.suppressed and self.group.pinned == null) {
            // Reuse click actions without their keyboard focus side effects.
            const focus = if (self.cx.focus_manager.current_focus) |node| self.cx.node_registry.handleFor(node) else null;
            self.action.invoke();
            if (self.cx.node_registry.resolve(focus, null)) |node| self.cx.setFocus(node) else self.cx.clearFocus();
            self.preview = self.open.peek();
            self.pinned = false;
            self.suppressed = !self.preview;
            self.cx.requestRedraw();
        }
        if (!self.preview or self.pinned) return .done;
        if (inside or self.contains(self.panel)) {
            self.leave_ns = null;
        } else {
            const now = clock.monotonicNs();
            if (self.leave_ns) |started| {
                if (now - started >= 150 * std.time.ns_per_ms) {
                    self.close.invoke();
                    self.preview = false;
                    self.leave_ns = null;
                    self.cx.requestRedraw();
                }
            } else self.leave_ns = now;
        }
        self.cx.scheduleRedrawAfterNs(50 * std.time.ns_per_ms);
        return .done;
    }
};
