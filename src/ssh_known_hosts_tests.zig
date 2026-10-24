const std = @import("std");
const known = @import("proto/ssh/host_key_store.zig");

const first = [_]u8{ 0, 0, 0, 11 } ++ "ssh-ed25519".* ++ [_]u8{ 0, 0, 0, 32 } ++ @as([32]u8, @splat(1));
const second = [_]u8{ 0, 0, 0, 11 } ++ "ssh-ed25519".* ++ [_]u8{ 0, 0, 0, 32 } ++ @as([32]u8, @splat(2));
const third = [_]u8{ 0, 0, 0, 11 } ++ "ssh-ed25519".* ++ [_]u8{ 0, 0, 0, 32 } ++ @as([32]u8, @splat(3));
fn key(bytes: []const u8) known.PublicKey {
    return .{ .algorithm = "ssh-ed25519", .raw = bytes };
}
fn line(allocator: std.mem.Allocator, names: []const u8, raw: []const u8, comment: []const u8) ![]u8 {
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(raw.len));
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, raw);
    return std.fmt.allocPrint(allocator, "{s} ssh-ed25519 {s}{s}\n", .{ names, encoded, comment });
}

test "known hosts raw OpenSSH records distinguish trusted changed and exact port" {
    const source = try line(std.testing.allocator, "Example.COM,alias", &first, " fixture");
    defer std.testing.allocator.free(source);
    var store = try known.HostKeyStore.parse(std.testing.allocator, source);
    defer store.deinit();
    try std.testing.expectEqual(known.Result.trusted, (try store.check("example.com", 22, key(&first))).result);
    try std.testing.expectEqual(known.Result.trusted, (try store.check("alias", 22, key(&first))).result);
    try std.testing.expectEqual(known.Result.changed, (try store.check("example.com", 22, key(&second))).result);
    try std.testing.expectEqual(known.Result.unknown, (try store.check("example.com", 2222, key(&first))).result);
}

test "known hosts explicit save is OpenSSH private and once creates no files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try known.HostKeyStore.load(std.testing.io, tmp.dir, std.testing.allocator, "known_hosts");
    defer store.deinit();
    const checked = try store.check("x", 2222, key(&first));
    try store.trust("x", 2222, key(&first), checked, .once);
    try std.testing.expectEqual(@as(usize, 0), store.records.items.len);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "known_hosts", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "known_hosts.lock", .{}));
    try store.trust("x", 2222, key(&first), checked, .save);
    var loaded = try known.HostKeyStore.load(std.testing.io, tmp.dir, std.testing.allocator, "known_hosts");
    defer loaded.deinit();
    try std.testing.expectEqual(known.Result.trusted, (try loaded.check("x", 2222, key(&first))).result);
    try std.testing.expect(std.mem.startsWith(u8, loaded.bytes(), "[x]:2222 ssh-ed25519 "));
    var file = try tmp.dir.openFile(std.testing.io, "known_hosts", .{});
    defer file.close(std.testing.io);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), (try file.stat(std.testing.io)).permissions.toMode() & 0o777);
}

test "known hosts hashed host IPv6 and nondefault port use the canonical endpoint" {
    const endpoint = try known.canonicalEndpoint(std.testing.allocator, "2001:0DB8:0:0:0:0:0:1", 2222);
    defer std.testing.allocator.free(endpoint);
    try std.testing.expectEqualStrings("[2001:db8::1]:2222", endpoint);
    const salt: [20]u8 = @splat(7);
    var hash: [20]u8 = undefined;
    std.crypto.auth.hmac.HmacSha1.create(&hash, endpoint, &salt);
    var salt64: [28]u8 = undefined;
    var hash64: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&salt64, &salt);
    _ = std.base64.standard.Encoder.encode(&hash64, &hash);
    const names = try std.fmt.allocPrint(std.testing.allocator, "|1|{s}|{s}", .{ salt64, hash64 });
    defer std.testing.allocator.free(names);
    const source = try line(std.testing.allocator, names, &first, " preserve hashed identity");
    defer std.testing.allocator.free(source);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "known_hosts", source);
    var store = try known.HostKeyStore.load(std.testing.io, tmp.dir, std.testing.allocator, "known_hosts");
    defer store.deinit();
    try std.testing.expectEqual(known.Result.trusted, (try store.check("2001:db8::1", 2222, key(&first))).result);
    try std.testing.expectEqual(known.Result.unknown, (try store.check("2001:db8::1", 22, key(&first))).result);
    const checked = try store.check("2001:db8::1", 2222, key(&second));
    try std.testing.expectEqual(known.Result.changed, checked.result);
    try store.replace("2001:db8::1", 2222, key(&second), checked, "yes");
    try std.testing.expect(std.mem.startsWith(u8, store.bytes(), names));
    try std.testing.expect(std.mem.endsWith(u8, store.bytes(), " preserve hashed identity\n"));
    try std.testing.expectEqual(known.Result.trusted, (try store.check("2001:db8::1", 2222, key(&second))).result);
}

test "known hosts revocation rejects only the matching raw key and CA errors remain explicit" {
    const revoked = try line(std.testing.allocator, "@revoked target", &first, " revoked fixture");
    defer std.testing.allocator.free(revoked);
    var store = try known.HostKeyStore.parse(std.testing.allocator, revoked);
    defer store.deinit();
    try std.testing.expectError(error.HostKeyRevoked, store.check("target", 22, key(&first)));
    try std.testing.expectEqual(known.Result.unknown, (try store.check("target", 22, key(&second))).result);
    try std.testing.expectEqual(known.Result.unknown, (try store.check("unrelated", 22, key(&first))).result);
    const ordinary = try line(std.testing.allocator, "target", &second, " another valid key");
    defer std.testing.allocator.free(ordinary);
    const combined = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}", .{ ordinary, revoked });
    defer std.testing.allocator.free(combined);
    var coexist = try known.HostKeyStore.parse(std.testing.allocator, combined);
    defer coexist.deinit();
    try std.testing.expectError(error.HostKeyRevoked, coexist.check("target", 22, key(&first)));
    try std.testing.expectEqual(known.Result.trusted, (try coexist.check("target", 22, key(&second))).result);
    try std.testing.expectEqual(known.Result.changed, (try coexist.check("target", 22, key(&third))).result);
    const ca = try line(std.testing.allocator, "@cert-authority target", &first, " retain CA");
    defer std.testing.allocator.free(ca);
    var authority = try known.HostKeyStore.parse(std.testing.allocator, ca);
    defer authority.deinit();
    try std.testing.expectError(error.UnsupportedHostCertificate, authority.check("target", 22, key(&first)));
    try std.testing.expectError(error.InvalidKnownHosts, known.HostKeyStore.parse(std.testing.allocator, "target ssh-ed25519 not-base64\n"));
    try std.testing.expectError(error.LegacyTrustMigrationRequired, known.HostKeyStore.parse(std.testing.allocator, "target\t22\ted25519\tSHA256:legacy\n"));
}

test "known hosts wildcard question mark and comma lists apply negation before any positive match" {
    for ([_][]const u8{
        "*.EXAMPLE,exact,host?,!blocked.example,!hostx",
        "!blocked.example,!hostx,*.EXAMPLE,exact,host?",
    }) |names| {
        const source = try line(std.testing.allocator, names, &first, " pattern fixture");
        defer std.testing.allocator.free(source);
        var store = try known.HostKeyStore.parse(std.testing.allocator, source);
        defer store.deinit();
        for ([_][]const u8{ "node.example", "a.b.example", "exact", "host1" }) |host| {
            try std.testing.expectEqual(known.Result.trusted, (try store.check(host, 22, key(&first))).result);
            try std.testing.expectEqual(known.Result.changed, (try store.check(host, 22, key(&second))).result);
        }
        for ([_][]const u8{ "blocked.example", "hostx", "host12", "unrelated" }) |host| try std.testing.expectEqual(known.Result.unknown, (try store.check(host, 22, key(&first))).result);
    }
    const negative_source = try line(std.testing.allocator, "!blocked,!host?", &first, " negatives do not grant trust");
    defer std.testing.allocator.free(negative_source);
    var negatives = try known.HostKeyStore.parse(std.testing.allocator, negative_source);
    defer negatives.deinit();
    try std.testing.expectEqual(known.Result.unknown, (try negatives.check("elsewhere", 22, key(&first))).result);
    const ports_source = try line(std.testing.allocator, "[*.example]:2?22,[2001:db8::*]:2222,![blocked.example]:2222", &first, " port fixture");
    defer std.testing.allocator.free(ports_source);
    var ports = try known.HostKeyStore.parse(std.testing.allocator, ports_source);
    defer ports.deinit();
    try std.testing.expectEqual(known.Result.trusted, (try ports.check("node.example", 2222, key(&first))).result);
    try std.testing.expectEqual(known.Result.trusted, (try ports.check("2001:0DB8::1", 2222, key(&first))).result);
    try std.testing.expectEqual(known.Result.unknown, (try ports.check("node.example", 22, key(&first))).result);
    try std.testing.expectEqual(known.Result.unknown, (try ports.check("blocked.example", 2222, key(&first))).result);
    try std.testing.expectError(error.InvalidKnownHosts, known.HostKeyStore.parse(std.testing.allocator, "target,,other ssh-ed25519 AA==\n"));
}

test "known hosts replacing a wildcard target preserves every other endpoint and the revoked line" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try line(std.testing.allocator, "*.example,!excluded.example,alias", &first, "\tkeep pattern comment\r");
    defer std.testing.allocator.free(target);
    const revoked = try line(std.testing.allocator, "@revoked *.example", &third, " preserve revoked key");
    defer std.testing.allocator.free(revoked);
    const source = try std.fmt.allocPrint(std.testing.allocator, "# header\n{s}{s}# final\n", .{ target, revoked });
    defer std.testing.allocator.free(source);
    try writeFile(tmp.dir, "known_hosts", source);
    var store = try known.HostKeyStore.load(std.testing.io, tmp.dir, std.testing.allocator, "known_hosts");
    defer store.deinit();
    const checked = try store.check("node.example", 22, key(&second));
    try store.replace("node.example", 22, key(&second), checked, "yes");
    try std.testing.expect(std.mem.indexOf(u8, store.bytes(), "*.example,!excluded.example,alias,!node.example ssh-ed25519 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, store.bytes(), revoked) != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, store.bytes(), "\tkeep pattern comment\r\n"));
    try std.testing.expectEqual(known.Result.trusted, (try store.check("node.example", 22, key(&second))).result);
    try std.testing.expectEqual(known.Result.changed, (try store.check("node.example", 22, key(&first))).result);
    try std.testing.expectEqual(known.Result.trusted, (try store.check("other.example", 22, key(&first))).result);
    try std.testing.expectEqual(known.Result.trusted, (try store.check("alias", 22, key(&first))).result);
    try std.testing.expectEqual(known.Result.unknown, (try store.check("excluded.example", 22, key(&first))).result);
    try std.testing.expectError(error.HostKeyRevoked, store.check("node.example", 22, key(&third)));
    try std.testing.expectError(error.RevisionConflict, store.replace("node.example", 22, key(&second), checked, "yes"));
}

test "known hosts checked replacement preserves aliases comments and unrelated bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try line(std.testing.allocator, "target,other", &first, "\tkeep original comment\r");
    defer std.testing.allocator.free(target);
    const unrelated = try line(std.testing.allocator, "untouched", &second, " another algorithm identity");
    defer std.testing.allocator.free(unrelated);
    const source = try std.fmt.allocPrint(std.testing.allocator, "# header\r\n\n{s}{s}# final comment without newline", .{ target, unrelated });
    defer std.testing.allocator.free(source);
    try writeFile(tmp.dir, "known_hosts", source);
    var store = try known.HostKeyStore.load(std.testing.io, tmp.dir, std.testing.allocator, "known_hosts");
    defer store.deinit();
    const checked = try store.check("target", 22, key(&second));
    for ([_][]const u8{ "", "y", "YES", "yes " }) |confirmation| try std.testing.expectError(error.HostKeyConfirmationRequired, store.replace("target", 22, key(&second), checked, confirmation));
    try std.testing.expectEqualStrings(source, store.bytes());
    try store.replace("target", 22, key(&second), checked, "yes");
    try std.testing.expect(std.mem.startsWith(u8, store.bytes(), "# header\r\n\n"));
    try std.testing.expect(std.mem.endsWith(u8, store.bytes(), "# final comment without newline"));
    try std.testing.expect(std.mem.indexOf(u8, store.bytes(), unrelated) != null);
    try std.testing.expectEqual(known.Result.trusted, (try store.check("other", 22, key(&first))).result);
    try std.testing.expectEqual(known.Result.trusted, (try store.check("target", 22, key(&second))).result);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, store.bytes(), "\tkeep original comment\r\n"));
    try std.testing.expectError(error.RevisionConflict, store.replace("target", 22, key(&second), checked, "yes"));
}

test "known hosts external edits and actual write failure retain disk memory and checked revision" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = try line(std.testing.allocator, "target", &first, " original");
    defer std.testing.allocator.free(source);
    try writeFile(tmp.dir, "known_hosts", source);
    var store = try known.HostKeyStore.load(std.testing.io, tmp.dir, std.testing.allocator, "known_hosts");
    defer store.deinit();
    const checked = try store.check("target", 22, key(&second));
    const external = try std.fmt.allocPrint(std.testing.allocator, "{s}# external edit\n", .{source});
    defer std.testing.allocator.free(external);
    try writeFile(tmp.dir, "known_hosts", external);
    try std.testing.expectError(error.FileConflict, store.replace("target", 22, key(&second), checked, "yes"));
    try std.testing.expectEqualStrings(source, store.bytes());
    try std.testing.expect(checked.revision.eql(store.currentRevision()));
    const disk = try tmp.dir.readFileAlloc(std.testing.io, "known_hosts", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(disk);
    try std.testing.expectEqualStrings(external, disk);
    try store.refresh();
    try std.testing.expectEqualStrings(external, store.bytes());
    try std.testing.expectError(error.RevisionConflict, store.replace("target", 22, key(&second), checked, "yes"));
    var missing = try known.HostKeyStore.load(std.testing.io, tmp.dir, std.testing.allocator, "blocked/known_hosts");
    defer missing.deinit();
    const before = try missing.check("new", 22, key(&first));
    try writeFile(tmp.dir, "blocked", "a file cannot be a parent directory");
    try std.testing.expectError(error.NotDir, missing.trust("new", 22, key(&first), before, .save));
    try std.testing.expectEqual(@as(usize, 0), missing.records.items.len);
    try std.testing.expect(before.revision.eql(missing.currentRevision()));
}

test "known hosts legacy import needs real matching keys preserves source and recovers backup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fp = known.fingerprint(key(&first));
    const legacy = try std.fmt.allocPrint(std.testing.allocator, "# private legacy source\ntarget\t2222\ted25519\t{s}=\n", .{fp.slice()});
    defer std.testing.allocator.free(legacy);
    try writeFile(tmp.dir, "legacy.tsv", legacy);
    var store = try known.HostKeyStore.load(std.testing.io, tmp.dir, std.testing.allocator, "known_hosts");
    defer store.deinit();
    try std.testing.expectError(error.LegacyKeyMaterialRequired, store.importLegacy(std.testing.io, tmp.dir, "legacy.tsv", &.{}));
    try std.testing.expectError(error.LegacyFingerprintMismatch, store.importLegacy(std.testing.io, tmp.dir, "legacy.tsv", &.{.{ .host = "target", .port = 2222, .key = key(&second) }}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "known_hosts", .{}));
    var imported = try store.importLegacy(std.testing.io, tmp.dir, "legacy.tsv", &.{.{ .host = "target", .port = 2222, .key = key(&first) }});
    defer imported.deinit();
    try std.testing.expectEqual(@as(usize, 1), imported.imported);
    try std.testing.expectEqual(known.Result.trusted, (try store.check("target", 2222, key(&first))).result);
    const original = try tmp.dir.readFileAlloc(std.testing.io, "legacy.tsv", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(original);
    const backup = try tmp.dir.readFileAlloc(std.testing.io, imported.backup_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(backup);
    try std.testing.expectEqualStrings(legacy, original);
    try std.testing.expectEqualStrings(legacy, backup);
}

fn writeFile(dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    var file = try dir.createFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, bytes);
}
