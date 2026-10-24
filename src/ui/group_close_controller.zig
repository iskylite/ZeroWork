//! Frozen group-close approval and receipts. Resource teardown remains in the
//! V0.1.1 session coordinator; this module never closes a process or transport.
const std = @import("std");
const identity = @import("../host/identity.zig");
pub const MemberState = enum { queued, await_confirm, closing, closed, cancelled, failed, cleanup_unknown };
pub const ClosePhase = enum { confirming, closing, partial, complete };
pub const Impact = struct {
    command: u64 = 0,
    transfer: u64 = 0,
    ai: u64 = 0,
    socks: u64 = 0,
    unknown: u64 = 0,
    remote_effect_unknown: bool = false,
    detail: [512]u8 = @splat(0),
    detail_len: usize = 0,
    pub fn setDetail(self: *Impact, value: []const u8) void {
        var end = @min(value.len, self.detail.len);
        while (end > 0 and !std.unicode.utf8ValidateSlice(value[0..end])) end -= 1;
        @memcpy(self.detail[0..end], value[0..end]);
        self.detail_len = end;
    }
    pub fn detailText(self: *const Impact) []const u8 {
        return self.detail[0..self.detail_len];
    }
    pub fn eql(a: Impact, b: Impact) bool {
        return a.command == b.command and a.transfer == b.transfer and a.ai == b.ai and a.socks == b.socks and a.unknown == b.unknown and a.remote_effect_unknown == b.remote_effect_unknown;
    }
};
pub const Member = struct {
    id: u64,
    generation: u64,
    handle: ?identity.SessionHandle = null,
    risk: u8 = 0,
    impact: Impact = .{},
    display: [256]u8 = @splat(0),
    display_len: usize = 0,
    state: MemberState = .queued,
    remote_effect_unknown: bool = false,
    eligible: bool = true,
    pub fn label(self: *const Member) []const u8 {
        return self.display[0..self.display_len];
    }
    pub fn setLabel(self: *Member, value: []const u8) void {
        // Preserve valid UTF-8 when a long display identity exceeds the inline slot.
        var end = @min(value.len, self.display.len);
        while (end > 0 and !std.unicode.utf8ValidateSlice(value[0..end])) end -= 1;
        @memcpy(self.display[0..end], value[0..end]);
        self.display_len = end;
    }
};
var next_operation_id: u64 = 1;
fn issueOperation() !u64 {
    if (next_operation_id == std.math.maxInt(u64)) return error.CloseOperationExhausted;
    const value = next_operation_id;
    next_operation_id += 1;
    return value;
}
pub const Counts = struct { closed: usize = 0, unclosed: usize = 0, unknown: usize = 0 };
pub const Plan = struct {
    members: std.ArrayList(Member) = .empty,
    revision: u64 = 0,
    operation_id: u64 = 0,
    sequence: u64 = 0,
    cursor: usize = 0,
    closed: usize = 0,
    awaiting: ?u64 = null,
    phase: ClosePhase = .confirming,
    stop_requested: bool = false,
    group_hook_started: bool = false,
    retry: bool = false,
    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        self.members.deinit(allocator);
    }
    pub fn append(self: *Plan, allocator: std.mem.Allocator, member: Member) !void {
        if (self.operation_id == 0) self.operation_id = try issueOperation();
        for (self.members.items) |old| if (old.id == member.id) return;
        try self.members.append(allocator, member);
    }
    pub fn counts(self: *const Plan) Counts {
        var result: Counts = .{};
        for (self.members.items) |member| {
            if (member.state == .closed) result.closed += 1 else result.unclosed += 1;
            if (member.state == .cleanup_unknown or member.remote_effect_unknown) result.unknown += 1;
        }
        return result;
    }
    pub fn record(self: *Plan, id: u64, state: MemberState) bool {
        for (self.members.items) |*member| if (member.id == id) {
            if (member.state == .closed and state != .closed) return false;
            if (member.state == state) return false;
            member.state = state;
            self.sequence +|= 1;
            self.closed = self.counts().closed;
            return true;
        };
        return false;
    }
    /// Cancel before approval has no resource effect. During execution, never
    /// abandon the in-flight request: stop only queued targets and keep polling.
    pub fn stop(self: *Plan) void {
        self.stop_requested = true;
        for (self.members.items) |*member| if (member.state == .queued) {
            member.state = .cancelled;
        };
        self.phase = .partial;
    }
    /// Original failed/cancelled targets only. Closed and cleanup_unknown
    /// receipts survive and cannot be resubmitted as parallel closes.
    pub fn prepareRetry(self: *Plan, revision: u64) !void {
        for (self.members.items) |member| if (member.state == .closing or member.state == .await_confirm or member.state == .cleanup_unknown) return error.CloseReceiptPending;
        const retry_operation = try issueOperation();
        var count: usize = 0;
        for (self.members.items) |*member| {
            member.eligible = member.state == .failed or member.state == .cancelled;
            if (member.eligible) {
                member.state = .queued;
                count += 1;
            }
        }
        if (count == 0) return error.NoRetryableMembers;
        self.revision = revision;
        self.operation_id = retry_operation;
        self.cursor = 0;
        self.awaiting = null;
        self.stop_requested = false;
        self.group_hook_started = false;
        self.phase = .confirming;
        self.retry = true;
    }
    pub fn next(self: *Plan) ?*Member {
        if (self.stop_requested) return null;
        while (self.cursor < self.members.items.len) {
            const index = self.cursor;
            self.cursor += 1;
            const member = &self.members.items[index];
            if (member.eligible and member.state == .queued) return member;
        }
        return null;
    }
    pub fn approvalCount(self: *const Plan) usize {
        var count: usize = 0;
        for (self.members.items) |member| if (member.eligible and member.state == .queued) {
            count += 1;
        };
        return count;
    }
};

test "receipt ledger keeps successful targets and retries only original failures" {
    var plan: Plan = .{};
    defer plan.deinit(std.testing.allocator);
    try plan.append(std.testing.allocator, .{ .id = 101, .generation = 1 });
    try plan.append(std.testing.allocator, .{ .id = 102, .generation = 1 });
    try plan.append(std.testing.allocator, .{ .id = 101, .generation = 1 });
    try std.testing.expectEqual(@as(usize, 2), plan.members.items.len);
    _ = plan.record(101, .closed);
    _ = plan.record(102, .failed);
    try plan.prepareRetry(5);
    try std.testing.expectEqual(@as(u64, 102), plan.next().?.id);
    try std.testing.expect(plan.next() == null);
    try std.testing.expectEqual(@as(usize, 1), plan.counts().closed);
    try std.testing.expect(!plan.record(101, .failed));
}
test "cleanup unknown preserves the original close request and blocks retry" {
    var plan: Plan = .{};
    defer plan.deinit(std.testing.allocator);
    try plan.append(std.testing.allocator, .{ .id = 101, .generation = 1 });
    _ = plan.record(101, .cleanup_unknown);
    try std.testing.expectError(error.CloseReceiptPending, plan.prepareRetry(2));
    plan.stop();
    try std.testing.expectEqual(MemberState.cleanup_unknown, plan.members.items[0].state);
    try std.testing.expectEqual(@as(usize, 1), plan.counts().unknown);
}
test "stop cancels only unstarted targets and fingerprint detects same-kind new work" {
    var plan: Plan = .{};
    defer plan.deinit(std.testing.allocator);
    try plan.append(std.testing.allocator, .{ .id = 101, .generation = 1, .state = .closing });
    try plan.append(std.testing.allocator, .{ .id = 102, .generation = 1 });
    plan.stop();
    try std.testing.expectEqual(MemberState.closing, plan.members.items[0].state);
    try std.testing.expectEqual(MemberState.cancelled, plan.members.items[1].state);
    try std.testing.expect(!Impact.eql(.{ .command = 101 }, .{ .command = 102 }));
}

test "retry operation renews the once-per-operation group stop hook gate" {
    var plan: Plan = .{};
    defer plan.deinit(std.testing.allocator);
    try plan.append(std.testing.allocator, .{ .id = 101, .generation = 1 });
    const original_operation = plan.operation_id;
    plan.group_hook_started = true; // Original accepted operation already stopped its group.
    _ = plan.record(101, .failed);
    try plan.prepareRetry(2);
    try std.testing.expect(plan.operation_id != original_operation);
    try std.testing.expect(!plan.group_hook_started);
    // The existing workspace acceptance guard claims this flag before calling
    // the application. Repeated acceptance cannot claim the same operation.
    var hook_calls: usize = 0;
    for (0..2) |_| {
        if (!plan.group_hook_started) {
            plan.group_hook_started = true;
            hook_calls += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), hook_calls);
    _ = plan.record(101, .failed);
    try plan.prepareRetry(3);
    try std.testing.expect(!plan.group_hook_started);
}

test "remote effect fact changes the frozen impact even after AI stops" {
    try std.testing.expect(!Impact.eql(.{}, .{ .remote_effect_unknown = true }));
    try std.testing.expect(Impact.eql(.{ .remote_effect_unknown = true }, .{ .remote_effect_unknown = true }));
}
