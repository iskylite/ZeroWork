//! Both the host and Local terminal entry use the same candidate, approval,
//! journal and commit. Context/session checks stay in the controller.
const std = @import("std");
const host = @import("host_tools.zig");
const provider = @import("provider.zig");
const local = @import("host_local_files.zig");
const file = @import("../host/local_file_commit.zig");
const paths = @import("../host/local_path.zig");
const operations = @import("local_file_operation.zig");
const changes = @import("local_file_change_query.zig");
const approval = @import("host_approval.zig");
const ProcessJournal = @import("lifecycle_runtime.zig").ProcessJournal;

pub const write_id = "host.local_write_text";
pub const edit_id = "host.local_edit_text";
pub const delete_id = "host.local_delete";
pub const move_id = "host.local_move";
const key_field = "\"request_key\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":128,\"description\":\"Use 1 to 128 ASCII letters, digits, or these characters: - _ . :\"}";
const version_field = "\"expected_version\":{\"type\":\"string\",\"minLength\":68,\"maxLength\":68,\"description\":\"Use the exact version from a current local read. Required for edit, replace, append, delete and move. Omit for create.\"}";
const ref_field = "\"file_ref\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":8192}";
pub const contributions = [_]host.Contribution{
    definition(write_id, "Create, replace, or append UTF-8 text on the Mac. Use a stable request_key. Create is exclusive and requires omitting expected_version. Replace and append require expected_version from a current local read; append adds text at the end of the existing file. Use create_parents=true only with mode=create.", key_field ++ "," ++ version_field ++ ",\"mode\":{\"type\":\"string\",\"enum\":[\"create\",\"replace\",\"append\"]},\"text\":{\"type\":\"string\"},\"create_parents\":{\"type\":\"boolean\",\"description\":\"Set to true only with mode=create to allow creating missing parent directories.\"}", "\"request_key\",\"path\",\"mode\",\"text\""),
    definition(edit_id, "Apply exact, nonoverlapping edits to one local UTF-8 file on the Mac. Supply exactly one of path and file_ref, plus expected_version from a current local read. Each old_text must match its occurrence (default 1) exactly; when old_text appears multiple times, pass occurrence to select one instead of enlarging the context. Alternatively replace the inclusive line_start..line_end range with text. Omit base_directory with file_ref. Reuse request_key only for the same request.", key_field ++ "," ++ version_field ++ "," ++ ref_field ++ ",\"edits\":{\"type\":\"array\",\"minItems\":1,\"maxItems\":128,\"items\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"old_text\":{\"type\":\"string\",\"minLength\":1},\"new_text\":{\"type\":\"string\"},\"occurrence\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":1000000}},\"required\":[\"old_text\",\"new_text\"]}},\"line_start\":{\"type\":\"integer\",\"minimum\":1,\"description\":\"Exclusive alternative to edits: replace this first line (1-based, inclusive).\"},\"line_end\":{\"type\":\"integer\",\"minimum\":1,\"description\":\"Last line of the inclusive replacement range.\"},\"text\":{\"type\":\"string\",\"description\":\"Replacement for the line range.\"}", "\"request_key\",\"expected_version\""),
    definition(delete_id, "Delete one regular UTF-8 file on the Mac. The file content is shown for approval and retained in the operation recovery reference; it is not sent to a remote host. Supply exactly one of path and file_ref, plus expected_version from a current local read. Deletion is atomic and verifiable through host.local_get_changes; do not retry an unknown outcome under a new key.", key_field ++ "," ++ version_field ++ "," ++ ref_field, "\"request_key\",\"expected_version\""),
    definition(move_id, "Move or rename one regular UTF-8 file on the Mac between two resolved Mac paths; this never touches a remote host. Supply source_path or source_file_ref, the target_path whose parent directory must already exist, and expected_version from a current local read of the source. base_directory applies to relative source and target paths. An existing target is rejected. Moving invalidates file references to the old path. Cross-volume moves are rejected; copy and delete explicitly instead.", key_field ++ ",\"source_path\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":4095},\"source_file_ref\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":8192},\"target_path\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":4095}," ++ version_field, "\"request_key\",\"target_path\",\"expected_version\""),
};
fn definition(comptime id: []const u8, comptime description: []const u8, comptime extra: []const u8, comptime required: []const u8) host.Contribution {
    return .{ .authority = .local_files, .definition = .{
        .id = id,
        .description = description,
        .schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{" ++ local.path_fields ++ "," ++ extra ++ "},\"required\":[" ++ required ++ "]}",
        .max_argument_bytes = 512 * 1024,
        .effect = .resource_write,
        .approval_policy = .confirm,
    } };
}
pub fn lookup(id: []const u8) ?@import("plugin_tools.zig").ToolDefinition {
    for (contributions) |entry| if (std.mem.eql(u8, id, entry.definition.id)) return entry.definition;
    return null;
}
const Args = struct {
    request_key: []const u8,
    path: ?[]const u8 = null,
    base_directory: ?[]const u8 = null,
    file_ref: ?[]const u8 = null,
    expected_version: ?[]const u8 = null,
    mode: ?enum { create, replace, append } = null,
    text: ?[]const u8 = null,
    edits: ?[]const file.Edit = null,
    create_parents: bool = false,
    line_start: ?u64 = null,
    line_end: ?u64 = null,
    source_path: ?[]const u8 = null,
    source_file_ref: ?[]const u8 = null,
    target_path: ?[]const u8 = null,
};

pub const Authority = struct {
    context: *anyopaque,
    /// Check current grant, target and workspace before displaying approval,
    /// during the wait, and at the final dispatch boundary.
    validate: *const fn (*anyopaque, ?u64) anyerror!void,
    broker: *approval.Broker,
    policy_revision: u64,
};
const Dispatch = struct {
    authority: Authority,
    invocation: host.Invocation,
    dependency: ?u64,
    subject: approval.Subject,
    permit: approval.Permit,
    cancel: ?*provider.CancelToken,

    fn live(self: *const Dispatch) !void {
        if (self.cancel) |token| if (token.isCancelled()) return error.CancelledBeforeDispatch;
        try self.authority.validate(self.authority.context, self.dependency);
        if (self.cancel) |token| if (token.isCancelled()) return error.CancelledBeforeDispatch;
    }
    fn wait(self: *const Dispatch) !void {
        try self.live();
        if (try self.authority.broker.poll(self.permit)) return;
        const waiting = provider.CancelToken.beginUserWait(self.cancel);
        defer waiting.end();
        while (true) {
            try self.live();
            if (try self.authority.broker.poll(self.permit)) return;
            @import("retry.zig").wait(50, self.cancel) catch return error.CancelledBeforeDispatch;
        }
    }
    fn awaitApproval(raw: *anyopaque) !void {
        const self: *Dispatch = @ptrCast(@alignCast(raw));
        try self.wait();
    }
    fn check(raw: *anyopaque, proposal: *const file.Prepared) !void {
        const self: *Dispatch = @ptrCast(@alignCast(raw));
        try self.live();
        if (!std.mem.eql(u8, &self.subject.evidence_hash.?, &proposal.evidence_hash)) return error.ToolApprovalChanged;
        switch (self.authority.broker.authorizeSubject(self.permit, self.invocation, self.subject, self.authority.policy_revision)) {
            .allow => {},
            .approval_required => return error.ToolApprovalRequired,
            .denied => return error.ToolApprovalRejected,
            .scope_changed => return error.ToolApprovalChanged,
        }
    }
};

pub fn execute(allocator: std.mem.Allocator, io: std.Io, state: local.State, owner: *ProcessJournal, invocation: host.Invocation, authority: Authority, cancel: ?*provider.CancelToken) !host.Result {
    if (invocation.authority != .local_files or lookup(invocation.tool_id) == null) return error.InvalidHostAuthority;
    const is_edit = std.mem.eql(u8, invocation.tool_id, edit_id);
    const is_delete = std.mem.eql(u8, invocation.tool_id, delete_id);
    const is_move = std.mem.eql(u8, invocation.tool_id, move_id);
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = (try std.json.parseFromValue(Args, a, invocation.arguments, .{})).value;
    const source_selector: operations.CanonicalTarget = if (is_move) blk: {
        if ((args.source_path == null) == (args.source_file_ref == null)) return error.InvalidFileTarget;
        if (args.path != null or args.file_ref != null) return error.InvalidArguments;
        break :blk if (args.source_path) |value| .{ .path = value } else .{ .file_ref = args.source_file_ref.? };
    } else blk: {
        if ((args.path == null) == (args.file_ref == null)) return error.InvalidFileTarget;
        break :blk if (args.path) |value| .{ .path = value } else .{ .file_ref = args.file_ref.? };
    };
    const request: file.Request = if (is_edit) .{
        .kind = .edit,
        .edits = args.edits orelse &.{},
        .expected_version = args.expected_version,
        .line_start = args.line_start,
        .line_end = args.line_end,
        .text = if (args.line_start != null) (args.text orelse return error.InvalidEdits) else "",
    } else if (is_delete) .{
        .kind = .delete,
        .expected_version = args.expected_version,
    } else if (is_move) .{
        .kind = .move,
        .expected_version = args.expected_version,
        .destination = args.target_path orelse return error.InvalidArguments,
    } else .{
        .kind = switch (args.mode orelse return error.InvalidWriteMode) {
            .create => .create,
            .replace => .replace,
            .append => .append,
        },
        .text = args.text orelse return error.InvalidArguments,
        .expected_version = args.expected_version,
        .create_parents = args.create_parents,
    };
    if (!is_edit and !is_delete and !is_move) {
        if (args.edits != null or args.file_ref != null or args.line_start != null) return error.InvalidArguments;
        if (args.mode.? == .create and args.expected_version != null) return error.InvalidExpectedVersion;
        if (args.mode.? != .create and args.expected_version == null) return error.ExpectedVersionRequired;
    }
    if (is_edit) {
        if (args.mode != null or args.create_parents) return error.InvalidArguments;
        if (args.line_start != null) {
            if (args.edits != null or args.line_end == null or args.text == null) return error.InvalidEdits;
        } else {
            if (args.edits == null or args.text != null or args.line_end != null) return error.InvalidEdits;
        }
    }
    if (is_delete and (args.mode != null or args.text != null or args.edits != null or args.create_parents or args.line_start != null or args.target_path != null or args.source_path != null)) return error.InvalidArguments;
    if (is_move and (args.mode != null or args.text != null or args.edits != null or args.line_start != null or args.file_ref != null or args.path != null or args.create_parents)) return error.InvalidArguments;
    if (!is_move and (args.source_path != null or args.source_file_ref != null or args.target_path != null)) return error.InvalidArguments;
    try authority.validate(authority.context, null);
    const semantic = try operations.canonicalHash(a, source_selector, args.base_directory, request);
    var transaction = try operations.Transaction.claim(owner, .{
        .context = invocation.context,
        .request_key = args.request_key,
        .canonical_hash = semantic,
        .turn_id = invocation.turn_id,
        .call_id = invocation.call_id,
    });
    if (transaction.handle.reused) {
        const record = try transaction.snapshot(a);
        return changes.mutationResult(allocator, io, invocation, record, null);
    }
    const dependency = if (local.usesPreferredBase(invocation.arguments)) state.workspace.revision else null;
    var actual: ?[]const u8 = null;
    const receipt = runNew(a, io, state, invocation, &transaction, authority, args, request, source_selector, dependency, cancel, &actual) catch |err| {
        // commit propagates errors only before dispatch. Unknown journal writes
        // and every post-syscall outcome return a typed receipt.
        transaction.rejectAt(err, actual) catch {};
        return local.result(allocator, invocation, if (err == error.CancelledBeforeDispatch) .cancelled_unsent else .rejected, .{
            .coverage = "managed_local_file_tools",
            .target = actual,
            .status = "rejected",
            .committed = false,
            .verified = false,
            .conflict = false,
            .operation_ref = transaction.handle.operation_ref,
            .error_code = @errorName(err),
            .side_effect_started = false,
        });
    };
    const record = transaction.snapshot(a) catch return fallback(allocator, invocation, actual, receipt) catch error.LocalFileReceiptUnavailable;
    return changes.mutationResult(allocator, io, invocation, record, receipt) catch return fallback(allocator, invocation, actual, receipt) catch error.LocalFileReceiptUnavailable;
}

fn runNew(a: std.mem.Allocator, io: std.Io, state: local.State, invocation: host.Invocation, transaction: *operations.Transaction, authority: Authority, args: Args, request: file.Request, source_selector: anytype, dependency: ?u64, cancel: ?*provider.CancelToken, actual: *?[]const u8) !file.Receipt {
    if (dependency != null and invocation.workspace_revision != dependency) return error.WorkspaceChanged;
    try authority.validate(authority.context, dependency);
    if (request.create_parents and request.kind != .create) return error.InvalidWriteMode;
    const options: paths.Options = .{
        .path = switch (source_selector) {
            .path => |value| value,
            .file_ref => null,
        },
        .file_ref = switch (source_selector) {
            .path => null,
            .file_ref => |ref| try local.openReference(a, state.reference_key orelse return error.LocalFileReferenceUnavailable, invocation.context.conversation_id, ref),
        },
        .base_directory = args.base_directory,
        .workspace = state.workspace,
        .local_cwd = state.cwd,
        .home = state.home,
        .app_data_root = state.app_data_root,
        .conversation = invocation.context.conversation_id,
        .create_parents = request.create_parents,
    };
    const mode: paths.Mode = if (request.kind == .create) .create else .file;
    var target = paths.resolve(a, io, options, mode) catch |err| {
        if (paths.attempt(a, options)) |attempt| actual.* = attempt.absolute else |_| {}
        return err;
    };
    // The result keeps its own name, even when the descriptor is released.
    defer target.deinit(a, io);
    actual.* = try a.dupe(u8, target.absolute);
    target.workspace_revision = dependency;
    // A move resolves the destination through the same base rules as the
    // source; the resolved path becomes the published destination.
    var move_destination: ?paths.Resolved = null;
    defer if (move_destination) |*resolved| resolved.deinit(a, io);
    if (request.kind == .move) {
        const destination_options: paths.Options = .{
            .path = request.destination,
            .base_directory = args.base_directory,
            .workspace = state.workspace,
            .local_cwd = state.cwd,
            .home = state.home,
            .app_data_root = state.app_data_root,
            .conversation = invocation.context.conversation_id,
            .create_parents = request.create_parents,
        };
        move_destination = try paths.resolve(a, io, destination_options, .create);
        if (std.mem.eql(u8, move_destination.?.absolute, target.absolute)) return error.InvalidMoveTarget;
    }
    var bounded = request;
    bounded.destination = if (move_destination) |*resolved| resolved.absolute else request.destination;
    const proposal = if (move_destination) |*resolved|
        try file.prepareMove(a, io, &target, resolved, bounded)
    else
        try file.prepare(a, io, &target, bounded);
    try authority.validate(authority.context, dependency);
    const detail = try approvalDetail(a, &proposal);
    const subject: approval.Subject = .{
        .kind = .local_file,
        .target = target.absolute,
        .detail = detail,
        .impact = switch (request.kind) {
            .create => "在所示路径创建文件。",
            .delete => "删除所示路径的文件，删除前内容已保留在恢复引用中。",
            .move => "将所示路径的文件移动到目标路径。",
            else => "在所示路径写入批准的修改。",
        },
        .evidence_hash = proposal.evidence_hash,
    };
    const permit = try authority.broker.beginSubject(invocation, subject, authority.policy_revision, a);
    defer authority.broker.finish(permit);
    var dispatch: Dispatch = .{ .authority = authority, .invocation = invocation, .dependency = dependency, .subject = subject, .permit = permit, .cancel = cancel };
    try dispatch.wait();
    return file.commit(a, io, &proposal, transaction.handle.operation_ref, try transaction.callbacks(), .{ .context = &dispatch, .validate = Dispatch.check, .wait_for_approval = Dispatch.awaitApproval });
}

fn approvalDetail(a: std.mem.Allocator, proposal: *const file.Prepared) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var parents: [paths.max_create_parents][]const u8 = undefined;
    const directories = proposal.target.plannedParents(&parents);
    if (directories.len > 0) {
        try out.writer.writeAll("将创建目录\n");
        for (directories) |directory| try out.writer.print("{s}\n", .{directory});
        try out.writer.writeByte('\n');
    }
    switch (proposal.kind) {
        .delete => {
            // The retained content is the approval basis for a deletion.
            try out.writer.writeAll("将删除文件，删除前内容如下（已保留在恢复引用中）：\n");
            for (proposal.diff.lines) |line| {
                try out.writer.print("−{d}  {s}\n", .{ line.number, std.mem.trimEnd(u8, line.text, "\r\n") });
            }
            if (proposal.diff.truncated) try out.writer.writeAll("部分内容未显示");
            return out.toOwnedSlice();
        },
        .move => {
            if (proposal.target.requested.len != 0) {
                try out.writer.print("将从 {s} 移动到 {s}\n", .{ proposal.target.absolute, proposal.destination orelse proposal.target.absolute });
            } else {
                try out.writer.print("将移动到 {s}\n", .{proposal.destination orelse proposal.target.absolute});
            }
            try out.writer.writeByte('\n');
        },
        else => {},
    }
    for (proposal.diff.lines) |line| {
        try out.writer.print("{s}{d}  {s}\n", .{
            if (line.kind == .add) "+" else "−",
            line.number,
            std.mem.trimEnd(u8, line.text, "\r\n"),
        });
    }
    if (proposal.diff.truncated) {
        try out.writer.writeAll("部分差异未显示");
    } else if (proposal.diff.lines.len == 0) {
        try out.writer.writeAll(if (proposal.kind == .create) "创建空文件" else "文件内容不变");
    }
    return out.toOwnedSlice();
}

fn fallback(a: std.mem.Allocator, invocation: host.Invocation, target: ?[]const u8, receipt: file.Receipt) !host.Result {
    var result = try local.result(a, invocation, if (receipt.status == .unknown or receipt.journal_outcome_unknown) .outcome_unknown else if (receipt.verified) .succeeded else .failed, .{
        .coverage = "managed_local_file_tools",
        .target = target,
        .status = if (receipt.journal_outcome_unknown) file.Status.unknown else receipt.status,
        .operation_ref = receipt.operation_ref,
        .committed = receipt.committed,
        .verified = receipt.verified,
        .conflict = receipt.conflict,
        .side_effect_started = receipt.side_effect_started,
        .error_code = "ChangeProjectionUnavailable",
    });
    result.receipt.side_effect_started = receipt.side_effect_started;
    return result;
}
