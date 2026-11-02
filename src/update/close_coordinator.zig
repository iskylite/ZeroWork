//! Install intent can be revoked; an issued owner close cannot be revoked.
//! Receipts carry the original batch/owner/operation, never install permission.
const std = @import("std");
pub const Receipt = enum { awaiting, released, unknown };
pub const Work = struct { owner: u64, operation: ?u64 = null, receipt: Receipt = .awaiting };
pub const Coordinator = struct {
    batch: u64 = 0,
    generation: u64 = 0,
    intent: bool = false,
    snapshot_saved: bool = false,
    work: std.ArrayList(Work) = .empty,
    pub fn deinit(self: *Coordinator, allocator: std.mem.Allocator) void {
        self.work.deinit(allocator);
    }
    pub fn begin(self: *Coordinator, allocator: std.mem.Allocator, owners: []const u64) !void {
        // Keep issued work across cancel/retry; a new plan adopts the same closes.
        self.generation += 1;
        if (self.work.items.len == 0) self.batch += 1;
        for (owners) |owner| {
            var exists = false;
            for (self.work.items) |work| if (work.owner == owner) {
                exists = true;
                break;
            };
            if (!exists) try self.work.append(allocator, .{ .owner = owner });
        }
        self.intent = true;
        self.snapshot_saved = false;
    }
    pub fn saved(self: *Coordinator) void {
        if (self.intent) self.snapshot_saved = true;
    }
    pub fn next(self: *Coordinator) ?u64 {
        if (!self.intent or !self.snapshot_saved) return null;
        for (self.work.items) |work| if (work.operation != null and work.receipt != .released) return null;
        for (self.work.items) |work| if (work.operation == null and work.receipt != .released) return work.owner;
        return null;
    }
    /// An original owner may release itself while the confirmation is open.
    /// Observing physical release does not invent a close operation or intent.
    pub fn observeReleased(self: *Coordinator, owner: u64) void {
        for (self.work.items) |*work| if (work.owner == owner and work.operation == null) {
            work.receipt = .released;
            return;
        };
    }
    pub fn issued(self: *Coordinator, owner: u64, operation: u64) !void {
        if (!self.intent or !self.snapshot_saved) return error.InstallNotAuthorized;
        for (self.work.items) |*work| if (work.owner == owner) {
            if (work.operation != null) return error.AlreadyIssued;
            work.operation = operation;
            return;
        };
        return error.UnknownOwner;
    }
    pub fn receive(self: *Coordinator, batch: u64, owner: u64, operation: u64, receipt: Receipt) bool {
        if (batch != self.batch) return false;
        for (self.work.items) |*work| if (work.owner == owner and work.operation == operation) {
            if (work.receipt == .released) return receipt == .released;
            work.receipt = receipt;
            return true;
        };
        return false;
    }
    pub fn cancel(self: *Coordinator) void {
        self.intent = false;
        self.generation += 1;
    }
    pub fn draining(self: *const Coordinator) usize {
        var result: usize = 0;
        for (self.work.items) |work| if (work.operation != null and work.receipt != .released) {
            result += 1;
        };
        return result;
    }
    pub fn released(self: *const Coordinator) usize {
        var result: usize = 0;
        for (self.work.items) |work| if (work.receipt == .released) {
            result += 1;
        };
        return result;
    }
    pub fn canPrepare(self: *const Coordinator) bool {
        return self.intent and self.snapshot_saved and self.released() == self.work.items.len;
    }
};

test "update snapshot failure sends zero closes; cancel drains only issued owner; retry adopts original operation" {
    var c: Coordinator = .{};
    defer c.deinit(std.testing.allocator);
    try c.begin(std.testing.allocator, &.{ 1, 2 });
    try std.testing.expect(c.next() == null);
    c.cancel();
    try std.testing.expect(!c.canPrepare());
    try c.begin(std.testing.allocator, &.{ 1, 2 });
    c.saved();
    try std.testing.expectEqual(@as(?u64, 1), c.next());
    try c.issued(1, 91);
    c.cancel();
    try std.testing.expectEqual(@as(usize, 1), c.draining());
    try std.testing.expect(c.next() == null);
    try std.testing.expect(!c.receive(c.batch + 1, 1, 91, .released));
    try c.begin(std.testing.allocator, &.{ 1, 2 });
    c.saved();
    try std.testing.expect(c.next() == null);
    try std.testing.expect(c.receive(c.batch, 1, 91, .released));
    try std.testing.expectEqual(@as(?u64, 2), c.next());
    try std.testing.expectError(error.AlreadyIssued, c.issued(1, 92));
    c.cancel();
    try std.testing.expect(!c.canPrepare());
}
