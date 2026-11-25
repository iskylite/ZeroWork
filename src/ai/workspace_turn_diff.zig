//! Project one already-visible managed write receipt for the standalone
//! inspector. Never walk a journal for history, read recovery payloads, or
//! infer a change from a working tree. One result is one operation, not a
//! reconstructed diff between the beginning and end of the turn.
const std = @import("std");
const id = @import("../host/identity.zig");
const paths = @import("../host/local_path.zig");
const workspace = @import("../host/local_workspace.zig");
const preview = @import("../host/workspace_preview.zig");
const commit = @import("../host/local_file_commit.zig");
const host = @import("host_tools.zig");
const journal = @import("lifecycle_journal.zig");
const ProcessJournal = @import("lifecycle_runtime.zig").ProcessJournal;
const facts = @import("tool_results.zig");

/// Supplied by the controller when it has current read authority. A captured
/// file row or a model-supplied path is not a substitute for that authority.
pub const Current = struct { source: preview.Source, authority: host.Context, turn_id: u64 };
/// Captured from an authorized, successful *text* preview in this inspector.
/// The UI must also discard the returned view if this selection was superseded.
pub const Selection = struct { stamp: preview.Stamp, relative: []const u8, file: workspace.Identity };
pub const Result = union(enum) {
    /// Different scope/target, no local host receipt, or no such operation.
    not_applicable,
    /// The write was not confirmed. No proposed or unverified text is exposed.
    unverified: id.HostOperationId,
    expired: id.HostOperationId,
    unavailable: id.HostOperationId,
    change: struct { operation: id.HostOperationId, order: u64, kind: commit.Kind, diff: commit.Diff },
};

const Wire = struct {
    coverage: []const u8,
    operation_ref: id.HostOperationId,
    conversation_ref: id.ConversationId,
    task_ref: id.TaskId,
    turn_id: u64,
    call_id: []const u8,
    target: ?[]const u8 = null,
    base_directory: ?[]const u8 = null,
    resolution_source: ?[]const u8 = null,
    workspace_revision: ?u64 = null,
    kind: ?commit.Kind = null,
    status: commit.Status,
    committed: bool,
    verified: bool,
    conflict: bool,
    journal_outcome_unknown: bool = false,
    diff_expired: bool = false,
    diff_content_error: ?[]const u8 = null,
    diff: ?commit.Diff = null,
};

/// Arena `a` owns the returned lines. Only metadata for this single operation
/// is requested from this same app-data instance; text must already be present
/// on the host receipt. Run off the UI thread (first journal open can do IO).
pub fn project(a: std.mem.Allocator, current: Current, selected: Selection, record: *const facts.Record, store: *ProcessJournal) !Result {
    const source = current.source;
    const authority = current.authority;
    authority.validate() catch return .not_applicable;
    source.workspace.validate() catch return .not_applicable;
    if (!std.meta.eql(selected.stamp, source.stamp) or
        source.workspace.availability != .ready or source.workspace.revision != source.stamp.revision or
        !std.meta.eql(source.workspace.directory_identity, @as(?workspace.Identity, source.stamp.root)) or
        source.stamp.root.inode == 0 or selected.file.inode == 0 or !validRelative(selected.relative) or
        !std.mem.eql(u8, source.data_root, store.data_root) or
        !authority.conversation_id.eql(source.stamp.fence.conversation) or authority.binding_revision != source.stamp.fence.binding or
        authority.child_origin != null or current.turn_id == 0 or record.turn_id != current.turn_id or !record.owner.eql(authority.binding))
        return .not_applicable;
    if (record.conversation_id) |c| if (!c.eql(authority.conversation_id)) return .not_applicable;
    const fact = record.host orelse return .not_applicable;
    if (!fact.receipt.conversation_id.eql(authority.conversation_id) or !fact.receipt.task_id.eql(authority.task_id) or
        fact.receipt.binding_revision != authority.binding_revision or fact.receipt.operation_id == 0 or fact.content.len > 48 * 1024)
        return .not_applicable;
    var name_buf: [64]u8 = undefined;
    const name = @import("plugin_tools.zig").decodeName(&name_buf, record.name) catch record.name;
    if (!std.mem.eql(u8, name, "host.local_write_text") and !std.mem.eql(u8, name, "host.local_edit_text")) return .not_applicable;

    const wire = std.json.parseFromSliceLeaky(Wire, a, fact.content, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .not_applicable;
    };
    const base = source.workspace.resolved_directory orelse return .not_applicable;
    if (!wire.operation_ref.valid() or !std.mem.eql(u8, wire.coverage, "managed_local_file_tools") or
        !wire.conversation_ref.eql(authority.conversation_id) or !wire.task_ref.eql(authority.task_id) or
        wire.turn_id != current.turn_id or !std.mem.eql(u8, wire.call_id, record.call_id) or
        !std.mem.eql(u8, wire.resolution_source orelse "", "workspace") or wire.workspace_revision != source.stamp.revision or
        !std.mem.eql(u8, wire.base_directory orelse "", base) or !isTarget(wire.target orelse return .not_applicable, base, selected.relative))
        return .not_applicable;

    // A bound conversation advances its workspace revision when its root
    // identity changes. The directory can also move *before* that observation
    // reaches the controller; reject stale selections even at the same path.
    // This checks only directory metadata. Never use a disk diff as evidence.
    var live_root = try workspace.recheck(a, store.io, source.workspace);
    defer live_root.deinit(a);
    if (!source.workspace.sameState(live_root)) return .not_applicable;
    var saved = (try store.findLocalFile(a, authority, .{ .operation_ref = wire.operation_ref })) orelse return .not_applicable;
    defer saved.deinit(a);
    const evidence = saved.local_file_evidence orelse return .not_applicable;
    if (!std.mem.eql(u8, saved.tool_id, journal.local_file_tool_id) or !saved.context.eql(authority) or
        saved.original_turn != current.turn_id or !std.mem.eql(u8, saved.original_call, record.call_id) or
        !saved.operation_ref.eql(wire.operation_ref) or !evidence.operation_ref.eql(saved.operation_ref) or
        evidence.source != .workspace or evidence.workspace_revision != source.stamp.revision or
        !std.mem.eql(u8, evidence.base_directory orelse "", base) or !isTarget(evidence.target, base, selected.relative) or
        wire.kind != evidence.kind or !toolKind(name, evidence.kind)) return .not_applicable;

    const op = saved.operation_ref;
    const result = saved.local_file_result orelse return .{ .unverified = op };
    if (!record.dispatched or !fact.receipt.local_released or
        !saved.dispatch_started or saved.stage != .succeeded or result.status != .verified or !result.side_effect_started or
        !result.verified or !result.committed or result.conflict or saved.remote_effect_unknown or fact.status != .succeeded or
        !fact.receipt.side_effect_started or fact.receipt.remote_effect_unknown or wire.journal_outcome_unknown or
        wire.status != .verified or !wire.verified or !wire.committed or wire.conflict) return .{ .unverified = op };
    if (saved.local_file_material_expired == true or wire.diff_expired) return .{ .expired = op };
    // The path alone is not the selected file. A replaced object does not
    // inherit its predecessor's text, even at the same relative name.
    if (!std.meta.eql(selected.file, evidence.recovery.candidate_identity) or !std.meta.eql(result.actual_before_version, evidence.approved_version) or
        !std.meta.eql(result.submitted_after_version, @as(@TypeOf(result.submitted_after_version), evidence.candidate_version)))
        return .{ .unavailable = op };
    const reference = result.diff_ref orelse return .{ .unavailable = op };
    const approved_hash = evidence.approved_diff_hash orelse return .{ .unavailable = op };
    // verifyCommit() proves the actually displaced object == the approved
    // preimage and the published object == the candidate before binding the
    // approved material to a verified receipt. "actual" is a conflict path.
    if (reference.kind != .approved or !std.mem.eql(u8, &reference.digest, &approved_hash) or wire.diff_content_error != null) return .{ .unavailable = op };
    const diff = wire.diff orelse return .{ .unavailable = op };
    if (diff.lines.len > 96) return .{ .unavailable = op };
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    const encoded = try std.json.Stringify.valueAlloc(a, diff, .{});
    defer a.free(encoded);
    sha.update(encoded);
    const digest = sha.finalResult();
    if (!std.mem.eql(u8, &digest, &reference.digest)) return .{ .unavailable = op };
    return .{ .change = .{ .operation = op, .kind = evidence.kind, .order = saved.local_file_order orelse return .{ .unavailable = op }, .diff = diff } };
}

fn toolKind(name: []const u8, kind: commit.Kind) bool {
    return if (std.mem.eql(u8, name, "host.local_edit_text")) kind == .edit else kind == .create or kind == .replace or kind == .append;
}
fn validRelative(path: []const u8) bool {
    if (path.len == 0 or path.len >= std.Io.Dir.max_path_bytes or !std.unicode.utf8ValidateSlice(path)) return false;
    var components = std.mem.splitScalar(u8, path, '/');
    var depth: usize = 0;
    while (components.next()) |c| {
        depth += 1;
        if (depth > preview.max_depth + 1 or c.len == 0 or c.len > std.Io.Dir.max_name_bytes or
            std.mem.eql(u8, c, ".") or std.mem.eql(u8, c, "..") or paths.isRecoveryName(c)) return false;
        for (c) |b| if (b < 32 or b == 127) return false;
    }
    return true;
}
fn isTarget(path: []const u8, root: []const u8, relative: []const u8) bool {
    if (!std.fs.path.isAbsolute(root)) return false;
    const prefix = std.mem.trimEnd(u8, root, "/");
    return std.mem.startsWith(u8, path, prefix) and path.len > prefix.len and path[prefix.len] == '/' and
        std.mem.eql(u8, path[prefix.len + 1 ..], relative);
}

const testing = std.testing;
const operations = @import("local_file_operation.zig");
const reads = @import("../host/local_file_reads.zig");
fn allowTestCommit(_: *anyopaque, _: *const commit.Prepared) !void {}

const Fixture = struct {
    a: std.mem.Allocator,
    current: Current,
    journal: *ProcessJournal,

    fn init(a: std.mem.Allocator, tmp: std.Io.Dir) !Fixture {
        const io = testing.io;
        try tmp.createDirPath(io, "project/src");
        const data_root = try tmp.realPathFileAlloc(io, ".", a);
        const dir = try tmp.realPathFileAlloc(io, "project", a);
        const snap = try workspace.inspect(a, io, dir);
        const context: host.Context = .{
            .conversation_id = id.ConversationId.generate(),
            .task_id = id.TaskId.generate(),
            .binding = .{ .session = 31 },
            .binding_revision = 4,
            .grant_revision = 3,
        };
        return .{
            .a = a,
            .current = .{ .authority = context, .turn_id = 12, .source = .{ .workspace = snap, .data_root = data_root, .stamp = .{
                .owner = .{ .session_id = @fromBackingInt(31), .generation = 2 },
                .fence = .{ .agent = id.AgentId.generate(), .conversation = context.conversation_id, .binding = 4, .environment = 1 },
                .scope_revision = 2,
                .revision = snap.revision,
                .root = snap.directory_identity.?,
            } } },
            .journal = try ProcessJournal.acquire(.{ .data_root = data_root, .dir = tmp, .io = io, .path = "state/lifecycle.json" }),
        };
    }

    const Mutation = struct { record: facts.Record, version: reads.Version, operation: id.HostOperationId };
    fn mutate(f: Fixture, relative: []const u8, req: commit.Request, explicit_base: bool, call: []const u8) !Mutation {
        const a = f.a;
        const io = testing.io;
        const base = if (explicit_base) f.current.source.workspace.resolved_directory else null;
        const tool = if (req.kind == .edit) "host.local_edit_text" else "host.local_write_text";
        const inv: host.Invocation = .{
            .context = f.current.authority,
            .authority = .local_files,
            .operation_id = 31,
            .turn_id = f.current.turn_id,
            .call_id = call,
            .tool_id = tool,
            .arguments = .null,
            .arguments_json = "{}",
            .arguments_hash = @splat(0),
            .canonical_arguments_hash = @splat(0),
        };
        var txn = try operations.Transaction.claim(f.journal, .{ .context = inv.context, .request_key = call, .canonical_hash = try operations.canonicalHash(a, .{ .path = relative }, base, req), .turn_id = inv.turn_id, .call_id = call });
        const target = try paths.resolve(a, io, .{ .path = relative, .base_directory = base, .workspace = f.current.source.workspace }, if (req.kind == .create) .create else .file);
        defer target.deinit(a, io);
        const plan = try commit.prepare(a, io, &target, req);
        const ack = try commit.commit(a, io, &plan, txn.handle.operation_ref, try txn.callbacks(), .{ .context = &txn, .validate = allowTestCommit });
        try testing.expect(ack.committed and ack.verified and !ack.conflict);
        var saved = try txn.snapshot(a);
        defer saved.deinit(a);
        const fact = try @import("local_file_change_query.zig").mutationResult(a, io, inv, saved, ack);
        return .{
            .record = .{ .arena = .init(a), .owner = inv.context.binding, .turn_id = inv.turn_id, .call_id = call, .name = tool, .arguments = "{}", .command = "{}", .arguments_hash = @splat(0), .targets = &.{}, .dispatched = true, .host = .{ .status = fact.status, .receipt = fact.receipt, .content = fact.blocks[0].structured } },
            .version = ack.submitted_after_version.?,
            .operation = txn.handle.operation_ref,
        };
    }
    fn selected(f: Fixture, path: []const u8) !Selection {
        var result = try preview.capture(f.a, testing.io, f.current.source, .read, path);
        defer result.release();
        return .{ .relative = path, .stamp = f.current.source.stamp, .file = result.text.file.? };
    }
};

test "workspace turn diff presents only the actual operation from host and journal; untouched by later disk edits" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try Fixture.init(arena.allocator(), tmp.dir);
    defer f.journal.release();
    const create = try f.mutate("src/a", .{ .kind = .create, .text = "initial\n" }, false, "first");
    const original = try f.selected("src/a");
    const first = (try project(f.a, f.current, original, &create.record, f.journal)).change;
    try testing.expect(first.operation.eql(create.operation));
    try testing.expectEqualStrings("initial\n", first.diff.lines[0].text);
    const edit = try f.mutate("src/a", .{ .kind = .edit, .edits = &.{.{ .old_text = "initial", .new_text = "second" }}, .expected_version = &create.version }, false, "second");
    const current = try f.selected("src/a");
    const second = (try project(f.a, f.current, current, &edit.record, f.journal)).change;
    try testing.expect(second.order > first.order and second.operation.eql(edit.operation));
    try testing.expectEqual(@as(?usize, 1), second.diff.added);
    try testing.expectEqual(@as(?usize, 1), second.diff.removed);
    try testing.expectEqualStrings("initial\n", second.diff.lines[0].text);
    try testing.expectEqualStrings("second\n", second.diff.lines[1].text);
    try testing.expect((try project(f.a, f.current, current, &create.record, f.journal)) == .unavailable);
    // Even once the selected file is externally edited in-place, neither Git
    // nor its current contents become the historical receipt for this call.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "project/src/a", .data = "not an AI change\n" });
    const after = try f.selected("src/a");
    try testing.expectEqualStrings("second\n", (try project(f.a, f.current, after, &edit.record, f.journal)).change.diff.lines[1].text);
    _ = try f.journal.expireLocalFiles(f.current.authority.conversation_id);
    try testing.expect((try project(f.a, f.current, after, &edit.record, f.journal)) == .expired);
}

test "workspace turn diff denies cross conversation task turn grant root revision operation tool and unrelated file" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try Fixture.init(arena.allocator(), tmp.dir);
    defer f.journal.release();
    const r = try f.mutate("src/a", .{ .kind = .create, .text = "PRIVATE\n" }, false, "write1");
    const other = try f.mutate("src/b", .{ .kind = .create, .text = "public\n" }, true, "write2");
    const s = try f.selected("src/a");
    try testing.expect((try project(f.a, f.current, try f.selected("src/b"), &other.record, f.journal)) == .not_applicable);
    for (0..14) |i| {
        var c = f.current;
        var sel = s;
        var rec = r.record;
        switch (i) {
            0 => c.authority.conversation_id = id.ConversationId.generate(),
            1 => c.authority.task_id = id.TaskId.generate(),
            2 => c.turn_id += 1,
            3 => c.authority.grant_revision += 1,
            4 => sel.stamp.root.inode += 1,
            5 => {
                c.source.stamp.revision += 1;
                c.source.workspace.revision = c.source.stamp.revision;
                sel.stamp = c.source.stamp;
            },
            6 => sel.relative = "../src/a",
            7 => rec.call_id = "write2",
            8 => rec.name = "another_tool",
            9 => rec.host.?.content = "{",
            10 => rec.owner = .{ .session = 32 },
            11 => rec.host.?.receipt.binding_revision += 1,
            12 => {
                c.authority.binding_revision += 1;
                c.source.stamp.fence.binding = c.authority.binding_revision;
                sel.stamp = c.source.stamp;
            },
            13 => c.source.workspace.directory = null,
            else => unreachable,
        }
        try testing.expect((try project(f.a, c, sel, &rec, f.journal)) == .not_applicable);
    }
    var rec = r.record;
    rec.host.?.status = .outcome_unknown;
    try testing.expect((try project(f.a, f.current, s, &rec, f.journal)) == .unverified);
    rec = r.record;
    rec.dispatched = false;
    try testing.expect((try project(f.a, f.current, s, &rec, f.journal)) == .unverified);
    rec = r.record;
    rec.host.?.receipt.remote_effect_unknown = true;
    try testing.expect((try project(f.a, f.current, s, &rec, f.journal)) == .unverified);
    rec = r.record;
    const bytes = try f.a.dupe(u8, rec.host.?.content);
    const at = std.mem.indexOf(u8, bytes, "PRIVATE").?;
    bytes[at] = 'X';
    rec.host.?.content = bytes;
    try testing.expect((try project(f.a, f.current, s, &rec, f.journal)) == .unavailable);
    var detached = s;
    detached.file.inode += 1;
    try testing.expect((try project(f.a, f.current, detached, &r.record, f.journal)) == .unavailable);
}

test "workspace turn diff rejects a replaced workspace at the same path even when the original file survives" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try Fixture.init(arena.allocator(), tmp.dir);
    defer f.journal.release();
    const r = try f.mutate("src/a", .{ .kind = .create, .text = "original root only\n" }, false, "root-proof");
    const old = try f.selected("src/a");
    try testing.expect((try project(f.a, f.current, old, &r.record, f.journal)) == .change);
    const io = testing.io;
    try tmp.dir.rename("project", tmp.dir, "old-root", io);
    try tmp.dir.createDir(io, "project", .default_dir);
    try tmp.dir.rename("old-root/src", tmp.dir, "project/src", io);
    try testing.expect((try project(f.a, f.current, old, &r.record, f.journal)) == .not_applicable);
    var rebound = f.current;
    rebound.source.workspace = try workspace.inspect(f.a, io, f.current.source.workspace.directory.?);
    // Explicit adoption via session_lifecycle.setWorkspace advances the
    // conversation revision, even when the canonical path stays identical.
    rebound.source.workspace.revision = old.stamp.revision + 1;
    rebound.source.stamp.revision = rebound.source.workspace.revision;
    rebound.source.stamp.root = rebound.source.workspace.directory_identity.?;
    var reread = try preview.capture(f.a, io, rebound.source, .read, old.relative);
    defer reread.release();
    const fresh: Selection = .{ .stamp = rebound.source.stamp, .relative = old.relative, .file = reread.text.file.? };
    try testing.expectEqual(old.file, fresh.file);
    try testing.expect(!std.meta.eql(old.stamp.root, fresh.stamp.root));
    try testing.expect((try project(f.a, rebound, fresh, &r.record, f.journal)) == .not_applicable);
}
