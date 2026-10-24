const std = @import("std");

// Archive readers and retention/explicit cleanup use the same path gate. The
// key includes the resolved data directory: same-named recordings belonging to
// two isolated application instances never share a lease.
const Reference = struct { key: []u8, token: u64, readers: usize, removing: bool };
var references: std.ArrayList(Reference) = .empty;
var reference_mutex: std.atomic.Mutex = .unlocked;
var next_reference_token: u64 = 1;
var index_mutex: std.atomic.Mutex = .unlocked;

fn lockIndex() void {
    while (!index_mutex.tryLock()) std.atomic.spinLoopHint();
}

fn lockReferences() void {
    while (!reference_mutex.tryLock()) std.atomic.spinLoopHint();
}
fn referenceKey(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) ![]u8 {
    try validatePath(path);
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try dir.realPath(io, &buffer);
    // All artifacts of one Local recording share a lease domain. This also
    // pins its raw stream and checkpoint while a history/export reader is open.
    if (localStem(path)) |stem| return std.fs.path.join(allocator, &.{ buffer[0..length], "logs", stem });
    return std.fs.path.join(allocator, &.{ buffer[0..length], path });
}
fn localStem(path: []const u8) ?[]const u8 {
    const prefix = if (std.mem.startsWith(u8, path, "logs/history/")) "logs/history/" else if (std.mem.startsWith(u8, path, "logs/")) "logs/" else return null;
    const name = path[prefix.len..];
    if (!std.mem.startsWith(u8, name, "session-local-")) return null;
    for ([_][]const u8{ ".cast", ".raw", ".checkpoint" }) |suffix| if (std.mem.endsWith(u8, name, suffix)) return name[0 .. name.len - suffix.len];
    return null;
}

fn releaseReference(token: u64, removal: bool) void {
    lockReferences();
    defer reference_mutex.unlock();
    for (references.items, 0..) |*entry, index| if (entry.token == token) {
        if (removal) entry.removing = false else entry.readers -= 1;
        if (entry.readers == 0 and !entry.removing) {
            const old = references.swapRemove(index);
            std.heap.c_allocator.free(old.key);
            if (references.items.len == 0) {
                references.deinit(std.heap.c_allocator);
                references = .empty;
            }
        }
        return;
    };
}

/// A frozen read handle. New writes/rotations at the same path cannot replace
/// its captured inode or extend the byte range read by an export.
pub const RecordLease = struct {
    io: std.Io,
    file: std.Io.File,
    token: u64,
    stat: std.Io.File.Stat,
    active: bool = true,

    pub fn readAll(self: *const RecordLease, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
        if (!self.active) return error.LeaseReleased;
        if (self.stat.size > max_bytes) return error.RecordingTooLarge;
        const bytes = try allocator.alloc(u8, @intCast(self.stat.size));
        errdefer allocator.free(bytes);
        if (try self.file.readPositionalAll(self.io, bytes, 0) != bytes.len) return error.RecordingTruncated;
        const current = try self.file.stat(self.io);
        if (current.inode != self.stat.inode or current.size < self.stat.size or !std.meta.eql(current.mtime, self.stat.mtime)) return error.RecordingChanged;
        return bytes;
    }
    pub fn deinit(self: *RecordLease) void {
        if (!self.active) return;
        self.file.close(self.io);
        releaseReference(self.token, false);
        self.active = false;
    }
};

pub const RemovalGuard = struct {
    token: u64,
    active: bool = true,
    pub fn deinit(self: *RemovalGuard) void {
        if (!self.active) return;
        releaseReference(self.token, true);
        self.active = false;
    }
};

pub fn acquireLease(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !RecordLease {
    const key = try referenceKey(allocator, io, dir, path);
    defer allocator.free(key);
    lockReferences();
    defer reference_mutex.unlock();
    var existing: ?*Reference = null;
    for (references.items) |*entry| if (std.mem.eql(u8, entry.key, key)) {
        if (entry.removing) return error.RecordBusy;
        existing = entry;
        break;
    };
    const file = try dir.openFile(io, path, .{});
    errdefer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.InvalidRecordingFile;
    const token = if (existing) |entry| blk: {
        entry.readers += 1;
        break :blk entry.token;
    } else blk: {
        if (next_reference_token == std.math.maxInt(u64)) return error.ReferenceExhausted;
        const owned = try std.heap.c_allocator.dupe(u8, key);
        errdefer std.heap.c_allocator.free(owned);
        const token = next_reference_token;
        try references.append(std.heap.c_allocator, .{ .key = owned, .token = token, .readers = 1, .removing = false });
        next_reference_token += 1;
        break :blk token;
    };
    return .{ .io = io, .file = file, .token = token, .stat = stat };
}

/// Hold until index/file mutation has either completed or failed. Unlike an
/// isReferenced preflight, reservation closes the reader/deleter race.
pub fn reserveRemoval(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !RemovalGuard {
    const key = try referenceKey(allocator, io, dir, path);
    defer allocator.free(key);
    lockReferences();
    defer reference_mutex.unlock();
    for (references.items) |entry| if (std.mem.eql(u8, entry.key, key)) return error.RecordBusy;
    if (next_reference_token == std.math.maxInt(u64)) return error.ReferenceExhausted;
    const owned = try std.heap.c_allocator.dupe(u8, key);
    errdefer std.heap.c_allocator.free(owned);
    const token = next_reference_token;
    try references.append(std.heap.c_allocator, .{ .key = owned, .token = token, .readers = 0, .removing = true });
    next_reference_token += 1;
    return .{ .token = token };
}

pub const RemovalSet = struct {
    allocator: std.mem.Allocator,
    guards: std.ArrayList(RemovalGuard) = .empty,
    pub fn deinit(self: *RemovalSet) void {
        for (self.guards.items) |*guard| guard.deinit();
        self.guards.deinit(self.allocator);
    }
};

/// Reserve a frozen artifact group, deduplicating the shared Local lease key.
/// A failed reservation releases every prior guard before returning.
pub fn reserveRemovals(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, paths: []const []const u8) !RemovalSet {
    var result: RemovalSet = .{ .allocator = allocator };
    errdefer result.deinit();
    try result.guards.ensureTotalCapacity(allocator, paths.len);
    for (paths, 0..) |path, index| {
        const key = try referenceKey(allocator, io, dir, path);
        defer allocator.free(key);
        var duplicate = false;
        for (paths[0..index]) |previous| {
            const prior_key = try referenceKey(allocator, io, dir, previous);
            defer allocator.free(prior_key);
            if (std.mem.eql(u8, key, prior_key)) { duplicate = true; break; }
        }
        if (!duplicate) result.guards.appendAssumeCapacity(try reserveRemoval(allocator, io, dir, path));
    }
    return result;
}

pub fn isReferenced(io: std.Io, dir: std.Io.Dir, path: []const u8) !bool {
    const key = try referenceKey(std.heap.c_allocator, io, dir, path);
    defer std.heap.c_allocator.free(key);
    lockReferences();
    defer reference_mutex.unlock();
    for (references.items) |entry| if (std.mem.eql(u8, entry.key, key)) return entry.readers != 0 or entry.removing;
    return false;
}

/// Persistent index for closed-session recordings. The index is deliberately
/// line based so a damaged final line never hides older entries. Fields are
/// tab separated and sanitized before writing.
pub const SourceKind = enum { local, ssh };

pub const Entry = struct {
    id: u64,
    ended_ms: i64,
    started_ms: i64,
    host: []const u8,
    user: []const u8,
    cast_path: []const u8,
    duration_ms: u64,
    exit_code: ?i32 = null,
    /// Null on legacy indexes; never infer identity from the display host.
    source_kind: ?SourceKind = null,
    saved_connection_id: ?u64 = null,
};
pub const EntryKey = struct { id: u64, started_ms: i64, cast_path: []const u8 };

pub const Archive = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    index_path: []const u8 = "logs/history/index.tsv",

    pub fn append(self: *Archive, entry: Entry) !void {
        lockIndex();
        defer index_mutex.unlock();
        try validatePath(self.index_path);
        if (entry.saved_connection_id) |id| if (id == 0 or entry.source_kind != .ssh) return error.InvalidArchiveIdentity;
        try validateField(entry.host);
        try validateField(entry.user);
        try validatePath(entry.cast_path);
        if (std.fs.path.dirname(self.index_path)) |parent| try self.dir.createDirPath(self.io, parent);
        const old = self.dir.readFileAlloc(self.io, self.index_path, self.allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => try self.allocator.dupe(u8, ""),
            else => return err,
        };
        defer self.allocator.free(old);
        var buf: [4096]u8 = undefined;
        var line = std.ArrayList(u8).empty;
        defer line.deinit(self.allocator);
        try line.appendSlice(self.allocator, old);
        var writer = std.Io.Writer.fixed(&buf);
        try writer.print("{d}\t{d}\t{d}\t{d}\t{d}\t{s}\t{s}\t{s}\t{s}\t{d}\n", .{
            entry.id, entry.started_ms, entry.ended_ms, entry.duration_ms,
            entry.exit_code orelse -2147483648, sanitize(entry.host), sanitize(entry.user), sanitize(entry.cast_path), if (entry.source_kind) |kind| @tagName(kind) else "", entry.saved_connection_id orelse 0,
        });
        try line.appendSlice(self.allocator, writer.buffered());
        var atomic = try self.dir.createFileAtomic(self.io, self.index_path, .{ .permissions = @as(std.Io.File.Permissions, @fromBackingInt(0o600)), .make_path = true, .replace = true });
        defer atomic.deinit(self.io);
        try atomic.file.writePositionalAll(self.io, line.items, 0);
        try atomic.replace(self.io);
    }

    /// Loads valid entries, skipping a partial/corrupt trailing line.
    pub fn load(self: *Archive, allocator: std.mem.Allocator) !std.ArrayList(Entry) {
        var out: std.ArrayList(Entry) = .empty;
        errdefer self.freeEntries(&out);
        const data = self.dir.readFileAlloc(self.io, self.index_path, allocator, .limited(16 * 1024 * 1024)) catch |err| {
            if (err == error.FileNotFound) return out;
            return err;
        };
        defer allocator.free(data);
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const id = parseU64(fields.next() orelse continue) orelse continue;
            const started = parseI64(fields.next() orelse continue) orelse continue;
            const ended = parseI64(fields.next() orelse continue) orelse continue;
            const duration = parseU64(fields.next() orelse continue) orelse continue;
            const exit_raw = parseI64(fields.next() orelse continue) orelse continue;
            if (exit_raw < std.math.minInt(i32) or exit_raw > std.math.maxInt(i32)) continue;
            const host_raw = fields.next() orelse continue;
            const user_raw = fields.next() orelse continue;
            const path_raw = fields.next() orelse continue;
            const identity_fields = parseIdentity(&fields) orelse continue;
            const host = try allocator.dupe(u8, host_raw);
            errdefer allocator.free(host);
            const user = try allocator.dupe(u8, user_raw);
            errdefer allocator.free(user);
            const path = try allocator.dupe(u8, path_raw);
            errdefer allocator.free(path);
            try out.append(allocator, .{ .id = id, .started_ms = started, .ended_ms = ended, .duration_ms = duration, .exit_code = if (exit_raw == -2147483648) null else @intCast(exit_raw), .host = host, .user = user, .cast_path = path, .source_kind = identity_fields.kind, .saved_connection_id = identity_fields.connection_id });
        }
        return out;
    }

    /// Removes entries older than keep_days and rewrites the index atomically.
    /// The cast file is removed only after it is no longer indexed.
    pub fn prune(self: *Archive, keep_days: u16, now_ms: i64) !usize {
        if (keep_days == 0) return 0;
        lockIndex();
        defer index_mutex.unlock();
        var entries = try self.load(self.allocator);
        defer self.freeEntries(&entries);
        const cutoff = now_ms - @as(i64, keep_days) * std.time.ms_per_day;
        var kept: std.ArrayList(Entry) = .empty;
        defer kept.deinit(self.allocator);
        // Complete every fallible allocation before unlinking any recording.
        try kept.ensureTotalCapacity(self.allocator, entries.items.len);
        var guards: std.ArrayList(RemovalGuard) = .empty;
        defer { for (guards.items) |*guard| guard.deinit(); guards.deinit(self.allocator); }
        try guards.ensureTotalCapacity(self.allocator, entries.items.len);
        var atomic = try self.dir.createFileAtomic(self.io, self.index_path, .{ .permissions = @as(std.Io.File.Permissions, @fromBackingInt(0o600)), .make_path = true, .replace = true });
        defer atomic.deinit(self.io);
        var removed: usize = 0;
        for (entries.items) |entry| {
            if (entry.ended_ms < cutoff) {
                if (reserveRemoval(self.allocator, self.io, self.dir, entry.cast_path)) |guard| {
                    guards.appendAssumeCapacity(guard);
                } else |err| switch (err) {
                    error.RecordBusy => { kept.appendAssumeCapacity(entry); continue; },
                    else => return err,
                }
            } else { kept.appendAssumeCapacity(entry); continue; }
            // Guard setup is completed for every candidate before mutation.
        }
        // Reservations hold through the atomic index replacement. No new
        // reader can enter the gap between unlink and index publication.
        for (entries.items) |entry| {
            var reserved = entry.ended_ms < cutoff;
            if (reserved) for (kept.items) |item| {
                if (item.cast_path.ptr == entry.cast_path.ptr) { reserved = false; break; }
            };
            if (!reserved) continue;
            const remove = if (self.dir.deleteFile(self.io, entry.cast_path)) |_| true else |err| err == error.FileNotFound;
            if (remove) {
                removed += 1;
                if (localStem(entry.cast_path)) |stem| {
                    var buffer: [std.fs.max_path_bytes]u8 = undefined;
                    for ([_][]const u8{ ".raw", ".checkpoint" }) |suffix| {
                        const path = try std.fmt.bufPrint(&buffer, "logs/{s}{s}", .{stem, suffix});
                        self.dir.deleteFile(self.io, path) catch |err| if (err != error.FileNotFound) return err;
                    }
                }
            } else kept.appendAssumeCapacity(entry);
        }
        if (removed != 0) {
            var buffer: [4096]u8 = undefined;
            var writer = atomic.file.writer(self.io, &buffer);
            for (kept.items) |entry| try writer.interface.print("{d}\t{d}\t{d}\t{d}\t{d}\t{s}\t{s}\t{s}\t{s}\t{d}\n", .{ entry.id, entry.started_ms, entry.ended_ms, entry.duration_ms, entry.exit_code orelse -2147483648, sanitize(entry.host), sanitize(entry.user), sanitize(entry.cast_path), if (entry.source_kind) |kind| @tagName(kind) else "", entry.saved_connection_id orelse 0 });
            try writer.interface.flush();
            try atomic.replace(self.io);
        }
        return removed;
    }

    /// Explicit cleanup supplies only paths it has successfully removed while
    /// holding RemovalGuards. Preserve entries appended after its plan froze.
    pub fn removeEntries(self: *Archive, keys: []const EntryKey) !void {
        lockIndex();
        defer index_mutex.unlock();
        const source = self.dir.readFileAlloc(self.io, self.index_path, self.allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(source);
        var kept: std.ArrayList(u8) = .empty;
        defer kept.deinit(self.allocator);
        var cursor: usize = 0;
        while (cursor < source.len) {
            const end = if (std.mem.indexOfScalarPos(u8, source, cursor, '\n')) |index| index + 1 else source.len;
            const raw = source[cursor..end];
            const line = std.mem.trimEnd(u8, raw, "\n");
            var fields = std.mem.splitScalar(u8, line, '\t');
            const id = parseU64(fields.next() orelse "");
            const started = parseI64(fields.next() orelse "");
            for (0..5) |_| _ = fields.next();
            const path = fields.next();
            var removed = false;
            if (id != null and started != null and path != null and parseIdentity(&fields) != null and std.mem.endsWith(u8, raw, "\n")) for (keys) |key| {
                if (id.? == key.id and started.? == key.started_ms and std.mem.eql(u8, path.?, key.cast_path)) {
                    removed = true;
                    break;
                }
            };
            if (!removed) try kept.appendSlice(self.allocator, raw);
            cursor = end;
        }
        var atomic = try self.dir.createFileAtomic(self.io, self.index_path, .{ .permissions = @as(std.Io.File.Permissions, @fromBackingInt(0o600)), .make_path = true, .replace = true });
        defer atomic.deinit(self.io);
        try atomic.file.writePositionalAll(self.io, kept.items, 0);
        try atomic.replace(self.io);
    }

    fn rewrite(self: *Archive, entries: []const Entry) !void {
        var buf: [4096]u8 = undefined;
        var atomic = try self.dir.createFileAtomic(self.io, self.index_path, .{ .permissions = @as(std.Io.File.Permissions, @fromBackingInt(@intCast(0o600))), .make_path = true, .replace = true });
        defer atomic.deinit(self.io);
        var writer = atomic.file.writer(self.io, &buf);
        for (entries) |entry| try writer.interface.print("{d}\t{d}\t{d}\t{d}\t{d}\t{s}\t{s}\t{s}\t{s}\t{d}\n", .{ entry.id, entry.started_ms, entry.ended_ms, entry.duration_ms, entry.exit_code orelse -2147483648, sanitize(entry.host), sanitize(entry.user), sanitize(entry.cast_path), if (entry.source_kind) |kind| @tagName(kind) else "", entry.saved_connection_id orelse 0 });
        try writer.interface.flush();
        try atomic.replace(self.io);
    }

    /// Releases strings and the list returned by `load`.  Callers that retain
    /// an archive index for a view/controller use this instead of duplicating
    /// the ownership rules.
    pub fn freeEntries(self: *Archive, entries: *std.ArrayList(Entry)) void {
        for (entries.items) |entry| { self.allocator.free(entry.host); self.allocator.free(entry.user); self.allocator.free(entry.cast_path); }
        entries.deinit(self.allocator);
    }
};

const ParsedIdentity = struct { kind: ?SourceKind = null, connection_id: ?u64 = null };

/// Eight columns are legacy. Extended rows need both identity columns; partial
/// or invalid identities must not silently fall back to a different source.
fn parseIdentity(fields: *std.mem.SplitIterator(u8, .scalar)) ?ParsedIdentity {
    const source = fields.next() orelse return .{};
    const id_raw = fields.next() orelse return null;
    if (fields.next() != null) return null;
    const id = parseU64(id_raw) orelse return null;
    const kind: ?SourceKind = if (source.len == 0) null else std.meta.stringToEnum(SourceKind, source) orelse return null;
    if (id != 0 and kind != .ssh) return null;
    return .{ .kind = kind, .connection_id = if (id == 0) null else id };
}

fn sanitize(value: []const u8) []const u8 { return value; }
fn validateField(value: []const u8) !void {
    if (value.len == 0) return error.InvalidArchiveField;
    for (value) |byte| if (byte == '\t' or byte == '\n' or byte == '\r') return error.InvalidArchiveField;
}
fn parseU64(v: []const u8) ?u64 { return std.fmt.parseInt(u64, v, 10) catch null; }
fn parseI64(v: []const u8) ?i64 { return std.fmt.parseInt(i64, v, 10) catch null; }
fn validatePath(path: []const u8) !void { if (path.len == 0 or path[0] == '/') return error.InvalidArchivePath; var it = std.mem.splitScalar(u8, path, '/'); while (it.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidArchivePath; }

test "archive index tolerates partial lines and prunes cast files" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var archive = Archive{ .allocator = std.testing.allocator, .io = std.testing.io, .dir = tmp.dir };
    try archive.append(.{ .id = 1, .started_ms = 0, .ended_ms = 1, .duration_ms = 1, .host = "h", .user = "u", .cast_path = "logs/history/a.cast" });
    try tmp.dir.createDirPath(std.testing.io, "logs/history");
    var f = try tmp.dir.createFile(std.testing.io, "logs/history/a.cast", .{}); f.close(std.testing.io);
    var idx = try tmp.dir.openFile(std.testing.io, "logs/history/index.tsv", .{ .mode = .write_only });
    idx.close(std.testing.io);
    const prior = try tmp.dir.readFileAlloc(std.testing.io, "logs/history/index.tsv", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(prior);
    var merged = try std.testing.allocator.alloc(u8, prior.len + 7);
    defer std.testing.allocator.free(merged);
    @memcpy(merged[0..prior.len], prior); @memcpy(merged[prior.len..], "partial");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "logs/history/index.tsv", .data = merged });
    var loaded = try archive.load(std.testing.allocator); defer archive.freeEntries(&loaded); try std.testing.expectEqual(@as(usize, 1), loaded.items.len);
    try std.testing.expectEqual(@as(usize, 1), try archive.prune(1, std.time.ms_per_day + 10));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "logs/history/a.cast", .{}));
}

test "archive read lease pins the real file and retention waits for release" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "logs/history");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "logs/history/a.cast", .data = "original" });
    var archive: Archive = .{ .allocator = std.testing.allocator, .io = std.testing.io, .dir = tmp.dir };
    try archive.append(.{ .id = 1, .started_ms = 0, .ended_ms = 1, .duration_ms = 1, .host = "local", .user = "zsh", .cast_path = "logs/history/a.cast" });
    var lease = try acquireLease(std.testing.allocator, std.testing.io, tmp.dir, "logs/history/a.cast");
    defer lease.deinit();
    try std.testing.expect(try isReferenced(std.testing.io, tmp.dir, "logs/history/a.cast"));
    try std.testing.expectError(error.RecordBusy, reserveRemoval(std.testing.allocator, std.testing.io, tmp.dir, "logs/history/a.cast"));
    try std.testing.expectEqual(@as(usize, 0), try archive.prune(1, std.time.ms_per_day + 10));
    const bytes = try lease.readAll(std.testing.allocator, 4096);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("original", bytes);
    lease.deinit();
    try std.testing.expectEqual(@as(usize, 1), try archive.prune(1, std.time.ms_per_day + 10));
    var guard = try reserveRemoval(std.testing.allocator, std.testing.io, tmp.dir, "logs/history/a.cast");
    defer guard.deinit();
    try std.testing.expectError(error.RecordBusy, acquireLease(std.testing.allocator, std.testing.io, tmp.dir, "logs/history/a.cast"));
}

test "archive cleanup preserves a newer entry and damaged tail" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var archive: Archive = .{ .allocator = std.testing.allocator, .io = std.testing.io, .dir = tmp.dir };
    try archive.append(.{ .id = 1, .started_ms = 1, .ended_ms = 2, .duration_ms = 1, .host = "local", .user = "zsh", .cast_path = "logs/history/a.cast" });
    try archive.append(.{ .id = 1, .started_ms = 3, .ended_ms = 4, .duration_ms = 1, .host = "local", .user = "zsh", .cast_path = "logs/history/a.cast" });
    const source = try tmp.dir.readFileAlloc(std.testing.io, archive.index_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(source);
    const damaged = try std.fmt.allocPrint(std.testing.allocator, "{s}damaged-tail", .{source});
    defer std.testing.allocator.free(damaged);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = archive.index_path, .data = damaged });
    try archive.removeEntries(&.{.{ .id = 1, .started_ms = 1, .cast_path = "logs/history/a.cast" }});
    const kept = try tmp.dir.readFileAlloc(std.testing.io, archive.index_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(kept);
    try std.testing.expect(std.mem.startsWith(u8, kept, "1\t3\t4\t"));
    try std.testing.expect(std.mem.endsWith(u8, kept, "damaged-tail"));
}

test "Local artifact group is pinned together and reservations deduplicate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths: []const []const u8 = &.{ "logs/history/session-local-1-2-3-4.cast", "logs/session-local-1-2-3-4.raw", "logs/session-local-1-2-3-4.checkpoint" };
    try tmp.dir.createDirPath(std.testing.io, "logs/history");
    for (paths) |path| try tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = "data" });
    var lease = try acquireLease(std.testing.allocator, std.testing.io, tmp.dir, paths[0]);
    defer lease.deinit();
    try std.testing.expectError(error.RecordBusy, reserveRemovals(std.testing.allocator, std.testing.io, tmp.dir, paths));
    lease.deinit();
    var guards = try reserveRemovals(std.testing.allocator, std.testing.io, tmp.dir, paths);
    defer guards.deinit();
    try std.testing.expectEqual(@as(usize, 1), guards.guards.items.len);
    try std.testing.expectError(error.RecordBusy, acquireLease(std.testing.allocator, std.testing.io, tmp.dir, paths[2]));
}

test "retention allocation failure leaves the recording and index untouched" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var archive: Archive = .{ .allocator = std.testing.allocator, .io = std.testing.io, .dir = tmp.dir };
    const path = "logs/history/a.cast";
    try archive.append(.{ .id = 1, .started_ms = 0, .ended_ms = 1, .duration_ms = 1, .host = "local", .user = "zsh", .cast_path = path });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = "recording" });
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    archive.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, archive.prune(1, 2 * std.time.ms_per_day));
    var file = try tmp.dir.openFile(std.testing.io, path, .{});
    file.close(std.testing.io);
    archive.allocator = std.testing.allocator;
    var entries = try archive.load(std.testing.allocator);
    defer archive.freeEntries(&entries);
    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
}

test "archive reads legacy and stable identities and cleanup preserves identity columns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var archive: Archive = .{ .allocator = std.testing.allocator, .io = std.testing.io, .dir = tmp.dir };
    try tmp.dir.createDirPath(std.testing.io, "logs/history");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = archive.index_path, .data =
        "1\t1\t2\t1\t0\tsame\tu\tlogs/history/1.cast\n" ++
        "8\t1\t2\t1\t0\tsame\tu\tlogs/history/8.cast\tssh\n" ++
        "9\t1\t2\t1\t0\tsame\tu\tlogs/history/9.cast\tlocal\t99\n" });
    try archive.append(.{ .id = 2, .started_ms = 3, .ended_ms = 4, .duration_ms = 1, .host = "same", .user = "u", .cast_path = "logs/history/2.cast", .source_kind = .ssh, .saved_connection_id = 42 });
    try archive.append(.{ .id = 3, .started_ms = 5, .ended_ms = 6, .duration_ms = 1, .host = "same", .user = "u", .cast_path = "logs/history/3.cast", .source_kind = .local });
    var entries = try archive.load(std.testing.allocator);
    defer archive.freeEntries(&entries);
    try std.testing.expectEqual(@as(usize, 3), entries.items.len);
    try std.testing.expectEqual(@as(?SourceKind, null), entries.items[0].source_kind);
    try std.testing.expectEqual(@as(?u64, 42), entries.items[1].saved_connection_id);
    try std.testing.expectEqual(SourceKind.local, entries.items[2].source_kind.?);
    try archive.removeEntries(&.{.{ .id = 2, .started_ms = 3, .cast_path = "logs/history/2.cast" }});
    // Retention rewrites surviving entries; the Local kind must survive it.
    try std.testing.expectEqual(@as(usize, 1), try archive.prune(1, std.time.ms_per_day + 3));
    var kept = try archive.load(std.testing.allocator);
    defer archive.freeEntries(&kept);
    try std.testing.expectEqual(@as(usize, 1), kept.items.len);
    try std.testing.expectEqual(@as(u64, 3), kept.items[0].id);
    try std.testing.expectEqual(SourceKind.local, kept.items[0].source_kind.?);
    try std.testing.expectError(error.InvalidArchiveIdentity, archive.append(.{ .id = 4, .started_ms = 5, .ended_ms = 6, .duration_ms = 1, .host = "h", .user = "u", .cast_path = "logs/history/4.cast", .source_kind = .local, .saved_connection_id = 42 }));
}
