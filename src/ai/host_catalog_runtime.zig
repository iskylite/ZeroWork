//! create_host reuses the process lifecycle journal. A repeated logical key
//! observes its original operation; it can never redispatch a possibly saved
//! asset. Only a succeeded record carries an asset identity for exact replay.
const std = @import("std");
const host = @import("host_tools.zig");
const catalog = @import("host_catalog.zig");
const journal = @import("lifecycle_journal.zig");
const references = @import("host_lifecycle.zig");
const ProcessJournal = @import("lifecycle_runtime.zig").ProcessJournal;
const hosts = @import("../config/hosts.zig");
const identity = hosts.identity;

pub const Operation = struct {
    owner: *ProcessJournal,
    handle: journal.Handle,
    record: journal.Record,

    pub fn deinit(self: *Operation, allocator: std.mem.Allocator) void {
        self.record.deinit(allocator);
        self.* = undefined;
    }
    pub fn dispatched(self: *Operation) !void {
        if (self.handle.reused) return error.OperationAlreadyStarted;
        try self.owner.update(self.handle, self.record.revision, .{ .stage = .dispatch_started, .local_released = false });
        self.record.stage = .dispatch_started;
        self.record.dispatch_started = true;
        self.record.local_released = false;
        self.record.revision += 1;
    }
    pub fn succeeded(self: *Operation, asset: identity.AssetOwner) !void {
        if (self.handle.reused or self.record.stage != .dispatch_started) return error.OperationAlreadyStarted;
        try self.owner.update(self.handle, self.record.revision, .{ .stage = .succeeded, .created_asset = asset, .local_released = true, .remote_effect_unknown = false });
        self.record.stage = .succeeded;
        self.record.created_asset = asset;
        self.record.local_released = true;
        self.record.revision += 1;
    }
    pub fn failed(self: *Operation, err: anyerror) !void {
        if (self.handle.reused) return error.OperationAlreadyStarted;
        const unknown = self.record.dispatch_started;
        const stage: journal.Stage = if (unknown) .outcome_unknown else if (err == error.ToolApprovalRejected) .rejected else if (err == error.CancelledBeforeDispatch) .cancelled_unsent else .failed;
        try self.owner.update(self.handle, self.record.revision, .{ .stage = stage, .local_released = !unknown, .remote_effect_unknown = unknown });
        self.record.stage = stage;
        self.record.local_released = !unknown;
        self.record.remote_effect_unknown = unknown;
        self.record.revision += 1;
    }
    /// Run this read-only projection on the main thread after validating the
    /// current context. Success requires the original saved revision to exist.
    pub fn replay(self: *const Operation, registry: *const hosts.Registry, invocation: host.Invocation, allocator: std.mem.Allocator) !host.Result {
        _ = try catalog.parse(invocation);
        if (!self.record.context.conversation_id.eql(invocation.context.conversation_id) or !self.record.context.task_id.eql(invocation.context.task_id)) return error.ScopeChanged;
        if (self.record.stage == .succeeded) {
            const asset = self.record.created_asset orelse return error.InvalidJournal;
            const value = registry.get(asset) catch return error.SourceChanged;
            return catalog.savedResult(allocator, invocation, value, self.record.operation_ref, true);
        }
        return self.failureResult(invocation, null, allocator);
    }
    /// The original operation remains authoritative even when a reply or a
    /// post-save journal update failed. No name/id inference or save retry.
    pub fn failureResult(self: *const Operation, invocation: host.Invocation, err: ?anyerror, allocator: std.mem.Allocator) !host.Result {
        const unknown = self.record.dispatch_started and self.record.stage != .succeeded and self.record.stage != .failed;
        const operation_ref = try references.operationRef(allocator, invocation.context, self.record.operation_ref);
        defer allocator.free(operation_ref);
        const code: ?[]const u8 = if (unknown) "OutcomeUnknown" else if (err) |failure| @errorName(failure) else if (self.record.stage == .prepared) "OperationBusy" else null;
        const json = try std.json.Stringify.valueAlloc(allocator, .{ .operation_ref = operation_ref, .state = if (unknown) "outcome_unknown" else @tagName(self.record.stage), .idempotent_reuse = self.handle.reused, .saved = @as(?bool, if (self.record.dispatch_started) null else false), .connection_started = false, .code = code, .recovery_hint = if (unknown) "Inspect this original operation and the saved catalog. Do not repeat the save or change the key/name to recover a reply." else "Use the original operation receipt." }, .{});
        errdefer allocator.free(json);
        const blocks = try allocator.alloc(host.Block, 1);
        blocks[0] = .{ .structured = json };
        return .{ .status = if (unknown) .outcome_unknown else if (self.record.stage == .rejected) .rejected else if (self.record.stage == .cancelled_unsent) .cancelled_unsent else .failed, .blocks = blocks, .receipt = .{ .conversation_id = invocation.context.conversation_id, .task_id = invocation.context.task_id, .operation_id = invocation.operation_id, .binding_revision = invocation.context.binding_revision, .side_effect_started = self.record.dispatch_started, .local_released = !unknown, .remote_effect_unknown = unknown } };
    }
};

pub fn begin(owner: *ProcessJournal, invocation: host.Invocation, allocator: std.mem.Allocator) !Operation {
    const request = try catalog.parse(invocation);
    if (request.kind != .create_host) return error.ToolNotAvailable;
    const canonical = try @import("canonical_arguments.zig").digest(allocator, invocation.arguments);
    if (!std.mem.eql(u8, &canonical, &invocation.canonical_arguments_hash)) return error.InvalidArguments;
    const handle = try owner.begin(.{ .context = invocation.context, .tool_id = invocation.tool_id, .request_key = request.request_key, .canonical_hash = canonical, .turn_id = invocation.turn_id, .call_id = invocation.call_id });
    return .{ .owner = owner, .handle = handle, .record = try owner.snapshot(allocator, handle) };
}

pub fn createdOwner(result: host.Result, context: host.Context) !identity.AssetOwner {
    if (result.status != .succeeded or result.blocks.len != 1 or result.blocks[0] != .structured) return error.InvalidControllerReceipt;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, result.blocks[0].structured, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidControllerReceipt;
    const value = parsed.value.object.get("host") orelse return error.InvalidControllerReceipt;
    if (value != .object) return error.InvalidControllerReceipt;
    const reference = value.object.get("source_ref") orelse return error.InvalidControllerReceipt;
    if (reference != .string) return error.InvalidControllerReceipt;
    return references.connectionOwner(context, reference.string);
}
