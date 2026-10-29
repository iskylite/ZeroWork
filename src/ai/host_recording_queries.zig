//! Closed-recording content authority and bounded, resumable offline VT reads.
//! Only trusted controllers install grants; a model-supplied ID never searches
//! the archive catalog. Readers pin one committed manifest and all dependencies.
const std = @import("std");
const host = @import("host_tools.zig");
const queries = @import("host_terminal_queries.zig");
const identity = @import("../host/identity.zig");
const archive_mod = @import("../vt/session_archive.zig");
const terminal = @import("../host/terminal_service.zig");
const Adapter = @import("../vt/ghostty_adapter.zig").Adapter;
const c = @import("generated_ghostty_vt");
const max_readers = 2;
const scan_bytes = 256 * 1024;
const event_bytes = 256 * 1024;
const event_limit = 128;
const idle_ms = 60_000;

pub const Grant = struct {
    context: host.Context,
    owner: identity.SessionHandle,
    recording_id: [32]u8,
    recording_generation: u64,
    manifest_path: []const u8,
    /// Zero is allowed only for a captured still-active source whose eventual
    /// closed commit did not exist when the content permission was captured.
    manifest_revision: u64 = 0,
    origin: enum { captured_source, task_owned_closed, explicit_history_selection },
};
const KnownCommand = struct {
    id: u64,
    record: queries.Command,
    output: []const u8,
    first_ms: i64,
    last_ms: i64,
};
threadlocal var receive_ms: i64 = 0;
fn replayClock() i64 {
    return receive_ms;
}
const Reader = struct {
    arena: std.heap.ArenaAllocator,
    record: archive_mod.QueryRecord,
    grant: Grant,
    request: queries.Request,
    tool: []const u8,
    token: [32]u8,
    last_used: i64,
    verify_file: usize = 0,
    verify_offset: u64 = 0,
    hash: std.crypto.hash.sha2.Sha256 = .init(.{}),
    verified: bool = false,
    offset: u64 = 0,
    pending: std.ArrayList(u8) = .empty,
    adapter: ?Adapter = null,
    decoded: bool = false,
    event_sequence: u64 = 0,
    previous_ms: i64 = 0,
    observed_event_ms: ?i64 = null,
    commands: std.ArrayList(KnownCommand) = .empty,
    command_bytes: usize = 0,
    execution_range: ?archive_mod.manifest.ExecutionRange = null,
    interval_output: std.ArrayList(u8) = .empty,
    interval_byte: usize = 0,
    commands_partial: bool = false,
    after_line: ?u64 = null,
    command_page: usize = 0,
    search_byte: usize = 0,
    fn deinit(self: *Reader) void {
        if (self.adapter) |*adapter| adapter.destroy();
        self.record.deinit();
        self.arena.deinit();
    }
};

pub const Backend = struct {
    archive: archive_mod.Archive,
    grants: []const Grant = &.{},
    readers: [max_readers]?*Reader = @splat(null),
    mutex: std.atomic.Mutex = .unlocked,
    /// Tests may provide an advancing clock. Production uses the archive IO's
    /// monotonic clock for idle expiration, independent of cast receive time.
    now_override: ?i64 = null,
    fn now(self: *const Backend) i64 {
        return self.now_override orelse @intCast(std.Io.Clock.awake.now(self.archive.io).toMilliseconds());
    }
    pub fn deinit(self: *Backend) void {
        for (&self.readers) |*slot| if (slot.*) |reader| {
            reader.deinit();
            std.heap.c_allocator.destroy(reader);
            slot.* = null;
        };
    }
    pub fn cancel(self: *Backend, context: host.Context) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        for (&self.readers) |*slot| if (slot.*) |reader| if (reader.grant.context.eql(context)) {
            reader.deinit();
            std.heap.c_allocator.destroy(reader);
            slot.* = null;
        };
    }
    /// Call from the existing host/controller poll so abandoned cursors stop
    /// pinning files even when the model never requests another page.
    pub fn expireIdle(self: *Backend) void {
        if (!self.mutex.tryLock()) return;
        defer self.mutex.unlock();
        const now_ms = self.now();
        for (self.readers, 0..) |slot, index| if (slot) |reader| if (now_ms -| reader.last_used >= idle_ms) self.release(index);
    }
    fn release(self: *Backend, index: usize) void {
        if (self.readers[index]) |reader| {
            reader.deinit();
            std.heap.c_allocator.destroy(reader);
            self.readers[index] = null;
        }
    }
    pub fn execute(self: *Backend, invocation: host.Invocation, allocator: std.mem.Allocator) !host.Result {
        const request = try queries.parse(invocation.tool_id, invocation.arguments);
        try invocation.context.validate();
        if (invocation.authority != .conversation_context or request.source != .recording) return error.PermissionDenied;
        const reference = try queries.resolveRecording(invocation.context, request.source.recording);
        const grant = for (self.grants) |candidate| {
            if (candidate.context.eql(invocation.context) and candidate.recording_generation == reference.generation and std.mem.eql(u8, &candidate.recording_id, &reference.id)) break candidate;
        } else return error.PermissionDenied;
        if (!self.mutex.tryLock()) return error.RecordingQueryBusy;
        defer self.mutex.unlock();
        const now_ms = self.now();
        for (self.readers, 0..) |slot, index| if (slot) |reader| if (now_ms -| reader.last_used >= idle_ms) self.release(index);
        const index = if (request.cursor) |cursor| blk: {
            if (cursor.len != 64) return error.CursorExpired;
            const candidate_index = for (self.readers, 0..) |slot, i| if (slot) |reader| {
                if (std.mem.eql(u8, &std.fmt.bytesToHex(reader.token, .lower), cursor)) break i;
            } else continue else return error.CursorExpired;
            const reader = self.readers[candidate_index].?;
            if (!reader.grant.context.eql(invocation.context) or !std.mem.eql(u8, reader.tool, invocation.tool_id) or !std.mem.eql(u8, reader.request.source.recording, request.source.recording) or reader.request.time_basis != request.time_basis or reader.request.max_bytes != request.max_bytes or reader.request.max_lines != request.max_lines or reader.request.limit != request.limit or reader.request.case_sensitive != request.case_sensitive or !optionalEqual(reader.request.query, request.query)) return error.CursorExpired;
            if (request.range_kind != .cursor and (reader.request.range_kind != request.range_kind or reader.request.start_line != request.start_line or reader.request.end_line != request.end_line or reader.request.start_ms != request.start_ms or reader.request.end_ms != request.end_ms or !optionalEqual(reader.request.command_ref, request.command_ref))) return error.CursorExpired;
            break :blk candidate_index;
        } else blk: {
            const free = for (self.readers, 0..) |slot, i| {
                if (slot == null) break i;
            } else return error.RecordingQueryBusy;
            self.readers[free] = try self.open(grant, request, invocation.tool_id, now_ms);
            break :blk free;
        };
        errdefer self.release(index);
        const reader = self.readers[index].?;
        reader.last_used = now_ms;
        // A permission revision/path change invalidates even a matching token.
        if (!std.mem.eql(u8, reader.grant.manifest_path, grant.manifest_path) or reader.grant.manifest_revision != grant.manifest_revision or !reader.grant.owner.eql(grant.owner)) return error.CursorExpired;
        for (reader.record.lease.leases.items) |*lease| try lease.validateFrozen();
        try verify(reader);
        if (reader.verified and !reader.decoded) try decode(reader);
        std.c.arc4random_buf(&reader.token, reader.token.len);
        const result = try render(reader, invocation, allocator);
        if (reader.decoded and !result.more) self.release(index);
        return result.value;
    }
    fn open(self: *Backend, grant: Grant, request: queries.Request, tool: []const u8, now_ms: i64) !*Reader {
        if (grant.recording_generation == 0 or (grant.manifest_revision == 0 and grant.origin != .captured_source)) return error.InvalidRecordingGrant;
        const reader = try std.heap.c_allocator.create(Reader);
        errdefer std.heap.c_allocator.destroy(reader);
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var record = try archive_mod.acquireQueryRecord(self.archive, std.heap.c_allocator, grant.manifest_path);
        errdefer record.deinit();
        const doc = record.document.value;
        if (!std.mem.eql(u8, doc.recording_id, &grant.recording_id) or (grant.manifest_revision != 0 and grant.manifest_revision != doc.manifest_revision)) return error.StaleRecordingRevision;
        const generation = for (doc.recording.generations) |item| {
            if (item.recording_generation == grant.recording_generation) break item;
        } else return error.StaleGeneration;
        if (generation.session_id != @backingInt(grant.owner.session_id) or generation.session_generation != grant.owner.generation) return error.StaleGeneration;
        // Multiple generations require a seekable baseline for that generation;
        // never replay another generation from an empty decoder.
        if (doc.recording.generations.len != 1 or generation.raw_offset_start != 0 or generation.event_sequence_start > 1) return error.RecordingBaselineUnavailable;
        const has_empty = for (generation.baselines) |baseline| {
            if (baseline.kind == .initial_empty and baseline.raw_offset == 0 and baseline.event_sequence == 0) break true;
        } else false;
        if (!has_empty) return error.RecordingBaselineUnavailable;
        var copy = request;
        copy.source = .{ .recording = try a.dupe(u8, request.source.recording) };
        if (copy.query) |value| copy.query = try a.dupe(u8, value);
        if (copy.command_ref) |value| copy.command_ref = try a.dupe(u8, value);
        copy.cursor = null;
        var owned_grant = grant;
        owned_grant.manifest_path = try a.dupe(u8, grant.manifest_path);
        reader.* = .{ .arena = arena, .record = record, .grant = owned_grant, .request = copy, .tool = try a.dupe(u8, tool), .last_used = now_ms, .token = undefined };
        if (request.command_ref) |reference| if (std.mem.startsWith(u8, reference, "c1:")) {
            const execution_id = try commandExecution(grant, reference);
            reader.execution_range = for (doc.execution_ranges) |range| {
                if (range.recording_generation == grant.recording_generation and std.mem.eql(u8, range.execution_id, execution_id)) break range;
            } else return error.CommandIndexUnavailable;
            if (reader.execution_range.?.end == null or doc.events.len == 0) return error.RangeUnavailable;
        };
        std.c.arc4random_buf(&reader.token, reader.token.len);
        return reader;
    }
};
fn optionalEqual(a: ?[]const u8, b: ?[]const u8) bool {
    return if (a) |value| if (b) |other| std.mem.eql(u8, value, other) else false else b == null;
}
fn verify(reader: *Reader) !void {
    if (reader.verified) return;
    var budget: usize = scan_bytes;
    var buffer: [32768]u8 = undefined;
    const files = reader.record.document.value.files;
    while (reader.verify_file < files.len and budget > 0) {
        const file = files[reader.verify_file];
        const lease = &reader.record.lease.leases.items[reader.verify_file + 1];
        const count = try lease.readRange(reader.verify_offset, buffer[0..@min(buffer.len, budget)]);
        reader.hash.update(buffer[0..count]);
        reader.verify_offset += count;
        budget -= count;
        if (reader.verify_offset == file.committed_length) {
            var digest: [32]u8 = undefined;
            reader.hash.final(&digest);
            if (!std.ascii.eqlIgnoreCase(&std.fmt.bytesToHex(digest, .lower), file.checksum)) return error.RecordingChecksumMismatch;
            reader.hash = .init(.{});
            reader.verify_file += 1;
            reader.verify_offset = 0;
        }
    }
    reader.verified = reader.verify_file == files.len;
}
fn decode(reader: *Reader) !void {
    const a = reader.arena.allocator();
    const lease = reader.record.lease.cast();
    var budget: usize = scan_bytes;
    var events: usize = 0;
    var buffer: [8192]u8 = undefined;
    while (events < event_limit) {
        if (std.mem.indexOfScalar(u8, reader.pending.items, '\n')) |newline| {
            const line = reader.pending.items[0..newline];
            try decodeLine(reader, line);
            const remaining = reader.pending.items.len - newline - 1;
            std.mem.copyForwards(u8, reader.pending.items[0..remaining], reader.pending.items[newline + 1 ..]);
            reader.pending.shrinkRetainingCapacity(remaining);
            events += 1;
            if (reader.decoded) return;
            continue;
        }
        if (reader.offset == lease.stat.size) {
            if (reader.pending.items.len > 0) {
                try decodeLine(reader, reader.pending.items);
                reader.pending.clearRetainingCapacity();
            }
            if (reader.adapter == null) return error.EmptyRecording;
            reader.decoded = true;
            return;
        }
        if (budget == 0) return;
        const count = try lease.readRange(reader.offset, buffer[0..@min(buffer.len, budget)]);
        if (reader.pending.items.len + count > event_bytes) return error.RecordingEventBudgetExceeded;
        try reader.pending.appendSlice(a, buffer[0..count]);
        reader.offset += count;
        budget -= count;
    }
}
fn decodeLine(reader: *Reader, line: []const u8) !void {
    if (std.mem.trim(u8, line, " \r\t").len == 0) return;
    const a = reader.arena.allocator();
    const event = try std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, line, .{});
    defer event.deinit();
    if (reader.adapter == null) {
        if (event.value != .object) return error.InvalidCast;
        const v = event.value.object.get("version") orelse return error.InvalidCast;
        const cols = event.value.object.get("width") orelse return error.InvalidCast;
        const rows = event.value.object.get("height") orelse return error.InvalidCast;
        if (v != .integer or v.integer != 2 or cols != .integer or rows != .integer or cols.integer < 1 or cols.integer > 500 or rows.integer < 1 or rows.integer > 200) return error.InvalidCast;
        const generation = reader.record.document.value.recording.generations[0];
        if (cols.integer != generation.initial_cols or rows.integer != generation.initial_rows) return error.InvalidRecordingBaseline;
        if (event.value.object.get("zerowork")) |metadata| {
            if (metadata != .object) return error.InvalidCast;
            if (metadata.object.get("replay_baseline") != null) return error.RecordingBaselineUnavailable;
        }
        reader.adapter = try Adapter.init(std.heap.c_allocator, @intCast(rows.integer), @intCast(cols.integer));
        const continuation_limit: usize = 65536;
        if (c.ghostty_terminal_set(reader.adapter.?.terminal, c.GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &continuation_limit) != c.GHOSTTY_SUCCESS) return error.RecordingDecoderBudgetExceeded;
        reader.adapter.?.wall_clock_ms = replayClock;
        try reader.adapter.?.setScrollbackLimit(4096);
        return;
    }
    if (event.value != .array or event.value.array.items.len != 3) return error.InvalidCast;
    const items = event.value.array.items;
    const seconds: f64 = switch (items[0]) {
        .integer => |n| @floatFromInt(n),
        .float => |n| n,
        else => return error.InvalidCast,
    };
    if (!std.math.isFinite(seconds) or seconds < 0 or seconds > 1e12 or items[1] != .string or items[2] != .string) return error.InvalidCast;
    const relative_ms: i64 = @intFromFloat(seconds * 1000);
    if (relative_ms < reader.previous_ms) return error.InvalidCast;
    reader.previous_ms = relative_ms;
    const ms = relative_ms;
    // Time queries expose the real terminal state at the last recorded event
    // at/before the end bound. No synthetic per-line timestamps are assigned.
    if (reader.request.range_kind == .time and ms > reader.request.end_ms.?) {
        reader.decoded = true;
        return;
    }
    // Native row metadata reserves zero for unknown. Offset internally and
    // undo it at the capture boundary, preserving a real elapsed time of zero.
    receive_ms = ms + 1;
    if (std.mem.eql(u8, items[1].string, "o")) {
        if (reader.execution_range) |range| {
            const mapping = for (reader.record.document.value.events) |mapped| {
                if (mapped.cast_line == reader.event_sequence + 1) break mapped;
            } else return error.RecordingGap;
            if (mapping.kind == .output and mapping.sequence > range.start.event_sequence and mapping.sequence < range.end.?.event_sequence) {
                if (mapping.raw_offset < range.start.raw_offset or mapping.raw_offset +| mapping.raw_length > range.end.?.raw_offset) return error.RangeUnavailable;
                if (items[2].string.len > 65536 -| reader.interval_output.items.len) return error.RecordingCommandBudgetExceeded;
                try reader.interval_output.appendSlice(a, items[2].string);
            }
        }
        _ = try reader.adapter.?.feed(items[2].string);
    } else if (std.mem.eql(u8, items[1].string, "r")) {
        const x = std.mem.indexOfScalar(u8, items[2].string, 'x') orelse return error.InvalidCast;
        const cols = std.fmt.parseInt(u16, items[2].string[0..x], 10) catch return error.InvalidCast;
        const rows = std.fmt.parseInt(u16, items[2].string[x + 1 ..], 10) catch return error.InvalidCast;
        if (cols == 0 or rows == 0 or cols > 500 or rows > 200) return error.InvalidCast;
        try reader.adapter.?.resize(cols, rows);
    } else if (std.mem.eql(u8, items[1].string, "a")) {
        const typed = try std.json.parseFromSlice(terminal.ApplicationRecord, std.heap.c_allocator, items[2].string, .{});
        defer typed.deinit();
        const record = typed.value;
        if (record.owner.eql(reader.grant.owner)) {
            if (record.command.len + record.output.len > 65536 -| reader.command_bytes or reader.commands.items.len >= 200) {
                reader.commands_partial = true;
            } else {
                const index = for (reader.commands.items, 0..) |known, i| {
                    if (known.id == record.id) break i;
                } else reader.commands.items.len;
                const reference = try std.fmt.allocPrint(a, "ac1:{s}:{d}:{d}", .{ reader.grant.recording_id, reader.grant.recording_generation, record.id });
                const command: KnownCommand = .{ .id = record.id, .record = .{ .reference = reference, .submitted_command = try a.dupe(u8, record.command), .submitted_at_ms = record.timestamp_ms, .verified = false, .complete = false }, .output = try a.dupe(u8, record.output), .first_ms = if (index < reader.commands.items.len) reader.commands.items[index].first_ms else ms, .last_ms = ms };
                if (index == reader.commands.items.len) try reader.commands.append(a, command) else reader.commands.items[index] = command;
                reader.command_bytes += record.command.len + record.output.len;
            }
        }
    }
    reader.event_sequence += 1;
    reader.observed_event_ms = ms;
}
const Rendered = struct { value: host.Result, more: bool };
fn finish(invocation: host.Invocation, allocator: std.mem.Allocator, body: []u8, more: bool) !Rendered {
    errdefer allocator.free(body);
    if (body.len > 64 * 1024) return error.ResultLimit;
    const blocks = try allocator.alloc(host.Block, 1);
    blocks[0] = .{ .structured = body };
    return .{ .more = more, .value = .{ .status = .succeeded, .blocks = blocks, .receipt = .{ .conversation_id = invocation.context.conversation_id, .task_id = invocation.context.task_id, .operation_id = invocation.operation_id, .binding_revision = invocation.context.binding_revision } } };
}
fn render(reader: *Reader, invocation: host.Invocation, allocator: std.mem.Allocator) !Rendered {
    const doc = reader.record.document.value;
    const cursor = std.fmt.bytesToHex(reader.token, .lower);
    if (!reader.decoded) return finish(invocation, allocator, try std.json.Stringify.valueAlloc(allocator, .{ .source_ref = reader.request.source.recording, .source_revision = doc.manifest_revision, .observed_at = std.Io.Clock.real.now(reader.record.lease.cast().io).toMilliseconds(), .timestamp_basis = "client_receive", .time_basis = "cast_first_event_elapsed_ms", .time_coordinate = "cast_first_event_elapsed_ms", .phase = if (reader.verified) "decoding" else "verifying_committed_dependencies", .scan_progress = .{ .verified_files = reader.verify_file, .verified_file_offset = reader.verify_offset, .cast_bytes_scanned = reader.offset, .cast_committed_bytes = reader.record.lease.cast().stat.size, .events_decoded = reader.event_sequence, .max_io_bytes_per_call = scan_bytes * 2, .max_events_per_call = event_limit }, .gap = &[_][]const u8{"scan_in_progress"}, .complete = false, .truncated = true, .next_cursor = &cursor }, .{}), true);
    if (std.mem.eql(u8, reader.tool, "host.list_terminal_commands")) return renderCommands(reader, invocation, allocator);
    if (reader.request.range_kind == .command) return renderCommandOutput(reader, invocation, allocator);
    var native: terminal.ContentRequest = .{ .max_lines = @intCast(@min(reader.request.max_lines, 100)), .max_bytes = @min(reader.request.max_bytes, 6000), .after_line = reader.after_line };
    switch (reader.request.range_kind) {
        .lines => {
            native.range_kind = .lines;
            native.start_line = reader.request.start_line;
            native.end_line = reader.request.end_line;
        },
        .time => {
            native.range_kind = .time;
            native.start_ms = std.math.add(i64, reader.request.start_ms.?, 1) catch return error.InvalidRange;
            native.end_ms = std.math.add(i64, reader.request.end_ms.?, 1) catch return error.InvalidRange;
        },
        else => {},
    }
    var captured = try reader.adapter.?.contentQuery(reader.grant.owner, native, allocator);
    defer captured.deinit(allocator);
    for (captured.lines) |*line| if (line.received_at_ms) |ms| {
        line.received_at_ms = ms - 1;
    };
    const searching = reader.request.query != null;
    if (searching) return renderSearch(reader, invocation, allocator, &captured);
    reader.after_line = captured.next_line;
    const more = captured.next_line != null;
    return finish(invocation, allocator, try std.json.Stringify.valueAlloc(allocator, .{ .source_ref = reader.request.source.recording, .source_revision = doc.manifest_revision, .observed_at = std.Io.Clock.real.now(reader.record.lease.cast().io).toMilliseconds(), .timestamp_basis = "client_receive", .time_basis = "cast_first_event_elapsed_ms", .time_coordinate = "cast_first_event_elapsed_ms", .coordinate_basis = "recorded_snapshot_logical_lines", .representation = if (captured.alternate_screen) "recorded_alternate_screen_snapshot" else "recorded_terminal_snapshot", .snapshot_event = .{ .cast_event_index = reader.event_sequence, .received_at_ms = reader.observed_event_ms }, .range_requested = .{ .kind = @tagName(reader.request.range_kind), .start_line = reader.request.start_line, .end_line = reader.request.end_line, .start_ms = reader.request.start_ms, .end_ms = reader.request.end_ms }, .range_returned = .{ .first_line = if (captured.lines.len > 0) @as(?u64, captured.lines[0].line) else null, .last_line = if (captured.lines.len > 0) @as(?u64, captured.lines[captured.lines.len - 1].line) else null, .retained_logical_lines = captured.total_lines }, .lines = captured.lines, .coverage = doc.coverage, .replayability = doc.replayability, .recording_gaps = doc.gaps, .decoder_retention_max_rows = 4096, .gap = &[_][]const u8{ "recorded_snapshot_not_full_transcript", "decoder_retention_is_bounded" }, .complete = false, .truncated = more or captured.unknown_timestamps, .next_cursor = if (more) @as(?[]const u8, &cursor) else null }, .{}), more);
}
const Match = struct { line: u64, byte_offset: usize, text: []const u8, received_at_ms: ?i64 };
fn find(text: []const u8, query: []const u8, start: usize, sensitive: bool) ?usize {
    if (start > text.len or query.len > text.len - start) return null;
    var at = start;
    while (at <= text.len - query.len) : (at += 1) {
        if (sensitive) {
            if (std.mem.eql(u8, text[at..][0..query.len], query)) return at;
        } else if (std.ascii.eqlIgnoreCase(text[at..][0..query.len], query)) return at;
    }
    return null;
}
fn renderSearch(reader: *Reader, invocation: host.Invocation, a: std.mem.Allocator, captured: *terminal.ContentCapture) !Rendered {
    var matches: std.ArrayList(Match) = .empty;
    defer matches.deinit(a);
    const query = reader.request.query.?;
    var more = captured.next_line != null;
    reader.after_line = captured.next_line;
    outer: for (captured.lines) |line| {
        var at = reader.search_byte;
        reader.search_byte = 0;
        while (find(line.text, query, at, reader.request.case_sensitive)) |hit| {
            if (matches.items.len >= @min(reader.request.limit, 32)) {
                reader.after_line = line.line;
                reader.search_byte = hit;
                more = true;
                break :outer;
            }
            const context_start = hit -| 64;
            const context_end = @min(line.text.len, hit + query.len + 64);
            // Context boundaries must stay at UTF-8 codepoint boundaries.
            var lo = context_start;
            var hi = context_end;
            while (lo > 0 and lo < line.text.len and (line.text[lo] & 0xc0) == 0x80) lo -= 1;
            while (hi < line.text.len and (line.text[hi] & 0xc0) == 0x80) hi += 1;
            try matches.append(a, .{ .line = line.line, .byte_offset = hit, .text = line.text[lo..hi], .received_at_ms = line.received_at_ms });
            at = hit + query.len;
        }
    }
    const cursor = std.fmt.bytesToHex(reader.token, .lower);
    return finish(invocation, a, try std.json.Stringify.valueAlloc(a, .{ .source_ref = reader.request.source.recording, .source_revision = reader.record.document.value.manifest_revision, .observed_at = std.Io.Clock.real.now(reader.record.lease.cast().io).toMilliseconds(), .timestamp_basis = "client_receive", .time_basis = "cast_first_event_elapsed_ms", .time_coordinate = "cast_first_event_elapsed_ms", .coordinate_basis = "recorded_snapshot_logical_lines", .representation = if (captured.alternate_screen) "recorded_alternate_screen_snapshot" else "recorded_terminal_snapshot", .snapshot_event = .{ .cast_event_index = reader.event_sequence, .received_at_ms = reader.observed_event_ms }, .case_folding = if (reader.request.case_sensitive) "exact_utf8" else "ascii_only", .matches = matches.items, .decoder_retention_max_rows = 4096, .gap = &[_][]const u8{ "recorded_snapshot_not_full_transcript", "decoder_retention_is_bounded" }, .complete = false, .truncated = more or captured.unknown_timestamps, .next_cursor = if (more) @as(?[]const u8, &cursor) else null }, .{}), more);
}
fn renderCommands(reader: *Reader, invocation: host.Invocation, a: std.mem.Allocator) !Rendered {
    if (reader.commands.items.len == 0) return error.CommandIndexUnavailable;
    if (reader.request.range_kind == .lines) return error.RangeUnavailable;
    var commands: std.ArrayList(queries.Command) = .empty;
    defer commands.deinit(a);
    var next = reader.command_page;
    while (next < reader.commands.items.len and commands.items.len < @min(reader.request.limit, 32)) : (next += 1) {
        const command = reader.commands.items[next];
        if (reader.request.range_kind == .time and (command.first_ms > reader.request.end_ms.? or command.last_ms < reader.request.start_ms.?)) continue;
        try commands.append(a, command.record);
    }
    reader.command_page = next;
    const more = next < reader.commands.items.len;
    const cursor = std.fmt.bytesToHex(reader.token, .lower);
    return finish(invocation, a, try std.json.Stringify.valueAlloc(a, .{ .source_ref = reader.request.source.recording, .source_revision = reader.record.document.value.manifest_revision, .observed_at = std.Io.Clock.real.now(reader.record.lease.cast().io).toMilliseconds(), .timestamp_basis = "client_receive", .time_basis = "cast_first_event_elapsed_ms", .time_coordinate = "cast_first_event_elapsed_ms", .range_requested = .{ .kind = @tagName(reader.request.range_kind), .start_ms = reader.request.start_ms, .end_ms = reader.request.end_ms }, .range_returned = .{ .command_offset = next - commands.items.len, .count = commands.items.len }, .index_scope = "typed_application_records_only", .commands = commands.items, .gap = &[_][]const u8{"typed_application_commands_only"}, .complete = false, .truncated = more or reader.commands_partial, .next_cursor = if (more) @as(?[]const u8, &cursor) else null }, .{}), more);
}
fn renderCommandOutput(reader: *Reader, invocation: host.Invocation, a: std.mem.Allocator) !Rendered {
    if (reader.execution_range != null) return renderExecutionOutput(reader, invocation, a);
    const command = for (reader.commands.items) |item| {
        if (std.mem.eql(u8, item.record.reference, reader.request.command_ref.?)) break item;
    } else return error.CommandIndexUnavailable;
    if (reader.request.query != null) return renderCommandSearch(reader, invocation, a, command.output, "typed_application_output_bytes");
    var rows: std.ArrayList(struct { line: u64, text: []const u8 }) = .empty;
    defer rows.deinit(a);
    var lines = std.mem.splitScalar(u8, command.output, '\n');
    var index: u64 = 0;
    var used: usize = 0;
    var more = false;
    while (lines.next()) |line| : (index += 1) {
        if (index < (reader.after_line orelse 0)) continue;
        if (rows.items.len >= @min(reader.request.max_lines, 100) or line.len > @min(reader.request.max_bytes, 6000) -| used) {
            if (rows.items.len == 0) return error.ResultLimit;
            reader.after_line = index;
            more = true;
            break;
        }
        try rows.append(a, .{ .line = index, .text = line });
        used += line.len;
    }
    const cursor = std.fmt.bytesToHex(reader.token, .lower);
    return finish(invocation, a, try std.json.Stringify.valueAlloc(a, .{ .source_ref = reader.request.source.recording, .source_revision = reader.record.document.value.manifest_revision, .observed_at = std.Io.Clock.real.now(reader.record.lease.cast().io).toMilliseconds(), .timestamp_basis = "client_receive", .time_basis = "cast_first_event_elapsed_ms", .time_coordinate = "cast_first_event_elapsed_ms", .coordinate_basis = "typed_application_output_logical_lines", .representation = "typed_application_record", .command_ref = command.record.reference, .lines = rows.items, .event_time_range = .{ .start_ms = command.first_ms, .end_ms = command.last_ms }, .gap = &[_][]const u8{"typed_application_output_only"}, .complete = false, .truncated = more, .next_cursor = if (more) @as(?[]const u8, &cursor) else null }, .{}), more);
}

fn commandExecution(grant: Grant, reference: []const u8) ![]const u8 {
    var parts = std.mem.splitScalar(u8, reference, ':');
    if (!std.mem.eql(u8, parts.next() orelse "", "c1") or !std.mem.eql(u8, parts.next() orelse "", &std.fmt.bytesToHex(grant.context.conversation_id.bytes, .lower))) return error.StaleReference;
    const session_id = std.fmt.parseInt(u64, parts.next() orelse "", 10) catch return error.StaleReference;
    const generation = std.fmt.parseInt(u64, parts.next() orelse "", 10) catch return error.StaleReference;
    if (session_id != @backingInt(grant.owner.session_id) or generation != grant.owner.generation) return error.StaleGeneration;
    const id = parts.next() orelse return error.StaleReference;
    _ = identity.ExecutionId.parse(id) catch return error.StaleReference;
    if (parts.next() != null) return error.StaleReference;
    return id;
}
fn renderExecutionOutput(reader: *Reader, invocation: host.Invocation, a: std.mem.Allocator) !Rendered {
    const range = reader.execution_range.?;
    if (reader.request.query != null) return renderCommandSearch(reader, invocation, a, reader.interval_output.items, "recorded_cast_output_bytes");
    const start = reader.interval_byte;
    var end = @min(reader.interval_output.items.len, start + @min(reader.request.max_bytes, 6000));
    while (end > start and end < reader.interval_output.items.len and (reader.interval_output.items[end] & 0xc0) == 0x80) end -= 1;
    if (end == start and end < reader.interval_output.items.len) return error.ResultLimit;
    const text = reader.interval_output.items[start..end];
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidCast;
    reader.interval_byte = end;
    const more = end < reader.interval_output.items.len;
    const cursor = std.fmt.bytesToHex(reader.token, .lower);
    return finish(invocation, a, try std.json.Stringify.valueAlloc(a, .{ .source_ref = reader.request.source.recording, .source_revision = reader.record.document.value.manifest_revision, .observed_at = std.Io.Clock.real.now(reader.record.lease.cast().io).toMilliseconds(), .timestamp_basis = "client_receive", .time_basis = "cast_first_event_elapsed_ms", .time_coordinate = "cast_first_event_elapsed_ms", .coordinate_basis = "recorded_event_range", .representation = "recorded_terminal_output", .command_ref = reader.request.command_ref, .execution_id = range.execution_id, .range_returned = .{ .start = range.start, .end = range.end, .cast_output_byte_start = start, .cast_output_byte_end = end }, .output = text, .output_scope = range.output_scope, .output_attribution = range.output_attribution, .completion_evidence = range.completion_evidence, .recording_coverage = reader.record.document.value.coverage, .recording_gaps = reader.record.document.value.gaps, .interval_gaps = range.gaps, .gap = &[_][]const u8{"terminal_output_is_untrusted_data"}, .complete = false, .truncated = more, .next_cursor = if (more) @as(?[]const u8, &cursor) else null }, .{}), more);
}

fn renderCommandSearch(reader: *Reader, invocation: host.Invocation, a: std.mem.Allocator, text: []const u8, basis: []const u8) !Rendered {
    const query = reader.request.query.?;
    const start = reader.interval_byte;
    const scan_end = @min(text.len, start + @min(reader.request.max_bytes, 6000));
    var at = start;
    var matches: std.ArrayList(struct { byte_offset: usize, text: []const u8 }) = .empty;
    defer matches.deinit(a);
    var next = scan_end;
    while (find(text, query, at, reader.request.case_sensitive)) |hit| {
        if (hit >= scan_end) break;
        if (matches.items.len >= @min(reader.request.limit, 32)) {
            next = hit;
            break;
        }
        var lo = hit -| 32;
        var hi = @min(text.len, hit + query.len + 32);
        while (lo > 0 and (text[lo] & 0xc0) == 0x80) lo -= 1;
        while (hi < text.len and (text[hi] & 0xc0) == 0x80) hi += 1;
        try matches.append(a, .{ .byte_offset = hit, .text = text[lo..hi] });
        at = hit + query.len;
    }
    reader.interval_byte = next;
    const more = next < text.len;
    const cursor = std.fmt.bytesToHex(reader.token, .lower);
    return finish(invocation, a, try std.json.Stringify.valueAlloc(a, .{ .source_ref = reader.request.source.recording, .source_revision = reader.record.document.value.manifest_revision, .observed_at = std.Io.Clock.real.now(reader.record.lease.cast().io).toMilliseconds(), .timestamp_basis = "client_receive", .time_basis = "cast_first_event_elapsed_ms", .time_coordinate = "cast_first_event_elapsed_ms", .coordinate_basis = basis, .representation = if (reader.execution_range != null) "recorded_terminal_output" else "typed_application_record", .command_ref = reader.request.command_ref, .matches = matches.items, .case_folding = if (reader.request.case_sensitive) "exact_utf8" else "ascii_only", .gap = &[_][]const u8{"command_output_only"}, .complete = false, .truncated = more, .next_cursor = if (more) @as(?[]const u8, &cursor) else null }, .{}), more);
}
