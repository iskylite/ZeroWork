//! Main-thread receipts for explicitly accepted disconnects. These records own
//! no native resource: the original runtime retains ownership until its exact
//! create operation publishes an actual cleanup receipt.
const std = @import("std");
const identity = @import("../host/identity.zig");
const host = @import("../ai/host_tools.zig");
const operation = @import("../host/operation.zig");
pub const Receipt = @import("../proto/ssh/session.zig").ReleaseReceipt;
pub const max_operations = 512;
pub const cleanup_timeout_ns = 5 * std.time.ns_per_s;
pub const Request = struct {
    operation_ref: identity.HostOperationId,
    context: host.Context,
    session: identity.SessionHandle,
    create_operation: operation.OperationKey,
    binding: @import("../host/session_host.zig").ServiceHandle,
    impact_revision: u64,
};
pub const Snapshot = struct {
    operation_ref: identity.HostOperationId,
    session: identity.SessionHandle,
    state: enum { pending, disconnected, outcome_unknown } = .pending,
    revision: u64 = 1,
    local_released: bool = false,
    remote_effect_unknown: bool = false,
    error_code: ?[]const u8 = null,
};
pub const Entry = struct {
    request: Request,
    snapshot: Snapshot,
    deadline_ns: i128,
    pub fn observe(self: *Entry, create_operation: operation.OperationKey, receipt: Receipt, now_ns: i128) !void {
        if (!self.request.create_operation.eql(create_operation)) return error.StaleCreateOperation;
        if (self.snapshot.state == .disconnected) return;
        const state: @FieldType(Snapshot, "state") = switch (receipt) {
            .released => .disconnected,
            .awaiting => if (self.snapshot.state == .outcome_unknown or now_ns >= self.deadline_ns) .outcome_unknown else .pending,
            .unknown => .outcome_unknown,
        };
        const code: ?[]const u8 = if (receipt == .unknown) "DisconnectCleanupUnknown" else if (state == .outcome_unknown) "DisconnectCleanupTimeout" else null;
        if (state == self.snapshot.state and std.meta.eql(code, self.snapshot.error_code)) return;
        self.snapshot.state = state;
        self.snapshot.local_released = receipt == .released;
        self.snapshot.remote_effect_unknown = state == .outcome_unknown;
        self.snapshot.error_code = code;
        self.snapshot.revision = try identity.advance(self.snapshot.revision);
    }
};
pub const Ledger = struct {
    entries: std.ArrayList(Entry) = .empty,
    pub fn deinit(self: *Ledger, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }
    pub fn find(self: *Ledger, operation_ref: identity.HostOperationId, context: host.Context) !*Entry {
        for (self.entries.items) |*entry| if (entry.request.operation_ref.eql(operation_ref)) {
            if (!entry.request.context.eql(context)) return error.ScopeChanged;
            return entry;
        };
        return error.NotFound;
    }
    /// All storage is reserved before the protocol enqueue. A repeated token
    /// returns the same receipt and must never enqueue another disconnect.
    pub fn prepare(self: *Ledger, allocator: std.mem.Allocator, request: Request, now_ns: i128) !struct { entry: *Entry, fresh: bool } {
        try request.context.validate();
        if (!request.operation_ref.valid() or @backingInt(request.session.session_id) == 0 or request.session.generation == 0 or request.create_operation.operation_id == 0 or !request.create_operation.owner.eql(.{ .session = request.session }) or request.binding.kind != .terminal or request.binding.binding_id == 0 or request.binding.binding_generation == 0 or !request.binding.resource_owner.eql(.{ .session = request.session })) return error.InvalidDisconnectIdentity;
        if (request.binding.origin_session) |origin| if (!origin.eql(request.session)) return error.InvalidDisconnectIdentity;
        for (self.entries.items) |*entry| if (entry.request.operation_ref.eql(request.operation_ref)) {
            if (!std.meta.eql(entry.request, request)) return error.ScopeChanged;
            return .{ .entry = entry, .fresh = false };
        };
        if (self.entries.items.len >= max_operations) return error.DisconnectOperationLimit;
        try self.entries.append(allocator, .{ .request = request, .snapshot = .{ .operation_ref = request.operation_ref, .session = request.session }, .deadline_ns = now_ns + cleanup_timeout_ns });
        return .{ .entry = &self.entries.items[self.entries.items.len - 1], .fresh = true };
    }
    /// Only legal before the runtime accepted any work.
    pub fn rejectPrepared(self: *Ledger, operation_ref: identity.HostOperationId) void {
        for (self.entries.items, 0..) |entry, index| if (entry.request.operation_ref.eql(operation_ref)) {
            _ = self.entries.orderedRemove(index);
            return;
        };
    }
};

test "disconnect ledger binds exact create and scope and never duplicates an accepted token" {
    const a = std.testing.allocator;
    var ledger: Ledger = .{};
    defer ledger.deinit(a);
    const session: identity.SessionHandle = .{ .session_id = @fromBackingInt(101), .generation = 2 };
    const context: host.Context = .{ .conversation_id = .generate(), .task_id = .generate(), .binding = .{ .session = 101 }, .binding_revision = 1, .grant_revision = 1 };
    const request: Request = .{ .operation_ref = .generate(), .context = context, .session = session, .create_operation = .{ .owner = .{ .session = session }, .operation_id = 3, .attempt_id = 2 }, .binding = .{ .resource_owner = .{ .session = session }, .kind = .terminal, .binding_id = 1, .binding_generation = 1 }, .impact_revision = 1 };
    const first = try ledger.prepare(a, request, 0);
    try std.testing.expect(first.fresh);
    const same = try ledger.prepare(a, request, 1);
    try std.testing.expect(!same.fresh);
    try std.testing.expectEqual(@as(usize, 1), ledger.entries.items.len);
    var changed = request;
    changed.context.grant_revision += 1;
    try std.testing.expectError(error.ScopeChanged, ledger.prepare(a, changed, 2));
    var wrong = request.create_operation;
    wrong.attempt_id = 3;
    try std.testing.expectError(error.StaleCreateOperation, first.entry.observe(wrong, .released, 3));
    try std.testing.expectEqual(@FieldType(Snapshot, "state").pending, first.entry.snapshot.state);
    try first.entry.observe(request.create_operation, .awaiting, cleanup_timeout_ns);
    try std.testing.expectEqual(@FieldType(Snapshot, "state").outcome_unknown, first.entry.snapshot.state);
    try std.testing.expect(!first.entry.snapshot.local_released);
    // The original owner may later provide a real receipt; no redispatch.
    try first.entry.observe(request.create_operation, .released, cleanup_timeout_ns + 1);
    try std.testing.expectEqual(@FieldType(Snapshot, "state").disconnected, first.entry.snapshot.state);
    try std.testing.expect(first.entry.snapshot.local_released);
}
