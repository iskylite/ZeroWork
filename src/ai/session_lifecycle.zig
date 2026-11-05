//! Controller-owned authority for attached AI conversations. Stable allocations
//! survive list growth. UI selection is deliberately not part of this API.
const std = @import("std");
const identity = @import("../host/identity.zig");
const scope = @import("tool_scope.zig");
const wire = @import("wire_history.zig");
const provider = @import("provider.zig");
const context_usage = @import("context_usage.zig");
pub const input = @import("session_input.zig");
pub const Binding = struct { agent: identity.AgentId, owner: scope.Owner };
pub const End = struct { operation: identity.HostOperationId, fence: input.Fence, failed: bool = false };
pub const Released = struct { worker_joined: bool, dispatch_closed: bool, local_released: bool, transcript_saved: bool };
pub const Event = struct {
    kind: enum { create, bind, end_requested, unbind, fork, fork_bound, handoff, environment, checkpoint, presentation, draft, remove, migrate_bound, migrate_closed },
    conversation: identity.ConversationId,
    agent: ?identity.AgentId = null,
    owner: ?scope.Owner = null,
    revision: u64,
    environment: u64 = 1,
    operation: ?identity.HostOperationId = null,
    parent: ?identity.ConversationId = null,
    source_revision: ?u64 = null,
    turn: u64 = 0,
    messages: []const provider.Message = &.{},
    presentation: ?[]const u8 = null,
    context_usage: ?context_usage.Stored = null,
    draft: ?[]const u8 = null,
    recoverable: bool = true,
    initial_input: ?input.Receipt = null,
    initial_origin: ?scope.Owner = null,
};
pub const Persistence = struct {
    context: *anyopaque,
    write: *const fn (*anyopaque, Event) anyerror!void,
};
pub const Record = struct {
    id: identity.ConversationId,
    initial_origin: ?scope.Owner = null,
    binding: ?Binding = null,
    revision: u64 = 1,
    closed_revision: ?u64 = null,
    content_revision: u64 = 1,
    draft_revision: u64 = 1,
    history: wire.History = .{},
    presentation: ?[]u8 = null,
    recovery_history: wire.History = .{},
    recovery_turn: u64 = 0,
    draft: ?[]u8 = null,
    last_turn: u64 = 0,
    recoverable: bool = true,
    ending: ?End = null,
    last_end: ?End = null,
    parent: ?identity.ConversationId = null,
    source_revision: ?u64 = null,
    fork_turn: ?u64 = null,
    historical_messages: usize = 0,
    needs_recovery: bool = false,
    inbox: input.Inbox,
    fn deinit(self: *Record, a: std.mem.Allocator) void {
        self.history.deinit();
        if (self.presentation) |bytes| a.free(bytes);
        self.recovery_history.deinit();
        if (self.draft) |text| a.free(text);
        self.inbox.deinit();
        a.destroy(self);
    }
};
pub const Agent = struct {
    id: identity.AgentId,
    owner: scope.Owner,
    current: ?identity.ConversationId = null,
    environment: u64 = 1,
    busy: bool = false,
    closing: bool = false,
};
pub const Store = struct {
    allocator: std.mem.Allocator,
    agents: std.ArrayList(*Agent) = .empty,
    records: std.ArrayList(*Record) = .empty,
    persist: ?Persistence = null,
    input_persist: ?input.Persist = null,
    budget: input.Budget = .{},

    pub fn init(a: std.mem.Allocator) Store {
        return .{ .allocator = a };
    }
    pub fn deinit(self: *Store) void {
        for (self.records.items) |record| record.deinit(self.allocator);
        for (self.agents.items) |value| self.allocator.destroy(value);
        self.records.deinit(self.allocator);
        self.agents.deinit(self.allocator);
    }
    fn save(self: *Store, event: Event) !void {
        if (self.persist) |p| try p.write(p.context, event);
    }
    pub fn find(self: *Store, id: identity.ConversationId) ?*Record {
        for (self.records.items) |record| if (record.id.eql(id)) return record;
        return null;
    }
    pub fn agent(self: *Store, id: identity.AgentId) ?*Agent {
        for (self.agents.items) |value| if (value.id.eql(id)) return value;
        return null;
    }
    pub fn attach(self: *Store, owner: scope.Owner) !*Agent {
        switch (owner) {
            .session => |id| if (id == 0) return error.InvalidOwner,
            .group => |id| if (id == 0) return error.InvalidOwner,
        }
        for (self.agents.items) |value| if (value.owner.eql(owner)) {
            if (value.current) |id| if (self.find(id).?.needs_recovery) return error.RecoveryRequired;
            if (!value.closing) return value;
        };
        try self.agents.ensureUnusedCapacity(self.allocator, 1);
        const value = try self.allocator.create(Agent);
        value.* = .{ .id = identity.AgentId.generate(), .owner = owner };
        self.agents.appendAssumeCapacity(value);
        return value;
    }
    /// A destroyed attachment cannot be resurrected by a later object that
    /// happens to reuse its numeric owner. Ending must already have released it.
    pub fn retire(self: *Store, agent_id: identity.AgentId) !void {
        const target = self.agent(agent_id) orelse return error.AgentNotFound;
        if (target.current != null or target.busy) return error.BindingConflict;
        target.closing = true;
    }
    pub fn fence(self: *Store, id: identity.ConversationId) !input.Fence {
        const record = self.find(id) orelse return error.ConversationNotFound;
        const bound = record.binding orelse return error.ConversationUnbound;
        const current = self.agent(bound.agent) orelse return error.AgentNotFound;
        if (current.current == null or !current.current.?.eql(id) or !current.owner.eql(bound.owner)) return error.BindingChanged;
        return .{ .agent = bound.agent, .conversation = id, .binding = record.revision, .environment = current.environment };
    }
    pub fn validate(self: *Store, expected: input.Fence) !*Record {
        if (!(try self.fence(expected.conversation)).eql(expected)) return error.BindingChanged;
        const record = self.find(expected.conversation).?;
        if (record.needs_recovery) return error.RecoveryRequired;
        return record;
    }
    fn allocateRecord(self: *Store) !*Record {
        try self.records.ensureUnusedCapacity(self.allocator, 1);
        const record = try self.allocator.create(Record);
        const id = identity.ConversationId.generate();
        record.* = .{ .id = id, .inbox = input.Inbox.init(self.allocator, .{ .agent = .{}, .conversation = id, .binding = 1, .environment = 1 }) };
        record.inbox.admission = false;
        record.inbox.budget = &self.budget;
        record.inbox.persist = self.input_persist;
        return record;
    }
    pub fn create(self: *Store, agent_id: identity.AgentId) !input.Fence {
        const target = self.agent(agent_id) orelse return error.AgentNotFound;
        if (target.current != null or target.busy or target.closing) return error.BindingConflict;
        const record = try self.allocateRecord();
        errdefer record.deinit(self.allocator);
        const revision = try identity.advance(record.revision);
        try self.save(.{ .kind = .create, .conversation = record.id, .agent = target.id, .owner = target.owner, .revision = revision, .environment = target.environment });
        record.revision = revision;
        record.binding = .{ .agent = target.id, .owner = target.owner };
        record.initial_origin = target.owner;
        target.current = record.id;
        self.records.appendAssumeCapacity(record);
        const ticket = try self.fence(record.id);
        record.inbox.changeFence(ticket);
        return ticket;
    }
    /// Import one quiescent legacy record without changing its durable identity.
    /// Migration invalidates old binding tickets and never adopts a live task.
    pub fn migrate(self: *Store, id: identity.ConversationId, owner: scope.Owner, revision: u64, bound: bool, messages: []const provider.Message, draft: ?[]const u8, turn: u64) !*Record {
        return self.migrateWithOrigin(id, owner, revision, bound, messages, draft, turn, owner);
    }
    pub fn migrateWithOrigin(self: *Store, id: identity.ConversationId, owner: scope.Owner, revision: u64, bound: bool, messages: []const provider.Message, draft: ?[]const u8, turn: u64, origin: scope.Owner) !*Record {
        if (!id.valid() or revision == 0) return error.InvalidLegacyConversation;
        if (self.find(id)) |existing| return existing;
        const target = if (bound) try self.attach(owner) else null;
        if (target) |value| if (value.current != null or value.busy) return error.BindingConflict;
        var history = try wire.History.copy(self.allocator, messages, "");
        errdefer history.deinit();
        const text = if (draft) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (text) |value| self.allocator.free(value);
        const record = try self.allocateRecord();
        errdefer record.deinit(self.allocator);
        const next = try identity.advance(revision);
        try self.save(.{ .kind = if (bound) .migrate_bound else .migrate_closed, .conversation = id, .revision = next, .owner = owner, .initial_origin = origin, .agent = if (target) |value| value.id else null, .messages = messages, .draft = draft, .turn = turn });
        record.id = id;
        record.revision = next;
        record.history = history;
        record.draft = text;
        record.initial_origin = origin;
        record.last_turn = turn;
        record.historical_messages = messages.len;
        record.inbox.fence.conversation = id;
        if (target) |value| {
            record.binding = .{ .agent = value.id, .owner = owner };
            value.current = id;
            record.inbox.changeFence(.{ .agent = value.id, .conversation = id, .binding = next, .environment = value.environment });
        } else record.closed_revision = revision;
        self.records.appendAssumeCapacity(record);
        return record;
    }
    /// Welcome-page first send: body ownership, queue budget and binding are
    /// prepared privately, then published by one durable lifecycle event.
    pub fn createWithInput(self: *Store, agent_id: identity.AgentId, id: identity.SubmissionId, message: provider.Message, mode: input.Mode) !input.Fence {
        const target = self.agent(agent_id) orelse return error.AgentNotFound;
        if (target.current != null or target.busy or target.closing) return error.BindingConflict;
        const record = try self.allocateRecord();
        errdefer record.deinit(self.allocator);
        record.revision = try identity.advance(record.revision);
        const ticket: input.Fence = .{ .agent = target.id, .conversation = record.id, .binding = record.revision, .environment = target.environment };
        record.inbox.changeFence(ticket);
        record.inbox.persist = null;
        const receipt = try record.inbox.admit(ticket, id, message, mode);
        try self.save(.{ .kind = .create, .conversation = record.id, .agent = target.id, .owner = target.owner, .revision = record.revision, .environment = target.environment, .initial_input = receipt, .messages = record.inbox.entries.items[0].payload.messages });
        record.inbox.persist = self.input_persist;
        record.binding = .{ .agent = target.id, .owner = target.owner };
        record.initial_origin = target.owner;
        target.current = record.id;
        self.records.appendAssumeCapacity(record);
        return ticket;
    }
    pub fn beginEnd(self: *Store, expected: input.Fence, operation: identity.HostOperationId) !bool {
        const record = self.find(expected.conversation) orelse return error.ConversationNotFound;
        if (!operation.valid()) return error.InvalidOperation;
        if (record.last_end) |prior| if (prior.operation.eql(operation) and prior.fence.eql(expected)) return true;
        _ = try self.validate(expected);
        if (record.ending) |prior| {
            if (!prior.operation.eql(operation) or !prior.fence.eql(expected)) return error.LifecycleBusy;
        } else record.ending = .{ .operation = operation, .fence = expected };
        record.inbox.pauseAll(.end);
        self.save(.{ .kind = .end_requested, .conversation = record.id, .agent = expected.agent, .revision = expected.binding, .environment = expected.environment, .operation = operation }) catch |err| {
            record.ending.?.failed = true;
            return err;
        };
        record.ending.?.failed = false;
        return false;
    }
    pub fn commitEnd(self: *Store, expected: input.Fence, operation: identity.HostOperationId, released: Released) !void {
        const record = self.find(expected.conversation) orelse return error.ConversationNotFound;
        if (record.last_end) |prior| if (prior.operation.eql(operation) and prior.fence.eql(expected)) return;
        _ = try self.validate(expected);
        const pending = record.ending orelse return error.EndNotRequested;
        if (!pending.operation.eql(operation) or !pending.fence.eql(expected) or pending.failed) return error.StaleLifecycleOperation;
        const target = self.agent(expected.agent).?;
        if (target.busy or !released.worker_joined or !released.dispatch_closed or !released.local_released or !released.transcript_saved) return error.ResourceCleanupPending;
        const revision = try identity.advance(record.revision);
        try self.save(.{ .kind = .unbind, .conversation = record.id, .revision = revision, .operation = operation, .turn = record.last_turn, .messages = record.history.messages, .draft = record.draft });
        record.revision = revision;
        record.closed_revision = expected.binding;
        record.binding = null;
        record.last_end = pending;
        record.ending = null;
        target.current = null;
        record.inbox.archive();
    }
    pub fn resumeConversation(self: *Store, id: identity.ConversationId, agent_id: identity.AgentId, expected_revision: u64) !input.Fence {
        const record = self.find(id) orelse return error.ConversationNotFound;
        const target = self.agent(agent_id) orelse return error.AgentNotFound;
        if (record.binding != null or target.current != null or target.busy or target.closing) return error.BindingConflict;
        if (record.revision != expected_revision or record.ending != null) return error.BindingChanged;
        if (!record.recoverable or record.history.failure != null) return error.ConversationNotRecoverable;
        // A fresh never-used fork is also eligible for first binding.
        if (record.closed_revision == null and record.parent == null) return error.MissingEndReceipt;
        const revision = try identity.advance(record.revision);
        try self.save(.{ .kind = .bind, .conversation = id, .agent = target.id, .owner = target.owner, .revision = revision, .environment = target.environment });
        record.binding = .{ .agent = target.id, .owner = target.owner };
        record.revision = revision;
        target.current = id;
        record.historical_messages = record.history.messages.len;
        const ticket = try self.fence(id);
        record.inbox.changeFence(ticket);
        return ticket;
    }
    pub fn setDraft(self: *Store, expected: input.Fence, revision: u64, text: []const u8) !u64 {
        const record = try self.validate(expected);
        if (record.draft_revision != revision or text.len > wire.History.max_text_bytes or !std.unicode.utf8ValidateSlice(text)) return error.StaleDraft;
        const next = try identity.advance(revision);
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        try self.save(.{ .kind = .draft, .conversation = record.id, .agent = expected.agent, .revision = record.revision, .draft = text });
        if (record.draft) |old| self.allocator.free(old);
        record.draft = owned;
        record.draft_revision = next;
        return next;
    }
    /// Only the joined runtime commits canonical history. Live readers pin a
    /// separate immutable snapshot, never pointers into its growing tool loop.
    pub fn checkpoint(self: *Store, expected: input.Fence, turn: u64, messages: []const provider.Message, recoverable: bool) !void {
        const record = try self.validate(expected);
        const next = try identity.advance(record.content_revision);
        var snapshot = try wire.History.copy(self.allocator, messages, "");
        errdefer snapshot.deinit();
        try self.save(.{ .kind = .checkpoint, .conversation = record.id, .agent = expected.agent, .revision = record.revision, .turn = turn, .messages = snapshot.messages, .recoverable = recoverable });
        record.history.deinit();
        record.history = snapshot;
        record.recovery_history.deinit();
        record.content_revision = next;
        record.last_turn = turn;
        record.recoverable = recoverable;
    }
    /// Display history is independent of compacted model context and grants no authority.
    pub fn savePresentation(self: *Store, id: identity.ConversationId, bytes: []const u8) !void {
        const record = self.find(id) orelse return error.ConversationNotFound;
        try self.savePresentationWithUsage(id, bytes, record.history.usage);
    }
    /// Persist display data and its counter together, including explicit clears.
    pub fn savePresentationWithUsage(self: *Store, id: identity.ConversationId, bytes: []const u8, baseline: ?context_usage.Baseline) !void {
        const record = self.find(id) orelse return error.ConversationNotFound;
        const stored = context_usage.Stored.capture(record.history.messages, baseline);
        const valid = if (stored) |value| value.baseline else null;
        if (record.presentation) |prior| if (std.mem.eql(u8, prior, bytes) and std.meta.eql(record.history.usage, valid)) return;
        const owned = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(owned);
        try self.save(.{ .kind = .presentation, .conversation = id, .revision = record.revision, .presentation = bytes, .context_usage = stored });
        if (record.presentation) |prior| self.allocator.free(prior);
        record.presentation = owned;
        record.history.usage = valid;
    }
    pub const ForkSnapshot = struct {
        source: identity.ConversationId,
        revision: u64,
        turn: u64,
        origin: ?scope.Owner,
        history: wire.History,
        presentation: ?[]const u8 = null,
        pub fn deinit(self: *ForkSnapshot) void {
            self.history.deinit();
        }
    };
    /// Owned, immutable completed checkpoint. Later output or source deletion
    /// cannot change the content awaiting an explicit UI confirmation.
    pub fn pinFork(self: *Store, source: identity.ConversationId) !ForkSnapshot {
        const record = self.find(source) orelse return error.ConversationNotFound;
        if (record.last_turn == 0 or !record.recoverable or record.history.failure != null) return error.NoStableCheckpoint;
        var history = try wire.History.copy(self.allocator, record.history.messages, "");
        errdefer history.deinit();
        const presentation = if (record.presentation) |bytes| try history.arena.?.allocator().dupe(u8, bytes) else null;
        return .{ .source = source, .revision = record.content_revision, .turn = record.last_turn, .origin = record.initial_origin, .history = history, .presentation = presentation };
    }
    pub fn publishFork(self: *Store, pinned: *const ForkSnapshot, agent_id: ?identity.AgentId) !identity.ConversationId {
        const target = if (agent_id) |id| self.agent(id) orelse return error.AgentNotFound else null;
        if (target) |agent_value| if (agent_value.current != null or agent_value.busy or agent_value.closing) return error.BindingConflict;
        if (!pinned.source.valid() or pinned.revision == 0 or pinned.turn == 0 or pinned.history.failure != null) return error.NoStableCheckpoint;
        var snapshot = try wire.History.copy(self.allocator, pinned.history.messages, "");
        errdefer snapshot.deinit();
        const record = try self.allocateRecord();
        errdefer record.deinit(self.allocator);
        if (target != null) record.revision = try identity.advance(record.revision);
        if (pinned.presentation) |bytes| record.presentation = try self.allocator.dupe(u8, bytes);
        try self.save(.{ .kind = if (target != null) .fork_bound else .fork, .conversation = record.id, .revision = record.revision, .parent = pinned.source, .source_revision = pinned.revision, .turn = pinned.turn, .messages = snapshot.messages, .presentation = record.presentation, .agent = if (target) |agent_value| agent_value.id else null, .owner = if (target) |agent_value| agent_value.owner else null, .environment = if (target) |agent_value| agent_value.environment else 1, .initial_origin = pinned.origin });
        record.history = snapshot;
        record.initial_origin = pinned.origin;
        record.parent = pinned.source;
        record.source_revision = pinned.revision;
        record.fork_turn = pinned.turn;
        record.last_turn = pinned.turn;
        record.historical_messages = record.history.messages.len;
        self.records.appendAssumeCapacity(record);
        if (target) |agent_value| {
            record.binding = .{ .agent = agent_value.id, .owner = agent_value.owner };
            agent_value.current = record.id;
            record.inbox.changeFence(try self.fence(record.id));
        }
        return record.id;
    }
    pub fn fork(self: *Store, source: identity.ConversationId, expected_content: u64) !identity.ConversationId {
        return self.forkImpl(source, expected_content, null, null);
    }
    pub fn forkAndUse(self: *Store, source: identity.ConversationId, expected_content: u64, agent_id: identity.AgentId) !input.Fence {
        const target = self.agent(agent_id) orelse return error.AgentNotFound;
        if (target.current != null or target.busy or target.closing) return error.BindingConflict;
        const id = try self.forkImpl(source, expected_content, target, null);
        return self.fence(id);
    }
    const Checkpoint = struct { turn: u64, messages: []const provider.Message };
    /// The trusted host supplies its pinned, completed Turn snapshot. A model
    /// tool cannot supply arbitrary transcripts through this internal API.
    pub fn forkCheckpointAndUse(self: *Store, source: identity.ConversationId, expected_content: u64, turn: u64, messages: []const provider.Message, agent_id: identity.AgentId) !input.Fence {
        const target = self.agent(agent_id) orelse return error.AgentNotFound;
        if (target.current != null or target.busy or target.closing) return error.BindingConflict;
        return self.fence(try self.forkImpl(source, expected_content, target, .{ .turn = turn, .messages = messages }));
    }
    fn forkImpl(self: *Store, source: identity.ConversationId, expected_content: u64, target: ?*Agent, checkpoint_value: ?Checkpoint) !identity.ConversationId {
        const parent = self.find(source) orelse return error.ConversationNotFound;
        if (parent.content_revision != expected_content) return error.CheckpointChanged;
        if (parent.last_turn == 0 or !parent.recoverable or parent.history.failure != null) return error.NoStableCheckpoint;
        const selected_checkpoint = checkpoint_value orelse Checkpoint{ .turn = parent.last_turn, .messages = parent.history.messages };
        if (selected_checkpoint.turn == 0 or selected_checkpoint.turn > parent.last_turn) return error.NoStableCheckpoint;
        var snapshot = try wire.History.copy(self.allocator, selected_checkpoint.messages, "");
        errdefer snapshot.deinit();
        const record = try self.allocateRecord();
        errdefer record.deinit(self.allocator);
        if (target != null) record.revision = try identity.advance(record.revision);
        if (parent.presentation) |bytes| record.presentation = try self.allocator.dupe(u8, bytes);
        try self.save(.{ .kind = if (target != null) .fork_bound else .fork, .conversation = record.id, .revision = record.revision, .parent = parent.id, .source_revision = parent.content_revision, .turn = selected_checkpoint.turn, .messages = snapshot.messages, .presentation = record.presentation, .agent = if (target) |value| value.id else null, .owner = if (target) |value| value.owner else null, .environment = if (target) |value| value.environment else 1, .initial_origin = parent.initial_origin });
        record.history = snapshot;
        record.initial_origin = parent.initial_origin;
        record.parent = parent.id;
        record.source_revision = parent.content_revision;
        record.fork_turn = selected_checkpoint.turn;
        record.last_turn = selected_checkpoint.turn;
        record.historical_messages = record.history.messages.len;
        self.records.appendAssumeCapacity(record);
        if (target) |value| {
            record.binding = .{ .agent = value.id, .owner = value.owner };
            value.current = record.id;
            record.inbox.changeFence(try self.fence(record.id));
        }
        return record.id;
    }
    pub fn environmentChanged(self: *Store, agent_id: identity.AgentId) !input.Fence {
        const target = self.agent(agent_id) orelse return error.AgentNotFound;
        const id = target.current orelse return error.ConversationUnbound;
        const record = self.find(id).?;
        if (record.ending != null) return error.LifecycleBusy;
        const next = try identity.advance(target.environment);
        record.inbox.pauseAll(.environment);
        self.save(.{ .kind = .environment, .conversation = id, .agent = target.id, .owner = target.owner, .revision = record.revision, .environment = next }) catch |err| {
            record.inbox.lock();
            record.inbox.admission = false;
            record.inbox.unlock();
            return err;
        };
        target.environment = next;
        record.historical_messages = record.history.messages.len;
        const ticket = try self.fence(id);
        record.inbox.changeFence(ticket);
        return ticket;
    }
    pub fn handoff(self: *Store, expected: input.Fence, owner: scope.Owner) !input.Fence {
        const record = try self.validate(expected);
        if (record.ending != null) return error.LifecycleBusy;
        for (self.agents.items) |other| if (!other.id.eql(expected.agent) and other.owner.eql(owner) and !other.closing) return error.BindingConflict;
        if (record.binding.?.owner != .session or owner != .group or owner.group == 0) return error.InvalidBindingHandoff;
        const revision = try identity.advance(record.revision);
        const target = self.agent(expected.agent).?;
        const environment = try identity.advance(target.environment);
        try self.save(.{ .kind = .handoff, .conversation = record.id, .agent = target.id, .owner = owner, .revision = revision, .environment = environment });
        record.revision = revision;
        record.binding.?.owner = owner;
        target.owner = owner;
        target.environment = environment;
        record.historical_messages = record.history.messages.len;
        const ticket = try self.fence(record.id);
        record.inbox.changeFence(ticket);
        return ticket;
    }
    pub fn remove(self: *Store, id: identity.ConversationId) !void {
        for (self.records.items, 0..) |record, index| if (record.id.eql(id)) {
            if (record.binding != null or record.ending != null) return error.BindingConflict;
            record.inbox.lock();
            for (record.inbox.entries.items) |entry| if (entry.receipt.delivery == .outcome_unknown) {
                record.inbox.unlock();
                return error.SubmissionUnconfirmed;
            };
            record.inbox.unlock();
            try self.save(.{ .kind = .remove, .conversation = id, .revision = record.revision });
            record.deinit(self.allocator);
            _ = self.records.orderedRemove(index);
            return;
        };
        return error.ConversationNotFound;
    }
    /// Replay under the journal's exclusive writer lock, before attaching any
    /// worker. A saved binding is metadata, never recovered execution power.
    pub fn replay(self: *Store, event: Event) !void {
        if (!event.conversation.valid() or event.revision == 0) return error.InvalidSessionJournal;
        var record = self.find(event.conversation);
        if (event.kind == .create or event.kind == .fork or event.kind == .fork_bound or event.kind == .migrate_bound or event.kind == .migrate_closed) {
            if (record != null) return error.InvalidSessionJournal;
            const fresh = try self.allocateRecord();
            errdefer fresh.deinit(self.allocator);
            fresh.id = event.conversation;
            fresh.initial_origin = event.initial_origin orelse if (event.kind == .create) event.owner else null;
            fresh.inbox.fence.conversation = fresh.id;
            fresh.parent = event.parent;
            fresh.source_revision = event.source_revision;
            fresh.fork_turn = if (event.parent != null) event.turn else null;
            fresh.last_turn = event.turn;
            if (event.draft) |text| fresh.draft = try self.allocator.dupe(u8, text);
            if (event.presentation) |bytes| fresh.presentation = try self.allocator.dupe(u8, bytes);
            fresh.history = try wire.History.copy(self.allocator, if (event.initial_input != null) &.{} else event.messages, "");
            self.records.appendAssumeCapacity(fresh);
            record = fresh;
        }
        const value = record orelse return error.InvalidSessionJournal;
        switch (event.kind) {
            .create, .bind, .handoff, .fork_bound, .migrate_bound => {
                const aid = event.agent orelse return error.InvalidSessionJournal;
                const owner = event.owner orelse return error.InvalidSessionJournal;
                var target = self.agent(aid);
                if (target == null) {
                    for (self.agents.items) |other| if (other.owner.eql(owner) and !other.id.eql(aid) and other.current != null) return error.InvalidSessionJournal;
                    try self.agents.ensureUnusedCapacity(self.allocator, 1);
                    const created = try self.allocator.create(Agent);
                    // Process-local business objects are not proven alive by
                    // their saved numeric IDs. Reattach creates a fresh Agent.
                    created.* = .{ .id = aid, .owner = owner, .environment = event.environment, .closing = true };
                    self.agents.appendAssumeCapacity(created);
                    target = created;
                }
                if (target.?.current) |prior| if (!prior.eql(value.id)) return error.InvalidSessionJournal;
                if (value.binding) |prior| if (!prior.agent.eql(aid)) return error.InvalidSessionJournal;
                target.?.current = value.id;
                target.?.owner = owner;
                target.?.environment = event.environment;
                value.binding = .{ .agent = aid, .owner = owner };
                value.revision = event.revision;
                value.needs_recovery = true;
                value.historical_messages = value.history.messages.len;
            },
            .fork => {
                value.revision = event.revision;
                value.historical_messages = value.history.messages.len;
            },
            .migrate_closed => {
                value.revision = event.revision;
                value.closed_revision = event.revision - 1;
                value.historical_messages = value.history.messages.len;
            },
            .end_requested => {
                const bound = value.binding orelse return error.InvalidSessionJournal;
                value.ending = .{ .operation = event.operation orelse return error.InvalidSessionJournal, .fence = .{ .agent = bound.agent, .conversation = value.id, .binding = event.revision, .environment = event.environment } };
            },
            .unbind => {
                const bound = value.binding orelse return error.InvalidSessionJournal;
                self.agent(bound.agent).?.current = null;
                value.closed_revision = value.revision;
                value.revision = event.revision;
                value.last_end = value.ending;
                value.ending = null;
                value.binding = null;
                value.needs_recovery = false;
            },
            .environment => {
                const bound = value.binding orelse return error.InvalidSessionJournal;
                self.agent(bound.agent).?.environment = event.environment;
            },
            .checkpoint => {
                var snapshot = try wire.History.copy(self.allocator, event.messages, "");
                errdefer snapshot.deinit();
                value.history.deinit();
                value.history = snapshot;
                value.recovery_history.deinit();
                value.last_turn = event.turn;
                value.recoverable = event.recoverable;
                value.content_revision = try identity.advance(value.content_revision);
            },
            .presentation => {
                const bytes = try self.allocator.dupe(u8, event.presentation orelse return error.InvalidSessionJournal);
                if (value.presentation) |prior| self.allocator.free(prior);
                value.presentation = bytes;
                value.history.usage = if (event.context_usage) |stored| stored.restore(value.history.messages) else null;
            },
            .draft => {
                const text = try self.allocator.dupe(u8, event.draft orelse "");
                if (value.draft) |old| self.allocator.free(old);
                value.draft = text;
                value.draft_revision = try identity.advance(value.draft_revision);
            },
            .remove => {
                if (value.binding != null) return error.InvalidSessionJournal;
                for (self.records.items, 0..) |entry, i| if (entry == value) {
                    value.deinit(self.allocator);
                    _ = self.records.orderedRemove(i);
                    return;
                };
            },
        }
        if (event.initial_input) |receipt| {
            if (event.kind != .create or !receipt.fence.conversation.eql(event.conversation) or receipt.fence.binding != event.revision or receipt.delivery != .queued) return error.InvalidSessionJournal;
            try self.replayInput(receipt, event.messages);
        }
        value.inbox.admission = false;
    }
    pub fn replayInput(self: *Store, receipt: input.Receipt, messages: []const provider.Message) !void {
        const record = self.find(receipt.fence.conversation) orelse return error.InvalidSessionJournal;
        if (messages.len != 1 or messages[0].role != .user or !receipt.id.valid() or !receipt.fence.agent.valid() or receipt.sequence == 0 or receipt.revision == 0 or receipt.fence.binding == 0 or receipt.fence.environment == 0) return error.InvalidSessionJournal;
        var payload = try wire.History.copy(self.allocator, messages, "");
        errdefer payload.deinit();
        var entry = record.inbox.findLocked(receipt.id);
        if (entry) |prior| {
            if (!prior.receipt.fence.eql(receipt.fence) or prior.receipt.sequence != receipt.sequence or prior.receipt.mode != receipt.mode or prior.receipt.revision > receipt.revision or prior.receipt.attempt > receipt.attempt or (input.terminal(prior.receipt.delivery) and prior.receipt.delivery != receipt.delivery)) return error.InvalidSessionJournal;
        }
        if (entry == null) {
            if (record.inbox.entries.items.len >= wire.History.max_messages) return error.InputQueueFull;
            try record.inbox.entries.ensureUnusedCapacity(self.allocator, 1);
            const created = try self.allocator.create(input.Entry);
            created.* = .{ .receipt = receipt, .payload = .{}, .text_bytes = messages[0].content.len };
            record.inbox.entries.appendAssumeCapacity(created);
            entry = created;
        }
        entry.?.payload.deinit();
        entry.?.payload = payload;
        entry.?.receipt = receipt;
        entry.?.receipt.archived = true;
        entry.?.receipt.pause = .stop;
        record.inbox.next_sequence = @max(record.inbox.next_sequence, try identity.advance(receipt.sequence));
        record.inbox.admission = false;
    }
    pub fn recoverOrphan(self: *Store, id: identity.ConversationId, released: Released) !void {
        const record = self.find(id) orelse return error.ConversationNotFound;
        if (!record.needs_recovery or record.binding == null) return error.RecoveryNotRequired;
        if (!released.worker_joined or !released.dispatch_closed or !released.local_released or !released.transcript_saved) return error.ResourceCleanupPending;
        const expected = try self.fence(id);
        const operation = if (record.ending) |prior| prior.operation else identity.HostOperationId.generate();
        try self.save(.{ .kind = .end_requested, .conversation = id, .agent = expected.agent, .revision = expected.binding, .environment = expected.environment, .operation = operation });
        record.ending = .{ .operation = operation, .fence = expected };
        record.needs_recovery = false;
        errdefer record.needs_recovery = true;
        if (record.recovery_history.messages.len != 0) try self.checkpoint(expected, record.recovery_turn, record.recovery_history.messages, true);
        self.commitEnd(expected, operation, released) catch |err| {
            record.needs_recovery = true;
            return err;
        };
    }
};
