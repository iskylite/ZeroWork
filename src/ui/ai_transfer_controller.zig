//! All transfer/session access is marshalled to the controller. Journal IO,
//! approval waits and bounded progress waits stay on the AI worker.
const std = @import("std");
const transfers = @import("../ai/host_transfer.zig");
const runtime = @import("../ai/host_transfer_runtime.zig");
const host = @import("../ai/host_tools.zig");
const approval = @import("../ai/host_approval.zig");
const provider = @import("../ai/provider.zig");
const Bridge = @import("ai_tools.zig").Bridge;
pub const Access = struct {
    registry: *transfers.Registry,
    backend: transfers.Backend,
    approvals: *approval.Broker,
    journal: *@import("../ai/lifecycle_runtime.zig").ProcessJournal,
    policy_revision: u64,
    /// Validate current conversation even when a replay has no queue entry.
    validate_context: *const fn (*anyopaque, host.Context) anyerror!void,
};
const Exchange = struct {
    access: Access,
    invocation: host.Invocation,
    allocator: std.mem.Allocator,
    prepared: ?transfers.Prepared = null,
    permit: ?approval.Permit = null,
    operation: ?*runtime.Operation = null,
    result: ?host.Result = null,
    timed_out: bool = false,
    settled: bool = false,
    fn validate(self: *@This()) !void {
        try self.access.validate_context(self.access.backend.context, self.invocation.context);
    }
    fn preflight(raw: *anyopaque) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        try self.validate();
        self.prepared = try self.access.registry.prepare(self.invocation, self.access.backend, self.allocator);
    }
    fn replay(raw: *anyopaque) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        try self.validate();
        const operation = self.operation.?;
        if (self.access.registry.byOperation(self.invocation.context, operation.handle.operation_ref)) |entry| {
            self.result = try self.access.registry.result(self.invocation, entry, self.access.backend, self.allocator, false);
        } else self.result = try operation.failureResult(self.invocation, null, self.allocator);
    }
    fn dispatch(raw: *anyopaque) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        try self.validate();
        const subject = self.prepared.?.subject();
        if (self.access.approvals.authorizeSubject(self.permit.?, self.invocation, subject, self.access.policy_revision) != .allow) return error.ScopeChanged;
        var approved = self.invocation;
        approved.approval_sequence = self.permit.?.sequence;
        self.result = if (transfers.starts(self.prepared.?.request.kind)) try self.access.registry.submit(approved, self.operation.?.handle.operation_ref, self.prepared.?, self.access.backend, self.allocator) else try self.access.registry.cancel(approved, self.access.backend, self.allocator);
    }
    fn query(raw: *anyopaque) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        try self.validate();
        self.result = try self.access.registry.query(self.invocation, self.access.backend, self.allocator, self.timed_out);
        errdefer {
            self.result.?.deinit(self.allocator);
            self.result = null;
        }
        const request = try transfers.parse(self.invocation);
        const entry = try self.access.registry.find(self.invocation.context, request.reference);
        const progress = self.access.backend.progress(self.access.backend.context, entry.job) orelse return error.TransferUnavailable;
        self.settled = transfers.waitSettled(progress);
    }
};
pub fn execute(access: Access, bridge: *Bridge, invocation: host.Invocation, a: std.mem.Allocator, cancel: ?*provider.CancelToken) !host.Result {
    const request = try transfers.parse(invocation);
    var exchange: Exchange = .{ .access = access, .invocation = invocation, .allocator = a };
    defer if (exchange.prepared) |*prepared| prepared.deinit(a);
    if (!transfers.mutates(request.kind)) {
        const clock: @import("../ai/retry.zig").Clock = .{};
        const deadline = clock.now() + @as(i128, request.wait_ms) * std.time.ns_per_ms;
        while (true) {
            exchange.timed_out = request.kind == .wait_transfer and clock.now() >= deadline;
            try bridge.callController(&exchange, Exchange.query, cancel);
            if (request.kind == .get_transfer or exchange.settled or exchange.timed_out) return exchange.result orelse error.InvalidControllerReceipt;
            exchange.result.?.deinit(a);
            exchange.result = null;
            try @import("../ai/retry.zig").wait(@intCast(@min(100, @max(1, @divFloor(deadline - clock.now(), std.time.ns_per_ms)))), cancel);
        }
    }
    var operation: ?runtime.Operation = null;
    defer if (operation) |*value| value.deinit(a);
    if (transfers.starts(request.kind)) {
        operation = try runtime.begin(access.journal, invocation, a);
        exchange.operation = &operation.?;
        if (operation.?.handle.reused) {
            try bridge.callController(&exchange, Exchange.replay, cancel);
            return exchange.result orelse error.InvalidControllerReceipt;
        }
    }
    bridge.callController(&exchange, Exchange.preflight, cancel) catch |err| {
        if (operation) |*value| {
            try value.failed(err);
            return value.failureResult(invocation, err, a);
        }
        return err;
    };
    const permit = bridge.requestHostRoute(invocation, exchange.prepared.?.subject(), a, cancel) catch |err| {
        if (operation) |*value| {
            try value.failed(err);
            return value.failureResult(invocation, err, a);
        }
        return err;
    };
    defer access.approvals.finish(permit);
    exchange.permit = permit;
    if (operation) |*value| try value.dispatched();
    bridge.callController(&exchange, Exchange.dispatch, cancel) catch |err| {
        if (operation) |*value| {
            try value.failed(err);
            return value.failureResult(invocation, err, a);
        }
        return err;
    };
    var result = exchange.result orelse return error.InvalidControllerReceipt;
    if (operation) |*value| value.accepted() catch |err| {
        result.deinit(a);
        value.failed(err) catch {};
        return value.failureResult(invocation, err, a);
    };
    return result;
}
