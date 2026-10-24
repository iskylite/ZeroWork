//! Runtime approval: stable handles and membership epochs, never a live fan-out.
const std = @import("std");
const Handle = @import("../host/identity.zig").SessionHandle;
pub const Fact = struct {
    handle: Handle,
    membership_revision: u64,
    writable: bool = true,
    mode_revision: u64 = 1,
    input_revision: u64 = 0,
    capability_revision: u64 = 1,
    pub fn same(self: Fact, other: Fact) bool {
        return self.handle.eql(other.handle) and self.membership_revision == other.membership_revision and self.capability_revision == other.capability_revision;
    }
};
pub const Target = struct { fact: Fact, last_event: u64 = 0, result: enum { skipped, accepted, failed } = .skipped };
pub const Approval = struct {
    group_id: u32,
    group_revision: u64,
    source: Fact,
    targets: []Target,
    enabled: bool = false,
    pub fn deinit(self: *Approval, allocator: std.mem.Allocator) void {
        allocator.free(self.targets);
    }
    pub fn approve(self: *Approval, revision: u64, facts: []const Fact) !void {
        if (self.enabled) return;
        if (revision != self.group_revision or !valid(self.source, facts)) return error.StaleApproval;
        for (self.targets) |target| if (!valid(target.fact, facts)) return error.StaleApproval;
        if (self.targets.len == 0) return error.NoRecipients;
        self.enabled = true;
    }
    pub fn valid(fact: Fact, facts: []const Fact) bool {
        for (facts) |live| if (fact.same(live) and live.writable) return true;
        return false;
    }
    pub fn effective(self: *const Approval, facts: []const Fact) usize {
        var count: usize = 0;
        for (self.targets) |target| if (valid(target.fact, facts)) {
            count += 1;
        };
        return count;
    }
    pub fn dispatch(self: *Approval, source: Fact, event: u64, facts: []const Fact, context: *anyopaque, send: *const fn (*anyopaque, Handle) anyerror!void) !void {
        if (!self.enabled or event == 0) return;
        if (!self.source.same(source) or !valid(self.source, facts)) return error.StaleSource;
        var failure: ?anyerror = null;
        for (self.targets) |*target| {
            if (event <= target.last_event) continue;
            target.last_event = event;
            target.result = .skipped;
            if (!valid(target.fact, facts)) continue;
            send(context, target.fact.handle) catch |err| {
                target.result = .failed;
                if (failure == null) failure = err;
                continue;
            };
            target.result = .accepted;
        }
        if (failure) |err| return err;
    }
};
pub fn prepare(allocator: std.mem.Allocator, group: u32, revision: u64, source: Fact, facts: []const Fact) !Approval {
    if (!Approval.valid(source, facts)) return error.InvalidSource;
    var targets: std.ArrayList(Target) = .empty;
    errdefer targets.deinit(allocator);
    for (facts) |fact| {
        if (fact.handle.session_id == source.handle.session_id or !fact.writable) continue;
        try targets.append(allocator, .{ .fact = fact });
    }
    return .{ .group_id = group, .group_revision = revision, .source = source, .targets = try targets.toOwnedSlice(allocator) };
}
test "approval excludes new members reconnects rejoin and duplicate events; zero targets remains on" {
    const a: Fact = .{ .handle = .{ .session_id = @fromBackingInt(1) }, .membership_revision = 1 };
    const b: Fact = .{ .handle = .{ .session_id = @fromBackingInt(2) }, .membership_revision = 2 };
    var approval = try prepare(std.testing.allocator, 7, 2, a, &.{ a, b });
    defer approval.deinit(std.testing.allocator);
    try std.testing.expectError(error.StaleApproval, approval.approve(3, &.{ a, b }));
    try approval.approve(2, &.{ a, b });
    const Fake = struct {
        count: usize = 0,
        fn send(raw: *anyopaque, _: Handle) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.count += 1;
        }
    };
    var fake: Fake = .{};
    var c = b;
    c.handle.session_id = @fromBackingInt(3);
    try approval.dispatch(a, 1, &.{ a, b, c }, &fake, Fake.send);
    try approval.dispatch(a, 1, &.{ a, b, c }, &fake, Fake.send);
    try std.testing.expectEqual(@as(usize, 1), fake.count);
    var reconnect = b;
    reconnect.handle.generation += 1;
    try approval.dispatch(a, 2, &.{ a, reconnect, c }, &fake, Fake.send);
    var rejoin = b;
    rejoin.membership_revision += 1;
    try approval.dispatch(a, 3, &.{ a, rejoin, c }, &fake, Fake.send);
    try std.testing.expectEqual(@as(usize, 1), fake.count);
    try std.testing.expect(approval.enabled);
    try std.testing.expectEqual(@as(usize, 0), approval.effective(&.{ a, reconnect }));
}

test "recipient failure does not suppress healthy targets and skipped events never replay" {
    const source: Fact = .{ .handle = .{ .session_id = @fromBackingInt(100) }, .membership_revision = 1 };
    var facts: [301]Fact = undefined;
    facts[0] = source;
    for (facts[1..], 0..) |*fact, index| fact.* = .{ .handle = .{ .session_id = @fromBackingInt(200 + index) }, .membership_revision = 2 + index };
    var approval = try prepare(std.testing.allocator, 7, 2, source, &facts);
    defer approval.deinit(std.testing.allocator);
    try approval.approve(2, &facts);
    const Fake = struct {
        count: usize = 0,
        fn send(raw: *anyopaque, handle: Handle) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.count += 1;
            if (@backingInt(handle.session_id) == 200) return error.InputFull;
        }
    };
    var fake: Fake = .{};
    facts[2].writable = false;
    try std.testing.expectError(error.InputFull, approval.dispatch(source, 1, &facts, &fake, Fake.send));
    try std.testing.expectEqual(@as(usize, 299), fake.count);
    try std.testing.expectEqual(.failed, approval.targets[0].result);
    try std.testing.expectEqual(.skipped, approval.targets[1].result);
    try std.testing.expectEqual(.accepted, approval.targets[2].result);
    facts[2].writable = true;
    try approval.dispatch(source, 1, &facts, &fake, Fake.send);
    try std.testing.expectEqual(@as(usize, 299), fake.count);
    var replacement = source;
    replacement.handle.generation += 1;
    try std.testing.expectError(error.StaleSource, approval.dispatch(replacement, 2, &facts, &fake, Fake.send));
}
