const std = @import("std");
const notifications = @import("host/notification_coordinator.zig");
test {
    _ = @import("host/content_context.zig");
    _ = @import("host/challenge_host.zig");
    _ = @import("host/frame_texture_sink.zig");
    _ = @import("host/capability_snapshot.zig");
    _ = @import("host/operation_store.zig");
}
fn event(operation: u64) notifications.NotificationEvent {
    return .{ .definition_id = "fixture.result", .owner = .{ .window_id = 1, .content = .{ .session = .{ .session_id = @fromBackingInt(1), .generation = 2 } } }, .operation_id = operation, .event_revision = 1, .phase = .accepted, .title = "Accepted" };
}
test "unified notification updates accepted unknown query success in place and ignores old revisions" {
    var coordinator = try notifications.Coordinator.init(std.testing.allocator, .{}, .{});
    defer coordinator.deinit();
    try coordinator.registerDefinition(.{ .id = "fixture.result", .category = .operation_result });
    var value = event(1);
    const first = try coordinator.publishNotification(value, .{ .local_minute = 0, .monotonic_ms = 0 });
    value.event_revision = 2;
    value.phase = .outcome_unknown;
    value.title = "Unknown";
    try std.testing.expect((try coordinator.publishNotification(value, .{ .local_minute = 0, .monotonic_ms = 1 })).updated);
    value.event_revision = 3;
    value.phase = .verifying;
    _ = try coordinator.publishNotification(value, .{ .local_minute = 0, .monotonic_ms = 2 });
    value.event_revision = 4;
    value.phase = .succeeded;
    _ = try coordinator.publishNotification(value, .{ .local_minute = 0, .monotonic_ms = 3 });
    value.event_revision = 2;
    try std.testing.expect((try coordinator.publishNotification(value, .{ .local_minute = 0, .monotonic_ms = 4 })).duplicate);
    try std.testing.expectEqual(@as(usize, 1), coordinator.notification_records.items.len);
    try std.testing.expectEqual(@as(u64, 4), coordinator.recordFor(first.fact_id).?.event.event_revision);
    try std.testing.expectEqual(@as(usize, 1), coordinator.presentation_count);
}
test "notification queue max32 max3 visible and dismissal does not clear unknown fact" {
    var coordinator = try notifications.Coordinator.init(std.testing.allocator, .{}, .{});
    defer coordinator.deinit();
    try coordinator.registerDefinition(.{ .id = "fixture.result", .category = .operation_result });
    var unknown = event(1);
    unknown.phase = .outcome_unknown;
    const first = try coordinator.publishNotification(unknown, .{ .local_minute = 0, .monotonic_ms = 0 });
    for (2..38) |i| _ = try coordinator.publishNotification(event(i), .{ .local_minute = 0, .monotonic_ms = 0 });
    try std.testing.expectEqual(@as(usize, 32), coordinator.presentation_count);
    var visible: [3]*const notifications.NotificationRecord = undefined;
    try std.testing.expectEqual(@as(usize, 3), coordinator.visibleNotifications(1, 0, true, &visible));
    coordinator.dismissNotification(first.fact_id);
    try std.testing.expectEqual(notifications.Phase.outcome_unknown, coordinator.recordFor(first.fact_id).?.event.phase);
    try std.testing.expectEqual(notifications.Presentation.hidden, coordinator.recordFor(first.fact_id).?.presentation);
    try std.testing.expectEqual(@as(usize, 0), coordinator.visibleNotifications(2, 4000, true, &visible));
}
test "notification focus pause owner transfer and ended retention" {
    var coordinator = try notifications.Coordinator.init(std.testing.allocator, .{}, .{});
    defer coordinator.deinit();
    try coordinator.registerDefinition(.{ .id = "fixture.result", .category = .operation_result });
    const first = try coordinator.publishNotification(event(1), .{ .local_minute = 0, .monotonic_ms = 0 });
    coordinator.pauseNotification(first.fact_id, true);
    var visible: [3]*const notifications.NotificationRecord = undefined;
    try std.testing.expectEqual(@as(usize, 1), coordinator.visibleNotifications(1, 5000, true, &visible));
    coordinator.moveOwner(event(1).owner.content, 2);
    coordinator.ownerEnded(event(1).owner.content);
    try std.testing.expectEqual(@as(usize, 0), coordinator.visibleNotifications(1, 5001, true, &visible));
    try std.testing.expectEqual(@as(usize, 1), coordinator.visibleNotifications(2, 5002, true, &visible));
    try std.testing.expect(visible[0].owner_ended);
    try std.testing.expectEqual(@as(usize, 0), coordinator.visibleNotifications(2, 9000, false, &visible));
}
test "notification attention never consumes or invents terminal output generations" {
    var coordinator = try notifications.Coordinator.init(std.testing.allocator, .{}, .{});
    defer coordinator.deinit();
    try coordinator.registerDefinition(.{ .id = "fixture.result", .category = .operation_result });
    const owner = event(1).owner.content;
    try std.testing.expect(try coordinator.observeOutput(owner, 8));
    try std.testing.expect(coordinator.markRead(owner, 8, true));
    _ = try coordinator.publishNotification(event(1), .{ .local_minute = 0, .monotonic_ms = 0 });
    try std.testing.expect(coordinator.hasDot(owner));
    try std.testing.expect(coordinator.markNotificationsRead(owner));
    try std.testing.expect(!coordinator.hasDot(owner));
    try std.testing.expect(try coordinator.observeOutput(owner, 9));
    try std.testing.expect(!coordinator.markNotificationsRead(owner));
    try std.testing.expect(coordinator.hasDot(owner));
    try std.testing.expect(coordinator.markRead(owner, 9, true));
    try std.testing.expect(!coordinator.hasDot(owner));
}
test "notification timers and hover pause are independent across windows" {
    var coordinator = try notifications.Coordinator.init(std.testing.allocator, .{}, .{});
    defer coordinator.deinit();
    try coordinator.registerDefinition(.{ .id = "fixture.result", .category = .operation_result });
    const first = try coordinator.publishNotification(event(1), .{ .local_minute = 0, .monotonic_ms = 0 });
    var second = event(2);
    second.owner.window_id = 2;
    _ = try coordinator.publishNotification(second, .{ .local_minute = 0, .monotonic_ms = 0 });
    coordinator.pauseNotification(first.fact_id, true);
    var visible: [3]*const notifications.NotificationRecord = undefined;
    try std.testing.expectEqual(@as(usize, 0), coordinator.visibleNotifications(2, 5000, false, &visible));
    try std.testing.expectEqual(@as(usize, 1), coordinator.visibleNotifications(1, 5000, true, &visible));
    try std.testing.expectEqual(first.fact_id, visible[0].fact_id);
    try std.testing.expectEqual(@as(u64, 3000), visible[0].remaining_ms);
}

test "notification definitions validate stable names namespace version and channels" {
    var coordinator = try notifications.Coordinator.init(std.testing.allocator, .{}, .{});
    defer coordinator.deinit();
    try std.testing.expectError(error.InvalidNotificationDefinition, coordinator.registerDefinition(.{ .id = "plain", .category = .attention }));
    try coordinator.registerDefinition(.{ .id = "fixture.result", .category = .operation_result });
    try coordinator.registerDefinition(.{ .id = "fixture.result", .category = .operation_result });
    try std.testing.expectError(error.NotificationDefinitionConflict, coordinator.registerDefinition(.{ .id = "fixture.result", .version = 2, .category = .operation_result }));
    var value = event(1);
    value.definition_version = 2;
    try std.testing.expectError(error.NotificationDefinitionVersionMismatch, coordinator.publishNotification(value, .{ .local_minute = 0, .monotonic_ms = 0 }));
    value.definition_version = 1;
    value.definition_id = "unregistered.result";
    try std.testing.expectError(error.UnknownNotificationDefinition, coordinator.publishNotification(value, .{ .local_minute = 0, .monotonic_ms = 0 }));
    try std.testing.expectEqual(@as(usize, 0), coordinator.notification_records.items.len);
}
test "unified system notification updates only after verified result and consumes async receipt once" {
    const Driver = struct {
        sends: usize = 0,
        event_id: u64 = 0,
        target: notifications.Target = undefined,
        fn send(ptr: *anyopaque, message: notifications.SystemMessage) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.sends += 1;
            self.event_id = message.event_id;
            self.target = message.target;
        }
    };
    var driver: Driver = .{};
    var coordinator = try notifications.Coordinator.init(std.testing.allocator, .{ .quiet_hours = "00:00-00:00" }, .{ .context = &driver, .notify = Driver.send, .authorization = .authorized, .delivery_mode = .asynchronous });
    defer coordinator.deinit();
    try coordinator.registerDefinition(.{ .id = "fixture.result", .category = .operation_result, .default_channels = .{ .system = true }, .system_policy = .transfer_done });
    var value = event(1);
    const publication = try coordinator.publishNotification(value, .{ .local_minute = 0, .monotonic_ms = 0 });
    try std.testing.expectEqual(@as(usize, 0), driver.sends);
    value.event_revision = 2;
    value.phase = .succeeded;
    _ = try coordinator.publishNotification(value, .{ .local_minute = 0, .monotonic_ms = 1 });
    try std.testing.expectEqual(@as(usize, 1), driver.sends);
    try std.testing.expectEqual(notifications.Disposition.pending, coordinator.recordFor(publication.fact_id).?.system.disposition);
    try std.testing.expect(std.meta.eql(driver.target, coordinator.targetFor(driver.event_id).?));
    try std.testing.expect(try coordinator.reportSystemResult(driver.event_id, driver.target, .scheduled));
    try std.testing.expect(!try coordinator.reportSystemResult(driver.event_id, driver.target, .scheduled));
    value.event_revision = 3;
    _ = try coordinator.publishNotification(value, .{ .local_minute = 0, .monotonic_ms = 2 });
    try std.testing.expectEqual(@as(usize, 1), driver.sends);
    try std.testing.expectEqual(notifications.Disposition.scheduled, coordinator.recordFor(publication.fact_id).?.system.disposition);
}
