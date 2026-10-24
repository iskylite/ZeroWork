//! Opt-in, no-GUI actual libssh2 READ/FIN ordering regression. No pause() or
//! transportFailed() is injected; only the real peer closes its active socket.
const std = @import("std");
const runtime = @import("host/file_transfer_runtime.zig");
const sessions = @import("host/session_host.zig");
const identity = @import("host/identity.zig");
const factory_mod = @import("host/file_route_factory.zig");
const files = @import("host/file_binding_host.zig");
const ssh = @import("proto/ssh/session.zig");
const clock = @import("platform/realtime.zig");
const transfer = @import("transfer/manager.zig");
const engine_mod = @import("transfer/sftp_engine.zig");
const a = std.testing.allocator;
const io = std.testing.io;

fn pause() void {
    var unused: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&unused, 0, 2);
}
const Fixture = struct {
    port: u16,
    controls: []const u8,
    fingerprint: []const u8,
    trusted: std.atomic.Value(bool) = .init(false),

    fn fromEnvironment() !Fixture {
        const raw = std.c.getenv("ZEROWORK_SFTP_ACTIVE_FIN_PORT") orelse return error.SkipZigTest;
        return .{ .port = try std.fmt.parseInt(u16, std.mem.span(raw), 10), .controls = std.mem.span(std.c.getenv("ZEROWORK_SFTP_ACTIVE_FIN_CONTROLS") orelse return error.MissingFixtureControls), .fingerprint = std.mem.span(std.c.getenv("ZEROWORK_SFTP_ACTIVE_FIN_FINGERPRINT") orelse return error.MissingFingerprint) };
    }
    fn trust(raw: *anyopaque, host: []const u8, port: u16, value: ssh.HostKeyInfo) ssh.HostKeyDecision {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (std.mem.eql(u8, host, "127.0.0.1") and port == self.port and value.status == .unknown and std.mem.eql(u8, value.fingerprint, self.fingerprint)) {
            self.trusted.store(true, .release);
            return .trust_once;
        }
        return .reject_unknown;
    }
    fn signal(self: Fixture, name: []const u8) !void {
        const path = try std.fs.path.join(a, &.{ self.controls, name });
        defer a.free(path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "ready\n" });
    }
    fn wait(self: Fixture, name: []const u8) !void {
        const path = try std.fs.path.join(a, &.{ self.controls, name });
        defer a.free(path);
        const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
        while (true) {
            std.Io.Dir.cwd().access(io, path, .{}) catch |err| {
                if (err != error.FileNotFound) return err;
                if (clock.monotonicNs() >= deadline) return error.PeerSignalTimeout;
                pause();
                continue;
            };
            return;
        }
    }
};

const Partial = struct { path: []u8, size: u64, inode: std.Io.File.INode };
fn ownPartial(directory: []const u8) !?Partial {
    var dir = try std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".part")) {
            const path = try std.fs.path.join(a, &.{ directory, entry.name });
            errdefer a.free(path);
            const attrs = try std.Io.Dir.cwd().statFile(io, path, .{});
            return .{ .path = path, .size = attrs.size, .inode = attrs.inode };
        }
    }
    return null;
}

test "file transfer active FIN native keeps real in-flight partial as an exportable paused checkpoint" {
    var fixture = try Fixture.fromEnvironment();
    var library = try ssh.Library.init();
    defer library.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    const known = try std.fs.path.join(a, &.{ directory, "known_hosts" });
    defer a.free(known);
    var factory: factory_mod.SourceFactory = .{ .library = &library, .known_hosts_path = known, .timeout_ms = 3000, .host_key_observer = .{ .ctx = &fixture, .callback = Fixture.trust } };
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(501), .generation = 1 };
    const key: sessions.OperationKey = .{ .owner = .{ .session = owner }, .operation_id = 701, .attempt_id = 1 };
    const binding: sessions.ServiceHandle = .{ .resource_owner = .{ .session = owner }, .origin_session = owner, .kind = .transfer, .binding_id = 801, .binding_generation = 1 };
    const source: files.Source = .{ .owner = owner, .create_key = key, .open_key = key, .spec = .{ .saved = .{ .connection_id = @fromBackingInt(901), .config_revision = 1, .protocol = .ssh, .immutable_config = .{ .endpoint = .{ .host = "127.0.0.1", .port = fixture.port, .user = "aux" }, .auth = .{ .password = "fault-fixture" } } } } };
    const api = factory.interface();
    const connector = try api.prepare(api.context, source);
    const value = runtime.Runtime.startAuxiliary(a, binding, connector) catch |err| {
        api.discard(api.context, connector);
        return err;
    };
    defer {
        fixture.signal("aux-1.read-release") catch {};
        // Explicit cleanup is after all observations. It must not be mistaken
        // for the tested fault retain path or used to satisfy its assertions.
        value.requestRetainedCancel() catch {};
        const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
        while (!value.done.load(.acquire) and clock.monotonicNs() < deadline) pause();
        if (!value.done.load(.acquire)) @panic("active FIN cleanup remains pinned");
        value.deinit() catch @panic("active FIN Runtime cleanup not released");
    }
    const ready_deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (value.state() != .ready) {
        if (clock.monotonicNs() >= ready_deadline) return error.RuntimeNotReady;
        pause();
    }
    const engine = value.engine();
    const id = try engine.open(engine.ctx, .{ .transfer_binding = binding, .session_id = @backingInt(owner.session_id), .sources = &.{"/retained-fixture.bin"}, .direction = .download, .remote_dir = "/", .local_dir = directory, .md5_check = true });
    try fixture.wait("aux-1.read-entered");
    const data_deadline = clock.monotonicNs() + std.time.ns_per_s;
    var confirmed: u64 = 0;
    while (confirmed < 32768) {
        while (engine.poll(engine.ctx)) |event| confirmed = @max(confirmed, event.done_bytes);
        if (clock.monotonicNs() >= data_deadline) return error.NoActualConfirmedPrefix;
        pause();
    }
    const before = (try ownPartial(directory)) orelse return error.NoActualPartial;
    defer a.free(before.path);
    try std.testing.expect(before.size >= 32768 and before.size < 2 * 1024 * 1024 + 17);
    std.debug.print("ACTIVE_FIN_BEFORE {{\"engine_job\":{d},\"confirmed\":{d},\"partial_bytes\":{d},\"pause_requested\":false,\"transport_fault_injected\":false}}\n", .{ id, confirmed, before.size });
    try fixture.signal("aux-1.fin");
    try fixture.wait("aux-1.fin-sent");
    const deadline = clock.monotonicNs() + 3 * std.time.ns_per_s;
    var last: ?transfer.EngineProgress = null;
    while (clock.monotonicNs() < deadline) {
        while (engine.poll(engine.ctx)) |event| {
            last = event;
            if (event.state != .running) std.debug.print("ACTIVE_FIN_EVENT {{\"state\":\"{s}\",\"cleanup\":\"{s}\",\"failure\":\"{s}\",\"bytes\":{d},\"runtime_observed_fin\":{}}}\n", .{ @tagName(event.state), @tagName(event.job_cleanup), if (event.failure) |failure| @tagName(failure) else "none", event.done_bytes, value.transportFailure() != null });
        }
        if (last != null and last.?.state != .running and value.backend.owner_done.load(.acquire) and value.transportFailure() != null) break;
        pause();
    }
    const after = try std.Io.Dir.cwd().statFile(io, before.path, .{});
    const exportable = value.backend.canExportPaused(id);
    var checkpoint: ?engine_mod.OwnedCheckpoint = value.backend.exportPaused(id) catch null;
    const cp_present = checkpoint != null;
    if (checkpoint) |*cp| {
        const Cancel = struct {
            fn run(saved: *engine_mod.OwnedCheckpoint) void {
                std.debug.assert(saved.cancel(std.testing.io) == .released);
            }
        };
        const cleanup_thread = try std.Thread.spawn(.{}, Cancel.run, .{cp});
        cleanup_thread.join();
        try cp.deinit();
    }
    std.debug.print("ACTIVE_FIN_AFTER {{\"state\":\"{s}\",\"cleanup\":\"{s}\",\"runtime_observed_fin\":{},\"owner_done\":{},\"partial_same_inode\":{},\"partial_bytes\":{d},\"can_export_paused\":{},\"checkpoint\":{}}}\n", .{ if (last) |event| @tagName(event.state) else "none", if (last) |event| @tagName(event.job_cleanup) else "none", value.transportFailure() != null, value.backend.owner_done.load(.acquire), before.inode == after.inode, after.size, exportable, cp_present });
    try std.testing.expect(last != null);
    try std.testing.expectEqual(.paused, last.?.state);
    try std.testing.expectEqual(.released, last.?.job_cleanup);
    try std.testing.expect(exportable and cp_present);
    try std.testing.expectEqual(before.inode, after.inode);
}
