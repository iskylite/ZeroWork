//! Stable global theme identities, owned import drafts and independent metadata.
const std = @import("std");
const importer = @import("imported_theme.zig");
const presets = @import("theme_presets.zig");

pub const max_import_bytes = 2 * 1024 * 1024;
pub const default_id = "dark";
pub const reset_id = "sauber";
pub const Source = enum { builtin, imported };
pub const Filter = enum { all, favorites, imported };
pub const UiTokens = struct {
    // Filled-action roles are independent of link/icon accents. Zero derives
    // compatible colours for imported and legacy palettes.
    action_accent: u32 = 0,
    action_accent_2: u32 = 0,
    action_danger: u32 = 0,
    app: u32,
    surface_1: u32,
    surface_2: u32,
    well: u32,
    well_border: u32,
    terminal: u32,
    overlay: u32,
    hover: u32,
    tab_on: u32,
    fg_1: u32,
    fg_2: u32,
    fg_3: u32,
    accent: u32,
    accent_ink: u32,
    ok: u32,
    ok_ink: u32,
    warn: u32,
    warn_ink: u32,
    danger: u32,
    danger_ink: u32,
    selection: u32,
    border: u32,
    shadow: u32,
};
pub const Record = struct {
    id: []u8,
    theme: importer.Theme,
    ui_tokens: UiTokens,
    source_kind: Source,
    managed_source: ?[]u8 = null,
    source_bytes: ?[]u8 = null,
    staged_for: ?u64 = null,
    favorite: bool = false,
    revision: u64 = 1,

    fn deinit(self: *Record, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        self.theme.deinit(allocator);
        if (self.managed_source) |path| allocator.free(path);
        if (self.source_bytes) |bytes| allocator.free(bytes);
        self.* = undefined;
    }
};
pub const ImportRequest = struct { draft_id: u64, operation_id: u64 };
pub const ImportResult = struct {
    request: ImportRequest,
    record: Record,
    pub fn deinit(self: *ImportResult, allocator: std.mem.Allocator) void {
        self.record.deinit(allocator);
        self.* = undefined;
    }
};
pub const References = struct { saved: []const u8, draft: []const u8 };
pub const Counts = struct { all: usize = 0, favorites: usize = 0, imported: usize = 0 };

/// A worker prepares managed copies before the shared configuration transaction.
/// On Save failure keep this receipt for retry, or abort it before deinit.
/// Only files created by this receipt can be removed by abort.
pub const Installation = struct {
    allocator: std.mem.Allocator,
    draft_id: u64,
    entries: []Entry,
    ready: bool = false,
    pub const Entry = struct { id: []u8, path: ?[]u8, created: bool = false };

    pub fn init(registry: *const Registry, draft_id: u64) !Installation {
        var entries: std.ArrayList(Entry) = .empty;
        errdefer {
            for (entries.items) |entry| {
                registry.allocator.free(entry.id);
                if (entry.path) |path| registry.allocator.free(path);
            }
            entries.deinit(registry.allocator);
        }
        for (registry.records.items) |record| {
            if (record.staged_for != draft_id) continue;
            var buffer: [80]u8 = undefined;
            const id = try registry.allocator.dupe(u8, record.id);
            errdefer registry.allocator.free(id);
            const path = try registry.allocator.dupe(u8, try importer.managedPath(record.id, &buffer));
            errdefer registry.allocator.free(path);
            try entries.append(registry.allocator, .{ .id = id, .path = path });
        }
        return .{ .allocator = registry.allocator, .draft_id = draft_id, .entries = try entries.toOwnedSlice(registry.allocator) };
    }
    pub fn deinit(self: *Installation) void {
        for (self.entries) |entry| {
            self.allocator.free(entry.id);
            if (entry.path) |path| self.allocator.free(path);
        }
        self.allocator.free(self.entries);
        self.* = undefined;
    }
    pub fn validate(self: Installation, registry: *const Registry) !void {
        if (registry.revision == std.math.maxInt(u64)) return error.RegistryRevisionExhausted;
        for (self.entries) |entry| {
            const record = registry.get(entry.id) orelse return error.StaleThemeInstallation;
            if (record.staged_for != self.draft_id or record.source_bytes == null) return error.StaleThemeInstallation;
        }
    }
    /// Worker only. Failure retains the receipt and draft, including any copies
    /// already prepared. The caller can retry or explicitly abort them.
    pub fn prepare(self: *Installation, io: std.Io, dir: std.Io.Dir, registry: *const Registry) !void {
        try self.validate(registry);
        for (self.entries) |*entry| {
            if (entry.created) continue;
            const record = registry.get(entry.id).?;
            var existing = importer.loadManaged(io, dir, self.allocator, entry.id) catch |err| switch (err) {
                error.FileNotFound => {
                    const bytes = try std.json.Stringify.valueAlloc(self.allocator, importer.Managed{ .name = record.theme.name, .source = record.source_bytes.? }, .{});
                    defer self.allocator.free(bytes);
                    var atomic = try dir.createFileAtomic(io, entry.path.?, .{ .make_path = true, .replace = false });
                    defer atomic.deinit(io);
                    try atomic.file.writePositionalAll(io, bytes, 0);
                    try atomic.file.sync(io);
                    try atomic.replace(io);
                    entry.created = true;
                    continue;
                },
                else => return err,
            };
            existing.deinit(self.allocator);
        }
        self.ready = true;
    }
    pub fn abort(self: *Installation, io: std.Io, dir: std.Io.Dir) !void {
        self.ready = false;
        for (self.entries) |*entry| {
            if (!entry.created) continue;
            dir.deleteFile(io, entry.path.?) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            entry.created = false;
        }
    }
    /// Call only after validate and successful atomic Config replacement, on the
    /// same controller thread. It allocates nothing and cannot fail.
    pub fn commit(self: *Installation, registry: *Registry) void {
        std.debug.assert(self.ready);
        for (self.entries) |*entry| {
            const record = registry.getMut(entry.id).?;
            std.debug.assert(record.staged_for == self.draft_id);
            record.managed_source = entry.path;
            entry.path = null;
            if (record.source_bytes) |bytes| registry.allocator.free(bytes);
            record.source_bytes = null;
            record.staged_for = null;
            entry.created = false;
        }
        if (self.entries.len != 0) registry.revision += 1;
    }
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(Record) = .empty,
    revision: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) !Registry {
        var self: Registry = .{ .allocator = allocator };
        errdefer self.deinit();
        for (presets.ids ++ [_][]const u8{ "catppuccin-mocha", "dracula", "dark-pro", "solarized-dark", "nord" }) |id| {
            const preset = builtinTheme(id);
            var colors = builtinTokens(id);
            if (presets.tokens(UiTokens, id) == null) {
                colors.app = preset.bg;
                colors.terminal = preset.bg;
                colors.fg_1 = preset.fg;
                colors.selection = preset.selection.?;
            }
            const owned_id = try allocator.dupe(u8, id);
            errdefer allocator.free(owned_id);
            const owned_name = try allocator.dupe(u8, preset.name);
            errdefer allocator.free(owned_name);
            var theme = preset;
            theme.name = owned_name;
            try self.records.append(allocator, .{ .id = owned_id, .source_kind = .builtin, .ui_tokens = colors, .theme = theme });
        }
        return self;
    }
    pub fn deinit(self: *Registry) void {
        for (self.records.items) |*record| record.deinit(self.allocator);
        self.records.deinit(self.allocator);
        self.* = undefined;
    }
    /// Owned memory-only snapshot for a metadata worker. The live registry is
    /// read only until its host publishes this snapshot at the UI boundary.
    pub fn clone(self: *const Registry) !Registry {
        var copy: Registry = .{ .allocator = self.allocator, .revision = self.revision };
        errdefer copy.deinit();
        for (self.records.items) |record| {
            var next = record;
            next.id = try self.allocator.dupe(u8, record.id);
            errdefer self.allocator.free(next.id);
            next.theme.name = try self.allocator.dupe(u8, record.theme.name);
            errdefer self.allocator.free(next.theme.name);
            next.managed_source = if (record.managed_source) |path| try self.allocator.dupe(u8, path) else null;
            errdefer if (next.managed_source) |path| self.allocator.free(path);
            next.source_bytes = if (record.source_bytes) |bytes| try self.allocator.dupe(u8, bytes) else null;
            errdefer if (next.source_bytes) |bytes| self.allocator.free(bytes);
            try copy.records.append(self.allocator, next);
        }
        return copy;
    }
    pub fn get(self: *const Registry, id: []const u8) ?*const Record {
        const canonical = importer.builtinId(id) orelse id;
        for (self.records.items) |*record| if (std.mem.eql(u8, record.id, canonical)) return record;
        return null;
    }
    fn getMut(self: *Registry, id: []const u8) ?*Record {
        for (self.records.items) |*record| if (std.mem.eql(u8, record.id, id)) return record;
        return null;
    }
    pub fn counts(self: Registry) Counts {
        var result: Counts = .{ .all = self.records.items.len };
        for (self.records.items) |record| {
            if (record.favorite) result.favorites += 1;
            if (record.source_kind == .imported) result.imported += 1;
        }
        return result;
    }
    pub fn matches(record: Record, filter: Filter, query: []const u8) bool {
        if (filter == .favorites and !record.favorite) return false;
        if (filter == .imported and record.source_kind != .imported) return false;
        if (query.len > record.theme.name.len) return false;
        for (0..record.theme.name.len - query.len + 1) |i|
            if (std.ascii.eqlIgnoreCase(record.theme.name[i..][0..query.len], query)) return true;
        return false;
    }
    /// Parsing belongs on a bounded worker. The result owns every byte and may
    /// be released without touching the registry if its request became stale.
    pub fn parseImport(allocator: std.mem.Allocator, request: ImportRequest, bytes: []const u8, display_name: []const u8) !ImportResult {
        if (bytes.len > max_import_bytes) return error.ThemeTooLarge;
        if (std.mem.trim(u8, display_name, " \t\r\n").len == 0 or !std.unicode.utf8ValidateSlice(display_name)) return error.InvalidThemeName;
        var theme = try importer.parse(allocator, bytes, display_name);
        errdefer theme.deinit(allocator);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const id = try std.fmt.allocPrint(allocator, "import:{s}", .{std.fmt.bytesToHex(digest, .lower)});
        errdefer allocator.free(id);
        const owned = try allocator.dupe(u8, bytes);
        return .{ .request = request, .record = .{ .id = id, .theme = theme, .ui_tokens = importedTokens(theme), .source_kind = .imported, .source_bytes = owned, .staged_for = request.draft_id } };
    }
    pub fn readImport(io: std.Io, dir: std.Io.Dir, allocator: std.mem.Allocator, request: ImportRequest, path: []const u8) !ImportResult {
        const bytes = try dir.readFileAlloc(io, path, allocator, .limited(max_import_bytes));
        defer allocator.free(bytes);
        return parseImport(allocator, request, bytes, std.fs.path.stem(path));
    }
    /// Always consumes result. Duplicate content reuses identity; matching a
    /// display name never overwrites another theme. An outdated import is inert.
    /// Results must use this registry's allocator, including on error paths.
    pub fn completeImport(self: *Registry, active: ?ImportRequest, result: *ImportResult) !?[]const u8 {
        errdefer {
            result.record.deinit(self.allocator);
            result.* = undefined;
        }
        if (active == null or active.?.draft_id != result.request.draft_id or active.?.operation_id != result.request.operation_id) {
            result.record.deinit(self.allocator);
            result.* = undefined;
            return null;
        }
        if (self.get(result.record.id)) |existing| {
            const id = existing.id;
            result.record.deinit(self.allocator);
            result.* = undefined;
            return id;
        }
        if (self.revision == std.math.maxInt(u64)) return error.RegistryRevisionExhausted;
        try self.records.append(self.allocator, result.record);
        result.* = undefined;
        self.revision += 1;
        return self.records.items[self.records.items.len - 1].id;
    }
    pub fn checkRemove(self: Registry, id: []const u8, expected_revision: u64, references: References) !void {
        if (expected_revision != self.revision) return error.StaleRegistryRevision;
        const record = self.get(id) orelse return error.UnknownTheme;
        if (record.source_kind == .builtin) return error.BuiltinThemeProtected;
        if (std.mem.eql(u8, id, references.saved)) return error.CurrentThemeProtected;
        if (std.mem.eql(u8, id, references.draft)) return error.DraftThemeProtected;
    }
    /// Only application-managed copies are removed. selectedPath is never a
    /// deletion target. On disk failure the record and its selection survive.
    pub fn remove(self: *Registry, io: std.Io, dir: std.Io.Dir, id: []const u8, expected_revision: u64, references: References) !void {
        try self.checkRemove(id, expected_revision, references);
        if (self.revision == std.math.maxInt(u64)) return error.RegistryRevisionExhausted;
        for (self.records.items, 0..) |record, i| if (std.mem.eql(u8, record.id, id)) {
            if (record.managed_source) |path| {
                var expected_buffer: [80]u8 = undefined;
                const expected = try importer.managedPath(record.id, &expected_buffer);
                if (!std.mem.eql(u8, path, expected)) return error.InvalidManagedThemePath;
                try dir.deleteFile(io, path);
            }
            var removed = self.records.orderedRemove(i);
            removed.deinit(self.allocator);
            self.revision += 1;
            return;
        };
    }
    /// This transaction only writes favorite metadata. Failure changes neither
    /// the favorite marker nor settings dirty/current theme state.
    pub fn favorite(self: *Registry, io: std.Io, dir: std.Io.Dir, metadata_path: []const u8, id: []const u8, expected_revision: u64, enabled: bool) !void {
        if (expected_revision != self.revision) return error.StaleRegistryRevision;
        const record = self.getMut(id) orelse return error.UnknownTheme;
        if (record.favorite == enabled) return;
        if (self.revision == std.math.maxInt(u64)) return error.RegistryRevisionExhausted;
        var buffer: [64 * 1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try writer.writeByte('[');
        for (self.records.items, 0..) |entry, i| {
            if (i != 0) try writer.writeByte(',');
            try std.json.Stringify.value(.{ .id = entry.id, .favorite = if (std.mem.eql(u8, entry.id, id)) enabled else entry.favorite }, .{}, &writer);
        }
        try writer.writeByte(']');
        var atomic = try dir.createFileAtomic(io, metadata_path, .{ .make_path = true, .replace = true });
        defer atomic.deinit(io);
        try atomic.file.writePositionalAll(io, writer.buffered(), 0);
        try atomic.file.sync(io);
        try atomic.replace(io);
        record.favorite = enabled;
        self.revision += 1;
        record.revision = self.revision;
    }
    pub fn loadFavorites(self: *Registry, io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
        const bytes = dir.readFileAlloc(io, path, self.allocator, .limited(64 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(bytes);
        const parsed = try std.json.parseFromSlice([]const struct { id: []const u8, favorite: bool }, self.allocator, bytes, .{});
        defer parsed.deinit();
        for (parsed.value) |entry| if (self.getMut(entry.id)) |record| {
            record.favorite = entry.favorite;
        };
    }
    pub fn loadInstalled(self: *Registry, io: std.Io, dir: std.Io.Dir) !void {
        var directory = dir.openDir(io, "themes", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer directory.close(io);
        var iterator = directory.iterate();
        while (try iterator.next(io)) |entry| {
            if (entry.kind != .file or entry.name.len != 69 or !std.mem.endsWith(u8, entry.name, ".json")) continue;
            const id = try std.fmt.allocPrint(self.allocator, "import:{s}", .{entry.name[0..64]});
            defer self.allocator.free(id);
            if (self.get(id) != null) continue;
            var path_buffer: [80]u8 = undefined;
            const path = try importer.managedPath(id, &path_buffer);
            var theme = try importer.loadManaged(io, dir, self.allocator, id);
            errdefer theme.deinit(self.allocator);
            const owned_id = try self.allocator.dupe(u8, id);
            errdefer self.allocator.free(owned_id);
            const owned_path = try self.allocator.dupe(u8, path);
            errdefer self.allocator.free(owned_path);
            try self.records.append(self.allocator, .{ .id = owned_id, .theme = theme, .ui_tokens = importedTokens(theme), .source_kind = .imported, .managed_source = owned_path });
            self.revision +|= 1;
        }
    }
    pub fn discard(self: *Registry, draft_id: u64) void {
        var i = self.records.items.len;
        while (i > 0) {
            i -= 1;
            if (self.records.items[i].staged_for == draft_id) {
                var removed = self.records.orderedRemove(i);
                removed.deinit(self.allocator);
                self.revision +|= 1;
            }
        }
    }
};

pub const LibraryState = struct {
    draft_id: u64,
    saved_theme_id: []const u8,
    draft_theme_id: []const u8,
    query: []const u8 = "",
    filter: Filter = .all,
    scroll: f32 = 0,
    selected_id: []const u8,
    registry_revision: u64,
    import_operation: ?ImportRequest = null,
    problem: ?anyerror = null,
    open: bool = false,
    query_storage: ?[]u8 = null,

    pub fn deinit(self: *LibraryState, allocator: std.mem.Allocator) void {
        if (self.query_storage) |query| allocator.free(query);
        self.* = undefined;
    }
    pub fn setQuery(self: *LibraryState, allocator: std.mem.Allocator, query: []const u8) !void {
        const owned = try allocator.dupe(u8, query);
        if (self.query_storage) |previous| allocator.free(previous);
        self.query_storage = owned;
        self.query = owned;
    }

    pub fn select(self: *LibraryState, registry: *const Registry, id: []const u8) !void {
        const record = registry.get(id) orelse return error.UnknownTheme;
        self.selected_id = record.id;
        self.draft_theme_id = record.id;
        self.registry_revision = registry.revision;
    }
};

fn importedTokens(theme: importer.Theme) UiTokens {
    const bright = ((theme.bg >> 24) & 255) + ((theme.bg >> 16) & 255) + ((theme.bg >> 8) & 255) > 384;
    var result = builtinTokens(if (bright) "light" else "dark");
    result.app = theme.bg;
    result.terminal = theme.bg;
    result.fg_1 = theme.fg;
    result.accent = theme.ansi[4];
    result.accent_ink = theme.ansi[12];
    result.action_accent = theme.ansi[4];
    result.action_accent_2 = theme.ansi[4];
    result.action_danger = result.danger;
    if (theme.selection) |selection| result.selection = selection;
    return result;
}

pub fn builtinTokens(id: []const u8) UiTokens {
    if (presets.tokens(UiTokens, id)) |colors| return colors;
    if (std.mem.eql(u8, id, "sauber")) return .{ .app = 0xd9eccfff, .surface_1 = 0xf2fdecff, .surface_2 = 0xecfbe5ff, .well = 0xe2f5daff, .well_border = 0xc9e4bdff, .terminal = 0xecffe5ff, .overlay = 0xf3ffefff, .hover = 0xdbf0d6ff, .tab_on = 0xf8fff4ff, .fg_1 = 0x0f172aff, .fg_2 = 0x46604fff, .fg_3 = 0x8aa396ff, .accent = 0x1345f6ff, .accent_ink = 0x1345f6ff, .ok = 0x10b981ff, .ok_ink = 0x0a714fff, .warn = 0xd49a0cff, .warn_ink = 0x7f5c07ff, .danger = 0xdc4c3fff, .danger_ink = 0xad3c32ff, .selection = 0x1345f617, .border = 0xc9e4bdff, .shadow = 0x14462324 };
    if (std.mem.eql(u8, id, "light")) return .{ .app = 0xe6e6eaff, .surface_1 = 0xfbfbfcff, .surface_2 = 0xf4f4f7ff, .well = 0xececf0ff, .well_border = 0xd9d9e0ff, .terminal = 0xfbfbfcff, .overlay = 0xffffffff, .hover = 0xececf1ff, .tab_on = 0xffffffff, .fg_1 = 0x18181bff, .fg_2 = 0x52525bff, .fg_3 = 0xa1a1aaff, .accent = 0x4f46e5ff, .accent_ink = 0x4f46e5ff, .ok = 0x16a34aff, .ok_ink = 0x107435ff, .warn = 0xd97706ff, .warn_ink = 0x985304ff, .danger = 0xdc2626ff, .danger_ink = 0xc32222ff, .selection = 0x4f46e517, .border = 0xd9d9e0ff, .shadow = 0x0f172a24 };
    return .{ .app = 0x060608ff, .surface_1 = 0x131316ff, .surface_2 = 0x1b1b1fff, .well = 0x0c0c0fff, .well_border = 0x26262cff, .terminal = 0x0a0a0dff, .overlay = 0x292a30ff, .hover = 0x202026ff, .tab_on = 0x1e1e23ff, .fg_1 = 0xf4f4f5ff, .fg_2 = 0xa1a1aaff, .fg_3 = 0x5b5b64ff, .accent = 0x6366f1ff, .accent_ink = 0x8c8ef5ff, .ok = 0x22c55eff, .ok_ink = 0x22c55eff, .warn = 0xf59e0bff, .warn_ink = 0xf59e0bff, .danger = 0xef4444ff, .danger_ink = 0xf36e6eff, .selection = 0x6366f124, .border = 0x26262cff, .shadow = 0x0000005c };
}
fn builtinAnsi(id: []const u8) [16]u32 {
    if (!std.mem.eql(u8, id, "sauber") and !std.mem.eql(u8, id, "dark") and !std.mem.eql(u8, id, "light")) if (presets.ansi(UiTokens, id)) |colors| return colors;
    if (std.mem.eql(u8, id, "sauber")) return .{ 0x0f172aff, 0xdc4c3fff, 0x10b981ff, 0xd49a0cff, 0x2563ebff, 0xc241e0ff, 0x06b6d4ff, 0xd6e2f0ff, 0x64748bff, 0xdd7975ff, 0x3fcd76ff, 0xc6bb00ff, 0xa7abf2ff, 0xe17ee1ff, 0x048b8fff, 0xa4801cff };
    // Existing VT engine default palette, used where the prototypes specify
    // semantic inks but do not define a complete raw ANSI palette.
    return .{ 0x1d1f21ff, 0xcc6666ff, 0xb5bd68ff, 0xf0c674ff, 0x81a2beff, 0xb294bbff, 0x8abeb7ff, 0xc5c8c6ff, 0x666666ff, 0xd54e53ff, 0xb9ca4aff, 0xe7c547ff, 0x7aa6daff, 0xc397d8ff, 0x70c0b1ff, 0xeaeaeaff };
}

fn builtinTheme(id: []const u8) importer.Theme {
    const colors = builtinTokens(id);
    var result: importer.Theme = .{ .name = "Vanta Dark", .bg = colors.terminal, .fg = colors.fg_1, .cursor = 0x818cf8ff, .selection = colors.selection, .ansi = builtinAnsi(id) };
    if (std.mem.eql(u8, id, "light")) {
        result.name = "Vanta Light";
        result.cursor = 0x4f46e5ff;
    }
    if (std.mem.eql(u8, id, "sauber")) {
        result.name = "Sauber";
        result.fg = 0x1345f6ff;
        result.cursor = 0x000000ff;
        result.selection = 0xb3d7ffff;
    }
    if (presets.tokens(UiTokens, id) != null and !std.mem.eql(u8, id, "dark") and !std.mem.eql(u8, id, "light") and !std.mem.eql(u8, id, "sauber")) {
        result.name = presets.name(id);
        result.cursor = colors.accent_ink;
    }
    // Preserve the terminal palettes that the existing implementation exposes;
    // the registry is now their global identity/lookup owner.
    if (std.mem.eql(u8, id, "catppuccin-mocha")) {
        result.name = "Catppuccin Mocha";
        result.bg = 0x1e1e2eff;
        result.fg = 0xcdd6f4ff;
        result.cursor = result.fg;
        result.selection = 0x585b70ff;
    }
    if (std.mem.eql(u8, id, "dracula")) {
        result.name = "Dracula";
        result.bg = 0x282a36ff;
        result.fg = 0xf8f8f2ff;
        result.cursor = result.fg;
        result.selection = 0x6272a4ff;
    }
    if (std.mem.eql(u8, id, "dark-pro")) {
        result.name = "Dark Pro";
        result.bg = 0x0f172aff;
        result.fg = 0xe2e8f0ff;
        result.cursor = result.fg;
        result.selection = 0x475569ff;
    }
    if (std.mem.eql(u8, id, "solarized-dark")) {
        result.name = "Solarized Dark";
        result.bg = 0x002b36ff;
        result.fg = 0x93a1a1ff;
        result.cursor = result.fg;
        result.selection = 0x586e75ff;
    }
    if (std.mem.eql(u8, id, "nord")) {
        result.name = "Nord";
        result.bg = 0x2e3440ff;
        result.fg = 0xd8dee9ff;
        result.cursor = result.fg;
        result.selection = 0x434c5eff;
    }
    return result;
}

fn testSource(allocator: std.mem.Allocator, red: []const u8) ![]u8 {
    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(allocator);
    for (0..19) |i| {
        const key = if (i < 16) try std.fmt.allocPrint(allocator, "Ansi {d} Color", .{i}) else try allocator.dupe(u8, ([_][]const u8{ "Background Color", "Foreground Color", "Cursor Color" })[i - 16]);
        defer allocator.free(key);
        const entry = try std.fmt.allocPrint(allocator, "<key>{s}</key><dict><key>Red Component</key><real>{s}</real><key>Green Component</key><real>0</real><key>Blue Component</key><real>0</real></dict>", .{ key, red });
        defer allocator.free(entry);
        try source.appendSlice(allocator, entry);
    }
    return source.toOwnedSlice(allocator);
}

test "registry keeps builtins and legacy aliases as real stable identities" {
    var registry = try Registry.init(std.testing.allocator);
    defer registry.deinit();
    try std.testing.expectEqual(@as(usize, 17), registry.counts().all);
    try std.testing.expectEqualStrings("catppuccin-mocha", registry.get("CATPPUCCIN_MOCHA").?.id);
    try std.testing.expectEqual(@as(u32, 0x282a36ff), registry.get("dracula").?.theme.bg);
    try std.testing.expectEqual(@as(u32, 0x000000ff), registry.get("sauber").?.theme.cursor);
    try std.testing.expect(registry.get("nord") != null);
    try std.testing.expectError(error.BuiltinThemeProtected, registry.checkRemove("dracula", registry.revision, .{ .saved = "dark", .draft = "light" }));
}

test "imports reject bad colors reuse identical content and retain same-name records" {
    const allocator = std.testing.allocator;
    var registry = try Registry.init(allocator);
    defer registry.deinit();
    const request: ImportRequest = .{ .draft_id = 5, .operation_id = 7 };
    const source = try testSource(allocator, "0.25");
    defer allocator.free(source);
    const other_source = try testSource(allocator, "0.5");
    defer allocator.free(other_source);
    var first = try Registry.parseImport(allocator, request, source, "Shared name");
    const first_id = (try registry.completeImport(request, &first)).?;
    var duplicate = try Registry.parseImport(allocator, request, source, "Different filename");
    try std.testing.expectEqualStrings(first_id, (try registry.completeImport(request, &duplicate)).?);
    var other = try Registry.parseImport(allocator, request, other_source, "Shared name");
    const other_id = (try registry.completeImport(request, &other)).?;
    try std.testing.expect(!std.mem.eql(u8, first_id, other_id));
    try std.testing.expectEqual(@as(usize, 2), registry.counts().imported);
    try std.testing.expect(Registry.matches(registry.get(first_id).?.*, .imported, "ARED N"));
    try std.testing.expect(!Registry.matches(registry.get(first_id).?.*, .all, "missing"));
    try std.testing.expectError(error.CurrentThemeProtected, registry.checkRemove(first_id, registry.revision, .{ .saved = first_id, .draft = "dark" }));
    try std.testing.expectError(error.DraftThemeProtected, registry.checkRemove(first_id, registry.revision, .{ .saved = "dark", .draft = first_id }));
    const invalid = try testSource(allocator, "nan");
    defer allocator.free(invalid);
    try std.testing.expectError(error.InvalidComponent, Registry.parseImport(allocator, request, invalid, "bad"));
    try std.testing.expectError(error.MissingColors, Registry.parseImport(allocator, request, "<plist/>", "bad"));
}

test "import completions always consume including stale revision and allocation failures" {
    const allocator = std.testing.allocator;
    const source = try testSource(allocator, "1");
    defer allocator.free(source);
    const request: ImportRequest = .{ .draft_id = 11, .operation_id = 1 };
    var registry = try Registry.init(allocator);
    defer registry.deinit();
    var stale = try Registry.parseImport(allocator, request, source, "stale");
    try std.testing.expect((try registry.completeImport(null, &stale)) == null);
    var exhausted = try Registry.parseImport(allocator, request, source, "exhausted");
    registry.revision = std.math.maxInt(u64);
    try std.testing.expectError(error.RegistryRevisionExhausted, registry.completeImport(request, &exhausted));
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var empty: Registry = .{ .allocator = failing.allocator() };
    defer empty.deinit();
    var result = try Registry.parseImport(failing.allocator(), request, source, "oom");
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, empty.completeImport(request, &result));
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "favorites persist independently and failed replacement leaves marker unchanged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var registry = try Registry.init(std.testing.allocator);
    defer registry.deinit();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "blocked", .data = "file" });
    try std.testing.expectError(error.NotDir, registry.favorite(std.testing.io, tmp.dir, "blocked/favorites.json", "dark", registry.revision, true));
    try std.testing.expect(!registry.get("dark").?.favorite);
    try registry.favorite(std.testing.io, tmp.dir, "themes/favorites.json", "dark", registry.revision, true);
    var reloaded = try Registry.init(std.testing.allocator);
    defer reloaded.deinit();
    try reloaded.loadFavorites(std.testing.io, tmp.dir, "themes/favorites.json");
    try std.testing.expect(reloaded.get("dark").?.favorite);
    try std.testing.expectEqual(@as(usize, 1), reloaded.counts().favorites);
}

test "V3 presets have complete semantic tokens opaque ANSI and protected identities" {
    var registry = try Registry.init(std.testing.allocator);
    defer registry.deinit();
    for (presets.ids) |id| {
        const record = registry.get(id).?;
        try std.testing.expectEqualDeep(builtinTokens(id), record.ui_tokens);
        try std.testing.expectEqual(@as(u32, 255), record.ui_tokens.app & 255);
        for (record.theme.ansi) |color| try std.testing.expectEqual(@as(u32, 255), color & 255);
        try std.testing.expectError(error.BuiltinThemeProtected, registry.checkRemove(id, registry.revision, .{ .saved = "dark", .draft = "dark" }));
        try std.testing.expect(importer.builtinId(id) != null);
    }
    try std.testing.expect(registry.get("forest").?.ui_tokens.app != registry.get("ocean").?.ui_tokens.app);
}
