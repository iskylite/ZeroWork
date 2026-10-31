const std = @import("std");
const ui = @import("ui");
const mod = @import("plugins/remote/editor.zig");
const hosts = @import("config/hosts.zig");
const store = @import("config/store.zig");
const a = std.testing.allocator;

const SaveFixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    wizard: mod.RemoteEditor = .{},
    tmp: std.testing.TmpDir,
    registry: hosts.Registry,
    path: []const u8 = "hosts.toml",
    calls: usize = 0,
    save_only_calls: usize = 0,
    open_calls: usize = 0,
    commits: usize = 0,
    open_failure: ?anyerror = null,
    reentry_blocked: bool = false,
    transient_secret_received: bool = false,
    cancel_calls: usize = 0,
    assets: [1]mod.Draft,

    fn init(self: *SaveFixture, protocol: mod.Protocol) !void {
        self.* = .{ .cx = undefined, .scope = undefined, .tmp = std.testing.tmpDir(.{}), .registry = undefined, .assets = undefined };
        var initial = try hosts.Registry.parse(a, "[[hosts]]\nconnection_id=41\nrevision=3\nname=\"jump\"\nhost=\"jump.example\"\nuser=\"ops\"\n");
        defer initial.deinit();
        try store.saveHosts(std.testing.io, self.tmp.dir, self.path, initial);
        self.registry = try store.loadHosts(std.testing.io, self.tmp.dir, a, self.path);
        self.assets[0] = try mod.Draft.fromHost(self.registry.hosts[0]).dupe(a);
        self.cx = try ui.Cx.init(a, std.testing.io);
        try self.cx.setTestFrameStep(100);
        self.cx.setViewport(1440, 900);
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill() }, .{});
        self.scope = try ui.Scope.init(a, null, self.cx.owner);
        self.wizard.on_result = result;
        self.wizard.result_ctx = self;
        try self.cx.root.?.appendChild(a, try self.wizard.mount(self.cx, self.scope));
        try self.wizard.setAssets(&self.assets);
        self.wizard.loadDraft(.{ .name = "target", .host = "target.example", .port = 2222, .user = "deploy", .protocol = protocol, .auth = .key, .key_path = "/tmp/id_ed25519", .key_passphrase = "only current draft", .strict_host_key_checking = false, .keepalive = false, .compression = true, .route = &.{@fromBackingInt(41)}, .jump_chain = &.{"jump"}, .startup_commands = &.{"cd /srv"}, .terminal_type = "screen-256color", .scrollback = 1234 });
        self.wizard.show();
        activate(self.wizard.next1_btn.?);
        activate(self.wizard.next2_btn.?);
        self.cx.layout();
    }
    fn deinit(self: *SaveFixture) void {
        self.wizard.hide();
        feedbackFrames(self);
        self.scope.dispose();
        self.cx.deinit();
        self.assets[0].deinit(a);
        self.registry.deinit();
        self.tmp.cleanup();
    }
    fn activate(node: *ui.Node) void {
        const handler = node.behavior.events.on_click.?;
        handler.callback(handler.context);
    }
    fn clickSave(self: *SaveFixture) void {
        self.cx.layout();
        const rect = self.wizard.save_btn.?.globalRect();
        self.cx.handleClick(rect.x + rect.w / 2, rect.y + rect.h / 2);
    }
    fn result(raw: *anyopaque, requested: mod.Result) !?mod.SaveReceipt {
        const self: *SaveFixture = @ptrCast(@alignCast(raw));
        const draft = switch (requested) {
            .cancelled => {
                self.cancel_calls += 1;
                return null;
            },
            .saved, .save_only => |value| value,
        };
        self.calls += 1;
        switch (requested) {
            .save_only => self.save_only_calls += 1,
            .saved => self.open_calls += 1,
            .cancelled => unreachable,
        }
        self.reentry_blocked = !self.wizard.canSave();
        // A second activation while the real save callback runs must not
        // dispatch another transaction, including accessibility activation.
        activate(self.wizard.save_btn.?);
        var value = try draft.toHostConfig();
        self.transient_secret_received = value.key_passphrase != null;
        value = try draft.toPersistentHostConfig();
        value.key_passphrase = null;
        value.totp_secret = null;
        var transaction = try store.HostsTransaction.init(a, &self.registry);
        defer transaction.deinit();
        const owner = if (draft.source_owner) |expected| try transaction.candidate.?.update(expected, value) else try transaction.candidate.?.add(value);
        try transaction.commit(std.testing.io, self.tmp.dir, self.path, &self.registry);
        self.commits += 1;
        return .{ .owner = owner, .open_failure = self.open_failure };
    }
};

test "wizard save accepts valid untested or failed-test drafts and freezes complete protocol options" {
    for ([_]mod.Protocol{ .ssh, .sftp }) |protocol| {
        var f: SaveFixture = undefined;
        try f.init(protocol);
        defer f.deinit();
        if (protocol == .sftp) f.wizard.setTestResult(.{ .fail = "optional test failed" });
        try std.testing.expect(f.wizard.canSave());
        try std.testing.expectEqual(protocol == .sftp, f.wizard.save_btn.?.behavior.interaction.a11y.?.disabled);
        if (protocol == .sftp) SaveFixture.activate(f.wizard.save_only_btn.?) else f.clickSave();
        try std.testing.expectEqual(@as(usize, 1), f.calls);
        try std.testing.expectEqual(@as(usize, 1), f.commits);
        try std.testing.expect(f.reentry_blocked);
        try std.testing.expectEqual(@as(@TypeOf(f.wizard.root.?.style.display), .none), f.wizard.root.?.style.display);
        var saved = try store.loadHosts(std.testing.io, f.tmp.dir, a, "hosts.toml");
        defer saved.deinit();
        const value = try saved.get(f.wizard.source_owner.?);
        try std.testing.expectEqual(if (protocol == .ssh) hosts.Protocol.ssh else hosts.Protocol.sftp, value.protocol);
        try std.testing.expectEqual(hosts.AuthMode.private_key, value.auth_mode);
        try std.testing.expect(!value.strict_host_key_checking and !value.keepalive and value.compression);
        try std.testing.expectEqualStrings("/tmp/id_ed25519", value.identity_file.?);
        try std.testing.expect(f.transient_secret_received);
        try std.testing.expect(value.key_passphrase == null and value.password == null and value.totp_secret == null);
        try std.testing.expectEqual(@as(u16, 2222), value.port);
        try std.testing.expectEqualStrings("deploy", value.user);
        try std.testing.expectEqual(@as(u64, 41), @backingInt(value.route[0]));
        try std.testing.expectEqualStrings("cd /srv", value.startup_commands[0]);
        try std.testing.expectEqualStrings("screen-256color", value.terminal_type);
        try std.testing.expectEqual(@as(u32, 1234), value.scrollback);
    }
}
test "auto shell integration host selection survives save reload and draft editing" {
    var f: SaveFixture = undefined;
    try f.init(.ssh);
    defer f.deinit();
    try std.testing.expect(f.wizard.currentDraft().auto_shell_integration == null);
    f.wizard.sig_shell_integration.?.set("off");
    try std.testing.expectEqual(@as(?bool, false), f.wizard.currentDraft().auto_shell_integration);
    f.clickSave();
    try std.testing.expectEqual(@as(usize, 1), f.commits);
    var saved = try store.loadHosts(std.testing.io, f.tmp.dir, a, "hosts.toml");
    defer saved.deinit();
    const value = try saved.get(f.wizard.source_owner.?);
    try std.testing.expectEqual(@as(?bool, false), value.auto_shell_integration);
    f.wizard.loadDraft(mod.Draft.fromHost(value));
    try std.testing.expectEqualStrings("off", f.wizard.sig_shell_integration.?.get().?);
    f.wizard.sig_shell_integration.?.set("on");
    try std.testing.expectEqual(@as(?bool, true), f.wizard.currentDraft().auto_shell_integration);
    f.wizard.sig_shell_integration.?.set("inherit");
    try std.testing.expect(f.wizard.currentDraft().auto_shell_integration == null);
}

test "wizard save disk failure keeps the exact draft focus and registry then retries once" {
    var f: SaveFixture = undefined;
    try f.init(.ssh);
    defer f.deinit();
    const before = f.wizard.currentDraft();
    const name_signal = f.wizard.sig_name.?;
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "blocked", .data = "not a directory" });
    f.path = "blocked/hosts.toml";
    f.cx.setFocus(f.wizard.save_btn.?);
    f.clickSave();
    try std.testing.expectEqual(@as(usize, 1), f.calls);
    try std.testing.expectEqual(@as(usize, 0), f.commits);
    try std.testing.expectEqual(@as(usize, 1), f.registry.hosts.len);
    try std.testing.expectEqual(error.NotDir, f.wizard.save_failure.?.cause);
    try std.testing.expectEqual(before.draft_id, f.wizard.currentDraft().draft_id);
    try std.testing.expectEqual(before.revision, f.wizard.currentDraft().revision);
    try std.testing.expectEqual(name_signal, f.wizard.sig_name.?);
    try std.testing.expectEqualStrings("target", name_signal.get());
    try std.testing.expect(f.wizard.source_owner == null);
    try std.testing.expect(f.cx.isFocused(f.wizard.save_btn.?));
    try std.testing.expectEqual(@as(@TypeOf(f.wizard.root.?.style.display), .flex), f.wizard.root.?.style.display);
    try std.testing.expectEqual(@as(@TypeOf(f.wizard.save_error_node.?.style.display), .flex), f.wizard.save_error_node.?.style.display);
    try std.testing.expect(f.wizard.canSave());
    f.path = "hosts.toml";
    f.clickSave();
    try std.testing.expectEqual(@as(usize, 2), f.calls);
    try std.testing.expectEqual(@as(usize, 1), f.commits);
    try std.testing.expectEqual(@as(usize, 2), f.registry.hosts.len);
    try std.testing.expect(f.wizard.save_failure == null);
}

test "wizard save pending probe is gated and a committed opening failure retries the same asset" {
    var f: SaveFixture = undefined;
    try f.init(.ssh);
    defer f.deinit();
    f.wizard.setTestResult(.pending);
    try std.testing.expect(!f.wizard.canSave());
    SaveFixture.activate(f.wizard.save_btn.?);
    try std.testing.expectEqual(@as(usize, 0), f.calls);
    f.wizard.setTestResult(.none);
    f.open_failure = error.WorkspaceClosed;
    f.clickSave();
    try std.testing.expectEqual(@as(usize, 1), f.commits);
    const receipt = f.wizard.source_owner.?;
    try std.testing.expectEqual(@as(@TypeOf(f.wizard.save_failure.?.stage), .open), f.wizard.save_failure.?.stage);
    try std.testing.expectEqual(@as(@TypeOf(f.wizard.root.?.style.display), .flex), f.wizard.root.?.style.display);
    try std.testing.expect(std.mem.startsWith(u8, f.wizard.save_error_node.?.getText().?.content, "配置已保存"));
    // The host refreshes its asset options on the next safe hook after a
    // commit. This must not erase the opening failure or saved identity.
    try f.wizard.setAssets(&f.assets);
    try std.testing.expectEqual(receipt, f.wizard.source_owner.?);
    try std.testing.expectEqual(error.WorkspaceClosed, f.wizard.save_failure.?.cause);
    f.open_failure = null;
    f.clickSave();
    try std.testing.expectEqual(@as(usize, 2), f.commits);
    try std.testing.expectEqual(@as(usize, 2), f.registry.hosts.len);
    try std.testing.expectEqual(receipt.id, f.wizard.source_owner.?.id);
    try std.testing.expectEqual(receipt.revision + 1, f.wizard.source_owner.?.revision);
    try std.testing.expect(f.wizard.save_failure == null);
    try std.testing.expectEqual(@as(@TypeOf(f.wizard.root.?.style.display), .none), f.wizard.root.?.style.display);
}

test "connection wizard keeps edits across steps and refuses unconfigured probe" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{}, .{});
    cx.root = root;
    var wizard: mod.RemoteEditor = .{};
    const node = try wizard.mount(cx, scope);
    try root.appendChild(cx.allocator, node);
    const assets = [_]mod.Draft{.{ .source_owner = .{ .id = @fromBackingInt(41), .revision = 2 }, .name = "bastion", .host = "127.0.0.1", .user = "jump" }};
    try wizard.setAssets(&assets);
    wizard.loadDraft(.{ .name = "target", .host = "127.0.0.1", .user = "test", .route = &.{@fromBackingInt(41)}, .jump_chain = &.{"bastion"}, .startup_commands = &.{"cd /tmp"} });
    var snapshot = try wizard.currentDraft().dupe(std.testing.allocator);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 41), @backingInt(snapshot.route[0]));
    try std.testing.expectEqualStrings("bastion", snapshot.jump_chain[0]);
    try std.testing.expectEqualStrings("cd /tmp", snapshot.startup_commands[0]);
    wizard.show();
    try std.testing.expectEqualStrings("target", wizard.currentDraft().name);
    try std.testing.expectEqual(@as(usize, 1), wizard.currentDraft().startup_commands.len);
}

test "wizard topology uses registry address user and only configured exits" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{}, .{});
    cx.root = root;
    var wizard: mod.RemoteEditor = .{};
    try root.appendChild(cx.allocator, try wizard.mount(cx, scope));
    const assets = [_]mod.Draft{
        .{ .source_owner = .{ .id = @fromBackingInt(41), .revision = 2 }, .name = "jump-a", .host = "192.0.2.1", .port = 2222, .user = "alice" },
        .{ .source_owner = .{ .id = @fromBackingInt(42), .revision = 3 }, .name = "jump-b", .host = "192.0.2.2", .user = "bob" },
        .{ .source_owner = .{ .id = @fromBackingInt(43), .revision = 4 }, .name = "jump-c", .host = "192.0.2.3", .user = "carol" },
    };
    try wizard.setAssets(&assets);
    wizard.loadDraft(.{ .name = "target", .host = "192.0.2.4", .user = "dave", .route = &.{ @fromBackingInt(41), @fromBackingInt(42), @fromBackingInt(43) }, .jump_chain = &.{ "jump-a", "jump-b", "jump-c" } });
    try std.testing.expectEqualStrings("alice@192.0.2.1:2222", wizard.jump_addresses[0].?.getText().?.content);
    try std.testing.expectEqualStrings("待连接", wizard.jump_users[0].?.getText().?.content);
    try std.testing.expectEqualStrings("jump-a", wizard.route_previews[0].names[1].?.getText().?.content);
    try std.testing.expectEqualStrings("jump-c", wizard.route_previews[0].names[3].?.getText().?.content);
    try std.testing.expectEqualStrings("target", wizard.route_previews[0].names[9].?.getText().?.content);
    try std.testing.expectEqual(@as(usize, 4), wizard.exit_options.?.get().len);
    wizard.loadDraft(.{ .name = "direct", .host = "192.0.2.4", .user = "dave", .socks_exit = 7 });
    try std.testing.expectEqual(@as(usize, 1), wizard.exit_options.?.get().len);
    try std.testing.expect(wizard.currentDraft().socks_exit == null);
}

test "wizard keeps long steps in real scroll areas and exposes programmatic bounds" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{}, .{});
    cx.root = root;
    var wizard: mod.RemoteEditor = .{};
    try root.appendChild(cx.allocator, try wizard.mount(cx, scope));
    try std.testing.expect(wizard.scrollState(.protocol) != null);
    try std.testing.expect(wizard.scrollState(.form) != null);
    try std.testing.expect(wizard.step1_scroll_content != null);
    try std.testing.expect(wizard.step2_scroll_content != null);
    wizard.scrollToBottom(.protocol);
    try std.testing.expect(wizard.scrollState(.protocol).?.scroll_y <= wizard.scrollState(.protocol).?.maxScrollY());
    wizard.scrollToTop(.form);
    try std.testing.expectEqual(@as(f32, 0), wizard.scrollState(.form).?.scroll_y);
}

test "wizard modal and scroll viewport fit initial short window and resized narrow window" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(920, 576);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    var wizard: mod.RemoteEditor = .{};
    try root.appendChild(cx.allocator, try wizard.mount(cx, scope));
    wizard.show();
    SaveFixture.activate(findId(wizard.root.?, "wizard.advanced.toggle").?);
    for (0..3) |_| {
        cx.layout();
        _ = wizard.updateViewport();
    }
    cx.layout();

    const modal = wizard.modal.?.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 760), modal.w, 0.5);
    try std.testing.expect(modal.y >= 15.5 and modal.y + modal.h <= 560.5);
    try std.testing.expect(wizard.step1_scroll.?.globalRect().h <= 544.5);
    const state = wizard.scrollState(.protocol).?;
    state.content_height = wizard.step1_scroll_content.?.globalRect().h;
    state.viewport_height = wizard.step1_scroll.?.globalRect().h;
    try std.testing.expect(state.maxScrollY() > 0);
    wizard.scrollToBottom(.protocol);
    try std.testing.expectApproxEqAbs(state.maxScrollY(), state.scroll_y, 0.5);
    try std.testing.expectApproxEqAbs(-state.scroll_y, wizard.step1_scroll_content.?.style.translate_y, 0.5);
    const next = wizard.next1_btn.?.globalRect();
    const viewport = wizard.step1_scroll.?.globalRect();
    try std.testing.expect(next.y >= viewport.y + viewport.h);
    try std.testing.expect(next.y + next.h <= modal.y + modal.h - 13.5);
    wizard.step = .form;
    wizard.show();
    wizard.step = .form;
    wizard.step1_scroll.?.setDisplay(.none);
    wizard.step2_scroll.?.setDisplay(.flex);
    for (0..3) |_| {
        cx.layout();
        _ = wizard.updateViewport();
    }
    cx.layout();
    try std.testing.expectApproxEqAbs(@as(f32, 760), wizard.modal.?.globalRect().w, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 720), wizard.step2_scroll.?.globalRect().w, 0.5);
    cx.setViewport(600, 420);
    for (0..3) |_| {
        cx.layout();
        _ = wizard.updateViewport();
    }
    cx.layout();
    const resized = wizard.modal.?.globalRect();
    try std.testing.expect(resized.x >= 15.5 and resized.x + resized.w <= 584.5);
    try std.testing.expect(resized.y >= 15.5 and resized.y + resized.h <= 404.5);
}

test "copy modal is conditional on real assets and remains centered after transitions" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    try cx.setTestFrameStep(100);
    cx.setViewport(920, 576);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    var wizard: mod.RemoteEditor = .{};
    try root.appendChild(cx.allocator, try wizard.mount(cx, scope));
    wizard.show();
    cx.layout();
    try std.testing.expect(!wizard.copy_open.?.peek());
    SaveFixture.activate(findId(wizard.root.?, "wizard.copy.open").?);
    try std.testing.expect(!wizard.copy_open.?.peek());
    const assets = [_]mod.Draft{.{ .source_owner = .{ .id = @fromBackingInt(71), .revision = 5 }, .name = "real-host", .host = "192.0.2.1", .user = "test" }};
    try wizard.setAssets(&assets);
    SaveFixture.activate(findId(wizard.root.?, "wizard.copy.open").?);
    for (0..4) |_| cx.layout();
    try std.testing.expect(wizard.copy_open.?.peek());
    try std.testing.expectApproxEqAbs(@as(f32, 440), wizard.copy_dialog.?.globalRect().w, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 73.5), wizard.copy_bar.?.globalRect().h, 0.5);
    try wizard.setAssets(&.{});
    cx.layout();
    try std.testing.expect(!wizard.copy_open.?.peek());
    try wizard.setAssets(&assets);
    SaveFixture.activate(findId(wizard.root.?, "wizard.copy.open").?);
    for (0..4) |_| cx.layout();
    cx.handleKeyDown(.escape, .{});
    try std.testing.expect(!wizard.copy_open.?.peek());
    try std.testing.expect(wizard.isVisible());
}

fn findId(node: *ui.Node, id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, value, id)) return node;
    for (node.children.items) |child| if (findId(child, id)) |found| return found;
    return null;
}

fn findText(node: *ui.Node, content: []const u8) ?*ui.Node {
    if (node.getText()) |value| if (std.mem.eql(u8, value.content, content)) return node;
    for (node.children.items) |child| if (findText(child, content)) |found| return found;
    return null;
}

test "three step wizard retains editors and probe slots inside one V3 760 point shell" {
    var f: SaveFixture = undefined;
    try f.init(.ssh);
    defer f.deinit();
    const shell = f.wizard.modal.?;
    const auth_area = f.wizard.authentication_area;
    const logs_area = f.wizard.test_logs_area;
    const name_editor = findId(f.wizard.root.?, "wizard.name").?;
    const draft_id = f.wizard.draft_id;
    for ([_][]const u8{ "wizard.back", "wizard.back", "wizard.next.identity", "wizard.next.route" }) |id| {
        SaveFixture.activate(findId(f.wizard.root.?, id).?);
        f.cx.layout();
        try std.testing.expectEqual(shell, f.wizard.modal.?);
        try std.testing.expectApproxEqAbs(@as(f32, 760), shell.globalRect().w, 0.5);
        try std.testing.expectEqual(name_editor, findId(f.wizard.root.?, "wizard.name").?);
        try std.testing.expectEqual(auth_area, f.wizard.authentication_area);
        try std.testing.expectEqual(logs_area, f.wizard.test_logs_area);
        try std.testing.expectEqual(draft_id, f.wizard.draft_id);
    }
    try std.testing.expectEqual(mod.Step.confirm, f.wizard.step);
    try std.testing.expectEqual(@as(@TypeOf(shell.style.display), .flex), shell.style.display);
    try std.testing.expectEqual(@as(@TypeOf(f.wizard.scrolls[2].?.container.style.display), .flex), f.wizard.scrolls[2].?.container.style.display);
    try std.testing.expect(f.wizard.scrollState(.confirm) != null);
}

test "wizard host key policy uses native select and review returns focus" {
    var f: SaveFixture = undefined;
    try f.init(.ssh);
    defer f.deinit();
    f.wizard.loadDraft(.{ .source_owner = .{ .id = @fromBackingInt(41), .revision = 3 }, .name = "target", .host = "192.0.2.1", .user = "ops", .strict_host_key_checking = false });
    f.wizard.show();
    feedbackFrames(&f);
    const policy = f.wizard.strict_checkbox.?;
    const compression_before = f.wizard.currentDraft().compression;
    try std.testing.expectEqualStrings("false", f.wizard.sig_strict_policy.?.peek().?);
    const scroll = f.wizard.scrolls[0].?;
    scroll.state.content_height = scroll.content.globalRect().h;
    scroll.state.viewport_height = scroll.container.globalRect().h;
    ui.widgets.scrollIntoView(scroll.state, scroll.content, policy, .nearest);
    feedbackFrames(&f);
    f.cx.setFocus(policy);
    f.cx.handleKeyDown(.down, .{});
    feedbackFrames(&f);
    f.cx.handleKeyDown(.home, .{});
    f.cx.handleKeyDown(.@"return", .{});
    feedbackFrames(&f);
    try std.testing.expect(f.wizard.currentDraft().strict_host_key_checking);
    try std.testing.expectEqual(compression_before, f.wizard.currentDraft().compression);
    f.cx.setFocus(policy);
    f.cx.handleKeyDown(.down, .{});
    feedbackFrames(&f);
    f.cx.handleKeyDown(.end, .{});
    f.cx.handleKeyDown(.@"return", .{});
    feedbackFrames(&f);
    try std.testing.expect(!f.wizard.currentDraft().strict_host_key_checking);
    SaveFixture.activate(f.wizard.next1_btn.?);
    SaveFixture.activate(f.wizard.next2_btn.?);
    try std.testing.expectEqualStrings("严格验证已关闭", f.wizard.summary_values[4].?.getText().?.content);
    const identity_ = f.wizard.currentDraft().draft_id;
    SaveFixture.activate(findId(f.wizard.root.?, "wizard.review.modify").?);
    feedbackFrames(&f);
    try std.testing.expectEqual(mod.Step.protocol, f.wizard.step);
    try std.testing.expectEqual(identity_, f.wizard.currentDraft().draft_id);
    try std.testing.expect(f.cx.isFocused(findId(f.wizard.root.?, "wizard.name").?));
}

test "wizard pending probe disables actual editors steps and saves while cancellation remains reachable" {
    var f: SaveFixture = undefined;
    try f.init(.ssh);
    defer f.deinit();
    const before = f.wizard.currentDraft();
    f.wizard.setTestResult(.pending);
    try std.testing.expect(f.wizard.locked.?.get());
    for (f.wizard.inputs.items) |input| try std.testing.expect(input.state.disabled);
    try std.testing.expect(!f.wizard.strict_checkbox.?.behavior.interaction.focusable);
    for (f.wizard.compression_checkbox.?.children.items) |choice|
        try std.testing.expect(choice.behavior.interaction.a11y.?.disabled);
    try std.testing.expect(!f.wizard.cancel_btn.?.behavior.interaction.a11y.?.disabled);
    for ([_][]const u8{ "wizard.step.identity", "wizard.review.modify", "wizard.back", "wizard.save_only", "wizard.save" }) |id| SaveFixture.activate(findId(f.wizard.root.?, id).?);
    try std.testing.expect(!findId(f.wizard.root.?, "wizard.auth").?.behavior.interaction.focusable);
    try std.testing.expectEqual(mod.Step.confirm, f.wizard.step);
    try std.testing.expectEqual(before.draft_id, f.wizard.currentDraft().draft_id);
    try std.testing.expectEqual(before.revision, f.wizard.currentDraft().revision);
    try std.testing.expectEqual(before.auth, f.wizard.currentDraft().auth);
    try std.testing.expectEqual(@as(usize, 0), f.calls);
    f.wizard.setTestResult(.{ .fail = "已释放" });
    try std.testing.expect(!f.wizard.locked.?.get());
    for (f.wizard.inputs.items) |input| try std.testing.expect(!input.state.disabled);
    try std.testing.expect(f.wizard.canSave());
}

test "wizard probe logs reject stale stamps preserve the slot and clear when editing" {
    var f: SaveFixture = undefined;
    try f.init(.ssh);
    defer f.deinit();
    const before = f.wizard.currentDraft();
    const generation = f.wizard.test_generation;
    const area = f.wizard.test_logs_area;
    try std.testing.expect(!f.wizard.setTestProgress(generation + 1, before.draft_id, before.revision, "late"));
    try std.testing.expect(!f.wizard.setTestProgress(generation, before.draft_id + 1, before.revision, "wrong draft"));
    try std.testing.expect(!f.wizard.setTestProgress(generation, before.draft_id, before.revision + 1, "old revision"));
    try std.testing.expect(f.wizard.setTestProgress(generation, before.draft_id, before.revision, "第 1 跳 · 主机密钥核对完成"));
    try std.testing.expectEqualStrings("第 1 跳 · 主机密钥核对完成", f.wizard.test_log_text.getText().?.content);
    SaveFixture.activate(findId(f.wizard.root.?, "wizard.test.logs.toggle").?);
    try std.testing.expectEqual(area, f.wizard.test_logs_area);
    try std.testing.expectEqual(@as(@TypeOf(f.wizard.logs_scroll.?.style.display), .flex), f.wizard.logs_scroll.?.style.display);
    SaveFixture.activate(findId(f.wizard.root.?, "wizard.step.identity").?);
    try selectWizardAuth(&f, "wizard.auth.agent");
    try std.testing.expectEqualStrings("", f.wizard.test_log_text.getText().?.content);
    try std.testing.expectEqual(@as(@TypeOf(area.style.display), .none), area.style.display);
    try std.testing.expect(!f.wizard.setTestProgress(generation, before.draft_id, before.revision, "late completion"));
}

test "wizard save only dispatches its own intent without opening and empty password remains valid" {
    var f: SaveFixture = undefined;
    try f.init(.ssh);
    defer f.deinit();
    f.wizard.loadDraft(.{ .name = "password later", .host = "192.0.2.9", .user = "ops" });
    f.wizard.show();
    SaveFixture.activate(f.wizard.next1_btn.?);
    SaveFixture.activate(f.wizard.next2_btn.?);
    try std.testing.expectEqual(mod.Step.confirm, f.wizard.step);
    try std.testing.expect(f.wizard.currentDraft().password == null);
    try std.testing.expect(f.wizard.canSave());
    SaveFixture.activate(f.wizard.save_only_btn.?);
    try std.testing.expectEqual(@as(usize, 1), f.calls);
    try std.testing.expectEqual(@as(usize, 1), f.commits);
    try std.testing.expectEqual(@as(usize, 1), f.save_only_calls);
    try std.testing.expectEqual(@as(usize, 0), f.open_calls);
    try std.testing.expect(!f.wizard.isVisible());
}

test "wizard pending cancellation retains exact stamp and gate until released completion" {
    var f: SaveFixture = undefined;
    try f.init(.ssh);
    defer f.deinit();
    const before = f.wizard.currentDraft();
    const generation = f.wizard.test_generation;
    f.wizard.setTestResult(.pending);
    SaveFixture.activate(f.wizard.cancel_btn.?);
    try std.testing.expectEqual(@as(usize, 1), f.cancel_calls);
    try std.testing.expect(f.wizard.cancel_requested);
    try std.testing.expect(f.wizard.isVisible());
    try std.testing.expect(f.wizard.locked.?.get());
    try std.testing.expectEqual(generation, f.wizard.test_generation);
    try std.testing.expectEqual(before.draft_id, f.wizard.draft_id);
    try std.testing.expect(!f.wizard.setTestResultForDraft(generation + 1, before.draft_id, before.revision, .{ .fail = "late" }));
    try std.testing.expect(f.wizard.setTestResultForDraft(generation, before.draft_id, before.revision, .{ .fail = "测试已取消 · 资源已释放" }));
    try std.testing.expect(!f.wizard.isVisible());
    try std.testing.expect(!f.wizard.cancel_requested);
    try std.testing.expect(!f.wizard.locked.?.get());
    f.wizard.show();
    try std.testing.expect(!f.wizard.locked.?.get());
    try std.testing.expectEqualStrings("", f.wizard.currentDraft().name);
    try std.testing.expect(!f.wizard.canSave());
}

test "wizard completed step cannot bypass fields that have become invalid" {
    var f: SaveFixture = undefined;
    try f.init(.ssh);
    defer f.deinit();
    SaveFixture.activate(findId(f.wizard.root.?, "wizard.step.identity").?);
    try std.testing.expectEqual(mod.Step.protocol, f.wizard.step);
    f.wizard.sig_port.?.set("+22");
    SaveFixture.activate(findId(f.wizard.root.?, "wizard.step.review").?);
    try std.testing.expectEqual(mod.Step.protocol, f.wizard.step);
    try std.testing.expect(!f.wizard.canSave());
    try std.testing.expectEqualStrings("+22", f.wizard.sig_port.?.get());
}

test "wizard copy selection preserves the draft until explicit apply then saves a new identity" {
    var f: SaveFixture = undefined;
    try f.init(.ssh);
    defer f.deinit();
    SaveFixture.activate(findId(f.wizard.root.?, "wizard.step.identity").?);
    const original_id = f.wizard.currentDraft().draft_id;
    f.wizard.sig_copy_source.?.set("conn:41");
    try f.wizard.setAssets(&f.assets);
    try std.testing.expectEqualStrings("target", f.wizard.currentDraft().name);
    try std.testing.expectEqual(original_id, f.wizard.currentDraft().draft_id);
    SaveFixture.activate(findId(f.cx.root.?, "wizard.copy.apply").?);
    const copied = f.wizard.currentDraft();
    try std.testing.expect(copied.draft_id != original_id);
    try std.testing.expect(copied.source_owner == null);
    try std.testing.expectEqual(f.assets[0].source_owner.?, copied.copy_source_owner.?);
    try std.testing.expectEqualStrings("jump-副本", copied.name);
    try std.testing.expect(copied.password == null and copied.key_passphrase == null);
    SaveFixture.activate(f.wizard.next1_btn.?);
    SaveFixture.activate(f.wizard.next2_btn.?);
    SaveFixture.activate(f.wizard.save_only_btn.?);
    try std.testing.expectEqual(@as(usize, 2), f.registry.hosts.len);
    try std.testing.expect(f.wizard.source_owner.?.id != f.assets[0].source_owner.?.id);
    try std.testing.expectEqualStrings("jump", f.registry.hosts[f.registry.indexOf(f.assets[0].source_owner.?.id).?].name);
}

test "wizard modal Escape consumes active IME composition before closing the draft" {
    var f: SaveFixture = undefined;
    try f.init(.ssh);
    defer f.deinit();
    SaveFixture.activate(findId(f.wizard.root.?, "wizard.step.identity").?);
    const editor = findId(f.wizard.root.?, "wizard.name").?;
    f.cx.setFocus(editor);
    f.cx.handleImePreedit("ni", 2);
    f.cx.handleKeyDown(.escape, .{});
    try std.testing.expect(f.wizard.isVisible());
    try std.testing.expectEqualStrings("target", f.wizard.sig_name.?.get());
    f.cx.handleKeyDown(.escape, .{});
    try std.testing.expectEqual(@as(usize, 1), f.cancel_calls);
    try std.testing.expect(!f.wizard.isVisible());
}

test "wizard SSH global defaults show injected values without changing draft or probe stamps" {
    var f: SaveFixture = undefined;
    try f.init(.ssh);
    defer f.deinit();
    const timeout = findId(f.wizard.root.?, "wizard.ssh.connect_timeout").?;
    const keepalive = findId(f.wizard.root.?, "wizard.ssh.keepalive").?;
    try std.testing.expectEqualStrings("—", timeout.getText().?.content);
    try std.testing.expectEqualStrings("—", keepalive.getText().?.content);
    f.wizard.setTestResult(.pending);
    const before = f.wizard.currentDraft();
    const generation = f.wizard.test_generation;
    f.wizard.setSshDefaults(47, 61);
    try std.testing.expectEqualStrings("47 秒", timeout.getText().?.content);
    try std.testing.expectEqualStrings("61 秒", keepalive.getText().?.content);
    try std.testing.expectEqual(before.draft_id, f.wizard.currentDraft().draft_id);
    try std.testing.expectEqual(before.revision, f.wizard.currentDraft().revision);
    try std.testing.expectEqual(generation, f.wizard.test_generation);
    try std.testing.expect(f.wizard.locked.?.get());
    try std.testing.expect(!f.wizard.canSave());
    f.wizard.setSshDefaults(65535, 0);
    try std.testing.expectEqualStrings("65535 秒", timeout.getText().?.content);
    try std.testing.expectEqualStrings("0 秒", keepalive.getText().?.content);
    try std.testing.expectEqual(timeout, findId(f.wizard.root.?, "wizard.ssh.connect_timeout").?);
    try std.testing.expectEqual(keepalive, findId(f.wizard.root.?, "wizard.ssh.keepalive").?);
}

test "wizard accepts real SSH defaults before mounting its read only fields" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    var wizard: mod.RemoteEditor = .{};
    wizard.setSshDefaults(4, 27);
    try cx.root.?.appendChild(a, try wizard.mount(cx, scope));
    try std.testing.expectEqualStrings("4 秒", findId(wizard.root.?, "wizard.ssh.connect_timeout").?.getText().?.content);
    try std.testing.expectEqualStrings("27 秒", findId(wizard.root.?, "wizard.ssh.keepalive").?.getText().?.content);
}

test "wizard access cards reject an empty jump and let identity return to route correction" {
    var f: SaveFixture = undefined;
    try f.init(.ssh);
    defer f.deinit();
    // This case starts with a direct draft; a loaded route is intentionally
    // retained when the access mode is toggled and is covered separately.
    f.wizard.loadDraft(.{ .name = "target", .host = "target.example", .user = "deploy", .protocol = .ssh });
    SaveFixture.activate(findId(f.wizard.root.?, "wizard.step.identity").?);
    SaveFixture.activate(f.wizard.next1_btn.?);
    SaveFixture.activate(findId(f.wizard.root.?, "wizard.access.direct").?);
    try std.testing.expectEqual(@as(usize, 0), f.wizard.currentDraft().route.len);
    try std.testing.expect(f.wizard.canSave());
    SaveFixture.activate(findId(f.wizard.root.?, "wizard.step.route").?);
    feedbackFrames(&f);
    const access = findId(f.wizard.root.?, "wizard.access.jump").?.globalRect();
    f.cx.handleMouseMove(access.x + access.w / 2, access.y + access.h / 2);
    f.cx.handleClick(access.x + access.w / 2, access.y + access.h / 2);
    feedbackFrames(&f);
    f.cx.handleMouseMove(0, 0);
    feedbackFrames(&f);
    try std.testing.expect(f.wizard.route_choices[1].?.highlight.style.display == .flex);
    try std.testing.expect(f.wizard.route_choices[0].?.highlight.style.display == .none);
    try std.testing.expect(!f.wizard.canSave());
    try std.testing.expect(f.wizard.next2_disabled.?.peek());
    try std.testing.expect(findId(f.wizard.root.?, "wizard.route.error").?.style.display == .flex);
    SaveFixture.activate(f.wizard.next2_btn.?);
    try std.testing.expectEqual(mod.Step.form, f.wizard.step);
    SaveFixture.activate(f.wizard.back_btn.?);
    try std.testing.expectEqual(mod.Step.protocol, f.wizard.step);
    try std.testing.expect(!f.wizard.next1_disabled.?.peek());
    SaveFixture.activate(f.wizard.next1_btn.?);
    try std.testing.expectEqual(mod.Step.form, f.wizard.step);
    SaveFixture.activate(findId(f.wizard.root.?, "wizard.access.direct").?);
    feedbackFrames(&f);
    try std.testing.expect(!f.wizard.next2_disabled.?.peek());
    try std.testing.expect(findId(f.wizard.root.?, "wizard.route.error").?.style.display == .none);
    SaveFixture.activate(f.wizard.next2_btn.?);
    try std.testing.expectEqual(mod.Step.confirm, f.wizard.step);
}

test "wizard jump picker commits registry identity through actual keyboard interaction" {
    var f: SaveFixture = undefined;
    try f.init(.ssh);
    defer f.deinit();
    var replacement = [_]mod.Draft{try f.assets[0].dupe(a)};
    try f.wizard.setAssets(&replacement);
    f.assets[0].deinit(a);
    f.assets = replacement;
    try f.wizard.setAssets(&f.assets);
    SaveFixture.activate(findId(f.wizard.root.?, "wizard.access.direct").?);
    SaveFixture.activate(findId(f.wizard.root.?, "wizard.step.route").?);
    SaveFixture.activate(findId(f.wizard.root.?, "wizard.access.jump").?);
    feedbackFrames(&f);
    const trigger = findId(f.wizard.root.?, "wizard.route.hop.0").?;
    f.cx.setFocus(trigger);
    f.cx.handleKeyDown(.down, .{});
    feedbackFrames(&f);
    f.cx.handleKeyDown(.@"return", .{});
    feedbackFrames(&f);
    const value = f.wizard.currentDraft();
    try std.testing.expectEqual(@as(usize, 1), value.route.len);
    try std.testing.expectEqual(@as(u64, 41), @backingInt(value.route[0]));
    try std.testing.expectEqualStrings("jump", value.jump_chain[0]);
    try std.testing.expect(!f.wizard.next2_disabled.?.peek());
    try std.testing.expect(f.wizard.jump_add_disabled.?.peek());
    SaveFixture.activate(findId(f.wizard.root.?, "wizard.route.add").?);
    feedbackFrames(&f);
    try std.testing.expectEqual(@as(usize, 1), f.wizard.jump_count);
    try std.testing.expect(!f.wizard.next2_disabled.?.peek());
    try std.testing.expect(findId(f.wizard.root.?, "wizard.route.error").?.style.display == .none);
}

test "SFTP wizard keeps routed draft save only until explicit direct path selection" {
    var f: SaveFixture = undefined;
    try f.init(.sftp);
    defer f.deinit();
    try std.testing.expect(f.wizard.canSave());
    try std.testing.expect(!f.wizard.canOpen());
    try std.testing.expect(f.wizard.open_disabled.?.get());
    try std.testing.expect(f.wizard.test_action_disabled.?.get());
    SaveFixture.activate(f.wizard.test_btn.?);
    SaveFixture.activate(f.wizard.save_btn.?);
    try std.testing.expectEqual(@as(usize, 0), f.calls);
    try std.testing.expectEqual(@as(@TypeOf(f.wizard.test_kind), .none), f.wizard.test_kind);
    try std.testing.expectEqual(@as(usize, 1), f.wizard.currentDraft().route.len);
    var direct = try f.wizard.currentDraft().dupe(a);
    defer direct.deinit(a);
    a.free(direct.route);
    direct.route = &.{};
    for (direct.jump_chain) |name| a.free(name);
    a.free(direct.jump_chain);
    direct.jump_chain = &.{};
    f.wizard.loadDraft(direct);
    f.cx.layout();
    try std.testing.expect(f.wizard.canOpen());
    try std.testing.expect(!f.wizard.open_disabled.?.get());
    try std.testing.expect(!f.wizard.test_action_disabled.?.get());
    f.wizard.setTestResult(.{ .fail = "optional SFTP test failed" });
    SaveFixture.activate(f.wizard.save_btn.?);
    try std.testing.expectEqual(@as(usize, 1), f.calls);
    try std.testing.expectEqual(@as(usize, 1), f.open_calls);
    const saved = try f.registry.get(f.wizard.source_owner.?);
    try std.testing.expectEqual(hosts.Protocol.sftp, saved.protocol);
    try std.testing.expectEqual(@as(usize, 0), saved.route.len);
}

test "wizard review actual pointer reaches test action in fixed footer with current target" {
    var f: SaveFixture = undefined;
    try f.init(.ssh);
    defer f.deinit();
    f.cx.setTheme(&ui.theme.light);
    for (0..8) |_| {
        f.cx.layout();
        _ = f.wizard.updateViewport();
        _ = f.cx.render();
    }
    const button = f.wizard.test_btn.?.globalRect();
    const footer = f.wizard.footer.?.globalRect();
    const viewport = f.wizard.scrolls[2].?.container.globalRect();
    try std.testing.expect(button.y >= footer.y);
    try std.testing.expect(button.y + button.h <= footer.y + footer.h + 0.1);
    try std.testing.expect(viewport.y + viewport.h <= footer.y + 0.1);
    const preview = f.wizard.route_previews[1];
    try std.testing.expectEqualStrings("target", preview.names[9].?.getText().?.content);
    try std.testing.expectEqualStrings("deploy@target.example:2222", preview.addresses[9].?.getText().?.content);
    f.cx.handleClick(button.x + button.w / 2, button.y + button.h / 2);
    f.cx.handleMouseUp(button.x + button.w / 2, button.y + button.h / 2);
    try std.testing.expect(f.wizard.test_kind != .none);
    try std.testing.expectEqual(@as(usize, 0), f.calls);
}

test "SFTP wizard stepper keeps plain numerals and only the current selection after navigation and theme change" {
    const theme = @import("ui/app_theme.zig");
    const previous = theme.currentName();
    defer theme.select(previous);
    theme.select(.dark);
    var f: SaveFixture = undefined;
    try f.init(.sftp);
    defer f.deinit();
    try f.cx.setTestFrameStep(100);
    for (0..4) |_| {
        f.cx.advanceFrameClock();
        _ = f.cx.render();
    }
    try std.testing.expectEqual(ui.Color.TRANSPARENT, f.wizard.step_buttons[0].?.getBackground());
    try std.testing.expectEqual(ui.Color.TRANSPARENT, f.wizard.step_buttons[1].?.getBackground());
    try std.testing.expectEqual(theme.popupSelection(), f.wizard.step_buttons[2].?.getBackground());
    for ([_][]const u8{ "wizard.step.identity.check", "wizard.step.route.check" }) |id| {
        const check = findId(f.wizard.root.?, id) orelse return error.CompletedStepCheckMissing;
        try std.testing.expectEqual(@as(@TypeOf(check.style.display), .none), check.style.display);
    }
    const route = f.wizard.step_buttons[1].?.globalRect();
    f.cx.handleClick(route.x + route.w / 2, route.y + route.h / 2);
    f.cx.handleMouseUp(route.x + route.w / 2, route.y + route.h / 2);
    try std.testing.expectEqual(mod.Step.form, f.wizard.step);
    theme.select(.light);
    f.cx.setTheme(theme.widgetTheme(.light));
    for (0..4) |_| {
        f.cx.advanceFrameClock();
        _ = f.cx.render();
    }
    try std.testing.expectEqual(ui.Color.TRANSPARENT, f.wizard.step_buttons[0].?.getBackground());
    try std.testing.expectEqual(theme.popupSelection(), f.wizard.step_buttons[1].?.getBackground());
    try std.testing.expectEqual(ui.Color.TRANSPARENT, f.wizard.step_buttons[2].?.getBackground());
    try std.testing.expectEqual(@as(@TypeOf(findId(f.wizard.root.?, "wizard.step.route.check").?.style.display), .none), findId(f.wizard.root.?, "wizard.step.route.check").?.style.display);
    try std.testing.expectEqual(@as(usize, 1), f.wizard.currentDraft().route.len);
    try std.testing.expectEqual(@as(usize, 0), f.calls);
}

test "SFTP wizard review exposes the same identity and value fields without a summary disclosure" {
    var f: SaveFixture = undefined;
    try f.init(.sftp);
    defer f.deinit();
    feedbackFrames(&f);
    const icon = findId(f.wizard.root.?, "wizard.protocol.icon").?;
    const summary_icon = findId(f.wizard.root.?, "wizard.review.summary.icon").?;
    try std.testing.expectEqual(ui.icons.plug.icon_id.?, icon.getIcon().?.icon_id);
    try std.testing.expectEqual(ui.icons.folder_open.icon_id.?, summary_icon.getIcon().?.icon_id);
    try std.testing.expectEqualStrings("SFTP", f.wizard.summary_values[0].?.getText().?.content);
    try std.testing.expectEqualStrings("target", f.wizard.summary_name.?.getText().?.content);
    try std.testing.expectEqualStrings("target.example:2222", f.wizard.summary_endpoint.?.getText().?.content);
    try std.testing.expectEqual(@as(@TypeOf(f.wizard.summary_details.?.style.display), .flex), f.wizard.summary_details.?.style.display);
    try std.testing.expect(findId(f.wizard.root.?, "wizard.review.summary.toggle") == null);
    // Path editing returns to the existing draft and retains its selected identity.
    SaveFixture.activate(findId(f.wizard.root.?, "wizard.review.route.modify").?);
    try std.testing.expectEqual(mod.Step.form, f.wizard.step);
    try std.testing.expectEqual(@as(usize, 1), f.wizard.currentDraft().route.len);
    try std.testing.expectEqual(@as(usize, 0), f.calls);
}

test "SFTP wizard unavailable test text fits its prototype action and direct retry restores compact geometry" {
    var f: SaveFixture = undefined;
    try f.init(.sftp);
    defer f.deinit();
    for (0..4) |_| _ = f.cx.render();
    const button = f.wizard.test_btn.?;
    try std.testing.expectApproxEqAbs(@as(f32, 196), button.globalRect().w, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 34), button.globalRect().h, 0.5);
    try std.testing.expect(button.behavior.interaction.a11y.?.disabled);
    const label = findText(button, "检测 SFTP · 不可用") orelse return error.SftpUnavailableLabelMissing;
    try std.testing.expect(label.globalRect().w <= button.globalRect().w);
    try std.testing.expect(label.globalRect().x >= button.globalRect().x);
    try std.testing.expect(label.globalRect().x + label.globalRect().w <= button.globalRect().x + button.globalRect().w);
    SaveFixture.activate(button);
    try std.testing.expectEqual(@as(@TypeOf(f.wizard.test_kind), .none), f.wizard.test_kind);
    f.wizard.loadDraft(.{ .name = "target", .host = "target.example", .user = "deploy", .protocol = .sftp });
    f.wizard.show();
    SaveFixture.activate(f.wizard.next1_btn.?);
    SaveFixture.activate(f.wizard.next2_btn.?);
    for (0..3) |_| _ = f.cx.render();
    try std.testing.expectApproxEqAbs(@as(f32, 76), button.globalRect().w, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 34), button.globalRect().h, 0.5);
    try std.testing.expect(findText(button, "检测 SFTP") != null);
    f.wizard.setTestResult(.{ .fail = "只读目录验证失败" });
    try std.testing.expect(findText(button, "重新测试") != null);
    try std.testing.expectEqual(@as(usize, 0), f.calls);
}

test "wizard cancel closes directly and clears draft without saving" {
    var f: SaveFixture = undefined;
    try f.init(.ssh);
    defer f.deinit();
    const before = try f.wizard.currentDraft().dupe(a);
    defer {
        var owned = before;
        owned.deinit(a);
    }
    const generation = f.wizard.test_generation;
    f.wizard.cancel();
    try std.testing.expect(!f.wizard.isVisible());
    try std.testing.expectEqual(@as(usize, 1), f.cancel_calls);
    try std.testing.expectEqual(@as(usize, 0), f.commits);
    try std.testing.expectEqualStrings("", f.wizard.currentDraft().name);
    try std.testing.expect(!f.wizard.advanced_expanded);
    try std.testing.expect(!f.wizard.strict_focus_pending);
    try std.testing.expectEqual(@as(f32, 0), f.wizard.scrolls[0].?.state.scroll_y);
    try std.testing.expect(f.wizard.currentDraft().key_passphrase == null);
    try std.testing.expect(!f.wizard.setTestResultForDraft(generation, before.draft_id, before.revision, .{ .ok = "stale result" }));
}

test "wizard partial and empty drafts both close directly" {
    var f: SaveFixture = undefined;
    try f.init(.ssh);
    defer f.deinit();
    f.wizard.loadDraft(.{ .name = "unfinished" });
    f.wizard.show();
    f.wizard.cancel();
    try std.testing.expect(!f.wizard.isVisible());
    try std.testing.expectEqualStrings("", f.wizard.currentDraft().name);
    try std.testing.expectEqual(@as(usize, 1), f.cancel_calls);
    f.wizard.show();
    f.wizard.cancel();
    try std.testing.expect(!f.wizard.isVisible());
    try std.testing.expectEqual(@as(usize, 2), f.cancel_calls);
}

test "SSH wizard review initially exposes identity row and modify returns without altering route" {
    var f: SaveFixture = undefined;
    try f.init(.ssh);
    defer f.deinit();
    for (0..4) |_| _ = f.cx.render();
    try std.testing.expectEqualStrings("target", f.wizard.summary_name.?.getText().?.content);
    try std.testing.expectEqualStrings("target.example:2222", f.wizard.summary_endpoint.?.getText().?.content);
    const edit = findId(f.wizard.root.?, "wizard.review.modify").?;
    try std.testing.expectEqual(f.wizard.summary_card.?, edit.parent);
    try std.testing.expect(std.mem.eql(u8, f.wizard.summary_values[4].?.getText().?.content, "严格验证已关闭"));
    SaveFixture.activate(edit);
    try std.testing.expectEqual(mod.Step.protocol, f.wizard.step);
    try std.testing.expectEqual(@as(usize, 1), f.wizard.currentDraft().route.len);
    try std.testing.expectEqualStrings("target", f.wizard.currentDraft().name);
    try std.testing.expectEqual(@as(usize, 0), f.calls);
}

fn feedbackFrames(f: *SaveFixture) void {
    for (0..8) |_| {
        f.cx.advanceFrameClock();
        f.cx.layout();
        _ = f.cx.render();
    }
}
fn selectWizardAuth(f: *SaveFixture, id: []const u8) !void {
    feedbackFrames(f);
    const option = findId(f.wizard.root.?, id) orelse return error.MissingAuthenticationPicker;
    f.cx.setFocus(option);
    f.cx.handleKeyDown(.@"return", .{});
    feedbackFrames(f);
    try std.testing.expect(option.behavior.interaction.a11y.?.checked.?);
}
fn replaceWizardInput(f: *SaveFixture, id: []const u8, value: []const u8) void {
    f.cx.setFocus(findId(f.wizard.root.?, id).?);
    f.cx.handleKeyDown(.a, .{ .super = true });
    f.cx.handleTextInput(value);
    feedbackFrames(f);
}

test "wizard blur validates only touched fields and correction clears native error without replacing raw input" {
    var f: SaveFixture = undefined;
    try f.init(.ssh);
    defer f.deinit();
    f.wizard.loadDraft(.{});
    f.wizard.show();
    feedbackFrames(&f);
    for ([_][]const u8{ "wizard.name.error", "wizard.host.error", "wizard.user.error", "wizard.port.error" }) |id_| {
        const error_ = findId(f.wizard.root.?, id_).?;
        try std.testing.expectEqual(@as(@TypeOf(error_.style.display), .none), error_.style.display);
    }
    f.cx.setFocus(findId(f.wizard.root.?, "wizard.name").?);
    f.cx.setFocus(findId(f.wizard.root.?, "wizard.host").?);
    feedbackFrames(&f);
    const name_error = findId(f.wizard.root.?, "wizard.name.error").?;
    try std.testing.expectEqualStrings("请输入主机名称。", name_error.getText().?.content);
    try std.testing.expect(findId(f.wizard.root.?, "wizard.name").?.behavior.interaction.a11y.?.invalid);
    try std.testing.expectEqual(ui.icons.circle_alert.icon_id.?, f.wizard.step_checks[0].?.getIcon().?.icon_id);
    try std.testing.expectEqual(@as(@TypeOf(name_error.style.display), .flex), name_error.style.display);
    const untouched_user = findId(f.wizard.root.?, "wizard.user.error").?;
    try std.testing.expectEqual(@as(@TypeOf(untouched_user.style.display), .none), untouched_user.style.display);
    replaceWizardInput(&f, "wizard.name", "fixed-name");
    try std.testing.expectEqual(@as(@TypeOf(name_error.style.display), .none), name_error.style.display);
    try std.testing.expect(!findId(f.wizard.root.?, "wizard.name").?.behavior.interaction.a11y.?.invalid);
    try std.testing.expectEqual(ui.icons.circle_alert.icon_id.?, f.wizard.step_checks[0].?.getIcon().?.icon_id);
    for ([_][]const u8{ "0", "65536", "+22", "abc" }) |raw| {
        replaceWizardInput(&f, "wizard.port", raw);
        f.cx.setFocus(findId(f.wizard.root.?, "wizard.user").?);
        feedbackFrames(&f);
        try std.testing.expectEqualStrings(raw, f.wizard.sig_port.?.get());
        try std.testing.expectEqualStrings("请输入 1–65535 的整数。", findId(f.wizard.root.?, "wizard.port.error").?.getText().?.content);
        try std.testing.expect(f.wizard.next1_disabled.?.get());
    }
    replaceWizardInput(&f, "wizard.port", "65535");
    replaceWizardInput(&f, "wizard.host", "127.0.0.1");
    replaceWizardInput(&f, "wizard.user", "fixture");
    try std.testing.expectEqual(ui.icons.check.icon_id.?, f.wizard.step_checks[0].?.getIcon().?.icon_id);
    try std.testing.expectEqual(@as(@TypeOf(name_error.style.display), .none), findId(f.wizard.root.?, "wizard.port.error").?.style.display);
    try std.testing.expectEqual(@as(usize, 0), f.calls);
}

test "wizard Enter exposes concrete required errors and private key feedback follows authentication mode" {
    var f: SaveFixture = undefined;
    try f.init(.ssh);
    defer f.deinit();
    f.wizard.loadDraft(.{});
    f.wizard.show();
    feedbackFrames(&f);
    f.cx.setFocus(findId(f.wizard.root.?, "wizard.name").?);
    f.cx.handleKeyDown(.@"return", .{});
    feedbackFrames(&f);
    try std.testing.expectEqual(mod.Step.protocol, f.wizard.step);
    try std.testing.expectEqualStrings("请输入主机地址。", findId(f.wizard.root.?, "wizard.host.error").?.getText().?.content);
    try std.testing.expectEqualStrings("请输入登录用户。", findId(f.wizard.root.?, "wizard.user.error").?.getText().?.content);
    try std.testing.expect(f.cx.isFocused(findId(f.wizard.root.?, "wizard.name").?));
    try std.testing.expectEqual(ui.icons.circle_alert.icon_id.?, f.wizard.step_checks[0].?.getIcon().?.icon_id);
    try std.testing.expectEqual(@as(@TypeOf(f.wizard.step_checks[0].?.style.display), .flex), f.wizard.step_checks[0].?.style.display);
    replaceWizardInput(&f, "wizard.name", "valid");
    replaceWizardInput(&f, "wizard.host", "127.0.0.1");
    replaceWizardInput(&f, "wizard.user", "fixture");
    try selectWizardAuth(&f, "wizard.auth.key");
    replaceWizardInput(&f, "wizard.key_passphrase", "temporary-key-passphrase");
    try std.testing.expectEqualStrings("temporary-key-passphrase", f.wizard.currentDraft().key_passphrase.?);
    f.cx.setFocus(findId(f.wizard.root.?, "wizard.key_path").?);
    f.cx.setFocus(findId(f.wizard.root.?, "wizard.name").?);
    feedbackFrames(&f);
    const key_error = findId(f.wizard.root.?, "wizard.key_path.error").?;
    try std.testing.expectEqualStrings("请选择或输入私钥文件。", key_error.getText().?.content);
    try selectWizardAuth(&f, "wizard.auth.password");
    feedbackFrames(&f);
    try std.testing.expectEqual(@as(@TypeOf(key_error.style.display), .none), key_error.style.display);
    try std.testing.expect(!f.wizard.next1_disabled.?.get());
    try std.testing.expect(f.wizard.currentDraft().password == null);
    f.cx.setFocus(findId(f.wizard.root.?, "wizard.user").?);
    f.cx.handleKeyDown(.@"return", .{});
    try std.testing.expectEqual(mod.Step.form, f.wizard.step);
    f.wizard.loadDraft(.{});
    f.wizard.show();
    feedbackFrames(&f);
    try std.testing.expectEqual(@as(@TypeOf(key_error.style.display), .none), findId(f.wizard.root.?, "wizard.name.error").?.style.display);
}

test "wizard encoding capability rejects unsupported values instead of silently dropping them on save" {
    var draft: mod.Draft = .{ .name = "target", .host = "example", .user = "ops", .encoding = "GB18030" };
    try std.testing.expectError(error.UnsupportedEncoding, draft.toHostConfig());
    draft.encoding = "UTF-8";
    const saved = try draft.toHostConfig();
    try std.testing.expectEqualStrings("UTF-8", mod.Draft.fromHost(saved).encoding);
    var f: SaveFixture = undefined;
    try f.init(.ssh);
    defer f.deinit();
    var found = false;
    for (f.wizard.inputs.items) |input| {
        const id = input.input_container.meta.ownership.meta.test_id orelse continue;
        if (!std.mem.eql(u8, id, "wizard.encoding")) continue;
        found = true;
        try std.testing.expect(input.state.readonly);
    }
    try std.testing.expect(found);
}

test "wizard explicit password persistence writes a credential reference and rehydrates on edit" {
    for ([_]mod.Protocol{ .ssh, .sftp }) |protocol| {
        var f: SaveFixture = undefined;
        try f.init(protocol);
        defer f.deinit();
        f.wizard.loadDraft(.{ .name = "remembered", .host = "secret.example", .user = "ops", .protocol = protocol, .password = "wizard-test-password" });
        f.wizard.show();
        try std.testing.expect(f.wizard.currentDraft().save_password);
        SaveFixture.activate(f.wizard.next1_btn.?);
        SaveFixture.activate(f.wizard.next2_btn.?);
        SaveFixture.activate(f.wizard.save_only_btn.?);
        try std.testing.expectEqual(@as(usize, 1), f.commits);
        const saved = f.registry.hosts[f.registry.hosts.len - 1];
        try std.testing.expect(saved.password_ref != null);
        const encoded = try f.tmp.dir.readFileAlloc(std.testing.io, f.path, a, .limited(store.max_config_bytes));
        defer a.free(encoded);
        try std.testing.expect(std.mem.indexOf(u8, encoded, "wizard-test-password") == null);
        try std.testing.expect(std.mem.indexOf(u8, encoded, "password_ref") != null);
        var loaded = try store.loadHosts(std.testing.io, f.tmp.dir, a, f.path);
        defer loaded.deinit();
        const restored = loaded.hosts[loaded.hosts.len - 1];
        try std.testing.expectEqualStrings("wizard-test-password", restored.password.?);
        f.wizard.loadDraft(mod.Draft.fromHost(restored));
        try std.testing.expect(f.wizard.currentDraft().save_password);
        try std.testing.expectEqualStrings("wizard-test-password", f.wizard.currentDraft().password.?);
        // Turning off persistence removes the ref while retaining the current
        // draft password for the one-shot connection path.
        SaveFixture.activate(findId(f.wizard.root.?, "wizard.password.remember").?);
        try std.testing.expect(f.wizard.currentDraft().password != null);
        SaveFixture.activate(f.wizard.next1_btn.?);
        SaveFixture.activate(f.wizard.next2_btn.?);
        SaveFixture.activate(f.wizard.save_only_btn.?);
        try std.testing.expect(f.registry.hosts[f.registry.hosts.len - 1].password_ref == null);
    }
}

test "wizard unchecked and cancelled passwords never enter credential storage" {
    var f: SaveFixture = undefined;
    try f.init(.ssh);
    defer f.deinit();
    f.wizard.loadDraft(.{ .name = "one-shot", .host = "secret.example", .user = "ops", .password = "never-persist-this", .save_password = false });
    f.wizard.show();
    try std.testing.expect(!f.wizard.currentDraft().save_password);
    try std.testing.expectEqualStrings("never-persist-this", (try f.wizard.currentDraft().toHostConfig()).password.?);
    SaveFixture.activate(f.wizard.next1_btn.?);
    SaveFixture.activate(f.wizard.next2_btn.?);
    SaveFixture.activate(f.wizard.save_only_btn.?);
    const saved = f.registry.hosts[f.registry.hosts.len - 1];
    try std.testing.expect(saved.password == null and saved.password_ref == null);
    const commits = f.commits;
    f.wizard.loadDraft(.{ .name = "cancelled", .host = "secret.example", .user = "ops", .password = "cancel-this", .save_password = true });
    f.wizard.show();
    f.wizard.cancel();
    try std.testing.expectEqual(commits, f.commits);
}

test "wizard credential storage failure keeps the draft visible without save success" {
    var f: SaveFixture = undefined;
    try f.init(.ssh);
    defer f.deinit();
    var memory: store.credentials.MemoryBackend = .{ .fail_add_after = 0 };
    defer memory.deinit();
    const previous = store.credentials.useBackendForTesting(memory.backend());
    defer store.credentials.restoreBackendForTesting(previous);
    f.wizard.loadDraft(.{ .name = "denied", .host = "secret.example", .user = "ops", .password = "not-in-error-text", .save_password = true });
    f.wizard.show();
    SaveFixture.activate(f.wizard.next1_btn.?);
    SaveFixture.activate(f.wizard.next2_btn.?);
    SaveFixture.activate(f.wizard.save_only_btn.?);
    try std.testing.expectEqual(@as(usize, 0), f.commits);
    try std.testing.expect(f.wizard.isVisible());
    try std.testing.expectEqual(error.CredentialStorageFailure, f.wizard.save_failure.?.cause);
    const message = f.wizard.save_error_node.?.getText().?.content;
    try std.testing.expect(std.mem.indexOf(u8, message, "系统钥匙串") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "not-in-error-text") == null);
    try std.testing.expectEqualStrings("not-in-error-text", f.wizard.currentDraft().password.?);
    try std.testing.expectEqual(@as(usize, 1), f.registry.hosts.len);
}

test "wizard V3 group select retains registry empty groups and replaced snapshot strings" {
    var f: SaveFixture = undefined;
    try f.init(.ssh);
    defer f.deinit();
    const name = try a.dupe(u8, "Empty group");
    try f.wizard.setGroups(&.{ name, name });
    a.free(name);
    try f.wizard.setGroups(&.{"Empty group"});
    try std.testing.expectEqual(@as(usize, 2), f.wizard.group_options.?.peek().len);
    f.wizard.loadDraft(.{ .name = "target", .host = "target.example", .user = "ops" });
    f.wizard.show();
    feedbackFrames(&f);
    const group = findId(f.wizard.root.?, "wizard.group.pick").?;
    f.cx.setFocus(group);
    f.cx.handleKeyDown(.down, .{});
    feedbackFrames(&f);
    f.cx.handleKeyDown(.end, .{});
    f.cx.handleKeyDown(.@"return", .{});
    feedbackFrames(&f);
    try std.testing.expectEqualStrings("Empty group", f.wizard.currentDraft().group.?);
    try f.wizard.setGroups(&.{});
    try std.testing.expectEqualStrings("Empty group", f.wizard.currentDraft().group.?);
    var grouped = f.assets;
    grouped[0].group = "Empty group";
    try f.wizard.setAssets(&grouped);
    f.wizard.loadDraft(.{ .source_owner = grouped[0].source_owner, .name = "envelope", .host = "target.example", .user = "ops" });
    try std.testing.expectEqualStrings("Empty group", f.wizard.currentDraft().group.?);
    feedbackFrames(&f);
    f.cx.setFocus(group);
    f.cx.handleKeyDown(.down, .{});
    feedbackFrames(&f);
    f.cx.handleKeyDown(.home, .{});
    f.cx.handleKeyDown(.@"return", .{});
    feedbackFrames(&f);
    try std.testing.expect(f.wizard.currentDraft().group == null);
    try f.wizard.setAssets(&grouped);
    try std.testing.expect(f.wizard.currentDraft().group == null);
}

test "wizard V3 multiline startup preserves order rejects overflow and remains hidden for SFTP" {
    var f: SaveFixture = undefined;
    try f.init(.ssh);
    defer f.deinit();
    f.wizard.loadDraft(.{ .name = "target", .host = "target.example", .user = "ops", .startup_commands = &.{ "cd /srv", "pwd" } });
    try std.testing.expectEqualStrings("cd /srv\npwd", f.wizard.sig_startup.?.peek());
    const area = f.wizard.startup_textarea.?;
    try std.testing.expect(area.input.behavior.interaction.a11y.?.multiline);
    try std.testing.expect(area.state.setAccessibilityValue("  echo first  \n\n echo second\n"));
    try std.testing.expectEqual(@as(usize, 2), f.wizard.currentDraft().startup_commands.len);
    try std.testing.expectEqualStrings("echo first", f.wizard.currentDraft().startup_commands[0]);
    try std.testing.expectEqualStrings("echo second", f.wizard.currentDraft().startup_commands[1]);
    var overflow: std.ArrayList(u8) = .empty;
    defer overflow.deinit(a);
    for (0..33) |_| try overflow.appendSlice(a, "echo overflow\n");
    try std.testing.expect(area.state.setAccessibilityValue(overflow.items));
    try std.testing.expect(f.wizard.next1_disabled.?.peek());
    try std.testing.expect(f.wizard.startup_error.?.peek().len != 0);
    try std.testing.expect(area.state.setAccessibilityValue("echo recovered"));
    try std.testing.expect(!f.wizard.next1_disabled.?.peek());
    try std.testing.expectEqual(@as(usize, 1), f.wizard.currentDraft().startup_commands.len);
    f.wizard.loadDraft(.{ .protocol = .sftp, .name = "files", .host = "target.example", .user = "ops" });
    try std.testing.expect(f.wizard.commands_details.?.style.display == .none);
}

test "wizard checkbox labels keep app contrast in light theme after real toggles" {
    const theme = @import("ui/app_theme.zig");
    const previous = theme.currentName();
    defer theme.select(previous);
    theme.select(.light);
    var f: SaveFixture = undefined;
    try f.init(.ssh);
    defer f.deinit();
    f.cx.setTheme(theme.widgetTheme(.light));
    f.wizard.show();
    feedbackFrames(&f);
    SaveFixture.activate(findId(f.wizard.root.?, "wizard.advanced.toggle").?);
    SaveFixture.activate(f.wizard.remember_checkbox.?);
    feedbackFrames(&f);
    try std.testing.expectEqual(theme.current().fg_1, findText(f.wizard.remember_checkbox.?, "保存密码").?.getText().?.color);
    for ([_][]const u8{ "disabled", "enabled" }) |suffix| {
        const id = try std.fmt.allocPrint(a, "wizard.compression.{s}", .{suffix});
        defer a.free(id);
        const choice = findId(f.wizard.root.?, id).?;
        SaveFixture.activate(choice);
        feedbackFrames(&f);
        try std.testing.expectEqual(theme.current().fg_1, findText(choice, if (std.mem.eql(u8, suffix, "enabled")) "开启" else "关闭").?.getText().?.color);
    }
}

test "wizard revised browser field typography and advanced host policy geometry" {
    var f: SaveFixture = undefined;
    try f.init(.ssh);
    defer f.deinit();
    f.wizard.show();
    SaveFixture.activate(findId(f.wizard.root.?, "wizard.advanced.toggle").?);
    feedbackFrames(&f);
    const name = findId(f.wizard.root.?, "wizard.name").?;
    try std.testing.expectApproxEqAbs(@as(f32, 34), name.globalRect().h, 0.01);
    try std.testing.expectEqual(@as(f32, 11), name.style.padding.left);
    try std.testing.expectEqual(@as(f32, 6), name.style.padding.top);
    try std.testing.expectEqual(@as(f32, 1), name.style.border.width);
    for (f.wizard.field_feedback.items) |feedback| if (feedback.input.input_container == name) {
        try std.testing.expectEqual(@as(f32, 11), feedback.input.state.font_size);
        try std.testing.expectEqual(@as(f32, 16), feedback.input.state.line_height);
        try std.testing.expectEqual(@as(f32, 11), feedback.input.state.text_display_node.?.getText().?.font_size);
        try std.testing.expectApproxEqAbs(@as(f32, 55.5), feedback.group.globalRect().h, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 16.5), feedback.group.children.items[0].globalRect().h, 0.01);
        try std.testing.expectEqual(@as(f32, 5), feedback.group.style.gap);
    };
    const body = f.wizard.advanced_body.?.globalRect();
    const summary = findId(f.wizard.root.?, "wizard.advanced.toggle").?.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 379.5), body.h, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 18), summary.h, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 12), body.y - summary.y - summary.h, 0.01);
    const timeout = f.wizard.connect_timeout_fact.?;
    try std.testing.expectEqual(@as(f32, 12), timeout.getText().?.font_size);
    try std.testing.expectEqual(@as(f32, 1.5), timeout.getText().?.line_height);
    // The form reserves 40px on the right for scrollbar chrome (24px on the left).
    try std.testing.expectApproxEqAbs(@as(f32, (760 - 24 - 40 - 16) / 2), timeout.parent.?.globalRect().w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 34), timeout.parent.?.globalRect().h, 0.01);
    const area = f.wizard.startup_textarea.?;
    try std.testing.expectEqual(@as(f32, 12), area.state.font_size);
    try std.testing.expectEqual(@as(f32, 18), area.state.line_height);
    try std.testing.expectEqual(@as(f32, 11), area.state.padding_h);
    try std.testing.expectEqual(@as(f32, 9), area.state.padding_v);
    try std.testing.expectApproxEqAbs(@as(f32, 80), area.input.globalRect().h, 0.01);
}

test "wizard route choices disable identities selected by other hops" {
    var f: SaveFixture = undefined;
    try f.init(.ssh);
    defer f.deinit();
    var second = f.assets[0];
    second.name = "second jump";
    second.source_owner = .{ .id = @fromBackingInt(42), .revision = 1 };
    const assets = [_]mod.Draft{ f.assets[0], second };
    try f.wizard.setAssets(&assets);
    f.wizard.loadDraft(.{ .name = "target", .host = "target.example", .user = "ops", .route = &.{ @fromBackingInt(41), @fromBackingInt(42) } });
    feedbackFrames(&f);
    const first_options = f.wizard.jump_options[0].?.peek();
    const second_options = f.wizard.jump_options[1].?.peek();
    try std.testing.expect(!first_options[0].disabled and first_options[1].disabled);
    try std.testing.expect(second_options[0].disabled and !second_options[1].disabled);
    try std.testing.expect(f.wizard.jump_add_disabled.?.peek());
    SaveFixture.activate(findId(f.wizard.root.?, "wizard.route.remove.1").?);
    feedbackFrames(&f);
    try std.testing.expect(!f.wizard.jump_add_disabled.?.peek());
    try std.testing.expect(!f.wizard.jump_options[0].?.peek()[1].disabled);
}

test "wizard access mode restores a loaded route without changing its saved identity" {
    var f: SaveFixture = undefined;
    try f.init(.ssh);
    defer f.deinit();
    const route_id = f.wizard.currentDraft().route[0];
    SaveFixture.activate(findId(f.wizard.root.?, "wizard.access.direct").?);
    try std.testing.expectEqual(@as(usize, 0), f.wizard.currentDraft().route.len);
    SaveFixture.activate(findId(f.wizard.root.?, "wizard.access.jump").?);
    try std.testing.expectEqual(@as(usize, 1), f.wizard.currentDraft().route.len);
    try std.testing.expectEqual(route_id, f.wizard.currentDraft().route[0]);
    try std.testing.expect(f.wizard.canSave());
}

test "copy saved host retains credential references route and all persistent attributes" {
    var memory: store.credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = store.credentials.useBackendForTesting(memory.backend());
    defer store.credentials.restoreBackendForTesting(previous);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var initial = try hosts.Registry.parse(a, "[[hosts]]\nname=\"jump\";host=\"jump.test\";user=\"ops\"\n[[hosts]]\nname=\"original\";host=\"target.test\";user=\"root\"\nauth={password=\"saved-password\"}\njump_chain=[\"jump\"];startup_commands=[\"cd /srv\"];scrollback=20000;compression=true;keepalive=false\n");
    defer initial.deinit();
    try store.saveHosts(std.testing.io, tmp.dir, "hosts.toml", initial);
    var live = try store.loadHosts(std.testing.io, tmp.dir, a, "hosts.toml");
    defer live.deinit();
    const owner = try live.duplicate(live.hosts[1].owner(), "copy");
    const source = live.hosts[1];
    try store.saveHosts(std.testing.io, tmp.dir, "hosts.toml", live);
    var reopened = try store.loadHosts(std.testing.io, tmp.dir, a, "hosts.toml");
    defer reopened.deinit();
    const copy = try reopened.get(owner);
    try std.testing.expectEqualStrings("saved-password", copy.password.?);
    try std.testing.expect(copy.password_ref != null);
    try std.testing.expectEqualSlices(hosts.identity.ConnectionId, source.route, copy.route);
    try std.testing.expectEqualStrings(source.startup_commands[0], copy.startup_commands[0]);
    try std.testing.expectEqual(source.scrollback, copy.scrollback);
    try std.testing.expectEqual(source.compression, copy.compression);
    try std.testing.expectEqual(source.keepalive, copy.keepalive);
    var edited = reopened.hosts[1];
    edited.password = "replacement-password";
    _ = try reopened.update(edited.owner(), edited);
    try store.saveHosts(std.testing.io, tmp.dir, "hosts.toml", reopened);
    var after_edit = try store.loadHosts(std.testing.io, tmp.dir, a, "hosts.toml");
    defer after_edit.deinit();
    try std.testing.expectEqualStrings("saved-password", (try after_edit.get(owner)).password.?);
    try after_edit.remove(after_edit.hosts[1].owner());
    try store.saveHosts(std.testing.io, tmp.dir, "hosts.toml", after_edit);
    var after_delete = try store.loadHosts(std.testing.io, tmp.dir, a, "hosts.toml");
    defer after_delete.deinit();
    try std.testing.expectEqualStrings("saved-password", (try after_delete.get(owner)).password.?);
}

test "command info host override shares advanced row and survives saving" {
    var f: SaveFixture = undefined;
    try f.init(.ssh);
    defer f.deinit();
    try std.testing.expect(f.wizard.currentDraft().command_info == null);
    f.wizard.sig_command_info.?.set("off");
    try std.testing.expectEqual(@as(?bool, false), f.wizard.currentDraft().command_info);
    f.clickSave();
    var saved = try store.loadHosts(std.testing.io, f.tmp.dir, a, "hosts.toml");
    defer saved.deinit();
    const value = try saved.get(f.wizard.source_owner.?);
    try std.testing.expectEqual(@as(?bool, false), value.command_info);
    f.wizard.loadDraft(mod.Draft.fromHost(value));
    try std.testing.expectEqualStrings("off", f.wizard.sig_command_info.?.get().?);
    f.wizard.sig_command_info.?.set("on");
    try std.testing.expectEqual(@as(?bool, true), f.wizard.currentDraft().command_info);
    f.wizard.sig_command_info.?.set("inherit");
    try std.testing.expect(f.wizard.currentDraft().command_info == null);
    f.wizard.show();
    SaveFixture.activate(findId(f.wizard.root.?, "wizard.advanced.toggle").?);
    feedbackFrames(&f);
    const info = findId(f.wizard.root.?, "wizard.command_info").?.globalRect();
    const shell = findId(f.wizard.root.?, "wizard.shell_integration").?.globalRect();
    try std.testing.expectApproxEqAbs(info.y, shell.y, 0.1);
    try std.testing.expectApproxEqAbs(info.h, shell.h, 0.1);
    try std.testing.expectApproxEqAbs(info.w, shell.w, 0.1);
    try std.testing.expect(info.w > 250 and info.w < 400);
    try std.testing.expect(shell.x >= info.x + info.w + 15);
    try std.testing.expect(findId(f.wizard.root.?, "wizard.command_info.help") != null);
    try std.testing.expect(findId(f.wizard.root.?, "wizard.shell_integration.help") != null);
}
