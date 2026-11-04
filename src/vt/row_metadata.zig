//! Wall-clock decoration attached to native logical-line anchors. No bytes
//! are parsed here, and discarded metadata never becomes terminal text.
const std = @import("std");
const c = @import("generated_ghostty_vt");
const native_view = @import("ghostty_view.zig");
const model = @import("snapshot.zig");
const Entry = struct { id: u64, native: c.GhosttyTrackedGridRef, alternate: bool, ref: c.GhosttyGridRef, row: ?u32 = null, received_ms: ?i64, submitted_ms: ?i64 = null };
pub const Before = struct { native: c.GhosttyTrackedGridRef = null, alternate: bool = false, had_content: bool = false };

pub fn begin(terminal: c.GhosttyTerminal) Before {
    var x: u16 = 0;
    var y: u16 = 0;
    _ = c.ghostty_terminal_get(terminal, c.GHOSTTY_TERMINAL_DATA_CURSOR_X, @ptrCast(&x));
    _ = c.ghostty_terminal_get(terminal, c.GHOSTTY_TERMINAL_DATA_CURSOR_Y, @ptrCast(&y));
    const point: c.GhosttyPoint = .{ .tag = c.GHOSTTY_POINT_TAG_ACTIVE, .value = .{ .coordinate = .{ .x = x, .y = y } } };
    var result: Before = .{ .alternate = native_view.alternate(terminal), .had_content = x > 0 };
    _ = c.ghostty_terminal_grid_ref_track(terminal, point, &result.native);
    if (!result.had_content) {
        var ref: c.GhosttyGridRef = .{ .size = @sizeOf(c.GhosttyGridRef) };
        if (c.ghostty_terminal_grid_ref(terminal, point, &ref) == c.GHOSTTY_SUCCESS) {
            var cell: c.GhosttyCell = 0;
            if (c.ghostty_grid_ref_cell(&ref, &cell) == c.GHOSTTY_SUCCESS) _ = c.ghostty_cell_get(cell, c.GHOSTTY_CELL_DATA_HAS_TEXT, @ptrCast(&result.had_content));
        }
    }
    return result;
}

pub const Store = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    /// Entries retain cyclic age order; replacing the oldest pin is O(1).
    /// Streaming one line must not shift all 1024 retained metadata records.
    oldest: usize = 0,
    next_id: u64 = 1,
    truncated: bool = false,

    pub fn deinit(self: *Store) void {
        for (self.entries.items) |entry| c.ghostty_tracked_grid_ref_free(entry.native);
        self.entries.deinit(self.allocator);
    }
    /// Snapshot pins in O(1) each. Converting every retained pin to a SCREEN
    /// coordinate walks history pages and was paid for every incoming batch.
    /// The snapshot is only compared while the adapter guard prevents mutation.
    fn refresh(self: *Store, coordinates: bool) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const entry = &self.entries.items[i];
            if (c.ghostty_tracked_grid_ref_snapshot(entry.native, &entry.ref) != c.GHOSTTY_SUCCESS) {
                c.ghostty_tracked_grid_ref_free(entry.native);
                _ = self.entries.orderedRemove(i);
                if (i < self.oldest) self.oldest -= 1;
                if (self.oldest >= self.entries.items.len) self.oldest = 0;
                self.truncated = true;
            } else {
                entry.row = null;
                if (coordinates and entry.ref.x == 0) {
                    var point: c.GhosttyPointCoordinate = .{};
                    if (c.ghostty_tracked_grid_ref_point(entry.native, c.GHOSTTY_POINT_TAG_SCREEN, &point) == c.GHOSTTY_SUCCESS) entry.row = point.y;
                }
                i += 1;
            }
        }
    }
    fn find(self: *Store, terminal: c.GhosttyTerminal, alternate: bool, row: u32) ?*Entry {
        var ref: c.GhosttyGridRef = .{ .size = @sizeOf(c.GhosttyGridRef) };
        const point: c.GhosttyPoint = .{ .tag = c.GHOSTTY_POINT_TAG_SCREEN, .value = .{ .coordinate = .{ .x = 0, .y = row } } };
        if (c.ghostty_terminal_grid_ref(terminal, point, &ref) != c.GHOSTTY_SUCCESS) return null;
        return self.findRef(alternate, ref);
    }
    fn findRef(self: *Store, alternate: bool, ref: c.GhosttyGridRef) ?*Entry {
        for (self.entries.items) |*entry| if (entry.alternate == alternate and entry.ref.x == 0 and entry.ref.node == ref.node and entry.ref.y == ref.y) return entry;
        return null;
    }
    fn record(self: *Store, terminal: c.GhosttyTerminal, row: u32, wall_ms: i64, submission: bool) void {
        const alternate = native_view.alternate(terminal);
        // Resolve the new pin once. Looking up a SCREEN coordinate first and
        // tracking it afterwards would walk the history pages twice per line.
        var tracked: c.GhosttyTrackedGridRef = null;
        const point: c.GhosttyPoint = .{ .tag = c.GHOSTTY_POINT_TAG_SCREEN, .value = .{ .coordinate = .{ .x = 0, .y = row } } };
        if (c.ghostty_terminal_grid_ref_track(terminal, point, &tracked) != c.GHOSTTY_SUCCESS) {
            self.truncated = true;
            return;
        }
        var owned = false;
        defer if (!owned) c.ghostty_tracked_grid_ref_free(tracked);
        var ref: c.GhosttyGridRef = .{ .size = @sizeOf(c.GhosttyGridRef) };
        if (c.ghostty_tracked_grid_ref_snapshot(tracked, &ref) != c.GHOSTTY_SUCCESS) {
            self.truncated = true;
            return;
        }
        if (self.findRef(alternate, ref)) |entry| {
            if (submission and entry.submitted_ms == null) entry.submitted_ms = if (wall_ms > 0) wall_ms else null;
            return;
        }
        if (self.next_id == std.math.maxInt(u64)) {
            self.truncated = true;
            return;
        }
        const entry: Entry = .{ .id = self.next_id, .native = tracked, .alternate = alternate, .ref = ref, .received_ms = if (wall_ms > 0) wall_ms else null, .submitted_ms = if (submission and wall_ms > 0) wall_ms else null };
        if (self.entries.items.len == 1024) {
            c.ghostty_tracked_grid_ref_free(self.entries.items[self.oldest].native);
            self.entries.items[self.oldest] = entry;
            self.oldest = (self.oldest + 1) % self.entries.items.len;
            self.truncated = true;
        } else {
            self.entries.ensureUnusedCapacity(self.allocator, 1) catch {
                self.truncated = true;
                return;
            };
            if (self.oldest == 0) {
                self.entries.appendAssumeCapacity(entry);
            } else {
                // Invalidated pins may leave a partially full cyclic array.
                // Insert the newest immediately before the oldest, preserving
                // age order when that array next reaches its capacity.
                self.entries.insertAssumeCapacity(self.oldest, entry);
                self.oldest += 1;
            }
        }
        owned = true;
        self.next_id += 1;
    }
    pub fn observe(self: *Store, terminal: c.GhosttyTerminal, rows: u16, before: Before, wall_ms: i64) void {
        defer c.ghostty_tracked_grid_ref_free(before.native);
        self.refresh(false);
        var total: usize = 0;
        var x: u16 = 0;
        var y: u16 = 0;
        var at_prompt = false;
        _ = c.ghostty_terminal_get(terminal, c.GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, @ptrCast(&total));
        _ = c.ghostty_terminal_get(terminal, c.GHOSTTY_TERMINAL_DATA_CURSOR_X, @ptrCast(&x));
        _ = c.ghostty_terminal_get(terminal, c.GHOSTTY_TERMINAL_DATA_CURSOR_Y, @ptrCast(&y));
        _ = c.ghostty_terminal_get(terminal, c.GHOSTTY_TERMINAL_DATA_CURSOR_AT_PROMPT, @ptrCast(&at_prompt));
        const active_start: u32 = @intCast(total -| rows);
        const current = active_start + y;
        var prior: c.GhosttyPointCoordinate = .{};
        const prior_valid = before.alternate == native_view.alternate(terminal) and c.ghostty_tracked_grid_ref_point(before.native, c.GHOSTTY_POINT_TAG_SCREEN, &prior) == c.GHOSTTY_SUCCESS;
        var first = if (prior_valid and prior.y <= current) prior.y else active_start;
        if (current - first >= 1024) {
            first = current - 1023;
            self.truncated = true;
        }
        var row = first;
        while (row <= current) : (row += 1) {
            if ((native_view.continuation(terminal, row) catch true)) continue;
            if (row == current and x == 0 and !at_prompt) continue;
            // Never re-stamp an older line merely because its bounded metadata
            // was evicted. New rows after the prior cursor are output events.
            if (self.truncated and prior_valid and row <= prior.y and before.had_content and self.find(terminal, before.alternate, row) == null) continue;
            self.record(terminal, row, wall_ms, false);
        }
    }
    pub fn submitted(self: *Store, terminal: c.GhosttyTerminal, rows: u16, wall_ms: i64) void {
        self.refresh(false);
        var total: usize = 0;
        var y: u16 = 0;
        _ = c.ghostty_terminal_get(terminal, c.GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, @ptrCast(&total));
        _ = c.ghostty_terminal_get(terminal, c.GHOSTTY_TERMINAL_DATA_CURSOR_Y, @ptrCast(&y));
        var row: u32 = @intCast(total -| rows + y);
        var visited: usize = 0;
        while (row > 0 and (native_view.continuation(terminal, row) catch true)) : (visited += 1) {
            if (visited == 8192) {
                self.truncated = true;
                return;
            }
            row -= 1;
        }
        self.record(terminal, row, wall_ms, true);
    }
    /// Bounded, owned metadata for formatting a captured render state after the
    /// VT lock is released. Coordinates and time values belong to this capture.
    pub const SearchStamps = struct {
        const Stamp = struct { row: u32, timestamp: ?i64 };
        items: [1024]Stamp = undefined,
        len: usize = 0,
        pub fn annotate(self: *const SearchStamps, rows: []@import("search_snapshot.zig").Row) void {
            var next: usize = 0;
            var logical_id: ?model.RowId = null;
            var found: ?usize = null;
            for (rows) |*row| {
                if (logical_id == null or !std.meta.eql(logical_id.?, row.logical_id)) {
                    logical_id = row.logical_id;
                    while (next < self.len and self.items[next].row < row.screen_row) next += 1;
                    found = if (next < self.len and self.items[next].row == row.screen_row) next else null;
                }
                if (found) |n| row.timestamp_ms = self.items[n].timestamp;
            }
        }
    };
    pub fn captureSearchStamps(self: *Store, terminal: c.GhosttyTerminal) SearchStamps {
        self.refresh(true);
        const alternate = native_view.alternate(terminal);
        var result: SearchStamps = .{};
        for (self.entries.items) |entry| if (entry.alternate == alternate) {
            if (entry.row) |row| {
                result.items[result.len] = .{ .row = row, .timestamp = entry.submitted_ms orelse entry.received_ms };
                result.len += 1;
            }
        };
        std.mem.sort(SearchStamps.Stamp, result.items[0..result.len], {}, struct {
            fn less(_: void, a: SearchStamps.Stamp, b: SearchStamps.Stamp) bool {
                return a.row < b.row;
            }
        }.less);
        return result;
    }
    pub fn annotateSearch(self: *Store, terminal: c.GhosttyTerminal, rows: []@import("search_snapshot.zig").Row) void {
        self.refresh(true);
        const alternate = native_view.alternate(terminal);
        // The complete snapshot already identifies soft-wrapped logical rows.
        // Sort the bounded timestamp entries once, then merge forward instead
        // of resolving a grid reference and scanning all entries for each row.
        var order: [1024]u16 = undefined;
        var count: usize = 0;
        for (self.entries.items, 0..) |entry, i| if (entry.alternate == alternate and entry.row != null) {
            order[count] = @intCast(i);
            count += 1;
        };
        std.mem.sort(u16, order[0..count], @as([]const Entry, self.entries.items), struct {
            fn less(entries: []const Entry, a: u16, b: u16) bool {
                const ar = entries[a].row.?;
                const br = entries[b].row.?;
                return ar < br or ar == br and a < b;
            }
        }.less);
        var next: usize = 0;
        var logical_id: ?model.RowId = null;
        var found: ?u16 = null;
        for (rows) |*row| {
            if (logical_id == null or !std.meta.eql(logical_id.?, row.logical_id)) {
                logical_id = row.logical_id;
                while (next < count and self.entries.items[order[next]].row.? < row.screen_row) next += 1;
                found = if (next < count and self.entries.items[order[next]].row.? == row.screen_row) order[next] else null;
            }
            if (found) |i| row.timestamp_ms = self.entries.items[i].submitted_ms orelse self.entries.items[i].received_ms;
        }
    }

    pub fn annotate(self: *Store, terminal: c.GhosttyTerminal, rows: []model.Row, viewport_offset: u64) void {
        self.refresh(false);
        const alternate = native_view.alternate(terminal);
        var logical: ?u32 = null;
        for (rows) |*row| {
            const absolute: u32 = @intCast(viewport_offset + row.viewport_y);
            if (!row.continuation) logical = absolute else if (logical == null) {
                var first = absolute;
                var visited: usize = 0;
                while (first > 0 and (native_view.continuation(terminal, first) catch true)) : (visited += 1) {
                    if (visited == 8192) break;
                    first -= 1;
                }
                if (visited < 8192) logical = first;
            }
            if (logical) |first| if (self.find(terminal, alternate, first)) |entry| {
                row.logical_id = entry.id;
                row.received_wallclock_ms = entry.received_ms;
                row.submitted_wallclock_ms = entry.submitted_ms;
            };
        }
    }
};

test "row metadata pin keys preserve receive and submission times through reflow screen switches and reset" {
    const Fixture = struct {
        terminal: c.GhosttyTerminal = null,
        store: Store = .{ .allocator = std.testing.allocator },
        rows: u16 = 3,
        fn feed(self: *@This(), bytes: []const u8, now: i64) void {
            const before = begin(self.terminal);
            c.ghostty_terminal_vt_write(self.terminal, bytes.ptr, bytes.len);
            self.store.observe(self.terminal, self.rows, before, now);
        }
    };
    var fixture: Fixture = .{};
    try std.testing.expectEqual(c.GHOSTTY_SUCCESS, c.ghostty_terminal_new(null, &fixture.terminal, 8, fixture.rows));
    defer c.ghostty_terminal_free(fixture.terminal);
    defer fixture.store.deinit();
    fixture.feed("abcdefghij", 100);
    const original = fixture.store.find(fixture.terminal, false, 0).?.id;
    fixture.store.submitted(fixture.terminal, fixture.rows, 200);
    try std.testing.expectEqual(@as(?i64, 100), fixture.store.find(fixture.terminal, false, 0).?.received_ms);
    try std.testing.expectEqual(@as(?i64, 200), fixture.store.find(fixture.terminal, false, 0).?.submitted_ms);
    try std.testing.expectEqual(c.GHOSTTY_SUCCESS, c.ghostty_terminal_resize(fixture.terminal, 5, fixture.rows, 0, 0));
    fixture.store.refresh(false);
    try std.testing.expectEqual(original, fixture.store.find(fixture.terminal, false, 0).?.id);
    fixture.feed("\x1b[?1049halt", 300);
    const alternate = fixture.store.find(fixture.terminal, true, 0).?.id;
    try std.testing.expect(alternate != original);
    fixture.feed("\x1b[?1049l", 350);
    try std.testing.expectEqual(original, fixture.store.find(fixture.terminal, false, 0).?.id);
    try std.testing.expectEqual(@as(?i64, 100), fixture.store.find(fixture.terminal, false, 0).?.received_ms);
    fixture.feed("\x1bcnew", 400);
    const reset = fixture.store.find(fixture.terminal, false, 0).?;
    try std.testing.expect(reset.id != original);
    try std.testing.expectEqual(@as(?i64, 400), reset.received_ms);
}

test "row metadata evicts oldest entries without shifting and retains age order after invalidated pins" {
    const Fixture = struct {
        terminal: c.GhosttyTerminal = null,
        store: Store = .{ .allocator = std.testing.allocator },
        fn feed(self: *@This(), bytes: []const u8) void {
            const before = begin(self.terminal);
            c.ghostty_terminal_vt_write(self.terminal, bytes.ptr, bytes.len);
            self.store.observe(self.terminal, 24, before, 100);
        }
        fn checkOrder(self: *@This()) !void {
            try std.testing.expect(self.store.entries.items.len <= 1024);
            var previous: u64 = 0;
            for (0..self.store.entries.items.len) |offset| {
                const entry = self.store.entries.items[(self.store.oldest + offset) % self.store.entries.items.len];
                try std.testing.expect(entry.id > previous);
                try std.testing.expect(c.ghostty_tracked_grid_ref_has_value(entry.native));
                previous = entry.id;
            }
        }
    };
    var fixture: Fixture = .{};
    try std.testing.expectEqual(c.GHOSTTY_SUCCESS, c.ghostty_terminal_new(null, &fixture.terminal, 80, 24));
    defer c.ghostty_terminal_free(fixture.terminal);
    defer fixture.store.deinit();
    for (0..1100) |_| fixture.feed("line\r\n");
    try std.testing.expectEqual(@as(usize, 1024), fixture.store.entries.items.len);
    try std.testing.expect(fixture.store.oldest != 0);
    try fixture.checkOrder();
    fixture.feed("\x1b[?1049h");
    for (0..60) |_| fixture.feed("alternate\r\n");
    try fixture.checkOrder();
    fixture.feed("\x1b[?1049l");
    for (0..100) |_| fixture.feed("primary\r\n");
    try fixture.checkOrder();
    fixture.feed("\x1b[?1049h");
    for (0..60) |_| fixture.feed("replacement\r\n");
    try fixture.checkOrder();
}
