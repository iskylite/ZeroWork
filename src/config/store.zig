const std = @import("std");
const config = @import("config.zig");
pub const credentials = @import("credential_store.zig");

pub const max_config_bytes = 256 * 1024;
pub const private_permissions: std.Io.File.Permissions = @fromBackingInt(@intCast(0o600));

/// Writes a complete configuration snapshot and atomically replaces the old file.
/// The temporary and final file are owner read/write only, independent of umask.
pub fn save(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, value: config.Config) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    _ = try saveWithCredentialRefs(io, dir, sub_path, value, arena.allocator());
}

/// Returns the committed provider slice and credential refs in allocator;
/// other configuration fields borrow value. Returned ownership is allocated
/// before the atomic replacement.
pub fn saveWithCredentialRefs(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, value: config.Config, allocator: std.mem.Allocator) !config.Config {
    try value.validate();
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var disk = value;
    disk.ai.providers = try allocator.dupe(config.AiProvider, value.ai.providers);
    var tx = try credentials.Transaction.init();
    defer tx.deinit();
    const baseline_source = dir.readFileAlloc(io, sub_path, a, std.Io.Limit.limited(max_config_bytes)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    const baseline = if (baseline_source) |source| try config.Config.parseWithAllocator(a, source) else null;
    for (disk.ai.providers[0..disk.ai.provider_count], 0..) |*provider, index| {
        var old = provider.api_key_ref;
        if (baseline) |old_config| {
            for (old_config.ai.providers[0..old_config.ai.provider_count], 0..) |previous, old_index| {
                if ((provider.name.len != 0 and std.mem.eql(u8, provider.name, previous.name)) or (provider.name.len == 0 and index == old_index)) {
                    old = previous.api_key_ref;
                    break;
                }
            }
        }
        provider.api_key_ref = try tx.stage(io, allocator, if (provider.api_key.len != 0) provider.api_key else null, old);
    }
    if (baseline) |old| for (old.ai.providers[0..old.ai.provider_count]) |provider| {
        if (provider.api_key_ref) |reference| if (!configHasReference(disk, reference)) try tx.retire(reference);
    };
    for (disk.ai.providers[0..disk.ai.provider_count]) |provider| if (provider.api_key_ref) |reference| tx.retain(reference);
    const encoded_buffer = try std.heap.page_allocator.alloc(u8, max_config_bytes);
    defer std.heap.page_allocator.free(encoded_buffer);
    const encoded = try disk.format(encoded_buffer);

    var atomic_buffer: [16 * 1024]u8 = undefined;
    var atomic = try dir.createFileAtomic(io, sub_path, .{
        .permissions = private_permissions,
        .make_path = true,
        .replace = true,
    });
    defer atomic.deinit(io);

    var writer = atomic.file.writer(io, &atomic_buffer);
    try writer.interface.writeAll(encoded);
    try writer.interface.flush();
    try atomic.file.sync(io);
    try atomic.replace(io);
    tx.commit();
    return disk;
}

/// Loads and validates one configuration snapshot. The returned config borrows
/// strings from source, which the caller owns and must retain while using it.
pub fn load(io: std.Io, dir: std.Io.Dir, allocator: std.mem.Allocator, sub_path: []const u8) !LoadedConfig {
    const source = try dir.readFileAlloc(io, sub_path, allocator, std.Io.Limit.limited(max_config_bytes));
    errdefer allocator.free(source);
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var value = try config.Config.parseWithAllocator(arena.allocator(), source);
    var migrate = false;
    for (value.ai.providers[0..value.ai.provider_count]) |*provider| {
        if (provider.api_key_ref) |reference| {
            if (provider.api_key.len != 0) return error.AmbiguousCredential;
            provider.api_key = try credentials.get(arena.allocator(), reference);
        } else if (provider.api_key.len != 0) migrate = true;
    }
    if (migrate) {
        try save(io, dir, sub_path, value);
        const migrated = try load(io, dir, allocator, sub_path);
        arena.deinit();
        allocator.free(source);
        return migrated;
    }
    return .{ .source = source, .arena = arena, .value = value };
}

pub const LoadedConfig = struct {
    source: []u8,
    arena: std.heap.ArenaAllocator,
    value: config.Config,

    pub fn deinit(self: *LoadedConfig, allocator: std.mem.Allocator) void {
        self.arena.deinit();
        allocator.free(self.source);
        self.* = undefined;
    }
};

/// Atomically writes the host registry with the same private permissions as config.toml.
pub fn saveHosts(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, registry: config.hosts.Registry) !void {
    var staged = try registry.clone(std.heap.page_allocator);
    defer staged.deinit();
    var tx = try credentials.Transaction.init();
    defer tx.deinit();
    var baseline = try readHostBaseline(io, dir, sub_path);
    defer if (baseline) |*old| old.deinit();
    try stageHosts(io, &tx, &staged, if (baseline) |*old| old else null);
    const encoded = try staged.encode(std.heap.page_allocator);
    defer std.heap.page_allocator.free(encoded);
    if (encoded.len > max_config_bytes) return error.HostRegistryTooLarge;
    const lock = try lockHosts(io, dir, sub_path);
    defer lock.close(io);
    try writeHostsEncoded(io, dir, sub_path, encoded, null);
    tx.commit();
}

const HostBaseline = struct { hash: ?config.hosts.Digest };

/// One advisory lock per file, retained across atomic replacement of the data
/// inode. Participating writers serialize; non-cooperating external edits are
/// detected by exact-byte hashes before staging and immediately before rename.
fn lockHosts(io: std.Io, dir: std.Io.Dir, sub_path: []const u8) !std.Io.File {
    if (std.fs.path.dirname(sub_path)) |parent| try dir.createDirPath(io, parent);
    const path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}.lock", .{sub_path});
    defer std.heap.page_allocator.free(path);
    return dir.createFile(io, path, .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true, .permissions = private_permissions });
}

fn checkHostsBaseline(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, expected: HostBaseline) !void {
    const bytes = dir.readFileAlloc(io, sub_path, std.heap.page_allocator, std.Io.Limit.limited(max_config_bytes)) catch |err| switch (err) {
        error.FileNotFound => if (expected.hash == null) return else return error.FileConflict,
        else => return err,
    };
    defer std.heap.page_allocator.free(bytes);
    if (!std.meta.eql(expected.hash, @as(?config.hosts.Digest, config.hosts.digest(bytes)))) return error.FileConflict;
}

fn writeHostsEncoded(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, encoded: []const u8, expected: ?HostBaseline) !void {
    if (expected) |baseline| try checkHostsBaseline(io, dir, sub_path, baseline);
    var atomic_buffer: [16 * 1024]u8 = undefined;
    var atomic = try dir.createFileAtomic(io, sub_path, .{
        .permissions = private_permissions,
        .make_path = true,
        .replace = true,
    });
    defer atomic.deinit(io);

    var file_writer = atomic.file.writer(io, &atomic_buffer);
    try file_writer.interface.writeAll(encoded);
    try file_writer.flush();
    try atomic.file.sync(io);
    if (expected) |baseline| try checkHostsBaseline(io, dir, sub_path, baseline);
    try atomic.replace(io);
}

/// An owned candidate of the existing Registry, not a second asset store.
/// Mutate `candidate`, then commit against the captured live/file baseline.
/// Failure retains both the draft and live registry; success publishes once.
pub const HostsTransaction = struct {
    candidate: ?config.hosts.Registry,
    baseline_revision: u64,
    baseline_hash: ?config.hosts.Digest,

    pub fn init(allocator: std.mem.Allocator, live: *const config.hosts.Registry) !HostsTransaction {
        return .{ .candidate = try live.clone(allocator), .baseline_revision = live.revision, .baseline_hash = live.source_hash };
    }

    pub fn deinit(self: *HostsTransaction) void {
        if (self.candidate) |*candidate| candidate.deinit();
        self.candidate = null;
    }

    pub fn commit(self: *HostsTransaction, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, live: *config.hosts.Registry) !void {
        const candidate = if (self.candidate) |*value| value else return error.TransactionConsumed;
        if (live.revision != self.baseline_revision or !std.meta.eql(live.source_hash, self.baseline_hash)) return error.RevisionConflict;
        var next = try candidate.clone(candidate.arena.child_allocator);
        errdefer next.deinit();
        next.revision = try config.hosts.identity.advance(self.baseline_revision);
        next.needs_migration = false;
        var tx = try credentials.Transaction.init();
        defer tx.deinit();
        try stageHosts(io, &tx, &next, live);
        const encoded = try next.encode(std.heap.page_allocator);
        defer std.heap.page_allocator.free(encoded);
        if (encoded.len > max_config_bytes) return error.HostRegistryTooLarge;
        next.source_hash = config.hosts.digest(encoded);
        const lock = try lockHosts(io, dir, sub_path);
        defer lock.close(io);
        try writeHostsEncoded(io, dir, sub_path, encoded, .{ .hash = self.baseline_hash });
        // Everything after the successful rename is infallible ownership
        // transfer: a memory allocation cannot leave disk/live half committed.
        tx.commit();
        live.deinit();
        live.* = next;
        candidate.deinit();
        self.candidate = null;
    }
};

/// Loads hosts.toml into an owned registry. The source buffer is discarded after parsing.
pub fn loadHosts(io: std.Io, dir: std.Io.Dir, allocator: std.mem.Allocator, sub_path: []const u8) !config.hosts.Registry {
    return loadHostsInternal(io, dir, allocator, sub_path, true);
}
/// Import sources are read-only. Persistence happens when the registry is saved.
pub fn loadHostsForImport(io: std.Io, dir: std.Io.Dir, allocator: std.mem.Allocator, sub_path: []const u8) !config.hosts.Registry {
    return loadHostsInternal(io, dir, allocator, sub_path, false);
}
fn loadHostsInternal(io: std.Io, dir: std.Io.Dir, allocator: std.mem.Allocator, sub_path: []const u8, migrate_plaintext: bool) anyerror!config.hosts.Registry {
    const source = try dir.readFileAlloc(io, sub_path, allocator, std.Io.Limit.limited(max_config_bytes));
    defer allocator.free(source);
    var registry = try config.hosts.Registry.parse(allocator, source);
    errdefer registry.deinit();
    var migrate = false;
    for (registry.hosts) |*host| {
        inline for (.{ .{ "password", "password_ref" }, .{ "key_passphrase", "key_passphrase_ref" }, .{ "totp_secret", "totp_secret_ref" } }) |fields| {
            if (@field(host, fields[1])) |reference| {
                if (@field(host, fields[0]) != null) return error.AmbiguousCredential;
                @field(host, fields[0]) = try credentials.get(registry.arena.allocator(), reference);
            } else if (@field(host, fields[0]) != null) migrate = true;
        }
        try host.validate();
    }
    if (migrate and migrate_plaintext) {
        try saveHosts(io, dir, sub_path, registry);
        const migrated = try loadHosts(io, dir, allocator, sub_path);
        registry.deinit();
        return migrated;
    }
    return registry;
}

fn configHasReference(value: config.Config, reference: []const u8) bool {
    for (value.ai.providers[0..value.ai.provider_count]) |p| if (p.api_key_ref) |r| if (std.mem.eql(u8, r, reference)) return true;
    return false;
}
fn hostsHasReference(value: *const config.hosts.Registry, reference: []const u8) bool {
    for (value.hosts) |host| inline for (.{ "password_ref", "key_passphrase_ref", "totp_secret_ref" }) |field| {
        if (@field(host, field)) |r| if (std.mem.eql(u8, r, reference)) return true;
    };
    return false;
}
fn readHostBaseline(io: std.Io, dir: std.Io.Dir, path: []const u8) !?config.hosts.Registry {
    const source = dir.readFileAlloc(io, path, std.heap.page_allocator, std.Io.Limit.limited(max_config_bytes)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer std.heap.page_allocator.free(source);
    return try config.hosts.Registry.parse(std.heap.page_allocator, source);
}
fn stageHosts(io: std.Io, tx: *credentials.Transaction, next: *config.hosts.Registry, baseline: ?*const config.hosts.Registry) !void {
    const a = next.arena.allocator();
    for (next.hosts) |*host| {
        var old: ?config.hosts.HostConfig = null;
        if (baseline) |previous| for (previous.hosts) |candidate| {
            if (candidate.connection_id == host.connection_id) {
                old = candidate;
                break;
            }
        };
        inline for (.{ .{ "password", "password_ref" }, .{ "key_passphrase", "key_passphrase_ref" }, .{ "totp_secret", "totp_secret_ref" } }) |fields| {
            const reference = if (old) |value| @field(value, fields[1]) else @field(host, fields[1]);
            @field(host, fields[1]) = try tx.stage(io, a, @field(host, fields[0]), reference);
        }
    }
    for (next.hosts) |host| inline for (.{ "password_ref", "key_passphrase_ref", "totp_secret_ref" }) |field| {
        if (@field(host, field)) |reference| tx.retain(reference);
    };
    if (baseline) |previous| for (previous.hosts) |host| {
        inline for (.{ "password_ref", "key_passphrase_ref", "totp_secret_ref" }) |field| {
            if (@field(host, field)) |reference| if (!hostsHasReference(next, reference)) try tx.retire(reference);
        }
    };
}
/// Union of the two owned files' refs, used only after both loads succeed.
pub fn reconcileCredentials(value: config.Config, registry: *const config.hosts.Registry) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    var keep: std.ArrayList([]const u8) = .empty;
    const a = arena.allocator();
    for (value.ai.providers[0..value.ai.provider_count]) |p| if (p.api_key_ref) |r| try keep.append(a, r);
    for (registry.hosts) |host| inline for (.{ "password_ref", "key_passphrase_ref", "totp_secret_ref" }) |field| {
        if (@field(host, field)) |r| try keep.append(a, r);
    };
    try credentials.reconcileScope(keep.items);
}

/// Bootstrap must call this after filesystem migration and scope initialization,
/// before mounting windows. Missing files are empty; every other error is fatal.
pub fn prepareCredentials(io: std.Io, dir: std.Io.Dir, allocator: std.mem.Allocator, config_path: []const u8, hosts_path: []const u8) !void {
    // Validate both source files before collecting unreferenced crash leftovers.
    // Cleanup refusal blocks new staging, even across repeated failed startups.
    {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const source = dir.readFileAlloc(io, config_path, a, std.Io.Limit.limited(max_config_bytes)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        const raw_config: config.Config = if (source) |text| try config.Config.parseWithAllocator(a, text) else .{};
        var raw_hosts = (try readHostBaseline(io, dir, hosts_path)) orelse try config.hosts.Registry.parse(allocator, "");
        defer raw_hosts.deinit();
        try reconcileCredentials(raw_config, &raw_hosts);
    }
    var loaded: ?LoadedConfig = load(io, dir, allocator, config_path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (loaded) |*value| value.deinit(allocator);
    var registry = loadHosts(io, dir, allocator, hosts_path) catch |err| switch (err) {
        error.FileNotFound => try config.hosts.Registry.parse(allocator, ""),
        else => return err,
    };
    defer registry.deinit();
    try reconcileCredentials(if (loaded) |value| value.value else .{}, &registry);
}

test "config persistence is atomic private and round trips" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var expected: config.Config = .{};
    expected.ui.font_size = 16;
    expected.ai.permission_mode = .auto;

    try save(std.testing.io, tmp.dir, "nested/config.toml", expected);

    var file = try tmp.dir.openFile(std.testing.io, "nested/config.toml", .{});
    defer file.close(std.testing.io);
    const stat = try file.stat(std.testing.io);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);

    var loaded = try load(std.testing.io, tmp.dir, std.testing.allocator, "nested/config.toml");
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 16), loaded.value.ui.font_size);
    try std.testing.expectEqual(config.PermissionMode.auto, loaded.value.ai.permission_mode);
}

test "configuration values larger than four kibibytes persist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const long_font = try std.testing.allocator.alloc(u8, 8192);
    defer std.testing.allocator.free(long_font);
    @memset(long_font, 'x');
    var expected: config.Config = .{};
    expected.ui.font_family = long_font;
    try save(std.testing.io, tmp.dir, "config.toml", expected);

    var loaded = try load(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 8192), loaded.value.ui.font_family.len);
}

test "replacement never leaves stale content or broadens permissions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var first: config.Config = .{};
    first.ui.font_family = "a deliberately longer font family name";
    try save(std.testing.io, tmp.dir, "config.toml", first);
    try save(std.testing.io, tmp.dir, "config.toml", .{});

    var loaded = try load(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("JetBrains Mono", loaded.value.ui.font_family);

    var file = try tmp.dir.openFile(std.testing.io, "config.toml", .{});
    defer file.close(std.testing.io);
    const stat = try file.stat(std.testing.io);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
}

test "host registry larger than four kibibytes persists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    for (0..64) |index| {
        try source.writer.print("[[hosts]]\nname=\"node-{d}\"\nhost=\"10.0.0.{d}\"\nuser=\"ops\"\nauth={{password=\"secret-{d}\"}}\nstartup_commands=[\"uptime\",\"df -h\"]\n\n", .{ index, index, index });
    }
    try std.testing.expect(source.written().len > 4096);
    var registry = try config.hosts.Registry.parse(std.testing.allocator, source.written());
    defer registry.deinit();
    try saveHosts(std.testing.io, tmp.dir, "hosts.toml", registry);

    var loaded = try loadHosts(std.testing.io, tmp.dir, std.testing.allocator, "hosts.toml");
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 64), loaded.hosts.len);
    try std.testing.expectEqualStrings("node-63", loaded.hosts[63].name);
}

test "host registry persists atomically with private permissions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source = "[[hosts]]; name=\"node\"; host=\"10.0.0.8\"; user=\"ops\"; auth={password=\"secret\"}; startup_commands=[\"uptime\"]";
    var registry = try config.hosts.Registry.parse(std.testing.allocator, source);
    defer registry.deinit();
    try saveHosts(std.testing.io, tmp.dir, "nested/hosts.toml", registry);

    var loaded = try loadHosts(std.testing.io, tmp.dir, std.testing.allocator, "nested/hosts.toml");
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.hosts.len);
    try std.testing.expectEqualStrings("secret", loaded.hosts[0].password.?);
    try std.testing.expectEqualStrings("uptime", loaded.hosts[0].startup_commands[0]);

    var file = try tmp.dir.openFile(std.testing.io, "nested/hosts.toml", .{});
    defer file.close(std.testing.io);
    const stat = try file.stat(std.testing.io);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
}
