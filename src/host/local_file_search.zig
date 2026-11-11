//! Bounded host-local directory observations. A continuation scans the live
//! directory tree, with a cursor tied to the original request and root.
const std = @import("std");
const paths = @import("local_path.zig");
const reads = @import("local_file_reads.zig");
const CancelToken = @import("../ai/provider.zig").CancelToken;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const max_entries: usize = 32;
pub const max_matches: usize = 16;
pub const default_entries = 24;
pub const default_matches = 12;
pub const max_glob_bytes = 256;
const max_scanned_entries = 8192;
const max_depth = 24;
const max_scan_bytes = reads.max_version_bytes;
const max_ignore_bytes = reads.max_page_bytes;
const cursor_lifetime_ms = 5 * std.time.ms_per_min;
const cursor_prefix = "lscan1:";
const base64 = std.base64.url_safe_no_pad;
extern "c" fn fnmatch(pattern: [*:0]const u8, path: [*:0]const u8, flags: c_int) c_int;
const fnm_pathname = 0x02; // Darwin fnmatch.h

pub const ListOptions = struct {
    glob: ?[]const u8 = null,
    limit: usize = default_entries,
    cursor: ?[]const u8 = null,
    respect_ignores: bool = true,
};

pub const SearchOptions = struct {
    pattern: []const u8,
    glob: ?[]const u8 = null,
    limit: usize = default_matches,
    cursor: ?[]const u8 = null,
    respect_ignores: bool = true,
    follow_directory_symlinks: bool = false,
    context_lines: u8 = 0,
};

pub const Incomplete = enum(u8) {
    result_limit,
    scan_budget,
    depth_limit,
    inaccessible_entry,
    source_changed,
    ignore_rules_unavailable,
    unsupported_path_encoding,
};

pub const Entry = struct {
    name: []const u8,
    path: []const u8,
    kind: std.Io.File.Kind,
    size: ?u64,
};

pub const Match = struct {
    path: []const u8,
    line: u64,
    column: u64,
    snippet: []const u8,
    snippet_offset: u64,
    snippet_truncated: bool,
    version: []const u8,
    before: []const reads.ContextLine = &.{},
    after: []const reads.ContextLine = &.{},
};

pub const ListPage = struct {
    coverage: []const u8 = "live_scan",
    root: []const u8,
    entries: []const Entry,
    complete: bool,
    incomplete_reason: ?Incomplete,
    next_cursor: ?[]const u8,
    skipped: usize,
};

pub const SearchPage = struct {
    coverage: []const u8 = "live_scan",
    root: []const u8,
    matches: []const Match,
    complete: bool,
    incomplete_reason: ?Incomplete,
    next_cursor: ?[]const u8,
    skipped: usize,
};

const Common = struct {
    glob: ?[]const u8,
    limit: usize,
    cursor: ?[]const u8,
    respect_ignores: bool,
};

const Position = struct {
    entry: u32 = 0,
    match: u32 = 0,
};

const Cursor = struct {
    binding: [32]u8,
    expires: i64,
    position: Position,
    incomplete: ?Incomplete = null,
};

fn cursorMac(data: []const u8, key: [32]u8) [32]u8 {
    var mac = Hmac.init(&key);
    mac.update(cursor_prefix);
    mac.update(data);
    return mac.finalResult();
}

fn sealCursor(a: std.mem.Allocator, key: [32]u8, cursor: Cursor) ![]const u8 {
    var bytes: [81]u8 = undefined;
    @memcpy(bytes[0..32], &cursor.binding);
    std.mem.writeInt(i64, bytes[32..40], cursor.expires, .little);
    std.mem.writeInt(u32, bytes[40..44], cursor.position.entry, .little);
    std.mem.writeInt(u32, bytes[44..48], cursor.position.match, .little);
    bytes[48] = if (cursor.incomplete) |reason| @backingInt(reason) else 255;
    bytes[49..81].* = cursorMac(bytes[0..49], key);
    const output = try a.alloc(u8, cursor_prefix.len + base64.Encoder.calcSize(bytes.len));
    @memcpy(output[0..cursor_prefix.len], cursor_prefix);
    _ = base64.Encoder.encode(output[cursor_prefix.len..], &bytes);
    return output;
}

fn openCursor(key: [32]u8, text: []const u8, binding: [32]u8, now: i64) !Cursor {
    if (!std.mem.startsWith(u8, text, cursor_prefix)) return error.InvalidScanCursor;
    var bytes: [81]u8 = undefined;
    if (text.len != cursor_prefix.len + base64.Encoder.calcSize(bytes.len)) return error.InvalidScanCursor;
    base64.Decoder.decode(&bytes, text[cursor_prefix.len..]) catch return error.InvalidScanCursor;
    if (!std.crypto.timing_safe.eql([32]u8, cursorMac(bytes[0..49], key), bytes[49..81].*))
        return error.InvalidScanCursor;
    const expiry = std.mem.readInt(i64, bytes[32..40], .little);
    if (now >= expiry) return error.CursorExpired;
    if (!std.mem.eql(u8, &binding, bytes[0..32])) return error.ScanContextChanged;
    const incomplete = if (bytes[48] == 255)
        null
    else
        std.enums.fromInt(Incomplete, bytes[48]) orelse return error.InvalidScanCursor;
    return .{
        .binding = binding,
        .expires = expiry,
        .incomplete = incomplete,
        .position = .{
            .entry = std.mem.readInt(u32, bytes[40..44], .little),
            .match = std.mem.readInt(u32, bytes[44..48], .little),
        },
    };
}

const Rule = struct {
    pattern: [:0]const u8,
    basename: bool,
    directories_only: bool,
    negated: bool,
};

const Rules = struct {
    parent: ?*const Rules,
    prefix_len: usize,
    rules: []const Rule,

    fn ignored(self: Rules, name: [:0]const u8, relative: [:0]const u8, directory: bool) bool {
        var ignored_by_rule = if (self.parent) |parent| parent.ignored(name, relative, directory) else false;
        const local = relative[self.prefix_len.. :0];
        for (self.rules) |rule| {
            if (rule.directories_only and !directory) continue;
            const path = if (rule.basename) name else local;
            if (matchGlob(rule.pattern, path)) ignored_by_rule = !rule.negated;
        }
        return ignored_by_rule;
    }
};

fn ignoredByDefault(name: []const u8, directory: bool) bool {
    if (std.mem.eql(u8, name, ".git") or std.mem.eql(u8, name, ".DS_Store")) return true;
    if (!directory) return false;
    for ([_][]const u8{ ".zig-cache", "zig-cache", "zig-out", "node_modules", ".cache", "__pycache__", ".pytest_cache", ".venv", "target", "build", "dist" }) |excluded| {
        if (std.mem.eql(u8, name, excluded)) return true;
    }
    return false;
}

/// Match ordinary fnmatch patterns and ** as a full path component.
fn matchGlob(pattern: [:0]const u8, name: [:0]const u8) bool {
    if (std.mem.indexOf(u8, pattern, "**") == null or std.mem.indexOfScalar(u8, pattern, '/') == null)
        return fnmatch(pattern, name, fnm_pathname) == 0;

    const components_max = std.Io.Dir.max_path_bytes / 2 + 1;
    var names: [components_max][]const u8 = undefined;
    var count: usize = 0;
    var names_iter = std.mem.splitScalar(u8, name, '/');
    while (names_iter.next()) |segment| {
        names[count] = segment;
        count += 1;
    }
    var previous: [components_max + 1]bool = @splat(false);
    previous[0] = true;
    var pattern_iter = std.mem.splitScalar(u8, pattern, '/');
    while (pattern_iter.next()) |segment| {
        var next: [components_max + 1]bool = @splat(false);
        if (std.mem.eql(u8, segment, "**")) {
            // A trailing / ** excludes descendants, not the directory itself.
            const terminal = pattern_iter.index == null and segment.ptr != pattern.ptr;
            if (!terminal) next[0] = previous[0];
            for (1..count + 1) |i| next[i] = next[i - 1] or previous[i - 1] or (!terminal and previous[i]);
        } else {
            var pattern_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            @memcpy(pattern_buf[0..segment.len], segment);
            pattern_buf[segment.len] = 0;
            for (1..count + 1) |i| {
                if (!previous[i - 1]) continue;
                var name_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const part = names[i - 1];
                @memcpy(name_buf[0..part.len], part);
                name_buf[part.len] = 0;
                next[i] = fnmatch(pattern_buf[0..segment.len :0], name_buf[0..part.len :0], fnm_pathname) == 0;
            }
        }
        previous = next;
    }
    return previous[count];
}

fn loadRules(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    absolute: []const u8,
    cancel: *const CancelToken,
    notes_boundary: ?paths.NotesBoundary,
) ![]const Rule {
    const stat = directory.statFile(io, ".gitignore", .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    if (stat.kind == .sym_link) return &.{}; // Git also ignores symlinked ignore files.
    if (stat.kind != .file or stat.size > max_ignore_bytes) return error.IgnoreRulesUnavailable;
    const path = try std.fmt.allocPrint(allocator, "{s}/.gitignore", .{std.mem.trimEnd(u8, absolute, "/")});
    const target = try paths.resolveWithNotesBoundary(allocator, io, .{ .path = path }, .file, notes_boundary);
    defer target.deinit(allocator, io);
    if (!std.meta.eql(target.parent_identity, try paths.Identity.of(directory))) return error.SourceChanged;
    const page = try reads.readText(allocator, io, &target, .{
        .max_bytes = max_ignore_bytes,
        .version_byte_budget = max_ignore_bytes,
    }, cancel);
    if (page.truncated) return error.IgnoreRulesUnavailable;
    var lines = std.mem.splitScalar(u8, page.bytes, '\n');
    var rules: std.ArrayList(Rule) = .empty;
    while (lines.next()) |raw| {
        var line = std.mem.trimEnd(u8, raw, "\r");
        while (line.len > 0 and line[line.len - 1] == ' ') {
            var escapes: usize = 0;
            while (escapes + 2 <= line.len and line[line.len - escapes - 2] == '\\') escapes += 1;
            if (escapes % 2 != 0) break;
            line = line[0 .. line.len - 1];
        }
        if (line.len == 0 or line[0] == '#') continue;
        const negated = line[0] == '!';
        if (negated) line = line[1..];
        const anchored = std.mem.startsWith(u8, line, "/");
        if (anchored) line = line[1..];
        const directories_only = std.mem.endsWith(u8, line, "/");
        if (directories_only) line = line[0 .. line.len - 1];
        if (line.len == 0) continue;
        if (line.len >= std.Io.Dir.max_path_bytes) return error.IgnoreRulesUnavailable;
        try rules.append(allocator, .{
            .pattern = try allocator.dupeSentinel(u8, line, 0),
            .basename = !anchored and std.mem.indexOfScalar(u8, line, '/') == null,
            .directories_only = directories_only,
            .negated = negated,
        });
    }
    return rules.items;
}

const Walker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    deadline: std.Io.Timestamp,
    cancel: *const CancelToken,
    glob: ?[:0]const u8,
    respect_ignores: bool,
    requested: Position,
    scan_index: u32 = 0,
    scanned_bytes: u64 = 0,
    stopped: bool = false,
    skipped: usize = 0,
    incomplete: ?Incomplete = null,
    resume_position: ?Position = null,
    limit: usize,
    pattern: ?[]const u8,
    follow_links: bool,
    context_lines: u8,
    notes_boundary: ?paths.NotesBoundary,
    entries: std.ArrayList(Entry) = .empty,
    matches: std.ArrayList(Match) = .empty,
    visited: std.AutoHashMapUnmanaged(paths.Identity, void) = .empty,

    fn skip(self: *Walker, reason: Incomplete) void {
        self.skipped += 1;
        if (self.incomplete == null) self.incomplete = reason;
    }

    fn resumeAt(self: *Walker, position: Position) void {
        self.resume_position = position;
        self.stopped = true;
    }

    fn walk(
        self: *Walker,
        directory: std.Io.Dir,
        absolute: []const u8,
        prefix: []const u8,
        parent_rules: ?*const Rules,
        depth: usize,
    ) anyerror!void {
        if (depth > max_depth) {
            self.skip(.depth_limit);
            return;
        }
        var temporary: std.heap.ArenaAllocator = .init(self.allocator);
        defer temporary.deinit();
        const a = temporary.allocator();
        const rules: Rules = .{
            .parent = parent_rules,
            .prefix_len = if (prefix.len == 0) 0 else prefix.len + 1,
            .rules = if (self.respect_ignores)
                loadRules(a, self.io, directory, absolute, self.cancel, self.notes_boundary) catch |err| switch (err) {
                    error.OutOfMemory, error.Cancelled => return err,
                    error.Canceled => return error.Cancelled,
                    else => {
                        self.skip(.ignore_rules_unavailable);
                        return;
                    },
                }
            else
                &.{},
        };
        const directory_identity = if (self.notes_boundary) |boundary| blk: {
            boundary.check(self.io, directory, ".") catch |err| switch (err) {
                error.NotesStoreProtected => return,
                else => return err,
            };
            break :blk try paths.Identity.of(directory);
        } else null;
        var iterator = directory.iterateAssumeFirstIteration();
        while (!self.stopped) {
            if (self.cancel.isCancelled()) return error.Cancelled;
            if (self.scan_index >= max_scanned_entries or std.Io.Clock.awake.now(self.io).compare(.gte, self.deadline)) {
                self.skip(.scan_budget);
                self.stopped = true;
                return;
            }
            const entry = iterator.next(self.io) catch |err| switch (err) {
                error.Canceled => return error.Cancelled,
                else => {
                    self.skip(.inaccessible_entry);
                    return;
                },
            } orelse return;
            const position = self.scan_index;
            self.scan_index += 1;
            if (!std.unicode.utf8ValidateSlice(entry.name)) {
                self.skip(.unsupported_path_encoding);
                continue;
            }
            if (paths.isRecoveryName(entry.name)) continue;
            if (self.notes_boundary) |boundary| {
                if (boundary.protectsChild(directory_identity.?, entry.name)) continue;
            }
            var name_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            if (entry.name.len >= name_buf.len) {
                self.skip(.unsupported_path_encoding);
                continue;
            }
            @memcpy(name_buf[0..entry.name.len], entry.name);
            name_buf[entry.name.len] = 0;
            const name = name_buf[0..entry.name.len :0];
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const child = std.fmt.bufPrintSentinel(&path_buf, "{s}/{s}", .{ std.mem.trimEnd(u8, absolute, "/"), name }, 0) catch {
                self.skip(.unsupported_path_encoding);
                continue;
            };
            var relative_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const relative = (if (prefix.len == 0)
                std.fmt.bufPrintSentinel(&relative_buf, "{s}", .{name}, 0)
            else
                std.fmt.bufPrintSentinel(&relative_buf, "{s}/{s}", .{ prefix, name }, 0)) catch {
                self.skip(.unsupported_path_encoding);
                continue;
            };
            const stat = directory.statFile(self.io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.Canceled => return error.Cancelled,
                else => {
                    self.skip(if (err == error.FileNotFound) .source_changed else .inaccessible_entry);
                    continue;
                },
            };
            const is_directory = stat.kind == .directory;
            if (self.respect_ignores and (ignoredByDefault(name, is_directory) or rules.ignored(name, relative, is_directory))) continue;
            if (self.pattern != null) {
                if (is_directory) {
                    const opened = directory.openDir(self.io, name, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
                        error.Canceled => return error.Cancelled,
                        else => {
                            self.skip(.inaccessible_entry);
                            continue;
                        },
                    };
                    defer opened.close(self.io);
                    const id = try paths.Identity.of(opened);
                    if (id.inode != stat.inode) {
                        self.skip(.source_changed);
                        continue;
                    }
                    try self.walkDirectory(opened, child, relative, &rules, depth, id);
                    continue;
                } else if (stat.kind == .sym_link and self.follow_links) {
                    try self.walkLink(child, relative, &rules, depth);
                    continue;
                }
                if (stat.kind != .file) continue;
            }
            if (position < self.requested.entry or !self.matchesGlob(name, relative)) continue;
            if (self.pattern) |pattern| {
                try self.searchFile(directory, child, stat, position, pattern);
            } else {
                if (self.entries.items.len == self.limit) {
                    self.resumeAt(.{ .entry = position });
                    return;
                }
                try self.entries.append(self.allocator, .{
                    .name = try self.allocator.dupe(u8, name),
                    .path = try self.allocator.dupe(u8, child),
                    .kind = stat.kind,
                    .size = if (stat.kind == .file) stat.size else null,
                });
            }
        }
    }

    fn matchesGlob(self: *const Walker, name: [:0]const u8, relative: [:0]const u8) bool {
        const glob = self.glob orelse return true;
        const path = if (std.mem.indexOfScalar(u8, glob, '/') != null) relative else name;
        return matchGlob(glob, path);
    }

    fn walkDirectory(self: *Walker, opened: std.Io.Dir, absolute: []const u8, relative: []const u8, rules: *const Rules, depth: usize, id: paths.Identity) !void {
        const visited = try self.visited.getOrPut(self.allocator, id);
        if (visited.found_existing) return;
        try self.walk(opened, absolute, relative, rules, depth + 1);
    }

    fn walkLink(self: *Walker, child: []const u8, relative: [:0]const u8, rules: *const Rules, depth: usize) !void {
        var temporary: std.heap.ArenaAllocator = .init(self.allocator);
        defer temporary.deinit();
        const a = temporary.allocator();
        const target = paths.resolveWithNotesBoundary(a, self.io, .{ .path = child }, .directory, self.notes_boundary) catch |err| switch (err) {
            error.NotDir, error.ManagedRecoveryMaterial, error.NotesStoreProtected => return,
            error.OutOfMemory, error.Cancelled => return err,
            error.Canceled => return error.Cancelled,
            else => {
                self.skip(.inaccessible_entry);
                return;
            },
        };
        defer target.deinit(a, self.io);
        const name = if (std.mem.lastIndexOfScalar(u8, relative, '/')) |slash| relative[slash + 1 .. :0] else relative;
        if (self.respect_ignores and (ignoredByDefault(name, true) or rules.ignored(name, relative, true))) return;
        const opened = try target.openDirectory(self.io, true);
        defer opened.close(self.io);
        try self.walkDirectory(opened, target.absolute, relative, rules, depth, target.target_identity.?);
    }

    fn searchFile(
        self: *Walker,
        directory: std.Io.Dir,
        path: []const u8,
        observed: std.Io.File.Stat,
        position: u32,
        pattern: []const u8,
    ) !void {
        if (self.matches.items.len == self.limit) {
            self.resumeAt(.{ .entry = position });
            return;
        }
        const budget = max_scan_bytes - self.scanned_bytes;
        if (observed.size > budget) {
            self.skip(.scan_budget);
            return;
        }
        var temporary: std.heap.ArenaAllocator = .init(self.allocator);
        defer temporary.deinit();
        const a = temporary.allocator();
        const target = paths.resolveWithNotesBoundary(a, self.io, .{ .path = path }, .file, self.notes_boundary) catch |err| switch (err) {
            error.NotesStoreProtected => return,
            error.OutOfMemory, error.Cancelled => return err,
            error.Canceled => return error.Cancelled,
            else => {
                self.skip(.source_changed);
                return;
            },
        };
        defer target.deinit(a, self.io);
        if (target.target_identity.?.inode != observed.inode or !std.meta.eql(target.parent_identity, try paths.Identity.of(directory))) {
            self.skip(.source_changed);
            return;
        }
        const skip_matches = if (position == self.requested.entry) self.requested.match else 0;
        const result = reads.searchText(a, self.io, &target, pattern, skip_matches, self.limit - self.matches.items.len, self.context_lines, budget, self.deadline, self.cancel) catch |err| switch (err) {
            error.OutOfMemory, error.Cancelled => return err,
            error.Canceled => return error.Cancelled,
            error.UnsupportedTextEncoding => {
                // Count excluded files against the budget too. They have no text matches.
                self.scanned_bytes += observed.size;
                return;
            },
            else => {
                self.scanned_bytes += observed.size;
                self.skip(switch (err) {
                    error.VersionBudgetExceeded => .scan_budget,
                    error.SourceChanged => .source_changed,
                    else => .inaccessible_entry,
                });
                return;
            },
        };
        self.scanned_bytes += result.total_bytes;
        if (result.matches.len != 0) {
            const absolute = try self.allocator.dupe(u8, target.absolute);
            const version = try self.allocator.dupe(u8, &result.version);
            for (result.matches) |found| {
                try self.matches.append(self.allocator, .{
                    .path = absolute,
                    .line = found.line,
                    .column = found.column,
                    .snippet = try self.allocator.dupe(u8, found.snippet),
                    .snippet_offset = found.snippet_offset,
                    .snippet_truncated = found.snippet_truncated,
                    .version = version,
                    .before = try self.cloneContext(found.before),
                    .after = try self.cloneContext(found.after),
                });
            }
        }
        if (result.more) self.resumeAt(.{ .entry = position, .match = skip_matches + @as(u32, @intCast(result.matches.len)) });
    }

    fn cloneContext(self: *Walker, lines: []const reads.ContextLine) ![]const reads.ContextLine {
        if (lines.len == 0) return &.{};
        const result = try self.allocator.dupe(reads.ContextLine, lines);
        for (result) |*line| line.text = try self.allocator.dupe(u8, line.text);
        return result;
    }
};

const Summary = struct {
    walker: Walker,
    next_cursor: ?[]const u8,
    complete: bool,
    incomplete_reason: ?Incomplete,
};

/// The caller provides an arena for returned page data and transient work.
fn scan(
    a: std.mem.Allocator,
    io: std.Io,
    root: *const paths.Resolved,
    options: Common,
    pattern: ?[]const u8,
    follow_links: bool,
    context_lines: u8,
    cursor_key: [32]u8,
    cancel: *const CancelToken,
) !Summary {
    if (!root.conversation.valid()) return error.InvalidConversation;
    if (options.limit == 0 or options.limit > (if (pattern == null) max_entries else max_matches))
        return error.InvalidScanLimit;
    if (options.glob) |glob| {
        if (glob.len == 0 or glob.len > max_glob_bytes or
            std.mem.indexOfScalar(u8, glob, 0) != null or !std.unicode.utf8ValidateSlice(glob))
            return error.InvalidFileGlob;
    }
    if (pattern) |value| try reads.validatePattern(value);
    if (context_lines > reads.max_context_lines) return error.InvalidContextLines;
    const binding_bytes = try std.json.Stringify.valueAlloc(a, .{
        .conversation = root.conversation,
        .root = root.absolute,
        .root_identity = root.target_identity,
        .source = root.source,
        .workspace = root.workspace_revision,
        .glob = options.glob,
        .limit = options.limit,
        .respect_ignores = options.respect_ignores,
        .pattern = pattern,
        .follow_directory_symlinks = follow_links,
        .context_lines = context_lines,
    }, .{});
    defer a.free(binding_bytes);
    var binding: [32]u8 = undefined;
    Sha256.hash(binding_bytes, &binding, .{});
    const now = std.Io.Clock.real.now(io).toMilliseconds();
    const cursor = if (options.cursor) |value|
        try openCursor(cursor_key, value, binding, now)
    else
        Cursor{ .binding = binding, .expires = now + cursor_lifetime_ms, .position = .{} };
    const opened = try root.openDirectory(io, true);
    defer opened.close(io);
    const glob = if (options.glob) |value| try a.dupeSentinel(u8, value, 0) else null;
    defer if (glob) |value| a.free(value);
    var walker: Walker = .{
        .allocator = a,
        .io = io,
        .deadline = reads.deadlineFromNow(io),
        .cancel = cancel,
        .glob = glob,
        .respect_ignores = options.respect_ignores,
        .requested = cursor.position,
        .incomplete = cursor.incomplete,
        .limit = options.limit,
        .pattern = pattern,
        .follow_links = follow_links,
        .context_lines = context_lines,
        .notes_boundary = root.notes_boundary,
    };
    defer walker.visited.deinit(a);
    try walker.visited.put(a, root.target_identity.?, {});
    try walker.walk(opened, root.absolute, "", null, 0);
    try root.revalidate(io);
    const next_cursor = if (walker.resume_position) |position| try sealCursor(a, cursor_key, .{
        .binding = binding,
        .expires = cursor.expires,
        .position = position,
        .incomplete = walker.incomplete,
    }) else null;
    return .{
        .walker = walker,
        .next_cursor = next_cursor,
        .complete = next_cursor == null and walker.incomplete == null,
        .incomplete_reason = if (next_cursor != null) .result_limit else walker.incomplete,
    };
}

pub fn list(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: *const paths.Resolved,
    options: ListOptions,
    cursor_key: [32]u8,
    cancel: *const CancelToken,
) !ListPage {
    const summary = try scan(allocator, io, root, .{
        .glob = options.glob,
        .limit = options.limit,
        .cursor = options.cursor,
        .respect_ignores = options.respect_ignores,
    }, null, false, 0, cursor_key, cancel);
    return .{
        .root = root.absolute,
        .entries = summary.walker.entries.items,
        .complete = summary.complete,
        .incomplete_reason = summary.incomplete_reason,
        .next_cursor = summary.next_cursor,
        .skipped = summary.walker.skipped,
    };
}

pub fn search(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: *const paths.Resolved,
    options: SearchOptions,
    cursor_key: [32]u8,
    cancel: *const CancelToken,
) !SearchPage {
    const summary = try scan(allocator, io, root, .{
        .glob = options.glob,
        .limit = options.limit,
        .cursor = options.cursor,
        .respect_ignores = options.respect_ignores,
    }, options.pattern, options.follow_directory_symlinks, options.context_lines, cursor_key, cancel);
    return .{
        .root = root.absolute,
        .matches = summary.walker.matches.items,
        .complete = summary.complete,
        .incomplete_reason = summary.incomplete_reason,
        .next_cursor = summary.next_cursor,
        .skipped = summary.walker.skipped,
    };
}

test "local scan skips the managed notes subtree and keeps ordinary notes directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "app/notes/library");
    try tmp.dir.createDirPath(io, "project/notes");
    try tmp.dir.writeFile(io, .{ .sub_path = "app/notes/library/fake.txt", .data = "needle" });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/notes/example.txt", .data = "needle" });
    try tmp.dir.writeFile(io, .{ .sub_path = "app/config.txt", .data = "ordinary data" });
    try tmp.dir.symLink(io, "app/notes/library", "alias", .{ .is_directory = true });
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", a);
    const app_path = try tmp.dir.realPathFileAlloc(io, "app", a);
    const conversation = @import("identity.zig").ConversationId.generate();
    const root = try paths.resolve(a, io, .{ .path = root_path, .app_data_root = app_path, .conversation = conversation }, .directory);
    defer root.deinit(a, io);
    const app_root = try paths.resolve(a, io, .{ .path = app_path, .app_data_root = app_path, .conversation = conversation }, .directory);
    defer app_root.deinit(a, io);
    const cancel: CancelToken = .{};
    const key: [32]u8 = @splat(0);
    const listing = try list(a, io, &app_root, .{ .respect_ignores = false }, key, &cancel);
    try std.testing.expectEqual(@as(usize, 1), listing.entries.len);
    try std.testing.expectEqualStrings("config.txt", listing.entries[0].name);
    const matches = try search(a, io, &root, .{ .pattern = "needle", .respect_ignores = false, .follow_directory_symlinks = true }, key, &cancel);
    try std.testing.expectEqual(@as(usize, 1), matches.matches.len);
    try std.testing.expect(std.mem.endsWith(u8, matches.matches[0].path, "/project/notes/example.txt"));
}

test "local scan cursor binds the root revision, conversation and query" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "project/node_modules");
    try tmp.dir.createDirPath(io, "other");
    try tmp.dir.writeFile(io, .{ .sub_path = "project/.gitignore", .data = "*.log\n!important.log\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/ignored.log", .data = "ignored" });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/important.log", .data = "included" });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/one.txt", .data = "one" });
    const project = try tmp.dir.realPathFileAlloc(io, "project", a);
    const ConversationId = @import("identity.zig").ConversationId;
    const workspace = @import("local_workspace.zig");
    var options: paths.Options = .{
        .workspace = try workspace.inspect(a, io, project),
        .conversation = ConversationId.generate(),
    };
    const root = try paths.resolve(a, io, options, .directory);
    defer root.deinit(a, io);
    const key: [32]u8 = @splat(23);
    const cancel: CancelToken = .{};

    const page = try list(a, io, &root, .{ .limit = 1, .glob = "*.*" }, key, &cancel);
    try std.testing.expectEqualStrings("live_scan", page.coverage);
    try std.testing.expectEqual(@as(usize, 1), page.entries.len);
    try std.testing.expect(!page.complete and page.incomplete_reason.? == .result_limit);
    var cursor = page.next_cursor;
    try std.testing.expect(cursor != null);
    try std.testing.expectError(error.ScanContextChanged, list(a, io, &root, .{ .limit = 1, .glob = "*.txt", .cursor = cursor }, key, &cancel));
    try std.testing.expectError(error.InvalidScanCursor, list(a, io, &root, .{ .limit = 1, .glob = "*.*", .cursor = cursor }, @splat(24), &cancel));
    options.workspace.revision += 1;
    const revised = try paths.resolve(a, io, options, .directory);
    defer revised.deinit(a, io);
    try std.testing.expectError(error.ScanContextChanged, list(a, io, &revised, .{ .limit = 1, .glob = "*.*", .cursor = cursor }, key, &cancel));
    options.workspace.revision -= 1;
    options.conversation = ConversationId.generate();
    const another = try paths.resolve(a, io, options, .directory);
    defer another.deinit(a, io);
    try std.testing.expectError(error.ScanContextChanged, list(a, io, &another, .{ .limit = 1, .glob = "*.*", .cursor = cursor }, key, &cancel));
    options.conversation = root.conversation;
    const replacement = try tmp.dir.realPathFileAlloc(io, "other", a);
    options.workspace = try workspace.inspect(a, io, replacement);
    const new_root = try paths.resolve(a, io, options, .directory);
    defer new_root.deinit(a, io);
    try std.testing.expectError(error.ScanContextChanged, list(a, io, &new_root, .{ .limit = 1, .glob = "*.*", .cursor = cursor }, key, &cancel));

    var count: usize = 1;
    var important = std.mem.eql(u8, page.entries[0].name, "important.log");
    while (cursor) |token| {
        const next = try list(a, io, &root, .{ .limit = 1, .glob = "*.*", .cursor = token }, key, &cancel);
        count += next.entries.len;
        for (next.entries) |entry| {
            try std.testing.expect(!std.mem.eql(u8, entry.name, "ignored.log"));
            important = important or std.mem.eql(u8, entry.name, "important.log");
        }
        cursor = next.next_cursor;
        try std.testing.expect(count <= 3);
    }
    try std.testing.expect(important and count == 3);

    const expired = try sealCursor(a, key, .{ .binding = @splat(7), .position = .{}, .expires = 9 });
    try std.testing.expectError(error.CursorExpired, openCursor(key, expired, @splat(7), 9));
}

test "local scan streams a large file, pages hits, and deduplicates directory aliases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "project/src");
    try tmp.dir.createDirPath(io, "project/private/deep");
    try tmp.dir.createDirPath(io, "outside");
    const large = try a.alloc(u8, 96 * 1024);
    @memset(large, 'x');
    @memcpy(large[32765..][0..7], "needle\n");
    @memcpy(large[large.len - 7 ..], "needle\n");
    try tmp.dir.writeFile(io, .{ .sub_path = "project/src/main.txt", .data = large });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/private/deep/skip.txt", .data = "needle" });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/.gitignore", .data = "private/**/skip.txt\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "outside/out.txt", .data = "needle" });
    try tmp.dir.symLink(io, "../outside", "project/ext1", .{ .is_directory = true });
    try tmp.dir.symLink(io, "../outside", "project/ext2", .{ .is_directory = true });
    try tmp.dir.symLink(io, "../", "project/src/loop", .{ .is_directory = true });
    const root = try paths.resolve(a, io, .{
        .path = try tmp.dir.realPathFileAlloc(io, "project", a),
        .conversation = @import("identity.zig").ConversationId.generate(),
    }, .directory);
    defer root.deinit(a, io);
    const key: [32]u8 = @splat(35);
    const cancel: CancelToken = .{};
    var options: SearchOptions = .{ .pattern = "needle", .glob = "**/*.txt", .limit = 1 };
    const first = try search(a, io, &root, options, key, &cancel);
    try std.testing.expect(!first.complete and first.next_cursor != null);
    try std.testing.expectEqual(@as(usize, 1), first.matches.len);
    try std.testing.expectEqual(@as(u64, 1), first.matches[0].line);
    try std.testing.expectEqual(@as(u64, 32766), first.matches[0].column);
    try std.testing.expect(first.matches[0].snippet_truncated);
    try std.testing.expect(std.mem.indexOf(u8, first.matches[0].snippet, "needle") != null);
    options.cursor = first.next_cursor;
    const second = try search(a, io, &root, options, key, &cancel);
    try std.testing.expectEqual(@as(usize, 1), second.matches.len);
    try std.testing.expectEqual(@as(u64, 2), second.matches[0].line);
    try std.testing.expectEqualStrings(first.matches[0].version, second.matches[0].version);
    try std.testing.expect(second.complete and second.next_cursor == null);

    const followed = try search(a, io, &root, .{
        .pattern = "needle",
        .glob = "**/*.txt",
        .follow_directory_symlinks = true,
    }, key, &cancel);
    try std.testing.expect(followed.complete);
    try std.testing.expectEqual(@as(usize, 3), followed.matches.len);
    var outside: usize = 0;
    for (followed.matches) |found| {
        if (std.mem.endsWith(u8, found.path, "/outside/out.txt")) outside += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), outside);

    const ignored = try search(a, io, &root, .{ .pattern = "needle", .glob = "skip.txt" }, key, &cancel);
    try std.testing.expect(ignored.complete and ignored.matches.len == 0);
    const unignored = try search(a, io, &root, .{ .pattern = "needle", .glob = "skip.txt", .respect_ignores = false }, key, &cancel);
    try std.testing.expect(unignored.complete and unignored.matches.len == 1);
}

test "local scan applies default ignores to followed directory aliases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "project/build");
    try tmp.dir.createDirPath(io, "outside/dependencies");
    try tmp.dir.createDirPath(io, "outside/shared");
    try tmp.dir.writeFile(io, .{ .sub_path = "project/build/output.txt", .data = "needle" });
    try tmp.dir.writeFile(io, .{ .sub_path = "outside/dependencies/package.txt", .data = "needle" });
    try tmp.dir.writeFile(io, .{ .sub_path = "outside/shared/source.txt", .data = "needle" });
    try tmp.dir.symLink(io, "../outside/dependencies", "project/node_modules", .{ .is_directory = true });
    try tmp.dir.symLink(io, "../outside/shared", "project/shared", .{ .is_directory = true });
    const root = try paths.resolve(a, io, .{
        .path = try tmp.dir.realPathFileAlloc(io, "project", a),
        .conversation = @import("identity.zig").ConversationId.generate(),
    }, .directory);
    defer root.deinit(a, io);
    const key: [32]u8 = @splat(36);
    const cancel: CancelToken = .{};
    var options: SearchOptions = .{ .pattern = "needle", .follow_directory_symlinks = true };

    const filtered = try search(a, io, &root, options, key, &cancel);
    try std.testing.expect(filtered.complete);
    try std.testing.expectEqual(@as(usize, 1), filtered.matches.len);
    try std.testing.expect(std.mem.endsWith(u8, filtered.matches[0].path, "/outside/shared/source.txt"));

    options.respect_ignores = false;
    const unfiltered = try search(a, io, &root, options, key, &cancel);
    try std.testing.expect(unfiltered.complete);
    try std.testing.expectEqual(@as(usize, 3), unfiltered.matches.len);
}

test "local scan preserves bounded surrounding lines on either side of a page boundary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const long = @as([127]u8, @splat('x')) ++ "你";
    try tmp.dir.writeFile(io, .{
        .sub_path = "note.txt",
        .data = "one\ntwo\nneedle third\nneedle fourth\n" ++ long ++ "\nsix",
    });
    const root = try paths.resolve(a, io, .{
        .path = try tmp.dir.realPathFileAlloc(io, ".", a),
        .conversation = @import("identity.zig").ConversationId.generate(),
    }, .directory);
    defer root.deinit(a, io);
    const key: [32]u8 = @splat(55);
    const cancel: CancelToken = .{};
    var options: SearchOptions = .{ .pattern = "needle", .limit = 1, .context_lines = 2 };
    const first = try search(a, io, &root, options, key, &cancel);
    try std.testing.expect(!first.complete and first.next_cursor != null);
    try std.testing.expectEqual(@as(usize, 1), first.matches.len);
    const initial = first.matches[0];
    try std.testing.expectEqual(@as(u64, 3), initial.line);
    try std.testing.expectEqual(@as(usize, 2), initial.before.len);
    try std.testing.expectEqualStrings("one", initial.before[0].text);
    try std.testing.expectEqualStrings("two", initial.before[1].text);
    try std.testing.expectEqual(@as(usize, 2), initial.after.len);
    try std.testing.expectEqualStrings("needle fourth", initial.after[0].text);
    try std.testing.expectEqual(@as(u64, 5), initial.after[1].line);
    try std.testing.expectEqual(@as(usize, 127), initial.after[1].text.len);
    try std.testing.expect(initial.after[1].truncated);

    options.cursor = first.next_cursor;
    const second = try search(a, io, &root, options, key, &cancel);
    try std.testing.expect(second.complete and second.next_cursor == null);
    try std.testing.expectEqual(@as(usize, 1), second.matches.len);
    const continued = second.matches[0];
    try std.testing.expectEqual(@as(u64, 4), continued.line);
    try std.testing.expectEqualStrings("needle third", continued.before[1].text);
    try std.testing.expectEqualStrings("six", continued.after[1].text);
    options.context_lines = 1;
    try std.testing.expectError(error.ScanContextChanged, search(a, io, &root, options, key, &cancel));
}

test "local scan skips managed recovery material even through a directory alias" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const stage = ".zerowork-file-00112233445566778899aabbccddeeff.tmp";
    try tmp.dir.createDirPath(io, "project/" ++ stage);
    try tmp.dir.writeFile(io, .{ .sub_path = "project/" ++ stage ++ "/entry", .data = "needle in recovery" });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/visible.txt", .data = "needle in project" });
    try tmp.dir.symLink(io, stage, "project/recovery-alias", .{ .is_directory = true });
    const root_path = try tmp.dir.realPathFileAlloc(io, "project", a);
    const root = try paths.resolve(a, io, .{
        .path = root_path,
        .conversation = @import("identity.zig").ConversationId.generate(),
    }, .directory);
    defer root.deinit(a, io);
    const cancel: CancelToken = .{};
    const result = try search(a, io, &root, .{
        .pattern = "needle",
        .respect_ignores = false,
        .follow_directory_symlinks = true,
    }, @splat(5), &cancel);
    try std.testing.expect(result.complete);
    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expect(std.mem.endsWith(u8, result.matches[0].path, "/visible.txt"));
    const alias_file = try std.fs.path.join(a, &.{ root_path, "recovery-alias", "entry" });
    try std.testing.expectError(error.ManagedRecoveryMaterial, paths.resolve(a, io, .{ .path = alias_file }, .file));
}
