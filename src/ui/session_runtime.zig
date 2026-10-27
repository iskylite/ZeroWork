const std = @import("std");
const applog = @import("../platform/applog.zig");
const Library = @import("../proto/ssh/session.zig").Library;
const Options = @import("../proto/ssh/session.zig").Options;
const ResourceLedger = @import("../proto/ssh/session.zig").ResourceLedger;
const KeyboardPrompt = @import("../proto/ssh/session.zig").KeyboardPrompt;
const InteractiveBridge = @import("../proto/ssh/auth_challenge.zig").InteractiveBridge;
const SshWorker = @import("../vt/ssh_worker.zig").SshWorker;
const WorkerThread = @import("../vt/ssh_worker_thread.zig").Thread;
const CheckpointController = @import("../vt/checkpoint_controller.zig").Controller;
const realtime = @import("../platform/realtime.zig");
const config = @import("../config/config.zig");
const hosts_mod = @import("../config/hosts.zig");
const identity = @import("../host/identity.zig");
const OperationKey = @import("../host/operation.zig").OperationKey;
const Paths = @import("../config/paths.zig").Paths;
const session_archive = @import("../vt/session_archive.zig");
const Timeline = @import("../vt/timeline.zig").Timeline;
var next_log_id: std.atomic.Value(u64) = .init(0);

pub const ReleaseReceipt = @import("../proto/ssh/session.zig").ReleaseReceipt;
pub const ArchiveRequest = struct { session_id: u64, retention_days: u16 };
pub const Purpose = enum { @"test", session, transfer_binding };

/// One Runtime owns one deferred release. Only the controller requests/polls;
/// the cleanup thread publishes released after the real destructor returns.
pub const DeferredRelease = struct {
    const State = enum(u8) { idle, running, awaiting, released, unknown };
    state: std.atomic.Value(State) = .init(.idle),
    thread: ?std.Thread = null,

    pub fn request(self: *DeferredRelease, context: *anyopaque, cleanup_fn: *const fn (*anyopaque) ReleaseReceipt) ReleaseReceipt {
        switch (self.state.load(.acquire)) {
            .released => {
                self.join();
                return .released;
            },
            .unknown => return .unknown,
            .running => return .awaiting,
            .awaiting => self.join(),
            .idle => {},
        }
        self.state.store(.running, .release);
        self.thread = std.Thread.spawn(.{}, run, .{ self, context, cleanup_fn }) catch {
            // No destructor ran; keep the original owner and every resource.
            self.state.store(.unknown, .release);
            return .unknown;
        };
        return .awaiting;
    }

    fn run(self: *DeferredRelease, context: *anyopaque, cleanup_fn: *const fn (*anyopaque) ReleaseReceipt) void {
        const result = cleanup_fn(context);
        self.state.store(switch (result) {
            .released => .released,
            .awaiting => .awaiting,
            .unknown => .unknown,
        }, .release);
    }

    fn join(self: *DeferredRelease) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    /// Reserved for final scope destruction or a connect worker's local error
    /// path. Normal UI close requests use request(), never a live join.
    pub fn finish(self: *DeferredRelease, context: *anyopaque, cleanup_fn: *const fn (*anyopaque) ReleaseReceipt) void {
        self.join();
        if (self.state.load(.acquire) != .released) {
            run(self, context, cleanup_fn);
        }
    }

    pub fn receipt(self: *const DeferredRelease) ReleaseReceipt {
        return switch (self.state.load(.acquire)) {
            .released => .released,
            .unknown => .unknown,
            .idle, .running, .awaiting => .awaiting,
        };
    }

    pub fn resetReleased(self: *DeferredRelease) !void {
        switch (self.state.load(.acquire)) {
            .idle => return,
            .released => self.join(),
            .running, .awaiting, .unknown => return error.CleanupNotReleased,
        }
        self.state.store(.idle, .release);
    }
};

pub fn drainRetainedResources(raw: *anyopaque) ReleaseReceipt {
    const ledger: *ResourceLedger = @ptrCast(@alignCast(raw));
    return ledger.drainRetained();
}

/// UI-owned lifetime anchor for the opt-in real SSH connection. The worker
/// thread never owns Zenit nodes; Scope cleanup stops it before freeing handles.
pub fn workerRuntimeOptions(app_config: config.Config) @import("../vt/ssh_worker.zig").RuntimeOptions {
    return .{
        .scrollback = app_config.ui.scrollback_limit,
        .timeline_max_bytes = @as(usize, app_config.log.ring_mb) * 1024 * 1024,
        .reconnect_max = app_config.ssh.reconnect_max,
        .auto_reconnect = app_config.ssh.auto_reconnect and app_config.ssh.reconnect_max > 0,
        .buffer_input = app_config.ssh.buffer_input,
        .reconnect_backoff = app_config.ssh.reconnect_backoff,
    };
}

/// Host identity the UI wants to connect to (from hosts.toml or quick connect).
pub const HostTarget = struct {
    source_owner: ?identity.AssetOwner = null,
    protocol: hosts_mod.Protocol = .ssh,
    auth_mode: hosts_mod.AuthMode = .agent,
    strict_host_key_checking: bool = true,
    operation_key: ?OperationKey = null,
    resource_ledger: ?*ResourceLedger = null,
    connection_details: ?*@import("../proto/ssh/connection_details.zig").Store = null,
    display_name: []const u8 = "",
    progress_observer: ?@import("../proto/ssh/connection_progress.zig").Observer = null,
    host: []const u8,
    port: u16 = 22,
    user: []const u8,
    password: ?[]const u8 = null,
    identity_file: ?[]const u8 = null,
    key_passphrase: ?[]const u8 = null,
    terminal_type: ?[]const u8 = null,
    scrollback: ?u32 = null,
    keepalive: ?bool = null,
    compression: ?bool = null,
    host_key_bridge: ?*@import("host_key_confirmation.zig").Bridge = null,
    host_key_store: ?*@import("../proto/ssh/connection_policy.zig").HostKeyStore = null,
    keyboard_bridge: ?*InteractiveBridge = null,
    cancel_token: ?*std.atomic.Value(bool) = null,
    /// Borrowed only during init; enqueued before the worker starts, so no
    /// second producer races the UI's SPSC input queue.
    initial_input: []const u8 = "",
    /// Plain startup commands copied from the host profile. Expect/send
    /// semantics intentionally remain unsupported until a dedicated protocol
    /// model and interaction UI exist.
    startup_commands: []const []const u8 = &.{},
    /// Legacy display projection only; numeric route owns transport order.
    jump_chain: []const []const u8 = &.{},
    route: []const identity.ConnectionId = &.{},
    /// Registry snapshots for the configured jump chain. Borrowed while the
    /// worker is constructed; persistent IDs select hops before any IO.
    jump_hosts: []const hosts_mod.HostConfig = &.{},
};

pub const SessionRuntime = struct {
    allocator: std.mem.Allocator,
    library: *Library,
    worker: *SshWorker,
    thread: *WorkerThread,
    checkpoint: *CheckpointController,
    host: [:0]u8,
    user: [:0]u8,
    terminal_type: [:0]u8,
    password: ?[:0]u8,
    identity_file: ?[:0]u8,
    key_passphrase: ?[:0]u8,
    /// Marks members unavailable as soon as release starts; only the release
    /// task's receipt proves they are freed. The scope owns the struct itself.
    torn_down: bool = false,
    document_source: ?@import("terminal_document_source.zig").Source = null,
    log_directory: ?std.Io.Dir = null,
    checkpoint_path: []u8,
    raw_path: []u8,
    started_ms: i64,
    archive_written: bool = false,
    saved_connection_id: ?u64 = null,
    route_arena: ?std.heap.ArenaAllocator = null,
    host_key_bridge: ?*@import("host_key_confirmation.zig").Bridge = null,
    keyboard_bridge: ?*InteractiveBridge = null,
    cancel_token: ?*std.atomic.Value(bool) = null,
    release: DeferredRelease = .{},
    resource_ledger: ?*ResourceLedger = null,
    archive_request: ?ArchiveRequest = null,

    fn keyboardAnswer(ctx: *anyopaque, prompt: []const u8, answer: []u8) ?[]const u8 {
        const bridge: *InteractiveBridge = @ptrCast(@alignCast(ctx));
        const generation = bridge.offer(prompt) catch return null;
        const value = bridge.wait(generation, 60_000) catch return null;
        if (value.len > answer.len) return null;
        @memcpy(answer[0..value.len], value);
        return answer[0..value.len];
    }

    /// Builds a UI-owned session runtime for an explicit host target.
    /// Copies all strings so the caller's slices may be arena-owned (hosts.toml).
    pub fn initForHost(allocator: std.mem.Allocator, io: std.Io, app_config: config.Config, target: HostTarget) !*SessionRuntime {
        try validateTransportRoute(target);
        const host = try allocator.dupeSentinel(u8, target.host, 0);
        errdefer allocator.free(host);
        const terminal_type = try allocator.dupeSentinel(u8, target.terminal_type orelse app_config.ssh.term, 0);
        errdefer allocator.free(terminal_type);
        const user = try allocator.dupeSentinel(u8, target.user, 0);
        errdefer allocator.free(user);
        const password: ?[:0]u8 = if (target.password) |value| try allocator.dupeSentinel(u8, value, 0) else null;
        errdefer if (password) |value| allocator.free(value);
        const identity_file: ?[:0]u8 = if (target.identity_file) |value| try allocator.dupeSentinel(u8, value, 0) else null;
        errdefer if (identity_file) |value| allocator.free(value);
        const key_passphrase: ?[:0]u8 = if (target.key_passphrase) |value| try allocator.dupeSentinel(u8, value, 0) else null;
        errdefer if (key_passphrase) |value| allocator.free(value);
        const runtime = try allocator.create(SessionRuntime);
        errdefer allocator.destroy(runtime);
        runtime.* = undefined;
        runtime.library = try allocator.create(Library);
        errdefer allocator.destroy(runtime.library);
        runtime.library.* = try Library.init();
        errdefer runtime.library.deinit();
        applog.info(.ssh, "session init: {s}@{s}:{d} auth={s}", .{ user, host, target.port, @tagName(target.auth_mode) });
        var worker_options = workerRuntimeOptions(app_config);
        worker_options.scrollback = target.scrollback orelse app_config.ui.scrollback_limit;
        // Per-host values override global SSH policy when present; absent host
        // fields inherit the persisted application settings.
        worker_options.keepalive_sec = if (target.keepalive orelse true) app_config.ssh.keepalive_sec else 0;
        worker_options.compression = target.compression orelse app_config.ssh.compression;
        worker_options.startup_commands = target.startup_commands;
        worker_options.initial_input = target.initial_input;
        worker_options.wait_for_attachment = true;
        worker_options.connect_timeout_ms = @as(u32, @max(app_config.ssh.connect_timeout_sec, 1)) * 1000;
        var route_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer route_arena.deinit();
        const connection_options = try prepareConnectionOptions(route_arena.allocator(), app_config, target, .session);
        const direct_options = connection_options[connection_options.len - 1];
        if (connection_options.len > 1) worker_options.jump_options = connection_options;
        const worker = SshWorker.init(allocator, runtime.library, direct_options, worker_options) catch |err| {
            applog.err(.ssh, "session init FAILED {s}@{s}:{d}: {s}", .{ user, host, target.port, @errorName(err) });
            return err;
        };
        applog.info(.ssh, "session init done: worker+pty+loop ready", .{});
        errdefer worker.deinit();
        const checkpoint = try allocator.create(CheckpointController);
        errdefer allocator.destroy(checkpoint);
        // One namespace per runtime; simultaneous tabs never overwrite each
        // other's checkpoint or raw ring. Log failure does not prevent SSH.
        var paths = try Paths.forApplication(allocator);
        defer paths.deinit();
        const now_ms = realtime.milliseconds(worker);
        const log_id = next_log_id.fetchAdd(1, .monotonic);
        const checkpoint_path = try std.fmt.allocPrint(allocator, "logs/session-{d}-{d}-{d}.checkpoint", .{ std.c.getpid(), now_ms, log_id });
        errdefer allocator.free(checkpoint_path);
        const raw_path = try std.fmt.allocPrint(allocator, "logs/session-{d}-{d}-{d}.raw", .{ std.c.getpid(), now_ms, log_id });
        errdefer allocator.free(raw_path);
        const log_directory: ?std.Io.Dir = std.Io.Dir.cwd().createDirPathOpen(io, paths.directory, .{}) catch null;
        errdefer if (log_directory) |dir| dir.close(io);
        checkpoint.* = try CheckpointController.init(
            allocator,
            @as(usize, app_config.log.ring_mb) * 1024 * 1024,
            app_config.log.checkpoint_sec,
            now_ms,
            io,
            log_directory orelse std.Io.Dir.cwd(),
            checkpoint_path,
        );
        if (log_directory != null) checkpoint.enableRawFile(raw_path) catch |err| {
            applog.err(.ssh, "session recording unavailable: {s}", .{@errorName(err)});
        };
        errdefer checkpoint.deinit();
        if (log_directory != null) worker.bindCheckpoint(checkpoint);
        const thread = try WorkerThread.start(allocator, worker);
        errdefer thread.deinit();
        applog.info(.ssh, "worker thread started", .{});
        runtime.* = .{
            .allocator = allocator,
            .library = runtime.library,
            .worker = worker,
            .thread = thread,
            .checkpoint = checkpoint,
            .host = host,
            .user = user,
            .terminal_type = terminal_type,
            .password = password,
            .identity_file = identity_file,
            .key_passphrase = key_passphrase,
            .log_directory = log_directory,
            .checkpoint_path = checkpoint_path,
            .raw_path = raw_path,
            .started_ms = now_ms,
            .saved_connection_id = if (target.source_owner) |owner| @backingInt(owner.id) else null,
            .host_key_bridge = target.host_key_bridge,
            .keyboard_bridge = target.keyboard_bridge,
            .cancel_token = target.cancel_token,
            .route_arena = route_arena,
            .resource_ledger = target.resource_ledger,
        };
        return runtime;
    }

    /// Idempotent member teardown: stops the worker thread, closes the socket
    /// and frees all owned members. Does NOT free the SessionRuntime struct
    /// itself — repeated calls are no-ops, so every caller (scope cleanup,
    /// Workspace cleanup, closeTab, failure drains) can invoke it without a
    /// teardown/destroy double-free protocol.
    pub fn teardown(self: *SessionRuntime) void {
        self.cancelOwnedWork();
        self.torn_down = true;
        self.release.finish(self, releaseOwned);
    }

    pub fn releaseStep(self: *SessionRuntime, archive: ?ArchiveRequest) ReleaseReceipt {
        if (self.release.state.load(.acquire) == .idle) {
            self.archive_request = archive;
            self.cancelOwnedWork();
            self.torn_down = true;
        }
        return self.release.request(self, releaseOwned);
    }

    fn cancelOwnedWork(self: *SessionRuntime) void {
        switch (self.release.state.load(.acquire)) {
            .running, .released => return,
            .idle, .awaiting, .unknown => {},
        }
        if (self.cancel_token) |token| token.store(true, .release);
        if (self.host_key_bridge) |bridge| bridge.cancel();
        if (self.keyboard_bridge) |bridge| bridge.cancel();
        self.worker.invalidateInput();
        self.thread.requestStop();
    }

    fn releaseOwned(raw: *anyopaque) ReleaseReceipt {
        const self: *SessionRuntime = @ptrCast(@alignCast(raw));
        // Archive final output only once the IO owner has stopped. All joins,
        // filesystem IO and reverse target/relay/hop teardown stay off the UI.
        self.thread.stopAndJoin();
        const receipt = self.worker.releaseConnection();
        if (receipt != .released) return receipt;
        if (self.archive_request) |request| self.persistClosedArchive(request.session_id, request.retention_days) catch |err| {
            applog.warn(.workspace, "session {d} archive failed: {s}", .{ request.session_id, @errorName(err) });
        };
        self.thread.deinit(); // joins the worker thread and frees worker+thread
        const log_io = self.checkpoint.io;
        self.checkpoint.deinit();
        if (self.log_directory) |dir| dir.close(log_io);
        self.allocator.free(self.checkpoint_path);
        self.allocator.free(self.raw_path);
        self.allocator.destroy(self.checkpoint);
        self.library.deinit();
        self.allocator.destroy(self.library);
        self.allocator.free(self.host);
        self.allocator.free(self.user);
        self.allocator.free(self.terminal_type);
        if (self.password) |value| self.allocator.free(value);
        if (self.identity_file) |value| self.allocator.free(value);
        if (self.key_passphrase) |value| self.allocator.free(value);
        if (self.route_arena) |*arena| arena.deinit();
        return .released;
    }

    /// Full cleanup: teardown + struct free. Reserved for the single owner of
    /// the struct's memory — the scope cleanup entry (registration-order
    /// teardown at app quit). Everyone else calls teardown().
    pub fn cleanup(self: *SessionRuntime) void {
        _ = self.cleanupReleased();
    }

    /// Final destruction must retain the complete runtime when native cleanup
    /// has not finished; its original job continues to own that graph.
    pub fn cleanupReleased(self: *SessionRuntime) bool {
        const allocator = self.allocator;
        self.teardown();
        if (self.release.state.load(.acquire) != .released) return false;
        allocator.destroy(self);
        return true;
    }

    pub fn resourceSnapshot(self: *SessionRuntime) ?ResourceLedger.Snapshot {
        const ledger = self.resource_ledger orelse return null;
        return ledger.snapshot();
    }

    pub fn reconnectSnapshot(self: *SessionRuntime) ?@import("../vt/reconnect.zig").Control.Snapshot {
        if (self.torn_down) return null;
        return self.thread.reconnectSnapshot();
    }

    /// Main-thread request only. The existing worker consumes the grant and
    /// performs native release/rebuild under its original thread ownership.
    pub fn requestReconnect(self: *SessionRuntime, previous: OperationKey, next: OperationKey) !void {
        if (self.torn_down) return error.SessionClosed;
        try self.thread.requestReconnect(previous, next);
    }

    pub fn acknowledgeAttached(self: *SessionRuntime, key: OperationKey) bool {
        if (self.torn_down) return false;
        return self.thread.markAttached(key);
    }

    pub fn workerPtr(self: *SessionRuntime) *SshWorker {
        return self.worker;
    }

    pub fn threadPtr(self: *SessionRuntime) *WorkerThread {
        return self.thread;
    }

    /// Exports the worker-owned bounded timeline through the caller-owned IO root.
    /// Zenit/UI code supplies its existing std.Io and app data directory.
    pub fn exportTimeline(self: *SessionRuntime, io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
        if (self.torn_down) return error.SessionClosed;
        try self.worker.exportTimeline(io, dir, path);
    }

    /// Persists the retained recording before teardown frees the timeline and
    /// directory. The bounded timeline is not a complete lifetime recording.
    pub fn archiveClosed(self: *SessionRuntime, session_id: u64, retention_days: u16) !void {
        if (self.torn_down) return error.SessionClosed;
        try self.persistClosedArchive(session_id, retention_days);
    }

    fn persistClosedArchive(self: *SessionRuntime, session_id: u64, retention_days: u16) !void {
        if (self.archive_written) return;
        const dir = self.log_directory orelse return error.LogDirectoryUnavailable;
        const dimensions = self.worker.resize_dims.load(.acquire);
        try archiveTimeline(self.allocator, self.checkpoint.io, dir, self.worker.timelinePtr(), .{
            .id = session_id,
            .saved_connection_id = self.saved_connection_id,
            .started_ms = self.started_ms,
            .ended_ms = realtime.milliseconds(undefined),
            .host = self.host,
            .user = self.user,
        }, if (dimensions == 0) self.worker.options.cols else @truncate(dimensions), if (dimensions == 0) self.worker.options.rows else @truncate(dimensions >> 16), retention_days);
        self.archive_written = true;
    }
};

const ClosedSession = struct {
    id: u64,
    saved_connection_id: ?u64 = null,
    started_ms: i64,
    ended_ms: i64,
    host: []const u8,
    user: []const u8,
};

/// Reject before allocating credentials or attempting any network operation.
/// A direct-tcpip channel needs a byte relay before it can back a target session.
pub fn validateTransportRoute(target: HostTarget) !void {
    try validateConnectionTarget(target, .session);
}

fn validateConnectionTarget(target: HostTarget, purpose: Purpose) !void {
    if (purpose == .transfer_binding) return error.UnsupportedPurpose;
    if (target.protocol == .sftp) {
        if (purpose != .@"test") return error.UnsupportedProtocol;
        if (target.route.len != 0 or target.jump_chain.len != 0) return error.ProxyJumpTransportUnavailable;
    } else if (target.protocol != .ssh) return error.UnsupportedProtocol;
    if (target.source_owner) |owner| if (@backingInt(owner.id) == 0 or owner.revision == 0) return error.InvalidIdentity;
    if (target.operation_key) |key| {
        if (key.operation_id == 0) return error.InvalidOperation;
        if (purpose == .session and key.owner != .session) return error.InvalidOperation;
        if (purpose == .@"test" and (key.owner != .app or key.attempt_id == null or key.attempt_id == 0)) return error.InvalidOperation;
    } else if (purpose == .@"test") return error.InvalidOperation;
    if (target.port == 0 or target.host.len == 0 or target.user.len == 0) return error.InvalidEndpoint;
    for ([_][]const u8{ target.host, target.user, target.terminal_type orelse "xterm-256color" }) |value| {
        if (value.len == 0 or !std.unicode.utf8ValidateSlice(value)) return error.InvalidEndpoint;
        for (value) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidEndpoint;
    }
    for ([_]?[]const u8{ target.password, target.identity_file, target.key_passphrase }) |value| if (value) |text| {
        if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidEmbeddedNul;
    };
    if (target.route.len == 0 and target.jump_chain.len != 0) return error.UnmigratedRoute;
    if (target.route.len > 8) return error.TooManyHops;
    if (target.jump_hosts.len != target.route.len) return error.MissingRouteReference;
    for (target.route, target.jump_hosts, 0..) |id, hop, index| {
        if (@backingInt(id) == 0 or hop.connection_id != id) return error.RouteOwnerMismatch;
        if (target.source_owner) |owner| if (id == owner.id) return error.RouteCycle;
        for (target.route[0..index]) |previous| if (id == previous) return error.DuplicateRoute;
        try hop.validate();
        if (hop.protocol != .ssh) return error.InvalidRouteProtocol;
        if (hop.route.len != 0 or hop.jump_chain.len != 0) return error.NestedRouteUnsupported;
        if (hop.port == target.port and std.mem.eql(u8, hop.host, target.host)) return error.RouteCycle;
        for (target.jump_hosts[0..index]) |previous| if (hop.port == previous.port and std.mem.eql(u8, hop.host, previous.host)) return error.RouteCycle;
    }
}

/// Formal creation and probes freeze the identical endpoint/route/auth/policy
/// plan. All returned strings/options belong to the caller's arena; typed
/// bridges, store and cancel token remain the original attempt-owned handles.
pub fn prepareConnectionOptions(allocator: std.mem.Allocator, app_config: config.Config, target: HostTarget, purpose: Purpose) ![]Options {
    try validateConnectionTarget(target, purpose);
    const options = try allocator.alloc(Options, target.jump_hosts.len + 1);
    for (target.jump_hosts, 0..) |hop, index| options[index] = try routeHostOptions(allocator, hop, target, app_config, index);
    const password = if (target.password) |value| try allocator.dupeSentinel(u8, value, 0) else null;
    const key_path = if (target.identity_file) |value| try allocator.dupeSentinel(u8, value, 0) else null;
    const passphrase = if (target.key_passphrase) |value| try allocator.dupeSentinel(u8, value, 0) else null;
    options[options.len - 1] = sessionOptions(target, try sessionAuth(target.auth_mode, password, key_path, passphrase), try allocator.dupeSentinel(u8, target.host, 0), try allocator.dupeSentinel(u8, target.user, 0), try allocator.dupeSentinel(u8, target.terminal_type orelse app_config.ssh.term, 0), app_config);
    for (options, 0..) |*option, index| {
        option.open_shell = purpose == .session and index + 1 == options.len;
        option.details_source = if (purpose == .session) .session else .@"test";
        try option.prepareDetails();
    }
    return options;
}

pub fn targetFromHost(host: hosts_mod.HostConfig, route_hosts: []const hosts_mod.HostConfig) HostTarget {
    return .{
        .source_owner = if (@backingInt(host.connection_id) != 0) host.owner() else null,
        .display_name = host.name,
        .protocol = host.protocol,
        .auth_mode = host.auth_mode,
        .strict_host_key_checking = host.strict_host_key_checking,
        .host = host.host,
        .port = host.port,
        .user = host.user,
        .password = host.password,
        .identity_file = host.identity_file,
        .key_passphrase = host.key_passphrase,
        .terminal_type = if (host.terminal_type_explicit) host.terminal_type else null,
        .scrollback = if (host.scrollback_explicit or host.scrollback != 25000) host.scrollback else null,
        .keepalive = host.keepalive,
        .compression = if (host.compression_explicit) host.compression else null,
        .startup_commands = host.startup_commands,
        .jump_chain = host.jump_chain,
        .route = host.route,
        .jump_hosts = route_hosts,
    };
}

pub fn resolveHostRoute(allocator: std.mem.Allocator, host: hosts_mod.HostConfig, registry: []const hosts_mod.HostConfig) ![]hosts_mod.HostConfig {
    try host.validate();
    if (host.route.len == 0 and host.jump_chain.len != 0) return error.UnmigratedRoute;
    const result = try allocator.alloc(hosts_mod.HostConfig, host.route.len);
    errdefer allocator.free(result);
    for (host.route, 0..) |id, index| {
        if (@backingInt(id) == 0) return error.InvalidIdentity;
        if (id == host.connection_id) return error.RouteCycle;
        for (host.route[0..index]) |previous| if (id == previous) return error.DuplicateRoute;
        var matched: ?hosts_mod.HostConfig = null;
        for (registry) |candidate| {
            if (candidate.connection_id != id) continue;
            if (matched != null) return error.DuplicateConnectionId;
            matched = candidate;
        }
        const hop = matched orelse return error.MissingRouteReference;
        try hop.validate();
        if (hop.protocol != .ssh) return error.InvalidRouteProtocol;
        if (hop.route.len != 0 or hop.jump_chain.len != 0) return error.NestedRouteUnsupported;
        if (host.port == hop.port and std.mem.eql(u8, host.host, hop.host)) return error.RouteCycle;
        for (result[0..index]) |previous| if (previous.port == hop.port and std.mem.eql(u8, previous.host, hop.host)) return error.RouteCycle;
        result[index] = hop;
    }
    return result;
}

fn sessionAuth(mode: hosts_mod.AuthMode, password: ?[:0]const u8, key_path: ?[:0]const u8, passphrase: ?[:0]const u8) !@import("../proto/ssh/session.zig").Auth {
    return switch (mode) {
        .agent => .agent,
        .password => if (password) |value| .{ .password = value } else .password_prompt,
        .private_key => .{ .private_key = .{ .path = key_path orelse return error.MissingIdentityFile, .passphrase = passphrase } },
    };
}

fn sessionOptions(target: HostTarget, auth: @import("../proto/ssh/session.zig").Auth, host: [:0]const u8, user: [:0]const u8, term: [:0]const u8, app_config: config.Config) Options {
    return .{
        .host = host,
        .port = target.port,
        .user = user,
        .term = term,
        .auth = auth,
        .source_owner = target.source_owner,
        .strict_host_key_checking = target.strict_host_key_checking,
        .operation_key = target.operation_key,
        .resource_ledger = target.resource_ledger,
        .connection_details = target.connection_details,
        .display_name = target.display_name,
        .progress_observer = target.progress_observer,
        .attempt_id = if (target.operation_key) |key| key.attempt_id orelse 0 else 0,
        .hop_index = target.route.len,
        .hop_count = target.route.len + 1,
        .connect_timeout_ms = @as(u32, @max(app_config.ssh.connect_timeout_sec, 1)) * 1000,
        .keepalive_sec = if (target.keepalive orelse true) app_config.ssh.keepalive_sec else 0,
        .compression = target.compression orelse app_config.ssh.compression,
        .host_key_store = target.host_key_store,
        .host_key_observer = if (target.host_key_bridge) |bridge| .{ .ctx = bridge, .callback = @import("host_key_confirmation.zig").Bridge.observer } else null,
        .cancel_token = target.cancel_token,
        .keyboard_prompt = if (target.keyboard_bridge) |bridge| .{ .ctx = bridge, .callback = SessionRuntime.keyboardAnswer } else null,
        .auth_interaction = if (target.operation_key != null) blk: {
            const bridge = target.keyboard_bridge orelse break :blk null;
            break :blk .{ .bridge = bridge, .presentation = if (app_config.ssh.otp_modal) .otp_modal else .protected_form, .presentation_config_revision = app_config.config_revision };
        } else null,
    };
}

fn routeHostOptions(allocator: std.mem.Allocator, host: hosts_mod.HostConfig, target: HostTarget, app_config: config.Config, hop_index: usize) !Options {
    var hop = target;
    hop.source_owner = host.owner();
    hop.display_name = host.name;
    hop.auth_mode = host.auth_mode;
    hop.strict_host_key_checking = host.strict_host_key_checking;
    hop.port = host.port;
    hop.keepalive = host.keepalive;
    hop.compression = if (host.compression_explicit) host.compression else null;
    const password = if (host.password) |value| try allocator.dupeSentinel(u8, value, 0) else null;
    const key_path = if (host.identity_file) |value| try allocator.dupeSentinel(u8, value, 0) else null;
    const passphrase = if (host.key_passphrase) |value| try allocator.dupeSentinel(u8, value, 0) else null;
    var options = sessionOptions(hop, try sessionAuth(host.auth_mode, password, key_path, passphrase), try allocator.dupeSentinel(u8, host.host, 0), try allocator.dupeSentinel(u8, host.user, 0), try allocator.dupeSentinel(u8, if (host.terminal_type_explicit) host.terminal_type else app_config.ssh.term, 0), app_config);
    options.hop_index = hop_index;
    return options;
}

test "runtime release returns awaiting without joining and publishes only after cleanup" {
    const Owner = struct {
        allow_release: std.atomic.Value(bool) = .init(false),
        calls: usize = 0,
        session: @import("../proto/ssh/session.zig").Session,
        fn cleanup(raw: *anyopaque) ReleaseReceipt {
            const self: *@This() = @ptrCast(@alignCast(raw));
            while (!self.allow_release.load(.acquire)) std.Thread.yield() catch {};
            self.session.close();
            self.calls += 1;
            return .released;
        }
    };
    const native = @import("generated_ssh_session");
    const pair = try @import("../proto/ssh/socket_relay.zig").Pair.create();
    defer native.zw_ssh_socket_close(pair.relay_fd);
    var owner: Owner = .{ .session = .{ .state = .active, .socket_fd = pair.target_fd } };
    var release: DeferredRelease = .{};
    defer {
        owner.allow_release.store(true, .release);
        release.finish(&owner, Owner.cleanup);
    }
    try std.testing.expectEqual(ReleaseReceipt.awaiting, release.request(&owner, Owner.cleanup));
    // The real background thread is deliberately held. A repeated UI poll
    // cannot join it or turn accepted cancellation into a release receipt.
    try std.testing.expectEqual(ReleaseReceipt.awaiting, release.request(&owner, Owner.cleanup));
    try std.testing.expect(std.c.fcntl(pair.target_fd, std.c.F.GETFL, @as(c_int, 0)) >= 0);
    owner.allow_release.store(true, .release);
    release.finish(&owner, Owner.cleanup);
    try std.testing.expectEqual(ReleaseReceipt.released, release.request(&owner, Owner.cleanup));
    try std.testing.expectEqual(@as(usize, 1), owner.calls);
    try std.testing.expectEqual(@as(c_int, -1), std.c.fcntl(pair.target_fd, std.c.F.GETFL, @as(c_int, 0)));
}

test "runtime unknown cleanup retains owner and does not retry on UI polls" {
    const Owner = struct {
        calls: usize = 0,
        fn cleanup(raw: *anyopaque) ReleaseReceipt {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return .released;
        }
    };
    var owner: Owner = .{};
    var release: DeferredRelease = .{ .state = .init(.unknown) };
    try std.testing.expectEqual(ReleaseReceipt.unknown, release.request(&owner, Owner.cleanup));
    try std.testing.expectEqual(ReleaseReceipt.unknown, release.request(&owner, Owner.cleanup));
    try std.testing.expectEqual(@as(usize, 0), owner.calls);
    release.finish(&owner, Owner.cleanup);
    try std.testing.expectEqual(@as(usize, 1), owner.calls);
}

test "runtime cancellation invalidates typed authentication and original worker token" {
    var token: std.atomic.Value(bool) = .init(false);
    var host_key: @import("host_key_confirmation.zig").Bridge = .{};
    var auth: InteractiveBridge = .{};
    _ = try auth.offer("Password:");
    var thread: WorkerThread = undefined;
    thread.stop_requested = .init(false);
    thread.reconnect_control = @import("../vt/reconnect.zig").Control.init(null);
    var worker: SshWorker = undefined;
    worker.replay = try @import("../vt/reconnect_replay.zig").Replay.init(std.testing.allocator, 16);
    defer worker.replay.deinit();
    var runtime: SessionRuntime = undefined;
    runtime.release = .{};
    runtime.host_key_bridge = &host_key;
    runtime.keyboard_bridge = &auth;
    runtime.cancel_token = &token;
    runtime.thread = &thread;
    runtime.worker = &worker;
    runtime.cancelOwnedWork();
    try std.testing.expect(token.load(.acquire));
    try std.testing.expect(host_key.cancelled.load(.acquire));
    try std.testing.expect(thread.stop_requested.load(.acquire));
    try std.testing.expectError(error.Cancelled, auth.offer("late password"));
}

test "session runtime rejects configured jump before direct connect" {
    try std.testing.expectError(error.UnmigratedRoute, validateTransportRoute(.{
        .host = "127.0.0.1",
        .user = "test",
        .jump_chain = &.{"bastion"},
    }));
    try validateTransportRoute(.{ .host = "127.0.0.1", .user = "test" });
}

test "session runtime authenticates only the explicit frozen mode" {
    try std.testing.expect((try sessionAuth(.agent, "unused", "/unused/key", "unused")) == .agent);
    try std.testing.expect((try sessionAuth(.password, null, "/unused/key", null)) == .password_prompt);
    try std.testing.expectEqualStrings("password", (try sessionAuth(.password, "password", "/unused/key", null)).password);
    const key = try sessionAuth(.private_key, "unused", "/chosen/key", "phrase");
    try std.testing.expectEqualStrings("/chosen/key", key.private_key.path);
    try std.testing.expectEqualStrings("phrase", key.private_key.passphrase.?);
    try std.testing.expectError(error.MissingIdentityFile, sessionAuth(.private_key, "unused", null, null));
}

test "session runtime uses the original operation and each hops own policy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bridge: InteractiveBridge = .{};
    const key: OperationKey = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(85), .generation = 3 } }, .operation_id = 19, .attempt_id = 2 };
    var app_config: config.Config = .{};
    app_config.config_revision = 44;
    app_config.ssh.otp_modal = false;
    app_config.ssh.keepalive_sec = 47;
    const target: HostTarget = .{
        .source_owner = .{ .id = @fromBackingInt(100), .revision = 7 },
        .host = "target.test",
        .user = "target",
        .operation_key = key,
        .auth_mode = .password,
        .strict_host_key_checking = false,
        .keepalive = false,
        .terminal_type = "vt100",
        .keyboard_bridge = &bridge,
        .route = &.{@fromBackingInt(200)},
    };
    const direct = sessionOptions(target, try sessionAuth(target.auth_mode, null, null, null), "target.test", "target", "vt100", app_config);
    try std.testing.expect(direct.operation_key.?.eql(key));
    try std.testing.expectEqualDeep(target.source_owner, direct.source_owner);
    try std.testing.expect(!direct.strict_host_key_checking);
    try std.testing.expect(direct.auth == .password_prompt);
    try std.testing.expectEqual(@as(usize, 1), direct.hop_index);
    try std.testing.expectEqual(@as(usize, 2), direct.hop_count);
    try std.testing.expectEqual(@as(u64, 2), direct.attempt_id);
    try std.testing.expectEqual(@as(u16, 0), direct.keepalive_sec);
    try std.testing.expectEqualStrings("vt100", direct.term);
    try std.testing.expect(direct.auth_interaction.?.bridge == &bridge);
    try std.testing.expectEqual(@as(u64, 44), direct.auth_interaction.?.presentation_config_revision);
    try std.testing.expectEqual(@import("../proto/ssh/auth_challenge.zig").Presentation.protected_form, direct.auth_interaction.?.presentation);
    var path = "/hop/key".*;
    var source: hosts_mod.HostConfig = .{ .connection_id = @fromBackingInt(200), .revision = 12, .name = "hop", .host = "hop.test", .user = "jump", .auth_mode = .private_key, .identity_file = &path, .strict_host_key_checking = true };
    const hop = try routeHostOptions(arena.allocator(), source, target, app_config, 0);
    path[0] = 'x';
    source.revision = 13;
    source.strict_host_key_checking = false;
    try std.testing.expectEqualDeep(identity.AssetOwner{ .id = @fromBackingInt(200), .revision = 12 }, hop.source_owner.?);
    try std.testing.expect(hop.strict_host_key_checking);
    try std.testing.expectEqualStrings("hop.test", hop.host);
    try std.testing.expectEqualStrings("jump", hop.user);
    try std.testing.expectEqualStrings("/hop/key", hop.auth.private_key.path);
    try std.testing.expectEqual(@as(usize, 0), hop.hop_index);
    try std.testing.expectEqual(@as(usize, 2), hop.hop_count);
    try std.testing.expectEqual(@as(u16, 47), hop.keepalive_sec);
    try std.testing.expect(hop.operation_key.?.eql(key));
    try std.testing.expect(hop.auth_interaction.?.bridge == &bridge);
    const legacy = sessionOptions(.{ .host = "legacy", .user = "legacy", .keyboard_bridge = &bridge }, .agent, "legacy", "legacy", "vt100", app_config);
    try std.testing.expect(legacy.operation_key == null);
    try std.testing.expect(legacy.source_owner == null);
    try std.testing.expect(legacy.auth_interaction == null);
    try std.testing.expect(legacy.auth == .agent);
}

test "session runtime route identity validation ignores display names and rejects mismatches" {
    const hops = [_]hosts_mod.HostConfig{
        .{ .connection_id = @fromBackingInt(200), .revision = 12, .name = "renamed", .host = "hop.test", .user = "jump" },
    };
    var target: HostTarget = .{ .source_owner = .{ .id = @fromBackingInt(100), .revision = 7 }, .host = "target.test", .user = "test", .route = &.{@fromBackingInt(200)}, .jump_chain = &.{"old display name"}, .jump_hosts = &hops };
    try validateTransportRoute(target);
    target.route = &.{@fromBackingInt(201)};
    try std.testing.expectError(error.RouteOwnerMismatch, validateTransportRoute(target));
    target.route = &.{@fromBackingInt(200)};
    target.jump_hosts = &.{};
    try std.testing.expectError(error.MissingRouteReference, validateTransportRoute(target));
    target.jump_hosts = &hops;
    target.protocol = .sftp;
    try std.testing.expectError(error.UnsupportedProtocol, validateTransportRoute(target));
    target.protocol = .ssh;
    target.operation_key = .{ .owner = .app, .operation_id = 1 };
    try std.testing.expectError(error.InvalidOperation, validateTransportRoute(target));
}

fn archiveTimeline(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, timeline: *Timeline, closed: ClosedSession, cols: u16, rows: u16, retention_days: u16) !void {
    const path = try std.fmt.allocPrint(allocator, "logs/history/session-{d}-{d}-{d}.cast", .{ std.c.getpid(), closed.started_ms, closed.id });
    defer allocator.free(path);
    try timeline.saveCast(io, dir, path, cols, rows);
    // Never publish an index entry for a recording that failed to save.
    var archive = session_archive.Archive{ .allocator = allocator, .io = io, .dir = dir };
    archive.append(.{
        .id = closed.id,
        .source_kind = .ssh,
        .saved_connection_id = closed.saved_connection_id,
        .started_ms = closed.started_ms,
        .ended_ms = closed.ended_ms,
        .duration_ms = @intCast(@max(0, closed.ended_ms - closed.started_ms)),
        .host = closed.host,
        .user = closed.user,
        .cast_path = path,
    }) catch |err| {
        dir.deleteFile(io, path) catch {};
        return err;
    };
    _ = archive.prune(retention_days, closed.ended_ms) catch |err| {
        applog.warn(.workspace, "archive retention failed: {s}", .{@errorName(err)});
        return;
    };
}

test "closed runtime recording retains real identity times dimensions and output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var timeline = try Timeline.init(std.testing.allocator, 8, 1024);
    defer timeline.deinit();
    try timeline.append(10_000, 0, "hello\r\n");
    try timeline.append(11_000, 7, "world");
    try archiveTimeline(std.testing.allocator, std.testing.io, tmp.dir, &timeline, .{
        .id = 42,
        .saved_connection_id = 73,
        .started_ms = 9_000,
        .ended_ms = 12_000,
        .host = "host.example",
        .user = "alice",
    }, 132, 43, 14);
    const index = try tmp.dir.readFileAlloc(std.testing.io, "logs/history/index.tsv", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(index);
    try std.testing.expect(std.mem.startsWith(u8, index, "42\t9000\t12000\t3000\t"));
    try std.testing.expect(std.mem.indexOf(u8, index, "\thost.example\talice\t") != null);
    try std.testing.expect(std.mem.endsWith(u8, index, "\tssh\t73\n"));
    const path = try std.fmt.allocPrint(std.testing.allocator, "logs/history/session-{d}-9000-42.cast", .{std.c.getpid()});
    defer std.testing.allocator.free(path);
    const cast = try tmp.dir.readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(cast);
    try std.testing.expectEqualStrings("{\"version\":2,\"width\":132,\"height\":43}\n[0.000,\"o\",\"hello\\r\\n\"]\n[1.000,\"o\",\"world\"]\n", cast);
}

test "failed closed recording index leaves no orphan recording" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var timeline = try Timeline.init(std.testing.allocator, 8, 1024);
    defer timeline.deinit();
    try timeline.append(10_000, 0, "secret");
    try std.testing.expectError(error.InvalidArchiveField, archiveTimeline(std.testing.allocator, std.testing.io, tmp.dir, &timeline, .{
        .id = 43,
        .started_ms = 9_000,
        .ended_ms = 12_000,
        .host = "host\ninvalid",
        .user = "alice",
    }, 80, 24, 14));
    const path = try std.fmt.allocPrint(std.testing.allocator, "logs/history/session-{d}-9000-43.cast", .{std.c.getpid()});
    defer std.testing.allocator.free(path);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, path, .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "logs/history/index.tsv", .{}));
}

pub fn cleanupRuntime(runtime: *SessionRuntime) void {
    runtime.cleanup();
}

test "runtime policy follows persisted log and reconnect configuration" {
    var app_config: config.Config = .{};
    app_config.log.ring_mb = 12;
    app_config.ssh.reconnect_max = 3;
    app_config.ssh.reconnect_backoff = .{ 2, 3, 5, 8, 13 };
    const runtime = workerRuntimeOptions(app_config);
    try std.testing.expectEqual(@as(usize, 12 * 1024 * 1024), runtime.timeline_max_bytes);
    try std.testing.expectEqual(@as(u8, 3), runtime.reconnect_max);
    try std.testing.expectEqualSlices(u8, &app_config.ssh.reconnect_backoff, &runtime.reconnect_backoff);
}

test "disabled reconnect and disconnected input settings reach the worker policy" {
    var value: config.Config = .{};
    value.ssh.auto_reconnect = false;
    value.ssh.buffer_input = false;
    var runtime = workerRuntimeOptions(value);
    try std.testing.expect(!runtime.auto_reconnect);
    try std.testing.expect(!runtime.buffer_input);
    value.ssh.auto_reconnect = true;
    value.ssh.reconnect_max = 0;
    runtime = workerRuntimeOptions(value);
    try std.testing.expect(!runtime.auto_reconnect);
}

test "SSH host inheritance resolves parsed omissions and explicit defaults through connection factory" {
    var registry = try hosts_mod.Registry.parse(std.testing.allocator, "[[hosts]] name=\"inherited\";host=\"h\";user=\"u\"\n" ++
        "[[hosts]] name=\"explicit\";host=\"h\";user=\"u\";terminal_type=\"xterm-256color\";compression=false\n");
    defer registry.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg: config.Config = .{};
    cfg.ssh.term = "vt100";
    cfg.ssh.compression = true;
    cfg.ssh.keepalive_sec = 2;
    const inherited = (try prepareConnectionOptions(arena.allocator(), cfg, targetFromHost(registry.hosts[0], &.{}), .session))[0];
    try std.testing.expectEqualStrings("vt100", inherited.term);
    try std.testing.expect(inherited.compression);
    try std.testing.expectEqual(@as(u16, 2), inherited.keepalive_sec);
    const explicit = (try prepareConnectionOptions(arena.allocator(), cfg, targetFromHost(registry.hosts[1], &.{}), .session))[0];
    try std.testing.expectEqualStrings("xterm-256color", explicit.term);
    try std.testing.expect(!explicit.compression);
    const programmatic: hosts_mod.HostConfig = .{ .name = "custom", .host = "h", .user = "u", .terminal_type = "ansi", .compression = true };
    const custom = (try prepareConnectionOptions(arena.allocator(), .{}, targetFromHost(programmatic, &.{}), .session))[0];
    try std.testing.expectEqualStrings("ansi", custom.term);
    try std.testing.expect(custom.compression);
    for (registry.hosts, 0..) |hop, index| {
        var routed = targetFromHost(programmatic, registry.hosts[index .. index + 1]);
        routed.host = "target.example";
        routed.route = &.{hop.connection_id};
        const options = try prepareConnectionOptions(arena.allocator(), cfg, routed, .session);
        try std.testing.expectEqualStrings(if (index == 0) "vt100" else "xterm-256color", options[0].term);
        try std.testing.expectEqual(index == 0, options[0].compression);
    }
}
