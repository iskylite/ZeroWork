const std = @import("std");
const identity = @import("host/identity.zig");
const documents = @import("plugins/notes/document_sessions.zig");
const Store = @import("plugins/notes/store.zig").Store;

const a = std.testing.allocator;
const io = std.testing.io;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const expectStrings = std.testing.expectEqualStrings;
const first: identity.SessionHandle = .{ .session_id = @fromBackingInt(1) };
const second: identity.SessionHandle = .{ .session_id = @fromBackingInt(2) };

fn failReplace(_: ?*anyopaque, _: std.Io.Dir, _: []const u8, _: std.Io.Dir, _: []const u8) std.Io.Dir.RenameError!void {
    return error.AccessDenied;
}

test "notes document leases are shared by one owner and fenced after release" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(a, io, tmp.dir);
    defer store.deinit();
    var sessions = documents.Sessions.init(a, &store);
    defer sessions.deinit();
    const library = try store.createLibrary("工作");
    const key = try store.createNote(library, null, "运维");
    const lease = (try sessions.open(key, first)).lease;
    try expectEqual(lease, (try sessions.open(key, first)).lease);
    try expectEqual(first, (try sessions.open(key, second)).occupied);
    const stamp = (try sessions.snapshot(lease)).stamp;
    try sessions.edit(stamp, .{ .title = " 运维 ", .body_md = "私有草稿" });
    try expectError(error.StaleEdit, sessions.edit(stamp, .{ .title = "运维", .body_md = "过时回调" }));
    try expectStrings("运维", (try sessions.snapshot(lease)).title);
    const committed = try store.loadNote(a, key, .active);
    defer committed.deinit();
    try expectStrings("", committed.value.body_md);

    try sessions.releaseOwner(first);
    try expect(sessions.ownerFor(key) == null);
    try expectError(error.StaleLease, sessions.snapshot(lease));
    const replacement = (try sessions.open(key, second)).lease;
    try expect(replacement.epoch != lease.epoch);
    try expectError(error.StaleLease, sessions.edit(stamp, .{ .title = "运维", .body_md = "过时回调" }));
    const fresh = try sessions.snapshot(replacement);
    try expectStrings("私有草稿", fresh.body_md);
    try expect(!fresh.dirty);
    try sessions.release(replacement);
}

test "notes document save receipt keeps edits made during the worker save" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(a, io, tmp.dir);
    defer store.deinit();
    var sessions = documents.Sessions.init(a, &store);
    defer sessions.deinit();
    const key = try store.createNote(try store.createLibrary("目录"), null, "笔记");
    const lease = (try sessions.open(key, first)).lease;
    const initial = try sessions.snapshot(lease);
    try sessions.edit(initial.stamp, .{ .title = "笔记", .body_md = "第一版" });
    var packet = (try sessions.beginSave(lease, .save)).?;
    defer packet.deinit(a);
    const queued = try sessions.snapshot(lease);
    try expectEqual(.save, queued.saving.?);
    try expectError(error.SaveInProgress, sessions.releaseOwner(first));
    try sessions.edit(queued.stamp, .{ .title = "笔记", .body_md = "第二版" });
    const Worker = struct {
        fn run(commit: documents.Commit, repo: *Store, result: *documents.Receipt) void {
            result.* = commit.run(repo);
        }
    };
    var receipt: documents.Receipt = undefined;
    const worker = try std.Thread.spawn(.{}, Worker.run, .{ packet, &store, &receipt });
    worker.join();
    try sessions.finishSave(receipt);
    try expectError(error.StaleSave, sessions.finishSave(receipt));
    const first_commit = try store.loadNote(a, key, .active);
    defer first_commit.deinit();
    try expectStrings("第一版", first_commit.value.body_md);
    const newer = try sessions.snapshot(lease);
    try expect(newer.dirty);
    try expectEqual(first_commit.value.revision, newer.stamp.base_revision);
    try expectStrings("第二版", newer.body_md);
    try sessions.flushOwner(first);
    const second_commit = try store.loadNote(a, key, .active);
    defer second_commit.deinit();
    try expectStrings("第二版", second_commit.value.body_md);
    try expect(!(try sessions.snapshot(lease)).dirty);
}

test "notes document autosave debounces landed edits and retains failures for retry" {
    const Clock = struct {
        threadlocal var elapsed: i96 = 0;

        fn now(raw: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
            return if (clock == .awake) .fromNanoseconds(elapsed) else io.vtable.now(raw, clock);
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(a, io, tmp.dir);
    defer store.deinit();
    var timed_io = io.vtable.*;
    timed_io.now = Clock.now;
    store.io.vtable = &timed_io;
    Clock.elapsed = 0;
    var sessions = documents.Sessions.init(a, &store);
    defer sessions.deinit();
    const key = try store.createNote(try store.createLibrary("目录"), null, "笔记");
    const lease = (try sessions.open(key, first)).lease;
    const delay = documents.Sessions.save_delay_ns;
    try sessions.edit((try sessions.snapshot(lease)).stamp, .{ .title = "笔记", .body_md = "一" });
    Clock.elapsed = delay - 1;
    try expect((try sessions.beginDueSave(first)) == null);
    try sessions.edit((try sessions.snapshot(lease)).stamp, .{ .title = "笔记", .body_md = "二" });
    Clock.elapsed = 2 * delay - 2;
    try expect((try sessions.beginDueSave(first)) == null);
    Clock.elapsed += 1;
    try expect((try sessions.beginDueSave(second)) == null);
    var packet = (try sessions.beginDueSave(first)).?;
    defer packet.deinit(a);
    try expectError(error.AccessDenied, sessions.finishSave(packet.failed(error.AccessDenied)));
    Clock.elapsed += delay;
    try expect((try sessions.beginDueSave(first)) == null);
    try expect((try sessions.snapshot(lease)).dirty);
    try sessions.flush(lease);
    const committed = try store.loadNote(a, key, .active);
    defer committed.deinit();
    try expectStrings("二", committed.value.body_md);
}

test "notes document lock commits all text or keeps the editable draft and gates close" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(a, io, tmp.dir);
    defer store.deinit();
    var sessions = documents.Sessions.init(a, &store);
    defer sessions.deinit();
    const key = try store.createNote(try store.createLibrary("目录"), null, "旧标题");
    const lease = (try sessions.open(key, first)).lease;
    try sessions.edit((try sessions.snapshot(lease)).stamp, .{ .title = "新标题", .body_md = "完整正文" });
    const dirty = try sessions.snapshot(lease);

    var fault = io.vtable.*;
    fault.dirRename = failReplace;
    store.io.vtable = &fault;
    var attempt = (try sessions.beginSave(lease, .lock)).?;
    defer attempt.deinit(a);
    try expectError(error.SaveInProgress, sessions.edit(dirty.stamp, .{ .title = "新标题", .body_md = "暂缓编辑" }));
    try expect(!(try sessions.snapshot(lease)).read_only);
    try expectError(error.AccessDenied, sessions.finishSave(attempt.run(&store)));
    try expectError(error.AccessDenied, sessions.releaseOwner(first));
    const retained = try sessions.snapshot(lease);
    try expect(retained.dirty and !retained.read_only);
    try expectEqual(error.AccessDenied, retained.save_error.?);
    try expectStrings("完整正文", retained.body_md);
    const prior = try store.loadNote(a, key, .active);
    defer prior.deinit();
    try expectStrings("旧标题", prior.value.title);
    try expect(!prior.value.read_only);
    try expectEqual(first, (try sessions.open(key, second)).occupied);

    store.io = io;
    try sessions.setReadOnly(lease, true);
    const locked = try sessions.snapshot(lease);
    try expect(locked.read_only and !locked.dirty and locked.save_error == null);
    try expectError(error.ReadOnly, sessions.edit(locked.stamp, .{ .title = "新标题", .body_md = "只读" }));
    try expectError(error.ReadOnly, sessions.move(locked.stamp, null));
    try expectError(error.ReadOnly, sessions.delete(locked.stamp));
    const saved = try store.loadNote(a, key, .active);
    defer saved.deinit();
    try expectEqual(locked.stamp.base_revision, saved.value.revision);
    try expectStrings("完整正文", saved.value.body_md);
    try expect(saved.value.read_only);

    store.io.vtable = &fault;
    try expectError(error.AccessDenied, sessions.setReadOnly(lease, false));
    try expect((try sessions.snapshot(lease)).read_only);
    store.io = io;
    try sessions.setReadOnly(lease, false);
    try expectError(error.StaleEdit, sessions.edit(dirty.stamp, .{ .title = "新标题", .body_md = "过期" }));
    try sessions.release(lease);
}

test "notes document imports keep virtual anchors and reject stale completions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(a, io, tmp.dir);
    defer store.deinit();
    var sessions = documents.Sessions.init(a, &store);
    defer sessions.deinit();
    const key = try store.createNote(try store.createLibrary("目录"), null, "笔记");
    const lease = (try sessions.open(key, first)).lease;
    try sessions.edit((try sessions.snapshot(lease)).stamp, .{ .title = "笔记", .body_md = "甲乙丙" });
    const stamp = (try sessions.snapshot(lease)).stamp;
    try expectError(error.InvalidRange, sessions.beginImport(stamp, .{ .start = 1, .end = 3 }));
    const ticket = try sessions.beginImport(stamp, .{ .start = 3, .end = 6 });
    try expectError(error.ImportInProgress, sessions.setReadOnly(lease, true));
    try expectError(error.ImportInProgress, sessions.release(lease));
    try sessions.edit(stamp, .{ .title = "笔记", .body_md = "前甲乙丙" });
    const anchored = try sessions.snapshot(lease);
    try expectEqual(documents.Range{ .start = 6, .end = 9 }, anchored.pending_import.?);
    try expectStrings("前甲乙丙", anchored.body_md);
    const link = "![图片](assets/0000000000000000000000000000000000000000000000000000000000000000.png)";
    try sessions.completeImport(ticket, link);
    try expectStrings("前甲" ++ link ++ "丙", (try sessions.snapshot(lease)).body_md);
    try expectError(error.StaleImport, sessions.completeImport(ticket, link));

    const snapshot = try sessions.snapshot(lease);
    const crossing = try sessions.beginImport(snapshot.stamp, .{ .start = 3, .end = 6 });
    try sessions.edit(snapshot.stamp, .{ .title = "笔记", .body_md = "前丁" ++ link ++ "丙" });
    try expectError(error.StaleImport, sessions.completeImport(crossing, link));
    const updated = try sessions.snapshot(lease);
    const cancelled = try sessions.beginImport(updated.stamp, .{ .start = 0, .end = 0 });
    try sessions.cancelImport(cancelled);
    try sessions.setReadOnly(lease, true);
    const persisted = try store.loadNote(a, key, .active);
    defer persisted.deinit();
    try expectStrings("前丁" ++ link ++ "丙", persisted.value.body_md);
    try expect(persisted.value.read_only);
}

test "notes document moves and deletes require the current editable lease" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(a, io, tmp.dir);
    defer store.deinit();
    var sessions = documents.Sessions.init(a, &store);
    defer sessions.deinit();
    const library = try store.createLibrary("目录");
    const folder = try store.createFolder(library, null, "项目", 1);
    const key = try store.createNote(library, null, "笔记");
    const lease = (try sessions.open(key, first)).lease;
    const initial = (try sessions.snapshot(lease)).stamp;
    try sessions.edit(initial, .{ .title = "笔记", .body_md = "保留" });
    try expectError(error.StaleEdit, sessions.move(initial, folder));
    try sessions.move((try sessions.snapshot(lease)).stamp, folder);
    const moved = try sessions.snapshot(lease);
    try expect(folder.eql(moved.folder_id.?));
    try expectStrings("保留", moved.body_md);
    try sessions.delete(moved.stamp);
    try expectError(error.StaleLease, sessions.snapshot(lease));
    try expectError(error.Unavailable, sessions.open(key, second));
    const deleted = try store.loadNote(a, key, .include_deleted);
    defer deleted.deinit();
    try expect(deleted.value.deleted_at != null);
    try expectStrings("保留", deleted.value.body_md);
}

test "notes document undo crosses blocks and image insertions without crossing leases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(a, io, tmp.dir);
    defer store.deinit();
    var sessions = documents.Sessions.init(a, &store);
    defer sessions.deinit();
    const library = try store.createLibrary("目录");
    const key = try store.createNote(library, null, "笔记");
    const other_key = try store.createNote(library, null, "其他笔记");
    const lease = (try sessions.open(key, first)).lease;
    const other = (try sessions.open(other_key, first)).lease;

    const initial = try sessions.snapshot(lease);
    const two_blocks = "上段\n\n下段";
    try sessions.edit(initial.stamp, .{ .title = "笔记", .body_md = two_blocks });
    const before_edit = try sessions.snapshot(lease);
    try sessions.recordBodyChange(before_edit.stamp, initial.body_generation, .{ .start = 0, .end = two_blocks.len }, "");

    const edited_blocks = "上段\n\n下段已编辑";
    try sessions.edit(before_edit.stamp, .{ .title = "笔记", .body_md = edited_blocks });
    const edited = try sessions.snapshot(lease);
    try expectError(error.UnrecordedBodyChange, sessions.undo(edited.stamp));
    try sessions.recordBodyChange(edited.stamp, before_edit.body_generation, .{ .start = "上段\n\n".len, .end = edited_blocks.len }, "下段");
    const ticket = try sessions.beginImport(edited.stamp, .{ .start = edited_blocks.len, .end = edited_blocks.len });
    const image = "\n\n![图](assets/example.png)";
    try sessions.completeImport(ticket, image);
    const inserted = try sessions.snapshot(lease);
    try expect(inserted.can_undo and !inserted.can_redo);
    try expect(!(try sessions.undo((try sessions.snapshot(other)).stamp)));
    try expect(try sessions.undo(inserted.stamp));
    const no_image = try sessions.snapshot(lease);
    try expectStrings(edited_blocks, no_image.body_md);
    try expect(no_image.can_redo);
    try expect(try sessions.undo(no_image.stamp));
    const previous = try sessions.snapshot(lease);
    try expectStrings(two_blocks, previous.body_md);

    try sessions.setReadOnly(lease, true);
    const locked = try sessions.snapshot(lease);
    try expect(!locked.can_redo);
    try expectError(error.ReadOnly, sessions.redo(locked.stamp));
    try sessions.setReadOnly(lease, false);
    try expect(try sessions.redo((try sessions.snapshot(lease)).stamp));
    const redone = try sessions.snapshot(lease);
    try expectStrings(edited_blocks, redone.body_md);
    try expect(try sessions.redo(redone.stamp));
    try expectStrings(edited_blocks ++ image, (try sessions.snapshot(lease)).body_md);
    try sessions.releaseOwner(first);
    const reopened = (try sessions.open(key, second)).lease;
    const stored = try sessions.snapshot(reopened);
    try expectStrings(edited_blocks ++ image, stored.body_md);
    try expect(!stored.can_undo and !stored.can_redo);
}

test "notes document protects an active draft when deleting an ancestor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(a, io, tmp.dir);
    defer store.deinit();
    var sessions = documents.Sessions.init(a, &store);
    defer sessions.deinit();
    const library_id = try store.createLibrary("目录");
    const ancestor = try store.createFolder(library_id, null, "项目", 1);
    const descendant = try store.createFolder(library_id, ancestor, "运维", 2);
    const sibling = try store.createFolder(library_id, null, "其他项目", 3);
    const key = try store.createNote(library_id, descendant, "笔记");
    const lease = (try sessions.open(key, first)).lease;
    try sessions.edit((try sessions.snapshot(lease)).stamp, .{ .title = "笔记", .body_md = "草稿" });
    const library = try store.loadLibrary(a, library_id, .active);
    defer library.deinit();
    try expectError(error.DocumentInUse, sessions.requireUnleasedSubtree(library.value, ancestor));
    try expectError(error.DocumentInUse, sessions.requireUnleasedSubtree(library.value, descendant));
    try expectError(error.DocumentInUse, sessions.requireUnleasedSubtree(library.value, null));
    try sessions.requireUnleasedSubtree(library.value, sibling);
    try sessions.releaseOwner(first);
    try sessions.requireUnleasedSubtree(library.value, ancestor);
}
