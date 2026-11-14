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
const key_field = "\"request_key\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":128,\"description\":\"Use 1 to 128 ASCII letters, digits, or these characters: - _ . :\"}";
const version_field = "\"expected_version\":{\"type\":\"string\",\"minLength\":68,\"maxLength\":68,\"description\":\"Use the exact version from a current read. Required for edit and replace. Omit for create.\"}";
const ref_field = "\"file_ref\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":8192}";
pub const contributions = [_]host.Contribution{
    definition(write_id, "Create or replace UTF-8 text on the Mac. Use a stable request_key. Create is exclusive and requires omitting expected_version. Replace requires expected_version from a current local read. Use create_parents=true only with mode=create.", key_field ++ "," ++ version_field ++ ",\"mode\":{\"type\":\"string\",\"enum\":[\"create\",\"replace\"]},\"text\":{\"type\":\"string\"},\"create_parents\":{\"type\":\"boolean\",\"description\":\"Set to true only with mode=create to allow creating missing parent directories.\"}", "\"request_key\",\"path\",\"mode\",\"text\""),
    definition(edit_id, "Apply exact, nonoverlapping edits to one local UTF-8 file. Supply exactly one of path and file_ref, plus expected_version from a current local read. Omit base_directory with file_ref. Reuse request_key only for the same request.", key_field ++ "," ++ version_field ++ "," ++ ref_field ++ ",\"edits\":{\"type\":\"array\",\"minItems\":1,\"maxItems\":128,\"items\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"old_text\":{\"type\":\"string\",\"minLength\":1},\"new_text\":{\"type\":\"string\"}},\"required\":[\"old_text\",\"new_text\"]}}", "\"request_key\",\"expected_version\",\"edits\""),
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
    mode: ?enum { create, replace } = null,
    text: ?[]const u8 = null,
    edits: ?[]const file.Edit = null,
    create_parents: bool = false,
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
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = (try std.json.parseFromValue(Args, a, invocation.arguments, .{})).value;
    if ((args.path == null) == (args.file_ref == null)) return error.InvalidFileTarget;
    const request: file.Request = if (is_edit) .{
        .kind = .edit,
        .edits = args.edits orelse return error.InvalidEdits,
        .expected_version = args.expected_version,
    } else .{
        .kind = switch (args.mode orelse return error.InvalidWriteMode) {
            .create => .create,
            .replace => .replace,
        },
        .text = args.text orelse return error.InvalidArguments,
        .expected_version = args.expected_version,
        .create_parents = args.create_parents,
    };
    if (!is_edit and (args.edits != null or args.file_ref != null)) return error.InvalidArguments;
    if (is_edit and (args.mode != null or args.text != null or args.create_parents)) return error.InvalidArguments;
    try authority.validate(authority.context, null);
    const semantic = try operations.canonicalHash(a, if (args.path) |value| .{ .path = value } else .{ .file_ref = args.file_ref.? }, args.base_directory, request);
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
    const receipt = runNew(a, io, state, invocation, &transaction, authority, args, request, dependency, cancel, &actual) catch |err| {
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

fn runNew(a: std.mem.Allocator, io: std.Io, state: local.State, invocation: host.Invocation, transaction: *operations.Transaction, authority: Authority, args: Args, request: file.Request, dependency: ?u64, cancel: ?*provider.CancelToken, actual: *?[]const u8) !file.Receipt {
    if (dependency != null and invocation.workspace_revision != dependency) return error.WorkspaceChanged;
    try authority.validate(authority.context, dependency);
    if (request.create_parents and request.kind != .create) return error.InvalidWriteMode;
    const options: paths.Options = .{
        .path = args.path,
        .file_ref = if (args.file_ref) |ref| try local.openReference(a, state.reference_key orelse return error.LocalFileReferenceUnavailable, invocation.context.conversation_id, ref) else null,
        .base_directory = args.base_directory,
        .workspace = state.workspace,
        .local_cwd = state.cwd,
        .home = state.home,
        .app_data_root = state.app_data_root,
        .conversation = invocation.context.conversation_id,
        .create_parents = request.create_parents,
    };
    var target = paths.resolve(a, io, options, if (request.kind == .create) .create else .file) catch |err| {
        if (paths.attempt(a, options)) |attempt| actual.* = attempt.absolute else |_| {}
        return err;
    };
    // The result keeps its own name, even when the descriptor is released.
    defer target.deinit(a, io);
    actual.* = try a.dupe(u8, target.absolute);
    target.workspace_revision = dependency;
    const proposal = try file.prepare(a, io, &target, request);
    try authority.validate(authority.context, dependency);
    const detail = try approvalDetail(a, &proposal);
    const subject: approval.Subject = .{
        .kind = .local_file,
        .target = target.absolute,
        .detail = detail,
        .impact = if (request.kind == .create) "在所示路径创建文件。" else "在所示路径写入批准的修改。",
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
