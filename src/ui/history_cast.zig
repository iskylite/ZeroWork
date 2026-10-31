//! Decode persisted asciicast output through the same Ghostty VT used by live
//! sessions. Control sequences are interpreted, never displayed as transcript.
const std = @import("std");
const Adapter = @import("../vt/ghostty_adapter.zig").Adapter;
const Engine = @import("../vt/engine.zig").VtEngine;
const projection = @import("../vt/text_projection_styled.zig");
const frame = @import("../vt/text_frame.zig");
const Timeline = @import("history_replay.zig").Timeline;

pub fn load(allocator: std.mem.Allocator, cast: []const u8) !Timeline {
    return loadCancelable(allocator, cast, null);
}
pub fn loadCancelable(allocator: std.mem.Allocator, cast: []const u8, cancel: ?*const std.atomic.Value(bool)) !Timeline {
    return loadWithDisplay(allocator, cast, cancel, .{});
}
pub fn loadWithDisplay(allocator: std.mem.Allocator, cast: []const u8, cancel: ?*const std.atomic.Value(bool), display: @import("../vt/recording_manifest.zig").Display) !Timeline {
    return loadWithManifest(allocator, cast, cancel, display, null);
}
pub fn loadWithManifest(allocator: std.mem.Allocator, cast: []const u8, cancel: ?*const std.atomic.Value(bool), display: @import("../vt/recording_manifest.zig").Display, metadata: ?@import("../vt/recording_manifest.zig").Manifest) !Timeline {
    // Display color snapshots are historical metadata, never a UI theme.
    // Keep native cell color tags; the reader resolves them against the live
    // global palette without changing recorded bytes or literal truecolor.
    _ = display;
    var lines = std.mem.splitScalar(u8, cast, '\n');
    const header = try std.json.parseFromSlice(std.json.Value, allocator, lines.next() orelse return error.InvalidCast, .{});
    defer header.deinit();
    if (header.value != .object) return error.InvalidCast;
    const version = header.value.object.get("version") orelse return error.InvalidCast;
    const cols = try dimension(header.value.object.get("width") orelse return error.InvalidCast);
    const rows = try dimension(header.value.object.get("height") orelse return error.InvalidCast);
    if (version != .integer or version.integer != 2) return error.InvalidCast;
    // A ring tail may begin inside an ANSI sequence, alternate screen or
    // unknown geometry. Never interpret it from a fabricated empty VT.
    if (header.value.object.get("zerowork")) |header_metadata| {
        if (header_metadata != .object) return error.InvalidCast;
        if (header_metadata.object.get("replay_baseline")) |baseline| {
            if (baseline != .string) return error.InvalidCast;
            if (std.mem.eql(u8, baseline.string, "unavailable")) return error.RecordingBaselineUnavailable;
            return error.UnsupportedRecordingBaseline;
        }
    }
    var adapter = try Adapter.init(allocator, rows, cols);
    defer adapter.destroy();
    // Cast output has frame-relative timing. Never stamp decoded historical
    // rows with the wall clock of the machine opening the archive.
    adapter.wall_clock_ms = replayClockUnknown;
    var timeline = Timeline.init(allocator, 128 * 1024 * 1024);
    errdefer timeline.deinit();
    var command_replay: CommandReplay = .{ .timeline = &timeline, .metadata = metadata };
    adapter.setCommandObserver(.{ .context = &command_replay, .changed = CommandReplay.observed });
    var source: @import("terminal_document_source.zig").Source = .{ .adapter = &adapter, .owner = .{ .session_id = @fromBackingInt(1) } };
    var composite = @import("terminal_document.zig").Document.init(allocator, source.service(), source.owner);
    defer composite.deinit();
    var previous_ms: i64 = 0;
    var cast_line: u64 = 0;
    while (lines.next()) |line| {
        if (cancel) |token| if (token.load(.acquire)) return error.Cancelled;
        if (std.mem.trim(u8, line, " \r\t").len == 0) continue;
        cast_line += 1;
        command_replay.atLine(cast_line);
        const event = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer event.deinit();
        if (event.value != .array or event.value.array.items.len != 3) return error.InvalidCast;
        const items = event.value.array.items;
        const seconds: f64 = switch (items[0]) {
            .integer => |v| @floatFromInt(v),
            .float => |v| v,
            else => return error.InvalidCast,
        };
        if (!std.math.isFinite(seconds) or seconds < 0 or seconds > 1e12) return error.InvalidCast;
        const ms: i64 = @intFromFloat(seconds * 1000);
        if (ms < previous_ms) return error.InvalidCast;
        previous_ms = ms;
        if (items[1] != .string or items[2] != .string) return error.InvalidCast;
        if (std.mem.eql(u8, items[1].string, "r")) {
            const separator = std.mem.indexOfScalar(u8, items[2].string, 'x') orelse return error.InvalidCast;
            const width = std.fmt.parseInt(u16, items[2].string[0..separator], 10) catch return error.InvalidCast;
            const height = std.fmt.parseInt(u16, items[2].string[separator + 1 ..], 10) catch return error.InvalidCast;
            if (width == 0 or height == 0 or width > 1000 or height > 1000) return error.InvalidCast;
            try adapter.resize(width, height);
        } else if (std.mem.eql(u8, items[1].string, "o")) {
            _ = try adapter.feed(items[2].string);
        } else if (std.mem.eql(u8, items[1].string, "a")) {
            const record = try std.json.parseFromSlice(@import("../host/terminal_service.zig").ApplicationRecord, allocator, items[2].string, .{});
            defer record.deinit();
            try composite.restore(record.value);
        } else continue;
        if (command_replay.failure) |err| return err;
        try command_replay.refreshLocations(&adapter, allocator);
        if (composite.enabled) {
            var combined = try composite.service().snapshot(allocator);
            defer combined.deinit(allocator);
            command_replay.takeLocations(combined.projection.commands);
            var captured = try composite.service().searchSnapshot(allocator);
            const search_bytes = captured.document.text.len + captured.document.rows.len * @sizeOf(@import("../vt/search_snapshot.zig").Row) + captured.document.spans.len * @sizeOf(@import("../vt/search_snapshot.zig").Span);
            if (timeline.bytes + Timeline.projectionStorageBytes(&combined.projection) + search_bytes > timeline.limit) {
                captured.deinit(allocator);
                return error.HistoryRecordingTooLarge;
            }
            timeline.appendProjection(ms, &combined.projection) catch |err| {
                captured.deinit(allocator);
                return err;
            };
            timeline.frames.items[timeline.frames.items.len - 1].search = captured.document;
            timeline.bytes += search_bytes;
            continue;
        }
        const snap = adapter.snapshot();
        const styled = try projection.renderVisibleTextStyled(Engine.from(Adapter, &adapter), allocator);
        defer allocator.free(styled.text);
        defer allocator.free(styled.spans);
        const wire = try allocator.alloc(u8, frame.header_bytes + styled.spans.len * frame.span_wire_bytes + styled.text.len);
        defer allocator.free(wire);
        frame.encodeHeader(wire[0..frame.header_bytes], .{ .row = snap.cursor.row, .col = snap.cursor.col, .visible = false }, snap.cols, snap.rows, styled.spans.len, styled.text.len);
        frame.encodeSpans(wire[frame.header_bytes..][0 .. styled.spans.len * frame.span_wire_bytes], styled.spans);
        @memcpy(wire[frame.header_bytes + styled.spans.len * frame.span_wire_bytes ..], styled.text);
        // Refuse truncation: a closed-session replay must retain the beginning.
        if (timeline.bytes + wire.len > timeline.limit) return error.HistoryRecordingTooLarge;
        var document = try adapter.searchSnapshot(allocator);
        errdefer document.deinit(allocator);
        const search_bytes = document.text.len + document.rows.len * @sizeOf(@import("../vt/search_snapshot.zig").Row) + document.spans.len * @sizeOf(@import("../vt/search_snapshot.zig").Span);
        if (timeline.bytes + wire.len + search_bytes > timeline.limit) return error.HistoryRecordingTooLarge;
        try timeline.append(ms, wire);
        timeline.frames.items[timeline.frames.items.len - 1].reverse_colors = snap.modes.reverse_colors;
        timeline.frames.items[timeline.frames.items.len - 1].search = document;
        timeline.bytes += search_bytes;
    }
    if (timeline.frames.items.len == 0) return error.EmptyRecording;
    return timeline;
}

const CommandReplay = struct {
    timeline: *Timeline,
    metadata: ?@import("../vt/recording_manifest.zig").Manifest,
    generation: u64 = 1,
    generation_index: usize = 0,
    failure: ?anyerror = null,
    fn atLine(self: *CommandReplay, line: u64) void {
        const metadata = self.metadata orelse return;
        var sequence: u64 = 0;
        for (metadata.events) |event| if (event.cast_line == line) {
            sequence = event.sequence;
            break;
        };
        const generations = metadata.recording.generations;
        while (self.generation_index + 1 < generations.len and sequence >= generations[self.generation_index + 1].event_sequence_start) {
            self.generation_index += 1;
            self.generation = generations[self.generation_index].recording_generation;
        }
    }
    fn refreshLocations(self: *CommandReplay, adapter: *Adapter, allocator: std.mem.Allocator) !void {
        if (self.timeline.commands.items.len == 0) return;
        var current = try adapter.copyProjection(allocator);
        defer current.deinit(allocator);
        self.takeLocations(current.commands);
    }
    fn takeLocations(self: *CommandReplay, commands: []const @import("../vt/snapshot.zig").Command) void {
        for (self.timeline.commands.items, self.timeline.command_frames.items) |*command, frame_index| {
            if (frame_index != self.timeline.frames.items.len) continue;
            command.screen_row = null;
            command.col = null;
            command.input_end_row = null;
            command.input_end_col = null;
            command.output_start_row = null;
            command.output_start_col = null;
            for (commands) |native| if (native.id == command.id) {
                command.screen_row = native.screen_row;
                command.col = native.col;
                command.input_end_row = native.input_end_row;
                command.input_end_col = native.input_end_col;
                command.output_start_row = native.output_start_row;
                command.output_start_col = native.output_start_col;
                break;
            };
        }
    }
    fn observed(raw: *anyopaque, native: @import("../vt/snapshot.zig").Command) void {
        const self: *CommandReplay = @ptrCast(@alignCast(raw));
        if (self.failure != null) return;
        var command = native;
        // Old archives have no authoritative wall clock, elapsed time or AI
        // provenance. Never assign their decode-time values to historical runs.
        command.start_ms = 0;
        command.end_ms = null;
        command.elapsed_ms = null;
        command.exit_code = null;
        command.state = .unknown;
        command.ai_execution_id = null;
        if (self.metadata) |metadata| for (metadata.command_history) |saved| {
            if (saved.recording_generation != self.generation or saved.value.id != native.id) continue;
            if (saved.value.command) |text| {
                const captured = native.command orelse break;
                if (!std.mem.eql(u8, text, captured)) break;
            }
            // The manifest and cast are leased and checksum-verified together.
            // Preserve native row coordinates at this frame, restore facts only.
            command.start_ms = saved.value.start_ms;
            command.end_ms = saved.value.end_ms;
            command.elapsed_ms = saved.value.elapsed_ms;
            command.exit_code = saved.value.exit_code;
            command.state = saved.value.state;
            command.ai_execution_id = saved.value.ai_execution_id;
            @import("../vt/recording_manifest.zig").applyPrivateCommandEvidence(&command, self.generation, metadata.execution_ranges);
            break;
        };
        self.timeline.recordCommand(command, self.timeline.frames.items.len) catch |err| {
            self.failure = err;
        };
    }
};

fn replayClockUnknown() i64 {
    return 0;
}

fn dimension(value: std.json.Value) !u16 {
    if (value != .integer or value.integer < 1 or value.integer > 1000) return error.InvalidCast;
    return @intCast(value.integer);
}

test "archived cast replays real ANSI output with original timing" {
    var timeline = try load(std.testing.allocator, "{\"version\":2,\"width\":12,\"height\":2}\n[0,\"o\",\"first\"]\n[2.5,\"o\",\"\\r\\u001b[2Ksecond\"]\n");
    defer timeline.deinit();
    try std.testing.expectEqual(@as(usize, 2), timeline.frames.items.len);
    try std.testing.expectEqual(@as(i64, 2500), timeline.frames.items[1].time_ms);
    try std.testing.expect(std.mem.startsWith(u8, frame.decode(timeline.frames.items[0].wire).?.text, "first"));
    try std.testing.expect(std.mem.startsWith(u8, frame.decode(timeline.frames.items[1].wire).?.text, "second"));
    try std.testing.expectError(error.InvalidCast, load(std.testing.allocator, "{\"version\":2,\"width\":0,\"height\":2}\n"));
    try std.testing.expectError(error.EmptyRecording, load(std.testing.allocator, "{\"version\":2,\"width\":12,\"height\":2}\n"));
}

test "archived search source follows recorded resize and keeps offscreen logical lines" {
    var timeline = try load(std.testing.allocator, "{\"version\":2,\"width\":8,\"height\":2}\n[0,\"o\",\"abcdefghijk\\r\\nsecond\\r\\nlast\"]\n[1,\"r\",\"13x3\"]\n[2,\"o\",\"!\"]\n");
    defer timeline.deinit();
    const latest = timeline.latest().?;
    try std.testing.expectEqual(@as(u16, 13), frame.decode(latest.wire).?.cols);
    try std.testing.expectEqual(@as(u16, 3), frame.decode(latest.wire).?.rows);
    try std.testing.expect(std.mem.indexOf(u8, latest.search.?.text, "abcdefghijk") != null);
}

test "builtin_records archive application events restore ordered records without feeding application text to VT" {
    const a = std.testing.allocator;
    var recording = try @import("../vt/timeline.zig").Timeline.init(a, 16, 65536);
    defer recording.deinit();
    try recording.append(0, 0, "before\r\nprompt% ");
    const owner: @import("../host/identity.zig").SessionHandle = .{ .session_id = @fromBackingInt(5) };
    try recording.appendApplication(.{ .id = 1, .owner = owner, .timestamp_ms = 1, .command = "@ts", .output = "执行中…", .state = .pending }, 16);
    try recording.appendApplication(.{ .id = 1, .owner = owner, .timestamp_ms = 2, .command = "@ts", .output = "已开启时间戳", .state = .success }, 16);
    try recording.append(3, 16, "echo after\r\nafter\r\nprompt% ");
    var buffer: [65536]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try recording.exportCast(&writer, 32, 6);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"a\"") != null);
    var timeline = try load(a, writer.buffered());
    defer timeline.deinit();
    const latest = timeline.latest().?;
    const text = latest.search.?.text;
    const command = std.mem.indexOf(u8, text, "@ts").?;
    const result = std.mem.indexOf(u8, text, "已开启时间戳").?;
    const after = std.mem.indexOf(u8, text, "echo after").?;
    try std.testing.expect(command < result and result < after);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "@ts"));
    try std.testing.expect(std.mem.indexOf(u8, text, "执行中…") == null);
}

test "builtin_records delayed application events retain their original row and stream clock" {
    const a = std.testing.allocator;
    var recording = try @import("../vt/timeline.zig").Timeline.init(a, 8, 8192);
    defer recording.deinit();
    try recording.append(10, 0, "before\r\nprompt% ");
    try recording.append(11, 16, "echo later\r\nlater\r\nprompt% ");
    try recording.appendApplicationAt(.{ .id = 1, .owner = .{ .session_id = @fromBackingInt(5) }, .timestamp_ms = 1792937468187, .anchor_row = 1, .command = "@help", .output = "help result", .state = .success }, 40, 12);
    var bytes: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try recording.exportCast(&writer, 32, 6);
    var timeline = try load(a, writer.buffered());
    defer timeline.deinit();
    const latest = timeline.latest().?;
    try std.testing.expectEqual(@as(i64, 2), latest.time_ms);
    const text = latest.search.?.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "@help").? < std.mem.indexOf(u8, text, "echo later").?);
}

test "builtin_records replay keys command identity by source generation" {
    const a = std.testing.allocator;
    var recording = try @import("../vt/timeline.zig").Timeline.init(a, 8, 8192);
    defer recording.deinit();
    try recording.append(0, 0, "prompt% ");
    try recording.appendApplication(.{ .id = 1, .owner = .{ .session_id = @fromBackingInt(5), .generation = 1 }, .timestamp_ms = 1, .command = "@ts", .output = "first generation", .state = .success }, 8);
    try recording.appendApplication(.{ .id = 1, .owner = .{ .session_id = @fromBackingInt(5), .generation = 2 }, .timestamp_ms = 2, .command = "@theme", .output = "second generation", .state = .success }, 8);
    var bytes: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try recording.exportCast(&writer, 32, 6);
    var timeline = try load(a, writer.buffered());
    defer timeline.deinit();
    const text = timeline.latest().?.search.?.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "first generation") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "second generation") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "@ts"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "@theme"));
}

test "history refuses retained ANSI tails without a replay baseline after snapshot" {
    const a = std.testing.allocator;
    var recording = try @import("../vt/timeline.zig").Timeline.init(a, 2, 4096);
    defer recording.deinit();
    try recording.append(0, 0, "\x1b[31m\x1b[?1049h");
    try recording.appendResize(1, 13, 120, 30);
    try recording.append(2, 13, "tail");
    var frozen = try recording.snapshotWithAllocator(a);
    defer frozen.deinit();
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try frozen.exportCast(&writer, 80, 24);
    try std.testing.expectError(error.RecordingBaselineUnavailable, load(a, writer.buffered()));
    try std.testing.expectError(error.UnsupportedRecordingBaseline, load(a, "{\"version\":2,\"width\":80,\"height\":24,\"zerowork\":{\"replay_baseline\":\"future\"}}\n"));
}

test "command history replay separates reconnect generations and leaves old provenance unknown" {
    const a = std.testing.allocator;
    const Manifest = @import("../vt/recording_manifest.zig");
    const ai_id = @import("../host/identity.zig").ExecutionId.generate();
    const cast = "{\"version\":2,\"width\":20,\"height\":4}\n[0,\"o\",\"\\u001b]133;A\\u0007$ \\u001b]133;B\\u0007true\\r\\n\\u001b]133;C\\u0007\\u001b]133;D;0\\u0007\"]\n[1,\"o\",\"\\u001b]133;A\\u0007$ \\u001b]133;B\\u0007true\\r\\n\\u001b]133;C\\u0007\\u001b]133;D;7\\u0007\"]\n";
    const metadata: Manifest.Manifest = .{
        .archive_key = "11111111111111111111111111111111",
        .recording_id = "22222222222222222222222222222222",
        .source_kind = .ssh,
        .started_ms = 100,
        .recording = .{ .generations = &.{
            .{ .recording_generation = 1, .session_id = 1, .session_generation = 1, .initial_cols = 20, .initial_rows = 4, .receive_time_origin = 0, .event_sequence_start = 1 },
            .{ .recording_generation = 2, .session_id = 1, .session_generation = 2, .initial_cols = 20, .initial_rows = 4, .receive_time_origin = 1, .event_sequence_start = 2 },
        } },
        .events = &.{
            .{ .sequence = 1, .raw_offset = 0, .raw_length = 1, .cast_line = 1, .kind = .output },
            .{ .sequence = 2, .raw_offset = 1, .raw_length = 1, .cast_line = 2, .kind = .output },
        },
        .command_history = &.{
            .{ .recording_generation = 1, .value = .{ .id = 1, .command = "true", .start_ms = 100, .end_ms = 110, .elapsed_ms = 10, .exit_code = 0, .state = .succeeded } },
            .{ .recording_generation = 2, .value = .{ .id = 2, .command = "true", .start_ms = 200, .end_ms = 230, .elapsed_ms = 30, .exit_code = 7, .state = .failed, .ai_execution_id = ai_id } },
        },
    };
    var replay = try loadWithManifest(a, cast, null, .{}, metadata);
    defer replay.deinit();
    try std.testing.expectEqual(@as(usize, 2), replay.commands.items.len);
    try std.testing.expect(replay.commands.items[0].ai_execution_id == null);
    try std.testing.expect(replay.commands.items[1].ai_execution_id.?.eql(ai_id));
    try std.testing.expectEqual(@as(i64, 200), replay.commands.items[1].start_ms);
    try std.testing.expectEqual(@as(?u64, 30), replay.commands.items[1].elapsed_ms);
    try std.testing.expectEqual(@as(?usize, 0), replay.commandFrame(1));
    try std.testing.expectEqual(@as(?usize, 1), replay.commandFrame(2));
    var old = try load(a, cast);
    defer old.deinit();
    for (old.commands.items) |command| {
        try std.testing.expectEqual(@import("../vt/snapshot.zig").CommandState.unknown, command.state);
        try std.testing.expect(command.start_ms == 0 and command.end_ms == null and command.elapsed_ms == null and command.exit_code == null and command.ai_execution_id == null);
    }
}
