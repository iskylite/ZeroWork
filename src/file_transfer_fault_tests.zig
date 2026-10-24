//! Deterministic in-flight IO regression for the real SftpEngine fault gate.
//! Metadata/READ/CLOSE run on its sole worker; only local temporary data is written.
const std = @import("std");
const engine_mod = @import("transfer/sftp_engine.zig");
const manager = @import("transfer/manager.zig");
const ssh = @import("proto/ssh/session.zig");
const clock = @import("platform/realtime.zig");
const OpenRead = @FieldType(@FieldType(engine_mod.SftpEngine, "remote_files"), "open_read");
const Purpose = @typeInfo(@typeInfo(OpenRead).pointer.child).@"fn".param_types[3].?;

fn pause() void {
    var unused: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&unused, 0, 2);
}
fn await(flag: *const std.atomic.Value(bool)) !void {
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (!flag.load(.acquire)) {
        if (clock.monotonicNs() >= deadline) return error.ControlledIoTimeout;
        pause();
    }
}
const Peer = struct {
    caller: std.Thread.Id,
    io_owner: ?std.Thread.Id = null,
    wrong_thread: std.atomic.Value(bool) = .init(false),
    blocked: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
    active: bool = false,
    purpose: Purpose = .fingerprint,
    offset: usize = 0,
    metadata: std.atomic.Value(usize) = .init(0),
    closes: std.atomic.Value(usize) = .init(0),
    const length = 2 * 32768 + 17;
    fn of(raw: ?*anyopaque) *Peer {
        return @ptrCast(@alignCast(raw.?));
    }
    fn check(self: *Peer) void {
        const id = std.Thread.getCurrentId();
        if (id == self.caller or (self.io_owner != null and self.io_owner.? != id)) self.wrong_thread.store(true, .release);
        if (self.io_owner == null) self.io_owner = id;
    }
    fn attrs() ssh.SftpAttributes {
        return .{ .kind = .file, .size = length, .modified_at = 1700000000 };
    }
    fn size(raw: ?*anyopaque, _: *ssh.Session, _: [:0]const u8) !u64 {
        const self = of(raw);
        self.check();
        _ = self.metadata.fetchAdd(1, .release);
        return length;
    }
    fn stat(raw: ?*anyopaque, _: *ssh.Session, _: [:0]const u8) !ssh.SftpAttributes {
        of(raw).check();
        return attrs();
    }
    fn open(raw: ?*anyopaque, _: *ssh.Session, _: [:0]const u8, purpose: Purpose) !ssh.SftpHandle {
        const self = of(raw);
        self.check();
        std.debug.assert(!self.active);
        self.active = true;
        self.purpose = purpose;
        self.offset = 0;
        return .{ .handle = @ptrCast(self) };
    }
    fn statHandle(raw: ?*anyopaque, _: *ssh.Session, _: *ssh.SftpHandle) !ssh.SftpAttributes {
        of(raw).check();
        return attrs();
    }
    fn read(raw: ?*anyopaque, _: *ssh.SftpHandle, bytes: []u8) !usize {
        const self = of(raw);
        self.check();
        if (self.purpose == .transfer and self.offset >= 32768 and !self.release.load(.acquire)) {
            self.blocked.store(true, .release);
            try await(&self.release);
        }
        const count = @min(bytes.len, length - self.offset);
        for (bytes[0..count], self.offset..) |*value, index| value.* = @intCast(33 + index % 89);
        self.offset += count;
        return count;
    }
    fn close(raw: ?*anyopaque, _: *ssh.SftpHandle) ssh.SftpCloseResult {
        const self = of(raw);
        self.check();
        self.active = false;
        _ = self.closes.fetchAdd(1, .release);
        return .{ .receipt = .released, .consumed = true };
    }
    fn releaseContext(raw: ?*anyopaque, _: *ssh.Session) ssh.ReleaseReceipt {
        of(raw).check();
        return .released;
    }
};

test "file transfer fault active READ retains original IO owner until paused export and explicit cancel" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    var peer: Peer = .{ .caller = std.Thread.getCurrentId() };
    const engine = try engine_mod.SftpEngine.init(std.testing.allocator);
    defer {
        peer.release.store(true, .release);
        engine.deinit();
    }
    var session: ssh.Session = .{};
    engine.attachSession(&session);
    engine.remote_metadata = .{ .context = &peer, .size = Peer.size, .stat = Peer.stat };
    engine.remote_files = .{ .context = &peer, .open_read = Peer.open, .stat_handle = Peer.statHandle, .read = Peer.read, .close = Peer.close, .release = Peer.releaseContext };
    const id = try engine.open(.{ .direction = .download, .sources = &.{"a"}, .remote_dir = "/frozen", .local_dir = directory });
    try await(&peer.blocked);
    const before = peer.metadata.load(.acquire);
    engine.transportFailed(); // Runtime's observer performs memory-only handoff.
    try std.testing.expectEqual(before, peer.metadata.load(.acquire));
    try std.testing.expect(!engine.canResume(id) and !engine.canExportPaused(id));
    try std.testing.expect(!engine.detachIfIdle());
    try std.testing.expectError(error.TransferTransportClosed, engine.open(.{ .direction = .download, .sources = &.{"must-not-stat"}, .remote_dir = "/frozen", .local_dir = directory }));
    try std.testing.expectEqual(before, peer.metadata.load(.acquire));
    peer.release.store(true, .release);
    try await(&engine.owner_done);
    var outcome: ?manager.EngineProgress = null;
    while (engine.poll()) |event| outcome = event;
    try std.testing.expect(outcome != null);
    try std.testing.expectEqual(.paused, outcome.?.state);
    try std.testing.expectEqual(.released, outcome.?.job_cleanup);
    try std.testing.expectEqual(@as(u64, 32768), outcome.?.done_bytes);
    try std.testing.expect(engine.canExportPaused(id));
    try std.testing.expect(!engine.canResume(id));
    try std.testing.expect(!peer.wrong_thread.load(.acquire) and !peer.active);
    try std.testing.expectEqual(@as(usize, 2), peer.closes.load(.acquire));
    var checkpoint = try engine.exportPaused(id);
    const info = checkpoint.describe().?;
    const path = try std.testing.allocator.dupe(u8, info.temp_path.?);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqual(info.done_bytes, (try std.Io.Dir.cwd().statFile(std.testing.io, path, .{})).size);
    try std.testing.expect(engine.detachIfIdle());
    try std.testing.expectError(error.Busy, checkpoint.deinit());
    const Cancel = struct {
        fn run(cp: *engine_mod.OwnedCheckpoint) void {
            std.debug.assert(cp.cancel(std.testing.io) == .released);
        }
    };
    const thread = try std.Thread.spawn(.{}, Cancel.run, .{&checkpoint});
    thread.join();
    try checkpoint.deinit();
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, path, .{}));
}
