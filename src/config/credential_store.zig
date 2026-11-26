//! App-scoped, immutable credential references. Secrets never appear in errors.
//! Production defaults to Keychain and can move between it and private files.
const std = @import("std");
const builtin = @import("builtin");
const LocalStore = @import("local_credentials.zig");
const native = @import("../platform/keychain.zig");
const alloc = std.heap.page_allocator;
const default_service = "com.zerowork.app.credentials";
var service: ?[:0]const u8 = null;
var local_store: ?LocalStore = null;
var local_mode: std.atomic.Value(bool) = .init(false);
var pending_local_import: std.atomic.Value(bool) = .init(false);
var startup_reserved: std.atomic.Value(bool) = .init(false);
var startup_finished: std.Io.Event = .unset;
var startup_failure: ?anyerror = null;
var converting: std.atomic.Value(bool) = .init(false);
var transactions: std.atomic.Value(usize) = .init(0);
var readers: std.atomic.Value(usize) = .init(0);
var selected_backend: ?Backend = null;
var test_memory: MemoryBackend = .{};
var pending_cleanup: std.ArrayList([68]u8) = .empty;

pub const Backend = struct {
    context: *anyopaque,
    get: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8) anyerror![]u8,
    add: *const fn (*anyopaque, []const u8, []const u8, []const u8) anyerror!void,
    remove: *const fn (*anyopaque, []const u8, []const u8) anyerror!void,
    collect: *const fn (*anyopaque, []const u8, []const []const u8) anyerror!void,
};

pub fn configureScope(directory: []const u8, isolated: bool) !void {
    const next = if (isolated) blk: {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(directory, &digest, .{});
        break :blk try std.fmt.allocPrintSentinel(alloc, "{s}.instance.{x}", .{ default_service, digest }, 0);
    } else try alloc.dupeSentinel(u8, default_service, 0);
    if (service) |old| {
        defer alloc.free(next);
        if (!std.mem.eql(u8, old, next)) return error.CredentialScopeAlreadyConfigured;
        return;
    }
    service = next;
}
pub fn scopeService() ![]const u8 {
    return scope();
}
pub fn configureLocal(io: std.Io, directory: []const u8) !void {
    if (local_store != null) return error.CredentialScopeAlreadyConfigured;
    local_store = .{ .io = io, .directory = directory };
    local_mode.store(try local_store.?.isSelected(), .release);
    pending_local_import.store(!usesLocal() and try local_store.?.hasUnmarkedReferences(validReference), .release);
}
fn local() !LocalStore {
    return local_store orelse error.CredentialScopeNotConfigured;
}
pub fn usesLocal() bool {
    return local_mode.load(.acquire);
}
pub fn hasPendingLocalImport() bool {
    return pending_local_import.load(.acquire);
}
pub fn isUnlocked() bool {
    return if (builtin.is_test) true else usesLocal() or native.cached();
}
pub fn reserveStartupUnlock() bool {
    const reserve = !usesLocal();
    startup_reserved.store(reserve, .release);
    return reserve;
}
pub fn startupPending() bool {
    return startup_reserved.load(.acquire) and !startup_finished.isSet();
}
pub fn unlockAtStartup() void {
    const result = if (scope()) |name| native.authorize(name) else |err| err;
    completeStartupUnlock(result);
}
pub fn completeStartupUnlock(result: anyerror!void) void {
    startup_failure = if (result) |_| null else |err| err;
    startup_finished.set(std.Io.Threaded.global_single_threaded.io());
}
pub fn startupUnlockResult() ?anyerror!void {
    if (!startup_finished.isSet()) return null;
    if (startup_failure) |err| return @as(anyerror!void, err);
    return {};
}
/// Only workers wait for the shared system request. UI callers get CredentialBusy.
fn waitForStartup(cancel: anytype, comptime isCancelled: fn (@TypeOf(cancel)) bool) !void {
    while (startupPending()) {
        if (isCancelled(cancel)) return error.Cancelled;
        startup_finished.waitTimeout(std.Io.Threaded.global_single_threaded.io(), .{
            .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake },
        }) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => return error.Cancelled,
        };
    }
    if (isCancelled(cancel)) return error.Cancelled;
}
fn checkStartupUnlock() !void {
    if (startupPending()) return error.CredentialBusy;
    if (startupUnlockResult()) |result| result catch |err| {
        if (!native.cached()) return err;
    };
}

pub fn isConverting() bool {
    return converting.load(.acquire);
}
pub const Storage = enum { local, keychain };
pub const Conversion = enum { complete, local_cleanup_pending };

pub fn beginConversion(target: Storage) bool {
    if (startupPending()) return false;
    if (converting.cmpxchgStrong(false, true, .seq_cst, .seq_cst) != null) return false;
    const can_switch = usesLocal() != (target == .local) or (target == .keychain and hasPendingLocalImport());
    if (can_switch and transactions.load(.seq_cst) == 0 and readers.load(.seq_cst) == 0) return true;
    endConversion();
    return false;
}
pub fn endConversion() void {
    converting.store(false, .release);
}
pub fn convertToLocal() !void {
    if (builtin.is_test) return error.CredentialUnavailable;
    const target = try local();
    // Do not clear the target before authorization. Export into bounded memory
    // first, then preflight every immutable reference before any local writes.
    var incoming: LocalImport = .{};
    defer incoming.deinit();
    try native.copyToLocal(try scope(), &incoming);
    try incoming.publish(target, pending_cleanup.items);
    try target.select();
    pending_cleanup.clearRetainingCapacity();
    local_mode.store(true, .release);
    pending_local_import.store(false, .release);
}

const LocalImport = struct {
    const Entry = struct { reference: [68]u8, value: []u8, created: bool = false };
    entries: std.ArrayList(Entry) = .empty,
    total: usize = 0,

    fn deinit(self: *LocalImport) void {
        for (self.entries.items) |entry| {
            std.crypto.secureZero(u8, entry.value);
            alloc.free(entry.value);
        }
        self.entries.deinit(alloc);
    }
    pub fn importValue(self: *LocalImport, reference: []const u8, value: []const u8) !void {
        if (!validReference(reference)) return error.InvalidCredentialReference;
        if (self.entries.items.len >= 16384 or value.len > 8 * 1024 * 1024 - self.total) return error.CredentialLimitExceeded;
        try self.entries.ensureUnusedCapacity(alloc, 1);
        self.entries.appendAssumeCapacity(.{ .reference = reference[0..68].*, .value = try alloc.dupe(u8, value) });
        self.total += value.len;
    }
    fn publish(self: *LocalImport, target: LocalStore, retired: []const [68]u8) !void {
        for (self.entries.items) |*entry| {
            if (isRetired(retired, &entry.reference)) continue;
            const prior = target.get(alloc, &entry.reference) catch |err| switch (err) {
                error.CredentialMissing => continue,
                else => return err,
            };
            defer {
                std.crypto.secureZero(u8, prior);
                alloc.free(prior);
            }
            if (!std.mem.eql(u8, prior, entry.value)) return error.CredentialAlreadyExists;
        }
        errdefer for (self.entries.items) |entry| {
            if (entry.created) _ = target.removeIfEqual(&entry.reference, entry.value) catch false;
        };
        for (self.entries.items) |*entry| {
            if (isRetired(retired, &entry.reference)) continue;
            target.add(&entry.reference, entry.value) catch |err| switch (err) {
                error.CredentialAlreadyExists => {
                    try target.importValue(&entry.reference, entry.value);
                    continue;
                },
                else => return err,
            };
            entry.created = true;
        }
    }
};

fn isRetired(retired: []const [68]u8, reference: *const [68]u8) bool {
    for (retired) |*entry| if (std.mem.eql(u8, entry, reference)) return true;
    return false;
}

test "credential import preserves unmarked values across cancellation conflict and restart" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const directory = try temp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    const store: LocalStore = .{ .io = io, .directory = directory };
    const legacy = "zw1_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const other = "zw1_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const newer = "zw1_cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    try std.testing.expect(!try store.isSelected());
    try std.testing.expect(!try store.hasUnmarkedReferences(validReference));
    try store.add(legacy, "one");
    try std.testing.expect(!try store.isSelected());
    try std.testing.expect(try store.hasUnmarkedReferences(validReference));
    {
        // A rejected/partial export never reaches publish.
        var staged: LocalImport = .{};
        defer staged.deinit();
        try staged.importValue(other, "two");
    }
    try std.testing.expectError(error.CredentialMissing, store.get(a, other));
    {
        var staged: LocalImport = .{};
        defer staged.deinit();
        try staged.importValue(other, "two");
        try staged.importValue(legacy, "different");
        try std.testing.expectError(error.CredentialAlreadyExists, staged.publish(store, &.{}));
    }
    try std.testing.expectError(error.CredentialMissing, store.get(a, other));
    const old = try store.get(a, legacy);
    defer a.free(old);
    try std.testing.expectEqualStrings("one", old);
    {
        var staged: LocalImport = .{};
        defer staged.deinit();
        try staged.importValue(legacy, "one");
        try staged.importValue(other, "two");
        try staged.publish(store, &.{});
        try staged.publish(store, &.{}); // identical data is safe to retry
    }
    try std.testing.expect(try store.hasUnmarkedReferences(validReference));
    try store.select();
    try std.testing.expect(try store.isSelected());
    try std.testing.expect(!try store.hasUnmarkedReferences(validReference));
    try store.add(newer, "keep");
    try std.testing.expect(try store.deselect());
    try std.testing.expect(try store.deselect());
    try std.testing.expect(try store.removeIfEqual(legacy, "one"));
    try std.testing.expect(!try store.removeIfEqual(other, "obsolete"));
    const remaining = try store.get(a, newer);
    defer a.free(remaining);
    try std.testing.expectEqualStrings("keep", remaining);
    const reopened: LocalStore = .{ .io = io, .directory = directory };
    try std.testing.expect(!try reopened.isSelected());
    try std.testing.expect(!try reopened.hasUnmarkedReferences(validReference));
}

pub fn convertToKeychain() !Conversion {
    if (builtin.is_test) return error.CredentialUnavailable;
    const source = try local();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const allocator = arena.allocator();
    const refs = try source.references(allocator, validReference);
    var entries: std.ArrayList(native.ImportEntry) = .empty;
    defer for (entries.items) |entry| std.crypto.secureZero(u8, @constCast(entry.value[0..entry.length]));
    try entries.ensureTotalCapacity(allocator, refs.len);
    var total: usize = 0;
    for (refs) |*reference| {
        for (pending_cleanup.items) |*retired| {
            if (std.mem.eql(u8, reference, retired)) break;
        } else {
            const account = try allocator.dupeSentinel(u8, reference, 0);
            const secret = try source.get(allocator, reference);
            entries.appendAssumeCapacity(.{ .reference = account.ptr, .value = secret.ptr, .length = secret.len });
            total += secret.len;
            if (total > 8 * 1024 * 1024) return error.CredentialLimitExceeded;
        }
    }
    try native.importVerified(try scope(), entries.items);
    const durable = try source.deselect();
    local_mode.store(false, .release);
    pending_local_import.store(false, .release);
    pending_cleanup.clearRetainingCapacity();
    if (!durable) return .local_cleanup_pending;
    var complete = true;
    for (entries.items) |entry| {
        if (!(source.removeIfEqual(std.mem.span(entry.reference), entry.value[0..entry.length]) catch false)) complete = false;
    }
    return if (complete) .complete else .local_cleanup_pending;
}
fn scope() ![:0]const u8 {
    if (service) |s| return s;
    if (builtin.is_test) return "com.zerowork.tests.memory";
    return error.CredentialScopeNotConfigured;
}
fn backend() ?Backend {
    if (selected_backend) |value| return value;
    if (builtin.is_test) return test_memory.backend();
    return null;
}
/// A fixture owns its backend until restore. The default test backend is memory.
pub fn useBackendForTesting(value: Backend) ?Backend {
    if (!builtin.is_test) @panic("test backend is unavailable in production");
    const previous = selected_backend;
    selected_backend = value;
    return previous;
}
pub fn restoreBackendForTesting(previous: ?Backend) void {
    selected_backend = previous;
}
pub fn validReference(reference: []const u8) bool {
    if (reference.len != 68 or !std.mem.startsWith(u8, reference, "zw1_")) return false;
    for (reference[4..]) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}
pub fn get(a: std.mem.Allocator, reference: []const u8) ![]u8 {
    if (!validReference(reference)) return error.InvalidCredentialReference;
    const s = try scope();
    if (backend()) |b| return b.get(b.context, a, s, reference);
    if (builtin.is_test) unreachable;
    _ = readers.fetchAdd(1, .seq_cst);
    defer _ = readers.fetchSub(1, .seq_cst);
    if (converting.load(.seq_cst)) return error.CredentialBusy;
    if (usesLocal()) return (try local()).get(a, reference);
    try checkStartupUnlock();
    return native.get(a, s, reference);
}

pub fn getIfPresent(a: std.mem.Allocator, reference: []const u8) !?[]u8 {
    return get(a, reference) catch |err| switch (err) {
        error.CredentialMissing => null,
        else => return err,
    };
}
pub fn getForWorker(a: std.mem.Allocator, reference: []const u8, cancel: anytype, comptime isCancelled: fn (@TypeOf(cancel)) bool) !?[]u8 {
    try waitForStartup(cancel, isCancelled);
    return getIfPresent(a, reference);
}

pub fn getCached(a: std.mem.Allocator, reference: []const u8) !?[]u8 {
    if (!isUnlocked()) return null;
    return getIfPresent(a, reference) catch |err| switch (err) {
        error.CredentialBusy => null,
        else => return err,
    };
}
fn add(reference: []const u8, secret: []const u8) !void {
    const s = try scope();
    if (backend()) |b| return b.add(b.context, s, reference, secret);
    if (builtin.is_test) unreachable;
    if (usesLocal()) return (try local()).add(reference, secret);
    try checkStartupUnlock();
    return native.add(alloc, s, reference, secret);
}
fn remove(reference: []const u8) !void {
    if (!validReference(reference)) return error.InvalidCredentialReference;
    const s = try scope();
    if (backend()) |b| return b.remove(b.context, s, reference);
    if (builtin.is_test) unreachable;
    if (usesLocal()) return (try local()).remove(reference);
    try checkStartupUnlock();
    return native.remove(alloc, s, reference);
}
/// Call after both owned files are parsed successfully, retaining their union of refs.
/// This reclaims crash leftovers; it only enumerates this service's zw1_ accounts.
pub fn reconcileScope(keep: []const []const u8) !void {
    const s = try scope();
    for (keep) |reference| if (!validReference(reference)) return error.InvalidCredentialReference;
    if (backend()) |b| try b.collect(b.context, s, keep) else if (builtin.is_test) unreachable else if (usesLocal()) try (try local()).collect(keep, validReference) else {
        try checkStartupUnlock();
        try native.collect(alloc, s, keep);
    }
    pending_cleanup.clearRetainingCapacity();
}
pub fn eraseScope() !void {
    if (backend()) |_| return reconcileScope(&.{});
    if (builtin.is_test) unreachable;
    if (isConverting() or startupPending()) return error.CredentialBusy;
    try native.erase(try scope());
    try (try local()).collect(&.{}, validReference);
    pending_cleanup.clearRetainingCapacity();
}
/// Failed cleanup is retried before creating more secrets, bounding accumulation.
fn drainCleanup() !void {
    while (pending_cleanup.items.len != 0) {
        const reference = pending_cleanup.items[pending_cleanup.items.len - 1];
        try remove(&reference);
        _ = pending_cleanup.pop();
    }
}
fn deferCleanup(reference: []const u8) void {
    remove(reference) catch {
        // Reserved by Transaction.init before any native side effect.
        pending_cleanup.appendAssumeCapacity(reference[0..68].*);
    };
}

pub const Transaction = struct {
    arena: std.heap.ArenaAllocator,
    created: std.ArrayList([]const u8) = .empty,
    retired: std.ArrayList([]const u8) = .empty,
    committed: bool = false,
    pub fn init() !Transaction {
        _ = transactions.fetchAdd(1, .seq_cst);
        errdefer _ = transactions.fetchSub(1, .seq_cst);
        if (converting.load(.seq_cst)) return error.CredentialBusy;
        try drainCleanup();
        try pending_cleanup.ensureUnusedCapacity(alloc, 16384);
        return .{ .arena = .init(alloc) };
    }
    pub fn deinit(self: *Transaction) void {
        if (!self.committed) for (self.created.items) |reference| deferCleanup(reference);
        self.arena.deinit();
        _ = transactions.fetchSub(1, .seq_cst);
    }
    /// A changed value receives a cryptographically random, immutable new reference.
    pub fn stage(self: *Transaction, io: std.Io, a: std.mem.Allocator, secret: ?[]const u8, old_reference: ?[]const u8) !?[]const u8 {
        return self.stageWithFallback(io, a, secret, old_reference, null);
    }
    pub fn stageSetting(self: *Transaction, io: std.Io, a: std.mem.Allocator, secret: []const u8, reference: ?[]const u8, old_reference: ?[]const u8) !?[]const u8 {
        const value = if (secret.len != 0) secret else null;
        return self.stageWithFallback(io, a, value, old_reference, .{ .reference = if (value == null) reference else null });
    }
    pub fn stageHost(self: *Transaction, io: std.Io, a: std.mem.Allocator, secret: *?[]const u8, reference: *?[]const u8, old_reference: ?[]const u8) !void {
        reference.* = try self.stageWithFallback(io, a, secret.*, old_reference, .{ .cached_secret = secret, .reference = reference.* });
    }
    fn stageWithFallback(self: *Transaction, io: std.Io, a: std.mem.Allocator, secret: ?[]const u8, old_reference: ?[]const u8, fallback: ?struct { cached_secret: ?*?[]const u8 = null, reference: ?[]const u8 }) !?[]const u8 {
        const owned = self.arena.allocator();
        if (secret == null) if (fallback) |retained| if (retained.reference) |reference| {
            if (old_reference) |previous| {
                if (!std.mem.eql(u8, reference, previous)) try self.retired.append(owned, try owned.dupe(u8, previous));
            }
            return try a.dupe(u8, reference);
        };
        if (old_reference) |reference| {
            const prior: ?[]u8 = get(owned, reference) catch |err| missing: {
                if (err != error.CredentialMissing) return err;
                const recovery = fallback orelse return err;
                if (recovery.reference) |retained| {
                    // Keep the untouched reference without recreating its cached secret.
                    if (recovery.cached_secret) |cached| cached.* = null;
                    return try a.dupe(u8, retained);
                }
                // The editor supplied a fresh value or explicitly saved it empty.
                break :missing null;
            };
            if (prior) |old_secret| {
                if (secret) |value| if (std.mem.eql(u8, old_secret, value)) return try a.dupe(u8, reference);
                try self.retired.append(owned, try owned.dupe(u8, reference));
            }
        }
        const value = secret orelse return null;
        if (self.created.items.len >= 4096) return error.CredentialLimitExceeded;
        var random: [32]u8 = undefined;
        try io.randomSecure(&random);
        const reference = try std.fmt.allocPrint(owned, "zw1_{x}", .{random});
        const result = try a.dupe(u8, reference);
        try self.created.append(owned, reference);
        add(reference, value) catch |err| {
            _ = self.created.pop();
            return err;
        };
        return result;
    }
    pub fn retain(self: *Transaction, reference: []const u8) void {
        var i: usize = 0;
        while (i < self.retired.items.len) {
            if (std.mem.eql(u8, self.retired.items[i], reference)) {
                _ = self.retired.swapRemove(i);
            } else i += 1;
        }
    }
    pub fn retire(self: *Transaction, reference: []const u8) !void {
        for (self.retired.items) |old| if (std.mem.eql(u8, old, reference)) return;
        const owned = self.arena.allocator();
        _ = (try getIfPresent(owned, reference)) orelse return;
        try self.retired.append(owned, try owned.dupe(u8, reference));
    }
    pub fn commit(self: *Transaction) void {
        self.committed = true;
        for (self.retired.items) |reference| deferCleanup(reference);
    }
};

/// Injectable owned fixture. It never touches user data or native Keychain.
pub const MemoryBackend = struct {
    values: std.StringHashMapUnmanaged([]u8) = .empty,
    denied: bool = false,
    fail_add_after: ?usize = null,
    additions: usize = 0,
    pub fn backend(self: *MemoryBackend) Backend {
        return .{ .context = self, .get = read, .add = write, .remove = erase, .collect = collect };
    }
    pub fn deinit(self: *MemoryBackend) void {
        var it = self.values.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            @memset(entry.value_ptr.*, 0);
            alloc.free(entry.value_ptr.*);
        }
        self.values.deinit(alloc);
        self.* = .{};
    }
    fn key(s: []const u8, r: []const u8) ![]u8 {
        return std.fmt.allocPrint(alloc, "{s}/{s}", .{ s, r });
    }
    fn read(context: *anyopaque, a: std.mem.Allocator, s: []const u8, r: []const u8) ![]u8 {
        const self: *MemoryBackend = @ptrCast(@alignCast(context));
        if (self.denied) return error.CredentialDenied;
        const k = try key(s, r);
        defer alloc.free(k);
        return a.dupe(u8, self.values.get(k) orelse return error.CredentialMissing);
    }
    fn write(context: *anyopaque, s: []const u8, r: []const u8, value: []const u8) !void {
        const self: *MemoryBackend = @ptrCast(@alignCast(context));
        if (self.denied) return error.CredentialDenied;
        if (self.fail_add_after) |limit| if (self.additions >= limit) return error.CredentialStorageFailure;
        const k = try key(s, r);
        errdefer alloc.free(k);
        if (self.values.contains(k)) return error.CredentialAlreadyExists;
        const copy = try alloc.dupe(u8, value);
        errdefer alloc.free(copy);
        try self.values.put(alloc, k, copy);
        self.additions += 1;
    }
    fn erase(context: *anyopaque, s: []const u8, r: []const u8) !void {
        const self: *MemoryBackend = @ptrCast(@alignCast(context));
        if (self.denied) return error.CredentialDenied;
        const k = try key(s, r);
        defer alloc.free(k);
        if (self.values.fetchRemove(k)) |entry| {
            alloc.free(entry.key);
            @memset(entry.value, 0);
            alloc.free(entry.value);
        }
    }
    fn collect(context: *anyopaque, s: []const u8, keep: []const []const u8) !void {
        const self: *MemoryBackend = @ptrCast(@alignCast(context));
        if (self.denied) return error.CredentialDenied;
        var keys: std.ArrayList([]const u8) = .empty;
        defer keys.deinit(alloc);
        var it = self.values.keyIterator();
        while (it.next()) |k| {
            if (!std.mem.startsWith(u8, k.*, s) or k.*.len <= s.len or k.*[s.len] != '/') continue;
            const reference = k.*[s.len + 1 ..];
            if (!validReference(reference)) continue;
            var retained = false;
            for (keep) |item| if (std.mem.eql(u8, item, reference)) {
                retained = true;
                break;
            };
            if (!retained) try keys.append(alloc, try alloc.dupe(u8, reference));
        }
        for (keys.items) |r| {
            defer alloc.free(r);
            try erase(context, s, r);
        }
    }
};

test "credential isolated instance service is stable and refuses scope switching" {
    const previous_service = service;
    service = null;
    defer {
        if (service) |value| alloc.free(value);
        service = previous_service;
    }
    try configureScope("/owned-fixture/instance-a", true);
    const first = try scopeService();
    try std.testing.expect(std.mem.startsWith(u8, first, "com.zerowork.app.credentials.instance."));
    try std.testing.expectEqual(@as(usize, "com.zerowork.app.credentials.instance.".len + 64), first.len);
    try configureScope("/owned-fixture/instance-a", true);
    try std.testing.expectError(error.CredentialScopeAlreadyConfigured, configureScope("/owned-fixture/instance-b", true));
    try std.testing.expectEqualStrings(first, try scopeService());
}
