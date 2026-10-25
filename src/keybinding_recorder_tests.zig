const std = @import("std");
const ui = @import("ui");
const recorder = @import("config/keybinding_picker.zig");
const keys = @import("config/keybindings.zig");
const Probe = struct {
    changes: usize = 0,
    dismissals: usize = 0,
    fn changed(raw: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        self.changes += 1;
    }
    fn dismissed(raw: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        self.dismissals += 1;
    }
};
test "V3 recorder individual tab keycap records only its action and preserves other shortcuts" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(500, 400);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    const anchor = try ui.box(cx, .{ .width = .{ .px = 60 }, .height = .{ .px = 24 } }, .{});
    try root.appendChild(cx.allocator, anchor);
    var map: keys.Map = .{};
    const before = map;
    var probe: Probe = .{};
    const callbacks: recorder.Callbacks = .{ .context = &probe, .changed = Probe.changed, .dismiss = Probe.dismissed };
    const picker = try recorder.mount(cx, scope, root, anchor, &map, "tab_3", callbacks);
    try root.appendChild(cx.allocator, picker.root);
    _ = cx.render();
    picker.focus();
    cx.handleKeyDown(.x, .{ .super = true, .shift = true });
    cx.handleKeyUp(.x, .{ .super = true, .shift = true });
    try std.testing.expectEqual(@as(usize, 0), probe.changes);
    try std.testing.expect(map.get(.tab_3).eql(before.get(.tab_3)));
    picker.confirm();
    try std.testing.expectEqual(@as(usize, 1), probe.changes);
    try std.testing.expectEqual(@as(usize, 1), probe.dismissals);
    try std.testing.expect(map.get(.tab_3).eql(.{ .key = .x, .command = true, .shift = true }));
    for (before.chords, 0..) |chord, index| if (index != @backingInt(keys.Action.tab_3)) try std.testing.expect(chord.eql(map.chords[index]));
    try std.testing.expectError(error.FixedMouseRow, recorder.mount(cx, scope, root, anchor, &map, "recent_tab", callbacks));
    try std.testing.expectError(error.FixedMouseRow, recorder.mount(cx, scope, root, anchor, &map, "accept_completion", callbacks));
}

test "V3 recorder rejects reserved and conflicting chords and cancels without touching draft" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 480);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    var map: keys.Map = .{};
    const before = map;
    var probe: Probe = .{};
    const picker = try recorder.mount(cx, scope, root, root, &map, "new_tab", .{ .context = &probe, .changed = Probe.changed, .dismiss = Probe.dismissed });
    try root.appendChild(cx.allocator, picker.root);
    _ = cx.render();
    picker.focus();
    cx.handleKeyDown(.x, .{ .ctrl = true, .super = true });
    try std.testing.expect(picker.invalid.peek());
    cx.handleKeyDown(.c, .{ .super = true });
    try std.testing.expect(picker.invalid.peek());
    picker.confirm();
    try std.testing.expectEqual(@as(usize, 0), probe.changes);
    cx.handleKeyDown(.x, .{ .super = true, .shift = true });
    try std.testing.expect(!picker.invalid.peek());
    cx.handleKeyDown(.escape, .{});
    try std.testing.expectEqual(@as(usize, 0), probe.changes);
    try std.testing.expectEqual(@as(usize, 1), probe.dismissals);
    for (before.chords, map.chords) |a, b| try std.testing.expect(a.eql(b));
    try std.testing.expect(!picker.open.peek());
}

fn tagged(node: *ui.Node, id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |test_id| if (std.mem.eql(u8, id, test_id)) return node;
    for (node.children.items) |child| if (tagged(child, id)) |found| return found;
    return null;
}
test "V3 recorder scrolls body while header and footer retain their size" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 240);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    var map: keys.Map = .{};
    var probe: Probe = .{};
    const picker = try recorder.mount(cx, scope, root, root, &map, "new_tab", .{ .context = &probe, .changed = Probe.changed, .dismiss = Probe.dismissed });
    try root.appendChild(cx.allocator, picker.root);
    _ = cx.render();
    const dialog = tagged(picker.root, "settings.keybinding.dialog").?.globalRect();
    const header = tagged(picker.root, "settings.keybinding.header").?.globalRect();
    const footer = tagged(picker.root, "settings.keybinding.footer").?.globalRect();
    const body = tagged(picker.root, "settings.keybinding.body").?.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 390), dialog.w, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 60), header.h, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 60), footer.h, 0.5);
    try std.testing.expect(dialog.h <= 192.5);
    try std.testing.expect(body.y >= header.y + header.h - 0.5);
    try std.testing.expect(body.y + body.h <= footer.y + 0.5);
}
