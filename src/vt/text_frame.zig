const std = @import("std");

/// Wire format for one published terminal frame (version 2):
///
///   [0..2]   u16 little-endian  cursor.row (clamped)
///   [2..4]   u16 little-endian  cursor.col
///   [4..6]   u16 little-endian  grid cols
///   [6..8]   u16 little-endian  grid rows
///   [8]      flags: bit0 = cursor visible
///   [9]      format version (2); older/unknown versions fail decode
///   [10..12] u16 little-endian  span_count
///   [12..16] u32 little-endian  text_len
///   [16..16+20*span_count]  span table (20 bytes per span)
///   [..]     UTF-8 projected viewport text (row-per-line, exactly `rows` lines)
///
/// Span entry (extern, 4-byte aligned):
///   start u32, end u32     — byte offsets into the text
///   color u32, bg u32      — 0xRRGGBBAA, 0 = inherit base style
///   flags u32              — bit0 bold, bit1 italic, bit2 underline
///
/// The cursor is part of the frame payload (not the text) so the UI can blink
/// and reposition it without republishing terminal text, and the trailing
/// block cursor hack (append `█` to the text) disappears.
pub const header_bytes: usize = 16;
pub const span_wire_bytes: usize = 20;
pub const frame_version: u8 = 2;

pub const Cursor = struct { row: u32 = 0, col: u16 = 0, visible: bool = true };

pub const WireSpan = extern struct {
    start: u32,
    end: u32,
    color: u32,
    bg: u32,
    flags: u32,

    pub fn bold(self: WireSpan) bool {
        return self.flags & 1 != 0;
    }
    pub fn italic(self: WireSpan) bool {
        return self.flags & 2 != 0;
    }
    pub fn underline(self: WireSpan) bool {
        return self.flags & 4 != 0;
    }
};

/// Span flags from styled-projection attributes.
pub fn spanFlags(bold: bool, italic: bool, underline: bool) u32 {
    return @as(u32, @intFromBool(bold)) | (@as(u32, @intFromBool(italic)) << 1) | (@as(u32, @intFromBool(underline)) << 2);
}

pub const Frame = struct {
    cursor: Cursor,
    cols: u16,
    rows: u16,
    text: []const u8,
    spans: []const WireSpan,
};

pub fn encodeHeader(
    dst: *[header_bytes]u8,
    cursor: Cursor,
    cols: u16,
    rows: u16,
    span_count: usize,
    text_len: usize,
) void {
    std.mem.writeInt(u16, dst[0..2], @intCast(@min(cursor.row, std.math.maxInt(u16))), .little);
    std.mem.writeInt(u16, dst[2..4], cursor.col, .little);
    std.mem.writeInt(u16, dst[4..6], cols, .little);
    std.mem.writeInt(u16, dst[6..8], rows, .little);
    dst[8] = if (cursor.visible) 1 else 0;
    dst[9] = frame_version;
    std.mem.writeInt(u16, dst[10..12], @intCast(@min(span_count, std.math.maxInt(u16))), .little);
    std.mem.writeInt(u32, dst[12..16], @intCast(text_len), .little);
}

/// Serializes styled-projection spans into wire bytes (dst.len must be
/// span_count * span_wire_bytes).
pub fn encodeSpans(dst: []u8, spans: []const @import("text_projection_styled.zig").Span) void {
    for (spans, 0..) |span, index| {
        const entry: usize = index * span_wire_bytes;
        std.mem.writeInt(u32, dst[entry..][0..4], span.start, .little);
        std.mem.writeInt(u32, dst[entry + 4 ..][0..4], span.end, .little);
        std.mem.writeInt(u32, dst[entry + 8 ..][0..4], span.color, .little);
        std.mem.writeInt(u32, dst[entry + 12 ..][0..4], span.bg, .little);
        std.mem.writeInt(u32, dst[entry + 16 ..][0..4], spanFlags(span.bold, span.italic, span.underline), .little);
    }
}

/// Decodes a frame payload produced by encodeHeader + span table + text copy.
/// Returns null when the payload is smaller than the header, the version is
/// unknown, or the lengths are inconsistent.
pub fn decode(src: []const u8) ?Frame {
    if (src.len < header_bytes) return null;
    if (src[9] != frame_version) return null;
    const span_count = std.mem.readInt(u16, src[10..12], .little);
    const text_len = std.mem.readInt(u32, src[12..16], .little);
    const spans_bytes = @as(usize, span_count) * span_wire_bytes;
    if (src.len < header_bytes + spans_bytes + text_len) return null;
    const spans: []const WireSpan = if (span_count == 0) &.{} else blk: {
        const ptr: [*]const WireSpan = @ptrCast(@alignCast(src.ptr + header_bytes));
        break :blk ptr[0..span_count];
    };
    const text_start = header_bytes + spans_bytes;
    return .{
        .cursor = .{
            .row = std.mem.readInt(u16, src[0..2], .little),
            .col = std.mem.readInt(u16, src[2..4], .little),
            .visible = src[8] & 1 != 0,
        },
        .cols = std.mem.readInt(u16, src[4..6], .little),
        .rows = std.mem.readInt(u16, src[6..8], .little),
        .text = src[text_start..][0..text_len],
        .spans = spans,
    };
}

test "text frame round-trips cursor metadata, text and spans" {
    var buffer: [header_bytes + span_wire_bytes + 8]u8 = undefined;
    const cursor: Cursor = .{ .row = 3, .col = 7, .visible = false };
    encodeHeader(buffer[0..header_bytes], cursor, 100, 40, 1, 6);
    var span: @import("text_projection_styled.zig").Span = .{ .start = 1, .end = 3, .color = 0xFF0000FF, .bg = 0x11223344 };
    span.bold = true;
    encodeSpans(buffer[header_bytes .. header_bytes + span_wire_bytes], &.{span});
    const text = "hello!";
    @memcpy(buffer[header_bytes + span_wire_bytes .. header_bytes + span_wire_bytes + text.len], text);
    const frame = decode(&buffer).?;
    try std.testing.expectEqual(@as(u32, 3), frame.cursor.row);
    try std.testing.expectEqual(@as(u16, 7), frame.cursor.col);
    try std.testing.expect(!frame.cursor.visible);
    try std.testing.expectEqual(@as(u16, 100), frame.cols);
    try std.testing.expectEqual(@as(u16, 40), frame.rows);
    try std.testing.expectEqualStrings("hello!", frame.text);
    try std.testing.expectEqual(@as(usize, 1), frame.spans.len);
    try std.testing.expectEqual(@as(u32, 1), frame.spans[0].start);
    try std.testing.expectEqual(@as(u32, 3), frame.spans[0].end);
    try std.testing.expectEqual(0xFF0000FF, frame.spans[0].color);
    try std.testing.expect(frame.spans[0].bold());
}

test "text frame rejects payloads shorter than the header or wrong version" {
    try std.testing.expect(decode(&[_]u8{ 1, 2, 3 }) == null);
    try std.testing.expect(decode(&[_]u8{}) == null);
    var buffer: [header_bytes]u8 = undefined;
    encodeHeader(buffer[0..header_bytes], .{}, 80, 24, 0, 0);
    buffer[9] = 1; // wrong version
    try std.testing.expect(decode(&buffer) == null);
}

test "text frame rejects inconsistent declared lengths" {
    var buffer: [header_bytes]u8 = undefined;
    encodeHeader(buffer[0..header_bytes], .{}, 80, 24, 0, 100); // text_len beyond payload
    try std.testing.expect(decode(&buffer) == null);
}
