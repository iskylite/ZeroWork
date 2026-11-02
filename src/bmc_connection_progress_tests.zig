//! Synthetic telemetry only: no sockets, account stores or real BMC access.
const std = @import("std");
const progress = @import("plugins/bmc_ikvm/connection_progress.zig");
const probe = @import("plugins/bmc_ikvm/probe.zig");
const contract = @import("host/probe_contract.zig");

test "BMC connection progress measures monotonic phase and total time and marks human waits" {
    var tracker = progress.Tracker.initAt(3, 10_000);
    tracker.setStageAt(.route, 10_100);
    var value = tracker.snapshotAt(11_500);
    try std.testing.expectEqual(@as(u64, 1500), value.elapsed_ms);
    try std.testing.expectEqual(@as(u64, 1400), value.stage_elapsed_ms);
    try std.testing.expectEqual(@as(u8, 3), value.route_hops);
    tracker.setStageAt(.tls_handshake, 11_600);
    tracker.setStageAt(.waiting_certificate, 12_000);
    value = tracker.snapshotAt(72_000);
    try std.testing.expect(value.waiting_for_user);
    try std.testing.expectEqual(@as(u64, 60_000), value.stage_elapsed_ms);
    try std.testing.expect(value.failure_code == null);
    tracker.setStageAt(.tls_handshake, 72_100);
    tracker.setStageAt(.waiting_credentials, 72_500);
    try std.testing.expect(tracker.snapshotAt(73_000).waiting_for_user);
    tracker.setStageAt(.web_login, 74_000);
    // Repeated worker polls do not restart the phase stopwatch or add logs.
    tracker.setStageAt(.web_login, 75_000);
    value = tracker.snapshotAt(76_000);
    try std.testing.expect(!value.waiting_for_user);
    try std.testing.expectEqual(@as(u64, 2000), value.stage_elapsed_ms);
    tracker.setStageAt(.awaiting_first_frame, 77_000);
    value = tracker.snapshotAt(200_000);
    try std.testing.expectEqual(progress.Stage.awaiting_first_frame, value.stage);
    try std.testing.expect(value.failure_code == null);
    try std.testing.expectEqual(@as(u64, 123_000), value.stage_elapsed_ms);
    // Backwards caller timestamps are clamped, never becoming unsigned ages.
    tracker.setStageAt(.streaming, 76_500);
    try std.testing.expectEqual(@as(u64, 0), tracker.snapshotAt(76_000).stage_elapsed_ms);
}

test "BMC connection progress bounds logs and retains the original failure after cleanup and rollover" {
    var tracker = progress.Tracker.initAt(0, 100);
    tracker.setStageAt(.web_login, 110);
    tracker.failAt(error.InvalidWebSessionHeaders, 200);
    const failed = tracker.snapshotAt(250);
    try std.testing.expectEqual(progress.Stage.web_login, failed.failure_stage.?);
    try std.testing.expectEqualStrings("InvalidWebSessionHeaders", failed.failure_code.?);
    tracker.setStageAt(.cleanup, 300);
    for (0..70) |i| tracker.noteAt(.{ .resource = .system, .http_status = 404, .validity = .unavailable }, 301 + i);
    tracker.finishAt(false, 400);
    const value = tracker.snapshotAt(5000);
    try std.testing.expectEqual(progress.Stage.failed, value.stage);
    try std.testing.expectEqual(@as(u64, 300), value.elapsed_ms);
    try std.testing.expectEqual(@as(u8, progress.capacity), value.event_count);
    try std.testing.expectEqual(progress.Stage.web_login, value.failure_stage.?);
    try std.testing.expectEqualStrings("InvalidWebSessionHeaders", value.failure_code.?);
    try std.testing.expect(value.events[0].sequence > 1);
    for (value.events[0 .. value.event_count - 1], value.events[1..value.event_count]) |before, after| {
        try std.testing.expect(before.sequence < after.sequence);
        try std.testing.expect(before.at_ms <= after.at_ms);
    }
    // Earlier snapshots own the event array; later writes cannot mutate it.
    try std.testing.expectEqual(@as(u8, 3), failed.event_count);
    try std.testing.expectEqual(progress.Stage.failed, failed.events[2].stage);
}

test "BMC connection progress cancellation stays separate from authentication failure" {
    var tracker = progress.Tracker.initAt(0, 100);
    tracker.setStageAt(.waiting_credentials, 200);
    tracker.failAt(error.Cancelled, 300);
    tracker.setStageAt(.cleanup, 400);
    tracker.finishAt(true, 500);
    const value = tracker.snapshotAt(1000);
    try std.testing.expectEqual(progress.Stage.cancelled, value.stage);
    try std.testing.expect(value.failure_code == null and value.failure_stage == null);
    try std.testing.expect(!value.waiting_for_user);
    try std.testing.expectEqual(@as(u64, 400), value.elapsed_ms);
}

test "BMC connection progress preserves safe request failure context without logging every body read" {
    var tracker = progress.Tracker.initAt(1, 0);
    tracker.setStageAt(.public_script, 10);
    for (0..400) |index| tracker.setContext(.{ .channel = .management, .method = .get, .path = .public_script, .phase = .response_body, .http_status = 200, .received_bytes = index * 1024, .duration_ms = index * 10 });
    try std.testing.expectEqual(@as(u8, 1), tracker.snapshotAt(100).event_count);
    tracker.failAt(error.HttpTimeout, 4100);
    tracker.setStageAt(.cleanup, 4200);
    tracker.setContext(.{ .channel = .management, .method = .delete, .path = .web_session, .phase = .response_validate });
    for (0..40) |index| tracker.noteAt(.{ .code = .remote_logout_unconfirmed, .err = error.TlsClosed }, 4201 + index);
    tracker.finishAt(false, 4300);
    const snapshot = tracker.snapshotAt(4400);
    const failure = snapshot.failure_event.?;
    try std.testing.expectEqual(progress.Stage.public_script, failure.stage);
    try std.testing.expectEqualStrings("HttpTimeout", failure.error_code.?);
    try std.testing.expectEqual(progress.RequestPath.public_script, failure.context.?.path);
    try std.testing.expectEqual(progress.Phase.response_body, failure.context.?.phase);
    try std.testing.expectEqual(@as(?u16, 200), failure.context.?.http_status);
    try std.testing.expectEqual(@as(?u64, 399 * 1024), failure.context.?.received_bytes);
    try std.testing.expectEqual(@as(u8, 32), snapshot.event_count);
    try std.testing.expectEqualStrings("TlsClosed", snapshot.events[0].error_code.?);
}

test "BMC SSH route diagnostics preserve the original jump failure and format only its proven target" {
    const vm = @import("plugins/bmc_ikvm/view_model.zig");
    var tracker = progress.Tracker.initAt(1, 0);
    tracker.setStageAt(.route, 1);
    tracker.setContext(.{ .channel = .ssh, .ssh_hop = 1, .ssh_hops = 1, .phase = .ssh_handshake });
    tracker.failAt(error.SshHandshakeReceiveFailed, 2);
    tracker.setStageAt(.cleanup, 3);
    tracker.setContext(.{ .phase = .connect });
    for (0..40) |index| tracker.noteAt(.{ .code = .remote_logout_unconfirmed, .err = error.TlsClosed }, 4 + index);
    tracker.failAt(error.TlsClosed, 44);
    tracker.finishAt(false, 45);
    const snapshot = tracker.snapshotAt(46);
    try std.testing.expectEqualStrings("SshHandshakeReceiveFailed", snapshot.failure_code.?);
    try std.testing.expectEqual(progress.Stage.route, snapshot.failure_stage.?);
    try std.testing.expectEqual(@as(?u8, 1), snapshot.failure_event.?.context.?.ssh_hop);
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    try vm.writeLogMessage(&writer.writer, snapshot.failure_event.?, "bmc.invalid:443");
    try std.testing.expectEqualStrings("建立连接路由 · 失败 · SSH 路由 · 跳板 1/1 · SSH 握手 · SshHandshakeReceiveFailed", writer.written());
    writer.clearRetainingCapacity();
    try vm.writeStepDiagnosticsForTarget(&writer.writer, snapshot, .route, "bmc.invalid:443");
    try std.testing.expect(std.mem.indexOf(u8, writer.written(), "保留的原始失败") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.written(), "SSH 路由 · 跳板 1/1 · SSH 握手") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.written(), "bmc.invalid") == null);
    writer.clearRetainingCapacity();
    // Without a proven hop, say SSH route and do not invent a BMC target.
    try vm.writeLogMessage(&writer.writer, .{ .stage = .route, .kind = .failure, .context = .{ .channel = .ssh, .phase = .connect }, .error_code = "SshHandshakeReceiveFailed" }, "bmc.invalid:443");
    try std.testing.expectEqualStrings("建立连接路由 · 失败 · SSH 路由 · 建立路由 · SshHandshakeReceiveFailed", writer.written());
    writer.clearRetainingCapacity();
    try vm.writeLogMessage(&writer.writer, .{ .stage = .route, .kind = .diagnostic, .context = .{ .phase = .connect }, .code = .route_connected }, "bmc.invalid:443");
    try std.testing.expectEqualStrings("建立连接路由 · 管理通道 → bmc.invalid:443 · 建立路由 · 路由已建立", writer.written());
}

test "BMC connection progress samples wall time independently from monotonic request duration" {
    var tracker = progress.Tracker.init(0);
    const mono = progress.nowMs();
    tracker.setStageAt(.public_script, mono);
    tracker.setContext(.{ .method = .get, .path = .public_script, .phase = .response_body, .duration_ms = 1534 });
    // Advancing the supplied monotonic clock by a week must not manufacture
    // a wall-clock timestamp a week in the future.
    const week_ms = 7 * 24 * 60 * 60 * 1000;
    tracker.noteAt(.{ .http_status = 200 }, mono + week_ms);
    tracker.failAt(error.HttpTimeout, mono + week_ms + 1);
    tracker.setStageAt(.cleanup, mono + week_ms + 2);
    tracker.finishAt(false, mono + week_ms + 3);
    const snapshot = tracker.snapshotAt(mono + week_ms + 4);
    const first_wall = snapshot.started_unix_ms.?;
    const failure = snapshot.failure_event.?;
    try std.testing.expect(first_wall > 1_500_000_000_000);
    try std.testing.expect(failure.at_unix_ms.? >= first_wall);
    try std.testing.expect(failure.at_unix_ms.? < first_wall + 24 * 60 * 60 * 1000);
    try std.testing.expect(failure.at_ms >= week_ms);
    try std.testing.expectEqual(@as(?u64, 1534), failure.duration_ms);
    try std.testing.expectEqualStrings("HttpTimeout", failure.error_code.?);
}

const Concurrent = struct {
    tracker: progress.Tracker = progress.Tracker.initAt(2, 0),
    done: std.atomic.Value(bool) = .init(false),
    fn write(self: *Concurrent) void {
        for (0..3000) |i| {
            self.tracker.setStageAt(if (i % 2 == 0) .redfish_discovery else .firmware_confirmation, i * 2);
            self.tracker.noteAt(.{ .resource = .system, .http_status = 200, .validity = .valid }, i * 2 + 1);
        }
        self.done.store(true, .release);
    }
};
test "BMC connection progress snapshots never expose a torn bounded worker log" {
    var fixture: Concurrent = .{};
    const worker = try std.Thread.spawn(.{}, Concurrent.write, .{&fixture});
    defer worker.join();
    while (true) {
        const value = fixture.tracker.snapshotAt(6000);
        try std.testing.expect(value.event_count <= progress.capacity);
        if (value.event_count != 0) {
            try std.testing.expectEqual(value.revision, value.events[value.event_count - 1].sequence);
            for (value.events[0 .. value.event_count - 1], value.events[1..value.event_count]) |before, after| {
                try std.testing.expectEqual(before.sequence + 1, after.sequence);
                try std.testing.expect(before.at_ms <= after.at_ms);
            }
        }
        if (fixture.done.load(.acquire)) break;
    }
}

test "BMC connection progress probe reports truthful native phase and elapsed seconds without hop completion" {
    var buffer: [256]u8 = undefined;
    const route = try probe.formatProgress(.{ .stage = .route, .route_hops = 3, .elapsed_ms = 19_800, .stage_elapsed_ms = 18_400 }, &buffer);
    try std.testing.expectEqualStrings("建立 3 跳 SSH 链 · 阶段 18 秒 · 总计 19 秒", route);
    try std.testing.expect(std.mem.indexOf(u8, route, "%") == null);
    try std.testing.expectEqual(contract.Stage.transport, probe.probeStage(.route));
    try std.testing.expectEqual(contract.Stage.trust, probe.probeStage(.waiting_certificate));
    try std.testing.expectEqual(contract.Stage.authentication, probe.probeStage(.waiting_credentials));
    try std.testing.expectEqual(contract.Stage.discovery, probe.probeStage(.public_script));
    try std.testing.expectEqualStrings("等待用户确认证书 · 阶段 60 秒 · 总计 64 秒", try probe.formatProgress(.{ .stage = .waiting_certificate, .elapsed_ms = 64_000, .stage_elapsed_ms = 60_000 }, &buffer));
    try std.testing.expectEqualStrings("等待用户输入凭据 · 阶段 3 秒 · 总计 8 秒", try probe.formatProgress(.{ .stage = .waiting_credentials, .elapsed_ms = 8000, .stage_elapsed_ms = 3000 }, &buffer));
}

test "BMC connection progress video TLS and certificate wait remain explicit video work" {
    const vm = @import("plugins/bmc_ikvm/view_model.zig");
    var tracker = progress.Tracker.initAt(0, 0);
    var projection: vm.ProgressProjection = .{};
    const stages = [_]progress.Stage{ .oem_session, .websocket_upgrade, .video_tls_handshake, .waiting_video_certificate, .video_tls_handshake, .websocket_upgrade, .rfb_negotiation, .awaiting_first_frame };
    for (stages, 0..) |stage, index| {
        tracker.setStageAt(stage, (index + 1) * 100);
        const value = tracker.snapshotAt((index + 1) * 100 + 50);
        projection.observe(value);
        try std.testing.expectEqual(vm.ProgressGroup.video, vm.progressGroup(stage).?);
        try std.testing.expectEqual(if (stage == .waiting_video_certificate) vm.StepState.waiting_for_user else vm.StepState.current, projection.state(value, .video));
        try std.testing.expectEqual(vm.StepState.waiting, projection.state(value, .tls));
        try std.testing.expectEqual(stage == .waiting_video_certificate, value.waiting_for_user);
        try std.testing.expectEqual(@as(u64, 50), value.stage_elapsed_ms);
    }
    try std.testing.expectEqualStrings("视频 TLS 握手", progress.stageLabel(.video_tls_handshake));
    try std.testing.expectEqualStrings("等待用户确认视频通道证书", progress.stageLabel(.waiting_video_certificate));
}
