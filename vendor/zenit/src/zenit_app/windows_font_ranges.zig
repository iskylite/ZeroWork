//! Convert the shared renderer's segment/font decisions into native ranges.
const std = @import("std");
const text = @import("text");
const render = @import("render");
pub fn build(allocator: std.mem.Allocator, stack: *render.font_fallback_stack.FontFallbackStack, primary: *text.Font, content: []const u8, size: f32, italic: bool) !text.FontRanges {
    // Validate before the shared segmenter's unchecked fast decoding path.
    _ = std.unicode.Utf8View.init(content) catch return error.InvalidUtf8;
    if (content.len > 4 * 1048576) return error.TextTooLong;
    var ranges: std.ArrayList(text.FontRange) = .empty;
    defer ranges.deinit(allocator);
    var offset: u32 = 0;
    while (offset < content.len) {
        var spans: [render.TextRenderer.segment_capacity]render.TextRenderer.SegmentSpan = undefined;
        const count = render.TextRenderer.splitSegments(content[offset..], &spans);
        if (count == 0) break; // Only skipped tab/newline controls remain.
        const available = @min(count, spans.len);
        for (spans[0..available]) |span| {
            const segment = content[offset + span.start .. offset + span.end];
            // Same rule as TextRenderer.selectSegmentFont: ASCII is primary,
            // then primary cmap, then script priority/ordered stack coverage.
            if (segment.len == 0 or segment[0] < 128) continue;
            const bytes = std.unicode.utf8ByteSequenceLength(segment[0]) catch unreachable;
            const cp = std.unicode.utf8Decode(segment[0..bytes]) catch unreachable;
            if (primary.glyphIndexForCodepoint(cp) != 0) continue;
            const selected = stack.selectForCodepoint(cp, size, primary.weight) orelse continue;
            const start = offset + span.start;
            const length = span.end - span.start;
            if (ranges.items.len > 0) {
                const previous = &ranges.items[ranges.items.len - 1];
                if (previous.font == selected and previous.start + previous.length == start) {
                    previous.length += length;
                    continue;
                }
            }
            if (ranges.items.len == 65536) return error.TooManyFontRanges;
            try ranges.append(allocator, .{ .font = selected, .start = start, .length = length, .size = size, .italic = if (italic) true else null });
        }
        if (count <= spans.len) break;
        // Keep segment boundaries intact while processing arbitrarily long
        // paragraphs. Adjacent identical selections coalesce across batches.
        const consumed = spans[available - 1].end;
        if (consumed == 0) return error.InvalidFontSegment;
        offset += consumed;
    }
    return text.FontRanges.init(allocator, content, ranges.items);
}
