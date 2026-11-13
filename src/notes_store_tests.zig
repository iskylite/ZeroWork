const std = @import("std");
const model = @import("plugins/notes/model.zig");
const Store = @import("plugins/notes/store.zig").Store;

const a = std.testing.allocator;
const io = std.testing.io;
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "notes hierarchy enforces two levels for every document and directory operation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(a, io, tmp.dir);
    defer store.deinit();

    const library = try store.createLibrary("　工作笔记　");
    try expectError(error.NameConflict, store.createLibrary("工作笔记"));
    const other = try store.createLibrary("个人笔记");
    const first = try store.createFolder(library, null, "服务器运维", 1);
    const second = try store.createFolder(library, first, "Nginx", 2);
    const sibling = try store.createFolder(library, null, "项目记录", 3);
    const foreign = try store.createFolder(other, null, "备忘", 1);
    try expectError(error.FolderDepthExceeded, store.createFolder(library, second, "第三级", 4));
    try expectError(error.FolderDepthExceeded, store.changeFolder(library, first, 4, .{ .move = sibling }));
    try expectError(error.FolderDepthExceeded, store.changeFolder(library, first, 4, .{ .move = second }));
    try expectError(error.FolderDepthExceeded, store.changeFolder(library, first, 4, .{ .move = first }));
    try expectError(error.Unavailable, store.createFolder(library, foreign, "跨库", 4));
    try expectError(error.NameConflict, store.createFolder(library, null, "服务器运维", 4));

    const root_note = try store.createNote(library, null, "约定");
    const first_note = try store.createNote(library, first, "约定");
    const second_note = try store.createNote(library, second, "约定");
    try expectError(error.Unavailable, store.changeNote(root_note, 1, .{ .move = foreign }));
    try expectEqual(@as(u64, 2), try store.changeNote(root_note, 1, .{ .move = second }));
    try expectEqual(@as(u64, 3), try store.changeNote(root_note, 2, .{ .save = .{ .title = "构建约定", .body_md = "正文" } }));
    const moved = try store.loadNote(a, root_note, .active);
    defer moved.deinit();
    try expect(moved.value.id.eql(root_note.note_id));
    try expect(moved.value.folder_id.?.eql(second));
    try expectEqualStrings("构建约定", moved.value.title);

    try expectEqual(@as(u64, 5), try store.changeFolder(library, first, 4, .{ .rename = "基础设施" }));
    try expectEqual(@as(u64, 6), try store.changeFolder(library, first, 5, .delete));
    try expectError(error.Unavailable, store.loadNote(a, first_note, .active));
    try expectError(error.Unavailable, store.loadNote(a, second_note, .active));
    try expectError(error.Unavailable, store.createNote(library, second, "不可写"));
    const visible = try store.listNoteIds(a, library, .active);
    defer a.free(visible);
    try expectEqual(@as(usize, 0), visible.len);
    const all = try store.listNoteIds(a, library, .include_deleted);
    defer a.free(all);
    try expectEqual(@as(usize, 3), all.len);
}

test "notes timestamps preserve creation across saves and read legacy records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(a, io, tmp.dir);
    defer store.deinit();
    const library = try store.createLibrary("时间");
    const key = try store.createNote(library, null, "笔记");
    const fresh = try store.loadNote(a, key, .active);
    defer fresh.deinit();
    try expectEqual(@as(?i64, fresh.value.updated_at), fresh.value.created_at);

    const filename = "notes/libraries/" ++ std.fmt.bytesToHex(library.bytes, .lower) ++ "/documents/" ++
        std.fmt.bytesToHex(key.note_id.bytes, .lower) ++ ".json";
    for ([_]u64{ 1, 2 }) |revision| {
        const legacy = try std.json.Stringify.valueAlloc(a, .{
            .id = key.note_id,
            .library_id = library,
            .folder_id = @as(?model.FolderId, null),
            .title = "旧笔记",
            .revision = revision,
            .updated_at = @as(i64, 123456789),
        }, .{});
        defer a.free(legacy);
        try tmp.dir.writeFile(io, .{ .sub_path = filename, .data = legacy });
        const saved = try store.commitNote(key, revision, .{ .save = .{ .title = "旧笔记", .body_md = "新内容" } });
        try expectEqual(if (revision == 1) @as(?i64, 123456789) else null, saved.timestamps.created_at);
        const reopened = try store.loadNote(a, key, .active);
        defer reopened.deinit();
        try expectEqual(saved.timestamps, reopened.value.timestamps());
    }
}

test "notes restore keeps stable IDs and requires a visible parent and explicit unique name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(a, io, tmp.dir);
    defer store.deinit();

    const library = try store.createLibrary("工作笔记");
    const first = try store.createFolder(library, null, "生产", 1);
    const second = try store.createFolder(library, first, "发布", 2);
    const note = try store.createNote(library, second, "配置");
    _ = try store.changeNote(note, 1, .delete);
    _ = try store.changeFolder(library, second, 3, .delete);
    _ = try store.changeFolder(library, first, 4, .delete);
    _ = try store.createFolder(library, null, "生产", 5);

    try expectError(error.NameConflict, store.changeFolder(library, first, 6, .{ .restore = null }));
    try expectError(error.ParentDeleted, store.changeFolder(library, second, 6, .{ .restore = null }));
    try expectError(error.ParentDeleted, store.changeNote(note, 2, .restore));
    try expectEqual(@as(u64, 7), try store.changeFolder(library, first, 6, .{ .restore = "生产（恢复）" }));
    try expectEqual(@as(u64, 8), try store.changeFolder(library, second, 7, .{ .restore = null }));
    try expectEqual(@as(u64, 3), try store.changeNote(note, 2, .restore));

    const restored = try store.loadNote(a, note, .active);
    defer restored.deinit();
    try expect(restored.value.id.eql(note.note_id));
    try expect(restored.value.folder_id.?.eql(second));
    try expectEqualStrings("配置", restored.value.title);

    _ = try store.changeLibrary(library, 8, .delete);
    _ = try store.createLibrary("工作笔记");
    try expectError(error.NameConflict, store.changeLibrary(library, 9, .{ .restore = null }));
    try expectError(error.Unavailable, store.loadLibrary(a, library, .active));
    try expectEqual(@as(u64, 10), try store.changeLibrary(library, 9, .{ .restore = "工作笔记（恢复）" }));
    const metadata = try store.loadLibrary(a, library, .active);
    defer metadata.deinit();
    try expect(metadata.value.id.eql(library));
    try expectEqualStrings("工作笔记（恢复）", metadata.value.name);
    try expectEqual(@as(u64, 3), metadata.value.access_revision);

    const libraries = try store.listLibraryIds(a, .active);
    defer a.free(libraries);
    try expectEqual(@as(usize, 2), libraries.len);

    const deleted_revision = try store.changeNote(note, restored.value.revision, .delete);
    var deleted = try store.loadNote(a, note, .include_deleted);
    defer deleted.deinit();
    // Current edits cannot delete a protected note. Seed an existing record with both fields.
    deleted.value.read_only = true;
    deleted.value.body_md = "保留的原始正文";
    const bytes = try std.json.Stringify.valueAlloc(a, deleted.value, .{});
    defer a.free(bytes);
    const note_path = "notes/libraries/" ++ std.fmt.bytesToHex(library.bytes, .lower) ++ "/documents/" ++
        std.fmt.bytesToHex(note.note_id.bytes, .lower) ++ ".json";
    try tmp.dir.writeFile(io, .{ .sub_path = note_path, .data = bytes });
    try expectError(error.Unavailable, store.loadNote(a, note, .active));

    const protected_revision = try store.changeNote(note, deleted_revision, .restore);
    const protected = try store.loadNote(a, note, .active);
    defer protected.deinit();
    try expect(protected.value.id.eql(note.note_id));
    try expect(protected.value.folder_id.?.eql(second));
    try expect(protected.value.read_only);
    try expectEqualStrings(deleted.value.body_md, protected.value.body_md);
    try expectError(error.ReadOnly, store.changeNote(note, protected_revision, .delete));
}

test "notes revision guards stale saves and read-only blocks direct and ancestor changes after reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const body = try std.mem.join(a, "", &@as([500][]const u8, @splat("测试文档。")));
    defer a.free(body);
    const key, const first, const second = seed: {
        var store = try Store.init(a, io, tmp.dir);
        defer store.deinit();
        const library = try store.createLibrary("项目");
        const first = try store.createFolder(library, null, "归档", 1);
        const second = try store.createFolder(library, first, "生产", 2);
        const key = try store.createNote(library, second, "说明");
        try expectEqual(@as(u64, 2), try store.changeNote(key, 1, .{ .lock = .{ .title = "完整正文", .body_md = body } }));
        try expectError(error.RevisionChanged, store.changeNote(key, 1, .{ .save = .{ .title = "旧草稿", .body_md = "" } }));
        break :seed .{ key, first, second };
    };
    var store = try Store.init(a, io, tmp.dir);
    defer store.deinit();

    const saved = try store.loadNote(a, key, .active);
    defer saved.deinit();
    try expect(saved.value.read_only);
    try expectEqualStrings(body, saved.value.body_md);
    try expectEqualStrings("完整正文", saved.value.title);
    try expectError(error.ReadOnly, store.changeNote(key, 2, .{ .save = .{ .title = "保护中", .body_md = "不要保存" } }));
    try expectError(error.ReadOnly, store.changeNote(key, 2, .{ .move = null }));
    try expectError(error.ReadOnly, store.changeNote(key, 2, .delete));
    try expectError(error.ProtectedDocument, store.changeFolder(key.library_id, first, 3, .{ .rename = "新名" }));
    try expectError(error.ProtectedDocument, store.changeFolder(key.library_id, first, 3, .delete));
    try expectError(error.ProtectedDocument, store.changeFolder(key.library_id, second, 3, .{ .move = null }));
    try expectError(error.ProtectedDocument, store.changeLibrary(key.library_id, 3, .{ .rename = "新项目" }));
    try expectError(error.ProtectedDocument, store.changeLibrary(key.library_id, 3, .delete));

    const initial_library = try store.loadLibrary(a, key.library_id, .active);
    defer initial_library.deinit();
    try expect(!initial_library.value.ai_readable);
    try expectEqual(@as(u64, 4), try store.changeLibrary(key.library_id, 3, .{ .ai_readable = true }));
    const enabled = try store.loadLibrary(a, key.library_id, .active);
    defer enabled.deinit();
    try expect(enabled.value.ai_readable);
    try expectEqual(@as(u64, 2), enabled.value.access_revision);
    try expectEqual(@as(u64, 5), try store.changeLibrary(key.library_id, 4, .{ .ai_readable = false }));
    const disabled = try store.loadLibrary(a, key.library_id, .active);
    defer disabled.deinit();
    try expect(!disabled.value.ai_readable);
    try expectEqual(@as(u64, 3), disabled.value.access_revision);
    try expectEqual(@as(u64, 3), try store.changeNote(key, 2, .unlock));
    try expectEqual(@as(u64, 4), try store.changeNote(key, 3, .{ .move = null }));
}

fn failReplace(_: ?*anyopaque, _: std.Io.Dir, _: []const u8, _: std.Io.Dir, _: []const u8) std.Io.Dir.RenameError!void {
    return error.AccessDenied;
}

test "notes failed atomic replacement preserves committed body and lock state and allows retry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(a, io, tmp.dir);
    defer store.deinit();
    const library = try store.createLibrary("工作");
    const key = try store.createNote(library, null, "原始标题");
    _ = try store.changeNote(key, 1, .{ .save = .{ .title = "原始标题", .body_md = "原始正文" } });

    var broken = io.vtable.*;
    broken.dirRename = failReplace;
    store.io.vtable = &broken;
    const draft: @import("plugins/notes/store.zig").Draft = .{ .title = "新标题", .body_md = "新正文" };
    try expectError(error.AccessDenied, store.changeNote(key, 2, .{ .lock = draft }));
    store.io = io;

    const before_retry = try store.loadNote(a, key, .active);
    defer before_retry.deinit();
    try expectEqual(@as(u64, 2), before_retry.value.revision);
    try expect(!before_retry.value.read_only);
    try expectEqualStrings("原始标题", before_retry.value.title);
    try expectEqualStrings("原始正文", before_retry.value.body_md);
    try expectEqual(@as(u64, 3), try store.changeNote(key, 2, .{ .lock = draft }));
    const after_retry = try store.loadNote(a, key, .active);
    defer after_retry.deinit();
    try expect(after_retry.value.read_only);
    try expectEqualStrings(draft.title, after_retry.value.title);
    try expectEqualStrings(draft.body_md, after_retry.value.body_md);
}

test "notes records reject invalid names and a tampered folder cycle" {
    try expectError(error.InvalidName, model.normalizeName("　", model.max_directory_name));
    try expectError(error.InvalidName, model.normalizeName("行\n内", model.max_directory_name));
    try expectError(error.InvalidName, model.normalizeName("开\xc2\x81头", model.max_directory_name));
    const title = try std.mem.join(a, "", &@as([120][]const u8, @splat("文")));
    defer a.free(title);
    try expectError(error.NameTooLong, model.normalizeName(title[0 .. 81 * "文".len], model.max_directory_name));
    try expectEqualStrings(title, try model.normalizeName(title, model.max_title));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(a, io, tmp.dir);
    defer store.deinit();
    const library = try store.createLibrary("工作");
    const folder = model.FolderId.generate();
    const tampered: model.Library = .{
        .id = library,
        .name = "工作",
        .folders = &.{.{ .id = folder, .parent_id = folder, .name = "循环" }},
    };
    const bytes = try std.json.Stringify.valueAlloc(a, tampered, .{});
    defer a.free(bytes);
    const id_component = std.fmt.bytesToHex(library.bytes, .lower);
    const filename = "notes/libraries/" ++ id_component ++ "/library.json";
    try tmp.dir.writeFile(io, .{ .sub_path = filename, .data = bytes });
    try expectError(error.FolderDepthExceeded, store.loadLibrary(a, library, .active));
}

test "notes records use private permissions and reject symlinked records and directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(a, io, tmp.dir);
    defer store.deinit();
    const library = try store.createLibrary("工作");
    const key = try store.createNote(library, null, "路径验证");
    const library_path = "notes/libraries/" ++ std.fmt.bytesToHex(library.bytes, .lower);
    const documents_path = library_path ++ "/documents";
    const note_path = documents_path ++ "/" ++ std.fmt.bytesToHex(key.note_id.bytes, .lower) ++ ".json";

    for ([_][]const u8{ "notes", "notes/libraries", library_path, documents_path }) |path| {
        const stat = try tmp.dir.statFile(io, path, .{ .follow_symlinks = false });
        try expectEqual(@as(std.posix.mode_t, 0o700), stat.permissions.toMode() & 0o777);
    }
    for ([_][]const u8{ library_path ++ "/library.json", note_path }) |path| {
        const stat = try tmp.dir.statFile(io, path, .{ .follow_symlinks = false });
        try expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
    }
    try tmp.dir.rename(note_path, tmp.dir, "outside.json", io);
    try tmp.dir.symLink(io, "../../../../outside.json", note_path, .{});
    try expectError(error.InvalidRecordFile, store.loadNote(a, key, .active));
    try expectError(error.InvalidRecordFile, store.changeNote(key, 1, .delete));
    try expectError(error.InvalidRecordFile, store.changeLibrary(library, 1, .delete));

    try tmp.dir.rename(documents_path, tmp.dir, "outside_documents", io);
    try tmp.dir.symLink(io, "../../../outside_documents", documents_path, .{ .is_directory = true });
    if (store.createNote(library, null, "不能写到外面")) |_| {
        return error.FollowedDocumentsSymlink;
    } else |err| {
        try expect(err == error.SymLinkLoop or err == error.NotDir);
    }
    const outside = try tmp.dir.openDir(io, "outside_documents", .{ .iterate = true });
    defer outside.close(io);
    var entries = outside.iterate();
    try expect((try entries.next(io)).?.kind == .sym_link);
    try expect((try entries.next(io)) == null);
}

test "notes serializes concurrent writes against the same revision" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(a, io, tmp.dir);
    defer store.deinit();
    const library = try store.createLibrary("工作");
    const key = try store.createNote(library, null, "并发编辑");
    const Writer = struct {
        store: *Store,
        key: model.NoteKey,
        text: []const u8,
        result: anyerror!u64 = error.Unset,

        fn run(self: *@This()) void {
            self.result = self.store.changeNote(self.key, 1, .{ .save = .{ .title = self.text, .body_md = self.text } });
        }
    };
    var first: Writer = .{ .store = &store, .key = key, .text = "甲" };
    var second: Writer = .{ .store = &store, .key = key, .text = "乙" };
    const first_thread = try std.Thread.spawn(.{}, Writer.run, .{&first});
    {
        defer first_thread.join();
        const second_thread = try std.Thread.spawn(.{}, Writer.run, .{&second});
        second_thread.join();
    }

    const saved = try store.loadNote(a, key, .active);
    defer saved.deinit();
    if (first.result) |revision| {
        try expectEqual(@as(u64, 2), revision);
        try expectError(error.RevisionChanged, second.result);
        try expectEqualStrings(first.text, saved.value.body_md);
    } else |err| {
        try expectEqual(error.RevisionChanged, err);
        try expectEqual(@as(u64, 2), try second.result);
        try expectEqualStrings(second.text, saved.value.body_md);
    }
}
