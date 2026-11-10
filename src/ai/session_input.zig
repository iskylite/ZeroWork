//! Owned follow-up inbox. Binding fences, delivery facts and scheduling gates
//! are independent. The controller and worker share only this short mutex.
const std = @import("std");
const identity = @import("../host/identity.zig");
const provider = @import("provider.zig");
const wire = @import("wire_history.zig");
pub const Mode = @import("../config/config.zig").FollowUpMode;
pub const Delivery = enum { queued, submitting, accepted, consumed, failed, cancelled, outcome_unknown };
pub const Route = enum { start, queue, steer };
pub const WorkPhase = enum {
    starting,
    continuing,
    response,
    tools,

    pub fn waitingHint(self: WorkPhase) []const u8 {
        return switch (self) {
            .starting => "当前任务启动后处理",
            .continuing => "下一次请求时处理",
            .response => "当前响应结束后处理",
            .tools => "当前工具返回后处理",
        };
    }
};
pub const Pause = enum { stop, end, environment, failure, budget, unknown };
pub const Fence = struct {
    agent: identity.AgentId,
    conversation: identity.ConversationId,
    binding: u64,
    environment: u64,
    pub fn eql(a: Fence, b: Fence) bool {
        return a.agent.eql(b.agent) and a.conversation.eql(b.conversation) and a.binding == b.binding and a.environment == b.environment;
    }
};
pub const Receipt = struct {
    id: identity.SubmissionId,
    fence: Fence,
    sequence: u64,
    revision: u64 = 1,
    attempt: u64 = 0,
    mode: Mode,
    route: Route,
    expected_turn: ?u64 = null,
    turn: ?u64 = null,
    delivery: Delivery = .queued,
    pause: ?Pause = null,
    request_sequence: ?u64 = null,
    archived: bool = false,
    original: ?identity.SubmissionId = null,
};
pub const Entry = struct {
    receipt: Receipt,
    payload: wire.History,
    text_bytes: usize,
    pub fn deinit(self: *Entry, a: std.mem.Allocator) void {
        self.payload.deinit();
        a.destroy(self);
    }
};
pub const Persist = struct {
    context: *anyopaque,
    /// Must durably commit before returning if durable admission is promised.
    /// Borrowed payload; no UI, network or inbox reentry from this callback.
    write: *const fn (*anyopaque, Receipt, []const provider.Message) anyerror!void,
    consumed: ?*const fn (*anyopaque, Receipt, []const provider.Message, []const provider.Message) anyerror!void = null,
    order: ?*const fn (*anyopaque, Fence, []const identity.SubmissionId) anyerror!void = null,
};
pub const Budget = struct {
    mutex: std.atomic.Mutex = .unlocked,
    count: usize = 0,
    text_bytes: usize = 0,
    fn reserve(self: *Budget, count: usize, bytes: usize) !void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        self.count += count;
        self.text_bytes += bytes;
    }
    fn release(self: *Budget, count: usize, bytes: usize) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        self.count -= count;
        self.text_bytes -= bytes;
    }
};
pub const Inbox = struct {
    allocator: std.mem.Allocator,
    mutex: std.atomic.Mutex = .unlocked,
    fence: Fence,
    admission: bool = true,
    active_turn: ?u64 = null,
    closing: bool = false,
    work_phase: WorkPhase = .continuing,
    revision: u64 = 1,
    queue_revision: u64 = 1,
    next_sequence: u64 = 1,
    entries: std.ArrayList(*Entry) = .empty,
    persist: ?Persist = null,
    /// Application controller owns this budget. It serializes admissions and
    /// removals; workers only change delivery under their inbox lock.
    budget: ?*Budget = null,

    pub fn init(a: std.mem.Allocator, fence: Fence) Inbox {
        return .{ .allocator = a, .fence = fence };
    }
    pub fn lock(self: *Inbox) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    pub fn unlock(self: *Inbox) void {
        self.mutex.unlock();
    }
    fn save(self: *Inbox, value: Receipt, messages: []const provider.Message) !void {
        if (self.persist) |p| try p.write(p.context, value, messages);
    }
    pub fn findLocked(self: *Inbox, id: identity.SubmissionId) ?*Entry {
        for (self.entries.items) |entry| if (entry.receipt.id.eql(id)) return entry;
        return null;
    }
    pub fn receipt(self: *Inbox, id: identity.SubmissionId) ?Receipt {
        self.lock();
        defer self.unlock();
        return if (self.findLocked(id)) |entry| entry.receipt else null;
    }
    pub fn admit(self: *Inbox, fence: Fence, id: identity.SubmissionId, message: provider.Message, mode: Mode) !Receipt {
        return self.admitWithOrigin(fence, id, message, mode, null);
    }
    /// Preview and admission share this decision under the same inbox mutex.
    /// The controller separately checks whether an idle runtime can start.
    pub fn previewRoute(self: *Inbox, mode: Mode) Route {
        self.lock();
        defer self.unlock();
        return self.routeLocked(mode);
    }
    fn routeLocked(self: *Inbox, mode: Mode) Route {
        if (!self.admission) return .queue;
        if (self.active_turn != null) return if (mode == .steer and !self.closing and self.work_phase != .starting) .steer else .queue;
        for (self.entries.items) |entry| {
            if (entry.receipt.archived) continue;
            if (entry.receipt.delivery == .outcome_unknown or (entry.receipt.delivery == .queued and entry.receipt.pause == null and entry.receipt.fence.eql(self.fence))) return .queue;
        }
        return .start;
    }
    pub fn setWorkPhase(self: *Inbox, turn: u64, phase: WorkPhase) void {
        self.lock();
        defer self.unlock();
        if (self.active_turn == turn and !self.closing) self.work_phase = phase;
    }
    pub fn reissue(self: *Inbox, fence: Fence, original: identity.SubmissionId, revision: u64, id: identity.SubmissionId, message: provider.Message, mode: Mode) !Receipt {
        self.lock();
        const old = self.findLocked(original) orelse {
            self.unlock();
            return error.SubmissionNotFound;
        };
        const receipt_value = old.receipt;
        const active = self.active_turn;
        self.unlock();
        if (id.eql(original) or receipt_value.revision != revision) return error.SubmissionConflict;
        if (receipt_value.delivery == .outcome_unknown or receipt_value.delivery == .submitting) return error.SubmissionUnconfirmed;
        if ((terminal(receipt_value.delivery) and receipt_value.delivery != .failed) or (receipt_value.delivery == .accepted and active != null) or (receipt_value.delivery == .queued and receipt_value.fence.eql(fence) and !receipt_value.archived)) return error.SubmissionNotReady;
        // New payload has already been rebuilt for the current environment by
        // the sender; old resource references are never silently transplanted.
        return self.admitWithOrigin(fence, id, message, mode, original);
    }
    fn admitWithOrigin(self: *Inbox, fence: Fence, id: identity.SubmissionId, message: provider.Message, mode: Mode, original: ?identity.SubmissionId) !Receipt {
        if (!id.valid()) return error.InvalidSubmission;
        try validateMessage(message);
        var payload = try wire.History.copy(self.allocator, &.{message}, "");
        errdefer payload.deinit();
        self.lock();
        defer self.unlock();
        if (!self.fence.eql(fence)) return error.BindingChanged;
        if (!self.admission) return error.ConversationEnding;
        if (self.findLocked(id)) |prior| {
            if (!prior.receipt.fence.eql(fence)) return error.BindingChanged;
            if (!std.meta.eql(prior.receipt.original, original)) return error.SubmissionConflict;
            const prior_message = prior.payload.messages[0];
            if (prior.receipt.mode != mode or !std.mem.eql(u8, prior_message.content, message.content) or prior_message.images.len != message.images.len or prior_message.offloaded_images.len != message.offloaded_images.len or !std.meta.eql(prior_message.image_owner, message.image_owner) or prior_message.image_transform != message.image_transform) return error.SubmissionConflict;
            for (prior_message.images, message.images) |left, right| if (!sameImage(left, right)) return error.SubmissionConflict;
            for (prior_message.offloaded_images, message.offloaded_images) |left, right| if (!sameImage(left.reference, right.reference) or !std.meta.eql(left.owner, right.owner)) return error.SubmissionConflict;
            payload.deinit();
            return prior.receipt;
        }
        if (self.budget) |b| try b.reserve(1, message.content.len);
        errdefer if (self.budget) |b| b.release(1, message.content.len);
        const next_sequence = try identity.advance(self.next_sequence);
        const queue_rev = try identity.advance(self.queue_revision);
        const is_steer = self.routeLocked(mode) == .steer;
        const input_rev = if (is_steer) try identity.advance(self.revision) else self.revision;
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);
        const value: Receipt = .{ .id = id, .fence = fence, .sequence = self.next_sequence, .mode = mode, .route = if (is_steer) .steer else .queue, .expected_turn = if (is_steer) self.active_turn else null, .turn = if (is_steer) self.active_turn else null, .delivery = if (is_steer) .accepted else .queued, .original = original };
        try self.save(value, payload.messages);
        entry.* = .{ .receipt = value, .payload = payload, .text_bytes = message.content.len };
        self.entries.appendAssumeCapacity(entry);
        self.next_sequence = next_sequence;
        self.queue_revision = queue_rev;
        self.revision = input_rev;
        return value;
    }
    pub fn claim(self: *Inbox, id: identity.SubmissionId, revision: u64, expected_queue: ?u64, turn: u64, target_route: Route) !Receipt {
        self.lock();
        defer self.unlock();
        if (!self.admission) return error.ConversationEnding;
        if (expected_queue) |expected| if (expected != self.queue_revision) return error.QueueChanged;
        const entry = self.findLocked(id) orelse return error.SubmissionNotFound;
        if (!entry.receipt.fence.eql(self.fence) or entry.receipt.revision != revision) return error.BindingChanged;
        if (entry.receipt.delivery != .queued or entry.receipt.pause != null) return error.SubmissionNotReady;
        for (self.entries.items) |other| if (other.receipt.delivery == .outcome_unknown and !other.receipt.archived) return error.SubmissionUnconfirmed;
        if (target_route == .steer) {
            if (self.active_turn != turn or self.closing) return error.TurnChanged;
        } else if (target_route == .start) {
            if (self.active_turn != null) return error.AgentBusy;
        } else return error.InvalidSubmission;
        var value = entry.receipt;
        value.attempt = std.math.add(u64, value.attempt, 1) catch return error.RevisionExhausted;
        value.revision = try identity.advance(value.revision);
        value.route = target_route;
        value.turn = turn;
        value.expected_turn = if (target_route == .steer) turn else null;
        value.delivery = .accepted;
        const next_queue = try identity.advance(self.queue_revision);
        const next_input = try identity.advance(self.revision);
        try self.save(value, entry.payload.messages);
        entry.receipt = value;
        self.queue_revision = next_queue;
        self.revision = next_input;
        if (target_route == .start) {
            self.active_turn = turn;
            self.closing = false;
        }
        return value;
    }
    pub fn next(self: *Inbox) ?Receipt {
        self.lock();
        defer self.unlock();
        if (!self.admission or self.active_turn != null) return null;
        for (self.entries.items) |entry| if (entry.receipt.delivery == .outcome_unknown and !entry.receipt.archived) return null;
        for (self.entries.items) |entry| if (entry.receipt.delivery == .queued and entry.receipt.pause == null and entry.receipt.fence.eql(self.fence)) return entry.receipt;
        return null;
    }
    pub fn edit(self: *Inbox, id: identity.SubmissionId, revision: u64, message: provider.Message) !Receipt {
        try validateMessage(message);
        var payload = try wire.History.copy(self.allocator, &.{message}, "");
        errdefer payload.deinit();
        self.lock();
        defer self.unlock();
        const entry = self.findLocked(id) orelse return error.SubmissionNotFound;
        if (!self.admission or !entry.receipt.fence.eql(self.fence)) return error.BindingChanged;
        if (entry.receipt.revision != revision or entry.receipt.delivery != .queued) return error.SubmissionNotReady;
        const extra = message.content.len -| entry.text_bytes;
        if (self.budget) |b| try b.reserve(0, extra);
        errdefer if (self.budget) |b| b.release(0, extra);
        var value = entry.receipt;
        value.revision = try identity.advance(revision);
        const next_queue = try identity.advance(self.queue_revision);
        try self.save(value, payload.messages);
        if (self.budget) |b| b.release(0, entry.text_bytes -| message.content.len);
        entry.payload.deinit();
        entry.payload = payload;
        entry.text_bytes = message.content.len;
        entry.receipt = value;
        self.queue_revision = next_queue;
        return value;
    }
    pub fn reorder(self: *Inbox, expected: u64, order: []const identity.SubmissionId) !void {
        self.lock();
        defer self.unlock();
        if (!self.admission or expected != self.queue_revision) return error.QueueChanged;
        const slots = try self.allocator.alloc(usize, self.entries.items.len);
        defer self.allocator.free(slots);
        var count: usize = 0;
        for (self.entries.items, 0..) |entry, i| if (entry.receipt.delivery == .queued and entry.receipt.pause == null and entry.receipt.fence.eql(self.fence)) {
            slots[count] = i;
            count += 1;
        };
        if (count != order.len) return error.InvalidQueueOrder;
        const ordered = try self.allocator.alloc(*Entry, order.len);
        defer self.allocator.free(ordered);
        for (order, 0..) |id, i| {
            for (order[0..i]) |prior| if (id.eql(prior)) return error.InvalidQueueOrder;
            const entry = self.findLocked(id) orelse return error.InvalidQueueOrder;
            if (entry.receipt.delivery != .queued or entry.receipt.pause != null or !entry.receipt.fence.eql(self.fence)) return error.SubmissionNotReady;
            ordered[i] = entry;
        }
        const next_queue = try identity.advance(self.queue_revision);
        if (self.persist) |p| {
            const commit = p.order orelse return error.DurableQueueOrderUnavailable;
            const full = try self.allocator.alloc(identity.SubmissionId, self.entries.items.len);
            defer self.allocator.free(full);
            for (self.entries.items, 0..) |entry, i| full[i] = entry.receipt.id;
            for (slots[0..count], order) |i, id| full[i] = id;
            try commit(p.context, self.fence, full[0..self.entries.items.len]);
        }
        for (slots[0..count], ordered[0..count]) |i, entry| self.entries.items[i] = entry;
        self.queue_revision = next_queue;
    }
    /// Only delivery acknowledgements for this exact attempt can change facts.
    pub fn reconcile(self: *Inbox, id: identity.SubmissionId, attempt: u64, delivery: Delivery) !void {
        self.lock();
        defer self.unlock();
        const entry = self.findLocked(id) orelse return error.SubmissionNotFound;
        if (entry.receipt.attempt != attempt or terminal(entry.receipt.delivery)) return error.StaleSubmissionAttempt;
        if (delivery != .outcome_unknown and delivery != .accepted and delivery != .failed and delivery != .cancelled) return error.InvalidSubmissionTransition;
        if (delivery == .failed and entry.receipt.delivery == .accepted) return error.InvalidSubmissionTransition;
        var value = entry.receipt;
        value.delivery = delivery;
        if (delivery == .outcome_unknown) value.pause = .unknown;
        try self.save(value, entry.payload.messages);
        entry.receipt = value;
        if (terminal(delivery) and !entry.receipt.archived) self.releaseBudget(entry);
    }
    pub fn cancelQueued(self: *Inbox, id: identity.SubmissionId, revision: u64) !void {
        self.lock();
        defer self.unlock();
        const entry = self.findLocked(id) orelse return error.SubmissionNotFound;
        if (entry.receipt.revision != revision or entry.receipt.delivery != .queued) return error.SubmissionNotReady;
        var value = entry.receipt;
        value.delivery = .cancelled;
        const next_queue = try identity.advance(self.queue_revision);
        try self.save(value, entry.payload.messages);
        entry.receipt = value;
        self.releaseBudget(entry);
        self.queue_revision = next_queue;
    }
    pub fn pauseAll(self: *Inbox, reason: Pause) void {
        self.lock();
        defer self.unlock();
        for (self.entries.items) |entry| if (!terminal(entry.receipt.delivery)) {
            entry.receipt.pause = reason;
        };
        if (self.active_turn != null) self.closing = true;
        if (reason == .end) self.admission = false;
    }
    pub fn continueQueue(self: *Inbox, fence: Fence) !void {
        self.lock();
        defer self.unlock();
        if (!self.admission or !self.fence.eql(fence) or self.active_turn != null) return error.BindingChanged;
        for (self.entries.items) |entry| if (entry.receipt.delivery == .outcome_unknown and !entry.receipt.archived) return error.SubmissionUnconfirmed;
        for (self.entries.items) |entry| if (entry.receipt.delivery == .queued and entry.receipt.fence.eql(fence)) {
            entry.receipt.pause = null;
        };
    }
    pub fn changeFence(self: *Inbox, fence: Fence) void {
        self.lock();
        defer self.unlock();
        for (self.entries.items) |entry| if (!terminal(entry.receipt.delivery)) {
            entry.receipt.pause = .environment;
        };
        self.fence = fence;
        self.revision = std.math.add(u64, self.revision, 1) catch {
            self.admission = false;
            return;
        };
        self.admission = true;
    }
    pub fn hasPending(self: *Inbox) bool {
        self.lock();
        defer self.unlock();
        return self.pendingLocked();
    }
    pub fn pendingLocked(self: *Inbox) bool {
        for (self.entries.items) |entry| if (entry.receipt.delivery == .accepted and entry.receipt.pause == null and entry.receipt.turn == self.active_turn and entry.receipt.fence.eql(self.fence)) return true;
        return false;
    }
    pub fn inputRevision(self: *Inbox) u64 {
        self.lock();
        defer self.unlock();
        return self.revision;
    }
    pub fn planCurrent(self: *Inbox, revision: u64) bool {
        self.lock();
        defer self.unlock();
        return self.admission and !self.closing and revision == self.revision;
    }
    /// Linearization point with admission: an accepted steer wins before close.
    pub fn tryClose(self: *Inbox) bool {
        self.lock();
        defer self.unlock();
        if (self.pendingLocked()) return false;
        self.closing = true;
        return true;
    }
    pub fn finish(self: *Inbox, turn: u64, reason: ?Pause) void {
        self.lock();
        defer self.unlock();
        if (self.active_turn != turn) return;
        if (reason) |why| for (self.entries.items) |entry| if (!terminal(entry.receipt.delivery)) {
            entry.receipt.pause = why;
        };
        self.active_turn = null;
        self.closing = false;
    }
    pub fn consumedLocked(self: *Inbox, entry: *Entry, request_sequence: u64, transcript: []const provider.Message) !void {
        if (entry.receipt.delivery != .accepted or entry.receipt.pause != null or !self.admission or !entry.receipt.fence.eql(self.fence) or entry.receipt.turn != self.active_turn) return error.BindingChanged;
        var value = entry.receipt;
        value.delivery = .consumed;
        value.request_sequence = request_sequence;
        if (self.persist) |p| {
            if (p.consumed) |commit| try commit(p.context, value, entry.payload.messages, transcript) else try p.write(p.context, value, entry.payload.messages);
        }
        entry.receipt = value;
        self.releaseBudget(entry);
    }
    fn releaseBudget(self: *Inbox, entry: *Entry) void {
        if (self.budget) |b| b.release(1, entry.text_bytes);
    }
    /// Called after durable unbind: archive scheduling rights, never rewrite
    /// an unknown delivery fact into "not consumed".
    pub fn archive(self: *Inbox) void {
        self.lock();
        defer self.unlock();
        for (self.entries.items) |entry| if (!entry.receipt.archived) {
            if (!terminal(entry.receipt.delivery)) self.releaseBudget(entry);
            entry.receipt.archived = true;
        };
    }
    pub fn deinit(self: *Inbox) void {
        for (self.entries.items) |entry| {
            if (!terminal(entry.receipt.delivery) and !entry.receipt.archived) self.releaseBudget(entry);
            entry.deinit(self.allocator);
        }
        self.entries.deinit(self.allocator);
    }
};
pub fn terminal(value: Delivery) bool {
    return value == .consumed or value == .cancelled or value == .failed;
}
fn validateMessage(message: provider.Message) !void {
    if (message.role != .user or message.tool_calls.len != 0 or message.tool_call_id != null or !std.unicode.utf8ValidateSlice(message.content) or message.images.len +| message.offloaded_images.len > @import("image_attachments.zig").max_count) return error.InvalidSubmission;
}
fn sameImage(left: @import("image_attachments.zig").ContentRef, right: @import("image_attachments.zig").ContentRef) bool {
    if (left.snapshot == right.snapshot) return true;
    const a = left.content() orelse return false;
    const b = right.content() orelse return false;
    return std.mem.eql(u8, &a.sha256, &b.sha256) and std.mem.eql(u8, a.path, b.path) and a.captured_at_ms == b.captured_at_ms;
}
