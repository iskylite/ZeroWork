//! Synthetic wire tests only. No credentials, network or remote machine input.
const std = @import("std");
const T = std.testing;
const remote = @import("plugins/bmc_ikvm/remote_input.zig");
const ai = @import("plugins/bmc_ikvm/automation_input.zig");
const content = @import("host/content_context.zig");
const identity = @import("host/identity.zig");
const video = @import("plugins/bmc_ikvm/video_pipeline.zig");
const frames = @import("plugins/bmc_ikvm/framebuffer.zig");
const budgets = @import("host/frame_budget.zig");
const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(823) };

const Fixture = struct {
    service: remote.Service = remote.Service.init(owner),
    context: content.Context = undefined,
    cancel: std.atomic.Value(bool) = .init(false),
    fn init(self: *Fixture) !void {
        try self.service.setConnected(true, 1);
        try self.service.setControl(true, 2);
        self.context = .{ .owner = owner, .window_id = @fromBackingInt(1), .window = .{ .context = self, .request_fullscreen = fullscreen, .fullscreen_state = fullscreenState, .transfer = transfer }, .consumer = .{ .context = self, .consume = consume } };
        try self.context.setAuthorization(true, 2);
        self.context.setFocus(true, false);
    }
    fn proof(self: *Fixture) !ai.Proof {
        return (try self.context.acquireAutomation(2, &self.cancel, null, std.math.maxInt(u64))).proof;
    }
    fn authority(self: *Fixture) !ai.Authority {
        const snapshot = try self.service.snapshot(self.service.binding());
        return .{ .owner = owner, .binding_generation = owner.generation, .transport_generation = snapshot.transport_generation, .control_generation = snapshot.control_generation, .input_epoch = snapshot.input_epoch, .geometry_generation = snapshot.geometry_generation, .proof = try self.proof() };
    }
    fn submit(self: *Fixture, operation_id: u64, action: ai.Action) !ai.Receipt {
        return self.service.submitAutomation(self.service.binding(), try self.authority(), .{ .operation_id = operation_id, .action = action });
    }
    fn status(self: *Fixture, operation_id: u64) !ai.Receipt {
        return self.service.automationStatus(self.service.binding(), operation_id);
    }
    fn consume(raw: *anyopaque, value: content.Input) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (value == .release_all) _ = self.service.releaseAll(self.service.binding(), .released);
    }
    fn fullscreen(_: *anyopaque, _: bool) !void {}
    fn fullscreenState(_: *anyopaque) bool {
        return false;
    }
    fn transfer(_: *anyopaque, _: identity.SessionHandle, _: identity.WindowId) !void {}
};
const Output = struct {
    const Trigger = enum { release, cancel, takeover, revoke_control };
    data: [16384]u8 = undefined,
    length: usize = 0,
    chunk: usize = 16384,
    calls: usize = 0,
    aborts: usize = 0,
    fail_call: ?usize = null,
    fixture: ?*Fixture = null,
    trigger_call: ?usize = null,
    trigger: Trigger = .release,
    fn write(raw: *anyopaque, input_bytes: []const u8) !usize {
        const self: *Output = @ptrCast(@alignCast(raw));
        self.calls += 1;
        if (self.fail_call == self.calls) return error.SyntheticWriteFailed;
        const length = @min(input_bytes.len, self.chunk);
        if (length > self.data.len - self.length) return error.SyntheticBufferFull;
        @memcpy(self.data[self.length..][0..length], input_bytes[0..length]);
        self.length += length;
        if (self.trigger_call == self.calls) {
            self.trigger_call = null;
            const fixture = self.fixture.?;
            switch (self.trigger) {
                .release => fixture.context.release(fixture.context.automation.?),
                .cancel => fixture.cancel.store(true, .release),
                .takeover => fixture.service.setFocus(true),
                .revoke_control => try fixture.service.setControl(false, (try fixture.service.snapshot(fixture.service.binding())).control_generation + 1),
            }
        }
        return length;
    }
    fn abort(raw: *anyopaque) void {
        const self: *Output = @ptrCast(@alignCast(raw));
        self.aborts += 1;
    }
    fn wire(self: *Output, generation: u64) remote.Wire {
        return .{ .context = self, .generation = generation, .write = write, .abort = abort };
    }
    fn bytes(self: *const Output) []const u8 {
        return self.data[0..self.length];
    }
};
fn expectKey(bytes: []const u8, keysym: u32, down: bool) !void {
    try T.expectEqual(@as(usize, 8), bytes.len);
    try T.expectEqualSlices(u8, &.{ 4, @intFromBool(down), 0, 0 }, bytes[0..4]);
    try T.expectEqual(keysym, std.mem.readInt(u32, bytes[4..8], .big));
}

test "BMC AI input real automation lease sends an unfocused chord with ordered downs and reverse ups" {
    var fixture: Fixture = .{};
    try fixture.init();
    const snapshot = try fixture.service.snapshot(fixture.service.binding());
    try T.expect(!snapshot.focused);
    const accepted = try fixture.submit(1, .{ .chord = try ai.Chord.init(&.{ 0xffe3, 0xffe9, 0xffbe }) });
    try T.expectEqual(ai.Status.accepted, accepted.status);
    try T.expectEqual(@as(u16, 0), accepted.sent_events);
    try T.expectEqual(@as(u16, 6), accepted.total_events);
    var output: Output = .{ .chunk = 3 };
    try T.expectEqual(@as(usize, 6), try fixture.service.pump(output.wire(1)));
    for ([_]u32{ 0xffe3, 0xffe9, 0xffbe }, 0..) |symbol, index| {
        try expectKey(output.bytes()[index * 8 ..][0..8], symbol, true);
        try expectKey(output.bytes()[(5 - index) * 8 ..][0..8], symbol, false);
    }
    const sent = try fixture.status(1);
    try T.expectEqual(ai.Status.sent, sent.status);
    try T.expectEqual(sent.total_events, sent.sent_events);
    try T.expectEqual(owner, sent.owner);
    try T.expectEqual(@as(usize, 0), fixture.service.pressed_count);
    try T.expect(!(try fixture.service.snapshot(fixture.service.binding())).focused);
}

test "BMC AI input rejects stale binding transport control epoch proof and expired observation authority" {
    var fixture: Fixture = .{};
    try fixture.init();
    const authority = try fixture.authority();
    const request: ai.Request = .{ .operation_id = 1, .action = .{ .pointer_move = .{ .x = 4, .y = 5 } } };
    for (0..7) |field| {
        var stale = authority;
        switch (field) {
            0 => stale.owner.generation += 1,
            1 => stale.binding_generation += 1,
            2 => stale.transport_generation += 1,
            3 => stale.control_generation += 1,
            4 => stale.input_epoch += 1,
            5 => stale.proof.lease.id += 1,
            else => stale.expires_at_ms = 1,
        }
        try T.expectError(if (field < 2) error.StaleBinding else error.StaleAutomationAuthority, fixture.service.submitAutomation(fixture.service.binding(), stale, request));
    }
    fixture.service.setFocus(true);
    try T.expectError(error.HumanInputActive, fixture.service.submitAutomation(fixture.service.binding(), authority, request));
    try T.expectEqual(@as(usize, 0), fixture.service.automation_count);
}

test "BMC AI input compiles complete US ASCII text rejects Unicode and controls without implied Enter" {
    var fixture: Fixture = .{};
    try fixture.init();
    try T.expectError(error.UnsupportedText, fixture.submit(1, .{ .text = try ai.Text.init("hello\n", .us_ascii) }));
    try T.expectError(error.UnsupportedText, fixture.submit(1, .{ .text = try ai.Text.init("\xc3\xa9", .us_ascii) }));
    try T.expectError(error.UnsupportedKey, fixture.submit(1, .{ .key = 0x0101f600 }));
    try T.expectEqual(@as(usize, 0), fixture.service.automation_count);
    _ = try fixture.submit(1, .{ .text = try ai.Text.init("aA! ", .us_ascii) });
    var output: Output = .{};
    _ = try fixture.service.pump(output.wire(1));
    try T.expectEqual(ai.Status.sent, (try fixture.status(1)).status);
    for (0..output.length / 8) |index| {
        const symbol = std.mem.readInt(u32, output.bytes()[index * 8 + 4 ..][0..4], .big);
        try T.expect(symbol != 0xff0d);
    }
    try expectKey(output.bytes()[0..8], 'a', true);
    try expectKey(output.bytes()[16..24], 0xffe1, true);
    try expectKey(output.bytes()[24..32], 'A', true);
    try T.expectEqual(@as(usize, 0), fixture.service.pressed_count);
}

test "BMC AI input pointer move right double click drag and wheel finish with no button held" {
    var fixture: Fixture = .{};
    try fixture.init();
    var output: Output = .{};
    _ = try fixture.submit(1, .{ .pointer_move = .{ .x = 10, .y = 20 } });
    _ = try fixture.service.pump(output.wire(1));
    _ = try fixture.submit(2, .{ .click = .{ .point = .{ .x = 11, .y = 21 }, .button = .right } });
    _ = try fixture.service.pump(output.wire(1));
    _ = try fixture.submit(3, .{ .click = .{ .point = .{ .x = 12, .y = 22 }, .count = 2 } });
    _ = try fixture.service.pump(output.wire(1));
    _ = try fixture.submit(4, .{ .drag = try ai.Drag.init(&.{ .{ .x = 2, .y = 3 }, .{ .x = 20, .y = 30 }, .{ .x = 40, .y = 50 } }, .left) });
    _ = try fixture.service.pump(output.wire(1));
    _ = try fixture.submit(5, .{ .wheel = .{ .point = .{ .x = 8, .y = 9 }, .steps_x = -1, .steps_y = 2 } });
    _ = try fixture.service.pump(output.wire(1));
    for (1..6) |id| try T.expectEqual(ai.Status.sent, (try fixture.status(id)).status);
    try T.expectEqualSlices(u8, &.{ 5, 0, 0, 10, 0, 20 }, output.bytes()[0..6]);
    try T.expectEqualSlices(u8, &.{ 5, 4, 0, 11, 0, 21 }, output.bytes()[12..18]);
    try T.expectEqual(@as(u8, 0), fixture.service.pressed_buttons);
}

test "BMC AI input queue pressure and duplicate calls never enqueue half an action or replay it" {
    var fixture: Fixture = .{};
    try fixture.init();
    for (1..remote.Service.automation_capacity + 1) |id| _ = try fixture.submit(id, .{ .key = 0xffe1 });
    try T.expectError(error.AutomationOperationInFlight, fixture.submit(9, .{ .chord = try ai.Chord.init(&.{ 0xffe3, 'x' }) }));
    const duplicate = try fixture.submit(1, .{ .key = 0xffe1 });
    try T.expectEqual(ai.Status.accepted, duplicate.status);
    try T.expectError(error.OperationConflict, fixture.submit(1, .{ .key = 0xffe2 }));
    var output: Output = .{};
    try T.expectEqual(@as(usize, 2), try fixture.service.pump(output.wire(1)));
    _ = try fixture.submit(1, .{ .key = 0xffe1 });
    try T.expectEqual(@as(usize, 0), try fixture.service.pump(output.wire(1)));
    try T.expectEqual(@as(usize, 16), output.length);
}

test "BMC AI input lease release and cancellation before dispatch report cancelled unsent" {
    for ([_]bool{ false, true }) |cancel| {
        var fixture: Fixture = .{};
        try fixture.init();
        _ = try fixture.submit(1, .{ .key = 'a' });
        if (cancel) fixture.cancel.store(true, .release) else fixture.context.release(fixture.context.automation.?);
        var output: Output = .{};
        try T.expectEqual(@as(usize, 0), try fixture.service.pump(output.wire(1)));
        try T.expectEqual(ai.Status.cancelled_unsent, (try fixture.status(1)).status);
        try T.expectEqual(@as(usize, 0), output.length);
    }
}

test "BMC AI input revoke control cancel and manual takeover release only actual downs in reverse order" {
    for ([_]Output.Trigger{ .release, .cancel, .takeover, .revoke_control }) |trigger| {
        var fixture: Fixture = .{};
        try fixture.init();
        _ = try fixture.submit(1, .{ .chord = try ai.Chord.init(&.{ 0xffe3, 0xffe9, 'a' }) });
        var output: Output = .{ .fixture = &fixture, .trigger_call = 3, .trigger = trigger };
        try T.expectEqual(@as(usize, 6), try fixture.service.pump(output.wire(1)));
        try T.expectEqual(ai.Status.outcome_unknown, (try fixture.status(1)).status);
        try T.expectEqual(@as(u16, 3), (try fixture.status(1)).sent_events);
        try expectKey(output.bytes()[24..32], 'a', false);
        try expectKey(output.bytes()[32..40], 0xffe9, false);
        try expectKey(output.bytes()[40..48], 0xffe3, false);
        try T.expectEqual(@as(usize, 0), fixture.service.pressed_count);
        try T.expectEqual(@as(usize, 0), output.aborts);
    }
}

test "BMC AI input partial raw write aborts without replay and keeps uncertain receipt on reconnect" {
    var fixture: Fixture = .{};
    try fixture.init();
    const old = try fixture.authority();
    _ = try fixture.service.submitAutomation(fixture.service.binding(), old, .{ .operation_id = 1, .action = .{ .key = 'a' } });
    var output: Output = .{ .fixture = &fixture, .chunk = 3, .trigger_call = 1 };
    try T.expectError(error.InputWriteInterrupted, fixture.service.pump(output.wire(1)));
    const receipt = try fixture.status(1);
    try T.expectEqual(ai.Status.outcome_unknown, receipt.status);
    try T.expectEqual(@as(u16, 0), receipt.sent_events);
    try T.expect(receipt.possibly_written);
    try T.expectEqual(@as(usize, 1), output.aborts);
    try T.expectEqual(@as(usize, 3), output.length);
    try fixture.service.setConnected(true, 2);
    try fixture.service.setControl(true, 3);
    try T.expectError(error.InputOutcomeUnknown, fixture.service.submitAutomation(fixture.service.binding(), old, .{ .operation_id = 2, .action = .{ .key = 'a' } }));
    try T.expectEqual(@as(usize, 0), try fixture.service.pump(output.wire(2)));
    try T.expectEqual(ai.Status.outcome_unknown, (try fixture.status(1)).status);
}

test "BMC AI input failed send after first message reports actual sent range and no automatic retry" {
    var fixture: Fixture = .{};
    try fixture.init();
    _ = try fixture.submit(1, .{ .key = 0xffe1 });
    var output: Output = .{ .fail_call = 2 };
    try T.expectError(error.SyntheticWriteFailed, fixture.service.pump(output.wire(1)));
    const receipt = try fixture.status(1);
    try T.expectEqual(ai.Status.outcome_unknown, receipt.status);
    try T.expectEqual(@as(u16, 1), receipt.sent_events);
    _ = try fixture.submit(1, .{ .key = 0xffe1 });
    try T.expectEqual(@as(usize, 0), try fixture.service.pump(output.wire(1)));
    try T.expectEqual(@as(usize, 8), output.length);
}

test "BMC AI input complete in flight move remains sent when lease is released in write callback" {
    var fixture: Fixture = .{};
    try fixture.init();
    _ = try fixture.submit(1, .{ .pointer_move = .{ .x = 2, .y = 3 } });
    var output: Output = .{ .fixture = &fixture, .trigger_call = 1 };
    _ = try fixture.service.pump(output.wire(1));
    try T.expectEqual(ai.Status.sent, (try fixture.status(1)).status);
}

test "BMC AI input lease budget stops at 32 steps and bounded history cannot replay evicted operation ids" {
    var fixture: Fixture = .{};
    try fixture.init();
    var output: Output = .{};
    for (1..33) |id| {
        _ = try fixture.submit(id, .{ .key = 0xffe1 });
        _ = try fixture.service.pump(output.wire(1));
    }
    try T.expectError(error.AutomationBudgetExceeded, fixture.submit(33, .{ .key = 0xffe1 }));
    fixture.context.release(fixture.context.automation.?);
    while (fixture.context.drainRevocation()) |_| {}
    for (33..65) |id| {
        _ = try fixture.submit(id, .{ .key = 0xffe1 });
        _ = try fixture.service.pump(output.wire(1));
    }
    fixture.context.release(fixture.context.automation.?);
    while (fixture.context.drainRevocation()) |_| {}
    _ = try fixture.submit(65, .{ .key = 0xffe1 });
    _ = try fixture.service.pump(output.wire(1));
    try T.expectError(error.UnknownOperation, fixture.status(1));
    try T.expectError(error.OperationExpired, fixture.submit(1, .{ .key = 0xffe1 }));
}

test "BMC AI input manual sent watermark advances only on complete wire messages" {
    var fixture: Fixture = .{};
    try fixture.init();
    fixture.service.setFocus(true);
    try T.expect(fixture.service.submit(fixture.service.binding(), fixture.service.command(1, .{ .key = .{ .keysym = 0xffe1, .down = true } })) == .accepted);
    try T.expect(fixture.service.submit(fixture.service.binding(), fixture.service.command(2, .{ .key = .{ .keysym = 0xffe1, .down = false } })) == .accepted);
    try T.expectEqual(@as(u64, 0), (try fixture.service.snapshot(fixture.service.binding())).last_sent_input_sequence);
    var output: Output = .{ .chunk = 3 };
    _ = try fixture.service.pump(output.wire(1));
    const snapshot = try fixture.service.snapshot(fixture.service.binding());
    try T.expectEqual(@as(u64, 2), snapshot.last_sent_input_sequence);
    try T.expectEqual(@as(u64, 1), snapshot.last_sent_transport_generation);
}

test "BMC AI input unknown locks old lease until renewed authority and fresh epoch" {
    var fixture: Fixture = .{};
    try fixture.init();
    _ = try fixture.submit(1, .{ .key = 0xffe1 });
    var output: Output = .{ .fixture = &fixture, .trigger_call = 1, .trigger = .takeover };
    _ = try fixture.service.pump(output.wire(1));
    fixture.service.setFocus(false);
    try T.expectError(error.InputOutcomeUnknown, fixture.submit(2, .{ .key = 0xffe1 }));
    fixture.context.release(fixture.context.automation.?);
    while (fixture.context.drainRevocation()) |_| {}
    _ = try fixture.submit(2, .{ .key = 0xffe1 });
    _ = try fixture.service.pump(output.wire(1));
    try T.expectEqual(ai.Status.sent, (try fixture.status(2)).status);
    try T.expectEqual(ai.Status.outcome_unknown, (try fixture.status(1)).status);
}

test "BMC AI input observation expiry during blocked dispatch cancels without writing" {
    var fixture: Fixture = .{};
    try fixture.init();
    var authority = try fixture.authority();
    const now: u64 = @intCast(@divTrunc(@import("platform/realtime.zig").monotonicNs(), std.time.ns_per_ms));
    authority.expires_at_ms = now + 50;
    _ = try fixture.service.submitAutomation(fixture.service.binding(), authority, .{ .operation_id = 1, .action = .{ .key = 0xffe1 } });
    var delay: std.c.timespec = .{ .sec = 0, .nsec = 60 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&delay, null);
    var output: Output = .{};
    _ = try fixture.service.pump(output.wire(1));
    try T.expectEqual(ai.Status.cancelled_unsent, (try fixture.status(1)).status);
    try T.expectEqual(@as(usize, 0), output.length);
}

fn startPipeline(pipeline: *video.Pipeline) !void {
    try pipeline.start(.{ .tls_trusted = true, .web_authenticated = true, .oem_authenticated = true });
    var packet: [52]u8 = undefined;
    packet[0] = 0x82;
    packet[1] = 50;
    const hello = packet[2..];
    @memcpy(hello[0..12], "RFB 003.008\n");
    @memcpy(hello[12..26], &[_]u8{ 105, 1, 0, 99, 104, 0, 0, 0, 1, 1, 0, 0, 0, 0 });
    std.mem.writeInt(u16, hello[26..28], 1, .big);
    std.mem.writeInt(u16, hello[28..30], 1, .big);
    (video.rfb.raw.PixelFormat{}).write(hello[30..46]);
    std.mem.writeInt(u32, hello[46..50], 0, .big);
    _ = try pipeline.feed(&packet, 1);
    // A negotiated size is not yet a coordinate system. Input fixtures must
    // establish the same complete base required by the production pipeline.
    _ = try pipeline.feed(&.{ 0x82, 20, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0 }, 1);
}
fn drainPipeline(pipeline: *video.Pipeline, output: *Output) !void {
    for (0..128) |_| {
        try pipeline.pump(.{ .context = output, .write = Output.write, .abort = Output.abort });
        const snapshot = try pipeline.remote_input.snapshot(pipeline.remote_input.binding());
        if (pipeline.count == 0 and pipeline.input_output == null and pipeline.remote_input.tx == null and snapshot.queued == 0 and snapshot.automation_queued == 0) return;
    }
    return error.PipelineDidNotDrain;
}

test "BMC AI input partial WebSocket prefix aborts on lease revocation and preserves shared frame lease" {
    var fixture: Fixture = .{};
    try fixture.init();
    var budget = budgets.Budget.init(128 * 1024 * 1024);
    defer budget.deinit() catch unreachable;
    var framebuffer = frames.Service.init(T.allocator, owner, &budget);
    defer framebuffer.deinit() catch unreachable;
    var pipeline = try video.Pipeline.init(T.allocator, owner, 1, &framebuffer, &fixture.service, &budget);
    defer pipeline.deinit();
    try startPipeline(&pipeline);
    var output: Output = .{};
    try drainPipeline(&pipeline, &output);
    _ = try framebuffer.publishComplete(1, 1, &.{ 11, 22, 33, 255 }, 1);
    var lease = switch (framebuffer.acquireLatest(framebuffer.binding(), 0)) {
        .frame => |value| value,
        else => return error.FrameUnavailable,
    };
    defer lease.release();
    const start = output.length;
    _ = try fixture.submit(1, .{ .key = 0xffe1 });
    output.chunk = 3;
    output.fixture = &fixture;
    output.trigger_call = output.calls + 1;
    try pipeline.pump(.{ .context = &output, .write = Output.write, .abort = Output.abort });
    try T.expectEqual(start + 3, output.length);
    try T.expectError(error.InputWriteInterrupted, pipeline.pump(.{ .context = &output, .write = Output.write, .abort = Output.abort }));
    const receipt = try fixture.status(1);
    try T.expectEqual(ai.Status.outcome_unknown, receipt.status);
    try T.expectEqual(@as(u16, 0), receipt.sent_events);
    try T.expect(receipt.possibly_written);
    try T.expectEqual(@as(usize, 1), output.aborts);
    try T.expectEqual(start + 3, output.length);
    try T.expectEqualSlices(u8, &.{ 11, 22, 33, 255 }, lease.snapshot.pixels);
}

test "BMC AI input short WebSocket writes acknowledge only complete frames with paired input" {
    var fixture: Fixture = .{};
    try fixture.init();
    var budget = budgets.Budget.init(128 * 1024 * 1024);
    defer budget.deinit() catch unreachable;
    var framebuffer = frames.Service.init(T.allocator, owner, &budget);
    defer framebuffer.deinit() catch unreachable;
    var pipeline = try video.Pipeline.init(T.allocator, owner, 1, &framebuffer, &fixture.service, &budget);
    defer pipeline.deinit();
    try startPipeline(&pipeline);
    var output: Output = .{};
    try drainPipeline(&pipeline, &output);
    const start = output.length;
    _ = try fixture.submit(1, .{ .key = 0xffe1 });
    output.chunk = 3;
    try pipeline.pump(.{ .context = &output, .write = Output.write, .abort = Output.abort });
    try T.expectEqual(ai.Status.accepted, (try fixture.status(1)).status);
    try T.expectEqual(@as(u16, 0), (try fixture.status(1)).sent_events);
    try drainPipeline(&pipeline, &output);
    try T.expectEqual(ai.Status.sent, (try fixture.status(1)).status);
    const bytes = output.bytes()[start..];
    try T.expectEqual(@as(usize, 28), bytes.len);
    for (0..2) |frame_index| {
        const frame = bytes[frame_index * 14 ..][0..14];
        try T.expectEqualSlices(u8, &.{ 0x82, 0x88 }, frame[0..2]);
        var packet: [8]u8 = undefined;
        for (&packet, 0..) |*byte, index| byte.* = frame[6 + index] ^ frame[2 + index % 4];
        try expectKey(&packet, 0xffe1, frame_index == 0);
    }
    try T.expectEqual(@as(usize, 0), output.aborts);
    try T.expectEqual(@as(usize, 0), fixture.service.pressed_count);
}

test "BMC AI input DesktopSize cancels old observed coordinates before a new complete frame is published" {
    var fixture: Fixture = .{};
    try fixture.init();
    var budget = budgets.Budget.init(128 * 1024 * 1024);
    defer budget.deinit() catch unreachable;
    var framebuffer = frames.Service.init(T.allocator, owner, &budget);
    defer framebuffer.deinit() catch unreachable;
    var pipeline = try video.Pipeline.init(T.allocator, owner, 1, &framebuffer, &fixture.service, &budget);
    defer pipeline.deinit();
    try startPipeline(&pipeline);
    var output: Output = .{};
    try drainPipeline(&pipeline, &output);
    _ = try framebuffer.publishComplete(1, 1, &.{ 11, 22, 33, 255 }, 1);
    const before = try fixture.service.snapshot(fixture.service.binding());
    _ = try fixture.submit(1, .{ .pointer_move = .{ .x = 0, .y = 0 } });
    var packet: [18]u8 = .{ 0x82, 16, 0, 0, 0, 1, 0, 0, 0, 0, 0, 2, 0, 2, 0, 0, 0, 0 };
    std.mem.writeInt(i32, packet[14..18], -223, .big);
    _ = try pipeline.feed(&packet, 2);
    const after = try fixture.service.snapshot(fixture.service.binding());
    try T.expect(after.input_epoch > before.input_epoch);
    try T.expectEqual(ai.Status.cancelled_unsent, (try fixture.status(1)).status);
    var lease = switch (framebuffer.acquireLatest(framebuffer.binding(), 0)) {
        .frame => |value| value,
        else => return error.FrameUnavailable,
    };
    defer lease.release();
    try T.expectEqual(@as(u32, 1), lease.snapshot.width);
    try T.expectEqual(@as(u32, 1), lease.snapshot.height);
    try T.expectEqualSlices(u8, &.{ 11, 22, 33, 255 }, lease.snapshot.pixels);
}

test "BMC AI input main thread lease revocation races a worker prefix without a lock cycle or replay" {
    var fixture: Fixture = .{};
    try fixture.init();
    _ = try fixture.submit(1, .{ .key = 0xffe1 });
    const Race = struct {
        entered: std.atomic.Value(bool) = .init(false),
        revoked: std.atomic.Value(bool) = .init(false),
        aborted: bool = false,
        sent: usize = 0,
        fn write(raw: *anyopaque, _: []const u8) !usize {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.sent += 2;
            self.entered.store(true, .release);
            while (!self.revoked.load(.acquire)) std.atomic.spinLoopHint();
            return 2;
        }
        fn abort(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.aborted = true;
        }
        fn run(service: *remote.Service, race: *@This()) void {
            T.expectError(error.InputWriteInterrupted, service.pump(.{ .context = race, .generation = 1, .write = write, .abort = abort })) catch @panic("automation replayed after revocation");
        }
    };
    var race: Race = .{};
    const thread = try std.Thread.spawn(.{}, Race.run, .{ &fixture.service, &race });
    while (!race.entered.load(.acquire)) std.atomic.spinLoopHint();
    fixture.context.release(fixture.context.automation.?);
    race.revoked.store(true, .release);
    thread.join();
    try T.expect(race.aborted);
    try T.expectEqual(@as(usize, 2), race.sent);
    try T.expectEqual(ai.Status.outcome_unknown, (try fixture.status(1)).status);
}
