//! Restricted, protocol-neutral access to existing Keychain credential refs.
//! Host configuration resolution grants refs, never plugin supplied payloads.
//! A granted lease owns its allocation and must be released by the auth worker.
const std = @import("std");
const identity = @import("identity.zig");
const trust = @import("tls_trust.zig");
const credentials = @import("../config/credential_store.zig");
pub const OperationKey = trust.OperationKey;

pub const Lease = struct {
    allocator: std.mem.Allocator,
    owner: identity.SessionHandle,
    operation: OperationKey,
    credential_ref: [68]u8,
    secret: []u8,
    released: bool = false,
    default_secret: bool = false,

    /// Borrow only inside backend authentication. Do not copy into view state,
    /// diagnostics or renderer data. Move this lease to a worker; never copy it.
    pub fn bytes(self: *const Lease, owner: identity.SessionHandle, operation: OperationKey, credential_ref: []const u8) ![]const u8 {
        if (self.released) return error.SecretLeaseReleased;
        try trust.requireOperation(owner, operation);
        if (self.default_secret or !self.owner.eql(owner) or !self.operation.eql(operation) or !std.mem.eql(u8, &self.credential_ref, credential_ref)) return error.SecretLeaseMismatch;
        return self.secret;
    }
    /// A one-attempt editor override has no persistent credential reference.
    pub fn defaultBytes(self: *const Lease, owner: identity.SessionHandle, operation: OperationKey) ![]const u8 {
        if (self.released) return error.SecretLeaseReleased;
        try trust.requireOperation(owner, operation);
        if (!self.default_secret or !self.owner.eql(owner) or !self.operation.eql(operation)) return error.SecretLeaseMismatch;
        return self.secret;
    }
    pub fn deinit(self: *Lease) void {
        if (self.released) return;
        std.crypto.secureZero(u8, self.secret);
        // Allocator.free poisons bytes with undefined in checked builds. Use
        // rawFree so the allocator always receives the explicitly zeroed data.
        if (self.secret.len != 0) self.allocator.rawFree(self.secret, .of(u8), @returnAddress());
        self.secret = &.{};
        self.released = true;
    }
};
pub const AcquireResult = union(enum) { lease: Lease, missing, denied, cancelled, unavailable, invalid_reference, ungranted };
const Grant = struct { owner: identity.SessionHandle, operation: OperationKey, credential_ref: [68]u8 };
const DefaultGrant = struct { owner: identity.SessionHandle, operation: OperationKey, secret: []u8 };
const FacadeContext = struct {
    store: *Store,
    owner: identity.SessionHandle,
    retired: bool = false,
    ticket: u64 = 1,

    fn acquire(raw: ?*anyopaque, owner: identity.SessionHandle, ticket: u64, operation: OperationKey, reference: []const u8, cancel: ?*const std.atomic.Value(bool)) !AcquireResult {
        const self: *FacadeContext = @ptrCast(@alignCast(raw orelse return error.SecurityIdentityCapacity));
        try self.requireOwner(owner, ticket);
        return self.store.acquire(owner, operation, reference, cancel);
    }
    fn acquireDefault(raw: ?*anyopaque, owner: identity.SessionHandle, ticket: u64, operation: OperationKey, cancel: ?*const std.atomic.Value(bool)) !AcquireResult {
        const self: *FacadeContext = @ptrCast(@alignCast(raw orelse return error.SecurityIdentityCapacity));
        try self.requireOwner(owner, ticket);
        return self.store.acquireDefault(owner, operation, cancel);
    }
    fn requireOwner(self: *FacadeContext, owner: identity.SessionHandle, ticket: u64) !void {
        self.store.lock();
        defer self.store.mutex.unlock();
        // A revoked but unreused facade keeps the structured ungranted/missing
        // result. Recycling changes the ticket, so even owner-field tampering
        // cannot turn an old facade into the next occupant's capability.
        if (self.ticket != ticket or !self.owner.eql(owner)) return error.WrongOwner;
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    grants: std.ArrayList(Grant) = .empty,
    defaults: std.ArrayList(DefaultGrant) = .empty,
    facade_contexts: std.ArrayList(*FacadeContext) = .empty,
    mutex: std.atomic.Mutex = .unlocked,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }
    /// The application retires facades and joins authentication workers first.
    pub fn deinit(self: *Store) void {
        for (self.defaults.items) |entry| wipeFree(self.allocator, entry.secret);
        self.defaults.deinit(self.allocator);
        self.grants.deinit(self.allocator);
        for (self.facade_contexts.items) |context| self.allocator.destroy(context);
        self.facade_contexts.deinit(self.allocator);
    }
    fn lock(self: *Store) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    pub fn facade(self: *Store, owner: identity.SessionHandle) Facade {
        self.lock();
        defer self.mutex.unlock();
        for (self.facade_contexts.items) |context| if (!context.retired and context.owner.eql(owner)) return .{ .context = context, .owner = owner, .ticket = context.ticket };
        if (@backingInt(owner.session_id) == 0 or owner.generation == 0) return .{ .context = null, .owner = owner };
        for (self.facade_contexts.items) |context| if (context.retired) {
            if (context.ticket == std.math.maxInt(u64)) continue;
            context.owner = owner;
            context.retired = false;
            context.ticket += 1;
            return .{ .context = context, .owner = owner, .ticket = context.ticket };
        };
        if (self.facade_contexts.items.len >= 4096) return .{ .context = null, .owner = owner };
        const context = self.allocator.create(FacadeContext) catch return .{ .context = null, .owner = owner };
        context.* = .{ .store = self, .owner = owner };
        self.facade_contexts.append(self.allocator, context) catch {
            self.allocator.destroy(context);
            return .{ .context = null, .owner = owner };
        };
        return .{ .context = context, .owner = owner, .ticket = context.ticket };
    }
    /// Only trusted host resolution calls this, with the frozen config ref.
    /// A grant is bound to the full operation including the attempt number.
    pub fn authorize(self: *Store, owner: identity.SessionHandle, operation: OperationKey, credential_ref: []const u8) !void {
        try trust.requireOperation(owner, operation);
        if (!credentials.validReference(credential_ref)) return error.InvalidCredentialReference;
        self.lock();
        defer self.mutex.unlock();
        if (self.hasGrant(owner, operation, credential_ref)) return;
        if (self.grants.items.len >= 4096) return error.SecretGrantLimit;
        try self.grants.append(self.allocator, .{ .owner = owner, .operation = operation, .credential_ref = credential_ref[0..68].* });
    }
    /// Host-only handoff. The editor never chooses the receiving owner. Bytes
    /// remain in memory, are consumed once, and never pass through Keychain.
    pub fn authorizeDefault(self: *Store, owner: identity.SessionHandle, operation: OperationKey, secret: []const u8) !void {
        try trust.requireOperation(owner, operation);
        if (secret.len == 0) return error.EmptyCredential;
        self.lock();
        defer self.mutex.unlock();
        for (self.defaults.items) |entry| if (entry.owner.eql(owner) and entry.operation.eql(operation)) return error.DefaultSecretAlreadyGranted;
        if (self.defaults.items.len >= 4096) return error.SecretGrantLimit;
        const owned = try self.allocator.dupe(u8, secret);
        errdefer wipeFree(self.allocator, owned);
        try self.defaults.append(self.allocator, .{ .owner = owner, .operation = operation, .secret = owned });
    }
    pub fn revokeOperation(self: *Store, operation: OperationKey) void {
        self.lock();
        defer self.mutex.unlock();
        var i: usize = 0;
        while (i < self.grants.items.len) {
            if (self.grants.items[i].operation.eql(operation)) _ = self.grants.swapRemove(i) else i += 1;
        }
        i = 0;
        while (i < self.defaults.items.len) {
            if (self.defaults.items[i].operation.eql(operation)) wipeFree(self.allocator, self.defaults.swapRemove(i).secret) else i += 1;
        }
    }
    pub fn revokeOwner(self: *Store, owner: identity.SessionHandle) void {
        self.lock();
        defer self.mutex.unlock();
        var i: usize = 0;
        while (i < self.grants.items.len) {
            if (self.grants.items[i].owner.eql(owner)) _ = self.grants.swapRemove(i) else i += 1;
        }
        i = 0;
        while (i < self.defaults.items.len) {
            if (self.defaults.items[i].owner.eql(owner)) wipeFree(self.allocator, self.defaults.swapRemove(i).secret) else i += 1;
        }
        // Retain storage for potentially late worker facades, but recycle the
        // retired slot only for a distinct complete SessionHandle.
        for (self.facade_contexts.items) |context| if (context.owner.eql(owner)) {
            context.retired = true;
        };
    }
    fn hasGrant(self: *const Store, owner: identity.SessionHandle, operation: OperationKey, reference: []const u8) bool {
        for (self.grants.items) |grant| if (grant.owner.eql(owner) and grant.operation.eql(operation) and std.mem.eql(u8, &grant.credential_ref, reference)) return true;
        return false;
    }
    fn acquire(self: *Store, owner: identity.SessionHandle, operation: OperationKey, reference: []const u8, cancel: ?*const std.atomic.Value(bool)) !AcquireResult {
        try trust.requireOperation(owner, operation);
        if (!credentials.validReference(reference)) return .invalid_reference;
        if (isCancelled(cancel)) return .cancelled;
        self.lock();
        const granted = self.hasGrant(owner, operation, reference);
        self.mutex.unlock();
        if (!granted) return .ungranted;
        const value = credentials.get(self.allocator, reference) catch |err| return switch (err) {
            error.CredentialMissing => .missing,
            error.CredentialDenied, error.CredentialLocked => .denied,
            error.Cancelled, error.Canceled, error.UserCancelled => .cancelled,
            error.OutOfMemory => error.OutOfMemory,
            else => .unavailable,
        };
        // A Keychain prompt or backend may complete after close/cancellation.
        self.lock();
        const still_granted = self.hasGrant(owner, operation, reference);
        self.mutex.unlock();
        if (!still_granted or isCancelled(cancel)) {
            std.crypto.secureZero(u8, value);
            if (value.len != 0) self.allocator.rawFree(value, .of(u8), @returnAddress());
            return if (isCancelled(cancel)) .cancelled else .ungranted;
        }
        return .{ .lease = .{ .allocator = self.allocator, .owner = owner, .operation = operation, .credential_ref = reference[0..68].*, .secret = value } };
    }
    fn acquireDefault(self: *Store, owner: identity.SessionHandle, operation: OperationKey, cancel: ?*const std.atomic.Value(bool)) !AcquireResult {
        try trust.requireOperation(owner, operation);
        if (isCancelled(cancel)) return .cancelled;
        self.lock();
        defer self.mutex.unlock();
        for (self.defaults.items, 0..) |entry, index| if (entry.owner.eql(owner) and entry.operation.eql(operation)) {
            const granted = self.defaults.swapRemove(index);
            if (isCancelled(cancel)) {
                wipeFree(self.allocator, granted.secret);
                return .cancelled;
            }
            // Transfer the only owned copy into the worker lease.
            return .{ .lease = .{ .allocator = self.allocator, .owner = owner, .operation = operation, .credential_ref = @splat(0), .secret = granted.secret, .default_secret = true } };
        };
        return .missing;
    }
};
pub const Facade = struct {
    context: ?*anyopaque,
    owner: identity.SessionHandle,
    ticket: u64 = 0,

    pub fn acquire(self: Facade, operation: OperationKey, credential_ref: []const u8, cancel: ?*const std.atomic.Value(bool)) !AcquireResult {
        return FacadeContext.acquire(self.context, self.owner, self.ticket, operation, credential_ref, cancel);
    }
    pub fn acquireDefault(self: Facade, operation: OperationKey, cancel: ?*const std.atomic.Value(bool)) !AcquireResult {
        return FacadeContext.acquireDefault(self.context, self.owner, self.ticket, operation, cancel);
    }
};
fn wipeFree(allocator: std.mem.Allocator, bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
    if (bytes.len != 0) allocator.rawFree(bytes, .of(u8), @returnAddress());
}
fn isCancelled(cancel: ?*const std.atomic.Value(bool)) bool {
    return if (cancel) |flag| flag.load(.acquire) else false;
}

/// Same contract as the manifest callback: the returned outer slice and each
/// ref are owned by the supplied allocator. The host unions every successful
/// enumeration before reconcileScope. Any failure/unsupported payload stops GC.
pub const ReferenceEnumerator = *const fn (std.mem.Allocator, []const u8) anyerror![]const []const u8;
