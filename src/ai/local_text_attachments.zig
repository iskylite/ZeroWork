//! Local-text attachment ownership, independent of file IO and UI focus.
//! V0.1.7 §5: local UTF-8 text is an immutable <=64 KiB snapshot; invalid new
//! sources do not enter the draft. A sent bundle owns references independently.
const std = @import("std");
pub const Owner = @import("tool_scope.zig").Owner;
pub const max_bytes: usize = 64 * 1024;
pub const Id = u64;
const identity = @import("../host/identity.zig");
const paths = @import("../host/local_path.zig");
pub const SessionHandle = identity.SessionHandle;
pub const TerminalSource = struct {
    owner: SessionHandle,
    source_name: []const u8,
    line_count: u32,
    origin: union(enum) {
        selection: struct {
            selection: @import("../vt/viewport.zig").OwnedSelection,
            source_version: u64,
            /// Original inclusive viewport cells for the legacy SSH renderer.
            /// Owned anchors are real adapter receipts, retained as provenance.
            legacy_range: ?@import("../vt/engine.zig").Selection = null,
        },
        command: struct { command_id: u64, end_sequence: u64, exit_code: i32, command: []const u8 },
    },
};
pub const RemoteSource = struct {
    owner: SessionHandle,
    source_name: []const u8,
    source_revision: u64,
    operation: ?@import("../host/operation.zig").OperationKey,
    actual_path: ?[]const u8,
    original_size: ?u64,
    read_bytes: usize,
    read_limit: u32,
    truncated: bool,
    /// A locator only: no file content has been captured for this attachment.
    reference_only: bool = false,
};
pub const LocalReference = struct {
    reason: enum { binary, encoding, size_limit, text_limit, image_limit, image_count } = .binary,
    size_bytes: ?u64 = null,
};
pub const Source = union(enum) { local_file, local_reference: LocalReference, terminal: TerminalSource, remote_file: RemoteSource };
/// Existing Ghostty selection service bound, independent of local-file 64KiB.
pub const max_terminal_bytes: usize = 1024 * 1024;

pub fn validateText(bytes: []const u8) !void {
    if (bytes.len > max_bytes) return error.LocalTextTooLarge;
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.BinaryLocalText;
    if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..2], "PK") and
        ((bytes[2] == 3 and bytes[3] == 4) or (bytes[2] == 5 and bytes[3] == 6) or (bytes[2] == 7 and bytes[3] == 8))) return error.BinaryLocalText;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidLocalTextEncoding;
}

pub const PinnedLocal = struct {
    absolute: []const u8,
    identity: paths.Identity,

    pub fn fromResolved(target: paths.Resolved) PinnedLocal {
        return .{ .absolute = target.absolute, .identity = target.target_identity.? };
    }
};

pub const Content = struct {
    path: []const u8,
    bytes: []const u8,
    captured_at_ms: i64,
    sha256: [32]u8,
    /// UTF-8 BOM bytes are preserved, never silently normalized.
    bom_preserved: bool,
    source: Source = .local_file,
    pinned_local: ?PinnedLocal = null,

    pub fn fileReference(self: Content, conversation: identity.ConversationId) ?paths.Reference {
        if (!conversation.valid()) return null;
        const pin = self.pinned_local orelse return null;
        return .{ .conversation = conversation, .requested = self.path, .absolute = pin.absolute, .identity = pin.identity };
    }
};
const Snapshot = struct {
    allocator: std.mem.Allocator,
    references: std.atomic.Value(usize) = .init(1),
    value: Content,
};
pub const ContentRef = struct {
    snapshot: ?*Snapshot = null,

    pub fn create(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8, captured_at_ms: i64) !ContentRef {
        try validateText(bytes);
        return createSnapshot(allocator, path, bytes, captured_at_ms, .local_file, null);
    }
    pub fn createLocalReference(allocator: std.mem.Allocator, path: []const u8, reason: LocalReference) !ContentRef {
        if (!std.fs.path.isAbsolute(path) or !std.unicode.utf8ValidateSlice(path)) return error.InvalidAttachmentPath;
        return createSnapshot(allocator, path, "", 0, .{ .local_reference = reason }, null);
    }
    pub fn createPinnedLocal(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8, captured_at_ms: i64, pin: PinnedLocal) !ContentRef {
        try validateText(bytes);
        return createSnapshot(allocator, path, bytes, captured_at_ms, .local_file, pin);
    }
    pub fn createPinnedLocalReference(allocator: std.mem.Allocator, path: []const u8, reason: LocalReference, pin: PinnedLocal) !ContentRef {
        return createSnapshot(allocator, path, "", 0, .{ .local_reference = reason }, pin);
    }
    /// Already captured plain VT bytes only. This reads no terminal or file.
    pub fn createTerminal(allocator: std.mem.Allocator, source: TerminalSource, bytes: []const u8, captured_at_ms: i64) !ContentRef {
        if (@backingInt(source.owner.session_id) == 0 or source.owner.generation == 0) return error.InvalidAttachmentOwner;
        if (source.source_name.len == 0 or !std.unicode.utf8ValidateSlice(source.source_name) or std.mem.indexOfScalar(u8, source.source_name, 0) != null) return error.InvalidTerminalSource;
        if (bytes.len == 0 or source.line_count == 0) return error.EmptyTerminalSelection;
        if (bytes.len > max_terminal_bytes) return error.TerminalTextTooLarge;
        if (!std.unicode.utf8ValidateSlice(bytes) or std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidTerminalText;
        switch (source.origin) {
            .selection => |value| {
                if (!value.selection.start.owner.eql(source.owner) or !value.selection.end.owner.eql(source.owner)) return error.StaleOwner;
                if (value.source_version == 0 or value.selection.start.id == 0 or value.selection.end.id == 0) return error.InvalidTerminalSource;
            },
            .command => |value| {
                if (value.command_id == 0 or value.end_sequence <= value.command_id or value.exit_code == 0 or !std.unicode.utf8ValidateSlice(value.command) or std.mem.indexOfScalar(u8, value.command, 0) != null) return error.InvalidTerminalSource;
            },
        }
        return createSnapshot(allocator, switch (source.origin) {
            .selection => "终端选区.txt",
            .command => "命令上下文.txt",
        }, bytes, captured_at_ms, .{ .terminal = source }, null);
    }
    pub fn createRemote(allocator: std.mem.Allocator, reference: @import("../host/ai_remote_file_snapshot.zig").ResultRef, source_name: []const u8) !ContentRef {
        const value = reference.value() orelse return error.EmptyAttachmentResult;
        if (value.body != .text) return error.RemoteFileReadFailed;
        return createSnapshot(allocator, value.metadata.requested_path, value.body.text.bytes, value.metadata.captured_at_ms, .{ .remote_file = .{
            .owner = value.metadata.source,
            .source_name = source_name,
            .source_revision = value.metadata.source_revision,
            .operation = value.metadata.operation,
            .actual_path = value.metadata.actual_path,
            .original_size = value.body.text.original_size,
            .read_bytes = value.body.text.read_bytes,
            .read_limit = value.body.text.read_limit,
            .truncated = value.body.text.truncated,
        } }, null);
    }
    pub fn createRemoteReference(allocator: std.mem.Allocator, owner: SessionHandle, source_name: []const u8, path: []const u8) !ContentRef {
        if (@backingInt(owner.session_id) == 0 or owner.generation == 0) return error.InvalidAttachmentOwner;
        if (source_name.len == 0 or !std.unicode.utf8ValidateSlice(source_name) or std.mem.indexOfScalar(u8, source_name, 0) != null) return error.InvalidRemoteSource;
        try @import("../host/ai_remote_file_snapshot.zig").validatePath(path);
        return createSnapshot(allocator, path, "", 0, .{ .remote_file = .{
            .owner = owner,
            .source_name = source_name,
            .source_revision = 0,
            .operation = null,
            .actual_path = null,
            .original_size = null,
            .read_bytes = 0,
            .read_limit = 0,
            .truncated = false,
            .reference_only = true,
        } }, null);
    }
    /// Rehydrate already captured bytes; never reread a local/remote source.
    pub fn restore(allocator: std.mem.Allocator, value: Content) !ContentRef {
        if (value.source == .local_reference) {
            if (value.pinned_local) |pin| return createPinnedLocalReference(allocator, value.path, value.source.local_reference, pin);
            return createLocalReference(allocator, value.path, value.source.local_reference);
        }
        if (!std.unicode.utf8ValidateSlice(value.bytes)) return error.InvalidLocalTextEncoding;
        if (value.source == .remote_file) {
            const remote = value.source.remote_file;
            if (remote.reference_only) return createRemoteReference(allocator, remote.owner, remote.source_name, value.path);
            if (remote.operation == null) return error.InvalidRemoteSource;
        }
        return createSnapshot(allocator, value.path, value.bytes, value.captured_at_ms, value.source, value.pinned_local);
    }
    fn createSnapshot(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8, captured_at_ms: i64, source: Source, pin: ?PinnedLocal) !ContentRef {
        if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidAttachmentPath;
        var owned_source = source;
        switch (source) {
            .local_file, .local_reference => {},
            .remote_file => |remote| {
                owned_source.remote_file.source_name = try allocator.dupe(u8, remote.source_name);
                errdefer allocator.free(owned_source.remote_file.source_name);
                if (remote.actual_path) |path_value| owned_source.remote_file.actual_path = try allocator.dupe(u8, path_value);
            },
            .terminal => |terminal| {
                owned_source.terminal.source_name = try allocator.dupe(u8, terminal.source_name);
                errdefer allocator.free(owned_source.terminal.source_name);
                if (terminal.origin == .command) owned_source.terminal.origin.command.command = try allocator.dupe(u8, terminal.origin.command.command);
            },
        }
        errdefer freeSource(allocator, owned_source);
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        const owned_bytes = try allocator.dupe(u8, bytes);
        errdefer allocator.free(owned_bytes);
        const owned_pin: ?PinnedLocal = if (pin) |value| blk: {
            if ((source != .local_file and source != .local_reference) or !std.fs.path.isAbsolute(path) or
                !std.fs.path.isAbsolute(value.absolute) or value.identity.inode == 0 or
                !std.unicode.utf8ValidateSlice(path) or !std.unicode.utf8ValidateSlice(value.absolute) or
                std.mem.indexOfScalar(u8, value.absolute, 0) != null)
                return error.InvalidAttachmentPath;
            break :blk .{ .absolute = try allocator.dupe(u8, value.absolute), .identity = value.identity };
        } else null;
        errdefer if (owned_pin) |value| allocator.free(value.absolute);
        const snapshot = try allocator.create(Snapshot);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(owned_bytes, &digest, .{});
        snapshot.* = .{ .allocator = allocator, .value = .{
            .path = owned_path,
            .bytes = owned_bytes,
            .captured_at_ms = captured_at_ms,
            .sha256 = digest,
            .bom_preserved = std.mem.startsWith(u8, owned_bytes, "\xef\xbb\xbf"),
            .source = owned_source,
            .pinned_local = owned_pin,
        } };
        return .{ .snapshot = snapshot };
    }

    pub fn content(self: ContentRef) ?Content {
        return if (self.snapshot) |snapshot| snapshot.value else null;
    }
    pub fn retain(self: ContentRef) ContentRef {
        const snapshot = self.snapshot orelse return .{};
        const previous = snapshot.references.fetchAdd(1, .monotonic);
        std.debug.assert(previous > 0 and previous < std.math.maxInt(usize));
        return self;
    }
    pub fn release(self: *ContentRef) void {
        const snapshot = self.snapshot orelse return;
        self.snapshot = null;
        if (snapshot.references.fetchSub(1, .acq_rel) != 1) return;
        const allocator = snapshot.allocator;
        allocator.free(snapshot.value.path);
        allocator.free(snapshot.value.bytes);
        if (snapshot.value.pinned_local) |pin| allocator.free(pin.absolute);
        freeSource(allocator, snapshot.value.source);
        allocator.destroy(snapshot);
    }
};

pub const Ticket = struct {
    owner: Owner,
    conversation_id: ?@import("../host/identity.zig").ConversationId = null,
    draft_epoch: u64,
    id: Id,
    terminal_owner: ?SessionHandle = null,
    pub fn eql(self: Ticket, other: Ticket) bool {
        return self.owner.eql(other.owner) and std.meta.eql(self.conversation_id, other.conversation_id) and self.draft_epoch == other.draft_epoch and self.id == other.id and std.meta.eql(self.terminal_owner, other.terminal_owner);
    }
};
pub const Item = struct { id: Id, reference: ContentRef };
pub const Candidate = struct { id: Id, reference: ContentRef, replaces: ?Id = null };

pub const Bundle = struct {
    allocator: std.mem.Allocator,
    owner: Owner,
    conversation_id: ?@import("../host/identity.zig").ConversationId = null,
    draft_epoch: u64,
    items: []Item,
    pub fn deinit(self: *Bundle) void {
        for (self.items) |*item| item.reference.release();
        self.allocator.free(self.items);
        self.items = &.{};
    }
    pub fn retain(self: *const Bundle) !Bundle {
        const items = try self.allocator.alloc(Item, self.items.len);
        for (self.items, items) |item, *copy| copy.* = .{ .id = item.id, .reference = item.reference.retain() };
        return .{ .allocator = self.allocator, .owner = self.owner, .conversation_id = self.conversation_id, .draft_epoch = self.draft_epoch, .items = items };
    }
};

/// Main-thread-only draft. Workers receive a Ticket, their own selected path
/// and cancellation token; they never borrow this mutable Draft.
pub const Draft = struct {
    allocator: std.mem.Allocator,
    owner: Owner,
    conversation_id: ?@import("../host/identity.zig").ConversationId = null,
    epoch: u64 = 1,
    next_id: Id = 1,
    pending: std.ArrayList(Ticket) = .empty,
    items: std.ArrayList(Item) = .empty,
    candidates: std.ArrayList(Candidate) = .empty,

    pub fn init(allocator: std.mem.Allocator, owner: Owner) !Draft {
        const id = switch (owner) {
            .session => |id| id,
            .group => |id| id,
        };
        if (id == 0) return error.InvalidAttachmentOwner;
        return .{ .allocator = allocator, .owner = owner };
    }
    /// The host cancels/joins all readers before destroying the draft/store.
    pub fn deinit(self: *Draft) void {
        for (self.items.items) |*item| item.reference.release();
        self.items.deinit(self.allocator);
        for (self.candidates.items) |*item| item.reference.release();
        self.candidates.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.* = undefined;
    }
    /// Capture before opening a picker. Picker cancellation calls cancel();
    /// no path is read, and no attachment item exists until complete().
    pub fn begin(self: *Draft) !Ticket {
        return self.beginForTerminal(null);
    }
    pub fn beginTerminal(self: *Draft, owner: SessionHandle) !Ticket {
        if (@backingInt(owner.session_id) == 0 or owner.generation == 0) return error.InvalidAttachmentOwner;
        if (self.owner == .session and self.owner.session != @backingInt(owner.session_id)) return error.StaleAttachment;
        return self.beginForTerminal(owner);
    }
    fn beginForTerminal(self: *Draft, terminal_owner: ?SessionHandle) !Ticket {
        if (self.next_id == std.math.maxInt(Id)) return error.AttachmentIdExhausted;
        const ticket: Ticket = .{ .owner = self.owner, .conversation_id = self.conversation_id, .draft_epoch = self.epoch, .id = self.next_id, .terminal_owner = terminal_owner };
        try self.pending.append(self.allocator, ticket);
        self.next_id += 1;
        return ticket;
    }
    pub fn contains(self: *const Draft, ticket: Ticket) bool {
        return self.pendingIndex(ticket) != null;
    }
    pub fn cancel(self: *Draft, ticket: Ticket) bool {
        const index = self.pendingIndex(ticket) orelse return false;
        _ = self.pending.orderedRemove(index);
        self.removeCandidate(ticket.id);
        return true;
    }
    pub fn candidate(self: *const Draft, ticket: Ticket) ?Candidate {
        if (self.pendingIndex(ticket) == null) return null;
        for (self.candidates.items) |item| if (item.id == ticket.id) return item;
        return null;
    }
    /// Validation success is a preview candidate, not an attached draft item.
    /// Always consumes incoming; cancel/replace/old-owner completions release.
    pub fn stage(self: *Draft, ticket: Ticket, incoming: *ContentRef) !void {
        return self.stageReplacing(ticket, incoming, null);
    }
    pub fn stageReplacing(self: *Draft, ticket: Ticket, incoming: *ContentRef, replacement: ?Ticket) !void {
        defer incoming.release();
        _ = self.pendingIndex(ticket) orelse return error.StaleAttachment;
        if (self.candidate(ticket) != null) return error.StaleAttachment;
        try validateCompletion(ticket, incoming.*);
        var replaces: ?Id = null;
        var old_candidate: ?Ticket = null;
        if (replacement) |old| {
            if (!self.matchesConversation(old.owner, old.conversation_id) or old.draft_epoch != self.epoch or old.id == ticket.id) return error.StaleAttachment;
            if (self.candidate(old)) |previous| {
                replaces = previous.replaces;
                old_candidate = old;
            } else {
                var found = false;
                for (self.items.items) |item| if (item.id == old.id) {
                    found = true;
                    replaces = old.id;
                    break;
                };
                if (!found) return error.StaleAttachment;
            }
        }
        try self.candidates.ensureUnusedCapacity(self.allocator, 1);
        self.candidates.appendAssumeCapacity(.{ .id = ticket.id, .reference = incoming.retain(), .replaces = replaces });
        if (old_candidate) |old| _ = self.cancel(old);
    }
    /// Commit only an explicitly confirmed candidate. A replacement remains
    /// attached until all new allocations succeed and this commit is accepted.
    pub fn attach(self: *Draft, ticket: Ticket) !Id {
        const pending_index = self.pendingIndex(ticket) orelse return error.StaleAttachment;
        const selected = self.candidate(ticket) orelse return error.AttachmentNotReady;
        const content = selected.reference.content() orelse return error.EmptyAttachmentResult;
        // Confirming a remote preview attaches its locator, never preview bytes.
        var attached = if (content.source == .remote_file and !content.source.remote_file.reference_only)
            try ContentRef.createRemoteReference(self.allocator, content.source.remote_file.owner, content.source.remote_file.source_name, content.path)
        else
            selected.reference.retain();
        defer attached.release();
        try self.items.ensureUnusedCapacity(self.allocator, 1);
        self.items.appendAssumeCapacity(.{ .id = ticket.id, .reference = attached });
        attached = .{};
        _ = self.pending.orderedRemove(pending_index);
        self.removeCandidate(ticket.id);
        if (selected.replaces) |id| _ = self.remove(id);
        return ticket.id;
    }
    /// Always consumes incoming, including stale/duplicate/OOM completions.
    /// On failure existing text and attachments are untouched; caller may
    /// cancel the still-pending ticket after showing its actual read error.
    pub fn complete(self: *Draft, ticket: Ticket, incoming: *ContentRef) !Id {
        defer incoming.release();
        const index = self.pendingIndex(ticket) orelse return error.StaleAttachment;
        if (self.candidate(ticket) != null) return error.AttachmentAwaitingConfirmation;
        try validateCompletion(ticket, incoming.*);
        try self.items.ensureUnusedCapacity(self.allocator, 1);
        self.items.appendAssumeCapacity(.{ .id = ticket.id, .reference = incoming.retain() });
        _ = self.pending.orderedRemove(index);
        return ticket.id;
    }
    pub fn remove(self: *Draft, id: Id) bool {
        for (self.pending.items, 0..) |ticket, index| if (ticket.id == id) {
            _ = self.pending.orderedRemove(index);
            self.removeCandidate(id);
            return true;
        };
        for (self.items.items, 0..) |item, index| if (item.id == id) {
            var removed = self.items.orderedRemove(index);
            removed.reference.release();
            return true;
        };
        return false;
    }
    /// New conversation/cleared draft invalidates every outstanding ticket.
    pub fn clear(self: *Draft) !void {
        if (self.epoch == std.math.maxInt(u64)) return error.AttachmentEpochExhausted;
        self.epoch += 1;
        self.pending.clearRetainingCapacity();
        for (self.items.items) |*item| item.reference.release();
        self.items.clearRetainingCapacity();
        for (self.candidates.items) |*item| item.reference.release();
        self.candidates.clearRetainingCapacity();
    }
    pub fn restore(self: *Draft, bundle: *const Bundle) !void {
        if (!self.matchesConversation(bundle.owner, bundle.conversation_id) and !(bundle.conversation_id == null and bundle.items.len == 0 and self.owner.eql(bundle.owner))) return error.StaleAttachmentBundle;
        if (self.epoch == std.math.maxInt(u64)) return error.AttachmentEpochExhausted;
        var next = try Draft.init(self.allocator, self.owner);
        next.conversation_id = self.conversation_id;
        errdefer next.deinit();
        next.epoch = self.epoch + 1;
        next.next_id = self.next_id;
        for (bundle.items) |item| {
            const ticket = try next.begin();
            var ref = item.reference.retain();
            defer ref.release();
            _ = try next.complete(ticket, &ref);
        }
        self.deinit();
        self.* = next;
    }
    /// Explicit user rewind/fork copies already-owned immutable content. It
    /// creates fresh tickets; the original conversation's pending jobs cannot
    /// complete into this draft. This never reads the original source again.
    pub fn restoreHistory(self: *Draft, bundle: *const Bundle) !void {
        var selected = bundle.*;
        selected.owner = self.owner;
        selected.conversation_id = self.conversation_id;
        try self.restore(&selected);
    }
    pub fn freeze(self: *const Draft) !Bundle {
        if (self.pending.items.len != 0) return error.AttachmentsProcessing;
        const items = try self.allocator.alloc(Item, self.items.items.len);
        for (self.items.items, items) |item, *copy| copy.* = .{ .id = item.id, .reference = item.reference.retain() };
        return .{ .allocator = self.allocator, .owner = self.owner, .conversation_id = self.conversation_id, .draft_epoch = self.epoch, .items = items };
    }
    /// Call only after the host accepts the frozen request. Do not clear a
    /// later selection or picker created while submission was in progress.
    pub fn consumeSent(self: *Draft, bundle: *const Bundle) !usize {
        if (!self.matchesConversation(bundle.owner, bundle.conversation_id) or self.epoch != bundle.draft_epoch) return error.StaleAttachmentBundle;
        var removed: usize = 0;
        for (bundle.items) |item| if (self.remove(item.id)) {
            removed += 1;
        };
        return removed;
    }
    fn pendingIndex(self: *const Draft, ticket: Ticket) ?usize {
        if (!self.matchesConversation(ticket.owner, ticket.conversation_id) or self.epoch != ticket.draft_epoch) return null;
        for (self.pending.items, 0..) |current, index| if (current.eql(ticket)) return index;
        return null;
    }
    fn matchesConversation(self: *const Draft, owner: Owner, conversation: ?@import("../host/identity.zig").ConversationId) bool {
        if (self.conversation_id) |id| return conversation != null and id.eql(conversation.?);
        return conversation == null and self.owner.eql(owner);
    }
    fn removeCandidate(self: *Draft, id: Id) void {
        for (self.candidates.items, 0..) |item, index| if (item.id == id) {
            var removed = self.candidates.orderedRemove(index);
            removed.reference.release();
            return;
        };
    }
};

fn validateCompletion(ticket: Ticket, incoming: ContentRef) !void {
    const content = incoming.content() orelse return error.EmptyAttachmentResult;
    if (ticket.terminal_owner) |expected| {
        if (content.source != .terminal or !content.source.terminal.owner.eql(expected)) return error.StaleAttachment;
    } else if (content.source == .terminal) return error.InvalidTerminalAttachmentTicket;
}

fn freeSource(allocator: std.mem.Allocator, source: Source) void {
    switch (source) {
        .local_file, .local_reference => {},
        .remote_file => |remote| {
            allocator.free(remote.source_name);
            if (remote.actual_path) |path_value| allocator.free(path_value);
        },
        .terminal => |terminal| {
            allocator.free(terminal.source_name);
            if (terminal.origin == .command) allocator.free(terminal.origin.command.command);
        },
    }
}
