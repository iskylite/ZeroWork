//! Saved-asset mutations through the existing owned Registry transaction.
//! Requests capture persistent identities; this module never owns sessions/UI.
const std = @import("std");
const hosts = @import("hosts.zig");
const store = @import("store.zig");
const identity = hosts.identity;

/// Capture both fields when presenting the move menu. A group rename or
/// membership edit invalidates that menu even if the host revision is unchanged.
pub const GroupRef = struct { id: identity.AssetGroupId, revision: u64 };
pub const Kind = enum { clone, pin, move, delete };
pub const Request = union(Kind) {
    clone: struct { owner: identity.AssetOwner, name: []const u8 },
    pin: struct { owner: identity.AssetOwner, pinned: bool },
    move: struct { owner: identity.AssetOwner, source_group: ?GroupRef, destination: ?GroupRef },
    delete: struct { owner: identity.AssetOwner },
};
pub const CommitReceipt = struct {
    previous_revision: u64,
    revision: u64,
    source_hash: hosts.Digest,
};
/// All fields are value-owned; no slices into either Registry survive commit.
/// previous_index addresses the source in the old UI identity projection.
/// owner/index address the result; both are null for deletion.
pub const Result = struct {
    kind: Kind,
    source_owner: identity.AssetOwner,
    owner: ?identity.AssetOwner,
    previous_index: usize,
    index: ?usize,
    commit: CommitReceipt,
};

/// Synchronous, atomic mutation of the saved registry. Request strings may borrow
/// the current live registry during this call; Result contains only values.
/// Publish UI projections from Result only after success. Any error retains the
/// previous live registry, including identity watermarks and revisions.
pub fn apply(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, live: *hosts.Registry, request: Request) !Result {
    const source_owner = switch (request) {
        inline else => |value| value.owner,
    };
    _ = try live.get(source_owner);
    const previous_index = live.indexOf(source_owner.id).?;
    var transaction = try store.HostsTransaction.init(allocator, live);
    defer transaction.deinit();
    const candidate = &transaction.candidate.?;
    const owner: ?identity.AssetOwner = switch (request) {
        .clone => |value| try candidate.duplicate(value.owner, value.name),
        .pin => |value| try candidate.setPinned(value.owner, value.pinned),
        .move => |value| blk: {
            const source = try candidate.get(value.owner);
            const expected_source = if (value.source_group) |group| group.id else null;
            if (source.asset_group_id != expected_source) return error.RevisionConflict;
            if (value.source_group) |group| try validateGroup(candidate, group);
            if (value.destination) |group| try validateGroup(candidate, group);
            break :blk try candidate.move(value.owner, if (value.destination) |group| group.id else null);
        },
        .delete => |value| blk: {
            try candidate.remove(value.owner);
            break :blk null;
        },
    };
    const previous_revision = transaction.baseline_revision;
    try transaction.commit(io, dir, path, live);
    // Atomic rename and infallible Registry publication have both completed.
    return .{
        .kind = std.meta.activeTag(request),
        .source_owner = source_owner,
        .owner = owner,
        .previous_index = previous_index,
        .index = if (owner) |value| live.indexOf(value.id).? else null,
        .commit = .{ .previous_revision = previous_revision, .revision = live.revision, .source_hash = live.source_hash.? },
    };
}

fn validateGroup(registry: *const hosts.Registry, expected: GroupRef) !void {
    if (@backingInt(expected.id) == 0 or expected.revision == 0) return error.InvalidIdentity;
    const index = registry.groupIndex(expected.id) orelse return error.GroupNotFound;
    if (registry.groups[index].revision != expected.revision) return error.RevisionConflict;
}
