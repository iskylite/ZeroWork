//! Immutable, content-addressed local packages. No scripts or remote fetches.
const std = @import("std");
const cfg = @import("../config/ai_extensions.zig");
const id = @import("../host/identity.zig");
pub const Diagnostic = struct {
    path: [4096]u8 = undefined,
    path_len: usize = 0,
    pub fn set(self: *Diagnostic, path: []const u8) void {
        self.path_len = @min(path.len, self.path.len);
        @memcpy(self.path[0..self.path_len], path[0..self.path_len]);
    }
};
pub const Entry = struct { path: []const u8, size: usize, sha256: [32]u8 };
pub const Manifest = struct { files: []const Entry };
const File = Entry;
pub const Imported = struct {
    arena: std.heap.ArenaAllocator,
    skill: cfg.Skill,
    file_count: usize,
    total_bytes: u64,
    pub fn deinit(self: *Imported) void {
        self.arena.deinit();
    }
};
pub fn relative(path: []const u8) !void {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfAny(u8, path, "\\\x00") != null) return error.InvalidSkillPath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidSkillPath;
    }
}
pub fn openDir(root: std.Io.Dir, io: std.Io, path: []const u8) !std.Io.Dir {
    try relative(path);
    var current = try root.openDir(io, ".", .{ .follow_symlinks = false, .iterate = true });
    errdefer current.close(io);
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        const next = try current.openDir(io, part, .{ .follow_symlinks = false, .iterate = true });
        current.close(io);
        current = next;
    }
    return current;
}
fn openRegular(root: std.Io.Dir, io: std.Io, path: []const u8) !std.Io.File {
    try relative(path);
    const parent = std.fs.path.dirname(path);
    var dir = if (parent) |value| try openDir(root, io, value) else try root.openDir(io, ".", .{ .follow_symlinks = false });
    defer dir.close(io);
    if ((try dir.statFile(io, std.fs.path.basename(path), .{ .follow_symlinks = false })).kind != .file) return error.UnsupportedSkillFile;
    const file = try dir.openFile(io, std.fs.path.basename(path), .{ .follow_symlinks = false, .resolve_beneath = true, .lock = .shared, .lock_nonblocking = true });
    errdefer file.close(io);
    if ((try file.stat(io)).kind != .file) return error.UnsupportedSkillFile;
    return file;
}
pub fn readFile(root: std.Io.Dir, io: std.Io, a: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try openRegular(root, io, path);
    defer file.close(io);
    const stat = try file.stat(io);
    const bytes = try a.alloc(u8, std.math.cast(usize, stat.size) orelse return error.OutOfMemory);
    errdefer a.free(bytes);
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len or (try file.stat(io)).size != bytes.len) return error.SkillSourceChanged;
    return bytes;
}
/// Copy opaque resources in bounded chunks. Scripts/assets are never decoded,
/// parsed or included in the model context by importing a skill.
fn snapshot(dir: std.Io.Dir, destination: std.Io.Dir, io: std.Io, name: []const u8, path: []const u8, cancel: ?*@import("provider.zig").CancelToken) !Entry {
    const source = try openRegular(dir, io, name);
    defer source.close(io);
    const stat = try source.stat(io);
    if (std.fs.path.dirname(path)) |parent| try destination.createDirPath(io, parent);
    const out = try destination.createFile(io, path, .{ .exclusive = true, .permissions = @fromBackingInt(0o600) });
    defer out.close(io);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < stat.size) {
        if (cancel) |token| if (token.isCancelled()) return error.Cancelled;
        const count: usize = @intCast(@min(buffer.len, stat.size - offset));
        if (try source.readPositionalAll(io, buffer[0..count], offset) != count) return error.SkillSourceChanged;
        try out.writeStreamingAll(io, buffer[0..count]);
        hash.update(buffer[0..count]);
        offset += count;
    }
    if ((try source.stat(io)).size != stat.size) return error.SkillSourceChanged;
    try out.sync(io);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return .{ .path = path, .size = std.math.cast(usize, stat.size) orelse return error.OutOfMemory, .sha256 = digest };
}
fn collect(dir: std.Io.Dir, destination: std.Io.Dir, io: std.Io, a: std.mem.Allocator, prefix: []const u8, files: *std.ArrayList(File), diagnostic: ?*Diagnostic, cancel: ?*@import("provider.zig").CancelToken) !void {
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (cancel) |token| if (token.isCancelled()) return error.Cancelled;
        if (ignored(entry.name)) continue;
        const path = if (prefix.len == 0) try a.dupe(u8, entry.name) else try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, entry.name });
        if (diagnostic) |d| d.set(path);
        try relative(path);
        if (std.mem.eql(u8, path, ".package.json")) return error.ReservedSkillFile;
        if (entry.kind == .directory) {
            var child = try dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
            defer child.close(io);
            try collect(child, destination, io, a, path, files, diagnostic, cancel);
        } else if (entry.kind == .file) {
            try files.append(a, try snapshot(dir, destination, io, entry.name, path, cancel));
        } else return error.UnsupportedSkillFile;
    }
}
fn metadata(a: std.mem.Allocator, original: []const u8) !struct { name: []const u8, description: []const u8, body: []const u8 } {
    if (!std.unicode.utf8ValidateSlice(original) or std.mem.indexOfScalar(u8, original, 0) != null) return error.InvalidSkillMetadata;
    var normalized: std.ArrayList(u8) = .empty;
    for (original, 0..) |byte, index| {
        if (byte == '\r' and index + 1 < original.len and original[index + 1] == '\n') continue;
        try normalized.append(a, byte);
    }
    const content = normalized.items;
    if (!std.mem.startsWith(u8, content, "---\n")) return error.InvalidSkillMetadata;
    const end = std.mem.indexOfPos(u8, content, 4, "\n---\n") orelse return error.InvalidSkillMetadata;
    var name: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var block: enum { none, name, description, ignored } = .none;
    var block_text: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, content[4..end], '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (line[0] == ' ' or line[0] == '\t') {
            if (block == .none) return error.InvalidSkillMetadata;
            if (block != .ignored) {
                if (block_text.items.len != 0) try block_text.append(a, ' ');
                try block_text.appendSlice(a, trimmed);
            }
            continue;
        }
        if (block == .name) name = try a.dupe(u8, block_text.items);
        if (block == .description) description = try a.dupe(u8, block_text.items);
        block = .none;
        block_text.clearRetainingCapacity();
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidSkillMetadata;
        const key = std.mem.trim(u8, line[0..colon], " ");
        var value = std.mem.trim(u8, line[colon + 1 ..], " ");
        const is_name = std.mem.eql(u8, key, "name");
        const is_description = std.mem.eql(u8, key, "description");
        if (!is_name and !is_description) {
            block = .ignored;
            continue;
        }
        if ((is_name and name != null) or (is_description and description != null)) return error.InvalidSkillMetadata;
        if (std.mem.eql(u8, value, ">") or std.mem.eql(u8, value, ">-") or std.mem.eql(u8, value, "|") or std.mem.eql(u8, value, "|-")) {
            block = if (is_name) .name else .description;
            continue;
        }
        if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\''))) value = value[1 .. value.len - 1];
        if (is_name) name = try a.dupe(u8, value) else description = try a.dupe(u8, value);
    }
    if (block == .name) name = try a.dupe(u8, block_text.items);
    if (block == .description) description = try a.dupe(u8, block_text.items);
    try cfg.text(name orelse return error.InvalidSkillMetadata, 128, false);
    try cfg.text(description orelse return error.InvalidSkillMetadata, 1024, false);
    const body = content[end + 5 ..];
    if (std.mem.trim(u8, body, " \r\n\t").len == 0) return error.EmptySkillBody;
    return .{ .name = name.?, .description = description.?, .body = body };
}
pub fn importLocal(a: std.mem.Allocator, io: std.Io, data: std.Io.Dir, source: []const u8, replacing: ?cfg.Skill) !Imported {
    return importLocalDiagnostic(a, io, data, source, replacing, null);
}
pub fn importLocalDiagnostic(a: std.mem.Allocator, io: std.Io, data: std.Io.Dir, source: []const u8, replacing: ?cfg.Skill, diagnostic: ?*Diagnostic) !Imported {
    return importLocalCancellable(a, io, data, source, replacing, diagnostic, null);
}
pub fn importLocalCancellable(a: std.mem.Allocator, io: std.Io, data: std.Io.Dir, source: []const u8, replacing: ?cfg.Skill, diagnostic: ?*Diagnostic, cancel: ?*@import("provider.zig").CancelToken) !Imported {
    if (!std.fs.path.isAbsolute(source) or std.mem.indexOfScalar(u8, source, 0) != null) return error.LocalSkillPathRequired;
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const owned = arena.allocator();
    var files: std.ArrayList(File) = .empty;
    const stage = try std.fmt.allocPrint(owned, "ai/skills/.stage-{s}", .{std.fmt.bytesToHex(id.ConversationId.generate().bytes, .lower)});
    try data.createDirPath(io, stage);
    defer data.deleteTree(io, stage) catch {};
    var destination = try data.openDir(io, stage, .{});
    defer destination.close(io);
    if (std.mem.endsWith(u8, source, "/SKILL.md")) {
        var dir = try std.Io.Dir.cwd().openDir(io, std.fs.path.dirname(source).?, .{ .follow_symlinks = false, .iterate = true });
        defer dir.close(io);
        if (diagnostic) |d| d.set("SKILL.md");
        try files.append(owned, try snapshot(dir, destination, io, "SKILL.md", "SKILL.md", cancel));
        // A file import has no implied access to adjacent resources.
    } else {
        var dir = try std.Io.Dir.cwd().openDir(io, source, .{ .follow_symlinks = false, .iterate = true });
        defer dir.close(io);
        try collect(dir, destination, io, owned, "", &files, diagnostic, cancel);
    }
    std.mem.sort(File, files.items, {}, struct {
        fn less(_: void, x: File, y: File) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.less);
    const main = for (files.items) |file| {
        if (std.mem.eql(u8, file.path, "SKILL.md")) break try readFile(destination, io, owned, "SKILL.md");
    } else return error.MissingSkillFile;
    if (diagnostic) |d| d.set("SKILL.md");
    const meta = try metadata(owned, main);
    // Validate local Markdown links without following external links or fetching.
    var rest = meta.body;
    while (std.mem.indexOf(u8, rest, "](")) |start| {
        rest = rest[start + 2 ..];
        const end = std.mem.indexOfScalar(u8, rest, ')') orelse break;
        const link = rest[0..end];
        rest = rest[end + 1 ..];
        if (link.len == 0 or link[0] == '#' or std.mem.indexOf(u8, link, "://") != null or std.mem.startsWith(u8, link, "mailto:")) continue;
        const path = link[0..(std.mem.indexOfScalar(u8, link, '#') orelse link.len)];
        // Sibling links are references to other skills, never filesystem grants.
        // They are resolved by selecting that skill separately through host.skills.
        if (std.mem.startsWith(u8, path, "../")) {
            try relative(path[3..]);
            if (std.mem.indexOfScalar(u8, path[3..], '/') == null) return error.InvalidSkillPath;
            continue;
        }
        if (diagnostic) |d| d.set(path);
        try relative(path);
        for (files.items) |file| {
            if (std.mem.eql(u8, file.path, path)) break;
        } else return error.MissingSkillResource;
    }
    const entries = try owned.alloc(Entry, files.items.len);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var total_bytes: u64 = 0;
    for (files.items, entries) |file, *entry| {
        entry.* = file;
        total_bytes += file.size;
        hash.update(file.path);
        hash.update(&.{0});
        hash.update(&file.sha256);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const revision = try owned.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
    const skill_id = if (replacing) |old| try owned.dupe(u8, old.id) else try owned.dupe(u8, &std.fmt.bytesToHex(id.ConversationId.generate().bytes, .lower));
    const package = try std.fmt.allocPrint(owned, "ai/skills/{s}/{s}", .{ skill_id, revision });
    const manifest = try std.json.Stringify.valueAlloc(owned, Manifest{ .files = entries }, .{});
    try destination.writeFile(io, .{ .sub_path = ".package.json", .data = manifest, .flags = .{ .permissions = @fromBackingInt(0o600) } });
    try data.createDirPath(io, std.fs.path.dirname(package).?);
    data.rename(stage, data, package, io) catch |err| switch (err) {
        error.DirNotEmpty => {},
        else => return err,
    };
    return .{ .arena = arena, .file_count = files.items.len, .total_bytes = total_bytes, .skill = .{ .id = skill_id, .revision = revision, .name = meta.name, .description = meta.description, .enabled = if (replacing) |old| old.enabled else true } };
}
pub fn read(a: std.mem.Allocator, io: std.Io, data: std.Io.Dir, skill: cfg.Skill, resource: []const u8) ![]u8 {
    return readDiagnostic(a, io, data, skill, resource, null);
}
pub fn readDiagnostic(a: std.mem.Allocator, io: std.Io, data: std.Io.Dir, skill: cfg.Skill, resource: []const u8, diagnostic: ?*Diagnostic) ![]u8 {
    const opened = try openResource(a, io, data, skill, resource, diagnostic);
    defer opened.file.close(io);
    const content = try a.alloc(u8, opened.entry.size);
    errdefer a.free(content);
    if (try opened.file.readPositionalAll(io, content, 0) != content.len or (try opened.file.stat(io)).size != content.len) return error.SkillSourceChanged;
    var checksum: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &checksum, .{});
    if (!std.mem.eql(u8, &checksum, &opened.entry.sha256)) return error.SkillIntegrityFailure;
    if (!std.unicode.utf8ValidateSlice(content) or std.mem.indexOfScalar(u8, content, 0) != null) return error.SkillResourceNotText;
    return content;
}
const Resource = struct { file: std.Io.File, entry: Entry };
fn openResource(a: std.mem.Allocator, io: std.Io, data: std.Io.Dir, skill: cfg.Skill, resource: []const u8, diagnostic: ?*Diagnostic) !Resource {
    try (cfg.Extensions{ .skills = &.{skill} }).validate();
    try relative(resource);
    const path = try std.fmt.allocPrint(a, "ai/skills/{s}/{s}", .{ skill.id, skill.revision });
    defer a.free(path);
    var package = try openDir(data, io, path);
    defer package.close(io);
    const source = try readFile(package, io, a, ".package.json");
    defer a.free(source);
    const manifest = try std.json.parseFromSlice(Manifest, a, source, .{});
    defer manifest.deinit();
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    for (manifest.value.files) |entry| {
        try relative(entry.path);
        h.update(entry.path);
        h.update(&.{0});
        h.update(&entry.sha256);
    }
    var package_hash: [32]u8 = undefined;
    h.final(&package_hash);
    if (!std.mem.eql(u8, &std.fmt.bytesToHex(package_hash, .lower), skill.revision)) return error.SkillIntegrityFailure;
    const entry = for (manifest.value.files) |entry| {
        if (std.mem.eql(u8, resource, entry.path)) break entry;
    } else return error.SkillResourceNotFound;
    if (diagnostic) |d| d.set(resource);
    const file = try openRegular(package, io, resource);
    errdefer file.close(io);
    if ((try file.stat(io)).size != entry.size) return error.SkillIntegrityFailure;
    return .{ .file = file, .entry = .{ .path = resource, .size = entry.size, .sha256 = entry.sha256 } };
}

fn ignored(name: []const u8) bool {
    for ([_][]const u8{ ".git", ".DS_Store", "__pycache__" }) |value| if (std.mem.eql(u8, name, value)) return true;
    return false;
}
/// A skill root takes precedence over nested resources; collections recurse only
/// until a SKILL.md is found. Never follow directory or file symlinks.
pub fn sources(a: std.mem.Allocator, io: std.Io, source: []const u8) ![]const []const u8 {
    if (!std.fs.path.isAbsolute(source)) return error.LocalSkillPathRequired;
    if (std.mem.endsWith(u8, source, "/SKILL.md")) return a.dupe([]const u8, &.{try a.dupe(u8, source)});
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |path| a.free(path);
        list.deinit(a);
    }
    var dir = try std.Io.Dir.cwd().openDir(io, source, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    try findSources(a, io, dir, source, &list);
    if (list.items.len == 0) return error.MissingSkillFile;
    std.mem.sort([]const u8, list.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    return list.toOwnedSlice(a);
}
fn findSources(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, list: *std.ArrayList([]const u8)) !void {
    const main = dir.statFile(io, "SKILL.md", .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (main) |stat| {
        if (stat.kind != .file) return error.UnsupportedSkillFile;
        const copy = try a.dupe(u8, path);
        errdefer a.free(copy);
        try list.append(a, copy);
        return;
    }
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (ignored(entry.name) or entry.kind != .directory) continue;
        var child = try dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
        defer child.close(io);
        const child_path = try std.fs.path.join(a, &.{ path, entry.name });
        defer a.free(child_path);
        try findSources(a, io, child, child_path, list);
    }
}

pub const Page = struct { content: []u8, total_bytes: usize, next_offset: ?usize };
/// Verify immutable text with fixed-size IO buffers, returning only the requested
/// page. File size is independent of context and memory page budgets.
pub fn readPage(a: std.mem.Allocator, io: std.Io, data: std.Io.Dir, skill: cfg.Skill, resource: []const u8, offset: usize, diagnostic: ?*Diagnostic, cancel: ?*@import("provider.zig").CancelToken) !Page {
    const opened = try openResource(a, io, data, skill, resource, diagnostic);
    defer opened.file.close(io);
    if (offset > opened.entry.size) return error.InvalidSkillOffset;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var page: [32 * 1024]u8 = undefined;
    var count: usize = 0;
    var position: usize = 0;
    var remaining: u3 = 0;
    var minimum: u8 = 0x80;
    var maximum: u8 = 0xbf;
    while (position < opened.entry.size) {
        if (cancel) |token| if (token.isCancelled()) return error.Cancelled;
        const n = @min(buffer.len, opened.entry.size - position);
        if (try opened.file.readPositionalAll(io, buffer[0..n], position) != n) return error.SkillSourceChanged;
        hash.update(buffer[0..n]);
        for (buffer[0..n], 0..) |byte, index| {
            if (remaining != 0) {
                if (byte < minimum or byte > maximum) return error.SkillResourceNotText;
                remaining -= 1;
                minimum = 0x80;
                maximum = 0xbf;
            } else if (byte == 0) return error.SkillResourceNotText else if (byte < 0x80) {} else if (byte >= 0xc2 and byte <= 0xdf) {
                remaining = 1;
            } else if (byte >= 0xe0 and byte <= 0xef) {
                remaining = 2;
                minimum = if (byte == 0xe0) 0xa0 else 0x80;
                maximum = if (byte == 0xed) 0x9f else 0xbf;
            } else if (byte >= 0xf0 and byte <= 0xf4) {
                remaining = 3;
                minimum = if (byte == 0xf0) 0x90 else 0x80;
                maximum = if (byte == 0xf4) 0x8f else 0xbf;
            } else return error.SkillResourceNotText;
            if (position + index >= offset and count < page.len) {
                page[count] = byte;
                count += 1;
            }
        }
        position += n;
    }
    if (remaining != 0) return error.SkillResourceNotText;
    if ((try opened.file.stat(io)).size != opened.entry.size) return error.SkillSourceChanged;
    var checksum: [32]u8 = undefined;
    hash.final(&checksum);
    if (!std.mem.eql(u8, &checksum, &opened.entry.sha256)) return error.SkillIntegrityFailure;
    if (count > 0 and page[0] & 0xc0 == 0x80) return error.InvalidSkillOffset;
    var end: usize = 0;
    var encoded: usize = 0;
    while (end < count) {
        const byte = page[end];
        const cost: usize = if (byte < 0x20) 6 else if (byte == '"' or byte == '\\') 2 else 1;
        if (encoded + cost > 48 * 1024) break;
        encoded += cost;
        end += 1;
    }
    while (end > 0 and !std.unicode.utf8ValidateSlice(page[0..end])) end -= 1;
    return .{ .content = try a.dupe(u8, page[0..end]), .total_bytes = opened.entry.size, .next_offset = if (offset + end < opened.entry.size) offset + end else null };
}
