//! One application-owned repository for committed note records. The data
//! scope lock serializes processes; this mutex serializes in-process callers.
const std = @import("std");
const model = @import("model.zig");
const identity = @import("../../host/identity.zig");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const CancelToken = @import("../../ai/provider.zig").CancelToken;

const library_file = "library.json";
const documents_dir = "documents";
const private_dir: Dir.Permissions = @fromBackingInt(0o700);
const private_file: std.Io.File.Permissions = @fromBackingInt(0o600);
const max_library_bytes = 1024 * 1024;
pub const max_note_bytes = 8 * 1024 * 1024;

pub const Visibility = enum { active, include_deleted };

pub const LibraryChange = union(enum) {
    rename: []const u8,
    ai_readable: bool,
    delete,
    restore: ?[]const u8,
};

pub const FolderChange = union(enum) {
    rename: []const u8,
    move: ?model.FolderId,
    delete,
    restore: ?[]const u8,
};

pub const NoteChange = union(enum) {
    save: Draft,
    lock: Draft,
    unlock,
    move: ?model.FolderId,
    delete,
    restore,
};

pub const Draft = struct {
    title: []const u8,
    body_md: []const u8,
};

pub const QueryAccess = enum { user, assistant };

pub const QueryScope = struct {
    access: QueryAccess,
    library_ids: []const model.LibraryId = &.{},
    folder_id: ?model.FolderId = null,
    documents: union(enum) { none, children, descendants, one: model.NoteId },
};

pub const QueryFence = struct {
    library_id: model.LibraryId,
    library_revision: u64,
    access_revision: u64,
    documents_revision: ?u64,
    note_revision: ?u64 = null,
};

pub const QueryLibrary = struct {
    library: model.Library,
    notes: []const model.Note,
    fence: QueryFence,
};

const CachedNote = struct {
    record: std.json.Parsed(model.Note),
    cost: usize,
};

const max_query_cache_bytes = 32 * 1024 * 1024;

pub const Store = struct {
    allocator: Allocator,
    io: std.Io,
    libraries: Dir,
    mutex: std.Io.Mutex = .init,
    cached_notes: std.AutoHashMapUnmanaged(model.NoteKey, CachedNote) = .empty,
    cached_note_bytes: usize = 0,
    document_revisions: std.AutoHashMapUnmanaged(model.LibraryId, u64) = .empty,
    query_cursor_key: [32]u8,

    /// The composition root supplies an already-open private app data root and
    /// holds its process lock until this repository and its workers close.
    pub fn init(allocator: Allocator, io: std.Io, application_data: Dir) !Store {
        const notes = try ensureDir(io, application_data, "notes", false);
        defer notes.close(io);
        var query_cursor_key: [32]u8 = undefined;
        std.c.arc4random_buf(&query_cursor_key, query_cursor_key.len);
        return .{
            .allocator = allocator,
            .io = io,
            .libraries = try ensureDir(io, notes, "libraries", true),
            .query_cursor_key = query_cursor_key,
        };
    }

    pub fn deinit(self: *Store) void {
        self.clearCachedNotes();
        self.cached_notes.deinit(self.allocator);
        self.document_revisions.deinit(self.allocator);
        self.libraries.close(self.io);
        self.* = undefined;
    }

    pub fn createLibrary(self: *Store, raw_name: []const u8) !model.LibraryId {
        const name = try model.normalizeName(raw_name, model.max_directory_name);
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        try self.requireUniqueLibraryName(name, null);
        const id = model.LibraryId.generate();
        const component = idComponent(id);
        try self.libraries.createDir(self.io, &component, private_dir);
        errdefer self.libraries.deleteDir(self.io, &component) catch {};
        const directory = try self.openLibrary(id);
        defer directory.close(self.io);
        const library: model.Library = .{ .id = id, .name = name };
        try self.writeRecord(directory, library_file, library, max_library_bytes, false);
        return id;
    }

    pub fn loadLibrary(self: *Store, a: Allocator, id: model.LibraryId, visibility: Visibility) !std.json.Parsed(model.Library) {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const directory = try self.openLibrary(id);
        defer directory.close(self.io);
        const library = try self.readLibrary(a, directory, id);
        errdefer library.deinit();
        if (visibility == .active and library.value.deleted_at != null) return error.Unavailable;
        return library;
    }

    /// IDs are stable across changes. The caller owns the returned slice.
    pub fn listLibraryIds(self: *Store, a: Allocator, visibility: Visibility) ![]model.LibraryId {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var ids: std.ArrayList(model.LibraryId) = .empty;
        errdefer ids.deinit(a);
        var entries = self.libraries.iterate();
        while (try entries.next(self.io)) |entry| {
            const id = entryLibraryId(entry.name) orelse continue;
            const directory = try self.openLibrary(id);
            defer directory.close(self.io);
            const library = self.readLibrary(self.allocator, directory, id) catch |err| switch (err) {
                // A process can stop between creating the directory and
                // committing its first library record.
                error.FileNotFound => continue,
                else => return err,
            };
            defer library.deinit();
            if (visibility == .active and library.value.deleted_at != null) continue;
            try ids.append(a, id);
        }
        return ids.toOwnedSlice(a);
    }

    pub fn changeLibrary(self: *Store, id: model.LibraryId, expected_revision: u64, change: LibraryChange) !u64 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const directory = try self.openLibrary(id);
        defer directory.close(self.io);
        var record = try self.readLibrary(self.allocator, directory, id);
        defer record.deinit();
        const library = &record.value;
        try checkRevision(library.revision, expected_revision);
        if (library.deleted_at != null and change != .restore) return error.Unavailable;
        switch (change) {
            .rename => |raw_name| {
                const name = try model.normalizeName(raw_name, model.max_directory_name);
                if (std.mem.eql(u8, name, library.name)) return library.revision;
                try self.requireUniqueLibraryName(name, library.id);
                try self.requireNoProtectedNotes(directory, library.*, null);
                library.name = name;
            },
            .ai_readable => |enabled| {
                if (library.ai_readable == enabled) return library.revision;
                library.ai_readable = enabled;
                library.access_revision = try identity.advance(library.access_revision);
            },
            .delete => {
                try self.requireNoProtectedNotes(directory, library.*, null);
                library.deleted_at = self.now();
                library.access_revision = try identity.advance(library.access_revision);
            },
            .restore => |new_name| {
                if (library.deleted_at == null) return error.NotDeleted;
                const name = if (new_name) |raw| try model.normalizeName(raw, model.max_directory_name) else library.name;
                try self.requireUniqueLibraryName(name, library.id);
                if (!std.mem.eql(u8, name, library.name)) try self.requireNoProtectedNotes(directory, library.*, null);
                library.name = name;
                library.deleted_at = null;
                library.access_revision = try identity.advance(library.access_revision);
            },
        }
        return self.commitLibrary(directory, library);
    }

    pub fn createFolder(self: *Store, library_id: model.LibraryId, parent: ?model.FolderId, raw_name: []const u8, expected_revision: u64) !model.FolderId {
        const name = try model.normalizeName(raw_name, model.max_directory_name);
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const directory = try self.openLibrary(library_id);
        defer directory.close(self.io);
        var record = try self.readLibrary(self.allocator, directory, library_id);
        defer record.deinit();
        const library = &record.value;
        try checkRevision(library.revision, expected_revision);
        try requireVisibleFolder(library.*, parent);
        const id = model.FolderId.generate();
        const folders = try self.allocator.alloc(model.Folder, library.folders.len + 1);
        defer self.allocator.free(folders);
        @memcpy(folders[0..library.folders.len], library.folders);
        folders[folders.len - 1] = .{ .id = id, .parent_id = parent, .name = name, .sort_order = folders.len - 1 };
        library.folders = folders;
        _ = try self.commitLibrary(directory, library);
        return id;
    }

    pub fn changeFolder(self: *Store, library_id: model.LibraryId, id: model.FolderId, expected_revision: u64, change: FolderChange) !u64 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const directory = try self.openLibrary(library_id);
        defer directory.close(self.io);
        var record = try self.readLibrary(self.allocator, directory, library_id);
        defer record.deinit();
        const library = &record.value;
        try checkRevision(library.revision, expected_revision);
        const i = library.folderIndex(id) orelse return error.Unavailable;
        const folders = try self.allocator.dupe(model.Folder, library.folders);
        defer self.allocator.free(folders);
        library.folders = folders;
        const folder = &folders[i];
        if (change != .restore) try requireVisibleFolder(library.*, id);
        switch (change) {
            .rename => |raw_name| {
                const name = try model.normalizeName(raw_name, model.max_directory_name);
                if (std.mem.eql(u8, name, folder.name)) return library.revision;
                try self.requireNoProtectedNotes(directory, library.*, id);
                folder.name = name;
            },
            .move => |target| {
                try requireVisibleFolder(library.*, target);
                if (std.meta.eql(folder.parent_id, target)) return library.revision;
                try self.requireNoProtectedNotes(directory, library.*, id);
                folder.parent_id = target;
            },
            .delete => {
                try self.requireNoProtectedNotes(directory, library.*, id);
                folder.deleted_at = self.now();
            },
            .restore => |new_name| {
                if (folder.deleted_at == null) return error.NotDeleted;
                if (!library.folderVisible(folder.parent_id)) return error.ParentDeleted;
                if (new_name) |raw_name| {
                    const name = try model.normalizeName(raw_name, model.max_directory_name);
                    if (!std.mem.eql(u8, name, folder.name)) try self.requireNoProtectedNotes(directory, library.*, id);
                    folder.name = name;
                }
                folder.deleted_at = null;
            },
        }
        return self.commitLibrary(directory, library);
    }

    pub fn createNote(self: *Store, library_id: model.LibraryId, folder_id: ?model.FolderId, raw_title: []const u8) !model.NoteKey {
        const title = try model.normalizeName(raw_title, model.max_title);
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const directory = try self.openLibrary(library_id);
        defer directory.close(self.io);
        const library = try self.readLibrary(self.allocator, directory, library_id);
        defer library.deinit();
        try requireVisibleFolder(library.value, folder_id);
        const created_at = self.now();
        const note: model.Note = .{
            .id = model.NoteId.generate(),
            .library_id = library_id,
            .folder_id = folder_id,
            .title = title,
            .created_at = created_at,
            .updated_at = created_at,
        };
        const documents = try ensureDir(self.io, directory, documents_dir, false);
        defer documents.close(self.io);
        const filename = noteFilename(note.id);
        const query_revision = try self.nextDocumentRevision(library_id);
        try self.writeRecord(documents, &filename, note, max_note_bytes, false);
        self.documentCommitted(note.key(), query_revision);
        return note.key();
    }

    pub fn loadNote(self: *Store, a: Allocator, key: model.NoteKey, visibility: Visibility) !std.json.Parsed(model.Note) {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const directory = try self.openLibrary(key.library_id);
        defer directory.close(self.io);
        const library = try self.readLibrary(self.allocator, directory, key.library_id);
        defer library.deinit();
        const documents = try self.openDocuments(directory, false);
        defer documents.close(self.io);
        const note = try self.readNote(a, documents, key.note_id, library.value);
        errdefer note.deinit();
        if (visibility == .active and !note.value.visible(library.value)) return error.Unavailable;
        return note;
    }

    /// IDs are scoped to the requested library. The caller owns the result.
    pub fn listNoteIds(self: *Store, a: Allocator, library_id: model.LibraryId, visibility: Visibility) ![]model.NoteId {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const directory = try self.openLibrary(library_id);
        defer directory.close(self.io);
        const library = try self.readLibrary(self.allocator, directory, library_id);
        defer library.deinit();
        if (visibility == .active and library.value.deleted_at != null) return error.Unavailable;
        const documents = self.openDocuments(directory, true) catch |err| switch (err) {
            error.FileNotFound => return a.alloc(model.NoteId, 0),
            else => return err,
        };
        defer documents.close(self.io);
        var ids: std.ArrayList(model.NoteId) = .empty;
        errdefer ids.deinit(a);
        var entries = documents.iterate();
        while (try entries.next(self.io)) |entry| {
            const id = entryNoteId(entry.name) orelse continue;
            const note = try self.readNote(self.allocator, documents, id, library.value);
            defer note.deinit();
            if (visibility == .active and !note.value.visible(library.value)) continue;
            try ids.append(a, id);
        }
        return ids.toOwnedSlice(a);
    }

    pub fn changeNote(self: *Store, key: model.NoteKey, expected_revision: u64, change: NoteChange) !u64 {
        return (try self.commitNote(key, expected_revision, change)).revision;
    }

    pub const NoteCommit = struct {
        revision: u64,
        timestamps: model.Timestamps,
    };

    /// Lock commits the full draft and protected state in the same record.
    pub fn commitNote(self: *Store, key: model.NoteKey, expected_revision: u64, change: NoteChange) !NoteCommit {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const directory = try self.openLibrary(key.library_id);
        defer directory.close(self.io);
        const library = try self.readLibrary(self.allocator, directory, key.library_id);
        defer library.deinit();
        const documents = try self.openDocuments(directory, false);
        defer documents.close(self.io);
        var record = try self.readNote(self.allocator, documents, key.note_id, library.value);
        defer record.deinit();
        const note = &record.value;
        try checkRevision(note.revision, expected_revision);
        if (change != .restore) {
            if (!note.visible(library.value)) return error.Unavailable;
            if (note.read_only and change != .unlock) return error.ReadOnly;
        }
        switch (change) {
            .save, .lock => |draft| {
                if (draft.body_md.len > max_note_bytes) return error.RecordTooLarge;
                note.title = try model.normalizeName(draft.title, model.max_title);
                note.body_md = draft.body_md;
                note.read_only = change == .lock;
            },
            .unlock => {
                if (!note.read_only) return .{ .revision = note.revision, .timestamps = note.timestamps() };
                note.read_only = false;
            },
            .move => |folder_id| {
                try requireVisibleFolder(library.value, folder_id);
                if (std.meta.eql(note.folder_id, folder_id)) return .{ .revision = note.revision, .timestamps = note.timestamps() };
                note.folder_id = folder_id;
            },
            .delete => note.deleted_at = self.now(),
            .restore => {
                if (note.deleted_at == null) return error.NotDeleted;
                if (!library.value.folderVisible(note.folder_id)) return error.ParentDeleted;
                note.deleted_at = null;
            },
        }
        note.created_at = note.timestamps().created_at;
        note.revision = try identity.advance(note.revision);
        note.updated_at = self.now();
        try note.validate(library.value);
        const filename = noteFilename(note.id);
        const query_revision = try self.nextDocumentRevision(key.library_id);
        try self.writeRecord(documents, &filename, note.*, max_note_bytes, true);
        self.documentCommitted(key, query_revision);
        return .{ .revision = note.revision, .timestamps = note.timestamps() };
    }

    /// Capture only the caller's current scope. Callers allocate in a query
    /// arena, then rank/format on their worker after the storage lock is released.
    pub fn captureQuery(self: *Store, a: Allocator, scope: QueryScope, cancel: ?*const CancelToken) ![]const QueryLibrary {
        try checkQueryCancel(cancel);
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var libraries: std.ArrayList(QueryLibrary) = .empty;
        if (scope.library_ids.len != 0) {
            for (scope.library_ids) |id| {
                if (try self.captureLibrary(a, id, scope, cancel)) |library| try libraries.append(a, library);
            }
        } else {
            var entries = self.libraries.iterate();
            while (try entries.next(self.io)) |entry| {
                try checkQueryCancel(cancel);
                const id = entryLibraryId(entry.name) orelse continue;
                if (try self.captureLibrary(a, id, scope, cancel)) |library| try libraries.append(a, library);
            }
        }
        try checkQueryCancel(cancel);
        std.mem.sort(QueryLibrary, libraries.items, {}, struct {
            fn less(_: void, lhs: QueryLibrary, rhs: QueryLibrary) bool {
                return std.mem.order(u8, &lhs.library.id.bytes, &rhs.library.id.bytes) == .lt;
            }
        }.less);
        return libraries.toOwnedSlice(a);
    }

    /// Recheck current authorization before the caller publishes a result.
    /// Permission failures take precedence over stale-revision diagnostics.
    pub fn revalidateQuery(self: *Store, access: QueryAccess, fences: []const QueryFence, target: ?model.NoteKey, cancel: ?*const CancelToken) !void {
        try checkQueryCancel(cancel);
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var changed = false;
        for (fences) |fence| {
            try checkQueryCancel(cancel);
            const directory = self.openLibrary(fence.library_id) catch |err| switch (err) {
                error.FileNotFound => return error.Unavailable,
                else => return err,
            };
            defer directory.close(self.io);
            const record = self.readLibrary(self.allocator, directory, fence.library_id) catch |err| switch (err) {
                error.FileNotFound => return error.Unavailable,
                else => return err,
            };
            defer record.deinit();
            const library = record.value;
            if (!queryAllowed(library, access)) return error.Unavailable;
            if (target) |key| if (key.library_id.eql(library.id)) {
                const documents = self.openDocuments(directory, false) catch |err| switch (err) {
                    error.FileNotFound => return error.Unavailable,
                    else => return err,
                };
                defer documents.close(self.io);
                const note = self.readNote(self.allocator, documents, key.note_id, library) catch |err| switch (err) {
                    error.FileNotFound => return error.Unavailable,
                    else => return err,
                };
                defer note.deinit();
                if (!note.value.visible(library)) return error.Unavailable;
                changed = changed or fence.note_revision != note.value.revision;
            };
            changed = changed or fence.library_revision != library.revision or fence.access_revision != library.access_revision;
            if (fence.documents_revision) |revision| {
                changed = changed or revision != self.document_revisions.get(library.id);
            }
        }
        try checkQueryCancel(cancel);
        if (changed) return error.RevisionChanged;
    }

    fn captureLibrary(self: *Store, a: Allocator, id: model.LibraryId, scope: QueryScope, cancel: ?*const CancelToken) !?QueryLibrary {
        try checkQueryCancel(cancel);
        const directory = self.openLibrary(id) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer directory.close(self.io);
        const record = self.readLibrary(self.allocator, directory, id) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer record.deinit();
        const library = record.value;
        if (!queryAllowed(library, scope.access) or !library.folderVisible(scope.folder_id)) return null;

        var notes: []const model.Note = &.{};
        var document_revision: ?u64 = null;
        if (scope.documents == .one) {
            notes = try self.captureDocuments(a, directory, library, scope, cancel);
            if (notes.len == 0) return null;
        } else if (scope.documents != .none) {
            const revision = try self.document_revisions.getOrPut(self.allocator, id);
            if (!revision.found_existing) revision.value_ptr.* = 1;
            document_revision = revision.value_ptr.*;
            notes = try self.captureDocuments(a, directory, library, scope, cancel);
        }

        const folders = try a.dupe(model.Folder, library.folders);
        for (folders) |*folder| folder.name = try a.dupe(u8, folder.name);
        var copy = library;
        copy.folders = folders;
        copy.name = try a.dupe(u8, copy.name);
        return .{
            .library = copy,
            .notes = notes,
            .fence = .{
                .library_id = id,
                .library_revision = library.revision,
                .access_revision = library.access_revision,
                .documents_revision = document_revision,
                .note_revision = if (scope.documents == .one) notes[0].revision else null,
            },
        };
    }

    fn captureDocuments(self: *Store, a: Allocator, directory: Dir, library: model.Library, scope: QueryScope, cancel: ?*const CancelToken) ![]const model.Note {
        const documents = self.openDocuments(directory, scope.documents != .one) catch |err| switch (err) {
            error.FileNotFound => return &.{},
            else => return err,
        };
        defer documents.close(self.io);
        var notes: std.ArrayList(model.Note) = .empty;
        if (scope.documents == .one) {
            const record = self.readNote(a, documents, scope.documents.one, library) catch |err| switch (err) {
                error.FileNotFound => return &.{},
                else => return err,
            };
            defer record.deinit();
            if (record.value.visible(library)) try notes.append(a, try copyQueryNote(a, record.value, true));
            return notes.toOwnedSlice(a);
        }
        var entries = documents.iterate();
        while (try entries.next(self.io)) |entry| {
            try checkQueryCancel(cancel);
            const id = entryNoteId(entry.name) orelse continue;
            const note = try self.cachedNote(documents, id, library);
            if (!note.visible(library) or !inQueryFolder(note, library, scope)) continue;
            try notes.append(a, try copyQueryNote(a, note, scope.documents == .descendants));
        }
        return notes.toOwnedSlice(a);
    }

    fn cachedNote(self: *Store, directory: Dir, id: model.NoteId, library: model.Library) !model.Note {
        const key: model.NoteKey = .{ .library_id = library.id, .note_id = id };
        if (self.cached_notes.get(key)) |cached| return cached.record.value;
        const record = try self.readNote(self.allocator, directory, id, library);
        errdefer record.deinit();
        const cost = record.value.body_md.len + record.value.title.len + 1024;
        if (self.cached_note_bytes + cost > max_query_cache_bytes) self.clearCachedNotes();
        try self.cached_notes.put(self.allocator, key, .{ .record = record, .cost = cost });
        self.cached_note_bytes += cost;
        return record.value;
    }

    fn clearCachedNotes(self: *Store) void {
        var entries = self.cached_notes.valueIterator();
        while (entries.next()) |entry| entry.record.deinit();
        self.cached_notes.clearRetainingCapacity();
        self.cached_note_bytes = 0;
    }

    fn nextDocumentRevision(self: *Store, id: model.LibraryId) !?u64 {
        return if (self.document_revisions.get(id)) |current| try identity.advance(current) else null;
    }

    fn documentCommitted(self: *Store, key: model.NoteKey, revision: ?u64) void {
        if (revision) |value| self.document_revisions.getPtr(key.library_id).?.* = value;
        if (self.cached_notes.fetchRemove(key)) |removed| {
            self.cached_note_bytes -= removed.value.cost;
            removed.value.record.deinit();
        }
    }

    fn now(self: *const Store) i64 {
        return std.Io.Clock.real.now(self.io).toMilliseconds();
    }

    pub fn openLibrary(self: *Store, id: model.LibraryId) !Dir {
        if (!id.valid()) return error.InvalidLibrary;
        const component = idComponent(id);
        return self.libraries.openDir(self.io, &component, .{ .follow_symlinks = false });
    }

    fn openDocuments(self: *Store, library: Dir, iterate: bool) !Dir {
        return library.openDir(self.io, documents_dir, .{ .follow_symlinks = false, .iterate = iterate });
    }

    fn readLibrary(self: *Store, a: Allocator, directory: Dir, id: model.LibraryId) !std.json.Parsed(model.Library) {
        const record = try self.readRecord(model.Library, a, directory, library_file, max_library_bytes);
        errdefer record.deinit();
        if (!record.value.id.eql(id)) return error.InvalidLibrary;
        try record.value.validate();
        return record;
    }

    fn readNote(self: *Store, a: Allocator, directory: Dir, id: model.NoteId, library: model.Library) !std.json.Parsed(model.Note) {
        if (!id.valid()) return error.InvalidNote;
        const filename = noteFilename(id);
        const record = try self.readRecord(model.Note, a, directory, &filename, max_note_bytes);
        errdefer record.deinit();
        if (!record.value.id.eql(id)) return error.InvalidNote;
        try record.value.validate(library);
        return record;
    }

    fn readRecord(self: *Store, comptime T: type, a: Allocator, directory: Dir, filename: []const u8, limit: usize) !std.json.Parsed(T) {
        const info = try directory.statFile(self.io, filename, .{ .follow_symlinks = false });
        if (info.kind != .file or info.nlink != 1) return error.InvalidRecordFile;
        if (info.size > limit) return error.RecordTooLarge;
        const file = try directory.openFile(self.io, filename, .{ .allow_directory = false, .follow_symlinks = false });
        defer file.close(self.io);
        const opened = try file.stat(self.io);
        if (opened.kind != .file or opened.nlink != 1 or opened.inode != info.inode) return error.InvalidRecordFile;
        var buffer: [4096]u8 = undefined;
        var reader = file.reader(self.io, &buffer);
        const bytes = reader.interface.allocRemaining(a, .limited(limit + 1)) catch |err| switch (err) {
            error.StreamTooLong => return error.RecordTooLarge,
            error.ReadFailed => return reader.err orelse err,
            else => return err,
        };
        defer a.free(bytes);
        if (bytes.len > limit) return error.RecordTooLarge;
        return std.json.parseFromSlice(T, a, bytes, .{ .allocate = .alloc_always });
    }

    fn writeRecord(self: *Store, directory: Dir, filename: []const u8, value: anytype, limit: usize, replace: bool) !void {
        const encoded = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        defer self.allocator.free(encoded);
        if (encoded.len > limit) return error.RecordTooLarge;
        var atomic = try directory.createFileAtomic(self.io, filename, .{ .replace = replace, .permissions = private_file });
        defer atomic.deinit(self.io);
        var buffer: [4096]u8 = undefined;
        var writer = atomic.file.writer(self.io, &buffer);
        try writer.interface.writeAll(encoded);
        try writer.interface.flush();
        try atomic.file.sync(self.io);
        if (replace) {
            try atomic.replace(self.io);
        } else {
            try atomic.link(self.io);
        }
    }

    fn commitLibrary(self: *Store, directory: Dir, library: *model.Library) !u64 {
        library.revision = try identity.advance(library.revision);
        try library.validate();
        try self.writeRecord(directory, library_file, library.*, max_library_bytes, true);
        return library.revision;
    }

    fn requireUniqueLibraryName(self: *Store, name: []const u8, exclude: ?model.LibraryId) !void {
        var entries = self.libraries.iterate();
        while (try entries.next(self.io)) |entry| {
            const id = entryLibraryId(entry.name) orelse continue;
            if (exclude != null and id.eql(exclude.?)) continue;
            const directory = try self.openLibrary(id);
            defer directory.close(self.io);
            const record = self.readLibrary(self.allocator, directory, id) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            defer record.deinit();
            if (record.value.deleted_at == null and std.mem.eql(u8, record.value.name, name)) return error.NameConflict;
        }
    }

    fn requireNoProtectedNotes(self: *Store, directory: Dir, library: model.Library, subtree: ?model.FolderId) !void {
        const documents = self.openDocuments(directory, true) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer documents.close(self.io);
        var entries = documents.iterate();
        while (try entries.next(self.io)) |entry| {
            const id = entryNoteId(entry.name) orelse continue;
            const note = try self.readNote(self.allocator, documents, id, library);
            defer note.deinit();
            if (!note.value.read_only) continue;
            const target = subtree orelse return error.ProtectedDocument;
            const folder = note.value.folder_id orelse continue;
            if (folder.eql(target)) return error.ProtectedDocument;
            const parent = library.folders[library.folderIndex(folder).?].parent_id;
            if (parent != null and parent.?.eql(target)) return error.ProtectedDocument;
        }
    }
};

fn checkQueryCancel(cancel: ?*const CancelToken) !void {
    if (cancel) |token| if (token.isCancelled()) return error.Cancelled;
}

fn queryAllowed(library: model.Library, access: QueryAccess) bool {
    return library.deleted_at == null and (access == .user or library.ai_readable);
}

fn inQueryFolder(note: model.Note, library: model.Library, scope: QueryScope) bool {
    if (scope.documents == .children) return std.meta.eql(note.folder_id, scope.folder_id);
    const root = scope.folder_id orelse return true;
    const id = note.folder_id orelse return false;
    if (id.eql(root)) return true;
    const folder = library.folders[library.folderIndex(id).?];
    return if (folder.parent_id) |parent| parent.eql(root) else false;
}

fn copyQueryNote(a: Allocator, source: model.Note, include_body: bool) !model.Note {
    var note = source;
    note.title = try a.dupe(u8, source.title);
    note.body_md = if (include_body) try a.dupe(u8, source.body_md) else "";
    return note;
}

fn ensureDir(io: std.Io, parent: Dir, name: []const u8, iterate: bool) !Dir {
    parent.createDir(io, name, private_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return parent.openDir(io, name, .{ .follow_symlinks = false, .iterate = iterate });
}

fn checkRevision(actual: u64, expected: u64) !void {
    if (actual != expected) return error.RevisionChanged;
}

fn requireVisibleFolder(library: model.Library, folder_id: ?model.FolderId) !void {
    if (!library.folderVisible(folder_id)) return error.Unavailable;
}

fn idComponent(id: anytype) [32]u8 {
    return std.fmt.bytesToHex(id.bytes, .lower);
}

fn noteFilename(id: model.NoteId) [37]u8 {
    return idComponent(id) ++ ".json".*;
}

fn entryLibraryId(name: []const u8) ?model.LibraryId {
    const id = model.LibraryId.parse(name) catch return null;
    if (!std.mem.eql(u8, &idComponent(id), name)) return null;
    return id;
}

fn entryNoteId(name: []const u8) ?model.NoteId {
    if (!std.mem.endsWith(u8, name, ".json")) return null;
    const id = model.NoteId.parse(name[0 .. name.len - ".json".len]) catch return null;
    if (!std.mem.eql(u8, &noteFilename(id), name)) return null;
    return id;
}
