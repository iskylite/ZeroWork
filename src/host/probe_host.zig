//! Application-owned probe scopes. All provider callbacks and snapshot changes
//! run on the controller thread; workers expose progress only through poll.
const std = @import("std");
const sessions = @import("session_host.zig");
const contract = @import("probe_contract.zig");
const envelopes = @import("../config/connection_envelope.zig");
const operations = @import("operation.zig");
const identity = @import("identity.zig");

const Editor = struct {
    host: *Host,
    ticket: contract.EditorTicket,
    id: u64,
    operation: operations.OperationKey,
    revision: u64,
    alive: bool = true,
    owns_operation: bool = false,
    operation_retired: bool = false,
    fn facade(self: *Editor) contract.EditorProbes {
        return .{ .context = self.host, .ticket = self.ticket, .editor_id = self.id, .parent_editor_operation = self.operation, .begin_fn = begin, .snapshot_fn = snapshot, .cancel_fn = cancel, .revision_fn = setRevision, .destroy_fn = destroy };
    }
    fn begin(raw: *anyopaque, ticket: contract.EditorTicket, envelope: envelopes.Envelope, revision: u64) !contract.ProbeToken {
        const host: *Host = @ptrCast(@alignCast(raw));
        const self = try host.editorFor(ticket);
        if (!self.alive) return error.ProbeEditorDestroyed;
        if (revision != self.revision) return error.StaleDraft;
        return self.host.begin(self, envelope, revision);
    }
    fn snapshot(raw: *anyopaque, ticket: contract.EditorTicket, token: contract.ProbeToken, allocator: std.mem.Allocator) !contract.OwnedProbeSnapshot {
        const host: *Host = @ptrCast(@alignCast(raw));
        const self = try host.editorFor(ticket);
        const entry = try self.host.findFor(self, token);
        return contract.OwnedProbeSnapshot.init(allocator, .{ .token = entry.token, .stage = entry.stage, .outcome = if (entry.complete) entry.outcome else null, .cleanup = entry.cleanup, .safe_message = entry.safe_message, .applies_to_draft = self.alive and self.revision == token.draft_revision, .complete = entry.complete });
    }
    fn cancel(raw: *anyopaque, ticket: contract.EditorTicket, token: contract.ProbeToken) !contract.CloseReceipt {
        const host: *Host = @ptrCast(@alignCast(raw));
        const self = try host.editorFor(ticket);
        return self.host.cancelEntry(try self.host.findFor(self, token));
    }
    fn setRevision(raw: *anyopaque, ticket: contract.EditorTicket, revision: u64) !void {
        const host: *Host = @ptrCast(@alignCast(raw));
        const self = try host.editorFor(ticket);
        if (!self.alive) return error.ProbeEditorDestroyed;
        if (revision == 0 or revision < self.revision) return error.StaleDraft;
        self.revision = revision;
    }
    fn destroy(raw: *anyopaque, ticket: contract.EditorTicket) void {
        const host: *Host = @ptrCast(@alignCast(raw));
        const self = host.editorFor(ticket) catch return;
        if (!self.alive) return;
        self.alive = false;
        for (self.host.entries.items) |entry| if (entry.editor == self and !entry.complete) {
            _ = self.host.cancelEntry(entry) catch {};
        };
        self.host.finishEditor(self) catch {};
    }
};
const Entry = struct {
    token: contract.ProbeToken,
    editor: *Editor,
    factory: contract.ProbeFactory,
    cancel_source: std.atomic.Value(bool) = .init(false),
    stage: contract.Stage = .accepted,
    outcome: ?contract.Outcome = null,
    cleanup: contract.CloseReceipt = .awaiting,
    safe_message: []const u8 = "",
    complete: bool = false,
    started: bool = false,
};

pub const Host = struct {
    allocator: std.mem.Allocator,
    sessions: *sessions.SessionHost,
    context_factory: ?contract.ContextFactory = null,
    credential_host: ?*@import("editor_credentials.zig").Host = null,
    owner_thread: std.Thread.Id,
    editors: std.ArrayList(*Editor) = .empty,
    editor_tickets: identity.Allocator(contract.EditorTicket) = .{},
    entries: std.ArrayList(*Entry) = .empty,
    pub const capacity = 128;

    pub fn init(allocator: std.mem.Allocator, host: *sessions.SessionHost) Host {
        return .{ .allocator = allocator, .sessions = host, .owner_thread = std.Thread.getCurrentId() };
    }
    /// Pending or unknown cleanup retains this host and its cancel storage.
    /// Continue poll and retry deinit after the provider supplies release.
    pub fn deinit(self: *Host) !void {
        try self.requireThread();
        for (self.editors.items) |editor| Editor.destroy(self, editor.ticket);
        for (self.entries.items) |entry| if (!entry.complete) return error.ProbeCleanupPending;
        for (self.entries.items) |entry| {
            self.freeEntry(entry);
        }
        for (self.editors.items) |editor| self.allocator.destroy(editor);
        self.entries.deinit(self.allocator);
        self.editors.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn bindEditor(self: *Host, editor_id: u64, parent_operation: operations.OperationKey, revision: u64) !contract.EditorProbes {
        try self.requireThread();
        if (editor_id == 0 or parent_operation.operation_id == 0 or revision == 0) return error.InvalidProbeEditor;
        for (self.editors.items) |editor| if (editor.id == editor_id and editor.alive) {
            if (!editor.operation.eql(parent_operation)) return error.ProbeEditorConflict;
            try Editor.setRevision(self, editor.ticket, revision);
            return editor.facade();
        };
        // A dead editor with no live child can reuse its bounded slot. Drop its
        // completed diagnostics before overwriting the internal Editor pointer.
        // Existing facades carry the old ticket and only point to this Host.
        for (self.editors.items) |editor| if (!editor.alive and !self.editorHasPending(editor)) {
            const ticket = try self.editor_tickets.allocate();
            self.reapEditorEntries(editor);
            editor.* = .{ .host = self, .ticket = ticket, .id = editor_id, .operation = parent_operation, .revision = revision };
            return editor.facade();
        };
        if (self.editors.items.len >= capacity) return error.ProbeCapacity;
        const editor = try self.allocator.create(Editor);
        errdefer self.allocator.destroy(editor);
        editor.* = .{ .host = self, .ticket = try self.editor_tickets.allocate(), .id = editor_id, .operation = parent_operation, .revision = revision };
        try self.editors.append(self.allocator, editor);
        return editor.facade();
    }
    /// UI composition uses this rather than inventing an operation ID. Both
    /// editor parent and probe child live in the one SessionHost journal.
    pub fn bindParent(self: *Host, editor_id: u64, revision: u64) !contract.EditorProbes {
        try self.requireThread();
        for (self.editors.items) |editor| if (editor.id == editor_id and editor.alive) {
            try Editor.setRevision(self, editor.ticket, revision);
            return editor.facade();
        };
        const parent = try self.sessions.journal.begin(.app, null);
        errdefer {
            _ = self.sessions.journal.completeReleased(parent, "") catch false;
            self.sessions.journal.retire(parent, .no_resources) catch {};
        }
        const facade_value = try self.bindEditor(editor_id, parent, revision);
        (try self.editorFor(facade_value.ticket)).owns_operation = true;
        return facade_value;
    }
    /// Hiding/cancelling a modal stops its children without invalidating the
    /// mounted facade; destroying/remounting the draft uses destroy instead.
    pub fn cancelParent(self: *Host, editor_id: u64) !void {
        try self.requireThread();
        for (self.entries.items) |entry| if (entry.editor.id == editor_id and entry.editor.alive and !entry.complete) {
            _ = try self.cancelEntry(entry);
        };
    }
    fn begin(self: *Host, editor: *Editor, envelope: envelopes.Envelope, revision: u64) !contract.ProbeToken {
        // History is diagnostic and bounded. Only active work or unresolved
        // cleanup can exhaust the scope quota; its cancel storage stays pinned.
        if (self.entries.items.len >= capacity) {
            const completed = for (self.entries.items, 0..) |entry, index| {
                if (entry.complete) break index;
            } else return error.ProbeCapacity;
            self.freeEntry(self.entries.orderedRemove(completed));
        }
        const manifest = self.sessions.registry.find(envelope.protocol_id) orelse return error.AdapterNotConnected;
        const factory = (manifest.connection orelse return error.ConnectionNotSupported).probe_factory orelse return error.ProbeNotSupported;
        const entry = try self.allocator.create(Entry);
        var transferred = false;
        errdefer if (!transferred) self.allocator.destroy(entry);
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        const token = try self.sessions.openProbeScope(envelope, editor.operation, revision);
        entry.* = .{ .token = token, .editor = editor, .factory = factory };
        self.entries.appendAssumeCapacity(entry);
        transferred = true;
        // From here the real child scope owns the record, even if submission
        // fails. A failed begin is defined to have acquired no resources.
        if (self.credential_host) |credential_host| credential_host.authorizeProbe(editor.id, revision, token.handle, token.operation) catch |err| {
            try self.failSubmission(entry, err);
            return token;
        };
        const context = if (self.context_factory) |factory_value|
            factory_value.create(factory_value.context, token, &entry.cancel_source) catch |err| {
                try self.failSubmission(entry, err);
                return token;
            }
        else
            contract.ProbeContext{ .owner = token.handle, .operation = token.operation, .cancel = &entry.cancel_source };
        context.requireOwner(token.handle, token.operation) catch |err| {
            try self.failSubmission(entry, err);
            return token;
        };
        if (context.cancel != &entry.cancel_source) {
            try self.failSubmission(entry, error.InvalidProbeCancellation);
            return token;
        }
        factory.begin(factory.context, .{ .token = token, .handle = token.handle, .operation = token.operation, .parent_editor_operation = editor.operation, .draft_revision = revision, .envelope = self.sessions.connectionEnvelope(token.handle).?, .restricted_context = context }) catch |err| {
            try self.failSubmission(entry, err);
            return token;
        };
        entry.started = true;
        return token;
    }
    fn failSubmission(self: *Host, entry: *Entry, err: anyerror) !void {
        try self.setMessage(entry, @errorName(err));
        entry.outcome = .failed;
        try self.applyReceipt(entry, .released);
    }
    /// Called from the host's controller drain point. A late result after
    /// cancellation can release resources but can never revive the old result.
    pub fn poll(self: *Host) !bool {
        try self.requireThread();
        var changed = false;
        for (self.entries.items) |entry| {
            if (entry.complete or !entry.started) continue;
            const update = entry.factory.poll(entry.factory.context, entry.token.operation) catch |err| {
                try self.setMessage(entry, @errorName(err));
                if (!entry.cancel_source.load(.acquire)) entry.outcome = .failed;
                entry.cancel_source.store(true, .release);
                try self.applyReceipt(entry, entry.factory.cancel(entry.factory.context, entry.token.operation));
                changed = true;
                continue;
            } orelse continue;
            switch (update) {
                .progress => |progress| if (entry.outcome == null) {
                    try self.setMessage(entry, progress.safe_message);
                    entry.stage = progress.stage;
                },
                .result => |result| {
                    if (entry.outcome == null) {
                        try self.setMessage(entry, result.safe_message);
                        entry.outcome = result.outcome;
                    }
                    try self.applyReceipt(entry, result.cleanup);
                },
                .cleanup => |receipt| {
                    if (entry.outcome == null and receipt == .released) return error.MissingProbeOutcome;
                    try self.applyReceipt(entry, receipt);
                },
            }
            changed = true;
        }
        return changed;
    }
    fn setMessage(self: *Host, entry: *Entry, message: []const u8) !void {
        const owned = try self.allocator.dupe(u8, message);
        self.allocator.free(entry.safe_message);
        entry.safe_message = owned;
    }
    fn applyReceipt(self: *Host, entry: *Entry, receipt: contract.CloseReceipt) !void {
        if (!try self.sessions.probeScopeReceipt(entry.token, entry.outcome, receipt, entry.safe_message)) return error.StaleProbeScope;
        entry.cleanup = receipt;
        entry.complete = receipt == .released;
        entry.stage = if (entry.complete) .finished else .cleanup;
        if (entry.complete) {
            if (self.credential_host) |credential_host| {
                credential_host.secret_store.revokeOperation(entry.token.operation);
                credential_host.secret_store.revokeOwner(entry.token.handle);
            }
            try self.finishEditor(entry.editor);
        }
    }
    fn cancelEntry(self: *Host, entry: *Entry) !contract.CloseReceipt {
        if (entry.complete) return .released;
        if (entry.cancel_source.swap(true, .acq_rel)) return entry.cleanup;
        entry.outcome = .cancelled;
        try self.setMessage(entry, "测试已取消");
        const receipt = if (entry.started) entry.factory.cancel(entry.factory.context, entry.token.operation) else contract.CloseReceipt.released;
        try self.applyReceipt(entry, receipt);
        return receipt;
    }
    fn findFor(self: *Host, editor: *Editor, token: contract.ProbeToken) !*Entry {
        for (self.entries.items) |entry| if (entry.token.eql(token)) {
            if (entry.editor != editor or !token.parent_editor_operation.eql(editor.operation)) return error.ProbeOwnerMismatch;
            return entry;
        };
        return error.StaleProbeToken;
    }
    fn editorFor(self: *Host, ticket: contract.EditorTicket) !*Editor {
        try self.requireThread();
        for (self.editors.items) |editor| if (editor.ticket == ticket) return editor;
        return error.StaleProbeEditor;
    }
    fn editorHasPending(self: *Host, editor: *Editor) bool {
        for (self.entries.items) |entry| if (entry.editor == editor and !entry.complete) return true;
        return false;
    }
    fn finishEditor(self: *Host, editor: *Editor) !void {
        if (editor.alive or !editor.owns_operation or editor.operation_retired or self.editorHasPending(editor)) return;
        _ = try self.sessions.journal.completeReleased(editor.operation, "");
        try self.sessions.journal.retire(editor.operation, .resources_released);
        editor.operation_retired = true;
    }
    fn reapEditorEntries(self: *Host, editor: *Editor) void {
        var index: usize = 0;
        while (index < self.entries.items.len) {
            const entry = self.entries.items[index];
            if (entry.editor == editor and entry.complete) {
                self.freeEntry(self.entries.orderedRemove(index));
            } else index += 1;
        }
    }
    fn freeEntry(self: *Host, entry: *Entry) void {
        std.debug.assert(entry.complete);
        self.allocator.free(entry.safe_message);
        self.allocator.destroy(entry);
    }
    fn requireThread(self: *Host) !void {
        if (std.Thread.getCurrentId() != self.owner_thread) return error.ProbeOffMainThread;
    }
};
