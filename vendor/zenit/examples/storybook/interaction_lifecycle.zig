//! Core dispatch contract fixture. These deliberately use raw event targets:
//! replacing a widget's private handlers would test an unsupported widget API.
//! Layout, focusability and on_focus / on_blur are declared with ui.view; the raw
//! on_event handler, path hit geometry and the status hook stay node-level (v.setup).
const std = @import("std");
const ui = @import("ui");

const v = ui.view;

const State = struct {
    cx: *ui.Cx,
    status: *ui.Signal([]const u8),
    click_target: ?*ui.Node = null,
    focus_target: ?*ui.Node = null,
    destination: ?*ui.Node = null,
    removed: usize = 0,
    followups: usize = 0,
    blurs: usize = 0,
    path_clicks: usize = 0,
    oom: bool = false,
    shown: [256]u8 = undefined,
    shown_len: usize = 0,

    fn removeClick(self: *State) void {
        const node = self.click_target orelse return;
        self.click_target = null;
        self.cx.detachChild(node.parent.?, node);
        self.cx.freeNode(node);
        self.removed += 1;
    }
    fn followup(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *State = @ptrCast(@alignCast(raw.?));
        if (event == .click) self.followups += 1;
        return .ignored;
    }
    fn blur(self: *State) void {
        self.blurs += 1;
        // Bound a broken implementation so the test reports recursion precisely.
        if (self.blurs < 5) self.cx.focus_manager.setFocus(self.destination.?);
    }
    fn redirect(self: *State) void {
        self.cx.focus_manager.setFocus(self.destination.?);
    }
    fn removeFocus(self: *State) void {
        const node = self.focus_target orelse return;
        self.focus_target = null;
        self.cx.detachChild(node.parent.?, node);
        self.cx.freeNode(node);
    }
    fn pathClick(self: *State) void {
        self.path_clicks += 1;
    }
    fn tick(node: *ui.Node) void {
        const self: *State = @ptrCast(@alignCast(node.meta.per_frame.hooks.slots.anim_state.?));
        const actual = self.cx.focus_manager.getFocused();
        const focus_name: []const u8 = if (actual) |n| n.meta.ownership.meta.test_id orelse "other" else "none";
        var buf: [256]u8 = undefined;
        const value = std.fmt.bufPrint(&buf, "removed={d} followups={d} blurs={d} path={d} oom={} cache={} focus={s}", .{
            self.removed,                   self.followups, self.blurs, self.path_clicks, self.oom,
            self.cx.focused_node == actual, focus_name,
        }) catch unreachable;
        if (!std.mem.eql(u8, self.shown[0..self.shown_len], value)) {
            self.status.set(value);
            @memcpy(self.shown[0..value.len], value);
            self.shown_len = value.len;
        }
    }

    // ── v.setup callback: node-level wiring DSL can't reach ──

    fn wireFollowup(self: *State, node: *ui.Node) void {
        node.behavior.events.on_event = State.followup;
        node.behavior.events.event_context = self;
    }
    fn wirePath(self: *State, path: *ui.Node, _: *ui.Scope, cx: *ui.Cx) !void {
        (try path.style.ensureExtFallible(cx.allocator)).hit_shape = .{ .path = .{} };
        try path.setSvgPathHitGeometry(cx.allocator, "M0 0 H80 V38 H0 Z", .nonzero);
        var failing = std.testing.FailingAllocator.init(cx.allocator, .{ .fail_index = 0 });
        path.setPathHitGeometry(failing.allocator(), path.getLayoutOutput().vector.fill.path.?.commands, .evenodd) catch |err| {
            self.oom = err == error.OutOfMemory;
        };
    }
    fn installTick(self: *State, root: *ui.Node) void {
        root.meta.per_frame.hooks.slots.anim_state = self;
        root.addBeforeRender(State.tick);
    }
};

const LifecycleS = struct {
    fn root(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .gap = 8 };
    }
    fn target(t: *const ui.theme.Values) ui.BoxStyle {
        return .{
            .width = .{ .px = 320 },
            .height = .{ .px = 38 },
            .background = t.tokens.color.bg_secondary,
            .padding = ui.Padding.all(8),
        };
    }
    fn targetText(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 13, .color = t.tokens.color.fg_primary };
    }
    fn status(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 12, .color = t.tokens.color.fg_primary };
    }
};

const TargetProps = struct {
    title: []const u8,
    id: []const u8,
    on_click: ?ui.HandlerRef = null,
    on_focus: ?ui.HandlerRef = null,
    on_blur: ?ui.HandlerRef = null,
};

/// Focusable hit target: title text doesn't participate in hit, click / focus both land on outer
/// frame.
fn target(p: TargetProps, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    return v.render(scope, cx, v.box(.{
        .style = LifecycleS.target,
        .test_id = p.id,
        .focusable = true,
        .on_click = p.on_click,
        .on_focus = p.on_focus,
        .on_blur = p.on_blur,
    }, .{
        v.text(.{ .style = LifecycleS.targetText, .hit_test = false }, p.title),
    }));
}

pub fn build(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const state = try scope.createState(State, .{
        .cx = cx,
        .status = try scope.createText("Waiting for frame", .{}),
    });
    return v.render(scope, cx, v.setup(v.col(.{ .style = LifecycleS.root }, .{
        v.capture(&state.destination, v.component(target, .{ .title = "Settled focus destination", .id = "lifecycle.destination" })),
        v.setup(v.capture(&state.click_target, v.component(target, .{ .title = "Click removes this target", .id = "lifecycle.click-remove", .on_click = ui.on.call(state, State.removeClick) })), state, State.wireFollowup),
        v.component(target, .{ .title = "Focus me, then click attempted destination", .id = "lifecycle.blur-source", .on_blur = ui.on.call(state, State.blur) }),
        v.component(target, .{ .title = "Attempted focus destination", .id = "lifecycle.attempted" }),
        v.component(target, .{ .title = "Focus redirects to settled destination", .id = "lifecycle.redirect", .on_focus = ui.on.call(state, State.redirect) }),
        v.capture(&state.focus_target, v.component(target, .{ .title = "Focus removes this target", .id = "lifecycle.focus-remove", .on_focus = ui.on.call(state, State.removeFocus) })),
        v.setup(v.component(target, .{ .title = "Path hit area: left 80 px only", .id = "lifecycle.path", .on_click = ui.on.call(state, State.pathClick) }), state, State.wirePath),
        v.text(.{ .style = LifecycleS.status, .test_id = "lifecycle.status" }, state.status),
    }), state, State.installTick));
}
