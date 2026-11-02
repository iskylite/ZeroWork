//! Worker-only native HTTPS/WSS backend. Preparing freezes configuration and
//! resolves SSH credentials on the configuration owner; Driver methods own all
//! subsequent network IO. This module is deliberately not a production factory.
const std = @import("std");
const builtin = @import("builtin");
const controller = @import("controller.zig");
const route = @import("route.zig");
const model = @import("model.zig");
const svc = @import("services.zig");
const contexts = @import("../../host/host_context.zig");
const probes = @import("../../host/probe_contract.zig");
const trust = @import("../../host/tls_trust.zig");
const auth = @import("protocol/auth.zig");
const profile = @import("protocol/profile.zig");
const tls = @import("protocol/tls.zig");
const http = @import("protocol/http.zig");
const ws = @import("protocol/websocket.zig");
const redfish = @import("protocol/redfish.zig");
const power = @import("protocol/power.zig");
const management = @import("management_adapter.zig");
const transports = @import("../../host/transport_factory.zig");
const monotonic = @import("../../platform/realtime.zig");
const progress = @import("connection_progress.zig");
const ssh_progress = @import("../../proto/ssh/connection_progress.zig");

extern fn zw_bmc_gzip_create() ?*anyopaque;
extern fn zw_bmc_gzip_destroy(?*anyopaque) void;
extern fn zw_bmc_gzip_step(?*anyopaque, [*]const u8, usize, *usize, [*]u8, usize, *usize) c_int;

pub const Callbacks = struct {
    context: *anyopaque,
    /// The host presents the complete challenge. No callback means failure.
    trust_reply: ?*const fn (*anyopaque, trust.Challenge, *const std.atomic.Value(bool)) anyerror!trust.TrustChoice = null,
    /// One operation's input, returned in wipeable owned storage. Used only
    /// when there is no saved reference or the granted secret is missing.
    password_reply: ?*const fn (*anyopaque, svc.identity.SessionHandle, svc.OperationKey, *const std.atomic.Value(bool), std.mem.Allocator) anyerror!auth.Secret = null,
    /// Privilege schemas differ between firmware. Default is read-only; a
    /// verified adapter may return grants derived from these actual documents.
    capability: ?*const fn (*anyopaque, *const redfish.Discovery) anyerror!svc.Capability = null,
};
pub const KvmTokenSource = enum { response_header, synthetic_json };
pub const Options = struct {
    /// null selects from actual anonymous device identity after TLS trust on
    /// the worker. Explicit selections preserve previously verified callers.
    selected: ?profile.Profile = null,
    /// Sugon 1.80 returns the separate KVM token in its own X-Auth-Token
    /// response header. Explicit body fields are permitted only in test builds
    /// with a synthetic profile; neither source falls back to the WEB token.
    kvm_token_source: KvmTokenSource = .response_header,
    kvm_token_field: ?[]const u8 = null,
    kvm_id_field: ?[]const u8 = null,
    callbacks: ?Callbacks = null,
    management_adapter: ?*management.Adapter = null,
    /// Frozen for this attempt. Authentication and own-session cleanup are
    /// separate; this policy controls power/boot management IO dispatch.
    management_policy: svc.ManagementPolicy = .read_only,
    /// Stable per-attempt memory; worker only records safe scalar metadata.
    progress: ?*progress.Tracker = null,
};
pub const RemoteRelease = enum { not_created, awaiting, confirmed, unknown };
/// Safe, one-time discovery summary. No device URI, identity or response text
/// is exposed; callers acquire it only after the worker publishes the result.
pub const MappingRejection = enum {
    manager_document_rejected,
    manager_servers_not_single,
    system_missing,
    system_document_rejected,
    system_reverse_link_missing,
    system_identity_missing,
    invalid_relationship,
    profile_evidence_unverified,
    ambiguous_mapping,
};
pub const ResourceAssociationMethod = enum { reviewed_public_ids_and_chassis };
pub const DiscoveryDiagnostics = struct {
    management_discovery_complete: bool = true,
    management_discovery_error: ?anyerror = null,
    manager_count: usize = 0,
    system_count: usize = 0,
    mapping_verified: bool = false,
    mapping_error: ?anyerror = null,
    mapping_rejection: ?MappingRejection = null,
    mapping_system_status: ?u16 = null,
    mapping_system_validity: ?svc.Validity = null,
    management_target_verified: bool = false,
    management_target_error: ?anyerror = null,
    resource_association_verified: bool = false,
    resource_association_method: ?ResourceAssociationMethod = null,
    readonly_system_projection: bool = false,
    readonly_rejection: ?progress.Code = null,
    readonly_collection_count: usize = 0,
    readonly_member_count: usize = 0,
    readonly_collection_status: ?u16 = null,
    readonly_collection_validity: ?svc.Validity = null,
    readonly_system_status: ?u16 = null,
    readonly_system_validity: ?svc.Validity = null,
    readonly_system_identity_present: bool = false,
};
pub const LogoutStage = enum { not_created, own_reference_unavailable, management_unavailable, request_build_failed, transaction_failed, response_parse_failed, response_rejected, confirmed, connection_failed };
pub const LogoutAttempt = struct {
    stage: LogoutStage = .not_created,
    failure: ?anyerror = null,
    http_status: ?u16 = null,
    response_validity: ?svc.Validity = null,
    request_dispatched: bool = false,
    fresh_connection: bool = false,
    management_failed_at_entry: bool = false,
    transport_done_at_entry: bool = false,
    transport_done_at_exit: bool = false,
};
pub const WebSocketClose = enum { not_open, build_failed, transport_failed, deadline, frame_sent, incomplete_frame_aborted };
pub const LogoutDiagnostics = struct {
    web: LogoutAttempt = .{},
    kvm: LogoutAttempt = .{},
    websocket_close: WebSocketClose = .not_open,
    websocket_failure: ?anyerror = null,
};
pub const Diagnostics = struct {
    web_logout: RemoteRelease = .not_created,
    kvm_logout: RemoteRelease = .not_created,
    system_mapping_verified: bool = false,
    management_available: bool = false,
    video_upgraded: bool = false,
    firmware_observed: bool = false,
    local_cleanup: controller.Cleanup = .not_started,
};

const Channel = struct {
    client: tls.Client,
    // Preserves bytes following an HTTP response, especially the first WS frame
    // coalesced with Upgrade. No bytes are discarded at a parser boundary.
    pending: [32 * 1024]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    fn take(self: *Channel, out: []u8) usize {
        const n = @min(out.len, self.end - self.start);
        @memcpy(out[0..n], self.pending[self.start..][0..n]);
        self.start += n;
        if (self.start == self.end) {
            self.start = 0;
            self.end = 0;
        }
        return n;
    }
};
const Transaction = struct {
    request: auth.Secret,
    response: http.ResponseParser,
    offset: usize = 0,
    deadline_ns: u64,
    started_ns: u64,
    received_bytes: u64 = 0,
    context: progress.Context,
    sequence: u64 = 0,
    fn deinit(self: *Transaction) void {
        self.request.deinit();
        self.response.deinit();
        self.* = undefined;
    }
};
const Schema = struct { source: KvmTokenSource, token: ?[]const u8, id: ?[]const u8 };

// Only capabilities actually used by the shared authentication/discovery
// implementation survive preparation. No target, window or presentation is
// manufactured for a probe, or retained from a console context.
const CommonContext = struct {
    owner: svc.identity.SessionHandle,
    operation: svc.OperationKey,
    trust: contexts.Trust,
    secrets: ?@import("../../host/secret_lease.zig").Facade,
    tasks: ?contexts.Tasks,
};
const Preparation = union(enum) { console: contexts.HostContext, probe: probes.ProbeContext };

pub const NativeDriver = struct {
    allocator: std.mem.Allocator,
    context: CommonContext,
    probe_only: bool,
    config: svc.Owned(model.Payload),
    /// Initialized at prepare for explicit callers, or by trusted worker
    /// discovery for automatic mode. Never read until selection_ready.
    selected: svc.Owned(profile.Profile),
    selection_ready: bool = false,
    firmware_pending_verification: bool = false,
    schema: svc.Owned(Schema),
    callbacks: ?Callbacks,
    adapter: ?*management.Adapter,
    management_policy: svc.ManagementPolicy,
    connection_progress: ?*progress.Tracker = null,
    plan: *const route.Plan,
    pair: route.Pair,
    cancel: *const std.atomic.Value(bool),
    creator_thread: std.Thread.Id,
    worker_thread: ?std.Thread.Id = null,
    management_channel: ?Channel = null,
    video_channel: ?Channel = null,
    discovery: ?redfish.Discovery = null,
    web_session: ?auth.WebSession = null,
    kvm_session: ?auth.KvmSession = null,
    transaction: ?Transaction = null,
    completed: ?Transaction = null,
    management_failed: bool = false,
    management_discovery_error: ?anyerror = null,
    cleanup_peer_leaf: ?trust.Fingerprint = null,
    cleanup_peer_chain: ?trust.Fingerprint = null,
    aborted: bool = false,
    /// Pipeline writes one complete WS frame (or its unsent suffix) per call.
    /// A short write/WANT_* retains that frame, including mbedTLS's unchanged
    /// buffer requirement. Cleanup cannot append a different Close frame.
    video_write_pending: bool = false,
    cleanup_started: bool = false,
    transport_destroyed: bool = false,
    diagnostics: Diagnostics = .{},
    discovery_diagnostics: DiscoveryDiagnostics = .{},
    discovery_published: std.atomic.Value(bool) = .init(false),
    logout_diagnostics: LogoutDiagnostics = .{},
    logout_published: std.atomic.Value(bool) = .init(false),

    /// Call on the configuration owner, before Controller.start. Plan, cancel,
    /// facade backing stores and Adapter must remain alive until cleanup.
    pub fn prepare(a: std.mem.Allocator, context: contexts.HostContext, payload: model.Payload, plan: *const route.Plan, cancel: *const std.atomic.Value(bool), options: Options) !*NativeDriver {
        return prepareCommon(a, .{ .console = context }, payload, plan, cancel, options);
    }

    /// Memory/configuration preparation only. ProbeContext supplies the actual
    /// child owner/operation; the shared backend receives no UI/write facade.
    pub fn prepareProbe(a: std.mem.Allocator, context: probes.ProbeContext, payload: model.Payload, plan: *const route.Plan, cancel: *const std.atomic.Value(bool), options: Options) !*NativeDriver {
        if (options.management_adapter != null) return error.ProbeManagementForbidden;
        return prepareCommon(a, .{ .probe = context }, payload, plan, cancel, options);
    }

    fn prepareCommon(a: std.mem.Allocator, source: Preparation, payload: model.Payload, plan: *const route.Plan, cancel: *const std.atomic.Value(bool), options: Options) !*NativeDriver {
        try model.validate(payload);
        const common: CommonContext = switch (source) {
            .console => |context| blk: {
                try context.requireOwner(plan.owner);
                break :blk .{ .owner = context.owner, .operation = context.operation, .trust = context.trust, .secrets = context.secrets, .tasks = context.tasks };
            },
            .probe => |context| blk: {
                try context.requireOwner(plan.owner, context.operation);
                if (context.cancelled()) return error.Cancelled;
                break :blk .{ .owner = context.owner, .operation = context.operation, .trust = context.trust, .secrets = context.secrets, .tasks = .{ .cancel = context.cancel } };
            },
        };
        try trust.requireOperation(common.owner, common.operation);
        if (!std.mem.eql(u8, plan.destination.host, payload.endpoint.host) or plan.destination.port != payload.endpoint.https_port) return error.FrozenEndpointMismatch;
        if (options.selected) |selected| {
            if (selected.synthetic) {
                if (!builtin.is_test) return error.SyntheticProfileForbidden;
                // Re-validate all evidence, including a key digest, even for tests.
                _ = try profile.syntheticForTest(testIdentity(), selected.evidence);
            } else try selected.validateForProduction();
        }
        switch (options.kvm_token_source) {
            .response_header => if (options.kvm_token_field != null) return error.AmbiguousKvmTokenSource,
            .synthetic_json => {
                if (!builtin.is_test or options.selected == null or !options.selected.?.synthetic) return error.BodyKvmTokenSourceForbidden;
                if (options.kvm_token_field == null or options.kvm_token_field.?.len == 0) return error.KvmAuthenticationEvidenceUnavailable;
            },
        }
        const self = try a.create(NativeDriver);
        errdefer a.destroy(self);
        var frozen = try svc.Owned(model.Payload).init(a, payload);
        errdefer frozen.deinit();
        var selected: svc.Owned(profile.Profile) = undefined;
        if (options.selected) |value| selected = try svc.Owned(profile.Profile).init(a, value);
        errdefer if (options.selected != null) selected.deinit();
        var schema = try svc.Owned(Schema).init(a, .{ .source = options.kvm_token_source, .token = options.kvm_token_field, .id = options.kvm_id_field });
        errdefer schema.deinit();
        const pair = switch (source) {
            .console => |context| blk: {
                var host = context;
                if (host.transports) |*factory| {
                    factory.timeout_ms = 15_000;
                    factory.keep_established_until_close = true;
                    factory.cleanup_destination = plan.destination;
                    if (context.credentials) |provider| factory.credentials = provider;
                }
                break :blk try route.Pair.prepare(host, plan, cancel);
            },
            .probe => |context| blk: {
                var probe = context;
                if (probe.transports) |*factory| {
                    factory.timeout_ms = 15_000;
                    factory.keep_established_until_close = true;
                    // Probes own exactly one management stream. Even an
                    // inherited console factory cannot grant cleanup dials.
                    factory.cleanup_destination = null;
                    if (context.credentials) |provider| factory.credentials = provider;
                }
                break :blk try route.Pair.prepareProbe(probe, plan, cancel);
            },
        };
        self.* = .{ .allocator = a, .context = common, .probe_only = source == .probe, .config = frozen, .selected = selected, .selection_ready = options.selected != null, .firmware_pending_verification = if (options.selected) |value| value.identity_source == .reviewed_public_material else false, .schema = schema, .callbacks = options.callbacks, .adapter = options.management_adapter, .management_policy = if (source == .probe) .read_only else options.management_policy, .connection_progress = options.progress, .plan = plan, .pair = pair, .cancel = cancel, .creator_thread = std.Thread.getCurrentId() };
        self.diagnostics.firmware_observed = options.selected != null and !self.firmware_pending_verification;
        self.pair.destination = .{ .host = self.origin().host, .port = self.config.value.endpoint.https_port };
        if (options.progress) |tracker| for (self.pair.transport.options) |*hop| {
            hop.progress_observer = .{ .context = tracker, .callback = recordSshProgress };
        };
        return self;
    }

    /// Thread-spawn/submission failure owns no native IO. Retire only a never
    /// started transport: its deinit wipes cloned SSH auth and releases the
    /// failed-open reservation without joining or touching native sessions.
    pub fn discardPrepared(self: *NativeDriver) !void {
        if (self.pair.transport.started or self.worker_thread != null or self.management_channel != null or self.video_channel != null or self.cleanup_started) return error.NativeDriverAlreadyStarted;
        try self.pair.deinit();
        self.transport_destroyed = true;
        self.diagnostics.local_cleanup = .released;
        try self.deinit();
    }
    /// Memory-only retirement, after worker cleanup returned local released.
    pub fn deinit(self: *NativeDriver) !void {
        if (!self.transport_destroyed or self.diagnostics.local_cleanup != .released) return error.CleanupIncomplete;
        self.config.deinit();
        if (self.selection_ready) self.selected.deinit();
        self.schema.deinit();
        const a = self.allocator;
        a.destroy(self);
    }
    pub fn driver(self: *NativeDriver) controller.Driver {
        return .{ .context = self, .begin = begin, .read = read, .write = write, .abort = abort, .cleanup = cleanup, .wait = wait, .now_ns = now, .management_io = if (self.probe_only) null else managementIo, .management_available = managementAvailable };
    }
    pub fn discoveryDiagnostics(self: *const NativeDriver) ?DiscoveryDiagnostics {
        if (!self.discovery_published.load(.acquire)) return null;
        return self.discovery_diagnostics;
    }
    pub fn logoutDiagnostics(self: *const NativeDriver) ?LogoutDiagnostics {
        if (!self.logout_published.load(.acquire)) return null;
        return self.logout_diagnostics;
    }
    fn managementAvailable(context: *anyopaque) bool {
        return cast(context).diagnostics.management_available;
    }
    fn cast(context: *anyopaque) *NativeDriver {
        return @ptrCast(@alignCast(context));
    }
    fn requireWorker(self: *NativeDriver) !void {
        const current = std.Thread.getCurrentId();
        if (current == self.creator_thread) return error.NativeIoOnConfigurationThread;
        if (self.worker_thread) |owner| {
            if (owner != current) return error.NativeIoWrongWorker;
        } else self.worker_thread = current;
    }
    fn check(self: *NativeDriver) !void {
        if (self.cancel.load(.acquire) or (if (self.context.tasks) |tasks| tasks.cancelled() else false)) return error.Cancelled;
    }
    fn origin(self: *NativeDriver) http.Origin {
        var host = self.config.value.endpoint.host;
        if (host[0] == '[') host = host[1 .. host.len - 1];
        return .{ .host = host, .port = self.config.value.endpoint.https_port };
    }
    fn evidence(self: *NativeDriver) auth.Evidence {
        std.debug.assert(self.selection_ready);
        const ev = self.selected.value.evidence;
        return .{ .profile_id = @tagName(self.selected.value.id), .firmware = ev.firmware, .public_key_pem = ev.public_key_pem, .public_key_sha256 = ev.public_key_sha256, .source_uri = ev.public_key_source, .verified = true, .web_headers_verified = ev.web_login_schema_verified, .kvm_schema_verified = ev.kvm_login_schema_verified };
    }
    fn begin(context: *anyopaque, payload: *const model.Payload, plan: *const route.Plan, operation: svc.OperationKey, cancel: *const std.atomic.Value(bool)) !controller.video.rfb.Authenticated {
        const self = cast(context);
        try self.requireWorker();
        if (self.probe_only) return error.ProbeConsoleForbidden;
        if (self.cleanup_started or self.management_channel != null or plan != self.plan or cancel != self.cancel or !operation.eql(self.context.operation) or !std.mem.eql(u8, payload.endpoint.host, self.config.value.endpoint.host) or payload.endpoint.https_port != self.config.value.endpoint.https_port) return error.StaleNativeDriver;
        try self.beginManagement();
        self.publishDiscovery() catch |err| {
            if (err == error.Cancelled or err == error.OutOfMemory) return err;
            self.progressNote(.{ .code = .management_discovery_incomplete, .resource = .system, .err = err });
        };
        return self.beginConsole();
    }

    /// Worker-only WEB authentication and read-only Redfish discovery. This
    /// path cannot create an OEM session, open WSS, publish frames or input.
    pub fn beginProbe(self: *NativeDriver) !void {
        try self.requireWorker();
        if (!self.probe_only or self.adapter != null) return error.NotProbeDriver;
        if (self.cleanup_started or self.management_channel != null) return error.StaleNativeDriver;
        try self.beginManagement();
        self.diagnostics.management_available = true;
    }

    pub fn cleanupProbe(self: *NativeDriver) controller.Cleanup {
        if (!self.probe_only) return .unknown;
        return cleanup(self);
    }

    fn beginManagement(self: *NativeDriver) !void {
        try self.check();
        self.progressContext(.{ .channel = if (self.plan.route.hops.len == 0) .management else .ssh, .phase = .connect });
        self.progressStage(.route);
        // Automatic bootstrap has not identified the BMC yet. Open only the
        // management stream; a video stream is acquired after authorization.
        if (self.probe_only or !self.selection_ready) try self.pair.connectManagement() else try self.pair.connect();
        self.progressContext(.{ .phase = .connect });
        self.progressNote(.{ .code = .route_connected, .resource = .management_route });
        try self.check();
        self.management_channel = .{ .client = try tls.Client.init(self.pair.management.?.fd, self.origin().host) };
        try self.handshake(&self.management_channel.?);
        self.progressStage(.public_identity);
        self.discovery = try redfish.Discovery.init(self.allocator, self.config.value.endpoint);
        const root_request = self.discovery.?.next() orelse return error.MissingServiceRoot;
        var root_response = try self.request("GET", root_request.uri, &.{}, "");
        defer root_response.deinit();
        try self.discovery.?.ingest(root_request, root_response.response.status, root_response.response.body(), root_response.response.header("ETag"), timestamp() / std.time.ns_per_ms);
        const root_doc = self.discovery.?.find(root_request.uri) orelse return error.MissingServiceRoot;
        self.progressResponse(.service_root, root_doc.status, root_doc.validity);
        if (!self.selection_ready) try self.selectTrustedProfile(root_doc.*);
        const reviewed_public_management = self.selected.value.id == .sugon_1_80_oem_rfb and std.mem.eql(u8, self.selected.value.evidence.firmware, "1.80");
        self.discovery.?.oem_public_security_service = reviewed_public_management;
        self.discovery.?.oem_public_resource_association = reviewed_public_management;
        const service_link = redfish.link(root_doc.value, "SessionService") orelse return error.MissingSessionService;
        const service_uri = try self.origin().validateReference(service_link);
        var service_response = try self.request("GET", service_uri, &.{}, "");
        defer service_response.deinit();
        self.progressResponse(.session_service, service_response.response.status, null);
        const sessions_uri = blk: {
            // The reviewed 1.80 SPA creates WEB sessions at this exact path;
            // this firmware can protect GET SessionService before login. The
            // fallback is restricted to that selected evidence and the root's
            // exact same-origin parent, never a guessed endpoint/profile.
            if ((service_response.response.status == 401 or service_response.response.status == 403) and
                self.selected.value.id == .sugon_1_80_oem_rfb and
                std.mem.eql(u8, self.selected.value.evidence.firmware, "1.80") and
                self.selected.value.evidence.web_login_schema_verified and
                std.mem.eql(u8, service_uri, "/redfish/v1/SessionService")) break :blk try self.allocator.dupe(u8, "/redfish/v1/SessionService/Sessions");
            var service_doc = try redfish.Document.parse(self.allocator, service_uri, service_response.response.status, service_response.response.body(), null, timestamp() / std.time.ns_per_ms);
            defer service_doc.deinit();
            if (!service_doc.resourceAvailable() or !service_doc.fieldAccepted("/Sessions")) return error.SessionServiceUnavailable;
            const sessions_link = redfish.link(service_doc.value, "Sessions") orelse return error.MissingSessionsCollection;
            break :blk try self.allocator.dupe(u8, try self.origin().validateReference(sessions_link));
        };
        defer self.allocator.free(sessions_uri);
        var password = try self.acquirePassword();
        defer password.deinit();
        self.progressContext(.{ .method = .post, .path = .web_sessions, .phase = .request_send, .received_bytes = 0, .duration_ms = 0 });
        self.progressStage(.web_login);
        var login = try auth.webLogin(self.allocator, self.evidence(), auth.nativeEncryptor(), self.config.value.username, password.bytes);
        password.clear();
        defer login.deinit();
        var login_response = try self.createSessionRequest(sessions_uri, &.{.{ .name = "Content-Type", .value = "application/json" }}, login.body.bytes, &self.diagnostics.web_logout);
        login.body.clear();
        defer login_response.deinit();
        var login_doc = try redfish.Document.parse(self.allocator, sessions_uri, login_response.response.status, login_response.response.body(), null, timestamp() / std.time.ns_per_ms);
        defer login_doc.deinit();
        self.progressResponse(.web_session, login_doc.status, login_doc.validity);
        if (login_response.response.headerCount("X-Auth-Token") != 1 or login_response.response.headerCount("Location") != 1) return error.InvalidWebSessionHeaders;
        self.web_session = try auth.acceptWebSession(self.allocator, self.discovery.?.origin, self.context.owner, login_doc, login_response.response.header("X-Auth-Token").?, login_response.response.header("Location").?);
        self.diagnostics.web_logout = .awaiting;
        self.progressNote(.{ .code = .web_authenticated, .resource = .web_session });
        // Actual Manager firmware is mandatory when public material selected
        // the profile. Resolve it before optional Systems/management metadata.
        if (self.firmware_pending_verification) try self.readFirmwareEvidence();
        self.progressStage(.redfish_discovery);
        while (self.discovery.?.next()) |pending| {
            self.readDiscoveryResource(pending) catch |err| {
                // Probes report their discovery result. A console can keep
                // its authenticated video path without management metadata;
                // cancellation and allocation failures remain terminal.
                if (self.probe_only or err == error.Cancelled or err == error.OutOfMemory) return err;
                self.management_discovery_error = err;
                self.progressNote(.{ .code = .management_discovery_incomplete, .resource = resourceKind(pending.kind), .err = err });
                // A partially consumed HTTP response cannot share a stream
                // with OEM authentication. Reconnect only to the same endpoint
                // and authorize only this attempt's already accepted peer.
                if (self.management_failed) try self.reopenManagementChannel();
                break;
            };
        }
    }
    fn readDiscoveryResource(self: *NativeDriver, pending: redfish.ReadRequest) !void {
        var response = try self.request("GET", pending.uri, &.{}, "");
        defer response.deinit();
        try self.discovery.?.ingest(pending, response.response.status, response.response.body(), response.response.header("ETag"), timestamp() / std.time.ns_per_ms);
        const observed_doc = self.discovery.?.find(pending.uri);
        self.progressResponse(resourceKind(pending.kind), response.response.status, if (observed_doc) |doc| doc.validity else null);
    }
    fn readFirmwareEvidence(self: *NativeDriver) !void {
        self.progressStage(.firmware_confirmation);
        const collection_request = self.discovery.?.nextOfKind(.managers) orelse return error.UnsupportedProfileFirmwareUnavailable;
        try self.readDiscoveryResource(collection_request);
        const doc = self.discovery.?.find(collection_request.uri) orelse return error.UnsupportedProfileFirmwareUnavailable;
        if (!doc.resourceAvailable() or !doc.fieldAccepted("/Members")) return error.UnsupportedProfileFirmwareUnavailable;
        const collection = try redfish.parseCollection(self.discovery.?.arena.allocator(), self.discovery.?.origin, doc.*);
        if (collection.members.len != 1 or collection.next != null) return error.UnsupportedProfileIdentityAmbiguous;
        const manager_request = self.discovery.?.nextOfKind(.manager) orelse return error.UnsupportedProfileFirmwareUnavailable;
        try self.readDiscoveryResource(manager_request);
        try self.confirmFirmware();
    }

    fn selectTrustedProfile(self: *NativeDriver, root_doc: redfish.Document) !void {
        self.progressStage(.public_identity);
        // No password facade, session POST or OEM/WS route is touched until
        // the complete observed public identity matches reviewed evidence.
        const observed = try profile.publicIdentityFromRoot(true, root_doc.value);
        _ = try profile.detectPublicFamily(observed);
        if (observed.firmware.len == 0) {
            // OEM RedfishVersion is only a public compatibility observation,
            // never the actual FirmwareVersion. Avoid even the public asset
            // request if this independent identity component is unavailable.
            _ = try profile.detectPublicEvidenceFamily(observed);
            const digest = try self.hashPublicMaterial();
            self.selected = try svc.Owned(profile.Profile).init(self.allocator, try profile.selectPublicEvidence(observed, .{ .uri = profile.sugon_public_material_path, .sha256 = digest }));
            self.progressNote(.{ .code = .public_material_verified, .resource = .public_script });
            self.firmware_pending_verification = true;
        } else {
            self.selected = try svc.Owned(profile.Profile).init(self.allocator, try profile.selectPublic(observed));
            self.diagnostics.firmware_observed = true;
        }
        self.selection_ready = true;
        self.progressStage(.public_identity);
    }

    fn hashPublicMaterial(self: *NativeDriver) ![32]u8 {
        self.progressStage(.public_script);
        // Hash the exact reviewed path on this already-trusted origin. The
        // HTTP decoder owns at most one TLS read of script body at a time;
        // parsed bytes are wiped immediately, never executed or persisted.
        const limit = 16 * 1024 * 1024;
        var transaction = self.newTransaction(try self.build("GET", profile.sugon_public_material_path, &.{.{ .name = "Accept-Encoding", .value = "identity" }}, ""), 0);
        defer transaction.deinit();
        errdefer if (transaction.offset != 0 and !transaction.response.isDone()) {
            self.management_failed = true;
        };
        transaction.response.limits.body_bytes = limit;
        var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
        var total: usize = 0;
        var decoded: usize = 0;
        var headers_ready = false;
        var gzip: ?*anyopaque = null;
        defer zw_bmc_gzip_destroy(gzip);
        var gzip_ended = false;
        var output: [16 * 1024]u8 = undefined;
        defer std.crypto.secureZero(u8, &output);
        while (true) {
            const done = try self.stepTransaction(&self.management_channel.?, &transaction, false);
            if (!headers_ready and transaction.response.state != .headers) {
                self.progressResponse(.public_script, transaction.response.status, null);
                if (transaction.response.status != 200) return error.UnsupportedProfilePublicEvidenceUnavailable;
                if (transaction.response.headerCount("Content-Encoding") > 1) return error.UnsupportedProfilePublicEvidenceEncoding;
                if (transaction.response.header("Content-Encoding")) |encoding| {
                    if (std.ascii.eqlIgnoreCase(encoding, "gzip")) {
                        gzip = zw_bmc_gzip_create() orelse return error.OutOfMemory;
                    } else if (!std.ascii.eqlIgnoreCase(encoding, "identity")) return error.UnsupportedProfilePublicEvidenceEncoding;
                }
                headers_ready = true;
            }
            const body = transaction.response.body();
            total = std.math.add(usize, total, body.len) catch return error.BodyTooLarge;
            if (total > limit) return error.BodyTooLarge;
            if (gzip) |stream| {
                if (gzip_ended and body.len != 0) return error.InvalidPublicMaterialGzip;
                var offset: usize = 0;
                var drain = false;
                while (!gzip_ended and (offset != body.len or drain)) {
                    var consumed: usize = 0;
                    var produced: usize = 0;
                    const status = zw_bmc_gzip_step(stream, body[offset..].ptr, body.len - offset, &consumed, &output, output.len, &produced);
                    if (status < 0 or consumed > body.len - offset or produced > output.len) return error.InvalidPublicMaterialGzip;
                    offset += consumed;
                    decoded = std.math.add(usize, decoded, produced) catch return error.BodyTooLarge;
                    if (decoded > limit) return error.BodyTooLarge;
                    hash.update(output[0..produced]);
                    std.crypto.secureZero(u8, output[0..produced]);
                    if (status == 1) {
                        gzip_ended = true;
                        if (offset != body.len) return error.InvalidPublicMaterialGzip;
                    } else if (consumed == 0 and produced == 0) {
                        if (offset != body.len) return error.InvalidPublicMaterialGzip;
                        break;
                    }
                    drain = produced == output.len;
                }
            } else {
                decoded = std.math.add(usize, decoded, body.len) catch return error.BodyTooLarge;
                if (decoded > limit) return error.BodyTooLarge;
                hash.update(body);
            }
            std.crypto.secureZero(u8, transaction.response.body_buffer.items);
            transaction.response.body_buffer.clearRetainingCapacity();
            transaction.response.limits.body_bytes = limit - total;
            if (done) break;
            self.pause(2);
        }
        if (gzip != null and !gzip_ended) return error.InvalidPublicMaterialGzip;
        return hash.finalResult();
    }

    fn confirmFirmware(self: *NativeDriver) !void {
        self.progressStage(.firmware_confirmation);
        var count: usize = 0;
        for (self.discovery.?.resources.items) |resource| if (resource.kind == .manager) {
            count += 1;
            if (!resource.doc.resourceAvailable() or !resource.doc.fieldAccepted("/FirmwareVersion")) return error.UnsupportedProfileFirmwareUnavailable;
            const firmware = redfish.text(resource.doc.value, "FirmwareVersion") orelse return error.UnsupportedProfileFirmwareUnavailable;
            if (!std.mem.eql(u8, firmware, self.selected.value.evidence.firmware)) return error.UnsupportedProfileFirmwareMismatch;
        };
        if (count == 0) return error.UnsupportedProfileFirmwareUnavailable;
        if (count != 1) return error.UnsupportedProfileIdentityAmbiguous;
        self.firmware_pending_verification = false;
        self.diagnostics.firmware_observed = true;
        self.progressNote(.{ .code = .firmware_verified, .resource = .manager });
    }
    fn beginConsole(self: *NativeDriver) !controller.video.rfb.Authenticated {
        self.progressContext(.{ .method = .post, .path = .kvm_session, .phase = .request_send, .received_bytes = 0, .duration_ms = 0 });
        self.progressStage(.oem_session);
        var kvm_body = try auth.kvmLogin(self.allocator, self.evidence(), self.web_session.?, self.context.owner);
        defer kvm_body.deinit();
        var kvm_response = try self.createSessionRequest(profile.kvm_login_path, &.{.{ .name = "Content-Type", .value = "application/json" }}, kvm_body.bytes, &self.diagnostics.kvm_logout);
        kvm_body.clear();
        defer kvm_response.deinit();
        var kvm_doc = try redfish.Document.parse(self.allocator, profile.kvm_login_path, kvm_response.response.status, kvm_response.response.body(), null, timestamp() / std.time.ns_per_ms);
        defer kvm_doc.deinit();
        self.progressResponse(.kvm_session, kvm_doc.status, kvm_doc.validity);
        self.kvm_session = switch (self.schema.value.source) {
            .response_header => blk: {
                if (kvm_response.response.headerCount("X-Auth-Token") != 1) return error.InvalidKvmSessionHeaders;
                break :blk try auth.acceptKvmSessionHeader(self.allocator, self.evidence(), self.context.owner, kvm_doc, kvm_response.response.header("X-Auth-Token"), self.schema.value.id);
            },
            .synthetic_json => try auth.acceptKvmSession(self.allocator, self.evidence(), self.context.owner, kvm_doc, self.schema.value.token.?, self.schema.value.id),
        };
        self.diagnostics.kvm_logout = .awaiting;
        self.progressNote(.{ .code = .kvm_authenticated, .resource = .kvm_session });
        if (self.selected.value.evidence.kvm_logout) |rule| {
            const location = if (kvm_response.response.headerCount("Location") == 1) kvm_response.response.header("Location") else null;
            const id = if (self.kvm_session.?.id) |id| id.bytes else "";
            const uri = profile.logoutReference(self.allocator, self.origin(), rule, location, id) catch null;
            if (uri) |path| self.kvm_session.?.verified_logout_uri = .{ .allocator = self.allocator, .bytes = path };
        }
        self.progressContext(.{ .channel = .video, .path = .websocket, .phase = .connect });
        self.progressStage(.websocket_upgrade);
        if (self.pair.video == null) self.pair.video = try self.pair.transport.openTcpStream(self.pair.destination);
        self.video_channel = .{ .client = try tls.Client.init(self.pair.video.?.fd, self.origin().host) };
        try self.handshake(&self.video_channel.?);
        self.progressStage(.websocket_upgrade);
        const upgrade = try ws.Upgrade.init(self.kvm_session.?.token.bytes);
        var upgrade_request: auth.Secret = .{ .allocator = self.allocator, .bytes = try upgrade.buildRequest(self.allocator, self.origin(), profile.video_path) };
        var transaction = self.newTransaction(upgrade_request, 0);
        // Ownership moved into transaction; never retain the token request.
        upgrade_request.bytes = &.{};
        defer transaction.deinit();
        while (!try self.stepTransaction(&self.video_channel.?, &transaction, false)) self.pause(2);
        self.progressResponse(.websocket, transaction.response.status, null);
        try upgrade.validate(&transaction.response);
        self.diagnostics.video_upgraded = true;
        self.progressNote(.{ .code = .websocket_ready, .resource = .websocket });
        return .{ .tls_trusted = true, .web_authenticated = true, .oem_authenticated = true };
    }
    fn acquirePassword(self: *NativeDriver) !auth.Secret {
        try self.check();
        if (self.context.secrets) |facade| {
            var acquired = try facade.acquireDefault(self.context.operation, self.cancel);
            switch (acquired) {
                .lease => |*lease| {
                    defer lease.deinit();
                    return auth.Secret.init(self.allocator, try lease.defaultBytes(self.context.owner, self.context.operation));
                },
                .missing => {},
                .cancelled => return error.Cancelled,
                .denied => return error.SecretDenied,
                .ungranted => return error.SecretUngranted,
                .invalid_reference => return error.InvalidCredentialReference,
                .unavailable => return error.SecretUnavailable,
            }
        }
        if (self.config.value.credential_ref) |reference| {
            const facade = self.context.secrets orelse return error.MissingSecretFacade;
            var acquired = try facade.acquire(self.context.operation, reference, self.cancel);
            switch (acquired) {
                .lease => |*lease| {
                    defer lease.deinit();
                    return auth.Secret.init(self.allocator, try lease.bytes(self.context.owner, self.context.operation, reference));
                },
                .missing => {},
                .cancelled => return error.Cancelled,
                .denied => return error.SecretDenied,
                .ungranted => return error.SecretUngranted,
                .invalid_reference => return error.InvalidCredentialReference,
                .unavailable => return error.SecretUnavailable,
            }
        }
        const callbacks = self.callbacks orelse return error.PasswordReplyUnavailable;
        const reply = callbacks.password_reply orelse return error.PasswordReplyUnavailable;
        self.progressStage(.waiting_credentials);
        var password = try reply(callbacks.context, self.context.owner, self.context.operation, self.cancel, self.allocator);
        errdefer password.deinit();
        try self.check();
        return password;
    }
    fn handshake(self: *NativeDriver, channel: *Channel) !void {
        const video_channel = channel != &self.management_channel.?;
        const handshake_stage: progress.Stage = if (video_channel) .video_tls_handshake else .tls_handshake;
        self.progressContext(.{ .channel = if (video_channel) .video else .management, .phase = .tls_handshake });
        self.progressStage(handshake_stage);
        var deadline = timestamp() + stage_timeout_ns;
        while (true) {
            try self.check();
            if (timestamp() >= deadline) return error.TlsTimeout;
            switch (try channel.client.handshakeStep()) {
                .ready => {
                    self.progressNote(.{ .code = .tls_trusted, .resource = if (channel == &self.management_channel.?) .management_route else .video_route });
                    return;
                },
                .want_read, .want_write => self.pause(2),
                .closed => return error.TlsClosed,
                .needs_trust => {
                    const facade = self.context.trust.tls orelse return error.MissingTlsTrustFacade;
                    const chain = try channel.client.peerChain(self.allocator);
                    defer self.allocator.free(chain);
                    var evaluated = try facade.evaluate(self.context.operation, .{ .host = self.origin().host, .port = self.origin().port }, chain);
                    if (evaluated == .challenge) {
                        const callbacks = self.callbacks orelse return error.TrustReplyUnavailable;
                        const reply = callbacks.trust_reply orelse return error.TrustReplyUnavailable;
                        self.progressStage(if (video_channel) .waiting_video_certificate else .waiting_certificate);
                        const choice = try reply(callbacks.context, evaluated.challenge, self.cancel);
                        try self.check();
                        evaluated = try facade.answer(evaluated.challenge, choice);
                        self.progressStage(handshake_stage);
                        // Human challenge time is not network timeout time.
                        deadline = timestamp() + stage_timeout_ns;
                    }
                    if (evaluated != .trusted) {
                        try channel.client.authorizeTrust(false);
                        return error.TrustRejected;
                    }
                    try channel.client.authorizeTrust(true);
                    if (channel == &self.management_channel.?) {
                        // Retain only the already-authorized identity for this
                        // attempt's bounded cleanup, even after owner revoke.
                        self.cleanup_peer_leaf = trust.fingerprint(chain[0]);
                        self.cleanup_peer_chain = trust.chainFingerprint(chain);
                    }
                },
            }
        }
    }
    fn publishDiscovery(self: *NativeDriver) !void {
        const discovery = &self.discovery.?;
        var diagnostic: DiscoveryDiagnostics = .{};
        defer {
            self.progressDiscovery(diagnostic);
            self.discovery_diagnostics = diagnostic;
            self.discovery_published.store(true, .release);
        }
        for (discovery.resources.items) |resource| switch (resource.kind) {
            .manager => diagnostic.manager_count += 1,
            .system => diagnostic.system_count += 1,
            else => {},
        };
        if (self.management_discovery_error) |err| {
            diagnostic.management_discovery_complete = false;
            diagnostic.management_discovery_error = err;
            diagnostic.mapping_error = error.DiscoveryIncomplete;
            diagnostic.management_target_error = error.DiscoveryIncomplete;
            diagnostic.readonly_rejection = .readonly_discovery_incomplete;
            return;
        }
        var chosen: ?[]const u8 = null;
        var count: usize = 0;
        for (discovery.resources.items) |resource| if (resource.kind == .manager) {
            discovery.proveKvmMapping(resource.doc.uri, profile.video_path, self.selected.value.evidence.oem_handshake_verified) catch |err| {
                diagnostic.mapping_error = err;
                diagnostic.mapping_rejection = if (err == error.MappingAmbiguous) .ambiguous_mapping else self.mappingRejection(resource.doc, &diagnostic);
                continue;
            };
            chosen = resource.doc.uri;
            count += 1;
        };
        if (count != 1) {
            discovery.mapping_system = null;
            discovery.mapping_manager = null;
            diagnostic.mapping_error = if (count > 1) error.MappingAmbiguous else diagnostic.mapping_error orelse error.MappingUnverified;
            if (count > 1) diagnostic.mapping_rejection = .ambiguous_mapping;
        } else {
            try discovery.proveKvmMapping(chosen.?, profile.video_path, true);
            diagnostic.mapping_verified = true;
            diagnostic.mapping_error = null;
            diagnostic.mapping_rejection = null;
            if (discovery.find(discovery.mapping_system.?)) |system| {
                diagnostic.mapping_system_status = system.status;
                diagnostic.mapping_system_validity = system.validity;
            }
            self.diagnostics.system_mapping_verified = true;
        }
        discovery.proveManagementTarget() catch |err| {
            diagnostic.management_target_error = err;
            if (try self.readOnlyCollectionSystem(&diagnostic)) |selected| {
                try self.publishManagementSnapshots(selected);
                diagnostic.readonly_system_projection = true;
            }
            return;
        };
        diagnostic.management_target_verified = true;
        if (discovery.proveResourceAssociation()) |_| {
            diagnostic.resource_association_verified = true;
            diagnostic.resource_association_method = .reviewed_public_ids_and_chassis;
        } else |_| {}
        var capability: svc.Capability = .{ .binding_generation = self.context.owner.generation };
        if (self.callbacks) |callbacks| if (callbacks.capability) |derive| {
            capability = try derive(callbacks.context, discovery);
        };
        const selected = try discovery.system(discovery.management_system.?, capability);
        try self.publishManagementSnapshots(selected);
    }
    fn publishManagementSnapshots(self: *NativeDriver, selected: redfish.ParsedSystem) !void {
        // Availability means a valid observed read exists. Mapping remains a
        // separate capability; no absent or partial field inherits validity.
        self.diagnostics.management_available = (selected.power.state.value != null and selected.power.state.evidence.validity == .valid) or
            (selected.boot.state.enabled != null and selected.boot.enabled_evidence.validity == .valid) or
            (selected.boot.state.target != null and selected.boot.target_evidence.validity == .valid) or
            (selected.boot.state.mode != null and selected.boot.mode_evidence.validity == .valid);
        if (!self.diagnostics.management_available) self.progressNote(.{ .code = .management_fields_unavailable, .resource = .system });
        if (self.adapter) |adapter| try adapter.setSnapshots(selected.power, selected.boot, true);
    }
    /// A corroborated resource association, or a unique collection member,
    /// supplies observed read-only values. Property errors and object
    /// diagnostics stay separate. This never derives a grant or KVM mapping.
    fn readOnlyCollectionSystem(self: *NativeDriver, diagnostic: *DiscoveryDiagnostics) !?redfish.ParsedSystem {
        const discovery = &self.discovery.?;
        if (discovery.cursor != discovery.queue.items.len or discovery.outstanding.items.len != 0) {
            diagnostic.readonly_rejection = .readonly_discovery_incomplete;
            return null;
        }
        const association: ?redfish.ResourceAssociation = discovery.proveResourceAssociation() catch null;
        if (association != null) {
            diagnostic.resource_association_verified = true;
            diagnostic.resource_association_method = .reviewed_public_ids_and_chassis;
        }
        var member_uri: ?[]const u8 = if (association) |value| value.system_uri else null;
        var collections: usize = 0;
        for (discovery.resources.items) |resource| if (resource.kind == .systems) {
            collections += 1;
            diagnostic.readonly_collection_count = collections;
            diagnostic.readonly_collection_status = resource.doc.status;
            diagnostic.readonly_collection_validity = resource.doc.validity;
            if (!resource.doc.resourceAvailable() or !resource.doc.fieldAccepted("/Members")) {
                diagnostic.readonly_rejection = .readonly_collection_rejected;
                return null;
            }
            const collection = redfish.parseCollection(discovery.arena.allocator(), discovery.origin, resource.doc) catch |err| {
                diagnostic.readonly_rejection = .readonly_collection_invalid;
                return err;
            };
            for (collection.members) |uri| {
                diagnostic.readonly_member_count += 1;
                if (association == null) {
                    // Without an explicit association, multiple entries or
                    // aliases cannot select one source by their position.
                    if (member_uri != null) {
                        diagnostic.readonly_rejection = .readonly_members_not_single;
                        return null;
                    }
                    member_uri = uri;
                }
            }
        };
        if (collections == 0) {
            diagnostic.readonly_rejection = .readonly_collection_missing;
            return null;
        }
        const uri = member_uri orelse {
            diagnostic.readonly_rejection = .readonly_members_not_single;
            return null;
        };
        const doc = discovery.find(uri) orelse {
            diagnostic.readonly_rejection = .readonly_member_missing;
            return null;
        };
        diagnostic.readonly_system_status = doc.status;
        diagnostic.readonly_system_validity = doc.validity;
        if (!doc.resourceAvailable()) {
            diagnostic.readonly_rejection = .readonly_member_rejected;
            return null;
        }
        const capability: svc.Capability = .{ .binding_generation = self.context.owner.generation, .system_mapping_verified = false, .write_granted = false, .write_requestable = false, .secondary_auth = .unknown };
        var selected = discovery.system(uri, capability) catch |err| {
            diagnostic.readonly_rejection = .readonly_system_invalid;
            return err;
        };
        diagnostic.readonly_system_identity_present = selected.power.system_identity.len != 0;
        if (!diagnostic.readonly_system_identity_present) {
            diagnostic.readonly_rejection = .readonly_identity_missing;
            return null;
        }
        // Keep these denials explicit, independent of any future Discovery
        // capability enrichment, and expose no inferred Boot write target.
        selected.power.capability = capability;
        selected.boot.capability = capability;
        selected.boot.write_uri = null;
        return selected;
    }
    fn progressStage(self: *NativeDriver, stage: progress.Stage) void {
        if (self.connection_progress) |tracker| tracker.setStage(stage);
    }
    fn progressNote(self: *NativeDriver, detail: progress.Detail) void {
        if (self.connection_progress) |tracker| tracker.note(detail);
    }
    fn progressContext(self: *NativeDriver, context: progress.Context) void {
        if (self.connection_progress) |tracker| tracker.setContext(context);
    }
    fn progressResponse(self: *NativeDriver, resource: progress.Resource, status: u16, validity: ?svc.Validity) void {
        self.progressNote(.{ .resource = resource, .http_status = status, .validity = if (validity) |v| @fromBackingInt(@intCast(@backingInt(v))) else null });
    }
    fn progressDiscovery(self: *NativeDriver, diagnostic: DiscoveryDiagnostics) void {
        if (diagnostic.mapping_rejection) |rejection| self.progressNote(.{ .code = switch (rejection) {
            .manager_document_rejected => .mapping_manager_document_rejected,
            .manager_servers_not_single => .mapping_manager_servers_not_single,
            .system_missing => .mapping_system_missing,
            .system_document_rejected => .mapping_system_document_rejected,
            .system_reverse_link_missing => .mapping_system_reverse_link_missing,
            .system_identity_missing => .mapping_system_identity_missing,
            .invalid_relationship => .mapping_invalid_relationship,
            .profile_evidence_unverified => .mapping_profile_evidence_unverified,
            .ambiguous_mapping => .mapping_ambiguous,
        }, .resource = .system, .http_status = diagnostic.mapping_system_status, .validity = if (diagnostic.mapping_system_validity) |v| @fromBackingInt(@intCast(@backingInt(v))) else null });
        if (diagnostic.mapping_verified) self.progressNote(.{ .code = .mapping_verified, .resource = .system });
        if (diagnostic.readonly_rejection) |code| self.progressNote(.{ .code = code, .resource = .systems_collection, .http_status = diagnostic.readonly_collection_status, .validity = if (diagnostic.readonly_collection_validity) |v| @fromBackingInt(@intCast(@backingInt(v))) else null, .count = @intCast(@min(diagnostic.readonly_member_count, std.math.maxInt(u16))) });
        if (diagnostic.readonly_system_status) |status| self.progressResponse(.system, status, diagnostic.readonly_system_validity);
        if (diagnostic.readonly_system_projection) self.progressNote(.{ .code = .readonly_projection_available, .resource = .system });
    }
    /// Diagnose an already-rejected proof without changing Discovery's rules.
    /// This static stage summary must never include device links or identities.
    fn mappingRejection(self: *NativeDriver, manager: redfish.Document, diagnostic: *DiscoveryDiagnostics) MappingRejection {
        if (!self.selected.value.evidence.oem_handshake_verified) return .profile_evidence_unverified;
        if (!manager.resourceAvailable()) return .manager_document_rejected;
        const links = redfish.member(manager.value, "Links") orelse return .manager_servers_not_single;
        const managed = redfish.member(links, "ManagerForServers") orelse return .manager_servers_not_single;
        if (managed != .array or managed.array.items.len != 1) return .manager_servers_not_single;
        const reference = redfish.text(managed.array.items[0], "@odata.id") orelse return .invalid_relationship;
        const discovery = &self.discovery.?;
        const uri = redfish.resourceUri(self.allocator, discovery.origin, reference) catch return .invalid_relationship;
        defer self.allocator.free(uri);
        const system = discovery.find(uri) orelse return .system_missing;
        diagnostic.mapping_system_status = system.status;
        diagnostic.mapping_system_validity = system.validity;
        if (!system.resourceAvailable()) return .system_document_rejected;
        const parsed = redfish.parseSystem(discovery.arena.allocator(), discovery.origin, system.*) catch return .invalid_relationship;
        if (!svc.contains(parsed.managed_by, manager.uri)) return .system_reverse_link_missing;
        if (parsed.power.system_identity.len == 0) return .system_identity_missing;
        return .invalid_relationship;
    }
    fn newTransaction(self: *NativeDriver, request_bytes: auth.Secret, sequence: u64) Transaction {
        const started = timestamp();
        const context = requestContext(request_bytes.bytes);
        self.progressContext(context);
        return .{ .request = request_bytes, .response = http.ResponseParser.init(self.allocator, .{}), .deadline_ns = started + stage_timeout_ns, .started_ns = started, .context = context, .sequence = sequence };
    }
    fn build(self: *NativeDriver, method: []const u8, uri: []const u8, extra: []const http.Header, body: []const u8) !auth.Secret {
        return self.buildAuthorized(method, uri, extra, body, if (self.web_session) |session| session.token.bytes else null);
    }
    fn buildAuthorized(self: *NativeDriver, method: []const u8, uri: []const u8, extra: []const http.Header, body: []const u8, token: ?[]const u8) !auth.Secret {
        const path = try self.origin().validateReference(uri);
        var headers: [16]http.Header = undefined;
        if (extra.len > headers.len - 4) return error.TooManyHeaders;
        var count: usize = 0;
        for (extra) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "From")) {
                if (!std.mem.eql(u8, header.value, auth.WebLogin.from)) return error.InvalidWebContextHeader;
                continue;
            }
            if (std.ascii.eqlIgnoreCase(header.name, "X-Requested-With")) {
                if (!std.mem.eql(u8, header.value, auth.WebLogin.requested_with)) return error.InvalidWebContextHeader;
                continue;
            }
            if (std.ascii.eqlIgnoreCase(header.name, "X-Auth-Token")) return error.ReservedAuthenticationHeader;
            headers[count] = header;
            count += 1;
        }
        // The vendor SPA installs these defaults for every REST transaction,
        // including discovery, OEM KVM creation and both session DELETEs.
        headers[count] = .{ .name = "From", .value = auth.WebLogin.from };
        count += 1;
        headers[count] = .{ .name = "X-Requested-With", .value = auth.WebLogin.requested_with };
        count += 1;
        headers[count] = .{ .name = "Accept", .value = "application/json" };
        count += 1;
        if (token) |value| {
            headers[count] = .{ .name = "X-Auth-Token", .value = value };
            count += 1;
        }
        return .{ .allocator = self.allocator, .bytes = try http.buildRequest(self.allocator, method, self.origin(), path, headers[0..count], body) };
    }
    fn request(self: *NativeDriver, method: []const u8, uri: []const u8, headers: []const http.Header, body: []const u8) !Transaction {
        return self.requestInternal(method, uri, headers, body, null);
    }
    fn createSessionRequest(self: *NativeDriver, uri: []const u8, headers: []const http.Header, body: []const u8, release: *RemoteRelease) !Transaction {
        return self.requestInternal("POST", uri, headers, body, release);
    }
    fn requestInternal(self: *NativeDriver, method: []const u8, uri: []const u8, headers: []const http.Header, body: []const u8, creation: ?*RemoteRelease) !Transaction {
        var transaction = self.newTransaction(try self.build(method, uri, headers, body), 0);
        errdefer {
            // A partially/fully dispatched create can succeed even when its
            // response or session token is lost. Never call that not_created.
            if (creation) |release| if (transaction.offset != 0) {
                release.* = .unknown;
            };
            if (transaction.offset != 0 and !transaction.response.isDone()) self.management_failed = true;
            transaction.deinit();
        }
        while (!try self.stepTransaction(&self.management_channel.?, &transaction, false)) self.pause(2);
        if (creation) |release| if (transaction.response.status >= 200 and transaction.response.status < 300) {
            release.* = .unknown;
        };
        return transaction;
    }
    fn stepTransaction(self: *NativeDriver, channel: *Channel, transaction: *Transaction, closing: bool) !bool {
        transaction.context.channel = if (self.video_channel != null and channel == &self.video_channel.?) .video else .management;
        self.progressTransaction(transaction);
        if (!closing) try self.check();
        if (timestamp() >= transaction.deadline_ns) return error.HttpTimeout;
        if (transaction.offset != transaction.request.bytes.len) {
            switch (try channel.client.write(transaction.request.bytes[transaction.offset..])) {
                .bytes => |n| {
                    if (n == 0) return error.TlsClosed;
                    transaction.offset += n;
                    if (transaction.offset == transaction.request.bytes.len) transaction.request.clear();
                    self.progressTransaction(transaction);
                },
                .progress => |state| return switch (state) {
                    .want_read, .want_write => false,
                    else => error.TlsClosed,
                },
            }
            if (transaction.offset != transaction.request.bytes.len) return false;
        }
        if (channel.start == channel.end) {
            channel.start = 0;
            channel.end = 0;
            switch (try channel.client.read(&channel.pending)) {
                .bytes => |n| {
                    if (n == 0) {
                        try transaction.response.finishEof();
                        return transaction.response.isDone();
                    }
                    channel.end = n;
                },
                .progress => |state| switch (state) {
                    .want_read, .want_write => return false,
                    .closed => {
                        try transaction.response.finishEof();
                        return transaction.response.isDone();
                    },
                    else => return error.InvalidTlsState,
                },
            }
        }
        const body_before = transaction.response.body().len;
        channel.start += try transaction.response.feed(channel.pending[channel.start..channel.end]);
        transaction.received_bytes += transaction.response.body().len - body_before;
        self.progressTransaction(transaction);
        if (channel.start == channel.end) {
            channel.start = 0;
            channel.end = 0;
        }
        return transaction.response.isDone();
    }
    fn progressTransaction(self: *NativeDriver, transaction: *Transaction) void {
        transaction.context.phase = if (transaction.offset != transaction.request.bytes.len)
            .request_send
        else if (transaction.response.isDone())
            .response_validate
        else if (transaction.response.state == .headers)
            .response_headers
        else
            .response_body;
        transaction.context.received_bytes = transaction.received_bytes;
        transaction.context.http_status = if (transaction.response.status != 0) transaction.response.status else null;
        transaction.context.duration_ms = (timestamp() -| transaction.started_ns) / std.time.ns_per_ms;
        self.progressContext(transaction.context);
    }
    fn read(context: *anyopaque, out: []u8) !usize {
        const self = cast(context);
        if (self.probe_only) return error.ProbeConsoleForbidden;
        try self.requireWorker();
        try self.check();
        if (self.aborted or !self.diagnostics.video_upgraded) return error.VideoClosed;
        const channel = &self.video_channel.?;
        const pending = channel.take(out);
        if (pending != 0) return pending;
        return switch (try channel.client.read(out)) {
            .bytes => |n| n,
            .progress => |state| switch (state) {
                .want_read, .want_write => error.WouldBlock,
                .closed => 0,
                else => error.InvalidTlsState,
            },
        };
    }
    fn write(context: *anyopaque, bytes: []const u8) !usize {
        const self = cast(context);
        if (self.probe_only) return error.ProbeConsoleForbidden;
        try self.requireWorker();
        try self.check();
        if (self.aborted or !self.diagnostics.video_upgraded) return error.VideoClosed;
        self.video_write_pending = true;
        return switch (try self.video_channel.?.client.write(bytes)) {
            .bytes => |n| blk: {
                self.video_write_pending = n != bytes.len;
                break :blk n;
            },
            .progress => |state| switch (state) {
                .want_read, .want_write => error.WouldBlock,
                else => error.VideoClosed,
            },
        };
    }
    fn managementIo(context: *anyopaque, outbound: ?power.Outbound) !?power.Completion {
        const self = cast(context);
        if (self.probe_only) return error.ProbeManagementForbidden;
        if (outbound) |work| if (self.management_policy == .read_only and work.method != .get) return error.ManagementReadOnly;
        try self.requireWorker();
        if (self.completed) |*value| value.deinit();
        self.completed = null;
        if (outbound) |work| {
            if (self.transaction != null) return error.ManagementBusy;
            if (work.operation.owner != .session or !work.operation.owner.session.eql(self.context.owner)) return error.StaleManagementOwner;
            // buildRequest immediately copies URI/body/If-Match/AUTHKEY/token.
            // Engine's borrowed Outbound never survives this call.
            if (self.management_failed or self.aborted or self.cancel.load(.acquire)) return .{ .sequence = work.sequence, .transport_error = true };
            var headers: [3]http.Header = undefined;
            var count: usize = 0;
            if (work.method != .get) {
                headers[count] = .{ .name = "Content-Type", .value = "application/json" };
                count += 1;
            }
            if (work.if_match) |tag| {
                headers[count] = .{ .name = "If-Match", .value = tag };
                count += 1;
            }
            if (work.authkey) |key| {
                headers[count] = .{ .name = "AUTHKEY", .value = key };
                count += 1;
            }
            self.transaction = self.newTransaction(try self.build(switch (work.method) {
                .get => "GET",
                .post => "POST",
                .patch => "PATCH",
            }, work.uri, headers[0..count], work.body), work.sequence);
        }
        if (self.transaction) |*transaction| {
            const done = self.stepTransaction(&self.management_channel.?, transaction, false) catch {
                const sequence = transaction.sequence;
                transaction.deinit();
                self.transaction = null;
                self.management_failed = true;
                self.diagnostics.management_available = false;
                return .{ .sequence = sequence, .transport_error = true };
            };
            if (done) {
                self.completed = transaction.*;
                self.transaction = null;
                const response = &self.completed.?.response;
                if (response.status == 401 or response.status == 403) self.diagnostics.management_available = false;
                const retry = if (response.header("Retry-After")) |text| (std.fmt.parseInt(u64, text, 10) catch 0) *| 1000 else null;
                return .{ .sequence = self.completed.?.sequence, .status = response.status, .body = response.body(), .etag = response.header("ETag"), .location = response.header("Location"), .retry_after_ms = retry };
            }
        }
        return null;
    }
    fn abort(context: *anyopaque) void {
        const self = cast(context);
        self.requireWorker() catch return;
        self.aborted = true;
        self.abortIncompleteVideoFrame();
    }
    fn abortIncompleteVideoFrame(self: *NativeDriver) void {
        if (!self.video_write_pending or self.video_channel == null) return;
        // The peer is still inside the old WS payload. Any Close would become
        // input bytes, and WANT_WRITE cannot accept a changed TLS buffer.
        self.video_channel.?.client.deinit();
        std.crypto.secureZero(u8, &self.video_channel.?.pending);
        self.video_channel = null;
        if (self.pair.video) |*stream| stream.close();
        self.pair.video = null;
        self.logout_diagnostics.websocket_close = .incomplete_frame_aborted;
        self.logout_diagnostics.websocket_failure = error.IncompleteVideoFrame;
        self.progressNote(.{ .code = .websocket_close_unconfirmed, .resource = .websocket });
    }
    fn logout(self: *NativeDriver, uri: []const u8, token: []const u8, diagnostic: *LogoutAttempt) bool {
        // Each recorded own session is deleted at most once. Video can outlive
        // an idle HTTPS keepalive, so its two logouts use independent fresh TLS
        // channels; a possibly dispatched DELETE is never retried.
        diagnostic.management_failed_at_entry = self.management_failed;
        diagnostic.transport_done_at_entry = self.pair.transport.done.load(.acquire);
        defer diagnostic.transport_done_at_exit = self.pair.transport.done.load(.acquire);
        const deadline_ns = timestamp() + std.time.ns_per_s;
        const fresh = !self.probe_only and (self.diagnostics.video_upgraded or self.management_failed);
        if (fresh) {
            diagnostic.fresh_connection = true;
            self.openLogoutChannel(deadline_ns) catch |err| {
                diagnostic.stage = .connection_failed;
                diagnostic.failure = err;
                return false;
            };
        }
        defer if (fresh) self.closeManagementChannel();
        if (self.management_failed or self.management_channel == null) {
            diagnostic.stage = .management_unavailable;
            return false;
        }
        var transaction = self.newTransaction(self.buildAuthorized("DELETE", uri, &.{}, "", token) catch |err| {
            diagnostic.stage = .request_build_failed;
            diagnostic.failure = err;
            return false;
        }, 0);
        defer transaction.deinit();
        defer diagnostic.request_dispatched = transaction.offset != 0;
        // Cleanup remains bounded, and cannot resend a preceding mutation.
        transaction.deadline_ns = deadline_ns;
        while (!(self.stepTransaction(&self.management_channel.?, &transaction, true) catch |err| {
            // An incomplete response poisons this HTTP byte stream. Do not
            // parse it as the response to a subsequent session DELETE.
            self.management_failed = true;
            diagnostic.stage = .transaction_failed;
            diagnostic.failure = err;
            return false;
        })) self.pause(2);
        diagnostic.http_status = transaction.response.status;
        var doc = redfish.Document.parse(self.allocator, uri, transaction.response.status, transaction.response.body(), null, timestamp() / std.time.ns_per_ms) catch |err| {
            diagnostic.stage = .response_parse_failed;
            diagnostic.failure = err;
            return false;
        };
        defer doc.deinit();
        diagnostic.response_validity = doc.validity;
        // 202 acknowledges work, and does not prove session deletion finished.
        if ((doc.status == 200 or doc.status == 204) and (doc.accepted() or self.sugonSessionDeleteSuccess(doc))) {
            diagnostic.stage = .confirmed;
            return true;
        }
        diagnostic.stage = .response_rejected;
        return false;
    }
    fn closeManagementChannel(self: *NativeDriver) void {
        if (self.management_channel) |*channel| {
            channel.client.deinit();
            std.crypto.secureZero(u8, &channel.pending);
            self.management_channel = null;
        }
        if (self.pair.management) |*stream| stream.close();
        self.pair.management = null;
    }
    fn reopenManagementChannel(self: *NativeDriver) !void {
        try self.check();
        self.closeManagementChannel();
        self.progressContext(.{ .phase = .connect });
        self.pair.management = try self.pair.transport.openTcpStream(self.pair.destination);
        errdefer self.closeManagementChannel();
        self.management_channel = .{ .client = try tls.Client.init(self.pair.management.?.fd, self.origin().host) };
        try self.handshakePinnedManagement(timestamp() + stage_timeout_ns, false);
    }
    fn openLogoutChannel(self: *NativeDriver, deadline_ns: u64) !void {
        self.closeManagementChannel();
        // This capability has no destination argument, cannot start/reconnect
        // SSH and admits at most two original-endpoint streams after cancel.
        self.pair.management = try self.pair.transport.openCleanupTcpStream();
        errdefer self.closeManagementChannel();
        self.management_channel = .{ .client = try tls.Client.init(self.pair.management.?.fd, self.origin().host) };
        try self.handshakePinnedManagement(deadline_ns, true);
    }
    fn handshakePinnedManagement(self: *NativeDriver, deadline_ns: u64, closing: bool) !void {
        self.progressContext(.{ .phase = .tls_handshake });
        const channel = &self.management_channel.?;
        while (true) {
            if (!closing) try self.check();
            if (timestamp() >= deadline_ns) return error.TlsTimeout;
            switch (try channel.client.handshakeStep()) {
                .ready => {
                    self.management_failed = false;
                    return;
                },
                .want_read, .want_write => self.pause(2),
                .closed => return error.TlsClosed,
                .needs_trust => {
                    const leaf = self.cleanup_peer_leaf orelse return error.CleanupTrustUnavailable;
                    const expected_chain = self.cleanup_peer_chain orelse return error.CleanupTrustUnavailable;
                    const chain = try channel.client.peerChain(self.allocator);
                    defer self.allocator.free(chain);
                    const actual_leaf = trust.fingerprint(chain[0]);
                    const actual_chain = trust.chainFingerprint(chain);
                    if (!std.mem.eql(u8, &leaf, &actual_leaf) or !std.mem.eql(u8, &expected_chain, &actual_chain)) {
                        channel.client.authorizeTrust(false) catch {};
                        return if (closing) error.CleanupPeerChanged else error.ManagementPeerChanged;
                    }
                    // No new prompt, trust exception, password or application
                    // byte may precede this exact original peer comparison.
                    try channel.client.authorizeTrust(true);
                },
            }
        }
    }
    fn sugonSessionDeleteSuccess(self: *NativeDriver, doc: redfish.Document) bool {
        // This observed vendor envelope exception belongs only to the two
        // already-recorded session DELETEs. Normal management/write responses
        // keep redfish.Document.accepted()/hasBodyError semantics unchanged.
        if (doc.status != 200 or self.selected.value.id != .sugon_1_80_oem_rfb or !std.mem.eql(u8, self.selected.value.evidence.firmware, "1.80")) return false;
        const failure = redfish.member(doc.value, "error") orelse return false;
        if (failure != .object or !std.mem.eql(u8, redfish.text(failure, "code") orelse return false, "Base.1.19.Success")) return false;
        const messages = redfish.member(failure, "@Message.ExtendedInfo") orelse return false;
        if (messages != .array or messages.array.items.len == 0 or messages.array.items.len > 64) return false;
        for (messages.array.items) |message| {
            if (message != .object or !std.mem.eql(u8, redfish.text(message, "MessageId") orelse return false, "Base.1.19.Success") or !std.mem.eql(u8, redfish.text(message, "Severity") orelse return false, "OK")) return false;
        }
        return onlySuccessMessages(doc.value, 0);
    }
    fn cleanup(context: *anyopaque) controller.Cleanup {
        const self = cast(context);
        self.requireWorker() catch return .unknown;
        if (self.transport_destroyed) return .released;
        if (!self.cleanup_started) {
            self.progressStage(.cleanup);
            self.cleanup_started = true;
            self.aborted = true;
            self.abortIncompleteVideoFrame();
            if (self.transaction) |*value| {
                value.deinit();
                self.transaction = null;
                self.management_failed = true;
            }
            if (self.completed) |*value| {
                value.deinit();
                self.completed = null;
            }
            // Send the owned WebSocket close before deleting its session.
            // This cleanup-only close remains bounded after ordinary IO has
            // been cancelled; no RFB/control/input bytes are admitted here.
            if (self.diagnostics.video_upgraded and self.video_channel != null) {
                const close_frame = ws.clientFrame(self.allocator, .close, true, &.{ 3, 232 }) catch |err| blk: {
                    self.logout_diagnostics.websocket_close = .build_failed;
                    self.logout_diagnostics.websocket_failure = err;
                    break :blk null;
                };
                if (close_frame) |bytes| {
                    var offset: usize = 0;
                    const deadline = timestamp() + 250 * std.time.ns_per_ms;
                    self.logout_diagnostics.websocket_close = .deadline;
                    while (offset < bytes.len and timestamp() < deadline) {
                        switch (self.video_channel.?.client.write(bytes[offset..]) catch |err| {
                            self.logout_diagnostics.websocket_close = .transport_failed;
                            self.logout_diagnostics.websocket_failure = err;
                            break;
                        }) {
                            .bytes => |n| {
                                if (n == 0) {
                                    self.logout_diagnostics.websocket_close = .transport_failed;
                                    self.logout_diagnostics.websocket_failure = error.TlsClosed;
                                    break;
                                }
                                offset += n;
                            },
                            .progress => |state| switch (state) {
                                .want_read, .want_write => self.pause(2),
                                else => {
                                    self.logout_diagnostics.websocket_close = .transport_failed;
                                    self.logout_diagnostics.websocket_failure = error.TlsClosed;
                                    break;
                                },
                            },
                        }
                    }
                    if (offset == bytes.len) self.logout_diagnostics.websocket_close = .frame_sent;
                    self.allocator.free(bytes);
                }
                self.progressNote(.{ .code = if (self.logout_diagnostics.websocket_close == .frame_sent) .websocket_close_sent else .websocket_close_unconfirmed, .resource = .websocket });
            }
            if (self.kvm_session) |*session| {
                self.logout_diagnostics.kvm.stage = .own_reference_unavailable;
                self.diagnostics.kvm_logout = if (session.verified_logout_uri) |uri| if (self.logout(uri.bytes, session.token.bytes, &self.logout_diagnostics.kvm)) .confirmed else .unknown else .unknown;
                self.progressLogout(.kvm_session, self.diagnostics.kvm_logout, self.logout_diagnostics.kvm);
                session.deinit();
                self.kvm_session = null;
            }
            if (self.web_session) |*session| {
                self.logout_diagnostics.web.stage = .own_reference_unavailable;
                const uri = if (self.selected.value.evidence.web_logout) |rule| profile.logoutReference(self.allocator, self.origin(), rule, session.location.bytes, session.id.bytes) catch null else null;
                self.diagnostics.web_logout = if (uri) |path| blk: {
                    defer self.allocator.free(path);
                    break :blk if (self.logout(path, session.token.bytes, &self.logout_diagnostics.web)) .confirmed else .unknown;
                } else .unknown;
                self.progressLogout(.web_session, self.diagnostics.web_logout, self.logout_diagnostics.web);
                session.deinit();
                self.web_session = null;
            }
            if (self.video_channel) |*channel| {
                channel.client.deinit();
                std.crypto.secureZero(u8, &channel.pending);
                self.video_channel = null;
            }
            if (self.management_channel) |*channel| {
                channel.client.deinit();
                std.crypto.secureZero(u8, &channel.pending);
                self.management_channel = null;
            }
            if (self.discovery) |*discovery| {
                discovery.deinit();
                self.discovery = null;
            }
            self.logout_published.store(true, .release);
        }
        const receipt = self.pair.close();
        if (receipt == .unknown and self.diagnostics.local_cleanup != .unknown) self.progressNote(.{ .code = .local_cleanup_unknown });
        self.diagnostics.local_cleanup = switch (receipt) {
            .released => .released,
            .awaiting => .awaiting,
            .unknown => .unknown,
        };
        if (receipt == .released) {
            self.pair.transport.deinit() catch {
                self.diagnostics.local_cleanup = .unknown;
                return .unknown;
            };
            self.transport_destroyed = true;
        }
        return self.diagnostics.local_cleanup;
    }
    fn wait(context: *anyopaque, milliseconds: u32) void {
        cast(context).pause(milliseconds);
    }
    fn pause(_: *NativeDriver, milliseconds: u32) void {
        var fds: [1]std.c.pollfd = undefined;
        _ = std.c.poll(&fds, 0, @intCast(@min(milliseconds, 20)));
    }
    fn now(_: *anyopaque) u64 {
        return timestamp();
    }
    fn progressLogout(self: *NativeDriver, resource: progress.Resource, released: RemoteRelease, diagnostic: LogoutAttempt) void {
        self.progressNote(.{ .code = if (released == .confirmed) .remote_logout_confirmed else .remote_logout_unconfirmed, .resource = resource, .http_status = diagnostic.http_status, .validity = if (diagnostic.response_validity) |v| @fromBackingInt(@intCast(@backingInt(v))) else null });
    }
};
const stage_timeout_ns: u64 = 15 * std.time.ns_per_s;
/// Only scalar route metadata crosses from the SSH worker. The borrowed host,
/// authentication and device text never enter the BMC progress tracker.
fn recordSshProgress(raw: *anyopaque, event: ssh_progress.Event) void {
    const tracker: *progress.Tracker = @ptrCast(@alignCast(raw));
    if (event.hop_count == 0 or event.hop >= event.hop_count or event.hop_count > std.math.maxInt(u8)) return;
    // Pair.connect opens the BMC streams immediately after SSH start returns.
    // Restore their target before any stream-open error can reach the caller.
    if (event.phase == .ready and event.status == .succeeded and event.hop + 1 == event.hop_count) {
        tracker.setContext(.{ .phase = .connect });
        return;
    }
    tracker.setContext(.{
        .channel = .ssh,
        .ssh_hop = @intCast(event.hop + 1),
        .ssh_hops = @intCast(event.hop_count),
        .phase = switch (event.phase) {
            .transport => .connect,
            .tunnel => .ssh_tunnel,
            .handshake => .ssh_handshake,
            .host_key => .ssh_host_key,
            .authentication => .ssh_authentication,
            .shell, .ready => .none,
        },
    });
}

test "BMC SSH route diagnostics retain the observed failed jump without borrowed host data" {
    for ([_]usize{ 1, 3 }) |hops| {
        var tracker = progress.Tracker.initAt(@intCast(hops), 0);
        tracker.setStageAt(.route, 1);
        recordSshProgress(&tracker, .{ .attempt = 2, .hop = hops - 1, .hop_count = hops, .host = "borrowed-private-host", .port = 22, .phase = .handshake, .status = .failed, .failure = error.SshHandshakeReceiveFailed });
        tracker.failAt(error.SshHandshakeReceiveFailed, 2);
        const failure = tracker.snapshotAt(3).failure_event.?;
        try std.testing.expectEqual(progress.Channel.ssh, failure.context.?.channel);
        try std.testing.expectEqual(@as(?u8, @intCast(hops)), failure.context.?.ssh_hop);
        try std.testing.expectEqual(@as(?u8, @intCast(hops)), failure.context.?.ssh_hops);
        try std.testing.expectEqual(progress.Phase.ssh_handshake, failure.context.?.phase);
        const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, failure, .{});
        defer std.testing.allocator.free(encoded);
        try std.testing.expect(std.mem.indexOf(u8, encoded, "borrowed-private-host") == null);
    }
}

test "BMC SSH route diagnostics restore the BMC target only after the final jump is ready" {
    var tracker = progress.Tracker.initAt(2, 0);
    tracker.setStageAt(.route, 1);
    recordSshProgress(&tracker, .{ .attempt = 2, .hop = 0, .hop_count = 2, .host = "jump-1.invalid", .port = 22, .phase = .ready, .status = .succeeded });
    try std.testing.expectEqual(progress.Channel.ssh, tracker.context.?.channel);
    recordSshProgress(&tracker, .{ .attempt = 2, .hop = 1, .hop_count = 2, .host = "jump-2.invalid", .port = 22, .phase = .tunnel, .status = .started });
    try std.testing.expectEqual(progress.Phase.ssh_tunnel, tracker.context.?.phase);
    try std.testing.expectEqual(@as(?u8, 2), tracker.context.?.ssh_hop);
    recordSshProgress(&tracker, .{ .attempt = 2, .hop = 1, .hop_count = 2, .host = "jump-2.invalid", .port = 22, .phase = .ready, .status = .succeeded });
    tracker.failAt(error.StreamOpenFailed, 2);
    const failure = tracker.snapshotAt(3).failure_event.?;
    try std.testing.expectEqual(progress.Channel.management, failure.context.?.channel);
    try std.testing.expectEqual(progress.Phase.connect, failure.context.?.phase);
    try std.testing.expect(failure.context.?.ssh_hop == null and failure.context.?.ssh_hops == null);
}

/// Classify the locally built request before its credential-bearing storage is
/// wiped. Only fixed enum templates survive; no actual resource ID or query is
/// copied into connection diagnostics.
fn requestContext(bytes: []const u8) progress.Context {
    var parts = std.mem.splitScalar(u8, bytes, ' ');
    const method = parts.next() orelse "";
    const target = parts.next() orelse "";
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    return .{
        .method = if (std.mem.eql(u8, method, "GET")) .get else if (std.mem.eql(u8, method, "POST")) .post else if (std.mem.eql(u8, method, "PATCH")) .patch else if (std.mem.eql(u8, method, "DELETE")) .delete else .none,
        .path = if (std.mem.eql(u8, path, "/redfish/v1/") or std.mem.eql(u8, path, "/redfish/v1"))
            .service_root
        else if (std.mem.eql(u8, path, profile.sugon_public_material_path))
            .public_script
        else if (std.mem.eql(u8, path, "/redfish/v1/SessionService"))
            .session_service
        else if (std.mem.eql(u8, path, "/redfish/v1/SessionService/Sessions"))
            .web_sessions
        else if (std.mem.eql(u8, path, profile.kvm_login_path) or std.mem.startsWith(u8, path, profile.kvm_login_path ++ "/"))
            .kvm_session
        else if (isDirectMemberPath(path, "/redfish/v1/SessionService/Sessions/"))
            .web_session
        else if (std.mem.eql(u8, path, "/redfish/v1/Managers"))
            .managers
        else if (isDirectMemberPath(path, "/redfish/v1/Managers/"))
            .manager
        else if (std.mem.eql(u8, path, "/redfish/v1/Systems"))
            .systems
        else if (isDirectMemberPath(path, "/redfish/v1/Systems/"))
            .system
        else if (std.mem.eql(u8, path, profile.video_path))
            .websocket
        else
            .other_redfish,
        .phase = .request_send,
        .received_bytes = 0,
        .duration_ms = 0,
    };
}
fn isDirectMemberPath(path: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, path, prefix) and path.len > prefix.len and std.mem.indexOfScalar(u8, path[prefix.len..], '/') == null;
}
test "BMC native HTTP diagnostics retain only reviewed request templates without identifiers query headers or body" {
    const context = requestContext("GET /redfish/v1/Systems/private-system?private-query HTTP/1.1\r\nX-Auth-Token: private-token\r\n\r\nprivate-body");
    try std.testing.expectEqual(progress.Method.get, context.method);
    try std.testing.expectEqual(progress.RequestPath.system, context.path);
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, context, .{});
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "private-") == null);
    const child = requestContext("GET /redfish/v1/Managers/private-manager/SecurityService HTTP/1.1\r\n\r\n");
    // A subresource must not be mislabeled as its Manager parent.
    try std.testing.expectEqual(progress.RequestPath.other_redfish, child.path);
}
fn resourceKind(kind: redfish.ResourceKind) progress.Resource {
    return switch (kind) {
        .root => .service_root,
        .systems => .systems_collection,
        .managers => .managers_collection,
        .system => .system,
        .manager => .manager,
        .session_service => .session_service,
        else => .other_redfish,
    };
}
fn onlySuccessMessages(value: std.json.Value, depth: usize) bool {
    if (depth > 16) return false;
    switch (value) {
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const child = entry.value_ptr.*;
                if (std.mem.eql(u8, key, "code") or std.mem.eql(u8, key, "MessageId")) {
                    if (child != .string or !std.mem.eql(u8, child.string, "Base.1.19.Success")) return false;
                }
                if (std.mem.eql(u8, key, "Severity") or std.mem.eql(u8, key, "MessageSeverity")) {
                    if (child != .string or !std.mem.eql(u8, child.string, "OK")) return false;
                }
                if (!onlySuccessMessages(child, depth + 1)) return false;
            }
        },
        .array => |array| for (array.items) |child| {
            if (!onlySuccessMessages(child, depth + 1)) return false;
        },
        else => {},
    }
    return true;
}
fn timestamp() u64 {
    return @intCast(@max(0, monotonic.monotonicNs()));
}
fn testIdentity() profile.Identity {
    return .{ .trusted_channel = true, .manufacturer = "Sugon", .product = "SuperPod", .processor_vendor = "Hygon", .bmc_chip = "AST2600-A3", .firmware = "1.80", .oem_namespace = "Public", .kvm_login_resource = profile.kvm_login_path, .oem_rfb = true };
}
