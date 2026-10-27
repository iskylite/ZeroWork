//! Main-thread presentation of an existing connection operation. The workspace
//! and SessionHost retain all protocol resources and allocate every identity.
const std = @import("std");
const ui = @import("ui");
const Workspace = @import("workspace.zig").Workspace;
const ApplicationHost = @import("application_host.zig").ApplicationHost;
const operations = @import("../host/operation.zig");
const auth = @import("../proto/ssh/auth_challenge.zig");
const Bridge = @import("../plugins/remote/challenge_bridge.zig");
const Shared = @import("challenge_window_host.zig").Services;
const Presenter = @import("plugin_challenge_presenter.zig").Presenter;
const Progress = @import("connection_progress_view.zig");
const theme = @import("app_theme.zig");
const applog = @import("../platform/applog.zig");

pub const Host = struct {
    cx: *ui.Cx,
    workspace: *Workspace,
    application: *ApplicationHost,
    progress: *Progress.View,
    authentication: *Presenter,
    challenges: *Shared,
    bridge: Bridge.Bridge = .{},
    painted_colors: ?theme.Colors = null,
    last_error: ?anyerror = null,
    totp_clock: @import("../proto/ssh/totp_prefill.zig").Clock = .{},

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, workspace: *Workspace, application: *ApplicationHost) !*Host {
        const self = try cx.allocator.create(Host);
        var registered = false;
        errdefer if (!registered) cx.allocator.destroy(self);
        self.* = .{ .cx = cx, .workspace = workspace, .application = application, .progress = undefined, .authentication = undefined, .challenges = try Shared.mount(cx, scope) };
        self.progress = try Progress.View.mount(cx, scope, .{ .context = self, .cancel = cancel, .retry = retry, .close = close, .copy_logs = copyLogs });
        self.authentication = self.challenges.view;
        try scope.onCleanup(Host, self, cleanup);
        registered = true;
        try cx.addAfterLayoutHook(self, hook);
        workspace.authentication_ui_ready = true;
        return self;
    }

    pub fn blocksGlobalActions(self: *const Host) bool {
        return self.progress.isVisible() or self.bridge.visible();
    }

    fn hook(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Host = @ptrCast(@alignCast(raw));
        self.refresh() catch |err| {
            if (self.last_error == null or self.last_error.? != err) applog.warn(.ui, "connection presentation failed: {s}", .{@errorName(err)});
            self.last_error = err;
            return .done;
        };
        self.last_error = null;
        return .done;
    }

    fn refresh(self: *Host) !void {
        const colors = theme.current();
        if (self.painted_colors == null or !std.meta.eql(self.painted_colors.?, colors)) {
            try self.progress.retheme();
            self.painted_colors = colors;
        }
        const pending = self.workspace.pendingAuthentication();
        // A later owner's prompt cannot replace the card currently being
        // read. Reconcile its actual attached/released receipt first.
        const captured = self.progress.operationKey();
        const file_key = if (captured) |key| (if (self.application.fileConnectionProgress(key) != null) key else if (self.workspace.connectionProgress(key) != null) null else self.application.fileProgressKey()) else self.application.fileProgressKey();
        if (file_key) |key| {
            if (try self.refreshFile(key, pending)) return;
        }
        var source = if (captured) |key| self.workspace.connectionProgress(key) else null;
        if (captured != null and source == null) self.hide();
        const key = if (source) |current| current.key else if (pending) |request| request.identity.key else self.workspace.nextConnectionPresentationKey() orelse {
            self.hide();
            return;
        };
        if (source == null) source = self.workspace.connectionProgress(key);
        const current = source orelse {
            // File connections own their original authentication operation but
            // have no terminal ConnectJob/progress graph. Reuse the protected
            // modal directly; never synthesize a terminal resource snapshot.
            if (pending) |request| if (self.workspace.external_auth != null and self.workspace.authenticationHostFor(request.identity) != null) {
                self.progress.hide();
                var modal_request = request;
                modal_request.presentation = .otp_modal;
                try self.showAuthentication(modal_request);
                self.cx.scheduleRedrawAfterNs(33 * std.time.ns_per_ms);
                return;
            };
            self.hide();
            return;
        };
        if (current.attached) {
            const restore_focus = self.progress.isVisible() or self.bridge.current != null;
            self.hide();
            if (restore_focus) if (self.workspace.active_tab) |index| {
                const tab = self.workspace.tabs.items[index];
                if (tab.terminal) |*terminal| terminal.focus();
            };
            return;
        }
        const challenge = if (pending) |request| (if (request.identity.key.eql(key)) pending else null) else null;
        var hops: [9]Progress.Hop = undefined;
        var logs: [128]Progress.LogRecord = undefined;
        for (current.logs[0..current.log_count], logs[0..current.log_count]) |record, *destination| destination.* = .{ .key = record.key, .entry = record.entry };
        for (current.hops[0..current.hop_count], hops[0..current.hop_count]) |hop, *destination| destination.* = .{ .name = hop.name, .host = hop.host, .user = hop.user, .port = hop.port };
        const waiting = if (challenge) |request| request.identity.key.eql(key) else false;
        const is_host_key = if (challenge) |request| request.kind == .host_key_unknown or request.kind == .host_key_changed else false;
        const state: Progress.State = if (current.cancelled) .cancelled else if (current.failure != null or current.attachment_failed) .failed else if (waiting) (if (is_host_key) .waiting_host_key else .waiting_auth) else if (current.journal.completed) (if (current.finished) .attaching else .protocol_ready) else if ((key.attempt_id orelse 1) > 1) .retrying else .connecting;
        const failure: ?Progress.Failure = if (current.failure != null or current.attachment_failed) .{
            .hop = if (current.journal.failure) |entry| entry.hop else null,
            .phase = if (current.journal.failure) |entry| entry.phase else null,
            .reason = if (current.failure) |err| Progress.failureText(err) else "终端接入失败",
        } else null;
        // A protected challenge owns the active modal/focus trap. Reopening
        // progress while it is visible makes the password form inert.
        if (waiting) self.progress.hide() else try self.progress.show(.{ .key = key, .hops = hops[0..current.hop_count], .journal = current.journal, .logs = logs[0..current.log_count], .dropped = current.dropped, .resources = current.resources, .state = state, .cleanup = current.cleanup, .attached = current.attached, .local_ready = true, .inline_authentication = false, .failure = failure });
        if (challenge) |request| {
            try self.showAuthentication(request);
        } else {
            self.bridge.clear();
        }
        self.cx.scheduleRedrawAfterNs(33 * std.time.ns_per_ms);
    }

    fn showAuthentication(self: *Host, request: auth.Snapshot) !void {
        const host = self.workspace.authenticationHostFor(request.identity) orelse return error.StaleAuthentication;
        const ns = @import("../platform/realtime.zig").monotonicNs();
        try self.bridge.sync(&self.challenges.host, request, .{ .allow_save_password = @backingInt(host.connection_id) != 0, .display_name = host.name, .private_key_path = host.identity_file orelse "", .host_key = self.workspace.authenticationHostKey(request.identity) }, .{ .context = self, .submit = submitAuthentication, .save_password = savePassword, .cancel = cancelAuthentication }, @intCast(@max(0, ns) / std.time.ns_per_ms));
        if (self.workspace.authenticationTotp(request.identity, self.totp_clock.now()) catch null) |proposed| {
            var value = proposed;
            defer value.deinit();
            if (value.validAt(self.totp_clock.now())) _ = try self.authentication.prefill(Bridge.Bridge.owner(request.identity), request.identity.request_id, Bridge.Bridge.generation(request.identity), value.code.slice(), value.window, value.expires_at_ns, .{ .context = self, .valid = prefillValid });
        }
    }

    fn refreshFile(self: *Host, key: operations.OperationKey, pending: ?auth.Snapshot) !bool {
        if (key.owner != .session) return false;
        const state = self.application.sessions.queryState(key.owner.session) orelse return false;
        if (!state.create_operation.eql(key)) return false;
        if (state.lifecycle == .attached or state.lifecycle == .closed or state.lifecycle == .ended) {
            self.application.dismissFileProgress(key);
            self.hide();
            return false;
        }
        const diagnostic = self.application.fileConnectionProgress(key) orelse return false;
        if (pending) |request| if (self.workspace.authenticationHostFor(request.identity) != null) {
            self.progress.hide();
            var modal_request = request;
            modal_request.presentation = .otp_modal;
            try self.showAuthentication(modal_request);
            self.cx.scheduleRedrawAfterNs(33 * std.time.ns_per_ms);
            return true;
        };
        self.bridge.clear();
        const source = try self.application.fileSource(key.owner.session, key);
        var reason: [1536]u8 = undefined;
        const fault = diagnostic.failure;
        const failure: ?Progress.Failure = if (fault) |value| .{
            .hop = if (diagnostic.journal.failure) |entry| entry.hop else null,
            .phase = if (diagnostic.journal.failure) |entry| entry.phase else null,
            .reason = try std.fmt.bufPrint(&reason, "{s} · {s}（{s}）", .{ ApplicationHost.fileFailureText(value.code), value.stage orelse diagnostic.activity, value.code }),
        } else null;
        const saved = source.host;
        const hop: Progress.Hop = .{ .name = saved.name, .host = saved.host, .user = saved.user, .port = saved.port };
        try self.progress.show(.{
            .key = key,
            .hops = &.{hop},
            .journal = diagnostic.journal,
            .state = if (fault != null) .failed else if (state.lifecycle == .failed) .cancelled else if (diagnostic.journal.completed) .protocol_ready else .connecting,
            .cleanup = state.create_cleanup,
            .local_ready = true,
            .failure = failure,
            .file_session = true,
            .activity = diagnostic.activity,
        });
        self.cx.scheduleRedrawAfterNs(33 * std.time.ns_per_ms);
        return true;
    }

    fn prefillValid(raw: *anyopaque, window: u64, expires_ns: ?i128) bool {
        const self: *Host = @ptrCast(@alignCast(raw));
        const now = self.totp_clock.now();
        return now.unix_seconds / @import("../proto/ssh/totp.zig").period_seconds == window and (if (expires_ns) |expiry| now.monotonic_ns < expiry else true);
    }
    fn hide(self: *Host) void {
        self.bridge.clear();
        self.progress.hide();
    }
    fn savePassword(raw: *anyopaque, request: auth.Snapshot, password: []const u8) !void {
        const self: *Host = @ptrCast(@alignCast(raw));
        try self.workspace.saveAuthenticationPassword(request, password);
    }
    fn submitAuthentication(raw: *anyopaque, request: auth.RequestIdentity, reply: auth.Reply) !void {
        const self: *Host = @ptrCast(@alignCast(raw));
        try self.workspace.submitAuthentication(request, reply);
    }
    fn cancelAuthentication(raw: *anyopaque, request: auth.RequestIdentity) void {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (self.workspace.cancelAuthentication(request)) _ = self.application.sessions.cancel(request.key) catch false;
    }
    fn cancel(raw: *anyopaque, key: operations.OperationKey) void {
        const self: *Host = @ptrCast(@alignCast(raw));
        _ = self.application.sessions.cancel(key) catch false;
    }
    fn retry(raw: *anyopaque, key: operations.OperationKey) !void {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (key.owner != .session) return error.InvalidOperation;
        if (self.application.fileConnectionProgress(key) != null) {
            _ = try self.application.sessions.retry(key.owner.session);
            self.application.dismissFileProgress(key);
            self.progress.hide();
            return;
        }
        const current = self.workspace.connectionProgress(key) orelse return error.StaleConnection;
        if (current.cleanup != .released) return error.CleanupNotReleased;
        const id = self.application.legacyForHandle(key.owner.session) orelse return error.StaleConnection;
        try self.application.requestSshReconnect(id);
    }
    fn close(raw: *anyopaque, key: operations.OperationKey) void {
        const self: *Host = @ptrCast(@alignCast(raw));
        self.application.dismissFileProgress(key);
        self.workspace.dismissConnectionProgress(key) catch {};
    }
    fn copyLogs(raw: *anyopaque, key: operations.OperationKey, text: []const u8) !void {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (self.workspace.connectionProgress(key) == null and self.application.fileConnectionProgress(key) == null) return error.StaleConnection;
        if (!ui.platform_services.clipboardSetText(self.cx.system_sdk, text)) return error.ClipboardUnavailable;
    }
    fn cleanup(self: *Host) void {
        self.cx.removeAfterLayoutHook(self);
        self.bridge.clear();
        self.workspace.authentication_ui_ready = false;
        // Each view owns its scope cleanup. Child input scopes may already be
        // disposed here, so do not call presentation methods during teardown.
        self.cx.allocator.destroy(self);
    }
};
