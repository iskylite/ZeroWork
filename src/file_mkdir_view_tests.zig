//! Mkdir input integration: real Cx + Presentation/Controller + private local_fs.
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
    release: std.atomic.Value(bool) = .init(false),
    fn prepare(raw: *anyopaque, source: bindings.Source) !bindings.readonly.Connector {
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
        self.presentation = try Presentation.Presentation.init(a, .{ .app = self.app, .file_host = &self.file_host, .local = .{ .service = self.local, .journal = &self.local_journal, .endpoint = self.local.endpoint, .initial_path = self.path, .writable = true, .labels = .{ .title = "本机真实目录" } } });
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

const Files = @import("ui/file_workspace_view.zig");
fn settle(f: *Fixture) !void {
    for (0..8) |_| try f.frame();
}
fn click(f: *Fixture, target: *ui.Node) !void {
    const r = target.globalRect();
    f.cx.handleMouseDown(r.x + r.w / 2, r.y + r.h / 2, .{});
    f.cx.handleMouseUpEx(r.x + r.w / 2, r.y + r.h / 2, .left, .{});
    try settle(f);
}
fn paneNode(f: *Fixture, owner_: identity.SessionHandle, id: []const u8) *ui.Node {
    const root = f.presentation.contentFor(owner_).?;
    const pane = find(root, "files.local").?;
    return find(pane, id) orelse @panic("missing mkdir UI");
}
fn inputText(f: *Fixture, owner_: identity.SessionHandle, buffer: []u8) []const u8 {
    const client = paneNode(f, owner_, "files.mkdir.name").behavior.interaction.text_input_client.?;
    return buffer[0..client.copy_text(client.context, 0, buffer)];
}
fn enterName(f: *Fixture, owner_: identity.SessionHandle, name: []const u8) !void {
    f.cx.setFocus(paneNode(f, owner_, "files.mkdir.name"));
    f.cx.handleKeyDown(.a, .{ .super = true });
    f.cx.handleTextInput(name);
    try settle(f);
}
fn waitMkdir(f: *Fixture, owner_: identity.SessionHandle) !Presentation.controller.MkdirStatus {
    const end = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (true) {
        if (f.presentation.modelFor(owner_).?.mkdirStatus(.local)) |status| {
            if (status.phase != .creating and status.phase != .refreshing) return status;
        }
        if (clock.monotonicNs() > end) return error.TestTimeout;
        try f.frame();
    }
}
fn openLocal(f: *Fixture, id: u64) !adapters.Presentation {
    const source_ = try f.source(id, false);
    _ = try f.install(source_);
    try f.awaitLocal(source_.owner);
    try settle(f);
    try click(f, paneNode(f, source_.owner, "files.new_folder"));
    return source_;
}

test "file mkdir UI real toolbar and Enter creates once refreshes and locates without navigation" {
    var f: Fixture = undefined;
    try f.init();
    defer f.stop();
    const original = try openLocal(&f, 71);
    const model = f.presentation.modelFor(original.owner).?;
    const before = model.projection().?;
    const remote_stamp = before.panes[1].stamp;
    const before_count = before.panes[0].entries.len;
    const field = paneNode(&f, original.owner, "files.mkdir.field");
    // The editable name column follows the current file-pane width; its
    // folder glyph and 6px gap reserve 22px before the field.
    const name_column = field.parent.?.globalRect();
    try std.testing.expectApproxEqAbs(name_column.w - 22, field.globalRect().w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 24), field.globalRect().h, 0.1);
    const result = paneNode(&f, original.owner, "files.mkdir.result");
    try std.testing.expectApproxEqAbs(paneNode(&f, original.owner, "files.data_clip").globalRect().w, result.globalRect().w, 0.1);
    // Result uses content height: 8px padding, four rows and three 4px gaps.
    try std.testing.expect(result.style.height == .fit);
    var result_height: f32 = 16 + 3 * 4;
    for (result.children.items) |child| result_height += child.globalRect().h;
    try std.testing.expectApproxEqAbs(result_height, result.globalRect().h, 0.1);
    try enterName(&f, original.owner, "新目录 with spaces");
    try std.testing.expectEqual(before_count, model.projection().?.panes[0].entries.len);
    f.cx.handleKeyDown(.@"return", .{});
    const key = model.mkdirStatus(.local).?.key;
    f.cx.handleKeyDown(.@"return", .{});
    try std.testing.expect(key.eql(model.mkdirStatus(.local).?.key));
    try std.testing.expectEqual(@as(usize, 1), model.pending.items.len);
    const status = try waitMkdir(&f, original.owner);
    try settle(&f);
    try std.testing.expectEqual(Presentation.controller.MkdirPhase.succeeded, status.phase);
    try std.testing.expect(status.created);
    const after = model.projection().?;
    try std.testing.expectEqualStrings(f.path, after.panes[0].resolved_path);
    try std.testing.expectEqual(before_count + 1, after.panes[0].entries.len);
    try std.testing.expectEqualStrings(status.path, after.panes[0].focused_key.?);
    try std.testing.expectEqualStrings(status.path, after.panes[0].selected_keys[0]);
    try std.testing.expect(std.meta.eql(remote_stamp, after.panes[1].stamp));
    var created = try f.tmp.dir.openDir(std.testing.io, "新目录 with spaces", .{});
    created.close(std.testing.io);
    try std.testing.expect(paneNode(&f, original.owner, "files.mkdir.editor").style.display == .none);
    try std.testing.expectEqualStrings("目录已刷新", paneNode(&f, original.owner, "files.mkdir.feedback").getText().?.content);
    try std.testing.expectEqual(@as(usize, 0), model.pending.items.len);
}

test "file mkdir UI retains invalid and raced duplicate input and only retries explicit corrected name" {
    var f: Fixture = undefined;
    try f.init();
    defer f.stop();
    const original = try openLocal(&f, 72);
    const model = f.presentation.modelFor(original.owner).?;
    try enterName(&f, original.owner, "../bad");
    f.cx.handleKeyDown(.@"return", .{});
    try settle(&f);
    try std.testing.expect(model.mkdirStatus(.local) == null);
    try std.testing.expectEqualStrings("文件夹名称无效", paneNode(&f, original.owner, "files.mkdir.heading").getText().?.content);
    var raw_buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("../bad", inputText(&f, original.owner, &raw_buffer));
    try f.tmp.dir.createDir(std.testing.io, "raced-name", .default_dir);
    try enterName(&f, original.owner, "raced-name");
    f.cx.handleKeyDown(.@"return", .{});
    const failed = try waitMkdir(&f, original.owner);
    try settle(&f);
    try std.testing.expectEqual(Presentation.controller.MkdirPhase.failed, failed.phase);
    try std.testing.expectEqual(Presentation.controller.MkdirFailure.already_exists, failed.failure.?);
    try std.testing.expect(!failed.created);
    try std.testing.expectEqualStrings("raced-name", inputText(&f, original.owner, &raw_buffer));
    try enterName(&f, original.owner, "corrected-name");
    try click(&f, paneNode(&f, original.owner, "files.mkdir.create"));
    const succeeded = try waitMkdir(&f, original.owner);
    try std.testing.expectEqual(Presentation.controller.MkdirPhase.succeeded, succeeded.phase);
    try std.testing.expect(!succeeded.key.eql(failed.key));
}

test "file mkdir UI Escape cancels draft and frozen directory change rejects Enter" {
    var f: Fixture = undefined;
    try f.init();
    defer f.stop();
    const original = try openLocal(&f, 73);
    const model = f.presentation.modelFor(original.owner).?;
    try enterName(&f, original.owner, "never-created");
    f.cx.handleKeyDown(.escape, .{});
    try settle(&f);
    try std.testing.expect(model.mkdirStatus(.local) == null);
    try std.testing.expect(paneNode(&f, original.owner, "files.mkdir.result").style.display == .none);
    try click(&f, paneNode(&f, original.owner, "files.new_folder"));
    try enterName(&f, original.owner, "stale-name");
    const current = model.projection().?;
    const pane = current.panes[0];
    try model.handle(.{ .side = .local, .stamp = pane.stamp, .projection_revision = current.revision, .selection_revision = pane.selection_revision, .action = .refresh });
    try f.awaitLocal(original.owner);
    try settle(&f);
    f.cx.setFocus(paneNode(&f, original.owner, "files.mkdir.name"));
    f.cx.handleKeyDown(.@"return", .{});
    try settle(&f);
    try std.testing.expect(model.mkdirStatus(.local) == null);
    try std.testing.expectEqualStrings("原目录已变化", paneNode(&f, original.owner, "files.mkdir.heading").getText().?.content);
}

test "file mkdir UI close after submit does not reopen or duplicate mkdir and narrow card retains controls" {
    var f: Fixture = undefined;
    try f.init();
    defer f.stop();
    inline for (.{ "dir-a", "dir-b", "dir-c", "dir-d", "dir-e" }) |name| try f.tmp.dir.createDir(std.testing.io, name, .default_dir);
    const original = try openLocal(&f, 74);
    const model = f.presentation.modelFor(original.owner).?;
    f.cx.setViewport(790, 374);
    try settle(&f);
    const footer = paneNode(&f, original.owner, "files.mkdir.result").globalRect();
    const cancel = paneNode(&f, original.owner, "files.mkdir.cancel").globalRect();
    const create = paneNode(&f, original.owner, "files.mkdir.create").globalRect();
    const clip = paneNode(&f, original.owner, "files.data_clip").globalRect();
    const field = paneNode(&f, original.owner, "files.mkdir.field").globalRect();
    try std.testing.expect(field.y >= clip.y and field.y + field.h <= clip.y + clip.h + 0.1);
    try std.testing.expect(cancel.y >= footer.y and cancel.y + cancel.h <= footer.y + footer.h + 0.1);
    try std.testing.expect(create.x + create.w <= footer.x + footer.w + 0.1);
    try enterName(&f, original.owner, "closed-after-submit");
    f.cx.handleKeyDown(.@"return", .{});
    const key = model.mkdirStatus(.local).?.key;
    // The accepted request stays owned by Controller; dismissing does not
    // silently repeat it, roll back its directory, or reopen on its late result.
    f.cx.handleKeyDown(.escape, .{});
    const status = try waitMkdir(&f, original.owner);
    try settle(&f);
    try std.testing.expectEqual(Presentation.controller.MkdirPhase.succeeded, status.phase);
    try std.testing.expect(status.key.eql(key));
    try std.testing.expect(paneNode(&f, original.owner, "files.mkdir.result").style.display == .none);
    try std.testing.expectEqual(@as(usize, 0), model.pending.items.len);
}

test "file mkdir UI actual permission denial retains name and allows explicit retry" {
    var f: Fixture = undefined;
    try f.init();
    defer f.stop();
    const original = try openLocal(&f, 75);
    const model = f.presentation.modelFor(original.owner).?;
    try enterName(&f, original.owner, "permission-name");
    try f.tmp.dir.setPermissions(std.testing.io, .fromMode(0o500));
    defer f.tmp.dir.setPermissions(std.testing.io, .fromMode(0o700)) catch unreachable;
    f.cx.handleKeyDown(.@"return", .{});
    const failed = try waitMkdir(&f, original.owner);
    try settle(&f);
    try std.testing.expectEqual(Presentation.controller.MkdirPhase.failed, failed.phase);
    try std.testing.expectEqual(Presentation.controller.MkdirFailure.permission_denied, failed.failure.?);
    try std.testing.expect(!failed.created);
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("permission-name", inputText(&f, original.owner, &buffer));
    try std.testing.expectEqualStrings("创建失败 · Permission denied", paneNode(&f, original.owner, "files.mkdir.heading").getText().?.content);
    try f.tmp.dir.setPermissions(std.testing.io, .fromMode(0o700));
    try click(&f, paneNode(&f, original.owner, "files.mkdir.create"));
    const succeeded = try waitMkdir(&f, original.owner);
    try std.testing.expectEqual(Presentation.controller.MkdirPhase.succeeded, succeeded.phase);
    try std.testing.expect(!succeeded.key.eql(failed.key));
    try std.testing.expectEqual(@as(usize, 0), model.pending.items.len);
}

test "file mkdir UI separates actual created receipt from failed directory refresh" {
    var f: Fixture = undefined;
    try f.init();
    defer f.stop();
    const original = try openLocal(&f, 76);
    const model = f.presentation.modelFor(original.owner).?;
    try enterName(&f, original.owner, "created-before-read-denial");
    f.cx.handleKeyDown(.@"return", .{});
    const key = model.mkdirStatus(.local).?.key;
    const end = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (true) {
        if (f.local.poll()) |received| {
            var result = received;
            defer result.deinit();
            try std.testing.expect(result.value.key.eql(key));
            try std.testing.expect(result.value.body == .created);
            // Change only this private tmp fixture after actual mkdir, before
            // Controller can submit its independent refresh operation.
            try f.tmp.dir.setPermissions(std.testing.io, .fromMode(0o300));
            try std.testing.expect(try f.presentation.acceptLocal(result.value));
            break;
        }
        if (clock.monotonicNs() > end) return error.TestTimeout;
        pause();
    }
    defer f.tmp.dir.setPermissions(std.testing.io, .fromMode(0o700)) catch unreachable;
    const status = try waitMkdir(&f, original.owner);
    try settle(&f);
    try std.testing.expect(status.created);
    try std.testing.expectEqual(Presentation.controller.MkdirPhase.created_refresh_failed, status.phase);
    try std.testing.expect(status.refresh_key != null and !status.refresh_key.?.eql(key));
    try std.testing.expectEqualStrings("目录已创建，列表刷新失败", paneNode(&f, original.owner, "files.mkdir.heading").getText().?.content);
    f.cx.setViewport(790, 374);
    try settle(&f);
    const result_rect = paneNode(&f, original.owner, "files.mkdir.result").globalRect();
    const pane_rect = find(f.presentation.contentFor(original.owner).?, "files.local").?.globalRect();
    try std.testing.expect(result_rect.y + result_rect.h <= pane_rect.y + pane_rect.h + 0.1);
    try std.testing.expect(find(find(f.presentation.contentFor(original.owner).?, "files.local").?, "files.error").?.style.display == .none);
    try std.testing.expect(paneNode(&f, original.owner, "files.mkdir.editor").style.display == .none);
    try std.testing.expect(paneNode(&f, original.owner, "files.mkdir.create").style.display == .none);
    f.cx.handleKeyDown(.@"return", .{});
    try settle(&f);
    try std.testing.expect(model.mkdirStatus(.local).?.key.eql(key));
    try f.tmp.dir.setPermissions(std.testing.io, .fromMode(0o700));
    var created = try f.tmp.dir.openDir(std.testing.io, "created-before-read-denial", .{});
    created.close(std.testing.io);
}
