const std = @import("std");
const text_frame = @import("../vt/text_frame.zig");

/// UI-owned snapshots of frames actually received from the session. This is
/// an in-memory timeline; persistent RawStreamTap history is a separate source.
pub const Timeline = struct {
    allocator: std.mem.Allocator,
    frames: std.ArrayList(Entry) = .empty,
    bytes: usize = 0,
    limit: usize,
    selected: ?usize = null,
    history_id: ?@import("../host/identity.zig").HistoryId = null,
    pub const Entry = struct { time_ms: i64, wire: []u8, search: ?@import("../vt/search_snapshot.zig").Document = null };
    pub fn init(allocator: std.mem.Allocator, limit: usize) Timeline {
        return .{ .allocator = allocator, .limit = limit };
    }
    pub fn deinit(self: *Timeline) void {
        for (self.frames.items) |*entry| {
            self.allocator.free(entry.wire);
            if (entry.search) |*document| document.deinit(self.allocator);
        }
        self.frames.deinit(self.allocator);
    }
    pub fn append(self: *Timeline, time_ms: i64, wire: []const u8) !void {
        if (text_frame.decode(wire) == null) return error.InvalidFrame;
        const copy = try self.allocator.dupe(u8, wire);
        errdefer self.allocator.free(copy);
        try self.frames.append(self.allocator, .{ .time_ms = time_ms, .wire = copy });
        self.bytes += copy.len;
        // Preserve the selected frame during playback. When eviction reaches
        // it, keep it until playback exits instead of silently changing time.
        while (self.bytes > self.limit and self.frames.items.len > 1) {
            if (self.selected == 0) break;
            const oldest = self.frames.orderedRemove(0);
            self.bytes -= oldest.wire.len;
            if (oldest.search) |document| self.bytes -= document.text.len + document.rows.len * @sizeOf(@import("../vt/search_snapshot.zig").Row) + document.spans.len * @sizeOf(@import("../vt/search_snapshot.zig").Span);
            self.allocator.free(oldest.wire);
            var removed = oldest;
            if (removed.search) |*document| document.deinit(self.allocator);
            if (self.selected) |index| self.selected = index - 1;
        }
    }
    /// Legacy recordings contain viewport frames only. Index every retained
    /// frame explicitly; never claim their missing scrollback was persisted.
    pub fn legacySource(self: *const Timeline, allocator: std.mem.Allocator) ![]u8 {
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(allocator);
        for (self.frames.items, 0..) |entry, index| {
            if (index > 0) try text.append(allocator, '\n');
            const source = text_frame.decode(entry.wire) orelse return error.InvalidFrame;
            if (text.items.len + source.text.len > self.limit) return error.HistoryRecordingTooLarge;
            try text.appendSlice(allocator, source.text);
        }
        return text.toOwnedSlice(allocator);
    }
    pub fn legacyOffset(self: *const Timeline, frame_index: usize) usize {
        var start: usize = 0;
        for (self.frames.items[0..@min(frame_index, self.frames.items.len)]) |entry| start += text_frame.decode(entry.wire).?.text.len + 1;
        return start;
    }
    pub fn legacyLocation(self: *const Timeline, byte: usize) ?struct { frame: usize, start: usize, end: usize } {
        var start: usize = 0;
        for (self.frames.items, 0..) |entry, index| {
            const source = text_frame.decode(entry.wire) orelse return null;
            const end = start + source.text.len;
            if (byte >= start and byte < end) return .{ .frame = index, .start = start, .end = end };
            start = end + 1;
        }
        return null;
    }
    pub fn open(self: *Timeline) bool {
        if (self.frames.items.len == 0) return false;
        self.selected = self.frames.items.len - 1;
        return true;
    }
    pub fn close(self: *Timeline) void {
        self.selected = null;
    }
    pub fn seek(self: *Timeline, fraction: f32) void {
        if (self.selected == null or self.frames.items.len == 0) return;
        self.selected = @intFromFloat(@round(std.math.clamp(fraction, 0, 1) * @as(f32, @floatFromInt(self.frames.items.len - 1))));
    }
    pub fn current(self: *const Timeline) ?Entry {
        return self.frames.items[self.selected orelse return null];
    }
    pub fn latest(self: *const Timeline) ?Entry {
        return if (self.frames.items.len == 0) null else self.frames.items[self.frames.items.len - 1];
    }
};

test "timeline replays actual frames and keeps live updates separate" {
    var t = Timeline.init(std.testing.allocator, 1024);
    defer t.deinit();
    var wire: [text_frame.header_bytes + 1]u8 = undefined;
    text_frame.encodeHeader(wire[0..text_frame.header_bytes], .{}, 1, 1, 0, 1);
    wire[text_frame.header_bytes] = 'a';
    try t.append(10, &wire);
    try std.testing.expect(t.open());
    wire[text_frame.header_bytes] = 'b';
    try t.append(20, &wire);
    try std.testing.expectEqualStrings("a", text_frame.decode(t.current().?.wire).?.text);
    t.seek(1);
    try std.testing.expectEqualStrings("b", text_frame.decode(t.current().?.wire).?.text);
    t.close();
    try std.testing.expect(t.current() == null);
    try std.testing.expectEqual(@as(i64, 20), t.latest().?.time_ms);
}

test "timeline evicts bounded old frames and rejects invalid data" {
    var t = Timeline.init(std.testing.allocator, 17);
    defer t.deinit();
    try std.testing.expect(!t.open());
    try std.testing.expectError(error.InvalidFrame, t.append(0, "bad"));
    var wire: [text_frame.header_bytes + 1]u8 = undefined;
    text_frame.encodeHeader(wire[0..text_frame.header_bytes], .{}, 1, 1, 0, 1);
    wire[text_frame.header_bytes] = 'a';
    try t.append(1, &wire);
    try t.append(2, &wire);
    try std.testing.expectEqual(@as(usize, 1), t.frames.items.len);
    try std.testing.expectEqual(@as(i64, 2), t.latest().?.time_ms);
}

test "legacy history search indexes all retained frames with original frame locations" {
    const a = std.testing.allocator;
    var timeline = Timeline.init(a, 4096);
    defer timeline.deinit();
    var wire: [text_frame.header_bytes + 6]u8 = undefined;
    text_frame.encodeHeader(wire[0..text_frame.header_bytes], .{}, 6, 1, 0, 6);
    @memcpy(wire[text_frame.header_bytes..], "needle");
    try timeline.append(1, &wire);
    @memcpy(wire[text_frame.header_bytes..], "latest");
    try timeline.append(2, &wire);
    try std.testing.expect(timeline.open());
    const source = try timeline.legacySource(a);
    defer a.free(source);
    try std.testing.expectEqualStrings("needle\nlatest", source);
    const found = timeline.legacyLocation(std.mem.indexOf(u8, source, "needle").?).?;
    try std.testing.expectEqual(@as(usize, 0), found.frame);
    try std.testing.expectEqual(@as(usize, 0), found.start);
    try std.testing.expectEqual(@as(usize, 7), timeline.legacyOffset(1));
    try std.testing.expectEqual(@as(usize, 1), timeline.selected.?);
}
