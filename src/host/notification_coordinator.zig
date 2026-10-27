//! Application-owned notification facts and presentation policy (V0.1.8 §3).
//! Call on the main thread from actual service events, never from UI redraw.
//! This module does not claim a platform permission or delivery capability.
const std = @import("std");
const config = @import("../config/config.zig");
const identity = @import("identity.zig");

pub const Owner = identity.ContentOwner;
pub const Kind = enum { transfer_done, reconnect, ai_ready };
pub const Result = enum { succeeded, disconnected, recovered, failed, cancelled, unverified, pending, stream_done };
pub const Authorization = enum { unavailable, not_determined, denied, restricted, authorized, provisional };
pub const Disposition = enum { delivered, pending, scheduled, disabled, quiet, unauthorized, unsupported, failed, duplicate, not_applicable, rate_limited };
pub const Receipt = struct { disposition: Disposition, failure: ?anyerror = null };
/// Scheduled is an OS submission receipt, not proof of a visible banner.
pub const AsyncResult = union(enum) { scheduled, failed: ?anyerror };

pub const QuietHours = struct {
    start_minute: u16,
    end_minute: u16,

    pub fn parse(text: []const u8) !QuietHours {
        if (!config.validQuietHours(text)) return error.InvalidQuietHours;
        for ([_]usize{ 0, 1, 3, 4, 6, 7, 9, 10 }) |at| if (!std.ascii.isDigit(text[at])) return error.InvalidQuietHours;
        return .{
            .start_minute = try std.fmt.parseInt(u16, text[0..2], 10) * 60 + try std.fmt.parseInt(u16, text[3..5], 10),
            .end_minute = try std.fmt.parseInt(u16, text[6..8], 10) * 60 + try std.fmt.parseInt(u16, text[9..11], 10),
        };
    }
    /// Start is inclusive and end exclusive. Equal endpoints are empty.
    pub fn contains(self: QuietHours, local_minute: u16) bool {
        if (local_minute >= 24 * 60 or self.start_minute == self.end_minute) return false;
        if (self.start_minute < self.end_minute) return local_minute >= self.start_minute and local_minute < self.end_minute;
        return local_minute >= self.start_minute or local_minute < self.end_minute;
    }
};

pub const Policy = struct {
    transfer_done: bool,
    reconnect: bool,
    ai_ready: bool,
    bell: bool,
    tab_dot: bool,
    quiet_hours: QuietHours,

    pub fn fromSaved(value: config.Notify) !Policy {
        return .{ .transfer_done = value.transfer_done, .reconnect = value.reconnect, .ai_ready = value.ai_ready, .bell = value.bell, .tab_dot = value.tab_dot, .quiet_hours = try QuietHours.parse(value.quiet_hours) };
    }
    fn enabled(self: Policy, kind: Kind) bool {
        return switch (kind) {
            .transfer_done => self.transfer_done,
            .reconnect => self.reconnect,
            .ai_ready => self.ai_ready,
        };
    }
};

/// local_minute comes from the current system timezone for this event.
/// A timezone/clock change never causes an old event to be replayed.
pub const Clock = struct { local_minute: u16, monotonic_ms: u64 };
pub const Event = struct {
    event_id: u64,
    kind: Kind,
    owner: Owner,
    operation_id: u64,
    attempt_or_turn_id: ?u64 = null,
    result: Result,
    summary: []const u8,
    terminal_confirmed: bool = false,
    resources_released: bool = false,
    final_answer: bool = false,
    /// Frozen per-intent choice, in addition to the saved application policy.
    system_enabled: bool = true,
};
pub const Target = struct {
    owner: Owner,
    kind: Kind,
    operation_id: u64,
    attempt_or_turn_id: ?u64,
};
pub const SystemMessage = struct { event_id: u64, summary: []const u8, target: Target };
pub const BellMessage = struct { owner: Owner, sequence: u64 };
pub const Sink = struct {
    context: ?*anyopaque = null,
    authorization: Authorization = .unavailable,
    /// A platform implementation must copy borrowed message text before an
    /// asynchronous send. No callback means the capability is unavailable.
    notify: ?*const fn (*anyopaque, SystemMessage) anyerror!void = null,
    ring: ?*const fn (*anyopaque, BellMessage) anyerror!void = null,
    delivery_mode: enum { synchronous, asynchronous } = .synchronous,
};
pub const Record = struct {
    event: Event,
    policy_revision: u64,
    local_minute: u16,
    system: Receipt,
    pub fn target(self: Record) Target {
        return .{ .owner = self.event.owner, .kind = self.event.kind, .operation_id = self.event.operation_id, .attempt_or_turn_id = self.event.attempt_or_turn_id };
    }
};
pub const Published = struct { record_index: usize, duplicate: bool };
pub const Attention = struct {
    owner: Owner,
    output_sequence: u64 = 0,
    read_sequence: u64 = 0,
    notification_sequence: u64 = 0,
    notification_read_sequence: u64 = 0,
    bell_sequence: u64 = 0,
    last_bell_attempt_ms: ?u64 = null,
};
pub const BellReceipt = struct { duplicate: bool, sound: Receipt };

pub const Coordinator = struct {
    pub const bell_interval_ms: u64 = 1000;
    pub const history_limit: usize = 100;
    history_revision: u64 = 0,
    allocator: std.mem.Allocator,
    policy: Policy,
    policy_revision: u64 = 1,
    sink: Sink,
    records: std.ArrayList(Record) = .empty,
    attention: std.ArrayList(Attention) = .empty,
    definitions: std.ArrayList(OwnedDefinition) = .empty,
    notification_records: std.ArrayList(NotificationRecord) = .empty,
    presentation_queue: [256]u64 = undefined,
    presentation_count: usize = 0,
    next_fact: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, saved: config.Notify, sink: Sink) !Coordinator {
        if ((sink.notify != null or sink.ring != null) and sink.context == null) return error.MissingPlatformContext;
        var self: Coordinator = .{ .allocator = allocator, .policy = try Policy.fromSaved(saved), .sink = sink };
        errdefer self.deinit();
        try self.registerDefinition(.{ .id = "host.transfer_done", .category = .operation_result });
        try self.registerDefinition(.{ .id = "host.reconnect", .category = .connection_change });
        try self.registerDefinition(.{ .id = "host.ai_ready", .category = .attention });
        try self.registerDefinition(.{ .id = "host.feedback", .category = .operation_result, .default_channels = .{ .attention = false } });
        try self.registerDefinition(.{ .id = "host.command_error", .category = .operation_result, .default_channels = .{ .in_app = false, .system = false, .attention = false } });
        return self;
    }
    pub fn deinit(self: *Coordinator) void {
        for (self.records.items) |record| self.allocator.free(record.event.summary);
        self.records.deinit(self.allocator);
        self.attention.deinit(self.allocator);
        for (self.definitions.items) |definition| self.allocator.free(definition.value.id);
        self.definitions.deinit(self.allocator);
        for (self.notification_records.items) |*record| record.arena.deinit();
        self.notification_records.deinit(self.allocator);
        self.* = undefined;
    }
    /// Change only future delivery decisions. A suppressed/failed old event is
    /// still consumed and cannot be replayed by Save or permission changes.
    pub fn updatePolicy(self: *Coordinator, saved: config.Notify) !bool {
        const next = try Policy.fromSaved(saved);
        if (std.meta.eql(self.policy, next)) return false;
        if (self.policy_revision == std.math.maxInt(u64)) return error.PolicyRevisionExhausted;
        self.policy = next;
        self.policy_revision += 1;
        return true;
    }
    /// Only a real platform authorization report should call this. Enabling a
    /// saved preference never grants permission or requests it implicitly.
    pub fn reportAuthorization(self: *Coordinator, authorization: Authorization) void {
        self.sink.authorization = authorization;
    }

    pub fn publish(self: *Coordinator, event: Event, clock: Clock) !Published {
        try validClock(clock);
        try validEvent(event);
        for (self.records.items, 0..) |record, index| {
            if (record.event.event_id == event.event_id) {
                if (!sameOperation(record.event, event) or record.event.result != event.result) return error.EventIdentityConflict;
                return .{ .record_index = index, .duplicate = true };
            }
            if (sameOperation(record.event, event)) {
                if (record.event.result != event.result) return error.OperationResultConflict;
                return .{ .record_index = index, .duplicate = true };
            }
        }
        // Allocate both the owned fact and slot before performing any external
        // effect, so allocation failure cannot deliver an untracked event.
        try self.records.ensureUnusedCapacity(self.allocator, 1);
        const summary = try self.allocator.dupe(u8, event.summary);
        var owned = event;
        owned.summary = summary;
        const index = self.records.items.len;
        self.records.appendAssumeCapacity(.{ .event = owned, .policy_revision = self.policy_revision, .local_minute = clock.local_minute, .system = .{ .disposition = .not_applicable } });
        const receipt = self.deliver(owned, clock);
        self.records.items[index].system = receipt;
        return .{ .record_index = index, .duplicate = false };
    }

    pub fn registerDefinition(self: *Coordinator, definition: NotificationDefinition) !void {
        if (definition.version == 0 or definition.id.len == 0 or definition.id.len > 128 or std.mem.indexOfScalar(u8, definition.id, '.') == null) return error.InvalidNotificationDefinition;
        for (definition.id) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '_' and c != '-') return error.InvalidNotificationDefinition;
        for (self.definitions.items) |existing| if (std.mem.eql(u8, existing.value.id, definition.id)) {
            if (existing.value.version != definition.version or existing.value.category != definition.category or !std.meta.eql(existing.value.default_channels, definition.default_channels) or existing.value.system_policy != definition.system_policy) return error.NotificationDefinitionConflict;
            return;
        };
        const id = try self.allocator.dupe(u8, definition.id);
        errdefer self.allocator.free(id);
        var copy = definition;
        copy.id = id;
        try self.definitions.append(self.allocator, .{ .value = copy });
    }
    pub fn definitionFor(self: *const Coordinator, id: []const u8) ?NotificationDefinition {
        for (self.definitions.items) |definition| if (std.mem.eql(u8, definition.value.id, id)) return definition.value;
        return null;
    }
    pub fn recordFor(self: *const Coordinator, fact_id: u64) ?*const NotificationRecord {
        for (self.notification_records.items) |*record| if (record.fact_id == fact_id) return record;
        return null;
    }
    pub fn factFor(self: *const Coordinator, event: NotificationEvent) ?*const NotificationRecord {
        for (self.notification_records.items) |*record| if (sameNotification(record.event, event)) return record;
        return null;
    }
    /// Unified publish/update: monotonic revisions replace the original fact.
    /// No system policy/authorization change can replay an old revision.
    pub fn publishNotification(self: *Coordinator, event: NotificationEvent, clock: Clock) !NotificationPublication {
        try validClock(clock);
        try validOwner(event.owner.content);
        const definition = self.definitionFor(event.definition_id) orelse return error.UnknownNotificationDefinition;
        if (definition.version != event.definition_version) return error.NotificationDefinitionVersionMismatch;
        if (event.owner.window_id == 0 or event.operation_id == 0 or event.event_revision == 0 or event.attempt_id == 0) return error.InvalidNotificationIdentity;
        if (event.title.len == 0 or event.title.len > 256 or event.detail.len > 4096 or event.owner_name.len > 256 or event.object_name.len > 1024 or event.actions.len > 3) return error.InvalidNotificationContent;
        for (event.actions) |action| if (action.label.len == 0 or action.label.len > 128 or (action.kind == .safe_query and action.action_id == 0)) return error.InvalidNotificationAction;
        for (self.notification_records.items) |*record| if (sameNotification(record.event, event)) {
            if (event.event_revision <= record.event.event_revision) return .{ .fact_id = record.fact_id, .duplicate = true, .updated = false };
            if (!legalPhase(record.event.phase, event.phase)) return error.InvalidNotificationTransition;
            var replacement = try copyNotification(self.allocator, event, record.fact_id, clock.monotonic_ms);
            replacement.presentation = record.presentation;
            replacement.owner_ended = record.owner_ended;
            replacement.history_read = false;
            self.history_revision +|= 1;
            // Reconcile persistent unknown/error in place. A dismissed toast
            // remains dismissed; updates never steal focus or recreate it.
            replacement.system = record.system;
            replacement.system_event_id = record.system_event_id;
            record.arena.deinit();
            record.* = replacement;
            if (definition.default_channels.attention) {
                const state = try self.stateFor(event.owner.content);
                state.notification_sequence +|= 1;
            }
            if (record.system.disposition == .not_applicable) self.deliverNotification(record, definition, clock);
            return .{ .fact_id = record.fact_id, .duplicate = false, .updated = true };
        };
        if (self.next_fact >= (@as(u64, 1) << 63)) return error.NotificationIdentityExhausted;
        var record = try copyNotification(self.allocator, event, self.next_fact, clock.monotonic_ms);
        errdefer record.arena.deinit();
        try self.notification_records.ensureUnusedCapacity(self.allocator, 1);
        if (!definition.default_channels.in_app) record.presentation = .hidden;
        if (self.notification_records.items.len >= history_limit) self.removeHistoryAt(0);
        self.notification_records.appendAssumeCapacity(record);
        self.history_revision +|= 1;
        const fact_id = self.next_fact;
        self.next_fact += 1;
        if (definition.default_channels.in_app) self.enqueue(fact_id);
        if (definition.default_channels.attention) {
            const state = self.stateFor(event.owner.content) catch return .{ .fact_id = fact_id, .duplicate = false, .updated = false };
            state.notification_sequence +|= 1;
        }
        self.deliverNotification(&self.notification_records.items[self.notification_records.items.len - 1], definition, clock);
        return .{ .fact_id = fact_id, .duplicate = false, .updated = false };
    }
    fn removeHistoryAt(self: *Coordinator, index: usize) void {
        var removed = self.notification_records.orderedRemove(index);
        self.dequeue(removed.fact_id);
        removed.arena.deinit();
    }
    pub fn clearHistory(self: *Coordinator) void {
        while (self.notification_records.items.len > 0) self.removeHistoryAt(self.notification_records.items.len - 1);
        self.history_revision +|= 1;
    }
    pub fn unreadHistoryCount(self: *const Coordinator) usize {
        var count: usize = 0;
        for (self.notification_records.items) |record| if (!record.history_read) {
            count += 1;
        };
        return count;
    }
    pub fn readHistory(self: *Coordinator) void {
        for (self.notification_records.items) |*record| record.history_read = true;
    }
    fn deliverNotification(self: *Coordinator, record: *NotificationRecord, definition: NotificationDefinition, clock: Clock) void {
        if (!definition.default_channels.system or definition.system_policy == null) return;
        const event = record.event;
        const policy_kind = definition.system_policy.?;
        const id = record.fact_id | (@as(u64, 1) << 63);
        const legacy: Event = .{ .event_id = id, .kind = policy_kind, .owner = event.owner.content, .operation_id = event.operation_id, .attempt_or_turn_id = event.attempt_id, .result = switch (event.phase) {
            .succeeded => if (policy_kind == .reconnect) .recovered else .succeeded,
            .failed => .failed,
            else => .pending,
        }, .summary = event.title, .terminal_confirmed = true, .resources_released = true, .final_answer = true, .system_enabled = event.system_enabled };
        record.system = self.deliver(legacy, clock);
        if (record.system.disposition != .not_applicable) record.system_event_id = id;
    }
    pub fn dismissNotification(self: *Coordinator, fact_id: u64) void {
        for (self.notification_records.items) |*record| if (record.fact_id == fact_id) {
            record.presentation = .hidden;
            break;
        };
        self.dequeue(fact_id);
    }
    pub fn pauseNotification(self: *Coordinator, fact_id: u64, paused: bool) void {
        for (self.notification_records.items) |*record| if (record.fact_id == fact_id) {
            if (record.paused and !paused and !record.persistent()) record.remaining_ms = if (record.event.actions.len > 0) 8000 else 4000;
            record.paused = paused;
            return;
        };
    }
    pub fn ownerEnded(self: *Coordinator, owner: Owner) void {
        for (self.notification_records.items) |*record| if (record.event.owner.content.eql(owner)) {
            record.owner_ended = true;
            self.history_revision +|= 1;
        };
    }
    pub fn moveOwner(self: *Coordinator, owner: Owner, window_id: u64) void {
        for (self.notification_records.items) |*record| if (record.event.owner.content.eql(owner)) {
            record.event.owner.window_id = window_id;
        };
    }
    /// Returns up to three visible facts for this window. Ordinary stale
    /// success never reappears when returning to a background window.
    pub fn visibleNotifications(self: *Coordinator, window_id: u64, now_ms: u64, focused: bool, output: *[3]*const NotificationRecord) usize {
        var visible: usize = 0;
        var i: usize = 0;
        while (i < self.presentation_count) {
            const id = self.presentation_queue[i];
            var found: ?*NotificationRecord = null;
            for (self.notification_records.items) |*record| if (record.fact_id == id) {
                found = record;
                break;
            };
            const record = found orelse {
                self.dequeue(id);
                continue;
            };
            // A different window's frame/focus state cannot consume this
            // presentation timer or override its hover/focus pause receipt.
            if (record.event.owner.window_id != window_id) {
                i += 1;
                continue;
            }
            const has_slot = focused and visible < output.len;
            if (!record.persistent()) {
                const elapsed = now_ms -| record.last_tick_ms;
                if (record.presentation == .visible and has_slot and !record.paused) record.remaining_ms -|= elapsed;
                record.last_tick_ms = now_ms;
                if (record.remaining_ms == 0) {
                    record.presentation = .expired;
                    self.dequeue(id);
                    continue;
                }
            } else record.last_tick_ms = now_ms;
            if (has_slot) {
                record.presentation = .visible;
                output[visible] = record;
                visible += 1;
            }
            if (!has_slot) record.presentation = .queued;
            i += 1;
        }
        return visible;
    }
    fn enqueue(self: *Coordinator, fact_id: u64) void {
        if (self.presentation_count == self.presentation_queue.len) {
            var victim: usize = 0;
            // Prefer an old info/success presentation. Facts remain retained.
            for (self.presentation_queue[0..self.presentation_count], 0..) |id, i| if (self.recordFor(id)) |record| {
                if (!record.persistent()) {
                    victim = i;
                    break;
                }
            };
            const removed = self.presentation_queue[victim];
            for (self.notification_records.items) |*record| if (record.fact_id == removed) {
                record.presentation = .hidden;
                break;
            };
            self.dequeue(removed);
        }
        var insertion = self.presentation_count;
        if (self.recordFor(fact_id)) |incoming| if (incoming.persistent()) {
            for (self.presentation_queue[0..self.presentation_count], 0..) |id, index| {
                if (self.recordFor(id)) |record| if (!record.persistent()) {
                    insertion = index;
                    break;
                };
            }
        };
        std.mem.copyBackwards(u64, self.presentation_queue[insertion + 1 .. self.presentation_count + 1], self.presentation_queue[insertion..self.presentation_count]);
        self.presentation_queue[insertion] = fact_id;
        self.presentation_count += 1;
    }
    fn dequeue(self: *Coordinator, fact_id: u64) void {
        for (self.presentation_queue[0..self.presentation_count], 0..) |id, i| if (id == fact_id) {
            std.mem.copyForwards(u64, self.presentation_queue[i .. self.presentation_count - 1], self.presentation_queue[i + 1 .. self.presentation_count]);
            self.presentation_count -= 1;
            return;
        };
    }

    /// Records actual owner-bound output generations, without producing a
    /// system notification per line or depending on widget recreation.
    pub fn observeOutput(self: *Coordinator, owner: Owner, sequence: u64) !bool {
        try validOwner(owner);
        if (sequence == 0) return error.InvalidPublicationSequence;
        const state = try self.stateFor(owner);
        if (sequence <= state.output_sequence) return false;
        state.output_sequence = sequence;
        return true;
    }
    pub fn hasDot(self: *const Coordinator, owner: Owner) bool {
        if (!self.policy.tab_dot) return false;
        for (self.attention.items) |state| if (state.owner.eql(owner)) return state.output_sequence > state.read_sequence or state.notification_sequence > state.notification_read_sequence;
        return false;
    }
    /// A visible owner's notification projection is an independent read receipt;
    /// it must never advance or fabricate the terminal output generation.
    pub fn markNotificationsRead(self: *Coordinator, owner: Owner) bool {
        for (self.attention.items) |*state| if (state.owner.eql(owner)) {
            if (state.notification_read_sequence == state.notification_sequence) return false;
            state.notification_read_sequence = state.notification_sequence;
            return true;
        };
        return false;
    }
    /// The host must prove the exact content is visible and read through this
    /// generation (for a terminal, visible and following its current tail).
    /// A future acknowledgement cannot silently consume later output.
    pub fn markRead(self: *Coordinator, owner: Owner, through_sequence: u64, visible_and_at_latest: bool) bool {
        if (!visible_and_at_latest) return false;
        for (self.attention.items) |*state| if (state.owner.eql(owner)) {
            if (through_sequence == 0 or through_sequence > state.output_sequence or through_sequence <= state.read_sequence) return false;
            state.read_sequence = through_sequence;
            return true;
        };
        return false;
    }
    /// Consume a real VT Bell counter once. Disabling sound or quiet hours
    /// does not discard output attention or terminal state.
    pub fn observeBell(self: *Coordinator, owner: Owner, sequence: u64, clock: Clock) !BellReceipt {
        try validOwner(owner);
        try validClock(clock);
        if (sequence == 0) return error.InvalidPublicationSequence;
        const state = try self.stateFor(owner);
        if (sequence <= state.bell_sequence) return .{ .duplicate = true, .sound = .{ .disposition = .duplicate } };
        state.bell_sequence = sequence;
        if (!self.policy.bell) return .{ .duplicate = false, .sound = .{ .disposition = .disabled } };
        if (self.policy.quiet_hours.contains(clock.local_minute)) return .{ .duplicate = false, .sound = .{ .disposition = .quiet } };
        if (state.last_bell_attempt_ms) |previous| if (clock.monotonic_ms -| previous < bell_interval_ms) return .{ .duplicate = false, .sound = .{ .disposition = .rate_limited } };
        state.last_bell_attempt_ms = clock.monotonic_ms;
        const ring = self.sink.ring orelse return .{ .duplicate = false, .sound = .{ .disposition = .unsupported } };
        ring(self.sink.context.?, .{ .owner = owner, .sequence = sequence }) catch |err| return .{ .duplicate = false, .sound = .{ .disposition = .failed, .failure = err } };
        return .{ .duplicate = false, .sound = .{ .disposition = .delivered } };
    }
    pub fn targetFor(self: *const Coordinator, event_id: u64) ?Target {
        for (self.records.items) |record| if (record.event.event_id == event_id) return record.target();
        for (self.notification_records.items) |record| if (record.system_event_id == event_id) {
            const definition = self.definitionFor(record.event.definition_id) orelse return null;
            return .{ .owner = record.event.owner.content, .kind = definition.system_policy orelse return null, .operation_id = record.event.operation_id, .attempt_or_turn_id = record.event.attempt_id };
        };
        return null;
    }
    /// Complete only the original asynchronous attempt. Updating permission,
    /// policy or UI never retries it, and a mismatched owner cannot consume it.
    pub fn reportSystemResult(self: *Coordinator, event_id: u64, target: Target, result: AsyncResult) !bool {
        if (self.sink.delivery_mode != .asynchronous) return error.NotAnAsynchronousSink;
        const receipt: Receipt = switch (result) {
            .scheduled => .{ .disposition = .scheduled },
            .failed => |failure| .{ .disposition = .failed, .failure = failure },
        };
        for (self.records.items) |*record| if (record.event.event_id == event_id) {
            if (!std.meta.eql(record.target(), target)) return error.EventIdentityConflict;
            if (record.system.disposition == .pending) {
                record.system = receipt;
                return true;
            }
            if (record.system.disposition == .scheduled or record.system.disposition == .failed) {
                if (std.meta.eql(record.system, receipt)) return false;
                return error.SystemResultConflict;
            }
            return error.NoPendingSystemNotification;
        };
        for (self.notification_records.items) |*record| if (record.system_event_id == event_id) {
            const definition = self.definitionFor(record.event.definition_id) orelse return error.UnknownNotificationDefinition;
            const original: Target = .{ .owner = record.event.owner.content, .kind = definition.system_policy orelse return error.UnknownNotificationDefinition, .operation_id = record.event.operation_id, .attempt_or_turn_id = record.event.attempt_id };
            if (!std.meta.eql(original, target)) return error.EventIdentityConflict;
            if (record.system.disposition == .pending) {
                record.system = receipt;
                return true;
            }
            if (record.system.disposition == .scheduled or record.system.disposition == .failed) {
                if (std.meta.eql(record.system, receipt)) return false;
                return error.SystemResultConflict;
            }
            return error.NoPendingSystemNotification;
        };
        return error.UnknownNotificationEvent;
    }
    fn stateFor(self: *Coordinator, owner: Owner) !*Attention {
        for (self.attention.items) |*state| if (state.owner.eql(owner)) return state;
        try self.attention.append(self.allocator, .{ .owner = owner });
        return &self.attention.items[self.attention.items.len - 1];
    }
    fn deliver(self: *Coordinator, event: Event, clock: Clock) Receipt {
        const applicable = switch (event.kind) {
            .transfer_done, .ai_ready => event.result == .succeeded,
            .reconnect => event.result == .disconnected or event.result == .recovered or event.result == .failed,
        };
        if (!applicable) return .{ .disposition = .not_applicable };
        if (!event.system_enabled) return .{ .disposition = .disabled };
        if (!self.policy.enabled(event.kind)) return .{ .disposition = .disabled };
        if (self.policy.quiet_hours.contains(clock.local_minute)) return .{ .disposition = .quiet };
        const notify = self.sink.notify orelse return .{ .disposition = .unsupported };
        if (self.sink.authorization != .authorized and self.sink.authorization != .provisional) return .{ .disposition = if (self.sink.authorization == .unavailable) .unsupported else .unauthorized };
        notify(self.sink.context.?, .{ .event_id = event.event_id, .summary = event.summary, .target = .{ .owner = event.owner, .kind = event.kind, .operation_id = event.operation_id, .attempt_or_turn_id = event.attempt_or_turn_id } }) catch |err| return .{ .disposition = .failed, .failure = err };
        return .{ .disposition = if (self.sink.delivery_mode == .asynchronous) .pending else .delivered };
    }
};

fn validClock(clock: Clock) !void {
    if (clock.local_minute >= 24 * 60) return error.InvalidLocalMinute;
}
fn validOwner(owner: Owner) !void {
    const valid = switch (owner) {
        .session => |value| @backingInt(value.session_id) != 0 and value.generation != 0,
        .group => |value| @backingInt(value.id) != 0 and value.revision != 0,
        .history => |value| @backingInt(value) != 0,
    };
    if (!valid) return error.InvalidOwner;
}
fn validEvent(event: Event) !void {
    try validOwner(event.owner);
    if (event.event_id == 0 or event.operation_id == 0 or (event.attempt_or_turn_id != null and event.attempt_or_turn_id.? == 0)) return error.InvalidEventIdentity;
    if (!event.terminal_confirmed) return error.NotTerminal;
    switch (event.kind) {
        .transfer_done => {
            if (event.result != .succeeded and event.result != .failed and event.result != .cancelled) return error.InvalidEventResult;
            if (event.result == .succeeded and !event.resources_released) return error.ResultNotReleased;
        },
        .ai_ready => {
            if (event.result != .succeeded and event.result != .failed and event.result != .cancelled and event.result != .unverified) return error.InvalidEventResult;
            if (event.result == .succeeded and (!event.final_answer or !event.resources_released)) return error.AnswerNotFinal;
        },
        .reconnect => if (event.result != .disconnected and event.result != .recovered and event.result != .failed) return error.InvalidEventResult,
    }
}
fn sameOperation(a: Event, b: Event) bool {
    if (a.kind != b.kind or !a.owner.eql(b.owner) or a.operation_id != b.operation_id or a.attempt_or_turn_id != b.attempt_or_turn_id) return false;
    // A lost connection and its later recovered result are distinct service
    // transitions. Polling the same transition is still a duplicate.
    return a.kind != .reconnect or a.result == b.result;
}

// Open plugin notification contract. Legacy Kind remains solely a compatibility
// policy key and macOS activation target; plugins never extend that enum.
pub const NotificationCategory = enum { operation_result, connection_change, attention };
pub const Channels = struct { in_app: bool = true, attention: bool = true, system: bool = false };
pub const NotificationDefinition = struct {
    id: []const u8,
    version: u32 = 1,
    category: NotificationCategory,
    default_channels: Channels = .{},
    /// Reuse existing settings only. Null never implies a new system policy.
    system_policy: ?Kind = null,
};
pub const Phase = enum { accepted, verifying, succeeded, failed, outcome_unknown, cancelled };
pub const Severity = enum { info, success, warning, failure };
pub const NotificationOwner = struct {
    window_id: u64,
    content: Owner,
    pub fn eql(a: NotificationOwner, b: NotificationOwner) bool {
        return a.window_id == b.window_id and a.content.eql(b.content);
    }
};
pub const ActionKind = enum { locate_owner, view_result, safe_query };
pub const NotificationAction = struct { kind: ActionKind, label: []const u8, action_id: u64 = 0 };
pub const NotificationEvent = struct {
    definition_id: []const u8,
    definition_version: u32 = 1,
    owner: NotificationOwner,
    operation_id: u64,
    attempt_id: ?u64 = null,
    event_revision: u64,
    phase: Phase,
    severity: Severity = .info,
    title: []const u8,
    detail: []const u8 = "",
    owner_name: []const u8 = "",
    object_name: []const u8 = "",
    /// Host channel gate, in addition to the immutable definition and saved policy.
    system_enabled: bool = true,
    actions: []const NotificationAction = &.{},
};
pub const Presentation = enum { queued, visible, hidden, expired };
pub const NotificationRecord = struct {
    arena: std.heap.ArenaAllocator,
    fact_id: u64,
    system_event_id: ?u64 = null,
    event: NotificationEvent,
    system: Receipt = .{ .disposition = .not_applicable },
    presentation: Presentation = .queued,
    published_ms: u64,
    remaining_ms: u64 = 4000,
    last_tick_ms: u64,
    paused: bool = false,
    owner_ended: bool = false,
    history_read: bool = false,
    pub fn persistent(self: NotificationRecord) bool {
        return self.event.phase == .failed or self.event.phase == .outcome_unknown or self.event.severity == .failure or self.event.severity == .warning;
    }
};
pub const NotificationPublication = struct { fact_id: u64, duplicate: bool, updated: bool };
const OwnedDefinition = struct { value: NotificationDefinition };
fn sameNotification(a: NotificationEvent, b: NotificationEvent) bool {
    return std.mem.eql(u8, a.definition_id, b.definition_id) and a.owner.content.eql(b.owner.content) and a.operation_id == b.operation_id and a.attempt_id == b.attempt_id;
}
fn legalPhase(from: Phase, to: Phase) bool {
    if (from == to) return true;
    return switch (from) {
        .accepted => to == .verifying or to == .succeeded or to == .failed or to == .outcome_unknown or to == .cancelled,
        .verifying => to == .succeeded or to == .failed or to == .outcome_unknown or to == .cancelled,
        .outcome_unknown => to == .verifying or to == .succeeded or to == .failed,
        else => false,
    };
}
fn copyNotification(allocator: std.mem.Allocator, event: NotificationEvent, fact_id: u64, now_ms: u64) !NotificationRecord {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();
    var copy = event;
    copy.definition_id = try owned.dupe(u8, event.definition_id);
    copy.title = try owned.dupe(u8, event.title);
    copy.detail = try owned.dupe(u8, event.detail);
    copy.owner_name = try owned.dupe(u8, event.owner_name);
    copy.object_name = try owned.dupe(u8, event.object_name);
    const actions = try owned.alloc(NotificationAction, event.actions.len);
    for (event.actions, 0..) |action, i| {
        actions[i] = action;
        actions[i].label = try owned.dupe(u8, action.label);
    }
    copy.actions = actions;
    return .{ .arena = arena, .fact_id = fact_id, .event = copy, .published_ms = now_ms, .last_tick_ms = now_ms, .remaining_ms = if (event.actions.len > 0) 8000 else 4000 };
}
