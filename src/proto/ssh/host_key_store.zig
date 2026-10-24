//! OpenSSH known_hosts with byte-preserving edits and checked atomic commits.
//! A legacy fingerprint is not a public key and cannot establish new trust.
const std = @import("std");
const c = @import("generated_ssh_session");
const Library = @import("session.zig").Library;

pub const max_file_bytes = 4 * 1024 * 1024;
const max_key_bytes = 64 * 1024;
pub const Digest = [32]u8;
pub const Algorithm = enum {
    @"ssh-rsa",
    @"ssh-dss",
    @"ssh-ed25519",
    @"ecdsa-sha2-nistp256",
    @"ecdsa-sha2-nistp384",
    @"ecdsa-sha2-nistp521",
};
pub const PublicKey = struct {
    algorithm: []const u8,
    raw: []const u8,

    pub fn fromRaw(raw: []const u8) !PublicKey {
        var cursor: Cursor = .{ .bytes = raw };
        const algorithm = try cursor.string();
        const key: PublicKey = .{ .algorithm = algorithm, .raw = raw };
        try key.validate();
        return key;
    }

    pub fn validate(self: PublicKey) !void {
        if (self.raw.len == 0 or self.raw.len > max_key_bytes) return error.InvalidHostKey;
        const algorithm = try parseAlgorithm(self.algorithm);
        var cursor: Cursor = .{ .bytes = self.raw };
        if (!std.mem.eql(u8, try cursor.string(), self.algorithm)) return error.InvalidHostKey;
        switch (algorithm) {
            .@"ssh-ed25519" => if ((try cursor.string()).len != 32) return error.InvalidHostKey,
            .@"ssh-rsa" => {
                try positiveMpint(try cursor.string());
                try positiveMpint(try cursor.string());
            },
            .@"ssh-dss" => for (0..4) |_| try positiveMpint(try cursor.string()),
            .@"ecdsa-sha2-nistp256", .@"ecdsa-sha2-nistp384", .@"ecdsa-sha2-nistp521" => {
                if (!std.mem.eql(u8, try cursor.string(), self.algorithm[11..])) return error.InvalidHostKey;
                const point = try cursor.string();
                const length: usize = switch (algorithm) {
                    .@"ecdsa-sha2-nistp256" => 65,
                    .@"ecdsa-sha2-nistp384" => 97,
                    else => 133,
                };
                if (point.len != length or point[0] != 4) return error.InvalidHostKey;
            },
        }
        if (cursor.position != self.raw.len) return error.InvalidHostKey;
    }
};

pub const Fingerprint = struct {
    bytes: [50]u8,
    pub fn slice(self: *const Fingerprint) []const u8 {
        return &self.bytes;
    }
};
pub fn fingerprint(key: PublicKey) Fingerprint {
    return fingerprintDigest(digest(key.raw));
}
fn fingerprintDigest(value: Digest) Fingerprint {
    var result: Fingerprint = undefined;
    @memcpy(result.bytes[0..7], "SHA256:");
    _ = std.base64.standard_no_pad.Encoder.encode(result.bytes[7..], &value);
    return result;
}
pub fn digest(bytes: []const u8) Digest {
    var result: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}
pub const Revision = struct {
    sequence: u64,
    file_hash: ?Digest,
    pub fn eql(self: Revision, other: Revision) bool {
        return self.sequence == other.sequence and std.meta.eql(self.file_hash, other.file_hash);
    }
};
pub const Result = enum { unknown, trusted, changed };
pub const KeyIdentity = struct {
    algorithm: Algorithm,
    hash: Digest,
    pub fn fingerprint(self: KeyIdentity) Fingerprint {
        return fingerprintDigest(self.hash);
    }
};
pub const Verification = struct {
    result: Result,
    revision: Revision,
    endpoint_hash: Digest,
    received_key: Digest,
    old_key: ?KeyIdentity = null,
};
pub const LegacyResolution = struct { host: []const u8, port: u16 = 22, key: PublicKey };
pub const MigrationResult = struct {
    imported: usize,
    source_hash: Digest,
    backup_path: []u8,
    allocator: std.mem.Allocator,
    pub fn deinit(self: *MigrationResult) void {
        self.allocator.free(self.backup_path);
        self.* = undefined;
    }
};
const Marker = enum { ordinary, revoked, certificate_authority };
const Range = struct { start: usize, end: usize };
const Alias = struct {
    raw: []const u8,
    name: [:0]u8,
    salt: ?[:0]u8 = null,
    negated: bool = false,
    wildcard: bool = false,
    fn deinit(self: *Alias, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.salt) |salt| allocator.free(salt);
    }
};
pub const Record = struct {
    algorithm: []const u8,
    raw_key: []u8,
    start: usize,
    end: usize,
    hosts: Range,
    algorithm_range: Range,
    key_range: Range,
    marker: Marker,
    aliases: []Alias,
    native: *c.LIBSSH2_KNOWNHOSTS,

    fn deinit(self: *Record, allocator: std.mem.Allocator) void {
        c.zw_ssh_knownhosts_free(self.native);
        for (self.aliases) |*alias| alias.deinit(allocator);
        allocator.free(self.aliases);
        allocator.free(self.raw_key);
    }
    pub fn publicKey(self: *const Record) PublicKey {
        return .{ .algorithm = self.algorithm, .raw = self.raw_key };
    }
};

const Native = struct {
    library: Library,
    session: *c.LIBSSH2_SESSION,
    fn init() !Native {
        var library = try Library.init();
        errdefer library.deinit();
        return .{ .library = library, .session = c.zw_libssh2_session_create() orelse return error.OutOfMemory };
    }
    fn deinit(self: *Native) void {
        c.zw_libssh2_session_disconnect_free(self.session);
        self.library.deinit();
    }
};

pub const HostKeyStore = struct {
    allocator: std.mem.Allocator,
    source: ?[]u8 = null,
    records: std.ArrayList(Record) = .empty,
    native: ?Native = null,
    revision: u64 = 1,
    source_hash: ?Digest = null,
    persist_io: ?std.Io = null,
    persist_dir: ?std.Io.Dir = null,
    persist_path: ?[]u8 = null,
    pub const Trust = enum { once, save };
    pub const Result = @import("host_key_store.zig").Result;

    pub fn init(allocator: std.mem.Allocator) HostKeyStore {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *HostKeyStore) void {
        for (self.records.items) |*record| record.deinit(self.allocator);
        self.records.deinit(self.allocator);
        if (self.native) |*native| native.deinit();
        if (self.source) |source| self.allocator.free(source);
        if (self.persist_path) |path| self.allocator.free(path);
        self.* = undefined;
    }
    pub fn bytes(self: *const HostKeyStore) []const u8 {
        return self.source orelse &.{};
    }
    pub fn currentRevision(self: *const HostKeyStore) Revision {
        return .{ .sequence = self.revision, .file_hash = self.source_hash };
    }

    pub fn load(io: std.Io, dir: std.Io.Dir, allocator: std.mem.Allocator, path: []const u8) !HostKeyStore {
        const source = dir.readFileAlloc(io, path, allocator, .limited(max_file_bytes)) catch |err| switch (err) {
            error.FileNotFound => {
                var empty = init(allocator);
                errdefer empty.deinit();
                try empty.setPersistence(io, dir, path);
                return empty;
            },
            else => return err,
        };
        defer allocator.free(source);
        var store = try parse(allocator, source);
        errdefer store.deinit();
        store.source_hash = digest(source);
        try store.setPersistence(io, dir, path);
        return store;
    }

    pub fn parse(allocator: std.mem.Allocator, source: []const u8) !HostKeyStore {
        if (source.len > max_file_bytes) return error.KnownHostsTooLarge;
        if (std.mem.indexOfScalar(u8, source, 0) != null) return error.InvalidKnownHosts;
        var store = init(allocator);
        errdefer store.deinit();
        store.source = try allocator.dupe(u8, source);
        const owned = store.bytes();
        var offset: usize = 0;
        while (offset < owned.len) {
            const end = if (std.mem.indexOfScalarPos(u8, owned, offset, '\n')) |index| index + 1 else owned.len;
            const content = std.mem.trimEnd(u8, owned[offset..end], "\r\n");
            const trimmed = std.mem.trimStart(u8, content, " \t");
            if (trimmed.len != 0 and trimmed[0] != '#') {
                if (isLegacyLine(trimmed)) return error.LegacyTrustMigrationRequired;
                if (content.len > 128 * 1024) return error.KnownHostsLineTooLarge;
                if (store.records.items.len >= 16 * 1024) return error.KnownHostsTooLarge;
                var record = try store.parseRecord(offset, end, offset + content.len);
                errdefer record.deinit(allocator);
                try store.records.append(allocator, record);
            }
            offset = end;
        }
        return store;
    }

    pub fn setPersistence(self: *HostKeyStore, io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
        if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidTrustStorePath;
        if (self.persist_path) |old| if (!std.mem.eql(u8, old, path) or self.persist_dir.?.handle != dir.handle) return error.TrustStorePathMismatch;
        const owned = try self.allocator.dupe(u8, path);
        if (self.persist_path) |old| self.allocator.free(old);
        self.persist_io = io;
        self.persist_dir = dir;
        self.persist_path = owned;
    }

    pub fn refresh(self: *HostKeyStore) !void {
        var next = try load(self.persist_io orelse return error.TrustStoreUnavailable, self.persist_dir.?, self.allocator, self.persist_path.?);
        errdefer next.deinit();
        next.revision = try advance(self.revision);
        self.deinit();
        self.* = next;
    }

    pub fn check(self: *HostKeyStore, host: []const u8, port: u16, key: PublicKey) !Verification {
        try key.validate();
        const endpoint = try canonicalEndpoint(self.allocator, host, port);
        defer self.allocator.free(endpoint);
        var verification: Verification = .{ .result = .unknown, .revision = self.currentRevision(), .endpoint_hash = digest(endpoint), .received_key = digest(key.raw) };
        var matched = false;
        var ambiguous = false;
        var budget: MatchBudget = .{};
        for (self.records.items) |*record| {
            if (!try recordMatches(record, endpoint, key, &budget)) continue;
            const same_key = std.mem.eql(u8, record.raw_key, key.raw);
            switch (record.marker) {
                .revoked => {
                    if (same_key) return error.HostKeyRevoked;
                    // Revocation concerns this key, not every key at a host.
                    continue;
                },
                .certificate_authority => return error.UnsupportedHostCertificate,
                .ordinary => {},
            }
            if (same_key) {
                matched = true;
                continue;
            }
            const old: KeyIdentity = .{ .algorithm = try parseAlgorithm(record.algorithm), .hash = digest(record.raw_key) };
            if (verification.old_key) |previous| {
                if (!std.meta.eql(previous, old)) ambiguous = true;
            } else verification.old_key = old;
        }
        if (matched) {
            verification.result = .trusted;
            verification.old_key = null;
            return verification;
        }
        if (ambiguous) return error.AmbiguousKnownHostKey;
        if (verification.old_key != null) verification.result = .changed;
        return verification;
    }

    /// Only an explicit operation reaches a file writer. once also rechecks
    /// an existing disk baseline, but creates no lock/temporary/backup file.
    pub fn trust(self: *HostKeyStore, host: []const u8, port: u16, key: PublicKey, checked: Verification, mode: Trust) !void {
        try self.verify(host, port, key, checked);
        if (checked.result == .changed) return error.HostKeyConflict;
        if (mode == .once or checked.result == .trusted) {
            try self.verifyDisk();
            return;
        }
        var encoded: std.ArrayList(u8) = .empty;
        defer encoded.deinit(self.allocator);
        try encoded.appendSlice(self.allocator, self.bytes());
        try appendSeparator(self.allocator, &encoded);
        const endpoint = try canonicalEndpoint(self.allocator, host, port);
        defer self.allocator.free(endpoint);
        const line = try self.formatLine(endpoint, null, key);
        defer self.allocator.free(line);
        try encoded.appendSlice(self.allocator, line);
        try self.commit(encoded.items, checked.revision);
    }

    pub fn replace(self: *HostKeyStore, host: []const u8, port: u16, key: PublicKey, checked: Verification, confirmation: []const u8) !void {
        if (!std.mem.eql(u8, confirmation, "yes")) return error.HostKeyConfirmationRequired;
        try self.verify(host, port, key, checked);
        if (checked.result != .changed or checked.old_key == null) return error.HostKeyConflict;
        const endpoint = try canonicalEndpoint(self.allocator, host, port);
        defer self.allocator.free(endpoint);
        var encoded: std.ArrayList(u8) = .empty;
        defer encoded.deinit(self.allocator);
        var copied: usize = 0;
        var budget: MatchBudget = .{};
        for (self.records.items) |*record| {
            if (record.marker != .ordinary or !std.mem.eql(u8, &digest(record.raw_key), &checked.old_key.?.hash)) continue;
            if (!try recordMatches(record, endpoint, key, &budget)) continue;
            try encoded.appendSlice(self.allocator, self.bytes()[copied..record.start]);
            var remaining: std.ArrayList(u8) = .empty;
            defer remaining.deinit(self.allocator);
            var selected: ?*const Alias = null;
            var retain_pattern = false;
            for (record.aliases) |alias| if (!alias.negated and alias.wildcard) {
                retain_pattern = true;
                break;
            };
            for (record.aliases) |*alias| {
                if (alias.salt != null or (!alias.negated and !alias.wildcard and std.mem.eql(u8, alias.name, endpoint))) {
                    selected = alias;
                    continue;
                }
                if (remaining.items.len != 0) try remaining.append(self.allocator, ',');
                try remaining.appendSlice(self.allocator, alias.raw);
            }
            if (retain_pattern) {
                if (record.aliases.len >= 256) return error.KnownHostsAliasLimit;
                // Preserve the old pattern for every other endpoint. An exact
                // negation removes only this endpoint from its trust scope.
                try encoded.appendSlice(self.allocator, self.bytes()[record.start..record.hosts.end]);
                try encoded.appendSlice(self.allocator, ",!");
                try encoded.appendSlice(self.allocator, endpoint);
                try encoded.appendSlice(self.allocator, self.bytes()[record.hosts.end..record.end]);
                try appendSeparator(self.allocator, &encoded);
            } else if (remaining.items.len != 0) {
                try encoded.appendSlice(self.allocator, self.bytes()[record.start..record.hosts.start]);
                try encoded.appendSlice(self.allocator, remaining.items);
                try encoded.appendSlice(self.allocator, self.bytes()[record.hosts.end..record.end]);
                try appendSeparator(self.allocator, &encoded);
            }
            const affected = if (retain_pattern) null else selected orelse return error.KnownHostBackendFailure;
            const line = try self.formatLine(if (affected) |alias| alias.name else endpoint, if (affected) |alias| alias.salt else null, key);
            defer self.allocator.free(line);
            // Preserve the exact existing comment and newline bytes.
            try encoded.appendSlice(self.allocator, std.mem.trimEnd(u8, line, "\n"));
            try encoded.appendSlice(self.allocator, self.bytes()[record.key_range.end..record.end]);
            copied = record.end;
        }
        try encoded.appendSlice(self.allocator, self.bytes()[copied..]);
        try self.commit(encoded.items, checked.revision);
    }

    pub fn save(self: *HostKeyStore, io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
        try self.setPersistence(io, dir, path);
        try self.commit(self.bytes(), self.currentRevision());
    }

    /// Explicit import into this configured OpenSSH destination. The source is
    /// never rewritten. Every legacy fingerprint requires actual matching key
    /// material; a private recoverable byte-for-byte backup precedes the commit.
    pub fn importLegacy(self: *HostKeyStore, io: std.Io, source_dir: std.Io.Dir, source_path: []const u8, resolutions: []const LegacyResolution) !MigrationResult {
        const target_path = self.persist_path orelse return error.TrustStoreUnavailable;
        if (source_dir.handle == self.persist_dir.?.handle and std.mem.eql(u8, source_path, target_path)) return error.LegacyDestinationMustDiffer;
        const source = try source_dir.readFileAlloc(io, source_path, self.allocator, .limited(max_file_bytes));
        defer self.allocator.free(source);
        var rows: std.ArrayList(LegacyRecord) = .empty;
        defer rows.deinit(self.allocator);
        var seen = std.AutoHashMap(Digest, void).init(self.allocator);
        defer seen.deinit();
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, "\r ");
            if (line.len == 0 or line[0] == '#') continue;
            if (!isLegacyLine(line) or rows.items.len >= 16 * 1024) return error.InvalidLegacyTrustStore;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const host = fields.next().?;
            const port = std.fmt.parseInt(u16, fields.next().?, 10) catch return error.InvalidLegacyTrustStore;
            const algorithm = try legacyAlgorithm(fields.next().?);
            const expected_key = try legacyFingerprint(fields.next().?);
            const endpoint = try canonicalEndpoint(self.allocator, host, port);
            defer self.allocator.free(endpoint);
            const endpoint_hash = digest(endpoint);
            const entry = try seen.getOrPut(endpoint_hash);
            if (entry.found_existing) return error.AmbiguousLegacyTrustStore;
            try rows.append(self.allocator, .{ .host = host, .port = port, .algorithm = algorithm, .key_hash = expected_key, .endpoint_hash = endpoint_hash });
        }
        if (rows.items.len == 0) return error.NotLegacyTrustStore;
        if (resolutions.len != rows.items.len) return error.LegacyKeyMaterialRequired;
        var material = std.AutoHashMap(Digest, PublicKey).init(self.allocator);
        defer material.deinit();
        for (resolutions) |resolution| {
            try resolution.key.validate();
            const endpoint = try canonicalEndpoint(self.allocator, resolution.host, resolution.port);
            defer self.allocator.free(endpoint);
            const entry = try material.getOrPut(digest(endpoint));
            if (entry.found_existing) return error.AmbiguousLegacyTrustStore;
            entry.value_ptr.* = resolution.key;
        }
        const revision = self.currentRevision();
        var encoded: std.ArrayList(u8) = .empty;
        defer encoded.deinit(self.allocator);
        try encoded.appendSlice(self.allocator, self.bytes());
        var imported: usize = 0;
        for (rows.items) |row| {
            const key = material.get(row.endpoint_hash) orelse return error.LegacyKeyMaterialRequired;
            if (row.algorithm != try parseAlgorithm(key.algorithm) or !std.mem.eql(u8, &row.key_hash, &digest(key.raw))) return error.LegacyFingerprintMismatch;
            const checked = try self.check(row.host, row.port, key);
            if (checked.result == .changed) return error.HostKeyConflict;
            if (checked.result == .trusted) continue;
            const endpoint = try canonicalEndpoint(self.allocator, row.host, row.port);
            defer self.allocator.free(endpoint);
            const line = try self.formatLine(endpoint, null, key);
            defer self.allocator.free(line);
            try appendSeparator(self.allocator, &encoded);
            try encoded.appendSlice(self.allocator, line);
            imported += 1;
        }
        const source_hash = digest(source);
        const hex = std.fmt.bytesToHex(source_hash, .lower);
        const backup_path = try std.fmt.allocPrint(self.allocator, "{s}.zerowork-legacy-{s}.bak", .{ source_path, &hex });
        errdefer self.allocator.free(backup_path);
        const source_lock = try lockFile(self.allocator, io, source_dir, source_path);
        defer source_lock.close(io);
        try checkDisk(io, source_dir, source_path, source_hash);
        try self.verifyDisk();
        try backupLegacy(io, source_dir, backup_path, source);
        try checkDisk(io, source_dir, source_path, source_hash);
        try self.commit(encoded.items, revision);
        return .{ .imported = imported, .source_hash = source_hash, .backup_path = backup_path, .allocator = self.allocator };
    }

    fn verify(self: *HostKeyStore, host: []const u8, port: u16, key: PublicKey, checked: Verification) !void {
        if (!checked.revision.eql(self.currentRevision())) return error.RevisionConflict;
        const current = try self.check(host, port, key);
        if (!std.meta.eql(current, checked)) return error.StaleHostKeyDecision;
    }
    fn verifyDisk(self: *const HostKeyStore) !void {
        if (self.persist_io) |io| try checkDisk(io, self.persist_dir.?, self.persist_path.?, self.source_hash);
    }
    fn commit(self: *HostKeyStore, encoded: []const u8, expected: Revision) !void {
        if (!expected.eql(self.currentRevision())) return error.RevisionConflict;
        const io = self.persist_io orelse return error.TrustStoreUnavailable;
        const dir = self.persist_dir.?;
        const path = self.persist_path.?;
        var next = try parse(self.allocator, encoded);
        errdefer next.deinit();
        next.revision = try advance(self.revision);
        next.source_hash = digest(encoded);
        try next.setPersistence(io, dir, path);
        const lock = try lockFile(self.allocator, io, dir, path);
        defer lock.close(io);
        try checkDisk(io, dir, path, expected.file_hash);
        var atomic = try dir.createFileAtomic(io, path, .{ .permissions = private_permissions, .make_path = true, .replace = true });
        defer atomic.deinit(io);
        var buffer: [16 * 1024]u8 = undefined;
        var writer = atomic.file.writer(io, &buffer);
        try writer.interface.writeAll(encoded);
        try writer.interface.flush();
        try atomic.file.sync(io);
        try checkDisk(io, dir, path, expected.file_hash);
        try atomic.replace(io);
        // All allocations preceded rename. Publish cannot fail after disk did.
        self.deinit();
        self.* = next;
    }

    fn nativeSession(self: *HostKeyStore) !*c.LIBSSH2_SESSION {
        if (self.native == null) self.native = try Native.init();
        return self.native.?.session;
    }
    fn formatLine(self: *HostKeyStore, name: [:0]const u8, salt: ?[:0]const u8, key: PublicKey) ![]u8 {
        const native = c.zw_ssh_knownhosts_create(try self.nativeSession()) orelse return error.OutOfMemory;
        defer c.zw_ssh_knownhosts_free(native);
        try nativeAdd(native, name, salt, key);
        const output = try self.allocator.alloc(u8, key.raw.len * 2 + name.len + 256);
        defer self.allocator.free(output);
        var length: usize = 0;
        if (c.zw_ssh_knownhosts_write(native, output.ptr, output.len, &length) != 0) return error.KnownHostBackendFailure;
        return self.allocator.dupe(u8, output[0..length]);
    }
    fn parseRecord(self: *HostKeyStore, start: usize, end: usize, content_end: usize) !Record {
        const source = self.bytes();
        var position = start;
        var hosts = try token(source, &position, content_end);
        var marker: Marker = .ordinary;
        if (source[hosts.start] == '@') {
            const value = source[hosts.start..hosts.end];
            marker = if (std.mem.eql(u8, value, "@revoked")) .revoked else if (std.mem.eql(u8, value, "@cert-authority")) .certificate_authority else return error.UnsupportedKnownHostMarker;
            hosts = try token(source, &position, content_end);
        }
        const algorithm_range = try token(source, &position, content_end);
        const key_range = try token(source, &position, content_end);
        const algorithm = source[algorithm_range.start..algorithm_range.end];
        _ = try parseAlgorithm(algorithm);
        const raw_key = try decodeKey(self.allocator, source[key_range.start..key_range.end]);
        errdefer self.allocator.free(raw_key);
        const key: PublicKey = .{ .algorithm = algorithm, .raw = raw_key };
        key.validate() catch return error.InvalidKnownHosts;
        const native = c.zw_ssh_knownhosts_create(try self.nativeSession()) orelse return error.OutOfMemory;
        errdefer c.zw_ssh_knownhosts_free(native);
        var aliases: std.ArrayList(Alias) = .empty;
        errdefer {
            for (aliases.items) |*alias| alias.deinit(self.allocator);
            aliases.deinit(self.allocator);
        }
        var names = std.mem.splitScalar(u8, source[hosts.start..hosts.end], ',');
        while (names.next()) |name| {
            if (aliases.items.len >= 256) return error.InvalidKnownHosts;
            var alias = try parseAlias(self.allocator, name);
            errdefer alias.deinit(self.allocator);
            if (alias.salt != null and (aliases.items.len != 0 or names.peek() != null)) return error.InvalidKnownHosts;
            if (!alias.negated and !alias.wildcard) try nativeAdd(native, alias.name, alias.salt, key);
            try aliases.append(self.allocator, alias);
        }
        return .{ .algorithm = algorithm, .raw_key = raw_key, .start = start, .end = end, .hosts = hosts, .algorithm_range = algorithm_range, .key_range = key_range, .marker = marker, .aliases = try aliases.toOwnedSlice(self.allocator), .native = native };
    }
};

fn parseAlgorithm(value: []const u8) !Algorithm {
    if (std.mem.indexOf(u8, value, "-cert-") != null) return error.UnsupportedHostCertificate;
    return std.meta.stringToEnum(Algorithm, value) orelse error.UnsupportedHostKeyAlgorithm;
}
fn nativeAdd(native: *c.LIBSSH2_KNOWNHOSTS, name: [:0]const u8, salt: ?[:0]const u8, key: PublicKey) !void {
    var algorithm: [64:0]u8 = @splat(0);
    if (key.algorithm.len >= algorithm.len) return error.UnsupportedHostKeyAlgorithm;
    @memcpy(algorithm[0..key.algorithm.len], key.algorithm);
    if (c.zw_ssh_knownhosts_add_raw(native, name.ptr, if (salt) |value| value.ptr else null, &algorithm, key.raw.ptr, key.raw.len) != 0) return error.KnownHostBackendFailure;
}
fn parseAlias(allocator: std.mem.Allocator, raw: []const u8) !Alias {
    if (raw.len == 0) return error.InvalidKnownHosts;
    if (raw[0] == '|') {
        if (!std.mem.startsWith(u8, raw, "|1|")) return error.UnsupportedKnownHostHash;
        var fields = std.mem.splitScalar(u8, raw[3..], '|');
        const salt = fields.next() orelse return error.InvalidKnownHosts;
        const hash = fields.next() orelse return error.InvalidKnownHosts;
        if (fields.next() != null or salt.len != 28 or hash.len != 28) return error.InvalidKnownHosts;
        var decoded: [20]u8 = undefined;
        std.base64.standard.Decoder.decode(&decoded, salt) catch return error.InvalidKnownHosts;
        std.base64.standard.Decoder.decode(&decoded, hash) catch return error.InvalidKnownHosts;
        const name = try allocator.dupeSentinel(u8, hash, 0);
        errdefer allocator.free(name);
        return .{ .raw = raw, .name = name, .salt = try allocator.dupeSentinel(u8, salt, 0) };
    }
    const negated = raw[0] == '!';
    const value = if (negated) raw[1..] else raw;
    if (value.len == 0 or value[0] == '|') return error.InvalidKnownHosts;
    const wildcard = std.mem.indexOfAny(u8, value, "*?") != null;
    if (wildcard) {
        if (value.len > 1040) return error.KnownHostsPatternTooLarge;
        if (!std.unicode.utf8ValidateSlice(value) or std.mem.indexOfAny(u8, value, "\x00 \t\r\n,!|/@\\") != null) return error.InvalidKnownHosts;
        const name = try allocator.dupeSentinel(u8, value, 0);
        for (name) |*byte| byte.* = std.ascii.toLower(byte.*);
        return .{ .raw = raw, .name = name, .negated = negated, .wildcard = true };
    }
    var host = value;
    var port: u16 = 22;
    if (value[0] == '[') {
        const close = std.mem.indexOfScalar(u8, value, ']') orelse return error.InvalidKnownHosts;
        if (close + 2 >= value.len or value[close + 1] != ':') return error.InvalidKnownHosts;
        host = value[1..close];
        port = std.fmt.parseInt(u16, value[close + 2 ..], 10) catch return error.InvalidKnownHosts;
    }
    return .{ .raw = raw, .name = try canonicalEndpoint(allocator, host, port), .negated = negated };
}

const MatchBudget = struct {
    remaining: usize = 8 * 1024 * 1024,
    fn step(self: *MatchBudget) !void {
        if (self.remaining == 0) return error.KnownHostsPatternBudgetExceeded;
        self.remaining -= 1;
    }
};

fn recordMatches(record: *const Record, endpoint: [:0]const u8, key: PublicKey, budget: *MatchBudget) !bool {
    if (record.aliases[0].salt != null) {
        // Existing libssh2 performs OpenSSH's HMAC-SHA1 host matching.
        const result = c.zw_ssh_knownhosts_check(record.native, endpoint.ptr, key.raw.ptr, key.raw.len);
        return switch (result) {
            0, 1 => true,
            2 => false,
            else => error.KnownHostBackendFailure,
        };
    }
    var positive = false;
    for (record.aliases) |alias| {
        const matches = if (alias.wildcard) try matchPattern(alias.name, endpoint, budget) else std.mem.eql(u8, alias.name, endpoint);
        if (!matches) continue;
        if (alias.negated) return false;
        positive = true;
    }
    return positive;
}

/// OpenSSH '*'/'?' byte patterns, with no recursion, allocation or name lookup.
/// A shared per-check work budget bounds adversarial backtracking across lines.
fn matchPattern(pattern: []const u8, value: []const u8, budget: *MatchBudget) !bool {
    var p: usize = 0;
    var v: usize = 0;
    var star: ?usize = null;
    var retry: usize = 0;
    while (v < value.len) {
        try budget.step();
        if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            retry = v;
            if (p == pattern.len) return true;
        } else if (p < pattern.len and (pattern[p] == '?' or pattern[p] == value[v])) {
            p += 1;
            v += 1;
        } else if (star) |position| {
            retry += 1;
            v = retry;
            p = position + 1;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') {
        try budget.step();
        p += 1;
    }
    return p == pattern.len;
}
pub fn canonicalEndpoint(allocator: std.mem.Allocator, host_raw: []const u8, port: u16) ![:0]u8 {
    if (port == 0 or host_raw.len == 0 or host_raw.len > 1024 or !std.unicode.utf8ValidateSlice(host_raw) or std.mem.indexOfAny(u8, host_raw, "\x00 \t\r\n,*!?/@\\") != null) return error.InvalidHostKeyEndpoint;
    const host = if (host_raw[0] == '[' and host_raw[host_raw.len - 1] == ']') host_raw[1 .. host_raw.len - 1] else host_raw;
    if (host.len == 0) return error.InvalidHostKeyEndpoint;
    var normalized: []u8 = undefined;
    if (std.mem.indexOfScalar(u8, host, ':') != null) {
        const parsed = std.Io.net.Ip6Address.Unresolved.parse(host);
        normalized = switch (parsed) {
            .success => |value| try std.fmt.allocPrint(allocator, "{f}", .{value}),
            else => return error.InvalidHostKeyEndpoint,
        };
    } else {
        if (std.mem.indexOfAny(u8, host, "[]|%") != null) return error.InvalidHostKeyEndpoint;
        normalized = try allocator.dupe(u8, host);
        for (normalized) |*byte| byte.* = std.ascii.toLower(byte.*);
    }
    defer allocator.free(normalized);
    const result = if (port == 22) try allocator.dupe(u8, normalized) else try std.fmt.allocPrint(allocator, "[{s}]:{d}", .{ normalized, port });
    defer allocator.free(result);
    return allocator.dupeSentinel(u8, result, 0);
}
fn token(source: []const u8, position: *usize, end: usize) !Range {
    while (position.* < end and (source[position.*] == ' ' or source[position.*] == '\t')) position.* += 1;
    const start = position.*;
    while (position.* < end and source[position.*] != ' ' and source[position.*] != '\t') position.* += 1;
    if (start == position.*) return error.InvalidKnownHosts;
    return .{ .start = start, .end = position.* };
}
fn decodeKey(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (value.len > max_key_bytes * 2) return error.InvalidKnownHosts;
    const length = std.base64.standard.Decoder.calcSizeForSlice(value) catch return error.InvalidKnownHosts;
    if (length == 0 or length > max_key_bytes) return error.InvalidKnownHosts;
    const output = try allocator.alloc(u8, length);
    errdefer allocator.free(output);
    std.base64.standard.Decoder.decode(output, value) catch return error.InvalidKnownHosts;
    return output;
}
const Cursor = struct {
    bytes: []const u8,
    position: usize = 0,
    fn string(self: *Cursor) ![]const u8 {
        if (self.bytes.len - self.position < 4) return error.InvalidHostKey;
        const length = std.mem.readInt(u32, self.bytes[self.position..][0..4], .big);
        self.position += 4;
        if (length > self.bytes.len - self.position) return error.InvalidHostKey;
        const result = self.bytes[self.position..][0..length];
        self.position += length;
        return result;
    }
};
fn positiveMpint(value: []const u8) !void {
    if (value.len == 0 or value.len > 8193 or value[0] & 0x80 != 0) return error.InvalidHostKey;
    for (value) |byte| if (byte != 0) return;
    return error.InvalidHostKey;
}
fn isLegacyLine(line: []const u8) bool {
    var fields = std.mem.splitScalar(u8, line, '\t');
    _ = fields.next() orelse return false;
    const port = fields.next() orelse return false;
    _ = std.fmt.parseInt(u16, port, 10) catch return false;
    _ = fields.next() orelse return false;
    const fp = fields.next() orelse return false;
    return fields.next() == null and std.mem.startsWith(u8, fp, "SHA256:");
}
const LegacyRecord = struct { host: []const u8, port: u16, algorithm: Algorithm, key_hash: Digest, endpoint_hash: Digest };
fn legacyAlgorithm(value: []const u8) !Algorithm {
    if (std.mem.eql(u8, value, "rsa")) return .@"ssh-rsa";
    if (std.mem.eql(u8, value, "dss")) return .@"ssh-dss";
    if (std.mem.eql(u8, value, "ed25519")) return .@"ssh-ed25519";
    return parseAlgorithm(value);
}
fn legacyFingerprint(value: []const u8) !Digest {
    if (!std.mem.startsWith(u8, value, "SHA256:")) return error.InvalidLegacyTrustStore;
    const encoded = std.mem.trimEnd(u8, value[7..], "=");
    if (encoded.len != 43) return error.InvalidLegacyTrustStore;
    var result: Digest = undefined;
    std.base64.standard_no_pad.Decoder.decode(&result, encoded) catch return error.InvalidLegacyTrustStore;
    return result;
}
fn backupLegacy(io: std.Io, dir: std.Io.Dir, path: []const u8, source: []const u8) !void {
    const existing = dir.readFileAlloc(io, path, std.heap.page_allocator, .limited(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |bytes| {
        defer std.heap.page_allocator.free(bytes);
        if (!std.mem.eql(u8, bytes, source)) return error.LegacyBackupConflict;
        return;
    }
    var atomic = try dir.createFileAtomic(io, path, .{ .permissions = private_permissions, .replace = false });
    defer atomic.deinit(io);
    var buffer: [16 * 1024]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    try writer.interface.writeAll(source);
    try writer.interface.flush();
    try atomic.file.sync(io);
    try atomic.link(io);
}
const private_permissions: std.Io.File.Permissions = @fromBackingInt(0o600);
fn checkDisk(io: std.Io, dir: std.Io.Dir, path: []const u8, expected: ?Digest) !void {
    const source = dir.readFileAlloc(io, path, std.heap.page_allocator, .limited(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => if (expected == null) return else return error.FileConflict,
        else => return err,
    };
    defer std.heap.page_allocator.free(source);
    if (!std.meta.eql(expected, @as(?Digest, digest(source)))) return error.FileConflict;
}
fn lockFile(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !std.Io.File {
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(io, parent);
    const lock_path = try std.fmt.allocPrint(allocator, "{s}.lock", .{path});
    defer allocator.free(lock_path);
    return dir.createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true, .permissions = private_permissions });
}
fn advance(value: u64) !u64 {
    if (value == std.math.maxInt(u64)) return error.RevisionExhausted;
    return value + 1;
}
fn appendSeparator(allocator: std.mem.Allocator, encoded: *std.ArrayList(u8)) !void {
    if (encoded.items.len != 0 and encoded.items[encoded.items.len - 1] != '\n') try encoded.append(allocator, '\n');
}

test "known hosts pattern matcher handles repeated stars and enforces a finite work budget" {
    var budget: MatchBudget = .{};
    try std.testing.expect(try matchPattern("a**?c*", "abbcd", &budget));
    try std.testing.expect(try matchPattern("a*ab", "aaaaaaaaab", &budget));
    try std.testing.expect(!try matchPattern("a*b*c", "abxxxx", &budget));
    var exhausted: MatchBudget = .{ .remaining = 1 };
    try std.testing.expectError(error.KnownHostsPatternBudgetExceeded, matchPattern("a*b", "aaaaab", &exhausted));
}
