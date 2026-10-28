//! Authenticated native transport owner shared by independent shell workers.
const std = @import("std");
const ssh = @import("../proto/ssh/session.zig");
const Forward = @import("../proto/ssh/forward_service.zig").Service;
pub const Lifetime = struct { context: *anyopaque, retain: *const fn (*anyopaque) void, call: *const fn (*anyopaque) void };
const c = @import("generated_ssh_session");
const Lease = @import("../host/runtime_service.zig").SharedLease;
var pending_mutex: std.atomic.Mutex = .unlocked;
var pending_head: ?*Connection = null;
var next_notification_id: std.atomic.Value(u64) = .init(1);
pub fn reserveNotificationId() u64 {
    return next_notification_id.fetchAdd(1, .monotonic);
}

pub const Connection = struct {
    const ShellCleanup = struct {
        term: [:0]u8,
        raw: ?*c.LIBSSH2_CHANNEL = null,
        phase: c_int = 0,
        owns_open: bool = false,
        next: ?*ShellCleanup = null,
        fn ticket(self: *ShellCleanup) ssh.Session.OpenTicket {
            return .{ .kind = .shell, .id = @intFromPtr(self.term.ptr) };
        }
    };
    allocator: std.mem.Allocator,
    notification_id: u64 = 0,
    mutex: std.atomic.Mutex = .unlocked,
    library: ssh.Library,
    route: ?*@import("../proto/ssh/jump_transport.zig").Route = null,
    upstream: [9]?*Forward = @splat(null),
    native: ssh.Session,
    ledger: ?ssh.ResourceLedger = null,
    source_ledger: ?*ssh.ResourceLedger = null,
    pending_next: ?*Connection = null,
    cleanup_running: std.atomic.Value(bool) = .init(false),
    refs: std.atomic.Value(usize) = .init(1),
    broken: bool = false,
    pending_term: ?[:0]u8 = null,
    shell_cleanup: ?*ShellCleanup = null,
    on_release: ?Lifetime = null,

    pub fn lease(self: *Connection) Lease {
        retain(self);
        return .{ .context = self, .retain_fn = retain, .release_fn = release };
    }
    fn retain(raw: *anyopaque) void {
        const self: *Connection = @ptrCast(@alignCast(raw));
        _ = self.refs.fetchAdd(1, .monotonic);
    }
    pub fn release(raw: *anyopaque) void {
        const self: *Connection = @ptrCast(@alignCast(raw));
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        while (!pending_mutex.tryLock()) std.atomic.spinLoopHint();
        self.pending_next = pending_head;
        pending_head = self;
        // A retry may start and finish cleanup immediately. Keep the registry
        // guard until our last access so it cannot destroy self underneath us.
        self.startCleanup();
        pending_mutex.unlock();
    }
    fn startCleanup(self: *Connection) void {
        if (self.cleanup_running.swap(true, .acq_rel)) return;
        const cleanup = std.Thread.spawn(.{}, finishRelease, .{self}) catch {
            self.cleanup_running.store(false, .release);
            return;
        };
        cleanup.detach();
    }
    /// A process-owned registry retains incomplete graphs even if native free
    /// or thread creation fails. New session activity can retry those receipts.
    pub fn retryPending() void {
        while (!pending_mutex.tryLock()) std.atomic.spinLoopHint();
        defer pending_mutex.unlock();
        var current = pending_head;
        while (current) |group| {
            group.startCleanup();
            current = group.pending_next;
        }
    }
    fn finishRelease(self: *Connection) void {
        while (true) {
            switch (self.native.closeReceipt()) {
                .released => break,
                .unknown => {
                    self.cleanup_running.store(false, .release);
                    return;
                },
                .awaiting => {
                    var delay: std.c.timespec = .{ .sec = 0, .nsec = 25 * std.time.ns_per_ms };
                    _ = std.c.nanosleep(&delay, null);
                },
            }
        }
        self.discardShellCleanup();
        if (self.route) |route| {
            while (true) {
                switch (route.closeReceipt()) {
                    .released => break,
                    .unknown => {
                        self.cleanup_running.store(false, .release);
                        return;
                    },
                    .awaiting => {
                        var delay: std.c.timespec = .{ .sec = 0, .nsec = 25 * std.time.ns_per_ms };
                        _ = std.c.nanosleep(&delay, null);
                    },
                }
            }
            route.deinit();
            self.route = null;
        }
        for (&self.upstream) |*service| if (service.*) |value| {
            value.adoptIoAfterOwnerStopped();
            value.stepPaused() catch {
                self.cleanup_running.store(false, .release);
                return;
            };
            value.deinitLocal() catch {
                self.cleanup_running.store(false, .release);
                return;
            };
            service.* = null;
        };
        self.library.deinit();
        if (self.source_ledger) |ledger| ledger.forgetTransferred(&self.ledger.?);
        if (self.pending_term) |term| self.allocator.free(term);
        while (!pending_mutex.tryLock()) std.atomic.spinLoopHint();
        var link = &pending_head;
        while (link.*) |group| {
            if (group == self) {
                link.* = self.pending_next;
                break;
            }
            link = &group.pending_next;
        }
        pending_mutex.unlock();
        const callback = self.on_release;
        const allocator = self.allocator;
        allocator.destroy(self);
        if (callback) |value| value.call(value.context);
    }
    /// Register the new tab's upstream facades only after all fallible Worker
    /// initialization succeeded. Registration itself allocates no native state.
    pub fn bindUpstreamForwards(self: *Connection, forwards: []const ?*Forward, details: ?*ssh.ConnectionDetails.Store) !void {
        self.lock();
        defer self.unlock();
        if (self.broken or self.native.handle == null) return error.SharedTransportLost;
        const route = self.route orelse {
            if (forwards.len > 1) return error.InvalidForwardRoute;
            return;
        };
        if (forwards.len != route.hops.len) return error.InvalidForwardRoute;
        for (route.hops[0 .. forwards.len - 1]) |hop| {
            const relay = hop.relay orelse return error.SharedTransportLost;
            if (relay.state.load(.acquire) != 0) return error.SharedTransportLost;
        }
        for (route.hops[0 .. forwards.len - 1], forwards[0 .. forwards.len - 1], 0..) |hop, service, index| {
            if (service) |value| {
                value.relay_details = details;
                value.relay_hop = index;
                hop.relay.?.bindSharedForward(value);
            }
        }
    }
    /// Once the target is broken no sibling may use its upstream graph. Join
    /// its IO owners before releasing parent channels and waking facade owners.
    pub fn releaseBroken(self: *Connection) ssh.ReleaseReceipt {
        const target = self.native.closeReceipt();
        if (target != .released) return target;
        self.discardShellCleanup();
        if (self.route) |route| return route.closeReceipt();
        return .released;
    }
    pub fn isReusable(self: *Connection) bool {
        self.lock();
        defer self.unlock();
        return !self.broken and self.native.state == .active and self.native.handle != null and self.native.socket_fd >= 0;
    }
    /// Caller holds mutex. Failed construction must never retain a borrowed
    /// Session in an attempt ledger after its connection lease goes away.
    pub fn rollbackShell(self: *Connection, session: *ssh.Session) void {
        if (self.native.handle == null) {
            session.recordResource(.shell, .released);
        } else if (session.closeReceipt() != .released) {
            // The parent still owns this native child. Quarantine it with the
            // complete connection graph instead of leaving a dangling borrower.
            self.broken = true;
            c.zw_libssh2_session_abort_io(self.native.handle.?, self.native.socket_fd);
            session.recordResource(.shell, .transferred);
        }
        if (session.connection_details) |store| if (session.resource_key) |key| store.status(key, session.resource_hop, .released);
        session.* = .{ .state = .closed };
    }
    /// Native retry arguments outlive a cancelled caller. Existing workers
    /// drain this list under the shared native guard; final parent release is
    /// the fallback owner when a peer never acknowledges an abandoned open.
    fn queueShellCleanup(self: *Connection, pending: *ShellCleanup) void {
        if (pending.owns_open and pending.phase != 0) {
            self.native.finishChannelOpen(pending.ticket());
            pending.owns_open = false;
        }
        pending.next = self.shell_cleanup;
        self.shell_cleanup = pending;
    }
    fn freeShellCleanup(self: *Connection, pending: *ShellCleanup) void {
        self.allocator.free(pending.term);
        self.allocator.destroy(pending);
    }
    fn discardShellCleanup(self: *Connection) void {
        while (self.shell_cleanup) |pending| {
            self.shell_cleanup = pending.next;
            self.freeShellCleanup(pending);
        }
    }
    /// Caller holds the native mutex. No cleanup of one shell aborts siblings.
    pub fn stepShellCleanup(self: *Connection) void {
        if (self.native.handle == null) {
            self.discardShellCleanup();
            return;
        }
        var link = &self.shell_cleanup;
        while (link.*) |pending| {
            const rc = c.zw_libssh2_shared_shell_cancel_step(self.native.handle.?, &pending.raw, &pending.phase);
            if (pending.owns_open and (pending.phase != 0 or rc < 0)) {
                self.native.finishChannelOpen(pending.ticket());
                pending.owns_open = false;
            }
            if (rc == 0 or (rc < 0 and pending.raw == null)) {
                link.* = pending.next;
                self.freeShellCleanup(pending);
            } else link = &pending.next;
        }
    }
    pub fn openShell(self: *Connection, options: ssh.Options) !ssh.Session {
        try options.prepareDetails();
        const pending = try self.allocator.create(ShellCleanup);
        var graph_owned = false;
        defer if (!graph_owned) self.allocator.destroy(pending);
        pending.* = .{ .term = try self.allocator.dupeSentinel(u8, options.term, 0) };
        const deadline = @import("../platform/realtime.zig").monotonicNs() + @as(i128, options.connect_timeout_ms) * std.time.ns_per_ms;
        while (true) {
            self.lock();
            if (self.broken or self.native.handle == null) {
                if (pending.owns_open and self.native.handle != null) {
                    self.queueShellCleanup(pending);
                    graph_owned = true;
                } else self.allocator.free(pending.term);
                self.unlock();
                return error.SessionClosed;
            }
            const cancelled = if (options.cancel_token) |token| token.load(.acquire) else false;
            const expired = @import("../platform/realtime.zig").monotonicNs() >= deadline;
            if (cancelled or expired) {
                if (pending.owns_open) {
                    self.queueShellCleanup(pending);
                    graph_owned = true;
                    self.unlock();
                    return if (cancelled) error.Cancelled else error.ConnectionTimedOut;
                }
                self.allocator.free(pending.term);
                self.unlock();
                return if (cancelled) error.Cancelled else error.ConnectionTimedOut;
            }
            const acquired = self.native.claimChannelOpen(pending.ticket());
            pending.owns_open = pending.owns_open or acquired;
            const rc = if (acquired) c.zw_libssh2_shared_shell_step(self.native.handle.?, pending.term.ptr, options.cols, options.rows, &pending.raw, &pending.phase) else 1;
            if (rc <= 0) {
                self.native.finishChannelOpen(pending.ticket());
                pending.owns_open = false;
                if (rc < 0) {
                    if (c.zw_libssh2_transport_failed(self.native.handle.?) != 0) {
                        self.broken = true;
                        c.zw_libssh2_session_abort_io(self.native.handle.?, self.native.socket_fd);
                    }
                    if (pending.raw != null) {
                        self.queueShellCleanup(pending);
                        graph_owned = true;
                        self.unlock();
                        return error.ShellOpenFailed;
                    }
                    self.allocator.free(pending.term);
                    self.unlock();
                    return error.ShellOpenFailed;
                }
                var child: ssh.Session = .{ .state = .active, .handle = self.native.handle, .socket_fd = self.native.socket_fd, .channel = .{ .handle = @ptrCast(pending.raw.?) }, .borrowed_transport = true, .shared_gate = &self.native, .resource_ledger = options.resource_ledger, .resource_key = options.operation_key, .resource_hop = options.hop_index, .source_owner = options.source_owner, .connection_details = options.connection_details, .negotiated_metadata = self.native.negotiated_metadata };
                child.recordResource(.shell, .owned);
                if (options.connection_details) |store| if (options.operation_key) |key| {
                    if (self.route) |route| for (route.hops[0 .. route.hops.len - 1], 0..) |hop, index| store.negotiated(key, index, hop.session.negotiated_metadata);
                    store.negotiated(key, options.hop_index, child.negotiated_metadata);
                };
                self.unlock();
                self.allocator.free(pending.term);
                return child;
            }
            self.unlock();
            var delay: std.c.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
            _ = std.c.nanosleep(&delay, null);
        }
    }
    pub fn lock(self: *Connection) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    pub fn unlock(self: *Connection) void {
        self.mutex.unlock();
    }
};

test "queued shared shell timeout preserves another native open and transport" {
    const a = std.testing.allocator;
    const active: ssh.Session.OpenTicket = .{ .kind = .shell, .id = 77 };
    var group: Connection = .{
        .allocator = a,
        .library = .{ .active = false },
        // The gate remains claimed, so this test must never enter native IO.
        .native = .{ .state = .active, .handle = @ptrFromInt(16), .socket_fd = 3, .channel_open = active },
    };
    try std.testing.expectError(error.ConnectionTimedOut, group.openShell(.{
        .host = "fixture",
        .user = "fixture",
        .auth = .agent,
        .connect_timeout_ms = 0,
    }));
    try std.testing.expect(!group.broken);
    try std.testing.expectEqual(active, group.native.channel_open.?);
    try std.testing.expect(group.pending_term == null);
    try std.testing.expect(group.isReusable());
    var cancelled: std.atomic.Value(bool) = .init(true);
    try std.testing.expectError(error.Cancelled, group.openShell(.{
        .host = "fixture",
        .user = "fixture",
        .auth = .agent,
        .cancel_token = &cancelled,
    }));
    try std.testing.expect(!group.broken);
    try std.testing.expectEqual(active, group.native.channel_open.?);
}

test "shared shell rollback forgets stale borrower after parent native release" {
    var ledger = try ssh.ResourceLedger.init(null, 1);
    var group: Connection = .{ .allocator = std.testing.allocator, .library = .{ .active = false }, .native = .{ .state = .closed } };
    var child: ssh.Session = .{ .state = .active, .handle = @ptrFromInt(16), .socket_fd = 3, .channel = .{ .handle = @ptrFromInt(32) }, .borrowed_transport = true, .resource_ledger = &ledger };
    child.recordResource(.shell, .owned);
    group.rollbackShell(&child);
    try std.testing.expectEqual(ssh.State.closed, child.state);
    try std.testing.expect(child.handle == null and child.channel == null);
    try std.testing.expect(ledger.snapshot().released());
}
