//! Application-wide coordination of management writes. It owns no transport,
//! authentication or remote operation. Session permission is checked separately.
const std = @import("std");
const identity = @import("identity.zig");
const trust = @import("tls_trust.zig");
pub const OperationKey = trust.OperationKey;

pub const ResourceKey = struct {
    authority: trust.Authority,
    system_uri: []const u8,
    system_id: []const u8,
    /// Set only after unique discovery/mapping against the trusted authority.
    verified_mapping: bool,
    capability_revision: u64,
};
const Key = struct {
    authority: trust.CanonicalAuthority,
    uri: []const u8,
    id: []const u8,
};
const Record = struct { key: Key, operation: OperationKey, revision: u64, lease_id: u64 };
pub const AcquireResult = union(enum) { lease: Lease, busy: OperationKey };
const FacadeContext = struct {
    arbiter: *Arbiter,
    owner: identity.SessionHandle,

    fn resolve(raw: ?*anyopaque, owner: identity.SessionHandle) !*FacadeContext {
        const self: *FacadeContext = @ptrCast(@alignCast(raw orelse return error.SecurityIdentityCapacity));
        if (!self.owner.eql(owner)) return error.WrongOwner;
        return self;
    }
    fn tryAcquire(raw: ?*anyopaque, owner: identity.SessionHandle, key: ResourceKey, operation: OperationKey, expected_revision: u64) !AcquireResult {
        const self = try resolve(raw, owner);
        return self.arbiter.tryAcquire(self, self.owner, key, operation, expected_revision);
    }
};

pub const Lease = struct {
    context: ?*anyopaque,
    owner: identity.SessionHandle,
    operation: OperationKey,
    expected_revision: u64,
    id: u64,

    /// Call immediately before the write, after the session binding/permission
    /// check. A changed snapshot requires a new explicit user execution.
    pub fn revalidate(self: Lease, operation: OperationKey, current_revision: u64) !void {
        const context = try FacadeContext.resolve(self.context, self.owner);
        try trust.requireOperation(self.owner, operation);
        if (!self.operation.eql(operation)) return error.StaleOperation;
        context.arbiter.lock();
        defer context.arbiter.mutex.unlock();
        try context.arbiter.requireLive(context.owner, operation);
        const record = context.arbiter.find(self.id) orelse return error.ActionLeaseReleased;
        if (!record.operation.eql(operation)) return error.StaleOperation;
        if (current_revision == 0 or current_revision != record.revision or current_revision != self.expected_revision) return error.CapabilityRevisionChanged;
    }
    /// Copies may be released without double freeing; a stale handle can never
    /// release a newer lock because lease IDs do not wrap/reuse.
    pub fn release(self: Lease) void {
        const context = FacadeContext.resolve(self.context, self.owner) catch return;
        context.arbiter.release(context.owner, self.operation, self.id);
    }
};

/// Keep one arbiter in the application domain for all tabs/windows. The key is
/// canonical authority plus validated System URI/ID; DNS aliases are separate
/// unless discovery supplies the same canonical authority itself.
pub const Arbiter = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(Record) = .empty,
    facade_contexts: std.ArrayList(*FacadeContext) = .empty,
    mutex: std.atomic.Mutex = .unlocked,
    next_lease: u64 = 1,
    revoked_owners: std.ArrayList(identity.SessionHandle) = .empty,
    revoked_operations: std.ArrayList(OperationKey) = .empty,
    revocation_exhausted: bool = false,

    pub fn init(allocator: std.mem.Allocator) Arbiter {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Arbiter) void {
        for (self.records.items) |record| self.freeKey(record.key);
        self.records.deinit(self.allocator);
        for (self.facade_contexts.items) |context| self.allocator.destroy(context);
        self.facade_contexts.deinit(self.allocator);
        self.revoked_owners.deinit(self.allocator);
        self.revoked_operations.deinit(self.allocator);
    }
    fn lock(self: *Arbiter) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    pub fn facade(self: *Arbiter, owner: identity.SessionHandle) Facade {
        self.lock();
        defer self.mutex.unlock();
        for (self.facade_contexts.items) |context| if (context.owner.eql(owner)) return .{ .context = context, .owner = owner };
        if (@backingInt(owner.session_id) == 0 or owner.generation == 0 or self.facade_contexts.items.len >= 4096) return .{ .context = null, .owner = owner };
        const context = self.allocator.create(FacadeContext) catch return .{ .context = null, .owner = owner };
        context.* = .{ .arbiter = self, .owner = owner };
        self.facade_contexts.append(self.allocator, context) catch {
            self.allocator.destroy(context);
            return .{ .context = null, .owner = owner };
        };
        return .{ .context = context, .owner = owner };
    }
    pub fn releaseOwner(self: *Arbiter, owner: identity.SessionHandle) void {
        self.lock();
        defer self.mutex.unlock();
        var known = false;
        for (self.revoked_owners.items) |key| if (key.eql(owner)) {
            known = true;
            break;
        };
        if (!known) {
            if (self.revoked_owners.items.len >= 4096) self.revocation_exhausted = true else self.revoked_owners.append(self.allocator, owner) catch {
                self.revocation_exhausted = true;
            };
        }
        var i: usize = 0;
        while (i < self.records.items.len) {
            const record = self.records.items[i];
            if (record.operation.owner == .session and record.operation.owner.session.eql(owner)) self.freeKey(self.records.swapRemove(i).key) else i += 1;
        }
    }
    pub fn cancelOperation(self: *Arbiter, operation: OperationKey) void {
        self.lock();
        defer self.mutex.unlock();
        var known = false;
        for (self.revoked_operations.items) |key| if (key.eql(operation)) {
            known = true;
            break;
        };
        if (!known) {
            if (self.revoked_operations.items.len >= 4096) self.revocation_exhausted = true else self.revoked_operations.append(self.allocator, operation) catch {
                self.revocation_exhausted = true;
            };
        }
        var i: usize = 0;
        while (i < self.records.items.len) {
            if (self.records.items[i].operation.eql(operation)) self.freeKey(self.records.swapRemove(i).key) else i += 1;
        }
    }
    pub fn count(self: *Arbiter) usize {
        self.lock();
        defer self.mutex.unlock();
        return self.records.items.len;
    }
    fn tryAcquire(self: *Arbiter, context: *FacadeContext, owner: identity.SessionHandle, resource: ResourceKey, operation: OperationKey, expected_revision: u64) !AcquireResult {
        try trust.requireOperation(owner, operation);
        if (!resource.verified_mapping) return error.UnverifiedSystem;
        if (expected_revision == 0 or resource.capability_revision != expected_revision) return error.CapabilityRevisionChanged;
        const authority = try trust.canonicalize(resource.authority);
        try validateSystemUri(resource.system_uri);
        if (resource.system_id.len == 0 or resource.system_id.len > 256) return error.InvalidSystemIdentity;
        for (resource.system_id) |byte| if (byte <= 0x20 or byte >= 0x7f or byte == '/' or byte == '\\' or byte == '#' or byte == '?') return error.InvalidSystemIdentity;
        self.lock();
        defer self.mutex.unlock();
        try self.requireLive(owner, operation);
        for (self.records.items) |record| {
            if (!record.key.authority.eql(&authority)) continue;
            // Either shared identifier conflicts: inconsistent server IDs or
            // alternate URIs cannot split a lock for one known System.
            if (std.mem.eql(u8, record.key.uri, resource.system_uri) or std.mem.eql(u8, record.key.id, resource.system_id)) return .{ .busy = record.operation };
        }
        if (self.records.items.len >= 256) return error.ActionArbiterFull;
        if (self.next_lease == std.math.maxInt(u64)) return error.ActionLeaseExhausted;
        const uri = try self.allocator.dupe(u8, resource.system_uri);
        errdefer self.allocator.free(uri);
        const id = try self.allocator.dupe(u8, resource.system_id);
        errdefer self.allocator.free(id);
        const lease: Lease = .{ .context = context, .owner = context.owner, .operation = operation, .expected_revision = expected_revision, .id = self.next_lease };
        try self.records.append(self.allocator, .{ .key = .{ .authority = authority, .uri = uri, .id = id }, .operation = operation, .revision = expected_revision, .lease_id = lease.id });
        self.next_lease += 1;
        return .{ .lease = lease };
    }
    fn find(self: *Arbiter, id: u64) ?*Record {
        for (self.records.items) |*record| if (record.lease_id == id) return record;
        return null;
    }
    fn release(self: *Arbiter, owner: identity.SessionHandle, operation: OperationKey, id: u64) void {
        trust.requireOperation(owner, operation) catch return;
        self.lock();
        defer self.mutex.unlock();
        for (self.records.items, 0..) |record, index| {
            if (record.lease_id != id or !record.operation.eql(operation)) continue;
            self.freeKey(self.records.swapRemove(index).key);
            return;
        }
    }
    fn freeKey(self: *Arbiter, key: Key) void {
        self.allocator.free(key.uri);
        self.allocator.free(key.id);
    }
    fn requireLive(self: *const Arbiter, owner: identity.SessionHandle, operation: OperationKey) !void {
        if (self.revocation_exhausted) return error.SecurityRevocationCapacity;
        for (self.revoked_owners.items) |key| if (key.eql(owner)) return error.OwnerRevoked;
        for (self.revoked_operations.items) |key| if (key.eql(operation)) return error.OperationRevoked;
    }
};
pub const Facade = struct {
    context: ?*anyopaque,
    owner: identity.SessionHandle,

    pub fn tryAcquire(self: Facade, key: ResourceKey, operation: OperationKey, expected_revision: u64) !AcquireResult {
        return FacadeContext.tryAcquire(self.context, self.owner, key, operation, expected_revision);
    }
};

fn validateSystemUri(uri: []const u8) !void {
    if (uri.len < 2 or uri.len > 2048 or uri[0] != '/' or uri[1] == '/' or uri[uri.len - 1] == '/') return error.InvalidSystemUri;
    // Discovery must resolve same-origin absolute URIs into their path first.
    // Reject ambiguous encodings rather than making a second URL parser here.
    for (uri) |byte| if (byte <= 0x20 or byte >= 0x7f or byte == '\\' or byte == '%' or byte == '?' or byte == '#') return error.InvalidSystemUri;
    var segments = std.mem.splitScalar(u8, uri[1..], '/');
    while (segments.next()) |segment| if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.InvalidSystemUri;
}
