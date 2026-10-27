//! UI-thread composite terminal document. App records are never fed to the VT
//! or transport. Native rows retain the VT's stable identities and cell styles.
const std = @import("std");
const terminal = @import("../host/terminal_service.zig");
const vt = @import("../vt/snapshot.zig");
const search = @import("../vt/search_snapshot.zig");
const identity = @import("../host/identity.zig");
const record_geometry = @import("terminal_record_geometry.zig");
const unicode = @import("generated_ghostty_vt");
pub const State = enum { pending, success, failure };
const Record = struct { id: u64, anchor: terminal.Anchor, command: []u8, output: []u8, state: State, timestamp: i64, record_dirty: bool = true, updated_at: i64 = 0 };
const RestoreId = struct { owner: identity.SessionHandle, external: u64, local: u64 };
const Ref = struct { id: u64, row: vt.RowId, col: u16, alternate: bool };
const Meta = struct { id: u64 = 0, kind: enum { shell, command, success, failure, pending } = .shell, timestamp: ?i64 = null, state: State = .pending };
pub const Document = struct {
    allocator: std.mem.Allocator,
    raw: terminal.Service,
    owner: identity.SessionHandle,
    records: std.ArrayList(Record) = .empty,
    refs: std.ArrayList(Ref) = .empty,
    restored: std.ArrayList(RestoreId) = .empty,
    bytes: usize = 0,
    next_id: u64 = 1,
    next_ref: u64 = 1 << 63,
    revision: u64 = 1,
    source_version: u64 = 0,
    recording_failure: ?anyerror = null,
    cached: ?search.Document = null,
    cache_allocator: std.mem.Allocator = std.heap.page_allocator,
    source_cache: ?search.Document = null,
    source_shape: ?@import("../vt/search_task.zig").Shape = null,
    source_complete: bool = false,
    search_task: ?*terminal.SearchTask = null,
    search_failure: ?struct { err: anyerror, rows: u64, shape: @import("../vt/search_task.zig").Shape } = null,
    source_map: std.ArrayList(u32) = .empty,
    map_base: u32 = 0,
    incremental_rebuilds: u64 = 0,
    background_scans: u64 = 0,
    synchronous_scans: u64 = 0,
    preview_rebuilds: u64 = 0,
    last_composed_rows: usize = 0,
    profile_compose_us: u64 = 0,
    pending_patch_start: ?usize = null,
    tail_cache: ?struct { fingerprint: u64, row: usize } = null,
    full_rebuilds: u64 = 0,
    tail_updates: u64 = 0,
    metadata: std.ArrayList(Meta) = .empty,
    stamps: std.AutoHashMapUnmanaged(vt.RowId, i64) = .empty,
    top: usize = 0,
    pixel_scrolling: bool = false,
    pixel_offset: f32 = 0,
    height: u16 = 1,
    row_height: f32 = 22,
    cell_width: f32 = 8.4,
    follow: bool = true,
    alternate: bool = false,
    enabled: bool = false,
    command_inset_cells: u16 = 8,
    result_inset_cells: u16 = 3,
    colors: [3]u24 = .{ 0x818cf8, 0x67b88b, 0xdf8598 },
    pub fn init(allocator: std.mem.Allocator, raw: terminal.Service, owner: identity.SessionHandle) Document {
        return .{ .allocator = allocator, .raw = raw, .owner = owner };
    }
    pub fn deinit(self: *Document) void {
        for (self.records.items) |r| {
            self.raw.releaseAnchor(r.anchor) catch {};
            self.allocator.free(r.command);
            self.allocator.free(r.output);
        }
        self.records.deinit(self.allocator);
        self.refs.deinit(self.allocator);
        self.restored.deinit(self.allocator);
        if (self.search_task) |task| {
            task.cancelled.store(true, .release);
            task.release();
        }
        if (self.source_cache) |*d| d.deinit(self.cache_allocator);
        self.source_map.deinit(self.cache_allocator);
        self.metadata.deinit(self.cache_allocator);
        self.stamps.deinit(self.cache_allocator);
        if (self.cached) |*d| d.deinit(self.cache_allocator);
    }
    pub fn composed(self: *const Document) bool {
        return self.enabled or self.pixel_scrolling;
    }
    fn rowOrigin(doc: *const search.Document, index: usize) f32 {
        if (index >= doc.rows.len) return 0;
        const layout = doc.rows[index].presentation;
        return layout.y.? - layout.before;
    }
    fn maxPixelOrigin(self: *const Document, doc: *const search.Document) f32 {
        // Keep the existing bottom alignment, including command-card spacing.
        return rowOrigin(doc, self.maxTop(doc));
    }
    fn locatePixel(self: *Document, doc: *const search.Document, origin: f32) void {
        var lo: usize = 0;
        var hi = doc.rows.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (rowOrigin(doc, mid) <= origin) lo = mid + 1 else hi = mid;
        }
        self.top = lo -| 1;
        self.pixel_offset = origin - rowOrigin(doc, self.top);
    }
    /// Positive pixels move toward newer output. Only the UI document moves;
    /// the PTY geometry and alternate-screen input protocol stay unchanged.
    pub fn scrollPixels(self: *Document, pixels: f32) !void {
        if (!std.math.isFinite(pixels) or pixels == 0) return;
        var native = try self.raw.snapshot(self.allocator);
        defer native.deinit(self.allocator);
        if (native.projection.modes.alternate_screen) return;
        self.height = native.projection.rows;
        try self.rebuild(&native);
        // An async viewport-only preview cannot establish the scroll range.
        // Keep the wheel delta pending until the full history scan arrives,
        // otherwise maximum=0 consumes the gesture and snaps back to live.
        if (!self.source_complete) return error.WorkerBusy;
        if (!self.composed()) {
            self.top = @intCast(native.projection.scrollback.viewport_offset);
            self.follow = native.projection.scrollback.viewport_offset + native.projection.scrollback.viewport_rows >= native.projection.scrollback.total_rows;
        }
        const doc = &self.cached.?;
        const maximum = self.maxPixelOrigin(doc);
        const previous = if (self.follow) maximum else rowOrigin(doc, self.top) + self.pixel_offset;
        const origin = std.math.clamp(previous + pixels, 0, maximum);
        self.locatePixel(doc, origin);
        self.pixel_scrolling = true;
        self.follow = origin == maximum;
    }
    pub fn service(self: *Document) terminal.Service {
        return .{ .binding = self.raw.binding, .context = self, .vtable = &vtable };
    }
    pub fn setRowHeight(self: *Document, height: f32) bool {
        if (height <= 0 or height == self.row_height) return false;
        self.row_height = height;
        self.invalidate();
        return self.composed();
    }
    pub fn setCellWidth(self: *Document, width: f32) bool {
        if (width <= 0) return false;
        const command: u16 = @intFromFloat(@min(100, @ceil(record_geometry.command_inset / width)));
        const result: u16 = @intFromFloat(@min(100, @ceil(record_geometry.result_inset / width)));
        if (command == self.command_inset_cells and result == self.result_inset_cells and self.cell_width == width) return false;
        self.cell_width = width;
        self.command_inset_cells = command;
        self.result_inset_cells = result;
        self.invalidate();
        return self.composed();
    }
    pub fn setColors(self: *Document, colors: [3]u24) bool {
        if (std.meta.eql(self.colors, colors)) return false;
        self.colors = colors;
        self.invalidate();
        return self.composed();
    }
    fn invalidate(self: *Document) void {
        self.tail_cache = null;
        self.pending_patch_start = null;
        self.source_version = 0;
        self.revision +|= 1;
    }
    pub fn begin(self: *Document, command: []const u8, timestamp: i64) !u64 {
        return self.beginAt(command, timestamp, null);
    }
    fn beginAt(self: *Document, command: []const u8, timestamp: i64, screen_row: ?u32) !u64 {
        if (command.len == 0 or command.len > 16 * 1024 or !std.unicode.utf8ValidateSlice(command)) return error.InvalidCommand;
        var snap = try self.raw.snapshot(self.allocator);
        defer snap.deinit(self.allocator);
        if (snap.projection.modes.alternate_screen) return error.CommandNotAtPrompt;
        const anchor = try self.raw.createAnchor(.{ .space = .screen, .row = screen_row orelse @as(u32, @intCast(snap.projection.scrollback.total_rows -| snap.projection.rows + snap.projection.active_cursor.row)), .col = 0, .source_version = snap.projection.version });
        errdefer self.raw.releaseAnchor(anchor) catch {};
        const owned = try self.displayCopy(command);
        errdefer self.allocator.free(owned);
        const output = try self.allocator.dupe(u8, "执行中…");
        errdefer self.allocator.free(output);
        try self.records.ensureUnusedCapacity(self.allocator, 1);
        while (self.records.items.len >= 256 or self.bytes + owned.len + output.len > 1024 * 1024) self.evict();
        const id = self.next_id;
        self.next_id = try std.math.add(u64, id, 1);
        self.records.appendAssumeCapacity(.{ .id = id, .anchor = anchor, .command = owned, .output = output, .state = .pending, .timestamp = timestamp });
        self.bytes += owned.len + output.len;
        self.enabled = true;
        _ = self.flushRecording();
        self.follow = true;
        self.invalidate();
        // Start the first immutable capture as soon as a record is accepted,
        // while its command dispatch finishes. Waiting for the next snapshot
        // otherwise adds a whole frame before the worker can start.
        if (self.source_cache == null and self.search_task == null) {
            if (self.raw.beginSearch()) |task| {
                self.search_task = task;
                self.background_scans += 1;
            } else |_| {}
        }
        return id;
    }
    pub fn restore(self: *Document, record: terminal.ApplicationRecord) !void {
        for (self.restored.items) |mapped| if (mapped.owner.eql(record.owner) and mapped.external == record.id) {
            return self.finish(self.owner, mapped.local, @fromBackingInt(@intCast(@backingInt(record.state))), record.output);
        };
        try self.restored.ensureUnusedCapacity(self.allocator, 1);
        const id = try self.beginAt(record.command, record.timestamp_ms, record.anchor_row);
        self.restored.appendAssumeCapacity(.{ .owner = record.owner, .external = record.id, .local = id });
        try self.finish(self.owner, id, @fromBackingInt(@intCast(@backingInt(record.state))), record.output);
    }
    fn evict(self: *Document) void {
        self.evictAt(0);
    }
    fn evictAt(self: *Document, index: usize) void {
        const r = self.records.orderedRemove(index);
        var mapped_index: usize = 0;
        while (mapped_index < self.restored.items.len) {
            if (self.restored.items[mapped_index].local == r.id) {
                _ = self.restored.orderedRemove(mapped_index);
            } else mapped_index += 1;
        }
        self.bytes -= r.command.len + r.output.len;
        self.raw.releaseAnchor(r.anchor) catch {};
        self.allocator.free(r.command);
        self.allocator.free(r.output);
    }
    pub fn finish(self: *Document, owner: identity.SessionHandle, id: u64, state: State, output: []const u8) !void {
        if (!owner.eql(self.owner)) return error.StaleOwner;
        if (output.len > 64 * 1024 or !std.unicode.utf8ValidateSlice(output)) return error.InvalidCommandOutput;
        for (self.records.items) |r| if (r.id == id and r.state != .pending) {
            if (r.state == state and std.mem.eql(u8, r.output, output)) return;
            return error.CommandAlreadyCompleted;
        };
        while (true) {
            var old_length: ?usize = null;
            for (self.records.items) |r| if (r.id == id) {
                old_length = r.output.len;
                break;
            };
            const previous = old_length orelse return error.CommandRecordExpired;
            if (self.bytes - previous + displayLength(output) <= 1024 * 1024) break;
            if (self.records.items.len <= 1) return error.CommandRecordCapacity;
            self.evictAt(if (self.records.items[0].id == id) 1 else 0);
        }
        for (self.records.items) |*r| if (r.id == id) {
            if (r.state != .pending) {
                if (r.state == state and std.mem.eql(u8, r.output, output)) return;
                return error.CommandAlreadyCompleted;
            }
            const text = try self.displayCopy(output);
            self.bytes -= r.output.len;
            self.allocator.free(r.output);
            r.output = text;
            r.state = state;
            r.record_dirty = true;
            r.updated_at = @import("../platform/realtime.zig").milliseconds(undefined);
            self.bytes += text.len;
            self.invalidate();
            _ = self.flushRecording();
            return;
        };
        return error.CommandRecordExpired;
    }
    fn displayLength(value: []const u8) usize {
        var length: usize = 0;
        for (value) |byte| length += if (byte < 32 and byte != '\n' and byte != '\t' or byte == 127) @as(usize, 4) else 1;
        return length;
    }
    fn displayCopy(self: *Document, value: []const u8) ![]u8 {
        const text = try self.allocator.alloc(u8, displayLength(value));
        var at: usize = 0;
        const hex = "0123456789abcdef";
        for (value) |byte| {
            if (byte < 32 and byte != '\n' and byte != '\t' or byte == 127) {
                text[at..][0..4].* = .{ '\\', 'x', hex[byte >> 4], hex[byte & 15] };
                at += 4;
            } else {
                text[at] = byte;
                at += 1;
            }
        }
        return text;
    }
    fn firstSpan(doc: *const search.Document, row: usize) usize {
        var lo: usize = 0;
        var hi = doc.spans.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (doc.spans[mid].row < row) lo = mid + 1 else hi = mid;
        }
        return lo;
    }
    /// Retry the provider mailbox without losing a final record when its VT
    /// worker owns the serialization guard. No transport bytes are submitted.
    pub fn flushRecording(self: *Document) bool {
        var complete = true;
        for (self.records.items) |*r| if (r.record_dirty) {
            const position = self.raw.resolveAnchor(r.anchor) catch |err| {
                if (err == error.WorkerBusy) {
                    complete = false;
                    continue;
                }
                self.recording_failure = err;
                r.record_dirty = false;
                continue;
            };
            self.raw.recordApplication(.{ .id = r.id, .owner = self.owner, .timestamp_ms = r.timestamp, .anchor_row = if (position) |point| point.row else null, .command = r.command, .output = r.output, .state = @fromBackingInt(@intCast(@backingInt(r.state))) }) catch |err| {
                if (err == error.WorkerBusy) {
                    complete = false;
                    continue;
                }
                self.recording_failure = err;
                r.record_dirty = false;
                continue;
            };
            r.record_dirty = false;
        };
        return complete;
    }
    fn checked(raw: *anyopaque, binding: @TypeOf(@as(terminal.Service, undefined).binding)) !*Document {
        const self: *Document = @ptrCast(@alignCast(raw));
        if (!std.meta.eql(binding, self.raw.binding)) return error.StaleOwner;
        return self;
    }
    pub fn searchReady(self: *const Document) bool {
        return if (self.search_task) |task| task.done.load(.acquire) else false;
    }
    fn rebuild(self: *Document, native: *const terminal.TerminalSnapshot) !void {
        var arrived = false;
        if (self.search_task) |task| if (task.done.load(.acquire)) {
            defer task.release();
            self.search_task = null;
            arrived = true;
            if (task.take()) |result| {
                if (result.owner.eql(self.owner) and result.shape.matches(&native.projection)) {
                    if (self.source_cache) |*old| old.deinit(self.cache_allocator);
                    self.source_cache = result.document;
                    self.source_shape = result.shape;
                    self.source_complete = true;
                    self.pending_patch_start = null;
                    self.search_failure = null;
                } else {
                    var stale = result.document;
                    stale.deinit(self.cache_allocator);
                }
            } else if (task.failure) |err| {
                self.search_failure = .{ .err = err, .rows = native.projection.scrollback.total_rows, .shape = @import("../vt/search_task.zig").Shape.from(&native.projection) };
            }
        };
        if (!arrived and self.cached != null and self.source_version == native.projection.version) return;
        if (!arrived and try self.patchTail(native)) return;
        if (self.source_complete and self.source_cache.?.source_version > native.projection.version) return error.WorkerBusy;
        var patch_start = self.pending_patch_start;
        var fresh = false;
        if (self.source_complete and self.source_shape != null and self.source_shape.?.matches(&native.projection)) {
            const source = &self.source_cache.?;
            if (source.source_version == native.projection.version) {
                fresh = true;
            } else if (source.source_version < native.projection.version and source.rows.len >= native.projection.rows and native.projection.scrollback.total_rows >= source.rows.len) {
                var start = source.rows.len - native.projection.rows;
                if (start > 0) start -= 1; // immutable history boundary witness
                const tail_limit = native.projection.rows *| 2 +| 1;
                while (start > 0 and source.rows.len - start <= tail_limit and !std.meta.eql(source.rows[start].id, source.rows[start].logical_id)) start -= 1;
                if (self.raw.searchTail(.{ .start_row = @intCast(start), .version = native.projection.version, .max_rows = native.projection.rows *| 2 +| 1 }, self.cache_allocator)) |value| {
                    var tail = value;
                    defer tail.deinit(self.cache_allocator);
                    if (tail.owner.eql(self.owner) and tail.document.rows.len > 0 and (start == 0 or std.meta.eql(tail.document.rows[0].id, source.rows[start].id))) {
                        search.spliceTail(source, self.cache_allocator, start, &tail.document) catch |err| {
                            self.source_complete = false;
                            return err;
                        };
                        fresh = true;
                        if (!arrived) {
                            patch_start = start;
                            self.pending_patch_start = start;
                        }
                    }
                } else |err| switch (err) {
                    error.WorkerBusy, error.StaleProjection => return error.WorkerBusy,
                    else => {},
                }
            }
        }
        if (!fresh) {
            const failed = if (self.search_failure) |failure| failure.rows == native.projection.scrollback.total_rows and failure.shape.matches(&native.projection) else false;
            if (self.search_task == null and !failed) {
                if (self.raw.beginSearch()) |task| {
                    self.search_task = task;
                    self.search_failure = null;
                    self.background_scans += 1;
                } else |err| switch (err) {
                    error.SearchAsyncUnavailable => {
                        var full = try self.raw.searchSnapshot(self.cache_allocator);
                        if (!full.owner.eql(self.owner) or full.document.source_version != native.projection.version) {
                            full.deinit(self.cache_allocator);
                            return error.StaleProjection;
                        }
                        if (self.source_cache) |*old| old.deinit(self.cache_allocator);
                        self.source_cache = full.document;
                        self.source_shape = @import("../vt/search_task.zig").Shape.from(&native.projection);
                        self.source_complete = true;
                        self.synchronous_scans += 1;
                        fresh = true;
                    },
                    error.WorkerBusy => return error.WorkerBusy,
                    else => return err,
                }
            }
            if (!fresh) {
                const preview = try search.fromProjection(self.cache_allocator, &native.projection);
                if (self.source_cache) |*old| old.deinit(self.cache_allocator);
                self.source_cache = preview;
                self.source_complete = false;
                patch_start = null;
                self.pending_patch_start = null;
                self.source_shape = @import("../vt/search_task.zig").Shape.from(&native.projection);
            }
        }
        try self.compose(&self.source_cache.?, native, patch_start);
        self.pending_patch_start = null;
    }
    fn compose(self: *Document, doc: *const search.Document, native: *const terminal.TerminalSnapshot, patch_start: ?usize) !void {
        const started = profileNow();
        defer self.profile_compose_us = (profileNow() -| started) / 1000;
        var positions: [256]?u32 = @splat(null);
        for (self.records.items, 0..) |r, i| {
            const p = try self.raw.resolveAnchor(r.anchor);
            if (p) |point| if (!point.alternate_screen) {
                positions[i] = point.row;
            };
        }
        const base: u32 = if (doc.rows.len > 0) doc.rows[0].screen_row else 0;
        const start = if (patch_start) |value| (if (self.cached != null and self.map_base == base and value < self.source_map.items.len) value else 0) else 0;
        const prefix: usize = if (start > 0) self.source_map.items[start] else 0;
        const scroll_anchor: ?vt.RowId = if (!self.follow and self.cached != null and self.top < self.cached.?.rows.len) self.cached.?.rows[self.top].id else null;
        var text: std.ArrayList(u8) = .empty;
        var rows: std.ArrayList(search.Row) = .empty;
        var spans: std.ArrayList(search.Span) = .empty;
        if (self.cached) |old| {
            const span_start = firstSpan(&old, prefix);
            const text_end = if (prefix > 0) old.rows[prefix - 1].end else 0;
            text = .fromOwnedSlice(old.text);
            text.items.len = text_end;
            rows = .fromOwnedSlice(old.rows);
            rows.items.len = prefix;
            spans = .fromOwnedSlice(old.spans);
            spans.items.len = span_start;
        }
        self.cached = null;
        self.source_version = 0;
        self.tail_cache = null;
        defer text.deinit(self.cache_allocator);
        defer rows.deinit(self.cache_allocator);
        defer spans.deinit(self.cache_allocator);
        var meta = self.metadata;
        self.metadata = .empty;
        meta.items.len = prefix;
        defer meta.deinit(self.cache_allocator);
        var map = self.source_map;
        self.source_map = .empty;
        map.items.len = start;
        defer map.deinit(self.cache_allocator);
        // Size from the captured source rather than growing and recopying
        // complete history arrays repeatedly during composition.
        var app_bytes: usize = 0;
        for (self.records.items) |record| app_bytes += record.command.len + record.output.len + 2;
        try text.ensureTotalCapacityPrecise(self.cache_allocator, doc.text.len + app_bytes);
        try rows.ensureTotalCapacityPrecise(self.cache_allocator, doc.rows.len);
        try spans.ensureTotalCapacityPrecise(self.cache_allocator, doc.spans.len + @min(app_bytes, 4096));
        try meta.ensureTotalCapacityPrecise(self.cache_allocator, doc.rows.len);
        if (self.stamps.count() > 16384) self.stamps.clearRetainingCapacity();
        for (native.projection.visible_rows) |row| if (row.submitted_wallclock_ms orelse row.received_wallclock_ms) |stamp| try self.stamps.put(self.cache_allocator, row.id, stamp);
        const native_cursor = (native.projection.scrollback.total_rows -| native.projection.rows + native.projection.active_cursor.row) -| base;
        // Plain VT scrolling must retain blank screen rows below the cursor;
        // otherwise entering pixel mode would shift a partially filled screen.
        var last: usize = if (!self.enabled) doc.rows.len else @min(doc.rows.len, @as(usize, @intCast(native_cursor)) + 1);
        for (doc.rows[start..], start..) |r, i| if (r.end > r.start) {
            last = @max(last, i + 1);
        };
        for (doc.rows[start..last], start..) |r, index| {
            try map.append(self.cache_allocator, @intCast(rows.items.len));
            for (self.records.items, 0..) |record, ri| if (positions[ri] != null and positions[ri].? == r.screen_row) {
                try self.appendApp(&text, &rows, &spans, &meta, record, record.command, .command, native.projection.cols, 0);
                try self.appendApp(&text, &rows, &spans, &meta, record, record.output, switch (record.state) {
                    .pending => .pending,
                    .success => .success,
                    .failure => .failure,
                }, native.projection.cols, 1);
            };
            if (rows.items.len > 0 and (index == 0 or !std.meta.eql(doc.rows[index - 1].logical_id, r.logical_id) or meta.items[meta.items.len - 1].kind != .shell)) try text.append(self.cache_allocator, '\n');
            const body_start: u32 = @intCast(text.items.len);
            try text.appendSlice(self.cache_allocator, doc.text[r.start..r.end]);
            const row_index: u32 = @intCast(rows.items.len);
            try rows.append(self.cache_allocator, .{ .id = r.id, .logical_id = r.logical_id, .screen_row = row_index, .start = body_start, .end = @intCast(text.items.len) });
            for (doc.spans[firstSpan(doc, index)..]) |s| {
                if (s.row < index) continue;
                if (s.row > index) break;
                var span = s;
                span.start = body_start + s.start - r.start;
                span.end = body_start + s.end - r.start;
                span.row = row_index;
                try spans.append(self.cache_allocator, span);
            }
            const stamp = if (std.mem.trim(u8, doc.text[r.start..r.end], " \t\r\n").len == 0) null else r.timestamp_ms orelse self.stamps.get(r.id);
            rows.items[rows.items.len - 1].timestamp_ms = stamp;
            try meta.append(self.cache_allocator, .{ .timestamp = stamp });
        }
        // The live grid also includes selectable blank cells below its last
        // occupied row. Preserve those identities without making trailing
        // padding push the prompt out of the viewport after an app insertion.
        const visible_index = native.projection.scrollback.viewport_offset -| base;
        var visible_start: usize = if (visible_index < map.items.len) map.items[@intCast(visible_index)] else 0;
        while (visible_start > 0 and meta.items[visible_start - 1].id != 0) visible_start -= 1;
        var occupied_height = @as(f32, @floatFromInt(rows.items.len - visible_start)) * self.row_height;
        for (meta.items[visible_start..], visible_start..) |m, i| {
            if (m.id == 0) continue;
            if (i == 0 or meta.items[i - 1].id != m.id) occupied_height += record_geometry.margin + record_geometry.padding_top;
            if (m.kind != .command and i > 0 and meta.items[i - 1].kind == .command) occupied_height += record_geometry.result_gap;
            if (i + 1 == meta.items.len or meta.items[i + 1].id != m.id) occupied_height += record_geometry.padding_bottom + record_geometry.margin;
        }
        const viewport_height = @as(f32, @floatFromInt(native.projection.rows)) * self.row_height;
        var padding = last;
        while (occupied_height + self.row_height <= viewport_height and padding < doc.rows.len) : (padding += 1) {
            occupied_height += self.row_height;
            try map.append(self.cache_allocator, @intCast(rows.items.len));
            try text.append(self.cache_allocator, '\n');
            const at: u32 = @intCast(text.items.len);
            const index: u32 = @intCast(rows.items.len);
            try rows.append(self.cache_allocator, .{ .id = doc.rows[padding].id, .logical_id = doc.rows[padding].logical_id, .screen_row = index, .start = at, .end = at });
            try meta.append(self.cache_allocator, .{});
        }
        const owned_text = try text.toOwnedSlice(self.cache_allocator);
        errdefer self.cache_allocator.free(owned_text);
        const owned_rows = try rows.toOwnedSlice(self.cache_allocator);
        errdefer self.cache_allocator.free(owned_rows);
        const owned_spans = try spans.toOwnedSlice(self.cache_allocator);
        self.revision +|= 1;
        // Rows keep logical cell coordinates for pure copy/search. Pixel
        // geometry is a separate presentation plane with exact CSS insets.
        var pixel_y: f32 = if (prefix == 0) 0 else owned_rows[prefix - 1].presentation.y.? + self.row_height + owned_rows[prefix - 1].presentation.after;
        for (owned_rows[prefix..], prefix..) |*r, i| {
            const m = meta.items[i];
            if (m.id != 0) {
                const first = i == 0 or meta.items[i - 1].id != m.id;
                const last_row = i + 1 == owned_rows.len or meta.items[i + 1].id != m.id;
                r.presentation.before = if (first) record_geometry.margin + record_geometry.padding_top else if (m.kind != .command and meta.items[i - 1].kind == .command) record_geometry.result_gap else 0;
                r.presentation.after = if (last_row) record_geometry.padding_bottom + record_geometry.margin else 0;
                const inset_cells: f32 = @floatFromInt(if (m.kind == .command) (if (r.id[1] == 0 and native.projection.cols > self.command_inset_cells + 5) self.command_inset_cells else 0) else self.result_inset_cells);
                const desired: f32 = if (m.kind == .command) (if (inset_cells > 0) record_geometry.command_inset else 0) else record_geometry.result_inset;
                r.presentation.shift_x = desired - inset_cells * self.cell_width;
            }
            pixel_y += r.presentation.before;
            r.presentation.y = pixel_y;
            pixel_y += self.row_height + r.presentation.after;
        }
        var group_start: usize = prefix;
        while (group_start < owned_rows.len) {
            if (meta.items[group_start].id == 0) {
                group_start += 1;
                continue;
            }
            var group_end = group_start + 1;
            while (group_end < owned_rows.len and meta.items[group_end].id == meta.items[group_start].id) : (group_end += 1) {}
            const top = owned_rows[group_start].presentation.y.? - record_geometry.padding_top;
            const bottom = owned_rows[group_end - 1].presentation.y.? + self.row_height + record_geometry.padding_bottom;
            for (owned_rows[group_start..group_end]) |*r| {
                r.presentation.article_y = top;
                r.presentation.article_height = bottom - top;
            }
            group_start = group_end;
        }
        self.cached = .{ .source_version = self.revision, .alternate_screen = false, .text = owned_text, .rows = owned_rows, .spans = owned_spans };
        self.metadata = meta;
        meta = .empty;
        self.source_map = map;
        map = .empty;
        self.map_base = base;
        self.source_version = native.projection.version;
        if (scroll_anchor) |anchor| {
            if (self.top >= prefix) for (owned_rows[prefix..], prefix..) |row, i| {
                if (std.meta.eql(row.id, anchor)) {
                    self.top = i;
                    break;
                }
            };
        }
        self.last_composed_rows = owned_rows.len - prefix;
        if (!self.source_complete) self.preview_rebuilds += 1 else if (patch_start != null) self.incremental_rebuilds += 1 else self.full_rebuilds += 1;
        self.tail_cache = null;
        if (tailFingerprint(&native.projection)) |fingerprint| {
            const cursor_id = native.projection.visible_rows[native.projection.cursor.row].id;
            for (owned_rows[prefix..], prefix..) |row, i| if (std.meta.eql(row.id, cursor_id) and self.metadata.items[i].kind == .shell) {
                var trailing_blank = true;
                for (owned_rows[i + 1 ..]) |after| if (after.end != after.start) {
                    trailing_blank = false;
                    break;
                };
                if (trailing_blank) self.tail_cache = .{ .fingerprint = fingerprint, .row = i };
                break;
            };
        }
    }
    pub fn profileNow() u64 {
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }
    // Ordinary ZLE edits only replace the current final physical row. Verify
    // every other visible cell, stable row identity, palette and geometry;
    // then reuse the complete history/index instead of querying and composing
    // all scrollback again. Newlines, scroll/erase, wrapping, modes, and record
    // changes fall back to the authoritative full rebuild.
    fn tailFingerprint(p: *const vt.Projection) ?u64 {
        if (!p.cursor.visible or p.cursor.row >= p.visible_rows.len or p.scrollback.viewport_offset + p.scrollback.viewport_rows < p.scrollback.total_rows) return null;
        var hash = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hash, .{ p.cols, p.rows, p.cursor.row, p.scrollback, p.colors, p.modes });
        for (p.visible_rows, 0..) |row, i| {
            std.hash.autoHash(&hash, .{ row.id, row.wraps, row.continuation, row.semantic_prompt });
            if (i == p.cursor.row) continue;
            for (p.cells[row.cell_start..][0..row.cell_count]) |cell| {
                var style = cell;
                style.grapheme_start = 0;
                std.hash.autoHash(&hash, style);
                hash.update(p.grapheme(cell));
            }
        }
        return hash.final();
    }
    fn patchTail(self: *Document, native: *const terminal.TerminalSnapshot) !bool {
        const cache = self.tail_cache orelse return false;
        if (self.source_version == 0 or tailFingerprint(&native.projection) != cache.fingerprint) return false;
        const doc = if (self.cached) |*value| value else return false;
        if (cache.row >= doc.rows.len) return false;
        const old = doc.rows[cache.row];
        const row = native.projection.visible_rows[native.projection.cursor.row];
        if (!std.meta.eql(old.id, row.id)) return false;
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.cache_allocator);
        var spans: std.ArrayList(search.Span) = .empty;
        defer spans.deinit(self.cache_allocator);
        const cells = native.projection.cells[row.cell_start..][0..row.cell_count];
        var end = cells.len;
        while (end > 0 and cells[end - 1].grapheme_len == 0) end -= 1;
        for (cells[0..end], 0..) |cell, col| {
            if (cell.width == .wide_tail) continue;
            const start: u32 = old.start + @as(u32, @intCast(text.items.len));
            try text.appendSlice(self.cache_allocator, if (cell.grapheme_len == 0) " " else native.projection.grapheme(cell));
            var span: search.Span = .{ .start = start, .end = old.start + @as(u32, @intCast(text.items.len)), .row = @intCast(cache.row), .col = @intCast(col), .width = if (cell.width == .wide_lead) 2 else 1, .color = @import("../vt/projection_frame.zig").color(cell.foreground, native.projection.colors), .bg = @import("../vt/projection_frame.zig").color(cell.background, native.projection.colors), .flags = (cell.attributes & 3) | (if (cell.underline != 0) @as(u32, 4) else 0), .native_cell = cell };
            span.start -= old.start;
            span.end -= old.start;
            try search.appendSpan(self.cache_allocator, &spans, text.items, span);
        }
        for (spans.items) |*span| {
            span.start += old.start;
            span.end += old.start;
        }
        const prefix_spans = firstSpan(doc, cache.row);
        if (std.mem.eql(u8, doc.text[old.start..old.end], text.items) and doc.spans.len - prefix_spans == spans.items.len) {
            const same = for (doc.spans[prefix_spans..], spans.items) |saved, next| {
                var a = saved;
                var b = next;
                if (a.native_cell) |*cell| cell.grapheme_start = 0;
                if (b.native_cell) |*cell| cell.grapheme_start = 0;
                if (!std.meta.eql(a, b)) break false;
            } else true;
            if (same) {
                self.source_version = native.projection.version;
                return true;
            }
        }
        // Rows after the edited row were verified as empty at full rebuild.
        // Grow existing buffers so ordinary edits do not recopy the entire
        // retained history. Any allocation failure invalidates this cache.
        self.source_version = 0;
        self.tail_cache = null;
        const new_len = doc.text.len - (old.end - old.start) + text.items.len;
        const new_end = old.start + text.items.len;
        const suffix_len = doc.text.len - old.end;
        doc.spans = try self.cache_allocator.realloc(doc.spans, prefix_spans + spans.items.len);
        if (new_len < doc.text.len) std.mem.copyForwards(u8, doc.text[new_end..][0..suffix_len], doc.text[old.end..]);
        doc.text = try self.cache_allocator.realloc(doc.text, new_len);
        if (new_end > old.end) std.mem.copyBackwards(u8, doc.text[new_end..], doc.text[old.end..][0..suffix_len]);
        @memcpy(doc.text[old.start..new_end], text.items);
        @memcpy(doc.spans[prefix_spans..], spans.items);
        const delta = @as(i64, @intCast(text.items.len)) - @as(i64, old.end - old.start);
        doc.rows[cache.row].end = old.start + @as(u32, @intCast(text.items.len));
        for (doc.rows[cache.row + 1 ..]) |*after| {
            after.start = @intCast(@as(i64, after.start) + delta);
            after.end = @intCast(@as(i64, after.end) + delta);
        }
        self.revision +|= 1;
        doc.source_version = self.revision;
        self.source_version = native.projection.version;
        self.tail_cache = cache;
        self.tail_updates += 1;
        return true;
    }
    fn appendApp(self: *Document, text: *std.ArrayList(u8), rows: *std.ArrayList(search.Row), spans: *std.ArrayList(search.Span), meta: *std.ArrayList(Meta), record: Record, value: []const u8, kind: @FieldType(Meta, "kind"), cols: u16, section: u64) !void {
        // App text is measured with the same public grapheme rules as the
        // terminal, without feeding any application bytes into a VT.
        var codepoints: std.ArrayList(u32) = .empty;
        defer codepoints.deinit(self.cache_allocator);
        var byte_offsets: std.ArrayList(usize) = .empty;
        defer byte_offsets.deinit(self.cache_allocator);
        var decoded: usize = 0;
        while (decoded < value.len) {
            try byte_offsets.append(self.cache_allocator, decoded);
            const length = try std.unicode.utf8ByteSequenceLength(value[decoded]);
            try codepoints.append(self.cache_allocator, try std.unicode.utf8Decode(value[decoded..][0..length]));
            decoded += length;
        }
        try byte_offsets.append(self.cache_allocator, value.len);
        var cp_index: usize = 0;
        var offset: usize = 0;
        var line: u64 = 0;
        var logical: u64 = 0;
        var hard_break = true;
        while (offset < value.len) : (line += 1) {
            if (rows.items.len > 0 and hard_break) try text.append(self.cache_allocator, '\n');
            const start: u32 = @intCast(text.items.len);
            const index: u32 = @intCast(rows.items.len);
            var col: u16 = if (section == 1) @min(self.result_inset_cells, cols -| 1) else if (line == 0 and cols > self.command_inset_cells + 5) self.command_inset_cells else 0;
            const line_cols = cols;
            while (offset < value.len and value[offset] != '\n') {
                var measured: u8 = 0;
                const consumed = unicode.ghostty_unicode_grapheme_width(codepoints.items[cp_index..].ptr, codepoints.items.len - cp_index, &measured);
                const size = byte_offsets.items[cp_index + consumed] - offset;
                const width: u16 = @max(1, measured);
                if (col + width > line_cols and col > 0) break;
                const at: u32 = @intCast(text.items.len);
                try text.appendSlice(self.cache_allocator, value[offset..][0..size]);
                try search.appendSpan(self.cache_allocator, spans, text.items, .{ .start = at, .end = @intCast(text.items.len), .row = index, .col = col, .width = width, .color = (@as(u32, switch (kind) {
                    .command => self.colors[0],
                    .success => self.colors[1],
                    .failure => self.colors[2],
                    else => @as(u24, 0x9ca3af),
                }) << 8) | 255, .bg = 0 });
                col += width;
                offset += size;
                cp_index += consumed;
            }
            const ended_line = offset < value.len and value[offset] == '\n';
            if (ended_line) {
                offset += 1;
                cp_index += 1;
            }
            const logical_id: vt.RowId = .{ std.math.maxInt(u64) - record.id, (section << 32) | logical };
            const id: vt.RowId = .{ std.math.maxInt(u64) - record.id, (section << 32) | line };
            try rows.append(self.cache_allocator, .{ .id = id, .logical_id = logical_id, .screen_row = index, .start = start, .end = @intCast(text.items.len), .application_kind = @backingInt(kind), .application_state = @backingInt(record.state), .timestamp_ms = record.timestamp });
            try meta.append(self.cache_allocator, .{ .id = record.id, .kind = kind, .timestamp = record.timestamp, .state = record.state });
            hard_break = ended_line;
            if (ended_line) logical = line + 1;
        }
    }
    fn maxTop(self: *const Document, doc: *const search.Document) usize {
        const viewport_height = @as(f32, @floatFromInt(self.height)) * self.row_height;
        var top = doc.rows.len;
        var used_height: f32 = 0;
        while (top > 0) {
            const candidate = doc.rows[top - 1].presentation;
            const size = candidate.before + self.row_height + candidate.after;
            if (used_height + size > viewport_height and top < doc.rows.len) break;
            used_height += size;
            top -= 1;
        }
        return top;
    }
    fn snapshot(raw: *anyopaque, binding: @TypeOf(@as(terminal.Service, undefined).binding), allocator: std.mem.Allocator) !terminal.TerminalSnapshot {
        const self = try checked(raw, binding);
        var native = try self.raw.snapshot(allocator);
        errdefer native.deinit(allocator);
        self.height = native.projection.rows;
        self.alternate = native.projection.modes.alternate_screen;
        if (self.alternate) {
            self.pixel_offset = 0;
            self.follow = true;
            return native;
        }
        if (!self.enabled and self.pixel_scrolling and self.follow) {
            self.pixel_scrolling = false;
            self.pixel_offset = 0;
        }
        if (!self.composed()) return native;
        try self.rebuild(&native);
        const doc = &self.cached.?;
        const pixel_height = @as(f32, @floatFromInt(self.height)) * self.row_height;
        const max_top = self.maxTop(doc);
        var origin: f32 = 0;
        if (self.pixel_scrolling) {
            const maximum = self.maxPixelOrigin(doc);
            origin = if (self.follow) maximum else @min(rowOrigin(doc, @min(self.top, doc.rows.len -| 1)) + self.pixel_offset, maximum);
            self.locatePixel(doc, origin);
        } else {
            if (self.follow) self.top = max_top else self.top = @min(self.top, max_top);
            origin = rowOrigin(doc, self.top);
        }
        var next_y: f32 = 0;
        var cells: std.ArrayList(vt.Cell) = .empty;
        defer cells.deinit(allocator);
        var graphemes: std.ArrayList(u8) = .empty;
        defer graphemes.deinit(allocator);
        const visible = try allocator.alloc(vt.Row, @as(usize, self.height) + @intFromBool(self.pixel_scrolling and self.pixel_offset > 0 and self.height < std.math.maxInt(u16)));
        errdefer allocator.free(visible);
        var cursor = native.projection.cursor;
        cursor.visible = false;
        const native_cursor_id = if (native.projection.cursor.row < native.projection.visible_rows.len) native.projection.visible_rows[native.projection.cursor.row].id else vt.RowId{ 0, 0 };
        for (visible, 0..) |*row, y| {
            const index = self.top + y;
            const start: u32 = @intCast(cells.items.len);
            try cells.appendNTimes(allocator, .{}, native.projection.cols);
            row.* = .{ .id = .{ 0, y }, .viewport_y = @intCast(y), .cell_start = start, .cell_count = native.projection.cols, .wraps = false, .continuation = false, .logical_start_id = null, .dirty = true, .semantic_prompt = 0 };
            row.presentation.y = @max(pixel_height, next_y);
            if (index >= doc.rows.len) continue;
            const source = doc.rows[index];
            row.presentation = source.presentation;
            row.presentation.y = source.presentation.y.? - origin;
            row.presentation.article_y -= origin;
            next_y = row.presentation.y.? + self.row_height + row.presentation.after;
            const metadata = self.metadata.items[index];
            row.id = source.id;
            row.logical_start_id = source.logical_id;
            row.received_wallclock_ms = metadata.timestamp;
            row.application_record_id = metadata.id;
            row.application_kind = @backingInt(metadata.kind);
            row.application_state = @backingInt(metadata.state);
            if (std.meta.eql(source.id, native_cursor_id)) {
                cursor = native.projection.cursor;
                cursor.row = @intCast(y);
            }
            // Retain every live VT cell attribute verbatim when the row is
            // in the authoritative viewport. Search snapshots provide styles
            // for historical rows outside that viewport.
            if (metadata.kind == .shell) {
                var exact: ?vt.Row = null;
                for (native.projection.visible_rows) |nr| if (std.meta.eql(nr.id, source.id)) {
                    exact = nr;
                    break;
                };
                if (exact) |nr| {
                    row.wraps = nr.wraps;
                    row.continuation = nr.continuation;
                    row.semantic_prompt = nr.semantic_prompt;
                    for (native.projection.cells[nr.cell_start..][0..nr.cell_count], 0..) |cell, col| {
                        var copy = cell;
                        copy.grapheme_start = @intCast(graphemes.items.len);
                        if (cell.grapheme_len > 0) try graphemes.appendSlice(allocator, native.projection.graphemes[cell.grapheme_start..][0..cell.grapheme_len]);
                        cells.items[start + col] = copy;
                    }
                    continue;
                }
            }
            for (doc.spans[firstSpan(doc, index)..]) |s| {
                if (s.row < index) continue;
                if (s.row > index) break;
                var byte = s.start;
                while (byte < s.end) {
                    const cell = s.cellAt(byte);
                    byte = cell.end;
                    if (cell.col >= native.projection.cols) break;
                    const at: u32 = @intCast(graphemes.items.len);
                    try graphemes.appendSlice(allocator, doc.text[cell.start..cell.end]);
                    const color: vt.Color = if (metadata.kind == .shell) (if (cell.color == 0) .default else .{ .rgb = @intCast(cell.color >> 8) }) else .{ .rgb = switch (metadata.kind) {
                        .command => self.colors[0],
                        .success => self.colors[1],
                        .failure => self.colors[2],
                        else => 0x9ca3af,
                    } };
                    cells.items[start + cell.col] = .{ .grapheme_start = at, .grapheme_len = cell.end - cell.start, .width = if (cell.width == 2) .wide_lead else .single, .foreground = color, .background = if (cell.bg == 0) .default else .{ .rgb = @intCast(cell.bg >> 8) }, .attributes = @intCast(cell.flags & 3), .underline = if (cell.flags & 4 != 0) 1 else 0 };
                    if (metadata.kind == .shell) if (cell.native_cell) |style| {
                        const text_cell = cells.items[start + cell.col];
                        cells.items[start + cell.col] = style;
                        cells.items[start + cell.col].grapheme_start = text_cell.grapheme_start;
                        cells.items[start + cell.col].grapheme_len = text_cell.grapheme_len;
                        cells.items[start + cell.col].width = text_cell.width;
                    };
                    if (cell.width == 2 and cell.col + 1 < native.projection.cols) cells.items[start + cell.col + 1].width = .wide_tail;
                }
            }
        }
        const owned_cells = try cells.toOwnedSlice(allocator);
        errdefer allocator.free(owned_cells);
        const owned_graphemes = try graphemes.toOwnedSlice(allocator);
        const projection = &native.projection;
        allocator.free(projection.visible_rows);
        allocator.free(projection.cells);
        allocator.free(projection.graphemes);
        projection.visible_rows = visible;
        projection.cells = owned_cells;
        projection.graphemes = owned_graphemes;
        projection.cursor = cursor;
        projection.version = self.revision;
        projection.scrollback = .{ .total_rows = @max(doc.rows.len, self.height), .viewport_offset = self.top, .viewport_rows = self.height };
        return native;
    }
    fn find(self: *Document, anchor: terminal.Anchor) !?struct { row: usize, col: u16 } {
        if (!anchor.owner.eql(self.owner)) return error.StaleOwner;
        if (!self.enabled) {
            const position = (try self.raw.resolveAnchor(anchor)) orelse return null;
            return .{ .row = position.row, .col = position.col };
        }
        const doc = self.cached orelse return null;
        for (self.refs.items) |ref| if (ref.id == anchor.id) {
            for (doc.rows, 0..) |row, i| if (std.meta.eql(row.id, ref.row)) return .{ .row = i, .col = ref.col };
            return null;
        };
        return null;
    }
    fn createAnchor(raw: *anyopaque, binding: @TypeOf(@as(terminal.Service, undefined).binding), point: terminal.Point) !terminal.Anchor {
        const self = try checked(raw, binding);
        if (!self.enabled or self.alternate) {
            var native_point = point;
            if (self.pixel_scrolling and !self.alternate) {
                if (point.source_version) |version| if (version != self.revision) return error.StaleProjection;
                native_point.row += if (point.space == .viewport) @as(u32, @intCast(self.top)) else 0;
                native_point.space = .screen;
                native_point.source_version = self.source_version;
            }
            return self.raw.createAnchor(native_point);
        }
        const doc = self.cached orelse return error.StaleProjection;
        if (point.source_version) |version| if (version != self.revision) return error.StaleProjection;
        const index = point.row + if (point.space == .viewport) self.top else @as(usize, 0);
        if (index >= doc.rows.len) return error.InvalidPoint;
        const id = self.next_ref;
        self.next_ref += 1;
        if (self.refs.items.len >= 4096) return error.AnchorCapacity;
        try self.refs.append(self.allocator, .{ .id = id, .row = doc.rows[index].id, .col = point.col, .alternate = false });
        return .{ .owner = self.owner, .id = id };
    }
    fn resolveAnchor(raw: *anyopaque, binding: @TypeOf(@as(terminal.Service, undefined).binding), anchor: terminal.Anchor) !?terminal.AnchorPosition {
        const self = try checked(raw, binding);
        if (!self.enabled or self.alternate) {
            var position = (try self.raw.resolveAnchor(anchor)) orelse return null;
            if (self.pixel_scrolling and !self.alternate) position.source_version = if (position.source_version == self.source_version) self.revision else self.revision +| 1;
            return position;
        }
        const p = try self.find(anchor) orelse return null;
        return .{ .row = @intCast(p.row), .col = p.col, .alternate_screen = false, .source_version = self.revision };
    }
    fn releaseAnchor(raw: *anyopaque, binding: @TypeOf(@as(terminal.Service, undefined).binding), anchor: terminal.Anchor) !void {
        const self = try checked(raw, binding);
        if (!anchor.owner.eql(self.owner)) return error.StaleOwner;
        for (self.refs.items, 0..) |r, i| if (r.id == anchor.id) {
            _ = self.refs.orderedRemove(i);
            return;
        };
        return self.raw.releaseAnchor(anchor);
    }
    fn selectionText(raw: *anyopaque, binding: @TypeOf(@as(terminal.Service, undefined).binding), selected: terminal.Selection, allocator: std.mem.Allocator, limit: usize) ![]u8 {
        const self = try checked(raw, binding);
        if (!self.enabled or self.alternate) return self.raw.selectionText(selected, allocator, limit);
        var first = try self.find(selected.start) orelse return error.AnchorInvalidated;
        var last = try self.find(selected.end) orelse return error.AnchorInvalidated;
        if (first.row > last.row or first.row == last.row and first.col > last.col) std.mem.swap(@TypeOf(first), &first, &last);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        const doc = &self.cached.?;
        var index = first.row;
        while (index <= last.row) : (index += 1) {
            if (index > first.row and (selected.rectangle or !std.meta.eql(doc.rows[index].logical_id, doc.rows[index - 1].logical_id))) try out.append(allocator, '\n');
            const lo = if (selected.rectangle) @min(first.col, last.col) else if (index == first.row) first.col else 0;
            const hi = if (selected.rectangle) @max(first.col, last.col) else if (index == last.row) last.col else std.math.maxInt(u16);
            for (doc.spans[firstSpan(doc, index)..]) |s| {
                if (s.row < index) continue;
                if (s.row > index) break;
                if (s.columns(lo, hi)) |clipped| try out.appendSlice(allocator, doc.text[clipped.start..clipped.end]);
            }
            if (out.items.len > limit) return error.SelectionTooLarge;
        }
        return out.toOwnedSlice(allocator);
    }
    fn scroll(raw: *anyopaque, binding: @TypeOf(@as(terminal.Service, undefined).binding), value: terminal.Scroll) !void {
        const self = try checked(raw, binding);
        if (!self.composed() or self.alternate) return self.raw.scroll(value);
        const doc = self.cached orelse return;
        const max_top = self.maxTop(&doc);
        self.pixel_offset = 0;
        switch (value) {
            .bottom => {
                self.follow = true;
                self.top = max_top;
            },
            .top => {
                self.follow = false;
                self.top = 0;
            },
            .delta => |delta| {
                self.top = @intCast(std.math.clamp(@as(i64, @intCast(self.top)) + delta, 0, @as(i64, @intCast(max_top))));
                self.follow = self.top == max_top;
            },
            .anchor => |anchor| {
                const p = try self.find(anchor) orelse return error.AnchorInvalidated;
                self.top = @min(p.row, max_top);
                self.follow = false;
            },
        }
    }
    fn searchSnapshot(raw: *anyopaque, binding: @TypeOf(@as(terminal.Service, undefined).binding), allocator: std.mem.Allocator) !terminal.SearchSnapshot {
        const self = try checked(raw, binding);
        if (!self.composed() or self.alternate) return self.raw.searchSnapshot(allocator);
        var native = try self.raw.snapshot(self.allocator);
        defer native.deinit(self.allocator);
        try self.rebuild(&native);
        if (!self.source_complete) return if (self.search_failure) |failure| failure.err else error.WorkerBusy;
        const doc = self.cached.?;
        const text = try allocator.dupe(u8, doc.text);
        errdefer allocator.free(text);
        const rows = try allocator.dupe(search.Row, doc.rows);
        errdefer allocator.free(rows);
        return .{ .owner = self.owner, .document = .{ .source_version = self.revision, .alternate_screen = false, .text = text, .rows = rows, .spans = try allocator.dupe(search.Span, doc.spans) } };
    }
    fn readLines(raw: *anyopaque, binding: @TypeOf(@as(terminal.Service, undefined).binding), limits: terminal.LineLimits, allocator: std.mem.Allocator) !terminal.Lines {
        const self = try checked(raw, binding);
        if (!self.composed() or self.alternate) return self.raw.readLines(limits, allocator);
        var snap = try searchSnapshot(raw, binding, allocator);
        defer snap.deinit(allocator);
        var lines: std.ArrayList([]u8) = .empty;
        errdefer {
            for (lines.items) |line| allocator.free(line);
            lines.deinit(allocator);
        }
        var bytes: usize = 0;
        var iter = std.mem.splitScalar(u8, snap.document.text, '\n');
        while (iter.next()) |line| {
            if (lines.items.len >= limits.max_lines or bytes + line.len > limits.max_bytes) return .{ .lines = try lines.toOwnedSlice(allocator), .truncated = true };
            const owned = try allocator.dupe(u8, line);
            errdefer allocator.free(owned);
            try lines.append(allocator, owned);
            bytes += line.len;
        }
        return .{ .lines = try lines.toOwnedSlice(allocator), .truncated = false };
    }
    fn write(raw: *anyopaque, binding: @TypeOf(@as(terminal.Service, undefined).binding), request: terminal.WriteRequest) !terminal.Submission {
        const self = try checked(raw, binding);
        self.follow = true;
        return self.raw.write(request);
    }
    fn resize(raw: *anyopaque, binding: @TypeOf(@as(terminal.Service, undefined).binding), geometry: terminal.Geometry) !void {
        const self = try checked(raw, binding);
        return self.raw.resize(geometry);
    }
    fn read(raw: *anyopaque, binding: @TypeOf(@as(terminal.Service, undefined).binding), buffer: []u8) !terminal.Read {
        const self = try checked(raw, binding);
        return self.raw.readOutput(buffer);
    }
    fn receipt(raw: *anyopaque, binding: @TypeOf(@as(terminal.Service, undefined).binding)) !?terminal.WriteReceipt {
        const self = try checked(raw, binding);
        return self.raw.takeWriteReceipt();
    }
    fn status(raw: *anyopaque, binding: @TypeOf(@as(terminal.Service, undefined).binding)) !terminal.Status {
        const self = try checked(raw, binding);
        return self.raw.status();
    }
    fn textSlot(raw: *anyopaque, binding: @TypeOf(@as(terminal.Service, undefined).binding)) !*@import("../vt/text_slot.zig").TextSlot {
        const self = try checked(raw, binding);
        return self.raw.textSlot();
    }
    fn preparePaste(raw: *anyopaque, binding: @TypeOf(@as(terminal.Service, undefined).binding), allocator: std.mem.Allocator, text: []const u8) !terminal.Paste {
        const self = try checked(raw, binding);
        return self.raw.preparePaste(allocator, text);
    }
    fn commitPaste(raw: *anyopaque, binding: @TypeOf(@as(terminal.Service, undefined).binding), paste: terminal.Paste, sequence: u64, confirmed: bool) !terminal.Submission {
        const self = try checked(raw, binding);
        self.follow = true;
        return self.raw.commitPaste(paste, sequence, confirmed);
    }
    fn key(raw: *anyopaque, binding: @TypeOf(@as(terminal.Service, undefined).binding), request: terminal.KeyRequest) !terminal.Submission {
        const self = try checked(raw, binding);
        self.follow = true;
        return self.raw.writeKey(request);
    }
    fn mouse(raw: *anyopaque, binding: @TypeOf(@as(terminal.Service, undefined).binding), request: terminal.MouseRequest) !terminal.Submission {
        const self = try checked(raw, binding);
        return self.raw.writeMouse(request);
    }
    fn theme(raw: *anyopaque, binding: @TypeOf(@as(terminal.Service, undefined).binding), value: terminal.Theme) !void {
        const self = try checked(raw, binding);
        return self.raw.setTheme(value);
    }
    fn recordingLease(raw: *anyopaque, binding: @TypeOf(@as(terminal.Service, undefined).binding)) !@import("../vt/timeline.zig").Timeline.ExportLease {
        const self = try checked(raw, binding);
        return self.raw.recordingLease();
    }
    fn exportRecording(raw: *anyopaque, binding: @TypeOf(@as(terminal.Service, undefined).binding), kind: terminal.RecordingKind, io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
        const self = try checked(raw, binding);
        return self.raw.exportRecording(kind, io, dir, path);
    }
    fn trustedSnapshot(raw: *anyopaque, binding: @TypeOf(@as(terminal.Service, undefined).binding), allocator: std.mem.Allocator) !?terminal.trusted_edit.Snapshot {
        const self = try checked(raw, binding);
        return self.raw.trustedSnapshot(allocator);
    }
    fn trustedRequest(raw: *anyopaque, binding: @TypeOf(@as(terminal.Service, undefined).binding), request: terminal.trusted_edit.Request) !void {
        const self = try checked(raw, binding);
        return self.raw.trustedRequest(request);
    }
    fn trustedOutcome(raw: *anyopaque, binding: @TypeOf(@as(terminal.Service, undefined).binding)) !?terminal.trusted_edit.Outcome {
        const self = try checked(raw, binding);
        return self.raw.trustedOutcome();
    }
    fn trustedCancel(raw: *anyopaque, binding: @TypeOf(@as(terminal.Service, undefined).binding)) !void {
        const self = try checked(raw, binding);
        return self.raw.cancelTrustedEdit();
    }
    const vtable: terminal.Service.VTable = .{ .write = write, .resize = resize, .read = read, .receipt = receipt, .status = status, .text_slot = textSlot, .snapshot = snapshot, .prepare_paste = preparePaste, .commit_paste = commitPaste, .key = key, .mouse = mouse, .create_anchor = createAnchor, .resolve_anchor = resolveAnchor, .release_anchor = releaseAnchor, .selection_text = selectionText, .scroll = scroll, .read_lines = readLines, .theme = theme, .export_recording = exportRecording, .recording_lease = recordingLease, .trusted_snapshot = trustedSnapshot, .trusted_request = trustedRequest, .trusted_outcome = trustedOutcome, .trusted_cancel = trustedCancel, .search_snapshot = searchSnapshot };
};

test "builtin_records native rows and app rows share ordered search selection and scroll" {
    const a = std.testing.allocator;
    const Adapter = @import("../vt/ghostty_adapter.zig").Adapter;
    var adapter = try Adapter.init(a, 4, 32);
    defer adapter.destroy();
    _ = try adapter.feed("before\r\nprompt% ");
    var source: @import("terminal_document_source.zig").Source = .{ .adapter = &adapter, .owner = .{ .session_id = @fromBackingInt(5) } };
    var document = Document.init(a, source.service(), source.owner);
    defer document.deinit();
    const id = try document.begin("@ts invalid", 1234);
    try document.finish(source.owner, id, .failure, "开关只接受 on/off");
    _ = try adapter.feed("echo after\r\nafter\r\nprompt% ");
    var captured = try document.service().searchSnapshot(a);
    defer captured.deinit(a);
    const text = captured.document.text;
    const before = std.mem.indexOf(u8, text, "before").?;
    const command = std.mem.indexOf(u8, text, "@ts invalid").?;
    const after = std.mem.indexOf(u8, text, "echo after").?;
    try std.testing.expect(before < command and command < after);
    var snap = try document.service().snapshot(a);
    defer snap.deinit(a);
    const point = captured.document.point(command).?;
    const start = try document.service().createAnchor(point);
    defer document.service().releaseAnchor(start) catch {};
    var endpoint = point;
    endpoint.col += 11;
    const end = try document.service().createAnchor(endpoint);
    defer document.service().releaseAnchor(end) catch {};
    const copied = try document.service().selectionText(.{ .start = start, .end = end }, a, 1024);
    defer a.free(copied);
    try std.testing.expectEqualStrings("@ts invalid", copied);
    try document.service().scroll(.top);
    var top = try document.service().snapshot(a);
    defer top.deinit(a);
    try std.testing.expectEqual(@as(u64, 0), top.projection.scrollback.viewport_offset);
    try document.service().scroll(.{ .anchor = start });
    var located = try document.service().snapshot(a);
    defer located.deinit(a);
    try std.testing.expectEqual(captured.document.source_version, located.projection.version);
    try std.testing.expectError(error.StaleOwner, document.finish(.{ .session_id = @fromBackingInt(7) }, id, .success, "wrong owner"));
    try std.testing.expectError(error.CommandRecordExpired, document.finish(source.owner, id + 99, .success, "wrong id"));
}

test "builtin_records native clear preserves only valid tracked positions and raw bytes remain unchanged" {
    const a = std.testing.allocator;
    const Adapter = @import("../vt/ghostty_adapter.zig").Adapter;
    var adapter = try Adapter.init(a, 4, 32);
    defer adapter.destroy();
    _ = try adapter.feed("before\r\nprompt% ");
    var source: @import("terminal_document_source.zig").Source = .{ .adapter = &adapter, .owner = .{ .session_id = @fromBackingInt(5) } };
    var document = Document.init(a, source.service(), source.owner);
    defer document.deinit();
    const id = try document.begin("@help", 5);
    try document.finish(source.owner, id, .success, "supported commands");
    var raw_before = try adapter.searchSnapshot(a);
    defer raw_before.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, raw_before.text, "@help") == null);
    _ = try adapter.feed("\x1b[2J\x1b[Hnew% ");
    var snap = try document.service().snapshot(a);
    defer snap.deinit(a);
    var captured = try document.service().searchSnapshot(a);
    defer captured.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, captured.document.text, "new%") != null);
    try std.testing.expect(std.mem.indexOf(u8, captured.document.text, "supported commands") == null);
}

test "builtin_records wrapped commands copy original text and terminal results are immutable" {
    const a = std.testing.allocator;
    const Adapter = @import("../vt/ghostty_adapter.zig").Adapter;
    var adapter = try Adapter.init(a, 6, 24);
    defer adapter.destroy();
    _ = try adapter.feed("prompt% ");
    var source: @import("terminal_document_source.zig").Source = .{ .adapter = &adapter, .owner = .{ .session_id = @fromBackingInt(6) } };
    var document = Document.init(a, source.service(), source.owner);
    defer document.deinit();
    const command = "@grp a-long-production-group-name-with-many-characters-é-👩‍💻-❤️-中文";
    const id = try document.begin(command, 10);
    try document.finish(source.owner, id, .failure, "specific failure");
    try std.testing.expectError(error.CommandAlreadyCompleted, document.finish(source.owner, id, .success, "generic success"));
    try document.finish(source.owner, id, .failure, "specific failure");
    var snap = try document.service().snapshot(a);
    defer snap.deinit(a);
    var captured = try document.service().searchSnapshot(a);
    defer captured.deinit(a);
    const start_byte = std.mem.indexOf(u8, captured.document.text, command).?;
    const first = captured.document.point(start_byte).?;
    const last_span = captured.document.spanAt(start_byte + command.len - 1).?;
    var last = captured.document.point(start_byte + command.len - 1).?;
    last.col += last_span.width;
    const begin_anchor = try document.service().createAnchor(first);
    defer document.service().releaseAnchor(begin_anchor) catch {};
    const end_anchor = try document.service().createAnchor(last);
    defer document.service().releaseAnchor(end_anchor) catch {};
    const copied = try document.service().selectionText(.{ .start = begin_anchor, .end = end_anchor }, a, 1024);
    defer a.free(copied);
    try std.testing.expectEqualStrings(command, copied);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, captured.document.text, "specific failure"));
    try std.testing.expect(std.mem.indexOf(u8, captured.document.text, "generic success") == null);
}

test "builtin_records card spacing does not scroll short documents past their first command" {
    const a = std.testing.allocator;
    const Adapter = @import("../vt/ghostty_adapter.zig").Adapter;
    var adapter = try Adapter.init(a, 29, 99);
    defer adapter.destroy();
    _ = try adapter.feed("prompt% ");
    var source: @import("terminal_document_source.zig").Source = .{ .adapter = &adapter, .owner = .{ .session_id = @fromBackingInt(5) } };
    var document = Document.init(a, source.service(), source.owner);
    defer document.deinit();
    const id = try document.begin("@ts invalid", 1234);
    try document.finish(source.owner, id, .failure, "invalid switch");
    var snap = try document.service().snapshot(a);
    defer snap.deinit(a);
    try std.testing.expectEqual(@as(u64, 0), snap.projection.scrollback.viewport_offset);
    try std.testing.expectEqual(@as(u8, 1), snap.projection.visible_rows[0].application_kind);
    try std.testing.expect(snap.projection.visible_rows[0].presentation.y.? >= 22);
    try std.testing.expectEqual(@as(u8, 3), snap.projection.visible_rows[1].application_kind);
}

test "builtin_records command decoration retains exact pixels across terminal font widths" {
    const a = std.testing.allocator;
    const Adapter = @import("../vt/ghostty_adapter.zig").Adapter;
    var adapter = try Adapter.init(a, 29, 99);
    defer adapter.destroy();
    _ = try adapter.feed("prompt% ");
    var source: @import("terminal_document_source.zig").Source = .{ .adapter = &adapter, .owner = .{ .session_id = @fromBackingInt(5) } };
    var document = Document.init(a, source.service(), source.owner);
    defer document.deinit();
    const id = try document.begin("@ts invalid", 1234);
    try document.finish(source.owner, id, .failure, "invalid switch");
    for ([_]f32{ 8.4, 10, 13 }) |width| {
        _ = document.setCellWidth(width);
        var snap = try document.service().snapshot(a);
        defer snap.deinit(a);
        const row = snap.projection.visible_rows[0];
        try std.testing.expectEqual(@as(u8, 1), row.application_kind);
        const logical_inset: f32 = @floatFromInt(document.command_inset_cells);
        try std.testing.expectApproxEqAbs(record_geometry.command_inset, logical_inset * width + row.presentation.shift_x, 0.001);
        try std.testing.expectEqualStrings("@ts invalid", document.records.items[0].command);
    }
}

test "builtin_records persistence retains each original execution time after completion" {
    const a = std.testing.allocator;
    var adapter = try @import("../vt/ghostty_adapter.zig").Adapter.init(a, 6, 80);
    defer adapter.destroy();
    _ = try adapter.feed("prompt% ");
    var timeline = try @import("../vt/timeline.zig").Timeline.init(a, 16, 8192);
    defer timeline.deinit();
    var source: @import("terminal_document_source.zig").Source = .{ .adapter = &adapter, .owner = .{ .session_id = @fromBackingInt(5) }, .timeline = &timeline };
    var document = Document.init(a, source.service(), source.owner);
    defer document.deinit();
    for ([_]i64{ 1000123, 1002456 }) |at| {
        const id = try document.begin("@ts", at);
        try document.finish(source.owner, id, .success, "时间戳已切换");
        const event = timeline.events.items[timeline.events.items.len - 1];
        const recorded = try std.json.parseFromSlice(terminal.ApplicationRecord, a, event.payload, .{});
        defer recorded.deinit();
        try std.testing.expectEqual(at, recorded.value.timestamp_ms);
    }
}

test "terminal records anchor at live prompt while viewport shows history and retain offscreen timestamps" {
    const a = std.testing.allocator;
    const Adapter = @import("../vt/ghostty_adapter.zig").Adapter;
    var adapter = try Adapter.init(a, 4, 24);
    defer adapter.destroy();
    adapter.wall_clock_ms = struct {
        fn now() i64 {
            return 123456;
        }
    }.now;
    _ = try adapter.feed("old0\r\nold1\r\nold2\r\nold3\r\nold4\r\nprompt% ");
    try adapter.scroll(.top);
    var source: @import("terminal_document_source.zig").Source = .{ .adapter = &adapter, .owner = .{ .session_id = @fromBackingInt(6) } };
    var document = Document.init(a, source.service(), source.owner);
    defer document.deinit();
    const id = try document.begin("@ts", 234567);
    try document.finish(source.owner, id, .success, "enabled");
    var captured = try document.service().searchSnapshot(a);
    defer captured.deinit(a);
    const card = std.mem.indexOf(u8, captured.document.text, "@ts").?;
    try std.testing.expect(card > std.mem.indexOf(u8, captured.document.text, "old4").?);
    try std.testing.expect(card < std.mem.indexOf(u8, captured.document.text, "prompt%").?);
    for (captured.document.rows) |row| {
        if (row.application_kind == 0 and row.end > row.start)
            try std.testing.expectEqual(@as(?i64, 123456), row.timestamp_ms);
    }
}

test "terminal surface pixel scroll retains historical styles and leaves alternate input native" {
    const a = std.testing.allocator;
    var adapter = try @import("../vt/ghostty_adapter.zig").Adapter.init(a, 6, 60);
    defer adapter.destroy();
    _ = try adapter.feed("\x1b[2;9;4:2;58;2;255;0;0mHISTORY_STYLE\x1b[0m\r\n");
    for (0..30) |_| _ = try adapter.feed("ordinary output\r\n");
    var source: @import("terminal_document_source.zig").Source = .{ .adapter = &adapter, .owner = .{ .session_id = @fromBackingInt(5) } };
    var document = Document.init(a, source.service(), source.owner);
    defer document.deinit();
    try document.scrollPixels(-100000);
    var snap = try document.service().snapshot(a);
    defer snap.deinit(a);
    const cell = snap.projection.cells[0];
    try std.testing.expectEqualStrings("H", snap.projection.grapheme(cell));
    try std.testing.expect(cell.attributes & (1 << 5) != 0);
    try std.testing.expect(cell.attributes & (1 << 6) != 0);
    try std.testing.expectEqual(@as(u8, 2), cell.underline);
    try std.testing.expectEqual(@as(u24, 0xff0000), cell.underline_color.rgb);
    try document.scrollPixels(0.5);
    var partial = try document.service().snapshot(a);
    defer partial.deinit(a);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), partial.projection.visible_rows[0].presentation.y.?, 0.001);
    try std.testing.expectEqual(@as(usize, 7), partial.projection.visible_rows.len);
    _ = try adapter.feed("\x1b[?1049hALT");
    var alternate = try document.service().snapshot(a);
    defer alternate.deinit(a);
    try std.testing.expect(alternate.projection.modes.alternate_screen);
    try std.testing.expectEqual(@as(f32, 0), document.pixel_offset);
    try document.scrollPixels(-0.5);
    try std.testing.expectEqual(@as(f32, 0), document.pixel_offset);
    _ = try adapter.feed("\x1b[?1049l");
    var returned = try document.service().snapshot(a);
    defer returned.deinit(a);
    try std.testing.expect(document.follow);
    try std.testing.expect(!returned.projection.modes.alternate_screen);
}

test "terminal surface pixel scroll crosses command card gaps without quantizing their layout" {
    const a = std.testing.allocator;
    var adapter = try @import("../vt/ghostty_adapter.zig").Adapter.init(a, 4, 60);
    defer adapter.destroy();
    _ = try adapter.feed("prompt% ");
    var source: @import("terminal_document_source.zig").Source = .{ .adapter = &adapter, .owner = .{ .session_id = @fromBackingInt(5) } };
    var document = Document.init(a, source.service(), source.owner);
    defer document.deinit();
    const id = try document.begin("@example", 1234);
    try document.finish(source.owner, id, .success, "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight");
    var before = try document.service().snapshot(a);
    defer before.deinit(a);
    const previous_origin = Document.rowOrigin(&document.cached.?, document.top);
    try document.scrollPixels(-0.5);
    var after = try document.service().snapshot(a);
    defer after.deinit(a);
    const next_origin = Document.rowOrigin(&document.cached.?, document.top) + document.pixel_offset;
    try std.testing.expectApproxEqAbs(previous_origin - 0.5, next_origin, 0.001);
    for (after.projection.visible_rows) |row| {
        if (document.top + row.viewport_y >= document.cached.?.rows.len) continue;
        const original = document.cached.?.rows[document.top + row.viewport_y].presentation;
        try std.testing.expectApproxEqAbs(original.y.? - next_origin, row.presentation.y.?, 0.001);
        try std.testing.expectApproxEqAbs(original.article_y - next_origin, row.presentation.article_y, 0.001);
    }
}
