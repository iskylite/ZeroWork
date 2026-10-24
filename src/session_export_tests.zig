const std = @import("std");
const Export = @import("ui/session_export.zig");
const Timeline = @import("vt/timeline.zig").Timeline;
const identity = @import("host/identity.zig");
const a = std.testing.allocator;

const owner: identity.ContentOwner = .{ .session = .{ .session_id = @fromBackingInt(31), .generation = 2 } };
const Sink = struct {
    timeline: *Timeline,
    dir: std.Io.Dir,
    capture: Export.SessionCapture = .{ .tab_id = @fromBackingInt(7), .owner = owner },
    current_tab: identity.TabId = @fromBackingInt(7),
    current_owner: identity.ContentOwner = owner,
    active_tab: identity.TabId = @fromBackingInt(7),
    validates: usize = 0,
    writes: usize = 0,
    fail: ?Export.Kind = null,
    invalidate_after_first: bool = false,
    pub fn validate(self: *Sink) !void {
        self.validates += 1;
        if (!self.capture.matches(self.current_tab, self.current_owner)) return error.StaleExportOwner;
    }
    pub fn write(self: *Sink, kind: Export.Kind, path: []const u8) !void {
        if (self.fail == kind) return error.InjectedExportFailure;
        switch (kind) {
            .txt => try self.timeline.save(std.testing.io, self.dir, path),
            .cast => try self.timeline.saveCast(std.testing.io, self.dir, path, 80, 24),
        }
        self.writes += 1;
        if (self.invalidate_after_first) self.current_owner = .{ .session = .{ .session_id = @fromBackingInt(31), .generation = 3 } };
    }
};

fn read(dir: std.Io.Dir, path: []const u8) ![]u8 {
    return dir.readFileAlloc(std.testing.io, path, a, .limited(1024 * 1024));
}

test "session export saved three formats choose matching default and actual live timeline files" {
    try std.testing.expectEqualStrings("session.txt", (try Export.Format.parse("txt")).defaultFilename());
    try std.testing.expectEqualStrings("session.cast", (try Export.Format.parse("cast")).defaultFilename());
    try std.testing.expectEqualStrings("session", (try Export.Format.parse("txt_cast")).defaultFilename());
    try std.testing.expectError(error.InvalidExportFormat, Export.Format.parse("html"));
    for ([_]Export.Format{ .txt, .cast, .txt_cast }) |format| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var timeline = try Timeline.init(a, 8, 1024);
        defer timeline.deinit();
        try timeline.append(1000, 0, "original-session\r\n");
        var sink: Sink = .{ .timeline = &timeline, .dir = tmp.dir };
        // A typed known suffix is normalized to the saved setting. Both
        // outputs share the same user-selected stem and private atomic writer.
        try std.testing.expect(try Export.run(a, format, "capture.CAST", &sink));
        if (format != .cast) {
            const text = try read(tmp.dir, "capture.txt");
            defer a.free(text);
            try std.testing.expect(std.mem.indexOf(u8, text, "original-session") != null);
            try std.testing.expect(std.mem.startsWith(u8, text, "[1000] offset=0 "));
        } else try std.testing.expectError(error.FileNotFound, read(tmp.dir, "capture.txt"));
        if (format != .txt) {
            const cast = try read(tmp.dir, "capture.cast");
            defer a.free(cast);
            try std.testing.expect(std.mem.startsWith(u8, cast, "{\"version\":2,\"width\":80,\"height\":24}"));
            try std.testing.expect(std.mem.indexOf(u8, cast, "original-session") != null);
        } else try std.testing.expectError(error.FileNotFound, read(tmp.dir, "capture.cast"));
        try std.testing.expectEqual(@as(usize, if (format == .txt_cast) 2 else 1), sink.writes);
    }
}

test "session export cancel writes nothing and paired failure never returns success or truncates old second file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var timeline = try Timeline.init(a, 8, 1024);
    defer timeline.deinit();
    try timeline.append(10, 0, "new-session");
    try @import("ui/terminal_export.zig").writeSnapshot(std.testing.io, tmp.dir, "capture.cast", "old-cast-kept");
    var sink: Sink = .{ .timeline = &timeline, .dir = tmp.dir };
    for ([_]Export.Format{ .txt, .cast, .txt_cast }) |format| try std.testing.expect(!try Export.run(a, format, null, &sink));
    try std.testing.expectEqual(@as(usize, 0), sink.validates);
    try std.testing.expectEqual(@as(usize, 0), sink.writes);
    try std.testing.expectError(error.FileNotFound, read(tmp.dir, "capture.txt"));
    sink.fail = .cast;
    try std.testing.expectError(error.InjectedExportFailure, Export.run(a, .txt_cast, "capture", &sink));
    try std.testing.expectEqual(@as(usize, 1), sink.writes);
    const old = try read(tmp.dir, "capture.cast");
    defer a.free(old);
    try std.testing.expectEqualStrings("old-cast-kept", old);
    const first = try read(tmp.dir, "capture.txt");
    defer a.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "new-session") != null);
}

test "session export captured owner survives active switch and rejects generation or owner changes before each file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var timeline = try Timeline.init(a, 8, 1024);
    defer timeline.deinit();
    try timeline.append(10, 0, "captured-owner-only");
    var sink: Sink = .{ .timeline = &timeline, .dir = tmp.dir };
    sink.active_tab = @fromBackingInt(99);
    try std.testing.expect(try Export.run(a, .cast, "original", &sink));
    const original = try read(tmp.dir, "original.cast");
    defer a.free(original);
    try std.testing.expect(std.mem.indexOf(u8, original, "captured-owner-only") != null);
    sink.current_owner = .{ .session = .{ .session_id = @fromBackingInt(99), .generation = 2 } };
    try std.testing.expectError(error.StaleExportOwner, Export.run(a, .txt_cast, "wrong-owner", &sink));
    try std.testing.expectError(error.FileNotFound, read(tmp.dir, "wrong-owner.txt"));
    sink.current_owner = owner;
    sink.invalidate_after_first = true;
    try std.testing.expectError(error.StaleExportOwner, Export.run(a, .txt_cast, "generation", &sink));
    try std.testing.expectError(error.FileNotFound, read(tmp.dir, "generation.cast"));
    try std.testing.expect(!sink.capture.matches(@fromBackingInt(8), owner));
}

const cast_recording =
    "{\"version\":2,\"width\":32,\"height\":2}\n" ++
    "[0,\"o\",\"\\u001b[31m早期中文\\u001b[0m\\r\\nsecond\\r\\nthird\\r\\n\"]\n" ++
    "[1,\"i\",\"not-output\"]\n" ++
    "[2,\"o\",\"temp\\r\\u001b[2K末尾文\\r\\n\\u001b]0;not-title-text\\u0007\"]\n";

test "session export archive conversion interprets real VT UTF8 controls and retained scrollback" {
    const text = try Export.castText(a, cast_recording);
    defer a.free(text);
    try std.testing.expect(std.unicode.utf8ValidateSlice(text));
    for ([_][]const u8{ "早期中文", "second", "third", "末尾文" }) |expected| try std.testing.expect(std.mem.indexOf(u8, text, expected) != null);
    for ([_][]const u8{ "\x1b", "temp", "not-output", "not-title-text", "[31m" }) |excluded| try std.testing.expect(std.mem.indexOf(u8, text, excluded) == null);
    try std.testing.expectError(error.InvalidCast, Export.castText(a, "{\"version\":2,\"width\":0,\"height\":2}\n"));
    try std.testing.expectError(error.EmptyRecording, Export.castText(a, "{\"version\":2,\"width\":12,\"height\":2}\n"));
}

const ArchiveSink = struct {
    dir: std.Io.Dir,
    capture: Export.ArchiveCapture = .{ .id = 9, .cast_path = "history/original.cast" },
    current: @import("vt/session_archive.zig").Entry = .{ .id = 9, .ended_ms = 10, .started_ms = 1, .host = "original", .user = "root", .cast_path = "history/original.cast", .duration_ms = 9 },
    pub fn validate(self: *ArchiveSink) !void {
        if (!self.capture.matches(self.current)) return error.StaleExportOwner;
    }
    pub fn write(self: *ArchiveSink, kind: Export.Kind, path: []const u8) !void {
        try Export.writeArchive(a, std.testing.io, self.dir, kind, path, cast_recording);
    }
};

test "session export archive three formats preserve exact cast and reject stale recording identity" {
    for ([_]Export.Format{ .txt, .cast, .txt_cast }) |format| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var sink: ArchiveSink = .{ .dir = tmp.dir };
        try std.testing.expect(try Export.run(a, format, "history-export.txt", &sink));
        if (format != .cast) {
            const text = try read(tmp.dir, "history-export.txt");
            defer a.free(text);
            try std.testing.expect(std.mem.indexOf(u8, text, "早期中文") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "末尾文") != null);
        } else try std.testing.expectError(error.FileNotFound, read(tmp.dir, "history-export.txt"));
        if (format != .txt) {
            const cast = try read(tmp.dir, "history-export.cast");
            defer a.free(cast);
            try std.testing.expectEqualStrings(cast_recording, cast);
        } else try std.testing.expectError(error.FileNotFound, read(tmp.dir, "history-export.cast"));
        sink.current.id = 10;
        try std.testing.expectError(error.StaleExportOwner, Export.run(a, .cast, "other-recording", &sink));
        try std.testing.expectError(error.FileNotFound, read(tmp.dir, "other-recording.cast"));
        sink.current.id = 9;
        sink.current.cast_path = "history/replaced.cast";
        try std.testing.expectError(error.StaleExportOwner, Export.run(a, .txt, "replaced", &sink));
    }
}

test "session export archive atomic write failure preserves destination" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try @import("ui/terminal_export.zig").writeSnapshot(std.testing.io, tmp.dir, "keep.txt", "preserved");
    try std.testing.expectError(error.InvalidCast, Export.writeArchive(a, std.testing.io, tmp.dir, .txt, "keep.txt", "{\"version\":9}\n"));
    const kept = try read(tmp.dir, "keep.txt");
    defer a.free(kept);
    try std.testing.expectEqualStrings("preserved", kept);
    try std.testing.expectError(error.FileNotFound, Export.writeArchive(a, std.testing.io, tmp.dir, .cast, "absent/capture.cast", cast_recording));
}
