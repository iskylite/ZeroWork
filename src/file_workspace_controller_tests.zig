//! Real local_fs worker/temporary files plus a controlled remote connection
//! gate. Seeded remote pages are explicitly adapter-boundary fixtures, not a
//! claim of a native SFTP read. The failure test drains a real FileBindingHost.
const std = @import("std");
const controller = @import("host/file_workspace_controller.zig");
const files = @import("host/file_binding_host.zig");
const sessions = @import("host/session_host.zig");
const plugins = @import("host/plugin_registry.zig");
const operations = @import("host/operation.zig");
const identity = @import("host/identity.zig");
const ssh = @import("proto/ssh/session.zig");
const clock = @import("platform/realtime.zig");
const fs = controller.fs;
const V = controller.View;
const ui = @import("ui");
const a = std.testing.allocator;

fn awaitMkdir(fixture: *Fixture, side: V.Side) !controller.MkdirStatus {
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (true) {
        try fixture.drain();
        const value = fixture.model.mkdirStatus(side) orelse return error.MissingMkdirStatus;
        if (value.phase != .creating and value.phase != .refreshing) return value;
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
}

fn pause() void {
    var unused: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&unused, 0, 2);
}
const Adapter = struct {
    fn create(_: *anyopaque, _: sessions.CreateRequest) !void {}
    fn cancel(_: *anyopaque, _: operations.OperationKey) sessions.CloseReceipt {
        return .released;
    }
    fn close(_: *anyopaque, _: identity.SessionHandle, _: operations.OperationKey) !sessions.CloseReceipt {
        return .released;
    }
    fn stale(_: *anyopaque, _: identity.SessionHandle, _: operations.OperationKey) void {}
    fn interface(self: *Adapter) sessions.Adapter {
        return .{ .registration = .{ .plugin_id = .sftp, .workspace_kind = .file, .services = plugins.requiredServices(.sftp) }, .context = self, .vtable = &.{ .create = create, .cancel = cancel, .close = close, .release_stale = stale } };
    }
};
const Gate = struct {
    entered: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
    fn prepare(raw: *anyopaque, source: files.Source) !files.readonly.Connector {
        return .{ .key = source.open_key, .ctx = raw, .connect_fn = connect, .close_fn = close, .deinit_fn = destroy };
    }
    fn discard(_: *anyopaque, _: files.readonly.Connector) void {}
    fn connect(raw: *anyopaque, cancel_: *const std.atomic.Value(bool)) !ssh.Session {
        const self: *Gate = @ptrCast(@alignCast(raw));
        self.entered.store(true, .release);
        const deadline = clock.monotonicNs() + 10 * std.time.ns_per_s;
        while (!self.release.load(.acquire) and !cancel_.load(.acquire)) {
            if (clock.monotonicNs() >= deadline) return error.TestTimeout;
            pause();
        }
        return error.ControlledConnectionFailure;
    }
    fn close(_: *anyopaque, _: ?*ssh.Session) ssh.ReleaseReceipt {
        return .released;
    }
    fn destroy(_: *anyopaque) void {}
    fn interface(self: *Gate) files.Factory {
        return .{ .context = self, .prepare = prepare, .discard = discard };
    }
};
const Fixture = struct {
    tmp: std.testing.TmpDir,
    path: [:0]u8,
    adapter: Adapter = .{},
    gate: Gate = .{},
    domain: sessions.SessionHost,
    local_journal: operations.Journal,
    host: files.FileBindingHost,
    local: *fs.Service,
    owner: identity.SessionHandle,
    create_key: operations.OperationKey,
    bindings: files.Bindings,
    endpoint: files.readonly.EndpointRef,
    model: controller.Controller,
    transfer_count: usize = 0,
    frozen: ?controller.FrozenTransfer = null,
    capture_arena: std.heap.ArenaAllocator,
    histories: usize = 0,

    fn init(self: *Fixture, seed_remote: bool, verified: bool) !void {
        return self.initFactory(seed_remote, verified, null);
    }
    fn initFactory(self: *Fixture, seed_remote: bool, verified: bool, factory: ?files.Factory) !void {
        self.tmp = std.testing.tmpDir(.{});
        self.path = try self.tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
        self.adapter = .{};
        self.gate = .{};
        self.domain = try sessions.SessionHost.init(a, &.{self.adapter.interface()});
        self.local_journal = operations.Journal.init(a);
        const accepted = try self.domain.create(.{ .saved = .{ .connection_id = @fromBackingInt(42), .config_revision = 3, .protocol = .sftp, .immutable_config = .{ .endpoint = .{ .host = "controller-fixture.invalid", .user = "fixture" }, .auth = .{ .password = "fixture" } } } }, .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) });
        try std.testing.expect(try self.domain.ready(accepted.handle, accepted.operation, plugins.requiredServices(.sftp)));
        try std.testing.expect(try self.domain.attached(accepted.handle, .{ .target = .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) }, .tab_id = @fromBackingInt(9) }));
        self.owner = accepted.handle;
        self.create_key = accepted.operation;
        self.bindings = .{ .directory = self.domain.queryService(self.owner, .directory).available, .file_read = self.domain.queryService(self.owner, .file_read).available };
        self.host = try files.FileBindingHost.init(a, &self.domain, factory orelse self.gate.interface());
        self.endpoint = try self.host.attach(self.owner, self.bindings);
        self.local = try fs.Service.start(a, .{ .binding_id = 908, .binding_generation = 5 }, .{ .home = self.path });
        self.capture_arena = std.heap.ArenaAllocator.init(a);
        self.transfer_count = 0;
        self.frozen = null;
        self.histories = 0;
        self.model = try controller.Controller.init(a, .{
            .owner = self.owner,
            .local = .{ .service = self.local, .journal = &self.local_journal, .endpoint = self.local.endpoint, .initial_path = self.path, .verified_path = if (verified) self.path else null, .writable = true },
            .remote = .{ .host = &self.host, .directory = self.bindings.directory, .endpoint = self.endpoint, .initial_path = ".", .verified_path = if (verified) "/remote" else null, .labels = .{ .title = "Original remote", .subtitle = "fixture@original" }, .writable = true },
            .callbacks = .{ .context = self, .transfer = onTransfer, .auxiliary = onAuxiliary },
            .page_entries = 2,
        });
        if (seed_remote) try self.seed(&.{});
    }
    fn seed(self: *Fixture, entries: []const files.readonly.Entry) !void {
        const key = try self.domain.journal.begin(.{ .session = self.owner }, self.create_key.attempt_id);
        _ = try self.domain.journal.completeReleased(key, "controlled startup snapshot");
        try self.domain.journal.retire(key, .resources_released);
        try self.model.seedRemote(.{ .endpoint = self.endpoint, .key = key, .request_id = key.operation_id, .directory_revision = 11, .requested_path = ".", .resolved_path = "/remote", .entries = entries });
    }
    fn drain(self: *Fixture) !void {
        while (self.local.poll()) |received| {
            var result = received;
            defer result.deinit();
            try std.testing.expect(try self.model.acceptLocal(result.value));
        }
        _ = try self.host.safeTick();
        _ = try self.model.pump();
    }
    fn awaitLocal(self: *Fixture) !void {
        const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
        while (self.model.paneStatus(.local).state == .loading) {
            try self.drain();
            if (clock.monotonicNs() >= deadline) return error.TestTimeout;
            pause();
        }
    }
    fn stop(self: *Fixture) void {
        self.model.requestClose();
        self.gate.release.store(true, .release);
        const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
        while (self.model.closeReceipt() != .released or self.model.pending.items.len != 0) {
            self.drain() catch unreachable;
            if (clock.monotonicNs() >= deadline) @panic("controller requests did not release");
            pause();
        }
        self.model.deinit() catch unreachable;
        self.local.requestClose();
        while (self.local.closeReceipt() != .released) {
            if (clock.monotonicNs() >= deadline) unreachable;
            pause();
        }
        self.local.deinit() catch unreachable;
        self.host.requestCloseAll();
        while (self.host.safeTick() catch unreachable) {
            if (clock.monotonicNs() >= deadline) unreachable;
            pause();
        }
        self.host.deinit() catch unreachable;
        self.domain.deinit();
        self.local_journal.deinit();
        self.capture_arena.deinit();
        a.free(self.path);
        self.tmp.cleanup();
    }
    fn envelope(self: *Fixture, side: V.Side, action: V.Action) V.Envelope {
        const projection = self.model.projection().?;
        const pane = projection.panes[@backingInt(side)];
        return .{ .side = side, .stamp = pane.stamp, .projection_revision = projection.revision, .selection_revision = pane.selection_revision, .action = action };
    }
    fn navigate(self: *Fixture, side: V.Side, requested: []const u8) !void {
        const projection = self.model.projection().?;
        try self.model.handle(self.envelope(side, .{ .navigate = .{ .requested_path = requested, .base_directory = projection.panes[@backingInt(side)].resolved_path } }));
    }
    fn onTransfer(raw: ?*anyopaque, value: controller.FrozenTransfer) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        const owned = self.capture_arena.allocator();
        var frozen = value;
        const paths = try owned.alloc([]const u8, value.paths.len);
        for (value.paths, paths) |key, *copy| copy.* = try owned.dupe(u8, key);
        frozen.paths = paths;
        frozen.source.directory = try owned.dupe(u8, value.source.directory);
        frozen.destination.directory = try owned.dupe(u8, value.destination.directory);
        self.frozen = frozen;
        self.transfer_count += 1;
    }
    fn onAuxiliary(raw: ?*anyopaque, action: controller.Auxiliary) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        if (action == .history) self.histories = action.history.entries.len;
    }
};

test "file workspace controller accumulates actual local pages only at final and retains raw metadata" {
    var f: Fixture = undefined;
    try f.init(true, true);
    defer f.stop();
    for (0..7) |i| {
        var name: [40]u8 = undefined;
        try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = try std.fmt.bufPrint(&name, "item-{d}.txt", .{i}), .data = "abc" });
    }
    try f.tmp.dir.createDir(std.testing.io, "空格 子目录", .default_dir);
    try f.tmp.dir.symLink(std.testing.io, "item-0.txt", "link", .{});
    try f.model.start();
    const before = f.model.projection().?;
    try std.testing.expectEqual(V.State.loading, before.panes[0].state);
    try std.testing.expectEqual(@as(usize, 0), before.panes[0].entries.len);
    var pages: usize = 0;
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (true) {
        if (f.local.poll()) |received| {
            var result = received;
            defer result.deinit();
            try std.testing.expect(try f.model.acceptLocal(result.value));
            pages += 1;
            if (result.value.final) break;
            const pending = f.model.projection().?;
            try std.testing.expectEqual(before.revision, pending.revision);
            try std.testing.expectEqual(@as(usize, 0), pending.panes[0].entries.len);
            try std.testing.expectEqual(before.panes[0].stamp.directory_revision, pending.panes[0].stamp.directory_revision);
        } else {
            if (clock.monotonicNs() >= deadline) return error.TestTimeout;
            pause();
        }
    }
    try std.testing.expectEqual(@as(usize, 5), pages);
    const result = f.model.projection().?;
    try std.testing.expect(result.owner.eql(f.owner));
    try std.testing.expect(result.panes[0].stamp.owner.eql(f.owner));
    try std.testing.expectEqual(@as(usize, 9), result.panes[0].entries.len);
    try std.testing.expectEqual(V.State.ready, result.panes[0].state);
    try std.testing.expect(result.panes[0].stamp.directory_revision > before.panes[0].stamp.directory_revision);
    try std.testing.expectEqual(@as(usize, 0), f.model.pending.items.len);
    var symlink = false;
    for (result.panes[0].entries) |entry| {
        try std.testing.expect(std.mem.startsWith(u8, entry.absolute_path, f.path));
        try std.testing.expect(std.mem.endsWith(u8, entry.modified_full, " UTC"));
        if (std.mem.eql(u8, entry.raw_name, "link")) symlink = entry.kind == .symlink;
        if (std.mem.eql(u8, entry.raw_name, "item-0.txt")) try std.testing.expectEqual(@as(?u64, 3), entry.size);
    }
    try std.testing.expect(symlink);
    try std.testing.expectEqual(@as(u64, 11), result.panes[1].stamp.directory_revision);
    try std.testing.expect(result.panes[1].can_mkdir);
}

fn downloadedReceipt(job: u64, attempt: u8) @import("transfer/manager.zig").Progress {
    return .{ .job = job, .attempt = attempt, .state = .succeeded, .job_cleanup = .released, .done_bytes = 65829, .total_bytes = 65829, .speed_bps = 0, .retry_at_ms = null, .failure = null };
}

test "completed download refresh uses actual local metadata once per job attempt and preserves selection" {
    const refresh = @import("host/transfer_directory_refresh.zig");
    var f: Fixture = undefined;
    try f.init(true, true);
    defer f.stop();
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "download.bin", .data = &@as([64]u8, @splat('O')) });
    try f.model.start();
    try f.awaitLocal();
    const key = try std.fs.path.join(a, &.{ f.path, "download.bin" });
    defer a.free(key);
    try f.model.handle(f.envelope(.local, .{ .selection = .{ .keys = &.{key}, .anchor = key, .focused_key = key } }));
    const before = f.model.projection().?;
    const old_request = before.panes[0].stamp.request_id;
    const old_directory = before.panes[0].stamp.directory_revision;
    const remote_stamp = before.panes[1].stamp;
    try std.testing.expectEqual(@as(?u64, 64), before.panes[0].entries[0].size);
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "download.bin", .data = &@as([65829]u8, @splat('N')) });
    const target: refresh.Target = .{ .owner = f.owner, .endpoint = f.local.endpoint, .directory = f.path };
    var completion: refresh.Completion = .{};
    var progress = downloadedReceipt(41, 1);
    for ([_]@import("transfer/manager.zig").State{ .running, .paused, .cancelled, .failed }) |state| {
        progress.state = state;
        progress.verification = .{ .state = .passed };
        try std.testing.expect(!try completion.update(progress, target, &f.model));
    }
    progress = downloadedReceipt(41, 1);
    for ([_]@import("transfer/manager.zig").JobCleanup{ .awaiting, .unknown }) |cleanup_| {
        progress.job_cleanup = cleanup_;
        try std.testing.expect(!try completion.update(progress, target, &f.model));
    }
    try std.testing.expectEqual(@as(usize, 0), f.model.pending.items.len);
    try std.testing.expectEqual(old_request, f.model.projection().?.panes[0].stamp.request_id);
    progress = downloadedReceipt(41, 1);
    try std.testing.expect(try completion.update(progress, target, &f.model));
    try std.testing.expectEqual(@as(usize, 1), f.model.pending.items.len);
    const refresh_request = f.model.projection().?.panes[0].stamp.request_id;
    try std.testing.expect(refresh_request > old_request);
    try std.testing.expect(!try completion.update(progress, target, &f.model));
    try std.testing.expectEqual(refresh_request, f.model.projection().?.panes[0].stamp.request_id);
    try f.awaitLocal();
    const after = f.model.projection().?;
    try std.testing.expectEqual(@as(?u64, 65829), after.panes[0].entries[0].size);
    try std.testing.expect(after.panes[0].stamp.directory_revision > old_directory);
    try std.testing.expectEqualDeep(remote_stamp, after.panes[1].stamp);
    try std.testing.expectEqualStrings(key, after.panes[0].selected_keys[0]);
    try std.testing.expectEqualStrings(key, after.panes[0].anchor.?);
    try std.testing.expectEqualStrings(key, after.panes[0].focused_key.?);
    try std.testing.expect(!try completion.update(progress, target, &f.model));
    try std.testing.expectEqual(@as(usize, 0), f.model.pending.items.len);
    try std.testing.expect(try completion.update(downloadedReceipt(41, 2), target, &f.model));
    try f.awaitLocal();
    try std.testing.expect(try completion.update(downloadedReceipt(42, 2), target, &f.model));
    try f.awaitLocal();
}

test "completed download refresh preserves a newer navigation and rejects another owner or endpoint" {
    const refresh = @import("host/transfer_directory_refresh.zig");
    var f: Fixture = undefined;
    try f.init(true, true);
    defer f.stop();
    try f.tmp.dir.createDir(std.testing.io, "elsewhere", .default_dir);
    try f.model.start();
    try f.awaitLocal();
    const before = f.model.projection().?.panes[0].stamp;
    const target: refresh.Target = .{ .owner = f.owner, .endpoint = f.local.endpoint, .directory = f.path };
    var wrong = target;
    wrong.owner.generation += 1;
    var foreign_owner: refresh.Completion = .{};
    try std.testing.expect(!try foreign_owner.update(downloadedReceipt(51, 1), wrong, &f.model));
    wrong = target;
    wrong.endpoint.binding_generation += 1;
    var foreign_endpoint: refresh.Completion = .{};
    try std.testing.expect(!try foreign_endpoint.update(downloadedReceipt(52, 1), wrong, &f.model));
    try std.testing.expectEqualDeep(before, f.model.projection().?.panes[0].stamp);
    try std.testing.expectEqual(@as(usize, 0), f.model.pending.items.len);
    try f.navigate(.local, "elsewhere");
    const navigation = f.model.projection().?.panes[0].stamp.request_id;
    var completion: refresh.Completion = .{};
    try std.testing.expect(!try completion.update(downloadedReceipt(53, 1), target, &f.model));
    try std.testing.expectEqual(navigation, f.model.projection().?.panes[0].stamp.request_id);
    try std.testing.expectEqual(@as(usize, 1), f.model.pending.items.len);
    try f.awaitLocal();
    const entered = f.model.projection().?.panes[0].stamp;
    try std.testing.expect(std.mem.endsWith(u8, f.model.projection().?.panes[0].resolved_path, "/elsewhere"));
    try std.testing.expect(!try completion.update(downloadedReceipt(53, 1), target, &f.model));
    try std.testing.expectEqualDeep(entered, f.model.projection().?.panes[0].stamp);
    try std.testing.expectEqual(@as(usize, 0), f.model.pending.items.len);
    try f.model.handle(f.envelope(.local, .parent));
    try f.awaitLocal();
    try std.testing.expect(!try completion.update(downloadedReceipt(53, 1), target, &f.model));
    try std.testing.expectEqual(@as(usize, 0), f.model.pending.items.len);
}

test "file workspace controller navigation history and failed reads preserve the successful directory" {
    var f: Fixture = undefined;
    try f.init(true, false);
    defer f.stop();
    try f.tmp.dir.createDir(std.testing.io, "sub", .default_dir);
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "original.txt", .data = "abc" });
    try f.model.start();
    try std.testing.expect(f.model.projection() == null);
    try f.awaitLocal();
    try f.navigate(.local, "sub");
    try f.awaitLocal();
    const entered = f.model.projection().?;
    try std.testing.expectEqual(V.State.empty, entered.panes[0].state);
    try std.testing.expect(std.mem.endsWith(u8, entered.panes[0].resolved_path, "/sub"));
    try std.testing.expect(entered.panes[0].can_back);
    try f.model.handle(f.envelope(.local, .back));
    try f.awaitLocal();
    try std.testing.expectEqualStrings(f.path, f.model.projection().?.panes[0].resolved_path);
    try f.model.forward(f.envelope(.local, .history));
    try f.awaitLocal();
    try std.testing.expect(std.mem.endsWith(u8, f.model.projection().?.panes[0].resolved_path, "/sub"));
    try f.model.handle(f.envelope(.local, .parent));
    try f.awaitLocal();
    const old = f.model.projection().?;
    const original_path = try a.dupe(u8, old.panes[0].entries[0].absolute_path);
    defer a.free(original_path);
    try f.navigate(.local, "missing-directory");
    try f.awaitLocal();
    const failed = f.model.projection().?;
    try std.testing.expectEqual(V.State.failed, failed.panes[0].state);
    try std.testing.expectEqualStrings(f.path, failed.panes[0].resolved_path);
    try std.testing.expectEqual(old.panes[0].stamp.directory_revision, failed.panes[0].stamp.directory_revision);
    try std.testing.expect(failed.panes[0].stamp.request_id > old.panes[0].stamp.request_id);
    try std.testing.expectEqualStrings(original_path, failed.panes[0].entries[0].absolute_path);
    try std.testing.expect(!failed.panes[0].writable and !failed.panes[0].can_transfer);
    try f.model.handle(f.envelope(.local, .history));
    try std.testing.expect(f.histories >= 5);
    try f.model.handle(f.envelope(.local, .recover));
    try f.awaitLocal();
    try std.testing.expectEqual(V.State.ready, f.model.projection().?.panes[0].state);
}

test "file workspace controller selection uses path keys across sort refresh and owner revisions" {
    var f: Fixture = undefined;
    try f.init(true, false);
    defer f.stop();
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "alpha", .data = "1" });
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "beta", .data = "123456" });
    try f.model.start();
    try f.awaitLocal();
    const first = f.model.projection().?;
    const key = try a.dupe(u8, first.panes[0].entries[0].absolute_path);
    defer a.free(key);
    const selection: V.Selection = .{ .keys = &.{key}, .anchor = key, .focused_key = key };
    const stale = f.envelope(.local, .{ .selection = selection });
    try f.model.handle(stale);
    try std.testing.expectError(error.StaleFileAction, f.model.handle(stale));
    var wrong_owner = f.envelope(.local, .refresh);
    wrong_owner.stamp.owner.generation += 1;
    try std.testing.expectError(error.OwnerMismatch, f.model.handle(wrong_owner));
    var wrong_binding = f.envelope(.local, .refresh);
    wrong_binding.stamp.endpoint.binding_generation += 1;
    try std.testing.expectError(error.StaleFileAction, f.model.handle(wrong_binding));
    try f.model.handle(f.envelope(.local, .{ .sort = .{ .column = .size, .descending = true } }));
    const sorted = f.model.projection().?;
    try std.testing.expectEqualStrings("beta", sorted.panes[0].entries[0].raw_name);
    try std.testing.expectEqualStrings(key, sorted.panes[0].selected_keys[0]);
    try std.testing.expectEqualStrings(key, sorted.panes[0].focused_key.?);
    try f.tmp.dir.deleteFile(std.testing.io, "alpha");
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "aaa-new", .data = "new" });
    try f.model.handle(f.envelope(.local, .refresh));
    try f.awaitLocal();
    const refreshed = f.model.projection().?;
    try std.testing.expectEqual(@as(usize, 0), refreshed.panes[0].selected_keys.len);
    try std.testing.expect(refreshed.panes[0].anchor == null and refreshed.panes[0].focused_key == null);
    try std.testing.expectError(error.InvalidFileSelection, f.model.handle(f.envelope(.local, .{ .selection = selection })));
}

test "file workspace controller transfer publishes frozen two-sided identities and no execution" {
    var f: Fixture = undefined;
    try f.init(true, false);
    defer f.stop();
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source file", .data = "source" });
    try f.tmp.dir.createDir(std.testing.io, "new-target", .default_dir);
    try f.model.start();
    try f.awaitLocal();
    const first = f.model.projection().?;
    const key = try a.dupe(u8, first.panes[0].entries[1].absolute_path);
    defer a.free(key);
    const selection: V.Selection = .{ .keys = &.{key}, .anchor = key, .focused_key = key };
    try f.model.handle(f.envelope(.local, .{ .selection = selection }));
    const selected = f.model.projection().?;
    const action = f.envelope(.local, .{ .transfer = .{ .selection = selection, .destination = selected.panes[1].stamp, .directory = selected.panes[1].resolved_path } });
    try f.model.handle(action);
    try std.testing.expectEqual(@as(usize, 1), f.transfer_count);
    try std.testing.expect(f.frozen.?.owner.eql(f.owner));
    try std.testing.expect(f.frozen.?.source.endpoint.local_fs.eql(f.local.endpoint));
    try std.testing.expect(f.frozen.?.destination.endpoint.sftp.eql(f.endpoint));
    try std.testing.expectEqualStrings(key, f.frozen.?.paths[0]);
    try std.testing.expectEqual(@as(usize, 0), f.host.pending.items.len);
    try f.navigate(.local, "new-target");
    try f.awaitLocal();
    try std.testing.expectEqualStrings(f.path, f.frozen.?.source.directory);
    try std.testing.expectEqualStrings("/remote", f.frozen.?.destination.directory);
    try std.testing.expectError(error.StaleFileAction, f.model.handle(action));
    try std.testing.expectEqual(@as(usize, 1), f.transfer_count);
}

test "file workspace controller accepts only matching local request metadata and abandons old pages" {
    var f: Fixture = undefined;
    try f.init(true, true);
    defer f.stop();
    try f.tmp.dir.createDir(std.testing.io, "sub", .default_dir);
    try f.model.start();
    const key = f.model.paneStatus(.local).request.?;
    const work = f.model.pending.items[0];
    var foreign: fs.Result = .{ .key = key, .endpoint = f.local.endpoint, .request_id = key.operation_id, .directory_revision = work.revision, .requested_path = f.path, .resolved_path = f.path, .body = .{ .page = .{ .index = 0, .entries = &.{} } } };
    foreign.key.operation_id += 9000;
    try std.testing.expect(!try f.model.acceptLocal(foreign));
    foreign.key = key;
    foreign.endpoint.binding_generation += 1;
    try std.testing.expectError(error.ResultEndpointMismatch, f.model.acceptLocal(foreign));
    foreign.endpoint = f.local.endpoint;
    foreign.directory_revision += 1;
    try std.testing.expectError(error.ResultRequestMismatch, f.model.acceptLocal(foreign));
    try f.navigate(.local, "sub");
    const new_key = f.model.paneStatus(.local).request.?;
    try std.testing.expect(!key.eql(new_key));
    try f.awaitLocal();
    const final = f.model.projection().?;
    try std.testing.expectEqual(new_key.operation_id, final.panes[0].stamp.request_id);
    try std.testing.expect(std.mem.endsWith(u8, final.panes[0].resolved_path, "/sub"));
    try std.testing.expectEqual(V.State.empty, final.panes[0].state);
}

test "file workspace controller real remote failure preserves owner and waits for original final on close" {
    var f: Fixture = undefined;
    try f.init(false, true);
    defer f.stop();
    try f.model.start();
    const original = f.model.paneStatus(.remote).request.?;
    try std.testing.expect(original.owner.session.eql(f.owner));
    try std.testing.expectEqual(@as(usize, 1), f.host.pending.items.len);
    try std.testing.expect(f.host.pending.items[0].key.eql(original));
    f.model.requestClose();
    try std.testing.expectEqual(controller.ReleaseReceipt.awaiting, f.model.closeReceipt());
    try std.testing.expectError(error.Busy, f.model.deinit());
    try std.testing.expectError(error.FileWorkspaceClosing, f.model.handle(f.envelope(.remote, .refresh)));
    // Close did not release the shared app service/connection or invent a
    // receipt. Only these original queued requests receive cancellation.
    try std.testing.expect(!f.local.closing.load(.acquire));
    try std.testing.expectEqual(files.Phase.connecting, f.host.state(f.bindings.directory).?.phase);
    f.gate.release.store(true, .release);
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (f.model.closeReceipt() != .released) {
        try f.drain();
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
    try std.testing.expectEqual(@as(usize, 0), f.model.pending.items.len);
    try std.testing.expect(f.model.projection().?.owner.eql(f.owner));
}

test "file workspace controller startup copy and numeric sorting keep unknown values last" {
    var f: Fixture = undefined;
    try f.init(false, false);
    defer f.stop();
    var raw = "alpha".*;
    var original = "/remote/alpha".*;
    try f.seed(&.{
        .{ .raw_name = &raw, .display_name = &raw, .absolute_path = &original, .attributes = .{ .kind = .file, .size = 2 } },
        .{ .raw_name = "beta", .display_name = "beta", .absolute_path = "/remote/beta", .attributes = .{ .kind = .file, .size = 2, .modified_at = 5 } },
        .{ .raw_name = "gamma", .display_name = "gamma", .absolute_path = "/remote/gamma", .attributes = .{ .kind = .symlink, .modified_at = 1 } },
    });
    @memset(&raw, 'x');
    @memset(&original, 'x');
    try f.model.start();
    try f.awaitLocal();
    try f.model.handle(f.envelope(.remote, .{ .sort = .{ .column = .size, .descending = true } }));
    var pane = f.model.projection().?.panes[1];
    try std.testing.expectEqualStrings("alpha", pane.entries[0].raw_name);
    try std.testing.expectEqualStrings("/remote/alpha", pane.entries[0].absolute_path);
    try std.testing.expectEqualStrings("beta", pane.entries[1].raw_name);
    try std.testing.expect(pane.entries[2].size == null);
    try f.model.handle(f.envelope(.remote, .{ .sort = .{ .column = .modified, .descending = true } }));
    pane = f.model.projection().?.panes[1];
    try std.testing.expectEqualStrings("beta", pane.entries[0].raw_name);
    try std.testing.expectEqualStrings("gamma", pane.entries[1].raw_name);
    try std.testing.expectEqualStrings("alpha", pane.entries[2].raw_name);
    try std.testing.expectEqualStrings("1970-01-01 00:00:05 UTC", pane.entries[0].modified_full);
    try std.testing.expectEqual(@as(usize, 0), pane.entries[2].modified_full.len);
}

test "file workspace controller closing does not cancel another app filesystem consumer" {
    var f: Fixture = undefined;
    try f.init(true, false);
    defer f.stop();
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "unrelated", .data = "real file" });
    try f.model.start();
    const foreign = try f.local_journal.begin(.app, null);
    try f.local.submit(foreign, .{ .endpoint = f.local.endpoint, .request_id = foreign.operation_id, .directory_revision = 79, .path = f.path, .action = .{ .list = .{} } });
    f.model.requestClose();
    try std.testing.expectEqual(controller.ReleaseReceipt.awaiting, f.model.closeReceipt());
    try std.testing.expectError(error.Busy, f.model.deinit());
    var foreign_final = false;
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (!foreign_final or f.model.closeReceipt() != .released) {
        if (f.local.poll()) |received| {
            var result = received;
            defer result.deinit();
            if (!try f.model.acceptLocal(result.value)) {
                try std.testing.expect(result.value.key.eql(foreign));
                try std.testing.expect(result.value.body == .page);
                try std.testing.expectEqual(@as(u64, 79), result.value.directory_revision);
                if (result.value.final) {
                    foreign_final = true;
                    _ = try f.local_journal.completeReleased(foreign, "unrelated consumer completed");
                    try f.local_journal.retire(foreign, .resources_released);
                }
            }
        } else {
            if (clock.monotonicNs() >= deadline) return error.TestTimeout;
            pause();
        }
    }
    try std.testing.expect(!f.local.closing.load(.acquire));
}

test "file workspace controller actual directory projection reaches Cx view and acknowledges original selection" {
    var f: Fixture = undefined;
    try f.init(true, false);
    defer f.stop();
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "real-ui-file", .data = "abc" });
    try f.model.start();
    try f.awaitLocal();
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 480);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer {
        cx.clearFocus();
        scope.dispose();
    }
    const view = try V.View.mount(cx, scope, f.model.viewCallbacks());
    try cx.root.?.appendChild(a, view.root);
    try view.update(f.model.projection().?);
    try std.testing.expect(try view.flush());
    const pane = f.model.projection().?.panes[0];
    const key = pane.entries[0].absolute_path;
    const callback = view.callbacks;
    try callback.action(callback.context, f.envelope(.local, .{ .selection = .{ .keys = &.{key}, .anchor = key, .focused_key = key } }));
    try view.update(f.model.projection().?);
    try std.testing.expect(try view.flush());
    try std.testing.expectEqualStrings(key, view.source.?.value.panes[0].selected_keys[0]);
    try std.testing.expect(view.source.?.value.owner.eql(f.owner));
    try std.testing.expectEqual(pane.stamp.endpoint.binding_id, view.source.?.value.panes[0].stamp.endpoint.binding_id);
}

test "file workspace controller unresolved startup failure remains failure and retries only frozen endpoint" {
    var f: Fixture = undefined;
    try f.init(false, false);
    defer f.stop();
    const key = try f.domain.journal.begin(.{ .session = f.owner }, f.create_key.attempt_id);
    var initial: controller.InitialDirectory = .{ .endpoint = f.endpoint, .key = key, .request_id = key.operation_id, .directory_revision = 4, .requested_path = ".", .resolved_path = null, .entries = &.{}, .failure = .permission_denied, .retired = false };
    try std.testing.expectError(error.DirectoryStartupNotReleased, f.model.seedRemote(initial));
    _ = try f.domain.journal.failReleased(key, .{ .domain = .transport, .code = "permission_denied", .cleanup = .released, .safe_message = "controlled startup read failed" });
    try f.domain.journal.retire(key, .resources_released);
    initial.retired = true;
    try f.model.seedRemote(initial);
    try f.model.start();
    try f.awaitLocal();
    try std.testing.expect(f.model.projection() == null);
    try std.testing.expectEqual(V.State.failed, f.model.paneStatus(.remote).state);
    try std.testing.expectEqualStrings("没有权限读取此目录", f.model.paneStatus(.remote).failure);
    try std.testing.expect(f.model.panes[1].directory == null);
    try f.model.retryInitial(.remote);
    const retry = f.model.paneStatus(.remote).request.?;
    try std.testing.expect(retry.owner.session.eql(f.owner));
    try std.testing.expect(retry.operation_id > key.operation_id);
    try std.testing.expectEqual(@as(usize, 1), f.host.pending.items.len);
    try std.testing.expect(f.host.pending.items[0].binding.eql(f.bindings.directory));
    try std.testing.expect(f.host.pending.items[0].endpoint.eql(f.endpoint));
    f.gate.release.store(true, .release);
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (f.model.paneStatus(.remote).state == .loading) {
        try f.drain();
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
    try std.testing.expect(f.model.paneStatus(.remote).state == .failed or f.model.paneStatus(.remote).state == .stale);
    try std.testing.expect(f.model.projection() == null);
}

test "file workspace controller mkdir rejects unsafe names stale identity and missing write authorization before dispatch" {
    var f: Fixture = undefined;
    try f.init(true, true);
    defer f.stop();
    try f.model.start();
    try f.awaitLocal();
    const envelope = f.envelope(.local, .new_folder);
    const before = f.model.revision;
    const count = f.model.pending.items.len;
    for ([_][]const u8{ "", ".", "..", "a/b", "a\\b", "a\x00b" }) |name| {
        try std.testing.expectError(error.InvalidName, f.model.mkdir(envelope, name));
    }
    try std.testing.expectEqual(before, f.model.revision);
    try std.testing.expectEqual(count, f.model.pending.items.len);
    try std.testing.expect(f.model.mkdirStatus(.local) == null);
    var wrong = envelope;
    wrong.stamp.owner.generation += 1;
    try std.testing.expectError(error.OwnerMismatch, f.model.mkdir(wrong, "valid"));
    wrong = envelope;
    wrong.stamp.endpoint.binding_generation += 1;
    try std.testing.expectError(error.StaleFileAction, f.model.mkdir(wrong, "valid"));
    wrong = envelope;
    wrong.stamp.directory_revision += 1;
    try std.testing.expectError(error.StaleFileAction, f.model.mkdir(wrong, "valid"));
    f.model.options.local.writable = false;
    try std.testing.expectError(error.DirectoryNotWritable, f.model.mkdir(envelope, "valid"));
    try std.testing.expectEqual(count, f.model.pending.items.len);
}

test "file workspace controller mkdir actual local success refreshes and selects literal child without navigation or transfer" {
    var f: Fixture = undefined;
    try f.init(true, true);
    defer f.stop();
    try f.model.start();
    try f.awaitLocal();
    for ([_][]const u8{ "新建目录", "~" }) |name| {
        const original = f.model.projection().?.panes[0].stamp;
        const key = try f.model.mkdir(f.envelope(.local, .new_folder), name);
        try std.testing.expectEqual(controller.MkdirPhase.creating, f.model.mkdirStatus(.local).?.phase);
        try std.testing.expectError(error.MkdirPending, f.model.mkdir(f.envelope(.local, .new_folder), "duplicate-pending"));
        const status = try awaitMkdir(&f, .local);
        try std.testing.expectEqual(controller.MkdirPhase.succeeded, status.phase);
        try std.testing.expect(status.created and status.failure == null);
        try std.testing.expect(status.key.eql(key));
        try std.testing.expect(std.meta.eql(original, status.stamp));
        try std.testing.expect(status.refresh_key != null and !status.refresh_key.?.eql(key));
        try std.testing.expectEqualStrings(name, status.name);
        try std.testing.expectEqual(.directory, (try f.tmp.dir.statFile(std.testing.io, name, .{})).kind);
        const pane = f.model.projection().?.panes[0];
        try std.testing.expectEqualStrings(f.path, pane.resolved_path);
        try std.testing.expectEqual(@as(usize, 1), pane.selected_keys.len);
        try std.testing.expectEqualStrings(status.path, pane.selected_keys[0]);
        try std.testing.expectEqualStrings(status.path, pane.focused_key.?);
        try std.testing.expectEqual(@as(usize, 0), f.transfer_count);
    }
}

test "file workspace controller mkdir actual conflict retains input directory rows and revisions" {
    var f: Fixture = undefined;
    try f.init(true, true);
    defer f.stop();
    try f.tmp.dir.createDir(std.testing.io, "existing", .default_dir);
    try f.model.start();
    try f.awaitLocal();
    const before = f.model.projection().?.panes[0];
    const original_revision = before.stamp.directory_revision;
    const original_request = before.stamp.request_id;
    _ = try f.model.mkdir(f.envelope(.local, .new_folder), "existing");
    const status = try awaitMkdir(&f, .local);
    try std.testing.expectEqual(controller.MkdirPhase.failed, status.phase);
    try std.testing.expectEqual(controller.MkdirFailure.already_exists, status.failure.?);
    try std.testing.expect(!status.created and status.refresh_key == null);
    try std.testing.expectEqualStrings("existing", status.name);
    const after = f.model.projection().?.panes[0];
    try std.testing.expectEqual(original_revision, after.stamp.directory_revision);
    try std.testing.expectEqual(original_request, after.stamp.request_id);
    try std.testing.expectEqual(@as(usize, 1), after.entries.len);
    try std.testing.expectEqualStrings("existing", after.entries[0].raw_name);
    try std.testing.expectEqualStrings(f.path, after.resolved_path);
}

test "file workspace controller mkdir creation receipt stays distinct from failed actual refresh" {
    var f: Fixture = undefined;
    try f.init(true, true);
    defer f.stop();
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "old", .data = "old" });
    try f.model.start();
    try f.awaitLocal();
    const original_revision = f.model.projection().?.panes[0].stamp.directory_revision;
    f.model.options.max_entries = 1;
    _ = try f.model.mkdir(f.envelope(.local, .new_folder), "created-once");
    const status = try awaitMkdir(&f, .local);
    try std.testing.expectEqual(controller.MkdirPhase.created_refresh_failed, status.phase);
    try std.testing.expect(status.created and status.refresh_key != null);
    try std.testing.expectEqual(.directory, (try f.tmp.dir.statFile(std.testing.io, "created-once", .{})).kind);
    const after = f.model.projection().?.panes[0];
    try std.testing.expectEqual(V.State.failed, after.state);
    try std.testing.expectEqual(original_revision, after.stamp.directory_revision);
    try std.testing.expectEqual(@as(usize, 1), after.entries.len);
    try std.testing.expectEqualStrings("old", after.entries[0].raw_name);
    try std.testing.expectEqualStrings("created-once", status.name);
    // Directory read retry cannot accidentally reissue the acknowledged mkdir.
    f.model.options.max_entries = 4096;
    try f.model.handle(f.envelope(.local, .refresh));
    try f.awaitLocal();
    try std.testing.expectEqual(@as(usize, 2), f.model.projection().?.panes[0].entries.len);
    try std.testing.expectEqual(controller.MkdirPhase.created_refresh_failed, f.model.mkdirStatus(.local).?.phase);
}

test "file workspace controller mkdir late actual receipt cannot replace later directory or new creation" {
    var f: Fixture = undefined;
    try f.init(true, true);
    defer f.stop();
    try f.tmp.dir.createDir(std.testing.io, "later", .default_dir);
    try f.model.start();
    try f.awaitLocal();
    const first = try f.model.mkdir(f.envelope(.local, .new_folder), "old-child");
    var held: fs.OwnedResult = blk: {
        const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
        while (true) {
            if (f.local.poll()) |result| {
                if (result.value.key.eql(first)) break :blk result;
                var other = result;
                defer other.deinit();
                try std.testing.expect(try f.model.acceptLocal(other.value));
            }
            if (clock.monotonicNs() >= deadline) return error.TestTimeout;
            pause();
        }
    };
    var accepted = false;
    defer {
        if (!accepted) _ = f.model.acceptLocal(held.value) catch unreachable;
        held.deinit();
    }
    try std.testing.expect(held.value.body == .created);
    try f.navigate(.local, "later");
    try f.awaitLocal();
    const second = try f.model.mkdir(f.envelope(.local, .new_folder), "new-child");
    try std.testing.expect(try f.model.acceptLocal(held.value));
    accepted = true;
    try std.testing.expect(f.model.mkdirStatus(.local).?.key.eql(second));
    const status = try awaitMkdir(&f, .local);
    try std.testing.expectEqual(controller.MkdirPhase.succeeded, status.phase);
    try std.testing.expectEqualStrings("new-child", status.name);
    try std.testing.expect(std.mem.endsWith(u8, f.model.projection().?.panes[0].resolved_path, "/later"));
    try std.testing.expectEqual(.directory, (try f.tmp.dir.statFile(std.testing.io, "old-child", .{})).kind);
    try std.testing.expectEqual(.directory, (try f.tmp.dir.statFile(std.testing.io, "later/new-child", .{})).kind);
    try std.testing.expectEqual(@as(usize, 0), f.transfer_count);
}

const MkdirNative = struct {
    library: *ssh.Library,
    port: u16,
    fingerprint: []const u8,
    controls: []const u8,
    key: operations.OperationKey = undefined,
    closed: std.atomic.Value(bool) = .init(false),
    fn trust(raw: *anyopaque, host: []const u8, port: u16, value: ssh.HostKeyInfo) ssh.HostKeyDecision {
        const self: *MkdirNative = @ptrCast(@alignCast(raw));
        return if (std.mem.eql(u8, host, "127.0.0.1") and port == self.port and value.status == .unknown and std.mem.eql(u8, value.fingerprint, self.fingerprint)) .trust_once else .reject_unknown;
    }
    fn prepare(raw: *anyopaque, source: files.Source) !files.readonly.Connector {
        const self: *MkdirNative = @ptrCast(@alignCast(raw));
        self.key = source.open_key;
        return .{ .key = source.open_key, .ctx = self, .connect_fn = connect, .close_fn = close, .deinit_fn = destroy };
    }
    fn connect(raw: *anyopaque, cancel_: *const std.atomic.Value(bool)) !ssh.Session {
        const self: *MkdirNative = @ptrCast(@alignCast(raw));
        return ssh.Session.connect(self.library, .{ .host = "127.0.0.1", .port = self.port, .user = "fixture", .auth = .{ .password = "mkdir-fixture" }, .open_shell = false, .operation_key = self.key, .cancel_token = cancel_, .host_key_observer = .{ .ctx = self, .callback = trust }, .connect_timeout_ms = 5000 });
    }
    fn close(raw: *anyopaque, value: ?*ssh.Session) ssh.ReleaseReceipt {
        const self: *MkdirNative = @ptrCast(@alignCast(raw));
        const result = if (value) |session| session.closeReceipt() else ssh.ReleaseReceipt.released;
        if (value != null and result == .released) self.closed.store(true, .release);
        return result;
    }
    fn destroy(_: *anyopaque) void {}
    fn discard(_: *anyopaque, _: files.readonly.Connector) void {}
    fn interface(self: *MkdirNative) files.Factory {
        return .{ .context = self, .prepare = prepare, .discard = discard };
    }
    fn marker(self: *MkdirNative, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(a, "{s}/{s}", .{ self.controls, name });
    }
};

test "file workspace controller mkdir native loopback real created conflict permission and late cancel receipts" {
    const port_raw = std.c.getenv("ZEROWORK_MKDIR_PORT") orelse return error.SkipZigTest;
    var library = try ssh.Library.init();
    defer library.deinit();
    var native: MkdirNative = .{ .library = &library, .port = try std.fmt.parseInt(u16, std.mem.span(port_raw), 10), .fingerprint = std.mem.span(std.c.getenv("ZEROWORK_MKDIR_FINGERPRINT") orelse return error.MissingFingerprint), .controls = std.mem.span(std.c.getenv("ZEROWORK_MKDIR_CONTROLS") orelse return error.MissingControls) };
    var f: Fixture = undefined;
    try f.initFactory(false, false, native.interface());
    var live = true;
    defer if (live) f.stop();
    try f.model.start();
    const deadline = clock.monotonicNs() + 8 * std.time.ns_per_s;
    while (f.model.projection() == null or f.model.paneStatus(.remote).state == .loading) {
        try f.drain();
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
    try std.testing.expectEqual(V.State.ready, f.model.paneStatus(.remote).state);
    const created = try f.model.mkdir(f.envelope(.remote, .new_folder), "created-from-native");
    const first = try awaitMkdir(&f, .remote);
    try std.testing.expect(first.key.eql(created) and first.created and first.phase == .succeeded);
    try std.testing.expectEqualStrings("/created-from-native", f.model.projection().?.panes[1].selected_keys[0]);
    for ([_]struct { name: []const u8, failure: controller.MkdirFailure }{ .{ .name = "existing", .failure = .already_exists }, .{ .name = "race", .failure = .already_exists }, .{ .name = "denied", .failure = .permission_denied } }) |example| {
        const before = f.model.projection().?.panes[1].stamp;
        _ = try f.model.mkdir(f.envelope(.remote, .new_folder), example.name);
        const status = try awaitMkdir(&f, .remote);
        try std.testing.expectEqual(controller.MkdirPhase.failed, status.phase);
        try std.testing.expectEqual(example.failure, status.failure.?);
        try std.testing.expectEqualStrings(example.name, status.name);
        try std.testing.expect(!status.created and status.refresh_key == null);
        try std.testing.expect(std.meta.eql(before, f.model.projection().?.panes[1].stamp));
    }
    const pending = try f.model.mkdir(f.envelope(.remote, .new_folder), "created-after-cancel");
    const entered = try native.marker("mkdir-entered");
    defer a.free(entered);
    const release = try native.marker("mkdir-release");
    defer a.free(release);
    defer std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = release, .data = "release" }) catch {};
    const gate_deadline = clock.monotonicNs() + 8 * std.time.ns_per_s;
    while (true) {
        std.Io.Dir.cwd().access(std.testing.io, entered, .{}) catch |err| {
            if (err != error.FileNotFound) return err;
            if (clock.monotonicNs() >= gate_deadline) return error.TestTimeout;
            pause();
            continue;
        };
        break;
    }
    try std.testing.expect(f.host.cancel(pending));
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = release, .data = "release" });
    const completed_after_cancel = try awaitMkdir(&f, .remote);
    try std.testing.expect(completed_after_cancel.key.eql(pending));
    try std.testing.expect(completed_after_cancel.created and completed_after_cancel.phase == .succeeded);
    try std.testing.expectEqualStrings("/created-after-cancel", f.model.projection().?.panes[1].selected_keys[0]);
    try std.testing.expectEqual(@as(usize, 0), f.transfer_count);
    f.stop();
    live = false;
    try std.testing.expect(native.closed.load(.acquire));
    std.debug.print("MKDIR_NATIVE {{\"passed\":true,\"created_operation\":{d},\"cancelled_request_created_operation\":{d},\"actual_created_preserved_after_cancel\":true,\"conflict\":true,\"race_conflict\":true,\"permission_denied\":true,\"selected_after_real_refresh\":true,\"session_released\":true}}\n", .{ created.operation_id, pending.operation_id });
}

test "file workspace controller cross-card folder drop validates exact directory metadata and freezes destination without IO" {
    var f: Fixture = undefined;
    try f.init(false, false);
    defer f.stop();
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "upload.txt", .data = "source" });
    try f.seed(&.{
        .{ .raw_name = "shared", .display_name = "shared", .absolute_path = "/remote/shared", .attributes = .{ .kind = .directory } },
        .{ .raw_name = "not-a-folder", .display_name = "not-a-folder", .absolute_path = "/remote/not-a-folder", .attributes = .{ .kind = .file, .size = 1 } },
    });
    try f.model.start();
    try f.awaitLocal();
    const key = try a.dupe(u8, f.model.projection().?.panes[0].entries[0].absolute_path);
    defer a.free(key);
    const selection: V.Selection = .{ .keys = &.{key}, .anchor = key, .focused_key = key };
    try f.model.handle(f.envelope(.local, .{ .selection = selection }));
    const target = f.model.projection().?.panes[1];
    var action = f.envelope(.local, .{ .transfer = .{ .selection = selection, .destination = target.stamp, .directory = "/remote/not-a-folder", .target_entry = "/remote/not-a-folder" } });
    try std.testing.expectError(error.InvalidTransferDirectory, f.model.handle(action));
    action.action.transfer.directory = "/remote/missing";
    action.action.transfer.target_entry = "/remote/missing";
    try std.testing.expectError(error.StaleTransferDestination, f.model.handle(action));
    action.action.transfer.directory = "/remote/shared";
    action.action.transfer.target_entry = "/remote/shared";
    try f.model.handle(action);
    try std.testing.expectEqual(@as(usize, 1), f.transfer_count);
    try std.testing.expectEqualStrings("/remote/shared", f.frozen.?.destination.directory);
    try std.testing.expectEqualStrings(key, f.frozen.?.paths[0]);
    try std.testing.expectEqualStrings("/remote", f.model.projection().?.panes[1].resolved_path);
    try std.testing.expectEqual(@as(usize, 0), f.host.pending.items.len);
    try std.testing.expect(f.frozen.?.destination.stamp.owner.eql(f.owner));
    action.action.transfer.directory = "/remote/shared/different";
    try std.testing.expectError(error.InvalidTransferDirectory, f.model.handle(action));
    try std.testing.expectEqual(@as(usize, 1), f.transfer_count);
}
