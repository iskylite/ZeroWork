//! UI-only reads of a directory explicitly chosen for the displayed conversation.
//! Does not use the model's local file tool, terminal CWD, or process HOME.
const std = @import("std");
const workspace = @import("local_workspace.zig");
const paths = @import("local_path.zig");
const reads = @import("local_file_reads.zig");
const scan = @import("local_file_search.zig");
const identity = @import("identity.zig");
const images = @import("../ai/image_attachments.zig");
const image_snapshot = @import("ai_image_snapshot.zig");
pub const Stamp = struct {
    owner: identity.SessionHandle,
    fence: @import("../ai/session_input.zig").Fence,
    scope_revision: u64,
    revision: u64,
    root: workspace.Identity,
};
pub const Source = struct { stamp: Stamp, workspace: workspace.Snapshot, data_root: []const u8, reference_trial: bool = false };
pub const max_rows = 128;
pub const max_depth = 8;
pub const max_bytes = 16 * 1024;
pub const max_lines = 256;
const image_limits: images.Limits = .{ .bytes = 6 * 1024 * 1024, .dimension = 4096, .pixels = 4 * 1024 * 1024 };
pub const Kind = enum { file, directory, symlink };
pub const Entry = struct { path: []const u8, kind: Kind, depth: u16, expanded: bool = false };
pub const Text = struct {
    bytes: []const u8,
    limited: bool,
    line_limited: bool,
    file: ?workspace.Identity = null,
};
pub const Result = union(enum) {
    listing: struct { rows: []const Entry, limited: bool },
    text: Text,
    image: images.ContentRef,

    /// Text and rows belong to the request arena. A decoded image also owns a
    /// share of the existing global image budget, independent of that arena.
    pub fn release(self: *Result) void {
        if (self.* == .image) self.image.release();
    }
};
pub const Mode = enum { list, read, read_text_reference };
const CancelFlag = std.atomic.Value(bool);

fn checkCanceled(cancel: ?*const CancelFlag) !void {
    if (cancel) |flag| if (flag.load(.acquire)) return error.PreviewSuperseded;
}
fn imageCanceled(raw: *const anyopaque) bool {
    const flag: *const CancelFlag = @ptrCast(@alignCast(raw));
    return flag.load(.acquire);
}
fn readExact(io: std.Io, file: std.Io.File, bytes: []u8, offset: usize, cancel: ?*const CancelFlag) !void {
    var used: usize = 0;
    while (used < bytes.len) {
        try checkCanceled(cancel);
        const amount = @min(bytes.len - used, 64 * 1024);
        const n = try file.readPositional(io, &.{bytes[used..][0..amount]}, offset + used);
        if (n == 0) return error.FileChanged;
        used += n;
    }
}

fn component(name: []const u8) bool {
    return name.len != 0 and name.len <= std.Io.Dir.max_name_bytes and
        !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..") and !paths.isRecoveryName(name) and
        std.mem.indexOfAny(u8, name, "/\x00") == null and std.unicode.utf8ValidateSlice(name) and
        for (name) |byte| {
            if (byte < 32 or byte == 127) break false;
        } else true;
}
fn validate(path: []const u8, mode: Mode) !void {
    if (path.len == 0 and mode == .list) return;
    if (path.len >= std.Io.Dir.max_path_bytes) return error.InvalidPreviewPath;
    var parts = std.mem.splitScalar(u8, path, '/');
    var depth: usize = 0;
    while (parts.next()) |part| {
        depth += 1;
        if (!component(part) or depth > max_depth + 1) return error.InvalidPreviewPath;
    }
    if (mode == .list and depth > max_depth) return error.PreviewDepthLimit;
}
fn openRoot(io: std.Io, s: Source, cancel: ?*const CancelFlag) !std.Io.Dir {
    try checkCanceled(cancel);
    const snap = s.workspace;
    if (snap.availability != .ready or snap.revision != s.stamp.revision or
        !std.meta.eql(snap.directory_identity, @as(?workspace.Identity, s.stamp.root))) return error.WorkspaceChanged;
    const dir = try std.Io.Dir.openDirAbsolute(io, snap.directory orelse return error.WorkspaceChanged, .{ .iterate = true });
    errdefer dir.close(io);
    try checkCanceled(cancel);
    if (!std.meta.eql(try workspace.Identity.of(dir), s.stamp.root)) return error.WorkspaceChanged;
    return dir;
}
fn reopenDir(io: std.Io, source: Source, path: []const u8, cancel: ?*const CancelFlag) !std.Io.Dir {
    var dir = try openRoot(io, source, cancel);
    errdefer dir.close(io);
    if (path.len == 0) return dir;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        try checkCanceled(cancel);
        const next = try dir.openDir(io, part, .{ .follow_symlinks = false });
        dir.close(io);
        dir = next;
    }
    return dir;
}
fn less(_: void, a: Entry, b: Entry) bool {
    if ((a.kind == .directory) != (b.kind == .directory)) return a.kind == .directory;
    return std.mem.lessThan(u8, a.path, b.path);
}
fn childPath(a: std.mem.Allocator, base: []const u8, name: []const u8) ![]const u8 {
    return if (base.len == 0) a.dupe(u8, name) else std.fmt.allocPrint(a, "{s}/{s}", .{ base, name });
}
const List = struct {
    a: std.mem.Allocator,
    io: std.Io,
    source: Source,
    rows: std.ArrayList(Entry) = .empty,
    remaining: usize = max_rows * 3,
    limited: bool = false,
    boundary: ?paths.NotesBoundary,
    cancel: ?*const CancelFlag,
    fn collect(self: *List, dir: std.Io.Dir, base: []const u8, expand: []const u8, depth: u16) anyerror!void {
        try checkCanceled(self.cancel);
        const dir_id = try workspace.Identity.of(dir);
        var children: std.ArrayList(Entry) = .empty;
        var it = dir.iterate();
        while (self.remaining > 0 and children.items.len < max_rows) {
            try checkCanceled(self.cancel);
            const e = (try it.next(self.io)) orelse break;
            self.remaining -= 1;
            if (!component(e.name) or scan.ignoredByDefault(e.name, e.kind == .directory) or (if (self.boundary) |b| b.protectsChild(dir_id, e.name) else false)) continue;
            const kind: Kind = switch (e.kind) {
                .file => .file,
                .directory => .directory,
                .sym_link => .symlink,
                else => continue,
            };
            try children.append(self.a, .{ .path = try childPath(self.a, base, e.name), .kind = kind, .depth = depth });
        }
        if (self.remaining == 0 or children.items.len == max_rows) self.limited = true;
        std.mem.sort(Entry, children.items, {}, less);
        for (children.items) |entry| {
            if (self.rows.items.len == max_rows) {
                self.limited = true;
                break;
            }
            var row = entry;
            row.expanded = row.kind == .directory and depth < max_depth and (std.mem.eql(u8, expand, row.path) or
                (expand.len > row.path.len and expand[row.path.len] == '/' and std.mem.startsWith(u8, expand, row.path)));
            try self.rows.append(self.a, row);
            if (!row.expanded) continue;
            try checkCanceled(self.cancel);
            const child = try dir.openDir(self.io, std.fs.path.basename(row.path), .{ .follow_symlinks = false, .iterate = true });
            defer child.close(self.io);
            if (self.boundary) |b| try b.check(self.io, child, ".");
            try self.collect(child, row.path, expand, depth + 1);
        }
        const check = try reopenDir(self.io, self.source, base, self.cancel);
        defer check.close(self.io);
        if (!std.meta.eql(dir_id, try workspace.Identity.of(check))) return error.WorkspaceChanged;
    }
};
// `a` belongs to the bounded, per-request arena. Only a regular, unchanged
// file is read. Open each component relative to held descriptors, without
// following links; a FIFO swap must never block the reader.
pub fn capture(a: std.mem.Allocator, io: std.Io, s: Source, mode: Mode, relative: []const u8) !Result {
    return captureWhileCurrent(a, io, s, mode, relative, null);
}

fn captureWhileCurrent(a: std.mem.Allocator, io: std.Io, s: Source, mode: Mode, relative: []const u8, cancel: ?*const CancelFlag) !Result {
    try validate(relative, mode);
    var dir = try openRoot(io, s, cancel);
    defer dir.close(io);
    const boundary = if (s.data_root.len != 0) try paths.NotesBoundary.open(io, s.data_root) else null;
    try checkCanceled(cancel);
    if (boundary) |b| try b.check(io, dir, ".");
    if (mode == .list) {
        var listing = List{ .a = a, .io = io, .source = s, .boundary = boundary, .cancel = cancel };
        try listing.collect(dir, "", relative, 0);
        return .{ .listing = .{ .rows = listing.rows.items, .limited = listing.limited } };
    }
    var components = std.mem.splitScalar(u8, relative, '/');
    var name = components.next().?;
    while (components.next()) |next| {
        try checkCanceled(cancel);
        if (boundary) |b| try b.check(io, dir, name);
        const child = try dir.openDir(io, name, .{ .follow_symlinks = false });
        dir.close(io);
        dir = child;
        name = next;
    }
    try checkCanceled(cancel);
    if (boundary) |b| try b.check(io, dir, name);
    const z = try a.dupeSentinel(u8, name, 0);
    const fd = while (true) {
        try checkCanceled(cancel);
        const ret = std.c.openat(dir.handle, z.ptr, .{ .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true, .NOCTTY = true });
        switch (std.c.errno(ret)) {
            .SUCCESS => break ret,
            .INTR => continue,
            else => return error.PreviewUnavailable,
        }
    };
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    defer file.close(io);
    try checkCanceled(cancel);
    const before = try reads.fileState(file, io);
    // A hard link can alias a private file outside the workspace.
    if (before.stat.nlink != 1) return error.AmbiguousLink;
    // Type comes from the admitted file descriptor, not the name. Do not
    // hand a reconstructed path to the general attachment reader.
    var header: [12]u8 = undefined;
    const prefix = header[0..@intCast(@min(before.stat.size, header.len))];
    try readExact(io, file, prefix, 0, cancel);
    const is_image = if (images.sniff(prefix)) |_| true else |_| false;
    if (mode == .read_text_reference and (is_image or before.stat.size > max_bytes)) return error.WorkspaceFileNotPlainText;
    if (is_image and before.stat.size > image_limits.bytes) return error.ImageTooLarge;
    const expected: usize = @intCast(@min(before.stat.size, if (is_image) image_limits.bytes else max_bytes));
    const buffer = try a.alloc(u8, expected);
    @memcpy(buffer[0..prefix.len], prefix);
    try readExact(io, file, buffer[prefix.len..], prefix.len, cancel);
    try checkCanceled(cancel);
    if (!before.unchanged(try reads.fileState(file, io))) return error.FileChanged;
    const check = try reopenDir(io, s, std.fs.path.dirname(relative) orelse "", cancel);
    defer check.close(io);
    if (!std.meta.eql(try workspace.Identity.of(dir), try workspace.Identity.of(check))) return error.WorkspaceChanged;
    var latest: std.c.Stat = undefined;
    if (std.c.fstatat(check.handle, z.ptr, &latest, std.c.AT.SYMLINK_NOFOLLOW) != 0 or
        !std.meta.eql(before.identity, workspace.Identity.fromStat(latest))) return error.FileChanged;
    if (is_image) {
        const token: @import("../ai/provider.zig").CancelToken = .{ .source = if (cancel) |flag| .{ .context = flag, .poll = imageCanceled } else null };
        var image = try image_snapshot.captureBytes(a, relative, buffer, &token, image_limits);
        errdefer image.release();
        try checkCanceled(cancel);
        return .{ .image = image };
    }
    const limited = expected < before.stat.size;
    for (buffer) |c| if ((c < 32 and c != '\r' and c != '\n' and c != '\t') or c == 127) return error.BinaryFile;
    var text: []const u8 = buffer;
    if (limited and text.len != 0 and !std.unicode.utf8ValidateSlice(text)) {
        // Trim only an incomplete final codepoint, never arbitrary invalid bytes.
        var start = text.len - 1;
        while (start > 0 and text.len - start <= 3 and (text[start] & 0xc0) == 0x80) start -= 1;
        const width = std.unicode.utf8ByteSequenceLength(text[start]) catch return error.BinaryFile;
        if (width > text.len - start) text = text[0..start];
    }
    if (!std.unicode.utf8ValidateSlice(text)) return error.BinaryFile;
    var lines: usize = 1;
    for (text, 0..) |byte, i| if (byte == '\n') {
        if (lines == max_lines and i + 1 < text.len)
            return .{ .text = .{ .bytes = text[0..i], .limited = true, .line_limited = true, .file = before.identity } };
        lines += 1;
    };
    return .{ .text = .{ .bytes = text, .limited = limited, .line_limited = false, .file = before.identity } };
}

// An in-flight kernel filesystem call may not be interruptible (e.g. a lost
// mounted volume). Limit workers across windows, including abandoned calls.
const worker_limit: u8 = 12;
var workers: std.atomic.Value(u8) = .init(0);

fn reserveWorker(counter: *std.atomic.Value(u8)) bool {
    var running = counter.load(.acquire);
    while (running < worker_limit) {
        running = counter.cmpxchgWeak(running, running + 1, .acq_rel, .acquire) orelse return true;
    }
    return false;
}

// One result belongs to one mounted page. Workers have no UI pointers, and a
// newer request need not wait for a superseded worker to leave the kernel.
pub const Job = struct {
    arena: std.heap.ArenaAllocator,
    stamp: Stamp,
    source: Source,
    mode: Mode,
    path: []const u8,
    refs: std.atomic.Value(u8) = .init(2),
    done: std.atomic.Value(bool) = .init(false),
    canceled: CancelFlag = .init(false),
    result: anyerror!Result = error.Pending,
    pub fn start(source: Source, mode: Mode, path: []const u8) !*Job {
        if (!reserveWorker(&workers)) return error.PreviewBusy;
        errdefer _ = workers.fetchSub(1, .acq_rel);
        const job = try std.heap.c_allocator.create(Job);
        errdefer std.heap.c_allocator.destroy(job);
        job.* = .{ .arena = .init(std.heap.c_allocator), .source = source, .stamp = source.stamp, .mode = mode, .path = "" };
        errdefer job.arena.deinit();
        const a = job.arena.allocator();
        job.source.workspace = try source.workspace.clone(a);
        job.source.data_root = try a.dupe(u8, source.data_root);
        job.path = try a.dupe(u8, path);
        (try std.Thread.spawn(.{}, run, .{job})).detach();
        return job;
    }
    fn run(job: *Job) void {
        var runtime = std.Io.Threaded.init(std.heap.c_allocator, .{});
        job.result = captureWhileCurrent(job.arena.allocator(), runtime.io(), job.source, job.mode, job.path, &job.canceled);
        runtime.deinit();
        _ = workers.fetchSub(1, .acq_rel);
        job.done.store(true, .release);
        job.release();
    }
    pub fn cancel(job: *Job) void {
        job.canceled.store(true, .release);
    }
    pub fn release(job: *Job) void {
        if (job.refs.fetchSub(1, .acq_rel) != 1) return;
        if (job.result) |result| {
            var owned = result;
            owned.release();
        } else |_| {}
        job.arena.deinit();
        std.heap.c_allocator.destroy(job);
    }
};

test "workspace preview bounds outstanding readers including stale workers" {
    var count: std.atomic.Value(u8) = .init(0);
    for (0..worker_limit) |_| try std.testing.expect(reserveWorker(&count));
    try std.testing.expect(!reserveWorker(&count));
    _ = count.fetchSub(1, .acq_rel);
    try std.testing.expect(reserveWorker(&count));
    try std.testing.expectEqual(worker_limit, count.load(.acquire));
}

test "workspace preview decodes only bounded admitted static images" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR" ++
        "\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89" ++
        "\x00\x00\x00\x0dIDAT\x78\x9c\x63\xf8\xcf\xc0\xf0\x1f\x00\x05\x00\x01\xff\x89\x99\x3d\x1d" ++
        "\x00\x00\x00\x00IEND\xae\x42\x60\x82";
    try tmp.dir.writeFile(io, .{ .sub_path = "raster.bin", .data = png });
    try tmp.dir.writeFile(io, .{ .sub_path = "corrupt.png", .data = png[0..12] });
    try tmp.dir.writeFile(io, .{ .sub_path = "vector.svg", .data = "<svg/>" });
    try tmp.dir.symLink(io, "raster.bin", "link.png", .{});
    const too_large = try tmp.dir.createFile(io, "too-large.png", .{});
    defer too_large.close(io);
    try too_large.writePositionalAll(io, png, 0);
    try too_large.setLength(io, image_limits.bytes + 1);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const snap = try workspace.inspect(a, io, root);
    const source: Source = .{
        .stamp = .{ .owner = .{ .session_id = @fromBackingInt(7) }, .fence = .{ .agent = .generate(), .conversation = .generate(), .binding = 1, .environment = 1 }, .revision = snap.revision, .scope_revision = 1, .root = snap.directory_identity.? },
        .workspace = snap,
        .data_root = "",
    };
    var result = try capture(a, io, source, .read, "raster.bin");
    defer result.release();
    const image = result.image.content() orelse return error.ImageNotReady;
    try std.testing.expectEqual(images.Mime.png, image.mime);
    try std.testing.expectEqual(@as(u32, 1), image.width);
    try std.testing.expectEqual(@as(u32, 1), image.height);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, image.pixels);
    try std.testing.expectEqualStrings("<svg/>", (try capture(a, io, source, .read, "vector.svg")).text.bytes);
    try std.testing.expectError(error.PreviewUnavailable, capture(a, io, source, .read, "link.png"));
    try std.testing.expectError(error.ImageTooLarge, capture(a, io, source, .read, "too-large.png"));
    try std.testing.expectError(error.InvalidImage, capture(a, io, source, .read, "corrupt.png"));
}

test "workspace preview root identity, protected material, traversal, binary, bounded UTF-8 and symlinks" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "project", .default_dir);
    try tmp.dir.createDir(io, "other", .default_dir);
    try tmp.dir.createDir(io, "project/.git", .default_dir);
    try tmp.dir.createDir(io, "project/node_modules", .default_dir);
    try tmp.dir.createDir(io, "project/notes", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "other/secret", .data = "outside" });
    try tmp.dir.hardLink("other/secret", tmp.dir, "project/hardlink", io, .{});
    var many_lines: [(max_lines + 2) * 2]u8 = undefined;
    for (0..max_lines + 2) |i| @memcpy(many_lines[i * 2 ..][0..2], "x\n");
    try tmp.dir.writeFile(io, .{ .sub_path = "project/lines", .data = &many_lines });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/binary", .data = "\x00BIN" });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/notes/private", .data = "note" });
    try tmp.dir.symLink(io, "../other", "project/alias", .{ .is_directory = true });
    try tmp.dir.symLink(io, "../other/secret", "project/link", .{});
    const big = try a.alloc(u8, max_bytes + 2);
    @memset(big, 'a');
    @memcpy(big[max_bytes - 1 ..], "文");
    try tmp.dir.writeFile(io, .{ .sub_path = "project/big", .data = big });
    const path = try tmp.dir.realPathFileAlloc(io, "project", a);
    const snap = try workspace.inspect(a, io, path);
    var source = Source{ .stamp = .{ .owner = .{ .session_id = @fromBackingInt(7), .generation = 4 }, .fence = .{ .agent = .generate(), .conversation = .generate(), .binding = 1, .environment = 1 }, .revision = snap.revision, .scope_revision = 0, .root = snap.directory_identity.? }, .workspace = snap, .data_root = path };
    const canceled: CancelFlag = .init(true);
    try std.testing.expectError(error.PreviewSuperseded, captureWhileCurrent(a, io, source, .read, "big", &canceled));
    const text = (try capture(a, io, source, .read, "big")).text;
    for ((try capture(a, io, source, .list, "")).listing.rows) |row| {
        try std.testing.expect(!std.mem.eql(u8, row.path, ".git") and !std.mem.eql(u8, row.path, "node_modules"));
    }
    const lines = (try capture(a, io, source, .read, "lines")).text;
    try std.testing.expect(lines.limited and lines.line_limited);
    try std.testing.expectEqual(max_lines - 1, std.mem.count(u8, lines.bytes, "\n"));
    try std.testing.expectError(error.AmbiguousLink, capture(a, io, source, .read, "hardlink"));
    try std.testing.expect(text.limited);
    try std.testing.expectEqual(max_bytes - 1, text.bytes.len);
    try std.testing.expectError(error.InvalidPreviewPath, capture(a, io, source, .read, "../other/secret"));
    try std.testing.expectError(error.InvalidPreviewPath, capture(a, io, source, .read, "/outside"));
    try std.testing.expectError(error.BinaryFile, capture(a, io, source, .read, "binary"));
    try std.testing.expectError(error.PreviewUnavailable, capture(a, io, source, .read, "link"));
    if (capture(a, io, source, .read, "alias/secret")) |_| return error.FollowedDirectorySymlink else |_| {}
    try std.testing.expectError(error.NotesStoreProtected, capture(a, io, source, .read, "notes/private"));
    source.stamp.root.inode +%= 1;
    try std.testing.expectError(error.WorkspaceChanged, capture(a, io, source, .list, ""));
}
