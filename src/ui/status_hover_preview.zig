//! Statusbar previews share the existing click action and retained panel.
const std = @import("std");
const ui = @import("ui");
const clock = @import("../platform/realtime.zig");

pub const Group = struct { pinned: ?*Preview = null };

pub const Preview = struct {
    group: *Group,
    cx: *ui.Cx,
    trigger: *ui.Node,
    panel: *ui.Node,
    open: *ui.Signal(bool),
    action: ui.HandlerRef,
    close: ui.HandlerRef,
    preview: bool = false,
    pinned: bool = false,
    suppressed: bool = false,
    leave_ns: ?i128 = null,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, group: *Group, trigger: *ui.Node, panel: *ui.Node, open: *ui.Signal(bool), close: ui.HandlerRef) !void {
        const action = trigger.behavior.events.on_click orelse return;
        const self = try scope.createState(Preview, .{ .group = group, .cx = cx, .trigger = trigger, .panel = panel, .open = open, .action = action, .close = close });
        trigger.behavior.events.on_click = cx.on(Preview, self, click);
        try cx.addAfterLayoutHook(self, tick);
    }
    fn contains(self: *Preview, node: *ui.Node) bool {
        if (!node.isDisplayedInTree()) return false;
        const r = node.globalRect();
        return r.w > 0 and r.h > 0 and self.cx.mouse_x >= r.x and self.cx.mouse_x <= r.x + r.w and self.cx.mouse_y >= r.y and self.cx.mouse_y <= r.y + r.h;
    }
    fn click(self: *Preview) void {
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
