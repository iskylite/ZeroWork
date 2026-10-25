const std = @import("std");
const ui = @import("ui");
const Broadcast = @import("ui/broadcast_view.zig");
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
    fn init(self: *Fixture) !void {
        self.* = .{ .cx = try ui.Cx.init(a, std.testing.io), .scope = undefined, .anchor = undefined, .view = undefined };
        try self.cx.setTestFrameStep(100);
        self.cx.setViewport(1440, 900);
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill() }, .{});
        self.scope = try ui.Scope.init(a, null, self.cx.owner);
        self.anchor = try ui.widgets.Button(.{ .label = "广播", .variant = .ghost }).mount(self.scope, self.cx);
        self.anchor.setStyleInline(a, .{ .position = .absolute, .inset = .{ .left = .{ .px = 1060 }, .top = .{ .px = 850 } }, .width = .{ .px = 86 }, .height = .{ .px = 26 } });
        try self.cx.root.?.appendChild(a, self.anchor);
        self.view = try Broadcast.View.mount(self.cx, self.scope, .{ .context = self, .resolve = resolve, .select = select });
        self.frame();
    }
    fn deinit(self: *Fixture) void {
        self.cx.setFocus(null);
        self.scope.dispose();
        self.cx.deinit();
    }
    fn frame(self: *Fixture) void {
        for (0..10) |_| {
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
    try std.testing.expectEqualStrings("copied-member", f.view.current.?.snapshot.members[0].name);
    const check = find(f.cx.root.?, "group.broadcast.member.2.select").?;
    const rect = check.globalRect();
    f.cx.handleClick(rect.x + rect.w / 2, rect.y + rect.h / 2);
    f.cx.handleMouseUp(rect.x + rect.w / 2, rect.y + rect.h / 2);
    f.frame();
    try std.testing.expectEqual(@as(usize, 1), f.selects);
    try std.testing.expect(!f.selected);
    const source = find(f.cx.root.?, "group.broadcast.member.1.select").?;
    try std.testing.expect(source.behavior.interaction.a11y.?.disabled);
    try f.show(1);
    try std.testing.expect(f.view.disabled.peek());
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
