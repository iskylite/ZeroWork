//! Controller-owned lifecycle metadata. Enqueue never closes a runtime or joins
//! an AI worker. ApplicationHost advances these operations at its safe point.
const std = @import("std");
const identity = @import("identity.zig");
const host_tools = @import("../ai/host_tools.zig");
const config = @import("../config/config.zig");
pub const Retention = config.SessionRetention;
pub const Ownership = @import("../ai/lifecycle_journal.zig").Ownership;
pub const ConnectionPolicy = enum { reuse_only, new_only, prefer_reuse };
pub const State = enum { queued, prepared, opening, ready, failed, failed_cleanup_pending, cancelled, closing, cleanup_pending, closed };
pub const OpenRequest = struct {
    operation_ref: identity.HostOperationId,
    context: host_tools.Context,
    group: identity.GroupOwner,
    source: ?identity.SessionHandle = null,
    saved_source: ?identity.AssetOwner = null,
    connection_policy: ConnectionPolicy,
    retention: Retention,
    allow_new_fallback: bool = false,
    membership_revision: ?u64 = null,
};
pub const Snapshot = struct {
    operation_ref: identity.HostOperationId,
    context: host_tools.Context,
    group: identity.GroupOwner,
    source: ?identity.SessionHandle = null,
    saved_source: ?identity.AssetOwner = null,
    session: ?identity.SessionHandle = null,
    state: State = .queued,
    revision: u64 = 1,
    ownership: Ownership = .created_task,
    ownership_revision: u64 = 1,
    retention: Retention,
    membership_committed: bool = false,
    error_code: ?[]const u8 = null,
    local_released: bool = true,
    remote_effect_unknown: bool = false,
    retention_decision_pending: bool = false,
    retention_blocked_reason: ?[]const u8 = null,
};
pub const Entry = struct {
    request: OpenRequest,
    snapshot: Snapshot,
    cancel_requested: bool = false,
    close_requested: bool = false,
    close_result_acknowledged: bool = false,
    close_ownership_revision: u64 = 0,
    close_requires_idle: bool = true,
    task_finished: bool = false,
    dispatch_permitted: bool = false,
};
/// Unknown is deliberately the default. Model completion/output silence do
/// not constitute shell idleness or a durable recording seal.
pub const IdleEvidence = struct {
    confirmed: bool = false,
    foreground_active: bool = true,
    background_jobs: bool = true,
    pending_input: bool = true,
    active_references: bool = true,
    recording_settled: bool = false,
    pub fn canClose(self: IdleEvidence) bool {
        return self.confirmed and !self.foreground_active and !self.background_jobs and !self.pending_input and !self.active_references and self.recording_settled;
    }
};
pub const FinishEvidence = struct {
    provider_finished: bool,
    pending_tool_slots: bool,
    pending_approval: bool,
    pending_dispatch: bool,
    executions_settled: bool,
    input_grants_released: bool,
    cleanup_transferred: bool,
    model_done: bool,
    remote_effect_unknown: bool = false,
    failed: bool = false,
    cancelled: bool = false,
    pending_external_jobs: usize = 0,
    pub fn valid(self: FinishEvidence) bool {
        return self.provider_finished and !self.pending_tool_slots and !self.pending_approval and !self.pending_dispatch and self.executions_settled and self.input_grants_released and self.cleanup_transferred;
    }
};
pub const TaskFinishReceipt = struct {
    task_id: identity.TaskId,
    finish_revision: u64,
    status: enum { completed, failed, cancelled, completed_with_handoff, completed_with_unknown },
    model_done: bool,
    owned_resources: usize,
    auto_idle_candidates: usize,
    retained_resources: usize,
    ask_resources: usize,
    pending_external_jobs: usize,
    remote_effect_unknown: bool,
};
pub const Supervisor = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    finish_revision: u64 = 1,
    pub fn init(allocator: std.mem.Allocator) Supervisor {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Supervisor) void {
        self.entries.deinit(self.allocator);
    }
    pub fn find(self: *Supervisor, operation: identity.HostOperationId) ?*Entry {
        for (self.entries.items) |*entry| if (entry.request.operation_ref.eql(operation)) return entry;
        return null;
    }
    pub fn resource(self: *Supervisor, handle: identity.SessionHandle) ?*Entry {
        for (self.entries.items) |*entry| if (entry.snapshot.session) |owner| if (owner.eql(handle)) return entry;
        return null;
    }
    pub fn enqueue(self: *Supervisor, request: OpenRequest) !Snapshot {
        try request.context.validate();
        if (!request.operation_ref.valid() or request.context.binding != .group or request.context.binding.group != @backingInt(request.group.id) or request.group.revision == 0 or (request.source == null) == (request.saved_source == null)) return error.InvalidHostAuthority;
        if (request.source) |source| if (@backingInt(source.session_id) == 0 or source.generation == 0) return error.InvalidHostAuthority;
        if (request.saved_source) |source| if (@backingInt(source.id) == 0 or source.revision == 0) return error.InvalidHostAuthority;
        if (self.find(request.operation_ref)) |entry| {
            if (!std.meta.eql(entry.request, request)) return error.IdempotencyConflict;
            return entry.snapshot;
        }
        if (self.entries.items.len >= 512) return error.ResourceLimit;
        const snapshot: Snapshot = .{ .operation_ref = request.operation_ref, .context = request.context, .group = request.group, .source = request.source, .saved_source = request.saved_source, .retention = request.retention };
        try self.entries.append(self.allocator, .{ .request = request, .snapshot = snapshot });
        return snapshot;
    }
    pub fn query(self: *Supervisor, operation: identity.HostOperationId, context: host_tools.Context) !Snapshot {
        const entry = self.find(operation) orelse return error.NotFound;
        if (!entry.request.context.conversation_id.eql(context.conversation_id) or !entry.request.context.task_id.eql(context.task_id)) return error.PermissionDenied;
        return entry.snapshot;
    }
    pub fn transition(entry: *Entry, state: State, failure: ?[]const u8) void {
        if (entry.snapshot.state == state and std.meta.eql(entry.snapshot.error_code, failure)) return;
        entry.snapshot.state = state;
        entry.snapshot.error_code = failure;
        entry.snapshot.revision +|= 1;
    }
    pub fn handedToUser(self: *Supervisor, handle: identity.SessionHandle) !void {
        const entry = self.resource(handle) orelse return; // Borrowed resources never acquire cleanup ownership.
        if (entry.snapshot.ownership == .handed_to_user) return;
        entry.snapshot.ownership_revision = try identity.advance(entry.snapshot.ownership_revision);
        entry.snapshot.ownership = .handed_to_user;
        entry.close_requested = false;
        entry.snapshot.retention_decision_pending = false;
        entry.snapshot.retention_blocked_reason = null;
        entry.snapshot.revision +|= 1;
    }
    pub fn setRetention(self: *Supervisor, handle: identity.SessionHandle, task: identity.TaskId, retention: Retention) !Snapshot {
        const entry = self.resource(handle) orelse return error.OwnershipChanged;
        if (!entry.request.context.task_id.eql(task) or entry.snapshot.ownership != .created_task) return error.OwnershipChanged;
        if (entry.snapshot.state == .closing or entry.snapshot.state == .closed) return error.AlreadyClosing;
        entry.snapshot.ownership_revision = try identity.advance(entry.snapshot.ownership_revision);
        entry.snapshot.retention = retention;
        entry.close_requested = false;
        entry.snapshot.retention_decision_pending = false;
        entry.snapshot.retention_blocked_reason = null;
        entry.snapshot.revision +|= 1;
        return entry.snapshot;
    }
    pub fn finishTask(self: *Supervisor, task: identity.TaskId, evidence: FinishEvidence) !TaskFinishReceipt {
        if (!task.valid()) return error.InvalidHostAuthority;
        if (!evidence.valid()) return error.TaskStillActive;
        for (self.entries.items) |entry| if (entry.request.context.task_id.eql(task)) switch (entry.snapshot.state) {
            .queued, .prepared, .opening => return error.TaskStillActive,
            else => {},
        };
        self.finish_revision = try identity.advance(self.finish_revision);
        var count: usize = 0;
        var automatic: usize = 0;
        var retained: usize = 0;
        var ask: usize = 0;
        var handed_off = false;
        var remote_unknown = evidence.remote_effect_unknown;
        for (self.entries.items) |*entry| if (entry.request.context.task_id.eql(task)) {
            entry.task_finished = true;
            handed_off = handed_off or entry.snapshot.ownership == .handed_to_user;
            remote_unknown = remote_unknown or entry.snapshot.remote_effect_unknown;
            const has_resource = entry.snapshot.session != null and entry.snapshot.state != .closed and entry.snapshot.state != .failed and entry.snapshot.state != .cancelled;
            if (entry.snapshot.ownership == .created_task and has_resource) {
                count += 1;
                entry.snapshot.retention_decision_pending = entry.snapshot.retention == .ask;
                if (entry.snapshot.state != .ready) {
                    retained += 1;
                } else {
                    switch (entry.snapshot.retention) {
                        .auto_idle => automatic += 1,
                        .ask => ask += 1,
                        .keep => retained += 1,
                    }
                }
            }
        };
        return .{ .task_id = task, .finish_revision = self.finish_revision, .status = if (evidence.cancelled) .cancelled else if (evidence.failed) .failed else if (remote_unknown) .completed_with_unknown else if (handed_off) .completed_with_handoff else .completed, .model_done = evidence.model_done, .owned_resources = count, .auto_idle_candidates = automatic, .retained_resources = retained, .ask_resources = ask, .pending_external_jobs = evidence.pending_external_jobs, .remote_effect_unknown = remote_unknown };
    }
    pub fn requestCleanup(self: *Supervisor, handle: identity.SessionHandle, task: identity.TaskId, evidence: IdleEvidence) !void {
        const entry = self.resource(handle) orelse return error.OwnershipChanged;
        if (!entry.request.context.task_id.eql(task) or entry.snapshot.ownership != .created_task) return error.OwnershipChanged;
        if (!entry.task_finished) return error.TaskStillActive;
        if (entry.snapshot.retention != .auto_idle) return error.CloseApprovalRequired;
        if (entry.snapshot.state != .ready) return error.BusyUnknown;
        if (!evidence.canClose()) return error.BusyUnknown;
        entry.close_requested = true;
        entry.close_requires_idle = true;
        entry.close_result_acknowledged = true;
        entry.close_ownership_revision = entry.snapshot.ownership_revision;
    }
};

test "owned lifecycle completion requires host evidence and takeover invalidates cleanup" {
    var supervisor = Supervisor.init(std.testing.allocator);
    defer supervisor.deinit();
    const task = identity.TaskId.generate();
    const request: OpenRequest = .{ .operation_ref = identity.HostOperationId.generate(), .context = .{ .conversation_id = identity.ConversationId.generate(), .task_id = task, .binding = .{ .group = 3 }, .binding_revision = 1, .grant_revision = 1 }, .group = .{ .id = @fromBackingInt(3) }, .source = .{ .session_id = @fromBackingInt(5) }, .connection_policy = .new_only, .retention = .auto_idle };
    _ = try supervisor.enqueue(request);
    _ = try supervisor.enqueue(request);
    try std.testing.expectEqual(@as(usize, 1), supervisor.entries.items.len);
    const entry = supervisor.find(request.operation_ref).?;
    const handle: identity.SessionHandle = .{ .session_id = @fromBackingInt(6) };
    entry.snapshot.session = handle;
    Supervisor.transition(entry, .ready, null);
    try std.testing.expectError(error.TaskStillActive, supervisor.requestCleanup(handle, task, .{}));
    _ = try supervisor.finishTask(task, .{ .provider_finished = true, .pending_tool_slots = false, .pending_approval = false, .pending_dispatch = false, .executions_settled = true, .input_grants_released = true, .cleanup_transferred = true, .model_done = true });
    try std.testing.expectError(error.BusyUnknown, supervisor.requestCleanup(handle, task, .{}));
    _ = try supervisor.setRetention(handle, task, .keep);
    try std.testing.expectError(error.CloseApprovalRequired, supervisor.requestCleanup(handle, task, .{}));
    _ = try supervisor.setRetention(handle, task, .ask);
    const asked = try supervisor.finishTask(task, .{ .provider_finished = true, .pending_tool_slots = false, .pending_approval = false, .pending_dispatch = false, .executions_settled = true, .input_grants_released = true, .cleanup_transferred = true, .model_done = true });
    try std.testing.expectEqual(@as(usize, 1), asked.ask_resources);
    try std.testing.expect(entry.snapshot.retention_decision_pending);
    try std.testing.expect(!entry.close_requested);
    _ = try supervisor.setRetention(handle, task, .auto_idle);
    try supervisor.requestCleanup(handle, task, .{ .confirmed = true, .foreground_active = false, .background_jobs = false, .pending_input = false, .active_references = false, .recording_settled = true });
    const revision = entry.snapshot.ownership_revision;
    try supervisor.handedToUser(handle);
    try std.testing.expect(entry.snapshot.ownership_revision > revision);
    try std.testing.expect(!entry.close_requested);
    try std.testing.expectError(error.OwnershipChanged, supervisor.requestCleanup(handle, task, .{}));
}
