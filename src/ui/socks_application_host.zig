//! Main-window SOCKS presentation. Native Session/Listener pointers never leave
//! SocksRouteHost; this controller reads value snapshots and preserves owners.
const std = @import("std");
const ui = @import("ui");
const ws = @import("workspace.zig");
const Application = @import("application_host.zig").ApplicationHost;
const routes = @import("../host/socks_route_host.zig");
const sessions = @import("../host/session_host.zig");
const identity = @import("../host/identity.zig");
const operations = @import("../host/operation.zig");
const ssh = @import("../proto/ssh/session.zig");
const hosts = @import("../config/hosts.zig");
const Info = @import("socks_info_view.zig");
const Config = @import("socks_config_view.zig");
const Probe = @import("../proto/ssh/socks_proxy_probe.zig");
const applog = @import("../platform/applog.zig");
const Binding = struct { legacy: ws.SessionId, owner: identity.SessionHandle };

pub const Host = struct {
    allocator: std.mem.Allocator,
    cx: *ui.Cx,
    workspace: *ws.Workspace,
    application: *Application,
    backend: *routes.Host,
    previous_auth: ?ws.ExternalAuthentication = null,
    bindings: std.ArrayList(Binding) = .empty,
    auto_attempted: std.ArrayList(identity.SessionHandle) = .empty,
    chip_label: ?*ui.Node = null,
    chip: ?*ui.Node = null,
    info: ?*Info.View = null,
    info_owner: ?identity.SessionHandle = null,
    config: ?*Config.View = null,
    config_host_id: ?ws.HostId = null,
    config_session_id: ?ws.SessionId = null,
    exposure_owner: ?identity.SessionHandle = null,
    exposure_request_owner: ?identity.SessionHandle = null,
    exposure: ?*@import("socks_exposure_confirm.zig").View = null,
    exposure_for_start: bool = false,
    pending_start: ?ws.SessionId = null,
    pending_port: ?u16 = null,
    pending_restart: ?ws.SessionId = null,
    proxy_probe: ?*Probe.Job = null,
    probe_owner: ?identity.SessionHandle = null,
    probe_key: ?operations.OperationKey = null,
    probe_message: [160]u8 = undefined,
    probe_message_len: usize = 0,
    last_key: ?operations.OperationKey = null,
    last_phase: ?routes.Phase = null,

    /// Independent Library lifetime is pinned by the backend's real receipt.
    pub fn init(allocator: std.mem.Allocator, cx: *ui.Cx, workspace: *ws.Workspace, application: *Application, known_hosts_path: []const u8) !Host {
        _ = known_hosts_path;
        const tasks = application.domain.tasks orelse return error.TaskDomainUnavailable;
        return .{ .allocator = allocator, .cx = cx, .workspace = workspace, .application = application, .backend = &tasks.socks };
    }

    fn sharedForward(raw: *anyopaque, binding: sessions.ServiceHandle, exit_index: ?usize) !*@import("../proto/ssh/forward_service.zig").Service {
        const application: *Application = @ptrCast(@alignCast(raw));
        return application.sshForwardService(binding, exit_index);
    }
    pub fn bindAuthentication(self: *Host) void {
        self.previous_auth = self.workspace.external_auth;
        self.workspace.external_auth = .{ .context = self, .pending = pendingAuth, .submit = submitAuth, .cancel = cancelAuth, .host = authHost, .parent = authParent, .host_key = authHostKey, .totp = authTotp };
    }
    fn pendingAuth(raw: *anyopaque) ?routes.auth.Snapshot {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (self.previous_auth) |previous| if (previous.pending(previous.context)) |value| return value;
        return self.backend.pendingAuthentication();
    }
    fn submitAuth(raw: *anyopaque, request: routes.auth.RequestIdentity, reply: routes.auth.Reply) !void {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (self.backend.authenticationHostFor(request) != null) return self.backend.submitAuthentication(request, reply);
        if (self.previous_auth) |previous| return previous.submit(previous.context, request, reply);
        return error.StaleAuthentication;
    }
    fn cancelAuth(raw: *anyopaque, request: routes.auth.RequestIdentity) bool {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (self.backend.cancelAuthentication(request)) return true;
        return if (self.previous_auth) |previous| previous.cancel(previous.context, request) else false;
    }
    fn authHost(raw: *anyopaque, request: routes.auth.RequestIdentity) ?hosts.HostConfig {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (self.backend.authenticationHostFor(request)) |value| return value;
        return if (self.previous_auth) |previous| previous.host(previous.context, request) else null;
    }
    fn authParent(raw: *anyopaque, request: routes.auth.RequestIdentity) ?*ui.Node {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (self.backend.authenticationHostFor(request) != null) return self.workspace.terminal_area;
        return if (self.previous_auth) |previous| previous.parent(previous.context, request) else null;
    }
    fn authHostKey(raw: *anyopaque, request: routes.auth.RequestIdentity) ?routes.host_key.Request {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (self.backend.authenticationHostKey(request)) |value| return value;
        return if (self.previous_auth) |previous| previous.host_key(previous.context, request) else null;
    }
    fn authTotp(raw: *anyopaque, request: routes.auth.RequestIdentity, now: @import("../proto/ssh/totp_prefill.zig").Time) !?@import("../proto/ssh/totp_prefill.zig").Suggestion {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (self.previous_auth) |previous| if (previous.totp) |suggest| if (try suggest(previous.context, request, now)) |value| return value;
        return self.backend.authenticationTotp(request, now);
    }
    fn activeSession(self: *Host) ?ws.SessionId {
        const active = self.workspace.active_tab orelse return null;
        return self.workspace.tabs.items[active].id;
    }
    fn activeOwner(self: *Host) ?identity.SessionHandle {
        return self.application.ownerForLegacy(self.activeSession() orelse return null);
    }
    fn activeSnapshot(self: *Host) ?routes.Snapshot {
        return self.backend.snapshot(self.activeOwner() orelse return null);
    }
    fn configured(self: *Host, legacy: ws.SessionId) ?hosts.HostConfig {
        const tab = self.workspace.sessionTab(legacy) orelse return null;
        var host = (tab.host_snapshot orelse return null).value;
        if (!host.socks_enabled) {
            host.socks_port = self.workspace.app_config.ssh.socks_port;
            host.socks_bind = self.workspace.app_config.ssh.socks_bind;
        }
        return host;
    }
    pub fn hasLive(self: *Host, legacy: ws.SessionId) bool {
        for (self.bindings.items) |binding| if (binding.legacy == legacy) if (self.backend.snapshot(binding.owner)) |value| {
            if (value.cleanup != .released) return true;
        };
        return false;
    }
    /// Freeze the actual owner, physical binding, listener operation and
    /// effective configuration for close approvals. Traffic counters are not
    /// part of the approval identity: new relay bytes do not change intent.
    pub fn closeImpact(self: *Host, legacy: ws.SessionId) @import("group_close_controller.zig").Impact {
        var result: @import("group_close_controller.zig").Impact = .{};
        const owner = self.application.ownerForLegacy(legacy) orelse return result;
        const value = self.backend.snapshot(owner) orelse return result;
        if (value.cleanup == .released) return result;
        var hash = std.hash.Wyhash.init(0);
        hash.update(std.mem.asBytes(&owner.session_id));
        hash.update(std.mem.asBytes(&owner.generation));
        hash.update(std.mem.asBytes(&value.binding.binding_id));
        hash.update(std.mem.asBytes(&value.binding.binding_generation));
        hash.update(std.mem.asBytes(&value.key.operation_id));
        hash.update(std.mem.asBytes(&value.key.attempt_id));
        hash.update(std.mem.asBytes(&value.requested_port));
        hash.update(std.mem.asBytes(&value.local_port));
        hash.update(std.mem.asBytes(&value.bind127));
        hash.update(std.mem.asBytes(&value.max_connections));
        const selected = value.exit_index orelse std.math.maxInt(usize);
        hash.update(std.mem.asBytes(&selected));
        result.socks = hash.final();
        if (result.socks == 0) result.socks = 1;
        if (value.cleanup == .unknown) result.unknown = result.socks;
        var writer = std.Io.Writer.fixed(&result.detail);
        writer.print("SOCKS #{d} · {s}:{d} · {s} · 操作 {d}", .{ @backingInt(owner.session_id), if (value.bind127) "127.0.0.1" else "0.0.0.0", value.local_port, @tagName(value.phase), value.key.operation_id }) catch {};
        result.detail_len = writer.buffered().len;
        return result;
    }
    pub fn stopForSession(self: *Host, legacy: ws.SessionId) sessions.CloseReceipt {
        self.cancelProbeFor(legacy);
        var receipt: sessions.CloseReceipt = .released;
        for (self.bindings.items) |binding| if (binding.legacy == legacy) {
            const value = self.backend.requestStop(binding.owner);
            if (value == .unknown) receipt = .unknown else if (value == .awaiting and receipt == .released) receipt = .awaiting;
        };
        self.cx.scheduleRedrawAfterNs(20 * std.time.ns_per_ms);
        return receipt;
    }
    pub fn closeForSession(self: *Host, legacy: ws.SessionId) sessions.CloseReceipt {
        self.cancelProbeFor(legacy);
        var receipt: sessions.CloseReceipt = .released;
        if (self.application.ownerForLegacy(legacy)) |owner| receipt = self.backend.requestSessionClose(owner);
        for (self.bindings.items) |binding| if (binding.legacy == legacy) {
            const value = self.backend.requestSessionClose(binding.owner);
            if (value == .unknown) receipt = .unknown else if (value == .awaiting and receipt == .released) receipt = .awaiting;
        };
        self.cx.scheduleRedrawAfterNs(20 * std.time.ns_per_ms);
        return receipt;
    }
    fn cancelProbeFor(self: *Host, legacy: ws.SessionId) void {
        const owner = self.probe_owner orelse return;
        for (self.bindings.items) |binding| if (binding.legacy == legacy and binding.owner.eql(owner)) {
            if (self.proxy_probe) |probe| probe.cancel();
            self.probe_owner = null;
            self.probe_key = null;
            self.probe_message_len = 0;
            return;
        };
    }
    fn testProxy(self: *Host) void {
        const value = self.activeSnapshot() orelse {
            if (self.config) |view| view.setError("请先开启当前会话的转发");
            return;
        };
        if (value.phase != .ready or self.proxy_probe != null) return;
        const target = self.backend.exitHost(value.owner) orelse return;
        self.proxy_probe = Probe.Job.start(self.allocator, .{ .local_port = value.local_port, .target_host = target.host, .target_port = target.port }) catch |err| {
            self.workspace.status(@errorName(err));
            return;
        };
        self.probe_owner = value.owner;
        self.probe_key = value.key;
        self.probe_message_len = 0;
        self.cx.scheduleRedrawAfterNs(25 * std.time.ns_per_ms);
    }
    fn showConfig(self: *Host) void {
        const view = self.config orelse return;
        const legacy = self.activeSession() orelse return;
        const host = self.configured(legacy) orelse return;
        const owner = self.application.ownerForLegacy(legacy) orelse return;
        const tab = self.workspace.sessionTab(legacy) orelse return;
        self.exposure_for_start = false;
        self.config_host_id = tab.host_id;
        self.config_session_id = legacy;
        const hops = self.backend.sourceRoute(owner) catch return;
        var choices: [9]Config.Route = undefined;
        choices[0] = .{ .label = "链路末端", .index = null };
        for (hops, 0..) |hop, index| choices[index + 1] = .{ .label = if (hop.display_name.len == 0) hop.endpoint.host else hop.display_name, .index = index };
        view.setOwner(host.name, legacy);
        view.show(.{ .port = host.socks_port, .bind = host.socks_bind, .exit = host.socks_exit, .auto_start = host.socks_auto_start, .max_connections = host.socks_max_connections }, choices[0 .. hops.len + 1]) catch |err| view.setError(@errorName(err));
    }
    pub fn saveConfig(raw: *anyopaque, draft: Config.Draft) void {
        const self: *Host = @ptrCast(@alignCast(raw));
        const view = self.config orelse return;
        const legacy = self.config_session_id orelse return;
        const tab = self.workspace.sessionTab(legacy) orelse {
            view.setError("会话已关闭");
            return;
        };
        var host = self.configured(legacy) orelse return;
        host.socks_enabled = true;
        host.socks_port = draft.port;
        host.socks_bind = draft.bind;
        host.socks_exit = draft.exit;
        host.socks_auto_start = draft.auto_start;
        host.socks_max_connections = draft.max_connections;
        var next = @import("session_lifecycle.zig").Snapshot(hosts.HostConfig).init(self.allocator, host) catch {
            view.setError("内存不足");
            return;
        };
        if (draft.persist) {
            const index = self.workspace.hostIndex(self.config_host_id orelse {
                next.deinit();
                return;
            }) orelse {
                next.deinit();
                view.setError("主机配置已移除");
                return;
            };
            self.workspace.replaceHost(index, host) catch |err| {
                next.deinit();
                view.setError(@errorName(err));
                return;
            };
        }
        if (tab.host_snapshot) |*previous| previous.deinit();
        tab.host_snapshot = next;
        if (self.hasLive(legacy)) {
            self.pending_restart = legacy;
            _ = self.stopForSession(legacy);
        }
        view.hide();
        self.workspace.status(if (draft.persist) "转发配置已保存" else "转发配置已应用到当前会话");
    }
    pub fn testConfig(raw: *anyopaque, draft: Config.Draft) void {
        const self: *Host = @ptrCast(@alignCast(raw));
        const value = self.activeSnapshot() orelse {
            if (self.config) |view| view.setError("请先开启当前会话的转发");
            return;
        };
        if (value.phase != .ready or value.requested_port != draft.port or value.bind127 != std.mem.eql(u8, draft.bind, "127.0.0.1") or value.exit_index != draft.exit) {
            if (self.config) |view| view.setError("请先应用这组参数，再测试当前代理");
            return;
        }
        self.testProxy();
    }
    pub fn cancelConfig(raw: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (self.config) |view| view.hide();
    }
    pub fn confirmExposure(raw: *anyopaque, bind: []const u8) bool {
        const self: *Host = @ptrCast(@alignCast(raw));
        const owner = self.application.ownerForLegacy(self.config_session_id orelse return false) orelse return false;
        if (self.exposure_owner) |approved| if (approved.eql(owner)) return true;
        self.exposure_request_owner = owner;
        if (self.exposure) |view| view.show(bind) catch {};
        return false;
    }
    pub fn exposureConfirmed(raw: *anyopaque, _: []const u8) void {
        const self: *Host = @ptrCast(@alignCast(raw));
        const requested = self.exposure_request_owner orelse return;
        const current = self.application.ownerForLegacy(self.config_session_id orelse return) orelse return;
        if (!requested.eql(current)) return;
        self.exposure_owner = requested;
        self.exposure_request_owner = null;
        if (self.exposure_for_start) {
            self.exposure_for_start = false;
            const legacy = self.pending_start orelse return;
            const port = self.pending_port;
            self.pending_start = null;
            self.pending_port = null;
            self.startLegacy(legacy, port);
        } else if (self.config) |view| view.act(view.pending_action);
    }
    pub fn exposureCancelled(raw: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(raw));
        self.pending_start = null;
        self.pending_port = null;
        self.exposure_for_start = false;
        self.exposure_request_owner = null;
    }
    pub fn showInfo(self: *Host) void {
        const info = self.info orelse return;
        self.info_owner = self.activeOwner() orelse return;
        self.updateInfo();
        if (self.chip) |chip| info.showNode(chip);
    }
    fn infoOwnerIsCurrent(self: *Host) bool {
        const opened = self.info_owner orelse return false;
        const current = self.activeOwner() orelse return false;
        return opened.eql(current);
    }
    fn updateInfo(self: *Host) void {
        const info = self.info orelse return;
        if (!self.infoOwnerIsCurrent()) {
            info.hide();
            self.info_owner = null;
            return;
        }
        const host = self.configured(self.activeSession() orelse return) orelse return;
        const value = self.activeSnapshot();
        const stats: routes.listener.Stats = if (value) |snapshot| snapshot.stats else .{};
        const exit = if (value) |snapshot| self.backend.exitHost(snapshot.owner) else null;
        const state: Info.State = if (value) |snapshot| switch (snapshot.phase) {
            .ready => .running,
            .connecting => .connecting,
            .paused, .closing => .paused,
            .failed, .cleanup_unknown => .failed,
            .closed => if (snapshot.failure != null) .failed else .off,
        } else .off;
        info.update(.{
            .state = state,
            .session_id = self.activeSession(),
            .port = if (value) |snapshot| if (snapshot.local_port != 0) snapshot.local_port else host.socks_port else host.socks_port,
            .host = host.name,
            .exit = if (exit) |target| target.name else host.name,
            .bind = if (value) |snapshot| if (snapshot.bind127) "127.0.0.1" else "0.0.0.0" else host.socks_bind,
            .connections = stats.connections_active,
            .uploaded = stats.bytes_up,
            .downloaded = stats.bytes_down,
            .error_text = if (value) |snapshot| if (snapshot.failure) |err| @errorName(err) else "" else "",
            .test_result = if (value != null and self.probe_key != null and value.?.key.eql(self.probe_key.?)) self.probe_message[0..self.probe_message_len] else "",
        }) catch {};
    }
    pub fn infoAction(raw: *anyopaque, action: Info.Action) void {
        const self: *Host = @ptrCast(@alignCast(raw));
        // A retained card must never retarget its controls after a tab switch
        // or a reconnect changes the session generation.
        if (!self.infoOwnerIsCurrent()) {
            if (self.info) |info| info.hide();
            self.info_owner = null;
            return;
        }
        switch (action) {
            .start => self.commandToggle(null),
            .stop => _ = self.stopForSession(self.activeSession() orelse return),
            .config => self.showConfig(),
            .test_proxy => self.testProxy(),
            .copy_export => {
                const value = self.activeSnapshot() orelse return;
                if (value.phase != .ready) return;
                var buffer: [128]u8 = undefined;
                const command = std.fmt.bufPrint(&buffer, "export ALL_PROXY=socks5://127.0.0.1:{d}", .{value.local_port}) catch return;
                _ = ui.platform_services.clipboardSetText(self.cx.system_sdk, command);
            },
        }
        self.updateInfo();
    }
    pub fn commandToggle(self: *Host, requested_port: ?u16) void {
        const legacy = self.activeSession() orelse return;
        if (self.activeSnapshot()) |value| if (value.cleanup != .released) {
            _ = self.stopForSession(legacy);
            if (value.cleanup == .unknown) _ = self.backend.retryCleanup(value.owner) catch {};
            return;
        };
        self.startLegacy(legacy, requested_port);
    }
    fn startLegacy(self: *Host, legacy: ws.SessionId, requested_port: ?u16) void {
        var host = self.configured(legacy) orelse {
            self.workspace.status("当前会话不支持网络转发");
            return;
        };
        const owner = self.application.ownerForLegacy(legacy) orelse return;
        if (requested_port) |port| host.socks_port = port;
        if (!std.mem.eql(u8, host.socks_bind, "127.0.0.1") and !std.mem.eql(u8, host.socks_bind, "0.0.0.0")) {
            self.workspace.status("转发绑定地址无效");
            return;
        }
        const exposed = if (self.exposure_owner) |approved| approved.eql(owner) else false;
        if (!std.mem.eql(u8, host.socks_bind, "127.0.0.1") and !exposed) {
            self.pending_start = legacy;
            self.pending_port = requested_port;
            self.config_session_id = legacy;
            self.exposure_request_owner = owner;
            self.exposure_for_start = true;
            if (self.exposure) |view| view.show(host.socks_bind) catch {};
            return;
        }
        self.backend.options.presentation = if (self.workspace.app_config.ssh.otp_modal) .otp_modal else .protected_form;
        self.backend.options.presentation_config_revision = self.workspace.app_config.config_revision;
        self.backend.options.totp_autofill = self.workspace.app_config.ssh.totp_autofill;
        self.backend.options.timeout_ms = @as(u32, self.workspace.app_config.ssh.connect_timeout_sec) * 1000;
        self.bindings.ensureUnusedCapacity(self.allocator, 1) catch return;
        _ = self.backend.start(owner, .{ .exit_index = host.socks_exit, .listener = .{ .requested_port = host.socks_port, .bind127 = std.mem.eql(u8, host.socks_bind, "127.0.0.1"), .exposure_confirmed = exposed, .max_connections = host.socks_max_connections } }) catch |err| {
            self.workspace.status(@errorName(err));
            return;
        };
        var recorded = false;
        for (self.bindings.items) |binding| if (binding.owner.eql(owner)) {
            recorded = true;
            break;
        };
        if (!recorded) self.bindings.appendAssumeCapacity(.{ .legacy = legacy, .owner = owner });
        var attempted = false;
        for (self.auto_attempted.items) |previous| if (previous.eql(owner)) {
            attempted = true;
            break;
        };
        if (!attempted) self.auto_attempted.append(self.allocator, owner) catch {};
        self.workspace.status("正在开启 SOCKS5 转发…");
        self.cx.scheduleRedrawAfterNs(20 * std.time.ns_per_ms);
    }
    pub fn refreshChip(self: *Host) void {
        const label = self.chip_label orelse return;
        var buffer: [64]u8 = undefined;
        const text = if (self.activeSnapshot()) |value| switch (value.phase) {
            .ready => std.fmt.bufPrint(&buffer, "🧦 SOCKS5 :{d} ● {d}", .{ value.local_port, value.stats.connections_active }) catch "🧦 SOCKS5",
            .connecting => "🧦 SOCKS5 …",
            .paused => std.fmt.bufPrint(&buffer, "🧦 :{d} ◌ 已暂停", .{value.local_port}) catch "🧦 已暂停",
            .failed, .cleanup_unknown => "🧦 SOCKS5 ✕",
            .closing => "🧦 SOCKS5",
            .closed => if (value.failure != null) "🧦 SOCKS5 ✕" else "🧦 SOCKS5",
        } else "🧦 SOCKS5";
        label.setTextContent(self.allocator, text) catch return;
        label.markRenderDirty();
    }
    fn poll(self: *Host) void {
        const active = self.backend.safeTick() catch |err| blk: {
            applog.warn(.ui, "SOCKS5 owner tick: {s}", .{@errorName(err)});
            break :blk true;
        };
        // Reconnect advances the domain generation while the native facade
        // and local port persist. Close gestures bind to the new real owner.
        for (self.workspace.tabs.items) |tab| if (self.application.ownerForLegacy(tab.id)) |owner| if (self.backend.snapshot(owner)) |value| {
            var recorded = false;
            for (self.bindings.items) |binding| if (binding.owner.eql(value.owner)) {
                recorded = true;
                break;
            };
            if (!recorded) self.bindings.append(self.allocator, .{ .legacy = tab.id, .owner = value.owner }) catch {};
        };
        if (self.pending_restart) |legacy| if (!self.hasLive(legacy)) {
            self.pending_restart = null;
            self.startLegacy(legacy, null);
        };
        if (self.proxy_probe) |probe| {
            if (probe.poll()) |result| {
                const value = if (self.probe_owner) |owner| self.backend.snapshot(owner) else null;
                const current = value != null and self.probe_key != null and value.?.key.eql(self.probe_key.?) and value.?.phase == .ready;
                if (current) {
                    const succeeded = result.status == .succeeded;
                    const text = std.fmt.bufPrint(&self.probe_message, "{s} · {d} ms", .{ if (succeeded) "SOCKS CONNECT 成功" else if (result.failure) |err| @errorName(err) else "SOCKS CONNECT 失败", result.elapsed_ms }) catch "";
                    self.probe_message_len = text.len;
                    if (self.config) |view| if (view.visible) if (succeeded) view.setSuccess(text) else view.setError(text);
                }
                probe.deinit();
                self.proxy_probe = null;
            } else self.cx.scheduleRedrawAfterNs(25 * std.time.ns_per_ms);
        }
        if (!self.backend.shutting_down) for (self.workspace.tabs.items) |tab| {
            const host = self.configured(tab.id) orelse continue;
            if (!host.socks_auto_start) continue;
            const owner = self.application.ownerForLegacy(tab.id) orelse continue;
            var attempted = false;
            for (self.auto_attempted.items) |previous| if (previous.eql(owner)) {
                attempted = true;
                break;
            };
            if (attempted) continue;
            if (self.application.sessions.queryService(owner, .forward) != .available) continue;
            self.auto_attempted.append(self.allocator, owner) catch continue;
            self.startLegacy(tab.id, null);
        };
        if (self.activeSnapshot()) |value| {
            if (self.last_key == null or !self.last_key.?.eql(value.key) or self.last_phase == null or self.last_phase.? != value.phase) {
                if (value.phase == .ready) self.workspace.status("SOCKS5 转发已开启") else if (value.phase == .closed) self.workspace.status(if (value.failure) |err| @errorName(err) else "SOCKS5 转发已停止");
                self.last_key = value.key;
                self.last_phase = value.phase;
            }
        }
        self.refreshChip();
        if (self.info) |view| if (view.root.style.display != .none) self.updateInfo();
        if (active or self.pending_restart != null) self.cx.scheduleRedrawAfterNs(40 * std.time.ns_per_ms);
    }
    pub fn hookRun(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Host = @ptrCast(@alignCast(raw));
        self.poll();
        return .done;
    }
    pub fn cleanup(self: *Host) void {
        self.cx.removeAfterLayoutHook(self);
        if (self.workspace.external_auth) |external| {
            if (external.context == @as(*anyopaque, self)) self.workspace.external_auth = self.previous_auth;
        }
        if (self.proxy_probe) |probe| probe.deinit();
        self.proxy_probe = null;
        // The process domain owns listeners, authentication bridges and SSH
        // Library. A window only releases its presentation and local probe.
        self.bindings.deinit(self.allocator);
        self.auto_attempted.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};
