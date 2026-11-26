const std = @import("std");
const ui = @import("ui");
const Broadcast = @import("ui/broadcast_view.zig");
const Mascot = @import("ui/mascot_island.zig");
const Handle = @import("host/identity.zig").SessionHandle;
const a = std.testing.allocator;
fn find(root: *ui.Node, id: []const u8) ?*ui.Node {
    if (root.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, value, id)) return root;
    for (root.children.items) |child| if (find(child, id)) |node| return node;
    return null;
}
const Fixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    anchor: *ui.Node,
    view: *Broadcast.View,
    selects: usize = 0,
    selected: bool = true,
    accepted: usize = 0,
    mascot: ?*Mascot.View = null,
    fn init(self: *Fixture) !void {
        return self.initDocked(false);
    }
    fn initDocked(self: *Fixture, docked: bool) !void {
        self.* = .{ .cx = try ui.Cx.init(a, std.testing.io), .scope = undefined, .anchor = undefined, .view = undefined };
        try self.cx.setTestFrameStep(100);
        self.cx.setViewport(1440, 900);
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill() }, .{});
        self.scope = try ui.Scope.init(a, null, self.cx.owner);
        self.anchor = try ui.widgets.Button(.{ .label = "广播", .variant = .ghost }).mount(self.scope, self.cx);
        self.anchor.setStyleInline(a, .{ .position = .absolute, .inset = .{ .left = .{ .px = 1060 }, .top = .{ .px = 850 } }, .width = .{ .px = 86 }, .height = .{ .px = 26 } });
        try self.cx.root.?.appendChild(a, self.anchor);
        if (docked) {
            const hooks = struct {
                fn save(_: *anyopaque, _: f32, _: f32) void {}
                fn noop(_: *anyopaque, _: Mascot.Slot) void {}
                fn panel(raw: *anyopaque, slot: Mascot.Slot) ?*ui.Node {
                    const f: *Fixture = @ptrCast(@alignCast(raw));
                    return if (slot == .broadcast and (f.view.open.peek() or f.view.requested)) f.view.chrome else null;
                }
            };
            const m = try Mascot.View.mount(self.cx, self.scope, self.cx.root.?, .{ .context = self, .save_anchor = hooks.save, .open_preview = hooks.noop, .close_preview = hooks.noop, .panel = hooks.panel, .pin_preview = hooks.noop }, 1, 1);
            m.setActivity(.{ .forward_available = true, .chain_available = true, .history_available = true, .broadcast_available = true });
            m.expanded = true;
            m.pinned = true;
            self.mascot = m;
            self.anchor = m.slot(.broadcast);
        }
        self.view = try Broadcast.View.mountDocked(self.cx, self.scope, .{ .context = self, .resolve = resolve, .select = select }, self.mascot);
        if (self.mascot) |m| self.cx.focus_manager.setFocusWithReason(m.grab, .tab);
        self.frame();
    }
    fn deinit(self: *Fixture) void {
        self.cx.setFocus(null);
        self.scope.dispose();
        self.cx.deinit();
    }
    fn frame(self: *Fixture) void {
        for (0..10) |_| {
            self.cx.requestRedraw();
            self.cx.advanceFrameClock();
            self.cx.layout();
            _ = self.cx.render();
        }
    }
    fn resolve(raw: *anyopaque, _: u32, accepted: bool) void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (accepted) self.accepted += 1;
    }
    fn select(raw: *anyopaque, _: u32, owner: Handle, selected: bool) void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        std.debug.assert(@backingInt(owner.session_id) == 2);
        self.selects += 1;
        self.selected = selected;
    }
    fn show(self: *Fixture, count: usize) !void {
        const members = try a.alloc(Broadcast.Member, count);
        defer a.free(members);
        var name = "copied-member".*;
        for (members, 0..) |*member, i| member.* = .{ .id = i + 1, .owner = .{ .session_id = @fromBackingInt(i + 1) }, .name = &name, .endpoint = "local · zsh", .source = i == 0, .selected = true, .available = true };
        try self.view.show(.{ .group = 7, .name = "acceptance", .running = false, .can_enable = count > 1, .members = members }, self.anchor);
        @memset(&name, 'x');
        self.frame();
    }
};
test "broadcast view owns member text and selects only an enabled recipient through actual pointer" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.show(2);
    try std.testing.expectEqualStrings("", f.view.minimum.getText().?.content);
    try std.testing.expectEqualStrings("copied-member", f.view.current.?.snapshot.members[0].name);
    const check = find(f.cx.root.?, "group.broadcast.member.2.select").?;
    const rect = check.globalRect();
    f.cx.handleClick(rect.x + rect.w / 2, rect.y + rect.h / 2);
    f.cx.handleMouseUp(rect.x + rect.w / 2, rect.y + rect.h / 2);
    f.frame();
    try std.testing.expectEqual(@as(usize, 1), f.selects);
    try std.testing.expect(!f.selected);
    const source = find(f.cx.root.?, "group.broadcast.member.1.select").?;
    try std.testing.expect(!source.behavior.interaction.a11y.?.disabled);
    try f.show(1);
    try std.testing.expect(f.view.disabled.peek());
    try std.testing.expectEqualStrings("没有在线可写会话", f.view.minimum.getText().?.content);
}
test "broadcast view follows its actual anchor through resize and closes when the trigger disappears" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.show(12);
    f.cx.setViewport(860, 480);
    f.anchor.setStyleInline(a, .{ .inset = .{ .left = .{ .px = 560 }, .top = .{ .px = 438 } } });
    f.frame();
    const card = f.view.root.globalRect();
    const footer = find(f.cx.root.?, "group.broadcast.footer").?.globalRect();
    try std.testing.expect(card.x >= 0 and card.y >= 0 and card.x + card.w <= 860 and card.y + card.h <= 480);
    try std.testing.expect(footer.y >= card.y and footer.y + footer.h <= card.y + card.h + 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 560), f.view.anchor_rect.x, 0.5);
    f.anchor.setStyleInline(a, .{ .inset = .{ .left = .{ .px = 300 }, .top = .{ .px = 438 } } });
    f.frame();
    try std.testing.expectApproxEqAbs(@as(f32, 300), f.view.anchor_rect.x, 0.5);
    f.anchor.setDisplay(.none);
    f.frame();
    try std.testing.expect(!f.view.open.peek());
}
test {
    _ = @import("ui/broadcast_controller.zig");
}

test "retained broadcast_view_tests paint matches a fresh mount in every builtin theme without a new decision" {
    const theme = @import("ui/app_theme.zig");
    const support = @import("ui_theme_test_support.zig");
    const previous = theme.currentName();
    defer theme.select(previous);
    theme.select(.dark);
    var retained: Fixture = undefined;
    try retained.init();
    defer retained.deinit();
    try retained.show(3);
    for (@import("config/theme_presets.zig").ids) |id| {
        theme.selectTokens(@import("config/theme_registry.zig").builtinTokens(id));
        try support.publish(retained.cx, retained.scope);
        for (0..6) |_| retained.frame();
        var fresh: Fixture = undefined;
        try fresh.init();
        defer fresh.deinit();
        try support.publish(fresh.cx, fresh.scope);
        try fresh.show(3);
        for (0..6) |_| fresh.frame();
        errdefer std.debug.print("theme={s}\n", .{id});
        try support.expectPaintEqual(retained.view.root, fresh.view.root);
    }
}

test "mascot broadcast remains actionable on each side of the function rail" {
    var f: Fixture = undefined;
    try f.initDocked(true);
    defer f.deinit();
    const m = f.mascot.?;
    try f.show(2);
    for ([_]f32{ 1, 0 }) |side| {
        m.anchor_x = side;
        f.frame();
        const rail = m.toolFootprint().?.bounds;
        const panel = f.view.chrome.globalRect();
        try std.testing.expect(f.view.open.peek() and f.view.chrome.getOpacity() >= 0.99);
        if (side == 1) try std.testing.expect(panel.x + panel.w + 11.9 < rail.x) else try std.testing.expect(panel.x >= rail.x + rail.w + 11.9);
    }
    const control = f.view.control.globalRect();
    f.cx.handleClick(control.x + control.w / 2, control.y + control.h / 2);
    try std.testing.expectEqual(@as(usize, 1), f.accepted);
}
