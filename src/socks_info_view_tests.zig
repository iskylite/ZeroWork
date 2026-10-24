const std = @import("std");
const ui = @import("ui");
const view_mod = @import("ui/socks_info_view.zig");

const Sink = struct { actions: usize = 0, last: ?view_mod.Action = null };
fn action(raw: *anyopaque, a: view_mod.Action) void {
    const s: *Sink = @ptrCast(@alignCast(raw));
    s.actions += 1;
    s.last = a;
}

test "socks card mounts hidden, copies live values and dispatches actions" {
    var cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1280, 720);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    var sink = Sink{};
    const view = try view_mod.mount(cx, scope, .{ .context = @ptrCast(&sink), .action = action });
    try root.appendChild(cx.allocator, view.root);
    try std.testing.expect(view.root.style.display == .none);
    try view.update(.{ .state = .running, .port = 1081, .bind = "127.0.0.1", .host = "db", .exit = "db", .session_id = 201, .route = "via jump", .connections = 2, .uploaded = 1024 });
    try std.testing.expectEqualStrings("归属 db #201 ·", view.owner.getText().?.content);
    view.show(.{ .x = 1180, .y = 670, .w = 80, .h = 20 });
    cx.layout();
    _ = view.updateGeometry();
    try std.testing.expect(view.root.style.display == .flex);
    view.dispatch(.test_proxy);
    try std.testing.expectEqual(@as(usize, 1), sink.actions);
    try std.testing.expectEqual(view_mod.Action.test_proxy, sink.last.?);
    view.dispatch(.stop);
    try std.testing.expectEqual(view_mod.Action.stop, sink.last.?);
}

test "socks card follows trigger node and keeps pointer aligned after resize" {
    var cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1600, 600);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    var sink = Sink{};
    const view = try view_mod.mount(cx, scope, .{ .context = @ptrCast(&sink), .action = action });
    try root.appendChild(cx.allocator, view.root);
    const chip = try ui.box(cx, .{ .position = .absolute, .inset = .{ .right = .{ .px = 220 }, .bottom = .{ .px = 12 } }, .width = .{ .px = 96 }, .height = .{ .px = 24 } }, .{});
    try root.appendChild(cx.allocator, chip);
    try view.update(.{ .state = .running, .host = "db" });
    view.showNode(chip);
    for (0..3) |_| {
        cx.frame_count += 1;
        _ = cx.render();
    }
    const first = view.root.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 360), first.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 212), first.h, 0.01);
    try std.testing.expectApproxEqAbs(first.y + 164, view.footer.globalRect().y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 30), view.footer.globalRect().h, 0.01);
    try std.testing.expectEqual(ui.A11yRole.button, view.test_button.behavior.interaction.a11y.?.role);
    const first_anchor = chip.globalRect();
    const first_pointer = view.pointer.globalRect();
    try std.testing.expect(first.y + first.h <= 592.5);
    // Move the trigger; after-layout must recompute the popup position and
    // pointer offset from the node, rather than retaining the old snapshot.
    chip.style.ensureExtPanic(cx.allocator).inset.right = .{ .px = 40 };
    chip.markLayoutDirty();
    cx.frame_count += 1;
    _ = cx.render();
    const second_anchor = chip.globalRect();
    const second = view.root.globalRect();
    try std.testing.expect(second_anchor.x > first_anchor.x + 100);
    // The card is intentionally lower-right anchored; its pointer is the
    // element that tracks a horizontally moving status chip.
    try std.testing.expect(view.pointer.globalRect().x != first_pointer.x);
    try std.testing.expect(second.x >= 7.5 and second.x + second.w <= 1592.5);
}
