const std = @import("std");
const Paths = @import("config/paths.zig").Paths;
const lifecycle = @import("config/data_lifecycle.zig");
const io = std.testing.io;
const allocator = std.testing.allocator;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    home: [:0]u8,
    paths: Paths,

    fn init(override: bool) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDir(io, "account", .default_dir);
        const home = try tmp.dir.realPathFileAlloc(io, "account", allocator);
        errdefer allocator.free(home);
        const paths = if (override) try Paths.fromDirectory(allocator, home) else try Paths.fromHome(allocator, home);
        return .{ .tmp = tmp, .home = home, .paths = paths };
    }

    fn deinit(self: *Fixture) void {
        self.paths.deinit();
        allocator.free(self.home);
        self.tmp.cleanup();
    }

    fn write(self: *Fixture, name: []const u8, bytes: []const u8) !void {
        if (std.fs.path.dirname(name)) |parent| try self.tmp.dir.createDirPath(io, parent);
        try self.tmp.dir.writeFile(io, .{ .sub_path = name, .data = bytes });
    }

    fn expect(self: *Fixture, name: []const u8, bytes: []const u8) !void {
        const actual = try self.tmp.dir.readFileAlloc(io, name, allocator, .limited(1024 * 1024));
        defer allocator.free(actual);
        try std.testing.expectEqualStrings(bytes, actual);
    }
};
const support = "account/Library/Application Support/com.zerowork.app/";
const diagnostics = "account/Library/Logs/com.zerowork.app/";

test "storage paths standard roots override roots and dangerous lexical input" {
    var normal = try Paths.fromHome(allocator, "/tmp/fake-account");
    defer normal.deinit();
    try std.testing.expectEqualStrings("/tmp/fake-account/Library/Caches/com.zerowork.app", normal.cache_directory);
    try std.testing.expectEqualStrings("/tmp/fake-account/Library/Logs/com.zerowork.app", normal.diagnostic_directory);
    try std.testing.expectEqualStrings("/tmp/fake-account/.zerowork", normal.legacy_directory.?);
    try std.testing.expect(!normal.is_override);
    var isolated = try Paths.fromDirectory(allocator, "/tmp/isolated/");
    defer isolated.deinit();
    try std.testing.expectEqualStrings("/tmp/isolated/cache", isolated.cache_directory);
    try std.testing.expectEqualStrings("/tmp/isolated/logs", isolated.diagnostic_directory);
    try std.testing.expectEqualStrings("/tmp/isolated/known_hosts", isolated.known_hosts);
    try std.testing.expect(isolated.legacy_directory == null);
    for ([_][]const u8{ "/", "/Users", "/tmp/../Users/account", "/tmp/./instance", "/tmp//instance", "/Users/someone", "/home/someone", "/Volumes/drive", "/usr/local", "/private/tmp", "/private/var/folders", "/opt/homebrew", "/Users/someone/.ssh", "/Users/someone/Library", "/Users/someone/Library/Application Support", "/Users/someone/Library/Caches", "/Users/someone/Documents", "relative" }) |value| {
        try std.testing.expectError(error.InvalidDataDirectory, Paths.fromDirectory(allocator, value));
    }
}

test "legacy migration moves original files unknown keys history and routes only diagnostics then repeats" {
    var f = try Fixture.init(false);
    defer f.deinit();
    try f.write("account/.zerowork/config.toml", "secret=\"legacy\"\nunknown=42\n");
    try f.write("account/.zerowork/hosts.toml", "hosts original bytes");
    try f.write("account/.zerowork/custom/unknown.bin", "unknown");
    try f.write("account/.zerowork/logs/session.raw", "raw session");
    try f.write("account/.zerowork/logs/history/session.cast", "cast session");
    try f.write("account/.zerowork/logs/app-20261024.log", "diagnostic");
    try f.write("account/.zerowork/logs/app-20261024.log.1", "rotated");
    const report = try lifecycle.prepare(io, &f.paths);
    try std.testing.expect(report.migrated_legacy);
    try std.testing.expectEqual(@as(usize, 2), report.moved_diagnostic_files);
    try f.expect(support ++ "config.toml", "secret=\"legacy\"\nunknown=42\n");
    try f.expect(support ++ "hosts.toml", "hosts original bytes");
    try f.expect(support ++ "custom/unknown.bin", "unknown");
    try f.expect(support ++ "logs/session.raw", "raw session");
    try f.expect(support ++ "logs/history/session.cast", "cast session");
    try f.expect(diagnostics ++ "app-20261024.log", "diagnostic");
    try f.expect(diagnostics ++ "app-20261024.log.1", "rotated");
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.statFile(io, "account/.zerowork", .{}));
    const config_stat = try f.tmp.dir.statFile(io, support ++ "config.toml", .{});
    const dir_stat = try f.tmp.dir.statFile(io, support ++ "custom", .{});
    try std.testing.expectEqual(@as(u16, 0o600), @as(u16, @intCast(@backingInt(config_stat.permissions))) & 0o777);
    try std.testing.expectEqual(@as(u16, 0o700), @as(u16, @intCast(@backingInt(dir_stat.permissions))) & 0o777);
    const again = try lifecycle.prepare(io, &f.paths);
    try std.testing.expect(!again.migrated_legacy);
    try std.testing.expectEqual(@as(usize, 0), again.moved_diagnostic_files);
}

test "existing target never overwrites conflict and partial migration resumes without duplicate secrets" {
    var f = try Fixture.init(false);
    defer f.deinit();
    try f.write("account/.zerowork/config.toml", "old secret");
    try f.write("account/.zerowork/custom.txt", "legacy custom");
    try f.write(support ++ "config.toml", "new secret");
    try std.testing.expectError(error.LegacyConflict, lifecycle.prepare(io, &f.paths));
    try f.expect(support ++ "config.toml", "new secret");
    try f.expect("account/.zerowork/config.toml", "old secret");
    // Resolving the conflict to byte equality lets retry deduplicate safely.
    try f.write(support ++ "config.toml", "old secret");
    _ = try lifecycle.prepare(io, &f.paths);
    try f.expect(support ++ "custom.txt", "legacy custom");
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.statFile(io, "account/.zerowork", .{}));
}

test "diagnostic collision preserves both originals and retry recovers after whole directory move" {
    var f = try Fixture.init(false);
    defer f.deinit();
    try f.write("account/.zerowork/config.toml", "original");
    try f.write("account/.zerowork/logs/app-old.log", "old");
    try f.write(diagnostics ++ "app-old.log", "new");
    try std.testing.expectError(error.LegacyConflict, lifecycle.prepare(io, &f.paths));
    try f.expect(support ++ "config.toml", "original");
    try f.expect(support ++ "logs/app-old.log", "old");
    try f.expect(diagnostics ++ "app-old.log", "new");
    try f.tmp.dir.deleteFile(io, diagnostics ++ "app-old.log");
    _ = try lifecycle.prepare(io, &f.paths);
    try f.expect(diagnostics ++ "app-old.log", "old");
}

test "migration rejects source and parent symlinks without touching external sentinel" {
    var f = try Fixture.init(false);
    defer f.deinit();
    try f.write("outside/sentinel", "outside");
    const outside = try f.tmp.dir.realPathFileAlloc(io, "outside", allocator);
    defer allocator.free(outside);
    try f.tmp.dir.symLink(io, outside, "account/.zerowork", .{ .is_directory = true });
    try std.testing.expectError(error.UnsafeSymlink, lifecycle.prepare(io, &f.paths));
    try f.expect("outside/sentinel", "outside");
    try f.tmp.dir.deleteFile(io, "account/.zerowork");
    try f.write("account/.zerowork/config.toml", "legacy");
    try f.tmp.dir.symLink(io, outside, "account/.zerowork/link", .{ .is_directory = true });
    try std.testing.expectError(error.UnsafeSymlink, lifecycle.prepare(io, &f.paths));
    try f.expect("outside/sentinel", "outside");
    try f.tmp.dir.deleteFile(io, "account/.zerowork/link");
    try f.tmp.dir.symLink(io, outside, "account/Library", .{ .is_directory = true });
    try std.testing.expectError(error.UnsafeSymlink, lifecycle.prepare(io, &f.paths));
    try f.expect("outside/sentinel", "outside");
}

test "erase removes all owned roots and legacy but never shared SSH external files or exports" {
    var f = try Fixture.init(false);
    defer f.deinit();
    _ = try lifecycle.prepare(io, &f.paths);
    try f.write(support ++ "config.toml", "data");
    try f.write("account/Library/Caches/com.zerowork.app/cache", "cache");
    try f.write(diagnostics ++ "app-old.log", "diagnostic");
    try f.write("account/.zerowork/hosts.toml", "residual legacy");
    try f.write("account/.ssh/known_hosts", "shared trust");
    try f.write("account/.ssh/id_ed25519", "external key");
    try f.write("account/export.cast", "user export");
    try f.write("outside/sentinel", "outside");
    const outside = try f.tmp.dir.realPathFileAlloc(io, "outside", allocator);
    defer allocator.free(outside);
    try f.tmp.dir.symLink(io, outside, support ++ "link", .{ .is_directory = true });
    const report = try lifecycle.eraseOwned(io, &f.paths);
    try std.testing.expect(report.succeeded());
    try std.testing.expectEqual(@as(usize, 4), report.count);
    for ([_][]const u8{ support, "account/Library/Caches/com.zerowork.app", diagnostics, "account/.zerowork" }) |root| {
        try std.testing.expectError(error.FileNotFound, f.tmp.dir.statFile(io, root, .{}));
    }
    try f.expect("account/.ssh/known_hosts", "shared trust");
    try f.expect("account/.ssh/id_ed25519", "external key");
    try f.expect("account/export.cast", "user export");
    try f.expect("outside/sentinel", "outside");
    _ = try lifecycle.prepare(io, &f.paths);
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.statFile(io, support ++ "config.toml", .{}));
}

test "partial erase reports root errors and pending marker prevents legacy resurrection then retry succeeds" {
    var f = try Fixture.init(false);
    defer f.deinit();
    _ = try lifecycle.prepare(io, &f.paths);
    try f.write(support ++ "config.toml", "data");
    try f.write("outside/sentinel", "outside");
    const outside = try f.tmp.dir.realPathFileAlloc(io, "outside", allocator);
    defer allocator.free(outside);
    try f.tmp.dir.symLink(io, outside, "account/.zerowork", .{ .is_directory = true });
    const report = try lifecycle.eraseOwned(io, &f.paths);
    try std.testing.expect(!report.succeeded());
    try std.testing.expectEqual(error.UnsafeSymlink, report.items[0].failure.?);
    try std.testing.expectEqual(error.ResetIncomplete, report.items[3].failure.?);
    try std.testing.expectError(error.ResetIncomplete, lifecycle.prepare(io, &f.paths));
    try f.expect(support ++ "config.toml", "data");
    try f.expect("outside/sentinel", "outside");
    try f.tmp.dir.deleteFile(io, "account/.zerowork");
    try std.testing.expect((try lifecycle.eraseOwned(io, &f.paths)).succeeded());
    _ = try lifecycle.prepare(io, &f.paths);
}

test "override migration and erase stay inside instance and reject tampered derived roots" {
    var f = try Fixture.init(true);
    defer f.deinit();
    try f.write("account/config.toml", "instance");
    try f.write("account/.zerowork/config.toml", "instance child");
    try f.write("outside/known_hosts", "outside trust");
    _ = try lifecycle.prepare(io, &f.paths);
    try f.expect("account/config.toml", "instance");
    try f.expect("account/.zerowork/config.toml", "instance child");
    const original = f.paths.cache_directory;
    f.paths.cache_directory = try allocator.dupe(u8, "/");
    try std.testing.expectError(error.InvalidOwnedPaths, lifecycle.eraseOwned(io, &f.paths));
    allocator.free(f.paths.cache_directory);
    f.paths.cache_directory = original;
    const report = try lifecycle.eraseOwned(io, &f.paths);
    try std.testing.expect(report.succeeded());
    try std.testing.expectEqual(@as(usize, 1), report.count);
    try f.expect("outside/known_hosts", "outside trust");
}

test "legacy hardlink is rejected without changing external inode permissions" {
    var f = try Fixture.init(false);
    defer f.deinit();
    try f.write("outside/sentinel", "outside inode");
    try f.tmp.dir.createDirPath(io, "account/.zerowork");
    const before = try f.tmp.dir.statFile(io, "outside/sentinel", .{});
    try f.tmp.dir.hardLink("outside/sentinel", f.tmp.dir, "account/.zerowork/config.toml", io, .{});
    try std.testing.expectError(error.UnsafeHardlink, lifecycle.prepare(io, &f.paths));
    try f.expect("outside/sentinel", "outside inode");
    try std.testing.expectEqual(before.permissions, (try f.tmp.dir.statFile(io, "outside/sentinel", .{})).permissions);
}

test "begin reset persists private gate before simulated secret deletion in default and override scopes" {
    for ([_]bool{ false, true }) |isolated| {
        var f = try Fixture.init(isolated);
        defer f.deinit();
        const config = if (isolated) "account/config.toml" else support ++ "config.toml";
        const marker_path = if (isolated) "account/.reset-pending" else support ++ ".reset-pending";
        try f.write(config, "secret_ref=existing");
        try f.write("outside/simulated-keychain-secret", "credential exists");
        try lifecycle.beginReset(io, &f.paths);
        try f.expect("outside/simulated-keychain-secret", "credential exists");
        const marker = try f.tmp.dir.statFile(io, marker_path, .{ .follow_symlinks = false });
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), marker.permissions.toMode() & 0o777);
        // A process ending here must reach recovery, before any store is loaded.
        try std.testing.expectError(error.ResetIncomplete, lifecycle.prepare(io, &f.paths));
        // Simulate credentials already gone but the process dying before FS
        // erasure. The pending gate still overrides unresolved persisted refs.
        try f.tmp.dir.deleteFile(io, "outside/simulated-keychain-secret");
        try std.testing.expectError(error.ResetIncomplete, lifecycle.prepare(io, &f.paths));
        try f.expect(config, "secret_ref=existing");
        try lifecycle.beginReset(io, &f.paths);
        try std.testing.expect((try lifecycle.eraseOwned(io, &f.paths)).succeeded());
        try std.testing.expectError(error.FileNotFound, f.tmp.dir.statFile(io, marker_path, .{}));
        _ = try lifecycle.prepare(io, &f.paths);
        try std.testing.expectError(error.FileNotFound, f.tmp.dir.statFile(io, config, .{}));
    }
}

test "begin reset rejects symlink gate before simulated secret deletion" {
    var f = try Fixture.init(true);
    defer f.deinit();
    try f.write("outside/simulated-keychain-secret", "keep credential");
    const outside = try f.tmp.dir.realPathFileAlloc(io, "outside/simulated-keychain-secret", allocator);
    defer allocator.free(outside);
    try f.tmp.dir.symLink(io, outside, "account/.reset-pending", .{});
    try std.testing.expectError(error.UnsafeSymlink, lifecycle.beginReset(io, &f.paths));
    try f.expect("outside/simulated-keychain-secret", "keep credential");
}

test "data deletion permission failure preserves pending gate until retry for default and override" {
    if (std.c.geteuid() == 0) return error.SkipZigTest;
    for ([_]bool{ false, true }) |isolated| {
        var f = try Fixture.init(isolated);
        defer f.deinit();
        const blocked_path = if (isolated) "account/blocked" else support ++ "blocked";
        const kept_path = if (isolated) "account/blocked/kept" else support ++ "blocked/kept";
        const marker_path = if (isolated) "account/.reset-pending" else support ++ ".reset-pending";
        try f.write(kept_path, "undeletable until permissions restored");
        try lifecycle.beginReset(io, &f.paths);
        var blocked = try f.tmp.dir.openDir(io, blocked_path, .{ .iterate = true, .follow_symlinks = false });
        defer blocked.close(io);
        // Read+search permits iteration but no unlink within this subtree.
        try blocked.setPermissions(io, @fromBackingInt(0o500));
        defer blocked.setPermissions(io, @fromBackingInt(0o700)) catch {};
        const report = try lifecycle.eraseOwned(io, &f.paths);
        try std.testing.expect(!report.succeeded());
        const data_item = report.items[report.count - 1];
        try std.testing.expectEqual(lifecycle.Area.data, data_item.area);
        try std.testing.expect(data_item.failure.? == error.AccessDenied or data_item.failure.? == error.PermissionDenied);
        try f.expect(kept_path, "undeletable until permissions restored");
        const marker = try f.tmp.dir.statFile(io, marker_path, .{ .follow_symlinks = false });
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), marker.permissions.toMode() & 0o777);
        try std.testing.expectError(error.ResetIncomplete, lifecycle.prepare(io, &f.paths));
        try blocked.setPermissions(io, @fromBackingInt(0o700));
        try std.testing.expect((try lifecycle.eraseOwned(io, &f.paths)).succeeded());
        _ = try lifecycle.prepare(io, &f.paths);
        try std.testing.expectError(error.FileNotFound, f.tmp.dir.statFile(io, kept_path, .{}));
    }
}

test "final data rmdir permission failure restores synced pending gate in default and override" {
    if (std.c.geteuid() == 0) return error.SkipZigTest;
    for ([_]bool{ false, true }) |isolated| {
        var f = try Fixture.init(isolated);
        defer f.deinit();
        const config = if (isolated) "account/config.toml" else support ++ "config.toml";
        const marker_path = if (isolated) "account/.reset-pending" else support ++ ".reset-pending";
        try f.write(config, "credentials already removed");
        try lifecycle.beginReset(io, &f.paths);
        var parent = try std.Io.Dir.openDirAbsolute(io, std.fs.path.dirname(f.paths.directory).?, .{ .iterate = true, .follow_symlinks = false });
        defer parent.close(io);
        // The data root remains writable, so all contents and the marker can
        // be unlinked, but the parent's permissions reject the final rmdir.
        try parent.setPermissions(io, @fromBackingInt(0o500));
        defer parent.setPermissions(io, @fromBackingInt(0o700)) catch {};
        const report = try lifecycle.eraseOwned(io, &f.paths);
        try std.testing.expect(!report.succeeded());
        const failure = report.items[report.count - 1].failure.?;
        try std.testing.expect(failure == error.AccessDenied or failure == error.PermissionDenied);
        try std.testing.expectError(error.FileNotFound, f.tmp.dir.statFile(io, config, .{}));
        const marker = try f.tmp.dir.statFile(io, marker_path, .{ .follow_symlinks = false });
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), marker.permissions.toMode() & 0o777);
        try std.testing.expectError(error.ResetIncomplete, lifecycle.prepare(io, &f.paths));
        try parent.setPermissions(io, @fromBackingInt(0o700));
        try std.testing.expect((try lifecycle.eraseOwned(io, &f.paths)).succeeded());
        _ = try lifecycle.prepare(io, &f.paths);
    }
}

test {
    _ = @import("platform/applog.zig");
}
