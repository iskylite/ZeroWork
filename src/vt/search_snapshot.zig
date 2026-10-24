//! Immutable text and native cell coordinates for one complete retained screen.
//! Soft wraps join the same logical line; decorations never enter this source.
const std = @import("std");
const vt = @import("snapshot.zig");
const viewport = @import("viewport.zig");

pub const Span = struct { start: u32, end: u32, row: u32, col: u16, width: u16, color: u32 = 0, bg: u32 = 0, flags: u32 = 0 };
pub const Row = struct {
    id: vt.RowId,
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
            if (byte < span.start) hi = mid else if (byte >= span.end) lo = mid + 1 else return span;
        }
        return null;
    }
    pub fn point(self: *const Document, byte: usize) ?viewport.Point {
        const span = self.spanAt(byte) orelse return null;
        return .{ .space = .screen, .row = self.rows[span.row].screen_row, .col = span.col, .source_version = self.source_version };
    }
};
