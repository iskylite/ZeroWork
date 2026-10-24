//! Unclipped(T)
//!
//! Aligns with Zed `crates/text/src/text.rs` `Unclipped<T>` wrapper.
//! Marks "coords that can temporarily be out-of-bounds", used by Anchor etc.
//!
//! Motivation: an Anchor's offset may temporarily point to a nonexistent location
//! (e.g., an edit removes tail text but the Anchor still carries the old offset).
//! Unclipped is an explicit marker telling the reader the value may be out-of-bounds and
//! must be resolved before use.
//!
//! Pure type tag, zero runtime cost.

const std = @import("std");

/// `Unclipped(T)` = "carries possibly out-of-bounds T".
pub fn Unclipped(comptime T: type) type {
    return struct {
        const Self = @This();

        value: T,

        pub fn wrap(v: T) Self {
            return .{ .value = v };
        }

        pub fn unwrap(self: Self) T {
            return self.value;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Unclipped wraps and unwraps any type" {
    const U = Unclipped(u64);
    const u = U.wrap(42);
    try std.testing.expectEqual(@as(u64, 42), u.unwrap());
}

test "Unclipped is distinct from inner type at comptime" {
    const UInt = Unclipped(u32);
    const UStr = Unclipped([]const u8);
    // Pure type check: two instantiated types differ
    try std.testing.expect(@TypeOf(UInt.wrap(1)) != @TypeOf(UStr.wrap("x")));
}
