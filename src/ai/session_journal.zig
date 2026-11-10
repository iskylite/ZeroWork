//! Durable, exclusively locked session outbox. Replaying data never starts a
//! worker. Model credentials and live pointers are not part of this format.
const std = @import("std");
const lifecycle = @import("session_lifecycle.zig");
const input = @import("session_input.zig");
const provider = @import("provider.zig");
const images = @import("image_attachments.zig");
pub const max_bytes = 128 * 1024 * 1024;
const compact_bytes = 8 * 1024 * 1024;
const Image = struct { path: []const u8, encoded: []const u8, captured_at: i64, offloaded: bool = false, owner: ?@import("../host/identity.zig").SessionHandle = null };
pub const Message = struct {
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
    presentation: ?[]const u8 = null,
    context_usage: ?@import("context_usage.zig").Stored = null,
    initial_input: ?input.Receipt = null,
    initial_origin: ?@import("tool_scope.zig").Owner = null,
    child_info: ?@import("child_agent.zig").Info = null,
    child_settings: ?@import("child_agent.zig").Settings = null,
    parent_binding: ?input.Fence = null,
    targets: ?[]const @import("../host/identity.zig").SessionHandle = null,
    children: ?[]const @import("../host/identity.zig").ConversationId = null,
    task_fact: ?@import("task_budget.zig").Fact = null,
    initial_text: ?[]const u8 = null,
    pub fn jsonStringify(self: StoredEvent, writer: *std.json.Stringify) !void {
        try writer.beginObject();
        inline for (@typeInfo(StoredEvent).@"struct".field_names) |name| {
            const emit = if (comptime std.mem.eql(u8, name, "child_settings") or std.mem.eql(u8, name, "child_info") or std.mem.eql(u8, name, "parent_binding") or std.mem.eql(u8, name, "targets") or std.mem.eql(u8, name, "children") or std.mem.eql(u8, name, "task_fact") or std.mem.eql(u8, name, "initial_text")) @field(self, name) != null else true;
            if (emit) {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
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
    stamp: ?Stamp = null,
    compact_at: usize = compact_bytes,
    mutex: std.atomic.Mutex = .unlocked,

    const Stamp = struct {
        inode: std.Io.File.INode,
        size: u64,
        mtime: std.Io.Timestamp,
        ctime: std.Io.Timestamp,

        fn of(stat: std.Io.File.Stat) Stamp {
            return .{ .inode = stat.inode, .size = stat.size, .mtime = stat.mtime, .ctime = stat.ctime };
        }
    };

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
        // A crash can interrupt an unacknowledged append. Only complete lines
        // are committed; bind validates all of them before repairing the tail.
        const committed = if (source.len == 0 or source[source.len - 1] == '\n') source.len else if (std.mem.lastIndexOfScalar(u8, source, '\n')) |index| index + 1 else 0;
        if (source.len != 0 and committed == 0) return error.InvalidSessionJournal;
        try result.bytes.appendSlice(a, source[0..committed]);
        result.stamp = Stamp.of(try dir.statFile(io, path, .{}));
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
            if ((row.schema != 1 and row.schema != 2 and row.schema != 3) or @as(u8, @intFromBool(row.event != null)) + @intFromBool(row.receipt != null) + @intFromBool(row.order != null) != 1) return error.InvalidSessionJournal;
            if (row.schema < 3) if (row.event) |event| if (event.kind == .task_fact or event.kind == .child_launch or event.task_fact != null or event.initial_text != null) return error.InvalidSessionJournal;
            if (row.schema == 1) if (row.event) |event| if (event.kind == .child_config or event.child_settings != null or event.kind == .child_create or event.kind == .child_bind or event.kind == .remove_family or event.child_info != null or event.parent_binding != null or event.targets != null or event.children != null or event.task_fact != null or event.kind == .task_fact or event.kind == .child_launch or event.initial_text != null) return error.InvalidSessionJournal;
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
            const messages = try decode(self.allocator, a, row.messages, &refs);
            const transcript = try decode(self.allocator, a, row.transcript, &refs);
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
        // Validate replay before touching the original file. Presentation
        // events replace a full display snapshot, not individual chat messages.
        if (self.bytes.items.len >= self.compact_at) {
            try self.compactLocked();
        } else if (self.stamp) |stamp| if (stamp.size != self.bytes.items.len) {
            try self.replaceBytes(self.bytes.items);
        };
        store.persist = .{ .context = self, .write = writeEvent };
        store.input_persist = .{ .context = self, .write = writeInput, .consumed = writeConsumed, .order = writeOrder };
        for (store.records.items) |record| record.inbox.persist = store.input_persist;
    }
    pub fn decode(allocator: std.mem.Allocator, a: std.mem.Allocator, source: []const Message, refs: *std.ArrayList(images.ContentRef)) ![]provider.Message {
        const messages = try a.alloc(provider.Message, source.len);
        for (source, messages) |message, *decoded| {
            var normal: std.ArrayList(images.ContentRef) = .empty;
            var offloaded: std.ArrayList(provider.OffloadedImage) = .empty;
            for (message.images) |value| {
                const size = try std.base64.standard.Decoder.calcSizeForSlice(value.encoded);
                if (size > images.max_bytes) return error.ImageTooLarge;
                const bytes = try a.alloc(u8, size);
                try std.base64.standard.Decoder.decode(bytes, value.encoded);
                const ref = cached: {
                    for (refs.items) |existing| {
                        const content = existing.content() orelse continue;
                        if (content.captured_at_ms == value.captured_at and std.mem.eql(u8, content.path, value.path) and std.mem.eql(u8, content.bytes, bytes)) break :cached existing;
                    }
                    var created = try images.ContentRef.create(allocator, value.path, bytes, value.captured_at, .{});
                    refs.append(allocator, created) catch |err| {
                        created.release();
                        return err;
                    };
                    break :cached created;
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
        const extended = event.kind == .child_config or event.child_settings != null or event.kind == .child_create or event.kind == .child_bind or event.kind == .remove_family or event.kind == .task_fact or event.kind == .child_launch;
        try self.append(.{ .schema = if (event.kind == .task_fact or event.kind == .child_launch) 3 else if (extended) 2 else 1, .event = event }, original.messages, &.{});
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
    pub fn encode(a: std.mem.Allocator, source: []const provider.Message) ![]Message {
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
        if (self.bytes.items.len >= self.compact_at or encoded.len + 1 > max_bytes -| self.bytes.items.len) try self.compactLocked();
        if (encoded.len + 1 > max_bytes -| self.bytes.items.len) return error.JournalLimit;
        const prior = self.bytes.items.len;
        try self.bytes.ensureUnusedCapacity(self.allocator, encoded.len + 1);
        self.bytes.appendSliceAssumeCapacity(encoded);
        self.bytes.appendAssumeCapacity('\n');
        errdefer self.bytes.shrinkRetainingCapacity(prior);
        const file = if (self.stamp != null) self.dir.openFile(self.io, self.path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => return error.JournalConflict,
            else => return err,
        } else self.dir.createFile(self.io, self.path, .{ .exclusive = true, .read = true, .permissions = @fromBackingInt(0o600) }) catch |err| switch (err) {
            error.PathAlreadyExists => return error.JournalConflict,
            else => return err,
        };
        defer file.close(self.io);
        if (self.stamp) |stamp| if (!std.meta.eql(stamp, Stamp.of(try file.stat(self.io)))) return error.JournalConflict;
        // Append only the new record. fsync precedes publication to the store;
        // on failure roll back to the last acknowledged boundary.
        errdefer self.rollbackAppend(file, prior) catch {};
        try file.writePositionalAll(self.io, self.bytes.items[prior..], prior);
        try file.sync(self.io);
        self.stamp = Stamp.of(try file.stat(self.io));
    }

    fn rollbackAppend(self: *Journal, file: std.Io.File, prior: usize) !void {
        try file.setLength(self.io, prior);
        try file.sync(self.io);
        self.stamp = Stamp.of(try file.stat(self.io));
    }

    fn checkUnchanged(self: *Journal) !void {
        const current: ?Stamp = if (self.dir.statFile(self.io, self.path, .{})) |stat| Stamp.of(stat) else |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (!std.meta.eql(self.stamp, current)) return error.JournalConflict;
    }

    fn replaceBytes(self: *Journal, bytes: []const u8) !void {
        try self.checkUnchanged();
        var atomic = try self.dir.createFileAtomic(self.io, self.path, .{ .permissions = @fromBackingInt(0o600), .make_path = true, .replace = true });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, bytes);
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
        self.stamp = Stamp.of(try self.dir.statFile(self.io, self.path, .{}));
    }

    /// Keep every lifecycle/receipt event, and the last complete display
    /// snapshot of each conversation at its original position in the stream.
    /// Forks carry their own pinned snapshots. No chat messages are discarded.
    pub fn compact(self: *Journal) !void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        try self.compactLocked();
    }

    fn compactLocked(self: *Journal) !void {
        const Header = struct { event: ?struct { kind: @FieldType(lifecycle.Event, "kind"), conversation: @FieldType(lifecycle.Event, "conversation") } = null };
        const Span = struct { start: usize, end: usize, superseded: bool = false };
        var latest = std.AutoHashMap(@FieldType(lifecycle.Event, "conversation"), usize).init(self.allocator);
        defer latest.deinit();
        var spans: std.ArrayList(Span) = .empty;
        defer spans.deinit(self.allocator);
        var lines = std.mem.splitScalar(u8, self.bytes.items, '\n');
        var offset: usize = 0;
        while (lines.next()) |line| {
            if (line.len == 0) {
                offset += 1;
                continue;
            }
            const parsed = try std.json.parseFromSlice(Header, self.allocator, line, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            const index = spans.items.len;
            try spans.append(self.allocator, .{ .start = offset, .end = offset + line.len + 1 });
            if (parsed.value.event) |event| if (event.kind == .presentation) {
                const entry = try latest.getOrPut(event.conversation);
                if (entry.found_existing) spans.items[entry.value_ptr.*].superseded = true;
                entry.value_ptr.* = index;
            };
            offset += line.len + 1;
        }
        var kept: std.ArrayList(u8) = .empty;
        errdefer kept.deinit(self.allocator);
        for (spans.items) |span| if (!span.superseded) try kept.appendSlice(self.allocator, self.bytes.items[span.start..span.end]);
        if (kept.items.len < self.bytes.items.len or (self.stamp != null and self.stamp.?.size != self.bytes.items.len)) {
            try self.replaceBytes(kept.items);
            self.bytes.deinit(self.allocator);
            self.bytes = kept;
        } else kept.deinit(self.allocator);
        self.compact_at = @min(max_bytes, @max(compact_bytes, self.bytes.items.len * 2));
    }
};
