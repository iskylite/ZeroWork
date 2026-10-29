//! Read-only bounded native formatter queries. Does not move the viewport or
//! construct a full retained-history search/render snapshot.
const std = @import("std");
const c = @import("generated_ghostty_vt");
const terminal = @import("../host/terminal_service.zig");
const view = @import("ghostty_view.zig");
const owner_type = @import("../host/identity.zig").SessionHandle;
const max_scan_rows = 8192;

pub fn capture(adapter: anytype, owner: owner_type, request: terminal.ContentRequest, allocator: std.mem.Allocator) !terminal.ContentCapture {
    if (request.expected_version) |version| if (version != adapter.version) return error.SnapshotChanged;
    if (request.max_lines == 0 or request.max_lines > 500 or request.max_bytes == 0 or request.max_bytes > 65536) return error.InvalidArguments;
    switch (request.range_kind) {
        .tail => if (request.start_line != null or request.end_line != null or request.start_ms != null or request.end_ms != null) return error.InvalidRange,
        .lines => if (request.start_line == null or request.end_line == null or request.start_line.? > request.end_line.? or request.start_ms != null or request.end_ms != null) return error.InvalidRange,
        .time => if (request.start_ms == null or request.end_ms == null or request.start_ms.? > request.end_ms.? or request.start_line != null or request.end_line != null) return error.InvalidRange,
    }
    var total: usize = 0;
    if (c.ghostty_terminal_get(adapter.terminal, c.GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, @ptrCast(&total)) != c.GHOSTTY_SUCCESS) return error.RangeUnavailable;
    if (total > max_scan_rows) return error.SearchBudgetExceeded;
    // Metadata traversal has a fixed row budget. No terminal text is copied
    // before the query's line and byte limits have been applied.
    var starts: [max_scan_rows + 1]u32 = undefined;
    var logical_count: usize = 0;
    for (0..total) |row| {
        if (row == 0 or !try view.continuation(adapter.terminal, @intCast(row))) {
            starts[logical_count] = @intCast(row);
            logical_count += 1;
        }
    }
    starts[logical_count] = @intCast(total);
    if (request.range_kind == .lines and request.start_line.? >= logical_count and logical_count != 0) return error.RangeUnavailable;
    const begin: usize = @intCast(request.after_line orelse switch (request.range_kind) {
        .tail => logical_count -| request.max_lines,
        .lines => request.start_line.?,
        .time => 0,
    });
    if (begin > logical_count) return error.CursorExpired;
    var output: std.ArrayList(terminal.ContentLine) = .empty;
    errdefer {
        for (output.items) |line| allocator.free(line.text);
        output.deinit(allocator);
    }
    var used: usize = 0;
    var next: ?u64 = null;
    var unknown_timestamps = false;
    var index = begin;
    while (index < logical_count) : (index += 1) {
        if (request.range_kind == .lines and index > request.end_line.?) break;
        const first = starts[index];
        const last = starts[index + 1] - 1;
        const timestamp = receivedTime(adapter, first);
        if (request.range_kind == .time) {
            if (timestamp) |ms| {
                if (ms < request.start_ms.? or ms > request.end_ms.?) continue;
            } else {
                unknown_timestamps = true;
                continue;
            }
        }
        if (output.items.len == request.max_lines or used == request.max_bytes) {
            next = index;
            break;
        }
        const text = view.format(adapter.terminal, .{ .space = .screen, .row = first, .col = 0 }, .{ .space = .screen, .row = last, .col = adapter.cols - 1 }, false, allocator, request.max_bytes - used) catch |err| {
            if (err != error.CopyTooLarge) return err;
            if (output.items.len == 0) return error.ResultLimit;
            next = index;
            break;
        };
        errdefer allocator.free(text);
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidTerminalText;
        try output.append(allocator, .{ .line = index, .first_row = first, .last_row = last, .received_at_ms = timestamp, .text = text });
        used += text.len;
    }
    const first_partial = total > 0 and try view.continuation(adapter.terminal, 0);
    return .{ .owner = owner, .source_revision = adapter.version, .alternate_screen = view.alternate(adapter.terminal), .total_lines = logical_count, .lines = try output.toOwnedSlice(allocator), .truncated = next != null, .next_line = next, .unknown_timestamps = unknown_timestamps, .range_incomplete = request.range_kind == .lines and request.end_line.? >= logical_count, .first_line_partial = first_partial };
}
fn receivedTime(adapter: anytype, row: u32) ?i64 {
    const alternate = view.alternate(adapter.terminal);
    for (adapter.row_metadata.entries.items) |entry| {
        if (entry.alternate != alternate) continue;
        var point: c.GhosttyPointCoordinate = .{};
        if (c.ghostty_tracked_grid_ref_point(entry.native, c.GHOSTTY_POINT_TAG_SCREEN, &point) != c.GHOSTTY_SUCCESS) continue;
        if (point.y == row) return entry.received_ms;
    }
    return null;
}
