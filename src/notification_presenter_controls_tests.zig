const std = @import("std");
const ui = @import("ui");
const host = @import("host/notification_host.zig");
const Presenter = @import("ui/notification_presenter.zig").Presenter;
const a = std.testing.allocator;

test "notification closed history badge does not request another idle frame" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 480);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    var notice: host.Host = .{ .allocator = a, .activity = .{ .allocator = a }, .driver = undefined, .coordinator = try host.notifications.Coordinator.init(a, .{ .quiet_hours = "00:00-00:00" }, .{}) };
    defer {
        scope.dispose();
        notice.coordinator.deinit();
        notice.activity.deinit();
    }
    const trigger = try ui.widgets.Button(.{ .label = "通知" }).mount(scope, cx);
    try cx.root.?.appendChild(a, trigger);
    _ = try @import("ui/notification_history.zig").View.mount(cx, scope, &notice, trigger);
    const hook = cx.after_layout_hooks.items[cx.after_layout_hooks.items.len - 1];
    for (0..32) |_| {
        cx.frame_count += 1;
        cx.frame_time_ms += 16;
        _ = cx.render();
    }
    try std.testing.expect(!cx.hasPendingSceneWork());
    _ = hook.run(hook.ctx, 0, false);
    try std.testing.expect(!cx.hasPendingSceneWork());
}

test "notification global material stays at the highest tier across assistant overlap" {
    const theme = @import("ui/app_theme.zig");
    const previous = theme.currentName();
    const parameters = theme.materialParameters();
    defer {
        theme.select(previous);
        _ = theme.setMaterialParameters(parameters.transparency, parameters.blur);
    }
    theme.select(.dark);
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 480);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    var notice: host.Host = .{ .allocator = a, .activity = .{ .allocator = a }, .driver = undefined, .coordinator = try host.notifications.Coordinator.init(a, .{ .quiet_hours = "00:00-00:00" }, .{}) };
    defer {
        scope.dispose();
        notice.coordinator.deinit();
        notice.activity.deinit();
    }
    const assistant = try ui.boxStyled(cx, @import("ui/ai_assistant_styles.zig").panel, .{});
    assistant.setStyleInline(a, .{ .position = .absolute, .inset = .{ .left = .{ .px = 400 }, .top = .{ .px = 40 } }, .width = .{ .px = 280 }, .height = .{ .px = 240 } });
    try cx.root.?.appendChild(a, assistant);
    const view = try Presenter.mount(cx, scope, &notice, @fromBackingInt(1));
    try @import("ui/layer_materials.zig").Policy.mount(cx, scope);
    _ = try notice.coordinator.publishNotification(.{ .definition_id = "host.feedback", .owner = .{ .window_id = 1, .content = .{ .session = .{ .session_id = @fromBackingInt(1) } } }, .operation_id = 1, .event_revision = 1, .phase = .failed, .title = "Global risk", .attention = .{ .kind = .application_risk, .requires_action = true, .time_sensitive = true } }, .{ .monotonic_ms = 0, .local_minute = 0 });
    for ([_]f32{ 0, 50, 75, 100 }) |t| {
        _ = theme.setMaterialParameters(t, 0);
        for ([_]bool{ false, true }) |shown| {
            assistant.setDisplay(if (shown) .flex else .none);
            const card = view.slots[0].root;
            // Exact background transmission without the blur transition at edges.
            assistant.setStyleInline(a, .{ .glass = .{ .backdrop_blur = 0 } });
            card.setStyleInline(a, .{ .glass = .{ .backdrop_blur = 0 } });
            for (0..8) |_| {
                try view.update(0, true, null, .{ .content = .{ .x = 0, .y = 0, .w = 860, .h = 480 } });
                cx.layout();
                _ = cx.render();
            }
            const rect = card.globalRect();
            try std.testing.expect(rect.w > 0 and rect.h > 0);
            const compensation = historyNode(card, "appearance.material.compensation");
            _ = cx.render();
            for ([_]f32{ 32, rect.w - 32 }) |local_x| {
                const x = rect.x + local_x;
                const local_y: f32 = 30.25;
                var transmission = t / 100;
                const lower = assistant.globalRect();
                if (shown and x >= lower.x and x < lower.x + lower.w) transmission *= 1 - @as(f32, @floatFromInt(assistant.getBackground().a)) / 255;
                transmission *= 1 - @as(f32, @floatFromInt(card.getBackground().a)) / 255;
                if (compensation) |paint| for (paint.children.items) |patch| {
                    if (patch.style.display == .none) continue;
                    const area = patch.globalRect();
                    if (x >= area.x and x < area.x + area.w and rect.y + local_y >= area.y and rect.y + local_y < area.y + area.h) transmission *= 1 - @as(f32, @floatFromInt(patch.getBackground().a)) / 255;
                };
                try std.testing.expectApproxEqAbs(t / 100 * 0.2, transmission, 0.003);
            }
        }
    }
}

test "notification replacement and action revision cancel an old press before dispatch" {
    const Probe = struct {
        calls: usize = 0,
        owner: u64 = 0,
        fn owns(_: *anyopaque, _: host.notifications.Target) bool {
            return true;
        }
        fn activate(raw: *anyopaque, target: host.notifications.Target) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            self.owner = @backingInt(target.owner.session.session_id);
            return true;
        }
        fn feedback(_: *anyopaque, _: []const u8) void {}
    };
    for ([_]bool{ false, true }) |replace_fact| {
        const cx = try ui.Cx.init(a, std.testing.io);
        defer cx.deinit();
        cx.setViewport(860, 480);
        cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
        const scope = try ui.Scope.init(a, null, cx.owner);
        var notice: host.Host = .{ .allocator = a, .activity = .{ .allocator = a }, .driver = undefined, .coordinator = try host.notifications.Coordinator.init(a, .{ .quiet_hours = "00:00-00:00" }, .{}) };
        defer {
            scope.dispose();
            notice.coordinator.deinit();
            notice.activity.deinit();
            notice.windows.deinit(a);
        }
        var probe: Probe = .{};
        const window = try notice.registerWindow(.{ .context = &probe, .owns = Probe.owns, .activate = Probe.activate, .feedback = Probe.feedback });
        try notice.registerDefinition(.{ .id = "audit.press", .category = .connection_change, .default_channels = .{ .system = false, .attention = true } });
        const view = try Presenter.mount(cx, scope, &notice, window);
        const first: host.notifications.NotificationEvent = .{
            .definition_id = "audit.press",
            .owner = .{ .window_id = @backingInt(window), .content = .{ .session = .{ .session_id = @fromBackingInt(1), .generation = 1 } } },
            .operation_id = 1,
            .event_revision = 1,
            .phase = .failed,
            .severity = .failure,
            .title = "连接需要处理",
            .attention = .{ .kind = .connection_stopped, .requires_action = true, .time_sensitive = true },
            .actions = &.{.{ .kind = .locate_owner, .label = "查看来源" }},
        };
        _ = try notice.coordinator.publishNotification(first, .{ .monotonic_ms = 1, .local_minute = 0 });
        for (0..6) |_| {
            try view.update(1, true, null, .{ .content = .{ .x = 0, .y = 0, .w = 860, .h = 480 } });
            cx.layout();
        }
        const button = view.slots[0].actions[0].root;
        const before = button.globalRect();
        cx.handleMouseDown(before.x + before.w / 2, before.y + before.h / 2, .{});
        var next = first;
        if (replace_fact) {
            next.owner.content.session.session_id = @fromBackingInt(2);
            next.operation_id = 2;
        } else next.event_revision = 2;
        const publication = try notice.coordinator.publishNotification(next, .{ .monotonic_ms = 2, .local_minute = 0 });
        for (0..6) |_| {
            try view.update(2, true, null, .{ .content = .{ .x = 0, .y = 0, .w = 860, .h = 480 } });
            cx.layout();
        }
        cx.handleMouseUp(before.x + before.w / 2, before.y + before.h / 2);
        try std.testing.expectEqual(@as(usize, 0), probe.calls);
        try std.testing.expectEqual(host.notifications.Presentation.visible, notice.coordinator.recordFor(publication.fact_id).?.presentation);
        const current = button.globalRect();
        cx.handleMouseDown(current.x + current.w / 2, current.y + current.h / 2, .{});
        cx.handleMouseUp(current.x + current.w / 2, current.y + current.h / 2);
        try std.testing.expectEqual(@as(usize, 1), probe.calls);
        try std.testing.expectEqual(@as(u64, if (replace_fact) 2 else 1), probe.owner);
    }
}

test "notification presenter bounds longest admitted content and all actions at minimum window" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 480);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    var notice_host: host.Host = .{ .allocator = a, .activity = .{ .allocator = a }, .driver = undefined, .coordinator = try host.notifications.Coordinator.init(a, .{ .quiet_hours = "00:00-00:00" }, .{}) };
    defer {
        scope.dispose();
        notice_host.coordinator.deinit();
        notice_host.activity.deinit();
    }
    try notice_host.coordinator.registerDefinition(.{ .id = "audit.feedback", .category = .operation_result, .default_channels = .{ .system = false, .attention = false } });
    const view = try Presenter.mount(cx, scope, &notice_host, @fromBackingInt(1));
    const owner: host.ContentOwner = .{ .session = .{ .session_id = @fromBackingInt(1) } };
    var detail = cycled("long detail content with words and spaces ", 4096);
    @memset(detail[0..512], 'x'); // A long unbroken path/token must also wrap.
    const action_label = cycled("long action label with spaces ", 128);
    for (0..3) |index| {
        _ = try notice_host.coordinator.publishNotification(.{ .attention = .{ .kind = .task_blocked, .requires_action = true, .time_sensitive = true }, .definition_id = "audit.feedback", .owner = .{ .window_id = 1, .content = owner }, .operation_id = index + 1, .event_revision = 1, .phase = .failed, .severity = .failure, .title = &cycled("Longest admitted title ", 256), .detail = &detail, .actions = &.{ .{ .kind = .view_result, .label = &action_label }, .{ .kind = .view_result, .label = &action_label }, .{ .kind = .view_result, .label = &action_label } } }, .{ .monotonic_ms = 1, .local_minute = 0 });
    }
    for (0..8) |_| {
        try view.update(1, true, owner, .{ .content = .{ .x = 0, .y = 0, .w = 860, .h = 480 } });
        cx.layout();
    }
    // Complete failure causes remain in a bounded scrolling middle layer.
    for (view.slots[0..1]) |slot| {
        try std.testing.expectEqual(ui.types.Display.flex, slot.detail.style.display);
        const message_viewport = historyNode(slot.root, "notifications.message.viewport").?;
        try std.testing.expect(message_viewport.globalRect().h <= 240);
        try std.testing.expect(slot.root.globalRect().h <= 360);
        try std.testing.expect(slot.footer.globalRect().y >= message_viewport.globalRect().y + message_viewport.globalRect().h);
        for (slot.actions) |action| try std.testing.expectEqual(slot.action_row, action.root.parent.?);
        try std.testing.expectEqual(slot.footer, slot.close.parent.?);
    }
    const rect = view.root.globalRect();

    try std.testing.expectEqual(@as(f32, 62), rect.y);
    try std.testing.expect(rect.y + rect.h <= 480);
    try std.testing.expect(view.content.globalRect().h <= view.viewport.globalRect().h + 0.5);
    for (view.slots[0..1]) |slot| {
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
        try std.testing.expectEqual(ui.TextWrap.word, slot.detail.getText().?.wrap);
        try std.testing.expect(slot.detail.globalRect().h > 18);
        for (slot.actions) |action| try std.testing.expectEqual(@as(f32, 22), action.root.globalRect().h);
    }
    const slot = &view.slots[0];
    const viewport = historyNode(slot.root, "notifications.message.viewport").?;
    const before = slot.detail.globalRect().y;
    const footer_before = slot.footer.globalRect();
    const middle = viewport.globalRect();
    cx.handleScroll(.{ .x = middle.x + middle.w / 2, .y = middle.y + middle.h / 2, .dx = 0, .dy = -100000 });
    for (0..8) |_| {
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expect(slot.detail.globalRect().y < before);
    try std.testing.expectEqual(footer_before, slot.footer.globalRect());
    const last = slot.actions[2].root.globalRect();
    try std.testing.expect(last.y >= rect.y and last.y + last.h <= rect.y + rect.h + 0.5);
}

fn cycled(comptime text: []const u8, comptime length: usize) [length]u8 {
    var result: [length]u8 = undefined;
    for (&result, 0..) |*byte, index| byte.* = text[index % text.len];
    return result;
}

test "notification sources appear once below event titles for every built-in kind and plugin phase" {
    const Probe = struct {
        fn owns(_: *anyopaque, _: host.notifications.Target) bool {
            return true;
        }
        fn activate(_: *anyopaque, _: host.notifications.Target) bool {
            return true;
        }
        fn feedback(_: *anyopaque, _: []const u8) void {}
        fn name(_: *anyopaque, _: host.ContentOwner) []const u8 {
            return "prod-web-01";
        }
    };
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 480);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    var notice: host.Host = .{ .allocator = a, .activity = .{ .allocator = a }, .driver = undefined, .coordinator = try host.notifications.Coordinator.init(a, .{ .quiet_hours = "00:00-00:00" }, .{}) };
    defer {
        scope.dispose();
        notice.coordinator.deinit();
        notice.activity.deinit();
    }
    defer notice.windows.deinit(a);
    var probe: u8 = 0;
    const window = try notice.registerWindow(.{ .context = &probe, .owns = Probe.owns, .activate = Probe.activate, .feedback = Probe.feedback, .owner_name = Probe.name });
    try notice.registerDefinition(.{ .id = "audit.plugin", .category = .connection_change });
    const owner: host.ContentOwner = .{ .session = .{ .session_id = @fromBackingInt(1) } };
    const presenter = try Presenter.mount(cx, scope, &notice, window);
    const trigger = try ui.widgets.Button(.{ .label = "通知" }).mount(scope, cx);
    try cx.root.?.appendChild(a, trigger);
    const history = try @import("ui/notification_history.zig").View.mount(cx, scope, &notice, trigger);
    const Case = enum { transfer_done, transfer_failed, transfer_cancelled, disconnected, recovered, reconnect_failed, ai_ready, ai_failed, ai_unverified, ai_cancelled, feedback_failure, feedback_warning, command_error, plugin_accepted, plugin_verifying, plugin_succeeded, plugin_failed, plugin_cancelled, plugin_unknown };
    for (std.enums.values(Case), 0..) |case, index| {
        for (notice.coordinator.notification_records.items) |*prior| prior.event.attention.resolved = true;
        notice.coordinator.clearHistory();
        const operation: u64 = @intCast(index + 1);
        switch (case) {
            .transfer_done, .transfer_failed, .transfer_cancelled => try notice.publishTransfer(owner, operation, 1, .{ .result = if (case == .transfer_done) .succeeded else if (case == .transfer_failed) .failed else .cancelled, .resources_released = true, .notify_complete = true, .details = .{ .object = "backup.tar.gz" } }),
            .disconnected, .recovered, .reconnect_failed => try notice.publishReconnectDetails(owner, operation, 1, if (case == .disconnected) .disconnected else if (case == .recovered) .recovered else .failed, .{ .object = "prod-web-01" }),
            .ai_ready, .ai_failed, .ai_unverified, .ai_cancelled => try notice.publishAi(owner, operation, 1, .{ .result = if (case == .ai_ready) .succeeded else if (case == .ai_failed) .failed else if (case == .ai_unverified) .unverified else .cancelled, .resources_released = true, .final_answer = true }),
            .feedback_failure, .feedback_warning => try notice.publishFeedbackSeverity(window, owner, "连接失败: HandshakeFailed", if (case == .feedback_failure) .failure else .warning),
            .command_error => _ = try notice.publish(.{ .definition_id = "host.command_error", .owner = .{ .window_id = @backingInt(window), .content = owner }, .operation_id = operation, .event_revision = 1, .phase = .failed, .severity = .failure, .title = "命令执行失败", .detail = "command not found" }),
            else => _ = try notice.publish(.{ .definition_id = "audit.plugin", .owner = .{ .window_id = @backingInt(window), .content = owner }, .operation_id = operation, .event_revision = 1, .phase = switch (case) {
                .plugin_accepted => .accepted,
                .plugin_verifying => .verifying,
                .plugin_succeeded => .succeeded,
                .plugin_failed => .failed,
                .plugin_cancelled => .cancelled,
                else => .outcome_unknown,
            }, .title = "插件连接状态", .object_name = "prod-web-01" }),
        }
        if (case == .feedback_failure or case == .feedback_warning or case == .transfer_failed) {
            try std.testing.expectEqual(@as(usize, 1), notice.coordinator.historyCount(false));
            continue;
        }
        if (case != .reconnect_failed) {
            try std.testing.expectEqual(@as(usize, 0), notice.coordinator.historyCount(false));
            try std.testing.expectEqual(@as(usize, 0), notice.coordinator.presentation_count);
            continue;
        }
        const record = notice.coordinator.notification_records.items[0];
        try std.testing.expectEqualStrings("prod-web-01", record.event.owner_name);
        try std.testing.expect(std.mem.indexOf(u8, record.event.title, record.event.owner_name) == null);
        const now = record.published_ms;
        for (0..8) |_| {
            // The active owner also needs its source line now that titles
            // contain only the event, and equal object names must not repeat.
            try presenter.update(now, true, owner, .{ .content = .{ .x = 0, .y = 0, .w = 860, .h = 480 } });
            cx.layout();
        }
        if (case != .command_error) {
            try std.testing.expectEqualStrings(record.event.title, presenter.slots[0].title.getText().?.content);
            const source = presenter.slots[0].source;
            try std.testing.expect(source.style.display == .flex);
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source.getText().?.content, "prod-web-01"));
        }
        history.open.set(true);
        for (0..8) |_| {
            cx.layout();
            _ = cx.render();
        }
        try std.testing.expectEqualStrings(record.event.title, historyNode(history.root, "notifications.history.title").?.getText().?.content);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, historyNode(history.root, "notifications.history.summary").?.getText().?.content, "prod-web-01"));
        history.open.set(false);
    }
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
    var notice: host.Host = .{ .allocator = a, .activity = .{ .allocator = a }, .driver = undefined, .coordinator = try host.notifications.Coordinator.init(a, .{ .quiet_hours = "00:00-00:00" }, .{}) };
    defer {
        notice.coordinator.deinit();
        notice.activity.deinit();
    }
    defer notice.windows.deinit(a);
    defer notice.ai_origins.deinit(a);
    const window = try notice.registerWindow(.{ .context = &probe, .owns = Probe.owns, .activate = Probe.activate, .feedback = Probe.feedback, .owner_name = Probe.name });
    const owner: host.ContentOwner = .{ .session = .{ .session_id = @fromBackingInt(1) } };
    var object = [_]u8{ 'a', '.', 'z', 'i', 'p' };
    try notice.publishTransfer(owner, 1, 1, .{ .result = .failed, .resources_released = true, .notify_complete = false, .details = .{ .object = &object, .detail = "没有文件访问权限" } });
    object[0] = 'b';
    try notice.publishReconnectDetails(owner, 2, 1, .disconnected, .{ .object = "prod-web-01", .detail = "连接超时" });
    const ai_operation = try notice.reserveAiOperation(window);
    try notice.publishAi(owner, ai_operation, 1, .{ .result = .unverified, .resources_released = true });
    try notice.publishTransfer(owner, 4, 1, .{ .result = .cancelled, .resources_released = true, .notify_complete = false });
    const facts = notice.coordinator.notification_records.items;
    try std.testing.expectEqualStrings("a.zip", facts[0].event.object_name);
    try std.testing.expectEqualStrings("没有文件访问权限", facts[0].event.detail);
    try std.testing.expectEqualStrings("prod-web-01", facts[0].event.owner_name);
    try std.testing.expectEqualStrings("文件传输失败", facts[0].event.title);
    try std.testing.expectEqualStrings("连接超时", facts[2].event.detail);
    try std.testing.expectEqual(.warning, facts[3].event.severity);
    // Explicit cancellation is silent: no application fact, system delivery
    // record, or queued toast is added by publishTransfer.
    try std.testing.expectEqual(@as(usize, 4), facts.len);
    try std.testing.expectEqual(@as(usize, 3), notice.coordinator.records.items.len);
    try std.testing.expectEqual(@as(usize, 1), notice.coordinator.presentation_count);
    for (facts) |fact| try std.testing.expect(fact.event.operation_id != 4);
    for ([_]host.notifications.Kind{ .transfer_done, .reconnect, .ai_ready }, 0..) |kind, index| {
        try notice.dispatchAction(facts[if (index == 0) 0 else index + 1].fact_id, 0);
        try std.testing.expectEqual(kind, probe.kind.?);
    }
}

test "notification history evicts oldest facts without rejecting new ones and retains dismissed content" {
    var coordinator = try host.notifications.Coordinator.init(a, .{ .quiet_hours = "00:00-00:00" }, .{});
    defer coordinator.deinit();
    const owner: host.ContentOwner = .{ .session = .{ .session_id = @fromBackingInt(1) } };
    var first: u64 = 0;
    for (0..105) |index| {
        const published = try coordinator.publishNotification(.{ .attention = .{ .kind = .task_blocked, .requires_action = true, .time_sensitive = true }, .definition_id = "host.feedback", .owner = .{ .window_id = 1, .content = owner }, .operation_id = index + 1, .event_revision = 1, .phase = .succeeded, .title = "Retained" }, .{ .monotonic_ms = index, .local_minute = 0 });
        if (index == 0) first = published.fact_id;
        coordinator.dismissNotification(published.fact_id);
        coordinator.notification_records.items[coordinator.notification_records.items.len - 1].event.attention.resolved = true;
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

test "notification countdown pauses and application risk expires while retaining its fact" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 480);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    var notice_host: host.Host = .{ .allocator = a, .activity = .{ .allocator = a }, .driver = undefined, .coordinator = try host.notifications.Coordinator.init(a, .{ .quiet_hours = "00:00-00:00" }, .{}) };
    defer {
        scope.dispose();
        notice_host.coordinator.deinit();
        notice_host.activity.deinit();
    }
    const view = try Presenter.mount(cx, scope, &notice_host, @fromBackingInt(1));
    const owner: host.ContentOwner = .{ .session = .{ .session_id = @fromBackingInt(1) } };
    _ = try notice_host.coordinator.publishNotification(.{ .attention = .{ .kind = .task_blocked, .requires_action = true, .time_sensitive = true }, .definition_id = "host.feedback", .owner = .{ .window_id = 1, .content = owner }, .operation_id = 1, .event_revision = 1, .phase = .succeeded, .title = "Done", .actions = &.{.{ .kind = .view_result, .label = "View" }} }, .{ .monotonic_ms = 0, .local_minute = 0 });
    const placement = @import("ui/notification_presenter.zig").Placement{ .content = .{ .x = 0, .y = 0, .w = 860, .h = 480 } };
    try view.update(0, true, owner, placement);
    for (0..3) |_| {
        cx.layout();
        try view.update(0, true, owner, placement);
    }
    try view.update(2300, true, owner, placement);
    try std.testing.expectEqualStrings("6 秒后关闭", view.slots[0].countdown.getText().?.content);
    const card = view.slots[0].root.globalRect();
    try std.testing.expect(card.w > 0 and card.h > 0);
    cx.mouse_x = card.x + 10;
    cx.mouse_y = card.y + 10;
    cx.hovered_node = view.slots[0].close;
    try view.update(7300, true, owner, placement);
    try std.testing.expectEqual(ui.types.Display.none, view.slots[0].countdown_view.root.style.display);
    // The framework can retain the old hover node after the pointer leaves.
    cx.mouse_x = 0;
    cx.mouse_y = 0;
    try view.update(7300, true, owner, placement);
    try std.testing.expect(!notice_host.coordinator.recordFor(view.slots[0].fact_id.?).?.paused);
    const risk = try notice_host.coordinator.publishNotification(.{ .attention = .{ .kind = .application_risk, .requires_action = true, .time_sensitive = true }, .definition_id = "host.feedback", .owner = .{ .window_id = 1, .content = owner }, .operation_id = 2, .event_revision = 1, .phase = .failed, .severity = .failure, .title = "Failed" }, .{ .monotonic_ms = 7300, .local_minute = 0 });
    try view.update(7300, true, owner, placement);
    try std.testing.expect(view.slots[0].countdown.style.display == .flex);
    try std.testing.expectEqualStrings("4 秒后关闭", view.slots[0].countdown.getText().?.content);
    cx.hovered_node = null;
    try view.update(7300, true, owner, placement);
    try view.update(11_299, true, owner, placement);
    try std.testing.expectEqual(risk.fact_id, view.slots[0].fact_id.?);
    try view.update(11_300, true, owner, placement);
    try std.testing.expectEqual(@as(?u64, null), view.slots[0].fact_id);
    try std.testing.expect(notice_host.coordinator.recordFor(risk.fact_id).?.pending());
}

test "notification close control hides the banner without deleting the pending record" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 480);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    var notice: host.Host = .{ .allocator = a, .activity = .{ .allocator = a }, .driver = undefined, .coordinator = try host.notifications.Coordinator.init(a, .{ .quiet_hours = "00:00-00:00" }, .{}) };
    defer {
        scope.dispose();
        notice.coordinator.deinit();
        notice.activity.deinit();
    }
    const view = try Presenter.mount(cx, scope, &notice, @fromBackingInt(1));
    const published = try notice.coordinator.publishNotification(.{
        .definition_id = "host.feedback",
        .owner = .{ .window_id = 1, .content = .{ .session = .{ .session_id = @fromBackingInt(1) } } },
        .operation_id = 1,
        .event_revision = 1,
        .phase = .failed,
        .severity = .failure,
        .title = "无法保存记录",
        .detail = "磁盘已满",
        .attention = .{ .kind = .application_risk, .requires_action = true, .time_sensitive = true },
    }, .{ .monotonic_ms = 0, .local_minute = 0 });
    const placement = @import("ui/notification_presenter.zig").Placement{ .content = .{ .x = 0, .y = 0, .w = 860, .h = 480 } };
    for (0..6) |_| {
        try view.update(0, true, null, placement);
        cx.layout();
    }
    const close = view.slots[0].close.globalRect();
    try std.testing.expect(close.w > 0 and close.h > 0);
    cx.handleMouseDown(close.x + close.w / 2, close.y + close.h / 2, .{});
    cx.handleMouseUp(close.x + close.w / 2, close.y + close.h / 2);
    try view.update(1, true, null, placement);
    try std.testing.expectEqual(@as(?u64, null), view.slots[0].fact_id);
    const record = notice.coordinator.recordFor(published.fact_id).?;
    try std.testing.expectEqual(host.notifications.Presentation.hidden, record.presentation);
    try std.testing.expect(record.pending());
    try std.testing.expectEqualStrings("磁盘已满", record.event.detail);
    try std.testing.expectEqual(@as(usize, 1), notice.coordinator.historyCount(true));
}

test "notification history shows complete errors in a bounded scrolling middle layer" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 480);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    var notice: host.Host = .{ .allocator = a, .activity = .{ .allocator = a }, .driver = undefined, .coordinator = try host.notifications.Coordinator.init(a, .{ .quiet_hours = "00:00-00:00" }, .{}) };
    defer {
        scope.dispose();
        notice.coordinator.deinit();
        notice.activity.deinit();
    }
    const trigger = try ui.widgets.Button(.{ .label = "通知" }).mount(scope, cx);
    try cx.root.?.appendChild(a, trigger);
    const view = try @import("ui/notification_history.zig").View.mount(cx, scope, &notice, trigger);
    const detail = cycled("complete retained long notification detail ", 4096);
    _ = try notice.coordinator.publishNotification(.{ .attention = .{ .kind = .task_blocked, .requires_action = true, .time_sensitive = true }, .definition_id = "host.feedback", .owner = .{ .window_id = 1, .content = .{ .session = .{ .session_id = @fromBackingInt(1) } } }, .operation_id = 1, .event_revision = 1, .phase = .failed, .severity = .failure, .title = "Failure", .detail = &detail }, .{ .local_minute = 0, .monotonic_ms = 0 });
    view.open.set(true);
    for (0..8) |_| {
        cx.layout();
        _ = cx.render();
    }
    const details = historyNode(view.root, "notifications.history.details").?;
    const message = historyNode(view.root, "notifications.history.message").?;
    try std.testing.expectEqualStrings(&detail, message.children.items[0].getText().?.content);
    try std.testing.expect(details.globalRect().h <= 240);
    try std.testing.expect(message.globalRect().h > details.globalRect().h);
    try std.testing.expect(historyNode(view.root, "notifications.history.expand") == null);
    try std.testing.expect(view.scroll.container.globalRect().h <= 320);
}

fn historyNode(root: *ui.Node, id: []const u8) ?*ui.Node {
    if (root.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, value, id)) return root;
    for (root.children.items) |child| if (historyNode(child, id)) |found| return found;
    return null;
}

test "notification history repeated reopen retains one compensation background and constant transparency" {
    const theme = @import("ui/app_theme.zig");
    const saved = theme.materialParameters();
    defer _ = theme.setMaterialParameters(saved.transparency, saved.blur);
    _ = theme.setMaterialParameters(50, 0);
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 480);
    try cx.setTestFrameStep(16);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    var notice: host.Host = .{ .allocator = a, .activity = .{ .allocator = a }, .driver = undefined, .coordinator = try host.notifications.Coordinator.init(a, .{ .quiet_hours = "00:00-00:00" }, .{}) };
    defer {
        scope.dispose();
        notice.coordinator.deinit();
        notice.activity.deinit();
    }
    try @import("ui/layer_materials.zig").Policy.mount(cx, scope);
    const trigger = try ui.widgets.Button(.{ .label = "通知" }).mount(scope, cx);
    try cx.root.?.appendChild(a, trigger);
    const view = try @import("ui/notification_history.zig").View.mount(cx, scope, &notice, trigger);
    for (0..8) |_| {
        view.open.set(true);
        for (0..40) |_| {
            cx.advanceFrameClock();
            _ = cx.render();
        }
        const rect = view.root.globalRect();
        var count: usize = 0;
        var transmission: f32 = 0.5 * (1 - @as(f32, @floatFromInt(view.root.getBackground().a)) / 255);
        for (view.root.children.items) |child| {
            const id = child.meta.ownership.meta.test_id orelse continue;
            if (!std.mem.eql(u8, id, "appearance.material.compensation")) continue;
            count += 1;
            for (child.children.items) |patch| {
                if (patch.style.display == .none) continue;
                const area = patch.globalRect();
                if (area.x <= rect.x + 40 and area.x + area.w > rect.x + 40 and area.y <= rect.y + 110 and area.y + area.h > rect.y + 110) {
                    try std.testing.expect(patch.style.gradient() == null);
                    transmission *= 1 - @as(f32, @floatFromInt(patch.getBackground().a)) / 255;
                }
            }
        }
        try std.testing.expectEqual(@as(usize, 1), count);
        try std.testing.expectApproxEqAbs(@as(f32, 0.1), transmission, 0.003);
        view.open.set(false);
        for (0..40) |_| {
            cx.advanceFrameClock();
            _ = cx.render();
        }
    }
}

test "notification history background blur follows material changes without replacing content" {
    const theme = @import("ui/app_theme.zig");
    const saved = theme.materialParameters();
    defer _ = theme.setMaterialParameters(saved.transparency, saved.blur);
    _ = theme.setMaterialParameters(0, 0);
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 480);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    var notice: host.Host = .{ .allocator = a, .activity = .{ .allocator = a }, .driver = undefined, .coordinator = try host.notifications.Coordinator.init(a, .{ .quiet_hours = "00:00-00:00" }, .{}) };
    defer {
        scope.dispose();
        notice.coordinator.deinit();
        notice.activity.deinit();
    }
    const trigger = try ui.widgets.Button(.{ .label = "通知" }).mount(scope, cx);
    try cx.root.?.appendChild(a, trigger);
    const view = try @import("ui/notification_history.zig").View.mount(cx, scope, &notice, trigger);
    const root_id = view.root.id;
    try std.testing.expectEqual(@as(f32, 12), view.root.style.backdrop_blur());
    view.open.set(true);
    for ([_]f32{ 0, 8, 24, 0 }) |blur| {
        _ = theme.setMaterialParameters(0, blur);
        for (0..8) |_| {
            cx.layout();
            _ = cx.render();
        }
        try std.testing.expectEqual(@max(12, blur), view.root.style.backdrop_blur());
        // Popover positioning must retain the panel's rounded child clip;
        // material compensation patches otherwise paint square corners.
        try std.testing.expect(view.root.style.overflow_hidden);
        try std.testing.expectEqual(root_id, view.root.id);
        try std.testing.expectEqual(theme.current().overlay, view.root.getBackground());
        try std.testing.expectEqual(theme.current().fg_1, view.root.children.items[0].children.items[1].getText().?.color);
        try std.testing.expect(historyNode(view.root, "notifications.history.empty") != null);
    }
}

test "notification history expands only independent details without repeating title or owner" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 480);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    var notice: host.Host = .{ .allocator = a, .activity = .{ .allocator = a }, .driver = undefined, .coordinator = try host.notifications.Coordinator.init(a, .{ .quiet_hours = "00:00-00:00" }, .{}) };
    defer {
        scope.dispose();
        notice.coordinator.deinit();
        notice.activity.deinit();
    }
    const trigger = try ui.widgets.Button(.{ .label = "通知" }).mount(scope, cx);
    try cx.root.?.appendChild(a, trigger);
    const view = try @import("ui/notification_history.zig").View.mount(cx, scope, &notice, trigger);
    for ([_][]const u8{ "", " \n\t", "Failure", "Local Terminal", "backup.zip", "Permission denied\nexit 1" }, 1..) |detail, operation| {
        for (notice.coordinator.notification_records.items) |*prior| prior.event.attention.resolved = true;
        notice.coordinator.clearHistory();
        const record = try notice.coordinator.publishNotification(.{ .attention = .{ .kind = .task_blocked, .requires_action = true, .time_sensitive = true }, .definition_id = "host.feedback", .owner = .{ .window_id = 1, .content = .{ .session = .{ .session_id = @fromBackingInt(1) } } }, .operation_id = operation, .event_revision = 1, .phase = .failed, .severity = .failure, .title = "Failure", .owner_name = "Local Terminal", .object_name = "backup.zip", .detail = detail }, .{ .local_minute = 0, .monotonic_ms = 0 });
        _ = record;
        view.open.set(true);
        for (0..8) |_| {
            cx.layout();
            _ = cx.render();
        }
        try std.testing.expect(historyNode(view.root, "notifications.history.expand") == null);
        if (operation < 6) {
            try std.testing.expect(historyNode(view.root, "notifications.history.details") == null);
        } else {
            const message = historyNode(view.root, "notifications.history.message").?;
            try std.testing.expectEqual(@as(usize, 1), message.children.items.len);
            try std.testing.expectEqualStrings(detail, message.children.items[0].getText().?.content);
        }
    }
}

test "notification visible migration preserves expanded content and paused presentation" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 480);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    var notice: host.Host = .{ .allocator = a, .activity = .{ .allocator = a }, .driver = undefined, .coordinator = try host.notifications.Coordinator.init(a, .{ .quiet_hours = "00:00-00:00" }, .{}) };
    defer {
        scope.dispose();
        notice.coordinator.deinit();
        notice.activity.deinit();
    }
    const view = try Presenter.mount(cx, scope, &notice, @fromBackingInt(1));
    const owner: host.ContentOwner = .{ .session = .{ .session_id = @fromBackingInt(1) } };
    var event: host.notifications.NotificationEvent = .{ .definition_id = "host.feedback", .owner = .{ .window_id = 1, .content = owner }, .operation_id = 1, .event_revision = 1, .phase = .failed, .title = "Needs attention", .detail = "Independent detail", .attention = .{ .kind = .task_blocked, .requires_action = true, .time_sensitive = true, .incident_id = 11 }, .actions = &.{.{ .kind = .view_result, .label = "View" }} };
    const id = (try notice.coordinator.publishNotification(event, .{ .monotonic_ms = 0, .local_minute = 0 })).fact_id;
    const placement = @import("ui/notification_presenter.zig").Placement{ .content = .{ .x = 0, .y = 0, .w = 860, .h = 480 } };
    try view.update(0, true, owner, placement);
    view.slots[0].expand.behavior.events.on_click.?.invoke();
    try view.update(1000, true, owner, placement);
    const root = view.slots[0].root;
    const remaining = notice.coordinator.recordFor(id).?.remaining_ms;
    event.event_revision = 2;
    event.attention.incident_id = 22;
    _ = try notice.coordinator.publishNotification(event, .{ .monotonic_ms = 1100, .local_minute = 0 });
    try view.update(16000, true, owner, placement);
    try std.testing.expect(root == view.slots[0].root);
    try std.testing.expect(view.slots[0].expanded);
    try std.testing.expectEqual(ui.types.Display.flex, view.slots[0].detail.style.display);
    try std.testing.expectEqual(remaining, notice.coordinator.recordFor(id).?.remaining_ms);
    try std.testing.expect(notice.coordinator.recordFor(id).?.paused);
}

test "notification countdown covers risk banners and hides during interaction beside the action" {
    const theme = @import("ui/app_theme.zig");
    const previous = theme.currentName();
    defer theme.select(previous);
    for ([_]bool{ false, true }) |has_action| {
        const cx = try ui.Cx.init(a, std.testing.io);
        defer cx.deinit();
        cx.setViewport(860, 480);
        cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
        const scope = try ui.Scope.init(a, null, cx.owner);
        var notice: host.Host = .{ .allocator = a, .activity = .{ .allocator = a }, .driver = undefined, .coordinator = try host.notifications.Coordinator.init(a, .{ .quiet_hours = "00:00-00:00" }, .{}) };
        defer {
            scope.dispose();
            notice.coordinator.deinit();
            notice.activity.deinit();
        }
        const view = try Presenter.mount(cx, scope, &notice, @fromBackingInt(1));
        const published = try notice.coordinator.publishNotification(.{
            .definition_id = "host.feedback",
            .owner = .{ .window_id = 1, .content = .{ .session = .{ .session_id = @fromBackingInt(1) } } },
            .operation_id = 1,
            .event_revision = 1,
            .phase = .failed,
            .title = "需要处理",
            .owner_name = "prod-web-01",
            .detail = "保留完整详情",
            .attention = .{ .kind = if (has_action) .task_blocked else .application_risk, .requires_action = true, .time_sensitive = true },
            .actions = if (has_action) &.{.{ .kind = .locate_owner, .label = "查看来源" }} else &.{},
        }, .{ .monotonic_ms = 1000, .local_minute = 0 });
        const placement: @import("ui/notification_presenter.zig").Placement = .{ .content = .{ .x = 0, .y = 0, .w = 860, .h = 480 } };
        for (0..4) |_| {
            try view.update(1000, true, null, placement);
            cx.layout();
        }
        const slot = &view.slots[0];
        try std.testing.expectEqualStrings(if (has_action) "8 秒后关闭" else "4 秒后关闭", slot.countdown.getText().?.content);
        try std.testing.expectEqual(ui.types.Display.flex, slot.countdown.style.display);
        try view.update(2001, true, null, placement);
        try std.testing.expectEqualStrings(if (has_action) "7 秒后关闭" else "3 秒后关闭", slot.countdown.getText().?.content);
        if (has_action) {
            const timer = slot.countdown_view.root.globalRect();
            const button = slot.actions[0].root.globalRect();
            try std.testing.expect(timer.x + timer.w <= button.x);
            try std.testing.expectApproxEqAbs(timer.y + timer.h / 2, button.y + button.h / 2, 0.5);
        }
        const rect = slot.root.globalRect();
        cx.mouse_x = rect.x + 10;
        cx.mouse_y = rect.y + 10;
        cx.hovered_node = slot.root;
        try view.update(3000, true, null, placement);
        try view.update(15000, true, null, placement);
        try std.testing.expectEqual(ui.types.Display.none, slot.countdown_view.root.style.display);
        try std.testing.expectEqual(host.notifications.Presentation.visible, notice.coordinator.recordFor(published.fact_id).?.presentation);
        cx.hovered_node = null;
        for ([_]theme.Name{ .dark, .light, .sauber }) |name| {
            theme.select(name);
            try view.update(15000, true, null, placement);
            cx.layout();
            try std.testing.expectEqualStrings(if (has_action) "8 秒后关闭" else "4 秒后关闭", slot.countdown.getText().?.content);
            try std.testing.expectEqual(theme.current().fg_2, slot.countdown.getText().?.color);
            if (has_action) try std.testing.expectEqual(theme.actionForeground(theme.current().action_accent), slot.actions[0].label.getText().?.color);
        }
        try view.update(23001, true, null, placement);
        try std.testing.expectEqual(ui.types.Display.none, slot.root.style.display);
        // Closing the banner never resolves the source or removes its record.
        try std.testing.expect(notice.coordinator.recordFor(published.fact_id).?.pending());
    }
}

test "notification operation failure remains visible above its settings modal with cause expanded" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 480);
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    var notice: host.Host = .{ .allocator = a, .activity = .{ .allocator = a }, .driver = undefined, .coordinator = try host.notifications.Coordinator.init(a, .{ .quiet_hours = "00:00-23:59" }, .{}) };
    defer {
        notice.coordinator.deinit();
        notice.activity.deinit();
    }
    const presenter = try Presenter.mount(cx, scope, &notice, @fromBackingInt(1));
    _ = try notice.coordinator.publishNotification(.{ .definition_id = "host.operation_error", .owner = .{ .window_id = 1, .window_only = true }, .operation_id = 1, .event_revision = 1, .phase = .failed, .severity = .failure, .title = "无法保存设置", .detail = "SCNetX · API Key：请填写 API Key，或停用此服务提供方。", .attention = .{ .kind = .operation_failed, .requires_action = true, .time_sensitive = true } }, .{ .monotonic_ms = 0, .local_minute = 1 });
    for (0..8) |_| {
        try presenter.update(0, true, null, .{ .content = .{ .x = 0, .y = 0, .w = 860, .h = 480 }, .avoid = &.{.{ .x = 16, .y = 16, .w = 828, .h = 448 }} });
        cx.layout();
    }
    try std.testing.expectEqual(ui.types.Display.flex, presenter.root.style.display);
    try std.testing.expect(!presenter.slots[0].obscured);
    try std.testing.expectEqual(ui.types.Display.flex, presenter.slots[0].detail.style.display);
    try std.testing.expectEqual(@import("ui/app_theme.zig").current().danger_ink, presenter.slots[0].detail.getText().?.color);
    try std.testing.expect(presenter.slots[0].detail.globalRect().h > 18);
}
