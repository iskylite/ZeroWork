const std = @import("std");
const hosts = @import("config/hosts.zig");
const store = @import("config/store.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const legacy =
    \\[[hosts]]
    \\name = "jump"
    \\host = "jump.test"
    \\user = "ops"
    \\group = "Production"
    \\[[hosts]]
    \\name = "target"
    \\host = "target.test"
    \\user = "ops"
    \\auth = { password = "test-secret" }
    \\totp_secret = "JBSWY3DPEHPK3PXP"
    \\group = "Production"
    \\jump_chain = ["jump"]
;

test {
    _ = @import("config/hosts.zig");
    _ = @import("config/store.zig");
}

test "asset registry legacy read is byte preserving until an explicit atomic migration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "hosts.toml", .data = legacy });
    var live = try store.loadHosts(io, tmp.dir, a, "hosts.toml");
    defer live.deinit();
    try std.testing.expect(live.needs_migration);
    try std.testing.expectEqual(@as(u64, 1), @backingInt(live.hosts[0].connection_id));
    try std.testing.expectEqual(live.hosts[0].connection_id, live.hosts[1].route[0]);
    try std.testing.expectEqual(@as(usize, 1), live.groups.len);
    const before = try tmp.dir.readFileAlloc(io, "hosts.toml", a, .limited(store.max_config_bytes));
    defer a.free(before);
    try std.testing.expectEqualStrings(legacy, before);
    var transaction = try store.HostsTransaction.init(a, &live);
    defer transaction.deinit();
    const expected = transaction.candidate.?.hosts[1].owner();
    var edited = transaction.candidate.?.hosts[1];
    edited.strict_host_key_checking = false;
    const updated = try transaction.candidate.?.update(expected, edited);
    try transaction.commit(io, tmp.dir, "hosts.toml", &live);
    try std.testing.expect(!live.needs_migration);
    try std.testing.expectEqual(expected.id, updated.id);
    try std.testing.expectEqual(expected.revision + 1, updated.revision);
    try std.testing.expect(!live.hosts[1].strict_host_key_checking);
    const encoded = try tmp.dir.readFileAlloc(io, "hosts.toml", a, .limited(store.max_config_bytes));
    defer a.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "schema_version = 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "options = { strict_host_key = false }") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "jump_chain") == null);
    var reopened = try store.loadHosts(io, tmp.dir, a, "hosts.toml");
    defer reopened.deinit();
    try std.testing.expectEqual(updated, reopened.hosts[1].owner());
    try std.testing.expectEqualSlices(hosts.identity.ConnectionId, live.groups[0].ordered_connection_ids, reopened.groups[0].ordered_connection_ids);
    try std.testing.expect(!reopened.hosts[1].strict_host_key_checking);
    const file = try tmp.dir.openFile(io, "hosts.toml", .{});
    defer file.close(io);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), (try file.stat(io)).permissions.toMode() & 0o777);
    try std.testing.expectError(error.TransactionConsumed, transaction.commit(io, tmp.dir, "hosts.toml", &live));
}

test "asset registry rejects ambiguous identities types and routes before persistence" {
    const base = "[[hosts]] name=\"n\";host=\"h\";user=\"u\";";
    const Case = struct { source: []const u8, expected: anyerror };
    for ([_]Case{
        .{ .source = base ++ "connection_id=0", .expected = error.InvalidIdentity },
        .{ .source = base ++ "connection_id=\"1\"", .expected = error.InvalidValue },
        .{ .source = base ++ "connection_id=18446744073709551616", .expected = error.InvalidValue },
        .{ .source = base ++ "revision=0", .expected = error.InvalidIdentity },
        .{ .source = base ++ "pinned=\"false\"", .expected = error.InvalidValue },
        .{ .source = base ++ "options={strict_host_key=\"false\"}", .expected = error.InvalidValue },
        .{ .source = base ++ "options={strict_host_key=false,strict_host_key=true}", .expected = error.DuplicateKey },
        .{ .source = base ++ "protocol=\"telnet\"", .expected = error.UnsupportedProtocol },
        .{ .source = base ++ "connection_id=1;route=[1]", .expected = error.RouteCycle },
        .{ .source = base ++ "connection_id=1;route=[2,2]", .expected = error.DuplicateRoute },
        .{ .source = base ++ "connection_id=1\n" ++ base ++ "connection_id=1", .expected = error.DuplicateConnectionId },
        .{ .source = "[registry] schema_version=2;revision=1;next_connection_id=1\n" ++ base ++ "connection_id=1", .expected = error.InvalidIdentityWatermark },
        .{ .source = "[[hosts]] name=\"hop\";host=\"a\";user=\"u\"\n[[hosts]] name=\"hop\";host=\"b\";user=\"u\"\n" ++ base ++ "jump_chain=[\"hop\"]", .expected = error.AmbiguousLegacyRoute },
    }) |case| try std.testing.expectError(case.expected, hosts.Registry.parse(a, case.source));
}

test "asset registry duplicate preserves protocol authentication route and options but no secrets or pinned" {
    var registry = try hosts.Registry.parse(a, legacy);
    defer registry.deinit();
    const source = registry.hosts[1].owner();
    _ = try registry.setPinned(source, true);
    const current = registry.hosts[1].owner();
    const copied = try registry.duplicate(current, "target copy");
    const copy = try registry.get(copied);
    try std.testing.expect(copy.connection_id != current.id and copy.revision == 1);
    try std.testing.expect(copy.password == null and copy.key_passphrase == null and copy.totp_secret == null and !copy.pinned);
    try std.testing.expectEqual(hosts.AuthMode.password, copy.auth_mode);
    try std.testing.expectEqualSlices(hosts.identity.ConnectionId, registry.hosts[1].route, copy.route);
    const route = try registry.resolveRoute(copied, a);
    defer a.free(route);
    try std.testing.expectEqual(@as(usize, 2), route.len);
    try std.testing.expectEqual(registry.hosts[0].connection_id, route[0].connection_id);
    var sftp = copy;
    sftp.protocol = .sftp;
    const second_protocol = try registry.add(sftp);
    try std.testing.expect(second_protocol.id != copied.id);
    const encoded = try registry.encode(a);
    defer a.free(encoded);
    var read = try hosts.Registry.parse(a, encoded);
    defer read.deinit();
    try std.testing.expectEqual(hosts.AuthMode.password, (try read.get(copied)).auth_mode);
    try std.testing.expectEqual(hosts.Protocol.sftp, (try read.get(second_protocol)).protocol);
}

test "asset registry deletion retains missing route identity and never resolves a replacement by name" {
    var registry = try hosts.Registry.parse(a, legacy);
    defer registry.deinit();
    const hop = registry.hosts[0].owner();
    const target = registry.hosts[1].owner();
    try registry.remove(hop);
    try std.testing.expectError(error.MissingRouteReference, registry.resolveRoute(target, a));
    const encoded = try registry.encode(a);
    defer a.free(encoded);
    var read = try hosts.Registry.parse(a, encoded);
    defer read.deinit();
    const replacement = try read.add(.{ .name = "jump", .host = "replacement.test", .user = "ops" });
    try std.testing.expect(@backingInt(replacement.id) > @backingInt(target.id));
    try std.testing.expectEqual(hop.id, (try read.get(target)).route[0]);
    try std.testing.expectError(error.MissingRouteReference, read.resolveRoute(target, a));
}

test "asset registry pinned view keeps base order and group operations capture original revisions" {
    var registry = try hosts.Registry.parse(a, legacy);
    defer registry.deinit();
    const group = registry.groups[0].group_id;
    const before = try a.dupe(hosts.identity.ConnectionId, registry.groups[0].ordered_connection_ids);
    defer a.free(before);
    const target = try registry.setPinned(registry.hosts[1].owner(), true);
    const view = try registry.orderedIds(a, group);
    defer a.free(view);
    try std.testing.expectEqual(target.id, view[0]);
    try std.testing.expectEqualSlices(hosts.identity.ConnectionId, before, registry.groups[0].ordered_connection_ids);
    const unpinned = try registry.setPinned(target, false);
    const restored = try registry.orderedIds(a, group);
    defer a.free(restored);
    try std.testing.expectEqualSlices(hosts.identity.ConnectionId, before, restored);
    const archive = try registry.addGroup("Archive", "blue");
    const renamed_revision = try registry.updateGroup(archive, 1, "Archived", "green", true);
    try std.testing.expectError(error.RevisionConflict, registry.updateGroup(archive, 1, "stale", "", false));
    const moved = try registry.move(unpinned, archive);
    try std.testing.expectEqual(archive, (try registry.get(moved)).asset_group_id.?);
    try std.testing.expectEqual(renamed_revision + 1, registry.groups[registry.groupIndex(archive).?].revision);
    try std.testing.expectError(error.GroupNotEmpty, registry.removeEmptyGroup(archive, renamed_revision + 1));
    try registry.remove(moved);
    try registry.removeEmptyGroup(archive, renamed_revision + 2);
    const next = try registry.addGroup("New group", "");
    try std.testing.expect(@backingInt(next) > @backingInt(archive));
}

test "asset registry persists watermarks after deleting highest identities and never wraps" {
    var registry = try hosts.Registry.parse(a, "[[hosts]] name=\"only\";host=\"h\";user=\"u\"");
    defer registry.deinit();
    const removed = registry.hosts[0].owner();
    const removed_group = try registry.addGroup("Empty", "");
    try registry.remove(removed);
    try registry.removeEmptyGroup(removed_group, 1);
    const encoded = try registry.encode(a);
    defer a.free(encoded);
    var read = try hosts.Registry.parse(a, encoded);
    defer read.deinit();
    const replacement = try read.add(.{ .name = "only", .host = "new", .user = "u" });
    const replacement_group = try read.addGroup("Empty", "");
    try std.testing.expect(@backingInt(replacement.id) > @backingInt(removed.id));
    try std.testing.expect(@backingInt(replacement_group) > @backingInt(removed_group));
    var last = try hosts.Registry.parse(a, "[registry] schema_version=2;revision=1;next_connection_id=18446744073709551615");
    defer last.deinit();
    const final_id = try last.add(.{ .name = "last", .host = "h", .user = "u" });
    try std.testing.expectEqual(std.math.maxInt(u64), @backingInt(final_id.id));
    try last.remove(final_id);
    const exhausted = try last.encode(a);
    defer a.free(exhausted);
    var reopened = try hosts.Registry.parse(a, exhausted);
    defer reopened.deinit();
    try std.testing.expectError(error.IdentityExhausted, reopened.add(.{ .name = "no wrap", .host = "h", .user = "u" }));
}

test "asset registry failed candidate edit leaves original identity revision and order intact" {
    var registry = try hosts.Registry.parse(a, legacy);
    defer registry.deinit();
    const before = try registry.encode(a);
    defer a.free(before);
    const expected = registry.hosts[1].owner();
    var invalid = registry.hosts[1];
    invalid.route = &.{ expected.id, expected.id };
    try std.testing.expectError(error.RouteCycle, registry.update(expected, invalid));
    const after = try registry.encode(a);
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
    try std.testing.expectError(error.RevisionConflict, registry.setPinned(.{ .id = expected.id, .revision = expected.revision + 1 }, true));
}

test "asset transaction competing drafts and external same revision edits cannot overwrite baseline" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "hosts.toml", .data = legacy });
    var live = try store.loadHosts(io, tmp.dir, a, "hosts.toml");
    defer live.deinit();
    var first = try store.HostsTransaction.init(a, &live);
    defer first.deinit();
    var second = try store.HostsTransaction.init(a, &live);
    defer second.deinit();
    _ = try first.candidate.?.setPinned(first.candidate.?.hosts[1].owner(), true);
    try first.commit(io, tmp.dir, "hosts.toml", &live);
    try std.testing.expectError(error.RevisionConflict, second.commit(io, tmp.dir, "hosts.toml", &live));
    try std.testing.expect(second.candidate != null);
    var external = try store.HostsTransaction.init(a, &live);
    defer external.deinit();
    _ = try external.candidate.?.setPinned(external.candidate.?.hosts[0].owner(), true);
    const current = try tmp.dir.readFileAlloc(io, "hosts.toml", a, .limited(store.max_config_bytes));
    defer a.free(current);
    const changed = try std.fmt.allocPrint(a, "{s}\n# external editor, revision unchanged\n", .{current});
    defer a.free(changed);
    try tmp.dir.writeFile(io, .{ .sub_path = "hosts.toml", .data = changed });
    const revision = live.revision;
    try std.testing.expectError(error.FileConflict, external.commit(io, tmp.dir, "hosts.toml", &live));
    try std.testing.expectEqual(revision, live.revision);
    try std.testing.expect(!live.hosts[0].pinned and live.hosts[1].pinned);
    try std.testing.expect(external.candidate.?.hosts[0].pinned);
    const retained = try tmp.dir.readFileAlloc(io, "hosts.toml", a, .limited(store.max_config_bytes));
    defer a.free(retained);
    try std.testing.expectEqualSlices(u8, changed, retained);
}

test "asset transaction real filesystem failure retains draft live bytes and revisions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "hosts.toml", .data = legacy });
    var live = try store.loadHosts(io, tmp.dir, a, "hosts.toml");
    defer live.deinit();
    var transaction = try store.HostsTransaction.init(a, &live);
    defer transaction.deinit();
    _ = try transaction.candidate.?.setPinned(transaction.candidate.?.hosts[0].owner(), true);
    // A real non-directory parent fails the file-opening path, without a mock
    // writer or an injected success/failure acknowledgement.
    try tmp.dir.writeFile(io, .{ .sub_path = "blocked", .data = "not a directory" });
    if (transaction.commit(io, tmp.dir, "blocked/hosts.toml", &live)) |_| return error.ExpectedWriteFailure else |_| {}
    try std.testing.expectEqual(@as(u64, 1), live.revision);
    try std.testing.expect(!live.hosts[0].pinned);
    try std.testing.expect(transaction.candidate.?.hosts[0].pinned);
    const retained = try tmp.dir.readFileAlloc(io, "hosts.toml", a, .limited(store.max_config_bytes));
    defer a.free(retained);
    try std.testing.expectEqualStrings(legacy, retained);
    try transaction.commit(io, tmp.dir, "hosts.toml", &live);
    try std.testing.expect(live.hosts[0].pinned);
}

test "registry rejects malformed TOTP seeds before accepting an asset" {
    const invalid = [_][]const u8{ "", "not-a-seed", "JBSWY3DP EHPK3PXP", "MZ", "MY=", "01234567" };
    for (invalid) |seed| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "[[hosts]] name=\"otp\"; host=\"otp.test\"; user=\"operator\"; totp_secret=\"{s}\"", .{seed});
        defer std.testing.allocator.free(source);
        try std.testing.expectError(error.InvalidTotpSeed, hosts.Registry.parse(std.testing.allocator, source));
    }
}
