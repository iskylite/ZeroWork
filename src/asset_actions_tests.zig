const std = @import("std");
const actions = @import("config/asset_actions.zig");
const hosts = @import("config/hosts.zig");
const store = @import("config/store.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const path = "hosts.toml";

fn fixture(dir: std.Io.Dir) !hosts.Registry {
    var registry = try hosts.Registry.parse(a,
        \\[[hosts]]
        \\name="jump"; host="bridge.test"; user="ops"; group="Production"
        \\[[hosts]]
        \\name="target"; host="target.test"; user="ops"; group="Production"
        \\auth={password="password-secret"}; totp_secret="JBSWY3DPEHPK3PXP"
        \\jump_chain=["jump"]
    );
    defer registry.deinit();
    _ = try registry.add(.{ .name = "key-source", .host = "key.test", .user = "ops", .auth_mode = .private_key, .identity_file = "/tmp/key-path", .key_passphrase = "passphrase-secret", .totp_secret = "JBSWY3DPEHPK3PXP" });
    _ = try registry.addGroup("Archive", "blue");
    try store.saveHosts(io, dir, path, registry);
    return store.loadHosts(io, dir, a, path);
}

fn read(dir: std.Io.Dir) ![]u8 {
    return dir.readFileAlloc(io, path, a, .limited(store.max_config_bytes));
}

fn groupRef(registry: *const hosts.Registry, index: usize) actions.GroupRef {
    const value = registry.groups[index];
    return .{ .id = value.group_id, .revision = value.revision };
}

test "asset action clone commits new identity without secrets or pinned and preserves frozen options" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var live = try fixture(tmp.dir);
    defer live.deinit();
    const pin = try actions.apply(a, io, tmp.dir, path, &live, .{ .pin = .{ .owner = live.hosts[1].owner(), .pinned = true } });
    const original = pin.owner.?;
    const result = try actions.apply(a, io, tmp.dir, path, &live, .{ .clone = .{ .owner = original, .name = "editable-copy" } });
    const clone = try live.get(result.owner.?);
    try std.testing.expectEqual(actions.Kind.clone, result.kind);
    try std.testing.expectEqual(original, result.source_owner);
    try std.testing.expectEqual(@as(usize, 1), result.previous_index);
    try std.testing.expectEqual(@as(?usize, 3), result.index);
    try std.testing.expect(clone.connection_id != original.id);
    try std.testing.expectEqual(@as(u64, 1), clone.revision);
    try std.testing.expect(clone.password == null and clone.key_passphrase == null and clone.totp_secret == null and !clone.pinned);
    const source = try live.get(original);
    try std.testing.expectEqualStrings("password-secret", source.password.?);
    try std.testing.expectEqualStrings("JBSWY3DPEHPK3PXP", source.totp_secret.?);
    try std.testing.expect(source.pinned);
    try std.testing.expectEqual(source.asset_group_id, clone.asset_group_id);
    try std.testing.expectEqual(source.auth_mode, clone.auth_mode);
    try std.testing.expectEqual(source.protocol, clone.protocol);
    try std.testing.expectEqual(source.strict_host_key_checking, clone.strict_host_key_checking);
    try std.testing.expectEqualSlices(hosts.identity.ConnectionId, source.route, clone.route);
    const key_copy = try actions.apply(a, io, tmp.dir, path, &live, .{ .clone = .{ .owner = live.hosts[2].owner(), .name = "key-copy" } });
    const copied_key = try live.get(key_copy.owner.?);
    try std.testing.expectEqualStrings("/tmp/key-path", copied_key.identity_file.?);
    try std.testing.expect(copied_key.key_passphrase == null and copied_key.password == null and copied_key.totp_secret == null);
    var disk = try store.loadHosts(io, tmp.dir, a, path);
    defer disk.deinit();
    const saved_clone = try disk.get(result.owner.?);
    const saved_key = try disk.get(key_copy.owner.?);
    try std.testing.expectEqual(result.owner.?, saved_clone.owner());
    try std.testing.expect(saved_clone.password == null and saved_clone.key_passphrase == null and saved_clone.totp_secret == null and !saved_clone.pinned);
    try std.testing.expectEqual(hosts.AuthMode.password, saved_clone.auth_mode);
    try std.testing.expect(saved_key.password == null and saved_key.key_passphrase == null and saved_key.totp_secret == null);
    try std.testing.expectEqualStrings("/tmp/key-path", saved_key.identity_file.?);
    try std.testing.expectEqual(key_copy.commit.revision, disk.revision);
    try std.testing.expectEqualSlices(u8, &key_copy.commit.source_hash, &disk.source_hash.?);
    try std.testing.expectEqual(key_copy.commit.previous_revision + 1, key_copy.commit.revision);
}

test "asset action pin toggles persisted bool without reordering the stable registry or base group" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var live = try fixture(tmp.dir);
    defer live.deinit();
    const source = live.hosts[1].owner();
    const group = live.hosts[1].asset_group_id.?;
    const base = try a.dupe(hosts.identity.ConnectionId, live.groups[live.groupIndex(group).?].ordered_connection_ids);
    defer a.free(base);
    const pinned = try actions.apply(a, io, tmp.dir, path, &live, .{ .pin = .{ .owner = source, .pinned = true } });
    try std.testing.expect((try live.get(pinned.owner.?)).pinned);
    try std.testing.expectEqual(source.id, live.hosts[1].connection_id);
    try std.testing.expectEqualSlices(hosts.identity.ConnectionId, base, live.groups[live.groupIndex(group).?].ordered_connection_ids);
    const ordered = try live.orderedIds(a, group);
    defer a.free(ordered);
    try std.testing.expectEqual(source.id, ordered[0]);
    var disk = try store.loadHosts(io, tmp.dir, a, path);
    defer disk.deinit();
    try std.testing.expect((try disk.get(pinned.owner.?)).pinned);
    try std.testing.expectError(error.RevisionConflict, actions.apply(a, io, tmp.dir, "must-not-write/hosts.toml", &live, .{ .pin = .{ .owner = source, .pinned = false } }));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "must-not-write", .{}));
    const unpinned = try actions.apply(a, io, tmp.dir, path, &live, .{ .pin = .{ .owner = pinned.owner.?, .pinned = false } });
    try std.testing.expect(!(try live.get(unpinned.owner.?)).pinned);
    const restored = try live.orderedIds(a, group);
    defer a.free(restored);
    try std.testing.expectEqualSlices(hosts.identity.ConnectionId, base, restored);
}

test "asset action move validates both group revisions and delete retains route and independent snapshots" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var live = try fixture(tmp.dir);
    defer live.deinit();
    var frozen = try live.clone(a);
    defer frozen.deinit();
    const source = live.hosts[1].owner();
    const source_group = groupRef(&live, 0);
    const destination = groupRef(&live, 1);
    var stale = destination;
    stale.revision += 1;
    try std.testing.expectError(error.RevisionConflict, actions.apply(a, io, tmp.dir, "must-not-write/hosts.toml", &live, .{ .move = .{ .owner = source, .source_group = source_group, .destination = stale } }));
    try std.testing.expectError(error.RevisionConflict, actions.apply(a, io, tmp.dir, "must-not-write/hosts.toml", &live, .{ .move = .{ .owner = source, .source_group = null, .destination = destination } }));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "must-not-write", .{}));
    const moved = try actions.apply(a, io, tmp.dir, path, &live, .{ .move = .{ .owner = source, .source_group = source_group, .destination = destination } });
    const current = try live.get(moved.owner.?);
    try std.testing.expectEqual(source.id, current.connection_id);
    try std.testing.expectEqual(destination.id, current.asset_group_id.?);
    try std.testing.expectEqualStrings("password-secret", current.password.?);
    try std.testing.expectEqualSlices(hosts.identity.ConnectionId, frozen.hosts[1].route, current.route);
    try std.testing.expectEqual(source_group.id, (try frozen.get(source)).asset_group_id.?);
    const jump = live.hosts[0].owner();
    const deleted = try actions.apply(a, io, tmp.dir, path, &live, .{ .delete = .{ .owner = jump } });
    try std.testing.expectEqual(actions.Kind.delete, deleted.kind);
    try std.testing.expect(deleted.owner == null and deleted.index == null);
    try std.testing.expectEqual(@as(usize, 0), deleted.previous_index);
    try std.testing.expect(live.indexOf(jump.id) == null);
    try std.testing.expectEqual(jump.id, (try live.get(moved.owner.?)).route[0]);
    try std.testing.expectError(error.MissingRouteReference, live.resolveRoute(moved.owner.?, a));
    try std.testing.expectEqualStrings("bridge.test", (try frozen.get(jump)).host);
    var disk = try store.loadHosts(io, tmp.dir, a, path);
    defer disk.deinit();
    try std.testing.expect(disk.indexOf(jump.id) == null);
    try std.testing.expectEqual(destination.id, (try disk.get(moved.owner.?)).asset_group_id.?);
    try std.testing.expectEqual(@as(usize, 2), disk.groups.len);
}

test "asset action filesystem and external revision conflicts retain live and disk without consuming ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var live = try fixture(tmp.dir);
    defer live.deinit();
    const original = try live.encode(a);
    defer a.free(original);
    const before = try read(tmp.dir);
    defer a.free(before);
    const expected = live.hosts[1].owner();
    const next_id = live.connection_ids.next_value;
    try tmp.dir.writeFile(io, .{ .sub_path = "blocked", .data = "not a directory" });
    const requests: []const actions.Request = &.{
        .{ .clone = .{ .owner = expected, .name = "failed-copy" } },
        .{ .pin = .{ .owner = expected, .pinned = true } },
        .{ .move = .{ .owner = expected, .source_group = groupRef(&live, 0), .destination = groupRef(&live, 1) } },
        .{ .delete = .{ .owner = expected } },
    };
    for (requests) |request| {
        try std.testing.expectError(error.NotDir, actions.apply(a, io, tmp.dir, "blocked/hosts.toml", &live, request));
        const retained = try live.encode(a);
        defer a.free(retained);
        try std.testing.expectEqualStrings(original, retained);
        try std.testing.expectEqual(next_id, live.connection_ids.next_value);
        try std.testing.expectEqual(expected, live.hosts[1].owner());
        const unchanged = try read(tmp.dir);
        defer a.free(unchanged);
        try std.testing.expectEqualStrings(before, unchanged);
    }
    const edited = try std.fmt.allocPrint(a, "{s}\n# external edit without revision change\n", .{before});
    defer a.free(edited);
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = edited });
    try std.testing.expectError(error.FileConflict, actions.apply(a, io, tmp.dir, path, &live, .{ .clone = .{ .owner = expected, .name = "copy" } }));
    try std.testing.expectEqual(next_id, live.connection_ids.next_value);
    try std.testing.expectEqual(expected, live.hosts[1].owner());
    const external = try read(tmp.dir);
    defer a.free(external);
    try std.testing.expectEqualStrings(edited, external);
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = before });
    const success = try actions.apply(a, io, tmp.dir, path, &live, .{ .clone = .{ .owner = expected, .name = "copy" } });
    try std.testing.expectEqual(next_id, @backingInt(success.owner.?.id));
}

test "asset action move rejects captured group revisions after group-only changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var live = try fixture(tmp.dir);
    defer live.deinit();
    const source = live.hosts[1].owner();
    const source_group = groupRef(&live, 0);
    const destination = groupRef(&live, 1);
    var transaction = try store.HostsTransaction.init(a, &live);
    defer transaction.deinit();
    const candidate = &transaction.candidate.?;
    _ = try candidate.updateGroup(source_group.id, source_group.revision, "Production renamed", "green", false);
    _ = try candidate.updateGroup(destination.id, destination.revision, "Archive renamed", "blue", false);
    try transaction.commit(io, tmp.dir, path, &live);
    try std.testing.expectEqual(source, live.hosts[1].owner());
    const before = try read(tmp.dir);
    defer a.free(before);
    try std.testing.expectError(error.RevisionConflict, actions.apply(a, io, tmp.dir, "must-not-write/hosts.toml", &live, .{ .move = .{ .owner = source, .source_group = source_group, .destination = groupRef(&live, 1) } }));
    try std.testing.expectError(error.RevisionConflict, actions.apply(a, io, tmp.dir, "must-not-write/hosts.toml", &live, .{ .move = .{ .owner = source, .source_group = groupRef(&live, 0), .destination = destination } }));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "must-not-write", .{}));
    const after = try read(tmp.dir);
    defer a.free(after);
    try std.testing.expectEqualStrings(before, after);
    const moved = try actions.apply(a, io, tmp.dir, path, &live, .{ .move = .{ .owner = source, .source_group = groupRef(&live, 0), .destination = groupRef(&live, 1) } });
    try std.testing.expectEqual(source.id, moved.owner.?.id);
    try std.testing.expectEqual(source.revision + 1, moved.owner.?.revision);
    try std.testing.expectEqual(destination.id, (try live.get(moved.owner.?)).asset_group_id.?);
    const ungrouped = try actions.apply(a, io, tmp.dir, path, &live, .{ .move = .{ .owner = moved.owner.?, .source_group = groupRef(&live, 1), .destination = null } });
    const current = try live.get(ungrouped.owner.?);
    try std.testing.expect(current.asset_group_id == null and current.group == null);
    var disk = try store.loadHosts(io, tmp.dir, a, path);
    defer disk.deinit();
    const saved = try disk.get(ungrouped.owner.?);
    try std.testing.expect(saved.asset_group_id == null and saved.group == null);
}

test "asset action delete rejects old owner revisions and cannot delete a replacement at the same index" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var live = try fixture(tmp.dir);
    defer live.deinit();
    const source = live.hosts[1].owner();
    var retained = try @import("ui/session_lifecycle.zig").Snapshot(hosts.HostConfig).init(a, live.hosts[1]);
    defer retained.deinit();
    const pinned = try actions.apply(a, io, tmp.dir, path, &live, .{ .pin = .{ .owner = source, .pinned = true } });
    try std.testing.expectError(error.RevisionConflict, actions.apply(a, io, tmp.dir, "must-not-write/hosts.toml", &live, .{ .delete = .{ .owner = source } }));
    const deleted = try actions.apply(a, io, tmp.dir, path, &live, .{ .delete = .{ .owner = pinned.owner.? } });
    try std.testing.expectEqual(@as(usize, 1), deleted.previous_index);
    const replacement = live.hosts[1].owner();
    try std.testing.expect(replacement.id != source.id);
    try std.testing.expectError(error.ConnectionNotFound, actions.apply(a, io, tmp.dir, "must-not-write/hosts.toml", &live, .{ .delete = .{ .owner = pinned.owner.? } }));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "must-not-write", .{}));
    try std.testing.expectEqual(replacement, live.hosts[1].owner());
    try std.testing.expectEqual(source, retained.value.owner());
    try std.testing.expectEqualStrings("target.test", retained.value.host);
    try std.testing.expectEqualStrings("password-secret", retained.value.password.?);
    var disk = try store.loadHosts(io, tmp.dir, a, path);
    defer disk.deinit();
    try std.testing.expect(disk.indexOf(source.id) == null);
    try std.testing.expectEqual(replacement, disk.hosts[1].owner());
}
