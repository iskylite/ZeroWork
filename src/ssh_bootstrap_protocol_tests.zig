const std = @import("std");
const protocol = @import("local/execution.zig");
const wire = @import("host/trusted_edit.zig");
const execution = protocol.execution;
const identity = @import("host/identity.zig");
const a = std.testing.allocator;
const Fake = struct {
    incoming: []const u8 = &.{},
    sent: std.ArrayList(u8) = .empty,
    closed: bool = false,
    sequence: u64 = 0,
    fn read(raw: *anyopaque, bytes: []u8, count: *usize) c_int {
        const self: *@This() = @ptrCast(@alignCast(raw));
        count.* = @min(bytes.len, self.incoming.len);
        @memcpy(bytes[0..count.*], self.incoming[0..count.*]);
        self.incoming = self.incoming[count.*..];
        return if (count.* == 0) 0 else 1;
    }
    fn write(raw: *anyopaque, bytes: []const u8, count: *usize) c_int {
        const self: *@This() = @ptrCast(@alignCast(raw));
        count.* = @min(bytes.len, 7);
        self.sent.appendSlice(a, bytes[0..count.*]) catch return -1;
        return 0;
    }
    fn close(raw: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.closed = true;
    }
    fn emit(self: *@This(), bridge: *protocol.Bridge, fields: []const []const u8) !void {
        self.sequence += 1;
        var text: [32]u8 = undefined;
        var all: [16][]const u8 = undefined;
        const sequence = try std.fmt.bufPrint(&text, "{d}", .{self.sequence});
        @memcpy(all[0..5], &[_][]const u8{ "1", "17", "1", "private-nonce", sequence });
        @memcpy(all[5..][0..fields.len], fields);
        const bytes = try wire.encode(a, all[0 .. fields.len + 5]);
        defer a.free(bytes);
        // Every incoming byte can be split at a different SSH read boundary.
        for (bytes) |byte| {
            const one = [_]u8{byte};
            self.incoming = &one;
            bridge.poll(0, 2);
        }
    }
    fn makeBridge(self: *@This()) protocol.Bridge {
        return protocol.Bridge.initTransport(a, .{ .session_id = @fromBackingInt(17) }, .{ .context = self, .nonce = "private-nonce", .read = read, .write = write, .close = close });
    }
};
test "SSH BootstrapV1 shared protocol waits for real private idle and keeps old handoff observer through partial submit" {
    var fake: Fake = .{};
    defer fake.sent.deinit(a);
    var bridge = fake.makeBridge();
    defer bridge.deinit();
    try fake.emit(&bridge, &.{ "hello", "5.9", "ssh_cloexec_boundary_interval_v1" });
    try std.testing.expect(bridge.hello and !bridge.snapshot.interactive_execution);
    const request: execution.Request = .{ .execution_id = .generate(), .task_id = .generate(), .expected_input_epoch = 0, .ownership_revision = 1, .command = "read value", .command_hash = execution.digest("read value") };
    try std.testing.expectError(error.IntegrationUnavailable, bridge.begin(request, 2));
    try std.testing.expectEqual(@as(usize, 0), fake.sent.items.len);
    try fake.emit(&bridge, &.{ "idle", "empty_line", "no_pending", "shell_foreground" });
    try bridge.begin(request, 2);
    const grant = bridge.snapshot.grant.?;
    var fence_buffer: [32]u8 = undefined;
    const fence = try std.fmt.bufPrint(&fence_buffer, "{d}", .{grant.fence});
    try std.testing.expectError(error.TerminalControlled, bridge.ordinaryInput());
    try bridge.prepared(@splat('1'), 1, 1, 2);
    const id = std.fmt.bytesToHex(request.execution_id.bytes, .lower);
    try fake.emit(&bridge, &.{ "boundary", &id, fence, "start", &bridge.start_token });
    try fake.emit(&bridge, &.{ "ready", &id, fence, "0" });
    bridge.start_seen = .{ .raw_offset = 100, .sequence = 1 };
    try bridge.startCommitted(2, 2);
    const hash = std.fmt.bytesToHex(request.command_hash, .lower);
    try fake.emit(&bridge, &.{ "accepted", &id, fence, "0", &hash, request.command });
    bridge.poll(0, 2);
    try std.testing.expect(bridge.snapshot.submit_sent and bridge.snapshot.submit_native_bytes > 0);
    try bridge.revoke(grant, true, 2);
    try std.testing.expect(bridge.snapshot.input_handed_off and bridge.observes(grant));
    try std.testing.expectError(error.StaleFence, bridge.renew(grant, 3));
    try fake.emit(&bridge, &.{ "submitted", &id, fence, "0" });
    while (bridge.tx.items.len != bridge.tx_offset) bridge.poll(0, 2);
    bridge.wakeCompleted();
    try std.testing.expect(bridge.snapshot.input_ready and bridge.snapshot.local_released and bridge.snapshot.grant == null);
    try bridge.ordinaryInput();
    try fake.emit(&bridge, &.{ "started", &id, fence });
    bridge.capture("human-input-result");
    try fake.emit(&bridge, &.{ "boundary", &id, fence, "end", &bridge.end_token });
    bridge.end_seen = .{ .raw_offset = 118, .sequence = 2 };
    try fake.emit(&bridge, &.{ "finished", &id, fence, "7", "4" });
    try std.testing.expect(bridge.endPaired());
    bridge.endCommitted(3);
    bridge.intervalRecorded(4);
    try std.testing.expectEqual(execution.State.interval_recorded, bridge.snapshot.state);
    try std.testing.expectEqual(@as(?u8, 7), bridge.snapshot.process.?.exit_code);
    try std.testing.expect(bridge.snapshot.process.?.foreground_finished and bridge.snapshot.process.?.background_jobs_unknown);
    try std.testing.expect(bridge.snapshot.interval_saved and bridge.snapshot.input_handed_off and !bridge.snapshot.remote_effect_unknown);
    try std.testing.expectEqualStrings("human-input-result", bridge.captured.items);
}
test "SSH BootstrapV1 terminal text cannot establish readiness or authorize a wrong private nonce" {
    var fake: Fake = .{};
    defer fake.sent.deinit(a);
    var bridge = fake.makeBridge();
    defer bridge.deinit();
    const Sink = struct {
        fn output(_: *anyopaque, _: []const u8, _: u64) void {}
    };
    bridge.output("\x1b]133;A\x07done ready hello\n", .{ .context = &fake, .output = Sink.output });
    try std.testing.expect(!bridge.hello and !bridge.snapshot.interactive_execution);
    const forged = try wire.encode(a, &.{ "1", "17", "1", "wrong-nonce", "1", "hello", "5.9", "ssh_cloexec_boundary_interval_v1" });
    defer a.free(forged);
    fake.incoming = forged;
    bridge.poll(0, 2);
    try std.testing.expect(fake.closed and bridge.disabled and !bridge.snapshot.interactive_execution);
    try std.testing.expectEqual(@as(usize, 0), fake.sent.items.len);
}
