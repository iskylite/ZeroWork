//! Frozen UI commands over the existing lifecycle authority. No widget pointers
//! and no implicit restore, reconnect, queued execution or target redirection.
const std = @import("std");
const lifecycle = @import("session_lifecycle.zig");
const runtime = @import("session_runtime.zig");
const identity = @import("../host/identity.zig");
const scope = @import("tool_scope.zig");
pub const Kind = enum { end, new, restore, copy, copy_use };
pub const Result = struct { conversation: ?identity.ConversationId, used: bool = false };
pub const Command = struct {
    kind: Kind,
    source: ?identity.ConversationId,
    source_revision: u64 = 0,
    source_content_revision: u64 = 0,
    target: identity.AgentId,
    owner: scope.Owner,
    environment: u64,
    previous: ?runtime.input.Fence,
    operation: identity.HostOperationId,
    pinned: ?lifecycle.Store.ForkSnapshot = null,
    end_started: bool = false,
    text_only: bool = false,

    /// Saved terminal/group numbers can be reused on a later launch. Only
    /// the original live Agent and its unchanged environment may rebind
    /// the original conversation identity.
    pub fn canRestore(record: *const lifecycle.Record, agent: *const lifecycle.Agent) bool {
        const ended = record.last_end orelse return false;
        return record.binding == null and record.closed_revision != null and record.ending == null and
            record.recoverable and record.history.failure == null and !record.task_pending and !agent.closing and
            ended.fence.agent.eql(agent.id) and ended.fence.environment == agent.environment;
    }

    pub fn sameLiveEnvironment(record: *const lifecycle.Record, agent: *const lifecycle.Agent) bool {
        if (record.binding) |binding| return !record.needs_recovery and binding.agent.eql(agent.id) and binding.owner.eql(agent.owner);
        return canRestore(record, agent);
    }
    pub fn prepare(service: *runtime.Service, kind: Kind, source: ?identity.ConversationId, target: identity.AgentId) !Command {
        const runner = service.runnerFor(target) orelse return error.AgentNotFound;
        if (runner.agent.role != .attached) return error.ChildRequiresParent;
        if (runner.agent.closing) return error.AgentClosed;
        var command: Command = .{ .kind = kind, .operation = identity.HostOperationId.generate(), .source = source, .target = target, .owner = runner.agent.owner, .environment = runner.agent.environment, .previous = if (runner.agent.current) |id| try service.store.fence(id) else null };
        if (kind == .restore or kind == .copy or kind == .copy_use) {
            const record = service.store.find(source orelse return error.ConversationNotFound) orelse return error.ConversationNotFound;
            if (record.child != null) return error.ChildRequiresParent;
            command.source_revision = record.revision;
            command.source_content_revision = record.content_revision;
            if (kind == .restore) {
                if (record.binding != null or record.ending != null) return error.BindingConflict;
                if (!record.recoverable or record.history.failure != null) return error.ConversationNotRecoverable;
                if (!canRestore(record, runner.agent)) return error.RestoreEnvironmentChanged;
            } else {
                command.text_only = kind == .copy_use and !sameLiveEnvironment(record, runner.agent);
                command.pinned = if (command.text_only)
                    try service.store.pinTextFork(record.id, runner.agent.owner)
                else
                    try service.store.pinFork(record.id);
            }
        }
        if (command.previous) |ticket| if (kind != .copy and service.store.find(ticket.conversation).?.ending != null) {
            command.deinit();
            return error.LifecycleBusy;
        };
        return command;
    }
    pub fn needsConfirmation(self: Command) bool {
        return self.text_only or (self.previous != null and self.kind != .copy);
    }
    /// The host's completed Turn owns this canonical prefix. Freeze it before
    /// confirmation, using the same End/use-copy transaction as the list.
    pub fn selectCheckpoint(self: *Command, store: *lifecycle.Store, turn: u64, messages: []const @import("provider.zig").Message) !void {
        if (self.text_only) return error.RestoreEnvironmentChanged;
        const pin = if (self.pinned) |*value| value else return error.NoStableCheckpoint;
        const source = store.find(pin.source) orelse return error.ConversationNotFound;
        if (source.content_revision != pin.revision) return error.CheckpointChanged;
        if (turn == 0 or turn > source.last_turn) return error.NoStableCheckpoint;
        var snapshot = try @import("wire_history.zig").History.copy(store.allocator, messages, "");
        errdefer snapshot.deinit();
        const presentation = if (pin.presentation) |bytes| try snapshot.arenaAllocator().dupe(u8, bytes) else null;
        pin.history.deinit();
        pin.history = snapshot;
        pin.presentation = presentation;
        pin.turn = turn;
    }
    pub fn deinit(self: *Command) void {
        if (self.pinned) |*pin| pin.deinit();
        self.pinned = null;
    }
    pub fn validateTarget(self: Command, service: *runtime.Service) !*runtime.Runner {
        const runner = service.runnerFor(self.target) orelse return error.AgentNotFound;
        if (runner.agent.closing or !runner.agent.owner.eql(self.owner) or runner.agent.environment != self.environment) return error.BindingChanged;
        if (runner.agent.current) |current| {
            const prior = self.previous orelse return error.BindingConflict;
            if (!current.eql(prior.conversation) or !(try service.store.fence(current)).eql(prior)) return error.BindingChanged;
        } else if (self.previous != null and !self.end_started) return error.BindingChanged;
        return runner;
    }
    /// null means the original End is still releasing. Call only after the
    /// UI explicitly confirmed; cancellation drops this command, never End.
    pub fn advance(self: *Command, service: *runtime.Service) !?Result {
        if (self.kind == .copy) return .{ .conversation = try service.store.publishFork(&self.pinned.?, null) };
        const runner = try self.validateTarget(service);
        // Recheck before stopping the target: a raced source cannot needlessly
        // stop somebody's current task or acquire a second writer.
        if (self.kind == .restore) {
            const source = service.store.find(self.source.?) orelse return error.ConversationNotFound;
            if (source.revision != self.source_revision or source.content_revision != self.source_content_revision or !canRestore(source, runner.agent)) return error.BindingChanged;
        }
        if (self.previous) |ticket| if (runner.agent.current != null) {
            try service.endConversation(ticket, self.operation);
            self.end_started = true;
            if (runner.agent.current != null) return null;
        };
        if (runner.thread != null or runner.agent.busy or runner.pending_commit or runner.pending_notify) return null;
        return switch (self.kind) {
            .end, .new => .{ .conversation = null },
            .restore => .{ .conversation = (try service.resumeConversation(self.source.?, self.target, self.source_revision)).conversation, .used = true },
            .copy_use => blk: {
                const id = try service.store.publishFork(&self.pinned.?, self.target);
                runner.record = service.store.find(id);
                runner.context = null;
                if (runner.worker) |worker| worker.manager.input = null;
                runner.has_tools = false;
                break :blk .{ .conversation = id, .used = true };
            },
            .copy => unreachable,
        };
    }
};
