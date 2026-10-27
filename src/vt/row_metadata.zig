//! Wall-clock decoration attached to native logical-line anchors. No bytes
//! are parsed here, and discarded metadata never becomes terminal text.
const std = @import("std");
const c = @import("generated_ghostty_vt");
const native_view = @import("ghostty_view.zig");
const model = @import("snapshot.zig");
const Entry = struct { id: u64, native: c.GhosttyTrackedGridRef, alternate: bool, row: ?u32, received_ms: ?i64, submitted_ms: ?i64 = null };
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
    next_id: u64 = 1,
    truncated: bool = false,

    pub fn deinit(self: *Store) void {
        for (self.entries.items) |entry| c.ghostty_tracked_grid_ref_free(entry.native);
        self.entries.deinit(self.allocator);
    }
    fn refresh(self: *Store) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            var point: c.GhosttyPointCoordinate = .{};
            const entry = &self.entries.items[i];
            if (c.ghostty_tracked_grid_ref_point(entry.native, c.GHOSTTY_POINT_TAG_SCREEN, &point) != c.GHOSTTY_SUCCESS) {
                c.ghostty_tracked_grid_ref_free(entry.native);
                _ = self.entries.orderedRemove(i);
                self.truncated = true;
            } else {
                entry.row = if (point.x == 0) point.y else null;
                i += 1;
            }
        }
    }
    fn find(self: *Store, alternate: bool, row: u32) ?*Entry {
        for (self.entries.items) |*entry| if (entry.alternate == alternate and entry.row != null and entry.row.? == row) return entry;
        return null;
    }
    fn record(self: *Store, terminal: c.GhosttyTerminal, row: u32, wall_ms: i64, submission: bool) void {
        const alternate = native_view.alternate(terminal);
        if (self.find(alternate, row)) |entry| {
            if (submission and entry.submitted_ms == null) entry.submitted_ms = if (wall_ms > 0) wall_ms else null;
            return;
        }
        if (self.next_id == std.math.maxInt(u64)) {
            self.truncated = true;
            return;
        }
        if (self.entries.items.len == 1024) {
            c.ghostty_tracked_grid_ref_free(self.entries.orderedRemove(0).native);
            self.truncated = true;
        }
        self.entries.ensureUnusedCapacity(self.allocator, 1) catch {
            self.truncated = true;
            return;
        };
        var tracked: c.GhosttyTrackedGridRef = null;
        const point: c.GhosttyPoint = .{ .tag = c.GHOSTTY_POINT_TAG_SCREEN, .value = .{ .coordinate = .{ .x = 0, .y = row } } };
        if (c.ghostty_terminal_grid_ref_track(terminal, point, &tracked) != c.GHOSTTY_SUCCESS) {
            self.truncated = true;
            return;
        }
        self.entries.appendAssumeCapacity(.{ .id = self.next_id, .native = tracked, .alternate = alternate, .row = row, .received_ms = if (wall_ms > 0) wall_ms else null, .submitted_ms = if (submission and wall_ms > 0) wall_ms else null });
        self.next_id += 1;
    }
    pub fn observe(self: *Store, terminal: c.GhosttyTerminal, rows: u16, before: Before, wall_ms: i64) void {
        defer c.ghostty_tracked_grid_ref_free(before.native);
        self.refresh();
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
            if (self.truncated and prior_valid and row <= prior.y and before.had_content and self.find(before.alternate, row) == null) continue;
            self.record(terminal, row, wall_ms, false);
        }
    }
    pub fn submitted(self: *Store, terminal: c.GhosttyTerminal, rows: u16, wall_ms: i64) void {
        self.refresh();
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
    pub fn annotateSearch(self: *Store, terminal: c.GhosttyTerminal, rows: []@import("search_snapshot.zig").Row) void {
        self.refresh();
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
        self.refresh();
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
            if (logical) |first| if (self.find(alternate, first)) |entry| {
                row.logical_id = entry.id;
                row.received_wallclock_ms = entry.received_ms;
                row.submitted_wallclock_ms = entry.submitted_ms;
            };
        }
    }
};
