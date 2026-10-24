//! Dim trait / unified SumTree seek dimension entry
//!
//! Aligns with Zed crates/sum_tree/src/sum_tree.rs:95-110 trait Dimension<'a, S: Summary>.
//!
//! SumTree Cursor must seek by different dimensions:
//!   - ByteDim / ByteOffset: by byte offset
//!   - LineDim / Row: by line number
//!   - PointDim: by (row, column)
//!   - CharDim: by character count
//!   - OffsetUtf16: by UTF-16 code unit
//!
//! Each dimension implements "extract value from Summary + add two values" contract.
//! This file defines the contract + stubs; concrete dimensions are in src/core/rope/summary.zig.
//!
//! Zig lacks Rust traits; uses **structured duck typing**: each Dim type must satisfy
//!
//!   ```zig
//!   pub const Self = @This();
//!   pub const ZERO: Self;                      // zero value for this dimension
//!   pub fn fromSummary(s: Summary) Self;       // project Summary to dimension value
//!   pub fn addAssign(self: *Self, other: Self) void;  // accumulate (monoid add)
//!   pub fn cmp(a: Self, b: Self) std.math.Order;      // total order (for seek)
//!   ```
//!
//! SumTree.Cursor(Dim, OtherDim) enforces this via @hasDecl(Dim, ...).
//!
//! This file provides:
//!   - isValidDim(comptime Dim, comptime Summary) compile-time validation helper
//!   - Unit empty dimension as placeholder (Cursor second dimension optional)

const std = @import("std");

/// No-op dimension. Used as placeholder for "don't track second dimension" in `Cursor(Dim, Unit)`.
/// All methods are no-op.
pub const Unit = struct {
    pub const ZERO: Unit = .{};

    pub fn fromSummary(s: anytype) Unit {
        _ = s;
        return .{};
    }

    pub fn addAssign(self: *Unit, other: Unit) void {
        _ = self;
        _ = other;
    }

    pub fn cmp(a: Unit, b: Unit) std.math.Order {
        _ = a;
        _ = b;
        return .eq;
    }
};

/// Compile-time contract check: Dim must satisfy Dimension<Summary> four methods.
///
/// Usage:
/// ```zig
/// comptime isValidDim(ByteOffset, TextSummary);  // compile error if methods missing
/// ```
pub fn isValidDim(comptime Dim: type, comptime Summary: type) void {
    if (!@hasDecl(Dim, "ZERO")) @compileError(@typeName(Dim) ++ " missing ZERO constant");
    if (!@hasDecl(Dim, "fromSummary")) @compileError(@typeName(Dim) ++ " missing fromSummary(Summary) " ++ @typeName(Dim));
    if (!@hasDecl(Dim, "addAssign")) @compileError(@typeName(Dim) ++ " missing addAssign(*Self, Self) void");
    if (!@hasDecl(Dim, "cmp")) @compileError(@typeName(Dim) ++ " missing cmp(Self, Self) Order");
    _ = Summary; // Placeholder; Phase 2 adds signature detail validation.
}

// ============================================================================
// Tests
// ============================================================================

test "Unit is a valid Dim for any Summary" {
    comptime isValidDim(Unit, struct {});
    var u: Unit = Unit.ZERO;
    u.addAssign(.{});
    try std.testing.expectEqual(std.math.Order.eq, Unit.cmp(.{}, .{}));
}

// Minimal Dim example: u64 byte offset dimension, bound to any Summary with `len: u64` field.
const DummySummary = struct {
    len: u64 = 0,
    pub const ZERO: DummySummary = .{};
    pub fn add(self: DummySummary, other: DummySummary) DummySummary {
        return .{ .len = self.len + other.len };
    }
};

const DummyByteDim = struct {
    value: u64 = 0,
    pub const ZERO: DummyByteDim = .{};
    pub fn fromSummary(s: DummySummary) DummyByteDim {
        return .{ .value = s.len };
    }
    pub fn addAssign(self: *DummyByteDim, other: DummyByteDim) void {
        self.value += other.value;
    }
    pub fn cmp(a: DummyByteDim, b: DummyByteDim) std.math.Order {
        return std.math.order(a.value, b.value);
    }
};

test "custom Dim passes isValidDim" {
    comptime isValidDim(DummyByteDim, DummySummary);
    var dim: DummyByteDim = DummyByteDim.ZERO;
    dim.addAssign(DummyByteDim.fromSummary(.{ .len = 10 }));
    dim.addAssign(DummyByteDim.fromSummary(.{ .len = 5 }));
    try std.testing.expectEqual(@as(u64, 15), dim.value);
}
