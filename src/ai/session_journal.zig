//! Durable, exclusively locked session outbox. Replaying data never starts a
//! worker. Model credentials and live pointers are not part of this format.
const std = @import("std");
const lifecycle = @import("session_lifecycle.zig");
const input = @import("session_input.zig");
const provider = @import("provider.zig");
const images = @import("image_attachments.zig");
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
    origin: @FieldType(provider.Message, "origin") = .user_or_tool,
    file_reference_spans: @FieldType(provider.Message, "file_reference_spans") = &.{},

    pub fn jsonStringify(self: Message, writer: *std.json.Stringify) !void {
        try writer.beginObject();
        inline for (@typeInfo(Message).@"struct".field_names) |name| {
            const omit = if (comptime std.mem.eql(u8, name, "origin")) self.origin == .user_or_tool else if (comptime std.mem.eql(u8, name, "file_reference_spans")) self.file_reference_spans.len == 0 else false;
            if (!omit) {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
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
    workspace: @FieldType(lifecycle.Event, "workspace") = null,
    workspace_source: @FieldType(lifecycle.Event, "workspace_source") = null,
    workspace_change: @FieldType(lifecycle.Event, "workspace_change") = null,
    workspace_ack_revision: @FieldType(lifecycle.Event, "workspace_ack_revision") = null,
    pub fn jsonStringify(self: StoredEvent, writer: *std.json.Stringify) !void {
        try writer.beginObject();
        inline for (@typeInfo(StoredEvent).@"struct".field_names) |name| {
            const emit = if (comptime std.mem.eql(u8, name, "child_settings") or std.mem.eql(u8, name, "child_info") or std.mem.eql(u8, name, "parent_binding") or std.mem.eql(u8, name, "targets") or std.mem.eql(u8, name, "children") or std.mem.eql(u8, name, "task_fact") or std.mem.eql(u8, name, "initial_text") or std.mem.startsWith(u8, name, "workspace")) @field(self, name) != null else true;
            if (emit) {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
};
const QueueOrder = struct { fence: input.Fence, ids: []const @import("../host/identity.zig").SubmissionId };
const Consumed = struct { receipt: input.Receipt, messages: []const Message };
const Line = struct {
    schema: u8 = 1,
    event: ?StoredEvent = null,
    receipt: ?input.Receipt = null,
    order: ?QueueOrder = null,
    messages: []const Message = &.{},
    transcript: []const Message = &.{},
    consumed_batch: ?[]const Consumed = null,

    pub fn jsonStringify(self: Line, writer: *std.json.Stringify) !void {
        try writer.beginObject();
        inline for (@typeInfo(Line).@"struct".field_names) |name| {
            if (!(comptime std.mem.eql(u8, name, "consumed_batch")) or self.consumed_batch != null) {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
};
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
    checkpoint_job: ?*Checkpoint = null,

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
        const source = dir.readFileAlloc(io, path, a, .unlimited) catch |err| switch (err) {
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
        std.debug.assert(self.checkpoint_job == null);
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
            if (row.schema < 1 or row.schema > 4) return error.InvalidSessionJournal;
            const kinds: u8 = @as(u8, @intFromBool(row.event != null)) + @intFromBool(row.receipt != null) + @intFromBool(row.order != null) + @intFromBool(row.consumed_batch != null);
            if (kinds != 1) return error.InvalidSessionJournal;
            if (row.schema < 4) {
                if (row.event) |event| if (workspaceEvent(event)) return error.InvalidSessionJournal;
                if (row.consumed_batch != null or (row.receipt != null and row.receipt.?.workspace_revision != null) or hasMessageProvenance(row.messages) or hasMessageProvenance(row.transcript)) return error.InvalidSessionJournal;
            }
            if (row.schema < 3) if (row.event) |event| if (event.kind == .task_fact or event.kind == .child_launch or event.task_fact != null or event.initial_text != null) return error.InvalidSessionJournal;
            if (row.schema == 1) if (row.event) |event| if (event.kind == .child_config or event.child_settings != null or event.kind == .child_create or event.kind == .child_bind or event.kind == .remove_family or event.child_info != null or event.parent_binding != null or event.targets != null or event.children != null or event.task_fact != null or event.kind == .task_fact or event.kind == .child_launch or event.initial_text != null) return error.InvalidSessionJournal;
            if (row.order) |order| {
                const record = store.find(order.fence.conversation) orelse return error.InvalidSessionJournal;
                if (order.ids.len != record.inbox.entries.items.len) return error.InvalidSessionJournal;
                const ordered = try self.allocator.alloc(*input.Entry, order.ids.len);
                defer self.allocator.free(ordered);
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
            } else if (row.consumed_batch) |batch| {
                if (batch.len == 0 or messages.len != 0) return error.InvalidSessionJournal;
                const first = batch[0].receipt;
                const record = store.find(first.fence.conversation) orelse return error.InvalidSessionJournal;
                for (batch, 0..) |consumed, i| {
                    const receipt = consumed.receipt;
                    if (!receipt.fence.eql(first.fence) or receipt.turn != first.turn or receipt.request_sequence == null or receipt.request_sequence != first.request_sequence or receipt.delivery != .consumed or record.inbox.findLocked(receipt.id) == null) return error.InvalidSessionJournal;
                    for (batch[0..i]) |prior| if (prior.receipt.id.eql(receipt.id)) return error.InvalidSessionJournal;
                    try store.replayInput(receipt, try decode(self.allocator, a, consumed.messages, &refs));
                }
                try self.restoreTranscript(store, first, transcript);
            } else {
                try store.replayInput(row.receipt.?, messages);
                if (transcript.len != 0) try self.restoreTranscript(store, row.receipt.?, transcript);
            }
        }
        // Validate replay before touching the original file. Presentation
        // events replace a full display snapshot, not individual chat messages.
        if (self.bytes.items.len >= self.compact_at) {
            try self.compactLocked();
        } else if (self.stamp) |stamp| if (stamp.size != self.bytes.items.len) {
            try self.replaceBytes(self.bytes.items);
        };
        store.persist = .{ .context = self, .write = writeEvent, .checkpoint = checkpoint };
        try store.revalidateRecoveredWorkspaces(self.io);
        store.input_persist = .{ .context = self, .write = writeInput, .consumed = writeConsumed, .order = writeOrder, .consume_batch = writeConsumedBatch };
        for (store.records.items) |record| {
            record.inbox.pauseLegacyInputs();
            record.inbox.persist = store.input_persist;
        }
    }
    fn restoreTranscript(self: *Journal, store: *lifecycle.Store, receipt: input.Receipt, transcript: []const provider.Message) !void {
        if (receipt.delivery != .consumed or receipt.turn == null or transcript.len == 0) return error.InvalidSessionJournal;
        const record = store.find(receipt.fence.conversation) orelse return error.InvalidSessionJournal;
        const snapshot = try @import("wire_history.zig").History.copy(self.allocator, transcript, "");
        record.recovery_history.deinit();
        record.recovery_history = snapshot;
        record.recovery_turn = receipt.turn.?;
    }
    fn workspaceEvent(event: StoredEvent) bool {
        return event.kind == .workspace_update or event.kind == .workspace_ack or event.workspace != null or event.workspace_change != null or event.workspace_source != null or event.workspace_ack_revision != null or
            (event.initial_input != null and event.initial_input.?.workspace_revision != null);
    }
    fn hasMessageProvenance(messages: anytype) bool {
        for (messages) |message| if (message.origin != .user_or_tool or message.file_reference_spans.len != 0) return true;
        return false;
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
            decoded.* = .{ .role = message.role, .content = message.content, .tool_calls = message.tool_calls, .tool_call_id = message.tool_call_id, .images = normal.items, .offloaded_images = offloaded.items, .image_owner = message.image_owner, .image_transform = message.image_transform, .origin = message.origin, .file_reference_spans = message.file_reference_spans };
        }
        return messages;
    }
    const Checkpoint = struct {
        journal: *Journal,
        event: lifecycle.Event,
        latest_revision: u64,
        thread: ?std.Thread = null,
        done: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,
        fn run(self: *Checkpoint) void {
            writeEvent(self.journal, self.event) catch |err| {
                self.failure = err;
            };
            while (!self.journal.mutex.tryLock()) std.Thread.yield() catch {};
            self.journal.checkpoint_job = null;
            self.journal.mutex.unlock();
            self.done.store(true, .release);
        }
        fn ready(raw: *anyopaque) bool {
            const self: *Checkpoint = @ptrCast(@alignCast(raw));
            return self.done.load(.acquire);
        }
        fn finish(raw: *anyopaque) !void {
            const self: *Checkpoint = @ptrCast(@alignCast(raw));
            std.debug.assert(self.done.load(.acquire));
            if (self.failure) |err| return err;
        }
        fn release(raw: *anyopaque) void {
            const self: *Checkpoint = @ptrCast(@alignCast(raw));
            if (self.thread) |thread| thread.join();
            self.journal.allocator.destroy(self);
        }
    };
    fn checkpoint(raw: *anyopaque, event: lifecycle.Event) !lifecycle.Persistence.Write {
        const self: *Journal = @ptrCast(@alignCast(raw));
        // Controller ticks never wait on another agent's journal IO.
        if (!self.mutex.tryLock()) return error.WorkerBusy;
        defer self.mutex.unlock();
        if (self.checkpoint_job != null) return error.WorkerBusy;
        const job = try self.allocator.create(Checkpoint);
        errdefer self.allocator.destroy(job);
        job.* = .{ .journal = self, .event = event, .latest_revision = event.revision };
        self.checkpoint_job = job;
        errdefer self.checkpoint_job = null;
        job.thread = try std.Thread.spawn(.{}, Checkpoint.run, .{job});
        return .{ .context = job, .ready = Checkpoint.ready, .finish = Checkpoint.finish, .release = Checkpoint.release };
    }
    fn writeEvent(raw: *anyopaque, original: lifecycle.Event) !void {
        const self: *Journal = @ptrCast(@alignCast(raw));
        var event: StoredEvent = undefined;
        inline for (@typeInfo(StoredEvent).@"struct".field_names) |name| @field(event, name) = @field(original, name);
        const extended = event.kind == .child_config or event.child_settings != null or event.kind == .child_create or event.kind == .child_bind or event.kind == .remove_family or event.kind == .task_fact or event.kind == .child_launch;
        const schema: u8 = if (workspaceEvent(event) or hasMessageProvenance(original.messages)) 4 else if (event.kind == .task_fact or event.kind == .child_launch) 3 else if (extended) 2 else 1;
        try self.append(.{ .schema = schema, .event = event }, original.messages, &.{});
    }
    fn writeInput(raw: *anyopaque, receipt: input.Receipt, messages: []const provider.Message) !void {
        const self: *Journal = @ptrCast(@alignCast(raw));
        try self.append(.{ .schema = if (receipt.workspace_revision != null or hasMessageProvenance(messages)) 4 else 1, .receipt = receipt }, messages, &.{});
    }
    fn writeConsumed(raw: *anyopaque, receipt: input.Receipt, messages: []const provider.Message, transcript: []const provider.Message) !void {
        const self: *Journal = @ptrCast(@alignCast(raw));
        try self.append(.{ .schema = if (receipt.workspace_revision != null or hasMessageProvenance(messages) or hasMessageProvenance(transcript)) 4 else 1, .receipt = receipt }, messages, transcript);
    }
    fn writeConsumedBatch(raw: *anyopaque, rows: []const input.Consumption, transcript: []const provider.Message) !void {
        const self: *Journal = @ptrCast(@alignCast(raw));
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const batch = try a.alloc(Consumed, rows.len);
        for (rows, batch) |row, *item| item.* = .{ .receipt = row.receipt, .messages = try encode(a, row.payload) };
        try self.append(.{ .schema = 4, .consumed_batch = batch }, &.{}, transcript);
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
            out.* = .{ .role = message.role, .content = message.content, .tool_calls = message.tool_calls, .tool_call_id = message.tool_call_id, .images = image_values, .image_owner = message.image_owner, .image_transform = message.image_transform, .origin = message.origin, .file_reference_spans = message.file_reference_spans };
        }
        return messages;
    }
    fn append(self: *Journal, original: Line, source: []const provider.Message, transcript: []const provider.Message) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var line = original;
        // Immutable caller-owned messages remain pinned through acknowledgement.
        // Encode outside the journal lock so other agents' small controller
        // writes do not wait on full transcript serialization.
        line.messages = try encode(a, source);
        line.transcript = try encode(a, transcript);
        var encoded = try std.json.Stringify.valueAlloc(a, line, .{});
        // Serialize only the append, boundary checks and durable acknowledgement.
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        if (line.event) |*event| if (event.kind == .checkpoint) {
            if (self.checkpoint_job) |job| if (event.conversation.eql(job.event.conversation) and event.turn == job.event.turn) {
                if (event.revision != job.latest_revision) {
                    event.revision = job.latest_revision;
                    // A handoff won the race; only that uncommon path needs
                    // to re-encode with the just-committed binding revision.
                    encoded = try std.json.Stringify.valueAlloc(a, line, .{});
                }
            };
        };
        if (self.bytes.items.len >= self.compact_at) try self.compactLocked();
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
        // A live handoff may commit before the checkpoint worker acquires the
        // journal. Use that committed binding revision in the later checkpoint;
        // the reverse ordering already has checkpoint-before-handoff semantics.
        if (line.event) |event| if (event.kind == .handoff) {
            if (self.checkpoint_job) |job| if (event.conversation.eql(job.event.conversation)) {
                job.latest_revision = event.revision;
            };
        };
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
        self.compact_at = @max(compact_bytes, self.bytes.items.len *| 2);
    }
};
