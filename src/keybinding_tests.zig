const std = @import("std");
const keys = @import("config/keybindings.zig");
const picker = @import("config/keybinding_picker.zig");
const ui = @import("ui");
fn call(_: *anyopaque) void {}
test "keybinding roundtrip conflicts and remote reservation" {
    var map: keys.Map = .{};
    try map.set(.search, .{ .key = .e });
    try std.testing.expectError(error.Conflict, map.set(.ai, .{ .key = .e }));
    try std.testing.expectError(error.RemoteKeyReserved, map.set(.search, .{ .key = .tab }));
    try std.testing.expectError(error.RemoteKeyReserved, map.set(.search, .{ .key = .l, .command = false, .control = true }));
    var buffer: [4096]u8 = undefined;
    const next = try keys.Map.parse(try map.format(&buffer));
    try std.testing.expectEqualDeep(map, next);
    map.reset();
    try std.testing.expectEqual(keys.Action.search, map.match(.f, .{ .super = true }).?);
}
test "recording mounts with owned map and fixed mouse stays immutable" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const root = try ui.box(cx, .{}, .{});
    cx.root = root;
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    var map: keys.Map = .{};
    var ctx: u8 = 0;
    const anchor = try ui.box(cx, .{}, .{});
    try root.appendChild(cx.allocator, anchor);
    const mounted = try picker.mount(cx, scope, root, anchor, &map, "search", .{ .context = &ctx, .changed = call, .dismiss = call });
    try root.appendChild(cx.allocator, mounted.root);
    try std.testing.expectError(error.FixedMouseRow, picker.mount(cx, scope, root, anchor, &map, "recent_tab", .{ .context = &ctx, .changed = call, .dismiss = call }));
}
test "nine tab range and Control passthrough" {
    const map: keys.Map = .{};
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("⌘1 – ⌘9", try map.rowText("按序号直达", &buffer));
    try std.testing.expect(map.match(.tab, .{ .ctrl = true }) == null);
    try std.testing.expect(map.match(.c, .{ .ctrl = true }) == null);
}
test "V3 recorder Escape discards one action and explicit confirmation commits only that action" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 480);
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    var map: keys.Map = .{};
    const original = map;
    var ctx: u8 = 0;
    const anchor = try ui.box(cx, .{}, .{});
    try root.appendChild(cx.allocator, anchor);
    const recorder = try picker.mount(cx, scope, root, anchor, &map, "new_tab", .{ .context = &ctx, .changed = call, .dismiss = call });
    try root.appendChild(cx.allocator, recorder.root);
    cx.frame_count += 1;
    cx.frame_time_ms += 16;
    _ = cx.render();
    recorder.focus();
    cx.handleKeyDown(.e, .{ .super = true });
    cx.handleKeyUp(.e, .{ .super = true });
    try std.testing.expectEqualDeep(original, map);
    cx.handleKeyDown(.escape, .{});
    cx.handleKeyUp(.escape, .{});
    try std.testing.expectEqualDeep(original, map);
    try std.testing.expect(!recorder.open.peek());
    cx.frame_count += 1;
    cx.frame_time_ms += 16;
    _ = cx.render();
    // Each action has its own candidate; recording alone never commits it.
    const second = try picker.mount(cx, scope, root, anchor, &map, "new_tab", .{ .context = &ctx, .changed = call, .dismiss = call });
    try root.appendChild(cx.allocator, second.root);
    cx.frame_count += 1;
    cx.frame_time_ms += 16;
    _ = cx.render();
    second.focus();
    cx.handleKeyDown(.e, .{ .super = true });
    cx.handleKeyUp(.e, .{ .super = true });
    try std.testing.expectEqualDeep(original, map);
    second.confirm();
    try std.testing.expectEqual(keys.KeyCode.e, map.get(.new_tab).key);
    for (original.chords, 0..) |chord, index| if (index != @backingInt(keys.Action.new_tab)) try std.testing.expect(chord.eql(map.chords[index]));
}
