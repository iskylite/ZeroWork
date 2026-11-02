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
