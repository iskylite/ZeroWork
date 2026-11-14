//! Read-only projection of managed local file operations. Authority is a
//! controller-supplied set of conversation/task pairs, not a model reference.
const std = @import("std");
const host = @import("host_tools.zig");
const identity = @import("../host/identity.zig");
const journal = @import("lifecycle_journal.zig");
const ProcessJournal = @import("lifecycle_runtime.zig").ProcessJournal;
const commit = @import("../host/local_file_commit.zig");
const reads = @import("../host/local_file_reads.zig");

pub const Scope = journal.LocalFileScope;
pub const tool_id = "host.local_get_changes";
const result_limit = 47 * 1024;
pub const contribution: host.Contribution = .{
    .authority = .local_files,
    .definition = .{
        .id = tool_id,
        .description = "List managed local file changes for the current task and authorized child tasks. For a list, optionally pass task_ref, cursor and limit. For a bounded diff, pass exactly one of operation_ref or change_ref from a receipt and omit task_ref, cursor and limit. A version discontinuity describes edits outside the listed operations. verify observes current files without changing the original commit receipt. Shell, MCP, remote tools, and external edits are outside this log.",
        .schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{" ++
            "\"task_ref\":{\"type\":\"string\",\"minLength\":32,\"maxLength\":32}," ++
            "\"operation_ref\":{\"type\":\"string\",\"minLength\":32,\"maxLength\":32}," ++
            "\"change_ref\":{\"type\":\"string\",\"minLength\":32,\"maxLength\":32}," ++
            "\"cursor\":{\"type\":\"string\",\"maxLength\":128}," ++
            "\"limit\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":12,\"description\":\"List only. Maximum 4 with verify=true.\"}," ++
            "\"verify\":{\"type\":\"boolean\"}}}",
    },
};

const Args = struct {
    task_ref: ?identity.TaskId = null,
    operation_ref: ?identity.HostOperationId = null,
    change_ref: ?identity.HostOperationId = null,
    cursor: ?[]const u8 = null,
    limit: ?usize = null,
    verify: bool = false,
};

const Observation = struct {
    checked_at_ms: i64,
    current_version: ?[]const u8 = null,
    matches_submitted_candidate: bool = false,
    staged_entry_version: ?[]const u8 = null,
    staged_entry_is_candidate: bool = false,
    candidate_payload_preserved: bool = false,
    matching_parent_count: u8 = 0,
    error_code: ?[]const u8 = null,
    target_error: ?[]const u8 = null,
    staged_entry_error: ?[]const u8 = null,
    candidate_payload_error: ?[]const u8 = null,
};

const Projection = struct {
    coverage: []const u8 = "managed_local_file_tools",
    operation_ref: identity.HostOperationId,
    change_ref: identity.HostOperationId,
    conversation_ref: identity.ConversationId,
    task_ref: identity.TaskId,
    turn_id: u64,
    call_id: []const u8,
    request_key: []const u8,
    target: ?[]const u8,
    requested_path: ?[]const u8 = null,
    base_directory: ?[]const u8 = null,
    resolution_source: ?[]const u8 = null,
    workspace_revision: ?u64 = null,
    kind: ?commit.Kind = null,
    stage: journal.Stage,
    status: commit.Status,
    side_effect_started: ?bool,
    dispatch_started: bool,
    committed: bool,
    verified: bool,
    conflict: bool,
    journal_outcome_unknown: bool = false,
    error_code: ?[]const u8 = null,
    approved_before_version: ?[]const u8 = null,
    actual_before_version: ?[]const u8 = null,
    submitted_after_version: ?[]const u8 = null,
    recovery_ref: ?identity.HostOperationId = null,
    original_retained: bool = false,
    diff: ?commit.Diff = null,
    diff_expired: bool = false,
    diff_content_error: ?[]const u8 = null,
    planned_parents: []const []const u8 = &.{},
    created_parents: []const []const u8 = &.{},
    created_parent_count: u8 = 0,
    previous_operation_ref: ?identity.HostOperationId = null,
    version_chain: @FieldType(journal.LocalFilePage.Row, "version_chain") = .first_observed,
    observation: ?Observation = null,
};

fn errorName(err: ?anyerror) ?[]const u8 {
    return if (err) |value| @errorName(value) else null;
}

fn versionText(a: std.mem.Allocator, value: ?reads.Version) !?[]const u8 {
    return if (value) |version| try a.dupe(u8, &version) else null;
}

fn observe(a: std.mem.Allocator, io: std.Io, evidence: commit.Evidence) !Observation {
    const checked = std.Io.Clock.real.now(io).toMilliseconds();
    const observed = commit.observe(a, io, evidence) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{ .checked_at_ms = checked, .error_code = @errorName(err) };
    };
    return .{
        .checked_at_ms = checked,
        .current_version = try versionText(a, observed.target_version),
        .matches_submitted_candidate = observed.candidate_matches,
        .staged_entry_version = try versionText(a, observed.staged_entry_version),
        .staged_entry_is_candidate = observed.staged_entry_is_candidate,
        .candidate_payload_preserved = observed.candidate_payload_preserved,
        .matching_parent_count = observed.matching_parent_count,
        .target_error = errorName(observed.target_error),
        .staged_entry_error = errorName(observed.staged_entry_error),
        .candidate_payload_error = errorName(observed.candidate_payload_error),
    };
}

/// The arena owns loaded diff and observation text. Do not turn a current
/// observation into a historical commit claim, even when candidate bytes match.
fn project(a: std.mem.Allocator, io: std.Io, record: journal.Record, live: ?commit.Receipt, include_diff: bool, verify: bool) !Projection {
    const old = record.local_file_result;
    const evidence = record.local_file_evidence;
    const journal_unknown = if (live) |receipt| receipt.journal_outcome_unknown else false;
    const status: commit.Status = if (journal_unknown) .unknown else if (live) |receipt| receipt.status else if (old) |value| value.status else switch (record.stage) {
        .cancelled_unsent => .rejected,
        else => .unknown,
    };
    const committed = if (live) |receipt| receipt.committed else if (old) |value| value.committed else false;
    const expired = record.local_file_material_expired == true;
    const has_recovery = evidence != null and !expired and (if (live) |receipt| receipt.recovery != null else record.dispatch_started);
    var projected: Projection = .{
        .operation_ref = record.operation_ref,
        .change_ref = record.operation_ref,
        .conversation_ref = record.context.conversation_id,
        .task_ref = record.context.task_id,
        .turn_id = record.original_turn,
        .call_id = record.original_call,
        .request_key = record.request_key,
        .target = if (evidence) |prepared| prepared.target else if (old) |value| value.target else null,
        .requested_path = if (evidence) |prepared| prepared.request_path else null,
        .base_directory = if (evidence) |prepared| prepared.base_directory else null,
        .resolution_source = if (evidence) |prepared| @tagName(prepared.source) else null,
        .workspace_revision = if (evidence) |prepared| prepared.workspace_revision else null,
        .kind = if (evidence) |prepared| prepared.kind else null,
        .stage = record.stage,
        .status = status,
        .side_effect_started = if (live) |receipt| receipt.side_effect_started else if (old) |value| value.side_effect_started else if (record.local_file_parent_progress != null) true else if (record.dispatch_started) null else false,
        .dispatch_started = record.dispatch_started,
        .committed = committed,
        .verified = if (live) |receipt| receipt.verified else if (old) |value| value.verified else false,
        .conflict = if (live) |receipt| receipt.conflict else if (old) |value| value.conflict else false,
        .journal_outcome_unknown = journal_unknown,
        .error_code = if (journal_unknown) "OperationOutcomeUnknown" else if (live) |receipt| errorName(receipt.reason) else if (old) |value| value.reason else switch (record.stage) {
            .cancelled_unsent => "CancelledBeforeDispatch",
            .prepared, .dispatch_started => "OperationInProgress",
            .outcome_unknown => "OperationOutcomeUnknown",
            else => null,
        },
        .approved_before_version = try versionText(a, if (evidence) |prepared| prepared.approved_version else null),
        .actual_before_version = try versionText(a, if (live) |receipt| receipt.actual_before_version else if (old) |value| value.actual_before_version else null),
        .submitted_after_version = try versionText(a, if (live) |receipt| receipt.submitted_after_version else if (old) |value| value.submitted_after_version else null),
        .recovery_ref = if (has_recovery) record.operation_ref else null,
        .original_retained = has_recovery and committed and (if (live) |receipt| receipt.actual_before_version != null else if (old) |value| value.actual_before_version != null else false),
        .diff_expired = expired,
        .diff_content_error = if (expired) "ChangeContentExpired" else null,
    };
    if (evidence) |prepared| {
        if (prepared.parent_chain) |chain| {
            const parents = try a.alloc([]const u8, chain.plan.count);
            for (parents, 0..) |*parent, index| parent.* = chain.plan.parent(prepared.target, index);
            projected.planned_parents = parents;
            const count = if (live) |receipt| receipt.created_parent_count else if (old) |value| value.created_parent_count else record.local_file_parent_progress orelse 0;
            projected.created_parent_count = count;
            projected.created_parents = parents[0..@min(count, parents.len)];
        }
        if (include_diff and !expired) {
            projected.diff = if (live) |receipt| receipt.diff else null;
            if (projected.diff == null) {
                const diff_ref = if (live) |receipt| receipt.diff_ref else if (old) |value| value.diff_ref else null;
                if (diff_ref) |reference| {
                    if (commit.readDiff(a, io, prepared, reference)) |diff| {
                        // The allocation arena is released after serialization.
                        projected.diff = diff.value;
                    } else |err| {
                        if (err == error.OutOfMemory) return err;
                        projected.diff_content_error = @errorName(err);
                        projected.diff_expired = err == error.ChangeContentExpired;
                        if (projected.diff_expired) projected.original_retained = false;
                    }
                } else if (committed or record.dispatch_started) projected.diff_content_error = "ChangeContentUnavailable";
            }
        }
        if (verify) projected.observation = try observe(a, io, prepared);
    }
    return projected;
}

fn finish(a: std.mem.Allocator, invocation: host.Invocation, encoded: []const u8, status: @import("plugin_tools.zig").Status, started: bool) !host.Result {
    const owned = try a.dupe(u8, encoded);
    errdefer a.free(owned);
    const blocks = try a.alloc(host.Block, 1);
    blocks[0] = .{ .structured = owned };
    return .{
        .status = status,
        .blocks = blocks,
        .receipt = .{
            .conversation_id = invocation.context.conversation_id,
            .task_id = invocation.context.task_id,
            .operation_id = invocation.operation_id,
            .binding_revision = invocation.context.binding_revision,
            .side_effect_started = started,
        },
    };
}

fn encodeOperation(a: std.mem.Allocator, projected: Projection) ![]const u8 {
    const bytes = try std.json.Stringify.valueAlloc(a, projected, .{ .emit_null_optional_fields = false });
    if (bytes.len <= result_limit) return bytes;
    if (projected.diff == null) return error.ResultLimit;
    var bounded = projected;
    bounded.diff.?.lines = &.{};
    bounded.diff.?.truncated = true;
    const compact = try std.json.Stringify.valueAlloc(a, bounded, .{ .emit_null_optional_fields = false });
    if (compact.len > result_limit) return error.ResultLimit;
    return compact;
}

pub fn mutationResult(a: std.mem.Allocator, io: std.Io, invocation: host.Invocation, record: journal.Record, live: ?commit.Receipt) !host.Result {
    if (invocation.authority != .local_files or !Scope.from(invocation.context).matches(record.context) or
        !std.mem.eql(u8, record.tool_id, journal.local_file_tool_id) or
        (!std.mem.eql(u8, invocation.tool_id, "host.local_write_text") and
            !std.mem.eql(u8, invocation.tool_id, "host.local_edit_text"))) return error.InvalidHostAuthority;
    if (live) |value| if (!value.operation_ref.eql(record.operation_ref)) return error.StaleOperation;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const result = try project(ar, io, record, live, true, false);
    const status: @import("plugin_tools.zig").Status = switch (result.status) {
        .verified => .succeeded,
        .rejected => .rejected,
        .committed_unverified, .partial => .failed,
        .unknown => .outcome_unknown,
    };
    return finish(a, invocation, try encodeOperation(ar, result), status, result.side_effect_started orelse result.dispatch_started);
}

pub fn execute(a: std.mem.Allocator, io: std.Io, owner: *ProcessJournal, invocation: host.Invocation, children: []const Scope, cursor_key: [32]u8) !host.Result {
    if (invocation.authority != .local_files or !std.mem.eql(u8, invocation.tool_id, tool_id)) return error.InvalidHostAuthority;
    try invocation.context.validate();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const args = (try std.json.parseFromValue(Args, ar, invocation.arguments, .{})).value;
    if (args.operation_ref != null and args.change_ref != null) return error.InvalidArguments;
    const scopes = try queryScopes(ar, Scope.from(invocation.context), children, args.task_ref);
    if (args.operation_ref orelse args.change_ref) |operation| {
        if (args.cursor != null or args.limit != null or args.task_ref != null) return error.InvalidArguments;
        const record = (try owner.findScopedLocalFile(ar, scopes, operation)) orelse return error.LocalFileOperationNotFound;
        const projection = try project(ar, io, record, null, true, args.verify);
        return finish(a, invocation, try encodeOperation(ar, projection), .succeeded, false);
    }
    const max_page: usize = if (args.verify) 4 else journal.max_change_page;
    const limit = args.limit orelse @min(8, max_page);
    if (limit == 0 or limit > max_page) return error.InvalidArguments;
    const binding = try std.json.Stringify.valueAlloc(ar, .{ invocation.context, scopes, args.verify, limit }, .{});
    const supplied = if (args.cursor) |text| try decodeCursor(text, cursor_key, binding) else null;
    const offset = if (supplied) |cursor| cursor.offset else 0;
    const page = try owner.listLocalFiles(ar, scopes, offset, limit);
    if (supplied) |cursor| {
        if (!std.mem.eql(u8, &cursor.snapshot, &page.snapshot)) return error.SnapshotChanged;
    }

    const rows = try ar.alloc(Projection, page.rows.len);
    for (page.rows, rows) |row, *projection| {
        projection.* = try project(ar, io, row.record, null, false, args.verify);
        projection.previous_operation_ref = row.previous_operation;
        projection.version_chain = row.version_chain;
    }
    var visible = rows.len;
    while (true) {
        const next = if (visible < rows.len) offset + visible else page.next_offset;
        const encoded = try std.json.Stringify.valueAlloc(ar, .{
            .coverage = "managed_local_file_tools",
            .operations = rows[0..visible],
            .files = try groupFiles(ar, rows[0..visible]),
            .next_cursor = if (next) |index| try encodeCursor(ar, cursor_key, binding, .{ .offset = index, .snapshot = page.snapshot }) else null,
            .complete = next == null,
        }, .{ .emit_null_optional_fields = false });
        if (encoded.len <= result_limit) return finish(a, invocation, encoded, .succeeded, false);
        if (visible <= 1) return error.ResultLimit;
        visible -= 1;
    }
}

const File = struct {
    target: []const u8,
    operation_refs: std.ArrayList(identity.HostOperationId) = .empty,

    pub fn jsonStringify(self: File, writer: *std.json.Stringify) !void {
        try writer.write(.{ .target = self.target, .operation_refs = self.operation_refs.items });
    }
};

fn groupFiles(a: std.mem.Allocator, rows: []const Projection) ![]const File {
    var groups: std.ArrayList(File) = .empty;
    for (rows) |row| {
        const target = row.target orelse continue;
        const index = for (groups.items, 0..) |group, i| {
            if (std.mem.eql(u8, target, group.target)) break i;
        } else blk: {
            try groups.append(a, .{ .target = target });
            break :blk groups.items.len - 1;
        };
        try groups.items[index].operation_refs.append(a, row.operation_ref);
    }
    return groups.items;
}

fn queryScopes(a: std.mem.Allocator, own: Scope, children: []const Scope, requested: ?identity.TaskId) ![]const Scope {
    var scopes: std.ArrayList(Scope) = .empty;
    if (requested == null or requested.?.eql(own.task_id)) try scopes.append(a, own);
    for (children) |child| {
        if (!child.conversation_id.valid() or !child.task_id.valid()) return error.InvalidHostAuthority;
        if (requested != null and !requested.?.eql(child.task_id)) continue;
        const duplicate = for (scopes.items) |scope| {
            if (scope.conversation_id.eql(child.conversation_id) and scope.task_id.eql(child.task_id)) break true;
        } else false;
        if (!duplicate) try scopes.append(a, child);
    }
    if (scopes.items.len == 0) return error.LocalFileTaskNotAuthorized;
    const Ordering = struct {
        fn less(_: void, lhs: Scope, rhs: Scope) bool {
            const order = std.mem.order(u8, &lhs.conversation_id.bytes, &rhs.conversation_id.bytes);
            if (order != .eq) return order == .lt;
            return std.mem.order(u8, &lhs.task_id.bytes, &rhs.task_id.bytes) == .lt;
        }
    };
    std.mem.sort(Scope, scopes.items, {}, Ordering.less);
    return scopes.items;
}

const Cursor = struct { offset: usize, snapshot: [32]u8 };
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const base64 = std.base64.url_safe_no_pad;
const cursor_prefix = "lc1:";
const cursor_data_len = 4 + 32;
const cursor_wire_len = cursor_data_len + Hmac.mac_length;

fn cursorMac(data: *const [cursor_data_len]u8, key: [32]u8, binding: []const u8) [Hmac.mac_length]u8 {
    var h = Hmac.init(&key);
    h.update(cursor_prefix);
    h.update(data);
    h.update(binding);
    return h.finalResult();
}

fn encodeCursor(a: std.mem.Allocator, key: [32]u8, binding: []const u8, cursor: Cursor) ![]const u8 {
    var wire: [cursor_wire_len]u8 = undefined;
    std.mem.writeInt(u32, wire[0..4], @intCast(cursor.offset), .little);
    @memcpy(wire[4..cursor_data_len], &cursor.snapshot);
    wire[cursor_data_len..].* = cursorMac(wire[0..cursor_data_len], key, binding);
    const text = try a.alloc(u8, cursor_prefix.len + base64.Encoder.calcSize(wire.len));
    @memcpy(text[0..cursor_prefix.len], cursor_prefix);
    _ = base64.Encoder.encode(text[cursor_prefix.len..], &wire);
    return text;
}

fn decodeCursor(text: []const u8, key: [32]u8, binding: []const u8) !Cursor {
    if (!std.mem.startsWith(u8, text, cursor_prefix) or text.len != cursor_prefix.len + base64.Encoder.calcSize(cursor_wire_len))
        return error.CursorExpired;
    var wire: [cursor_wire_len]u8 = undefined;
    base64.Decoder.decode(&wire, text[cursor_prefix.len..]) catch return error.CursorExpired;
    const mac = cursorMac(wire[0..cursor_data_len], key, binding);
    if (!std.crypto.timing_safe.eql([Hmac.mac_length]u8, mac, wire[cursor_data_len..].*)) return error.CursorExpired;
    return .{ .offset = std.mem.readInt(u32, wire[0..4], .little), .snapshot = wire[4..cursor_data_len].* };
}
