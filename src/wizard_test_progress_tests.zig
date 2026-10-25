//! Real Cx/widgets and original-key probe presentation. No native window.
const std = @import("std");
const ui = @import("ui");
const W = @import("plugins/remote/editor.zig");
const P = W.TestProgress;
const Probe = @import("ui/wizard_probe.zig");
const ProbeHost = @import("ui/probe_connection_host.zig").Host;
const ssh = @import("proto/ssh/session.zig");
const config = @import("config/config.zig");
const a = std.testing.allocator;
const direct = [_]P.Hop{.{ .name = "DB", .host = "db.example", .user = "root", .port = 22 }};
const routed = [_]P.Hop{ .{ .name = "B1", .host = "b1.example", .user = "ops", .port = 22 }, .{ .name = "B2", .host = "b2.example", .user = "ops", .port = 22 }, direct[0] };
const key: P.operations.OperationKey = .{ .owner = .app, .operation_id = 21, .attempt_id = 1 };

const Fixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    wizard: W.RemoteEditor = .{},
    journal: P.progress.Journal = .{},
    cancels: usize = 0,
    cancelled_key: ?P.operations.OperationKey = null,
    fn init(self: *Fixture) !void {
        self.* = .{ .cx = try ui.Cx.init(a, std.testing.io), .scope = undefined };
        try self.cx.setTestFrameStep(100);
        self.cx.setViewport(1440, 900);
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill() }, .{});
        self.scope = try ui.Scope.init(a, null, self.cx.owner);
        self.wizard.on_result = result;
        self.wizard.result_ctx = self;
        self.wizard.on_test = start;
        self.wizard.test_ctx = self;
        self.wizard.on_cancel_test = cancel;
        self.wizard.cancel_test_ctx = self;
        try self.cx.root.?.appendChild(a, try self.wizard.mount(self.cx, self.scope));
        self.wizard.loadDraft(.{ .name = "DB", .host = "db.example", .user = "root" });
        self.wizard.show();
        activate(self.wizard.next1_btn.?);
        activate(self.wizard.next2_btn.?);
        activate(self.wizard.test_btn.?);
        self.journal.begin(1);
        self.settle();
    }
    fn deinit(self: *Fixture) void {
        self.cx.setFocus(null);
        self.scope.dispose();
        self.cx.deinit();
    }
    fn start(_: *anyopaque, _: *const W.Draft) void {}
    fn result(_: *anyopaque, _: W.Result) !?W.SaveReceipt {
        return null;
    }
    fn cancel(raw: *anyopaque, captured: P.operations.OperationKey) void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.cancels += 1;
        self.cancelled_key = captured;
    }
    fn snapshot(self: *Fixture, hops: []const P.Hop) !P.Snapshot {
        var ledger = try ssh.ResourceLedger.init(key, hops.len);
        return .{ .key = key, .generation = self.wizard.test_generation, .draft_id = self.wizard.draft_id, .draft_revision = self.wizard.draft_revision, .hops = hops, .journal = self.journal.snapshot(), .resources = ledger.snapshot(), .finished = false, .cancelled = false, .failure = null, .cleanup = .not_started };
    }
    fn record(self: *Fixture, hop: usize, count: usize, phase: P.progress.Phase, state: P.progress.Status) void {
        self.journal.record(.{ .attempt = self.journal.attempt, .timestamp_ns = @as(i128, @intCast(self.journal.count + self.journal.dropped)) * 10 * std.time.ns_per_ms, .hop = hop, .hop_count = count, .host = "fixture", .port = 22, .phase = phase, .status = state, .failure = if (state == .failed) error.AuthenticationFailed else null });
    }
    fn settle(self: *Fixture) void {
        for (0..8) |_| {
            self.cx.advanceFrameClock();
            self.cx.layout();
            _ = self.wizard.updateViewport();
            _ = self.cx.render();
        }
    }
    fn click(self: *Fixture, id: []const u8) void {
        self.settle();
        const node = findId(self.wizard.root.?, id).?;
        if (self.wizard.scrolls[2]) |scroll| {
            // Summary is now permanently visible; reach lower log controls through the real scroll area.
            ui.widgets.scrollIntoView(scroll.state, scroll.content, node, .nearest);
            self.settle();
        }
        const rect = node.globalRect();
        self.cx.handleClick(rect.x + rect.w / 2, rect.y + rect.h / 2);
        self.settle();
    }
};
fn activate(node: *ui.Node) void {
    const handler = node.behavior.events.on_click.?;
    handler.callback(handler.context);
}
fn findId(node: *ui.Node, id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, value, id)) return node;
    for (node.children.items) |child| if (findId(child, id)) |found| return found;
    return null;
}
fn contains(node: *ui.Node, needle: []const u8) bool {
    return std.mem.indexOf(u8, node.getText().?.content, needle) != null;
}

test "wizard hidden logs cannot intercept a subsequent file authentication pointer" {
    const Authentication = @import("ui/auth_challenge_view.zig");
    const auth = Authentication.auth;
    const AuthenticationContext = struct {
        bridge: auth.InteractiveBridge = .{},
        submissions: usize = 0,
        identity: ?auth.RequestIdentity = null,
        fn submit(raw: *anyopaque, id: auth.RequestIdentity, reply: auth.Reply) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try self.bridge.submit(id, reply);
            self.submissions += 1;
            self.identity = id;
        }
        fn cancel(raw: *anyopaque, id: auth.RequestIdentity) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = self.bridge.cancelRequest(id);
        }
    };
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.wizard.loadDraft(.{ .name = "File", .host = "target.example", .user = "operator", .protocol = .sftp });
    f.wizard.show();
    activate(f.wizard.next1_btn.?);
    activate(f.wizard.next2_btn.?);
    f.settle();
    const test_button = f.wizard.test_btn.?;
    try std.testing.expectEqual(@as(f32, 76), test_button.globalRect().w);
    for (test_button.children.items) |child| if (child.getText()) |label| {
        try std.testing.expectEqualStrings("检测 SFTP", label.content);
        try std.testing.expectEqual(@as(f32, 76), child.globalRect().w);
        try std.testing.expectEqual(@as(f32, 18), child.globalRect().h);
        try std.testing.expectEqual(@as(f32, 12), label.font_size);
        try std.testing.expectEqual(@as(u16, 500), label.font_weight);
        try std.testing.expect(label.text_align == .center and label.text_overflow == .clip);
    };
    activate(f.wizard.test_btn.?);
    try f.cx.setTestFrameStep(100);
    for (0..24) |_| f.record(0, 1, .authentication, .succeeded);
    f.record(0, 1, .ready, .succeeded);
    var complete = try f.snapshot(&direct);
    complete.finished = true;
    complete.cleanup = .released;
    try std.testing.expect(try f.wizard.setTestSnapshot(complete));
    f.settle();
    try std.testing.expect(f.wizard.logs_scroll.?.globalRect().h > 0);
    f.wizard.hide();
    f.settle();

    var context: AuthenticationContext = .{};
    const id = try context.bridge.offerChallenge(.{
        .key = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(9), .generation = 3 } }, .operation_id = 7, .attempt_id = 2 },
        .hop_index = 0,
        .kind = .host_key_unknown,
        .endpoint_identity = .{ .host = "target.example", .user = "operator", .port = 22 },
        .prompts = &.{},
        .presentation = .otp_modal,
        .presentation_config_revision = 1,
    });
    const view = try Authentication.View.mount(f.cx, f.scope, .{ .context = &context, .submit = AuthenticationContext.submit, .cancel = AuthenticationContext.cancel });
    try f.cx.root.?.appendChild(a, view.root);
    try view.show(context.bridge.snapshot().?);
    try view.setDetails(id, .{ .algorithm = "ecdsa-sha2-nistp256", .fingerprint = "SHA256:actual-file-key", .store_path = "/var/folders/hb/12753xs57vs9vv2xpy73kcn80000gn/T/zerowork-file-auth-pointer/data/known_hosts" });
    for (0..8) |_| {
        f.cx.requestRedraw();
        f.cx.advanceFrameClock();
        _ = f.cx.render();
    }
    const rect = view.trust_once_button.?.globalRect();
    f.cx.handleMouseDown(rect.x + rect.w / 2, rect.y + rect.h / 2, .{});
    f.cx.handleMouseUp(rect.x + rect.w / 2, rect.y + rect.h / 2);
    try std.testing.expectEqual(@as(usize, 1), context.submissions);
    try std.testing.expect(context.identity.?.eql(id));
    var response = try context.bridge.waitResponse(id, 50);
    defer response.deinit();
    try std.testing.expect(response.decision == .trust_once);
    view.hide();
    f.wizard.show();
    f.settle();
    const next = f.wizard.next1_btn.?.globalRect();
    f.cx.handleMouseDown(next.x + next.w / 2, next.y + next.h / 2, .{});
    f.cx.handleMouseUp(next.x + next.w / 2, next.y + next.h / 2);
    try std.testing.expectEqual(W.Step.form, f.wizard.step);
}

test "wizard typed probe exact Cx geometry and direct success return to editable" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.record(0, 1, .transport, .started);
    try std.testing.expect(try f.wizard.setTestSnapshot(try f.snapshot(&direct)));
    f.settle();
    try std.testing.expectEqual(@as(f32, 760), f.wizard.modal.?.globalRect().w);
    try std.testing.expectEqual(@as(f32, 66), f.wizard.summary_card.?.globalRect().h);
    try std.testing.expectApproxEqAbs(@as(f32, 132.6), f.wizard.review_test_card.?.globalRect().h, 0.1);
    try std.testing.expectEqual(@as(@TypeOf(f.wizard.review_body.?.style.display), .none), f.wizard.review_body.?.style.display);
    try std.testing.expectApproxEqAbs(@as(f32, 54.6), f.wizard.test_stages[0].node.globalRect().h, 0.1);
    try std.testing.expect(contains(f.wizard.test_stages[0].title, "第 1 跳 · DB"));
    try std.testing.expect(contains(f.wizard.test_stages[0].detail, "TCP 连接中"));
    f.click("wizard.test.toggle");
    try std.testing.expectEqual(@as(@TypeOf(f.wizard.review_body.?.style.display), .flex), f.wizard.review_body.?.style.display);
    try std.testing.expectEqual(@as(f32, 684), f.wizard.test_logs_area.globalRect().w);
    try std.testing.expectEqual(@as(f32, 142), f.wizard.test_logs_area.globalRect().h);
    try std.testing.expectEqual(@as(f32, 80), f.wizard.logs_scroll.?.globalRect().h);
    const card = findId(f.wizard.root.?, "wizard.test.hop.9").?;
    try std.testing.expectEqual(@as(f32, 146), card.globalRect().w);
    try std.testing.expectEqual(@as(f32, 76), card.globalRect().h);
    // Name (20h), endpoint (14h), status (16h), 3px gaps, 10px inset.
    try std.testing.expectEqual(@as(f32, 33), f.wizard.route_previews[1].addresses[9].?.globalRect().y - card.globalRect().y);
    try std.testing.expectEqual(@as(f32, 50), f.wizard.route_previews[1].users[9].?.globalRect().y - card.globalRect().y);
    try std.testing.expect(contains(f.wizard.res_text.?, "TCP 连接中"));
    try std.testing.expect(f.wizard.locked.?.get());
    f.record(0, 1, .authentication, .succeeded);
    f.record(0, 1, .ready, .succeeded);
    var finished = try f.snapshot(&direct);
    finished.cleanup = .released;
    finished.finished = true;
    try std.testing.expect(try f.wizard.setTestSnapshot(finished));
    try std.testing.expect(!f.wizard.locked.?.get());
    try std.testing.expect(f.wizard.canSave());
    try std.testing.expectEqualStrings("验证通过 · 已释放", f.wizard.route_previews[1].users[9].?.getText().?.content);
    try std.testing.expectEqualStrings("验证通过 · 测试资源已释放", f.wizard.res_text.?.getText().?.content);
    try std.testing.expectEqualStrings("查看记录", f.wizard.test_follow_label.?.getText().?.content);
    try std.testing.expect(f.wizard.isVisible());
    f.cx.setViewport(860, 480);
    f.settle();
    try std.testing.expect(f.wizard.modal.?.globalRect().h <= 448);
    const footer = f.wizard.footer.?.globalRect();
    try std.testing.expect(footer.y + footer.h <= f.wizard.modal.?.globalRect().y + f.wizard.modal.?.globalRect().h + 0.5);
}

test "wizard typed probe failure distinguishes upstream failed hop and untouched target" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.record(0, 3, .authentication, .succeeded);
    f.record(1, 3, .authentication, .failed);
    var source = try f.snapshot(&routed);
    source.failure = error.AuthenticationFailed;
    source.cleanup = .released;
    source.finished = true;
    try std.testing.expect(try f.wizard.setTestSnapshot(source));
    f.settle();
    try std.testing.expectEqualStrings("已认证 · 已释放", f.wizard.route_previews[1].users[1].?.getText().?.content);
    try std.testing.expectEqualStrings("认证失败", f.wizard.route_previews[1].users[2].?.getText().?.content);
    try std.testing.expectEqualStrings("未尝试", f.wizard.route_previews[1].users[9].?.getText().?.content);
    try std.testing.expect(contains(f.wizard.res_text.?, "B2 认证失败"));
    try std.testing.expect(f.wizard.canSave());
    const original = source.key;
    f.click("wizard.test.toggle");
    f.click("wizard.test.hop.2");
    try std.testing.expectEqual(@as(?usize, 1), f.wizard.test_filter);
    try std.testing.expectEqualStrings("第2跳", f.wizard.test_rows[0].text[1].getText().?.content);
    try std.testing.expectEqual(@as(@TypeOf(f.wizard.test_rows[1].node.style.display), .none), f.wizard.test_rows[1].node.style.display);
    try std.testing.expectEqualStrings("第2跳", f.wizard.test_filter_label.?.getText().?.content);
    try std.testing.expect(!contains(f.wizard.test_log_text, "第1跳"));
    f.click("wizard.test.logs.filter");
    try std.testing.expect(f.wizard.test_filter == null);
    try std.testing.expect(contains(f.wizard.test_log_text, "第1跳"));
    source.key.operation_id += 1;
    source.resources.key = source.key;
    try std.testing.expect(!try f.wizard.setTestSnapshot(source));
    try std.testing.expect(f.wizard.test_source.?.value.key.eql(original));
}

test "wizard typed probe cancel is original key once and unlocks only after released" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.record(0, 1, .handshake, .started);
    var source = try f.snapshot(&direct);
    try std.testing.expect(try f.wizard.setTestSnapshot(source));
    f.click("wizard.test");
    try std.testing.expectEqual(@as(usize, 1), f.cancels);
    try std.testing.expect(f.cancelled_key.?.eql(key));
    f.click("wizard.test");
    try std.testing.expectEqual(@as(usize, 1), f.cancels);
    source.cancelled = true;
    source.cleanup = .releasing;
    try std.testing.expect(try f.wizard.setTestSnapshot(source));
    try std.testing.expect(f.wizard.locked.?.get());
    try std.testing.expect(!f.wizard.canSave());
    source.cleanup = .unknown;
    try std.testing.expect(try f.wizard.setTestSnapshot(source));
    try std.testing.expect(contains(f.wizard.res_text.?, "释放待核实"));
    try std.testing.expect(!contains(f.wizard.route_previews[1].users[9].?, "已认证"));
    source.cleanup = .released;
    source.finished = true;
    source.failure = error.Cancelled;
    try std.testing.expect(try f.wizard.setTestSnapshot(source));
    try std.testing.expect(!f.wizard.locked.?.get());
    try std.testing.expect(f.wizard.isVisible());
    try std.testing.expectEqualStrings("测试已取消 · 测试资源已释放", f.wizard.res_text.?.getText().?.content);
}

test "wizard typed probe owns strings rejects old revision and preserves paused bounded journal" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var name = "Frozen".*;
    const owned_hop = [_]P.Hop{.{ .name = &name, .host = "frozen.example", .user = "ops", .port = 22 }};
    for (0..12) |_| f.record(0, 1, .handshake, .started);
    var source = try f.snapshot(&owned_hop);
    try std.testing.expect(try f.wizard.setTestSnapshot(source));
    @memset(&name, 'x');
    try std.testing.expectEqualStrings("Frozen", f.wizard.test_source.?.value.hops[0].name);
    f.settle();
    const scroll = f.wizard.test_scroll.?;
    ui.widgets.setScrollY(scroll.state, scroll.content, scroll.state.maxScrollY());
    f.wizard.test_last_scroll = scroll.state.scroll_y;
    ui.widgets.setScrollY(scroll.state, scroll.content, 0);
    f.record(0, 1, .handshake, .started);
    source = try f.snapshot(&direct);
    try std.testing.expect(try f.wizard.setTestSnapshot(source));
    try std.testing.expect(!f.wizard.test_following);
    try std.testing.expectEqual(@as(usize, 1), f.wizard.test_new_logs);
    try std.testing.expectEqual(@as(f32, 0), scroll.state.scroll_y);
    f.click("wizard.test.logs.follow");
    try std.testing.expect(f.wizard.test_following);
    try std.testing.expectEqual(@as(usize, 0), f.wizard.test_new_logs);
    // A missing platform clipboard is an actual failure, never "copied".
    f.click("wizard.test.logs.copy");
    try std.testing.expectEqual(@as(?bool, false), f.wizard.test_copy_result);
    try std.testing.expect(try f.wizard.setTestSnapshot(source));
    try std.testing.expectEqual(@as(?bool, false), f.wizard.test_copy_result);
    try std.testing.expect(contains(f.wizard.test_follow_hint.?, "复制失败"));
    for (0..140) |_| f.record(0, 1, .handshake, .started);
    source = try f.snapshot(&direct);
    try std.testing.expect(try f.wizard.setTestSnapshot(source));
    try std.testing.expectEqual(@as(usize, 128), f.wizard.test_history.count);
    try std.testing.expectEqual(@as(usize, 25), f.wizard.test_history.dropped);
    source.draft_revision -= 1;
    try std.testing.expect(!try f.wizard.setTestSnapshot(source));
    source.draft_revision += 1;
    source.generation += 1;
    try std.testing.expect(!try f.wizard.setTestSnapshot(source));
}

const Socket = struct {
    fd: c_int,
    port: u16,
    fn init(listen: bool) !Socket {
        const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = std.c.close(fd);
        var address: std.c.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        if (std.c.bind(fd, @ptrCast(&address), @sizeOf(@TypeOf(address))) != 0) return error.BindFailed;
        if (listen and std.c.listen(fd, 1) != 0) return error.ListenFailed;
        var length: std.c.socklen_t = @sizeOf(@TypeOf(address));
        if (std.c.getsockname(fd, @ptrCast(&address), &length) != 0) return error.AddressFailed;
        return .{ .fd = fd, .port = std.mem.bigToNative(u16, address.port) };
    }
    fn deinit(self: Socket) void {
        _ = std.c.close(self.fd);
    }
};

test "wizard typed probe Host mounts cleans up and presents actual TCP failure final ledger" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var journal = P.operations.Journal.init(a);
    defer journal.deinit();
    var controller = Probe.Controller.init(a, &journal);
    defer controller.deinit();
    var library = try ssh.Library.init();
    defer library.deinit();
    const host_scope = try ui.Scope.init(a, f.scope, f.cx.owner);
    defer host_scope.dispose();
    const host = try ProbeHost.mountRemote(f.cx, host_scope, &controller, &f.wizard, f.wizard.authentication_area);
    try std.testing.expect(controller.interaction_sink != null);
    const socket = try Socket.init(false);
    defer socket.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "known_hosts", .data = "" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "known_hosts", a);
    defer a.free(path);
    var draft = f.wizard.currentDraft();
    draft.host = "127.0.0.1";
    draft.port = socket.port;
    var settings: config.Config = .{};
    settings.ssh.connect_timeout_sec = 1;
    const job = try controller.startWithTrustStore(draft, &.{}, settings, f.wizard.test_generation, &library, path);
    if (job.thread) |thread| thread.join();
    job.thread = null;
    const status = try controller.poll(job);
    try std.testing.expect(status == .finished);
    try std.testing.expect(status.finished.failure != null);
    try std.testing.expectEqual(P.operations.Cleanup.released, status.finished.cleanup);
    try host.presentJob(job);
    try std.testing.expect(f.wizard.test_source.?.value.key.eql(job.key));
    try std.testing.expectEqualStrings("127.0.0.1", f.wizard.test_source.?.value.hops[0].host);
    try std.testing.expect(!f.wizard.locked.?.get());
    try std.testing.expect(contains(f.wizard.res_text.?, "已释放"));
    try controller.retire(job);
    // Retiring the network owner does not invalidate retained UI strings/logs.
    f.settle();
    try std.testing.expectEqualStrings("127.0.0.1", f.wizard.test_source.?.value.hops[0].host);
}

// The actual Job reads this trust-store stream before starting its network
// deadline. Holding the write end is an explicit EOF gate; rendering can take
// arbitrarily long without making the pending/cancellation assertions race.
const ProbeReadGate = struct {
    read_fd: c_int,
    write_fd: ?c_int,
    path: [:0]u8,
    fn init() !ProbeReadGate {
        var descriptors: [2]std.c.fd_t = undefined;
        if (std.c.pipe(&descriptors) != 0) return error.PipeFailed;
        errdefer {
            _ = std.c.close(descriptors[0]);
            _ = std.c.close(descriptors[1]);
        }
        const path = try std.fmt.allocPrintSentinel(a, "/dev/fd/{d}", .{descriptors[0]}, 0);
        return .{ .read_fd = descriptors[0], .write_fd = descriptors[1], .path = path };
    }
    fn release(self: *ProbeReadGate) void {
        if (self.write_fd) |fd| {
            _ = std.c.close(fd);
            self.write_fd = null;
        }
    }
    fn deinit(self: *ProbeReadGate) void {
        self.release();
        _ = std.c.close(self.read_fd);
        a.free(self.path);
    }
};

test "wizard typed probe real gated Job cancels only its captured operation" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var journal = P.operations.Journal.init(a);
    defer journal.deinit();
    var library = try ssh.Library.init();
    defer library.deinit();
    var controller = Probe.Controller.init(a, &journal);
    defer controller.deinit();
    const host_scope = try ui.Scope.init(a, f.scope, f.cx.owner);
    defer host_scope.dispose();
    const host = try ProbeHost.mountRemote(f.cx, host_scope, &controller, &f.wizard, f.wizard.authentication_area);
    const socket = try Socket.init(true);
    defer socket.deinit();
    var original_gate = try ProbeReadGate.init();
    defer original_gate.deinit();
    var other_gate = try ProbeReadGate.init();
    defer other_gate.deinit();
    var draft = f.wizard.currentDraft();
    draft.host = "127.0.0.1";
    draft.port = socket.port;
    var settings: config.Config = .{};
    settings.ssh.connect_timeout_sec = 2;
    const original = try controller.startWithTrustStore(draft, &.{}, settings, f.wizard.test_generation, &library, original_gate.path);
    draft.draft_id += 100;
    const other = try controller.startWithTrustStore(draft, &.{}, settings, f.wizard.test_generation, &library, other_gate.path);
    try host.presentJob(original);
    try std.testing.expect(!original.ready.load(.acquire));
    try std.testing.expect(!other.ready.load(.acquire));
    f.click("wizard.test");
    try std.testing.expect(original.cancelled.load(.acquire));
    try std.testing.expect(!other.cancelled.load(.acquire));
    // Neither real worker can retire while its independent gate is held.
    try std.testing.expect(!original.ready.load(.acquire));
    try std.testing.expect(!other.ready.load(.acquire));
    try std.testing.expect(f.wizard.locked.?.get());
    try std.testing.expect((try controller.poll(original)) == .pending);
    original_gate.release();
    if (original.thread) |thread| thread.join();
    original.thread = null;
    const status = try controller.poll(original);
    try std.testing.expect(status == .finished);
    try std.testing.expectEqual(error.Cancelled, status.finished.failure.?);
    try host.presentJob(original);
    try std.testing.expect(!f.wizard.locked.?.get());
    try std.testing.expect(f.wizard.isVisible());
    try std.testing.expectEqualStrings("测试已取消 · 测试资源已释放", f.wizard.res_text.?.getText().?.content);
    try controller.retire(original);
    try std.testing.expect(!other.ready.load(.acquire));
    try std.testing.expect(!other.cancelled.load(.acquire));
    other.cancel();
    other_gate.release();
    if (other.thread) |thread| thread.join();
    other.thread = null;
    try std.testing.expect((try controller.poll(other)) == .finished);
    try controller.retire(other);
}

// Explicit local acceptance only. The normal UI suite never depends on the VM.
// The production probe opens no shell/channel and changes no remote state.
test "wizard typed probe optional real VM authenticates releases and unlocks review" {
    const password = if (std.c.getenv("ZEROWORK_VM_PASSWORD")) |value| std.mem.span(value) else return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.wizard.loadDraft(.{ .name = "Local VM", .host = "192.0.2.10", .user = "root", .password = password });
    f.wizard.show();
    activate(f.wizard.next1_btn.?);
    activate(f.wizard.next2_btn.?);
    activate(f.wizard.test_btn.?);
    var journal = P.operations.Journal.init(a);
    defer journal.deinit();
    var controller = Probe.Controller.init(a, &journal);
    defer controller.deinit();
    var library = try ssh.Library.init();
    defer library.deinit();
    const host_scope = try ui.Scope.init(a, f.scope, f.cx.owner);
    defer host_scope.dispose();
    const host = try ProbeHost.mountRemote(f.cx, host_scope, &controller, &f.wizard, f.wizard.authentication_area);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "known_hosts", .data = "" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "known_hosts", a);
    defer a.free(path);
    var settings: config.Config = .{};
    settings.ssh.connect_timeout_sec = 5;
    const job = try controller.startWithTrustStore(f.wizard.currentDraft(), &.{}, settings, f.wizard.test_generation, &library, path);
    const original_key = job.key;
    const deadline = @import("platform/realtime.zig").monotonicNs() + 12 * std.time.ns_per_s;
    var completed = false;
    while (@import("platform/realtime.zig").monotonicNs() < deadline) {
        try host.presentJob(job);
        if (controller.pendingAuthentication()) |challenge| {
            try std.testing.expect(challenge.identity.key.eql(original_key));
            try std.testing.expectEqualStrings("192.0.2.10", challenge.endpoint().host);
            switch (challenge.kind) {
                .host_key_unknown => try controller.submitAuthentication(challenge.identity, .trust_once),
                .password => try controller.submitAuthentication(challenge.identity, .{ .answers = &.{password} }),
                else => return error.UnexpectedVmChallenge,
            }
        }
        const status = try controller.poll(job);
        if (status == .finished) {
            try std.testing.expect(status.finished.failure == null);
            try std.testing.expectEqual(P.operations.Cleanup.released, status.finished.cleanup);
            try std.testing.expect(status.finished.resources.?.released());
            try std.testing.expectEqual(ssh.ResourceState.absent, status.finished.resources.?.entry(0, .shell).state);
            try host.presentJob(job);
            try std.testing.expect(f.wizard.test_source.?.value.key.eql(original_key));
            try std.testing.expect(!f.wizard.locked.?.get());
            try std.testing.expect(f.wizard.canSave());
            try std.testing.expectEqualStrings("验证通过 · 测试资源已释放", f.wizard.res_text.?.getText().?.content);
            try controller.retire(job);
            completed = true;
            break;
        }
        const pause: std.c.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&pause, null);
    }
    try std.testing.expect(completed);
    f.settle();
    try std.testing.expectEqualStrings("192.0.2.10", f.wizard.test_source.?.value.hops[0].host);
    try std.testing.expect(f.wizard.isVisible());
}

test "SFTP wizard probe does not equate SSH ready with subsystem directory success" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.record(0, 1, .authentication, .succeeded);
    f.record(0, 1, .ready, .succeeded);
    var source = try f.snapshot(&direct);
    source.protocol = .sftp;
    try std.testing.expect(try f.wizard.setTestSnapshot(source));
    f.settle();
    try std.testing.expect(contains(f.wizard.res_text.?, "正在验证 SFTP 目录"));
    try std.testing.expect(!contains(f.wizard.res_text.?, "SFTP 可用"));
    source.finished = true;
    source.cleanup = .released;
    try std.testing.expect(try f.wizard.setTestSnapshot(source));
    f.settle();
    try std.testing.expect(contains(f.wizard.res_text.?, "SFTP 可用 · 目录只读验证通过 · 已释放"));
    source.failure = error.SftpSubsystemDenied;
    try std.testing.expect(try f.wizard.setTestSnapshot(source));
    f.settle();
    try std.testing.expect(contains(f.wizard.res_text.?, "SSH 认证通过 · SFTP 子系统拒绝 · 已释放"));
    try std.testing.expect(!contains(f.wizard.res_text.?, "验证通过"));
}
