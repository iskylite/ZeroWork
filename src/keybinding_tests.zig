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
    const mounted = try picker.mount(cx, scope, root, anchor, &map, "搜索当前终端", .{ .context = &ctx, .changed = call, .dismiss = call });
    try root.appendChild(cx.allocator, mounted.root);
    try std.testing.expectError(error.FixedMouseRow, picker.mount(cx, scope, root, anchor, &map, "终端", .{ .context = &ctx, .changed = call, .dismiss = call }));
}
test "nine tab range and Control passthrough" {
    const map: keys.Map = .{};
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("⌘1 – ⌘9", try map.rowText("按序号直达", &buffer));
    try std.testing.expect(map.match(.tab, .{ .ctrl = true }) == null);
    try std.testing.expect(map.match(.c, .{ .ctrl = true }) == null);
}
test "Escape cancels whole multi-shortcut recording and complete row commits once" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const root = try ui.box(cx, .{}, .{});
    cx.root = root;
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    var map: keys.Map = .{};
    const original = map;
    var ctx: u8 = 0;
    const anchor = try ui.box(cx, .{}, .{});
    try root.appendChild(cx.allocator, anchor);
    const recorder = try picker.mount(cx, scope, root, anchor, &map, "新建 / 关闭", .{ .context = &ctx, .changed = call, .dismiss = call });
    try root.appendChild(cx.allocator, recorder.root);
    const handler = recorder.root.behavior.events.on_key_down.?;
    _ = handler(.e, .{ .super = true }, recorder.root.behavior.events.event_context);
    try std.testing.expectEqualDeep(original, map);
    _ = handler(.escape, .{}, recorder.root.behavior.events.event_context);
    try std.testing.expectEqualDeep(original, map);
    // A separate recording commits only after both keys have passed validation.
    const second = try picker.mount(cx, scope, root, anchor, &map, "新建 / 关闭", .{ .context = &ctx, .changed = call, .dismiss = call });
    try root.appendChild(cx.allocator, second.root);
    const handle = second.root.behavior.events.on_key_down.?;
    _ = handle(.e, .{ .super = true }, second.root.behavior.events.event_context);
    _ = handle(.o, .{ .super = true }, second.root.behavior.events.event_context);
    try std.testing.expectEqual(ui.events.KeyCode.e, map.get(.new_tab).key);
    try std.testing.expectEqual(ui.events.KeyCode.o, map.get(.close_tab).key);
}
