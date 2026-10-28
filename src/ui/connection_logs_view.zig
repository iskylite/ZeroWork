//! Read-only connection diagnostics. Snapshot records and endpoint are copied;
//! this view has no session cancel, reconnect or native transport capability.
const std = @import("std");
const ui = @import("ui");
const Progress = @import("connection_progress_view.zig");
pub const details = @import("../proto/ssh/connection_details.zig");
pub const OperationKey = details.OperationKey;
pub const LogRecord = Progress.LogRecord;
const S = @import("connection_logs_styles.zig");
pub const Snapshot = struct {
    key: OperationKey,
    revision: u64 = 1,
    endpoint: details.Endpoint,
    records: []const LogRecord,
    dropped: usize = 0,
    expired: bool = false,
};
pub const Callbacks = struct {
    context: *anyopaque,
    /// Text is borrowed for this call. Return actual clipboard success/failure.
    copy_logs: *const fn (*anyopaque, OperationKey, []const u8) anyerror!void,
};
const Action = struct {
    view: *View,
    key: OperationKey,
    kind: enum { close, copy, bottom },
    fn click(self: *Action) void {
        if (!self.view.matches(self.key)) return;
        switch (self.kind) {
            .close => self.view.hide(),
            .copy => self.view.copyLogs(),
            .bottom => self.view.jumpToBottom(),
        }
    }
    fn cleanup(self: *Action) void {
        self.view.cx.allocator.destroy(self);
    }
};

pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    callbacks: Callbacks,
    root: *ui.Node,
    dialog: *ui.Node,
    form: *ui.Node,
    open: *ui.Signal(bool),
    copy_disabled: *ui.Signal(bool),
    source: ?Snapshot = null,
    owned_records: []LogRecord = &.{},
    visible: bool = false,
    invalidated: bool = false,
    form_scope: ?*ui.Scope = null,
    dirty: bool = false,
    rebuild_requested: bool = true,
    viewport: ui.Size = .ZERO,
    identity: *ui.Node = undefined,
    meta: *ui.Node = undefined,
    logs_scroll: ui.widgets.ScrollAreaResult = undefined,
    logs_text: *ui.Node = undefined,
    footer: *ui.Node = undefined,
    feedback: *ui.Node = undefined,
    bottom_button: *ui.Node = undefined,
    copy_button: *ui.Node = undefined,
    close_button: *ui.Node = undefined,
    focus_pending: bool = false,
    following: bool = true,
    last_scroll_y: f32 = 0,
    new_records: usize = 0,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, callbacks: Callbacks) !*View {
        const self = try cx.allocator.create(View);
        var registered = false;
        errdefer if (!registered) cx.allocator.destroy(self);
        const open = try scope.createSignal(bool, false);
        const disabled = try scope.createSignal(bool, true);
        self.* = .{ .cx = cx, .scope = scope, .callbacks = callbacks, .root = undefined, .dialog = undefined, .form = undefined, .open = open, .copy_disabled = disabled };
        try scope.onCleanup(View, self, cleanup);
        registered = true;
        const modal = try ui.widgets.Modal(.{ .open = open, .width = S.width, .max_height = @max(160, cx.viewport.height - S.margin * 2), .background = S.theme.current().overlay, .on_open_change = cx.on(View, self, openChanged) }).mount(scope, cx);
        self.root = modal.overlay;
        self.dialog = modal.dialog;
        self.form = modal.body;
        self.dialog.meta.ownership.meta.test_id = "connection.logs";
        self.dialog.setStyleInline(cx.allocator, S.panel(cx.viewport));
        self.form.setStyleInline(cx.allocator, S.form());
        if (!modal.portaled) if (cx.root) |root| try root.appendChild(cx.allocator, modal.overlay);
        try cx.addAfterLayoutHook(self, afterLayout);
        return self;
    }

    /// Explicitly open one capture. Changing the active tab cannot retarget it.
    pub fn show(self: *View, source: Snapshot) !void {
        try validate(source);
        const same = if (self.source) |current| current.key.eql(source.key) else false;
        if (same and (self.invalidated or self.source.?.expired)) {
            if (source.revision < self.source.?.revision) return error.StaleLogs;
            if (!std.meta.eql(source.endpoint, self.source.?.endpoint)) return error.FrozenEndpointChanged;
            // Explicit reopen may display the already captured expired data;
            // it cannot replace those records or make the old key current.
        } else if (same) try self.update(source) else {
            try self.freeze(source);
            self.invalidated = false;
            self.following = true;
            self.new_records = 0;
            self.rebuild_requested = true;
        }
        self.visible = true;
        self.dirty = true;
        try self.flush();
        self.open.set(true);
        self.focus_pending = true;
        self.cx.requestRedraw();
    }
    pub fn update(self: *View, source: Snapshot) !void {
        try validate(source);
        const current = self.source orelse return error.LogsNotVisible;
        if (!current.key.eql(source.key)) return error.LogOwnerMismatch;
        if (source.revision < current.revision or self.invalidated or (current.expired and !source.expired)) return error.StaleLogs;
        if (!std.meta.eql(current.endpoint, source.endpoint)) return error.FrozenEndpointChanged;
        if (source.revision == current.revision) return;
        self.observeScroll();
        if (!self.following) {
            const old_last = if (current.records.len != 0) current.records[current.records.len - 1] else null;
            var added = source.records.len;
            if (old_last) |last| for (source.records, 0..) |record, index| {
                if (record.key.eql(last.key) and record.entry.sequence == last.entry.sequence) {
                    added = source.records.len - index - 1;
                    break;
                }
            };
            self.new_records +|= added;
        }
        try self.freeze(source);
        self.dirty = true;
        self.cx.requestRedraw();
    }
    pub fn invalidate(self: *View, key: OperationKey) void {
        if (self.source == null or !self.source.?.key.eql(key) or self.invalidated) return;
        self.invalidated = true;
        self.dirty = true;
        self.cx.requestRedraw();
    }
    /// Call at a safe UI hook, after show/update, and after viewport changes.
    pub fn flush(self: *View) !void {
        if (!self.visible or self.source == null) return;
        if (self.rebuild_requested or self.form_scope == null) {
            self.rebuild_requested = false;
            try self.build();
            self.dirty = true;
        }
        if (!std.meta.eql(self.viewport, self.cx.viewport)) {
            self.viewport = self.cx.viewport;
            self.dialog.setStyleInline(self.cx.allocator, S.panel(self.viewport));
        }
        self.observeScroll();
        if (self.dirty) {
            self.dirty = false;
            try self.refresh();
        }
        self.syncScroll();
    }
    pub fn retheme(self: *View) !void {
        self.rebuild_requested = true;
        try self.flush();
    }
    pub fn isVisible(self: *const View) bool {
        return self.visible;
    }
    pub fn hide(self: *View) void {
        self.visible = false;
        self.focus_pending = false;
        self.open.set(false);
        self.cx.requestRedraw();
    }
    fn openChanged(self: *View, value: bool) void {
        if (!value) self.hide();
    }
    fn matches(self: *const View, key: OperationKey) bool {
        return self.visible and self.source != null and self.source.?.key.eql(key);
    }
    fn freeze(self: *View, source: Snapshot) !void {
        const records = try self.cx.allocator.dupe(LogRecord, source.records);
        self.cx.allocator.free(self.owned_records);
        self.owned_records = records;
        var frozen = source;
        frozen.records = records;
        self.source = frozen;
    }

    fn build(self: *View) !void {
        if (self.cx.focus_manager.current_focus) |focused| if (focused.isDescendantOf(self.form)) {
            self.cx.clearFocus();
            self.focus_pending = self.visible;
        };
        while (self.form.children.items.len != 0) {
            const child = self.form.children.items[0];
            self.cx.detachChild(self.form, child);
            self.cx.destroyDetached(child);
        }
        if (self.form_scope) |old| old.dispose();
        self.form_scope = null;
        const scope = try self.scope.childScope();
        self.form_scope = scope;
        self.dialog.setStyleInline(self.cx.allocator, S.panel(self.cx.viewport));
        const head = try ui.box(self.cx, S.header(), .{});
        try head.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.get("file-text").?, S.theme.current().accent, S.icon(18)));
        _ = try label(self.cx, head, "连接日志", S.title(), S.titleBox());
        const close_context = try self.action(scope, .close);
        const close = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = "关闭连接日志", .base_style = S.closeIcon(), .hover_style = S.hover(), .on_click = self.cx.on(Action, close_context, Action.click) }).mount(scope, self.cx);
        try close.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.x, S.theme.current().fg_2, S.icon(16)));
        close.meta.ownership.meta.test_id = "connection.logs.header-close";
        try head.appendChild(self.cx.allocator, close);
        try self.form.appendChild(self.cx.allocator, head);
        const body = try ui.box(self.cx, S.body(), .{});
        try self.form.appendChild(self.cx.allocator, body);
        self.identity = try label(self.cx, body, "", S.identity(), S.labelBox(S.identity_height));
        self.identity.meta.ownership.meta.test_id = "connection.logs.endpoint";
        self.meta = try label(self.cx, body, "", S.meta(), S.labelBox(S.meta_height));
        self.meta.meta.ownership.meta.test_id = "connection.logs.meta";
        self.logs_scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical, .rubber_band_y = false }).mount(scope, self.cx);
        self.logs_scroll.container.setStyleInline(self.cx.allocator, S.well());
        self.logs_scroll.content.setStyleInline(self.cx.allocator, S.logContent());
        self.logs_scroll.container.meta.ownership.meta.test_id = "connection.logs.body";
        self.logs_text = try label(self.cx, self.logs_scroll.content, "", S.logs(), S.logTextBox());
        self.logs_text.meta.ownership.meta.test_id = "connection.logs.records";
        try body.appendChild(self.cx.allocator, self.logs_scroll.container);
        self.footer = try ui.box(self.cx, S.footer(), .{});
        self.feedback = try label(self.cx, self.footer, "", S.meta(), S.feedbackBox());
        self.feedback.meta.ownership.meta.test_id = "connection.logs.feedback";
        const bottom_context = try self.action(scope, .bottom);
        self.bottom_button = try ui.widgets.Button(.{ .label = "回到底部", .variant = .ghost, .base_style = S.button(112, 28, false), .hover_style = S.hover(), .on_click = self.cx.on(Action, bottom_context, Action.click) }).mount(scope, self.cx);
        self.bottom_button.meta.ownership.meta.test_id = "connection.logs.bottom";
        try self.footer.appendChild(self.cx.allocator, self.bottom_button);
        const copy_context = try self.action(scope, .copy);
        self.copy_button = try ui.widgets.Button(.{ .label = "复制日志", .variant = .primary, .disabled = self.copy_disabled, .base_style = S.button(112, 34, true), .on_click = self.cx.on(Action, copy_context, Action.click) }).mount(scope, self.cx);
        self.copy_button.meta.ownership.meta.test_id = "connection.logs.copy";
        try self.footer.appendChild(self.cx.allocator, self.copy_button);
        const done_context = try self.action(scope, .close);
        self.close_button = try ui.widgets.Button(.{ .label = "关闭", .variant = .secondary, .base_style = S.button(88, 34, false), .hover_style = S.hover(), .on_click = self.cx.on(Action, done_context, Action.click) }).mount(scope, self.cx);
        self.close_button.meta.ownership.meta.test_id = "connection.logs.close";
        try self.footer.appendChild(self.cx.allocator, self.close_button);
        try body.appendChild(self.cx.allocator, self.footer);
        try @import("compact_overlay_layout.zig").mount(self.cx, scope, self.dialog, self.logs_scroll.container, self.logs_scroll.content, 158, S.well_height, null, 0);
        self.last_scroll_y = 0;
    }
    fn action(self: *View, scope: *ui.Scope, kind: @FieldType(Action, "kind")) !*Action {
        const context = try self.cx.allocator.create(Action);
        errdefer self.cx.allocator.destroy(context);
        context.* = .{ .view = self, .key = self.source.?.key, .kind = kind };
        try scope.onCleanup(Action, context, Action.cleanup);
        return context;
    }
    fn refresh(self: *View) !void {
        const source = &self.source.?;
        var endpoint: [2048]u8 = undefined;
        try self.identity.setTextContent(self.cx.allocator, try endpointText(&endpoint, &source.endpoint));
        var status: [256]u8 = undefined;
        var status_writer: std.Io.Writer = .fixed(&status);
        try status_writer.print("{s} · 尝试 {d} · {d} 条记录", .{ if (self.invalidated or source.expired) "已过期" else "只读", source.key.attempt_id.?, source.records.len });
        if (source.dropped != 0) try status_writer.print(" · 已省略 {d} 条旧日志", .{source.dropped});
        try self.meta.setTextContent(self.cx.allocator, status_writer.buffered());
        var text: std.Io.Writer.Allocating = .init(self.cx.allocator);
        defer text.deinit();
        try writeDisplayRecords(&text.writer, source.records);
        try self.logs_text.setTextContent(self.cx.allocator, if (source.records.len == 0) "暂无连接阶段日志" else text.writer.buffered());
        try @import("log_typography.zig").apply(self.cx, self.logs_text);
        self.copy_disabled.set(source.records.len == 0);
        try self.refreshScrollFeedback();
    }
    pub fn copyLogs(self: *View) void {
        if (!self.visible or self.source == null or self.source.?.records.len == 0) return;
        var text: std.Io.Writer.Allocating = .init(self.cx.allocator);
        defer text.deinit();
        self.writeReport(&text.writer) catch {
            self.copyFeedback(false);
            return;
        };
        self.callbacks.copy_logs(self.callbacks.context, self.source.?.key, text.writer.buffered()) catch {
            self.copyFeedback(false);
            return;
        };
        self.copyFeedback(true);
    }
    pub fn writeReport(self: *const View, writer: *std.Io.Writer) !void {
        const source = self.source orelse return error.LogsNotVisible;
        var endpoint: [2048]u8 = undefined;
        try writer.print("连接日志 · {s}\n{s} · 尝试 {d} · 已省略 {d} 条旧日志\n", .{ try endpointText(&endpoint, &source.endpoint), if (self.invalidated or source.expired) "已过期" else "只读", source.key.attempt_id.?, source.dropped });
        try writeRecords(writer, source.records);
    }
    fn copyFeedback(self: *View, success: bool) void {
        self.feedback.setTextContent(self.cx.allocator, if (success) "已复制连接日志" else "复制失败，请重试") catch {};
        self.cx.requestRedraw();
    }
    pub fn jumpToBottom(self: *View) void {
        self.following = true;
        self.new_records = 0;
        self.feedback.setTextContent(self.cx.allocator, "") catch {};
        self.syncScroll();
        self.refreshScrollFeedback() catch {};
        self.cx.requestRedraw();
    }
    fn observeScroll(self: *View) void {
        if (self.form_scope == null) return;
        const state = self.logs_scroll.state;
        if (@abs(state.scroll_y - self.last_scroll_y) < 0.5) return;
        self.following = state.scroll_y >= state.maxScrollY() - 1;
        if (self.following and self.new_records != 0) {
            self.new_records = 0;
            self.feedback.setTextContent(self.cx.allocator, "") catch {};
        }
        self.last_scroll_y = state.scroll_y;
        self.refreshScrollFeedback() catch {};
    }
    fn syncScroll(self: *View) void {
        const scroll = self.logs_scroll;
        scroll.state.content_height = scroll.content.globalRect().h;
        scroll.state.viewport_height = scroll.container.globalRect().h;
        if (self.following) ui.widgets.scroll_area.setScrollY(scroll.state, scroll.content, scroll.state.maxScrollY());
        self.last_scroll_y = scroll.state.scroll_y;
    }
    fn refreshScrollFeedback(self: *View) !void {
        self.bottom_button.setDisplay(if (self.following) .none else .flex);
        if (self.new_records != 0) {
            var buffer: [96]u8 = undefined;
            try self.feedback.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&buffer, "{d} 条新日志", .{self.new_records}));
        }
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        if (self.visible and self.focus_pending and self.form_scope != null and self.dialog.globalRect().w > 0) {
            self.focus_pending = false;
            self.cx.setFocus(self.close_button);
        }
        return .done;
    }
    fn cleanup(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
        self.cx.allocator.free(self.owned_records);
        self.cx.allocator.destroy(self);
    }
};

pub fn validate(source: Snapshot) !void {
    if (source.key.operation_id == 0 or source.key.attempt_id == null or source.key.attempt_id == 0 or source.revision == 0 or source.records.len > Progress.progress.Journal.capacity) return error.InvalidLogs;
    if (source.key.owner != .session and source.key.owner != .app) return error.InvalidLogOwner;
    if (source.key.owner == .session and (@backingInt(source.key.owner.session.session_id) == 0 or source.key.owner.session.generation == 0)) return error.InvalidLogOwner;
    if (source.endpoint.host.len > source.endpoint.host.bytes.len or source.endpoint.user.len > source.endpoint.user.bytes.len or source.endpoint.name.len > source.endpoint.name.bytes.len or source.endpoint.port == 0) return error.InvalidEndpoint;
    for (source.records, 0..) |record, index| {
        if (!belongs(record.key, source.key) or record.entry.hop_count == 0 or record.entry.hop_count > details.max_hops or record.entry.hop >= record.entry.hop_count or record.entry.host_len > record.entry.host.len) return error.InvalidLogOwner;
        for (source.records[0..index]) |previous| if (previous.key.eql(record.key) and previous.entry.sequence >= record.entry.sequence) return error.InvalidLogOrder;
        if (index != 0) {
            const previous = source.records[index - 1];
            if (previous.key.attempt_id.? > record.key.attempt_id.?) return error.InvalidLogOrder;
        }
    }
}
fn belongs(record: OperationKey, captured: OperationKey) bool {
    if (record.operation_id == 0 or record.attempt_id == null or record.attempt_id == 0 or record.attempt_id.? > captured.attempt_id.?) return false;
    if (record.eql(captured)) return true;
    if (record.owner == .session and captured.owner == .session) return record.owner.session.session_id == captured.owner.session.session_id and record.owner.session.generation != 0 and record.owner.session.generation < captured.owner.session.generation and record.attempt_id.? < captured.attempt_id.?;
    return record.owner == .app and captured.owner == .app and record.operation_id == captured.operation_id;
}
fn writeDisplayRecords(writer: *std.Io.Writer, records: []const LogRecord) !void {
    for (records, 0..) |record, index| {
        var start = record.entry.timestamp_ns;
        for (records[0..index]) |earlier| if (earlier.key.eql(record.key)) {
            start = earlier.entry.timestamp_ns;
            break;
        };
        const ms = @divTrunc(@max(0, record.entry.timestamp_ns - start), std.time.ns_per_ms);
        try writer.print("+{d}.{d:0>3}s  {s} · {s}\n         {s}:{d} · 第 {d} 跳 · 尝试 {d} · #{d}\n", .{ @divTrunc(ms, 1000), @mod(ms, 1000), Progress.phaseName(record.entry.phase), resultText(record.entry), record.entry.hostSlice(), record.entry.port, record.entry.hop + 1, record.key.attempt_id.?, record.entry.sequence });
    }
}
fn writeRecords(writer: *std.Io.Writer, records: []const LogRecord) !void {
    for (records, 0..) |record, index| {
        var start = record.entry.timestamp_ns;
        for (records[0..index]) |earlier| if (earlier.key.eql(record.key)) {
            start = earlier.entry.timestamp_ns;
            break;
        };
        const ms = @divTrunc(@max(0, record.entry.timestamp_ns - start), std.time.ns_per_ms);
        try writer.print("+{d}.{d:0>3}s [尝试 {d} · #{d}] 第 {d} 跳 {s}:{d} | {s} | {s}\n", .{ @divTrunc(ms, 1000), @mod(ms, 1000), record.key.attempt_id.?, record.entry.sequence, record.entry.hop + 1, record.entry.hostSlice(), record.entry.port, Progress.phaseName(record.entry.phase), resultText(record.entry) });
    }
}
fn resultText(entry: Progress.progress.Journal.Entry) []const u8 {
    return switch (entry.status) {
        .started => "进行中",
        .succeeded => "完成",
        .cancelled => "已取消",
        .failed => if (entry.failure) |failure| switch (failure) {
            error.AuthenticationFailed, error.AgentIdentityNotAccepted => "服务器未接受认证信息",
            error.ConnectionTimeout, error.Timeout => "连接超时",
            error.ConnectionRefused => "连接被拒绝",
            error.Cancelled => "已取消",
            else => @import("../proto/ssh/handshake_failure.zig").description(failure) orelse @errorName(failure),
        } else "连接失败",
    };
}
fn endpointText(buffer: []u8, value: *const details.Endpoint) ![]const u8 {
    const host = if (value.host.len == 0) "未知" else value.host.slice();
    const user = if (value.user.len == 0) "未知" else value.user.slice();
    const name = if (value.name.len == 0) host else value.name.slice();
    return if (std.mem.indexOfScalar(u8, host, ':') != null) std.fmt.bufPrint(buffer, "{s} · {s}@[{s}]:{d}", .{ name, user, host, value.port }) else std.fmt.bufPrint(buffer, "{s} · {s}@{s}:{d}", .{ name, user, host, value.port });
}
fn label(cx: *ui.Cx, parent: *ui.Node, text: []const u8, style: ui.TextStyle, box: ui.BoxStyle) !*ui.Node {
    const node = try ui.text(cx, "", style);
    node.setStyleInline(cx.allocator, box);
    try node.setTextContent(cx.allocator, text);
    try parent.appendChild(cx.allocator, node);
    return node;
}
