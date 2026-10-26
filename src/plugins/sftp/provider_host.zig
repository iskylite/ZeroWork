//! Provider-owned composition of the actual SFTP engine and independent file
//! services. Each remote directory
//! and transfer connection has its original domain identity and IO owner.
const std = @import("std");
const ui = @import("ui");
const application = @import("../../ui/application_host.zig");
const Workspace = @import("../../ui/workspace.zig").Workspace;
const sessions = @import("../../host/session_host.zig");
const identity = @import("../../host/identity.zig");
const files = @import("../../host/file_binding_host.zig");
const lifecycle = @import("../../host/sftp_adapter.zig");
const transfers = @import("../../host/file_transfer_host.zig");
const routing = @import("../../transfer/engine_mux.zig");
const local = @import("../../local/fs_service.zig");
const ssh = @import("../../proto/ssh/session.zig");
const authentication = @import("../../ui/file_authentication.zig");
const presentation = @import("../../ui/file_workspace_presentation.zig");
const paths_mod = @import("../../config/paths.zig");
const controller = @import("../../host/file_workspace_controller.zig");
const hosts = @import("../../config/hosts.zig");
const auth = @import("../../proto/ssh/auth_challenge.zig");
const TotpPrefill = @import("../../proto/ssh/totp_prefill.zig");
const host_key = @import("../../ui/host_key_confirmation.zig");

// This is an app-owned local_fs endpoint namespace, not a remote SessionId or
// a fabricated SessionHost service. Each independent native service gets one.
const LocalBindingId = enum(u64) { _ };
var local_bindings: identity.Allocator(LocalBindingId) = .{};

pub const ExportStatus = presentation.ExportStatus;
pub const TransferHandler = struct {
    context: *anyopaque,
    submit: *const fn (*anyopaque, controller.FrozenTransfer, sessions.ServiceHandle) anyerror!void,
    export_start: ?*const fn (*anyopaque, controller.FrozenTransfer, sessions.ServiceHandle) anyerror!u64 = null,
    export_poll: ?*const fn (*anyopaque, u64) ExportStatus = null,
    export_cancel: ?*const fn (*anyopaque, u64) void = null,
    confirm: ?*const fn (*anyopaque, controller.FrozenTransfer, sessions.ServiceHandle, @import("../../ui/file_copy_view.zig").Options) anyerror!void = null,
};

pub const Host = struct {
    allocator: std.mem.Allocator,
    workspace: *Workspace,
    paths: paths_mod.Paths,
    library: ssh.Library,
    home: []u8,
    adapter: *lifecycle.SftpAdapter,
    app: ?*application.ApplicationHost = null,
    authentication: ?*authentication.FileAuthentication = null,
    file_host: ?*files.FileBindingHost = null,
    mux: ?*routing.Mux = null,
    transfer_host: ?*transfers.Host = null,
    task_domain: ?*@import("../../host/application_task_domain.zig").Domain = null,
    local_service: ?*local.Service = null,
    presentation: ?*presentation.Presentation = null,
    transfer_handler: ?TransferHandler = null,
    shutting_down: bool = false,
    released: bool = false,
    adapter_disposed: bool = false,

    pub fn create(allocator: std.mem.Allocator, workspace: *Workspace) !*Host {
        const self = try allocator.create(Host);
        errdefer allocator.destroy(self);
        var paths = try paths_mod.Paths.forApplication(allocator);
        errdefer paths.deinit();
        var library = try ssh.Library.init();
        errdefer library.deinit();
        const home = try @import("../../platform/account.zig").home(allocator);
        errdefer allocator.free(home);
        const adapter = try lifecycle.SftpAdapter.init(allocator, .{ .context = self, .start = transferStart, .poll = transferPoll, .close = transferClose }, .{ .context = self, .install = install, .release = release, .rollback = rollback }, .{});
        self.* = .{ .allocator = allocator, .workspace = workspace, .paths = paths, .library = library, .home = home, .adapter = adapter };
        return self;
    }

    pub fn plugin(self: *Host) application.FilePlugin {
        return .{ .adapter = self.adapter.adapter(), .context = self, .tick = tick, .shutdown = shutdown };
    }

    /// Called immediately after ApplicationHost init, before UI event delivery.
    pub fn bind(self: *Host, app: *application.ApplicationHost) !void {
        if (self.app != null) return error.FileHostAlreadyBound;
        self.app = app;
        self.authentication = try authentication.FileAuthentication.init(self.allocator, app.sessions, .{ .library = &self.library, .known_hosts_path = self.paths.known_hosts, .presentation_config_revision = self.workspace.app_config.config_revision, .saved_config = self.workspace.app_config });
        const file_host = try self.allocator.create(files.FileBindingHost);
        file_host.* = files.FileBindingHost.init(self.allocator, app.sessions, self.authentication.?.factory()) catch |err| {
            self.allocator.destroy(file_host);
            return err;
        };
        self.file_host = file_host;
        if (app.domain.tasks == null) app.domain.tasks = try @import("../../host/application_task_domain.zig").Domain.init(app.domain.allocator, self.workspace.io, app.sessions, self.workspace.app_config, self.paths.known_hosts, .{ .context = app.domain, .get = application.Domain.sharedForward });
        const tasks = app.domain.tasks.?;
        self.task_domain = tasks;
        self.mux = &tasks.mux;
        self.transfer_host = &tasks.transfers;
        const endpoint: local.EndpointRef = .{ .binding_id = @backingInt(try local_bindings.allocate()), .binding_generation = 1 };
        self.local_service = try local.Service.start(self.allocator, endpoint, .{ .home = self.home });
        self.presentation = try presentation.Presentation.init(self.allocator, .{
            .app = app,
            .file_host = file_host,
            .local = .{ .service = self.local_service.?, .journal = &app.sessions.journal, .endpoint = endpoint, .initial_path = self.home, .labels = .{ .title = "本地 · 此 Mac", .subtitle = "本机文件", .badge = "本地" }, .writable = true },
            .callbacks = .{ .context = self, .transfer = submitTransfer, .auxiliary = auxiliary },
            .remote_writable = true,
            .confirm_transfer = confirmTransfer,
            .transfer_config = self.workspace.app_config,
            .exports = .{ .context = self, .start = exportStart, .poll = exportPoll, .cancel = exportCancel },
        });
        self.workspace.external_auth = .{ .context = self, .pending = pendingAuth, .submit = submitAuth, .cancel = cancelAuth, .host = authHost, .totp = authTotp, .parent = authParent, .host_key = authHostKey };
    }

    /// Explicit AI resource-picker request. Repeated calls preserve the same
    /// original source; callers query the handles until native readiness.
    pub fn ensureReadonlySource(self: *Host, owner: identity.SessionHandle) !files.Bindings {
        const app = self.app orelse return error.FileHostNotBound;
        const manifest = app.sessions.manifestFor(owner) orelse return error.StaleSession;
        if (!manifest.integration.auxiliary_readonly) {
            const directory = switch (app.sessions.queryService(owner, .directory)) {
                .available => |binding| binding,
                else => return error.FileSourceUnavailable,
            };
            const file_read = switch (app.sessions.queryService(owner, .file_read)) {
                .available => |binding| binding,
                else => return error.FileSourceUnavailable,
            };
            return .{ .directory = directory, .file_read = file_read };
        }
        const file_host = self.file_host orelse return error.FileHostNotBound;
        const start = try app.sessions.beginAuxiliaryReadonly(owner);
        _ = file_host.attachAuxiliary(owner, start) catch |err| {
            _ = app.sessions.auxiliaryReadonlyReleased(owner, start, .released) catch {};
            return err;
        };
        return .{ .directory = start.bindings.directory, .file_read = start.bindings.file_read };
    }

    pub fn ensureSharedReadonlySource(self: *Host, owner: identity.SessionHandle, provider: @import("../../proto/ssh/shared_readonly_mailbox.zig").Provider) !files.Bindings {
        const app = self.app orelse return error.FileHostNotBound;
        const file_host = self.file_host orelse return error.FileHostNotBound;
        const start = try app.sessions.beginAuxiliaryReadonly(owner);
        _ = file_host.attachShared(owner, start, provider) catch |err| {
            _ = app.sessions.auxiliaryReadonlyReleased(owner, start, .released) catch {};
            return err;
        };
        return .{ .directory = start.bindings.directory, .file_read = start.bindings.file_read };
    }

    pub fn setTransferHandler(self: *Host, handler: TransferHandler) void {
        self.transfer_handler = handler;
    }

    pub fn retheme(self: *Host) void {
        if (self.presentation) |view| view.retheme();
    }

    fn live(raw: *anyopaque, binding: sessions.ServiceHandle) bool {
        const domain: *sessions.SessionHost = @ptrCast(@alignCast(raw));
        return domain.bindingIsLive(binding);
    }

    fn tick(raw: *anyopaque, domain: *sessions.SessionHost) !bool {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (self.app == null or self.app.?.sessions != domain) return error.FileHostNotBound;
        if (self.shutting_down) _ = self.shutdownStep();
        var active = false;
        if (self.transfer_host) |host| active = try host.safeTick();
        if (self.file_host) |host| active = try self.adapter.safeTick(domain, host) or active;
        if (self.local_service) |service| for (0..64) |_| {
            var result = service.poll() orelse break;
            defer result.deinit();
            if (self.presentation) |view| {
                if (!try view.acceptLocal(result.value)) return error.UnclaimedLocalFileResult;
            } else if (!self.shutting_down) return error.UnclaimedLocalFileResult;
        };
        if (self.presentation) |view| active = try view.safeTick() or active;
        if (self.authentication) |host| active = try host.collect() or active;
        if (self.file_host) |host| for (self.workspace.tabs.items) |tab| {
            if (tab.content_owner != .session or tab.runtime != null or tab.local or tab.closing) continue;
            if (host.osDetection(tab.content_owner.session)) |value| {
                const original: ?hosts.HostConfig = switch (value.source) {
                    .saved => |saved| .{ .connection_id = saved.connection_id, .revision = saved.config_revision, .protocol = .sftp, .name = "", .host = saved.immutable_config.endpoint.host, .port = saved.immutable_config.endpoint.port, .user = saved.immutable_config.endpoint.user },
                    else => null,
                };
                self.workspace.updateSessionOs(tab.content_owner.session, value.kind, original);
            }
        };
        if (self.shutting_down) _ = self.shutdownStep();
        return active or (self.shutting_down and !self.released);
    }

    fn shutdown(raw: *anyopaque) sessions.CloseReceipt {
        const self: *Host = @ptrCast(@alignCast(raw));
        return self.shutdownStep();
    }

    pub fn shutdownStep(self: *Host) sessions.CloseReceipt {
        if (self.released) return .released;
        self.shutting_down = true;
        var receipt = self.adapter.shutdownStep();
        if (self.presentation) |view| receipt = combine(receipt, view.shutdownStep());
        // Transfer backends are process-owned. Adapter shutdown above closes
        // only this window's original bindings; retained jobs remain alive.
        if (self.file_host) |host| {
            host.requestCloseAll();
            if (host.bindings.items.len != 0) receipt = combine(receipt, .awaiting);
        }
        if (self.authentication) |host| receipt = combine(receipt, convert(host.shutdownStep()));
        if (self.local_service) |service| {
            service.requestClose();
            receipt = combine(receipt, convertLocal(service.closeReceipt()));
        }
        self.released = receipt == .released;
        return receipt;
    }

    /// ApplicationHost first consumes the released receipt, then its owner
    /// calls this. No freed ApplicationHost/SessionHost is accessed here.
    pub fn deinit(self: *Host) error{Busy}!void {
        if (!self.released) return error.Busy;
        if (self.workspace.external_auth) |external| if (external.context == @as(*anyopaque, self)) {
            self.workspace.external_auth = null;
        };
        if (self.presentation) |view| {
            try view.deinit();
            self.presentation = null;
        }
        if (!self.adapter_disposed) {
            try self.adapter.deinit();
            self.adapter_disposed = true;
        }
        if (self.file_host) |host| {
            try host.deinit();
            self.allocator.destroy(host);
            self.file_host = null;
        }
        self.transfer_host = null;
        self.mux = null;
        self.task_domain = null;
        if (self.authentication) |host| {
            try host.deinit();
            self.authentication = null;
        }
        if (self.local_service) |service| {
            try service.deinit();
            self.local_service = null;
        }
        self.library.deinit();
        self.paths.deinit();
        self.allocator.free(self.home);
        self.allocator.destroy(self);
    }

    /// Only for failed synchronous bootstrap, before any create can be accepted.
    /// The sole possible worker is an idle local service with no queued IO.
    pub fn abortInitialization(self: *Host) void {
        if (self.adapter.entries.items.len != 0) return;
        _ = self.shutdownStep();
        for (0..100) |_| {
            if (self.released) return;
            if (self.app) |app| _ = tick(self, app.sessions) catch return;
            var unused: [1]std.c.pollfd = undefined;
            _ = std.c.poll(&unused, 0, 2);
        }
    }

    fn transferStart(raw: *anyopaque, request: lifecycle.TransferStart) !void {
        const self: *Host = @ptrCast(@alignCast(raw));
        const host = self.transfer_host orelse return error.FileHostNotBound;
        const hooks = host.hooks();
        try hooks.start(hooks.context, request);
    }
    fn transferPoll(raw: *anyopaque, binding: sessions.ServiceHandle, key: sessions.OperationKey) lifecycle.TransferStatus {
        const self: *Host = @ptrCast(@alignCast(raw));
        const host = self.transfer_host orelse return .pending;
        const hooks = host.hooks();
        return hooks.poll(hooks.context, binding, key);
    }
    fn transferClose(raw: *anyopaque, request: lifecycle.TransferClose) sessions.CloseReceipt {
        const self: *Host = @ptrCast(@alignCast(raw));
        const host = self.transfer_host orelse return .released;
        const hooks = host.hooks();
        return hooks.close(hooks.context, request);
    }
    fn install(raw: *anyopaque, request: lifecycle.Presentation) !sessions.Attachment {
        const self: *Host = @ptrCast(@alignCast(raw));
        const hooks = (self.presentation orelse return error.FileHostNotBound).hooks();
        return hooks.install(hooks.context, request);
    }
    fn release(raw: *anyopaque, owner: identity.SessionHandle, attachment: sessions.Attachment, key: sessions.OperationKey) sessions.CloseReceipt {
        const self: *Host = @ptrCast(@alignCast(raw));
        const hooks = (self.presentation orelse return .released).hooks();
        const receipt = hooks.release(hooks.context, owner, attachment, key);
        if (receipt == .released and @import("../../platform/runtime_mode.zig").automation) std.debug.print("SFTP_WORKSPACE_TRACE {{\"event\":\"closed\",\"owner\":{{\"session_id\":{d},\"generation\":{d}}},\"operation\":{d},\"tab_id\":{d},\"cleanup\":\"released\"}}\n", .{ @backingInt(owner.session_id), owner.generation, key.operation_id, @backingInt(attachment.tab_id) });
        return receipt;
    }
    fn rollback(raw: *anyopaque, owner: identity.SessionHandle, key: sessions.OperationKey) sessions.CloseReceipt {
        const self: *Host = @ptrCast(@alignCast(raw));
        const hooks = (self.presentation orelse return .released).hooks();
        return if (hooks.rollback) |callback| callback(hooks.context, owner, key) else .released;
    }
    fn submitTransfer(raw: ?*anyopaque, intent: controller.FrozenTransfer) !void {
        const self: *Host = @ptrCast(@alignCast(raw orelse return error.FileHostNotBound));
        const domain = self.app.?.sessions;
        const binding = switch (domain.queryService(intent.owner, .transfer)) {
            .available => |handle| handle,
            else => return error.TransferUnavailable,
        };
        if (!domain.bindingIsLive(binding)) return error.StaleBinding;
        const handler = self.transfer_handler orelse return error.TransferUnavailable;
        try handler.submit(handler.context, intent, binding);
    }
    fn exportStart(raw: ?*anyopaque, intent: controller.FrozenTransfer) !u64 {
        const self: *Host = @ptrCast(@alignCast(raw orelse return error.FileHostNotBound));
        const domain = self.app.?.sessions;
        const binding = switch (domain.queryService(intent.owner, .transfer)) {
            .available => |handle| handle,
            else => return error.TransferUnavailable,
        };
        if (!domain.bindingIsLive(binding)) return error.StaleBinding;
        const handler = self.transfer_handler orelse return error.TransferUnavailable;
        return (handler.export_start orelse return error.TransferUnavailable)(handler.context, intent, binding);
    }
    fn exportCancel(raw: ?*anyopaque, job: u64) void {
        const self: *Host = @ptrCast(@alignCast(raw orelse return));
        const handler = self.transfer_handler orelse return;
        if (handler.export_cancel) |call| call(handler.context, job);
    }
    fn exportPoll(raw: ?*anyopaque, job: u64) ExportStatus {
        const self: *Host = @ptrCast(@alignCast(raw orelse return .failed));
        const handler = self.transfer_handler orelse return .failed;
        return if (handler.export_poll) |call| call(handler.context, job) else .failed;
    }
    fn confirmTransfer(raw: ?*anyopaque, intent: controller.FrozenTransfer, options: @import("../../ui/file_copy_view.zig").Options) !void {
        const self: *Host = @ptrCast(@alignCast(raw orelse return error.FileHostNotBound));
        const domain = self.app.?.sessions;
        const binding = switch (domain.queryService(intent.owner, .transfer)) {
            .available => |handle| handle,
            else => return error.TransferUnavailable,
        };
        if (!domain.bindingIsLive(binding)) return error.StaleBinding;
        const handler = self.transfer_handler orelse return error.TransferUnavailable;
        const callback = handler.confirm orelse return error.TransferUnavailable;
        try callback(handler.context, intent, binding, options);
    }
    fn auxiliary(raw: ?*anyopaque, action: controller.Auxiliary) !void {
        const self: *Host = @ptrCast(@alignCast(raw orelse return error.FileHostNotBound));
        switch (action) {
            .copy_paths => |envelope| {
                const keys = envelope.action.copy_paths.keys;
                const text = try std.mem.join(self.allocator, "\n", keys);
                defer self.allocator.free(text);
                if (!ui.platform_services.clipboardSetText(self.workspace.cx.system_sdk, text)) return error.ClipboardUnavailable;
            },
            else => return error.UnsupportedFileAction,
        }
    }
    fn pendingAuth(raw: *anyopaque) ?auth.Snapshot {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (self.authentication) |host| if (host.pendingAuthentication()) |value| return value;
        if (self.task_domain) |tasks| if (tasks.authentication.pendingAuthentication()) |value| {
            const app = self.app orelse return null;
            const original = if (value.identity.key.owner == .session) app.domain.ownerForHandle(value.identity.key.owner.session) else null;
            const recipient = original orelse if (app.domain.attachments.items.len != 0) app.domain.attachments.items[0] else null;
            if (recipient == app) return value;
        };
        return null;
    }
    fn submitAuth(raw: *anyopaque, key: auth.RequestIdentity, reply: auth.Reply) !void {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (self.task_domain) |tasks| if (tasks.authentication.authenticationHostFor(key) != null) return tasks.authentication.submitAuthentication(key, reply);
        try (self.authentication orelse return error.StaleAuthentication).submitAuthentication(key, reply);
    }
    fn cancelAuth(raw: *anyopaque, key: auth.RequestIdentity) bool {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (self.task_domain) |tasks| if (tasks.authentication.cancelAuthentication(key)) return true;
        return if (self.authentication) |host| host.cancelAuthentication(key) else false;
    }
    fn authHost(raw: *anyopaque, key: auth.RequestIdentity) ?hosts.HostConfig {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (self.task_domain) |tasks| if (tasks.authentication.authenticationHostFor(key)) |value| return value;
        return if (self.authentication) |host| host.authenticationHostFor(key) else null;
    }
    fn authTotp(raw: *anyopaque, key: auth.RequestIdentity, now: TotpPrefill.Time) !?TotpPrefill.Suggestion {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (self.task_domain) |tasks| if (tasks.authentication.authenticationHostFor(key) != null) return tasks.authentication.authenticationTotp(key, now);
        return if (self.authentication) |host| host.authenticationTotp(key, now) else null;
    }
    fn authParent(raw: *anyopaque, key: auth.RequestIdentity) ?*ui.Node {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (authHost(raw, key) == null) return null;
        return self.workspace.terminal_area;
    }
    fn authHostKey(raw: *anyopaque, key: auth.RequestIdentity) ?host_key.Request {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (self.task_domain) |tasks| if (tasks.authentication.authenticationHostKey(key)) |value| return value;
        return if (self.authentication) |host| host.authenticationHostKey(key) else null;
    }
};

fn combine(a: sessions.CloseReceipt, b: sessions.CloseReceipt) sessions.CloseReceipt {
    if (a == .unknown or b == .unknown) return .unknown;
    if (a == .awaiting or b == .awaiting) return .awaiting;
    return .released;
}
fn convert(value: files.readonly.ReleaseReceipt) sessions.CloseReceipt {
    return switch (value) {
        .released => .released,
        .awaiting => .awaiting,
        .unknown => .unknown,
    };
}
fn convertLocal(value: local.ReleaseReceipt) sessions.CloseReceipt {
    return switch (value) {
        .released => .released,
        .awaiting => .awaiting,
        .unknown => .unknown,
    };
}
