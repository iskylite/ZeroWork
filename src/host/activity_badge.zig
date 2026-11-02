//! Quiet, process-wide background session markers, independent of system
//! notification permission and policy. Content and AI share the same owner.
const std = @import("std");
const identity = @import("identity.zig");
const terminal = @import("terminal_service.zig");
const Entry = struct {
    owner: identity.ContentOwner,
    token: u64,
    ai_operation: ?u64 = null,
    pending: bool = false,
    initialized: bool = false,
    output_sequence: u64 = 0,
    eof: bool = false,
};
const AiReceipt = struct { owner: identity.ContentOwner, operation: u64, turn: u64 };
pub const Tracker = struct {
    allocator: std.mem.Allocator,
    background: bool = false,
    revision: u64 = 0,
    next_token: u64 = 3,
    entries: std.ArrayList(Entry) = .empty,
    ai_receipts: std.ArrayList(AiReceipt) = .empty,
    pub fn deinit(self: *Tracker) void {
        self.entries.deinit(self.allocator);
        self.ai_receipts.deinit(self.allocator);
    }
    fn entry(self: *Tracker, owner: identity.ContentOwner) !*Entry {
        for (self.entries.items) |*item| if (item.owner.eql(owner)) return item;
        if (self.next_token == std.math.maxInt(u64)) return error.ActivityIdentityExhausted;
        try self.entries.append(self.allocator, .{ .owner = owner, .token = self.next_token });
        self.next_token += 1;
        return &self.entries.items[self.entries.items.len - 1];
    }
    pub fn setForeground(self: *Tracker, foreground: bool) void {
        self.background = !foreground;
        if (foreground) self.clear();
    }
    pub fn observeTerminal(self: *Tracker, facts: terminal.NotificationSnapshot) !void {
        const item = try self.entry(.{ .session = facts.owner });
        if (item.initialized and self.background and
            (facts.output_sequence > item.output_sequence or (facts.eof_seen and !item.eof)))
        {
            if (!item.pending or item.ai_operation != null) self.revision +%= 1;
            item.pending = true;
            item.ai_operation = null;
        }
        item.initialized = true;
        item.output_sequence = facts.output_sequence;
        item.eof = facts.eof_seen;
    }
    pub fn observeAi(self: *Tracker, owner: identity.ContentOwner, operation: u64, turn: u64) !void {
        const item = try self.entry(owner);
        for (self.ai_receipts.items) |*receipt| if (receipt.operation == operation) {
            if (turn <= receipt.turn) return;
            receipt.turn = turn;
            if (self.background) {
                item.pending = true;
                item.ai_operation = operation;
                self.revision +%= 1;
            }
            return;
        };
        try self.ai_receipts.append(self.allocator, .{ .owner = owner, .operation = operation, .turn = turn });
        if (self.background) {
            item.pending = true;
            item.ai_operation = operation;
            self.revision +%= 1;
        }
    }
    pub fn remove(self: *Tracker, owner: identity.ContentOwner) void {
        for (self.entries.items, 0..) |item, i| if (item.owner.eql(owner)) {
            _ = self.entries.orderedRemove(i);
            self.revision +%= 1;
            break;
        };
        var i: usize = 0;
        while (i < self.ai_receipts.items.len) {
            if (self.ai_receipts.items[i].owner.eql(owner)) _ = self.ai_receipts.orderedRemove(i) else i += 1;
        }
    }
    pub fn clear(self: *Tracker) void {
        // Preserve observed facts so returning to the background cannot replay
        // old output or completion receipts.
        for (self.entries.items) |*item| if (item.pending) {
            item.pending = false;
            self.revision +%= 1;
        };
    }
    pub fn count(self: *const Tracker) u64 {
        var total: u64 = 0;
        for (self.entries.items) |item| total += @intFromBool(item.pending);
        return total;
    }
};

test "activity badge merges content and AI by session and clears on foreground" {
    var tracker: Tracker = .{ .allocator = std.testing.allocator };
    defer tracker.deinit();
    const first: identity.SessionHandle = .{ .session_id = @fromBackingInt(1), .generation = 1 };
    const second: identity.SessionHandle = .{ .session_id = @fromBackingInt(2), .generation = 1 };
    var facts: terminal.NotificationSnapshot = .{ .owner = first, .output_sequence = 0, .bell_count = 0 };
    try tracker.observeTerminal(facts);
    tracker.setForeground(false);
    facts.output_sequence = 1;
    try tracker.observeTerminal(facts);
    facts.output_sequence = 3;
    try tracker.observeTerminal(facts);
    try tracker.observeAi(.{ .session = first }, 1, 1);
    try tracker.observeAi(.{ .session = first }, 2, 1);
    try std.testing.expectEqual(@as(u64, 1), tracker.count());
    try tracker.observeAi(.{ .session = second }, 3, 1);
    try std.testing.expectEqual(@as(u64, 2), tracker.count());
    tracker.setForeground(true);
    try std.testing.expectEqual(@as(u64, 0), tracker.count());
    facts.output_sequence = 4;
    try tracker.observeTerminal(facts);
    tracker.setForeground(false);
    try tracker.observeTerminal(facts);
    try tracker.observeAi(.{ .session = first }, 2, 1);
    try std.testing.expectEqual(@as(u64, 0), tracker.count());
    // An older operation completing after a newer one is still new activity.
    try tracker.observeAi(.{ .session = first }, 1, 2);
    try tracker.observeAi(.{ .session = second }, 4, 1);
    try std.testing.expectEqual(@as(u64, 2), tracker.count());
    tracker.remove(.{ .session = first });
    try std.testing.expectEqual(@as(u64, 1), tracker.count());
}

test "activity badge ignores historical baseline but detects session end without new output" {
    var tracker: Tracker = .{ .allocator = std.testing.allocator };
    defer tracker.deinit();
    tracker.setForeground(false);
    var facts: terminal.NotificationSnapshot = .{ .owner = .{ .session_id = @fromBackingInt(3), .generation = 1 }, .output_sequence = 50, .bell_count = 0 };
    try tracker.observeTerminal(facts);
    try std.testing.expectEqual(@as(u64, 0), tracker.count());
    facts.eof_seen = true;
    try tracker.observeTerminal(facts);
    try std.testing.expectEqual(@as(u64, 1), tracker.count());
    tracker.setForeground(true);
    tracker.setForeground(false);
    facts.output_sequence += 1;
    try tracker.observeTerminal(facts);
    try std.testing.expectEqual(@as(u64, 1), tracker.count());
}
