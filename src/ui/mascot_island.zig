//! V0.8 右下角 LOGO 吉祥物 360° 浮岛。The view only composes existing
//! trigger nodes supplied by their owners; it never duplicates their actions.
const std = @import("std");
const ui = @import("ui");
const S = @import("mascot_island_styles.zig");
const theme = @import("app_theme.zig");
const orbit_offsets = [_][2]f32{ .{ -41.6, -24 }, .{ 0, -48 }, .{ 41.6, -24 }, .{ 24, 41.6 }, .{ -24, 41.6 } };

fn boundedCenter(value: f32, length: f32, inset: f32) f32 {
    // A temporary very small layout is possible during native resize.
    const edge = @min(inset, length / 2);
    return std.math.clamp(value, edge, length - edge);
}

fn slotPosition(center: [2]f32, width: f32, height: f32, index: usize, radius: f32) [2]f32 {
    const offset = orbit_offsets[index];
    return .{
        boundedCenter(center[0] + offset[0] / S.orbit_radius * radius, width, S.slot_size / 2) - S.slot_size / 2,
        boundedCenter(center[1] + offset[1] / S.orbit_radius * radius, height, S.slot_size / 2) - S.slot_size / 2,
    };
}

pub const Slot = enum(u8) { transfer = 0, forward = 1, broadcast = 2, chain = 3, history = 4 };

pub const Activity = struct {
    transfer_active: bool = false,
    forward_active: bool = false,
    forward_count: usize = 0,
    broadcast_available: bool = false,
    broadcast_active: bool = false,
    broadcast_participants: usize = 0,
    chain_available: bool = false,
    history_available: bool = false,
};

pub const Hooks = struct {
    context: *anyopaque,
    save_anchor: *const fn (*anyopaque, f32, f32) void,
};

pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    hooks: Hooks,
    root: *ui.Node,
    body: *ui.Node,
    logo: *ui.Node,
    grab: *ui.Node,
    slots: [5]*ui.Node = undefined,
    dots: [5]*ui.Node = undefined,
    activity: Activity = .{},
    anchor_x: f32 = 1,
    anchor_y: f32 = 1,
    center_x: f32 = 0,
    center_y: f32 = 0,
    expanded: bool = false,
    pinned: bool = false,
    dragging: bool = false,
    drag_start_x: f32 = 0,
    drag_start_y: f32 = 0,
    expand_started_ms: f64 = -1,
    collapse_after_ms: f64 = 0,
    logo_texture: ?u32 = null,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, hooks: Hooks, initial_x: f32, initial_y: f32) !*View {
        const root = try ui.box(cx, S.root(), .{});
        root.meta.ownership.meta.test_id = "workspace.mascot";
        const body = try ui.box(cx, S.body(), .{});
        body.meta.ownership.meta.test_id = "workspace.mascot.body";
        const logo = try ui.box(cx, S.logo(), .{});
        logo.setHitTestVisible(false);
        try body.appendChild(cx.allocator, logo);
        const grab = try ui.box(cx, S.grab(), .{});
        grab.meta.ownership.meta.test_id = "workspace.mascot.drag";
        try root.appendChild(cx.allocator, body);
        try root.appendChild(cx.allocator, grab);
        const self = try scope.createState(View, .{ .cx = cx, .scope = scope, .hooks = hooks, .root = root, .body = body, .logo = logo, .grab = grab, .anchor_x = std.math.clamp(initial_x, 0, 1), .anchor_y = std.math.clamp(initial_y, 0, 1) });
        for (&self.slots, 0..) |*slot_node, index| {
            slot_node.* = try ui.box(cx, S.slot(), .{});
            slot_node.*.meta.ownership.meta.test_id = switch (@as(Slot, @fromBackingInt(@intCast(index)))) {
                .transfer => "workspace.mascot.transfer",
                .forward => "workspace.mascot.forward",
                .broadcast => "workspace.mascot.broadcast",
                .chain => "workspace.mascot.chain",
                .history => "workspace.mascot.history",
            };
            slot_node.*.setDisplay(.none);
            const dot = try ui.box(cx, S.activeDot(), .{});
            dot.setDisplay(.none);
            self.dots[index] = dot;
            try slot_node.*.appendChild(cx.allocator, dot);
            try root.appendChild(cx.allocator, slot_node.*);
        }
        try parent.appendChild(cx.allocator, root);
        _ = try ui.interaction.drag.Binding.attach(scope, cx, grab, .{ .axis = .both, .activation_distance = 0, .active_cursor = .grabbing }, View.drag, self);
        try cx.addAfterLayoutHook(self, afterLayout);
        try scope.onCleanup(View, self, cleanup);
        return self;
    }

    pub fn slot(self: *View, which: Slot) *ui.Node {
        return self.slots[@backingInt(which)];
    }

    pub fn setLogo(self: *View, texture: ?u32) void {
        self.logo_texture = texture;
        if (texture) |id| self.logo.setImage(.{ .texture_id = id });
    }

    pub fn setActivity(self: *View, activity: Activity) void {
        if (std.meta.eql(self.activity, activity)) return;
        self.activity = activity;
        self.cx.requestRedraw();
    }

    /// Also include active controls outside the collapsed badge. Otherwise
    /// those controls paint over the WKWebView but cannot receive input.
    pub fn occlusionRect(self: *View) ?ui.ComputedRect {
        if (self.root.style.display == .none or !self.root.isDisplayedInTree()) return null;
        const canvas = self.root.globalRect();
        if (canvas.w <= 0 or canvas.h <= 0) return null;
        const base = self.body.globalRect();
        if (base.w <= 0 or base.h <= 0) return null;
        var x1 = base.x;
        var y1 = base.y;
        var x2 = base.x + base.w;
        var y2 = base.y + base.h;
        for (self.slots) |node| {
            if (node.style.display == .none or !node.isDisplayedInTree()) continue;
            const r = node.globalRect();
            if (r.w <= 0 or r.h <= 0) continue;
            x1 = @min(x1, r.x);
            y1 = @min(y1, r.y);
            x2 = @max(x2, r.x + r.w);
            y2 = @max(y2, r.y + r.h);
        }
        return .{ .x = x1, .y = y1, .w = x2 - x1, .h = y2 - y1 };
    }

    fn applicable(self: *const View, index: usize) bool {
        return switch (index) {
            0, 1 => true,
            2 => self.activity.broadcast_available,
            3 => self.activity.chain_available,
            else => self.activity.history_available,
        };
    }

    fn active(self: *const View, index: usize) bool {
        return switch (index) {
            0 => self.activity.transfer_active,
            1 => self.activity.forward_active,
            2 => self.activity.broadcast_active,
            else => false,
        };
    }

    fn userCenter(self: *const View, width: f32, height: f32) [2]f32 {
        const travel_x = @max(0, width - S.body_size - S.margin * 2);
        const travel_y = @max(0, height - S.body_size - S.margin * 2);
        const padding = S.margin + S.body_size / 2;
        return .{ boundedCenter(padding + self.anchor_x * travel_x, width, padding), boundedCenter(padding + self.anchor_y * travel_y, height, padding) };
    }

    fn drag(event: ui.interaction.drag.Event, raw: *anyopaque) void {
        const self: *View = @ptrCast(@alignCast(raw));
        const rect = self.root.globalRect();
        if (rect.w <= 0 or rect.h <= 0) return;
        switch (event.phase) {
            .start => {
                self.dragging = true;
                self.drag_start_x = self.center_x;
                self.drag_start_y = self.center_y;
            },
            .move => {
                const travel_x = @max(1, rect.w - S.body_size - S.margin * 2);
                const travel_y = @max(1, rect.h - S.body_size - S.margin * 2);
                if (@abs(event.delta.x) + @abs(event.delta.y) >= 3) self.pinned = false;
                self.center_x = boundedCenter(self.drag_start_x + event.delta.x, rect.w, S.margin + S.body_size / 2);
                self.center_y = boundedCenter(self.drag_start_y + event.delta.y, rect.h, S.margin + S.body_size / 2);
                self.anchor_x = std.math.clamp((self.center_x - S.margin - S.body_size / 2) / travel_x, 0, 1);
                self.anchor_y = std.math.clamp((self.center_y - S.margin - S.body_size / 2) / travel_y, 0, 1);
                self.cx.requestRedraw();
            },
            .end => {
                self.dragging = false;
                const moved = @abs(event.delta.x) + @abs(event.delta.y);
                if (moved < 3) {
                    if (self.expanded and self.pinned) {
                        self.pinned = false;
                        self.collapse_after_ms = 0;
                    } else {
                        self.pinned = true;
                        self.expanded = true;
                        self.expand_started_ms = self.cx.frame_time_ms;
                    }
                    self.cx.requestRedraw();
                } else {
                    self.hooks.save_anchor(self.hooks.context, self.anchor_x, self.anchor_y);
                }
            },
            .cancel => {
                self.dragging = false;
                const center = self.userCenter(rect.w, rect.h);
                self.center_x = center[0];
                self.center_y = center[1];
                self.cx.requestRedraw();
            },
        }
    }

    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        const rect = self.root.globalRect();
        if (rect.w <= 0 or rect.h <= 0) return .done;
        const user = self.userCenter(rect.w, rect.h);
        const dx = self.cx.mouse_x - (rect.x + self.center_x);
        const dy = self.cx.mouse_y - (rect.y + self.center_y);
        const anchor_distance = distance(self.cx.mouse_x - (rect.x + user[0]), self.cx.mouse_y - (rect.y + user[1]));
        const hit_radius = if (self.expanded) S.orbit_radius + S.slot_size / 2 + 8 else 34;
        const hovering = !self.dragging and (distance(dx, dy) <= hit_radius or anchor_distance <= 34);
        const now = self.cx.frame_time_ms;
        if (hovering) {
            self.collapse_after_ms = now + 450;
            if (!self.expanded) {
                self.expanded = true;
                self.expand_started_ms = now;
            }
        } else if (!self.pinned and !self.dragging and self.expanded and now >= self.collapse_after_ms) {
            self.expanded = false;
        } else if (!self.pinned and !self.dragging and self.expanded and self.collapse_after_ms > now) {
            const remaining_ns: u64 = @intFromFloat(@ceil((self.collapse_after_ms - now) * std.time.ns_per_ms));
            self.cx.scheduleRedrawAfterNs(remaining_ns);
        }
        var factor: f32 = 0;
        if (self.expanded) {
            if (ui.a11y.preferences.reduceMotion() or self.expand_started_ms < 0) {
                factor = 1;
            } else {
                factor = @floatCast(std.math.clamp((now - self.expand_started_ms) / 220, 0, 1));
                factor = 1 - std.math.pow(f32, 1 - factor, 3);
                if (factor < 1) self.cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
            }
        }
        // Keep the expanded ring fully inside the workspace; the body shifts
        // inward only for the duration of the expansion.
        const pad = S.orbit_radius + S.slot_size / 2 + 8;
        const target_x = boundedCenter(user[0], rect.w, pad);
        const target_y = boundedCenter(user[1], rect.h, pad);
        self.center_x = user[0] + (target_x - user[0]) * factor;
        self.center_y = user[1] + (target_y - user[1]) * factor;
        self.place(self.body, self.center_x - S.body_size / 2, self.center_y - S.body_size / 2);
        self.place(self.grab, self.center_x - S.body_size / 2, self.center_y - S.body_size / 2);
        for (self.slots, 0..) |slot_node, index| {
            const is_applicable = self.applicable(index);
            const is_active = self.active(index);
            const visible = is_applicable and (self.expanded or is_active);
            slot_node.setDisplay(if (visible) .flex else .none);
            if (!visible) continue;
            const radius = if (is_active) S.orbit_radius else 24 + (S.orbit_radius - 24) * factor;
            const at = slotPosition(.{ self.center_x, self.center_y }, rect.w, rect.h, index, radius);
            self.place(slot_node, at[0], at[1]);
            slot_node.setOpacityRaw(if (is_active) 1 else @max(0.001, factor));
            const shows_dot = (index == 1 and self.activity.forward_active) or (index == 2 and self.activity.broadcast_active);
            self.dots[index].setDisplay(if (shows_dot) .flex else .none);
        }
        if (self.activity.transfer_active or self.activity.forward_active or self.activity.broadcast_active) self.cx.scheduleRedrawAfterNs(120 * std.time.ns_per_ms);
        return .done;
    }

    fn place(self: *View, node: *ui.Node, x: f32, y: f32) void {
        node.setStyleInline(self.cx.allocator, .{ .inset = .{ .left = .{ .px = x }, .top = .{ .px = y } } });
    }

    fn distance(dx: f32, dy: f32) f32 {
        return @sqrt(dx * dx + dy * dy);
    }

    fn cleanup(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
    }
};

test "workspace mascot keeps collapsed active controls inside edge bounds" {
    const p = slotPosition(.{ 362, 162 }, 400, 200, @backingInt(Slot.broadcast), S.orbit_radius);
    try std.testing.expect(p[0] >= 0 and p[0] + S.slot_size <= 400);
    try std.testing.expect(p[1] >= 0 and p[1] + S.slot_size <= 200);
    try std.testing.expectEqual(@as(f32, 20), boundedCenter(5, 40, 70));
}
