//! Owned loopback acceptance: real algorithm negotiation and idle SSH liveness.
const std = @import("std");
const ssh = @import("proto/ssh/session.zig");
const c = @import("generated_ssh_session");
const clock = @import("platform/realtime.zig");
const Watch = @import("proto/ssh/keepalive_watch.zig").Watch;

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const port = try std.fmt.parseInt(u16, args.next() orelse return error.MissingPort, 10);
    const mode = args.next() orelse return error.MissingMode;
    var library = try ssh.Library.init();
    defer library.deinit();
    var session = ssh.Session.connect(&library, .{
        .host = "127.0.0.1",
        .port = port,
        .user = "fixture",
        .auth = .{ .password = "fixture" },
        .host_key_decision = .trust_once,
        .connect_timeout_ms = 1500,
        .keepalive_sec = 2,
    }) catch |err| {
        if (std.mem.eql(u8, mode, "unsupported") and err == error.SshHandshakeNegotiationFailed) {
            std.debug.print("PASS unsupported cipher reports negotiation failure\n", .{});
            return;
        }
        return err;
    };
    defer session.close();
    if (std.mem.eql(u8, mode, "unsupported")) return error.UnexpectedNegotiation;
    if (std.mem.eql(u8, mode, "fallback")) {
        if (!std.mem.eql(u8, std.mem.span(c.zw_libssh2_session_cipher_sc(session.handle.?)), "aes128-cbc")) return error.WrongCipher;
        std.debug.print("PASS backend-supported non-CTR fallback negotiated\n", .{});
        return;
    }
    if (std.mem.eql(u8, mode, "tunnel-timeout")) {
        const started = c.zw_ssh_monotonic_ms();
        var deadline = started + 150;
        var child = session.openDirectTcpipDriven("127.0.0.1", 22, .{
            .host = "127.0.0.1",
            .user = "fixture",
            .auth = .{ .password = "fixture" },
            .connect_timeout_ms = 150,
            .network_deadline_ms = &deadline,
        }) catch |err| {
            const elapsed = c.zw_ssh_monotonic_ms() - started;
            if (err != error.ConnectionTimedOut or elapsed < 120 or elapsed > 600) return error.TunnelDeadlineFailed;
            std.debug.print("PASS next-hop tunnel uses cancellable bounded network driver\n", .{});
            return;
        };
        session.closeChannel(&child);
        return error.UnexpectedTunnelSuccess;
    }
    var watch: Watch = .{};
    const start = clock.monotonicNs();
    const initial = c.zw_libssh2_session_received_packets(session.handle.?);
    var received = initial;
    var buffer: [1024]u8 = undefined;
    const silent = std.mem.eql(u8, mode, "silent");
    while (clock.monotonicNs() - start < 7 * std.time.ns_per_s) {
        const count = c.zw_libssh2_channel_read(@ptrCast(session.channel.?.handle), &buffer, buffer.len);
        if (count < 0) return error.ChannelReadFailed;
        received = c.zw_libssh2_session_received_packets(session.handle.?);
        const now = clock.monotonicNs();
        const send = watch.step(now, received, 2) catch |err| {
            if (silent and err == error.KeepaliveTimedOut) {
                std.debug.print("PASS silent SSH peer times out despite successful local sends\n", .{});
                return;
            }
            return err;
        };
        if (send) try watch.sent(now, c.zw_libssh2_session_send_keepalive(session.handle.?), 2);
        var unused: [1]std.c.pollfd = undefined;
        _ = std.c.poll(&unused, 0, 10);
    }
    if (silent or received == initial) return error.LivenessCheckFailed;
    std.debug.print("PASS idle SSH peer stays alive through protocol replies without terminal output\n", .{});
}
