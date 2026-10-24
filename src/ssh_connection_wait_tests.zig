//! Actual loopback/socketpair waits; no SSH daemon, GUI or remote host.
const std = @import("std");
const ssh = @import("proto/ssh/session.zig");
const c = @import("generated_ssh_session");
const realtime = @import("platform/realtime.zig");

const Cancel = struct {
    token: *std.atomic.Value(bool),
    fn run(self: @This()) void {
        var unused: [1]std.c.pollfd = undefined;
        _ = std.c.poll(&unused, 0, 60);
        self.token.store(true, .release);
    }
};

const Pair = struct {
    target: c_int,
    peer: c_int,
    fn tcp() !Pair {
        const listener = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (listener < 0) return error.SocketFailed;
        defer c.zw_ssh_socket_close(listener);
        var address: std.c.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        if (std.c.bind(listener, @ptrCast(&address), @sizeOf(@TypeOf(address))) != 0 or std.c.listen(listener, 1) != 0) return error.ListenFailed;
        var length: std.c.socklen_t = @sizeOf(@TypeOf(address));
        if (std.c.getsockname(listener, @ptrCast(&address), &length) != 0) return error.ListenFailed;
        const target = c.zw_ssh_socket_connect("127.0.0.1", std.mem.bigToNative(u16, address.port), 1000);
        if (target < 0) return error.ConnectFailed;
        errdefer c.zw_ssh_socket_close(target);
        const peer = std.c.accept(listener, null, null);
        if (peer < 0) return error.AcceptFailed;
        return .{ .target = target, .peer = peer };
    }
    fn relay() !Pair {
        const pair = try ssh.SocketRelay.Pair.create();
        return .{ .target = pair.target_fd, .peer = pair.relay_fd };
    }
};

fn expectClosed(fd: c_int) !void {
    try std.testing.expectEqual(@as(c_int, -1), std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0)));
    try std.testing.expectEqual(@as(c_int, @backingInt(std.c.E.BADF)), std.c._errno().*);
}

fn silentHandshake(pair: Pair, cancel: bool) !void {
    defer c.zw_ssh_socket_close(pair.peer);
    var library = try ssh.Library.init();
    defer library.deinit();
    var token: std.atomic.Value(bool) = .init(false);
    const thread = if (cancel) try std.Thread.spawn(.{}, Cancel.run, .{Cancel{ .token = &token }}) else null;
    defer if (thread) |value| value.join();
    const start = realtime.monotonicNs();
    var progress: ssh.ConnectionProgress.Journal = .{};
    progress.begin(1);
    try std.testing.expectError(if (cancel) error.Cancelled else error.ConnectionTimedOut, ssh.Session.connectOverFd(&library, .{
        .host = "loopback-fixture",
        .user = "operator",
        .auth = .agent,
        .open_shell = false,
        .cancel_token = &token,
        .connect_timeout_ms = if (cancel) 3000 else 120,
        .progress_observer = progress.observer(),
        .attempt_id = 1,
    }, pair.target));
    const elapsed = @divTrunc(realtime.monotonicNs() - start, std.time.ns_per_ms);
    try std.testing.expect(elapsed < 600);
    if (!cancel) try std.testing.expect(elapsed >= 100);
    try expectClosed(pair.target);
    const failed = progress.snapshot().failure.?;
    try std.testing.expectEqual(ssh.ConnectionProgress.Phase.handshake, failed.phase);
    try std.testing.expectEqual(@as(anyerror, if (cancel) error.Cancelled else error.ConnectionTimedOut), failed.failure.?);
    // The real client banner was transmitted before cancel/timeout. Drain it
    // and prove the remote endpoint sees actual EOF, not a fabricated receipt.
    try std.testing.expectEqual(@as(c_int, 0), c.zw_ssh_socket_set_nonblocking(pair.peer));
    var total: usize = 0;
    var bytes: [1024]u8 = undefined;
    while (true) {
        const count = std.c.recv(pair.peer, &bytes, bytes.len, 0);
        if (count == 0) break;
        try std.testing.expect(count > 0);
        if (total == 0) try std.testing.expect(std.mem.startsWith(u8, bytes[0..@intCast(count)], "SSH-2.0-"));
        total += @intCast(count);
        try std.testing.expect(total < 16 * 1024);
    }
    try std.testing.expect(total != 0);
}

test "connection wait cancels an actual silent TCP handshake and consumes its FD" {
    try silentHandshake(try Pair.tcp(), true);
}

test "connection wait times out an actual silent TCP handshake and consumes its FD" {
    try silentHandshake(try Pair.tcp(), false);
}

test "connection wait cancels an actual silent relay socketpair and consumes its FD" {
    try silentHandshake(try Pair.relay(), true);
}

test "connection wait agent failure must not close a subsequently reused FD" {
    const Native = struct {
        const Agent = opaque {};
        extern "c" fn libssh2_agent_init(*c.LIBSSH2_SESSION) ?*Agent;
        extern "c" fn libssh2_agent_set_identity_path(*Agent, [*:0]const u8) void;
        extern "c" fn libssh2_agent_connect(*Agent) c_int;
        extern "c" fn libssh2_agent_free(*Agent) void;
    };
    var library = try ssh.Library.init();
    defer library.deinit();
    const session = c.zw_libssh2_session_create() orelse return error.SessionCreateFailed;
    defer c.zw_libssh2_session_disconnect_free(session);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/missing-agent.sock", .{directory}, 0);
    defer std.testing.allocator.free(path);
    const agent = Native.libssh2_agent_init(session) orelse return error.AgentCreateFailed;
    var freed = false;
    defer if (!freed) Native.libssh2_agent_free(agent);
    Native.libssh2_agent_set_identity_path(agent, path);
    const probe = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    try std.testing.expect(probe >= 0);
    c.zw_ssh_socket_close(probe);
    try std.testing.expect(Native.libssh2_agent_connect(agent) < 0);
    const replacement = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    try std.testing.expect(replacement >= 0);
    defer c.zw_ssh_socket_close(replacement);
    try std.testing.expectEqual(probe, replacement);
    Native.libssh2_agent_free(agent);
    freed = true;
    try std.testing.expect(std.c.fcntl(replacement, std.c.F.GETFL, @as(c_int, 0)) >= 0);
}
