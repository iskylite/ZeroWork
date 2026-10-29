//! PATCH disclosure bodies keep their vertical input, including at either edge.
//! Short bodies still pass input to the conversation. The native ScrollArea owns
//! layout, physics, scrollbar drag, and cleanup; only nested-chain policy differs.
const ui = @import("ui");
const scroll_area = ui.widgets.scroll_area;
const Positions = @import("../ai/tool_results.zig").ScrollPositions;

/// Create before the associated ScrollAreas: Scope releases siblings in creation
/// order, so cleanup can save the last input before native state is destroyed.
pub const Keeper = struct {
    cx: *ui.Cx,
    positions: *Positions,
    bindings: [4]?Binding = @splat(null),
    const Binding = struct { cell: *scroll_area.ScrollCtxCell, restoring: bool = true };
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, positions: *Positions) !*Keeper {
        const keeper_scope = try scope.childScope();
        const self = try keeper_scope.createState(Keeper, .{ .cx = cx, .positions = positions });
        positions.retain();
        keeper_scope.onCleanup(Keeper, self, cleanup) catch |err| {
            positions.release();
            return err;
        };
        try cx.addAfterLayoutHook(self, tick);
        return self;
    }
    pub fn bind(self: *Keeper, slot: Positions.Slot, scroll: ui.widgets.ScrollAreaResult) void {
        showOverflowScrollbar(scroll);
        const ctx: *const scroll_area.ScrollEventCtx = @ptrCast(@alignCast(scroll.container.behavior.events.event_context.?));
        self.bindings[@backingInt(slot)] = .{ .cell = ctx.cell.? };
    }
    pub fn resetTarget(self: *Keeper) void {
        for ([_]Positions.Slot{ .body, .stdout, .stderr }) |slot| {
            const index = @backingInt(slot);
            self.positions.offsets[index] = .{};
            if (self.bindings[index]) |*binding| binding.restoring = true;
        }
    }
    fn save(self: *Keeper) void {
        for (&self.bindings, &self.positions.offsets) |*maybe_binding, *offset| {
            const binding = maybe_binding.* orelse continue;
            if (binding.restoring) continue;
            const ctx = binding.cell.ctx orelse continue;
            offset.* = .{ .x = ctx.state.scroll_x, .y = ctx.state.scroll_y };
        }
    }
    fn tick(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Keeper = @ptrCast(@alignCast(raw));
        for (&self.bindings, self.positions.offsets) |*maybe_binding, offset| {
            const binding = if (maybe_binding.*) |*value| value else continue;
            if (!binding.restoring) continue;
            const ctx = binding.cell.ctx orelse continue;
            const container = ctx.container orelse continue;
            const content = ctx.content orelse continue;
            const viewport = container.globalRect();
            const size = content.globalRect();
            if (viewport.h <= 0 or viewport.w <= 0 or size.h <= 0) continue;
            ctx.state.viewport_height = viewport.h - container.style.padding.vertical();
            ctx.state.viewport_width = viewport.w - container.style.padding.horizontal();
            ctx.state.content_height = size.h;
            ctx.state.content_width = size.w;
            ui.widgets.setScrollY(ctx.state, content, offset.y);
            scroll_area.applyHorizontalScroll(ctx.state, ctx.state.scroll_x - offset.x, 1, .wheel);
            content.style.translate_x = ctx.state.contentTranslateX();
            content.markCompositePropDirty();
            binding.restoring = false;
        }
        self.save();
        return .done;
    }
    fn cleanup(self: *Keeper) void {
        self.save();
        self.cx.removeAfterLayoutHook(self);
        self.positions.release();
    }
};

pub fn containVertical(scroll: ui.widgets.ScrollAreaResult) void {
    showOverflowScrollbar(scroll);
    const ctx: *const scroll_area.ScrollEventCtx = @ptrCast(@alignCast(scroll.container.behavior.events.event_context.?));
    scroll.container.behavior.events.on_event_capture = eventHandler;
    // The native relay cell lives until Cx destruction and nulls ctx before its
    // scope is released. Captures are safe even when a disposed tree is retained.
    scroll.container.behavior.events.capture_context = ctx.cell.?;
}

/// Keep the native thumb discoverable while idle. ScrollArea still checks actual
/// overflow before drawing it; this neither reserves space nor creates fake bars.
/// Its public per-instance fade state avoids a custom drawing or redraw loop.
pub fn showOverflowScrollbar(scroll: ui.widgets.ScrollAreaResult) void {
    const ctx: *const scroll_area.ScrollEventCtx = @ptrCast(@alignCast(scroll.container.behavior.events.event_context.?));
    if (ctx.direction != .horizontal) {
        scroll.state.scrollbar_fade.fade_speed = 0;
        scroll.state.scrollbar_fade.onActivity();
    }
    if (ctx.direction != .vertical) {
        scroll.state.scrollbar_fade_h.fade_speed = 0;
        scroll.state.scrollbar_fade_h.onActivity();
    }
}

/// Approval cards can contain a second bounded vertical viewport. Give its
/// capture first refusal, following the dispatcher's locked gesture owner rather
/// than the moving content under the pointer. Native handling has not run yet,
/// so a boundary-crossing delta is applied once, never replayed after clamping.
fn hasDeeperScrollableBody(ctx: *const scroll_area.ScrollEventCtx, scroll: ui.events.ScrollEvent) bool {
    const dispatcher = &ctx.cx.dispatcher;
    const owner = if (scroll.isMomentum()) dispatcher.scroll_momentum_owner else if (scroll.phase != .none) dispatcher.scroll_session_owner else null;
    var node = if (owner) |handle| ctx.cx.node_registry.resolve(handle, null) else ctx.cx.hitTest(scroll.x, scroll.y);
    var deeper = false;
    while (node) |candidate| : (node = candidate.parent) {
        if (candidate == ctx.container) return deeper;
        if (candidate.behavior.events.on_event_capture != eventHandler) continue;
        const cell: *const scroll_area.ScrollCtxCell = @ptrCast(@alignCast(candidate.behavior.events.capture_context orelse continue));
        const child_ctx = cell.ctx orelse continue;
        if (child_ctx.state.maxScrollY() > scroll_area.ScrollState.scroll_tuning.jitter_snap_epsilon) deeper = true;
    }
    return false;
}

fn eventHandler(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
    const scroll = switch (event) {
        .scroll => |value| value,
        else => return .ignored,
    };
    const cell: *const scroll_area.ScrollCtxCell = @ptrCast(@alignCast(raw orelse return .ignored));
    const ctx = cell.ctx orelse return .ignored;
    const content = ctx.content orelse return .ignored;
    const container = ctx.container orelse return .ignored;
    const state = ctx.state;
    if (hasDeeperScrollableBody(ctx, scroll)) return .ignored;
    const viewport = container.rectFromWorldOrFallback();
    state.viewport_height = viewport.h - container.style.padding.vertical();
    state.viewport_width = viewport.w - container.style.padding.horizontal();
    const size = content.rectFromWorldOrFallback();
    if (!state.external_content_height and size.h > 0) state.content_height = size.h;
    if (!state.external_content_width and size.w > 0) state.content_width = size.w;

    // An axis-only command/output viewport must not turn vertical input into
    // horizontal activity. Likewise, an unscrollable disclosure never traps it.
    const epsilon = scroll_area.ScrollState.scroll_tuning.jitter_snap_epsilon;
    if (state.maxScrollY() <= epsilon) return .ignored;
    if (@abs(scroll.dx) > @max(@abs(scroll.dy), epsilon)) return .ignored;
    if (scroll.isMomentum() and !state.latched) return .ignored;

    switch (scroll.phase) {
        .may_begin, .began => {
            state.latched = false;
            state.momentum_active = false;
            state.momentum_spent_y = false;
            if (scroll.dx == 0 and scroll.dy == 0) return .ignored;
        },
        .ended, .cancelled => {
            if (!state.touching and !state.latched) return .ignored;
            state.touching = false;
            if (state.bonus_y != 0) state.momentum_spent_y = true;
            if (scroll.phase == .cancelled) state.latched = false;
            return .stop;
        },
        .none, .changed => {},
    }
    const kind: scroll_area.scroll_physics.InputKind = if (scroll.isMomentum()) .momentum else if (scroll.phase == .none) .wheel else .gesture;
    switch (kind) {
        .momentum => {
            state.touching = false;
            if (scroll.momentum == .ended) {
                state.momentum_active = false;
                state.latched = false;
                return .stop;
            }
            state.momentum_active = true;
            // Once inertia reaches an edge, the existing ScrollArea spring
            // finishes the rebound; later outward packets stay with this body.
            if (state.bonus_y != 0 or (state.momentum_spent_y and scroll_area.isOutwardAtBoundary(state, .vertical, 0, scroll.dy, ctx.scroll_speed))) return .stop;
        },
        .gesture => state.beginTouch(),
        .wheel => {},
    }
    if (scroll.dy != 0) {
        scroll_area.applyVerticalScroll(state, scroll.dy, ctx.scroll_speed, kind);
        state.input_serial +%= 1;
        state.onScrollActivityAxes(true, false);
        if (kind == .gesture) state.latched = true;
        if (kind == .momentum and state.bonus_y != 0) state.momentum_spent_y = true;
        const translate = state.contentTranslateY();
        if (translate != content.style.translate_y) {
            content.style.translate_y = translate;
            content.markCompositeAnimFrameDirty();
        }
    }
    return .stop;
}

const std = @import("std");
const a = std.testing.allocator;
const Fixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    outer: ui.widgets.ScrollAreaResult,
    inner: ui.widgets.ScrollAreaResult,
    fn init(content_height: f32) !Fixture {
        const cx = try ui.Cx.init(a, std.testing.io);
        errdefer cx.deinit();
        const scope = try ui.Scope.init(a, null, cx.owner);
        errdefer scope.dispose();
        cx.setViewport(460, 400);
        cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
        const outer = try ui.widgets.ScrollArea(.{ .height = 400 }).mount(scope, cx);
        try cx.root.?.appendChild(a, outer.container);
        const inner = try ui.widgets.ScrollArea(.{ .width = 360, .height = 150 }).mount(scope, cx);
        containVertical(inner);
        inner.container.setStyleInline(a, .{ .flex_shrink = 0 });
        try outer.content.appendChild(a, inner.container);
        try inner.content.appendChild(a, try ui.box(cx, .{ .width = .fill(), .height = .{ .px = content_height }, .flex_shrink = 0 }, .{}));
        try outer.content.appendChild(a, try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 1000 }, .flex_shrink = 0 }, .{}));
        var self = Fixture{ .cx = cx, .scope = scope, .outer = outer, .inner = inner };
        self.settle();
        return self;
    }
    fn settle(self: *Fixture) void {
        for (0..3) |_| {
            self.cx.advanceFrameClock();
            self.cx.layout();
            _ = self.cx.render();
        }
    }
    fn send(self: *Fixture, dx: f32, dy: f32, phase: ui.events.ScrollPhase, momentum: ui.events.MomentumPhase) void {
        self.cx.handleScroll(.{ .x = 30, .y = 50, .dx = dx, .dy = dy, .phase = phase, .momentum = momentum });
        self.settle();
    }
    fn deinit(self: *Fixture) void {
        self.scope.dispose();
        self.cx.deinit();
    }
};

test "PATCH card scroll contains wheel boundary crossings and leaves outside conversation input working" {
    var f = try Fixture.init(650);
    defer f.deinit();
    f.send(0, -35, .none, .none);
    try std.testing.expectEqual(@as(f32, 35), f.inner.state.scroll_y);
    try std.testing.expectEqual(@as(f32, 0), f.outer.state.scroll_y);
    f.send(0, -10000, .none, .none);
    try std.testing.expectEqual(f.inner.state.maxScrollY(), f.inner.state.scroll_y);
    f.send(0, -30, .none, .none);
    try std.testing.expectEqual(@as(f32, 0), f.outer.state.scroll_y);
    f.send(0, 10000, .none, .none);
    f.send(0, 30, .none, .none);
    try std.testing.expectEqual(@as(f32, 0), f.inner.state.scroll_y);
    try std.testing.expectEqual(@as(f32, 0), f.outer.state.scroll_y);
    f.cx.handleScroll(.{ .x = 430, .y = 50, .dx = 0, .dy = -45 });
    f.settle();
    try std.testing.expectEqual(@as(f32, 45), f.outer.state.scroll_y);
}

test "PATCH card scroll keeps native overflow thumbs visible after idle frames without inventing short-content bars" {
    var long = try Fixture.init(650);
    defer long.deinit();
    // No scroll or hover input: initial long cards must advertise overflow.
    for (0..180) |_| {
        long.cx.advanceFrameClock();
        long.cx.root.?.markRenderDirty();
        _ = long.cx.render();
    }
    const bar = long.inner.container.children.items[1];
    try std.testing.expect(bar.rectFromWorldOrFallback().w > 0);
    try std.testing.expect(bar.getBackground().a > 0);
    try std.testing.expect(long.inner.state.scrollbar_fade.opacity > 0);
    try std.testing.expectEqual(@as(f32, 0), long.outer.state.scrollbar_fade.opacity);

    const horizontal = try ui.widgets.ScrollArea(.{ .height = 40, .direction = .horizontal }).mount(long.scope, long.cx);
    showOverflowScrollbar(horizontal);
    horizontal.container.setStyleInline(a, .{ .position = .absolute, .width = .{ .px = 340 }, .inset = .{ .top = .{ .px = 0 } } });
    horizontal.content.setStyleInline(a, .{ .width = .{ .px = 1000 }, .height = .{ .px = 40 } });
    try long.inner.content.appendChild(a, horizontal.container);
    long.settle();
    for (0..180) |_| {
        long.cx.advanceFrameClock();
        long.cx.root.?.markRenderDirty();
        _ = long.cx.render();
    }
    const horizontal_bar = horizontal.container.children.items[2];
    try std.testing.expect(horizontal_bar.rectFromWorldOrFallback().h > 0);
    try std.testing.expect(horizontal_bar.getBackground().a > 0);
    horizontal.content.setStyleInline(a, .{ .width = .{ .px = 120 } });
    long.settle();
    try std.testing.expectEqual(@as(f32, 0), horizontal_bar.rectFromWorldOrFallback().w);
    try std.testing.expectEqual(@as(f32, 0), horizontal_bar.rectFromWorldOrFallback().h);

    var short = try Fixture.init(60);
    defer short.deinit();
    const absent = short.inner.container.children.items[1];
    try std.testing.expectEqual(@as(f32, 0), absent.rectFromWorldOrFallback().w);
    try std.testing.expectEqual(@as(f32, 0), absent.rectFromWorldOrFallback().h);
}

test "PATCH card scroll holds touch and momentum through both edges without waking the conversation" {
    var f = try Fixture.init(650);
    defer f.deinit();
    f.send(0, 0, .may_begin, .none);
    f.send(0, -35, .began, .none);
    f.send(0, -1000, .changed, .none);
    f.send(0, -40, .changed, .none);
    try std.testing.expect(f.inner.state.bonus_y > 0);
    try std.testing.expectEqual(@as(f32, 0), f.outer.state.scroll_y);
    f.send(0, 0, .ended, .none);
    f.send(0, -30, .none, .began);
    f.send(0, -15, .none, .changed);
    f.send(0, 0, .none, .ended);
    try std.testing.expect(!f.inner.state.touching and !f.inner.state.latched and !f.inner.state.momentum_active);
    try std.testing.expectEqual(@as(f32, 0), f.outer.state.scroll_y);
    f.send(0, 1000, .began, .none);
    f.send(0, 50, .changed, .none);
    f.send(0, 0, .cancelled, .none);
    try std.testing.expectEqual(@as(f32, 0), f.inner.state.scroll_y);
    try std.testing.expectEqual(@as(f32, 0), f.outer.state.scroll_y);
}

test "PATCH card scroll lets short bodies and vertical input over horizontal output reach their proper parent" {
    var short = try Fixture.init(60);
    defer short.deinit();
    short.send(0, -35, .none, .none);
    try std.testing.expectEqual(@as(f32, 0), short.inner.state.scroll_y);
    try std.testing.expectEqual(@as(f32, 35), short.outer.state.scroll_y);
    short.send(0, -35, .began, .none);
    short.send(0, -35, .changed, .none);
    short.send(0, 0, .ended, .none);
    try std.testing.expectEqual(@as(f32, 105), short.outer.state.scroll_y);

    var f = try Fixture.init(650);
    defer f.deinit();
    const horizontal = try ui.widgets.ScrollArea(.{ .height = 60, .direction = .horizontal, .rubber_band_x = false }).mount(f.scope, f.cx);
    horizontal.container.setStyleInline(a, .{ .position = .absolute, .inset = .{ .top = .{ .px = 0 }, .left = .{ .px = 0 } }, .width = .{ .px = 340 } });
    horizontal.content.setStyleInline(a, .{ .width = .{ .px = 1000 }, .height = .{ .px = 60 } });
    try f.inner.content.appendChild(a, horizontal.container);
    f.settle();
    f.send(-35, 0, .none, .none);
    try std.testing.expectEqual(@as(f32, 35), horizontal.state.scroll_x);
    try std.testing.expectEqual(@as(f32, 0), f.inner.state.scroll_y);
    f.send(0, -35, .none, .none);
    try std.testing.expectEqual(@as(f32, 35), f.inner.state.scroll_y);
    try std.testing.expectEqual(@as(f32, 0), f.outer.state.scroll_y);
    f.send(0, 35, .none, .none);
    f.send(0, 0, .began, .none);
    f.send(-35, 0, .changed, .none);
    f.send(0, 0, .ended, .none);
    f.send(-20, 0, .none, .began);
    f.send(-10, 0, .none, .changed);
    f.send(0, 0, .none, .ended);
    try std.testing.expect(horizontal.state.scroll_x > 70);
    try std.testing.expect(!horizontal.state.touching and !horizontal.state.latched and !horizontal.state.momentum_active);
    try std.testing.expectEqual(@as(f32, 0), f.inner.state.scroll_y);
    try std.testing.expectEqual(@as(f32, 0), f.outer.state.scroll_y);
}

test "PATCH card scroll gives the deepest overflowing approval viewport each delta once and lets short details reach the body" {
    var f = try Fixture.init(650);
    defer f.deinit();
    const deepest = try ui.widgets.ScrollArea(.{ .height = 60 }).mount(f.scope, f.cx);
    containVertical(deepest);
    deepest.container.setStyleInline(a, .{ .position = .absolute, .width = .{ .px = 340 }, .inset = .{ .top = .{ .px = 0 } } });
    const long_content = try ui.box(f.cx, .{ .width = .fill(), .height = .{ .px = 240 }, .flex_shrink = 0 }, .{});
    try deepest.content.appendChild(a, long_content);
    try f.inner.content.appendChild(a, deepest.container);
    f.settle();
    f.send(0, -170, .none, .none);
    try std.testing.expectEqual(@as(f32, 170), deepest.state.scroll_y);
    f.send(0, -25, .none, .none);
    try std.testing.expectEqual(deepest.state.maxScrollY(), deepest.state.scroll_y);
    try std.testing.expectEqual(@as(f32, 0), deepest.state.bonus_y);
    f.send(0, -30, .none, .none);
    try std.testing.expectEqual(@as(f32, 0), f.inner.state.scroll_y);
    try std.testing.expectEqual(@as(f32, 0), f.outer.state.scroll_y);
    f.send(0, 170, .none, .none);
    f.send(0, 0, .may_begin, .none);
    f.send(0, 0, .began, .none);
    f.send(0, -5, .changed, .none);
    try std.testing.expectEqual(@as(f32, 15), deepest.state.scroll_y);
    try std.testing.expectEqual(@as(f32, 0), f.inner.state.scroll_y);
    // The pointer leaves the deeper viewport, but the same gesture stays there.
    f.cx.handleScroll(.{ .x = 350, .y = 100, .dx = 0, .dy = -5, .phase = .changed });
    f.settle();
    try std.testing.expectEqual(@as(f32, 20), deepest.state.scroll_y);
    f.send(0, -200, .changed, .none);
    try std.testing.expect(deepest.state.bonus_y > 0);
    try std.testing.expect(deepest.state.bonus_y < 25); // only the 40pt remainder overshoots
    f.send(0, -30, .changed, .none);
    f.send(0, 0, .ended, .none);
    f.send(0, -20, .none, .began);
    f.send(0, 0, .none, .ended);
    try std.testing.expect(!deepest.state.touching and !deepest.state.latched and !deepest.state.momentum_active);
    try std.testing.expectEqual(@as(f32, 0), f.inner.state.scroll_y);
    try std.testing.expectEqual(@as(f32, 0), f.outer.state.scroll_y);
    long_content.setStyleInline(a, .{ .height = .{ .px = 30 } });
    f.settle();
    f.send(0, -35, .none, .none);
    try std.testing.expectEqual(@as(f32, 35), f.inner.state.scroll_y);
    try std.testing.expectEqual(@as(f32, 0), f.outer.state.scroll_y);
}
