const std = @import("std");

// Separate types keep presentation, persistence and runtime identities from
// accidentally being substituted for one another at controller boundaries.
pub const ConnectionId = enum(u64) { _ };
pub const AssetGroupId = enum(u64) { _ };
pub const SessionId = enum(u64) { _ };
pub const RetainedTransferOwnerId = enum(u64) { _ };
pub const TabId = enum(u64) { _ };
pub const PaneId = enum(u64) { _ };
pub const GroupId = enum(u64) { _ };
pub const HistoryId = enum(u64) { _ };
pub const WindowId = enum(u64) { _ };
pub const WorkspaceId = enum(u64) { _ };

/// Persistence/cross-window correlation is independent of a Store's small UI
/// counter. Entropy comes from the OS; no timestamp, address or session name is
/// used as an identity. The zero value is reserved for uninitialized fixtures.
pub const ConversationId = StableId(.conversation);
pub const TaskId = StableId(.task);
pub const ExecutionId = StableId(.execution);
pub const HostOperationId = StableId(.host_operation);
pub const RecordingId = StableId(.recording);
pub const ArchiveKey = StableId(.archive);

fn StableId(comptime kind: enum { conversation, task, execution, host_operation, recording, archive }) type {
    _ = kind;
    return struct {
        bytes: [16]u8 = @splat(0),

        pub fn generate() @This() {
            var result: @This() = .{};
            while (!result.valid()) std.c.arc4random_buf(&result.bytes, result.bytes.len);
            return result;
        }
        pub fn valid(self: @This()) bool {
            return !std.mem.allEqual(u8, &self.bytes, 0);
        }
        pub fn eql(self: @This(), other: @This()) bool {
            return std.mem.eql(u8, &self.bytes, &other.bytes);
        }
        pub fn parse(text: []const u8) !@This() {
            if (text.len != 32) return error.InvalidIdentity;
            var result: @This() = .{};
            _ = std.fmt.hexToBytes(&result.bytes, text) catch return error.InvalidIdentity;
            if (!result.valid()) return error.InvalidIdentity;
            return result;
        }
        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            return parse(try std.json.innerParse([]const u8, allocator, source, options)) catch return error.InvalidCharacter;
        }
        pub fn jsonParseFromValue(_: std.mem.Allocator, value: std.json.Value, _: std.json.ParseOptions) !@This() {
            if (value != .string) return error.UnexpectedToken;
            return parse(value.string) catch return error.InvalidCharacter;
        }
        pub fn jsonStringify(self: @This(), writer: anytype) !void {
            const text = std.fmt.bytesToHex(self.bytes, .lower);
            try writer.write(@as([]const u8, &text));
        }
    };
}

pub const SessionHandle = struct {
    session_id: SessionId,
    generation: u64 = 1,

    pub fn eql(self: SessionHandle, other: SessionHandle) bool {
        return self.session_id == other.session_id and self.generation == other.generation;
    }

    pub fn nextGeneration(self: SessionHandle) !SessionHandle {
        return .{ .session_id = self.session_id, .generation = try advance(self.generation) };
    }
};

pub const GroupOwner = struct { id: GroupId, revision: u64 = 1 };
pub const AssetOwner = struct { id: ConnectionId, revision: u64 = 1 };
pub const TransferOwner = struct { id: RetainedTransferOwnerId, original_handle: SessionHandle };

pub const ContentOwner = union(enum) {
    session: SessionHandle,
    group: GroupOwner,
    history: HistoryId,

    pub fn eql(self: ContentOwner, other: ContentOwner) bool {
        return std.meta.eql(self, other);
    }
};

pub const CommandOwner = union(enum) {
    app,
    asset: AssetOwner,
    session: SessionHandle,
    group: GroupOwner,
    history: HistoryId,
    transfer_owner: TransferOwner,

    pub fn eql(self: CommandOwner, other: CommandOwner) bool {
        return std.meta.eql(self, other);
    }
};

pub const ResourceOwner = union(enum) {
    session: SessionHandle,
    retained_transfer: RetainedTransferOwnerId,

    pub fn eql(self: ResourceOwner, other: ResourceOwner) bool {
        return std.meta.eql(self, other);
    }
};

/// Owned by the application, not a window. Persist `next_value` alongside
/// persistent entities; runtime allocators live for the whole application.
/// Allocating the last u64 succeeds once; the next allocation fails, never wraps.
pub fn Allocator(comptime Id: type) type {
    return struct {
        next_value: u64 = 1,
        exhausted: bool = false,

        pub fn allocate(self: *@This()) error{IdentityExhausted}!Id {
            if (self.exhausted or self.next_value == 0) return error.IdentityExhausted;
            const value = self.next_value;
            if (value == std.math.maxInt(u64)) {
                self.exhausted = true;
            } else self.next_value += 1;
            return @fromBackingInt(value);
        }

        /// Loading stored entities must reserve their identities before new
        /// allocations. Removing an entity never moves the watermark backwards.
        pub fn reserve(self: *@This(), id: Id) error{InvalidIdentity}!void {
            const value = @backingInt(id);
            if (value == 0) return error.InvalidIdentity;
            if (value == std.math.maxInt(u64)) {
                self.exhausted = true;
            } else self.next_value = @max(self.next_value, value + 1);
        }
    };
}

pub fn advance(value: u64) error{RevisionExhausted}!u64 {
    if (value == 0 or value == std.math.maxInt(u64)) return error.RevisionExhausted;
    return value + 1;
}

test "identity allocation reserves persistent values and never wraps" {
    var ids: Allocator(ConnectionId) = .{};
    try ids.reserve(@fromBackingInt(41));
    try std.testing.expectEqual(@as(u64, 42), @backingInt(try ids.allocate()));
    try std.testing.expectError(error.InvalidIdentity, ids.reserve(@fromBackingInt(0)));
    ids.next_value = std.math.maxInt(u64);
    try std.testing.expectEqual(std.math.maxInt(u64), @backingInt(try ids.allocate()));
    try std.testing.expectError(error.IdentityExhausted, ids.allocate());
}

test "session reconstruction advances generation with an explicit limit" {
    const handle: SessionHandle = .{ .session_id = @fromBackingInt(1) };
    const next = try handle.nextGeneration();
    try std.testing.expect(!handle.eql(next));
    try std.testing.expectEqual(handle.session_id, next.session_id);
    try std.testing.expectError(error.RevisionExhausted, advance(std.math.maxInt(u64)));
}
