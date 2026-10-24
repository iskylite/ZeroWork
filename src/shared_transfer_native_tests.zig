//! Opt-in actual libssh2 test: the original Worker owns one SSH connection
//! carrying its interactive PTY and SFTP. The peer only modifies RAM fixtures.
const std = @import("std");
const ssh = @import("proto/ssh/session.zig");
const Worker = @import("vt/ssh_worker.zig").SshWorker;
const WorkerThread = @import("vt/ssh_worker_thread.zig").Thread;
const TextSlot = @import("vt/text_slot.zig").TextSlot;
const Shared = @import("proto/ssh/shared_transfer_service.zig").Service;
const transfer = @import("transfer/manager.zig");
const identity = @import("host/identity.zig");
const clock = @import("platform/realtime.zig");
const a = std.testing.allocator;
const io = std.testing.io;

fn pause() void {
    var unused: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&unused, 0, 1);
}
const Fixture = struct {
    port: u16,
    fingerprint: []const u8,
    controls: []const u8,
    trusted: bool = false,
    fn environment() !Fixture {
        const port = std.c.getenv("ZEROWORK_SHARED_SFTP_PORT") orelse return error.SkipZigTest;
        return .{ .port = try std.fmt.parseInt(u16, std.mem.span(port), 10), .fingerprint = std.mem.span(std.c.getenv("ZEROWORK_SHARED_SFTP_FINGERPRINT") orelse return error.MissingFingerprint), .controls = std.mem.span(std.c.getenv("ZEROWORK_SHARED_SFTP_CONTROLS") orelse return error.MissingControls) };
    }
    fn trust(raw: *anyopaque, host: []const u8, port: u16, value: ssh.HostKeyInfo) ssh.HostKeyDecision {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (!std.mem.eql(u8, host, "127.0.0.1") or port != self.port or value.status != .unknown or !std.mem.eql(u8, value.fingerprint, self.fingerprint)) return .reject_unknown;
        self.trusted = true;
        return .trust_once;
    }
    fn signal(self: Fixture, name: []const u8) !void {
        const path = try std.fs.path.join(a, &.{ self.controls, name });
        defer a.free(path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "ready\n" });
    }
    fn exists(self: Fixture, name: []const u8) !bool {
        const path = try std.fs.path.join(a, &.{ self.controls, name });
        defer a.free(path);
        std.Io.Dir.cwd().access(io, path, .{}) catch |err| {
            if (err == error.FileNotFound) return false;
            return err;
        };
        return true;
    }
};
const Frames = struct {
    worker: *Worker,
    thread: *WorkerThread,
    bytes: []u8,
    generation: u64 = 0,
    current: []const u8 = &.{},
    fn take(self: *Frames) !void {
        if (self.thread.hasFailed()) return error.WorkerFailed;
        if (try self.worker.text.take(self.generation, self.bytes)) |frame| {
            self.generation = frame.generation;
            self.current = frame.text;
        }
    }
    fn waitText(self: *Frames, text: []const u8) !void {
        const deadline = clock.monotonicNs() + 3 * std.time.ns_per_s;
        while (clock.monotonicNs() < deadline) {
            try self.take();
            if (std.mem.indexOf(u8, self.current, text) != null) return;
            pause();
        }
        std.debug.print("SHARED_LAST_FRAME {s}\n", .{self.current});
        return error.ShellEchoTimeout;
    }
    fn echo(self: *Frames, text: []const u8) !u64 {
        const started = clock.monotonicNs();
        try self.worker.pushInput(text);
        var expected: [128]u8 = undefined;
        try self.waitText(try std.fmt.bufPrint(&expected, "ZW_ECHO:{s}", .{text}));
        return @intCast(clock.monotonicNs() - started);
    }
    fn terminal(self: *Frames, api: transfer.TransferEngine, id: transfer.EngineJobId) !transfer.EngineProgress {
        const deadline = clock.monotonicNs() + 15 * std.time.ns_per_s;
        var last: ?transfer.EngineProgress = null;
        while (clock.monotonicNs() < deadline) {
            try self.take();
            while (api.poll(api.ctx)) |event| {
                if (event.job != id) continue;
                last = event;
                if (event.state != .running and event.job_cleanup == .released) return event;
            }
            pause();
        }
        std.debug.print("SHARED_TIMEOUT {any}\n", .{last});
        return error.TransferTimeout;
    }
};

fn expectNoPartial(dir: std.Io.Dir) !void {
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| try std.testing.expect(!std.mem.endsWith(u8, entry.name, ".part"));
}

test "shared transfer native original connection keeps PTY responsive through actual SFTP EAGAIN upload download and cancellation" {
    var fixture = try Fixture.environment();
    if (std.c.getenv("ZEROWORK_SHARED_SFTP_SCENARIO")) |scenario| if (!std.mem.eql(u8, std.mem.span(scenario), "normal")) return error.SkipZigTest;
    var library = try ssh.Library.init();
    defer library.deinit();
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(1501), .generation = 1 };
    const binding: transfer.ServiceHandle = .{ .resource_owner = .{ .session = owner }, .origin_session = owner, .kind = .transfer, .binding_id = 1701, .binding_generation = 1 };
    const worker = try Worker.init(a, &library, .{ .host = "127.0.0.1", .port = fixture.port, .user = "fixture", .auth = .{ .password = "shared-fixture" }, .operation_key = .{ .owner = .{ .session = owner }, .operation_id = 1601, .attempt_id = 1 }, .host_key_observer = .{ .ctx = &fixture, .callback = Fixture.trust }, .rows = 40, .cols = 160 }, .{ .keepalive_sec = 0, .auto_reconnect = false, .connect_timeout_ms = 3000 });
    const thread = WorkerThread.start(a, worker) catch |err| {
        worker.deinit();
        return err;
    };
    const shared = try worker.transferService(binding);
    defer {
        fixture.signal("cancel-read-release") catch {};
        shared.requestClose();
        const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
        while (shared.closeReceipt() != .released and clock.monotonicNs() < deadline and !thread.hasFailed()) pause();
        shared.routingReleased(binding) catch {};
        thread.stopAndJoin();
        while (worker.releaseConnection() == .awaiting and clock.monotonicNs() < deadline) pause();
        if (worker.releaseConnection() != .released) @panic("shared native actual parent cleanup pending");
        thread.deinit();
    }
    const bytes = try a.alloc(u8, TextSlot.default_capacity);
    defer a.free(bytes);
    var frames: Frames = .{ .worker = worker, .thread = thread, .bytes = bytes };
    try frames.waitText("ZW_SHARED_READY");
    try std.testing.expect(fixture.trusted);
    try std.testing.expect(shared.backend.service_token.handle == null and shared.backend.service_token.socket_fd == -1);
    const api = shared.engine();
    var latency: [12]u64 = undefined;
    var sample: usize = 0;
    const started = clock.monotonicNs();
    const down = try api.open(api.ctx, .{ .session_id = @backingInt(owner.session_id), .transfer_binding = binding, .direction = .download, .sources = &.{"/source.bin"}, .remote_dir = "/", .local_dir = directory, .md5_check = true, .pacing_kbps = 128 });
    while (shared.read_bytes.load(.acquire) < 8192) {
        try frames.take();
        if (clock.monotonicNs() - started > 5 * std.time.ns_per_s) return error.NoActualSharedRead;
        pause();
    }
    for (0..6) |index| {
        var text: [40]u8 = undefined;
        latency[sample] = try frames.echo(try std.fmt.bufPrint(&text, "DOWN_{d}", .{index}));
        sample += 1;
    }
    const downloaded = try frames.terminal(api, down);
    try std.testing.expectEqual(transfer.EngineState.succeeded, downloaded.state);
    try std.testing.expectEqual(.passed, downloaded.verification.?.state);
    const data = try temporary.dir.readFileAlloc(io, "source.bin", a, .limited(200 * 1024));
    defer a.free(data);
    try std.testing.expectEqual(@as(usize, 96 * 1024 + 53), data.len);
    for (data, 0..) |value, index| try std.testing.expectEqual(@as(u8, @intCast((index * 29 + 17) % 251)), value);
    try expectNoPartial(temporary.dir);
    const download_elapsed = clock.monotonicNs() - started;
    const down_bytes = shared.read_bytes.load(.acquire);
    try std.testing.expect(download_elapsed + std.time.ns_per_ms >= @divFloor(@as(i128, down_bytes) * std.time.ns_per_s, 128 * 1024));

    const up = try api.open(api.ctx, .{ .session_id = @backingInt(owner.session_id), .transfer_binding = binding, .direction = .upload, .sources = &.{"source.bin"}, .remote_dir = "/", .local_dir = directory, .rename = "upload.bin", .md5_check = true, .pacing_kbps = 128 });
    const up_deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (shared.written_bytes.load(.acquire) == 0) {
        try frames.take();
        if (clock.monotonicNs() >= up_deadline) return error.NoActualSharedWrite;
        pause();
    }
    for (0..5) |index| {
        var text: [40]u8 = undefined;
        latency[sample] = try frames.echo(try std.fmt.bufPrint(&text, "UP_{d}", .{index}));
        sample += 1;
    }
    const uploaded = try frames.terminal(api, up);
    try std.testing.expectEqual(transfer.EngineState.succeeded, uploaded.state);
    try std.testing.expectEqual(.passed, uploaded.verification.?.state);

    const unlimited = try api.open(api.ctx, .{ .session_id = @backingInt(owner.session_id), .transfer_binding = binding, .direction = .download, .sources = &.{"/source.bin"}, .remote_dir = "/", .local_dir = directory, .rename = "unlimited.bin", .pacing_kbps = 0 });
    const unlimited_done = try frames.terminal(api, unlimited);
    try std.testing.expectEqual(transfer.EngineState.succeeded, unlimited_done.state);
    const unlimited_data = try temporary.dir.readFileAlloc(io, "unlimited.bin", a, .limited(200 * 1024));
    defer a.free(unlimited_data);
    try std.testing.expectEqualSlices(u8, data, unlimited_data);

    const cancelled = try api.open(api.ctx, .{ .session_id = @backingInt(owner.session_id), .transfer_binding = binding, .direction = .download, .sources = &.{"/cancel.bin"}, .remote_dir = "/", .local_dir = directory, .pacing_kbps = 128 });
    const cancel_deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (!try fixture.exists("cancel-read-blocked")) {
        try frames.take();
        if (clock.monotonicNs() >= cancel_deadline) return error.NoActualBlockedRead;
        pause();
    }
    api.cancel(api.ctx, cancelled);
    latency[sample] = try frames.echo("CANCEL_PENDING");
    sample += 1;
    while (api.poll(api.ctx)) |event| if (event.job == cancelled) try std.testing.expect(event.job_cleanup != .released);
    try fixture.signal("cancel-read-release");
    const stopped = try frames.terminal(api, cancelled);
    try std.testing.expectEqual(transfer.EngineState.cancelled, stopped.state);
    try expectNoPartial(temporary.dir);
    try std.testing.expectError(error.FileNotFound, temporary.dir.access(io, "cancel.bin", .{}));
    try std.testing.expect(shared.would_block_count.load(.acquire) > 0);
    std.mem.sort(u64, latency[0..sample], {}, std.sort.asc(u64));
    const p95 = latency[(sample * 95 + 99) / 100 - 1];
    std.debug.print("SHARED_NATIVE {{\"samples\":{d},\"echo_p95_ns\":{d},\"would_block_steps\":{d},\"read_bytes\":{d},\"written_bytes\":{d},\"download_elapsed_ns\":{d},\"cancel_released\":true,\"checksum\":\"passed\"}}\n", .{ sample, p95, shared.would_block_count.load(.acquire), shared.read_bytes.load(.acquire), shared.written_bytes.load(.acquire), download_elapsed });
    try std.testing.expect(p95 < 50 * std.time.ns_per_ms);

    // A paused shared transfer must export a value-owned checkpoint before
    // the service can retire its original routes and release the SFTP context.
    const to_pause = try api.open(api.ctx, .{ .session_id = @backingInt(owner.session_id), .transfer_binding = binding, .direction = .download, .sources = &.{"/source.bin"}, .remote_dir = "/", .local_dir = directory, .rename = "paused.bin", .pacing_kbps = 128 });
    const pause_deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    var confirmed: u64 = 0;
    while (confirmed < 8192) {
        try frames.take();
        while (api.poll(api.ctx)) |event| if (event.job == to_pause) {
            confirmed = @max(confirmed, event.done_bytes);
        };
        if (clock.monotonicNs() >= pause_deadline) return error.NoSharedPausePrefix;
        pause();
    }
    try api.pause.?(api.ctx, to_pause);
    const paused = try frames.terminal(api, to_pause);
    try std.testing.expectEqual(transfer.EngineState.paused, paused.state);
    var checkpoint = try shared.backend.exportPaused(to_pause);
    defer {
        if (checkpoint.describe() != null and checkpoint.cancel(io) != .released) @panic("shared native checkpoint cleanup pending");
        checkpoint.deinit() catch @panic("shared native checkpoint deinit pending");
    }
    const exported = checkpoint.describe().?;
    try std.testing.expectEqual(to_pause, exported.original_engine_job);
    try std.testing.expect(exported.spec.transfer_binding.?.eql(binding));
    try std.testing.expect(exported.spec.pacing_kbps == 128);
    try std.testing.expectEqual(@as(usize, 0), shared.backend.faultJobCount());
    shared.requestClose();
    const close_deadline = clock.monotonicNs() + 3 * std.time.ns_per_s;
    while (shared.closeReceipt() != .released) {
        try frames.take();
        if (clock.monotonicNs() >= close_deadline) return error.SftpContextReleaseTimeout;
        pause();
    }
    _ = try frames.echo("AFTER_SFTP_RELEASE");
    try std.testing.expect(!shared.canReleaseParent());
    try shared.routingReleased(binding);
    try std.testing.expect(checkpoint.cancel(io) == .released);
    try expectNoPartial(temporary.dir);
    std.debug.print("SHARED_RETAIN {{\"original_job\":{d},\"confirmed_prefix\":{d},\"exported_original_binding\":true,\"sftp_released_before_ssh\":true,\"checkpoint_cancel_released\":true}}\n", .{ to_pause, confirmed });
}

test "shared transfer native real original parent FIN preserves the paused checkpoint until explicit export" {
    var fixture = try Fixture.environment();
    const scenario = std.c.getenv("ZEROWORK_SHARED_SFTP_SCENARIO") orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, std.mem.span(scenario), "fin")) return error.SkipZigTest;
    var library = try ssh.Library.init();
    defer library.deinit();
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(2501), .generation = 1 };
    const binding: transfer.ServiceHandle = .{ .resource_owner = .{ .session = owner }, .origin_session = owner, .kind = .transfer, .binding_id = 2701, .binding_generation = 1 };
    const worker = try Worker.init(a, &library, .{ .host = "127.0.0.1", .port = fixture.port, .user = "fixture", .auth = .{ .password = "shared-fixture" }, .operation_key = .{ .owner = .{ .session = owner }, .operation_id = 2601, .attempt_id = 1 }, .host_key_observer = .{ .ctx = &fixture, .callback = Fixture.trust } }, .{ .keepalive_sec = 0, .auto_reconnect = false, .connect_timeout_ms = 3000 });
    const thread = WorkerThread.start(a, worker) catch |err| {
        worker.deinit();
        return err;
    };
    const shared = try worker.transferService(binding);
    defer {
        fixture.signal("cancel-read-release") catch {};
        shared.requestClose();
        const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
        while (!shared.backend.owner_done.load(.acquire) and clock.monotonicNs() < deadline) pause();
        shared.routingReleased(binding) catch {};
        thread.stopAndJoin();
        while (worker.releaseConnection() == .awaiting and clock.monotonicNs() < deadline) pause();
        if (worker.releaseConnection() != .released) @panic("shared FIN actual parent cleanup pending");
        thread.deinit();
    }
    const bytes = try a.alloc(u8, TextSlot.default_capacity);
    defer a.free(bytes);
    var frames: Frames = .{ .worker = worker, .thread = thread, .bytes = bytes };
    try frames.waitText("ZW_SHARED_READY");
    const api = shared.engine();
    const id = try api.open(api.ctx, .{ .session_id = @backingInt(owner.session_id), .transfer_binding = binding, .direction = .download, .sources = &.{"/cancel.bin"}, .remote_dir = "/", .local_dir = directory, .pacing_kbps = 128 });
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    var confirmed: u64 = 0;
    while (!try fixture.exists("cancel-read-blocked") or confirmed == 0) {
        try frames.take();
        while (api.poll(api.ctx)) |event| if (event.job == id) {
            confirmed = @max(confirmed, event.done_bytes);
        };
        if (clock.monotonicNs() >= deadline) return error.NoSharedFinPrefix;
        pause();
    }
    try std.testing.expect(shared.closeReceipt() == .awaiting);
    try fixture.signal("trigger-fin");
    while (!try fixture.exists("fin-sent")) {
        if (clock.monotonicNs() >= deadline) return error.NoActualPeerFin;
        pause();
    }
    try fixture.signal("cancel-read-release");
    var paused: ?transfer.EngineProgress = null;
    const pause_deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (clock.monotonicNs() < pause_deadline) {
        while (api.poll(api.ctx)) |event| {
            if (event.job == id) paused = event;
        }
        if (paused != null and paused.?.state == .paused and paused.?.job_cleanup == .released and shared.parent_released.load(.acquire)) break;
        pause();
    }
    try std.testing.expect(paused != null);
    try std.testing.expectEqual(transfer.EngineState.paused, paused.?.state);
    try std.testing.expectEqual(transfer.JobCleanup.released, paused.?.job_cleanup);
    try std.testing.expect(shared.parent_released.load(.acquire));
    try std.testing.expect(worker.session.handle == null and worker.session.socket_fd == -1);
    try std.testing.expectEqual(@as(usize, 1), shared.backend.faultJobCount());
    try std.testing.expectEqual(ssh.ReleaseReceipt.awaiting, thread.reconnectSnapshot().cleanup);
    var checkpoint = try shared.backend.exportPaused(id);
    defer {
        if (checkpoint.describe() != null and checkpoint.cancel(io) != .released) @panic("shared FIN checkpoint cleanup pending");
        checkpoint.deinit() catch @panic("shared FIN checkpoint deinit pending");
    }
    const exported = checkpoint.describe().?;
    try std.testing.expectEqual(id, exported.original_engine_job);
    try std.testing.expect(exported.spec.transfer_binding.?.eql(binding));
    try std.testing.expect(!shared.canReleaseParent());
    try std.testing.expectEqual(ssh.ReleaseReceipt.awaiting, thread.reconnectSnapshot().cleanup);
    try std.testing.expectError(error.TransferCleanupPending, shared.prepareReplacement());
    try std.testing.expectError(error.Busy, shared.deinitLocal());
    var stale_binding = binding;
    stale_binding.binding_generation += 1;
    try std.testing.expectError(error.StaleBinding, shared.routingReleased(stale_binding));
    try shared.routingReleased(binding);
    try shared.prepareReplacement();
    const close_deadline = clock.monotonicNs() + 3 * std.time.ns_per_s;
    while (thread.reconnectSnapshot().cleanup != .released) {
        if (clock.monotonicNs() >= close_deadline) return error.ParentReleaseAwaitedExport;
        pause();
    }
    try std.testing.expect(checkpoint.cancel(io) == .released);
    try expectNoPartial(temporary.dir);
    std.debug.print("SHARED_FIN {{\"confirmed_prefix\":{d},\"actual_parent_released\":true,\"checkpoint_held_release_gate\":true,\"exported_original_binding\":true,\"explicit_checkpoint_cancel_released\":true}}\n", .{confirmed});
}
