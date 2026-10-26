//! Formal connection progress. Network facts belong to the original Job;
//! this view owns only presentation (fold/filter/scroll), never a second Job.
const std = @import("std");
const ui = @import("ui");
pub const progress = @import("../proto/ssh/connection_progress.zig");
const operations = @import("../host/operation.zig");
const ssh = @import("../proto/ssh/session.zig");
const S = @import("connection_progress_styles.zig");
pub const OperationKey = operations.OperationKey;
pub const State = enum { connecting, waiting_auth, waiting_host_key, retrying, protocol_ready, attaching, failed, cancelled };
pub const Hop = struct { name: []const u8, host: []const u8, user: []const u8, port: u16 = 22 };
pub const Failure = struct { hop: ?usize = null, phase: ?progress.Phase = null, reason: []const u8 };
pub const LogRecord = struct { key: OperationKey, entry: progress.Journal.Entry };
pub const Snapshot = struct {
    key: OperationKey,
    /// Frozen network order, target last. Local is a source, not a session/hop.
    hops: []const Hop,
    journal: progress.Journal.Snapshot,
    state: State = .connecting,
    cleanup: operations.Cleanup = .not_started,
    resources: ?ssh.ResourceLedger.Snapshot = null,
    attached: bool = false,
    inline_authentication: bool = false,
    local_ready: bool = false,
    file_session: bool = false,
    activity: []const u8 = "",
    failure: ?Failure = null,
    /// Controller-owned history across whole-chain retries, newest 128 total.
    /// Empty means show this journal only; the view never fabricates history.
    logs: []const LogRecord = &.{},
    dropped: usize = 0,
};
pub const Callbacks = struct {
    context: *anyopaque,
    cancel: *const fn (*anyopaque, OperationKey) void,
    retry: *const fn (*anyopaque, OperationKey) anyerror!void,
    close: *const fn (*anyopaque, OperationKey) void,
    /// Text is valid during this callback only. The caller must copy it or
    /// synchronously write the clipboard and return its actual success/failure.
    copy_logs: *const fn (*anyopaque, OperationKey, []const u8) anyerror!void,
};
// Journal/ledger records are self-contained value copies. Only the explicitly
// borrowed display strings need allocation; generic cloneValue(anyerror) is
// not a valid error-union payload on this project's Zig version.
const Owned = struct {
    arena: std.heap.ArenaAllocator,
    value: Snapshot,
    fn init(allocator: std.mem.Allocator, source: Snapshot) !Owned {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        var copy = source;
        const hops = try owned.alloc(Hop, source.hops.len);
        for (source.hops, hops) |hop, *destination| destination.* = .{ .name = try owned.dupe(u8, hop.name), .host = try owned.dupe(u8, hop.host), .user = try owned.dupe(u8, hop.user), .port = hop.port };
        copy.hops = hops;
        copy.logs = try owned.dupe(LogRecord, source.logs);
        copy.activity = try owned.dupe(u8, source.activity);
        if (source.failure) |fault| {
            var frozen = fault;
            frozen.reason = try owned.dupe(u8, fault.reason);
            copy.failure = frozen;
        }
        return .{ .arena = arena, .value = copy };
    }
    fn deinit(self: *Owned) void {
        self.arena.deinit();
    }
};
const ActionContext = struct {
    view: *View,
    key: OperationKey,
    fn cancel(self: *ActionContext) void {
        if (self.view.matches(self.key)) self.view.cancel();
    }
    fn close(self: *ActionContext) void {
        if (self.view.matches(self.key)) self.view.close();
    }
    fn retry(self: *ActionContext) void {
        if (self.view.matches(self.key)) self.view.retry();
    }
    fn copy(self: *ActionContext) void {
        if (self.view.matches(self.key)) self.view.copyLogs();
    }
};
const HopSlot = struct {
    view: *View,
    key: OperationKey,
    hop: ?usize,
    node: *ui.Node = undefined,
    name: *ui.Node = undefined,
    endpoint: *ui.Node = undefined,
    user: *ui.Node = undefined,
    status: *ui.Node = undefined,
    id: [48]u8 = @splat(0),
    fn choose(self: *HopSlot) void {
        if (!self.view.matches(self.key)) return;
        self.view.copy_result = null;
        self.view.filter = if (self.view.filter == self.hop) null else self.hop;
        self.view.following = true;
        self.view.new_logs = 0;
        self.view.refreshCards() catch {};
        self.view.refreshLogs() catch {};
    }
};
const Marker = struct { key: OperationKey, sequence: u64 };

pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    callbacks: Callbacks,
    root: *ui.Node,
    dialog: *ui.Node,
    modal_body: *ui.Node,
    open: *ui.Signal(bool),
    source: ?Owned = null,
    visible: bool = false,
    compact: bool = false,
    header: *ui.Node = undefined,
    body: *ui.Node = undefined,
    logs_expanded: bool = false,
    filter: ?usize = null,
    following: bool = true,
    new_logs: usize = 0,
    last_marker: ?Marker = null,
    last_scroll_y: f32 = 0,
    cancel_requested: bool = false,
    retry_requested: bool = false,
    copy_result: ?bool = null,
    action_scope: ?*ui.Scope = null,
    chain_scope: ?*ui.Scope = null,
    title: *ui.Node,
    header_icon: *ui.Node = undefined,
    header_spinner: *ui.Node = undefined,
    spinner_color: *ui.Signal(?ui.Color),
    identity_chip: *ui.Node = undefined,
    toggle_button: *ui.Node = undefined,
    copy_icon: ?*ui.Node = null,
    close_icon: ?*ui.Node = null,
    connectors: [S.max_hops]struct { icon: *ui.Node, label: *ui.Node } = undefined,
    header_action: *ui.Node,
    endpoint: *ui.Node,
    attempt: *ui.Node,
    body_scroll: ui.widgets.ScrollAreaResult,
    chain_scroll: ui.widgets.ScrollAreaResult,
    slots: [S.max_hops + 1]HopSlot = undefined,
    slot_count: usize = 0,
    summary: *ui.Node,
    summary_title: *ui.Node,
    summary_detail: *ui.Node,
    resource_box: *ui.Node,
    resource_text: *ui.Node,
    /// Stable slot inside this original progress modal. Append AuthView.root
    /// once; show() never destroys or reparents it during state/log updates.
    authentication_area: *ui.Node,
    logs_scroll: ui.widgets.ScrollAreaResult,
    logs_text: *ui.Node,
    toggle_label: *ui.Node,
    log_help: *ui.Node,
    jump_button: *ui.Node,
    jump_label: *ui.Node,
    copy_host: *ui.Node,
    footer: *ui.Node,
    footer_hint: *ui.Node = undefined,
    retry_disabled: *ui.Signal(bool),
    copy_disabled: *ui.Signal(bool),
    cancel_disabled: *ui.Signal(bool),
    close_disabled: *ui.Signal(bool),
    header_disabled: *ui.Signal(bool),
    cancel_button: ?*ui.Node = null,
    retry_button: ?*ui.Node = null,
    close_button: ?*ui.Node = null,
    cancel_label: ?*ui.Node = null,
    retry_label: ?*ui.Node = null,
    close_label: ?*ui.Node = null,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, callbacks: Callbacks) !*View {
        const self = try cx.allocator.create(View);
        var registered = false;
        errdefer if (!registered) cx.allocator.destroy(self);
        const open = try scope.createSignal(bool, false);
        const modal = try ui.widgets.Modal(.{ .open = ui.split(open, cx.on(View, self, openChanged)), .width = S.width, .max_height = @max(160, cx.viewport.height - 16), .background = S.theme.current().overlay, .close_on_overlay = false }).mount(scope, cx);
        self.* = .{
            .cx = cx,
            .scope = scope,
            .callbacks = callbacks,
            .spinner_color = try scope.createSignal(?ui.Color, S.theme.current().accent),
            .root = modal.overlay,
            .dialog = modal.dialog,
            .modal_body = modal.body,
            .open = open,
            .retry_disabled = try scope.createSignal(bool, true),
            .copy_disabled = try scope.createSignal(bool, true),
            .cancel_disabled = try scope.createSignal(bool, false),
            .close_disabled = try scope.createSignal(bool, true),
            .header_disabled = try scope.createSignal(bool, false),
            .title = undefined,
            .header_action = undefined,
            .endpoint = undefined,
            .attempt = undefined,
            .body_scroll = undefined,
            .chain_scroll = undefined,
            .summary = undefined,
            .summary_title = undefined,
            .summary_detail = undefined,
            .resource_box = undefined,
            .resource_text = undefined,
            .authentication_area = undefined,
            .logs_scroll = undefined,
            .logs_text = undefined,
            .toggle_label = undefined,
            .log_help = undefined,
            .jump_button = undefined,
            .jump_label = undefined,
            .copy_host = undefined,
            .footer = undefined,
        };
        try scope.onCleanup(View, self, cleanup);
        registered = true;
        modal.dialog.setStyleInline(cx.allocator, S.panel(S.normal_height, cx.viewport.width));
        modal.dialog.meta.ownership.meta.test_id = "connection.progress";
        modal.body.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .fill(), .padding = .{}, .gap = 0 });
        // The panel supplies its own header/body insets.
        modal.body.setStyle(cx.allocator, .padding, ui.Padding{});
        if (!modal.portaled) if (cx.root) |root| try root.appendChild(cx.allocator, modal.overlay);
        self.compact = cx.viewport.width <= 860 or cx.viewport.height <= 480;
        const header = try ui.box(cx, S.attemptHeader(self.compact), .{});
        self.header = header;
        self.header_icon = try ui.iconTint(cx, ui.icons.get("network").?, S.theme.current().accent, S.icon(18));
        try header.appendChild(cx.allocator, self.header_icon);
        self.header_spinner = try ui.widgets.Spinner(.{ .size = 18, .stroke_width = 2, .color = self.spinner_color }).mount(scope, cx);
        self.header_spinner.meta.ownership.meta.test_id = "connection.progress.spinner";
        self.header_spinner.setDisplay(.none);
        try header.appendChild(cx.allocator, self.header_spinner);
        self.title = try self.appendLabel(header, "连接进度", S.text(13, 700, false));
        self.title.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 20 }, .flex = 1, .min_width = 0 });
        self.header_action = try ui.box(cx, S.iconButton(22), .{});
        try header.appendChild(cx.allocator, self.header_action);
        try modal.body.appendChild(cx.allocator, header);
        const body = try ui.box(cx, S.body(self.compact), .{});
        self.body = body;
        try modal.body.appendChild(cx.allocator, body);
        self.body_scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical, .rubber_band_y = false }).mount(scope, cx);
        self.body_scroll.container.setStyleInline(cx.allocator, S.scroll());
        self.body_scroll.content.setStyleInline(cx.allocator, S.stack());
        self.body_scroll.container.meta.ownership.meta.test_id = "connection.progress.body";
        try body.appendChild(cx.allocator, self.body_scroll.container);
        const content = self.body_scroll.content;
        const identity_row = try ui.box(cx, S.row(24), .{});
        self.endpoint = try self.appendLabel(identity_row, "", S.text(11, 400, true));
        self.endpoint.setTextColor(S.theme.current().fg_1);
        self.endpoint.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 16 }, .flex = 1, .min_width = 0 });
        self.endpoint.meta.ownership.meta.test_id = "connection.progress.endpoint";
        const chip = try ui.box(cx, S.chip(), .{});
        self.identity_chip = chip;
        self.attempt = try ui.text(cx, "", S.attemptText());
        self.attempt.setStyleInline(cx.allocator, S.attemptLabel());
        self.attempt.meta.ownership.meta.test_id = "connection.progress.attempt";
        try chip.appendChild(cx.allocator, self.attempt);
        try identity_row.appendChild(cx.allocator, chip);
        try content.appendChild(cx.allocator, identity_row);
        self.chain_scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical, .rubber_band_y = false }).mount(scope, cx);
        self.chain_scroll.container.setStyleInline(cx.allocator, S.chainScroll());
        self.chain_scroll.container.meta.ownership.meta.test_id = "connection.progress.chain";
        try content.appendChild(cx.allocator, self.chain_scroll.container);
        self.summary = try ui.box(cx, S.notice(false), .{});
        self.summary_title = try self.appendLabel(self.summary, "", S.paragraph(12, 500));
        self.summary_title.meta.ownership.meta.test_id = "connection.progress.summary.title";
        self.summary_detail = try self.appendLabel(self.summary, "", S.paragraph(11, 400));
        self.summary_detail.meta.ownership.meta.test_id = "connection.progress.summary.detail";
        self.summary_detail.behavior.interaction.a11y = .{ .role = .status, .live = "polite" };
        try content.appendChild(cx.allocator, self.summary);
        self.resource_box = try ui.box(cx, S.notice(false), .{});
        self.resource_box.setDisplay(.none);
        self.resource_text = try self.appendLabel(self.resource_box, "", S.paragraph(11, 400));
        self.resource_text.meta.ownership.meta.test_id = "connection.progress.resources";
        try content.appendChild(cx.allocator, self.resource_box);
        self.authentication_area = try ui.box(cx, S.authentication(), .{});
        self.authentication_area.meta.ownership.meta.test_id = "connection.progress.authentication";
        try content.appendChild(cx.allocator, self.authentication_area);
        const log_controls = try ui.box(cx, S.row(30), .{});
        const toggle = try ui.widgets.Button(.{ .variant = .secondary, .a11y_label = "展开或收起阶段日志", .on_click = cx.on(View, self, toggleLogs) }).mount(scope, cx);
        prepareCustomButton(toggle);
        self.toggle_button = toggle;
        toggle.setStyleInline(cx.allocator, S.button(140, 30, false));
        toggle.meta.ownership.meta.test_id = "connection.progress.logs.toggle";
        self.toggle_label = try ui.text(cx, "展开阶段日志", S.text(12, 500, false));
        try toggle.appendChild(cx.allocator, self.toggle_label);
        try log_controls.appendChild(cx.allocator, toggle);
        self.log_help = try self.appendLabel(log_controls, "日志不含凭据", S.text(11, 400, false));
        self.log_help.setStyleInline(cx.allocator, .{ .width = .{ .px = 160 }, .height = .{ .px = 16 }, .flex_shrink = 0, .min_width = 0 });
        try log_controls.appendChild(cx.allocator, try ui.spacer(cx));
        self.jump_button = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = "回到阶段日志底部", .on_click = cx.on(View, self, jumpToBottom) }).mount(scope, cx);
        prepareCustomButton(self.jump_button);
        self.jump_button.setStyleInline(cx.allocator, S.button(154, 28, false));
        self.jump_button.setDisplay(.none);
        self.jump_button.meta.ownership.meta.test_id = "connection.progress.logs.bottom";
        self.jump_label = try ui.text(cx, "回到底部", S.text(11, 400, false));
        try self.jump_button.appendChild(cx.allocator, self.jump_label);
        try log_controls.appendChild(cx.allocator, self.jump_button);
        self.copy_host = try ui.box(cx, S.iconButton(28), .{});
        try log_controls.appendChild(cx.allocator, self.copy_host);
        try content.appendChild(cx.allocator, log_controls);
        self.logs_scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical, .rubber_band_y = false }).mount(scope, cx);
        self.logs_scroll.container.setStyleInline(cx.allocator, S.logs());
        self.logs_scroll.container.setDisplay(.none);
        self.logs_scroll.container.meta.ownership.meta.test_id = "connection.progress.logs";
        self.logs_scroll.content.setStyleInline(cx.allocator, S.logContent());
        var log_style = S.text(10.5, 400, false);
        log_style.line_height = 16.0 / 10.5;
        log_style.use_monospace_font = true;
        log_style.wrap = .word;
        log_style.text_overflow = .clip;
        self.logs_text = try self.appendLabel(self.logs_scroll.content, "", log_style);
        try content.appendChild(cx.allocator, self.logs_scroll.container);
        self.footer = try ui.box(cx, S.footer(self.compact), .{});
        self.footer.meta.ownership.meta.test_id = "connection.progress.actions";
        try modal.body.appendChild(cx.allocator, self.footer);
        try cx.addAfterLayoutHook(self, afterLayout);
        return self;
    }

    /// Safe-hook only. Takes an owned value copy and preserves the inline
    /// authentication slot, including its current focus/composition/selection.
    pub fn show(self: *View, snapshot: Snapshot) !void {
        try validate(snapshot);
        var same = false;
        if (self.source) |current| {
            same = current.value.key.eql(snapshot.key);
            if (self.visible and !sameLogicalOwner(current.value.key, snapshot.key)) return error.ProgressOwnerMismatch;
            if (sameLogicalOwner(current.value.key, snapshot.key) and older(snapshot.key, current.value.key)) return error.StaleProgress;
            if (same and self.cancel_requested and snapshot.attached) return error.StaleCompletion;
            if (same) {
                if (current.value.hops.len != snapshot.hops.len) return error.FrozenConnectionChanged;
                for (current.value.hops, snapshot.hops) |before, after| {
                    if (before.port != after.port or !std.mem.eql(u8, before.name, after.name) or !std.mem.eql(u8, before.host, after.host) or !std.mem.eql(u8, before.user, after.user)) return error.FrozenConnectionChanged;
                }
            }
        }
        var copy = try Owned.init(self.cx.allocator, snapshot);
        var transferred = false;
        errdefer if (!transferred) copy.deinit();
        self.observeUserScroll();
        if (!same) {
            self.cancel_requested = false;
            self.retry_requested = false;
            self.copy_result = null;
            self.filter = null;
            self.following = true;
            self.new_logs = 0;
        }
        if (self.source) |*old| old.deinit();
        self.source = copy;
        transferred = true;
        self.updateLogMarker();
        if (!same or self.action_scope == null) {
            try self.buildActions();
            try self.buildChain();
        }
        self.visible = !snapshot.attached;
        try self.refresh();
        self.open.set(!snapshot.attached);
        if (snapshot.attached) self.authentication_area.setDisplay(.none);
        self.cx.requestRedraw();
    }
    pub fn hide(self: *View) void {
        if (!self.visible and !self.open.peek() and self.authentication_area.style.display == .none) return;
        self.visible = false;
        self.open.set(false);
        self.authentication_area.setDisplay(.none);
        self.cx.requestRedraw();
    }
    pub fn isVisible(self: *const View) bool {
        return self.visible;
    }
    pub fn operationKey(self: *const View) ?OperationKey {
        return if (self.visible) self.source.?.value.key else null;
    }
    /// Reapply only this view's public slots; never rebuild authentication.
    pub fn retheme(self: *View) !void {
        const c = S.theme.current();
        self.dialog.setStyleInline(self.cx.allocator, S.panel(self.dialog.style.height.px, self.cx.viewport.width));
        _ = self.header_icon.setTint(c.accent);
        self.spinner_color.set(c.accent);
        self.title.setTextColor(c.fg_1);
        self.endpoint.setTextColor(c.fg_1);
        self.identity_chip.setStyleInline(self.cx.allocator, S.chip());
        self.footer.setStyleInline(self.cx.allocator, S.footer(self.compact));
        self.attempt.setTextColor(c.fg_2);
        self.toggle_button.setStyleInline(self.cx.allocator, S.button(140, 30, false));
        self.toggle_label.setTextColor(c.fg_1);
        self.log_help.setTextColor(c.fg_2);
        self.jump_button.setStyleInline(self.cx.allocator, S.button(154, 28, false));
        self.jump_label.setTextColor(c.fg_2);
        self.logs_scroll.container.setStyleInline(self.cx.allocator, S.logs());
        self.logs_text.setTextColor(c.fg_1);
        if (self.copy_icon) |node| _ = node.setTint(c.fg_2);
        if (self.close_icon) |node| _ = node.setTint(c.fg_2);
        for (self.slots[0..self.slot_count]) |slot| {
            slot.name.setTextColor(c.fg_1);
            slot.endpoint.setTextColor(c.fg_2);
            slot.user.setTextColor(c.fg_2);
        }
        for (self.connectors[0..self.slot_count -| 1]) |connector| {
            _ = connector.icon.setTint(c.fg_3);
            connector.label.setTextColor(c.fg_2);
        }
        if (self.cancel_button) |node| node.setStyleInline(self.cx.allocator, S.button(112, 34, false));
        if (self.close_button) |node| node.setStyleInline(self.cx.allocator, S.button(88, 34, false));
        if (self.retry_button) |node| node.setStyleInline(self.cx.allocator, S.button(156, 34, true));
        if (self.cancel_label) |node| node.setTextColor(S.actionText(false).color);
        if (self.close_label) |node| node.setTextColor(S.actionText(false).color);
        if (self.retry_label) |node| node.setTextColor(S.actionText(true).color);
        if (self.source != null) self.footer_hint.setTextColor(c.fg_2);
        self.summary_title.setTextColor(c.fg_1);
        self.summary_detail.setTextColor(c.fg_2);
        self.resource_box.setStyleInline(self.cx.allocator, S.notice(false));
        self.resource_text.setTextColor(c.fg_2);
        if (self.source != null) try self.refresh();
    }
    pub fn matches(self: *const View, key: OperationKey) bool {
        return if (self.source) |source| self.visible and source.value.key.eql(key) else false;
    }
    pub fn toggleLogs(self: *View) void {
        if (!self.visible) return;
        self.logs_expanded = !self.logs_expanded;
        self.logs_scroll.container.setDisplay(if (self.logs_expanded) .flex else .none);
        self.toggle_label.setTextContent(self.cx.allocator, if (self.logs_expanded) "收起阶段日志" else "展开阶段日志") catch {};
        self.resize();
        self.cx.requestRedraw();
    }
    pub fn jumpToBottom(self: *View) void {
        self.following = true;
        self.new_logs = 0;
        self.syncLogScroll();
        self.cx.requestRedraw();
    }
    pub fn cancel(self: *View) void {
        const source = if (self.source) |*source| &source.value else return;
        if (!self.visible or self.cancel_requested or source.attached or source.cleanup == .released) return;
        self.cancel_requested = true;
        self.cancel_disabled.set(true);
        self.callbacks.cancel(self.callbacks.context, source.key);
        self.refreshSummary() catch {};
    }
    pub fn retry(self: *View) void {
        if (!self.visible or self.retry_requested or !self.canRetry()) return;
        const key = self.source.?.value.key;
        self.retry_requested = true;
        self.retry_disabled.set(true);
        self.callbacks.retry(self.callbacks.context, key) catch {
            self.retry_requested = false;
            self.retry_disabled.set(!self.canRetry());
            self.log_help.setTextContent(self.cx.allocator, "无法开始重试，请保留原连接状态后重试。") catch {};
            return;
        };
    }
    pub fn close(self: *View) void {
        const source = if (self.source) |*source| &source.value else return;
        if (!self.visible) return;
        if (source.state != .failed and source.state != .cancelled and !source.attached) {
            self.cancel();
            return;
        }
        if (!self.canDismiss()) return;
        const key = source.key;
        self.hide();
        self.callbacks.close(self.callbacks.context, key);
    }
    pub fn copyLogs(self: *View) void {
        if (!self.visible or self.copy_disabled.peek()) return;
        var text = std.Io.Writer.Allocating.init(self.cx.allocator);
        defer text.deinit();
        self.writeLogs(&text.writer) catch {
            self.copyFeedback(false);
            return;
        };
        self.callbacks.copy_logs(self.callbacks.context, self.source.?.value.key, text.writer.buffered()) catch {
            self.copyFeedback(false);
            return;
        };
        self.copyFeedback(true);
    }

    fn refresh(self: *View) !void {
        const source = &self.source.?.value;
        const spinning = source.file_session and !source.attached and source.state != .failed and source.state != .cancelled and !self.cancel_requested;
        self.header_spinner.setDisplay(if (spinning) .flex else .none);
        self.header_icon.setDisplay(if (spinning) .none else .flex);
        const target = source.hops[source.hops.len - 1];
        var buffer: [2048]u8 = undefined;
        try self.endpoint.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&buffer, "{s}@{s}:{d}", .{ target.user, target.host, target.port }));
        try self.attempt.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&buffer, "尝试 {d}", .{source.key.attempt_id.?}));
        const state_label: []const u8 = if (source.attached) "已接入会话" else if (source.state == .failed) "连接失败" else if (source.state == .retrying) "重试完整链路" else if (source.state == .cancelled or self.cancel_requested) (if (source.cleanup == .released) "连接已取消" else "正在取消连接") else "正在连接";
        const title = if (source.hops.len == 1) try std.fmt.allocPrint(self.cx.allocator, "直连 {s} · {s}", .{ target.name, state_label }) else try std.fmt.allocPrint(self.cx.allocator, "{d} 级跳板 · {s} · {s}", .{ source.hops.len - 1, target.name, state_label });
        defer self.cx.allocator.free(title);
        try self.title.setTextContent(self.cx.allocator, title);
        self.authentication_area.setDisplay(if (source.inline_authentication and !source.attached) .flex else .none);
        self.retry_disabled.set(self.retry_requested or !self.canRetry());
        self.cancel_disabled.set(self.cancel_requested or source.attached);
        self.close_disabled.set(!self.canDismiss());
        self.header_disabled.set(if (source.state == .failed or source.state == .cancelled) !self.canDismiss() else self.cancel_requested or source.attached);
        const icon = ui.icons.get(if (source.state == .failed) "triangle-alert" else "network").?;
        if (icon.icon_id) |id| if (icon.pickRep(18)) |rep| self.header_icon.setIcon(.{ .icon_id = id, .rep = rep, .tint = if (source.state == .failed) S.theme.current().danger_ink else S.theme.current().accent });
        try self.refreshCards();
        try self.refreshSummary();
        try self.refreshResources();
        try self.refreshLogs();
        self.resize();
    }
    fn buildActions(self: *View) !void {
        self.clearNodes(self.header_action);
        self.clearNodes(self.copy_host);
        self.clearNodes(self.footer);
        if (self.action_scope) |scope| scope.dispose();
        const scope = try self.scope.childScope();
        self.action_scope = scope;
        const ctx = try self.cx.allocator.create(ActionContext);
        ctx.* = .{ .view = self, .key = self.source.?.value.key };
        try scope.adoptResource(ctx, struct {
            fn destroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                allocator.destroy(@as(*ActionContext, @ptrCast(@alignCast(ptr))));
            }
        }.destroy);
        const close_button = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .a11y_label = "关闭或取消当前连接", .disabled = self.header_disabled, .on_click = self.cx.on(ActionContext, ctx, ActionContext.close) }).mount(scope, self.cx);
        prepareCustomButton(close_button);
        self.close_icon = try ui.iconTint(self.cx, ui.icons.x, S.theme.current().fg_2, S.icon(16));
        try close_button.appendChild(self.cx.allocator, self.close_icon.?);
        close_button.setStyleInline(self.cx.allocator, S.iconButton(22));
        close_button.meta.ownership.meta.test_id = "connection.progress.close";
        try self.header_action.appendChild(self.cx.allocator, close_button);
        const copy_button = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .a11y_label = "复制阶段日志", .disabled = self.copy_disabled, .on_click = self.cx.on(ActionContext, ctx, ActionContext.copy) }).mount(scope, self.cx);
        prepareCustomButton(copy_button);
        self.copy_icon = try ui.iconTint(self.cx, ui.icons.copy, S.theme.current().fg_2, S.icon(16));
        try copy_button.appendChild(self.cx.allocator, self.copy_icon.?);
        copy_button.setStyleInline(self.cx.allocator, S.iconButton(28));
        copy_button.meta.ownership.meta.test_id = "connection.progress.logs.copy";
        try self.copy_host.appendChild(self.cx.allocator, copy_button);
        self.cancel_button = try self.button(self.footer, scope, ctx, "取消连接", 112, false, self.cancel_disabled, ActionContext.cancel, "connection.progress.cancel");
        try self.footer.appendChild(self.cx.allocator, try ui.spacer(self.cx));
        const hint = try self.appendLabel(self.footer, "取消后释放本次完整链路", S.text(11, 400, false));
        self.footer_hint = hint;
        hint.setStyleInline(self.cx.allocator, .{ .width = .{ .px = 220 }, .height = .{ .px = 16 }, .flex_shrink = 0, .min_width = 0 });
        self.close_button = try self.button(self.footer, scope, ctx, "关闭", 88, false, self.close_disabled, ActionContext.close, "connection.progress.dismiss");
        self.retry_button = try self.button(self.footer, scope, ctx, "重试完整链路", 156, true, self.retry_disabled, ActionContext.retry, "connection.progress.retry");
    }
    fn buildChain(self: *View) !void {
        self.clearNodes(self.chain_scroll.content);
        if (self.chain_scope) |scope| scope.dispose();
        const scope = try self.scope.childScope();
        self.chain_scope = scope;
        const source = &self.source.?.value;
        self.slot_count = source.hops.len + 1;
        self.chain_scroll.container.setStyleInline(self.cx.allocator, .{ .height = .{ .px = @as(f32, @floatFromInt(self.slot_count)) * 54 - 12 } });
        self.chain_scroll.content.setStyleInline(self.cx.allocator, S.chain(self.slot_count, @min(S.width, self.cx.viewport.width - 16) - 32));
        for (0..self.slot_count) |index| {
            if (index != 0) {
                const connector = try ui.box(self.cx, S.connector(), .{});
                const icon = try ui.iconTint(self.cx, ui.icons.arrow_right, S.theme.current().fg_3, S.icon(14));
                try connector.appendChild(self.cx.allocator, icon);
                const connector_label = try self.appendLabel(connector, if (index == 1) "TCP" else "隧道", S.connectorText());
                self.connectors[index - 1] = .{ .icon = icon, .label = connector_label };
                connector.setDisplay(.none);
                try self.chain_scroll.content.appendChild(self.cx.allocator, connector);
            }
            const slot = &self.slots[index];
            slot.* = .{ .view = self, .key = source.key, .hop = if (index == 0) null else index - 1 };
            slot.node = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = "筛选该节点的阶段日志", .on_click = self.cx.on(HopSlot, slot, HopSlot.choose) }).mount(scope, self.cx);
            prepareCustomButton(slot.node);
            slot.node.setStyleInline(self.cx.allocator, S.card(false));
            slot.node.meta.ownership.meta.test_id = try std.fmt.bufPrint(&slot.id, "connection.progress.hop.{d}", .{index});
            slot.name = try self.cardLabel(slot.node, 18, S.text(12, 500, false));
            slot.name.setStyleInline(self.cx.allocator, .{ .width = .{ .px = 130 }, .height = .{ .px = 18 }, .flex_shrink = 0 });
            slot.endpoint = try self.cardLabel(slot.node, 14, S.text(9.5, 400, true));
            slot.user = try self.cardLabel(slot.node, 14, S.text(10, 400, false));
            slot.user.setDisplay(.none);
            var status_style = S.text(10, 400, false);
            status_style.line_height = 1.6;
            slot.status = try self.cardLabel(slot.node, 16, status_style);
            slot.status.setStyleInline(self.cx.allocator, .{ .width = .{ .px = 130 }, .height = .{ .px = 16 }, .flex_shrink = 0 });
            slot.endpoint.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .px = 16 }, .min_width = 0, .flex = 1 });
            try self.chain_scroll.content.appendChild(self.cx.allocator, slot.node);
        }
    }
    fn refreshCards(self: *View) !void {
        const source = &self.source.?.value;
        const fault = self.currentFailure();
        var buffer: [1536]u8 = undefined;
        for (self.slots[0..self.slot_count]) |*slot| {
            slot.node.setStyleInline(self.cx.allocator, S.card(slot.hop != null and slot.hop == self.filter));
            if (slot.hop) |hop| {
                const item = source.hops[hop];
                try slot.name.setTextContent(self.cx.allocator, item.name);
                try slot.endpoint.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&buffer, "{s}@{s}:{d}", .{ item.user, item.host, item.port }));
                try slot.user.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&buffer, "身份  {s}", .{item.user}));
                const latest = self.latestEvent(hop);
                var label: []const u8 = if (source.state == .retrying) "等待整链重建" else "等待上游";
                var color = S.theme.current().fg_3;
                if (source.attached) {
                    label = "在线";
                    color = S.theme.current().ok;
                } else if (fault != null and fault.?.hop != null and hop > fault.?.hop.?) {
                    label = "受阻 · 未连接";
                } else if (fault != null and fault.?.hop == hop) {
                    label = if (source.cleanup == .released) "失败 · 已释放" else "连接失败";
                    color = S.theme.current().danger_ink;
                } else if (latest) |event| {
                    if (source.cleanup == .released) label = "已释放" else if (source.cleanup == .releasing) label = "正在释放" else if (source.cleanup == .unknown) label = "释放待核实" else if (event.phase == .ready and event.status == .succeeded) {
                        label = if (hop + 1 == source.hops.len) "协议已就绪" else "已认证";
                        color = S.theme.current().ok;
                    } else {
                        label = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ phaseName(event.phase), if (event.status == .succeeded) "完成" else "中" });
                        color = S.theme.current().accent;
                    }
                }
                try slot.status.setTextContent(self.cx.allocator, label);
                slot.status.setTextColor(color);
            } else {
                try slot.name.setTextContent(self.cx.allocator, "Local");
                try slot.endpoint.setTextContent(self.cx.allocator, "连接来源 · 本机进程");
                try slot.user.setTextContent(self.cx.allocator, "连接来源  本机进程");
                try slot.status.setTextContent(self.cx.allocator, if (source.local_ready) "已就绪" else "准备中");
                slot.status.setTextColor(if (source.local_ready) S.theme.current().ok else S.theme.current().fg_3);
            }
        }
    }
    fn refreshSummary(self: *View) !void {
        const source = &self.source.?.value;
        const fault = self.currentFailure();
        self.summary.setStyleInline(self.cx.allocator, S.notice(fault != null or source.state == .failed));
        self.cancel_button.?.setDisplay(if (source.state == .failed or source.state == .cancelled) .none else .flex);
        self.close_button.?.setDisplay(if (source.state == .failed or source.state == .cancelled) .flex else .none);
        self.retry_button.?.setDisplay(if (source.state == .failed) .flex else .none);
        self.footer_hint.setDisplay(if (source.state == .failed or source.state == .cancelled) .none else .flex);
        try self.footer_hint.setTextContent(self.cx.allocator, if (source.state == .failed or source.state == .cancelled) "" else "取消后释放本次完整链路");
        var title = std.Io.Writer.Allocating.init(self.cx.allocator);
        defer title.deinit();
        var detail = std.Io.Writer.Allocating.init(self.cx.allocator);
        defer detail.deinit();
        if (fault) |failure| {
            if (failure.hop) |hop| try title.writer.print("第 {d} 跳 {s} · {s}失败", .{ hop + 1, source.hops[hop].name, if (failure.phase) |phase| phaseName(phase) else "连接" }) else try title.writer.writeAll("连接失败");
            try detail.writer.writeAll(failure.reason);
            try detail.writer.print("；{s}", .{cleanupText(source.cleanup)});
            if (failure.hop) |hop| if (hop + 1 < source.hops.len) {
                try detail.writer.writeAll("\n后续受阻：");
                for (source.hops[hop + 1 ..], 0..) |item, index| {
                    if (index != 0) try detail.writer.writeAll("、");
                    try detail.writer.writeAll(item.name);
                }
                try detail.writer.writeAll("。");
            };
        } else if (source.attached) {
            try title.writer.writeAll("已接入会话");
            try detail.writer.writeAll("连接已由宿主接入当前会话。");
        } else if (self.cancel_requested or source.state == .cancelled) {
            try title.writer.writeAll(if (source.cleanup == .released) "连接已取消" else "正在取消连接");
            try detail.writer.writeAll(cleanupText(source.cleanup));
        } else if (source.file_session) {
            try title.writer.writeAll("正在连接 SFTP");
            try detail.writer.writeAll(source.activity);
        } else if (source.state == .protocol_ready or source.state == .attaching) {
            try title.writer.writeAll("协议已就绪，正在接入会话");
            try detail.writer.writeAll("等待会话接入结果。");
        } else if (self.latestEvent(null)) |event| {
            try title.writer.print("{s}第 {d} 跳 {s}", .{ if (source.state == .waiting_auth) "等待认证 · " else if (source.state == .waiting_host_key) "等待核对主机密钥 · " else if (source.state == .retrying) "正在重新连接" else "正在连接", event.hop + 1, source.hops[event.hop].name });
            try detail.writer.print("当前阶段：{s}。", .{phaseName(event.phase)});
            if (event.hop + 1 < source.hops.len) try detail.writer.writeAll(if (source.state == .retrying) "其余节点等待整链重建。" else "其余节点等待上游完成。");
        } else {
            try title.writer.writeAll(if (source.state == .retrying) "正在从 Local 重建完整链路" else "正在准备连接");
            try detail.writer.writeAll("等待当前连接的阶段结果。");
        }
        try self.summary_title.setTextContent(self.cx.allocator, title.writer.buffered());
        try self.summary_detail.setTextContent(self.cx.allocator, detail.writer.buffered());
    }
    fn refreshResources(self: *View) !void {
        const source = &self.source.?.value;
        const shown = source.cleanup == .releasing or source.cleanup == .unknown;
        self.resource_box.setDisplay(if (shown) .flex else .none);
        if (!shown) return;
        var text = std.Io.Writer.Allocating.init(self.cx.allocator);
        defer text.deinit();
        try text.writer.writeAll(cleanupText(source.cleanup));
        if (source.resources) |resources| {
            for (resources.resources[0..resources.hop_count], 0..) |hop, index| for (hop, 0..) |entry, kind| {
                if (entry.state == .absent or entry.state == .released) continue;
                try text.writer.print("\n第 {d} 跳 {s} · {s}：{s}", .{ index + 1, source.hops[index].name, resourceName(@fromBackingInt(@intCast(kind))), switch (entry.state) {
                    .owned => "仍由本次连接持有",
                    .releasing => "正在释放",
                    .unknown => "待核实",
                    else => unreachable,
                } });
            };
            if (resources.retained_count != 0) try text.writer.print("\n仍有 {d} 项连接资源等待释放。", .{resources.retained_count});
            if (resources.overflowed) try text.writer.writeAll("\n部分资源状态无法核实。");
        }
        try self.resource_text.setTextContent(self.cx.allocator, text.writer.buffered());
    }
    fn refreshLogs(self: *View) !void {
        var text = std.Io.Writer.Allocating.init(self.cx.allocator);
        defer text.deinit();
        try self.writeDisplayLogs(&text.writer);
        try self.logs_text.setTextContent(self.cx.allocator, if (text.writer.buffered().len != 0) text.writer.buffered() else "暂无当前节点的阶段日志");
        try @import("log_typography.zig").apply(self.cx, self.logs_text);
        self.copy_disabled.set(self.logCount() == 0);
        if (self.copy_result) |success| {
            try self.log_help.setTextContent(self.cx.allocator, if (success) "已复制阶段日志" else "复制失败，请重试");
            self.log_help.setTextColor(if (success) S.theme.current().ok else S.theme.current().danger_ink);
            return;
        }
        self.log_help.setTextColor(S.theme.current().fg_2);
        var label: [256]u8 = undefined;
        try self.log_help.setTextContent(self.cx.allocator, if (self.filter) |hop| try std.fmt.bufPrint(&label, "第 {d} 跳 · 日志不含凭据", .{hop + 1}) else "日志不含凭据");
        const drop_count = @max(self.source.?.value.dropped, self.source.?.value.journal.dropped);
        if (drop_count != 0) try self.log_help.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&label, "已省略 {d} 条旧日志", .{drop_count}));
    }
    fn writeDisplayLogs(self: *View, writer: *std.Io.Writer) !void {
        const count = self.logCount();
        for (0..count) |index| {
            const record = self.logAt(index);
            if (self.filter) |hop| if (record.entry.hop != hop) continue;
            var start = record.entry.timestamp_ns;
            for (0..index) |before| {
                const earlier = self.logAt(before);
                if (earlier.key.eql(record.key)) {
                    start = earlier.entry.timestamp_ns;
                    break;
                }
            }
            const ms = @divTrunc(@max(0, record.entry.timestamp_ns - start), std.time.ns_per_ms);
            try writer.print("+{d}.{d:0>3}s  {s} · {s}\n         {s}:{d} · 第 {d} 跳 · 尝试 {d} · #{d}\n", .{ @divTrunc(ms, 1000), @mod(ms, 1000), phaseName(record.entry.phase), switch (record.entry.status) {
                .started => "进行中",
                .succeeded => "完成",
                .failed => failureText(record.entry.failure),
                .cancelled => "已取消",
            }, record.entry.hostSlice(), record.entry.port, record.entry.hop + 1, record.key.attempt_id.?, record.entry.sequence });
        }
    }
    fn writeLogs(self: *View, writer: *std.Io.Writer) !void {
        const source = self.source.?.value;
        if (source.failure) |fault| try writer.print("失败原因：{s}\n", .{fault.reason});
        if (source.file_session) try writer.print("SFTP：{s}\n", .{source.activity});
        const count = self.logCount();
        for (0..count) |index| {
            const record = self.logAt(index);
            if (self.filter) |hop| if (record.entry.hop != hop) continue;
            var start = record.entry.timestamp_ns;
            for (0..index) |before| {
                const candidate = self.logAt(before);
                if (candidate.key.eql(record.key)) {
                    start = candidate.entry.timestamp_ns;
                    break;
                }
            }
            const milliseconds = @divTrunc(@max(0, record.entry.timestamp_ns - start), std.time.ns_per_ms);
            try writer.print("+{d}.{d:0>3}s [尝试 {d} · #{d}] 第 {d} 跳 {s}:{d} | {s} | {s}\n", .{ @divTrunc(milliseconds, 1000), @mod(milliseconds, 1000), record.key.attempt_id.?, record.entry.sequence, record.entry.hop + 1, record.entry.hostSlice(), record.entry.port, phaseName(record.entry.phase), switch (record.entry.status) {
                .started => "进行中",
                .succeeded => "完成",
                .failed => failureText(record.entry.failure),
                .cancelled => "已取消",
            } });
        }
    }
    fn logCount(self: *const View) usize {
        const source = &self.source.?.value;
        return if (source.logs.len != 0) source.logs.len else source.journal.count;
    }
    fn logAt(self: *const View, index: usize) LogRecord {
        const source = &self.source.?.value;
        return if (source.logs.len != 0) source.logs[index] else .{ .key = source.key, .entry = source.journal.entries[index] };
    }
    fn updateLogMarker(self: *View) void {
        const count = self.logCount();
        if (count == 0) return;
        const last = self.logAt(count - 1);
        if (self.last_marker) |marker| {
            if (!marker.key.eql(last.key) or marker.sequence != last.entry.sequence) {
                self.copy_result = null;
                var added = count;
                for (0..count) |index| {
                    const entry = self.logAt(index);
                    if (entry.key.eql(marker.key) and entry.entry.sequence == marker.sequence) {
                        added = count - index - 1;
                        break;
                    }
                }
                if (!self.following) self.new_logs +|= added;
            }
        }
        self.last_marker = .{ .key = last.key, .sequence = last.entry.sequence };
    }
    fn observeUserScroll(self: *View) void {
        const state = self.logs_scroll.state;
        if (@abs(state.scroll_y - self.last_scroll_y) < 0.5) return;
        self.following = state.scroll_y >= state.maxScrollY() - 1;
        if (self.following) self.new_logs = 0;
        self.last_scroll_y = state.scroll_y;
    }
    fn syncLogScroll(self: *View) void {
        const scroll = self.logs_scroll;
        self.observeUserScroll();
        scroll.state.content_height = scroll.content.globalRect().h;
        scroll.state.viewport_height = scroll.container.globalRect().h;
        if (self.following) ui.widgets.scroll_area.setScrollY(scroll.state, scroll.content, scroll.state.maxScrollY());
        self.last_scroll_y = scroll.state.scroll_y;
        self.jump_button.setDisplay(if (self.logs_expanded and !self.following) .flex else .none);
        var buffer: [80]u8 = undefined;
        const label = if (self.new_logs == 0) "回到底部" else std.fmt.bufPrint(&buffer, "{d} 条新日志 · 回到底部", .{self.new_logs}) catch "有新日志 · 回到底部";
        if (!std.mem.eql(u8, self.jump_label.getText().?.content, label)) self.jump_label.setTextContent(self.cx.allocator, label) catch {};
    }
    fn resize(self: *View) void {
        const source = if (self.source) |*source| &source.value else return;
        const natural = self.body_scroll.content.globalRect().h;
        const fallback = if (self.currentFailure() != null or source.state == .failed) S.failed_height else S.normal_height;
        const height = @min(if (natural > 0) natural + (if (self.compact) @as(f32, 114) else 134) else fallback, @max(100, self.cx.viewport.height - 16));
        const panel = S.panel(height, self.cx.viewport.width);
        if (!std.meta.eql(self.dialog.style.width, panel.width.?) or !std.meta.eql(self.dialog.style.height, panel.height.?)) self.dialog.setStyleInline(self.cx.allocator, panel);
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        if (!self.visible) return .done;
        const compact = self.cx.viewport.width <= 860 or self.cx.viewport.height <= 480;
        if (compact != self.compact) {
            self.compact = compact;
            self.header.setStyleInline(self.cx.allocator, S.attemptHeader(compact));
            self.body.setStyleInline(self.cx.allocator, S.body(compact));
            self.footer.setStyleInline(self.cx.allocator, S.footer(compact));
            return .needs_layout;
        }
        // Native widget style replay can restore Modal's default 16px inset
        // after mount. Normalize the public slot before accepting its layout.
        if (!std.meta.eql(self.modal_body.style.padding, ui.Padding{})) {
            self.modal_body.setStyle(self.cx.allocator, .padding, ui.Padding{});
            return .needs_layout;
        }
        const before_width = self.dialog.style.width;
        const before = self.dialog.style.height;
        self.resize();
        if (self.logs_expanded) self.syncLogScroll();
        return if (std.meta.eql(before_width, self.dialog.style.width) and std.meta.eql(before, self.dialog.style.height)) .done else .needs_layout;
    }
    fn latestEvent(self: *const View, hop: ?usize) ?progress.Journal.Entry {
        const journal = &self.source.?.value.journal;
        var index = journal.count;
        while (index > 0) {
            index -= 1;
            const entry = journal.entries[index];
            if (hop == null or entry.hop == hop.?) return entry;
        }
        return null;
    }
    fn currentFailure(self: *const View) ?Failure {
        const source = &self.source.?.value;
        if (source.failure) |fault| return fault;
        const fault = source.journal.failure orelse return null;
        if (fault.status != .failed) return null;
        return .{ .hop = fault.hop, .phase = fault.phase, .reason = failureText(fault.failure) };
    }
    fn canDismiss(self: *const View) bool {
        const source = if (self.source) |*source| &source.value else return false;
        return (source.state == .failed or source.state == .cancelled) and source.cleanup == .released;
    }
    fn canRetry(self: *const View) bool {
        const source = if (self.source) |*source| &source.value else return false;
        if (source.attached or source.state != .failed or source.cleanup != .released) return false;
        const resources = source.resources orelse return source.file_session;
        return resources.released() and !resources.hasUnknown();
    }
    fn copyFeedback(self: *View, success: bool) void {
        self.copy_result = success;
        self.log_help.setTextContent(self.cx.allocator, if (success) "已复制阶段日志" else "复制失败，请重试") catch {};
        self.log_help.setTextColor(if (success) S.theme.current().ok else S.theme.current().danger_ink);
        self.cx.requestRedraw();
    }
    fn openChanged(self: *View, value: bool) void {
        if (value) return;
        // Cx asks the top Modal to dismiss before delivering Escape to Input.
        // The original inline form must receive this physical key exactly once:
        // first cancel composition, then cancel its request on a later Escape.
        if (self.cx.focus_manager.getFocused()) |focused| {
            var ancestor: ?*ui.Node = focused;
            while (ancestor) |node| : (ancestor = node.parent) if (node == self.authentication_area) {
                _ = self.cx.dispatcher.dispatchKeyDown(focused, .{ .key = .escape });
                return;
            };
        }
        self.close();
    }
    fn clearNodes(self: *View, parent: *ui.Node) void {
        while (parent.children.items.len != 0) {
            const child = parent.children.items[parent.children.items.len - 1];
            self.cx.detachChild(parent, child);
            self.cx.freeNode(child);
        }
    }
    fn appendLabel(self: *View, parent: *ui.Node, text: []const u8, style: ui.TextStyle) !*ui.Node {
        const node = try ui.text(self.cx, text, style);
        node.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .min_height = style.font_size * style.line_height, .flex_shrink = 0 });
        try parent.appendChild(self.cx.allocator, node);
        return node;
    }
    fn cardLabel(self: *View, parent: *ui.Node, height: f32, style: ui.TextStyle) !*ui.Node {
        const node = try self.appendLabel(parent, "", style);
        node.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .px = height }, .min_width = 0, .flex_shrink = 0 });
        return node;
    }
    fn button(self: *View, parent: *ui.Node, scope: *ui.Scope, ctx: *ActionContext, label_text: []const u8, w: f32, primary: bool, disabled: ?*ui.Signal(bool), comptime callback: *const fn (*ActionContext) void, id: []const u8) !*ui.Node {
        const variant: ui.widgets.button.ButtonVariant = if (primary) .primary else .secondary;
        const source: ui.Source(bool) = if (disabled) |signal| .{ .signal = signal } else .{ .value = false };
        const node = try ui.widgets.Button(.{ .variant = variant, .a11y_label = label_text, .disabled = source, .on_click = self.cx.on(ActionContext, ctx, callback) }).mount(scope, self.cx);
        prepareCustomButton(node);
        node.setStyleInline(self.cx.allocator, S.button(w, 34, primary));
        node.meta.ownership.meta.test_id = id;
        const style = S.actionText(primary);
        const button_label = try ui.text(self.cx, label_text, style);
        if (std.mem.eql(u8, id, "connection.progress.cancel")) self.cancel_label = button_label;
        if (std.mem.eql(u8, id, "connection.progress.dismiss")) self.close_label = button_label;
        if (std.mem.eql(u8, id, "connection.progress.retry")) self.retry_label = button_label;
        try node.appendChild(self.cx.allocator, button_label);
        try parent.appendChild(self.cx.allocator, node);
        return node;
    }
    fn cleanup(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
        if (self.source) |*source| source.deinit();
        self.cx.allocator.destroy(self);
    }
};

fn validate(snapshot: Snapshot) !void {
    const attempt = snapshot.key.attempt_id orelse return error.InvalidProgressIdentity;
    if (attempt == 0 or snapshot.key.operation_id == 0 or snapshot.journal.attempt != attempt) return error.InvalidProgressIdentity;
    if (snapshot.hops.len == 0 or snapshot.hops.len > S.max_hops or snapshot.journal.count > progress.Journal.capacity or snapshot.logs.len > progress.Journal.capacity) return error.InvalidProgressSnapshot;
    for (snapshot.journal.entries[0..snapshot.journal.count]) |entry| if (entry.hop >= snapshot.hops.len or entry.hop_count != snapshot.hops.len) return error.InvalidProgressSnapshot;
    if (snapshot.journal.failure) |entry| if (entry.hop >= snapshot.hops.len or entry.hop_count != snapshot.hops.len) return error.InvalidProgressSnapshot;
    if (snapshot.failure) |fault| if (fault.hop) |hop| if (hop >= snapshot.hops.len) return error.InvalidProgressSnapshot;
    if (snapshot.resources) |resources| {
        const key = resources.key orelse return error.InvalidResourceOwner;
        if (!key.eql(snapshot.key) or resources.hop_count != snapshot.hops.len) return error.InvalidResourceOwner;
    }
    for (snapshot.logs) |record| {
        if (!sameLogicalOwner(record.key, snapshot.key) or record.key.attempt_id == null or record.entry.hop >= record.entry.hop_count or record.entry.hop_count > S.max_hops) return error.InvalidLogOwner;
        if (older(snapshot.key, record.key)) return error.InvalidLogOwner;
    }
    if (snapshot.attached and snapshot.key.owner != .session) return error.InvalidAttachmentOwner;
}
fn sameLogicalOwner(a: OperationKey, b: OperationKey) bool {
    if (a.owner == .session and b.owner == .session) return a.owner.session.session_id == b.owner.session.session_id;
    if (a.owner == .app and b.owner == .app) return a.operation_id == b.operation_id;
    return a.owner.eql(b.owner);
}
fn older(a: OperationKey, b: OperationKey) bool {
    if (a.owner == .session and b.owner == .session and a.owner.session.generation != b.owner.session.generation) return a.owner.session.generation < b.owner.session.generation;
    if (a.operation_id != b.operation_id) return a.operation_id < b.operation_id;
    return a.attempt_id.? < b.attempt_id.?;
}
pub fn phaseName(phase: progress.Phase) []const u8 {
    return switch (phase) {
        .transport => "TCP 连接",
        .tunnel => "隧道建立",
        .handshake => "SSH 握手",
        .host_key => "主机密钥核对",
        .authentication => "SSH 认证",
        .shell => "终端准备",
        .ready => "协议就绪",
    };
}
fn cleanupText(cleanup: operations.Cleanup) []const u8 {
    return switch (cleanup) {
        .not_started => "等待确认本次连接资源状态",
        .releasing => "本次链路资源正在释放",
        .released => "本次链路资源已释放",
        .unknown => "本次链路资源释放待核实",
    };
}
pub fn failureText(err: ?anyerror) []const u8 {
    return if (err) |failure| switch (failure) {
        error.AuthenticationFailed, error.AgentIdentityNotAccepted => "服务器未接受认证信息",
        error.ConnectionTimedOut, error.ConnectionTimeout, error.ConnectTimeout, error.Timeout => "连接超时",
        error.ConnectFailed => "无法建立 TCP 连接，请检查地址、端口与网络",
        error.ConnectionRefused => "连接被拒绝",
        error.HostKeyChanged => "服务器主机密钥已变化",
        error.HostKeyConfirmationRequired => "主机身份尚未确认",
        error.HostKeyRevoked => "服务器主机密钥已被撤销",
        error.Cancelled => "已取消",
        error.SftpSubsystemDenied => "服务器拒绝 SFTP 子系统",
        else => @errorName(failure),
    } else "连接失败";
}
fn prepareCustomButton(button: *ui.Node) void {
    for (button.children.items) |child| child.setDisplay(.none);
}
fn resourceName(kind: ssh.ResourceKind) []const u8 {
    return switch (kind) {
        .transport => "网络连接",
        .session => "SSH 会话",
        .shell => "终端通道",
        .tunnel => "隧道",
        .relay_socket => "转发连接",
        .relay_worker => "转发任务",
        .rtt_channel => "延迟检测通道",
    };
}
