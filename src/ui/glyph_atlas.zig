const std = @import("std");

pub const Key = struct { codepoint: u21, attrs: u16 = 0, weight: u16 = 400, italic: bool = false };
pub const Entry = struct { key: Key, last_used: u64, glyph_id: u32 };

pub fn keyFromCell(cell: @import("../vt/cell.zig").Cell) Key {
    const attrs = cell.attrs;
    return .{
        .codepoint = cell.codepoint,
        .attrs = attrs,
        .weight = if ((attrs & @import("../vt/cell.zig").attrMask(.bold)) != 0) 700 else 400,
        .italic = (attrs & @import("../vt/cell.zig").attrMask(.italic)) != 0,
    };
}

pub const Atlas = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    capacity: usize,
    clock: u64 = 0,
    next_glyph: u32 = 1,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Atlas {
        if (capacity == 0) return error.InvalidCapacity;
        return .{ .allocator = allocator, .capacity = capacity };
    }
    pub fn deinit(self: *Atlas) void {
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn getOrInsert(self: *Atlas, key: Key) !u32 {
        self.clock += 1;
        for (self.entries.items) |*entry| if (std.meta.eql(entry.key, key)) {
            entry.last_used = self.clock;
            return entry.glyph_id;
        };
        if (self.entries.items.len == self.capacity) {
            var oldest: usize = 0;
            for (self.entries.items, 0..) |entry, index| {
                if (entry.last_used < self.entries.items[oldest].last_used) oldest = index;
            }
            self.entries.items[oldest] = .{ .key = key, .last_used = self.clock, .glyph_id = self.next_glyph };
        } else try self.entries.append(self.allocator, .{ .key = key, .last_used = self.clock, .glyph_id = self.next_glyph });
        const id = self.next_glyph;
        self.next_glyph += 1;
        return id;
    }
};

test "glyph key derives weight and italic from cell attrs" {
    const Cell = @import("../vt/cell.zig").Cell;
    var cell = Cell.fromCodepoint('A');
    cell.attrs = @import("../vt/cell.zig").attrMask(.bold) | @import("../vt/cell.zig").attrMask(.italic);
    const key = keyFromCell(cell);
    try std.testing.expectEqual(@as(u16, 700), key.weight);
    try std.testing.expect(key.italic);
}

test "glyph atlas reuses keys and evicts least recently used" {
    var atlas = try Atlas.init(std.testing.allocator, 2);
    defer atlas.deinit();
    const a = try atlas.getOrInsert(.{ .codepoint = 'A' });
    try std.testing.expectEqual(a, try atlas.getOrInsert(.{ .codepoint = 'A' }));
    _ = try atlas.getOrInsert(.{ .codepoint = 'B' });
    _ = try atlas.getOrInsert(.{ .codepoint = 'C' });
    try std.testing.expectEqual(@as(usize, 2), atlas.entries.items.len);
}
