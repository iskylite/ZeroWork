const std = @import("std");

pub const Group = struct { id: u32, name: []const u8, color: u32 = 0xffffffff, pane_ids: []const u64 = &.{} };
pub const Broadcast = struct {
    group_id: u32,
    sent_bytes: u64 = 0,

    pub fn dispatch(self: *Broadcast, bytes: []const u8, panes: []const u64, send: *const fn (*anyopaque, u64, []const u8) anyerror!void, ctx: *anyopaque) !void {
        if (panes.len == 0) return error.EmptyGroup;
        var first_failure: ?anyerror = null;
        for (panes) |pane| {
            send(ctx, pane, bytes) catch |err| {
                if (first_failure == null) first_failure = err;
                continue;
            };
            self.sent_bytes += bytes.len;
        }
        if (first_failure) |err| return err;
    }
};

/// Runtime membership state for terminal groups.  The roster deliberately
/// contains pane IDs only: session/UI objects remain owned by the workspace
/// and can disappear without leaving dangling pointers here.
pub const Member = struct {
    pane_id: u64,
    active: bool = true,
    membership_revision: u64 = 1,
};

pub const GroupEntry = struct {
    id: u32,
    name: []u8,
    color: u32,
    members: std.ArrayList(Member) = .empty,
    pinned_pane: ?u64 = null,
    membership_revision: u64 = 1,

    fn deinit(self: *GroupEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.members.deinit(allocator);
    }

    pub fn memberIds(self: *const GroupEntry, out: []u64) usize {
        var count: usize = 0;
        for (self.members.items) |member| {
            if (!member.active or count == out.len) continue;
            out[count] = member.pane_id;
            count += 1;
        }
        return count;
    }

    pub fn contains(self: *const GroupEntry, pane_id: u64) bool {
        for (self.members.items) |member| if (member.pane_id == pane_id) return true;
        return false;
    }
};

/// Owns group membership without owning panes/sessions.  This is suitable for
/// both the `@grp` command and tab-menu actions; callers pass the current pane
/// identity and receive a compact active-member snapshot for dispatch.
pub const Roster = struct {
    allocator: std.mem.Allocator,
    groups: std.ArrayList(GroupEntry) = .empty,
    next_id: u32 = 1,
    reserved_groups: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Roster {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Roster) void {
        std.debug.assert(self.reserved_groups == 0);
        for (self.groups.items) |*group| group.deinit(self.allocator);
        self.groups.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn createOrGet(self: *Roster, name: []const u8, color: u32) !*GroupEntry {
        if (name.len == 0) return error.EmptyGroupName;
        for (self.groups.items) |*group| {
            if (std.mem.eql(u8, group.name, name)) return group;
        }
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        if (self.next_id == 0) return error.GroupIdentityExhausted;
        try self.groups.ensureUnusedCapacity(self.allocator, self.reserved_groups + 1);
        self.groups.appendAssumeCapacity(.{ .id = self.next_id, .name = owned, .color = color });
        self.next_id = if (self.next_id == std.math.maxInt(u32)) 0 else self.next_id + 1;
        return &self.groups.items[self.groups.items.len - 1];
    }
    pub const PreparedGroup = struct {
        roster: *Roster,
        id: u32,
        entry: ?GroupEntry,
        pub fn deinit(self: *PreparedGroup) void {
            if (self.entry) |*entry| {
                entry.deinit(self.roster.allocator);
                self.roster.reserved_groups -= 1;
                self.entry = null;
            }
        }
        /// All storage was reserved before publication. Other ordinary group
        /// creation respects the reservation, including while durable IO runs.
        pub fn commit(self: *PreparedGroup) !u32 {
            const entry = self.entry orelse return error.GroupTransactionConsumed;
            if (self.roster.findById(self.id) != null) return error.GroupIdentityConflict;
            self.roster.groups.appendAssumeCapacity(entry);
            self.roster.reserved_groups -= 1;
            self.entry = null;
            return self.id;
        }
    };
    /// Creates a fresh identity even when another group has the same name.
    /// The caller may durably record the reserved ID before exposing it.
    pub fn prepareNew(self: *Roster, name: []const u8, color: u32, initial_pane: ?u64) !PreparedGroup {
        if (name.len == 0) return error.EmptyGroupName;
        if (self.next_id == 0) return error.GroupIdentityExhausted;
        const owned = try self.allocator.dupe(u8, name);
        var entry: GroupEntry = .{ .id = self.next_id, .name = owned, .color = color };
        errdefer entry.deinit(self.allocator);
        if (initial_pane) |pane| {
            entry.membership_revision = 2;
            try entry.members.append(self.allocator, .{ .pane_id = pane, .membership_revision = 2 });
        }
        try self.groups.ensureUnusedCapacity(self.allocator, self.reserved_groups + 1);
        self.reserved_groups += 1;
        self.next_id = if (self.next_id == std.math.maxInt(u32)) 0 else self.next_id + 1;
        return .{ .roster = self, .id = entry.id, .entry = entry };
    }

    pub fn find(self: *Roster, name: []const u8) ?*GroupEntry {
        for (self.groups.items) |*group| if (std.mem.eql(u8, group.name, name)) return group;
        return null;
    }

    pub fn findById(self: *Roster, id: u32) ?*GroupEntry {
        for (self.groups.items) |*group| if (group.id == id) return group;
        return null;
    }

    /// Idempotent join: joining again does not duplicate a pane.
    pub fn join(self: *Roster, name: []const u8, pane_id: u64, color: u32) !*GroupEntry {
        const group = self.find(name) orelse {
            var prepared = try self.prepareNew(name, color, pane_id);
            defer prepared.deinit();
            return self.findById(try prepared.commit()).?;
        };
        for (group.members.items) |*member| {
            if (member.pane_id == pane_id) {
                member.active = true;
                return group;
            }
        }
        const revision = try std.math.add(u64, group.membership_revision, 1);
        try group.members.ensureUnusedCapacity(self.allocator, 1);
        group.members.appendAssumeCapacity(.{ .pane_id = pane_id, .membership_revision = revision });
        group.membership_revision = revision;
        return group;
    }

    pub fn leave(self: *Roster, name: []const u8, pane_id: u64) !void {
        const group = self.find(name) orelse return error.UnknownGroup;
        for (group.members.items, 0..) |member, index| {
            if (member.pane_id == pane_id) {
                _ = group.members.orderedRemove(index);
                group.membership_revision +|= 1;
                if (group.pinned_pane == pane_id) group.pinned_pane = null;
                return;
            }
        }
        return error.NotMember;
    }

    /// A closed/disconnected pane stays known to the group but is excluded
    /// from broadcast until it is marked active again.
    /// Remove a pane from every group, used by the @grp leave command when
    /// the caller does not need to know the current group name.
    pub fn leavePane(self: *Roster, pane_id: u64) bool {
        var removed = false;
        for (self.groups.items) |*group| {
            var index: usize = 0;
            while (index < group.members.items.len) {
                if (group.members.items[index].pane_id == pane_id) {
                    _ = group.members.orderedRemove(index);
                    group.membership_revision +|= 1;
                    if (group.pinned_pane == pane_id) group.pinned_pane = null;
                    removed = true;
                } else index += 1;
            }
        }
        return removed;
    }

    pub fn setActive(self: *Roster, name: []const u8, pane_id: u64, active: bool) !void {
        const group = self.find(name) orelse return error.UnknownGroup;
        for (group.members.items) |*member| {
            if (member.pane_id == pane_id) {
                member.active = active;
                if (!active and group.pinned_pane == pane_id) group.pinned_pane = null;
                return;
            }
        }
        return error.NotMember;
    }

    pub fn pin(self: *Roster, name: []const u8, pane_id: ?u64) !void {
        const group = self.find(name) orelse return error.UnknownGroup;
        if (pane_id) |id| {
            for (group.members.items) |member| {
                if (member.pane_id == id and member.active) {
                    group.pinned_pane = id;
                    return;
                }
            }
            return error.NotMember;
        }
        group.pinned_pane = null;
    }

    pub fn anchor(self: *Roster, name: []const u8) !?u64 {
        const group = self.find(name) orelse return error.UnknownGroup;
        if (group.pinned_pane) |id| return id;
        for (group.members.items) |member| if (member.active) return member.pane_id;
        return null;
    }
};

test "group transaction reserves publication across other creations and preserves unique identity" {
    var roster = Roster.init(std.testing.allocator);
    defer roster.deinit();
    var pending = try roster.prepareNew("same name", 0, 101);
    defer pending.deinit();
    const reserved = pending.id;
    try std.testing.expectEqual(@as(usize, 0), roster.groups.items.len);
    for (0..24) |index| {
        var name: [32]u8 = undefined;
        _ = try roster.createOrGet(try std.fmt.bufPrint(&name, "other-{d}", .{index}), 0);
    }
    try std.testing.expectEqual(reserved, try pending.commit());
    try std.testing.expectEqual(@as(usize, 25), roster.groups.items.len);
    try std.testing.expect(roster.findById(reserved).?.contains(101));
    try std.testing.expectError(error.GroupTransactionConsumed, pending.commit());
    var second = try roster.prepareNew("same name", 0, null);
    defer second.deinit();
    try std.testing.expect(reserved != try second.commit());
    var abandoned = try roster.prepareNew("abandoned", 0, 102);
    const abandoned_id = abandoned.id;
    abandoned.deinit();
    try std.testing.expect(roster.findById(abandoned_id) == null);
    try std.testing.expectEqual(@as(usize, 0), roster.reserved_groups);
}

test "group transaction allocation failures leave no group member or revision changes" {
    const a = std.testing.allocator;
    for (0..4) |failure| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = failure });
        var roster = Roster.init(failing.allocator());
        defer roster.deinit();
        var prepared = roster.prepareNew("atomic", 0, 101) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 0), roster.groups.items.len);
            try std.testing.expectEqual(@as(usize, 0), roster.reserved_groups);
            try std.testing.expectEqual(@as(u32, 1), roster.next_id);
            continue;
        };
        defer prepared.deinit();
        _ = try prepared.commit();
    }
    var failing = std.testing.FailingAllocator.init(a, .{});
    var roster = Roster.init(failing.allocator());
    defer roster.deinit();
    const group = try roster.join("existing", 101, 0);
    while (group.members.items.len < group.members.capacity) _ = try roster.join("existing", 101 + group.members.items.len, 0);
    const count = group.members.items.len;
    const revision = group.membership_revision;
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try std.testing.expectError(error.OutOfMemory, roster.join("existing", 999, 0));
    try std.testing.expectEqual(count, group.members.items.len);
    try std.testing.expectEqual(revision, group.membership_revision);
}

test "broadcast sends input to every pane and counts echo bytes" {
    const Fake = struct {
        count: usize = 0,
        fn send(ctx: *anyopaque, _: u64, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.count += bytes.len;
        }
    };
    var fake: Fake = .{};
    var broadcast: Broadcast = .{ .group_id = 1 };
    try broadcast.dispatch("ls\n", &.{ 2, 3, 4, 5 }, Fake.send, &fake);
    try std.testing.expectEqual(@as(usize, 12), fake.count);
    try std.testing.expectEqual(@as(u64, 12), broadcast.sent_bytes);
}

test "roster joins idempotently and excludes inactive members from dispatch" {
    var roster = Roster.init(std.testing.allocator);
    defer roster.deinit();
    _ = try roster.join("prod", 10, 0xff112233);
    _ = try roster.join("prod", 10, 0xff112233);
    _ = try roster.join("prod", 11, 0xff112233);
    try roster.setActive("prod", 11, false);
    var ids: [4]u64 = undefined;
    const count = roster.find("prod").?.memberIds(&ids);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(u64, 10), ids[0]);
}

test "roster pin is an active group anchor and falls back after leave" {
    var roster = Roster.init(std.testing.allocator);
    defer roster.deinit();
    _ = try roster.join("ops", 3, 0xffaabbcc);
    _ = try roster.join("ops", 4, 0xffaabbcc);
    try roster.pin("ops", 4);
    try std.testing.expectEqual(@as(?u64, 4), try roster.anchor("ops"));
    try roster.leave("ops", 4);
    try std.testing.expectEqual(@as(?u64, 3), try roster.anchor("ops"));
}

test "membership epoch changes on leave and rejoin but not duplicate join or pin" {
    var roster = Roster.init(std.testing.allocator);
    defer roster.deinit();
    const group = try roster.join("stable", 101, 0);
    const revision = group.membership_revision;
    const epoch = group.members.items[0].membership_revision;
    _ = try roster.join("stable", 101, 0);
    try roster.pin("stable", 101);
    try std.testing.expectEqual(revision, group.membership_revision);
    try roster.leave("stable", 101);
    _ = try roster.join("stable", 101, 0);
    try std.testing.expect(group.members.items[0].membership_revision > epoch);
}
