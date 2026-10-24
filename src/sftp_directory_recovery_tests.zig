//! Exact standalone-SFTP directory recovery identity/cleanup gates; no IO.
const std = @import("std");
const domain = @import("host/session_host.zig");
const plugins = @import("host/plugin_registry.zig");
const a = std.testing.allocator;
const target: domain.AttachmentTarget = .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) };
const Adapter = struct {
    fn interface(context: *anyopaque) domain.Adapter {
        return .{ .registration = .{ .plugin_id = .sftp, .workspace_kind = .file, .services = plugins.requiredServices(.sftp) }, .context = context, .vtable = &.{ .create = create, .cancel = cancel, .close = close, .release_stale = stale } };
    }
    fn create(_: *anyopaque, _: domain.CreateRequest) !void {}
    fn cancel(_: *anyopaque, _: domain.OperationKey) domain.CloseReceipt {
        return .released;
    }
    fn close(_: *anyopaque, _: domain.SessionHandle, _: domain.OperationKey) !domain.CloseReceipt {
        return .released;
    }
    fn stale(_: *anyopaque, _: domain.SessionHandle, _: domain.OperationKey) void {}
};
fn attach(host: *domain.SessionHost) !domain.Accepted {
    const source: domain.SessionCreateSpec = .{ .saved = .{ .connection_id = @fromBackingInt(77), .config_revision = 4, .protocol = .sftp, .immutable_config = .{ .endpoint = .{ .host = "original.invalid", .user = "original" } } } };
    const original = try host.create(source, target);
    try std.testing.expect(try host.ready(original.handle, original.operation, plugins.requiredServices(.sftp)));
    try std.testing.expect(try host.attached(original.handle, .{ .target = target, .tab_id = @fromBackingInt(1) }));
    return original;
}
fn pair(host: *domain.SessionHost, owner: domain.SessionHandle) domain.SftpDirectoryPair {
    return .{ .directory = host.queryService(owner, .directory).available, .file_read = host.queryService(owner, .file_read).available };
}

test "SFTP directory recovery revokes only exact read pair and waits real old release" {
    var context: u8 = 0;
    var host = try domain.SessionHost.init(a, &.{Adapter.interface(&context)});
    defer host.deinit();
    const original = try attach(&host);
    const previous = pair(&host, original.handle);
    const transfer = host.queryService(original.handle, .transfer).available;
    var wrong = previous;
    wrong.file_read.binding_id += 99;
    try std.testing.expectError(error.StaleBinding, host.beginSftpDirectoryRecovery(original.handle, wrong));
    const recovery = try host.beginSftpDirectoryRecovery(original.handle, previous);
    try std.testing.expect(!host.bindingIsLive(previous.directory) and !host.bindingIsLive(previous.file_read));
    try std.testing.expect(host.bindingIsLive(transfer));
    try std.testing.expect(!host.bindingIsPreparing(recovery.bindings.directory, recovery.key));
    try std.testing.expect(!try host.sftpDirectoryRecoveryReady(original.handle, recovery.key, recovery.bindings));
    try std.testing.expect(host.sftpDirectoryPreviousReleased(original.handle, recovery.key, previous, .unknown));
    try std.testing.expect(!host.bindingIsPreparing(recovery.bindings.directory, recovery.key));
    try std.testing.expect(host.sftpDirectoryPreviousReleased(original.handle, recovery.key, previous, .released));
    try std.testing.expect(host.bindingIsPreparing(recovery.bindings.directory, recovery.key));
    try std.testing.expect(!host.bindingIsLive(recovery.bindings.directory));
    try std.testing.expect(try host.sftpDirectoryRecoveryReady(original.handle, recovery.key, recovery.bindings));
    try std.testing.expect(host.bindingIsLive(recovery.bindings.directory) and host.bindingIsLive(recovery.bindings.file_read));
    try std.testing.expect(host.bindingIsLive(transfer));
    try std.testing.expect(host.queryState(original.handle).?.create_operation.eql(original.operation));
    try std.testing.expect(recovery.bindings.directory.binding_generation > previous.directory.binding_generation);
}

test "SFTP directory recovery unknown new cleanup blocks retry and stale transactions cannot publish" {
    var context: u8 = 0;
    var host = try domain.SessionHost.init(a, &.{Adapter.interface(&context)});
    defer host.deinit();
    const original = try attach(&host);
    const previous = pair(&host, original.handle);
    const first = try host.beginSftpDirectoryRecovery(original.handle, previous);
    try std.testing.expect(host.sftpDirectoryPreviousReleased(original.handle, first.key, previous, .released));
    try std.testing.expect(try host.sftpDirectoryRecoveryReleased(first.bindings.directory, first.key, .unknown));
    try std.testing.expectError(error.CleanupNotReleased, host.beginSftpDirectoryRecovery(original.handle, previous));
    try std.testing.expect(try host.sftpDirectoryRecoveryReleased(first.bindings.directory, first.key, .released));
    const next = try host.beginSftpDirectoryRecovery(original.handle, previous);
    try std.testing.expect(!host.sftpDirectoryPreviousReleased(original.handle, first.key, previous, .released));
    try std.testing.expect(!try host.sftpDirectoryRecoveryReady(original.handle, first.key, first.bindings));
    try std.testing.expect(!try host.sftpDirectoryRecoveryReleased(first.bindings.directory, first.key, .released));
    try std.testing.expect(host.sftpDirectoryPreviousReleased(original.handle, next.key, previous, .released));
    try std.testing.expect(try host.sftpDirectoryRecoveryReady(original.handle, next.key, next.bindings));
    try std.testing.expect(try host.sftpDirectoryRecoveryReleased(next.bindings.directory, next.key, .released));
    try std.testing.expectError(error.StaleBinding, host.beginSftpDirectoryRecovery(original.handle, previous));
    const third = try host.beginSftpDirectoryRecovery(original.handle, next.bindings);
    try std.testing.expect(third.bindings.directory.binding_generation > next.bindings.directory.binding_generation);
}

const files = @import("host/file_binding_host.zig");
const factory_mod = @import("host/file_route_factory.zig");
const controller = @import("host/file_workspace_controller.zig");
const operations = @import("host/operation.zig");
const ssh = @import("proto/ssh/session.zig");
const clock = @import("platform/realtime.zig");
fn pause() void {
    var unused: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&unused, 0, 2);
}
fn tick(file_host: *files.FileBindingHost, model: *controller.Controller, local: *controller.fs.Service) !void {
    _ = try file_host.safeTick();
    while (local.poll()) |received| {
        var value = received;
        defer value.deinit();
        _ = try model.acceptLocal(value.value);
    }
    _ = try model.pump();
    pause();
}
const Trust = struct {
    port: u16,
    fingerprint: []const u8,
    count: std.atomic.Value(usize) = .init(0),
    fn observe(raw: *anyopaque, host: []const u8, port: u16, info: ssh.HostKeyInfo) ssh.HostKeyDecision {
        const self: *Trust = @ptrCast(@alignCast(raw));
        if (!std.mem.eql(u8, host, "127.0.0.1") or port != self.port or info.status != .unknown or !std.mem.eql(u8, info.fingerprint, self.fingerprint)) return .reject_unknown;
        _ = self.count.fetchAdd(1, .release);
        return .trust_once;
    }
};

test "SFTP directory recovery actual SourceFactory libssh2 FIN new trust auth and same path rebind" {
    const port_text = std.c.getenv("ZEROWORK_DIRECTORY_RECOVERY_PORT") orelse return error.SkipZigTest;
    const fingerprint = std.mem.span(std.c.getenv("ZEROWORK_DIRECTORY_RECOVERY_FINGERPRINT") orelse return error.MissingFingerprint);
    const control = std.mem.span(std.c.getenv("ZEROWORK_DIRECTORY_RECOVERY_CONTROL") orelse return error.MissingControl);
    const port = try std.fmt.parseInt(u16, std.mem.span(port_text), 10);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(path);
    const known_path = try std.fs.path.join(a, &.{ path, "known_hosts" });
    defer a.free(known_path);
    var library = try ssh.Library.init();
    defer library.deinit();
    var trust: Trust = .{ .port = port, .fingerprint = fingerprint };
    var factory: factory_mod.SourceFactory = .{ .library = &library, .known_hosts_path = known_path, .host_key_observer = .{ .ctx = &trust, .callback = Trust.observe }, .timeout_ms = 5000 };
    var context: u8 = 0;
    var host = try domain.SessionHost.init(a, &.{Adapter.interface(&context)});
    defer host.deinit();
    const original = try host.create(.{ .saved = .{ .connection_id = @fromBackingInt(77), .config_revision = 4, .protocol = .sftp, .immutable_config = .{ .endpoint = .{ .host = "127.0.0.1", .port = port, .user = "fixture" }, .auth = .{ .password = "conflict-fixture" } } } }, target);
    try std.testing.expect(try host.ready(original.handle, original.operation, plugins.requiredServices(.sftp)));
    try std.testing.expect(try host.attached(original.handle, .{ .target = target, .tab_id = @fromBackingInt(1) }));
    const previous = pair(&host, original.handle);
    const transfer = host.queryService(original.handle, .transfer).available;
    var file_host = try files.FileBindingHost.init(a, &host, factory.interface());
    defer {
        file_host.requestCloseAll();
        const until = clock.monotonicNs() + 5 * std.time.ns_per_s;
        while (file_host.safeTick() catch unreachable) {
            if (clock.monotonicNs() > until) @panic("actual file connections did not release");
            pause();
        }
        file_host.deinit() catch unreachable;
    }
    const endpoint = try file_host.attach(original.handle, .{ .directory = previous.directory, .file_read = previous.file_read });
    var local_journal = operations.Journal.init(a);
    defer local_journal.deinit();
    const local = try controller.fs.Service.start(a, .{ .binding_id = 991, .binding_generation = 1 }, .{ .home = path });
    defer {
        local.requestClose();
        while (local.closeReceipt() != .released) pause();
        local.deinit() catch unreachable;
    }
    var model = try controller.Controller.init(a, .{ .owner = original.handle, .local = .{ .service = local, .journal = &local_journal, .endpoint = local.endpoint, .initial_path = path, .writable = true }, .remote = .{ .host = &file_host, .directory = previous.directory, .endpoint = endpoint, .initial_path = "/fixture", .labels = .{ .title = "Original owner" }, .writable = true } });
    defer {
        model.requestClose();
        const until = clock.monotonicNs() + 5 * std.time.ns_per_s;
        while (model.closeReceipt() != .released) {
            tick(&file_host, &model, local) catch unreachable;
            if (clock.monotonicNs() > until) @panic("actual directory requests did not release");
        }
        model.deinit() catch unreachable;
    }
    const deadline = clock.monotonicNs() + 20 * std.time.ns_per_s;
    while (file_host.state(previous.directory).?.phase != .ready) {
        _ = try file_host.safeTick();
        if (clock.monotonicNs() > deadline) return error.NativeReadyTimeout;
        pause();
    }
    try model.start();
    while (model.paneStatus(.remote).state == .loading or model.paneStatus(.local).state == .loading) {
        try tick(&file_host, &model, local);
        if (clock.monotonicNs() > deadline) return error.InitialListTimeout;
    }
    const initial = model.projection().?;
    try std.testing.expectEqualStrings("/fixture", initial.panes[1].resolved_path);
    try std.testing.expect(initial.panes[1].entries.len > 0);
    const old_request = initial.panes[1].stamp.request_id;
    const old_name = try a.dupe(u8, initial.panes[1].entries[0].raw_name);
    defer a.free(old_name);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = control, .data = "drop first\n" });
    // Peer sends genuine FIN. A real LIST exposes the transport failure; no
    // service replacement or authentication happens until the explicit API.
    var envelope: controller.View.Envelope = .{ .side = .remote, .stamp = initial.panes[1].stamp, .projection_revision = initial.revision, .selection_revision = initial.panes[1].selection_revision, .action = .refresh };
    var unused: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&unused, 0, 100);
    try model.handle(envelope);
    while (file_host.state(previous.directory) != null or model.pending.items.len != 0) {
        try tick(&file_host, &model, local);
        if (clock.monotonicNs() > deadline) return error.DeadDirectoryReleaseTimeout;
    }
    try std.testing.expectEqual(@as(usize, 1), trust.count.load(.acquire));
    try std.testing.expectEqual(controller.View.State.stale, model.paneStatus(.remote).state);
    try std.testing.expectEqualStrings(old_name, model.projection().?.panes[1].entries[0].raw_name);
    const recovery = try host.beginSftpDirectoryRecovery(original.handle, previous);
    try std.testing.expect(host.sftpDirectoryPreviousReleased(original.handle, recovery.key, previous, .released));
    const next_endpoint = try file_host.attachPreparing(original.handle, recovery.key, .{ .directory = recovery.bindings.directory, .file_read = recovery.bindings.file_read });
    while (file_host.state(recovery.bindings.directory).?.phase != .ready) {
        _ = try file_host.safeTick();
        if (clock.monotonicNs() > deadline) return error.RecoveryReadyTimeout;
        pause();
    }
    try std.testing.expect(try host.sftpDirectoryRecoveryReady(original.handle, recovery.key, recovery.bindings));
    try model.rebindRemote(previous.directory, recovery.bindings, next_endpoint);
    while (model.paneStatus(.remote).state == .loading) {
        try tick(&file_host, &model, local);
        if (clock.monotonicNs() > deadline) return error.RecoveryListTimeout;
    }
    const restored = model.projection().?;
    try std.testing.expectEqual(controller.View.State.ready, restored.panes[1].state);
    try std.testing.expectEqualStrings("/fixture", restored.panes[1].resolved_path);
    try std.testing.expectEqualStrings(old_name, restored.panes[1].entries[0].raw_name);
    try std.testing.expect(restored.owner.eql(original.handle));
    try std.testing.expect(restored.panes[1].stamp.request_id != old_request);
    try std.testing.expectEqual(@as(usize, 2), trust.count.load(.acquire));
    try std.testing.expect(host.bindingIsLive(transfer));
    envelope.projection_revision = restored.revision;
    try std.testing.expectError(error.StaleFileAction, model.handle(envelope));
    std.debug.print("SFTP_DIRECTORY_RECOVERY_NATIVE {{\"owner\":{d},\"old_binding\":{d},\"new_binding\":{d},\"trust_count\":2,\"resolved_path\":\"/fixture\",\"transfer_preserved\":true}}\n", .{ @backingInt(original.handle.session_id), previous.directory.binding_id, recovery.bindings.directory.binding_id });
}
