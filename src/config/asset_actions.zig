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
pub const Placement = union(enum) { before: identity.AssetOwner, after: identity.AssetOwner, end };
pub const Request = union(Kind) {
    clone: struct { owner: identity.AssetOwner, name: []const u8 },
    pin: struct { owner: identity.AssetOwner, pinned: bool },
    move: struct { owner: identity.AssetOwner, source_group: ?GroupRef, destination: ?GroupRef, placement: ?Placement = null },
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
            const destination = if (value.destination) |group| group.id else null;
            if (value.placement) |placement| switch (placement) {
                .before, .after => |target| {
                    const host = try candidate.get(target);
                    if (target.id == value.owner.id or host.asset_group_id != destination or host.pinned != source.pinned) return error.InvalidPlacement;
                },
                .end => {},
            };
            const moved = try candidate.move(value.owner, destination);
            if (value.placement) |placement| try place(candidate, moved, destination, placement);
            break :blk moved;
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

fn place(registry: *hosts.Registry, owner: identity.AssetOwner, destination: ?identity.AssetGroupId, placement: Placement) !void {
    if (destination) |id| {
        const group = &registry.groups[registry.groupIndex(id).?];
        const order = try registry.arena.allocator().alloc(identity.ConnectionId, group.ordered_connection_ids.len);
        var count: usize = 0;
        for (group.ordered_connection_ids) |item| if (item != owner.id) {
            order[count] = item;
            count += 1;
        };
        var at = count;
        switch (placement) {
            .before, .after => |target| for (order[0..count], 0..) |item, index| {
                if (item == target.id) {
                    at = index + @as(usize, if (placement == .after) 1 else 0);
                    break;
                }
            },
            .end => {},
        }
        std.mem.copyBackwards(identity.ConnectionId, order[at + 1 .. count + 1], order[at..count]);
        order[at] = owner.id;
        if (!std.mem.eql(identity.ConnectionId, order, group.ordered_connection_ids)) group.revision = try identity.advance(group.revision);
        group.ordered_connection_ids = order;
    } else {
        const from = registry.indexOf(owner.id).?;
        var at = registry.hosts.len - 1;
        switch (placement) {
            .before, .after => |target| {
                const index = registry.indexOf(target.id).?;
                at = index - @as(usize, if (from < index) 1 else 0) + @as(usize, if (placement == .after) 1 else 0);
            },
            .end => {},
        }
        const picked = registry.hosts[from];
        if (from < at) std.mem.copyForwards(hosts.HostConfig, registry.hosts[from..at], registry.hosts[from + 1 .. at + 1]) else if (at < from) std.mem.copyBackwards(hosts.HostConfig, registry.hosts[at + 1 .. from + 1], registry.hosts[at..from]);
        registry.hosts[at] = picked;
    }
}

fn validateGroup(registry: *const hosts.Registry, expected: GroupRef) !void {
    if (@backingInt(expected.id) == 0 or expected.revision == 0) return error.InvalidIdentity;
    const index = registry.groupIndex(expected.id) orelse return error.GroupNotFound;
    if (registry.groups[index].revision != expected.revision) return error.RevisionConflict;
}
