const std = @import("std");
const Channel = @import("channel.zig").Channel;
const worker_io = @import("../../vt/worker_io.zig");
const channel_pump = @import("../../vt/channel_pump.zig");
const c = @import("generated_ssh_session");
const policy = @import("connection_policy.zig");
const auth_flow = @import("auth_flow.zig");
const identity = @import("../../host/identity.zig");
const OperationKey = @import("../../host/operation.zig").OperationKey;
const known_hosts = @import("host_key_store.zig");
pub const ConnectionProgress = @import("connection_progress.zig");
pub const ConnectionDetails = @import("connection_details.zig");
pub const SocketRelay = @import("socket_relay.zig");
pub const JumpTransport = @import("jump_transport.zig");
test {
    _ = SocketRelay;
    _ = JumpTransport;
}

pub const State = enum { idle, connecting, authenticated, active, closing, closed, failed };
pub const ReleaseReceipt = enum { released, awaiting, unknown };

fn nativeReleaseReceipt(result: c_int) ReleaseReceipt {
    return switch (result) {
        0 => .released,
        1 => .awaiting,
        else => .unknown,
    };
}
pub const PrivateKeyAuth = auth_flow.PrivateKeyAuth;
pub const Auth = auth_flow.Auth;
pub const KeyboardPrompt = auth_flow.KeyboardPrompt;
pub const AuthInteraction = auth_flow.Interaction;
pub const HostKeyDecision = enum {
    /// Refuse an unrecognised key and let the caller present a confirmation UI.
    reject_unknown,
    /// Accept an unrecognised key for this session only.
    trust_once,
    /// Record an unrecognised key in the supplied store for future sessions.
    trust_save,
    /// Accept a key that differs from the stored key only after an explicit
    /// confirmation (the UI must require the literal `yes` acknowledgement).
    /// This is intentionally distinct from trust_once so changed keys can
    /// never be accepted by a generic first-connect button.
    trust_changed_yes,
};
pub const HostKeyStatus = enum { unknown, trusted, changed };
pub const HostKeyAcceptance = enum { unverified, known_match, unknown_once, unknown_saved, replaced, accepted_changed_for_attempt };
pub const HostKeyInfo = struct {
    algorithm: []const u8,
    fingerprint: []const u8,
    raw_key: []const u8 = &.{},
    status: HostKeyStatus = .unknown,
    verification: ?known_hosts.Verification = null,
    store_path: ?[]const u8 = null,
    acceptance: HostKeyAcceptance = .unverified,
    operation_key: ?OperationKey = null,
    hop_index: usize = 0,
    source_owner: ?identity.AssetOwner = null,
};
pub const HostKeyObserver = struct {
    ctx: *anyopaque,
    callback: *const fn (ctx: *anyopaque, host: []const u8, port: u16, info: HostKeyInfo) HostKeyDecision,
};

pub const ResourceKind = enum { transport, session, shell, tunnel, relay_socket, relay_worker, rtt_channel };
pub const ResourceState = enum { absent, owned, releasing, released, transferred, unknown };
pub const ResourceEntry = struct {
    state: ResourceState = .absent,
    acquired_sequence: u64 = 0,
    released_sequence: u64 = 0,
};

/// One bounded record of the resources actually acquired by this connection
/// attempt. It does not allocate operation IDs or own a second event journal.
pub const ResourceLedger = struct {
    pub const max_hops = 9;
    const kind_count = std.meta.fieldNames(ResourceKind).len;
    pub const Snapshot = struct {
        key: ?OperationKey,
        hop_count: usize,
        revision: u64,
        resources: [max_hops][kind_count]ResourceEntry,
        overflowed: bool,
        retained_count: usize,

        pub fn entry(self: *const Snapshot, hop: usize, kind: ResourceKind) ResourceEntry {
            std.debug.assert(hop < self.hop_count);
            return self.resources[hop][@backingInt(kind)];
        }

        pub fn released(self: *const Snapshot) bool {
            if (self.overflowed or self.retained_count != 0) return false;
            for (self.resources[0..self.hop_count]) |hop| for (hop) |resource| {
                if (resource.state != .absent and resource.state != .released and resource.state != .transferred) return false;
            };
            return true;
        }

        pub fn hasUnknown(self: *const Snapshot) bool {
            if (self.overflowed) return true;
            for (self.resources[0..self.hop_count]) |hop| for (hop) |resource| {
                if (resource.state == .unknown) return true;
            };
            return false;
        }
    };
    key: ?OperationKey,
    hop_count: usize,
    lock_flag: std.atomic.Value(bool) = .init(false),
    revision: u64 = 1,
    sequence: u64 = 0,
    resources: [max_hops][kind_count]ResourceEntry = @splat(@splat(.{})),
    overflowed: bool = false,
    retained_sessions: [max_hops]?Session = @splat(null),
    retained_route: ?*JumpTransport.Route = null,
    retained_library: ?Library = null,
    draining: std.atomic.Value(bool) = .init(false),
    previous_released: ?Snapshot = null,
    redirects: [9]?struct { key: ?OperationKey, ledger: *ResourceLedger, target_hop: usize } = @splat(null),

    pub fn transferConnectionOwnership(self: *ResourceLedger, target: *ResourceLedger) !void {
        self.lock();
        defer self.unlock();
        var slot: ?usize = null;
        for (self.redirects, 0..) |entry, i| if (entry == null) {
            slot = i;
            break;
        };
        const index = slot orelse return error.SharedConnectionLimit;
        target.* = try ResourceLedger.init(self.key, self.hop_count);
        target.resources = self.resources;
        target.sequence = self.sequence;
        const target_hop = self.hop_count - 1;
        for (0..self.hop_count) |hop| for (0..kind_count) |kind| {
            const owned_by_shell = hop == target_hop and (kind == @backingInt(ResourceKind.shell) or kind == @backingInt(ResourceKind.rtt_channel));
            if (owned_by_shell) {
                target.resources[hop][kind] = .{};
                continue;
            }
            if (self.resources[hop][kind].state == .owned or self.resources[hop][kind].state == .releasing) self.resources[hop][kind].state = .transferred;
        };
        self.redirects[index] = .{ .key = self.key, .ledger = target, .target_hop = target_hop };
        self.revision += 1;
    }
    pub fn forgetTransferred(self: *ResourceLedger, target: *ResourceLedger) void {
        self.lock();
        defer self.unlock();
        for (&self.redirects) |*entry| if (entry.*) |value| if (value.ledger == target) {
            entry.* = null;
        };
    }

    pub fn init(key: ?OperationKey, hop_count: usize) !ResourceLedger {
        if (hop_count == 0 or hop_count > max_hops) return error.InvalidJumpRoute;
        return .{ .key = key, .hop_count = hop_count };
    }

    pub fn accepts(self: *ResourceLedger, key: ?OperationKey, hop: usize, hop_count: usize) bool {
        self.lock();
        defer self.unlock();
        return std.meta.eql(self.key, key) and hop_count == self.hop_count and hop < self.hop_count;
    }

    fn lock(self: *ResourceLedger) void {
        while (self.lock_flag.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *ResourceLedger) void {
        self.lock_flag.store(false, .release);
    }

    pub fn record(self: *ResourceLedger, key: ?OperationKey, hop: usize, kind: ResourceKind, state: ResourceState) bool {
        self.lock();
        defer self.unlock();
        for (self.redirects) |entry| if (entry) |value| {
            const shell_owned = hop == value.target_hop and (kind == .shell or kind == .rtt_channel);
            if (std.meta.eql(value.key, key) and !shell_owned) return value.ledger.record(key, hop, kind, state);
        };
        if (!std.meta.eql(self.key, key) or hop >= self.hop_count or state == .absent) return false;
        const resource = &self.resources[hop][@backingInt(kind)];
        // Explicit, serial diagnostic requests reuse this one transient slot.
        // Native/transport owners still require beginAttempt before reacquire.
        const next_sample = kind == .rtt_channel and state == .owned and resource.state == .released;
        if (resource.state == state or (resource.state == .released and !next_sample)) return false;
        if (state == .owned and resource.state != .absent and !next_sample) return false;
        if (state != .owned and resource.state == .absent) return false;
        if (self.sequence == std.math.maxInt(u64) or self.revision == std.math.maxInt(u64)) {
            self.overflowed = true;
            return false;
        }
        self.sequence += 1;
        self.revision += 1;
        resource.state = state;
        if (state == .owned) resource.acquired_sequence = self.sequence;
        if (state == .released) resource.released_sequence = self.sequence;
        return true;
    }

    pub fn snapshot(self: *ResourceLedger) Snapshot {
        self.lock();
        defer self.unlock();
        return self.snapshotLocked();
    }

    fn snapshotLocked(self: *ResourceLedger) Snapshot {
        var retained_count: usize = @intFromBool(self.retained_route != null);
        for (self.retained_sessions) |pending| retained_count += @intFromBool(pending != null);
        return .{ .key = self.key, .hop_count = self.hop_count, .revision = self.revision, .resources = self.resources, .overflowed = self.overflowed, .retained_count = retained_count };
    }

    /// Reconnection may begin only after the complete previous native graph
    /// has a release receipt. This is transport bookkeeping, not a new owner ID.
    pub fn beginNextTransport(self: *ResourceLedger) !void {
        self.lock();
        defer self.unlock();
        const previous = self.snapshotLocked();
        if (!previous.released()) return error.CleanupNotReleased;
        if (self.revision == std.math.maxInt(u64)) return error.SequenceExhausted;
        self.previous_released = previous;
        self.resources = @splat(@splat(.{}));
        self.revision += 1;
    }

    /// Only the host-issued successor may acquire a new graph. The previous
    /// graph and its receipts remain attributable to their original key.
    pub fn beginAttempt(self: *ResourceLedger, expected: OperationKey, next: OperationKey) !void {
        self.lock();
        defer self.unlock();
        if (self.key == null or !self.key.?.eql(expected)) return error.StaleOperation;
        if (expected.owner != .session or next.owner != .session or
            expected.owner.session.session_id != next.owner.session.session_id or
            next.owner.session.generation != try identity.advance(expected.owner.session.generation) or
            expected.attempt_id == null or next.attempt_id != try identity.advance(expected.attempt_id.?) or
            expected.operation_id == next.operation_id) return error.InvalidOperation;
        const previous = self.snapshotLocked();
        if (!previous.released()) return error.CleanupNotReleased;
        if (self.revision == std.math.maxInt(u64)) return error.SequenceExhausted;
        self.previous_released = previous;
        self.key = next;
        self.resources = @splat(@splat(.{}));
        self.revision += 1;
    }

    pub fn previousReleased(self: *ResourceLedger) ?Snapshot {
        self.lock();
        defer self.unlock();
        return self.previous_released;
    }

    /// A failing connect cannot return its Session value. Preserve an unusual
    /// incomplete native free under the same bounded attempt owner instead.
    pub fn retainFailure(self: *ResourceLedger, session: *Session) bool {
        self.lock();
        defer self.unlock();
        if (!std.meta.eql(self.key, session.resource_key) or session.resource_hop >= self.hop_count or self.retained_sessions[session.resource_hop] != null) return false;
        if (self.retained_library == null) self.retained_library = Library.init() catch return false;
        self.retained_sessions[session.resource_hop] = session.*;
        session.* = .{ .state = .failed };
        return true;
    }

    pub fn retainRoute(self: *ResourceLedger, route: *JumpTransport.Route) bool {
        self.lock();
        defer self.unlock();
        if (self.retained_route) |retained| return retained == route;
        if (self.retained_library == null) self.retained_library = Library.init() catch return false;
        self.retained_route = route;
        return true;
    }

    /// Called by the connection/cleanup IO owner, never by a UI poll hook.
    /// Failed downstream Sessions settle before their retained upstream route.
    pub fn drainRetained(self: *ResourceLedger) ReleaseReceipt {
        if (self.draining.swap(true, .acq_rel)) return .awaiting;
        defer self.draining.store(false, .release);
        var index = self.hop_count;
        while (index != 0) {
            index -= 1;
            self.lock();
            var pending = self.retained_sessions[index];
            self.retained_sessions[index] = null;
            self.unlock();
            if (pending) |*session| {
                const receipt = session.closeReceipt();
                if (receipt != .released) {
                    self.lock();
                    self.retained_sessions[index] = session.*;
                    self.unlock();
                    return receipt;
                }
            }
        }
        self.lock();
        const route = self.retained_route;
        self.retained_route = null;
        self.unlock();
        if (route) |value| {
            const receipt = value.closeReceipt();
            if (receipt != .released) {
                self.lock();
                self.retained_route = value;
                self.unlock();
                return receipt;
            }
            value.deinit();
        }
        self.lock();
        const library = self.retained_library;
        self.retained_library = null;
        self.unlock();
        if (library) |lease| {
            var owned = lease;
            owned.deinit();
        }
        const remaining = self.snapshot();
        return if (remaining.released()) .released else if (remaining.hasUnknown()) .unknown else .awaiting;
    }
};

pub const Options = struct {
    host: [:0]const u8,
    port: u16 = 22,
    user: [:0]const u8,
    auth: Auth,
    /// Optional UI bridge used when auth is `.keyboard_interactive`.
    keyboard_prompt: ?KeyboardPrompt = null,
    auth_interaction: ?AuthInteraction = null,
    source_owner: ?identity.AssetOwner = null,
    strict_host_key_checking: bool = true,
    operation_key: ?OperationKey = null,
    resource_ledger: ?*ResourceLedger = null,
    connection_details: ?*ConnectionDetails.Store = null,
    details_source: ConnectionDetails.Source = .session,
    display_name: []const u8 = "",
    term: [:0]const u8 = "xterm-256color",
    connect_timeout_ms: u32 = 15_000,
    /// Borrowed for synchronous creation only. Shared by DNS/TCP/handshake/
    /// authentication/shell in this hop; human interaction extends it.
    network_deadline_ms: ?*c_longlong = null,
    keepalive_sec: u16 = 30,
    compression: bool = false,
    cols: u16 = 80,
    rows: u16 = 24,
    /// Tunnel hops authenticate without starting a remote login shell.
    open_shell: bool = true,
    /// Optional TOFU store. When omitted the negotiated fingerprint is still
    /// captured; unknown keys still require an explicit trust decision.
    host_key_store: ?*policy.HostKeyStore = null,
    host_key_decision: HostKeyDecision = .reject_unknown,
    host_key_observer: ?HostKeyObserver = null,
    /// Borrowed through the owned IO worker call. Network EAGAIN waits poll
    /// this flag; the UI never calls libssh2 or closes its descriptor.
    cancel_token: ?*const std.atomic.Value(bool) = null,
    /// Optional backend diagnostics; the callback must copy borrowed host data.
    progress_observer: ?ConnectionProgress.Observer = null,
    attempt_id: u64 = 0,
    hop_index: usize = 0,
    hop_count: usize = 1,

    pub fn recordResource(self: Options, kind: ResourceKind, state: ResourceState) void {
        if (self.resource_ledger) |ledger| _ = ledger.record(self.operation_key, self.hop_index, kind, state);
    }

    pub fn prepareDetails(self: Options) !void {
        const store = self.connection_details orelse return;
        const key = self.operation_key orelse return error.MissingOperation;
        try store.begin(key, self.hop_count, self.details_source);
        try store.configure(key, self.hop_index, .{
            .host = try ConnectionDetails.Text(1024).init(self.host),
            .user = try ConnectionDetails.Text(256).init(self.user),
            .name = try ConnectionDetails.Text(512).init(self.display_name),
            .port = self.port,
            .asset_owner = self.source_owner,
        });
    }

    pub fn report(self: Options, phase: ConnectionProgress.Phase, status: ConnectionProgress.Status, failure: ?anyerror) void {
        if (self.progress_observer) |observer| observer.callback(observer.context, .{
            .attempt = self.attempt_id,
            .timestamp_ns = @import("../../platform/realtime.zig").monotonicNs(),
            .hop = self.hop_index,
            .hop_count = self.hop_count,
            .host = self.host,
            .port = self.port,
            .phase = phase,
            .status = status,
            .failure = failure,
        });
    }
};

fn nativeDrive(options: Options, fd: c_int) c.ZW_SSH_DRIVE {
    return .{ .socket_fd = fd, .timeout_ms = options.connect_timeout_ms, .deadline_ms = options.network_deadline_ms, .cancelled = if (options.cancel_token != null) Session.connectCancelled else null, .ctx = if (options.cancel_token) |token| @constCast(token) else null };
}

fn checkDriveResult(result: c_int) !void {
    switch (result) {
        c.ZW_SSH_CANCELLED => return error.Cancelled,
        c.ZW_SSH_TIMED_OUT => return error.ConnectionTimedOut,
        c.ZW_SSH_WAIT_FAILED => return error.TransportWaitFailed,
        else => {},
    }
}

const HostKeyVerification = struct { acceptance: HostKeyAcceptance, checked: ?known_hosts.Verification };
fn verifyHostKey(options: Options, key: known_hosts.PublicKey, key_fingerprint: []const u8) !HostKeyVerification {
    const checked = if (options.host_key_store) |store| try store.check(options.host, options.port, key) else null;
    const status: HostKeyStatus = if (checked) |value| switch (value.result) {
        .trusted => .trusted,
        .changed => .changed,
        .unknown => .unknown,
    } else .unknown;
    if (status == .trusted) return .{ .acceptance = .known_match, .checked = checked };
    // Disabling strict accepts a confirmed mismatch only for this attempt.
    // It never changes the saved key and never skips first-contact consent.
    if (status == .changed and !options.strict_host_key_checking) return .{ .acceptance = .accepted_changed_for_attempt, .checked = checked };
    const decision = if (options.host_key_observer) |observer|
        observer.callback(observer.ctx, options.host, options.port, .{ .algorithm = key.algorithm, .fingerprint = key_fingerprint, .raw_key = key.raw, .status = status, .verification = checked, .store_path = if (options.host_key_store) |store| store.persist_path else null, .operation_key = options.operation_key, .hop_index = options.hop_index, .source_owner = options.source_owner })
    else
        options.host_key_decision;
    if (status == .changed) {
        if (decision != .trust_changed_yes) return error.HostKeyChanged;
        try options.host_key_store.?.replace(options.host, options.port, key, checked.?, "yes");
        return .{ .acceptance = .replaced, .checked = checked };
    }
    switch (decision) {
        .reject_unknown => return error.HostKeyConfirmationRequired,
        .trust_once => {
            if (options.host_key_store) |store| try store.trust(options.host, options.port, key, checked.?, .once);
            return .{ .acceptance = .unknown_once, .checked = checked };
        },
        .trust_save => {
            const store = options.host_key_store orelse return error.HostKeyStoreUnavailable;
            try store.trust(options.host, options.port, key, checked.?, .save);
            return .{ .acceptance = .unknown_saved, .checked = checked };
        },
        .trust_changed_yes => return error.HostKeyChanged,
    }
}

const NativeAuthBackend = struct {
    handle: *c.LIBSSH2_SESSION,
    socket_fd: c_int,
    user: [:0]const u8,
    drive: c.ZW_SSH_DRIVE,
    callback_error: ?anyerror = null,
    network_end_ms: c_longlong,

    fn resumeNetwork(self: *NativeAuthBackend) void {
        // AuthMachine may wait for a password/passphrase between native calls.
        // That user interaction has its own deadline, not the network budget.
        if (self.drive.deadline_ms) |deadline| deadline.* += c.zw_ssh_monotonic_ms() - self.network_end_ms;
    }

    pub fn query(self: *NativeAuthBackend) !auth_flow.Advertised {
        self.resumeNetwork();
        defer self.network_end_ms = c.zw_ssh_monotonic_ms();
        var methods: [1024]u8 = undefined;
        var length: usize = 0;
        const result = c.zw_libssh2_auth_methods_driven(self.handle, self.user.ptr, &methods, methods.len, &length, &self.drive);
        try checkDriveResult(result);
        return switch (result) {
            1 => .{ .authenticated = true, .methods = .init(.{}) },
            0 => .{ .methods = try auth_flow.parseMethods(methods[0..length]) },
            else => error.AuthenticationMethodsUnavailable,
        };
    }

    pub fn attempt(self: *NativeAuthBackend, auth: Auth, conversation: *auth_flow.Conversation) !auth_flow.Attempt {
        self.resumeNetwork();
        defer self.network_end_ms = c.zw_ssh_monotonic_ms();
        self.callback_error = null;
        const rc = switch (auth) {
            .password => |password| c.zw_libssh2_auth_password_driven(self.handle, self.user.ptr, password.ptr, &self.drive),
            .password_prompt => return error.AuthenticationInteractionRequired,
            .private_key => |key| c.zw_libssh2_auth_private_key_driven(self.handle, self.user.ptr, key.path.ptr, if (key.passphrase) |value| value.ptr else null, &self.drive),
            .agent => c.zw_libssh2_auth_agent_driven(self.handle, self.user.ptr, &self.drive),
            .keyboard_interactive => blk: {
                var callback: NativeConversation = .{ .backend = self, .conversation = conversation };
                break :blk c.zw_libssh2_auth_keyboard_interactive_batch_driven(self.handle, self.user.ptr, NativeConversation.respond, &callback, &self.drive);
            },
        };
        if (self.callback_error) |err| return err;
        try checkDriveResult(rc);
        if (rc == -1000) return error.InvalidChallengePrompt;
        var partial: c_int = 0;
        var methods: [1024]u8 = undefined;
        var length: usize = 0;
        const result = c.zw_libssh2_auth_result(self.handle, &partial, &methods, methods.len, &length);
        return switch (result) {
            2 => .{ .outcome = .success },
            1 => .{ .outcome = if (partial != 0) .partial else .failure, .remaining = try auth_flow.parseMethods(methods[0..length]) },
            0 => blk: {
                // Only a readable local key which failed before a server
                // response can enter the passphrase recovery challenge.
                // A server denial is never described as an unlock failure.
                const code = c.zw_libssh2_last_error_code(self.handle);
                const key_error = auth == .private_key and keyUnlockError(code);
                if (key_error and c.zw_ssh_private_key_readable(auth.private_key.path.ptr) == 0) return error.IdentityFileUnreadable;
                break :blk .{ .outcome = .failure, .key_unlock_failed = key_error };
            },
            else => error.InvalidAuthenticationResult,
        };
    }

    const NativeConversation = struct {
        backend: *NativeAuthBackend,
        conversation: *auth_flow.Conversation,

        fn respond(raw: ?*anyopaque, native_prompts: [*c]const c.ZW_SSH_AUTH_PROMPT, count: usize, answers: [*c]c.ZW_SSH_AUTH_RESPONSE) callconv(.c) c_int {
            const self: *NativeConversation = @ptrCast(@alignCast(raw orelse return -1));
            self.respondChecked(native_prompts, count, answers) catch |err| {
                self.backend.callback_error = err;
                // libssh2's callback cannot return an error. Shut down only
                // this owned transport so it cannot wait for another server
                // round after the scoped challenge has been cancelled.
                c.zw_ssh_socket_interrupt(self.backend.socket_fd);
                return -1;
            };
            return 0;
        }

        fn respondChecked(self: *NativeConversation, native_prompts: [*c]const c.ZW_SSH_AUTH_PROMPT, count: usize, answers: [*c]c.ZW_SSH_AUTH_RESPONSE) !void {
            const auth = @import("auth_challenge.zig");
            if (count == 0 or count > auth.max_prompts) return error.InvalidChallengePrompt;
            try self.conversation.checkCancelled();
            var prompts: [auth.max_prompts]auth.Prompt = undefined;
            for (0..count) |index| prompts[index] = .{
                .text = native_prompts[index].text[0..native_prompts[index].length],
                .echo = native_prompts[index].echo != 0,
                .kind = @import("auth_prompt.zig").classify(native_prompts[index].text[0..native_prompts[index].length], native_prompts[index].echo != 0),
            };
            if (self.conversation.config.interaction != null) {
                var response = try self.conversation.request(.keyboard_interactive, prompts[0..count]);
                defer response.deinit();
                for (0..count) |index| {
                    const value = response.answerAt(index);
                    if (value.len > answers[index].capacity) return error.InvalidChallengeResponse;
                    @memcpy(answers[index].text[0..value.len], value);
                    answers[index].length = value.len;
                }
            } else {
                // Compatibility only for callers which did not supply the
                // scoped interaction. App sessions always use the branch above.
                const legacy = self.conversation.config.legacy_keyboard orelse return error.AuthenticationInteractionRequired;
                for (0..count) |index| {
                    const buffer = answers[index].text[0..answers[index].capacity];
                    const value = legacy.callback(legacy.ctx, prompts[index].text, buffer) orelse return error.Cancelled;
                    if (value.len == 0 or value.len > buffer.len) return error.InvalidChallengeResponse;
                    @memmove(buffer[0..value.len], value);
                    answers[index].length = value.len;
                }
            }
        }
    };
};

fn keyUnlockError(code: c_int) bool {
    // PUBLICKEY_UNVERIFIED (-19) also means a transport/server failure;
    // only local key-file/unlock errors justify a passphrase challenge.
    return code == -16 or code == -48;
}

/// Process-level libssh2 owner. It must outlive every Session created from it.
///
/// libssh2's process init/exit pair is global rather than session scoped. Each
/// successful `init` owns one active token; native init runs only for the first
/// owner and native exit only after the final token is released. The lock also
/// prevents an init racing the last deinit from observing a half-torn-down
/// native library.
const LibraryGuard = struct {
    mutex: SpinMutex = .{},
    owners: u32 = 0,
};

const SpinMutex = struct {
    state: std.atomic.Value(bool) = .init(false),
    fn lock(self: *SpinMutex) void {
        while (self.state.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *SpinMutex) void {
        self.state.store(false, .release);
    }
};

var library_guard: LibraryGuard = .{};

pub const Library = struct {
    /// Token state is deliberately mutable and deinit is idempotent.
    active: bool,
    pub fn init() !Library {
        library_guard.mutex.lock();
        defer library_guard.mutex.unlock();
        if (library_guard.owners == 0) {
            if (c.zw_libssh2_library_init() != 0) return error.LibraryInitFailed;
        }
        library_guard.owners += 1;
        return .{ .active = true };
    }
    pub fn deinit(self: *Library) void {
        if (!self.active) return;
        library_guard.mutex.lock();
        defer library_guard.mutex.unlock();
        // Consume this token while holding the same guard used by init.
        self.active = false;
        if (library_guard.owners == 0) return;
        library_guard.owners -= 1;
        if (library_guard.owners == 0) c.zw_libssh2_library_exit();
    }

    /// Test/diagnostic visibility without exposing mutable guard state.
    pub fn activeOwners() u32 {
        library_guard.mutex.lock();
        defer library_guard.mutex.unlock();
        return library_guard.owners;
    }
};

pub const SftpCloseResult = struct { receipt: ReleaseReceipt, consumed: bool };
pub const SftpKind = enum { file, directory, symlink, other, unknown };
pub const SftpAttributes = struct {
    kind: SftpKind = .unknown,
    size: ?u64 = null,
    modified_at: ?u64 = null,
    permissions: ?u32 = null,

    fn fromNative(raw: c.ZW_SFTP_ATTRIBUTES) SftpAttributes {
        const mode: u32 = @truncate(raw.permissions);
        return .{
            .kind = if (raw.flags & 4 == 0) .unknown else switch (mode & 0o170000) {
                0o100000 => .file,
                0o040000 => .directory,
                0o120000 => .symlink,
                else => .other,
            },
            .size = if (raw.flags & 1 != 0) raw.size else null,
            .modified_at = if (raw.flags & 8 != 0) raw.mtime else null,
            .permissions = if (raw.flags & 4 != 0) mode else null,
        };
    }
};

pub const SftpHandle = struct {
    handle: *c.LIBSSH2_SFTP_HANDLE,
    consumed: ?ReleaseReceipt = null,

    pub fn read(self: *SftpHandle, bytes: []u8) !usize {
        if (self.consumed != null) return error.SftpHandleClosed;
        const count = c.zw_libssh2_sftp_read(self.handle, bytes.ptr, bytes.len);
        if (count < 0) return error.SftpReadFailed;
        return @intCast(count);
    }

    pub fn write(self: *SftpHandle, bytes: []const u8) !usize {
        if (self.consumed != null) return error.SftpHandleClosed;
        const count = c.zw_libssh2_sftp_write(self.handle, bytes.ptr, bytes.len);
        if (count < 0) return error.SftpWriteFailed;
        return @intCast(count);
    }

    /// Vendored sftp_close_handle consumes the allocation on every result
    /// except EAGAIN. Unknown remote close is not permission to close it twice.
    pub fn closeReceipt(self: *SftpHandle) SftpCloseResult {
        if (self.consumed) |receipt| return .{ .receipt = receipt, .consumed = true };
        const rc = c.zw_libssh2_sftp_close(self.handle);
        if (rc == -37) return .{ .receipt = .awaiting, .consumed = false };
        const receipt: ReleaseReceipt = if (rc == 0) .released else .unknown;
        self.consumed = receipt;
        return .{ .receipt = receipt, .consumed = true };
    }

    pub fn close(self: *SftpHandle) !void {
        if (self.closeReceipt().receipt != .released) return error.SftpCloseFailed;
    }
};

/// All methods are single nonblocking steps, used by one owned IO worker.
pub const SftpReadonlyHandle = struct {
    file: SftpHandle,
    session: *Session,

    pub fn read(self: *SftpReadonlyHandle, bytes: []u8) !usize {
        if (self.file.consumed != null) return error.SftpHandleClosed;
        const rc = c.zw_libssh2_sftp_read(self.file.handle, bytes.ptr, bytes.len);
        if (rc < 0) return self.session.sftpReadonlyError(rc);
        return @intCast(rc);
    }
    pub fn stat(self: *SftpReadonlyHandle) !SftpAttributes {
        if (self.file.consumed != null) return error.SftpHandleClosed;
        var raw: c.ZW_SFTP_ATTRIBUTES = undefined;
        const rc = c.zw_libssh2_sftp_fstat_attributes(self.file.handle, &raw);
        if (rc != 0) return self.session.sftpReadonlyError(rc);
        return SftpAttributes.fromNative(raw);
    }
    pub fn readDirectory(self: *SftpReadonlyHandle, name: []u8) !?struct { name: []const u8, attributes: SftpAttributes } {
        if (self.file.consumed != null) return error.SftpHandleClosed;
        var raw: c.ZW_SFTP_ATTRIBUTES = undefined;
        const rc = c.zw_libssh2_sftp_readdir(self.file.handle, name.ptr, name.len, &raw);
        if (rc < 0) return self.session.sftpReadonlyError(rc);
        if (rc == 0) return null;
        if (rc >= name.len) return error.PathLimit;
        return .{ .name = name[0..@intCast(rc)], .attributes = SftpAttributes.fromNative(raw) };
    }
    pub fn closeReceipt(self: *SftpReadonlyHandle) SftpCloseResult {
        return self.file.closeReceipt();
    }
};

/// Owns one TCP socket, one libssh2 session, and one interactive PTY channel.
pub const Session = struct {
    pub const OpenTicket = struct {
        kind: enum { exec, rtt, sftp, forward, legacy_exec, shell },
        owner: usize = 0,
        id: u64,
    };
    const RttOperation = struct {
        request: ConnectionDetails.Request,
        sample: ConnectionDetails.Sample,
        queued_ns: i128,
        channel: ?Channel = null,
        acquired: bool = false,
        phase: enum { waiting, opening, closing } = .waiting,
    };
    state: State = .idle,
    socket_fd: c_int = -1,
    handle: ?*c.LIBSSH2_SESSION = null,
    channel: ?Channel = null,
    sftp: ?*c.LIBSSH2_SFTP = null,
    host_key_algorithm: [64]u8 = undefined,
    host_key_algorithm_len: u8 = 0,
    host_key_fingerprint: [128]u8 = undefined,
    host_key_fingerprint_len: u8 = 0,
    host_key_raw: []u8 = &.{},
    host_key_store_path: ?[]u8 = null,
    host_key_verification: ?known_hosts.Verification = null,
    host_key_acceptance: HostKeyAcceptance = .unverified,
    accepted_auth_methods: auth_flow.Methods = .init(.{}),
    /// Immutable transport facts, retained independently of any tab's details store.
    negotiated_metadata: ConnectionDetails.Metadata = .{},
    resource_ledger: ?*ResourceLedger = null,
    resource_key: ?OperationKey = null,
    resource_hop: usize = 0,
    source_owner: ?identity.AssetOwner = null,
    connection_details: ?*ConnectionDetails.Store = null,
    channel_open: ?OpenTicket = null,
    shared_gate: ?*Session = null,
    borrowed_transport: bool = false,
    direct_opens: ?*c.ZW_SSH_DIRECT_OPEN = null,
    rtt: ?RttOperation = null,
    rtt_io_owner: ?std.Thread.Id = null,
    /// After an ambiguous close(2), never close this numeric fd again: another
    /// thread may already have received the recycled descriptor.
    socket_release_unknown: bool = false,

    pub fn recordResource(self: *Session, kind: ResourceKind, state: ResourceState) void {
        if (self.resource_ledger) |ledger| _ = ledger.record(self.resource_key, self.resource_hop, kind, state);
    }

    pub fn hostKey(self: *const Session) ?HostKeyInfo {
        if (self.host_key_algorithm_len == 0 or self.host_key_fingerprint_len == 0) return null;
        return .{
            .algorithm = self.host_key_algorithm[0..self.host_key_algorithm_len],
            .fingerprint = self.host_key_fingerprint[0..self.host_key_fingerprint_len],
            .raw_key = self.host_key_raw,
            .status = if (self.host_key_verification) |checked| switch (checked.result) {
                .trusted => .trusted,
                .unknown => .unknown,
                .changed => .changed,
            } else .unknown,
            .verification = self.host_key_verification,
            .store_path = self.host_key_store_path,
            .acceptance = self.host_key_acceptance,
            .operation_key = self.resource_key,
            .hop_index = self.resource_hop,
            .source_owner = self.source_owner,
        };
    }

    /// These gates are used only on the transport's one native IO owner.
    /// An EAGAIN open retains its ticket, including a cancelled RTT request.
    pub fn claimChannelOpen(self: *Session, ticket: OpenTicket) bool {
        if (self.shared_gate) |gate| {
            var scoped = ticket;
            scoped.owner = @intFromPtr(self);
            return gate.claimChannelOpen(scoped);
        }
        if (self.channel_open) |current| return std.meta.eql(current, ticket);
        // A forward batch can finish one open and start the next before the
        // worker calls stepRtt again. Reserve the next free turn for an already
        // waiting sample, while allowing the current native open to settle.
        if (self.rtt) |sample| if (sample.phase == .waiting) {
            if (!std.meta.eql(ticket, OpenTicket{ .kind = .rtt, .id = sample.request.id })) return false;
        };
        self.channel_open = ticket;
        return true;
    }
    pub fn finishChannelOpen(self: *Session, ticket: OpenTicket) void {
        if (self.shared_gate) |gate| {
            var scoped = ticket;
            scoped.owner = @intFromPtr(self);
            gate.finishChannelOpen(scoped);
            return;
        }
        if (self.channel_open) |current| if (std.meta.eql(current, ticket)) {
            self.channel_open = null;
        };
    }
    fn publishNegotiated(self: *Session) void {
        var metadata: ConnectionDetails.Metadata = .{ .accepted_auth_methods = self.accepted_auth_methods };
        metadata.fingerprint = ConnectionDetails.Text(128).init(self.host_key_fingerprint[0..self.host_key_fingerprint_len]) catch .{};
        if (c.zw_libssh2_session_hostkey_method(self.handle.?)) |value| metadata.host_key_algorithm = ConnectionDetails.Text(64).init(std.mem.span(value)) catch .{};
        if (c.zw_libssh2_session_cipher_cs(self.handle.?)) |value| metadata.cipher_c2s = ConnectionDetails.Text(64).init(std.mem.span(value)) catch .{};
        if (c.zw_libssh2_session_cipher_sc(self.handle.?)) |value| metadata.cipher_s2c = ConnectionDetails.Text(64).init(std.mem.span(value)) catch .{};
        self.negotiated_metadata = metadata;
        const store = self.connection_details orelse return;
        const key = self.resource_key orelse return;
        store.negotiated(key, self.resource_hop, metadata);
    }
    fn publishRtt(self: *Session, finished: bool) void {
        const value = self.rtt orelse return;
        std.log.debug("[ssh-rtt] publish phase={s} status={s} reason={any} cleanup={s}", .{ @tagName(value.phase), @tagName(value.sample.status), value.sample.reason, @tagName(value.sample.cleanup) });
        if (self.connection_details) |store| if (self.resource_key) |key| store.publish(key, self.resource_hop, value.sample, finished);
    }
    fn completeRtt(self: *Session) void {
        const value = self.rtt orelse return;
        std.log.debug("[ssh-rtt] request={d} phase={s} status={s} reason={any}", .{ value.request.id, @tagName(value.phase), @tagName(value.sample.status), value.sample.reason });
        self.finishChannelOpen(.{ .kind = .rtt, .id = value.request.id });
        self.publishRtt(true);
        self.rtt = null;
    }

    /// Opens no PTY, shell, subsystem or exec request. A refused/slow sample is
    /// diagnostic only: it never tears down this Session or its other channels.
    pub fn stepRtt(self: *Session, now_ns: i128) !void {
        if ((self.state != .active and !(self.borrowed_transport and self.state == .closing and self.rtt != null)) or self.handle == null) return;
        const store = self.connection_details orelse return;
        const key = self.resource_key orelse return;
        const current_thread = std.Thread.getCurrentId();
        if (self.rtt_io_owner) |owner| {
            if (owner != current_thread) return error.WrongIoOwner;
        } else self.rtt_io_owner = current_thread;
        if (self.rtt == null) {
            const request = store.take(key, self.resource_hop) orelse return;
            self.rtt = .{ .request = request, .sample = .{ .request_id = request.id }, .queued_ns = now_ns };
        }
        const value = &self.rtt.?;
        const previous = value.sample;
        if (store.cancelled(key, self.resource_hop, value.request.id)) {
            value.sample.status = .unavailable;
            value.sample.reason = .cancelled;
        }
        if (value.phase == .waiting) {
            // No native resource exists yet: expire the queued request without
            // releasing or interrupting another operation's channel-open slot.
            if (value.sample.reason == null and @max(0, now_ns - value.queued_ns) >= @as(i128, value.request.timeout_ms) * std.time.ns_per_ms) {
                value.sample.status = .unavailable;
                value.sample.reason = .timed_out;
            }
            if (value.sample.reason != null) {
                self.completeRtt();
                return;
            }
            if (!self.claimChannelOpen(.{ .kind = .rtt, .id = value.request.id })) return;
            value.phase = .opening;
            value.sample.started_ns = @import("../../platform/realtime.zig").monotonicNs();
            value.sample.cleanup = .releasing;
        }
        const elapsed = @max(0, now_ns - value.queued_ns);
        if (elapsed >= @as(i128, value.request.timeout_ms) * std.time.ns_per_ms) {
            // The RTT ends at OPEN_CONFIRMATION. A delayed CLOSE reply keeps
            // ownership unresolved, but cannot invalidate a measured result.
            if (value.phase == .opening) {
                if (value.sample.reason == null) value.sample.reason = .timed_out;
                value.sample.status = .unavailable;
            }
            if (value.acquired and value.sample.cleanup != .unknown) self.recordResource(.rtt_channel, .unknown);
            value.sample.cleanup = .unknown;
        }
        if (value.phase == .opening) {
            var raw: ?*c.LIBSSH2_CHANNEL = null;
            const result = c.zw_libssh2_session_channel_open_step(self.handle.?, &raw);
            if (result >= 0 and !value.acquired) {
                value.acquired = true;
                self.recordResource(.rtt_channel, .owned);
            }
            if (result == 1) {
                if (!std.meta.eql(previous, value.sample)) self.publishRtt(false);
                return;
            }
            if (result < 0) {
                value.sample.status = .unavailable;
                if (value.sample.reason == null) value.sample.reason = if (result == -21 or result == -22) .rejected else .native_failure;
                value.sample.cleanup = .released;
                if (value.acquired) self.recordResource(.rtt_channel, .released);
                self.completeRtt();
                return;
            }
            value.channel = .{ .handle = @ptrCast(raw.?) };
            const completed = @import("../../platform/realtime.zig").monotonicNs();
            value.sample.completed_ns = completed;
            if (value.sample.reason == null) {
                value.sample.duration_ms = @intCast(@divTrunc(@max(0, completed - value.sample.started_ns.?), std.time.ns_per_ms));
                value.sample.status = .ready;
            }
            value.phase = .closing;
        }
        const receipt = self.closeChannelReceipt(&value.channel.?);
        value.sample.cleanup = switch (receipt) {
            .released => .released,
            .awaiting => if (value.sample.cleanup == .unknown) .unknown else .releasing,
            .unknown => .unknown,
        };
        self.recordResource(.rtt_channel, switch (value.sample.cleanup) {
            .released => .released,
            .releasing => .releasing,
            .unknown => .unknown,
        });
        if (receipt == .released) {
            value.channel = null;
            self.completeRtt();
        } else if (!std.meta.eql(previous, value.sample)) self.publishRtt(false);
    }

    /// Explicit test-only-purpose orchestration on the existing IO owner.
    /// Ordinary probes do not call this. The caller retains normal Session
    /// teardown, including any request which timed out before native cleanup.
    pub fn measureRtt(self: *Session, timeout_ms: u32, cancelled: ?*const std.atomic.Value(bool)) !void {
        const store = self.connection_details orelse return error.DetailsUnavailable;
        const key = self.resource_key orelse return error.MissingOperation;
        const request = try store.request(key, self.resource_hop, timeout_ms);
        try self.driveRtt(request, false, cancelled);
    }
    pub fn driveRtt(self: *Session, request: u64, whole_route: bool, cancelled: ?*const std.atomic.Value(bool)) !void {
        const store = self.connection_details orelse return error.DetailsUnavailable;
        const key = self.resource_key orelse return error.MissingOperation;
        while (true) {
            if (cancelled) |token| if (token.load(.acquire)) {
                store.cancel(key, request) catch {};
                return error.Cancelled;
            };
            try self.stepRtt(@import("../../platform/realtime.zig").monotonicNs());
            const snapshot = store.snapshot(key) catch |err| switch (err) {
                error.WorkerBusy => continue,
                else => return err,
            };
            var pending = false;
            const first = if (whole_route) 0 else self.resource_hop;
            const end = if (whole_route) snapshot.hop_count else first + 1;
            for (snapshot.hops[first..end]) |hop| {
                const sample = hop.rtt_sample orelse return error.StaleSample;
                if (sample.request_id != request) return error.StaleSample;
                if (sample.status == .pending or sample.cleanup == .releasing) pending = true;
            }
            if (!pending) return;
            c.zw_ssh_relay_pause();
        }
    }

    pub fn connect(library: *const Library, supplied: Options) !Session {
        var deadline = c.zw_ssh_monotonic_ms() + @as(c_longlong, if (supplied.connect_timeout_ms == 0) 8000 else supplied.connect_timeout_ms);
        var options = supplied;
        options.network_deadline_ms = supplied.network_deadline_ms orelse &deadline;
        try options.prepareDetails();
        options.report(.transport, .started, null);
        if (options.resource_ledger) |ledger| {
            if (!ledger.accepts(options.operation_key, options.hop_index, options.hop_count)) return error.InvalidResourceOwner;
        }
        if (!library.active) {
            options.report(.transport, .failed, error.LibraryNotInitialized);
            return error.LibraryNotInitialized;
        }
        if (options.cancel_token) |token| if (token.load(.acquire)) {
            options.report(.transport, .cancelled, error.Cancelled);
            return error.Cancelled;
        };
        if (options.connection_details) |store| store.status(options.operation_key.?, options.hop_index, .negotiating);
        const remaining = options.network_deadline_ms.?.* - c.zw_ssh_monotonic_ms();
        if (remaining <= 0) {
            options.report(.transport, .failed, error.ConnectionTimedOut);
            return error.ConnectionTimedOut;
        }
        const fd = c.zw_ssh_socket_connect_cancellable(options.host.ptr, options.port, @intCast(@min(remaining, std.math.maxInt(u32))), if (options.cancel_token != null) connectCancelled else null, if (options.cancel_token) |token| @constCast(token) else null);
        if (fd < 0) {
            if (options.connection_details) |store| store.status(options.operation_key.?, options.hop_index, .released);
            if (options.cancel_token) |token| if (token.load(.acquire)) {
                options.report(.transport, .cancelled, error.Cancelled);
                return error.Cancelled;
            };
            const socket_error = c.zw_ssh_socket_last_error();
            const gai_error = c.zw_ssh_socket_last_gai_error();
            const failure = if (gai_error != 0) error.HostResolutionFailed else if (socket_error == @backingInt(std.c.E.TIMEDOUT)) error.ConnectionTimedOut else if (socket_error == @backingInt(std.c.E.CONNREFUSED)) error.ConnectionRefused else error.ConnectFailed;
            @import("../../platform/applog.zig").err(.ssh, "socket connect failed host={s}:{d} errno={d} gai={d}", .{ options.host, options.port, socket_error, gai_error });
            options.report(.transport, .failed, failure);
            return failure;
        }
        options.report(.transport, .succeeded, null);
        return connectOverFd(library, options, fd);
    }

    fn connectCancelled(raw: ?*anyopaque) callconv(.c) c_int {
        const token: *const std.atomic.Value(bool) = @ptrCast(@alignCast(raw orelse return 0));
        return @intFromBool(token.load(.acquire));
    }

    /// Consumes an already connected socket even on failure. A ProxyJump
    /// supervisor supplies a socketpair endpoint backed by its channel relay.
    /// Host-key verification still uses the requested target host and port.
    pub fn connectOverFd(library: *const Library, supplied: Options, fd: c_int) !Session {
        var deadline = c.zw_ssh_monotonic_ms() + @as(c_longlong, if (supplied.connect_timeout_ms == 0) 8000 else supplied.connect_timeout_ms);
        var options = supplied;
        options.network_deadline_ms = supplied.network_deadline_ms orelse &deadline;
        var phase: ConnectionProgress.Phase = .handshake;
        options.report(phase, .started, null);
        return connectOverFdWithPhase(library, options, fd, &phase) catch |err| {
            options.report(phase, if (err == error.Cancelled) .cancelled else .failed, err);
            return err;
        };
    }

    fn connectOverFdWithPhase(library: *const Library, options: Options, fd: c_int, phase: *ConnectionProgress.Phase) !Session {
        if (fd < 0) return error.InvalidTransport;
        var self: Session = .{ .state = .connecting, .resource_ledger = options.resource_ledger, .resource_key = options.operation_key, .resource_hop = options.hop_index, .source_owner = options.source_owner, .connection_details = options.connection_details };
        self.socket_fd = fd;
        self.recordResource(.transport, .owned);
        errdefer self.failAndRelease();
        try options.prepareDetails();
        if (options.connection_details) |store| store.status(options.operation_key.?, options.hop_index, .negotiating);
        if (options.resource_ledger) |ledger| {
            if (!ledger.accepts(options.operation_key, options.hop_index, options.hop_count)) return error.InvalidResourceOwner;
        }
        if (!library.active) return error.LibraryNotInitialized;
        if (options.cancel_token) |token| if (token.load(.acquire)) return error.Cancelled;
        self.handle = c.zw_libssh2_session_create() orelse return error.SessionCreateFailed;
        self.recordResource(.session, .owned);
        // Legacy dedicated-use APIs still honor the native timeout. Creation
        // itself stays nonblocking and is driven only by this owned IO worker.
        c.zw_libssh2_session_set_timeout(self.handle.?, @intCast(options.connect_timeout_ms));
        // Compression is a handshake method preference and must be set before
        // negotiation; the shim retains the server fallback ordering.
        if (c.zw_libssh2_session_set_compression(self.handle.?, if (options.compression) 1 else 0) != 0)
            return error.CompressionConfigurationFailed;
        // Keep the backend's supported fallback algorithms while preferring CTR.
        const cipher_rc = c.zw_libssh2_session_prefer_stream_ciphers(self.handle.?);
        if (cipher_rc != 0) {
            @import("../../platform/applog.zig").err(.ssh, "cipher preferences failed rc={d}", .{cipher_rc});
            return error.CipherConfigurationFailed;
        }
        try self.enterIoMode();
        const drive = nativeDrive(options, self.socket_fd);
        const handshake_rc = c.zw_libssh2_session_handshake_driven(self.handle.?, &drive);
        if (handshake_rc != 0) {
            const diagnostic = @import("handshake_failure.zig");
            const native_code = c.zw_libssh2_last_error_code(self.handle.?);
            const native_message = c.zw_libssh2_last_error(self.handle.?);
            var message_buffer: [1024]u8 = undefined;
            const message = if (native_message != null) std.mem.span(native_message) else "";
            @import("../../platform/applog.zig").err(.ssh, "handshake failed host={s}:{d} hop={d} rc={d} libssh2_code={d} fd={d} message={s}", .{
                options.host,                                                                                    options.port, options.hop_index, handshake_rc, native_code, self.socket_fd,
                diagnostic.logMessage(&message_buffer, if (message.len > 0) message else "(no libssh2 detail)"),
            });
            try checkDriveResult(handshake_rc);
            return diagnostic.fromCode(handshake_rc);
        }
        if (options.cancel_token) |token| if (token.load(.acquire)) return error.Cancelled;
        options.report(phase.*, .succeeded, null);
        phase.* = .host_key;
        options.report(phase.*, .started, null);
        // Host-key material is available only after the SSH handshake. Capture
        // it before authentication so the UI can make a real TOFU decision.
        var raw_key_length: usize = 0;
        const raw_key = c.zw_libssh2_session_hostkey_raw(self.handle.?, &raw_key_length);
        if (raw_key == null or raw_key_length == 0 or raw_key_length > 64 * 1024) return error.HostKeyUnavailable;
        self.host_key_raw = try std.heap.c_allocator.dupe(u8, raw_key[0..raw_key_length]);
        const server_key = try known_hosts.PublicKey.fromRaw(self.host_key_raw);
        if (server_key.algorithm.len > self.host_key_algorithm.len) return error.HostKeyUnavailable;
        @memcpy(self.host_key_algorithm[0..server_key.algorithm.len], server_key.algorithm);
        self.host_key_algorithm_len = @intCast(server_key.algorithm.len);
        const key_fingerprint = known_hosts.fingerprint(server_key);
        @memcpy(self.host_key_fingerprint[0..key_fingerprint.bytes.len], &key_fingerprint.bytes);
        self.host_key_fingerprint_len = key_fingerprint.bytes.len;
        if (options.host_key_store) |store| {
            if (store.persist_path) |path| self.host_key_store_path = try std.heap.c_allocator.dupe(u8, path);
        }
        const verification = blk: {
            const start = c.zw_ssh_monotonic_ms();
            defer options.network_deadline_ms.?.* += c.zw_ssh_monotonic_ms() - start;
            break :blk try verifyHostKey(options, server_key, key_fingerprint.slice());
        };
        self.host_key_verification = verification.checked;
        self.host_key_acceptance = verification.acceptance;
        if (options.cancel_token) |token| if (token.load(.acquire)) return error.Cancelled;
        options.report(phase.*, .succeeded, null);
        phase.* = .authentication;
        options.report(phase.*, .started, null);
        if (c.zw_libssh2_session_cipher_sc(self.handle.?)) |cipher_name| {
            std.log.info("[ssh] negotiated cipher: {s}", .{std.mem.span(cipher_name)});
        }
        const signature_rc = c.zw_libssh2_session_prefer_rsa_sha2(self.handle.?);
        if (signature_rc != 0) @import("../../platform/applog.zig").warn(.ssh, "RSA signature preference unavailable rc={d}; retaining native defaults", .{signature_rc});
        var backend: NativeAuthBackend = .{ .handle = self.handle.?, .socket_fd = self.socket_fd, .user = options.user, .drive = drive, .network_end_ms = c.zw_ssh_monotonic_ms() };
        const authenticated = try auth_flow.authenticate(.{
            .endpoint = .{ .host = options.host, .port = options.port, .user = options.user },
            .auth = options.auth,
            .source_owner = options.source_owner,
            .operation_key = options.operation_key,
            .hop_index = options.hop_index,
            .interaction = options.auth_interaction,
            .legacy_keyboard = options.keyboard_prompt,
            .cancel_token = options.cancel_token,
        }, &backend);
        self.accepted_auth_methods = authenticated.accepted_methods;
        self.publishNegotiated();
        options.report(phase.*, .succeeded, null);
        if (options.cancel_token) |token| if (token.load(.acquire)) return error.Cancelled;
        // libssh2 may emit a global keepalive while waiting for KEX packets.
        // Sending that request before encryption negotiation is invalid for
        // some sshd versions and resets the connection. Configure it only
        // after authentication has completed, when the transport is active.
        c.zw_libssh2_session_config_keepalive(self.handle.?, options.keepalive_sec);
        self.state = .authenticated;
        if (options.open_shell) {
            phase.* = .shell;
            options.report(phase.*, .started, null);
            var raw_channel: ?*c.LIBSSH2_CHANNEL = null;
            const shell_rc = c.zw_libssh2_open_shell_driven(self.handle.?, options.term.ptr, options.cols, options.rows, &raw_channel, &drive);
            try checkDriveResult(shell_rc);
            if (shell_rc != 0) return error.OpenShellFailed;
            self.channel = .{ .handle = @ptrCast(raw_channel orelse return error.OpenShellFailed) };
            self.recordResource(.shell, .owned);
            options.report(phase.*, .succeeded, null);
        }
        if (options.cancel_token) |token| if (token.load(.acquire)) return error.Cancelled;
        self.state = .active;
        options.report(.ready, .succeeded, null);
        return self;
    }

    /// Direct TCP and relay-backed descriptors share this native/libssh2 mode.
    /// Both flags are required before the first resumable network operation.
    fn enterIoMode(self: *Session) !void {
        if (c.zw_ssh_socket_set_nonblocking(self.socket_fd) != 0) return error.TransportSetupFailed;
        c.zw_libssh2_session_nonblocking(self.handle.?);
    }

    /// 专用用途（SFTP 传输/SOCKS5 隧道）切回阻塞模式：PTY 泵不存在时，
    /// 同步语义让 libssh2 内部消化 EAGAIN，避免 sftp_open 因非阻塞返回 null。
    pub fn setBlocking(self: *Session) void {
        c.zw_libssh2_session_set_blocking(self.handle.?);
    }

    pub fn sftpInit(self: *Session) !void {
        if (self.state != .active) return error.SessionNotActive;
        if (self.sftp != null) return;
        const ticket: OpenTicket = .{ .kind = .sftp, .id = 0 };
        if (!self.claimChannelOpen(ticket)) return error.ChannelOpenBusy;
        self.sftp = c.zw_libssh2_sftp_init(self.handle.?);
        if (self.sftp != null or c.zw_libssh2_session_last_error(self.handle.?) != -37) self.finishChannelOpen(ticket);
        if (self.sftp == null) return error.SftpInitFailed;
    }

    pub fn sftpOpenWrite(self: *Session, path: [:0]const u8) !SftpHandle {
        if (self.state != .active) return error.SessionNotActive;
        try self.sftpInit();
        const handle = c.zw_libssh2_sftp_open_write(self.sftp.?, path.ptr) orelse return error.SftpOpenFailed;
        return .{ .handle = handle };
    }

    /// Fresh transfer destination. EXCL is enforced by the server, not by an
    /// earlier stat; an existing or raced destination is never truncated.
    pub fn sftpOpenExclusive(self: *Session, path: [:0]const u8) !SftpHandle {
        if (self.state != .active) return error.SessionNotActive;
        try self.sftpInit();
        const raw = c.zw_libssh2_sftp_open_exclusive(self.sftp.?, path.ptr) orelse
            return self.sftpReadonlyError(c.zw_libssh2_session_last_error(self.handle.?));
        return .{ .handle = raw };
    }

    /// The caller has verified this exact open handle against the separately
    /// approved target version. No path reopen or implicit CREAT is performed.
    pub fn sftpTruncate(self: *Session, handle: *SftpHandle, size: u64) !void {
        if (self.state != .active or self.sftp == null) return error.SessionNotActive;
        if (handle.consumed != null) return error.SftpHandleClosed;
        const rc = c.zw_libssh2_sftp_truncate(handle.handle, size);
        if (rc != 0) return self.sftpReadonlyError(rc);
    }

    /// Opens only an existing destination without truncation, including offset zero.
    pub fn sftpOpenAppend(self: *Session, path: [:0]const u8, offset: u64) !SftpHandle {
        if (self.state != .active) return error.SessionNotActive;
        try self.sftpInit();
        const handle = c.zw_libssh2_sftp_open_append(self.sftp.?, path.ptr, offset) orelse return error.SftpOpenFailed;
        return .{ .handle = handle };
    }

    pub fn sftpOpenRead(self: *Session, path: [:0]const u8) !SftpHandle {
        if (self.state != .active) return error.SessionNotActive;
        try self.sftpInit();
        const handle = c.zw_libssh2_sftp_open_read(self.sftp.?, path.ptr) orelse return error.SftpOpenFailed;
        return .{ .handle = handle };
    }

    pub fn sftpSize(self: *Session, path: [:0]const u8) !u64 {
        if (self.state != .active) return error.SessionNotActive;
        try self.sftpInit();
        const size = c.zw_libssh2_sftp_size(self.sftp.?, path.ptr);
        if (size < 0) return error.SftpStatFailed;
        return @intCast(size);
    }

    pub fn sftpReadonlyInit(self: *Session) !void {
        self.sftpInit() catch |err| {
            if (err == error.SftpInitFailed) return switch (c.zw_libssh2_session_last_error(self.handle.?)) {
                -37 => error.WouldBlock,
                -21, -22 => error.SftpSubsystemDenied,
                else => error.SftpIoFailed,
            };
            return err;
        };
    }

    pub fn sftpRealpath(self: *Session, path: [:0]const u8, output: []u8) ![]const u8 {
        if (self.state != .active or self.sftp == null) return error.SessionNotActive;
        const rc = c.zw_libssh2_sftp_realpath(self.sftp.?, path.ptr, output.ptr, output.len);
        if (rc < 0) return self.sftpReadonlyError(rc);
        if (rc == 0 or rc >= output.len) return error.PathLimit;
        return output[0..@intCast(rc)];
    }

    /// lstat by default: listing/stat never follows a symlink implicitly.
    pub fn sftpStat(self: *Session, path: [:0]const u8, follow: bool) !SftpAttributes {
        if (self.state != .active or self.sftp == null) return error.SessionNotActive;
        var raw: c.ZW_SFTP_ATTRIBUTES = undefined;
        const rc = c.zw_libssh2_sftp_stat_attributes(self.sftp.?, path.ptr, @intFromBool(follow), &raw);
        if (rc != 0) return self.sftpReadonlyError(rc);
        return SftpAttributes.fromNative(raw);
    }

    /// One nonblocking MKDIR step, driven only by the owning directory worker.
    pub fn sftpMkdir(self: *Session, path: [:0]const u8) !void {
        if (self.state != .active or self.sftp == null) return error.SessionNotActive;
        const rc = c.zw_libssh2_sftp_mkdir(self.sftp.?, path.ptr);
        if (rc != 0) return self.sftpReadonlyError(rc);
    }

    pub fn sftpOpenReadonly(self: *Session, path: [:0]const u8, directory: bool) !SftpReadonlyHandle {
        if (self.state != .active or self.sftp == null) return error.SessionNotActive;
        const raw = if (directory) c.zw_libssh2_sftp_opendir(self.sftp.?, path.ptr) else c.zw_libssh2_sftp_open_read(self.sftp.?, path.ptr);
        const handle = raw orelse return self.sftpReadonlyError(c.zw_libssh2_session_last_error(self.handle.?));
        return .{ .file = .{ .handle = handle }, .session = self };
    }

    fn sftpReadonlyError(self: *Session, rc: anytype) anyerror {
        if (rc == -37) return error.WouldBlock;
        if (rc == -38) return error.PathLimit;
        if (rc == -31 and self.sftp != null) return switch (c.zw_libssh2_sftp_status(self.sftp.?)) {
            2, 10 => error.FileNotFound,
            3 => error.PermissionDenied,
            8 => error.UnsupportedOperation,
            11 => error.PathAlreadyExists,
            else => error.SftpProtocolFailed,
        };
        return error.SftpIoFailed;
    }

    pub fn closeSftp(self: *Session) void {
        _ = self.closeSftpReceipt();
    }

    pub fn closeSftpReceipt(self: *Session) ReleaseReceipt {
        const sftp = self.sftp orelse return .released;
        if (self.handle) |handle| c.zw_libssh2_session_nonblocking(handle);
        const receipt = nativeReleaseReceipt(c.zw_libssh2_sftp_release(sftp));
        if (receipt == .released) self.sftp = null;
        return receipt;
    }

    pub fn reader(self: *Session) !worker_io.ChannelReader {
        if (self.state != .active) return error.SessionNotActive;
        if (self.channel == null) return error.ShellUnavailable;
        return self.channel.?.reader();
    }
    pub fn writer(self: *Session) !channel_pump.ChannelWriter {
        if (self.state != .active) return error.SessionNotActive;
        if (self.channel == null) return error.ShellUnavailable;
        return self.channel.?.writer();
    }
    pub fn resize(self: *Session, cols: u16, rows: u16) !void {
        if (self.state != .active) return error.SessionNotActive;
        if (self.channel == null) return error.ShellUnavailable;
        try self.channel.?.resize(cols, rows);
    }

    /// Opens a direct-tcpip channel through this authenticated SSH session.
    /// Ownership is transferred to the caller, which must call closeChannel.
    pub fn openExec(self: *Session, command: [:0]const u8) !Channel {
        if (self.state != .active) return error.SessionNotActive;
        if (command.len == 0) return error.EmptyCommand;
        const ticket: OpenTicket = .{ .kind = .legacy_exec, .id = std.hash.Wyhash.hash(0, command) };
        if (!self.claimChannelOpen(ticket)) return error.ChannelOpenBusy;
        const raw = c.zw_libssh2_open_exec(self.handle.?, command.ptr);
        if (raw != null or c.zw_libssh2_session_last_error(self.handle.?) != -37) self.finishChannelOpen(ticket);
        if (raw == null) return error.OpenExecFailed;
        return .{ .handle = @ptrCast(raw.?) };
    }

    /// Exclusive route-creation owner only; shares this hop's network budget.
    pub fn openDirectTcpipDriven(self: *Session, host: [:0]const u8, port: u16, options: Options) !Channel {
        try self.enterIoMode();
        const drive = nativeDrive(options, self.socket_fd);
        var raw: ?*c.LIBSSH2_CHANNEL = null;
        const rc = c.zw_libssh2_open_direct_tcpip_driven(self.handle.?, host.ptr, port, &raw, &drive);
        try checkDriveResult(rc);
        if (rc != 0 or raw == null) return error.OpenDirectTcpipFailed;
        self.recordResource(.tunnel, .owned);
        return .{ .handle = @ptrCast(raw.?) };
    }

    pub fn openDirectTcpip(self: *Session, host: [:0]const u8, port: u16) !Channel {
        if (self.state != .active) return error.SessionNotActive;
        if (host.len == 0 or port == 0) return error.InvalidTunnelTarget;
        const ticket: OpenTicket = .{ .kind = .forward, .id = std.hash.Wyhash.hash(port, host) };
        if (!self.claimChannelOpen(ticket)) return error.ChannelOpenBusy;
        const raw = c.zw_libssh2_open_direct_tcpip(self.handle.?, host.ptr, port);
        if (raw != null or c.zw_libssh2_session_last_error(self.handle.?) != -37) self.finishChannelOpen(ticket);
        if (raw == null) return error.OpenDirectTcpipFailed;
        self.recordResource(.tunnel, .owned);
        return .{ .handle = @ptrCast(raw.?) };
    }

    /// Independent forwarding requests share the transport and channel registry,
    /// but retain their own native open/reply state on this sole IO owner.
    pub fn stepDirectTcpip(self: *Session, host: [:0]const u8, port: u16, pending: *?*c.ZW_SSH_DIRECT_OPEN) !?Channel {
        if (self.state != .active) return error.SessionNotActive;
        var raw: ?*c.LIBSSH2_CHANNEL = null;
        const rc = c.zw_libssh2_direct_open_step(self.handle.?, if (self.shared_gate) |gate| &gate.direct_opens else &self.direct_opens, pending, host.ptr, port, &raw);
        if (rc == 1) return null;
        if (rc < 0) return error.OpenDirectTcpipFailed;
        self.recordResource(.tunnel, .owned);
        return .{ .handle = @ptrCast(raw.?) };
    }

    pub fn closeChannel(self: *Session, channel: *Channel) void {
        _ = self.closeChannelReceipt(channel);
    }

    /// Releases only this child. An unacknowledged close keeps its native
    /// handle owned by the caller and must not interrupt sibling channels.
    pub fn closeChannelReceipt(self: *Session, channel: *Channel) ReleaseReceipt {
        const handle = self.handle orelse return if (self.state == .closed) .released else .unknown;
        c.zw_libssh2_session_nonblocking(handle);
        const is_shell = if (self.channel) |shell| shell.handle == channel.handle else false;
        if (is_shell) self.recordResource(.shell, .releasing);
        const receipt = nativeReleaseReceipt(c.zw_libssh2_channel_release(@ptrCast(channel.handle)));
        if (is_shell) {
            if (receipt == .released) self.channel = null;
            self.recordResource(.shell, switch (receipt) {
                .released => .released,
                .awaiting => .releasing,
                .unknown => .unknown,
            });
        }
        return receipt;
    }
    pub fn socketFd(self: *const Session) !c_int {
        if (self.state != .active) return error.SessionNotActive;
        return self.socket_fd;
    }
    pub fn close(self: *Session) void {
        _ = self.closeReceipt();
    }

    pub fn closeReceipt(self: *Session) ReleaseReceipt {
        if (self.state == .closed) return .released;
        self.state = .closing;
        if (self.connection_details) |store| if (self.resource_key) |key| store.status(key, self.resource_hop, .releasing);
        const receipt = self.release();
        if (receipt == .released) self.state = .closed;
        return receipt;
    }
    fn failAndRelease(self: *Session) void {
        const receipt = self.closeReceipt();
        if (receipt != .released) {
            if (self.resource_ledger) |ledger| {
                // The ordinary connect error cannot return this Session value.
                // Preserve any native remainder under its original attempt.
                if (!ledger.retainFailure(self)) @import("../../platform/applog.zig").err(.ssh, "failed connection cleanup could not retain native owner", .{});
            } else {
                @import("../../platform/applog.zig").err(.ssh, "legacy connection cleanup remains unknown without resource ledger", .{});
            }
        }
        self.state = .failed;
    }
    fn release(self: *Session) ReleaseReceipt {
        if (self.borrowed_transport) {
            if (self.rtt != null) {
                self.rtt_io_owner = std.Thread.getCurrentId();
                self.stepRtt(@import("../../platform/realtime.zig").monotonicNs()) catch return .unknown;
                if (self.rtt != null) return .awaiting;
            }
            const sftp_receipt = self.closeSftpReceipt();
            if (sftp_receipt != .released) return sftp_receipt;
            if (self.channel) |*channel| {
                const receipt = self.closeChannelReceipt(channel);
                if (receipt != .released) return receipt;
            }
            self.handle = null;
            self.socket_fd = -1;
            if (self.connection_details) |store| if (self.resource_key) |key| for (0..self.resource_hop + 1) |hop| store.status(key, hop, .released);
            return .released;
        }
        if (self.socket_release_unknown) return .unknown;
        if (self.handle) |handle| {
            self.recordResource(.session, .releasing);
            if (self.channel != null) self.recordResource(.shell, .releasing);
            self.recordResource(.tunnel, .releasing);
            // Only whole-Session release aborts I/O. Retain fd identity until
            // native free has completed all channel cleanup and flag restores.
            c.zw_libssh2_session_abort_io(handle, self.socket_fd);
            const sftp_receipt = self.closeSftpReceipt();
            if (sftp_receipt != .released) {
                if (sftp_receipt == .unknown) self.recordResource(.session, .unknown);
                return sftp_receipt;
            }
            const receipt = nativeReleaseReceipt(c.zw_libssh2_session_release(handle));
            if (receipt != .released) {
                if (receipt == .unknown) self.recordResource(.session, .unknown);
                return receipt;
            }
            // Native session_free owns every child channel, including a shell
            // that failed halfway through creation and was never published.
            c.zw_libssh2_direct_open_released(&self.direct_opens);
            self.handle = null;
            self.channel = null;
            self.recordResource(.shell, .released);
            self.recordResource(.tunnel, .released);
            if (self.rtt) |sample| if (sample.acquired) self.recordResource(.rtt_channel, .released);
            self.recordResource(.session, .released);
            self.rtt = null;
            self.channel_open = null;
        }
        if (self.socket_fd >= 0) {
            self.recordResource(.transport, .releasing);
            if (c.zw_ssh_socket_release(self.socket_fd) != 0) {
                self.socket_release_unknown = true;
                self.recordResource(.transport, .unknown);
                return .unknown;
            }
            self.socket_fd = -1;
            self.recordResource(.transport, .released);
        }
        if (self.host_key_raw.len != 0) std.heap.c_allocator.free(self.host_key_raw);
        self.host_key_raw = &.{};
        if (self.host_key_store_path) |path| std.heap.c_allocator.free(path);
        self.host_key_store_path = null;
        if (self.connection_details) |store| if (self.resource_key) |key| store.status(key, self.resource_hop, .released);
        return .released;
    }
};

// State-only tests deliberately do not call libssh2, so the direct contract gate stays hermetic.
test "closed SSH session rejects channel access and close is idempotent" {
    var session: Session = .{};
    session.close();
    session.close();
    try std.testing.expectEqual(State.closed, session.state);
    try std.testing.expectError(error.SessionNotActive, session.socketFd());
    try std.testing.expectError(error.SessionNotActive, session.reader());
    try std.testing.expectError(error.SessionNotActive, session.openDirectTcpip("db.internal", 5432));
}

test "private key auth retains optional passphrase contract" {
    const without_passphrase: Auth = .{ .private_key = .{ .path = "/tmp/id_ed25519" } };
    const with_passphrase: Auth = .{ .private_key = .{ .path = "/tmp/id_rsa", .passphrase = "secret" } };

    try std.testing.expect(without_passphrase.private_key.passphrase == null);
    try std.testing.expectEqualStrings("/tmp/id_rsa", with_passphrase.private_key.path);
    try std.testing.expectEqualStrings("secret", with_passphrase.private_key.passphrase.?);
}

test "library tokens share one native process owner and deinit idempotently" {
    const before = Library.activeOwners();
    var first = try Library.init();
    try std.testing.expectEqual(before + 1, Library.activeOwners());
    var second = try Library.init();
    try std.testing.expectEqual(before + 2, Library.activeOwners());
    first.deinit();
    try std.testing.expectEqual(before + 1, Library.activeOwners());
    first.deinit();
    try std.testing.expectEqual(before + 1, Library.activeOwners());
    second.deinit();
    try std.testing.expectEqual(before, Library.activeOwners());
}

test "inactive library token does not affect process owner count" {
    var token: Library = .{ .active = false };
    const before = Library.activeOwners();
    token.deinit();
    try std.testing.expectEqual(before, Library.activeOwners());
}

test "inactive library rejects SSH connection before network IO" {
    const library: Library = .{ .active = false };
    try std.testing.expectError(error.LibraryNotInitialized, Session.connect(&library, .{
        .host = "invalid",
        .user = "nobody",
        .auth = .agent,
    }));
}

test "session strict policy only skips confirmed changed keys for that attempt" {
    const Observer = struct {
        calls: usize = 0,
        status: HostKeyStatus = .trusted,
        decision: HostKeyDecision = .reject_unknown,
        fn observe(raw: *anyopaque, _: []const u8, _: u16, info: HostKeyInfo) HostKeyDecision {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            self.status = info.status;
            std.debug.assert(info.raw_key.len != 0 and info.verification != null);
            return self.decision;
        }
    };
    const old_raw = [_]u8{ 0, 0, 0, 11 } ++ "ssh-ed25519".* ++ [_]u8{ 0, 0, 0, 32 } ++ @as([32]u8, @splat(1));
    const new_raw = [_]u8{ 0, 0, 0, 11 } ++ "ssh-ed25519".* ++ [_]u8{ 0, 0, 0, 32 } ++ @as([32]u8, @splat(2));
    const old_key = try known_hosts.PublicKey.fromRaw(&old_raw);
    const new_key = try known_hosts.PublicKey.fromRaw(&new_raw);
    const fp = known_hosts.fingerprint(new_key);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try policy.HostKeyStore.load(std.testing.io, tmp.dir, std.testing.allocator, "known_hosts");
    defer store.deinit();
    try store.trust("target", 2222, old_key, try store.check("target", 2222, old_key), .save);
    const saved = try std.testing.allocator.dupe(u8, store.bytes());
    defer std.testing.allocator.free(saved);
    var observer: Observer = .{};
    var options: Options = .{ .host = "target", .port = 2222, .user = "operator", .auth = .agent, .strict_host_key_checking = false, .host_key_store = &store, .host_key_observer = .{ .ctx = &observer, .callback = Observer.observe } };
    try std.testing.expectEqual(HostKeyAcceptance.accepted_changed_for_attempt, (try verifyHostKey(options, new_key, fp.slice())).acceptance);
    try std.testing.expectEqual(@as(usize, 0), observer.calls);
    try std.testing.expectEqualStrings(saved, store.bytes());
    const disk = try tmp.dir.readFileAlloc(std.testing.io, "known_hosts", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(disk);
    try std.testing.expectEqualStrings(saved, disk);
    try std.testing.expectEqual(known_hosts.Result.trusted, (try store.check("target", 2222, old_key)).result);
    options.strict_host_key_checking = true;
    try std.testing.expectError(error.HostKeyChanged, verifyHostKey(options, new_key, fp.slice()));
    try std.testing.expectEqual(HostKeyStatus.changed, observer.status);
    observer.decision = .trust_changed_yes;
    try std.testing.expectEqual(HostKeyAcceptance.replaced, (try verifyHostKey(options, new_key, fp.slice())).acceptance);
    try std.testing.expectEqual(known_hosts.Result.trusted, (try store.check("target", 2222, new_key)).result);
    observer.decision = .reject_unknown;
    options.host = "first-contact";
    for ([_]bool{ false, true }) |strict| {
        options.strict_host_key_checking = strict;
        try std.testing.expectError(error.HostKeyConfirmationRequired, verifyHostKey(options, new_key, fp.slice()));
        try std.testing.expectEqual(HostKeyStatus.unknown, observer.status);
    }
    options.host_key_store = null;
    options.host_key_observer = null;
    try std.testing.expectError(error.HostKeyConfirmationRequired, verifyHostKey(options, new_key, fp.slice()));
    const revoked_source = try std.fmt.allocPrint(std.testing.allocator, "@revoked {s}", .{saved});
    defer std.testing.allocator.free(revoked_source);
    var revoked = try policy.HostKeyStore.parse(std.testing.allocator, revoked_source);
    defer revoked.deinit();
    options.host = "target";
    options.host_key_store = &revoked;
    options.strict_host_key_checking = false;
    // A revocation is a hard failure, never a strict=false mismatch bypass.
    try std.testing.expectError(error.HostKeyRevoked, verifyHostKey(options, old_key, fp.slice()));
    try std.testing.expectError(error.HostKeyConfirmationRequired, verifyHostKey(options, new_key, fp.slice()));
    const coexist_source = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}", .{ revoked_source, store.bytes() });
    defer std.testing.allocator.free(coexist_source);
    var coexist = try policy.HostKeyStore.parse(std.testing.allocator, coexist_source);
    defer coexist.deinit();
    options.host_key_store = &coexist;
    try std.testing.expectEqual(HostKeyAcceptance.known_match, (try verifyHostKey(options, new_key, fp.slice())).acceptance);
}

test "session key unlock recovery does not mistake transport refusal for a passphrase error" {
    try std.testing.expect(keyUnlockError(-16));
    try std.testing.expect(keyUnlockError(-48));
    try std.testing.expect(!keyUnlockError(-19));
    try std.testing.expect(!keyUnlockError(-18));
    try std.testing.expect(!keyUnlockError(-9));
}

test "cancelled connect is rejected before opening a socket" {
    var library = Library{ .active = true };
    var cancelled = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Cancelled, Session.connect(&library, .{
        .host = "invalid",
        .user = "nobody",
        .auth = .agent,
        .cancel_token = &cancelled,
    }));
}

test "empty session has no host key information" {
    const session: Session = .{};
    try std.testing.expect(session.hostKey() == null);
}

test "library init and deinit remain balanced across concurrent tokens" {
    const before = Library.activeOwners();
    var failures = std.atomic.Value(u32).init(0);
    var threads: [8]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, libraryTokenWorker, .{&failures});
    for (threads) |thread| thread.join();
    try std.testing.expectEqual(@as(u32, 0), failures.load(.acquire));
    try std.testing.expectEqual(before, Library.activeOwners());
}

fn libraryTokenWorker(failures: *std.atomic.Value(u32)) void {
    var token = Library.init() catch {
        _ = failures.fetchAdd(1, .acq_rel);
        return;
    };
    // Repeated deinit consumes only this token.
    token.deinit();
    token.deinit();
}

test "connection diagnostics report pre-network failures without credentials" {
    var journal: ConnectionProgress.Journal = .{};
    journal.begin(11);
    const library: Library = .{ .active = false };
    try std.testing.expectError(error.LibraryNotInitialized, Session.connect(&library, .{ .host = "jump-2", .user = "ops", .auth = .{ .password = "must-not-be-logged" }, .progress_observer = journal.observer(), .attempt_id = 11, .hop_index = 1, .hop_count = 3 }));
    const failed = journal.snapshot().failure.?;
    try std.testing.expectEqual(@as(usize, 1), failed.hop);
    try std.testing.expectEqual(ConnectionProgress.Phase.transport, failed.phase);
    try std.testing.expectEqualStrings("jump-2", failed.hostSlice());
}

const IoModeTest = struct {
    extern "c" fn libssh2_session_get_blocking(session: *c.LIBSSH2_SESSION) c_int;

    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });

    /// Exercises the same final handoff as connectOverFd without pretending
    /// that a local socket has performed SSH authentication. Consumes fd.
    fn handoff(fd: c_int) !void {
        var session: Session = .{ .state = .authenticated, .socket_fd = fd };
        defer session.close();
        session.handle = c.zw_libssh2_session_create() orelse return error.SessionCreateFailed;
        try std.testing.expectEqual(@as(c_int, 0), c.zw_ssh_socket_set_blocking(fd));
        const before = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
        try std.testing.expect(before >= 0 and before & nonblock == 0);
        c.zw_libssh2_session_set_blocking(session.handle.?);
        try std.testing.expectEqual(@as(c_int, 1), libssh2_session_get_blocking(session.handle.?));
        try session.enterIoMode();
        try std.testing.expectEqual(before | nonblock, std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0)));
        try std.testing.expectEqual(@as(c_int, 0), libssh2_session_get_blocking(session.handle.?));
        // Check the flag first so a regression cannot hang this empty read.
        var byte: u8 = 0;
        try std.testing.expectEqual(@as(isize, -1), std.c.recv(fd, &byte, 1, 0));
        try std.testing.expectEqual(@as(c_int, @backingInt(std.c.E.AGAIN)), std.c._errno().*);
        session.close();
        try std.testing.expectEqual(@as(c_int, -1), std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0)));
        try std.testing.expectEqual(@as(c_int, @backingInt(std.c.E.BADF)), std.c._errno().*);
        try std.testing.expectEqual(@as(c_int, -1), session.socket_fd);
        try std.testing.expect(session.handle == null);
    }
};

test "SSH IO handoff restores native nonblocking mode on a real direct TCP socket" {
    var library = try Library.init();
    defer library.deinit();
    const listener = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    try std.testing.expect(listener >= 0);
    defer c.zw_ssh_socket_close(listener);
    var address: std.c.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    try std.testing.expectEqual(@as(c_int, 0), std.c.bind(listener, @ptrCast(&address), @sizeOf(@TypeOf(address))));
    try std.testing.expectEqual(@as(c_int, 0), std.c.listen(listener, 1));
    var length: std.c.socklen_t = @sizeOf(@TypeOf(address));
    try std.testing.expectEqual(@as(c_int, 0), std.c.getsockname(listener, @ptrCast(&address), &length));
    // Only the loopback listener above is contacted; no SSH daemon is needed.
    const fd = c.zw_ssh_socket_connect("127.0.0.1", std.mem.bigToNative(u16, address.port), 1000);
    try std.testing.expect(fd >= 0);
    try IoModeTest.handoff(fd);
}

test "SSH IO handoff restores native nonblocking mode on a real jump socketpair" {
    var library = try Library.init();
    defer library.deinit();
    const pair = try SocketRelay.Pair.create();
    defer c.zw_ssh_socket_close(pair.relay_fd);
    try IoModeTest.handoff(pair.target_fd);
    var byte: u8 = 0;
    try std.testing.expectEqual(@as(isize, 0), std.c.recv(pair.relay_fd, &byte, 1, 0));
}

test "SSH IO handoff failure and cancelled connectOverFd consume owned resources" {
    var library = try Library.init();
    defer library.deinit();
    const inactive: Library = .{ .active = false };
    var cancelled = std.atomic.Value(bool).init(true);
    for ([_]bool{ false, true }) |cancel| {
        const pair = try SocketRelay.Pair.create();
        defer c.zw_ssh_socket_close(pair.relay_fd);
        try std.testing.expectError(if (cancel) error.Cancelled else error.LibraryNotInitialized, Session.connectOverFd(if (cancel) &library else &inactive, .{ .host = "unused", .user = "unused", .auth = .agent, .cancel_token = &cancelled }, pair.target_fd));
        try std.testing.expectEqual(@as(c_int, -1), std.c.fcntl(pair.target_fd, std.c.F.GETFL, @as(c_int, 0)));
        try std.testing.expectEqual(@as(c_int, @backingInt(std.c.E.BADF)), std.c._errno().*);
        var byte: u8 = 0;
        try std.testing.expectEqual(@as(isize, 0), std.c.recv(pair.relay_fd, &byte, 1, 0));
    }
    try std.testing.expectEqual(@as(c_int, -1), c.zw_ssh_socket_set_nonblocking(-1));
    var session: Session = .{ .state = .authenticated, .socket_fd = -1 };
    defer session.close();
    session.handle = c.zw_libssh2_session_create() orelse return error.SessionCreateFailed;
    // A failed native transition must not switch only the libssh2 flag.
    try std.testing.expectError(error.TransportSetupFailed, session.enterIoMode());
    try std.testing.expectEqual(@as(c_int, 1), IoModeTest.libssh2_session_get_blocking(session.handle.?));
    try std.testing.expectEqual(State.authenticated, session.state);
    session.failAndRelease();
    try std.testing.expectEqual(State.failed, session.state);
    try std.testing.expect(session.handle == null and session.socket_fd == -1);
}

test "shared transport ledger transfers native ownership while shell remains local" {
    var source = try ResourceLedger.init(null, 2);
    var shared = try ResourceLedger.init(null, 2);
    try std.testing.expect(source.record(null, 0, .transport, .owned));
    try std.testing.expect(source.record(null, 1, .session, .owned));
    try std.testing.expect(source.record(null, 1, .shell, .owned));
    try source.transferConnectionOwnership(&shared);
    try std.testing.expectEqual(ResourceState.transferred, source.snapshot().entry(0, .transport).state);
    try std.testing.expectEqual(ResourceState.owned, shared.snapshot().entry(0, .transport).state);
    try std.testing.expect(!source.snapshot().released());
    try std.testing.expect(source.record(null, 1, .shell, .released));
    try std.testing.expect(source.snapshot().released());
    try std.testing.expect(!shared.snapshot().released());
    // Relay owners may finish recording through the original stable ledger.
    try std.testing.expect(source.record(null, 0, .transport, .released));
    try std.testing.expectEqual(ResourceState.released, shared.snapshot().entry(0, .transport).state);
    source.forgetTransferred(&shared);
}

test "shared channel open gates namespace identical caller IDs by session" {
    var native: Session = .{};
    var one: Session = .{ .shared_gate = &native };
    var two: Session = .{ .shared_gate = &native };
    const ticket: Session.OpenTicket = .{ .kind = .exec, .id = 1 };
    try std.testing.expect(one.claimChannelOpen(ticket));
    try std.testing.expect(!two.claimChannelOpen(ticket));
    two.finishChannelOpen(ticket);
    try std.testing.expect(!two.claimChannelOpen(ticket));
    one.finishChannelOpen(ticket);
    try std.testing.expect(two.claimChannelOpen(ticket));
    two.finishChannelOpen(ticket);
}
