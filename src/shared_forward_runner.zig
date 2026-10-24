//! Controlled real SSH shell + SOCKS sharing the same native IO owner/Session.
//! No actual remote shell commands: the owned fixture only echoes raw bytes.
const std = @import("std");
const ssh = @import("proto/ssh/session.zig");
const Forward = @import("proto/ssh/forward_service.zig");
const sessions = @import("host/session_host.zig");
const plugins = @import("host/plugin_registry.zig");
const clock = @import("platform/realtime.zig");
const native = @import("generated_ssh_session");
const Authority = struct {
    session: ?*ssh.Session = null,
    fn interface(self: *Authority) sessions.Adapter {
        return .{ .context = self, .registration = .{ .plugin_id = .ssh, .workspace_kind = .terminal, .services = plugins.builtin_descriptors[1].services }, .vtable = &.{ .create = create, .cancel = cancel, .close = close, .release_stale = stale } };
    }
    fn create(_: *anyopaque, _: sessions.CreateRequest) !void {}
    fn cancel(_: *anyopaque, _: sessions.OperationKey) sessions.CloseReceipt {
        return .released;
    }
    fn close(raw: *anyopaque, _: sessions.SessionHandle, _: sessions.OperationKey) !sessions.CloseReceipt {
        const self: *Authority = @ptrCast(@alignCast(raw));
        return if (self.session) |session| switch (session.closeReceipt()) {
            .released => .released,
            .awaiting => .awaiting,
            .unknown => .unknown,
        } else .released;
    }
    fn stale(_: *anyopaque, _: sessions.SessionHandle, _: sessions.OperationKey) void {}
};
const Trust = struct {
    fingerprint: []const u8,
    key: sessions.OperationKey,
    fn observe(raw: *anyopaque, host: []const u8, _: u16, value: ssh.HostKeyInfo) ssh.HostKeyDecision {
        const self: *Trust = @ptrCast(@alignCast(raw));
        return if (std.mem.eql(u8, host, "127.0.0.1") and std.mem.eql(u8, value.fingerprint, self.fingerprint) and value.operation_key != null and value.operation_key.?.eql(self.key)) .trust_once else .reject_unknown;
    }
};
const Command = struct {
    service: *Forward.Service,
    origin: sessions.OperationKey,
    binding: sessions.ServiceHandle,
    key: sessions.OperationKey,
    caller: std.Thread.Id,
    failure: ?anyerror = null,
    fn run(self: *Command) void {
        std.debug.assert(std.Thread.getCurrentId() != self.caller);
        self.service.start(self.origin, self.binding, self.key, .{ .requested_port = 0 }) catch |err| {
            self.failure = err;
        };
    }
};
fn pause() void {
    var empty: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&empty, 0, 2);
}
fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}
fn write(io: std.Io, path: []const u8, value: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = value });
}
fn submit(service: *Forward.Service, origin: sessions.OperationKey, binding: sessions.ServiceHandle, key: sessions.OperationKey) !void {
    var command: Command = .{ .service = service, .origin = origin, .binding = binding, .key = key, .caller = std.Thread.getCurrentId() };
    const thread = try std.Thread.spawn(.{}, Command.run, .{&command});
    thread.join();
    if (command.failure) |reason| return reason;
}
pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const mode = args.next() orelse return error.MissingMode;
    const controls = args.next() orelse return error.MissingControls;
    const fingerprint = args.next() orelse return error.MissingFingerprint;
    const port = try std.fmt.parseInt(u16, args.next() orelse return error.MissingPort, 10);
    if (!std.fs.path.isAbsolute(controls)) return error.OwnedControlsRequired;
    const reconnect = std.mem.eql(u8, mode, "reconnect");
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const ready_path = try std.fs.path.join(a, &.{ controls, "ready.json" });
    const pause_path = try std.fs.path.join(a, &.{ controls, "pause" });
    const paused_path = try std.fs.path.join(a, &.{ controls, "paused.json" });
    const resume_path = try std.fs.path.join(a, &.{ controls, "resume" });
    const resumed_path = try std.fs.path.join(a, &.{ controls, "resumed.json" });
    const stop_path = try std.fs.path.join(a, &.{ controls, "stop" });
    var library = try ssh.Library.init();
    defer library.deinit();
    var store = try @import("proto/ssh/host_key_store.zig").HostKeyStore.load(init.io, std.Io.Dir.cwd(), init.gpa, try std.fs.path.join(a, &.{ controls, "known_hosts" }));
    defer store.deinit();
    var authority: Authority = .{};
    var domain = try sessions.SessionHost.init(init.gpa, &.{authority.interface()});
    defer domain.deinit();
    const target: sessions.AttachmentTarget = .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) };
    var accepted = try domain.create(.{ .temporary_ssh = .{ .structured_endpoint = .{ .host = "127.0.0.1", .port = port, .user = "shared-fixture" }, .auth_options = .{ .password = "shared-secret" } } }, target);
    var trust: Trust = .{ .fingerprint = fingerprint, .key = accepted.operation };
    var options: ssh.Options = .{ .host = "127.0.0.1", .port = port, .user = "shared-fixture", .auth = .{ .password = "shared-secret" }, .operation_key = accepted.operation, .open_shell = true, .host_key_store = &store, .host_key_observer = .{ .ctx = &trust, .callback = Trust.observe }, .connect_timeout_ms = 3000 };
    var session = try ssh.Session.connect(&library, options);
    defer session.close();
    authority.session = &session;
    native.zw_libssh2_session_nonblocking(session.handle.?);
    if (session.channel == null) return error.RealShellRequired;
    if (!try domain.ready(accepted.handle, accepted.operation, plugins.builtin_descriptors[1].services) or !try domain.attached(accepted.handle, .{ .target = target, .tab_id = @fromBackingInt(1) })) return error.DomainReadyRejected;
    var binding = domain.queryService(accepted.handle, .forward).available;
    var key = try domain.journal.begin(.{ .session = accepted.handle }, accepted.operation.attempt_id);
    const service = try Forward.Service.init(init.gpa, accepted.operation);
    var disposed = false;
    defer if (!disposed) {
        _ = service.requestStop(binding);
        for (0..500) |_| {
            if (session.state == .active) service.step(&session) catch {} else service.stepPaused() catch {};
            if (service.snapshot().cleanup == .released) break;
            pause();
        }
        if (service.snapshot().cleanup != .released and session.closeReceipt() == .released) service.sessionReleased() catch {};
        service.deinitLocal() catch {};
    };
    try submit(service, accepted.operation, binding, key);
    var ready = false;
    var paused = false;
    var resumed = false;
    var stopping = false;
    var local_port: u16 = 0;
    var heartbeat_offset: usize = 0;
    var shell_bytes: usize = 0;
    var heartbeats: usize = 0;
    var heartbeat_at = clock.monotonicNs();
    var stop_started: i128 = 0;
    const heartbeat = "TTY_HEARTBEAT\n";
    const deadline = clock.monotonicNs() + 18 * std.time.ns_per_s;
    while (clock.monotonicNs() < deadline) {
        if (paused and !resumed) {
            try service.stepPaused();
            if (exists(init.io, resume_path)) {
                try service.prepareReplacement();
                accepted = try domain.retry(accepted.handle);
                trust.key = accepted.operation;
                options.operation_key = accepted.operation;
                session = try ssh.Session.connect(&library, options);
                native.zw_libssh2_session_nonblocking(session.handle.?);
                if (!try domain.ready(accepted.handle, accepted.operation, plugins.builtin_descriptors[1].services) or !try domain.attached(accepted.handle, .{ .target = target, .tab_id = @fromBackingInt(1) })) return error.ReconnectDomainRejected;
                try service.step(&session);
                binding = domain.queryService(accepted.handle, .forward).available;
                try domain.journal.retire(key, .transferred_to_owner);
                key = try domain.journal.begin(.{ .session = accepted.handle }, accepted.operation.attempt_id);
                try submit(service, accepted.operation, binding, key);
                resumed = true;
            }
            pause();
            continue;
        }
        if (clock.monotonicNs() >= heartbeat_at) {
            const count = try (try session.writer()).write(heartbeat[heartbeat_offset..]);
            heartbeat_offset += count;
            if (heartbeat_offset == heartbeat.len) {
                heartbeats += 1;
                heartbeat_offset = 0;
                heartbeat_at = clock.monotonicNs() + 8 * std.time.ns_per_ms;
            }
        }
        var shell: [2048]u8 = undefined;
        switch (try (try session.reader()).read(&shell)) {
            .bytes => |count| shell_bytes += count,
            .would_block => {},
            .eof => return error.ParentShellClosed,
        }
        try service.step(&session);
        const value = service.snapshot();
        if (value.phase == .running and (!ready or (resumed and !exists(init.io, resumed_path)))) {
            if (local_port != 0 and value.port != local_port) return error.ListeningPortChanged;
            local_port = value.port;
            if (value.binding == null or !value.binding.?.eql(binding) or value.key == null or !value.key.?.eql(key)) return error.ForwardOwnerMismatch;
            _ = try domain.journal.publish(key, .completed, "SOCKS5 sharing original SSH", null);
            const json = try std.fmt.allocPrint(a, "{{\"local_port\":{d},\"generation\":{d}}}\n", .{ local_port, accepted.handle.generation });
            try write(init.io, if (ready) resumed_path else ready_path, json);
            ready = true;
        }
        if (ready and reconnect and !paused and exists(init.io, pause_path)) {
            try service.transportLost();
            const until = clock.monotonicNs() + 3 * std.time.ns_per_s;
            while (session.closeReceipt() != .released) {
                if (clock.monotonicNs() > until) return error.ParentNotReleased;
                pause();
            }
            try service.sessionReleased();
            if (!try domain.transportLost(accepted.handle, accepted.operation, .{ .domain = .transport, .code = "owned_reconnect_fixture", .cleanup = .released, .safe_message = "owned fixture" })) return error.LossReceiptRejected;
            paused = true;
            try write(init.io, paused_path, try std.fmt.allocPrint(a, "{{\"local_port\":{d}}}\n", .{service.snapshot().port}));
            continue;
        }
        if (ready and !stopping and exists(init.io, stop_path)) {
            stopping = true;
            stop_started = clock.monotonicNs();
            _ = service.requestStop(binding);
        }
        if (stopping and value.cleanup == .released) break;
        if (value.phase == .cleanup_unknown or value.phase == .failed) return value.failure orelse error.SharedForwardFailed;
        pause();
    }
    const final = service.snapshot();
    if (!ready or !stopping or final.cleanup != .released or final.stats.connections_active != 0 or shell_bytes == 0 or heartbeats == 0 or (reconnect and !resumed)) return error.SharedForwardIncomplete;
    const stop_ms = @divTrunc(clock.monotonicNs() - stop_started, std.time.ns_per_ms);
    // A stopped SOCKS listener must not close, deauthenticate or replace the PTY.
    const marker = "AFTER_SOCKS_STOP\n";
    var sent: usize = 0;
    var tail: [4096]u8 = undefined;
    var tail_len: usize = 0;
    const tail_deadline = clock.monotonicNs() + 3 * std.time.ns_per_s;
    while (clock.monotonicNs() < tail_deadline) {
        if (sent < marker.len) sent += try (try session.writer()).write(marker[sent..]);
        switch (try (try session.reader()).read(tail[tail_len..])) {
            .bytes => |count| tail_len += count,
            .would_block => {},
            .eof => return error.ParentClosedOnForwardStop,
        }
        if (std.mem.indexOf(u8, tail[0..tail_len], marker) != null) break;
        if (tail_len == tail.len) return error.ShellTailOverflow;
        pause();
    }
    if (std.mem.indexOf(u8, tail[0..tail_len], marker) == null or session.state != .active or session.channel == null) return error.ParentPtyNotUsable;
    _ = try domain.journal.publish(key, .cleanup_released, "SOCKS children actually released", null);
    try domain.journal.retire(key, .resources_released);
    _ = try domain.requestClose(accepted.handle, .{});
    if (domain.queryState(accepted.handle).?.lifecycle != .closed) return error.DomainParentClosePending;
    try service.sessionReleased();
    try service.deinitLocal();
    disposed = true;
    const report = try std.fmt.allocPrint(a, "{{\"same_native_session\":true,\"original_domain_forward_binding\":true,\"controller_thread_separate\":true,\"tty_bytes_during_forward\":{d},\"tty_heartbeat_writes\":{d},\"tty_after_forward_stop\":true,\"pause_and_resume\":{},\"local_port\":{d},\"port_preserved\":{},\"active\":{d},\"bytes_up\":{d},\"bytes_down\":{d},\"stop_ms\":{d},\"forward_cleanup_released\":true,\"parent_cleanup_released\":true}}\n", .{ shell_bytes, heartbeats, resumed, local_port, resumed, final.stats.connections_active, final.stats.bytes_up, final.stats.bytes_down, stop_ms });
    try write(init.io, try std.fs.path.join(a, &.{ controls, "runner-report.json" }), report);
    std.debug.print("PASS shared-forward {s} same_session=true tty_after_stop=true cleanup=released\n", .{mode});
}
