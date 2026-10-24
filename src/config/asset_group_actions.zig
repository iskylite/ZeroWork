//! Persistent asset groups use the existing Registry transaction. Requests
//! capture a group identity and revision, never a sidebar position or name.
const std = @import("std");
const hosts = @import("hosts.zig");
const store = @import("store.zig");
const assets = @import("asset_actions.zig");
pub const GroupRef = assets.GroupRef;
pub const Kind = enum { create, rename, color, toggle_collapsed, delete_empty };
pub const Request = union(Kind) {
    create: struct { name: []const u8, color: []const u8 = "#6366f1" },
    rename: struct { group: GroupRef, name: []const u8 },
    color: struct { group: GroupRef, color: []const u8 },
    toggle_collapsed: GroupRef,
    delete_empty: GroupRef,
};
pub const Result = struct {
    kind: Kind,
    source_group: ?GroupRef,
    group: ?GroupRef,
    commit: assets.CommitReceipt,
};

pub fn group(registry: *const hosts.Registry, expected: GroupRef) !hosts.AssetGroup {
    if (@backingInt(expected.id) == 0 or expected.revision == 0) return error.InvalidIdentity;
    const index = registry.groupIndex(expected.id) orelse return error.GroupNotFound;
    const value = registry.groups[index];
    if (value.revision != expected.revision) return error.RevisionConflict;
    return value;
}
pub fn colorValid(value: []const u8) bool {
    if (value.len != 7 or value[0] != '#') return false;
    for (value[1..]) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}
pub fn apply(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, live: *hosts.Registry, request: Request) !Result {
    var transaction = try store.HostsTransaction.init(allocator, live);
    defer transaction.deinit();
    const candidate = &transaction.candidate.?;
    var original: ?GroupRef = null;
    const next: ?GroupRef = switch (request) {
        .create => |value| blk: {
            if (!colorValid(value.color)) return error.InvalidGroupColor;
            const id = try candidate.addGroup(std.mem.trim(u8, value.name, " \t\r\n"), value.color);
            break :blk .{ .id = id, .revision = candidate.groups[candidate.groupIndex(id).?].revision };
        },
        .rename => |value| blk: {
            const previous = try group(candidate, value.group);
            original = value.group;
            const revision = try candidate.updateGroup(value.group.id, value.group.revision, std.mem.trim(u8, value.name, " \t\r\n"), previous.color, previous.collapsed);
            break :blk .{ .id = value.group.id, .revision = revision };
        },
        .color => |value| blk: {
            const previous = try group(candidate, value.group);
            if (!colorValid(value.color)) return error.InvalidGroupColor;
            original = value.group;
            const revision = try candidate.updateGroup(value.group.id, value.group.revision, previous.name, value.color, previous.collapsed);
            break :blk .{ .id = value.group.id, .revision = revision };
        },
        .toggle_collapsed => |reference| blk: {
            const previous = try group(candidate, reference);
            original = reference;
            const revision = try candidate.updateGroup(reference.id, reference.revision, previous.name, previous.color, !previous.collapsed);
            break :blk .{ .id = reference.id, .revision = revision };
        },
        .delete_empty => |reference| blk: {
            _ = try group(candidate, reference);
            original = reference;
            try candidate.removeEmptyGroup(reference.id, reference.revision);
            break :blk null;
        },
    };
    const baseline = transaction.baseline_revision;
    try transaction.commit(io, dir, path, live);
    return .{ .kind = std.meta.activeTag(request), .source_group = original, .group = next, .commit = .{ .previous_revision = baseline, .revision = live.revision, .source_hash = live.source_hash.? } };
}
