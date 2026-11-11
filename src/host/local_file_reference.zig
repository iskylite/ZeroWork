//! Durable signing for local file locators. A token pins a conversation and an
//! observed file identity. The tool's current policy still controls access.
const std = @import("std");
const paths = @import("local_path.zig");
const ConversationId = @import("identity.zig").ConversationId;
pub const Key = [32]u8;

const key_name: [:0]const u8 = "ai-local-file-reference.key";
const prefix = "lf1:";
const header_bytes = 64;
const max_token_bytes = 8192;
const base64 = std.base64.url_safe_no_pad;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;

pub fn seal(a: std.mem.Allocator, key: Key, ref: paths.Reference) ![]u8 {
    if (!ref.conversation.valid() or !validPath(ref.absolute) or !validPath(ref.requested) or
        !std.fs.path.isAbsolute(ref.absolute) or ref.identity.inode == 0) return error.InvalidFileReference;
    const distinct_request = !std.mem.eql(u8, ref.absolute, ref.requested);
    const raw_size = header_bytes + ref.absolute.len + if (distinct_request) ref.requested.len + 1 else 0;
    const token_size = prefix.len + base64.Encoder.calcSize(raw_size);
    if (token_size > max_token_bytes) return error.InvalidFileReference;
    const raw = try a.alloc(u8, raw_size);
    defer a.free(raw);
    @memcpy(raw[32..48], &ref.conversation.bytes);
    std.mem.writeInt(u64, raw[48..56], ref.identity.device, .little);
    std.mem.writeInt(u64, raw[56..64], ref.identity.inode, .little);
    const absolute_end = header_bytes + ref.absolute.len;
    @memcpy(raw[header_bytes..absolute_end], ref.absolute);
    if (distinct_request) {
        raw[absolute_end] = 0;
        @memcpy(raw[absolute_end + 1 ..], ref.requested);
    }
    Hmac.create(raw[0..32], raw[32..], &key);
    const token = try a.alloc(u8, token_size);
    @memcpy(token[0..prefix.len], prefix);
    _ = base64.Encoder.encode(token[prefix.len..], raw);
    return token;
}

/// The returned path slices share one allocation. Use the caller's tool arena.
pub fn open(a: std.mem.Allocator, key: Key, conversation: ConversationId, token: []const u8) !paths.Reference {
    if (!conversation.valid()) return error.InvalidFileReference;
    const decoded = try decodeSigned(a, key, token) orelse return error.InvalidFileReference;
    const raw = decoded.raw;
    errdefer a.free(raw);
    if (!conversation.eql(decoded.conversation)) return error.InvalidFileReference;
    const encoded_paths = raw[header_bytes..];
    const split = std.mem.indexOfScalar(u8, encoded_paths, 0);
    const absolute = if (split) |index| encoded_paths[0..index] else encoded_paths;
    const requested = if (split) |index| encoded_paths[index + 1 ..] else absolute;
    const inode = std.mem.readInt(u64, raw[56..64], .little);
    if (!validPath(absolute) or !validPath(requested) or !std.fs.path.isAbsolute(absolute) or inode == 0) return error.InvalidFileReference;
    return .{
        .conversation = conversation,
        .requested = requested,
        .absolute = absolute,
        .identity = .{ .device = std.mem.readInt(u64, raw[48..56], .little), .inode = inode },
    };
}

/// Internal provider-message provenance. Each span names only the base64
/// locator value emitted by the host, never an occurrence in source text.
pub const Span = struct { start: u32, len: u32 };
pub const max_spans = 128;

pub fn validateSpans(content: []const u8, spans: []const Span) !void {
    if (spans.len > max_spans) return error.InvalidFileReferenceSpans;
    var end: usize = 0;
    for (spans) |span| {
        const start: usize = span.start;
        if (start < end or start > content.len or span.len > content.len - start or span.len > max_token_bytes)
            return error.InvalidFileReferenceSpans;
        end = start + span.len;
        const token = content[start..end];
        if (!std.mem.startsWith(u8, token, prefix)) return error.InvalidFileReferenceSpans;
    }
}

/// The controller captured this lineage from the Store. It is separate from
/// execution policy, which still gates every read or edit using these tokens.
pub const Projection = struct {
    key: Key,
    conversation: ConversationId,
    ancestors: [64]ConversationId = @splat(.{}),
    count: usize = 0,

    pub fn contains(self: *const Projection, id: ConversationId) bool {
        for (self.ancestors[0..self.count]) |ancestor| if (ancestor.eql(id)) return true;
        return false;
    }

    pub fn project(self: *const Projection, a: std.mem.Allocator, original: []const u8, spans: []const Span) ![]const u8 {
        if (self.count == 0 or spans.len == 0) return original;
        try validateSpans(original, spans);
        var projected: ?[]u8 = null;
        errdefer if (projected) |owned| a.free(owned);
        for (spans) |span| {
            const start: usize = span.start;
            const token = original[start .. start + span.len];
            const decoded = try decodeSigned(a, self.key, token) orelse continue;
            defer a.free(decoded.raw);
            if (!self.contains(decoded.conversation)) continue;
            // Changing only the fixed-width conversation bytes and MAC
            // preserves all surrounding original provider-message bytes.
            @memcpy(decoded.raw[32..48], &self.conversation.bytes);
            Hmac.create(decoded.raw[0..32], decoded.raw[32..], &self.key);
            if (projected == null) projected = try a.dupe(u8, original);
            _ = base64.Encoder.encode(projected.?[start + prefix.len .. start + span.len], decoded.raw);
        }
        return projected orelse original;
    }
};

const Decoded = struct { raw: []u8, conversation: ConversationId };
fn decodeSigned(a: std.mem.Allocator, key: Key, token: []const u8) !?Decoded {
    if (!std.mem.startsWith(u8, token, prefix) or token.len > max_token_bytes) return null;
    const data = token[prefix.len..];
    const len = base64.Decoder.calcSizeForSlice(data) catch return null;
    if (len <= header_bytes or base64.Encoder.calcSize(len) != data.len) return null;
    const raw = try a.alloc(u8, len);
    var valid = false;
    defer if (!valid) a.free(raw);
    base64.Decoder.decode(raw, data) catch return null;
    var mac: [32]u8 = undefined;
    Hmac.create(&mac, raw[32..], &key);
    if (!std.crypto.timing_safe.eql([32]u8, mac, raw[0..32].*)) return null;
    valid = true;
    return .{ .raw = raw, .conversation = .{ .bytes = raw[32..48].* } };
}

/// Find the field offset in our serialized receipt, after parsing the
/// structured block to obtain its exact field value. Advance past all blocks
/// in wire order so an earlier untrusted block cannot acquire a span.
pub const ReceiptSpans = struct {
    spans: std.ArrayList(Span) = .empty,
    offset: usize = 0,

    pub fn observe(self: *ReceiptSpans, a: std.mem.Allocator, receipt: []const u8, text: []const u8, trusted: bool) !void {
        const encoded = try std.json.Stringify.valueAlloc(a, .{ .text = text }, .{});
        defer a.free(encoded);
        const member = encoded[1 .. encoded.len - 1];
        const start = std.mem.indexOfPos(u8, receipt, self.offset, member) orelse return error.InvalidFileReferenceReceipt;
        self.offset = start + member.len;
        if (!trusted) return;
        const parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const token = parsed.value.object.get("file_ref") orelse return;
        if (token != .string) return;
        if (!std.mem.startsWith(u8, token.string, prefix) or token.string.len > max_token_bytes) return error.InvalidFileReferenceReceipt;
        const field = try std.json.Stringify.valueAlloc(a, .{ .file_ref = token.string }, .{});
        defer a.free(field);
        const escaped = try std.json.Stringify.valueAlloc(a, field[1 .. field.len - 1], .{});
        defer a.free(escaped);
        const marker = escaped[1 .. escaped.len - 1];
        const field_offset = std.mem.lastIndexOf(u8, member, marker) orelse return error.InvalidFileReferenceReceipt;
        const token_offset = std.mem.indexOf(u8, marker, token.string).?;
        try self.spans.append(a, .{ .start = @intCast(start + field_offset + token_offset), .len = @intCast(token.string.len) });
    }
};

fn validPath(path: []const u8) bool {
    return path.len != 0 and path.len < std.Io.Dir.max_path_bytes and std.unicode.utf8ValidateSlice(path) and
        std.mem.indexOfScalar(u8, path, 0) == null;
}

/// The caller holds the existing assistant session lock for this data scope.
/// A successfully materialized key is never replaced or silently regenerated.
pub fn loadOrCreate(io: std.Io, dir: std.Io.Dir) !Key {
    return read(io, dir) catch |err| switch (err) {
        error.FileNotFound => create(io, dir),
        else => err,
    };
}

fn read(io: std.Io, dir: std.Io.Dir) !Key {
    // O_NONBLOCK also makes an invalid FIFO fail validation without waiting
    // for its writer. Only a private, single-link regular file is accepted.
    const fd = while (true) {
        const rc = std.c.openat(dir.handle, key_name, .{ .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true, .NOCTTY = true });
        switch (std.c.errno(rc)) {
            .SUCCESS => break rc,
            .INTR => continue,
            .NOENT => return error.FileNotFound,
            else => return error.InvalidLocalFileReferenceKey,
        }
    };
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    defer file.close(io);
    var stat: std.c.Stat = undefined;
    if (std.c.fstat(fd, &stat) != 0 or stat.mode & std.c.S.IFMT != std.c.S.IFREG or
        stat.mode & 0o077 != 0 or stat.uid != std.c.geteuid() or stat.nlink != 1 or stat.size != @sizeOf(Key))
        return error.InvalidLocalFileReferenceKey;
    var key: Key = undefined;
    if (try file.readPositionalAll(io, &key, 0) != key.len) return error.InvalidLocalFileReferenceKey;
    return key;
}

fn create(io: std.Io, dir: std.Io.Dir) !Key {
    var key: Key = undefined;
    std.c.arc4random_buf(&key, key.len);
    var atomic = try dir.createFileAtomic(io, key_name, .{ .permissions = @fromBackingInt(0o600), .replace = false });
    defer atomic.deinit(io);
    try atomic.file.writePositionalAll(io, &key, 0);
    try atomic.file.sync(io);
    atomic.link(io) catch |err| switch (err) {
        error.PathAlreadyExists => return read(io, dir),
        else => return err,
    };
    while (true) {
        const rc = std.c.fsync(dir.handle);
        switch (std.c.errno(rc)) {
            .SUCCESS => return key,
            .INTR => continue,
            else => return error.LocalFileReferenceKeySyncFailed,
        }
    }
}

test "AI local file reference survives data scope reopen and keeps its original target" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const first = try loadOrCreate(io, tmp.dir);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const conversation: ConversationId = .{ .bytes = @splat(4) };
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    const absolute = try std.fs.path.join(a, &.{ path, "original.txt" });
    try tmp.dir.writeFile(io, .{ .sub_path = "original.txt", .data = "original" });
    const original = try paths.resolve(a, io, .{ .path = absolute, .conversation = conversation }, .file);
    defer original.deinit(a, io);
    var ref = try original.reference();
    ref.requested = "original.txt";
    const token = try seal(a, first, ref);

    const reopened = try loadOrCreate(io, tmp.dir);
    try std.testing.expectEqualSlices(u8, &first, &reopened);
    const locator = try open(a, reopened, conversation, token);
    try std.testing.expectEqualStrings(absolute, locator.absolute);
    try std.testing.expectEqualStrings("original.txt", locator.requested);
    try std.testing.expectError(error.InvalidFileReference, open(a, reopened, .{ .bytes = @splat(5) }, token));
    try tmp.dir.rename("original.txt", tmp.dir, "previous.txt", io);
    try tmp.dir.writeFile(io, .{ .sub_path = "original.txt", .data = "replacement" });
    try std.testing.expectError(error.SourceChanged, paths.resolve(a, io, .{ .conversation = conversation, .file_ref = locator }, .file));
}

test "AI local file reference key rejects a symlink and never overwrites it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "other", .data = "preserved" });
    try tmp.dir.symLink(io, "other", key_name, .{});
    try std.testing.expectError(error.InvalidLocalFileReferenceKey, loadOrCreate(io, tmp.dir));
    try std.testing.expectEqual(.sym_link, (try tmp.dir.statFile(io, key_name, .{ .follow_symlinks = false })).kind);
    const contents = try tmp.dir.readFileAlloc(io, "other", std.testing.allocator, .limited(32));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("preserved", contents);
}

test "AI local file reference receipt spans skip duplicated untrusted blocks and escaped source bytes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key: Key = @splat(42);
    const source: ConversationId = .{ .bytes = @splat(1) };
    const receiver: ConversationId = .{ .bytes = @splat(2) };
    const token = try seal(a, key, .{
        .conversation = source,
        .absolute = "/sample.txt",
        .requested = "sample.txt",
        .identity = .{ .device = 3, .inode = 4 },
    });
    const raw_source = try std.fmt.allocPrint(a, "原文\n\"file_ref\":\"{s}\"", .{token});
    const body = try std.json.Stringify.valueAlloc(a, .{ .file_ref = token, .text = raw_source }, .{});
    const Block = struct { type: []const u8, text: []const u8 };
    const blocks = [_]Block{ .{ .type = "text", .text = body }, .{ .type = "structured", .text = body } };
    const receipt = try std.json.Stringify.valueAlloc(a, .{ .status = "succeeded", .content = blocks }, .{});
    var located: ReceiptSpans = .{};
    for (blocks) |block| try located.observe(a, receipt, block.text, std.mem.eql(u8, block.type, "structured"));
    try std.testing.expectEqual(@as(usize, 1), located.spans.items.len);
    const offset = located.spans.items[0].start;
    try std.testing.expect(offset > std.mem.indexOf(u8, receipt, "structured").?);
    try std.testing.expectEqualStrings(token, receipt[offset .. offset + token.len]);
    const no_lineage: Projection = .{ .key = key, .conversation = receiver };
    try std.testing.expectEqualStrings(receipt, try no_lineage.project(a, receipt, located.spans.items));
    var projection = no_lineage;
    projection.ancestors[0] = source;
    projection.count = 1;
    const projected = try projection.project(a, receipt, located.spans.items);
    try std.testing.expectEqualStrings(receipt[0..offset], projected[0..offset]);
    try std.testing.expectEqualStrings(receipt[offset + token.len ..], projected[offset + token.len ..]);
    const locator = try open(a, key, receiver, projected[offset .. offset + token.len]);
    try std.testing.expectEqualStrings("sample.txt", locator.requested);
}
