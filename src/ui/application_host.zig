//! Main-thread bridge from the application controllers to SSH and Local
//! runtimes. Workers keep their own snapshots; they never retain this host.
const std = @import("std");
const workspace_mod = @import("workspace.zig");
const hosts = @import("../config/hosts.zig");
const config = @import("../config/config.zig");
const identity = @import("../host/identity.zig");
const session = @import("../host/session_host.zig");
const windows = @import("../host/window_host.zig");
const plugins = @import("../host/plugin_registry.zig");
const commands = @import("../host/command.zig");
const overlay_model = @import("overlay_model.zig");
const local_mod = @import("../host/process_service.zig");
const terminal = @import("../host/terminal_service.zig");
const ui = @import("ui");
const background = @import("../host/socks_background_runtime.zig");
const group_close = @import("group_close_controller.zig");
const connection_envelope = @import("../config/connection_envelope.zig");

pub const CloseStep = session.CloseStep;
pub const CloseReceipt = session.CloseReceipt;
pub const OperationKey = session.OperationKey;
pub const LegacySessionId = workspace_mod.SessionId;

/// Called on the main thread. Returning awaiting requests another safeTick;
/// unknown requires an explicit closeReceipt instead of blindly retrying work.
/// Hooks must be idempotent and must not reenter SessionHost.
pub const CloseExtension = struct {
    context: *anyopaque,
    run: *const fn (*anyopaque, LegacySessionId, CloseStep) CloseReceipt,
};

const remote_source = @import("../plugins/ssh/connection_source.zig");
const SourceSnapshot = remote_source.SourceSnapshot;
pub const FileSource = remote_source.Source;
pub const WindowConnection = struct {
    envelope: @import("session_lifecycle.zig").Snapshot(connection_envelope.Envelope),
    remote: ?SourceSnapshot = null,
    pub fn init(allocator: std.mem.Allocator, host: hosts.HostConfig, global_config: config.Config, registry_values: []const hosts.HostConfig, host_id: workspace_mod.HostId, source_index: usize) !WindowConnection {
        var remote = try remote_source.freezeWindowSource(allocator, host, global_config, registry_values, host_id, source_index);
        errdefer if (remote) |*source| source.deinit();
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const envelope = try connection_envelope.fromLegacy(arena.allocator(), host);
        try envelope.validate();
        return .{ .envelope = try @import("session_lifecycle.zig").Snapshot(connection_envelope.Envelope).init(allocator, envelope), .remote = remote };
    }
    pub fn deinit(self: *WindowConnection) void {
        self.envelope.deinit();
        if (self.remote) |*source| source.deinit();
    }
};
const freezeSource = remote_source.freezeSource;
const sourceSpec = remote_source.sourceSpec;
const auth = remote_source.auth;
pub fn localHomeDirectory(allocator: std.mem.Allocator) ![]u8 {
    return @import("../platform/account.zig").home(allocator);
}
/// Installed only with a real file lifecycle adapter and its resource owner.
pub const FilePlugin = struct {
    adapter: session.Adapter,
    context: *anyopaque,
    tick: *const fn (*anyopaque, *session.SessionHost) anyerror!bool,
    shutdown: *const fn (*anyopaque) CloseReceipt,
};
const FileCreateSource = struct { handle: identity.SessionHandle, key: OperationKey, source: SourceSnapshot, failure_reported: bool = false };
const CloseTarget = @import("workspace_model.zig").CloseTarget;
const WindowClose = struct {
    ticket: windows.Close,
    key: OperationKey,
    /// Borrowed from Workspace's one frozen close queue until this request ends.
    targets: []const CloseTarget,
    state: enum { draining, ready, cancelled, closed } = .draining,
    cancel_requested: bool = false,
};
const Waiting = struct { key: OperationKey, step: CloseStep, unknown: bool = false };
const HistoryClose = struct {
    tab_id: identity.TabId,
    owner: identity.HistoryId,
    key: OperationKey,
    state: enum { pending, closed, unknown } = .pending,
};
const ReconnectPolicy = struct { automatic: bool, max: u8, backoff: [5]u8 };
const Mapping = struct {
    process: ?*local_mod.Service = null,
    handle: identity.SessionHandle,
    create_operation: OperationKey,
    legacy_id: LegacySessionId,
    legacy_generation: u64,
    tab_id: identity.TabId,
    owner: identity.ContentOwner,
    source: ?SourceSnapshot,
    connected_received: bool = false,
    ready_published: bool = false,
    attached_published: bool = false,
    failed_received: bool = false,
    failed_published: bool = false,
    cleanup_received: bool = false,
    cleanup_unknown_received: bool = false,
    failure: [384]u8 = undefined,
    failure_len: usize = 0,
    waiting: ?Waiting = null,
    acknowledged_step: ?CloseStep = null,
    content_pending: bool = false,
    local_retired: bool = false,
    local_started: bool = false,
    reconnect_policy: ?ReconnectPolicy = null,
    reconnect_ticket: ?@import("../vt/reconnect.zig").Ticket = null,
    reconnect_count: u8 = 0,
    runtime_loss_received: bool = false,

    pub fn recordFailure(self: *Mapping, text: []const u8) void {
        var len = @min(text.len, self.failure.len);
        while (len > 0 and !std.unicode.utf8ValidateSlice(text[0..len])) len -= 1;
        @memcpy(self.failure[0..len], text[0..len]);
        self.failure_len = len;
        self.failed_received = true;
    }
};

/// Process-owned services. A window host is only an attachment to this domain;
/// native close releases its workspace while sibling session identities remain
/// registered in this one registry. Adapter callbacks retain this stable owner.
pub const Domain = struct {
    allocator: std.mem.Allocator,
    windows: windows.Host,
    sessions: session.SessionHost,
    local_adapter: *local_mod.Service,
    dispatcher: commands.Dispatcher,
    operation_history: @import("../host/operation_store.zig").Store,
    attachments: std.ArrayList(*ApplicationHost) = .empty,
    has_file_plugin: bool,
    backgrounds: ?*background.Host = null,
    tasks: ?*@import("../host/application_task_domain.zig").Domain = null,

    pub fn init(allocator: std.mem.Allocator, has_file_plugin: bool) !*Domain {
        return initWithContributions(allocator, has_file_plugin, &.{}, &.{});
    }
    pub fn initWithContributions(allocator: std.mem.Allocator, has_file_plugin: bool, manifests: []const plugins.PluginManifest, renderers: []const plugins.RendererDefinition) !*Domain {
        const self = try allocator.create(Domain);
        errdefer allocator.destroy(self);
        const local = try @import("../plugins/linked_plugins.zig").createProcess(allocator);
        errdefer local.deinit() catch {};
        const adapters = @import("../plugins/linked_plugins.zig").applicationAdapters(Domain, ApplicationHost, self, local);
        self.* = .{
            .allocator = allocator,
            .operation_history = @import("../host/operation_store.zig").Store.init(allocator),
            .windows = .{ .allocator = allocator },
            .sessions = try session.SessionHost.initWithPlugins(allocator, adapters[0..if (has_file_plugin) @as(usize, 3) else 2], manifests, renderers),
            .local_adapter = local,
            .dispatcher = .{ .allocator = allocator },
            .has_file_plugin = has_file_plugin,
        };
        return self;
    }

    /// Called after native windows have released their Cx and adapters.
    pub fn deinit(self: *Domain) void {
        if (self.attachments.items.len != 0) {
            std.log.warn("Shared application domain still has window attachments; retaining resources", .{});
            return;
        }
        if (self.local_adapter.shutdownStep() != .released) {
            std.log.warn("Shared local shutdown is not released; retaining its owner", .{});
            return;
        }
        if (self.tasks) |tasks| {
            if (tasks.shutdownStep() != .released) {
                std.log.warn("Shared task shutdown is not released; retaining its owner", .{});
                return;
            }
            tasks.deinit() catch return;
            self.tasks = null;
        }
        if (self.backgrounds) |host| {
            if (host.shutdownStep() != .released) {
                std.log.warn("Shared background shutdown is not released; retaining its owner", .{});
                return;
            }
            host.deinit() catch return;
            self.backgrounds = null;
        }
        self.local_adapter.deinit() catch return;
        self.operation_history.deinit();
        self.sessions.deinit();
        self.windows.deinit();
        self.dispatcher.deinit();
        self.attachments.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn retireClosedOperations(self: *Domain) void {
        for (self.sessions.sessions.items) |entry| {
            const state = self.sessions.queryState(entry.handle) orelse continue;
            switch (state.lifecycle) {
                .closing, .closed, .failed, .ended, .cleanup_unknown => self.operation_history.ownerClosed(state.handle) catch |err| std.log.warn("operation history owner retirement: {s}", .{@errorName(err)}),
                else => {},
            }
        }
    }
    /// One journal belongs to the process, so consuming from window A must
    /// deliver window B's event to B instead of silently discarding it.
    fn drainJournal(self: *Domain) void {
        while (self.sessions.journal.take()) |owned_event| {
            var event = owned_event;
            defer event.deinit();
            if (event.value.key.owner != .session) continue;
            const source = self.ownerForHandle(event.value.key.owner.session) orelse continue;
            const mapping = source.findHandle(event.value.key.owner.session) orelse {
                if (event.value.kind == .failed) if (event.value.failure) |failure|
                    source.publishFileCreateFailure(event.value.key, failure);
                continue;
            };
            if (!mapping.create_operation.eql(event.value.key)) continue;
            if (event.value.failure) |failure| if (event.value.kind == .failed) mapping.recordFailure(failure.safe_message);
        }
    }

    pub fn sharedForward(raw: *anyopaque, binding: session.ServiceHandle, exit_index: ?usize) !*@import("../proto/ssh/forward_service.zig").Service {
        const self: *Domain = @ptrCast(@alignCast(raw));
        if (!self.sessions.bindingIsLive(binding) or binding.origin_session == null) return error.StaleForwardBinding;
        if (self.backgrounds) |host| if (host.owns(binding.origin_session.?)) return host.forwardService(binding, exit_index);
        const host = self.ownerForHandle(binding.origin_session.?) orelse return error.StaleSession;
        return host.sshForwardService(binding, exit_index);
    }

    pub fn stopBackgroundOwner(self: *Domain, owner: identity.SessionHandle) !OperationKey {
        const host = self.backgrounds orelse return error.StaleSession;
        if (!host.owns(owner)) return error.StaleSession;
        _ = host.requestStop(owner);
        return self.sessions.requestClose(owner, .{
            .pause_transfers = .{ .context = self, .run = backgroundPause },
            .stop_ai = .{ .context = self, .run = backgroundStopAi },
            .release_forwards = .{ .context = self, .run = backgroundReleaseForwards },
            .release_content = .{ .context = self, .run = backgroundReleaseContent },
        });
    }
    fn backgroundStep(raw: *anyopaque, owner: identity.SessionHandle, key: OperationKey, step: CloseStep) CloseReceipt {
        const self: *Domain = @ptrCast(@alignCast(raw));
        return (self.backgrounds orelse return .unknown).closeStep(owner, key, step);
    }
    fn backgroundPause(raw: *anyopaque, owner: identity.SessionHandle, key: OperationKey) !CloseReceipt {
        return backgroundStep(raw, owner, key, .pause_transfers);
    }
    fn backgroundStopAi(raw: *anyopaque, owner: identity.SessionHandle, key: OperationKey) !CloseReceipt {
        return backgroundStep(raw, owner, key, .stop_ai);
    }
    fn backgroundReleaseForwards(raw: *anyopaque, owner: identity.SessionHandle, key: OperationKey) !CloseReceipt {
        return backgroundStep(raw, owner, key, .release_forwards);
    }
    fn backgroundReleaseContent(raw: *anyopaque, owner: identity.SessionHandle, key: OperationKey) !CloseReceipt {
        return backgroundStep(raw, owner, key, .release_content);
    }

    fn detach(self: *Domain, host: *ApplicationHost) void {
        for (self.attachments.items, 0..) |attachment, index| if (attachment == host) {
            _ = self.attachments.orderedRemove(index);
            break;
        };
        // Exceptional teardown can arrive without the native close callback.
        // Retire that window identity without touching a sibling workspace.
        if (self.windows.find(host.window_id)) |window| if (!window.closing) {
            const ticket = self.windows.beginClose(host.window_id) catch return;
            self.windows.completeClose(ticket) catch {};
        };
    }

    pub fn ownerForWindow(self: *Domain, id: identity.WindowId) ?*ApplicationHost {
        for (self.attachments.items) |host| if (host.window_id == id) return host;
        return null;
    }
    pub fn ownerForTarget(self: *Domain, target_value: session.AttachmentTarget) ?*ApplicationHost {
        for (self.attachments.items) |host| if (host.window_id == target_value.window_id and host.workspace_id == target_value.workspace_id) return host;
        return null;
    }
    pub fn ownerForHandle(self: *Domain, handle: identity.SessionHandle) ?*ApplicationHost {
        const state = self.sessions.queryState(handle) orelse return null;
        return self.ownerForTarget(state.target);
    }
    fn ownerForKey(self: *Domain, key: OperationKey) ?*ApplicationHost {
        return if (key.owner == .session) self.ownerForHandle(key.owner.session) else null;
    }
    /// A provider retains its own lifecycle callbacks. This bridge only resolves
    /// the destination window; it never selects an engine from a protocol ID.
    pub fn windowFactory(comptime implementation: session.Adapter.VTable) session.Adapter.VTable {
        return struct {
            fn create(raw: *anyopaque, request: session.CreateRequest) !void {
                const self: *Domain = @ptrCast(@alignCast(raw));
                const host = self.ownerForTarget(request.target) orelse return error.WorkspaceClosed;
                if (host.workspace.shutting_down or host.windowClosePending()) return error.WorkspaceClosed;
                return implementation.create(host, request);
            }
            fn cancel(raw: *anyopaque, key: OperationKey) CloseReceipt {
                const self: *Domain = @ptrCast(@alignCast(raw));
                if (key.owner == .session) if (self.backgrounds) |background_host| if (background_host.owns(key.owner.session)) return background_host.cancel(key);
                const host = self.ownerForKey(key) orelse return .unknown;
                return implementation.cancel(host, key);
            }
            fn close(raw: *anyopaque, handle: identity.SessionHandle, key: OperationKey) !CloseReceipt {
                const self: *Domain = @ptrCast(@alignCast(raw));
                if (self.backgrounds) |background_host| if (background_host.owns(handle)) return background_host.closeStep(handle, key, .close_protocol);
                const host = self.ownerForHandle(handle) orelse return .unknown;
                return implementation.close(host, handle, key);
            }
            fn stale(raw: *anyopaque, handle: identity.SessionHandle, key: OperationKey) void {
                const self: *Domain = @ptrCast(@alignCast(raw));
                if (self.backgrounds) |background_host| if (background_host.owns(handle)) return background_host.releaseStale(handle, key);
                const host = self.ownerForHandle(handle) orelse return;
                implementation.release_stale(host, handle, key);
            }
            const vtable: session.Adapter.VTable = .{ .create = create, .cancel = cancel, .close = close, .release_stale = stale };
        }.vtable;
    }
};

/// Keep this allocation stable: adapter and workspace callbacks borrow self.
/// init does not install callbacks or register cleanup with a UI scope. The
/// application installs it after its close-risk bridge and calls deinit after
/// it has stopped workspace polling/worker events during shutdown.
pub const ApplicationHost = struct {
    allocator: std.mem.Allocator,
    workspace: *workspace_mod.Workspace,
    domain: *Domain,
    owns_domain: bool = false,
    windows: *windows.Host,
    window_id: identity.WindowId,
    workspace_id: identity.WorkspaceId,
    sessions: *session.SessionHost,
    local_adapter: *local_mod.Service,
    dispatcher: *commands.Dispatcher,
    overlay: overlay_model.OverlayHost,
    close_extension: ?CloseExtension = null,
    mappings: std.ArrayList(Mapping) = .empty,
    history_closes: std.ArrayList(HistoryClose) = .empty,
    pending_source: ?*const SourceSnapshot = null,
    previous_sessions: workspace_mod.SessionBridge = .{},
    previous_close: workspace_mod.CloseBridge = .{},
    previous_window_close: workspace_mod.WindowCloseBridge = .{},
    window_close: ?WindowClose = null,
    installed: bool = false,
    last_rejection: ?commands.Rejection = null,
    file_plugin: ?FilePlugin = null,
    file_sources: std.ArrayList(FileCreateSource) = .empty,
    /// A failed create has no tab to own the usual workspace feedback channel.
    /// Delivered once on the original window, with the exact frozen owner.
    file_failure: ?struct {
        context: *anyopaque,
        publish: *const fn (*anyopaque, identity.SessionHandle, []const u8) void,
    } = null,
    plugin_attempts: std.ArrayList(session.Accepted) = .empty,
    background_previous_auth: ?workspace_mod.ExternalAuthentication = null,

    pub fn init(allocator: std.mem.Allocator, workspace: *workspace_mod.Workspace) !*ApplicationHost {
        return initWithFilePlugin(allocator, workspace, null);
    }

    pub fn initWithFilePlugin(allocator: std.mem.Allocator, workspace: *workspace_mod.Workspace, file_plugin: ?FilePlugin) !*ApplicationHost {
        const domain = try Domain.init(allocator, file_plugin != null);
        errdefer domain.deinit();
        const self = try initInDomain(domain, workspace, file_plugin);
        self.owns_domain = true;
        return self;
    }

    /// Attach a workspace to the application's existing service registry.
    /// The domain outlives all window Cx instances and owns process identities.
    pub fn initInDomain(domain: *Domain, workspace: *workspace_mod.Workspace, file_plugin: ?FilePlugin) !*ApplicationHost {
        if (file_plugin) |plugin| if (plugin.adapter.registration.plugin_id != .sftp) return error.InvalidFilePlugin;
        if (file_plugin != null and !domain.has_file_plugin) return error.FilePluginUnavailable;
        const self = try domain.allocator.create(ApplicationHost);
        errdefer domain.allocator.destroy(self);
        try domain.attachments.ensureUnusedCapacity(domain.allocator, 1);
        const request = (try domain.windows.requestCreate(.workspace)).pending;
        errdefer domain.windows.failed(request) catch {};
        const window = try domain.windows.ready(request);
        self.* = .{
            .allocator = domain.allocator,
            .domain = domain,
            .workspace = workspace,
            .windows = &domain.windows,
            .window_id = window.id,
            .workspace_id = window.workspace.?,
            .sessions = &domain.sessions,
            .local_adapter = domain.local_adapter,
            .file_plugin = file_plugin,
            .dispatcher = &domain.dispatcher,
            .overlay = overlay_model.OverlayHost.init(domain.allocator, window.id),
        };
        domain.attachments.appendAssumeCapacity(self);
        workspace.plugins = self.sessions.registry;
        workspace.configureIdentity(self.window_id, self.workspace_id);
        return self;
    }

    pub fn install(self: *ApplicationHost) void {
        if (self.installed) return;
        self.previous_sessions = self.workspace.session_bridge;
        self.previous_close = self.workspace.close_bridge;
        self.previous_window_close = self.workspace.window_close_bridge;
        self.workspace.session_bridge = .{ .context = self, .create = bridgeCreate, .recreate = bridgeRecreate, .connected = bridgeConnected, .failed = bridgeFailed, .cleanup = bridgeCleanup, .cleanup_status = bridgeCleanupStatus, .create_local = bridgeCreateLocal, .duplicate_local = bridgeDuplicateLocal, .retry_local = bridgeRetryLocal, .retry_ssh = bridgeRetrySsh };
        // Resource teardown belongs to the five typed close steps. The old
        // aggregate cleanup callback is replaced by close_extension.
        self.workspace.close_bridge = .{ .context = self, .risk = bridgeRisk, .impact = bridgeImpact, .close_state = bridgeCloseState, .request_close = bridgeClose, .confirm = if (self.previous_close.confirm != null) bridgeConfirm else null };
        self.workspace.window_close_bridge = .{ .context = self, .cancelled = bridgeWindowCancelled };
        if (self.domain.backgrounds != null) self.installBackgroundAuth();
        self.installed = true;
    }

    pub fn uninstall(self: *ApplicationHost) void {
        if (!self.installed) return;
        if (self.workspace.session_bridge.context == @as(?*anyopaque, self)) self.workspace.session_bridge = self.previous_sessions;
        if (self.workspace.close_bridge.context == @as(?*anyopaque, self)) self.workspace.close_bridge = self.previous_close;
        if (self.workspace.window_close_bridge.context == @as(?*anyopaque, self)) self.workspace.window_close_bridge = self.previous_window_close;
        if (self.workspace.external_auth) |installed| if (installed.context == @as(*anyopaque, self)) {
            self.workspace.external_auth = self.background_previous_auth;
        };
        self.installed = false;
    }

    pub fn deinit(self: *ApplicationHost) void {
        // Native close normally reaches this with every view already released.
        // An exceptional teardown must retain unknown/live owners, never free
        // a TextSlot beneath a view or claim a worker's cleanup completed.
        if (self.file_plugin) |plugin| if (plugin.shutdown(plugin.context) != .released) {
            std.log.warn("File shutdown is not released; retaining its owner", .{});
            return;
        };
        for (self.mappings.items) |mapping| if (mapping.process != null)
            self.workspace.unbindLocalTerminal(mapping.legacy_id, mapping.handle);
        if (self.workspace.external_auth) |installed| {
            if (installed.context == @as(*anyopaque, self)) self.workspace.external_auth = self.background_previous_auth;
        }
        if (self.window_close) |close| _ = self.workspace.endWindowCloseBatch(close.ticket.request);
        self.uninstall();
        self.overlay.deinit();
        const domain = self.domain;
        const owns_domain = self.owns_domain;
        domain.detach(self);
        for (self.mappings.items) |*mapping| if (mapping.source) |*source| source.deinit();
        self.mappings.deinit(self.allocator);
        self.history_closes.deinit(self.allocator);
        for (self.file_sources.items) |*source| source.source.deinit();
        self.file_sources.deinit(self.allocator);
        self.plugin_attempts.deinit(self.allocator);
        self.allocator.destroy(self);
        if (owns_domain) domain.deinit();
    }

    pub fn setCloseExtension(self: *ApplicationHost, context: *anyopaque, run: *const fn (*anyopaque, LegacySessionId, CloseStep) CloseReceipt) void {
        self.close_extension = .{ .context = context, .run = run };
    }

    pub fn registry(self: *const ApplicationHost) plugins.Registry {
        return self.sessions.registry;
    }

    /// Frozen UI identity for a queued file create, independent of current
    /// registry edits or tab focus. Borrowed until application shutdown.
    pub fn fileSource(self: *const ApplicationHost, owner: identity.SessionHandle, key: OperationKey) !FileSource {
        for (self.file_sources.items) |source| if (source.handle.eql(owner) and source.key.eql(key)) return source.source.value;
        return error.StaleFileCreate;
    }

    /// Presentation callback invoked after the real adapter publishes ready.
    /// Content/scope ownership transfers only on success, as in Workspace.
    pub fn attachFileSession(self: *ApplicationHost, owner: identity.SessionHandle, key: OperationKey, content: *ui.Node, scope: *ui.Scope) !session.Attachment {
        const state = self.sessions.queryState(owner) orelse return error.StaleSession;
        if (self.workspace.shutting_down or self.windowClosePending()) return error.WorkspaceClosed;
        if (!state.create_operation.eql(key) or state.lifecycle != .ready) return error.FileSessionNotReady;
        if (!std.meta.eql(state.target, self.target())) return error.WrongAttachmentTarget;
        if (self.findHandle(owner) != null) return error.FileSessionAlreadyAttached;
        const source = try self.fileSource(owner, key);
        try self.mappings.ensureUnusedCapacity(self.allocator, 1);
        const id = try self.workspace.createFileSessionDirect(owner, source.host, source.host_id, source.source_index, content, scope);
        const tab = self.workspace.sessionTab(id).?;
        tab.file_ready = true;
        self.mappings.appendAssumeCapacity(.{ .handle = owner, .create_operation = key, .legacy_id = id, .legacy_generation = tab.generation, .tab_id = tab.tab_id, .owner = tab.content_owner, .source = null, .ready_published = true });
        if (@import("../platform/runtime_mode.zig").automation) std.debug.print("SFTP_WORKSPACE_TRACE {{\"event\":\"attached\",\"owner\":{{\"session_id\":{d},\"generation\":{d}}},\"create_operation\":{d},\"tab_id\":{d},\"plugin\":\"sftp\",\"terminal_present\":{},\"runtime_present\":{}}}\n", .{ @backingInt(owner.session_id), owner.generation, key.operation_id, @backingInt(tab.tab_id), tab.terminal != null, tab.runtime != null });
        return .{ .target = state.target, .tab_id = tab.tab_id };
    }

    pub fn supportsIntegration(self: *ApplicationHost, handle: identity.SessionHandle, comptime feature: []const u8) bool {
        const manifest = self.sessions.manifestFor(handle) orelse return false;
        return @field(manifest.integration, feature);
    }
    fn registeredServices(self: *ApplicationHost, handle: identity.SessionHandle) plugins.Services {
        const manifest = self.sessions.manifestFor(handle) orelse return .{};
        const registration = manifest.legacy_registration orelse return .{};
        return registration.services;
    }

    pub fn localProcess(self: *ApplicationHost, id: LegacySessionId) !?local_mod.ProcessSnapshot {
        const mapping = self.localMapping(id) orelse return null;
        return try mapping.process.?.processSnapshot(mapping.handle);
    }
    pub fn localCwd(self: *ApplicationHost, id: LegacySessionId, allocator: std.mem.Allocator) !?local_mod.CwdSnapshot {
        const mapping = self.localMapping(id) orelse return null;
        return try mapping.process.?.cwdSnapshot(mapping.handle, allocator);
    }
    pub fn localCloseRisk(self: *ApplicationHost, id: LegacySessionId, allocator: std.mem.Allocator) !?local_mod.CloseRiskSnapshot {
        const mapping = self.localMapping(id) orelse return null;
        return try mapping.process.?.closeRiskSnapshot(mapping.handle, allocator);
    }
    pub fn terminalSnapshot(self: *ApplicationHost, id: LegacySessionId) ?*const terminal.TerminalSnapshot {
        const mapping = self.localMapping(id) orelse return null;
        const tab = self.workspace.sessionTab(id) orelse return null;
        return tab.terminal.?.terminalSnapshot(mapping.handle);
    }
    fn localMapping(self: *ApplicationHost, id: LegacySessionId) ?*Mapping {
        for (self.mappings.items) |*mapping| if (mapping.legacy_id == id and mapping.process != null and !mapping.local_retired) return mapping;
        return null;
    }

    pub fn createLocal(self: *ApplicationHost, cwd: ?[]const u8) !session.Accepted {
        const decision = try self.createLocalForInput(try self.dispatcher.issue(), cwd);
        return switch (decision) {
            .accepted => |key| .{ .handle = key.owner.session, .operation = key },
            .rejected => error.CommandRejected,
        };
    }
    pub fn createLocalForInput(self: *ApplicationHost, command_id: u64, cwd: ?[]const u8) !commands.Decision {
        return self.dispatcher.submit(.{ .command_id = command_id, .kind = .create_local_session, .owner = .app, .view_revision = self.workspace.app_config.config_revision, .payload = .{ .text = cwd orelse "" } }, .{
            .owner = .app,
            .view_revision = self.workspace.app_config.config_revision,
            .action_context = .{ .supported = .{ .session_factory = true }, .ready = .{ .session_factory = true }, .lifecycle_allows = !self.workspace.shutting_down and self.workspace.model.window_close == null, .permission_granted = true, .handler_ready = true },
        }, .{ .context = self, .submit = submitCreateLocal });
    }

    pub fn retryLocal(self: *ApplicationHost, id: LegacySessionId) !session.Accepted {
        if (self.workspace.shutting_down or self.workspace.model.window_close != null) return error.WorkspaceClosed;
        const mapping = self.localMapping(id) orelse return error.UnknownSession;
        const state = self.sessions.queryState(mapping.handle) orelse return error.StaleSession;
        if (state.lifecycle != .failed) return error.LifecycleDoesNotAllowRetry;
        if (state.create_cleanup != .released) return error.CleanupNotReleased;
        const tab = self.workspace.sessionTab(id) orelse return error.StaleSession;
        const index = self.workspace.model.indexOf(tab.tab_id) orelse return error.StaleSession;
        if (self.workspace.model.tabs.items[index].revision == std.math.maxInt(u64)) return error.RevisionExhausted;
        self.workspace.unbindLocalTerminal(id, mapping.handle);
        return self.sessions.retry(mapping.handle);
    }

    pub fn duplicateLocal(self: *ApplicationHost, id: LegacySessionId) !session.Accepted {
        const mapping = self.localMapping(id) orelse return error.UnknownSession;
        const cwd = try mapping.process.?.copyCwd(mapping.handle, self.allocator);
        defer if (cwd) |value| self.allocator.free(value);
        const accepted = try self.createLocal(cwd);
        if (cwd == null) self.workspace.status("当前本地目录未知，新会话使用用户主目录");
        return accepted;
    }

    pub fn ownerForLegacy(self: *const ApplicationHost, id: LegacySessionId) ?identity.SessionHandle {
        for (self.mappings.items) |mapping| if (mapping.legacy_id == id) return mapping.handle;
        return null;
    }

    /// A facade for the real IO-owner mailbox, scoped to the host's current
    /// generation. A parked/reconnecting worker exposes no live exec binding.
    pub fn sshExecService(self: *ApplicationHost, handle: identity.SessionHandle) !@import("../ai/execbridge.zig").ExecBridge {
        const mapping = self.findHandle(handle) orelse return error.StaleSession;
        const binding = switch (self.sessions.queryService(handle, .exec)) {
            .available => |binding| binding,
            else => return error.ServiceUnavailable,
        };
        if (!self.sessions.bindingIsLive(binding)) return error.StaleBinding;
        const tab = self.workspace.sessionTab(mapping.legacy_id) orelse return error.StaleSession;
        if (tab.generation != mapping.legacy_generation or tab.tab_id != mapping.tab_id or !tab.content_owner.eql(mapping.owner)) return error.StaleSession;
        const runtime = tab.runtime orelse return error.ServiceUnavailable;
        if (runtime.torn_down) return error.ServiceUnavailable;
        const state = runtime.reconnectSnapshot() orelse return error.ServiceUnavailable;
        if (state.key == null or !state.key.?.eql(mapping.create_operation) or (state.phase != .active and state.phase != .ready)) return error.ServiceUnavailable;
        return runtime.execService(binding);
    }

    /// Typed controller facade for the exact already authenticated hop. Native
    /// forwarding stays in that hop's Worker/Relay, including reconnects.
    pub fn sshForwardService(self: *ApplicationHost, binding: session.ServiceHandle, exit_index: ?usize) !*@import("../proto/ssh/forward_service.zig").Service {
        if (!self.sessions.bindingIsLive(binding) or binding.kind != .forward or binding.origin_session == null) return error.StaleForwardBinding;
        const handle = binding.origin_session.?;
        const snapshot = self.sessions.queryState(handle) orelse return error.StaleSession;
        if (snapshot.purpose == .socks_background) return (self.domain.backgrounds orelse return error.ServiceUnavailable).forwardService(binding, exit_index);
        const mapping = self.findHandle(handle) orelse return error.StaleSession;
        const tab = self.workspace.sessionTab(mapping.legacy_id) orelse return error.StaleSession;
        if (tab.generation != mapping.legacy_generation or tab.tab_id != mapping.tab_id or !tab.content_owner.eql(mapping.owner)) return error.StaleSession;
        const runtime = tab.runtime orelse return error.ServiceUnavailable;
        if (runtime.torn_down) return error.ServiceUnavailable;
        const state = runtime.reconnectSnapshot() orelse return error.ServiceUnavailable;
        if (state.key == null or !state.key.?.eql(mapping.create_operation) or (state.phase != .active and state.phase != .ready)) return error.ServiceUnavailable;
        return runtime.forwardService(binding, exit_index);
    }

    pub fn sshConnectionDetails(self: *ApplicationHost, handle: identity.SessionHandle) !@import("../proto/ssh/connection_details.zig").ConnectionDetailsSnapshot {
        const mapping = self.findHandle(handle) orelse return error.StaleSession;
        const state = self.sessions.queryState(handle) orelse return error.StaleSession;
        if (state.lifecycle == .closed) return error.StaleSession;
        const store = try self.workspace.connectionDetailsStore(mapping.legacy_id, mapping.create_operation);
        return store.snapshot(mapping.create_operation);
    }
    pub fn requestSshRtt(self: *ApplicationHost, handle: identity.SessionHandle, hop: ?usize) !u64 {
        const mapping = self.findHandle(handle) orelse return error.StaleSession;
        const state = self.sessions.queryState(handle) orelse return error.StaleSession;
        if (state.lifecycle != .attached or self.windowClosePending()) return error.ServiceUnavailable;
        const store = try self.workspace.connectionDetailsStore(mapping.legacy_id, mapping.create_operation);
        return store.request(mapping.create_operation, hop, 1500);
    }
    pub fn cancelSshRtt(self: *ApplicationHost, handle: identity.SessionHandle, request_id: u64) !void {
        const mapping = self.findHandle(handle) orelse return error.StaleSession;
        const store = try self.workspace.connectionDetailsStore(mapping.legacy_id, mapping.create_operation);
        try store.cancel(mapping.create_operation, request_id);
    }

    /// Manual and timer retries reserve the same ticket. Native IO starts only
    /// in safeTick, after the old attempt's real release receipt.
    pub fn requestSshReconnect(self: *ApplicationHost, id: LegacySessionId) !void {
        if (self.workspace.shutting_down or self.windowClosePending()) return error.WorkspaceClosed;
        const mapping = self.findLegacyId(id) orelse return error.UnknownSession;
        if (!self.supportsIntegration(mapping.handle, "transport_loss")) return error.LocalSessionDoesNotReconnect;
        _ = try self.syncSshReconnect(mapping);
        const state = self.sessions.queryState(mapping.handle) orelse return error.StaleSession;
        if (state.lifecycle != .failed and state.lifecycle != .ended) return error.LifecycleDoesNotAllowRetry;
        if (mapping.reconnect_ticket == null) mapping.reconnect_ticket = .{ .key = mapping.create_operation, .deadline_ns = null };
        if (!mapping.reconnect_ticket.?.claim(mapping.create_operation, @import("../platform/realtime.zig").monotonicNs(), true)) return error.ReconnectAlreadyRequested;
        self.workspace.cx.requestRedraw();
    }

    pub fn legacyForHandle(self: *const ApplicationHost, handle: identity.SessionHandle) ?LegacySessionId {
        for (self.mappings.items) |mapping| if (mapping.handle.eql(handle)) return mapping.legacy_id;
        return null;
    }

    pub fn requestWindowClose(self: *ApplicationHost) !OperationKey {
        if (self.windowClosePending()) return self.window_close.?.key;
        const revision = @max(self.workspace.model.order_revision, 1);
        const decision = try self.dispatcher.submit(.{ .command_id = try self.dispatcher.issue(), .kind = .request_close_window, .owner = .app, .view_revision = revision, .payload = .{ .number = @backingInt(self.window_id) } }, .{
            .owner = .app,
            .view_revision = revision,
            .action_context = .{ .lifecycle_allows = !self.workspace.shutting_down, .permission_granted = true, .handler_ready = true },
        }, .{ .context = self, .submit = submitWindowClose });
        return switch (decision) {
            .accepted => |key| key,
            .rejected => error.CommandRejected,
        };
    }

    pub fn windowClosePending(self: *const ApplicationHost) bool {
        const close = self.window_close orelse return false;
        return close.state == .draining or close.state == .ready;
    }

    pub fn windowCloseReady(self: *const ApplicationHost) bool {
        const close = self.window_close orelse return false;
        return close.state == .ready and !close.cancel_requested;
    }

    /// Called after AppKit confirms native close. Publication can be retried
    /// without repeating any owner close or consuming another window ticket.
    pub fn completeWindowClose(self: *ApplicationHost) !void {
        const close = if (self.window_close) |*close| close else return error.NoWindowClose;
        if (close.state == .closed) return;
        if (!self.windowCloseReady()) return error.WindowCloseNotReady;
        if (!self.windowTargetsReleased(close.targets)) {
            close.state = .draining;
            return error.WindowCloseNotReady;
        }
        _ = try self.sessions.journal.completeReleased(close.key, "window closed");
        try self.windows.completeClose(close.ticket);
        _ = self.workspace.endWindowCloseBatch(close.ticket.request);
        close.state = .closed;
    }

    pub fn cancelWindowClose(self: *ApplicationHost) !bool {
        const close = if (self.window_close) |*close| close else return false;
        if (!self.windowClosePending()) return false;
        close.cancel_requested = true;
        _ = try self.sessions.journal.publish(close.key, .cancelled, "window close cancelled", null);
        _ = try self.sessions.journal.publish(close.key, .cleanup_released, "window close request released", null);
        try self.workspace.model.cancelWindowClose(close.ticket.request);
        try self.windows.cancelClose(close.ticket);
        _ = self.workspace.endWindowCloseBatch(close.ticket.request);
        close.state = .cancelled;
        return true;
    }

    pub fn create(self: *ApplicationHost, host: hosts.HostConfig, host_id: workspace_mod.HostId, source_index: usize, initial_input: []const u8) !session.Accepted {
        if (!host.isLegacy()) {
            var arena: std.heap.ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            return self.openEnvelope(try connection_envelope.fromLegacy(arena.allocator(), host), try self.dispatcher.issue());
        }
        const decision = try self.createForInput(try self.dispatcher.issue(), host, host_id, source_index, initial_input);
        return switch (decision) {
            .accepted => |key| .{ .handle = key.owner.session, .operation = key },
            .rejected => error.CommandRejected,
        };
    }

    pub fn openEnvelope(self: *ApplicationHost, value: connection_envelope.Envelope, request_key: u64) !session.Accepted {
        if (self.workspace.shutting_down or self.windowClosePending()) return error.WorkspaceClosed;
        const manifest = self.sessions.registry.find(value.protocol_id) orelse return error.UnknownPlugin;
        const renderer = self.sessions.registry.renderer(manifest.content_renderer) orelse return error.ContentRendererUnavailable;
        if (renderer.mount != null) try self.plugin_attempts.ensureUnusedCapacity(self.allocator, 1);
        const accepted = try self.sessions.open(value, .{ .request_key = request_key, .target = self.target() });
        if (renderer.mount != null) {
            for (self.plugin_attempts.items) |previous| if (previous.handle.eql(accepted.handle)) return accepted;
            self.plugin_attempts.appendAssumeCapacity(accepted);
        }
        return accepted;
    }

    /// Capture at command acceptance; later registry edits cannot retarget the
    /// connection while its native window is being created.
    pub fn freezeWindowConnection(self: *ApplicationHost, host_id: workspace_mod.HostId) !WindowConnection {
        if (self.workspace.shutting_down or self.windowClosePending()) return error.WorkspaceClosed;
        const index = self.workspace.hostIndex(host_id) orelse return error.StaleAsset;
        return WindowConnection.init(self.allocator, self.workspace.registry.hosts[index], self.workspace.app_config.*, self.workspace.registry.hosts, host_id, index);
    }

    /// Called only after the destination workspace has mounted and registered
    /// its own WindowId. This never consults the currently active native view.
    pub fn createWindowConnection(self: *ApplicationHost, source: *const WindowConnection) !session.Accepted {
        if (self.workspace.shutting_down or self.windowClosePending()) return error.WorkspaceClosed;
        if (self.pending_source != null) return error.ReentrantCreate;
        self.pending_source = if (source.remote) |*remote| remote else null;
        defer self.pending_source = null;
        return self.openEnvelope(source.envelope.value, try self.dispatcher.issue());
    }

    /// Saved-host sidebar entry. The normal SSH adapter receives an explicit
    /// purpose and queues no presentation, terminal runtime, or Tab mapping.
    pub fn createBackgroundSaved(self: *ApplicationHost, host_id: workspace_mod.HostId) !session.Accepted {
        if (self.workspace.shutting_down or self.windowClosePending()) return error.WorkspaceClosed;
        const index = self.workspace.hostIndex(host_id) orelse return error.StaleAsset;
        const host = self.workspace.registry.hosts[index];
        if (@backingInt(host.connection_id) == 0) return error.InvalidSessionPurpose;
        _ = try self.ensureBackgroundHost();
        var source = try freezeSource(self.allocator, host, self.workspace.app_config.*, self.workspace.registry.hosts, host_id, index, "");
        defer source.deinit();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const envelope = try connection_envelope.fromLegacy(arena.allocator(), source.value.host);
        if (self.pending_source != null) return error.ReentrantCreate;
        self.pending_source = &source;
        defer self.pending_source = null;
        return self.sessions.open(envelope, .{ .request_key = try self.dispatcher.issue(), .target = self.target(), .purpose = .socks_background });
    }
    pub fn stopBackgroundOwner(self: *ApplicationHost, owner: identity.SessionHandle) !OperationKey {
        const host = self.domain.backgrounds orelse return error.StaleSession;
        if (!host.owns(owner)) return error.StaleSession;
        _ = host.requestStop(owner);
        return self.domain.stopBackgroundOwner(owner);
    }
    pub fn requestBackgroundReconnect(self: *ApplicationHost, owner: identity.SessionHandle) !void {
        if (self.workspace.shutting_down or self.windowClosePending()) return error.WorkspaceClosed;
        _ = try (self.domain.backgrounds orelse return error.StaleSession).retry(owner);
    }
    /// The caller owns this value-only slice; there is no native pointer or Tab.
    pub fn backgroundSnapshots(self: *ApplicationHost, allocator: std.mem.Allocator) ![]background.Snapshot {
        return if (self.domain.backgrounds) |host| host.snapshots(allocator) else allocator.alloc(background.Snapshot, 0);
    }

    fn ensureBackgroundHost(self: *ApplicationHost) !*background.Host {
        if (self.domain.backgrounds) |host| {
            host.policy = self.backgroundPolicy();
            return host;
        }
        var paths = try @import("../config/paths.zig").Paths.forApplication(self.allocator);
        defer paths.deinit();
        const host = try background.Host.init(self.allocator, self.sessions, paths.known_hosts, self.backgroundPolicy());
        self.domain.backgrounds = host;
        self.installBackgroundAuth();
        return host;
    }
    fn installBackgroundAuth(self: *ApplicationHost) void {
        if (self.workspace.external_auth) |installed| if (installed.context == @as(*anyopaque, self)) return;
        self.background_previous_auth = self.workspace.external_auth;
        self.workspace.external_auth = .{ .context = self, .pending = backgroundPendingAuth, .submit = backgroundSubmitAuth, .cancel = backgroundCancelAuth, .host = backgroundAuthHost, .parent = backgroundAuthParent, .host_key = backgroundAuthHostKey, .totp = backgroundAuthTotp };
    }
    fn backgroundPolicy(self: *ApplicationHost) background.Policy {
        const saved = self.workspace.app_config.*;
        return .{ .presentation = if (saved.ssh.otp_modal) .otp_modal else .protected_form, .presentation_config_revision = saved.config_revision, .timeout_ms = @as(u32, saved.ssh.connect_timeout_sec) * 1000, .totp_autofill = saved.ssh.totp_autofill, .automatic_reconnect = saved.ssh.auto_reconnect, .reconnect_max = saved.ssh.reconnect_max, .reconnect_backoff = saved.ssh.reconnect_backoff };
    }

    /// An event routed through several UI layers passes the same issued ID.
    /// All factory entry points share the real domain handler and its key.
    pub fn createForInput(self: *ApplicationHost, command_id: u64, host: hosts.HostConfig, host_id: workspace_mod.HostId, source_index: usize, initial_input: []const u8) !commands.Decision {
        if (self.pending_source != null) return error.ReentrantCreate;
        var source = try freezeSource(self.allocator, host, self.workspace.app_config.*, self.workspace.registry.hosts, host_id, source_index, initial_input);
        defer source.deinit();
        const payload = try std.json.Stringify.valueAlloc(self.allocator, source.value, .{});
        defer self.allocator.free(payload);
        const revision = source.value.host.revision;
        const temporary = @backingInt(source.value.host.connection_id) == 0;
        const owner: identity.CommandOwner = if (temporary) .app else .{ .asset = source.value.host.owner() };
        const command: commands.UiCommand = .{
            .command_id = command_id,
            .kind = if (temporary) .create_temporary_ssh_session else .open_saved_connection,
            .owner = owner,
            .view_revision = revision,
            .payload = .{ .text = payload },
        };
        self.pending_source = &source;
        defer self.pending_source = null;
        const manifest = self.sessions.registry.find(source.value.host.protocolId());
        const connected = if (manifest) |entry| entry.session_factory != null else false;
        const decision = try self.dispatcher.submit(command, .{
            .owner = owner,
            .view_revision = revision,
            .action_context = .{
                .supported = .{ .session_factory = true },
                .ready = .{ .session_factory = connected },
                .lifecycle_allows = !self.workspace.shutting_down and self.workspace.model.window_close == null,
                .permission_granted = true,
                .handler_ready = connected,
            },
        }, .{ .context = self, .submit = submitCreate });
        self.last_rejection = switch (decision) {
            .rejected => |failure| failure,
            .accepted => null,
        };
        return decision;
    }

    /// Domain API used by the command handler; no second journal is created.
    pub fn requestCloseLegacy(self: *ApplicationHost, id: LegacySessionId) !OperationKey {
        const handle = self.ownerForLegacy(id) orelse return error.UnknownSession;
        if (self.findHandle(handle)) |mapping| if (mapping.reconnect_ticket) |*ticket| ticket.invalidate();
        return self.sessions.requestClose(handle, self.closeHooks()) catch |err| {
            // Once the domain has accepted a close, a later publication OOM
            // must not turn its real operation into a rejected UI command.
            const state = self.sessions.queryState(handle) orelse return err;
            const key = state.close_operation orelse return err;
            const mapping = self.findHandle(handle).?;
            if (mapping.waiting == null) mapping.waiting = .{ .key = key, .step = .release_content };
            return key;
        };
    }

    pub fn closeForInput(self: *ApplicationHost, command_id: u64, tab_id: identity.TabId, owner: identity.ContentOwner) !commands.Decision {
        const index = self.workspace.model.indexOf(tab_id) orelse return error.StaleSession;
        if (!self.workspace.model.tabs.items[index].owner.eql(owner)) return error.StaleSession;
        const revision = self.workspace.model.tabs.items[index].revision;
        const command_owner: identity.CommandOwner = switch (owner) {
            .session => .{ .session = (self.findTab(tab_id, owner) orelse return error.StaleSession).handle },
            .history => |id| .{ .history = id },
            .group => return error.UnsupportedOwner,
        };
        return self.dispatcher.submit(.{ .command_id = command_id, .kind = .request_close, .owner = command_owner, .view_revision = revision, .payload = .{ .tab = tab_id } }, .{
            .owner = command_owner,
            .view_revision = revision,
            .action_context = .{ .has_tab = true, .permission_granted = true, .handler_ready = true },
        }, .{ .context = self, .submit = submitClose });
    }

    /// Call only from an after-layout/before-render safe hook. A queued view
    /// removal is acknowledged after Workspace's own safe hook has removed it.
    /// The return value indicates outstanding asynchronous work.
    /// Stage a renderer in the destination Cx, atomically rebind its controller,
    /// then discard the source view. No create/reconnect or close is dispatched.
    pub fn transferPluginTo(self: *ApplicationHost, destination: *ApplicationHost, owner: identity.SessionHandle, new_context: @import("../host/host_context.zig").HostContext) !void {
        if (self == destination or self.domain != destination.domain) return error.InvalidTransferDestination;
        if (self.windowClosePending() or destination.windowClosePending() or destination.workspace.shutting_down) return error.WindowClosing;
        const original = (self.findHandle(owner) orelse return error.ContentNotAttached).*;
        if (original.source != null or original.process != null or original.waiting != null) return error.ContentTransferUnavailable;
        try self.workspace.validatePluginTransfer(owner, original.legacy_id);
        const state = self.sessions.queryState(owner) orelse return error.UnknownSession;
        const expected = state.attachment orelse return error.ContentNotAttached;
        const manifest = self.sessions.manifestFor(owner) orelse return error.UnknownPlugin;
        const renderer = self.sessions.registry.renderer(manifest.content_renderer) orelse return error.ContentRendererUnavailable;
        if (!renderer.supports_window_transfer) return error.WindowTransferUnsupported;
        if (destination.findHandle(owner) != null) return error.ContentAlreadyAttached;
        try destination.mappings.ensureUnusedCapacity(destination.allocator, 1);
        try destination.plugin_attempts.ensureUnusedCapacity(destination.allocator, 1);
        const connection = self.sessions.connectionEnvelope(owner) orelse return error.ConnectionUnavailable;
        const new_id = try destination.workspace.createPluginSession(owner, connection, renderer.*);
        errdefer destination.workspace.discardTransferredPlugin(owner, new_id);
        const new_tab = destination.workspace.sessionTab(new_id).?;
        new_tab.setTitle(self.workspace.sessionTab(original.legacy_id).?.titleSlice());
        try self.sessions.retargetAttached(owner, expected, .{ .target = destination.target(), .tab_id = new_tab.tab_id }, new_context);
        var moved = original;
        moved.legacy_id = new_id;
        moved.legacy_generation = new_tab.generation;
        moved.tab_id = new_tab.tab_id;
        destination.mappings.appendAssumeCapacity(moved);
        for (self.mappings.items, 0..) |entry, index| if (entry.handle.eql(owner)) {
            _ = self.mappings.orderedRemove(index);
            break;
        };
        for (self.plugin_attempts.items, 0..) |attempt, index| if (attempt.handle.eql(owner)) {
            destination.plugin_attempts.appendAssumeCapacity(attempt);
            _ = self.plugin_attempts.orderedRemove(index);
            break;
        };
        self.workspace.discardTransferredPlugin(owner, original.legacy_id);
    }

    pub fn safeTick(self: *ApplicationHost) !bool {
        self.local_adapter.applyRecordingRetention(self.workspace.app_config.config_revision, self.workspace.app_config.log.retention_days);
        var background_pending = false;
        if (self.domain.backgrounds) |host| {
            self.installBackgroundAuth();
            if ((self.windowClosePending() or self.workspace.shutting_down) and self.domain.attachments.items.len == 1) {
                const values = try host.snapshots(self.allocator);
                defer self.allocator.free(values);
                for (values) |value| {
                    const state = self.sessions.queryState(value.owner) orelse continue;
                    if (state.close_operation == null) _ = try self.stopBackgroundOwner(value.owner);
                }
            }
            background_pending = try host.safeTick();
        }
        if (self.windowClosePending()) for (self.file_sources.items) |source| {
            const state = self.sessions.queryState(source.handle) orelse continue;
            if (!state.create_operation.eql(source.key) or self.findHandle(source.handle) != null) continue;
            if (state.lifecycle == .creating or state.lifecycle == .ready) _ = try self.sessions.cancel(source.key);
        };
        var shared_pending = false;
        if (self.domain.tasks) |tasks| shared_pending = try tasks.tick(@intCast(@divTrunc(@import("../platform/realtime.zig").monotonicNs(), std.time.ns_per_ms)), self.workspace.app_config.transfer.max_tasks);
        const controller_pending = try self.sessions.pollControllers();
        self.domain.retireClosedOperations();
        for (self.plugin_attempts.items) |attempt| {
            const state = self.sessions.queryState(attempt.handle) orelse continue;
            if (state.lifecycle != .ready or self.findHandle(attempt.handle) != null) continue;
            const manifest = self.sessions.manifestFor(attempt.handle) orelse continue;
            const renderer = self.sessions.registry.renderer(manifest.content_renderer) orelse continue;
            const connection = self.sessions.connectionEnvelope(attempt.handle) orelse continue;
            try self.mappings.ensureUnusedCapacity(self.allocator, 1);
            const id = try self.workspace.createPluginSession(attempt.handle, connection, renderer.*);
            const tab = self.workspace.sessionTab(id).?;
            self.mappings.appendAssumeCapacity(.{ .handle = attempt.handle, .create_operation = attempt.operation, .legacy_id = id, .legacy_generation = tab.generation, .tab_id = tab.tab_id, .owner = tab.content_owner, .source = null, .ready_published = true, .attached_published = true });
            _ = try self.sessions.attached(attempt.handle, .{ .target = self.target(), .tab_id = tab.tab_id });
        }
        var file_pending = false;
        if (self.file_plugin) |plugin| file_pending = try plugin.tick(plugin.context, self.sessions);
        for (self.mappings.items) |mapping| if (self.supportsIntegration(mapping.handle, "transport_loss") and mapping.source != null) {
            self.workspace.pollConnectionResults();
            break;
        };
        var pending = try self.local_adapter.drain(self.sessions) or controller_pending or file_pending or background_pending or shared_pending;
        // Exactly one consumer drains the bounded raw stream, including before
        // ready and after cancellation. VT/TextSlot is consumed only by views.
        var output: [16 * 1024]u8 = undefined;
        for (self.mappings.items) |mapping| {
            if (mapping.process == null or mapping.local_retired) continue;
            var budget: usize = 256 * 1024;
            while (budget > 0) {
                const read = mapping.process.?.readOutput(mapping.handle, &output) catch |err| switch (err) {
                    error.StaleSession => break,
                    else => return err,
                };
                switch (read) {
                    .bytes => |count| {
                        budget -|= count;
                        if (count == 0) break;
                    },
                    .would_block, .eof => break,
                }
            }
            if (budget == 0) pending = true;
        }
        self.domain.drainJournal();
        for (self.mappings.items) |*mapping| {
            if (mapping.process != null) {
                try self.syncLocal(mapping);
            }
            if (self.supportsIntegration(mapping.handle, "transport_loss")) pending = try self.syncSshReconnect(mapping) or pending;
            if (self.supportsIntegration(mapping.handle, "transport_loss") and mapping.failed_received and !mapping.failed_published) {
                _ = try self.sessions.failed(mapping.handle, mapping.create_operation, .{
                    .domain = .transport,
                    .code = "connection_failed",
                    .cleanup = if (mapping.cleanup_received) .released else if (mapping.cleanup_unknown_received) .unknown else .releasing,
                    .safe_message = mapping.failure[0..mapping.failure_len],
                });
                mapping.failed_published = true;
            }
            if (self.supportsIntegration(mapping.handle, "transport_loss") and mapping.connected_received and !mapping.ready_published and !mapping.failed_received) {
                _ = try self.sessions.ready(mapping.handle, mapping.create_operation, self.registeredServices(mapping.handle));
                if (self.sessions.queryState(mapping.handle)) |state| {
                    mapping.ready_published = state.create_operation.eql(mapping.create_operation) and (state.lifecycle == .ready or state.lifecycle == .attached);
                }
            }
            if (self.supportsIntegration(mapping.handle, "transport_loss") and mapping.ready_published and !mapping.attached_published) {
                if (self.workspace.sessionTab(mapping.legacy_id)) |tab| {
                    if (tab.generation == mapping.legacy_generation and tab.tab_id == mapping.tab_id and tab.content_owner.eql(mapping.owner)) {
                        _ = try self.sessions.attached(mapping.handle, .{ .target = self.target(), .tab_id = mapping.tab_id });
                        if (self.sessions.queryState(mapping.handle)) |state| if (state.lifecycle == .attached and state.attachment != null and state.attachment.?.tab_id == mapping.tab_id) {
                            mapping.attached_published = self.workspace.acknowledgeSessionAttached(mapping.legacy_id, mapping.legacy_generation, mapping.create_operation);
                            if (mapping.attached_published) {
                                mapping.reconnect_policy = null;
                                mapping.reconnect_ticket = null;
                                mapping.reconnect_count = 0;
                            }
                        };
                    }
                }
            }
            if (self.supportsIntegration(mapping.handle, "transport_loss") and mapping.cleanup_received) {
                if (self.sessions.queryState(mapping.handle)) |state| if (state.create_cleanup != .released) {
                    _ = try self.sessions.createCleanupReceipt(mapping.handle, mapping.create_operation, .released);
                };
            } else if (self.supportsIntegration(mapping.handle, "transport_loss") and mapping.cleanup_unknown_received) {
                if (self.sessions.queryState(mapping.handle)) |state| if (state.create_cleanup != .released and state.create_cleanup != .unknown) {
                    _ = try self.sessions.createCleanupReceipt(mapping.handle, mapping.create_operation, .unknown);
                };
            }
            if (self.supportsIntegration(mapping.handle, "transport_loss") and mapping.reconnect_ticket != null) {
                const state = self.sessions.queryState(mapping.handle) orelse continue;
                if (state.lifecycle == .closing or state.lifecycle == .closed or self.workspace.shutting_down) {
                    mapping.reconnect_ticket.?.invalidate();
                } else if (!self.windowClosePending()) {
                    _ = mapping.reconnect_ticket.?.claim(mapping.create_operation, @import("../platform/realtime.zig").monotonicNs(), false);
                    const ticket = mapping.reconnect_ticket.?;
                    if (ticket.claimed and !ticket.invalidated and (state.lifecycle == .failed or state.lifecycle == .ended) and state.create_cleanup == .released) {
                        mapping.reconnect_ticket = null;
                        _ = self.sessions.retry(mapping.handle) catch |err| {
                            if (mapping.create_operation.eql(ticket.key)) mapping.reconnect_ticket = ticket;
                            return err;
                        };
                        mapping.reconnect_count +|= 1;
                        pending = true;
                    } else if (!ticket.invalidated and (ticket.deadline_ns != null or ticket.claimed)) pending = true;
                }
            }
            if (mapping.waiting) |waiting| {
                if (!waiting.unknown) {
                    mapping.waiting = null;
                    const receipt = self.runCloseStep(mapping, waiting.key, waiting.step, true);
                    if (receipt != .awaiting) _ = try self.publishCloseReceipt(mapping, waiting, receipt);
                }
            }
            if (self.sessions.queryState(mapping.handle)) |state| {
                if (state.lifecycle == .closed) {
                    if (mapping.process != null and !mapping.local_retired) {
                        self.workspace.unbindLocalTerminal(mapping.legacy_id, mapping.handle);
                        if (self.workspace.sessionTab(mapping.legacy_id) == null) {
                            mapping.process.?.retire(mapping.handle) catch |err| switch (err) {
                                error.StaleSession => {},
                                error.WorkerBusy, error.CleanupIncomplete => {
                                    pending = true;
                                    continue;
                                },
                                else => return err,
                            };
                            mapping.local_retired = true;
                        }
                    }
                    if (mapping.source) |*source| source.deinit();
                    mapping.source = null;
                    mapping.waiting = null;
                } else if (state.lifecycle == .creating) {
                    pending = true;
                } else if (mapping.waiting) |waiting| if (!waiting.unknown) {
                    pending = true;
                };
            }
        }
        for (self.history_closes.items) |*close| {
            if (close.state != .pending) continue;
            if (self.workspace.tabIndexById(close.tab_id)) |index| {
                const tab = self.workspace.tabs.items[index];
                if (!tab.archived or !tab.content_owner.eql(.{ .history = close.owner })) {
                    _ = try self.sessions.journal.publish(close.key, .cleanup_unknown, "history owner changed", null);
                    close.state = .unknown;
                    continue;
                }
                self.workspace.receiveCloseReceipt(close.tab_id, .{ .history = close.owner }, true);
                pending = true;
            } else {
                _ = try self.sessions.journal.completeReleased(close.key, "history view closed");
                close.state = .closed;
            }
        }
        if (self.window_close) |*close| {
            if (close.cancel_requested and self.windowClosePending()) {
                _ = try self.cancelWindowClose();
            } else if (close.state == .draining) {
                if (self.windowTargetsReleased(close.targets) and self.fileCreatesReleased()) {
                    const files_released = if (self.file_plugin) |plugin| plugin.shutdown(plugin.context) == .released else true;
                    if (files_released) close.state = .ready;
                }
            }
            // A native close may start after layout, including in an empty
            // workspace with no worker to wake the next frame.
            if (self.windowClosePending()) pending = true;
        }
        if (pending) self.workspace.cx.scheduleRedrawAfterNs(33 * std.time.ns_per_ms);
        return pending;
    }

    fn publishFileCreateFailure(self: *ApplicationHost, key: OperationKey, failure: @import("../host/operation.zig").Failure) void {
        if (key.owner != .session) return;
        const state = self.sessions.queryState(key.owner.session) orelse return;
        if (!state.create_operation.eql(key) or state.lifecycle != .failed) return;
        for (self.file_sources.items) |*source| {
            if (!source.handle.eql(key.owner.session) or !source.key.eql(key) or source.failure_reported) continue;
            source.failure_reported = true;
            const message = if (std.mem.eql(u8, failure.code, "ProxyJumpTransportUnavailable"))
                "连接失败：独立 SFTP 会话暂不支持跳板链（ProxyJumpTransportUnavailable）"
            else
                failure.safe_message;
            if (self.file_failure) |feedback| feedback.publish(feedback.context, source.handle, message);
            return;
        }
    }

    fn fileCreatesReleased(self: *ApplicationHost) bool {
        for (self.file_sources.items) |source| {
            const state = self.sessions.queryState(source.handle) orelse continue;
            if (!state.create_operation.eql(source.key) or self.findHandle(source.handle) != null) continue;
            if (state.lifecycle == .creating or state.lifecycle == .ready or state.create_cleanup != .released) return false;
        }
        return true;
    }

    fn syncSshReconnect(self: *ApplicationHost, mapping: *Mapping) !bool {
        if (mapping.source == null) return false;
        if (!mapping.failed_received) if (self.workspace.connectionProgress(mapping.create_operation)) |progress| {
            if (progress.finished and progress.failure != null) {
                mapping.recordFailure(@errorName(progress.failure.?));
                mapping.cleanup_received = progress.cleanup == .released;
                mapping.cleanup_unknown_received = progress.cleanup == .unknown;
            }
        };
        const tab = self.workspace.sessionTab(mapping.legacy_id) orelse return false;
        const runtime = tab.runtime orelse return false;
        if (!runtime.torn_down) runtime.setInputBufferEnabled(self.workspace.app_config.ssh.buffer_input);
        const notice = runtime.reconnectSnapshot() orelse return false;
        if (notice.key == null or !notice.key.?.eql(mapping.create_operation)) return false;
        if (notice.phase == .ready) {
            mapping.connected_received = true;
            self.workspace.finishSshReconnect(mapping.legacy_id, mapping.create_operation, null);
            return true;
        }
        if (notice.phase == .ended) {
            if (tab.terminal.?.tombstone.state == .active) {
                tab.terminal.?.tombstone.end("远端 Shell 已退出");
                tab.terminal.?.refreshTombstone();
                self.workspace.tab_rebuild_pending = true;
            }
            const cleanup: @import("../host/operation.zig").Cleanup = switch (notice.cleanup) {
                .released => .released,
                .awaiting => .releasing,
                .unknown => .unknown,
            };
            _ = try self.sessions.shellEnded(mapping.handle, mapping.create_operation, cleanup);
            _ = try self.sessions.createCleanupReceipt(mapping.handle, mapping.create_operation, switch (notice.cleanup) {
                .released => .released,
                .awaiting => .awaiting,
                .unknown => .unknown,
            });
            mapping.runtime_loss_received = true;
            mapping.cleanup_received = notice.cleanup == .released;
            mapping.cleanup_unknown_received = notice.cleanup == .unknown;
            return notice.cleanup == .awaiting;
        }
        if (notice.phase != .releasing and notice.phase != .waiting) return notice.phase == .connecting;
        if (!mapping.runtime_loss_received) {
            const state = self.sessions.queryState(mapping.handle) orelse return false;
            const failure: @import("../host/operation.zig").Failure = .{
                .domain = .transport,
                .code = @errorName(notice.failure orelse error.ConnectionClosed),
                .stage = "io",
                .retryable = true,
                .effect = .unknown,
                .cleanup = switch (notice.cleanup) {
                    .released => .released,
                    .awaiting => .releasing,
                    .unknown => .unknown,
                },
                .safe_message = @errorName(notice.failure orelse error.ConnectionClosed),
            };
            if (state.lifecycle == .attached) {
                _ = try self.sessions.transportLost(mapping.handle, mapping.create_operation, failure);
            } else if (state.lifecycle == .creating or state.lifecycle == .ready) {
                _ = try self.sessions.failed(mapping.handle, mapping.create_operation, failure);
            } else return false;
            mapping.runtime_loss_received = true;
            mapping.failed_published = true;
            mapping.recordFailure(failure.safe_message);
            self.workspace.finishSshReconnect(mapping.legacy_id, mapping.create_operation, notice.failure orelse error.ConnectionClosed);
            if (mapping.reconnect_policy == null) {
                const policy = self.workspace.app_config.ssh;
                mapping.reconnect_policy = .{ .automatic = policy.auto_reconnect and (notice.failure orelse error.ConnectionClosed) != error.Cancelled, .max = policy.reconnect_max, .backoff = policy.reconnect_backoff };
            }
            const policy = mapping.reconnect_policy.?;
            const delay: ?i128 = if (policy.automatic and mapping.reconnect_count < policy.max and mapping.reconnect_count < policy.backoff.len)
                @import("../platform/realtime.zig").monotonicNs() + @as(i128, policy.backoff[mapping.reconnect_count]) * std.time.ns_per_s
            else
                null;
            mapping.reconnect_ticket = .{ .key = mapping.create_operation, .deadline_ns = delay };
        }
        mapping.cleanup_received = notice.cleanup == .released;
        mapping.cleanup_unknown_received = notice.cleanup == .unknown;
        return notice.cleanup == .awaiting or (mapping.reconnect_ticket != null and mapping.reconnect_ticket.?.deadline_ns != null);
    }

    fn syncLocal(self: *ApplicationHost, mapping: *Mapping) !void {
        if (mapping.local_retired) return;
        const state = self.sessions.queryState(mapping.handle) orelse return;
        const tab = self.workspace.sessionTab(mapping.legacy_id) orelse return;
        if (!tab.content_owner.eql(.{ .session = mapping.handle })) return;
        if (state.lifecycle == .ready or state.lifecycle == .attached) {
            if (!tab.local_bound) switch (self.sessions.queryService(mapping.handle, .terminal)) {
                .available => |binding| try self.workspace.bindLocalTerminal(mapping.legacy_id, mapping.handle, try mapping.process.?.terminalService(binding)),
                else => {},
            };
            if (tab.local_bound and state.lifecycle == .ready) {
                _ = try self.sessions.attached(mapping.handle, .{ .target = self.target(), .tab_id = mapping.tab_id });
                mapping.attached_published = true;
            }
        }
        if (state.lifecycle == .failed) {
            if (tab.local_state != .failed) self.workspace.updateLocalState(mapping.legacy_id, .failed, if (mapping.failure_len > 0) mapping.failure[0..mapping.failure_len] else "无法启动 /bin/zsh");
            return;
        }
        if (state.lifecycle == .closing or state.lifecycle == .cleanup_unknown) {
            const next: workspace_mod.LocalState = if (state.lifecycle == .closing) .closing else .cleanup_unknown;
            if (tab.local_state != next) self.workspace.updateLocalState(mapping.legacy_id, next, if (next == .closing) "正在关闭本地会话…" else "本地资源清理结果未知");
            return;
        }
        const process = mapping.process.?.processSnapshot(mapping.handle) catch |err| switch (err) {
            error.WorkerBusy, error.StaleSession => return,
            else => return err,
        };
        const next: workspace_mod.LocalState = switch (process.state) {
            .starting => .starting,
            .running => .running,
            .exited => .exited,
            .failed => .failed,
            .closing, .closed => .closing,
            .cleanup_unknown => .cleanup_unknown,
        };
        if (next != tab.local_state) {
            var buffer: [160]u8 = undefined;
            const text = if (process.exit) |exit| switch (exit) {
                .exited => |code| try std.fmt.bufPrint(&buffer, "本地 zsh 已退出 · exit {d}", .{code}),
                .signal => |signal| try std.fmt.bufPrint(&buffer, "本地 zsh 已退出 · signal {d}", .{signal}),
            } else switch (next) {
                .starting => "正在启动 zsh…",
                .running => "本地 · zsh",
                .failed => "无法启动 /bin/zsh",
                .exited => "本地 zsh 已退出",
                .closing => "正在关闭本地会话…",
                .cleanup_unknown => "本地资源清理结果未知",
            };
            self.workspace.updateLocalState(mapping.legacy_id, next, text);
        }
    }

    /// A subsystem with an explicit completion event can resume an awaiting or
    /// unknown step. The exact handle/key/step must still own the pending close.
    pub fn closeReceipt(self: *ApplicationHost, handle: identity.SessionHandle, key: OperationKey, step: CloseStep, receipt: CloseReceipt) !bool {
        const mapping = self.findHandle(handle) orelse return false;
        const waiting = mapping.waiting orelse return false;
        if (!waiting.key.eql(key) or waiting.step != step) return false;
        // Protocol/view release remain grounded in their actual resource state.
        if (receipt == .released and (step == .close_protocol or step == .release_content)) {
            mapping.acknowledged_step = step;
            mapping.waiting.?.unknown = false;
            self.workspace.cx.requestRedraw();
            return true;
        }
        mapping.waiting = if (receipt == .released) null else .{ .key = key, .step = step, .unknown = receipt == .unknown };
        return self.publishCloseReceipt(mapping, waiting, receipt);
    }

    fn publishCloseReceipt(self: *ApplicationHost, mapping: *Mapping, waiting: Waiting, receipt: CloseReceipt) !bool {
        return self.sessions.closeReceipt(mapping.handle, waiting.key, waiting.step, receipt) catch |err| {
            // A hook for the next step may already have installed a new wait.
            // Otherwise retain this receipt so publication can be retried.
            if (mapping.waiting == null) mapping.waiting = waiting;
            return err;
        };
    }

    fn target(self: *const ApplicationHost) session.AttachmentTarget {
        return .{ .window_id = self.window_id, .workspace_id = self.workspace_id };
    }

    fn windowTargetsReleased(self: *ApplicationHost, targets: []const CloseTarget) bool {
        if (self.domain.attachments.items.len == 1) if (self.domain.backgrounds) |host| {
            const values = host.snapshots(self.allocator) catch return false;
            defer self.allocator.free(values);
            if (values.len != 0) return false;
        };
        for (targets) |target_content| {
            if (self.workspace.model.isCurrentTarget(target_content)) return false;
            switch (target_content.owner) {
                .session => |handle| {
                    const state = self.sessions.queryState(handle) orelse return false;
                    if (state.lifecycle != .closed) return false;
                },
                .history => |owner| {
                    var released = false;
                    for (self.history_closes.items) |close| if (close.tab_id == target_content.tab and close.owner == owner and close.state == .closed) {
                        released = true;
                        break;
                    };
                    if (!released) return false;
                },
                // Workspace retires a frozen group target only after its
                // group controller acknowledges every member close receipt.
                .group => {},
            }
        }
        return true;
    }

    fn submitWindowClose(raw: *anyopaque, command: commands.UiCommand) !OperationKey {
        const self: *ApplicationHost = @ptrCast(@alignCast(raw));
        if (command.payload.number != @backingInt(self.window_id)) return error.WrongWindow;
        const ticket = try self.windows.beginClose(self.window_id);
        errdefer self.windows.cancelClose(ticket) catch {};
        const targets = try self.workspace.beginWindowCloseBatch(ticket);
        errdefer {
            _ = self.workspace.endWindowCloseBatch(ticket.request);
            self.workspace.model.cancelWindowClose(ticket.request) catch {};
        }
        const key = try self.sessions.journal.begin(.app, null);
        self.window_close = .{ .ticket = ticket, .key = key, .targets = targets };
        return key;
    }

    fn bridgeWindowCancelled(raw: ?*anyopaque, request: u64) void {
        const self: *ApplicationHost = @ptrCast(@alignCast(raw orelse return));
        const close = if (self.window_close) |*close| close else return;
        if (close.ticket.request == request and self.windowClosePending()) close.cancel_requested = true;
    }

    pub fn findHandle(self: *ApplicationHost, handle: identity.SessionHandle) ?*Mapping {
        for (self.mappings.items) |*mapping| if (mapping.handle.eql(handle)) return mapping;
        return null;
    }

    fn findLegacy(self: *ApplicationHost, id: LegacySessionId, generation: u64) ?*Mapping {
        for (self.mappings.items) |*mapping| if (mapping.legacy_id == id and mapping.legacy_generation == generation) return mapping;
        return null;
    }

    fn findLegacyId(self: *ApplicationHost, id: LegacySessionId) ?*Mapping {
        for (self.mappings.items) |*mapping| if (mapping.legacy_id == id) return mapping;
        return null;
    }

    fn findTab(self: *ApplicationHost, tab_id: identity.TabId, owner: identity.ContentOwner) ?*Mapping {
        for (self.mappings.items) |*mapping| if (mapping.tab_id == tab_id and mapping.owner.eql(owner)) return mapping;
        return null;
    }

    fn closeHooks(self: *ApplicationHost) session.CloseHooks {
        return .{
            .pause_transfers = .{ .context = self, .run = pauseTransfers },
            .stop_ai = .{ .context = self, .run = stopAi },
            .release_forwards = .{ .context = self, .run = releaseForwards },
            .release_content = .{ .context = self, .run = releaseContent },
        };
    }

    pub fn runCloseStep(self: *ApplicationHost, mapping: *Mapping, key: OperationKey, step: CloseStep, safe: bool) CloseReceipt {
        if (step == .release_content and !safe) {
            mapping.waiting = .{ .key = key, .step = step };
            return .awaiting;
        }
        var receipt: CloseReceipt = .released;
        if (!mapping.content_pending and mapping.acknowledged_step != step) {
            if (self.close_extension) |extension| receipt = extension.run(extension.context, mapping.legacy_id, step);
        }
        if (receipt == .released) switch (step) {
            .close_protocol => {
                if (mapping.process != null) {
                    self.workspace.unbindLocalTerminal(mapping.legacy_id, mapping.handle);
                    const adapter = mapping.process.?.adapter();
                    receipt = if (!mapping.local_started) .released else adapter.vtable.close(adapter.context, mapping.handle, key) catch .unknown;
                } else receipt = switch (self.workspace.protocolReleaseStep(mapping.legacy_id)) {
                    .released => .released,
                    .awaiting => .awaiting,
                    .unknown => .unknown,
                };
            },
            .release_content => {
                mapping.content_pending = true;
                if (self.workspace.sessionTab(mapping.legacy_id)) |tab| {
                    if (tab.generation != mapping.legacy_generation or tab.tab_id != mapping.tab_id or !tab.content_owner.eql(mapping.owner)) {
                        receipt = .unknown;
                    } else {
                        if (safe) self.workspace.receiveCloseReceipt(mapping.tab_id, mapping.owner, true);
                        receipt = .awaiting;
                    }
                }
            },
            else => {},
        };
        if (receipt != .released) mapping.waiting = .{ .key = key, .step = step, .unknown = receipt == .unknown };
        return receipt;
    }

    fn bridgeCreate(context: ?*anyopaque, host: hosts.HostConfig, host_id: workspace_mod.HostId, index: usize, input: []const u8) !void {
        const self: *ApplicationHost = @ptrCast(@alignCast(context orelse return error.MissingApplicationHost));
        _ = try self.create(host, host_id, index, input);
    }

    fn bridgeRecreate(context: ?*anyopaque, id: LegacySessionId) !void {
        const self: *ApplicationHost = @ptrCast(@alignCast(context orelse return error.MissingApplicationHost));
        if (self.workspace.shutting_down or self.windowClosePending()) return error.WorkspaceClosed;
        const mapping = self.findLegacyId(id) orelse return error.StaleSession;
        const manifest = self.sessions.manifestFor(mapping.handle) orelse return error.UnknownPlugin;
        const request_key = try self.dispatcher.issue();
        const value = self.sessions.connectionEnvelope(mapping.handle) orelse return error.ConnectionEnvelopeUnavailable;
        if (manifest.quick_create) |quick| {
            const payload = if (quick.new_session_payload) |prepare| try prepare(self.allocator, value.payload) else try self.allocator.dupe(u8, value.payload);
            defer self.allocator.free(payload);
            _ = try self.sessions.openQuick(manifest.id, payload, .{ .request_key = request_key, .target = self.target() });
            return;
        }
        _ = try self.openEnvelope(value, request_key);
    }

    fn bridgeCreateLocal(context: ?*anyopaque, cwd: ?[]const u8) !void {
        const self: *ApplicationHost = @ptrCast(@alignCast(context orelse return error.MissingApplicationHost));
        _ = try self.createLocal(cwd);
    }
    fn bridgeDuplicateLocal(context: ?*anyopaque, id: LegacySessionId) !void {
        const self: *ApplicationHost = @ptrCast(@alignCast(context orelse return error.MissingApplicationHost));
        _ = try self.duplicateLocal(id);
    }
    fn bridgeRetryLocal(context: ?*anyopaque, id: LegacySessionId) !void {
        const self: *ApplicationHost = @ptrCast(@alignCast(context orelse return error.MissingApplicationHost));
        _ = try self.retryLocal(id);
    }
    fn bridgeRetrySsh(context: ?*anyopaque, id: LegacySessionId) !void {
        const self: *ApplicationHost = @ptrCast(@alignCast(context orelse return error.MissingApplicationHost));
        try self.requestSshReconnect(id);
    }
    fn bridgeConfirm(context: ?*anyopaque, id: LegacySessionId) void {
        const self: *ApplicationHost = @ptrCast(@alignCast(context orelse return));
        if (self.previous_close.confirm) |confirm| confirm(self.previous_close.context, id);
    }

    fn bridgeConnected(context: ?*anyopaque, id: LegacySessionId, generation: u64) void {
        const self: *ApplicationHost = @ptrCast(@alignCast(context orelse return));
        const mapping = self.findLegacy(id, generation) orelse return;
        mapping.connected_received = true;
        self.workspace.cx.requestRedraw();
    }

    fn bridgeFailed(context: ?*anyopaque, id: LegacySessionId, generation: u64, message: []const u8) void {
        const self: *ApplicationHost = @ptrCast(@alignCast(context orelse return));
        const mapping = self.findLegacy(id, generation) orelse return;
        mapping.recordFailure(message);
        self.workspace.cx.requestRedraw();
    }

    fn bridgeCleanup(context: ?*anyopaque, id: LegacySessionId, generation: u64) void {
        const self: *ApplicationHost = @ptrCast(@alignCast(context orelse return));
        const mapping = self.findLegacy(id, generation) orelse return;
        mapping.cleanup_received = true;
        self.workspace.cx.requestRedraw();
    }

    fn bridgeCleanupStatus(context: ?*anyopaque, id: LegacySessionId, generation: u64, receipt: @import("../host/runtime_service.zig").ReleaseReceipt) void {
        const self: *ApplicationHost = @ptrCast(@alignCast(context orelse return));
        const mapping = self.findLegacy(id, generation) orelse return;
        switch (receipt) {
            .released => mapping.cleanup_received = true,
            .unknown => mapping.cleanup_unknown_received = true,
            .awaiting => {},
        }
        self.workspace.cx.requestRedraw();
    }

    fn bridgeRisk(context: ?*anyopaque, id: LegacySessionId) workspace_mod.CloseRisk {
        const self: *ApplicationHost = @ptrCast(@alignCast(context orelse return .{}));
        var result = if (self.previous_close.risk) |risk| risk(self.previous_close.context, id) else workspace_mod.CloseRisk{};
        const mapping = self.localMapping(id) orelse return result;
        var local = mapping.process.?.closeRiskSnapshot(mapping.handle, self.allocator) catch {
            const state = self.sessions.queryState(mapping.handle);
            result.local_unknown = state == null or state.?.create_cleanup != .released;
            return result;
        };
        defer local.deinit(self.allocator);
        result.local_process = local.foreground_state == .task or local.active_exec.len != 0;
        result.local_unknown = local.unknown;
        return result;
    }

    fn bridgeImpact(context: ?*anyopaque, id: LegacySessionId) group_close.Impact {
        const self: *ApplicationHost = @ptrCast(@alignCast(context orelse return .{}));
        var result = if (self.previous_close.impact) |impact| impact(self.previous_close.context, id) else group_close.Impact{};
        const mapping = self.localMapping(id) orelse return result;
        var risk = mapping.process.?.closeRiskSnapshot(mapping.handle, self.allocator) catch {
            result.unknown = 1;
            return result;
        };
        defer risk.deinit(self.allocator);
        var hash = std.hash.Wyhash.init(result.command);
        std.hash.autoHash(&hash, mapping.handle);
        if (risk.foreground) |foreground| {
            std.hash.autoHash(&hash, foreground.pid);
            std.hash.autoHash(&hash, foreground.process_group);
            hash.update(std.mem.sliceTo(&foreground.name, 0));
        }
        for (risk.active_exec) |job| {
            std.hash.autoHash(&hash, job.handle);
            std.hash.autoHash(&hash, job.pid);
            std.hash.autoHash(&hash, job.state);
            hash.update(job.command);
        }
        result.command = hash.final();
        if (risk.unknown) result.unknown = 1;
        var details: [512]u8 = undefined;
        var length: usize = @min(result.detail_len, details.len);
        @memcpy(details[0..length], result.detail[0..length]);
        if (risk.foreground_state == .task) if (risk.foreground) |foreground| {
            const text = std.fmt.bufPrint(details[length..], "{s}进程 {s} (PID {d})", .{ if (length == 0) @as([]const u8, "") else "；", std.mem.sliceTo(&foreground.name, 0), foreground.pid }) catch "";
            length += text.len;
        };
        for (risk.active_exec) |job| {
            const text = std.fmt.bufPrint(details[length..], "{s}执行 {s}", .{ if (length == 0) @as([]const u8, "") else "；", job.command }) catch break;
            length += text.len;
        }
        result.setDetail(details[0..length]);
        return result;
    }

    fn bridgeCloseState(context: ?*anyopaque, id: LegacySessionId) ?group_close.MemberState {
        const self: *ApplicationHost = @ptrCast(@alignCast(context orelse return null));
        const handle = self.ownerForLegacy(id) orelse return null;
        const state = self.sessions.queryState(handle) orelse return null;
        if (state.close_operation == null) return null;
        return switch (state.lifecycle) {
            .closing => .closing,
            .cleanup_unknown => .cleanup_unknown,
            .closed => .closed,
            .failed => .failed,
            else => null,
        };
    }

    fn bridgeClose(context: ?*anyopaque, tab_id: identity.TabId, owner: identity.ContentOwner) workspace_mod.CloseResult {
        const self: *ApplicationHost = @ptrCast(@alignCast(context orelse return .rejected));
        const decision = self.closeForInput(self.dispatcher.issue() catch return .rejected, tab_id, owner) catch return .rejected;
        const key = switch (decision) {
            .accepted => |key| key,
            .rejected => return .rejected,
        };
        self.workspace.cx.requestRedraw();
        if (owner == .history) {
            for (self.history_closes.items) |close| if (close.tab_id == tab_id and close.owner == owner.history and close.key.eql(key)) {
                return switch (close.state) {
                    .pending => .awaiting,
                    .closed => .released,
                    .unknown => .unknown,
                };
            };
            return .rejected;
        }
        const mapping = self.findTab(tab_id, owner) orelse return .rejected;
        const state = self.sessions.queryState(mapping.handle) orelse return .rejected;
        if (state.close_operation == null or !state.close_operation.?.eql(key)) return .rejected;
        return switch (state.lifecycle) {
            .closed => .released,
            .cleanup_unknown => .unknown,
            else => .awaiting,
        };
    }

    fn submitCreate(context: *anyopaque, command: commands.UiCommand) !OperationKey {
        const self: *ApplicationHost = @ptrCast(@alignCast(context));
        const source = self.pending_source orelse return error.MissingCreateSource;
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const envelope = try connection_envelope.fromLegacy(arena.allocator(), source.value.host);
        return (try self.sessions.open(envelope, .{ .request_key = command.command_id, .target = self.target() })).operation;
    }

    fn submitCreateLocal(context: *anyopaque, command: commands.UiCommand) !OperationKey {
        const self: *ApplicationHost = @ptrCast(@alignCast(context));
        return (try self.sessions.openQuickAction("session.local.create", if (command.payload.text.len == 0) null else command.payload.text, .{ .request_key = command.command_id, .target = self.target() })).operation;
    }

    fn submitClose(context: *anyopaque, command: commands.UiCommand) !OperationKey {
        const self: *ApplicationHost = @ptrCast(@alignCast(context));
        if (command.owner == .history) return self.requestHistoryClose(command.payload.tab, command.owner.history);
        const handle = command.owner.session;
        const mapping = self.findHandle(handle) orelse return error.StaleSession;
        if (command.payload.tab != mapping.tab_id) return error.StaleTab;
        return self.requestCloseLegacy(mapping.legacy_id);
    }

    fn requestHistoryClose(self: *ApplicationHost, tab_id: identity.TabId, owner: identity.HistoryId) !OperationKey {
        for (self.history_closes.items) |close| if (close.tab_id == tab_id and close.owner == owner) return close.key;
        const index = self.workspace.tabIndexById(tab_id) orelse return error.StaleTab;
        const tab = self.workspace.tabs.items[index];
        if (!tab.archived or !tab.content_owner.eql(.{ .history = owner })) return error.StaleTab;
        // Read-only history owns a view, not a transport. Its close still uses
        // the same operation journal and waits for the real safe UI removal.
        try self.history_closes.ensureUnusedCapacity(self.allocator, 1);
        const key = try self.sessions.journal.begin(.{ .history = owner }, null);
        self.history_closes.appendAssumeCapacity(.{ .tab_id = tab_id, .owner = owner, .key = key });
        return key;
    }

    fn pauseTransfers(context: *anyopaque, handle: identity.SessionHandle, key: OperationKey) !CloseReceipt {
        return closeStep(context, handle, key, .pause_transfers);
    }
    fn stopAi(context: *anyopaque, handle: identity.SessionHandle, key: OperationKey) !CloseReceipt {
        return closeStep(context, handle, key, .stop_ai);
    }
    fn releaseForwards(context: *anyopaque, handle: identity.SessionHandle, key: OperationKey) !CloseReceipt {
        return closeStep(context, handle, key, .release_forwards);
    }
    fn releaseContent(context: *anyopaque, handle: identity.SessionHandle, key: OperationKey) !CloseReceipt {
        return closeStep(context, handle, key, .release_content);
    }
    fn closeStep(context: *anyopaque, handle: identity.SessionHandle, key: OperationKey, step: CloseStep) CloseReceipt {
        const self: *ApplicationHost = @ptrCast(@alignCast(context));
        if (self.domain.backgrounds) |host| if (host.owns(handle)) return host.closeStep(handle, key, step);
        const mapping = self.findHandle(handle) orelse return .unknown;
        const receipt = self.runCloseStep(mapping, key, step, false);
        if (receipt == .awaiting) self.workspace.cx.scheduleRedrawAfterNs(33 * std.time.ns_per_ms);
        return receipt;
    }

    fn backgroundPendingAuth(raw: *anyopaque) ?background.auth.Snapshot {
        const self: *ApplicationHost = @ptrCast(@alignCast(raw));
        if (self.domain.backgrounds) |host| if (host.pendingAuthentication()) |value| {
            const original = if (value.identity.key.owner == .session) self.domain.ownerForHandle(value.identity.key.owner.session) else null;
            const recipient = original orelse if (self.domain.attachments.items.len != 0) self.domain.attachments.items[0] else null;
            if (recipient == self) return value;
        };
        return if (self.background_previous_auth) |previous| previous.pending(previous.context) else null;
    }
    fn backgroundSubmitAuth(raw: *anyopaque, request: background.auth.RequestIdentity, reply: background.auth.Reply) !void {
        const self: *ApplicationHost = @ptrCast(@alignCast(raw));
        if (self.domain.backgrounds) |host| if (host.authenticationHostFor(request) != null) return host.submitAuthentication(request, reply);
        if (self.background_previous_auth) |previous| return previous.submit(previous.context, request, reply);
        return error.StaleAuthentication;
    }
    fn backgroundCancelAuth(raw: *anyopaque, request: background.auth.RequestIdentity) bool {
        const self: *ApplicationHost = @ptrCast(@alignCast(raw));
        if (self.domain.backgrounds) |host| if (host.cancelAuthentication(request)) return true;
        return if (self.background_previous_auth) |previous| previous.cancel(previous.context, request) else false;
    }
    fn backgroundAuthHost(raw: *anyopaque, request: background.auth.RequestIdentity) ?hosts.HostConfig {
        const self: *ApplicationHost = @ptrCast(@alignCast(raw));
        if (self.domain.backgrounds) |host| if (host.authenticationHostFor(request)) |value| return value;
        return if (self.background_previous_auth) |previous| previous.host(previous.context, request) else null;
    }
    fn backgroundAuthParent(raw: *anyopaque, request: background.auth.RequestIdentity) ?*ui.Node {
        const self: *ApplicationHost = @ptrCast(@alignCast(raw));
        if (self.domain.backgrounds) |host| if (host.authenticationHostFor(request) != null) return self.workspace.terminal_area;
        return if (self.background_previous_auth) |previous| previous.parent(previous.context, request) else null;
    }
    fn backgroundAuthHostKey(raw: *anyopaque, request: background.auth.RequestIdentity) ?background.host_key.Request {
        const self: *ApplicationHost = @ptrCast(@alignCast(raw));
        if (self.domain.backgrounds) |host| if (host.authenticationHostKey(request)) |value| return value;
        return if (self.background_previous_auth) |previous| previous.host_key(previous.context, request) else null;
    }
    fn backgroundAuthTotp(raw: *anyopaque, request: background.auth.RequestIdentity, now: @import("../proto/ssh/totp_prefill.zig").Time) !?@import("../proto/ssh/totp_prefill.zig").Suggestion {
        const self: *ApplicationHost = @ptrCast(@alignCast(raw));
        if (self.domain.backgrounds) |host| if (host.authenticationHostFor(request) != null) return host.authenticationTotp(request, now);
        if (self.background_previous_auth) |previous| if (previous.totp) |suggest| return suggest(previous.context, request, now);
        return null;
    }
};

const sshServices = @import("../plugins/linked_plugins.zig").sshServices;

test "TOTP autofill application source spec freezes saved and temporary hop seeds" {
    var target_seed = "MZXW6".*;
    var hop_seed = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ".*;
    var global: config.Config = .{};
    global.ssh.totp_autofill = true;
    const hop: hosts.HostConfig = .{ .connection_id = @fromBackingInt(42), .revision = 8, .name = "same", .host = "bridge", .user = "jump", .totp_secret = &hop_seed };
    var host: hosts.HostConfig = .{ .connection_id = @fromBackingInt(43), .revision = 9, .name = "same", .host = "target", .user = "root", .route = &.{hop.connection_id}, .totp_secret = &target_seed };
    var saved = try freezeSource(std.testing.allocator, host, global, &.{hop}, 7, 0, "");
    defer saved.deinit();
    host.connection_id = @fromBackingInt(0);
    var temporary = try freezeSource(std.testing.allocator, host, global, &.{hop}, 8, workspace_mod.removed_host_index, "");
    defer temporary.deinit();
    @memset(&target_seed, 'A');
    @memset(&hop_seed, 'A');
    global.ssh.totp_autofill = false;
    var saved_hops: [8]session.RouteHop = undefined;
    var temporary_hops: [8]session.RouteHop = undefined;
    const saved_spec = sourceSpec(saved.value, &saved_hops, "");
    const temporary_spec = sourceSpec(temporary.value, &temporary_hops, "");
    try std.testing.expectEqualStrings("MZXW6", saved_spec.saved.immutable_config.totp_secret.?);
    try std.testing.expectEqualStrings("MZXW6", temporary_spec.temporary_ssh.totp_secret.?);
    try std.testing.expectEqualStrings("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", saved_spec.saved.route_snapshot[0].totp_secret.?);
    try std.testing.expectEqualStrings("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", temporary_spec.temporary_ssh.route_snapshot[0].totp_secret.?);
    try std.testing.expect(saved.value.global_config.ssh.totp_autofill);
    try std.testing.expect(temporary.value.global_config.ssh.totp_autofill);
}

test "application source freezes host global policy route and initial input" {
    var address = [_]u8{ 'n', 'o', 'd', 'e' };
    var input = [_]u8{ 'p', 'w', 'd', '\r' };
    var global: config.Config = .{};
    global.config_revision = 900;
    global.ssh.keepalive_sec = 47;
    var key_path = "/test/key".*;
    var hop_name = "same".*;
    var route_ids = [_]identity.ConnectionId{ @fromBackingInt(42), @fromBackingInt(43) };
    var host: hosts.HostConfig = .{ .connection_id = @fromBackingInt(123), .revision = 27, .name = "target", .host = &address, .user = "test", .route = &route_ids, .auth_mode = .password, .password = "test-only", .strict_host_key_checking = false };
    var registry = [_]hosts.HostConfig{
        .{ .connection_id = @fromBackingInt(43), .revision = 8, .name = &hop_name, .host = "bridge-b", .user = "jump-b", .strict_host_key_checking = false },
        .{ .connection_id = @fromBackingInt(42), .revision = 5, .name = &hop_name, .host = "bridge-a", .user = "jump-a", .auth_mode = .private_key, .identity_file = &key_path },
    };
    var frozen = try freezeSource(std.testing.allocator, host, global, &registry, 7, 2, &input);
    defer frozen.deinit();
    address[0] = 'x';
    input[0] = 'x';
    key_path[0] = 'x';
    hop_name[0] = 'x';
    route_ids[0] = @fromBackingInt(43);
    registry[1].revision = 99;
    registry[1].strict_host_key_checking = false;
    host.protocol = .sftp;
    host.revision = 28;
    global.ssh.keepalive_sec = 3;
    var route: [8]session.RouteHop = undefined;
    const spec = sourceSpec(frozen.value, &route, "private");
    try spec.validate();
    try std.testing.expectEqual(@as(identity.ConnectionId, @fromBackingInt(123)), spec.saved.connection_id);
    try std.testing.expectEqual(@as(u64, 27), spec.saved.config_revision);
    try std.testing.expectEqual(session.RemoteProtocol.ssh, spec.saved.protocol);
    try std.testing.expectEqualStrings("node", spec.saved.immutable_config.endpoint.host);
    try std.testing.expectEqual(@as(u16, 47), spec.saved.immutable_config.keepalive_sec);
    try std.testing.expect(!spec.saved.immutable_config.strict_host_key_checking);
    try std.testing.expectEqualStrings("pwd\r", frozen.value.initial_input);
    try std.testing.expectEqual(@as(usize, 2), spec.saved.route_snapshot.len);
    try std.testing.expectEqualDeep(identity.AssetOwner{ .id = @fromBackingInt(42), .revision = 5 }, spec.saved.route_snapshot[0].owner.?);
    try std.testing.expectEqualStrings("same", spec.saved.route_snapshot[0].display_name);
    try std.testing.expectEqualStrings("bridge-a", spec.saved.route_snapshot[0].endpoint.host);
    try std.testing.expectEqualStrings("/test/key", spec.saved.route_snapshot[0].auth.private_key.path);
    try std.testing.expect(spec.saved.route_snapshot[0].strict_host_key_checking);
    try std.testing.expectEqual(session.RemoteProtocol.ssh, spec.saved.route_snapshot[0].protocol);
    try std.testing.expectEqualDeep(identity.AssetOwner{ .id = @fromBackingInt(43), .revision = 8 }, spec.saved.route_snapshot[1].owner.?);
    try std.testing.expectEqualStrings("bridge-b", spec.saved.route_snapshot[1].endpoint.host);
    try std.testing.expect(spec.saved.route_snapshot[1].auth == .agent);
    try std.testing.expect(!spec.saved.route_snapshot[1].strict_host_key_checking);
    try std.testing.expectEqualStrings("test-only", spec.saved.immutable_config.auth.password);
}

test "temporary factory has no invented saved identity and missing route rejects early" {
    const host: hosts.HostConfig = .{ .name = "temporary", .host = "test", .user = "test" };
    // A process-local HostId never promotes a temporary endpoint to an asset.
    var frozen = try freezeSource(std.testing.allocator, host, .{}, &.{}, 77, workspace_mod.removed_host_index, "");
    defer frozen.deinit();
    var route: [8]session.RouteHop = undefined;
    const spec = sourceSpec(frozen.value, &route, "");
    try std.testing.expect(spec == .temporary_ssh);
    try spec.validate();
    var routed = host;
    routed.route = &.{@fromBackingInt(9)};
    try std.testing.expectError(error.MissingRouteReference, freezeSource(std.testing.allocator, routed, .{}, &.{}, 0, 0, ""));
    routed.route = &.{};
    routed.jump_chain = &.{"legacy-name"};
    try std.testing.expectError(error.UnmigratedRoute, freezeSource(std.testing.allocator, routed, .{}, &.{.{ .name = "legacy-name", .host = "hop", .user = "test" }}, 0, 0, ""));
    try std.testing.expect(sshServices().has(.terminal));
    try std.testing.expect(!sshServices().has(.directory));
}

test "application source preserves SFTP protocol and explicit auth mode" {
    var host: hosts.HostConfig = .{ .connection_id = @fromBackingInt(52), .revision = 6, .protocol = .sftp, .name = "files", .host = "files.test", .user = "test", .password = "unused-agent-field" };
    var frozen = try freezeSource(std.testing.allocator, host, .{}, &.{}, 0, 0, "");
    defer frozen.deinit();
    var route: [8]session.RouteHop = undefined;
    const spec = sourceSpec(frozen.value, &route, "");
    try std.testing.expectEqual(session.RemoteProtocol.sftp, spec.saved.protocol);
    try std.testing.expect(spec.saved.immutable_config.auth == .agent);
    host.auth_mode = .password;
    host.password = null;
    try std.testing.expect(auth(host) == .password_prompt);
    host.connection_id = @fromBackingInt(0);
    try std.testing.expectError(error.InvalidTemporaryProtocol, freezeSource(std.testing.allocator, host, .{}, &.{}, 1, 0, ""));
}

test "application source rejects invalid numeric routes before a factory can start IO" {
    var host: hosts.HostConfig = .{ .connection_id = @fromBackingInt(10), .revision = 2, .name = "target", .host = "target.test", .user = "test", .route = &.{@fromBackingInt(20)} };
    var hop: hosts.HostConfig = .{ .connection_id = @fromBackingInt(20), .revision = 3, .name = "hop", .host = "hop.test", .user = "jump" };
    try std.testing.expectError(error.MissingRouteReference, freezeSource(std.testing.allocator, host, .{}, &.{}, 1, 0, ""));
    try std.testing.expectError(error.DuplicateConnectionId, freezeSource(std.testing.allocator, host, .{}, &.{ hop, hop }, 1, 0, ""));
    host.route = &.{@fromBackingInt(0)};
    try std.testing.expectError(error.InvalidIdentity, freezeSource(std.testing.allocator, host, .{}, &.{hop}, 1, 0, ""));
    host.route = &.{@fromBackingInt(10)};
    try std.testing.expectError(error.RouteCycle, freezeSource(std.testing.allocator, host, .{}, &.{host}, 1, 0, ""));
    host.route = &.{ @fromBackingInt(20), @fromBackingInt(20) };
    try std.testing.expectError(error.DuplicateRoute, freezeSource(std.testing.allocator, host, .{}, &.{hop}, 1, 0, ""));
    host.route = &.{ @fromBackingInt(20), @fromBackingInt(21), @fromBackingInt(22), @fromBackingInt(23), @fromBackingInt(24), @fromBackingInt(25), @fromBackingInt(26), @fromBackingInt(27), @fromBackingInt(28) };
    try std.testing.expectError(error.TooManyJumps, freezeSource(std.testing.allocator, host, .{}, &.{hop}, 1, 0, ""));
    host.route = &.{@fromBackingInt(20)};
    hop.route = &.{@fromBackingInt(21)};
    try std.testing.expectError(error.NestedRouteUnsupported, freezeSource(std.testing.allocator, host, .{}, &.{hop}, 1, 0, ""));
    hop.route = &.{};
    hop.jump_chain = &.{"legacy-nested"};
    try std.testing.expectError(error.NestedRouteUnsupported, freezeSource(std.testing.allocator, host, .{}, &.{hop}, 1, 0, ""));
    hop.jump_chain = &.{};
    hop.protocol = .sftp;
    try std.testing.expectError(error.InvalidRouteProtocol, freezeSource(std.testing.allocator, host, .{}, &.{hop}, 1, 0, ""));
}

test "application host adapter and callback signatures compile" {
    std.testing.refAllDecls(ApplicationHost);
}

test "background application entry keeps Tabs and connect jobs empty through actual queued cancellation" {
    const a = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "hosts.toml", .data = "" });
    const path = try temporary.dir.realPathFileAlloc(std.testing.io, "hosts.toml", a);
    defer a.free(path);
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(directory);
    const known = try std.fs.path.join(a, &.{ directory, "known_hosts" });
    defer a.free(known);
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.setViewport(1100, 720);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    var nodes: [4]*ui.Node = undefined;
    for (&nodes) |*node| {
        node.* = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
        try cx.root.?.appendChild(a, node.*);
    }
    var saved: config.Config = .{};
    saved.ssh.auto_reconnect = false;
    const workspace = try workspace_mod.Workspace.init(a, cx, scope, std.testing.io, &saved, path, nodes[0], nodes[1], nodes[2], nodes[3]);
    const index = try workspace.appendHost(.{ .connection_id = @fromBackingInt(73), .revision = 5, .name = "background-original", .host = "127.0.0.1", .port = 1, .user = "owned-loopback", .auth_mode = .password, .password = "unused", .strict_host_key_checking = false });
    const app = try ApplicationHost.init(a, workspace);
    // The isolated trust path is installed before the real create; the tested
    // adapter still queues its actual SourceFactory/worker and close receipts.
    app.domain.backgrounds = try background.Host.init(a, app.sessions, known, .{ .automatic_reconnect = false });
    defer app.deinit();
    app.install();
    const accepted = try app.createBackgroundSaved(workspace.hostId(index).?);
    try std.testing.expectEqual(@as(usize, 0), workspace.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 0), workspace.model.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 0), workspace.connect_jobs.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.mappings.items.len);
    try std.testing.expectEqual(session.SessionPurpose.socks_background, app.sessions.queryState(accepted.handle).?.purpose);
    try std.testing.expect(app.sessions.queryService(accepted.handle, .terminal) == .unsupported);
    const close_key = try app.stopBackgroundOwner(accepted.handle);
    const deadline = @import("../platform/realtime.zig").monotonicNs() + 3 * std.time.ns_per_s;
    while (app.sessions.queryState(accepted.handle).?.lifecycle != .closed) {
        if (@import("../platform/realtime.zig").monotonicNs() > deadline) return error.BackgroundCancellationNotReleased;
        _ = try app.safeTick();
        var empty: [1]std.c.pollfd = undefined;
        _ = std.c.poll(&empty, 0, 2);
    }
    try std.testing.expect(app.sessions.queryState(accepted.handle).?.close_operation.?.eql(close_key));
    const remaining = try app.backgroundSnapshots(a);
    defer a.free(remaining);
    try std.testing.expectEqual(@as(usize, 0), remaining.len);
    try std.testing.expectEqual(@as(usize, 0), workspace.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 0), workspace.connect_jobs.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.mappings.items.len);
}

test "application installs real SSH and Local availability and restores prior bridges" {
    var workspace: workspace_mod.Workspace = undefined;
    workspace.model = .{ .allocator = std.testing.allocator, .window = @fromBackingInt(0), .workspace = @fromBackingInt(0) };
    defer workspace.model.deinit();
    workspace.session_bridge = .{};
    workspace.close_bridge = .{};
    workspace.window_close_bridge = .{};
    const app = try ApplicationHost.init(std.testing.allocator, &workspace);
    defer app.deinit();
    try std.testing.expectEqual(app.window_id, workspace.model.window);
    try std.testing.expectEqual(app.workspace_id, workspace.model.workspace);
    try std.testing.expectEqual(plugins.Availability.available, app.registry().availability(.ssh));
    try std.testing.expectEqual(plugins.Availability.available, app.registry().availability(.local));
    try std.testing.expectEqual(plugins.Availability.adapter_not_connected, app.registry().availability(.sftp));
    app.install();
    try std.testing.expect(workspace.session_bridge.create != null);
    try std.testing.expect(workspace.session_bridge.create_local != null);
    try std.testing.expect(workspace.close_bridge.request_close != null);
    try std.testing.expect(workspace.close_bridge.cleanup == null);
    app.uninstall();
    try std.testing.expect(workspace.session_bridge.create == null);
    try std.testing.expect(workspace.session_bridge.create_local == null);
    try std.testing.expect(workspace.close_bridge.request_close == null);
}

test "application file plugin queues frozen source without constructing terminal and retains unknown shutdown" {
    // Controller-only provider fixture: it intentionally never reports ready
    // and is not registered by the production main application.
    const Provider = struct {
        queued: ?session.CreateRequest = null,
        ticks: usize = 0,
        release: CloseReceipt = .unknown,
        cancel_receipt: CloseReceipt = .unknown,
        fn create(raw: *anyopaque, request: session.CreateRequest) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.queued = request;
        }
        fn cancel(raw: *anyopaque, _: OperationKey) CloseReceipt {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.cancel_receipt;
        }
        fn close(_: *anyopaque, _: identity.SessionHandle, _: OperationKey) !CloseReceipt {
            return .released;
        }
        fn stale(_: *anyopaque, _: identity.SessionHandle, _: OperationKey) void {}
        fn tick(raw: *anyopaque, _: *session.SessionHost) !bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.ticks += 1;
            return false;
        }
        fn shutdown(raw: *anyopaque) CloseReceipt {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.release;
        }
        fn plugin(self: *@This()) FilePlugin {
            return .{ .adapter = .{ .registration = .{ .plugin_id = .sftp, .workspace_kind = .file, .services = plugins.requiredServices(.sftp) }, .context = self, .vtable = &.{ .create = create, .cancel = cancel, .close = close, .release_stale = stale } }, .context = self, .tick = tick, .shutdown = shutdown };
        }
    };
    var workspace: workspace_mod.Workspace = undefined;
    workspace.model = .{ .allocator = std.testing.allocator, .window = @fromBackingInt(0), .workspace = @fromBackingInt(0) };
    defer workspace.model.deinit();
    workspace.session_bridge = .{};
    workspace.close_bridge = .{};
    workspace.window_close_bridge = .{};
    workspace.shutting_down = false;
    var global: config.Config = .{};
    workspace.app_config = &global;
    workspace.registry.hosts = &.{};
    var provider: Provider = .{};
    const app = try ApplicationHost.initWithFilePlugin(std.testing.allocator, &workspace, provider.plugin());
    defer {
        provider.release = .released;
        app.deinit();
    }
    var name = "Original Files".*;
    var address = "files.test".*;
    const accepted = try app.create(.{ .connection_id = @fromBackingInt(19), .revision = 7, .protocol = .sftp, .name = &name, .host = &address, .user = "operator" }, 91, 4, "");
    try std.testing.expect(provider.queued.?.handle.eql(accepted.handle));
    try std.testing.expectEqual(session.Lifecycle.creating, app.sessions.queryState(accepted.handle).?.lifecycle);
    try std.testing.expect(app.sessions.queryService(accepted.handle, .transfer) == .temporarily_unavailable);
    name[0] = 'X';
    address[0] = 'X';
    const source = try app.fileSource(accepted.handle, accepted.operation);
    try std.testing.expectEqualStrings("Original Files", source.host.name);
    try std.testing.expectEqualStrings("files.test", source.host.host);
    try std.testing.expectEqual(@as(workspace_mod.HostId, 91), source.host_id);
    try std.testing.expectEqual(@as(usize, 4), source.source_index);
    try std.testing.expectEqual(@as(usize, 0), app.mappings.items.len);
    try std.testing.expect(!app.fileCreatesReleased());
    var foreign = accepted.operation;
    foreign.owner.session.generation += 1;
    try std.testing.expectError(error.StaleFileCreate, app.fileSource(accepted.handle, foreign));
    // Shutdown unknown must retain the owner and immutable snapshots.
    app.deinit();
    try std.testing.expectEqualStrings("files.test", (try app.fileSource(accepted.handle, accepted.operation)).host.host);
    try std.testing.expect(try app.sessions.cancel(accepted.operation));
    try std.testing.expect(!app.fileCreatesReleased());
    provider.cancel_receipt = .released;
    try std.testing.expect(try app.sessions.createCleanupReceipt(accepted.handle, accepted.operation, .released));
    try std.testing.expect(app.fileCreatesReleased());
}

const ReceiptTestAdapter = struct {
    fn create(_: *anyopaque, _: session.CreateRequest) !void {}
    fn cancel(_: *anyopaque, _: OperationKey) CloseReceipt {
        return .released;
    }
    fn close(_: *anyopaque, _: identity.SessionHandle, _: OperationKey) !CloseReceipt {
        return .released;
    }
    fn stale(_: *anyopaque, _: identity.SessionHandle, _: OperationKey) void {}
    fn holdContent(_: *anyopaque, _: identity.SessionHandle, _: OperationKey) !CloseReceipt {
        return .awaiting;
    }
};

test "cancelled SSH late ready never attaches and unknown cleanup retains retry gate" {
    const Pending = struct {
        fn cancel(_: *anyopaque, _: OperationKey) CloseReceipt {
            return .awaiting;
        }
    };
    var context: u8 = 0;
    const adapter: session.Adapter = .{ .registration = .{ .plugin_id = .ssh, .workspace_kind = .terminal, .services = sshServices() }, .context = &context, .vtable = &.{ .create = ReceiptTestAdapter.create, .cancel = Pending.cancel, .close = ReceiptTestAdapter.close, .release_stale = ReceiptTestAdapter.stale } };
    const saved: config.Config = .{};
    var workspace: workspace_mod.Workspace = undefined;
    workspace.app_config = &saved;
    workspace.model = .{ .allocator = std.testing.allocator, .window = @fromBackingInt(0), .workspace = @fromBackingInt(0) };
    defer workspace.model.deinit();
    workspace.tabs = .empty;
    const app = try ApplicationHost.init(std.testing.allocator, &workspace);
    defer app.deinit();
    const receipt_domain = try session.SessionHost.init(std.testing.allocator, &.{adapter});
    app.sessions.deinit();
    app.sessions.* = receipt_domain;
    const accepted = try app.sessions.create(.{ .temporary_ssh = .{ .structured_endpoint = .{ .host = "test.invalid", .user = "test" } } }, .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) });
    try std.testing.expect(try app.sessions.cancel(accepted.operation));
    app.history_closes = .empty;
    app.window_close = null;
    try app.mappings.append(app.allocator, .{ .handle = accepted.handle, .create_operation = accepted.operation, .legacy_id = 31, .legacy_generation = 1, .tab_id = @fromBackingInt(7), .owner = .{ .session = accepted.handle }, .source = null, .connected_received = true, .cleanup_unknown_received = true });
    const mappings = app.mappings.items;
    try std.testing.expect(!try app.safeTick());
    try std.testing.expect(!mappings[0].ready_published);
    try std.testing.expect(!mappings[0].attached_published);
    try std.testing.expectEqual(@import("../host/operation.zig").Cleanup.unknown, app.sessions.queryState(accepted.handle).?.create_cleanup);
    try std.testing.expectError(error.CleanupNotReleased, app.sessions.retry(accepted.handle));
    mappings[0].cleanup_received = true;
    try std.testing.expect(!try app.safeTick());
    const retry = try app.sessions.retry(accepted.handle);
    try std.testing.expectEqual(accepted.handle.session_id, retry.handle.session_id);
    try std.testing.expect(!accepted.handle.eql(retry.handle));
}

test "application close keeps its receipt when completion publication runs out of memory" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var context: u8 = 0;
    const adapter: session.Adapter = .{ .registration = .{ .plugin_id = .ssh, .workspace_kind = .terminal, .services = sshServices() }, .context = &context, .vtable = &.{ .create = ReceiptTestAdapter.create, .cancel = ReceiptTestAdapter.cancel, .close = ReceiptTestAdapter.close, .release_stale = ReceiptTestAdapter.stale } };
    const saved: config.Config = .{};
    var workspace: workspace_mod.Workspace = undefined;
    workspace.app_config = &saved;
    workspace.model = .{ .allocator = std.testing.allocator, .window = @fromBackingInt(0), .workspace = @fromBackingInt(0) };
    defer workspace.model.deinit();
    workspace.tabs = .empty;
    const app = try ApplicationHost.init(std.testing.allocator, &workspace);
    defer app.deinit();
    const receipt_domain = try session.SessionHost.init(failing.allocator(), &.{adapter});
    app.sessions.deinit();
    app.sessions.* = receipt_domain;
    const accepted = try app.sessions.create(.{ .temporary_ssh = .{ .structured_endpoint = .{ .host = "test", .user = "test" } } }, .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) });
    const key = try app.sessions.requestClose(accepted.handle, .{ .release_content = .{ .context = &context, .run = ReceiptTestAdapter.holdContent } });
    app.close_extension = null;
    app.history_closes = .empty;
    app.window_close = null;
    try app.mappings.append(app.allocator, .{ .handle = accepted.handle, .create_operation = accepted.operation, .legacy_id = 31, .legacy_generation = 1, .tab_id = @fromBackingInt(7), .owner = .{ .session = accepted.handle }, .source = null, .waiting = .{ .key = key, .step = .release_content }, .content_pending = true });
    const mappings = app.mappings.items;
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, app.safeTick());
    try std.testing.expect(mappings[0].waiting != null);
    try std.testing.expect(mappings[0].waiting.?.key.eql(key));
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expect(!try app.safeTick());
    try std.testing.expectEqual(session.Lifecycle.closed, app.sessions.queryState(accepted.handle).?.lifecycle);
    try std.testing.expect(mappings[0].waiting == null);
    try std.testing.expect(app.findLegacy(31, 2) == null);
    try std.testing.expect(app.legacyForHandle(try accepted.handle.nextGeneration()) == null);
}

test "read-only history close shares dispatcher and journal without a transport session" {
    const saved: config.Config = .{};
    var workspace: workspace_mod.Workspace = undefined;
    workspace.app_config = &saved;
    workspace.model = .{ .allocator = std.testing.allocator, .window = @fromBackingInt(0), .workspace = @fromBackingInt(0) };
    defer workspace.model.deinit();
    workspace.session_bridge = .{};
    workspace.close_bridge = .{};
    const app = try ApplicationHost.init(std.testing.allocator, &workspace);
    defer app.deinit();
    const tab_id: identity.TabId = @fromBackingInt(9);
    const owner: identity.ContentOwner = .{ .history = @fromBackingInt(3) };
    try workspace.model.append(tab_id, owner, "record");
    var tab: workspace_mod.SessionTab = undefined;
    tab.id = 50;
    tab.tab_id = tab_id;
    tab.content_owner = owner;
    tab.archived = true;
    var tabs = [_]*workspace_mod.SessionTab{&tab};
    workspace.tabs = .empty;
    workspace.tabs.items = &tabs;
    workspace.tabs.capacity = tabs.len;
    const input = try app.dispatcher.issue();
    const first = (try app.closeForInput(input, tab_id, owner)).accepted;
    const repeated = (try app.closeForInput(input, tab_id, owner)).accepted;
    try std.testing.expect(first.eql(repeated));
    try std.testing.expectEqual(owner.history, first.owner.history);
    try std.testing.expectEqual(@as(usize, 1), app.history_closes.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.sessions.sessions.items.len);
    // The controller acknowledges only after the workspace no longer exposes
    // the view; actual node destruction remains the workspace safe hook's job.
    workspace.tabs = .empty;
    try workspace.model.completeClose(tab_id, owner);
    try std.testing.expect(!try app.safeTick());
    try std.testing.expect(app.history_closes.items[0].state == .closed);
    var completed: usize = 0;
    var released: usize = 0;
    while (app.sessions.journal.take()) |received| {
        var event = received;
        defer event.deinit();
        try std.testing.expect(event.value.key.eql(first));
        if (event.value.kind == .completed) completed += 1;
        if (event.value.kind == .cleanup_released) released += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), completed);
    try std.testing.expectEqual(@as(usize, 1), released);
}

test "release content defers even its extension until the safe hook" {
    const Extension = struct {
        calls: usize = 0,
        fn run(raw: *anyopaque, _: LegacySessionId, _: CloseStep) CloseReceipt {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return .released;
        }
    };
    var extension: Extension = .{};
    var workspace: workspace_mod.Workspace = undefined;
    workspace.tabs = .empty;
    var app: ApplicationHost = undefined;
    app.file_plugin = null;
    app.file_sources = .empty;
    app.workspace = &workspace;
    app.close_extension = .{ .context = &extension, .run = Extension.run };
    const handle: identity.SessionHandle = .{ .session_id = @fromBackingInt(4) };
    const key: OperationKey = .{ .owner = .{ .session = handle }, .operation_id = 8 };
    var mapping: Mapping = .{ .handle = handle, .create_operation = key, .legacy_id = 20, .legacy_generation = 1, .tab_id = @fromBackingInt(2), .owner = .{ .session = handle }, .source = null };
    try std.testing.expectEqual(CloseReceipt.awaiting, app.runCloseStep(&mapping, key, .release_content, false));
    try std.testing.expectEqual(@as(usize, 0), extension.calls);
    try std.testing.expect(!mapping.content_pending);
    try std.testing.expectEqual(CloseReceipt.released, app.runCloseStep(&mapping, key, .release_content, true));
    try std.testing.expectEqual(@as(usize, 1), extension.calls);
}

test "shared application domain routes independent window sessions and preserves sibling on close" {
    const Provider = struct {
        queued: ?session.CreateRequest = null,
        closes: usize = 0,
        fn create(raw: *anyopaque, request: session.CreateRequest) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.queued = request;
        }
        fn cancel(_: *anyopaque, _: OperationKey) CloseReceipt {
            return .released;
        }
        fn close(raw: *anyopaque, _: identity.SessionHandle, _: OperationKey) !CloseReceipt {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.closes += 1;
            return .released;
        }
        fn stale(_: *anyopaque, _: identity.SessionHandle, _: OperationKey) void {}
        fn tick(_: *anyopaque, _: *session.SessionHost) !bool {
            return false;
        }
        fn shutdown(_: *anyopaque) CloseReceipt {
            return .released;
        }
        fn plugin(self: *@This()) FilePlugin {
            return .{ .adapter = .{ .registration = .{ .plugin_id = .sftp, .workspace_kind = .file, .services = plugins.requiredServices(.sftp) }, .context = self, .vtable = &.{ .create = create, .cancel = cancel, .close = close, .release_stale = stale } }, .context = self, .tick = tick, .shutdown = shutdown };
        }
    };
    const a = std.testing.allocator;
    const saved: config.Config = .{};
    var first_workspace: workspace_mod.Workspace = undefined;
    first_workspace.app_config = &saved;
    first_workspace.model = .{ .allocator = a, .window = @fromBackingInt(0), .workspace = @fromBackingInt(0) };
    defer first_workspace.model.deinit();
    first_workspace.shutting_down = false;
    first_workspace.tabs = .empty;
    var second_workspace: workspace_mod.Workspace = undefined;
    second_workspace.app_config = &saved;
    second_workspace.model = .{ .allocator = a, .window = @fromBackingInt(0), .workspace = @fromBackingInt(0) };
    defer second_workspace.model.deinit();
    second_workspace.shutting_down = false;
    second_workspace.tabs = .empty;
    var first_provider: Provider = .{};
    var second_provider: Provider = .{};
    const domain = try Domain.init(a, true);
    defer domain.deinit();
    const first = try ApplicationHost.initInDomain(domain, &first_workspace, first_provider.plugin());
    var first_live = true;
    defer if (first_live) first.deinit();
    const second = try ApplicationHost.initInDomain(domain, &second_workspace, second_provider.plugin());
    defer second.deinit();
    try std.testing.expect(first.sessions == second.sessions);
    try std.testing.expect(first.local_adapter == second.local_adapter);
    try std.testing.expect(first.dispatcher == second.dispatcher);
    try std.testing.expect(first.windows == second.windows);
    try std.testing.expect(first.window_id != second.window_id);
    try std.testing.expect(first.workspace_id != second.workspace_id);
    const host: hosts.HostConfig = .{ .name = "original target", .host = "test.invalid", .user = "tester", .protocol = .sftp, .connection_id = @fromBackingInt(17), .revision = 1 };
    var frozen = try WindowConnection.init(a, host, saved, &.{}, 17, 0);
    defer frozen.deinit();
    const one = try first.createWindowConnection(&frozen);
    const two = try second.createWindowConnection(&frozen);
    try std.testing.expect(!one.handle.eql(two.handle));
    try std.testing.expectEqual(first.window_id, first_provider.queued.?.target.window_id);
    try std.testing.expectEqual(second.window_id, second_provider.queued.?.target.window_id);
    try std.testing.expectEqual(first, domain.ownerForHandle(one.handle).?);
    try std.testing.expectEqual(second, domain.ownerForHandle(two.handle).?);
    _ = try domain.sessions.ready(one.handle, one.operation, plugins.requiredServices(.sftp));
    _ = try domain.sessions.ready(two.handle, two.operation, plugins.requiredServices(.sftp));
    _ = try domain.sessions.attached(one.handle, .{ .target = first.target(), .tab_id = @fromBackingInt(1) });
    _ = try domain.sessions.attached(two.handle, .{ .target = second.target(), .tab_id = @fromBackingInt(1) });
    // Looking through another window uses the same live binding and owner.
    const binding = first.sessions.queryService(two.handle, .directory).available;
    try std.testing.expect(second.sessions.bindingIsLive(binding));
    try std.testing.expect(binding.origin_session.?.eql(two.handle));
    const closed_window = first.window_id;
    _ = try first.sessions.requestClose(one.handle, .{});
    try std.testing.expectEqual(session.Lifecycle.closed, second.sessions.queryState(one.handle).?.lifecycle);
    try std.testing.expectEqual(@as(usize, 1), first_provider.closes);
    try std.testing.expectEqual(@as(usize, 0), second_provider.closes);
    first.deinit();
    first_live = false;
    try std.testing.expect(domain.windows.find(closed_window) == null);
    try std.testing.expect(domain.windows.find(second.window_id) != null);
    try std.testing.expectEqual(session.Lifecycle.attached, second.sessions.queryState(two.handle).?.lifecycle);
    try std.testing.expect(second.sessions.bindingIsLive(binding));
    _ = try second.sessions.requestClose(two.handle, .{});
    try std.testing.expectEqual(@as(usize, 1), second_provider.closes);
}

test "shared application journal delivers failure to the original window" {
    const a = std.testing.allocator;
    const saved: config.Config = .{};
    var workspace_a: workspace_mod.Workspace = undefined;
    workspace_a.app_config = &saved;
    workspace_a.model = .{ .allocator = a, .window = @fromBackingInt(0), .workspace = @fromBackingInt(0) };
    defer workspace_a.model.deinit();
    workspace_a.tabs = .empty;
    var workspace_b: workspace_mod.Workspace = undefined;
    workspace_b.app_config = &saved;
    workspace_b.model = .{ .allocator = a, .window = @fromBackingInt(0), .workspace = @fromBackingInt(0) };
    defer workspace_b.model.deinit();
    workspace_b.tabs = .empty;
    const domain = try Domain.init(a, false);
    defer domain.deinit();
    const one = try ApplicationHost.initInDomain(domain, &workspace_a, null);
    defer one.deinit();
    const two = try ApplicationHost.initInDomain(domain, &workspace_b, null);
    defer two.deinit();
    // Isolate journal dispatch from native transports: the fixture adapter is
    // registered on the same shared registry, without creating a view.
    var context: u8 = 0;
    const adapter: session.Adapter = .{ .registration = .{ .plugin_id = .ssh, .workspace_kind = .terminal, .services = sshServices() }, .context = &context, .vtable = &.{ .create = ReceiptTestAdapter.create, .cancel = ReceiptTestAdapter.cancel, .close = ReceiptTestAdapter.close, .release_stale = ReceiptTestAdapter.stale } };
    domain.sessions.deinit();
    domain.sessions = try session.SessionHost.init(a, &.{adapter});
    const accepted = try domain.sessions.create(.{ .temporary_ssh = .{ .structured_endpoint = .{ .host = "test.invalid", .user = "tester" } } }, two.target());
    try two.mappings.append(a, .{ .handle = accepted.handle, .create_operation = accepted.operation, .legacy_id = 1, .legacy_generation = 1, .tab_id = @fromBackingInt(1), .owner = .{ .session = accepted.handle }, .source = null });
    _ = try domain.sessions.failed(accepted.handle, accepted.operation, .{ .domain = .transport, .code = "test_failure", .safe_message = "second window failure", .cleanup = .released });
    one.domain.drainJournal();
    try std.testing.expectEqual(@as(usize, 0), one.mappings.items.len);
    try std.testing.expect(two.mappings.items[0].failed_received);
    try std.testing.expectEqualStrings("second window failure", two.mappings.items[0].failure[0..two.mappings.items[0].failure_len]);
}

test "production creation entries obey removed and replacement Registry contributions" {
    const Counter = struct {
        creates: usize = 0,
        local_payload: bool = false,
        fn create(raw: *anyopaque, request: session.CreateRequest) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try std.testing.expect(request.spec == .plugin);
            self.creates += 1;
            if (std.mem.eql(u8, request.spec.plugin.protocol_id, "replacement.local")) self.local_payload = std.mem.indexOf(u8, request.spec.plugin.payload, "provider_encoded") != null;
        }
        fn cancel(_: *anyopaque, _: OperationKey) CloseReceipt {
            return .released;
        }
        fn close(_: *anyopaque, _: identity.SessionHandle, _: OperationKey) !CloseReceipt {
            return .released;
        }
        fn stale(_: *anyopaque, _: identity.SessionHandle, _: OperationKey) void {}
        fn validate(_: []const u8) !void {}
        fn codec(allocator: std.mem.Allocator, value: connection_envelope.Envelope) !connection_envelope.Envelope {
            return value.clone(allocator);
        }
        fn migrate(allocator: std.mem.Allocator, value: connection_envelope.Envelope, _: u32) !connection_envelope.Envelope {
            return value.clone(allocator);
        }
        fn editor(_: ?*anyopaque, _: @import("../host/plugin_ui_contract.zig").EditorMount) !@import("../host/plugin_ui_contract.zig").EditorInstance {
            return error.UnusedEditor;
        }
        fn encode(allocator: std.mem.Allocator, argument: ?[]const u8) ![]u8 {
            return std.json.Stringify.valueAlloc(allocator, .{ .provider_encoded = true, .argument = argument }, .{});
        }
        fn manifest(self: *@This(), id: []const u8) plugins.PluginManifest {
            var value: plugins.PluginManifest = .{ .id = id, .display_name = id, .workspace_kind = "terminal", .content_renderer = "terminal", .session_factory = .{ .context = self, .vtable = &.{ .create = create, .cancel = cancel, .close = close, .release_stale = stale } } };
            if (std.mem.eql(u8, id, "replacement.local")) value.quick_create = .{ .validate_payload = validate, .action_id = "session.local.create", .encode_creation_payload = encode } else value.connection = .{ .editor_factory = .{ .mount = editor }, .create_kind = .saved_or_temporary, .validate_payload = validate, .encode = codec, .decode = codec, .migrate = migrate };
            return value;
        }
    };
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |replaced| {
        var counter: Counter = .{};
        const definitions = [_]plugins.PluginManifest{ counter.manifest("replacement.local"), counter.manifest("ssh"), counter.manifest("sftp"), counter.manifest("fixture.replacement") };
        const domain = try Domain.init(a, false);
        defer domain.deinit();
        domain.sessions.deinit();
        domain.sessions = try session.SessionHost.initPlugins(a, if (replaced) &definitions else &.{}, &.{});
        var saved: config.Config = .{};
        var workspace: workspace_mod.Workspace = undefined;
        workspace.model = .{ .allocator = a, .window = @fromBackingInt(0), .workspace = @fromBackingInt(0) };
        defer workspace.model.deinit();
        workspace.registry = try hosts.Registry.parse(a, "");
        defer workspace.registry.deinit();
        workspace.app_config = &saved;
        workspace.shutting_down = false;
        workspace.external_auth = null;
        workspace.tabs = .empty;
        workspace.connect_jobs = .empty;
        const app = try ApplicationHost.initInDomain(domain, &workspace, null);
        defer app.deinit();
        const local = try app.createLocalForInput(try app.dispatcher.issue(), "/tmp");
        try std.testing.expectEqual(replaced, local == .accepted);
        for ([_]hosts.Protocol{ .ssh, .sftp }) |protocol| {
            const host: hosts.HostConfig = .{ .connection_id = @fromBackingInt(8), .revision = 2, .protocol = protocol, .name = "frozen", .host = "not-opened.test", .user = "operator" };
            const decision = try app.createForInput(try app.dispatcher.issue(), host, 8, 0, "");
            try std.testing.expectEqual(replaced, decision == .accepted);
        }
        const unknown: connection_envelope.Envelope = .{ .protocol_id = "fixture.replacement", .name = "unlisted protocol", .payload = "{}" };
        if (replaced) {
            _ = try app.openEnvelope(unknown, try app.dispatcher.issue());
            try std.testing.expectEqual(@as(usize, 4), counter.creates);
            try std.testing.expect(counter.local_payload);
        } else {
            try std.testing.expectError(error.UnknownPlugin, app.openEnvelope(unknown, try app.dispatcher.issue()));
            try std.testing.expectEqual(@as(usize, 0), counter.creates);
            try std.testing.expectEqual(@as(usize, 0), app.sessions.sessions.items.len);
        }
        try std.testing.expectEqual(@as(usize, 0), workspace.tabs.items.len);
        try std.testing.expectEqual(@as(usize, 0), workspace.connect_jobs.items.len);
    }
}

test "file create failure without a tab reaches original window once" {
    const Feedback = struct {
        calls: usize = 0,
        owner: ?identity.SessionHandle = null,
        fn publish(raw: *anyopaque, owner: identity.SessionHandle, message: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            self.owner = owner;
            std.testing.expectEqualStrings("连接失败：独立 SFTP 会话暂不支持跳板链（ProxyJumpTransportUnavailable）", message) catch @panic("incorrect failure");
        }
        fn tick(_: *anyopaque, _: *session.SessionHost) !bool {
            return false;
        }
        fn shutdown(_: *anyopaque) CloseReceipt {
            return .released;
        }
    };
    var feedback: Feedback = .{};
    var workspace: workspace_mod.Workspace = undefined;
    workspace.model = .{ .allocator = std.testing.allocator, .window = @fromBackingInt(0), .workspace = @fromBackingInt(0) };
    defer workspace.model.deinit();
    workspace.session_bridge = .{};
    workspace.close_bridge = .{};
    workspace.window_close_bridge = .{};
    workspace.shutting_down = false;
    var global: config.Config = .{};
    workspace.app_config = &global;
    workspace.registry.hosts = &.{};
    const adapter: session.Adapter = .{ .registration = .{ .plugin_id = .sftp, .workspace_kind = .file, .services = plugins.requiredServices(.sftp) }, .context = &feedback, .vtable = &.{ .create = ReceiptTestAdapter.create, .cancel = ReceiptTestAdapter.cancel, .close = ReceiptTestAdapter.close, .release_stale = ReceiptTestAdapter.stale } };
    const app = try ApplicationHost.initWithFilePlugin(std.testing.allocator, &workspace, .{ .adapter = adapter, .context = &feedback, .tick = Feedback.tick, .shutdown = Feedback.shutdown });
    defer app.deinit();
    app.file_failure = .{ .context = &feedback, .publish = Feedback.publish };
    const accepted = try app.create(.{ .connection_id = @fromBackingInt(19), .revision = 7, .protocol = .sftp, .name = "Route Files", .host = "test.invalid", .user = "operator" }, 91, 4, "");
    try std.testing.expectEqual(@as(usize, 0), app.mappings.items.len);
    const failure: @import("../host/operation.zig").Failure = .{ .domain = .plugin, .code = "ProxyJumpTransportUnavailable", .cleanup = .released, .safe_message = "SFTP 文件会话启动失败" };
    try std.testing.expect(try app.sessions.failed(accepted.handle, accepted.operation, failure));
    app.domain.drainJournal();
    try std.testing.expectEqual(@as(usize, 1), feedback.calls);
    try std.testing.expect(feedback.owner.?.eql(accepted.handle));
    app.publishFileCreateFailure(accepted.operation, failure);
    var stale = accepted.operation;
    stale.operation_id += 1;
    app.publishFileCreateFailure(stale, failure);
    try std.testing.expectEqual(@as(usize, 1), feedback.calls);
}
