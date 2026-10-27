const std = @import("std");
const ui = @import("ui");
const host = @import("host/notification_host.zig");
const Presenter = @import("ui/notification_presenter.zig").Presenter;
const a = std.testing.allocator;

test "notification presenter bounds longest admitted content and all actions at minimum window" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 480);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    var notice_host: host.Host = .{ .allocator = a, .driver = undefined, .coordinator = try host.notifications.Coordinator.init(a, .{}, .{}) };
    defer notice_host.coordinator.deinit();
    try notice_host.coordinator.registerDefinition(.{ .id = "audit.feedback", .category = .operation_result, .default_channels = .{ .system = false, .attention = false } });
    const view = try Presenter.mount(cx, scope, &notice_host, @fromBackingInt(1));
    const owner: host.ContentOwner = .{ .session = .{ .session_id = @fromBackingInt(1) } };
    var detail = cycled("long detail content with words and spaces ", 4096);
    @memset(detail[0..512], 'x'); // A long unbroken path/token must also wrap.
    const action_label = cycled("long action label with spaces ", 128);
    for (0..3) |index| {
        _ = try notice_host.coordinator.publishNotification(.{ .definition_id = "audit.feedback", .owner = .{ .window_id = 1, .content = owner }, .operation_id = index + 1, .event_revision = 1, .phase = .failed, .severity = .failure, .title = &cycled("Longest admitted title ", 256), .detail = &detail, .actions = &.{ .{ .kind = .view_result, .label = &action_label }, .{ .kind = .view_result, .label = &action_label }, .{ .kind = .view_result, .label = &action_label } } }, .{ .monotonic_ms = 1, .local_minute = 0 });
    }
    for (0..8) |_| {
        try view.update(1, true, owner, .{ .content = .{ .x = 0, .y = 0, .w = 860, .h = 480 } });
        cx.layout();
    }
    const rect = view.root.globalRect();

    try std.testing.expectEqual(@as(f32, 62), rect.y);
    try std.testing.expect(rect.y + rect.h <= 480);
    try std.testing.expect(view.content.globalRect().h > view.viewport.globalRect().h);
    for (view.slots) |slot| {
        const card = slot.root.globalRect();
        for (slot.actions) |action| {
            const button = action.root.globalRect();
            const label = action.label.globalRect();
            try std.testing.expect(button.x >= card.x and button.x + button.w <= card.x + card.w);
            try std.testing.expect(label.x >= button.x and label.x + label.w <= button.x + button.w + 0.5);
            try std.testing.expect(label.y >= button.y and label.y + label.h <= button.y + button.h + 0.5);
            try std.testing.expectEqualStrings(&action_label, action.label.getText().?.content);
        }
        try std.testing.expectEqualStrings(&detail, slot.detail.getText().?.content);
        try std.testing.expectEqual(ui.TextWrap.none, slot.detail.getText().?.wrap);
        try std.testing.expectEqual(@as(f32, 18), slot.detail.globalRect().h);
        for (slot.actions) |action| try std.testing.expectEqual(@as(f32, 24), action.root.globalRect().h);
    }
    const last = view.slots[2].actions[2].root;
    const before = last.globalRect().y;
    cx.handleScroll(.{ .x = rect.x + 20, .y = rect.y + 100, .dx = 0, .dy = -100000 });
    for (0..8) |_| {
        cx.layout();
        _ = cx.render();
    }
    const after = last.globalRect();
    try std.testing.expect(after.y < before);
    try std.testing.expect(after.y >= rect.y and after.y + after.h <= rect.y + rect.h + 0.5);
}

fn cycled(comptime text: []const u8, comptime length: usize) [length]u8 {
    var result: [length]u8 = undefined;
    for (&result, 0..) |*byte, index| byte.* = text[index % text.len];
    return result;
}

test "notification host retains structured details and dispatches built-in actions to original result kind" {
    const Probe = struct {
        kind: ?host.notifications.Kind = null,
        fn owns(_: *anyopaque, _: host.notifications.Target) bool {
            return true;
        }
        fn activate(raw: *anyopaque, target: host.notifications.Target) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.kind = target.kind;
            return true;
        }
        fn feedback(_: *anyopaque, _: []const u8) void {}
        fn name(_: *anyopaque, _: host.ContentOwner) []const u8 {
            return "prod-web-01";
        }
    };
    var probe: Probe = .{};
    var notice: host.Host = .{ .allocator = a, .driver = undefined, .coordinator = try host.notifications.Coordinator.init(a, .{}, .{}) };
    defer notice.coordinator.deinit();
    defer notice.windows.deinit(a);
    _ = try notice.registerWindow(.{ .context = &probe, .owns = Probe.owns, .activate = Probe.activate, .feedback = Probe.feedback, .owner_name = Probe.name });
    const owner: host.ContentOwner = .{ .session = .{ .session_id = @fromBackingInt(1) } };
    var object = [_]u8{ 'a', '.', 'z', 'i', 'p' };
    try notice.publishTransfer(owner, 1, 1, .{ .result = .failed, .resources_released = true, .notify_complete = false, .details = .{ .object = &object, .detail = "没有文件访问权限" } });
    object[0] = 'b';
    try notice.publishReconnectDetails(owner, 2, 1, .disconnected, .{ .object = "prod-web-01", .detail = "连接超时" });
    try notice.publishAi(owner, 3, 1, .{ .result = .unverified, .resources_released = true });
    try notice.publishTransfer(owner, 4, 1, .{ .result = .cancelled, .resources_released = true, .notify_complete = false });
    const facts = notice.coordinator.notification_records.items;
    try std.testing.expectEqualStrings("a.zip", facts[0].event.object_name);
    try std.testing.expectEqualStrings("没有文件访问权限", facts[0].event.detail);
    try std.testing.expectEqualStrings("prod-web-01", facts[0].event.owner_name);
    try std.testing.expectEqualStrings("文件传输失败", facts[0].event.title);
    try std.testing.expectEqualStrings("连接超时", facts[1].event.detail);
    try std.testing.expectEqual(.warning, facts[2].event.severity);
    // Explicit cancellation is silent: no application fact, system delivery
    // record, or queued toast is added by publishTransfer.
    try std.testing.expectEqual(@as(usize, 3), facts.len);
    try std.testing.expectEqual(@as(usize, 3), notice.coordinator.records.items.len);
    try std.testing.expectEqual(@as(usize, 3), notice.coordinator.presentation_count);
    for (facts) |fact| try std.testing.expect(fact.event.operation_id != 4);
    for ([_]host.notifications.Kind{ .transfer_done, .reconnect, .ai_ready }, 0..) |kind, index| {
        try notice.dispatchAction(facts[index].fact_id, 0);
        try std.testing.expectEqual(kind, probe.kind.?);
    }
}

test "notification history evicts oldest facts without rejecting new ones and retains dismissed content" {
    var coordinator = try host.notifications.Coordinator.init(a, .{}, .{});
    defer coordinator.deinit();
    const owner: host.ContentOwner = .{ .session = .{ .session_id = @fromBackingInt(1) } };
    var first: u64 = 0;
    for (0..105) |index| {
        const published = try coordinator.publishNotification(.{ .definition_id = "host.feedback", .owner = .{ .window_id = 1, .content = owner }, .operation_id = index + 1, .event_revision = 1, .phase = .succeeded, .title = "Retained" }, .{ .monotonic_ms = index, .local_minute = 0 });
        if (index == 0) first = published.fact_id;
        coordinator.dismissNotification(published.fact_id);
    }
    try std.testing.expectEqual(@as(usize, 100), coordinator.notification_records.items.len);
    try std.testing.expect(coordinator.recordFor(first) == null);
    try std.testing.expectEqual(@as(u64, 6), coordinator.notification_records.items[0].event.operation_id);
    try std.testing.expectEqual(@as(usize, 100), coordinator.unreadHistoryCount());
    coordinator.readHistory();
    try std.testing.expectEqual(@as(usize, 0), coordinator.unreadHistoryCount());
    coordinator.clearHistory();
    try std.testing.expectEqual(@as(usize, 0), coordinator.notification_records.items.len);
    try std.testing.expectEqual(@as(usize, 0), coordinator.presentation_count);
}

test "notification countdown follows actual timer pauses and excludes persistent errors" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 480);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    var notice_host: host.Host = .{ .allocator = a, .driver = undefined, .coordinator = try host.notifications.Coordinator.init(a, .{}, .{}) };
    defer notice_host.coordinator.deinit();
    const view = try Presenter.mount(cx, scope, &notice_host, @fromBackingInt(1));
    const owner: host.ContentOwner = .{ .session = .{ .session_id = @fromBackingInt(1) } };
    _ = try notice_host.coordinator.publishNotification(.{ .definition_id = "host.feedback", .owner = .{ .window_id = 1, .content = owner }, .operation_id = 1, .event_revision = 1, .phase = .succeeded, .title = "Done", .actions = &.{.{ .kind = .view_result, .label = "View" }} }, .{ .monotonic_ms = 0, .local_minute = 0 });
    const placement = @import("ui/notification_presenter.zig").Placement{ .content = .{ .x = 0, .y = 0, .w = 860, .h = 480 } };
    try view.update(0, true, owner, placement);
    try view.update(2300, true, owner, placement);
    try std.testing.expectEqualStrings("6 秒后关闭", view.slots[0].countdown.getText().?.content);
    view.slots[0].hovered = true;
    try view.update(7300, true, owner, placement);
    try std.testing.expectEqualStrings("6 秒后关闭", view.slots[0].countdown.getText().?.content);
    _ = try notice_host.coordinator.publishNotification(.{ .definition_id = "host.feedback", .owner = .{ .window_id = 1, .content = owner }, .operation_id = 2, .event_revision = 1, .phase = .failed, .severity = .failure, .title = "Failed" }, .{ .monotonic_ms = 7300, .local_minute = 0 });
    try view.update(7300, true, owner, placement);
    try std.testing.expect(view.slots[0].countdown.style.display == .none);
}

test "notification history compact rows retain full long detail behind an explicit expandable control" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 480);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    var notice: host.Host = .{ .allocator = a, .driver = undefined, .coordinator = try host.notifications.Coordinator.init(a, .{}, .{}) };
    defer notice.coordinator.deinit();
    const trigger = try ui.widgets.Button(.{ .label = "通知" }).mount(scope, cx);
    try cx.root.?.appendChild(a, trigger);
    const view = try @import("ui/notification_history.zig").View.mount(cx, scope, &notice, trigger);
    const detail = cycled("complete retained long notification detail ", 4096);
    _ = try notice.coordinator.publishNotification(.{ .definition_id = "host.feedback", .owner = .{ .window_id = 1, .content = .{ .session = .{ .session_id = @fromBackingInt(1) } } }, .operation_id = 1, .event_revision = 1, .phase = .failed, .severity = .failure, .title = "Failure", .detail = &detail }, .{ .local_minute = 0, .monotonic_ms = 0 });
    view.open.set(true);
    for (0..8) |_| {
        cx.layout();
        _ = cx.render();
    }
    const card = historyNode(view.root, "notifications.history.record").?;
    try std.testing.expectEqual(@as(f32, 58), card.globalRect().h);
    try std.testing.expect(historyNode(view.root, "notifications.history.details") == null);
    var expand = historyNode(view.root, "notifications.history.expand").?;
    var rect = expand.globalRect();
    cx.handleClick(rect.x + rect.w / 2, rect.y + rect.h / 2);
    for (0..8) |_| {
        cx.layout();
        _ = cx.render();
    }
    const details = historyNode(view.root, "notifications.history.details").?;
    try std.testing.expectEqualStrings(&detail, details.children.items[0].getText().?.content);
    try std.testing.expect(details.globalRect().h > view.scroll.container.globalRect().h);
    try std.testing.expect(view.scroll.container.globalRect().h <= 320);
    expand = historyNode(view.root, "notifications.history.expand").?;
    try std.testing.expectEqual(expand, cx.focused_node.?);
    rect = expand.globalRect();
    cx.handleClick(rect.x + rect.w / 2, rect.y + rect.h / 2);
    for (0..8) |_| {
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expect(historyNode(view.root, "notifications.history.details") == null);
    try std.testing.expectEqual(@as(f32, 58), historyNode(view.root, "notifications.history.record").?.globalRect().h);
}

fn historyNode(root: *ui.Node, id: []const u8) ?*ui.Node {
    if (root.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, value, id)) return root;
    for (root.children.items) |child| if (historyNode(child, id)) |found| return found;
    return null;
}
