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
