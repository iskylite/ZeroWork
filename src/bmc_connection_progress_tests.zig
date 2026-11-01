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
