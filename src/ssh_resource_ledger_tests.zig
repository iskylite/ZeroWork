//! Focused connection ownership tests. No GUI or remote endpoint is used.
const std = @import("std");
const ssh = @import("proto/ssh/session.zig");
const operations = @import("host/operation.zig");
const Worker = @import("vt/ssh_worker.zig").SshWorker;
const SharedTransfer = @import("proto/ssh/shared_transfer_service.zig").Service;
const native = @import("generated_ssh_session");
const runtime = @import("ui/session_runtime.zig");
const probe = @import("ui/wizard_probe.zig");

fn key() operations.OperationKey {
    return .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(71), .generation = 3 } }, .operation_id = 81, .attempt_id = 4 };
}

test "resource ledger rejects stale owners and unknown cleanup blocks a new transport" {
    var ledger = try ssh.ResourceLedger.init(key(), 2);
    var stale = key();
    stale.attempt_id = 3;
    try std.testing.expect(!ledger.record(stale, 0, .transport, .owned));
    try std.testing.expect(!ledger.record(key(), 2, .transport, .owned));
    try std.testing.expect(ledger.record(key(), 1, .transport, .owned));
    try std.testing.expect(ledger.record(key(), 1, .transport, .unknown));
    try std.testing.expectError(error.CleanupNotReleased, ledger.beginNextTransport());
    const unknown = ledger.snapshot();
    try std.testing.expect(unknown.hasUnknown() and !unknown.released());
    try std.testing.expect(!ledger.record(stale, 1, .transport, .released));
    try std.testing.expect(ledger.record(key(), 1, .transport, .released));
    try ledger.beginNextTransport();
    const previous = ledger.previousReleased().?;
    try std.testing.expect(previous.released());
    try std.testing.expect(previous.key.?.eql(key()));
    try std.testing.expect(previous.entry(1, .transport).released_sequence > previous.entry(1, .transport).acquired_sequence);
    try std.testing.expectEqual(ssh.ResourceState.absent, ledger.snapshot().entry(1, .transport).state);
}

test "failed connectOverFd records and releases the actual owned descriptor" {
    var ledger = try ssh.ResourceLedger.init(key(), 1);
    const pair = try ssh.SocketRelay.Pair.create();
    defer native.zw_ssh_socket_close(pair.relay_fd);
    const library: ssh.Library = .{ .active = false };
    try std.testing.expectError(error.LibraryNotInitialized, ssh.Session.connectOverFd(&library, .{
        .host = "unused",
        .user = "unused",
        .auth = .agent,
        .operation_key = key(),
        .resource_ledger = &ledger,
    }, pair.target_fd));
    const resources = ledger.snapshot();
    try std.testing.expect(resources.released());
    try std.testing.expectEqual(ssh.ResourceState.released, resources.entry(0, .transport).state);
    try std.testing.expect(resources.entry(0, .transport).released_sequence > resources.entry(0, .transport).acquired_sequence);
    try std.testing.expectEqual(@as(c_int, -1), std.c.fcntl(pair.target_fd, std.c.F.GETFL, @as(c_int, 0)));
}

test "retained native owners keep real descriptors until reverse-order cleanup" {
    var ledger = try ssh.ResourceLedger.init(key(), 2);
    defer _ = ledger.drainRetained();
    const first = try ssh.SocketRelay.Pair.create();
    defer native.zw_ssh_socket_close(first.relay_fd);
    const second = try ssh.SocketRelay.Pair.create();
    defer native.zw_ssh_socket_close(second.relay_fd);
    var parent: ssh.Session = .{ .state = .active, .socket_fd = first.target_fd, .resource_ledger = &ledger, .resource_key = key(), .resource_hop = 0 };
    var child: ssh.Session = .{ .state = .active, .socket_fd = second.target_fd, .resource_ledger = &ledger, .resource_key = key(), .resource_hop = 1 };
    parent.recordResource(.transport, .owned);
    child.recordResource(.transport, .owned);
    try std.testing.expect(ledger.retainFailure(&parent));
    try std.testing.expect(ledger.retainFailure(&child));
    try std.testing.expectEqual(@as(c_int, -1), parent.socket_fd);
    try std.testing.expectEqual(@as(c_int, -1), child.socket_fd);
    try std.testing.expectEqual(@as(usize, 2), ledger.snapshot().retained_count);
    try std.testing.expect(std.c.fcntl(first.target_fd, std.c.F.GETFL, @as(c_int, 0)) >= 0);
    try std.testing.expect(std.c.fcntl(second.target_fd, std.c.F.GETFL, @as(c_int, 0)) >= 0);
    try std.testing.expectError(error.CleanupNotReleased, ledger.beginNextTransport());
    try std.testing.expectEqual(ssh.ReleaseReceipt.released, ledger.drainRetained());
    const resources = ledger.snapshot();
    try std.testing.expect(resources.released());
    try std.testing.expect(resources.entry(1, .transport).released_sequence < resources.entry(0, .transport).released_sequence);
    try std.testing.expectEqual(@as(c_int, -1), std.c.fcntl(first.target_fd, std.c.F.GETFL, @as(c_int, 0)));
    try std.testing.expectEqual(@as(c_int, -1), std.c.fcntl(second.target_fd, std.c.F.GETFL, @as(c_int, 0)));
}

test "real worker reconnect releases the previous descriptor before attempting a replacement" {
    var ledger = try ssh.ResourceLedger.init(key(), 1);
    const pair = try ssh.SocketRelay.Pair.create();
    defer native.zw_ssh_socket_close(pair.relay_fd);
    const library: ssh.Library = .{ .active = false };
    var worker: Worker = undefined;
    worker.native_mutex = .unlocked;
    worker.shared_connection = null;
    worker.options = .{ .host = "unused", .user = "unused", .auth = .agent, .operation_key = key(), .resource_ledger = &ledger };
    worker.library = &library;
    worker.session = .{ .state = .active, .socket_fd = pair.target_fd, .resource_ledger = &ledger, .resource_key = key() };
    worker.exec_bridge = @import("proto/ssh/exec_bridge.zig").SshExecBridge.init(&worker.session, std.testing.allocator);
    worker.shared_transfer = try SharedTransfer.init(std.testing.allocator, &worker.session);
    worker.forward_services = @splat(null);
    worker.forward_count = 0;
    defer worker.shared_transfer.?.deinitLocal() catch unreachable;
    try std.testing.expect(!worker.shared_transfer.?.parent_released.load(.acquire));
    worker.session.recordResource(.transport, .owned);
    worker.jump_route = null;
    worker.jump_options = &.{};
    worker.loop_active = false;
    worker.resize_dims = .init(0);
    worker.input = try @import("vt/input_queue.zig").InputQueue.init(std.testing.allocator, 128);
    defer worker.input.deinit(std.testing.allocator);
    worker.replay = try @import("vt/reconnect_replay.zig").Replay.init(std.testing.allocator, 128);
    defer worker.replay.deinit();
    worker.replay.configure(key(), true, false);
    worker.replay.disconnected(&worker.input);

    // The replacement's inactive Library is reached only after real old-FD
    // cleanup. No new socket or shell is opened by this focused regression.
    var next = key();
    next.owner.session.generation += 1;
    next.operation_id += 1;
    next.attempt_id = next.attempt_id.? + 1;
    try std.testing.expectError(error.LibraryNotInitialized, worker.rebuildForOperation(key(), next));
    try std.testing.expectEqual(@as(c_int, -1), std.c.fcntl(pair.target_fd, std.c.F.GETFL, @as(c_int, 0)));
    try std.testing.expect(ledger.previousReleased().?.released());
    try std.testing.expectEqual(ssh.State.closed, worker.session.state);
    try std.testing.expect(worker.shared_transfer.?.parent_released.load(.acquire));
    try std.testing.expectEqual(ssh.ReleaseReceipt.released, worker.shared_transfer.?.closeReceipt());
    try std.testing.expect(!worker.loop_active);
}

test "real worker reconnect cannot pass an unknown resource receipt" {
    var ledger = try ssh.ResourceLedger.init(key(), 1);
    _ = ledger.record(key(), 0, .transport, .owned);
    _ = ledger.record(key(), 0, .transport, .unknown);
    const library: ssh.Library = .{ .active = false };
    var worker: Worker = undefined;
    worker.native_mutex = .unlocked;
    worker.shared_connection = null;
    worker.options = .{ .host = "unused", .user = "unused", .auth = .agent, .operation_key = key(), .resource_ledger = &ledger };
    worker.library = &library;
    worker.session = .{};
    worker.exec_bridge = @import("proto/ssh/exec_bridge.zig").SshExecBridge.init(&worker.session, std.testing.allocator);
    worker.shared_transfer = try SharedTransfer.init(std.testing.allocator, &worker.session);
    worker.forward_services = @splat(null);
    worker.forward_count = 0;
    defer worker.shared_transfer.?.deinitLocal() catch unreachable;
    worker.jump_route = null;
    worker.loop_active = false;
    try std.testing.expectError(error.CleanupUnknown, worker.rebuildConnection());
    try std.testing.expect(ledger.previousReleased() == null);
    try std.testing.expect(ledger.snapshot().hasUnknown());
    try std.testing.expect(worker.shared_transfer.?.parent_released.load(.acquire));
}

test "deferred runtime release preserves an unknown native receipt without publishing released" {
    const Owner = struct {
        calls: usize = 0,
        fn cleanup(raw: *anyopaque) runtime.ReleaseReceipt {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return .unknown;
        }
    };
    var owner: Owner = .{};
    var release: runtime.DeferredRelease = .{};
    defer release.finish(&owner, Owner.cleanup);
    try std.testing.expectEqual(runtime.ReleaseReceipt.awaiting, release.request(&owner, Owner.cleanup));
    while (release.receipt() == .awaiting) std.Thread.yield() catch {};
    try std.testing.expectEqual(runtime.ReleaseReceipt.unknown, release.receipt());
    try std.testing.expectEqual(@as(usize, 1), owner.calls);
    try std.testing.expectEqual(runtime.ReleaseReceipt.unknown, release.request(&owner, Owner.cleanup));
    try std.testing.expectEqual(@as(usize, 1), owner.calls);
}

test "probe controller keeps the same draft gated after a finished unknown cleanup" {
    var journal = operations.Journal.init(std.testing.allocator);
    defer journal.deinit();
    const original = try journal.begin(.app, 1);
    var controller = probe.Controller.init(std.testing.allocator, &journal);
    defer controller.jobs.deinit(std.testing.allocator);
    var job: probe.Job = undefined;
    job.source.value.draft_id = 17;
    job.ready = .init(true);
    job.resource_ledger = try ssh.ResourceLedger.init(original, 1);
    _ = job.resource_ledger.record(original, 0, .transport, .owned);
    _ = job.resource_ledger.record(original, 0, .transport, .unknown);
    job.retained_cleanup = .{ .state = .init(.unknown) };
    job.outcome = .{ .generation = 1, .key = original, .draft_id = 17, .draft_revision = 4, .source_owner = null, .protocol = .ssh, .elapsed_ms = 0, .failure = error.Cancelled, .cleanup = .unknown };
    try controller.jobs.append(std.testing.allocator, &job);
    const library: ssh.Library = .{ .active = false };
    try std.testing.expectError(error.CleanupNotReleased, controller.startWithTrustStore(.{ .draft_id = 17, .revision = 5 }, &.{}, .{}, 2, &library, "/unused/isolated-known-hosts"));
    try std.testing.expectEqual(@as(usize, 1), journal.records.items.len);
    try std.testing.expect(job.resource_ledger.snapshot().hasUnknown());
}
