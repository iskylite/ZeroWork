//! Read-only model for the persistent closed-session history list.
//!
//! The history modal must never render design-time sample rows.  This model
//! loads the RawStreamTap index and exposes only records that actually exist
//! on disk; replay/export callers receive the indexed cast path verbatim.
const std = @import("std");
const Archive = @import("../vt/session_archive.zig").Archive;
const Entry = @import("../vt/session_archive.zig").Entry;

/// Saved IDs survive rename and distinguish assets with the same name.
pub const SourceFilter = union(enum) {
    saved_connection: u64,
    local,

    fn matches(self: SourceFilter, entry: Entry) bool {
        return switch (self) {
            .saved_connection => |id| entry.source_kind == .ssh and entry.saved_connection_id == id,
            .local => entry.source_kind == .local,
        };
    }
};

pub const Model = struct {
    allocator: std.mem.Allocator,
    archive: *Archive,
    entries: std.ArrayList(Entry) = .empty,
    source_filter: ?SourceFilter = null,

    pub fn init(allocator: std.mem.Allocator, archive: *Archive) Model {
        return .{ .allocator = allocator, .archive = archive };
    }

    pub fn deinit(self: *Model) void {
        self.archive.freeEntries(&self.entries);
        self.source_filter = null;
    }

    /// Legacy rows remain available in the unfiltered list, but cannot be
    /// attributed to any saved asset or Local source by their display names.
    pub fn refresh(self: *Model, source: ?SourceFilter) !void {
        var loaded = try self.archive.load(self.allocator);
        errdefer self.archive.freeEntries(&loaded);
        var next_entries: std.ArrayList(Entry) = .empty;
        errdefer next_entries.deinit(self.allocator);
        // Finish allocations before moving string ownership out of loaded.
        try next_entries.ensureTotalCapacity(self.allocator, loaded.items.len);
        for (loaded.items) |entry| {
            if (source) |filter| if (!filter.matches(entry)) {
                self.allocator.free(entry.host);
                self.allocator.free(entry.user);
                self.allocator.free(entry.cast_path);
                continue;
            };
            next_entries.appendAssumeCapacity(entry);
        }
        // `load` owns each string; ownership moved to self.entries above.
        loaded.items.len = 0;
        loaded.deinit(self.allocator);
        self.archive.freeEntries(&self.entries);
        self.source_filter = source;
        self.entries = next_entries;
        std.sort.heap(Entry, self.entries.items, {}, lessRecent);
    }

    fn lessRecent(_: void, a: Entry, b: Entry) bool {
        if (a.ended_ms != b.ended_ms) return a.ended_ms > b.ended_ms;
        return a.id > b.id;
    }

    pub fn len(self: *const Model) usize {
        return self.entries.items.len;
    }
    pub fn at(self: *const Model, index: usize) ?Entry {
        return if (index < self.entries.items.len) self.entries.items[index] else null;
    }

    /// Returns a real recording path for replay.  Missing files are rejected
    /// so a stale index cannot produce a fake/empty history row.
    pub fn replayPath(self: *const Model, index: usize) ![]const u8 {
        const entry = self.at(index) orelse return error.InvalidHistoryIndex;
        var file = try self.archive.dir.openFile(self.archive.io, entry.cast_path, .{});
        file.close(self.archive.io);
        return entry.cast_path;
    }

    /// Export uses the same durable cast path; the caller performs the native
    /// save dialog/copy and may choose txt conversion separately.
    pub fn exportPath(self: *const Model, index: usize) ![]const u8 {
        return self.replayPath(index);
    }
};

test "history list loads real index, filters stable source, and orders newest first" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var archive = Archive{ .allocator = std.testing.allocator, .io = std.testing.io, .dir = tmp.dir };
    try archive.append(.{ .id = 1, .started_ms = 0, .ended_ms = 10, .duration_ms = 10, .host = "old", .user = "u", .cast_path = "logs/history/old.cast" });
    try archive.append(.{ .id = 2, .started_ms = 20, .ended_ms = 30, .duration_ms = 10, .host = "same name", .user = "u", .cast_path = "logs/history/new.cast", .exit_code = 1, .source_kind = .ssh, .saved_connection_id = 7 });
    try archive.append(.{ .id = 3, .started_ms = 40, .ended_ms = 50, .duration_ms = 10, .host = "renamed", .user = "u", .cast_path = "logs/history/latest.cast", .source_kind = .ssh, .saved_connection_id = 7 });
    try tmp.dir.createDirPath(std.testing.io, "logs/history");
    for ([_][]const u8{ "old.cast", "new.cast", "latest.cast" }) |name| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "logs/history/{s}", .{name});
        defer std.testing.allocator.free(path);
        var f = try tmp.dir.createFile(std.testing.io, path, .{});
        f.close(std.testing.io);
    }
    var model = Model.init(std.testing.allocator, &archive);
    defer model.deinit();
    try model.refresh(.{ .saved_connection = 7 });
    try std.testing.expectEqual(@as(usize, 2), model.len());
    try std.testing.expectEqual(@as(u64, 3), model.at(0).?.id);
    try std.testing.expectEqualStrings("logs/history/latest.cast", try model.replayPath(0));
    try std.testing.expectError(error.InvalidHistoryIndex, model.replayPath(9));
    try model.refresh(null);
    try std.testing.expectEqual(@as(usize, 3), model.len());
    try std.testing.expectEqual(@as(u64, 3), model.at(0).?.id);
}

test "history list rejects stale cast path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var archive = Archive{ .allocator = std.testing.allocator, .io = std.testing.io, .dir = tmp.dir };
    try archive.append(.{ .id = 1, .started_ms = 0, .ended_ms = 1, .duration_ms = 1, .host = "h", .user = "u", .cast_path = "logs/history/missing.cast" });
    var model = Model.init(std.testing.allocator, &archive);
    defer model.deinit();
    try model.refresh(null);
    try std.testing.expectError(error.FileNotFound, model.replayPath(0));
}

test "history refresh accepts its own filter and survives allocation failures" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var archive = Archive{ .allocator = std.testing.allocator, .io = std.testing.io, .dir = tmp.dir };
    try archive.append(.{ .id = 1, .started_ms = 0, .ended_ms = 1, .duration_ms = 1, .host = "target", .user = "u", .cast_path = "logs/history/a.cast", .source_kind = .ssh, .saved_connection_id = 7 });
    try std.testing.checkAllAllocationFailures(std.testing.allocator, refreshWithAllocator, .{&archive});
}

fn refreshWithAllocator(allocator: std.mem.Allocator, source: *Archive) !void {
    var archive = source.*;
    archive.allocator = allocator;
    var model = Model.init(allocator, &archive);
    defer model.deinit();
    try model.refresh(.{ .saved_connection = 7 });
    model.refresh(model.source_filter) catch |err| {
        try std.testing.expectEqual(@as(u64, 7), model.source_filter.?.saved_connection);
        try std.testing.expectEqual(@as(usize, 1), model.len());
        return err;
    };
    try std.testing.expectEqual(@as(u64, 7), model.source_filter.?.saved_connection);
    try std.testing.expectEqual(@as(usize, 1), model.len());
}

test "history stable identity isolates duplicate names, renamed assets, Local and legacy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var archive = Archive{ .allocator = std.testing.allocator, .io = std.testing.io, .dir = tmp.dir };
    const sources = [_]Entry{
        .{ .id = 1, .started_ms = 1, .ended_ms = 2, .duration_ms = 1, .host = "duplicate", .user = "u", .cast_path = "logs/history/1.cast", .source_kind = .ssh, .saved_connection_id = 10 },
        .{ .id = 2, .started_ms = 2, .ended_ms = 3, .duration_ms = 1, .host = "duplicate", .user = "u", .cast_path = "logs/history/2.cast", .source_kind = .ssh, .saved_connection_id = 20 },
        .{ .id = 3, .started_ms = 3, .ended_ms = 4, .duration_ms = 1, .host = "renamed", .user = "u", .cast_path = "logs/history/3.cast", .source_kind = .ssh, .saved_connection_id = 10 },
        .{ .id = 4, .started_ms = 4, .ended_ms = 5, .duration_ms = 1, .host = "duplicate", .user = "u", .cast_path = "logs/history/4.cast", .source_kind = .local },
        .{ .id = 5, .started_ms = 5, .ended_ms = 6, .duration_ms = 1, .host = "duplicate", .user = "u", .cast_path = "logs/history/5.cast" },
        .{ .id = 6, .started_ms = 6, .ended_ms = 7, .duration_ms = 1, .host = "duplicate", .user = "u", .cast_path = "logs/history/6.cast", .source_kind = .ssh },
    };
    for (sources) |entry| try archive.append(entry);
    var model = Model.init(std.testing.allocator, &archive);
    defer model.deinit();
    try model.refresh(.{ .saved_connection = 10 });
    try std.testing.expectEqual(@as(usize, 2), model.len());
    try std.testing.expectEqual(@as(u64, 3), model.at(0).?.id);
    try std.testing.expectEqual(@as(u64, 1), model.at(1).?.id);
    try model.refresh(.{ .saved_connection = 20 });
    try std.testing.expectEqual(@as(usize, 1), model.len());
    try std.testing.expectEqual(@as(u64, 2), model.at(0).?.id);
    try model.refresh(.local);
    try std.testing.expectEqual(@as(usize, 1), model.len());
    try std.testing.expectEqual(@as(u64, 4), model.at(0).?.id);
    try model.refresh(null);
    try std.testing.expectEqual(@as(usize, sources.len), model.len());
}
