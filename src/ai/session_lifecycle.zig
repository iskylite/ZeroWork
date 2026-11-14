//! Controller-owned authority for attached AI conversations. Stable allocations
//! survive list growth. UI selection is deliberately not part of this API.
const std = @import("std");
const identity = @import("../host/identity.zig");
const scope = @import("tool_scope.zig");
const wire = @import("wire_history.zig");
const provider = @import("provider.zig");
const context_usage = @import("context_usage.zig");
const display = @import("conversation_presentation.zig");
const local_workspace = @import("../host/local_workspace.zig");
const ConversationModel = @import("provider_config.zig").ConversationModel;
pub const input = @import("session_input.zig");
pub const child = @import("child_agent.zig");
pub const Role = enum { attached, child };
pub const Binding = struct { agent: identity.AgentId, owner: scope.Owner };
pub const End = struct { operation: identity.HostOperationId, fence: input.Fence, failed: bool = false };
pub const Released = struct { worker_joined: bool, dispatch_closed: bool, local_released: bool, transcript_saved: bool };
pub const WorkspaceChange = struct {
    before_revision: u64,
    reason: enum { set, changed, removed, unavailable, available },
};
pub const WorkspaceSource = struct {
    conversation: identity.ConversationId,
    snapshot: local_workspace.Snapshot,
};
pub const Event = struct {
    kind: enum { create, bind, end_requested, unbind, fork, fork_bound, handoff, environment, checkpoint, presentation, draft, remove, migrate_bound, migrate_closed, child_create, child_bind, remove_family, task_fact, child_launch, child_config, workspace_update, workspace_ack, conversation_model },
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
    child_info: ?child.Info = null,
    child_settings: ?child.Settings = null,
    parent_binding: ?input.Fence = null,
    targets: ?[]const identity.SessionHandle = null,
    children: ?[]const identity.ConversationId = null,
    task_fact: ?@import("task_budget.zig").Fact = null,
    initial_text: ?[]const u8 = null,
    workspace: ?local_workspace.Snapshot = null,
    workspace_source: ?WorkspaceSource = null,
    workspace_change: ?WorkspaceChange = null,
    workspace_ack_revision: ?u64 = null,
    conversation_model: ?ConversationModel = null,
};
pub const Persistence = struct {
    context: *anyopaque,
    write: *const fn (*anyopaque, Event) anyerror!void,
    /// Optional durable worker path; message bytes stay pinned until release.
    checkpoint: ?*const fn (*anyopaque, Event) anyerror!Write = null,
    try_draft: ?*const fn (*anyopaque, Event) anyerror!void = null,
    pub const Write = struct {
        context: *anyopaque,
        ready: *const fn (*anyopaque) bool,
        finish: *const fn (*anyopaque) anyerror!void,
        release: *const fn (*anyopaque) void,
    };
};
pub const Record = struct {
    id: identity.ConversationId,
    initial_origin: ?scope.Owner = null,
    binding: ?Binding = null,
    revision: u64 = 1,
    closed_revision: ?u64 = null,
    content_revision: u64 = 1,
    draft_revision: u64 = 1,
    workspace: local_workspace.Snapshot = .{},
    workspace_source: ?WorkspaceSource = null,
    workspace_change: ?WorkspaceChange = null,
    workspace_ack_revision: u64 = 1,
    history: wire.History = .{},
    presentation: ?[]u8 = null,
    presentation_version: ?display.Version = null,
    pending_presentation: ?*PresentationWrite = null,
    presentation_failure: ?anyerror = null,
    conversation_model: ?ConversationModel = null,
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
    resumed_history: ?struct { through_turn: u64, user_messages: usize } = null,
    needs_recovery: bool = false,
    /// Controller-only gate until the final task fact is durably committed.
    task_pending: bool = false,
    /// Main-thread intent closes dispatch while children release their workers.
    /// Never replay an unfinished UI transition after a restart.
    transition: ?struct { fence: input.Fence, operation: identity.HostOperationId } = null,
    child: ?child.Owned = null,
    child_settings: ?child.SettingsOwned = null,
    child_settings_revision: u64 = 1,
    inbox: input.Inbox,
    fn markResumedHistory(self: *Record) void {
        var user_messages: usize = 0;
        for (self.history.messages) |message| {
            if (message.role == .user and message.origin != .host_context_notice and message.content.len != 0) user_messages += 1;
        }
        self.resumed_history = if (user_messages == 0 and self.last_turn == 0) null else .{ .through_turn = self.last_turn, .user_messages = user_messages };
    }
    fn deinit(self: *Record, a: std.mem.Allocator) void {
        if (self.pending_presentation) |job| job.destroy(a);
        self.workspace.deinit(a);
        if (self.workspace_source) |*source| source.snapshot.deinit(a);
        if (self.child_settings) |*settings| settings.deinit();
        if (self.child) |*owned| owned.deinit();
        self.history.deinit();
        if (self.presentation) |bytes| a.free(bytes);
        if (self.conversation_model) |model| model.deinit(a);
        self.recovery_history.deinit();
        if (self.draft) |text| a.free(text);
        self.inbox.deinit();
        a.destroy(self);
    }
};
pub const Agent = struct {
    id: identity.AgentId,
    owner: scope.Owner,
    role: Role = .attached,
    parent_binding: ?input.Fence = null,
    targets: []const identity.SessionHandle = &.{},
    current: ?identity.ConversationId = null,
    environment: u64 = 1,
    busy: bool = false,
    closing: bool = false,
};

const PresentationWrite = struct {
    allocator: std.mem.Allocator,
    persistence: ?Persistence,
    event: Event,
    version: display.Version,
    snapshot: display.Capture,
    history: wire.History,
    history_revision: u64,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    bytes: ?[]u8 = null,

    fn run(self: *PresentationWrite) void {
        self.write() catch |err| {
            self.failure = err;
        };
        self.snapshot.deinit(self.allocator);
        self.history.deinit();
        self.done.store(true, .release);
    }
    fn write(self: *PresentationWrite) !void {
        self.bytes = try self.snapshot.encode(self.allocator);
        self.event.presentation = self.bytes;
        self.event.context_usage = context_usage.Stored.capture(self.history.messages, self.version.usage);
        if (self.persistence) |p| try p.write(p.context, self.event);
    }
    fn destroy(self: *PresentationWrite, a: std.mem.Allocator) void {
        if (self.thread) |thread| thread.join();
        if (self.bytes) |bytes| a.free(bytes);
        a.destroy(self);
    }
};
pub const Store = struct {
    allocator: std.mem.Allocator,
    agents: std.ArrayList(*Agent) = .empty,
    records: std.ArrayList(*Record) = .empty,
    persist: ?Persistence = null,
    input_persist: ?input.Persist = null,
    workspace_io: ?std.Io = null,
    share_storage: ?struct { io: std.Io, dir: std.Io.Dir } = null,
    budget: input.Budget = .{},
    task_facts: std.ArrayList(@import("task_budget.zig").Owned) = .empty,

    pub fn init(a: std.mem.Allocator) Store {
        return .{ .allocator = a };
    }
    pub fn deinit(self: *Store) void {
        for (self.task_facts.items) |*fact| fact.deinit();
        self.task_facts.deinit(self.allocator);
        for (self.records.items) |record| record.deinit(self.allocator);
        for (self.agents.items) |value| {
            self.allocator.free(value.targets);
            self.allocator.destroy(value);
        }
        self.records.deinit(self.allocator);
        self.agents.deinit(self.allocator);
    }
    pub fn recoverTasks(self: *Store) !void {
        for (0..self.task_facts.items.len) |i| {
            var fact = self.task_facts.items[i].fact;
            if (@import("task_budget.zig").terminal(fact.status)) continue;
            var latest = fact;
            for (self.task_facts.items) |other| if (other.fact.root.eql(fact.root) and other.fact.sequence > latest.sequence) {
                latest = other.fact;
            };
            fact.sequence = try identity.advance(latest.sequence);
            fact.counters = latest.counters;
            if (fact.counters.pending_requests != 0) fact.counters.usage_complete = false;
            fact.status = .interrupted;
            fact.event_sequence = fact.sequence;
            fact.user_waits = 0;
            fact.summary = "Process ended; execution was not restored. Pending effects require their original evidence.";
            try persistTask(self, fact);
            var owned = try @import("task_budget.zig").Owned.init(self.allocator, fact);
            errdefer owned.deinit();
            self.task_facts.items[i].deinit();
            self.task_facts.items[i] = owned;
        }
    }
    pub fn persistTask(raw: *anyopaque, fact: @import("task_budget.zig").Fact) !void {
        const self: *Store = @ptrCast(@alignCast(raw));
        try self.save(.{ .kind = .task_fact, .conversation = fact.conversation, .revision = fact.sequence, .task_fact = fact });
    }
    fn save(self: *Store, event: Event) !void {
        if (self.persist) |p| try p.write(p.context, event);
    }
    fn saveDraft(self: *Store, event: Event) !void {
        if (self.persist) |p| try (p.try_draft orelse p.write)(p.context, event);
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
        for (self.agents.items) |value| if (value.role == .attached and value.owner.eql(owner)) {
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
    pub fn setWorkspace(self: *Store, io: std.Io, expected: input.Fence, expected_revision: u64, directory: ?[]const u8) !bool {
        const record = try self.validateExecution(expected);
        if (record.workspace.revision != expected_revision) return error.WorkspaceChanged;
        var next = if (directory) |path| try local_workspace.inspect(self.allocator, io, path) else local_workspace.Snapshot{};
        defer next.deinit(self.allocator);
        return self.applyWorkspaceSelection(io, record, expected, &next);
    }
    /// Accept a directory inspected by the host before first-conversation
    /// migration. A saved selection takes ownership from the caller.
    pub fn setInspectedWorkspace(self: *Store, io: std.Io, expected: input.Fence, expected_revision: u64, next: *local_workspace.Snapshot) !bool {
        const record = try self.validateExecution(expected);
        if (record.workspace.revision != expected_revision) return error.WorkspaceChanged;
        try next.validate();
        if (next.availability == .unavailable) return error.InvalidWorkspaceSnapshot;
        return self.applyWorkspaceSelection(io, record, expected, next);
    }
    fn applyWorkspaceSelection(self: *Store, io: std.Io, record: *Record, expected: input.Fence, next: *local_workspace.Snapshot) !bool {
        self.workspace_io = io;
        if (record.workspace.sameTarget(next.*)) {
            if (record.workspace.sameState(next.*)) return false;
            var current = try local_workspace.recheck(self.allocator, io, record.workspace);
            defer current.deinit(self.allocator);
            // A different spelling can be equivalent, provided the original
            // choice still resolves to the same usable directory.
            if (record.workspace.sameState(current)) return false;
        }
        const before_revision = record.workspace.revision;
        next.revision = try identity.advance(before_revision);
        const reason: @FieldType(WorkspaceChange, "reason") = if (next.directory == null) .removed else if (record.workspace.directory == null) .set else .changed;
        try self.saveWorkspace(record, expected, next, .{ .before_revision = before_revision, .reason = reason });
        return true;
    }
    pub fn revalidateWorkspace(self: *Store, io: std.Io, expected: input.Fence) !bool {
        const record = try self.validateExecution(expected);
        self.workspace_io = io;
        return self.revalidateBoundWorkspace(record, expected);
    }
    fn revalidateBoundWorkspace(self: *Store, record: *Record, expected: input.Fence) !bool {
        var update = (try self.prepareWorkspaceRecheck(record.workspace)) orelse return false;
        defer update.snapshot.deinit(self.allocator);
        try self.saveWorkspace(record, expected, &update.snapshot, update.change);
        return true;
    }
    /// Replay only rechecks bound conversations. Closed history continues to
    /// display its saved preference until a user binds it again.
    pub fn revalidateRecoveredWorkspaces(self: *Store, io: std.Io) !void {
        self.workspace_io = io;
        for (self.records.items) |record| {
            if (!record.needs_recovery or record.binding == null) continue;
            _ = try self.revalidateBoundWorkspace(record, try self.fence(record.id));
        }
    }
    const WorkspaceUpdate = struct { snapshot: local_workspace.Snapshot, change: WorkspaceChange };
    fn prepareWorkspaceRecheck(self: *Store, prior: local_workspace.Snapshot) !?WorkspaceUpdate {
        if (prior.directory == null) return null;
        const io = self.workspace_io orelse return error.WorkspaceIoUnavailable;
        var checked = try local_workspace.recheck(self.allocator, io, prior);
        errdefer checked.deinit(self.allocator);
        if (prior.sameState(checked)) {
            checked.deinit(self.allocator);
            return null;
        }
        checked.revision = try identity.advance(prior.revision);
        const reason: @FieldType(WorkspaceChange, "reason") = if (checked.availability == .unavailable) .unavailable else if (prior.availability == .unavailable) .available else .changed;
        return .{ .snapshot = checked, .change = .{ .before_revision = prior.revision, .reason = reason } };
    }
    fn saveWorkspace(self: *Store, record: *Record, fence_value: input.Fence, next: *local_workspace.Snapshot, change: WorkspaceChange) !void {
        try record.inbox.beginWorkspaceChange();
        defer record.inbox.endWorkspaceChange();
        try self.save(.{
            .kind = .workspace_update,
            .conversation = record.id,
            .agent = fence_value.agent,
            .revision = fence_value.binding,
            .environment = fence_value.environment,
            .workspace = next.*,
            .workspace_change = change,
        });
        self.publishWorkspace(record, next, change);
    }
    fn publishWorkspace(self: *Store, record: *Record, next: *local_workspace.Snapshot, change: ?WorkspaceChange) void {
        record.workspace.deinit(self.allocator);
        record.workspace = next.*;
        next.* = .{};
        record.workspace_change = change;
        record.inbox.setWorkspaceRevision(record.workspace.revision);
    }
    pub fn ackWorkspace(self: *Store, expected: input.Fence, revision: u64) !bool {
        const record = try self.validate(expected);
        if (revision > record.workspace.revision or revision == 0) return error.WorkspaceChanged;
        if (revision <= record.workspace_ack_revision) return false;
        try self.save(.{ .kind = .workspace_ack, .conversation = record.id, .agent = expected.agent, .revision = expected.binding, .environment = expected.environment, .workspace_ack_revision = revision });
        record.workspace_ack_revision = revision;
        return true;
    }
    fn inheritWorkspace(self: *Store, record: *Record, origin: WorkspaceSource) !void {
        var checked = if (origin.snapshot.directory == null) local_workspace.Snapshot{} else try local_workspace.recheck(self.allocator, self.workspace_io orelse return error.WorkspaceIoUnavailable, origin.snapshot);
        errdefer checked.deinit(self.allocator);
        checked.revision = 1;
        record.workspace_source = .{ .conversation = origin.conversation, .snapshot = try origin.snapshot.clone(self.allocator) };
        self.publishWorkspace(record, &checked, null);
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
        if (target.role != .attached) return error.ChildRequiresParent;
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
        if (target.role != .attached) return error.ChildRequiresParent;
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
        if (self.hasBoundChildren(record.id)) return error.ChildSettlementRequired;
        const revision = try identity.advance(record.revision);
        try self.save(.{ .kind = .unbind, .conversation = record.id, .revision = revision, .operation = operation, .turn = record.last_turn, .messages = record.history.messages, .draft = record.draft });
        record.revision = revision;
        record.closed_revision = expected.binding;
        record.binding = null;
        record.last_end = pending;
        record.ending = null;
        record.transition = null;
        target.current = null;
        self.allocator.free(target.targets);
        target.targets = &.{};
        target.parent_binding = null;
        record.inbox.archive();
    }
    pub fn resumeConversation(self: *Store, id: identity.ConversationId, agent_id: identity.AgentId, expected_revision: u64) !input.Fence {
        const record = self.find(id) orelse return error.ConversationNotFound;
        const target = self.agent(agent_id) orelse return error.AgentNotFound;
        if (record.child != null or target.role != .attached) return error.ChildRequiresParent;
        if (record.task_pending or record.binding != null or target.current != null or target.busy or target.closing) return error.BindingConflict;
        if (record.revision != expected_revision or record.ending != null) return error.BindingChanged;
        if (!record.recoverable or record.history.failure != null) return error.ConversationNotRecoverable;
        // A fresh never-used fork is also eligible for first binding.
        if (record.closed_revision == null and record.parent == null) return error.MissingEndReceipt;
        const revision = try identity.advance(record.revision);
        var update = try self.prepareWorkspaceRecheck(record.workspace);
        defer if (update) |*pending| pending.snapshot.deinit(self.allocator);
        try self.save(.{ .kind = .bind, .conversation = id, .agent = target.id, .owner = target.owner, .revision = revision, .environment = target.environment, .workspace = if (update) |pending| pending.snapshot else null, .workspace_change = if (update) |pending| pending.change else null });
        if (update) |*pending| self.publishWorkspace(record, &pending.snapshot, pending.change);
        record.binding = .{ .agent = target.id, .owner = target.owner };
        record.revision = revision;
        target.current = id;
        record.historical_messages = record.history.messages.len;
        record.markResumedHistory();
        const ticket = try self.fence(id);
        record.inbox.changeFence(ticket);
        return ticket;
    }
    pub fn setChildDraft(self: *Store, conversation: identity.ConversationId, revision: u64, text: []const u8) !u64 {
        const record = self.find(conversation) orelse return error.ConversationNotFound;
        if (record.child == null or record.draft_revision != revision or !std.unicode.utf8ValidateSlice(text)) return error.StaleDraft;
        const next = try identity.advance(revision);
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        try self.saveDraft(.{ .kind = .draft, .conversation = record.id, .revision = record.revision, .draft = text });
        if (record.draft) |old| self.allocator.free(old);
        record.draft = owned;
        record.draft_revision = next;
        return next;
    }
    pub fn setDraft(self: *Store, expected: input.Fence, revision: u64, text: []const u8) !u64 {
        const record = try self.validate(expected);
        if (record.draft_revision != revision or !std.unicode.utf8ValidateSlice(text)) return error.StaleDraft;
        const next = try identity.advance(revision);
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        try self.saveDraft(.{ .kind = .draft, .conversation = record.id, .agent = expected.agent, .revision = record.revision, .draft = text });
        if (record.draft) |old| self.allocator.free(old);
        record.draft = owned;
        record.draft_revision = next;
        return next;
    }
    /// Only the joined runtime commits canonical history. Live readers pin a
    /// separate immutable snapshot, never pointers into its growing tool loop.
    pub fn checkpoint(self: *Store, expected: input.Fence, turn: u64, messages: []const provider.Message, recoverable: bool) !void {
        const record = try self.validate(expected);
        _ = try identity.advance(record.content_revision);
        var snapshot = try wire.History.copy(self.allocator, messages, "");
        errdefer snapshot.deinit();
        try self.save(.{ .kind = .checkpoint, .conversation = record.id, .agent = expected.agent, .revision = record.revision, .turn = turn, .messages = snapshot.messages, .recoverable = recoverable });
        try self.publishDurableCheckpoint(expected, turn, &snapshot, recoverable);
    }
    /// UI-thread publication only, after a successful durable write acknowledgement.
    /// Moving the already-owned worker snapshot avoids another full history copy.
    pub fn publishDurableCheckpoint(self: *Store, expected: input.Fence, turn: u64, snapshot: *wire.History, recoverable: bool) !void {
        const record = try self.validate(expected);
        const next = try identity.advance(record.content_revision);
        record.history.deinit();
        record.history = snapshot.*;
        snapshot.* = .{};
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

    pub fn saveConversationModel(self: *Store, id: identity.ConversationId, model: ConversationModel) !void {
        const record = self.find(id) orelse return error.ConversationNotFound;
        if (record.conversation_model) |prior| if (prior.eql(model)) return;
        const copy = try model.clone(self.allocator);
        errdefer copy.deinit(self.allocator);
        try self.save(.{ .kind = .conversation_model, .conversation = id, .revision = record.revision, .conversation_model = model });
        if (record.conversation_model) |prior| prior.deinit(self.allocator);
        record.conversation_model = copy;
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
        record.presentation_version = null;
        record.history.usage = valid;
    }

    pub const PresentationStatus = enum { saved, queued, busy };
    pub fn queuePresentation(self: *Store, record: *Record, version: display.Version, history: []const @import("assistant_store.zig").Message, current: ?@import("assistant_store.zig").Message, cards: []const @import("card.zig").Card) !PresentationStatus {
        try self.pollPresentation(record);
        if (record.pending_presentation) |job| return if (std.meta.eql(job.version, version)) .queued else .busy;
        if (std.meta.eql(record.presentation_version, @as(?display.Version, version))) return .saved;

        const a = self.allocator;
        const job = try a.create(PresentationWrite);
        errdefer a.destroy(job);
        job.* = .{
            .allocator = a,
            .persistence = self.persist,
            .event = .{ .kind = .presentation, .conversation = record.id, .revision = record.revision },
            .version = version,
            .snapshot = try display.Capture.init(a, history, current, cards),
            .history = record.history.retain(),
            .history_revision = record.history.revision,
        };
        errdefer job.snapshot.deinit(a);
        errdefer job.history.deinit();
        job.thread = try std.Thread.spawn(.{}, PresentationWrite.run, .{job});
        record.pending_presentation = job;
        return .queued;
    }

    pub fn pollPresentations(self: *Store) !void {
        var failure: ?anyerror = null;
        for (self.records.items) |record| self.pollPresentation(record) catch |err| {
            if (failure == null) failure = err;
        };
        if (failure) |err| return err;
    }

    /// Active saves must see their own failures so the runtime can retry them.
    pub fn collectPresentations(self: *Store) void {
        for (self.records.items) |record| self.finishPresentation(record) catch |err| {
            record.presentation_failure = err;
        };
    }

    fn pollPresentation(self: *Store, record: *Record) !void {
        if (record.presentation_failure) |err| {
            record.presentation_failure = null;
            return err;
        }
        try self.finishPresentation(record);
    }

    fn finishPresentation(self: *Store, record: *Record) !void {
        const job = record.pending_presentation orelse return;
        if (!job.done.load(.acquire)) return;
        record.pending_presentation = null;
        defer job.destroy(self.allocator);
        if (job.failure) |err| return err;
        if (record.presentation) |old| self.allocator.free(old);
        record.presentation = job.bytes;
        job.bytes = null;
        record.presentation_version = job.version;
        if (record.history.revision == job.history_revision) {
            record.history.usage = if (job.event.context_usage) |stored| stored.baseline else null;
        }
    }

    pub fn presentationPending(self: *const Store) bool {
        for (self.records.items) |record| if (record.pending_presentation != null) return true;
        return false;
    }
    pub const ForkSnapshot = struct {
        source: identity.ConversationId,
        revision: u64,
        turn: u64,
        origin: ?scope.Owner,
        history: wire.History,
        presentation: ?[]const u8 = null,
        workspace: local_workspace.Snapshot,
        workspace_allocator: std.mem.Allocator,

        pub fn deinit(self: *ForkSnapshot) void {
            self.workspace.deinit(self.workspace_allocator);
            self.history.deinit();
        }
    };
    /// Owned, immutable completed checkpoint. Later output or source deletion
    /// cannot change the content awaiting an explicit UI confirmation.
    pub fn pinFork(self: *Store, source: identity.ConversationId) !ForkSnapshot {
        const record = self.find(source) orelse return error.ConversationNotFound;
        try self.pollPresentation(record);
        if (record.pending_presentation != null) return error.ResourceCleanupPending;
        if (record.child != null) return error.ChildRequiresParent;
        if (record.last_turn == 0 or !record.recoverable or record.history.failure != null) return error.NoStableCheckpoint;
        var history = try wire.History.copy(self.allocator, record.history.messages, "");
        errdefer history.deinit();
        const presentation = if (record.presentation) |bytes| try history.arenaAllocator().dupe(u8, bytes) else null;
        const workspace = try record.workspace.clone(self.allocator);
        return .{ .source = source, .revision = record.content_revision, .turn = record.last_turn, .origin = record.initial_origin, .history = history, .presentation = presentation, .workspace = workspace, .workspace_allocator = self.allocator };
    }
    pub fn publishFork(self: *Store, pinned: *const ForkSnapshot, agent_id: ?identity.AgentId) !identity.ConversationId {
        const target = if (agent_id) |id| self.agent(id) orelse return error.AgentNotFound else null;
        if (target) |agent_value| if (agent_value.role != .attached) return error.ChildRequiresParent;
        if (self.find(pinned.source)) |source| if (source.child != null) return error.ChildRequiresParent;
        if (target) |agent_value| if (agent_value.current != null or agent_value.busy or agent_value.closing) return error.BindingConflict;
        if (!pinned.source.valid() or pinned.revision == 0 or pinned.turn == 0 or pinned.history.failure != null) return error.NoStableCheckpoint;
        var snapshot = try wire.History.copy(self.allocator, pinned.history.messages, "");
        errdefer snapshot.deinit();
        const record = try self.allocateRecord();
        errdefer record.deinit(self.allocator);
        if (target != null) {
            record.revision = try identity.advance(record.revision);
            try self.inheritWorkspace(record, .{ .conversation = pinned.source, .snapshot = pinned.workspace });
        }
        if (pinned.presentation) |bytes| record.presentation = try self.allocator.dupe(u8, bytes);
        try self.save(.{ .kind = if (target != null) .fork_bound else .fork, .conversation = record.id, .revision = record.revision, .parent = pinned.source, .source_revision = pinned.revision, .turn = pinned.turn, .messages = snapshot.messages, .presentation = record.presentation, .agent = if (target) |agent_value| agent_value.id else null, .owner = if (target) |agent_value| agent_value.owner else null, .environment = if (target) |agent_value| agent_value.environment else 1, .initial_origin = pinned.origin, .workspace = if (record.workspace_source != null) record.workspace else null, .workspace_source = record.workspace_source });
        record.history = snapshot;
        record.initial_origin = pinned.origin;
        record.parent = pinned.source;
        record.source_revision = pinned.revision;
        record.fork_turn = pinned.turn;
        record.last_turn = pinned.turn;
        record.historical_messages = record.history.messages.len;
        if (target != null) record.markResumedHistory();
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
        if (target.role != .attached) return error.ChildRequiresParent;
        if (target.current != null or target.busy or target.closing) return error.BindingConflict;
        const id = try self.forkImpl(source, expected_content, target, null);
        return self.fence(id);
    }
    const Checkpoint = struct { turn: u64, messages: []const provider.Message };
    /// The trusted host supplies its pinned, completed Turn snapshot. A model
    /// tool cannot supply arbitrary transcripts through this internal API.
    pub fn forkCheckpointAndUse(self: *Store, source: identity.ConversationId, expected_content: u64, turn: u64, messages: []const provider.Message, agent_id: identity.AgentId) !input.Fence {
        const target = self.agent(agent_id) orelse return error.AgentNotFound;
        if (target.role != .attached) return error.ChildRequiresParent;
        if (target.current != null or target.busy or target.closing) return error.BindingConflict;
        return self.fence(try self.forkImpl(source, expected_content, target, .{ .turn = turn, .messages = messages }));
    }
    fn forkImpl(self: *Store, source: identity.ConversationId, expected_content: u64, target: ?*Agent, checkpoint_value: ?Checkpoint) !identity.ConversationId {
        const parent = self.find(source) orelse return error.ConversationNotFound;
        if (parent.child != null) return error.ChildRequiresParent;
        if (parent.content_revision != expected_content) return error.CheckpointChanged;
        if (parent.last_turn == 0 or !parent.recoverable or parent.history.failure != null) return error.NoStableCheckpoint;
        const selected_checkpoint = checkpoint_value orelse Checkpoint{ .turn = parent.last_turn, .messages = parent.history.messages };
        if (selected_checkpoint.turn == 0 or selected_checkpoint.turn > parent.last_turn) return error.NoStableCheckpoint;
        var snapshot = try wire.History.copy(self.allocator, selected_checkpoint.messages, "");
        errdefer snapshot.deinit();
        const record = try self.allocateRecord();
        errdefer record.deinit(self.allocator);
        if (target != null) {
            record.revision = try identity.advance(record.revision);
            try self.inheritWorkspace(record, .{ .conversation = parent.id, .snapshot = parent.workspace });
        }
        if (parent.presentation) |bytes| record.presentation = try self.allocator.dupe(u8, bytes);
        try self.save(.{ .kind = if (target != null) .fork_bound else .fork, .conversation = record.id, .revision = record.revision, .parent = parent.id, .source_revision = parent.content_revision, .turn = selected_checkpoint.turn, .messages = snapshot.messages, .presentation = record.presentation, .agent = if (target) |value| value.id else null, .owner = if (target) |value| value.owner else null, .environment = if (target) |value| value.environment else 1, .initial_origin = parent.initial_origin, .workspace = if (record.workspace_source != null) record.workspace else null, .workspace_source = record.workspace_source });
        record.history = snapshot;
        record.initial_origin = parent.initial_origin;
        record.parent = parent.id;
        record.source_revision = parent.content_revision;
        record.fork_turn = selected_checkpoint.turn;
        record.last_turn = selected_checkpoint.turn;
        record.historical_messages = record.history.messages.len;
        if (target != null) record.markResumedHistory();
        self.records.appendAssumeCapacity(record);
        if (target) |value| {
            record.binding = .{ .agent = value.id, .owner = value.owner };
            value.current = record.id;
            record.inbox.changeFence(try self.fence(record.id));
        }
        return record.id;
    }
    pub fn environmentChanged(self: *Store, agent_id: identity.AgentId) !input.Fence {
        return self.changeEnvironment(agent_id, false);
    }
    /// A verified transition within the same retained SSH session may keep an
    /// operation-reference observer alive. Mutating plans still go stale.
    pub fn transportEnvironmentChanged(self: *Store, agent_id: identity.AgentId) !input.Fence {
        return self.changeEnvironment(agent_id, true);
    }
    fn changeEnvironment(self: *Store, agent_id: identity.AgentId, keep_operation_observation: bool) !input.Fence {
        const target = self.agent(agent_id) orelse return error.AgentNotFound;
        const id = target.current orelse return error.ConversationUnbound;
        const record = self.find(id).?;
        if (record.ending != null) return error.LifecycleBusy;
        const next = try identity.advance(target.environment);
        if (!keep_operation_observation) record.inbox.pauseAll(.environment);
        self.save(.{ .kind = .environment, .conversation = id, .agent = target.id, .owner = target.owner, .revision = record.revision, .environment = next }) catch |err| {
            record.inbox.lock();
            record.inbox.admission = false;
            record.inbox.unlock();
            return err;
        };
        target.environment = next;
        record.historical_messages = record.history.messages.len;
        const ticket = try self.fence(id);
        record.inbox.changeEnvironmentFence(ticket, keep_operation_observation);
        return ticket;
    }
    pub fn handoff(self: *Store, expected: input.Fence, owner: scope.Owner) !input.Fence {
        const record = try self.validate(expected);
        if (record.ending != null) return error.LifecycleBusy;
        if (record.child != null or self.hasBoundChildren(record.id)) return error.ChildSettlementRequired;
        for (self.agents.items) |other| if (other.role == .attached and !other.id.eql(expected.agent) and other.owner.eql(owner) and !other.closing) return error.BindingConflict;
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
    pub const Inherited = struct { source: child.Source, messages: []const provider.Message };
    /// Data-only registration. The execution-side caller freezes a legal prefix
    /// from the current Loop; this API never silently substitutes a checkpoint.
    pub fn registerChild(self: *Store, parent: input.Fence, draft: child.Draft, inherited: ?Inherited) !*Record {
        const parent_record = try self.validate(parent);
        if (parent_record.child != null) return error.ChildCannotDelegate;
        if (parent_record.ending != null) return error.ConversationEnding;
        if (parent_record.transition != null) return error.TransitionPending;
        const context_hash = try childContextHash(self.allocator, if (inherited) |snapshot| snapshot.messages else &.{});
        for (self.records.items) |existing| if (existing.child) |owned| {
            if (owned.info.owning_parent_conversation.eql(parent.conversation) and std.mem.eql(u8, owned.info.request_key, draft.request_key)) {
                const info = owned.info;
                if (!std.mem.eql(u8, &info.initial_context_hash, &context_hash) or !std.mem.eql(u8, info.name, draft.name) or info.context_mode != draft.context_mode or info.reusable != draft.reusable or info.effort != draft.effort or !@import("../config/settings_schema.zig").same(info.skill_ids, draft.skill_ids) or !@import("../config/settings_schema.zig").same(info.mcp_ids, draft.mcp_ids) or !sameModel(info.model, draft.model) or !std.meta.eql(info.context_source, if (inherited) |snapshot| @as(?child.Source, snapshot.source) else null)) return error.ChildRequestConflict;
                return existing;
            }
        };
        if ((draft.context_mode == .inherit) != (inherited != null)) return error.MissingInheritanceSnapshot;
        if (inherited) |snapshot| if (!snapshot.source.conversation.eql(parent.conversation) or snapshot.source.message_count != snapshot.messages.len) return error.InvalidInheritanceSnapshot;
        try self.agents.ensureUnusedCapacity(self.allocator, 1);
        const record = try self.allocateRecord();
        errdefer record.deinit(self.allocator);
        const agent_value = try self.allocator.create(Agent);
        errdefer self.allocator.destroy(agent_value);
        const info: child.Info = .{ .agent = identity.AgentId.generate(), .owning_parent_conversation = parent.conversation, .created_by_agent = parent.agent, .request_key = draft.request_key, .name = draft.name, .context_mode = draft.context_mode, .reusable = draft.reusable, .model = draft.model, .effort = draft.effort, .context_source = if (inherited) |snapshot| snapshot.source else null, .initial_context_hash = context_hash, .skill_ids = draft.skill_ids, .mcp_ids = draft.mcp_ids };
        record.child = try child.Owned.init(self.allocator, info);
        try self.inheritWorkspace(record, .{ .conversation = parent_record.id, .snapshot = parent_record.workspace });
        if (inherited) |snapshot| record.history = try wire.History.copy(self.allocator, snapshot.messages, "");
        record.initial_origin = parent_record.initial_origin;
        record.historical_messages = record.history.messages.len;
        agent_value.* = .{ .id = info.agent, .owner = parent_record.binding.?.owner, .role = .child };
        try self.save(.{ .kind = .child_create, .conversation = record.id, .revision = record.revision, .child_info = record.child.?.info, .parent_binding = parent, .messages = record.history.messages, .initial_origin = record.initial_origin, .workspace = if (record.workspace_source != null) record.workspace else null, .workspace_source = record.workspace_source });
        self.agents.appendAssumeCapacity(agent_value);
        self.records.appendAssumeCapacity(record);
        return record;
    }
    /// Stage identity/binding/input under the serialized controller and publish
    /// exactly one durable row. No Worker can observe a partially created task.
    pub fn launchChild(self: *Store, parent: input.Fence, draft: ?child.Draft, reuse: ?identity.AgentId, inherited: ?Inherited, live: scope.Scope, targets: []const identity.SessionHandle, submission: identity.SubmissionId, text: []const u8, fact: *@import("task_budget.zig").Fact) !*Record {
        if (fact.targets) |captured| if (!@import("../config/settings_schema.zig").same(captured, targets)) return error.InvalidTaskFact;
        const capture = struct {
            fn write(_: *anyopaque, _: Event) !void {}
        };
        const original_persist = self.persist;
        const original_input = self.input_persist;
        var sentinel: u8 = 0;
        self.persist = .{ .context = &sentinel, .write = capture.write };
        self.input_persist = null;
        defer {
            self.persist = original_persist;
            self.input_persist = original_input;
        }
        const records_before = self.records.items.len;
        const agents_before = self.agents.items.len;
        const record = if (draft) |config| try self.registerChild(parent, config, inherited) else try self.childFor(parent, reuse orelse return error.ChildNotFound);
        const created = self.records.items.len != records_before;
        if (draft != null and !created) return error.ChildRequestAlreadyUsed;
        errdefer if (created) {
            const removed = self.records.pop().?;
            removed.deinit(self.allocator);
            const removed_agent = self.agents.pop().?;
            self.allocator.free(removed_agent.targets);
            self.allocator.destroy(removed_agent);
            std.debug.assert(self.records.items.len == records_before and self.agents.items.len == agents_before);
        };
        const agent_value = self.agent(record.child.?.info.agent).?;
        const revision = record.revision;
        const environment = agent_value.environment;
        const old_fence = record.inbox.fence;
        const old_closed = record.closed_revision;
        const inbox_revision = record.inbox.revision;
        const inbox_admission = record.inbox.admission;
        const old_owner = agent_value.owner;
        const old_closing = agent_value.closing;
        // Queued old inputs require an explicit disposition before model reuse.
        for (record.inbox.entries.items) |entry| if (!input.terminal(entry.receipt.delivery)) return error.SubmissionUnconfirmed;
        var update = if (created) null else try self.prepareWorkspaceRecheck(record.workspace);
        defer if (update) |*pending| pending.snapshot.deinit(self.allocator);
        const ticket = try self.bindChildImpl(parent, agent_value.id, revision, live, targets, false);
        errdefer {
            record.binding = null;
            record.revision = revision;
            record.closed_revision = old_closed;
            record.inbox.fence = old_fence;
            record.inbox.revision = inbox_revision;
            record.inbox.admission = inbox_admission;
            agent_value.owner = old_owner;
            agent_value.closing = old_closing;
            agent_value.current = null;
            agent_value.parent_binding = null;
            agent_value.environment = environment;
            self.allocator.free(agent_value.targets);
            agent_value.targets = &.{};
        }
        var staged = input.Inbox.init(self.allocator, ticket);
        staged.budget = &self.budget;
        staged.next_sequence = record.inbox.next_sequence;
        staged.revision = record.inbox.revision;
        staged.setWorkspaceRevision(record.workspace.revision);
        staged.queue_revision = record.inbox.queue_revision;
        if (update) |pending| staged.setWorkspaceRevision(pending.snapshot.revision);
        defer staged.deinit();
        const receipt = try staged.admit(ticket, submission, .{ .content = text }, .queue);
        try record.inbox.entries.ensureUnusedCapacity(self.allocator, 1);
        fact.conversation = record.id;
        fact.agent = agent_value.id;
        try fact.validate();
        if (original_persist) |persist| try persist.write(persist.context, .{ .kind = .child_launch, .conversation = record.id, .agent = agent_value.id, .owner = live.owner, .revision = record.revision, .environment = agent_value.environment, .child_info = if (created) record.child.?.info else null, .parent_binding = parent, .targets = agent_value.targets, .messages = if (created) record.history.messages else &.{}, .initial_origin = record.initial_origin, .initial_input = receipt, .initial_text = text, .task_fact = fact.*, .workspace = if (update) |pending| pending.snapshot else if (created and record.workspace_source != null) record.workspace else null, .workspace_source = if (created) record.workspace_source else null, .workspace_change = if (update) |pending| pending.change else null });
        if (update) |*pending| self.publishWorkspace(record, &pending.snapshot, pending.change);
        record.inbox.entries.appendAssumeCapacity(staged.entries.items[0]);
        record.inbox.revision = staged.revision;
        record.inbox.next_sequence = staged.next_sequence;
        record.inbox.queue_revision = staged.queue_revision;
        staged.entries.clearRetainingCapacity();
        record.inbox.persist = original_input;
        record.task_pending = true;
        return record;
    }
    fn childContextHash(allocator: std.mem.Allocator, messages: []const provider.Message) ![32]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const encoded = try @import("session_journal.zig").Journal.encode(a, messages);
        const text = try std.json.Stringify.valueAlloc(a, encoded, .{});
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(text, &hash, .{});
        return hash;
    }
    fn sameModel(a: ?@import("provider_config.zig").ModelSelection, b: ?@import("provider_config.zig").ModelSelection) bool {
        if (a == null or b == null) return a == null and b == null;
        return std.mem.eql(u8, a.?.provider_id, b.?.provider_id) and std.mem.eql(u8, a.?.model_id, b.?.model_id);
    }
    pub fn childCount(self: *Store, parent: identity.ConversationId) usize {
        var count: usize = 0;
        for (self.records.items) |record| if (record.child) |owned| {
            if (owned.info.owning_parent_conversation.eql(parent)) count += 1;
        };
        return count;
    }
    pub fn hasBoundChildren(self: *Store, parent: identity.ConversationId) bool {
        for (self.records.items) |record| if (record.child) |owned| {
            if (owned.info.owning_parent_conversation.eql(parent) and (record.binding != null or record.ending != null or record.task_pending)) return true;
        };
        return false;
    }
    pub fn beginTransition(self: *Store, expected: input.Fence, operation: identity.HostOperationId) !void {
        if (!operation.valid()) return error.InvalidOperation;
        const record = try self.validate(expected);
        if (record.child != null or record.ending != null) return error.ConversationEnding;
        if (record.transition) |pending| {
            if (!pending.fence.eql(expected) or !pending.operation.eql(operation)) return error.TransitionPending;
        } else record.transition = .{ .fence = expected, .operation = operation };
    }
    pub fn releaseTransition(self: *Store, expected: input.Fence, operation: identity.HostOperationId) void {
        const record = self.find(expected.conversation) orelse return;
        if (record.transition) |pending| if (pending.fence.eql(expected) and pending.operation.eql(operation)) {
            record.transition = null;
        };
    }
    pub fn updateChildSettings(self: *Store, parent: input.Fence, agent_id: identity.AgentId, revision: u64, value: child.Settings, live: scope.Scope) !void {
        const record = try self.childFor(parent, agent_id);
        if (record.child_settings_revision != revision) return error.StaleChildSettings;
        if (self.find(parent.conversation).?.transition != null) return error.TransitionPending;
        if (!live.owner.eql(self.find(parent.conversation).?.binding.?.owner)) return error.BindingChanged;
        if (value.targets.len != 0) try validateTargets(live, value.targets);
        var owned = try child.SettingsOwned.init(self.allocator, value, record.child.?.info);
        errdefer owned.deinit();
        const next = try identity.advance(revision);
        try self.save(.{ .kind = .child_config, .conversation = record.id, .agent = agent_id, .revision = next, .child_settings = value });
        if (record.child_settings) |*old| old.deinit();
        record.child_settings = owned;
        record.child_settings_revision = next;
    }
    pub fn childPreferences(record: *const Record) child.Settings {
        return if (record.child_settings) |settings| settings.value else child.Settings.fromInfo(record.child.?.info);
    }
    pub fn childFor(self: *Store, parent: input.Fence, agent_id: identity.AgentId) !*Record {
        const current = try self.validate(parent);
        if (current.child != null or current.ending != null) return error.ChildNotFound;
        for (self.records.items) |record| if (record.child) |owned| {
            if (owned.info.agent.eql(agent_id) and owned.info.owning_parent_conversation.eql(parent.conversation)) return record;
        };
        return error.ChildNotFound;
    }
    /// Bind saved child data to the parent's CURRENT fence, never its creation
    /// AgentId. Exact handles are supplied/validated by the live host adapter.
    pub fn bindChild(self: *Store, parent: input.Fence, agent_id: identity.AgentId, revision: u64, live: scope.Scope, targets: []const identity.SessionHandle) !input.Fence {
        return self.bindChildImpl(parent, agent_id, revision, live, targets, true);
    }
    fn bindChildImpl(self: *Store, parent: input.Fence, agent_id: identity.AgentId, revision: u64, live: scope.Scope, targets: []const identity.SessionHandle, revalidate: bool) !input.Fence {
        const record = try self.childFor(parent, agent_id);
        if (self.find(parent.conversation).?.transition != null) return error.TransitionPending;
        if (record.revision != revision) return error.BindingChanged;
        if (record.task_pending or record.binding != null or record.ending != null or !record.recoverable or record.history.failure != null) return error.BindingConflict;
        record.inbox.lock();
        const unconfirmed = for (record.inbox.entries.items) |entry| {
            if (entry.receipt.delivery == .outcome_unknown or entry.receipt.delivery == .submitting or entry.receipt.delivery == .accepted) break true;
        } else false;
        record.inbox.unlock();
        if (unconfirmed) return error.SubmissionUnconfirmed;
        try validateTargets(live, targets);
        const parent_record = self.find(parent.conversation).?;
        if (!live.owner.eql(parent_record.binding.?.owner)) return error.BindingChanged;
        const agent_value = self.agent(agent_id) orelse return error.AgentNotFound;
        if (agent_value.role != .child or agent_value.current != null or agent_value.busy) return error.BindingConflict;
        const owned = try self.allocator.dupe(identity.SessionHandle, targets);
        errdefer self.allocator.free(owned);
        const next = try identity.advance(record.revision);
        const environment = try identity.advance(agent_value.environment);
        var update = if (revalidate) try self.prepareWorkspaceRecheck(record.workspace) else null;
        defer if (update) |*pending| pending.snapshot.deinit(self.allocator);
        try self.save(.{ .kind = .child_bind, .conversation = record.id, .agent = agent_id, .owner = live.owner, .revision = next, .environment = environment, .parent_binding = parent, .targets = owned, .workspace = if (update) |pending| pending.snapshot else null, .workspace_change = if (update) |pending| pending.change else null });
        if (update) |*pending| self.publishWorkspace(record, &pending.snapshot, pending.change);
        self.allocator.free(agent_value.targets);
        agent_value.targets = owned;
        agent_value.parent_binding = parent;
        agent_value.environment = environment;
        agent_value.owner = live.owner;
        agent_value.closing = false;
        agent_value.current = record.id;
        record.binding = .{ .agent = agent_id, .owner = live.owner };
        record.revision = next;
        record.historical_messages = record.history.messages.len;
        const ticket = try self.fence(record.id);
        record.inbox.changeFence(ticket);
        return ticket;
    }
    fn validateTargets(live: scope.Scope, targets: []const identity.SessionHandle) !void {
        for (targets, 0..) |handle, i| {
            if (@backingInt(handle.session_id) == 0 or handle.generation == 0) return error.TargetOutsideAssistant;
            try live.validateDirectory(&.{@backingInt(handle.session_id)});
            for (targets[0..i]) |prior| if (prior.session_id == handle.session_id) return error.DuplicateTarget;
        }
    }
    /// Dispatch-only gate. Cleanup/checkpoint may still append old facts after
    /// parent invalidation, but new input/reads/leases must pass this gate.
    pub fn validateExecution(self: *Store, expected: input.Fence) !*Record {
        const record = try self.validate(expected);
        if (record.ending != null) return error.ConversationEnding;
        if (record.transition != null) return error.TransitionPending;
        if (record.child != null) {
            const agent_value = self.agent(expected.agent).?;
            const parent = agent_value.parent_binding orelse return error.ParentBindingChanged;
            const parent_record = self.validate(parent) catch return error.ParentBindingChanged;
            if (parent_record.transition != null) return error.TransitionPending;
            if (parent_record.ending != null or parent_record.child != null or !record.child.?.info.owning_parent_conversation.eql(parent.conversation) or !parent_record.binding.?.owner.eql(agent_value.owner)) return error.ParentBindingChanged;
        }
        return record;
    }
    pub fn validateExecutionTarget(self: *Store, expected: input.Fence, handle: identity.SessionHandle, live: scope.Scope, live_handles: []const identity.SessionHandle) !void {
        const record = try self.validateExecution(expected);
        if (!record.binding.?.owner.eql(live.owner)) return error.TargetOutsideAssistant;
        try live.validateDirectory(&.{@backingInt(handle.session_id)});
        const present = for (live_handles) |current| {
            if (current.eql(handle)) break true;
        } else false;
        if (!present) return error.TargetOutsideAssistant;
        if (record.child != null) {
            for (self.agent(expected.agent).?.targets) |target| if (target.eql(handle)) return;
            return error.TargetOutsideAssistant;
        }
    }
    fn removable(self: *Store, record: *Record) !void {
        try self.pollPresentation(record);
        if (record.pending_presentation != null) return error.ResourceCleanupPending;
        if (record.task_pending or record.binding != null or record.ending != null or record.needs_recovery) return error.BindingConflict;
        record.inbox.lock();
        defer record.inbox.unlock();
        for (record.inbox.entries.items) |entry| if (entry.receipt.delivery == .outcome_unknown) return error.SubmissionUnconfirmed;
    }
    /// One durable delete plan, including every child. No partial family is
    /// removed if persistence or any bound/unknown child blocks publication.
    pub fn removeFamily(self: *Store, id: identity.ConversationId, expected_revision: u64, expected_children: usize) !void {
        const parent = self.find(id) orelse return error.ConversationNotFound;
        if (parent.child != null) return error.ChildRequiresParent;
        if (parent.revision != expected_revision or self.childCount(id) != expected_children) return error.BindingChanged;
        try self.removable(parent);
        var children: std.ArrayList(identity.ConversationId) = .empty;
        defer children.deinit(self.allocator);
        for (self.records.items) |record| if (record.child) |owned| {
            if (!owned.info.owning_parent_conversation.eql(id)) continue;
            try self.removable(record);
            try children.append(self.allocator, record.id);
        };
        for (children.items) |child_id| try self.removeShare(child_id);
        try self.removeShare(id);
        try self.save(.{ .kind = .remove_family, .conversation = id, .revision = parent.revision, .children = children.items });
        for (children.items) |child_id| self.eraseRecord(child_id);
        self.eraseRecord(id);
    }
    fn removeShare(self: *Store, id: identity.ConversationId) !void {
        // A share is a regenerable copy. Revoke it before committing deletion
        // so an IO failure leaves the conversation available for retry.
        if (self.share_storage) |storage| try @import("conversation_share.zig").remove(storage.io, storage.dir, id);
    }
    fn eraseRecord(self: *Store, id: identity.ConversationId) void {
        for (self.records.items, 0..) |record, index| if (record.id.eql(id)) {
            if (record.child) |owned| if (self.agent(owned.info.agent)) |child_agent_value| {
                child_agent_value.closing = true;
            };
            record.deinit(self.allocator);
            _ = self.records.orderedRemove(index);
            return;
        };
    }
    fn replayChild(self: *Store, event: Event) !void {
        if (event.kind == .child_create) {
            const info = event.child_info orelse return error.InvalidSessionJournal;
            info.validate() catch return error.InvalidSessionJournal;
            if (event.agent != null or event.owner != null or event.presentation != null or event.draft != null or event.source_revision != null or event.turn != 0 or event.environment != 1 or !event.recoverable) return error.InvalidSessionJournal;
            const hash = try childContextHash(self.allocator, event.messages);
            if (!std.mem.eql(u8, &hash, &info.initial_context_hash)) return error.InvalidSessionJournal;
            const parent = event.parent_binding orelse return error.InvalidSessionJournal;
            const parent_record = self.find(parent.conversation) orelse return error.InvalidSessionJournal;
            if (parent_record.child != null or parent_record.ending != null or !info.owning_parent_conversation.eql(parent.conversation) or !info.created_by_agent.eql(parent.agent) or !(try self.fence(parent.conversation)).eql(parent) or self.agent(info.agent) != null or self.find(event.conversation) != null or event.revision != 1 or event.targets != null or event.children != null or event.parent != null or event.initial_input != null) return error.InvalidSessionJournal;
            if (info.context_source) |source| {
                if (source.message_count != event.messages.len) return error.InvalidSessionJournal;
            } else if (event.messages.len != 0) return error.InvalidSessionJournal;
            try self.agents.ensureUnusedCapacity(self.allocator, 1);
            const fresh = try self.allocateRecord();
            errdefer fresh.deinit(self.allocator);
            const agent_value = try self.allocator.create(Agent);
            errdefer self.allocator.destroy(agent_value);
            fresh.id = event.conversation;
            fresh.inbox.fence.conversation = fresh.id;
            fresh.initial_origin = event.initial_origin;
            fresh.child = try child.Owned.init(self.allocator, info);
            fresh.history = try wire.History.copy(self.allocator, event.messages, "");
            try self.replayWorkspace(fresh, event, parent.conversation);
            fresh.historical_messages = fresh.history.messages.len;
            agent_value.* = .{ .id = info.agent, .role = .child, .owner = parent_record.binding.?.owner, .closing = true };
            self.agents.appendAssumeCapacity(agent_value);
            self.records.appendAssumeCapacity(fresh);
            return;
        }
        if (event.child_info != null or event.children != null or event.messages.len != 0 or event.parent != null or event.source_revision != null or event.initial_input != null or event.presentation != null or event.draft != null or event.turn != 0) return error.InvalidSessionJournal;
        const record = self.find(event.conversation) orelse return error.InvalidSessionJournal;
        const info = (record.child orelse return error.InvalidSessionJournal).info;
        const parent = event.parent_binding orelse return error.InvalidSessionJournal;
        const parent_record = self.find(parent.conversation) orelse return error.InvalidSessionJournal;
        const agent_value = self.agent(info.agent) orelse return error.InvalidSessionJournal;
        const owner = event.owner orelse return error.InvalidSessionJournal;
        const targets = event.targets orelse return error.InvalidSessionJournal;
        const agent_id = event.agent orelse return error.InvalidSessionJournal;
        if (!agent_id.eql(info.agent) or record.binding != null or record.ending != null or !info.owning_parent_conversation.eql(parent.conversation) or parent_record.child != null or parent_record.ending != null or !(try self.fence(parent.conversation)).eql(parent) or !owner.eql(parent_record.binding.?.owner) or event.revision != try identity.advance(record.revision) or event.environment != try identity.advance(agent_value.environment)) return error.InvalidSessionJournal;
        const ids = try self.allocator.alloc(u64, targets.len);
        defer self.allocator.free(ids);
        for (targets, 0..) |handle, i| ids[i] = @backingInt(handle.session_id);
        try validateTargets(.{ .owner = owner, .members = .{}, .inventory = ids[0..targets.len] }, targets);
        const owned_targets = try self.allocator.dupe(identity.SessionHandle, targets);
        errdefer self.allocator.free(owned_targets);
        try self.replayWorkspace(record, event, null);
        self.allocator.free(agent_value.targets);
        agent_value.targets = owned_targets;
        agent_value.current = record.id;
        agent_value.parent_binding = parent;
        agent_value.owner = owner;
        agent_value.environment = event.environment;
        record.binding = .{ .agent = agent_id, .owner = owner };
        record.revision = event.revision;
        record.needs_recovery = true;
    }
    pub fn remove(self: *Store, id: identity.ConversationId) !void {
        for (self.records.items, 0..) |record, index| if (record.id.eql(id)) {
            try self.pollPresentation(record);
            if (record.pending_presentation != null) return error.ResourceCleanupPending;
            if (record.child != null) return error.ChildRequiresParent;
            if (self.childCount(id) != 0) return error.ChildRecordsPresent;
            if (record.task_pending or record.binding != null or record.ending != null) return error.BindingConflict;
            record.inbox.lock();
            for (record.inbox.entries.items) |entry| if (entry.receipt.delivery == .outcome_unknown) {
                record.inbox.unlock();
                return error.SubmissionUnconfirmed;
            };
            record.inbox.unlock();
            try self.removeShare(id);
            try self.save(.{ .kind = .remove, .conversation = id, .revision = record.revision });
            record.deinit(self.allocator);
            _ = self.records.orderedRemove(index);
            return;
        };
        return error.ConversationNotFound;
    }
    fn replayWorkspace(self: *Store, record: *Record, event: Event, initial_source: ?identity.ConversationId) !void {
        const value = event.workspace orelse {
            if (event.workspace_change != null or event.workspace_source != null) return error.InvalidSessionJournal;
            return;
        };
        value.validate() catch return error.InvalidSessionJournal;
        if (initial_source) |source_id| {
            const source = event.workspace_source orelse return error.InvalidSessionJournal;
            if (event.workspace_change != null or value.revision != 1 or !source.conversation.eql(source_id) or !source.conversation.valid()) return error.InvalidSessionJournal;
            source.snapshot.validate() catch return error.InvalidSessionJournal;
            if (!std.meta.eql(source.snapshot.directory_identity, value.directory_identity)) return error.InvalidSessionJournal;
            record.workspace_source = .{ .conversation = source.conversation, .snapshot = try source.snapshot.clone(self.allocator) };
        } else {
            const change = event.workspace_change orelse return error.InvalidSessionJournal;
            if (event.workspace_source != null or change.before_revision != record.workspace.revision or value.revision != try identity.advance(change.before_revision)) return error.InvalidSessionJournal;
            switch (change.reason) {
                .set => if (record.workspace.availability != .none or value.availability != .ready) return error.InvalidSessionJournal,
                .changed => if (record.workspace.availability == .none or value.availability != .ready) return error.InvalidSessionJournal,
                .removed => if (record.workspace.availability == .none or value.availability != .none) return error.InvalidSessionJournal,
                .unavailable => if (record.workspace.availability == .none or value.availability != .unavailable) return error.InvalidSessionJournal,
                .available => if (record.workspace.availability != .unavailable or value.availability != .ready) return error.InvalidSessionJournal,
            }
        }
        var owned = try value.clone(self.allocator);
        self.publishWorkspace(record, &owned, event.workspace_change);
    }
    /// Replay under the journal's exclusive writer lock, before attaching any
    /// worker. A saved binding is metadata, never recovered execution power.
    pub fn replay(self: *Store, event: Event) !void {
        if (event.workspace_ack_revision != null and event.kind != .workspace_ack) return error.InvalidSessionJournal;
        if (event.workspace != null or event.workspace_source != null or event.workspace_change != null) switch (event.kind) {
            .workspace_update, .bind, .fork_bound, .child_create, .child_bind, .child_launch => {},
            else => return error.InvalidSessionJournal,
        };
        if (event.kind == .workspace_update or event.kind == .workspace_ack) {
            const record = self.find(event.conversation) orelse return error.InvalidSessionJournal;
            const fence_value = self.fence(record.id) catch return error.InvalidSessionJournal;
            if (!fence_value.agent.eql(event.agent orelse return error.InvalidSessionJournal) or fence_value.binding != event.revision or fence_value.environment != event.environment or event.messages.len != 0) return error.InvalidSessionJournal;
            if (event.kind == .workspace_ack) {
                const ack = event.workspace_ack_revision orelse return error.InvalidSessionJournal;
                if (ack <= record.workspace_ack_revision or ack > record.workspace.revision) return error.InvalidSessionJournal;
                record.workspace_ack_revision = ack;
            } else {
                if (event.workspace == null) return error.InvalidSessionJournal;
                try self.replayWorkspace(record, event, null);
            }
            return;
        }
        if (event.kind == .child_config) {
            const record = self.find(event.conversation) orelse return error.InvalidSessionJournal;
            const info = (record.child orelse return error.InvalidSessionJournal).info;
            if (!info.agent.eql(event.agent orelse return error.InvalidSessionJournal) or event.revision != try identity.advance(record.child_settings_revision)) return error.InvalidSessionJournal;
            const value = event.child_settings orelse return error.InvalidSessionJournal;
            var owned = child.SettingsOwned.init(self.allocator, value, info) catch return error.InvalidSessionJournal;
            errdefer owned.deinit();
            if (record.child_settings) |*old| old.deinit();
            record.child_settings = owned;
            record.child_settings_revision = event.revision;
            return;
        }
        if (event.child_settings != null) return error.InvalidSessionJournal;
        if (event.kind == .child_launch) {
            const fact = event.task_fact orelse return error.InvalidSessionJournal;
            if (fact.targets) |captured| if (!@import("../config/settings_schema.zig").same(captured, event.targets orelse return error.InvalidSessionJournal)) return error.InvalidSessionJournal;
            const receipt = event.initial_input orelse return error.InvalidSessionJournal;
            const text = event.initial_text orelse return error.InvalidSessionJournal;
            if (!fact.conversation.eql(event.conversation) or !fact.agent.eql(event.agent orelse return error.InvalidSessionJournal) or fact.parent == null or fact.generation == 0 or receipt.delivery != .queued or !receipt.fence.conversation.eql(event.conversation) or receipt.fence.binding != event.revision) return error.InvalidSessionJournal;
            const created = event.child_info != null;
            if (created) {
                try self.replayChild(.{ .kind = .child_create, .conversation = event.conversation, .revision = 1, .child_info = event.child_info, .parent_binding = event.parent_binding, .messages = event.messages, .initial_origin = event.initial_origin, .workspace = event.workspace, .workspace_source = event.workspace_source, .workspace_change = event.workspace_change });
            } else if (event.workspace_source != null) return error.InvalidSessionJournal;
            try self.replayChild(.{ .kind = .child_bind, .conversation = event.conversation, .revision = event.revision, .agent = event.agent, .owner = event.owner, .environment = event.environment, .parent_binding = event.parent_binding, .targets = event.targets, .workspace = if (created) null else event.workspace, .workspace_change = if (created) null else event.workspace_change });
            try self.replayInput(receipt, &.{.{ .content = text }});
            try self.replay(.{ .kind = .task_fact, .conversation = fact.conversation, .revision = fact.sequence, .task_fact = fact });
            return;
        }
        if (event.initial_text != null) return error.InvalidSessionJournal;
        if (event.kind == .task_fact) {
            const fact = event.task_fact orelse return error.InvalidSessionJournal;
            fact.validate() catch return error.InvalidSessionJournal;
            if (!fact.conversation.eql(event.conversation) or fact.sequence != event.revision) return error.InvalidSessionJournal;
            var existing: ?usize = null;
            for (self.task_facts.items, 0..) |prior, i| {
                if (prior.fact.root.eql(fact.root)) {
                    if (prior.fact.sequence >= fact.sequence or prior.fact.counters.requests > fact.counters.requests or prior.fact.counters.calls > fact.counters.calls or prior.fact.counters.elapsed_ns > fact.counters.elapsed_ns) return error.InvalidSessionJournal;
                }
                if (prior.fact.task.eql(fact.task)) {
                    if (!prior.fact.root.eql(fact.root) or !prior.fact.agent.eql(fact.agent) or !prior.fact.conversation.eql(fact.conversation) or prior.fact.generation != fact.generation or !std.meta.eql(prior.fact.parent, fact.parent) or !std.mem.eql(u8, prior.fact.request_key, fact.request_key) or !std.mem.eql(u8, &prior.fact.input_hash, &fact.input_hash) or prior.fact.read_only != fact.read_only or prior.fact.local_files != fact.local_files or !@import("../config/settings_schema.zig").same(prior.fact.targets, fact.targets)) return error.InvalidSessionJournal;
                    if (@import("task_budget.zig").terminal(prior.fact.status) and !@import("task_budget.zig").terminal(fact.status) and !(fact.status == .running and (prior.fact.status == .failed or prior.fact.status == .outcome_unknown) and fact.attempt == prior.fact.attempt + 1)) return error.InvalidSessionJournal;
                    existing = i;
                }
            }
            if (fact.parent) |parent_task| {
                const parent_fact = for (self.task_facts.items) |prior| {
                    if (prior.fact.task.eql(parent_task)) break prior.fact;
                } else return error.InvalidSessionJournal;
                const record = self.find(fact.conversation) orelse return error.InvalidSessionJournal;
                const info = (record.child orelse return error.InvalidSessionJournal).info;
                if (!parent_fact.root.eql(fact.root) or !info.owning_parent_conversation.eql(parent_fact.conversation)) return error.InvalidSessionJournal;
            }
            var owned = try @import("task_budget.zig").Owned.init(self.allocator, fact);
            errdefer owned.deinit();
            if (existing) |i| {
                self.task_facts.items[i].deinit();
                self.task_facts.items[i] = owned;
            } else try self.task_facts.append(self.allocator, owned);
            return;
        }
        if (event.task_fact != null) return error.InvalidSessionJournal;
        if ((event.kind == .conversation_model) != (event.conversation_model != null)) return error.InvalidSessionJournal;
        if (!event.conversation.valid() or event.revision == 0) return error.InvalidSessionJournal;
        if (event.kind == .child_create or event.kind == .child_bind) return self.replayChild(event);
        if (event.child_info != null or event.parent_binding != null or event.targets != null or (event.kind != .remove_family and event.children != null)) return error.InvalidSessionJournal;
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
            if (event.kind == .fork_bound) try self.replayWorkspace(fresh, event, event.parent orelse return error.InvalidSessionJournal);
            self.records.appendAssumeCapacity(fresh);
            record = fresh;
        }
        const value = record orelse return error.InvalidSessionJournal;
        switch (event.kind) {
            .create, .bind, .handoff, .fork_bound, .migrate_bound => {
                if (event.kind == .bind) try self.replayWorkspace(value, event, null);
                const aid = event.agent orelse return error.InvalidSessionJournal;
                const owner = event.owner orelse return error.InvalidSessionJournal;
                var target = self.agent(aid);
                if (target == null) {
                    for (self.agents.items) |other| if (other.role == .attached and other.owner.eql(owner) and !other.id.eql(aid) and other.current != null) return error.InvalidSessionJournal;
                    try self.agents.ensureUnusedCapacity(self.allocator, 1);
                    const created = try self.allocator.create(Agent);
                    // Process-local business objects are not proven alive by
                    // their saved numeric IDs. Reattach creates a fresh Agent.
                    created.* = .{ .id = aid, .owner = owner, .environment = event.environment, .closing = true };
                    self.agents.appendAssumeCapacity(created);
                    target = created;
                }
                if (value.child != null or target.?.role != .attached) return error.InvalidSessionJournal;
                if (target.?.current) |prior| if (!prior.eql(value.id)) return error.InvalidSessionJournal;
                if (value.binding) |prior| if (!prior.agent.eql(aid)) return error.InvalidSessionJournal;
                target.?.current = value.id;
                target.?.owner = owner;
                target.?.environment = event.environment;
                value.binding = .{ .agent = aid, .owner = owner };
                value.revision = event.revision;
                value.needs_recovery = true;
                value.historical_messages = value.history.messages.len;
                if (event.kind == .bind or event.kind == .fork_bound) value.markResumedHistory();
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
                if (self.hasBoundChildren(value.id)) return error.InvalidSessionJournal;
                const bound = value.binding orelse return error.InvalidSessionJournal;
                const old_agent = self.agent(bound.agent).?;
                old_agent.current = null;
                self.allocator.free(old_agent.targets);
                old_agent.targets = &.{};
                old_agent.parent_binding = null;
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
            .conversation_model => {
                const model = try event.conversation_model.?.clone(self.allocator);
                if (value.conversation_model) |prior| prior.deinit(self.allocator);
                value.conversation_model = model;
            },
            .draft => {
                const text = try self.allocator.dupe(u8, event.draft orelse "");
                if (value.draft) |old| self.allocator.free(old);
                value.draft = text;
                value.draft_revision = try identity.advance(value.draft_revision);
            },
            .child_create, .child_bind => unreachable,
            .remove_family => {
                if (value.child != null or value.binding != null) return error.InvalidSessionJournal;
                const children = event.children orelse return error.InvalidSessionJournal;
                if (children.len != self.childCount(value.id)) return error.InvalidSessionJournal;
                for (children, 0..) |id, i| {
                    const dependent = self.find(id) orelse return error.InvalidSessionJournal;
                    const info = (dependent.child orelse return error.InvalidSessionJournal).info;
                    if (!info.owning_parent_conversation.eql(value.id) or dependent.binding != null) return error.InvalidSessionJournal;
                    for (children[0..i]) |prior| if (prior.eql(id)) return error.InvalidSessionJournal;
                }
                for (children) |id| self.eraseRecord(id);
                self.eraseRecord(value.id);
                return;
            },
            .task_fact, .child_launch, .child_config, .workspace_update, .workspace_ack => unreachable,
            .remove => {
                if (value.child != null or self.childCount(value.id) != 0) return error.InvalidSessionJournal;
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
        if (messages.len != 1 or messages[0].role != .user or messages[0].origin != .user_or_tool or !receipt.id.valid() or !receipt.fence.agent.valid() or receipt.sequence == 0 or receipt.revision == 0 or receipt.fence.binding == 0 or receipt.fence.environment == 0) return error.InvalidSessionJournal;
        if (receipt.workspace_revision) |revision| {
            if (revision == 0 or revision > record.workspace.revision) return error.InvalidSessionJournal;
        }
        var payload = try wire.History.copy(self.allocator, messages, "");
        errdefer payload.deinit();
        var entry = record.inbox.findLocked(receipt.id);
        if (entry) |prior| {
            if (!prior.receipt.fence.eql(receipt.fence) or prior.receipt.sequence != receipt.sequence or prior.receipt.mode != receipt.mode or prior.receipt.workspace_revision != receipt.workspace_revision or prior.receipt.revision > receipt.revision or prior.receipt.attempt > receipt.attempt or (input.terminal(prior.receipt.delivery) and prior.receipt.delivery != receipt.delivery)) return error.InvalidSessionJournal;
        }
        if (entry == null) {
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
        entry.?.receipt.pause = if ((receipt.delivery == .queued or receipt.delivery == .accepted) and (receipt.workspace_revision == null or receipt.workspace_revision.? != record.workspace.revision)) .workspace_changed else .stop;
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
