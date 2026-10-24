//! Explicit settings cleanup. A plan is frozen only after confirmation; it never
//! scans again while running or retrying and never recursively removes logs.
const std = @import("std");
const archive_mod = @import("../vt/session_archive.zig");

pub const File = struct {
    path: []const u8,
    identity: ?std.Io.File.Stat,
    removed: bool = false,
};
pub const State = enum { pending, deleted, failed };
pub const Record = struct {
    key: ?archive_mod.EntryKey = null,
    files: std.ArrayList(File) = .empty,
    state: State = .pending,
    failure: ?anyerror = null,
    invalid: bool = false,
};
pub const Progress = struct {
    total: usize = 0,
    deleted: usize = 0,
    failed: usize = 0,
    pending: usize = 0,
    pub fn done(self: Progress) bool {
        return self.pending == 0;
    }
};

pub fn requireIdle(has_active_sessions: bool) !void {
    if (has_active_sessions) return error.LiveSessionActive;
}

pub const Controller = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    records: std.ArrayList(Record) = .empty,
    running: bool = false,

    /// Borrows the data directory until deinit. This is read-only: cancelling a
    /// confirmation does not call freeze, and freezing itself writes no files.
    pub fn freeze(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, has_active_sessions: bool) !Controller {
        try requireIdle(has_active_sessions);
        var self: Controller = .{ .allocator = allocator, .io = io, .dir = dir };
        errdefer self.deinit();
        // Do not traverse a symlink in either application-owned directory.
        const logs = dir.openDir(io, "logs", .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return self,
            else => return err,
        };
        defer logs.close(io);
        const history: ?std.Io.Dir = logs.openDir(io, "history", .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (history) |value| value.close(io);
        var archive: archive_mod.Archive = .{ .allocator = allocator, .io = io, .dir = dir };
        var entries = try archive.load(allocator);
        defer archive.freeEntries(&entries);
        for (entries.items) |entry| {
            // Archive may contain an invalid/corrupt source path. Keep its row
            // as a visible failed item; never turn it into arbitrary deletion.
            var record: Record = .{};
            errdefer self.freeRecord(&record);
            const path = try allocator.dupe(u8, entry.cast_path);
            record.key = .{ .id = entry.id, .started_ms = entry.started_ms, .cast_path = path };
            if (!isCastPath(path)) {
                record.invalid = true;
                record.state = .failed;
                record.failure = error.InvalidRecordingPath;
            } else {
                const stat: ?std.Io.File.Stat = self.pathStat(path) catch |err| blk: {
                    if (err == error.FileNotFound) {
                        record.state = .failed;
                        record.failure = error.RecordingMissing;
                        break :blk null;
                    }
                    record.invalid = true;
                    record.state = .failed;
                    record.failure = err;
                    break :blk null;
                };
                if (stat) |value| if (value.kind != .file) {
                    record.invalid = true;
                    record.state = .failed;
                    record.failure = error.InvalidRecordingFile;
                };
                try self.addFile(&record, path, stat);
            }
            try self.records.append(allocator, record);
        }
        var iterator = logs.iterate();
        while (try iterator.next(io)) |entry| {
            if (entry.kind != .file or !isRawName(entry.name)) continue;
            const file = logs.openFile(io, entry.name, .{ .follow_symlinks = false }) catch continue;
            defer file.close(io);
            const stat = try file.stat(io);
            var header: [32]u8 = undefined;
            if (try file.readPositionalAll(io, &header, 0) != header.len or !validRaw(header, stat.size)) continue;
            var record: Record = .{};
            errdefer self.freeRecord(&record);
            const raw_path = try std.fmt.allocPrint(allocator, "logs/{s}", .{entry.name});
            defer allocator.free(raw_path);
            try self.addFile(&record, raw_path, stat);
            const checkpoint = try std.fmt.allocPrint(allocator, "logs/{s}.checkpoint", .{entry.name[0 .. entry.name.len - 4]});
            defer allocator.free(checkpoint);
            const checkpoint_stat: ?std.Io.File.Stat = self.pathStat(checkpoint) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            if (checkpoint_stat) |value| {
                if (value.kind == .file and (value.size == 24 or try self.isGhosttyCheckpoint(checkpoint, value.size))) {
                    try self.addFile(&record, checkpoint, value);
                }
            }
            // Local recording keeps the same stem across its cast/raw pair.
            // Older SSH logs have no such relation: never guess by an ID.
            var merged = false;
            if (std.mem.startsWith(u8, entry.name, "session-local-")) {
                const stem = entry.name[0 .. entry.name.len - 4];
                for (self.records.items) |*existing| if (existing.key) |key| {
                    const name = std.fs.path.basename(key.cast_path);
                    if (name.len == stem.len + 5 and std.mem.startsWith(u8, name, stem)) {
                        try existing.files.appendSlice(allocator, record.files.items);
                        record.files.deinit(allocator);
                        record.files = .empty;
                        merged = true;
                        break;
                    }
                };
            }
            if (merged) continue;
            try self.records.append(allocator, record);
        }
        return self;
    }

    pub fn deinit(self: *Controller) void {
        for (self.records.items) |*record| self.freeRecord(record);
        self.records.deinit(self.allocator);
        self.records = .empty;
    }
    fn freeRecord(self: *Controller, record: *Record) void {
        for (record.files.items) |file| self.allocator.free(file.path);
        record.files.deinit(self.allocator);
        if (record.key) |key| self.allocator.free(key.cast_path);
    }
    fn addFile(self: *Controller, record: *Record, path: []const u8, stat: ?std.Io.File.Stat) !void {
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);
        try record.files.append(self.allocator, .{ .path = owned, .identity = stat });
    }
    pub fn progress(self: *const Controller) Progress {
        var value: Progress = .{ .total = self.records.items.len };
        for (self.records.items) |record| switch (record.state) {
            .pending => value.pending += 1,
            .deleted => value.deleted += 1,
            .failed => value.failed += 1,
        };
        return value;
    }
    pub fn firstFailure(self: *const Controller) ?anyerror {
        for (self.records.items) |record| if (record.state == .failed) return record.failure;
        return null;
    }
    pub fn begin(self: *Controller, has_active_sessions: bool) !void {
        try requireIdle(has_active_sessions);
        if (self.running) return error.CleanupAlreadyRunning;
        self.running = true;
    }
    /// Retries the frozen failed IDs only. Successful items and records added
    /// later are not enumerated, read, deleted or removed from the index.
    pub fn retryFailed(self: *Controller, has_active_sessions: bool) !void {
        try requireIdle(has_active_sessions);
        if (self.running) return error.CleanupAlreadyRunning;
        for (self.records.items) |*record| if (record.state == .failed) {
            record.state = .pending;
            record.failure = null;
        };
        self.running = true;
    }
    /// One recording per UI tick, so progress is real and settings stay usable.
    pub fn step(self: *Controller, has_active_sessions: bool) !Progress {
        if (!self.running) return error.CleanupNotRunning;
        requireIdle(has_active_sessions) catch |err| {
            for (self.records.items) |*record| if (record.state == .pending) {
                record.state = .failed;
                record.failure = err;
            };
            self.running = false;
            return self.progress();
        };
        for (self.records.items) |*record| if (record.state == .pending) {
            self.removeRecord(record) catch |err| {
                record.state = .failed;
                record.failure = err;
            };
            break;
        };
        const value = self.progress();
        if (value.done()) self.running = false;
        return value;
    }
    fn removeRecord(self: *Controller, record: *Record) !void {
        if (record.invalid) return error.InvalidRecordingFile;
        // Obtain all references before deleting any path in this recording.
        const paths = try self.allocator.alloc([]const u8, record.files.items.len);
        defer self.allocator.free(paths);
        for (record.files.items, paths) |file, *path| path.* = file.path;
        var guards = try archive_mod.reserveRemovals(self.allocator, self.io, self.dir, paths);
        defer guards.deinit();
        // Check the complete frozen set before mutating any one file.
        for (record.files.items) |file| {
            const stat = self.pathStat(file.path) catch |err| switch (err) {
                error.FileNotFound => if (file.removed) continue else return error.RecordingMissing,
                else => return err,
            };
            if (file.removed or file.identity == null or !sameFile(file.identity.?, stat)) return error.RecordingChanged;
        }
        for (record.files.items) |*file| {
            if (file.removed) continue;
            try self.deletePath(file.path);
            file.removed = true;
        }
        // An index error leaves this item failed even if its file is missing.
        // Next retry uses the same key and only retries the index commit.
        if (record.key) |key| {
            var archive: archive_mod.Archive = .{ .allocator = self.allocator, .io = self.io, .dir = self.dir };
            try archive.removeEntries(&.{key});
        }
        record.state = .deleted;
        record.failure = null;
    }
    fn parent(self: *Controller, path: []const u8) !std.Io.Dir {
        const logs = try self.dir.openDir(self.io, "logs", .{ .follow_symlinks = false });
        if (!std.mem.startsWith(u8, path, "logs/history/")) return logs;
        defer logs.close(self.io);
        return logs.openDir(self.io, "history", .{ .follow_symlinks = false });
    }
    fn pathStat(self: *Controller, path: []const u8) !std.Io.File.Stat {
        const directory = try self.parent(path);
        defer directory.close(self.io);
        return directory.statFile(self.io, std.fs.path.basename(path), .{ .follow_symlinks = false });
    }
    fn isGhosttyCheckpoint(self: *Controller, path: []const u8, size: u64) !bool {
        if (size <= 8) return false;
        const logs = try self.dir.openDir(self.io, "logs", .{ .follow_symlinks = false });
        defer logs.close(self.io);
        const file = try logs.openFile(self.io, std.fs.path.basename(path), .{ .follow_symlinks = false });
        defer file.close(self.io);
        var magic: [8]u8 = undefined;
        // This identifies an application-owned snapshot file for deletion; it
        // does not claim the snapshot payload can be decoded or replayed.
        return try file.readPositionalAll(self.io, &magic, 0) == 8 and std.mem.eql(u8, &magic, "GHOSTSNP");
    }
    fn deletePath(self: *Controller, path: []const u8) !void {
        const directory = try self.parent(path);
        defer directory.close(self.io);
        try directory.deleteFile(self.io, std.fs.path.basename(path));
    }
};

fn sameFile(a: std.Io.File.Stat, b: std.Io.File.Stat) bool {
    return a.kind == .file and b.kind == .file and a.inode == b.inode and a.size == b.size and std.meta.eql(a.mtime, b.mtime) and std.meta.eql(a.ctime, b.ctime);
}
fn isCastPath(path: []const u8) bool {
    const prefix = "logs/history/";
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, ".cast")) return false;
    const name = path[prefix.len..];
    return name.len > 5 and std.mem.indexOfAny(u8, name, "/\\\x00") == null and !std.mem.eql(u8, name, "..cast");
}
fn isRawName(name: []const u8) bool {
    if (!std.mem.endsWith(u8, name, ".raw")) return false;
    const local = std.mem.startsWith(u8, name, "session-local-");
    const prefix = if (local) "session-local-" else "session-";
    if (!std.mem.startsWith(u8, name, prefix)) return false;
    var parts = std.mem.splitScalar(u8, name[prefix.len .. name.len - 4], '-');
    var count: usize = 0;
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        for (part) |byte| if (!std.ascii.isDigit(byte)) return false;
        _ = std.fmt.parseInt(u64, part, 10) catch return false;
        count += 1;
    }
    return count == (if (local) @as(usize, 4) else 3);
}
fn validRaw(header: [32]u8, size: u64) bool {
    if (!std.mem.eql(u8, header[0..8], "ZWRAW001")) return false;
    const capacity = std.mem.readInt(u64, header[8..16], .little);
    const sequence = std.mem.readInt(u64, header[16..24], .little);
    const length = std.mem.readInt(u64, header[24..32], .little);
    return capacity != 0 and capacity <= std.math.maxInt(u64) - 32 and length <= capacity and length <= sequence and size == 32 + @min(sequence, capacity);
}
