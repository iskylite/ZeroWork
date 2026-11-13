//! Application-owned drafts and leases. Only a Commit packet crosses to a
//! worker. Its receipt is applied to Sessions on the owner thread.
const std = @import("std");
const identity = @import("../../host/identity.zig");
const model = @import("model.zig");
const storage = @import("store.zig");
const Allocator = std.mem.Allocator;

pub const Lease = struct {
    key: model.NoteKey,
    owner: identity.SessionHandle,
    epoch: u64,
};
pub const Stamp = struct {
    lease: Lease,
    base_revision: u64,
    edit_generation: u64,
};
pub const Access = union(enum) {
    lease: Lease,
    occupied: identity.SessionHandle,
};
pub const SaveMode = enum { save, lock, unlock };
pub const Range = struct { start: usize, end: usize };
pub const ImportTicket = struct { stamp: Stamp, serial: u64 };

pub const Snapshot = struct {
    stamp: Stamp,
    timestamps: model.Timestamps,
    body_generation: u64,
    title: []const u8,
    body_md: []const u8,
    folder_id: ?model.FolderId,
    read_only: bool,
    dirty: bool,
    saving: ?SaveMode,
    save_error: ?anyerror,
    pending_import: ?Range,
    can_undo: bool,
    can_redo: bool,
};

const Request = struct {
    stamp: Stamp,
    mode: SaveMode,
    serial: u64,
};
pub const Receipt = struct {
    request: Request,
    result: anyerror!storage.Store.NoteCommit,
};
pub const Commit = struct {
    request: Request,
    draft: ?OwnedDraft,

    /// Dispatch exactly once. The caller owns this packet until the worker
    /// returns, then applies the receipt and frees the packet.
    pub fn run(self: Commit, store: *storage.Store) Receipt {
        const change: storage.NoteChange = switch (self.request.mode) {
            .save => .{ .save = self.draft.?.view() },
            .lock => .{ .lock = self.draft.?.view() },
            .unlock => .unlock,
        };
        const stamp = self.request.stamp;
        return .{ .request = self.request, .result = store.commitNote(stamp.lease.key, stamp.base_revision, change) };
    }

    pub fn failed(self: Commit, err: anyerror) Receipt {
        return .{ .request = self.request, .result = err };
    }

    pub fn deinit(self: *Commit, allocator: Allocator) void {
        if (self.draft) |draft| allocator.free(draft.bytes);
        self.* = undefined;
    }
};

const OwnedDraft = struct {
    bytes: []u8,
    title_len: usize,

    fn copy(allocator: Allocator, draft: storage.Draft) !OwnedDraft {
        return .{
            .bytes = try std.mem.concat(allocator, u8, &.{ draft.title, draft.body_md }),
            .title_len = draft.title.len,
        };
    }

    fn view(self: OwnedDraft) storage.Draft {
        return .{ .title = self.bytes[0..self.title_len], .body_md = self.bytes[self.title_len..] };
    }
};

const PendingImport = struct {
    ticket: ImportTicket,
    range: Range,
    edit_generation: u64,
};

const BodyChange = struct {
    start: usize,
    bytes: []u8,
    before_len: usize,

    fn before(self: BodyChange) []const u8 {
        return self.bytes[0..self.before_len];
    }

    fn after(self: BodyChange) []const u8 {
        return self.bytes[self.before_len..];
    }
};

const History = struct {
    changes: std.ArrayList(BodyChange) = .empty,
    generation: u64 = 1,
    applied: usize = 0,
    bytes: usize = 0,

    const max_changes = 64;
    const max_bytes = 2 * storage.max_note_bytes;

    fn deinit(self: *History, allocator: Allocator) void {
        self.truncate(allocator, 0);
        self.changes.deinit(allocator);
    }

    fn truncate(self: *History, allocator: Allocator, length: usize) void {
        while (self.changes.items.len > length) {
            const change = self.changes.pop().?;
            self.bytes -= change.bytes.len;
            allocator.free(change.bytes);
        }
        self.applied = @min(self.applied, length);
    }

    fn append(self: *History, allocator: Allocator, previous_generation: u64, current_generation: u64, change: ?BodyChange) void {
        if (self.generation != previous_generation) self.truncate(allocator, 0);
        self.generation = current_generation;
        const next = change orelse return;
        self.truncate(allocator, self.applied);
        while (self.changes.items.len >= max_changes or self.bytes + next.bytes.len > max_bytes) {
            const oldest = self.changes.orderedRemove(0);
            self.bytes -= oldest.bytes.len;
            allocator.free(oldest.bytes);
        }
        self.changes.appendAssumeCapacity(next);
        self.applied = self.changes.items.len;
        self.bytes += next.bytes.len;
    }
};

const Entry = struct {
    stamp: Stamp,
    timestamps: model.Timestamps,
    draft: OwnedDraft,
    folder_id: ?model.FolderId,
    read_only: bool,
    body_generation: u64 = 1,
    history: History = .{},
    dirty: bool = false,
    saving: ?Request = null,
    save_error: ?anyerror = null,
    due_ns: ?i128 = null,
    pending_import: ?PendingImport = null,
};

pub const Sessions = struct {
    allocator: Allocator,
    store: *storage.Store,
    thread: std.Thread.Id,
    entries: std.ArrayList(Entry) = .empty,
    next_serial: u64 = 1,

    pub const save_delay_ns = 500 * std.time.ns_per_ms;
    const max_live_sessions = 128;

    pub fn init(allocator: Allocator, store: *storage.Store) Sessions {
        return .{ .allocator = allocator, .store = store, .thread = std.Thread.getCurrentId() };
    }

    /// Close paths must first call releaseOwner. This tears down memory after
    /// workers have drained and is also usable during failed app startup.
    pub fn deinit(self: *Sessions) void {
        self.assertThread();
        for (self.entries.items) |*item| {
            std.debug.assert(item.saving == null);
            self.destroyEntry(item);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn open(self: *Sessions, key: model.NoteKey, owner: identity.SessionHandle) !Access {
        self.assertThread();
        if (@backingInt(owner.session_id) == 0 or owner.generation == 0) return error.InvalidOwner;
        for (self.entries.items) |entry| {
            if (!std.meta.eql(entry.stamp.lease.key, key)) continue;
            const lease = entry.stamp.lease;
            return if (lease.owner.eql(owner)) .{ .lease = lease } else .{ .occupied = lease.owner };
        }
        if (self.entries.items.len == max_live_sessions) return error.DocumentSessionLimit;
        const parsed = try self.store.loadNote(self.allocator, key, .active);
        defer parsed.deinit();
        const note = parsed.value;
        const lease: Lease = .{ .key = key, .owner = owner, .epoch = try self.issueSerial() };
        const draft = try OwnedDraft.copy(self.allocator, .{ .title = note.title, .body_md = note.body_md });
        errdefer self.allocator.free(draft.bytes);
        try self.entries.append(self.allocator, .{
            .stamp = .{ .lease = lease, .base_revision = note.revision, .edit_generation = 1 },
            .timestamps = note.timestamps(),
            .draft = draft,
            .folder_id = note.folder_id,
            .read_only = note.read_only,
        });
        return .{ .lease = lease };
    }

    /// Borrowed text lasts until the next edit or release of this document.
    pub fn snapshot(self: *Sessions, lease: Lease) !Snapshot {
        const entry = try self.entryFor(lease);
        const draft = entry.draft.view();
        return .{
            .stamp = entry.stamp,
            .timestamps = entry.timestamps,
            .body_generation = entry.body_generation,
            .title = draft.title,
            .body_md = draft.body_md,
            .folder_id = entry.folder_id,
            .read_only = entry.read_only,
            .dirty = entry.dirty or entry.pending_import != null,
            .saving = if (entry.saving) |saving| saving.mode else null,
            .save_error = entry.save_error,
            .pending_import = if (entry.pending_import) |pending| pending.range else null,
            .can_undo = !entry.read_only and entry.history.generation == entry.body_generation and entry.history.applied > 0,
            .can_redo = !entry.read_only and entry.history.generation == entry.body_generation and entry.history.applied < entry.history.changes.items.len,
        };
    }

    pub fn edit(self: *Sessions, stamp: Stamp, draft: storage.Draft) !void {
        const entry = try self.editable(stamp);
        const title = try model.normalizeName(draft.title, model.max_title);
        if (!std.unicode.utf8ValidateSlice(draft.body_md)) return error.InvalidBody;
        try self.replaceDraft(entry, .{ .title = title, .body_md = draft.body_md });
    }

    /// Active Textarea owns keystroke undo. At a stable block boundary the
    /// controller records only the change needed to undo it in another block.
    pub fn recordBodyChange(self: *Sessions, stamp: Stamp, previous_generation: u64, range: Range, previous_text: []const u8) !void {
        const entry = try self.editable(stamp);
        if (previous_generation == 0 or previous_generation > entry.body_generation) return error.StaleUndoBoundary;
        if (previous_generation == entry.body_generation) return;
        if (entry.history.generation == entry.body_generation) return error.StaleUndoBoundary;
        const body = entry.draft.view().body_md;
        if (!validRange(body, range)) return error.InvalidRange;
        if (!std.unicode.utf8ValidateSlice(previous_text)) return error.InvalidBody;
        const change = try self.prepareBodyChange(&entry.history, range.start, previous_text, body[range.start..range.end]);
        entry.history.append(self.allocator, previous_generation, entry.body_generation, change);
    }

    pub fn undo(self: *Sessions, stamp: Stamp) !bool {
        return self.applyHistory(stamp, false);
    }

    pub fn redo(self: *Sessions, stamp: Stamp) !bool {
        return self.applyHistory(stamp, true);
    }

    pub fn beginImport(self: *Sessions, stamp: Stamp, range: Range) !ImportTicket {
        const entry = try self.editable(stamp);
        if (entry.saving != null) return error.SaveInProgress;
        if (entry.pending_import != null) return error.ImportInProgress;
        if (!validRange(entry.draft.view().body_md, range)) return error.InvalidRange;
        const ticket: ImportTicket = .{ .stamp = stamp, .serial = try self.issueSerial() };
        entry.pending_import = .{ .ticket = ticket, .range = range, .edit_generation = stamp.edit_generation };
        return ticket;
    }

    /// The caller supplies the link only after the referenced asset is durable.
    /// The retained anchor is outside Markdown and cannot be committed to disk.
    pub fn completeImport(self: *Sessions, ticket: ImportTicket, markdown: []const u8) !void {
        const entry = try self.importEntry(ticket);
        if (!std.unicode.utf8ValidateSlice(markdown) or markdown.len == 0) return error.InvalidBody;
        const range = entry.pending_import.?.range;
        const body = entry.draft.view().body_md;
        const previous_generation = entry.body_generation;
        const change = try self.prepareBodyChange(&entry.history, range.start, body[range.start..range.end], markdown);
        errdefer if (change) |item| self.allocator.free(item.bytes);
        try self.replaceBodyRange(entry, range, markdown);
        entry.history.append(self.allocator, previous_generation, entry.body_generation, change);
        entry.pending_import = null;
    }

    /// The active editor records this insertion in its own undo history.
    pub fn completeImportInEditor(self: *Sessions, ticket: ImportTicket, markdown: []const u8) !void {
        const entry = try self.importEntry(ticket);
        if (!std.unicode.utf8ValidateSlice(markdown) or markdown.len == 0) return error.InvalidBody;
        try self.replaceBodyRange(entry, entry.pending_import.?.range, markdown);
        entry.pending_import = null;
    }

    pub fn cancelImport(self: *Sessions, ticket: ImportTicket) !void {
        const entry = try self.importEntry(ticket);
        entry.pending_import = null;
    }

    pub fn beginSave(self: *Sessions, lease: Lease, mode: SaveMode) !?Commit {
        const entry = try self.entryFor(lease);
        if (entry.saving != null) return error.SaveInProgress;
        if (entry.pending_import != null) return error.ImportInProgress;
        switch (mode) {
            .save => if (!entry.dirty) return null,
            .lock => if (entry.read_only) return null,
            .unlock => if (!entry.read_only) return null,
        }
        const request: Request = .{ .stamp = entry.stamp, .mode = mode, .serial = try self.issueSerial() };
        const draft = if (mode == .unlock) null else try OwnedDraft.copy(self.allocator, entry.draft.view());
        entry.saving = request;
        entry.due_ns = null;
        return .{ .request = request, .draft = draft };
    }

    /// Consume one due save for this controller; hidden presentations can
    /// dispatch this without doing layout or preview work.
    pub fn beginDueSave(self: *Sessions, owner: identity.SessionHandle) !?Commit {
        self.assertThread();
        const now = self.nowNs();
        for (self.entries.items) |entry| {
            if (!entry.stamp.lease.owner.eql(owner) or entry.saving != null or entry.pending_import != null) continue;
            if (entry.due_ns) |due| {
                if (due <= now) return self.beginSave(entry.stamp.lease, .save);
            }
        }
        return null;
    }

    pub fn finishSave(self: *Sessions, receipt: Receipt) !void {
        const entry = try self.entryFor(receipt.request.stamp.lease);
        const request = entry.saving orelse return error.StaleSave;
        if (!std.meta.eql(request, receipt.request)) return error.StaleSave;
        entry.saving = null;
        const committed = receipt.result catch |err| {
            entry.save_error = err;
            return err;
        };
        entry.stamp.base_revision = committed.revision;
        entry.timestamps = committed.timestamps;
        entry.save_error = null;
        switch (request.mode) {
            .save => {
                if (entry.stamp.edit_generation == request.stamp.edit_generation) entry.dirty = false;
            },
            .lock, .unlock => {
                entry.read_only = request.mode == .lock;
                entry.dirty = false;
            },
        }
    }

    pub fn flush(self: *Sessions, lease: Lease) !void {
        try self.commitNow(lease, .save);
    }

    pub fn setReadOnly(self: *Sessions, lease: Lease, enabled: bool) !void {
        try self.commitNow(lease, if (enabled) .lock else .unlock);
    }

    pub fn flushOwner(self: *Sessions, owner: identity.SessionHandle) !void {
        self.assertThread();
        for (self.entries.items) |entry| {
            if (entry.stamp.lease.owner.eql(owner)) try self.flush(entry.stamp.lease);
        }
    }

    pub fn release(self: *Sessions, lease: Lease) !void {
        try self.flush(lease);
        self.removeAt(try self.indexFor(lease));
    }

    pub fn releaseOwner(self: *Sessions, owner: identity.SessionHandle) !void {
        try self.flushOwner(owner);
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            if (self.entries.items[i].stamp.lease.owner.eql(owner)) self.removeAt(i);
        }
    }

    pub fn move(self: *Sessions, stamp: Stamp, folder_id: ?model.FolderId) !void {
        const entry = try self.editable(stamp);
        try self.flush(stamp.lease);
        const committed = try self.store.commitNote(stamp.lease.key, entry.stamp.base_revision, .{ .move = folder_id });
        entry.stamp.base_revision = committed.revision;
        entry.timestamps = committed.timestamps;
        entry.folder_id = folder_id;
    }

    pub fn delete(self: *Sessions, stamp: Stamp) !void {
        const entry = try self.editable(stamp);
        try self.flush(stamp.lease);
        _ = try self.store.changeNote(stamp.lease.key, entry.stamp.base_revision, .delete);
        self.removeAt(try self.indexFor(stamp.lease));
    }

    /// Directory mutations can check for open documents before affecting
    /// their paths. A query never exposes another controller's draft.
    pub fn ownerFor(self: *Sessions, key: model.NoteKey) ?identity.SessionHandle {
        self.assertThread();
        for (self.entries.items) |entry| {
            if (std.meta.eql(entry.stamp.lease.key, key)) return entry.stamp.lease.owner;
        }
        return null;
    }

    pub fn requireUnleasedSubtree(self: *Sessions, library: model.Library, folder_id: ?model.FolderId) !void {
        return self.requireUnleasedSubtreeExcept(library, folder_id, null);
    }

    /// A caller may retain its clean lease until the directory commit
    /// succeeds so a rejected delete leaves its editor and undo history live.
    pub fn requireUnleasedSubtreeExcept(self: *Sessions, library: model.Library, folder_id: ?model.FolderId, clean: ?Lease) !void {
        self.assertThread();
        for (self.entries.items) |entry| {
            if (!entry.stamp.lease.key.library_id.eql(library.id)) continue;
            if (!library.containsFolder(folder_id, entry.folder_id)) continue;
            if (clean) |lease| {
                if (std.meta.eql(entry.stamp.lease, lease) and !entry.dirty and entry.saving == null and entry.pending_import == null) continue;
            }
            return error.DocumentInUse;
        }
    }

    fn prepareBodyChange(self: *Sessions, history: *History, offset: usize, before: []const u8, after: []const u8) !?BodyChange {
        const span = changedSpan(before, after) orelse return null;
        const old_text = before[span.start..span.old_end];
        const new_text = after[span.start..span.new_end];
        if (old_text.len > History.max_bytes or new_text.len > History.max_bytes - old_text.len) return error.UndoLimit;
        try history.changes.ensureUnusedCapacity(self.allocator, 1);
        return .{
            .start = offset + span.start,
            .bytes = try std.mem.concat(self.allocator, u8, &.{ old_text, new_text }),
            .before_len = old_text.len,
        };
    }

    fn applyHistory(self: *Sessions, stamp: Stamp, forward: bool) !bool {
        const entry = try self.editable(stamp);
        if (entry.pending_import != null) return error.ImportInProgress;
        const history = &entry.history;
        if (history.generation != entry.body_generation) return error.UnrecordedBodyChange;
        if (forward) {
            if (history.applied == history.changes.items.len) return false;
        } else if (history.applied == 0) return false;
        const index = if (forward) history.applied else history.applied - 1;
        const change = history.changes.items[index];
        const original = if (forward) change.before() else change.after();
        const replacement = if (forward) change.after() else change.before();
        const body = entry.draft.view().body_md;
        const range: Range = .{ .start = change.start, .end = change.start + original.len };
        if (!validRange(body, range) or !std.mem.eql(u8, body[range.start..range.end], original)) return error.StaleUndoBoundary;
        try self.replaceBodyRange(entry, range, replacement);
        history.generation = entry.body_generation;
        history.applied = if (forward) index + 1 else index;
        return true;
    }

    fn replaceBodyRange(self: *Sessions, entry: *Entry, range: Range, replacement: []const u8) !void {
        const previous = entry.draft.view();
        const remaining = previous.body_md.len - (range.end - range.start);
        if (replacement.len > storage.max_note_bytes - remaining) return error.RecordTooLarge;
        const body = try std.mem.concat(self.allocator, u8, &.{ previous.body_md[0..range.start], replacement, previous.body_md[range.end..] });
        defer self.allocator.free(body);
        try self.replaceDraft(entry, .{ .title = previous.title, .body_md = body });
    }

    fn replaceDraft(self: *Sessions, entry: *Entry, draft: storage.Draft) !void {
        if (draft.body_md.len > storage.max_note_bytes) return error.RecordTooLarge;
        const previous = entry.draft.view();
        const body_changed = !std.mem.eql(u8, previous.body_md, draft.body_md);
        if (!body_changed and std.mem.eql(u8, previous.title, draft.title)) return;
        const generation = try identity.advance(entry.stamp.edit_generation);
        const body_generation = if (body_changed) try identity.advance(entry.body_generation) else entry.body_generation;
        const next = try OwnedDraft.copy(self.allocator, draft);
        if (entry.pending_import) |*pending| {
            if (!body_changed) {
                pending.edit_generation = generation;
            } else if (rebaseRange(previous.body_md, draft.body_md, pending.range)) |range| {
                pending.range = range;
                pending.edit_generation = generation;
            } else {
                entry.pending_import = null;
            }
        }
        self.allocator.free(entry.draft.bytes);
        entry.draft = next;
        entry.stamp.edit_generation = generation;
        entry.body_generation = body_generation;
        entry.dirty = true;
        entry.due_ns = self.nowNs() + save_delay_ns;
    }

    fn commitNow(self: *Sessions, lease: Lease, mode: SaveMode) !void {
        var packet = (try self.beginSave(lease, mode)) orelse return;
        defer packet.deinit(self.allocator);
        try self.finishSave(packet.run(self.store));
    }

    fn editable(self: *Sessions, stamp: Stamp) !*Entry {
        const entry = try self.entryFor(stamp.lease);
        if (entry.read_only) return error.ReadOnly;
        if (entry.saving) |saving| {
            if (saving.mode != .save) return error.SaveInProgress;
        }
        if (!std.meta.eql(entry.stamp, stamp)) return error.StaleEdit;
        return entry;
    }

    fn importEntry(self: *Sessions, ticket: ImportTicket) !*Entry {
        const entry = try self.entryFor(ticket.stamp.lease);
        _ = try self.editable(entry.stamp);
        const pending = entry.pending_import orelse return error.StaleImport;
        if (!std.meta.eql(pending.ticket, ticket) or
            entry.stamp.base_revision != ticket.stamp.base_revision or
            entry.stamp.edit_generation != pending.edit_generation)
        {
            return error.StaleImport;
        }
        return entry;
    }

    fn indexFor(self: *Sessions, lease: Lease) !usize {
        self.assertThread();
        for (self.entries.items, 0..) |entry, i| {
            if (std.meta.eql(entry.stamp.lease, lease)) return i;
        }
        return error.StaleLease;
    }

    fn entryFor(self: *Sessions, lease: Lease) !*Entry {
        return &self.entries.items[try self.indexFor(lease)];
    }

    fn removeAt(self: *Sessions, index: usize) void {
        var entry = self.entries.swapRemove(index);
        self.destroyEntry(&entry);
    }

    fn destroyEntry(self: *Sessions, entry: *Entry) void {
        self.allocator.free(entry.draft.bytes);
        entry.history.deinit(self.allocator);
    }

    fn issueSerial(self: *Sessions) !u64 {
        const serial = self.next_serial;
        self.next_serial = try identity.advance(serial);
        return serial;
    }

    fn nowNs(self: *Sessions) i128 {
        return std.Io.Clock.awake.now(self.store.io).toNanoseconds();
    }

    fn assertThread(self: *Sessions) void {
        std.debug.assert(self.thread == std.Thread.getCurrentId());
    }
};

fn validRange(body: []const u8, range: Range) bool {
    return range.start <= range.end and range.end <= body.len and
        isBoundary(body, range.start) and isBoundary(body, range.end);
}

fn isBoundary(body: []const u8, index: usize) bool {
    return index == body.len or body[index] & 0xc0 != 0x80;
}

/// A landed edit preserves the anchor if the original selection remains
/// outside the changed span. Editing through the anchor cancels the ticket.
fn rebaseRange(previous: []const u8, next: []const u8, range: Range) ?Range {
    const span = changedSpan(previous, next) orelse return range;
    if (range.end <= span.start) return range;
    if (range.start < span.old_end) return null;
    const rebased: Range = .{ .start = span.new_end + (range.start - span.old_end), .end = span.new_end + (range.end - span.old_end) };
    return if (validRange(next, rebased)) rebased else null;
}

fn changedSpan(previous: []const u8, next: []const u8) ?struct { start: usize, old_end: usize, new_end: usize } {
    var prefix = std.mem.indexOfDiff(u8, previous, next) orelse return null;
    while (!isBoundary(previous, prefix) or !isBoundary(next, prefix)) prefix -= 1;
    var old_end = previous.len;
    var new_end = next.len;
    while (old_end > prefix and new_end > prefix and previous[old_end - 1] == next[new_end - 1]) {
        old_end -= 1;
        new_end -= 1;
    }
    while (!isBoundary(previous, old_end) or !isBoundary(next, new_end)) {
        old_end += 1;
        new_end += 1;
    }
    return .{ .start = prefix, .old_end = old_end, .new_end = new_end };
}
