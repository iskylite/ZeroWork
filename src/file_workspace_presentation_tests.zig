//! Actual Workspace/ApplicationHost + Controller/View + real local_fs worker.
//! Remote startup is an explicit adapter-boundary snapshot behind a controlled
//! connector; these tests do not claim a successful network SFTP connection.
const std = @import("std");
const ui = @import("ui");
const Presentation = @import("ui/file_workspace_presentation.zig");
const Workspace = @import("ui/workspace.zig").Workspace;
const Application = @import("ui/application_host.zig");
const Config = @import("config/config.zig").Config;
const domain = @import("host/session_host.zig");
const identity = @import("host/identity.zig");
const operations = @import("host/operation.zig");
const adapters = @import("host/sftp_adapter.zig");
const bindings = @import("host/file_binding_host.zig");
const plugins = @import("host/plugin_registry.zig");
const ssh = @import("proto/ssh/session.zig");
const clock = @import("platform/realtime.zig");
const fs = Presentation.controller.fs;
const a = std.testing.allocator;
fn pause() void {
    var unused: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&unused, 0, 2);
}
const Adapter = struct {
    fn create(_: *anyopaque, _: domain.CreateRequest) !void {}
    fn cancel(_: *anyopaque, _: operations.OperationKey) domain.CloseReceipt {
        return .released;
    }
    fn close(_: *anyopaque, _: identity.SessionHandle, _: operations.OperationKey) !domain.CloseReceipt {
        return .released;
    }
    fn stale(_: *anyopaque, _: identity.SessionHandle, _: operations.OperationKey) void {}
    fn tick(_: *anyopaque, _: *domain.SessionHost) !bool {
        return false;
    }
    fn shutdown(_: *anyopaque) domain.CloseReceipt {
        return .released;
    }
    fn plugin(self: *Adapter) Application.FilePlugin {
        return .{ .adapter = .{ .registration = .{ .plugin_id = .sftp, .workspace_kind = .file, .services = plugins.requiredServices(.sftp) }, .context = self, .vtable = &.{ .create = create, .cancel = cancel, .close = close, .release_stale = stale } }, .context = self, .tick = tick, .shutdown = shutdown };
    }
};
const Gate = struct {
    prepare_count: usize = 0,
    last_source: ?bindings.Source = null,
    last_host: [256]u8 = @splat(0),
    last_host_len: usize = 0,
    release: std.atomic.Value(bool) = .init(false),
    fn prepare(raw: *anyopaque, source: bindings.Source) !bindings.readonly.Connector {
        const self: *Gate = @ptrCast(@alignCast(raw));
        self.prepare_count += 1;
        self.last_source = source;
        const host = source.spec.saved.immutable_config.endpoint.host;
        self.last_host_len = @min(host.len, self.last_host.len);
        @memcpy(self.last_host[0..self.last_host_len], host[0..self.last_host_len]);
        return .{ .key = source.open_key, .ctx = raw, .connect_fn = connect, .close_fn = close, .deinit_fn = destroy };
    }
    fn discard(_: *anyopaque, _: bindings.readonly.Connector) void {}
    fn connect(raw: *anyopaque, cancel: *const std.atomic.Value(bool)) !ssh.Session {
        const self: *Gate = @ptrCast(@alignCast(raw));
        const deadline = clock.monotonicNs() + 10 * std.time.ns_per_s;
        while (!self.release.load(.acquire) and !cancel.load(.acquire)) {
            if (clock.monotonicNs() > deadline) return error.TestTimeout;
            pause();
        }
        return error.ControlledConnectionFailure;
    }
    fn close(_: *anyopaque, _: ?*ssh.Session) ssh.ReleaseReceipt {
        return .released;
    }
    fn destroy(_: *anyopaque) void {}
    fn factory(self: *Gate) bindings.Factory {
        return .{ .context = self, .prepare = prepare, .discard = discard };
    }
};
const Fixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    workspace: *Workspace,
    app: *Application.ApplicationHost,
    config: Config = .{},
    tmp: std.testing.TmpDir,
    path: [:0]u8,
    hosts_path: [:0]u8,
    adapter: Adapter = .{},
    gate: Gate = .{},
    file_host: bindings.FileBindingHost,
    local_journal: operations.Journal,
    local: *fs.Service,
    presentation: *Presentation.Presentation,
    fn init(self: *Fixture) !void {
        self.* = .{ .cx = try ui.Cx.init(a, std.testing.io), .scope = undefined, .workspace = undefined, .app = undefined, .tmp = std.testing.tmpDir(.{}), .path = undefined, .hosts_path = undefined, .file_host = undefined, .local_journal = operations.Journal.init(a), .local = undefined, .presentation = undefined };
        self.path = try self.tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "hosts.toml", .data = "" });
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "presentation-local.txt", .data = "real local directory fixture" });
        self.hosts_path = try self.tmp.dir.realPathFileAlloc(std.testing.io, "hosts.toml", a);
        self.cx.setViewport(1194, 794);
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
        self.scope = try ui.Scope.init(a, null, self.cx.owner);
        var nodes: [4]*ui.Node = undefined;
        for (&nodes, 0..) |*node, i| {
            node.* = try ui.box(self.cx, .{ .width = .fill(), .height = if (i == 2) .fill() else .{ .px = 20 }, .min_height = 0 }, .{});
            try self.cx.root.?.appendChild(a, node.*);
        }
        self.workspace = try Workspace.init(a, self.cx, self.scope, std.testing.io, &self.config, self.hosts_path, nodes[0], nodes[1], nodes[2], nodes[3]);
        self.app = try Application.ApplicationHost.initWithFilePlugin(a, self.workspace, self.adapter.plugin());
        self.app.install();
        self.file_host = try bindings.FileBindingHost.init(a, self.app.sessions, self.gate.factory());
        self.local = try fs.Service.start(a, .{ .binding_id = 991, .binding_generation = 4 }, .{ .home = self.path });
        self.presentation = try Presentation.Presentation.init(a, .{ .app = self.app, .file_host = &self.file_host, .local = .{ .service = self.local, .journal = &self.local_journal, .endpoint = self.local.endpoint, .initial_path = self.path, .labels = .{ .title = "本机真实目录" } } });
    }
    fn source(self: *Fixture, id: u64, failure: bool) !adapters.Presentation {
        const accepted = try self.app.create(.{ .connection_id = @fromBackingInt(id), .revision = 2, .protocol = .sftp, .name = "Original Files", .host = "presentation-fixture.invalid", .user = "fixture", .password = "fixture-only" }, id, 0, "");
        const directory = try self.app.sessions.reserveService(accepted.handle, accepted.operation, .directory);
        const file_read = try self.app.sessions.reserveService(accepted.handle, accepted.operation, .file_read);
        const transfer = try self.app.sessions.reserveService(accepted.handle, accepted.operation, .transfer);
        const endpoint = try self.file_host.attachPreparing(accepted.handle, accepted.operation, .{ .directory = directory, .file_read = file_read });
        try std.testing.expect(try self.app.sessions.ready(accepted.handle, accepted.operation, plugins.requiredServices(.sftp)));
        const startup = try self.app.sessions.journal.begin(.{ .session = accepted.handle }, accepted.operation.attempt_id);
        _ = try self.app.sessions.journal.completeReleased(startup, "controlled adapter startup snapshot");
        try self.app.sessions.journal.retire(startup, .resources_released);
        return .{ .owner = accepted.handle, .create_key = accepted.operation, .target = .{ .window_id = self.app.window_id, .workspace_id = self.app.workspace_id }, .handles = .{ .directory = directory, .file_read = file_read, .transfer = transfer }, .initial_directory = .{ .endpoint = endpoint, .key = startup, .request_id = startup.operation_id, .directory_revision = 11, .requested_path = ".", .resolved_path = if (failure) null else "/remote", .entries = &.{}, .failure = if (failure) .permission_denied else null } };
    }
    fn install(self: *Fixture, source_: adapters.Presentation) !domain.Attachment {
        const hook = self.presentation.hooks();
        const attachment = try hook.install(hook.context, source_);
        try std.testing.expect(try self.app.sessions.attached(source_.owner, attachment));
        return attachment;
    }
    fn localPump(self: *Fixture) !void {
        while (self.local.poll()) |received| {
            var result = received;
            defer result.deinit();
            try std.testing.expect(try self.presentation.acceptLocal(result.value));
        }
    }
    fn frame(self: *Fixture) !void {
        _ = try self.file_host.safeTick();
        try self.localPump();
        _ = try self.presentation.safeTick();
        self.cx.frame_count += 1;
        self.cx.advanceFrameClock();
        _ = self.cx.render();
        pause();
    }
    fn awaitLocal(self: *Fixture, owner: identity.SessionHandle) !void {
        const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
        while (self.presentation.modelFor(owner).?.paneStatus(.local).state == .loading) {
            if (clock.monotonicNs() > deadline) return error.TestTimeout;
            try self.frame();
        }
        try self.frame();
    }
    fn stop(self: *Fixture) void {
        self.workspace.shutting_down = false;
        const hook = self.presentation.hooks();
        for (self.app.mappings.items) |mapping| if (self.presentation.modelFor(mapping.handle) != null) {
            _ = hook.release(hook.context, mapping.handle, .{ .target = .{ .window_id = self.app.window_id, .workspace_id = self.app.workspace_id }, .tab_id = mapping.tab_id }, mapping.create_operation);
        };
        _ = self.presentation.shutdownStep();
        const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
        while (self.presentation.shutdownStep() != .released) {
            if (clock.monotonicNs() > deadline) @panic("presentation did not drain");
            self.frame() catch unreachable;
        }
        self.presentation.deinit() catch unreachable;
        self.local.requestClose();
        while (self.local.closeReceipt() != .released) {
            if (clock.monotonicNs() > deadline) unreachable;
            pause();
        }
        self.local.deinit() catch unreachable;
        self.gate.release.store(true, .release);
        self.file_host.requestCloseAll();
        while (self.file_host.safeTick() catch unreachable) {
            if (clock.monotonicNs() > deadline) unreachable;
            pause();
        }
        self.file_host.deinit() catch unreachable;
        self.app.deinit();
        self.cx.clearFocus();
        self.scope.dispose();
        self.cx.deinit();
        self.local_journal.deinit();
        a.free(self.path);
        a.free(self.hosts_path);
        self.tmp.cleanup();
    }
};
fn find(node: *ui.Node, id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, value, id)) return node;
    for (node.children.items) |child| if (find(child, id)) |found| return found;
    return null;
}

test "file workspace presentation installs a real file tab with local filesystem rows and no terminal" {
    var f: Fixture = undefined;
    try f.init();
    defer f.stop();
    const source = try f.source(31, false);
    const attachment = try f.install(source);
    try std.testing.expectEqual(@as(usize, 1), f.workspace.tabs.items.len);
    const tab = f.workspace.tabs.items[0];
    try std.testing.expect(tab.terminal == null and tab.runtime == null and tab.file_scope != null);
    try std.testing.expectEqual(attachment.tab_id, tab.tab_id);
    try std.testing.expect(tab.content_owner.eql(.{ .session = source.owner }));
    try std.testing.expect(f.presentation.modelFor(source.owner).?.projection() == null);
    try std.testing.expect(find(tab.root, "files.initial.local.status") != null);
    try f.awaitLocal(source.owner);
    const projection = f.presentation.modelFor(source.owner).?.projection().?;
    try std.testing.expectEqualStrings(f.path, projection.panes[0].resolved_path);
    var found = false;
    for (projection.panes[0].entries) |entry| if (std.mem.eql(u8, entry.raw_name, "presentation-local.txt")) {
        found = true;
    };
    try std.testing.expect(found);
    try std.testing.expectEqualStrings("/remote", projection.panes[1].resolved_path);
    try std.testing.expect(find(tab.root, "files.workspace").?.style.display == .flex);
}

test "file workspace presentation close waits for real local release then destroys only its exact attachment" {
    var f: Fixture = undefined;
    try f.init();
    defer f.stop();
    const source = try f.source(32, false);
    const attachment = try f.install(source);
    const other_source = try f.source(132, false);
    const other_attachment = try f.install(other_source);
    const other_root = f.presentation.contentFor(other_source.owner).?;
    const hook = f.presentation.hooks();
    var foreign = attachment;
    foreign.tab_id = @fromBackingInt(@backingInt(foreign.tab_id) + 99);
    try std.testing.expectEqual(domain.CloseReceipt.unknown, hook.release(hook.context, source.owner, foreign, source.create_key));
    try std.testing.expectEqual(domain.CloseReceipt.awaiting, hook.release(hook.context, source.owner, attachment, source.create_key));
    try std.testing.expectEqual(@as(usize, 2), f.workspace.tabs.items.len);
    try std.testing.expect(f.presentation.contentFor(source.owner) != null);
    try std.testing.expect(f.presentation.modelFor(source.owner).?.pending.items.len > 0);
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (hook.release(hook.context, source.owner, attachment, source.create_key) != .released) {
        if (clock.monotonicNs() > deadline) return error.TestTimeout;
        try f.frame();
    }
    try std.testing.expectEqual(@as(usize, 1), f.workspace.tabs.items.len);
    try std.testing.expectEqual(other_attachment.tab_id, f.workspace.tabs.items[0].tab_id);
    try std.testing.expect(f.workspace.tabs.items[0].root == other_root);
    try std.testing.expect(f.presentation.modelFor(other_source.owner) != null);
    try std.testing.expect(f.presentation.modelFor(source.owner) == null and f.presentation.contentFor(source.owner) == null);
    try std.testing.expectEqual(domain.CloseReceipt.released, hook.release(hook.context, source.owner, attachment, source.create_key));
}

test "file workspace presentation attach failure keeps rollback resources until true release without installing content" {
    var f: Fixture = undefined;
    try f.init();
    defer f.stop();
    const source = try f.source(33, false);
    const hook = f.presentation.hooks();
    f.workspace.shutting_down = true;
    try std.testing.expectError(error.WorkspaceClosed, hook.install(hook.context, source));
    try std.testing.expectEqual(@as(usize, 0), f.workspace.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 0), f.app.mappings.items.len);
    try std.testing.expect(f.presentation.modelFor(source.owner).?.closing);
    var foreign = source.create_key;
    foreign.operation_id += 1;
    try std.testing.expectEqual(domain.CloseReceipt.unknown, hook.rollback.?(hook.context, source.owner, foreign));
    try std.testing.expectEqual(domain.CloseReceipt.awaiting, hook.rollback.?(hook.context, source.owner, source.create_key));
    try std.testing.expectEqual(domain.CloseReceipt.awaiting, f.presentation.shutdownStep());
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (f.presentation.shutdownStep() != .released) {
        if (clock.monotonicNs() > deadline) return error.TestTimeout;
        try f.frame();
    }
    try std.testing.expect(f.presentation.modelFor(source.owner) == null);
    try std.testing.expectEqual(domain.CloseReceipt.released, hook.rollback.?(hook.context, source.owner, source.create_key));
}

test "file workspace presentation leaves unrelated shared local results to their actual consumer" {
    var f: Fixture = undefined;
    try f.init();
    defer f.stop();
    const source = try f.source(34, false);
    _ = try f.install(source);
    const other = try f.local_journal.begin(.app, null);
    try f.local.submit(other, .{ .endpoint = f.local.endpoint, .request_id = other.operation_id, .directory_revision = 1, .path = f.path, .action = .stat });
    var delivered = false;
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (!delivered) {
        if (clock.monotonicNs() > deadline) return error.TestTimeout;
        if (f.local.poll()) |received| {
            var result = received;
            defer result.deinit();
            const accepted = try f.presentation.acceptLocal(result.value);
            if (result.value.key.eql(other)) {
                try std.testing.expect(!accepted);
                try std.testing.expect(result.value.body == .stat);
                try std.testing.expectEqualStrings(f.path, result.value.requested_path);
                _ = try f.local_journal.completeReleased(other, "actual other consumer");
                try f.local_journal.retire(other, .resources_released);
                delivered = true;
            } else try std.testing.expect(accepted);
        } else pause();
    }
}

test "file workspace presentation unresolved startup failure stays readable without inventing a remote root" {
    var f: Fixture = undefined;
    try f.init();
    defer f.stop();
    const source = try f.source(35, true);
    _ = try f.install(source);
    try f.awaitLocal(source.owner);
    const model = f.presentation.modelFor(source.owner).?;
    try std.testing.expect(model.projection() == null);
    try std.testing.expectEqual(Presentation.controller.View.State.failed, model.paneStatus(.remote).state);
    const root = f.presentation.contentFor(source.owner).?;
    const status = find(root, "files.initial.remote.status").?;
    try std.testing.expect(status.getText().?.content.len > 0);
    try std.testing.expect(!std.mem.eql(u8, status.getText().?.content, "目录为空"));
    try std.testing.expect(find(root, "files.workspace").?.style.display == .none);
    const retry = find(root, "files.initial.remote.retry").?;
    try std.testing.expect(!retry.behavior.interaction.a11y.?.disabled);
}

test "file workspace presentation context and history use real menus and reject later card revision" {
    var f: Fixture = undefined;
    try f.init();
    defer f.stop();
    const source = try f.source(39, false);
    _ = try f.install(source);
    try f.awaitLocal(source.owner);
    const model = f.presentation.modelFor(source.owner).?;
    var projection = model.projection().?;
    const local = projection.panes[0];
    var envelope: @import("ui/file_workspace_view.zig").Envelope = .{ .side = .local, .stamp = local.stamp, .projection_revision = projection.revision, .selection_revision = local.selection_revision, .action = .history };
    try model.handle(envelope);
    try f.frame();
    const menu = f.presentation.entries.items[0].action_views[0].?;
    try std.testing.expect(menu.open.peek());
    try std.testing.expect(menu.history);
    try std.testing.expect(find(menu.content, "files.history.navigate") != null);
    for (0..12) |_| try f.frame();
    try std.testing.expectApproxEqAbs(@as(f32, 340), menu.chrome.globalRect().w, 1);
    try std.testing.expect(menu.chrome.globalRect().h <= 148);
    const path_before = try a.dupe(u8, model.projection().?.panes[0].resolved_path);
    defer a.free(path_before);
    const original_revision = projection.revision;
    envelope.action = .{ .sort = .{ .column = .size } };
    try model.handle(envelope);
    const navigation = find(menu.content, "files.history.navigate").?;
    // Invoke the actual widget's registered click callback after a later sort.
    if (navigation.behavior.events.on_click) |handler| handler.invoke();
    try std.testing.expectEqualStrings(path_before, model.projection().?.panes[0].resolved_path);
    try std.testing.expect(model.projection().?.revision > original_revision);
    try std.testing.expectEqualStrings("StaleFileAction", menu.feedback.?.getText().?.content);
    projection = model.projection().?;
    const entry = projection.panes[0].entries[0].absolute_path;
    const keys = [_][]const u8{entry};
    envelope = .{ .side = .local, .stamp = projection.panes[0].stamp, .projection_revision = projection.revision, .selection_revision = projection.panes[0].selection_revision, .action = .{ .context = .{ .keys = &keys, .anchor = entry, .focused_key = entry } } };
    try model.handle(envelope);
    try f.frame();
    try std.testing.expect(menu.open.peek() and !menu.history);
    for (0..12) |_| try f.frame();
    try std.testing.expectApproxEqAbs(@as(f32, 260), menu.chrome.globalRect().w, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 150), menu.chrome.globalRect().h, 1);
    try std.testing.expect(find(menu.content, "files.context.copy") != null);
    const rename = find(menu.content, "files.context.rename").?;
    try std.testing.expect(!rename.behavior.interaction.focusable);
    try std.testing.expectEqualStrings(entry, menu.frozen.?.envelope.action.context.keys[0]);
}

test "file workspace presentation history removal leaves directory and other card unchanged" {
    var f: Fixture = undefined;
    try f.init();
    defer f.stop();
    const source = try f.source(40, false);
    _ = try f.install(source);
    try f.awaitLocal(source.owner);
    const model = f.presentation.modelFor(source.owner).?;
    const projection = model.projection().?;
    const local = projection.panes[0];
    var envelope: @import("ui/file_workspace_view.zig").Envelope = .{ .side = .local, .stamp = local.stamp, .projection_revision = projection.revision, .selection_revision = local.selection_revision, .action = .history };
    var foreign = envelope;
    foreign.stamp.owner.generation += 1;
    try std.testing.expectError(error.OwnerMismatch, model.removeHistory(foreign, local.resolved_path));
    try model.removeHistory(envelope, local.resolved_path);
    try std.testing.expectEqualStrings(f.path, model.projection().?.panes[0].resolved_path);
    try std.testing.expectEqualStrings("/remote", model.projection().?.panes[1].resolved_path);
    try std.testing.expectEqual(@as(usize, 0), model.pending.items.len);
    try std.testing.expectError(error.StaleFileAction, model.removeHistory(envelope, local.resolved_path));
    const updated = model.projection().?;
    envelope.projection_revision = updated.revision;
    try model.handle(envelope);
    try f.frame();
    const menu = f.presentation.entries.items[0].action_views[0].?;
    try std.testing.expect(find(menu.content, "files.history.empty") != null);
}

test "file workspace presentation explicit directory recovery waits old worker release and preserves original tab and rows on new failure" {
    var f: Fixture = undefined;
    try f.init();
    defer f.stop();
    const source = try f.source(41, false);
    const attachment = try f.install(source);
    try f.awaitLocal(source.owner);
    const model = f.presentation.modelFor(source.owner).?;
    const old_directory = model.options.remote.directory;
    const transfer = f.app.sessions.queryService(source.owner, .transfer).available;
    const old_key = f.gate.last_source.?.open_key;
    try std.testing.expectEqual(@as(usize, 1), f.gate.prepare_count);
    f.gate.release.store(true, .release);
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (f.file_host.state(old_directory) != null) {
        if (clock.monotonicNs() > deadline) return error.TestTimeout;
        try f.frame();
    }
    try f.frame();
    try std.testing.expectEqual(@import("ui/file_workspace_view.zig").State.stale, model.paneStatus(.remote).state);
    const projection = model.projection().?;
    const remote = projection.panes[1];
    const local_count = projection.panes[0].entries.len;
    try model.handle(.{ .side = .remote, .stamp = remote.stamp, .projection_revision = projection.revision, .selection_revision = remote.selection_revision, .action = .recover });
    const recovery = f.app.sessions.sftpDirectoryRecovery(source.owner).?;
    try std.testing.expect(!f.app.sessions.bindingIsLive(old_directory));
    try std.testing.expect(f.app.sessions.bindingIsLive(transfer));
    while (f.presentation.entries.items[0].directory_recovery != null) {
        if (clock.monotonicNs() > deadline) return error.TestTimeout;
        try f.frame();
    }
    try std.testing.expectEqual(@as(usize, 2), f.gate.prepare_count);
    try std.testing.expect(f.gate.last_source.?.owner.eql(source.owner));
    try std.testing.expect(f.gate.last_source.?.create_key.eql(source.create_key));
    try std.testing.expect(!f.gate.last_source.?.open_key.eql(old_key));
    try std.testing.expectEqualStrings("presentation-fixture.invalid", f.gate.last_host[0..f.gate.last_host_len]);
    try std.testing.expectEqual(@as(usize, 1), f.workspace.tabs.items.len);
    try std.testing.expectEqual(attachment.tab_id, f.workspace.tabs.items[0].tab_id);
    try std.testing.expectEqualStrings("/remote", model.projection().?.panes[1].resolved_path);
    try std.testing.expectEqual(local_count, model.projection().?.panes[0].entries.len);
    try std.testing.expectEqual(domain.CloseReceipt.released, f.app.sessions.sftpDirectoryRecovery(source.owner).?.cleanup);
    try std.testing.expect(!f.app.sessions.bindingIsLive(recovery.bindings.directory));
    try std.testing.expectEqual(@import("ui/file_workspace_view.zig").State.stale, model.paneStatus(.remote).state);
}

test "file workspace presentation inline copy freezes target and waits explicit confirmation with saved choices" {
    const Copy = @import("ui/file_copy_view.zig");
    const Capture = struct {
        count: usize = 0,
        fail: bool = true,
        fn submit(raw: ?*anyopaque, intent: Presentation.controller.FrozenTransfer, options: Copy.Options) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try std.testing.expectEqualStrings("/remote/locked", intent.destination.directory);
            try std.testing.expectEqualStrings("/original/file", intent.paths[0]);
            try std.testing.expect(!options.resume_transfer and options.md5_check);
            self.count += 1;
            if (self.fail) return error.ControlledQueueFailure;
        }
    };
    var f: Fixture = undefined;
    try f.init();
    defer f.stop();
    const source = try f.source(185, false);
    _ = try f.install(source);
    try f.awaitLocal(source.owner);
    const entry = f.presentation.entries.items[0];
    const p = entry.model.projection().?;
    const copy = entry.copy_views[1].?;
    var captured: Capture = .{};
    copy.context = &captured;
    copy.callback = Capture.submit;
    var path = "/original/file".*;
    const paths = [_][]const u8{&path};
    try copy.open(.{ .owner = source.owner, .source = .{ .stamp = p.panes[0].stamp, .endpoint = .{ .local_fs = f.local.endpoint }, .selection_revision = 1, .directory = f.path }, .destination = .{ .stamp = p.panes[1].stamp, .endpoint = .{ .sftp = source.initial_directory.endpoint }, .selection_revision = 1, .directory = "/remote/locked" }, .paths = &paths }, .{ .resume_transfer = false, .md5_check = true });
    path[0] = 'X';
    for (0..12) |_| try f.frame();
    try std.testing.expectApproxEqAbs(@as(f32, 132), copy.root.globalRect().h, 1);
    try std.testing.expectEqual(@as(usize, 0), captured.count);
    // Cancel has no queue callback; a later explicit draft still owns copies.
    const frozen = copy.frozen.?.intent;
    copy.dismiss();
    try std.testing.expectEqual(@as(usize, 0), captured.count);
    // open copies before releasing the previous frozen arena.
    try copy.open(frozen, .{ .resume_transfer = false, .md5_check = true });
    try std.testing.expect(!copy.resume_value.peek() and copy.md5_value.peek());
    copy.confirm.behavior.events.on_click.?.invoke();
    try std.testing.expectEqual(@as(usize, 1), captured.count);
    try std.testing.expect(copy.shown);
    try std.testing.expectEqualStrings("ControlledQueueFailure", copy.feedback.getText().?.content);
    captured.fail = false;
    copy.confirm.behavior.events.on_click.?.invoke();
    try std.testing.expectEqual(@as(usize, 2), captured.count);
    try std.testing.expect(!copy.shown);
}
