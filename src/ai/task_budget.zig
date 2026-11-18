//! Shared, durable task-tree counters. Stable roots outlive every joined Worker.
const std = @import("std");
const id = @import("../host/identity.zig");
const provider = @import("provider.zig");
const Clock = @import("retry.zig").Clock;
pub const Status = enum { running, human_wait, waiting_model, waiting_children, settling, succeeded, failed, cancelled, interrupted, outcome_unknown, queued_dependency };
pub fn terminal(status: Status) bool {
    return switch (status) {
        .succeeded, .failed, .cancelled, .interrupted, .outcome_unknown => true,
        else => false,
    };
}
pub const Counters = struct {
    requests: u64 = 0,
    calls: u64 = 0,
    pending_requests: u64 = 0,
    elapsed_ns: u64 = 0,
    /// Optional explicit task deadline; zero means no cumulative time limit.
    timeout_ns: u64 = 0,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    usage_complete: bool = true,

    // Schema 3 journals written before unbounded tasks retain these two
    // retired quota fields. Accept them only on input; new writes stay canonical.
    const Stored = struct {
        requests: u64 = 0,
        calls: u64 = 0,
        pending_requests: u64 = 0,
        elapsed_ns: u64 = 0,
        timeout_ns: u64 = 0,
        input_tokens: u64 = 0,
        output_tokens: u64 = 0,
        usage_complete: bool = true,
        max_requests: ?u32 = null,
        max_calls: ?u32 = null,
    };
    fn fromStored(value: Stored) Counters {
        var result: Counters = .{};
        inline for (@typeInfo(Counters).@"struct".field_names) |name| @field(result, name) = @field(value, name);
        return result;
    }
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Counters {
        return fromStored(try std.json.innerParse(Stored, allocator, source, options));
    }
    pub fn jsonParseFromValue(allocator: std.mem.Allocator, value: std.json.Value, options: std.json.ParseOptions) !Counters {
        return fromStored(try std.json.innerParseFromValue(Stored, allocator, value, options));
    }
};
/// A child assignment is an upper bound. The controller checks the live
/// host and parent policy again before publishing or dispatching a file call.
pub const LocalFiles = enum(u8) {
    none,
    read,
    write,

    pub fn intersect(self: LocalFiles, other: LocalFiles) LocalFiles {
        return @fromBackingInt(@intCast(@min(@backingInt(self), @backingInt(other))));
    }
};

pub const BoostRound = struct {
    number: u8,
    phase: enum { implementation, challenge, repair },
    previous: ?id.TaskId = null,
};
pub const VerificationItem = struct {
    requirement: []const u8,
    passed: bool,
    detail: []const u8,
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
    /// Host-assigned display sequence within the parent conversation scope.
    /// Unique per owning parent conversation; reuse keeps it, destroy never
    /// recycles it (V0.7 §2.1). Zero only for pre-V0.7 journal replay rows.
    seq: u32 = 0,
    /// Optional mnemonic label. Not unique, never used as a reference alone
    /// unless it uniquely matches one child under the same parent task.
    label: []const u8 = "",
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
    local_files: LocalFiles = .none,
    targets: ?[]const id.SessionHandle = null,
    dependencies: ?[]const id.TaskId = null,
    boost_round: ?BoostRound = null,
    boost_limit: ?u8 = null,
    verification: ?[]const VerificationItem = null,
    pub fn jsonStringify(self: Fact, writer: *std.json.Stringify) !void {
        try writer.beginObject();
        inline for (@typeInfo(Fact).@"struct".field_names) |name| {
            const optional = comptime std.mem.eql(u8, name, "dependencies") or std.mem.eql(u8, name, "boost_round") or std.mem.eql(u8, name, "boost_limit") or std.mem.eql(u8, name, "verification");
            if ((!(comptime std.mem.eql(u8, name, "local_files")) or self.local_files != .none) and (!optional or @field(self, name) != null)) {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
    pub fn validate(self: Fact) !void {
        if (!self.root.valid() or !self.task.valid() or !self.conversation.valid() or !self.agent.valid() or self.generation == 0 or self.sequence == 0 or self.attempt == 0 or self.summary.len > 4096 or self.request_key.len > 128 or !std.unicode.utf8ValidateSlice(self.summary) or !std.unicode.utf8ValidateSlice(self.request_key)) return error.InvalidTaskFact;
        if (self.label.len > 32 or !std.unicode.utf8ValidateSlice(self.label)) return error.InvalidTaskFact;
        if ((self.parent == null and self.local_files != .none) or (self.read_only and self.local_files == .write)) return error.InvalidTaskFact;
        if (self.targets) |targets| {
            if (targets.len > 32) return error.InvalidTaskFact;
            for (targets, 0..) |target, i| {
                if (@backingInt(target.session_id) == 0 or target.generation == 0) return error.InvalidTaskFact;
                for (targets[0..i]) |prior| if (prior.session_id == target.session_id) return error.InvalidTaskFact;
            }
        }
        if (self.parent) |parent| {
            if (!parent.eql(self.root) or self.task.eql(self.root)) return error.InvalidTaskFact;
            // Delegated facts require a host-assigned seq (V0.7 §2.1).
            if (self.seq == 0) return error.InvalidTaskFact;
        } else if (!self.task.eql(self.root)) return error.InvalidTaskFact;
        if (self.dependencies) |ids| {
            if (self.parent == null or ids.len == 0 or ids.len > 16) return error.InvalidTaskFact;
            for (ids) |dependency| if (!dependency.valid() or dependency.eql(self.task)) return error.InvalidTaskFact;
        }
        if (self.boost_round) |round| {
            if (self.parent == null or round.number == 0 or round.number > 8 or (round.phase == .implementation) != (round.previous == null)) return error.InvalidTaskFact;
        }
        if (self.boost_limit) |limit| if (self.parent != null or limit < 1 or limit > 8) return error.InvalidTaskFact;
        if (self.verification) |items| {
            if (self.boost_limit == null) return error.InvalidTaskFact;
            try validateVerification(items);
        }
        if (self.counters.pending_requests > self.counters.requests) return error.InvalidTaskFact;
    }
};
fn validateVerification(items: []const VerificationItem) !void {
    if (items.len == 0 or items.len > 16) return error.InvalidVerification;
    for (items) |item| {
        for ([_][]const u8{ item.requirement, item.detail }) |value| {
            if (value.len > 512 or std.mem.trim(u8, value, " \t\r\n").len == 0 or !std.unicode.utf8ValidateSlice(value)) return error.InvalidVerification;
        }
    }
}
fn copyVerification(a: std.mem.Allocator, items: []const VerificationItem) ![]const VerificationItem {
    const copy = try a.dupe(VerificationItem, items);
    for (copy) |*item| {
        item.requirement = try a.dupe(u8, item.requirement);
        item.detail = try a.dupe(u8, item.detail);
    }
    return copy;
}

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
        copy.label = try arena.allocator().dupe(u8, fact.label);
        if (fact.targets) |targets| copy.targets = try arena.allocator().dupe(id.SessionHandle, targets);
        if (fact.dependencies) |ids| copy.dependencies = try arena.allocator().dupe(id.TaskId, ids);
        if (fact.verification) |items| copy.verification = try copyVerification(arena.allocator(), items);
        return .{ .arena = arena, .fact = copy };
    }
    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
    }
};
pub const Persist = struct { context: *anyopaque, write: *const fn (*anyopaque, Fact) anyerror!void };
/// Durable board-post hook (V0.7 §11.1 写入即落板): each post rides the
/// session journal as a `.board_post` event and is restored on replay. The
/// conversation is the parent record the root's event stream belongs to.
pub const BoardPersist = struct {
    context: *anyopaque,
    write: *const fn (*anyopaque, conversation: id.ConversationId, post: @import("swarm_board.zig").Post) anyerror!void,
};
pub const Root = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    mutex: std.atomic.Mutex = .unlocked,
    facts: []Fact = &.{},
    count: usize = 0,
    // Controller-owned cache. Fact strings and targets are immutable in the
    // root arena and outlive both the worker and the cached facts.
    display_facts: std.ArrayList(Fact) = .empty,
    display_revision: u64 = 0,
    counters: Counters = .{},
    revision: u64 = 0,
    last_ns: i128,
    persist: ?Persist = null,
    board_persist: ?BoardPersist = null,
    failed_storage: bool = false,
    cancelled: bool = false,
    /// Per-parent-task seq allocation watermark (V0.7 §2.1). Destroyed
    /// children never recycle their numbers; reuse keeps the original seq.
    next_seq: u32 = 0,
    /// V0.7 §3.3/G2: host-tracked delivered event watermark for the model
    /// consumer. Advanced atomically when a wait_events response is accepted
    /// into the Loop; an omitted after_sequence pages from here.
    delivered_watermark: u64 = 0,
    /// V0.7 §11/G8: shared board posts appended to this root's event stream.
    /// Board events ride the same {kind, origin, text, ts} envelope and the
    /// same delivery watermark as settle reports; stage-3 UI reads them via
    /// the same cursor.
    board_posts: std.ArrayList(@import("swarm_board.zig").Post) = .empty,
    /// V0.7 §11.2 ask debounce counters keyed by the member's display seq.
    /// Seq is never recycled (§2.1), so it identifies the member for the
    /// root's lifetime without a ≤16 slot cap; the 4th consecutive ask gets
    /// an automatic best-judgment reply and the entry clears when the member
    /// settles.
    board_ask_counts: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// V0.7 §10.2/G4: Auto upgrade decisions on the task event stream. Each
    /// entry records the triggering signal and the hit substance condition;
    /// the panel renders them as an explainable "why this ran in parallel"
    /// timeline (可解释). Bounded ring, host-written only.
    decisions: std.ArrayList(Decision) = .empty,
    /// V0.7 §2.3: max active delegated children per this root (1–16,
    /// clamped). Frozen at root creation from process configuration.
    child_limit: u8 = 4,
    orchestration_mode: ?@import("swarm_mode.zig").Mode = null,
    stall_since_ms: ?i64 = null,
    stall_escalated: bool = false,
    /// V0.7 §12.2: when the host injected the level-1 wake ("请汇总"/"集群
    /// 停滞") into the parent conversation during this stall window. Drives
    /// wake dedupe and the level-2 countdown ("父被唤醒 M 分钟无动作").
    /// Runtime sweep state only; never persisted or replayed.
    stall_wake_ms: ?i64 = null,
    /// V0.7 §12.2 orphan sweep (sweepParentWakes/wakeParentReports): the top
    /// child event_sequence of the last wake batch submitted into the parent
    /// conversation. The same undelivered batch is injected once even when
    /// its follow-up fact acks keep failing (journal write errors would
    /// otherwise re-inject it on every sweep); a changed batch (new events,
    /// or renumbered events after resumeAnswer) wakes again.
    /// Runtime sweep state only; never persisted or replayed.
    wake_submitted_sequence: u64 = 0,
    pub fn init(a: std.mem.Allocator) Root {
        return .{ .allocator = a, .arena = .init(a), .last_ns = (Clock{}).now() };
    }
    pub fn deinit(self: *Root) void {
        self.display_facts.deinit(self.allocator);
        for (self.board_posts.items) |post| self.allocator.free(post.text);
        self.board_posts.deinit(self.allocator);
        self.board_ask_counts.deinit(self.allocator);
        for (self.decisions.items) |decision| self.allocator.free(decision.reason);
        self.decisions.deinit(self.allocator);
        self.arena.deinit();
    }
    /// V0.7 §10.2: record an Auto-upgrade decision (bounded to 16, oldest
    /// dropped) so the panel can explain why a request ran in parallel.
    pub fn recordDecision(self: *Root, at_ms: i64, reason: []const u8) !void {
        self.lock();
        defer self.mutex.unlock();
        const owned = try self.allocator.dupe(u8, reason);
        errdefer self.allocator.free(owned);
        if (self.decisions.items.len == 16) {
            const dropped = self.decisions.orderedRemove(0);
            self.allocator.free(dropped.reason);
        }
        try self.decisions.append(self.allocator, .{ .at_ms = at_ms, .reason = owned });
    }
    /// Panel projection: copied decisions (caller frees reasons slice only).
    pub fn decisionsSnapshot(self: *Root, a: std.mem.Allocator) ![]Decision {
        self.lock();
        defer self.mutex.unlock();
        const copy = try a.alloc(Decision, self.decisions.items.len);
        for (self.decisions.items, 0..) |decision, i| copy[i] = .{ .at_ms = decision.at_ms, .reason = decision.reason };
        return copy;
    }
    /// V0.7 §11: append a board post to this root's event stream. The post
    /// text is owned by the root after this call. Delivery follows the §11.2
    /// rules: parent/member-targeted posts surface in the next model round;
    /// @all posts stay board-only.
    pub fn postBoard(self: *Root, post: @import("swarm_board.zig").Post) !void {
        self.lock();
        defer self.mutex.unlock();
        var owned = post;
        owned.text = try self.allocator.dupe(u8, post.text);
        errdefer self.allocator.free(owned.text);
        // 写入即落板：the journal write precedes the in-memory append so an
        // acknowledged post is durable. A failed write fails the request like
        // a fact write and halts further storage (same contract as write()).
        if (self.board_persist) |hook| {
            const root_fact = for (self.facts[0..self.count]) |fact| {
                if (fact.parent == null) break fact;
            } else return error.InvalidTaskFact;
            hook.write(hook.context, root_fact.conversation, owned) catch |err| {
                self.failed_storage = true;
                return err;
            };
        }
        try self.board_posts.append(self.allocator, owned);
    }
    /// Mark one stored post as already delivered directly to the parent inbox.
    /// Returns false when the post is absent (for example after a prior delivery).
    pub fn markPostDelivered(self: *Root, post_id: [16]u8) bool {
        self.lock();
        defer self.mutex.unlock();
        for (self.board_posts.items) |*post| {
            if (std.mem.eql(u8, &post.post_id, &post_id)) {
                post.delivered = true;
                return true;
            }
        }
        return false;
    }
    /// Board posts not yet consumed into the model transcript, ordered by
    /// arrival. The caller copies what it needs; entries stay retained.
    pub fn undeliveredBoardPosts(self: *Root) []const @import("swarm_board.zig").Post {
        self.lock();
        defer self.mutex.unlock();
        return self.board_posts.items;
    }
    pub fn displayFacts(self: *Root) []const Fact {
        if (!self.mutex.tryLock()) return self.display_facts.items;
        defer self.mutex.unlock();
        if (self.display_revision != self.revision) {
            self.display_facts.ensureTotalCapacity(self.allocator, self.count) catch return self.display_facts.items;
            self.display_facts.clearRetainingCapacity();
            self.display_facts.appendSliceAssumeCapacity(self.facts[0..self.count]);
            self.display_revision = self.revision;
        }
        return self.display_facts.items;
    }
    pub fn lock(self: *Root) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    fn ensureFactCapacity(self: *Root) !void {
        if (self.count == self.facts.len) self.facts = try self.arena.allocator().realloc(self.facts, @max(16, self.facts.len * 2));
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
        if (self.counters.timeout_ns != 0 and self.counters.elapsed_ns >= self.counters.timeout_ns) return error.SharedTaskTimeout;
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
    /// Allocate the next per-parent display seq under the root lock. Called
    /// only for delegated facts; roots keep seq 0. The seq identifies the
    /// member (V0.7 §2.1/G1): a rollover's new task keeps the member's
    /// number, so a duplicate number is an error only for a different agent.
    fn allocateSeqLocked(self: *Root, parent: id.TaskId, agent: id.AgentId, requested: u32) !u32 {
        if (requested != 0) {
            for (self.facts[0..self.count]) |prior| if (prior.parent != null and prior.parent.?.eql(parent) and prior.seq == requested and !prior.agent.eql(agent)) return error.InvalidTaskFact;
            if (requested > self.next_seq) self.next_seq = requested;
            return requested;
        }
        if (self.next_seq == std.math.maxInt(u32)) return error.InvalidTaskFact;
        self.next_seq += 1;
        return self.next_seq;
    }
    /// Resolve a #seq reference to the single delegated fact under the parent
    /// task's scope. Caller holds no lock; this takes it.
    pub fn factForSeq(self: *Root, parent: id.TaskId, seq: u32) !Fact {
        self.lock();
        defer self.mutex.unlock();
        var index_value = self.count;
        while (index_value != 0) {
            index_value -= 1;
            const fact = self.facts[index_value];
            if (fact.parent != null and fact.parent.?.eql(parent) and fact.seq == seq) return fact;
        }
        return error.TaskNotFound;
    }
    /// Resolve a bare label reference: exactly one live-or-terminal delegated
    /// fact with this label may exist under the parent task. Multiple matches
    /// return an error carrying the candidate display names for the model.
    pub fn factsForLabel(self: *Root, parent: id.TaskId, label: []const u8) !LabelResolution {
        self.lock();
        defer self.mutex.unlock();
        var found: [16]Fact = undefined;
        var count: usize = 0;
        for (self.facts[0..self.count]) |fact| if (fact.parent != null and fact.parent.?.eql(parent) and std.mem.eql(u8, fact.label, label)) {
            if (count == found.len) return error.LabelAmbiguous;
            found[count] = fact;
            count += 1;
        };
        if (count == 0) return error.TaskNotFound;
        if (count > 1) return error.LabelAmbiguous;
        return .{ .fact = found[0], .candidates = &.{} };
    }
    pub const LabelResolution = struct { fact: Fact, candidates: []const Fact };
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
        try self.ensureFactCapacity();
        if (original.parent != null) {
            var active: usize = 0;
            for (self.facts[0..self.count]) |fact| if (fact.parent != null and !terminal(fact.status)) {
                active += 1;
            };
            if (active >= self.child_limit) return error.ChildTaskLimit;
        }
        var fact = original;
        fact.request_key = try self.arena.allocator().dupe(u8, fact.request_key);
        fact.label = try self.arena.allocator().dupe(u8, fact.label);
        if (fact.targets) |targets| fact.targets = try self.arena.allocator().dupe(id.SessionHandle, targets);
        fact.summary = try self.arena.allocator().dupe(u8, fact.summary);
        // V0.7 §2.1: add() always publishes a fresh delegated fact, so it
        // receives the next seq; only rollover keeps the member's number.
        if (fact.parent != null) {
            fact.seq = 0;
            fact.seq = try self.allocateSeqLocked(fact.parent.?, fact.agent, 0);
        }
        self.facts[self.count] = try self.write(fact);
        self.count += 1;
    }
    /// Hold the root revision stable while the controller commits the atomic
    /// child record+first-input row. Sibling Workers cannot race its sequence.
    pub fn launch(self: *Root, original: Fact, context: *anyopaque, commit: *const fn (*anyopaque, *Fact) anyerror!void) !Fact {
        self.lock();
        defer self.mutex.unlock();
        try self.checkLocked();
        try self.ensureFactCapacity();
        var active: usize = 0;
        for (self.facts[0..self.count]) |fact| if (fact.parent != null and !terminal(fact.status)) {
            active += 1;
        };
        if (active >= self.child_limit) return error.ChildTaskLimit;
        var fact = original;
        if (fact.dependencies) |ids| fact.dependencies = try self.arena.allocator().dupe(id.TaskId, ids);
        fact.request_key = try self.arena.allocator().dupe(u8, original.request_key);
        fact.label = try self.arena.allocator().dupe(u8, original.label);
        if (original.targets) |targets| fact.targets = try self.arena.allocator().dupe(id.SessionHandle, targets);
        fact.created_at_ms = @import("../platform/realtime.zig").milliseconds(undefined);
        fact.changed_at_ms = fact.created_at_ms;
        fact.sequence = if (self.revision == 0) 1 else try id.advance(self.revision);
        fact.counters = self.counters;
        fact.event_sequence = fact.sequence;
        if (fact.parent != null) fact.seq = try self.allocateSeqLocked(fact.parent.?, fact.agent, fact.seq);
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
        try self.ensureFactCapacity();
        const index_ = try self.index(previous);
        const prior = self.facts[index_];
        if (prior.parent == null or !std.meta.eql(prior.parent, original.parent) or !prior.agent.eql(original.agent) or !prior.conversation.eql(original.conversation) or !prior.root.eql(original.root) or !terminal(outcome) or original.task.eql(previous)) return error.InvalidTaskFact;
        if (original.local_files.intersect(prior.local_files) != original.local_files or
            (prior.read_only and !original.read_only) or
            (outcome == .outcome_unknown and original.local_files == .write))
            return error.InvalidTaskFact;
        var next = original;
        next.request_key = try self.arena.allocator().dupe(u8, original.request_key);
        next.label = try self.arena.allocator().dupe(u8, original.label);
        next.summary = try self.arena.allocator().dupe(u8, original.summary);
        if (next.targets) |targets| next.targets = try self.arena.allocator().dupe(id.SessionHandle, targets);
        next.created_at_ms = @import("../platform/realtime.zig").milliseconds(undefined);
        next.changed_at_ms = next.created_at_ms;
        // Rollover keeps the member's original display seq (V0.7 §2.1).
        next.seq = prior.seq;
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
        return if (self.counters.timeout_ns == 0) std.math.maxInt(u64) else self.counters.timeout_ns -| self.counters.elapsed_ns;
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
    pub fn configure(self: *Root, task: id.TaskId, timeout_ms: u32) !void {
        self.lock();
        defer self.mutex.unlock();
        const i = try self.index(task);
        if (self.facts[i].parent == null and self.counters.requests == 0 and self.counters.calls == 0) {
            self.counters.timeout_ns = @as(u64, timeout_ms) * std.time.ns_per_ms;
        }
    }
    pub const Outstanding = struct { seq: u32, label: []const u8, status: Status };
    /// V0.7 §3.3 (approved 2026-11-15): resuming an answer no longer hard-fails
    /// on unsettled children. The caller must disclose the returned outstanding
    /// list (#seq label) in its final reply; delivered reports stay delivered.
    pub fn outstandingChildren(self: *Root, a: std.mem.Allocator, parent: id.TaskId) ![]Outstanding {
        self.lock();
        defer self.mutex.unlock();
        var list: std.ArrayList(Outstanding) = .empty;
        errdefer list.deinit(a);
        for (self.facts[0..self.count]) |fact| if (fact.parent != null and fact.parent.?.eql(parent) and !terminal(fact.status)) {
            try list.append(a, .{ .seq = fact.seq, .label = fact.label, .status = fact.status });
        };
        return list.toOwnedSlice(a);
    }
    pub fn resumeAnswer(self: *Root, task: id.TaskId) !void {
        self.lock();
        defer self.mutex.unlock();
        self.settleClock();
        if (self.failed_storage) return error.TaskPersistenceFailed;
        const i = try self.index(task);
        if (self.facts[i].status == .cancelled or self.facts[i].status == .interrupted) return error.TaskAlreadyFinished;
        var fact = self.facts[i];
        fact.status = .running;
        fact.event_sequence = 0;
        fact.attempt = try std.math.add(u32, fact.attempt, 1);
        self.facts[i] = try self.write(fact);
        self.cancelled = false;
        self.counters.timeout_ns = 0;
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
    /// V0.7 §3.3/G2: advance the model-consumer watermark after a wait_events
    /// result entered the Loop. Delivery and interface reading levels are
    /// tracked separately; this one belongs to the model only.
    pub fn advanceDeliveredWatermark(self: *Root, sequence: u64) void {
        self.lock();
        defer self.mutex.unlock();
        self.advanceDeliveredWatermarkLocked(sequence);
    }
    /// Caller must already hold the root mutex.
    pub fn advanceDeliveredWatermarkLocked(self: *Root, sequence: u64) void {
        if (sequence > self.delivered_watermark) self.delivered_watermark = sequence;
    }
    pub fn take(self: *Root, task: id.TaskId, requests: u32, calls: u32) !void {
        self.lock();
        defer self.mutex.unlock();
        try self.checkLocked();
        const i = try self.index(task);
        if (terminal(self.facts[i].status)) return error.TaskAlreadyFinished;
        const prior = self.counters;
        self.counters.requests +|= requests;
        self.counters.pending_requests +|= requests;
        self.counters.calls +|= calls;
        self.facts[i] = self.write(self.facts[i]) catch |err| {
            self.counters = prior;
            return err;
        };
    }
    pub fn configureBoost(self: *Root, task: id.TaskId, limit: u8) !void {
        self.lock();
        defer self.mutex.unlock();
        const i = try self.index(task);
        var fact = self.facts[i];
        if (fact.boost_limit != null) return;
        fact.boost_limit = limit;
        self.facts[i] = try self.write(fact);
    }

    pub fn factForTask(self: *Root, task: id.TaskId) !Fact {
        self.lock();
        defer self.mutex.unlock();
        return self.facts[try self.index(task)];
    }

    pub fn verifyBoost(self: *Root, task: id.TaskId, items: []const VerificationItem) !void {
        try validateVerification(items);
        self.lock();
        defer self.mutex.unlock();
        const i = try self.index(task);
        var fact = self.facts[i];
        if (fact.boost_limit == null or terminal(fact.status)) return error.InvalidVerification;
        if (fact.verification) |prior| {
            if (@import("../config/settings_schema.zig").same(prior, items)) return;
            return error.BoostAlreadyVerified;
        }
        for (self.facts[0..self.count]) |child| {
            if (child.parent != null and child.parent.?.eql(task) and !terminal(child.status)) return error.BoostChildrenPending;
        }
        fact.verification = try copyVerification(self.arena.allocator(), items);
        self.facts[i] = try self.write(fact);
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
        // V0.7 §11.2: a settled member's ask debounce counter clears.
        if (fact.parent != null and fact.seq != 0) _ = self.board_ask_counts.remove(fact.seq);
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
    /// Historical changes are visible only for tasks delegated by this
    /// exact parent task. Reusing an Agent under a different task does not
    /// make the old root's file operations visible.
    pub fn childFileTasks(self: *Root, a: std.mem.Allocator, authority: @import("host_tools.zig").Context) ![]@import("lifecycle_journal.zig").LocalFileScope {
        try authority.validate();
        if (authority.child_origin != null) return error.ChildCannotDelegate;
        self.lock();
        defer self.mutex.unlock();
        const parent = self.facts[try self.index(authority.task_id)];
        if (parent.parent != null or !parent.conversation.eql(authority.conversation_id)) return error.ScopeChanged;

        const Scope = @import("lifecycle_journal.zig").LocalFileScope;
        var scopes: std.ArrayList(Scope) = .empty;
        errdefer scopes.deinit(a);
        for (self.facts[0..self.count]) |fact| {
            const owner = fact.parent orelse continue;
            if (!owner.eql(parent.task) or fact.local_files == .none) continue;
            try scopes.append(a, .{ .conversation_id = fact.conversation, .task_id = fact.task });
        }
        return scopes.toOwnedSlice(a);
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

/// V0.7 §10.2: an explainable Auto-upgrade decision (panel-readable).
pub const Decision = struct { at_ms: i64, reason: []const u8 };

/// Only actual Provider calls occupy slots. FIFO within a root; rotate eligible
/// roots on each admission. Waiting is cancellable without acquiring a slot.
/// V0.7 §2.3: capacities are process-frozen from configuration (model_slots,
/// child_request_concurrency); queue depth keeps the V0.4 fixed bound.
pub const Slots = struct {
    mutex: std.atomic.Mutex = .unlocked,
    next: u64 = 1,
    last_root: id.TaskId = .{},
    queue: [64]?Ticket = @splat(null),
    active: [8]?Ticket = @splat(null),
    /// Number of active slots actually used (2–8, frozen at process start).
    active_slots: usize = 4,
    /// Concurrent provider requests per root (1–8, frozen at process start).
    per_root: usize = 2,
    pub const Ticket = struct { sequence: u64, root: id.TaskId };
    pub fn configure(self: *Slots, model_slots: u8, request_concurrency: u8) void {
        self.active_slots = @min(8, @max(2, @as(usize, model_slots)));
        self.per_root = @min(8, @max(1, @as(usize, request_concurrency)));
        self.lock();
        defer self.mutex.unlock();
        for (self.active[self.active_slots..]) |*entry| entry.* = null;
    }
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
        const vacant = for (self.active[0..self.active_slots], 0..) |entry, i| {
            if (entry == null) break i;
        } else return false;
        var selected: ?usize = null;
        var alternative: ?usize = null;
        for (self.queue, 0..) |maybe, i| if (maybe) |entry| {
            var count: usize = 0;
            for (self.active[0..self.active_slots]) |running| if (running != null and running.?.root.eql(entry.root)) {
                count += 1;
            };
            if (count >= self.per_root) continue;
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
