//! AI submits paths to the existing transfer queue; file bytes never enter a tool result.
const std = @import("std");
const host = @import("host_tools.zig");
const identity = @import("../host/identity.zig");
const transfer = @import("../transfer/manager.zig");
const approval = @import("host_approval.zig");
pub const Kind = enum { upload_file, download_file, get_transfer, wait_transfer, cancel_transfer };
const session = "\"session_ref\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":128}";
const key = "\"request_key\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":128,\"description\":\"Use 1 to 128 ASCII letters, digits, or these characters: - _ . :\"}";
const ref = "\"transfer_ref\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":128}";
fn path(comptime name: []const u8) []const u8 {
    return "\"" ++ name ++ "\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":4096}";
}
fn tool(comptime name: []const u8, description: []const u8, mutation: bool, comptime fields: []const u8, comptime required: []const u8) host.Contribution {
    return .{ .authority = if (mutation) .lifecycle else .conversation_context, .definition = .{ .id = "host." ++ name, .effect = if (mutation) .resource_write else .read_state, .description = description, .schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{" ++ fields ++ "},\"required\":[" ++ required ++ "]}" } };
}
pub const contributions = [_]host.Contribution{
    tool("upload_file", "Queue a binary file or directory upload from an absolute path on the user's Mac to an absolute remote_directory in an authorized SSH/SFTP session_ref. This uses the application's transfer engine, not a shell or file.write_text; large files do not enter model context. Returns transfer_ref and queue progress, NOT proof of file completion. Reuse the same request_key to observe the original submission; never retry an unknown outcome with a new key. Same-name conflicts require the existing transfer conflict UI. Use wait_transfer/get_transfer; cancellation of AI generation does not cancel an accepted transfer.", true, session ++ "," ++ path("local_path") ++ "," ++ path("remote_directory") ++ "," ++ key, "\"session_ref\",\"local_path\",\"remote_directory\",\"request_key\""),
    tool("download_file", "Queue a binary file or directory download from an absolute remote_path in an authorized SSH/SFTP session_ref. local_directory is an absolute Mac directory; omit it to use the application's configured download directory. The resolved destination is shown in approval and returned with transfer_ref. File bytes never enter context. Queued is not completed: use wait_transfer/get_transfer. Reuse request_key after a lost reply; never redispatch an unknown submission under a new key. Same-name conflicts use the transfer conflict UI.", true, session ++ "," ++ path("remote_path") ++ "," ++ path("local_directory") ++ "," ++ key, "\"session_ref\",\"remote_path\",\"request_key\""),
    tool("get_transfer", "Read progress of an AI-created transfer_ref in this conversation and current authorized binding. Reports bytes, state, conflict waiting, checksum and actual IO cleanup; completed is true only after successful transfer and release. Unavailable after restart is not evidence of success or permission to resubmit. Does not inspect unrelated manual transfers.", false, ref, "\"transfer_ref\""),
    tool("wait_transfer", "Wait up to wait_ms (default 1000, maximum 10000) for an AI-created transfer to settle, pause or require conflict resolution. A wait timeout returns current progress and does not cancel the transfer. Never claim completion from queue acceptance or byte count alone.", false, ref ++ ",\"wait_ms\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":10000}", "\"transfer_ref\""),
    tool("cancel_transfer", "Request cancellation of the original AI-created transfer_ref. Repeated cancellation never creates a replacement transfer. Inspect subsequent progress: cancelling is not yet proof that original IO released. Uses current permission policy and never cancels unrelated transfers.", true, ref, "\"transfer_ref\""),
};
pub fn kind(name: []const u8) ?Kind {
    if (!std.mem.startsWith(u8, name, "host.")) return null;
    return std.meta.stringToEnum(Kind, name[5..]);
}
pub fn supports(name: []const u8) bool {
    return kind(name) != null;
}
pub fn mutates(k: Kind) bool {
    return k == .upload_file or k == .download_file or k == .cancel_transfer;
}
pub fn starts(k: Kind) bool {
    return k == .upload_file or k == .download_file;
}
pub fn waitSettled(progress: transfer.Progress) bool {
    if (progress.conflict_waiting or progress.state == .paused) return true;
    return (progress.state == .succeeded or progress.state == .failed or progress.state == .cancelled) and progress.job_cleanup == .released;
}
pub const Request = struct {
    kind: Kind,
    owner: ?identity.SessionHandle = null,
    source: []const u8 = "",
    destination: []const u8 = "",
    request_key: []const u8 = "",
    reference: []const u8 = "",
    wait_ms: u32 = 1000,
    pub fn direction(self: Request) transfer.Direction {
        return if (self.kind == .upload_file) .upload else .download;
    }
};
fn text(args: std.json.Value, name: []const u8, max: usize) ![]const u8 {
    const value = args.object.get(name) orelse return error.InvalidArguments;
    if (value != .string or value.string.len == 0 or value.string.len > max or !std.unicode.utf8ValidateSlice(value.string)) return error.InvalidArguments;
    for (value.string) |c| if (c < 0x20 or c == 0x7f) return error.InvalidArguments;
    return value.string;
}
fn absolute(value: []const u8) ![]const u8 {
    if (value.len > 4096 or !std.unicode.utf8ValidateSlice(value)) return error.InvalidArguments;
    for (value) |c| if (c < 0x20 or c == 0x7f) return error.InvalidArguments;
    if (!std.fs.path.isAbsolute(value)) return error.AbsolutePathRequired;
    return value;
}
pub fn parse(invocation: host.Invocation) !Request {
    try invocation.context.validate();
    const k = kind(invocation.tool_id) orelse return error.ToolNotAvailable;
    const expected: @import("provider.zig").ToolAuthority = if (mutates(k)) .lifecycle else .conversation_context;
    if (invocation.authority != expected or invocation.arguments != .object) return error.InvalidArguments;
    const allowed: []const []const u8 = switch (k) {
        .upload_file => &.{ "session_ref", "local_path", "remote_directory", "request_key" },
        .download_file => &.{ "session_ref", "remote_path", "local_directory", "request_key" },
        .get_transfer, .cancel_transfer => &.{"transfer_ref"},
        .wait_transfer => &.{ "transfer_ref", "wait_ms" },
    };
    for (invocation.arguments.object.keys()) |field| {
        for (allowed) |candidate| if (std.mem.eql(u8, field, candidate)) break else {} else return error.InvalidArguments;
    }
    var result: Request = .{ .kind = k };
    if (starts(k)) {
        result.owner = try @import("host_terminal_queries.zig").resolveSession(invocation.context, try text(invocation.arguments, "session_ref", 128));
        result.source = try absolute(try text(invocation.arguments, if (k == .upload_file) "local_path" else "remote_path", 4096));
        const target = if (k == .upload_file) "remote_directory" else "local_directory";
        if (k == .upload_file or invocation.arguments.object.contains(target)) result.destination = try absolute(try text(invocation.arguments, target, 4096));
        result.request_key = try text(invocation.arguments, "request_key", 128);
        for (result.request_key) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.' and c != ':') return error.InvalidArguments;
    } else {
        result.reference = try text(invocation.arguments, "transfer_ref", 128);
        _ = try operationId(invocation.context, result.reference);
        if (invocation.arguments.object.get("wait_ms")) |value| {
            if (value != .integer or value.integer < 0 or value.integer > 10000) return error.InvalidArguments;
            result.wait_ms = @intCast(value.integer);
        }
    }
    return result;
}
pub fn reference(a: std.mem.Allocator, context: host.Context, operation: identity.HostOperationId) ![]u8 {
    return std.fmt.allocPrint(a, "t1:{s}:{s}", .{ std.fmt.bytesToHex(context.conversation_id.bytes, .lower), std.fmt.bytesToHex(operation.bytes, .lower) });
}
pub fn operationId(context: host.Context, value: []const u8) !identity.HostOperationId {
    var parts = std.mem.splitScalar(u8, value, ':');
    if (!std.mem.eql(u8, parts.next() orelse "", "t1") or !std.mem.eql(u8, parts.next() orelse "", &std.fmt.bytesToHex(context.conversation_id.bytes, .lower))) return error.StaleReference;
    const id = identity.HostOperationId.parse(parts.next() orelse "") catch return error.StaleReference;
    if (parts.next() != null) return error.StaleReference;
    return id;
}
/// All callbacks run on the application controller. Submit uses the existing
/// queue; the worker neither accesses an SFTP session nor loads file contents.
pub const Backend = struct {
    context: *anyopaque,
    validate: *const fn (*anyopaque, host.Context, identity.SessionHandle, bool) anyerror!void,
    submit: *const fn (*anyopaque, Request) anyerror!transfer.JobId,
    progress: *const fn (*anyopaque, transfer.JobId) ?transfer.Progress,
    cancel: *const fn (*anyopaque, transfer.JobId) anyerror!void,
    downloadDirectory: *const fn (*anyopaque, std.mem.Allocator) anyerror![]u8,
};
pub const Prepared = struct {
    request: Request,
    detail: []u8,
    owned_destination: ?[]u8 = null,
    pub fn subject(self: Prepared) approval.Subject {
        var evidence: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(self.detail, &evidence, .{});
        return .{ .kind = .lifecycle, .target = switch (self.request.kind) {
            .upload_file => "host.upload_file",
            .download_file => "host.download_file",
            .cancel_transfer => "host.cancel_transfer",
            else => unreachable,
        }, .detail = self.detail, .impact = if (self.request.kind == .cancel_transfer) "取消原传输任务，并等待实际传输释放。" else "通过应用传输队列读写所列本机与远端路径；同名文件冲突沿用现有传输确认。", .evidence_hash = evidence };
    }
    pub fn deinit(self: *Prepared, a: std.mem.Allocator) void {
        a.free(self.detail);
        if (self.owned_destination) |value| a.free(value);
    }
};
pub const Entry = struct {
    context: host.Context,
    operation: identity.HostOperationId,
    owner: identity.SessionHandle,
    job: transfer.JobId,
    direction: transfer.Direction,
    source: []u8,
    destination: []u8,
    hash: [32]u8,
};
pub const Registry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    pub fn init(a: std.mem.Allocator) Registry {
        return .{ .allocator = a };
    }
    pub fn deinit(self: *Registry) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.source);
            self.allocator.free(entry.destination);
        }
        self.entries.deinit(self.allocator);
    }
    pub fn prepare(self: *Registry, invocation: host.Invocation, backend: Backend, a: std.mem.Allocator) !Prepared {
        var request = try parse(invocation);
        if (!mutates(request.kind)) return error.ToolNotAvailable;
        var owned: ?[]u8 = null;
        errdefer if (owned) |value| a.free(value);
        if (starts(request.kind)) {
            try backend.validate(backend.context, invocation.context, request.owner.?, true);
            if (request.destination.len == 0) {
                owned = try backend.downloadDirectory(backend.context, a);
                request.destination = try absolute(owned.?);
            }
        } else {
            const entry = try self.find(invocation.context, request.reference);
            try backend.validate(backend.context, invocation.context, entry.owner, false);
            request.owner = entry.owner;
            request.source = entry.source;
            request.destination = entry.destination;
        }
        const session_ref = if (request.owner) |owner| try @import("host_queries.zig").sessionRef(a, invocation.context, owner) else try a.dupe(u8, request.reference);
        defer a.free(session_ref);
        return .{ .request = request, .owned_destination = owned, .detail = try std.json.Stringify.valueAlloc(a, .{ .action = @tagName(request.kind), .target = session_ref, .transfer_ref = if (request.reference.len == 0) @as(?[]const u8, null) else request.reference, .source = request.source, .destination_directory = request.destination }, .{}) };
    }
    pub fn find(self: *Registry, context: host.Context, value: []const u8) !*Entry {
        const operation = try operationId(context, value);
        return self.byOperation(context, operation) orelse error.TransferUnavailable;
    }
    pub fn byOperation(self: *Registry, context: host.Context, operation: identity.HostOperationId) ?*Entry {
        for (self.entries.items) |*entry| if (entry.context.conversation_id.eql(context.conversation_id) and entry.operation.eql(operation)) return entry;
        return null;
    }
    pub fn submit(self: *Registry, invocation: host.Invocation, operation: identity.HostOperationId, prepared: Prepared, backend: Backend, a: std.mem.Allocator) !host.Result {
        const request = prepared.request;
        if (!starts(request.kind) or (invocation.approval_sequence orelse 0) == 0) return error.HostApprovalRequired;
        if (self.byOperation(invocation.context, operation)) |entry| {
            if (!std.mem.eql(u8, &entry.hash, &invocation.canonical_arguments_hash)) return error.IdempotencyConflict;
            return self.result(invocation, entry, backend, a, false);
        }
        try backend.validate(backend.context, invocation.context, request.owner.?, true);
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        const source = try self.allocator.dupe(u8, request.source);
        var owned = true;
        errdefer if (owned) self.allocator.free(source);
        const destination = try self.allocator.dupe(u8, request.destination);
        errdefer if (owned) self.allocator.free(destination);
        const job = try backend.submit(backend.context, request);
        self.entries.appendAssumeCapacity(.{ .context = invocation.context, .operation = operation, .owner = request.owner.?, .job = job, .direction = request.direction(), .source = source, .destination = destination, .hash = invocation.canonical_arguments_hash });
        owned = false; // Keep the accepted job indexed even if reply allocation fails.
        return self.result(invocation, &self.entries.items[self.entries.items.len - 1], backend, a, false);
    }
    pub fn query(self: *Registry, invocation: host.Invocation, backend: Backend, a: std.mem.Allocator, timed_out: bool) !host.Result {
        const request = try parse(invocation);
        if (request.kind != .get_transfer and request.kind != .wait_transfer) return error.ToolNotAvailable;
        return self.result(invocation, try self.find(invocation.context, request.reference), backend, a, timed_out);
    }
    pub fn cancel(self: *Registry, invocation: host.Invocation, backend: Backend, a: std.mem.Allocator) !host.Result {
        const request = try parse(invocation);
        if (request.kind != .cancel_transfer or (invocation.approval_sequence orelse 0) == 0) return error.HostApprovalRequired;
        const entry = try self.find(invocation.context, request.reference);
        try backend.validate(backend.context, invocation.context, entry.owner, false);
        try backend.cancel(backend.context, entry.job);
        return self.result(invocation, entry, backend, a, false);
    }
    pub fn result(self: *Registry, invocation: host.Invocation, entry: *const Entry, backend: Backend, a: std.mem.Allocator, timed_out: bool) !host.Result {
        _ = self;
        try backend.validate(backend.context, invocation.context, entry.owner, false);
        const progress = backend.progress(backend.context, entry.job) orelse return error.TransferUnavailable;
        const id = try reference(a, invocation.context, entry.operation);
        defer a.free(id);
        const owner = try @import("host_queries.zig").sessionRef(a, invocation.context, entry.owner);
        defer a.free(owner);
        const json = try std.json.Stringify.valueAlloc(a, .{ .transfer_ref = id, .session_ref = owner, .direction = entry.direction, .source = entry.source, .destination_directory = entry.destination, .state = progress.state, .done_bytes = progress.done_bytes, .total_bytes = progress.total_bytes, .speed_bps = progress.speed_bps, .failure = progress.failure, .job_cleanup = progress.job_cleanup, .conflict_waiting = progress.conflict_waiting, .skipped_files = progress.skipped_files, .skipped_bytes = progress.skipped_bytes, .verification = if (progress.verification) |v| @as(?@TypeOf(v.state), v.state) else null, .completed = progress.state == .succeeded and progress.job_cleanup == .released, .wait_timed_out = timed_out and !waitSettled(progress) }, .{});
        return jsonResult(invocation, a, json, .succeeded, false, mutates(kind(invocation.tool_id).?));
    }
};
pub fn jsonResult(invocation: host.Invocation, a: std.mem.Allocator, json: []u8, status: @import("plugin_tools.zig").Status, unknown: bool, started: bool) !host.Result {
    errdefer a.free(json);
    const blocks = try a.alloc(host.Block, 1);
    blocks[0] = .{ .structured = json };
    return .{ .status = status, .blocks = blocks, .receipt = .{ .conversation_id = invocation.context.conversation_id, .task_id = invocation.context.task_id, .operation_id = invocation.operation_id, .binding_revision = invocation.context.binding_revision, .local_released = true, .side_effect_started = started, .remote_effect_unknown = unknown } };
}
