const std = @import("std");

/// The user data location shared by application settings, host assets and logs.
/// Paths are owned, so callers may release the account source immediately.
pub const Paths = struct {
    allocator: std.mem.Allocator,
    directory: []u8,
    config: []u8,
    hosts: []u8,
    known_hosts: []u8,
    cache_directory: []u8,
    diagnostic_directory: []u8,
    legacy_directory: ?[]u8 = null,
    home_directory: ?[]u8 = null,
    is_override: bool = true,

    pub const bundle_id = "com.zerowork.app";

    pub fn forApplication(allocator: std.mem.Allocator) !Paths {
        if (@import("../testing/data_directory.zig").override()) |directory| return fromDirectory(allocator, directory);
        const home = try @import("../platform/account.zig").home(allocator);
        defer allocator.free(home);
        return fromHome(allocator, home);
    }

    pub fn fromHome(allocator: std.mem.Allocator, home: []const u8) !Paths {
        const clean = std.mem.trimEnd(u8, home, "/");
        if (!isSafeAbsolute(clean)) return error.InvalidHomeDirectory;
        const directory = try std.fs.path.join(allocator, &.{ clean, "Library", "Application Support", bundle_id });
        defer allocator.free(directory);
        var result = try fromDirectory(allocator, directory);
        errdefer result.deinit();
        const known_hosts = try std.fs.path.join(allocator, &.{ clean, ".ssh", "known_hosts" });
        allocator.free(result.known_hosts);
        result.known_hosts = known_hosts;
        const cache = try std.fs.path.join(allocator, &.{ clean, "Library", "Caches", bundle_id });
        allocator.free(result.cache_directory);
        result.cache_directory = cache;
        const diagnostics = try std.fs.path.join(allocator, &.{ clean, "Library", "Logs", bundle_id });
        allocator.free(result.diagnostic_directory);
        result.diagnostic_directory = diagnostics;
        result.legacy_directory = try std.fs.path.join(allocator, &.{ clean, ".zerowork" });
        result.home_directory = try allocator.dupe(u8, clean);
        result.is_override = false;
        return result;
    }

    /// Reject lexical traversal and filesystem roots before any IO. The
    /// lifecycle additionally opens every component without following links.
    pub fn isSafeAbsolute(value: []const u8) bool {
        if (value.len < 2 or !std.fs.path.isAbsolute(value) or std.mem.indexOfScalar(u8, value, 0) != null) return false;
        var parts = std.mem.splitScalar(u8, value[1..], '/');
        var count: usize = 0;
        while (parts.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
            count += 1;
        }
        return count >= 2;
    }

    /// Explicit instance storage never changes HOME or silently falls back
    /// when an override is invalid. Its trust store is isolated alongside the
    /// instance data and never reads the account's real ~/.ssh/known_hosts.
    pub fn fromDirectory(allocator: std.mem.Allocator, data_directory: []const u8) !Paths {
        const clean = std.mem.trimEnd(u8, data_directory, "/");
        if (!isSafeAbsolute(clean)) return error.InvalidDataDirectory;
        // Overrides are instance roots, never a whole account, mounted volume,
        // OS namespace or OpenSSH's shared directory.
        for ([_][]const u8{ "/private/tmp", "/private/var", "/private/etc", "/private/var/folders", "/private/var/tmp", "/private/var/root", "/var/folders", "/var/tmp", "/opt/homebrew" }) |protected| {
            if (std.mem.eql(u8, clean, protected)) return error.InvalidDataDirectory;
        }
        var parts = std.mem.tokenizeScalar(u8, clean, '/');
        const first = parts.next().?;
        var count: usize = 1;
        while (parts.next()) |part| {
            if (std.mem.eql(u8, part, ".ssh")) return error.InvalidDataDirectory;
            count += 1;
        }
        for ([_][]const u8{ "System", "Library", "Applications", "bin", "sbin", "usr", "etc", "dev" }) |protected| {
            if (std.mem.eql(u8, first, protected)) return error.InvalidDataDirectory;
        }
        if (count == 2 and (std.mem.eql(u8, first, "Users") or std.mem.eql(u8, first, "home") or std.mem.eql(u8, first, "Volumes"))) return error.InvalidDataDirectory;
        if (std.mem.eql(u8, first, "Users") or std.mem.eql(u8, first, "home")) {
            if (count == 3) {
                for ([_][]const u8{ "Library", "Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies", "Public" }) |protected| {
                    if (std.mem.eql(u8, std.fs.path.basename(clean), protected)) return error.InvalidDataDirectory;
                }
            }
            if (count == 4 and (std.mem.endsWith(u8, clean, "/Library/Application Support") or std.mem.endsWith(u8, clean, "/Library/Caches") or std.mem.endsWith(u8, clean, "/Library/Logs"))) return error.InvalidDataDirectory;
        }
        const directory = try allocator.dupe(u8, clean);
        errdefer allocator.free(directory);
        const config = try std.fs.path.join(allocator, &.{ directory, "config.toml" });
        errdefer allocator.free(config);
        const hosts = try std.fs.path.join(allocator, &.{ directory, "hosts.toml" });
        errdefer allocator.free(hosts);
        const known_hosts = try std.fs.path.join(allocator, &.{ directory, "known_hosts" });
        errdefer allocator.free(known_hosts);
        const cache = try std.fs.path.join(allocator, &.{ directory, "cache" });
        errdefer allocator.free(cache);
        const diagnostics = try std.fs.path.join(allocator, &.{ directory, "logs" });
        return .{ .allocator = allocator, .directory = directory, .config = config, .hosts = hosts, .known_hosts = known_hosts, .cache_directory = cache, .diagnostic_directory = diagnostics };
    }

    pub fn deinit(self: *Paths) void {
        self.allocator.free(self.directory);
        self.allocator.free(self.config);
        self.allocator.free(self.hosts);
        self.allocator.free(self.known_hosts);
        self.allocator.free(self.cache_directory);
        self.allocator.free(self.diagnostic_directory);
        if (self.legacy_directory) |value| self.allocator.free(value);
        if (self.home_directory) |value| self.allocator.free(value);
        self.* = undefined;
    }
};

test "user data paths resolve under HOME and own their source" {
    var home = [_]u8{ '/', 't', 'm', 'p', '/', 'u', 's', 'e', 'r' };
    var paths = try Paths.fromHome(std.testing.allocator, &home);
    defer paths.deinit();
    @memset(&home, 'x');
    try std.testing.expectEqualStrings("/tmp/user/Library/Application Support/com.zerowork.app", paths.directory);
    try std.testing.expectEqualStrings("/tmp/user/Library/Application Support/com.zerowork.app/config.toml", paths.config);
    try std.testing.expectEqualStrings("/tmp/user/Library/Application Support/com.zerowork.app/hosts.toml", paths.hosts);
    try std.testing.expectEqualStrings("/tmp/user/.ssh/known_hosts", paths.known_hosts);
}

test "explicit data directory is absolute owned and isolated from HOME" {
    try std.testing.expectError(error.InvalidDataDirectory, Paths.fromDirectory(std.testing.allocator, ""));
    try std.testing.expectError(error.InvalidDataDirectory, Paths.fromDirectory(std.testing.allocator, "relative"));
    var directory = [_]u8{ '/', 't', 'm', 'p', '/', 'c', 'h', 'e', 'c', 'k' };
    var paths = try Paths.fromDirectory(std.testing.allocator, &directory);
    defer paths.deinit();
    @memset(&directory, 'x');
    try std.testing.expectEqualStrings("/tmp/check/config.toml", paths.config);
    try std.testing.expectEqualStrings("/tmp/check/hosts.toml", paths.hosts);
    try std.testing.expectEqualStrings("/tmp/check/known_hosts", paths.known_hosts);
}

test "application paths use the account unless explicitly isolated by the test runner" {
    var actual = try Paths.forApplication(std.testing.allocator);
    defer actual.deinit();
    const home = try @import("../platform/account.zig").home(std.testing.allocator);
    defer std.testing.allocator.free(home);
    var expected = if (@import("../testing/data_directory.zig").override()) |directory|
        try Paths.fromDirectory(std.testing.allocator, directory)
    else
        try Paths.fromHome(std.testing.allocator, home);
    defer expected.deinit();
    try std.testing.expectEqualStrings(expected.directory, actual.directory);
    try std.testing.expectEqualStrings(expected.known_hosts, actual.known_hosts);
}

test "user data paths reject missing or relative HOME" {
    try std.testing.expectError(error.InvalidHomeDirectory, Paths.fromHome(std.testing.allocator, ""));
    try std.testing.expectError(error.InvalidHomeDirectory, Paths.fromHome(std.testing.allocator, "user"));
    var paths = try Paths.fromHome(std.testing.allocator, "/tmp/user/");
    defer paths.deinit();
    try std.testing.expectEqualStrings("/tmp/user/Library/Application Support/com.zerowork.app/config.toml", paths.config);
}

test "OpenSSH trust paths remain separate from explicit instance storage and legacy TSV" {
    var standard = try Paths.fromHome(std.testing.allocator, "/tmp/fake-account");
    defer standard.deinit();
    var isolated = try Paths.fromDirectory(std.testing.allocator, "/tmp/isolated-instance");
    defer isolated.deinit();
    try std.testing.expectEqualStrings("/tmp/fake-account/.ssh/known_hosts", standard.known_hosts);
    try std.testing.expectEqualStrings("/tmp/fake-account/Library/Application Support/com.zerowork.app/config.toml", standard.config);
    try std.testing.expectEqualStrings("/tmp/isolated-instance/known_hosts", isolated.known_hosts);
    try std.testing.expect(!std.mem.startsWith(u8, isolated.known_hosts, "/tmp/fake-account/"));
    try std.testing.expect(!std.mem.eql(u8, standard.known_hosts, "/tmp/fake-account/.zerowork/known_hosts"));
}

test "path allocation failures release both default and isolated owned strings" {
    const Scenario = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var standard = try Paths.fromHome(allocator, "/tmp/fake-account");
            defer standard.deinit();
            var isolated = try Paths.fromDirectory(allocator, "/tmp/isolated-instance");
            defer isolated.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Scenario.run, .{});
}
