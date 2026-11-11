const std = @import("std");
const ui = @import("ui");
const input = @import("ui/floating_input.zig");

const Fixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    background: *ui.Node,
    clicks: usize = 0,
    wheels: usize = 0,

    fn init() !*Fixture {
        const self = try std.testing.allocator.create(Fixture);
        const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
        errdefer cx.deinit();
        const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
        errdefer scope.dispose();
        cx.setViewport(1000, 700);
        cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
        const background = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .hit_roles = .{ .pointer = true, .scroll = true } }, .{});
        self.* = .{ .cx = cx, .scope = scope, .background = background };
        background.behavior.events.event_context = self;
        background.behavior.events.on_event = observe;
        try cx.root.?.appendChild(cx.allocator, background);
        try input.Policy.mount(cx, scope);
        return self;
    }
    fn deinit(self: *Fixture) void {
        self.scope.dispose();
        self.cx.deinit();
        std.testing.allocator.destroy(self);
    }
    fn observe(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        switch (event) {
            .mouse_down => self.clicks += 1,
            .scroll => self.wheels += 1,
            else => return .ignored,
        }
        return .handled;
    }
    fn frames(self: *Fixture) void {
        for (0..20) |_| {
            self.cx.frame_count += 1;
            self.cx.frame_time_ms += 16;
            _ = self.cx.render();
        }
    }
    fn click(self: *Fixture, x: f32, y: f32) void {
        self.cx.handleMouseDown(x, y, .{});
        self.cx.handleMouseUp(x, y);
    }
    fn wheel(self: *Fixture, x: f32, y: f32) void {
        self.cx.handleScroll(.{ .x = x, .y = y, .dx = 0, .dy = -24 });
    }
};

test "floating input scrollbar cursor follows real thumb drag and releases outside either axis" {
    const f = try Fixture.init();
    defer f.deinit();
    const scroll = try ui.widgets.ScrollArea(.{ .width = 300, .height = 200, .direction = .both }).mount(f.scope, f.cx);
    scroll.container.setStyleInline(f.cx.allocator, .{ .position = .absolute });
    scroll.content.setStyleInline(f.cx.allocator, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 }, .flex_shrink = 0 });
    try f.background.appendChild(f.cx.allocator, scroll.container);
    scroll.state.onScrollActivity();
    f.frames();
    for ([_]usize{ 1, 2 }) |index| {
        const thumb = scroll.container.children.items[index];
        const r = thumb.globalRect();
        try std.testing.expect(r.w > 0 and r.h > 0);
        const x = r.x + r.w / 2;
        const y = r.y + r.h / 2;
        f.cx.handleMouseMove(x, y);
        try std.testing.expectEqual(ui.CursorShape.grab, f.cx.current_cursor);
        f.cx.handleMouseDown(x, y, .{});
        f.cx.handleMouseMove(500, 400);
        try std.testing.expectEqual(ui.CursorShape.grabbing, f.cx.current_cursor);
        f.cx.handleMouseUp(500, 400);
        try std.testing.expectEqual(ui.CursorShape.default, f.cx.current_cursor);
        try std.testing.expect(!f.cx.dispatcher.hasPointerCapture());
        scroll.state.onScrollActivity();
        f.frames();
    }
    f.cx.handleMouseMove(40, 40);
    try std.testing.expect(f.cx.current_cursor != .grab);
}

test "floating input manual surface consumes blank clicks and wheels before its terminal ancestor" {
    const f = try Fixture.init();
    defer f.deinit();
    const card = try ui.box(f.cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = 100 }, .top = .{ .px = 100 } }, .width = .{ .px = 300 }, .height = .{ .px = 240 }, .z_index = 20 }, .{});
    input.protect(f.cx, card);
    try f.background.appendChild(f.cx.allocator, card);
    f.frames();
    f.click(120, 120);
    f.wheel(120, 120);
    try std.testing.expectEqual(@as(usize, 0), f.clicks);
    try std.testing.expectEqual(@as(usize, 0), f.wheels);
    f.click(30, 30);
    f.wheel(30, 30);
    try std.testing.expectEqual(@as(usize, 1), f.clicks);
    try std.testing.expectEqual(@as(usize, 1), f.wheels);
}

test "floating input popover preserves button input and inner scrolling without leaking from chrome" {
    const f = try Fixture.init();
    defer f.deinit();
    const open = try f.scope.createSignal(bool, true);
    const popup = try ui.widgets.Popover(.{ .open = open, .trigger = .manual, .width = @as(f32, 300), .max_height = @as(f32, 300), .position = .bottom_start, .enter_transition = .none, .exit_transition = .none, .close_on_outside_click = false }).mount(f.scope, f.cx);
    popup.trigger.setStyleInline(f.cx.allocator, .{ .width = .{ .px = 80 }, .height = .{ .px = 30 } });
    try f.cx.root.?.appendChild(f.cx.allocator, popup.wrapper);
    popup.content.setStyleInline(f.cx.allocator, .{ .padding = ui.Padding.all(12), .gap = 8 });
    var pressed: bool = false;
    const Click = struct {
        fn run(value: *bool) void {
            value.* = true;
        }
    };
    const button = try ui.widgets.Button(.{ .label = "Inside", .on_click = f.cx.on(bool, &pressed, Click.run) }).mount(f.scope, f.cx);
    try popup.content.appendChild(f.cx.allocator, button);
    const scroll = try ui.widgets.ScrollArea(.{ .height = @as(f32, 100), .direction = .vertical }).mount(f.scope, f.cx);
    scroll.container.setStyleInline(f.cx.allocator, .{ .width = .fill() });
    try scroll.content.appendChild(f.cx.allocator, try ui.box(f.cx, .{ .width = .fill(), .height = .{ .px = 500 } }, .{}));
    try popup.content.appendChild(f.cx.allocator, scroll.container);
    f.frames();
    const r = popup.chrome.globalRect();
    f.click(r.x + 5, r.y + 5);
    f.wheel(r.x + 5, r.y + 5);
    try std.testing.expectEqual(@as(usize, 0), f.clicks);
    try std.testing.expectEqual(@as(usize, 0), f.wheels);
    const b = button.globalRect();
    f.click(b.x + b.w / 2, b.y + b.h / 2);
    try std.testing.expect(pressed);
    const v = scroll.container.globalRect();
    f.wheel(v.x + v.w / 2, v.y + v.h / 2);
    try std.testing.expect(scroll.state.scroll_y > 0);
    try std.testing.expectEqual(@as(usize, 0), f.wheels);
}

test "floating input modal shields dialog and scrim including a previously captured trackpad gesture" {
    const f = try Fixture.init();
    defer f.deinit();
    const open = try f.scope.createSignal(bool, false);
    const modal = try ui.widgets.Modal(.{ .open = open, .width = @as(f32, 300), .max_height = @as(f32, 220), .enter_transition = .none, .exit_transition = .none, .close_on_overlay = false }).mount(f.scope, f.cx);
    if (!modal.portaled) try f.cx.root.?.appendChild(f.cx.allocator, modal.overlay);
    try modal.body.appendChild(f.cx.allocator, try ui.box(f.cx, .{ .width = .fill(), .height = .{ .px = 100 } }, .{}));
    f.frames();
    f.cx.handleScroll(.{ .x = 30, .y = 30, .dx = 0, .dy = -12, .phase = .began });
    try std.testing.expect(f.wheels > 0);
    open.set(true);
    f.frames();
    f.wheels = 0;
    const r = modal.dialog.globalRect();
    f.click(r.x + 12, r.y + 12);
    f.wheel(r.x + 12, r.y + 12);
    f.click(30, 30);
    f.cx.handleScroll(.{ .x = 30, .y = 30, .dx = 0, .dy = -12, .phase = .changed });
    f.cx.handleScroll(.{ .x = 30, .y = 30, .dx = 0, .dy = -12, .phase = .ended });
    f.cx.handleScroll(.{ .x = 30, .y = 30, .dx = 0, .dy = -12, .momentum = .changed });
    try std.testing.expectEqual(@as(usize, 0), f.clicks);
    try std.testing.expectEqual(@as(usize, 0), f.wheels);
}

test "scoped modal blocks only its owner, suspends on switch and leaves panel backdrop interactive" {
    const f = try Fixture.init();
    defer f.deinit();
    const cx = f.cx;
    const pane = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .left = .{ .px = 160 }, .top = .{ .px = 100 } },
        .width = .{ .px = 420 },
        .height = .{ .px = 350 },
        .hit_roles = .{ .pointer = true },
    }, .{});
    pane.setFocusable(true);
    const open = try f.scope.createSignal(bool, false);
    const modal = try ui.widgets.Modal(.{
        .open = open,
        .managed_focus = false,
        .width = 240,
        .enter_transition = .none,
        .exit_transition = .none,
    }).mount(f.scope, cx);
    const binding = try @import("ui/scoped_modal.zig").bind(cx, f.scope, modal, .{ .owner = .{ .node = pane } });
    try f.background.appendChild(cx.allocator, pane);
    const button = try ui.widgets.Button(.{ .label = "Cancel" }).mount(f.scope, cx);
    try modal.body.appendChild(cx.allocator, button);
    f.frames();
    cx.setFocus(pane);
    open.set(true);
    f.frames();

    try std.testing.expectEqual(pane.globalRect(), modal.overlay.globalRect());
    try std.testing.expect(cx.focus_manager.getFocused().?.isDescendantOf(modal.dialog));
    try std.testing.expect(!cx.overlay_stack.allowsSemanticAction(pane));
    try std.testing.expect(cx.overlay_stack.allowsSemanticAction(f.background));
    cx.setFocus(pane);
    try std.testing.expect(cx.focus_manager.getFocused() != pane);
    f.wheel(170, 110);
    try std.testing.expectEqual(@as(usize, 0), f.wheels);
    f.click(750, 120);
    f.wheel(750, 120);
    try std.testing.expectEqual(@as(usize, 1), f.clicks);
    try std.testing.expectEqual(@as(usize, 1), f.wheels);
    try std.testing.expect(open.peek());
    cx.handleKeyDown(.escape, .{});
    try std.testing.expect(open.peek());

    pane.setDisplay(.none);
    f.frames();
    try std.testing.expectEqual(@TypeOf(modal.overlay.style.display).none, modal.overlay.style.display);
    try std.testing.expect(open.peek());
    pane.setDisplay(.flex);
    f.frames();
    try std.testing.expectEqual(pane.globalRect(), modal.overlay.globalRect());

    cx.detachChildRetained(f.background, pane);
    f.frames();
    try std.testing.expect(!modal.overlay.isDisplayedInTree());
    try f.background.appendChild(cx.allocator, pane);
    f.frames();
    try std.testing.expectEqual(pane.globalRect(), modal.overlay.globalRect());

    binding.setMode(.panel);
    f.frames();
    f.wheel(170, 110);
    try std.testing.expectEqual(@as(usize, 2), f.wheels);
    try std.testing.expect(cx.overlay_stack.allowsSemanticAction(pane));
    cx.setFocus(button);
    cx.handleKeyDown(.escape, .{});
    f.frames();
    try std.testing.expect(!open.peek());
    try std.testing.expectEqual(@as(usize, 0), cx.focus_manager.scope_count);
}

test "floating input display only Tooltip drag ghosts and FPS remain pass through on reopen" {
    const f = try Fixture.init();
    defer f.deinit();
    const open = try f.scope.createSignal(bool, true);
    const tip = try ui.widgets.Tooltip(.{ .text = "Passive", .open = open, .open_delay_ms = @as(f32, 0), .position = .bottom }).mount(f.scope, f.cx);
    tip.trigger.setStyleInline(f.cx.allocator, .{ .width = .{ .px = 80 }, .height = .{ .px = 30 } });
    try f.cx.root.?.appendChild(f.cx.allocator, tip.wrapper);
    for (0..2) |_| {
        f.frames();
        const r = tip.content.globalRect();
        try std.testing.expect(r.w > 0 and r.h > 0);
        const before_clicks = f.clicks;
        const before_wheels = f.wheels;
        f.click(r.x + r.w / 2, r.y + r.h / 2);
        f.wheel(r.x + r.w / 2, r.y + r.h / 2);
        try std.testing.expectEqual(before_clicks + 1, f.clicks);
        try std.testing.expectEqual(before_wheels + 1, f.wheels);
        open.set(false);
        f.frames();
        open.set(true);
    }
    for ([_]ui.BoxStyle{
        @import("ui/file_workspace_styles.zig").dragGhost(),
        @import("ui/file_workspace_styles.zig").dragPreview(undefined),
        @import("plugins/bmc_ikvm/styles.zig").fpsHud(undefined),
    }) |style| {
        const node = try ui.box(f.cx, style, .{});
        defer f.cx.destroyDetached(node);
        input.protect(f.cx, node);
        try std.testing.expectEqual(.pass_through, node.style.hit_behavior().?);
        try std.testing.expect(node.behavior.events.on_scroll == null);
        try std.testing.expect(node.behavior.events.on_event == null);
    }
}

const Surface = @import("ui/floating_surface.zig").Surface;
const FloatingCounters = struct {
    clicks: usize = 0,
    captures: usize = 0,
    buttons: usize = 0,
    fn capture(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        if (event == .mouse_down) self.captures += 1;
        return .ignored;
    }
    fn clicked(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        if (event == .click) self.clicks += 1;
        return .stop;
    }
    fn button(self: *@This()) void {
        self.buttons += 1;
    }
};
fn floatingCard(f: *Fixture, left: f32, top: f32, counter: *FloatingCounters) !*ui.Node {
    const card = try ui.box(f.cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = left }, .top = .{ .px = top } }, .width = .{ .px = 320 }, .height = .{ .px = 260 }, .hit_behavior = .@"opaque" }, .{});
    card.behavior.events.on_event_capture = FloatingCounters.capture;
    card.behavior.events.capture_context = counter;
    card.behavior.events.on_event = FloatingCounters.clicked;
    card.behavior.events.event_context = counter;
    input.protect(f.cx, card);
    const button = try ui.widgets.Button(.{ .label = "Child", .on_click = f.cx.on(FloatingCounters, counter, FloatingCounters.button), .base_style = ui.BoxStyle{ .width = .{ .px = 80 }, .height = .{ .px = 30 } } }).mount(f.scope, f.cx);
    try card.appendChild(f.cx.allocator, button);
    try f.background.appendChild(f.cx.allocator, card);
    return card;
}

test "floating surfaces activate on open and child press with matching paint and hit order" {
    const f = try Fixture.init();
    defer f.deinit();
    var first: FloatingCounters = .{};
    var second: FloatingCounters = .{};
    const one = try floatingCard(f, 80, 80, &first);
    _ = try Surface.mount(f.cx, f.scope, one);
    const two = try floatingCard(f, 220, 130, &second);
    const second_surface = try Surface.mount(f.cx, f.scope, two);
    two.setDisplay(.none);
    f.frames();
    two.setDisplay(.flex);
    f.frames();
    try std.testing.expect(two.style.z_index() > one.style.z_index());
    f.click(300, 230);
    try std.testing.expectEqual(@as(usize, 1), second.clicks);
    // The child consumes its own click. The surface must still activate before it.
    f.click(100, 95);
    f.frames();
    try std.testing.expectEqual(@as(usize, 1), first.buttons);
    try std.testing.expectEqual(@as(usize, 1), first.captures);
    try std.testing.expect(one.style.z_index() > two.style.z_index());
    const first_before = first.clicks;
    const second_before = second.clicks;
    f.click(300, 230);
    try std.testing.expectEqual(first_before + 1, first.clicks);
    try std.testing.expectEqual(second_before, second.clicks);
    // Clicking the toolbar for an already visible surface uses the same activation.
    second_surface.activate();
    f.frames();
    f.click(300, 230);
    try std.testing.expectEqual(second_before + 1, second.clicks);
    try std.testing.expectEqual(@as(usize, 0), f.clicks);
}

test "floating surfaces preserve reopen ordering bounded priority and modal shielding" {
    const f = try Fixture.init();
    defer f.deinit();
    var counters: FloatingCounters = .{};
    const one = try floatingCard(f, 80, 80, &counters);
    const first = try Surface.mount(f.cx, f.scope, one);
    const two = try floatingCard(f, 220, 130, &counters);
    const second = try Surface.mount(f.cx, f.scope, two);
    f.frames();
    for (0..1000) |_| {
        first.activate();
        second.activate();
    }
    try std.testing.expectEqual(@as(i16, 200), one.style.z_index());
    try std.testing.expectEqual(@as(i16, 201), two.style.z_index());
    two.setDisplay(.none);
    f.frames();
    first.activate();
    two.setDisplay(.flex);
    f.frames();
    try std.testing.expect(two.style.z_index() > one.style.z_index());
    const open = try f.scope.createSignal(bool, true);
    const modal = try ui.widgets.Modal(.{ .open = open, .width = @as(f32, 420), .enter_transition = .none, .exit_transition = .none }).mount(f.scope, f.cx);
    if (!modal.portaled) try f.cx.root.?.appendChild(f.cx.allocator, modal.overlay);
    f.frames();
    first.activate();
    f.frames();
    const before = counters.clicks;
    const rect = modal.dialog.globalRect();
    f.click(rect.x + rect.w / 2, rect.y + rect.h / 2);
    try std.testing.expectEqual(before, counters.clicks);
    try std.testing.expectEqual(@as(usize, 0), f.clicks);
}

test "floating surface wrapper keeps empty space pass through and popovers above its content" {
    const f = try Fixture.init();
    defer f.deinit();
    const wrapper = try ui.box(f.cx, .{ .position = .absolute, .inset = .{ .top = .{ .px = 80 } }, .width = .fill(), .direction = .row, .justify = .center, .hit_roles = .{ .pointer = false, .scroll = false } }, .{});
    try f.background.appendChild(f.cx.allocator, wrapper);
    _ = try Surface.mount(f.cx, f.scope, wrapper);
    const card = try ui.box(f.cx, .{ .width = .{ .px = 320 }, .height = .{ .px = 260 }, .hit_behavior = .@"opaque" }, .{});
    input.protect(f.cx, card);
    try wrapper.appendChild(f.cx.allocator, card);
    const open = try f.scope.createSignal(bool, false);
    const popup = try ui.widgets.Popover(.{ .open = open, .trigger = .manual, .width = @as(f32, 260), .position = .bottom_start, .enter_transition = .none, .exit_transition = .none }).mount(f.scope, f.cx);
    try card.appendChild(f.cx.allocator, popup.wrapper);
    popup.trigger.setStyleInline(f.cx.allocator, .{ .width = .{ .px = 80 }, .height = .{ .px = 30 } });
    try popup.content.appendChild(f.cx.allocator, try ui.text(f.cx, "Owned bubble", .{}));
    f.frames();
    f.click(30, 100);
    try std.testing.expectEqual(@as(usize, 1), f.clicks);
    open.set(true);
    f.frames();
    const rect = popup.chrome.globalRect();
    const before = f.clicks;
    f.click(rect.x + rect.w / 2, rect.y + rect.h / 2);
    try std.testing.expect(open.peek());
    try std.testing.expectEqual(before, f.clicks);
}
