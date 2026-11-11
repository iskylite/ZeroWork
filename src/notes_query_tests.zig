const std = @import("std");
const storage = @import("plugins/notes/store.zig");
const model = @import("plugins/notes/model.zig");
const query = @import("plugins/notes/queries.zig");

const a = std.testing.allocator;
const io = std.testing.io;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;
const asset = "assets/" ++ @as([64]u8, @splat('a')) ++ ".png";

fn seedNote(store: *storage.Store, library: model.LibraryId, folder: ?model.FolderId, title: []const u8, body: []const u8) !model.NoteKey {
    const key = try store.createNote(library, folder, title);
    _ = try store.changeNote(key, 1, .{ .save = .{ .title = title, .body_md = body } });
    return key;
}

test "notes queries restrict all assistant reads before ranking and revoke outstanding results" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try storage.Store.init(a, io, temporary.dir);
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const q: query.Queries = .{ .store = &store };

    const public = try store.createLibrary("工作资料");
    const private = try store.createLibrary("私密目录");
    const hidden = try seedNote(&store, private, null, "证书", "![](" ++ asset ++ ")");
    const allowed = try seedNote(&store, public, null, "生产部署", "请检查证书。\n\n![拓扑](" ++ asset ++ ")");
    try expect(!try q.hasReadableLibrary(a, null));
    try expectEqual(@as(usize, 0), (try q.list(alloc, .assistant, .{}, null)).value.entries.len);

    _ = try store.changeLibrary(public, 1, .{ .ai_readable = true });
    try expect(try q.hasReadableLibrary(a, null));
    const libraries = try q.list(alloc, .assistant, .{}, null);
    try expectEqual(@as(usize, 1), libraries.value.entries.len);
    try expectEqualStrings("工作资料", libraries.value.entries[0].name);
    try expectError(error.Unavailable, q.list(alloc, .assistant, .{ .library_id = private }, null));

    const results = try q.search(alloc, .assistant, .{ .query = "证书", .limit = 1 }, null);
    try expectEqual(@as(usize, 1), results.value.entries.len);
    try expect(results.value.entries[0].note_id.eql(allowed.note_id));
    try expect(results.value.next_cursor == null);
    const local = try q.search(alloc, .user, .{ .query = "证书", .limit = 1 }, null);
    try expect(local.value.entries[0].note_id.eql(hidden.note_id));
    try expectError(error.Unavailable, q.revalidate(.assistant, local.guard, null));

    try expectError(error.Unavailable, q.read(alloc, .assistant, .{ .note_id = hidden.note_id, .expected_revision = 99 }, null));
    try expectError(error.Unavailable, q.prepareImage(alloc, .assistant, .{ .note_id = hidden.note_id, .expected_revision = 2, .asset_ref = asset }, null));
    const read = try q.read(alloc, .assistant, .{ .note_id = allowed.note_id }, null);
    try expectEqualStrings(asset, read.value.image_refs[0]);
    const image = try q.prepareImage(alloc, .assistant, .{ .note_id = allowed.note_id, .expected_revision = 2, .asset_ref = asset }, null);
    try expect(image.value.key.library_id.eql(public));
    try expectError(error.Unavailable, q.prepareImage(alloc, .assistant, .{ .note_id = allowed.note_id, .expected_revision = 2, .asset_ref = "assets/unreferenced.png" }, null));

    const source = try query.SourceRef.parse(read.value.source_ref);
    _ = try store.changeLibrary(public, 2, .{ .ai_readable = false });
    try expectError(error.Unavailable, q.revalidate(.assistant, libraries.guard, null));
    try expectError(error.Unavailable, q.revalidate(.assistant, results.guard, null));
    try expectError(error.Unavailable, q.revalidate(.assistant, read.guard, null));
    try expectError(error.Unavailable, q.revalidate(.assistant, image.guard, null));
    try expectError(error.Unavailable, q.read(alloc, .assistant, .{ .note_id = source.key.note_id, .expected_revision = source.revision }, null));
    try expectEqual(.current, (try q.resolveSource(a, source, null)).state);

    _ = try store.changeLibrary(public, 3, .{ .ai_readable = true });
    try expectError(error.RevisionChanged, q.revalidate(.assistant, image.guard, null));
    _ = try store.changeNote(allowed, 2, .{ .save = .{ .title = "生产部署", .body_md = "新版" } });
    try expectEqual(.updated, (try q.resolveSource(alloc, source, null)).state);
    _ = try store.changeNote(allowed, 3, .delete);
    try expectEqual(.deleted, (try q.resolveSource(alloc, source, null)).state);
    try expectError(error.Unavailable, q.revalidate(.assistant, read.guard, null));
}

test "notes queries rank matches, page stable results, and constrain direct children" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try storage.Store.init(a, io, temporary.dir);
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const q: query.Queries = .{ .store = &store };

    const library = try store.createLibrary("运维");
    const first = try store.createFolder(library, null, "证书目录", 1);
    const second = try store.createFolder(library, first, "生产", 2);
    const exact = try seedNote(&store, library, null, "证书", "检查更新");
    const title = try seedNote(&store, library, null, "证书发布", "检查更新");
    const path = try seedNote(&store, library, second, "发布", "检查更新");
    const prefix = try std.mem.join(alloc, "", &@as([51][]const u8, @splat("开")));
    const suffix = try std.mem.join(alloc, "", &@as([140][]const u8, @splat("收")));
    const body = try std.mem.concat(alloc, u8, &.{ prefix, "请执行 `NGINX -t` 后更新证书。", suffix });
    const text = try seedNote(&store, library, null, "安装", body);

    var args: query.SearchArgs = .{ .query = "证书", .limit = 1 };
    const expected = [_]model.NoteKey{ exact, title, path, text };
    for (expected, 0..) |key, index| {
        const response = try q.search(alloc, .user, args, null);
        try expectEqual(@as(usize, 1), response.value.entries.len);
        const hit = response.value.entries[0];
        try expect(hit.note_id.eql(key.note_id));
        try expectEqual(index != expected.len - 1, response.value.next_cursor != null);
        args.cursor = response.value.next_cursor;
    }

    const narrowed = try q.search(alloc, .user, .{ .query = "发布 检查", .folder_id = first, .library_ids = &.{library} }, null);
    try expectEqual(@as(usize, 1), narrowed.value.entries.len);
    try expect(narrowed.value.entries[0].note_id.eql(path.note_id));
    try expectEqualStrings("生产", narrowed.value.entries[0].path[2]);
    const code = (try q.search(alloc, .user, .{ .query = "nginx -T 证书" }, null)).value.entries[0];
    try expect(code.note_id.eql(text.note_id));
    try expect(std.unicode.utf8ValidateSlice(code.excerpt));
    try expectEqualStrings(body[code.start_byte..code.end_byte], code.excerpt);
    try expect(std.mem.indexOf(u8, code.excerpt, "NGINX -t") != null);
    try expect(std.mem.indexOf(u8, code.excerpt, "证书") != null);
    const source = try query.SourceRef.parse(code.source_ref);
    try expectEqual(code.start_byte, source.range.start_byte);
    try expectEqual(code.end_byte, source.range.end_byte);

    const root = try q.list(alloc, .user, .{ .library_id = library }, null);
    try expectEqual(@as(usize, 4), root.value.entries.len);
    try expect(root.value.entries[0].folder_id.?.eql(first));
    const mid = try q.list(alloc, .user, .{ .library_id = library, .folder_id = first }, null);
    try expectEqual(@as(usize, 1), mid.value.entries.len);
    try expect(mid.value.entries[0].folder_id.?.eql(second));
    const leaf = try q.list(alloc, .user, .{ .library_id = library, .folder_id = second }, null);
    try expectEqual(@as(usize, 1), leaf.value.entries.len);
    try expect(leaf.value.entries[0].note_id.?.eql(path.note_id));

    const page1 = try q.search(alloc, .user, .{ .query = "证书", .limit = 1 }, null);
    try expectError(error.RevisionChanged, q.search(alloc, .user, .{ .query = "安装", .limit = 1, .cursor = page1.value.next_cursor }, null));
    _ = try store.changeNote(text, 2, .{ .save = .{ .title = "安装", .body_md = "替换正文" } });
    try expectError(error.RevisionChanged, q.search(alloc, .user, .{ .query = "证书", .limit = 1, .cursor = page1.value.next_cursor }, null));
    try expectError(error.RevisionChanged, q.revalidate(.user, page1.guard, null));
    const replaced = try q.search(alloc, .user, .{ .query = "nginx" }, null);
    try expectEqual(@as(usize, 0), replaced.value.entries.len);
    const original_path = try q.search(alloc, .user, .{ .query = "证书目录" }, null);
    try expectEqual(@as(usize, 1), original_path.value.entries.len);
    try expect(original_path.value.entries[0].note_id.eql(path.note_id));

    _ = try store.changeFolder(library, first, 3, .delete);
    try expectError(error.Unavailable, q.read(alloc, .user, .{ .note_id = path.note_id }, null));
    try expectEqual(@as(usize, 0), (try q.search(alloc, .user, .{ .query = "证书目录" }, null)).value.entries.len);
    _ = try store.createFolder(library, null, "证书目录", 4);
    try expectError(error.NameConflict, store.changeFolder(library, first, 5, .{ .restore = null }));
    _ = try store.changeFolder(library, first, 5, .{ .restore = "归档后目录" });

    try expectError(error.RevisionChanged, q.revalidate(.user, original_path.guard, null));
    try expectEqual(@as(usize, 0), (try q.search(alloc, .user, .{ .query = "证书目录" }, null)).value.entries.len);
    const restored_path = try q.search(alloc, .user, .{ .query = "归档后目录" }, null);
    try expectEqual(@as(usize, 1), restored_path.value.entries.len);
    const restored_hit = restored_path.value.entries[0];
    try expect(restored_hit.note_id.eql(path.note_id));
    try expectEqual(original_path.value.entries[0].revision, restored_hit.revision);
    try expectEqualStrings("归档后目录", restored_hit.path[1]);
    try expectEqualStrings("生产", restored_hit.path[2]);
}

test "notes queries page complete UTF-8 characters and validate targeted revisions" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try storage.Store.init(a, io, temporary.dir);
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const q: query.Queries = .{ .store = &store };

    const library = try store.createLibrary("笔记");
    const body = "中文😀ab";
    const key = try seedNote(&store, library, null, "测试", body);
    const first_response = try q.read(alloc, .user, .{ .note_id = key.note_id, .max_bytes = 8 }, null);
    const first = first_response.value;
    try expectEqualStrings("中文", first.body_md);
    try expectEqual(@as(?usize, 6), first.next_byte);
    try expectError(error.InvalidArguments, q.read(alloc, .user, .{ .note_id = key.note_id, .start_byte = 6 }, null));
    try expectError(error.InvalidArguments, q.read(alloc, .user, .{ .note_id = key.note_id, .start_byte = 7, .expected_revision = 2 }, null));
    try expectError(error.ResultLimit, q.read(alloc, .user, .{ .note_id = key.note_id, .start_byte = 6, .expected_revision = 2, .max_bytes = 3 }, null));
    const second = (try q.read(alloc, .user, .{ .note_id = key.note_id, .start_byte = 6, .expected_revision = 2, .max_bytes = 4 }, null)).value;
    try expectEqualStrings("😀", second.body_md);
    try expectEqual(@as(?usize, 10), second.next_byte);
    const end = (try q.read(alloc, .user, .{ .note_id = key.note_id, .start_byte = 10, .expected_revision = 2 }, null)).value;
    try expectEqualStrings("ab", end.body_md);
    try expect(end.next_byte == null);

    _ = try seedNote(&store, library, null, "其他", "无关文档");
    try q.revalidate(.user, first_response.guard, null);
    _ = try store.changeNote(key, 2, .{ .save = .{ .title = "测试", .body_md = body ++ "更新" } });
    try expectError(error.RevisionChanged, q.revalidate(.user, first_response.guard, null));
    try expectError(error.RevisionChanged, q.read(alloc, .user, .{ .note_id = key.note_id, .start_byte = 10, .expected_revision = 2 }, null));
    var cancelled: query.CancelToken = .{};
    cancelled.cancel();
    try expectError(error.Cancelled, q.read(alloc, .user, .{ .note_id = key.note_id }, &cancelled));
    try expectError(error.Cancelled, q.search(alloc, .user, .{ .query = "中文" }, &cancelled));
    try expectError(error.Cancelled, q.list(alloc, .user, .{}, &cancelled));
}
