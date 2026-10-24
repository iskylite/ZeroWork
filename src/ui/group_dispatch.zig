//! Legacy raw-byte helper retained for existing callers/tests. Production group
//! input uses broadcast_controller Approval plus typed TerminalService events.
pub const Approved = @import("broadcast_controller.zig");
const Group = @import("group_model.zig").Group;
const model = @import("group_model.zig");
const Broadcast = model.Broadcast;
const Roster = model.Roster;
const Manager = @import("pane_manager.zig").Manager;

pub const Dispatcher = struct {
    manager: ?*Manager = null,
    group: Group,
    broadcast: Broadcast,
    send: *const fn (*anyopaque, u64, []const u8) anyerror!void,
    ctx: *anyopaque,

    pub fn dispatch(self: *Dispatcher, bytes: []const u8) !void {
        try self.broadcast.dispatch(bytes, self.group.pane_ids, self.send, self.ctx);
    }

    /// The focused sender has already accepted these bytes. Explicit @sync
    /// enables fan-out; the source is never sent twice, and source membership
    /// is checked against the live roster rather than the active-tab index.
    pub fn dispatchFrom(self: *Dispatcher, roster: *Roster, group_name: []const u8, source: u64, enabled: bool, bytes: []const u8) !void {
        if (!enabled or bytes.len == 0) return;
        const entry = roster.find(group_name) orelse return error.UnknownGroup;
        var source_active = false;
        for (entry.members.items) |member| {
            if (member.pane_id == source and member.active) source_active = true;
        }
        if (!source_active) return error.NotMember;
        self.broadcast.group_id = entry.id;
        // Iterate without a fixed-size snapshot: large groups cannot silently
        // lose members. Failed/ended recipients do not stop healthy siblings.
        var first_failure: ?anyerror = null;
        for (entry.members.items) |member| {
            if (!member.active or member.pane_id == source) continue;
            self.send(self.ctx, member.pane_id, bytes) catch |err| {
                if (first_failure == null) first_failure = err;
                continue;
            };
            self.broadcast.sent_bytes += bytes.len;
        }
        if (first_failure) |err| return err;
    }

    /// Dispatch using the current roster rather than a stale UI snapshot.
    /// Inactive/closed members are filtered by `Roster`; this keeps broadcast
    /// scoped to the selected group and avoids writing into another session.
    pub fn dispatchRoster(self: *Dispatcher, roster: *Roster, group_name: []const u8, bytes: []const u8) !void {
        const entry = roster.find(group_name) orelse return error.UnknownGroup;
        var active_count: usize = 0;
        var first_failure: ?anyerror = null;
        self.broadcast.group_id = entry.id;
        for (entry.members.items) |member| {
            if (!member.active) continue;
            active_count += 1;
            self.send(self.ctx, member.pane_id, bytes) catch |err| {
                if (first_failure == null) first_failure = err;
                continue;
            };
            self.broadcast.sent_bytes += bytes.len;
        }
        if (active_count == 0) return error.EmptyGroup;
        if (first_failure) |err| return err;
    }
};

test "dispatcher roster dispatches only active selected-group members" {
    const std = @import("std");
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    var roster = Roster.init(std.testing.allocator);
    defer roster.deinit();
    _ = try roster.join("prod", 1, 0xff00ff00);
    _ = try roster.join("prod", 2, 0xff00ff00);
    _ = try roster.join("other", 3, 0xff0000ff);
    try roster.setActive("prod", 2, false);
    const Fake = struct {
        seen: std.ArrayList(u64) = .empty,
        fn send(ctx: *anyopaque, pane: u64, _: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.seen.append(std.testing.allocator, pane);
        }
    };
    var fake = Fake{};
    defer fake.seen.deinit(std.testing.allocator);
    var dispatcher = Dispatcher{ .manager = &manager, .group = .{ .id = 0, .name = "", .pane_ids = &.{} }, .broadcast = .{ .group_id = 0 }, .send = Fake.send, .ctx = &fake };
    try dispatcher.dispatchRoster(&roster, "prod", "pwd\n");
    try std.testing.expectEqual(@as(usize, 1), fake.seen.items.len);
    try std.testing.expectEqual(@as(u64, 1), fake.seen.items[0]);
}

test "source dispatch requires explicit enable and isolates failed recipients" {
    const std = @import("std");
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    var roster = Roster.init(std.testing.allocator);
    defer roster.deinit();
    for ([_]u32{ 1, 2, 3, 4 }) |id| _ = try roster.join("ops", id, 0);
    try roster.setActive("ops", 4, false);
    const Fake = struct {
        seen: std.ArrayList(u64) = .empty,
        fn send(ctx: *anyopaque, pane: u64, _: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.seen.append(std.testing.allocator, pane);
            if (pane == 2) return error.EndedSession;
        }
    };
    var fake = Fake{};
    defer fake.seen.deinit(std.testing.allocator);
    var dispatcher = Dispatcher{ .manager = &manager, .group = .{ .id = 0, .name = "" }, .broadcast = .{ .group_id = 0 }, .send = Fake.send, .ctx = &fake };
    try dispatcher.dispatchFrom(&roster, "ops", 1, false, "pwd\r");
    try std.testing.expectEqual(@as(usize, 0), fake.seen.items.len);
    try std.testing.expectError(error.NotMember, dispatcher.dispatchFrom(&roster, "ops", 9, true, "pwd\r"));
    try std.testing.expectError(error.EndedSession, dispatcher.dispatchFrom(&roster, "ops", 1, true, "pwd\r"));
    try std.testing.expectEqualSlices(u64, &.{ 2, 3 }, fake.seen.items);
    try std.testing.expectEqual(@as(u64, 4), dispatcher.broadcast.sent_bytes);
}

test "source dispatch reaches groups larger than snapshot capacity" {
    const std = @import("std");
    var roster = Roster.init(std.testing.allocator);
    defer roster.deinit();
    for (0..300) |index| _ = try roster.join("large", @intCast(index), 0);
    const Fake = struct {
        count: usize = 0,
        fn send(ctx: *anyopaque, pane: u64, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try std.testing.expect(pane != 0);
            try std.testing.expectEqualStrings("x", bytes);
            self.count += 1;
        }
    };
    var fake = Fake{};
    var dispatcher = Dispatcher{ .group = .{ .id = 0, .name = "" }, .broadcast = .{ .group_id = 0 }, .send = Fake.send, .ctx = &fake };
    try dispatcher.dispatchFrom(&roster, "large", 0, true, "x");
    try std.testing.expectEqual(@as(usize, 299), fake.count);
    try std.testing.expectEqual(@as(u64, 299), dispatcher.broadcast.sent_bytes);
}

test "roster dispatch preserves full session identities and all active recipients" {
    const std = @import("std");
    var roster = Roster.init(std.testing.allocator);
    defer roster.deinit();
    const high: u64 = @as(u64, 1) << 32;
    for (0..300) |index| _ = try roster.join("large", high + index, 0);
    _ = try roster.join("large", 1, 0);
    try roster.setActive("large", high + 1, false);
    const Fake = struct {
        seen: std.ArrayList(u64) = .empty,
        fn send(raw: *anyopaque, id: u64, _: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try self.seen.append(std.testing.allocator, id);
            if (id == high + 2) return error.EndedSession;
        }
    };
    var fake: Fake = .{};
    defer fake.seen.deinit(std.testing.allocator);
    var dispatcher: Dispatcher = .{ .group = .{ .id = 0, .name = "" }, .broadcast = .{ .group_id = 0 }, .send = Fake.send, .ctx = &fake };
    try std.testing.expectError(error.EndedSession, dispatcher.dispatchRoster(&roster, "large", "x"));
    try std.testing.expectEqual(@as(usize, 300), fake.seen.items.len);
    try std.testing.expectEqual(@as(u64, 1), fake.seen.items[299]);
    try std.testing.expect(std.mem.indexOfScalar(u64, fake.seen.items, high + 1) == null);
    try std.testing.expectEqual(@as(u64, 299), dispatcher.broadcast.sent_bytes);
    _ = roster.leavePane(1);
    try std.testing.expect(roster.find("large").?.contains(high + 1));
}
