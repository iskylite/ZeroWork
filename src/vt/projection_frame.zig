//! Encode an already-owned viewport. Local transport and UI replay share this
//! path; neither needs to traverse/project the worker VT a second time.
const std = @import("std");
const vt = @import("snapshot.zig");
const frame = @import("text_frame.zig");
const Span = @import("text_projection_styled.zig").Span;

pub fn encode(allocator: std.mem.Allocator, projection: *const vt.Projection, cursor_visible: bool) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(allocator);
    for (projection.visible_rows, 0..) |row, index| {
        const cells = projection.cells[row.cell_start..][0..row.cell_count];
        var end = cells.len;
        while (end > 0 and cells[end - 1].grapheme_len == 0 and cells[end - 1].attributes == 0 and cells[end - 1].background == .default and cells[end - 1].underline == 0 and !projection.modes.reverse_colors) end -= 1;
        for (cells[0..end]) |cell| {
            if (cell.width == .wide_tail) continue;
            const start: u32 = @intCast(text.items.len);
            try text.appendSlice(allocator, if (cell.grapheme_len == 0) " " else projection.grapheme(cell));
            const default_fg = if (projection.modes.reverse_colors) projection.colors.background else projection.colors.foreground;
            const default_bg = if (projection.modes.reverse_colors) projection.colors.foreground else projection.colors.background;
            var fg = if (cell.foreground == .default) rgba(default_fg) else color(cell.foreground, projection.colors);
            var bg = if (cell.background == .default and projection.modes.reverse_colors) rgba(default_bg) else color(cell.background, projection.colors);
            if (cell.attributes & (1 << 4) != 0) {
                const previous_fg = fg;
                fg = if (bg == 0) rgba(default_bg) else bg;
                bg = if (previous_fg == 0) rgba(default_fg) else previous_fg;
            }
            if (cell.attributes & (1 << 6) != 0) {
                if (fg == 0) fg = rgba(default_fg);
                fg = (fg & 0xffffff00) | 127;
            }
            // Nonzero RGB with alpha zero avoids the wire inherit sentinel.
            if (cell.attributes & (1 << 7) != 0) fg = 0x00000100;
            const style: Span = .{ .start = start, .end = @intCast(text.items.len), .color = fg, .bg = bg, .bold = cell.attributes & 1 != 0, .italic = cell.attributes & 2 != 0, .underline = cell.underline != 0 };
            if (style.color == 0 and style.bg == 0 and !style.bold and !style.italic and !style.underline) continue;
            if (spans.items.len > 0) {
                const last = &spans.items[spans.items.len - 1];
                if (last.end == start and last.color == style.color and last.bg == style.bg and last.bold == style.bold and last.italic == style.italic and last.underline == style.underline) {
                    last.end = style.end;
                    continue;
                }
            }
            try spans.append(allocator, style);
        }
        if (index + 1 < projection.visible_rows.len) try text.append(allocator, '\n');
    }
    if (spans.items.len > std.math.maxInt(u16)) return error.TooManySpans;
    const wire = try allocator.alloc(u8, frame.header_bytes + spans.items.len * frame.span_wire_bytes + text.items.len);
    frame.encodeHeader(wire[0..frame.header_bytes], .{ .row = if (cursor_visible) projection.cursor.row else 0, .col = if (cursor_visible) projection.cursor.col else 0, .visible = cursor_visible and projection.cursor.visible }, projection.cols, projection.rows, spans.items.len, text.items.len);
    frame.encodeSpans(wire[frame.header_bytes..][0 .. spans.items.len * frame.span_wire_bytes], spans.items);
    @memcpy(wire[frame.header_bytes + spans.items.len * frame.span_wire_bytes ..], text.items);
    return wire;
}
pub fn color(value: vt.Color, colors: vt.Colors) u32 {
    const rgb = switch (value) {
        .default => return 0,
        .rgb => |v| v,
        .ansi => |v| colors.palette[v],
        .indexed => |v| colors.palette[v],
    };
    return rgba(rgb);
}

fn rgba(rgb: u24) u32 {
    return (@as(u32, rgb) << 8) | 255;
}
