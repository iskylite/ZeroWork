//! Opt-in production libssh2 resume checks. e2e/sftp_resume_loopback.py owns
//! the read-only loopback peer and its deterministic READ/mutation gates.
const std = @import("std");
const ssh = @import("proto/ssh/session.zig");
const transfer = @import("transfer/sftp_engine.zig");
const manager = @import("transfer/manager.zig");
const monotonicNs = @import("platform/realtime.zig").monotonicNs;

const allocator = std.testing.allocator;
const io = std.testing.io;
const source_size = 8 * transfer.chunk_bytes + 17;
const Mode = enum { unchanged, mtime, prefix };

const Fixture = struct {
    port: u16,
    fingerprint: []const u8,
    controls: []const u8,
    accepted: bool = false,

    fn fromEnvironment() !Fixture {
        const port = std.c.getenv("ZEROWORK_SFTP_RESUME_PORT") orelse return error.SkipZigTest;
        return .{
            .port = try std.fmt.parseInt(u16, std.mem.span(port), 10),
            .fingerprint = std.mem.span(std.c.getenv("ZEROWORK_SFTP_RESUME_FINGERPRINT") orelse return error.MissingFixtureFingerprint),
            .controls = std.mem.span(std.c.getenv("ZEROWORK_SFTP_RESUME_CONTROL_DIR") orelse return error.MissingFixtureControls),
        };
    }

    fn trust(raw: *anyopaque, host: []const u8, port: u16, info: ssh.HostKeyInfo) ssh.HostKeyDecision {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (std.mem.eql(u8, host, "127.0.0.1") and port == self.port and info.status == .unknown and
            std.mem.eql(u8, info.fingerprint, self.fingerprint))
        {
            self.accepted = true;
            return .trust_once;
        }
        return .reject_unknown;
    }

    fn connect(self: *Fixture, library: *ssh.Library) !ssh.Session {
        var session = try ssh.Session.connect(library, .{
            .host = "127.0.0.1",
            .port = self.port,
            .user = "fixture",
            .auth = .{ .password = "resume-fixture" },
            .host_key_observer = .{ .ctx = self, .callback = trust },
            .operation_key = .{ .owner = .app, .operation_id = 603 },
            .open_shell = false,
            .connect_timeout_ms = 5_000,
        });
        errdefer session.close();
        try std.testing.expect(self.accepted);
        try std.testing.expect(session.channel == null);
        session.setBlocking();
        return session;
    }

    fn marker(self: Fixture, name: []const u8, suffix: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/{s}.{s}", .{ self.controls, name, suffix });
    }

    fn signal(self: Fixture, name: []const u8, suffix: []const u8) !void {
        const path = try self.marker(name, suffix);
        defer allocator.free(path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "ready\n" });
    }

    fn wait(self: Fixture, name: []const u8, suffix: []const u8) !void {
        const path = try self.marker(name, suffix);
        defer allocator.free(path);
        const deadline = monotonicNs() + 10 * std.time.ns_per_s;
        while (true) {
            std.Io.Dir.cwd().access(io, path, .{}) catch |err| {
                if (err != error.FileNotFound) return err;
                if (monotonicNs() >= deadline) return error.FixtureGateTimeout;
                pause();
                continue;
            };
            return;
        }
    }
};

fn pause() void {
    var descriptors: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&descriptors, 0, 2);
}

fn awaitOutcome(engine: *transfer.SftpEngine, id: manager.EngineJobId, state: manager.EngineState) !manager.EngineProgress {
    const deadline = monotonicNs() + 12 * std.time.ns_per_s;
    while (monotonicNs() < deadline) {
        while (engine.poll()) |event| {
            if (event.job != id or event.state == .running or event.job_cleanup == .awaiting) continue;
            if (event.state != state or event.job_cleanup != .released) {
                std.debug.print("UNEXPECTED_NATIVE_EVENT id={d} state={s} cleanup={s} failure={s}\n", .{ id, @tagName(event.state), @tagName(event.job_cleanup), if (event.failure) |failure| @tagName(failure) else "none" });
                return error.UnexpectedNativeOutcome;
            }
            return event;
        }
        pause();
    }
    return error.NativeOutcomeTimeout;
}

fn awaitIdle(engine: *transfer.SftpEngine) !void {
    const deadline = monotonicNs() + 5 * std.time.ns_per_s;
    while (!engine.detachIfIdle()) {
        if (monotonicNs() >= deadline) return error.NativeOwnerNotReleased;
        pause();
    }
}

fn closeSession(session: *ssh.Session) !void {
    const deadline = monotonicNs() + 5 * std.time.ns_per_s;
    while (true) {
        switch (session.closeReceipt()) {
            .released => break,
            .unknown => return error.SessionCleanupUnknown,
            .awaiting => if (monotonicNs() >= deadline) return error.SessionCleanupTimeout,
        }
        pause();
    }
    try std.testing.expect(session.handle == null and session.sftp == null and session.channel == null);
    try std.testing.expectEqual(@as(c_int, -1), session.socket_fd);
}

fn runResume(mode: Mode) !void {
    var fixture = try Fixture.fromEnvironment();
    const name = @tagName(mode);
    var library = try ssh.Library.init();
    defer library.deinit();
    var session = try fixture.connect(&library);
    defer session.close();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    const engine = try transfer.SftpEngine.init(allocator);
    defer {
        fixture.signal(name, "release") catch {};
        engine.deinit();
    }
    engine.attachSession(&session);
    const first = try engine.open(.{ .session_id = 603, .direction = .download, .sources = &.{name}, .remote_dir = "/", .local_dir = directory });
    try fixture.wait(name, "read-entered");
    try engine.pause(first);
    try fixture.signal(name, "pause-requested");
    // The peer still holds the native READ; a command acknowledgement alone
    // must not become a quiescent release receipt.
    while (engine.poll()) |event| {
        try std.testing.expect(!(event.job == first and event.state == .paused and event.job_cleanup == .released));
    }
    try std.testing.expect(!engine.canResume(first));
    try std.testing.expect(!engine.detachIfIdle());
    try fixture.signal(name, "release");
    const paused = try awaitOutcome(engine, first, .paused);
    try std.testing.expect(paused.failure == null);
    try std.testing.expect(paused.done_bytes > 0 and paused.done_bytes < source_size);
    try std.testing.expect(engine.canResume(first));
    const retained = (try engine.retainedTemp(allocator, first)) orelse return error.MissingRetainedTemp;
    defer allocator.free(retained);
    const before = try std.Io.Dir.cwd().statFile(io, retained, .{});
    try std.testing.expectEqual(paused.done_bytes, before.size);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, name, .{}));
    if (mode != .unchanged) {
        try fixture.signal(name, "mutate");
        try fixture.wait(name, "mutated");
    }
    const second = try engine.resumeJob(first);
    try std.testing.expect(second != first);
    try std.testing.expect(!engine.canResume(first));
    engine.cancel(first); // stale attempt cannot cancel the accepted successor
    if (mode == .unchanged) {
        const complete = try awaitOutcome(engine, second, .succeeded);
        try std.testing.expect(complete.failure == null);
        try std.testing.expectEqual(@as(u64, source_size), complete.done_bytes);
        const actual = try tmp.dir.readFileAlloc(io, name, allocator, .limited(source_size + 1));
        defer allocator.free(actual);
        try std.testing.expectEqual(@as(usize, source_size), actual.len);
        var expected: [source_size]u8 = undefined;
        for (&expected, 0..) |*byte, index| byte.* = @intCast(33 + index % 89);
        var expected_hash: [32]u8 = undefined;
        var actual_hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&expected, &expected_hash, .{});
        std.crypto.hash.sha2.Sha256.hash(actual, &actual_hash, .{});
        try std.testing.expectEqualSlices(u8, &expected_hash, &actual_hash);
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, retained, .{}));
        try awaitIdle(engine);
        try closeSession(&session);
        std.debug.print("RESUME_NATIVE {{\"case\":\"{s}\",\"passed\":true,\"old_id\":{d},\"new_id\":{d},\"paused_bytes\":{d},\"bytes\":{d},\"sha256\":\"{s}\",\"temp_removed\":true,\"session_released\":true}}\n", .{ name, first, second, paused.done_bytes, actual.len, std.fmt.bytesToHex(actual_hash, .lower) });
    } else {
        const rejected = try awaitOutcome(engine, second, .paused);
        try std.testing.expectEqual(manager.Failure.conflict, rejected.failure.?);
        const after = try std.Io.Dir.cwd().statFile(io, retained, .{});
        try std.testing.expectEqual(before.inode, after.inode);
        try std.testing.expectEqual(before.size, after.size);
        const still_retained = (try engine.retainedTemp(allocator, second)) orelse return error.LostRejectedTemp;
        defer allocator.free(still_retained);
        try std.testing.expectEqualStrings(retained, still_retained);
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, name, .{}));
        engine.cancel(second);
        _ = try awaitOutcome(engine, second, .cancelled);
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, retained, .{}));
        try awaitIdle(engine);
        try closeSession(&session);
        std.debug.print("RESUME_NATIVE {{\"case\":\"{s}\",\"passed\":true,\"old_id\":{d},\"new_id\":{d},\"paused_bytes\":{d},\"failure\":\"conflict\",\"same_temp_preserved\":true,\"cancel_removed_temp\":true,\"session_released\":true}}\n", .{ name, first, second, paused.done_bytes });
    }
}

test "sftp resume native loopback pause release and exact checkpoint resume hash" {
    try runResume(.unchanged);
}

test "sftp resume native loopback changed mtime retains cancellable checkpoint" {
    try runResume(.mtime);
}

test "sftp resume native loopback same metadata changed prefix retains cancellable checkpoint" {
    try runResume(.prefix);
}

test "sftp resume native loopback append offset zero never creates missing destination" {
    var fixture = try Fixture.fromEnvironment();
    var library = try ssh.Library.init();
    defer library.deinit();
    var session = try fixture.connect(&library);
    defer session.close();
    try std.testing.expectError(error.SftpOpenFailed, session.sftpOpenAppend("/missing-append-probe", 0));
    try std.testing.expectError(error.FileNotFound, session.sftpStat("/missing-append-probe", true));
    try closeSession(&session);
    std.debug.print("RESUME_NATIVE {{\"case\":\"append_zero_missing\",\"passed\":true,\"open_rejected\":true,\"missing_after_probe\":true,\"session_released\":true}}\n", .{});
}
