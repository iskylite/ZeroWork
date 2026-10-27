const std = @import("std");
const terminal = @import("host/terminal_service.zig");
const Provider = @import("plugins/ssh/terminal_service.zig").Provider;
const Native = @import("ui/session_runtime.zig").SessionRuntime;
const Worker = @import("vt/ssh_worker.zig").SshWorker;
const Thread = @import("vt/ssh_worker_thread.zig").Thread;
const a = std.testing.allocator;
const owner: @import("host/identity.zig").SessionHandle = .{ .session_id = @fromBackingInt(17) };
const operation: @import("host/operation.zig").OperationKey = .{ .owner = .{ .session = owner }, .operation_id = 1, .attempt_id = 1 };
const Fixture = struct {
    worker: Worker = undefined,
    thread: Thread = undefined,
    native: Native = undefined,
    provider: Provider = undefined,
    fn init(self: *@This()) !void {
        self.worker.allocator = a;
        self.worker.vt = try @import("vt/ghostty_adapter.zig").Adapter.init(a, 4, 80);
        self.worker.input = try @import("vt/input_queue.zig").InputQueue.init(a, 256);
        self.worker.replay = try @import("vt/reconnect_replay.zig").Replay.init(a, 8192);
        self.worker.replay.configure(operation, true, true);
        self.worker.reconnect = try @import("vt/reconnect.zig").Machine.init(1, &.{1});
        self.worker.presentation_attached = .init(true);
        self.worker.timeline = try @import("vt/timeline.zig").Timeline.init(a, 64, 65536);
        self.thread = .{ .worker = &self.worker, .thread = undefined, .reconnect_control = .init(operation) };
        self.native.allocator = a;
        self.native.torn_down = false;
        self.native.worker = &self.worker;
        self.native.thread = &self.thread;
        self.provider = Provider.init(&self.native, owner);
    }
    fn deinit(self: *@This()) void {
        self.provider.deinit();
        self.worker.timeline.deinit();
        self.worker.replay.deinit();
        self.worker.input.deinit(a);
        self.worker.vt.destroy();
    }
};
test "SSH terminal service uses native graphemes and rejects stale modes owners and geometry" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const service = f.provider.service();
    _ = try f.worker.vt.feed("\x1b[1;3;9;53m界e\u{301}👩‍💻\x1b[0m\x1b[?1h\x1b[?1000h\x1b[?1006h");
    var snapshot = try service.snapshot(a);
    defer snapshot.deinit(a);
    try std.testing.expectEqualStrings("界", snapshot.projection.grapheme(snapshot.projection.cells[0]));
    try std.testing.expect(snapshot.projection.cells[0].attributes & (1 << 8) != 0);
    try std.testing.expect(snapshot.projection.cells[0].attributes & (1 << 5) != 0);
    const mode = snapshot.projection.mode_revision;
    try std.testing.expectError(error.StaleMode, service.writeKey(.{ .input_sequence = 1, .mode_revision = mode - 1, .event = .{ .key = .arrow_up } }));
    _ = try service.writeKey(.{ .input_sequence = 1, .mode_revision = mode, .event = .{ .key = .arrow_up } });
    var bytes: [256]u8 = undefined;
    try std.testing.expectEqualStrings("\x1bOA", f.worker.input.drain(&bytes));
    try std.testing.expectError(error.StaleInput, service.writeKey(.{ .input_sequence = 1, .mode_revision = mode, .event = .{ .key = .enter } }));
    var stale = service;
    stale.binding.binding_generation += 1;
    try std.testing.expectError(error.StaleOwner, stale.snapshot(a));
    try std.testing.expectError(error.StaleGeometry, service.writeMouse(.{ .input_sequence = 2, .mode_revision = mode, .geometry_revision = 2, .event = .{ .action = .press, .button = .right, .x = 10, .y = 10, .screen_width = 640, .screen_height = 80, .cell_width = 8, .cell_height = 20 } }));
    _ = try service.writeMouse(.{ .input_sequence = 2, .mode_revision = mode, .geometry_revision = 1, .event = .{ .action = .press, .button = .right, .x = 10, .y = 10, .screen_width = 640, .screen_height = 80, .cell_width = 8, .cell_height = 20 } });
    try std.testing.expectEqualStrings("\x1b[<2;2;1M", f.worker.input.drain(&bytes));
}
test "SSH terminal service streams bounded bracketed paste without interleaving or reconnect replay" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const service = f.provider.service();
    _ = try f.worker.vt.feed("\x1b[?2004h");
    const input = try a.alloc(u8, 130000);
    defer a.free(input);
    @memset(input, 'x');
    var paste = try service.preparePaste(a, input);
    defer paste.deinit(a);
    _ = try service.commitPaste(paste, 1, false);
    try std.testing.expectError(error.InputFull, service.write(.{ .input_sequence = 2, .mode_revision = paste.mode_revision, .bytes = "interleave" }));
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(a);
    var bytes: [256]u8 = undefined;
    while (f.provider.pending_paste != null or f.worker.input.pending() != 0) {
        try std.testing.expect(try service.takeWriteReceipt() == null);
        try result.appendSlice(a, f.worker.input.drain(&bytes));
    }
    try std.testing.expectEqualStrings("\x1b[200~", result.items[0..6]);
    try std.testing.expectEqualSlices(u8, input, result.items[6..][0..input.len]);
    try std.testing.expectEqualStrings("\x1b[201~", result.items[6 + input.len ..]);
    var again = try service.preparePaste(a, "two\nlines");
    defer again.deinit(a);
    try std.testing.expectError(error.ConfirmationRequired, service.commitPaste(again, 2, false));
    _ = try service.commitPaste(again, 2, true);
    _ = try f.worker.vt.feed("\x1b[?2004l");
    const receipt = (try service.takeWriteReceipt()).?;
    try std.testing.expectEqual(terminal.WriteFailure.stale_mode, receipt.failure.?);
    try std.testing.expectEqual(@as(usize, 0), f.worker.input.pending());
}

test "SSH terminal service retains only ordinary reconnect input and keeps paste out of replay" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const service = f.provider.service();
    const mode = f.worker.vt.snapshot().mode_revision;
    f.worker.replay.disconnected(&f.worker.input);
    f.worker.reconnect.suspect(null);
    _ = try service.write(.{ .input_sequence = 1, .mode_revision = mode, .bytes = "ordinary" });
    try std.testing.expectEqual(@as(usize, 0), f.worker.input.pending());
    try std.testing.expect((try service.status()).writable);
    try std.testing.expectError(error.SessionNotWritable, service.preparePaste(a, "paste"));
    f.worker.replay.ended(&f.worker.input);
    try std.testing.expect(!(try service.status()).writable);
    try std.testing.expectError(error.SessionNotWritable, service.write(.{ .input_sequence = 2, .mode_revision = mode, .bytes = "late" }));
}

test "SSH terminal service uses the selected built-in function key policy" {
    for (@import("vt/terminal_type.zig").builtin) |entry| {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        f.worker.vt.configureTerminalType(entry.name);
        const service = f.provider.service();
        const mode = f.worker.vt.snapshot().mode_revision;
        _ = try service.writeKey(.{ .input_sequence = 1, .mode_revision = mode, .event = .{ .key = .f5 } });
        var bytes: [256]u8 = undefined;
        try std.testing.expectEqualStrings(if (entry.kind == .vt100) "\x1bOt" else "\x1b[15~", f.worker.input.drain(&bytes));
    }
}
