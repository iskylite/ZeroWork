const std = @import("std");
const identity = @import("identity.zig");

pub const OperationKey = struct {
    owner: identity.CommandOwner,
    operation_id: u64,
    attempt_id: ?u64 = null,

    pub fn eql(self: OperationKey, other: OperationKey) bool {
        return std.meta.eql(self, other);
    }
};

pub const Effect = enum { none, partial, unknown };
pub const Cleanup = enum { not_started, releasing, released, unknown };
pub const Failure = struct {
    domain: enum { host, plugin, transport, workspace, settings },
    code: []const u8,
    stage: ?[]const u8 = null,
    hop: ?u8 = null,
    retryable: bool = false,
    effect: Effect = .none,
    cleanup: Cleanup = .not_started,
    safe_message: []const u8,
};

pub const EventKind = enum {
    progress,
    completed,
    failed,
    cancelled,
    cleanup_progress,
    cleanup_released,
    cleanup_unknown,

    pub fn isTerminal(self: EventKind) bool {
        return self == .completed or self == .failed or self == .cancelled;
    }

    pub fn isCleanup(self: EventKind) bool {
        return self == .cleanup_progress or self == .cleanup_released or self == .cleanup_unknown;
    }
};

pub const Event = struct {
    key: OperationKey,
    sequence: u64,
    kind: EventKind,
    payload: []const u8 = &.{},
    failure: ?Failure = null,
};

/// A queued value owns all text, including error metadata. Exactly one consumer
/// calls deinit after receiving it. Successful sends transfer this whole value;
/// failed sends leave ownership with the sender.
pub const OwnedEvent = struct {
    arena: std.heap.ArenaAllocator,
    value: Event,

    pub fn init(allocator: std.mem.Allocator, event: Event) !OwnedEvent {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        var copy = event;
        copy.payload = try owned.dupe(u8, event.payload);
        if (event.failure) |failure| {
            var failure_copy = failure;
            failure_copy.code = try owned.dupe(u8, failure.code);
            failure_copy.stage = if (failure.stage) |stage| try owned.dupe(u8, stage) else null;
            failure_copy.safe_message = try owned.dupe(u8, failure.safe_message);
            copy.failure = failure_copy;
        }
        return .{ .arena = arena, .value = copy };
    }

    pub fn deinit(self: *OwnedEvent) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const Record = struct {
    key: OperationKey,
    next_sequence: u64 = 1,
    terminal: bool = false,
    cleanup_released: bool = false,
};

/// Main-thread operation journal. Event allocation/queueing completes before
/// state advances, so allocation failure cannot silently consume a terminal.
/// Cleanup has its own gate and remains deliverable after business failure.
pub const Journal = struct {
    allocator: std.mem.Allocator,
    next_operation: u64 = 1,
    exhausted: bool = false,
    records: std.ArrayList(Record) = .empty,
    events: std.ArrayList(OwnedEvent) = .empty,

    pub fn init(allocator: std.mem.Allocator) Journal {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Journal) void {
        for (self.events.items) |*event| event.deinit();
        self.events.deinit(self.allocator);
        self.records.deinit(self.allocator);
    }

    pub fn begin(self: *Journal, owner: identity.CommandOwner, attempt_id: ?u64) !OperationKey {
        if (self.exhausted or self.next_operation == 0) return error.OperationExhausted;
        if (attempt_id == 0) return error.InvalidAttempt;
        const key: OperationKey = .{ .owner = owner, .operation_id = self.next_operation, .attempt_id = attempt_id };
        try self.records.append(self.allocator, .{ .key = key });
        if (self.next_operation == std.math.maxInt(u64)) self.exhausted = true else self.next_operation += 1;
        return key;
    }

    /// Returns false for duplicate business terminals/progress after terminal.
    /// Unknown cleanup may later converge to released on the same operation.
    pub fn publish(self: *Journal, key: OperationKey, kind: EventKind, payload: []const u8, failure: ?Failure) !bool {
        const record = self.find(key) orelse return error.UnknownOperation;
        if ((record.terminal and !kind.isCleanup()) or (kind.isCleanup() and record.cleanup_released)) return false;
        if (record.next_sequence == std.math.maxInt(u64)) return error.SequenceExhausted;
        var event = try OwnedEvent.init(self.allocator, .{ .key = key, .sequence = record.next_sequence, .kind = kind, .payload = payload, .failure = failure });
        errdefer event.deinit();
        try self.events.append(self.allocator, event);
        record.next_sequence += 1;
        if (kind.isTerminal()) record.terminal = true;
        if (kind == .cleanup_released) record.cleanup_released = true;
        return true;
    }

    pub fn take(self: *Journal) ?OwnedEvent {
        return if (self.events.items.len == 0) null else self.events.orderedRemove(0);
    }

    /// Close completion and its release receipt are one publication transaction.
    /// In particular, OOM cannot leave a terminal without the cleanup receipt.
    pub fn completeReleased(self: *Journal, key: OperationKey, payload: []const u8) !bool {
        return self.terminateReleased(key, .completed, payload, null);
    }

    pub fn failReleased(self: *Journal, key: OperationKey, failure: Failure) !bool {
        return self.terminateReleased(key, .failed, "", failure);
    }

    fn terminateReleased(self: *Journal, key: OperationKey, kind: EventKind, payload: []const u8, failure: ?Failure) !bool {
        const record = self.find(key) orelse return error.UnknownOperation;
        if (record.terminal) return false;
        if (record.next_sequence >= std.math.maxInt(u64) - 1) return error.SequenceExhausted;
        var completed = try OwnedEvent.init(self.allocator, .{ .key = key, .sequence = record.next_sequence, .kind = kind, .payload = payload, .failure = failure });
        errdefer completed.deinit();
        var released = try OwnedEvent.init(self.allocator, .{ .key = key, .sequence = record.next_sequence + 1, .kind = .cleanup_released });
        errdefer released.deinit();
        try self.events.ensureUnusedCapacity(self.allocator, 2);
        self.events.appendAssumeCapacity(completed);
        self.events.appendAssumeCapacity(released);
        record.next_sequence += 2;
        record.terminal = true;
        record.cleanup_released = true;
        return true;
    }

    pub fn isTerminal(self: *Journal, key: OperationKey) bool {
        return if (self.find(key)) |record| record.terminal else false;
    }

    /// The resource controller supplies explicit ownership evidence. A create
    /// operation may retire once its resources moved to live service bindings;
    /// cleanup_unknown cannot use resources_released until the receipt arrives.
    pub fn retire(self: *Journal, key: OperationKey, evidence: enum { resources_released, no_resources, transferred_to_owner }) !void {
        for (self.records.items, 0..) |record, index| {
            if (!record.key.eql(key)) continue;
            if (!record.terminal) return error.OperationNotTerminal;
            if (evidence == .resources_released and !record.cleanup_released) return error.CleanupNotReleased;
            _ = self.records.orderedRemove(index);
            return;
        }
        return error.UnknownOperation;
    }

    fn find(self: *Journal, key: OperationKey) ?*Record {
        for (self.records.items) |*record| if (record.key.eql(key)) return record;
        return null;
    }
};

/// One adapter worker is the sole producer; the UI/controller is the sole
/// consumer. Give each additional worker its own mailbox. Byte events are never
/// coalesced: a full queue applies backpressure and keeps sender ownership.
pub const Mailbox = struct {
    entries: []OwnedEvent,
    write: std.atomic.Value(usize) = .init(0),
    read: std.atomic.Value(usize) = .init(0),

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Mailbox {
        // Power-of-two indexing remains correct when the unsigned counters wrap.
        if (capacity == 0 or !std.math.isPowerOfTwo(capacity)) return error.InvalidCapacity;
        return .{ .entries = try allocator.alloc(OwnedEvent, capacity) };
    }

    /// Both worker and UI must be stopped before destruction.
    pub fn deinit(self: *Mailbox, allocator: std.mem.Allocator) void {
        while (self.take()) |received| {
            var event = received;
            event.deinit();
        }
        allocator.free(self.entries);
    }

    pub fn send(self: *Mailbox, event: OwnedEvent) !void {
        const write = self.write.load(.monotonic);
        const read = self.read.load(.acquire);
        if (write -% read == self.entries.len) return error.Full;
        self.entries[write % self.entries.len] = event;
        self.write.store(write +% 1, .release);
    }

    pub fn take(self: *Mailbox) ?OwnedEvent {
        const read = self.read.load(.monotonic);
        const write = self.write.load(.acquire);
        if (read == write) return null;
        const event = self.entries[read % self.entries.len];
        self.read.store(read +% 1, .release);
        return event;
    }
};

test "business terminal is unique and cleanup still converges after failure" {
    var journal = Journal.init(std.testing.allocator);
    defer journal.deinit();
    const key = try journal.begin(.app, 1);
    try std.testing.expect(try journal.publish(key, .failed, "failed", .{ .domain = .transport, .code = "timeout", .effect = .unknown, .cleanup = .releasing, .safe_message = "连接超时" }));
    try std.testing.expect(!try journal.publish(key, .completed, "late success", null));
    try std.testing.expect(try journal.publish(key, .cleanup_unknown, "", null));
    try std.testing.expect(try journal.publish(key, .cleanup_released, "", null));
    try std.testing.expect(!try journal.publish(key, .cleanup_released, "", null));
    var expected: u64 = 1;
    while (journal.take()) |received| {
        var event = received;
        defer event.deinit();
        try std.testing.expectEqual(expected, event.value.sequence);
        expected += 1;
    }
    try std.testing.expectEqual(@as(u64, 4), expected);
}

test "mailbox owns copied bytes and full send retains sender ownership" {
    var mailbox = try Mailbox.init(std.testing.allocator, 1);
    defer mailbox.deinit(std.testing.allocator);
    var bytes = [_]u8{ 'a', 0, 'b', '\n' };
    const key: OperationKey = .{ .owner = .app, .operation_id = 1 };
    const first = try OwnedEvent.init(std.testing.allocator, .{ .key = key, .sequence = 1, .kind = .progress, .payload = &bytes });
    try mailbox.send(first);
    bytes[0] = 'X';
    var rejected = try OwnedEvent.init(std.testing.allocator, .{ .key = key, .sequence = 2, .kind = .failed });
    defer rejected.deinit();
    try std.testing.expectError(error.Full, mailbox.send(rejected));
    var received = mailbox.take().?;
    defer received.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 'a', 0, 'b', '\n' }, received.value.payload);
    try std.testing.expect(mailbox.take() == null);
}

test "operation keys isolate attempts and exhaustion never reuses a key" {
    var journal = Journal.init(std.testing.allocator);
    defer journal.deinit();
    const key = try journal.begin(.app, 1);
    var wrong_attempt = key;
    wrong_attempt.attempt_id = 2;
    try std.testing.expectError(error.UnknownOperation, journal.publish(wrong_attempt, .cancelled, "", null));
    journal.next_operation = std.math.maxInt(u64);
    _ = try journal.begin(.app, null);
    try std.testing.expectError(error.OperationExhausted, journal.begin(.app, null));
}

test "retirement requires terminal and explicit resource ownership evidence" {
    var journal = Journal.init(std.testing.allocator);
    defer journal.deinit();
    const key = try journal.begin(.app, null);
    try std.testing.expectError(error.OperationNotTerminal, journal.retire(key, .no_resources));
    _ = try journal.publish(key, .failed, "", null);
    _ = try journal.publish(key, .cleanup_unknown, "", null);
    try std.testing.expectError(error.CleanupNotReleased, journal.retire(key, .resources_released));
    _ = try journal.publish(key, .cleanup_released, "", null);
    try journal.retire(key, .resources_released);
    try std.testing.expectEqual(@as(usize, 0), journal.records.items.len);
    try std.testing.expectError(error.UnknownOperation, journal.publish(key, .completed, "", null));
}

fn completeWithAllocationFailures(allocator: std.mem.Allocator) !void {
    var journal = Journal.init(allocator);
    defer journal.deinit();
    const key = try journal.begin(.app, null);
    _ = journal.completeReleased(key, "closed") catch |err| {
        try std.testing.expect(!journal.isTerminal(key));
        try std.testing.expectEqual(@as(usize, 0), journal.events.items.len);
        return err;
    };
    try std.testing.expect(journal.isTerminal(key));
    try std.testing.expectEqual(@as(usize, 2), journal.events.items.len);
}

test "close publication allocation failures retain a retryable operation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, completeWithAllocationFailures, .{});
}
