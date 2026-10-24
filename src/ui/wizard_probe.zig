//! A connection test owns an independent app operation, never a SessionHandle.
//! It uses the production frozen SSH plan and releases it before publishing.
const std = @import("std");
const wizard = @import("wizard.zig");
const hosts = @import("../config/hosts.zig");
const config = @import("../config/config.zig");
const lifecycle = @import("session_lifecycle.zig");
const runtime = @import("session_runtime.zig");
const operations = @import("../host/operation.zig");
const ssh = @import("../proto/ssh/session.zig");
const Route = @import("../proto/ssh/jump_transport.zig").Route;
const policy = @import("../proto/ssh/connection_policy.zig");
const progress = @import("../proto/ssh/connection_progress.zig");
const Paths = @import("../config/paths.zig").Paths;
const auth = @import("../proto/ssh/auth_challenge.zig");
const HostKeyBridge = @import("host_key_confirmation.zig").Bridge;

pub const Purpose = runtime.Purpose;
pub const Outcome = struct {
    generation: u64,
    key: operations.OperationKey,
    draft_id: u64,
    draft_revision: u64,
    source_owner: ?hosts.identity.AssetOwner,
    purpose: Purpose = .@"test",
    protocol: hosts.Protocol,
    elapsed_ms: u64,
    reached_stage: ?progress.Phase = null,
    failure: ?anyerror,
    cleanup: operations.Cleanup,
    resources: ?ssh.ResourceLedger.Snapshot = null,
    details_snapshot: ?ssh.ConnectionDetails.ConnectionDetailsSnapshot = null,
};
pub const Status = union(enum) { pending, finished: Outcome };
/// Journal and ledger are self-contained value copies. Only hop display
/// strings borrow the immutable Job until Controller.retire/Job.deinit;
/// views must copy those strings synchronously before retaining a projection.
pub const ConnectionProgress = struct {
    pub const Hop = struct { name: []const u8, host: []const u8, user: []const u8, port: u16 };
    key: operations.OperationKey,
    generation: u64,
    draft_id: u64,
    draft_revision: u64,
    source_owner: ?hosts.identity.AssetOwner,
    purpose: Purpose = .@"test",
    protocol: hosts.Protocol = .ssh,
    hops: [9]Hop = undefined,
    hop_count: usize,
    journal: progress.Journal.Snapshot,
    resources: ssh.ResourceLedger.Snapshot,
    worker_finished: bool,
    /// A stopped network worker is not terminal until its native graph drains.
    finished: bool,
    cancelled: bool,
    failure: ?anyerror,
    cleanup: operations.Cleanup,
};
/// Called only by the controller's polling thread. Registration promises an
/// actual consumer of this Job's original-key bridges, never an auto-approval.
pub const InteractionSink = struct {
    context: *anyopaque,
    consume: *const fn (*anyopaque, *Job) void,
};
const Source = struct {
    host: hosts.HostConfig,
    route_hosts: []const hosts.HostConfig,
    settings: config.Config,
    draft_id: u64,
    draft_revision: u64,
};
pub const StartOptions = struct {
    key: operations.OperationKey,
    /// Tests supply an isolated absolute path; production captures Paths once.
    known_hosts_path: ?[]const u8 = null,
    interaction_sink: ?InteractionSink = null,
    sample_rtt: bool = false,
};

pub const Job = struct {
    const allocator = std.heap.c_allocator;
    source: lifecycle.Snapshot(Source),
    generation: u64,
    key: operations.OperationKey = undefined,
    library: *const ssh.Library,
    known_hosts_path: []u8,
    io_instance: std.Io.Threaded,
    thread: ?std.Thread = null,
    ready: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),
    host_key_bridge: HostKeyBridge = .{},
    auth_bridge: auth.InteractiveBridge = .{},
    request_counter: auth.RequestCounter = .{},
    progress: progress.Journal = .{},
    outcome: Outcome = undefined,
    result_published: bool = false,
    interaction_sink: ?InteractionSink = null,
    interaction_unavailable: std.atomic.Value(bool) = .init(false),
    resource_ledger: ssh.ResourceLedger,
    connection_details: ssh.ConnectionDetails.Store = .{},
    sample_rtt: bool = false,
    retained_cleanup: runtime.DeferredRelease = .{},

    /// Legacy callers must move to Controller.start or supply their original
    /// operation. There is no private ID counter or direct-shim fallback.
    pub fn start(_: wizard.Draft, _: []const hosts.HostConfig, _: config.Config, _: u64, library: *const ssh.Library) !*Job {
        if (!library.active) return error.LibraryNotInitialized;
        return error.OperationKeyRequired;
    }

    pub fn startForOperation(draft: wizard.Draft, registry: []const hosts.HostConfig, settings: config.Config, generation: u64, library: *const ssh.Library, key: operations.OperationKey) !*Job {
        return startWithOptions(draft, registry, settings, generation, library, .{ .key = key });
    }

    pub fn startWithOptions(draft: wizard.Draft, registry: []const hosts.HostConfig, settings: config.Config, generation: u64, library: *const ssh.Library, options: StartOptions) !*Job {
        try validateKey(options.key);
        const self = try prepare(draft, registry, settings, generation, library, options.known_hosts_path, options.interaction_sink);
        self.sample_rtt = options.sample_rtt;
        self.activate(options.key);
        return self;
    }

    fn prepare(draft: wizard.Draft, registry: []const hosts.HostConfig, settings: config.Config, generation: u64, library: *const ssh.Library, known_hosts_path: ?[]const u8, sink: ?InteractionSink) !*Job {
        if (!library.active) return error.LibraryNotInitialized;
        if (draft.draft_id == 0 or draft.revision == 0 or generation == 0) return error.InvalidDraftIdentity;
        const host = try draft.toHostConfig();
        try validateProbeHost(host);
        const hops = try runtime.resolveHostRoute(allocator, host, registry);
        defer allocator.free(hops);
        // Freeze selected IDs and every hop's independent policy/auth before IO.
        var source = try lifecycle.Snapshot(Source).init(allocator, .{ .host = host, .route_hosts = hops, .settings = settings, .draft_id = draft.draft_id, .draft_revision = draft.revision });
        errdefer source.deinit();
        const path = if (known_hosts_path) |path| blk: {
            if (!std.fs.path.isAbsolute(path)) return error.InvalidTrustStorePath;
            break :blk try allocator.dupe(u8, path);
        } else blk: {
            var paths = try Paths.forApplication(allocator);
            defer paths.deinit();
            break :blk try allocator.dupe(u8, paths.known_hosts);
        };
        errdefer allocator.free(path);
        const self = try allocator.create(Job);
        self.* = .{ .source = source, .generation = generation, .library = library, .known_hosts_path = path, .interaction_sink = sink, .io_instance = .init(allocator, .{}), .resource_ledger = try ssh.ResourceLedger.init(null, hops.len + 1) };
        self.host_key_bridge.request_counter = &self.request_counter;
        self.auth_bridge.request_counter = &self.request_counter;
        return self;
    }

    fn activate(self: *Job, key: operations.OperationKey) void {
        self.key = key;
        self.resource_ledger.key = key;
        self.progress.begin(key.attempt_id.?);
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
            self.publishOutcome(0, err);
            return;
        };
    }

    pub fn poll(self: *Job) Status {
        if (!self.ready.load(.acquire)) {
            if (!self.cancelled.load(.acquire)) if (self.interaction_sink) |sink| sink.consume(sink.context, self);
            return .pending;
        }
        if (self.outcome.cleanup != .released) {
            const receipt = self.retained_cleanup.request(&self.resource_ledger, runtime.drainRetainedResources);
            self.outcome.cleanup = switch (receipt) {
                .released => .released,
                .awaiting => .releasing,
                .unknown => .unknown,
            };
        }
        self.outcome.resources = self.resource_ledger.snapshot();
        if (self.outcome.details_snapshot != null) self.outcome.details_snapshot = self.connection_details.snapshot(self.key) catch self.outcome.details_snapshot;
        if (self.outcome.cleanup != .released or !self.outcome.resources.?.released()) return .pending;
        return .{ .finished = self.outcome };
    }

    /// Complete value copy: endpoints/prompts/state and the original
    /// key/hop/request identity never borrow the worker, even after retirement.
    /// Reading this does not register an authentication consumer.
    pub fn pendingAuthentication(self: *Job) ?auth.Snapshot {
        if (self.interaction_sink == null or self.cancelled.load(.acquire) or self.ready.load(.acquire)) return null;
        if (self.host_key_bridge.snapshot()) |request| {
            if (request.operation_key == null or !request.operation_key.?.eql(self.key)) return null;
            const host = self.hostAt(request.hop_index) orelse return null;
            if (host.user.len > 256) {
                self.cancel();
                return null;
            }
            var challenge: auth.Snapshot = .{
                .identity = .{ .key = self.key, .hop_index = request.hop_index, .request_id = request.generation },
                .source_owner = request.source_owner,
                .kind = if (request.status == .changed) .host_key_changed else .host_key_unknown,
                .presentation = .protected_form,
                .presentation_config_revision = self.source.value.settings.config_revision,
                .expires_at_ns = null,
                .port = request.port,
                .host_len = request.host_len,
                .user_len = host.user.len,
            };
            @memcpy(challenge.host[0..request.host_len], request.hostSlice());
            @memcpy(challenge.user[0..host.user.len], host.user);
            return challenge;
        }
        const challenge = self.auth_bridge.snapshot() orelse return null;
        if (!challenge.identity.key.eql(self.key) or self.hostAt(challenge.identity.hop_index) == null) return null;
        return switch (challenge.state) {
            .completed, .cancelled => null,
            else => challenge,
        };
    }

    pub fn submitAuthentication(self: *Job, request: auth.RequestIdentity, reply: auth.Reply) !void {
        const current = self.pendingAuthentication() orelse return error.StaleAuthentication;
        if (!current.identity.eql(request)) return error.StaleAuthentication;
        switch (current.kind) {
            .host_key_unknown, .host_key_changed => if (!self.host_key_bridge.decideScoped(request, reply)) return error.StaleAuthentication,
            else => try self.auth_bridge.submit(request, reply),
        }
    }

    /// A stale request cannot cancel another prompt, hop or test operation.
    pub fn cancelAuthentication(self: *Job, request: auth.RequestIdentity) bool {
        const current = self.pendingAuthentication() orelse return false;
        if (!current.identity.eql(request)) return false;
        switch (current.kind) {
            .host_key_unknown, .host_key_changed => {},
            else => if (!self.auth_bridge.cancelRequest(request)) return false,
        }
        self.cancel();
        return true;
    }

    /// Borrowed frozen display/config metadata, valid until this Job retires.
    /// Authentication secrets are deliberately absent from this projection.
    pub fn authenticationHostFor(self: *Job, request: auth.RequestIdentity) ?hosts.HostConfig {
        const current = self.pendingAuthentication() orelse return null;
        if (!current.identity.eql(request)) return null;
        var host = self.hostAt(request.hop_index) orelse return null;
        host.password = null;
        host.key_passphrase = null;
        host.totp_secret = null;
        return host;
    }

    pub fn authenticationTotp(self: *Job, request: auth.RequestIdentity, now: @import("../proto/ssh/totp_prefill.zig").Time) !?@import("../proto/ssh/totp_prefill.zig").Suggestion {
        const current = self.pendingAuthentication() orelse return null;
        if (!current.identity.eql(request)) return null;
        const host = self.hostAt(request.hop_index) orelse return null;
        return @import("../proto/ssh/totp_prefill.zig").suggest(&current, request, host, self.source.value.settings.ssh.totp_autofill, now);
    }

    /// An owned value copy of this hop's negotiated host key. It remains
    /// available for the following password/passphrase challenge, but lookup
    /// still requires that challenge's complete current request identity.
    pub fn authenticationHostKey(self: *Job, request: auth.RequestIdentity) ?@import("host_key_confirmation.zig").Request {
        const current = self.pendingAuthentication() orelse return null;
        if (!current.identity.eql(request)) return null;
        const observed = self.host_key_bridge.lastSnapshot() orelse return null;
        if (observed.operation_key == null or !observed.operation_key.?.eql(request.key) or observed.hop_index != request.hop_index) return null;
        return observed;
    }

    pub fn connectionProgress(self: *Job) ConnectionProgress {
        const finished = self.ready.load(.acquire);
        const cancelled = self.cancelled.load(.acquire);
        const resources = self.resource_ledger.snapshot();
        const cleanup: operations.Cleanup = if (resources.hasUnknown() or (finished and self.outcome.cleanup == .unknown)) .unknown else if (finished and resources.released()) .released else if (finished or cancelled) .releasing else .not_started;
        var result: ConnectionProgress = .{
            .key = self.key,
            .generation = self.generation,
            .protocol = self.source.value.host.protocol,
            .draft_id = self.source.value.draft_id,
            .draft_revision = self.source.value.draft_revision,
            .source_owner = if (@backingInt(self.source.value.host.connection_id) != 0) self.source.value.host.owner() else null,
            .hop_count = self.source.value.route_hosts.len + 1,
            .journal = self.progress.snapshot(),
            .resources = resources,
            .worker_finished = finished,
            .finished = finished and cleanup == .released,
            .cancelled = cancelled,
            .failure = if (finished) self.outcome.failure else null,
            .cleanup = cleanup,
        };
        for (0..result.hop_count) |index| {
            const host = self.hostAt(index).?;
            result.hops[index] = .{ .name = host.name, .host = host.host, .user = host.user, .port = host.port };
        }
        return result;
    }

    fn hostAt(self: *const Job, hop: usize) ?hosts.HostConfig {
        if (hop < self.source.value.route_hosts.len) return self.source.value.route_hosts[hop];
        if (hop == self.source.value.route_hosts.len) return self.source.value.host;
        return null;
    }

    pub fn cancel(self: *Job) void {
        self.cancelled.store(true, .release);
        self.host_key_bridge.cancel();
        self.auth_bridge.cancel();
    }

    /// Controller.retire calls this only after finished. Final scope destruction
    /// may cancel/join while retaining the entire frozen owner until it drains.
    pub fn deinit(self: *Job) void {
        _ = self.deinitReleased();
    }

    pub fn deinitReleased(self: *Job) bool {
        self.cancel();
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.retained_cleanup.finish(&self.resource_ledger, runtime.drainRetainedResources);
        if (!self.resource_ledger.snapshot().released()) return false;
        self.io_instance.deinit();
        self.source.deinit();
        allocator.free(self.known_hosts_path);
        allocator.destroy(self);
        return true;
    }

    fn run(self: *Job) void {
        const io = self.io_instance.io();
        const begin = std.Io.Clock.awake.now(io).toMilliseconds();
        const failure: ?anyerror = if (self.probe()) |_| null else |err| if (self.interaction_unavailable.load(.acquire) or err == error.AuthenticationInteractionRequired) error.InteractionUnavailable else err;
        self.retained_cleanup.finish(&self.resource_ledger, runtime.drainRetainedResources);
        // probe's Session/Route/Store/arena defers have actually run here.
        const end = std.Io.Clock.awake.now(io).toMilliseconds();
        self.publishOutcome(@intCast(@max(0, end - begin)), failure);
    }

    fn publishOutcome(self: *Job, elapsed_ms: u64, failure: ?anyerror) void {
        const log = self.progress.snapshot();
        self.outcome = .{
            .generation = self.generation,
            .key = self.key,
            .draft_id = self.source.value.draft_id,
            .draft_revision = self.source.value.draft_revision,
            .source_owner = if (@backingInt(self.source.value.host.connection_id) != 0) self.source.value.host.owner() else null,
            .protocol = self.source.value.host.protocol,
            .elapsed_ms = elapsed_ms,
            .reached_stage = if (log.count != 0) log.entries[log.count - 1].phase else null,
            .failure = if (self.cancelled.load(.acquire)) error.Cancelled else failure,
            .cleanup = if (self.resource_ledger.snapshot().released()) .released else if (self.resource_ledger.snapshot().hasUnknown()) .unknown else .releasing,
            .resources = self.resource_ledger.snapshot(),
            .details_snapshot = self.connection_details.snapshot(self.key) catch null,
        };
        self.ready.store(true, .release);
    }

    fn probe(self: *Job) !void {
        if (self.cancelled.load(.acquire)) return error.Cancelled;
        if (!self.library.active) return error.LibraryNotInitialized;
        const io = self.io_instance.io();
        var store = try policy.HostKeyStore.load(io, std.Io.Dir.cwd(), allocator, self.known_hosts_path);
        defer store.deinit();
        try store.setPersistence(io, std.Io.Dir.cwd(), self.known_hosts_path);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var target = runtime.targetFromHost(self.source.value.host, self.source.value.route_hosts);
        target.operation_key = self.key;
        target.resource_ledger = &self.resource_ledger;
        target.connection_details = &self.connection_details;
        target.host_key_store = &store;
        target.host_key_bridge = if (self.interaction_sink != null) &self.host_key_bridge else null;
        target.keyboard_bridge = if (self.interaction_sink != null) &self.auth_bridge else null;
        target.cancel_token = &self.cancelled;
        const options = try runtime.prepareConnectionOptions(arena.allocator(), self.source.value.settings, target, .@"test");
        for (options) |*option| {
            option.progress_observer = self.progress.observer();
            if (self.interaction_sink == null) option.host_key_observer = .{ .ctx = self, .callback = unavailableHostKey };
        }
        if (options.len == 1) {
            var connection = try ssh.Session.connect(self.library, options[0]);
            defer if (connection.closeReceipt() != .released) {
                _ = self.resource_ledger.retainFailure(&connection);
            };
            if (self.source.value.host.protocol == .sftp) try self.probeDirectory(&connection);
            if (self.sample_rtt) try connection.measureRtt(1500, &self.cancelled);
        } else {
            const route = try Route.connect(allocator, self.library, options);
            // Do not takeTarget: this test keeps the whole graph and releases
            // target, downstream relay/channel, then upstream hops in reverse.
            defer route.deinit();
            if (self.sample_rtt) try route.measureRtt(1500, &self.cancelled);
        }
        if (self.cancelled.load(.acquire)) return error.Cancelled;
    }

    /// Runs only on this probe's worker, using its no-shell Session. A successful
    /// SSH authentication alone does not prove the SFTP subsystem/directory.
    fn probeDirectory(self: *Job, connection: *ssh.Session) !void {
        const deadline = @import("../platform/realtime.zig").monotonicNs() + @as(u64, @max(self.source.value.settings.ssh.connect_timeout_sec, 1)) * std.time.ns_per_s;
        try self.probeIo(void, ssh.Session.sftpReadonlyInit, .{connection}, deadline);
        var buffer: [4096]u8 = undefined;
        const path = try self.probeIo([]const u8, ssh.Session.sftpRealpath, .{ connection, @as([:0]const u8, "."), @as([]u8, &buffer) }, deadline);
        if (path.len == 0 or path[0] != '/') return error.InvalidResolvedPath;
        const owned = try allocator.dupeSentinel(u8, path, 0);
        defer allocator.free(owned);
        const attributes = try self.probeIo(ssh.SftpAttributes, ssh.Session.sftpStat, .{ connection, owned, true }, deadline);
        if (attributes.kind != .directory) return error.NotDirectory;
        var directory = try self.probeIo(ssh.SftpReadonlyHandle, ssh.Session.sftpOpenReadonly, .{ connection, owned, true }, deadline);
        defer _ = directory.closeReceipt();
        var name: [4096]u8 = undefined;
        // Keep the exact handle/buffer stable across EAGAIN. No other SFTP API
        // may take over the library's in-flight per-context operation.
        const Entry = @typeInfo(@typeInfo(@TypeOf(ssh.SftpReadonlyHandle.readDirectory)).@"fn".return_type.?).error_union.payload;
        _ = try self.probeIo(Entry, ssh.SftpReadonlyHandle.readDirectory, .{ &directory, @as([]u8, &name) }, deadline);
        while (true) switch (directory.closeReceipt().receipt) {
            .released => break,
            .unknown => return error.SftpCloseFailed,
            .awaiting => try self.waitProbeIo(deadline),
        };
        if (self.cancelled.load(.acquire)) return error.Cancelled;
    }

    fn probeIo(self: *Job, comptime T: type, comptime method: anytype, args: anytype, deadline: i128) !T {
        while (true) {
            if (self.cancelled.load(.acquire)) return error.Cancelled;
            if (@import("../platform/realtime.zig").monotonicNs() >= deadline) return error.Timeout;
            return @call(.auto, method, args) catch |err| {
                if (err != error.WouldBlock) return err;
                try self.waitProbeIo(deadline);
                continue;
            };
        }
    }

    fn waitProbeIo(self: *Job, deadline: i128) !void {
        if (self.cancelled.load(.acquire)) return error.Cancelled;
        if (@import("../platform/realtime.zig").monotonicNs() >= deadline) return error.Timeout;
        var unused: [1]std.c.pollfd = undefined;
        _ = std.c.poll(&unused, 0, 1);
    }

    fn unavailableHostKey(raw: *anyopaque, _: []const u8, _: u16, _: ssh.HostKeyInfo) ssh.HostKeyDecision {
        const self: *Job = @ptrCast(@alignCast(raw));
        self.interaction_unavailable.store(true, .release);
        return .reject_unknown;
    }
};

fn validateKey(key: operations.OperationKey) !void {
    if (key.owner != .app or key.operation_id == 0 or key.attempt_id == null or key.attempt_id == 0) return error.InvalidOperation;
}

/// Uses the application's existing Journal. The controller owns only its test
/// jobs, so unrelated SessionHost operations keep their original IDs/resources.
pub const Controller = struct {
    allocator: std.mem.Allocator,
    journal: *operations.Journal,
    jobs: std.ArrayList(*Job) = .empty,
    next_attempt: u64 = 1,
    exhausted: bool = false,
    interaction_sink: ?InteractionSink = null,

    /// Frozen into the next Job. Ordinary tests keep this false and perform
    /// no additional channel-open round trips.
    sample_rtt: bool = false,

    pub fn init(allocator: std.mem.Allocator, journal: *operations.Journal) Controller {
        return .{ .allocator = allocator, .journal = journal };
    }

    pub fn start(self: *Controller, draft: wizard.Draft, registry: []const hosts.HostConfig, settings: config.Config, generation: u64, library: *const ssh.Library) !*Job {
        return self.startWithTrustStore(draft, registry, settings, generation, library, null);
    }

    pub fn startWithTrustStore(self: *Controller, draft: wizard.Draft, registry: []const hosts.HostConfig, settings: config.Config, generation: u64, library: *const ssh.Library, path: ?[]const u8) !*Job {
        for (self.jobs.items) |job| {
            if (job.source.value.draft_id == draft.draft_id) {
                const previous = job.poll();
                if (previous == .pending or previous.finished.cleanup != .released) return error.CleanupNotReleased;
            }
        }
        if (self.exhausted) return error.IdentityExhausted;
        try self.jobs.ensureUnusedCapacity(self.allocator, 1);
        const job = try Job.prepare(draft, registry, settings, generation, library, path, self.interaction_sink);
        errdefer job.deinit();
        const attempt = self.next_attempt;
        const key = try self.journal.begin(.app, attempt);
        if (attempt == std.math.maxInt(u64)) self.exhausted = true else self.next_attempt += 1;
        job.sample_rtt = self.sample_rtt;
        job.activate(key);
        self.jobs.appendAssumeCapacity(job);
        return job;
    }

    pub fn cancelAll(self: *Controller) void {
        for (self.jobs.items) |job| job.cancel();
    }

    pub fn setInteractionSink(self: *Controller, sink: ?InteractionSink) void {
        // A removed UI consumer cannot leave old workers waiting on dead UI.
        if (sink == null) self.cancelAll();
        self.interaction_sink = sink;
    }

    pub fn pendingAuthentication(self: *Controller) ?auth.Snapshot {
        for (self.jobs.items) |job| if (job.pendingAuthentication()) |challenge| return challenge;
        return null;
    }

    pub fn submitAuthentication(self: *Controller, request: auth.RequestIdentity, reply: auth.Reply) !void {
        const job = self.forKey(request.key) orelse return error.StaleAuthentication;
        try job.submitAuthentication(request, reply);
    }

    pub fn cancelAuthentication(self: *Controller, request: auth.RequestIdentity) bool {
        const job = self.forKey(request.key) orelse return false;
        return job.cancelAuthentication(request);
    }

    pub fn authenticationHostFor(self: *Controller, request: auth.RequestIdentity) ?hosts.HostConfig {
        const job = self.forKey(request.key) orelse return null;
        return job.authenticationHostFor(request);
    }

    pub fn authenticationTotp(self: *Controller, request: auth.RequestIdentity, now: @import("../proto/ssh/totp_prefill.zig").Time) !?@import("../proto/ssh/totp_prefill.zig").Suggestion {
        const job = self.forKey(request.key) orelse return null;
        return job.authenticationTotp(request, now);
    }

    pub fn authenticationHostKey(self: *Controller, request: auth.RequestIdentity) ?@import("host_key_confirmation.zig").Request {
        const job = self.forKey(request.key) orelse return null;
        return job.authenticationHostKey(request);
    }

    pub fn connectionProgress(self: *Controller, key: operations.OperationKey) ?ConnectionProgress {
        const job = self.forKey(key) orelse return null;
        return job.connectionProgress();
    }

    pub fn cancel(self: *Controller, key: operations.OperationKey) bool {
        const job = self.forKey(key) orelse return false;
        if (job.ready.load(.acquire)) return false;
        job.cancel();
        return true;
    }

    fn forKey(self: *Controller, key: operations.OperationKey) ?*Job {
        for (self.jobs.items) |job| if (job.key.eql(key)) return job;
        return null;
    }

    pub fn poll(self: *Controller, job: *Job) !Status {
        _ = try self.indexOf(job);
        const status = job.poll();
        if (status == .finished and !job.result_published) {
            const result = status.finished;
            if (result.cleanup != .released) return error.CleanupNotReleased;
            if (result.failure) |failure| {
                _ = try self.journal.failReleased(result.key, .{ .domain = .transport, .code = @errorName(failure), .stage = if (result.reached_stage) |stage| @tagName(stage) else null, .retryable = true, .cleanup = .released, .safe_message = @errorName(failure) });
            } else {
                _ = try self.journal.completeReleased(result.key, "connection_test_released");
            }
            job.result_published = true;
        }
        return status;
    }

    pub fn retire(self: *Controller, job: *Job) !void {
        const index = try self.indexOf(job);
        if ((try self.poll(job)) != .finished) return error.CleanupNotReleased;
        try self.journal.retire(job.key, .resources_released);
        _ = self.jobs.orderedRemove(index);
        job.deinit();
    }

    fn indexOf(self: *Controller, job: *Job) !usize {
        for (self.jobs.items, 0..) |candidate, index| if (candidate == job) return index;
        return error.ForeignTestOperation;
    }

    pub fn deinit(self: *Controller) void {
        self.cancelAll();
        for (self.jobs.items) |job| {
            if (job.thread) |thread| thread.join();
            job.thread = null;
            _ = self.poll(job) catch |err| {
                // Final application shutdown still releases the actual graph;
                // keep an unpublishable record for the owning Journal's final
                // destructor rather than forge a terminal/released event.
                std.log.warn("test shutdown result publication failed: {s}", .{@errorName(err)});
            };
            if (job.result_published) self.journal.retire(job.key, .resources_released) catch |err| {
                std.log.warn("test shutdown operation retirement failed: {s}", .{@errorName(err)});
            };
            job.deinit();
        }
        self.jobs.deinit(self.allocator);
        self.jobs = .empty;
    }
};

/// Pure validation uses the same numeric resolver as formal Runtime creation.
pub fn validateProbeHost(host: hosts.HostConfig) !void {
    if (host.protocol == .sftp and (host.route.len != 0 or host.jump_chain.len != 0)) return error.ProxyJumpTransportUnavailable;
}

pub fn validateRoute(draft: wizard.Draft, registry: []const hosts.HostConfig) !void {
    const host = try draft.toHostConfig();
    try validateProbeHost(host);
    const selected = try runtime.resolveHostRoute(std.heap.c_allocator, host, registry);
    defer std.heap.c_allocator.free(selected);
}

fn prepareTestJob(library: *const ssh.Library, key: operations.OperationKey, draft: wizard.Draft, registry: []const hosts.HostConfig) !*Job {
    const Consumer = struct {
        fn consume(_: *anyopaque, _: *Job) void {}
    };
    var settings: config.Config = .{};
    settings.config_revision = 19;
    const job = try Job.prepare(draft, registry, settings, 3, library, "/tmp/zerowork-probe-api-no-io", .{ .context = @ptrCast(@constCast(library)), .consume = Consumer.consume });
    job.key = key;
    job.resource_ledger.key = key;
    job.progress.begin(key.attempt_id.?);
    return job;
}

test "probe authentication API freezes full request and shares hostkey auth request counter" {
    var library = try ssh.Library.init();
    defer library.deinit();
    const key: operations.OperationKey = .{ .owner = .app, .operation_id = 71, .attempt_id = 4 };
    var name = "frozen-name".*;
    const job = try prepareTestJob(&library, key, .{ .draft_id = 17, .revision = 2, .source_owner = .{ .id = @fromBackingInt(77), .revision = 6 }, .name = &name, .host = "127.0.0.1", .user = "fixture", .auth = .password, .password = "not-projected" }, &.{});
    var destroyed = false;
    defer if (!destroyed) job.deinit();
    @memset(&name, 'x');
    const Offer = struct {
        fn run(value: *Job) void {
            _ = HostKeyBridge.observer(&value.host_key_bridge, "127.0.0.1", 22, .{ .algorithm = "ssh-ed25519", .fingerprint = "SHA256:original", .operation_key = value.key, .hop_index = 0, .source_owner = value.source.value.host.owner() });
        }
    };
    const thread = try std.Thread.spawn(.{}, Offer.run, .{job});
    var joined = false;
    defer if (!joined) {
        job.cancel();
        thread.join();
    };
    while (!job.host_key_bridge.pending()) std.Thread.yield() catch {};
    const trust = job.pendingAuthentication().?;
    try std.testing.expectEqual(auth.Kind.host_key_unknown, trust.kind);
    try std.testing.expect(trust.identity.key.eql(key));
    try std.testing.expectEqual(@as(u64, 1), trust.identity.request_id);
    try std.testing.expectEqual(@as(u64, 19), trust.presentation_config_revision);
    const host = job.authenticationHostFor(trust.identity).?;
    try std.testing.expectEqualStrings("frozen-name", host.name);
    try std.testing.expect(host.password == null and host.key_passphrase == null and host.totp_secret == null);
    const public_key = job.authenticationHostKey(trust.identity).?;
    try std.testing.expectEqualStrings("SHA256:original", public_key.fingerprintSlice());
    var stale = trust.identity;
    stale.hop_index = 1;
    try std.testing.expectError(error.StaleAuthentication, job.submitAuthentication(stale, .trust_once));
    try std.testing.expect(!job.cancelAuthentication(stale));
    try job.submitAuthentication(trust.identity, .trust_once);
    thread.join();
    joined = true;
    const request = try job.auth_bridge.offerChallenge(.{ .key = key, .source_owner = host.owner(), .hop_index = 0, .kind = .keyboard_interactive, .endpoint_identity = .{ .host = "127.0.0.1", .user = "fixture" }, .prompts = &.{ .{ .text = "Password", .echo = false }, .{ .text = "Label", .echo = true } }, .presentation_config_revision = 19 });
    const copied = job.pendingAuthentication().?;
    try std.testing.expectEqual(@as(u64, 2), request.request_id);
    try std.testing.expect(!copied.promptAt(0).echo and copied.promptAt(1).echo);
    try std.testing.expectEqualStrings("Label", copied.promptAt(1).text);
    try std.testing.expect(job.authenticationHostFor(trust.identity) == null);
    try std.testing.expect(job.authenticationHostKey(trust.identity) == null);
    try std.testing.expectEqualStrings("SHA256:original", job.authenticationHostKey(request).?.fingerprintSlice());
    try job.submitAuthentication(request, .{ .answers = &.{ "secret", "visible" } });
    try std.testing.expectError(error.StaleChallenge, job.submitAuthentication(request, .{ .answers = &.{ "twice", "twice" } }));
    var reply = try job.auth_bridge.waitResponse(request, 10);
    defer reply.deinit();
    try std.testing.expectEqualStrings("secret", reply.answerAt(0));
    try job.auth_bridge.complete(request);
    job.deinit();
    destroyed = true;
    try std.testing.expectEqualStrings("127.0.0.1", copied.endpoint().host);
    try std.testing.expectEqualStrings("Label", copied.promptAt(1).text);
    try std.testing.expectEqualStrings("SHA256:original", public_key.fingerprintSlice());
}

test "probe controller scopes cancellation progress and terminal receipt to original job" {
    var library = try ssh.Library.init();
    defer library.deinit();
    var journal = operations.Journal.init(std.testing.allocator);
    defer journal.deinit();
    var controller = Controller.init(std.testing.allocator, &journal);
    defer controller.deinit();
    const first_key = try journal.begin(.app, 1);
    const second_key = try journal.begin(.app, 2);
    const draft: wizard.Draft = .{ .draft_id = 17, .revision = 2, .name = "target", .host = "127.0.0.1", .user = "fixture", .route = &.{@fromBackingInt(41)} };
    const hop: hosts.HostConfig = .{ .connection_id = @fromBackingInt(41), .revision = 8, .name = "jump", .host = "bridge.test", .user = "bridge-user" };
    const first = try prepareTestJob(&library, first_key, draft, &.{hop});
    try controller.jobs.append(std.testing.allocator, first);
    const second = try prepareTestJob(&library, second_key, draft, &.{hop});
    try controller.jobs.append(std.testing.allocator, second);
    const request = try first.auth_bridge.offerChallenge(.{ .key = first_key, .hop_index = 0, .kind = .password, .endpoint_identity = .{ .host = hop.host, .user = hop.user }, .prompts = &.{.{ .text = "Password" }}, .presentation_config_revision = 19 });
    try std.testing.expect(controller.pendingAuthentication().?.identity.eql(request));
    var wrong = request;
    wrong.request_id += 1;
    try std.testing.expect(!controller.cancelAuthentication(wrong));
    try std.testing.expect(controller.cancelAuthentication(request));
    try std.testing.expect(first.cancelled.load(.acquire));
    try std.testing.expect(!second.cancelled.load(.acquire));
    try std.testing.expect(controller.pendingAuthentication() == null);
    try std.testing.expectError(error.StaleAuthentication, controller.submitAuthentication(request, .{ .answers = &.{"late"} }));
    second.progress.record(.{ .attempt = 2, .hop = 0, .hop_count = 2, .host = hop.host, .port = 22, .phase = .authentication, .status = .started });
    try std.testing.expect(second.resource_ledger.record(second_key, 0, .transport, .owned));
    second.publishOutcome(0, error.Cancelled);
    second.retained_cleanup.state.store(.unknown, .release);
    const pending = (try controller.poll(second));
    try std.testing.expect(pending == .pending);
    try std.testing.expect(!journal.isTerminal(second_key));
    const projection = controller.connectionProgress(second_key).?;
    try std.testing.expect(projection.key.eql(second_key));
    try std.testing.expect(projection.worker_finished and !projection.finished);
    try std.testing.expectEqual(@as(usize, 2), projection.hop_count);
    try std.testing.expectEqualStrings("bridge.test", projection.hops[0].host);
    try std.testing.expectEqualStrings("127.0.0.1", projection.hops[1].host);
    try std.testing.expectEqual(@as(usize, 1), projection.journal.count);
    try std.testing.expectEqual(ssh.ResourceState.owned, projection.resources.entry(0, .transport).state);
    try std.testing.expectError(error.CleanupNotReleased, controller.retire(second));
    try std.testing.expect(second.resource_ledger.record(second_key, 0, .transport, .released));
    second.retained_cleanup.state.store(.released, .release);
    _ = try controller.poll(second);
    try controller.retire(second);
    try std.testing.expect(controller.connectionProgress(second_key) == null);
    try std.testing.expectEqual(@as(usize, 1), projection.journal.count);
}
