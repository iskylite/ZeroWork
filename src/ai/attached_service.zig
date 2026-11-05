//! Process-owned adapter for the existing assistant hosts. Windows register
//! controller bridges; they never own or duplicate execution slots.
const std = @import("std");
const runtime = @import("session_runtime.zig");
const identity = @import("../host/identity.zig");
const legacy = @import("assistant_store.zig");
const Journal = @import("session_journal.zig").Journal;
pub const Bridge = struct {
    agent: identity.AgentId,
    window: identity.WindowId,
    context: *anyopaque,
    pump: *const fn (*anyopaque) anyerror!void,
    released: *const fn (*anyopaque) bool,
    destroy: *const fn (*anyopaque) void,
    flush: ?*const fn (*anyopaque) anyerror!void = null,
    ending: ?identity.HostOperationId = null,
    ending_fence: ?runtime.input.Fence = null,
    disposed: bool = false,
};
pub const Host = struct {
    allocator: std.mem.Allocator,
    service: runtime.Service,
    presentations: legacy.Store,
    bridges: std.ArrayList(Bridge) = .empty,
    pumping: bool = false,
    closing: bool = false,
    journal: ?Journal = null,
    journal_io: ?*std.Io.Threaded = null,
    journal_dir: ?std.Io.Dir = null,
    data_root: ?[]u8 = null,
    pub fn init(a: std.mem.Allocator) Host {
        return .{ .allocator = a, .service = runtime.Service.init(a), .presentations = legacy.Store.init(a) };
    }
    pub fn bridgeFor(self: *Host, agent: identity.AgentId) ?*Bridge {
        for (self.bridges.items) |*bridge| if (bridge.agent.eql(agent) and !bridge.disposed) return bridge;
        return null;
    }
    /// Called once under the application's existing data-scope ownership. The
    /// journal's exclusive OS lock excludes a second live writer. No saved
    /// worker/lease can be revived by replay in this newly owned process.
    pub fn ensurePersistence(self: *Host, data_root: []const u8) !void {
        if (self.data_root) |root| {
            if (!std.mem.eql(u8, root, data_root)) return error.AiDataScopeChanged;
            return;
        }
        if (self.service.store.records.items.len != 0 or self.service.runners.items.len != 0 or self.presentations.states.items.len != 0) return error.JournalRequiresEmptyStore;
        const io = try self.allocator.create(std.Io.Threaded);
        errdefer self.allocator.destroy(io);
        io.* = .init(self.allocator, .{});
        errdefer io.deinit();
        const dir = try std.Io.Dir.cwd().openDir(io.io(), data_root, .{});
        errdefer dir.close(io.io());
        const root = try self.allocator.dupe(u8, data_root);
        errdefer self.allocator.free(root);
        self.journal = try Journal.open(self.allocator, io.io(), dir, "ai-sessions.jsonl");
        errdefer {
            self.journal.?.deinit();
            self.journal = null;
            self.service.store.deinit();
            self.service.store = @import("session_lifecycle.zig").Store.init(self.allocator);
            self.presentations.deinit();
            self.presentations = legacy.Store.init(self.allocator);
            self.presentations.authority = &self.service;
        }
        try self.journal.?.bind(&self.service.store);
        for (self.service.store.records.items) |record| if (record.needs_recovery) {
            try self.service.store.recoverOrphan(record.id, .{ .worker_joined = true, .dispatch_closed = true, .local_released = true, .transcript_saved = true });
        };
        for (self.service.store.records.items) |record| {
            const state = try self.presentations.create(record.initial_origin orelse return error.MissingConversationOrigin);
            state.conversation_id = record.id;
            state.binding_revision = record.revision;
            state.selected = false;
            state.ended = true;
            state.historical_environment = true;
            state.listed = true;
            state.phase = .stopped;
            state.wire_history = try @import("wire_history.zig").History.copy(self.allocator, record.history.messages, "");
            state.wire_history.usage = record.history.usage;
            if (record.draft) |text| state.draft = try self.allocator.dupe(u8, text);
            const presentation = @import("conversation_presentation.zig");
            state.history = try presentation.restoreHistory(self.allocator, record.presentation, record.last_turn, record.history.messages);
        }
        self.journal_io = io;
        self.journal_dir = dir;
        self.data_root = root;
    }
    pub fn register(self: *Host, bridge: Bridge) !void {
        self.presentations.authority = &self.service;
        if (self.closing or self.bridgeFor(bridge.agent) != null) return error.AgentBridgeConflict;
        _ = self.service.runnerFor(bridge.agent) orelse return error.AgentNotFound;
        try self.bridges.append(self.allocator, bridge);
    }
    /// Caller first saves any presentation moved into the currently visible
    /// host. A live legacy worker must be drained, never declared stopped.
    pub fn migrate(self: *Host, state: *legacy.State, released: @import("session_lifecycle.zig").Released) !void {
        self.presentations.authority = &self.service;
        if (!released.worker_joined or !released.dispatch_closed or !released.local_released or !released.transcript_saved) return error.ResourceCleanupPending;
        if (state.phase == .running or state.phase == .approval) return error.LegacyWorkerStillRunning;
        if (state.wire_history.failure != null) return error.ConversationNotRecoverable;
        const record = try self.service.store.migrateWithOrigin(state.conversation_id, state.owner, state.binding_revision, state.selected and !state.ended and !state.closed, state.wire_history.messages, state.draft, state.current_turn.id, state.initial_owner orelse state.owner);
        state.binding_revision = record.revision;
        state.ended = record.binding == null;
        state.selected = record.binding != null;
    }
    pub fn pump(self: *Host) !void {
        if (self.pumping) return;
        self.pumping = true;
        defer self.pumping = false;
        var failure: ?anyerror = null;
        for (self.bridges.items) |bridge| if (!bridge.disposed) bridge.pump(bridge.context) catch |err| {
            if (failure == null) failure = err;
        };
        self.service.poll() catch |err| {
            if (failure == null) failure = err;
        };
        for (self.service.store.records.items) |record| if (self.presentations.findConversation(record.id)) |state| {
            state.binding_revision = record.revision;
            if (record.binding) |binding| {
                state.owner = binding.owner;
            } else if (record.closed_revision != null) {
                state.ended = true;
                state.selected = false;
            }
        };
        if (failure) |err| return err;
    }
    pub fn closeWindow(self: *Host, window: identity.WindowId) !bool {
        var failure: ?anyerror = null;
        for (self.bridges.items) |*bridge| {
            if (bridge.disposed or bridge.window != window) continue;
            // Preserve the window's final draft before an idle End can commit.
            if (bridge.flush) |flush| flush(bridge.context) catch |err| {
                if (failure == null) failure = err;
                const active = self.service.runnerFor(bridge.agent).?;
                if (active.agent.current) |id| self.service.stop(self.service.store.fence(id) catch continue) catch {};
                continue;
            };
            const runner = self.service.runnerFor(bridge.agent).?;
            if (runner.agent.current) |id| {
                const ticket = self.service.store.fence(id) catch |err| {
                    if (failure == null) failure = err;
                    continue;
                };
                if (self.service.store.find(id).?.ending) |ending| {
                    bridge.ending = ending.operation;
                } else if (bridge.ending_fence == null or !bridge.ending_fence.?.eql(ticket)) bridge.ending = identity.HostOperationId.generate();
                bridge.ending_fence = ticket;
                self.service.endConversation(ticket, bridge.ending.?) catch |err| {
                    if (failure == null) failure = err;
                };
            }
        }
        self.pump() catch |err| {
            if (failure == null) failure = err;
        };
        if (failure) |err| return err;
        return self.windowReady(window);
    }
    pub fn windowReady(self: *Host, window: identity.WindowId) bool {
        var ready = true;
        for (self.bridges.items) |bridge| {
            if (bridge.disposed or bridge.window != window) continue;
            const runner = self.service.runnerFor(bridge.agent).?;
            if (runner.thread != null or runner.agent.busy or runner.pending_commit or runner.pending_notify or runner.agent.current != null or !bridge.released(bridge.context)) ready = false;
        }
        return ready;
    }
    pub fn releaseWindow(self: *Host, window: identity.WindowId) !void {
        if (!try self.closeWindow(window)) return error.ResourceCleanupPending;
        for (self.bridges.items) |*bridge| if (!bridge.disposed and bridge.window == window) {
            try self.service.retire(bridge.agent);
            bridge.destroy(bridge.context);
            bridge.disposed = true;
        };
    }
    pub fn shutdown(self: *Host) !bool {
        self.closing = true;
        var ready = true;
        var failure: ?anyerror = null;
        // Iterate every owner, including agents hidden in another window.
        for (self.bridges.items) |bridge| if (!bridge.disposed) {
            const done = self.closeWindow(bridge.window) catch |err| {
                if (failure == null) failure = err;
                ready = false;
                continue;
            };
            ready = ready and done;
        };
        for (self.service.store.records.items) |record| if (record.binding) |binding| {
            if (self.service.runnerFor(binding.agent) != null) {
                ready = false;
                continue;
            }
            // Only a migration proven quiescent can have no executor at all.
            const ticket = self.service.store.fence(record.id) catch |err| {
                if (failure == null) failure = err;
                continue;
            };
            const operation = if (record.ending) |ending| ending.operation else identity.HostOperationId.generate();
            _ = self.service.store.beginEnd(ticket, operation) catch |err| {
                if (failure == null) failure = err;
                continue;
            };
            self.service.store.commitEnd(ticket, operation, .{ .worker_joined = true, .dispatch_closed = true, .local_released = true, .transcript_saved = true }) catch |err| {
                if (failure == null) failure = err;
            };
        };
        if (failure) |err| return err;
        return ready;
    }
    pub fn deinit(self: *Host) !void {
        if (!try self.shutdown()) return error.ResourceCleanupPending;
        for (self.bridges.items) |*bridge| if (!bridge.disposed) {
            bridge.destroy(bridge.context);
            bridge.disposed = true;
        };
        self.service.deinit();
        self.presentations.deinit();
        self.bridges.deinit(self.allocator);
        if (self.journal) |*journal| journal.deinit();
        if (self.journal_io) |io| {
            if (self.journal_dir) |dir| dir.close(io.io());
            io.deinit();
            self.allocator.destroy(io);
        }
        if (self.data_root) |root| self.allocator.free(root);
    }
};
