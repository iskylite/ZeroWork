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
    if (header.value.object.get("zerowork")) |metadata| {
        if (metadata != .object) return error.InvalidCast;
        if (metadata.object.get("replay_baseline")) |baseline| {
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
    var source: @import("terminal_document_source.zig").Source = .{ .adapter = &adapter, .owner = .{ .session_id = @fromBackingInt(1) } };
    var composite = @import("terminal_document.zig").Document.init(allocator, source.service(), source.owner);
    defer composite.deinit();
    var previous_ms: i64 = 0;
    while (lines.next()) |line| {
        if (cancel) |token| if (token.load(.acquire)) return error.Cancelled;
        if (std.mem.trim(u8, line, " \r\t").len == 0) continue;
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
        if (composite.enabled) {
            var combined = try composite.service().snapshot(allocator);
            defer combined.deinit(allocator);
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
