const std = @import("std");
const notifications = @import("host/notification_coordinator.zig");
const config = @import("config/config.zig");
const a = std.testing.allocator;
const owner: notifications.Owner = .{ .session = .{ .session_id = @fromBackingInt(21), .generation = 3 } };
const other: notifications.Owner = .{ .session = .{ .session_id = @fromBackingInt(21), .generation = 4 } };
const day: notifications.Clock = .{ .local_minute = 12 * 60, .monotonic_ms = 0 };

const Platform = struct {
    notifications_sent: usize = 0,
    bells: usize = 0,
    fail: bool = false,
    last_target: ?notifications.Target = null,
    fn sink(self: *Platform) notifications.Sink {
        return .{ .context = self, .authorization = .authorized, .notify = notify, .ring = ring };
    }
    fn notify(raw: *anyopaque, message: notifications.SystemMessage) !void {
        const self: *Platform = @ptrCast(@alignCast(raw));
        self.notifications_sent += 1;
        self.last_target = message.target;
        if (self.fail) return error.PlatformSendFailed;
    }
    fn ring(raw: *anyopaque, _: notifications.BellMessage) !void {
        const self: *Platform = @ptrCast(@alignCast(raw));
        self.bells += 1;
        if (self.fail) return error.PlatformSoundFailed;
    }
};
fn event(kind: notifications.Kind) notifications.Event {
    return .{ .event_id = 1, .kind = kind, .owner = owner, .operation_id = 30, .attempt_or_turn_id = 2, .result = .succeeded, .summary = "Completed", .terminal_confirmed = true, .resources_released = true, .final_answer = true };
}

test "notification policy quiet hours uses local inclusive exclusive bounds including midnight and empty range" {
    const overnight = try notifications.QuietHours.parse("22:00-08:00");
    try std.testing.expect(!overnight.contains(21 * 60 + 59));
    try std.testing.expect(overnight.contains(22 * 60));
    try std.testing.expect(overnight.contains(0));
    try std.testing.expect(overnight.contains(7 * 60 + 59));
    try std.testing.expect(!overnight.contains(8 * 60));
    const daytime = try notifications.QuietHours.parse("09:15-10:30");
    try std.testing.expect(!daytime.contains(9 * 60 + 14));
    try std.testing.expect(daytime.contains(9 * 60 + 15));
    try std.testing.expect(daytime.contains(10 * 60 + 29));
    try std.testing.expect(!daytime.contains(10 * 60 + 30));
    const empty = try notifications.QuietHours.parse("08:00-08:00");
    for (0..1440) |minute| try std.testing.expect(!empty.contains(@intCast(minute)));
    for ([_][]const u8{ "25:00-08:00", "22:60-08:00", "22:00-24:00", "+1:00-08:00", "2:00-8:00", "22:00/08:00" }) |raw| try std.testing.expectError(error.InvalidQuietHours, notifications.QuietHours.parse(raw));
}

test "notification coordinator actual terminal facts deliver once per event and operation and own summary" {
    var platform: Platform = .{};
    var value = try notifications.Coordinator.init(a, .{ .transfer_done = true, .ai_ready = true }, platform.sink());
    defer value.deinit();
    var summary = [_]u8{ 'D', 'o', 'n', 'e' };
    var completed = event(.transfer_done);
    completed.summary = &summary;
    const first = try value.publish(completed, day);
    try std.testing.expect(!first.duplicate);
    @memset(&summary, 'x');
    try std.testing.expectEqualStrings("Done", value.records.items[first.record_index].event.summary);
    try std.testing.expect((try value.publish(completed, day)).duplicate);
    completed.event_id += 1;
    try std.testing.expect((try value.publish(completed, day)).duplicate);
    try std.testing.expectEqual(@as(usize, 1), platform.notifications_sent);
    try std.testing.expectEqual(@as(usize, 1), value.records.items.len);
    var next_attempt = event(.transfer_done);
    next_attempt.event_id = 3;
    next_attempt.attempt_or_turn_id = 3;
    try std.testing.expect(!(try value.publish(next_attempt, day)).duplicate);
    try std.testing.expectEqual(@as(usize, 2), platform.notifications_sent);
    try std.testing.expect(platform.last_target.?.owner.eql(owner));
    try std.testing.expectEqual(@as(?u64, 3), platform.last_target.?.attempt_or_turn_id);
}

test "notification coordinator rejects progress checksum or nonfinal AI as a ready event and keeps failure facts" {
    var platform: Platform = .{};
    var value = try notifications.Coordinator.init(a, .{ .transfer_done = true, .ai_ready = true }, platform.sink());
    defer value.deinit();
    var candidate = event(.transfer_done);
    candidate.terminal_confirmed = false;
    try std.testing.expectError(error.NotTerminal, value.publish(candidate, day));
    candidate.terminal_confirmed = true;
    candidate.resources_released = false;
    try std.testing.expectError(error.ResultNotReleased, value.publish(candidate, day));
    candidate = event(.ai_ready);
    candidate.final_answer = false;
    try std.testing.expectError(error.AnswerNotFinal, value.publish(candidate, day));
    candidate.final_answer = true;
    candidate.resources_released = false;
    try std.testing.expectError(error.AnswerNotFinal, value.publish(candidate, day));
    candidate.resources_released = true;
    candidate.result = .stream_done;
    try std.testing.expectError(error.InvalidEventResult, value.publish(candidate, day));
    candidate.result = .unverified;
    const unverified = try value.publish(candidate, day);
    try std.testing.expectEqual(.not_applicable, value.records.items[unverified.record_index].system.disposition);
    var failed = event(.transfer_done);
    failed.event_id = 2;
    failed.result = .failed;
    const failure = try value.publish(failed, day);
    try std.testing.expectEqual(.failed, value.records.items[failure.record_index].event.result);
    try std.testing.expectEqual(.not_applicable, value.records.items[failure.record_index].system.disposition);
    try std.testing.expectEqual(@as(usize, 0), platform.notifications_sent);
}

test "notification coordinator saved toggles and quiet authorization changes do not replay consumed facts" {
    var platform: Platform = .{};
    var prefs: config.Notify = .{ .transfer_done = false, .ai_ready = false, .reconnect = false };
    var value = try notifications.Coordinator.init(a, prefs, platform.sink());
    defer value.deinit();
    var disabled = event(.transfer_done);
    const off = try value.publish(disabled, day);
    try std.testing.expectEqual(.disabled, value.records.items[off.record_index].system.disposition);
    prefs.transfer_done = true;
    prefs.ai_ready = true;
    prefs.reconnect = true;
    try std.testing.expect(try value.updatePolicy(prefs));
    disabled.event_id = 2;
    try std.testing.expect((try value.publish(disabled, day)).duplicate);
    var quiet = event(.ai_ready);
    quiet.event_id = 3;
    const night = try value.publish(quiet, .{ .local_minute = 22 * 60, .monotonic_ms = 10 });
    try std.testing.expectEqual(.quiet, value.records.items[night.record_index].system.disposition);
    quiet.event_id = 4;
    try std.testing.expect((try value.publish(quiet, day)).duplicate);
    value.reportAuthorization(.denied);
    var denied = event(.transfer_done);
    denied.event_id = 5;
    denied.operation_id = 31;
    const denial = try value.publish(denied, day);
    try std.testing.expectEqual(.unauthorized, value.records.items[denial.record_index].system.disposition);
    value.reportAuthorization(.authorized);
    denied.event_id = 6;
    try std.testing.expect((try value.publish(denied, day)).duplicate);
    denied.event_id = 7;
    denied.operation_id = 32;
    _ = try value.publish(denied, day);
    try std.testing.expectEqual(@as(usize, 1), platform.notifications_sent);
    try std.testing.expectEqual(@as(usize, 4), value.records.items.len);
    prefs.quiet_hours = "25:00-08:00";
    const previous = value.policy;
    try std.testing.expectError(error.InvalidQuietHours, value.updatePolicy(prefs));
    try std.testing.expectEqualDeep(previous, value.policy);
}

test "notification coordinator reports unsupported platform or failed delivery without losing business facts" {
    var unavailable = try notifications.Coordinator.init(a, .{ .transfer_done = true, .ai_ready = true }, .{});
    defer unavailable.deinit();
    const missing = try unavailable.publish(event(.transfer_done), day);
    try std.testing.expectEqual(.unsupported, unavailable.records.items[missing.record_index].system.disposition);
    try std.testing.expectEqual(.succeeded, unavailable.records.items[missing.record_index].event.result);
    var platform: Platform = .{ .fail = true };
    var value = try notifications.Coordinator.init(a, .{ .transfer_done = true, .ai_ready = true }, platform.sink());
    defer value.deinit();
    const sent = try value.publish(event(.ai_ready), day);
    try std.testing.expectEqual(.failed, value.records.items[sent.record_index].system.disposition);
    try std.testing.expectEqual(error.PlatformSendFailed, value.records.items[sent.record_index].system.failure.?);
    try std.testing.expect(value.targetFor(1).?.owner.eql(owner));
    try std.testing.expect((try value.publish(event(.ai_ready), day)).duplicate);
    try std.testing.expectEqual(@as(usize, 1), platform.notifications_sent);
}

test "notification attention follows exact original owner and actual read generation independent of quiet" {
    var platform: Platform = .{};
    var value = try notifications.Coordinator.init(a, .{ .transfer_done = true, .ai_ready = true }, platform.sink());
    defer value.deinit();
    try std.testing.expect(try value.observeOutput(owner, 8));
    try std.testing.expect(!try value.observeOutput(owner, 8));
    try std.testing.expect(!try value.observeOutput(owner, 7));
    try std.testing.expect(value.hasDot(owner));
    try std.testing.expect(!value.hasDot(other));
    try std.testing.expect(!value.markRead(other, 8, true));
    try std.testing.expect(!value.markRead(owner, 8, false));
    try std.testing.expect(!value.markRead(owner, 9, true));
    try std.testing.expect(value.markRead(owner, 7, true));
    try std.testing.expect(value.hasDot(owner));
    try std.testing.expect(value.markRead(owner, 8, true));
    try std.testing.expect(!value.hasDot(owner));
    _ = try value.observeOutput(other, 1);
    try std.testing.expect(value.hasDot(other));
    _ = try value.observeOutput(owner, 9);
    try std.testing.expect(value.hasDot(owner));
    var prefs: config.Notify = .{ .tab_dot = false };
    _ = try value.updatePolicy(prefs);
    try std.testing.expect(!value.hasDot(owner));
    prefs.tab_dot = true;
    _ = try value.updatePolicy(prefs);
    try std.testing.expect(value.hasDot(owner));
    try std.testing.expect(value.hasDot(other));
    try std.testing.expectEqual(@as(usize, 0), platform.notifications_sent);
    try std.testing.expectEqual(@as(usize, 0), value.records.items.len);
}

test "notification bell consumes real counters once throttles sound and preserves attention" {
    var platform: Platform = .{};
    var value = try notifications.Coordinator.init(a, .{ .transfer_done = true, .ai_ready = true }, platform.sink());
    defer value.deinit();
    _ = try value.observeOutput(owner, 1);
    try std.testing.expectEqual(.disabled, (try value.observeBell(owner, 1, day)).sound.disposition);
    var prefs: config.Notify = .{ .bell = true };
    _ = try value.updatePolicy(prefs);
    try std.testing.expect((try value.observeBell(owner, 1, day)).duplicate);
    try std.testing.expectEqual(.delivered, (try value.observeBell(owner, 2, day)).sound.disposition);
    try std.testing.expectEqual(.rate_limited, (try value.observeBell(owner, 3, .{ .local_minute = day.local_minute, .monotonic_ms = 999 })).sound.disposition);
    try std.testing.expectEqual(.delivered, (try value.observeBell(owner, 4, .{ .local_minute = day.local_minute, .monotonic_ms = 1000 })).sound.disposition);
    try std.testing.expectEqual(.quiet, (try value.observeBell(owner, 5, .{ .local_minute = 23 * 60, .monotonic_ms = 3000 })).sound.disposition);
    try std.testing.expect((try value.observeBell(owner, 5, .{ .local_minute = day.local_minute, .monotonic_ms = 4000 })).duplicate);
    try std.testing.expectEqual(@as(usize, 2), platform.bells);
    try std.testing.expect(value.hasDot(owner));
    prefs.bell = false;
    _ = try value.updatePolicy(prefs);
    try std.testing.expectEqual(.disabled, (try value.observeBell(owner, 6, day)).sound.disposition);
}

test "notification reconnect differentiates lost and recovered operation transitions and old owner clicks" {
    var platform: Platform = .{};
    var value = try notifications.Coordinator.init(a, .{ .transfer_done = true, .ai_ready = true }, platform.sink());
    defer value.deinit();
    var lost = event(.reconnect);
    lost.result = .disconnected;
    _ = try value.publish(lost, day);
    lost.event_id = 2;
    try std.testing.expect((try value.publish(lost, day)).duplicate);
    lost.event_id = 3;
    lost.result = .recovered;
    _ = try value.publish(lost, day);
    try std.testing.expectEqual(@as(usize, 2), platform.notifications_sent);
    try std.testing.expect(value.targetFor(1).?.owner.eql(owner));
    try std.testing.expect(value.targetFor(3).?.owner.eql(owner));
    try std.testing.expect(value.targetFor(99) == null);
    var collision = event(.ai_ready);
    collision.owner = other;
    try std.testing.expectError(error.EventIdentityConflict, value.publish(collision, day));
    var contradiction = event(.ai_ready);
    contradiction.event_id = 4;
    _ = try value.publish(contradiction, day);
    contradiction.event_id = 5;
    contradiction.result = .cancelled;
    try std.testing.expectError(error.OperationResultConflict, value.publish(contradiction, day));
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var platform: Platform = .{};
    var value = try notifications.Coordinator.init(allocator, .{ .transfer_done = true }, platform.sink());
    defer value.deinit();
    _ = value.publish(event(.transfer_done), day) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), platform.notifications_sent);
        try std.testing.expectEqual(@as(usize, 0), value.records.items.len);
        return err;
    };
    try std.testing.expectEqual(@as(usize, 1), platform.notifications_sent);
    _ = try value.observeOutput(owner, 1);
}
test "notification allocation failure never delivers an untracked fact or leaks owned summary" {
    try std.testing.checkAllAllocationFailures(a, allocationCase, .{});
}

test "notification all three saved event switches suppress real final facts without hiding records" {
    const kinds = [_]notifications.Kind{ .transfer_done, .reconnect, .ai_ready };
    for (kinds) |kind| {
        var platform: Platform = .{};
        var prefs: config.Notify = .{ .transfer_done = false, .reconnect = false, .ai_ready = false };
        var value = try notifications.Coordinator.init(a, prefs, platform.sink());
        defer value.deinit();
        var final = event(kind);
        if (kind == .reconnect) final.result = .recovered;
        const suppressed = try value.publish(final, day);
        try std.testing.expectEqual(.disabled, value.records.items[suppressed.record_index].system.disposition);
        try std.testing.expectEqual(final.result, value.records.items[suppressed.record_index].event.result);
        try std.testing.expectEqual(@as(usize, 0), platform.notifications_sent);
        prefs.transfer_done = true;
        prefs.reconnect = true;
        prefs.ai_ready = true;
        _ = try value.updatePolicy(prefs);
        final.event_id = 2;
        try std.testing.expect((try value.publish(final, day)).duplicate);
        final.event_id = 3;
        final.operation_id += 1;
        const enabled = try value.publish(final, day);
        try std.testing.expectEqual(.delivered, value.records.items[enabled.record_index].system.disposition);
        try std.testing.expectEqual(@as(usize, 1), platform.notifications_sent);
    }
}
