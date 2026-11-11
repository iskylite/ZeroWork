//! Resolve host-local paths before access decisions. Directory preference
//! chooses a base; it is never an authority or containment boundary.
const std = @import("std");
const workspace = @import("local_workspace.zig");
const ConversationId = @import("identity.zig").ConversationId;

pub const Identity = workspace.Identity;
pub const Source = enum { fixed_reference, absolute, explicit_base, workspace, local_cwd };
pub const Mode = enum { file, create, directory };
pub const max_create_parents = 16;
pub const recovery_prefix = ".zerowork-file-";
pub const recovery_suffix = ".tmp";

pub fn isRecoveryName(name: []const u8) bool {
    if (name.len != recovery_prefix.len + 32 + recovery_suffix.len or
        !std.mem.startsWith(u8, name, recovery_prefix) or
        !std.mem.endsWith(u8, name, recovery_suffix)) return false;
    for (name[recovery_prefix.len..][0..32]) |byte| {
        switch (byte) {
            '0'...'9', 'a'...'f' => {},
            else => return false,
        }
    }
    return true;
}

fn isRecoveryPath(absolute: []const u8) bool {
    var parts = std.mem.splitScalar(u8, absolute, '/');
    while (parts.next()) |part| if (isRecoveryName(part)) return true;
    return false;
}

/// Indices into the canonical absolute target. The anchor already exists;
/// each subsequent prefix is one exact directory approved for creation.
pub const ParentPlan = struct {
    anchor_len: u16,
    count: u8,
    ends: [max_create_parents]u16 = @splat(0),

    pub fn validate(self: ParentPlan, absolute: []const u8) !void {
        if (self.count == 0 or self.count > max_create_parents or
            self.anchor_len == 0 or self.anchor_len >= absolute.len or !std.fs.path.isAbsolute(absolute))
            return error.InvalidParentCreationPlan;
        var components = std.mem.splitScalar(u8, absolute[1..], '/');
        while (components.next()) |part| if (!validComponent(part)) return error.InvalidParentCreationPlan;
        var previous: usize = self.anchor_len;
        for (self.ends[0..self.count]) |end| {
            const start = if (previous == 1) 1 else previous + 1;
            if (end <= start or end >= absolute.len or absolute[end] != '/' or
                (previous != 1 and absolute[previous] != '/') or
                !validComponent(absolute[start..end])) return error.InvalidParentCreationPlan;
            previous = end;
        }
        for (self.ends[self.count..]) |end| if (end != 0) return error.InvalidParentCreationPlan;
        if (previous != parentName(absolute).len) return error.InvalidParentCreationPlan;
    }

    pub fn prefix(self: ParentPlan, absolute: []const u8) []const u8 {
        return absolute[0..self.anchor_len];
    }

    pub fn parent(self: ParentPlan, absolute: []const u8, index: usize) []const u8 {
        return absolute[0..self.ends[index]];
    }

    pub fn component(self: ParentPlan, absolute: []const u8, index: usize) []const u8 {
        return std.fs.path.basename(self.parent(absolute, index));
    }
};

/// A host-issued record looked up within the current conversation. The
/// resolver accepts the record only after the caller has resolved its ID.
pub const Reference = struct {
    conversation: ConversationId,
    requested: []const u8,
    absolute: []const u8,
    identity: Identity,
};

pub const Options = struct {
    path: ?[]const u8 = null,
    file_ref: ?Reference = null,
    base_directory: ?[]const u8 = null,
    workspace: workspace.Snapshot = .{},
    home: ?[]const u8 = null,
    /// The caller supplies this only for a unique, authorized Local cwd.
    local_cwd: ?[]const u8 = null,
    conversation: ConversationId = .{},
    create_parents: bool = false,
    app_data_root: ?[]const u8 = null,
};

/// General file tools must use the notes service for the private store. Match
/// opened directory identities so aliases cannot change that boundary.
pub const NotesBoundary = struct {
    app: Identity,
    notes: ?Identity,

    pub fn open(io: std.Io, data_root: []const u8) !?NotesBoundary {
        const app = std.Io.Dir.openDirAbsolute(io, data_root, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer app.close(io);
        const app_identity = try Identity.of(app);
        const notes = app.openDir(io, "notes", .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.SymLinkLoop => return .{ .app = app_identity, .notes = null },
            else => return err,
        };
        defer notes.close(io);
        return .{ .app = app_identity, .notes = try Identity.of(notes) };
    }

    pub fn protectsChild(self: NotesBoundary, parent: Identity, name: []const u8) bool {
        return std.meta.eql(parent, self.app) and std.ascii.eqlIgnoreCase(name, "notes");
    }

    pub fn check(self: NotesBoundary, io: std.Io, parent: std.Io.Dir, name: []const u8) !void {
        var current_id = try Identity.of(parent);
        if (self.protectsChild(current_id, name)) return error.NotesStoreProtected;
        const protected = self.notes orelse return;
        var current = try parent.openDir(io, ".", .{});
        defer current.close(io);
        while (true) {
            if (std.meta.eql(current_id, protected)) return error.NotesStoreProtected;
            const ancestor = try current.openDir(io, "..", .{});
            const ancestor_id = Identity.of(ancestor) catch |err| {
                ancestor.close(io);
                return err;
            };
            current.close(io);
            current = ancestor;
            if (std.meta.eql(current_id, ancestor_id)) return;
            current_id = ancestor_id;
        }
    }
};

/// The deterministic attempted location, available even when a file is absent.
pub const Attempt = struct {
    requested: []const u8,
    base_directory: ?[]const u8,
    absolute: [:0]const u8,
    source: Source,
    workspace_revision: ?u64,

    pub fn deinit(self: Attempt, allocator: std.mem.Allocator) void {
        allocator.free(self.requested);
        if (self.base_directory) |base| allocator.free(base);
        allocator.free(self.absolute);
    }
};

const WorkspaceAnchor = struct { selected: []const u8, identity: Identity };

pub const Resolved = struct {
    requested: []const u8,
    base_directory: ?[]const u8,
    absolute: [:0]const u8,
    basename: [:0]const u8,
    source: Source,
    workspace_revision: ?u64,
    conversation: ConversationId,
    /// With a parent plan this handle pins the nearest existing ancestor.
    parent: std.Io.Dir,
    parent_identity: Identity,
    target_identity: ?Identity,
    mode: Mode,
    workspace_anchor: ?WorkspaceAnchor = null,
    parent_plan: ?ParentPlan = null,
    notes_boundary: ?NotesBoundary = null,

    pub fn deinit(self: Resolved, allocator: std.mem.Allocator, io: std.Io) void {
        self.parent.close(io);
        allocator.free(self.requested);
        if (self.base_directory) |base| allocator.free(base);
        allocator.free(self.absolute);
        if (self.workspace_anchor) |anchor| allocator.free(anchor.selected);
    }

    pub fn reference(self: Resolved) !Reference {
        if (self.mode != .file or !self.conversation.valid()) return error.InvalidFileReference;
        return .{
            .conversation = self.conversation,
            .requested = self.requested,
            .absolute = self.absolute,
            .identity = self.target_identity orelse return error.InvalidFileReference,
        };
    }

    pub fn existingParentPath(self: Resolved) []const u8 {
        return if (self.parent_plan) |plan| plan.prefix(self.absolute) else parentName(self.absolute);
    }

    pub fn plannedParents(self: Resolved, out: *[max_create_parents][]const u8) []const []const u8 {
        const plan = self.parent_plan orelse return &.{};
        for (out[0..plan.count], 0..) |*item, index| item.* = plan.parent(self.absolute, index);
        return out[0..plan.count];
    }

    pub fn revalidateParent(self: Resolved, io: std.Io) !void {
        const path = self.existingParentPath();
        const current = std.Io.Dir.openDirAbsolute(io, path, .{ .follow_symlinks = false }) catch |err| return sourceError(err);
        defer current.close(io);
        if (!std.meta.eql(try Identity.of(current), self.parent_identity) or
            !std.meta.eql(try Identity.of(self.parent), self.parent_identity))
            return error.SourceChanged;
        if (self.notes_boundary) |boundary| {
            const name = if (self.parent_plan) |plan| blk: {
                try plan.validate(self.absolute);
                break :blk plan.component(self.absolute, 0);
            } else self.basename;
            try boundary.check(io, self.parent, name);
        }
    }

    pub fn revalidate(self: Resolved, io: std.Io) !void {
        if (self.workspace_anchor) |anchor| try verifyWorkspace(io, anchor.selected, self.base_directory.?, anchor.identity);
        try self.revalidateParent(io);
        if (self.parent_plan) |plan| {
            try plan.validate(self.absolute);
            const first = plan.component(self.absolute, 0);
            var name: [std.Io.Dir.max_name_bytes:0]u8 = undefined;
            @memcpy(name[0..first.len], first);
            name[first.len] = 0;
            if (statAt(self.parent, name[0..first.len :0], false)) |_| {
                return error.SourceChanged;
            } else |err| {
                if (err != error.FileNotFound) return err;
            }
            return;
        }
        const current = statAt(self.parent, self.basename, false) catch |err| switch (err) {
            error.FileNotFound => {
                if (self.target_identity == null) return;
                return error.SourceChanged;
            },
            else => return err,
        };
        if (self.target_identity) |expected| {
            const expected_kind: @TypeOf(current.mode) = if (self.mode == .directory) std.c.S.IFDIR else std.c.S.IFREG;
            if (current.mode & std.c.S.IFMT != expected_kind or
                !std.meta.eql(Identity.fromStat(current), expected))
                return error.SourceChanged;
        } else return error.PathAlreadyExists;
    }

    pub fn openFile(self: Resolved, io: std.Io) !std.Io.File {
        const expected = self.target_identity orelse return error.FileNotFound;
        if (self.mode != .file) return error.NotRegularFile;
        try self.revalidate(io);
        const fd = while (true) {
            const rc = std.c.openat(self.parent.handle, self.basename, .{
                .NONBLOCK = true,
                .NOFOLLOW = true,
                .CLOEXEC = true,
                .NOCTTY = true,
            });
            switch (std.c.errno(rc)) {
                .SUCCESS => break rc,
                .INTR => continue,
                .NOENT, .LOOP, .NOTDIR => return error.SourceChanged,
                .ACCES, .PERM => return error.AccessDenied,
                .ISDIR => return error.SourceChanged,
                else => return error.FileOpenFailed,
            }
        };
        const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
        errdefer file.close(io);
        var stat: std.c.Stat = undefined;
        if (std.c.fstat(fd, &stat) != 0) return error.FileStatFailed;
        if (stat.mode & std.c.S.IFMT != std.c.S.IFREG or
            !std.meta.eql(Identity.fromStat(stat), expected)) return error.SourceChanged;
        return file;
    }

    pub fn openDirectory(self: Resolved, io: std.Io, iterate: bool) !std.Io.Dir {
        if (self.mode != .directory) return error.NotDir;
        try self.revalidate(io);
        const directory = self.parent.openDir(io, self.basename, .{ .iterate = iterate, .follow_symlinks = false }) catch |err| return sourceError(err);
        errdefer directory.close(io);
        if (!std.meta.eql(try Identity.of(directory), self.target_identity.?)) return error.SourceChanged;
        return directory;
    }
};

fn validPath(path: []const u8) !void {
    if (path.len == 0 or path.len >= std.Io.Dir.max_path_bytes or
        std.mem.indexOfScalar(u8, path, 0) != null or !std.unicode.utf8ValidateSlice(path))
        return error.InvalidFilePath;
}

fn validComponent(name: []const u8) bool {
    return name.len > 0 and name.len <= std.Io.Dir.max_name_bytes and
        !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..") and
        std.mem.indexOfAny(u8, name, "/\x00") == null;
}

fn validBase(path: []const u8) !void {
    try validPath(path);
    if (!std.fs.path.isAbsolute(path)) return error.InvalidBaseDirectory;
}

fn copyAttempt(
    allocator: std.mem.Allocator,
    requested: []const u8,
    base: ?[]const u8,
    path: []const u8,
    source: Source,
    workspace_revision: ?u64,
) !Attempt {
    const absolute = if (base) |value|
        try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ std.mem.trimEnd(u8, value, "/"), path }, 0)
    else
        try allocator.dupeSentinel(u8, path, 0);
    errdefer allocator.free(absolute);
    try validPath(absolute);
    const request_copy = try allocator.dupe(u8, requested);
    errdefer allocator.free(request_copy);
    return .{
        .requested = request_copy,
        .base_directory = if (base) |value| try allocator.dupe(u8, value) else null,
        .absolute = absolute,
        .source = source,
        .workspace_revision = workspace_revision,
    };
}

pub fn attempt(allocator: std.mem.Allocator, options: Options) !Attempt {
    if (options.file_ref) |ref| {
        if (options.path != null or options.base_directory != null) return error.PathArgumentConflict;
        if (!options.conversation.valid() or !options.conversation.eql(ref.conversation))
            return error.InvalidFileReference;
        try validBase(ref.absolute);
        return copyAttempt(allocator, ref.requested, null, ref.absolute, .fixed_reference, null);
    }
    // Omitted path means the selected base itself for directory operations.
    const path = options.path orelse ".";
    try validPath(path);
    if (std.fs.path.isAbsolute(path)) {
        if (options.base_directory != null) return error.PathArgumentConflict;
        return copyAttempt(allocator, path, null, path, .absolute, null);
    }
    if (path[0] == '~') {
        if (!std.mem.startsWith(u8, path, "~/")) return error.UnsupportedHomeExpansion;
        if (options.base_directory != null) return error.PathArgumentConflict;
        const home = options.home orelse return error.HomeDirectoryUnavailable;
        try validBase(home);
        return copyAttempt(allocator, path, home, path[2..], .absolute, null);
    }
    if (options.base_directory) |base| {
        try validBase(base);
        return copyAttempt(allocator, path, base, path, .explicit_base, null);
    }
    switch (options.workspace.availability) {
        .none => {
            const cwd = options.local_cwd orelse return error.RelativeBaseUnavailable;
            try validBase(cwd);
            return copyAttempt(allocator, path, cwd, path, .local_cwd, null);
        },
        .unavailable => return error.WorkspaceUnavailable,
        .ready => {
            const base = options.workspace.resolved_directory orelse return error.WorkspaceUnavailable;
            try validBase(base);
            return copyAttempt(allocator, path, base, path, .workspace, options.workspace.revision);
        },
    }
}

fn sourceError(err: anyerror) anyerror {
    return switch (err) {
        error.FileNotFound, error.NotDir, error.SymLinkLoop => error.SourceChanged,
        else => err,
    };
}

fn parentName(absolute: []const u8) []const u8 {
    return std.fs.path.dirname(absolute) orelse "/";
}

fn statAt(dir: std.Io.Dir, name: [:0]const u8, follow: bool) !std.c.Stat {
    var stat: std.c.Stat = undefined;
    while (true) {
        const rc = std.c.fstatat(dir.handle, name, &stat, if (follow) 0 else std.c.AT.SYMLINK_NOFOLLOW);
        switch (std.c.errno(rc)) {
            .SUCCESS => return stat,
            .INTR => continue,
            .ACCES, .PERM => return error.AccessDenied,
            .NOENT => return error.FileNotFound,
            .LOOP => return error.SymLinkLoop,
            .NOTDIR => return error.NotDir,
            .NAMETOOLONG => return error.NameTooLong,
            else => return error.FileStatFailed,
        }
    }
}

fn verifyDirectory(io: std.Io, path: []const u8, identity: Identity, follow: bool) !void {
    const dir = std.Io.Dir.openDirAbsolute(io, path, .{ .follow_symlinks = follow }) catch |err| switch (err) {
        error.Canceled => return error.Cancelled,
        else => return error.WorkspaceUnavailable,
    };
    defer dir.close(io);
    if (!std.meta.eql(try Identity.of(dir), identity)) return error.WorkspaceUnavailable;
}

fn verifyWorkspace(io: std.Io, selected: []const u8, resolved: []const u8, identity: Identity) !void {
    try verifyDirectory(io, resolved, identity, false);
    if (!std.mem.eql(u8, selected, resolved)) try verifyDirectory(io, selected, identity, true);
}

const CreatePath = struct {
    absolute: [:0]u8,
    requested_anchor: []const u8,
    parent_plan: ?ParentPlan,
};

fn canonicalCreate(allocator: std.mem.Allocator, io: std.Io, selected: Attempt, create_parents: bool) !CreatePath {
    const cwd = std.Io.Dir.cwd();
    var prefix = parentName(selected.absolute);
    var reversed: [max_create_parents][]const u8 = undefined;
    var count: usize = 0;
    const existing = while (true) {
        if (cwd.realPathFileAlloc(io, prefix, allocator)) |canonical| break canonical else |err| {
            if (err != error.FileNotFound) return err;
            if (!create_parents) return error.ParentDirectoryNotFound;
        }
        var component_path: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
        @memcpy(component_path[0..prefix.len], prefix);
        component_path[prefix.len] = 0;
        if (statAt(cwd, component_path[0..prefix.len :0], false)) |entry| {
            if (entry.mode & std.c.S.IFMT == std.c.S.IFLNK) return error.DanglingSymlink;
            return error.SourceChanged;
        } else |err| {
            if (err != error.FileNotFound) return err;
        }
        const component = std.fs.path.basename(prefix);
        if (!std.mem.eql(u8, component, ".")) {
            if (!validComponent(component)) return error.InvalidParentCreationPath;
            if (count == reversed.len) return error.ParentCreationLimit;
            reversed[count] = component;
            count += 1;
        }
        const next = parentName(prefix);
        if (std.mem.eql(u8, next, prefix)) return error.ParentDirectoryNotFound;
        prefix = next;
    };
    defer allocator.free(existing);
    try validBase(existing);

    var plan: ParentPlan = .{ .anchor_len = @intCast(existing.len), .count = @intCast(count) };
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var used = std.mem.trimEnd(u8, existing, "/").len;
    @memcpy(buffer[0..used], existing[0..used]);
    for (0..count) |index| {
        try appendComponent(&buffer, &used, reversed[count - 1 - index]);
        plan.ends[index] = @intCast(used);
    }
    try appendComponent(&buffer, &used, std.fs.path.basename(selected.absolute));
    return .{
        .absolute = try allocator.dupeSentinel(u8, buffer[0..used], 0),
        .requested_anchor = prefix,
        .parent_plan = if (count != 0) plan else null,
    };
}

fn appendComponent(buffer: *[std.Io.Dir.max_path_bytes]u8, used: *usize, component: []const u8) !void {
    if (!validComponent(component)) return error.InvalidFilePath;
    if (used.* + 1 + component.len >= buffer.len) return error.InvalidFilePath;
    buffer[used.*] = '/';
    used.* += 1;
    @memcpy(buffer[used.*..][0..component.len], component);
    used.* += component.len;
}

pub fn resolve(allocator: std.mem.Allocator, io: std.Io, options: Options, mode: Mode) !Resolved {
    const boundary = if (options.app_data_root) |root| try NotesBoundary.open(io, root) else null;
    return resolveWithNotesBoundary(allocator, io, options, mode, boundary);
}

pub fn resolveWithNotesBoundary(allocator: std.mem.Allocator, io: std.Io, options: Options, mode: Mode, boundary: ?NotesBoundary) !Resolved {
    if (mode != .directory and options.path == null and options.file_ref == null)
        return error.InvalidFilePath;
    if (options.file_ref != null and mode != .file) return error.PathArgumentConflict;
    if (options.create_parents and mode != .create) return error.InvalidParentCreationPath;
    const selected = try attempt(allocator, options);
    defer selected.deinit(allocator);
    if (options.create_parents) if (selected.base_directory) |base| {
        const verified = std.Io.Dir.openDirAbsolute(io, base, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.ParentDirectoryNotFound,
            else => return err,
        };
        verified.close(io);
    };
    const anchor: ?WorkspaceAnchor = if (selected.source == .workspace) blk: {
        const path = options.workspace.directory orelse return error.WorkspaceUnavailable;
        const identity = options.workspace.directory_identity orelse return error.WorkspaceUnavailable;
        try verifyWorkspace(io, path, selected.base_directory.?, identity);
        break :blk .{ .selected = try allocator.dupe(u8, path), .identity = identity };
    } else null;
    errdefer if (anchor) |value| allocator.free(value.selected);
    const cwd = std.Io.Dir.cwd();
    // Resolve the path in filesystem order. Lexically folding link/.. first
    // changes which directory an existing symlink traverses.
    const before: ?std.c.Stat = if (mode == .create) blk: {
        if (selected.absolute[selected.absolute.len - 1] == '/') return error.InvalidFilePath;
        const basename = std.fs.path.basename(selected.absolute);
        if (std.mem.eql(u8, basename, ".") or std.mem.eql(u8, basename, "..")) return error.InvalidFilePath;
        if (statAt(cwd, selected.absolute, false)) |_| return error.PathAlreadyExists else |err| {
            if (err != error.FileNotFound) return err;
        }
        break :blk null;
    } else statAt(cwd, selected.absolute, selected.source != .fixed_reference) catch |err| {
        if (selected.source == .fixed_reference) return sourceError(err);
        if (err == error.FileNotFound) {
            if (statAt(cwd, selected.absolute, false)) |entry| {
                if (entry.mode & std.c.S.IFMT == std.c.S.IFLNK) return error.DanglingSymlink;
            } else |_| {}
        }
        return err;
    };

    var create: ?CreatePath = null;
    const absolute = if (before) |stat| blk: {
        const expected_kind: @TypeOf(stat.mode) = if (mode == .directory) std.c.S.IFDIR else std.c.S.IFREG;
        if (stat.mode & std.c.S.IFMT != expected_kind)
            return if (selected.source == .fixed_reference) error.SourceChanged else if (mode == .directory) error.NotDir else error.NotRegularFile;
        break :blk try cwd.realPathFileAlloc(io, selected.absolute, allocator);
    } else blk: {
        create = try canonicalCreate(allocator, io, selected, options.create_parents);
        break :blk create.?.absolute;
    };
    errdefer allocator.free(absolute);
    try validPath(absolute);
    if (isRecoveryPath(absolute)) return error.ManagedRecoveryMaterial;
    const basename: [:0]const u8 = if (std.mem.eql(u8, absolute, "/"))
        "."
    else
        absolute[(std.mem.lastIndexOfScalar(u8, absolute, '/') orelse return error.InvalidFilePath) + 1 .. :0];
    const parent_plan = if (create) |plan| plan.parent_plan else null;
    const existing_parent = if (parent_plan) |plan| plan.prefix(absolute) else parentName(absolute);
    const parent = try std.Io.Dir.openDirAbsolute(io, existing_parent, .{ .follow_symlinks = false });
    errdefer parent.close(io);

    const requested = try allocator.dupe(u8, selected.requested);
    errdefer allocator.free(requested);
    const base = if (selected.base_directory) |value| try allocator.dupe(u8, value) else null;
    errdefer if (base) |value| allocator.free(value);
    const result: Resolved = .{
        .requested = requested,
        .base_directory = base,
        .absolute = absolute,
        .basename = basename,
        .source = selected.source,
        .workspace_revision = selected.workspace_revision,
        .conversation = options.conversation,
        .parent = parent,
        .parent_identity = try Identity.of(parent),
        .target_identity = if (before) |stat| Identity.fromStat(stat) else null,
        .mode = mode,
        .workspace_anchor = anchor,
        .parent_plan = parent_plan,
        .notes_boundary = boundary,
    };
    if (options.file_ref) |ref| {
        if (!std.mem.eql(u8, ref.absolute, absolute) or !std.meta.eql(ref.identity, result.target_identity.?))
            return error.SourceChanged;
    }
    try result.revalidate(io);
    if (before != null) {
        const after = statAt(cwd, selected.absolute, selected.source != .fixed_reference) catch |err| return sourceError(err);
        if (!std.meta.eql(Identity.fromStat(after), result.target_identity.?)) return error.SourceChanged;
    } else {
        // Resolve the requested parent again before publishing the frozen
        // target. A retargeted symlink must not change which parent is used.
        const original_parent = try std.Io.Dir.openDirAbsolute(io, create.?.requested_anchor, .{});
        defer original_parent.close(io);
        if (!std.meta.eql(try Identity.of(original_parent), result.parent_identity)) return error.SourceChanged;
    }
    return result;
}

test "local path notes boundary preserves manual access and rejects managed private targets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "app/notes/library");
    try tmp.dir.createDirPath(io, "project/notes");
    try tmp.dir.writeFile(io, .{ .sub_path = "app/notes/library/fake.txt", .data = "test fixture" });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/notes/example.txt", .data = "test fixture" });
    try tmp.dir.symLink(io, "app/notes/library", "alias", .{ .is_directory = true });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const app_root = try tmp.dir.realPathFileAlloc(io, "app", a);

    var options: Options = .{ .base_directory = root, .app_data_root = app_root };
    for ([_][]const u8{ "app/notes/library/fake.txt", "alias/fake.txt" }) |path| {
        options.path = path;
        try std.testing.expectError(error.NotesStoreProtected, resolve(a, io, options, .file));
    }
    options.path = "app/notes";
    try std.testing.expectError(error.NotesStoreProtected, resolve(a, io, options, .directory));
    options.path = "app/notes/new/example.txt";
    options.create_parents = true;
    try std.testing.expectError(error.NotesStoreProtected, resolve(a, io, options, .create));
    options.create_parents = false;
    options.path = "project/notes/example.txt";
    const ordinary = try resolve(a, io, options, .file);
    defer ordinary.deinit(a, io);
    options.app_data_root = null;
    options.path = "app/notes/library/fake.txt";
    const manual = try resolve(a, io, options, .file);
    defer manual.deinit(a, io);

    try tmp.dir.createDirPath(io, "fresh-app");
    options.app_data_root = try tmp.dir.realPathFileAlloc(io, "fresh-app", a);
    options.path = "fresh-app/notes/library/created.txt";
    options.create_parents = true;
    try std.testing.expectError(error.NotesStoreProtected, resolve(a, io, options, .create));
}

test "local path priority uses real symlink ordering and never falls back from workspace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "project");
    try tmp.dir.createDirPath(io, "other/child");
    try tmp.dir.createDirPath(io, "terminal");
    try tmp.dir.writeFile(io, .{ .sub_path = "project/same.txt", .data = "project" });
    try tmp.dir.writeFile(io, .{ .sub_path = "terminal/same.txt", .data = "terminal" });
    try tmp.dir.writeFile(io, .{ .sub_path = "terminal/only.txt", .data = "other base" });
    try tmp.dir.writeFile(io, .{ .sub_path = "other/same.txt", .data = "through symlink parent" });
    try tmp.dir.symLink(io, "../other/child", "project/link", .{ .is_directory = true });
    try tmp.dir.symLink(io, "../other/same.txt", "project/alias", .{});
    try tmp.dir.symLink(io, "absent", "project/dangling", .{});
    try tmp.dir.symLink(io, "loop", "project/loop", .{});
    const project = try tmp.dir.realPathFileAlloc(io, "project", allocator);
    const terminal = try tmp.dir.realPathFileAlloc(io, "terminal", allocator);
    const selected = try workspace.inspect(allocator, io, project);
    var options: Options = .{
        .path = "same.txt",
        .workspace = selected,
        .local_cwd = terminal,
        .conversation = ConversationId.generate(),
    };

    const preferred = try resolve(allocator, io, options, .file);
    defer preferred.deinit(allocator, io);
    try std.testing.expectEqual(Source.workspace, preferred.source);
    try std.testing.expectEqual(selected.revision, preferred.workspace_revision.?);

    options.base_directory = terminal;
    const explicit = try resolve(allocator, io, options, .file);
    defer explicit.deinit(allocator, io);
    try std.testing.expectEqual(Source.explicit_base, explicit.source);
    try std.testing.expectEqualStrings(try tmp.dir.realPathFileAlloc(io, "terminal/same.txt", allocator), explicit.absolute);
    options.path = explicit.absolute;
    try std.testing.expectError(error.PathArgumentConflict, resolve(allocator, io, options, .file));
    options.base_directory = null;
    options.home = terminal;
    options.path = "~/same.txt";
    const home = try resolve(allocator, io, options, .file);
    defer home.deinit(allocator, io);
    try std.testing.expectEqualStrings(explicit.absolute, home.absolute);
    options.path = "~somebody/same.txt";
    try std.testing.expectError(error.UnsupportedHomeExpansion, resolve(allocator, io, options, .file));
    options.path = "only.txt";
    try std.testing.expectError(error.FileNotFound, resolve(allocator, io, options, .file));
    const missing = try attempt(allocator, options);
    defer missing.deinit(allocator);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "{s}/only.txt", .{project}), missing.absolute);
    const create = try resolve(allocator, io, options, .create);
    defer create.deinit(allocator, io);
    try std.testing.expectEqualStrings(missing.absolute, create.absolute);
    options.path = "unknown/only.txt";
    try std.testing.expectError(error.ParentDirectoryNotFound, resolve(allocator, io, options, .create));
    options.path = "dangling";
    try std.testing.expectError(error.PathAlreadyExists, resolve(allocator, io, options, .create));
    try std.testing.expectError(error.DanglingSymlink, resolve(allocator, io, options, .file));
    options.path = "loop";
    try std.testing.expectError(error.SymLinkLoop, resolve(allocator, io, options, .file));

    options.path = "link/../same.txt";
    const through_parent = try resolve(allocator, io, options, .file);
    defer through_parent.deinit(allocator, io);
    try std.testing.expectEqualStrings(try tmp.dir.realPathFileAlloc(io, "other/same.txt", allocator), through_parent.absolute);
    options.path = "alias";
    const alias = try resolve(allocator, io, options, .file);
    defer alias.deinit(allocator, io);
    try std.testing.expectEqualStrings(through_parent.absolute, alias.absolute);

    options.workspace.availability = .unavailable;
    options.path = "same.txt";
    try std.testing.expectError(error.WorkspaceUnavailable, resolve(allocator, io, options, .file));
    options.path = null;
    options.file_ref = try alias.reference();
    const fixed = try resolve(allocator, io, options, .file);
    defer fixed.deinit(allocator, io);
    try std.testing.expectEqual(Source.fixed_reference, fixed.source);
    try std.testing.expectEqualStrings(alias.absolute, fixed.absolute);
    options.conversation = ConversationId.generate();
    try std.testing.expectError(error.InvalidFileReference, resolve(allocator, io, options, .file));
    options.conversation = fixed.conversation;
    try tmp.dir.writeFile(io, .{ .sub_path = "other/replacement.txt", .data = "new inode" });
    try tmp.dir.rename("other/replacement.txt", tmp.dir, "other/same.txt", io);
    try std.testing.expectError(error.SourceChanged, resolve(allocator, io, options, .file));
    try std.testing.expectError(error.SourceChanged, fixed.revalidate(io));

    options.file_ref = null;
    options.workspace = .{};
    options.path = "same.txt";
    const cwd = try resolve(allocator, io, options, .file);
    defer cwd.deinit(allocator, io);
    try std.testing.expectEqual(Source.local_cwd, cwd.source);
    try std.testing.expectEqualStrings(explicit.absolute, cwd.absolute);
    options.local_cwd = null;
    try std.testing.expectError(error.RelativeBaseUnavailable, resolve(allocator, io, options, .file));

    options.workspace = selected;
    try tmp.dir.rename("project", tmp.dir, "old-project", io);
    try tmp.dir.createDirPath(io, "project");
    try tmp.dir.writeFile(io, .{ .sub_path = "project/same.txt", .data = "replacement directory" });
    try std.testing.expectError(error.WorkspaceUnavailable, resolve(allocator, io, options, .file));
    try std.testing.expectError(error.WorkspaceUnavailable, through_parent.revalidate(io));
}

test "local path parent creation is bounded and never invents a missing explicit base" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    var options: Options = .{ .path = "one/../target", .base_directory = base, .create_parents = true };
    try std.testing.expectError(error.InvalidParentCreationPath, resolve(a, io, options, .create));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "one", .{}));
    const prefixes_len = 2 * (max_create_parents + 1);
    var deep: [prefixes_len + "target".len]u8 = undefined;
    for (0..max_create_parents + 1) |index| @memcpy(deep[index * 2 ..][0..2], "p/");
    @memcpy(deep[prefixes_len..], "target");
    options.path = &deep;
    try std.testing.expectError(error.ParentCreationLimit, resolve(a, io, options, .create));
    options.base_directory = try std.fmt.allocPrint(a, "{s}/missing-base", .{base});
    options.path = "one/target";
    try std.testing.expectError(error.ParentDirectoryNotFound, resolve(a, io, options, .create));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "missing-base", .{}));
}
