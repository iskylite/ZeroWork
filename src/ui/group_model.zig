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

    pub fn init(allocator: std.mem.Allocator) Roster {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Roster) void {
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
        try self.groups.append(self.allocator, .{ .id = self.next_id, .name = owned, .color = color });
        self.next_id += 1;
        return &self.groups.items[self.groups.items.len - 1];
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
        const group = try self.createOrGet(name, color);
        for (group.members.items) |*member| {
            if (member.pane_id == pane_id) {
                member.active = true;
                return group;
            }
        }
        group.membership_revision = try std.math.add(u64, group.membership_revision, 1);
        try group.members.append(self.allocator, .{ .pane_id = pane_id, .membership_revision = group.membership_revision });
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
