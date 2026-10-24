const std = @import("std");

pub fn Cache(comptime Key: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        const Entry = struct { key: Key, generation: u32, frame: u64, permanent: bool };
        entries: [capacity]?Entry = @splat(null),
        cursor: usize = 0,

        pub fn contains(self: *const Self, key: Key, generation: u32, frame: u64) bool {
            for (self.entries) |entry| if (entry) |e| {
                if (e.generation == generation and std.meta.eql(e.key, key) and (e.permanent or e.frame == frame)) return true;
            };
            return false;
        }
        pub fn remember(self: *Self, key: Key, generation: u32, frame: u64, permanent: bool) void {
            for (&self.entries) |*entry| if (entry.*) |e| {
                if (std.meta.eql(e.key, key)) {
                    entry.* = .{ .key = key, .generation = generation, .frame = frame, .permanent = permanent };
                    return;
                }
            };
            self.entries[self.cursor] = .{ .key = key, .generation = generation, .frame = frame, .permanent = permanent };
            self.cursor = (self.cursor + 1) % capacity;
        }
        pub fn forgetFont(self: *Self, font_ptr: usize) void {
            for (&self.entries) |*entry| if (entry.*) |e| {
                if (e.key.font_ptr == font_ptr) entry.* = null;
            };
        }
    };
}

test "raster failures are bounded, transient failures retry and oversized glyphs stay negative" {
    const Key = struct { font_ptr: usize, glyph: u32 };
    var cache = Cache(Key, 4){};
    const key = Key{ .font_ptr = 1, .glyph = 42 };
    cache.remember(key, 0, 10, false);
    try std.testing.expect(cache.contains(key, 0, 10));
    try std.testing.expect(!cache.contains(key, 0, 11));
    cache.remember(key, 0, 11, true);
    try std.testing.expect(cache.contains(key, 0, 100));
    try std.testing.expect(!cache.contains(key, 1, 100));
    cache.forgetFont(1);
    try std.testing.expect(!cache.contains(key, 0, 100));
    for (0..10000) |i| cache.remember(.{ .font_ptr = 2, .glyph = @intCast(i) }, 0, 11, false);
    var occupied: usize = 0;
    for (cache.entries) |entry| if (entry != null) {
        occupied += 1;
    };
    try std.testing.expectEqual(@as(usize, 4), occupied);
}
