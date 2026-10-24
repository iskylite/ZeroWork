//! Native tracked references and formatter access. Serialized by Adapter's
//! existing guard; no terminal byte parser or second screen is maintained.
const std = @import("std");
const c = @import("generated_ghostty_vt");
const view = @import("viewport.zig");
const Ref = struct { id: view.AnchorId, native: c.GhosttyTrackedGridRef, after: bool, alternate: bool };

pub const Store = struct {
    allocator: std.mem.Allocator,
    refs: std.ArrayList(Ref) = .empty,
    next_id: u64 = 1,

    pub fn deinit(self: *Store) void {
        for (self.refs.items) |ref| c.ghostty_tracked_grid_ref_free(ref.native);
        self.refs.deinit(self.allocator);
    }
    pub fn create(self: *Store, terminal: c.GhosttyTerminal, cols: u16, point: view.Point) !view.AnchorId {
        if (cols == 0 or point.col > cols) return error.InvalidPoint;
        if (self.refs.items.len >= 256) return error.AnchorCapacity;
        if (self.next_id == std.math.maxInt(u64)) return error.AnchorIdentityExhausted;
        try self.refs.ensureUnusedCapacity(self.allocator, 1);
        var tracked: c.GhosttyTrackedGridRef = null;
        // A gap after text tracks that text cell, not the unproduced blank
        // after it: reflow is allowed to discard such blank positions.
        const after = point.col > 0;
        const native: c.GhosttyPoint = .{ .tag = if (point.space == .viewport) c.GHOSTTY_POINT_TAG_VIEWPORT else c.GHOSTTY_POINT_TAG_SCREEN, .value = .{ .coordinate = .{ .x = if (after) point.col - 1 else 0, .y = point.row } } };
        if (c.ghostty_terminal_grid_ref_track(terminal, native, &tracked) != c.GHOSTTY_SUCCESS) return error.InvalidPoint;
        const id = self.next_id;
        self.next_id += 1;
        self.refs.appendAssumeCapacity(.{ .id = id, .native = tracked, .after = after, .alternate = alternate(terminal) });
        return id;
    }
    fn find(self: *Store, id: view.AnchorId) ?*Ref {
        for (self.refs.items) |*ref| if (ref.id == id) return ref;
        return null;
    }
    pub fn release(self: *Store, id: view.AnchorId) !void {
        for (self.refs.items, 0..) |ref, i| if (ref.id == id) {
            c.ghostty_tracked_grid_ref_free(ref.native);
            _ = self.refs.orderedRemove(i);
            return;
        };
        return error.StaleAnchor;
    }
    pub fn resolve(self: *Store, id: view.AnchorId) !?view.AnchorPosition {
        const ref = self.find(id) orelse return error.StaleAnchor;
        var point: c.GhosttyPointCoordinate = .{};
        const result = c.ghostty_tracked_grid_ref_point(ref.native, c.GHOSTTY_POINT_TAG_SCREEN, &point);
        if (result == c.GHOSTTY_NO_VALUE) return null;
        if (result != c.GHOSTTY_SUCCESS) return error.StaleAnchor;
        return .{ .row = point.y, .col = point.x + @as(u16, @intFromBool(ref.after)), .alternate_screen = ref.alternate };
    }
    pub fn selectionText(self: *Store, terminal: c.GhosttyTerminal, cols: u16, selection: view.Selection, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
        var start = (try self.resolve(selection.start)) orelse return error.AnchorInvalidated;
        var end = (try self.resolve(selection.end)) orelse return error.AnchorInvalidated;
        if (start.alternate_screen != end.alternate_screen or start.alternate_screen != alternate(terminal)) return error.AnchorNotActive;
        if (selection.rectangle) {
            const min_col = @min(start.col, end.col);
            const max_col = @max(start.col, end.col);
            if (min_col == max_col) return allocator.alloc(u8, 0);
            const min_row = @min(start.row, end.row);
            const max_row = @max(start.row, end.row);
            return copyRectangle(terminal, min_row, max_row, min_col, @min(max_col, cols), allocator, max_bytes);
        }
        if (less(end, start)) std.mem.swap(view.AnchorPosition, &start, &end);
        if (start.row == end.row and start.col == end.col) return allocator.alloc(u8, 0);
        if (start.col >= cols) {
            start.row += 1;
            start.col = 0;
        }
        if (end.col == 0) {
            if (end.row == 0) return allocator.alloc(u8, 0);
            end.row -= 1;
            end.col = cols;
        }
        if (less(end, start) or (start.row == end.row and end.col <= start.col)) return allocator.alloc(u8, 0);
        return format(terminal, .{ .row = start.row, .col = start.col }, .{ .row = end.row, .col = @min(end.col, cols) - 1 }, false, allocator, max_bytes);
    }
    pub fn scroll(self: *Store, terminal: c.GhosttyTerminal, request: view.Scroll) !void {
        const native: c.GhosttyTerminalScrollViewport = switch (request) {
            .top => .{ .tag = c.GHOSTTY_SCROLL_VIEWPORT_TOP },
            .bottom => .{ .tag = c.GHOSTTY_SCROLL_VIEWPORT_BOTTOM },
            .delta => |value| .{ .tag = c.GHOSTTY_SCROLL_VIEWPORT_DELTA, .value = .{ .delta = value } },
            .anchor => |id| value: {
                const point = (try self.resolve(id)) orelse return error.AnchorInvalidated;
                if (point.alternate_screen != alternate(terminal)) return error.AnchorNotActive;
                break :value .{ .tag = c.GHOSTTY_SCROLL_VIEWPORT_ROW, .value = .{ .row = point.row } };
            },
        };
        c.ghostty_terminal_scroll_viewport(terminal, native);
    }
};

fn less(a: view.AnchorPosition, b: view.AnchorPosition) bool {
    return a.row < b.row or (a.row == b.row and a.col < b.col);
}

fn copyRectangle(terminal: c.GhosttyTerminal, first_row: u32, last_row: u32, first_col: u16, end_col: u16, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
    if (max_bytes == 0 or max_bytes > 1024 * 1024) return error.InvalidLimit;
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var row = first_row;
    while (row <= last_row) : (row += 1) {
        if (row > first_row) try appendBounded(&result, allocator, "\n", max_bytes);
        var col = first_col;
        while (col < end_col) : (col += 1) {
            var ref = try gridRef(terminal, .{ .space = .screen, .row = row, .col = col });
            var raw: c.GhosttyCell = 0;
            if (c.ghostty_grid_ref_cell(&ref, &raw) != c.GHOSTTY_SUCCESS) return error.SelectionUnavailable;
            var wide: c.GhosttyCellWide = c.GHOSTTY_CELL_WIDE_NARROW;
            _ = c.ghostty_cell_get(raw, c.GHOSTTY_CELL_DATA_WIDE, @ptrCast(&wide));
            if (wide == c.GHOSTTY_CELL_WIDE_SPACER_TAIL) {
                if (col > first_col) continue;
                if (col > 0) ref = try gridRef(terminal, .{ .space = .screen, .row = row, .col = col - 1 });
            }
            var needed: usize = 0;
            const query = c.ghostty_grid_ref_graphemes(&ref, null, 0, &needed);
            if (query != c.GHOSTTY_SUCCESS and query != c.GHOSTTY_OUT_OF_SPACE) return error.SelectionUnavailable;
            if (needed == 0) {
                try appendBounded(&result, allocator, " ", max_bytes);
                continue;
            }
            if (needed > max_bytes - result.items.len) return error.CopyTooLarge;
            const points = try allocator.alloc(u32, needed);
            defer allocator.free(points);
            if (c.ghostty_grid_ref_graphemes(&ref, points.ptr, points.len, &needed) != c.GHOSTTY_SUCCESS) return error.SelectionUnavailable;
            for (points[0..needed]) |point| {
                if (point > std.math.maxInt(u21)) return error.InvalidNativeText;
                var bytes: [4]u8 = undefined;
                const count = std.unicode.utf8Encode(@intCast(point), &bytes) catch return error.InvalidNativeText;
                try appendBounded(&result, allocator, bytes[0..count], max_bytes);
            }
        }
    }
    return result.toOwnedSlice(allocator);
}
fn appendBounded(result: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8, max_bytes: usize) !void {
    if (bytes.len > max_bytes - result.items.len) return error.CopyTooLarge;
    try result.appendSlice(allocator, bytes);
}
pub fn alternate(terminal: c.GhosttyTerminal) bool {
    var value: c.GhosttyTerminalScreen = c.GHOSTTY_TERMINAL_SCREEN_PRIMARY;
    _ = c.ghostty_terminal_get(terminal, c.GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, @ptrCast(&value));
    return value == c.GHOSTTY_TERMINAL_SCREEN_ALTERNATE;
}
pub fn gridRef(terminal: c.GhosttyTerminal, point: view.Point) !c.GhosttyGridRef {
    var result: c.GhosttyGridRef = .{ .size = @sizeOf(c.GhosttyGridRef) };
    const native: c.GhosttyPoint = .{ .tag = if (point.space == .viewport) c.GHOSTTY_POINT_TAG_VIEWPORT else c.GHOSTTY_POINT_TAG_SCREEN, .value = .{ .coordinate = .{ .x = point.col, .y = point.row } } };
    if (c.ghostty_terminal_grid_ref(terminal, native, &result) != c.GHOSTTY_SUCCESS) return error.InvalidPoint;
    return result;
}
pub fn continuation(terminal: c.GhosttyTerminal, row: u32) !bool {
    const ref = try gridRef(terminal, .{ .space = .screen, .row = row, .col = 0 });
    var raw: c.GhosttyRow = 0;
    if (c.ghostty_grid_ref_row(&ref, &raw) != c.GHOSTTY_SUCCESS) return error.InvalidPoint;
    var result = false;
    _ = c.ghostty_row_get(raw, c.GHOSTTY_ROW_DATA_WRAP_CONTINUATION, @ptrCast(&result));
    return result;
}
pub fn format(terminal: c.GhosttyTerminal, start: view.Point, end: view.Point, rectangle: bool, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
    if (max_bytes == 0 or max_bytes > 1024 * 1024) return error.InvalidLimit;
    var native: c.GhosttySelection = .{ .size = @sizeOf(c.GhosttySelection), .start = try gridRef(terminal, .{ .space = .screen, .row = start.row, .col = start.col }), .end = try gridRef(terminal, .{ .space = .screen, .row = end.row, .col = end.col }), .rectangle = rectangle };
    const options: c.GhosttyTerminalSelectionFormatOptions = .{ .size = @sizeOf(c.GhosttyTerminalSelectionFormatOptions), .emit = c.GHOSTTY_FORMATTER_FORMAT_PLAIN, .unwrap = !rectangle, .trim = !rectangle, .selection = &native };
    var needed: usize = 0;
    const query = c.ghostty_terminal_selection_format_buf(terminal, options, null, 0, &needed);
    if (query != c.GHOSTTY_SUCCESS and query != c.GHOSTTY_OUT_OF_SPACE) return error.SelectionUnavailable;
    if (needed > max_bytes) return error.CopyTooLarge;
    var result = try allocator.alloc(u8, needed);
    errdefer allocator.free(result);
    var written: usize = 0;
    if (c.ghostty_terminal_selection_format_buf(terminal, options, result.ptr, result.len, &written) != c.GHOSTTY_SUCCESS) return error.SelectionUnavailable;
    if (written != result.len) result = try allocator.realloc(result, written);
    return result;
}

pub fn readLines(terminal: c.GhosttyTerminal, cols: u16, limits: view.LineLimits, allocator: std.mem.Allocator) !view.Lines {
    if (limits.max_lines == 0 or limits.max_lines > 1024 or limits.max_bytes == 0 or limits.max_bytes > 1024 * 1024) return error.InvalidLimit;
    var total: usize = 0;
    _ = c.ghostty_terminal_get(terminal, c.GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, @ptrCast(&total));
    var lines: std.ArrayList([]u8) = .empty;
    errdefer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }
    var end = total;
    var used: usize = 0;
    var visited: usize = 0;
    var truncated = false;
    while (end > 0 and lines.items.len < limits.max_lines and visited < 8192) {
        var begin = end - 1;
        visited += 1;
        while (begin > 0 and try continuation(terminal, @intCast(begin))) {
            if (visited == 8192) break;
            begin -= 1;
            visited += 1;
        }
        const line = format(terminal, .{ .row = @intCast(begin), .col = 0 }, .{ .row = @intCast(end - 1), .col = cols - 1 }, false, allocator, limits.max_bytes - used) catch |err| {
            if (err != error.CopyTooLarge) return err;
            truncated = true;
            break;
        };
        end = begin;
        if (lines.items.len == 0 and line.len == 0) {
            allocator.free(line); // Unproduced trailing screen padding.
            continue;
        }
        errdefer allocator.free(line);
        try lines.append(allocator, line);
        used += line.len;
        if (used == limits.max_bytes) break;
    }
    std.mem.reverse([]u8, lines.items);
    return .{ .lines = try lines.toOwnedSlice(allocator), .truncated = truncated or end > 0 };
}
