//! App-scoped, immutable credential references. Secrets never appear in errors.
//! Production bootstrap configures a scope once; tests use memory, never Security.
const std = @import("std");
const builtin = @import("builtin");
const native = @import("../platform/keychain.zig");
const alloc = std.heap.page_allocator;
const default_service = "com.zerowork.app.credentials";
var service: ?[:0]const u8 = null;
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
    return native.get(a, s, reference);
}
fn add(reference: []const u8, secret: []const u8) !void {
    const s = try scope();
    if (backend()) |b| return b.add(b.context, s, reference, secret);
    if (builtin.is_test) unreachable;
    return native.add(alloc, s, reference, secret);
}
fn remove(reference: []const u8) !void {
    const s = try scope();
    if (backend()) |b| return b.remove(b.context, s, reference);
    if (builtin.is_test) unreachable;
    return native.remove(alloc, s, reference);
}
/// Call after both owned files are parsed successfully, retaining their union of refs.
/// This reclaims crash leftovers; it only enumerates this service's zw1_ accounts.
pub fn reconcileScope(keep: []const []const u8) !void {
    const s = try scope();
    for (keep) |reference| if (!validReference(reference)) return error.InvalidCredentialReference;
    if (backend()) |b| try b.collect(b.context, s, keep) else if (builtin.is_test) unreachable else try native.collect(alloc, s, keep);
    pending_cleanup.clearRetainingCapacity();
}
pub fn eraseScope() !void {
    const s = try scope();
    if (backend()) |b| try b.collect(b.context, s, &.{}) else if (builtin.is_test) unreachable else try native.erase(s);
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
        try drainCleanup();
        try pending_cleanup.ensureUnusedCapacity(alloc, 16384);
        return .{ .arena = .init(alloc) };
    }
    pub fn deinit(self: *Transaction) void {
        if (!self.committed) for (self.created.items) |reference| deferCleanup(reference);
        self.arena.deinit();
    }
    /// Existing refs are always resolved first; absence/denial cannot be overwritten.
    /// A changed value receives a cryptographically random, immutable new reference.
    pub fn stage(self: *Transaction, io: std.Io, a: std.mem.Allocator, secret: ?[]const u8, old_reference: ?[]const u8) !?[]const u8 {
        const owned = self.arena.allocator();
        if (old_reference) |reference| {
            const old_secret = try get(owned, reference);
            if (secret) |value| if (std.mem.eql(u8, old_secret, value)) return try a.dupe(u8, reference);
            try self.retired.append(owned, try owned.dupe(u8, reference));
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
        _ = try get(owned, reference);
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

pub fn authorizeScope() !void {
    if (builtin.is_test) return error.CredentialUnavailable;
    try native.authorize(try scope());
}
