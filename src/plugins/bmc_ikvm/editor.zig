//! BMC fields and actions inside the existing connection editor slot. The
//! Wizard owns its Modal, protocol picker, child SSH editor and persistence.
const std = @import("std");
const ui = @import("ui");
const contract = @import("../../host/plugin_ui_contract.zig");
const content = @import("../../host/content_context.zig");
const envelopes = @import("../../config/connection_envelope.zig");
const identity = @import("../../host/identity.zig");
const probes = @import("../../host/probe_contract.zig");
const model = @import("model.zig");
const draft_mod = @import("editor_model.zig");
const S = @import("editor_styles.zig");

const scale_options = [_]ui.widgets.SelectOption{
    .{ .value = "fit", .label = "适应窗口", .test_id = "bmc.editor.scale.fit" },
    .{ .value = "original", .label = "原始比例 100%", .test_id = "bmc.editor.scale.original" },
};
const auth_options = [_]ui.widgets.checkbox.RadioOption{
    .{ .value = "password", .label = "密码", .test_id = "bmc.editor.auth.password" },
};
const Pending = enum { save, save_and_open, temporary, probe, cancel, child };
const RouteAction = enum { up, down, remove };
const RouteHandler = struct {
    editor: *EditorView,
    index: usize,
    action: RouteAction = .remove,
    fn select(self: *RouteHandler, text: ?[]const u8) void {
        const editor = self.editor;
        const value = parseId(text orelse return, "conn:") catch return;
        const old = editor.draft.?.revision;
        editor.draft.?.replaceHop(self.index, @fromBackingInt(value)) catch |err| return editor.reportError(err);
        editor.changed(old);
    }
    fn click(self: *RouteHandler) void {
        const editor = self.editor;
        const old = editor.draft.?.revision;
        (switch (self.action) {
            .up => editor.draft.?.moveHop(self.index, true),
            .down => editor.draft.?.moveHop(self.index, false),
            .remove => editor.draft.?.removeHop(self.index),
        }) catch |err| return editor.reportError(err);
        editor.changed(old);
    }
};

pub const EditorView = struct {
    mount: contract.EditorMount,
    draft: ?draft_mod.Editor = null,
    arena: ?std.heap.ArenaAllocator = null,
    root: ?*ui.Node = null,
    body: ?*ui.Node = null,
    footer: ?*ui.Node = null,
    scroll: ?ui.widgets.ScrollAreaResult = null,
    pending_focus: ?usize = null,
    feedback_area: ?*ui.Node = null,
    message: ?*ui.Node = null,
    log_button: ?*ui.Node = null,
    log_open: ?*ui.Signal(bool) = null,
    log_modal: ?ui.widgets.ModalResult = null,
    log_scroll: ?ui.widgets.ScrollAreaResult = null,
    log_status: ?*ui.Node = null,
    log_entries: ?*ui.Node = null,
    log_render_revision: u64 = 0,
    route_preview: ?*ui.Node = null,
    route_editor: ?*ui.Node = null,
    asset_filter_field: ?*ui.Node = null,
    asset_filter: ?*ui.Signal([]const u8) = null,
    options_key: ?u64 = null,
    advanced: ?*ui.Node = null,
    advanced_open: bool = false,
    inputs: [4]?ui.widgets.input.InputResult = @splat(null),
    errors: [4]?*ui.Signal([]const u8) = @splat(null),
    name_value: ?*ui.Signal([]const u8) = null,
    host_value: ?*ui.Signal([]const u8) = null,
    port_value: ?*ui.Signal([]const u8) = null,
    username_value: ?*ui.Signal([]const u8) = null,
    password_value: ?*ui.Signal([]const u8) = null,
    password_input: ?ui.widgets.input.InputResult = null,
    save_password: ?*ui.Signal(bool) = null,
    read_only: ?*ui.Signal(bool) = null,
    scale_value: ?*ui.Signal(?[]const u8) = null,
    group_value: ?*ui.Signal(?[]const u8) = null,
    group_options: ?*ui.Signal([]const ui.widgets.SelectOption) = null,
    locked: ?*ui.Signal(bool) = null,
    probe_running: ?*ui.Signal(bool) = null,
    probe_label: ?*ui.Signal([]const u8) = null,
    add_disabled: ?*ui.Signal(bool) = null,
    route_values: [8]?*ui.Signal(?[]const u8) = @splat(null),
    route_options: [8]?*ui.Signal([]const ui.widgets.SelectOption) = @splat(null),
    route_rows: [8]?*ui.Node = @splat(null),
    route_up_disabled: [8]?*ui.Signal(bool) = @splat(null),
    route_down_disabled: [8]?*ui.Signal(bool) = @splat(null),
    access_styles: [2]?*ui.Signal(ui.BoxStyle) = @splat(null),
    access_highlights: [2]?*ui.Node = @splat(null),
    access_nodes: [2]?*ui.Node = @splat(null),
    access_titles: [2]?*ui.Node = @splat(null),
    selects: std.ArrayList(ui.widgets.SelectResult) = .empty,
    pending: ?Pending = null,
    probe: draft_mod.ProbeState = .{},
    probe_log: draft_mod.ProbeLog = .{},
    child_request: ?u64 = null,
    hidden: bool = false,
    hook_registered: bool = false,

    pub fn deinit(self: *EditorView) void {
        self.release();
    }
    fn release(self: *EditorView) void {
        if (self.draft == null) return;
        if (self.hook_registered) self.mount.cx.removeAfterLayoutHook(self);
        self.hook_registered = false;
        if (self.mount.editor_host) |host| host.destroyParent(self.mount.editor_id) else if (self.probesFacade()) |facade| facade.destroy();
        if (comptime @hasField(contract.EditorMount, "credentials")) if (self.mount.credentials) |credentials| credentials.clear();
        self.draft.?.deinit();
        self.draft = null;
        self.probe = .{};
        self.probe_log = .{};
        self.pending = null;
        self.child_request = null;
        self.access_highlights = @splat(null);
        self.access_nodes = @splat(null);
        self.access_titles = @splat(null);
        self.root = null;
        self.body = null;
        self.footer = null;
        self.scroll = null;
        self.feedback_area = null;
        self.message = null;
        self.log_button = null;
        self.log_open = null;
        self.log_modal = null;
        self.log_scroll = null;
        self.log_status = null;
        self.log_entries = null;
        self.route_preview = null;
        self.password_input = null;
        self.inputs = @splat(null);
        self.selects.deinit(self.mount.cx.allocator);
        self.selects = .empty;
        if (self.arena) |*arena| arena.deinit();
        self.arena = null;
    }
    fn alloc(self: *EditorView) std.mem.Allocator {
        return self.arena.?.allocator();
    }
    fn queue(self: *EditorView, pending: Pending) void {
        if (self.draft == null or self.pending != null) return;
        self.pending = pending;
        self.mount.cx.requestRedraw();
    }
    fn save(self: *EditorView) void {
        self.queue(.save);
    }
    fn saveAndOpen(self: *EditorView) void {
        self.queue(.save_and_open);
    }
    fn temporary(self: *EditorView) void {
        self.queue(.temporary);
    }
    fn testConnection(self: *EditorView) void {
        if (self.probe.token != null) {
            self.cancelProbe();
        } else self.queue(.probe);
    }
    fn cancelClicked(self: *EditorView) void {
        self.queue(.cancel);
    }
    fn child(self: *EditorView) void {
        self.queue(.child);
    }
    fn nameChanged(self: *EditorView, text: []const u8) void {
        self.textChanged(.name, text);
    }
    fn hostChanged(self: *EditorView, text: []const u8) void {
        self.textChanged(.host, text);
    }
    fn usernameChanged(self: *EditorView, text: []const u8) void {
        self.textChanged(.username, text);
    }
    fn textChanged(self: *EditorView, text_field: draft_mod.TextField, text: []const u8) void {
        const old = self.draft.?.revision;
        self.draft.?.setText(text_field, text) catch |err| return self.reportError(err);
        self.changed(old);
    }
    fn portChanged(self: *EditorView, text: []const u8) void {
        const old = self.draft.?.revision;
        const port = std.fmt.parseInt(u16, text, 10) catch 0;
        self.draft.?.setPort(port) catch |err| return self.reportError(err);
        self.changed(old);
    }
    fn passwordChanged(self: *EditorView, text: []const u8) void {
        const old = self.draft.?.revision;
        self.draft.?.setPassword(text) catch |err| return self.reportError(err);
        self.changed(old);
    }
    fn savePasswordChanged(self: *EditorView, value: bool) void {
        const old = self.draft.?.revision;
        self.draft.?.setSavePassword(value) catch |err| return self.reportError(err);
        self.changed(old);
    }
    fn readOnlyChanged(self: *EditorView, value: bool) void {
        const old = self.draft.?.revision;
        self.draft.?.setReadOnly(value) catch |err| return self.reportError(err);
        self.changed(old);
    }
    fn scaleChanged(self: *EditorView, value: ?[]const u8) void {
        const scale = std.meta.stringToEnum(model.Scale, value orelse return) orelse return;
        const old = self.draft.?.revision;
        self.draft.?.setScale(scale) catch |err| return self.reportError(err);
        self.changed(old);
    }
    fn groupChanged(self: *EditorView, value: ?[]const u8) void {
        const text = value orelse "none";
        const group: ?identity.AssetGroupId = if (std.mem.eql(u8, text, "none")) null else @fromBackingInt(parseId(text, "group:") catch return);
        const old = self.draft.?.revision;
        self.draft.?.setGroup(group) catch |err| return self.reportError(err);
        self.changed(old);
    }
    fn assetFilterChanged(self: *EditorView, _: []const u8) void {
        self.refreshRoutes() catch |err| self.reportError(err);
    }
    fn direct(self: *EditorView) void {
        self.access(false);
    }
    fn routed(self: *EditorView) void {
        self.access(true);
    }
    fn access(self: *EditorView, value: bool) void {
        const old = self.draft.?.revision;
        self.draft.?.setAccess(value) catch |err| return self.reportError(err);
        self.changed(old);
    }
    fn addHop(self: *EditorView) void {
        const resolver = self.mount.connection_configs orelse return self.feedback("暂无可用的 SSH 配置，请先新建 SSH 主机");
        for (resolver.registry.hosts) |host| {
            if (!std.mem.eql(u8, host.protocolId(), "ssh") or self.draft.?.containsHop(@backingInt(host.connection_id), null)) continue;
            var resolved = resolver.resolve(host.connection_id, "ssh", self.mount.cx.allocator) catch continue;
            resolved.deinit();
            const old = self.draft.?.revision;
            self.draft.?.addHop(host.connection_id) catch |err| return self.reportError(err);
            self.changed(old);
            return;
        }
        self.feedback("没有其他可用的 SSH 配置，可新建 SSH 主机后加入路径");
    }
    fn toggleAdvanced(self: *EditorView) void {
        self.advanced_open = !self.advanced_open;
        self.advanced.?.setDisplay(if (self.advanced_open) .flex else .none);
        self.mount.cx.requestRedraw();
    }
    fn changed(self: *EditorView, previous_revision: u64) void {
        const draft = &self.draft.?;
        if (draft.revision == previous_revision) return;
        const had_result = self.probe_log.count != 0;
        self.probe_log.invalidate(draft.revision);
        self.probe.invalidate();
        if (self.probe.token != null) self.cancelProbe();
        for (self.errors) |maybe| if (maybe) |error_signal| error_signal.set("");
        if (had_result) self.feedback("配置已更改，上次测试记录仅供参考，请重新测试");
        self.refreshProbeLog();
        if (self.mount.editor_host) |host| host.setParentRevision(self.mount.editor_id, draft.revision) catch |err| self.reportError(err);
        if (self.mount.credentials) |credentials| credentials.setDraftRevision(draft.revision) catch |err| self.reportError(err);
        if (self.probesFacade()) |facade| facade.setDraftRevision(draft.revision) catch |err| self.reportError(err);
        self.mount.events.changed(self.mount.events.context);
        self.refreshRoutes() catch |err| self.reportError(err);
    }
    fn feedback(self: *EditorView, message: []const u8) void {
        if (self.message) |node| {
            if (node.getText()) |old| if (std.mem.eql(u8, old.content, message)) return;
            node.setTextContent(self.mount.cx.allocator, message) catch {};
        }
        self.mount.cx.requestRedraw();
    }
    fn reportError(self: *EditorView, err: anyerror) void {
        const message: []const u8 = switch (err) {
            error.MissingName => "请输入连接名称",
            error.InvalidEndpoint => if (self.draft != null and self.draft.?.https_port == 0) "HTTPS 端口应为 1–65535" else "请输入有效的 BMC 地址，不包含协议或路径",
            error.InvalidUsername => "请输入有效的 BMC 用户名",
            error.MissingSshReference => "请选择至少一个 SSH 跳板，或切换为直连",
            error.MissingRouteReference, error.ConnectionNotFound => "路径中的 SSH 资产已不存在，请重新选择",
            error.DuplicateRoute, error.DuplicateEndpoint => "SSH 路径不能包含重复主机或地址",
            error.TooManyJumps => "SSH 路径最多包含 8 跳",
            error.ConfigurationResolverUnavailable => "SSH 资产列表暂不可用",
            error.GroupNotFound => "资产分组已不存在，请重新选择",
            error.ProbeInProgress => "上次测试仍在释放资源，请稍后再试",
            error.EditorCredentialsUnavailable => "安全凭据服务尚未就绪，请稍后重试",
            error.EditorSecretSubmitUnavailable => "安全保存入口尚未就绪，请稍后重试",
            error.CredentialDenied, error.CredentialLocked => "密码存储访问被拒绝，草稿已保留",
            error.CredentialStorageFailure => "密码保存失败，草稿已保留",
            else => "操作未完成，配置草稿已保留",
        };
        const field_index: ?usize = switch (err) {
            error.MissingName => 0,
            error.InvalidEndpoint => if (self.draft != null and self.draft.?.https_port == 0) 2 else 1,
            error.InvalidUsername => 3,
            else => null,
        };
        if (field_index) |i| {
            if (self.errors[i]) |signal| signal.set(message);
            self.pending_focus = i;
        }
        self.feedback(message);
    }
    fn clearSecrets(self: *EditorView) void {
        if (self.draft == null) return;
        if (self.draft) |*draft| draft.clearSecrets();
        // Overwrite both owned text-signal buffers before publishing empty.
        // Input is intentionally bounded at 2048 bytes, like the shared form.
        if (self.password_value) |signal| {
            const zeros: [2048]u8 = @splat(0);
            const overwritten: [2048]u8 = @splat(1);
            self.mount.cx.owner.beginBatch();
            signal.set(&zeros);
            signal.set(&overwritten);
            signal.set(&zeros);
            signal.set("");
            self.mount.cx.owner.endBatch();
        }
        if (self.password_input) |input| {
            input.state.clearUndoHistory();
            std.crypto.secureZero(u8, &input.state.buffer);
            _ = input.state.setText("");
            input.state.cancelImeComposition();
        }
        if (comptime @hasField(contract.EditorMount, "credentials")) if (self.mount.credentials) |credentials| credentials.clear();
    }
    fn cancelProbe(self: *EditorView) void {
        const token = self.probe.token orelse return;
        self.probe.cancel();
        self.probe_log.cancel();
        self.refreshProbeLog();
        const facade = self.probesFacade() orelse return;
        _ = facade.cancel(token) catch {};
        self.feedback("正在取消管理连接测试并释放资源");
    }
    fn pollProbe(self: *EditorView) void {
        if (self.draft == null) return;
        const token = self.probe.token orelse return;
        const facade = self.probesFacade() orelse return;
        var probe_snapshot = facade.snapshot(token, self.mount.cx.allocator) catch {
            self.probe_log.unavailable();
            self.refreshProbeLog();
            self.feedback(if (self.probe_log.stale) "正在等待上次测试释放状态；此记录仅供参考" else "正在等待管理测试状态，配置草稿已保留");
            self.mount.cx.scheduleRedrawAfterNs(100 * std.time.ns_per_ms);
            return;
        };
        defer probe_snapshot.deinit();
        self.probe_log.observe(probe_snapshot.value);
        self.refreshProbeLog();
        const current = self.probe.apply(probe_snapshot.value, self.draft.?.revision);
        if (current) {
            if (probe_snapshot.value.complete) {
                self.feedback(switch (probe_snapshot.value.outcome orelse .failed) {
                    .succeeded => "管理连接测试成功：已验证 SSH / TLS、BMC 登录与资源发现；未打开视频",
                    .failed => if (probe_snapshot.value.safe_message.len != 0) probe_snapshot.value.safe_message else "管理连接测试失败，配置草稿已保留",
                    .cancelled => "管理连接测试已取消，配置草稿已保留",
                });
            } else self.feedback(if (probe_snapshot.value.cleanup == .unknown) stageLabel(probe_snapshot.value.stage, .unknown) else if (probe_snapshot.value.safe_message.len != 0) probe_snapshot.value.safe_message else stageLabel(probe_snapshot.value.stage, probe_snapshot.value.cleanup));
        } else if (self.probe_log.stale) {
            self.feedback(if (self.probe.token != null) "配置已更改，上次测试正在释放资源；日志仅供参考" else "配置已更改，上次测试已结束；请重新测试当前配置");
        } else if (self.probe.cancelled) {
            if (self.probe.token != null) {
                var buffer: [192]u8 = undefined;
                self.feedback(std.fmt.bufPrint(&buffer, "正在取消管理测试并释放资源 · 总计 {d} 秒", .{self.probe_log.elapsed_seconds}) catch "正在取消管理测试并释放资源");
            } else self.feedback("管理连接测试已取消，配置草稿已保留");
        }
        self.probe_running.?.set(self.probe.token != null);
        self.probe_label.?.set(if (self.probe.token != null) "取消测试" else "测试连接");
        if (self.probe.token != null) self.mount.cx.scheduleRedrawAfterNs(100 * std.time.ns_per_ms);
    }
    fn showProbeLog(self: *EditorView) void {
        if (self.draft == null or self.probe_log.count == 0) return;
        self.refreshProbeLog();
        self.log_open.?.set(true);
        self.mount.cx.requestRedraw();
    }
    fn closeProbeLog(self: *EditorView) void {
        if (self.log_open) |open| open.set(false);
    }
    fn refreshProbeLog(self: *EditorView) void {
        if (self.draft == null or self.probe_log.revision == self.log_render_revision) return;
        self.log_render_revision = self.probe_log.revision;
        if (self.log_button) |node| node.setDisplay(if (self.probe_log.count == 0) .none else .flex);
        var status_buffer: [192]u8 = undefined;
        const status = std.fmt.bufPrint(&status_buffer, "第 {d} 次测试 · {s}", .{ self.probe_log.attempt, if (self.probe_log.stale) @as([]const u8, "旧草稿（仅供参考）") else "当前草稿" }) catch "管理测试记录";
        if (self.log_status) |node| node.setTextContent(self.mount.cx.allocator, status) catch {};
        var entries_buffer: [8192]u8 = undefined;
        if (self.log_entries) |node| node.setTextContent(self.mount.cx.allocator, self.probe_log.format(&entries_buffer)) catch {};
        self.mount.cx.requestRedraw();
    }
    fn submit(self: *EditorView, intent: contract.SubmitIntent) !void {
        const draft = &self.draft.?;
        if (intent == .temporary or intent == .probe) try draft.validateRuntime(self.mount.connection_configs, self.mount.cx.allocator) else try draft.validateOffline(self.mount.connection_configs, self.mount.cx.allocator);
        if (intent == .probe) return self.beginProbe();
        var arena: std.heap.ArenaAllocator = .init(self.mount.cx.allocator);
        defer arena.deinit();
        if (comptime @hasField(contract.EditorMount, "credentials")) {
            const credentials = self.mount.credentials orelse return error.EditorCredentialsUnavailable;
            errdefer credentials.clear();
            const callback = self.mount.events.submit_with_secret orelse return error.EditorSecretSubmitUnavailable;
            const only_removing_saved_password = intent == .save and !draft.save_password;
            const staged = try credentials.prepare(if (!only_removing_saved_password and draft.password.len != 0) draft.password else null, if (only_removing_saved_password) null else draft.credential_ref, if (intent == .temporary) false else draft.save_password);
            const reference: ?[]const u8 = if (staged.reference) |*ref| ref else null;
            const value = if (intent == .temporary) try draft.snapshotRuntime(arena.allocator(), reference) else try draft.snapshotWithReference(arena.allocator(), reference);
            const handoff = try credentials.handoff(staged);
            try callback(self.mount.events.context, value, intent, handoff);
        } else {
            // Older hosts remain useful for non-secret offline configurations.
            // A typed password must never silently disappear into JSON.
            if (draft.password.len != 0 or (!draft.save_password and draft.credential_ref != null)) return error.EditorCredentialsUnavailable;
            const value = if (intent == .temporary) try draft.snapshotRuntime(arena.allocator(), null) else try draft.snapshot(arena.allocator());
            try self.mount.events.submit(self.mount.events.context, value, intent);
        }
        self.clearSecrets();
        // The host owns the single save/open notification and closes its shell.
    }
    fn beginProbe(self: *EditorView) !void {
        if (self.probe.token != null) return error.ProbeInProgress;
        const facade = self.probesFacade() orelse return error.ProbeUnavailable;
        var arena: std.heap.ArenaAllocator = .init(self.mount.cx.allocator);
        defer arena.deinit();
        var value = try self.draft.?.snapshotRuntime(arena.allocator(), null);
        if (comptime @hasField(contract.EditorMount, "credentials")) {
            const credentials = self.mount.credentials orelse return error.EditorCredentialsUnavailable;
            errdefer credentials.clear();
            const draft = &self.draft.?;
            const staged = try credentials.prepare(if (draft.password.len != 0) draft.password else null, draft.credential_ref, false);
            value = try draft.snapshotRuntime(arena.allocator(), if (staged.reference) |*reference| reference else null);
            try credentials.forProbe(staged);
        } else if (self.draft.?.password.len != 0) return error.EditorCredentialsUnavailable;
        const token = facade.begin(value, self.draft.?.revision) catch |err| {
            if (self.mount.credentials) |credentials| credentials.clear();
            return err;
        };
        try self.probe.begin(token);
        self.probe_log.begin(token);
        self.refreshProbeLog();
        self.probe_running.?.set(true);
        self.probe_label.?.set("取消测试");
        self.feedback("正在测试 SSH / TLS、BMC 管理登录与资源发现；不会打开视频");
        self.mount.cx.scheduleRedrawAfterNs(100 * std.time.ns_per_ms);
    }
    fn openChild(self: *EditorView) !void {
        if (self.child_request != null) return error.ChildEditorAlreadyOpen;
        const host = self.mount.editor_host orelse return error.ChildEditorUnavailable;
        self.clearSecrets();
        self.child_request = try host.openChild(self.mount.editor_id, self.draft.?.revision, "ssh", .create);
    }
    fn childCompleted(raw: *anyopaque, completion: content.ChildCompletion) void {
        const self: *EditorView = @ptrCast(@alignCast(raw));
        if (self.draft == null or completion.request.parent_editor_id != self.mount.editor_id or self.child_request != completion.request.request_id) return;
        self.child_request = null;
        // Cancellation/failure never change the non-secret parent draft.
        if (completion.request.draft_revision != self.draft.?.revision) return;
        switch (completion.result) {
            .saved => |saved| {
                const resolver = self.mount.connection_configs orelse return self.reportError(error.ConfigurationResolverUnavailable);
                const old = self.draft.?.revision;
                _ = self.draft.?.applyChild(completion.request.draft_revision, saved.asset_id, resolver) catch |err| return self.reportError(err);
                self.changed(old);
                self.feedback("SSH 主机已创建并加入路径");
            },
            .cancelled => self.feedback("已返回 BMC 草稿，未创建 KVM 资产"),
            .failed => self.feedback("SSH 主机未保存，BMC 草稿已保留"),
        }
        self.refreshGroups() catch {};
        self.refreshRoutes() catch {};
    }
    fn tick(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *EditorView = @ptrCast(@alignCast(raw));
        if (self.draft == null) return .done;
        const compact = self.mount.cx.viewport.width <= 860 or self.mount.cx.viewport.height <= 480;
        const body_padding: ui.Padding = if (compact) .{ .left = 18, .right = 34, .bottom = 12 } else .{ .left = 24, .right = 40, .bottom = 20 };
        const footer_padding: ui.Padding = if (compact) .{ .left = 18, .right = 18, .top = 10, .bottom = 10 } else .{ .left = 24, .right = 24, .top = 14, .bottom = 14 };
        const footer_height: f32 = if (compact) 54 else 62;
        const feedback_padding: ui.Padding = .{ .left = if (compact) 18 else 24, .right = if (compact) 18 else 24, .top = 4, .bottom = 4 };
        var geometry_changed = false;
        if (self.pending_focus) |index| {
            self.pending_focus = null;
            if (self.inputs[index]) |input| {
                self.mount.cx.setFocus(input.input_container);
                if (self.scroll) |scroll| {
                    scroll.state.content_height = scroll.content.globalRect().h;
                    scroll.state.viewport_height = scroll.container.globalRect().h;
                    ui.widgets.scrollIntoView(scroll.state, scroll.content, input.input_container, .nearest);
                }
                geometry_changed = true;
            }
        }
        if (self.body) |body| if (!std.meta.eql(body.style.padding, body_padding)) {
            body.setStyleInline(self.mount.cx.allocator, .{ .padding = body_padding });
            geometry_changed = true;
        };
        if (self.footer) |footer| if (footer.style.height != .px or footer.style.height.px != footer_height or !std.meta.eql(footer.style.padding, footer_padding)) {
            footer.setStyleInline(self.mount.cx.allocator, .{ .height = .{ .px = footer_height }, .padding = footer_padding });
            geometry_changed = true;
        };
        if (self.feedback_area) |area| if (!std.meta.eql(area.style.padding, feedback_padding)) {
            area.setStyleInline(self.mount.cx.allocator, .{ .padding = feedback_padding });
            geometry_changed = true;
        };
        if (self.child_request) |request_id| if (self.mount.editor_host) |host| {
            var pending_child = false;
            for (host.pending.items) |request| if (request.request_id == request_id) {
                pending_child = true;
                break;
            };
            if (!pending_child) self.child_request = null;
        };
        if (self.pending) |pending| {
            self.pending = null;
            self.locked.?.set(true);
            defer if (self.draft != null) self.locked.?.set(false);
            switch (pending) {
                .cancel => {
                    self.cancelProbe();
                    self.clearSecrets();
                    if (self.mount.events.cancelled) |cancelled| cancelled(self.mount.events.context) else if (self.mount.events.dismiss) |dismiss| dismiss(self.mount.events.context);
                },
                .child => self.openChild() catch |err| self.reportError(err),
                else => self.submit(switch (pending) {
                    .save => .save,
                    .save_and_open => .save_and_open,
                    .temporary => .temporary,
                    .probe => .probe,
                    else => unreachable,
                }) catch |err| self.reportError(err),
            }
        }
        self.pollProbe();
        return if (geometry_changed) .needs_layout else .done;
    }
    fn probesFacade(self: *EditorView) ?probes.EditorProbes {
        if (comptime @hasField(contract.EditorMount, "probes")) return self.mount.probes;
        return if (self.mount.editor_host) |host| host.probes else null;
    }
    fn refreshGroups(self: *EditorView) !void {
        var options: std.ArrayList(ui.widgets.SelectOption) = .empty;
        const a = self.alloc();
        try options.append(a, .{ .value = "none", .label = "未分组", .test_id = "bmc.editor.group.none" });
        if (self.mount.connection_configs) |resolver| for (resolver.registry.groups) |group| {
            try options.append(a, .{ .value = try std.fmt.allocPrint(a, "group:{d}", .{@backingInt(group.group_id)}), .label = try a.dupe(u8, group.name), .test_id = try std.fmt.allocPrint(a, "bmc.editor.group.{d}", .{@backingInt(group.group_id)}) });
        };
        self.group_options.?.set(try options.toOwnedSlice(a));
        self.group_value.?.set(if (self.draft.?.group_id) |id| try std.fmt.allocPrint(a, "group:{d}", .{@backingInt(id)}) else "none");
    }
    fn refreshRoutes(self: *EditorView) !void {
        const draft = &self.draft.?;
        const a = self.alloc();
        self.route_editor.?.setDisplay(if (draft.routed) .flex else .none);
        for (self.access_styles, 0..) |style, i| {
            const selected = draft.routed == (i == 1);
            var value = S.host.accessChoice(selected);
            value.height = .{ .px = 61 };
            style.?.set(.{ .width = value.width, .height = value.height, .flex = value.flex, .min_width = value.min_width, .flex_shrink = value.flex_shrink, .background = value.background, .border = .{ .radius = 8 }, .padding = .{} });
            self.access_highlights[i].?.setDisplay(if (selected) .flex else .none);
            self.access_titles[i].?.setTextColor(if (selected) S.theme.current().accent_ink else S.theme.current().fg_1);
            if (self.access_nodes[i].?.behavior.interaction.a11y) |*a11y| a11y.pressed = selected;
        }
        var hash = std.hash.Wyhash.init(0);
        if (self.mount.connection_configs) |resolver| hash.update(std.mem.asBytes(&resolver.registry.revision));
        hash.update(std.mem.asBytes(&draft.route_count));
        hash.update(std.mem.sliceAsBytes(draft.route[0..draft.route_count]));
        hash.update(self.asset_filter.?.peek());
        const options_key = hash.final();
        const update_options = self.options_key == null or self.options_key.? != options_key;
        if (update_options) self.options_key = options_key;
        var ssh_count: usize = 0;
        if (self.mount.connection_configs) |resolver| for (resolver.registry.hosts) |host| {
            if (std.mem.eql(u8, host.protocolId(), "ssh")) ssh_count += 1;
        };
        self.asset_filter_field.?.setDisplay(if (ssh_count > 64) .flex else .none);
        for (0..8) |i| {
            self.route_rows[i].?.setDisplay(if (i < draft.route_count) .flex else .none);
            self.route_up_disabled[i].?.set(i == 0);
            self.route_down_disabled[i].?.set(i + 1 >= draft.route_count);
            if (update_options) {
                var options: std.ArrayList(ui.widgets.SelectOption) = .empty;
                if (self.mount.connection_configs) |resolver| {
                    const ids = try draft_mod.visibleSshAssets(resolver, self.asset_filter.?.peek(), if (i < draft.route_count) @fromBackingInt(@intCast(draft.route[i].asset_id)) else null, a);
                    for (ids) |id| {
                        const host = resolver.registry.hosts[resolver.registry.indexOf(id).?];
                        try options.append(a, .{
                            .value = try std.fmt.allocPrint(a, "conn:{d}", .{@backingInt(id)}),
                            .label = try std.fmt.allocPrint(a, "{s} · {s}:{d}", .{ host.name, host.host, host.port }),
                            .disabled = draft.containsHop(@backingInt(id), i),
                            .test_id = try std.fmt.allocPrint(a, "bmc.editor.route.{d}.asset.{d}", .{ i, @backingInt(id) }),
                        });
                    }
                }
                self.route_options[i].?.set(try options.toOwnedSlice(a));
            }
            self.route_values[i].?.set(if (i < draft.route_count) try std.fmt.allocPrint(a, "conn:{d}", .{draft.route[i].asset_id}) else null);
        }
        self.add_disabled.?.set(draft.route_count >= 8);
        var writer: std.Io.Writer.Allocating = .init(a);
        try writer.writer.writeAll("本机");
        if (draft.routed) for (draft.route[0..draft.route_count]) |hop| {
            const label = blk: {
                const resolver = self.mount.connection_configs orelse break :blk "未解析的 SSH 主机";
                const index = resolver.registry.indexOf(@fromBackingInt(hop.asset_id)) orelse break :blk "已删除的 SSH 主机";
                break :blk resolver.registry.hosts[index].name;
            };
            try writer.writer.print(" → {s}", .{label});
        };
        try writer.writer.print(" → {s}:{d} · BMC", .{ if (draft.host.len == 0) "目标主机" else draft.host, draft.https_port });
        try self.route_preview.?.setTextContent(self.mount.cx.allocator, writer.written());
    }
    fn snapshot(raw: *anyopaque, allocator: std.mem.Allocator) !envelopes.Envelope {
        const self: *EditorView = @ptrCast(@alignCast(raw));
        const draft = if (self.draft) |*value| value else return error.EditorClosed;
        try draft.validateOffline(self.mount.connection_configs, allocator);
        return draft.snapshot(allocator);
    }
    fn clear(raw: *anyopaque) void {
        const self: *EditorView = @ptrCast(@alignCast(raw));
        self.clearSecrets();
    }
    fn unmount(raw: *anyopaque) void {
        const self: *EditorView = @ptrCast(@alignCast(raw));
        self.release();
    }
    fn cancel(raw: *anyopaque) void {
        const self: *EditorView = @ptrCast(@alignCast(raw));
        self.queue(.cancel);
    }
    fn presentation(raw: *anyopaque) contract.ModalPresentation {
        const self: *EditorView = @ptrCast(@alignCast(raw));
        return .{ .width = S.width, .title = if (self.draft != null and @backingInt(self.draft.?.asset_id) != 0) "编辑连接" else "新建连接" };
    }
    fn preferredHeight(raw: *anyopaque) ?f32 {
        const self: *EditorView = @ptrCast(@alignCast(raw));
        if (self.draft == null) return null;
        if (self.mount.cx.viewport.width <= 860 or self.mount.cx.viewport.height <= 480) return 400;
        // Natural direct-form reference 590.5; route and options add content
        // inside its bounded ScrollArea, while footer remains reachable.
        return @min(S.host.max_height, 590.5 + (if (self.draft.?.routed) @as(f32, 94) else 0) + (if (self.advanced_open) @as(f32, 67.5) else 0));
    }
    fn parentVisible(raw: *anyopaque) bool {
        const self: *EditorView = @ptrCast(@alignCast(raw));
        return self.child_request == null;
    }
    fn visibility(raw: *anyopaque, visible: bool) void {
        const self: *EditorView = @ptrCast(@alignCast(raw));
        self.hidden = !visible;
        if (!visible) {
            self.closeProbeLog();
            self.cancelProbe();
            self.clearSecrets();
        }
    }
};

pub fn mountEditor(_: ?*anyopaque, mount: contract.EditorMount) !contract.EditorInstance {
    if (!std.mem.eql(u8, mount.protocol_id, model.protocol_id)) return error.ProtocolMismatch;
    if (mount.draft_revision == 0) return error.InvalidEditor;
    const cx = mount.cx;
    const scope = mount.scope;
    const self = try cx.bindState(EditorView, .{ .mount = mount });
    self.draft = draft_mod.Editor.init(cx.allocator, mount.draft_revision);
    self.draft.?.save_password = mount.save_password_by_default;
    self.arena = .init(cx.allocator);
    try scope.onCleanup(EditorView, self, EditorView.release);
    if (mount.initial) |initial| try self.draft.?.load(initial);
    if (mount.editor_host) |host| {
        try host.setParentRevision(mount.editor_id, mount.draft_revision);
        try host.setParentDelivery(mount.editor_id, self, EditorView.childCompleted);
    }
    self.locked = try scope.createSignal(bool, false);
    self.probe_running = try scope.createSignal(bool, false);
    self.probe_label = try scope.createText("测试连接", .{});
    self.log_open = try scope.createSignal(bool, false);
    self.asset_filter = try scope.createText("", .{});
    self.add_disabled = try scope.createSignal(bool, false);
    self.name_value = try scope.createText(self.draft.?.name, .{});
    self.host_value = try scope.createText(self.draft.?.host, .{});
    self.username_value = try scope.createText(self.draft.?.username, .{});
    self.port_value = try scope.createText(try std.fmt.allocPrint(self.alloc(), "{d}", .{self.draft.?.https_port}), .{});
    self.password_value = try scope.createText("", .{ .capacity = 2048 });
    self.save_password = try scope.createSignal(bool, self.draft.?.save_password);
    self.read_only = try scope.createSignal(bool, self.draft.?.read_only_requested);
    self.scale_value = try scope.createSignal(?[]const u8, @tagName(self.draft.?.scale));
    self.group_value = try scope.createSignal(?[]const u8, null);
    self.group_options = try scope.createList(ui.widgets.SelectOption, &.{});
    for (&self.errors) |*error_signal| error_signal.* = try scope.createText("", .{});
    const root = try ui.boxStyled(cx, S.root, .{});
    root.meta.ownership.meta.test_id = "bmc.editor";
    try mount.slot.appendChild(cx.allocator, root);
    self.root = root;
    const scroll = try ui.widgets.ScrollArea(.{}).mount(scope, cx);
    scroll.container.meta.ownership.meta.test_id = "bmc.editor.scroll";
    const body = try ui.boxStyled(cx, S.content, .{});
    try scroll.content.appendChild(cx.allocator, body);
    try root.appendChild(cx.allocator, scroll.container);
    self.scroll = scroll;
    self.body = body;
    if (mount.protocol_picker) |picker| try body.appendChild(cx.allocator, try picker.mount(picker.context, cx, scope));
    try section(self, body, "连接信息");
    const identity_row = try ui.boxStyled(cx, S.row, .{});
    self.inputs[0] = try field(self, identity_row, "连接名称", "bmc.editor.name", self.name_value.?, "例如：compute-bmc-01", self.errors[0], EditorView.nameChanged);
    const group_field = try fieldBox(self, identity_row, "资产分组");
    const group = try ui.widgets.Select(.{ .options = self.group_options.?, .value = self.group_value.?, .width = 340, .disabled = self.locked.?, .on_change = cx.on(EditorView, self, EditorView.groupChanged) }).mount(scope, cx);
    try skinSelect(self, group, "bmc.editor.group");
    try group_field.appendChild(cx.allocator, group.wrapper);
    try body.appendChild(cx.allocator, identity_row);
    const endpoint_row = try ui.boxStyled(cx, S.row, .{});
    self.inputs[1] = try field(self, endpoint_row, "BMC 地址", "bmc.editor.host", self.host_value.?, "bmc.example.internal", self.errors[1], EditorView.hostChanged);
    self.inputs[2] = try field(self, endpoint_row, "HTTPS 端口", "bmc.editor.port", self.port_value.?, "443", self.errors[2], EditorView.portChanged);
    try body.appendChild(cx.allocator, endpoint_row);
    const auth_row = try ui.boxStyled(cx, S.row, .{});
    self.inputs[3] = try field(self, auth_row, "用户名", "bmc.editor.username", self.username_value.?, "BMC 用户名", self.errors[3], EditorView.usernameChanged);
    const auth_field = try fieldBox(self, auth_row, "认证方式");
    const auth = try ui.widgets.RadioGroup(.{ .options = &auth_options, .value = @as(?[]const u8, "password"), .horizontal = true, .disabled = self.locked.?, .focus_ring = S.host.radioFocus() }).mount(scope, cx);
    auth.setStyleInline(cx.allocator, .{ .height = .{ .px = 34 }, .align_items = .center });
    auth.addBeforeRender(paintActionTypography);
    try auth_field.appendChild(cx.allocator, auth);
    try body.appendChild(cx.allocator, auth_row);
    const password_row = try ui.boxStyled(cx, S.row, .{});
    password_row.setStyleInline(cx.allocator, .{ .align_items = .end });
    const password_field = try fieldBox(self, password_row, "密码");
    const password = try ui.widgets.Input(.{ .value = self.password_value.?, .input_type = @as(ui.widgets.input.InputType, .password), .placeholder = if (self.draft.?.credential_ref != null) "已保存，留空保持原密码" else "可留空，连接时再输入", .disabled = self.locked.?, .on_change = cx.on(EditorView, self, EditorView.passwordChanged) }).mountResult(scope, cx);
    skinInput(self, password, "bmc.editor.password");
    try password_field.appendChild(cx.allocator, password.node);
    self.password_input = password;
    const remember = try ui.widgets.Checkbox(.{ .label = "保存密码", .box_size = @as(f32, 14), .label_font_size = @as(f32, 11), .checked = self.save_password.?, .disabled = self.locked.?, .focus_ring = S.host.radioFocus(), .on_change = cx.on(EditorView, self, EditorView.savePasswordChanged) }).mount(scope, cx);
    remember.meta.ownership.meta.test_id = "bmc.editor.save_password";
    remember.setStyleInline(cx.allocator, S.savePassword(cx.tokens));
    remember.addBeforeRender(paintCheckboxTypography);
    try password_row.appendChild(cx.allocator, remember);
    try body.appendChild(cx.allocator, password_row);
    try section(self, body, "连接路径");
    const access = try ui.boxStyled(cx, S.row, .{});
    try accessChoice(self, access, 0, "从本机直接连接", "本机 → BMC", "bmc.editor.access.direct", EditorView.direct);
    try accessChoice(self, access, 1, "经 SSH 跳板连接", "通过有序跳板访问目标", "bmc.editor.access.ssh", EditorView.routed);
    try body.appendChild(cx.allocator, access);
    const routes = try ui.boxStyled(cx, S.host.stack, .{});
    self.route_editor = routes;
    const search_field = try ui.boxStyled(cx, S.field, .{});
    self.asset_filter_field = search_field;
    _ = try field(self, search_field, "搜索已保存的 SSH 主机", "bmc.editor.route.search", self.asset_filter.?, "输入名称或地址以筛选全部 SSH 资产", null, EditorView.assetFilterChanged);
    try routes.appendChild(cx.allocator, search_field);
    for (0..8) |i| {
        const row = try ui.boxStyled(cx, S.routeRow, .{});
        self.route_rows[i] = row;
        row.meta.ownership.meta.test_id = try std.fmt.allocPrint(self.alloc(), "bmc.editor.route.{d}", .{i});
        const number = try ui.boxStyled(cx, S.routeNumber, .{});
        try number.appendChild(cx.allocator, try ui.text(cx, try std.fmt.allocPrint(self.alloc(), "{d}", .{i + 1}), S.host.text(11, 500, false)));
        try row.appendChild(cx.allocator, number);
        self.route_values[i] = try scope.createSignal(?[]const u8, null);
        self.route_options[i] = try scope.createList(ui.widgets.SelectOption, &.{});
        const handler = try scope.createState(RouteHandler, .{ .editor = self, .index = i });
        const picker = try ui.widgets.Select(.{ .options = self.route_options[i].?, .value = self.route_values[i].?, .placeholder = "选择已保存的 SSH 主机", .width = 500, .searchable = true, .disabled = self.locked.?, .on_change = cx.on(RouteHandler, handler, RouteHandler.select) }).mount(scope, cx);
        try skinSelect(self, picker, try std.fmt.allocPrint(self.alloc(), "bmc.editor.route.{d}.select", .{i}));
        picker.wrapper.setStyleInline(cx.allocator, .{ .flex = 1 });
        try row.appendChild(cx.allocator, picker.wrapper);
        self.route_up_disabled[i] = try scope.createSignal(bool, true);
        self.route_down_disabled[i] = try scope.createSignal(bool, true);
        inline for (.{ RouteAction.up, RouteAction.down, RouteAction.remove }, .{ ui.icons.arrow_up, ui.icons.arrow_down, ui.icons.x }, .{ "上移跳板", "下移跳板", "删除跳板" }) |kind, icon, label| {
            const action_handler = try scope.createState(RouteHandler, .{ .editor = self, .index = i, .action = kind });
            const disabled: ui.Source(bool) = if (kind == .up) .{ .signal = self.route_up_disabled[i].? } else if (kind == .down) .{ .signal = self.route_down_disabled[i].? } else .{ .signal = self.locked.? };
            const node = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = icon, .icon_size = @as(f32, 14), .icon_tint = S.theme.current().fg_2, .a11y_label = label, .disabled = disabled, .base_style = S.routeAction(cx.tokens), .on_click = cx.on(RouteHandler, action_handler, RouteHandler.click) }).mount(scope, cx);
            node.meta.ownership.meta.test_id = try std.fmt.allocPrint(self.alloc(), "bmc.editor.route.{d}.{s}", .{ i, @tagName(kind) });
            try row.appendChild(cx.allocator, node);
        }
        try routes.appendChild(cx.allocator, row);
    }
    const route_actions = try ui.boxStyled(cx, S.row, .{});
    try button(self, route_actions, "添加跳板", "bmc.editor.route.add", false, self.add_disabled.?, EditorView.addHop);
    try button(self, route_actions, "新建 SSH 主机", "bmc.editor.route.new_ssh", false, self.locked.?, EditorView.child);
    try routes.appendChild(cx.allocator, route_actions);
    try body.appendChild(cx.allocator, routes);
    const preview = try ui.boxStyled(cx, S.routePreview, .{});
    const preview_text = try ui.textStyled(cx, S.previewText, "");
    preview_text.meta.ownership.meta.test_id = "bmc.editor.route.preview";
    try preview.appendChild(cx.allocator, preview_text);
    self.route_preview = preview_text;
    try body.appendChild(cx.allocator, preview);
    try button(self, body, "高级选项", "bmc.editor.advanced", false, self.locked.?, EditorView.toggleAdvanced);
    const advanced = try ui.boxStyled(cx, S.row, .{});
    advanced.setDisplay(.none);
    self.advanced = advanced;
    const scale_field = try fieldBox(self, advanced, "显示比例");
    const scale = try ui.widgets.Select(.{ .options = &scale_options, .value = self.scale_value.?, .width = 340, .disabled = self.locked.?, .on_change = cx.on(EditorView, self, EditorView.scaleChanged) }).mount(scope, cx);
    try skinSelect(self, scale, "bmc.editor.scale");
    try scale_field.appendChild(cx.allocator, scale.wrapper);
    const read_only = try ui.widgets.Checkbox(.{ .label = "以只读模式进入", .box_size = @as(f32, 14), .label_font_size = @as(f32, 11), .checked = self.read_only.?, .disabled = self.locked.?, .focus_ring = S.host.radioFocus(), .on_change = cx.on(EditorView, self, EditorView.readOnlyChanged) }).mount(scope, cx);
    read_only.meta.ownership.meta.test_id = "bmc.editor.readonly";
    read_only.setStyleInline(cx.allocator, .{ .height = .{ .px = 34 }, .margin = .{ .top = 21.5 }, .flex = 1 });
    read_only.addBeforeRender(paintCheckboxTypography);
    try advanced.appendChild(cx.allocator, read_only);
    try body.appendChild(cx.allocator, advanced);
    const feedback_area = try ui.boxStyled(cx, S.feedbackArea, .{});
    feedback_area.meta.ownership.meta.test_id = "bmc.editor.feedback";
    self.message = try ui.textStyled(cx, S.feedback, if (mount.initial != null) "保存的修改在下次新建连接时生效" else "可离线保存；测试仅验证管理连接，打开控制台后才验证视频");
    self.message.?.setStyleInline(cx.allocator, .{ .flex = 1, .min_width = 0 });
    self.message.?.meta.ownership.meta.test_id = "bmc.editor.message";
    try feedback_area.appendChild(cx.allocator, self.message.?);
    const log_button = try ui.widgets.Button(.{ .label = "查看测试日志", .variant = .ghost, .base_style = S.logAction(), .on_click = cx.on(EditorView, self, EditorView.showProbeLog) }).mount(scope, cx);
    log_button.meta.ownership.meta.test_id = "bmc.editor.probe_log";
    log_button.addBeforeRender(paintLogActionTypography);
    log_button.setDisplay(.none);
    try feedback_area.appendChild(cx.allocator, log_button);
    try root.appendChild(cx.allocator, feedback_area);
    self.feedback_area = feedback_area;
    self.log_button = log_button;
    const footer = try ui.boxStyled(cx, S.footer, .{});
    footer.meta.ownership.meta.test_id = "bmc.editor.footer";
    try button(self, footer, "取消", "bmc.editor.cancel", false, self.locked.?, EditorView.cancelClicked);
    try footer.appendChild(cx.allocator, try ui.spacer(cx));
    try button(self, footer, "测试连接", "bmc.editor.probe", false, self.locked.?, EditorView.testConnection);
    try button(self, footer, "临时连接", "bmc.editor.temporary", false, self.locked.?, EditorView.temporary);
    try button(self, footer, "仅保存", "bmc.editor.save", false, self.locked.?, EditorView.save);
    try button(self, footer, "保存并连接", "bmc.editor.save_and_open", true, self.locked.?, EditorView.saveAndOpen);
    try root.appendChild(cx.allocator, footer);
    self.footer = footer;
    const log_modal = try ui.widgets.Modal(.{ .title = "管理测试日志", .open = self.log_open.?, .width = @as(f32, 560), .max_height = @as(f32, 420), .background = S.theme.current().overlay, .close_icon_asset = ui.icons.x, .enter_transition = .fade, .exit_transition = .fade }).mount(scope, cx);
    if (!log_modal.portaled) try root.appendChild(cx.allocator, log_modal.overlay);
    log_modal.dialog.meta.ownership.meta.test_id = "bmc.editor.log_modal";
    if (log_modal.dialog.children.items.len != 0) {
        const header = log_modal.dialog.children.items[0];
        if (header.children.items.len != 0) header.children.items[header.children.items.len - 1].meta.ownership.meta.test_id = "bmc.editor.log_close";
    }
    log_modal.body.setStyleInline(cx.allocator, S.logBody(cx.tokens));
    self.log_status = try ui.textStyled(cx, S.feedback, "");
    self.log_status.?.meta.ownership.meta.test_id = "bmc.editor.log_status";
    try log_modal.body.appendChild(cx.allocator, self.log_status.?);
    const log_scroll = try ui.widgets.ScrollArea(.{ .height = @as(f32, 200), .rubber_band_y = false }).mount(scope, cx);
    log_scroll.container.meta.ownership.meta.test_id = "bmc.editor.log_scroll";
    log_scroll.container.behavior.interaction.focusable = true;
    self.log_entries = try ui.textStyled(cx, S.logText, "");
    self.log_entries.?.meta.ownership.meta.test_id = "bmc.editor.log_entries";
    try log_scroll.content.appendChild(cx.allocator, self.log_entries.?);
    try log_modal.body.appendChild(cx.allocator, log_scroll.container);
    try log_modal.body.appendChild(cx.allocator, try ui.textStyled(cx, S.feedback, "仅显示最近 32 条脱敏阶段记录，关闭表单后清除。"));
    const log_actions = try ui.boxStyled(cx, S.row, .{});
    try log_actions.appendChild(cx.allocator, try ui.spacer(cx));
    const cancel_log_probe = try ui.widgets.Button(.{ .label = "取消测试", .variant = .ghost, .disabled = ui.not(self.probe_running.?), .base_style = S.action(false), .on_click = cx.on(EditorView, self, EditorView.cancelProbe) }).mount(scope, cx);
    cancel_log_probe.meta.ownership.meta.test_id = "bmc.editor.log_cancel_probe";
    cancel_log_probe.addBeforeRender(paintActionTypography);
    try log_actions.appendChild(cx.allocator, cancel_log_probe);
    try button(self, log_actions, "关闭", "bmc.editor.log_done", false, self.locked.?, EditorView.closeProbeLog);
    try log_modal.body.appendChild(cx.allocator, log_actions);
    self.log_modal = log_modal;
    self.log_scroll = log_scroll;
    try self.refreshGroups();
    try self.refreshRoutes();
    try cx.addAfterLayoutHook(self, EditorView.tick);
    self.hook_registered = true;
    return .{ .context = self, .vtable = &vtable, .handles_actions = true };
}

const vtable: contract.EditorInstance.VTable = .{
    .snapshot = EditorView.snapshot,
    .clear_secrets = EditorView.clear,
    .unmount = EditorView.unmount,
    .cancel = EditorView.cancel,
    .preferred_modal_height = EditorView.preferredHeight,
    .modal_presentation = EditorView.presentation,
    .parent_presentation_visible = EditorView.parentVisible,
    .visibility_changed = EditorView.visibility,
    .child_completed = EditorView.childCompleted,
};
fn parseId(text: []const u8, prefix: []const u8) !u64 {
    if (!std.mem.startsWith(u8, text, prefix)) return error.InvalidIdentity;
    const value = std.fmt.parseInt(u64, text[prefix.len..], 10) catch return error.InvalidIdentity;
    if (value == 0) return error.InvalidIdentity;
    return value;
}
fn stageLabel(stage: probes.Stage, cleanup: probes.CloseReceipt) []const u8 {
    if (cleanup == .unknown) return "管理测试资源仍待确认释放";
    return switch (stage) {
        .accepted => "测试已提交，等待独立连接",
        .transport => "正在验证 SSH 路径和目标 TLS",
        .trust => "等待核对目标身份",
        .authentication => "正在验证 BMC 管理认证",
        .discovery => "正在发现管理资源与能力；未打开视频",
        .cleanup, .finished => "测试结束，正在注销管理会话并释放连接",
    };
}
fn section(editor: *EditorView, parent: *ui.Node, label: []const u8) !void {
    const node = try ui.boxStyled(editor.mount.cx, S.section, .{});
    try node.appendChild(editor.mount.cx.allocator, try ui.textStyled(editor.mount.cx, S.sectionLabel, label));
    const line = try ui.box(editor.mount.cx, .{ .width = .fill(), .height = .{ .px = 1 }, .flex = 1, .background = S.theme.current().border }, .{});
    try node.appendChild(editor.mount.cx.allocator, line);
    try parent.appendChild(editor.mount.cx.allocator, node);
}
fn fieldBox(editor: *EditorView, parent: *ui.Node, label: []const u8) !*ui.Node {
    const node = try ui.boxStyled(editor.mount.cx, S.field, .{});
    try node.appendChild(editor.mount.cx.allocator, try ui.textStyled(editor.mount.cx, S.label, label));
    try parent.appendChild(editor.mount.cx.allocator, node);
    return node;
}
fn field(editor: *EditorView, parent: *ui.Node, label: []const u8, id: []const u8, value: *ui.Signal([]const u8), placeholder: []const u8, error_message: ?*ui.Signal([]const u8), comptime changed: *const fn (*EditorView, []const u8) void) !ui.widgets.input.InputResult {
    const box = try fieldBox(editor, parent, label);
    const input = try ui.widgets.Input(.{ .value = value, .placeholder = placeholder, .error_msg = if (error_message) |signal| ui.Source([]const u8){ .signal = signal } else ui.Source([]const u8){ .value = "" }, .disabled = editor.locked.?, .on_change = editor.mount.cx.on(EditorView, editor, changed) }).mountResult(editor.mount.scope, editor.mount.cx);
    skinInput(editor, input, id);
    try box.appendChild(editor.mount.cx.allocator, input.node);
    return input;
}
fn skinInput(editor: *EditorView, input: ui.widgets.input.InputResult, id: []const u8) void {
    S.theme.styleInput(input);
    input.node.setStyleInline(editor.mount.cx.allocator, S.inputSlot(editor.mount.cx.tokens));
    input.input_container.setStyleInline(editor.mount.cx.allocator, S.input(editor.mount.cx.tokens));
    input.input_container.meta.ownership.meta.test_id = id;
    input.state.font_size = 11;
    input.state.line_height = 16;
    input.state.padding_h = 0;
    input.state.char_width = 6.3;
    input.state.dirty = true;
    if (input.state.text_display_node) |text| text.addBeforeRender(paintInputTypography);
}
fn paintInputTypography(node: *ui.Node) void {
    if (node.getText()) |old| {
        if (old.font_size == 11 and old.line_height == 16.0 / 11.0) return;
        var text = old;
        text.font_size = 11;
        text.line_height = 16.0 / 11.0;
        node.setText(text);
    }
}
fn paintFieldTypography(node: *ui.Node) void {
    paintInputTypography(node);
    for (node.children.items) |child| paintFieldTypography(child);
}
fn paintActionTypography(node: *ui.Node) void {
    if (node.getText()) |old| {
        if (old.font_size != 12 or old.line_height != 1.5) {
            var text = old;
            text.font_size = 12;
            text.line_height = 1.5;
            node.setText(text);
        }
    }
    for (node.children.items) |child| paintActionTypography(child);
}
fn paintLogActionTypography(node: *ui.Node) void {
    if (node.getText()) |old| {
        const color = S.theme.current().accent;
        if (old.font_size != 11 or old.line_height != 17.0 / 11.0 or !std.meta.eql(old.color, color)) {
            var text = old;
            text.font_size = 11;
            text.line_height = 17.0 / 11.0;
            text.color = color;
            node.setText(text);
        }
    }
    for (node.children.items) |child| paintLogActionTypography(child);
}
fn paintCheckboxTypography(node: *ui.Node) void {
    if (node.getText()) |old| {
        if (old.font_size != 11 or old.line_height != 1.5) {
            var text = old;
            text.font_size = 11;
            text.line_height = 1.5;
            node.setText(text);
        }
    }
    for (node.children.items) |child| paintCheckboxTypography(child);
}
fn skinSelect(editor: *EditorView, result: ui.widgets.SelectResult, id: []const u8) !void {
    const allocator = editor.mount.cx.allocator;
    result.wrapper.setStyleInline(allocator, .{ .width = .fill(), .min_width = 0, .height = .{ .px = 34 }, .flex_shrink = 0 });
    result.trigger.setStyleInline(allocator, S.input(editor.mount.cx.tokens));
    result.trigger.meta.ownership.meta.test_id = id;
    result.trigger.addBeforeRender(if (std.mem.startsWith(u8, id, "bmc.editor.route.")) paintActionTypography else paintFieldTypography);
    if (result.trigger.parent) |wrapper| wrapper.setStyleInline(allocator, .{ .width = .fill(), .min_width = 0 });
    result.chrome.setStyleInline(allocator, .{ .padding = ui.Padding.all(5), .gap = 0, .border = .{ .radius = 10, .width = 0 }, .background = S.theme.current().overlay });
    result.panel.setStyleInline(allocator, .{ .gap = 0 });
    result.panel.addBeforeRender(paintActionTypography);
    try editor.selects.append(allocator, result);
}
fn button(editor: *EditorView, parent: *ui.Node, label: []const u8, id: []const u8, primary: bool, disabled: *ui.Signal(bool), comptime clicked: *const fn (*EditorView) void) !void {
    const cx = editor.mount.cx;
    const label_source: ui.Source([]const u8) = if (std.mem.eql(u8, id, "bmc.editor.probe")) .{ .signal = editor.probe_label.? } else .{ .value = label };
    const node = try ui.widgets.Button(.{ .label = label_source, .variant = @as(ui.widgets.ButtonVariant, if (primary) .primary else .ghost), .disabled = disabled, .base_style = S.action(primary), .on_click = cx.on(EditorView, editor, clicked) }).mount(editor.mount.scope, cx);
    node.meta.ownership.meta.test_id = id;
    node.addBeforeRender(paintActionTypography);
    try parent.appendChild(cx.allocator, node);
}
fn accessChoice(editor: *EditorView, parent: *ui.Node, index: usize, title: []const u8, detail: []const u8, id: []const u8, comptime clicked: *const fn (*EditorView) void) !void {
    const cx = editor.mount.cx;
    const base = try editor.mount.scope.createSignal(ui.BoxStyle, .{ .width = .fill(), .height = .{ .px = 61 }, .flex = 1, .min_width = 0, .flex_shrink = 0, .padding = .{}, .background = S.theme.popupInset(), .border = .{ .radius = 8 } });
    editor.access_styles[index] = base;
    const node = try ui.widgets.Button(.{ .a11y_label = title, .variant = .ghost, .disabled = editor.locked.?, .base_style = base, .on_click = cx.on(EditorView, editor, clicked) }).mount(editor.mount.scope, cx);
    node.meta.ownership.meta.test_id = id;
    const highlight = try ui.boxStyled(cx, S.accessSelection, .{});
    highlight.meta.ownership.meta.test_id = try std.fmt.allocPrint(editor.alloc(), "{s}.selected", .{id});
    try node.appendChild(cx.allocator, highlight);
    editor.access_highlights[index] = highlight;
    editor.access_nodes[index] = node;
    const heading = try ui.text(cx, title, S.host.text(12, 600, false));
    editor.access_titles[index] = heading;
    heading.setStyleInline(cx.allocator, .{ .position = .absolute, .inset = .{ .left = .{ .px = 14 }, .top = .{ .px = 12 }, .right = .{ .px = 14 } }, .height = .{ .px = 18 } });
    const subtitle = try ui.text(cx, detail, S.host.text(10, 400, false));
    subtitle.setStyleInline(cx.allocator, .{ .position = .absolute, .inset = .{ .left = .{ .px = 14 }, .top = .{ .px = 34 }, .right = .{ .px = 14 } }, .height = .{ .px = 15 } });
    try node.appendChild(cx.allocator, heading);
    try node.appendChild(cx.allocator, subtitle);
    try parent.appendChild(cx.allocator, node);
}

test "BMC editor mounting API is analysed" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(EditorView);
}
