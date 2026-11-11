//! Authorized queries over immutable captures of committed notes.
const std = @import("std");
const model = @import("model.zig");
const storage = @import("store.zig");
const assets = @import("assets.zig");
const Allocator = std.mem.Allocator;
pub const CancelToken = @import("../../ai/provider.zig").CancelToken;
pub const Access = storage.QueryAccess;

const max_page = 20;
const max_query_bytes = 256;
const max_library_filter = 64;
const excerpt_bytes = 384;
const excerpt_context = 72;

pub const Range = struct {
    start_byte: usize,
    end_byte: usize,
};

pub const SourceRef = struct {
    key: model.NoteKey,
    revision: u64,
    range: Range,

    pub fn format(self: SourceRef, a: Allocator) ![]const u8 {
        return std.fmt.allocPrint(a, "notes:{s}:{s}:{d}:{d}:{d}", .{
            std.fmt.bytesToHex(self.key.library_id.bytes, .lower),
            std.fmt.bytesToHex(self.key.note_id.bytes, .lower),
            self.revision,
            self.range.start_byte,
            self.range.end_byte,
        });
    }

    pub fn parse(text: []const u8) !SourceRef {
        var fields = std.mem.splitScalar(u8, text, ':');
        if (!std.mem.eql(u8, fields.next() orelse "", "notes")) return error.InvalidArguments;
        const library_id = model.LibraryId.parse(fields.next() orelse "") catch return error.InvalidArguments;
        const note_id = model.NoteId.parse(fields.next() orelse "") catch return error.InvalidArguments;
        const revision = try decimal(u64, fields.next());
        const start = try decimal(usize, fields.next());
        const end = try decimal(usize, fields.next());
        if (fields.next() != null or revision == 0 or start > end) return error.InvalidArguments;
        return .{ .key = .{ .library_id = library_id, .note_id = note_id }, .revision = revision, .range = .{ .start_byte = start, .end_byte = end } };
    }
};

pub const SourceResolution = struct {
    state: enum { current, updated, deleted },
    key: model.NoteKey,
    revision: ?u64 = null,
    range: ?Range = null,
};

pub const Guard = struct {
    access: Access,
    fences: []const storage.QueryFence,
    target: ?model.NoteKey = null,
};

pub fn Checked(comptime Value: type) type {
    return struct {
        value: Value,
        guard: Guard,
    };
}

pub fn Page(comptime Entry: type) type {
    return struct {
        entries: []const Entry,
        next_cursor: ?[]const u8,
    };
}

pub const ListArgs = struct {
    library_id: ?model.LibraryId = null,
    folder_id: ?model.FolderId = null,
    cursor: ?[]const u8 = null,
};

pub const ListEntry = struct {
    kind: enum { library, folder, note },
    library_id: model.LibraryId,
    folder_id: ?model.FolderId = null,
    note_id: ?model.NoteId = null,
    name: []const u8,
    revision: ?u64 = null,
};

pub const SearchArgs = struct {
    query: []const u8,
    library_ids: []const model.LibraryId = &.{},
    folder_id: ?model.FolderId = null,
    limit: usize = 6,
    cursor: ?[]const u8 = null,
};

pub const Hit = struct {
    library_id: model.LibraryId,
    note_id: model.NoteId,
    title: []const u8,
    path: []const []const u8,
    revision: u64,
    start_byte: usize,
    end_byte: usize,
    excerpt: []const u8,
    source_ref: []const u8,
};

pub const ReadArgs = struct {
    note_id: model.NoteId,
    expected_revision: ?u64 = null,
    start_byte: usize = 0,
    max_bytes: usize = 8 * 1024,
};

pub const ReadResult = struct {
    library_id: model.LibraryId,
    note_id: model.NoteId,
    title: []const u8,
    path: []const []const u8,
    revision: u64,
    body_md: []const u8,
    start_byte: usize,
    end_byte: usize,
    next_byte: ?usize,
    image_refs: []const []const u8,
    source_ref: []const u8,
};

pub const ImageArgs = struct {
    note_id: model.NoteId,
    expected_revision: u64,
    asset_ref: []const u8,
};

/// Pass this exact document revision to the asset loader, then revalidate the
/// guard before returning the loaded bytes to the caller.
pub const PreparedImage = struct {
    key: model.NoteKey,
    body_md: []const u8,
    asset_ref: []const u8,
};

pub const Queries = struct {
    store: *storage.Store,

    /// The allocator is the caller's query arena. The guard borrows it through
    /// the last handoff; serialized tool responses contain only value.
    pub fn list(self: Queries, a: Allocator, access: Access, args: ListArgs, cancel: ?*const CancelToken) !Checked(Page(ListEntry)) {
        if (args.folder_id != null and args.library_id == null) return error.InvalidArguments;
        const ids: []const model.LibraryId = if (args.library_id) |id| &.{id} else &.{};
        try validateScope(ids, args.folder_id);
        const captured = try self.store.captureQuery(a, .{
            .access = access,
            .library_ids = ids,
            .folder_id = args.folder_id,
            .documents = if (ids.len == 0) .none else .children,
        }, cancel);
        if (ids.len != 0 and captured.len == 0) return error.Unavailable;
        const guard = try guardFor(a, access, captured);
        const paging = self.pagination(guard, .list, ids, args.folder_id, "", max_page);
        const offset = try paging.offset(args.cursor);
        var entries: std.ArrayList(ListEntry) = .empty;
        for (captured) |snapshot| {
            const library = snapshot.library;
            if (ids.len == 0) {
                try entries.append(a, .{ .kind = .library, .library_id = library.id, .name = library.name, .revision = library.revision });
                continue;
            }
            for (library.folders) |folder| {
                if (!std.meta.eql(folder.parent_id, args.folder_id) or folder.deleted_at != null) continue;
                try entries.append(a, .{ .kind = .folder, .library_id = library.id, .folder_id = folder.id, .name = folder.name });
            }
            for (snapshot.notes) |note| {
                try entries.append(a, .{ .kind = .note, .library_id = library.id, .note_id = note.id, .folder_id = note.folder_id, .name = note.title, .revision = note.revision });
            }
        }
        std.mem.sort(ListEntry, entries.items, {}, lessEntry);
        const end = try pageEnd(entries.items.len, offset, max_page);
        try self.revalidate(access, guard, cancel);
        return .{ .value = .{
            .entries = entries.items[offset..end],
            .next_cursor = if (end < entries.items.len) try paging.format(a, end) else null,
        }, .guard = guard };
    }

    pub fn search(self: Queries, a: Allocator, access: Access, args: SearchArgs, cancel: ?*const CancelToken) !Checked(Page(Hit)) {
        try validateScope(args.library_ids, args.folder_id);
        if (args.limit == 0 or args.limit > max_page or args.query.len > max_query_bytes or !std.unicode.utf8ValidateSlice(args.query)) return error.InvalidArguments;
        const query = std.mem.trim(u8, args.query, whitespace);
        if (query.len == 0) return error.InvalidArguments;

        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const work = scratch.allocator();
        const captured = try self.store.captureQuery(work, .{
            .access = access,
            .library_ids = args.library_ids,
            .folder_id = args.folder_id,
            .documents = .descendants,
        }, cancel);
        const guard = try guardFor(a, access, captured);
        const paging = self.pagination(guard, .search, args.library_ids, args.folder_id, query, args.limit);
        const offset = try paging.offset(args.cursor);

        var matches: std.ArrayList(Ranked) = .empty;
        for (captured) |snapshot| for (snapshot.notes) |note| {
            try checkCancel(cancel);
            const path = pathOf(snapshot.library, note.folder_id);
            if (try rank(note, path.slice(), query, cancel)) |match| {
                try matches.append(work, .{ .note = note, .path = path, .match = match });
            }
        };
        std.mem.sort(Ranked, matches.items, {}, lessMatch);
        const end = try pageEnd(matches.items.len, offset, args.limit);
        const page = try a.alloc(Hit, end - offset);
        for (page, matches.items[offset..end]) |*hit, match| {
            const note = match.note;
            const range = excerptRange(note.body_md, match.match.body_position);
            hit.* = .{
                .library_id = note.library_id,
                .note_id = note.id,
                .title = try a.dupe(u8, note.title),
                .path = try copyPath(a, match.path),
                .revision = note.revision,
                .start_byte = range.start_byte,
                .end_byte = range.end_byte,
                .excerpt = try a.dupe(u8, note.body_md[range.start_byte..range.end_byte]),
                .source_ref = try (SourceRef{ .key = note.key(), .revision = note.revision, .range = range }).format(a),
            };
        }
        try self.revalidate(access, guard, cancel);
        return .{ .value = .{ .entries = page, .next_cursor = if (end < matches.items.len) try paging.format(a, end) else null }, .guard = guard };
    }

    pub fn read(self: Queries, a: Allocator, access: Access, args: ReadArgs, cancel: ?*const CancelToken) !Checked(ReadResult) {
        if (args.max_bytes == 0 or args.max_bytes > 32 * 1024 or (args.start_byte != 0 and args.expected_revision == null)) return error.InvalidArguments;
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const work = scratch.allocator();
        const captured = try self.locate(work, access, args.note_id, cancel);
        const note = captured.notes[0];
        try requireRevision(note, args.expected_revision);
        const start = args.start_byte;
        if (!validBoundary(note.body_md, start)) return error.InvalidArguments;
        const end = previousBoundary(note.body_md, start + @min(note.body_md.len - start, args.max_bytes));
        if (end == start and start != note.body_md.len) return error.ResultLimit;
        const guard = try documentGuard(a, access, captured.fence, note.key());
        const range: Range = .{ .start_byte = start, .end_byte = end };
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var refs: std.ArrayList([]const u8) = .empty;
        var images = assets.ReferenceIterator.init(note.body_md);
        while (images.next()) |image| {
            try checkCancel(cancel);
            const asset = image.relative_path;
            const position = @intFromPtr(asset.ptr) - @intFromPtr(note.body_md.ptr);
            if (position < start or position + asset.len > end) continue;
            const entry = try seen.getOrPut(work, asset);
            if (!entry.found_existing) try refs.append(a, try a.dupe(u8, asset));
        }
        const value: ReadResult = .{
            .library_id = note.library_id,
            .note_id = note.id,
            .title = try a.dupe(u8, note.title),
            .path = try copyPath(a, pathOf(captured.library, note.folder_id)),
            .revision = note.revision,
            .body_md = try a.dupe(u8, note.body_md[start..end]),
            .start_byte = start,
            .end_byte = end,
            .next_byte = if (end < note.body_md.len) end else null,
            .image_refs = try refs.toOwnedSlice(a),
            .source_ref = try (SourceRef{ .key = note.key(), .revision = note.revision, .range = range }).format(a),
        };
        try self.revalidate(access, guard, cancel);
        return .{ .value = value, .guard = guard };
    }

    pub fn prepareImage(self: Queries, a: Allocator, access: Access, args: ImageArgs, cancel: ?*const CancelToken) !Checked(PreparedImage) {
        if (args.expected_revision == 0 or args.asset_ref.len == 0 or args.asset_ref.len > 128) return error.InvalidArguments;
        const captured = try self.locate(a, access, args.note_id, cancel);
        const note = captured.notes[0];
        try requireRevision(note, args.expected_revision);
        if (!assets.isReferenced(note.body_md, args.asset_ref)) return error.Unavailable;
        const guard = try documentGuard(a, access, captured.fence, note.key());
        const value: PreparedImage = .{ .key = note.key(), .body_md = note.body_md, .asset_ref = try a.dupe(u8, args.asset_ref) };
        try self.revalidate(access, guard, cancel);
        return .{ .value = value, .guard = guard };
    }

    pub fn resolveSource(self: Queries, a: Allocator, source: SourceRef, cancel: ?*const CancelToken) !SourceResolution {
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const captured = try self.store.captureQuery(scratch.allocator(), .{ .access = .user, .library_ids = &.{source.key.library_id}, .documents = .{ .one = source.key.note_id } }, cancel);
        if (captured.len == 0) return .{ .state = .deleted, .key = source.key };
        const note = captured[0].notes[0];
        if (note.revision != source.revision) return .{ .state = .updated, .key = source.key, .revision = note.revision };
        if (source.range.start_byte > source.range.end_byte or !validBoundary(note.body_md, source.range.start_byte) or !validBoundary(note.body_md, source.range.end_byte)) return error.InvalidArguments;
        return .{ .state = .current, .key = source.key, .revision = note.revision, .range = source.range };
    }

    pub fn hasReadableLibrary(self: Queries, a: Allocator, cancel: ?*const CancelToken) !bool {
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const libraries = try self.store.captureQuery(scratch.allocator(), .{ .access = .assistant, .documents = .none }, cancel);
        return libraries.len != 0;
    }

    pub fn revalidate(self: Queries, access: Access, guard: Guard, cancel: ?*const CancelToken) !void {
        if (access != guard.access) return error.Unavailable;
        return self.store.revalidateQuery(access, guard.fences, guard.target, cancel);
    }

    fn locate(self: Queries, a: Allocator, access: Access, id: model.NoteId, cancel: ?*const CancelToken) !storage.QueryLibrary {
        if (!id.valid()) return error.InvalidArguments;
        const captured = try self.store.captureQuery(a, .{ .access = access, .documents = .{ .one = id } }, cancel);
        if (captured.len == 0) return error.Unavailable;
        if (captured.len != 1) return error.InvalidRecordFile;
        return captured[0];
    }

    fn pagination(self: Queries, guard: Guard, operation: enum { list, search }, ids: []const model.LibraryId, folder: ?model.FolderId, query: []const u8, limit: usize) Pagination {
        var auth = Mac.init(&self.store.query_cursor_key);
        auth.update(@tagName(operation));
        auth.update(@tagName(guard.access));
        hashInt(&auth, query.len);
        auth.update(query);
        hashInt(&auth, limit);
        hashInt(&auth, ids.len);
        for (ids) |id| auth.update(&id.bytes);
        const folder_id = folder orelse model.FolderId{};
        auth.update(&folder_id.bytes);
        for (guard.fences) |fence| {
            auth.update(&fence.library_id.bytes);
            hashInt(&auth, fence.library_revision);
            hashInt(&auth, fence.access_revision);
            hashInt(&auth, fence.documents_revision orelse 0);
        }
        return .{ .auth = auth };
    }
};

const Mac = std.crypto.auth.hmac.sha2.HmacSha256;
const whitespace = " \t\r\n";

const Pagination = struct {
    auth: Mac,

    fn token(self: Pagination, start: usize, buffer: []u8) ![]const u8 {
        var auth = self.auth;
        hashInt(&auth, start);
        var mac: [Mac.mac_length]u8 = undefined;
        auth.final(&mac);
        return std.fmt.bufPrint(buffer, "n1:{d}:{s}", .{ start, std.fmt.bytesToHex(mac[0..16].*, .lower) });
    }

    fn format(self: Pagination, a: Allocator, start: usize) ![]const u8 {
        var buffer: [64]u8 = undefined;
        return a.dupe(u8, try self.token(start, &buffer));
    }

    fn offset(self: Pagination, input: ?[]const u8) !usize {
        const text = input orelse return 0;
        if (text.len > 64) return error.InvalidArguments;
        var fields = std.mem.splitScalar(u8, text, ':');
        if (!std.mem.eql(u8, fields.next() orelse "", "n1")) return error.InvalidArguments;
        const start = try decimal(usize, fields.next());
        const signature = fields.next() orelse return error.InvalidArguments;
        if (start == 0 or signature.len != 32 or fields.next() != null) return error.InvalidArguments;
        var buffer: [64]u8 = undefined;
        if (!std.mem.eql(u8, try self.token(start, &buffer), text)) return error.RevisionChanged;
        return start;
    }
};

fn hashInt(auth: *Mac, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    auth.update(&bytes);
}

fn decimal(comptime T: type, text: ?[]const u8) !T {
    const value = text orelse return error.InvalidArguments;
    if (value.len == 0 or value.len > 20) return error.InvalidArguments;
    for (value) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidArguments;
    return std.fmt.parseInt(T, value, 10) catch error.InvalidArguments;
}

fn pageEnd(count: usize, offset: usize, limit: usize) !usize {
    if (offset > count) return error.RevisionChanged;
    return offset + @min(count - offset, limit);
}

fn validateScope(ids: []const model.LibraryId, folder_id: ?model.FolderId) !void {
    if (ids.len > max_library_filter) return error.InvalidArguments;
    if (folder_id) |id| if (!id.valid()) return error.InvalidArguments;
    for (ids, 0..) |id, i| {
        if (!id.valid()) return error.InvalidArguments;
        for (ids[0..i]) |earlier| if (id.eql(earlier)) return error.InvalidArguments;
    }
}

fn guardFor(a: Allocator, access: Access, captured: []const storage.QueryLibrary) !Guard {
    const fences = try a.alloc(storage.QueryFence, captured.len);
    for (fences, captured) |*fence, snapshot| fence.* = snapshot.fence;
    return .{ .access = access, .fences = fences };
}

fn documentGuard(a: Allocator, access: Access, fence: storage.QueryFence, key: model.NoteKey) !Guard {
    return .{ .access = access, .fences = try a.dupe(storage.QueryFence, &.{fence}), .target = key };
}

fn checkCancel(cancel: ?*const CancelToken) !void {
    if (cancel) |token| if (token.isCancelled()) return error.Cancelled;
}

fn requireRevision(note: model.Note, expected: ?u64) !void {
    if (expected) |revision| {
        if (revision == 0) return error.InvalidArguments;
        if (revision != note.revision) return error.RevisionChanged;
    }
}

fn lessEntry(_: void, lhs: ListEntry, rhs: ListEntry) bool {
    if (lhs.kind != rhs.kind) return @backingInt(lhs.kind) < @backingInt(rhs.kind);
    switch (std.ascii.orderIgnoreCase(lhs.name, rhs.name)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    return switch (lhs.kind) {
        .library => idLess(lhs.library_id, rhs.library_id),
        .folder => idLess(lhs.folder_id.?, rhs.folder_id.?),
        .note => idLess(lhs.note_id.?, rhs.note_id.?),
    };
}

fn idLess(lhs: anytype, rhs: @TypeOf(lhs)) bool {
    return std.mem.order(u8, &lhs.bytes, &rhs.bytes) == .lt;
}

const Path = struct {
    parts: [3][]const u8,
    len: usize,

    fn slice(self: *const Path) []const []const u8 {
        return self.parts[0..self.len];
    }
};

fn pathOf(library: model.Library, folder_id: ?model.FolderId) Path {
    var path: Path = .{ .parts = .{ library.name, "", "" }, .len = 1 };
    if (folder_id) |id| {
        const folder = library.folders[library.folderIndex(id).?];
        if (folder.parent_id) |parent| {
            path.parts[1] = library.folders[library.folderIndex(parent).?].name;
            path.parts[2] = folder.name;
            path.len = 3;
        } else {
            path.parts[1] = folder.name;
            path.len = 2;
        }
    }
    return path;
}

fn copyPath(a: Allocator, path: Path) ![]const []const u8 {
    const result = try a.alloc([]const u8, path.len);
    for (result, path.slice()) |*dst, part| dst.* = try a.dupe(u8, part);
    return result;
}

const Match = struct {
    quality: enum { title_exact, title, path, body },
    body_position: ?usize = null,
};

const Ranked = struct {
    note: model.Note,
    path: Path,
    match: Match,
};

fn rank(note: model.Note, path: []const []const u8, query: []const u8, cancel: ?*const CancelToken) !?Match {
    if (std.ascii.eqlIgnoreCase(note.title, query)) return .{ .quality = .title_exact };
    var terms = std.mem.tokenizeAny(u8, query, whitespace);
    var match: Match = .{ .quality = .title };
    while (terms.next()) |term| {
        try checkCancel(cancel);
        if (std.ascii.findIgnoreCase(note.title, term) != null) continue;
        if (pathContains(path, term)) {
            if (match.quality == .title) match.quality = .path;
            continue;
        }
        const position = std.ascii.findIgnoreCase(note.body_md, term) orelse return null;
        match.quality = .body;
        match.body_position = @min(match.body_position orelse position, position);
    }
    return match;
}

fn pathContains(path: []const []const u8, term: []const u8) bool {
    for (path) |part| if (std.ascii.findIgnoreCase(part, term) != null) return true;
    return false;
}

fn lessMatch(_: void, lhs: Ranked, rhs: Ranked) bool {
    if (lhs.match.quality != rhs.match.quality) return @backingInt(lhs.match.quality) < @backingInt(rhs.match.quality);
    if (lhs.note.updated_at != rhs.note.updated_at) return lhs.note.updated_at > rhs.note.updated_at;
    if (!lhs.note.library_id.eql(rhs.note.library_id)) return idLess(lhs.note.library_id, rhs.note.library_id);
    return idLess(lhs.note.id, rhs.note.id);
}

fn validBoundary(text: []const u8, index: usize) bool {
    return index <= text.len and (index == text.len or text[index] & 0xc0 != 0x80);
}

fn previousBoundary(text: []const u8, end: usize) usize {
    var index = end;
    while (!validBoundary(text, index)) index -= 1;
    return index;
}

fn excerptRange(body: []const u8, position: ?usize) Range {
    const start = previousBoundary(body, (position orelse 0) -| excerpt_context);
    return .{ .start_byte = start, .end_byte = previousBoundary(body, start + @min(body.len - start, excerpt_bytes)) };
}
