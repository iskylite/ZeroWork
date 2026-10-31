const std = @import("std");
const text_frame = @import("../vt/text_frame.zig");

test {
    _ = @import("history_colors.zig");
}

/// UI-owned snapshots of frames actually received from the session. This is
/// an in-memory timeline; persistent RawStreamTap history is a separate source.
pub const Timeline = struct {
    allocator: std.mem.Allocator,
    frames: std.ArrayList(Entry) = .empty,
    commands: std.ArrayList(@import("../vt/snapshot.zig").Command) = .empty,
    command_frames: std.ArrayList(usize) = .empty,
    bytes: usize = 0,
    limit: usize,
    selected: ?usize = null,
    history_id: ?@import("../host/identity.zig").HistoryId = null,
    pub const PresentationRow = struct { layout: @import("terminal_record_geometry.zig").Layout = .{}, y: u16, id: @import("../vt/snapshot.zig").RowId, kind: u8, state: u8, timestamp: ?i64 };
    pub const ColorRun = struct { start: u32, end: u32, cell: @import("../vt/snapshot.zig").Cell, kind: u8 };
    pub const Entry = struct { time_ms: i64, wire: []u8, presentation: []PresentationRow = &.{}, search: ?@import("../vt/search_snapshot.zig").Document = null, search_allocator: ?std.mem.Allocator = null, reverse_colors: bool = false, color_runs: []ColorRun = &.{} };
    pub fn projectionStorageBytes(projection: *const @import("../vt/snapshot.zig").Projection) usize {
        var text_bytes: usize = projection.visible_rows.len -| 1;
        var spans: usize = 0;
        for (projection.visible_rows) |row| {
            const cells = projection.cells[row.cell_start..][0..row.cell_count];
            var end = cells.len;
            while (end > 0 and cells[end - 1].grapheme_len == 0 and cells[end - 1].attributes == 0 and cells[end - 1].background == .default and cells[end - 1].underline == 0 and !projection.modes.reverse_colors) end -= 1;
            for (cells[0..end]) |cell| if (cell.width != .wide_tail) {
                spans += 1;
                text_bytes += @max(1, cell.grapheme_len);
            };
        }
        return text_frame.header_bytes + text_bytes + @min(spans, std.math.maxInt(u16)) * text_frame.span_wire_bytes + projection.visible_rows.len * @sizeOf(PresentationRow) + spans * @sizeOf(ColorRun);
    }
    pub fn appendProjection(self: *Timeline, at: i64, projection: *const @import("../vt/snapshot.zig").Projection) !void {
        _ = try self.appendProjectionInner(at, projection, false);
    }
    pub fn appendProjectionChanged(self: *Timeline, at: i64, projection: *const @import("../vt/snapshot.zig").Projection) !bool {
        return self.appendProjectionInner(at, projection, true);
    }
    fn appendProjectionInner(self: *Timeline, at: i64, projection: *const @import("../vt/snapshot.zig").Projection, deduplicate: bool) !bool {
        const wire = try @import("../vt/projection_frame.zig").encode(self.allocator, projection, false);
        errdefer self.allocator.free(wire);
        const color_runs = try self.captureColors(projection);
        errdefer self.allocator.free(color_runs);
        if (deduplicate) if (self.latest()) |last| if (std.mem.eql(u8, last.wire, wire) and last.presentation.len == projection.visible_rows.len) {
            const same_colors = last.reverse_colors == projection.modes.reverse_colors and last.color_runs.len == color_runs.len and for (last.color_runs, color_runs) |saved, next| {
                if (!std.meta.eql(saved, next)) break false;
            } else true;
            const same = for (projection.visible_rows, last.presentation) |row, saved| {
                if (!std.meta.eql(row.id, saved.id) or !std.meta.eql(row.presentation, saved.layout) or row.viewport_y != saved.y or row.application_kind != saved.kind or row.application_state != saved.state) break false;
            } else true;
            if (same and same_colors) {
                self.allocator.free(wire);
                self.allocator.free(color_runs);
                return false;
            }
        };
        const presentation = try self.allocator.alloc(PresentationRow, projection.visible_rows.len);
        errdefer self.allocator.free(presentation);
        for (projection.visible_rows, presentation) |row, *saved| saved.* = .{ .layout = row.presentation, .y = row.viewport_y, .id = row.id, .kind = row.application_kind, .state = row.application_state, .timestamp = row.submitted_wallclock_ms orelse row.received_wallclock_ms };
        try self.frames.append(self.allocator, .{ .time_ms = at, .wire = wire, .presentation = presentation, .reverse_colors = projection.modes.reverse_colors, .color_runs = color_runs });
        self.bytes += wire.len + presentation.len * @sizeOf(PresentationRow) + color_runs.len * @sizeOf(ColorRun);
        self.trim();
        return true;
    }
    /// Pixel-only viewport changes reuse the current source document rather
    /// than copying the complete scrollback into history on every wheel tick.
    pub fn replaceLatestProjection(self: *Timeline, projection: *const @import("../vt/snapshot.zig").Projection) !void {
        if (self.frames.items.len == 0 or self.selected != null) return error.InvalidFrame;
        const last = &self.frames.items[self.frames.items.len - 1];
        var replacement = Timeline.init(self.allocator, std.math.maxInt(usize));
        defer replacement.deinit();
        try replacement.appendProjection(last.time_ms, projection);
        const next = replacement.frames.pop().?;
        self.bytes -= last.wire.len + last.presentation.len * @sizeOf(PresentationRow) + last.color_runs.len * @sizeOf(ColorRun);
        self.allocator.free(last.wire);
        if (last.presentation.len > 0) self.allocator.free(last.presentation);
        self.allocator.free(last.color_runs);
        last.wire = next.wire;
        last.presentation = next.presentation;
        last.reverse_colors = next.reverse_colors;
        last.color_runs = next.color_runs;
        self.bytes += next.wire.len + next.presentation.len * @sizeOf(PresentationRow) + next.color_runs.len * @sizeOf(ColorRun);
        self.trim();
    }
    pub fn init(allocator: std.mem.Allocator, limit: usize) Timeline {
        return .{ .allocator = allocator, .limit = limit };
    }
    /// A live @log view freezes its retained document while incoming output
    /// continues in an independently bounded live timeline.
    pub fn clone(self: *const Timeline) !Timeline {
        var result = Timeline.init(self.allocator, self.limit);
        errdefer result.deinit();
        result.history_id = self.history_id;
        for (self.commands.items, self.command_frames.items) |command, index| try result.recordCommand(command, index);
        for (self.frames.items) |entry| {
            const wire = try result.allocator.dupe(u8, entry.wire);
            errdefer result.allocator.free(wire);
            const presentation = try result.allocator.dupe(PresentationRow, entry.presentation);
            errdefer result.allocator.free(presentation);
            const color_runs = try result.allocator.dupe(ColorRun, entry.color_runs);
            errdefer result.allocator.free(color_runs);
            var search: ?@import("../vt/search_snapshot.zig").Document = null;
            errdefer if (search) |*document| document.deinit(result.allocator);
            if (entry.search) |document| {
                const text = try result.allocator.dupe(u8, document.text);
                errdefer result.allocator.free(text);
                const rows = try result.allocator.dupe(@import("../vt/search_snapshot.zig").Row, document.rows);
                errdefer result.allocator.free(rows);
                const spans = try result.allocator.dupe(@import("../vt/search_snapshot.zig").Span, document.spans);
                search = .{ .source_version = document.source_version, .alternate_screen = document.alternate_screen, .text = text, .rows = rows, .spans = spans };
            }
            try result.frames.append(result.allocator, .{ .time_ms = entry.time_ms, .wire = wire, .presentation = presentation, .search = search, .reverse_colors = entry.reverse_colors, .color_runs = color_runs });
        }
        result.bytes = self.bytes;
        return result;
    }
    /// The frame is captured at the native C/D callback, so its row remains
    /// meaningful even when later resize/scrollback changes the final grid.
    pub fn commandFrame(self: *const Timeline, id: u64) ?usize {
        for (self.commands.items, self.command_frames.items) |command, index| if (command.id == id) return @min(index, self.frames.items.len -| 1);
        return null;
    }
    pub fn recordCommand(self: *Timeline, value: @import("../vt/snapshot.zig").Command, frame_index: usize) !void {
        var command = value;
        command.command = if (value.command) |text| try self.allocator.dupe(u8, text) else null;
        errdefer if (command.command) |text| self.allocator.free(text);
        for (self.commands.items, 0..) |*saved_command, index| if (saved_command.id == value.id) {
            if (saved_command.command) |text| {
                self.bytes -= text.len;
                self.allocator.free(text);
            }
            saved_command.* = command;
            self.command_frames.items[index] = frame_index;
            self.bytes += if (command.command) |text| text.len else 0;
            return;
        };
        const size = @sizeOf(@import("../vt/snapshot.zig").Command) + @sizeOf(usize) + (if (command.command) |text| text.len else @as(usize, 0));
        if (self.bytes + size > self.limit) return error.HistoryRecordingTooLarge;
        try self.commands.ensureUnusedCapacity(self.allocator, 1);
        try self.command_frames.ensureUnusedCapacity(self.allocator, 1);
        self.commands.appendAssumeCapacity(command);
        self.command_frames.appendAssumeCapacity(frame_index);
        self.bytes += size;
    }
    pub fn deinit(self: *Timeline) void {
        for (self.frames.items) |*entry| {
            self.allocator.free(entry.wire);
            self.allocator.free(entry.presentation);
            self.allocator.free(entry.color_runs);
            if (entry.search) |*document| document.deinit(entry.search_allocator orelse self.allocator);
        }
        self.frames.deinit(self.allocator);
        for (self.commands.items) |command| if (command.command) |text| self.allocator.free(text);
        self.commands.deinit(self.allocator);
        self.command_frames.deinit(self.allocator);
    }
    pub fn append(self: *Timeline, time_ms: i64, wire: []const u8) !void {
        if (text_frame.decode(wire) == null) return error.InvalidFrame;
        const copy = try self.allocator.dupe(u8, wire);
        errdefer self.allocator.free(copy);
        try self.frames.append(self.allocator, .{ .time_ms = time_ms, .wire = copy });
        self.bytes += copy.len;
        self.trim();
    }
    pub fn trim(self: *Timeline) void {
        // Keep the frozen selection and newest live frame. When eviction
        // reaches the selection, retire intermediate live frames instead of
        // letting an open replay turn the bounded timeline into an unbounded
        // list. At most those two frames may exceed a very small byte budget.
        while (self.bytes > self.limit and self.frames.items.len > 1) {
            const remove_index: usize = if (self.selected == 0) (if (self.frames.items.len > 2) 1 else break) else 0;
            const oldest = self.frames.orderedRemove(remove_index);
            for (self.command_frames.items) |*index| {
                if (index.* > remove_index) index.* -= 1;
            }
            self.bytes -= oldest.wire.len;
            self.bytes -= oldest.presentation.len * @sizeOf(PresentationRow);
            self.bytes -= oldest.color_runs.len * @sizeOf(ColorRun);
            if (oldest.presentation.len > 0) self.allocator.free(oldest.presentation);
            self.allocator.free(oldest.color_runs);
            if (oldest.search) |document| self.bytes -= document.text.len + document.rows.len * @sizeOf(@import("../vt/search_snapshot.zig").Row) + document.spans.len * @sizeOf(@import("../vt/search_snapshot.zig").Span);
            self.allocator.free(oldest.wire);
            var removed = oldest;
            if (removed.search) |*document| document.deinit(removed.search_allocator orelse self.allocator);
            if (self.selected) |index| if (index > remove_index) {
                self.selected = index - 1;
            };
        }
    }
    pub fn attachSearch(self: *Timeline, document: @import("../vt/search_snapshot.zig").Document) void {
        self.attachSearchWithAllocator(document, self.allocator);
    }
    pub fn attachSearchWithAllocator(self: *Timeline, document: @import("../vt/search_snapshot.zig").Document, allocator: std.mem.Allocator) void {
        if (!self.canAttachSearch(document)) {
            var rejected = document;
            rejected.deinit(allocator);
            return;
        }
        const last = &self.frames.items[self.frames.items.len - 1];
        if (last.search) |*old| {
            self.bytes -= searchBytes(old.*);
            old.deinit(last.search_allocator orelse self.allocator);
        }
        last.search = document;
        last.search_allocator = allocator;
        self.bytes += searchBytes(document);
        self.trim();
    }
    /// A complete search index is optional; the viewport and raw recording
    /// remain available when that index alone would exceed the history budget.
    pub fn canAttachSearch(self: *const Timeline, document: @import("../vt/search_snapshot.zig").Document) bool {
        const last = self.latest() orelse return false;
        const frame_bytes = last.wire.len + last.presentation.len * @sizeOf(PresentationRow) + last.color_runs.len * @sizeOf(ColorRun);
        return searchBytes(document) <= self.limit -| frame_bytes;
    }
    fn searchBytes(document: @import("../vt/search_snapshot.zig").Document) usize {
        return document.text.len + document.rows.len * @sizeOf(@import("../vt/search_snapshot.zig").Row) + document.spans.len * @sizeOf(@import("../vt/search_snapshot.zig").Span);
    }
    // Keep only coalesced color semantics for the viewport-only @log fallback.
    // Full search documents already retain native_cell; no full Projection or
    // second text copy is retained here. Byte offsets match projection_frame.
    fn captureColors(self: *Timeline, projection: *const @import("../vt/snapshot.zig").Projection) ![]ColorRun {
        var runs: std.ArrayList(ColorRun) = .empty;
        defer runs.deinit(self.allocator);
        var offset: u32 = 0;
        for (projection.visible_rows, 0..) |row, index| {
            const cells = projection.cells[row.cell_start..][0..row.cell_count];
            var end = cells.len;
            while (end > 0 and cells[end - 1].grapheme_len == 0 and cells[end - 1].attributes == 0 and cells[end - 1].background == .default and cells[end - 1].underline == 0 and !projection.modes.reverse_colors) end -= 1;
            for (cells[0..end]) |cell| {
                if (cell.width == .wide_tail) continue;
                var style = cell;
                style.grapheme_start = 0;
                style.grapheme_len = 0;
                style.width = .single;
                style.semantic = 0;
                const start = offset;
                offset += @max(1, cell.grapheme_len);
                if (runs.items.len > 0) {
                    const last = &runs.items[runs.items.len - 1];
                    if (last.end == start and last.kind == row.application_kind and std.meta.eql(last.cell, style)) {
                        last.end = offset;
                        continue;
                    }
                }
                try runs.append(self.allocator, .{ .start = start, .end = offset, .cell = style, .kind = row.application_kind });
            }
            if (index + 1 < projection.visible_rows.len) offset += 1;
        }
        return runs.toOwnedSlice(self.allocator);
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

test "timeline projected history coalesces styles and ignores cursor-only duplicates" {
    const a = std.testing.allocator;
    var adapter = try @import("../vt/ghostty_adapter.zig").Adapter.init(a, 20, 80);
    defer adapter.destroy();
    _ = try adapter.feed("\x1b[31m" ++ "abcdefg abcdefg abcdefg abcdefg abcdefg abcdefg abcdefg abcdefg abcdefg " ++ "\x1b[0m\r\nplain text");
    var projection = try adapter.copyProjection(a);
    defer projection.deinit(a);
    var timeline = Timeline.init(a, 1024 * 1024);
    defer timeline.deinit();
    try std.testing.expect(try timeline.appendProjectionChanged(100, &projection));
    const wire = text_frame.decode(timeline.latest().?.wire).?;
    try std.testing.expectEqual(@as(usize, 2), wire.spans.len);
    try std.testing.expect(timeline.latest().?.wire.len < 256);
    projection.cursor.col = 0;
    try std.testing.expect(!try timeline.appendProjectionChanged(200, &projection));
    try std.testing.expectEqual(@as(usize, 1), timeline.frames.items.len);
}

test "timeline rejects an optional full index larger than the history budget" {
    const a = std.testing.allocator;
    var timeline = Timeline.init(a, 256);
    defer timeline.deinit();
    var wire: [text_frame.header_bytes + 1]u8 = undefined;
    text_frame.encodeHeader(wire[0..text_frame.header_bytes], .{}, 1, 1, 0, 1);
    wire[text_frame.header_bytes] = 'a';
    try timeline.append(1, &wire);
    const search = @import("../vt/search_snapshot.zig");
    const document = search.Document{ .source_version = 1, .alternate_screen = false, .text = try a.alloc(u8, 512), .rows = try a.alloc(search.Row, 0), .spans = try a.alloc(search.Span, 0) };
    try std.testing.expect(!timeline.canAttachSearch(document));
    timeline.attachSearch(document);
    try std.testing.expect(timeline.latest().?.search == null);
    try std.testing.expectEqual(wire.len, timeline.bytes);
    try std.testing.expectEqualStrings("a", text_frame.decode(timeline.latest().?.wire).?.text);
}

test "timeline owns page-backed search copies through eviction and teardown" {
    const a = std.testing.allocator;
    const pages = std.heap.page_allocator;
    const search = @import("../vt/search_snapshot.zig");
    var timeline = Timeline.init(a, 64);
    defer timeline.deinit();
    var wire: [text_frame.header_bytes + 1]u8 = undefined;
    text_frame.encodeHeader(wire[0..text_frame.header_bytes], .{}, 1, 1, 0, 1);
    wire[text_frame.header_bytes] = 'a';
    for (0..2) |i| {
        try timeline.append(@intCast(i), &wire);
        timeline.attachSearchWithAllocator(.{ .source_version = i + 1, .alternate_screen = false, .text = try pages.dupe(u8, "12345678901234567890123456789012"), .rows = try pages.alloc(search.Row, 0), .spans = try pages.alloc(search.Span, 0) }, pages);
    }
    try std.testing.expectEqual(@as(usize, 1), timeline.frames.items.len);
    try std.testing.expectEqual(@as(u64, 2), timeline.latest().?.search.?.source_version);
}

test "timeline projected styles preserve inverse top header and literal colors" {
    const a = std.testing.allocator;
    var adapter = try @import("../vt/ghostty_adapter.zig").Adapter.init(a, 2, 12);
    defer adapter.destroy();
    _ = try adapter.feed("\x1b[7mPID USER\x1b[0m\r\n\x1b[38;2;0;0;0;48;2;255;255;255mX");
    var projection = try adapter.copyProjection(a);
    defer projection.deinit(a);
    var timeline = Timeline.init(a, 1024 * 1024);
    defer timeline.deinit();
    try timeline.appendProjection(100, &projection);
    const wire = text_frame.decode(timeline.latest().?.wire).?;
    try std.testing.expectEqual(@as(usize, 2), wire.spans.len);
    try std.testing.expectEqual((@as(u32, projection.colors.background) << 8) | 255, wire.spans[0].color);
    try std.testing.expectEqual((@as(u32, projection.colors.foreground) << 8) | 255, wire.spans[0].bg);
    try std.testing.expectEqual(@as(u32, 0x000000ff), wire.spans[1].color);
    try std.testing.expectEqual(@as(u32, 0xffffffff), wire.spans[1].bg);
    projection.modes.reverse_colors = true;
    try timeline.appendProjection(200, &projection);
    const reversed = text_frame.decode(timeline.latest().?.wire).?;
    // Cell inverse and screen inverse cancel for the header.
    try std.testing.expectEqual(@as(u32, 0), reversed.spans[0].start);
    try std.testing.expectEqual((@as(u32, projection.colors.foreground) << 8) | 255, reversed.spans[0].color);
    try std.testing.expectEqual((@as(u32, projection.colors.background) << 8) | 255, reversed.spans[0].bg);
}
