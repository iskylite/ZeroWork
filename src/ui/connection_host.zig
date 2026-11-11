//! Main-thread presentation of an existing connection operation. The workspace
//! and SessionHost retain all protocol resources and allocate every identity.
const std = @import("std");
const ui = @import("ui");
const Workspace = @import("workspace.zig").Workspace;
const ApplicationHost = @import("application_host.zig").ApplicationHost;
const operations = @import("../host/operation.zig");
const identity = @import("../host/identity.zig");
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
    pending_file_focus: ?@import("../host/identity.zig").SessionHandle = null,
    retained_logs: ?operations.OperationKey = null,
    painted_colors: ?theme.Colors = null,
    last_error: ?anyerror = null,
    totp_clock: @import("../proto/ssh/totp_prefill.zig").Clock = .{},

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, workspace: *Workspace, application: *ApplicationHost) !*Host {
        // Mount runs outside a render/input entry. Inputs created below can
        // start transitions immediately; use this window's clock rather than
        // the last rendered window's (potentially much later) timestamp.
        cx.bindFrameClock();
        const self = try cx.allocator.create(Host);
        var registered = false;
        errdefer if (!registered) cx.allocator.destroy(self);
        self.* = .{ .cx = cx, .workspace = workspace, .application = application, .progress = undefined, .authentication = undefined, .challenges = try Shared.mount(cx, scope) };
        self.progress = try Progress.View.mountWithOwner(cx, scope, .{ .context = self, .cancel = cancel, .retry = retry, .close = close, .copy_logs = copyLogs }, .{ .resolve = .{ .context = self, .get = progressOwner } });
        self.authentication = self.challenges.view;
        self.challenges.bindSessionOwner(workspace);
        self.challenges.unattached_owner = .{ .context = self, .get = unattachedAuthOwner };
        try scope.onCleanup(Host, self, cleanup);
        registered = true;
        try cx.addAfterLayoutHook(self, hook);
        workspace.authentication_ui_ready = true;
        return self;
    }

    fn progressOwner(raw: *anyopaque) ?*ui.Node {
        const self: *Host = @ptrCast(@alignCast(raw));
        const key = self.progress.operationKey() orelse return null;
        return if (key.owner == .session) self.workspace.overlayOwner(key.owner.session) else null;
    }

    fn activeOwner(self: *const Host) ?identity.SessionHandle {
        const index = self.workspace.active_tab orelse return null;
        if (index >= self.workspace.tabs.items.len) return null;
        const tab = self.workspace.tabs.items[index];
        return if (tab.content_owner == .session and !tab.closing) tab.content_owner.session else null;
    }

    fn unattachedAuthOwner(raw: *anyopaque, owner: @import("../host/challenge_host.zig").Owner) ?*ui.Node {
        const self: *Host = @ptrCast(@alignCast(raw));
        const current = self.bridge.current orelse return null;
        if (!owner.eql(Bridge.Bridge.owner(current.identity))) return null;
        if (self.isBackgroundRequest(current)) return self.workspace.authenticationParent(current.identity);
        const key = current.identity.key;
        return if (key.owner == .session) self.provisionalGroupOwner(key.owner.session) else null;
    }

    fn isBackgroundRequest(self: *const Host, request: auth.Snapshot) bool {
        const owner = request.identity.key.owner;
        const backgrounds = self.application.domain.backgrounds orelse return false;
        return owner == .session and backgrounds.owns(owner.session);
    }

    fn provisionalGroupOwner(self: *Host, owner: identity.SessionHandle) ?*ui.Node {
        const id = self.application.legacyForHandle(owner) orelse return null;
        const tab = self.workspace.sessionTab(id) orelse return null;
        if (!tab.owned_pending or tab.closing) return null;
        const entry = self.application.lifecycle_supervisor.resource(owner) orelse return null;
        const group = self.workspace.active_group_view orelse return null;
        if (group != @backingInt(entry.request.group.id)) return null;
        if (entry.request.source) |source| return self.workspace.overlayOwner(source);
        for (self.workspace.group_views.items) |view| if (view.id == group) return view.root;
        return null;
    }

    fn pendingAuthentication(self: *Host, active: ?identity.SessionHandle) ?auth.Snapshot {
        if (active) |owner| if (self.workspace.pendingAuthenticationFor(owner)) |request| return request;
        for (self.workspace.tabs.items) |tab| {
            if (tab.content_owner != .session or tab.closing) continue;
            const owner = tab.content_owner.session;
            if (active != null and active.?.eql(owner)) continue;
            if (self.workspace.overlayOwner(owner) == null and self.provisionalGroupOwner(owner) == null) continue;
            if (self.workspace.pendingAuthenticationFor(owner)) |request| return request;
        }
        const request = self.workspace.pendingAuthentication() orelse return null;
        return if (self.isBackgroundRequest(request)) request else null;
    }

    fn hook(raw: *anyopaque, _: u8, last_round: bool) ui.AfterLayoutResult {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (self.pending_file_focus) |owner| {
            self.pending_file_focus = null;
            if (self.cx.focus_manager.activeScope() == null) if (self.workspace.active_tab) |index| {
                const tab = self.workspace.tabs.items[index];
                if (tab.content_owner.eql(.{ .session = owner })) self.cx.setFocus(tab.root);
            };
        }
        self.refresh() catch |err| {
            if (self.last_error == null or self.last_error.? != err) applog.warn(.ui, "connection presentation failed: {s}", .{@errorName(err)});
            self.last_error = err;
            return .done;
        };
        self.last_error = null;
        if (self.pending_file_focus != null) {
            if (last_round) self.cx.requestRedraw();
            return .needs_layout;
        }
        return .done;
    }

    fn refresh(self: *Host) !void {
        const colors = theme.current();
        if (self.painted_colors == null or !std.meta.eql(self.painted_colors.?, colors)) {
            try self.progress.retheme();
            self.painted_colors = colors;
        }
        const owner = self.activeOwner();
        const pending = self.pendingAuthentication(owner);
        try self.refreshAuthentication(pending);
        const captured = self.progress.operationKey();
        const file = if (owner) |value| self.application.fileProgressKeyFor(value) else null;
        const terminal = if (owner) |value| self.workspace.nextConnectionPresentationKeyFor(value) else null;
        const visible_capture = if (captured) |key| if (key.owner == .session and self.workspace.overlayOwner(key.owner.session) != null) key else null else null;
        if (self.retained_logs) |key| if (key.owner != .session or self.workspace.overlayOwner(key.owner.session) == null) {
            self.retained_logs = null;
        };
        const key = file orelse terminal orelse self.retained_logs orelse visible_capture orelse {
            self.progress.hide();
            return;
        };
        if (captured) |previous| if (previous.owner == .session and key.owner == .session and previous.owner.session.session_id != key.owner.session.session_id) {
            self.progress.hide();
        };
        const open_logs = self.showingRetainedLogs(key) and !self.progress.matches(key);
        const waiting = if (pending) |request| request.identity.key.owner.eql(key.owner) else false;
        if (waiting) {
            self.progress.hide();
            return;
        }
        if (self.application.fileConnectionProgress(key) == null or !try self.refreshFile(key)) try self.refreshTerminal(key);
        if (open_logs and self.progress.matches(key) and !self.progress.logs_expanded) self.progress.toggleLogs();
    }

    // Terminal progress carries bounded route/history arrays. Keep its stack
    // frame out of the SFTP presentation path.
    fn refreshTerminal(self: *Host, key: operations.OperationKey) !void {
        const current = self.workspace.connectionProgress(key) orelse {
            self.progress.hide();
            return;
        };
        if (current.cancelled and current.finished and current.cleanup == .released and !self.showingRetainedLogs(key)) {
            // The tab already owns the cancelled state. Keep the progress
            // journal available to connection details without retaining its modal.
            try self.workspace.dismissConnectionProgress(key);
            self.publishResultNotice(key, .cancelled);
            self.progress.hide();
            return;
        }
        if (current.attached) {
            const restore_focus = self.progress.matches(key);
            self.progress.hide();
            if (restore_focus and self.activeOwner() != null and key.owner == .session and self.activeOwner().?.eql(key.owner.session)) if (self.workspace.active_tab) |index| {
                const tab = self.workspace.tabs.items[index];
                if (tab.terminal) |*terminal| terminal.focus();
            };
            return;
        }
        var hops: [9]Progress.Hop = undefined;
        var logs: [128]Progress.LogRecord = undefined;
        for (current.logs[0..current.log_count], logs[0..current.log_count]) |record, *destination| destination.* = .{ .key = record.key, .entry = record.entry };
        for (current.hops[0..current.hop_count], hops[0..current.hop_count]) |hop, *destination| destination.* = .{ .name = hop.name, .host = hop.host, .user = hop.user, .port = hop.port };
        const state: Progress.State = if (current.cancelled) .cancelled else if (current.automatic_retry_pending) .retrying else if (current.failure != null or current.attachment_failed) .failed else if (current.journal.completed) (if (current.finished) .attaching else .protocol_ready) else if ((key.attempt_id orelse 1) > 1) .retrying else .connecting;
        const failure: ?Progress.Failure = if (current.failure != null or current.attachment_failed) .{
            .hop = if (current.journal.failure) |entry| entry.hop else null,
            .phase = if (current.journal.failure) |entry| entry.phase else null,
            .reason = if (current.failure) |err| Progress.failureText(err) else "终端接入失败",
        } else null;
        try self.progress.show(.{ .key = key, .hops = hops[0..current.hop_count], .journal = current.journal, .logs = logs[0..current.log_count], .dropped = current.dropped, .resources = current.resources, .state = state, .cleanup = current.cleanup, .attached = current.attached, .local_ready = true, .failure = failure });
        // A failure/cancellation is idle only after cleanup settles. Polling a
        // released result at 30 Hz keeps the failure modal and CPU active.
        if ((state != .failed and state != .cancelled) or current.cleanup == .not_started or current.cleanup == .releasing)
            self.cx.scheduleRedrawAfterNs(33 * std.time.ns_per_ms);
    }

    fn refreshAuthentication(self: *Host, pending: ?auth.Snapshot) !void {
        if (self.bridge.current) |prior| {
            const same = if (pending) |request| prior.identity.eql(request.identity) else false;
            if (!same) {
                // Drain any answer already accepted by the presenter before
                // selecting another request. Hidden owners keep their mailbox.
                const key = prior.identity.key;
                const observed = if (key.owner == .session) self.workspace.pendingAuthenticationFor(key.owner.session) else null;
                if (observed) |request| if (request.identity.eql(prior.identity)) {
                    try self.showAuthentication(request);
                    if (pending == null) return;
                };
                self.bridge.clear();
            }
        }
        if (pending) |request| {
            try self.showAuthentication(request);
            self.cx.scheduleRedrawAfterNs(33 * std.time.ns_per_ms);
        }
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

    fn refreshFile(self: *Host, key: operations.OperationKey) !bool {
        if (key.owner != .session) return false;
        const state = self.application.sessions.queryState(key.owner.session) orelse return false;
        if (!state.create_operation.eql(key)) return false;
        if (state.lifecycle == .attached or state.lifecycle == .closed or state.lifecycle == .ended) {
            self.application.dismissFileProgress(key);
            self.progress.hide();
            // Closing the modal restores the launcher's focus at the end of
            // the reactive batch. Focus the attached workspace after that.
            if (state.lifecycle == .attached) self.pending_file_focus = key.owner.session;
            return false;
        }
        const diagnostic = self.application.fileConnectionProgress(key) orelse return false;
        const source = try self.application.fileSource(key.owner.session, key);
        var reason: [1536]u8 = undefined;
        const fault = diagnostic.failure;
        if (state.lifecycle == .failed and state.create_cleanup == .released and fault == null and !self.showingRetainedLogs(key)) {
            self.application.dismissFileProgress(key);
            self.publishResultNotice(key, .cancelled);
            self.progress.hide();
            return true;
        }
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
        // File connections have the same terminal-result contract as SSH:
        // preserve cleanup polling, then let the retained diagnostic go idle.
        if ((fault == null and state.lifecycle != .failed) or state.create_cleanup == .not_started or state.create_cleanup == .releasing)
            self.cx.scheduleRedrawAfterNs(33 * std.time.ns_per_ms);
        return true;
    }

    fn prefillValid(raw: *anyopaque, window: u64, expires_ns: ?i128) bool {
        const self: *Host = @ptrCast(@alignCast(raw));
        const now = self.totp_clock.now();
        return now.unix_seconds / @import("../proto/ssh/totp.zig").period_seconds == window and (if (expires_ns) |expiry| now.monotonic_ns < expiry else true);
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
        if (self.workspace.connectionProgress(key)) |current| if (current.automatic_retry_pending) {
            const id = self.application.legacyForHandle(key.owner.session) orelse return;
            self.workspace.cancelSessionCreation(id);
        };
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
        if (self.showingRetainedLogs(key)) self.retained_logs = null;
        if (self.progress.source) |source| if (source.value.key.eql(key)) switch (source.value.state) {
            .failed => self.publishResultNotice(key, .failed),
            .cancelled => self.publishResultNotice(key, .cancelled),
            else => {},
        };
        self.application.dismissFileProgress(key);
        self.workspace.dismissConnectionProgress(key) catch {};
    }
    fn showingRetainedLogs(self: *Host, key: operations.OperationKey) bool {
        return if (self.retained_logs) |current| current.eql(key) else false;
    }
    fn publishResultNotice(self: *Host, key: operations.OperationKey, state: @import("remote_session_notice.zig").State) void {
        if (key.owner != .session) return;
        const id = self.application.legacyForHandle(key.owner.session) orelse return;
        const tab = self.workspace.sessionTab(id) orelse return;
        // Live reconnects use the runtime's own notice and lifecycle.
        if (tab.runtime != null) return;
        const notice = tab.remote_notice orelse return;
        notice.update(.{ .state = state });
        notice.bindLogs(.{ .context = self, .key = key, .show = showRetainedLogs });
    }
    fn showRetainedLogs(raw: *anyopaque, key: operations.OperationKey) void {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (key.owner != .session or self.workspace.overlayOwner(key.owner.session) == null) return;
        self.retained_logs = key;
        if (self.progress.matches(key) and !self.progress.logs_expanded) self.progress.toggleLogs();
        self.cx.requestRedraw();
    }
    fn copyLogs(raw: *anyopaque, key: operations.OperationKey, text: []const u8) !void {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (self.workspace.connectionProgress(key) == null and self.application.fileConnectionProgress(key) == null) return error.StaleConnection;
        if (!ui.platform_services.clipboardSetText(self.cx.system_sdk, text)) return error.ClipboardUnavailable;
    }
    fn cleanup(self: *Host) void {
        self.cx.removeAfterLayoutHook(self);
        self.challenges.unattached_owner = null;
        self.bridge.clear();
        self.workspace.authentication_ui_ready = false;
        // Each view owns its scope cleanup. Child input scopes may already be
        // disposed here, so do not call presentation methods during teardown.
        self.cx.allocator.destroy(self);
    }
};
