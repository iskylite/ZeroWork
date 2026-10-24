const std = @import("std");
const module = @import("host/sftp_adapter.zig");
const sessions = @import("host/session_host.zig");
const files = @import("host/file_binding_host.zig");
const identity = @import("host/identity.zig");
const ssh = @import("proto/ssh/session.zig");
const operations = @import("host/operation.zig");
const plugins = @import("host/plugin_registry.zig");
const clock = @import("platform/realtime.zig");

const Hooks = struct {
    starts: usize = 0,
    closes: usize = 0,
    installs: usize = 0,
    releases: usize = 0,
    fn transfer(self: *Hooks) module.TransferHooks {
        return .{ .context = self, .start = start, .poll = poll, .close = close };
    }
    fn presentation(self: *Hooks) module.PresentationHooks {
        return .{ .context = self, .install = install, .release = release };
    }
    fn start(raw: *anyopaque, _: module.TransferStart) !void {
        const self: *Hooks = @ptrCast(@alignCast(raw));
        self.starts += 1;
        return error.NoTestTransferBackend;
    }
    fn poll(_: *anyopaque, _: sessions.ServiceHandle, _: sessions.OperationKey) module.TransferStatus {
        return .pending;
    }
    fn close(raw: *anyopaque, _: module.TransferClose) sessions.CloseReceipt {
        const self: *Hooks = @ptrCast(@alignCast(raw));
        self.closes += 1;
        return .released; // No start accepted a resource in these fixtures.
    }
    fn install(raw: *anyopaque, _: module.Presentation) !sessions.Attachment {
        const self: *Hooks = @ptrCast(@alignCast(raw));
        self.installs += 1;
        return error.UnexpectedTestPresentation;
    }
    fn release(raw: *anyopaque, _: identity.SessionHandle, _: sessions.Attachment, _: sessions.OperationKey) sessions.CloseReceipt {
        const self: *Hooks = @ptrCast(@alignCast(raw));
        self.releases += 1;
        return .released;
    }
};
const Factory = struct {
    caller: std.Thread.Id,
    prepares: usize = 0,
    reject: bool = false,
    entered: std.atomic.Value(bool) = .init(false),
    unblock: std.atomic.Value(bool) = .init(false),
    closing: std.atomic.Value(bool) = .init(false),
    close_state: std.atomic.Value(u8) = .init(@backingInt(files.readonly.ReleaseReceipt.awaiting)),
    destroyed: std.atomic.Value(bool) = .init(false),
    token: ?*const std.atomic.Value(bool) = null,
    fn interface(self: *Factory) files.Factory {
        return .{ .context = self, .prepare = prepare, .discard = discard };
    }
    fn prepare(raw: *anyopaque, source: files.Source) !files.readonly.Connector {
        const self: *Factory = @ptrCast(@alignCast(raw));
        self.prepares += 1;
        if (self.reject) return error.FileConnectorRejected;
        return .{ .key = source.open_key, .ctx = self, .connect_fn = connect, .close_fn = close, .deinit_fn = destroy };
    }
    fn discard(_: *anyopaque, _: files.readonly.Connector) void {}
    fn connect(raw: *anyopaque, token: *const std.atomic.Value(bool)) !ssh.Session {
        const self: *Factory = @ptrCast(@alignCast(raw));
        std.debug.assert(std.Thread.getCurrentId() != self.caller);
        self.token = token;
        self.entered.store(true, .release);
        try wait(&self.unblock);
        return if (token.load(.acquire)) error.Cancelled else error.ControlledConnectFailed;
    }
    fn close(raw: *anyopaque, _: ?*ssh.Session) files.readonly.ReleaseReceipt {
        const self: *Factory = @ptrCast(@alignCast(raw));
        std.debug.assert(std.Thread.getCurrentId() != self.caller);
        self.closing.store(true, .release);
        return @fromBackingInt(@intCast(self.close_state.load(.acquire)));
    }
    fn destroy(raw: *anyopaque) void {
        const self: *Factory = @ptrCast(@alignCast(raw));
        self.destroyed.store(true, .release);
    }
};
const target: sessions.AttachmentTarget = .{ .window_id = @fromBackingInt(9), .workspace_id = @fromBackingInt(13) };
fn spec() sessions.SessionCreateSpec {
    return .{ .saved = .{ .connection_id = @fromBackingInt(51), .config_revision = 7, .protocol = .sftp, .immutable_config = .{ .endpoint = .{ .host = "original.invalid", .user = "original" }, .auth = .{ .password = "frozen" } } } };
}
fn pause() void {
    var unused: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&unused, 0, 2);
}
fn wait(flag: *const std.atomic.Value(bool)) !void {
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (!flag.load(.acquire)) {
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
}
fn stop(adapter: *module.SftpAdapter, host: *sessions.SessionHost, file_host: *files.FileBindingHost, factory: *Factory) void {
    factory.unblock.store(true, .release);
    factory.close_state.store(@backingInt(files.readonly.ReleaseReceipt.released), .release);
    _ = adapter.shutdownStep();
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (adapter.safeTick(host, file_host) catch unreachable) {
        if (clock.monotonicNs() >= deadline) unreachable;
        pause();
    }
    while (file_host.safeTick() catch unreachable) {
        if (clock.monotonicNs() >= deadline) unreachable;
        pause();
    }
    adapter.deinit() catch unreachable;
    file_host.deinit() catch unreachable;
}

test "sftp adapter queues immutable create and cancel before tick performs no factory or presentation IO" {
    var hooks: Hooks = .{};
    const adapter = try module.SftpAdapter.init(std.testing.allocator, hooks.transfer(), hooks.presentation(), .{});
    var host = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.adapter()});
    defer host.deinit();
    var factory: Factory = .{ .caller = std.Thread.getCurrentId() };
    var file_host = try files.FileBindingHost.init(std.testing.allocator, &host, factory.interface());
    defer stop(adapter, &host, &file_host, &factory);
    var password = "frozen".*;
    var input = spec();
    input.saved.immutable_config.auth = .{ .password = &password };
    const accepted = try host.create(input, target);
    @memset(&password, 'x');
    try std.testing.expectEqualStrings("frozen", adapter.entries.items[0].request.value.spec.saved.immutable_config.auth.password);
    try std.testing.expectEqual(@as(u64, 1), host.next_binding);
    try std.testing.expectEqual(@as(usize, 0), factory.prepares);
    try std.testing.expectEqual(@as(usize, 0), hooks.starts);
    try std.testing.expectError(error.Busy, adapter.deinit());
    try std.testing.expect(try host.cancel(accepted.operation));
    _ = try adapter.safeTick(&host, &file_host);
    try std.testing.expectEqual(sessions.Lifecycle.failed, host.queryState(accepted.handle).?.lifecycle);
    try std.testing.expectEqual(operations.Cleanup.released, host.queryState(accepted.handle).?.create_cleanup);
    try std.testing.expectEqual(@as(usize, 0), factory.prepares);
    try std.testing.expectEqual(@as(usize, 0), hooks.closes);
    try std.testing.expectEqual(@as(usize, 0), hooks.installs);
}

test "sftp adapter native cancel and unknown cleanup gate retry on the original owner and create key" {
    var hooks: Hooks = .{};
    const adapter = try module.SftpAdapter.init(std.testing.allocator, hooks.transfer(), hooks.presentation(), .{});
    var host = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.adapter()});
    defer host.deinit();
    var factory: Factory = .{ .caller = std.Thread.getCurrentId() };
    var file_host = try files.FileBindingHost.init(std.testing.allocator, &host, factory.interface());
    defer stop(adapter, &host, &file_host, &factory);
    const first = try host.create(spec(), target);
    _ = try adapter.safeTick(&host, &file_host);
    try wait(&factory.entered);
    const handles = adapter.entries.items[0].handles.?;
    try std.testing.expect(host.bindingIsPreparing(handles.transfer, first.operation));
    try std.testing.expect(host.queryService(first.handle, .transfer) == .temporarily_unavailable);
    try std.testing.expectEqual(@as(usize, 0), hooks.starts);
    const wrong = try host.journal.begin(.{ .session = first.handle }, 2);
    try std.testing.expect(!try host.cancel(wrong));
    try std.testing.expect(!factory.token.?.load(.acquire));
    try std.testing.expect(try host.cancel(first.operation));
    _ = try adapter.safeTick(&host, &file_host);
    try std.testing.expect(factory.token.?.load(.acquire));
    factory.unblock.store(true, .release);
    try wait(&factory.closing);
    factory.close_state.store(@backingInt(files.readonly.ReleaseReceipt.unknown), .release);
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (host.queryState(first.handle).?.create_cleanup != .unknown) {
        _ = try adapter.safeTick(&host, &file_host);
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
    try std.testing.expectError(error.CleanupNotReleased, host.retry(first.handle));
    try std.testing.expectError(error.Busy, adapter.deinit());
    try std.testing.expect(!factory.destroyed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), hooks.installs);
    factory.close_state.store(@backingInt(files.readonly.ReleaseReceipt.released), .release);
    while (host.queryState(first.handle).?.create_cleanup != .released) {
        _ = try adapter.safeTick(&host, &file_host);
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
    const retry = try host.retry(first.handle);
    try std.testing.expectEqual(first.handle.generation + 1, retry.handle.generation);
    try std.testing.expect(!try host.ready(first.handle, first.operation, plugins.requiredServices(.sftp)));
    try std.testing.expect(host.queryService(retry.handle, .directory) == .temporarily_unavailable);
    try std.testing.expect(try host.cancel(retry.operation));
    _ = try adapter.safeTick(&host, &file_host);
    try std.testing.expectEqual(@as(usize, 1), factory.prepares);
}

test "sftp adapter rejected factory and unsupported standalone route never publish empty ready services" {
    var hooks: Hooks = .{};
    const adapter = try module.SftpAdapter.init(std.testing.allocator, hooks.transfer(), hooks.presentation(), .{});
    var host = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.adapter()});
    defer host.deinit();
    var factory: Factory = .{ .caller = std.Thread.getCurrentId(), .reject = true };
    var file_host = try files.FileBindingHost.init(std.testing.allocator, &host, factory.interface());
    defer stop(adapter, &host, &file_host, &factory);
    const first = try host.create(spec(), target);
    for (0..3) |_| _ = try adapter.safeTick(&host, &file_host);
    try std.testing.expectEqual(sessions.Lifecycle.failed, host.queryState(first.handle).?.lifecycle);
    try std.testing.expectEqual(operations.Cleanup.released, host.queryState(first.handle).?.create_cleanup);
    try std.testing.expectEqual(@as(usize, 0), hooks.starts);
    try std.testing.expectEqual(@as(usize, 0), hooks.installs);
    var routed = spec();
    routed.saved.route_snapshot = &.{.{ .endpoint = .{ .host = "jump.invalid", .user = "jump" } }};
    const second = try host.create(routed, target);
    for (0..3) |_| _ = try adapter.safeTick(&host, &file_host);
    try std.testing.expectEqual(sessions.Lifecycle.failed, host.queryState(second.handle).?.lifecycle);
    try std.testing.expectEqual(operations.Cleanup.released, host.queryState(second.handle).?.create_cleanup);
    try std.testing.expectEqual(@as(usize, 1), factory.prepares);
    try std.testing.expect(host.queryService(second.handle, .transfer) == .temporarily_unavailable);
}

const Runtime = @import("host/file_transfer_runtime.zig").Runtime;
const Snapshot = @import("ui/session_lifecycle.zig").Snapshot;
const VmHooks = struct {
    factory: files.Factory,
    runtime: ?*Runtime = null,
    binding: ?sessions.ServiceHandle = null,
    create_key: ?sessions.OperationKey = null,
    installed: ?Snapshot(module.Presentation) = null,
    attachment: ?sessions.Attachment = null,
    released_with: ?sessions.OperationKey = null,
    release_receipt: sessions.CloseReceipt = .released,
    bad_attachment: bool = false,
    install_error: bool = false,
    installs: usize = 0,
    native_not_released_at_presentation_release: bool = false,
    ids: identity.Allocator(identity.TabId) = .{},
    fn transfer(self: *VmHooks) module.TransferHooks {
        return .{ .context = self, .start = start, .poll = poll, .close = close };
    }
    fn presentation(self: *VmHooks) module.PresentationHooks {
        return .{ .context = self, .install = install, .release = release, .rollback = rollback };
    }
    fn path(_: *anyopaque, request: sessions.CreateRequest) ![]const u8 {
        return if (request.spec.saved.private_options.len == 0) "." else request.spec.saved.private_options;
    }
    fn start(raw: *anyopaque, request: module.TransferStart) !void {
        const self: *VmHooks = @ptrCast(@alignCast(raw));
        if (self.runtime != null) return error.DuplicateRuntime;
        const connector = try self.factory.prepare(self.factory.context, request.source);
        self.runtime = Runtime.start(std.testing.allocator, request.binding, connector) catch |err| {
            self.factory.discard(self.factory.context, connector);
            return err;
        };
        self.binding = request.binding;
        self.create_key = request.source.create_key;
    }
    fn poll(raw: *anyopaque, binding: sessions.ServiceHandle, key: sessions.OperationKey) module.TransferStatus {
        const self: *VmHooks = @ptrCast(@alignCast(raw));
        if (self.runtime) |runtime| {
            if (!binding.eql(self.binding.?) or !key.eql(self.create_key.?)) return .{ .failed = .{ .domain = .host, .code = "wrong_runtime_identity", .safe_message = "fixture" } };
            if (runtime.failureReason()) |err| return .{ .failed = .{ .domain = .transport, .code = @errorName(err), .safe_message = "actual runtime failed" } };
            if (runtime.state() == .ready) return .{ .ready = runtime.binding };
        }
        return .pending;
    }
    fn close(raw: *anyopaque, request: module.TransferClose) sessions.CloseReceipt {
        const self: *VmHooks = @ptrCast(@alignCast(raw));
        const runtime = self.runtime orelse return .released;
        if (!runtime.binding.eql(request.binding) or !self.create_key.?.eql(request.create_key) or request.operation.owner != .session or !request.operation.owner.session.eql(request.owner)) return .unknown;
        runtime.requestClose();
        return convert(runtime.closeReceipt());
    }
    fn install(raw: *anyopaque, value: module.Presentation) !sessions.Attachment {
        const self: *VmHooks = @ptrCast(@alignCast(raw));
        self.installs += 1;
        if (self.runtime == null or self.runtime.?.state() != .ready) return error.TransferWasNotActuallyReady;
        if (!value.initial_directory.retired or value.initial_directory.cleanup != .released) return error.DirectoryWasNotRetired;
        if (!self.binding.?.eql(value.handles.transfer) or !self.create_key.?.eql(value.create_key)) return error.PresentationIdentityMismatch;
        self.installed = try Snapshot(module.Presentation).init(std.testing.allocator, value);
        if (self.install_error) return error.OutOfMemory;
        var original = value.target;
        if (self.bad_attachment) original.window_id = @fromBackingInt(400);
        const attachment: sessions.Attachment = .{ .target = original, .tab_id = try self.ids.allocate() };
        self.attachment = attachment;
        return attachment; // Headless presentation receipt; no native UI claim.
    }
    fn release(raw: *anyopaque, owner: identity.SessionHandle, attachment: sessions.Attachment, key: sessions.OperationKey) sessions.CloseReceipt {
        const self: *VmHooks = @ptrCast(@alignCast(raw));
        if (self.runtime.?.closeReceipt() != .released) self.native_not_released_at_presentation_release = true;
        if (!std.meta.eql(self.attachment.?, attachment) or !self.installed.?.value.owner.eql(owner)) return .unknown;
        self.released_with = key;
        return self.release_receipt;
    }
    fn rollback(raw: *anyopaque, owner: identity.SessionHandle, key: sessions.OperationKey) sessions.CloseReceipt {
        const self: *VmHooks = @ptrCast(@alignCast(raw));
        if (self.runtime.?.closeReceipt() != .released) self.native_not_released_at_presentation_release = true;
        if (self.attachment != null or !self.installed.?.value.owner.eql(owner) or !self.create_key.?.eql(key)) return .unknown;
        self.released_with = key;
        return self.release_receipt;
    }
    fn deinit(self: *VmHooks) void {
        if (self.runtime) |runtime| {
            const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
            while (true) {
                runtime.deinit() catch {
                    if (clock.monotonicNs() >= deadline) unreachable;
                    pause();
                    continue;
                };
                break;
            }
        }
        if (self.installed) |*value| value.deinit();
    }
};
fn convert(receipt: files.readonly.ReleaseReceipt) sessions.CloseReceipt {
    return switch (receipt) {
        .released => .released,
        .awaiting => .awaiting,
        .unknown => .unknown,
    };
}
fn trust(_: *anyopaque, _: []const u8, _: u16, value: ssh.HostKeyInfo) ssh.HostKeyDecision {
    const expected = std.mem.span(std.c.getenv("ZEROWORK_SFTP_FINGERPRINT") orelse return .reject_unknown);
    return if (value.status == .unknown and std.mem.eql(u8, value.fingerprint, expected)) .trust_once else .reject_unknown;
}
fn stopVm(adapter: *module.SftpAdapter, host: *sessions.SessionHost, file_host: *files.FileBindingHost, hooks: *VmHooks) void {
    hooks.release_receipt = .released;
    _ = adapter.shutdownStep();
    const deadline = clock.monotonicNs() + 15 * std.time.ns_per_s;
    while (adapter.safeTick(host, file_host) catch unreachable) {
        if (clock.monotonicNs() >= deadline) unreachable;
        pause();
    }
    while (file_host.safeTick() catch unreachable) {
        if (clock.monotonicNs() >= deadline) unreachable;
        pause();
    }
    adapter.deinit() catch unreachable;
    file_host.deinit() catch unreachable;
}

test "sftp adapter optional VM real file and transfer readiness initial directory error and original attachment rollback" {
    const password_raw = std.c.getenv("ZEROWORK_VM_PASSWORD") orelse return error.SkipZigTest;
    const password = std.mem.span(password_raw);
    var library = try ssh.Library.init();
    defer library.deinit();
    for ([_]enum { browsing, directory_error, bad_attachment, install_failure }{ .browsing, .directory_error, .bad_attachment, .install_failure }) |mode| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(path);
        const trust_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/known_hosts", .{path});
        defer std.testing.allocator.free(trust_path);
        var ignored: u8 = 0;
        var native: files.DirectFactory = .{ .library = &library, .known_hosts_path = trust_path, .host_key_observer = .{ .ctx = &ignored, .callback = trust }, .timeout_ms = 5000 };
        var hooks: VmHooks = .{ .factory = native.interface(), .bad_attachment = mode == .bad_attachment, .install_error = mode == .install_failure, .release_receipt = if (mode == .install_failure) .unknown else .released };
        defer hooks.deinit();
        const adapter = try module.SftpAdapter.init(std.testing.allocator, hooks.transfer(), hooks.presentation(), .{ .initial_path = .{ .context = &ignored, .get = VmHooks.path } });
        var host = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.adapter()});
        defer host.deinit();
        var file_host = try files.FileBindingHost.init(std.testing.allocator, &host, native.interface());
        defer stopVm(adapter, &host, &file_host, &hooks);
        var input = spec();
        input.saved.immutable_config.endpoint = .{ .host = std.mem.span(std.c.getenv("ZEROWORK_VM_HOST") orelse return error.MissingHost), .user = "root" };
        input.saved.immutable_config.auth = .{ .password = password };
        input.saved.private_options = if (mode == .directory_error) "/zerowork-readonly-nonexistent-directory-20261020" else ".";
        const accepted = try host.create(input, target);
        const deadline = clock.monotonicNs() + 20 * std.time.ns_per_s;
        var saw_ready_before_install = false;
        while (true) {
            _ = try adapter.safeTick(&host, &file_host);
            const state = host.queryState(accepted.handle).?;
            if (state.lifecycle == .ready and hooks.installed == null) saw_ready_before_install = true;
            if (mode == .install_failure) {
                if (hooks.released_with != null and hooks.release_receipt == .unknown) {
                    try std.testing.expectEqual(sessions.Lifecycle.failed, state.lifecycle);
                    try std.testing.expectEqual(operations.Cleanup.unknown, state.create_cleanup);
                    try std.testing.expectError(error.Busy, adapter.deinit());
                    hooks.release_receipt = .released;
                }
                if (state.lifecycle == .failed and state.create_cleanup == .released) break;
            } else if (mode == .bad_attachment) {
                if (state.lifecycle == .failed and state.create_cleanup == .released) break;
            } else if (state.lifecycle == .attached) break;
            if (state.lifecycle == .failed and mode != .bad_attachment and mode != .install_failure) {
                if (adapter.entries.items[0].failure) |value| std.debug.print("SFTP_ADAPTER_VM_FAILURE {s}\n", .{value.code});
                return error.VmStartupFailed;
            }
            if (clock.monotonicNs() >= deadline) return error.VmStartupTimeout;
            pause();
        }
        try std.testing.expect(saw_ready_before_install);
        const presented = hooks.installed.?.value;
        try std.testing.expect(presented.owner.eql(accepted.handle));
        try std.testing.expect(std.meta.eql(target, presented.target));
        try std.testing.expect(presented.initial_directory.retired and presented.initial_directory.cleanup == .released);
        for (host.journal.records.items) |record| try std.testing.expect(!record.key.eql(presented.initial_directory.key));
        if (mode == .directory_error) {
            try std.testing.expectEqual(@as(?files.readonly.Failure, .not_found), presented.initial_directory.failure);
            // Servers may canonicalize a path which does not exist; retain
            // that actual REALPATH receipt alongside LIST's typed failure.
            if (presented.initial_directory.resolved_path) |resolved| try std.testing.expectEqualStrings(input.saved.private_options, resolved);
            try std.testing.expectEqual(@as(usize, 0), presented.initial_directory.entries.len);
        } else {
            try std.testing.expect(presented.initial_directory.failure == null);
            try std.testing.expectEqualStrings("/root", presented.initial_directory.resolved_path.?);
        }
        try std.testing.expectEqual(@as(usize, 1), hooks.installs);
        if (mode == .bad_attachment or mode == .install_failure) {
            try std.testing.expect(hooks.released_with.?.eql(accepted.operation));
            try std.testing.expect(!hooks.native_not_released_at_presentation_release);
            try std.testing.expect(host.queryService(accepted.handle, .transfer) == .temporarily_unavailable);
        } else {
            try std.testing.expect(host.queryService(accepted.handle, .transfer).available.eql(presented.handles.transfer));
            // Use the initialized actual transfer capability before close.
            const transfer = @import("transfer/manager.zig");
            var manager = try transfer.Manager.init(std.testing.allocator, hooks.runtime.?.engine(), 1, .{ .max_attempts = 1 });
            defer manager.deinit();
            const job = try manager.enqueue(.{ .session_id = @backingInt(accepted.handle.session_id), .transfer_binding = presented.handles.transfer, .direction = .download, .sources = &.{"/etc/os-release"}, .remote_dir = "/etc", .local_dir = path, .rename = "readonly-os-release", .resume_transfer = false });
            while (manager.progress(job).?.state != .succeeded) {
                manager.tick(0);
                try std.testing.expect(manager.progress(job).?.state != .failed);
                if (clock.monotonicNs() >= deadline) return error.VmTransferTimeout;
                pause();
            }
            try std.testing.expectEqual(@as(u64, 579), manager.progress(job).?.done_bytes);
            hooks.release_receipt = .unknown;
            const close_key = try host.requestClose(accepted.handle, .{});
            try std.testing.expect(!hooks.runtime.?.closing.load(.acquire)); // Domain callback queued only.
            while (host.queryState(accepted.handle).?.lifecycle != .cleanup_unknown) {
                _ = try adapter.safeTick(&host, &file_host);
                if (clock.monotonicNs() >= deadline) return error.VmCloseTimeout;
                pause();
            }
            try std.testing.expect(hooks.released_with.?.eql(close_key));
            try std.testing.expectError(error.Busy, adapter.deinit());
            try std.testing.expect(!hooks.native_not_released_at_presentation_release);
            hooks.release_receipt = .released;
            while (host.queryState(accepted.handle).?.lifecycle != .closed) {
                _ = try adapter.safeTick(&host, &file_host);
                if (clock.monotonicNs() >= deadline) return error.VmCloseTimeout;
                pause();
            }
        }
        try std.testing.expectEqual(files.readonly.ReleaseReceipt.released, hooks.runtime.?.closeReceipt());
        try adapter.retire(accepted.handle);
        // The presentation made an owned copy, surviving adapter arena release.
        try std.testing.expect(presented.create_key.eql(accepted.operation));
        try std.testing.expectEqualStrings(input.saved.private_options, presented.initial_directory.requested_path);
        std.debug.print("SFTP_ADAPTER_VM_PASS mode={s} actual_file_init=true actual_transfer_init=true initial_retired=true original_target=true cleanup=released shell=false remote_mutation=false\n", .{@tagName(mode)});
    }
}
