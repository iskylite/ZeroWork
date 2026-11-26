//! A stationary, draggable workspace badge with a single inward-opening tools strip.
const std = @import("std");
const ui = @import("ui");
const S = @import("mascot_island_styles.zig");
const theme = @import("app_theme.zig");
const animation_ms: f64 = 220;
const enter_ms: f64 = 150;
const leave_ms: f64 = 270;
const slot_count = 5;
const Direction = enum { left, right, up, down };

pub const ToolFootprint = struct {
    bounds: ui.ComputedRect,
    horizontal: bool,
};

fn boundedCenter(value: f32, length: f32, inset: f32) f32 {
    const edge = @min(inset, length / 2);
    return std.math.clamp(value, edge, length - edge);
}
fn directionFor(c: [2]f32, w: f32, h: f32, n: usize) Direction {
    const space = [4]f32{ c[0], w - c[0], c[1], h - c[1] };
    const x: usize = if (space[0] >= space[1]) 0 else 1;
    const y: usize = if (space[2] >= space[3]) 2 else 3;
    const extent = S.body_size / 2 + S.rail_gap + railLength(@floatFromInt(n)) + 2;
    if (space[2] >= extent) return .up;
    return @fromBackingInt(@intCast(if (space[x] >= extent or space[x] >= space[y]) x else y));
}
fn railLength(count: f32) f32 {
    return @max(0, count * (S.slot_size + S.slot_gap) - S.slot_gap) + S.rail_padding * 2;
}
fn onAxis(center: [2]f32, dir: Direction, distance: f32) [2]f32 {
    return switch (dir) {
        .left => .{ center[0] - distance, center[1] },
        .right => .{ center[0] + distance, center[1] },
        .up => .{ center[0], center[1] - distance },
        .down => .{ center[0], center[1] + distance },
    };
}
fn boxAt(c: [2]f32, w: f32, h: f32) ui.ComputedRect {
    return .{ .x = c[0] - w / 2, .y = c[1] - h / 2, .w = w, .h = h };
}
fn unionRect(a: ui.ComputedRect, b: ui.ComputedRect) ui.ComputedRect {
    const x = @min(a.x, b.x);
    const y = @min(a.y, b.y);
    return .{ .x = x, .y = y, .w = @max(a.x + a.w, b.x + b.w) - x, .h = @max(a.y + a.h, b.y + b.h) - y };
}
fn railRect(c: [2]f32, dir: Direction, len: f32) ui.ComputedRect {
    const center = onAxis(c, dir, S.body_size / 2 + S.rail_gap + len / 2);
    const cross = S.slot_size + 2 * S.rail_padding;
    const horizontal = dir == .left or dir == .right;
    return boxAt(center, if (horizontal) len else cross, if (horizontal) cross else len);
}
fn translateRect(r: ui.ComputedRect, x: f32, y: f32) ui.ComputedRect {
    return .{ .x = r.x + x, .y = r.y + y, .w = r.w, .h = r.h };
}
fn advance(value: f32, target: bool, dt_ms: f64, reduced: bool) f32 {
    if (reduced) return if (target) 1 else 0;
    const delta: f32 = @floatCast(@max(0, dt_ms) / animation_ms);
    return std.math.clamp(value + (if (target) delta else -delta), 0, 1);
}
fn eased(value: f32) f32 {
    return value * value * (3 - 2 * value);
}
/// Place the whole panel in the workspace. Prefer the side with room; a
/// bottom-edge badge must not place a history list below the viewport.
pub fn panelRect(bounds: ui.ComputedRect, anchor: ui.ComputedRect, desired_w: f32, desired_h: f32) ui.ComputedRect {
    const pad = @min(@as(f32, 8), @min(bounds.w, bounds.h) * 0.25);
    const w = @min(desired_w, @max(0, bounds.w - 2 * pad));
    const above = @max(0, anchor.y - 6 - (bounds.y + pad));
    const below = @max(0, bounds.y + bounds.h - pad - anchor.y - anchor.h - 6);
    const place_above = above >= below;
    const h = @min(desired_h, if (place_above) above else below);
    return .{
        .x = std.math.clamp(anchor.x + anchor.w / 2 - w / 2, bounds.x + pad, @max(bounds.x + pad, bounds.x + bounds.w - pad - w)),
        .y = std.math.clamp(if (place_above) anchor.y - 6 - h else anchor.y + anchor.h + 6, bounds.y + pad, @max(bounds.y + pad, bounds.y + bounds.h - pad - h)),
        .w = w,
        .h = h,
    };
}

/// Workspace tool panels always use a horizontal side of the complete rail
/// envelope. Both sides are legal; an undersized workspace never falls back
/// on top of the rail or on its click targets.
pub fn lateralPanelRect(bounds: ui.ComputedRect, tools: ui.ComputedRect, trigger: ui.ComputedRect, width: f32, height: f32, min_w: f32, min_h: f32) ?ui.ComputedRect {
    const clear: f32 = 12;
    const left = bounds.x + clear;
    const right = bounds.x + bounds.w - clear;
    const top = bounds.y + clear;
    const bottom = bounds.y + bounds.h - clear;
    const left_edge = @min(right, tools.x - clear);
    const right_edge = @max(left, tools.x + tools.w + clear);
    const left_room = left_edge - left;
    const right_room = right - right_edge;
    const to_left = left_room >= right_room;
    const w = @min(width, if (to_left) left_room else right_room);
    const h = @min(height, bottom - top);
    if (w < min_w or h < min_h) return null;
    const anchor_y = if (trigger.y + trigger.h / 2 >= bounds.y + bounds.h / 2) trigger.y + trigger.h - h else trigger.y;
    return .{ .x = if (to_left) left_edge - w else right_edge, .y = std.math.clamp(anchor_y, top, bottom - h), .w = w, .h = h };
}

pub const Slot = enum(u8) { transfer = 0, forward = 1, broadcast = 2, chain = 3, history = 4 };

pub const Activity = struct {
    transfer_active: bool = false,
    forward_available: bool = false,
    forward_active: bool = false,
    broadcast_available: bool = false,
    broadcast_active: bool = false,
    broadcast_participants: usize = 0,
    chain_available: bool = false,
    history_available: bool = false,
};

pub const Hooks = struct {
    context: *anyopaque,
    save_anchor: *const fn (*anyopaque, f32, f32) void,
    open_preview: *const fn (*anyopaque, Slot) void,
    close_preview: *const fn (*anyopaque, Slot) void,
    panel: *const fn (*anyopaque, Slot) ?*ui.Node,
    pin_preview: *const fn (*anyopaque, Slot) void,
};

pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    hooks: Hooks,
    root: *ui.Node,
    body: *ui.Node,
    rail: *ui.Node,
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
    ignore_badge_until_leave: bool = false,
    dragging: bool = false,
    drag_start_x: f32 = 0,
    drag_start_y: f32 = 0,
    glance: ui.widgets.popover.PopoverResult = undefined,
    glance_kind: ?Slot = null,
    glance_title: *ui.Node = undefined,
    glance_detail: *ui.Node = undefined,
    glance_meta: *ui.Node = undefined,
    progress: f32 = 0,
    last_ms: ?f64 = null,
    candidate: ?Slot = null,
    candidate_since: f64 = 0,
    preview: ?Slot = null,
    preview_leave: ?f64 = null,
    suppressed: ?Slot = null,
    slot_events: [slot_count]SlotEvent = undefined,
    geometry: [slot_count + 3]?ui.ComputedRect = @splat(null),
    collapse_after_ms: f64 = 0,
    logo_texture: ?u32 = null,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, hooks: Hooks, initial_x: f32, initial_y: f32) !*View {
        const root = try ui.box(cx, S.root(), .{});
        root.meta.ownership.meta.test_id = "workspace.mascot";
        const rail = try ui.box(cx, S.rail(), .{});
        rail.meta.ownership.meta.test_id = "workspace.mascot.tools";
        rail.setHitTestVisible(false);
        rail.setDisplay(.none);
        try root.appendChild(cx.allocator, rail);
        const body = try ui.box(cx, S.body(), .{});
        body.meta.ownership.meta.test_id = "workspace.mascot.body";
        const logo = try ui.box(cx, S.logo(), .{});
        logo.setHitTestVisible(false);
        try body.appendChild(cx.allocator, logo);
        const grab = try ui.box(cx, S.grab(), .{});
        grab.meta.ownership.meta.test_id = "workspace.mascot.drag";
        try root.appendChild(cx.allocator, body);
        try root.appendChild(cx.allocator, grab);
        const self = try scope.createState(View, .{ .cx = cx, .scope = scope, .hooks = hooks, .root = root, .body = body, .rail = rail, .logo = logo, .grab = grab, .anchor_x = std.math.clamp(initial_x, 0, 1), .anchor_y = std.math.clamp(initial_y, 0, 1) });
        grab.behavior.interaction.focusable = true;
        grab.behavior.interaction.a11y = .{ .role = .button, .label = "工作区工具" };
        try ui.hooks.useFocusRing(scope, cx, grab, .{ .color = theme.current().accent_ink, .width = 1.5, .offset = 1 });
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
            self.slot_events[index] = .{ .view = self, .which = @fromBackingInt(@intCast(index)) };
            slot_node.*.behavior.events.capture_context = &self.slot_events[index];
            slot_node.*.behavior.events.on_event_capture = SlotEvent.capture;
            const dot = try ui.box(cx, S.activeDot(), .{});
            dot.setDisplay(.none);
            self.dots[index] = dot;
            try slot_node.*.appendChild(cx.allocator, dot);
            try root.appendChild(cx.allocator, slot_node.*);
        }
        // Read-only previews for surfaces whose click creates an editing draft
        // or opens a separate graphical connection dialog. Hover must do neither.
        self.glance = try ui.widgets.Popover(.{ .group = @import("floating_surface.zig").workspace_popup, .trigger = .manual, .position = .bottom_start, .flip = false, .shift_main_axis = false, .viewport_padding = 0, .width = @as(f32, 260), .max_width = @as(f32, 260), .constrain_width_to_viewport = false, .size_policy = .fit_content, .offset = .{ .static = 0 }, .enter_transition = .none, .exit_transition = .none, .anchor = .{ .virtual = .{ .ctx = self, .getRect = glanceAnchor } } }).mount(scope, cx);
        self.glance.trigger.setDisplay(.none);
        self.glance.content.meta.ownership.meta.test_id = "workspace.mascot.preview";
        self.glance.content.setStyleInline(cx.allocator, .{ .width = .fill(), .padding = ui.Padding.all(12), .gap = 5, .background = theme.current().overlay, .glass = theme.overlayGlass(), .border = .{ .radius = 11 }, .shadow = .{ .offset_y = 8, .blur = 18, .color = theme.current().shadow } });
        self.glance_title = try ui.text(cx, "", .{ .font_size = 13, .font_weight = 600, .color = theme.current().fg_1, .wrap = .word });
        self.glance_detail = try ui.text(cx, "", .{ .font_size = 12, .color = theme.current().fg_1, .wrap = .word });
        self.glance_meta = try ui.text(cx, "", .{ .font_size = 11, .color = theme.current().fg_2, .wrap = .word });
        for ([_]*ui.Node{ self.glance_title, self.glance_detail, self.glance_meta }) |n| try self.glance.content.appendChild(cx.allocator, n);
        try root.appendChild(cx.allocator, self.glance.wrapper);
        try parent.appendChild(cx.allocator, root);
        _ = try ui.interaction.drag.Binding.attach(scope, cx, grab, .{ .axis = .both, .activation_distance = 0, .active_cursor = .grabbing }, View.drag, self);
        grab.behavior.events.capture_context = self;
        grab.behavior.events.on_event_capture = mascotKey;
        try cx.addAfterLayoutHook(self, afterLayout);
        try scope.onCleanup(View, self, cleanup);
        return self;
    }

    pub fn slot(self: *View, which: Slot) *ui.Node {
        return self.slots[@backingInt(which)];
    }

    fn glanceAnchor(raw: *anyopaque) ui.widgets.popover.AnchorRect {
        const self: *View = @ptrCast(@alignCast(raw));
        const r = self.glanceRect() orelse return .{ .x = -1e6, .y = -1e6, .w = 0, .h = 0 };
        return .{ .x = r.x, .y = r.y, .w = 0, .h = 0 };
    }
    fn glanceRect(self: *View) ?ui.ComputedRect {
        const trigger = (if (self.glance_kind) |which| self.slot(which) else self.body).globalRect();
        const h = @max(@as(f32, 96), self.glance.chrome.globalRect().h);
        return self.workspacePanelRect(trigger, 260, h, 260, 96);
    }
    pub fn showGlance(self: *View, which: Slot, title: []const u8, detail: []const u8, meta: []const u8) !void {
        try self.glance_title.setTextContent(self.cx.allocator, title);
        try self.glance_detail.setTextContent(self.cx.allocator, detail);
        try self.glance_meta.setTextContent(self.cx.allocator, meta);
        self.glance_kind = which;
        if (self.glanceRect() != null) self.glance.show.invoke() else self.glance_kind = null;
    }
    pub fn closeGlance(self: *View) void {
        self.glance.close.invoke();
        self.glance_kind = null;
    }
    pub fn glanceFor(self: *View, which: Slot) ?*ui.Node {
        return if (self.glance_kind == which and self.glance.open.?.peek()) self.glance.content else null;
    }

    pub fn setVisible(self: *View, visible: bool) void {
        if ((self.root.style.display != .none) == visible) return;
        if (!visible) {
            self.endPreview();
            for (0..slot_count) |i| {
                const which: Slot = @fromBackingInt(@intCast(i));
                if (self.hooks.panel(self.hooks.context, which) != null) self.hooks.close_preview(self.hooks.context, which);
            }
            self.candidate = null;
            self.suppressed = null;
            self.pinned = false;
            self.ignore_badge_until_leave = false;
            self.expanded = false;
            self.progress = 0;
            self.last_ms = null;
            self.collapse_after_ms = 0;
            self.rail.setDisplay(.none);
            for (self.slots) |n| n.setDisplay(.none);
        }
        self.root.setDisplay(if (visible) .flex else .none);
        self.cx.requestRedraw();
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

    /// A panel opened from the rail expands it. Compute the live landing
    /// envelope from this layout's workspace/direction, rather than using
    /// stale absolute boxes from before a drag or resize. The animated slots
    /// and active collapsed controls always stay in this envelope.
    pub fn toolFootprint(self: *View) ?ToolFootprint {
        if (!self.root.isDisplayedInTree()) return null;
        const canvas = self.root.globalRect();
        if (canvas.w <= 0 or canvas.h <= 0) return null;
        const c = self.userCenter(canvas.w, canvas.h);
        var n: usize = 0;
        for (0..slot_count) |i| n += @intFromBool(self.applicable(i));
        const dir = directionFor(c, canvas.w, canvas.h, n);
        const destination = unionRect(boxAt(c, S.body_size, S.body_size), railRect(c, dir, railLength(@floatFromInt(n))));
        return .{ .bounds = translateRect(destination, canvas.x, canvas.y), .horizontal = dir == .left or dir == .right };
    }

    pub fn workspacePanelRect(self: *View, trigger: ui.ComputedRect, width: f32, height: f32, min_w: f32, min_h: f32) ?ui.ComputedRect {
        const footprint = self.toolFootprint() orelse return null;
        const workspace = self.root.globalRect();
        const cx = self.cx;
        const x = @max(cx.safe_area_left, workspace.x);
        const y = @max(cx.safe_area_top, workspace.y);
        return lateralPanelRect(.{
            .x = x,
            .y = y,
            .w = @max(0, @min(cx.viewport.width - cx.safe_area_right, workspace.x + workspace.w) - x),
            .h = @max(0, @min(cx.viewport.height - cx.safe_area_bottom, workspace.y + workspace.h) - y),
        }, footprint.bounds, trigger, width, height, min_w, min_h);
    }

    pub fn publishPanelOrigin(node: *ui.Node, target: ui.ComputedRect) void {
        const parent = node.parent orelse return;
        const base = parent.globalRect();
        const x = target.x - base.x;
        const y = target.y - base.y;
        if (@abs(node.style.translate_x - x) > 0.01 or @abs(node.style.translate_y - y) > 0.01) {
            node.style.translate_x = x;
            node.style.translate_y = y;
            node.markCompositePropDirty();
        }
    }

    fn applicable(self: *const View, index: usize) bool {
        return switch (index) {
            0 => true,
            1 => self.activity.forward_available,
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

    fn mascotKey(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *View = @ptrCast(@alignCast(raw orelse return .ignored));
        if (event == .key_down and (event.key_down.key == .@"return" or event.key_down.key == .space)) {
            self.togglePin();
            return .stop;
        }
        return .ignored;
    }
    fn togglePin(self: *View) void {
        if (self.expanded and self.pinned) {
            self.pinned = false;
            self.expanded = false;
            self.ignore_badge_until_leave = true;
            self.collapse_after_ms = 0;
        } else {
            self.pinned = true;
            self.ignore_badge_until_leave = false;
            self.expanded = true;
        }
        self.cx.requestRedraw();
    }

    fn drag(event: ui.interaction.drag.Event, raw: *anyopaque) void {
        const self: *View = @ptrCast(@alignCast(raw));
        const rect = self.root.globalRect();
        if (rect.w <= 0 or rect.h <= 0) return;
        switch (event.phase) {
            .start => {
                self.dragging = true;
                self.endPreview();
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
                    self.togglePin();
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

    const SlotEvent = struct {
        view: *View,
        which: Slot,
        fn capture(e: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
            const item: *SlotEvent = @ptrCast(@alignCast(raw orelse return .ignored));
            if (e != .click or item.view.preview != item.which) return .ignored;
            // A click on an already-open hover preview pins that same panel;
            // never call a toggle which would close it (or perform an action).
            if (item.view.hooks.panel(item.view.hooks.context, item.which) == null) return .ignored;
            item.view.hooks.pin_preview(item.view.hooks.context, item.which);
            item.view.preview = null;
            item.view.preview_leave = null;
            item.view.suppressed = item.which;
            return .stop;
        }
    };

    fn endPreview(self: *View) void {
        const which = self.preview orelse return;
        self.preview = null;
        self.preview_leave = null;
        self.hooks.close_preview(self.hooks.context, which);
    }
    fn within(self: *View, node: *ui.Node) bool {
        if (!node.isDisplayedInTree()) return false;
        const r = node.globalRect();
        return r.w > 0 and r.h > 0 and r.contains(self.cx.mouse_x, self.cx.mouse_y);
    }
    // A geometric route through the visual gap, not another input layer.
    // Other tools keep their real hit targets and can take over the preview.
    fn bridgeContains(source: ui.ComputedRect, panel: ui.ComputedRect, x: f32, y: f32) bool {
        if (source.w <= 0 or source.h <= 0 or panel.w <= 0 or panel.h <= 0) return false;
        if (source.x >= panel.x + panel.w) return bridgeAxis(source.x, panel.x + panel.w, source.y, source.h, panel.y, panel.h, x, y);
        if (panel.x >= source.x + source.w) return bridgeAxis(source.x + source.w, panel.x, source.y, source.h, panel.y, panel.h, x, y);
        if (source.y >= panel.y + panel.h) return bridgeAxis(source.y, panel.y + panel.h, source.x, source.w, panel.x, panel.w, y, x);
        if (panel.y >= source.y + source.h) return bridgeAxis(source.y + source.h, panel.y, source.x, source.w, panel.x, panel.w, y, x);
        return false;
    }
    fn bridgeAxis(from: f32, to: f32, src: f32, src_len: f32, dst: f32, dst_len: f32, at: f32, cross: f32) bool {
        if (from == to or at < @min(from, to) or at > @max(from, to)) return false;
        const f = (at - from) / (to - from);
        const start = src + src_len / 2;
        const inset = @min(@as(f32, 8), dst_len / 2);
        const end = std.math.clamp(start, dst + inset, dst + dst_len - inset);
        const middle = start + (end - start) * f;
        return @abs(cross - middle) <= src_len / 2 + 3;
    }
    fn schedule(self: *View, ms: f64) void {
        self.cx.scheduleRedrawAfterNs(@intFromFloat(@ceil(@max(1, ms) * std.time.ns_per_ms)));
    }
    fn previewTick(self: *View, wanted: ?Slot, inside_panel: bool, now: f64) void {
        if (wanted != self.suppressed) self.suppressed = null;
        if (wanted != self.candidate) {
            self.candidate = wanted;
            self.candidate_since = now;
        }
        if (self.preview) |which| {
            if (self.hooks.panel(self.hooks.context, which) == null) {
                // Escape, an explicit dismissal, or navigation away from a
                // preview must not reopen it under a stationary pointer.
                self.suppressed = which;
                self.preview = null;
                self.preview_leave = null;
            } else if (inside_panel or wanted == which) {
                self.preview_leave = null;
                return;
            } else {
                const deadline = self.preview_leave orelse now + leave_ms;
                self.preview_leave = deadline;
                if (now < deadline and (wanted == null or now < self.candidate_since + enter_ms)) {
                    self.schedule(@min(deadline - now, if (wanted != null) self.candidate_since + enter_ms - now else leave_ms));
                    return;
                }
                self.endPreview();
            }
        }
        const which = wanted orelse return;
        if (self.suppressed == which or self.dragging or self.progress < 0.98 and !self.active(@backingInt(which))) return;
        const remaining = self.candidate_since + enter_ms - now;
        if (remaining > 0) {
            self.schedule(remaining);
            return;
        }
        // A user-opened panel has its own lifetime. Never replace it on hover.
        for (0..slot_count) |index| if (self.hooks.panel(self.hooks.context, @fromBackingInt(@intCast(index))) != null) return;
        if (self.cx.overlay_stack.hasGroup(@import("floating_surface.zig").workspace_popup)) return;
        const focus = if (self.cx.focus_manager.current_focus) |n| self.cx.node_registry.handleFor(n) else null;
        self.hooks.open_preview(self.hooks.context, which);
        if (self.cx.node_registry.resolve(focus, null)) |n| self.cx.setFocus(n) else self.cx.clearFocus();
        if (self.hooks.panel(self.hooks.context, which) != null) self.preview = which else self.suppressed = which;
    }

    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        if (!self.root.isDisplayedInTree()) return .done;
        const rect = self.root.globalRect();
        if (rect.w <= 0 or rect.h <= 0) return .done;
        const c = self.userCenter(rect.w, rect.h);
        self.center_x = c[0];
        self.center_y = c[1];
        var n: usize = 0;
        var active_n: usize = 0;
        for (0..slot_count) |i| if (self.applicable(i)) {
            n += 1;
            active_n += @intFromBool(self.active(i));
        };
        const dir = directionFor(c, rect.w, rect.h, n);
        const now = self.cx.frame_time_ms;
        const target = self.cx.node_registry.resolve(self.cx.dispatcher.hovered_handle, null);
        const focus = if (self.cx.focus_manager.focus_visible) self.cx.focus_manager.current_focus else null;
        var hovered: ?Slot = null;
        var tool_focused = false;
        var panel_open = false;
        var inside_panel = false;
        var bridge_panel: ?struct { slot: Slot, node: *ui.Node } = null;
        if (self.glance_kind != null and self.glance.open.?.peek()) {
            if (self.glanceRect()) |r| publishPanelOrigin(self.glance.chrome, r) else self.closeGlance();
        }
        for (self.slots, 0..) |node, i| {
            const which: Slot = @fromBackingInt(@intCast(i));
            if (self.hooks.panel(self.hooks.context, which)) |panel| {
                panel_open = true;
                if (self.preview == which) {
                    inside_panel = self.within(panel) or (if (target) |t|
                        (which != .forward or self.within(t)) and @import("floating_input.zig").containsPress(self.cx, panel, t)
                    else
                        false);
                    bridge_panel = .{ .slot = which, .node = panel };
                }
            }
            if (self.applicable(i) and node.isDisplayedInTree()) if (focus) |f| {
                tool_focused = tool_focused or f.isDescendantOf(node);
            };
            if (self.applicable(i) and self.within(node) and
                (if (target) |t| t.isDescendantOf(node) else false)) hovered = which;
        }
        if (bridge_panel) |item| {
            if (!inside_panel and hovered == null and item.node.isDisplayedInTree() and item.node.getOpacity() >= 0.99) {
                inside_panel = bridgeContains(self.slot(item.slot).globalRect(), item.node.globalRect(), self.cx.mouse_x, self.cx.mouse_y);
            }
        }
        const body_hover = if (target) |t| (t.isDescendantOf(self.root) and (self.within(self.body) or self.within(self.rail))) else false;
        if (!body_hover) self.ignore_badge_until_leave = false;
        // Clicking the badge latches the current interaction, not the rail
        // indefinitely. Keyboard activation still keeps the trail open while
        // the trigger/one of its tools has visible keyboard focus.
        const badge_keyboard = self.pinned and (if (focus) |node| node == self.grab else false);
        const hovering = !self.dragging and (body_hover and !self.ignore_badge_until_leave or hovered != null or panel_open or tool_focused or badge_keyboard);
        if (hovering) {
            self.expanded = true;
            self.collapse_after_ms = now + leave_ms;
        } else if (!self.dragging and self.expanded) {
            if (now >= self.collapse_after_ms) {
                self.expanded = false;
                self.pinned = false;
            } else self.schedule(self.collapse_after_ms - now);
        }
        self.previewTick(if (inside_panel) null else hovered, inside_panel, now);
        const dt = if (self.last_ms) |old| now - old else 0;
        self.last_ms = now;
        self.progress = advance(self.progress, self.expanded, @min(dt, if (self.progress == 0 and self.expanded or self.progress == 1 and !self.expanded) @as(f64, 16) else std.math.inf(f64)), ui.a11y.preferences.reduceMotion());
        if ((self.expanded and self.progress < 1) or (!self.expanded and self.progress > 0)) self.schedule(16);
        const t = eased(self.progress);
        var dirty = self.place(0, self.body, boxAt(c, S.body_size, S.body_size));
        dirty = self.place(1, self.grab, boxAt(c, S.body_size, S.body_size)) or dirty;
        const has_rail = n > 0 and (t > 0 or active_n > 0);
        dirty = display(self.rail, has_rail) or dirty;
        if (has_rail) {
            const len = railLength(@as(f32, @floatFromInt(active_n)) + @as(f32, @floatFromInt(n - active_n)) * t);
            dirty = self.place(2, self.rail, railRect(c, dir, len)) or dirty;
            self.rail.setOpacityRaw(if (active_n > 0) 1 else t);
        }
        var active_rank: usize = 0;
        var rank: usize = 0;
        for (self.slots, 0..) |slot_node, index| {
            const applicable_ = self.applicable(index);
            const active_ = applicable_ and self.active(index);
            const visible = applicable_ and (active_ or t > 0.001);
            dirty = display(slot_node, visible) or dirty;
            if (!visible) continue;
            const from: f32 = @floatFromInt(active_rank);
            const to: f32 = @floatFromInt(rank);
            const stride = S.slot_size + S.slot_gap;
            const radius = S.body_size / 2 + S.rail_gap + S.rail_padding + S.slot_size / 2 +
                (if (active_) from + (to - from) * t else to * t) * stride - (if (active_) @as(f32, 0) else 10 * (1 - t));
            dirty = self.place(3 + index, slot_node, boxAt(onAxis(c, dir, radius), S.slot_size, S.slot_size)) or dirty;
            slot_node.setOpacityRaw(if (active_) 1 else t);
            const shows_dot = index == 1 and self.activity.forward_active or index == 2 and self.activity.broadcast_active;
            dirty = display(self.dots[index], shows_dot) or dirty;
            rank += 1;
            active_rank += @intFromBool(active_);
        }
        return if (dirty) .needs_layout else .done;
    }

    fn place(self: *View, i: usize, node: *ui.Node, r: ui.ComputedRect) bool {
        if (self.geometry[i]) |old| if (std.meta.eql(old, r)) return false;
        self.geometry[i] = r;
        node.setStyleInline(self.cx.allocator, .{ .width = .{ .px = r.w }, .height = .{ .px = r.h }, .inset = .{ .left = .{ .px = r.x }, .top = .{ .px = r.y } } });
        return true;
    }
    fn display(node: *ui.Node, visible: bool) bool {
        if ((node.style.display != .none) == visible) return false;
        node.setDisplay(if (visible) .flex else .none);
        return true;
    }
    fn cleanup(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
    }
};

test "mascot tools prefer up and fall back inside all viewport edges" {
    const cases = [_]struct { c: [2]f32, w: f32, h: f32, dir: Direction }{
        .{ .c = .{ 362, 362 }, .w = 400, .h = 400, .dir = .up },
        .{ .c = .{ 38, 362 }, .w = 400, .h = 400, .dir = .up },
        .{ .c = .{ 362, 162 }, .w = 400, .h = 200, .dir = .left },
        .{ .c = .{ 38, 38 }, .w = 400, .h = 200, .dir = .right },
        .{ .c = .{ 72, 38 }, .w = 140, .h = 450, .dir = .down },
        .{ .c = .{ 72, 412 }, .w = 140, .h = 450, .dir = .up },
    };
    for (cases) |c| {
        const dir = directionFor(c.c, c.w, c.h, 5);
        try std.testing.expectEqual(c.dir, dir);
        for (0..5) |i| {
            const center = onAxis(c.c, dir, S.body_size / 2 + S.rail_gap + S.rail_padding + S.slot_size / 2 + @as(f32, @floatFromInt(i)) * (S.slot_size + S.slot_gap));
            const rect = boxAt(center, S.slot_size, S.slot_size);
            try std.testing.expect(rect.x >= 0 and rect.y >= 0 and rect.x + rect.w <= c.w and rect.y + rect.h <= c.h);
        }
    }
}
test "mascot tools reverse along the same motion and respect reduced motion" {
    const partial = advance(0, true, 110, false);
    try std.testing.expectEqual(@as(f32, 0.5), eased(partial));
    try std.testing.expectEqual(partial, advance(advance(partial, false, 55, false), true, 55, false));
    try std.testing.expectEqual(@as(f32, 0), advance(partial, false, 1, true));
    try std.testing.expectEqual(@as(f32, 1), advance(partial, true, 1, true));
}
test "mascot preview follows the anchor and does not cover its trigger or clip against edges" {
    const bounds = ui.ComputedRect{ .x = 80, .y = 40, .w = 680, .h = 480 };
    for ([_][2]f32{ .{ 94, 52 }, .{ 716, 54 }, .{ 96, 466 }, .{ 719, 470 }, .{ 400, 230 } }) |at| {
        const anchor = ui.ComputedRect{ .x = at[0], .y = at[1], .w = 28, .h = 28 };
        const r = panelRect(bounds, anchor, 640, 578);
        try std.testing.expect(r.x >= bounds.x and r.y >= bounds.y and r.x + r.w <= bounds.x + bounds.w and r.y + r.h <= bounds.y + bounds.h);
        try std.testing.expect(r.y + r.h <= anchor.y or r.y >= anchor.y + anchor.h);
    }
}

test "mascot side panels stay outside the complete function group" {
    const bounds: ui.ComputedRect = .{ .x = 220, .y = 20, .w = 760, .h = 520 };
    const right_rail: ui.ComputedRect = .{ .x = 922, .y = 310, .w = 44, .h = 216 };
    const left_rail: ui.ComputedRect = .{ .x = 232, .y = 50, .w = 44, .h = 200 };
    const tight: ui.ComputedRect = .{ .x = 800, .y = 180, .w = 150, .h = 270 };
    const transfer = lateralPanelRect(bounds, right_rail, right_rail, 640, 400, 288, 166).?;
    try std.testing.expect(transfer.x + transfer.w + 12 <= right_rail.x);
    try std.testing.expect(transfer.y >= bounds.y + 12 and transfer.y + transfer.h + 12 <= bounds.y + bounds.h);
    const chain = lateralPanelRect(bounds, left_rail, left_rail, 380, 312, 284, 190).?;
    try std.testing.expect(chain.x >= left_rail.x + left_rail.w + 12);
    try std.testing.expect(lateralPanelRect(tight, right_rail, right_rail, 380, 312, 284, 190) == null);
}
