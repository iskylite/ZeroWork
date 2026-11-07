//! Immutable, content-addressed local packages. No scripts or remote fetches.
const std = @import("std");
const cfg = @import("../config/ai_extensions.zig");
const id = @import("../host/identity.zig");
pub const max_files = 128;
pub const max_bytes = 4 * 1024 * 1024;
pub const Entry = struct { path: []const u8, size: usize, sha256: [32]u8 };
pub const Manifest = struct { files: []const Entry };
const File = struct { path: []const u8, bytes: []const u8 };
pub const Imported = struct {
    arena: std.heap.ArenaAllocator,
    skill: cfg.Skill,
    pub fn deinit(self: *Imported) void {
        self.arena.deinit();
    }
};
pub fn relative(path: []const u8) !void {
    if (path.len == 0 or path.len > 512 or std.fs.path.isAbsolute(path) or std.mem.indexOfAny(u8, path, "\\\x00") != null) return error.InvalidSkillPath;
    var parts = std.mem.splitScalar(u8, path, '/');
    var depth: usize = 0;
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidSkillPath;
        depth += 1;
    }
    if (depth > 8) return error.SkillDepthLimit;
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
pub fn readFile(root: std.Io.Dir, io: std.Io, a: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    try relative(path);
    const parent = std.fs.path.dirname(path);
    var dir = if (parent) |value| try openDir(root, io, value) else try root.openDir(io, ".", .{ .follow_symlinks = false });
    defer dir.close(io);
    const source_stat = try dir.statFile(io, std.fs.path.basename(path), .{ .follow_symlinks = false });
    if (source_stat.kind != .file) return error.UnsupportedSkillFile;
    // macOS opens a shared nonblocking lock atomically (O_SHLOCK|O_NONBLOCK),
    // so replacing a selected file with a FIFO cannot block before fstat.
    const file = try dir.openFile(io, std.fs.path.basename(path), .{ .follow_symlinks = false, .resolve_beneath = true, .lock = .shared, .lock_nonblocking = true });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.UnsupportedSkillFile;
    if (stat.size > limit) return error.SkillFileTooLarge;
    const bytes = try a.alloc(u8, @intCast(stat.size));
    errdefer a.free(bytes);
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len or (try file.stat(io)).size != bytes.len) return error.SkillSourceChanged;
    return bytes;
}
fn collect(dir: std.Io.Dir, io: std.Io, a: std.mem.Allocator, prefix: []const u8, files: *std.ArrayList(File), bytes: *usize) !void {
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        const path = if (prefix.len == 0) try a.dupe(u8, entry.name) else try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, entry.name });
        try relative(path);
        if (std.mem.eql(u8, path, ".package.json")) return error.ReservedSkillFile;
        if (entry.kind == .directory) {
            var child = try dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
            defer child.close(io);
            try collect(child, io, a, path, files, bytes);
        } else if (entry.kind == .file) {
            if (files.items.len >= max_files) return error.SkillFileLimit;
            const content = try readFile(dir, io, a, entry.name, 512 * 1024);
            bytes.* += content.len;
            if (bytes.* > max_bytes) return error.SkillPackageTooLarge;
            try files.append(a, .{ .path = path, .bytes = content });
        } else return error.UnsupportedSkillFile;
    }
}
fn metadata(a: std.mem.Allocator, original: []const u8) !struct { name: []const u8, description: []const u8, body: []const u8 } {
    if (original.len > 64 * 1024 or !std.unicode.utf8ValidateSlice(original) or std.mem.indexOfScalar(u8, original, 0) != null) return error.InvalidSkillMetadata;
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
    if (!std.fs.path.isAbsolute(source) or std.mem.indexOfScalar(u8, source, 0) != null) return error.LocalSkillPathRequired;
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const owned = arena.allocator();
    var files: std.ArrayList(File) = .empty;
    var total: usize = 0;
    if (std.mem.endsWith(u8, source, "/SKILL.md")) {
        var dir = try std.Io.Dir.cwd().openDir(io, std.fs.path.dirname(source).?, .{ .follow_symlinks = false, .iterate = true });
        defer dir.close(io);
        const bytes = try readFile(dir, io, owned, "SKILL.md", 64 * 1024);
        try files.append(owned, .{ .path = "SKILL.md", .bytes = bytes });
        // A file import has no implied access to adjacent resources.
    } else {
        var dir = try std.Io.Dir.cwd().openDir(io, source, .{ .follow_symlinks = false, .iterate = true });
        defer dir.close(io);
        try collect(dir, io, owned, "", &files, &total);
    }
    std.mem.sort(File, files.items, {}, struct {
        fn less(_: void, x: File, y: File) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.less);
    const main = for (files.items) |file| {
        if (std.mem.eql(u8, file.path, "SKILL.md")) break file.bytes;
    } else return error.MissingSkillFile;
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
        try relative(path);
        for (files.items) |file| {
            if (std.mem.eql(u8, file.path, path)) break;
        } else return error.MissingSkillResource;
    }
    const entries = try owned.alloc(Entry, files.items.len);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (files.items, entries) |file, *entry| {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(file.bytes, &digest, .{});
        entry.* = .{ .path = file.path, .size = file.bytes.len, .sha256 = digest };
        hash.update(file.path);
        hash.update(&.{0});
        hash.update(&digest);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const revision = try owned.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
    const skill_id = if (replacing) |old| try owned.dupe(u8, old.id) else try owned.dupe(u8, &std.fmt.bytesToHex(id.ConversationId.generate().bytes, .lower));
    const package = try std.fmt.allocPrint(owned, "ai/skills/{s}/{s}", .{ skill_id, revision });
    const stage = try std.fmt.allocPrint(owned, "ai/skills/.stage-{s}", .{std.fmt.bytesToHex(id.ConversationId.generate().bytes, .lower)});
    try data.createDirPath(io, stage);
    defer data.deleteTree(io, stage) catch {};
    var destination = try data.openDir(io, stage, .{});
    defer destination.close(io);
    for (files.items) |file| {
        if (std.fs.path.dirname(file.path)) |parent| try destination.createDirPath(io, parent);
        var out = try destination.createFile(io, file.path, .{ .exclusive = true, .permissions = @fromBackingInt(0o600) });
        defer out.close(io);
        try out.writeStreamingAll(io, file.bytes);
        try out.sync(io);
    }
    const manifest = try std.json.Stringify.valueAlloc(owned, Manifest{ .files = entries }, .{});
    try destination.writeFile(io, .{ .sub_path = ".package.json", .data = manifest, .flags = .{ .permissions = @fromBackingInt(0o600) } });
    try data.createDirPath(io, std.fs.path.dirname(package).?);
    data.rename(stage, data, package, io) catch |err| switch (err) {
        error.DirNotEmpty => {},
        else => return err,
    };
    return .{ .arena = arena, .skill = .{ .id = skill_id, .revision = revision, .name = meta.name, .description = meta.description, .enabled = if (replacing) |old| old.enabled else true } };
}
pub fn read(a: std.mem.Allocator, io: std.Io, data: std.Io.Dir, skill: cfg.Skill, resource: []const u8) ![]u8 {
    try (cfg.Extensions{ .skills = &.{skill} }).validate();
    try relative(resource);
    const path = try std.fmt.allocPrint(a, "ai/skills/{s}/{s}", .{ skill.id, skill.revision });
    defer a.free(path);
    var package = try openDir(data, io, path);
    defer package.close(io);
    const source = try readFile(package, io, a, ".package.json", 64 * 1024);
    defer a.free(source);
    const manifest = try std.json.parseFromSlice(Manifest, a, source, .{});
    defer manifest.deinit();
    if (manifest.value.files.len > max_files) return error.InvalidSkillPackage;
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
    const content = try readFile(package, io, a, resource, 64 * 1024);
    errdefer a.free(content);
    var checksum: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &checksum, .{});
    if (content.len != entry.size or !std.mem.eql(u8, &checksum, &entry.sha256)) return error.SkillIntegrityFailure;
    if (!std.unicode.utf8ValidateSlice(content) or std.mem.indexOfScalar(u8, content, 0) != null) return error.SkillResourceNotText;
    return content;
}
