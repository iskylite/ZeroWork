const std = @import("std");
const ssh = @import("proto/ssh/session.zig");
const c = @import("generated_ssh_session");

test "release receipt closes owned socket and records native-free before transport" {
    var library = try ssh.Library.init();
    defer library.deinit();
    const pair = try ssh.SocketRelay.Pair.create();
    defer c.zw_ssh_socket_close(pair.relay_fd);
    var ledger = try ssh.ResourceLedger.init(null, 1);
    var session: ssh.Session = .{ .state = .connecting, .socket_fd = pair.target_fd, .resource_ledger = &ledger };
    defer session.close();
    session.recordResource(.transport, .owned);
    session.handle = c.zw_libssh2_session_create() orelse return error.CreateFailed;
    session.recordResource(.session, .owned);
    try std.testing.expectEqual(ssh.ReleaseReceipt.released, session.closeReceipt());
    try std.testing.expectEqual(ssh.ReleaseReceipt.released, session.closeReceipt());
    try std.testing.expect(session.handle == null and session.socket_fd == -1);
    const snapshot = ledger.snapshot();
    try std.testing.expect(snapshot.released());
    try std.testing.expect(snapshot.entry(0, .session).released_sequence < snapshot.entry(0, .transport).released_sequence);
    try std.testing.expectEqual(@as(c_int, -1), std.c.fcntl(pair.target_fd, std.c.F.GETFL, @as(c_int, 0)));
    var byte: u8 = 0;
    try std.testing.expectEqual(@as(isize, 0), std.c.recv(pair.relay_fd, &byte, 1, 0));
}

test "release receipt preserves unknown close and never closes recycled fd" {
    const pair = try ssh.SocketRelay.Pair.create();
    defer c.zw_ssh_socket_close(pair.relay_fd);
    var ledger = try ssh.ResourceLedger.init(null, 1);
    var session: ssh.Session = .{ .state = .active, .socket_fd = pair.target_fd, .resource_ledger = &ledger };
    session.recordResource(.transport, .owned);
    // Simulate an externally broken ownership invariant. A failed close must
    // remain unknown, and its numeric descriptor must never be closed twice.
    c.zw_ssh_socket_close(pair.target_fd);
    try std.testing.expectEqual(ssh.ReleaseReceipt.unknown, session.closeReceipt());
    try std.testing.expectEqual(ssh.State.closing, session.state);
    const replacement = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    try std.testing.expect(replacement >= 0);
    defer c.zw_ssh_socket_close(replacement);
    try std.testing.expectEqual(pair.target_fd, replacement);
    try std.testing.expectEqual(ssh.ReleaseReceipt.unknown, session.closeReceipt());
    try std.testing.expect(std.c.fcntl(replacement, std.c.F.GETFL, @as(c_int, 0)) >= 0);
    const snapshot = ledger.snapshot();
    try std.testing.expect(!snapshot.released());
    try std.testing.expect(snapshot.hasUnknown());
}

test {
    _ = ssh;
}
