//! BMC fields and actions inside the existing connection editor slot. The
//! Wizard owns its Modal, protocol picker, child SSH editor and persistence.
const std = @import("std");
const ui = @import("ui");
const scoped_modal = @import("../../ui/scoped_modal.zig");
const contract = @import("../../host/plugin_ui_contract.zig");
const content = @import("../../host/content_context.zig");
const envelopes = @import("../../config/connection_envelope.zig");
const identity = @import("../../host/identity.zig");
const probes = @import("../../host/probe_contract.zig");
const model = @import("model.zig");
const draft_mod = @import("editor_model.zig");
const probe_feedback = @import("probe_feedback.zig");
const S = @import("editor_styles.zig");
const Stepper = @import("../../ui/connection_stepper.zig");
const Review = @import("../../ui/connection_review.zig");
const route_view = @import("../remote/route_view.zig");
const route_hop = @import("../remote/route_hop_control.zig");
const RoutePicker = @import("../remote/route_picker.zig").RoutePicker;

const scale_options = [_]ui.widgets.SelectOption{
    .{ .value = "fit", .label = "适应窗口", .test_id = "bmc.editor.scale.fit" },
    .{ .value = "original", .label = "原始比例 100%", .test_id = "bmc.editor.scale.original" },
};
const Pending = enum { save, save_and_open, temporary, probe, cancel, child };
const FeedbackTone = enum { neutral, running, ok, warn, err };
const ActionKind = enum { back, cancel, probe, next, temporary, save, save_and_open };
const FooterButton = struct {
    kind: ActionKind,
    node: *ui.Node,
    style: *ui.Signal(ui.BoxStyle),
    label: *ui.Node,
    icon: ?*ui.Node = null,
    trailing_icon: bool = false,
    disabled: *ui.Signal(bool),
};

pub const EditorView = struct {
    mount: contract.EditorMount,
    draft: ?draft_mod.Editor = null,
    arena: ?std.heap.ArenaAllocator = null,
    options_arena: ?std.heap.ArenaAllocator = null,
    root: ?*ui.Node = null,
    body: ?*ui.Node = null,
    stepper: ?*ui.Node = null,
    step: usize = 0,
    furthest_step: usize = 0,
    panels: [3]?*ui.Node = @splat(null),
    scrolls: [3]?ui.widgets.ScrollAreaResult = @splat(null),
    steps: [3]?Stepper.Entry = @splat(null),
    step_disabled: [3]?*ui.Signal(bool) = @splat(null),
    step_styles: [3]?*ui.Signal(ui.BoxStyle) = @splat(null),
    back_button: ?*ui.Node = null,
    next_button: ?*ui.Node = null,
    cancel_button: ?*ui.Node = null,
    probe_button: ?*ui.Node = null,
    review_actions: [3]?*ui.Node = @splat(null),
    footer_buttons: [7]?FooterButton = @splat(null),
    summary_view: ?*Review.Summary = null,
    feedback_visible: bool = false,
    feedback_tone: FeedbackTone = .neutral,

    footer: ?*ui.Node = null,
    scroll: ?ui.widgets.ScrollAreaResult = null,
    pending_focus: ?usize = null,
    feedback_area: ?*ui.Node = null,
    feedback_icon: ?*ui.Node = null,
    message: ?*ui.Node = null,
    log_button: ?*ui.Node = null,
    log_open: ?*ui.Signal(bool) = null,
    log_modal: ?ui.widgets.ModalResult = null,
    log_scroll: ?ui.widgets.ScrollAreaResult = null,
    log_status: ?*ui.Node = null,
    log_entries: ?*ui.Node = null,
    log_render_revision: u64 = 0,
    route_path: ?*route_view.View = null,
    route_error: ?*ui.Node = null,
    reveal_hop: ?usize = null,
    hop_options: []const ui.widgets.SelectOption = &.{},
    options_revision: ?u64 = null,
    advanced_open: bool = false,
    advanced_toggle: ?*ui.Node = null,
    advanced_chevron: ?*ui.Node = null,
    advanced_label: ?*ui.Node = null,
    advanced_body: ?*ui.Node = null,
    advanced_disclosure: ?*@import("../../ui/layout_motion.zig").Disclosure = null,
    scale_trigger: ?*ui.Node = null,
    readonly_checkbox: ?*ui.Node = null,
    save_password_checkbox: ?*ui.Node = null,
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
    selects: std.ArrayList(ui.widgets.SelectResult) = .empty,
    pending: ?Pending = null,
    probe: draft_mod.ProbeState = .{},
    probe_log: draft_mod.ProbeLog = .{},
    child_request: ?u64 = null,
    hidden: bool = false,
    hook_registered: bool = false,
    height_motion: @import("../../ui/layout_motion.zig").Height = .{},
    last_compact: ?bool = null,
    last_route_chrome: ?bool = null,

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
        self.root = null;
        self.body = null;
        self.stepper = null;
        self.panels = @splat(null);
        self.scrolls = @splat(null);
        self.steps = @splat(null);
        self.step_disabled = @splat(null);
        self.step_styles = @splat(null);
        self.review_actions = @splat(null);
        self.footer_buttons = @splat(null);
        self.summary_view = null;
        self.back_button = null;
        self.next_button = null;
        self.cancel_button = null;
        self.probe_button = null;
        self.advanced_toggle = null;
        self.advanced_chevron = null;
        self.advanced_label = null;
        self.advanced_body = null;
        self.advanced_disclosure = null;
        self.scale_trigger = null;
        self.readonly_checkbox = null;
        self.save_password_checkbox = null;
        self.footer = null;
        self.scroll = null;
        self.feedback_area = null;
        self.feedback_icon = null;
        self.message = null;
        self.log_button = null;
        self.log_open = null;
        self.log_modal = null;
        self.log_scroll = null;
        self.log_status = null;
        self.log_entries = null;
        self.route_path = null;
        self.route_error = null;
        self.hop_options = &.{};
        self.options_revision = null;
        self.password_input = null;
        self.inputs = @splat(null);
        self.selects.deinit(self.mount.cx.allocator);
        self.selects = .empty;
        if (self.options_arena) |*arena| arena.deinit();
        self.options_arena = null;
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
    fn validateIdentity(self: *EditorView) !void {
        var payload = self.draft.?.payload(null);
        payload.access = .direct;
        try model.validate(payload);
    }
    fn navigate(self: *EditorView, step: usize) void {
        if (self.locked.?.peek() or step > 2) return;
        if (step > 0) self.validateIdentity() catch |err| return self.reportError(err);
        if (step == 2) self.draft.?.validateRuntime(self.mount.connection_configs, self.mount.cx.allocator) catch |err| return self.reportError(err);
        self.step = step;
        self.furthest_step = @max(self.furthest_step, step);
        self.feedback_visible = false;
        self.feedback_tone = .neutral;
        self.setRouteError("");
        if (self.probe_log.count == 0) if (self.message) |node| node.setTextContent(self.mount.cx.allocator, if (self.mount.initial != null) "保存的修改在下次新建连接时生效" else "尚未测试") catch {};
        self.applyStep();
        if (self.scrolls[self.step]) |scroll| ui.widgets.setScrollY(scroll.state, scroll.content, 0);
        if (self.step == 2) if (self.summary_view) |summary| summary.resetScroll();
        self.mount.cx.requestRedraw();
    }
    fn next(self: *EditorView) void {
        self.navigate(@min(self.step + 1, 2));
    }
    fn back(self: *EditorView) void {
        self.navigate(self.step -| 1);
    }
    fn editIdentity(self: *EditorView) void {
        self.navigate(0);
    }
    fn editRoute(self: *EditorView) void {
        self.navigate(1);
    }
    fn feedbackVisible(self: *const EditorView) bool {
        return self.feedback_visible or self.probe_log.count != 0 or self.probe.token != null;
    }
    fn hasIdentityErrors(self: *const EditorView) bool {
        for (self.errors) |maybe| if (maybe) |signal| {
            if (signal.peek().len != 0) return true;
        };
        return false;
    }
    fn applyStep(self: *EditorView) void {
        if (self.step != 1) {
            self.reveal_hop = null;
            if (self.route_path) |view| view.close();
        }
        self.scroll = self.scrolls[self.step];
        for (self.scrolls, 0..) |slot, i| if (slot) |scroll| scroll.container.setDisplay(if (i == self.step) .flex else .none);
        if (self.stepper) |stepper| Stepper.paintTrack(stepper);
        const step0_invalid = self.hasIdentityErrors();
        for (self.steps, 0..) |entry, i| if (entry) |value| {
            self.step_disabled[i].?.set(i > self.furthest_step);
            Stepper.paint(self.mount.cx, value, i == self.step, i < self.step, i == 0 and step0_invalid);
        };
        if (self.back_button) |node| node.setDisplay(if (self.step == 0) .none else .flex);
        if (self.cancel_button) |node| node.setDisplay(.flex);
        if (self.next_button) |node| node.setDisplay(if (self.step == 2) .none else .flex);
        if (self.probe_button) |node| node.setDisplay(if (self.step == 2) .flex else .none);
        for (self.review_actions) |action| if (action) |node| node.setDisplay(if (self.step == 2) .flex else .none);
        if (self.feedback_area) |node| node.setDisplay(if (self.feedbackVisible()) .flex else .none);
        if (self.step == 2) self.refreshSummary();
        self.paintChrome();
    }
    fn refreshSummary(self: *EditorView) void {
        const draft = &self.draft.?;
        const summary = self.summary_view orelse return;
        const group_name: []const u8 = blk: {
            const id = draft.group_id orelse break :blk "未分组";
            const resolver = self.mount.connection_configs orelse break :blk "未分组";
            const index = resolver.registry.groupIndex(id) orelse break :blk "未分组";
            break :blk resolver.registry.groups[index].name;
        };
        var subtitle_buf: [256]u8 = undefined;
        const subtitle = std.fmt.bufPrint(&subtitle_buf, "BMC · iKVM 控制台 · {s}", .{group_name}) catch "BMC · iKVM 控制台";
        var endpoint_buf: [320]u8 = undefined;
        const endpoint = std.fmt.bufPrint(&endpoint_buf, "{s}:{d}", .{ draft.host, draft.https_port }) catch draft.host;
        var display_buf: [128]u8 = undefined;
        const display = std.fmt.bufPrint(&display_buf, "{s} · 只读：{s}", .{ if (draft.scale == .fit) @as([]const u8, "适应窗口") else "原始比例 100%", if (draft.read_only_requested) @as([]const u8, "开启") else "关闭" }) catch "";

        var nodes: [10]Review.RouteNodeData = undefined;
        var caption_bufs: [10][32]u8 = undefined;
        var count: usize = 0;
        nodes[count] = .{ .name = "本机", .caption = "客户端", .icon = ui.icons.monitor, .highlighted = false };
        count += 1;
        if (draft.routed) for (draft.route[0..draft.route_count], 1..) |hop, i| {
            const label = blk: {
                const resolver = self.mount.connection_configs orelse break :blk "未解析的 SSH 主机";
                const index = resolver.registry.indexOf(@fromBackingInt(hop.asset_id)) orelse break :blk "已删除的 SSH 主机";
                break :blk resolver.registry.hosts[index].name;
            };
            nodes[count] = .{
                .name = label,
                .caption = std.fmt.bufPrint(&caption_bufs[count], "SSH · 第 {d} 跳", .{i}) catch "SSH 跳板",
                .icon = ui.icons.route,
                .highlighted = false,
            };
            count += 1;
        };
        nodes[count] = .{
            .name = if (draft.host.len == 0) "目标主机" else draft.host,
            .caption = "BMC · 目标",
            .icon = ui.icons.monitor,
            .highlighted = true,
        };
        count += 1;

        summary.update(.{
            .icon = ui.icons.monitor,
            .name = if (draft.name.len == 0) draft.host else draft.name,
            .subtitle = subtitle,
            .protocol_badge = "BMC",
            .endpoint_caption = "目标地址",
            .endpoint = endpoint,
            .values = .{
                draft.username,
                if (draft.password.len != 0) "密码 · 当前输入" else if (draft.credential_ref != null) "密码 · 已保存" else "密码 · 连接时输入",
                display,
            },
            .route_nodes = nodes[0..count],
            .show_note = !self.feedbackVisible(),
        });
    }
    const StepClick = struct {
        editor: *EditorView,
        step: usize,
        fn click(self: *@This()) void {
            self.editor.navigate(self.step);
        }
    };
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
        if (self.route_path) |view| if (view.picker.popup.open.?.peek()) {
            view.picker.close();
            return;
        };
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
    fn direct(self: *EditorView) void {
        self.access(false);
    }
    fn routed(self: *EditorView) void {
        self.access(true);
    }
    fn access(self: *EditorView, value: bool) void {
        const old = self.draft.?.revision;
        if (!value) if (self.route_path) |view| view.close();
        self.draft.?.setAccess(value) catch |err| return self.reportError(err);
        self.changed(old);
    }
    fn displayHops(self: *const EditorView) usize {
        const draft = &(self.draft orelse return 0);
        return if (draft.routed) @max(draft.route_count, 1) else 0;
    }
    fn routeExtraLines(self: *const EditorView) usize {
        if (self.route_error) |node| {
            if (node.style.display != .none) return 1;
        }
        return 0;
    }
    fn setRouteError(self: *EditorView, text: []const u8) void {
        if (self.route_error) |node| {
            node.setTextContent(self.mount.cx.allocator, text) catch {};
            node.setDisplay(if (text.len != 0) .flex else .none);
        }
    }
    fn pickerOptions(raw: *anyopaque, _: RoutePicker.Target) []const ui.widgets.SelectOption {
        const self: *EditorView = @ptrCast(@alignCast(raw));
        return self.hop_options;
    }
    fn pickerAvailable(raw: *anyopaque, target: RoutePicker.Target, value: []const u8) bool {
        const self: *EditorView = @ptrCast(@alignCast(raw));
        const draft = &(self.draft orelse return false);
        if (self.locked.?.peek() or !draft.routed) return false;
        const id = parseId(value, "conn:") catch return false;
        const resolver = self.mount.connection_configs orelse return false;
        const index = resolver.registry.indexOf(@fromBackingInt(id)) orelse return false;
        if (!std.mem.eql(u8, resolver.registry.hosts[index].protocolId(), "ssh")) return false;
        const except: ?usize = if (target == .replace) target.replace else null;
        return !draft.containsHop(id, except);
    }
    fn pickerChoose(raw: *anyopaque, target: RoutePicker.Target, value: []const u8) void {
        const self: *EditorView = @ptrCast(@alignCast(raw));
        if (!pickerAvailable(self, target, value)) return;
        const id = parseId(value, "conn:") catch return;
        const draft = &(self.draft orelse return);
        const old = draft.revision;
        var chosen_index: usize = 0;
        switch (target) {
            .replace => |index| {
                if (draft.route_count == 0 and index == 0) {
                    draft.addHop(@fromBackingInt(id)) catch |err| return self.reportError(err);
                    chosen_index = 0;
                } else {
                    draft.replaceHop(index, @fromBackingInt(id)) catch |err| return self.reportError(err);
                    chosen_index = index;
                }
            },
            .insert => |index| {
                const insert_at = @min(index, draft.route_count);
                draft.insertHop(insert_at, @fromBackingInt(id)) catch |err| return self.reportError(err);
                chosen_index = insert_at;
            },
        }
        self.route_path.?.picker.close();
        self.reveal_hop = chosen_index;
        self.changed(old);
    }
    fn replaceHop(raw: *anyopaque, index: usize, trigger: *ui.Node) void {
        const self: *EditorView = @ptrCast(@alignCast(raw));
        const draft = &(self.draft orelse return);
        if (self.locked.?.peek() or !draft.routed or index >= self.displayHops()) return;
        self.route_path.?.picker.show(trigger, .{ .replace = index });
    }
    fn reorderHop(raw: *anyopaque, index: usize, action_kind: route_hop.Action) void {
        const self: *EditorView = @ptrCast(@alignCast(raw));
        const draft = &(self.draft orelse return);
        if (self.locked.?.peek() or !draft.routed) return;
        const old = draft.revision;
        if (action_kind == .remove and draft.route_count == 0) {
            draft.setAccess(false) catch |err| return self.reportError(err);
        } else {
            switch (action_kind) {
                .up => draft.moveHop(index, true) catch |err| return self.reportError(err),
                .down => draft.moveHop(index, false) catch |err| return self.reportError(err),
                .remove => {
                    draft.removeHop(index) catch |err| return self.reportError(err);
                    if (draft.route_count == 0) draft.setAccess(false) catch |err| return self.reportError(err);
                },
            }
        }
        self.changed(old);
    }
    fn toggleAdvanced(self: *EditorView) void {
        self.advanced_open = !self.advanced_open;
        if (self.advanced_disclosure) |disc| disc.setExpanded(self.advanced_open);
        self.paintAdvancedToggle();
        self.mount.cx.requestRedraw();
    }
    fn advancedInk(self: *const EditorView) ui.Color {
        const colors = S.theme.current();
        return if (self.advanced_open) colors.accent_ink else colors.fg_2;
    }
    fn paintAdvancedToggle(self: *EditorView) void {
        const ink = self.advancedInk();
        if (self.advanced_chevron) |node| paintIcon(node, if (self.advanced_open) ui.icons.chevron_down else ui.icons.chevron_right, 14, ink);
        if (self.advanced_label) |node| node.setTextColor(ink);
    }
    fn changed(self: *EditorView, previous_revision: u64) void {
        const draft = &self.draft.?;
        if (draft.revision == previous_revision) return;
        const had_result = self.probe_log.count != 0;
        self.probe_log.invalidate(draft.revision);
        self.probe.invalidate();
        if (self.probe.token != null) self.cancelProbe();
        for (self.errors) |maybe| if (maybe) |error_signal| error_signal.set("");
        self.setRouteError("");
        if (had_result) {
            self.feedback("配置已更改，上次测试记录仅供参考，请重新测试");
            self.feedback_tone = .warn;
        } else {
            self.feedback_visible = false;
            self.feedback_tone = .neutral;
        }
        self.refreshProbeLog();
        if (self.mount.editor_host) |host| host.setParentRevision(self.mount.editor_id, draft.revision) catch |err| self.reportError(err);
        if (self.mount.credentials) |credentials| credentials.setDraftRevision(draft.revision) catch |err| self.reportError(err);
        if (self.probesFacade()) |facade| facade.setDraftRevision(draft.revision) catch |err| self.reportError(err);
        self.mount.events.changed(self.mount.events.context);
        self.refreshRoutes() catch |err| self.reportError(err);
        self.applyStep();
    }
    fn feedback(self: *EditorView, message: []const u8) void {
        if (self.message) |node| {
            if (node.getText()) |old| {
                if (!std.mem.eql(u8, old.content, message)) node.setTextContent(self.mount.cx.allocator, message) catch {};
            } else node.setTextContent(self.mount.cx.allocator, message) catch {};
        }
        self.feedback_visible = true;
        if (self.feedback_area) |area| area.setDisplay(.flex);
        if (self.step == 2) if (self.summary_view) |summary| summary.note_row.setDisplay(.none);
        self.refreshFeedbackChrome();
        self.mount.cx.requestRedraw();
    }
    fn reportError(self: *EditorView, err: anyerror) void {
        const message: []const u8 = switch (err) {
            error.MissingName => "请输入连接名称",
            error.DuplicateConnectionName => "已有同名连接，请修改连接名称。",
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
            error.EditorSecretSubmitUnavailable => "凭据保存服务尚未就绪，请稍后重试",
            error.CredentialDenied, error.CredentialLocked => "密码存储访问被拒绝，草稿已保留",
            error.CredentialStorageFailure => "密码保存失败，草稿已保留",
            else => @import("../../ui/feedback_message.zig").knownMessage(@errorName(err)) orelse "操作未完成，配置草稿已保留",
        };
        const field_index: ?usize = switch (err) {
            error.MissingName, error.DuplicateConnectionName => 0,
            error.InvalidEndpoint => if (self.draft != null and self.draft.?.https_port == 0) 2 else 1,
            error.InvalidUsername => 3,
            else => null,
        };
        const is_route_err = switch (err) {
            error.MissingSshReference, error.MissingRouteReference, error.ConnectionNotFound, error.DuplicateRoute, error.DuplicateEndpoint, error.TooManyJumps, error.ConfigurationResolverUnavailable, error.ProtocolMismatch => true,
            else => false,
        };
        self.feedback_tone = .err;
        if (field_index) |i| {
            self.step = 0;
            if (self.errors[i]) |signal| signal.set(message);
            self.pending_focus = i;
            self.applyStep();
        } else if (is_route_err) {
            self.step = 1;
            self.setRouteError(message);
            self.applyStep();
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
        self.feedback_tone = .neutral;
        self.feedback("正在取消管理连接测试并释放资源");
    }
    fn pollProbe(self: *EditorView) void {
        if (self.draft == null) return;
        const token = self.probe.token orelse return;
        const facade = self.probesFacade() orelse return;
        var probe_snapshot = facade.snapshot(token, self.mount.cx.allocator) catch {
            self.probe_log.unavailable();
            self.refreshProbeLog();
            self.feedback_tone = if (self.probe_log.stale) .warn else .running;
            self.feedback(if (self.probe_log.stale) "正在等待上次测试结束；此记录仅供参考" else "正在等待管理测试状态，配置草稿已保留");
            self.mount.cx.scheduleRedrawAfterNs(100 * std.time.ns_per_ms);
            return;
        };
        defer probe_snapshot.deinit();
        self.probe_log.observe(probe_snapshot.value);
        self.refreshProbeLog();
        const current = self.probe.apply(probe_snapshot.value, self.draft.?.revision);
        if (current) {
            if (probe_snapshot.value.complete) {
                const outcome = probe_snapshot.value.outcome orelse .failed;
                const warning = if (outcome == .succeeded) probe_feedback.warningFromMessage(probe_snapshot.value.safe_message) else null;
                self.feedback_tone = switch (outcome) {
                    .succeeded => if (warning != null) .warn else .ok,
                    .failed => .err,
                    .cancelled => .neutral,
                };
                self.feedback(switch (outcome) {
                    .succeeded => if (warning) |value| probe_feedback.warningText(value) else "管理连接测试成功：已验证 SSH / TLS、BMC 登录与资源发现；未打开视频",
                    .failed => if (probe_snapshot.value.safe_message.len != 0) probe_snapshot.value.safe_message else "管理连接测试失败，配置草稿已保留",
                    .cancelled => "管理连接测试已取消，配置草稿已保留",
                });
            } else {
                self.feedback_tone = .running;
                self.feedback(if (probe_snapshot.value.cleanup == .unknown) stageLabel(probe_snapshot.value.stage, .unknown) else if (probe_snapshot.value.safe_message.len != 0) probe_snapshot.value.safe_message else stageLabel(probe_snapshot.value.stage, probe_snapshot.value.cleanup));
            }
        } else if (self.probe_log.stale) {
            self.feedback_tone = .warn;
            self.feedback(if (self.probe.token != null) "配置已更改，上次测试正在释放资源；日志仅供参考" else "配置已更改，上次测试已结束；请重新测试当前配置");
        } else if (self.probe.cancelled) {
            self.feedback_tone = .neutral;
            if (self.probe.token != null) {
                var buffer: [192]u8 = undefined;
                self.feedback(std.fmt.bufPrint(&buffer, "正在取消管理测试并释放资源 · 总计 {d} 秒", .{self.probe_log.elapsed_seconds}) catch "正在取消管理测试并释放资源");
            } else self.feedback("管理连接测试已取消，配置草稿已保留");
        }
        const running = self.probe.token != null;
        self.probe_running.?.set(running);
        self.probe_label.?.set(if (running) "取消测试" else "测试管理连接");
        self.paintFooterButtons();
        if (running) self.mount.cx.scheduleRedrawAfterNs(100 * std.time.ns_per_ms);
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
        self.paintFooterButtons();
        self.feedback_tone = .running;
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
                self.reveal_hop = self.draft.?.route_count -| 1;
                self.changed(old);
                self.feedback_tone = .ok;
                self.feedback("SSH 主机已创建并加入路径");
            },
            .cancelled => {
                self.feedback_tone = .neutral;
                self.feedback("已返回 BMC 草稿，未创建 KVM 资产");
            },
            .failed => {
                self.feedback_tone = .warn;
                self.feedback("SSH 主机未保存，BMC 草稿已保留");
            },
        }
        self.refreshGroups() catch {};
        self.refreshRoutes() catch {};
    }
    fn tick(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *EditorView = @ptrCast(@alignCast(raw));
        if (self.draft == null) return .done;
        const cx = self.mount.cx;
        const compact = S.host.compactWindow(cx.viewport.width, cx.viewport.height);
        const route = self.step == 1;
        const review = self.step == 2;
        const body_padding = S.host.stepBodyPadding();
        const footer_padding = S.host.stepFooterPadding(route, compact, review);
        const footer_height = S.host.stepFooterHeight(route, compact, review);
        const footer_needs_layout = if (self.footer) |footer|
            footer.style.height != .px or footer.style.height.px != footer_height
        else
            false;
        var geometry_changed = false;
        if (self.pending_focus) |index| {
            self.pending_focus = null;
            if (self.inputs[index]) |input| {
                cx.setFocus(input.input_container);
                if (self.scrolls[0]) |scroll| {
                    scroll.state.content_height = scroll.content.globalRect().h;
                    scroll.state.viewport_height = scroll.container.globalRect().h;
                    ui.widgets.scrollIntoView(scroll.state, scroll.content, input.input_container, .nearest);
                }
                geometry_changed = true;
            }
        }
        if (self.body) |body| if (!std.meta.eql(body.style.padding, body_padding) or self.last_compact != compact or self.last_route_chrome != route or footer_needs_layout) {
            self.last_compact = compact;
            self.last_route_chrome = route;
            body.setStyleInline(cx.allocator, .{ .padding = body_padding, .gap = S.host.stepBodyGap(route) });
            if (self.stepper) |stepper| Stepper.layout(cx, stepper, compact);
            if (self.summary_view) |summary| summary.setCompact(compact);
            if (self.panels[2]) |panel| panel.setStyleInline(cx.allocator, .{ .gap = if (compact) 12 else 16 });
            if (self.footer) |footer| {
                footer.setStyleInline(cx.allocator, .{ .height = .{ .px = footer_height }, .padding = .{ .left = 24, .right = 24, .top = footer_padding, .bottom = footer_padding } });
                footer.setBackground(S.host.stepFooterBackground(route));
            }
            self.paintFooterButtons();
            geometry_changed = true;
        };
        if (route) if (self.route_path) |view| {
            const vertical = route_view.isVertical(self.displayHops(), cx.viewport.width);
            const height = route_view.chainHeight(self.displayHops(), vertical, cx.viewport.height, compact, self.routeExtraLines());
            if (view.layout(vertical, height)) geometry_changed = true;
            if (view.picker.update()) geometry_changed = true;
            if (self.reveal_hop) |index| {
                self.reveal_hop = null;
                view.reveal(index);
            }
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
            self.paintFooterButtons();
            defer if (self.draft != null) {
                self.locked.?.set(false);
                self.paintFooterButtons();
            };
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
    fn rebuildHopOptions(self: *EditorView) !void {
        const current_revision: ?u64 = if (self.mount.connection_configs) |resolver| resolver.registry.revision else null;
        if (self.options_revision == current_revision and self.options_revision != null) return;
        self.options_revision = current_revision;
        _ = self.options_arena.?.reset(.retain_capacity);
        const a = self.options_arena.?.allocator();
        var options: std.ArrayList(ui.widgets.SelectOption) = .empty;
        if (self.mount.connection_configs) |resolver| for (resolver.registry.hosts) |host| {
            if (!std.mem.eql(u8, host.protocolId(), "ssh")) continue;
            const id = @backingInt(host.connection_id);
            try options.append(a, .{
                .value = try std.fmt.allocPrint(a, "conn:{d}", .{id}),
                .label = try a.dupe(u8, host.name),
                .test_id = try std.fmt.allocPrint(a, "bmc.editor.route.option.{d}", .{id}),
            });
        };
        self.hop_options = try options.toOwnedSlice(a);
    }
    fn refreshRoutes(self: *EditorView) !void {
        const draft = &self.draft.?;
        try self.rebuildHopOptions();
        const count = self.displayHops();
        const view = self.route_path orelse return;
        view.setRoute(draft.routed, count);
        const a = self.mount.cx.allocator;
        const preview = &view.preview;
        for (0..count) |i| {
            const slot_index = i + 1;
            const hop = if (i < draft.route_count) draft.route[i].asset_id else 0;
            const resolved = if (hop != 0) host: {
                const resolver = self.mount.connection_configs orelse break :host null;
                const index = resolver.registry.indexOf(@fromBackingInt(hop)) orelse break :host null;
                const asset = resolver.registry.hosts[index];
                break :host if (std.mem.eql(u8, asset.protocolId(), "ssh")) asset else null;
            } else null;
            preview.names[slot_index].?.setTextContent(a, if (resolved) |asset| asset.name else if (hop != 0) "找不到此 SSH 主机" else "选择跳板") catch {};
            var buf: [256]u8 = undefined;
            const address = if (resolved) |asset|
                if (asset.port == 22)
                    std.fmt.bufPrint(&buf, "{s}@{s}", .{ asset.user, asset.host }) catch asset.host
                else
                    std.fmt.bufPrint(&buf, "{s}@{s}:{d}", .{ asset.user, asset.host, asset.port }) catch asset.host
            else
                "";
            preview.addresses[slot_index].?.setTextContent(a, address) catch {};
        }
        const target_name = if (draft.name.len != 0) draft.name else if (draft.host.len != 0) draft.host else "目标 BMC";
        preview.names[9].?.setTextContent(a, target_name) catch {};
        var target_buf: [256]u8 = undefined;
        const target_addr = if (draft.host.len != 0)
            (if (draft.username.len != 0)
                std.fmt.bufPrint(&target_buf, "{s}@{s}:{d}", .{ draft.username, draft.host, draft.https_port }) catch draft.host
            else
                std.fmt.bufPrint(&target_buf, "{s}:{d}", .{ draft.host, draft.https_port }) catch draft.host)
        else
            "";
        preview.addresses[9].?.setTextContent(a, target_addr) catch {};

        var can_insert = false;
        if (!self.locked.?.peek() and draft.route_count < 8) {
            for (self.hop_options) |option| if (pickerAvailable(self, .{ .insert = draft.route_count }, option.value)) {
                can_insert = true;
                break;
            };
        }
        self.add_disabled.?.set(!can_insert);
        if (self.step == 2) self.refreshSummary();
    }
    fn paintChrome(self: *EditorView) void {
        if (self.draft == null) return;
        const cx = self.mount.cx;
        const colors = S.theme.current();
        if (self.route_path) |view| view.paint(self.draft.?.routed);
        if (self.route_error) |node| node.setTextColor(colors.danger_ink);
        if (self.summary_view) |summary| summary.paint();
        if (self.advanced_body) |body| body.setBackground(S.host.identityPanelColor());
        self.paintAdvancedToggle();
        for (self.selects.items) |select| {
            select.chrome.setBackground(colors.overlay);
            if (self.scale_trigger != null and select.trigger == self.scale_trigger.?) {
                paintPanelControl(select.trigger);
            } else {
                select.trigger.setBackground(S.input(cx.tokens).background.?);
            }
        }
        if (self.save_password_checkbox) |box| paintCheckboxTypography(box);
        if (self.readonly_checkbox) |box| paintCheckboxTypography(box);
        if (self.feedback_area) |area| area.setBackground(S.theme.popupInset());
        self.refreshFeedbackChrome();
        if (self.footer) |footer| footer.setBackground(S.host.stepFooterBackground(self.step == 1));
        if (self.log_modal) |modal| modal.dialog.setBackground(colors.overlay);
        self.paintFooterButtons();
    }
    fn refreshFeedbackChrome(self: *EditorView) void {
        const colors = S.theme.current();
        const icon_asset = switch (self.feedback_tone) {
            .running => ui.icons.loader,
            .ok => ui.icons.circle_check,
            .err, .warn => ui.icons.circle_alert,
            .neutral => ui.icons.circle,
        };
        const tint = switch (self.feedback_tone) {
            .running => colors.accent,
            .ok => colors.ok,
            .err => colors.danger,
            .warn => colors.warn,
            .neutral => colors.fg_2,
        };
        if (self.feedback_icon) |node| paintIcon(node, icon_asset, 16, tint);
        if (self.message) |node| node.setTextColor(if (self.feedback_tone == .err) colors.danger_ink else if (self.feedback_tone == .ok) colors.ok else if (self.feedback_tone == .warn) colors.warn else colors.fg_2);
    }
    fn paintFooterButtons(self: *EditorView) void {
        const cx = self.mount.cx;
        const colors = S.theme.current();
        const review = self.step == 2;
        const editing = self.draft != null and @backingInt(self.draft.?.asset_id) != 0;
        const probe_running = self.probe.token != null;
        for (self.footer_buttons) |maybe| if (maybe) |button| {
            const width: f32 = switch (button.kind) {
                .back => if (review) 84 else 64,
                .cancel => 52,
                .probe => if (probe_running) 96 else 118,
                .next => if (self.step == 0) 94 else 64,
                .temporary => 80,
                .save => if (editing) 88 else 80,
                .save_and_open => 115,
            };
            const primary = button.kind == .next or button.kind == .save_and_open;
            var style = S.host.button(width, 34, primary);
            if (button.kind == .cancel and self.step != 1) style.background = ui.Color.TRANSPARENT;
            const is_disabled = button.disabled.peek();
            style.opacity = if (is_disabled) 0.4 else 1;
            if (primary and is_disabled) style.gradient = .{ .from = style.background.?, .to = style.background.?, .direction = .diagonal };
            button.style.set(style);
            button.node.setStyleInline(cx.allocator, style);
            button.label.setTextColor(S.host.action(primary).color);
            if (button.kind == .save) {
                const label_text = if (editing) "保存更改" else "仅保存";
                button.label.setTextContent(cx.allocator, label_text) catch {};
                if (button.node.behavior.interaction.a11y) |*a11y| a11y.label = label_text;
            }
            if (button.icon) |icon| {
                const show_icon = switch (button.kind) {
                    .back => review,
                    .next => self.step == 0,
                    .probe => true,
                    else => false,
                };
                icon.setDisplay(if (show_icon) .flex else .none);
                _ = icon.setTint(if (primary) S.host.action(true).color else colors.fg_2);
            }
        };
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
        if (self.route_path) |view| if (view.picker.popup.open.?.peek()) {
            view.picker.close();
            return;
        };
        self.queue(.cancel);
    }
    fn presentation(raw: *anyopaque) contract.ModalPresentation {
        const self: *EditorView = @ptrCast(@alignCast(raw));
        return .{ .width = S.width, .title = if (self.draft != null and @backingInt(self.draft.?.asset_id) != 0) "编辑连接" else "新建连接" };
    }
    fn preferredHeight(raw: *anyopaque) ?f32 {
        const self: *EditorView = @ptrCast(@alignCast(raw));
        if (self.draft == null) return null;
        const compact = S.host.compactWindow(self.mount.cx.viewport.width, self.mount.cx.viewport.height);
        const limit = @min(S.host.remote_max_height, S.host.availableModalHeight(self.mount.cx.viewport.height, compact));
        const target = @min(self.contentModalHeight(compact), limit);
        return @min(limit, self.height_motion.sample(self.mount.cx, target, true));
    }
    fn contentModalHeight(self: *const EditorView, compact: bool) f32 {
        if (self.step == 1) return route_view.modalHeight(self.displayHops(), self.mount.cx.viewport.width, compact, self.routeExtraLines());
        if (self.step == 2) {
            if (compact) return S.host.review_compact_height;
            if (self.feedbackVisible()) return 536;
            return S.host.review_height;
        }
        if (self.scrolls[0]) |scroll| {
            if (self.advanced_disclosure) |disc| {
                const expanded_h = if (self.advanced_open) disc.content.globalRect().h else 0;
                const content_h = scroll.content.globalRect().h - disc.root.globalRect().h + expanded_h;
                if (content_h > 0) {
                    const header_h: f32 = if (compact) 48 else 52;
                    const footer_h = S.host.stepFooterHeight(false, compact, false);
                    const track_margin: f32 = if (compact) 4 else 8;
                    const feedback_h: f32 = if (self.feedbackVisible()) 48 else 0;
                    return header_h + track_margin + 36 + 12 + content_h + feedback_h + footer_h;
                }
            }
        }
        return S.host.remote_max_height;
    }
    fn visibility(raw: *anyopaque, visible: bool) void {
        const self: *EditorView = @ptrCast(@alignCast(raw));
        self.hidden = !visible;
        if (!visible) {
            if (self.route_path) |view| view.close();
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
    self.options_arena = .init(cx.allocator);
    try scope.onCleanup(EditorView, self, EditorView.release);
    if (mount.initial) |initial| try self.draft.?.load(initial);
    if (mount.editor_host) |host| {
        try host.setParentRevision(mount.editor_id, mount.draft_revision);
        try host.setParentDelivery(mount.editor_id, self, EditorView.childCompleted);
    }
    self.locked = try scope.createSignal(bool, false);
    self.probe_running = try scope.createSignal(bool, false);
    self.probe_label = try scope.createText("测试管理连接", .{});
    self.log_open = try scope.createSignal(bool, false);
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

    const body_shell = try ui.box(cx, .{
        .width = .fill(),
        .height = .fill(),
        .flex = 1,
        .min_height = 0,
        .direction = .column,
        .padding = S.host.stepBodyPadding(),
        .gap = S.host.stepBodyGap(false),
    }, .{});
    try root.appendChild(cx.allocator, body_shell);
    self.body = body_shell;

    const steps = try Stepper.row(cx);
    self.stepper = steps;
    for (0..3) |i| {
        self.step_disabled[i] = try scope.createSignal(bool, i != 0);
        self.step_styles[i] = try scope.createSignal(ui.BoxStyle, S.host.reviewStep(i == 0));
        const click = try scope.createState(EditorView.StepClick, .{ .editor = self, .step = i });
        self.steps[i] = try Stepper.append(cx, scope, steps, i, Stepper.step_ids[i], self.step_disabled[i].?, self.step_styles[i].?, cx.on(EditorView.StepClick, click, EditorView.StepClick.click));
    }
    try body_shell.appendChild(cx.allocator, steps);

    // Step 1: 连接与认证 + 高级选项
    var step1 = try ui.boxStyled(cx, S.host.formSection, .{});
    self.panels[0] = step1;
    try section(self, step1, "连接信息");
    const identity_row = try ui.boxStyled(cx, S.row, .{});
    self.inputs[0] = try field(self, identity_row, "连接名称", "bmc.editor.name", self.name_value.?, "例如：compute-bmc-01", self.errors[0], EditorView.nameChanged);
    const group_field = try fieldBox(self, identity_row, "资产分组");
    const group = try ui.widgets.Select(.{ .options = self.group_options.?, .value = self.group_value.?, .width = 340, .disabled = self.locked.?, .on_change = cx.on(EditorView, self, EditorView.groupChanged) }).mount(scope, cx);
    try skinSelect(self, group, "bmc.editor.group");
    try group_field.appendChild(cx.allocator, group.wrapper);
    try step1.appendChild(cx.allocator, identity_row);
    const endpoint_row = try ui.boxStyled(cx, S.row, .{});
    self.inputs[1] = try field(self, endpoint_row, "BMC 地址", "bmc.editor.host", self.host_value.?, "bmc.example.internal", self.errors[1], EditorView.hostChanged);
    self.inputs[2] = try field(self, endpoint_row, "HTTPS 端口", "bmc.editor.port", self.port_value.?, "443", self.errors[2], EditorView.portChanged);
    try step1.appendChild(cx.allocator, endpoint_row);
    const auth_row = try ui.boxStyled(cx, S.row, .{});
    self.inputs[3] = try field(self, auth_row, "用户名", "bmc.editor.username", self.username_value.?, "BMC 用户名", self.errors[3], EditorView.usernameChanged);
    const auth_field = try fieldBox(self, auth_row, "认证方式");
    const auth = try ui.box(cx, .{ .height = .{ .px = 34 }, .direction = .row, .align_items = .center, .gap = 8 }, .{});
    try auth.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.lock, S.theme.current().fg_2, S.host.icon(14)));
    try auth.appendChild(cx.allocator, try ui.text(cx, "密码", S.host.text(12, 400, false)));
    try auth_field.appendChild(cx.allocator, auth);
    try step1.appendChild(cx.allocator, auth_row);
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
    self.save_password_checkbox = remember;
    try password_row.appendChild(cx.allocator, remember);
    try step1.appendChild(cx.allocator, password_row);

    const advanced_section = try ui.boxStyled(cx, S.host.advancedSection, .{});
    try mountAdvancedDisclosure(self, advanced_section);
    const advanced_body = try ui.boxStyled(cx, S.host.identityPanel, .{});
    advanced_body.setStyleInline(cx.allocator, .{ .gap = 12, .padding = ui.Padding.all(16) });
    self.advanced_body = advanced_body;
    const adv_row = try ui.boxStyled(cx, S.row, .{});
    const scale_field = try fieldBox(self, adv_row, "显示比例");
    const scale = try ui.widgets.Select(.{ .options = &scale_options, .value = self.scale_value.?, .width = 340, .disabled = self.locked.?, .on_change = cx.on(EditorView, self, EditorView.scaleChanged) }).mount(scope, cx);
    try skinSelect(self, scale, "bmc.editor.scale");
    scale.trigger.addBeforeRender(paintPanelControl);
    self.scale_trigger = scale.trigger;
    try scale_field.appendChild(cx.allocator, scale.wrapper);
    const readonly_field = try ui.boxStyled(cx, S.field, .{});
    try adv_row.appendChild(cx.allocator, readonly_field);
    const read_only = try ui.widgets.Checkbox(.{ .label = "以只读模式进入", .box_size = @as(f32, 14), .label_font_size = @as(f32, 11), .checked = self.read_only.?, .disabled = self.locked.?, .focus_ring = S.host.radioFocus(), .on_change = cx.on(EditorView, self, EditorView.readOnlyChanged) }).mount(scope, cx);
    read_only.meta.ownership.meta.test_id = "bmc.editor.readonly";
    read_only.setStyleInline(cx.allocator, .{ .height = .{ .px = 34 }, .margin = .{ .top = 21.5 }, .flex_shrink = 0 });
    read_only.addBeforeRender(paintCheckboxTypography);
    self.readonly_checkbox = read_only;
    try readonly_field.appendChild(cx.allocator, read_only);
    try advanced_body.appendChild(cx.allocator, adv_row);
    self.advanced_disclosure = try @import("../../ui/layout_motion.zig").Disclosure.mount(cx, scope, advanced_body, self.advanced_open);
    try advanced_section.appendChild(cx.allocator, self.advanced_disclosure.?.root);
    try step1.appendChild(cx.allocator, advanced_section);

    // Step 2: 连接路径 (shared route_view)
    const step2 = try ui.boxStyled(cx, S.host.stack, .{});
    self.panels[1] = step2;
    self.route_path = try route_view.mount(cx, scope, .{
        .locked = self.locked.?,
        .insert_disabled = self.add_disabled.?,
        .direct = cx.on(EditorView, self, EditorView.direct),
        .ssh = cx.on(EditorView, self, EditorView.routed),
        .hop_actions = .{ .context = self, .replace = EditorView.replaceHop, .reorder = EditorView.reorderHop },
        .picker_actions = .{ .context = self, .options = EditorView.pickerOptions, .available = EditorView.pickerAvailable, .choose = EditorView.pickerChoose },
        .target_role = "目标 BMC",
        .target_icon = ui.icons.monitor,
        .extra_action = .{
            .label = "新建 SSH 主机",
            .test_id = "bmc.editor.route.new_ssh",
            .disabled = self.locked.?,
            .on_click = cx.on(EditorView, self, EditorView.child),
        },
    });
    try step2.appendChild(cx.allocator, self.route_path.?.root);
    self.route_error = try ui.textStyled(cx, S.host.paragraph, "");
    self.route_error.?.meta.ownership.meta.test_id = "wizard.route.error";
    self.route_error.?.setTextColor(S.theme.current().danger_ink);
    self.route_error.?.setDisplay(.none);
    try step2.appendChild(cx.allocator, self.route_error.?);

    // Step 3: 核对与测试 (shared connection_review.Summary)
    const review = try ui.boxStyled(cx, S.host.reviewStack, .{});
    self.panels[2] = review;
    review.meta.ownership.meta.test_id = "bmc.editor.review";
    self.summary_view = try Review.Summary.mount(cx, scope, review, .{
        .icon = ui.icons.monitor,
        .endpoint_caption = "目标地址",
        .details_title = "认证与显示",
        .edit_identity_id = "bmc.editor.review.edit_identity",
        .edit_route_id = "bmc.editor.review.edit_route",
        .fields = .{
            .{ .label = "认证账户", .test_id = "bmc.editor.review.user", .mono = true },
            .{ .label = "认证方式", .test_id = "bmc.editor.review.auth" },
            .{ .label = "显示与模式", .test_id = "bmc.editor.review.display" },
        },
        .note = "仅保存配置不会建立会话。管理连接测试仅验证登录与资源发现，视频在打开控制台后验证。",
        .locked = self.locked.?,
        .on_edit_identity = cx.on(EditorView, self, EditorView.editIdentity),
        .on_edit_route = cx.on(EditorView, self, EditorView.editRoute),
    });

    const scroll_ids = [_][]const u8{ "bmc.editor.scroll", "wizard.scroll.route", "wizard.scroll.review" };
    for (self.panels, 0..) |panel, i| {
        const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical }).mount(scope, cx);
        scroll.container.setStyleInline(cx.allocator, S.host.scroll());
        scroll.container.meta.ownership.meta.test_id = scroll_ids[i];
        scroll.content.setStyleInline(cx.allocator, .{
            .width = .fill(),
            .height = .{ .fit = .{} },
            .direction = .column,
            .gap = 6,
            .padding = if (i == 2) .{ .bottom = 8 } else if (i == 1) .{} else .{ .bottom = 12 },
            .flex_shrink = 0,
        });
        try scroll.content.appendChild(cx.allocator, panel.?);
        try body_shell.appendChild(cx.allocator, scroll.container);
        self.scrolls[i] = scroll;
    }
    self.scroll = self.scrolls[0];

    const feedback_area = try ui.boxStyled(cx, S.feedbackArea, .{});
    feedback_area.meta.ownership.meta.test_id = "bmc.editor.feedback";
    self.feedback_icon = try ui.iconTint(cx, ui.icons.circle, S.theme.current().fg_2, S.host.icon(16));
    try feedback_area.appendChild(cx.allocator, self.feedback_icon.?);
    self.message = try ui.textStyled(cx, S.feedback, if (mount.initial != null) "保存的修改在下次新建连接时生效" else "尚未测试");
    self.message.?.setStyleInline(cx.allocator, .{ .flex = 1, .min_width = 0 });
    self.message.?.meta.ownership.meta.test_id = "bmc.editor.message";
    try feedback_area.appendChild(cx.allocator, self.message.?);
    const log_button = try ui.widgets.Button(.{ .icon_only = true, .icon_asset = ui.icons.get("file-text").?, .icon_size = 14, .a11y_label = "查看测试日志", .variant = .ghost, .base_style = S.logAction(), .on_click = cx.on(EditorView, self, EditorView.showProbeLog) }).mount(scope, cx);
    log_button.meta.ownership.meta.test_id = "bmc.editor.probe_log";
    log_button.addBeforeRender(paintLogActionTypography);
    const log_hint = try @import("../../ui/control_hint.zig").mount(cx, scope, log_button, "查看测试日志", .{ .id = "bmc.editor.probe_log.tooltip" });
    log_hint.wrapper.setDisplay(.none);
    try feedback_area.appendChild(cx.allocator, log_hint.wrapper);
    try root.appendChild(cx.allocator, feedback_area);
    self.feedback_area = feedback_area;
    self.log_button = log_hint.wrapper;

    const footer = try ui.boxStyled(cx, S.footer, .{});
    footer.meta.ownership.meta.test_id = "bmc.editor.footer";
    self.footer = footer;
    try mountFooterButton(self, footer, 0, .back, .{ .value = "上一步" }, "bmc.editor.back", 64, false, ui.icons.arrow_left, false, EditorView.back);
    try mountFooterButton(self, footer, 1, .cancel, .{ .value = "取消" }, "bmc.editor.cancel", 52, false, null, false, EditorView.cancelClicked);
    try footer.appendChild(cx.allocator, try ui.spacer(cx));
    try mountFooterButton(self, footer, 2, .probe, .{ .signal = self.probe_label.? }, "bmc.editor.probe", 118, false, ui.icons.activity, false, EditorView.testConnection);
    try mountFooterButton(self, footer, 3, .next, .{ .value = "下一步" }, "bmc.editor.next", 94, true, ui.icons.arrow_right, true, EditorView.next);
    try mountFooterButton(self, footer, 4, .temporary, .{ .value = "临时连接" }, "bmc.editor.temporary", 80, false, null, false, EditorView.temporary);
    try mountFooterButton(self, footer, 5, .save, .{ .value = "仅保存" }, "bmc.editor.save", 80, false, null, false, EditorView.save);
    try mountFooterButton(self, footer, 6, .save_and_open, .{ .value = "保存并连接" }, "bmc.editor.save_and_open", 115, true, null, false, EditorView.saveAndOpen);
    try root.appendChild(cx.allocator, footer);

    const log_modal = try ui.widgets.Modal(.{ .title = "管理测试日志", .managed_focus = false, .open = self.log_open.?, .width = @as(f32, 560), .max_height = @as(f32, 420), .background = S.theme.current().overlay, .close_icon_asset = ui.icons.x, .enter_transition = .fade, .exit_transition = .fade }).mount(scope, cx);
    if (!log_modal.portaled) try root.appendChild(cx.allocator, log_modal.overlay);
    _ = try scoped_modal.bind(cx, scope, log_modal, .{ .owner = .{ .node = mount.parent_dialog orelse root } });
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
    const close_log_btn = try ui.widgets.Button(.{ .label = "关闭", .variant = .ghost, .disabled = self.locked.?, .base_style = S.action(false), .on_click = cx.on(EditorView, self, EditorView.closeProbeLog) }).mount(scope, cx);
    close_log_btn.meta.ownership.meta.test_id = "bmc.editor.log_done";
    close_log_btn.addBeforeRender(paintActionTypography);
    try log_actions.appendChild(cx.allocator, close_log_btn);
    try log_modal.body.appendChild(cx.allocator, log_actions);
    self.log_modal = log_modal;
    self.log_scroll = log_scroll;
    try self.refreshGroups();
    try self.refreshRoutes();
    self.applyStep();
    try scope.createEffect(.{ .editor = self, .publication = try cx.themeSignal(scope) }, struct {
        fn paint(ctx: anytype) void {
            _ = ctx.publication.get();
            if (ctx.editor.draft == null) return;
            ctx.editor.applyStep();
        }
    }.paint);
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
fn paintIcon(node: *ui.Node, asset: ui.SvgAsset, size: f32, tint: ui.Color) void {
    if (asset.icon_id) |id| if (asset.pickRep(size)) |rep| node.setIcon(.{ .icon_id = id, .rep = rep, .tint = tint });
}
fn mountAdvancedDisclosure(self: *EditorView, parent: *ui.Node) !void {
    const cx = self.mount.cx;
    const scope = self.mount.scope;
    const row = try ui.box(cx, S.host.row(30), .{});
    const base = try scope.createSignal(ui.BoxStyle, S.host.advancedToggle());
    const node = try ui.widgets.Button(.{
        .variant = .ghost,
        .a11y_label = "高级选项",
        .disabled = self.locked.?,
        .base_style = base,
        .hover_style = S.host.disclosureHover(),
        .pressed_style = S.host.disclosureHover(),
        .on_click = cx.on(EditorView, self, EditorView.toggleAdvanced),
    }).mount(scope, cx);
    node.meta.ownership.meta.test_id = "bmc.editor.advanced";
    const chevron = try ui.iconTint(cx, ui.icons.chevron_right, self.advancedInk(), S.host.icon(14));
    const title = try ui.text(cx, "高级选项", S.host.text(13, 500, false));
    title.setTextColor(self.advancedInk());
    const content_box = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 30 }, .min_width = 0, .flex = 1, .direction = .row, .align_items = .center, .justify = .start, .gap = 8, .hit_behavior = .pass_through }, .{});
    try content_box.appendChild(cx.allocator, chevron);
    try content_box.appendChild(cx.allocator, title);
    try node.appendChild(cx.allocator, content_box);
    self.advanced_toggle = node;
    self.advanced_chevron = chevron;
    self.advanced_label = title;
    try row.appendChild(cx.allocator, node);
    try parent.appendChild(cx.allocator, row);
}
fn mountFooterButton(
    self: *EditorView,
    parent: *ui.Node,
    slot: usize,
    kind: ActionKind,
    label_source: ui.Source([]const u8),
    id: []const u8,
    width: f32,
    primary: bool,
    glyph: ?ui.SvgAsset,
    trailing_icon: bool,
    comptime clicked: *const fn (*EditorView) void,
) !void {
    const cx = self.mount.cx;
    const scope = self.mount.scope;
    const style = try scope.createSignal(ui.BoxStyle, S.host.button(width, 34, primary));
    const initial_label: []const u8 = switch (label_source) {
        .value => |text| text,
        .signal => |signal| signal.peek(),
        .memo => |memo| memo.peek(),
        .derived => "",
    };
    const node = try ui.widgets.Button(.{
        .variant = @as(ui.widgets.ButtonVariant, if (primary) .primary else .ghost),
        .a11y_label = initial_label,
        .disabled = self.locked.?,
        .base_style = style,
        .on_click = cx.on(EditorView, self, clicked),
    }).mount(scope, cx);
    for (node.children.items) |child| child.setDisplay(.none);
    node.setStyleInline(cx.allocator, S.host.button(width, 34, primary));
    node.meta.ownership.meta.test_id = id;
    var icon_node: ?*ui.Node = null;
    if (glyph) |asset| {
        icon_node = try ui.iconTint(cx, asset, if (primary) S.host.action(true).color else S.theme.current().fg_2, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .flex_shrink = 0 });
        if (!trailing_icon) try node.appendChild(cx.allocator, icon_node.?);
    }
    const label_node = try ui.text(cx, initial_label, S.host.action(primary));
    try node.appendChild(cx.allocator, label_node);
    if (trailing_icon) if (icon_node) |icon| try node.appendChild(cx.allocator, icon);
    switch (label_source) {
        .signal => |signal| {
            try scope.createEffect(.{ .cx = cx, .signal = signal, .node = node, .label = label_node }, struct {
                fn sync(ctx: anytype) void {
                    const text = ctx.signal.get();
                    ctx.label.setTextContent(ctx.cx.allocator, text) catch {};
                    if (ctx.node.behavior.interaction.a11y) |*a11y| a11y.label = text;
                }
            }.sync);
        },
        else => {},
    }
    try parent.appendChild(cx.allocator, node);
    self.footer_buttons[slot] = .{
        .kind = kind,
        .node = node,
        .style = style,
        .label = label_node,
        .icon = icon_node,
        .trailing_icon = trailing_icon,
        .disabled = self.locked.?,
    };
    switch (kind) {
        .back => self.back_button = node,
        .cancel => self.cancel_button = node,
        .probe => self.probe_button = node,
        .next => self.next_button = node,
        .temporary => self.review_actions[0] = node,
        .save => self.review_actions[1] = node,
        .save_and_open => self.review_actions[2] = node,
    }
}
fn paintPanelControl(node: *ui.Node) void {
    const parent = node.parent orelse node;
    const attrs = node.behavior.interaction.a11y orelse parent.behavior.interaction.a11y;
    const disabled = if (attrs) |value| value.disabled else false;
    const fill = if (disabled) S.theme.states().disabled else S.theme.current().overlay;
    if (ui.Color.eql(node.getBackground(), fill)) return;
    node.setBackgroundRaw(fill);
    node.markRenderDirty();
}
fn section(editor: *EditorView, parent: *ui.Node, label: []const u8) !void {
    const node = try ui.boxStyled(editor.mount.cx, S.section, .{});
    try node.appendChild(editor.mount.cx.allocator, try ui.textStyled(editor.mount.cx, S.sectionLabel, label));
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
        if (old.font_size != 11 or old.line_height != 1.5 or !std.meta.eql(old.color, S.theme.current().fg_2)) {
            var text = old;
            text.font_size = 11;
            text.line_height = 1.5;
            text.color = S.theme.current().fg_2;
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
    result.trigger.addBeforeRender(paintFieldTypography);
    if (result.trigger.parent) |wrapper| wrapper.setStyleInline(allocator, .{ .width = .fill(), .min_width = 0 });
    result.chrome.setStyleInline(allocator, .{ .padding = ui.Padding.all(5), .gap = 0, .border = .{ .radius = 10, .width = 0 }, .background = S.theme.current().overlay });
    result.panel.setStyleInline(allocator, .{ .gap = 0 });
    result.panel.addBeforeRender(paintActionTypography);
    try editor.selects.append(allocator, result);
}

test "BMC editor mounting API is analysed" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(EditorView);
}
