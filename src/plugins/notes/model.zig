//! Committed note records. Names are user text; only stable IDs address files.
const std = @import("std");
const identity = @import("../../host/identity.zig");

pub const LibraryId = identity.NoteLibraryId;
pub const FolderId = identity.NoteFolderId;
pub const NoteId = identity.NoteId;

pub const max_directory_name = 80;
pub const max_title = 120;
pub const schema_version = 1;

pub const Folder = struct {
    id: FolderId,
    parent_id: ?FolderId,
    name: []const u8,
    sort_order: usize = 0,
    deleted_at: ?i64 = null,
};

pub const Library = struct {
    id: LibraryId,
    name: []const u8,
    ai_readable: bool = false,
    access_revision: u64 = 1,
    revision: u64 = 1,
    folders: []const Folder = &.{},
    deleted_at: ?i64 = null,

    pub fn folderIndex(self: Library, id: FolderId) ?usize {
        for (self.folders, 0..) |folder, i| {
            if (folder.id.eql(id)) return i;
        }
        return null;
    }

    pub fn folderVisible(self: Library, folder_id: ?FolderId) bool {
        if (self.deleted_at != null) return false;
        const id = folder_id orelse return true;
        const folder = self.folders[self.folderIndex(id) orelse return false];
        if (folder.deleted_at != null) return false;
        const parent = folder.parent_id orelse return true;
        const ancestor = self.folders[self.folderIndex(parent) orelse return false];
        return ancestor.deleted_at == null and ancestor.parent_id == null;
    }

    pub fn folderDepth(self: Library, folder_id: ?FolderId) ?u8 {
        const id = folder_id orelse return 0;
        const folder = self.folders[self.folderIndex(id) orelse return null];
        return if (folder.parent_id == null) 1 else 2;
    }

    pub fn containsFolder(self: Library, ancestor: ?FolderId, folder: ?FolderId) bool {
        const root = ancestor orelse return true;
        const id = folder orelse return false;
        if (root.eql(id)) return true;
        const entry = self.folders[self.folderIndex(id) orelse return false];
        return if (entry.parent_id) |parent| root.eql(parent) else false;
    }

    pub fn validate(self: Library) !void {
        if (!self.id.valid() or self.revision == 0 or self.access_revision == 0) return error.InvalidLibrary;
        try requireCanonicalName(self.name, max_directory_name);
        for (self.folders, 0..) |folder, i| {
            if (!folder.id.valid()) return error.InvalidFolder;
            try requireCanonicalName(folder.name, max_directory_name);
            if (folder.parent_id) |parent_id| {
                const parent = self.folders[self.folderIndex(parent_id) orelse return error.UnknownParent];
                // A folder has at most one ancestor folder. This also rejects cycles.
                if (parent.parent_id != null) return error.FolderDepthExceeded;
            }
            for (self.folders[0..i]) |other| {
                if (folder.id.eql(other.id)) return error.DuplicateFolder;
                if (std.meta.eql(folder.parent_id, other.parent_id) and
                    std.mem.eql(u8, folder.name, other.name) and
                    self.folderVisible(folder.id) and self.folderVisible(other.id))
                {
                    return error.NameConflict;
                }
            }
        }
    }
};

pub const NoteKey = struct {
    library_id: LibraryId,
    note_id: NoteId,
};

pub const Note = struct {
    schema_version: u32 = model_schema_version,
    id: NoteId,
    library_id: LibraryId,
    folder_id: ?FolderId,
    title: []const u8,
    body_md: []const u8 = "",
    read_only: bool = false,
    revision: u64 = 1,
    updated_at: i64,
    deleted_at: ?i64 = null,

    const model_schema_version = schema_version;

    pub fn key(self: Note) NoteKey {
        return .{ .library_id = self.library_id, .note_id = self.id };
    }

    pub fn validate(self: Note, library: Library) !void {
        if (self.schema_version != model_schema_version) return error.UnsupportedNoteVersion;
        if (!self.id.valid() or !self.library_id.eql(library.id) or self.revision == 0) return error.InvalidNote;
        if (self.folder_id) |folder_id| {
            if (library.folderIndex(folder_id) == null) return error.UnknownParent;
        }
        try requireCanonicalName(self.title, max_title);
        if (!std.unicode.utf8ValidateSlice(self.body_md)) return error.InvalidBody;
    }

    pub fn visible(self: Note, library: Library) bool {
        return self.deleted_at == null and library.folderVisible(self.folder_id);
    }
};

fn requireCanonicalName(raw: []const u8, max_chars: usize) !void {
    const clean = try normalizeName(raw, max_chars);
    if (clean.len != raw.len) return error.InvalidName;
}

pub fn normalizeName(raw: []const u8, max_chars: usize) ![]const u8 {
    var iter = (std.unicode.Utf8View.init(raw) catch return error.InvalidName).iterator();
    var start: ?usize = null;
    var end: usize = 0;
    var chars: usize = 0;
    var last_text_char: usize = 0;
    while (iter.nextCodepointSlice()) |bytes| {
        const point = std.unicode.utf8Decode(bytes) catch unreachable;
        if (point < 0x20 or (point >= 0x7f and point <= 0x9f)) return error.InvalidName;
        const space = switch (point) {
            0x20, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
            else => false,
        };
        if (start == null and space) continue;
        if (start == null) start = iter.i - bytes.len;
        chars += 1;
        if (!space) {
            end = iter.i;
            last_text_char = chars;
        }
    }
    if (last_text_char > max_chars) return error.NameTooLong;
    return raw[start orelse return error.InvalidName .. end];
}
