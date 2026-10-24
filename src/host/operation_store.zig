//! Bounded, redacted operation history. This store never owns a live binding or
//! retries a remote action. Method-level locking supports AI workers and host
//! controllers; no lock crosses approval, plugin callbacks, or network waits.
const std = @import("std");
const identity = @import("identity.zig");
pub const Stage = enum { prepared, pending_approval, approved, sent, verifying, succeeded, failed, cancelled_unsent, outcome_unknown, rejected };
pub const QueryTarget = struct { owner: identity.SessionHandle, operation_id: u64 };
pub const Record = struct {
    owner: identity.SessionHandle,
    operation_id: u64,
    tool_id: []const u8,
    arguments_hash: [32]u8,
    authorization_revision: u64,
    event_revision: u64 = 1,
    stage: Stage = .prepared,
    /// Only a pre-redacted summary, never tool arguments or credentials.
    result_text: []const u8 = "",
    resources_released: bool = false,
    owner_closed: bool = false,
    query_of: ?QueryTarget = null,
    pub fn terminal(self: Record) bool {
        return switch (self.stage) {
            .succeeded, .failed, .cancelled_unsent, .rejected, .outcome_unknown => true,
            else => false,
        };
    }
};
/// Immutable scalar facts. No borrowed ArrayList pointers or mutable strings.
pub const Facts = struct {
    owner: identity.SessionHandle,
    operation_id: u64,
    arguments_hash: [32]u8,
    authorization_revision: u64,
    event_revision: u64,
    stage: Stage,
    resources_released: bool,
    owner_closed: bool,
    query_of: ?QueryTarget,
};
/// A complete historical result owns its strings until explicit release, even
/// after another thread updates/clears the source or the store is destroyed.
pub const Snapshot = struct {
    value: Record,
    allocator: std.mem.Allocator,
    pub fn deinit(self: *Snapshot) void {
        self.allocator.free(self.value.tool_id);
        self.allocator.free(self.value.result_text);
        self.* = undefined;
    }
};
fn facts(record: Record) Facts {
    return .{ .owner = record.owner, .operation_id = record.operation_id, .arguments_hash = record.arguments_hash, .authorization_revision = record.authorization_revision, .event_revision = record.event_revision, .stage = record.stage, .resources_released = record.resources_released, .owner_closed = record.owner_closed, .query_of = record.query_of };
}
pub const Store = struct {
    pub const capacity = 128;
    allocator: std.mem.Allocator,
    // Internal storage; callers must use count/lookup/snapshot across threads.
    records: std.ArrayList(Record) = .empty,
    mutex: std.atomic.Mutex = .unlocked,
    fn lock(self: *Store) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }
    /// The process owner calls this only after every worker/controller joins.
    pub fn deinit(self: *Store) void {
        self.lock();
        defer self.mutex.unlock();
        for (self.records.items) |record| self.release(record);
        self.records.deinit(self.allocator);
    }
    pub fn count(self: *Store) usize {
        self.lock();
        defer self.mutex.unlock();
        return self.records.items.len;
    }
    pub fn hasPending(self: *Store, owner: identity.SessionHandle) bool {
        self.lock();
        defer self.mutex.unlock();
        for (self.records.items) |record| if (record.owner.eql(owner) and !record.terminal()) return true;
        return false;
    }
    pub fn begin(self: *Store, owner: identity.SessionHandle, operation_id: u64, tool_id: []const u8, arguments_hash: [32]u8, authorization_revision: u64) !Facts {
        self.lock();
        defer self.mutex.unlock();
        return facts((try self.beginLocked(owner, operation_id, tool_id, arguments_hash, authorization_revision)).*);
    }
    pub fn beginNew(self: *Store, owner: identity.SessionHandle, operation_id: u64, tool_id: []const u8, arguments_hash: [32]u8, authorization_revision: u64) !Facts {
        self.lock();
        defer self.mutex.unlock();
        if (self.find(owner, operation_id) != null) return error.ToolOperationAlreadyRecorded;
        return facts((try self.beginLocked(owner, operation_id, tool_id, arguments_hash, authorization_revision)).*);
    }
    fn beginLocked(self: *Store, owner: identity.SessionHandle, operation_id: u64, tool_id: []const u8, arguments_hash: [32]u8, authorization_revision: u64) !*Record {
        if (@backingInt(owner.session_id) == 0 or owner.generation == 0 or operation_id == 0 or tool_id.len == 0 or tool_id.len > 256 or authorization_revision == 0) return error.InvalidOperation;
        for (self.records.items) |record| if (record.owner.eql(owner) and record.owner_closed) return error.OwnerClosed;
        if (self.find(owner, operation_id)) |record| {
            if (!std.mem.eql(u8, record.tool_id, tool_id) or !std.mem.eql(u8, &record.arguments_hash, &arguments_hash) or record.authorization_revision != authorization_revision) return error.OperationIdentityConflict;
            return record;
        }
        if (self.records.items.len >= capacity) return error.OperationHistoryFull;
        const owned = try self.allocator.dupe(u8, tool_id);
        errdefer self.allocator.free(owned);
        try self.records.append(self.allocator, .{ .owner = owner, .operation_id = operation_id, .tool_id = owned, .arguments_hash = arguments_hash, .authorization_revision = authorization_revision });
        return &self.records.items[self.records.items.len - 1];
    }
    /// A safe follow-up query is a distinct operation with fresh authorization.
    pub fn beginReadQuery(self: *Store, owner: identity.SessionHandle, operation_id: u64, tool_id: []const u8, arguments_hash: [32]u8, authorization_revision: u64, original: QueryTarget) !Facts {
        self.lock();
        defer self.mutex.unlock();
        const fact = self.find(original.owner, original.operation_id) orelse return error.UnknownOperation;
        if (fact.stage != .outcome_unknown) return error.OperationNotUnknown;
        if (original.owner.eql(owner) and original.operation_id == operation_id) return error.QueryMustBeNewOperation;
        const existed = self.find(owner, operation_id) != null;
        const query = try self.beginLocked(owner, operation_id, tool_id, arguments_hash, authorization_revision);
        if (query.query_of) |prior| if (!prior.owner.eql(original.owner) or prior.operation_id != original.operation_id) return error.OperationIdentityConflict;
        if (query.query_of == null) {
            if (existed) query.event_revision = try identity.advance(query.event_revision);
            query.query_of = original;
        }
        return facts(query.*);
    }
    /// A verified read reconciles history only; it never dispatches an action.
    pub fn reconcileUnknown(self: *Store, query_owner: identity.SessionHandle, query_operation_id: u64, succeeded: bool, safe_result: []const u8) !void {
        self.lock();
        defer self.mutex.unlock();
        const query = self.find(query_owner, query_operation_id) orelse return error.UnknownOperation;
        if (query.stage != .succeeded) return error.QueryNotVerified;
        const original = query.query_of orelse return error.NotAReadQuery;
        const fact = self.find(original.owner, original.operation_id) orelse return error.UnknownOperation;
        if (fact.stage != .outcome_unknown) return error.OperationNotUnknown;
        if (safe_result.len > 4096) return error.OperationResultTooLarge;
        const revision = try identity.advance(fact.event_revision);
        const owned = try self.allocator.dupe(u8, safe_result);
        self.allocator.free(fact.result_text);
        fact.result_text = owned;
        fact.stage = if (succeeded) .succeeded else .failed;
        fact.event_revision = revision;
    }
    pub fn lookup(self: *Store, owner: identity.SessionHandle, operation_id: u64) ?Facts {
        self.lock();
        defer self.mutex.unlock();
        return if (self.find(owner, operation_id)) |record| facts(record.*) else null;
    }
    pub fn snapshot(self: *Store, allocator: std.mem.Allocator, owner: identity.SessionHandle, operation_id: u64) !?Snapshot {
        self.lock();
        defer self.mutex.unlock();
        const record = self.find(owner, operation_id) orelse return null;
        const tool_id = try allocator.dupe(u8, record.tool_id);
        errdefer allocator.free(tool_id);
        const result_text = try allocator.dupe(u8, record.result_text);
        var value = record.*;
        value.tool_id = tool_id;
        value.result_text = result_text;
        return .{ .value = value, .allocator = allocator };
    }
    pub fn update(self: *Store, owner: identity.SessionHandle, operation_id: u64, revision: u64, stage: Stage, safe_result: []const u8) !bool {
        self.lock();
        defer self.mutex.unlock();
        return self.updateLocked(owner, operation_id, revision, stage, safe_result);
    }
    fn updateLocked(self: *Store, owner: identity.SessionHandle, operation_id: u64, revision: u64, stage: Stage, safe_result: []const u8) !bool {
        const record = self.find(owner, operation_id) orelse return error.UnknownOperation;
        if (revision <= record.event_revision) return false;
        if (!legal(record.stage, stage)) return error.InvalidOperationTransition;
        if (record.owner_closed and stage != .outcome_unknown) return error.OwnerClosed;
        if (safe_result.len > 4096) return error.OperationResultTooLarge;
        const owned = try self.allocator.dupe(u8, safe_result);
        self.allocator.free(record.result_text);
        record.result_text = owned;
        record.event_revision = revision;
        record.stage = stage;
        return true;
    }
    /// Transition against the current revision atomically, without retaining a
    /// lookup snapshot across a competing cancellation or close.
    pub fn transition(self: *Store, owner: identity.SessionHandle, operation_id: u64, stage: Stage, safe_result: []const u8) !void {
        self.lock();
        defer self.mutex.unlock();
        const record = self.find(owner, operation_id) orelse return error.UnknownOperation;
        _ = try self.updateLocked(owner, operation_id, try identity.advance(record.event_revision), stage, safe_result);
    }
    /// Claim exactly one send. Repeating a .sent transition cannot replay it.
    pub fn markSent(self: *Store, owner: identity.SessionHandle, operation_id: u64) !void {
        self.lock();
        defer self.mutex.unlock();
        const record = self.find(owner, operation_id) orelse return error.UnknownOperation;
        if (record.stage != .prepared and record.stage != .approved) return error.ToolOperationAlreadyRecorded;
        _ = try self.updateLocked(owner, operation_id, try identity.advance(record.event_revision), .sent, "");
    }
    pub fn cancel(self: *Store, owner: identity.SessionHandle, operation_id: u64) !void {
        self.lock();
        defer self.mutex.unlock();
        const record = self.find(owner, operation_id) orelse return error.UnknownOperation;
        if (record.terminal()) return;
        const stage: Stage = if (record.stage == .sent or record.stage == .verifying) .outcome_unknown else .cancelled_unsent;
        _ = try self.updateLocked(owner, operation_id, try identity.advance(record.event_revision), stage, "");
    }
    pub fn finish(self: *Store, owner: identity.SessionHandle, operation_id: u64, succeeded: bool, safe_result: []const u8) !void {
        return self.transition(owner, operation_id, if (succeeded) .succeeded else .failed, safe_result);
    }
    /// Only actual owner close calls this. Bridge/window disposal is not close.
    /// Facts carry the close marker; empty owners allocate no tombstone and
    /// history capacity must never block releasing a real session. This store
    /// is not live authority: every new action still needs SessionHost preflight.
    pub fn ownerClosed(self: *Store, owner: identity.SessionHandle) !void {
        self.lock();
        defer self.mutex.unlock();
        for (self.records.items) |*record| if (record.owner.eql(owner)) {
            if (record.owner_closed) continue;
            const revision = try identity.advance(record.event_revision);
            if (!record.terminal()) record.stage = if (record.stage == .sent or record.stage == .verifying) .outcome_unknown else .cancelled_unsent;
            record.owner_closed = true;
            record.event_revision = revision;
        };
    }
    pub fn resourcesReleased(self: *Store, owner: identity.SessionHandle, operation_id: u64) !void {
        self.lock();
        defer self.mutex.unlock();
        const record = self.find(owner, operation_id) orelse return error.UnknownOperation;
        if (record.resources_released) return;
        const revision = try identity.advance(record.event_revision);
        record.resources_released = true;
        record.event_revision = revision;
    }
    pub fn clearCompleted(self: *Store, include_unknown: bool) usize {
        self.lock();
        defer self.mutex.unlock();
        var removed: usize = 0;
        var i: usize = 0;
        while (i < self.records.items.len) {
            const record = self.records.items[i];
            if (record.terminal() and record.resources_released and (include_unknown or record.stage != .outcome_unknown)) {
                self.release(self.records.orderedRemove(i));
                removed += 1;
            } else i += 1;
        }
        return removed;
    }
    // Internal pointers never escape a method's lock.
    fn find(self: *Store, owner: identity.SessionHandle, operation_id: u64) ?*Record {
        for (self.records.items) |*record| if (record.owner.eql(owner) and record.operation_id == operation_id) return record;
        return null;
    }
    fn release(self: *Store, record: Record) void {
        self.allocator.free(record.tool_id);
        self.allocator.free(record.result_text);
    }
};
pub const OperationStore = Store;
fn legal(from: Stage, to: Stage) bool {
    if (from == to) return true;
    return switch (from) {
        .prepared => to == .pending_approval or to == .approved or to == .sent or to == .cancelled_unsent or to == .rejected or to == .failed,
        .pending_approval => to == .approved or to == .rejected or to == .cancelled_unsent,
        .approved => to == .sent or to == .cancelled_unsent or to == .rejected,
        .sent => to == .verifying or to == .succeeded or to == .failed or to == .outcome_unknown,
        .verifying => to == .succeeded or to == .failed or to == .outcome_unknown,
        // A query is a separate newly-authorized operation. Its result may
        // reconcile this history fact, but never redispatch the original write.
        .outcome_unknown => false,
        else => false,
    };
}
test "operation cancellation preserves unknown result and owner generation" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(1) };
    _ = try store.begin(owner, 1, "fixture.write", @splat(0), 1);
    _ = try store.update(owner, 1, 2, .sent, "accepted");
    try store.cancel(owner, 1);
    try std.testing.expectEqual(Stage.outcome_unknown, store.lookup(owner, 1).?.stage);
    try std.testing.expectError(error.InvalidOperationTransition, store.finish(owner, 1, true, "late"));
    try store.ownerClosed(owner);
    try std.testing.expectError(error.OwnerClosed, store.begin(owner, 2, "fixture.query", @splat(0), 2));
    _ = try store.begin(try owner.nextGeneration(), 2, "fixture.query", @splat(0), 2);
    try store.resourcesReleased(owner, 1);
    try std.testing.expectEqual(@as(usize, 0), store.clearCompleted(false));
    try std.testing.expectEqual(@as(usize, 1), store.clearCompleted(true));
}
test "operation history full applies backpressure without evicting unknown facts" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(1) };
    for (0..Store.capacity) |i| _ = try store.begin(owner, i + 1, "fixture.ping", @splat(0), 1);
    try std.testing.expectError(error.OperationHistoryFull, store.begin(owner, 999, "fixture.ping", @splat(0), 1));
    try std.testing.expectError(error.OperationIdentityConflict, store.begin(owner, 1, "fixture.write", @splat(0), 1));
}

test "unknown history only reconciles through a new authorized read query" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(9) };
    _ = try store.begin(owner, 1, "fixture.write", @splat(0), 1);
    _ = try store.update(owner, 1, 2, .sent, "accepted");
    try store.ownerClosed(owner);
    const next = try owner.nextGeneration();
    _ = try store.beginReadQuery(next, 2, "fixture.query", @splat(1), 2, .{ .owner = owner, .operation_id = 1 });
    try std.testing.expectError(error.QueryNotVerified, store.reconcileUnknown(next, 2, true, "verified"));
    _ = try store.update(next, 2, 2, .sent, "");
    try store.finish(next, 2, true, "observed");
    try store.reconcileUnknown(next, 2, true, "verified by read query");
    try std.testing.expectEqual(Stage.succeeded, store.lookup(owner, 1).?.stage);
    try std.testing.expect(store.lookup(owner, 1).?.owner_closed);
    try std.testing.expectError(error.OwnerClosed, store.begin(owner, 3, "fixture.write", @splat(0), 3));
}

test "operation snapshots own complete strings across updates cleanup and store disposal" {
    const a = std.testing.allocator;
    var store = Store.init(a);
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(11) };
    _ = try store.beginNew(owner, 1, "fixture.read", @splat(0), 1);
    try store.markSent(owner, 1);
    try store.transition(owner, 1, .verifying, "original safe result");
    var saved = (try store.snapshot(a, owner, 1)).?;
    defer saved.deinit();
    try store.finish(owner, 1, true, "replacement safe result");
    try store.resourcesReleased(owner, 1);
    try std.testing.expectEqual(@as(usize, 1), store.clearCompleted(false));
    store.deinit();
    try std.testing.expectEqualStrings("fixture.read", saved.value.tool_id);
    try std.testing.expectEqualStrings("original safe result", saved.value.result_text);
    try std.testing.expectEqual(Stage.verifying, saved.value.stage);
}

test "operation closing empty owners cannot exhaust history or block resource release" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    for (1..Store.capacity * 3) |id| try store.ownerClosed(.{ .session_id = @fromBackingInt(id) });
    try std.testing.expectEqual(@as(usize, 0), store.count());
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(999) };
    _ = try store.beginNew(owner, 1, "fixture.write", @splat(0), 1);
    try std.testing.expect(store.hasPending(owner));
    try store.markSent(owner, 1);
    const sent_revision = store.lookup(owner, 1).?.event_revision;
    try store.ownerClosed(owner);
    const closed_revision = store.lookup(owner, 1).?.event_revision;
    try std.testing.expectEqual(sent_revision + 1, closed_revision);
    try store.ownerClosed(owner);
    try std.testing.expectEqual(closed_revision, store.lookup(owner, 1).?.event_revision);
    try store.resourcesReleased(owner, 1);
    const released_revision = store.lookup(owner, 1).?.event_revision;
    try std.testing.expectEqual(closed_revision + 1, released_revision);
    try store.resourcesReleased(owner, 1);
    try std.testing.expectEqual(released_revision, store.lookup(owner, 1).?.event_revision);
    try std.testing.expect(!store.hasPending(owner));
    try std.testing.expect(store.lookup(owner, 1).?.owner_closed);
    try std.testing.expectEqual(Stage.outcome_unknown, store.lookup(owner, 1).?.stage);
    try std.testing.expectError(error.OwnerClosed, store.beginNew(owner, 2, "fixture.read", @splat(0), 1));
}
