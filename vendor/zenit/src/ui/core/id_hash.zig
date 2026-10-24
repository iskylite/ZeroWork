//! Hash maps keyed by 32-bit ids (node ids, raw ElementIds).
//!
//! `std.AutoHashMap(u32, V)` hashes the key with Wyhash over its four bytes.
//! The per-frame render/sync passes look ids up several times per node
//! (scene runtime, interaction table, cache boundary set, ...), and in a Debug
//! build each Wyhash call is an un-inlined init/update/final chain with safety
//! checks. Ids need no keyed or streaming hash, only good bit
//! diffusion (std.HashMap takes the slot from the low bits and the fingerprint
//! from the top 7 bits), which the SplitMix64 finalizer gives in five
//! arithmetic ops.

const std = @import("std");

pub const U32Context = struct {
    pub fn hash(_: U32Context, key: u32) u64 {
        var x: u64 = key;
        x = (x ^ (x >> 30)) *% 0xbf58476d1ce4e5b9;
        x = (x ^ (x >> 27)) *% 0x94d049bb133111eb;
        return x ^ (x >> 31);
    }

    pub fn eql(_: U32Context, a: u32, b: u32) bool {
        return a == b;
    }
};

pub fn U32HashMap(comptime V: type) type {
    return std.HashMap(u32, V, U32Context, std.hash_map.default_max_load_percentage);
}

pub fn U32HashMapUnmanaged(comptime V: type) type {
    return std.HashMapUnmanaged(u32, V, U32Context, std.hash_map.default_max_load_percentage);
}

test "U32Context spreads sequential ids over slots and fingerprints" {
    const ctx = U32Context{};
    var low_bits = std.StaticBitSet(256).empty;
    var fingerprints = std.StaticBitSet(128).empty;
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        const h = ctx.hash(i);
        low_bits.set(@intCast(h & 0xff));
        fingerprints.set(@intCast(h >> 57));
    }
    // A bijective mixer keeps sequential ids distinct in the slot bits and
    // reaches most fingerprint values; a weak hash (identity, plain multiply)
    // fails the fingerprint half.
    try std.testing.expect(low_bits.count() > 150);
    try std.testing.expect(fingerprints.count() > 100);
}

test "U32HashMap round-trips ids including generation-tagged raw values" {
    var map = U32HashMap(u32).init(std.testing.allocator);
    defer map.deinit();
    var i: u32 = 0;
    while (i < 2000) : (i += 1) try map.put((i << 8) | 0x5a, i);
    i = 0;
    while (i < 2000) : (i += 1) try std.testing.expectEqual(@as(?u32, i), map.get((i << 8) | 0x5a));
    try std.testing.expect(map.remove((7 << 8) | 0x5a));
    try std.testing.expectEqual(@as(?u32, null), map.get((7 << 8) | 0x5a));
}
