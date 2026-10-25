const std = @import("std");
const raw_stream_tap = @import("raw_stream_tap.zig");

/// Bounded, allocator-owned stream timeline used by @log/export surfaces.
pub const Timeline = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(Event) = .empty,
    max_events: usize,
    max_bytes: usize,
    bytes: usize = 0,
    mutex: std.atomic.Mutex = .unlocked,

    pub const Event = struct {
        timestamp_ms: i64,
        stream_offset: u64,
        payload: []u8,
        kind: enum { output, resize, application } = .output,
    };

    pub fn init(allocator: std.mem.Allocator, max_events: usize, max_bytes: usize) !Timeline {
        if (max_events == 0 or max_bytes == 0) return error.InvalidLimit;
        return .{ .allocator = allocator, .max_events = max_events, .max_bytes = max_bytes };
    }

    pub fn deinit(self: *Timeline) void {
        for (self.events.items) |event| {
            @memset(event.payload, 0);
            self.allocator.free(event.payload);
        }
        self.events.deinit(self.allocator);
        self.* = undefined;
    }

    /// Appends one received stream segment, evicting oldest segments as needed.
    pub fn append(self: *Timeline, timestamp_ms: i64, stream_offset: u64, payload: []const u8) !void {
        self.lock();
        defer self.mutex.unlock();
        if (payload.len > self.max_bytes) return error.EventTooLarge;
        while (self.events.items.len >= self.max_events or self.bytes + payload.len > self.max_bytes) {
            self.evictOldest();
        }
        const owned = try self.allocator.dupe(u8, payload);
        errdefer self.allocator.free(owned);
        try self.events.append(self.allocator, .{ .timestamp_ms = timestamp_ms, .stream_offset = stream_offset, .payload = owned });
        self.bytes += owned.len;
    }

    pub fn appendApplication(self: *Timeline, record: @import("../host/terminal_service.zig").ApplicationRecord, stream_offset: u64) !void {
        return self.appendApplicationAt(record, stream_offset, record.timestamp_ms);
    }
    pub fn appendApplicationAt(self: *Timeline, record: @import("../host/terminal_service.zig").ApplicationRecord, stream_offset: u64, event_ms: i64) !void {
        const payload = try std.json.Stringify.valueAlloc(self.allocator, record, .{});
        errdefer self.allocator.free(payload);
        self.lock();
        defer self.mutex.unlock();
        if (payload.len > self.max_bytes) return error.EventTooLarge;
        while (self.events.items.len >= self.max_events or self.bytes + payload.len > self.max_bytes) self.evictOldest();
        try self.events.append(self.allocator, .{ .timestamp_ms = event_ms, .stream_offset = stream_offset, .payload = payload, .kind = .application });
        self.bytes += payload.len;
    }

    pub fn appendTap(self: *Timeline, tap: *const raw_stream_tap.Tap, timestamp_ms: i64) !void {
        const payload = try self.allocator.alloc(u8, tap.len);
        defer self.allocator.free(payload);
        _ = try tap.snapshot(payload);
        try self.append(timestamp_ms, tap.sequence -| tap.len, payload);
    }

    /// Only successful transport/VT geometry changes become cast resize
    /// events; requested or rejected revisions never enter the recording.
    pub fn appendResize(self: *Timeline, timestamp_ms: i64, stream_offset: u64, cols: u16, rows: u16) !void {
        if (cols == 0 or rows == 0) return error.InvalidGeometry;
        var buffer: [32]u8 = undefined;
        const bytes = try std.fmt.bufPrint(&buffer, "{d}x{d}", .{ cols, rows });
        self.lock();
        defer self.mutex.unlock();
        if (bytes.len > self.max_bytes) return error.EventTooLarge;
        while (self.events.items.len >= self.max_events or self.bytes + bytes.len > self.max_bytes) self.evictOldest();
        const owned = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(owned);
        try self.events.append(self.allocator, .{ .timestamp_ms = timestamp_ms, .stream_offset = stream_offset, .payload = owned, .kind = .resize });
        self.bytes += owned.len;
    }

    pub fn eventCount(self: *const Timeline) usize {
        return self.events.items.len;
    }

    /// Exports a stable line-oriented representation. Payload bytes are escaped so
    /// terminal control sequences cannot alter a saved @log transcript.
    pub fn exportText(self: *Timeline, writer: *std.Io.Writer) !void {
        self.lock();
        defer self.mutex.unlock();
        try self.exportTextUnlocked(writer);
    }

    fn exportTextUnlocked(self: *const Timeline, writer: *std.Io.Writer) !void {
        for (self.events.items) |event| {
            if (event.kind == .application) {
                const value = try std.json.parseFromSlice(@import("../host/terminal_service.zig").ApplicationRecord, self.allocator, event.payload, .{});
                defer value.deinit();
                try writer.print("[{d}] ZeroWork #{d} {s}\n{s}\n", .{ event.timestamp_ms, value.value.id, value.value.command, value.value.output });
                continue;
            }
            try writer.print("[{d}] offset={d} ", .{ event.timestamp_ms, event.stream_offset });
            for (event.payload) |byte| {
                switch (byte) {
                    '\n' => try writer.writeAll("\\n"),
                    '\r' => try writer.writeAll("\\r"),
                    '\t' => try writer.writeAll("\\t"),
                    '\\' => try writer.writeAll("\\\\"),
                    0...8, 11...12, 14...31, 127...255 => try writer.print("\\x{x:0>2}", .{byte}),
                    else => try writer.writeByte(byte),
                }
            }
            try writer.writeByte('\n');
        }
    }

    /// Exports asciicast v2 events using stream-relative seconds.
    pub fn exportCast(self: *Timeline, writer: *std.Io.Writer, cols: u16, rows: u16) !void {
        self.lock();
        defer self.mutex.unlock();
        try writer.print("{{\"version\":2,\"width\":{d},\"height\":{d}}}\n", .{ cols, rows });
        const origin = if (self.events.items.len == 0) 0 else self.events.items[0].timestamp_ms;
        // PTY reads may split a UTF-8 scalar. Keep its prefix across events so
        // JSON contains Unicode text, rather than Latin-1 escapes of UTF-8 bytes.
        var pending: [4]u8 = undefined;
        var pending_len: usize = 0;
        var expected: usize = 0;
        var previous_ms: i64 = origin;
        for (self.events.items, 0..) |event, index| {
            const monotonic_ms = @max(previous_ms, event.timestamp_ms);
            previous_ms = monotonic_ms;
            const elapsed = @as(f64, @floatFromInt(monotonic_ms - origin)) / 1000.0;
            if (event.kind == .application) {
                try writer.print("[{d:.3},\"a\",", .{elapsed});
                try std.json.Stringify.value(event.payload, .{}, writer);
                try writer.writeAll("]\n");
                continue;
            }
            if (event.kind == .resize) {
                try writer.print("[{d:.3},\"r\",\"{s}\"]\n", .{ elapsed, event.payload });
                continue;
            }
            try writer.print("[{d:.3},\"o\",\"", .{elapsed});
            for (event.payload) |byte| {
                if (pending_len > 0) {
                    if (byte & 0xc0 == 0x80) {
                        pending[pending_len] = byte;
                        pending_len += 1;
                        if (pending_len == expected) {
                            if (std.unicode.utf8ValidateSlice(pending[0..pending_len]))
                                try writer.writeAll(pending[0..pending_len])
                            else
                                try writer.writeAll("\xef\xbf\xbd");
                            pending_len = 0;
                        }
                        continue;
                    }
                    try writer.writeAll("\xef\xbf\xbd");
                    pending_len = 0;
                }
                if (byte >= 0x80) {
                    expected = std.unicode.utf8ByteSequenceLength(byte) catch {
                        try writer.writeAll("\xef\xbf\xbd");
                        continue;
                    };
                    pending[0] = byte;
                    pending_len = 1;
                    continue;
                }
                switch (byte) {
                    '\n' => try writer.writeAll("\\n"),
                    '\r' => try writer.writeAll("\\r"),
                    '\t' => try writer.writeAll("\\t"),
                    '\\' => try writer.writeAll("\\\\"),
                    '"' => try writer.writeAll("\\\""),
                    0...8, 11...12, 14...31, 127 => try writer.print("\\u00{x:0>2}", .{byte}),
                    else => try writer.writeByte(byte),
                }
            }
            if (index + 1 == self.events.items.len and pending_len > 0)
                try writer.writeAll("\xef\xbf\xbd");
            try writer.writeAll("\"]\n");
        }
    }

    pub fn saveCast(self: *Timeline, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, cols: u16, rows: u16) !void {
        var atomic_buffer: [16 * 1024]u8 = undefined;
        var atomic = try dir.createFileAtomic(io, sub_path, .{
            .permissions = @as(std.Io.File.Permissions, @fromBackingInt(@intCast(0o600))),
            .make_path = true,
            .replace = true,
        });
        defer atomic.deinit(io);
        var writer = atomic.file.writer(io, &atomic_buffer);
        try self.exportCast(&writer.interface, cols, rows);
        try writer.flush();
        try atomic.replace(io);
    }

    /// Atomically persists the current transcript with owner-only permissions.
    pub fn save(self: *Timeline, io: std.Io, dir: std.Io.Dir, sub_path: []const u8) !void {
        self.lock();
        defer self.mutex.unlock();
        var atomic_buffer: [16 * 1024]u8 = undefined;
        var atomic = try dir.createFileAtomic(io, sub_path, .{
            .permissions = @as(std.Io.File.Permissions, @fromBackingInt(@intCast(0o600))),
            .make_path = true,
            .replace = true,
        });
        defer atomic.deinit(io);
        var writer = atomic.file.writer(io, &atomic_buffer);
        try self.exportTextUnlocked(&writer.interface);
        try writer.flush();
        try atomic.replace(io);
    }

    fn lock(self: *Timeline) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn evictOldest(self: *Timeline) void {
        if (self.events.items.len == 0) return;
        const event = self.events.orderedRemove(0);
        self.bytes -= event.payload.len;
        @memset(event.payload, 0);
        self.allocator.free(event.payload);
    }
};

test "timeline is bounded and evicts oldest stream segments" {
    var timeline = try Timeline.init(std.testing.allocator, 2, 5);
    defer timeline.deinit();
    try timeline.append(10, 0, "ab");
    try timeline.append(20, 2, "cd");
    try timeline.append(30, 4, "ef");
    try std.testing.expectEqual(@as(usize, 2), timeline.eventCount());
    try std.testing.expectEqual(@as(usize, 4), timeline.bytes);
    try std.testing.expectEqual(@as(i64, 20), timeline.events.items[0].timestamp_ms);
}

test "timeline export escapes control bytes" {
    var timeline = try Timeline.init(std.testing.allocator, 4, 64);
    defer timeline.deinit();
    try timeline.append(-1, 7, "ok\n\x1b");
    var output: [128]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&output);
    try timeline.exportText(&fixed);
    try std.testing.expectEqualStrings("[-1] offset=7 ok\\n\\x1b\n", fixed.buffer[0..fixed.end]);
}

test "timeline exports asciicast v2 header and relative events" {
    var timeline = try Timeline.init(std.testing.allocator, 4, 64);
    defer timeline.deinit();
    try timeline.append(1_000, 0, "hi\n");
    try timeline.append(1_250, 3, "ok");
    var output: [256]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&output);
    try timeline.exportCast(&fixed, 80, 24);
    try std.testing.expectEqualStrings("{\"version\":2,\"width\":80,\"height\":24}\n[0.000,\"o\",\"hi\\n\"]\n[0.250,\"o\",\"ok\"]\n", fixed.buffer[0..fixed.end]);
}

test "timeline captures bounded raw tap snapshot" {
    var tap = try raw_stream_tap.Tap.init(std.testing.allocator, 8);
    defer tap.deinit();
    tap.append("hello");
    var timeline = try Timeline.init(std.testing.allocator, 2, 16);
    defer timeline.deinit();
    try timeline.appendTap(&tap, 42);
    try std.testing.expectEqual(@as(usize, 1), timeline.eventCount());
    try std.testing.expectEqualStrings("hello", timeline.events.items[0].payload);
}

test "cast preserves Unicode split across reads and sanitizes invalid bytes" {
    var timeline = try Timeline.init(std.testing.allocator, 8, 64);
    defer timeline.deinit();
    try timeline.append(100, 0, "中\xe6");
    try timeline.append(90, 4, "\x96\x87\xff\x1b");
    var output: [512]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&output);
    try timeline.exportCast(&fixed, 120, 40);
    try std.testing.expectEqualStrings("{\"version\":2,\"width\":120,\"height\":40}\n[0.000,\"o\",\"中\"]\n[0.000,\"o\",\"文�\\u001b\"]\n", fixed.buffer[0..fixed.end]);
}

test "cast file export is private and parses as asciicast JSON lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var timeline = try Timeline.init(std.testing.allocator, 8, 64);
    defer timeline.deinit();
    try timeline.append(42, 0, "中文\n\x1b[31m");
    try timeline.saveCast(std.testing.io, tmp.dir, "out/session.cast", 132, 36);
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "out/session.cast", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(bytes);
    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    const header = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lines.next().?, .{});
    defer header.deinit();
    try std.testing.expectEqual(@as(i64, 132), header.value.object.get("width").?.integer);
    const event = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lines.next().?, .{});
    defer event.deinit();
    try std.testing.expectEqualStrings("中文\n\x1b[31m", event.value.array.items[2].string);
    var file = try tmp.dir.openFile(std.testing.io, "out/session.cast", .{});
    defer file.close(std.testing.io);
    const stat = try file.stat(std.testing.io);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
}
