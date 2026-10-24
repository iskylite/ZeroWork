//! Actual production WorkerThread + SOCKS controller over an owned echo peer.
//! The peer echoes bytes and rejects exec; no real remote command is run.
const std = @import("std");
const ssh = @import("proto/ssh/session.zig");
const Worker = @import("vt/ssh_worker.zig").SshWorker;
const WorkerThread = @import("vt/ssh_worker_thread.zig").Thread;
const Forward = @import("proto/ssh/forward_service.zig");
const Socks = @import("host/socks_route_host.zig");
const sessions = @import("host/session_host.zig");
const plugins = @import("host/plugin_registry.zig");
const clock = @import("platform/realtime.zig");
const Authority = struct {
    worker: ?*Worker = null,
    thread: ?*WorkerThread = null,
    socks: ?*Socks.Host = null,
    fn interface(self: *Authority) sessions.Adapter {
        return .{ .context = self, .registration = .{ .plugin_id = .ssh, .workspace_kind = .terminal, .services = plugins.builtin_descriptors[1].services }, .vtable = &.{ .create = create, .cancel = cancel, .close = close, .release_stale = stale } };
    }
    fn create(_: *anyopaque, _: sessions.CreateRequest) !void {}
    fn cancel(_: *anyopaque, _: sessions.OperationKey) sessions.CloseReceipt { return .released; }
    fn close(raw: *anyopaque, _: sessions.SessionHandle, _: sessions.OperationKey) !sessions.CloseReceipt {
        const self: *Authority = @ptrCast(@alignCast(raw));
        if (self.thread) |thread| thread.stopAndJoin();
        return if (self.worker) |worker| switch (worker.releaseConnection()) { .released => .released, .awaiting => .awaiting, .unknown => .unknown } else .released;
    }
    fn stale(_: *anyopaque, _: sessions.SessionHandle, _: sessions.OperationKey) void {}
    fn service(raw: *anyopaque, binding: sessions.ServiceHandle, exit: ?usize) !*Forward.Service {
        const self: *Authority = @ptrCast(@alignCast(raw));
        return (self.worker orelse return error.NoWorker).forwardService(binding, exit);
    }
    fn releaseForwards(raw: *anyopaque, owner: sessions.SessionHandle, _: sessions.OperationKey) !sessions.CloseReceipt {
        const self: *Authority = @ptrCast(@alignCast(raw));
        return (self.socks orelse return error.NoSocksHost).requestSessionClose(owner);
    }
};
const Trust = struct {
    fingerprint: []const u8,
    fn observe(raw: *anyopaque, host: []const u8, _: u16, value: ssh.HostKeyInfo) ssh.HostKeyDecision {
        const self: *Trust = @ptrCast(@alignCast(raw));
        return if (std.mem.eql(u8, host, "127.0.0.1") and std.mem.eql(u8, value.fingerprint, self.fingerprint)) .trust_once else .reject_unknown;
    }
};
fn pause() void { var empty: [1]std.c.pollfd = undefined; _ = std.c.poll(&empty, 0, 2); }
fn exists(io: std.Io, path: []const u8) bool { std.Io.Dir.cwd().access(io, path, .{}) catch return false; return true; }
fn write(io: std.Io, path: []const u8, value: []const u8) !void { try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = value }); }
pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate(); _ = args.next();
    const mode = args.next() orelse return error.MissingMode;
    const controls = args.next() orelse return error.MissingControls;
    const fingerprint = args.next() orelse return error.MissingFingerprint;
    const port = try std.fmt.parseInt(u16, args.next() orelse return error.MissingPort, 10);
    const jump_count = if (args.next()) |value| try std.fmt.parseInt(usize, value, 10) else 0;
    if (jump_count > 2) return error.OwnedFixtureRouteLimit;
    const exit_text = args.next() orelse "target";
    const exit_index: ?usize = if (std.mem.eql(u8, exit_text, "target")) null else try std.fmt.parseInt(usize, exit_text, 10);
    if (exit_index != null and exit_index.? >= jump_count) return error.InvalidOwnedExit;
    var jump_ports: [2]u16 = undefined;
    var jump_fingerprints: [2][]const u8 = undefined;
    for (0..jump_count) |index| {
        jump_ports[index] = try std.fmt.parseInt(u16, args.next() orelse return error.MissingJumpPort, 10);
        jump_fingerprints[index] = args.next() orelse return error.MissingJumpFingerprint;
    }
    if (!std.fs.path.isAbsolute(controls)) return error.OwnedControlsRequired;
    const reconnect = std.mem.eql(u8, mode, "reconnect");
    const parent_close = std.mem.eql(u8, mode, "parent-close") or std.mem.eql(u8, mode, "parent-open-close");
    var arena = std.heap.ArenaAllocator.init(init.gpa); defer arena.deinit();
    const a = arena.allocator();
    const ready_path = try std.fs.path.join(a, &.{ controls, "ready.json" });
    const pause_path = try std.fs.path.join(a, &.{ controls, "pause" });
    const paused_path = try std.fs.path.join(a, &.{ controls, "paused.json" });
    const resume_path = try std.fs.path.join(a, &.{ controls, "resume" });
    const resumed_path = try std.fs.path.join(a, &.{ controls, "resumed.json" });
    const stop_path = try std.fs.path.join(a, &.{ controls, "stop" });
    var library = try ssh.Library.init(); defer library.deinit();
    var store = try @import("proto/ssh/host_key_store.zig").HostKeyStore.load(init.io, std.Io.Dir.cwd(), init.gpa, try std.fs.path.join(a, &.{ controls, "known_hosts" })); defer store.deinit();
    var authority: Authority = .{};
    var domain = try sessions.SessionHost.init(init.gpa, &.{authority.interface()}); defer domain.deinit();
    const target: sessions.AttachmentTarget = .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) };
    var route_spec: [2]sessions.RouteHop = undefined;
    for (0..jump_count) |index| route_spec[index] = .{ .display_name = if (index == 0) "owned first jump" else "owned second jump", .endpoint = .{ .host = "127.0.0.1", .port = jump_ports[index], .user = "shared-fixture" }, .auth = .{ .password = "shared-secret" } };
    var accepted = try domain.create(.{ .temporary_ssh = .{ .structured_endpoint = .{ .host = "127.0.0.1", .port = port, .user = "shared-fixture" }, .auth_options = .{ .password = "shared-secret" }, .route_snapshot = route_spec[0..jump_count] } }, target);
    var trust: [3]Trust = undefined;
    for (0..jump_count) |index| trust[index] = .{ .fingerprint = jump_fingerprints[index] };
    trust[jump_count] = .{ .fingerprint = fingerprint };
    var ledger = try ssh.ResourceLedger.init(accepted.operation, jump_count + 1);
    const target_options: ssh.Options = .{ .host = "127.0.0.1", .port = port, .user = "shared-fixture", .auth = .{ .password = "shared-secret" }, .operation_key = accepted.operation, .resource_ledger = &ledger, .open_shell = true, .host_key_store = &store, .host_key_observer = .{ .ctx = &trust[jump_count], .callback = Trust.observe }, .rows = 40, .cols = 160 };
    var route_options: [3]ssh.Options = undefined;
    for (0..jump_count + 1) |index| {
        route_options[index] = target_options;
        route_options[index].port = if (index == jump_count) port else jump_ports[index];
        route_options[index].host_key_observer = .{ .ctx = &trust[index], .callback = Trust.observe };
        route_options[index].connect_timeout_ms = 3000;
    }
    const worker = try Worker.init(init.gpa, &library, target_options, .{ .connect_timeout_ms = 3000, .keepalive_sec = 0, .auto_reconnect = false, .jump_options = if (jump_count == 0) &.{} else route_options[0 .. jump_count + 1] });
    const thread = try WorkerThread.start(init.gpa, worker);
    authority.worker = worker; authority.thread = thread;
    var worker_disposed = false;
    defer if (!worker_disposed) {
        for (worker.forward_services[0..worker.forward_count]) |service| if (service) |value| value.requestClose();
        thread.stopAndJoin();
        _ = worker.releaseConnection();
        thread.deinit();
    };
    if (!try domain.ready(accepted.handle, accepted.operation, plugins.builtin_descriptors[1].services) or !try domain.attached(accepted.handle, .{ .target = target, .tab_id = @fromBackingInt(1) }) or !thread.markAttached(accepted.operation)) return error.DomainReadyRejected;
    var backend = try Socks.Host.init(init.gpa, &domain, .{ .library = &library, .known_hosts_path = try std.fs.path.join(a, &.{ controls, "known_hosts" }), .shared_provider = .{ .context = &authority, .get = Authority.service } });
    authority.socks = &backend;
    var backend_disposed = false;
    defer if (!backend_disposed) {
        const cleanup_until = clock.monotonicNs() + 3 * std.time.ns_per_s;
        while (backend.shutdownStep() == .awaiting and clock.monotonicNs() < cleanup_until) { _ = backend.safeTick() catch false; pause(); }
        if (backend.shutdownStep() != .released) {
            thread.stopAndJoin();
            _ = worker.releaseConnection();
        }
        _ = backend.safeTick() catch false;
        backend.deinit() catch {};
    };
    _ = try backend.start(accepted.handle, .{ .exit_index = exit_index, .listener = .{ .requested_port = 0 } });
    const frames = try a.alloc(u8, @import("vt/text_slot.zig").TextSlot.default_capacity);
    var frame_generation: u64 = 0;
    var shell_bytes: usize = 0;
    var heartbeats: usize = 0;
    var ready = false; var paused = false; var resumed = false; var granted = false; var stopping = false;
    var local_port: u16 = 0; var heartbeat_at = clock.monotonicNs(); var stop_started: i128 = 0;
    var close_key: ?sessions.OperationKey = null;
    const deadline = clock.monotonicNs() + 20 * std.time.ns_per_s;
    while (clock.monotonicNs() < deadline) {
        _ = try backend.safeTick();
        if (try worker.text.take(frame_generation, frames)) |frame| { frame_generation = frame.generation; shell_bytes += frame.text.len; }
        const runtime = thread.reconnectSnapshot();
        if (ready and reconnect and !paused and exists(init.io, pause_path) and runtime.cleanup == .released and (runtime.phase == .waiting or runtime.phase == .ended)) {
            if (!try domain.transportLost(accepted.handle, accepted.operation, .{ .domain = .transport, .code = "owned_disconnect", .cleanup = .released, .safe_message = "owned peer closed its transport" })) return error.LossReceiptRejected;
            paused = true;
            try write(init.io, paused_path, try std.fmt.allocPrint(a, "{{\"local_port\":{d}}}\n", .{backend.snapshot(accepted.handle).?.local_port}));
        }
        if (paused and !granted and exists(init.io, resume_path)) {
            const old = accepted.operation;
            accepted = try domain.retry(accepted.handle);
            try thread.requestReconnect(old, accepted.operation);
            granted = true;
        }
        if (granted and !resumed and runtime.phase == .ready and runtime.key != null and runtime.key.?.eql(accepted.operation)) {
            if (!try domain.ready(accepted.handle, accepted.operation, plugins.builtin_descriptors[1].services) or !try domain.attached(accepted.handle, .{ .target = target, .tab_id = @fromBackingInt(1) }) or !thread.markAttached(accepted.operation)) return error.ReconnectDomainRejected;
            resumed = true;
            _ = try backend.safeTick();
        }
        if (!paused or resumed) {
            if (runtime.phase == .active and clock.monotonicNs() >= heartbeat_at) {
                worker.pushInput("TTY_HEARTBEAT\r\n") catch |err| {
                    // The real attached receipt schedules replay's input gate
                    // in the next owner tick. Application input waits for it.
                    if (err == error.DisconnectedApplicationInput) { pause(); continue; }
                    return err;
                };
                heartbeats += 1;
                heartbeat_at = clock.monotonicNs() + 15 * std.time.ns_per_ms;
            }
            if (backend.snapshot(accepted.handle)) |value| {
                if (value.phase == .ready and (!ready or (resumed and !exists(init.io, resumed_path)))) {
                    if (local_port != 0 and local_port != value.local_port) return error.ListeningPortChanged;
                    local_port = value.local_port;
                    try write(init.io, if (ready) resumed_path else ready_path, try std.fmt.allocPrint(a, "{{\"local_port\":{d},\"generation\":{d}}}\n", .{ local_port, accepted.handle.generation }));
                    ready = true;
                }
                if (ready and !stopping and exists(init.io, stop_path)) {
                    stopping = true; stop_started = clock.monotonicNs();
                    if (parent_close) close_key = try domain.requestClose(accepted.handle, .{ .release_forwards = .{ .context = &authority, .run = Authority.releaseForwards } }) else _ = backend.requestStop(accepted.handle);
                }
                if (stopping and value.cleanup == .released) {
                    if (close_key) |key| _ = try domain.closeReceipt(accepted.handle, key, .release_forwards, .released);
                    break;
                }
                if (value.phase == .cleanup_unknown or value.phase == .failed) return value.failure orelse error.ForwardFailed;
            }
        }
        pause();
    }
    const final = backend.snapshot(accepted.handle) orelse return error.MissingFinalSnapshot;
    if (!ready or !stopping or final.cleanup != .released or final.stats.connections_active != 0 or heartbeats == 0 or shell_bytes == 0 or (reconnect and !resumed)) return error.SharedForwardIncomplete;
    const stop_ms = @divTrunc(clock.monotonicNs() - stop_started, std.time.ns_per_ms);
    if (parent_close) {
        if (domain.queryState(accepted.handle).?.lifecycle != .closed) return error.ParentClosePending;
        _ = try backend.safeTick();
        try backend.deinit(); backend_disposed = true;
        thread.deinit(); worker_disposed = true;
        authority.worker = null; authority.thread = null;
        try write(init.io, try std.fs.path.join(a, &.{ controls, "runner-report.json" }), try std.fmt.allocPrint(a, "{{\"real_worker_thread\":true,\"real_shared_host\":true,\"same_native_session\":true,\"parent_close_under_withheld_ack\":{},\"parent_close_under_withheld_open\":{},\"tty_after_forward_stop\":false,\"active\":{d},\"bytes_up\":{d},\"bytes_down\":{d},\"stop_ms\":{d},\"forward_cleanup_released\":true,\"parent_cleanup_released\":true}}\n", .{ std.mem.eql(u8, mode, "parent-close"), std.mem.eql(u8, mode, "parent-open-close"), final.stats.connections_active, final.stats.bytes_up, final.stats.bytes_down, stop_ms }));
        std.debug.print("PASS worker-parent-close withheld_ack=true cleanup=released\n", .{});
        return;
    }
    try worker.pushInput("AFTER_SOCKS_STOP\n");
    var marker_seen = false;
    const tail_deadline = clock.monotonicNs() + 3 * std.time.ns_per_s;
    while (clock.monotonicNs() < tail_deadline) {
        if (try worker.text.take(frame_generation, frames)) |frame| {
            frame_generation = frame.generation;
            if (std.mem.indexOf(u8, frame.text, "AFTER_SOCKS_STOP") != null) { marker_seen = true; break; }
        }
        pause();
    }
    if (!marker_seen or thread.hasFailed()) return error.ParentPtyNotUsable;
    _ = try backend.safeTick();
    try backend.deinit(); backend_disposed = true;
    _ = try domain.requestClose(accepted.handle, .{});
    if (domain.queryState(accepted.handle).?.lifecycle != .closed) return error.ParentClosePending;
    thread.deinit(); worker_disposed = true;
    authority.worker = null; authority.thread = null;
    const report = try std.fmt.allocPrint(a, "{{\"real_worker_thread\":true,\"real_shared_host\":true,\"jump_count\":{d},\"exit_index\":{d},\"same_native_session\":true,\"original_domain_forward_binding\":true,\"controller_thread_separate\":true,\"tty_bytes_during_forward\":{d},\"tty_heartbeat_writes\":{d},\"tty_after_forward_stop\":true,\"pause_and_resume\":{},\"local_port\":{d},\"port_preserved\":{},\"active\":{d},\"bytes_up\":{d},\"bytes_down\":{d},\"stop_ms\":{d},\"forward_cleanup_released\":true,\"parent_cleanup_released\":true}}\n", .{ jump_count, exit_index orelse jump_count, shell_bytes, heartbeats, resumed, local_port, resumed, final.stats.connections_active, final.stats.bytes_up, final.stats.bytes_down, stop_ms });
    try write(init.io, try std.fs.path.join(a, &.{ controls, "runner-report.json" }), report);
    std.debug.print("PASS worker-shared-forward {s} same_session=true tty_after_stop=true cleanup=released\n", .{mode});
}
