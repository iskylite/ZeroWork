const std = @import("std");
const builtin = @import("builtin");
const operations = @import("local_file_operation.zig");
const ProcessJournal = @import("lifecycle_runtime.zig").ProcessJournal;
const identity = @import("../host/identity.zig");
const commit = @import("../host/local_file_commit.zig");
const paths = @import("../host/local_path.zig");
const a = std.testing.allocator;
const io = std.testing.io;

fn request() operations.Request {
    return .{
        .context = .{
            .conversation_id = identity.ConversationId.generate(),
            .task_id = identity.TaskId.generate(),
            .binding = .{ .session = 10 },
            .binding_revision = 1,
            .grant_revision = 1,
        },
        .request_key = "update-1",
        .canonical_hash = @splat(7),
        .turn_id = 1,
        .call_id = "provider-1",
    };
}

fn allow(_: *anyopaque, _: *const commit.Prepared) !void {}

const FullRecoveryQuota = struct {
    fn callbacks(delegate: *commit.Journal) commit.Journal {
        return .{ .context = delegate, .prepare = prepare, .dispatch = dispatch, .finish = finish, .progress = progress };
    }

    fn prepare(raw: *anyopaque, source: commit.Evidence) !void {
        const target: *const commit.Journal = @ptrCast(@alignCast(raw));
        var evidence = source;
        evidence.reserved_bytes = @import("lifecycle_journal.zig").max_recovery_bytes;
        try target.prepare(target.context, evidence);
    }

    fn dispatch(raw: *anyopaque, operation: identity.HostOperationId) !void {
        const target: *const commit.Journal = @ptrCast(@alignCast(raw));
        try target.dispatch(target.context, operation);
    }

    fn finish(raw: *anyopaque, receipt: commit.Receipt) !void {
        const target: *const commit.Journal = @ptrCast(@alignCast(raw));
        try target.finish(target.context, receipt);
    }

    fn progress(raw: *anyopaque, operation: identity.HostOperationId, count: u8) !void {
        const target: *const commit.Journal = @ptrCast(@alignCast(raw));
        try target.progress.?(target.context, operation, count);
    }
};

test "managed local file journal persists evidence, deduplicates both entrances and loads verified diff" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var owner: ?*ProcessJournal = try ProcessJournal.acquire(.{ .data_root = root, .dir = tmp.dir, .io = io, .path = "state/lifecycle.json" });
    defer if (owner) |value| value.release();
    var input = request();
    const file_request: commit.Request = .{ .kind = .create, .text = "submitted data\n" };
    input.canonical_hash = try operations.canonicalHash(a, .{ .path = "f" }, root, file_request);

    var first = try operations.Transaction.claim(owner.?, input);
    try std.testing.expect(!first.handle.reused);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const target = try paths.resolve(ar, io, .{ .path = "f", .base_directory = root }, .create);
    defer target.deinit(ar, io);
    const plan = try commit.prepare(ar, io, &target, file_request);
    const receipt = try commit.commit(ar, io, &plan, first.handle.operation_ref, try first.callbacks(), .{ .context = &first, .validate = allow });
    try std.testing.expect(receipt.verified and receipt.committed and !receipt.journal_outcome_unknown);

    owner.?.release();
    owner = null;
    owner = try ProcessJournal.acquire(.{ .data_root = root, .dir = tmp.dir, .io = io, .path = "state/lifecycle.json" });
    input.call_id = "other-entrance";
    input.turn_id = 2;
    input.context.binding_revision = 2;
    var repeat = try operations.Transaction.claim(owner.?, input);
    try std.testing.expect(repeat.handle.reused and repeat.handle.operation_ref.eql(first.handle.operation_ref));
    try std.testing.expectError(error.LocalFileOperationAlreadyClaimed, repeat.callbacks());
    input.canonical_hash[0] ^= 1;
    try std.testing.expectError(error.IdempotencyConflict, operations.Transaction.claim(owner.?, input));
    var record = (try operations.find(owner.?, a, input.context, .{ .request_key = input.request_key })).?;
    defer record.deinit(a);
    try std.testing.expectEqualStrings("provider-1", record.original_call);
    try std.testing.expectEqual(@import("lifecycle_journal.zig").Stage.succeeded, record.stage);
    try std.testing.expect(record.local_file_result.?.verified);
    const diff = try commit.readDiff(a, io, record.local_file_evidence.?, record.local_file_result.?.diff_ref.?);
    defer diff.deinit();
    try std.testing.expectEqualStrings("submitted data\n", diff.value.lines[0].text);
    const evidence = record.local_file_evidence.?;
    const diff_ref = record.local_file_result.?.diff_ref.?;
    const stage = try tmp.dir.openDir(io, &evidence.recovery.stage_name, .{});
    defer stage.close(io);
    try stage.writeFile(io, .{ .sub_path = "approved-diff.json", .data = "{}" });
    try std.testing.expectError(error.RecoveryMaterialChanged, commit.readDiff(a, io, evidence, diff_ref));
    try stage.deleteFile(io, "approved-diff.json");
    try std.testing.expectError(error.ChangeContentExpired, commit.readDiff(a, io, evidence, diff_ref));
    var wrong = input.context;
    wrong.task_id = identity.TaskId.generate();
    try std.testing.expectEqual(null, try operations.find(owner.?, a, wrong, .{ .operation_ref = record.operation_ref }));
    const disk = try tmp.dir.readFileAlloc(io, "state/lifecycle.json", a, .limited(16384));
    defer a.free(disk);
    try std.testing.expect(std.mem.indexOf(u8, disk, "submitted data") == null);
}

test "managed local file journal retains unknown operation across process-owner reopen" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const config: @import("lifecycle_runtime.zig").JournalConfig = .{ .data_root = root, .dir = tmp.dir, .io = io };
    var owner: ?*ProcessJournal = try ProcessJournal.acquire(config);
    defer if (owner) |value| value.release();
    const input = request();
    var transaction = try operations.Transaction.claim(owner.?, input);
    const live = try transaction.callbacks();

    // Force loss of the final journal callback after a real exclusive create.
    const LostReceipt = struct {
        fn prepare(raw: *anyopaque, evidence: commit.Evidence) !void {
            const delegate: *const commit.Journal = @ptrCast(@alignCast(raw));
            try delegate.prepare(delegate.context, evidence);
        }

        fn dispatch(raw: *anyopaque, operation: identity.HostOperationId) !void {
            const delegate: *const commit.Journal = @ptrCast(@alignCast(raw));
            try delegate.dispatch(delegate.context, operation);
        }

        fn finish(_: *anyopaque, _: commit.Receipt) !void {
            return error.SimulatedProcessExit;
        }
    };
    var delegate = live;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const target = try paths.resolve(ar, io, .{ .path = "f", .base_directory = root }, .create);
    defer target.deinit(ar, io);
    const plan = try commit.prepare(ar, io, &target, .{ .kind = .create, .text = "once" });
    const result = try commit.commit(ar, io, &plan, transaction.handle.operation_ref, .{
        .context = &delegate,
        .prepare = LostReceipt.prepare,
        .dispatch = LostReceipt.dispatch,
        .finish = LostReceipt.finish,
    }, .{ .context = &transaction, .validate = allow });
    try std.testing.expect(result.committed and result.journal_outcome_unknown);

    owner.?.release();
    owner = null;
    owner = try ProcessJournal.acquire(config);
    var stored = (try operations.find(owner.?, a, input.context, .{ .operation_ref = transaction.handle.operation_ref })).?;
    defer stored.deinit(a);
    try std.testing.expectEqual(@import("lifecycle_journal.zig").Stage.outcome_unknown, stored.stage);
    try std.testing.expect(stored.local_file_result == null);
    const observation = try commit.observe(a, io, stored.local_file_evidence.?);
    try std.testing.expect(observation.candidate_matches and observation.candidate_payload_preserved);
    var queried = try query(owner.?, input.context, &.{}, .{ .operation_ref = stored.operation_ref, .verify = true });
    defer queried.deinit();
    const body = queried.value.object;
    try std.testing.expectEqualStrings("unknown", body.get("status").?.string);
    try std.testing.expect(!body.get("committed").?.bool and !body.get("verified").?.bool);
    try std.testing.expect(body.get("side_effect_started") == null and body.get("dispatch_started").?.bool);
    try std.testing.expect(body.get("observation").?.object.get("matches_submitted_candidate").?.bool);
    const expired = try owner.?.expireLocalFiles(input.context.conversation_id);
    try std.testing.expectEqual(@as(usize, 0), expired.expired);
    try std.testing.expectEqual(@as(usize, 1), expired.pending);
    var same = try operations.Transaction.claim(owner.?, input);
    try std.testing.expect(same.handle.reused);
    try std.testing.expectError(error.LocalFileOperationAlreadyClaimed, same.callbacks());
    const content = try tmp.dir.readFileAlloc(io, "f", a, .limited(128));
    defer a.free(content);
    try std.testing.expectEqualStrings("once", content);
}

test "managed local file journal rejects exhausted recovery quota before target mutation" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const owner = try ProcessJournal.acquire(.{ .data_root = root, .dir = tmp.dir, .io = io });
    defer owner.release();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    var input = request();
    var reserved = try operations.Transaction.claim(owner, input);
    var delegate = try reserved.callbacks();
    const first = try paths.resolve(ar, io, .{ .path = "first", .base_directory = root }, .create);
    defer first.deinit(ar, io);
    const first_plan = try commit.prepare(ar, io, &first, .{ .kind = .create, .text = "reserved" });
    const first_result = try commit.commit(ar, io, &first_plan, reserved.handle.operation_ref, FullRecoveryQuota.callbacks(&delegate), .{ .context = &reserved, .validate = allow });
    try std.testing.expect(first_result.verified);

    input.request_key = "update-2";
    var rejected = try operations.Transaction.claim(owner, input);
    const second = try paths.resolve(ar, io, .{ .path = "second", .base_directory = root }, .create);
    defer second.deinit(ar, io);
    const plan = try commit.prepare(ar, io, &second, .{ .kind = .create, .text = "no room" });
    const receipt = try commit.commit(ar, io, &plan, rejected.handle.operation_ref, try rejected.callbacks(), .{ .context = &rejected, .validate = allow });
    try std.testing.expectEqual(commit.Status.rejected, receipt.status);
    try std.testing.expectEqual(@as(?anyerror, error.RecoveryQuotaExceeded), receipt.reason);
    try std.testing.expect(!receipt.side_effect_started and receipt.recovery == null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "second", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, &commit.stageName(rejected.handle.operation_ref), .{}));
    var fact = try rejected.snapshot(a);
    defer fact.deinit(a);
    try std.testing.expectEqual(@import("lifecycle_journal.zig").Stage.rejected, fact.stage);
    try std.testing.expectEqualStrings("RecoveryQuotaExceeded", fact.local_file_result.?.reason.?);
}

test "managed local file history expiry reclaims a durably rejected write and preserves its key" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const config: @import("lifecycle_runtime.zig").JournalConfig = .{ .data_root = root, .dir = tmp.dir, .io = io };
    const input = request();
    const rejected = blk: {
        const owner = try ProcessJournal.acquire(config);
        defer owner.release();
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const ar = arena.allocator();
        const file_request: commit.Request = .{ .kind = .create, .text = "never written", .create_parents = true };
        const target = try paths.resolve(ar, io, .{ .path = "missing/sub/file", .base_directory = root, .create_parents = true }, .create);
        defer target.deinit(ar, io);
        const proposal = try commit.prepare(ar, io, &target, file_request);
        var transaction = try operations.Transaction.claim(owner, input);
        var delegate = try transaction.callbacks();
        const Gate = struct {
            fn validate(raw: *anyopaque, _: *const commit.Prepared) !void {
                const current: *const operations.Transaction = @ptrCast(@alignCast(raw));
                if (current.stage == .dispatch_started) return error.WorkspaceChanged;
            }
        };
        const receipt = try commit.commit(ar, io, &proposal, transaction.handle.operation_ref, FullRecoveryQuota.callbacks(&delegate), .{ .context = &transaction, .validate = Gate.validate });
        try std.testing.expectEqual(commit.Status.rejected, receipt.status);
        try std.testing.expectEqual(@as(?anyerror, error.WorkspaceChanged), receipt.reason);
        try std.testing.expect(!receipt.side_effect_started and !receipt.journal_outcome_unknown);

        const stage_name = commit.stageName(receipt.operation_ref);
        const stage = try tmp.dir.openDir(io, &stage_name, .{});
        defer stage.close(io);
        try stage.writeFile(io, .{ .sub_path = "parent-00/external-file", .data = "preserve" });
        const unsafe = try owner.expireLocalFiles(input.context.conversation_id);
        try std.testing.expectEqual(@as(usize, 1), unsafe.failed);
        try std.testing.expectEqual(@as(usize, 0), unsafe.expired);
        _ = try stage.statFile(io, "entry", .{});
        _ = try stage.statFile(io, "parent-00/external-file", .{});
        try stage.deleteFile(io, "parent-00/external-file");

        const expired = try owner.expireLocalFiles(input.context.conversation_id);
        try std.testing.expectEqual(@as(usize, 1), expired.expired);
        try std.testing.expectEqual(@as(usize, 0), expired.failed);
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, &stage_name, .{}));
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "missing", .{}));
        break :blk receipt.operation_ref;
    };
    const owner = try ProcessJournal.acquire(config);
    defer owner.release();
    var record = (try operations.find(owner, a, input.context, .{ .operation_ref = rejected })).?;
    defer record.deinit(a);
    try std.testing.expect(record.dispatch_started and record.local_file_material_expired == true);
    try std.testing.expectEqual(commit.Status.rejected, record.local_file_result.?.status);
    try std.testing.expectEqualStrings("WorkspaceChanged", record.local_file_result.?.reason.?);
    var duplicate = try operations.Transaction.claim(owner, input);
    try std.testing.expect(duplicate.handle.reused and duplicate.handle.operation_ref.eql(rejected));
    try std.testing.expectError(error.LocalFileOperationAlreadyClaimed, duplicate.callbacks());
    _ = try applyChange(owner, root, request(), "new-file", .{ .kind = .create, .text = "room for another write" });
}

fn applyChange(owner: *ProcessJournal, root: []const u8, source: operations.Request, filename: []const u8, file_request: commit.Request) !identity.HostOperationId {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    var input = source;
    input.canonical_hash = try operations.canonicalHash(ar, .{ .path = filename }, root, file_request);
    var transaction = try operations.Transaction.claim(owner, input);
    const target = try paths.resolve(ar, io, .{ .path = filename, .base_directory = root }, if (file_request.kind == .create) .create else .file);
    defer target.deinit(ar, io);
    const proposal = try commit.prepare(ar, io, &target, file_request);
    const receipt = try commit.commit(ar, io, &proposal, transaction.handle.operation_ref, try transaction.callbacks(), .{ .context = &transaction, .validate = allow });
    try std.testing.expect(receipt.verified and receipt.committed);
    return receipt.operation_ref;
}

const changes = @import("local_file_change_query.zig");
const host = @import("host_tools.zig");
const query_key: [32]u8 = @splat(0x7c);

fn query(owner: *ProcessJournal, context: host.Context, children: []const changes.Scope, args: anytype) !std.json.Parsed(std.json.Value) {
    const json = try std.json.Stringify.valueAlloc(a, args, .{});
    defer a.free(json);
    const input = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer input.deinit();
    const invocation: host.Invocation = .{
        .context = context,
        .authority = .local_files,
        .operation_id = 9,
        .turn_id = 1,
        .call_id = "query",
        .tool_id = changes.tool_id,
        .arguments = input.value,
        .arguments_json = json,
        .arguments_hash = @splat(0),
        .canonical_arguments_hash = @splat(0),
    };
    var result = try changes.execute(a, io, owner, invocation, children, query_key);
    defer result.deinit(a);
    try result.validate(context, invocation.operation_id);
    try std.testing.expectEqual(@as(usize, 1), result.blocks.len);
    return std.json.parseFromSlice(std.json.Value, a, result.blocks[0].structured, .{ .allocate = .alloc_always });
}

test "managed local file change query paginates a Task tree and marks a version discontinuity" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const owner = try ProcessJournal.acquire(.{ .data_root = root, .dir = tmp.dir, .io = io });
    defer owner.release();
    const parent = request();
    var child = request();
    child.request_key = "child-write";
    const own = changes.Scope.from(parent.context);
    const children = [_]changes.Scope{changes.Scope.from(child.context)};
    const first = try applyChange(owner, root, parent, "same", .{ .kind = .create, .text = "version-one\n" });
    const external = "external-editor\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "same", .data = external });
    const file = try tmp.dir.openFile(io, "same", .{});
    const reads = @import("../host/local_file_reads.zig");
    const version = reads.version(try reads.fileState(file, io), external);
    file.close(io);
    const second = try applyChange(owner, root, child, "same", .{ .kind = .replace, .text = "version-two\n", .expected_version = &version });

    try std.testing.expectError(error.LocalFileOperationNotFound, query(owner, parent.context, &.{}, .{ .operation_ref = second }));
    try std.testing.expectError(error.LocalFileTaskNotAuthorized, query(owner, parent.context, &.{}, .{ .task_ref = child.context.task_id }));
    var first_page = try query(owner, parent.context, &children, .{ .limit = 1 });
    defer first_page.deinit();
    const initial = first_page.value.object;
    try std.testing.expectEqualStrings("managed_local_file_tools", initial.get("coverage").?.string);
    try std.testing.expect(!initial.get("complete").?.bool);
    const row = initial.get("operations").?.array.items[0].object;
    try std.testing.expect((try identity.HostOperationId.parse(row.get("operation_ref").?.string)).eql(first));
    const cursor = initial.get("next_cursor").?.string;
    try std.testing.expectError(error.CursorExpired, query(owner, parent.context, &.{}, .{ .limit = 1, .cursor = cursor }));
    try std.testing.expectError(error.CursorExpired, query(owner, parent.context, &children, .{ .limit = 2, .cursor = cursor }));

    var second_page = try query(owner, parent.context, &children, .{ .limit = 1, .cursor = cursor });
    defer second_page.deinit();
    const result = second_page.value.object;
    try std.testing.expect(result.get("complete").?.bool);
    const next = result.get("operations").?.array.items[0].object;
    try std.testing.expect((try identity.HostOperationId.parse(next.get("operation_ref").?.string)).eql(second));
    try std.testing.expect((try identity.HostOperationId.parse(next.get("previous_operation_ref").?.string)).eql(first));
    try std.testing.expectEqualStrings("discontinuity", next.get("version_chain").?.string);
    try std.testing.expectEqualStrings(&version, next.get("actual_before_version").?.string);
    const files = result.get("files").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings(next.get("target").?.string, files[0].object.get("target").?.string);
    var exact = try query(owner, parent.context, &children, .{ .change_ref = second, .verify = true });
    defer exact.deinit();
    const exact_row = exact.value.object;
    try std.testing.expect(exact_row.get("observation").?.object.get("matches_submitted_candidate").?.bool);
    try std.testing.expect(exact_row.get("original_retained").?.bool);
    try std.testing.expect(exact_row.get("diff") != null);

    var next_attempt = parent;
    next_attempt.request_key = "later-attempt";
    var rejected = try operations.Transaction.claim(owner, next_attempt);
    const named = try std.fs.path.join(a, &.{ root, "later" });
    defer a.free(named);
    try rejected.rejectAt(error.ScopeChanged, named);
    try std.testing.expectError(error.SnapshotChanged, query(owner, parent.context, &children, .{ .limit = 1, .cursor = cursor }));
    var old = (try owner.findScopedLocalFile(a, &.{own}, rejected.handle.operation_ref)).?;
    defer old.deinit(a);
    try std.testing.expectEqualStrings(named, old.local_file_result.?.target.?);
}

test "managed local file history expiry preserves idempotency and current verification" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const config: @import("lifecycle_runtime.zig").JournalConfig = .{ .data_root = root, .dir = tmp.dir, .io = io };
    const input = request();
    const file_request: commit.Request = .{ .kind = .create, .text = "preserved result\n" };
    const first = blk: {
        const owner = try ProcessJournal.acquire(config);
        defer owner.release();
        const operation = try applyChange(owner, root, input, "out", file_request);
        const expired = try owner.expireLocalFiles(input.context.conversation_id);
        try std.testing.expectEqual(@as(usize, 1), expired.expired);
        try std.testing.expectEqual(@as(usize, 0), expired.failed);
        try std.testing.expectEqual(@as(usize, 0), (try owner.expireLocalFiles(input.context.conversation_id)).expired);
        break :blk operation;
    };
    const owner = try ProcessJournal.acquire(config);
    defer owner.release();
    var after = try query(owner, input.context, &.{}, .{ .operation_ref = first, .verify = true });
    defer after.deinit();
    const body = after.value.object;
    try std.testing.expect(body.get("committed").?.bool and body.get("verified").?.bool);
    try std.testing.expect(body.get("diff_expired").?.bool and body.get("diff") == null);
    try std.testing.expectEqualStrings("ChangeContentExpired", body.get("diff_content_error").?.string);
    try std.testing.expect(body.get("recovery_ref") == null);
    try std.testing.expect(body.get("observation").?.object.get("matches_submitted_candidate").?.bool);
    var repeated = input;
    repeated.canonical_hash = try operations.canonicalHash(a, .{ .path = "out" }, root, file_request);
    const duplicate = try operations.Transaction.claim(owner, repeated);
    try std.testing.expect(duplicate.handle.reused and duplicate.handle.operation_ref.eql(first));
    const contents = try tmp.dir.readFileAlloc(io, "out", a, .limited(64));
    defer a.free(contents);
    try std.testing.expectEqualStrings(file_request.text, contents);
}
