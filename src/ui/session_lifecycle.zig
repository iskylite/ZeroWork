const std = @import("std");

pub const HostId = u64;
pub const SessionId = u64;

/// Build one POSIX shell input line from a shell-reported absolute directory.
/// OSC metadata is untrusted: quotes must be escaped and terminal controls
/// must never enter the input stream (even inside shell quotes).
pub fn mirrorDirectoryInput(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    if (cwd.len == 0 or cwd[0] != '/') return error.InvalidCurrentDirectory;
    if (!std.unicode.utf8ValidateSlice(cwd)) return error.InvalidCurrentDirectory;
    for (cwd) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidCurrentDirectory;
    var input: std.ArrayList(u8) = .empty;
    errdefer input.deinit(allocator);
    try input.appendSlice(allocator, "cd '");
    for (cwd) |byte| {
        if (byte == '\'') {
            try input.appendSlice(allocator, "'\\''");
        } else try input.append(allocator, byte);
    }
    try input.appendSlice(allocator, "'\r");
    return input.toOwnedSlice(allocator);
}

test "directory mirror quotes remote metadata and rejects terminal controls" {
    const allocator = std.testing.allocator;
    const input = try mirrorDirectoryInput(allocator, "/srv/it's $(touch sentinel);工作");
    defer allocator.free(input);
    try std.testing.expectEqualStrings("cd '/srv/it'\\''s $(touch sentinel);工作'\r", input);
    try std.testing.expectError(error.InvalidCurrentDirectory, mirrorDirectoryInput(allocator, "relative"));
    try std.testing.expectError(error.InvalidCurrentDirectory, mirrorDirectoryInput(allocator, "/srv/a\rwhoami"));
    try std.testing.expectError(error.InvalidCurrentDirectory, mirrorDirectoryInput(allocator, "/srv/\x1b[A"));
    try std.testing.expectError(error.InvalidCurrentDirectory, mirrorDirectoryInput(allocator, "/srv/\x9bA"));
}

/// A connection result belongs to one session incarnation, never an array index.
pub const Ticket = struct {
    session_id: SessionId,
    generation: u64 = 1,

    pub fn matches(self: Ticket, other: Ticket) bool {
        return self.session_id == other.session_id and self.generation == other.generation;
    }
};

/// Stable process-local asset identities. Moving/removing an asset only changes
/// its position in this list; already-running sessions retain their identity.
pub const Identities = struct {
    hosts: std.ArrayList(HostId) = .empty,
    next_host: HostId = 1,
    next_session: SessionId = 1,

    pub fn deinit(self: *Identities, allocator: std.mem.Allocator) void {
        self.hosts.deinit(allocator);
    }

    pub fn appendHosts(self: *Identities, allocator: std.mem.Allocator, count: usize) !void {
        if (count < self.hosts.items.len) return error.AssetMutationRequiresIdentityUpdate;
        try self.hosts.ensureTotalCapacity(allocator, count);
        while (self.hosts.items.len < count) {
            self.hosts.appendAssumeCapacity(self.next_host);
            self.next_host += 1;
        }
    }

    pub fn hostAt(self: *const Identities, index: usize) ?HostId {
        return if (index < self.hosts.items.len) self.hosts.items[index] else null;
    }

    pub fn hostIndex(self: *const Identities, id: HostId) ?usize {
        for (self.hosts.items, 0..) |candidate, index| if (candidate == id) return index;
        return null;
    }

    pub fn removeHost(self: *Identities, index: usize) !HostId {
        if (index >= self.hosts.items.len) return error.InvalidHost;
        return self.hosts.orderedRemove(index);
    }

    pub fn moveHost(self: *Identities, from: usize, to: usize) !void {
        if (from >= self.hosts.items.len or to >= self.hosts.items.len) return error.InvalidHost;
        const picked = self.hosts.items[from];
        if (from > to) {
            std.mem.copyBackwards(HostId, self.hosts.items[to + 1 .. from + 1], self.hosts.items[to..from]);
        } else if (from < to) {
            std.mem.copyForwards(HostId, self.hosts.items[from..to], self.hosts.items[from + 1 .. to + 1]);
        }
        self.hosts.items[to] = picked;
    }

    pub fn newTicket(self: *Identities) Ticket {
        const id = self.next_session;
        self.next_session += 1;
        return .{ .session_id = id };
    }
};

/// An owned configuration snapshot. Strings and nested slices are copied so a
/// pending connection or running session never borrows mutable asset storage.
pub fn Snapshot(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: T,

        pub fn init(allocator: std.mem.Allocator, value: T) !@This() {
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();
            const owned = try cloneValue(T, arena.allocator(), value);
            return .{ .arena = arena, .value = owned };
        }

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
        }
    };
}

pub fn cloneValue(comptime T: type, allocator: std.mem.Allocator, value: T) !T {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| blk: {
            if (pointer.size != .slice) break :blk value;
            const slice = try allocator.alloc(pointer.child, value.len);
            for (value, 0..) |item, index| slice[index] = try cloneValue(pointer.child, allocator, item);
            break :blk slice;
        },
        .optional => |optional| if (value) |item| try cloneValue(optional.child, allocator, item) else null,
        .@"struct" => |structure| blk: {
            var copy = value;
            inline for (structure.field_names, structure.field_types, structure.field_attrs) |name, FieldType, attrs| {
                if (!attrs.@"comptime") @field(copy, name) = try cloneValue(FieldType, allocator, @field(value, name));
            }
            break :blk copy;
        },
        .array => |array| blk: {
            var copy = value;
            for (value, 0..) |item, index| copy[index] = try cloneValue(array.child, allocator, item);
            break :blk copy;
        },
        .@"union" => |union_info| if (union_info.tag_type != null) switch (value) {
            inline else => |payload, tag| @unionInit(T, @tagName(tag), try cloneValue(@TypeOf(payload), allocator, payload)),
        } else value,
        else => value,
    };
}

test "asset reorder and removal cannot retarget a retained host identity" {
    var identities: Identities = .{};
    defer identities.deinit(std.testing.allocator);
    try identities.appendHosts(std.testing.allocator, 3);
    const a = identities.hostAt(0).?;
    const b = identities.hostAt(1).?;
    try identities.moveHost(1, 0);
    try std.testing.expectEqual(@as(?usize, 1), identities.hostIndex(a));
    try std.testing.expectEqual(@as(?usize, 0), identities.hostIndex(b));
    try std.testing.expectEqual(a, try identities.removeHost(1));
    try std.testing.expect(identities.hostIndex(a) == null);
    try std.testing.expectEqual(@as(?usize, 0), identities.hostIndex(b));
    try identities.appendHosts(std.testing.allocator, 3);
    try std.testing.expect(identities.hostAt(2).? != a);
}

test "late connection results require the original session and generation" {
    var identities: Identities = .{};
    const closed = identities.newTicket();
    const replacement = identities.newTicket();
    try std.testing.expect(!closed.matches(replacement));
    try std.testing.expect(!closed.matches(.{ .session_id = closed.session_id, .generation = closed.generation + 1 }));
    try std.testing.expect(closed.matches(closed));
}

test "snapshot survives mutation and release of all original config storage" {
    const Host = struct {
        host: []const u8,
        password: ?[]const u8,
        jumps: []const []const u8,
        option: struct { label: []const u8 },
    };
    var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = source_arena.allocator();
    const name = try allocator.dupe(u8, "server-a");
    const password = try allocator.dupe(u8, "first-password");
    const jumps = try allocator.alloc([]const u8, 1);
    jumps[0] = try allocator.dupe(u8, "bastion-a");
    var owned = try Snapshot(Host).init(std.testing.allocator, .{
        .host = name,
        .password = password,
        .jumps = jumps,
        .option = .{ .label = try allocator.dupe(u8, "direct") },
    });
    defer owned.deinit();
    name[0] = 'X';
    password[0] = 'X';
    source_arena.deinit();
    try std.testing.expectEqualStrings("server-a", owned.value.host);
    try std.testing.expectEqualStrings("first-password", owned.value.password.?);
    try std.testing.expectEqualStrings("bastion-a", owned.value.jumps[0]);
    try std.testing.expectEqualStrings("direct", owned.value.option.label);
}
