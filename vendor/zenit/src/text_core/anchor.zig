//! Anchor - stable position marker in document editing.
//!
//! Modeled on Zed `text::Anchor`, based on the PieceTree `(source, buffer_offset)` pair:
//! - `original_buffer` and `add_buffer` are both **append-only** (insert appends,
//!   delete doesn't free)
//! - so `(source, buffer_offset)` is the **permanent coordinate** of that byte
//! - even if pieces split/replace on insert/delete, `buffer_offset` points to the same byte
//! - resolve scans the current piece list for the piece containing `(source, offset)`
//!   and computes the doc offset
//!
//! ## Bias semantics
//!
//! When the anchor sits exactly at an insert start or delete boundary, Bias decides
//! which side it sticks to:
//! `.left`: glued to the char before -> insert at anchor, anchor doesn't move
//! `.right`: glued to the char after -> insert at anchor, anchor follows right
//!
//! Typical usage: `Selection.start` uses `.right`, `Selection.end` uses `.left`.
//!
//! Delete: if the anchor falls in the deleted range, resolve backs up to range.start
//! (.left) or range.end (.right) per bias.
//!
//! Future OT semantics can extend this to `(source, buffer_offset, bias, version)`.

const std = @import("std");

/// Bias - determines anchor 'stickiness' direction at edit boundaries.
pub const Bias = enum(u8) {
    /// stick left (anchor between chars leans toward left char)
    left,
    /// stick right (anchor between chars leans toward right char)
    right,
};

/// mirror of PieceTree's source enum. values must match `piece_tree.Source` (piece_tree converts
/// via `@intFromEnum`).
pub const Source = enum(u8) {
    original = 0,
    add = 1,
};

/// Anchor kind: normal = ordinary anchor; start/end = special end anchors.
pub const Kind = enum(u8) {
    /// ordinary anchor: resolves via (source, buffer_offset)
    normal,
    /// document start: resolve always returns 0
    start_of_document,
    /// document end: resolve always returns totalLength()
    end_of_document,
};

/// Anchor - stable position marker. two special constants: `START` always points to document offset
/// 0, `END` always points to document end (totalLength)
pub const Anchor = struct {
    /// source buffer (original / add). ignored when kind != .normal.
    source: Source,
    /// byte offset in that buffer. ignored when kind != .normal.
    buffer_offset: usize,
    /// stickiness direction.
    bias: Bias,
    /// Anchor kind.
    kind: Kind,

    pub const START: Anchor = .{
        .source = .original,
        .buffer_offset = 0,
        .bias = .left,
        .kind = .start_of_document,
    };

    pub const END: Anchor = .{
        .source = .original,
        .buffer_offset = 0,
        .bias = .right,
        .kind = .end_of_document,
    };

    pub fn eql(a: Anchor, b: Anchor) bool {
        if (a.kind != b.kind) return false;
        if (a.kind != .normal) return true;
        return a.source == b.source and
            a.buffer_offset == b.buffer_offset and
            a.bias == b.bias;
    }

    /// check if anchor points to certain source's offset (ignore bias and kind)
    pub fn pointsTo(self: Anchor, source: Source, offset: usize) bool {
        if (self.kind != .normal) return false;
        return self.source == source and self.buffer_offset == offset;
    }
};

/// range segment (start + end, both anchors).
pub const AnchorRange = struct {
    start: Anchor,
    end: Anchor,

    pub fn eql(a: AnchorRange, b: AnchorRange) bool {
        return Anchor.eql(a.start, b.start) and Anchor.eql(a.end, b.end);
    }
};

// ============================================================================
// Tests (pure type tests, independent of PieceTree; resolve tests in piece_tree.zig)
// ============================================================================

const testing = std.testing;

test "Anchor.START and END are singletons" {
    try testing.expect(Anchor.eql(Anchor.START, Anchor.START));
    try testing.expect(Anchor.eql(Anchor.END, Anchor.END));
    try testing.expect(!Anchor.eql(Anchor.START, Anchor.END));
}

test "Anchor.eql ignores buffer_offset for special kinds" {
    var mutated_start = Anchor.START;
    mutated_start.buffer_offset = 999;
    try testing.expect(Anchor.eql(mutated_start, Anchor.START));
}

test "Anchor.eql compares normal anchors by source+offset+bias" {
    const a: Anchor = .{ .source = .add, .buffer_offset = 10, .bias = .left, .kind = .normal };
    const b: Anchor = .{ .source = .add, .buffer_offset = 10, .bias = .left, .kind = .normal };
    const c: Anchor = .{ .source = .add, .buffer_offset = 10, .bias = .right, .kind = .normal };
    const d: Anchor = .{ .source = .original, .buffer_offset = 10, .bias = .left, .kind = .normal };

    try testing.expect(Anchor.eql(a, b));
    try testing.expect(!Anchor.eql(a, c));
    try testing.expect(!Anchor.eql(a, d));
}

test "AnchorRange equality" {
    const r1: AnchorRange = .{ .start = Anchor.START, .end = Anchor.END };
    const r2: AnchorRange = .{ .start = Anchor.START, .end = Anchor.END };
    try testing.expect(AnchorRange.eql(r1, r2));
}

test "Anchor.pointsTo detects source + offset match" {
    const a: Anchor = .{ .source = .add, .buffer_offset = 42, .bias = .left, .kind = .normal };
    try testing.expect(a.pointsTo(.add, 42));
    try testing.expect(!a.pointsTo(.add, 43));
    try testing.expect(!a.pointsTo(.original, 42));
}

test "Anchor.pointsTo returns false for special kinds" {
    try testing.expect(!Anchor.START.pointsTo(.original, 0));
    try testing.expect(!Anchor.END.pointsTo(.original, 0));
}
