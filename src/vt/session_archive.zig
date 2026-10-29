const std = @import("std");
const record_identity = @import("../host/identity.zig");
pub const manifest = @import("recording_manifest.zig");

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
    if (std.mem.indexOf(u8, name, ".commit-")) |index| if (std.mem.endsWith(u8, name, ".cast")) return name[0..index];
    for ([_][]const u8{ ".cast", ".raw", ".checkpoint", ".session.json" }) |suffix| if (std.mem.endsWith(u8, name, suffix)) return name[0 .. name.len - suffix.len];
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
    const file = try manifest.openManaged(io, dir, path);
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
            if (std.mem.eql(u8, key, prior_key)) {
                duplicate = true;
                break;
            }
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
pub const SourceKind = manifest.SourceKind;

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

    pub fn loadCatalog(self: *Archive, allocator: std.mem.Allocator) !Catalog {
        return catalogLoad(self, allocator);
    }
    pub fn loadCatalogForCleanup(self: *Archive, allocator: std.mem.Allocator) !Catalog {
        return catalogLoadWithActive(self, allocator, true);
    }
    pub fn resolveRecord(self: *Archive, allocator: std.mem.Allocator, query: RecordQuery) !ResolvedRecord {
        return catalogResolve(self, allocator, query);
    }
    pub fn acquireRecord(self: *Archive, allocator: std.mem.Allocator, descriptor: Descriptor) !RecordGroupLease {
        return catalogAcquire(self, allocator, descriptor, .replay);
    }
    /// Export preserves real retained bytes even when no matching VT baseline
    /// permits accurate replay. All file/identity checks remain the same.
    pub fn acquireRecordForExport(self: *Archive, allocator: std.mem.Allocator, descriptor: Descriptor) !RecordGroupLease {
        return catalogAcquire(self, allocator, descriptor, .export_retained);
    }

    pub fn publishMetadata(self: *Archive, options: MetadataPublication) !MetadataReceipt {
        return publishMetadataOnly(self, options);
    }

    pub fn append(self: *Archive, entry: Entry) !void {
        lockIndex();
        defer index_mutex.unlock();
        return self.appendUnlocked(entry);
    }
    /// Completion retries publish the same compatibility row at most once.
    pub fn appendOnce(self: *Archive, entry: Entry) !void {
        lockIndex();
        defer index_mutex.unlock();
        var existing = try self.load(self.allocator);
        defer self.freeEntries(&existing);
        for (existing.items) |current| if (current.id == entry.id and current.started_ms == entry.started_ms and std.mem.eql(u8, current.cast_path, entry.cast_path)) return;
        return self.appendUnlocked(entry);
    }
    fn appendUnlocked(self: *Archive, entry: Entry) !void {
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
            entry.id,                                             entry.started_ms,                   entry.ended_ms,       entry.duration_ms,
            entry.exit_code orelse -2147483648,                   sanitize(entry.host),               sanitize(entry.user), sanitize(entry.cast_path),
            if (entry.source_kind) |kind| @tagName(kind) else "", entry.saved_connection_id orelse 0,
        });
        try line.appendSlice(self.allocator, writer.buffered());
        var atomic = try self.dir.createFileAtomic(self.io, self.index_path, .{ .permissions = @as(std.Io.File.Permissions, @fromBackingInt(0o600)), .make_path = true, .replace = true });
        defer atomic.deinit(self.io);
        try atomic.file.writePositionalAll(self.io, line.items, 0);
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
    }

    /// Loads valid entries, skipping a partial/corrupt trailing line.
    pub fn load(self: *Archive, allocator: std.mem.Allocator) !std.ArrayList(Entry) {
        return self.loadBounded(allocator, 16 * 1024 * 1024, std.math.maxInt(usize));
    }
    fn loadBounded(self: *Archive, allocator: std.mem.Allocator, byte_limit: usize, entry_limit: usize) !std.ArrayList(Entry) {
        var out: std.ArrayList(Entry) = .empty;
        errdefer self.freeEntries(&out);
        const data = self.dir.readFileAlloc(self.io, self.index_path, allocator, .limited(byte_limit)) catch |err| {
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
            if (out.items.len == entry_limit) return error.CatalogLimit;
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
        try kept.ensureTotalCapacity(self.allocator, entries.items.len);
        var plans: std.ArrayList(RemovalPlan) = .empty;
        defer {
            for (plans.items) |*plan| plan.deinit();
            plans.deinit(self.allocator);
        }
        try plans.ensureTotalCapacity(self.allocator, entries.items.len);
        var atomic = try self.dir.createFileAtomic(self.io, self.index_path, .{ .permissions = @as(std.Io.File.Permissions, @fromBackingInt(0o600)), .make_path = true, .replace = true });
        defer atomic.deinit(self.io);
        for (entries.items) |entry| {
            if (entry.ended_ms >= cutoff) {
                kept.appendAssumeCapacity(entry);
                continue;
            }
            var already_planned = false;
            for (plans.items) |plan| {
                for (plan.paths.items) |path| if (std.mem.eql(u8, path, entry.cast_path)) {
                    already_planned = true;
                    break;
                };
                if (already_planned) break;
            }
            if (already_planned) continue;
            const plan = makeRemovalPlan(self.allocator, self.io, self.dir, entry.cast_path) catch |err| switch (err) {
                error.RecordBusy => {
                    kept.appendAssumeCapacity(entry);
                    continue;
                },
                else => return err,
            };
            plans.appendAssumeCapacity(plan);
        }
        var catalog = try catalogLoad(self, self.allocator);
        defer catalog.deinit();
        for (catalog.entries.items) |descriptor| {
            const document = descriptor.document orelse continue;
            if (document.state == .tombstone or descriptor.entry.ended_ms >= cutoff) continue;
            var indexed = false;
            for (entries.items) |entry| if (std.mem.eql(u8, entry.cast_path, descriptor.entry.cast_path)) {
                indexed = true;
                break;
            };
            if (indexed) continue;
            const plan = makeRemovalPlanAt(self.allocator, self.io, self.dir, descriptor.entry.cast_path, descriptor.manifest_path) catch |err| switch (err) {
                error.RecordBusy => continue,
                else => return err,
            };
            plans.append(self.allocator, plan) catch |err| {
                var rejected = plan;
                rejected.deinit();
                return err;
            };
        }
        // Every dependency and every reservation is prepared before the first
        // deletion. Readers cannot observe a half removed artifact group.
        for (plans.items) |*plan| try plan.remove(self.io, self.dir, "RetentionExpired");
        if (plans.items.len != 0) {
            var buffer: [4096]u8 = undefined;
            var writer = atomic.file.writer(self.io, &buffer);
            for (kept.items) |entry| try writer.interface.print("{d}\t{d}\t{d}\t{d}\t{d}\t{s}\t{s}\t{s}\t{s}\t{d}\n", .{ entry.id, entry.started_ms, entry.ended_ms, entry.duration_ms, entry.exit_code orelse -2147483648, entry.host, entry.user, entry.cast_path, if (entry.source_kind) |kind| @tagName(kind) else "", entry.saved_connection_id orelse 0 });
            try writer.interface.flush();
            try atomic.file.sync(self.io);
            try atomic.replace(self.io);
        }
        return plans.items.len;
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
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
    }

    fn rewrite(self: *Archive, entries: []const Entry) !void {
        var buf: [4096]u8 = undefined;
        var atomic = try self.dir.createFileAtomic(self.io, self.index_path, .{ .permissions = @as(std.Io.File.Permissions, @fromBackingInt(@intCast(0o600))), .make_path = true, .replace = true });
        defer atomic.deinit(self.io);
        var writer = atomic.file.writer(self.io, &buf);
        for (entries) |entry| try writer.interface.print("{d}\t{d}\t{d}\t{d}\t{d}\t{s}\t{s}\t{s}\t{s}\t{d}\n", .{ entry.id, entry.started_ms, entry.ended_ms, entry.duration_ms, entry.exit_code orelse -2147483648, sanitize(entry.host), sanitize(entry.user), sanitize(entry.cast_path), if (entry.source_kind) |kind| @tagName(kind) else "", entry.saved_connection_id orelse 0 });
        try writer.interface.flush();
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
    }

    /// Releases strings and the list returned by `load`.  Callers that retain
    /// an archive index for a view/controller use this instead of duplicating
    /// the ownership rules.
    pub fn freeEntries(self: *Archive, entries: *std.ArrayList(Entry)) void {
        for (entries.items) |entry| {
            self.allocator.free(entry.host);
            self.allocator.free(entry.user);
            self.allocator.free(entry.cast_path);
        }
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

fn sanitize(value: []const u8) []const u8 {
    return value;
}
fn validateField(value: []const u8) !void {
    if (value.len == 0) return error.InvalidArchiveField;
    for (value) |byte| if (byte == '\t' or byte == '\n' or byte == '\r') return error.InvalidArchiveField;
}
fn parseU64(v: []const u8) ?u64 {
    return std.fmt.parseInt(u64, v, 10) catch null;
}
fn parseI64(v: []const u8) ?i64 {
    return std.fmt.parseInt(i64, v, 10) catch null;
}
fn validatePath(path: []const u8) !void {
    if (path.len == 0 or path[0] == '/') return error.InvalidArchivePath;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidArchivePath;
}

test "archive index tolerates partial lines and prunes cast files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var archive = Archive{ .allocator = std.testing.allocator, .io = std.testing.io, .dir = tmp.dir };
    try archive.append(.{ .id = 1, .started_ms = 0, .ended_ms = 1, .duration_ms = 1, .host = "h", .user = "u", .cast_path = "logs/history/a.cast" });
    try tmp.dir.createDirPath(std.testing.io, "logs/history");
    var f = try tmp.dir.createFile(std.testing.io, "logs/history/a.cast", .{});
    f.close(std.testing.io);
    var idx = try tmp.dir.openFile(std.testing.io, "logs/history/index.tsv", .{ .mode = .write_only });
    idx.close(std.testing.io);
    const prior = try tmp.dir.readFileAlloc(std.testing.io, "logs/history/index.tsv", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(prior);
    var merged = try std.testing.allocator.alloc(u8, prior.len + 7);
    defer std.testing.allocator.free(merged);
    @memcpy(merged[0..prior.len], prior);
    @memcpy(merged[prior.len..], "partial");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "logs/history/index.tsv", .data = merged });
    var loaded = try archive.load(std.testing.allocator);
    defer archive.freeEntries(&loaded);
    try std.testing.expectEqual(@as(usize, 1), loaded.items.len);
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
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = archive.index_path, .data = "1\t1\t2\t1\t0\tsame\tu\tlogs/history/1.cast\n" ++
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

/// Metadata owns no live terminal binding. A Catalog owns every referenced byte.
pub const Descriptor = struct {
    archive_key: []const u8,
    recording_id: ?[]const u8 = null,
    manifest_revision: u64 = 0,
    entry: Entry,
    title: []const u8 = "",
    endpoint: []const u8 = "",
    connection_id: ?u64 = null,
    config_revision: ?u64 = null,
    coverage: manifest.Coverage = .retained,
    replayability: manifest.Replayability = .legacy_unverified,
    failure: ?[]const u8 = null,
    manifest_path: ?[]const u8 = null,
    can_open: bool = true,
    display: manifest.Display = .{},
    document: ?manifest.Manifest = null,
};
pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Descriptor) = .empty,
    pub fn deinit(self: *Catalog) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
pub const RecordQuery = struct { archive_key: ?[]const u8 = null, recording_id: ?[]const u8 = null, execution_id: ?[]const u8 = null };
pub const ResolvedRecord = struct {
    catalog: Catalog,
    descriptor: Descriptor,
    execution_range: ?manifest.ExecutionRange = null,
    pub fn deinit(self: *ResolvedRecord) void {
        self.catalog.deinit();
    }
};
pub const RecordGroupLease = struct {
    allocator: std.mem.Allocator,
    leases: std.ArrayList(RecordLease) = .empty,
    cast_index: usize = 0,
    pub fn cast(self: *RecordGroupLease) *RecordLease {
        return &self.leases.items[self.cast_index];
    }
    pub fn deinit(self: *RecordGroupLease) void {
        for (self.leases.items) |*lease| lease.deinit();
        self.leases.deinit(self.allocator);
        self.leases = .empty;
    }
};

fn legacyKey(allocator: std.mem.Allocator, archive: *Archive, entry: Entry) ![]const u8 {
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_length = try archive.dir.realPath(archive.io, &root_buffer);
    const value = try std.fmt.allocPrint(allocator, "{s}:{d}:{d}:{s}", .{ root_buffer[0..root_length], entry.id, entry.started_ms, entry.cast_path });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &digest, .{});
    return std.fmt.allocPrint(allocator, "legacy-{s}", .{std.fmt.bytesToHex(digest, .lower)});
}
fn descriptorFromManifest(allocator: std.mem.Allocator, path: []const u8, value: manifest.Manifest) !Descriptor {
    const generation = value.recording.generations[0];
    var cast_path: []const u8 = "";
    for (value.files) |file| if (file.kind == .cast) {
        cast_path = file.path;
        break;
    };
    const ended = value.ended_ms orelse value.started_ms;
    return .{
        .archive_key = value.archive_key,
        .recording_id = value.recording_id,
        .manifest_revision = value.manifest_revision,
        .manifest_path = try allocator.dupe(u8, path),
        .entry = .{ .id = generation.session_id, .started_ms = value.started_ms, .ended_ms = ended, .duration_ms = @intCast(@max(0, ended - value.started_ms)), .host = value.display.host, .user = value.display.user, .cast_path = cast_path, .exit_code = value.exit_code, .source_kind = value.source_kind, .saved_connection_id = value.connection_id },
        .title = value.display.title,
        .endpoint = value.display.endpoint,
        .connection_id = value.connection_id,
        .config_revision = value.config_revision,
        .coverage = value.coverage,
        .replayability = value.replayability,
        .failure = value.failure orelse if (value.commit.state == .pending_index) "IndexPending" else null,
        .can_open = value.state != .tombstone and value.state != .unavailable and value.coverage != .unavailable and value.replayability != .baseline_unavailable and value.replayability != .unsupported and cast_path.len > 0,
        .display = value.display,
        .document = value,
    };
}
pub const max_catalog_metadata_bytes: usize = 16 * 1024 * 1024;
fn catalogLoad(archive: *Archive, allocator: std.mem.Allocator) !Catalog {
    return catalogLoadWithActive(archive, allocator, false);
}
fn catalogLoadWithActive(archive: *Archive, allocator: std.mem.Allocator, include_active: bool) !Catalog {
    var out: Catalog = .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    errdefer out.deinit();
    const owned = out.arena.allocator();
    // Scan only the application's bounded archive directory. A sidecar commit
    // remains discoverable even if the subsequent TSV replace failed/crashed.
    const history = archive.dir.openDir(archive.io, "logs/history", .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return out,
        else => return err,
    };
    defer history.close(archive.io);
    var iterator = history.iterate();
    var scanned: usize = 0;
    var metadata_bytes: u64 = 0;
    while (try iterator.next(archive.io)) |file| {
        scanned += 1;
        if (scanned > 16384) return error.CatalogLimit;
        if (file.kind != .file or !std.mem.endsWith(u8, file.name, ".session.json")) continue;
        const path = try std.fmt.allocPrint(owned, "logs/history/{s}", .{file.name});
        const metadata_file = try manifest.openManaged(archive.io, archive.dir, path);
        const metadata_stat = metadata_file.stat(archive.io) catch |err| {
            metadata_file.close(archive.io);
            return err;
        };
        metadata_file.close(archive.io);
        if (metadata_stat.size > max_catalog_metadata_bytes -| metadata_bytes) return error.CatalogLimit;
        metadata_bytes += metadata_stat.size;
        const sized = manifest.loadSized(archive.allocator, archive.io, archive.dir, path) catch |err| {
            if (err == error.OutOfMemory) return err;
            const failure_entry: Entry = .{ .id = 0, .started_ms = 0, .ended_ms = 0, .duration_ms = 0, .host = "", .user = "", .cast_path = path };
            var failed: Descriptor = .{ .archive_key = try legacyKey(owned, archive, failure_entry), .entry = failure_entry, .title = try owned.dupe(u8, file.name), .manifest_path = path, .coverage = .unavailable, .replayability = .unsupported, .failure = @errorName(err), .can_open = false };
            if (readManifestIdentity(owned, archive.allocator, archive.io, archive.dir, path)) |header| {
                failed.archive_key = header.archive_key;
                failed.recording_id = header.recording_id;
            } else |header_error| if (header_error == error.OutOfMemory) return header_error;
            try out.entries.append(owned, failed);
            continue;
        };
        const parsed = sized.parsed;
        defer parsed.deinit();
        if (sized.source_length > metadata_stat.size) {
            const extra = sized.source_length - metadata_stat.size;
            if (extra > max_catalog_metadata_bytes -| metadata_bytes) return error.CatalogLimit;
            metadata_bytes += extra;
        }
        if (!include_active and (parsed.value.state == .tombstone or (parsed.value.state == .active and isActiveRecord(parsed.value.archive_key)))) continue;
        // Catalog rows retain display/identity/file metadata only. Detailed
        // event/range/baseline arrays are loaded for the single resolver target.
        var projection = parsed.value;
        projection.events = &.{};
        projection.execution_ranges = &.{};
        projection.gaps = &.{};
        const generations = try archive.allocator.dupe(manifest.Generation, projection.recording.generations);
        defer archive.allocator.free(generations);
        for (generations) |*generation| {
            generation.segments = &.{};
            generation.baselines = &.{};
        }
        projection.recording.generations = generations;
        const encoded = try std.json.Stringify.valueAlloc(archive.allocator, projection, .{});
        defer archive.allocator.free(encoded);
        const copy = try std.json.parseFromSliceLeaky(manifest.Manifest, owned, encoded, .{ .allocate = .alloc_always });
        var descriptor = try descriptorFromManifest(owned, path, copy);
        if (copy.state == .active and !isActiveRecord(copy.archive_key)) {
            descriptor.coverage = .partial;
            descriptor.failure = "AbnormalTermination";
        }
        if (descriptor.can_open) {
            const data = manifest.openManaged(archive.io, archive.dir, descriptor.entry.cast_path) catch |err| {
                descriptor.can_open = false;
                descriptor.failure = @errorName(err);
                try out.entries.append(owned, descriptor);
                continue;
            };
            data.close(archive.io);
        }
        var duplicate = false;
        for (out.entries.items) |existing| if (std.mem.eql(u8, existing.archive_key, descriptor.archive_key)) {
            duplicate = true;
            break;
        };
        if (!duplicate) try out.entries.append(owned, descriptor);
    }
    if (archive.dir.openFile(archive.io, archive.index_path, .{ .follow_symlinks = false })) |index_file| {
        defer index_file.close(archive.io);
        if ((try index_file.stat(archive.io)).size > max_catalog_metadata_bytes -| metadata_bytes) return error.CatalogLimit;
    } else |err| if (err != error.FileNotFound) return err;
    const remaining: usize = @intCast(max_catalog_metadata_bytes -| metadata_bytes);
    var entries = archive.loadBounded(archive.allocator, remaining, 16384) catch |err| switch (err) {
        error.StreamTooLong => return error.CatalogLimit,
        else => return err,
    };
    defer archive.freeEntries(&entries);
    for (entries.items) |entry| {
        const sidecar_path = try manifest.pathForCast(owned, entry.cast_path);
        // Even an unknown/broken manifest must not grant legacy exact replay.
        if (manifest.openManaged(archive.io, archive.dir, sidecar_path)) |file| {
            file.close(archive.io);
            continue;
        } else |err| if (err != error.FileNotFound) continue;
        var descriptor: Descriptor = .{ .archive_key = try legacyKey(owned, archive, entry), .entry = entry, .title = entry.host, .connection_id = entry.saved_connection_id };
        descriptor.entry.host = try owned.dupe(u8, entry.host);
        descriptor.entry.user = try owned.dupe(u8, entry.user);
        descriptor.entry.cast_path = try owned.dupe(u8, entry.cast_path);
        descriptor.title = descriptor.entry.host;
        if (manifest.openManaged(archive.io, archive.dir, entry.cast_path)) |file| file.close(archive.io) else |err| {
            descriptor.can_open = false;
            descriptor.failure = @errorName(err);
        }
        var duplicate = false;
        for (out.entries.items) |existing| if (std.mem.eql(u8, existing.archive_key, descriptor.archive_key)) {
            duplicate = true;
            break;
        };
        if (!duplicate) try out.entries.append(owned, descriptor);
    }
    if (out.entries.items.len > 16384) return error.CatalogLimit;
    const Sort = struct {
        fn less(_: void, a: Descriptor, b: Descriptor) bool {
            return a.entry.ended_ms > b.entry.ended_ms;
        }
    };
    std.mem.sort(Descriptor, out.entries.items, {}, Sort.less);
    return out;
}
fn catalogResolve(archive: *Archive, allocator: std.mem.Allocator, query: RecordQuery) !ResolvedRecord {
    if ((query.archive_key == null) == (query.recording_id == null)) return error.InvalidRecordQuery;
    var catalog = try catalogLoadWithActive(archive, allocator, true);
    errdefer catalog.deinit();
    for (catalog.entries.items) |descriptor| {
        const matches = if (query.archive_key) |key| std.mem.eql(u8, descriptor.archive_key, key) else if (descriptor.recording_id) |id| std.mem.eql(u8, id, query.recording_id.?) else false;
        if (!matches) continue;
        if (descriptor.document) |document| if (document.state == .tombstone) return error.RecordRemoved;
        var resolved_descriptor = descriptor;
        if (descriptor.manifest_path) |path| if (descriptor.document != null) {
            const parsed = try manifest.load(allocator, archive.io, archive.dir, path);
            defer parsed.deinit();
            if (parsed.value.manifest_revision != descriptor.manifest_revision or !std.mem.eql(u8, parsed.value.archive_key, descriptor.archive_key)) return error.CatalogChanged;
            const encoded = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
            defer allocator.free(encoded);
            resolved_descriptor.document = try std.json.parseFromSliceLeaky(manifest.Manifest, catalog.arena.allocator(), encoded, .{ .allocate = .alloc_always });
        };
        var range: ?manifest.ExecutionRange = null;
        if (query.execution_id) |id| {
            const document = resolved_descriptor.document orelse return error.ExactRangeUnavailable;
            for (document.execution_ranges) |candidate| if (std.mem.eql(u8, id, candidate.execution_id)) {
                range = candidate;
                break;
            };
            if (range == null) return error.ExecutionRangeNotFound;
        }
        return .{ .catalog = catalog, .descriptor = resolved_descriptor, .execution_range = range };
    }
    return error.RecordNotFound;
}
fn catalogAcquire(archive: *Archive, allocator: std.mem.Allocator, descriptor: Descriptor, purpose: enum { replay, export_retained }) !RecordGroupLease {
    if (purpose == .replay and !descriptor.can_open) return error.RecordingUnavailable;
    if (purpose == .export_retained and (descriptor.coverage == .unavailable or descriptor.replayability == .unsupported or (descriptor.manifest_path == null and !descriptor.can_open))) return error.RecordingUnavailable;
    var result: RecordGroupLease = .{ .allocator = allocator };
    errdefer result.deinit();
    try result.leases.ensureUnusedCapacity(allocator, 1);
    if (descriptor.manifest_path) |path| {
        result.leases.appendAssumeCapacity(try acquireLease(allocator, archive.io, archive.dir, path));
        const bytes = try result.leases.items[0].readAll(allocator, 8 * 1024 * 1024);
        defer allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(manifest.Manifest, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
        defer parsed.deinit();
        try manifest.validate(parsed.value);
        if (!std.mem.eql(u8, descriptor.archive_key, parsed.value.archive_key) or descriptor.manifest_revision != parsed.value.manifest_revision) return error.CatalogChanged;
        if (parsed.value.state == .tombstone or parsed.value.coverage == .unavailable or parsed.value.replayability == .unsupported) return error.RecordingUnavailable;
        if (purpose == .replay and parsed.value.replayability == .baseline_unavailable) return error.RecordingUnavailable;
        try result.leases.ensureUnusedCapacity(allocator, parsed.value.files.len);
        var found_cast = false;
        for (parsed.value.files) |file| {
            var lease = try acquireLease(allocator, archive.io, archive.dir, file.path);
            errdefer lease.deinit();
            if (lease.stat.size != file.committed_length) return error.RecordingChanged;
            const checksum = try manifest.fingerprint(archive.io, lease.file, file.committed_length);
            if (!std.mem.eql(u8, &checksum, file.checksum)) return error.RecordingChecksumMismatch;
            if (file.kind == .cast) {
                result.cast_index = result.leases.items.len;
                found_cast = true;
            }
            result.leases.appendAssumeCapacity(lease);
        }
        if (!found_cast) return error.RecordingUnavailable;
    } else {
        result.leases.appendAssumeCapacity(try acquireLease(allocator, archive.io, archive.dir, descriptor.entry.cast_path));
    }
    return result;
}

/// Called only while the complete removal group is reserved. Keeping the same
/// identity makes stale AI cards and global history resolve the same removal.
pub fn writeTombstone(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, reason: []const u8) !void {
    const parsed = try manifest.load(allocator, io, dir, path);
    defer parsed.deinit();
    if (parsed.value.state == .tombstone) return;
    var value = parsed.value;
    value.manifest_revision = try std.math.add(u64, value.manifest_revision, 1);
    value.state = .tombstone;
    value.coverage = .unavailable;
    value.replayability = .unsupported;
    value.failure = reason;
    value.execution_ranges = &.{};
    value.events = &.{};
    value.gaps = &.{};
    value.display = .{};
    value.commit.state = .removed;
    try manifest.save(allocator, io, dir, path, value);
}

test "archive catalog recovers manifest before index commit and freezes every dependency" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cast_path = "logs/history/session-local-1-2-3-4.cast";
    try tmp.dir.createDirPath(std.testing.io, "logs/history");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = cast_path, .data = "cast" });
    const cast = try manifest.openManaged(std.testing.io, tmp.dir, cast_path);
    defer cast.close(std.testing.io);
    const checksum = try manifest.fingerprint(std.testing.io, cast, 4);
    const manifest_path = try manifest.pathForCast(std.testing.allocator, cast_path);
    defer std.testing.allocator.free(manifest_path);
    const generation: manifest.Generation = .{ .session_id = 3, .session_generation = 4, .initial_cols = 80, .initial_rows = 24, .receive_time_origin = 1 };
    try manifest.save(std.testing.allocator, std.testing.io, tmp.dir, manifest_path, .{
        .archive_key = "11111111111111111111111111111111",
        .recording_id = "22222222222222222222222222222222",
        .source_kind = .local,
        .started_ms = 1,
        .ended_ms = 2,
        .state = .closed,
        .recording = .{ .generations = &.{generation} },
        .display = .{ .title = "saved", .host = "local", .user = "zsh" },
        .coverage = .complete,
        .files = &.{.{ .path = cast_path, .kind = .cast, .committed_length = 4, .checksum = &checksum }},
        .commit = .{ .state = .pending_index },
    });
    var archive: Archive = .{ .allocator = std.testing.allocator, .io = std.testing.io, .dir = tmp.dir };
    var record = try archive.resolveRecord(std.testing.allocator, .{ .recording_id = "22222222222222222222222222222222" });
    defer record.deinit();
    try std.testing.expectEqualStrings("IndexPending", record.descriptor.failure.?);
    var group = try archive.acquireRecord(std.testing.allocator, record.descriptor);
    defer group.deinit();
    try std.testing.expectEqual(@as(usize, 2), group.leases.items.len);
    try std.testing.expectError(error.RecordBusy, reserveRemoval(std.testing.allocator, std.testing.io, tmp.dir, cast_path));
    const bytes = try group.cast().readAll(std.testing.allocator, 64);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("cast", bytes);
    group.deinit();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = cast_path, .data = "tamp" });
    try std.testing.expectError(error.RecordingChecksumMismatch, archive.acquireRecord(std.testing.allocator, record.descriptor));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = cast_path, .data = "cast" });
    var guard = try reserveRemoval(std.testing.allocator, std.testing.io, tmp.dir, cast_path);
    defer guard.deinit();
    try writeTombstone(std.testing.allocator, std.testing.io, tmp.dir, manifest_path, "UserRemoved");
    try std.testing.expectError(error.RecordRemoved, archive.resolveRecord(std.testing.allocator, .{ .archive_key = "11111111111111111111111111111111" }));
}

test "archive legacy keys are stable and never expose exact execution ranges" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var archive: Archive = .{ .allocator = std.testing.allocator, .io = std.testing.io, .dir = tmp.dir };
    try archive.append(.{ .id = 1, .started_ms = 1, .ended_ms = 2, .duration_ms = 1, .host = "h", .user = "u", .cast_path = "logs/history/old.cast" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "logs/history/old.cast", .data = "old" });
    var first = try archive.loadCatalog(std.testing.allocator);
    defer first.deinit();
    var second = try archive.loadCatalog(std.testing.allocator);
    defer second.deinit();
    try std.testing.expectEqualStrings(first.entries.items[0].archive_key, second.entries.items[0].archive_key);
    try std.testing.expectEqual(manifest.Replayability.legacy_unverified, first.entries.items[0].replayability);
    try std.testing.expectError(error.ExactRangeUnavailable, archive.resolveRecord(std.testing.allocator, .{ .archive_key = first.entries.items[0].archive_key, .execution_id = "11111111111111111111111111111111" }));
}

// Writer liveness is process memory, never guessed from a saved PID or host.
// The data-scope lock already excludes other application writers for this root.
var active_records: [4096][32]u8 = undefined;
var active_record_count: usize = 0;
var active_record_mutex: std.atomic.Mutex = .unlocked;
pub fn setActiveRecord(key: []const u8, active: bool) !void {
    if (key.len != 32) return error.InvalidArchiveKey;
    while (!active_record_mutex.tryLock()) std.atomic.spinLoopHint();
    defer active_record_mutex.unlock();
    for (active_records[0..active_record_count], 0..) |existing, index| if (std.mem.eql(u8, &existing, key)) {
        if (!active) {
            active_record_count -= 1;
            active_records[index] = active_records[active_record_count];
        }
        return;
    };
    if (!active) return;
    if (active_record_count == active_records.len) return error.ActiveRecordingLimit;
    active_records[active_record_count] = key[0..32].*;
    active_record_count += 1;
}
fn isActiveRecord(key: []const u8) bool {
    while (!active_record_mutex.tryLock()) std.atomic.spinLoopHint();
    defer active_record_mutex.unlock();
    for (active_records[0..active_record_count]) |existing| if (std.mem.eql(u8, &existing, key)) return true;
    return false;
}

const RemovalPlan = struct {
    allocator: std.mem.Allocator,
    paths: std.ArrayList([]const u8) = .empty,
    manifest_path: ?[]const u8 = null,
    guards: RemovalSet,
    fn deinit(self: *RemovalPlan) void {
        self.guards.deinit();
        for (self.paths.items) |path| self.allocator.free(path);
        self.paths.deinit(self.allocator);
    }
    fn remove(self: *RemovalPlan, io: std.Io, dir: std.Io.Dir, reason: []const u8) !void {
        if (self.manifest_path) |path| try writeTombstone(self.allocator, io, dir, path, reason);
        for (self.paths.items) |path| {
            if (self.manifest_path) |sidecar| if (std.mem.eql(u8, path, sidecar)) continue;
            dir.deleteFile(io, path) catch |err| if (err != error.FileNotFound) return err;
        }
    }
};
fn makeRemovalPlan(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, cast_path: []const u8) !RemovalPlan {
    return makeRemovalPlanAt(allocator, io, dir, cast_path, null);
}
fn makeRemovalPlanAt(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, cast_path: []const u8, known_manifest_path: ?[]const u8) !RemovalPlan {
    var plan: RemovalPlan = .{ .allocator = allocator, .guards = .{ .allocator = allocator } };
    errdefer plan.deinit();
    const sidecar = if (known_manifest_path) |path| try allocator.dupe(u8, path) else try manifest.pathForCast(allocator, cast_path);
    defer allocator.free(sidecar);
    if (manifest.load(allocator, io, dir, sidecar)) |parsed| {
        defer parsed.deinit();
        for (parsed.value.files) |file| try appendRemovalPath(&plan, file.path);
        try appendRemovalPath(&plan, sidecar);
        plan.manifest_path = plan.paths.items[plan.paths.items.len - 1];
    } else |err| switch (err) {
        error.FileNotFound => {
            try appendRemovalPath(&plan, cast_path);
            if (localStem(cast_path)) |stem| for ([_][]const u8{ ".raw", ".checkpoint" }) |suffix| {
                const path = try std.fmt.allocPrint(allocator, "logs/{s}{s}", .{ stem, suffix });
                defer allocator.free(path);
                try appendRemovalPath(&plan, path);
            };
        },
        else => return err,
    }
    plan.guards = try reserveRemovals(allocator, io, dir, plan.paths.items);
    return plan;
}

fn appendRemovalPath(plan: *RemovalPlan, path: []const u8) !void {
    try plan.paths.ensureUnusedCapacity(plan.allocator, 1);
    plan.paths.appendAssumeCapacity(try plan.allocator.dupe(u8, path));
}

const ManifestIdentity = struct { archive_key: []const u8, recording_id: []const u8 };
fn readManifestIdentity(allocator: std.mem.Allocator, scratch: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !ManifestIdentity {
    const file = try manifest.openManaged(io, dir, path);
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size > 8 * 1024 * 1024) return error.ManifestTooLarge;
    const bytes = try scratch.alloc(u8, @intCast(stat.size));
    defer scratch.free(bytes);
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.RecordingTruncated;
    const parsed = try std.json.parseFromSlice(ManifestIdentity, scratch, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    const header = parsed.value;
    if (header.archive_key.len != 32 or header.recording_id.len != 32) return error.InvalidManifest;
    var id: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&id, header.archive_key) catch return error.InvalidManifest;
    _ = std.fmt.hexToBytes(&id, header.recording_id) catch return error.InvalidManifest;
    return .{ .archive_key = try allocator.dupe(u8, header.archive_key), .recording_id = try allocator.dupe(u8, header.recording_id) };
}

test "archive SSH publisher reserves identity and commits the existing timeline once" {
    const publisher = @import("ssh_recording_manifest.zig");
    const identity = @import("../host/identity.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var timeline = try @import("timeline.zig").Timeline.init(std.testing.allocator, 16, 4096);
    defer timeline.deinit();
    try timeline.append(1, 0, "first");
    try timeline.appendResize(2, 5, 100, 30);
    try timeline.append(3, 5, "two");
    const generations = [_]manifest.Generation{
        .{ .session_id = 9, .session_generation = 1, .initial_cols = 80, .initial_rows = 24, .receive_time_origin = 1 },
        .{ .recording_generation = 2, .raw_offset_start = 5, .event_sequence_start = 2, .session_id = 9, .session_generation = 2, .initial_cols = 100, .initial_rows = 30, .receive_time_origin = 2 },
    };
    var options: publisher.Options = .{ .recording_id = try identity.RecordingId.parse("33333333333333333333333333333333"), .archive_key = try identity.ArchiveKey.parse("44444444444444444444444444444444"), .generations = &generations, .cast_path = "logs/history/ssh-manifest.cast", .started_ms = 1, .display = .{ .title = "SSH source", .host = "saved server", .user = "user" }, .connection_id = 42 };
    try publisher.reserve(std.testing.allocator, std.testing.io, tmp.dir, options);
    defer setActiveRecord("44444444444444444444444444444444", false) catch {};
    options.timeline = &timeline;
    options.ended_ms = 4;
    options.total_received = 8;
    const receipt = try publisher.publish(std.testing.allocator, std.testing.io, tmp.dir, options);
    try std.testing.expectEqual(manifest.Coverage.complete, receipt.coverage);
    var archive: Archive = .{ .allocator = std.testing.allocator, .io = std.testing.io, .dir = tmp.dir };
    var listing = try archive.loadCatalog(std.testing.allocator);
    defer listing.deinit();
    try std.testing.expectEqual(@as(usize, 0), listing.entries.items[0].document.?.events.len);
    try std.testing.expectEqual(@as(usize, 0), listing.entries.items[0].document.?.execution_ranges.len);
    try std.testing.expectEqual(@as(usize, 0), listing.entries.items[0].document.?.recording.generations[0].segments.len);
    var resolved = try archive.resolveRecord(std.testing.allocator, .{ .recording_id = "33333333333333333333333333333333" });
    defer resolved.deinit();
    const document = resolved.descriptor.document.?;
    try std.testing.expectEqual(@as(usize, 2), document.recording.generations.len);
    try std.testing.expectEqual(@as(u64, 2), document.recording.generations[1].session_generation);
    try std.testing.expectEqual(@as(u64, 5), document.recording.generations[0].segments[0].end.raw_offset);
    try std.testing.expectEqual(@as(usize, 3), document.events.len);
    var lease = try archive.acquireRecord(std.testing.allocator, resolved.descriptor);
    defer lease.deinit();
    const again = try publisher.publish(std.testing.allocator, std.testing.io, tmp.dir, options);
    try std.testing.expectEqual(receipt.manifest_revision, again.manifest_revision);
    var rows = try archive.load(std.testing.allocator);
    defer archive.freeEntries(&rows);
    try std.testing.expectEqual(@as(usize, 1), rows.items.len);
    try std.testing.expectEqual(@as(?u64, 42), rows.items[0].saved_connection_id);
}

test "archive legacy catalog preserves only an explicit saved connection identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "logs/history");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "logs/history/index.tsv", .data = "1\t1\t2\t1\t0\tsame host\tu\tlogs/history/old.cast\n" ++
        "2\t3\t4\t1\t0\tsame host\tu\tlogs/history/extended.cast\tssh\t42\n" });
    var archive: Archive = .{ .allocator = std.testing.allocator, .io = std.testing.io, .dir = tmp.dir };
    var catalog = try archive.loadCatalog(std.testing.allocator);
    defer catalog.deinit();
    try std.testing.expectEqual(@as(usize, 2), catalog.entries.items.len);
    try std.testing.expectEqual(@as(?u64, 42), catalog.entries.items[0].connection_id);
    try std.testing.expectEqual(@as(?u64, null), catalog.entries.items[1].connection_id);
}

test "archive retained export pins and verifies content without granting accurate replay" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cast_path = "logs/history/retained.cast";
    const sidecar = "logs/history/retained.session.json";
    try tmp.dir.createDirPath(std.testing.io, "logs/history");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = cast_path, .data = "real retained bytes" });
    const file = try manifest.openManaged(std.testing.io, tmp.dir, cast_path);
    defer file.close(std.testing.io);
    const length = (try file.stat(std.testing.io)).size;
    const checksum = try manifest.fingerprint(std.testing.io, file, length);
    const generation: manifest.Generation = .{ .session_id = 1, .session_generation = 1, .initial_cols = 80, .initial_rows = 24, .receive_time_origin = 1 };
    try manifest.save(std.testing.allocator, std.testing.io, tmp.dir, sidecar, .{
        .archive_key = "11111111111111111111111111111111",
        .recording_id = "22222222222222222222222222222222",
        .source_kind = .local,
        .started_ms = 1,
        .ended_ms = 2,
        .state = .closed,
        .recording = .{ .generations = &.{generation} },
        .coverage = .retained,
        .replayability = .baseline_unavailable,
        .files = &.{.{ .path = cast_path, .kind = .cast, .committed_length = length, .checksum = &checksum }},
    });
    var archive: Archive = .{ .allocator = std.testing.allocator, .io = std.testing.io, .dir = tmp.dir };
    var record = try archive.resolveRecord(std.testing.allocator, .{ .recording_id = "22222222222222222222222222222222" });
    defer record.deinit();
    try std.testing.expect(!record.descriptor.can_open);
    try std.testing.expectError(error.RecordingUnavailable, archive.acquireRecord(std.testing.allocator, record.descriptor));
    var lease = try archive.acquireRecordForExport(std.testing.allocator, record.descriptor);
    defer lease.deinit();
    const bytes = try lease.cast().readAll(std.testing.allocator, 4096);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("real retained bytes", bytes);
    try std.testing.expectError(error.RecordBusy, reserveRemoval(std.testing.allocator, std.testing.io, tmp.dir, cast_path));
    lease.deinit();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = cast_path, .data = "fake retained bytes" });
    try std.testing.expectError(error.RecordingChecksumMismatch, archive.acquireRecordForExport(std.testing.allocator, record.descriptor));
    var rejected = record.descriptor;
    rejected.coverage = .unavailable;
    try std.testing.expectError(error.RecordingUnavailable, archive.acquireRecordForExport(std.testing.allocator, rejected));
    rejected = record.descriptor;
    rejected.replayability = .unsupported;
    try std.testing.expectError(error.RecordingUnavailable, archive.acquireRecordForExport(std.testing.allocator, rejected));
}

/// A non-recorded terminal still owns one stable catalog identity. The caller
/// keeps this with its existing session state; it is not a recording engine.
pub const MetadataIdentity = struct {
    recording_id: record_identity.RecordingId,
    archive_key: record_identity.ArchiveKey,
    pub fn generate() MetadataIdentity {
        return .{ .recording_id = record_identity.RecordingId.generate(), .archive_key = record_identity.ArchiveKey.generate() };
    }
};
pub const UnavailableReason = enum { RecordingDisabled, NotRecorded, RecordingUnavailable };
pub const MetadataPublication = struct {
    identity: MetadataIdentity,
    owner: record_identity.SessionHandle,
    source_kind: SourceKind,
    recording_generation: u64 = 1,
    started_ms: i64,
    ended_ms: i64,
    initial_cols: u16,
    initial_rows: u16,
    display: manifest.Display,
    connection_id: ?u64 = null,
    config_revision: ?u64 = null,
    reason: UnavailableReason,
    /// Only error codes/non-secret facts; Disabled/NotRecorded never mask IO
    /// errors. Those use RecordingUnavailable with their actual failure code.
    failure: ?[]const u8 = null,
    exit_code: ?i32 = null,
    end_reason: ?[]const u8 = null,
    retention_days: u16 = 0,
};
pub const MetadataReceipt = struct { manifest_revision: u64, removed: bool = false };

fn publishMetadataOnly(archive: *Archive, options: MetadataPublication) !MetadataReceipt {
    if (!options.identity.recording_id.valid() or !options.identity.archive_key.valid() or options.recording_generation == 0 or @backingInt(options.owner.session_id) == 0 or options.owner.generation == 0 or options.initial_cols == 0 or options.initial_rows == 0 or options.ended_ms < options.started_ms) return error.InvalidRecordingMetadata;
    if (options.connection_id) |id| if (id == 0 or options.source_kind != .ssh) return error.InvalidArchiveIdentity;
    if (options.reason != .RecordingUnavailable and options.failure != null) return error.InvalidRecordingReason;
    const key = std.fmt.bytesToHex(options.identity.archive_key.bytes, .lower);
    const id = std.fmt.bytesToHex(options.identity.recording_id.bytes, .lower);
    const path = try std.fmt.allocPrint(archive.allocator, "logs/history/session-{s}.session.json", .{key});
    defer archive.allocator.free(path);
    // Serialize metadata publication with retention/index ownership. A delayed
    // close receipt cannot recreate a record that explicit cleanup tombstoned.
    lockIndex();
    var index_locked = true;
    defer if (index_locked) index_mutex.unlock();
    if (manifest.load(archive.allocator, archive.io, archive.dir, path)) |existing| {
        defer existing.deinit();
        if (!std.mem.eql(u8, existing.value.archive_key, &key) or !std.mem.eql(u8, existing.value.recording_id, &id)) return error.RecordingIdentityChanged;
        const generation = existing.value.recording.generations[0];
        if (generation.session_id != @backingInt(options.owner.session_id) or generation.session_generation != options.owner.generation or generation.recording_generation != options.recording_generation or existing.value.source_kind != options.source_kind or existing.value.started_ms != options.started_ms) return error.RecordingIdentityChanged;
        if (existing.value.state == .tombstone) return .{ .manifest_revision = existing.value.manifest_revision, .removed = true };
        if (existing.value.state != .unavailable or existing.value.files.len != 0) return error.RecordingHasContent;
        return .{ .manifest_revision = existing.value.manifest_revision };
    } else |err| if (err != error.FileNotFound) return err;
    const generation: manifest.Generation = .{ .recording_generation = options.recording_generation, .session_id = @backingInt(options.owner.session_id), .session_generation = options.owner.generation, .initial_cols = options.initial_cols, .initial_rows = options.initial_rows, .receive_time_origin = options.started_ms };
    var display = options.display;
    if (display.final_cols == 0) display.final_cols = options.initial_cols;
    if (display.final_rows == 0) display.final_rows = options.initial_rows;
    try manifest.save(archive.allocator, archive.io, archive.dir, path, .{ .archive_key = &key, .recording_id = &id, .source_kind = options.source_kind, .connection_id = options.connection_id, .config_revision = options.config_revision, .started_ms = options.started_ms, .ended_ms = options.ended_ms, .exit_code = options.exit_code, .end_reason = options.end_reason, .state = .unavailable, .display = display, .recording = .{ .generations = &.{generation} }, .coverage = .unavailable, .replayability = .unsupported, .failure = options.failure orelse @tagName(options.reason), .commit = .{ .state = .metadata_only } });
    index_mutex.unlock();
    index_locked = false;
    // The existing retention path discovers sidecars without TSV rows too.
    _ = try archive.prune(options.retention_days, options.ended_ms);
    return .{ .manifest_revision = 1 };
}

test "archive unrecorded metadata publishes once without a cast and retains a real disabled reason" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var archive: Archive = .{ .allocator = std.testing.allocator, .io = std.testing.io, .dir = tmp.dir };
    const ids = MetadataIdentity.generate();
    const key = std.fmt.bytesToHex(ids.archive_key.bytes, .lower);
    const id = std.fmt.bytesToHex(ids.recording_id.bytes, .lower);
    var options: MetadataPublication = .{ .identity = ids, .owner = .{ .session_id = @fromBackingInt(5), .generation = 2 }, .source_kind = .local, .started_ms = 1, .ended_ms = 2, .initial_cols = 80, .initial_rows = 24, .display = .{ .title = "unrecorded local", .host = "local", .cwd = "/actual/cwd", .grouped = true }, .reason = .RecordingDisabled };
    const first = try archive.publishMetadata(options);
    options.display.title = "late duplicate callback";
    const again = try archive.publishMetadata(options);
    try std.testing.expectEqual(first.manifest_revision, again.manifest_revision);
    var catalog = try archive.loadCatalog(std.testing.allocator);
    defer catalog.deinit();
    try std.testing.expectEqual(@as(usize, 1), catalog.entries.items.len);
    const descriptor = catalog.entries.items[0];
    try std.testing.expectEqualStrings(&key, descriptor.archive_key);
    try std.testing.expectEqualStrings(&id, descriptor.recording_id.?);
    try std.testing.expectEqualStrings("RecordingDisabled", descriptor.failure.?);
    try std.testing.expectEqualStrings("unrecorded local", descriptor.title);
    try std.testing.expect(descriptor.display.grouped and !descriptor.can_open);
    try std.testing.expectEqual(@as(usize, 0), descriptor.document.?.files.len);
    try std.testing.expectEqual(@as(usize, 0), descriptor.entry.cast_path.len);
    try std.testing.expectError(error.RecordingUnavailable, archive.acquireRecord(std.testing.allocator, descriptor));
    try std.testing.expectError(error.RecordingUnavailable, archive.acquireRecordForExport(std.testing.allocator, descriptor));
    var rows = try archive.load(std.testing.allocator);
    defer archive.freeEntries(&rows);
    try std.testing.expectEqual(@as(usize, 0), rows.items.len);
    const fake_cast = try std.fmt.allocPrint(std.testing.allocator, "logs/history/session-{s}.cast", .{key});
    defer std.testing.allocator.free(fake_cast);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, fake_cast, .{}));
    try std.testing.expectEqual(@as(usize, 1), try archive.prune(1, 2 + 2 * std.time.ms_per_day));
    try std.testing.expectError(error.RecordRemoved, archive.resolveRecord(std.testing.allocator, .{ .recording_id = &id }));
    try std.testing.expect((try archive.publishMetadata(options)).removed);
    var after = try archive.loadCatalog(std.testing.allocator);
    defer after.deinit();
    try std.testing.expectEqual(@as(usize, 0), after.entries.items.len);
}

test "archive unrecorded metadata never labels an actual writer failure as disabled" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var archive: Archive = .{ .allocator = std.testing.allocator, .io = std.testing.io, .dir = tmp.dir };
    var options: MetadataPublication = .{ .identity = MetadataIdentity.generate(), .owner = .{ .session_id = @fromBackingInt(6) }, .source_kind = .ssh, .started_ms = 1, .ended_ms = 2, .initial_cols = 80, .initial_rows = 24, .display = .{ .title = "SSH", .host = "server", .user = "user" }, .connection_id = 42, .reason = .RecordingDisabled, .failure = "AccessDenied" };
    try std.testing.expectError(error.InvalidRecordingReason, archive.publishMetadata(options));
    options.reason = .RecordingUnavailable;
    _ = try archive.publishMetadata(options);
    const id = std.fmt.bytesToHex(options.identity.recording_id.bytes, .lower);
    var resolved = try archive.resolveRecord(std.testing.allocator, .{ .recording_id = &id });
    defer resolved.deinit();
    try std.testing.expectEqualStrings("AccessDenied", resolved.descriptor.failure.?);
    try std.testing.expectEqual(@as(?u64, 42), resolved.descriptor.connection_id);
}

test "archive catalog rejects cumulative metadata beyond its budget without returning a truncated list" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var archive: Archive = .{ .allocator = std.testing.allocator, .io = std.testing.io, .dir = tmp.dir };
    const title = try std.testing.allocator.alloc(u8, 6 * 1024 * 1024);
    defer std.testing.allocator.free(title);
    @memset(title, 'x');
    for (0..3) |index| _ = try archive.publishMetadata(.{ .identity = MetadataIdentity.generate(), .owner = .{ .session_id = @fromBackingInt(index + 1) }, .source_kind = .local, .started_ms = 1, .ended_ms = 2, .initial_cols = 80, .initial_rows = 24, .display = .{ .title = title }, .reason = .RecordingDisabled });
    try std.testing.expectError(error.CatalogLimit, archive.loadCatalog(std.testing.allocator));
}
