const std = @import("std");
const ui = @import("ui");
const Connection = @import("ui/connection_host.zig");
const Workspace = @import("ui/workspace.zig").Workspace;
const Application = @import("ui/application_host.zig").ApplicationHost;
const Config = @import("config/config.zig").Config;
const OperationKey = @import("host/operation.zig").OperationKey;
const clock = @import("platform/realtime.zig");
const c = @import("generated_ssh_session");
const a = std.testing.allocator;

const Socket = struct {
    fd: c_int,
    port: u16,
    fn init(listen: bool) !Socket {
        const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer c.zw_ssh_socket_close(fd);
        var address: std.c.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        if (std.c.bind(fd, @ptrCast(&address), @sizeOf(@TypeOf(address))) != 0) return error.BindFailed;
        if (listen and std.c.listen(fd, 1) != 0) return error.ListenFailed;
        var length: std.c.socklen_t = @sizeOf(@TypeOf(address));
        if (std.c.getsockname(fd, @ptrCast(&address), &length) != 0) return error.AddressFailed;
        return .{ .fd = fd, .port = std.mem.bigToNative(u16, address.port) };
    }
    fn deinit(self: Socket) void {
        c.zw_ssh_socket_close(self.fd);
    }
};

const Fixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    workspace: *Workspace,
    application: *Application,
    host: *Connection.Host,
    config: Config = .{},
    tmp: @TypeOf(std.testing.tmpDir(.{})),
    path: [:0]const u8,
    fn init(self: *Fixture) !void {
        self.* = .{ .cx = try ui.Cx.init(a, std.testing.io), .scope = undefined, .workspace = undefined, .application = undefined, .host = undefined, .tmp = std.testing.tmpDir(.{}), .path = undefined };
        self.cx.setViewport(1100, 720);
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
        self.scope = try ui.Scope.init(a, null, self.cx.owner);
        var nodes: [4]*ui.Node = undefined;
        for (&nodes) |*node| {
            node.* = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .px = 100 } }, .{});
            try self.cx.root.?.appendChild(a, node.*);
        }
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "hosts.toml", .data = "" });
        self.path = try self.tmp.dir.realPathFileAlloc(std.testing.io, "hosts.toml", a);
        self.config.ssh.connect_timeout_sec = 2;
        self.config.ssh.auto_reconnect = false;
        self.workspace = try Workspace.init(a, self.cx, self.scope, std.testing.io, &self.config, self.path, nodes[0], nodes[1], nodes[2], nodes[3]);
        self.application = try Application.init(a, self.workspace);
        try self.scope.onCleanup(Application, self.application, Application.deinit);
        self.application.install();
        self.host = try Connection.Host.mount(self.cx, self.scope, self.workspace, self.application);
    }
    fn tick(self: *Fixture) !void {
        _ = try self.application.safeTick();
        self.cx.advanceFrameClock();
        self.cx.layout();
        _ = self.cx.render();
        var unused: [1]std.c.pollfd = undefined;
        _ = std.c.poll(&unused, 0, 2);
    }
    fn deinit(self: *Fixture) void {
        var ids: [16]@import("ui/workspace.zig").SessionId = undefined;
        const count = @min(ids.len, self.workspace.tabs.items.len);
        for (self.workspace.tabs.items[0..count], ids[0..count]) |tab, *id| id.* = tab.id;
        for (ids[0..count]) |id| _ = self.application.requestCloseLegacy(id) catch @panic("Connection fixture close request failed");
        const deadline = clock.monotonicNs() + 8 * std.time.ns_per_s;
        // Tab removal is only a presentation receipt. Keep driving the real
        // worker/owner cleanup before disposing ApplicationHost's scope.
        while (self.workspace.tabs.items.len != 0 or self.application.local_adapter.shutdownStep() != .released) {
            self.tick() catch @panic("Connection fixture cleanup tick failed");
            if (clock.monotonicNs() >= deadline) @panic("Connection fixture did not release its real sessions");
        }
        self.cx.clearFocus();
        self.scope.dispose();
        self.cx.deinit();
        a.free(self.path);
        self.tmp.cleanup();
    }
};

test "connection host mounts and disposes the actual Workspace ApplicationHost and native modal scopes" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.tick();
    try std.testing.expect(f.workspace.authentication_ui_ready);
    try std.testing.expect(!f.host.blocksGlobalActions());
    try std.testing.expect(f.host.last_error == null);
}

test "connection host keeps a failed original owner while a foreign challenge waits and transfers only after explicit close" {
    var refused = try Socket.init(false);
    defer refused.deinit();
    var pending = try Socket.init(true);
    defer pending.deinit();
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const first = try f.application.create(.{ .name = "Original", .host = "127.0.0.1", .port = refused.port, .user = "fixture", .auth_mode = .password, .password = "fixture-password" }, 1, 0, "");
    const deadline = clock.monotonicNs() + 3 * std.time.ns_per_s;
    while (clock.monotonicNs() < deadline) {
        try f.tick();
        if (f.host.progress.source) |source| if (source.value.key.eql(first.operation) and source.value.state == .failed and source.value.cleanup == .released) break;
    }
    try std.testing.expect(f.host.progress.matches(first.operation));
    try std.testing.expect(!f.host.progress.close_disabled.peek());
    const second = try f.application.create(.{ .name = "Queued", .host = "127.0.0.1", .port = pending.port, .user = "fixture", .auth_mode = .password, .password = "fixture-password" }, 2, 0, "");
    // This test supplies only a typed UI challenge. The second real TCP
    // connection deliberately has no SSH peer and is cancelled at teardown.
    var offered = false;
    for (f.workspace.connect_jobs.items) |job| if (job.operation_key != null and job.operation_key.?.eql(second.operation)) {
        _ = try job.auth_bridge.offerChallenge(.{ .key = second.operation, .hop_index = 0, .kind = .password, .endpoint_identity = .{ .host = "127.0.0.1", .port = pending.port, .user = "fixture" }, .prompts = &.{.{ .text = "Password:", .echo = false }}, .presentation_config_revision = 1 });
        offered = true;
        break;
    };
    try std.testing.expect(offered);
    try f.tick();
    try std.testing.expect(f.host.last_error == null);
    try std.testing.expect(f.host.progress.matches(first.operation));
    try std.testing.expect(!f.host.authentication.isVisible());
    f.cx.setFocus(f.host.progress.close_button.?);
    f.cx.handleKeyDown(.@"return", .{});
    for (0..4) |_| try f.tick();
    try std.testing.expect(f.host.last_error == null);
    // Protected authentication owns the modal; progress must stay hidden so
    // its focus trap cannot make the password form inert.
    try std.testing.expect(!f.host.progress.isVisible());
    try std.testing.expect(f.host.bridge.current.?.identity.key.eql(second.operation));
    try std.testing.expect(f.host.authentication.isVisible());
}

const ExternalAuthentication = struct {
    const auth = @import("proto/ssh/auth_challenge.zig");
    bridge: auth.InteractiveBridge = .{},
    parent: *ui.Node,
    submitted: usize = 0,
    cancelled: usize = 0,
    submitted_identity: ?auth.RequestIdentity = null,
    cancelled_identity: ?auth.RequestIdentity = null,
    host_key_queries: usize = 0,

    fn provider(self: *ExternalAuthentication) @import("ui/workspace.zig").ExternalAuthentication {
        return .{ .context = self, .pending = pending, .submit = submit, .cancel = cancel, .host = host, .parent = parentFor, .host_key = hostKey };
    }
    fn current(self: *ExternalAuthentication, request: auth.RequestIdentity) bool {
        const snapshot = self.bridge.snapshot() orelse return false;
        return snapshot.identity.eql(request) and snapshot.state != .completed and snapshot.state != .cancelled;
    }
    fn pending(raw: *anyopaque) ?auth.Snapshot {
        const self: *ExternalAuthentication = @ptrCast(@alignCast(raw));
        const snapshot = self.bridge.snapshot() orelse return null;
        return if (snapshot.state == .completed or snapshot.state == .cancelled) null else snapshot;
    }
    fn submit(raw: *anyopaque, request: auth.RequestIdentity, reply: auth.Reply) !void {
        const self: *ExternalAuthentication = @ptrCast(@alignCast(raw));
        try self.bridge.submit(request, reply);
        self.submitted += 1;
        self.submitted_identity = request;
    }
    fn cancel(raw: *anyopaque, request: auth.RequestIdentity) bool {
        const self: *ExternalAuthentication = @ptrCast(@alignCast(raw));
        if (!self.bridge.cancelRequest(request)) return false;
        self.cancelled += 1;
        self.cancelled_identity = request;
        return true;
    }
    fn host(raw: *anyopaque, request: auth.RequestIdentity) ?@import("config/hosts.zig").HostConfig {
        const self: *ExternalAuthentication = @ptrCast(@alignCast(raw));
        if (!self.current(request)) return null;
        return .{ .name = "Original file authentication", .host = "original-file.example", .port = 2222, .user = "file-user", .auth_mode = .password };
    }
    fn parentFor(raw: *anyopaque, request: auth.RequestIdentity) ?*ui.Node {
        const self: *ExternalAuthentication = @ptrCast(@alignCast(raw));
        return if (self.current(request)) self.parent else null;
    }
    fn hostKey(raw: *anyopaque, request: auth.RequestIdentity) ?@import("ui/host_key_confirmation.zig").Request {
        const self: *ExternalAuthentication = @ptrCast(@alignCast(raw));
        if (!self.current(request)) return null;
        self.host_key_queries += 1;
        return null; // Keyboard authentication does not invent a host key.
    }
};

fn renderedText(cx: *ui.Cx, text: []const u8) bool {
    for (cx.render()) |item| switch (item) {
        .text_run => |run| if (std.mem.eql(u8, run.content, text)) return true,
        else => {},
    };
    return false;
}

test "connection host external protected authentication uses real modal without progress and keeps original request across tab selection" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // Actual local tabs supply real domain identities and focus changes. The
    // external challenge is a UI fixture; it claims no remote capability.
    const first = try f.application.createLocal(null);
    const second = try f.application.createLocal(null);
    const deadline = clock.monotonicNs() + 3 * std.time.ns_per_s;
    while (f.application.sessions.queryState(first.handle).?.lifecycle != .attached or f.application.sessions.queryState(second.handle).?.lifecycle != .attached) {
        try f.tick();
        if (clock.monotonicNs() >= deadline) return error.LocalFixtureTimeout;
    }
    try std.testing.expectEqual(@as(usize, 0), f.workspace.connect_jobs.items.len);
    try std.testing.expect(f.workspace.nextConnectionPresentationKey() == null);
    const first_index = f.workspace.tabIndexById(f.application.sessions.queryState(first.handle).?.attachment.?.tab_id).?;
    const second_index = f.workspace.tabIndexById(f.application.sessions.queryState(second.handle).?.attachment.?.tab_id).?;
    f.workspace.selectTab(second_index);
    const key = try f.application.sessions.journal.begin(.{ .session = first.handle }, 1);
    var external: ExternalAuthentication = .{ .parent = f.workspace.terminal_area };
    defer external.bridge.cancel();
    f.workspace.external_auth = external.provider();
    defer f.workspace.external_auth = null;
    const original = try external.bridge.offerChallenge(.{ .key = key, .hop_index = 0, .kind = .keyboard_interactive, .endpoint_identity = .{ .host = "original-file.example", .port = 2222, .user = "file-user" }, .prompts = &.{ .{ .text = "Account:", .echo = true }, .{ .text = "Recovery response:", .echo = false } }, .presentation = .protected_form, .presentation_config_revision = 19 });
    try std.testing.expect(f.workspace.connectionProgress(key) == null);
    for (0..2) |_| try f.tick();
    const view = f.host.authentication;
    try std.testing.expect(f.host.last_error == null);
    try std.testing.expect(f.host.blocksGlobalActions());
    try std.testing.expect(!f.host.progress.isVisible());
    try std.testing.expect(f.host.progress.source == null);
    try std.testing.expect(view.isVisible());
    try std.testing.expect(view.open.peek());
    try std.testing.expect(view.modal.dialog.globalRect().w > 0 and view.modal.dialog.globalRect().h > 0);
    // Modal may be in Cx's portal layer. Verify its real render output rather
    // than requiring a particular widget-internal parent.
    try std.testing.expect(std.mem.indexOf(u8, view.source.getText().?.content, "Original file authentication") != null);
    try std.testing.expectEqual(@as(usize, 2), view.current.?.field_count);
    try std.testing.expectEqual(ui.widgets.input.InputType.text, view.fields[0].input.state.input_type);
    try std.testing.expectEqual(ui.widgets.input.InputType.password, view.fields[1].input.state.input_type);
    try std.testing.expect(f.host.bridge.current.?.identity.eql(original));
    try std.testing.expectEqual(ExternalAuthentication.auth.Kind.keyboard_interactive, f.host.bridge.current.?.kind);
    try std.testing.expectEqual(ExternalAuthentication.auth.Presentation.otp_modal, f.host.bridge.current.?.presentation);
    try std.testing.expectEqual(ExternalAuthentication.auth.Presentation.protected_form, external.bridge.snapshot().?.presentation);
    try std.testing.expectEqualStrings("Original file authentication", f.workspace.authenticationHostFor(original).?.name);
    try std.testing.expect(std.mem.indexOf(u8, view.source.getText().?.content, "file-user@original-file.example:2222") != null);
    try std.testing.expectEqual(f.workspace.terminal_area, f.workspace.authenticationParent(original).?);
    try std.testing.expect(external.host_key_queries > 0);
    var wrong = original;
    wrong.request_id += 1;
    try std.testing.expectError(error.StaleChallenge, f.workspace.submitAuthentication(wrong, .{ .answers = &.{ "wrong", "wrong" } }));
    try std.testing.expect(!f.workspace.cancelAuthentication(wrong));
    try std.testing.expect(f.workspace.authenticationHostFor(wrong) == null);
    try std.testing.expectEqual(@as(usize, 0), external.submitted);
    try std.testing.expectEqual(@as(usize, 0), external.cancelled);

    f.cx.setFocus(view.fields[0].input.input_container);
    f.cx.handleTextInput("file-user");
    f.cx.setFocus(view.fields[1].input.input_container);
    f.cx.handleTextInput("generic recovery phrase");
    f.workspace.selectTab(first_index);
    try f.tick();
    f.workspace.selectTab(second_index);
    try f.tick();
    try std.testing.expect(f.host.bridge.current.?.identity.eql(original));
    try std.testing.expectEqualStrings("file-user", view.fields[0].input.state.getText());
    try std.testing.expectEqualStrings("generic recovery phrase", view.fields[1].input.state.getText());
    try std.testing.expect(!view.submit_disabled.peek());
    f.cx.setFocus(view.fields[1].input.input_container);
    f.cx.handleKeyDown(.@"return", .{});
    try f.tick();
    try std.testing.expectEqual(@as(usize, 1), external.submitted);
    try std.testing.expect(external.submitted_identity.?.eql(original));
    try std.testing.expectEqual(second_index, f.workspace.active_tab.?);
    var response = try external.bridge.waitResponse(original, 50);
    defer response.deinit();
    try std.testing.expectEqualStrings("file-user", response.answerAt(0));
    try std.testing.expectEqualStrings("generic recovery phrase", response.answerAt(1));
    try external.bridge.complete(original);
    for (0..2) |_| try f.tick();
    try std.testing.expect(!view.isVisible());
    try std.testing.expect(!f.host.progress.isVisible());

    const next = try external.bridge.offerChallenge(.{ .key = key, .hop_index = 0, .kind = .keyboard_interactive, .endpoint_identity = .{ .host = "original-file.example", .port = 2222, .user = "file-user" }, .prompts = &.{.{ .text = "Server next round:", .echo = false }}, .presentation = .protected_form, .presentation_config_revision = 19 });
    for (0..2) |_| try f.tick();
    try std.testing.expect(next.request_id > original.request_id);
    f.cx.setFocus(view.fields[0].input.input_container);
    f.cx.handleKeyDown(.escape, .{});
    try f.tick();
    try std.testing.expectEqual(@as(usize, 1), external.cancelled);
    try std.testing.expect(external.cancelled_identity.?.eql(next));
    try std.testing.expectEqual(second_index, f.workspace.active_tab.?);
    try std.testing.expectEqual(@as(usize, 2), f.workspace.tabs.items.len);
    try std.testing.expectEqual(@import("host/session_host.zig").Lifecycle.attached, f.application.sessions.queryState(first.handle).?.lifecycle);
    try std.testing.expectEqual(@import("host/session_host.zig").Lifecycle.attached, f.application.sessions.queryState(second.handle).?.lifecycle);
    try std.testing.expect(external.bridge.snapshot().?.state == .cancelled);
    for (0..2) |_| try f.tick();
    try std.testing.expect(!view.isVisible());
    try std.testing.expect(!f.host.blocksGlobalActions());
    _ = try f.application.sessions.journal.publish(key, .cancelled, "external auth fixture complete", null);
    _ = try f.application.sessions.journal.publish(key, .cleanup_released, "no native fixture resource", null);
    try f.application.sessions.journal.retire(key, .resources_released);
}

test "connection host shared trust bridge keeps once save and replacement decisions on exact original requests" {
    const generic = @import("host/challenge_host.zig");
    const adapter = @import("plugins/remote/challenge_bridge.zig");
    const authentication = @import("proto/ssh/auth_challenge.zig");
    const Observer = struct {
        calls: usize = 0,
        once: usize = 0,
        saved: usize = 0,
        replaced: usize = 0,
        fn submit(raw: *anyopaque, request: authentication.RequestIdentity, reply: authentication.Reply) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try std.testing.expectEqual(@as(u64, 19), request.key.operation_id);
            try std.testing.expectEqual(@as(usize, 2), request.hop_index);
            self.calls += 1;
            switch (reply) {
                .trust_once => self.once += 1,
                .trust_save => self.saved += 1,
                .replace_host_key => |confirmation| {
                    try std.testing.expectEqualStrings("yes", confirmation);
                    self.replaced += 1;
                },
                else => return error.UnexpectedAuthenticationReply,
            }
        }
        fn cancel(_: *anyopaque, _: authentication.RequestIdentity) void {}
    };
    var host = generic.Host.init(a);
    defer host.deinit();
    var observer: Observer = .{};
    var bridge: adapter.Bridge = .{};
    const callbacks: adapter.Callbacks = .{ .context = &observer, .submit = Observer.submit, .cancel = Observer.cancel };
    const original: authentication.RequestIdentity = .{ .key = .{ .owner = .app, .operation_id = 19, .attempt_id = 2 }, .hop_index = 2, .request_id = 1 };
    var request: authentication.Snapshot = .{ .identity = original, .kind = .host_key_unknown, .presentation = .protected_form, .presentation_config_revision = 1, .expires_at_ns = null, .port = 22 };
    var key: @import("ui/host_key_confirmation.zig").Request = .{ .algorithm_len = 7, .fingerprint_len = 10, .old_fingerprint_len = 10 };
    @memcpy(key.algorithm[0..7], "ed25519");
    @memcpy(key.fingerprint[0..10], "SHA256:new");
    @memcpy(key.old_fingerprint[0..10], "SHA256:old");
    try bridge.sync(&host, request, .{ .display_name = "Trust fixture", .host_key = key }, callbacks, 1);
    try std.testing.expect(std.mem.indexOf(u8, host.snapshot(0, null).?.payload.material, "SHA256:new") != null);
    try host.submitAnswer(adapter.Bridge.owner(original), 1, 2, .{ .choice = "trust_once" }, 2);
    try bridge.sync(&host, request, .{}, callbacks, 2);
    try bridge.sync(&host, request, .{}, callbacks, 2);
    try std.testing.expectEqual(@as(usize, 1), observer.calls);
    request.identity.request_id = 2;
    try bridge.sync(&host, request, .{ .host_key = key }, callbacks, 3);
    try host.submitAnswer(adapter.Bridge.owner(original), 2, 2, .{ .choice = "trust_save" }, 4);
    try bridge.sync(&host, request, .{}, callbacks, 4);
    request.identity.request_id = 3;
    request.kind = .host_key_changed;
    try bridge.sync(&host, request, .{ .host_key = key }, callbacks, 5);
    try std.testing.expect(std.mem.indexOf(u8, host.snapshot(0, null).?.payload.material, "SHA256:old") != null);
    try std.testing.expectError(error.InvalidChallengeConfirmation, host.submitAnswer(adapter.Bridge.owner(original), 3, 2, .{ .fields = &.{"YES"} }, 6));
    try host.submitAnswer(adapter.Bridge.owner(original), 3, 2, .{ .fields = &.{"yes"} }, 6);
    try bridge.sync(&host, request, .{}, callbacks, 6);
    try std.testing.expectEqual(@as(usize, 3), observer.calls);
    try std.testing.expectEqual(@as(usize, 1), observer.once);
    try std.testing.expectEqual(@as(usize, 1), observer.saved);
    try std.testing.expectEqual(@as(usize, 1), observer.replaced);
    bridge.clear();
}

test "connection host shared OTP prefill waits for confirmation preserves manual edits and rejects expired code" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const shared = @import("host/challenge_host.zig");
    const owner: OperationKey = .{ .owner = .app, .operation_id = 35, .attempt_id = 2 };
    const service = f.host.challenges;
    const view = service.view;
    const now = @import("proto/ssh/totp_prefill.zig").Clock{};
    const window = now.now().unix_seconds / 30;
    const Validity = struct {
        fn valid(_: *anyopaque, _: u64, expiry: ?i128) bool {
            return expiry == null;
        }
    };
    const validity: @import("ui/plugin_challenge_presenter.zig").PrefillGuard = .{ .context = &f, .valid = Validity.valid };
    try service.host.offer(owner, 1, 2, .secret_input, .{ .title = "One-time verification", .submit_label = "验证并继续", .fields = &.{.{ .label = "OTP", .max_bytes = 256 }} }, std.math.maxInt(u64));
    for (0..2) |_| try f.tick();
    try std.testing.expect(try view.prefill(shared.Owner.from(owner), 1, 2, "123456", window, null, validity));
    try std.testing.expect(service.host.takeAnswer(owner, 1, 2) == null);
    f.cx.setFocus(view.fields[0].input.input_container);
    f.cx.handleTextInput("7");
    try f.tick();
    try std.testing.expectEqualStrings("验证并继续", view.submit_button.behavior.interaction.a11y.?.label.?);
    const manual = try a.dupe(u8, view.fields[0].input.state.getText());
    defer a.free(manual);
    try std.testing.expect(!try view.prefill(shared.Owner.from(owner), 1, 2, "654321", window + 1, null, validity));
    try std.testing.expectEqualStrings(manual, view.fields[0].input.state.getText());
    f.cx.handleKeyDown(.@"return", .{});
    var first = service.host.takeAnswer(owner, 1, 2).?;
    defer first.deinit();
    try std.testing.expectEqualStrings(manual, first.value.fields[0]);
    try service.host.offer(owner, 2, 2, .secret_input, .{ .title = "One-time verification", .fields = &.{.{ .label = "OTP", .max_bytes = 256 }} }, std.math.maxInt(u64));
    for (0..2) |_| try f.tick();
    try std.testing.expect(try view.prefill(shared.Owner.from(owner), 2, 2, "123456", window, 1, validity));
    f.cx.setFocus(view.fields[0].input.input_container);
    f.cx.handleKeyDown(.@"return", .{});
    try std.testing.expect(service.host.takeAnswer(owner, 2, 2) == null);
    try std.testing.expectEqualStrings("", view.fields[0].input.state.getText());
    service.host.retire(owner, 2, 2);
}
