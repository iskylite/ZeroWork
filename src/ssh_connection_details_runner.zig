//! Isolated no-shell connection details/RTT driver; loopback fixture only.
const std = @import("std");
const ssh = @import("proto/ssh/session.zig");
const details = ssh.ConnectionDetails;
const Route = @import("proto/ssh/jump_transport.zig").Route;
const Exec = @import("proto/ssh/exec_bridge.zig").SshExecBridge;
const clock = @import("platform/realtime.zig");
const native = @import("generated_ssh_session");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const port = try std.fmt.parseInt(u16, args.next() orelse return error.MissingPort, 10);
    const mode = args.next() orelse return error.MissingMode;
    const path = args.next() orelse return error.MissingStore;
    const key: details.OperationKey = .{ .owner = .app, .operation_id = 81, .attempt_id = 3 };
    var library = try ssh.Library.init();
    defer library.deinit();
    if (std.mem.startsWith(u8, mode, "probe")) return runProbe(init, &library, port, path, std.mem.eql(u8, mode, "probe"));
    var trust = try @import("proto/ssh/host_key_store.zig").HostKeyStore.load(init.io, std.Io.Dir.cwd(), std.heap.c_allocator, path);
    defer trust.deinit();
    var facts: details.Store = .{};
    const routed = std.mem.eql(u8, mode, "route");
    var ledger = try ssh.ResourceLedger.init(key, if (routed) 2 else 1);
    defer _ = ledger.drainRetained();
    var options: ssh.Options = .{
        .host = "127.0.0.1",
        .port = port,
        .user = "operator",
        .auth = .{ .password = "fixture-password" },
        .host_key_store = &trust,
        .operation_key = key,
        .source_owner = .{ .id = @fromBackingInt(52), .revision = 6 },
        .connection_details = &facts,
        .details_source = .@"test",
        .resource_ledger = &ledger,
        .open_shell = false,
        .keepalive_sec = 0,
        .display_name = "target",
    };
    if (routed) {
        const hop_port = try std.fmt.parseInt(u16, args.next() orelse return error.MissingHop, 10);
        options.hop_count = 2;
        options.hop_index = 1;
        var parent = options;
        parent.hop_index = 0;
        parent.port = hop_port;
        parent.display_name = "bastion";
        parent.source_owner = .{ .id = @fromBackingInt(51), .revision = 4 };
        const route = try Route.connect(std.heap.c_allocator, &library, &.{ parent, options });
        defer route.deinit();
        try route.measureRtt(1500, null);
        try verify(&facts, key, 2);
        try std.testing.expectEqual(ssh.ReleaseReceipt.released, route.closeReceipt());
    } else {
        var session = try ssh.Session.connect(&library, options);
        defer session.close();
        try std.testing.expect(session.channel == null);
        const timeout: u32 = if (std.mem.eql(u8, mode, "timeout")) 30 else if (std.mem.eql(u8, mode, "slow-close")) 250 else 1500;
        const request = try facts.request(key, 0, timeout);
        const begin = clock.monotonicNs();
        try session.stepRtt(begin);
        const first = (try facts.snapshot(key)).hops[0].rtt_sample.?;
        try std.testing.expect(first.started_ns != null);
        try std.testing.expectError(error.SampleBusy, facts.request(key, 0, 100));
        // Exercise the real Exec mailbox on this same transport while the
        // sample owns native open_state. It must remain queued; cancellation
        // below sends neither a second channel-open nor an exec request.
        var exec = Exec.init(&session, std.heap.c_allocator);
        defer exec.deinitLocal();
        const queued = try exec.exec("fixture-must-not-execute", .{ .key = key, .timeout_ms = 2000 });
        try exec.step();
        try std.testing.expect(Exec.pollHandle(queued) == null);
        Exec.abortHandle(queued);
        try exec.step();
        try std.testing.expectEqual(.cancelled, Exec.pollHandle(queued).?.status);
        if (std.mem.eql(u8, mode, "cancel")) try facts.cancel(key, request);
        var observed_unknown = false;
        const deadline = begin + 4 * std.time.ns_per_s;
        while (clock.monotonicNs() < deadline) {
            try session.stepRtt(clock.monotonicNs());
            const sample = (try facts.snapshot(key)).hops[0].rtt_sample.?;
            try std.testing.expectEqual(first.started_ns, sample.started_ns);
            try std.testing.expectEqual(ssh.State.active, session.state);
            if (sample.cleanup == .unknown) {
                observed_unknown = true;
                try std.testing.expect(ledger.snapshot().hasUnknown());
                try std.testing.expectError(error.SampleBusy, facts.request(key, 0, 100));
            }
            if (sample.status != .pending and sample.cleanup == .released) break;
            native.zw_ssh_relay_pause();
        }
        const sample = (try facts.snapshot(key)).hops[0].rtt_sample.?;
        try std.testing.expectEqual(details.Cleanup.released, sample.cleanup);
        if (std.mem.eql(u8, mode, "cancel")) {
            try std.testing.expectEqual(details.Reason.cancelled, sample.reason.?);
        } else if (std.mem.eql(u8, mode, "timeout")) {
            try std.testing.expect(observed_unknown);
            try std.testing.expectEqual(details.Reason.timed_out, sample.reason.?);
            try std.testing.expect(sample.duration_ms == null);
        } else if (std.mem.eql(u8, mode, "reject")) {
            try std.testing.expectEqual(details.Reason.rejected, sample.reason.?);
        } else {
            try verify(&facts, key, 1);
            try std.testing.expect(sample.duration_ms.? >= 50);
            if (std.mem.eql(u8, mode, "slow-close")) {
                try std.testing.expect(observed_unknown);
                try std.testing.expectEqual(.ready, sample.status);
                try std.testing.expect(sample.reason == null);
                try std.testing.expect(sample.duration_ms.? < timeout);
            }
        }
        if (!std.mem.eql(u8, mode, "direct") and !std.mem.eql(u8, mode, "slow-close")) {
            // Cancellation/rejection/timeout must not poison a live transport.
            try session.measureRtt(1500, null);
            try verify(&facts, key, 1);
        }
        try std.testing.expect(session.channel == null);
        try std.testing.expectEqual(ssh.ReleaseReceipt.released, session.closeReceipt());
        try exec.sessionReleased();
    }
    try std.testing.expect(ledger.snapshot().released());
    const released = try facts.snapshot(key);
    try std.testing.expect(released.target_rtt_sample == null);
    for (released.hops[0..released.hop_count]) |hop| {
        try std.testing.expectEqual(details.Status.released, hop.status);
        try std.testing.expectEqual(.stale, hop.rtt_sample.?.status);
        try std.testing.expectEqual(details.Cleanup.released, hop.rtt_sample.?.cleanup);
    }
    std.debug.print("DETAILS_RTT_OK mode={s} released=true no_shell=true\n", .{mode});
}

fn runProbe(init: std.process.Init, library: *const ssh.Library, port: u16, path: []const u8, enabled: bool) !void {
    const probe = @import("ui/wizard_probe.zig");
    const operation = @import("host/operation.zig");
    var journal = operation.Journal.init(std.heap.c_allocator);
    defer journal.deinit();
    var controller = probe.Controller.init(std.heap.c_allocator, &journal);
    defer controller.deinit();
    controller.sample_rtt = enabled;
    const job = try controller.startWithTrustStore(.{
        .draft_id = 17,
        .revision = 6,
        .source_owner = .{ .id = @fromBackingInt(52), .revision = 6 },
        .name = "target",
        .host = "127.0.0.1",
        .port = port,
        .user = "operator",
        .auth = .password,
        .password = "fixture-password",
        .startup_commands = &.{"MUST_NEVER_EXECUTE"},
    }, &.{}, .{}, 1, library, path);
    const expected = job.key;
    const deadline = clock.monotonicNs() + 4 * std.time.ns_per_s;
    const outcome = while (clock.monotonicNs() < deadline) {
        switch (try controller.poll(job)) {
            .finished => |value| break value,
            .pending => {},
        }
        native.zw_ssh_relay_pause();
    } else return error.ProbeTimedOut;
    if (outcome.failure) |failure| return failure;
    try std.testing.expectEqual(.released, outcome.cleanup);
    try std.testing.expect(outcome.resources.?.released());
    try std.testing.expectEqual(ssh.ResourceState.absent, outcome.resources.?.entry(0, .shell).state);
    const snapshot = outcome.details_snapshot orelse return error.MissingDetails;
    try std.testing.expect(snapshot.key.eql(expected) and snapshot.key.owner == .app);
    try std.testing.expectEqual(details.Source.@"test", snapshot.source);
    try std.testing.expect(snapshot.target_rtt_sample == null);
    const hop = snapshot.hops[0];
    try std.testing.expectEqual(details.Status.released, hop.status);
    try std.testing.expect(hop.metadata.accepted_auth_methods.contains(.password));
    if (enabled) {
        try std.testing.expectEqual(.stale, hop.rtt_sample.?.status);
        try std.testing.expectEqual(details.Cleanup.released, hop.rtt_sample.?.cleanup);
        try std.testing.expect(hop.rtt_sample.?.duration_ms.? >= 50);
        try std.testing.expectEqual(ssh.ResourceState.released, outcome.resources.?.entry(0, .rtt_channel).state);
    } else {
        try std.testing.expect(hop.rtt_sample == null);
        try std.testing.expectEqual(ssh.ResourceState.absent, outcome.resources.?.entry(0, .rtt_channel).state);
    }
    std.debug.print("DETAILS_METADATA hop=0 algorithm={s} c2s={s} s2c={s} fingerprint={s} rtt_ms=", .{ hop.metadata.host_key_algorithm.slice(), hop.metadata.cipher_c2s.slice(), hop.metadata.cipher_s2c.slice(), hop.metadata.fingerprint.slice() });
    if (hop.rtt_sample) |sample| std.debug.print("{d}\n", .{sample.duration_ms.?}) else std.debug.print("none\n", .{});
    try controller.retire(job);
    try std.testing.expectEqual(@as(usize, 0), journal.records.items.len);
    _ = init;
    std.debug.print("DETAILS_RTT_OK mode={s} released=true no_shell=true\n", .{if (enabled) "probe" else "probe-default"});
}

fn verify(store: *details.Store, key: details.OperationKey, count: usize) !void {
    const snapshot = try store.snapshot(key);
    try std.testing.expectEqual(count, snapshot.hop_count);
    try std.testing.expect(snapshot.key.eql(key));
    try std.testing.expectEqual(details.Source.@"test", snapshot.source);
    for (snapshot.hops[0..count], 0..) |hop, index| {
        try std.testing.expectEqual(details.Status.online, hop.status);
        try std.testing.expectEqual(.ready, hop.rtt_sample.?.status);
        try std.testing.expectEqual(details.Cleanup.released, hop.rtt_sample.?.cleanup);
        try std.testing.expect(hop.metadata.host_key_algorithm.len > 0);
        try std.testing.expect(hop.metadata.cipher_c2s.len > 0 and hop.metadata.cipher_s2c.len > 0);
        try std.testing.expect(std.mem.startsWith(u8, hop.metadata.fingerprint.slice(), "SHA256:"));
        try std.testing.expect(hop.metadata.accepted_auth_methods.contains(.password));
        try std.testing.expect(hop.endpoint.asset_owner != null);
        std.debug.print("DETAILS_METADATA hop={d} algorithm={s} c2s={s} s2c={s} fingerprint={s} rtt_ms={d}\n", .{ index, hop.metadata.host_key_algorithm.slice(), hop.metadata.cipher_c2s.slice(), hop.metadata.cipher_s2c.slice(), hop.metadata.fingerprint.slice(), hop.rtt_sample.?.duration_ms.? });
    }
    // Target is its own complete route sample, never the sum of cumulative hops.
    try std.testing.expectEqual(snapshot.hops[count - 1].rtt_sample.?.duration_ms, snapshot.target_rtt_sample.?.duration_ms);
}
