//! Durable submission intent. A replay observes the original queue entry and
//! never dispatches again, including after a crash between enqueue and reply.
const std = @import("std");
const host = @import("host_tools.zig");
const transfers = @import("host_transfer.zig");
const journal = @import("lifecycle_journal.zig");
const ProcessJournal = @import("lifecycle_runtime.zig").ProcessJournal;
pub const Operation = struct {
    owner: *ProcessJournal,
    handle: journal.Handle,
    record: journal.Record,
    pub fn deinit(self: *Operation, a: std.mem.Allocator) void {
        self.record.deinit(a);
    }
    pub fn dispatched(self: *Operation) !void {
        if (self.handle.reused) return error.OperationAlreadyStarted;
        try self.owner.update(self.handle, self.record.revision, .{ .stage = .dispatch_started, .local_released = false });
        self.record.stage = .dispatch_started;
        self.record.dispatch_started = true;
        self.record.local_released = false;
        self.record.revision += 1;
    }
    /// This records queue acceptance only; completion is queried from Manager.
    pub fn accepted(self: *Operation) !void {
        if (self.handle.reused or self.record.stage != .dispatch_started) return error.OperationAlreadyStarted;
        try self.owner.update(self.handle, self.record.revision, .{ .stage = .succeeded });
        self.record.stage = .succeeded;
        self.record.local_released = true;
        self.record.revision += 1;
    }
    pub fn failed(self: *Operation, err: anyerror) !void {
        if (self.handle.reused) return error.OperationAlreadyStarted;
        const unknown = self.record.dispatch_started;
        const stage: journal.Stage = if (unknown) .outcome_unknown else if (err == error.ToolApprovalRejected) .rejected else if (err == error.CancelledBeforeDispatch) .cancelled_unsent else .failed;
        try self.owner.update(self.handle, self.record.revision, .{ .stage = stage, .local_released = !unknown, .remote_effect_unknown = unknown });
        self.record.stage = stage;
        self.record.remote_effect_unknown = unknown;
        self.record.revision += 1;
    }
    pub fn failureResult(self: *const Operation, invocation: host.Invocation, err: ?anyerror, a: std.mem.Allocator) !host.Result {
        // A missing in-memory queue index after restart cannot prove release or
        // completion, even when queue acceptance was durably recorded.
        const unknown = self.record.dispatch_started;
        const reference = try transfers.reference(a, invocation.context, self.handle.operation_ref);
        defer a.free(reference);
        const json = try std.json.Stringify.valueAlloc(a, .{ .transfer_ref = reference, .state = if (unknown) "outcome_unknown" else @tagName(self.record.stage), .idempotent_reuse = self.handle.reused, .completed = false, .submitted = @as(?bool, if (self.record.stage == .succeeded) true else if (unknown) null else false), .code = if (err) |failure| @as(?[]const u8, @errorName(failure)) else null, .recovery_hint = if (unknown) "Inspect the original transfer in the transfer manager. Never resubmit under a new key to recover a lost reply." else "This request was not dispatched; inspect the original receipt." }, .{});
        return transfers.jsonResult(invocation, a, json, if (unknown) .outcome_unknown else if (self.record.stage == .rejected) .rejected else if (self.record.stage == .cancelled_unsent) .cancelled_unsent else .failed, unknown, self.record.dispatch_started);
    }
};
pub fn begin(owner: *ProcessJournal, invocation: host.Invocation, a: std.mem.Allocator) !Operation {
    const request = try transfers.parse(invocation);
    if (!transfers.starts(request.kind)) return error.ToolNotAvailable;
    const hash = try @import("canonical_arguments.zig").digest(a, invocation.arguments);
    if (!std.mem.eql(u8, &hash, &invocation.canonical_arguments_hash)) return error.InvalidArguments;
    const handle = try owner.begin(.{ .context = invocation.context, .tool_id = invocation.tool_id, .request_key = request.request_key, .canonical_hash = hash, .turn_id = invocation.turn_id, .call_id = invocation.call_id });
    return .{ .owner = owner, .handle = handle, .record = try owner.snapshot(a, handle) };
}
