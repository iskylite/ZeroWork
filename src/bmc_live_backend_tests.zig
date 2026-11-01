//! Native TLS discovery regressions reuse the owned WEB/KVM fixture and the
//! repository's sanitized Sugon session/logout evidence. No device IO occurs.
const fixture = @import("bmc_native_driver_tests.zig");
const std = @import("std");
const controller = @import("plugins/bmc_ikvm/controller.zig");
const svc = @import("plugins/bmc_ikvm/services.zig");
const ledger = @import("plugins/bmc_ikvm/management_journal.zig");
const budgets = @import("host/frame_budget.zig");
const monotonic = @import("platform/realtime.zig");
const transports = @import("host/transport_factory.zig");
const resolution = @import("host/connection_config_resolver.zig");
const ssh = @import("proto/ssh/session.zig");

test "BMC live backend mapped reads retain owned power boot options and evidence without a write grant" {
    try fixture.liveBackendScenario(.mapped);
}

test "BMC live backend follows manager canonical system link beyond the collection alias and proves reciprocal mapping" {
    try fixture.liveBackendScenario(.manager_linked_system);
}

test "BMC live backend missing relationship preserves unique collection reads without mapping or writes" {
    try fixture.liveBackendScenario(.missing_mapping);
}

test "BMC live backend rejected manager canonical keeps safe status while projecting only the unique valid collection member" {
    try fixture.liveBackendScenario(.broken_canonical);
}

test "BMC live backend multiple or aliased collection members cannot select an unverified read projection" {
    try fixture.liveBackendScenario(.multiple_members);
}

test "BMC live backend multiple collection pages cannot select an unverified read projection" {
    try fixture.liveBackendScenario(.paged_members);
}

test "BMC live backend partial collection cannot authorize a read projection even with a clean member" {
    try fixture.liveBackendScenario(.partial_collection);
}

test "BMC live backend collection member without identity cannot supply an unverified read projection" {
    try fixture.liveBackendScenario(.missing_identity);
}

test "BMC live backend partial system document never promotes fields or mapping to valid" {
    try fixture.liveBackendScenario(.partial_mapping);
}

test "BMC live backend mapped document without observed fields stays unavailable" {
    try fixture.liveBackendScenario(.missing_fields);
}

const AvailabilityDriver = struct {
    available: std.atomic.Value(bool) = .init(false),
    fn begin(_: *anyopaque, _: *const controller.model.Payload, _: *const controller.route.Plan, _: svc.OperationKey, _: *const std.atomic.Value(bool)) !controller.video.rfb.Authenticated {
        return .{ .tls_trusted = true, .web_authenticated = true, .oem_authenticated = true };
    }
    fn read(_: *anyopaque, _: []u8) !usize {
        return error.WouldBlock;
    }
    fn write(_: *anyopaque, bytes: []const u8) !usize {
        return bytes.len;
    }
    fn abort(_: *anyopaque) void {}
    fn cleanup(_: *anyopaque) controller.Cleanup {
        return .released;
    }
    fn wait(_: *anyopaque, _: u32) void {
        var fds: [1]std.c.pollfd = undefined;
        _ = std.c.poll(&fds, 0, 1);
    }
    fn now(_: *anyopaque) u64 {
        return @intCast(monotonic.monotonicNs());
    }
    fn managementAvailable(raw: *anyopaque) bool {
        const self: *AvailabilityDriver = @ptrCast(@alignCast(raw));
        return self.available.load(.acquire);
    }
    fn driver(self: *AvailabilityDriver) controller.Driver {
        return .{ .context = self, .begin = begin, .read = read, .write = write, .abort = abort, .cleanup = cleanup, .wait = wait, .now_ns = now, .management_available = managementAvailable };
    }
};

test "BMC live backend controller reports management from observed reads rather than WEB authentication" {
    const a = std.testing.allocator;
    const owner: svc.identity.SessionHandle = .{ .session_id = @fromBackingInt(903), .generation = 2 };
    const operation: svc.OperationKey = .{ .owner = .{ .session = owner }, .operation_id = 81 };
    var budget = budgets.Budget.init(128 * 1024 * 1024);
    defer budget.deinit() catch unreachable;
    var journal_backend: ledger.MemoryBackend = .{ .allocator = a };
    defer journal_backend.deinit();
    var journal = try ledger.Journal.init(a, journal_backend.backend());
    defer journal.deinit();
    const control = try controller.Controller.create(a, owner, operation, .{ .endpoint = .{ .host = "bmc.invalid" }, .username = "fixture" }, null, &budget, &journal, null);
    defer {
        control.cancel();
        while (!control.poll().worker_exited) AvailabilityDriver.wait(control, 1);
        control.deinit() catch unreachable;
    }
    var backend: AvailabilityDriver = .{};
    try control.startPrepared(backend.driver());
    const deadline = AvailabilityDriver.now(&backend) + 2 * std.time.ns_per_s;
    while (control.poll().route != .connected) {
        if (control.poll().failure) |failure| return failure;
        if (AvailabilityDriver.now(&backend) >= deadline) return error.ControllerStartTimeout;
        AvailabilityDriver.wait(&backend, 1);
    }
    try std.testing.expectEqual(controller.ManagementState.unavailable, control.poll().management);
    backend.available.store(true, .release);
    while (control.poll().management != .available) {
        if (AvailabilityDriver.now(&backend) >= deadline) return error.ManagementProjectionTimeout;
        AvailabilityDriver.wait(&backend, 1);
    }
    backend.available.store(false, .release);
    while (control.poll().management != .unavailable) {
        if (AvailabilityDriver.now(&backend) >= deadline) return error.ManagementProjectionTimeout;
        AvailabilityDriver.wait(&backend, 1);
    }
    try std.testing.expectEqual(@as(usize, 0), journal_backend.writes);
    try std.testing.expect(control.poll().failure == null);
}

test "BMC live backend retained cleanup policy still rejects cancelled prepare connect and stream opens" {
    const a = std.testing.allocator;
    const owner: svc.identity.SessionHandle = .{ .session_id = @fromBackingInt(904), .generation = 1 };
    var library: ssh.Library = .{ .active = false };
    var cancel: std.atomic.Value(bool) = .init(true);
    var route: resolution.FrozenRoute = .{ .arena = .init(a), .store_revision = 1, .hops = &.{} };
    defer route.deinit();
    const factory: transports.Factory = .{ .allocator = a, .library = &library, .keep_established_until_close = true };
    try std.testing.expectError(error.Cancelled, factory.prepareOwned(.{ .session = owner }, &route, .connection, &cancel));
    cancel.store(false, .release);
    const owned = try factory.prepareOwned(.{ .session = owner }, &route, .connection, &cancel);
    defer owned.deinit() catch unreachable;
    cancel.store(true, .release);
    try std.testing.expectError(error.Cancelled, owned.start());
    try std.testing.expectError(error.Cancelled, owned.openTcpStream(.{ .host = "127.0.0.1", .port = 1 }));
    try std.testing.expect(!owned.started and owned.thread == null);
    try std.testing.expectEqual(transports.ReleaseReceipt.released, owned.close());
}
