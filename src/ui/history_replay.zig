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
    pub const PresentationRow = struct { layout: @import("terminal_record_geometry.zig").Layout = .{}, y: u16, id: @import("../vt/snapshot.zig").RowId, kind: u8, state: u8, timestamp: ?i64 };
    pub const Entry = struct { time_ms: i64, wire: []u8, presentation: []PresentationRow = &.{}, search: ?@import("../vt/search_snapshot.zig").Document = null };
    pub fn projectionStorageBytes(projection: *const @import("../vt/snapshot.zig").Projection) usize {
        var text_bytes: usize = projection.visible_rows.len -| 1;
        var spans: usize = 0;
        for (projection.visible_rows) |row| {
            const cells = projection.cells[row.cell_start..][0..row.cell_count];
            var end = cells.len;
            while (end > 0 and cells[end - 1].grapheme_len == 0) end -= 1;
            for (cells[0..end]) |cell| if (cell.width != .wide_tail) {
                spans += 1;
                text_bytes += @max(1, cell.grapheme_len);
            };
        }
        return text_frame.header_bytes + text_bytes + @min(spans, std.math.maxInt(u16)) * text_frame.span_wire_bytes + projection.visible_rows.len * @sizeOf(PresentationRow);
    }
    pub fn appendProjection(self: *Timeline, at: i64, projection: *const @import("../vt/snapshot.zig").Projection) !void {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.allocator);
        var spans: std.ArrayList(@import("../vt/text_projection_styled.zig").Span) = .empty;
        defer spans.deinit(self.allocator);
        for (projection.visible_rows, 0..) |row, index| {
            const cells = projection.cells[row.cell_start..][0..row.cell_count];
            var end = cells.len;
            while (end > 0 and cells[end - 1].grapheme_len == 0) end -= 1;
            for (cells[0..end]) |cell| {
                if (cell.width == .wide_tail) continue;
                const start: u32 = @intCast(text.items.len);
                if (cell.grapheme_len == 0) try text.append(self.allocator, ' ') else try text.appendSlice(self.allocator, projection.graphemes[cell.grapheme_start..][0..cell.grapheme_len]);
                try spans.append(self.allocator, .{ .start = start, .end = @intCast(text.items.len), .color = projectionColor(cell.foreground, projection.colors), .bg = projectionColor(cell.background, projection.colors), .bold = cell.attributes & 1 != 0, .italic = cell.attributes & 2 != 0, .underline = cell.underline != 0 });
            }
            if (index + 1 < projection.visible_rows.len) try text.append(self.allocator, '\n');
        }
        const span_count = @min(spans.items.len, std.math.maxInt(u16));
        const wire = try self.allocator.alloc(u8, text_frame.header_bytes + span_count * text_frame.span_wire_bytes + text.items.len);
        defer self.allocator.free(wire);
        text_frame.encodeHeader(wire[0..text_frame.header_bytes], .{ .row = projection.cursor.row, .col = projection.cursor.col, .visible = false }, projection.cols, projection.rows, span_count, text.items.len);
        text_frame.encodeSpans(wire[text_frame.header_bytes..][0 .. span_count * text_frame.span_wire_bytes], spans.items[0..span_count]);
        @memcpy(wire[text_frame.header_bytes + span_count * text_frame.span_wire_bytes ..], text.items);
        const presentation = try self.allocator.alloc(PresentationRow, projection.visible_rows.len);
        errdefer self.allocator.free(presentation);
        for (projection.visible_rows, presentation) |row, *saved| saved.* = .{ .layout = row.presentation, .y = row.viewport_y, .id = row.id, .kind = row.application_kind, .state = row.application_state, .timestamp = row.submitted_wallclock_ms orelse row.received_wallclock_ms };
        try self.append(at, wire);
        self.frames.items[self.frames.items.len - 1].presentation = presentation;
        self.bytes += presentation.len * @sizeOf(PresentationRow);
    }
    fn projectionColor(color: @import("../vt/snapshot.zig").Color, colors: @import("../vt/snapshot.zig").Colors) u32 {
        const rgb = switch (color) {
            .default => return 0,
            .rgb => |v| v,
            .ansi => |v| colors.palette[v],
            .indexed => |v| colors.palette[v],
        };
        return (@as(u32, rgb) << 8) | 255;
    }
    pub fn init(allocator: std.mem.Allocator, limit: usize) Timeline {
        return .{ .allocator = allocator, .limit = limit };
    }
    pub fn deinit(self: *Timeline) void {
        for (self.frames.items) |*entry| {
            self.allocator.free(entry.wire);
            if (entry.presentation.len > 0) self.allocator.free(entry.presentation);
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
        // Keep the frozen selection and newest live frame. When eviction
        // reaches the selection, retire intermediate live frames instead of
        // letting an open replay turn the bounded timeline into an unbounded
        // list. At most those two frames may exceed a very small byte budget.
        while (self.bytes > self.limit and self.frames.items.len > 1) {
            const remove_index: usize = if (self.selected == 0) (if (self.frames.items.len > 2) 1 else break) else 0;
            const oldest = self.frames.orderedRemove(remove_index);
            self.bytes -= oldest.wire.len;
            self.bytes -= oldest.presentation.len * @sizeOf(PresentationRow);
            if (oldest.presentation.len > 0) self.allocator.free(oldest.presentation);
            if (oldest.search) |document| self.bytes -= document.text.len + document.rows.len * @sizeOf(@import("../vt/search_snapshot.zig").Row) + document.spans.len * @sizeOf(@import("../vt/search_snapshot.zig").Span);
            self.allocator.free(oldest.wire);
            var removed = oldest;
            if (removed.search) |*document| document.deinit(self.allocator);
            if (self.selected) |index| if (index > remove_index) {
                self.selected = index - 1;
            };
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

test "builtin_records history keeps the frozen selection and bounded live tail" {
    var timeline = Timeline.init(std.testing.allocator, 34);
    defer timeline.deinit();
    var wire: [text_frame.header_bytes + 1]u8 = undefined;
    text_frame.encodeHeader(wire[0..text_frame.header_bytes], .{}, 1, 1, 0, 1);
    wire[text_frame.header_bytes] = 'a';
    try timeline.append(0, &wire);
    try std.testing.expect(timeline.open());
    for (1..100) |i| {
        wire[text_frame.header_bytes] = 'b';
        try timeline.append(@intCast(i), &wire);
    }
    try std.testing.expectEqual(@as(usize, 2), timeline.frames.items.len);
    try std.testing.expectEqual(@as(usize, 0), timeline.selected.?);
    try std.testing.expectEqualStrings("a", text_frame.decode(timeline.current().?.wire).?.text);
    try std.testing.expectEqual(@as(i64, 99), timeline.latest().?.time_ms);
}
