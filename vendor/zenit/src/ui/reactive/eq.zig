//! eqlValue: reactive equality check, replacing std.meta.eql, which is wrong for zenit:
//! - `[]const u8`: std.meta.eql compares (ptr, len), not content
//! - `f32/f64 NaN`: std.meta.eql uses ==, so NaN != NaN is always "different" -> set never consumed
//! - `0.0 == -0.0`: == is true, which is the correct result here
//!
//! Type dispatch:
//! - int / bool / enum / pointer / fn: ==
//! - float: custom (bytewise NaN equivalence)
//! - slice []T: length + elements recursive eqlValue
//! - array [N]T: elements recursive eqlValue
//! - struct (no union fields): all fields recursive eqlValue
//! - struct with union: std.meta.eql compatible path
//! - optional: null/null same; else recursive
//! - other: fallback std.meta.eql

const std = @import("std");
const testing = std.testing;

/// Key for "remember old value, compare later" scenarios. Slices record content hash not slice
/// itself: owned text (`scope.createText`) is double-buffered; next write or resize overwrites /
/// frees previous buffer, saved old slice dangles. Other types are values themselves.
pub fn EqKey(comptime T: type) type {
    return if (isSlice(T)) u64 else T;
}

pub fn eqKey(comptime T: type, v: T) EqKey(T) {
    if (comptime isSlice(T)) {
        const Child = @typeInfo(T).pointer.child;
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&v.len));
        if (@typeInfo(Child) == .int or @typeInfo(Child) == .bool or @typeInfo(Child) == .@"enum") {
            h.update(std.mem.sliceAsBytes(v));
        } else {
            // Non-scalar elements: hash each element bytewise by value (pointers by address).
            for (v) |*e| h.update(std.mem.asBytes(e));
        }
        return h.final();
    }
    return v;
}

fn isSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .slice,
        else => false,
    };
}

pub fn eqlValue(comptime T: type, a: T, b: T) bool {
    const info = @typeInfo(T);
    return switch (info) {
        .bool, .int, .@"enum", .error_set, .void, .null, .undefined, .noreturn => a == b,
        .comptime_int, .comptime_float => a == b,
        .float => eqlFloat(T, a, b),
        .pointer => |p| switch (p.size) {
            .slice => eqlSlice(p.child, a, b),
            else => a == b, // single pointer / many / c: identity comparison
        },
        .array => |arr| eqlArray(arr.child, arr.len, a, b),
        .vector => |v| eqlArray(v.child, v.len, @as([v.len]v.child, a), @as([v.len]v.child, b)),
        .optional => |o| blk: {
            if (a == null and b == null) break :blk true;
            if (a == null or b == null) break :blk false;
            break :blk eqlValue(o.child, a.?, b.?);
        },
        .@"struct" => eqlStruct(T, a, b),
        .@"union" => |u| if (u.tag_type) |_| std.meta.eql(a, b) else false,
        else => std.meta.eql(a, b),
    };
}

fn eqlFloat(comptime T: type, a: T, b: T) bool {
    // NaN: bytewise same treated as equal (avoid NaN always dirty infinite loop)
    // -0.0 vs +0.0: treat as equal (== also treats as equal, matches expectation)
    if (std.math.isNan(a) and std.math.isNan(b)) return true;
    return a == b;
}

fn eqlSlice(comptime Child: type, a: anytype, b: anytype) bool {
    if (a.len != b.len) return false;
    if (a.ptr == b.ptr) return true; // alias fast path
    if (Child == u8) {
        return std.mem.eql(u8, a, b);
    }
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (!eqlValue(Child, a[i], b[i])) return false;
    }
    return true;
}

fn eqlArray(comptime Child: type, comptime len: usize, a: anytype, b: anytype) bool {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (!eqlValue(Child, a[i], b[i])) return false;
    }
    return true;
}

fn eqlStruct(comptime T: type, a: T, b: T) bool {
    inline for (@import("zenit_reflection").fields(T)) |f| {
        if (!eqlValue(f.type, @field(a, f.name), @field(b, f.name))) return false;
    }
    return true;
}

// ============================================================================
// Tests
// ============================================================================

test "eqlValue: integers" {
    try testing.expect(eqlValue(i32, 42, 42));
    try testing.expect(!eqlValue(i32, 42, 43));
    try testing.expect(eqlValue(u64, 0, 0));
}

test "eqlValue: bool" {
    try testing.expect(eqlValue(bool, true, true));
    try testing.expect(!eqlValue(bool, true, false));
}

test "eqlValue: float NaN bytewise equal (avoid renotify storm)" {
    const nan = std.math.nan(f32);
    try testing.expect(eqlValue(f32, nan, nan));
}

test "eqlValue: float 0.0 == -0.0 (silently equal, matches IEEE ==)" {
    try testing.expect(eqlValue(f32, 0.0, -0.0));
    try testing.expect(eqlValue(f64, 0.0, -0.0));
}

test "eqlValue: float regular equality" {
    try testing.expect(eqlValue(f32, 1.5, 1.5));
    try testing.expect(!eqlValue(f32, 1.5, 1.6));
}

test "eqlValue: []const u8 compares content not ptr" {
    var buf1: [5]u8 = .{ 'h', 'e', 'l', 'l', 'o' };
    var buf2: [5]u8 = .{ 'h', 'e', 'l', 'l', 'o' };
    const a: []const u8 = &buf1;
    const b: []const u8 = &buf2;
    try testing.expect(a.ptr != b.ptr);
    try testing.expect(eqlValue([]const u8, a, b)); // critical fix
}

test "eqlValue: []const u8 different content" {
    try testing.expect(!eqlValue([]const u8, "hello", "world"));
    try testing.expect(!eqlValue([]const u8, "abc", "abcd"));
}

test "eqlValue: optional" {
    const a: ?i32 = 42;
    const b: ?i32 = 42;
    const c: ?i32 = null;
    const d: ?i32 = null;
    try testing.expect(eqlValue(?i32, a, b));
    try testing.expect(eqlValue(?i32, c, d));
    try testing.expect(!eqlValue(?i32, a, c));
}

test "eqlValue: arrays" {
    const a: [3]i32 = .{ 1, 2, 3 };
    const b: [3]i32 = .{ 1, 2, 3 };
    const c: [3]i32 = .{ 1, 2, 4 };
    try testing.expect(eqlValue([3]i32, a, b));
    try testing.expect(!eqlValue([3]i32, a, c));
}

test "eqlValue: struct field-wise" {
    const S = struct { a: i32, b: f32, c: bool };
    try testing.expect(eqlValue(S, .{ .a = 1, .b = 2.0, .c = true }, .{ .a = 1, .b = 2.0, .c = true }));
    try testing.expect(!eqlValue(S, .{ .a = 1, .b = 2.0, .c = true }, .{ .a = 2, .b = 2.0, .c = true }));
}

test "eqlValue: nested struct with []const u8" {
    const Inner = struct { name: []const u8 };
    const Outer = struct { id: u32, inner: Inner };
    var n1: [4]u8 = .{ 'a', 'b', 'c', 'd' };
    var n2: [4]u8 = .{ 'a', 'b', 'c', 'd' };
    const a = Outer{ .id = 1, .inner = .{ .name = &n1 } };
    const b = Outer{ .id = 1, .inner = .{ .name = &n2 } };
    try testing.expect(n1[0..].ptr != n2[0..].ptr);
    try testing.expect(eqlValue(Outer, a, b));
}

test "eqlValue: enum" {
    const E = enum { a, b, c };
    try testing.expect(eqlValue(E, .a, .a));
    try testing.expect(!eqlValue(E, .a, .b));
}

test "eqlValue: alias slice fast path" {
    const buf = "hello";
    const a: []const u8 = buf;
    const b: []const u8 = buf;
    try testing.expect(a.ptr == b.ptr);
    try testing.expect(eqlValue([]const u8, a, b));
}
