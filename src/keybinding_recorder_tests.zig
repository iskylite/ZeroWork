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
test "individual tab keycap records only its action and preserves other shortcuts" {
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
    try std.testing.expectEqual(@as(usize, 1), probe.changes);
    try std.testing.expectEqual(@as(usize, 1), probe.dismissals);
    try std.testing.expect(map.get(.tab_3).eql(.{ .key = .x, .command = true, .shift = true }));
    for (before.chords, 0..) |chord, index| if (index != @backingInt(keys.Action.tab_3)) try std.testing.expect(chord.eql(map.chords[index]));
    try std.testing.expectError(error.FixedMouseRow, recorder.mount(cx, scope, root, anchor, &map, "recent_tab", callbacks));
    try std.testing.expectError(error.FixedMouseRow, recorder.mount(cx, scope, root, anchor, &map, "accept_completion", callbacks));
}
