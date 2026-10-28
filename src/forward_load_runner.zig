//! Opt-in load probe using the production WorkerThread, PTY and forward owner.
//! Credentials arrive through the environment; no commands are typed into the PTY.
const std = @import("std");
const ssh = @import("proto/ssh/session.zig");
const Worker = @import("vt/ssh_worker.zig").SshWorker;
const Thread = @import("vt/ssh_worker_thread.zig").Thread;
const sessions = @import("host/session_host.zig");
const plugins = @import("host/plugin_registry.zig");
const clock = @import("platform/realtime.zig");
const Authority = struct {
    fn create(_: *anyopaque, _: sessions.CreateRequest) !void {}
    fn cancel(_: *anyopaque, _: sessions.OperationKey) sessions.CloseReceipt {
        return .released;
    }
    fn close(_: *anyopaque, _: sessions.SessionHandle, _: sessions.OperationKey) !sessions.CloseReceipt {
        return .released;
    }
    fn stale(_: *anyopaque, _: sessions.SessionHandle, _: sessions.OperationKey) void {}
    fn adapter(self: *Authority) sessions.Adapter {
        return .{ .context = self, .registration = .{ .plugin_id = .ssh, .workspace_kind = .terminal, .services = plugins.builtin_descriptors[1].services }, .vtable = &.{ .create = create, .cancel = cancel, .close = close, .release_stale = stale } };
    }
};
fn pause() void {
    var fds: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&fds, 0, 2);
}
fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}
fn write(io: std.Io, path: []const u8, value: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = value });
}
pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const controls = args.next() orelse return error.MissingControls;
    if (!std.fs.path.isAbsolute(controls)) return error.AbsoluteControlsRequired;
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const host = try a.dupeSentinel(u8, init.environ_map.get("ZW_LOAD_HOST") orelse "127.0.0.1", 0);
    const user = try a.dupeSentinel(u8, init.environ_map.get("ZW_LOAD_USER") orelse return error.MissingUser, 0);
    const password = try a.dupeSentinel(u8, init.environ_map.get("ZW_LOAD_PASSWORD") orelse return error.MissingCredential, 0);
    const port = try std.fmt.parseInt(u16, init.environ_map.get("ZW_LOAD_PORT") orelse "22", 10);
    var library = try ssh.Library.init();
    defer library.deinit();
    var known = try @import("proto/ssh/host_key_store.zig").HostKeyStore.load(init.io, std.Io.Dir.cwd(), init.gpa, try std.fs.path.join(a, &.{ controls, "known_hosts" }));
    defer known.deinit();
    var authority: Authority = .{};
    var domain = try sessions.SessionHost.init(init.gpa, &.{authority.adapter()});
    defer domain.deinit();
    const target: sessions.AttachmentTarget = .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) };
    const accepted = try domain.create(.{ .temporary_ssh = .{ .structured_endpoint = .{ .host = host, .port = port, .user = user }, .auth_options = .{ .password = password } } }, target);
    var details: ssh.ConnectionDetails.Store = .{};
    const worker = try Worker.init(init.gpa, &library, .{ .host = host, .port = port, .user = user, .auth = .{ .password = password }, .operation_key = accepted.operation, .connection_details = &details, .host_key_store = &known, .open_shell = true }, .{ .auto_reconnect = false, .keepalive_sec = 0 });
    const thread = try Thread.start(init.gpa, worker);
    defer thread.deinit();
    if (!try domain.ready(accepted.handle, accepted.operation, plugins.builtin_descriptors[1].services) or !try domain.attached(accepted.handle, .{ .target = target, .tab_id = @fromBackingInt(1) }) or !thread.markAttached(accepted.operation)) return error.NotAttached;
    const binding = domain.queryService(accepted.handle, .forward).available;
    const service = try worker.forwardService(binding, null);
    const operation = try domain.journal.begin(.{ .session = accepted.handle }, accepted.operation.attempt_id);
    try service.start(accepted.operation, binding, operation, .{ .requested_port = 0 });
    const stop_path = try std.fs.path.join(a, &.{ controls, "stop" });
    const frames = try a.alloc(u8, @import("vt/text_slot.zig").TextSlot.default_capacity);
    var generation: u64 = 0;
    var ready = false;
    var sample_index: usize = 0;
    var pending: ?struct { id: u64, started: i128 } = null;
    const deadline = clock.monotonicNs() + 300 * std.time.ns_per_s;
    while (clock.monotonicNs() < deadline and !exists(init.io, stop_path)) {
        if (thread.hasFailed()) return error.WorkerFailed;
        if (try worker.text.take(generation, frames)) |frame| generation = frame.generation;
        const state = service.snapshot();
        if (!ready and state.phase == .running) {
            const snap = details.snapshot(accepted.operation) catch {
                pause();
                continue;
            };
            try write(init.io, try std.fs.path.join(a, &.{ controls, "ready.json" }), try std.fmt.allocPrint(a, "{{\"port\":{d},\"cipher\":\"{s}\"}}", .{ state.port, snap.hops[0].metadata.cipher_c2s.slice() }));
            ready = true;
        }
        if (pending) |p| {
            const snapshot = details.snapshot(accepted.operation) catch {
                pause();
                continue;
            };
            const sample = snapshot.hops[0].rtt_sample.?;
            if (sample.status != .pending and sample.cleanup == .released) {
                const path = try std.fmt.allocPrint(a, "{s}/sample-{d}.json", .{ controls, sample_index });
                try write(init.io, path, try std.fmt.allocPrint(a, "{{\"status\":\"{s}\",\"reason\":\"{s}\",\"rtt_ms\":{d},\"total_ms\":{d},\"bytes_down\":{d}}}", .{ @tagName(sample.status), if (sample.reason) |r| @tagName(r) else "none", sample.duration_ms orelse 0, @divTrunc(clock.monotonicNs() - p.started, std.time.ns_per_ms), state.stats.bytes_down }));
                sample_index += 1;
                pending = null;
            }
        } else if (ready and exists(init.io, try std.fmt.allocPrint(a, "{s}/sample-{d}", .{ controls, sample_index }))) {
            const id = details.request(accepted.operation, null, 1500) catch {
                pause();
                continue;
            };
            pending = .{ .id = id, .started = clock.monotonicNs() };
        }
        pause();
    }
    const before = service.snapshot();
    _ = service.requestStop(binding);
    const end = clock.monotonicNs() + 2 * std.time.ns_per_s;
    while (clock.monotonicNs() < end and service.snapshot().cleanup != .released) pause();
    thread.stopAndJoin();
    if (worker.releaseConnection() != .released) return error.ParentCleanupIncomplete;
    const after = service.snapshot();
    try write(init.io, try std.fs.path.join(a, &.{ controls, "cleanup.json" }), try std.fmt.allocPrint(a, "{{\"bytes_up\":{d},\"bytes_down\":{d},\"parent_released\":true,\"children_released\":{}}}", .{ before.stats.bytes_up, before.stats.bytes_down, after.cleanup == .released }));
}
