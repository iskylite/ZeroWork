//! Decode persisted asciicast output through the same Ghostty VT used by live
//! sessions. Control sequences are interpreted, never displayed as transcript.
const std = @import("std");
const Adapter = @import("../vt/ghostty_adapter.zig").Adapter;
const Engine = @import("../vt/engine.zig").VtEngine;
const projection = @import("../vt/text_projection_styled.zig");
const frame = @import("../vt/text_frame.zig");
const Timeline = @import("history_replay.zig").Timeline;

pub fn load(allocator: std.mem.Allocator, cast: []const u8) !Timeline {
    var lines = std.mem.splitScalar(u8, cast, '\n');
    const header = try std.json.parseFromSlice(std.json.Value, allocator, lines.next() orelse return error.InvalidCast, .{});
    defer header.deinit();
    if (header.value != .object) return error.InvalidCast;
    const version = header.value.object.get("version") orelse return error.InvalidCast;
    const cols = try dimension(header.value.object.get("width") orelse return error.InvalidCast);
    const rows = try dimension(header.value.object.get("height") orelse return error.InvalidCast);
    if (version != .integer or version.integer != 2) return error.InvalidCast;
    var adapter = try Adapter.init(allocator, rows, cols);
    defer adapter.destroy();
    var timeline = Timeline.init(allocator, 128 * 1024 * 1024);
    errdefer timeline.deinit();
    var previous_ms: i64 = 0;
    while (lines.next()) |line| {
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
        } else continue;
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
        timeline.frames.items[timeline.frames.items.len - 1].search = document;
        timeline.bytes += search_bytes;
    }
    if (timeline.frames.items.len == 0) return error.EmptyRecording;
    return timeline;
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
