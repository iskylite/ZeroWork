//! Original-owner SOCKS connections. The controller holds SessionHost authority
//! and the journal; a dedicated worker connects the frozen Route, transfers the
//! no-shell Session to Listener's sole IO owner, then releases the entire Route.
const std = @import("std");
const sessions = @import("session_host.zig");
const identity = @import("identity.zig");
const operations = @import("operation.zig");
const files = @import("file_binding_host.zig");
const routing = @import("file_route_factory.zig");
const ssh = @import("../proto/ssh/session.zig");
pub const auth = @import("../proto/ssh/auth_challenge.zig");
pub const host_key = @import("../ui/host_key_confirmation.zig");
pub const listener = @import("../proto/ssh/socks5_listener.zig");
const progress = @import("../proto/ssh/connection_progress.zig");
const hosts = @import("../config/hosts.zig");
const Frozen = @import("../ui/session_lifecycle.zig").Snapshot;
const Forward = @import("../proto/ssh/forward_service.zig");

pub const Phase = enum(u8) { connecting, ready, paused, failed, closing, cleanup_unknown, closed };
pub const SharedProvider = struct {
    context: *anyopaque,
    get: *const fn (*anyopaque, sessions.ServiceHandle, ?usize) anyerror!*Forward.Service,
};
pub const Options = struct {
    /// Library must remain alive until Host.deinit succeeds, including unknown.
    library: *const ssh.Library,
    known_hosts_path: []const u8,
    presentation: auth.Presentation = .protected_form,
    presentation_config_revision: u64 = 1,
    timeout_ms: u32 = 15_000,
    totp_autofill: bool = false,
    shared_provider: ?SharedProvider = null,
};
pub const StartOptions = struct {
    listener: listener.Options = .{},
    /// null selects the original final target; otherwise zero-based jump hop.
    exit_index: ?usize = null,
};
pub const Snapshot = struct {
    owner: identity.SessionHandle,
    binding: sessions.ServiceHandle,
    key: operations.OperationKey,
    phase: Phase,
    cleanup: sessions.CloseReceipt,
    local_port: u16,
    stats: listener.Stats,
    failure: ?anyerror,
    exit_index: ?usize,
    requested_port: u16,
    bind127: bool,
    max_connections: u32,
};
const Entry = struct {
    runtime: *Runtime,
    terminal_published: bool = false,
    cleanup_published: ?sessions.CloseReceipt = null,
    retired: bool = false,
};
const SharedEntry = struct {
    source: Frozen(files.Source),
    service: ?*Forward.Service,
    options: StartOptions,
    last: Snapshot,
    stopping: bool = false,
    terminal_published: bool = false,
    cleanup_published: ?sessions.CloseReceipt = null,
    retired: bool = false,
};

pub const Host = struct {
    allocator: std.mem.Allocator,
    domain: *sessions.SessionHost,
    options: Options,
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,
    shared_entries: std.ArrayList(SharedEntry) = .empty,
    shutting_down: bool = false,

    pub fn init(allocator: std.mem.Allocator, domain: *sessions.SessionHost, options: Options) !Host {
        if (!std.fs.path.isAbsolute(options.known_hosts_path) or options.presentation_config_revision == 0 or options.timeout_ms == 0) return error.InvalidSocksRouteOptions;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        var owned = options;
        owned.known_hosts_path = try arena.allocator().dupe(u8, options.known_hosts_path);
        return .{ .allocator = allocator, .domain = domain, .options = owned, .arena = arena };
    }

    /// Memory-only preparation. Service authority and the immutable request
    /// come from the original SessionHost, never the selected tab/asset editor.
    pub fn start(self: *Host, owner: identity.SessionHandle, options: StartOptions) !operations.OperationKey {
        if (self.options.shared_provider) |provider| return self.startShared(owner, options, provider);
        return self.startIndependent(owner, options);
    }
    fn startIndependent(self: *Host, owner: identity.SessionHandle, options: StartOptions) !operations.OperationKey {
        if (self.shutting_down) return error.SocksRouteClosing;
        const state = self.domain.queryState(owner) orelse return error.StaleSession;
        const binding = switch (self.domain.queryService(owner, .forward)) {
            .available => |value| value,
            .unsupported => return error.UnsupportedProtocol,
            .temporarily_unavailable => return error.ForwardServiceUnavailable,
        };
        if (binding.kind != .forward or binding.resource_owner != .session or !binding.resource_owner.session.eql(owner) or !self.domain.bindingIsLive(binding)) return error.StaleForwardBinding;
        if (!options.listener.bind127 and !options.listener.exposure_confirmed) return error.ExposureConfirmationRequired;
        const selected = try selectExit(try self.sourceSpec(owner), options.exit_index);
        // Do not replace an owner whose real native cleanup has not completed.
        for (self.entries.items, 0..) |*entry, index| if (entry.runtime.source.value.owner.eql(owner)) {
            if (!entry.retired or !entry.runtime.done.load(.acquire) or entry.runtime.receipt() != .released) return error.SocksRouteAlreadyActive;
            try entry.runtime.deinit();
            _ = self.entries.orderedRemove(index);
            break;
        };
        if (self.entries.items.len == 32) return error.SocksRouteLimit;
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        const key = try self.domain.journal.begin(.{ .session = owner }, state.create_operation.attempt_id);
        const runtime = Runtime.start(self.allocator, binding, .{ .owner = owner, .create_key = state.create_operation, .open_key = key, .spec = selected }, self.options, options) catch |err| {
            _ = try self.domain.journal.failReleased(key, failure(err, .released));
            try self.domain.journal.retire(key, .no_resources);
            return err;
        };
        self.entries.appendAssumeCapacity(.{ .runtime = runtime });
        return key;
    }

    /// Nonblocking; Listener.stop and native Route.close stay on the IO worker.
    pub fn requestStop(self: *Host, owner: identity.SessionHandle) sessions.CloseReceipt {
        if (self.findShared(owner)) |entry| {
            entry.stopping = true;
            if (entry.service) |service| {
                _ = service.requestStop(entry.last.binding);
                self.readShared(entry);
            }
            return entry.last.cleanup;
        }
        const entry = self.find(owner) orelse return .released;
        entry.runtime.requestStop();
        return entry.runtime.receipt();
    }
    /// A close transaction for the original session may release its entire
    /// native graph. The forward receipt still waits for that actual release.
    pub fn requestSessionClose(self: *Host, owner: identity.SessionHandle) sessions.CloseReceipt {
        const state = self.domain.queryState(owner) orelse return .released;
        var shared = self.findShared(owner);
        // A close may arrive in the frame between actual transport replacement
        // and forward rebinding. Use the accepted current parent operation,
        // preserving the old forward operation's resource cleanup ownership.
        if (shared == null) for (self.shared_entries.items) |*entry| {
            if (entry.last.owner.session_id != owner.session_id) continue;
            if (entry.service == null) continue;
            shared = entry;
            break;
        };
        if (shared) |entry| {
            entry.stopping = true;
            if (entry.service) |service| {
                _ = service.requestParentClose(state.create_operation, entry.last.binding);
                self.readShared(entry);
            }
            return entry.last.cleanup;
        }
        return self.requestStop(owner);
    }

    /// An uncertain native owner stays pinned. A subsequent explicit cleanup
    /// request may retry it on a worker; no UI-thread destructor is introduced.
    pub fn retryCleanup(self: *Host, owner: identity.SessionHandle) !sessions.CloseReceipt {
        if (self.findShared(owner) != null) return self.requestStop(owner);
        const entry = self.find(owner) orelse return .released;
        entry.runtime.requestStop();
        try entry.runtime.retryCleanup();
        return entry.runtime.receipt();
    }

    pub fn snapshot(self: *Host, owner: identity.SessionHandle) ?Snapshot {
        if (self.findShared(owner)) |entry| {
            self.readShared(entry);
            return entry.last;
        }
        const entry = self.find(owner) orelse return null;
        return entry.runtime.snapshot();
    }

    /// Controller safe point. Journal IO results retain their original key;
    /// cleanup remains publishable after a successful start or business failure.
    pub fn safeTick(self: *Host) !bool {
        var active = try self.tickShared();
        for (self.entries.items) |*entry| {
            const runtime = entry.runtime;
            if (self.shutting_down or !self.current(runtime)) runtime.requestStop();
            const value = runtime.snapshot();
            if (!entry.terminal_published) {
                if (value.phase == .ready and !runtime.closing.load(.acquire)) {
                    _ = try self.domain.journal.publish(value.key, .completed, "SOCKS5 listening", null);
                    entry.terminal_published = true;
                } else if (runtime.done.load(.acquire)) {
                    if (value.failure) |reason| {
                        _ = try self.domain.journal.publish(value.key, .failed, "", failure(reason, value.cleanup));
                    } else {
                        _ = try self.domain.journal.publish(value.key, .cancelled, "SOCKS5 stopped", null);
                    }
                    entry.terminal_published = true;
                }
            }
            if (runtime.closing.load(.acquire) or runtime.done.load(.acquire)) {
                if (entry.cleanup_published == null or entry.cleanup_published.? != value.cleanup) {
                    _ = try self.domain.journal.publish(value.key, switch (value.cleanup) {
                        .released => .cleanup_released,
                        .awaiting => .cleanup_progress,
                        .unknown => .cleanup_unknown,
                    }, "SOCKS5 cleanup", if (value.failure) |reason| failure(reason, value.cleanup) else null);
                    entry.cleanup_published = value.cleanup;
                }
            }
            if (runtime.done.load(.acquire) and value.cleanup == .released and entry.terminal_published and !entry.retired) {
                try self.domain.journal.retire(value.key, .resources_released);
                entry.retired = true;
            }
            if (runtime.done.load(.acquire) and value.cleanup == .awaiting) try runtime.retryCleanup();
            active = active or !runtime.done.load(.acquire) or value.cleanup != .released;
        }
        return active;
    }

    pub fn shutdownStep(self: *Host) sessions.CloseReceipt {
        self.shutting_down = true;
        var receipt: sessions.CloseReceipt = .released;
        for (self.shared_entries.items) |*entry| {
            const value = self.requestStop(entry.last.owner);
            if (value == .unknown) receipt = .unknown else if (value == .awaiting and receipt == .released) receipt = .awaiting;
        }
        for (self.entries.items) |entry| {
            entry.runtime.requestStop();
            const value = entry.runtime.receipt();
            if (value == .unknown) receipt = .unknown else if (value == .awaiting and receipt == .released) receipt = .awaiting;
        }
        return receipt;
    }

    /// All original dependencies must remain alive when this returns Busy.
    pub fn deinit(self: *Host) error{Busy}!void {
        for (self.shared_entries.items) |*entry| {
            self.readShared(entry);
            if (entry.service != null or entry.last.cleanup != .released) return error.Busy;
        }
        for (self.entries.items) |entry| if (!entry.runtime.done.load(.acquire) or entry.runtime.receipt() != .released) return error.Busy;
        for (self.entries.items) |entry| try entry.runtime.deinit();
        self.entries.deinit(self.allocator);
        for (self.shared_entries.items) |*entry| entry.source.deinit();
        self.shared_entries.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn pendingAuthentication(self: *Host) ?auth.Snapshot {
        for (self.entries.items) |entry| if (self.current(entry.runtime)) if (entry.runtime.pendingAuthentication()) |value| return value;
        return null;
    }
    pub fn submitAuthentication(self: *Host, request: auth.RequestIdentity, reply: auth.Reply) !void {
        const runtime = self.authRuntime(request) orelse return error.StaleAuthentication;
        const value = runtime.pendingAuthentication().?;
        switch (value.kind) {
            .host_key_unknown, .host_key_changed => if (!runtime.host_bridge.decideScoped(request, reply)) return error.StaleAuthentication,
            else => try runtime.auth_bridge.submit(request, reply),
        }
    }
    pub fn cancelAuthentication(self: *Host, request: auth.RequestIdentity) bool {
        const runtime = self.authRuntime(request) orelse return false;
        runtime.requestStop();
        return true;
    }
    pub fn authenticationHostFor(self: *Host, request: auth.RequestIdentity) ?hosts.HostConfig {
        const runtime = self.authRuntime(request) orelse return null;
        const value = hostAt(runtime.source.value.spec, request.hop_index) orelse return null;
        return self.withExitName(runtime, request.hop_index, value);
    }
    pub fn authenticationHostKey(self: *Host, request: auth.RequestIdentity) ?host_key.Request {
        const runtime = self.authRuntime(request) orelse return null;
        const observed = runtime.host_bridge.lastSnapshot() orelse return null;
        if (observed.operation_key == null or !observed.operation_key.?.eql(request.key) or observed.hop_index != request.hop_index) return null;
        return observed;
    }
    pub fn authenticationTotp(self: *Host, request: auth.RequestIdentity, now: @import("../proto/ssh/totp_prefill.zig").Time) !?@import("../proto/ssh/totp_prefill.zig").Suggestion {
        const runtime = self.authRuntime(request) orelse return null;
        // Use the worker's original presentation, never ConnectionHost's modal
        // display projection of an unrelated protected authentication form.
        const original = runtime.auth_bridge.snapshot() orelse return null;
        return @import("../proto/ssh/totp_prefill.zig").suggestForSpec(&original, request, runtime.source.value.spec, runtime.policy.totp_autofill, now);
    }
    pub fn connectionProgress(self: *Host, owner: identity.SessionHandle) ?progress.Journal.Snapshot {
        const entry = self.find(owner) orelse return null;
        return entry.runtime.progress_journal.snapshot();
    }
    pub fn sourceRoute(self: *Host, owner: identity.SessionHandle) ![]const sessions.RouteHop {
        return routeOf(try self.sourceSpec(owner));
    }
    pub fn exitHost(self: *Host, owner: identity.SessionHandle) ?hosts.HostConfig {
        if (self.findShared(owner)) |entry| return hostAt(entry.source.value.spec, entry.options.exit_index orelse routeOf(entry.source.value.spec).len);
        const entry = self.find(owner) orelse return null;
        const spec = entry.runtime.source.value.spec;
        const index = routeOf(spec).len;
        return self.withExitName(entry.runtime, index, hostAt(spec, index) orelse return null);
    }
    fn withExitName(self: *Host, runtime: *Runtime, index: usize, value: hosts.HostConfig) hosts.HostConfig {
        var result = value;
        if (runtime.options.exit_index) |selected| if (index == routeOf(runtime.source.value.spec).len) {
            const original = self.sourceSpec(runtime.source.value.owner) catch return result;
            const hops = routeOf(original);
            if (selected < hops.len and hops[selected].display_name.len != 0) result.name = hops[selected].display_name;
        };
        return result;
    }

    fn find(self: *Host, owner: identity.SessionHandle) ?*Entry {
        for (self.entries.items) |*entry| if (entry.runtime.source.value.owner.eql(owner)) return entry;
        return null;
    }
    fn findShared(self: *Host, owner: identity.SessionHandle) ?*SharedEntry {
        for (self.shared_entries.items) |*entry| if (entry.last.owner.eql(owner)) return entry;
        return null;
    }
    fn startShared(self: *Host, owner: identity.SessionHandle, options: StartOptions, provider: SharedProvider) !operations.OperationKey {
        if (self.shutting_down) return error.SocksRouteClosing;
        const state = self.domain.queryState(owner) orelse return error.StaleSession;
        const binding = switch (self.domain.queryService(owner, .forward)) {
            .available => |value| value,
            else => return error.ForwardServiceUnavailable,
        };
        if (!self.domain.bindingIsLive(binding)) return error.StaleForwardBinding;
        const spec = try self.sourceSpec(owner);
        _ = try selectExit(spec, options.exit_index);
        if (self.findShared(owner)) |entry| {
            self.readShared(entry);
            if (entry.service != null or !entry.retired) return error.SocksRouteAlreadyActive;
            entry.source.deinit();
            for (self.shared_entries.items, 0..) |old, index| if (old.last.owner.eql(owner)) {
                _ = self.shared_entries.orderedRemove(index);
                break;
            };
        }
        if (self.shared_entries.items.len == 32) return error.SocksRouteLimit;
        try self.shared_entries.ensureUnusedCapacity(self.allocator, 1);
        const service = try provider.get(provider.context, binding, options.exit_index);
        const key = try self.domain.journal.begin(.{ .session = owner }, state.create_operation.attempt_id);
        errdefer {
            _ = self.domain.journal.failReleased(key, failure(error.SharedForwardRejected, .released)) catch false;
            self.domain.journal.retire(key, .no_resources) catch {};
        }
        var source = try Frozen(files.Source).init(self.allocator, .{ .owner = owner, .create_key = state.create_operation, .open_key = key, .spec = spec });
        errdefer source.deinit();
        try service.start(state.create_operation, binding, key, options.listener);
        self.shared_entries.appendAssumeCapacity(.{ .source = source, .service = service, .options = options, .last = .{ .owner = owner, .binding = binding, .key = key, .phase = .connecting, .cleanup = .awaiting, .local_port = 0, .stats = .{}, .failure = null, .exit_index = options.exit_index, .requested_port = options.listener.requested_port, .bind127 = options.listener.bind127, .max_connections = options.listener.max_connections } });
        return key;
    }
    fn readShared(_: *Host, entry: *SharedEntry) void {
        const service = entry.service orelse return;
        const value = service.snapshot();
        entry.last.phase = switch (value.phase) {
            .off => .closed,
            .starting => .connecting,
            .running => .ready,
            .paused => .paused,
            .stopping => .closing,
            .failed => .failed,
            .cleanup_unknown => .cleanup_unknown,
        };
        entry.last.cleanup = switch (value.cleanup) {
            .released => .released,
            .awaiting => .awaiting,
            .unknown => .unknown,
        };
        entry.last.local_port = value.port;
        entry.last.stats = value.stats;
        entry.last.failure = value.failure;
        // Close hooks may immediately proceed to destroy the Worker after a
        // released receipt. Retain values, never a facade into freed memory.
        if (value.cleanup == .released) entry.service = null;
    }
    fn tickShared(self: *Host) !bool {
        var active = false;
        for (self.shared_entries.items) |*entry| {
            if (entry.service) |service| {
                const state = self.domain.queryState(entry.last.owner);
                if (self.shutting_down or entry.stopping or (state != null and (state.?.lifecycle == .closing or state.?.lifecycle == .closed))) {
                    entry.stopping = true;
                    _ = service.requestStop(entry.last.binding);
                } else {
                    const native = service.snapshot();
                    if (native.origin) |next| if (!next.eql(entry.source.value.create_key) and next.owner == .session and next.owner.session.session_id == entry.last.owner.session_id and native.phase == .paused) {
                        if (self.domain.queryState(next.owner.session)) |successor| if (successor.create_operation.eql(next)) switch (self.domain.queryService(next.owner.session, .forward)) {
                            .available => |binding| if (self.domain.bindingIsLive(binding)) {
                                const provider = self.options.shared_provider orelse return error.ForwardServiceUnavailable;
                                const actual = try provider.get(provider.context, binding, entry.options.exit_index);
                                if (actual != service) return error.ForwardOwnerChanged;
                                const key = try self.domain.journal.begin(.{ .session = next.owner.session }, next.attempt_id);
                                errdefer {
                                    _ = self.domain.journal.failReleased(key, failure(error.SharedForwardRejected, .released)) catch false;
                                    self.domain.journal.retire(key, .no_resources) catch {};
                                }
                                var source = try Frozen(files.Source).init(self.allocator, .{ .owner = next.owner.session, .create_key = next, .open_key = key, .spec = try self.sourceSpec(next.owner.session) });
                                errdefer source.deinit();
                                try service.start(next, binding, key, entry.options.listener);
                                if (!entry.terminal_published) _ = try self.domain.journal.publish(entry.last.key, .cancelled, "original SSH transport ended", null);
                                try self.domain.journal.retire(entry.last.key, .transferred_to_owner);
                                entry.source.deinit();
                                entry.source = source;
                                entry.last.owner = next.owner.session;
                                entry.last.binding = binding;
                                entry.last.key = key;
                                entry.terminal_published = false;
                                entry.cleanup_published = null;
                            },
                            else => {},
                        };
                    };
                }
            }
            self.readShared(entry);
            if (!entry.terminal_published) {
                if (entry.last.phase == .ready) {
                    _ = try self.domain.journal.publish(entry.last.key, .completed, "SOCKS5 sharing original SSH", null);
                    entry.terminal_published = true;
                } else if (entry.last.phase == .failed or entry.last.phase == .cleanup_unknown) {
                    _ = try self.domain.journal.publish(entry.last.key, .failed, "", failure(entry.last.failure orelse error.ForwardCleanupUnknown, entry.last.cleanup));
                    entry.terminal_published = true;
                } else if (entry.last.cleanup == .released) {
                    _ = try self.domain.journal.publish(entry.last.key, if (entry.last.failure != null) .failed else .cancelled, "SOCKS5 stopped", if (entry.last.failure) |reason| failure(reason, .released) else null);
                    entry.terminal_published = true;
                }
            }
            if ((entry.stopping or entry.last.phase == .cleanup_unknown or entry.last.cleanup == .released) and (entry.cleanup_published == null or entry.cleanup_published.? != entry.last.cleanup)) {
                _ = try self.domain.journal.publish(entry.last.key, switch (entry.last.cleanup) {
                    .released => .cleanup_released,
                    .awaiting => .cleanup_progress,
                    .unknown => .cleanup_unknown,
                }, "SOCKS5 cleanup", if (entry.last.failure) |reason| failure(reason, entry.last.cleanup) else null);
                entry.cleanup_published = entry.last.cleanup;
            }
            if (entry.last.cleanup == .released and !entry.retired) {
                try self.domain.journal.retire(entry.last.key, .resources_released);
                entry.retired = true;
            }
            active = active or entry.last.cleanup != .released;
        }
        return active;
    }
    fn sourceSpec(self: *Host, owner: identity.SessionHandle) !sessions.SessionCreateSpec {
        return self.domain.engineSpec(owner) orelse error.StaleSession;
    }
    fn current(self: *Host, runtime: *Runtime) bool {
        const state = self.domain.queryState(runtime.source.value.owner) orelse return false;
        return state.create_operation.eql(runtime.source.value.create_key) and self.domain.bindingIsLive(runtime.binding);
    }
    fn authRuntime(self: *Host, request: auth.RequestIdentity) ?*Runtime {
        for (self.entries.items) |entry| {
            const runtime = entry.runtime;
            if (!runtime.source.value.open_key.eql(request.key) or !self.current(runtime)) continue;
            const value = runtime.pendingAuthentication() orelse return null;
            if (value.identity.eql(request)) return runtime;
        }
        return null;
    }
};

const Runtime = struct {
    allocator: std.mem.Allocator,
    binding: sessions.ServiceHandle,
    source: Frozen(files.Source),
    options: StartOptions,
    policy: Options,
    connector: files.readonly.Connector = undefined,
    thread: ?std.Thread = null,
    closing: std.atomic.Value(bool) = .init(false),
    phase: std.atomic.Value(Phase) = .init(.connecting),
    cleanup: std.atomic.Value(u8) = .init(@backingInt(ssh.ReleaseReceipt.awaiting)),
    done: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    failure_reason: ?anyerror = null,
    port: std.atomic.Value(u16) = .init(0),
    connections_total: std.atomic.Value(u64) = .init(0),
    connections_active: std.atomic.Value(u32) = .init(0),
    bytes_up: std.atomic.Value(u64) = .init(0),
    bytes_down: std.atomic.Value(u64) = .init(0),
    counter: auth.RequestCounter = .{},
    host_bridge: host_key.Bridge = .{},
    auth_bridge: auth.InteractiveBridge = .{},
    progress_journal: progress.Journal = .{},
    session: ?ssh.Session = null,
    proxy: ?*listener.Socks5Listener = null,

    fn start(allocator: std.mem.Allocator, binding: sessions.ServiceHandle, source: files.Source, policy: Options, options: StartOptions) !*Runtime {
        var frozen = try Frozen(files.Source).init(allocator, source);
        errdefer frozen.deinit();
        const self = try allocator.create(Runtime);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .binding = binding, .source = frozen, .options = options, .policy = policy };
        self.host_bridge.request_counter = &self.counter;
        self.auth_bridge.request_counter = &self.counter;
        self.progress_journal.begin(source.open_key.attempt_id orelse 1);
        var factory: routing.SourceFactory = .{
            .library = policy.library,
            .known_hosts_path = policy.known_hosts_path,
            .host_key_observer = .{ .ctx = &self.host_bridge, .callback = host_key.Bridge.observer },
            .auth_interaction = .{ .bridge = &self.auth_bridge, .presentation = policy.presentation, .presentation_config_revision = policy.presentation_config_revision },
            .progress_observer = self.progress_journal.observer(),
            .timeout_ms = policy.timeout_ms,
        };
        const api = factory.interface();
        self.connector = try api.prepare(api.context, self.source.value);
        errdefer api.discard(api.context, self.connector);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    fn requestStop(self: *Runtime) void {
        self.closing.store(true, .release);
        self.host_bridge.cancel();
        self.auth_bridge.cancel();
    }
    fn receipt(self: *const Runtime) sessions.CloseReceipt {
        if (!self.done.load(.acquire)) return .awaiting;
        return switch (@as(ssh.ReleaseReceipt, @fromBackingInt(@intCast(self.cleanup.load(.acquire))))) {
            .released => .released,
            .awaiting => .awaiting,
            .unknown => .unknown,
        };
    }
    fn snapshot(self: *Runtime) Snapshot {
        return .{
            .owner = self.source.value.owner,
            .binding = self.binding,
            .key = self.source.value.open_key,
            .phase = self.phase.load(.acquire),
            .cleanup = self.receipt(),
            .local_port = self.port.load(.acquire),
            .stats = .{ .connections_total = self.connections_total.load(.acquire), .connections_active = self.connections_active.load(.acquire), .bytes_up = self.bytes_up.load(.acquire), .bytes_down = self.bytes_down.load(.acquire) },
            .failure = if (self.failed.load(.acquire)) self.failure_reason else null,
            .exit_index = self.options.exit_index,
            .requested_port = self.options.listener.requested_port,
            .bind127 = self.options.listener.bind127,
            .max_connections = self.options.listener.max_connections,
        };
    }
    fn run(self: *Runtime) void {
        self.connectAndServe() catch |err| {
            // Host-key cancellation returns its protocol rejection rather than
            // error.Cancelled. The original stop request still owns the result.
            if (!self.closing.load(.acquire)) {
                self.failure_reason = err;
                self.failed.store(true, .release);
                self.phase.store(.failed, .release);
            }
        };
        self.releaseNative();
    }
    fn connectAndServe(self: *Runtime) !void {
        self.session = try self.connector.connect_fn(self.connector.ctx, &self.closing);
        if (self.closing.load(.acquire)) return error.Cancelled;
        // This dedicated Session never opens a PTY/shell. Once start succeeds,
        // only Listener's single native IO owner may use it until stop joins.
        self.proxy = try listener.Socks5Listener.init(self.allocator, &self.session.?);
        try self.proxy.?.startWithOptions(self.options.listener);
        while (self.proxy.?.state() == .starting and !self.closing.load(.acquire)) pause();
        if (self.closing.load(.acquire)) return error.Cancelled;
        if (self.proxy.?.state() != .listening) return self.proxy.?.last_failure orelse error.ForwardListenFailed;
        self.port.store(self.proxy.?.port(), .release);
        self.phase.store(.ready, .release);
        while (!self.closing.load(.acquire)) {
            self.copyStats();
            if (self.proxy.?.state() != .listening) return self.proxy.?.last_failure orelse error.SocksListenerStopped;
            pause();
        }
    }
    fn releaseNative(self: *Runtime) void {
        self.phase.store(.closing, .release);
        self.host_bridge.cancel();
        self.auth_bridge.cancel();
        if (self.proxy) |proxy| {
            proxy.stop();
            self.copyStats();
            const released = proxy.cleanupReceipt();
            if (released != .released) {
                self.finishCleanup(released);
                return;
            }
            proxy.deinit();
            self.proxy = null;
        }
        const released = self.connector.close_fn(self.connector.ctx, if (self.session) |*session| session else null);
        if (released == .released) self.session = null;
        self.finishCleanup(released);
    }
    fn finishCleanup(self: *Runtime, value: ssh.ReleaseReceipt) void {
        self.cleanup.store(@backingInt(value), .release);
        self.phase.store(switch (value) {
            .released => .closed,
            .awaiting => .closing,
            .unknown => .cleanup_unknown,
        }, .release);
        self.done.store(true, .release);
    }
    fn retryCleanup(self: *Runtime) !void {
        if (!self.done.load(.acquire) or self.receipt() == .released) return;
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.done.store(false, .release);
        self.phase.store(.closing, .release);
        self.thread = std.Thread.spawn(.{}, releaseNative, .{self}) catch |err| {
            self.finishCleanup(.unknown);
            return err;
        };
    }
    fn copyStats(self: *Runtime) void {
        const stats = self.proxy.?.stats();
        self.connections_total.store(stats.connections_total, .release);
        self.connections_active.store(stats.connections_active, .release);
        self.bytes_up.store(stats.bytes_up, .release);
        self.bytes_down.store(stats.bytes_down, .release);
    }
    fn pendingAuthentication(self: *Runtime) ?auth.Snapshot {
        if (self.closing.load(.acquire) or self.done.load(.acquire)) return null;
        const source = self.source.value;
        if (self.host_bridge.snapshot()) |request| {
            const key = request.operation_key orelse return null;
            const host = hostAt(source.spec, request.hop_index) orelse return null;
            if (!key.eql(source.open_key) or host.user.len > 256 or !std.mem.eql(u8, host.host, request.hostSlice()) or host.port != request.port) return null;
            var value: auth.Snapshot = .{
                .identity = .{ .key = key, .hop_index = request.hop_index, .request_id = request.generation },
                .source_owner = request.source_owner,
                .kind = if (request.status == .changed) .host_key_changed else .host_key_unknown,
                .presentation = .protected_form,
                .presentation_config_revision = self.policy.presentation_config_revision,
                .expires_at_ns = null,
                .port = request.port,
                .host_len = request.host_len,
                .user_len = host.user.len,
            };
            @memcpy(value.host[0..request.host_len], request.hostSlice());
            @memcpy(value.user[0..host.user.len], host.user);
            return value;
        }
        const value = self.auth_bridge.snapshot() orelse return null;
        if (!value.identity.key.eql(source.open_key) or value.state == .completed or value.state == .cancelled) return null;
        const host = hostAt(source.spec, value.identity.hop_index) orelse return null;
        const endpoint = value.endpoint();
        if (!std.mem.eql(u8, host.host, endpoint.host) or !std.mem.eql(u8, host.user, endpoint.user) or host.port != endpoint.port) return null;
        return value;
    }
    fn deinit(self: *Runtime) error{Busy}!void {
        if (!self.done.load(.acquire) or self.receipt() != .released) return error.Busy;
        if (self.thread) |thread| thread.join();
        self.connector.deinit_fn(self.connector.ctx);
        self.source.deinit();
        self.allocator.destroy(self);
    }
};

/// Select from the immutable route; a jump exit never authenticates later hops.
pub fn selectExit(spec: sessions.SessionCreateSpec, exit_index: ?usize) !sessions.SessionCreateSpec {
    if (spec.pluginId() != .ssh) return error.UnsupportedProtocol;
    try spec.validate();
    const index = exit_index orelse return spec;
    const hops = routeOf(spec);
    if (index >= hops.len) return error.InvalidSocksExit;
    const hop = hops[index];
    if (hop.owner) |owner| return .{ .saved = .{
        .connection_id = owner.id,
        .config_revision = owner.revision,
        .protocol = .ssh,
        .immutable_config = .{ .endpoint = hop.endpoint, .auth = hop.auth, .strict_host_key_checking = hop.strict_host_key_checking, .totp_secret = hop.totp_secret },
        .route_snapshot = hops[0..index],
    } };
    return .{ .temporary_ssh = .{ .structured_endpoint = hop.endpoint, .auth_options = hop.auth, .strict_host_key_checking = hop.strict_host_key_checking, .totp_secret = hop.totp_secret, .route_snapshot = hops[0..index] } };
}
fn routeOf(spec: sessions.SessionCreateSpec) []const sessions.RouteHop {
    return switch (spec) {
        .local, .plugin => &.{},
        .saved => |saved| saved.route_snapshot,
        .temporary_ssh => |temporary| temporary.route_snapshot,
    };
}
fn hostAt(spec: sessions.SessionCreateSpec, index: usize) ?hosts.HostConfig {
    const hops = routeOf(spec);
    var owner: ?identity.AssetOwner = null;
    var name: []const u8 = "";
    const remote: sessions.RemoteConfig = if (index < hops.len) blk: {
        const hop = hops[index];
        owner = hop.owner;
        name = hop.display_name;
        break :blk .{ .endpoint = hop.endpoint, .auth = hop.auth, .strict_host_key_checking = hop.strict_host_key_checking, .totp_secret = hop.totp_secret };
    } else if (index == hops.len) switch (spec) {
        .saved => |saved| blk: {
            owner = .{ .id = saved.connection_id, .revision = saved.config_revision };
            break :blk saved.immutable_config;
        },
        .temporary_ssh => |temporary| .{ .endpoint = temporary.structured_endpoint, .auth = temporary.auth_options, .strict_host_key_checking = temporary.strict_host_key_checking, .totp_secret = temporary.totp_secret },
        .local, .plugin => return null,
    } else return null;
    return .{
        .connection_id = if (owner) |value| value.id else @fromBackingInt(0),
        .revision = if (owner) |value| value.revision else 1,
        .name = if (name.len == 0) remote.endpoint.host else name,
        .host = remote.endpoint.host,
        .port = remote.endpoint.port,
        .user = remote.endpoint.user,
        .strict_host_key_checking = remote.strict_host_key_checking,
        .totp_secret = remote.totp_secret,
        .auth_mode = switch (remote.auth) {
            .agent => .agent,
            .private_key => .private_key,
            else => .password,
        },
        .identity_file = switch (remote.auth) {
            .private_key => |key| key.path,
            else => null,
        },
    };
}
fn failure(reason: anyerror, receipt: sessions.CloseReceipt) operations.Failure {
    return .{ .domain = .transport, .code = @errorName(reason), .stage = "forward", .retryable = receipt == .released, .cleanup = switch (receipt) {
        .released => .released,
        .awaiting => .releasing,
        .unknown => .unknown,
    }, .safe_message = "SOCKS5 连接未完成" };
}
fn pause() void {
    var empty: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&empty, 0, 10);
}
