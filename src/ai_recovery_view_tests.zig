const std = @import("std");
const ui = @import("ui");
const V = @import("ui/ai_recovery_view.zig");
fn find(node: *ui.Node, id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, value, id)) return node;
    for (node.children.items) |child| if (find(child, id)) |value| return value;
    return null;
}
test "recovery buttons keep captured group and turn and disable IO actions during unknown or cooldown" {
    const Probe = struct {
        count: usize = 0,
        last: ?V.Envelope = null,
        fn enqueue(raw: *anyopaque, envelope: V.Envelope) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.count += 1;
            self.last = envelope;
        }
    };
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 358);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    var probe: Probe = .{};
    const root = try V.mount(cx, scope, .{ .ticket = .{ .owner = .{ .group = 7 }, .turn = 83 }, .reason = "远端写入结果待核实\nToolOutcomeUnknown", .has_tool_calls = true, .retries = 0, .max_retries = 3, .retry_enabled = false, .regenerate_enabled = false, .cooldown_seconds = 2 }, .{ .context = &probe, .enqueue = Probe.enqueue });
    try cx.root.?.appendChild(cx.allocator, root);
    cx.layout();
    const details = find(root, "ai.recovery.details").?;
    try std.testing.expectEqual(ui.types.Display.none, details.style.display);
    const summary = find(root, "ai.recovery.reason").?;
    try std.testing.expectEqualStrings("远端写入结果待核实", summary.getText().?.content);
    const toggle = find(root, "ai.recovery.details.toggle").?;
    toggle.behavior.events.on_click.?.invoke();
    cx.layout();
    try std.testing.expectEqual(ui.types.Display.flex, details.style.display);
    toggle.behavior.events.on_click.?.invoke();
    cx.layout();
    try std.testing.expectEqual(ui.types.Display.none, details.style.display);
    const retry = find(root, "ai.recovery.answer").?;
    const retry_label = retry.children.items[retry.children.items.len - 1];
    const retry_rect = retry.globalRect();
    const label_rect = retry_label.globalRect();
    try std.testing.expect(label_rect.x >= retry_rect.x);
    try std.testing.expect(label_rect.x + label_rect.w <= retry_rect.x + retry_rect.w);
    const edit = find(root, "ai.recovery.edit").?;
    const rect = edit.globalRect();
    cx.handleClick(rect.x + rect.w / 2, rect.y + rect.h / 2);
    try std.testing.expectEqual(@as(usize, 1), probe.count);
    try std.testing.expectEqual(@as(u64, 83), probe.last.?.ticket.turn);
    try std.testing.expectEqual(@as(u64, 7), probe.last.?.ticket.owner.group);
    try std.testing.expectEqual(V.Action.edit, probe.last.?.action);
    for ([_][]const u8{ "ai.recovery.answer", "ai.recovery.regenerate" }) |id| {
        const r = find(root, id).?.globalRect();
        cx.handleClick(r.x + r.w / 2, r.y + r.h / 2);
    }
    try std.testing.expectEqual(@as(usize, 1), probe.count);
}

test "PATCH recovery details keep an idle thumb and contain boundary input inside the conversation" {
    const a = std.testing.allocator;
    const reason = try std.mem.join(a, "\n", &@as([35][]const u8, @splat("HTTP failure detail retained for inspection")));
    defer a.free(reason);
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 400);
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    const outer = try ui.widgets.ScrollArea(.{ .width = 600, .height = 400 }).mount(scope, cx);
    cx.root = outer.container;
    const Ignore = struct {
        fn enqueue(_: *anyopaque, _: V.Envelope) void {}
    };
    const root = try V.mount(cx, scope, .{ .ticket = .{ .owner = .{ .session = 1 }, .turn = 1 }, .reason = reason, .retries = 0, .max_retries = 3, .retry_enabled = false, .regenerate_enabled = false, .cooldown_seconds = 0 }, .{ .context = cx, .enqueue = Ignore.enqueue });
    try outer.content.appendChild(a, root);
    try outer.content.appendChild(a, try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 800 }, .flex_shrink = 0 }, .{}));
    find(root, "ai.recovery.details.toggle").?.behavior.events.on_click.?.invoke();
    for (0..3) |_| {
        cx.layout();
        _ = cx.render();
    }
    const details = find(root, "ai.recovery.details").?;
    const rect = details.globalRect();
    try std.testing.expectEqual(@as(f32, 120), rect.h);
    const thumb = details.children.items[1];
    try std.testing.expect(thumb.rectFromWorldOrFallback().w > 0 and thumb.getBackground().a > 0);
    const ctx: *ui.widgets.scroll_area.ScrollEventCtx = @ptrCast(@alignCast(details.behavior.events.event_context.?));
    cx.handleScroll(.{ .x = rect.x + 30, .y = rect.y + rect.h / 2, .dx = 0, .dy = -100000 });
    cx.handleScroll(.{ .x = rect.x + 30, .y = rect.y + rect.h / 2, .dx = 0, .dy = -30 });
    try std.testing.expectEqual(ctx.state.maxScrollY(), ctx.state.scroll_y);
    try std.testing.expectEqual(@as(f32, 0), outer.state.scroll_y);
}
