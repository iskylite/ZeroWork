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

const ro = @import("proto/ssh/sftp_readonly.zig");
const Mailbox = @import("proto/ssh/shared_readonly_mailbox.zig").Mailbox;
fn result(mailbox: *Mailbox) !ro.OwnedResult {
    const deadline = clock.monotonicNs() + 8 * std.time.ns_per_s;
    while (clock.monotonicNs() < deadline) {
        if (mailbox.poll()) |value| return value;
        pause();
    }
    return error.ResultTimeout;
}
test "shared readonly native actual bytes list cancellation and parent FIN" {
    var fixture = try Fixture.environment();
    var library = try ssh.Library.init();
    defer library.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(2501), .generation = 3 };
    const worker = try Worker.init(a, &library, .{ .host = "127.0.0.1", .port = fixture.port, .user = "fixture", .auth = .{ .password = "shared-fixture" }, .operation_key = .{ .owner = .{ .session = owner }, .operation_id = 2601, .attempt_id = 1 }, .host_key_observer = .{ .ctx = &fixture, .callback = Fixture.trust }, .rows = 40, .cols = 160 }, .{ .keepalive_sec = 0, .auto_reconnect = false, .connect_timeout_ms = 3000 });
    const thread = try WorkerThread.start(a, worker);
    const transfer_binding: transfer.ServiceHandle = .{ .resource_owner = .{ .session = owner }, .origin_session = owner, .kind = .transfer, .binding_id = 2702, .binding_generation = 1 };
    const shared = try worker.transferService(transfer_binding);
    const provider = try worker.readonlyProvider();
    const endpoint: ro.EndpointRef = .{ .binding_id = 2701, .binding_generation = 1, .resource_owner = .{ .session = owner }, .origin_session = owner };
    const mailbox = try provider.attach(provider.context, endpoint, .{ .owner = .{ .session = owner }, .operation_id = 2602 });
    defer {
        mailbox.requestClose();
        fixture.signal("cancel-read-release") catch {};
        const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
        while (mailbox.closeReceipt() != .released and clock.monotonicNs() < deadline) pause();
        mailbox.deinit() catch @panic("mailbox cleanup pending");
        shared.requestClose();
        while (shared.closeReceipt() != .released and clock.monotonicNs() < deadline and !thread.hasFailed()) pause();
        shared.routingReleased(transfer_binding) catch {};
        thread.stopAndJoin();
        while (worker.releaseConnection() == .awaiting and clock.monotonicNs() < deadline) pause();
        if (worker.releaseConnection() != .released) @panic("parent cleanup pending");
        thread.deinit();
    }
    var ready = try result(mailbox);
    defer ready.deinit();
    try std.testing.expect(ready.value.body == .ready);
    const bytes = try a.alloc(u8, TextSlot.default_capacity);
    defer a.free(bytes);
    var frames: Frames = .{ .worker = worker, .thread = thread, .bytes = bytes };
    try frames.waitText("ZW_SHARED_READY");
    const api = shared.engine();
    const down = try api.open(api.ctx, .{ .session_id = @backingInt(owner.session_id), .transfer_binding = transfer_binding, .direction = .download, .sources = &.{"/source.bin"}, .remote_dir = "/", .local_dir = directory, .md5_check = true, .pacing_kbps = 128 });
    const transfer_deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (shared.read_bytes.load(.acquire) == 0) {
        if (clock.monotonicNs() >= transfer_deadline) return error.NoTransferProgress;
        pause();
    }
    var key: ro.OperationKey = .{ .owner = .{ .session = owner }, .operation_id = 2603 };
    try mailbox.submit(key, .{ .endpoint = endpoint, .request_id = key.operation_id, .path = "/text.txt", .action = .{ .read_text = .{} } });
    var text = try result(mailbox);
    defer text.deinit();
    if (text.value.body != .text) {
        std.debug.print("READ_RESULT {any}\n", .{text.value.body});
        return error.NoText;
    }
    try std.testing.expectEqual(@as(usize, 4096), text.value.body.text.text.len);
    try std.testing.expectEqual(@as(usize, 4097), text.value.body.text.read_bytes);
    try std.testing.expect(text.value.body.text.truncated);
    for (text.value.body.text.text) |byte| try std.testing.expectEqual(@as(u8, 'x'), byte);
    _ = try frames.echo("during-readonly\n");
    key.operation_id += 1;
    try mailbox.submit(key, .{ .endpoint = endpoint, .request_id = key.operation_id, .path = "/", .action = .{ .list = .{ .page_entries = 2 } } });
    var count: usize = 0;
    while (true) {
        var page = try result(mailbox);
        defer page.deinit();
        if (page.value.body != .page) {
            std.debug.print("LIST_RESULT {any}\n", .{page.value.body});
            return error.NoPage;
        }
        count += page.value.body.page.entries.len;
        if (page.value.final) break;
    }
    try std.testing.expect(count >= 3);
    const downloaded = try frames.terminal(api, down);
    try std.testing.expectEqual(transfer.EngineState.succeeded, downloaded.state);
    try std.testing.expectEqual(.passed, downloaded.verification.?.state);
    const data = try temporary.dir.readFileAlloc(io, "source.bin", a, .limited(200 * 1024));
    defer a.free(data);
    try std.testing.expectEqual(@as(usize, 96 * 1024 + 53), data.len);
    for (data, 0..) |value, index| try std.testing.expectEqual(@as(u8, @intCast((index * 29 + 17) % 251)), value);
    key.operation_id += 1;
    try mailbox.submit(key, .{ .endpoint = endpoint, .request_id = key.operation_id, .path = "/text.txt", .action = .{ .read_text = .{ .max_bytes = 65536 } } });
    const cancel_deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (!try fixture.exists("cancel-read-blocked")) {
        if (clock.monotonicNs() > cancel_deadline) return error.CancelGateTimeout;
        pause();
    }
    try std.testing.expect(mailbox.cancel(key));
    try std.testing.expect(mailbox.poll() == null);
    _ = try frames.echo("cancel-pending\n");
    try fixture.signal("cancel-read-release");
    var cancelled = try result(mailbox);
    defer cancelled.deinit();
    try std.testing.expect(cancelled.value.body == .cancelled and cancelled.value.cleanup == .released);
    key.operation_id += 1;
    try std.testing.expectError(error.InvalidReadLimit, mailbox.submit(key, .{ .endpoint = endpoint, .request_id = key.operation_id, .path = "/text.txt", .action = .{ .read_text = .{ .max_bytes = 65537 } } }));
    var stale = endpoint;
    stale.binding_generation += 1;
    try std.testing.expectError(error.StaleBinding, mailbox.submit(key, .{ .endpoint = stale, .request_id = key.operation_id, .path = "/", .action = .stat }));
    if (std.mem.eql(u8, std.mem.span(std.c.getenv("ZEROWORK_SHARED_SFTP_SCENARIO").?), "fin")) {
        key.operation_id += 1;
        try mailbox.submit(key, .{ .endpoint = endpoint, .request_id = key.operation_id, .path = "/text.txt", .action = .{ .read_text = .{ .max_bytes = 65536 } } });
        const fin_deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
        while (!try fixture.exists("final-read-blocked")) {
            if (clock.monotonicNs() > fin_deadline) return error.FinGateTimeout;
            pause();
        }
        try fixture.signal("trigger-fin");
        var failed = try result(mailbox);
        defer failed.deinit();
        try std.testing.expect(failed.value.body == .failure);
    }
    std.debug.print("SHARED_READONLY_VERIFIED actual4096=true probe4097=true list={d} cancel=true concurrent_transfer_checksum=true original_session=true\n", .{count});
}
