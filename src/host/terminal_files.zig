//! Bounded terminal-owned files. No SFTP, model image blocks or PTY IO.
const std = @import("std");
const identity = @import("identity.zig");
const provider = @import("../ai/provider.zig");
pub const text_limit = 64 * 1024;
pub const Edit = struct { old_text: []const u8, new_text: []const u8 };
pub const Kind = enum { read_text, write_text, edit_text, read_image };
pub const Request = struct {
    kind: Kind,
    path: []const u8,
    text: []const u8 = "",
    mode: enum { create, replace } = .create,
    expected_version: []const u8 = "",
    edits: []const Edit = &.{},
    offset: usize = 0,
    max_bytes: usize = 4096,
    /// Host-only service identity; never a model argument.
    version_scope: u64 = 0,
    version_stamp: []const u8 = "",
    app_data_root: ?[]const u8 = null,
};
pub const Result = struct {
    bytes: []const u8 = "",
    version: [64]u8 = @splat(0),
    committed: bool = false,
    verified: bool = false,
    outcome_unknown: bool = false,
    failure: ?anyerror = null,
};
pub fn pathFor(a: std.mem.Allocator, path: []const u8, cwd: ?[]const u8) ![]const u8 {
    if (path.len == 0 or path.len > 4096 or std.mem.indexOfAny(u8, path, "\x00\r\n") != null or !std.unicode.utf8ValidateSlice(path)) return error.InvalidFilePath;
    const absolute = if (path[0] == '/') try a.dupe(u8, path) else try std.fmt.allocPrint(a, "{s}/{s}", .{ cwd orelse return error.UnknownDirectory, path });
    errdefer a.free(absolute);
    if (absolute.len > 4096 or absolute[0] != '/' or absolute[absolute.len - 1] == '/' or std.mem.indexOfAny(u8, absolute, "\x00\r\n") != null or !std.unicode.utf8ValidateSlice(absolute)) return error.InvalidFilePath;
    var parts = std.mem.splitScalar(u8, absolute, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return error.ParentTraversalUnsupported;
    if (std.fs.path.basename(absolute).len == 0) return error.InvalidFilePath;
    return absolute;
}
pub fn version(owner: identity.SessionHandle, path: []const u8, bytes: []const u8) [64]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(std.mem.asBytes(&owner.session_id));
    hash.update(std.mem.asBytes(&owner.generation));
    hash.update(path);
    hash.update(&.{0});
    hash.update(bytes);
    return std.fmt.bytesToHex(hash.finalResult(), .lower);
}
pub fn validateText(bytes: []const u8) !void {
    if (bytes.len > text_limit) return error.FileTooLarge;
    if (!std.unicode.utf8ValidateSlice(bytes) or std.mem.indexOfScalar(u8, bytes, 0) != null) return error.UnsupportedTextEncoding;
}
pub fn requestVersion(request: Request, owner: identity.SessionHandle, path: []const u8, bytes: []const u8) [64]u8 {
    const base = version(owner, path, bytes);
    if (request.version_scope == 0 and request.version_stamp.len == 0) return base;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(&base);
    hash.update(std.mem.asBytes(&request.version_scope));
    hash.update(request.version_stamp);
    return std.fmt.bytesToHex(hash.finalResult(), .lower);
}
pub fn candidate(a: std.mem.Allocator, request: Request, owner: identity.SessionHandle, path: []const u8, before: []const u8) ![]const u8 {
    try validateText(before);
    if (request.kind == .edit_text or request.mode == .replace) {
        if (!std.mem.eql(u8, &requestVersion(request, owner, path, before), request.expected_version)) return error.SourceChanged;
    }
    if (request.kind == .write_text) {
        try validateText(request.text);
        return a.dupe(u8, request.text);
    }
    if (request.edits.len == 0 or request.edits.len > 128) return error.InvalidEdits;
    const Match = struct { start: usize, end: usize, text: []const u8 };
    var matches: std.ArrayList(Match) = .empty;
    defer matches.deinit(a);
    for (request.edits) |edit| {
        if (edit.old_text.len == 0) return error.EmptyMatch;
        const start = std.mem.indexOf(u8, before, edit.old_text) orelse return error.MatchNotFound;
        if (std.mem.indexOf(u8, before[start + 1 ..], edit.old_text) != null) return error.AmbiguousMatch;
        const end = start + edit.old_text.len;
        for (matches.items) |other| if (start < other.end and end > other.start) return error.OverlappingEdits;
        try matches.append(a, .{ .start = start, .end = end, .text = edit.new_text });
    }
    std.mem.sort(Match, matches.items, {}, struct {
        fn less(_: void, x: Match, y: Match) bool {
            return x.start < y.start;
        }
    }.less);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var cursor: usize = 0;
    for (matches.items) |match| {
        try out.appendSlice(a, before[cursor..match.start]);
        try out.appendSlice(a, match.text);
        cursor = match.end;
    }
    try out.appendSlice(a, before[cursor..]);
    try validateText(out.items);
    return out.toOwnedSlice(a);
}

pub const RemoteRead = struct { bytes: []const u8, stamp: []const u8, absent: bool = false };
pub fn parseRemoteRead(raw: []const u8, limit: usize) !RemoteRead {
    if (std.mem.eql(u8, raw, "ZWFILE1 absent\n")) return .{ .bytes = "", .stamp = "", .absent = true };
    if (!std.mem.startsWith(u8, raw, "ZWFILE1 ")) return error.InvalidFileResponse;
    const end = std.mem.indexOfScalar(u8, raw, '\n') orelse return error.InvalidFileResponse;
    const stamp = raw[8..end];
    if (stamp.len == 0 or stamp.len > 256) return error.InvalidFileResponse;
    for (stamp) |ch| if (!(ch >= '0' and ch <= '9') and ch != ':') return error.InvalidFileResponse;
    var fields = std.mem.splitScalar(u8, stamp, ':');
    _ = fields.next() orelse return error.InvalidFileResponse;
    _ = fields.next() orelse return error.InvalidFileResponse;
    const size = try std.fmt.parseInt(usize, fields.next() orelse return error.InvalidFileResponse, 10);
    if (size > limit) return error.FileTooLarge;
    if (raw.len != end + 1 + size + 8 + stamp.len + 1) return error.InvalidFileResponse;
    const tail = raw[end + 1 + size ..];
    if (!std.mem.startsWith(u8, tail, "\nZWEND1 ") or !std.mem.eql(u8, tail[8 .. tail.len - 1], stamp) or tail[tail.len - 1] != '\n') return error.SourceChanged;
    return .{ .bytes = raw[end + 1 ..][0..size], .stamp = stamp };
}
fn quote(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.append(a, '\'');
    for (bytes) |ch| if (ch == '\'') try out.appendSlice(a, "'\\''") else try out.append(a, ch);
    try out.append(a, '\'');
    return out.toOwnedSlice(a);
}
pub fn readCommand(a: std.mem.Allocator, path: []const u8, limit: usize, missing: bool) ![]const u8 {
    return std.fmt.allocPrint(a, script_prefix ++ "{s} zw-file {s} {d} {d}", .{ try quote(a, @embedFile("terminal_file_read.sh")), try quote(a, path), limit, @intFromBool(missing) });
}
// The login shell still belongs to the remote host, but our file utilities
// must not inherit project/user PATH entries, shell functions or startup vars.
const script_prefix = "/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C /bin/sh -c ";
pub fn writeCommand(a: std.mem.Allocator, path: []const u8, create: bool, before: []const u8, after: []const u8, stamp: []const u8) ![]const u8 {
    if (!create) {
        var fields = std.mem.splitScalar(u8, stamp, ':');
        var values: [9][]const u8 = undefined;
        for (&values) |*v| v.* = fields.next() orelse return error.InvalidFileResponse;
        if (!std.mem.eql(u8, values[8], "1")) return error.HardlinkUnsupported;
        const permissions = try std.fmt.parseInt(u32, values[5], 8);
        if (permissions & 0o7000 != 0) return error.SpecialPermissionsUnsupported;
    }
    return std.fmt.allocPrint(a, script_prefix ++ "{s} zw-file {s} {s} {d} {d} {s}", .{ try quote(a, @embedFile("terminal_file_write.sh")), try quote(a, path), if (create) "create" else "replace", before.len, after.len, try quote(a, stamp) });
}

extern "c" fn fcopyfile(c_int, c_int, ?*anyopaque, u32) c_int;
// O_NONBLOCK prevents a raced FIFO/device from trapping a worker in open().
// The descriptor is accepted only after fstat confirms a regular file.
fn openLocal(a: std.mem.Allocator, dir: std.Io.Dir, base: []const u8, writable: bool) !std.Io.File {
    const name = try a.dupeSentinel(u8, base, 0);
    defer a.free(name);
    while (true) {
        const fd = std.c.openat(dir.handle, name, .{ .ACCMODE = if (writable) .RDWR else .RDONLY, .NONBLOCK = true, .NOFOLLOW = true, .CLOEXEC = true, .NOCTTY = true });
        switch (std.c.errno(fd)) {
            .SUCCESS => return .{ .handle = fd, .flags = .{ .nonblocking = true } },
            .INTR => continue,
            .ACCES, .PERM => return error.AccessDenied,
            .NOENT => return error.FileNotFound,
            .LOOP => return error.SourceChanged,
            else => return error.FileOpenFailed,
        }
    }
}
fn readLocal(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, base: []const u8, limit: usize) !struct { bytes: []const u8, stat: std.Io.File.Stat } {
    const observed = try dir.statFile(io, base, .{ .follow_symlinks = false });
    if (observed.kind != .file) return error.NotRegularFile;
    if (observed.size > limit) return error.FileTooLarge;
    const file = try openLocal(a, dir, base, false);
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.inode != observed.inode or stat.kind != .file) return error.SourceChanged;
    const buffer = try a.alloc(u8, limit + 1);
    var used: usize = 0;
    while (used < buffer.len) {
        const n = try file.readPositional(io, &.{buffer[used..]}, used);
        if (n == 0) break;
        used += n;
    }
    if (used > limit) return error.FileTooLarge;
    const after = try file.stat(io);
    const path_after = try dir.statFile(io, base, .{ .follow_symlinks = false });
    if (used != after.size or stat.inode != path_after.inode or path_after.kind != .file or !std.meta.eql(stat.mtime, after.mtime) or !std.meta.eql(stat.ctime, after.ctime)) return error.SourceChanged;
    return .{ .bytes = buffer[0..used], .stat = after };
}
pub fn local(a: std.mem.Allocator, io: std.Io, owner: identity.SessionHandle, request: Request, cancel: *provider.CancelToken, result: *Result) !void {
    const path = request.path;
    var dir = try std.Io.Dir.openDirAbsolute(io, std.fs.path.dirname(path) orelse return error.InvalidFilePath, .{});
    defer dir.close(io);
    const base = std.fs.path.basename(path);
    if (cancel.isCancelled()) return error.Cancelled;
    if (request.app_data_root) |data_root| try guardNotesDirectory(io, data_root, dir, base);
    const create = request.kind == .write_text and request.mode == .create;
    const old = readLocal(a, io, dir, base, if (request.kind == .read_image) @import("../ai/image_attachments.zig").max_bytes else text_limit) catch |err| blk: {
        if (create and err == error.FileNotFound) break :blk null;
        return err;
    };
    if (create and old != null) return error.PathAlreadyExists;
    var version_request = request;
    if (old) |value| version_request.version_stamp = try localStamp(a, value.stat);
    if (request.kind == .read_text or request.kind == .read_image) {
        const value = old orelse return error.FileNotFound;
        if (request.kind == .read_text) try validateText(value.bytes);
        result.bytes = value.bytes;
        result.version = requestVersion(version_request, owner, path, value.bytes);
        return;
    }
    const before = if (old) |v| v.bytes else "";
    if (old) |v| {
        if (v.stat.nlink != 1) return error.HardlinkUnsupported;
        if (@backingInt(v.stat.permissions) & 0o7000 != 0) return error.SpecialPermissionsUnsupported;
    }
    const after = try candidate(a, version_request, owner, path, before);
    var random: [16]u8 = undefined;
    std.Io.random(io, &random);
    const temporary = try std.fmt.allocPrint(a, ".zerowork-file-{s}.tmp", .{std.fmt.bytesToHex(random, .lower)});
    try dir.createDir(io, temporary, @fromBackingInt(0o700));
    // If opening/identifying the directory fails, do not unlink an unverified
    // pathname: another writer may already have replaced it.
    var staging = try dir.openDir(io, temporary, .{ .follow_symlinks = false });
    defer staging.close(io);
    var directory_stat: std.c.Stat = undefined;
    if (std.c.fstat(staging.handle, &directory_stat) != 0 or directory_stat.uid != std.c.geteuid() or directory_stat.mode & 0o777 != 0o700) return error.SourceChanged;
    const owned_directory = try staging.stat(io);
    defer {
        if (dir.statFile(io, temporary, .{ .follow_symlinks = false })) |current| {
            if (current.kind == .directory and current.inode == owned_directory.inode) dir.deleteDir(io, temporary) catch {};
        } else |_| {}
    }
    const file = try staging.createFile(io, "candidate", .{ .exclusive = true, .permissions = @fromBackingInt(@intCast(0o600)) });
    defer file.close(io);
    const owned_temp = try file.stat(io);
    defer {
        if (staging.statFile(io, "candidate", .{ .follow_symlinks = false })) |current| {
            if (current.kind == .file and current.inode == owned_temp.inode) staging.deleteFile(io, "candidate") catch {};
        } else |_| {}
    }
    if (old != null) {
        const original = try openLocal(a, dir, base, true);
        defer original.close(io);
        const original_stat = try original.stat(io);
        if (original_stat.kind != .file or !std.mem.eql(u8, try localStamp(a, original_stat), version_request.version_stamp)) return error.SourceChanged;
        if (fcopyfile(original.handle, file.handle, null, 7) != 0) return error.MetadataPreservationFailed;
    }
    try file.writePositionalAll(io, after, 0);
    try file.sync(io);
    if (cancel.isCancelled()) return error.Cancelled;
    if (!create) {
        const current = try readLocal(a, io, dir, base, text_limit);
        if (current.stat.inode != old.?.stat.inode or current.stat.nlink != 1 or !std.mem.eql(u8, try localStamp(a, current.stat), version_request.version_stamp) or !std.mem.eql(u8, current.bytes, before)) return error.SourceChanged;
    }
    const staged = try staging.statFile(io, "candidate", .{ .follow_symlinks = false });
    if (staged.kind != .file or staged.inode != owned_temp.inode or staged.nlink != 1) return error.SourceChanged;
    if (cancel.isCancelled()) return error.Cancelled;
    if (create) try staging.renamePreserve("candidate", dir, base, io) else try staging.rename("candidate", dir, base, io);
    result.committed = true;
    result.bytes = after;
    const confirmed = try readLocal(a, io, dir, base, text_limit);
    if (!std.mem.eql(u8, confirmed.bytes, after)) return error.VerificationFailed;
    version_request.version_stamp = try localStamp(a, confirmed.stat);
    result.version = requestVersion(version_request, owner, path, after);
    result.verified = true;
}

fn guardNotesDirectory(io: std.Io, data_root: []const u8, parent: std.Io.Dir, base: []const u8) !void {
    const boundary = try @import("local_path.zig").NotesBoundary.open(io, data_root) orelse return;
    try boundary.check(io, parent, base);
}

test "notes data guard rejects both direct and symlinked directory access" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "app/notes/libraries");
    try tmp.dir.symLink(io, "app/notes/libraries", "linked", .{ .is_directory = true });
    const root = try tmp.dir.realPathFileAlloc(io, "app", a);
    defer a.free(root);
    const direct = try tmp.dir.openDir(io, "app/notes/libraries", .{});
    defer direct.close(io);
    const alias = try tmp.dir.openDir(io, "linked", .{});
    defer alias.close(io);
    try std.testing.expectError(error.NotesStoreProtected, guardNotesDirectory(io, root, direct, "note.json"));
    try std.testing.expectError(error.NotesStoreProtected, guardNotesDirectory(io, root, alias, "note.json"));
    try guardNotesDirectory(io, root, tmp.dir, "unrelated.txt");
}
fn localStamp(a: std.mem.Allocator, stat: std.Io.File.Stat) ![]const u8 {
    return std.fmt.allocPrint(a, "{d}:{d}:{d}:{d}:{any}:{any}", .{ stat.inode, stat.nlink, stat.size, @backingInt(stat.permissions), stat.mtime, stat.ctime });
}

test "terminal files exact edits preserve bytes and reject stale ambiguous overlapping changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(42), .generation = 1 };
    const before = "\xef\xbb\xbfport=80\r\nname=one\r\n";
    const token = version(owner, "/test", before);
    const request: Request = .{ .kind = .edit_text, .path = "/test", .expected_version = &token, .edits = &.{.{ .old_text = "port=80", .new_text = "port=90" }} };
    try std.testing.expectEqualStrings("\xef\xbb\xbfport=90\r\nname=one\r\n", try candidate(a, request, owner, "/test", before));
    try std.testing.expectError(error.SourceChanged, candidate(a, request, try owner.nextGeneration(), "/test", before));
    var other = request;
    other.expected_version = &version(owner, "/test", "aa");
    other.edits = &.{.{ .old_text = "a", .new_text = "x" }};
    try std.testing.expectError(error.AmbiguousMatch, candidate(a, other, owner, "/test", "aa"));
    try std.testing.expectError(error.InvalidFilePath, pathFor(a, "/tmp/target/", null));
    try std.testing.expectError(error.ParentTraversalUnsupported, pathFor(a, "../target", "/tmp"));
}

test "terminal files native create replace conflict metadata and cancellation use isolated files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const path = try std.fmt.allocPrint(a, "{s}/a 'quoted' $(literal).txt", .{root});
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(42), .generation = 1 };
    var cancel: provider.CancelToken = .{};
    var result: Result = .{};
    try local(a, io, owner, .{ .kind = .write_text, .path = path, .text = "\xef\xbb\xbfport=80\r\n" }, &cancel, &result);
    try std.testing.expect(result.committed and result.verified);
    const original = result.version;
    try std.testing.expectError(error.PathAlreadyExists, local(a, io, owner, .{ .kind = .write_text, .path = path, .text = "wrong" }, &cancel, &result));
    var edited: Result = .{};
    try local(a, io, owner, .{ .kind = .edit_text, .path = path, .expected_version = &original, .edits = &.{.{ .old_text = "80", .new_text = "90" }} }, &cancel, &edited);
    try std.testing.expect(edited.committed and edited.verified);
    try std.testing.expectEqualStrings("\xef\xbb\xbfport=90\r\n", edited.bytes);
    var stale: Result = .{};
    try std.testing.expectError(error.SourceChanged, local(a, io, owner, .{ .kind = .write_text, .mode = .replace, .path = path, .expected_version = &original, .text = "wrong" }, &cancel, &stale));
    try std.testing.expect(!stale.committed);
    const stat = try tmp.dir.statFile(io, std.fs.path.basename(path), .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), @backingInt(stat.permissions) & 0o777);
    const link_path = try std.fmt.allocPrint(a, "{s}/linked", .{root});
    try tmp.dir.symLink(io, std.fs.path.basename(path), "linked", .{});
    try std.testing.expectError(error.NotRegularFile, local(a, io, owner, .{ .kind = .read_text, .path = link_path }, &cancel, &stale));
    cancel.cancel();
    try std.testing.expectError(error.Cancelled, local(a, io, owner, .{ .kind = .write_text, .path = try std.fmt.allocPrint(a, "{s}/cancelled", .{root}), .text = "never" }, &cancel, &stale));
}

test "terminal files native replacement honors read only permissions and cleans rejected staging" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "readonly", .data = "original" });
    const file = try tmp.dir.openFile(io, "readonly", .{});
    defer file.close(io);
    try file.setPermissions(io, @fromBackingInt(0o400));
    defer file.setPermissions(io, @fromBackingInt(0o600)) catch {};
    const path = try tmp.dir.realPathFileAlloc(io, "readonly", a);
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(42), .generation = 1 };
    var cancel: provider.CancelToken = .{};
    var before: Result = .{};
    try local(a, io, owner, .{ .kind = .read_text, .path = path }, &cancel, &before);
    var result: Result = .{};
    try std.testing.expectError(error.AccessDenied, local(a, io, owner, .{ .kind = .write_text, .mode = .replace, .path = path, .expected_version = &before.version, .text = "changed" }, &cancel, &result));
    try std.testing.expect(!result.committed and !result.outcome_unknown);
    try std.testing.expectEqualStrings("original", try tmp.dir.readFileAlloc(io, "readonly", a, .limited(100)));
    var iterator = tmp.dir.iterate();
    while (try iterator.next(io)) |entry| try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".zerowork-file-"));
}

test "terminal files raced FIFO opens never block the local worker" {
    const Native = struct {
        extern "c" fn mkfifo([*:0]const u8, std.c.mode_t) c_int;
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const name = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/fifo", .{root}, 0);
    defer std.testing.allocator.free(name);
    try std.testing.expectEqual(@as(c_int, 0), Native.mkfifo(name, 0o600));
    const file = try openLocal(std.testing.allocator, tmp.dir, "fifo", false);
    defer file.close(std.testing.io);
    try std.testing.expectEqual(std.Io.File.Kind.named_pipe, (try file.stat(std.testing.io)).kind);
}
