//! Opt-in read-only acceptance against the servers explicitly supplied by the user.
//! Credentials are required through environment variables and are never emitted.
//! Uses the production libssh2 Session/Route and its real cleanup ledger; no UI.
const std = @import("std");
const ssh = @import("proto/ssh/session.zig");
const Route = @import("proto/ssh/jump_transport.zig").Route;
const clock = @import("platform/realtime.zig");
const native = @import("generated_ssh_session");
const channel_native = @import("generated_ssh_channel");

fn emit(value: anytype) void {
    const encoded = std.json.Stringify.valueAlloc(std.heap.c_allocator, value, .{}) catch return;
    defer std.heap.c_allocator.free(encoded);
    std.debug.print("REAL_JUMP {s}\n", .{encoded});
}
fn pause() void {
    var unused: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&unused, 0, 2);
}
const Trust = struct {
    hosts: []const [:0]const u8,
    jump_port: u16,
    count: usize = 0,
    fn observe(raw: *anyopaque, host: []const u8, port: u16, info: ssh.HostKeyInfo) ssh.HostKeyDecision {
        const self: *Trust = @ptrCast(@alignCast(raw));
        const matches = info.hop_index < self.hosts.len and std.mem.eql(u8, host, self.hosts[info.hop_index]) and port == (if (info.hop_index == 0) self.jump_port else @as(u16, 22));
        emit(.{ .event = "hostkey", .hop = info.hop_index, .host = host, .port = port, .algorithm = info.algorithm, .fingerprint = info.fingerprint, .expected_endpoint = matches, .decision = if (matches and info.status == .unknown) "trust_once" else "reject" });
        if (!matches or info.status != .unknown) return .reject_unknown;
        self.count += 1;
        return .trust_once;
    }
};
fn progress(_: *anyopaque, event: @import("proto/ssh/connection_progress.zig").Event) void {
    emit(.{ .event = "progress", .hop = event.hop, .hop_count = event.hop_count, .host = event.host, .port = event.port, .phase = @tagName(event.phase), .status = @tagName(event.status), .failure = if (event.failure) |err| @errorName(err) else null });
}
fn command(session: *ssh.Session, text: [:0]const u8) !void {
    if (!std.mem.eql(u8, text, "id") and !std.mem.eql(u8, text, "hostname")) return error.ReadOnlyCommandRequired;
    session.setBlocking();
    var channel = try session.openExec(text);
    var closed = false;
    defer if (!closed) {
        _ = session.closeChannelReceipt(&channel);
    };
    native.zw_libssh2_session_nonblocking(session.handle.?);
    var output: [2048]u8 = undefined;
    var count: usize = 0;
    const deadline = clock.monotonicNs() + 8 * std.time.ns_per_s;
    while (true) {
        if (clock.monotonicNs() > deadline) return error.CommandReadTimeout;
        if (count == output.len) return error.CommandOutputTooLarge;
        const result = try channel.reader().read(output[count..]);
        switch (result) {
            .bytes => |size| count += size,
            .would_block => pause(),
            .eof => break,
        }
    }
    while (true) {
        const rc = channel_native.zw_libssh2_channel_wait_closed_step(channel.handle);
        if (rc == 0) break;
        if (rc != -37) return error.CommandCloseAckFailed;
        if (clock.monotonicNs() > deadline) return error.CommandCloseAckTimeout;
        pause();
    }
    var status: c_int = -1;
    const known = channel_native.zw_libssh2_channel_exit_status_received(channel.handle, &status) == 1;
    emit(.{ .event = "readonly_command", .command = text, .stdout = output[0..count], .exit_status_known = known, .exit_status = status, .pty = false });
    while (session.closeChannelReceipt(&channel) != .released) {
        if (clock.monotonicNs() > deadline) return error.CommandResourceNotReleased;
        pause();
    }
    closed = true;
    if (!known or status != 0 or count == 0) return error.CommandFailed;
    if (std.mem.eql(u8, text, "id") and !std.mem.startsWith(u8, output[0..count], "uid=0(root)")) return error.UnexpectedTargetIdentity;
}
fn run(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const mode = args.next() orelse return error.MissingMode;
    if (args.next() != null) return error.UnexpectedArgument;
    const first_password = std.mem.span(std.c.getenv("ZEROWORK_REAL_JUMP_PASSWORD") orelse return error.MissingJumpPassword);
    const target_password = std.mem.span(std.c.getenv("ZEROWORK_REAL_TARGET_PASSWORD") orelse return error.MissingTargetPassword);
    const two = std.mem.eql(u8, mode, "two");
    const three = std.mem.eql(u8, mode, "three");
    const blocked = std.mem.eql(u8, mode, "blocked");
    if (!two and !three and !blocked) return error.InvalidMode;
    const jump_host = std.mem.span(std.c.getenv("ZEROWORK_REAL_JUMP_HOST") orelse return error.MissingJumpHost);
    const middle_host = std.mem.span(std.c.getenv("ZEROWORK_REAL_MIDDLE_HOST") orelse return error.MissingMiddleHost);
    const final_host = if (two) middle_host else std.mem.span(std.c.getenv("ZEROWORK_REAL_TARGET_HOST") orelse return error.MissingTargetHost);
    const jump_user = std.mem.span(std.c.getenv("ZEROWORK_REAL_JUMP_USER") orelse return error.MissingJumpUser);
    const jump_port = try std.fmt.parseInt(u16, std.mem.span(std.c.getenv("ZEROWORK_REAL_JUMP_PORT") orelse return error.MissingJumpPort), 10);
    if (jump_port == 0) return error.InvalidPort;
    const names: [3][:0]const u8 = .{ jump_host, middle_host, final_host };
    const count: usize = if (two) 2 else 3;
    var library = try ssh.Library.init();
    defer library.deinit();
    const key: @import("host/operation.zig").OperationKey = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(71001), .generation = 1 } }, .operation_id = if (two) 1 else if (three) 2 else 3, .attempt_id = 1 };
    var ledger = try ssh.ResourceLedger.init(key, count);
    var trust: Trust = .{ .hosts = names[0..count], .jump_port = jump_port };
    var observer_context: u8 = 0;
    var options: [3]ssh.Options = undefined;
    for (options[0..count], 0..) |*option, index| option.* = .{ .host = names[index], .port = if (index == 0) jump_port else 22, .user = if (index == 0) jump_user else "root", .auth = .{ .password = if (index == 0) first_password else target_password }, .open_shell = false, .strict_host_key_checking = true, .host_key_observer = .{ .ctx = &trust, .callback = Trust.observe }, .connect_timeout_ms = 8_000, .resource_ledger = &ledger, .operation_key = key, .attempt_id = 1, .progress_observer = .{ .context = &observer_context, .callback = progress } };
    emit(.{ .event = "begin", .mode = mode, .route = names[0..count], .production = "proto/ssh/jump_transport.Route", .remote_writes = false, .login_shell = false });
    const route = Route.connect(init.gpa, &library, options[0..count]) catch |err| {
        const deadline = clock.monotonicNs() + 8 * std.time.ns_per_s;
        var receipt = ledger.drainRetained();
        while (receipt == .awaiting and clock.monotonicNs() < deadline) {
            pause();
            receipt = ledger.drainRetained();
        }
        const snapshot = ledger.snapshot();
        emit(.{ .event = "connect_failed", .mode = mode, .failure = @errorName(err), .cleanup = @tagName(receipt), .ledger_released = snapshot.released(), .unknown = snapshot.hasUnknown(), .host_keys_observed = trust.count });
        if (blocked and err == error.OpenDirectTcpipFailed and trust.count == 2 and receipt == .released and snapshot.released()) return;
        return err;
    };
    var disposed = false;
    defer if (!disposed) route.deinit();
    if (blocked) return error.ExpectedForwardingRejection;
    if (trust.count != count) return error.MissingHopHostKey;
    try command(route.target(), "id");
    try command(route.target(), "hostname");
    const deadline = clock.monotonicNs() + 8 * std.time.ns_per_s;
    var receipt = route.closeReceipt();
    while (receipt == .awaiting and clock.monotonicNs() < deadline) {
        pause();
        receipt = route.closeReceipt();
    }
    const snapshot = ledger.snapshot();
    emit(.{ .event = "complete", .mode = mode, .hops = count, .cleanup = @tagName(receipt), .ledger_released = snapshot.released(), .unknown = snapshot.hasUnknown(), .host_keys_observed = trust.count, .commands = 2 });
    if (receipt != .released or !snapshot.released()) return error.NativeResourcesNotReleased;
    route.deinit();
    disposed = true;
}
pub fn main(init: std.process.Init) !void {
    run(init) catch |err| {
        emit(.{ .event = "failed", .error_name = @errorName(err) });
        return err;
    };
}
