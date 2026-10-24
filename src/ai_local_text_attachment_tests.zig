const std = @import("std");
const attachments = @import("ai/local_text_attachments.zig");
const host = @import("host/ai_local_text_snapshot.zig");
const store_mod = @import("ai/assistant_store.zig");
const CancelToken = @import("ai/provider.zig").CancelToken;
const a = std.testing.allocator;
const io = std.testing.io;

fn pathIn(directory: std.Io.Dir, name: []const u8) ![]u8 {
    const directory_path = try directory.realPathFileAlloc(io, ".", a);
    defer a.free(directory_path);
    return std.fs.path.join(a, &.{ directory_path, name });
}

test "AI local text actual file accepts exactly 64 KiB and refuses larger sources without truncation" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const bytes = try a.alloc(u8, 96 * 1024);
    defer a.free(bytes);
    @memset(bytes, 'a');
    var cancel: CancelToken = .{};
    for ([_]usize{ attachments.max_bytes, attachments.max_bytes + 1, bytes.len }) |size| {
        try temp.dir.writeFile(io, .{ .sub_path = "not-extension-driven.bin", .data = bytes[0..size] });
        const path = try pathIn(temp.dir, "not-extension-driven.bin");
        defer a.free(path);
        if (size <= attachments.max_bytes) {
            var value = try host.capture(a, io, path, &cancel);
            defer value.release();
            try std.testing.expectEqual(size, value.content().?.bytes.len);
            try std.testing.expectEqualStrings(bytes[0..size], value.content().?.bytes);
            try std.testing.expectEqualStrings(path, value.content().?.path);
            try std.testing.expect(value.content().?.captured_at_ms > 0);
        } else try std.testing.expectError(error.LocalTextTooLarge, host.capture(a, io, path, &cancel));
    }
}

test "AI local text actual file validates UTF8 NUL ZIP and keeps original BOM bytes" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try pathIn(temp.dir, "chosen.txt");
    defer a.free(path);
    var cancel: CancelToken = .{};
    for ([_]struct { bytes: []const u8, failure: anyerror }{
        .{ .bytes = "text\x00hidden", .failure = error.BinaryLocalText },
        .{ .bytes = "\xc3\x28", .failure = error.InvalidLocalTextEncoding },
        .{ .bytes = "PK\x03\x04archive", .failure = error.BinaryLocalText },
        .{ .bytes = "PK\x05\x06archive", .failure = error.BinaryLocalText },
    }) |fixture| {
        try temp.dir.writeFile(io, .{ .sub_path = "chosen.txt", .data = fixture.bytes });
        try std.testing.expectError(fixture.failure, host.capture(a, io, path, &cancel));
    }
    const original = "\xef\xbb\xbf中文\ntext";
    try temp.dir.writeFile(io, .{ .sub_path = "chosen.txt", .data = original });
    var valid = try host.capture(a, io, path, &cancel);
    defer valid.release();
    try std.testing.expect(valid.content().?.bom_preserved);
    try std.testing.expectEqualStrings(original, valid.content().?.bytes);
}

test "AI local text immutable sent snapshot survives source replacement draft removal and store teardown" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "chosen.log", .data = "captured original" });
    const path = try pathIn(temp.dir, "chosen.log");
    defer a.free(path);
    var cancel: CancelToken = .{};
    var store = store_mod.Store.init(a);
    var store_live = true;
    defer if (store_live) store.deinit();
    const draft = try store.attachmentDraft(.{ .session = 71 });
    const ticket = try draft.begin();
    var value = try host.capture(a, io, path, &cancel);
    try std.testing.expectEqual(ticket.id, try draft.complete(ticket, &value));
    try std.testing.expect(value.content() == null);
    var sent = try draft.freeze();
    defer sent.deinit();
    try temp.dir.writeFile(io, .{ .sub_path = "chosen.log", .data = "new content at the same path" });
    try std.testing.expect(draft.remove(ticket.id));
    try std.testing.expectEqual(@as(usize, 0), draft.items.items.len);
    store.deinit();
    store_live = false;
    try std.testing.expectEqualStrings("captured original", sent.items[0].reference.content().?.bytes);
    var expected_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("captured original", &expected_hash, .{});
    try std.testing.expectEqual(expected_hash, sent.items[0].reference.content().?.sha256);
}

test "AI local text cancelled cleared duplicate and wrong-owner completions release without resurrecting attachments" {
    var draft = try attachments.Draft.init(a, .{ .session = 9 });
    defer draft.deinit();
    var other = try attachments.Draft.init(a, .{ .group = 9 });
    defer other.deinit();
    const cancelled = try draft.begin();
    try std.testing.expect(draft.cancel(cancelled));
    var late = try attachments.ContentRef.create(a, "/chosen", "late result", 1);
    try std.testing.expectError(error.StaleAttachment, draft.complete(cancelled, &late));
    try std.testing.expect(late.content() == null);
    const old = try draft.begin();
    try draft.clear();
    var cleared = try attachments.ContentRef.create(a, "/chosen", "old draft result", 1);
    try std.testing.expectError(error.StaleAttachment, draft.complete(old, &cleared));
    try std.testing.expect(cleared.content() == null);
    const original = try draft.begin();
    const foreign = try other.begin();
    var wrong_owner = try attachments.ContentRef.create(a, "/chosen", "other owner", 1);
    try std.testing.expectError(error.StaleAttachment, draft.complete(foreign, &wrong_owner));
    try std.testing.expect(draft.contains(original));
    try std.testing.expect(other.contains(foreign));
    var accepted = try attachments.ContentRef.create(a, "/chosen", "accepted", 1);
    _ = try draft.complete(original, &accepted);
    var duplicate = try attachments.ContentRef.create(a, "/chosen", "duplicate", 1);
    try std.testing.expectError(error.StaleAttachment, draft.complete(original, &duplicate));
    try std.testing.expectEqual(@as(usize, 1), draft.items.items.len);
    try std.testing.expectEqualStrings("accepted", draft.items.items[0].reference.content().?.bytes);
}

test "AI local text owner drafts remain stable across presented state replacements and same-name attachments use IDs" {
    var store = store_mod.Store.init(a);
    defer store.deinit();
    const draft = try store.attachmentDraft(.{ .session = 7 });
    for ([_][]const u8{ "/a/config.txt", "/b/config.txt" }) |path| {
        const ticket = try draft.begin();
        var value = try attachments.ContentRef.create(a, path, path, 1);
        _ = try draft.complete(ticket, &value);
    }
    try std.testing.expect(draft.items.items[0].id != draft.items.items[1].id);
    const second_id = draft.items.items[1].id;
    const state = try store.get(.{ .session = 7 });
    state.draft = try a.dupe(u8, "original question");
    for (8..80) |id| _ = try store.attachmentDraft(.{ .session = id });
    const group = try store.attachmentDraft(.{ .group = 7 });
    try std.testing.expect(group != draft and group.items.items.len == 0);
    try std.testing.expect(draft == try store.attachmentDraft(.{ .session = 7 }));
    try std.testing.expect(draft.remove(draft.items.items[0].id));
    try std.testing.expectEqual(second_id, draft.items.items[0].id);
    try std.testing.expectEqualStrings("original question", (try store.get(.{ .session = 7 })).draft.?);
}

test "AI local text pending selection blocks sending and picker cancellation preserves the ready draft" {
    var draft = try attachments.Draft.init(a, .{ .session = 1 });
    defer draft.deinit();
    const first = try draft.begin();
    var ready = try attachments.ContentRef.create(a, "/already", "ready", 1);
    _ = try draft.complete(first, &ready);
    const picker = try draft.begin();
    try std.testing.expectError(error.AttachmentsProcessing, draft.freeze());
    try std.testing.expect(draft.cancel(picker));
    var sent = try draft.freeze();
    defer sent.deinit();
    try std.testing.expectEqual(@as(usize, 1), sent.items.len);
    try std.testing.expectEqual(first.id, sent.items[0].id);
}

test "AI local text cancellation checks before IO and directories are never treated as text" {
    var cancel: CancelToken = .{};
    cancel.cancel();
    try std.testing.expectError(error.Cancelled, host.capture(a, io, "/must-not-be-read/or-created", &cancel));
    var live: CancelToken = .{};
    try std.testing.expectError(error.InvalidAttachmentPath, host.capture(a, io, "relative/path", &live));
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try temp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    try std.testing.expectError(error.NotRegularLocalText, host.capture(a, io, path, &live));
}

test "AI local text actual worker late completion after cancellation releases its captured file snapshot" {
    const Worker = struct {
        path: []const u8,
        token: CancelToken = .{},
        captured: std.atomic.Value(bool) = .init(false),
        deliver: std.atomic.Value(bool) = .init(false),
        result: ?attachments.ContentRef = null,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.result = host.capture(a, io, self.path, &self.token) catch |err| blk: {
                self.failure = err;
                break :blk null;
            };
            self.captured.store(true, .release);
            while (!self.deliver.load(.acquire)) std.Thread.yield() catch {};
        }
    };
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "selected.log", .data = "captured by real background reader" });
    const path = try pathIn(temp.dir, "selected.log");
    defer a.free(path);
    var draft = try attachments.Draft.init(a, .{ .session = 8 });
    defer draft.deinit();
    const ticket = try draft.begin();
    var worker: Worker = .{ .path = path };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    var joined = false;
    defer if (!joined) {
        worker.deliver.store(true, .release);
        thread.join();
        if (worker.result) |*reference| reference.release();
    };
    const deadline = @import("platform/realtime.zig").monotonicNs() + 2 * std.time.ns_per_s;
    while (!worker.captured.load(.acquire)) {
        if (@import("platform/realtime.zig").monotonicNs() > deadline) return error.ReaderDidNotComplete;
        std.Thread.yield() catch {};
    }
    try std.testing.expect(draft.cancel(ticket));
    worker.token.cancel();
    worker.deliver.store(true, .release);
    thread.join();
    joined = true;
    try std.testing.expect(worker.failure == null);
    try std.testing.expectError(error.StaleAttachment, draft.complete(ticket, &worker.result.?));
    try std.testing.expect(worker.result.?.content() == null);
    try std.testing.expectEqual(@as(usize, 0), draft.pending.items.len);
    try std.testing.expectEqual(@as(usize, 0), draft.items.items.len);
}

test "AI local text actual unreadable selected file reports permission failure without a draft item" {
    if (std.c.geteuid() == 0) return error.SkipZigTest;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "private.txt", .data = "private" });
    const file = try temp.dir.openFile(io, "private.txt", .{});
    defer file.close(io);
    try file.setPermissions(io, .fromMode(0));
    defer file.setPermissions(io, .fromMode(0o600)) catch unreachable;
    const path = try pathIn(temp.dir, "private.txt");
    defer a.free(path);
    var cancel: CancelToken = .{};
    var draft = try attachments.Draft.init(a, .{ .session = 17 });
    defer draft.deinit();
    const ticket = try draft.begin();
    if (host.capture(a, io, path, &cancel)) |reference| {
        var unexpected = reference;
        unexpected.release();
        return error.ExpectedPermissionFailure;
    } else |err| try std.testing.expect(err == error.AccessDenied or err == error.PermissionDenied);
    try std.testing.expect(draft.cancel(ticket));
    try std.testing.expectEqual(@as(usize, 0), draft.items.items.len);
}

test "AI local text owned draft and sent references release through every allocation failure" {
    const Scenario = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var store = store_mod.Store.init(allocator);
            defer store.deinit();
            const draft = try store.attachmentDraft(.{ .group = 22 });
            const ticket = try draft.begin();
            var incoming = try attachments.ContentRef.create(allocator, "/selected/config.txt", "stable selected text", 1);
            defer incoming.release();
            _ = try draft.complete(ticket, &incoming);
            var sent = try draft.freeze();
            defer sent.deinit();
            _ = draft.remove(ticket.id);
            try std.testing.expectEqualStrings("stable selected text", sent.items[0].reference.content().?.bytes);
        }
    };
    try std.testing.checkAllAllocationFailures(a, Scenario.run, .{});
}

test "AI local text accepting a frozen request consumes only its captured IDs and preserves a newer picker" {
    var draft = try attachments.Draft.init(a, .{ .session = 1 });
    defer draft.deinit();
    const first = try draft.begin();
    var ready = try attachments.ContentRef.create(a, "/already", "ready", 1);
    _ = try draft.complete(first, &ready);
    var sent = try draft.freeze();
    defer sent.deinit();
    const newer = try draft.begin();
    try std.testing.expectEqual(@as(usize, 1), try draft.consumeSent(&sent));
    try std.testing.expect(draft.contains(newer));
    try std.testing.expectEqual(@as(usize, 0), draft.items.items.len);
    try std.testing.expectEqualStrings("ready", sent.items[0].reference.content().?.bytes);
    try std.testing.expectEqual(@as(usize, 0), try draft.consumeSent(&sent));
    try draft.clear();
    const latest = try draft.begin();
    try std.testing.expectError(error.StaleAttachmentBundle, draft.consumeSent(&sent));
    try std.testing.expect(draft.contains(latest));
}

fn waitReader(reader: *host.Reader) !void {
    const deadline = @import("platform/realtime.zig").monotonicNs() + 2 * std.time.ns_per_s;
    while (!reader.poll()) {
        if (@import("platform/realtime.zig").monotonicNs() > deadline) return error.ReaderDidNotComplete;
        std.Thread.yield() catch {};
    }
}

test "AI local text Reader privately reads an owned selected path and returns only its captured owner ticket once" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "selected.log", .data = "private IO background snapshot" });
    const path = try pathIn(temp.dir, "selected.log");
    defer a.free(path);
    var store = store_mod.Store.init(a);
    defer store.deinit();
    const original = try store.attachmentDraft(.{ .session = 41 });
    const ticket = try original.begin();
    const reader = try host.Reader.start(a, ticket, path);
    defer reader.deinit();
    // The caller may free or replace its picker buffer immediately.
    @memset(path, 'x');
    const later_presented = try store.attachmentDraft(.{ .session = 42 });
    try waitReader(reader);
    const completion = reader.take().?;
    try std.testing.expect(ticket.eql(completion.ticket));
    var reference = try completion.result;
    _ = try original.complete(completion.ticket, &reference);
    try std.testing.expect(reader.take() == null);
    try std.testing.expectEqual(@as(usize, 1), original.items.items.len);
    try std.testing.expectEqualStrings("private IO background snapshot", original.items.items[0].reference.content().?.bytes);
    try std.testing.expectEqual(@as(usize, 0), later_presented.items.items.len);
}

test "AI local text Reader cancellation discards an actual completed late file result" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "selected.log", .data = "late queued snapshot" });
    const path = try pathIn(temp.dir, "selected.log");
    defer a.free(path);
    var draft = try attachments.Draft.init(a, .{ .group = 4 });
    defer draft.deinit();
    const ticket = try draft.begin();
    const reader = try host.Reader.start(a, ticket, path);
    defer reader.deinit();
    try waitReader(reader);
    // The worker really completed. Cancel before the main thread takes it.
    try std.testing.expect(draft.cancel(ticket));
    reader.cancel();
    const completion = reader.take().?;
    try std.testing.expectError(error.Cancelled, completion.result);
    try std.testing.expect(ticket.eql(completion.ticket));
    try std.testing.expect(reader.take() == null);
    try std.testing.expectEqual(@as(usize, 0), draft.items.items.len);
}

test "AI local text Reader cancel and close joins a real worker before the draft is destroyed" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const content = try a.alloc(u8, attachments.max_bytes);
    defer a.free(content);
    @memset(content, 'a');
    try temp.dir.writeFile(io, .{ .sub_path = "selected.log", .data = content });
    const path = try pathIn(temp.dir, "selected.log");
    defer a.free(path);
    var draft = try attachments.Draft.init(a, .{ .session = 5 });
    defer draft.deinit();
    const ticket = try draft.begin();
    const reader = try host.Reader.start(a, ticket, path);
    try std.testing.expect(draft.cancel(ticket));
    reader.cancel();
    reader.deinit();
    try std.testing.expectEqual(@as(usize, 0), draft.pending.items.len);
    try std.testing.expectEqual(@as(usize, 0), draft.items.items.len);
    // Also close after a success has been queued but never taken.
    const second = try host.Reader.start(a, try draft.begin(), path);
    try waitReader(second);
    second.deinit();
}

test "AI local text Reader reports real read errors with the original ticket and frees start failures" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "binary.txt", .data = "a\x00b" });
    const path = try pathIn(temp.dir, "binary.txt");
    defer a.free(path);
    const ticket: attachments.Ticket = .{ .owner = .{ .session = 6 }, .draft_epoch = 1, .id = 2 };
    try std.testing.expectError(error.InvalidAttachmentPath, host.Reader.start(a, ticket, "relative.txt"));
    // The only main-thread allocations are the path and Reader itself.
    for (0..2) |failure_index| {
        var failing: std.testing.FailingAllocator = .init(a, .{ .fail_index = failure_index });
        try std.testing.expectError(error.OutOfMemory, host.Reader.start(failing.allocator(), ticket, path));
    }
    const reader = try host.Reader.start(a, ticket, path);
    defer reader.deinit();
    try waitReader(reader);
    const completion = reader.take().?;
    try std.testing.expect(ticket.eql(completion.ticket));
    try std.testing.expectError(error.BinaryLocalText, completion.result);
}

test "AI local text Reader releases worker and result ownership through every allocation failure" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "selected.log", .data = "owned by a real Reader worker" });
    const path = try pathIn(temp.dir, "selected.log");
    defer a.free(path);
    const Scenario = struct {
        fn run(allocator: std.mem.Allocator, selected: []const u8) !void {
            const ticket: attachments.Ticket = .{ .owner = .{ .session = 6 }, .draft_epoch = 1, .id = 2 };
            const reader = try host.Reader.start(allocator, ticket, selected);
            defer reader.deinit();
            try waitReader(reader);
            const completion = reader.take().?;
            var reference = try completion.result;
            defer reference.release();
            try std.testing.expectEqualStrings("owned by a real Reader worker", reference.content().?.bytes);
        }
    };
    try std.testing.checkAllAllocationFailures(a, Scenario.run, .{path});
}

test "AI local text actual selected file is only a candidate until explicit confirmation and sent history retains its snapshot" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "selected.log", .data = "captured candidate\n中文" });
    const path = try pathIn(temp.dir, "selected.log");
    defer a.free(path);
    var draft = try attachments.Draft.init(a, .{ .session = 90 });
    defer draft.deinit();
    const ticket = try draft.begin();
    var token: CancelToken = .{};
    var reference = try host.capture(a, io, path, &token);
    try draft.stage(ticket, &reference);
    try std.testing.expect(reference.content() == null);
    try std.testing.expectEqual(@as(usize, 0), draft.items.items.len);
    try std.testing.expectEqual(@as(usize, 1), draft.candidates.items.len);
    try std.testing.expectError(error.AttachmentsProcessing, draft.freeze());
    try temp.dir.writeFile(io, .{ .sub_path = "selected.log", .data = "file changed after preview" });
    _ = try draft.attach(ticket);
    var sent = try draft.freeze();
    defer sent.deinit();
    var history = try sent.retain();
    defer history.deinit();
    _ = try draft.consumeSent(&sent);
    try draft.clear();
    try std.testing.expectEqualStrings("captured candidate\n中文", history.items[0].reference.content().?.bytes);
    try std.testing.expectEqual(@as(usize, 0), draft.candidates.items.len);
    try std.testing.expectError(error.StaleAttachment, draft.attach(ticket));
}

test "AI local text candidate cancellation and complete cannot bypass confirmation or resurrect old tickets" {
    var draft = try attachments.Draft.init(a, .{ .session = 1 });
    defer draft.deinit();
    const ticket = try draft.begin();
    var preview = try attachments.ContentRef.create(a, "/preview.txt", "preview", 1);
    try draft.stage(ticket, &preview);
    var bypass = try attachments.ContentRef.create(a, "/bypass.txt", "bypass", 1);
    try std.testing.expectError(error.AttachmentAwaitingConfirmation, draft.complete(ticket, &bypass));
    try std.testing.expect(bypass.content() == null);
    try std.testing.expectEqualStrings("preview", draft.candidate(ticket).?.reference.content().?.bytes);
    try std.testing.expect(draft.cancel(ticket));
    try std.testing.expectEqual(@as(usize, 0), draft.candidates.items.len);
    try std.testing.expectError(error.StaleAttachment, draft.attach(ticket));
    var late = try attachments.ContentRef.create(a, "/late.txt", "late", 1);
    try std.testing.expectError(error.StaleAttachment, draft.stage(ticket, &late));
    try std.testing.expect(late.content() == null);
    try std.testing.expectEqual(@as(usize, 0), draft.items.items.len);
}

test "AI local text reselect cancellation preserves ready contents and replacement commits only on confirmation" {
    var draft = try attachments.Draft.init(a, .{ .session = 1 });
    defer draft.deinit();
    const first = try draft.begin();
    var ready = try attachments.ContentRef.create(a, "/original.txt", "original ready", 1);
    _ = try draft.complete(first, &ready);
    const cancelled_picker = try draft.begin();
    try std.testing.expect(draft.cancel(cancelled_picker));
    try std.testing.expectEqualStrings("original ready", draft.items.items[0].reference.content().?.bytes);
    const replacement = try draft.begin();
    var newer = try attachments.ContentRef.create(a, "/new.txt", "new candidate", 2);
    try draft.stageReplacing(replacement, &newer, first);
    try std.testing.expectEqualStrings("original ready", draft.items.items[0].reference.content().?.bytes);
    const another = try draft.begin();
    // Cancelling this chooser keeps the selected candidate and original ready file.
    try std.testing.expect(draft.cancel(another));
    try std.testing.expect(draft.candidate(replacement) != null);
    const final_choice = try draft.begin();
    var final = try attachments.ContentRef.create(a, "/final.txt", "final snapshot", 3);
    try draft.stageReplacing(final_choice, &final, replacement);
    try std.testing.expect(draft.candidate(replacement) == null);
    try std.testing.expect(!draft.contains(replacement));
    try std.testing.expectEqual(first.id, draft.candidate(final_choice).?.replaces.?);
    _ = try draft.attach(final_choice);
    try std.testing.expectEqual(@as(usize, 1), draft.items.items.len);
    try std.testing.expectEqual(final_choice.id, draft.items.items[0].id);
    try std.testing.expectEqualStrings("final snapshot", draft.items.items[0].reference.content().?.bytes);
    var sent = try draft.freeze();
    sent.deinit();
}

test "AI local text candidate replace confirm and independent history references release on every allocation failure" {
    const Scenario = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var draft = try attachments.Draft.init(allocator, .{ .group = 3 });
            defer draft.deinit();
            const first = try draft.begin();
            var ready = try attachments.ContentRef.create(allocator, "/original.txt", "original", 1);
            _ = try draft.complete(first, &ready);
            const replacement = try draft.begin();
            var next = try attachments.ContentRef.create(allocator, "/new.txt", "replacement", 2);
            try draft.stageReplacing(replacement, &next, first);
            _ = try draft.attach(replacement);
            var sent = try draft.freeze();
            defer sent.deinit();
            var history = try sent.retain();
            defer history.deinit();
            _ = try draft.consumeSent(&sent);
            try std.testing.expectEqualStrings("replacement", history.items[0].reference.content().?.bytes);
        }
    };
    try std.testing.checkAllAllocationFailures(a, Scenario.run, .{});
}

test "AI local text owner message history and last turn own separate original snapshots across draft removal and teardown" {
    var store = store_mod.Store.init(a);
    var store_live = true;
    defer if (store_live) store.deinit();
    const owner: attachments.Owner = .{ .session = 81 };
    const draft = try store.attachmentDraft(owner);
    const ticket = try draft.begin();
    var reference = try attachments.ContentRef.create(a, "/original/message.txt", "original sent snapshot", 1);
    try draft.stage(ticket, &reference);
    _ = try draft.attach(ticket);
    const state = try store.get(owner);
    state.last_user_text = try a.dupe(u8, "visible human text");
    state.last_user_wire = try a.dupe(u8, "complete provider wire with original sent snapshot");
    state.last_user_attachments = try draft.freeze();
    var message = try (store_mod.Message{ .user = true, .text = state.last_user_text.?, .wire_text = state.last_user_wire, .attachments = state.last_user_attachments }).clone(a);
    state.history.append(a, message) catch |err| {
        message.deinit(a);
        return err;
    };
    // The history owns a copy independently of the currently displayed turn.
    state.last_user_attachments.?.deinit();
    state.last_user_attachments = null;
    try draft.clear();
    var preview = try state.history.items[0].attachments.?.retain();
    defer preview.deinit();
    try std.testing.expectEqualStrings("visible human text", state.history.items[0].text);
    try std.testing.expectEqualStrings("complete provider wire with original sent snapshot", state.history.items[0].wire_text.?);
    const other = try store.get(.{ .group = 81 });
    try std.testing.expect(other.last_user_attachments == null and other.history.items.len == 0);
    store.deinit();
    store_live = false;
    try std.testing.expectEqualStrings("original sent snapshot", preview.items[0].reference.content().?.bytes);
}

test "AI local text message snapshot cloning frees every failed allocation without consuming the original" {
    const Scenario = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var draft = try attachments.Draft.init(allocator, .{ .group = 8 });
            defer draft.deinit();
            const ticket = try draft.begin();
            var reference = try attachments.ContentRef.create(allocator, "/original.txt", "unchanged original", 1);
            try draft.stage(ticket, &reference);
            _ = try draft.attach(ticket);
            var bundle = try draft.freeze();
            defer bundle.deinit();
            const source: store_mod.Message = .{ .user = true, .text = @constCast("visible"), .wire_text = @constCast("wire"), .attachments = bundle };
            var copy = try source.clone(allocator);
            defer copy.deinit(allocator);
            try std.testing.expect(draft.remove(ticket.id));
            try std.testing.expectEqualStrings("unchanged original", copy.attachments.?.items[0].reference.content().?.bytes);
            try std.testing.expectEqualStrings("visible", source.text);
            try std.testing.expectEqualStrings("unchanged original", bundle.items[0].reference.content().?.bytes);
        }
    };
    try std.testing.checkAllAllocationFailures(a, Scenario.run, .{});
}
