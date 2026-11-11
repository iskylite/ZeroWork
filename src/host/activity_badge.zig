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
    /// Window-local tab attention. Unlike `pending` this is not a menu-bar
    /// background marker: it survives App foreground restoration and is cleared
    /// only by a real read receipt for the owning tab.
    tab_pending: bool = false,
    /// Last observed frame generation for plugin (KVM) sessions, so a steady
    /// video stream cannot be mistaken for an unbounded stream of new events.
    tab_frame_sequence: u64 = 0,
    last_frame_activity_ms: u64 = 0,
};
const AiReceipt = struct { owner: identity.ContentOwner, operation: u64, turn: u64 };
pub const Tracker = struct {
    pub const frame_activity_interval_ms: u64 = 1000;
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
        const changed = item.initialized and
            (facts.output_sequence > item.output_sequence or (facts.eof_seen and !item.eof));
        if (changed) {
            // A newly observed output batch or session end is one real event.
            // The tab attention is independent of the App's foreground state:
            // another tab in a foreground window is still a background tab.
            item.tab_pending = true;
            if (self.background) {
                if (!item.pending or item.ai_operation != null) self.revision +%= 1;
                item.pending = true;
                item.ai_operation = null;
            }
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
            item.tab_pending = true;
            if (self.background) {
                item.pending = true;
                item.ai_operation = operation;
                self.revision +%= 1;
            }
            return;
        };
        try self.ai_receipts.append(self.allocator, .{ .owner = owner, .operation = operation, .turn = turn });
        item.tab_pending = true;
        if (self.background) {
            item.pending = true;
            item.ai_operation = operation;
            self.revision +%= 1;
        }
    }
    /// A host-confirmed one-shot session event (transfer completion, reconnect,
    /// plugin result) marks the owning tab unread without publishing a menu-bar
    /// row or a system notification.
    pub fn observeTabActivity(self: *Tracker, owner: identity.ContentOwner) !void {
        const item = try self.entry(owner);
        item.tab_pending = true;
    }
    /// Video/stream frames are deduplicated by a monotonically increasing
    /// generation owned by the plugin, then throttled in time: a steady RFB
    /// stream publishes frames even when the picture is static, so without a
    /// throttle a real read receipt would be undone by the very next frame.
    pub fn observeTabFrame(self: *Tracker, owner: identity.ContentOwner, sequence: u64, now_ms: u64) !void {
        if (sequence == 0) return;
        const item = try self.entry(owner);
        if (sequence <= item.tab_frame_sequence) return;
        item.tab_frame_sequence = sequence;
        if (now_ms -| item.last_frame_activity_ms < frame_activity_interval_ms) return;
        item.last_frame_activity_ms = now_ms;
        item.tab_pending = true;
    }
    pub fn hasTabActivity(self: *const Tracker, owner: identity.ContentOwner) bool {
        for (self.entries.items) |item| if (item.owner.eql(owner) and item.tab_pending) return true;
        return false;
    }
    /// Cleared only when the real content is visible and read at its latest
    /// generation. A later event re-arms the tab; mere redraws do not.
    pub fn markTabRead(self: *Tracker, owner: identity.ContentOwner) bool {
        for (self.entries.items) |*item| if (item.owner.eql(owner) and item.tab_pending) {
            item.tab_pending = false;
            return true;
        };
        return false;
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

test "tab attention is independent of foreground and clears only on read" {
    var tracker: Tracker = .{ .allocator = std.testing.allocator };
    defer tracker.deinit();
    const handle: identity.SessionHandle = .{ .session_id = @fromBackingInt(9), .generation = 1 };
    const owner: identity.ContentOwner = .{ .session = handle };
    var facts: terminal.NotificationSnapshot = .{ .owner = handle, .output_sequence = 5, .bell_count = 0 };
    // The first observation establishes a baseline, not a new event.
    try tracker.observeTerminal(facts);
    try std.testing.expect(!tracker.hasTabActivity(owner));
    facts.output_sequence = 6;
    try tracker.observeTerminal(facts);
    try std.testing.expect(tracker.hasTabActivity(owner));
    try std.testing.expectEqual(@as(u64, 0), tracker.count());
    // App foreground restoration clears menu rows but not tab attention.
    tracker.setForeground(false);
    tracker.setForeground(true);
    try std.testing.expect(tracker.hasTabActivity(owner));
    try tracker.observeTerminal(facts);
    try std.testing.expect(tracker.hasTabActivity(owner));
    try std.testing.expect(tracker.markTabRead(owner));
    try std.testing.expect(!tracker.hasTabActivity(owner));
    try std.testing.expect(!tracker.markTabRead(owner));
    // AI turns, one-shot task results and plugin frames share the same state.
    try tracker.observeAi(owner, 1, 1);
    try std.testing.expect(tracker.hasTabActivity(owner));
    try std.testing.expect(tracker.markTabRead(owner));
    try tracker.observeTabActivity(owner);
    try std.testing.expect(tracker.hasTabActivity(owner));
    try std.testing.expect(tracker.markTabRead(owner));
    try tracker.observeTabFrame(owner, 10, 1000);
    try std.testing.expect(tracker.hasTabActivity(owner));
    try std.testing.expect(tracker.markTabRead(owner));
    // A repeated/older generation is not a new event, and a newer frame
    // inside the throttle window does not undo the read receipt.
    try tracker.observeTabFrame(owner, 10, 1000);
    try tracker.observeTabFrame(owner, 4, 1000);
    try tracker.observeTabFrame(owner, 11, 1100);
    try std.testing.expect(!tracker.hasTabActivity(owner));
    try tracker.observeTabFrame(owner, 12, 2000);
    try std.testing.expect(tracker.hasTabActivity(owner));
    tracker.remove(owner);
    try std.testing.expect(!tracker.hasTabActivity(owner));
}
