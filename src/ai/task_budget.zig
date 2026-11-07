//! Shared, durable task-tree counters. Stable roots outlive every joined Worker.
const std = @import("std");
const id = @import("../host/identity.zig");
const provider = @import("provider.zig");
const Clock = @import("retry.zig").Clock;
pub const Status = enum { running, human_wait, waiting_model, waiting_children, settling, succeeded, failed, cancelled, interrupted, outcome_unknown };
pub fn terminal(status: Status) bool {
    return switch (status) {
        .succeeded, .failed, .cancelled, .interrupted, .outcome_unknown => true,
        else => false,
    };
}
pub const Counters = struct {
    requests: u32 = 0,
    calls: u32 = 0,
    pending_requests: u32 = 0,
    elapsed_ns: u64 = 0,
    timeout_ns: u64 = 10 * 60 * std.time.ns_per_s,
    max_requests: u32 = 16,
    max_calls: u32 = 64,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    usage_complete: bool = true,
};
pub const Fact = struct {
    root: id.TaskId,
    task: id.TaskId,
    parent: ?id.TaskId = null,
    conversation: id.ConversationId,
    agent: id.AgentId,
    generation: u64,
    sequence: u64 = 1,
    event_sequence: u64 = 0,
    status: Status = .running,
    request_key: []const u8 = "",
    input_hash: [32]u8 = @splat(0),
    summary: []const u8 = "",
    delivered: bool = false,
    attempt: u32 = 1,
    user_waits: u32 = 0,
    reported_sequence: u64 = 0,
    counters: Counters = .{},
    created_at_ms: i64 = 0,
    changed_at_ms: i64 = 0,
    read_only: bool = false,
    targets: ?[]const id.SessionHandle = null,
    pub fn validate(self: Fact) !void {
        if (!self.root.valid() or !self.task.valid() or !self.conversation.valid() or !self.agent.valid() or self.generation == 0 or self.sequence == 0 or self.attempt == 0 or self.summary.len > 4096 or self.request_key.len > 128 or !std.unicode.utf8ValidateSlice(self.summary) or !std.unicode.utf8ValidateSlice(self.request_key)) return error.InvalidTaskFact;
        if (self.targets) |targets| {
            if (targets.len > 32) return error.InvalidTaskFact;
            for (targets, 0..) |target, i| {
                if (@backingInt(target.session_id) == 0 or target.generation == 0) return error.InvalidTaskFact;
                for (targets[0..i]) |prior| if (prior.session_id == target.session_id) return error.InvalidTaskFact;
            }
        }
        if (self.parent) |parent| {
            if (!parent.eql(self.root) or self.task.eql(self.root)) return error.InvalidTaskFact;
        } else if (!self.task.eql(self.root)) return error.InvalidTaskFact;
        if (self.counters.pending_requests > self.counters.requests or self.counters.requests > self.counters.max_requests or self.counters.calls > self.counters.max_calls or self.counters.max_requests == 0 or self.counters.max_calls == 0 or self.counters.timeout_ns == 0) return error.InvalidTaskFact;
    }
};
pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    fact: Fact,
    pub fn init(a: std.mem.Allocator, fact: Fact) !Owned {
        try fact.validate();
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        var copy = fact;
        copy.summary = try arena.allocator().dupe(u8, fact.summary);
        copy.request_key = try arena.allocator().dupe(u8, fact.request_key);
        if (fact.targets) |targets| copy.targets = try arena.allocator().dupe(id.SessionHandle, targets);
        return .{ .arena = arena, .fact = copy };
    }
    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
    }
};
pub const Persist = struct { context: *anyopaque, write: *const fn (*anyopaque, Fact) anyerror!void };
pub const Root = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    mutex: std.atomic.Mutex = .unlocked,
    facts: [32]Fact = undefined,
    count: usize = 0,
    counters: Counters = .{},
    revision: u64 = 0,
    last_ns: i128,
    persist: ?Persist = null,
    failed_storage: bool = false,
    cancelled: bool = false,
    pub fn init(a: std.mem.Allocator) Root {
        return .{ .allocator = a, .arena = .init(a), .last_ns = (Clock{}).now() };
    }
    pub fn deinit(self: *Root) void {
        self.arena.deinit();
    }
    pub fn lock(self: *Root) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    fn machineActive(self: *Root) bool {
        for (self.facts[0..self.count]) |fact| if (fact.status == .running or fact.status == .settling) return true;
        return false;
    }
    fn settleClock(self: *Root) void {
        const now = (Clock{}).now();
        if (self.machineActive()) self.counters.elapsed_ns +|= @intCast(@max(0, now - self.last_ns));
        self.last_ns = now;
    }
    fn checkLocked(self: *Root) !void {
        self.settleClock();
        if (self.cancelled) return error.Cancelled;
        if (self.failed_storage) return error.TaskPersistenceFailed;
        if (self.counters.elapsed_ns >= self.counters.timeout_ns) return error.SharedTaskTimeout;
    }
    pub fn check(self: *Root) !void {
        self.lock();
        defer self.mutex.unlock();
        try self.checkLocked();
    }
    fn index(self: *Root, task: id.TaskId) !usize {
        for (self.facts[0..self.count], 0..) |fact, i| if (fact.task.eql(task)) return i;
        return error.TaskNotFound;
    }
    fn write(self: *Root, original: Fact) !Fact {
        var fact = original;
        const now_ms = @import("../platform/realtime.zig").milliseconds(undefined);
        if (fact.created_at_ms == 0) fact.created_at_ms = now_ms;
        var changed = fact.changed_at_ms == 0;
        for (self.facts[0..self.count]) |prior| if (prior.task.eql(fact.task)) {
            changed = changed or prior.status != fact.status or prior.attempt != fact.attempt or prior.user_waits != fact.user_waits;
            break;
        };
        if (changed) fact.changed_at_ms = @max(fact.changed_at_ms, now_ms);
        fact.sequence = if (self.revision == 0) 1 else try id.advance(self.revision);
        fact.counters = self.counters;
        if (fact.event_sequence == 0) fact.event_sequence = fact.sequence;
        try fact.validate();
        if (self.persist) |p| p.write(p.context, fact) catch |err| {
            self.failed_storage = true;
            return err;
        };
        self.revision = fact.sequence;
        return fact;
    }
    pub fn add(self: *Root, original: Fact) !void {
        self.lock();
        defer self.mutex.unlock();
        try self.checkLocked();
        if (self.count == self.facts.len) return error.TaskHistoryLimit;
        if (original.parent != null) {
            var active: usize = 0;
            for (self.facts[0..self.count]) |fact| if (fact.parent != null and !terminal(fact.status)) {
                active += 1;
            };
            if (active >= 4) return error.ChildTaskLimit;
        }
        var fact = original;
        fact.request_key = try self.arena.allocator().dupe(u8, fact.request_key);
        if (fact.targets) |targets| fact.targets = try self.arena.allocator().dupe(id.SessionHandle, targets);
        fact.summary = try self.arena.allocator().dupe(u8, fact.summary);
        self.facts[self.count] = try self.write(fact);
        self.count += 1;
    }
    /// Hold the root revision stable while the controller commits the atomic
    /// child record+first-input row. Sibling Workers cannot race its sequence.
    pub fn launch(self: *Root, original: Fact, context: *anyopaque, commit: *const fn (*anyopaque, *Fact) anyerror!void) !Fact {
        self.lock();
        defer self.mutex.unlock();
        try self.checkLocked();
        if (self.count == self.facts.len) return error.TaskHistoryLimit;
        var active: usize = 0;
        for (self.facts[0..self.count]) |fact| if (fact.parent != null and !terminal(fact.status)) {
            active += 1;
        };
        if (active >= 4) return error.ChildTaskLimit;
        var fact = original;
        fact.request_key = try self.arena.allocator().dupe(u8, original.request_key);
        if (original.targets) |targets| fact.targets = try self.arena.allocator().dupe(id.SessionHandle, targets);
        fact.created_at_ms = @import("../platform/realtime.zig").milliseconds(undefined);
        fact.changed_at_ms = fact.created_at_ms;
        fact.sequence = if (self.revision == 0) 1 else try id.advance(self.revision);
        fact.counters = self.counters;
        fact.event_sequence = fact.sequence;
        try commit(context, &fact);
        self.facts[self.count] = fact;
        self.count += 1;
        self.revision = fact.sequence;
        return fact;
    }
    /// A released child moves to its next queued task under one root lock.
    /// The parent cannot observe a gap with no unfinished child and finish.
    pub fn rollover(self: *Root, previous: id.TaskId, outcome: Status, original: Fact) !void {
        self.lock();
        defer self.mutex.unlock();
        try self.checkLocked();
        if (self.count == self.facts.len) return error.TaskHistoryLimit;
        const index_ = try self.index(previous);
        const prior = self.facts[index_];
        if (prior.parent == null or !std.meta.eql(prior.parent, original.parent) or !prior.agent.eql(original.agent) or !prior.conversation.eql(original.conversation) or !prior.root.eql(original.root) or !terminal(outcome) or original.task.eql(previous)) return error.InvalidTaskFact;
        var next = original;
        next.request_key = try self.arena.allocator().dupe(u8, original.request_key);
        next.summary = try self.arena.allocator().dupe(u8, original.summary);
        if (next.targets) |targets| next.targets = try self.arena.allocator().dupe(id.SessionHandle, targets);
        next.created_at_ms = @import("../platform/realtime.zig").milliseconds(undefined);
        next.changed_at_ms = next.created_at_ms;
        try next.validate();
        var done = prior;
        done.status = outcome;
        done.event_sequence = 0;
        self.facts[index_] = try self.write(done);
        self.facts[self.count] = try self.write(next);
        self.count += 1;
    }

    pub fn remainingNs(self: *Root) !u64 {
        self.lock();
        defer self.mutex.unlock();
        try self.checkLocked();
        return self.counters.timeout_ns -| self.counters.elapsed_ns;
    }
    pub fn userWait(self: *Root, task: id.TaskId, entering: bool) !void {
        self.lock();
        defer self.mutex.unlock();
        self.settleClock();
        const i = try self.index(task);
        if (terminal(self.facts[i].status)) return;
        var fact = self.facts[i];
        if (entering) fact.user_waits = try std.math.add(u32, fact.user_waits, 1) else fact.user_waits -|= 1;
        const status: Status = if (fact.user_waits == 0) .running else .human_wait;
        if (status != fact.status) fact.event_sequence = 0;
        fact.status = status;
        self.facts[i] = try self.write(fact);
    }
    pub fn configure(self: *Root, task: id.TaskId, timeout_ms: u32, requests: u16, calls: u16) !void {
        self.lock();
        defer self.mutex.unlock();
        const i = try self.index(task);
        if (self.facts[i].parent == null and self.counters.requests == 0 and self.counters.calls == 0) {
            self.counters.timeout_ns = @as(u64, timeout_ms) * std.time.ns_per_ms;
            self.counters.max_requests = requests;
            self.counters.max_calls = calls;
        }
    }
    pub fn resumeAnswer(self: *Root, task: id.TaskId) !void {
        self.lock();
        defer self.mutex.unlock();
        self.settleClock();
        if (self.failed_storage) return error.TaskPersistenceFailed;
        if (self.counters.elapsed_ns >= self.counters.timeout_ns) return error.SharedTaskTimeout;
        const i = try self.index(task);
        if (self.facts[i].status == .cancelled or self.facts[i].status == .interrupted) return error.TaskAlreadyFinished;
        for (self.facts[0..self.count]) |fact| if (fact.parent != null and !terminal(fact.status)) return error.ChildSettlementRequired;
        var fact = self.facts[i];
        fact.status = .running;
        fact.event_sequence = 0;
        fact.attempt = try std.math.add(u32, fact.attempt, 1);
        self.facts[i] = try self.write(fact);
        self.cancelled = false;
    }
    pub fn acknowledge(self: *Root, task: id.TaskId, sequence: u64) !void {
        self.lock();
        defer self.mutex.unlock();
        const i = try self.index(task);
        if (self.facts[i].event_sequence != sequence or self.facts[i].reported_sequence >= sequence) return;
        var fact = self.facts[i];
        fact.delivered = terminal(fact.status);
        fact.reported_sequence = sequence;
        self.facts[i] = try self.write(fact);
    }
    pub fn take(self: *Root, task: id.TaskId, requests: u32, calls: u32) !void {
        self.lock();
        defer self.mutex.unlock();
        try self.checkLocked();
        const i = try self.index(task);
        if (terminal(self.facts[i].status)) return error.TaskAlreadyFinished;
        if (requests > self.counters.max_requests -| self.counters.requests) return error.SharedRequestLimit;
        if (calls > self.counters.max_calls -| self.counters.calls) return error.SharedToolCallLimit;
        const prior = self.counters;
        self.counters.requests += requests;
        self.counters.pending_requests += requests;
        self.counters.calls += calls;
        self.facts[i] = self.write(self.facts[i]) catch |err| {
            self.counters = prior;
            return err;
        };
    }
    pub fn state(self: *Root, task: id.TaskId, status: Status, summary: []const u8) !void {
        self.lock();
        defer self.mutex.unlock();
        self.settleClock();
        const i = try self.index(task);
        if (terminal(self.facts[i].status)) return;
        var fact = self.facts[i];
        if (fact.status != status or (summary.len != 0 and !std.mem.eql(u8, fact.summary, summary))) fact.event_sequence = 0;
        fact.status = status;
        if (summary.len != 0) {
            var n = @min(summary.len, 4096);
            while (n > 0 and !std.unicode.utf8ValidateSlice(summary[0..n])) n -= 1;
            fact.summary = try self.arena.allocator().dupe(u8, summary[0..n]);
        }
        self.facts[i] = try self.write(fact);
        if (fact.parent == null and (status == .failed or status == .cancelled or status == .interrupted)) self.cancelled = true;
    }
    pub fn usage(self: *Root, task: id.TaskId, stats: ?provider.ChatStats) !void {
        self.lock();
        defer self.mutex.unlock();
        self.settleClock();
        const i = try self.index(task);
        self.counters.pending_requests -|= 1;
        if (stats) |value| {
            self.counters.input_tokens +|= value.input_tokens;
            self.counters.output_tokens +|= value.output_tokens;
            self.counters.usage_complete = self.counters.usage_complete and value.usage_reported;
        } else self.counters.usage_complete = false;
        self.facts[i] = try self.write(self.facts[i]);
    }
    pub fn needsChildren(self: *Root, parent: id.TaskId) bool {
        self.lock();
        defer self.mutex.unlock();
        for (self.facts[0..self.count]) |fact| if (fact.parent != null and fact.parent.?.eql(parent) and (!terminal(fact.status) or !fact.delivered)) return true;
        return false;
    }
    pub fn unreportedHuman(self: *Root, parent: id.TaskId) bool {
        self.lock();
        defer self.mutex.unlock();
        for (self.facts[0..self.count]) |fact| if (fact.parent != null and fact.parent.?.eql(parent) and fact.status == .human_wait and fact.event_sequence > fact.reported_sequence) return true;
        return false;
    }
    pub fn childrenRunning(self: *Root, parent: id.TaskId) bool {
        self.lock();
        defer self.mutex.unlock();
        for (self.facts[0..self.count]) |fact| if (fact.parent != null and fact.parent.?.eql(parent) and !terminal(fact.status)) return true;
        return false;
    }
};

/// Only actual Provider calls occupy slots. FIFO within a root; rotate eligible
/// roots on each admission. Waiting is cancellable without acquiring a slot.
pub const Slots = struct {
    mutex: std.atomic.Mutex = .unlocked,
    next: u64 = 1,
    last_root: id.TaskId = .{},
    queue: [64]?Ticket = @splat(null),
    active: [4]?Ticket = @splat(null),
    pub const Ticket = struct { sequence: u64, root: id.TaskId };
    fn lock(self: *Slots) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    pub fn enqueue(self: *Slots, root: id.TaskId) !Ticket {
        self.lock();
        defer self.mutex.unlock();
        for (&self.queue) |*entry| if (entry.* == null) {
            const ticket: Ticket = .{ .sequence = self.next, .root = root };
            self.next = try id.advance(self.next);
            entry.* = ticket;
            return ticket;
        };
        return error.ModelSlotQueueFull;
    }
    pub fn cancel(self: *Slots, ticket: Ticket) void {
        self.lock();
        defer self.mutex.unlock();
        for (&self.queue) |*entry| if (entry.* != null and entry.*.?.sequence == ticket.sequence) {
            entry.* = null;
            return;
        };
    }
    pub fn tryAcquire(self: *Slots, ticket: Ticket) bool {
        self.lock();
        defer self.mutex.unlock();
        const vacant = for (self.active, 0..) |entry, i| {
            if (entry == null) break i;
        } else return false;
        var selected: ?usize = null;
        var alternative: ?usize = null;
        for (self.queue, 0..) |maybe, i| if (maybe) |entry| {
            var count: usize = 0;
            for (self.active) |running| if (running != null and running.?.root.eql(entry.root)) {
                count += 1;
            };
            if (count >= 2) continue;
            if (selected == null or entry.sequence < self.queue[selected.?].?.sequence) selected = i;
            if (!entry.root.eql(self.last_root) and (alternative == null or entry.sequence < self.queue[alternative.?].?.sequence)) alternative = i;
        };
        const chosen = alternative orelse selected orelse return false;
        if (self.queue[chosen].?.sequence != ticket.sequence) return false;
        self.active[vacant] = ticket;
        self.queue[chosen] = null;
        self.last_root = ticket.root;
        return true;
    }
    pub fn release(self: *Slots, ticket: Ticket) void {
        self.lock();
        defer self.mutex.unlock();
        for (&self.active) |*entry| if (entry.* != null and entry.*.?.sequence == ticket.sequence) {
            entry.* = null;
            return;
        };
    }
};
