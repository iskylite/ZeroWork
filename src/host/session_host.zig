const std = @import("std");
const identity = @import("identity.zig");
const operations = @import("operation.zig");
const plugins = @import("plugin_registry.zig");
const typed = @import("plugin_services.zig");
const envelopes = @import("../config/connection_envelope.zig");
const contexts = @import("host_context.zig");
const Snapshot = @import("../ui/session_lifecycle.zig").Snapshot;

pub const SessionHandle = identity.SessionHandle;
pub const OperationKey = operations.OperationKey;
pub const ServiceKind = plugins.ServiceKind;
pub const Endpoint = struct { host: []const u8, port: u16 = 22, user: []const u8 };
pub const AuthOptions = union(enum) {
    agent,
    password_prompt,
    password: []const u8,
    private_key: struct { path: []const u8, passphrase: ?[]const u8 = null },
    keyboard_interactive,
};
pub const RemoteProtocol = enum { ssh, sftp };
pub const SessionPurpose = enum { interactive, socks_background };

pub fn backgroundServices() plugins.Services {
    return plugins.Services.of(&.{ .lifecycle, .auth, .route, .forward });
}
pub const RouteHop = struct {
    owner: ?identity.AssetOwner = null,
    display_name: []const u8 = "",
    protocol: RemoteProtocol = .ssh,
    endpoint: Endpoint,
    auth: AuthOptions = .agent,
    totp_secret: ?[]const u8 = null,
    strict_host_key_checking: bool = true,
};
pub const RemoteConfig = struct {
    endpoint: Endpoint,
    auth: AuthOptions = .agent,
    totp_secret: ?[]const u8 = null,
    strict_host_key_checking: bool = true,
    terminal_type: []const u8 = "xterm-256color",
    startup_commands: []const []const u8 = &.{},
    keepalive_sec: u16 = 30,
    compression: bool = false,
};

/// Local never carries a fake host asset. Saved SSH/SFTP and temporary SSH
/// freeze the complete request, including route and credential options.
pub const SessionCreateSpec = union(enum) {
    plugin: envelopes.Envelope,
    local: struct { initial_cwd: ?[]const u8 = null, fixed_backend: enum { zsh } = .zsh },
    saved: struct {
        connection_id: identity.ConnectionId,
        config_revision: u64,
        protocol: RemoteProtocol,
        purpose: SessionPurpose = .interactive,
        immutable_config: RemoteConfig,
        credential_ref: ?u64 = null,
        route_snapshot: []const RouteHop = &.{},
        private_options: []const u8 = &.{},
    },
    temporary_ssh: struct {
        structured_endpoint: Endpoint,
        auth_options: AuthOptions = .agent,
        totp_secret: ?[]const u8 = null,
        strict_host_key_checking: bool = true,
        route_snapshot: []const RouteHop = &.{},
    },

    pub fn pluginId(self: SessionCreateSpec) plugins.PluginId {
        return switch (self) {
            .plugin => .external,
            .local => .local,
            .saved => |saved| if (saved.protocol == .ssh) .ssh else .sftp,
            .temporary_ssh => .ssh,
        };
    }

    pub fn purpose(self: SessionCreateSpec) SessionPurpose {
        return switch (self) {
            .saved => |saved| saved.purpose,
            else => .interactive,
        };
    }

    pub fn requiredServices(self: SessionCreateSpec) plugins.Services {
        return if (self.purpose() == .socks_background) backgroundServices() else plugins.requiredServices(self.pluginId());
    }

    pub fn validate(self: SessionCreateSpec) !void {
        switch (self) {
            .plugin => |envelope| try envelope.validate(),
            .local => |local| if (local.initial_cwd) |cwd| {
                if (cwd.len == 0 or cwd[0] != '/' or !std.unicode.utf8ValidateSlice(cwd) or std.mem.indexOfScalar(u8, cwd, 0) != null) return error.InvalidDirectory;
            },
            .saved => |saved| {
                if (saved.purpose == .socks_background and saved.protocol != .ssh) return error.InvalidSessionPurpose;
                if (@backingInt(saved.connection_id) == 0 or saved.config_revision == 0) return error.InvalidIdentity;
                try validateEndpoint(saved.immutable_config.endpoint);
                try validateAuth(saved.immutable_config.auth);
                try validateRoute(saved.route_snapshot, saved.connection_id, saved.immutable_config.endpoint);
            },
            .temporary_ssh => |temporary| {
                try validateEndpoint(temporary.structured_endpoint);
                try validateAuth(temporary.auth_options);
                try validateRoute(temporary.route_snapshot, null, temporary.structured_endpoint);
            },
        }
    }
};

pub const AttachmentTarget = struct { window_id: identity.WindowId, workspace_id: identity.WorkspaceId };
pub const Attachment = struct { target: AttachmentTarget, tab_id: identity.TabId };
pub const Lifecycle = enum { creating, ready, attached, ended, failed, closing, closed, cleanup_unknown };

pub const ServiceHandle = struct {
    resource_owner: identity.ResourceOwner,
    origin_session: ?SessionHandle = null,
    kind: ServiceKind,
    binding_id: u64,
    binding_generation: u64,

    pub fn eql(self: ServiceHandle, other: ServiceHandle) bool {
        return std.meta.eql(self, other);
    }
};

/// Typed adapter for existing engine APIs: resolve rechecks owner, generation,
/// authorization and readiness on every call before returning an engine handle.
/// New providers may define richer interfaces without editing this bridge.
pub fn LegacyService(comptime kind: ServiceKind) type {
    return struct {
        pub const service_kind = kind;
        resolve: *const fn (*anyopaque, typed.Binding) anyerror!ServiceHandle,
    };
}
const LegacyBindingContext = struct {
    host: *SessionHost,
    owner: SessionHandle,
    kind: ServiceKind,
    fn resolve(context: *anyopaque, borrowed_binding: typed.Binding) !ServiceHandle {
        const self: *LegacyBindingContext = @ptrCast(@alignCast(context));
        if (!self.host.typedBindingIsLive(borrowed_binding)) return error.StaleBinding;
        const entry = self.host.find(self.owner) orelse return error.StaleBinding;
        for (entry.typed_bindings.items) |binding| if (binding.definition.key.eql(.{ .name = @tagName(self.kind) }) and !binding.authorized) return error.ServiceDenied;
        return switch (self.host.queryLegacyService(self.owner, self.kind)) {
            .available => |binding| binding,
            .unsupported => error.UnsupportedService,
            .temporarily_unavailable => error.ServiceUnavailable,
        };
    }
};

pub const ServiceQuery = union(enum) {
    available: ServiceHandle,
    temporarily_unavailable: []const u8,
    unsupported,
};

pub const CloseStep = enum { pause_transfers, stop_ai, release_forwards, close_protocol, release_content };
pub const CloseReceipt = enum { released, awaiting, unknown };
pub const CreateRequest = struct { handle: SessionHandle, key: OperationKey, target: AttachmentTarget, spec: SessionCreateSpec, purpose: SessionPurpose = .interactive, context: ?contexts.HostContext = null };

/// Adapters must enqueue asynchronous completions for the controller thread;
/// they must not call SessionHost reentrantly. The borrowed request remains
/// immutable and alive until host shutdown. No empty/nullable vtable is accepted.
pub const Adapter = struct {
    registration: plugins.AdapterRegistration,
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        create: *const fn (*anyopaque, CreateRequest) anyerror!void,
        cancel: *const fn (*anyopaque, OperationKey) CloseReceipt,
        close: *const fn (*anyopaque, SessionHandle, OperationKey) anyerror!CloseReceipt,
        release_stale: *const fn (*anyopaque, SessionHandle, OperationKey) void,
        /// Main-thread rebinding only: preserve controller/transport ownership,
        /// do not reconnect, and leave the old context intact on failure.
        rebind_context: ?*const fn (*anyopaque, SessionHandle, contexts.HostContext) anyerror!void = null,
    };
};

pub const SessionFactory = struct {
    context: *anyopaque,
    vtable: *const Adapter.VTable,
    poll: ?*const fn (*anyopaque, *SessionHost) anyerror!bool = null,
};
pub const OpenIntent = struct { request_key: u64, target: AttachmentTarget, purpose: SessionPurpose = .interactive };
const OpenRequest = struct { request_key: u64, fingerprint: u64, envelope: Snapshot(envelopes.Envelope), target: AttachmentTarget, purpose: SessionPurpose, accepted: Accepted };

pub const CloseHook = struct {
    context: *anyopaque,
    run: *const fn (*anyopaque, SessionHandle, OperationKey) anyerror!CloseReceipt,
};
pub const CloseHooks = struct {
    pause_transfers: ?CloseHook = null,
    stop_ai: ?CloseHook = null,
    release_forwards: ?CloseHook = null,
    release_content: ?CloseHook = null,
};

pub const Accepted = struct { handle: SessionHandle, operation: OperationKey };
pub const SessionSnapshot = struct {
    handle: SessionHandle,
    plugin_id: plugins.PluginId,
    protocol_id: []const u8 = "",
    purpose: SessionPurpose = .interactive,
    lifecycle: Lifecycle,
    target: AttachmentTarget,
    attachment: ?Attachment,
    create_operation: OperationKey,
    close_operation: ?OperationKey,
    create_cleanup: operations.Cleanup,
};

const Entry = struct {
    handle: SessionHandle,
    manifest_id: []const u8,
    purpose: SessionPurpose = .interactive,
    spec: Snapshot(SessionCreateSpec),
    legacy_spec: ?Snapshot(SessionCreateSpec) = null,
    target: AttachmentTarget,
    attachment: ?Attachment = null,
    state: Lifecycle = .creating,
    ready_accepted: bool = false,
    creation_ended: bool = false,
    create_cleanup: operations.Cleanup = .not_started,
    attempt: u64 = 1,
    create_operation: OperationKey,
    close_operation: ?OperationKey = null,
    close_step: CloseStep = .pause_transfers,
    hooks: CloseHooks = .{},
    close_resources_released: bool = false,
    shutdown_receipt: ?CloseReceipt = null,
    shutdown_via_cancel: bool = false,
    bindings: std.ArrayList(ServiceHandle) = .empty,
    typed_bindings: std.ArrayList(typed.Binding) = .empty,
    available_bindings: std.ArrayList(typed.Binding) = .empty,
    capability_states: std.ArrayList(@import("capability_snapshot.zig").ServiceState) = .empty,
    capability_revision: u64 = 1,
};

pub const RetainedTransferStart = struct { binding: ServiceHandle, key: OperationKey, spec: SessionCreateSpec };
pub const ReadonlyBindings = struct { directory: ServiceHandle, file_read: ServiceHandle };
pub const AuxiliaryReadonlyStart = struct { bindings: ReadonlyBindings, key: OperationKey };
const AuxiliaryReadonly = struct {
    owner: SessionHandle,
    bindings: ReadonlyBindings,
    key: OperationKey,
    live: bool = false,
    cleanup: CloseReceipt = .awaiting,
};
pub const AuxiliaryTransferStart = struct { binding: ServiceHandle, key: OperationKey, spec: SessionCreateSpec };
pub const SharedTransferStart = struct { binding: ServiceHandle, key: OperationKey };
const SharedTransfer = struct {
    owner: SessionHandle,
    binding: ServiceHandle,
    key: OperationKey,
    live: bool = false,
    closing: bool = false,
    cleanup: CloseReceipt = .awaiting,
};
const AuxiliaryTransfer = struct {
    owner: SessionHandle,
    binding: ServiceHandle,
    key: OperationKey,
    live: bool = false,
    closing: bool = false,
    cleanup: CloseReceipt = .awaiting,
};
const FaultTransferSource = struct {
    binding: ServiceHandle,
    key: OperationKey,
    cleanup: CloseReceipt,
};
const RetainedTransfer = struct {
    id: identity.RetainedTransferOwnerId,
    original: SessionHandle,
    spec: Snapshot(SessionCreateSpec),
    generation: u64 = 0,
    faults: std.ArrayList(FaultTransferSource) = .empty,
    binding: ?ServiceHandle = null,
    key: ?OperationKey = null,
    live: bool = false,
    closing: bool = false,
    cleanup: CloseReceipt = .released,
};

/// An explicit standalone SFTP directory recovery never replaces its logical
/// session or its independent transfer binding. Old and new pairs are exact.
pub const SftpDirectoryPair = struct { directory: ServiceHandle, file_read: ServiceHandle };
pub const SftpDirectoryRecovery = struct {
    owner: SessionHandle,
    previous: SftpDirectoryPair,
    bindings: SftpDirectoryPair,
    key: OperationKey,
    old_cleanup: CloseReceipt = .awaiting,
    cleanup: CloseReceipt = .awaiting,
    live: bool = false,
    published: bool = false,
};

/// Application-owned controller. UI widgets retain IDs/handles only; the host
/// keeps factories, immutable requests, operation ordering and service bindings.
pub const SessionHost = struct {
    allocator: std.mem.Allocator,
    context_factory: ?contexts.Factory = null,
    registry: plugins.Registry,
    adapters: []Adapter,
    registrations: []plugins.AdapterRegistration,
    sessions: std.ArrayList(Entry) = .empty,
    open_requests: std.ArrayList(OpenRequest) = .empty,
    legacy_binding_contexts: std.ArrayList(*LegacyBindingContext) = .empty,
    session_ids: identity.Allocator(identity.SessionId) = .{},
    retained_transfers: std.ArrayList(RetainedTransfer) = .empty,
    auxiliary_transfers: std.ArrayList(AuxiliaryTransfer) = .empty,
    shared_transfers: std.ArrayList(SharedTransfer) = .empty,
    auxiliary_readonly: std.ArrayList(AuxiliaryReadonly) = .empty,
    sftp_directory_recoveries: std.ArrayList(SftpDirectoryRecovery) = .empty,
    retained_ids: identity.Allocator(identity.RetainedTransferOwnerId) = .{},
    next_binding: u64 = 1,
    binding_exhausted: bool = false,
    journal: operations.Journal,

    pub fn init(allocator: std.mem.Allocator, adapters: []const Adapter) !SessionHost {
        return initWithPlugins(allocator, adapters, &.{}, &.{});
    }

    pub fn initPlugins(allocator: std.mem.Allocator, manifests: []const plugins.PluginManifest, renderers: []const plugins.RendererDefinition) !SessionHost {
        return initWithPlugins(allocator, &.{}, manifests, renderers);
    }

    pub fn initWithPlugins(allocator: std.mem.Allocator, adapters: []const Adapter, manifests: []const plugins.PluginManifest, renderers: []const plugins.RendererDefinition) !SessionHost {
        const owned_adapters = try allocator.dupe(Adapter, adapters);
        errdefer allocator.free(owned_adapters);
        var registry = try @import("../plugins/linked_plugins.zig").initRegistry(allocator, owned_adapters, manifests, renderers);
        errdefer registry.deinit();
        const registrations = try allocator.alloc(plugins.AdapterRegistration, adapters.len);
        for (adapters, registrations) |adapter, *registration| registration.* = adapter.registration;
        return .{ .allocator = allocator, .registry = registry, .adapters = owned_adapters, .registrations = registrations, .journal = operations.Journal.init(allocator) };
    }

    /// Call only after adapters have stopped producing events and closed their
    /// resources. Shutdown never claims that a still-running resource is gone.
    pub fn deinit(self: *SessionHost) void {
        for (self.sessions.items) |*entry| {
            entry.spec.deinit();
            if (entry.legacy_spec) |*legacy| legacy.deinit();
            entry.bindings.deinit(self.allocator);
            entry.typed_bindings.deinit(self.allocator);
            entry.available_bindings.deinit(self.allocator);
            entry.capability_states.deinit(self.allocator);
        }
        self.sessions.deinit(self.allocator);
        for (self.open_requests.items) |*request| request.envelope.deinit();
        self.open_requests.deinit(self.allocator);
        for (self.legacy_binding_contexts.items) |context| self.allocator.destroy(context);
        self.legacy_binding_contexts.deinit(self.allocator);
        self.registry.deinit();
        for (self.retained_transfers.items) |*retained| {
            retained.spec.deinit();
            retained.faults.deinit(self.allocator);
        }
        self.retained_transfers.deinit(self.allocator);
        self.auxiliary_transfers.deinit(self.allocator);
        self.shared_transfers.deinit(self.allocator);
        self.auxiliary_readonly.deinit(self.allocator);
        self.sftp_directory_recoveries.deinit(self.allocator);
        self.journal.deinit();
        self.allocator.free(self.adapters);
        self.allocator.free(self.registrations);
    }

    /// One submission key dispatches at most one create; reusing it for a
    /// different immutable request is an error, including after failure/close.
    pub fn open(self: *SessionHost, envelope: envelopes.Envelope, intent: OpenIntent) !Accepted {
        return self.openEnvelope(envelope, intent, false);
    }

    /// Quick creation never allocates or writes an asset. Registry membership,
    /// immutable payload, deduplication and lifecycle use the ordinary path.
    pub fn openQuick(self: *SessionHost, protocol_id: []const u8, payload: []const u8, intent: OpenIntent) !Accepted {
        const manifest_value = self.registry.find(protocol_id) orelse return error.AdapterNotConnected;
        const quick = manifest_value.quick_create orelse return error.QuickCreateNotSupported;
        return self.openEnvelope(.{ .protocol_id = protocol_id, .name = manifest_value.display_name, .payload_version = quick.payload_version, .payload = payload }, intent, true);
    }

    pub fn openQuickAction(self: *SessionHost, action_id: []const u8, argument: ?[]const u8, intent: OpenIntent) !Accepted {
        for (self.registry.manifests()) |manifest_value| if (manifest_value.quick_create) |quick| {
            if (!std.mem.eql(u8, quick.action_id orelse continue, action_id)) continue;
            const payload = try (quick.encode_creation_payload orelse return error.InvalidCreationAction)(self.allocator, argument);
            defer self.allocator.free(payload);
            return self.openQuick(manifest_value.id, payload, intent);
        };
        return error.QuickCreateNotSupported;
    }

    fn openEnvelope(self: *SessionHost, envelope: envelopes.Envelope, intent: OpenIntent, quick: bool) !Accepted {
        if (intent.request_key == 0) return error.InvalidRequestKey;
        try envelope.validate();
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hasher, @backingInt(envelope.id));
        std.hash.autoHash(&hasher, envelope.revision);
        std.hash.autoHash(&hasher, envelope.payload_version);
        std.hash.autoHash(&hasher, envelope.group_id);
        std.hash.autoHash(&hasher, intent.target);
        std.hash.autoHash(&hasher, intent.purpose);
        hasher.update(envelope.protocol_id);
        hasher.update(envelope.name);
        hasher.update(envelope.payload);
        const fingerprint = hasher.final();
        for (self.open_requests.items) |request| if (request.request_key == intent.request_key) {
            const original = request.envelope.value;
            if (request.fingerprint != fingerprint or request.purpose != intent.purpose or !std.meta.eql(request.target, intent.target) or original.id != envelope.id or original.revision != envelope.revision or original.payload_version != envelope.payload_version or original.group_id != envelope.group_id or !std.mem.eql(u8, original.protocol_id, envelope.protocol_id) or !std.mem.eql(u8, original.name, envelope.name) or !std.mem.eql(u8, original.payload, envelope.payload)) return error.RequestKeyConflict;
            return request.accepted;
        };
        try self.open_requests.ensureUnusedCapacity(self.allocator, 1);
        const manifest_value = self.registry.find(envelope.protocol_id) orelse return error.AdapterNotConnected;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const decoded = if (quick) blk: {
            const contribution = manifest_value.quick_create orelse return error.QuickCreateNotSupported;
            if (envelope.payload_version != contribution.payload_version) return error.UnsupportedPayloadVersion;
            try contribution.validate_payload(envelope.payload);
            break :blk envelope;
        } else blk: {
            const contribution = manifest_value.connection orelse return error.ConnectionNotSupported;
            if (envelope.payload_version != contribution.payload_version) return error.UnsupportedPayloadVersion;
            break :blk try (contribution.decode orelse return error.MissingConnectionCodec)(arena.allocator(), envelope);
        };
        if (!std.mem.eql(u8, decoded.protocol_id, envelope.protocol_id) or decoded.id != envelope.id or decoded.revision != envelope.revision or decoded.group_id != envelope.group_id or !std.mem.eql(u8, decoded.name, envelope.name)) return error.CodecChangedEnvelopeIdentity;
        var request_snapshot = try Snapshot(envelopes.Envelope).init(self.allocator, envelope);
        errdefer request_snapshot.deinit();
        const accepted = try self.createWithPurpose(.{ .plugin = decoded }, intent.target, intent.purpose);
        self.open_requests.appendAssumeCapacity(.{ .request_key = intent.request_key, .fingerprint = fingerprint, .envelope = request_snapshot, .target = intent.target, .purpose = intent.purpose, .accepted = accepted });
        return accepted;
    }

    pub fn protocolId(self: *SessionHost, handle: SessionHandle) ?[]const u8 {
        const entry = self.find(handle) orelse return null;
        return entry.manifest_id;
    }
    pub fn manifestFor(self: *SessionHost, handle: SessionHandle) ?*const plugins.PluginManifest {
        return self.registry.find(self.protocolId(handle) orelse return null);
    }
    pub fn connectionEnvelope(self: *SessionHost, handle: SessionHandle) ?envelopes.Envelope {
        const entry = self.find(handle) orelse return null;
        return if (entry.spec.value == .plugin) entry.spec.value.plugin else null;
    }
    /// Provider-only codec boundary: retain the frozen old-engine request while
    /// the original public envelope remains available to editors/renderers.
    pub fn bindEngineSpec(self: *SessionHost, handle: SessionHandle, key: OperationKey, spec: SessionCreateSpec) !void {
        const entry = self.find(handle) orelse return error.StaleSession;
        if (entry.state != .creating or !entry.create_operation.eql(key)) return error.StaleCreateOperation;
        const descriptor = self.manifest(entry).legacy_descriptor orelse return error.NotLegacyAdapter;
        if (spec == .plugin or spec.pluginId() != descriptor.plugin_id) return error.ProtocolMismatch;
        try spec.validate();
        const snapshot = try Snapshot(SessionCreateSpec).init(self.allocator, spec);
        if (entry.legacy_spec) |*previous| previous.deinit();
        entry.legacy_spec = snapshot;
    }
    pub fn engineSpec(self: *SessionHost, handle: SessionHandle) ?SessionCreateSpec {
        const entry = self.find(handle) orelse return null;
        return sourceSpec(entry);
    }
    fn sourceSpec(entry: *const Entry) SessionCreateSpec {
        return if (entry.legacy_spec) |legacy| legacy.value else entry.spec.value;
    }
    pub fn createSpec(self: *SessionHost, handle: SessionHandle) ?SessionCreateSpec {
        const entry = self.find(handle) orelse return null;
        return entry.spec.value;
    }
    pub fn setContextFactory(self: *SessionHost, context_factory: contexts.Factory) void {
        self.context_factory = context_factory;
    }
    pub fn pollControllers(self: *SessionHost) !bool {
        var changed = false;
        for (self.registry.manifests()) |manifest_value| if (manifest_value.session_factory) |factory_value| {
            if (factory_value.poll) |poll| changed = (try poll(factory_value.context, self)) or changed;
        };
        return changed;
    }
    pub fn readyPlugin(self: *SessionHost, handle: SessionHandle, key: OperationKey, bindings: []const typed.Binding) !bool {
        const entry = self.find(handle) orelse {
            self.releaseStale(handle, key);
            return false;
        };
        if (entry.ready_accepted and entry.create_operation.eql(key)) return false;
        if (entry.state != .creating or !entry.create_operation.eql(key)) {
            self.releaseStale(handle, key);
            return false;
        }
        self.validatePluginBindings(entry, bindings) catch |err| {
            _ = try self.failed(handle, key, .{ .domain = .plugin, .code = @errorName(err), .cleanup = .releasing, .safe_message = "插件返回的服务绑定不合法" });
            const factory_value = self.factory(entry);
            try self.applyCreateCleanup(entry, factory_value.vtable.cancel(factory_value.context, key));
            return err;
        };
        try entry.typed_bindings.ensureTotalCapacity(self.allocator, bindings.len);
        _ = try self.journal.publish(key, .progress, "ready", null);
        entry.typed_bindings.appendSliceAssumeCapacity(bindings);
        for (bindings) |binding| entry.capability_revision = @max(entry.capability_revision, binding.revision);
        entry.ready_accepted = true;
        entry.state = .ready;
        return true;
    }
    fn validatePluginBindings(self: *SessionHost, entry: *const Entry, bindings: []const typed.Binding) !void {
        const manifest_value = self.manifest(entry);
        for (bindings, 0..) |binding, i| {
            if (!binding.owner.eql(entry.handle) or binding.generation != entry.handle.generation or binding.revision == 0) return error.StaleBinding;
            if (!manifest_value.supports(binding.definition)) return error.ServiceNotRegistered;
            for (bindings[0..i]) |other| if (other.definition.key.eql(binding.definition.key)) return error.DuplicateServiceBinding;
        }
        for (manifest_value.required_services) |required| {
            var found = false;
            for (bindings) |binding| if (binding.definition.matches(required)) {
                found = true;
                break;
            };
            if (!found) return error.MissingRequiredService;
        }
    }
    pub fn queryTypedService(self: *SessionHost, handle: SessionHandle, comptime Interface: type, service_key: typed.ServiceKey) typed.Query(Interface) {
        const entry = self.find(handle) orelse return .{ .temporarily_unavailable = .{ .reason = "会话已失效", .revision = 0 } };
        if (entry.purpose == .socks_background) {
            var allowed = false;
            inline for (comptime std.meta.tags(ServiceKind)) |kind| if (backgroundServices().has(kind) and service_key.eql(.{ .name = @tagName(kind) })) {
                allowed = true;
            };
            if (!allowed) return .unsupported;
        }
        const expected = typed.Definition.of(Interface, service_key);
        if (!self.manifest(entry).supports(expected)) return .unsupported;
        if (entry.state != .ready and entry.state != .attached) return .{ .temporarily_unavailable = .{ .reason = "会话尚未就绪或正在关闭", .revision = entry.capability_revision } };
        inline for (comptime std.meta.tags(ServiceKind)) |kind| {
            if (comptime Interface == LegacyService(kind)) {
                if (!std.mem.eql(u8, service_key.name, @tagName(kind)) or service_key.major != 1) return .unsupported;
                switch (self.queryLegacyService(handle, kind)) {
                    .available => {},
                    .unsupported => return .unsupported,
                    .temporarily_unavailable => |reason| return .{ .temporarily_unavailable = .{ .reason = reason, .revision = entry.capability_revision } },
                }
            }
        }
        for (entry.typed_bindings.items) |binding| if (binding.definition.matches(expected)) {
            if (!binding.authorized) return .{ .denied = .{ .reason = "当前操作未授权", .revision = binding.revision } };
            const vtable = binding.borrow(Interface, service_key, handle) catch return .{ .temporarily_unavailable = .{ .reason = "服务绑定已失效", .revision = binding.revision } };
            return .{ .available = .{ .context = binding.context, .vtable = vtable, .binding = binding } };
        };
        return .{ .temporarily_unavailable = .{ .reason = "当前会话未绑定此服务", .revision = entry.capability_revision } };
    }
    /// Borrowed only until the next host mutation; asynchronous clients copy it.
    pub fn typedBindingsFor(self: *SessionHost, handle: SessionHandle) ?[]const typed.Binding {
        const entry = self.find(handle) orelse return null;
        if (entry.state != .ready and entry.state != .attached) return null;
        entry.available_bindings.clearRetainingCapacity();
        entry.available_bindings.ensureTotalCapacity(self.allocator, entry.typed_bindings.items.len) catch return null;
        for (entry.typed_bindings.items) |binding| if (self.bindingAvailable(entry, binding)) entry.available_bindings.appendAssumeCapacity(binding);
        return entry.available_bindings.items;
    }
    fn bindingAvailable(self: *SessionHost, entry: *const Entry, binding: typed.Binding) bool {
        inline for (comptime std.meta.tags(ServiceKind)) |kind| {
            if (binding.definition.matches(plugins.legacyServiceDefinition(kind)) and kind != .lifecycle) return self.queryLegacyService(entry.handle, kind) == .available;
        }
        return true;
    }
    pub fn capabilitySnapshot(self: *SessionHost, owner: SessionHandle) !?@import("capability_snapshot.zig").Snapshot {
        const entry = self.find(owner) orelse return null;
        const manifest_value = self.manifest(entry);
        entry.capability_states.clearRetainingCapacity();
        try entry.capability_states.ensureTotalCapacity(self.allocator, manifest_value.services.len);
        for (manifest_value.services) |definition| {
            var declared = true;
            if (entry.purpose == .socks_background) {
                declared = false;
                inline for (comptime std.meta.tags(ServiceKind)) |kind| if (backgroundServices().has(kind) and definition.matches(plugins.legacyServiceDefinition(kind))) {
                    declared = true;
                };
            }
            var available = false;
            var authorized = true;
            var revision = entry.capability_revision;
            for (entry.typed_bindings.items) |binding| if (binding.definition.matches(definition)) {
                available = (entry.state == .ready or entry.state == .attached) and self.bindingAvailable(entry, binding);
                authorized = binding.authorized;
                revision = binding.revision;
                break;
            };
            entry.capability_states.appendAssumeCapacity(.{ .key = definition.key, .declared = declared, .available = declared and available, .authorized = authorized, .revision = revision, .reason = if (!authorized) "当前操作未授权" else if (!available) "服务尚未就绪或正在关闭" else "" });
        }
        return .{ .owner = owner, .revision = entry.capability_revision, .services = entry.capability_states.items, .closed = entry.state == .closing or entry.state == .closed or entry.state == .cleanup_unknown };
    }
    pub fn capabilityRevisionFor(self: *SessionHost, handle: SessionHandle) ?u64 {
        const entry = self.find(handle) orelse return null;
        return entry.capability_revision;
    }
    pub fn typedBindingIsLive(self: *SessionHost, binding: typed.Binding) bool {
        const entry = self.find(binding.owner) orelse return false;
        if (entry.state != .ready and entry.state != .attached) return false;
        for (entry.typed_bindings.items) |current| if (current.definition.matches(binding.definition) and current.owner.eql(binding.owner) and current.generation == binding.generation and current.revision == binding.revision and current.context == binding.context and current.vtable == binding.vtable) return current.authorized and self.bindingAvailable(entry, current);
        return false;
    }
    fn capabilityChanged(self: *SessionHost, owner: SessionHandle) void {
        const entry = self.find(owner) orelse return;
        entry.capability_revision +|= 1;
        for (entry.typed_bindings.items) |*binding| binding.revision +|= 1;
    }
    /// Providers may publish optional services after startup. The host assigns
    /// a fresh revision so revocation/rebinding never revives a captured binding.
    pub fn bindTypedService(self: *SessionHost, handle: SessionHandle, operation: OperationKey, proposed: typed.Binding) !typed.Binding {
        const entry = self.find(handle) orelse return error.StaleSession;
        if (!entry.create_operation.eql(operation) or (entry.state != .ready and entry.state != .attached)) return error.StaleCreateOperation;
        if (!proposed.owner.eql(handle) or proposed.generation != handle.generation) return error.StaleBinding;
        if (!self.manifest(entry).supports(proposed.definition)) return error.ServiceNotRegistered;
        var slot: ?usize = null;
        for (entry.typed_bindings.items, 0..) |binding, index| if (binding.definition.key.eql(proposed.definition.key)) {
            slot = index;
            break;
        };
        if (slot == null) try entry.typed_bindings.ensureUnusedCapacity(self.allocator, 1);
        const revision = try identity.advance(entry.capability_revision);
        var binding = proposed;
        binding.revision = revision;
        if (slot) |index| entry.typed_bindings.items[index] = binding else entry.typed_bindings.appendAssumeCapacity(binding);
        entry.capability_revision = revision;
        return binding;
    }
    pub fn revokeTypedService(self: *SessionHost, handle: SessionHandle, operation: OperationKey, service_key: typed.ServiceKey) !bool {
        const entry = self.find(handle) orelse return error.StaleSession;
        if (!entry.create_operation.eql(operation) or (entry.state != .ready and entry.state != .attached)) return error.StaleCreateOperation;
        for (entry.typed_bindings.items, 0..) |binding, index| if (binding.definition.key.eql(service_key)) {
            const revision = try identity.advance(entry.capability_revision);
            _ = entry.typed_bindings.orderedRemove(index);
            entry.capability_revision = revision;
            return true;
        };
        return false;
    }
    pub fn authorizeService(self: *SessionHost, handle: SessionHandle, service_key: typed.ServiceKey, authorized: bool) !void {
        const entry = self.find(handle) orelse return error.StaleSession;
        for (entry.typed_bindings.items) |*binding| if (binding.definition.key.eql(service_key)) {
            if (binding.authorized == authorized) return;
            binding.revision = try identity.advance(binding.revision);
            binding.authorized = authorized;
            entry.capability_revision = try identity.advance(entry.capability_revision);
            return;
        };
        return error.ServiceNotBound;
    }

    pub fn createBackground(self: *SessionHost, saved_spec: SessionCreateSpec, target: AttachmentTarget) !Accepted {
        var spec = saved_spec;
        switch (spec) {
            .saved => |*saved| {
                if (saved.protocol != .ssh) return error.InvalidSessionPurpose;
                saved.purpose = .socks_background;
            },
            else => return error.InvalidSessionPurpose,
        }
        return self.create(spec, target);
    }

    pub fn create(self: *SessionHost, spec: SessionCreateSpec, target: AttachmentTarget) !Accepted {
        return self.createWithPurpose(spec, target, spec.purpose());
    }

    fn createWithPurpose(self: *SessionHost, spec: SessionCreateSpec, target: AttachmentTarget, purpose: SessionPurpose) !Accepted {
        try spec.validate();
        if (@backingInt(target.window_id) == 0 or @backingInt(target.workspace_id) == 0) return error.InvalidIdentity;
        const protocol_id = if (spec == .plugin) spec.plugin.protocol_id else plugins.legacyId(spec.pluginId());
        const selected_manifest = self.registry.find(protocol_id) orelse return error.AdapterNotConnected;
        if (selected_manifest.session_factory == null) return error.AdapterNotConnected;
        if (spec == .plugin) {
            if (selected_manifest.connection) |connection| {
                if (spec.plugin.payload_version != connection.payload_version) return error.UnsupportedPayloadVersion;
                try connection.validate_payload(spec.plugin.payload);
                if (@backingInt(spec.plugin.id) == 0 and connection.create_kind == .saved) return error.SavedConnectionRequired;
            } else if (selected_manifest.quick_create) |quick| {
                if (@backingInt(spec.plugin.id) != 0 or spec.plugin.group_id != null) return error.InvalidQuickCreate;
                if (spec.plugin.payload_version != quick.payload_version) return error.UnsupportedPayloadVersion;
                try quick.validate_payload(spec.plugin.payload);
            } else return error.ConnectionNotSupported;
        }
        if (purpose == .socks_background) {
            if (selected_manifest.legacy_registration) |registration| {
                if (!registration.services.contains(backgroundServices())) return error.MissingRequiredService;
            }
            inline for (comptime std.meta.tags(ServiceKind)) |kind| {
                if (comptime backgroundServices().has(kind)) {
                    if (!selected_manifest.supports(plugins.legacyServiceDefinition(kind))) return error.MissingRequiredService;
                }
            }
        }
        var owned = try Snapshot(SessionCreateSpec).init(self.allocator, spec);
        var transferred = false;
        errdefer if (!transferred) owned.deinit();
        try self.sessions.ensureUnusedCapacity(self.allocator, 1);
        const handle: SessionHandle = .{ .session_id = try self.session_ids.allocate() };
        const key = try self.journal.begin(.{ .session = handle }, 1);
        self.sessions.appendAssumeCapacity(.{ .handle = handle, .manifest_id = selected_manifest.id, .purpose = purpose, .spec = owned, .target = target, .create_operation = key });
        transferred = true;
        // Ownership has transferred to the entry; the request can now safely
        // outlive its caller, including all tagged-union auth and route fields.
        const entry = &self.sessions.items[self.sessions.items.len - 1];
        self.startAdapter(entry) catch |err| {
            try self.failCreate(entry, @errorName(err));
        };
        return .{ .handle = handle, .operation = key };
    }

    /// A failed startup keeps identity and advances generation/attempt only
    /// after cleanup. Reopening an exited Local uses create, not failed/retry.
    pub fn retry(self: *SessionHost, handle: SessionHandle) !Accepted {
        const entry = self.find(handle) orelse return error.StaleSession;
        if (entry.shutdown_receipt != null) return error.SessionShuttingDown;
        if (entry.state != .failed and !(entry.state == .ended and self.manifest(entry).integration.retry_after_end)) return error.LifecycleDoesNotAllowRetry;
        if (entry.create_cleanup != .released) return error.CleanupNotReleased;
        const next = try entry.handle.nextGeneration();
        const attempt = try identity.advance(entry.attempt);
        const key = try self.journal.begin(.{ .session = next }, attempt);
        entry.handle = next;
        entry.attempt = attempt;
        entry.create_operation = key;
        entry.state = .creating;
        entry.ready_accepted = false;
        entry.creation_ended = false;
        entry.create_cleanup = .not_started;
        entry.bindings.clearRetainingCapacity();
        entry.typed_bindings.clearRetainingCapacity();
        entry.capability_revision +|= 1;
        self.startAdapter(entry) catch |err| try self.failCreate(entry, @errorName(err));
        return .{ .handle = next, .operation = key };
    }

    pub fn cancel(self: *SessionHost, key: OperationKey) !bool {
        const entry = self.findKey(key) orelse return false;
        if (entry.state != .creating and entry.state != .ready) return false;
        if (entry.state == .ready and entry.purpose == .socks_background) return false;
        _ = try self.journal.publish(key, .cancelled, "", null);
        entry.state = .failed;
        entry.creation_ended = true;
        entry.bindings.clearRetainingCapacity();
        entry.typed_bindings.clearRetainingCapacity();
        entry.capability_revision +|= 1;
        const adapter = self.factory(entry);
        try self.applyCreateCleanup(entry, adapter.vtable.cancel(adapter.context, key));
        return true;
    }

    /// Reserve the actual domain identity for adapter startup IO. Reservation
    /// never publishes a service: queryService/bindingIsLive remain gated by
    /// ready. Repeated calls on the same create operation return the same ID.
    pub fn reserveService(self: *SessionHost, handle: SessionHandle, key: OperationKey, kind: ServiceKind) !ServiceHandle {
        const entry = self.find(handle) orelse return error.StaleSession;
        if (!entry.create_operation.eql(key)) return error.StaleCreateOperation;
        if (entry.state != .creating or self.journal.isTerminal(key)) return error.SessionNotCreating;
        if (entry.purpose == .socks_background and !backgroundServices().has(kind)) return error.UnsupportedSessionService;
        if (!(self.manifest(entry).legacy_registration orelse return error.ServiceNotRegistered).services.has(kind)) return error.ServiceNotRegistered;
        return self.reserveBinding(entry, kind);
    }

    /// This capability is for the adapter's original startup transaction only.
    /// It cannot authorize ordinary consumers while the session is creating.
    pub fn bindingIsPreparing(self: *SessionHost, binding: ServiceHandle, key: OperationKey) bool {
        if (self.sftpDirectoryRecoveryPreparing(binding, key)) return true;
        if (binding.resource_owner == .session and binding.kind == .transfer) {
            if (self.findAuxiliary(binding.resource_owner.session)) |auxiliary| if (auxiliary.binding.eql(binding)) {
                return !auxiliary.live and self.auxiliaryTransferOperationIsCurrent(auxiliary.owner, key);
            };
        }
        const handle = switch (binding.resource_owner) {
            .session => |owner| owner,
            .retained_transfer => |id| {
                const retained = self.findRetained(id) orelse return false;
                return !retained.closing and retained.binding != null and retained.binding.?.eql(binding) and retained.key != null and retained.key.?.eql(key) and !retained.live and retained.cleanup == .awaiting and !self.journal.isTerminal(key);
            },
        };
        const entry = self.find(handle) orelse return false;
        if (entry.state != .creating or !entry.create_operation.eql(key) or self.journal.isTerminal(key)) return false;
        for (entry.bindings.items) |reserved| if (reserved.eql(binding)) return true;
        return false;
    }

    /// Adapter completion is not presentation completion. Only attached() may
    /// acknowledge installation in the originally requested window/workspace.
    pub fn ready(self: *SessionHost, handle: SessionHandle, key: OperationKey, services: plugins.Services) !bool {
        return self.acceptReady(handle, key, services, .interactive);
    }

    pub fn readyBackground(self: *SessionHost, handle: SessionHandle, key: OperationKey, services: plugins.Services) !bool {
        return self.acceptReady(handle, key, services, .socks_background);
    }

    fn acceptReady(self: *SessionHost, handle: SessionHandle, key: OperationKey, services: plugins.Services, purpose_kind: SessionPurpose) !bool {
        const entry = self.find(handle) orelse {
            self.releaseStale(handle, key);
            return false;
        };
        // Repeated delivery of the current ready receipt owns no new resource.
        // Releasing it would tear down the still-live current service bindings.
        if (entry.create_operation.eql(key) and entry.ready_accepted) return false;
        if (!entry.create_operation.eql(key) or entry.state != .creating) {
            self.releaseStale(handle, key);
            return false;
        }
        if (entry.purpose != purpose_kind) return error.InvalidSessionPurpose;
        const advertised = (self.manifest(entry).legacy_registration orelse return error.ServiceNotRegistered).services;
        var includes_reserved = true;
        for (entry.bindings.items) |binding| includes_reserved = includes_reserved and services.has(binding.kind);
        if (!advertised.contains(services) or !services.contains(sourceSpec(entry).requiredServices()) or !includes_reserved or (purpose_kind == .socks_background and !backgroundServices().contains(services))) {
            _ = try self.failed(handle, key, .{ .domain = .plugin, .code = "invalid_ready_services", .cleanup = .releasing, .safe_message = "适配器返回的服务与注册信息不符" });
            const adapter = self.factory(entry);
            try self.applyCreateCleanup(entry, adapter.vtable.cancel(adapter.context, key));
            return error.InvalidReadyServices;
        }
        try entry.bindings.ensureTotalCapacity(self.allocator, @popCount(services.bits));
        try entry.typed_bindings.ensureUnusedCapacity(self.allocator, self.manifest(entry).services.len);
        const reserved_count = entry.bindings.items.len;
        errdefer entry.bindings.shrinkRetainingCapacity(reserved_count);
        for (std.meta.tags(ServiceKind)) |kind| {
            if (!services.has(kind)) continue;
            _ = try self.reserveBinding(entry, kind);
        }
        const context_count = self.legacy_binding_contexts.items.len;
        const typed_count = entry.typed_bindings.items.len;
        errdefer {
            for (self.legacy_binding_contexts.items[context_count..]) |context| self.allocator.destroy(context);
            self.legacy_binding_contexts.shrinkRetainingCapacity(context_count);
            entry.typed_bindings.shrinkRetainingCapacity(typed_count);
        }
        const factory_value = self.factory(entry);
        entry.typed_bindings.appendAssumeCapacity(typed.Binding.init(Adapter.VTable, .{ .name = "lifecycle" }, factory_value.context, factory_value.vtable, handle, entry.capability_revision));
        inline for (comptime std.meta.tags(ServiceKind)) |kind| {
            if (kind != .lifecycle and self.manifest(entry).supports(plugins.legacyServiceDefinition(kind))) {
                const context = try self.allocator.create(LegacyBindingContext);
                self.legacy_binding_contexts.append(self.allocator, context) catch |err| {
                    self.allocator.destroy(context);
                    return err;
                };
                context.* = .{ .host = self, .owner = handle, .kind = kind };
                entry.typed_bindings.appendAssumeCapacity(typed.Binding.init(LegacyService(kind), .{ .name = @tagName(kind) }, context, &.{ .resolve = LegacyBindingContext.resolve }, handle, entry.capability_revision));
            }
        }
        _ = try self.journal.publish(key, if (purpose_kind == .socks_background) .completed else .progress, if (purpose_kind == .socks_background) "background ready" else "ready", null);
        entry.state = .ready;
        entry.ready_accepted = true;
        return true;
    }

    fn reserveBinding(self: *SessionHost, entry: *Entry, kind: ServiceKind) !ServiceHandle {
        for (entry.bindings.items) |binding| if (binding.kind == kind) return binding;
        if (self.binding_exhausted) return error.BindingExhausted;
        try entry.bindings.ensureUnusedCapacity(self.allocator, 1);
        const id = self.next_binding;
        if (id == std.math.maxInt(u64)) self.binding_exhausted = true else self.next_binding += 1;
        const binding: ServiceHandle = .{ .resource_owner = .{ .session = entry.handle }, .origin_session = entry.handle, .kind = kind, .binding_id = id, .binding_generation = entry.handle.generation };
        entry.bindings.appendAssumeCapacity(binding);
        return binding;
    }

    pub fn attached(self: *SessionHost, handle: SessionHandle, attachment: Attachment) !bool {
        const entry = self.find(handle) orelse return false;
        if (entry.purpose != .interactive) return false;
        if (entry.state != .ready or !std.meta.eql(entry.target, attachment.target) or @backingInt(attachment.tab_id) == 0) return false;
        _ = try self.journal.publish(entry.create_operation, .completed, "attached", null);
        entry.attachment = attachment;
        entry.state = .attached;
        return true;
    }

    /// Commit a renderer relocation after the window host prepared its new
    /// facades. Exact attachment matching prevents stale source-window moves.
    pub fn retargetAttached(self: *SessionHost, handle: SessionHandle, expected: Attachment, destination: Attachment, context: contexts.HostContext) !void {
        const entry = self.find(handle) orelse return error.StaleSession;
        if (entry.state != .attached or entry.close_operation != null or entry.shutdown_receipt != null) return error.LifecycleDoesNotAllowTransfer;
        if (entry.attachment == null or !std.meta.eql(entry.attachment.?, expected) or !std.meta.eql(entry.target, expected.target)) return error.StaleAttachment;
        if (@backingInt(destination.target.window_id) == 0 or @backingInt(destination.target.workspace_id) == 0 or @backingInt(destination.tab_id) == 0) return error.InvalidIdentity;
        if (!context.owner.eql(handle) or !context.operation.eql(entry.create_operation) or context.target.window_id != destination.target.window_id or context.target.workspace_id != destination.target.workspace_id) return error.StaleHostContext;
        const manifest_value = self.manifest(entry);
        const renderer = self.registry.renderer(manifest_value.content_renderer) orelse return error.ContentRendererUnavailable;
        if (!renderer.supports_window_transfer) return error.WindowTransferUnsupported;
        const factory_value = self.factory(entry);
        const rebind = factory_value.vtable.rebind_context orelse return error.WindowTransferUnsupported;
        const revision = try identity.advance(entry.capability_revision);
        for (entry.typed_bindings.items) |binding| _ = try identity.advance(binding.revision);
        try rebind(factory_value.context, handle, context);
        entry.target = destination.target;
        entry.attachment = destination;
        entry.capability_revision = revision;
        for (entry.typed_bindings.items) |*binding| binding.revision += 1;
    }

    pub fn failed(self: *SessionHost, handle: SessionHandle, key: OperationKey, failure: operations.Failure) !bool {
        const entry = self.find(handle) orelse return false;
        if (!entry.create_operation.eql(key) or (entry.state != .creating and entry.state != .ready)) return false;
        if (entry.state == .ready and entry.purpose == .socks_background) return false;
        _ = if (failure.cleanup == .released) try self.journal.failReleased(key, failure) else try self.journal.publish(key, .failed, "", failure);
        entry.bindings.clearRetainingCapacity();
        entry.typed_bindings.clearRetainingCapacity();
        entry.capability_revision +|= 1;
        entry.state = .failed;
        entry.creation_ended = true;
        entry.create_cleanup = failure.cleanup;
        return true;
    }

    /// A live transport can fail after its create operation completed. Keep
    /// that operation terminal, revoke its services, and use its real cleanup
    /// receipt as the gate for retrying the same logical session.
    pub fn transportLost(self: *SessionHost, handle: SessionHandle, key: OperationKey, failure: operations.Failure) !bool {
        const entry = self.find(handle) orelse return false;
        const running = entry.state == .attached or (entry.state == .ready and entry.purpose == .socks_background and entry.ready_accepted);
        if (!entry.create_operation.eql(key) or !running or !self.manifest(entry).integration.transport_loss) return false;
        _ = try self.journal.publish(key, switch (failure.cleanup) {
            .released => .cleanup_released,
            .unknown => .cleanup_unknown,
            .not_started, .releasing => .cleanup_progress,
        }, "transport lost", failure);
        entry.bindings.clearRetainingCapacity();
        entry.typed_bindings.clearRetainingCapacity();
        entry.capability_revision +|= 1;
        entry.state = .failed;
        entry.creation_ended = true;
        entry.create_cleanup = failure.cleanup;
        return true;
    }

    /// A server shell ending revokes live services without inventing a transport
    /// failure or scheduling another connection. Output remains with its pane.
    pub fn shellEnded(self: *SessionHost, handle: SessionHandle, key: OperationKey, cleanup: operations.Cleanup) !bool {
        const entry = self.find(handle) orelse return false;
        if (!entry.create_operation.eql(key) or entry.state != .attached or !self.manifest(entry).integration.retry_after_end) return false;
        _ = try self.journal.publish(key, switch (cleanup) {
            .released => .cleanup_released,
            .unknown => .cleanup_unknown,
            .not_started, .releasing => .cleanup_progress,
        }, "shell ended", null);
        entry.bindings.clearRetainingCapacity();
        entry.typed_bindings.clearRetainingCapacity();
        entry.capability_revision +|= 1;
        entry.state = .ended;
        entry.creation_ended = true;
        entry.create_cleanup = cleanup;
        return true;
    }

    /// Cancellation/factory failure may finish cleanup asynchronously. Only the
    /// same handle+operation can release its retry gate; unknown never grants it.
    pub fn createCleanupReceipt(self: *SessionHost, handle: SessionHandle, key: OperationKey, receipt: CloseReceipt) !bool {
        const entry = self.find(handle) orelse return false;
        if (!entry.creation_ended or !entry.create_operation.eql(key) or entry.create_cleanup == .released) return false;
        try self.applyCreateCleanup(entry, receipt);
        return true;
    }

    pub fn queryState(self: *SessionHost, handle: SessionHandle) ?SessionSnapshot {
        const entry = self.find(handle) orelse return null;
        return .{ .handle = entry.handle, .plugin_id = if (self.manifest(entry).legacy_descriptor) |descriptor| descriptor.plugin_id else .external, .protocol_id = entry.manifest_id, .purpose = entry.purpose, .lifecycle = entry.state, .target = entry.target, .attachment = entry.attachment, .create_operation = entry.create_operation, .close_operation = entry.close_operation, .create_cleanup = entry.create_cleanup };
    }

    /// Compatibility engine API consumes the same typed bindings as new clients.
    pub fn queryService(self: *SessionHost, handle: SessionHandle, kind: ServiceKind) ServiceQuery {
        const entry = self.find(handle) orelse return .{ .temporarily_unavailable = "会话已失效" };
        if (entry.purpose == .socks_background and !backgroundServices().has(kind)) return .unsupported;
        if (kind == .lifecycle) return switch (self.queryTypedService(handle, Adapter.VTable, .{ .name = "lifecycle" })) {
            .available => self.queryLegacyService(handle, kind),
            .unsupported => .unsupported,
            .denied => |failure| .{ .temporarily_unavailable = failure.reason },
            .temporarily_unavailable => |failure| .{ .temporarily_unavailable = failure.reason },
        };
        inline for (comptime std.meta.tags(ServiceKind)) |candidate| if (kind == candidate) {
            return switch (self.queryTypedService(handle, LegacyService(candidate), .{ .name = @tagName(candidate) })) {
                .available => |service| .{ .available = service.vtable.resolve(service.context, service.binding) catch return .{ .temporarily_unavailable = "服务绑定已失效或未授权" } },
                .unsupported => .unsupported,
                .temporarily_unavailable => |failure| .{ .temporarily_unavailable = failure.reason },
                .denied => |failure| .{ .temporarily_unavailable = failure.reason },
            };
        };
        unreachable;
    }
    fn queryLegacyService(self: *SessionHost, handle: SessionHandle, kind: ServiceKind) ServiceQuery {
        const entry = self.find(handle) orelse return .{ .temporarily_unavailable = "会话已失效" };
        if (entry.purpose == .socks_background and !backgroundServices().has(kind)) return .unsupported;
        if ((kind == .directory or kind == .file_read) and self.manifest(entry).integration.auxiliary_readonly) {
            if (self.findAuxiliaryReadonly(handle)) |source| if (source.live and self.auxiliaryReadonlyIsCurrent(handle, source.key)) {
                return .{ .available = if (kind == .directory) source.bindings.directory else source.bindings.file_read };
            };
            return .{ .temporarily_unavailable = "远程文件读取连接尚未就绪或正在关闭" };
        }
        // This optional service belongs to the independent file Runtime, not
        // the SSH terminal adapter's ready-services receipt.
        if (kind == .transfer and self.manifest(entry).integration.auxiliary_transfer) {
            if (self.findAuxiliary(handle)) |auxiliary| {
                if (auxiliary.live and self.auxiliaryTransferOperationIsCurrent(handle, auxiliary.key)) return .{ .available = auxiliary.binding };
            }
            if (self.findShared(handle)) |shared| if (shared.live and self.sharedTransferOperationIsCurrent(handle, shared.key)) return .{ .available = shared.binding };
            return .{ .temporarily_unavailable = "文件传输连接尚未就绪或正在关闭" };
        }
        if ((kind == .directory or kind == .file_read) and self.manifest(entry).integration.directory_recovery) {
            if (self.sftpDirectoryRecovery(handle)) |recovery| {
                if (entry.state != .attached or !recovery.live or recovery.cleanup != .awaiting) return .{ .temporarily_unavailable = "SFTP 目录连接正在恢复或已失效" };
            }
        }
        if (!(self.manifest(entry).legacy_registration orelse return .unsupported).services.has(kind)) return .unsupported;
        if (entry.state != .ready and entry.state != .attached) return .{ .temporarily_unavailable = "会话尚未就绪或正在关闭" };
        for (entry.bindings.items) |binding| if (binding.kind == kind) return .{ .available = binding };
        return .{ .temporarily_unavailable = "当前适配器未提供此服务" };
    }

    pub fn bindingIsLive(self: *SessionHost, binding: ServiceHandle) bool {
        if (binding.resource_owner == .session) {
            const entry = self.find(binding.resource_owner.session) orelse return false;
            for (entry.typed_bindings.items) |current| if (current.definition.key.eql(.{ .name = @tagName(binding.kind) }) and !current.authorized) return false;
        }
        if (binding.kind == .transfer and binding.resource_owner == .session) {
            const original = binding.resource_owner.session;
            if (self.findShared(original)) |shared| if (shared.binding.eql(binding)) return shared.live and self.sharedTransferOperationIsCurrent(original, shared.key);
            if (self.findAuxiliary(original)) |auxiliary| if (auxiliary.binding.eql(binding)) return auxiliary.live and self.auxiliaryTransferOperationIsCurrent(original, auxiliary.key);
        }
        const handle = switch (binding.resource_owner) {
            .session => |handle| handle,
            .retained_transfer => |id| {
                const retained = self.findRetained(id) orelse return false;
                return !retained.closing and retained.live and retained.cleanup == .awaiting and retained.binding != null and retained.binding.?.eql(binding);
            },
        };
        return switch (self.queryService(handle, binding.kind)) {
            .available => |current| current.eql(binding),
            else => false,
        };
    }

    /// Explicit user recovery of the original standalone file card. Reservation
    /// revokes its exact read pair immediately, but cannot authorize new IO until
    /// the old native service and every operation have actually released.
    pub fn beginSftpDirectoryRecovery(self: *SessionHost, owner: SessionHandle, previous: SftpDirectoryPair) !SftpDirectoryRecovery {
        const entry = self.find(owner) orelse return error.StaleSession;
        if (!self.manifest(entry).integration.directory_recovery or entry.state != .attached) return error.LifecycleDoesNotAllowDirectoryRecovery;
        if (previous.directory.kind != .directory or previous.file_read.kind != .file_read) return error.ServiceKindMismatch;
        if (previous.directory.resource_owner != .session or !previous.directory.resource_owner.session.eql(owner) or previous.file_read.resource_owner != .session or !previous.file_read.resource_owner.session.eql(owner)) return error.OwnerMismatch;
        var slot: ?usize = null;
        var generation = previous.directory.binding_generation;
        for (self.sftp_directory_recoveries.items, 0..) |recovery, i| if (recovery.owner.eql(owner)) {
            if (recovery.cleanup != .released) return error.CleanupNotReleased;
            if (!std.meta.eql(previous, if (recovery.published) recovery.bindings else recovery.previous)) return error.StaleBinding;
            slot = i;
            generation = @max(generation, recovery.bindings.directory.binding_generation);
            break;
        };
        if (slot == null) {
            var directory_matches = false;
            var read_matches = false;
            for (entry.bindings.items) |binding| {
                directory_matches = directory_matches or binding.eql(previous.directory);
                read_matches = read_matches or binding.eql(previous.file_read);
            }
            if (!directory_matches or !read_matches) return error.StaleBinding;
        }
        generation = std.math.add(u64, generation, 1) catch return error.BindingGenerationExhausted;
        if (self.binding_exhausted or self.next_binding >= std.math.maxInt(u64) - 1) return error.BindingExhausted;
        if (slot == null) try self.sftp_directory_recoveries.ensureUnusedCapacity(self.allocator, 1);
        const key = try self.journal.begin(.{ .session = owner }, entry.attempt);
        const pair: SftpDirectoryPair = .{
            .directory = .{ .resource_owner = .{ .session = owner }, .origin_session = owner, .kind = .directory, .binding_id = self.next_binding, .binding_generation = generation },
            .file_read = .{ .resource_owner = .{ .session = owner }, .origin_session = owner, .kind = .file_read, .binding_id = self.next_binding + 1, .binding_generation = generation },
        };
        self.next_binding += 2;
        var i = entry.bindings.items.len;
        while (i > 0) {
            i -= 1;
            if (entry.bindings.items[i].kind == .directory or entry.bindings.items[i].kind == .file_read) _ = entry.bindings.orderedRemove(i);
        }
        self.capabilityChanged(owner);
        const recovery: SftpDirectoryRecovery = .{ .owner = owner, .previous = previous, .bindings = pair, .key = key };
        if (slot) |at| self.sftp_directory_recoveries.items[at] = recovery else self.sftp_directory_recoveries.appendAssumeCapacity(recovery);
        return recovery;
    }
    pub fn sftpDirectoryRecovery(self: *SessionHost, owner: SessionHandle) ?SftpDirectoryRecovery {
        for (self.sftp_directory_recoveries.items) |value| if (value.owner.eql(owner)) return value;
        return null;
    }
    pub fn sftpDirectoryPreviousReleased(self: *SessionHost, owner: SessionHandle, key: OperationKey, previous: SftpDirectoryPair, receipt: CloseReceipt) bool {
        for (self.sftp_directory_recoveries.items) |*value| if (value.owner.eql(owner) and value.key.eql(key) and std.meta.eql(value.previous, previous)) {
            if (value.old_cleanup != .unknown or receipt == .released) value.old_cleanup = receipt;
            return true;
        };
        return false;
    }
    pub fn sftpDirectoryRecoveryPreparing(self: *SessionHost, binding: ServiceHandle, key: OperationKey) bool {
        if (binding.resource_owner != .session) return false;
        const owner = binding.resource_owner.session;
        const entry = self.find(owner) orelse return false;
        const value = self.sftpDirectoryRecovery(owner) orelse return false;
        return entry.state == .attached and value.key.eql(key) and value.old_cleanup == .released and value.cleanup == .awaiting and !value.live and !self.journal.isTerminal(key) and (value.bindings.directory.eql(binding) or value.bindings.file_read.eql(binding));
    }
    pub fn sftpDirectoryRecoveryReady(self: *SessionHost, owner: SessionHandle, key: OperationKey, pair: SftpDirectoryPair) !bool {
        if (!self.sftpDirectoryRecoveryPreparing(pair.directory, key) or !self.sftpDirectoryRecoveryPreparing(pair.file_read, key)) return false;
        const entry = self.find(owner) orelse return false;
        for (self.sftp_directory_recoveries.items) |*value| if (value.owner.eql(owner) and value.key.eql(key) and std.meta.eql(value.bindings, pair)) {
            try entry.bindings.ensureUnusedCapacity(self.allocator, 2);
            _ = try self.journal.publish(key, .completed, "standalone SFTP directory recovered", null);
            entry.bindings.appendAssumeCapacity(pair.directory);
            entry.bindings.appendAssumeCapacity(pair.file_read);
            value.live = true;
            self.capabilityChanged(owner);
            value.published = true;
            return true;
        };
        return false;
    }
    pub fn sftpDirectoryRecoveryReleased(self: *SessionHost, binding: ServiceHandle, key: OperationKey, receipt: CloseReceipt) !bool {
        for (self.sftp_directory_recoveries.items) |*value| if (value.key.eql(key) and (value.bindings.directory.eql(binding) or value.bindings.file_read.eql(binding))) {
            if (value.cleanup == .released) return true;
            value.live = false;
            self.capabilityChanged(value.owner);
            if (value.cleanup != .unknown or receipt == .released) value.cleanup = receipt;
            if (!self.journal.isTerminal(key)) _ = try self.journal.publish(key, .cancelled, "standalone SFTP directory recovery ended", null);
            _ = try self.journal.publish(key, if (receipt == .released) .cleanup_released else if (receipt == .unknown) .cleanup_unknown else .cleanup_progress, "standalone SFTP directory cleanup", null);
            return true;
        };
        return false;
    }

    /// Reserve identities only. A real FileBindingHost connection must publish
    /// ready; neither descriptor support nor reservation grants read authority.
    pub fn beginAuxiliaryReadonly(self: *SessionHost, owner: SessionHandle) !AuxiliaryReadonlyStart {
        const entry = self.find(owner) orelse return error.StaleSession;
        if (!self.manifest(entry).integration.auxiliary_readonly) return error.UnsupportedProtocol;
        if (entry.state != .attached) return error.LifecycleDoesNotAllowTransfer;
        var slot: ?usize = null;
        var generation: u64 = 1;
        for (self.auxiliary_readonly.items, 0..) |source, index| if (source.owner.eql(owner)) {
            if (source.cleanup != .released) {
                if (self.auxiliaryReadonlyIsCurrent(owner, source.key)) return .{ .bindings = source.bindings, .key = source.key };
                return error.CleanupNotReleased;
            }
            slot = index;
            generation = std.math.add(u64, source.bindings.directory.binding_generation, 1) catch return error.BindingGenerationExhausted;
            break;
        };
        if (self.binding_exhausted or self.next_binding == std.math.maxInt(u64)) return error.BindingExhausted;
        if (slot == null) try self.auxiliary_readonly.ensureUnusedCapacity(self.allocator, 1);
        const key = try self.journal.begin(.{ .session = owner }, entry.attempt);
        const directory: ServiceHandle = .{ .resource_owner = .{ .session = owner }, .origin_session = owner, .kind = .directory, .binding_id = self.next_binding, .binding_generation = generation };
        const file_read: ServiceHandle = .{ .resource_owner = .{ .session = owner }, .origin_session = owner, .kind = .file_read, .binding_id = self.next_binding + 1, .binding_generation = generation };
        if (self.next_binding + 1 == std.math.maxInt(u64)) self.binding_exhausted = true else self.next_binding += 2;
        const source: AuxiliaryReadonly = .{ .owner = owner, .bindings = .{ .directory = directory, .file_read = file_read }, .key = key };
        if (slot) |index| self.auxiliary_readonly.items[index] = source else self.auxiliary_readonly.appendAssumeCapacity(source);
        return .{ .bindings = source.bindings, .key = key };
    }
    pub fn auxiliaryReadonlyIsCurrent(self: *SessionHost, owner: SessionHandle, key: OperationKey) bool {
        const entry = self.find(owner) orelse return false;
        const source = self.findAuxiliaryReadonly(owner) orelse return false;
        return entry.state == .attached and self.manifest(entry).integration.auxiliary_readonly and source.key.eql(key) and source.cleanup == .awaiting and !self.journal.isTerminal(key);
    }
    pub fn auxiliaryReadonlyOwns(self: *SessionHost, owner: SessionHandle, start: AuxiliaryReadonlyStart) bool {
        const source = self.findAuxiliaryReadonly(owner) orelse return false;
        return source.key.eql(start.key) and source.bindings.directory.eql(start.bindings.directory) and source.bindings.file_read.eql(start.bindings.file_read);
    }
    pub fn auxiliaryReadonlyReady(self: *SessionHost, owner: SessionHandle, start: AuxiliaryReadonlyStart) !bool {
        if (!self.auxiliaryReadonlyOwns(owner, start) or !self.auxiliaryReadonlyIsCurrent(owner, start.key)) return false;
        const source = self.findAuxiliaryReadonly(owner).?;
        if (source.live) return true;
        _ = try self.journal.publish(start.key, .progress, "remote readonly source ready", null);
        source.live = true;
        self.capabilityChanged(owner);
        return true;
    }
    pub fn auxiliaryReadonlyReleased(self: *SessionHost, owner: SessionHandle, start: AuxiliaryReadonlyStart, receipt: CloseReceipt) !bool {
        if (!self.auxiliaryReadonlyOwns(owner, start)) return false;
        const source = self.findAuxiliaryReadonly(owner).?;
        if (source.cleanup == .released) return true;
        source.live = false;
        self.capabilityChanged(owner);
        if (receipt == .released) {
            if (!self.journal.isTerminal(start.key)) _ = try self.journal.publish(start.key, .cancelled, "remote readonly source closed", null);
            _ = try self.journal.publish(start.key, .cleanup_released, "remote readonly source released", null);
        } else _ = try self.journal.publish(start.key, if (receipt == .unknown) .cleanup_unknown else .cleanup_progress, "remote readonly source cleanup", null);
        if (source.cleanup != .unknown or receipt == .released) source.cleanup = receipt;
        return true;
    }
    fn findAuxiliaryReadonly(self: *SessionHost, owner: SessionHandle) ?*AuxiliaryReadonly {
        for (self.auxiliary_readonly.items) |*source| if (source.owner.eql(owner)) return source;
        return null;
    }

    /// An attached SSH may explicitly request one independent, no-shell file
    /// connection. The caller must use its actual Runtime ready/release
    /// receipts below. Reserving never publishes a terminal adapter capability.
    /// Source slices borrow the original immutable session snapshot.
    pub fn beginAuxiliaryTransfer(self: *SessionHost, owner: SessionHandle) !AuxiliaryTransferStart {
        const entry = self.find(owner) orelse return error.StaleSession;
        if (!self.manifest(entry).integration.auxiliary_readonly) return error.UnsupportedProtocol;
        if (entry.state != .attached) return error.LifecycleDoesNotAllowTransfer;
        var slot: ?usize = null;
        var generation: u64 = 1;
        for (self.auxiliary_transfers.items, 0..) |auxiliary, index| if (auxiliary.owner.eql(owner)) {
            if (auxiliary.cleanup != .released) {
                if (self.auxiliaryTransferOperationIsCurrent(owner, auxiliary.key)) return .{ .binding = auxiliary.binding, .key = auxiliary.key, .spec = sourceSpec(entry) };
                return error.CleanupNotReleased;
            }
            slot = index;
            generation = std.math.add(u64, auxiliary.binding.binding_generation, 1) catch return error.BindingGenerationExhausted;
            break;
        };
        if (self.binding_exhausted) return error.BindingExhausted;
        if (slot == null) try self.auxiliary_transfers.ensureUnusedCapacity(self.allocator, 1);
        const key = try self.journal.begin(.{ .session = owner }, entry.attempt);
        const binding: ServiceHandle = .{ .resource_owner = .{ .session = owner }, .origin_session = owner, .kind = .transfer, .binding_id = self.next_binding, .binding_generation = generation };
        if (self.next_binding == std.math.maxInt(u64)) self.binding_exhausted = true else self.next_binding += 1;
        const auxiliary: AuxiliaryTransfer = .{ .owner = owner, .binding = binding, .key = key };
        if (slot) |index| self.auxiliary_transfers.items[index] = auxiliary else self.auxiliary_transfers.appendAssumeCapacity(auxiliary);
        return .{ .binding = binding, .key = key, .spec = sourceSpec(entry) };
    }

    pub fn auxiliaryTransferOperationIsCurrent(self: *SessionHost, owner: SessionHandle, key: OperationKey) bool {
        const entry = self.find(owner) orelse return false;
        if (entry.state != .attached or !self.manifest(entry).integration.auxiliary_transfer) return false;
        const auxiliary = self.findAuxiliary(owner) orelse return false;
        return auxiliary.key.eql(key) and !auxiliary.closing and auxiliary.cleanup == .awaiting and !self.journal.isTerminal(key);
    }

    /// Identity evidence for exact cleanup retries, including after release.
    /// It grants neither startup nor consumer authority.
    pub fn auxiliaryTransferOwns(self: *SessionHost, binding: ServiceHandle, key: OperationKey) bool {
        if (binding.resource_owner != .session or binding.kind != .transfer) return false;
        const auxiliary = self.findAuxiliary(binding.resource_owner.session) orelse return false;
        return auxiliary.binding.eql(binding) and auxiliary.key.eql(key);
    }

    /// Called only after this exact independent Runtime initialized SFTP.
    pub fn auxiliaryTransferReady(self: *SessionHost, binding: ServiceHandle, key: OperationKey) !bool {
        if (binding.resource_owner != .session or binding.kind != .transfer) return false;
        const auxiliary = self.findAuxiliary(binding.resource_owner.session) orelse return false;
        if (!auxiliary.binding.eql(binding) or auxiliary.live or !self.auxiliaryTransferOperationIsCurrent(auxiliary.owner, key)) return false;
        _ = try self.journal.publish(key, .progress, "auxiliary transfer ready", null);
        auxiliary.live = true;
        self.capabilityChanged(auxiliary.owner);
        return true;
    }

    /// The original auxiliary operation accepts cleanup even after its SSH
    /// starts closing. Unknown/OOM never grants another binding generation.
    pub fn auxiliaryTransferReleased(self: *SessionHost, binding: ServiceHandle, key: OperationKey, receipt: CloseReceipt) !bool {
        if (binding.resource_owner != .session or binding.kind != .transfer) return false;
        const auxiliary = self.findAuxiliary(binding.resource_owner.session) orelse return false;
        if (!auxiliary.binding.eql(binding) or !auxiliary.key.eql(key) or auxiliary.cleanup == .released) return false;
        auxiliary.live = false;
        self.capabilityChanged(auxiliary.owner);
        auxiliary.closing = true;
        if (receipt == .released) {
            _ = try self.journal.completeReleased(key, "auxiliary transfer released");
        } else {
            _ = try self.journal.publish(key, if (receipt == .unknown) .cleanup_unknown else .cleanup_progress, "auxiliary transfer cleanup", null);
        }
        if (auxiliary.cleanup != .unknown or receipt == .released) auxiliary.cleanup = receipt;
        self.publishFaultReceipt(binding, key, receipt);
        return true;
    }

    fn findAuxiliary(self: *SessionHost, owner: SessionHandle) ?*AuxiliaryTransfer {
        for (self.auxiliary_transfers.items) |*auxiliary| if (auxiliary.owner.eql(owner)) return auxiliary;
        return null;
    }

    /// The actual original SSH Worker supplies the SFTP mailbox. This service
    /// has no connector transaction or second transport to authenticate.
    pub fn beginSharedTransfer(self: *SessionHost, owner: SessionHandle) !SharedTransferStart {
        const entry = self.find(owner) orelse return error.StaleSession;
        if (!self.manifest(entry).integration.auxiliary_transfer) return error.UnsupportedProtocol;
        if (entry.state != .attached) return error.LifecycleDoesNotAllowTransfer;
        if (self.findShared(owner)) |shared| {
            if (shared.closing or shared.cleanup != .awaiting) return error.CleanupNotReleased;
            if (!shared.key.eql(entry.create_operation)) return error.StaleCreateOperation;
            return .{ .binding = shared.binding, .key = shared.key };
        }
        try self.shared_transfers.ensureUnusedCapacity(self.allocator, 1);
        const binding = try self.reserveBinding(entry, .transfer);
        self.shared_transfers.appendAssumeCapacity(.{ .owner = owner, .binding = binding, .key = entry.create_operation });
        return .{ .binding = binding, .key = entry.create_operation };
    }

    pub fn sharedTransferOperationIsCurrent(self: *SessionHost, owner: SessionHandle, key: OperationKey) bool {
        const entry = self.find(owner) orelse return false;
        const shared = self.findShared(owner) orelse return false;
        return self.manifest(entry).integration.auxiliary_transfer and entry.state == .attached and entry.create_operation.eql(key) and shared.key.eql(key) and !shared.closing and shared.cleanup == .awaiting;
    }

    pub fn sharedTransferReady(self: *SessionHost, binding: ServiceHandle, key: OperationKey) bool {
        if (binding.kind != .transfer or binding.resource_owner != .session) return false;
        const shared = self.findShared(binding.resource_owner.session) orelse return false;
        if (!shared.binding.eql(binding) or !self.sharedTransferOperationIsCurrent(shared.owner, key)) return false;
        shared.live = true;
        self.capabilityChanged(shared.owner);
        return true;
    }

    pub fn sharedTransferReleased(self: *SessionHost, binding: ServiceHandle, key: OperationKey, receipt: CloseReceipt) bool {
        if (binding.kind != .transfer or binding.resource_owner != .session) return false;
        const shared = self.findShared(binding.resource_owner.session) orelse return false;
        if (!shared.binding.eql(binding) or !shared.key.eql(key)) return false;
        shared.live = false;
        self.capabilityChanged(shared.owner);
        shared.closing = true;
        if (shared.cleanup != .unknown or receipt == .released) shared.cleanup = receipt;
        self.publishFaultReceipt(binding, key, receipt);
        return true;
    }

    fn findShared(self: *SessionHost, owner: SessionHandle) ?*SharedTransfer {
        for (self.shared_transfers.items) |*shared| if (shared.owner.eql(owner)) return shared;
        return null;
    }

    /// Register before the original pause-transfers close step releases. This
    /// owns source values only; callers must separately hand off real jobs.
    pub fn retainTransferSource(self: *SessionHost, original: SessionHandle) !identity.RetainedTransferOwnerId {
        return self.retainSource(original, false);
    }

    fn retainSource(self: *SessionHost, original: SessionHandle, shared_fault: bool) !identity.RetainedTransferOwnerId {
        for (self.retained_transfers.items) |retained| if (retained.original.eql(original)) return retained.id;
        const entry = self.find(original) orelse return error.StaleSession;
        if (entry.purpose != .interactive) return error.UnsupportedSessionService;
        if (!self.manifest(entry).integration.auxiliary_transfer and !self.manifest(entry).integration.directory_recovery) return error.UnsupportedProtocol;
        if (entry.state != .attached and entry.state != .ready and !((entry.state == .closing or entry.state == .cleanup_unknown) and entry.close_step == .pause_transfers) and !(shared_fault and (entry.state == .failed or entry.state == .ended))) return error.LifecycleDoesNotAllowRetain;
        var source = try Snapshot(SessionCreateSpec).init(self.allocator, sourceSpec(entry));
        errdefer source.deinit();
        try self.retained_transfers.ensureUnusedCapacity(self.allocator, 1);
        const id = try self.retained_ids.allocate();
        self.retained_transfers.appendAssumeCapacity(.{ .id = id, .original = original, .spec = source });
        return id;
    }

    /// Preserve only an exact revoked transfer source. This does not release
    /// its transport or grant a new connection before the real release receipt.
    pub fn retainFaultTransferSource(self: *SessionHost, binding: ServiceHandle, key: OperationKey) !identity.RetainedTransferOwnerId {
        const original = binding.origin_session orelse return error.StaleBinding;
        if (binding.kind != .transfer) return error.StaleBinding;
        var shared_fault = false;
        const receipt: CloseReceipt = switch (binding.resource_owner) {
            .session => blk: {
                if (self.findShared(original)) |shared| if (shared.binding.eql(binding)) {
                    if (!shared.key.eql(key) or !shared.closing) return error.StaleBinding;
                    shared_fault = true;
                    break :blk shared.cleanup;
                };
                const auxiliary = self.findAuxiliary(original) orelse return error.StaleBinding;
                if (!auxiliary.binding.eql(binding) or !auxiliary.key.eql(key) or !auxiliary.closing) return error.StaleBinding;
                break :blk auxiliary.cleanup;
            },
            .retained_transfer => |id| blk: {
                const retained = self.findRetained(id) orelse return error.UnknownRetainedTransfer;
                if (!retained.original.eql(original) or retained.binding == null or !retained.binding.?.eql(binding) or retained.key == null or !retained.key.?.eql(key) or !retained.closing) return error.StaleBinding;
                break :blk retained.cleanup;
            },
        };
        const id = if (binding.resource_owner == .retained_transfer) binding.resource_owner.retained_transfer else try self.retainSource(original, shared_fault);
        const retained = self.findRetained(id).?;
        for (retained.faults.items) |fault| if (fault.binding.eql(binding) and fault.key.eql(key)) return id;
        try retained.faults.append(self.allocator, .{ .binding = binding, .key = key, .cleanup = receipt });
        return id;
    }

    pub fn faultTransferSourceIsCurrent(self: *SessionHost, id: identity.RetainedTransferOwnerId, original: SessionHandle, binding: ServiceHandle, key: OperationKey) bool {
        const retained = self.findRetained(id) orelse return false;
        if (!retained.original.eql(original)) return false;
        for (retained.faults.items) |fault| if (fault.binding.eql(binding) and fault.key.eql(key)) return true;
        return false;
    }

    fn publishFaultReceipt(self: *SessionHost, binding: ServiceHandle, key: OperationKey, receipt: CloseReceipt) void {
        for (self.retained_transfers.items) |*retained| for (retained.faults.items) |*fault| {
            if (fault.binding.eql(binding) and fault.key.eql(key) and (fault.cleanup != .unknown or receipt == .released)) fault.cleanup = receipt;
        };
    }

    /// Borrowed until releaseRetainedTransfer/deinit; never reads an asset or
    /// a newly opened same-name session to reconstruct the original source.
    pub fn retainedTransferSource(self: *SessionHost, id: identity.RetainedTransferOwnerId, original: SessionHandle) ?SessionCreateSpec {
        const retained = self.findRetained(id) orelse return null;
        if (!retained.original.eql(original)) return null;
        return retained.spec.value;
    }

    pub fn retainedTransferOperationIsCurrent(self: *SessionHost, id: identity.RetainedTransferOwnerId, original: SessionHandle, key: OperationKey) bool {
        const retained = self.findRetained(id) orelse return false;
        return !retained.closing and retained.original.eql(original) and retained.key != null and retained.key.?.eql(key) and retained.cleanup == .awaiting and !self.journal.isTerminal(key);
    }

    /// Explicit resume starts a new, isolated transfer service transaction.
    /// This never revives the original session or exposes Terminal/Exec/Auth.
    pub fn beginRetainedTransfer(self: *SessionHost, id: identity.RetainedTransferOwnerId, original: SessionHandle) !RetainedTransferStart {
        const retained = self.findRetained(id) orelse return error.UnknownRetainedTransfer;
        if (!retained.original.eql(original)) return error.RetainedOwnerMismatch;
        const source = self.find(original) orelse return error.StaleSession;
        var fault_released = false;
        for (retained.faults.items) |fault| {
            if (fault.cleanup != .released) return error.CleanupNotReleased;
            fault_released = true;
        }
        if (source.state != .closed) {
            if (source.state != .attached or !self.manifest(source).integration.auxiliary_transfer or !fault_released) return error.OriginalSessionNotClosed;
        }
        if (retained.cleanup != .released) return error.CleanupNotReleased;
        if (self.binding_exhausted) return error.BindingExhausted;
        const generation = try std.math.add(u64, retained.generation, 1);
        const key = try self.journal.begin(.{ .transfer_owner = .{ .id = id, .original_handle = original } }, generation);
        const binding: ServiceHandle = .{ .resource_owner = .{ .retained_transfer = id }, .origin_session = original, .kind = .transfer, .binding_id = self.next_binding, .binding_generation = generation };
        if (self.next_binding == std.math.maxInt(u64)) self.binding_exhausted = true else self.next_binding += 1;
        retained.binding = binding;
        retained.key = key;
        retained.generation = generation;
        retained.live = false;
        retained.closing = false;
        retained.cleanup = .awaiting;
        return .{ .binding = binding, .key = key, .spec = retained.spec.value };
    }

    pub fn retainedTransferReady(self: *SessionHost, binding: ServiceHandle, key: OperationKey) !bool {
        if (!self.bindingIsPreparing(binding, key) or binding.resource_owner != .retained_transfer) return false;
        const retained = self.findRetained(binding.resource_owner.retained_transfer).?;
        _ = try self.journal.publish(key, .progress, "retained transfer ready", null);
        retained.live = true;
        return true;
    }

    /// Only an actual Runtime release receipt may unblock another generation.
    pub fn retainedTransferReleased(self: *SessionHost, binding: ServiceHandle, key: OperationKey, receipt: CloseReceipt) !bool {
        if (binding.resource_owner != .retained_transfer) return false;
        const retained = self.findRetained(binding.resource_owner.retained_transfer) orelse return false;
        if (retained.binding == null or !retained.binding.?.eql(binding) or retained.key == null or !retained.key.?.eql(key) or retained.cleanup == .released) return false;
        // Revoke consumer/startup authority even when receipt publication OOMs.
        // The cleanup gate advances only after that publication succeeds.
        retained.live = false;
        retained.closing = true;
        if (receipt == .released) {
            _ = try self.journal.completeReleased(key, "retained transfer released");
        } else {
            _ = try self.journal.publish(key, if (receipt == .unknown) .cleanup_unknown else .cleanup_progress, "retained transfer cleanup", null);
        }
        if (retained.cleanup != .unknown or receipt == .released) retained.cleanup = receipt;
        self.publishFaultReceipt(binding, key, receipt);
        return true;
    }

    /// The job owner calls this only after all checkpoints/jobs terminate.
    pub fn releaseRetainedTransfer(self: *SessionHost, id: identity.RetainedTransferOwnerId, original: SessionHandle) !void {
        for (self.retained_transfers.items, 0..) |retained, index| if (retained.id == id) {
            if (!retained.original.eql(original)) return error.RetainedOwnerMismatch;
            if (retained.cleanup != .released) return error.CleanupNotReleased;
            for (retained.faults.items) |fault| if (fault.cleanup != .released) return error.CleanupNotReleased;
            var removed = self.retained_transfers.orderedRemove(index);
            removed.spec.deinit();
            removed.faults.deinit(self.allocator);
            return;
        };
        return error.UnknownRetainedTransfer;
    }

    fn findRetained(self: *SessionHost, id: identity.RetainedTransferOwnerId) ?*RetainedTransfer {
        for (self.retained_transfers.items) |*retained| if (retained.id == id) return retained;
        return null;
    }

    /// Repeated requests, including cleanup_unknown, return the original key.
    /// Services are gated immediately, before any asynchronous hook runs.
    pub fn requestClose(self: *SessionHost, handle: SessionHandle, hooks: CloseHooks) !OperationKey {
        const entry = self.find(handle) orelse return error.StaleSession;
        if (entry.close_operation) |key| {
            if (entry.close_resources_released and entry.state != .closed) try self.finishClose(entry);
            return key;
        }
        if (entry.state == .creating or (entry.state == .ready and entry.purpose == .interactive)) _ = try self.cancel(entry.create_operation);
        const key = try self.journal.begin(.{ .session = handle }, entry.attempt);
        entry.close_operation = key;
        entry.hooks = hooks;
        self.capabilityChanged(handle);
        entry.state = .closing;
        try self.advanceClose(entry);
        return key;
    }

    /// Last controller barrier before its window facades are destroyed. This
    /// revokes authority and stops the original factory without dereferencing
    /// view hooks that may already be tearing down. It reports protocol cleanup
    /// only: Cx still owns and releases the content tree afterwards.
    pub fn shutdownOwner(self: *SessionHost, handle: SessionHandle) !CloseReceipt {
        const entry = self.find(handle) orelse return .released;
        if (entry.state == .closed or entry.shutdown_receipt == .released) return .released;
        if (entry.shutdown_receipt == null) {
            entry.shutdown_via_cancel = entry.state == .creating or entry.creation_ended or (entry.state == .ready and entry.attachment == null);
            entry.bindings.clearRetainingCapacity();
            entry.typed_bindings.clearRetainingCapacity();
            entry.available_bindings.clearRetainingCapacity();
            entry.capability_revision +|= 1;
        }
        const adapter = self.factory(entry);
        const receipt = if (entry.shutdown_via_cancel)
            adapter.vtable.cancel(adapter.context, entry.create_operation)
        else
            adapter.vtable.close(adapter.context, entry.handle, entry.close_operation orelse entry.create_operation) catch .unknown;
        entry.shutdown_receipt = receipt;
        entry.create_cleanup = switch (receipt) {
            .released => .released,
            .awaiting => .releasing,
            .unknown => .unknown,
        };
        entry.creation_ended = true;
        entry.state = if (receipt == .unknown) .cleanup_unknown else .ended;
        return receipt;
    }

    pub fn closeReceipt(self: *SessionHost, handle: SessionHandle, key: OperationKey, step: CloseStep, receipt: CloseReceipt) !bool {
        const entry = self.find(handle) orelse return false;
        if (entry.close_operation == null or !entry.close_operation.?.eql(key) or entry.close_step != step or (entry.state != .closing and entry.state != .cleanup_unknown)) return false;
        if (receipt != .released) {
            try self.recordCloseWait(entry, receipt);
            return true;
        }
        entry.state = .closing;
        if (step == .release_content) {
            try self.finishClose(entry);
        } else {
            entry.close_step = @fromBackingInt(@backingInt(step) + 1);
            try self.advanceClose(entry);
        }
        return true;
    }

    fn advanceClose(self: *SessionHost, entry: *Entry) !void {
        while (true) {
            const key = entry.close_operation.?;
            const result: CloseReceipt = if (entry.close_step == .close_protocol) blk: {
                // A cancelled/failed factory retains cleanup ownership until its
                // receipt. Do not concurrently close those same resources again.
                if (entry.creation_ended) break :blk switch (entry.create_cleanup) {
                    .released => .released,
                    .unknown => .unknown,
                    .not_started, .releasing => .awaiting,
                };
                const adapter = self.factory(entry);
                break :blk adapter.vtable.close(adapter.context, entry.handle, key) catch .unknown;
            } else if (hookFor(entry.hooks, entry.close_step)) |hook|
                hook.run(hook.context, entry.handle, key) catch .unknown
            else
                .released;
            if (result != .released) {
                try self.recordCloseWait(entry, result);
                return;
            }
            if (entry.close_step == .release_content) {
                try self.finishClose(entry);
                return;
            }
            entry.close_step = @fromBackingInt(@backingInt(entry.close_step) + 1);
        }
    }

    fn recordCloseWait(self: *SessionHost, entry: *Entry, receipt: CloseReceipt) !void {
        const unknown = receipt == .unknown;
        _ = try self.journal.publish(entry.close_operation.?, if (unknown) .cleanup_unknown else .cleanup_progress, @tagName(entry.close_step), null);
        entry.state = if (unknown) .cleanup_unknown else .closing;
    }

    fn finishClose(self: *SessionHost, entry: *Entry) !void {
        entry.close_resources_released = true;
        _ = try self.journal.completeReleased(entry.close_operation.?, "closed");
        entry.bindings.clearRetainingCapacity();
        entry.typed_bindings.clearRetainingCapacity();
        entry.capability_revision +|= 1;
        entry.attachment = null;
        entry.state = .closed;
    }

    fn startAdapter(self: *SessionHost, entry: *Entry) !void {
        const adapter = self.factory(entry);
        const context = if (self.context_factory) |factory_value| try factory_value.create(factory_value.context, entry.handle, entry.create_operation, .{ .window_id = entry.target.window_id, .workspace_id = entry.target.workspace_id }) else null;
        if (context) |value| {
            if (!value.owner.eql(entry.handle) or !value.operation.eql(entry.create_operation)) return error.InvalidHostContext;
        }
        try adapter.vtable.create(adapter.context, .{ .handle = entry.handle, .key = entry.create_operation, .target = entry.target, .spec = entry.spec.value, .purpose = entry.purpose, .context = context });
    }

    fn failCreate(self: *SessionHost, entry: *Entry, code: []const u8) !void {
        // Throwing from create means the adapter rejected before acquiring any
        // resource. Failures after acquisition use failed()+cleanup receipts.
        _ = try self.journal.failReleased(entry.create_operation, .{ .domain = .plugin, .code = code, .cleanup = .released, .safe_message = "会话创建失败" });
        entry.state = .failed;
        entry.creation_ended = true;
        entry.create_cleanup = .released;
    }

    fn applyCreateCleanup(self: *SessionHost, entry: *Entry, receipt: CloseReceipt) !void {
        const next_cleanup: operations.Cleanup = switch (receipt) {
            .released => .released,
            .awaiting => .releasing,
            .unknown => .unknown,
        };
        _ = try self.journal.publish(entry.create_operation, switch (receipt) {
            .released => .cleanup_released,
            .awaiting => .cleanup_progress,
            .unknown => .cleanup_unknown,
        }, "", null);
        entry.create_cleanup = next_cleanup;
        if (receipt == .released and entry.close_operation != null and entry.close_step == .close_protocol and (entry.state == .closing or entry.state == .cleanup_unknown)) {
            entry.state = .closing;
            entry.close_step = .release_content;
            try self.advanceClose(entry);
        }
    }

    fn releaseStale(self: *SessionHost, handle: SessionHandle, key: OperationKey) void {
        for (self.sessions.items) |entry| if (entry.handle.session_id == handle.session_id) {
            const adapter = self.factory(&entry);
            adapter.vtable.release_stale(adapter.context, handle, key);
            return;
        };
    }

    fn find(self: *SessionHost, handle: SessionHandle) ?*Entry {
        for (self.sessions.items) |*entry| if (entry.handle.eql(handle)) return entry;
        return null;
    }

    fn findKey(self: *SessionHost, key: OperationKey) ?*Entry {
        for (self.sessions.items) |*entry| if (entry.create_operation.eql(key)) return entry;
        return null;
    }

    fn manifest(self: *const SessionHost, entry: *const Entry) *const plugins.PluginManifest {
        return self.registry.find(entry.manifest_id).?;
    }
    fn factory(self: *const SessionHost, entry: *const Entry) SessionFactory {
        return self.manifest(entry).session_factory.?;
    }
};

fn hookFor(hooks: CloseHooks, step: CloseStep) ?CloseHook {
    return switch (step) {
        .pause_transfers => hooks.pause_transfers,
        .stop_ai => hooks.stop_ai,
        .release_forwards => hooks.release_forwards,
        .close_protocol => null,
        .release_content => hooks.release_content,
    };
}
fn validateEndpoint(endpoint: Endpoint) !void {
    if (endpoint.host.len == 0 or endpoint.user.len == 0 or endpoint.port == 0) return error.InvalidEndpoint;
    if (std.mem.indexOfScalar(u8, endpoint.host, 0) != null or std.mem.indexOfScalar(u8, endpoint.user, 0) != null) return error.InvalidEndpoint;
}
fn validateAuth(auth: AuthOptions) !void {
    switch (auth) {
        .private_key => |key| if (key.path.len == 0) return error.InvalidCredential,
        else => {},
    }
}
fn validateRoute(route: []const RouteHop, target_id: ?identity.ConnectionId, target: Endpoint) !void {
    if (route.len > 8) return error.TooManyHops;
    for (route, 0..) |hop, index| {
        if (hop.protocol != .ssh) return error.InvalidRouteProtocol;
        if (hop.owner) |owner| {
            if (@backingInt(owner.id) == 0 or owner.revision == 0) return error.InvalidIdentity;
            if (target_id != null and owner.id == target_id.?) return error.RouteCycle;
            for (route[0..index]) |previous| if (previous.owner) |other| {
                if (owner.id == other.id) return error.DuplicateRoute;
            };
        }
        try validateEndpoint(hop.endpoint);
        try validateAuth(hop.auth);
        if (sameEndpoint(hop.endpoint, target)) return error.RouteCycle;
        for (route[0..index]) |previous| if (sameEndpoint(hop.endpoint, previous.endpoint)) return error.RouteCycle;
    }
}

fn sameEndpoint(a: Endpoint, b: Endpoint) bool {
    return a.port == b.port and std.mem.eql(u8, a.host, b.host);
}

const ControlledAdapter = struct {
    creates: usize = 0,
    cancels: usize = 0,
    closes: usize = 0,
    stale_releases: usize = 0,
    close_result: CloseReceipt = .released,
    cancel_result: CloseReceipt = .released,
    last_request: ?CreateRequest = null,
    rebinds: usize = 0,
    rebind_failure: bool = false,
    last_rebound: ?contexts.HostContext = null,

    fn adapter(self: *ControlledAdapter) Adapter {
        return .{ .registration = .{ .plugin_id = .ssh, .workspace_kind = .terminal, .services = plugins.requiredServices(.ssh) }, .context = self, .vtable = &.{ .create = create, .cancel = cancel, .close = close, .release_stale = releaseStale } };
    }
    fn create(ctx: *anyopaque, request: CreateRequest) !void {
        const self: *ControlledAdapter = @ptrCast(@alignCast(ctx));
        self.creates += 1;
        self.last_request = request;
    }
    fn cancel(ctx: *anyopaque, _: OperationKey) CloseReceipt {
        const self: *ControlledAdapter = @ptrCast(@alignCast(ctx));
        self.cancels += 1;
        return self.cancel_result;
    }
    fn close(ctx: *anyopaque, _: SessionHandle, _: OperationKey) !CloseReceipt {
        const self: *ControlledAdapter = @ptrCast(@alignCast(ctx));
        self.closes += 1;
        return self.close_result;
    }
    fn releaseStale(ctx: *anyopaque, _: SessionHandle, _: OperationKey) void {
        const self: *ControlledAdapter = @ptrCast(@alignCast(ctx));
        self.stale_releases += 1;
    }
};

const test_target: AttachmentTarget = .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) };

test "retarget preserves owner and controller rejects stale attachments and revokes captured authority" {
    var controller: ControlledAdapter = .{};
    const Rebinding = struct {
        fn validate(_: []const u8) !void {}
        fn run(raw: *anyopaque, owner: SessionHandle, context: contexts.HostContext) !void {
            const self: *ControlledAdapter = @ptrCast(@alignCast(raw));
            if (self.rebind_failure) return error.ControlledRebindFailure;
            try context.requireOwner(owner);
            self.rebinds += 1;
            self.last_rebound = context;
        }
    };
    var callbacks = controller.adapter().vtable.*;
    callbacks.rebind_context = Rebinding.run;
    const lifecycle = typed.Definition.of(Adapter.VTable, .{ .name = "lifecycle" });
    var host = try SessionHost.initPlugins(std.testing.allocator, &.{.{
        .id = "transfer.probe",
        .display_name = "Transfer probe",
        .quick_create = .{ .validate_payload = Rebinding.validate },
        .workspace_kind = "movable",
        .content_renderer = "movable",
        .session_factory = .{ .context = &controller, .vtable = &callbacks },
        .services = &.{lifecycle},
        .required_services = &.{lifecycle},
    }}, &.{.{ .kind = "movable", .shared_renderer = true, .supports_window_transfer = true }});
    defer host.deinit();
    const accepted = try host.openQuick("transfer.probe", "opaque", .{ .request_key = 1, .target = test_target });
    const binding = typed.Binding.init(Adapter.VTable, lifecycle.key, &controller, &callbacks, accepted.handle, 1);
    _ = try host.readyPlugin(accepted.handle, accepted.operation, &.{binding});
    const original: Attachment = .{ .target = test_target, .tab_id = @fromBackingInt(1) };
    _ = try host.attached(accepted.handle, original);
    const destination: Attachment = .{ .target = .{ .window_id = @fromBackingInt(2), .workspace_id = @fromBackingInt(2) }, .tab_id = @fromBackingInt(42) };
    const context: contexts.HostContext = .{ .owner = accepted.handle, .operation = accepted.operation, .target = .{ .window_id = destination.target.window_id, .workspace_id = destination.target.workspace_id } };
    var stale = original;
    stale.tab_id = @fromBackingInt(3);
    try std.testing.expectError(error.StaleAttachment, host.retargetAttached(accepted.handle, stale, destination, context));
    controller.rebind_failure = true;
    try std.testing.expectError(error.ControlledRebindFailure, host.retargetAttached(accepted.handle, original, destination, context));
    try std.testing.expectEqual(original, host.queryState(accepted.handle).?.attachment.?);
    try std.testing.expect(host.typedBindingIsLive(binding));
    controller.rebind_failure = false;
    try host.retargetAttached(accepted.handle, original, destination, context);
    const state = host.queryState(accepted.handle).?;
    try std.testing.expectEqual(destination, state.attachment.?);
    try std.testing.expect(state.handle.eql(accepted.handle));
    try std.testing.expect(state.create_operation.eql(accepted.operation));
    try std.testing.expect(!host.typedBindingIsLive(binding));
    try std.testing.expectEqual(@as(usize, 1), controller.creates);
    try std.testing.expectEqual(@as(usize, 1), controller.rebinds);
    try std.testing.expectEqual(destination.target.window_id, controller.last_rebound.?.target.window_id);
    try std.testing.expectError(error.StaleAttachment, host.retargetAttached(accepted.handle, original, destination, context));
    _ = try host.shutdownOwner(accepted.handle);
    try std.testing.expectError(error.LifecycleDoesNotAllowTransfer, host.retargetAttached(accepted.handle, destination, original, context));
}

test "quick creation is registry controlled immutable deduplicated and never a saved connection" {
    var controller: ControlledAdapter = .{};
    const factory_value = controller.adapter();
    const Payload = struct {
        fn validate(value: []const u8) !void {
            if (value.len == 0) return error.EmptyPayload;
        }
        fn encode(allocator: std.mem.Allocator, argument: ?[]const u8) ![]u8 {
            return allocator.dupe(u8, argument orelse return error.MissingArgument);
        }
    };
    const lifecycle = typed.Definition.of(Adapter.VTable, .{ .name = "lifecycle" });
    var host = try SessionHost.initPlugins(std.testing.allocator, &.{.{
        .id = "native.probe",
        .display_name = "Native probe",
        .workspace_kind = "probe",
        .content_renderer = "probe",
        .quick_create = .{ .validate_payload = Payload.validate, .action_id = "probe.create", .encode_creation_payload = Payload.encode },
        .session_factory = .{ .context = factory_value.context, .vtable = factory_value.vtable },
        .services = &.{lifecycle},
        .required_services = &.{lifecycle},
    }}, &.{.{ .kind = "probe", .shared_renderer = true }});
    defer host.deinit();
    var payload = [_]u8{'x'};
    const first = try host.openQuick("native.probe", &payload, .{ .request_key = 1, .target = test_target });
    payload[0] = 'y';
    try std.testing.expectEqualStrings("x", controller.last_request.?.spec.plugin.payload);
    const duplicate = try host.openQuick("native.probe", "x", .{ .request_key = 1, .target = test_target });
    try std.testing.expect(first.handle.eql(duplicate.handle));
    try std.testing.expectEqual(@as(usize, 1), controller.creates);
    try std.testing.expectError(error.RequestKeyConflict, host.openQuick("native.probe", "y", .{ .request_key = 1, .target = test_target }));
    try std.testing.expectError(error.AdapterNotConnected, host.openQuick("missing", "x", .{ .request_key = 2, .target = test_target }));
    try std.testing.expectError(error.EmptyPayload, host.openQuick("native.probe", "", .{ .request_key = 2, .target = test_target }));
    try std.testing.expectError(error.MissingRequiredService, host.openQuick("native.probe", "x", .{ .request_key = 2, .target = test_target, .purpose = .socks_background }));
    try std.testing.expectError(error.ConnectionNotSupported, host.open(.{ .protocol_id = "native.probe", .name = "saved", .payload = "x" }, .{ .request_key = 2, .target = test_target }));
    const by_action = try host.openQuickAction("probe.create", "z", .{ .request_key = 3, .target = test_target });
    try std.testing.expectEqualStrings("z", host.connectionEnvelope(by_action.handle).?.payload);
    try std.testing.expectError(error.QuickCreateNotSupported, host.openQuickAction("removed.create", "z", .{ .request_key = 4, .target = test_target }));
    try std.testing.expectError(error.MissingArgument, host.openQuickAction("probe.create", null, .{ .request_key = 4, .target = test_target }));
    try std.testing.expectEqual(@as(u64, 0), @backingInt(host.connectionEnvelope(first.handle).?.id));
    try std.testing.expectEqual(CloseReceipt.released, try host.shutdownOwner(first.handle));
    try std.testing.expectEqual(@as(usize, 1), controller.cancels);
    _ = try host.shutdownOwner(by_action.handle);
}

test "open freezes background purpose and never deduplicates a different intent" {
    var controller: ControlledAdapter = .{};
    var adapter_value = controller.adapter();
    adapter_value.registration.services.bits |= backgroundServices().bits;
    var host = try SessionHost.init(std.testing.allocator, &.{adapter_value});
    defer host.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const envelope = try envelopes.fromLegacy(arena.allocator(), .{ .connection_id = @fromBackingInt(1), .name = "background", .host = "example.test", .user = "tester" });
    const first = try host.open(envelope, .{ .request_key = 5, .target = test_target, .purpose = .socks_background });
    try std.testing.expectEqual(SessionPurpose.socks_background, controller.last_request.?.purpose);
    try std.testing.expectEqual(SessionPurpose.socks_background, host.queryState(first.handle).?.purpose);
    try std.testing.expect(host.queryService(first.handle, .terminal) == .unsupported);
    try std.testing.expectError(error.RequestKeyConflict, host.open(envelope, .{ .request_key = 5, .target = test_target }));
    try std.testing.expectEqual(@as(usize, 1), controller.creates);
}

test "window shutdown revokes services and stops each controller with truthful idempotent receipts" {
    var controller: ControlledAdapter = .{};
    var host = try SessionHost.init(std.testing.allocator, &.{controller.adapter()});
    defer host.deinit();
    const pending = try host.create(testSpec(), test_target);
    try std.testing.expectEqual(CloseReceipt.released, try host.shutdownOwner(pending.handle));
    try std.testing.expectEqual(CloseReceipt.released, try host.shutdownOwner(pending.handle));
    try std.testing.expectEqual(@as(usize, 1), controller.cancels);
    try std.testing.expectError(error.SessionShuttingDown, host.retry(pending.handle));

    const live = try host.create(testSpec(), test_target);
    _ = try host.ready(live.handle, live.operation, plugins.requiredServices(.ssh));
    _ = try host.attached(live.handle, .{ .target = test_target, .tab_id = @fromBackingInt(1) });
    const binding = host.queryService(live.handle, .terminal).available;
    controller.close_result = .unknown;
    try std.testing.expectEqual(CloseReceipt.unknown, try host.shutdownOwner(live.handle));
    try std.testing.expect(!host.bindingIsLive(binding));
    try std.testing.expectEqual(Lifecycle.cleanup_unknown, host.queryState(live.handle).?.lifecycle);
    controller.close_result = .released;
    try std.testing.expectEqual(CloseReceipt.released, try host.shutdownOwner(live.handle));
    try std.testing.expectEqual(CloseReceipt.released, try host.shutdownOwner(live.handle));
    try std.testing.expectEqual(@as(usize, 2), controller.closes);
    try std.testing.expectError(error.SessionShuttingDown, host.retry(live.handle));
}
fn testSpec() SessionCreateSpec {
    return .{ .temporary_ssh = .{ .structured_endpoint = .{ .host = "test.invalid", .user = "test" } } };
}

test "host route snapshot owns each hop identity policy and auth" {
    var adapter: ControlledAdapter = .{};
    var host = try SessionHost.init(std.testing.allocator, &.{adapter.adapter()});
    defer host.deinit();
    var display_name = "bastion".*;
    var address = "bridge.test".*;
    var key_path = "/test/key".*;
    var passphrase = "secret".*;
    var route = [_]RouteHop{.{
        .owner = .{ .id = @fromBackingInt(71), .revision = 9 },
        .display_name = &display_name,
        .endpoint = .{ .host = &address, .user = "jump" },
        .auth = .{ .private_key = .{ .path = &key_path, .passphrase = &passphrase } },
        .strict_host_key_checking = true,
    }};
    _ = try host.create(.{ .saved = .{
        .connection_id = @fromBackingInt(72),
        .config_revision = 4,
        .protocol = .ssh,
        .immutable_config = .{ .endpoint = .{ .host = "target.test", .user = "test" }, .strict_host_key_checking = false },
        .route_snapshot = &route,
    } }, test_target);
    display_name[0] = 'x';
    address[0] = 'x';
    key_path[0] = 'x';
    passphrase[0] = 'x';
    route[0].owner.?.revision = 100;
    route[0].strict_host_key_checking = false;
    route[0].protocol = .sftp;
    const frozen = adapter.last_request.?.spec.saved;
    try std.testing.expectEqual(@as(u64, 4), frozen.config_revision);
    try std.testing.expect(!frozen.immutable_config.strict_host_key_checking);
    const hop = frozen.route_snapshot[0];
    try std.testing.expectEqualDeep(identity.AssetOwner{ .id = @fromBackingInt(71), .revision = 9 }, hop.owner.?);
    try std.testing.expectEqualStrings("bastion", hop.display_name);
    try std.testing.expectEqualStrings("bridge.test", hop.endpoint.host);
    try std.testing.expectEqualStrings("/test/key", hop.auth.private_key.path);
    try std.testing.expectEqualStrings("secret", hop.auth.private_key.passphrase.?);
    try std.testing.expect(hop.strict_host_key_checking);
    try std.testing.expectEqual(RemoteProtocol.ssh, hop.protocol);
}

test "host preserves an explicit password prompt without an invented empty secret" {
    var adapter: ControlledAdapter = .{};
    var host = try SessionHost.init(std.testing.allocator, &.{adapter.adapter()});
    defer host.deinit();
    var spec = testSpec();
    spec.temporary_ssh.auth_options = .password_prompt;
    _ = try host.create(spec, test_target);
    try std.testing.expect(adapter.last_request.?.spec.temporary_ssh.auth_options == .password_prompt);
}

test "host route validation rejects invalid owner and cycles before adapter IO" {
    var adapter: ControlledAdapter = .{};
    var host = try SessionHost.init(std.testing.allocator, &.{adapter.adapter()});
    defer host.deinit();
    var spec: SessionCreateSpec = .{ .saved = .{
        .connection_id = @fromBackingInt(72),
        .config_revision = 4,
        .protocol = .ssh,
        .immutable_config = .{ .endpoint = .{ .host = "target.test", .user = "test" } },
    } };
    var route = [_]RouteHop{
        .{ .owner = .{ .id = @fromBackingInt(71), .revision = 9 }, .endpoint = .{ .host = "bridge-a.test", .user = "jump" } },
        .{ .owner = .{ .id = @fromBackingInt(71), .revision = 10 }, .endpoint = .{ .host = "bridge-b.test", .user = "jump" } },
    };
    spec.saved.route_snapshot = &route;
    try std.testing.expectError(error.DuplicateRoute, host.create(spec, test_target));
    spec.saved.route_snapshot = route[0..1];
    route[0].owner.?.id = @fromBackingInt(72);
    try std.testing.expectError(error.RouteCycle, host.create(spec, test_target));
    route[0].owner.?.id = @fromBackingInt(0);
    try std.testing.expectError(error.InvalidIdentity, host.create(spec, test_target));
    route[0].owner = .{ .id = @fromBackingInt(71), .revision = 0 };
    try std.testing.expectError(error.InvalidIdentity, host.create(spec, test_target));
    route[0].owner.?.revision = 9;
    route[0].protocol = .sftp;
    try std.testing.expectError(error.InvalidRouteProtocol, host.create(spec, test_target));
    route[0].protocol = .ssh;
    route[0].endpoint.host = "target.test";
    try std.testing.expectError(error.RouteCycle, host.create(spec, test_target));
    route[0].endpoint.host = "bridge-a.test";
    route[1].owner.?.id = @fromBackingInt(73);
    route[1].endpoint.host = "bridge-a.test";
    spec.saved.route_snapshot = &route;
    try std.testing.expectError(error.RouteCycle, host.create(spec, test_target));
    const excessive: [9]RouteHop = @splat(route[0]);
    spec.saved.route_snapshot = &excessive;
    try std.testing.expectError(error.TooManyHops, host.create(spec, test_target));
    try std.testing.expectEqual(@as(usize, 0), adapter.creates);
}

test "host freezes tagged create requests and requires original attached receipt" {
    var adapter: ControlledAdapter = .{};
    var host = try SessionHost.init(std.testing.allocator, &.{adapter.adapter()});
    defer host.deinit();
    var password = [_]u8{ 's', 'e', 'c', 'r', 'e', 't' };
    var spec = testSpec();
    spec.temporary_ssh.auth_options = .{ .password = &password };
    const accepted = try host.create(spec, test_target);
    password[0] = 'X';
    try std.testing.expectEqualStrings("secret", adapter.last_request.?.spec.temporary_ssh.auth_options.password);
    try std.testing.expect(try host.ready(accepted.handle, accepted.operation, plugins.requiredServices(.ssh)));
    try std.testing.expectEqual(Lifecycle.ready, host.queryState(accepted.handle).?.lifecycle);
    var other_target = test_target;
    other_target.window_id = @fromBackingInt(2);
    try std.testing.expect(!try host.attached(accepted.handle, .{ .target = other_target, .tab_id = @fromBackingInt(1) }));
    try std.testing.expect(try host.attached(accepted.handle, .{ .target = test_target, .tab_id = @fromBackingInt(1) }));
    try std.testing.expectEqual(Lifecycle.attached, host.queryState(accepted.handle).?.lifecycle);
    try std.testing.expect(!try host.ready(accepted.handle, accepted.operation, plugins.requiredServices(.ssh)));
    try std.testing.expectEqual(@as(usize, 0), adapter.stale_releases);
    try std.testing.expect(host.queryService(accepted.handle, .terminal) == .available);
    try std.testing.expectError(error.AdapterNotConnected, host.create(.{ .local = .{} }, test_target));
}

test "cancel and retry isolate generations and clean late ready without revival" {
    var adapter: ControlledAdapter = .{};
    var host = try SessionHost.init(std.testing.allocator, &.{adapter.adapter()});
    defer host.deinit();
    const first = try host.create(testSpec(), test_target);
    var wrong_attempt = first.operation;
    wrong_attempt.attempt_id = 2;
    try std.testing.expect(!try host.cancel(wrong_attempt));
    try std.testing.expect(try host.cancel(first.operation));
    const replacement = try host.retry(first.handle);
    try std.testing.expectEqual(first.handle.session_id, replacement.handle.session_id);
    try std.testing.expect(!first.handle.eql(replacement.handle));
    try std.testing.expect(!try host.ready(first.handle, first.operation, plugins.requiredServices(.ssh)));
    try std.testing.expectEqual(@as(usize, 1), adapter.stale_releases);
    try std.testing.expectEqual(Lifecycle.creating, host.queryState(replacement.handle).?.lifecycle);
    try std.testing.expect(try host.ready(replacement.handle, replacement.operation, plugins.requiredServices(.ssh)));
}

test "close unknown gates bindings and converges on the same request" {
    var adapter: ControlledAdapter = .{ .close_result = .unknown };
    var host = try SessionHost.init(std.testing.allocator, &.{adapter.adapter()});
    defer host.deinit();
    const accepted = try host.create(testSpec(), test_target);
    _ = try host.ready(accepted.handle, accepted.operation, plugins.requiredServices(.ssh));
    _ = try host.attached(accepted.handle, .{ .target = test_target, .tab_id = @fromBackingInt(1) });
    const binding = host.queryService(accepted.handle, .terminal).available;
    try std.testing.expect(host.bindingIsLive(binding));
    const close_key = try host.requestClose(accepted.handle, .{});
    try std.testing.expect(!host.bindingIsLive(binding));
    try std.testing.expectEqual(Lifecycle.cleanup_unknown, host.queryState(accepted.handle).?.lifecycle);
    try std.testing.expect(close_key.eql(try host.requestClose(accepted.handle, .{})));
    try std.testing.expectEqual(@as(usize, 1), adapter.closes);
    try std.testing.expect(!try host.closeReceipt(accepted.handle, accepted.operation, .close_protocol, .released));
    try std.testing.expect(try host.closeReceipt(accepted.handle, close_key, .close_protocol, .released));
    try std.testing.expectEqual(Lifecycle.closed, host.queryState(accepted.handle).?.lifecycle);
    try std.testing.expect(!try host.ready(accepted.handle, accepted.operation, plugins.requiredServices(.ssh)));
}

test "close awaits the original hook before protocol release and ignores ready replays" {
    const Barrier = struct {
        calls: usize = 0,
        fn run(context: *anyopaque, _: SessionHandle, _: OperationKey) !CloseReceipt {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            return .awaiting;
        }
    };
    var barrier: Barrier = .{};
    var adapter: ControlledAdapter = .{};
    var host = try SessionHost.init(std.testing.allocator, &.{adapter.adapter()});
    defer host.deinit();
    const accepted = try host.create(testSpec(), test_target);
    _ = try host.ready(accepted.handle, accepted.operation, plugins.requiredServices(.ssh));
    _ = try host.attached(accepted.handle, .{ .target = test_target, .tab_id = @fromBackingInt(1) });
    const key = try host.requestClose(accepted.handle, .{ .pause_transfers = .{ .context = &barrier, .run = Barrier.run } });
    try std.testing.expectEqual(@as(usize, 0), adapter.closes);
    try std.testing.expect(!try host.ready(accepted.handle, accepted.operation, plugins.requiredServices(.ssh)));
    try std.testing.expectEqual(@as(usize, 0), adapter.stale_releases);
    _ = try host.requestClose(accepted.handle, .{});
    try std.testing.expectEqual(@as(usize, 1), barrier.calls);
    try std.testing.expect(!try host.closeReceipt(accepted.handle, key, .stop_ai, .released));
    try std.testing.expect(try host.closeReceipt(accepted.handle, key, .pause_transfers, .released));
    try std.testing.expectEqual(@as(usize, 1), adapter.closes);
    try std.testing.expectEqual(Lifecycle.closed, host.queryState(accepted.handle).?.lifecycle);
}

test "cancel unknown blocks retry until the exact creation cleanup receipt" {
    var adapter: ControlledAdapter = .{ .cancel_result = .unknown };
    var host = try SessionHost.init(std.testing.allocator, &.{adapter.adapter()});
    defer host.deinit();
    const first = try host.create(testSpec(), test_target);
    _ = try host.cancel(first.operation);
    try std.testing.expectError(error.CleanupNotReleased, host.retry(first.handle));
    var wrong = first.operation;
    wrong.attempt_id = 2;
    try std.testing.expect(!try host.createCleanupReceipt(first.handle, wrong, .released));
    try std.testing.expect(try host.createCleanupReceipt(first.handle, first.operation, .released));
    const next = try host.retry(first.handle);
    try std.testing.expectEqual(@as(u64, 2), next.handle.generation);
    try std.testing.expect(!try host.createCleanupReceipt(first.handle, first.operation, .released));
}

test "failed factory retains cleanup ownership and close does not release it in parallel" {
    var adapter: ControlledAdapter = .{};
    var host = try SessionHost.init(std.testing.allocator, &.{adapter.adapter()});
    defer host.deinit();
    const accepted = try host.create(testSpec(), test_target);
    _ = try host.failed(accepted.handle, accepted.operation, .{ .domain = .transport, .code = "timeout", .effect = .none, .cleanup = .unknown, .safe_message = "连接超时" });
    try std.testing.expectError(error.CleanupNotReleased, host.retry(accepted.handle));
    const close_key = try host.requestClose(accepted.handle, .{});
    try std.testing.expectEqual(Lifecycle.cleanup_unknown, host.queryState(accepted.handle).?.lifecycle);
    try std.testing.expectEqual(@as(usize, 0), adapter.closes);
    _ = try host.createCleanupReceipt(accepted.handle, accepted.operation, .released);
    try std.testing.expectEqual(Lifecycle.closed, host.queryState(accepted.handle).?.lifecycle);
    try std.testing.expectEqual(@as(usize, 0), adapter.closes);
    try std.testing.expect(close_key.eql(try host.requestClose(accepted.handle, .{})));
}

test "invalid ready services fail and release through the same adapter cleanup gate" {
    var adapter: ControlledAdapter = .{ .cancel_result = .awaiting };
    var host = try SessionHost.init(std.testing.allocator, &.{adapter.adapter()});
    defer host.deinit();
    const accepted = try host.create(testSpec(), test_target);
    try std.testing.expectError(error.InvalidReadyServices, host.ready(accepted.handle, accepted.operation, .{}));
    try std.testing.expectEqual(Lifecycle.failed, host.queryState(accepted.handle).?.lifecycle);
    try std.testing.expectEqual(@as(usize, 1), adapter.cancels);
    try std.testing.expectError(error.CleanupNotReleased, host.retry(accepted.handle));
    _ = try host.createCleanupReceipt(accepted.handle, accepted.operation, .released);
    _ = try host.retry(accepted.handle);
}

test "cleanup publication OOM keeps the original receipt retryable and resumes close" {
    const allocator = std.testing.allocator;
    var adapter: ControlledAdapter = .{};
    var host = try SessionHost.init(allocator, &.{adapter.adapter()});
    defer host.deinit();
    const accepted = try host.create(testSpec(), test_target);
    _ = try host.failed(accepted.handle, accepted.operation, .{ .domain = .transport, .code = "timeout", .cleanup = .unknown, .safe_message = "连接超时" });
    _ = try host.requestClose(accepted.handle, .{});
    while (host.journal.take()) |received| {
        var event = received;
        event.deinit();
    }
    host.journal.events.deinit(allocator);
    host.journal.events = .empty;
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    host.journal.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, host.createCleanupReceipt(accepted.handle, accepted.operation, .released));
    try std.testing.expectEqual(operations.Cleanup.unknown, host.queryState(accepted.handle).?.create_cleanup);
    try std.testing.expectEqual(Lifecycle.cleanup_unknown, host.queryState(accepted.handle).?.lifecycle);
    host.journal.allocator = allocator;
    try std.testing.expect(try host.createCleanupReceipt(accepted.handle, accepted.operation, .released));
    try std.testing.expectEqual(Lifecycle.closed, host.queryState(accepted.handle).?.lifecycle);
    try std.testing.expectEqual(@as(usize, 0), adapter.closes);
}

test "Local startup retry requires released cleanup and keeps late receipts on the old generation" {
    var controlled: ControlledAdapter = .{};
    var adapter = controlled.adapter();
    adapter.registration = .{ .plugin_id = .local, .workspace_kind = .terminal, .services = plugins.requiredServices(.local) };
    var host = try SessionHost.init(std.testing.allocator, &.{adapter});
    defer host.deinit();
    const first = try host.create(.{ .local = .{ .initial_cwd = "/tmp" } }, test_target);
    _ = try host.failed(first.handle, first.operation, .{ .domain = .transport, .code = "LocalStartFailed", .cleanup = .unknown, .safe_message = "process ownership unknown" });
    try std.testing.expectError(error.CleanupNotReleased, host.retry(first.handle));
    _ = try host.createCleanupReceipt(first.handle, first.operation, .released);
    const retry = try host.retry(first.handle);
    try std.testing.expectEqual(first.handle.session_id, retry.handle.session_id);
    try std.testing.expectEqual(first.handle.generation + 1, retry.handle.generation);
    try std.testing.expectEqual(@as(usize, 2), controlled.creates);
    try std.testing.expect(!try host.ready(first.handle, first.operation, plugins.requiredServices(.local)));
    try std.testing.expect(!try host.createCleanupReceipt(first.handle, first.operation, .unknown));
    try std.testing.expectEqual(@as(usize, 1), controlled.stale_releases);
    try std.testing.expect(try host.ready(retry.handle, retry.operation, plugins.requiredServices(.local)));
    try std.testing.expectError(error.LifecycleDoesNotAllowRetry, host.retry(retry.handle));
}

test "ended SSH revokes services and only explicit retry advances after real cleanup" {
    var adapter: ControlledAdapter = .{};
    var host = try SessionHost.init(std.testing.allocator, &.{adapter.adapter()});
    defer host.deinit();
    const first = try host.create(testSpec(), test_target);
    try std.testing.expect(try host.ready(first.handle, first.operation, plugins.requiredServices(.ssh)));
    try std.testing.expect(try host.attached(first.handle, .{ .target = test_target, .tab_id = @fromBackingInt(9) }));
    const binding = host.queryService(first.handle, .terminal).available;
    try std.testing.expect(try host.shellEnded(first.handle, first.operation, .releasing));
    try std.testing.expectEqual(Lifecycle.ended, host.queryState(first.handle).?.lifecycle);
    try std.testing.expect(!host.bindingIsLive(binding));
    try std.testing.expect(host.journal.isTerminal(first.operation));
    try std.testing.expectError(error.CleanupNotReleased, host.retry(first.handle));
    try std.testing.expect(try host.createCleanupReceipt(first.handle, first.operation, .released));
    const next = try host.retry(first.handle);
    try std.testing.expectEqual(first.handle.session_id, next.handle.session_id);
    try std.testing.expectEqual(first.handle.generation + 1, next.handle.generation);
    try std.testing.expect(!try host.shellEnded(first.handle, first.operation, .released));
}

test "attached SSH loss keeps terminal operation and retries original session after real cleanup" {
    var adapter: ControlledAdapter = .{};
    var host = try SessionHost.init(std.testing.allocator, &.{adapter.adapter()});
    defer host.deinit();
    const first = try host.create(testSpec(), test_target);
    try std.testing.expect(try host.ready(first.handle, first.operation, plugins.requiredServices(.ssh)));
    const attachment: Attachment = .{ .target = test_target, .tab_id = @fromBackingInt(9) };
    try std.testing.expect(try host.attached(first.handle, attachment));
    const binding = host.queryService(first.handle, .terminal).available;
    try std.testing.expect(try host.transportLost(first.handle, first.operation, .{ .domain = .transport, .code = "disconnect", .cleanup = .releasing, .safe_message = "connection lost" }));
    try std.testing.expect(host.journal.isTerminal(first.operation));
    try std.testing.expect(!host.bindingIsLive(binding));
    try std.testing.expectEqualDeep(attachment, host.queryState(first.handle).?.attachment.?);
    try std.testing.expectError(error.CleanupNotReleased, host.retry(first.handle));
    try std.testing.expect(try host.createCleanupReceipt(first.handle, first.operation, .unknown));
    try std.testing.expectError(error.CleanupNotReleased, host.retry(first.handle));
    try std.testing.expect(try host.createCleanupReceipt(first.handle, first.operation, .released));
    const next = try host.retry(first.handle);
    try std.testing.expectEqual(first.handle.session_id, next.handle.session_id);
    try std.testing.expectEqual(first.handle.generation + 1, next.handle.generation);
    try std.testing.expectEqual(first.operation.attempt_id.? + 1, next.operation.attempt_id.?);
    try std.testing.expect(next.operation.operation_id != first.operation.operation_id);
    try std.testing.expect(!try host.createCleanupReceipt(first.handle, first.operation, .released));
    try std.testing.expect(!try host.transportLost(first.handle, first.operation, .{ .domain = .transport, .code = "late", .cleanup = .released, .safe_message = "late" }));
    try std.testing.expect(try host.ready(next.handle, next.operation, plugins.requiredServices(.ssh)));
    try std.testing.expect(try host.attached(next.handle, attachment));
    try std.testing.expectEqual(@as(usize, 2), adapter.creates);
}

test "retained transfer freezes source and publishes only a separate transfer binding" {
    var adapter: ControlledAdapter = .{};
    var host = try SessionHost.init(std.testing.allocator, &.{adapter.adapter()});
    defer host.deinit();
    const original = try host.create(testSpec(), test_target);
    try std.testing.expect(try host.ready(original.handle, original.operation, plugins.requiredServices(.ssh)));
    try std.testing.expect(try host.attached(original.handle, .{ .target = test_target, .tab_id = @fromBackingInt(1) }));
    const id = try host.retainTransferSource(original.handle);
    try std.testing.expectEqual(id, try host.retainTransferSource(original.handle));
    try std.testing.expectError(error.OriginalSessionNotClosed, host.beginRetainedTransfer(id, original.handle));
    _ = try host.requestClose(original.handle, .{});
    const start = try host.beginRetainedTransfer(id, original.handle);
    try std.testing.expectEqual(identity.CommandOwner{ .transfer_owner = .{ .id = id, .original_handle = original.handle } }, start.key.owner);
    try std.testing.expectEqual(ServiceKind.transfer, start.binding.kind);
    try std.testing.expectEqual(original.handle, start.binding.origin_session.?);
    try std.testing.expect(!host.bindingIsLive(start.binding));
    try std.testing.expect(host.bindingIsPreparing(start.binding, start.key));
    try std.testing.expect(try host.retainedTransferReady(start.binding, start.key));
    try std.testing.expect(host.bindingIsLive(start.binding));
    try std.testing.expect(!host.bindingIsPreparing(start.binding, start.key));
    try std.testing.expect(!try host.retainedTransferReady(start.binding, start.key));
    try std.testing.expect(host.queryService(original.handle, .terminal) == .temporarily_unavailable);
    try std.testing.expectEqual(@as(usize, 1), adapter.creates);
    try std.testing.expectEqual(@as(usize, 1), adapter.closes);
    try std.testing.expectEqualStrings("test.invalid", host.retainedTransferSource(id, original.handle).?.temporary_ssh.structured_endpoint.host);
}

test "retained transfer unknown cleanup blocks generations and late receipts cannot revive a binding" {
    var adapter: ControlledAdapter = .{};
    var host = try SessionHost.init(std.testing.allocator, &.{adapter.adapter()});
    defer host.deinit();
    const original = try host.create(testSpec(), test_target);
    try std.testing.expect(try host.ready(original.handle, original.operation, plugins.requiredServices(.ssh)));
    const id = try host.retainTransferSource(original.handle);
    _ = try host.requestClose(original.handle, .{});
    const first = try host.beginRetainedTransfer(id, original.handle);
    try std.testing.expect(try host.retainedTransferReady(first.binding, first.key));
    try std.testing.expect(try host.retainedTransferReleased(first.binding, first.key, .unknown));
    try std.testing.expect(!host.bindingIsLive(first.binding));
    try std.testing.expect(!host.retainedTransferOperationIsCurrent(id, original.handle, first.key));
    try std.testing.expect(try host.retainedTransferReleased(first.binding, first.key, .awaiting));
    try std.testing.expect(!host.bindingIsPreparing(first.binding, first.key));
    try std.testing.expect(!host.retainedTransferOperationIsCurrent(id, original.handle, first.key));
    try std.testing.expectError(error.CleanupNotReleased, host.beginRetainedTransfer(id, original.handle));
    try std.testing.expectError(error.CleanupNotReleased, host.releaseRetainedTransfer(id, original.handle));
    try std.testing.expect(try host.retainedTransferReleased(first.binding, first.key, .released));
    const second = try host.beginRetainedTransfer(id, original.handle);
    try std.testing.expectEqual(first.binding.binding_generation + 1, second.binding.binding_generation);
    try std.testing.expect(first.binding.binding_id != second.binding.binding_id);
    try std.testing.expect(!try host.retainedTransferReady(first.binding, first.key));
    try std.testing.expect(!try host.retainedTransferReleased(first.binding, first.key, .released));
    try std.testing.expect(!host.bindingIsLive(first.binding));
    try std.testing.expect(try host.retainedTransferReady(second.binding, second.key));
    try std.testing.expect(try host.retainedTransferReleased(second.binding, second.key, .released));
    try host.releaseRetainedTransfer(id, original.handle);
    try std.testing.expect(host.retainedTransferSource(id, original.handle) == null);
    try std.testing.expect(!host.bindingIsLive(second.binding));
}

test "shared transfer binds the original SSH operation and coexists with independent transfer authority" {
    var adapter: ControlledAdapter = .{};
    var host = try SessionHost.init(std.testing.allocator, &.{adapter.adapter()});
    defer host.deinit();
    const original = try host.create(testSpec(), test_target);
    try std.testing.expectError(error.LifecycleDoesNotAllowTransfer, host.beginSharedTransfer(original.handle));
    _ = try host.ready(original.handle, original.operation, plugins.requiredServices(.ssh));
    _ = try host.attached(original.handle, .{ .target = test_target, .tab_id = @fromBackingInt(1) });
    const shared = try host.beginSharedTransfer(original.handle);
    try std.testing.expect(shared.key.eql(original.operation));
    try std.testing.expect(!host.bindingIsLive(shared.binding));
    try std.testing.expect(host.sharedTransferReady(shared.binding, shared.key));
    const auxiliary = try host.beginAuxiliaryTransfer(original.handle);
    try std.testing.expect(!auxiliary.binding.eql(shared.binding));
    try std.testing.expect(!auxiliary.key.eql(shared.key));
    try std.testing.expect(try host.auxiliaryTransferReady(auxiliary.binding, auxiliary.key));
    try std.testing.expect(host.bindingIsLive(shared.binding));
    try std.testing.expect(host.bindingIsLive(auxiliary.binding));
    try std.testing.expectEqual(@as(usize, 1), adapter.creates);
    var stale = shared.key;
    stale.attempt_id = (stale.attempt_id orelse 0) + 1;
    try std.testing.expect(!host.sharedTransferReleased(shared.binding, stale, .released));
    try std.testing.expect(host.sharedTransferReleased(shared.binding, shared.key, .unknown));
    try std.testing.expect(!host.bindingIsLive(shared.binding));
    try std.testing.expect(host.bindingIsLive(auxiliary.binding));
    try std.testing.expectError(error.CleanupNotReleased, host.beginSharedTransfer(original.handle));
    try std.testing.expect(host.sharedTransferReleased(shared.binding, shared.key, .awaiting));
    try std.testing.expectEqual(CloseReceipt.unknown, host.findShared(original.handle).?.cleanup);
    try std.testing.expect(host.sharedTransferReleased(shared.binding, shared.key, .released));
}

test "shared transfer fault retains only the exact revoked original source across failed SSH lifecycle" {
    var adapter: ControlledAdapter = .{};
    var host = try SessionHost.init(std.testing.allocator, &.{adapter.adapter()});
    defer host.deinit();
    const original = try host.create(testSpec(), test_target);
    _ = try host.ready(original.handle, original.operation, plugins.requiredServices(.ssh));
    _ = try host.attached(original.handle, .{ .target = test_target, .tab_id = @fromBackingInt(1) });
    const shared = try host.beginSharedTransfer(original.handle);
    try std.testing.expect(host.sharedTransferReady(shared.binding, shared.key));
    _ = try host.transportLost(original.handle, original.operation, .{ .domain = .transport, .code = "loopback FIN", .cleanup = .releasing, .safe_message = "closed" });
    try std.testing.expect(!host.bindingIsLive(shared.binding));
    try std.testing.expectError(error.StaleBinding, host.retainFaultTransferSource(shared.binding, shared.key));
    try std.testing.expect(host.sharedTransferReleased(shared.binding, shared.key, .awaiting));
    var stale = shared.key;
    stale.operation_id += 1;
    try std.testing.expectError(error.StaleBinding, host.retainFaultTransferSource(shared.binding, stale));
    const retained = try host.retainFaultTransferSource(shared.binding, shared.key);
    try std.testing.expect(host.faultTransferSourceIsCurrent(retained, original.handle, shared.binding, shared.key));
    try std.testing.expectEqualStrings("test.invalid", host.retainedTransferSource(retained, original.handle).?.temporary_ssh.structured_endpoint.host);
    try std.testing.expect(host.sharedTransferReleased(shared.binding, shared.key, .released));
    _ = try host.createCleanupReceipt(original.handle, original.operation, .released);
    const next = try host.retry(original.handle);
    _ = try host.ready(next.handle, next.operation, plugins.requiredServices(.ssh));
    _ = try host.attached(next.handle, .{ .target = test_target, .tab_id = @fromBackingInt(2) });
    const successor = try host.beginSharedTransfer(next.handle);
    try std.testing.expect(!successor.binding.eql(shared.binding));
    try std.testing.expect(!host.sharedTransferReady(shared.binding, shared.key));
    try std.testing.expect(host.sharedTransferReady(successor.binding, successor.key));
}

test "auxiliary readonly readiness and unknown cleanup gate the exact source generation" {
    var adapter: ControlledAdapter = .{};
    var host = try SessionHost.init(std.testing.allocator, &.{adapter.adapter()});
    defer host.deinit();
    const original = try host.create(testSpec(), test_target);
    try std.testing.expect(try host.ready(original.handle, original.operation, plugins.requiredServices(.ssh)));
    try std.testing.expect(try host.attached(original.handle, .{ .target = test_target, .tab_id = @fromBackingInt(1) }));
    const start = try host.beginAuxiliaryReadonly(original.handle);
    try std.testing.expect(!host.bindingIsLive(start.bindings.directory));
    try std.testing.expect(!host.bindingIsLive(start.bindings.file_read));
    try std.testing.expect(host.queryService(original.handle, .directory) == .temporarily_unavailable);
    try std.testing.expect(host.auxiliaryReadonlyOwns(original.handle, try host.beginAuxiliaryReadonly(original.handle)));
    var wrong = start;
    wrong.bindings.file_read.binding_generation += 1;
    try std.testing.expect(!try host.auxiliaryReadonlyReady(original.handle, wrong));
    try std.testing.expect(try host.auxiliaryReadonlyReady(original.handle, start));
    try std.testing.expect(host.bindingIsLive(start.bindings.directory));
    try std.testing.expect(host.bindingIsLive(start.bindings.file_read));
    try std.testing.expect(try host.auxiliaryReadonlyReleased(original.handle, start, .unknown));
    try std.testing.expect(!host.bindingIsLive(start.bindings.file_read));
    try std.testing.expectError(error.CleanupNotReleased, host.beginAuxiliaryReadonly(original.handle));
    try std.testing.expect(try host.auxiliaryReadonlyReleased(original.handle, start, .released));
    const replacement = try host.beginAuxiliaryReadonly(original.handle);
    try std.testing.expect(replacement.bindings.directory.binding_generation > start.bindings.directory.binding_generation);
    try std.testing.expect(!try host.auxiliaryReadonlyReady(original.handle, start));
    try std.testing.expect(!try host.auxiliaryReadonlyReleased(original.handle, start, .released));
    try std.testing.expect(!host.bindingIsLive(replacement.bindings.directory));
    try std.testing.expect(try host.auxiliaryReadonlyReleased(original.handle, replacement, .released));
}

test "open deduplicates arbitrary plugin payload and shares lifecycle owner and typed authority" {
    var adapter: ControlledAdapter = .{};
    const factory_value = adapter.adapter();
    const TestPayload = struct {
        fn validate(payload: []const u8) !void {
            if (payload.len == 0) return error.EmptyPayload;
        }
        fn codec(allocator: std.mem.Allocator, envelope: envelopes.Envelope) !envelopes.Envelope {
            try validate(envelope.payload);
            return envelope.clone(allocator);
        }
        fn migrate(allocator: std.mem.Allocator, envelope: envelopes.Envelope, version: u32) !envelopes.Envelope {
            if (version != 1) return error.UnsupportedPayloadVersion;
            return codec(allocator, envelope);
        }
    };
    const lifecycle = typed.Definition.of(Adapter.VTable, .{ .name = "lifecycle" });
    var host = try SessionHost.initPlugins(std.testing.allocator, &.{.{
        .id = "custom.probe",
        .display_name = "Probe",
        .workspace_kind = "probe",
        .content_renderer = "probe",
        .connection = .{ .create_kind = .saved_or_temporary, .editor_factory = .{ .shared_editor = "test" }, .validate_payload = TestPayload.validate, .encode = TestPayload.codec, .decode = TestPayload.codec, .migrate = TestPayload.migrate },
        .session_factory = .{ .context = factory_value.context, .vtable = factory_value.vtable },
        .services = &.{lifecycle},
        .required_services = &.{lifecycle},
    }}, &.{.{ .kind = "probe", .shared_renderer = true }});
    defer host.deinit();
    const envelope: envelopes.Envelope = .{ .protocol_id = "custom.probe", .name = "Probe", .payload = "{\"unfamiliar\":true}" };
    const first = try host.open(envelope, .{ .request_key = 17, .target = test_target });
    const duplicate = try host.open(envelope, .{ .request_key = 17, .target = test_target });
    try std.testing.expectEqual(first.handle, duplicate.handle);
    try std.testing.expectEqual(@as(usize, 1), adapter.creates);
    var changed = envelope;
    changed.payload = "{}";
    try std.testing.expectError(error.RequestKeyConflict, host.open(changed, .{ .request_key = 17, .target = test_target }));
    changed.name = "Prob";
    changed.payload = "e{\"unfamiliar\":true}";
    // These unseparated strings have the same hash input as the original.
    try std.testing.expectError(error.RequestKeyConflict, host.open(changed, .{ .request_key = 17, .target = test_target }));
    const binding = typed.Binding.init(Adapter.VTable, lifecycle.key, factory_value.context, factory_value.vtable, first.handle, 1);
    try std.testing.expect(try host.readyPlugin(first.handle, first.operation, &.{binding}));
    try std.testing.expectEqualStrings("custom.probe", host.protocolId(first.handle).?);
    try std.testing.expect(host.queryService(first.handle, .terminal) == .unsupported);
    try std.testing.expect(host.queryTypedService(first.handle, Adapter.VTable, lifecycle.key) == .available);
    try std.testing.expect(host.typedBindingIsLive(binding));
    try host.authorizeService(first.handle, lifecycle.key, false);
    try std.testing.expect(!host.typedBindingIsLive(binding));
    try std.testing.expect(host.queryTypedService(first.handle, Adapter.VTable, lifecycle.key) == .denied);
    try host.authorizeService(first.handle, lifecycle.key, true);
    try std.testing.expect(!host.typedBindingIsLive(binding));
    const current = host.queryTypedService(first.handle, Adapter.VTable, lifecycle.key).available.binding;
    try std.testing.expect(host.typedBindingIsLive(current));
    try std.testing.expect(try host.revokeTypedService(first.handle, first.operation, lifecycle.key));
    try std.testing.expect(!try host.revokeTypedService(first.handle, first.operation, lifecycle.key));
    try std.testing.expect(host.queryTypedService(first.handle, Adapter.VTable, lifecycle.key) == .temporarily_unavailable);
    const replacement = try host.bindTypedService(first.handle, first.operation, binding);
    try std.testing.expect(!host.typedBindingIsLive(current));
    try std.testing.expect(host.typedBindingIsLive(replacement));
    try std.testing.expect(try host.attached(first.handle, .{ .target = test_target, .tab_id = @fromBackingInt(45) }));
    const close_key = try host.requestClose(first.handle, .{});
    try std.testing.expect(close_key.eql(try host.requestClose(first.handle, .{})));
    try std.testing.expect(!host.typedBindingIsLive(current));
    try std.testing.expectEqual(@as(usize, 1), adapter.closes);
    const invalid = try host.open(envelope, .{ .request_key = 18, .target = test_target });
    try std.testing.expectError(error.StaleBinding, host.readyPlugin(invalid.handle, invalid.operation, &.{binding}));
    try std.testing.expectEqual(Lifecycle.failed, host.queryState(invalid.handle).?.lifecycle);
    try std.testing.expectEqual(operations.Cleanup.released, host.queryState(invalid.handle).?.create_cleanup);
    try std.testing.expectEqual(@as(usize, 1), adapter.cancels);
}

test "legacy engine query and typed service resolve share revocation and stale revision gate" {
    var adapter: ControlledAdapter = .{};
    var host = try SessionHost.init(std.testing.allocator, &.{adapter.adapter()});
    defer host.deinit();
    const accepted = try host.create(testSpec(), test_target);
    _ = try host.ready(accepted.handle, accepted.operation, plugins.requiredServices(.ssh));
    const old = host.queryTypedService(accepted.handle, LegacyService(.terminal), .{ .name = "terminal" }).available;
    const engine = try old.vtable.resolve(old.context, old.binding);
    try std.testing.expectEqualDeep(engine, host.queryService(accepted.handle, .terminal).available);
    try host.authorizeService(accepted.handle, .{ .name = "terminal" }, false);
    try std.testing.expect(!host.bindingIsLive(engine));
    try std.testing.expect(host.queryService(accepted.handle, .terminal) == .temporarily_unavailable);
    try std.testing.expectError(error.StaleBinding, old.vtable.resolve(old.context, old.binding));
    try host.authorizeService(accepted.handle, .{ .name = "terminal" }, true);
    try std.testing.expectError(error.StaleBinding, old.vtable.resolve(old.context, old.binding));
    const current = host.queryTypedService(accepted.handle, LegacyService(.terminal), .{ .name = "terminal" }).available;
    _ = try current.vtable.resolve(current.context, current.binding);
    const available = host.typedBindingsFor(accepted.handle).?;
    for (available) |binding| try std.testing.expect(!std.mem.eql(u8, binding.definition.key.name, "directory"));
    _ = try host.requestClose(accepted.handle, .{});
    try std.testing.expectError(error.StaleBinding, current.vtable.resolve(current.context, current.binding));
}
