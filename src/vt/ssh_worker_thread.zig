const std = @import("std");
const SshWorker = @import("ssh_worker.zig").SshWorker;
const reconnect = @import("reconnect.zig");
const OperationKey = @import("../host/operation.zig").OperationKey;

/// Owns the worker thread only; all Zenit nodes remain UI-thread owned.
pub const Thread = struct {
    worker: *SshWorker,
    thread: std.Thread,
    stop_requested: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    joined: bool = false,
    reconnect_control: reconnect.Control = reconnect.Control.init(null),

    pub fn start(allocator: std.mem.Allocator, worker: *SshWorker) !*Thread {
        const self = try allocator.create(Thread);
        errdefer allocator.destroy(self);
        self.* = .{ .worker = worker, .thread = undefined, .reconnect_control = reconnect.Control.init(worker.options.operation_key) };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    pub fn requestStop(self: *Thread) void {
        self.stop_requested.store(true, .release);
        self.reconnect_control.close();
    }

    pub fn stopAndJoin(self: *Thread) void {
        if (self.joined) return;
        self.requestStop();
        self.thread.join();
        self.joined = true;
    }

    pub fn deinit(self: *Thread) void {
        self.stopAndJoin();
        const allocator = self.worker.allocator;
        self.worker.deinit();
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn hasFailed(self: *const Thread) bool {
        return self.failed.load(.acquire);
    }

    pub fn reconnectSnapshot(self: *Thread) reconnect.Control.Snapshot {
        return self.reconnect_control.snapshot();
    }

    pub fn requestReconnect(self: *Thread, previous: OperationKey, next: OperationKey) !void {
        if (self.stop_requested.load(.acquire)) return error.WorkerStopped;
        try self.reconnect_control.request(previous, next);
    }

    pub fn markAttached(self: *Thread, key: OperationKey) bool {
        if (!self.reconnect_control.attached(key)) return false;
        self.worker.markAttached();
        return true;
    }

    fn pause() void {
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 25 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }

    fn run(self: *Thread) void {
        var failure: ?anyerror = null;
        while (!self.stop_requested.load(.acquire)) {
            if (failure == null) {
                const timeout: u32 = if (self.worker.io.feed.republish_pending) 8 else 50;
                self.worker.step(timeout) catch |err| {
                    failure = err;
                };
                if (failure == null) {
                    // A deferred tail frame or close exchange must not busy
                    // spin on the socket's permanent EOF readiness.
                    if (self.worker.io.closed) pause();
                    continue;
                }
                self.worker.presentation_attached.store(false, .release);
                if (failure.? != error.ShellEnded and failure.? != error.ForwardParentClosing) {
                    self.worker.transportFailed();
                    self.worker.reconnect.suspect(null);
                    self.failed.store(true, .release);
                }
            }
            const shell_ended = failure.? == error.ShellEnded;
            if (!shell_ended) self.worker.disconnectInput();
            // This remains the sole native IO owner. An unknown release never
            // grants a replacement, and no controller callback closes a socket.
            var receipt = self.worker.releaseConnection();
            self.publishRelease(shell_ended, receipt, failure.?);
            while (!self.stop_requested.load(.acquire)) {
                self.worker.publishPendingPresentation();
                if (receipt == .awaiting) {
                    pause();
                    receipt = self.worker.releaseConnection();
                    self.publishRelease(shell_ended, receipt, failure.?);
                    continue;
                }
                if (receipt == .released) self.worker.stepPausedForwards() catch |err| {
                    failure = err;
                    break;
                };
                const grant = self.reconnect_control.take() orelse {
                    pause();
                    continue;
                };
                self.worker.reconnect.authorized();
                self.worker.rebuildForOperation(grant.previous, grant.next) catch |err| {
                    failure = err;
                    break;
                };
                self.failed.store(false, .release);
                self.reconnect_control.ready(grant.next);
                @import("../platform/presentation_wakeup.zig").notify();
                failure = null;
                break;
            }
        }
    }

    fn publishRelease(self: *Thread, shell_ended: bool, receipt: @import("../proto/ssh/session.zig").ReleaseReceipt, failure: anyerror) void {
        const before = self.reconnect_control.snapshot();
        if (shell_ended) self.reconnect_control.ended(self.worker.options.operation_key, receipt, self.worker.shell_exit_code) else self.reconnect_control.lost(self.worker.options.operation_key, receipt, failure);
        // EOF/connection loss and cleanup receipts can change without a text
        // frame. Wake only for actual changes, never on every cleanup retry.
        if (!std.meta.eql(before, self.reconnect_control.snapshot())) @import("../platform/presentation_wakeup.zig").notify();
    }
};

test "worker thread starts with externally owned worker contract" {
    // The network worker is intentionally not created in the unit gate. This
    // test locks the stop/error state contract without opening a socket.
    var failed: std.atomic.Value(bool) = .init(false);
    try std.testing.expect(!failed.load(.acquire));
    failed.store(true, .release);
    try std.testing.expect(failed.load(.acquire));
}

test "worker thread joining is idempotent for archive then destruction" {
    const Runner = struct {
        fn run(thread: *Thread) void {
            while (!thread.stop_requested.load(.acquire)) std.Thread.yield() catch {};
        }
    };
    var thread: Thread = undefined;
    thread.stop_requested = .init(false);
    thread.joined = false;
    thread.reconnect_control = reconnect.Control.init(null);
    thread.thread = try std.Thread.spawn(.{}, Runner.run, .{&thread});
    thread.stopAndJoin();
    thread.stopAndJoin();
    try std.testing.expect(thread.joined);
}

test "worker thread notifies shell end and cleanup changes without repeated idle wakes" {
    const wake = @import("../platform/presentation_wakeup.zig");
    _ = wake.take();
    defer _ = wake.take();
    const key: OperationKey = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(7) } }, .operation_id = 1, .attempt_id = 1 };
    var worker: SshWorker = undefined;
    worker.options = .{ .host = "fixture", .user = "fixture", .auth = .agent, .operation_key = key };
    worker.shell_exit_code = 7;
    var thread: Thread = undefined;
    thread.worker = &worker;
    thread.reconnect_control = reconnect.Control.init(key);
    thread.publishRelease(true, .awaiting, error.ShellEnded);
    try std.testing.expect(wake.take());
    try std.testing.expectEqual(reconnect.Control.Phase.ended, thread.reconnectSnapshot().phase);
    try std.testing.expectEqual(@as(?i32, 7), thread.reconnectSnapshot().exit_code);
    thread.publishRelease(true, .awaiting, error.ShellEnded);
    try std.testing.expect(!wake.take());
    thread.publishRelease(true, .released, error.ShellEnded);
    try std.testing.expect(wake.take());
    try std.testing.expectEqual(@import("../proto/ssh/session.zig").ReleaseReceipt.released, thread.reconnectSnapshot().cleanup);
}

test "worker thread notifies transport loss without any terminal text" {
    const wake = @import("../platform/presentation_wakeup.zig");
    _ = wake.take();
    defer _ = wake.take();
    const key: OperationKey = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(7) } }, .operation_id = 1, .attempt_id = 1 };
    var worker: SshWorker = undefined;
    worker.options = .{ .host = "fixture", .user = "fixture", .auth = .agent, .operation_key = key };
    var thread: Thread = undefined;
    thread.worker = &worker;
    thread.reconnect_control = reconnect.Control.init(key);
    thread.publishRelease(false, .released, error.ConnectionClosed);
    try std.testing.expect(wake.take());
    try std.testing.expectEqual(reconnect.Control.Phase.waiting, thread.reconnectSnapshot().phase);
    try std.testing.expectEqual(error.ConnectionClosed, thread.reconnectSnapshot().failure.?);
    thread.publishRelease(false, .released, error.ConnectionClosed);
    try std.testing.expect(!wake.take());
}
