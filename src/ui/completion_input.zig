//! Match application-observed input against its echo, without parsing prompts
//! or treating terminal output as new command history.
const std = @import("std");
const vt = @import("../vt/snapshot.zig");

pub const Anchor = struct { row: vt.RowId, col: u16 };

pub fn anchor(projection: vt.Projection) ?Anchor {
    if (!atLiveEnd(projection) or !projection.cursor.visible) return null;
    for (projection.visible_rows) |row| {
        if (row.viewport_y == projection.cursor.row) return .{ .row = row.id, .col = projection.cursor.col };
    }
    return null;
}

pub fn echoed(projection: vt.Projection, start: Anchor, text: []const u8) bool {
    if (text.len == 0) return false;
    var offset: usize = 0;
    var found = false;
    for (projection.visible_rows) |row| {
        if (!found and !std.meta.eql(row.id, start.row)) continue;
        const first: usize = if (found) 0 else start.col;
        found = true;
        for (projection.cells[row.cell_start..][0..row.cell_count], 0..) |cell, col| {
            if (col < first or cell.width == .wide_tail) continue;
            const glyph = projection.grapheme(cell);
            if (glyph.len == 0 and row.wraps and col + 1 == row.cell_count) continue;
            const bytes = if (glyph.len == 0) " " else glyph;
            if (!std.mem.startsWith(u8, text[offset..], bytes)) return false;
            offset += bytes.len;
            if (offset == text.len) return true;
        }
        if (!row.wraps) return false;
    }
    return false;
}

/// Verify the known draft immediately before the live cursor. Wide cells and
/// soft wraps are compared as graphemes; no prompt syntax or DEL counts.
pub fn atCursor(projection: vt.Projection, text: []const u8) bool {
    if (text.len == 0 or !atLiveEnd(projection) or !projection.cursor.visible) return false;
    var row_index: ?usize = null;
    for (projection.visible_rows, 0..) |row, i| if (row.viewport_y == projection.cursor.row) {
        row_index = i;
        break;
    };
    var index = row_index orelse return false;
    var col: usize = projection.cursor.col;
    // An existing suffix means this is not an append-only editing position.
    const current = projection.visible_rows[index];
    if (col > current.cell_count) return false;
    if (projection.cursor.wide_tail or (col < current.cell_count and projection.cells[current.cell_start + col].width == .wide_tail)) return false;
    for (projection.cells[current.cell_start..][col..current.cell_count]) |cell| {
        const glyph = projection.grapheme(cell);
        if (glyph.len != 0 and !std.mem.eql(u8, glyph, " ")) return false;
    }
    var remaining = text.len;
    while (remaining > 0) {
        if (col == 0) {
            if (index == 0 or !projection.visible_rows[index - 1].wraps) return false;
            index -= 1;
            col = projection.visible_rows[index].cell_count;
        }
        col -= 1;
        const cell = projection.cells[projection.visible_rows[index].cell_start + col];
        if (cell.width == .wide_tail) continue;
        const glyph = projection.grapheme(cell);
        if (glyph.len == 0 and projection.visible_rows[index].wraps and col + 1 == projection.visible_rows[index].cell_count) continue;
        const bytes = if (glyph.len == 0) " " else glyph;
        if (!std.mem.endsWith(u8, text[0..remaining], bytes)) return false;
        remaining -= bytes.len;
    }
    return true;
}

/// Read only the input range whose start and pre-Tab prefix we observed.
/// After Return, require its hard line to be above the live cursor; an old
/// pre-completion draft at the cursor is not evidence of submission.
pub fn completedLine(allocator: std.mem.Allocator, projection: vt.Projection, start: Anchor, prefix: []const u8, submitted: bool) !?[]u8 {
    if (prefix.len == 0 or !atLiveEnd(projection) or !projection.cursor.visible or
        projection.modes.alternate_screen or projection.modes.application_cursor or projection.modes.mouse_tracking != .none) return null;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    var found = false;
    for (projection.visible_rows) |row| {
        if (!found and !std.meta.eql(row.id, start.row)) continue;
        const first: usize = if (found) 0 else start.col;
        found = true;
        if (row.viewport_y > projection.cursor.row or first > row.cell_count) return null;
        const at_cursor = row.viewport_y == projection.cursor.row;
        if (submitted and at_cursor) return null;
        const end: usize = if (at_cursor) projection.cursor.col else row.cell_count;
        if (end < first or end > row.cell_count) return null;
        for (projection.cells[row.cell_start..][first..end], first..) |cell, col| {
            if (cell.width == .wide_tail) continue;
            const glyph = projection.grapheme(cell);
            if (glyph.len == 0 and row.wraps and col + 1 == row.cell_count) continue;
            const bytes = if (glyph.len == 0) " " else glyph;
            if (text.items.len + bytes.len > 4096) return null;
            try text.appendSlice(allocator, bytes);
        }
        if ((!submitted and at_cursor) or (submitted and !row.wraps)) {
            if (!std.mem.startsWith(u8, text.items, prefix) or
                (!submitted and !atCursor(projection, text.items))) return null;
            const command = std.mem.trimEnd(u8, text.items, " ");
            // A completion listing can leave the original partial line above
            // the cursor. Do not mistake that unchanged prefix for the result.
            if (std.mem.eql(u8, command, std.mem.trimEnd(u8, prefix, " "))) return null;
            return try allocator.dupe(u8, if (submitted) command else text.items);
        }
        if (!row.wraps) return null;
    }
    return null;
}

fn atLiveEnd(projection: vt.Projection) bool {
    const range = projection.scrollback;
    return range.viewport_offset +| range.viewport_rows >= range.total_rows;
}
