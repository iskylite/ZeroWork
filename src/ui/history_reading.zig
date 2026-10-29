//! One frozen reading position shared by the wheel, track and search. Rows
//! shared by recorded frames are indexed once; changed row contents retain
//! their own real frame witness. No synthetic time interpolation is used.
const std = @import("std");
const Timeline = @import("history_replay.zig").Timeline;
const frame = @import("../vt/text_frame.zig");
const Search = @import("../vt/search_snapshot.zig");
pub const Anchor = struct {
    frame_index: usize,
    row: usize,
    start: usize,
    end: usize,
    y: f32 = 0,
    extent: f32 = 0,
    timestamp: ?i64,
    frame_time: i64,
    has_document: bool,
};
const Key = struct { id: [2]u64, text: u64, kind: u8, state: u8 };
pub const Position = struct { anchor: usize = 0, pixel: f32 = 0, frame_index: usize = 0, row: usize = 0, time_ms: ?i64 = null, frame_time: bool = false };
pub const Model = struct {
    allocator: std.mem.Allocator,
    anchors: std.ArrayList(Anchor) = .empty,
    text: std.ArrayList(u8) = .empty,
    offset: f32 = 0,
    maximum: f32 = 0,
    total: f32 = 0,
    viewport: f32 = 0,
    row_height: f32 = 0,
    position: Position = .{},
    legacy: bool = false,
    limit: usize = 128 * 1024 * 1024,
    pub fn init(allocator: std.mem.Allocator, timeline: *const Timeline) !Model {
        var self: Model = .{ .allocator = allocator, .limit = timeline.limit };
        errdefer self.deinit();
        const Witness = struct { frame_index: usize, first: usize, end: usize, has_document: bool, key: ?Key = null };
        var witnesses: std.ArrayList(Witness) = .empty;
        defer witnesses.deinit(allocator);
        var seen: std.AutoHashMap(Key, usize) = .init(allocator);
        defer seen.deinit();
        var previous_groups: std.ArrayList(usize) = .empty;
        defer previous_groups.deinit(allocator);
        var current_groups: std.ArrayList(usize) = .empty;
        defer current_groups.deinit(allocator);
        for (timeline.frames.items, 0..) |entry, frame_index| {
            current_groups.clearRetainingCapacity();
            const current_frame = frame.decode(entry.wire) orelse return error.InvalidFrame;
            const resized = if (frame_index > 0) blk: {
                const previous = frame.decode(timeline.frames.items[frame_index - 1].wire).?;
                break :blk previous.cols != current_frame.cols or previous.rows != current_frame.rows;
            } else false;
            if (entry.search) |document| {
                var retained_rows = document.rows.len;
                // Empty rows after the last recorded text are VT viewport
                // padding, rather than a scrollable blank recording tail.
                while (retained_rows > 0) {
                    const row = document.rows[retained_rows - 1];
                    if (row.start != row.end or row.application_kind != 0 or row.timestamp_ms != null) break;
                    retained_rows -= 1;
                }
                var first: usize = 0;
                var span_index: usize = 0;
                while (first < retained_rows) {
                    const row = document.rows[first];
                    var end = first + 1;
                    while (end < retained_rows and std.meta.eql(row.logical_id, document.rows[end].logical_id) and row.application_kind == document.rows[end].application_kind and row.application_state == document.rows[end].application_state) : (end += 1) {}
                    // Compare a whole logical line. A recorded grid resize may
                    // wrap that same text into a different number of rows.
                    const text_start = row.start;
                    const text_end = document.rows[end - 1].end;
                    var content = std.hash.Wyhash.init(0);
                    content.update(document.text[text_start..text_end]);
                    while (span_index < document.spans.len and document.spans[span_index].row < first) : (span_index += 1) {}
                    var style_run: ?Search.Span = null;
                    while (span_index < document.spans.len and document.spans[span_index].row < end) : (span_index += 1) {
                        const span = document.spans[span_index];
                        if (style_run) |*run| {
                            if (run.end == span.start and run.color == span.color and run.bg == span.bg and run.flags == span.flags) {
                                run.end = span.end;
                                continue;
                            }
                            std.hash.autoHash(&content, .{ run.start - text_start, run.end - text_start, run.color, run.bg, run.flags });
                        }
                        style_run = span;
                    }
                    if (style_run) |run| std.hash.autoHash(&content, .{ run.start - text_start, run.end - text_start, run.color, run.bg, run.flags });
                    const key: Key = .{ .id = row.logical_id, .text = content.final(), .kind = row.application_kind, .state = row.application_state };
                    const witness: Witness = .{ .frame_index = frame_index, .first = first, .end = end, .has_document = true, .key = key };
                    const witness_index = seen.get(key) orelse reflow: {
                        // Ghostty changes the row-identity epoch on resize.
                        // Match only the same ordered logical line from the
                        // immediately preceding frame when text and styles
                        // are unchanged; repeated equal lines stay distinct.
                        if (resized and current_groups.items.len < previous_groups.items.len) {
                            const previous_index = previous_groups.items[current_groups.items.len];
                            if (witnesses.items[previous_index].key) |old| if (old.text == key.text and old.kind == key.kind and old.state == key.state) {
                                try seen.put(key, previous_index);
                                break :reflow previous_index;
                            };
                        }
                        const index = witnesses.items.len;
                        try witnesses.append(allocator, witness);
                        try seen.put(key, index);
                        break :reflow index;
                    };
                    witnesses.items[witness_index] = witness;
                    try current_groups.append(allocator, witness_index);
                    first = end;
                }
            } else {
                self.legacy = true;
                const decoded = frame.decode(entry.wire) orelse return error.InvalidFrame;
                try witnesses.append(allocator, .{ .frame_index = frame_index, .first = 0, .end = decoded.rows, .has_document = false });
            }
            if (witnesses.items.len > timeline.limit / @sizeOf(Witness)) return error.HistoryRecordingTooLarge;
            const old_groups = previous_groups;
            previous_groups = current_groups;
            current_groups = old_groups;
        }
        for (witnesses.items) |witness| {
            const entry = timeline.frames.items[witness.frame_index];
            if (witness.has_document) {
                const document = entry.search.?;
                for (witness.first..witness.end) |row_index| {
                    const row = document.rows[row_index];
                    try self.append(witness.frame_index, row_index, document.text[row.start..row.end], row.timestamp_ms, entry.time_ms, true, row_index == witness.first);
                }
            } else {
                const decoded = frame.decode(entry.wire).?;
                var lines = std.mem.splitScalar(u8, decoded.text, '\n');
                var row_index: usize = 0;
                while (lines.next()) |text| : (row_index += 1) try self.append(witness.frame_index, row_index, text, if (row_index < entry.presentation.len) entry.presentation[row_index].timestamp else null, entry.time_ms, false, true);
            }
        }
        if (self.anchors.items.len == 0) return error.EmptyRecording;
        return self;
    }
    fn append(self: *Model, frame_index: usize, row: usize, text: []const u8, timestamp: ?i64, frame_time: i64, has_document: bool, separator: bool) !void {
        if (self.storageBytes() + text.len + @sizeOf(Anchor) + 1 > self.limit) return error.HistoryRecordingTooLarge;
        if (self.anchors.items.len > 0 and separator) try self.text.append(self.allocator, '\n');
        const actual_start = self.text.items.len;
        try self.text.appendSlice(self.allocator, text);
        try self.anchors.append(self.allocator, .{ .frame_index = frame_index, .row = row, .start = actual_start, .end = self.text.items.len, .timestamp = timestamp, .frame_time = frame_time, .has_document = has_document });
    }
    pub fn storageBytes(self: *const Model) usize {
        return self.anchors.items.len * @sizeOf(Anchor) + self.text.items.len;
    }
    pub fn deinit(self: *Model) void {
        self.anchors.deinit(self.allocator);
        self.text.deinit(self.allocator);
    }
    pub fn layout(self: *Model, timeline: *const Timeline, row_height: f32, viewport: f32) void {
        const was_end = self.offset >= self.maximum - 0.1;
        const old = self.position;
        var y: f32 = 0;
        for (self.anchors.items) |*anchor| {
            const entry = timeline.frames.items[anchor.frame_index];
            const extra = if (anchor.has_document) blk: {
                const row = entry.search.?.rows[anchor.row];
                break :blk row.presentation.before + row.presentation.after;
            } else if (anchor.row < entry.presentation.len) entry.presentation[anchor.row].layout.before + entry.presentation[anchor.row].layout.after else 0;
            anchor.y = y;
            anchor.extent = row_height + extra;
            if (!anchor.has_document) {
                const decoded = frame.decode(entry.wire).?;
                if (anchor.row + 1 >= decoded.rows) anchor.extent += @max(0, viewport - @as(f32, @floatFromInt(decoded.rows)) * row_height);
            }
            y += anchor.extent;
        }
        self.row_height = row_height;
        self.viewport = viewport;
        self.total = y;
        self.maximum = @max(0, y - viewport);
        if (was_end) self.offset = self.maximum else if (old.anchor < self.anchors.items.len) self.offset = @min(self.maximum, self.anchors.items[old.anchor].y + old.pixel);
        self.resolve();
    }
    pub fn seek(self: *Model, progress: f32) void {
        self.offset = self.maximum * std.math.clamp(progress, 0, 1);
        if (self.legacy and self.anchors.items.len > 0) {
            var nearest = self.anchors.items[0].y;
            for (self.anchors.items) |anchor| if (anchor.y <= self.maximum and @abs(anchor.y - self.offset) < @abs(nearest - self.offset)) {
                nearest = anchor.y;
            };
            self.offset = nearest;
        }
        self.resolve();
    }
    pub fn scroll(self: *Model, delta: f32) void {
        self.offset = std.math.clamp(self.offset + delta, 0, self.maximum);
        self.resolve();
    }
    pub fn fraction(self: *const Model) f32 {
        return if (self.maximum > 0) self.offset / self.maximum else 1;
    }
    pub fn locate(self: *Model, byte: usize) void {
        for (self.anchors.items) |anchor| if (byte >= anchor.start and (byte < anchor.end or anchor.start == anchor.end)) {
            self.offset = @min(self.maximum, anchor.y);
            self.resolve();
            return;
        };
    }
    fn resolve(self: *Model) void {
        if (self.anchors.items.len == 0) return;
        var low: usize = 0;
        var high = self.anchors.items.len;
        while (low + 1 < high) {
            const mid = low + (high - low) / 2;
            if (self.anchors.items[mid].y <= self.offset) low = mid else high = mid;
        }
        const anchor = self.anchors.items[low];
        self.position = .{ .anchor = low, .pixel = @max(0, self.offset - anchor.y), .frame_index = anchor.frame_index, .row = anchor.row, .time_ms = anchor.timestamp orelse anchor.frame_time, .frame_time = anchor.timestamp == null };
    }
};

test "history reading retains fractional wheel input and clamps a single reachable viewport" {
    var timeline = Timeline.init(std.testing.allocator, 4096);
    defer timeline.deinit();
    const text = "one\ntwo\nthree\nfour";
    var wire: [frame.header_bytes + text.len]u8 = undefined;
    frame.encodeHeader(wire[0..frame.header_bytes], .{}, 12, 4, 0, text.len);
    @memcpy(wire[frame.header_bytes..], text);
    try timeline.append(125, &wire);
    var reading = try Model.init(std.testing.allocator, &timeline);
    defer reading.deinit();
    reading.layout(&timeline, 22, 44);
    try std.testing.expectEqual(@as(f32, 1), reading.fraction());
    reading.scroll(-0.25);
    try std.testing.expectApproxEqAbs(@as(f32, 43.75), reading.offset, 0.001);
    reading.seek(0);
    try std.testing.expectEqual(@as(usize, 0), reading.position.row);
    try std.testing.expectEqual(@as(?i64, 125), reading.position.time_ms);
    reading.seek(1);
    try std.testing.expectEqual(@as(usize, 2), reading.position.row);
    reading.layout(&timeline, 22, 200);
    try std.testing.expectEqual(@as(f32, 0), reading.maximum);
    try std.testing.expectEqual(@as(f32, 1), reading.fraction());
}

test "history reading indexes shared row identity once and preserves changed row versions" {
    const a = std.testing.allocator;
    var timeline = Timeline.init(a, 8192);
    defer timeline.deinit();
    const source = [_][]const u8{ "old\nstable", "new\nstable" };
    for (source, 0..) |text, i| {
        const wire = try a.alloc(u8, frame.header_bytes + text.len);
        defer a.free(wire);
        frame.encodeHeader(wire[0..frame.header_bytes], .{}, 12, 2, 0, text.len);
        @memcpy(wire[frame.header_bytes..], text);
        try timeline.append(@intCast(i * 10), wire);
        const rows = try a.alloc(Search.Row, 2);
        rows[0] = .{ .id = .{ 1, 1 }, .logical_id = .{ 1, 1 }, .screen_row = 0, .start = 0, .end = 3 };
        rows[1] = .{ .id = .{ 1, 2 }, .logical_id = .{ 1, 2 }, .screen_row = 1, .start = 4, .end = 10, .timestamp_ms = 7 };
        timeline.frames.items[i].search = .{ .source_version = i + 1, .alternate_screen = false, .text = try a.dupe(u8, text), .rows = rows, .spans = try a.alloc(Search.Span, 0) };
    }
    var reading = try Model.init(a, &timeline);
    defer reading.deinit();
    try std.testing.expectEqual(@as(usize, 3), reading.anchors.items.len);
    try std.testing.expectEqualStrings("old\nstable\nnew", reading.text.items);
    try std.testing.expectEqual(@as(usize, 1), reading.anchors.items[1].frame_index);
    try std.testing.expectEqual(@as(?i64, 7), reading.anchors.items[1].timestamp);
    reading.layout(&timeline, 22, 22);
    reading.seek(0);
    try std.testing.expectEqual(@as(usize, 0), reading.position.frame_index);
    reading.locate(11);
    try std.testing.expectEqual(@as(usize, 1), reading.position.frame_index);
}

test "history short cast reading ignores unrecorded trailing VT padding" {
    var timeline = try @import("history_cast.zig").load(std.testing.allocator, "{\"version\":2,\"width\":80,\"height\":24}\n[0,\"o\",\"short recorded output\\r\\n\"]\n");
    defer timeline.deinit();
    var reading = try Model.init(std.testing.allocator, &timeline);
    defer reading.deinit();
    reading.layout(&timeline, 22, 120);
    try std.testing.expectEqual(@as(f32, 0), reading.maximum);
    try std.testing.expectEqual(@as(usize, 0), reading.position.row);
    try std.testing.expectEqualStrings("short recorded output", reading.text.items);
    try std.testing.expect(reading.position.frame_time);
}

test "history reading shares a logical line across recorded grid reflow" {
    var timeline = try @import("history_cast.zig").load(std.testing.allocator, "{\"version\":2,\"width\":8,\"height\":2}\n[0,\"o\",\"abcdefghijk\\r\\nsecond\\r\\nlast\"]\n[1,\"r\",\"13x3\"]\n");
    defer timeline.deinit();
    var reading = try Model.init(std.testing.allocator, &timeline);
    defer reading.deinit();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, reading.text.items, "abcdefghijk"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, reading.text.items, "second"));
    try std.testing.expect(std.mem.indexOf(u8, reading.text.items, "last") != null);
}
