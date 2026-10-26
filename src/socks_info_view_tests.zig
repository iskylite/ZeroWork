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
    if (!view.portaled) try root.appendChild(cx.allocator, view.wrapper);
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

test "socks card follows the live trigger through resize without leaving the window" {
    var cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1600, 600);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    var sink = Sink{};
    const view = try view_mod.mount(cx, scope, .{ .context = @ptrCast(&sink), .action = action });
    if (!view.portaled) try root.appendChild(cx.allocator, view.wrapper);
    const chip = try ui.box(cx, .{ .position = .absolute, .inset = .{ .right = .{ .px = 220 }, .bottom = .{ .px = 12 } }, .width = .{ .px = 96 }, .height = .{ .px = 24 } }, .{});
    try root.appendChild(cx.allocator, chip);
    try view.update(.{ .state = .running, .host = "db" });
    view.showNode(chip);
    try cx.setTestFrameStep(100);
    for (0..10) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    const first = view.root.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 344), first.w, 0.01);
    try std.testing.expect(first.h >= 271 and first.h < 400);
    try std.testing.expect(view.footer.globalRect().y >= view.body.container.globalRect().y + view.body.container.globalRect().h);
    try std.testing.expectApproxEqAbs(@as(f32, 45), view.footer.globalRect().h, 0.01);
    try std.testing.expectEqual(ui.A11yRole.button, view.test_button.behavior.interaction.a11y.?.role);
    const first_anchor = chip.globalRect();
    try std.testing.expect(view.pointer.style.display == .none);
    try std.testing.expect(first.y + first.h <= 592.5);
    // Move the trigger; after-layout must recompute the popup position and
    // pointer offset from the node, rather than retaining the old snapshot.
    chip.style.ensureExtPanic(cx.allocator).inset.right = .{ .px = 40 };
    chip.markLayoutDirty();
    for (0..10) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    const second_anchor = chip.globalRect();
    const second = view.root.globalRect();
    try std.testing.expect(second_anchor.x > first_anchor.x + 100);
    // The card is intentionally lower-right anchored; its pointer is the
    // element that tracks a horizontally moving status chip.
    try std.testing.expect(second.x != first.x);
    try std.testing.expect(second.x >= 7.5 and second.x + second.w <= 1592.5);
}

test "socks card long endpoint and failure use scrollable content above fixed actions" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 480);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    var sink = Sink{};
    const view = try view_mod.mount(cx, scope, .{ .context = &sink, .action = action });
    if (!view.portaled) try cx.root.?.appendChild(cx.allocator, view.wrapper);
    try view.update(.{
        .mode = .local,
        .state = .failed,
        .target_host = "very-long-target-host-for-production-forwarding-diagnostics.example.internal.with-additional-routing-segments.example.internal",
        .target_port = 443,
        .error_text = "连接失败，请检查目标主机配置和当前链路。\n第一条诊断记录：此处保留完整错误原因。\n第二条诊断记录：此处保留下一步操作建议。\n第三条诊断记录：请重新连接后显式重试。",
    });
    view.show(.{ .x = 720, .y = 440, .w = 80, .h = 20 });
    try cx.setTestFrameStep(100);
    for (0..12) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
        _ = view.updateGeometry();
    }
    try std.testing.expect(view.address.globalRect().h > 32);
    try std.testing.expect(view.message.globalRect().h >= 64);
    const card = view.root.globalRect();
    const footer = view.footer.globalRect();
    try std.testing.expect(footer.y >= view.body.container.globalRect().y + view.body.container.globalRect().h - 0.5);
    try std.testing.expect(footer.y + footer.h <= card.y + card.h + 0.5);
    try std.testing.expect(card.y >= 7.5 and card.y + card.h <= 472.5);
}
