const std = @import("std");
const Adapter = @import("vt/ghostty_adapter.zig").Adapter;
const model = @import("vt/snapshot.zig");
const allocator = std.testing.allocator;

fn wall() i64 {
    return 1_800_000_000_123;
}

test "command metadata keeps repeated native commands and actual D exit status" {
    var adapter = try Adapter.init(allocator, 6, 40);
    defer adapter.destroy();
    adapter.wall_clock_ms = wall;
    _ = try adapter.feed("\x1b]133;A\x07$ \x1b]133;B\x07echo one  \r\n\x1b]133;C\x07");
    var running = try adapter.copyProjection(allocator);
    defer running.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), running.commands.len);
    try std.testing.expectEqualStrings("echo one  ", running.commands[0].command.?);
    try std.testing.expectEqual(model.CommandState.running, running.commands[0].state);
    try std.testing.expectEqual(wall(), running.commands[0].start_ms);
    try std.testing.expectEqual(@as(?i64, null), running.commands[0].end_ms);
    try std.testing.expectEqual(@as(?u32, 0), running.commands[0].screen_row);
    try std.testing.expectEqual(@as(?u16, 2), running.commands[0].col);
    try std.testing.expectEqual(@as(?u32, 0), running.commands[0].input_end_row);
    try std.testing.expectEqual(@as(?u16, 12), running.commands[0].input_end_col);
    try std.testing.expectEqual(@as(?u32, 1), running.commands[0].output_start_row);
    _ = try adapter.feed("one\r\n\x1b]133;D;0\x07\x1b]133;A\x07$ \x1b]133;B\x07echo one  \r\n\x1b]133;C\x07one\r\n\x1b]133;D;1\x07");
    var completed = try adapter.copyProjection(allocator);
    defer completed.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), completed.commands.len);
    const first = completed.commands[0];
    const second = completed.commands[1];
    try std.testing.expect(first.id != second.id);
    try std.testing.expectEqualStrings(first.command.?, second.command.?);
    try std.testing.expectEqual(model.CommandState.succeeded, first.state);
    try std.testing.expectEqual(@as(?i32, 0), first.exit_code);
    try std.testing.expectEqual(model.CommandState.failed, second.state);
    try std.testing.expectEqual(@as(?i32, 1), second.exit_code);
    try std.testing.expectEqual(@as(?i64, wall()), second.end_ms);
    try std.testing.expect(first.elapsed_ms != null and second.elapsed_ms != null);
    var clone = try completed.clone(allocator);
    defer clone.deinit(allocator);
    try std.testing.expect(clone.commands.ptr != completed.commands.ptr);
    try std.testing.expect(clone.commands[0].command.?.ptr != first.command.?.ptr);
    try std.testing.expectEqualStrings(first.command.?, clone.commands[0].command.?);
}

test "command metadata reads B to C across feeds and preserves shell-provided command" {
    var adapter = try Adapter.init(allocator, 5, 50);
    defer adapter.destroy();
    _ = try adapter.feed("\x1b]133;A\x07$ \x1b]133;");
    _ = try adapter.feed("B\x07  echo split");
    _ = try adapter.feed("  \r\n\x1b]133;C");
    _ = try adapter.feed("\x07\x1b]133;D\x07");
    _ = try adapter.feed("\x1b]133;A\x07$ \x1b]133;B\x07short\r\n\x1b]133;C;cmdline_url=echo%20truth%20%20\x07");
    var result = try adapter.copyProjection(allocator);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), result.commands.len);
    try std.testing.expectEqualStrings("  echo split  ", result.commands[0].command.?);
    try std.testing.expectEqual(model.CommandState.unknown, result.commands[0].state);
    try std.testing.expectEqual(@as(?i32, null), result.commands[0].exit_code);
    try std.testing.expectEqualStrings("echo truth  ", result.commands[1].command.?);
}

test "command metadata tracks wrap and resize without repeating a command" {
    var adapter = try Adapter.init(allocator, 4, 10);
    defer adapter.destroy();
    _ = try adapter.feed("\x1b]133;A\x07$ \x1b]133;B\x07abcdefghijklmnop\r\n\x1b]133;C\x07\x1b]133;D;0\x07");
    var before = try adapter.copyProjection(allocator);
    defer before.deinit(allocator);
    try std.testing.expectEqualStrings("abcdefghijklmnop", before.commands[0].command.?);
    try std.testing.expectEqual(@as(?u32, 1), before.commands[0].input_end_row);
    try std.testing.expectEqual(@as(?u16, 8), before.commands[0].input_end_col);
    try adapter.resize(6, 4);
    var after = try adapter.copyProjection(allocator);
    defer after.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), after.commands.len);
    try std.testing.expectEqual(before.commands[0].id, after.commands[0].id);
    try std.testing.expectEqualStrings("abcdefghijklmnop", after.commands[0].command.?);
    try std.testing.expectEqual(@as(?u32, 0), after.commands[0].screen_row);
    try std.testing.expectEqual(@as(?u16, 2), after.commands[0].col);
    try std.testing.expectEqual(@as(?u32, 2), after.commands[0].input_end_row);
    try std.testing.expectEqual(@as(?u16, 6), after.commands[0].input_end_col);
}

test "command metadata keeps primary refs while ignoring alternate semantic markers" {
    var adapter = try Adapter.init(allocator, 4, 30);
    defer adapter.destroy();
    _ = try adapter.feed("\x1b]133;A\x07$ \x1b]133;B\x07top\r\n\x1b]133;C\x07\x1b[?1049h\x1b]133;B\x07fake\x1b]133;C\x07\x1b]133;D;1\x07");
    var alternate = try adapter.copyProjection(allocator);
    defer alternate.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), alternate.commands.len);
    try std.testing.expectEqual(model.CommandState.running, alternate.commands[0].state);
    try std.testing.expectEqual(@as(?u32, null), alternate.commands[0].screen_row);
    _ = try adapter.feed("\x1b[?1049l\x1b]133;D;0\x07");
    var primary = try adapter.copyProjection(allocator);
    defer primary.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), primary.commands.len);
    try std.testing.expectEqualStrings("top", primary.commands[0].command.?);
    try std.testing.expectEqual(@as(?u32, 0), primary.commands[0].screen_row);
    try std.testing.expectEqual(model.CommandState.succeeded, primary.commands[0].state);
}

test "command metadata never fabricates command or completion from prompt and partial events" {
    var adapter = try Adapter.init(allocator, 4, 30);
    defer adapter.destroy();
    _ = try adapter.feed("\x1b]133;A\x07$ \x1b]133;B\x07draft\r\n\x1b]133;D;0\x07");
    var no_c = try adapter.copyProjection(allocator);
    defer no_c.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), no_c.commands.len);
    // A missing B does not reuse the previous prompt's retained input.
    _ = try adapter.feed("\x1b]133;C\x07\x1b]133;A\x07");
    var unknown = try adapter.copyProjection(allocator);
    defer unknown.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), unknown.commands.len);
    try std.testing.expectEqual(@as(?[]const u8, null), unknown.commands[0].command);
    try std.testing.expectEqual(model.CommandState.running, unknown.commands[0].state);
    try std.testing.expectEqual(@as(?i64, null), unknown.commands[0].end_ms);
    _ = try adapter.feed("\x1bc\x1b]133;D;1\x07");
    var reset = try adapter.copyProjection(allocator);
    defer reset.deinit(allocator);
    try std.testing.expectEqual(@as(?u32, null), reset.commands[0].screen_row);
}

test "command metadata survives event truncation and bounds retained commands" {
    var adapter = try Adapter.init(allocator, 3, 30);
    defer adapter.destroy();
    for (0..520) |_| _ = try adapter.feed("\x1b]133;A\x07$ \x1b]133;B\x07same\r\n\x1b]133;C\x07\x1b]133;D;0\x07");
    var result = try adapter.copyProjection(allocator);
    defer result.deinit(allocator);
    try std.testing.expect(result.events_truncated and result.commands_truncated);
    try std.testing.expectEqual(@as(usize, 512), result.commands.len);
    try std.testing.expectEqual(@as(u64, 9), result.commands[0].id);
    try std.testing.expectEqual(@as(u64, 520), result.commands[511].id);
    for (result.commands) |command| {
        try std.testing.expectEqualStrings("same", command.command.?);
        try std.testing.expectEqual(model.CommandState.succeeded, command.state);
    }
}

test "command metadata resolves wide input boundaries and resize before C" {
    var adapter = try Adapter.init(allocator, 5, 10);
    defer adapter.destroy();
    _ = try adapter.feed("\x1b]133;A\x07$ \x1b]133;B\x07abcd界");
    try adapter.resize(6, 5);
    _ = try adapter.feed("\r\n\x1b]133;C\x07");
    var result = try adapter.copyProjection(allocator);
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("abcd界", result.commands[0].command.?);
    try std.testing.expectEqual(@as(?u32, 1), result.commands[0].input_end_row);
    try std.testing.expectEqual(@as(?u16, 2), result.commands[0].input_end_col);
}

test "command metadata returns null locations after scrollback eviction" {
    var adapter = try Adapter.init(allocator, 3, 20);
    defer adapter.destroy();
    try adapter.setScrollbackLimit(3);
    _ = try adapter.feed("\x1b]133;A\x07$ \x1b]133;B\x07echo old\r\n\x1b]133;C\x07\x1b]133;D;0\x07");
    // Ghostty prunes complete native pages, so exceed the minimum page size.
    for (0..8192) |_| _ = try adapter.feed("new\r\n");
    var result = try adapter.copyProjection(allocator);
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("echo old", result.commands[0].command.?);
    try std.testing.expect(result.scrollback.total_rows < 8192);
    try std.testing.expectEqual(@as(?u32, null), result.commands[0].screen_row);
    try std.testing.expectEqual(@as(?u16, null), result.commands[0].col);
    try std.testing.expectEqual(@as(?u32, null), result.commands[0].input_end_row);
    try std.testing.expectEqual(@as(?u32, null), result.commands[0].output_start_row);
}

test "command metadata associates only a matching actual AI submission once" {
    const ExecutionId = @import("host/identity.zig").ExecutionId;
    const ai: ExecutionId = .{ .bytes = @splat(17) };
    const other: ExecutionId = .{ .bytes = @splat(18) };
    var adapter = try Adapter.init(allocator, 5, 30);
    defer adapter.destroy();
    try adapter.registerAiSubmission(ai, "same\n");
    try std.testing.expectError(error.AiSubmissionPending, adapter.registerAiSubmission(other, "same"));
    _ = try adapter.feed("\x1b]133;A\x07$ \x1b]133;B\x07same\r\n\x1b]133;C\x07\x1b]133;D;0\x07");
    _ = try adapter.feed("\x1b]133;A\x07$ \x1b]133;B\x07same\r\n\x1b]133;C\x07\x1b]133;D;0\x07");
    try adapter.registerAiSubmission(ai, "same");
    _ = try adapter.feed("\x1b]133;A\x07$ \x1b]133;B\x07different\r\n\x1b]133;C\x07\x1b]133;D;0\x07");
    _ = try adapter.feed("\x1b]133;A\x07$ \x1b]133;B\x07same\r\n\x1b]133;C\x07\x1b]133;D;0\x07");
    try adapter.registerAiSubmission(other, "same");
    adapter.cancelAiSubmission(other);
    _ = try adapter.feed("\x1b]133;A\x07$ \x1b]133;B\x07same\r\n\x1b]133;C\x07\x1b]133;D;0\x07");
    var result = try adapter.copyProjection(allocator);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 5), result.commands.len);
    try std.testing.expectEqual(@as(?ExecutionId, ai), result.commands[0].ai_execution_id);
    for (result.commands[1..]) |command| try std.testing.expectEqual(@as(?ExecutionId, null), command.ai_execution_id);
}

test "command metadata reports unknown text when a native B anchor is lost" {
    var adapter = try Adapter.init(allocator, 3, 20);
    defer adapter.destroy();
    _ = try adapter.feed("\x1b]133;A\x07$ \x1b]133;B\x07old draft\x1bc\x1b]133;C\x07");
    var result = try adapter.copyProjection(allocator);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.commands.len);
    try std.testing.expectEqual(@as(?[]const u8, null), result.commands[0].command);
    try std.testing.expectEqual(@as(?u32, null), result.commands[0].screen_row);
}

test "command metadata projection clone cleans partial allocations" {
    var adapter = try Adapter.init(allocator, 3, 20);
    defer adapter.destroy();
    _ = try adapter.feed("\x1b]133;A\x07$ \x1b]133;B\x07echo real\r\n\x1b]133;C\x07\x1b]133;D;0\x07");
    var result = try adapter.copyProjection(allocator);
    defer result.deinit(allocator);
    try std.testing.checkAllAllocationFailures(allocator, struct {
        fn run(failing: std.mem.Allocator, value: model.Projection) !void {
            var clone = try value.clone(failing);
            defer clone.deinit(failing);
        }
    }.run, .{result});
    try std.testing.checkAllAllocationFailures(allocator, struct {
        fn run(failing: std.mem.Allocator, source: *Adapter) !void {
            var value = try source.copyProjection(failing);
            defer value.deinit(failing);
        }
    }.run, .{&adapter});
}

test "command metadata excludes native continuation prompts from multiline command text" {
    var adapter = try Adapter.init(allocator, 5, 40);
    defer adapter.destroy();
    _ = try adapter.feed("\x1b]133;A\x07$ \x1b]133;B\x07echo one\r\n\x1b]133;P;k=s\x07> \x1b]133;B\x07two  \r\n\x1b]133;C\x07");
    var result = try adapter.copyProjection(allocator);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.commands.len);
    try std.testing.expectEqualStrings("echo one\ntwo  ", result.commands[0].command.?);
    try std.testing.expectEqual(@as(?u32, 0), result.commands[0].screen_row);
    try std.testing.expectEqual(@as(?u32, 1), result.commands[0].input_end_row);
}

test "command metadata observer sees every C and D before bounded history eviction" {
    const Capture = struct {
        starts: usize = 0,
        ends: usize = 0,
        last_id: u64 = 0,
        valid: bool = true,
        fn changed(context: *anyopaque, value: model.Command) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.valid = self.valid and value.command != null and std.mem.eql(u8, value.command.?, "same");
            if (value.state == .running) {
                self.starts += 1;
                self.valid = self.valid and value.id > self.last_id and value.end_ms == null;
                self.last_id = value.id;
            } else {
                self.ends += 1;
                self.valid = self.valid and value.id == self.last_id and value.exit_code == 0 and value.end_ms != null;
            }
        }
    };
    var received: Capture = .{};
    var adapter = try Adapter.init(allocator, 3, 20);
    defer adapter.destroy();
    adapter.setCommandObserver(.{ .context = &received, .changed = Capture.changed });
    for (0..520) |_| _ = try adapter.feed("\x1b]133;A\x07$ \x1b]133;B\x07same\r\n\x1b]133;C\x07\x1b]133;D;0\x07");
    try std.testing.expect(received.valid);
    try std.testing.expectEqual(@as(usize, 520), received.starts);
    try std.testing.expectEqual(@as(usize, 520), received.ends);
    adapter.setCommandObserver(null);
}

test "command metadata keeps oversized native input explicitly unknown" {
    var adapter = try Adapter.init(allocator, 4, 80);
    defer adapter.destroy();
    const text = try allocator.alloc(u8, 16 * 1024 + 1);
    defer allocator.free(text);
    @memset(text, 'x');
    _ = try adapter.feed("\x1b]133;A\x07$ \x1b]133;B\x07");
    _ = try adapter.feed(text);
    _ = try adapter.feed("\r\n\x1b]133;C\x07\x1b]133;D;0\x07");
    var result = try adapter.copyProjection(allocator);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.commands.len);
    try std.testing.expect(result.commands_truncated);
    try std.testing.expectEqual(@as(?[]const u8, null), result.commands[0].command);
    try std.testing.expectEqual(model.CommandState.succeeded, result.commands[0].state);
}

test "command metadata refreshes running monotonic duration without changing VT revisions" {
    var adapter = try Adapter.init(allocator, 3, 30);
    defer adapter.destroy();
    adapter.wall_clock_ms = wall;
    _ = try adapter.feed("\x1b]133;A\x07$ \x1b]133;B\x07sleep 1\r\n\x1b]133;C\x07");
    var first = try adapter.copyProjection(allocator);
    defer first.deinit(allocator);
    try std.testing.expect(first.commands[0].elapsed_ms != null);
    const delay: std.c.timespec = .{ .sec = 0, .nsec = 25 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&delay, null);
    adapter.wall_clock_ms = struct {
        fn backwards() i64 {
            return wall() - 3_600_000;
        }
    }.backwards;
    var running = try adapter.copyProjection(allocator);
    defer running.deinit(allocator);
    try std.testing.expect(running.commands[0].elapsed_ms.? > first.commands[0].elapsed_ms.?);
    try std.testing.expect(running.commands[0].elapsed_ms.? < 10_000);
    try std.testing.expectEqual(@as(?i64, null), running.commands[0].end_ms);
    try std.testing.expectEqual(model.CommandState.running, running.commands[0].state);
    try std.testing.expectEqual(first.version, running.version);
    try std.testing.expectEqual(first.style_version, running.style_version);
    try std.testing.expectEqual(first.output_sequence, running.output_sequence);
    try std.testing.expectEqual(first.events[first.events.len - 1].sequence, running.events[running.events.len - 1].sequence);
    _ = try adapter.feed("\x1b]133;D;0\x07");
    var completed = try adapter.copyProjection(allocator);
    defer completed.deinit(allocator);
    try std.testing.expect(completed.commands[0].end_ms.? < completed.commands[0].start_ms);
    try std.testing.expect(completed.commands[0].elapsed_ms.? >= running.commands[0].elapsed_ms.?);
    _ = std.c.nanosleep(&delay, null);
    var later = try adapter.copyProjection(allocator);
    defer later.deinit(allocator);
    try std.testing.expectEqual(completed.commands[0].elapsed_ms, later.commands[0].elapsed_ms);
    try std.testing.expectEqual(completed.commands[0].end_ms, later.commands[0].end_ms);
}

test "command metadata abandon prevents replacement shell D from completing an old command" {
    const Capture = struct {
        abandoned: usize = 0,
        valid: bool = true,
        fn changed(context: *anyopaque, value: model.Command) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (value.state == .unknown) {
                self.abandoned += 1;
                self.valid = self.valid and value.id == 1 and value.end_ms == null and value.exit_code == null and value.elapsed_ms == null;
            }
        }
    };
    var received: Capture = .{};
    var adapter = try Adapter.init(allocator, 5, 30);
    defer adapter.destroy();
    adapter.setCommandObserver(.{ .context = &received, .changed = Capture.changed });
    _ = try adapter.feed("\x1b]133;A\x07$ \x1b]133;B\x07old\r\n\x1b]133;C\x07");
    const before = adapter.snapshot();
    adapter.abandonCommands();
    try std.testing.expectEqual(@as(usize, 1), received.abandoned);
    try std.testing.expect(received.valid);
    try std.testing.expectEqual(before.output_sequence, adapter.snapshot().output_sequence);
    _ = try adapter.feed("\x1b]133;D;0\x07\x1b]133;A\x07$ \x1b]133;B\x07new\r\n\x1b]133;C\x07\x1b]133;D;1\x07");
    var result = try adapter.copyProjection(allocator);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), result.commands.len);
    try std.testing.expectEqual(model.CommandState.unknown, result.commands[0].state);
    try std.testing.expectEqual(@as(?i64, null), result.commands[0].end_ms);
    try std.testing.expectEqual(@as(?i32, null), result.commands[0].exit_code);
    try std.testing.expectEqual(@as(?u64, null), result.commands[0].elapsed_ms);
    try std.testing.expectEqual(model.CommandState.failed, result.commands[1].state);
    try std.testing.expectEqual(@as(?i32, 1), result.commands[1].exit_code);
    try std.testing.expect(result.commands[1].end_ms != null);
}

test "command metadata abandon clears pending native input and AI submission" {
    const ExecutionId = @import("host/identity.zig").ExecutionId;
    const id: ExecutionId = .{ .bytes = @splat(25) };
    var adapter = try Adapter.init(allocator, 5, 30);
    defer adapter.destroy();
    try adapter.registerAiSubmission(id, "same");
    _ = try adapter.feed("\x1b]133;A\x07$ \x1b]133;B\x07same\r\n");
    adapter.abandonCommands();
    _ = try adapter.feed("\x1b]133;C\x07\x1b]133;D;0\x07\x1b]133;A\x07$ \x1b]133;B\x07same\r\n\x1b]133;C\x07\x1b]133;D;0\x07");
    var result = try adapter.copyProjection(allocator);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), result.commands.len);
    try std.testing.expectEqual(@as(?[]const u8, null), result.commands[0].command);
    try std.testing.expectEqual(@as(?u32, null), result.commands[0].screen_row);
    for (result.commands) |command| try std.testing.expectEqual(@as(?ExecutionId, null), command.ai_execution_id);
    try std.testing.expectEqualStrings("same", result.commands[1].command.?);
    try adapter.registerAiSubmission(id, "same");
    adapter.cancelAiSubmission(id);
}

test "command metadata long automatic wrap preserves exact AI source and manual repeat" {
    const ExecutionId = @import("host/identity.zig").ExecutionId;
    const id: ExecutionId = .{ .bytes = @splat(31) };
    const command = "printf '%s\\n' 'abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz'  ";
    var adapter = try Adapter.init(allocator, 12, 20);
    defer adapter.destroy();
    try adapter.registerAiSubmission(id, command);
    for (0..2) |_| {
        _ = try adapter.feed("\x1b]133;A\x07$ \x1b]133;B\x07");
        _ = try adapter.feed(command);
        _ = try adapter.feed("\r\n\x1b]133;C\x07\x1b]133;D;0\x07");
    }
    var result = try adapter.copyProjection(allocator);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), result.commands.len);
    try std.testing.expectEqual(@as(?ExecutionId, id), result.commands[0].ai_execution_id);
    try std.testing.expectEqual(@as(?ExecutionId, null), result.commands[1].ai_execution_id);
    try std.testing.expect(result.commands[0].id != result.commands[1].id);
    for (result.commands) |value| {
        try std.testing.expectEqualStrings(command, value.command.?);
        try std.testing.expect(value.input_end_row.? >= value.screen_row.? + 5);
        try std.testing.expectEqual(model.CommandState.succeeded, value.state);
    }
}

test "command metadata Chinese prompt and command preserve exact AI source and manual repeat" {
    const ExecutionId = @import("host/identity.zig").ExecutionId;
    const id: ExecutionId = .{ .bytes = @splat(32) };
    const command = "printf '%s\\n' '中文命令与输出：你好，世界'  ";
    var adapter = try Adapter.init(allocator, 10, 24);
    defer adapter.destroy();
    try adapter.registerAiSubmission(id, command);
    for (0..2) |_| {
        _ = try adapter.feed("\x1b]133;A\x07中文工作台 ❯ \x1b]133;B\x07");
        const start_col = adapter.snapshot().cursor.col;
        _ = try adapter.feed(command);
        _ = try adapter.feed("\r\n\x1b]133;C\x07\x1b]133;D;0\x07");
        var snapshot = try adapter.copyProjection(allocator);
        defer snapshot.deinit(allocator);
        try std.testing.expectEqual(@as(?u16, start_col), snapshot.commands[snapshot.commands.len - 1].col);
    }
    var result = try adapter.copyProjection(allocator);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), result.commands.len);
    try std.testing.expectEqual(@as(?ExecutionId, id), result.commands[0].ai_execution_id);
    try std.testing.expectEqual(@as(?ExecutionId, null), result.commands[1].ai_execution_id);
    for (result.commands) |value| {
        try std.testing.expectEqualStrings(command, value.command.?);
        try std.testing.expect(value.input_end_row.? > value.screen_row.?);
    }
}

fn localSemanticCommand(command: []const u8) ![]u8 {
    // Exercise the production Local producer's byte encoder. The candidate
    // command is an argv value passed to its hook; it is never evaluated.
    var sandbox = std.testing.tmpDir(.{});
    defer sandbox.cleanup();
    try sandbox.dir.writeFile(std.testing.io, .{ .sub_path = "integration.zsh", .data = @embedFile("local/shell/integration.zsh") });
    const path = try sandbox.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(path);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("ZDOTDIR", path);
    try environment.put("LC_ALL", "C");
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "/bin/zsh", "-f", "-i", "-c", "source ./integration.zsh; _zw_semantic_preexec \"$1\"", "zerowork-command-metadata-test", command },
        .cwd = .{ .dir = sandbox.dir },
        .environ_map = &environment,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } },
    });
    defer allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);
    try std.testing.expect(result.term.success());
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "\x1b]133;C;cmdline_url="));
    return result.stdout;
}

test "command metadata production Local multiline producer preserves exact AI source and manual repeat" {
    const ExecutionId = @import("host/identity.zig").ExecutionId;
    const id: ExecutionId = .{ .bytes = @splat(33) };
    const command = "printf '%s\\n' '第一行'\nprintf '%s\\n' '第二行'  ";
    const semantic = try localSemanticCommand(command);
    defer allocator.free(semantic);
    var adapter = try Adapter.init(allocator, 10, 30);
    defer adapter.destroy();
    try adapter.registerAiSubmission(id, command);
    for (0..2) |_| {
        _ = try adapter.feed("\x1b]133;A\x07中文 ❯ \x1b]133;B\x07printf '%s\\n' '第一行'\r\n\x1b]133;P;k=s\x07续行> \x1b]133;B\x07printf '%s\\n' '第二行'  \r\n");
        _ = try adapter.feed(semantic);
        _ = try adapter.feed("\x1b]133;D;0\x07");
    }
    var result = try adapter.copyProjection(allocator);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), result.commands.len);
    try std.testing.expectEqual(@as(?ExecutionId, id), result.commands[0].ai_execution_id);
    try std.testing.expectEqual(@as(?ExecutionId, null), result.commands[1].ai_execution_id);
    try std.testing.expect(result.commands[0].id != result.commands[1].id);
    for (result.commands) |value| try std.testing.expectEqualStrings(command, value.command.?);
}

test "command metadata native PS2 continuation preserves exact AI source and manual repeat" {
    const ExecutionId = @import("host/identity.zig").ExecutionId;
    const id: ExecutionId = .{ .bytes = @splat(34) };
    const command = "printf '%s\\n' \\\n'中文续行'  ";
    var adapter = try Adapter.init(allocator, 8, 30);
    defer adapter.destroy();
    try adapter.registerAiSubmission(id, command);
    for (0..2) |_| _ = try adapter.feed("\x1b]133;A\x07中文 ❯ \x1b]133;B\x07printf '%s\\n' \\\r\n\x1b]133;P;k=s\x07续行> \x1b]133;B\x07'中文续行'  \r\n\x1b]133;C\x07\x1b]133;D;0\x07");
    var result = try adapter.copyProjection(allocator);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), result.commands.len);
    try std.testing.expectEqual(@as(?ExecutionId, id), result.commands[0].ai_execution_id);
    try std.testing.expectEqual(@as(?ExecutionId, null), result.commands[1].ai_execution_id);
    try std.testing.expect(result.commands[0].id != result.commands[1].id);
    for (result.commands) |value| {
        try std.testing.expectEqualStrings(command, value.command.?);
        try std.testing.expect(value.input_end_row.? > value.screen_row.?);
    }
}
