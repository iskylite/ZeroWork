//! Atomic, exclusively locked session outbox. Replaying data never starts a
//! worker. Model credentials and live pointers are not part of this format.
const std = @import("std");
const lifecycle = @import("session_lifecycle.zig");
const input = @import("session_input.zig");
const provider = @import("provider.zig");
const images = @import("image_attachments.zig");
pub const max_bytes = 128 * 1024 * 1024;
const Image = struct { path: []const u8, encoded: []const u8, captured_at: i64, offloaded: bool = false, owner: ?@import("../host/identity.zig").SessionHandle = null };
const Message = struct {
    role: provider.Role,
    content: []const u8,
    tool_calls: []const provider.ToolCall = &.{},
    tool_call_id: ?[]const u8 = null,
    images: []const Image = &.{},
    image_owner: ?@import("../host/identity.zig").SessionHandle = null,
    image_transform: u64 = 0,
};
const StoredEvent = struct {
    kind: @FieldType(lifecycle.Event, "kind"),
    conversation: @FieldType(lifecycle.Event, "conversation"),
    agent: @FieldType(lifecycle.Event, "agent") = null,
    owner: @FieldType(lifecycle.Event, "owner") = null,
    revision: u64,
    environment: u64 = 1,
    operation: @FieldType(lifecycle.Event, "operation") = null,
    parent: @FieldType(lifecycle.Event, "parent") = null,
    source_revision: ?u64 = null,
    turn: u64 = 0,
    draft: ?[]const u8 = null,
    recoverable: bool = true,
    initial_input: ?input.Receipt = null,
    initial_origin: ?@import("tool_scope.zig").Owner = null,
};
const QueueOrder = struct { fence: input.Fence, ids: []const @import("../host/identity.zig").SubmissionId };
const Line = struct { schema: u8 = 1, event: ?StoredEvent = null, receipt: ?input.Receipt = null, order: ?QueueOrder = null, messages: []const Message = &.{}, transcript: []const Message = &.{} };
pub const Journal = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []u8,
    lock_file: std.Io.File,
    bytes: std.ArrayList(u8) = .empty,
    hash: ?[32]u8 = null,
    mutex: std.atomic.Mutex = .unlocked,

    pub fn open(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !Journal {
        if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOf(u8, path, "..") != null) return error.InvalidJournalPath;
        if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(io, parent);
        const lock_name = try std.fmt.allocPrint(a, "{s}.lock", .{path});
        defer a.free(lock_name);
        const lock_file = try dir.createFile(io, lock_name, .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true, .permissions = @fromBackingInt(0o600) });
        errdefer lock_file.close(io);
        const owned = try a.dupe(u8, path);
        errdefer a.free(owned);
        var result: Journal = .{ .allocator = a, .io = io, .dir = dir, .path = owned, .lock_file = lock_file };
        errdefer result.bytes.deinit(a);
        const source = dir.readFileAlloc(io, path, a, .limited(max_bytes)) catch |err| switch (err) {
            error.FileNotFound => return result,
            else => return err,
        };
        defer a.free(source);
        if (source.len != 0 and source[source.len - 1] != '\n') return error.InvalidSessionJournal;
        try result.bytes.appendSlice(a, source);
        result.hash = digest(source);
        return result;
    }
    pub fn deinit(self: *Journal) void {
        self.lock_file.close(self.io);
        self.allocator.free(self.path);
        self.bytes.deinit(self.allocator);
    }
    pub fn bind(self: *Journal, store: *lifecycle.Store) !void {
        if (store.records.items.len != 0 or store.agents.items.len != 0) return error.JournalRequiresEmptyStore;
        errdefer {
            const allocator = store.allocator;
            store.deinit();
            store.* = lifecycle.Store.init(allocator);
        }
        var lines = std.mem.splitScalar(u8, self.bytes.items, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const parsed = try std.json.parseFromSlice(Line, self.allocator, line, .{});
            defer parsed.deinit();
            const row = parsed.value;
            if (row.schema != 1 or @as(u8, @intFromBool(row.event != null)) + @intFromBool(row.receipt != null) + @intFromBool(row.order != null) != 1) return error.InvalidSessionJournal;
            if (row.order) |order| {
                const record = store.find(order.fence.conversation) orelse return error.InvalidSessionJournal;
                if (order.ids.len != record.inbox.entries.items.len or order.ids.len > @import("wire_history.zig").History.max_messages) return error.InvalidSessionJournal;
                var ordered: [@import("wire_history.zig").History.max_messages]*input.Entry = undefined;
                for (order.ids, 0..) |id, i| {
                    for (order.ids[0..i]) |prior| if (prior.eql(id)) return error.InvalidSessionJournal;
                    ordered[i] = record.inbox.findLocked(id) orelse return error.InvalidSessionJournal;
                }
                @memcpy(record.inbox.entries.items, ordered[0..order.ids.len]);
                continue;
            }
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            var refs: std.ArrayList(images.ContentRef) = .empty;
            defer {
                for (refs.items) |*ref| ref.release();
                refs.deinit(self.allocator);
            }
            const a = arena.allocator();
            const messages = try self.decode(a, row.messages, &refs);
            const transcript = try self.decode(a, row.transcript, &refs);
            if (row.event) |original| {
                var event: lifecycle.Event = .{ .kind = original.kind, .conversation = original.conversation, .revision = original.revision, .messages = messages };
                inline for (@typeInfo(StoredEvent).@"struct".field_names) |name| @field(event, name) = @field(original, name);
                try store.replay(event);
            } else {
                try store.replayInput(row.receipt.?, messages);
                if (transcript.len != 0) {
                    const receipt = row.receipt.?;
                    if (receipt.delivery != .consumed or receipt.turn == null) return error.InvalidSessionJournal;
                    const record = store.find(receipt.fence.conversation) orelse return error.InvalidSessionJournal;
                    var snapshot = try @import("wire_history.zig").History.copy(self.allocator, transcript, "");
                    errdefer snapshot.deinit();
                    record.recovery_history.deinit();
                    record.recovery_history = snapshot;
                    record.recovery_turn = receipt.turn.?;
                }
            }
        }
        store.persist = .{ .context = self, .write = writeEvent };
        store.input_persist = .{ .context = self, .write = writeInput, .consumed = writeConsumed, .order = writeOrder };
        for (store.records.items) |record| record.inbox.persist = store.input_persist;
    }
    fn decode(self: *Journal, a: std.mem.Allocator, source: []const Message, refs: *std.ArrayList(images.ContentRef)) ![]provider.Message {
        const messages = try a.alloc(provider.Message, source.len);
        for (source, messages) |message, *decoded| {
            var normal: std.ArrayList(images.ContentRef) = .empty;
            var offloaded: std.ArrayList(provider.OffloadedImage) = .empty;
            for (message.images) |value| {
                const size = try std.base64.standard.Decoder.calcSizeForSlice(value.encoded);
                if (size > images.max_bytes) return error.ImageTooLarge;
                const bytes = try a.alloc(u8, size);
                try std.base64.standard.Decoder.decode(bytes, value.encoded);
                var ref = try images.ContentRef.create(self.allocator, value.path, bytes, value.captured_at, .{});
                refs.append(self.allocator, ref) catch |err| {
                    ref.release();
                    return err;
                };
                if (value.offloaded) try offloaded.append(a, .{ .reference = ref, .owner = value.owner }) else try normal.append(a, ref);
            }
            decoded.* = .{ .role = message.role, .content = message.content, .tool_calls = message.tool_calls, .tool_call_id = message.tool_call_id, .images = normal.items, .offloaded_images = offloaded.items, .image_owner = message.image_owner, .image_transform = message.image_transform };
        }
        return messages;
    }
    fn writeEvent(raw: *anyopaque, original: lifecycle.Event) !void {
        const self: *Journal = @ptrCast(@alignCast(raw));
        var event: StoredEvent = undefined;
        inline for (@typeInfo(StoredEvent).@"struct".field_names) |name| @field(event, name) = @field(original, name);
        try self.append(.{ .event = event }, original.messages, &.{});
    }
    fn writeInput(raw: *anyopaque, receipt: input.Receipt, messages: []const provider.Message) !void {
        const self: *Journal = @ptrCast(@alignCast(raw));
        try self.append(.{ .receipt = receipt }, messages, &.{});
    }
    fn writeConsumed(raw: *anyopaque, receipt: input.Receipt, messages: []const provider.Message, transcript: []const provider.Message) !void {
        const self: *Journal = @ptrCast(@alignCast(raw));
        try self.append(.{ .receipt = receipt }, messages, transcript);
    }
    fn writeOrder(raw: *anyopaque, fence: input.Fence, ids: []const @import("../host/identity.zig").SubmissionId) !void {
        const self: *Journal = @ptrCast(@alignCast(raw));
        try self.append(.{ .order = .{ .fence = fence, .ids = ids } }, &.{}, &.{});
    }
    fn encode(a: std.mem.Allocator, source: []const provider.Message) ![]Message {
        const messages = try a.alloc(Message, source.len);
        for (source, messages) |message, *out| {
            const image_values = try a.alloc(Image, message.images.len + message.offloaded_images.len);
            for (image_values, 0..) |*value, i| {
                const ref = if (i < message.images.len) message.images[i] else message.offloaded_images[i - message.images.len].reference;
                const content = ref.content() orelse return error.EmptyAttachmentResult;
                const encoded = try a.alloc(u8, std.base64.standard.Encoder.calcSize(content.bytes.len));
                _ = std.base64.standard.Encoder.encode(encoded, content.bytes);
                value.* = .{ .path = content.path, .encoded = encoded, .captured_at = content.captured_at_ms, .offloaded = i >= message.images.len, .owner = if (i >= message.images.len) message.offloaded_images[i - message.images.len].owner else message.image_owner };
            }
            out.* = .{ .role = message.role, .content = message.content, .tool_calls = message.tool_calls, .tool_call_id = message.tool_call_id, .images = image_values, .image_owner = message.image_owner, .image_transform = message.image_transform };
        }
        return messages;
    }
    fn append(self: *Journal, original: Line, source: []const provider.Message, transcript: []const provider.Message) !void {
        // Different agent workers can commit consumed receipts concurrently.
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var line = original;
        line.messages = try encode(a, source);
        line.transcript = try encode(a, transcript);
        const encoded = try std.json.Stringify.valueAlloc(a, line, .{});
        if (encoded.len + 1 > max_bytes -| self.bytes.items.len) return error.JournalLimit;
        const prior = self.bytes.items.len;
        try self.bytes.ensureUnusedCapacity(self.allocator, encoded.len + 1);
        self.bytes.appendSliceAssumeCapacity(encoded);
        self.bytes.appendAssumeCapacity('\n');
        errdefer self.bytes.shrinkRetainingCapacity(prior);
        const current = self.dir.readFileAlloc(self.io, self.path, a, .limited(max_bytes)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (!std.meta.eql(self.hash, if (current) |value| @as(?[32]u8, digest(value)) else null)) return error.JournalConflict;
        var atomic = try self.dir.createFileAtomic(self.io, self.path, .{ .permissions = @fromBackingInt(0o600), .make_path = true, .replace = true });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, self.bytes.items);
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
        self.hash = digest(self.bytes.items);
    }
};
fn digest(bytes: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}
