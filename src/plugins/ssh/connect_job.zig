//! Provider-owned SSH attempt: frozen configuration, authentication, IO and release ledger.
const std = @import("std");
const applog = @import("../../platform/applog.zig");
const lifecycle = @import("../../ui/session_lifecycle.zig");
const hosts_mod = @import("../../config/hosts.zig");
const config_mod = @import("../../config/config.zig");
const OperationKey = @import("../../host/operation.zig").OperationKey;
const HostSnapshot = lifecycle.Snapshot(hosts_mod.HostConfig);
const ConfigSnapshot = lifecycle.Snapshot(config_mod.Config);
const SessionRuntime = @import("../../ui/session_runtime.zig").SessionRuntime;
const RuntimeReleaseReceipt = @import("../../ui/session_runtime.zig").ReleaseReceipt;
const ResourceLedger = @import("../../proto/ssh/session.zig").ResourceLedger;
const host_key_confirmation = @import("../../ui/host_key_confirmation.zig");
const host_key_policy = @import("../../proto/ssh/connection_policy.zig");
const auth_challenge = @import("../../proto/ssh/auth_challenge.zig");
/// A job owns everything used by its worker: identity, host config,
/// runtime policy, IO instance and result. It has no Workspace/Tab/Cx/node
/// pointers. UI polling consumes a result only after the release fence.
pub const ConnectJob = struct {
    ticket: lifecycle.Ticket,
    operation_key: ?OperationKey = null,
    host_snapshot: HostSnapshot,
    config_snapshot: ConfigSnapshot,
    io_instance: std.Io.Threaded,
    thread: ?std.Thread = null,
    cancelled: std.atomic.Value(bool) = .init(false),
    ready: std.atomic.Value(bool) = .init(false),
    drained: bool = false,
    runtime: ?*@import("../../host/runtime_service.zig").Runtime = null,
    runtime_storage: @import("../../host/runtime_service.zig").Runtime = undefined,
    runtime_scope_owned: bool = false,
    cleanup_unknown: bool = false,
    resource_ledger: ResourceLedger,
    connection_details: @import("../../proto/ssh/connection_details.zig").Store = .{},
    progress: @import("../../proto/ssh/connection_progress.zig").Journal = .{},
    progress_history: std.ArrayList(struct { key: OperationKey, journal: @import("../../proto/ssh/connection_progress.zig").Journal.Snapshot }) = .empty,
    progress_history_dropped: usize = 0,
    progress_dismissed: bool = false,
    retained_cleanup: @import("../../ui/session_runtime.zig").DeferredRelease = .{},
    err: ?anyerror = null,
    connection_attempts: u8 = 1,
    automatic_retry_deadline_ns: ?i128 = null,
    host_key_bridge: host_key_confirmation.Bridge = .{},
    auth_bridge: auth_challenge.InteractiveBridge = .{},
    request_counter: auth_challenge.RequestCounter = .{},
    host_key_store: host_key_policy.HostKeyStore,
    initial_input: ?[]u8 = null,
    shared_connection: ?@import("../../host/runtime_service.zig").SharedLease = null,
    deferred_shared_destroy: bool = false,
    shared_graph_refs: usize = 0,
    destroy_mutex: std.atomic.Mutex = .unlocked,
    jump_snapshot: lifecycle.Snapshot([]const hosts_mod.HostConfig),

    pub fn create(ticket: lifecycle.Ticket, host: hosts_mod.HostConfig, registry: []const hosts_mod.HostConfig, app_config: config_mod.Config, io: std.Io) !*ConnectJob {
        // c_allocator is thread-safe. UI arenas and node ownership never
        // cross the worker boundary, including failed connection cleanup.
        const allocator = std.heap.c_allocator;
        const job = try allocator.create(ConnectJob);
        errdefer allocator.destroy(job);
        var host_snapshot = try HostSnapshot.init(allocator, host);
        errdefer host_snapshot.deinit();
        var config_snapshot = try ConfigSnapshot.init(allocator, app_config);
        errdefer config_snapshot.deinit();
        const ordered_hops = try resolvedHops(allocator, host, registry);
        defer allocator.free(ordered_hops);
        var jump_snapshot = try lifecycle.Snapshot([]const hosts_mod.HostConfig).init(allocator, ordered_hops);
        errdefer jump_snapshot.deinit();
        const PathsType = @import("../../config/paths.zig").Paths;
        var paths = try PathsType.forApplication(allocator);
        defer paths.deinit();
        var key_store = try loadHostKeyStore(allocator, io, std.Io.Dir.cwd(), paths.known_hosts);
        errdefer key_store.deinit();
        job.* = .{
            .ticket = ticket,
            .host_key_store = key_store,
            .host_snapshot = host_snapshot,
            .config_snapshot = config_snapshot,
            .jump_snapshot = jump_snapshot,
            .io_instance = .init(allocator, .{}),
            .resource_ledger = try ResourceLedger.init(null, ordered_hops.len + 1),
        };
        job.host_key_bridge.request_counter = &job.request_counter;
        job.auth_bridge.request_counter = &job.request_counter;
        return job;
    }

    pub fn loadHostKeyStore(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !host_key_policy.HostKeyStore {
        var key_store = try host_key_policy.HostKeyStore.load(io, dir, allocator, path);
        errdefer key_store.deinit();
        try key_store.setPersistence(io, dir, path);
        return key_store;
    }

    /// ApplicationHost supplies its owned hop configs here. Direct callers
    /// use the same durable IDs; display names never select a transport.
    pub fn resolvedHops(allocator: std.mem.Allocator, host: hosts_mod.HostConfig, registry: []const hosts_mod.HostConfig) ![]hosts_mod.HostConfig {
        return @import("../../ui/session_runtime.zig").resolveHostRoute(allocator, host, registry);
    }

    /// Called only after the worker has been joined (or never started).
    pub fn destroy(job: *ConnectJob) void {
        while (!job.destroy_mutex.tryLock()) std.atomic.spinLoopHint();
        if (job.runtime) |runtime| {
            if (!runtime.cleanupReleased()) {
                job.destroy_mutex.unlock();
                return;
            }
            job.runtime = null;
        }
        if (job.shared_graph_refs != 0) {
            job.deferred_shared_destroy = true;
            job.destroy_mutex.unlock();
            return;
        }
        job.retained_cleanup.finish(&job.resource_ledger, @import("../../ui/session_runtime.zig").drainRetainedResources);
        if (!job.resource_ledger.snapshot().released()) {
            job.deferred_shared_destroy = true;
            job.destroy_mutex.unlock();
            return;
        }
        if (job.shared_connection) |lease| lease.release();
        if (job.initial_input) |input| std.heap.c_allocator.free(input);
        job.host_key_store.deinit();
        job.io_instance.deinit();
        job.host_snapshot.deinit();
        job.config_snapshot.deinit();
        job.jump_snapshot.deinit();
        job.progress_history.deinit(std.heap.c_allocator);
        std.heap.c_allocator.destroy(job);
    }

    pub fn failedCleanupReceipt(job: *ConnectJob) RuntimeReleaseReceipt {
        if (job.resource_ledger.snapshot().released()) return .released;
        return job.retained_cleanup.request(&job.resource_ledger, @import("../../ui/session_runtime.zig").drainRetainedResources);
    }

    /// Retry only network setup before authentication/shell creation. Each
    /// successor still receives a fresh host-issued operation and resource ledger.
    pub fn canAutomaticallyRetry(job: *ConnectJob) bool {
        if (job.connection_attempts >= 3 or job.runtime != null or job.cancelled.load(.acquire)) return false;
        const failure = job.progress.snapshot().failure orelse return false;
        switch (failure.phase) {
            .transport, .tunnel, .handshake => {},
            else => return false,
        }
        return switch (job.err orelse return false) {
            error.ConnectFailed, error.ConnectionRefused, error.HostResolutionFailed, error.ConnectionTimedOut, error.HandshakeFailed, error.SshHandshakeReceiveFailed, error.SshHandshakeSendFailed, error.SshHandshakeDisconnected, error.SshHandshakeBannerFailed, error.SshHandshakeTimedOut => true,
            else => false,
        };
    }
};

pub fn connectThread(job: *ConnectJob) void {
    defer job.ready.store(true, .release);
    defer if (job.shared_connection) |lease| {
        // Creation pins the transport only until an installed worker owns its
        // own lease. Failed native cleanup keeps the creation lease pinned.
        if (job.runtime != null or job.resource_ledger.snapshot().released()) {
            job.shared_connection = null;
            lease.release();
        }
    };
    if (job.cancelled.load(.acquire)) return;
    const host = job.host_snapshot.value;
    applog.info(.workspace, "connect thread started session={d} for {s}", .{ job.ticket.session_id, host.name });
    const runtime = SessionRuntime.initForHost(std.heap.c_allocator, job.io_instance.io(), job.config_snapshot.value, runtimeTarget(job)) catch |err| {
        applog.err(.workspace, "connect FAILED session={d}: {s}", .{ job.ticket.session_id, @errorName(err) });
        job.err = err;
        job.retained_cleanup.finish(&job.resource_ledger, @import("../../ui/session_runtime.zig").drainRetainedResources);
        return;
    };
    if (job.cancelled.load(.acquire)) {
        if (!runtime.cleanupReleased()) {
            job.runtime_storage = @import("runtime_binding.zig").borrow(runtime);
            job.runtime = &job.runtime_storage;
        }
        return;
    }
    job.runtime_storage = @import("runtime_binding.zig").borrow(runtime);
    job.runtime = &job.runtime_storage;
    applog.info(.workspace, "connect OK session={d}", .{job.ticket.session_id});
}

fn sharedGraphRetained(raw: *anyopaque) void {
    const job: *ConnectJob = @ptrCast(@alignCast(raw));
    while (!job.destroy_mutex.tryLock()) std.atomic.spinLoopHint();
    job.shared_graph_refs += 1;
    job.destroy_mutex.unlock();
}
fn sharedGraphReleased(raw: *anyopaque) void {
    const job: *ConnectJob = @ptrCast(@alignCast(raw));
    while (!job.destroy_mutex.tryLock()) std.atomic.spinLoopHint();
    job.shared_graph_refs -= 1;
    const destroy = job.shared_graph_refs == 0 and job.deferred_shared_destroy;
    job.destroy_mutex.unlock();
    if (destroy) job.destroy();
}
pub fn runtimeTarget(job: *ConnectJob) @import("../../ui/session_runtime.zig").HostTarget {
    var target = @import("../../ui/session_runtime.zig").targetFromHost(job.host_snapshot.value, job.jump_snapshot.value);
    target.shared_connection = job.shared_connection;
    target.connection_lifetime = .{ .context = job, .retain = sharedGraphRetained, .call = sharedGraphReleased };
    target.operation_key = job.operation_key;
    target.resource_ledger = &job.resource_ledger;
    target.connection_details = &job.connection_details;
    target.progress_observer = job.progress.observer();
    target.host_key_bridge = &job.host_key_bridge;
    target.keyboard_bridge = &job.auth_bridge;
    target.host_key_store = &job.host_key_store;
    target.cancel_token = &job.cancelled;
    target.initial_input = job.initial_input orelse "";
    return target;
}
