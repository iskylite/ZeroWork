//! Preserve full standard MCP results; move binary and large text out of the
//! model's bounded JSON transcript, keeping exact local artifacts retrievable.
const std = @import("std");
const images = @import("image_attachments.zig");
const local = @import("local_skills.zig");
pub const File = struct { name: []const u8, path: []const u8, mime_type: []const u8, bytes: u64, size: []const u8 };
pub const Captured = struct {
    arena: std.heap.ArenaAllocator,
    value: std.json.Value,
    files: []const File,
    images: []images.ContentRef,
    reference: ?[]const u8,
    directory: ?[]const u8,
    pub fn deinit(self: *Captured, a: std.mem.Allocator) void {
        for (self.images) |*ref| ref.release();
        a.free(self.images);
        self.arena.deinit();
    }
};
fn string(object: std.json.Value, name: []const u8) ?[]const u8 {
    if (object != .object) return null;
    const value = object.object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}
fn put(a: std.mem.Allocator, object: *std.json.Value, name: []const u8, value: std.json.Value) !void {
    try object.object.put(a, name, value);
}
fn save(a: std.mem.Allocator, io: std.Io, directory: []const u8, name: []const u8, bytes: []const u8, mime: []const u8) !File {
    const path = try std.fs.path.join(a, &.{ directory, name });
    var dir = try std.Io.Dir.cwd().openDir(io, directory, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = name, .data = bytes, .flags = .{ .exclusive = true, .permissions = @fromBackingInt(0o600) } });
    return .{ .name = name, .path = path, .mime_type = mime, .bytes = bytes.len, .size = try @import("extension_sizes.zig").format(a, bytes.len) };
}
fn gather(a: std.mem.Allocator, value: *std.json.Value, found: *std.ArrayList(*std.json.Value)) !void {
    if (value.* == .array) {
        for (value.array.items) |*item| try gather(a, item, found);
        return;
    }
    if (value.* != .object) return;
    if ((value.object.get("mimeType") != null and value.object.get("data") != null) or (value.object.get("uri") != null and value.object.get("blob") != null)) try found.append(a, value);
    inline for (.{ "content", "contents", "messages", "resource" }) |key| if (value.object.getPtr(key)) |child| try gather(a, child, found);
}
pub fn capture(a: std.mem.Allocator, io: std.Io, root: []const u8, body: []const u8) !Captured {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const owned = arena.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, owned, body, .{ .allocate = .alloc_always });
    var value = parsed.value;
    var blocks: std.ArrayList(*std.json.Value) = .empty;
    try gather(owned, &value, &blocks);
    const preserve = body.len > 40 * 1024 or blocks.items.len != 0;
    var refs: std.ArrayList(images.ContentRef) = .empty;
    errdefer {
        for (refs.items) |*ref| ref.release();
        refs.deinit(a);
    }
    var files: std.ArrayList(File) = .empty;
    var reference: ?[]const u8 = null;
    var directory: ?[]const u8 = null;
    if (preserve) {
        reference = try owned.dupe(u8, &std.fmt.bytesToHex(@import("../host/identity.zig").TaskId.generate().bytes, .lower));
        directory = try std.fs.path.join(owned, &.{ root, "ai/mcp-results", reference.? });
        try std.Io.Dir.cwd().createDirPath(io, directory.?);
        const raw = try save(owned, io, directory.?, "result.json", body, "application/json");
        try files.append(owned, raw);
        for (blocks.items, 0..) |target, index| {
            const kind = string(target.*, "type") orelse "resource";
            const key: []const u8 = if (target.object.get("blob") != null) "blob" else "data";
            const encoded = string(target.*, key) orelse continue;
            const mime = string(target.*, "mimeType") orelse "application/octet-stream";
            const count = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.InvalidMcpBase64;
            const bytes = try owned.alloc(u8, count);
            std.base64.standard.Decoder.decode(bytes, encoded) catch return error.InvalidMcpBase64;
            const extension: []const u8 = if (std.mem.eql(u8, mime, "image/png")) "png" else if (std.mem.eql(u8, mime, "image/jpeg")) "jpg" else if (std.mem.eql(u8, mime, "audio/wav")) "wav" else if (std.mem.eql(u8, mime, "audio/mpeg")) "mp3" else "bin";
            const name = try std.fmt.allocPrint(owned, "content-{d}.{s}", .{ index, extension });
            const file = try save(owned, io, directory.?, name, bytes, mime);
            try files.append(owned, file);
            _ = target.object.swapRemove(key);
            try put(owned, target, "file", .{ .string = file.path });
            try put(owned, target, "size", .{ .string = file.size });
            if (std.mem.eql(u8, kind, "image")) {
                if (refs.items.len >= 32) {
                    try put(owned, target, "preview_error", .{ .string = "Model image count budget reached; original file preserved." });
                    continue;
                }
                const ref = images.ContentRef.create(a, file.path, bytes, @intCast(@divTrunc((@import("retry.zig").Clock{}).now(), std.time.ns_per_ms)), .{}) catch |err| {
                    try put(owned, target, "preview_error", .{ .string = @errorName(err) });
                    continue;
                };
                errdefer {
                    var owned_ref = ref;
                    owned_ref.release();
                }
                try refs.append(a, ref);
            }
        }
        try put(owned, &value, "result_ref", .{ .string = reference.? });
        const model = try std.json.Stringify.valueAlloc(owned, value, .{});
        if (model.len > 40 * 1024) {
            var fallback: std.json.ObjectMap = .empty;
            try fallback.put(owned, "result_ref", .{ .string = reference.? });
            try fallback.put(owned, "result_file", .{ .string = raw.path });
            try fallback.put(owned, "size", .{ .string = raw.size });
            try fallback.put(owned, "message", .{ .string = "Full result preserved. Use host.mcp_result with result_ref and resource result.json to read it in pages." });
            try fallback.put(owned, "isError", value.object.get("isError") orelse .{ .bool = false });
            value = .{ .object = fallback };
        }
    }
    return .{ .arena = arena, .value = value, .files = files.items, .images = try refs.toOwnedSlice(a), .reference = reference, .directory = directory };
}
pub const Page = struct { content: []u8, total_bytes: u64, next_offset: ?u64 };
pub fn readPage(a: std.mem.Allocator, io: std.Io, directory: []const u8, resource: []const u8, offset: u64) !Page {
    try local.relative(resource);
    var dir = try std.Io.Dir.cwd().openDir(io, directory, .{ .follow_symlinks = false });
    defer dir.close(io);
    const file = try dir.openFile(io, resource, .{ .follow_symlinks = false, .resolve_beneath = true });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or offset > stat.size) return error.InvalidMcpResultOffset;
    const count: usize = @intCast(@min(8 * 1024, stat.size - offset));
    const bytes = try a.alloc(u8, count);
    errdefer a.free(bytes);
    if (try file.readPositionalAll(io, bytes, offset) != count) return error.McpResultChanged;
    var end = bytes.len;
    if (offset + count < stat.size) while (end > 0 and !std.unicode.utf8ValidateSlice(bytes[0..end])) : (end -= 1) {
        if (count - end > 3) return error.McpResourceNotText;
    };
    if (!std.unicode.utf8ValidateSlice(bytes[0..end]) or std.mem.indexOfScalar(u8, bytes[0..end], 0) != null) return error.McpResourceNotText;
    const page = try a.dupe(u8, bytes[0..end]);
    a.free(bytes);
    return .{ .content = page, .total_bytes = stat.size, .next_offset = if (offset + end < stat.size) offset + end else null };
}
