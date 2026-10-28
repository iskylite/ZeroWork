//! Short, interruptible geometry changes. Typing and live output stay immediate.
const std = @import("std");
const ui = @import("ui");

pub fn reduced(cx: *ui.Cx) bool {
    return cx.reduced_motion or cx.renderer_reduced_motion or ui.a11y.preferences.reduceMotion();
}

pub const Height = struct {
    value: ?f32 = null,
    target: f32 = 0,
    from: f32 = 0,
    started: f64 = 0,

    pub fn sample(self: *Height, cx: *ui.Cx, target: f32, animate: bool) f32 {
        if (self.value == null or !animate or reduced(cx)) {
            self.* = .{ .value = target, .target = target, .from = target, .started = cx.frame_time_ms };
            return target;
        }
        if (@abs(target - self.target) > 0.1) {
            self.from = self.value.?;
            self.target = target;
            self.started = cx.frame_time_ms;
        }
        const t: f32 = @floatCast(std.math.clamp((cx.frame_time_ms - self.started) / 200, 0, 1));
        const rest = 1 - t;
        self.value = self.from + (self.target - self.from) * (1 - rest * rest * rest);
        if (t < 1 and @abs(self.value.? - self.target) > 0.1) cx.scheduleRedrawAfterNs(8 * std.time.ns_per_ms) else self.value = self.target;
        return self.value.?;
    }
};

pub const Disclosure = struct {
    cx: *ui.Cx,
    root: *ui.Node,
    content: *ui.Node,
    expanded: bool,
    animating: bool = false,
    motion: Height = .{},

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, content: *ui.Node, expanded: bool) !*Disclosure {
        const root = try ui.box(cx, .{ .width = .fill(), .height = if (expanded) .{ .fit = .{} } else .{ .px = 0 }, .direction = .column, .flex_shrink = 0, .overflow_hidden = true }, .{});
        try root.appendChild(cx.allocator, content);
        const self = try scope.createState(Disclosure, .{ .cx = cx, .root = root, .content = content, .expanded = expanded });
        try cx.addAfterLayoutHook(self, afterLayout);
        try scope.onCleanup(Disclosure, self, cleanup);
        root.setHitTestVisible(expanded);
        return self;
    }
    pub fn setExpanded(self: *Disclosure, expanded: bool) void {
        if (expanded == self.expanded) return;
        self.expanded = expanded;
        self.animating = true;
        if (!expanded) self.cx.invalidateReferencesTo(self.content);
        self.root.setHitTestVisible(expanded);
        self.cx.requestRedraw();
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Disclosure = @ptrCast(@alignCast(raw));
        const target = if (self.expanded) self.content.globalRect().h else 0;
        const height = self.motion.sample(self.cx, target, self.animating);
        if (@abs(height - target) < 0.1) self.animating = false;
        if (self.root.style.height == .px and @abs(self.root.style.height.px - height) < 0.05) return .done;
        self.root.setStyle(self.cx.allocator, .height, .{ .px = height });
        return .needs_layout;
    }
    fn cleanup(self: *Disclosure) void {
        self.cx.removeAfterLayoutHook(self);
    }
};

test "layout motion reverses at its current height and finishes at the latest target" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    var height: Height = .{};
    cx.frame_time_ms = 0;
    try std.testing.expectEqual(@as(f32, 100), height.sample(cx, 100, true));
    _ = height.sample(cx, 300, true);
    cx.frame_time_ms = 80;
    const expanding = height.sample(cx, 300, true);
    try std.testing.expect(expanding > 100 and expanding < 300);
    try std.testing.expectEqual(expanding, height.sample(cx, 100, true));
    cx.frame_time_ms = 160;
    const shrinking = height.sample(cx, 100, true);
    try std.testing.expect(shrinking > 100 and shrinking < expanding);
    cx.frame_time_ms = 300;
    try std.testing.expectEqual(@as(f32, 100), height.sample(cx, 100, true));
}

test "layout motion honors system reduced motion and immediate viewport constraints" {
    const preferences = ui.a11y.preferences;
    const saved = preferences.current();
    defer preferences.set(saved);
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    var height: Height = .{};
    _ = height.sample(cx, 100, true);
    preferences.set(.{ .reduce_motion = true });
    try std.testing.expectEqual(@as(f32, 300), height.sample(cx, 300, true));
    preferences.set(.{});
    try std.testing.expectEqual(@as(f32, 80), height.sample(cx, 80, false));
}

test "layout motion disclosure clips both directions and releases its hook with its scope" {
    const a = std.testing.allocator;
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 400);
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    cx.root = root;
    const content = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 160 }, .flex_shrink = 0 }, .{});
    const disclosure = try Disclosure.mount(cx, scope, content, false);
    try root.appendChild(a, disclosure.root);
    cx.frame_time_ms = 0;
    cx.layout();
    _ = afterTestFrame(disclosure);
    try std.testing.expectEqual(@as(f32, 0), disclosure.root.style.height.px);
    disclosure.setExpanded(true);
    _ = afterTestFrame(disclosure);
    cx.frame_time_ms = 80;
    _ = afterTestFrame(disclosure);
    const opening = disclosure.root.style.height.px;
    try std.testing.expect(opening > 0 and opening < 160);
    disclosure.setExpanded(false);
    _ = afterTestFrame(disclosure);
    try std.testing.expectEqual(opening, disclosure.root.style.height.px);
    cx.frame_time_ms = 300;
    _ = afterTestFrame(disclosure);
    try std.testing.expectEqual(@as(f32, 0), disclosure.root.style.height.px);
}
fn afterTestFrame(disclosure: *Disclosure) ui.AfterLayoutResult {
    disclosure.cx.layout();
    return Disclosure.afterLayout(disclosure, 0, false);
}
