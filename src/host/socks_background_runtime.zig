//! A registered SSH session whose only workload is forwarding. The target's
//! native Session belongs to this worker; upstream Sessions keep Route Relay
//! owners. Controllers receive facades and immutable snapshots, never sockets.
const std = @import("std");
const sessions = @import("session_host.zig");
const identity = @import("identity.zig");
const operations = @import("operation.zig");
const files = @import("file_binding_host.zig");
const routing = @import("file_route_factory.zig");
const ssh = @import("../proto/ssh/session.zig");
const Forward = @import("../proto/ssh/forward_service.zig");
pub const auth = @import("../proto/ssh/auth_challenge.zig");
pub const host_key = @import("../ui/host_key_confirmation.zig");
const hosts = @import("../config/hosts.zig");
const Frozen = @import("../ui/session_lifecycle.zig").Snapshot;
const realtime = @import("../platform/realtime.zig");
const Totp = @import("../proto/ssh/totp_prefill.zig");
const c = @import("generated_ssh_session");

pub const Phase = enum(u8) { connecting, ready, paused, failed, closing, cleanup_unknown, closed };
pub const Policy = struct {
    presentation: auth.Presentation = .protected_form,
    presentation_config_revision: u64 = 1,
    timeout_ms: u32 = 15_000,
    totp_autofill: bool = false,
    automatic_reconnect: bool = true,
    reconnect_max: u8 = 5,
    reconnect_backoff: [5]u8 = .{ 1, 2, 4, 8, 16 },
};
pub const Snapshot = struct {
    owner: identity.SessionHandle,
    key: operations.OperationKey,
    source: identity.AssetOwner,
    phase: Phase,
    lifecycle: sessions.Lifecycle,
    protocol_cleanup: sessions.CloseReceipt,
    cleanup: sessions.CloseReceipt,
    failure: ?anyerror,
    listeners: u32,
    connections_active: u32,
    bytes_up: u64,
    bytes_down: u64,
};
const Waiting = struct { key: operations.OperationKey, step: sessions.CloseStep, last: sessions.CloseReceipt };
const Entry = struct {
    runtime: *Runtime,
    owner: identity.SessionHandle,
    key: operations.OperationKey,
    replacement_failure: ?anyerror = null,
    ready_published: bool = false,
    failure_published: bool = false,
    cleanup_published: ?sessions.CloseReceipt = null,
    waiting: ?Waiting = null,
    reconnect_deadline_ns: ?i128 = null,
    reconnect_count: u8 = 0,
};

pub const Host = struct {
    allocator: std.mem.Allocator,
    domain: *sessions.SessionHost,
    library: ssh.Library,
    known_hosts_path: []u8,
    policy: Policy,
    entries: std.ArrayList(Entry) = .empty,
    shutting_down: bool = false,

    /// Allocation/configuration only. No connection, PTY, shell, or Tab starts.
    pub fn init(allocator: std.mem.Allocator, domain: *sessions.SessionHost, known_hosts_path: []const u8, policy: Policy) !*Host {
        if (!std.fs.path.isAbsolute(known_hosts_path) or policy.timeout_ms == 0 or policy.presentation_config_revision == 0) return error.InvalidBackgroundPolicy;
        const self = try allocator.create(Host);
        errdefer allocator.destroy(self);
        const path = try allocator.dupe(u8, known_hosts_path);
        errdefer allocator.free(path);
        var library = try ssh.Library.init();
        errdefer library.deinit();
        self.* = .{ .allocator = allocator, .domain = domain, .known_hosts_path = path, .library = library, .policy = policy };
        return self;
    }

    /// Called by the existing SSH adapter, while SessionHost owns create/retry.
    /// Publication is deferred to safeTick; no reentrant domain callbacks.
    pub fn queue(self: *Host, request: sessions.CreateRequest) !void {
        if (self.shutting_down) return error.BackgroundClosing;
        if (request.spec.purpose() != .socks_background or request.spec != .saved or request.spec.saved.protocol != .ssh) return error.InvalidSessionPurpose;
        if (request.key.owner != .session or !request.key.owner.session.eql(request.handle)) return error.InvalidOperationOwner;
        for (self.entries.items) |*entry| if (entry.runtime.source.value.owner.session_id == request.handle.session_id) {
            // A retained listening port still belongs to this original owner.
            // An OOM before acquiring a replacement transport must not drop
            // that owner or make it unreachable through the new domain grant.
            var replacement_failure: ?anyerror = null;
            entry.runtime.replace(request) catch |err| {
                replacement_failure = err;
            };
            const count = entry.reconnect_count;
            entry.* = .{ .runtime = entry.runtime, .owner = request.handle, .key = request.key, .replacement_failure = replacement_failure, .reconnect_count = count };
            return;
        };
        if (self.entries.items.len == 32) return error.BackgroundLimit;
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        const runtime = try Runtime.start(self.allocator, request, &self.library, self.known_hosts_path, self.policy);
        self.entries.appendAssumeCapacity(.{ .runtime = runtime, .owner = request.handle, .key = request.key });
    }

    pub fn owns(self: *Host, owner: identity.SessionHandle) bool {
        return self.find(owner) != null;
    }
    pub fn cancel(self: *Host, key: operations.OperationKey) sessions.CloseReceipt {
        const entry = self.findKey(key) orelse return .unknown;
        entry.reconnect_deadline_ns = null;
        // The authentication UI also cancels the domain create operation after
        // cancelling its challenge. That ends only this transport attempt;
        // retained listeners still belong to the explicit reconnect owner.
        if (entry.runtime.authentication_cancelled.load(.acquire)) return entry.runtime.parentReceipt();
        entry.runtime.requestStop();
        return entry.runtime.closeReceipt();
    }
    pub fn releaseStale(self: *Host, owner: identity.SessionHandle, key: operations.OperationKey) void {
        const entry = self.find(owner) orelse return;
        if (entry.key.eql(key)) entry.runtime.requestStop();
    }
    pub fn requestStop(self: *Host, owner: identity.SessionHandle) sessions.CloseReceipt {
        const entry = self.find(owner) orelse return .released;
        entry.reconnect_deadline_ns = null;
        entry.runtime.requestStop();
        // This public call is an explicit user retry, unlike periodic ticks.
        entry.runtime.retry_cleanup.store(true, .release);
        return entry.runtime.closeReceipt();
    }
    pub fn closeStep(self: *Host, owner: identity.SessionHandle, key: operations.OperationKey, step: sessions.CloseStep) sessions.CloseReceipt {
        const entry = self.find(owner) orelse return .unknown;
        const state = self.domain.queryState(owner) orelse return .unknown;
        if (state.close_operation == null or !state.close_operation.?.eql(key)) return .unknown;
        if (step != .release_forwards and step != .close_protocol) return .released;
        entry.reconnect_deadline_ns = null;
        entry.runtime.requestStop();
        const receipt = entry.runtime.closeReceipt();
        if (receipt != .released) entry.waiting = .{ .key = key, .step = step, .last = receipt };
        return receipt;
    }

    /// No borrowing a Session across threads. The caller must first obtain the
    /// current original forward binding from SessionHost.
    pub fn forwardService(self: *Host, binding: sessions.ServiceHandle, exit_index: ?usize) !*Forward.Service {
        if (binding.kind != .forward or binding.origin_session == null or !self.domain.bindingIsLive(binding)) return error.StaleForwardBinding;
        const entry = self.find(binding.origin_session.?) orelse return error.StaleSession;
        const runtime = entry.runtime;
        if (entry.replacement_failure != null or !runtime.source.value.create_key.eql(entry.key) or !runtime.ready.load(.acquire) or runtime.failed.load(.acquire) or runtime.closing.load(.acquire)) return error.ServiceUnavailable;
        const index = exit_index orelse runtime.forwards.len - 1;
        if (exit_index != null and index >= runtime.forwards.len - 1) return error.InvalidSocksExit;
        return runtime.forwards[index].?;
    }
    pub fn retry(self: *Host, owner: identity.SessionHandle) !sessions.Accepted {
        const entry = self.find(owner) orelse return error.StaleSession;
        if (entry.runtime.parentReceipt() != .released) return error.CleanupNotReleased;
        entry.reconnect_deadline_ns = null;
        return self.domain.retry(owner);
    }
    pub fn snapshots(self: *Host, allocator: std.mem.Allocator) ![]Snapshot {
        var result: std.ArrayList(Snapshot) = .empty;
        errdefer result.deinit(allocator);
        try result.ensureTotalCapacity(allocator, self.entries.items.len);
        for (self.entries.items) |entry| {
            const source = entry.runtime.source.value;
            const state = self.domain.queryState(entry.owner) orelse continue;
            if (state.lifecycle == .closed) continue;
            var value: Snapshot = .{ .owner = entry.owner, .key = entry.key, .source = .{ .id = source.spec.saved.connection_id, .revision = source.spec.saved.config_revision }, .phase = if (entry.replacement_failure != null) .failed else entry.runtime.phase.load(.acquire), .lifecycle = state.lifecycle, .protocol_cleanup = entry.runtime.parentReceipt(), .cleanup = entry.runtime.closeReceipt(), .failure = if (entry.replacement_failure) |reason| reason else entry.runtime.failureReason(), .listeners = 0, .connections_active = 0, .bytes_up = 0, .bytes_down = 0 };
            for (entry.runtime.forwards) |maybe| if (maybe) |service| {
                const status = service.snapshot();
                value.listeners += @intFromBool(status.cleanup != .released);
                value.connections_active +|= status.stats.connections_active;
                value.bytes_up +|= status.stats.bytes_up;
                value.bytes_down +|= status.stats.bytes_down;
            };
            result.appendAssumeCapacity(value);
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn safeTick(self: *Host) !bool {
        var pending = false;
        for (self.entries.items) |*entry| {
            const runtime = entry.runtime;
            const owner = entry.owner;
            const key = entry.key;
            var state = self.domain.queryState(owner) orelse continue;
            if (!state.create_operation.eql(key)) continue;
            if ((entry.replacement_failure != null or runtime.failed.load(.acquire)) and !entry.failure_published and state.lifecycle != .closing and state.lifecycle != .closed and state.lifecycle != .cleanup_unknown) {
                const receipt = runtime.parentReceipt();
                const reason: anyerror = if (entry.replacement_failure) |reason| reason else runtime.failureReason() orelse error.ConnectionClosed;
                const failure: operations.Failure = .{ .domain = .transport, .code = @errorName(reason), .stage = "forward", .retryable = true, .effect = .unknown, .cleanup = switch (receipt) {
                    .released => .released,
                    .awaiting => .releasing,
                    .unknown => .unknown,
                }, .safe_message = @errorName(reason) };
                if (state.lifecycle == .ready) _ = try self.domain.transportLost(owner, key, failure) else if (state.lifecycle == .creating) _ = try self.domain.failed(owner, key, failure);
                entry.failure_published = true;
                const policy = runtime.policy;
                if (!runtime.closing.load(.acquire) and reason != error.Cancelled and policy.automatic_reconnect and entry.reconnect_count < policy.reconnect_max and entry.reconnect_count < policy.reconnect_backoff.len)
                    entry.reconnect_deadline_ns = realtime.monotonicNs() + @as(i128, policy.reconnect_backoff[entry.reconnect_count]) * std.time.ns_per_s;
                state = self.domain.queryState(owner).?;
            }
            if (!entry.ready_published and entry.replacement_failure == null and runtime.source.value.create_key.eql(key) and runtime.ready.load(.acquire) and !runtime.failed.load(.acquire) and !runtime.closing.load(.acquire) and state.lifecycle == .creating) {
                _ = try self.domain.readyBackground(owner, key, sessions.backgroundServices());
                entry.ready_published = true;
                entry.reconnect_count = 0;
                state = self.domain.queryState(owner).?;
            }
            if (state.lifecycle == .failed or state.lifecycle == .ended or (state.lifecycle == .closing and !entry.ready_published)) {
                const receipt = runtime.parentReceipt();
                if (entry.cleanup_published == null or entry.cleanup_published.? != receipt) {
                    _ = try self.domain.createCleanupReceipt(owner, key, receipt);
                    entry.cleanup_published = receipt;
                }
            }
            if (entry.waiting) |waiting| {
                const receipt = runtime.closeReceipt();
                if (receipt == .released or receipt != waiting.last) {
                    entry.waiting = null;
                    _ = self.domain.closeReceipt(owner, waiting.key, waiting.step, receipt) catch |err| {
                        if (entry.waiting == null) entry.waiting = waiting;
                        return err;
                    };
                    if (receipt != .released and entry.waiting == null) entry.waiting = .{ .key = waiting.key, .step = waiting.step, .last = receipt };
                }
            }
            if (entry.reconnect_deadline_ns) |deadline| {
                if (runtime.closing.load(.acquire) or self.shutting_down or state.lifecycle == .closing or state.lifecycle == .closed) entry.reconnect_deadline_ns = null else if (realtime.monotonicNs() >= deadline and runtime.parentReceipt() == .released and (state.lifecycle == .failed or state.lifecycle == .ended)) {
                    entry.reconnect_deadline_ns = null;
                    entry.reconnect_count +|= 1;
                    _ = self.domain.retry(owner) catch |err| {
                        entry.reconnect_deadline_ns = deadline;
                        entry.reconnect_count -|= 1;
                        return err;
                    };
                }
            }
            pending = pending or !runtime.done.load(.acquire) or entry.waiting != null or entry.reconnect_deadline_ns != null;
        }
        return pending;
    }
    pub fn shutdownStep(self: *Host) sessions.CloseReceipt {
        self.shutting_down = true;
        var receipt: sessions.CloseReceipt = .released;
        for (self.entries.items) |*entry| {
            entry.reconnect_deadline_ns = null;
            entry.runtime.requestStop();
            receipt = combine(receipt, entry.runtime.closeReceipt());
        }
        return receipt;
    }
    pub fn deinit(self: *Host) error{Busy}!void {
        for (self.entries.items) |entry| if (entry.runtime.closeReceipt() != .released) return error.Busy;
        for (self.entries.items) |entry| try entry.runtime.deinit();
        self.entries.deinit(self.allocator);
        self.library.deinit();
        self.allocator.free(self.known_hosts_path);
        self.allocator.destroy(self);
    }

    pub fn pendingAuthentication(self: *Host) ?auth.Snapshot {
        for (self.entries.items) |entry| if (self.current(entry.runtime)) if (entry.runtime.pendingAuthentication()) |value| return value;
        return null;
    }
    pub fn submitAuthentication(self: *Host, request: auth.RequestIdentity, reply: auth.Reply) !void {
        const runtime = self.authenticationRuntime(request) orelse return error.StaleAuthentication;
        const snapshot = runtime.pendingAuthentication().?;
        switch (snapshot.kind) {
            .host_key_unknown, .host_key_changed => if (!runtime.host_bridge.decideScoped(request, reply)) return error.StaleAuthentication,
            else => try runtime.auth_bridge.submit(request, reply),
        }
    }
    pub fn cancelAuthentication(self: *Host, request: auth.RequestIdentity) bool {
        const runtime = self.authenticationRuntime(request) orelse return false;
        // Cancelling a challenge ends this attempt, not the retained runtime.
        // The worker publishes Cancelled and releases its transport normally;
        // an explicit retry can then reuse the original listening port.
        runtime.authentication_cancelled.store(true, .release);
        runtime.host_bridge.cancel();
        runtime.auth_bridge.cancel();
        return true;
    }
    pub fn authenticationHostFor(self: *Host, request: auth.RequestIdentity) ?hosts.HostConfig {
        const runtime = self.authenticationRuntime(request) orelse return null;
        return hostAt(runtime.source.value.spec, request.hop_index);
    }
    pub fn authenticationHostKey(self: *Host, request: auth.RequestIdentity) ?host_key.Request {
        const runtime = self.authenticationRuntime(request) orelse return null;
        const value = runtime.host_bridge.lastSnapshot() orelse return null;
        if (value.operation_key == null or !value.operation_key.?.eql(request.key) or value.hop_index != request.hop_index or value.generation != request.request_id) return null;
        return value;
    }
    pub fn authenticationTotp(self: *Host, request: auth.RequestIdentity, now: Totp.Time) !?Totp.Suggestion {
        const runtime = self.authenticationRuntime(request) orelse return null;
        const snapshot = runtime.pendingAuthentication() orelse return null;
        return Totp.suggestForSpec(&snapshot, request, runtime.source.value.spec, runtime.policy.totp_autofill, now);
    }
    fn current(self: *Host, runtime: *Runtime) bool {
        const source = runtime.source.value;
        const entry = self.find(source.owner) orelse return false;
        const state = self.domain.queryState(entry.owner) orelse return false;
        return entry.replacement_failure == null and entry.key.eql(source.create_key) and state.create_operation.eql(source.create_key) and state.lifecycle == .creating and !runtime.closing.load(.acquire);
    }
    fn authenticationRuntime(self: *Host, request: auth.RequestIdentity) ?*Runtime {
        for (self.entries.items) |entry| if (self.current(entry.runtime)) {
            const value = entry.runtime.pendingAuthentication() orelse continue;
            if (value.identity.eql(request)) return entry.runtime;
        };
        return null;
    }
    fn find(self: *Host, owner: identity.SessionHandle) ?*Entry {
        for (self.entries.items) |*entry| if (entry.owner.eql(owner)) return entry;
        return null;
    }
    fn findKey(self: *Host, key: operations.OperationKey) ?*Entry {
        for (self.entries.items) |*entry| if (entry.key.eql(key)) return entry;
        return null;
    }
};

const Runtime = struct {
    allocator: std.mem.Allocator,
    source: Frozen(files.Source),
    policy: Policy,
    library: *const ssh.Library,
    known_hosts_path: []const u8,
    connector: ?files.readonly.Connector = null,
    session: ?ssh.Session = null,
    forwards: []?*Forward.Service,
    thread: ?std.Thread = null,
    closing: std.atomic.Value(bool) = .init(false),
    authentication_cancelled: std.atomic.Value(bool) = .init(false),
    handoff: std.atomic.Value(bool) = .init(false),
    retry_cleanup: std.atomic.Value(bool) = .init(false),
    ready: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    phase: std.atomic.Value(Phase) = .init(.connecting),
    parent_cleanup: std.atomic.Value(u8) = .init(@backingInt(ssh.ReleaseReceipt.awaiting)),
    failure_reason: ?anyerror = null,
    counter: auth.RequestCounter = .{},
    host_bridge: host_key.Bridge = .{},
    auth_bridge: auth.InteractiveBridge = .{},

    fn sourceFor(request: sessions.CreateRequest) files.Source {
        return .{ .owner = request.handle, .create_key = request.key, .open_key = request.key, .spec = request.spec };
    }
    fn start(allocator: std.mem.Allocator, request: sessions.CreateRequest, library: *const ssh.Library, path: []const u8, policy: Policy) !*Runtime {
        var source = try Frozen(files.Source).init(allocator, sourceFor(request));
        errdefer source.deinit();
        const self = try allocator.create(Runtime);
        errdefer allocator.destroy(self);
        const forwards = try allocator.alloc(?*Forward.Service, request.spec.saved.route_snapshot.len + 1);
        @memset(forwards, null);
        errdefer {
            for (forwards) |value| if (value) |service| service.deinitLocal() catch {};
            allocator.free(forwards);
        }
        for (forwards) |*value| value.* = try Forward.Service.init(allocator, request.key);
        self.* = .{ .allocator = allocator, .source = source, .policy = policy, .library = library, .known_hosts_path = path, .forwards = forwards };
        self.host_bridge.request_counter = &self.counter;
        self.auth_bridge.request_counter = &self.counter;
        self.connector = try self.prepareConnector(source.value);
        errdefer self.connector.?.deinit_fn(self.connector.?.ctx);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    fn prepareConnector(self: *Runtime, source: files.Source) !files.readonly.Connector {
        var factory: routing.SourceFactory = .{ .library = self.library, .known_hosts_path = self.known_hosts_path, .timeout_ms = self.policy.timeout_ms, .forward_services = self.forwards, .host_key_observer = .{ .ctx = &self.host_bridge, .callback = host_key.Bridge.observer }, .auth_interaction = .{ .bridge = &self.auth_bridge, .presentation = self.policy.presentation, .presentation_config_revision = self.policy.presentation_config_revision } };
        return factory.interface().prepare(&factory, source);
    }
    fn replace(self: *Runtime, request: sessions.CreateRequest) !void {
        if (self.closing.load(.acquire) or !self.failed.load(.acquire) or self.parentReceipt() != .released) return error.PreviousTransportNotReleased;
        if (request.handle.session_id != self.source.value.owner.session_id or request.handle.generation <= self.source.value.owner.generation or request.key.attempt_id == self.source.value.create_key.attempt_id or request.spec.saved.route_snapshot.len + 1 != self.forwards.len) return error.StaleBackgroundRetry;
        var source = try Frozen(files.Source).init(self.allocator, sourceFor(request));
        errdefer source.deinit();
        // Preparation copies memory only and may fail before moving IO owners.
        const connector = try self.prepareConnector(source.value);
        errdefer connector.deinit_fn(connector.ctx);
        self.handoff.store(true, .release);
        if (self.thread) |thread| thread.join();
        self.thread = null;
        for (self.forwards) |value| try value.?.prepareReplacement();
        if (self.connector) |old| old.deinit_fn(old.ctx);
        self.connector = connector;
        self.source.deinit();
        self.source = source;
        self.session = null;
        self.host_bridge.reset();
        self.auth_bridge.resetForAttempt();
        self.authentication_cancelled.store(false, .release);
        self.handoff.store(false, .release);
        self.ready.store(false, .release);
        self.failed.store(false, .release);
        self.done.store(false, .release);
        self.parent_cleanup.store(@backingInt(ssh.ReleaseReceipt.awaiting), .release);
        self.failure_reason = null;
        self.phase.store(.connecting, .release);
        // If spawn fails, no native ownership was acquired for the new grant.
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
            self.failure_reason = err;
            self.failed.store(true, .release);
            self.parent_cleanup.store(@backingInt(ssh.ReleaseReceipt.released), .release);
            self.phase.store(.failed, .release);
            self.done.store(true, .release);
            return;
        };
    }
    fn requestStop(self: *Runtime) void {
        const first = !self.closing.swap(true, .acq_rel);
        if (first) self.retry_cleanup.store(true, .release);
        self.host_bridge.cancel();
        self.auth_bridge.cancel();
        for (self.forwards) |service| service.?.requestClose();
        // A failed replacement spawn still owns its retained local port. A
        // cleanup owner may be created without doing native IO on this caller.
        if (self.done.load(.acquire) and self.closeReceipt() != .released) {
            if (self.thread) |thread| thread.join();
            self.thread = null;
            for (self.forwards) |service| service.?.adoptIoAfterOwnerStopped();
            self.handoff.store(false, .release);
            self.done.store(false, .release);
            self.thread = std.Thread.spawn(.{}, run, .{self}) catch {
                self.parent_cleanup.store(@backingInt(ssh.ReleaseReceipt.unknown), .release);
                self.done.store(true, .release);
                return;
            };
        }
    }
    fn parentReceipt(self: *Runtime) sessions.CloseReceipt {
        return convert(self.nativeParentReceipt());
    }
    fn nativeParentReceipt(self: *Runtime) ssh.ReleaseReceipt {
        return @fromBackingInt(@as(std.meta.Tag(ssh.ReleaseReceipt), @intCast(self.parent_cleanup.load(.acquire))));
    }
    fn closeReceipt(self: *Runtime) sessions.CloseReceipt {
        const parent = self.parentReceipt();
        if (parent == .unknown) return .unknown;
        if (!self.done.load(.acquire)) return .awaiting;
        var receipt = parent;
        for (self.forwards) |service| receipt = combine(receipt, convert(service.?.snapshot().cleanup));
        return receipt;
    }
    fn failureReason(self: *Runtime) ?anyerror {
        return if (self.failed.load(.acquire)) self.failure_reason else null;
    }
    fn run(self: *Runtime) void {
        self.connectAndServe() catch |err| {
            if (!self.closing.load(.acquire)) {
                self.failure_reason = if (self.authentication_cancelled.load(.acquire)) error.Cancelled else err;
                self.failed.store(true, .release);
            }
        };
        self.host_bridge.cancel();
        self.auth_bridge.cancel();
        if (self.session != null) self.forwards[self.forwards.len - 1].?.transportLost() catch {};
        var retry = true;
        while (self.nativeParentReceipt() != .released) {
            const requested_cleanup = self.retry_cleanup.swap(false, .acq_rel);
            if (retry or requested_cleanup) {
                const connector = self.connector.?;
                const receipt = connector.close_fn(connector.ctx, if (self.session) |*value| value else null);
                self.parent_cleanup.store(@backingInt(receipt), .release);
                retry = receipt == .awaiting;
                self.phase.store(if (receipt == .unknown) .cleanup_unknown else .closing, .release);
                if (receipt == .released) {
                    self.forwards[self.forwards.len - 1].?.sessionReleased() catch {
                        self.parent_cleanup.store(@backingInt(ssh.ReleaseReceipt.unknown), .release);
                        retry = false;
                    };
                }
            }
            if (self.nativeParentReceipt() != .released) pause();
        }
        self.phase.store(if (self.closing.load(.acquire)) .closing else .paused, .release);
        while (!self.handoff.load(.acquire)) {
            var all_released = true;
            for (self.forwards) |value| {
                const service = value.?;
                service.stepPaused() catch {
                    self.phase.store(.cleanup_unknown, .release);
                    all_released = false;
                };
                all_released = all_released and service.snapshot().cleanup == .released;
            }
            if (self.closing.load(.acquire) and all_released) {
                self.phase.store(.closed, .release);
                break;
            }
            pause();
        }
        self.done.store(true, .release);
    }
    fn connectAndServe(self: *Runtime) !void {
        const connector = self.connector.?;
        self.session = try connector.connect_fn(connector.ctx, &self.closing);
        if (self.closing.load(.acquire)) return error.Cancelled;
        std.debug.assert(self.session.?.channel == null);
        const target = self.forwards[self.forwards.len - 1].?;
        // Publish the new transport origin before ready. Upstream Relays do
        // the same through Route.bindForwards on their original IO threads.
        try target.step(&self.session.?);
        self.phase.store(.ready, .release);
        self.ready.store(true, .release);
        var next_keepalive = realtime.monotonicNs() + std.time.ns_per_s;
        while (!self.closing.load(.acquire)) {
            for (self.forwards) |service| if (service.?.parentCloseRequested()) {
                self.requestStop();
                return;
            };
            try target.step(&self.session.?);
            try probeTransport(self.session.?.socket_fd);
            if (realtime.monotonicNs() >= next_keepalive) {
                const result = c.zw_libssh2_session_send_keepalive(self.session.?.handle.?);
                if (result != 0 and result != -37) return error.ConnectionClosed;
                next_keepalive = realtime.monotonicNs() + if (result == -37) @as(i128, 50) * std.time.ns_per_ms else std.time.ns_per_s;
            }
            pause();
        }
    }
    fn pendingAuthentication(self: *Runtime) ?auth.Snapshot {
        if (self.closing.load(.acquire) or self.ready.load(.acquire) or self.failed.load(.acquire)) return null;
        const source = self.source.value;
        if (self.host_bridge.snapshot()) |request| {
            const key = request.operation_key orelse return null;
            const host = hostAt(source.spec, request.hop_index) orelse return null;
            if (!key.eql(source.create_key) or host.user.len > 256 or !std.mem.eql(u8, host.host, request.hostSlice()) or host.port != request.port) return null;
            var value: auth.Snapshot = .{ .identity = .{ .key = key, .hop_index = request.hop_index, .request_id = request.generation }, .source_owner = request.source_owner, .kind = if (request.status == .changed) .host_key_changed else .host_key_unknown, .presentation = .protected_form, .presentation_config_revision = self.policy.presentation_config_revision, .expires_at_ns = null, .port = request.port, .host_len = request.host_len, .user_len = host.user.len };
            @memcpy(value.host[0..request.host_len], request.hostSlice());
            @memcpy(value.user[0..host.user.len], host.user);
            return value;
        }
        const value = self.auth_bridge.snapshot() orelse return null;
        if (!value.identity.key.eql(source.create_key) or value.state == .completed or value.state == .cancelled) return null;
        const host = hostAt(source.spec, value.identity.hop_index) orelse return null;
        const endpoint = value.endpoint();
        if (!std.mem.eql(u8, host.host, endpoint.host) or !std.mem.eql(u8, host.user, endpoint.user) or host.port != endpoint.port) return null;
        return value;
    }
    fn deinit(self: *Runtime) error{Busy}!void {
        if (self.closeReceipt() != .released) return error.Busy;
        if (self.thread) |thread| thread.join();
        if (self.connector) |connector| connector.deinit_fn(connector.ctx);
        for (self.forwards) |value| try value.?.deinitLocal();
        self.allocator.free(self.forwards);
        self.source.deinit();
        self.allocator.destroy(self);
    }
};

fn hostAt(spec: sessions.SessionCreateSpec, index: usize) ?hosts.HostConfig {
    if (spec != .saved) return null;
    const saved = spec.saved;
    var owner: ?identity.AssetOwner = null;
    const remote: sessions.RemoteConfig = if (index < saved.route_snapshot.len) blk: {
        const hop = saved.route_snapshot[index];
        owner = hop.owner;
        break :blk .{ .endpoint = hop.endpoint, .auth = hop.auth, .strict_host_key_checking = hop.strict_host_key_checking, .totp_secret = hop.totp_secret };
    } else if (index == saved.route_snapshot.len) blk: {
        owner = .{ .id = saved.connection_id, .revision = saved.config_revision };
        break :blk saved.immutable_config;
    } else return null;
    return .{ .connection_id = if (owner) |value| value.id else @fromBackingInt(0), .revision = if (owner) |value| value.revision else 1, .name = remote.endpoint.host, .host = remote.endpoint.host, .port = remote.endpoint.port, .user = remote.endpoint.user, .totp_secret = remote.totp_secret, .strict_host_key_checking = remote.strict_host_key_checking, .auth_mode = switch (remote.auth) {
        .agent => .agent,
        .private_key => .private_key,
        else => .password,
    }, .identity_file = switch (remote.auth) {
        .private_key => |key| key.path,
        else => null,
    } };
}
fn convert(value: ssh.ReleaseReceipt) sessions.CloseReceipt {
    return switch (value) {
        .released => .released,
        .awaiting => .awaiting,
        .unknown => .unknown,
    };
}
fn combine(left: sessions.CloseReceipt, right: sessions.CloseReceipt) sessions.CloseReceipt {
    if (left == .unknown or right == .unknown) return .unknown;
    if (left == .awaiting or right == .awaiting) return .awaiting;
    return .released;
}
fn probeTransport(fd: c_int) !void {
    if (fd < 0) return error.ConnectionClosed;
    var polls = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    _ = try std.posix.poll(&polls, 0);
    if (polls[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0) return error.ConnectionClosed;
    if (polls[0].revents & std.posix.POLL.IN != 0) {
        var byte: [1]u8 = undefined;
        const result = std.c.recv(fd, &byte, byte.len, std.posix.MSG.PEEK | std.posix.MSG.DONTWAIT);
        if (result == 0) return error.ConnectionClosed;
    }
}
fn pause() void {
    var empty: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&empty, 0, 5);
}

test "background runtime controller declarations compile" {
    std.testing.refAllDecls(Host);
}
