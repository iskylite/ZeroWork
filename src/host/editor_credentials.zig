//! Editor-scoped staging over the existing Keychain transaction. The config
//! store remains the only writer and retires old refs from its complete union.
//! Unsaved passwords cross to a real session/probe only through a host handoff.
const std = @import("std");
const credentials = @import("../config/credential_store.zig");
const secrets = @import("secret_lease.zig");
const identity = @import("identity.zig");
const operations = @import("operation.zig");

pub const EditorTicket = enum(u64) { _ };
pub const Ticket = enum(u64) { _ };
pub const Staged = struct { ticket: Ticket, reference: ?[68]u8 };

/// An opaque host receipt. Plugins may pass it to EditorEvents; only trusted
/// composition consumes it after allocating the actual session operation.
pub const Handoff = struct {
    context: *anyopaque,
    editor_ticket: EditorTicket,
    ticket: Ticket,
};

const Pending = struct {
    ticket: Ticket,
    revision: u64,
    reference: ?[68]u8,
    transaction: credentials.Transaction,
    temporary_secret: ?[]u8,

    fn deinit(self: *Pending, allocator: std.mem.Allocator) void {
        self.transaction.deinit();
        if (self.temporary_secret) |value| wipeFree(allocator, value);
        self.temporary_secret = null;
    }
};
const Editor = struct {
    ticket: EditorTicket,
    id: u64,
    revision: u64,
    alive: bool = true,
    pending: ?Pending = null,
    probe_ticket: ?Ticket = null,
};

pub const Host = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    secret_store: *secrets.Store,
    editors: std.ArrayList(Editor) = .empty,
    editor_tickets: identity.Allocator(EditorTicket) = .{},
    tickets: identity.Allocator(Ticket) = .{},
    owner_thread: std.Thread.Id,
    pub const capacity = 128;

    pub fn init(allocator: std.mem.Allocator, io: std.Io, store: *secrets.Store) Host {
        return .{ .allocator = allocator, .io = io, .secret_store = store, .owner_thread = std.Thread.getCurrentId() };
    }
    pub fn deinit(self: *Host) void {
        for (self.editors.items) |*editor| self.clearEditor(editor);
        self.editors.deinit(self.allocator);
    }
    pub fn bindEditor(self: *Host, id: u64, revision: u64) !Facade {
        try self.requireThread();
        if (id == 0 or revision == 0) return error.InvalidEditor;
        for (self.editors.items) |*editor| if (editor.alive and editor.id == id) {
            try self.setRevision(editor, revision);
            return .{ .context = self, .ticket = editor.ticket, .editor_id = id };
        };
        const value: Editor = .{ .ticket = try self.editor_tickets.allocate(), .id = id, .revision = revision };
        for (self.editors.items) |*editor| if (!editor.alive) {
            editor.* = value;
            return .{ .context = self, .ticket = value.ticket, .editor_id = id };
        };
        if (self.editors.items.len >= capacity) return error.EditorCredentialCapacity;
        try self.editors.append(self.allocator, value);
        return .{ .context = self, .ticket = value.ticket, .editor_id = id };
    }
    /// A ProbeHost calls this after reserving its real child owner/operation,
    /// before creating the restricted worker context. The editor keeps its own
    /// pending secret so another probe of the same draft is still possible.
    pub fn authorizeProbe(self: *Host, editor_id: u64, revision: u64, owner: identity.SessionHandle, operation: operations.OperationKey) !void {
        try self.requireThread();
        for (self.editors.items) |*editor| if (editor.alive and editor.id == editor_id) {
            if (editor.revision != revision) return error.StaleDraft;
            const ticket = editor.probe_ticket orelse return;
            try self.authorize(.{ .context = self, .editor_ticket = editor.ticket, .ticket = ticket }, owner, operation);
            return;
        };
    }
    /// Host composition owns this receiver; the plugin-facing Facade/Handoff
    /// has no operation/owner authorization method. Consume synchronously in
    /// createContext, before handing the restricted facade to an auth worker.
    pub fn authorizeHandoff(self: *Host, handoff: Handoff, owner: identity.SessionHandle, operation: operations.OperationKey) !void {
        if (handoff.context != @as(*anyopaque, self)) return error.CredentialHandoffMismatch;
        try self.authorize(handoff, owner, operation);
    }
    fn authorize(self: *Host, handoff: Handoff, owner: identity.SessionHandle, operation: operations.OperationKey) !void {
        try self.requireThread();
        try @import("tls_trust.zig").requireOperation(owner, operation);
        const editor = try self.find(handoff.editor_ticket);
        const pending = try self.pendingFor(editor, handoff.ticket);
        if (pending.temporary_secret) |value| try self.secret_store.authorizeDefault(owner, operation, value);
    }
    fn find(self: *Host, ticket: EditorTicket) !*Editor {
        try self.requireThread();
        for (self.editors.items) |*editor| if (editor.ticket == ticket) {
            if (!editor.alive) return error.EditorCredentialsDestroyed;
            return editor;
        };
        return error.StaleEditorCredentials;
    }
    fn pendingFor(_: *Host, editor: *Editor, ticket: Ticket) !*Pending {
        const pending = if (editor.pending) |*value| value else return error.StaleCredentialStage;
        if (pending.ticket != ticket or pending.revision != editor.revision) return error.StaleCredentialStage;
        return pending;
    }
    fn clearEditor(self: *Host, editor: *Editor) void {
        if (editor.pending) |*pending| pending.deinit(self.allocator);
        editor.pending = null;
        editor.probe_ticket = null;
    }
    fn setRevision(self: *Host, editor: *Editor, revision: u64) !void {
        if (revision == 0 or revision < editor.revision) return error.StaleDraft;
        if (revision != editor.revision) self.clearEditor(editor);
        editor.revision = revision;
    }
    fn requireThread(self: *const Host) !void {
        if (std.Thread.getCurrentId() != self.owner_thread) return error.EditorCredentialsOffMainThread;
    }
};

/// Bound to a host-issued ticket, not a reusable UI/editor ID. No store,
/// Keychain backend, arbitrary owner or operation is exposed by this facade.
pub const Facade = struct {
    context: *anyopaque,
    ticket: EditorTicket,
    editor_id: u64,

    fn host(self: Facade) *Host {
        return @ptrCast(@alignCast(self.context));
    }
    pub fn prepare(self: Facade, secret: ?[]const u8, old_reference: ?[]const u8, save_password: bool) !Staged {
        const owner = self.host();
        const editor = try owner.find(self.ticket);
        if (old_reference) |reference| if (!credentials.validReference(reference)) return error.InvalidCredentialReference;
        if (secret) |value| if (value.len == 0) return error.EmptyCredential;
        owner.clearEditor(editor);
        var transaction = try credentials.Transaction.init();
        errdefer transaction.deinit();
        var temporary_secret: ?[]u8 = null;
        errdefer if (temporary_secret) |value| wipeFree(owner.allocator, value);
        var reference: ?[68]u8 = null;
        if (save_password) {
            if (secret) |value| {
                const unchanged = if (old_reference) |old| blk: {
                    // Resolve old refs before replacement, preserving denial
                    // semantics. Keep password bytes outside the transaction's
                    // text arena so this editor can explicitly wipe the copy.
                    const previous = (try credentials.getIfPresent(owner.allocator, old)) orelse break :blk false;
                    defer wipeFree(owner.allocator, previous);
                    break :blk std.mem.eql(u8, previous, value);
                } else false;
                if (unchanged) {
                    reference = old_reference.?[0..68].*;
                } else {
                    const staged = (try transaction.stage(owner.io, transaction.arena.allocator(), value, null)).?;
                    reference = staged[0..68].*;
                }
                // Retirement belongs to store.saveHostsWithOptions, which has
                // the complete plugin/reference union and the atomic write.
            } else if (old_reference) |old| reference = old[0..68].*;
        } else {
            temporary_secret = if (secret) |value| try owner.allocator.dupe(u8, value) else if (old_reference) |old| try credentials.getIfPresent(owner.allocator, old) else null;
        }
        const staged: Staged = .{ .ticket = try owner.tickets.allocate(), .reference = reference };
        editor.pending = .{ .ticket = staged.ticket, .revision = editor.revision, .reference = reference, .transaction = transaction, .temporary_secret = temporary_secret };
        return staged;
    }
    pub fn handoff(self: Facade, staged: Staged) !Handoff {
        const owner = self.host();
        const editor = try owner.find(self.ticket);
        _ = try owner.pendingFor(editor, staged.ticket);
        return .{ .context = owner, .editor_ticket = self.ticket, .ticket = staged.ticket };
    }
    pub fn forProbe(self: Facade, staged: Staged) !void {
        const owner = self.host();
        const editor = try owner.find(self.ticket);
        _ = try owner.pendingFor(editor, staged.ticket);
        editor.probe_ticket = staged.ticket;
    }
    /// Validate before invoking the application transaction, so a receipt from
    /// another editor cannot be submitted with this editor's envelope.
    pub fn requireHandoff(self: Facade, handoff_value: Handoff) !void {
        if (handoff_value.context != self.context or handoff_value.editor_ticket != self.ticket) return error.CredentialHandoffMismatch;
        _ = try self.host().pendingFor(try self.host().find(self.ticket), handoff_value.ticket);
    }
    pub fn commit(self: Facade, handoff_value: Handoff) !void {
        try self.requireHandoff(handoff_value);
        const editor = try self.host().find(self.ticket);
        editor.pending.?.transaction.commit();
        self.host().clearEditor(editor);
    }
    pub fn rollback(self: Facade, handoff_value: Handoff) void {
        self.requireHandoff(handoff_value) catch return;
        const editor = self.host().find(self.ticket) catch return;
        self.host().clearEditor(editor);
    }
    pub fn setDraftRevision(self: Facade, revision: u64) !void {
        try self.host().setRevision(try self.host().find(self.ticket), revision);
    }
    pub fn clear(self: Facade) void {
        const editor = self.host().find(self.ticket) catch return;
        self.host().clearEditor(editor);
    }
    pub fn destroy(self: Facade) void {
        const editor = self.host().find(self.ticket) catch return;
        self.host().clearEditor(editor);
        editor.alive = false;
    }
};

fn wipeFree(allocator: std.mem.Allocator, bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
    if (bytes.len != 0) allocator.rawFree(bytes, .of(u8), @returnAddress());
}
