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
        self.worker.text = try @import("vt/text_slot.zig").TextSlot.init(a, 4096);
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
        self.worker.text.deinit(a);
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

test "SSH terminal structured snapshot stays coherent while parser is busy" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.worker.text.enableStructured();
    _ = try f.worker.vt.feed("published");
    _ = try f.worker.text.publishOwnedProjection(try f.worker.vt.copyProjection(std.heap.page_allocator), 1);
    _ = try f.worker.vt.feed("unpublished");
    try std.testing.expect(f.worker.vt.mutex.tryLock());
    defer f.worker.vt.mutex.unlock();
    const service = f.provider.service();
    try std.testing.expectError(error.WorkerBusy, service.status());
    var value = try service.snapshot(a);
    defer value.deinit(a);
    try std.testing.expectEqual(@as(u64, 1), value.output_sequence);
    try std.testing.expectEqualStrings("p", value.projection.grapheme(value.projection.cells[0]));
    try std.testing.expectEqual(@as(usize, 0), value.projection.grapheme(value.projection.cells[9]).len);
}

test "SSH terminal structured resize waits for acknowledged geometry and matching cells" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const service = f.provider.service();
    f.worker.resize_dims = .init(0);
    f.worker.resize_seq = .init(0);
    f.worker.text.enableStructured();
    _ = try f.worker.text.publishOwnedProjection(try f.worker.vt.copyProjection(std.heap.page_allocator), 1);
    try service.resize(.{ .revision = 2, .cols = 100, .rows = 5 });
    try std.testing.expectError(error.WorkerBusy, service.snapshot(a));
    try f.worker.vt.resize(100, 5);
    const status = try service.status();
    try std.testing.expectEqual(@as(u64, 2), status.geometry.revision);
    try std.testing.expectError(error.WorkerBusy, service.snapshot(a));
    // Returning to the old size must not let the old frame acknowledge the
    // successor request before the live VT has actually applied it.
    try service.resize(.{ .revision = 3, .cols = 80, .rows = 4 });
    try std.testing.expectError(error.WorkerBusy, service.snapshot(a));
    try std.testing.expectEqual(@as(u64, 3), f.provider.pending_geometry.?.revision);
    try f.worker.vt.resize(80, 4);
    _ = try service.status();
    _ = try f.worker.text.publishOwnedProjection(try f.worker.vt.copyProjection(std.heap.page_allocator), 1);
    var value = try service.snapshot(a);
    defer value.deinit(a);
    try std.testing.expectEqual(@as(u64, 3), value.geometry_revision);
    try std.testing.expectEqual(@as(u16, 80), value.projection.cols);
    try std.testing.expectEqual(@as(u16, 4), value.projection.rows);
}

test "SSH terminal ended and disconnected presentation publishes theme without transport IO" {
    for ([_]bool{ true, false }) |shell_ended| {
        var f: Fixture = .{};
        try f.init();
        defer f.deinit();
        const service = f.provider.service();
        f.worker.io.feed = .{ .engine = @import("vt/engine.zig").VtEngine.from(@import("vt/ghostty_adapter.zig").Adapter, &f.worker.vt), .text_slot = &f.worker.text };
        f.worker.text.enableStructured();
        // Fill the slot to cover a theme request deferred behind the last
        // output frames. Only the paused worker is allowed to publish.
        for (0..3) |_| _ = try f.worker.text.publishOwnedProjection(try f.worker.vt.copyProjection(std.heap.page_allocator), 1);
        if (shell_ended) f.thread.reconnect_control.ended(operation, .released, 0) else f.thread.reconnect_control.lost(operation, .released, error.ConnectionClosed);
        try service.setTheme(.{ .revision = 2, .foreground = 0xeeeeeeff, .background = 0x112233ff, .cursor = 0xffffffff, .selection = 0x666666ff, .ansi = @splat(0x777777ff) });
        f.worker.publishPendingPresentation();
        try std.testing.expect(f.worker.io.feed.republish_pending);
        _ = f.worker.text.acknowledge(0);
        f.worker.publishPendingPresentation();
        try std.testing.expect(!f.worker.io.feed.republish_pending);
        var value = try service.snapshot(a);
        defer value.deinit(a);
        try std.testing.expectEqual(@as(u64, 2), value.applied_theme_revision);
        try std.testing.expectEqual(@as(u24, 0x112233), value.projection.colors.background);
    }
}

test "SSH terminal loss settles an unapplied resize before publishing the final theme" {
    for ([_]bool{ true, false }) |shell_ended| {
        var f: Fixture = .{};
        try f.init();
        defer f.deinit();
        const service = f.provider.service();
        f.worker.resize_dims = .init(0);
        f.worker.resize_seq = .init(0);
        f.worker.io.feed = .{ .engine = @import("vt/engine.zig").VtEngine.from(@import("vt/ghostty_adapter.zig").Adapter, &f.worker.vt), .text_slot = &f.worker.text };
        f.worker.text.enableStructured();
        try service.resize(.{ .revision = 2, .cols = 100, .rows = 5 });
        // The transport ends before the worker can apply the requested grid.
        f.worker.presentation_attached.store(false, .release);
        if (shell_ended) f.thread.reconnect_control.ended(operation, .released, 0) else f.thread.reconnect_control.lost(operation, .released, error.ConnectionClosed);
        const status = try service.status();
        try service.setTheme(.{ .revision = 2, .foreground = 0xeeeeeeff, .background = 0x112233ff, .cursor = 0xffffffff, .selection = 0x666666ff, .ansi = @splat(0x777777ff) });
        f.worker.publishPendingPresentation();
        var value = try service.snapshot(a);
        defer value.deinit(a);
        try std.testing.expect(f.provider.pending_geometry == null);
        try std.testing.expectEqual(status.geometry.revision, value.geometry_revision);
        try std.testing.expectEqual(@as(u16, 80), value.projection.cols);
        try std.testing.expectEqual(@as(u16, 4), value.projection.rows);
        try std.testing.expectEqual(@as(u64, 2), value.applied_theme_revision);
    }
}

test "nonblocking terminal reads yield on worker contention and recover unchanged ownership" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    var runtime = @import("plugins/ssh/runtime_binding.zig").borrow(&f.native);
    const service = f.provider.service();
    _ = try f.worker.vt.feed("\x1b]133;A\x07");
    const version = f.worker.vt.snapshot().version;
    const sequence = f.worker.vt.semanticSequence();
    try std.testing.expect(sequence > 0);
    try std.testing.expect(f.worker.vt.mutex.tryLock());
    {
        defer f.worker.vt.mutex.unlock();
        try std.testing.expectEqual(version, runtime.sourceVersion());
        try std.testing.expectEqual(sequence, runtime.semanticSequence());
        try std.testing.expectError(error.WorkerBusy, runtime.copyCwd(a));
        try std.testing.expectError(error.WorkerBusy, runtime.copyProjection(a));
        try std.testing.expectError(error.WorkerBusy, service.snapshot(a));
        try std.testing.expectError(error.WorkerBusy, f.provider.source.service().snapshot(a));
    }
    _ = try f.worker.vt.feed("after contention");
    var snapshot = try runtime.copyProjection(a);
    defer snapshot.deinit(a);
    try std.testing.expectEqualStrings("a", snapshot.grapheme(snapshot.cells[0]));
    try std.testing.expect(runtime.sourceVersion() > version);
    try std.testing.expectEqual(snapshot.version, runtime.sourceVersion());
    try std.testing.expect((try runtime.copyCwd(a)) == null);
    var recovered = try service.snapshot(a);
    defer recovered.deinit(a);
    try std.testing.expect(recovered.owner.eql(owner));
}

test "SSH trusted execution fails before input without BootstrapV1 and preserves normal terminal" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const service = f.provider.service();
    const snapshot = try service.executionSnapshot();
    try std.testing.expect(!snapshot.interactive_execution and snapshot.state == .unavailable);
    try std.testing.expectEqualStrings("IntegrationUnavailable", snapshot.failure.?);
    try std.testing.expectError(error.IntegrationUnavailable, service.executionRequest(.{ .execution_id = .generate(), .task_id = .generate(), .expected_input_epoch = 0, .ownership_revision = 1, .command = "touch never", .command_hash = terminal.execution.digest("touch never") }));
    try std.testing.expectEqual(@as(usize, 0), f.worker.input.pending());
    try std.testing.expectEqual(@as(u64, 0), f.provider.input_sequence);
    var stale = service;
    stale.binding.binding_generation += 1;
    try std.testing.expectError(error.StaleOwner, stale.executionSnapshot());
}
