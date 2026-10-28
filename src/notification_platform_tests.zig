const std = @import("std");
const platform = @import("platform/notifications.zig");
const notifications = @import("host/notification_coordinator.zig");
const a = std.testing.allocator;
const target: notifications.Target = .{
    .owner = .{ .session = .{ .session_id = @fromBackingInt(9_007_199_254_740_993), .generation = 17 } },
    .kind = .ai_ready,
    .operation_id = 9_007_199_254_740_995,
    .attempt_or_turn_id = 19,
};
const authorized: platform.RawSettings = .{ .authorization = 3, .alert_setting = 2, .center_setting = 2, .sound_setting = 1 };
const day: notifications.Clock = .{ .local_minute = 12 * 60, .monotonic_ms = 0 };

const Fake = struct {
    var active: ?*Fake = null;
    capabilities: platform.RawCapabilities = .{ .system_notifications = 1, .authorization_request = 1, .activation = 1, .bell = 1 },
    creates: usize = 0,
    destroys: usize = 0,
    queries: usize = 0,
    requests: usize = 0,
    sends: usize = 0,
    rings: usize = 0,
    polls: usize = 0,
    send_status: c_int = 0,
    last_query: u64 = 0,
    last_permission: u64 = 0,
    last_send: u64 = 0,
    last_event: u64 = 0,
    last_target: platform.RawTarget = .{},
    last_body: [512]u8 = @splat(0),
    last_body_len: usize = 0,
    events: [32]platform.RawEvent = undefined,
    written: usize = 0,
    read: usize = 0,

    fn api(self: *Fake) platform.Api {
        active = self;
        return .{ .create = create, .destroy = destroy, .capabilities = capabilitiesFn, .query_settings = query, .request_authorization = request, .send = send, .poll = poll, .ring = ring };
    }
    fn get(handle: *platform.Handle) *Fake {
        return @ptrCast(@alignCast(handle));
    }
    fn create(status: *c_int) callconv(.c) ?*platform.Handle {
        const self = active.?;
        self.creates += 1;
        status.* = 0;
        return @ptrCast(self);
    }
    fn destroy(handle: *platform.Handle) callconv(.c) void {
        get(handle).destroys += 1;
    }
    fn capabilitiesFn(handle: *platform.Handle, out: *platform.RawCapabilities) callconv(.c) c_int {
        out.* = get(handle).capabilities;
        return 0;
    }
    fn query(handle: *platform.Handle, request_id: u64) callconv(.c) c_int {
        const self = get(handle);
        self.queries += 1;
        self.last_query = request_id;
        return 0;
    }
    fn request(handle: *platform.Handle, request_id: u64, explicit: u32) callconv(.c) c_int {
        const self = get(handle);
        if (explicit != 1) return 2;
        self.requests += 1;
        self.last_permission = request_id;
        return 0;
    }
    fn send(handle: *platform.Handle, request_id: u64, event_id: u64, raw_target: *const platform.RawTarget, body: [*]const u8, len: usize) callconv(.c) c_int {
        const self = get(handle);
        self.sends += 1;
        self.last_send = request_id;
        self.last_event = event_id;
        self.last_target = raw_target.*;
        self.last_body_len = @min(len, self.last_body.len);
        @memcpy(self.last_body[0..self.last_body_len], body[0..self.last_body_len]);
        return self.send_status;
    }
    fn poll(handle: *platform.Handle, out: *platform.RawEvent) callconv(.c) c_int {
        const self = get(handle);
        self.polls += 1;
        if (self.read == self.written) return 0;
        out.* = self.events[self.read];
        self.read += 1;
        return 1;
    }
    fn ring(handle: *platform.Handle) callconv(.c) c_int {
        get(handle).rings += 1;
        return 0;
    }
    fn push(self: *Fake, value: platform.RawEvent) void {
        self.events[self.written] = value;
        self.written += 1;
    }
    fn reportAuthorization(self: *Fake, driver: *platform.Driver, settings: platform.RawSettings) !void {
        self.push(.{ .kind = 1, .result = 1, .request_id = self.last_query, .settings = settings });
        _ = (try driver.poll()).?.settings;
    }
    fn reportSend(self: *Fake, result: u32) void {
        self.push(.{ .kind = 3, .result = result, .request_id = self.last_send, .event_id = self.last_event, .target = self.last_target, .settings = authorized });
    }
};

fn event(id: u64) notifications.Event {
    return .{ .event_id = id, .kind = target.kind, .owner = target.owner, .operation_id = target.operation_id, .attempt_or_turn_id = target.attempt_or_turn_id, .result = .succeeded, .summary = "回答已完成", .terminal_confirmed = true, .resources_released = true, .final_answer = true };
}

test "notification native adapter queries without prompt and only explicit action requests actual permission" {
    var fake: Fake = .{};
    var driver = try platform.Driver.initWithApi(a, fake.api());
    defer driver.deinit();
    try std.testing.expectEqual(@as(usize, 1), fake.queries);
    try std.testing.expectEqual(@as(usize, 0), fake.requests);
    try std.testing.expectEqual(@as(usize, 0), fake.sends);
    try std.testing.expectEqual(@as(usize, 0), fake.rings);
    try std.testing.expect(driver.settings == null);
    try std.testing.expectError(error.AuthorizationQueryPending, driver.refreshAuthorization());
    try fake.reportAuthorization(&driver, .{ .authorization = 1, .alert_setting = 1, .center_setting = 1, .sound_setting = 1 });
    try std.testing.expectEqual(.not_determined, driver.settings.?.authorization);
    var coordinator = try notifications.Coordinator.init(a, .{}, driver.sink());
    defer coordinator.deinit();
    _ = try coordinator.updatePolicy(.{ .quiet_hours = "00:00-00:00", .bell = true });
    try std.testing.expectEqual(@as(usize, 0), fake.requests);
    const permission = try driver.requestAuthorization(.enable_system_notifications);
    try std.testing.expectEqual(@as(usize, 1), fake.requests);
    try std.testing.expectError(error.AuthorizationRequestPending, driver.requestAuthorization(.enable_system_notifications));
    fake.push(.{ .kind = 2, .result = 1, .request_id = permission, .granted = 0, .settings = .{ .authorization = 2, .alert_setting = 1, .center_setting = 1, .sound_setting = 1 } });
    const denied = (try driver.poll()).?.settings;
    try std.testing.expect(denied.explicit_request and !denied.granted and denied.failure == null);
    try std.testing.expectEqual(.denied, denied.value.authorization);
    try std.testing.expectEqual(.denied, driver.settings.?.authorization);
    try std.testing.expectEqual(@as(usize, 0), fake.sends);
}

test "notification native adapter and coordinator retain pending until matching async scheduled receipt" {
    var fake: Fake = .{};
    var driver = try platform.Driver.initWithApi(a, fake.api());
    defer driver.deinit();
    try fake.reportAuthorization(&driver, authorized);
    var coordinator = try notifications.Coordinator.init(a, .{}, driver.sink());
    defer coordinator.deinit();
    const published = try coordinator.publish(event(41), day);
    try std.testing.expectEqual(.pending, coordinator.records.items[published.record_index].system.disposition);
    try std.testing.expectEqual(@as(usize, 1), fake.sends);
    try std.testing.expect(try driver.poll() == null);
    try std.testing.expectEqual(.pending, coordinator.records.items[published.record_index].system.disposition);
    fake.reportSend(2);
    const receipt = (try driver.poll()).?.system;
    try std.testing.expectEqual(.scheduled, receipt.result);
    try std.testing.expect(std.meta.eql(target, receipt.target));
    try std.testing.expect(try coordinator.reportSystemResult(receipt.event_id, receipt.target, .scheduled));
    try std.testing.expectEqual(.scheduled, coordinator.records.items[published.record_index].system.disposition);
    try std.testing.expect(!try coordinator.reportSystemResult(receipt.event_id, receipt.target, .scheduled));
    try std.testing.expectError(error.SystemResultConflict, coordinator.reportSystemResult(receipt.event_id, receipt.target, .{ .failed = error.NativeNotificationFailed }));
    try std.testing.expect((try coordinator.publish(event(41), day)).duplicate);
    try std.testing.expectEqual(@as(usize, 1), fake.sends);
}

test "notification native failure preserves terminal fact original owner error and no automatic replay" {
    var fake: Fake = .{};
    var driver = try platform.Driver.initWithApi(a, fake.api());
    defer driver.deinit();
    try fake.reportAuthorization(&driver, authorized);
    var coordinator = try notifications.Coordinator.init(a, .{}, driver.sink());
    defer coordinator.deinit();
    const published = try coordinator.publish(event(42), day);
    var failed: platform.RawEvent = .{ .kind = 3, .result = 3, .request_id = fake.last_send, .event_id = fake.last_event, .target = fake.last_target, .settings = .{ .authorization = 2 }, .error_code = 17 };
    @memcpy(failed.error_domain[0..13], "UNErrorDomain");
    @memcpy(failed.error_detail[0..15], "Permission lost");
    fake.push(failed);
    const receipt = (try driver.poll()).?.system;
    try std.testing.expectEqual(.failed, receipt.result);
    var issue = receipt.failure.?;
    try std.testing.expectEqual(@as(i64, 17), issue.code);
    try std.testing.expectEqualStrings("UNErrorDomain", issue.domainText());
    try std.testing.expectEqualStrings("Permission lost", issue.detailText());
    try std.testing.expectEqual(.denied, driver.settings.?.authorization);
    try std.testing.expect(try coordinator.reportSystemResult(receipt.event_id, receipt.target, .{ .failed = error.NativeNotificationFailed }));
    try std.testing.expectEqual(.failed, coordinator.records.items[published.record_index].system.disposition);
    try std.testing.expectEqual(.succeeded, coordinator.records.items[published.record_index].event.result);
    coordinator.reportAuthorization(.authorized);
    _ = try coordinator.updatePolicy(.{ .quiet_hours = "00:00-00:00" });
    try std.testing.expect((try coordinator.publish(event(42), day)).duplicate);
    try std.testing.expectEqual(@as(usize, 1), fake.sends);
    try std.testing.expectEqual(@as(usize, 0), fake.requests);
}

test "notification native payload copies borrowed text and roundtrips exact wide identities and owner kinds" {
    var fake: Fake = .{};
    var driver = try platform.Driver.initWithApi(a, fake.api());
    defer driver.deinit();
    var body = [_]u8{ 'd', 'o', 'n', 'e' };
    _ = try driver.send(.{ .event_id = 51, .summary = &body, .target = target });
    @memset(&body, 'x');
    try std.testing.expectEqualStrings("done", fake.last_body[0..fake.last_body_len]);
    try std.testing.expectEqual(@as(u64, 9_007_199_254_740_993), fake.last_target.owner_id);
    try std.testing.expectEqual(@as(u64, 9_007_199_254_740_995), fake.last_target.operation_id);
    try std.testing.expect(std.meta.eql(target, try platform.decodeTarget(fake.last_target)));
    try std.testing.expectError(error.DuplicateNotificationEvent, driver.send(.{ .event_id = 51, .summary = "done", .target = target }));
    for ([_]notifications.Owner{
        .{ .group = .{ .id = @fromBackingInt(std.math.maxInt(u64)), .revision = std.math.maxInt(u64) } },
        .{ .history = @fromBackingInt(std.math.maxInt(u64)) },
    }) |owner| {
        var value = target;
        value.owner = owner;
        value.attempt_or_turn_id = null;
        try std.testing.expect(std.meta.eql(value, try platform.decodeTarget(try platform.encodeTarget(value))));
    }
    var invalid = try platform.encodeTarget(target);
    invalid.owner_revision = 0;
    try std.testing.expectError(error.InvalidNotificationIdentity, platform.decodeTarget(invalid));
}

test "notification native activation cannot bind original owner to another generation or foreign launch" {
    var fake: Fake = .{};
    var driver = try platform.Driver.initWithApi(a, fake.api());
    defer driver.deinit();
    _ = try driver.send(.{ .event_id = 61, .summary = "done", .target = target });
    var click: platform.RawEvent = .{ .kind = 4, .result = 1, .event_id = 61, .target = try platform.encodeTarget(target), .current_instance = 1 };
    click.target.owner_revision += 1;
    fake.push(click);
    try std.testing.expectError(error.NotificationIdentityConflict, driver.poll());
    click.target.owner_revision -= 1;
    fake.push(click);
    const own = (try driver.poll()).?.activation;
    try std.testing.expect(own.current_instance and std.meta.eql(own.target, target));
    click.event_id = 999;
    fake.push(click);
    try std.testing.expectError(error.UnknownNotificationActivation, driver.poll());
    click.current_instance = 0;
    fake.push(click);
    const old_launch = (try driver.poll()).?.activation;
    try std.testing.expect(!old_launch.current_instance);
    try std.testing.expect(std.meta.eql(target, old_launch.target));
    try std.testing.expectEqual(@as(usize, 1), fake.sends);
}

test "notification native completion rejects stale wrong-owner or duplicate reports before altering state" {
    var fake: Fake = .{};
    var driver = try platform.Driver.initWithApi(a, fake.api());
    defer driver.deinit();
    const request_id = try driver.send(.{ .event_id = 71, .summary = "done", .target = target });
    var completion: platform.RawEvent = .{ .kind = 3, .result = 2, .request_id = request_id, .event_id = 71, .target = fake.last_target, .settings = authorized };
    completion.target.owner_revision += 1;
    fake.push(completion);
    try std.testing.expectError(error.NotificationIdentityConflict, driver.poll());
    try std.testing.expect(driver.settings == null);
    completion.target.owner_revision -= 1;
    fake.push(completion);
    _ = (try driver.poll()).?.system;
    fake.push(completion);
    try std.testing.expectError(error.DuplicateNativeNotificationCompletion, driver.poll());
    completion.request_id = 9999;
    fake.push(completion);
    try std.testing.expectError(error.UnknownNotificationRequest, driver.poll());
    fake.push(.{ .kind = 5, .result = 3, .dropped_events = 2 });
    try std.testing.expectEqual(@as(u64, 2), (try driver.poll()).?.queue_failure.dropped_events);
}

test "notification native bare-executable capability is honest and Bell is independent of alert permission" {
    var fake: Fake = .{ .capabilities = .{ .bell = 1, .unavailable_reason = 1 } };
    var driver = try platform.Driver.initWithApi(a, fake.api());
    defer driver.deinit();
    try std.testing.expectEqual(.no_app_bundle, driver.capabilities.unavailable_reason);
    try std.testing.expectEqual(@as(usize, 0), fake.queries);
    try std.testing.expectError(error.NotificationUnavailable, driver.requestAuthorization(.enable_system_notifications));
    var coordinator = try notifications.Coordinator.init(a, .{ .bell = true }, driver.sink());
    defer coordinator.deinit();
    const published = try coordinator.publish(event(81), day);
    try std.testing.expectEqual(.unsupported, coordinator.records.items[published.record_index].system.disposition);
    const bell = try coordinator.observeBell(target.owner, 1, day);
    try std.testing.expectEqual(.delivered, bell.sound.disposition);
    try std.testing.expectEqual(@as(usize, 1), fake.rings);
    try std.testing.expectEqual(@as(usize, 0), fake.sends);
    try std.testing.expectEqual(@as(usize, 0), fake.requests);
}

test "notification native closed adapter owns no callback target and never polls or sends after release" {
    var fake: Fake = .{};
    var driver = try platform.Driver.initWithApi(a, fake.api());
    _ = try driver.requestAuthorization(.enable_system_notifications);
    _ = try driver.send(.{ .event_id = 91, .summary = "done", .target = target });
    driver.deinit();
    fake.reportSend(2); // A late native value has no pointer into the destroyed Zig state.
    try std.testing.expectError(error.NotificationDriverClosed, driver.poll());
    try std.testing.expectError(error.NotificationDriverClosed, driver.requestAuthorization(.enable_system_notifications));
    try std.testing.expectError(error.NotificationDriverClosed, driver.send(.{ .event_id = 92, .summary = "done", .target = target }));
    try std.testing.expectError(error.NotificationDriverClosed, driver.ring());
    try std.testing.expectEqual(@as(usize, 0), fake.polls);
    try std.testing.expectEqual(@as(usize, 1), fake.destroys);
    driver.deinit();
    try std.testing.expectEqual(@as(usize, 1), fake.destroys);
}

test "notification native old settings query and send cannot overwrite explicit authorization result" {
    var fake: Fake = .{};
    var driver = try platform.Driver.initWithApi(a, fake.api());
    defer driver.deinit();
    const initial_query = fake.last_query;
    const permission = try driver.requestAuthorization(.enable_system_notifications);
    const send_id = try driver.send(.{ .event_id = 101, .summary = "done", .target = target });
    fake.push(.{ .kind = 2, .result = 1, .request_id = permission, .granted = 1, .settings = authorized });
    try std.testing.expect((try driver.poll()).?.settings.current_settings);
    fake.push(.{ .kind = 1, .result = 1, .request_id = initial_query, .settings = .{ .authorization = 1 } });
    try std.testing.expect(!(try driver.poll()).?.settings.current_settings);
    try std.testing.expectEqual(.authorized, driver.settings.?.authorization);
    fake.push(.{ .kind = 3, .result = 3, .request_id = send_id, .event_id = 101, .target = fake.last_target, .settings = .{ .authorization = 1 } });
    const old_send = (try driver.poll()).?.system;
    try std.testing.expectEqual(.failed, old_send.result);
    try std.testing.expect(!old_send.current_settings);
    try std.testing.expectEqual(.authorized, driver.settings.?.authorization);
    try std.testing.expectEqual(@as(usize, 1), fake.requests);
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var fake: Fake = .{};
    var driver = platform.Driver.initWithApi(allocator, fake.api()) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), fake.queries);
        try std.testing.expectEqual(@as(usize, 1), fake.destroys);
        return err;
    };
    defer driver.deinit();
    for (0..9) |at| {
        _ = driver.send(.{ .event_id = at + 1, .summary = "done", .target = target }) catch |err| {
            try std.testing.expectEqual(at, fake.sends);
            return err;
        };
        try std.testing.expectEqual(at + 1, fake.sends);
    }
}

test "notification native allocation failure precedes external query or send and releases native ownership" {
    try std.testing.checkAllAllocationFailures(a, allocationCase, .{});
}

const notification_host = @import("host/notification_host.zig");
const WindowProbe = struct {
    activates: usize = 0,
    messages: usize = 0,
    owner: notifications.Owner = target.owner,
    fn callbacks(self: *WindowProbe) notification_host.Window {
        return .{ .context = self, .owns = owns, .activate = activate, .feedback = feedback };
    }
    fn owns(raw: *anyopaque, value: notifications.Target) bool {
        const self: *WindowProbe = @ptrCast(@alignCast(raw));
        return self.owner.eql(value.owner);
    }
    fn activate(raw: *anyopaque, value: notifications.Target) bool {
        const self: *WindowProbe = @ptrCast(@alignCast(raw));
        if (!owns(raw, value)) return false;
        self.activates += 1;
        return true;
    }
    fn feedback(raw: *anyopaque, _: []const u8) void {
        const self: *WindowProbe = @ptrCast(@alignCast(raw));
        self.messages += 1;
    }
};

test "notification process host sends only released final AI and each transfer intent choice survives global policy" {
    var fake: Fake = .{};
    const host = try notification_host.Host.createWithApi(a, .{ .quiet_hours = "00:00-00:00" }, fake.api());
    defer host.destroy();
    fake.push(.{ .kind = 1, .result = 1, .request_id = fake.last_query, .settings = authorized });
    _ = try host.poll();
    try std.testing.expectError(error.AnswerNotFinal, host.publishAi(target.owner, 1, 1, .{ .result = .succeeded, .resources_released = false, .final_answer = true }));
    try std.testing.expectEqual(@as(usize, 0), fake.sends);
    try host.publishAi(target.owner, 1, 1, .{ .result = .succeeded, .resources_released = true, .final_answer = true });
    try host.publishAi(target.owner, 1, 1, .{ .result = .succeeded, .resources_released = true, .final_answer = true });
    try std.testing.expectEqual(@as(usize, 1), fake.sends);
    fake.reportSend(2);
    _ = try host.poll();
    try std.testing.expectEqual(.scheduled, host.coordinator.records.items[0].system.disposition);
    try host.publishAi(target.owner, 2, 2, .{ .result = .unverified, .resources_released = true });
    const before_cancel = host.coordinator.records.items.len;
    try host.publishAi(target.owner, 3, 3, .{ .result = .cancelled, .resources_released = true });
    try std.testing.expectEqual(before_cancel, host.coordinator.records.items.len);
    try host.publishTransfer(target.owner, 1, 1, .{ .result = .succeeded, .resources_released = true, .notify_complete = false });
    try std.testing.expectEqual(@as(usize, 1), fake.sends);
    const transfer_record = for (host.coordinator.records.items) |record| {
        if (record.event.kind == .transfer_done and record.event.owner.eql(target.owner) and
            record.event.operation_id == 1 and record.event.attempt_or_turn_id == 1) break record;
    } else return error.TestExpectedTransferNotification;
    try std.testing.expect(!transfer_record.event.system_enabled);
    try std.testing.expectEqual(.disabled, transfer_record.system.disposition);
    try host.updatePolicy(.{ .transfer_done = false, .quiet_hours = "00:00-00:00" });
    try host.publishTransfer(target.owner, 2, 1, .{ .result = .succeeded, .resources_released = true, .notify_complete = true });
    try std.testing.expectEqual(@as(usize, 1), fake.sends);
    try host.updatePolicy(.{ .quiet_hours = "00:00-00:00" });
    try host.publishTransfer(target.owner, 3, 1, .{ .result = .succeeded, .resources_released = true, .notify_complete = true });
    try std.testing.expectEqual(@as(usize, 2), fake.sends);
}

test "notification process host permissions and notification clicks retain registered original window owner" {
    var fake: Fake = .{};
    const host = try notification_host.Host.createWithApi(a, .{ .quiet_hours = "00:00-00:00" }, fake.api());
    defer host.destroy();
    var original: WindowProbe = .{};
    var other: WindowProbe = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(5), .generation = 1 } } };
    const original_id = try host.registerWindow(original.callbacks());
    _ = try host.registerWindow(other.callbacks());
    try host.requestAuthorization(original_id);
    fake.push(.{ .kind = 2, .result = 1, .request_id = fake.last_permission, .granted = 1, .settings = authorized });
    _ = try host.poll();
    try std.testing.expectEqual(@as(usize, 1), original.messages);
    try std.testing.expectEqual(@as(usize, 0), other.messages);
    const operation = try host.reserveAiOperation(original_id);
    try host.publishAi(target.owner, operation, target.attempt_or_turn_id.?, .{ .result = .succeeded, .resources_released = true, .final_answer = true });
    fake.push(.{ .kind = 4, .result = 1, .event_id = fake.last_event, .target = fake.last_target, .current_instance = 1 });
    _ = try host.poll();
    try std.testing.expectEqual(@as(usize, 1), original.activates);
    try std.testing.expectEqual(@as(usize, 0), other.activates);
    host.removeWindow(original_id);
    fake.push(.{ .kind = 4, .result = 1, .event_id = fake.last_event, .target = fake.last_target, .current_instance = 1 });
    _ = try host.poll();
    try std.testing.expectEqual(@as(usize, 1), original.activates);
    try std.testing.expectEqual(@as(usize, 0), other.activates);
    try std.testing.expectEqual(@as(usize, 1), other.messages);
    try std.testing.expectError(error.NotificationWindowClosed, host.requestAuthorization(original_id));
}

test "notification process AI operations never route equal group numbers or closed origins into another window" {
    var fake: Fake = .{};
    const host = try notification_host.Host.createWithApi(a, .{ .quiet_hours = "00:00-00:00" }, fake.api());
    defer host.destroy();
    const group: notifications.Owner = .{ .group = .{ .id = @fromBackingInt(1), .revision = 1 } };
    var first: WindowProbe = .{ .owner = group };
    var second: WindowProbe = .{ .owner = group };
    const first_id = try host.registerWindow(first.callbacks());
    const second_id = try host.registerWindow(second.callbacks());
    fake.push(.{ .kind = 1, .result = 1, .request_id = fake.last_query, .settings = authorized });
    _ = try host.poll();
    const first_op = try host.reserveAiOperation(first_id);
    const second_op = try host.reserveAiOperation(second_id);
    try std.testing.expect(first_op != second_op);
    try host.publishAi(group, second_op, 1, .{ .result = .succeeded, .resources_released = true, .final_answer = true });
    fake.push(.{ .kind = 4, .result = 1, .event_id = fake.last_event, .target = fake.last_target, .current_instance = 1 });
    _ = try host.poll();
    try std.testing.expectEqual(@as(usize, 0), first.activates);
    try std.testing.expectEqual(@as(usize, 1), second.activates);
    host.removeWindow(second_id);
    fake.push(.{ .kind = 4, .result = 1, .event_id = fake.last_event, .target = fake.last_target, .current_instance = 1 });
    _ = try host.poll();
    try std.testing.expectEqual(@as(usize, 0), first.activates);
    try std.testing.expectEqual(@as(usize, 1), second.activates);
    try std.testing.expectEqual(@as(usize, 1), first.messages);
    fake.push(.{ .kind = 4, .result = 1, .event_id = fake.last_event, .target = fake.last_target, .current_instance = 0 });
    _ = try host.poll();
    try std.testing.expectEqual(@as(usize, 0), first.activates);
}

test "notification permission feedback retains waiting and native failure independently of not determined settings" {
    var fake: Fake = .{};
    const host = try notification_host.Host.createWithApi(a, .{}, fake.api());
    defer host.destroy();
    var window: WindowProbe = .{};
    const id = try host.registerWindow(window.callbacks());
    try std.testing.expect(host.authorization_feedback == null);
    try host.requestAuthorization(id);
    try std.testing.expectEqualStrings("正在等待系统通知授权结果…", host.authorization_feedback.?);
    var failed: platform.RawEvent = .{ .kind = 2, .result = 3, .request_id = fake.last_permission, .settings = .{ .authorization = 1 }, .error_code = 1 };
    const domain = "test.\"notifications";
    const detail = "request failed\nwith \\ detail";
    @memcpy(failed.error_domain[0..domain.len], domain);
    @memcpy(failed.error_detail[0..detail.len], detail);
    fake.push(failed);
    _ = try host.poll();
    try std.testing.expectEqualStrings("系统通知授权请求失败", host.authorization_feedback.?);
    try std.testing.expectEqual(.not_determined, host.driver.settings.?.authorization);
    try std.testing.expectEqual(@as(i64, 1), host.last_failure.?.code);
}

test "ordinary feedback stays quiet and explicitly typed failure retains severity independent of title" {
    var fake: Fake = .{};
    const host = try notification_host.Host.createWithApi(a, .{ .quiet_hours = "00:00-00:00" }, fake.api());
    defer host.destroy();
    var window: WindowProbe = .{};
    const id = try host.registerWindow(window.callbacks());
    host.setWindowFocus(id, false);
    try host.publishFeedback(id, target.owner, "已复制");
    try std.testing.expectEqual(@as(usize, 0), host.coordinator.notification_records.items.len);
    try host.publishFeedbackSeverity(id, target.owner, "连接失败: ChallengeTimeout", .failure);
    try host.publishFeedbackSeverity(id, target.owner, "连接失败: ChallengeTimeout", .failure);
    try std.testing.expectEqual(@as(usize, 1), host.coordinator.notification_records.items.len);
    const fact = host.coordinator.notification_records.items[0];
    try std.testing.expectEqualStrings("host.feedback", fact.event.definition_id);
    try std.testing.expectEqualStrings("连接失败: ChallengeTimeout", fact.event.title);
    try std.testing.expectEqual(.failure, fact.event.severity);
    try std.testing.expectEqual(.failed, fact.event.phase);
    try std.testing.expect(!fact.event.system_enabled);
    try std.testing.expect(!host.coordinator.hasDot(target.owner));
    try std.testing.expectEqual(@as(usize, 0), fake.sends);
}

test "notification closing window revokes borrowed action handlers and preserves result facts" {
    const Handler = struct {
        calls: usize = 0,
        fn invoke(raw: *anyopaque, _: notifications.NotificationEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
        }
    };
    var fake: Fake = .{};
    const host = try notification_host.Host.createWithApi(a, .{}, fake.api());
    defer host.destroy();
    var window: WindowProbe = .{};
    const id = try host.registerWindow(window.callbacks());
    try host.bindOwner(.{ .window_id = @backingInt(id), .content = target.owner });
    var handler: Handler = .{};
    const action_id = try host.registerAction(target.owner, .view_result, .{ .context = &handler, .invoke = Handler.invoke });
    const publication = try host.publish(.{ .definition_id = "host.feedback", .owner = .{ .window_id = @backingInt(id), .content = target.owner }, .operation_id = 8, .event_revision = 1, .phase = .outcome_unknown, .title = "结果未知", .actions = &.{.{ .kind = .view_result, .label = "查看结果", .action_id = action_id }} });
    try host.dispatchAction(publication.fact_id, 0);
    try std.testing.expectEqual(@as(usize, 1), handler.calls);
    host.removeWindow(id);
    try std.testing.expectEqual(@as(usize, 0), host.actions.items.len);
    try std.testing.expectEqual(@as(usize, 0), host.bound_owners.items.len);
    try std.testing.expectError(error.NotificationOwnerEnded, host.dispatchAction(publication.fact_id, 0));
    try std.testing.expectEqual(@as(usize, 1), handler.calls);
    try std.testing.expectEqual(notifications.Phase.outcome_unknown, host.coordinator.recordFor(publication.fact_id).?.event.phase);
}

test "visible results stay quiet while background results and failures remain available" {
    const Presented = struct {
        fn result(_: *anyopaque, _: notifications.Kind, _: notifications.Owner) bool {
            return true;
        }
    };
    var fake: Fake = .{};
    const host = try notification_host.Host.createWithApi(a, .{ .quiet_hours = "00:00-00:00" }, fake.api());
    defer host.destroy();
    fake.push(.{ .kind = 1, .result = 1, .request_id = fake.last_query, .settings = authorized });
    _ = try host.poll();
    var window: WindowProbe = .{};
    var callbacks = window.callbacks();
    callbacks.result_presented = Presented.result;
    _ = try host.registerWindow(callbacks);
    try host.publishAi(target.owner, 10, 1, .{ .result = .succeeded, .resources_released = true, .final_answer = true });
    try std.testing.expectEqual(@as(usize, 0), host.coordinator.presentation_count);
    try std.testing.expectEqual(@as(usize, 0), fake.sends);
    host.windows.items[0].value.result_presented = null;
    try host.publishAi(target.owner, 11, 1, .{ .result = .succeeded, .resources_released = true, .final_answer = true });
    try std.testing.expectEqual(@as(usize, 1), host.coordinator.presentation_count);
    try std.testing.expectEqual(@as(usize, 1), fake.sends);
    host.windows.items[0].value.result_presented = Presented.result;
    try host.publishAi(target.owner, 12, 1, .{ .result = .failed, .resources_released = true });
    try std.testing.expectEqual(@as(usize, 2), host.coordinator.presentation_count);
    try host.publishAi(target.owner, 13, 1, .{ .result = .cancelled, .resources_released = true });
    try std.testing.expectEqual(@as(usize, 2), host.coordinator.presentation_count);
}

test "reconnect attempts replace previous notices for the same session" {
    var fake: Fake = .{};
    const host = try notification_host.Host.createWithApi(a, .{ .quiet_hours = "00:00-00:00" }, fake.api());
    defer host.destroy();
    var window: WindowProbe = .{};
    _ = try host.registerWindow(window.callbacks());
    try host.publishReconnect(target.owner, 50, 1, .disconnected);
    try host.publishReconnect(target.owner, 50, 2, .failed);
    try host.publishReconnect(target.owner, 50, 3, .failed);
    try std.testing.expectEqual(@as(usize, 1), host.coordinator.presentation_count);
    try std.testing.expectEqual(@as(u64, 3), host.coordinator.notification_records.items[2].event.attempt_id);
}
