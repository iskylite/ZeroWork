//! Resumable discovery of legacy and active JSONL journals. Index rows hold
//! file offsets and display metadata. Only the selected record reader opens
//! the recorded ranges; index generation never decodes an attachment.
const std = @import("std");
const identity = @import("../host/identity.zig");
const Owner = @import("tool_scope.zig").Owner;
const Title = @import("conversation_title.zig").Title;
const lifecycle = @import("session_lifecycle.zig");
const input = @import("session_input.zig");
const A = std.mem.Allocator;
pub const Id = identity.ConversationId;
pub const Source = enum {
    legacy,
    active,
    pub fn path(self: Source) []const u8 {
        return switch (self) {
            .legacy => "ai-sessions.jsonl",
            .active => "ai-sessions-active.jsonl",
        };
    }
    fn indexPath(self: Source) []const u8 {
        return switch (self) {
            .legacy => "ai-sessions-legacy-index-v2.jsonl",
            .active => "ai-sessions-active-index-v2.jsonl",
        };
    }
};
pub const Limit = struct { inode: u64, end: u64 };
pub const Bounds = std.EnumArray(Source, ?Limit);
pub const Span = struct { source: Source, start: u64, end: u64 };
const Projection = struct { snapshot: bool = false, transcript: bool = false, draft: bool = false, workspace: bool = false };
const ReceiptIndex = struct { id: @import("../host/identity.zig").SubmissionId, delivery: @FieldType(input.Receipt, "delivery"), has_body: bool };
const PendingSpan = struct { receipt: ReceiptIndex, span: ?Span };
const Row = struct {
    conversation: Id,
    related: ?Id = null,
    origin: ?Owner = null,
    title: ?[]const u8 = null,
    removed: bool = false,
    child: bool = false,
    status: ?struct { can_restore: bool, can_copy: bool, first_use: bool } = null,
    recoverable: ?bool = null,
    history_pinned: ?bool = null,
    projection: Projection = .{},
    receipts: []const ReceiptIndex = &.{},
};
const Indexed = struct { start: u64, end: u64, items: []const Row };
const Commit = struct { inode: u64, from: u64, end: u64, rows: []const Indexed };
const Header = struct {
    event: ?struct {
        kind: @FieldType(lifecycle.Event, "kind"),
        conversation: Id,
        initial_origin: ?Owner = null,
        owner: ?Owner = null,
        initial_text: ?[]const u8 = null,
        recoverable: bool = true,
        history_pinned: ?bool = null,
        turn: u64 = 0,
        draft: ?[]const u8 = null,
        workspace: ?struct {} = null,
        initial_input: ?input.Receipt = null,
        child_info: ?struct { owning_parent_conversation: Id } = null,
        parent_binding: ?input.Fence = null,
        children: ?[]const Id = null,
    } = null,
    receipt: ?input.Receipt = null,
    order: ?struct { fence: input.Fence } = null,
    consumed_batch: ?[]const struct { receipt: input.Receipt } = null,
    transcript: []const struct {} = &.{},
    messages: []const struct { role: @import("provider.zig").Role, content: []const u8, origin: @FieldType(@import("provider.zig").Message, "origin") = .user_or_tool } = &.{},
};

pub const Entry = struct {
    conversation: Id,
    related: ?Id = null,
    origin: ?Owner = null,
    title: Title = .{},
    child: bool = false,
    removed: bool = false,
    rows: std.ArrayList(Span) = .empty,
    snapshot: ?Span = null,
    transcript: ?Span = null,
    draft: ?Span = null,
    workspace: ?Span = null,
    pending: std.ArrayList(PendingSpan) = .empty,
    can_restore: bool = false,
    can_copy: bool = false,
    first_use: bool = false,
    recoverable: bool = true,
    history_pinned: bool = false,
};

pub const Catalog = struct {
    allocator: A,
    entries: std.ArrayList(Entry) = .empty,
    positions: std.AutoHashMapUnmanaged(Id, usize) = .empty,
    bounds: Bounds = Bounds.initFill(null),
    source_bytes: u64 = 0,
    resumed_bytes: u64 = 0,

    pub fn init(a: A) Catalog {
        return .{ .allocator = a };
    }
    pub fn deinit(self: *Catalog) void {
        for (self.entries.items) |*entry| {
            entry.rows.deinit(self.allocator);
            entry.pending.deinit(self.allocator);
        }
        self.entries.deinit(self.allocator);
        self.positions.deinit(self.allocator);
    }
    pub fn find(self: *const Catalog, id: Id) ?*const Entry {
        return if (self.positions.get(id)) |index| &self.entries.items[index] else null;
    }

    fn apply(self: *Catalog, source: Source, span: Indexed) !void {
        for (span.items) |item| {
            const lookup = try self.positions.getOrPut(self.allocator, item.conversation);
            if (!lookup.found_existing) {
                lookup.value_ptr.* = self.entries.items.len;
                try self.entries.append(self.allocator, .{ .conversation = item.conversation });
            }
            const entry = &self.entries.items[lookup.value_ptr.*];
            if (item.related) |related| if (!related.eql(item.conversation)) {
                entry.related = related;
            };
            if (item.origin) |origin| entry.origin = origin;
            entry.child = entry.child or item.child;
            entry.removed = entry.removed or item.removed;
            if (item.status) |status| {
                entry.can_restore = status.can_restore;
                entry.can_copy = entry.can_copy or status.can_copy;
                entry.first_use = status.first_use;
            }
            if (item.recoverable) |recoverable| entry.recoverable = recoverable;
            if (item.history_pinned) |pinned| entry.history_pinned = pinned;
            if (entry.title.len == 0) if (item.title) |title| {
                _ = entry.title.set(title);
            };
            const location: Span = .{ .source = source, .start = span.start, .end = span.end };
            try entry.rows.append(self.allocator, location);
            if (item.projection.snapshot) {
                entry.snapshot = location;
                entry.transcript = null;
            }
            if (item.projection.transcript) entry.transcript = location;
            if (item.projection.draft) entry.draft = location;
            if (item.projection.workspace) entry.workspace = location;
            for (item.receipts) |receipt| {
                const existing = for (entry.pending.items, 0..) |candidate, i| {
                    if (candidate.receipt.id.eql(receipt.id)) break @as(?usize, i);
                } else null;
                if (existing) |i| {
                    if (input.terminal(receipt.delivery)) {
                        _ = entry.pending.orderedRemove(i);
                    } else {
                        entry.pending.items[i].receipt = receipt;
                        if (receipt.has_body) entry.pending.items[i].span = location;
                    }
                } else if (!input.terminal(receipt.delivery)) {
                    try entry.pending.append(self.allocator, .{ .receipt = receipt, .span = if (receipt.has_body) location else null });
                }
            }
        }
    }

    /// Runtime mutations of a parent can touch its retained children. A
    /// plain history preview uses only the selected Entry.rows.
    pub fn family(self: *const Catalog, id: Id, allocator: A) ![]Span {
        var root = self.find(id) orelse return error.ConversationNotFound;
        var traversed: usize = 0;
        while (root.related) |parent| {
            traversed += 1;
            if (traversed > self.entries.items.len) return error.InvalidAiHistoryIndex;
            root = self.find(parent) orelse return error.InvalidAiHistoryIndex;
        }
        var result: std.ArrayList(Span) = .empty;
        errdefer result.deinit(allocator);
        for (self.entries.items) |*entry| {
            if (entry.conversation.eql(root.conversation) or (entry.related != null and entry.related.?.eql(root.conversation))) {
                try result.appendSlice(allocator, entry.rows.items);
            }
        }
        result.shrinkRetainingCapacity(orderDistinct(result.items));
        return result.toOwnedSlice(allocator);
    }

    pub fn scan(self: *Catalog, io: std.Io, directory: std.Io.Dir, bounds: Bounds, cancel: *const std.atomic.Value(bool)) !void {
        self.bounds = bounds;
        for ([_]Source{ .legacy, .active }) |source| if (bounds.get(source)) |limit| {
            try self.scanSource(io, directory, source, limit, cancel);
        };
    }

    fn scanSource(self: *Catalog, io: std.Io, directory: std.Io.Dir, source: Source, limit: Limit, cancel: *const std.atomic.Value(bool)) !void {
        const a = self.allocator;
        const input_file = try openSource(io, directory, source, limit);
        defer input_file.close(io);
        const checkpoint = directory.openFile(io, source.indexPath(), .{ .mode = .read_write, .allow_directory = false, .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => try directory.createFile(io, source.indexPath(), .{ .exclusive = true, .read = true, .permissions = @fromBackingInt(0o600) }),
            else => return err,
        };
        defer checkpoint.close(io);
        const info = try checkpoint.stat(io);
        if (info.kind != .file or info.nlink != 1) return error.InvalidAiHistoryIndex;
        var offset: u64 = 0;
        var persisted: u64 = 0;
        var existing = Lines.init(checkpoint, info.size, 0, a);
        defer existing.deinit();
        while (try existing.next(io)) |line| {
            if (cancel.load(.acquire)) return error.Cancelled;
            const parsed = try std.json.parseFromSlice(Commit, a, line, .{});
            defer parsed.deinit();
            const commit = parsed.value;
            if (commit.inode != limit.inode or commit.from != offset or commit.end <= offset or commit.end > limit.end) return error.AiHistoryIndexSourceChanged;
            for (commit.rows) |row| {
                if (row.start < offset or row.end > commit.end or row.end <= row.start) return error.InvalidAiHistoryIndex;
                try self.apply(source, row);
            }
            offset = commit.end;
            persisted = existing.position();
        }
        self.resumed_bytes += offset;
        if (persisted != info.size) try checkpoint.setLength(io, persisted);
        var content = Lines.init(input_file, limit.end, offset, a);
        defer content.deinit();
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var pending: std.ArrayList(Indexed) = .empty;
        var start = offset;
        var batch_from = offset;
        while (try content.next(io)) |line| {
            if (cancel.load(.acquire)) return error.Cancelled;
            const end = content.position();
            const scratch = arena.allocator();
            if (line.len != 0) try pending.append(scratch, .{ .start = start, .end = end, .items = try summarize(scratch, a, line) });
            if (pending.items.len >= 32 or end - batch_from >= 4 * 1024 * 1024) {
                try self.writeBatch(io, checkpoint, source, limit.inode, &persisted, batch_from, end, pending.items);
                pending = .empty;
                _ = arena.reset(.free_all);
                batch_from = end;
            }
            start = end;
        }
        if (start > batch_from) try self.writeBatch(io, checkpoint, source, limit.inode, &persisted, batch_from, start, pending.items);
        self.source_bytes += content.read_size;
    }

    fn writeBatch(self: *Catalog, io: std.Io, file: std.Io.File, source: Source, inode: u64, position: *u64, from: u64, end: u64, rows: []const Indexed) !void {
        const bytes = try std.json.Stringify.valueAlloc(self.allocator, Commit{ .inode = inode, .from = from, .end = end, .rows = rows }, .{});
        defer self.allocator.free(bytes);
        try file.writePositionalAll(io, bytes, position.*);
        try file.writePositionalAll(io, "\n", position.* + bytes.len);
        try file.sync(io);
        position.* += bytes.len + 1;
        for (rows) |row| try self.apply(source, row);
    }
};

fn orderDistinct(rows: []Span) usize {
    std.mem.sort(Span, rows, {}, struct {
        fn less(_: void, left: Span, right: Span) bool {
            return if (left.source != right.source) @backingInt(left.source) < @backingInt(right.source) else left.start < right.start;
        }
    }.less);
    var n: usize = 0;
    for (rows) |span| {
        if (n > 0 and std.meta.eql(rows[n - 1], span)) continue;
        rows[n] = span;
        n += 1;
    }
    return n;
}

fn summarize(scratch: A, allocator: A, line: []const u8) ![]const Row {
    const parsed = try std.json.parseFromSlice(Header, allocator, line, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const value = parsed.value;
    var rows: std.ArrayList(Row) = .empty;
    var row: Row = undefined;
    if (value.event) |event| {
        row = .{
            .conversation = event.conversation,
            .related = if (event.child_info) |info| info.owning_parent_conversation else if (event.parent_binding) |parent| parent.conversation else null,
            .origin = event.initial_origin orelse if (event.kind == .create) event.owner else null,
            .child = event.child_info != null or event.parent_binding != null,
            .removed = event.kind == .remove or event.kind == .remove_family,
            .recoverable = if (event.kind == .checkpoint) event.recoverable else null,
            .history_pinned = if (event.kind == .history_pin) event.history_pinned else null,
            .projection = .{
                .snapshot = switch (event.kind) {
                    .checkpoint, .fork, .fork_bound, .migrate_bound, .migrate_closed, .child_create => true,
                    .child_launch => event.child_info != null,
                    else => false,
                },
                .draft = event.kind == .draft or event.draft != null,
                .workspace = event.workspace != null,
            },
            .status = switch (event.kind) {
                .create, .migrate_bound, .migrate_closed, .checkpoint, .bind, .unbind, .fork, .fork_bound => .{
                    .can_restore = true,
                    .can_copy = event.turn != 0,
                    .first_use = event.kind == .fork,
                },
                else => null,
            },
        };
        if (event.children) |children| for (children) |id| {
            try rows.append(scratch, .{ .conversation = id, .related = row.conversation, .removed = true, .child = true });
        };
        if (event.initial_text) |text| row.title = try shortTitle(scratch, text);
    } else {
        const id = if (value.receipt) |receipt| receipt.fence.conversation else if (value.order) |order| order.fence.conversation else if (value.consumed_batch) |batch| if (batch.len > 0) batch[0].receipt.fence.conversation else return error.InvalidSessionJournal else return error.InvalidSessionJournal;
        row = .{ .conversation = id };
    }
    if (!row.conversation.valid()) return error.InvalidSessionJournal;
    row.projection.transcript = value.transcript.len != 0;
    const primary = if (value.event) |event| event.initial_input else value.receipt;
    if (primary) |receipt| {
        const status = try scratch.alloc(ReceiptIndex, 1);
        status[0] = .{ .id = receipt.id, .delivery = receipt.delivery, .has_body = value.messages.len > 0 or (value.event != null and value.event.?.initial_text != null) };
        row.receipts = status;
    }
    if (value.consumed_batch) |batch| {
        const status = try scratch.alloc(ReceiptIndex, batch.len);
        for (batch, status) |consumed, *receipt| receipt.* = .{ .id = consumed.receipt.id, .delivery = consumed.receipt.delivery, .has_body = false };
        row.receipts = status;
    }
    if (row.title == null) for (value.messages) |message| {
        if (message.role != .user or message.origin != .user_or_tool) continue;
        row.title = try shortTitle(scratch, message.content);
        if (row.title != null) break;
    };
    try rows.append(scratch, row);
    return rows.items;
}

fn shortTitle(a: A, raw: []const u8) !?[]const u8 {
    var title: Title = .{};
    if (!title.set(raw)) return null;
    return try a.dupe(u8, title.text().?);
}

pub fn sourceBounds(io: std.Io, dir: std.Io.Dir) !Bounds {
    var bounds = Bounds.initFill(null);
    for ([_]Source{ .legacy, .active }) |source| {
        const info = dir.statFile(io, source.path(), .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        if (info.kind != .file or info.nlink != 1) return error.InvalidSessionJournal;
        bounds.set(source, .{ .inode = info.inode, .end = info.size });
    }
    return bounds;
}

pub fn openSource(io: std.Io, directory: std.Io.Dir, source: Source, limit: Limit) !std.Io.File {
    const file = try directory.openFile(io, source.path(), .{ .allow_directory = false, .follow_symlinks = false });
    errdefer file.close(io);
    const info = try file.stat(io);
    if (info.kind != .file or info.nlink != 1 or info.inode != limit.inode or info.size < limit.end) return error.AiHistoryIndexSourceChanged;
    return file;
}

pub fn readSpans(io: std.Io, dir: std.Io.Dir, a: A, bounds: Bounds, spans: []const Span, cancel: *const std.atomic.Value(bool), target: anytype, comptime consume: fn (@TypeOf(target), []const u8) anyerror!void) !u64 {
    var bytes: u64 = 0;
    for ([_]Source{ .legacy, .active }) |source| {
        if (cancel.load(.acquire)) return error.Cancelled;
        const limit = bounds.get(source) orelse continue;
        for (spans) |span| {
            if (span.source == source) break;
        } else continue;
        const file = try openSource(io, dir, source, limit);
        defer file.close(io);
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(a);
        for (spans) |span| {
            if (span.source != source) continue;
            if (cancel.load(.acquire)) return error.Cancelled;
            if (span.start >= span.end or span.end > limit.end) return error.InvalidAiHistoryIndex;
            try buffer.resize(a, @intCast(span.end - span.start));
            if (try file.readPositionalAll(io, buffer.items, span.start) != buffer.items.len or buffer.items[buffer.items.len - 1] != '\n') return error.AiHistoryIndexSourceChanged;
            bytes += buffer.items.len;
            try consume(target, buffer.items[0 .. buffer.items.len - 1]);
        }
    }
    return bytes;
}

/// A fixed read limit keeps concurrently appended records out of an older
/// snapshot. The buffer retains at most the largest complete input row.
const Lines = struct {
    file: std.Io.File,
    limit: u64,
    base: u64,
    read_size: u64 = 0,
    seek: usize = 0,
    end: usize = 0,
    buffer: [64 * 1024]u8 = undefined,
    line: std.ArrayList(u8) = .empty,
    allocator: A,

    fn init(file: std.Io.File, limit: u64, start: u64, allocator: A) Lines {
        return .{ .file = file, .limit = limit, .base = start, .allocator = allocator };
    }
    fn deinit(self: *Lines) void {
        self.line.deinit(self.allocator);
    }
    fn position(self: *const Lines) u64 {
        return self.base + self.seek;
    }
    fn next(self: *Lines, io: std.Io) !?[]const u8 {
        self.line.clearRetainingCapacity();
        while (true) {
            if (self.seek == self.end) {
                self.base += self.end;
                self.seek = 0;
                self.end = 0;
                if (self.base == self.limit) return null;
                const buf = self.buffer[0..@intCast(@min(self.buffer.len, self.limit - self.base))];
                self.end = try self.file.readPositionalAll(io, buf, self.base);
                if (self.end != buf.len) return error.AiHistoryIndexSourceChanged;
                self.read_size += self.end;
            }
            const bytes = self.buffer[self.seek..self.end];
            if (std.mem.indexOfScalar(u8, bytes, '\n')) |index| {
                try self.line.appendSlice(self.allocator, bytes[0..index]);
                self.seek += index + 1;
                return self.line.items;
            }
            try self.line.appendSlice(self.allocator, bytes);
            self.seek = self.end;
        }
    }
};

pub const Preview = struct {
    const Message = @FieldType(Header, "messages");
    const Event = struct {
        kind: @FieldType(lifecycle.Event, "kind"),
        conversation: Id,
        draft: ?[]const u8 = null,
        recoverable: bool = true,
        initial_input: ?input.Receipt = null,
        initial_text: ?[]const u8 = null,
        workspace: ?struct { directory: ?[]const u8 = null } = null,
    };
    const Data = struct {
        schema: u8 = 1,
        event: ?Event = null,
        receipt: ?input.Receipt = null,
        messages: Message = &.{},
        transcript: Message = &.{},
        consumed_batch: ?[]const struct { receipt: input.Receipt } = null,
    };
    const Pending = struct { receipt: input.Receipt, body: []const u8 };
    allocator: A,
    id: Id,
    snapshot: std.Io.Writer.Allocating,
    recovery: std.Io.Writer.Allocating,
    draft: ?[]u8 = null,
    directory: ?[]u8 = null,
    pending: std.ArrayList(Pending) = .empty,
    input_index: []const PendingSpan,
    rows_read: usize = 0,
    can_restore: bool = false,
    can_copy: bool = false,
    first_use: bool = false,
    bytes_read: u64 = 0,

    pub fn load(a: A, io: std.Io, dir: std.Io.Dir, bounds: Bounds, entry: *const Entry, cancel: *const std.atomic.Value(bool)) !Preview {
        var self: Preview = .{
            .allocator = a,
            .id = entry.conversation,
            .snapshot = .init(a),
            .recovery = .init(a),
            .can_restore = entry.can_restore and entry.recoverable,
            .can_copy = entry.can_copy and entry.recoverable,
            .first_use = entry.first_use,
            .input_index = entry.pending.items,
        };
        errdefer self.deinit();
        var spans: std.ArrayList(Span) = .empty;
        defer spans.deinit(a);
        for ([_]?Span{ entry.snapshot, entry.transcript, entry.draft, entry.workspace }) |span| {
            if (span) |location| try spans.append(a, location);
        }
        for (entry.pending.items) |item| {
            if (item.span) |location| try spans.append(a, location);
        }
        self.rows_read = orderDistinct(spans.items);
        self.bytes_read = try readSpans(io, dir, a, bounds, spans.items[0..self.rows_read], cancel, &self, row);
        return self;
    }

    pub fn deinit(self: *Preview) void {
        self.snapshot.deinit();
        self.recovery.deinit();
        if (self.draft) |draft| self.allocator.free(draft);
        if (self.directory) |directory| self.allocator.free(directory);
        for (self.pending.items) |item| self.allocator.free(item.body);
        self.pending.deinit(self.allocator);
    }

    pub fn render(self: *Preview, out: *std.Io.Writer) !void {
        if (self.directory) |directory| try out.print("本地工作区：{s}\n\n", .{directory});
        try out.writeAll(if (self.recovery.written().len != 0) self.recovery.written() else self.snapshot.written());
        if (self.draft) |draft| if (draft.len != 0) try out.print("未发送草稿\n{s}\n\n", .{draft});
        for (self.pending.items) |item| {
            try out.print("{s}\n{s}\n\n", .{ if (item.receipt.delivery == .outcome_unknown) "待核对：尚不能确认是否消费，不自动重发" else if (item.receipt.delivery == .accepted) "任务已接收，尚未消费；保留原消息，不自动重发" else "待处理输入（不自动执行）", item.body });
        }
    }

    fn row(self: *Preview, line: []const u8) anyerror!void {
        const parsed = try std.json.parseFromSlice(Data, self.allocator, line, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const item = parsed.value;
        if (item.schema < 1 or item.schema > 5) return error.InvalidSessionJournal;
        if (item.event) |event| {
            if (!event.conversation.eql(self.id)) return error.InvalidAiHistoryIndex;
            switch (event.kind) {
                .checkpoint => {
                    try writeMessages(&self.snapshot, item.messages);
                    self.recovery.clearRetainingCapacity();
                },
                .fork, .fork_bound, .migrate_closed, .migrate_bound, .child_create => try writeMessages(&self.snapshot, item.messages),
                .child_launch => if (event.initial_input != null and item.messages.len != 0) try writeMessages(&self.snapshot, item.messages),
                else => {},
            }
            if (event.kind == .draft or event.draft != null) try self.setText(&self.draft, event.draft);
            if (event.workspace) |workspace| try self.setText(&self.directory, workspace.directory);
            if (event.initial_input) |receipt| try self.applyReceipt(receipt, event.initial_text orelse if (item.messages.len != 0) item.messages[0].content else null);
        }
        if (item.receipt) |receipt| try self.applyReceipt(receipt, if (item.messages.len != 0) item.messages[0].content else null);
        if (item.consumed_batch) |batch| for (batch) |entry| try self.applyReceipt(entry.receipt, null);
        if (item.transcript.len != 0) try writeMessages(&self.recovery, item.transcript);
    }

    fn setText(self: *Preview, target: *?[]u8, value: ?[]const u8) !void {
        const next = if (value) |text| try self.allocator.dupe(u8, text) else null;
        if (target.*) |old| self.allocator.free(old);
        target.* = next;
    }

    fn applyReceipt(self: *Preview, receipt: input.Receipt, body: ?[]const u8) !void {
        if (!receipt.fence.conversation.eql(self.id)) return error.InvalidAiHistoryIndex;
        const final = for (self.input_index) |entry| {
            if (entry.receipt.id.eql(receipt.id)) break entry.receipt;
        } else return;
        var latest = receipt;
        latest.delivery = final.delivery;
        for (self.pending.items) |*old| {
            if (!old.receipt.id.eql(receipt.id)) continue;
            if (body) |value| {
                const copy = try self.allocator.dupe(u8, value);
                self.allocator.free(old.body);
                old.body = copy;
            }
            old.receipt = latest;
            return;
        }
        const copy = try self.allocator.dupe(u8, body orelse "");
        errdefer self.allocator.free(copy);
        try self.pending.append(self.allocator, .{ .receipt = latest, .body = copy });
    }

    fn writeMessages(out: *std.Io.Writer.Allocating, messages: Message) !void {
        out.clearRetainingCapacity();
        for (messages) |message| {
            if (message.origin == .host_context_notice) continue;
            const body = if (message.role == .assistant) @import("history_environment.zig").assistantText(message.content) else message.content;
            try out.writer.print("{s}\n{s}\n\n", .{ switch (message.role) {
                .user => "你",
                .assistant => "AI 助手",
                .tool => "历史工具结果",
            }, body });
        }
    }
};
