const std = @import("std");

/// Compact terminal cell. The documented semantic fields total 119 bits;
/// nine reserved bits complete the explicit 128-bit storage contract.
pub const Cell = packed struct(u128) {
    codepoint: u21 = ' ',
    width: Width = .single,
    fg: u32 = 0xffffffff,
    bg: u32 = 0x000000ff,
    attrs: u16 = 0,
    grapheme_link: u16 = 0,
    reserved: u9 = 0,

    pub fn blank() Cell {
        return .{};
    }

    pub fn fromCodepoint(codepoint: u21) Cell {
        return .{ .codepoint = codepoint };
    }
};

pub const Width = enum(u2) {
    single = 0,
    wide_lead = 1,
    wide_tail = 2,
    reserved = 3,
};

comptime {
    std.debug.assert(@bitSizeOf(Cell) == 128);
    std.debug.assert(@sizeOf(Cell) == 16);
    std.debug.assert(@bitOffsetOf(Cell, "codepoint") == 0);
    std.debug.assert(@bitOffsetOf(Cell, "width") == 21);
    std.debug.assert(@bitOffsetOf(Cell, "fg") == 23);
    std.debug.assert(@bitOffsetOf(Cell, "bg") == 55);
    std.debug.assert(@bitOffsetOf(Cell, "attrs") == 87);
    std.debug.assert(@bitOffsetOf(Cell, "grapheme_link") == 103);
    std.debug.assert(@bitOffsetOf(Cell, "reserved") == 119);
}

pub const Attr = enum(u4) {
    bold,
    italic,
    underline,
    blink,
    inverse,
    strike,
    dim,
    hidden,
};

pub fn attrMask(attr: Attr) u16 {
    return @as(u16, 1) << @intFromEnum(attr);
}

test "cell has exact stable sixteen byte layout" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Cell));
    try std.testing.expectEqual(@as(usize, 16), @alignOf(Cell));
    try std.testing.expectEqual(@as(u21, 'A'), Cell.fromCodepoint('A').codepoint);
}

test "attributes use independent mask bits" {
    try std.testing.expect(attrMask(.bold) & attrMask(.dim) == 0);
}
