//! LocalClock / Global / EditTimestamp
//!
//! Aligns with Zed `crates/clock/src/clock.rs` `Lamport` + `Global` concepts. Non-CRDT scenarios
//! only need one strictly monotonic tick as version key.
//!
//! Invariants:
//!   - `tick` strictly monotonic
//!   - all snapshots carry their own tick
//!   - all 'edits_since(version)' queries use tick as baseline
//!
//! Zed reference:
//!   - `crates/text/src/text.rs:829-831` `Buffer::version()` returns `clock::Global`
//!   - `crates/language/src/syntax_map.rs:329-446` `SyntaxSnapshot::interpolate` based on
//!     `text.anchored_edits_since(interpolated_version)` query

const std = @import("std");

/// Monotonically-increasing local logical clock.
///
/// Each edit calls `next()` to get a new tick, used as `EditTimestamp`. `observe(other)` makes
/// local clock catch up past some external tick (for snapshot restore, merge background parse
/// result etc.).
pub const LocalClock = struct {
    tick: u64 = 0,

    /// Produce next tick strictly greater than current.
    pub fn next(self: *LocalClock) u64 {
        self.tick += 1;
        return self.tick;
    }

    /// Let local tick at least catch up to `other` (if larger).
    pub fn observe(self: *LocalClock, other: u64) void {
        if (other > self.tick) self.tick = other;
    }

    /// Compare order of two versions.
    pub fn cmp(a: LocalClock, b: LocalClock) std.math.Order {
        return std.math.order(a.tick, b.tick);
    }

    /// Return snapshot of current tick value (for read-only comparison).
    pub fn value(self: LocalClock) u64 {
        return self.tick;
    }
};

/// Zed's `clock::Global` is Lamport vector clock; single-machine scenario it's just `LocalClock`.
/// Keep `Global` name so `Buffer`/`BufferSnapshot`/`SyntaxSnapshot` etc. downstream use unified
/// signature.
pub const Global = LocalClock;

/// Timestamp of single edit. Align with Zed `clock::Lamport`, but non-CRDT scenario just u64.
pub const EditTimestamp = u64;

// ============================================================================
// Tests
// ============================================================================

test "LocalClock.next is strictly monotonic" {
    var clock: LocalClock = .{};
    const a = clock.next();
    const b = clock.next();
    const c = clock.next();
    try std.testing.expect(a < b);
    try std.testing.expect(b < c);
    try std.testing.expectEqual(@as(u64, 1), a);
    try std.testing.expectEqual(@as(u64, 2), b);
    try std.testing.expectEqual(@as(u64, 3), c);
}

test "LocalClock.observe pulls tick forward but never backward" {
    var clock: LocalClock = .{ .tick = 5 };
    clock.observe(3);
    try std.testing.expectEqual(@as(u64, 5), clock.tick);
    clock.observe(10);
    try std.testing.expectEqual(@as(u64, 10), clock.tick);
    clock.observe(10);
    try std.testing.expectEqual(@as(u64, 10), clock.tick);
}

test "LocalClock.cmp orders by tick" {
    const a: LocalClock = .{ .tick = 3 };
    const b: LocalClock = .{ .tick = 5 };
    try std.testing.expectEqual(std.math.Order.lt, LocalClock.cmp(a, b));
    try std.testing.expectEqual(std.math.Order.gt, LocalClock.cmp(b, a));
    try std.testing.expectEqual(std.math.Order.eq, LocalClock.cmp(a, a));
}

test "Global alias behaves like LocalClock" {
    var global: Global = .{};
    const t1 = global.next();
    const t2 = global.next();
    try std.testing.expect(t2 > t1);
}
