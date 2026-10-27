//! Immutable text and native cell coordinates for one complete retained screen.
//! Soft wraps join the same logical line; decorations never enter this source.
const std = @import("std");
const vt = @import("snapshot.zig");
const viewport = @import("viewport.zig");

pub const Span = struct {
    start: u32,
    end: u32,
    row: u32,
    col: u16,
    width: u16,
    color: u32 = 0,
    bg: u32 = 0,
    flags: u32 = 0,
    native_cell: ?vt.Cell = null,
    /// Printable single-byte cells with identical style. Unicode graphemes
    /// remain individual spans; byte offsets in a run map exactly to columns.
    ascii_run: bool = false,
    pub fn cellAt(self: Span, byte: u32) Span {
        if (!self.ascii_run) return self;
        var cell = self;
        cell.start = byte;
        cell.end = byte + 1;
        cell.col += @intCast(byte - self.start);
        cell.width = 1;
        return cell;
    }
    pub fn columns(self: Span, left: u16, right: u16) ?Span {
        if (!self.ascii_run) return if (self.col >= left and self.col < right) self else null;
        const lo = @max(self.col, left);
        const hi = @min(self.col + self.width, right);
        if (lo >= hi) return null;
        var clipped = self;
        clipped.start += lo - self.col;
        clipped.end = clipped.start + hi - lo;
        clipped.col = lo;
        clipped.width = hi - lo;
        return clipped;
    }
};

/// Coalesce only ASCII so every existing grapheme/width invariant survives.
pub fn appendSpan(allocator: std.mem.Allocator, spans: *std.ArrayList(Span), text: []const u8, value: Span) !void {
    var next = value;
    next.ascii_run = value.ascii_run or (value.width == 1 and value.end == value.start + 1 and text[value.start] >= 0x20 and text[value.start] < 0x7f);
    if (next.ascii_run and spans.items.len > 0) {
        const last = &spans.items[spans.items.len - 1];
        if (last.ascii_run and last.row == next.row and last.end == next.start and last.col + last.width == next.col and sameStyle(last.*, next)) {
            last.end = next.end;
            last.width += next.width;
            return;
        }
    }
    try spans.append(allocator, next);
}
fn sameStyle(a: Span, b: Span) bool {
    if (a.color != b.color or a.bg != b.bg or a.flags != b.flags) return false;
    var ac = a.native_cell;
    var bc = b.native_cell;
    if (ac) |*cell| {
        cell.grapheme_start = 0;
        cell.grapheme_len = 0;
    }
    if (bc) |*cell| {
        cell.grapheme_start = 0;
        cell.grapheme_len = 0;
    }
    return std.meta.eql(ac, bc);
}
pub const Row = struct {
    id: vt.RowId,
    presentation: @import("../ui/terminal_record_geometry.zig").Layout = .{},
    application_kind: u8 = 0,
    application_state: u8 = 0,
    timestamp_ms: ?i64 = null,
    logical_id: vt.RowId,
    screen_row: u32,
    start: u32,
    end: u32,
};
pub const Document = struct {
    source_version: u64,
    alternate_screen: bool,
    text: []u8,
    rows: []Row,
    spans: []Span,

    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.rows);
        allocator.free(self.spans);
        self.* = undefined;
    }
    pub fn spanAt(self: *const Document, byte: usize) ?Span {
        var lo: usize = 0;
        var hi = self.spans.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const span = self.spans[mid];
            if (byte < span.start) hi = mid else if (byte >= span.end) lo = mid + 1 else return span.cellAt(@intCast(byte));
        }
        return null;
    }
    pub fn point(self: *const Document, byte: usize) ?viewport.Point {
        const span = self.spanAt(byte) orelse return null;
        return .{ .space = .screen, .row = self.rows[span.row].screen_row, .col = span.col, .source_version = self.source_version };
    }
};

/// A bounded live preview uses an already-owned projection while a complete
/// retained-history capture is pending. It never traverses the VT again.
pub fn fromProjection(allocator: std.mem.Allocator, p: *const vt.Projection) !Document {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(allocator);
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(allocator);
    var logical: vt.RowId = undefined;
    for (p.visible_rows, 0..) |row, y| {
        if (y == 0 or !row.continuation) {
            logical = row.logical_start_id orelse row.id;
            if (y > 0) try text.append(allocator, '\n');
        }
        const start: u32 = @intCast(text.items.len);
        const cells = p.cells[row.cell_start..][0..row.cell_count];
        var end = cells.len;
        while (end > 0 and cells[end - 1].grapheme_len == 0 and cells[end - 1].attributes == 0 and cells[end - 1].background == .default and cells[end - 1].underline == 0) end -= 1;
        for (cells[0..end], 0..) |cell, col| {
            if (cell.width == .wide_tail) continue;
            const at: u32 = @intCast(text.items.len);
            try text.appendSlice(allocator, if (cell.grapheme_len == 0) " " else p.grapheme(cell));
            try appendSpan(allocator, &spans, text.items, .{ .start = at, .end = @intCast(text.items.len), .row = @intCast(y), .col = @intCast(col), .width = if (cell.width == .wide_lead) 2 else 1, .color = @import("projection_frame.zig").color(cell.foreground, p.colors), .bg = @import("projection_frame.zig").color(cell.background, p.colors), .flags = (cell.attributes & 3) | (if (cell.underline != 0) @as(u32, 4) else 0), .native_cell = cell });
        }
        try rows.append(allocator, .{ .id = row.id, .logical_id = logical, .screen_row = @intCast(p.scrollback.viewport_offset + row.viewport_y), .start = start, .end = @intCast(text.items.len), .timestamp_ms = row.submitted_wallclock_ms orelse row.received_wallclock_ms });
    }
    const owned_text = try text.toOwnedSlice(allocator);
    errdefer allocator.free(owned_text);
    const owned_rows = try rows.toOwnedSlice(allocator);
    errdefer allocator.free(owned_rows);
    return .{ .source_version = p.version, .alternate_screen = p.modes.alternate_screen, .text = owned_text, .rows = owned_rows, .spans = try spans.toOwnedSlice(allocator) };
}

/// Replace only a logical tail; the prefix is immutable retained history.
/// On allocation failure the caller must discard this invalidated document.
pub fn spliceTail(doc: *Document, allocator: std.mem.Allocator, start: usize, tail: *const Document) !void {
    const cut: usize = if (start == 0) 0 else doc.rows[start - 1].end;
    var first: usize = 0;
    var hi = doc.spans.len;
    while (first < hi) {
        const mid = first + (hi - first) / 2;
        if (doc.spans[mid].row < start) first = mid + 1 else hi = mid;
    }
    const separator: usize = @intFromBool(start > 0);
    const offset = cut + separator;
    doc.source_version = 0;
    doc.text = try allocator.realloc(doc.text, offset + tail.text.len);
    doc.rows = try allocator.realloc(doc.rows, start + tail.rows.len);
    doc.spans = try allocator.realloc(doc.spans, first + tail.spans.len);
    if (separator != 0) doc.text[cut] = '\n';
    @memcpy(doc.text[offset..], tail.text);
    for (tail.rows, doc.rows[start..]) |row, *out| {
        out.* = row;
        out.start += @intCast(offset);
        out.end += @intCast(offset);
    }
    for (tail.spans, doc.spans[first..]) |span, *out| {
        out.* = span;
        out.start += @intCast(offset);
        out.end += @intCast(offset);
        out.row += @intCast(start);
    }
    doc.source_version = tail.source_version;
}
