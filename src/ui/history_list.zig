//! Metadata-only catalogue projection. A list refresh never decodes recordings.
const std = @import("std");
const archive_mod = @import("../vt/session_archive.zig");
const Archive = archive_mod.Archive;
const Entry = archive_mod.Entry;
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
pub const TypeFilter = enum { all, ssh, local };
pub const page_size = 100;
pub const Model = struct {
    allocator: std.mem.Allocator,
    archive: *Archive,
    catalog: ?archive_mod.Catalog = null,
    // Shallow entry projections; the catalogue arena owns all strings.
    entries: std.ArrayList(Entry) = .empty,
    visible: std.ArrayList(usize) = .empty,
    source_filter: ?SourceFilter = null,
    type_filter: TypeFilter = .all,
    query: std.ArrayList(u8) = .empty,
    page: usize = 0,
    pub fn init(allocator: std.mem.Allocator, archive: *Archive) Model {
        return .{ .allocator = allocator, .archive = archive };
    }
    pub fn deinit(self: *Model) void {
        self.entries.deinit(self.allocator);
        self.visible.deinit(self.allocator);
        self.query.deinit(self.allocator);
        if (self.catalog) |*catalog| catalog.deinit();
    }
    pub fn refresh(self: *Model, source: ?SourceFilter) !void {
        var catalog = try self.archive.loadCatalog(self.allocator);
        errdefer catalog.deinit();
        try self.install(&catalog, source);
    }
    /// Takes catalogue ownership only after all fallible projection allocation.
    pub fn install(self: *Model, catalog: *archive_mod.Catalog, source: ?SourceFilter) !void {
        var entries: std.ArrayList(Entry) = .empty;
        errdefer entries.deinit(self.allocator);
        var visible: std.ArrayList(usize) = .empty;
        errdefer visible.deinit(self.allocator);
        try entries.ensureTotalCapacity(self.allocator, catalog.entries.items.len);
        try visible.ensureTotalCapacity(self.allocator, catalog.entries.items.len);
        for (catalog.entries.items, 0..) |descriptor, index| {
            if (source) |filter| if (!filter.matches(descriptor.entry)) continue;
            entries.appendAssumeCapacity(descriptor.entry);
            visible.appendAssumeCapacity(index);
        }
        self.entries.deinit(self.allocator);
        self.visible.deinit(self.allocator);
        if (self.catalog) |*old| old.deinit();
        self.catalog = catalog.*;
        self.entries = entries;
        self.visible = visible;
        self.source_filter = source;
        self.page = 0;
    }
    pub fn applyFilter(self: *Model, query: []const u8, kind: TypeFilter) !void {
        const copy = try self.allocator.dupe(u8, query);
        defer self.allocator.free(copy);
        try self.query.ensureTotalCapacity(self.allocator, copy.len);
        self.query.clearRetainingCapacity();
        self.query.appendSliceAssumeCapacity(copy);
        self.type_filter = kind;
        self.entries.clearRetainingCapacity();
        self.visible.clearRetainingCapacity();
        if (self.catalog) |catalog| for (catalog.entries.items, 0..) |descriptor, index| {
            const entry = descriptor.entry;
            if (self.source_filter) |filter| if (!filter.matches(entry)) continue;
            if (kind == .local and entry.source_kind != .local) continue;
            if (kind == .ssh and entry.source_kind != .ssh) continue;
            if (copy.len > 0 and !contains(descriptor.title, copy) and !contains(entry.host, copy) and !contains(entry.user, copy) and !contains(descriptor.endpoint, copy)) continue;
            self.entries.appendAssumeCapacity(entry);
            self.visible.appendAssumeCapacity(index);
        };
        self.page = 0;
    }
    pub fn len(self: *const Model) usize {
        return self.entries.items.len;
    }
    pub fn at(self: *const Model, index: usize) ?Entry {
        return if (index < self.len()) self.entries.items[index] else null;
    }
    pub fn descriptorAt(self: *const Model, index: usize) ?archive_mod.Descriptor {
        return if (index < self.visible.items.len) self.catalog.?.entries.items[self.visible.items[index]] else null;
    }
    pub fn pageStart(self: *const Model) usize {
        return @min(self.len(), self.page * page_size);
    }
    pub fn pageEnd(self: *const Model) usize {
        return @min(self.len(), self.pageStart() + page_size);
    }
    /// Compatibility path validation. All readers must still acquire a lease.
    pub fn replayPath(self: *const Model, index: usize) ![]const u8 {
        const entry = self.at(index) orelse return error.InvalidHistoryIndex;
        const file = try self.archive.dir.openFile(self.archive.io, entry.cast_path, .{});
        file.close(self.archive.io);
        return entry.cast_path;
    }
    pub fn exportPath(self: *const Model, index: usize) ![]const u8 {
        return self.replayPath(index);
    }
};
fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |index| if (std.ascii.eqlIgnoreCase(haystack[index..][0..needle.len], needle)) return true;
    return false;
}

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

test "history metadata search and type filter never use display name as source identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var archive = Archive{ .allocator = std.testing.allocator, .io = std.testing.io, .dir = tmp.dir };
    try archive.append(.{ .id = 1, .started_ms = 1, .ended_ms = 2, .duration_ms = 1, .host = "同名主机", .user = "Deploy", .cast_path = "logs/history/1.cast", .source_kind = .ssh, .saved_connection_id = 10 });
    try archive.append(.{ .id = 2, .started_ms = 2, .ended_ms = 3, .duration_ms = 1, .host = "同名主机", .user = "local-user", .cast_path = "logs/history/2.cast", .source_kind = .local });
    var model = Model.init(std.testing.allocator, &archive);
    defer model.deinit();
    try model.refresh(null);
    try model.applyFilter("DEPLOY", .all);
    try std.testing.expectEqual(@as(usize, 1), model.len());
    try std.testing.expectEqual(@as(u64, 1), model.at(0).?.id);
    try model.applyFilter("同名", .local);
    try std.testing.expectEqual(@as(usize, 1), model.len());
    try std.testing.expectEqual(@as(u64, 2), model.at(0).?.id);
    try model.applyFilter("unmatched", .all);
    try std.testing.expectEqual(@as(usize, 0), model.len());
    try model.applyFilter("", .all);
    try std.testing.expectEqual(@as(usize, 2), model.len());
    try std.testing.expect(!model.descriptorAt(0).?.can_open);
}
