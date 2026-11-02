//! BMC editor persistence, ordering, asynchronous-result and UI action bounds.
//! Credentials use the in-memory backend; no BMC or user assets are accessed.
const std = @import("std");
const ui = @import("ui");
const drafts = @import("plugins/bmc_ikvm/editor_model.zig");
const editor = @import("plugins/bmc_ikvm/editor.zig");
const model = @import("plugins/bmc_ikvm/model.zig");
const codec = @import("plugins/bmc_ikvm/codec.zig");
const hosts = @import("config/hosts.zig");
const envelopes = @import("config/connection_envelope.zig");
const configs = @import("host/connection_config_resolver.zig");
const identity = @import("host/identity.zig");
const contract = @import("host/plugin_ui_contract.zig");
const probes = @import("host/probe_contract.zig");
const credentials = @import("config/credential_store.zig");
const editor_credentials = @import("host/editor_credentials.zig");
const secrets = @import("host/secret_lease.zig");
const a = std.testing.allocator;

fn validDraft() !drafts.Editor {
    var draft = drafts.Editor.init(a, 1);
    errdefer draft.deinit();
    try draft.setText(.name, "BMC fixture");
    try draft.setText(.host, "bmc.example.invalid");
    try draft.setText(.username, "operator");
    return draft;
}
fn freeEnvelope(value: envelopes.Envelope) void {
    a.free(value.protocol_id);
    a.free(value.name);
    a.free(value.payload);
}
fn operation(owner: identity.SessionHandle, id: u64) @import("host/operation.zig").OperationKey {
    return .{ .owner = .{ .session = owner }, .operation_id = id, .attempt_id = 1 };
}
fn token(revision: u64, id: u64) probes.ProbeToken {
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(id), .generation = 1 };
    return .{ .handle = owner, .operation = operation(owner, id), .parent_editor_operation = .{ .owner = .app, .operation_id = 99 }, .draft_revision = revision };
}

test "BMC editor snapshot and codec preserve public identity but never serialize editor or SSH secrets" {
    var registry = try hosts.Registry.parse(a, "");
    defer registry.deinit();
    const one = try registry.add(.{ .name = "first", .host = "first.invalid", .user = "ssh-user", .password = "ssh-secret" });
    const two = try registry.add(.{ .name = "second", .host = "second.invalid", .user = "ssh-user" });
    const nested = try registry.add(.{ .name = "nested", .host = "nested.invalid", .user = "ssh-user" });
    registry.hosts[0].route = &.{nested.id};
    const group = try registry.addGroup("Fixture group", "blue");
    var draft = try validDraft();
    defer draft.deinit();
    draft.asset_id = @fromBackingInt(81);
    draft.asset_revision = 7;
    try draft.setGroup(group);
    try draft.setPassword("bmc-secret-not-json");
    try draft.addHop(one.id);
    try draft.addHop(two.id);
    try draft.setScale(.original);
    try draft.setReadOnly(true);
    try draft.validateOffline(configs.Resolver.init(&registry), a);
    const value = try draft.snapshot(a);
    defer freeEnvelope(value);
    try std.testing.expectEqual(@as(u64, 81), @backingInt(value.id));
    try std.testing.expectEqual(@as(u64, 7), value.revision);
    try std.testing.expectEqual(group, value.group_id.?);
    for ([_][]const u8{ "bmc-secret-not-json", "ssh-secret", "password", "nested.invalid", "local_port", "profile", "Header" }) |secret| try std.testing.expect(std.mem.indexOf(u8, value.payload, secret) == null);
    var parsed = try model.parse(a, value.payload);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, @backingInt(one.id)), parsed.value().access.ssh_route.hops[0].asset_id);
    try std.testing.expectEqual(@as(u64, @backingInt(two.id)), parsed.value().access.ssh_route.hops[1].asset_id);
    var frozen = try model.freezeRoute(parsed.value(), configs.Resolver.init(&registry), a);
    defer frozen.deinit();
    try std.testing.expectEqual(@as(usize, 2), frozen.hops.len);
    try std.testing.expectEqual(@as(usize, 0), frozen.hops[0].nonsecret_config.route.len);
    try std.testing.expect(frozen.hops[0].nonsecret_config.password == null);
    const encoded = try codec.encode(a, value);
    defer freeEnvelope(encoded);
    var loaded = drafts.Editor.init(a, 52);
    defer loaded.deinit();
    try loaded.load(encoded);
    try std.testing.expectEqual(@as(u64, 52), loaded.revision);
    try std.testing.expectEqual(@as(usize, 0), loaded.password.len);
    try std.testing.expectEqual(model.Scale.original, loaded.scale);
    try std.testing.expect(loaded.read_only_requested);
    try std.testing.expectEqual(@as(usize, 2), loaded.route_count);
}

test "BMC editor route is explicit ordered at most eight SSH assets and offline validation needs no password" {
    var registry = try hosts.Registry.parse(a, "");
    defer registry.deinit();
    var ids: [9]identity.ConnectionId = undefined;
    for (0..9) |i| {
        var name: [30]u8 = undefined;
        var host: [40]u8 = undefined;
        ids[i] = (try registry.add(.{ .name = try std.fmt.bufPrint(&name, "hop{d}", .{i}), .host = try std.fmt.bufPrint(&host, "hop{d}.invalid", .{i}), .user = "operator", .auth_mode = .password })).id;
    }
    var draft = try validDraft();
    defer draft.deinit();
    for (ids[0..8]) |id| try draft.addHop(id);
    try std.testing.expectError(error.TooManyJumps, draft.addHop(ids[8]));
    try std.testing.expectError(error.DuplicateRoute, draft.replaceHop(0, ids[1]));
    try draft.moveHop(1, true);
    try std.testing.expectEqual(@backingInt(ids[1]), draft.route[0].asset_id);
    try draft.removeHop(1);
    try std.testing.expectEqual(@as(usize, 7), draft.route_count);
    try draft.validateOffline(configs.Resolver.init(&registry), a);
    const before = draft.revision;
    try std.testing.expect(!try draft.applyChild(before - 1, ids[8], configs.Resolver.init(&registry)));
    try std.testing.expectEqual(before, draft.revision);
    try std.testing.expect(try draft.applyChild(before, ids[8], configs.Resolver.init(&registry)));
    try draft.setAccess(false);
    const direct = try draft.snapshot(a);
    defer freeEnvelope(direct);
    var direct_payload = try model.parse(a, direct.payload);
    defer direct_payload.deinit();
    try std.testing.expect(direct_payload.value().access == .direct);
    try std.testing.expectEqual(@as(usize, 8), draft.route_count);
    try draft.setAccess(true);
    const sftp = try registry.add(.{ .name = "files", .host = "files.invalid", .user = "operator", .protocol = .sftp });
    try draft.replaceHop(0, sftp.id);
    try std.testing.expectError(error.ProtocolMismatch, draft.validateOffline(configs.Resolver.init(&registry), a));
    try draft.replaceHop(0, @fromBackingInt(9000));
    try std.testing.expectError(error.MissingRouteReference, draft.validateOffline(configs.Resolver.init(&registry), a));
}

test "BMC editor probe publishes only matching current drafts after cleanup and suppresses cancelled late success" {
    var state: drafts.ProbeState = .{};
    const first = token(12, 201);
    try state.begin(first);
    var update: probes.ProbeSnapshot = .{ .token = first, .stage = .cleanup, .outcome = .succeeded, .cleanup = .awaiting, .safe_message = "fixture", .applies_to_draft = true, .complete = false };
    try std.testing.expect(state.apply(update, 12));
    try std.testing.expect(state.outcome == null);
    var unrelated = update;
    unrelated.token = token(12, 202);
    try std.testing.expect(!state.apply(unrelated, 12));
    state.invalidate();
    update.complete = true;
    update.cleanup = .released;
    try std.testing.expect(!state.apply(update, 13));
    try std.testing.expect(state.token == null and state.outcome == null);
    try state.begin(token(13, 203));
    state.cancel();
    update.token = token(13, 203);
    try std.testing.expect(!state.apply(update, 13));
    try std.testing.expect(state.token == null and state.outcome == null);
    try state.begin(token(13, 204));
    update.token = token(13, 204);
    try std.testing.expect(state.apply(update, 13));
    try std.testing.expectEqual(probes.Outcome.succeeded, state.outcome.?);
}

test "BMC editor probe log keeps only bounded static phases and does not turn old or cancelled results into success" {
    var log: drafts.ProbeLog = .{};
    const owner = token(12, 211);
    log.begin(owner);
    var update: probes.ProbeSnapshot = .{ .token = owner, .stage = .transport, .outcome = null, .cleanup = .awaiting, .safe_message = "TLS 握手 · 阶段 1 秒 · 总计 2 秒", .applies_to_draft = true, .complete = false };
    log.observe(update);
    const first_count = log.count;
    update.safe_message = "TLS 握手 · 阶段 9 秒 · 总计 10 秒";
    log.observe(update);
    try std.testing.expectEqual(first_count, log.count);
    try std.testing.expectEqual(@as(u64, 10), log.elapsed_seconds);
    update.safe_message = "读取公开设备身份 · 阶段 0 秒 · 总计 10 秒";
    log.observe(update);
    try std.testing.expectEqual(first_count + 1, log.count);
    update.safe_message = "fixture-password https://private.invalid/raw/device-body";
    update.stage = .authentication;
    log.observe(update);
    var buffer: [8192]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, log.format(&buffer), "fixture-password") == null);
    for (0..40) |i| {
        update.safe_message = if (i % 2 == 0) "WEB 登录 · 阶段 0 秒 · 总计 12 秒" else "Redfish 只读发现 · 阶段 0 秒 · 总计 13 秒";
        log.observe(update);
    }
    try std.testing.expectEqual(@as(usize, 32), log.count);
    update.cleanup = .unknown;
    log.observe(update);
    const unknown_revision = log.revision;
    for (0..4) |_| log.observe(update);
    try std.testing.expectEqual(unknown_revision, log.revision);
    var unrelated = update;
    unrelated.token = token(12, 212);
    unrelated.complete = true;
    unrelated.cleanup = .released;
    unrelated.outcome = .succeeded;
    log.observe(unrelated);
    try std.testing.expect(!log.complete);
    log.cancel();
    update.complete = true;
    update.cleanup = .released;
    update.outcome = .succeeded;
    update.safe_message = "TLS 握手失败 · SyntheticFailure · 总计 14 秒 · WEB 会话注销未确认";
    log.observe(update);
    try std.testing.expectEqual(@as(u64, 14), log.elapsed_seconds);
    try std.testing.expectEqual(probes.Outcome.cancelled, log.outcome.?);
    try std.testing.expect(std.mem.indexOf(u8, log.format(&buffer), "测试成功") == null);
    log.invalidate(13);
    try std.testing.expect(log.stale);
    log.begin(token(13, 213));
    try std.testing.expectEqual(@as(u64, 2), log.attempt);
    try std.testing.expectEqual(@as(usize, 1), log.count);
    try std.testing.expect(!log.stale and !log.complete);
    log.invalidate(14);
    update.token = token(13, 213);
    log.observe(update);
    try std.testing.expect(log.complete and log.outcome == null);
    try std.testing.expect(std.mem.indexOf(u8, log.format(&buffer), "上次草稿") != null);
}

test "BMC editor SSH inventory search covers more than sixty four assets and retains the selected reference" {
    var registry = try hosts.Registry.parse(a, "");
    defer registry.deinit();
    var last: identity.ConnectionId = @fromBackingInt(0);
    for (0..80) |i| {
        var name: [32]u8 = undefined;
        var address: [42]u8 = undefined;
        last = (try registry.add(.{ .name = try std.fmt.bufPrint(&name, "saved-ssh-{d}", .{i}), .host = try std.fmt.bufPrint(&address, "ssh-{d}.invalid", .{i}), .user = "operator" })).id;
    }
    const resolver = configs.Resolver.init(&registry);
    const first_page = try drafts.visibleSshAssets(resolver, "", last, a);
    defer a.free(first_page);
    try std.testing.expectEqual(@as(usize, 64), first_page.len);
    try std.testing.expectEqual(last, first_page[0]);
    const filtered = try drafts.visibleSshAssets(resolver, "SSH-79", null, a);
    defer a.free(filtered);
    try std.testing.expectEqual(@as(usize, 1), filtered.len);
    try std.testing.expectEqual(last, filtered[0]);
}

test "BMC editor temporary and probe names derive from endpoint without changing a saved draft or persistence validation" {
    var draft = try validDraft();
    defer draft.deinit();
    draft.asset_id = @fromBackingInt(66);
    try draft.setText(.name, "");
    try std.testing.expectError(error.MissingName, draft.validateOffline(null, a));
    try draft.validateRuntime(null, a);
    const temporary = try draft.snapshotRuntime(a, null);
    defer freeEnvelope(temporary);
    try std.testing.expectEqualStrings("bmc.example.invalid", temporary.name);
    try std.testing.expectEqual(@as(u64, 0), @backingInt(temporary.id));
    try std.testing.expectEqual(@as(u64, 66), @backingInt(draft.asset_id));
    try std.testing.expectEqualStrings("", draft.name);
    try std.testing.expectError(error.MissingName, draft.snapshot(a));
}

const Driver = struct {
    facade: editor_credentials.Facade,
    credential_host: *editor_credentials.Host,
    submissions: usize = 0,
    cancelled: usize = 0,
    last_intent: ?contract.SubmitIntent = null,
    fail_save: bool = false,
    last_reference: ?[68]u8 = null,
    fn changed(_: *anyopaque) void {}
    fn submit(_: *anyopaque, _: envelopes.Envelope, _: contract.SubmitIntent) !void {
        return error.UnsafeFallback;
    }
    fn submitSecret(raw: *anyopaque, value: envelopes.Envelope, intent: contract.SubmitIntent, handoff: editor_credentials.Handoff) !void {
        const self: *Driver = @ptrCast(@alignCast(raw));
        try self.facade.requireHandoff(handoff);
        self.submissions += 1;
        self.last_intent = intent;
        var parsed = try model.parse(a, value.payload);
        defer parsed.deinit();
        try std.testing.expect(std.mem.indexOf(u8, value.payload, "editor-sensitive") == null);
        self.last_reference = if (parsed.value().credential_ref) |ref| ref[0..68].* else null;
        if (self.fail_save) return error.AtomicSaveFailed;
        if (intent == .temporary) {
            try std.testing.expect(parsed.value().credential_ref == null);
            const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(802), .generation = 1 };
            try self.credential_host.authorizeHandoff(handoff, owner, operation(owner, 802));
            self.facade.rollback(handoff);
        } else try self.facade.commit(handoff);
    }
    fn cancel(raw: *anyopaque) void {
        const self: *Driver = @ptrCast(@alignCast(raw));
        self.cancelled += 1;
    }
};
fn find(node: *ui.Node, test_id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |id| if (std.mem.eql(u8, test_id, id)) return node;
    for (node.children.items) |child| if (find(child, test_id)) |match| return match;
    return null;
}
fn frames(cx: *ui.Cx) void {
    for (0..3) |_| {
        cx.advanceFrameClock();
        cx.requestRedraw();
        _ = cx.render();
    }
}
fn click(cx: *ui.Cx, node: *ui.Node) void {
    const rect = node.globalRect();
    cx.handleClick(rect.x + rect.w / 2, rect.y + rect.h / 2);
    cx.handleMouseUpEx(rect.x + rect.w / 2, rect.y + rect.h / 2, .left, .{});
}

test "BMC editor native actions defer submission and rollback failed saves while temporary and cancel preserve the draft" {
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    var secret_store = secrets.Store.init(a);
    defer secret_store.deinit();
    var credential_host = editor_credentials.Host.init(a, std.testing.io, &secret_store);
    defer credential_host.deinit();
    const facade = try credential_host.bindEditor(55, 1);
    var driver: Driver = .{ .facade = facade, .credential_host = &credential_host };
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setTheme(&ui.theme.dark);
    cx.setViewport(760, 710);
    try cx.setTestFrameStep(100);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    const instance = try editor.mountEditor(null, .{ .cx = cx, .scope = scope, .slot = cx.root.?, .protocol_id = model.protocol_id, .draft_revision = 1, .editor_id = 55, .credentials = facade, .events = .{ .context = &driver, .changed = Driver.changed, .submit = Driver.submit, .submit_with_secret = Driver.submitSecret, .cancelled = Driver.cancel } });
    const view: *editor.EditorView = @ptrCast(@alignCast(instance.context));
    try view.draft.?.setText(.name, "Fixture BMC");
    try view.draft.?.setText(.host, "fixture.invalid");
    try view.draft.?.setText(.username, "operator");
    try view.draft.?.setPassword("editor-sensitive");
    try facade.setDraftRevision(view.draft.?.revision);
    frames(cx);
    click(cx, find(cx.root.?, "bmc.editor.access.ssh").?);
    frames(cx);
    try std.testing.expect(find(cx.root.?, "bmc.editor.access.ssh.selected").?.isDisplayedInTree());
    click(cx, find(cx.root.?, "bmc.editor.access.direct").?);
    frames(cx);
    try std.testing.expect(!find(cx.root.?, "bmc.editor.access.ssh.selected").?.isDisplayedInTree());
    const save = find(cx.root.?, "bmc.editor.save").?;
    try std.testing.expect(save.isDisplayedInTree());
    driver.fail_save = true;
    click(cx, save);
    try std.testing.expectEqual(@as(usize, 0), driver.submissions);
    frames(cx);
    try std.testing.expectEqual(@as(usize, 1), driver.submissions);
    try std.testing.expectEqual(@as(usize, 0), memory.values.count());
    try std.testing.expectEqualStrings("editor-sensitive", view.draft.?.password);
    try std.testing.expect(find(cx.root.?, "bmc.editor.access.direct.selected").?.isDisplayedInTree());
    try std.testing.expectEqualStrings("fixture.invalid", view.draft.?.host);
    driver.fail_save = false;
    click(cx, find(cx.root.?, "bmc.editor.temporary").?);
    frames(cx);
    try std.testing.expectEqual(contract.SubmitIntent.temporary, driver.last_intent.?);
    try std.testing.expectEqual(@as(usize, 0), memory.values.count());
    try std.testing.expectEqual(@as(usize, 0), view.draft.?.password.len);
    try std.testing.expectEqualStrings("Fixture BMC", view.draft.?.name);
    click(cx, find(cx.root.?, "bmc.editor.cancel").?);
    frames(cx);
    try std.testing.expectEqual(@as(usize, 1), driver.cancelled);
    try std.testing.expectEqualStrings("fixture.invalid", view.draft.?.host);
    instance.vtable.unmount(instance.context);
}

test "BMC editor new saved password is opaque and successful save and open use distinct intents" {
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    var store = secrets.Store.init(a);
    defer store.deinit();
    var host = editor_credentials.Host.init(a, std.testing.io, &store);
    defer host.deinit();
    const facade = try host.bindEditor(56, 1);
    var draft = try validDraft();
    defer draft.deinit();
    try draft.setPassword("editor-sensitive");
    try facade.setDraftRevision(draft.revision);
    const staged = try facade.prepare(draft.password, null, true);
    const value = try draft.snapshotWithReference(a, if (staged.reference) |*ref| ref else null);
    defer freeEnvelope(value);
    var driver: Driver = .{ .facade = facade, .credential_host = &host };
    try Driver.submitSecret(&driver, value, .save_and_open, try facade.handoff(staged));
    try std.testing.expectEqual(contract.SubmitIntent.save_and_open, driver.last_intent.?);
    try std.testing.expectEqual(@as(usize, 1), memory.values.count());
    const saved_secret = try credentials.get(a, &driver.last_reference.?);
    defer a.free(saved_secret);
    try std.testing.expectEqualStrings("editor-sensitive", saved_secret);
    draft.clearSecrets();
    try std.testing.expectEqual(@as(usize, 0), draft.password.len);
    try std.testing.expectEqualStrings("bmc.example.invalid", draft.host);
}

const ProbeFixture = struct {
    revision: u64 = 1,
    begins: u64 = 0,
    cancels: u64 = 0,
    active: ?probes.ProbeToken = null,
    override_token: ?probes.ProbeToken = null,
    stage: probes.Stage = .transport,
    message: []const u8 = "TLS 握手 · 阶段 1 秒 · 总计 1 秒",
    complete: bool = false,
    outcome: ?probes.Outcome = null,
    cleanup: probes.CloseReceipt = .awaiting,
    fn facade(self: *ProbeFixture) probes.EditorProbes {
        return .{ .context = self, .ticket = @fromBackingInt(1), .editor_id = 57, .parent_editor_operation = token(1, 1).parent_editor_operation, .begin_fn = begin, .snapshot_fn = snapshot, .cancel_fn = cancel, .revision_fn = setRevision, .destroy_fn = destroy };
    }
    fn begin(raw: *anyopaque, _: probes.EditorTicket, _: envelopes.Envelope, revision: u64) !probes.ProbeToken {
        const self: *ProbeFixture = @ptrCast(@alignCast(raw));
        self.begins += 1;
        self.active = token(revision, 300 + self.begins);
        self.stage = .transport;
        self.message = "TLS 握手 · 阶段 1 秒 · 总计 1 秒";
        self.complete = false;
        self.outcome = null;
        self.cleanup = .awaiting;
        return self.active.?;
    }
    fn snapshot(raw: *anyopaque, _: probes.EditorTicket, owner: probes.ProbeToken, allocator: std.mem.Allocator) !probes.OwnedProbeSnapshot {
        const self: *ProbeFixture = @ptrCast(@alignCast(raw));
        try std.testing.expect(self.active.?.eql(owner));
        return probes.OwnedProbeSnapshot.init(allocator, .{ .token = self.override_token orelse owner, .stage = self.stage, .outcome = self.outcome, .cleanup = self.cleanup, .safe_message = self.message, .applies_to_draft = owner.draft_revision == self.revision, .complete = self.complete });
    }
    fn cancel(raw: *anyopaque, _: probes.EditorTicket, owner: probes.ProbeToken) !probes.CloseReceipt {
        const self: *ProbeFixture = @ptrCast(@alignCast(raw));
        try std.testing.expect(self.active.?.eql(owner));
        self.cancels += 1;
        return .awaiting;
    }
    fn setRevision(raw: *anyopaque, _: probes.EditorTicket, revision: u64) !void {
        const self: *ProbeFixture = @ptrCast(@alignCast(raw));
        self.revision = revision;
    }
    fn destroy(_: *anyopaque, _: probes.EditorTicket) void {}
    fn changed(_: *anyopaque) void {}
    fn submit(_: *anyopaque, _: envelopes.Envelope, _: contract.SubmitIntent) !void {
        return error.UnexpectedSubmission;
    }
};

test "BMC editor native probe feedback stays visible and log updates preserve cancel and draft ownership" {
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    var secret_store = secrets.Store.init(a);
    defer secret_store.deinit();
    var credential_host = editor_credentials.Host.init(a, std.testing.io, &secret_store);
    defer credential_host.deinit();
    const credential_facade = try credential_host.bindEditor(57, 1);
    var fixture: ProbeFixture = .{};
    var draft = try validDraft();
    defer draft.deinit();
    const initial = try draft.snapshot(a);
    defer freeEnvelope(initial);
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setTheme(&ui.theme.dark);
    cx.setViewport(860, 428);
    try cx.setTestFrameStep(100);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    const instance = try editor.mountEditor(null, .{ .cx = cx, .scope = scope, .slot = cx.root.?, .protocol_id = model.protocol_id, .initial = initial, .draft_revision = 1, .editor_id = 57, .credentials = credential_facade, .probes = fixture.facade(), .events = .{ .context = &fixture, .changed = ProbeFixture.changed, .submit = ProbeFixture.submit } });
    const view: *editor.EditorView = @ptrCast(@alignCast(instance.context));
    frames(cx);
    const root_before = view.root;
    const message_before = view.message;
    const footer = find(cx.root.?, "bmc.editor.footer").?;
    try std.testing.expectEqual(@as(usize, 6), footer.children.items.len); // five actions and spacer
    click(cx, find(cx.root.?, "bmc.editor.probe").?);
    try std.testing.expectEqual(@as(u64, 0), fixture.begins);
    frames(cx);
    try std.testing.expectEqual(@as(u64, 1), fixture.begins);
    try std.testing.expectEqualStrings(fixture.message, view.message.?.getText().?.content);
    const log_count = view.probe_log.count;
    fixture.message = "TLS 握手 · 阶段 5 秒 · 总计 5 秒";
    frames(cx);
    try std.testing.expectEqualStrings(fixture.message, view.message.?.getText().?.content);
    try std.testing.expectEqual(log_count, view.probe_log.count);
    const feedback_rect = find(cx.root.?, "bmc.editor.feedback").?.globalRect();
    try std.testing.expect(feedback_rect.y >= 0 and feedback_rect.y + feedback_rect.h <= footer.globalRect().y + 0.01);
    const cancel_rect = find(cx.root.?, "bmc.editor.probe").?.globalRect();
    try std.testing.expect(cancel_rect.y + cancel_rect.h <= 428);
    fixture.stage = .trust;
    fixture.message = "等待用户确认证书 · 阶段 0 秒 · 总计 6 秒";
    frames(cx);
    try std.testing.expectEqualStrings(fixture.message, view.message.?.getText().?.content);
    click(cx, find(cx.root.?, "bmc.editor.probe_log").?);
    frames(cx);
    try std.testing.expect(view.log_open.?.peek());
    fixture.stage = .authentication;
    fixture.message = "等待用户输入凭据 · 阶段 2 秒 · 总计 8 秒";
    frames(cx);
    try std.testing.expect(std.mem.indexOf(u8, view.log_entries.?.getText().?.content, "等待用户输入凭据") != null);
    try std.testing.expect(root_before == view.root and message_before == view.message);
    click(cx, find(cx.root.?, "bmc.editor.log_cancel_probe").?);
    frames(cx);
    try std.testing.expectEqual(@as(u64, 1), fixture.cancels);
    fixture.complete = true;
    fixture.cleanup = .released;
    fixture.outcome = .succeeded; // Deliberately late success after cancellation.
    frames(cx);
    try std.testing.expect(view.probe.token == null and view.probe.outcome == null);
    try std.testing.expectEqual(probes.Outcome.cancelled, view.probe_log.outcome.?);
    try std.testing.expect(std.mem.indexOf(u8, view.log_entries.?.getText().?.content, "测试成功") == null);
    try std.testing.expect(!view.probe_running.?.peek() and view.probe_log.count != 0);
    cx.handleKeyDown(.escape, .{});
    frames(cx);
    try std.testing.expect(!view.log_open.?.peek());
    const cancelled_token = fixture.active.?;
    click(cx, find(cx.root.?, "bmc.editor.probe").?);
    frames(cx);
    try std.testing.expectEqual(@as(u64, 2), view.probe_log.attempt);
    try std.testing.expect(std.mem.indexOf(u8, view.log_entries.?.getText().?.content, "已取消") == null);
    cx.setFocus(view.inputs[1].?.input_container);
    cx.handleTextInput("-changed");
    frames(cx);
    try std.testing.expect(view.probe_log.stale and view.probe.cancelled);
    fixture.override_token = cancelled_token;
    fixture.complete = true;
    fixture.cleanup = .released;
    fixture.outcome = .succeeded;
    frames(cx);
    try std.testing.expect(view.probe.token != null and !view.probe_log.complete);
    fixture.override_token = null;
    frames(cx);
    try std.testing.expect(view.probe.token == null and view.probe.outcome == null);
    try std.testing.expect(view.probe_log.complete and view.probe_log.outcome == null);
    try std.testing.expect(std.mem.indexOf(u8, view.log_status.?.getText().?.content, "旧草稿") != null);
    try std.testing.expect(std.mem.indexOf(u8, view.message.?.getText().?.content, "成功") == null);
    click(cx, find(cx.root.?, "bmc.editor.probe").?);
    frames(cx);
    try std.testing.expectEqual(@as(u64, 3), view.probe_log.attempt);
    try std.testing.expect(!view.probe_log.stale);
    fixture.complete = true;
    fixture.cleanup = .released;
    fixture.outcome = .failed;
    fixture.message = "FixtureAuthenticationFailed";
    frames(cx);
    try std.testing.expectEqual(probes.Outcome.failed, view.probe.outcome.?);
    try std.testing.expectEqualStrings("FixtureAuthenticationFailed", view.message.?.getText().?.content);
    try std.testing.expect(std.mem.indexOf(u8, view.log_entries.?.getText().?.content, "测试失败") != null);
    instance.vtable.unmount(instance.context);
}

test "BMC editor reopening a temporary session preserves configuration without persisting runtime credentials" {
    var source = try validDraft();
    defer source.deinit();
    try source.setPassword("temporary-password-not-saved");
    try source.setPort(8443);
    try source.setScale(.original);
    const reference = "zw1_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const temporary = try source.snapshotRuntime(a, reference);
    defer freeEnvelope(temporary);
    var draft = drafts.Editor.init(a, 1);
    defer draft.deinit();
    try draft.load(temporary);
    try std.testing.expectEqualStrings(source.host, draft.host);
    try std.testing.expectEqualStrings(source.username, draft.username);
    try std.testing.expectEqual(@as(u16, 8443), draft.https_port);
    try std.testing.expectEqual(model.Scale.original, draft.scale);
    try std.testing.expect(!draft.save_password);
    try std.testing.expect(draft.credential_ref == null);
    try std.testing.expectEqual(@as(usize, 0), draft.password.len);
    const saved = try draft.snapshot(a);
    defer freeEnvelope(saved);
    try std.testing.expect(std.mem.indexOf(u8, saved.payload, reference) == null);
    try std.testing.expect(std.mem.indexOf(u8, saved.payload, "temporary-password-not-saved") == null);
    var saved_asset = temporary;
    saved_asset.id = @fromBackingInt(87);
    var existing = drafts.Editor.init(a, 1);
    defer existing.deinit();
    try existing.load(saved_asset);
    try std.testing.expectEqualStrings(reference, existing.credential_ref.?);
    try std.testing.expect(existing.save_password);
}
