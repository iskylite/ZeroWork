//! Focused facts/admission tests; real native RTT behavior has its own fixture.
const std = @import("std");
const ssh = @import("proto/ssh/session.zig");
const details = ssh.ConnectionDetails;

test {
    _ = details;
}

test "RTT and exec share the same Session channel-open ticket" {
    var session: ssh.Session = .{};
    const sample: ssh.Session.OpenTicket = .{ .kind = .rtt, .id = 4 };
    const exec: ssh.Session.OpenTicket = .{ .kind = .exec, .id = 4 };
    try std.testing.expect(session.claimChannelOpen(sample));
    try std.testing.expect(session.claimChannelOpen(sample));
    try std.testing.expect(!session.claimChannelOpen(exec));
    session.finishChannelOpen(exec);
    try std.testing.expect(!session.claimChannelOpen(exec));
    session.finishChannelOpen(sample);
    try std.testing.expect(session.claimChannelOpen(exec));
    try std.testing.expect(!session.claimChannelOpen(sample));
}

test "RTT requests atomically reject a released or busy hop and preserve attempt identity" {
    const key: details.OperationKey = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(1) } }, .operation_id = 1, .attempt_id = 1 };
    var store: details.Store = .{};
    try store.begin(key, 2, .session);
    store.negotiated(key, 0, .{});
    try std.testing.expectError(error.TransportNotOnline, store.request(key, null, 10));
    try std.testing.expect(store.take(key, 0) == null);
    store.negotiated(key, 1, .{});
    const request = try store.request(key, null, 10);
    const first = store.take(key, 0).?;
    const second = store.take(key, 1).?;
    try std.testing.expectEqual(request, first.id);
    try std.testing.expectEqual(request, second.id);
    var next = key;
    next.owner.session.generation += 1;
    next.operation_id += 1;
    next.attempt_id = 2;
    try std.testing.expectError(error.CleanupNotReleased, store.begin(next, 2, .session));
    store.publish(key, 0, .{ .request_id = request, .status = .unavailable, .reason = .timed_out, .cleanup = .unknown }, false);
    try std.testing.expectError(error.SampleBusy, store.request(key, 0, 10));
    store.status(key, 0, .released);
    store.status(key, 1, .released);
    try store.begin(next, 2, .session);
    store.negotiated(key, 0, .{ .cipher_c2s = try details.Text(64).init("stale") });
    const current = try store.snapshot(next);
    try std.testing.expectEqual(@as(usize, 0), current.hops[0].metadata.cipher_c2s.len);
}

test "details application facade rejects a stale handle before native access" {
    const ApplicationHost = @import("ui/application_host.zig").ApplicationHost;
    var host: ApplicationHost = undefined;
    host.mappings = .empty;
    const handle: @import("host/identity.zig").SessionHandle = .{ .session_id = @fromBackingInt(7) };
    try std.testing.expectError(error.StaleSession, host.sshConnectionDetails(handle));
    try std.testing.expectError(error.StaleSession, host.requestSshRtt(handle, null));
    try std.testing.expectError(error.StaleSession, host.cancelSshRtt(handle, 1));
}

test "RTT ledger permits a later sample only after its previous real release" {
    const key: details.OperationKey = .{ .owner = .app, .operation_id = 2, .attempt_id = 1 };
    var ledger = try ssh.ResourceLedger.init(key, 1);
    try std.testing.expect(ledger.record(key, 0, .rtt_channel, .owned));
    try std.testing.expect(ledger.record(key, 0, .rtt_channel, .unknown));
    try std.testing.expect(!ledger.record(key, 0, .rtt_channel, .owned));
    try std.testing.expect(ledger.record(key, 0, .rtt_channel, .released));
    const first_release = ledger.snapshot().entry(0, .rtt_channel).released_sequence;
    try std.testing.expect(ledger.record(key, 0, .rtt_channel, .owned));
    try std.testing.expect(!ledger.snapshot().released());
    try std.testing.expect(ledger.snapshot().entry(0, .rtt_channel).acquired_sequence > first_release);
    try std.testing.expect(ledger.record(key, 0, .rtt_channel, .released));
    try std.testing.expect(ledger.record(key, 0, .transport, .owned));
    try std.testing.expect(ledger.record(key, 0, .transport, .released));
    try std.testing.expect(!ledger.record(key, 0, .transport, .owned));
}
