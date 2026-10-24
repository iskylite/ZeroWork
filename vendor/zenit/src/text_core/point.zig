//! Point / PointUtf16 / OffsetUtf16
//!
//! Aligns with Zed `crates/text/src/text.rs` text coordinate types.
//!
//! `Point { row, column }` is a **byte-column** coordinate system (row = 0-based line number,
//! column = byte offset in line). `PointUtf16` / `OffsetUtf16` are UTF-16 code unit systems,
//! reserved for future LSP alignment.
//!
//! Currently only types + basic compare/add/subtract are defined; Rope.offsetToPoint/pointToOffset
//! will produce these Points.
//!
//! Note: `src/core/wrap_map.zig` has `DisplayPoint { row, column }`, a **display layer**
//! coordinate, distinct from the **buffer layer** Point here. DisplayPoint is planned to move to
//! display_map/; this type stays independent.

const std = @import("std");

/// Buffer coordinate system (row, column). column is byte column.
pub const Point = struct {
    row: u32 = 0,
    column: u32 = 0,

    pub const ZERO: Point = .{};
    pub const MAX: Point = .{ .row = std.math.maxInt(u32), .column = std.math.maxInt(u32) };

    pub fn init(row: u32, column: u32) Point {
        return .{ .row = row, .column = column };
    }

    /// Order of two Point: compare row first, column if rows equal.
    pub fn cmp(a: Point, b: Point) std.math.Order {
        if (a.row != b.row) return std.math.order(a.row, b.row);
        return std.math.order(a.column, b.column);
    }

    pub fn eql(a: Point, b: Point) bool {
        return a.row == b.row and a.column == b.column;
    }

    /// Add a Point: if other spans rows then row += other.row and column becomes other.column; else
    /// row unchanged, column += other.column. Align Zed `Point::add`.
    pub fn add(self: Point, other: Point) Point {
        if (other.row == 0) {
            return .{ .row = self.row, .column = self.column + other.column };
        }
        return .{ .row = self.row + other.row, .column = other.column };
    }

    /// Subtract two points: assume a >= b. For Summary.add inverse. Align Zed `Point::sub`: same
    /// row gives (0, a.col - b.col); else (a.row - b.row, a.col).
    pub fn sub(a: Point, b: Point) Point {
        std.debug.assert(cmp(a, b) != .lt);
        if (a.row == b.row) {
            return .{ .row = 0, .column = a.column - b.column };
        }
        return .{ .row = a.row - b.row, .column = a.column };
    }

    pub fn isZero(self: Point) bool {
        return self.row == 0 and self.column == 0;
    }
};

/// UTF-16 code unit coordinate system (row, column). Reserved for LSP alignment; Phase 0 doesn't
/// implement internals.
pub const PointUtf16 = struct {
    row: u32 = 0,
    column: u32 = 0,

    pub const ZERO: PointUtf16 = .{};

    pub fn init(row: u32, column: u32) PointUtf16 {
        return .{ .row = row, .column = column };
    }
};

/// Global UTF-16 offset (single number coordinate), align Zed `OffsetUtf16`.
pub const OffsetUtf16 = struct {
    value: u64 = 0,

    pub const ZERO: OffsetUtf16 = .{};

    pub fn cmp(a: OffsetUtf16, b: OffsetUtf16) std.math.Order {
        return std.math.order(a.value, b.value);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Point.cmp orders by row then column" {
    const a = Point.init(0, 5);
    const b = Point.init(0, 10);
    const c = Point.init(1, 0);
    try std.testing.expectEqual(std.math.Order.lt, Point.cmp(a, b));
    try std.testing.expectEqual(std.math.Order.lt, Point.cmp(b, c));
    try std.testing.expectEqual(std.math.Order.lt, Point.cmp(a, c));
    try std.testing.expectEqual(std.math.Order.eq, Point.cmp(a, a));
}

test "Point.add same line: column accumulates" {
    const base = Point.init(3, 10);
    const delta = Point.init(0, 5);
    const result = base.add(delta);
    try std.testing.expectEqual(@as(u32, 3), result.row);
    try std.testing.expectEqual(@as(u32, 15), result.column);
}

test "Point.add cross line: row advances and column resets to delta.column" {
    const base = Point.init(3, 10);
    const delta = Point.init(2, 7);
    const result = base.add(delta);
    try std.testing.expectEqual(@as(u32, 5), result.row);
    try std.testing.expectEqual(@as(u32, 7), result.column);
}

test "Point.sub reverses Point.add for same-line case" {
    const base = Point.init(3, 10);
    const delta = Point.init(0, 5);
    const combined = base.add(delta);
    const recovered = combined.sub(base);
    try std.testing.expect(recovered.eql(delta));
}

test "Point.sub cross line" {
    const a = Point.init(5, 8);
    const b = Point.init(3, 10);
    const diff = a.sub(b);
    try std.testing.expectEqual(@as(u32, 2), diff.row);
    try std.testing.expectEqual(@as(u32, 8), diff.column);
}

test "Point.isZero" {
    try std.testing.expect(Point.ZERO.isZero());
    try std.testing.expect(!Point.init(1, 0).isZero());
    try std.testing.expect(!Point.init(0, 1).isZero());
}

test "OffsetUtf16.cmp" {
    const a: OffsetUtf16 = .{ .value = 10 };
    const b: OffsetUtf16 = .{ .value = 20 };
    try std.testing.expectEqual(std.math.Order.lt, OffsetUtf16.cmp(a, b));
}
