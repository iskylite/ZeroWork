//! Actual modal/widgets plus the production journal; no window or network.
const std = @import("std");
const ui = @import("ui");
const P = @import("ui/connection_progress_view.zig");
const Auth = @import("ui/auth_challenge_view.zig");
const ssh = @import("proto/ssh/session.zig");
const theme = @import("ui/app_theme.zig");
const a = std.testing.allocator;

test "idle connection progress hide does not request another frame" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.view.hide();
    f.cx.needs_redraw = false;
    f.view.hide();
    try std.testing.expect(!f.cx.needs_redraw);
    try std.testing.expectEqual(@as(usize, 0), f.cancellations);
}
const key: P.OperationKey = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(33), .generation = 1 } }, .operation_id = 12, .attempt_id = 1 };
const direct = [_]P.Hop{.{ .name = "DB", .host = "db.example", .user = "admin" }};
const route = [_]P.Hop{ .{ .name = "Bastion-01", .host = "b1.example", .user = "ops" }, .{ .name = "Bastion-02", .host = "b2.example", .user = "ops" }, direct[0] };

const Fixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    view: *P.View,
    journal: P.progress.Journal = .{},
    cancellations: usize = 0,
    retries: usize = 0,
    closes: usize = 0,
    copies: usize = 0,
    copied: ?[]u8 = null,
    copy_error: bool = false,
    last_key: ?P.OperationKey = null,
    fn init(self: *Fixture) !void {
        self.* = .{ .cx = try ui.Cx.init(a, std.testing.io), .scope = undefined, .view = undefined };
        self.cx.setViewport(1440, 900);
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill() }, .{});
        self.scope = try ui.Scope.init(a, null, self.cx.owner);
        self.view = try P.View.mount(self.cx, self.scope, .{ .context = self, .cancel = cancel, .retry = retry, .close = close, .copy_logs = copy });
        self.journal.begin(1);
    }
    fn deinit(self: *Fixture) void {
        self.scope.dispose();
        self.cx.deinit();
        if (self.copied) |text| a.free(text);
    }
    fn cancel(raw: *anyopaque, captured: P.OperationKey) void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.cancellations += 1;
        self.last_key = captured;
    }
    fn retry(raw: *anyopaque, captured: P.OperationKey) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.retries += 1;
        self.last_key = captured;
    }
    fn close(raw: *anyopaque, captured: P.OperationKey) void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.closes += 1;
        self.last_key = captured;
    }
    fn copy(raw: *anyopaque, captured: P.OperationKey, text: []const u8) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (self.copy_error) return error.ClipboardUnavailable;
        const owned = try a.dupe(u8, text);
        if (self.copied) |old| a.free(old);
        self.copied = owned;
        self.copies += 1;
        self.last_key = captured;
    }
    fn record(self: *Fixture, hop: usize, count: usize, phase: P.progress.Phase, status: P.progress.Status) void {
        self.journal.record(.{ .attempt = self.journal.attempt, .timestamp_ns = @as(i128, @intCast(self.journal.count)) * 50 * std.time.ns_per_ms, .hop = hop, .hop_count = count, .host = if (count == 1 or (count == 2 and hop == 1)) direct[0].host else route[hop].host, .port = 22, .phase = phase, .status = status, .failure = if (status == .failed) error.AuthenticationFailed else null });
    }
    fn snapshot(self: *Fixture, hops: []const P.Hop) P.Snapshot {
        return .{ .key = key, .hops = hops, .journal = self.journal.snapshot(), .local_ready = true };
    }
    fn show(self: *Fixture, source: P.Snapshot) !void {
        try self.view.show(source);
        self.cx.layout();
    }
};

test "connection progress view direct and routed facts keep the current hop distinct from waiting nodes" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.record(0, 1, .transport, .started);
    try f.show(f.snapshot(&direct));
    try std.testing.expectEqual(@as(usize, 2), f.view.slot_count);
    try std.testing.expectEqualStrings("admin@db.example:22", f.view.endpoint.getText().?.content);
    try std.testing.expectEqualStrings("TCP 连接中", f.view.slots[1].status.getText().?.content);
    try std.testing.expectEqual(@as(f32, 760), f.view.dialog.globalRect().w);
    try std.testing.expectEqual(@as(f32, 348), f.view.dialog.globalRect().h);
    try std.testing.expectEqualStrings("尝试 1", f.view.attempt.getText().?.content);
    try std.testing.expectEqual(@as(f32, 56), f.view.identity_chip.globalRect().w);
    try std.testing.expectEqual(@as(f32, 24), f.view.identity_chip.globalRect().h);
    try std.testing.expect(f.view.attempt.globalRect().w >= 38);
    try std.testing.expectEqual(@as(f32, 16), f.view.attempt.globalRect().h);
    try std.testing.expect(f.view.root.parent != null);
    try std.testing.expectEqualStrings("直连 DB · 正在连接", f.view.title.getText().?.content);
    for (f.view.slots[0..f.view.slot_count]) |slot| {
        const r = slot.node.globalRect();
        try std.testing.expectApproxEqAbs(r.x + 10, slot.name.globalRect().x, 0.01);
        try std.testing.expectApproxEqAbs(r.y + 10, slot.name.globalRect().y, 0.01);
        try std.testing.expectApproxEqAbs(r.y + 30, slot.endpoint.globalRect().y, 0.01);
        try std.testing.expectApproxEqAbs(r.y + 46, slot.user.globalRect().y, 0.01);
        try std.testing.expectApproxEqAbs(r.y + 62, slot.status.globalRect().y, 0.01);
    }
    try std.testing.expectApproxEqAbs(f.view.footer.globalRect().x + 516, f.view.footer_hint.globalRect().x, 0.01);
    try std.testing.expectApproxEqAbs(f.view.cancel_button.?.globalRect().x + 56, f.view.cancel_label.?.globalRect().x + f.view.cancel_label.?.globalRect().w / 2, 0.01);
    try std.testing.expectEqual(@as(f32, 16), f.view.copy_icon.?.globalRect().w);
    f.view.cancel();
    f.view.cancel();
    try std.testing.expectEqual(@as(usize, 1), f.cancellations);
    try std.testing.expect(f.last_key.?.eql(key));
    var other = f.snapshot(&direct);
    other.key.owner.session.session_id = @fromBackingInt(999);
    try std.testing.expectError(error.ProgressOwnerMismatch, f.view.show(other));
}

test "connection progress view failed summary remains outside folded logs and retry waits for release facts" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.record(0, 3, .ready, .succeeded);
    f.record(1, 3, .authentication, .failed);
    var source = f.snapshot(&route);
    source.state = .failed;
    source.cleanup = .releasing;
    var ledger = try ssh.ResourceLedger.init(key, 3);
    _ = ledger.record(key, 0, .session, .owned);
    source.resources = ledger.snapshot();
    try f.show(source);
    f.view.retry();
    try std.testing.expectEqual(@as(usize, 0), f.retries);
    try std.testing.expectEqualStrings("第 2 跳 Bastion-02 · SSH 认证失败", f.view.summary_title.getText().?.content);
    try std.testing.expect(std.mem.indexOf(u8, f.view.summary_detail.getText().?.content, "后续受阻：DB") != null);
    try std.testing.expectEqualStrings("受阻 · 未连接", f.view.slots[3].status.getText().?.content);
    try std.testing.expectEqual(@as(f32, 364), f.view.dialog.globalRect().h);
    try std.testing.expectEqualStrings("2 级跳板 · DB · 连接失败", f.view.title.getText().?.content);
    try std.testing.expect(f.view.close_disabled.peek());
    f.view.close();
    try std.testing.expect(f.view.isVisible());
    try std.testing.expectEqual(@as(usize, 0), f.closes);
    _ = ledger.record(key, 0, .session, .unknown);
    source.cleanup = .unknown;
    source.resources = ledger.snapshot();
    try f.show(source);
    f.view.retry();
    try std.testing.expectEqual(@as(usize, 0), f.retries);
    try std.testing.expect(std.mem.indexOf(u8, f.view.resource_text.getText().?.content, "待核实") != null);
    f.view.close();
    try std.testing.expect(f.view.isVisible());
    try std.testing.expectEqual(@as(usize, 0), f.closes);
    try std.testing.expectEqual(@as(@TypeOf(f.view.logs_scroll.container.style.display), .none), f.view.logs_scroll.container.style.display);
    f.view.toggleLogs();
    f.cx.layout();
    try std.testing.expectEqual(@as(f32, 412), f.view.dialog.globalRect().h);
    try std.testing.expectApproxEqAbs(f.view.dialog.globalRect().y + f.view.dialog.globalRect().h - 12, f.view.footer.globalRect().y + 34, 0.01);
    _ = ledger.record(key, 0, .session, .released);
    source.cleanup = .released;
    source.resources = ledger.snapshot();
    try f.show(source);
    try std.testing.expect(!f.view.close_disabled.peek());
    try std.testing.expectApproxEqAbs(f.view.footer.globalRect().x + 484, f.view.close_button.?.globalRect().x, 0.01);
    try std.testing.expectApproxEqAbs(f.view.footer.globalRect().x + 580, f.view.retry_button.?.globalRect().x, 0.01);
    try std.testing.expectEqualStrings("已释放", f.view.slots[1].status.getText().?.content);
    try std.testing.expectEqualStrings("失败 · 已释放", f.view.slots[2].status.getText().?.content);
    f.view.toggleLogs();
    f.cx.layout();
    const panel_rect = f.view.dialog.globalRect();
    const body_rect = f.view.body_scroll.container.globalRect();
    const toggle_rect = f.view.toggle_button.globalRect();
    try std.testing.expectApproxEqAbs(panel_rect.x + 12, f.view.endpoint.globalRect().x, 0.01);
    try std.testing.expect(toggle_rect.y >= body_rect.y);
    try std.testing.expect(toggle_rect.y + toggle_rect.h <= body_rect.y + body_rect.h + 0.01);
    // A native theme/style replay may run after the initial mount. The next
    // rendered layout must still keep the whole folded-log control reachable.
    f.view.modal_body.setStyleInline(f.cx.allocator, .{ .padding = ui.Padding.all(16) });
    _ = f.cx.render();
    try std.testing.expectEqual(ui.Padding{}, f.view.modal_body.style.padding);
    const replay_body = f.view.body_scroll.container.globalRect();
    const replay_toggle = f.view.toggle_button.globalRect();
    try std.testing.expect(replay_toggle.y + replay_toggle.h <= replay_body.y + replay_body.h + 0.01);
    f.view.retry();
    f.view.retry();
    try std.testing.expectEqual(@as(usize, 1), f.retries);
    try std.testing.expect(f.last_key.?.eql(key));
}

test "connection progress view protocol completion does not close before the exact attached receipt" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.record(0, 1, .ready, .succeeded);
    var source = f.snapshot(&direct);
    source.state = .protocol_ready;
    try f.show(source);
    try std.testing.expect(f.view.isVisible());
    try std.testing.expect(f.view.open.peek());
    source.attached = true;
    try f.show(source);
    try std.testing.expect(!f.view.isVisible());
    try std.testing.expect(!f.view.open.peek());
}

test "connection progress view copies only owned real diagnostics and rejects stale attempts or another owner history" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.record(0, 1, .transport, .started);
    const previous = f.snapshot(&direct);
    const old_record: P.LogRecord = .{ .key = key, .entry = previous.journal.entries[0] };
    var new_key = key;
    new_key.attempt_id = 2;
    new_key.operation_id += 1;
    f.journal.begin(2);
    f.record(0, 1, .transport, .started);
    var records = [_]P.LogRecord{ old_record, .{ .key = new_key, .entry = f.journal.snapshot().entries[0] } };
    var source = f.snapshot(&direct);
    source.key = new_key;
    source.state = .retrying;
    source.logs = &records;
    source.dropped = 4;
    try f.show(source);
    records[0].entry.host[0] = 'x';
    f.view.copyLogs();
    try std.testing.expectEqual(@as(usize, 1), f.copies);
    try std.testing.expect(f.last_key.?.eql(new_key));
    try std.testing.expect(std.mem.indexOf(u8, f.copied.?, "尝试 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, f.copied.?, "尝试 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, f.copied.?, "db.example") != null);
    try std.testing.expectEqualStrings("已复制阶段日志", f.view.log_help.getText().?.content);
    try f.show(source);
    try std.testing.expectEqualStrings("已复制阶段日志", f.view.log_help.getText().?.content);
    f.copy_error = true;
    f.view.copyLogs();
    try std.testing.expectEqualStrings("复制失败，请重试", f.view.log_help.getText().?.content);
    try f.show(source);
    try std.testing.expectEqualStrings("复制失败，请重试", f.view.log_help.getText().?.content);
    try std.testing.expectError(error.StaleProgress, f.view.show(previous));
    records[0].key.owner.session.session_id = @fromBackingInt(999);
    try std.testing.expectError(error.InvalidLogOwner, f.view.show(source));
}

test "connection progress view cancellation keeps its original modal until release and then closes without another cancel" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.record(0, 1, .transport, .started);
    var source = f.snapshot(&direct);
    try f.show(source);
    f.view.close();
    try std.testing.expectEqual(@as(usize, 1), f.cancellations);
    try std.testing.expect(f.view.operationKey().?.eql(key));
    source.state = .cancelled;
    source.cleanup = .releasing;
    try f.show(source);
    f.view.close();
    try std.testing.expect(f.view.isVisible());
    try std.testing.expectEqual(@as(usize, 0), f.closes);
    source.cleanup = .released;
    try f.show(source);
    try std.testing.expectEqualStrings("直连 DB · 连接已取消", f.view.title.getText().?.content);
    try std.testing.expectEqualStrings("连接已取消", f.view.summary_title.getText().?.content);
    f.view.close();
    try std.testing.expect(!f.view.isVisible());
    try std.testing.expect(f.view.operationKey() == null);
    try std.testing.expectEqual(@as(usize, 1), f.cancellations);
    try std.testing.expectEqual(@as(usize, 1), f.closes);
    try std.testing.expect(f.last_key.?.eql(key));
}

test "connection progress view original modal routes inline IME Escape once and preserves the field on update and theme" {
    const Recorder = struct {
        bridge: Auth.auth.InteractiveBridge = .{},
        cancelled: usize = 0,
        fn submit(raw: *anyopaque, id: Auth.auth.RequestIdentity, reply: Auth.auth.Reply) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try self.bridge.submit(id, reply);
        }
        fn cancel(raw: *anyopaque, id: Auth.auth.RequestIdentity) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.bridge.cancelRequest(id)) self.cancelled += 1;
        }
    };
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.record(0, 1, .authentication, .started);
    var source = f.snapshot(&direct);
    source.state = .waiting_auth;
    source.inline_authentication = true;
    try f.show(source);
    var recorder: Recorder = .{};
    const auth = try Auth.View.mount(f.cx, f.scope, .{ .context = &recorder, .submit = Recorder.submit, .cancel = Recorder.cancel });
    try f.view.authentication_area.appendChild(a, auth.root);
    _ = try recorder.bridge.offerChallenge(.{ .key = key, .kind = .keyboard_interactive, .hop_index = 0, .endpoint_identity = .{ .host = direct[0].host, .user = direct[0].user }, .prompts = &.{.{ .text = "Response:", .echo = true }}, .presentation = .protected_form, .presentation_config_revision = 1 });
    try auth.show(recorder.bridge.snapshot().?);
    f.cx.layout();
    const input = auth.fields[0].input.state;
    f.cx.setFocus(auth.fields[0].input.input_container);
    f.cx.handleTextInput("answer");
    _ = input.setAccessibilitySelection(1, 3);
    f.cx.handleImePreedit("pin", 3);
    const cursor = input.cursor_pos;
    const anchor = input.selection_anchor;
    try f.show(source);
    f.view.toggleLogs();
    const previous_theme = theme.currentName();
    defer theme.select(previous_theme);
    for ([_]theme.Name{ .dark, .light, .sauber }) |name| {
        theme.select(name);
        f.cx.setTheme(theme.widgetTheme(name));
        try f.view.retheme();
        try auth.retheme();
        try std.testing.expectEqual(ui.Color.WHITE, auth.submit_label.getText().?.color);
        try std.testing.expectEqual(ui.Color.WHITE, f.view.retry_label.?.getText().?.color);
        try std.testing.expectEqual(theme.current().overlay, f.view.dialog.getBackground());
    }
    try std.testing.expectEqual(input, auth.fields[0].input.state);
    try std.testing.expect(auth.isComposing());
    try std.testing.expectEqual(cursor, input.cursor_pos);
    try std.testing.expectEqual(anchor, input.selection_anchor);
    try std.testing.expect(auth.modal == null);
    try std.testing.expect(f.cx.isFocused(auth.fields[0].input.input_container));
    f.cx.handleKeyDown(.escape, .{});
    try std.testing.expect(!auth.isComposing());
    try std.testing.expectEqual(@as(usize, 0), recorder.cancelled);
    try std.testing.expectEqual(@as(usize, 0), f.cancellations);
    try std.testing.expect(f.view.open.peek());
    f.cx.handleKeyDown(.escape, .{});
    try std.testing.expectEqual(@as(usize, 1), recorder.cancelled);
    try std.testing.expectEqual(@as(usize, 0), f.cancellations);
}

test "connection progress view all routed variants use their actual current node and downstream waiting" {
    const cases = [_]struct { count: usize, current: usize, phase: P.progress.Phase }{
        .{ .count = 2, .current = 0, .phase = .authentication },
        .{ .count = 3, .current = 1, .phase = .authentication },
        .{ .count = 2, .current = 1, .phase = .transport },
    };
    for (cases) |case| {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        const hops: []const P.Hop = if (case.count == 3) &route else &.{ route[0], direct[0] };
        for (0..case.current) |hop| f.record(hop, case.count, .ready, .succeeded);
        f.record(case.current, case.count, case.phase, .started);
        try f.show(f.snapshot(hops));
        try std.testing.expectEqualStrings(hops[case.current].name, f.view.slots[case.current + 1].name.getText().?.content);
        try std.testing.expect(std.mem.indexOf(u8, f.view.slots[case.current + 1].status.getText().?.content, P.phaseName(case.phase)) != null);
        for (case.current + 1..case.count) |hop| try std.testing.expectEqualStrings("等待上游", f.view.slots[hop + 1].status.getText().?.content);
        for (0..case.current) |hop| try std.testing.expectEqualStrings("已认证", f.view.slots[hop + 1].status.getText().?.content);
    }
}

test "connection progress view log follow pauses on scroll new rows stay pending and compact footer remains reachable" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const hops = [_]P.Hop{ route[0], direct[0] };
    for ([_]P.progress.Phase{ .transport, .handshake, .host_key, .authentication, .ready }) |phase| {
        f.record(0, 2, phase, .started);
        f.record(0, 2, phase, .succeeded);
    }
    for ([_]P.progress.Phase{ .transport, .handshake, .host_key, .authentication }) |phase| {
        f.record(1, 2, phase, .started);
        f.record(1, 2, phase, .succeeded);
    }
    f.record(1, 2, .shell, .started);
    try f.show(f.snapshot(&hops));
    f.view.toggleLogs();
    f.cx.advanceFrameClock();
    _ = f.cx.render();
    const scroll = f.view.logs_scroll;
    try std.testing.expect(scroll.state.maxScrollY() > 0);
    try std.testing.expectApproxEqAbs(scroll.state.maxScrollY(), scroll.state.scroll_y, 0.01);
    ui.widgets.scroll_area.setScrollY(scroll.state, scroll.content, 0);
    f.cx.requestRedraw();
    f.cx.advanceFrameClock();
    _ = f.cx.render();
    try std.testing.expect(!f.view.following);
    f.record(1, 2, .shell, .succeeded);
    try f.show(f.snapshot(&hops));
    f.cx.advanceFrameClock();
    _ = f.cx.render();
    try std.testing.expectEqual(@as(f32, 0), scroll.state.scroll_y);
    try std.testing.expectEqual(@as(usize, 1), f.view.new_logs);
    f.view.jumpToBottom();
    try std.testing.expectApproxEqAbs(scroll.state.maxScrollY(), scroll.state.scroll_y, 0.01);
    const choose = f.view.slots[1].node.behavior.events.on_click.?;
    choose.callback(choose.context);
    try std.testing.expectEqual(@as(?usize, 0), f.view.filter);
    try std.testing.expect(std.mem.indexOf(u8, f.view.logs_text.getText().?.content, "b1.example") != null);
    try std.testing.expect(std.mem.indexOf(u8, f.view.logs_text.getText().?.content, "db.example") == null);
    choose.callback(choose.context);
    try std.testing.expect(f.view.filter == null);
    f.cx.setViewport(860, 480);
    try f.show(f.snapshot(&hops));
    try std.testing.expectEqual(@as(f32, 458), f.view.dialog.globalRect().h);
    try std.testing.expectApproxEqAbs(f.view.dialog.globalRect().y + f.view.dialog.globalRect().h - 12, f.view.footer.globalRect().y + 34, 0.01);
}

test "connection progress viewport width changes preserve reachable actions at unchanged height" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.record(0, 1, .transport, .started);
    try f.show(f.snapshot(&direct));
    f.cx.advanceFrameClock();
    _ = f.cx.render();
    const before_height = f.view.dialog.globalRect().h;
    f.cx.setViewport(700, 900);
    f.cx.advanceFrameClock();
    _ = f.cx.render();
    try std.testing.expect(f.view.dialog.globalRect().w <= 684);
    try std.testing.expect(f.view.dialog.globalRect().h <= before_height);
    f.cx.setViewport(620, 900);
    f.cx.advanceFrameClock();
    _ = f.cx.render();
    try std.testing.expect(f.view.dialog.globalRect().w <= 604);
    const panel = f.view.dialog.globalRect();
    const cancel = f.view.cancel_button.?.globalRect();
    try std.testing.expect(cancel.x >= panel.x and cancel.x + cancel.w <= panel.x + panel.w);
}
