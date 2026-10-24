//! Ghostty's public overscan snapshot supplies stable row ids and real cell
//! graphemes for the complete retained screen without moving its viewport.
const std = @import("std");
const c = @import("generated_ghostty_vt");
const search = @import("search_snapshot.zig");
const native_view = @import("ghostty_view.zig");

pub fn capture(adapter: anytype, allocator: std.mem.Allocator) !search.Document {
    var bar: c.GhosttyTerminalScrollbar = .{};
    if (c.ghostty_terminal_get(adapter.terminal, c.GHOSTTY_TERMINAL_DATA_SCROLLBAR, @ptrCast(&bar)) != c.GHOSTTY_SUCCESS) return error.SearchUnavailable;
    const below = bar.total -| bar.offset -| bar.len;
    if (bar.offset > std.math.maxInt(u16) or below > std.math.maxInt(u16) or @as(u64, bar.total) * adapter.cols > 8 * 1024 * 1024) return error.SearchTooLarge;
    var state: c.GhosttyRenderState = null;
    if (c.ghostty_render_state_new(null, &state) != c.GHOSTTY_SUCCESS) return error.OutOfMemory;
    defer c.ghostty_render_state_free(state);
    const overscan: c.GhosttyRenderStateOverscan = .{ .above = @intCast(bar.offset), .below = @intCast(below) };
    if (c.ghostty_render_state_set(state, c.GHOSTTY_RENDER_STATE_OPTION_OVERSCAN, @ptrCast(&overscan)) != c.GHOSTTY_SUCCESS) return error.SearchUnavailable;
    // A second render state consumes native dirty flags. Force the display's
    // own state dirty before the next capture so search cannot hide damage.
    const dirty: c.GhosttyRenderStateDirty = c.GHOSTTY_RENDER_STATE_DIRTY_FULL;
    defer _ = c.ghostty_render_state_set(adapter.render_state, c.GHOSTTY_RENDER_STATE_OPTION_DIRTY, @ptrCast(&dirty));
    if (c.ghostty_render_state_update(state, adapter.terminal) != c.GHOSTTY_SUCCESS) return error.SearchUnavailable;
    var iterator: c.GhosttyRenderStateRowIterator = null;
    if (c.ghostty_render_state_row_iterator_new(null, &iterator) != c.GHOSTTY_SUCCESS) return error.OutOfMemory;
    defer c.ghostty_render_state_row_iterator_free(iterator);
    if (c.ghostty_render_state_get(state, c.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, @ptrCast(&iterator)) != c.GHOSTTY_SUCCESS) return error.SearchUnavailable;
    var row_cells: c.GhosttyRenderStateRowCells = null;
    if (c.ghostty_render_state_row_cells_new(null, &row_cells) != c.GHOSTTY_SUCCESS) return error.OutOfMemory;
    defer c.ghostty_render_state_row_cells_free(row_cells);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    var rows: std.ArrayList(search.Row) = .empty;
    defer rows.deinit(allocator);
    var spans: std.ArrayList(search.Span) = .empty;
    defer spans.deinit(allocator);
    var colors: c.GhosttyRenderStateColors = .{ .size = @sizeOf(c.GhosttyRenderStateColors) };
    if (c.ghostty_render_state_get(state, c.GHOSTTY_RENDER_STATE_DATA_COLORS, @ptrCast(&colors)) != c.GHOSTTY_SUCCESS) return error.SearchUnavailable;
    var logical_id: @import("snapshot.zig").RowId = undefined;
    while (c.ghostty_render_state_row_iterator_next(iterator)) {
        var y: i32 = 0;
        var id: c.GhosttyRenderStateRowId = .{};
        var raw_row: c.GhosttyRow = 0;
        if (c.ghostty_render_state_row_get(iterator, c.GHOSTTY_RENDER_STATE_ROW_DATA_VIEWPORT_Y, @ptrCast(&y)) != c.GHOSTTY_SUCCESS or
            c.ghostty_render_state_row_get(iterator, c.GHOSTTY_RENDER_STATE_ROW_DATA_ID, @ptrCast(&id)) != c.GHOSTTY_SUCCESS or
            c.ghostty_render_state_row_get(iterator, c.GHOSTTY_RENDER_STATE_ROW_DATA_RAW, @ptrCast(&raw_row)) != c.GHOSTTY_SUCCESS) return error.SearchUnavailable;
        var continuation = false;
        var wraps = false;
        _ = c.ghostty_row_get(raw_row, c.GHOSTTY_ROW_DATA_WRAP_CONTINUATION, @ptrCast(&continuation));
        _ = c.ghostty_row_get(raw_row, c.GHOSTTY_ROW_DATA_WRAP, @ptrCast(&wraps));
        if (!continuation or rows.items.len == 0) {
            logical_id = id.bits;
            if (rows.items.len > 0) try text.append(allocator, '\n');
        }
        const row_start = text.items.len;
        const spans_start = spans.items.len;
        var text_end = row_start;
        var spans_end = spans_start;
        if (c.ghostty_render_state_row_get(iterator, c.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, @ptrCast(&row_cells)) != c.GHOSTTY_SUCCESS) return error.SearchUnavailable;
        var col: u16 = 0;
        while (c.ghostty_render_state_row_cells_next(row_cells)) : (col += 1) {
            var raw: c.GhosttyCell = 0;
            _ = c.ghostty_render_state_row_cells_get(row_cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, @ptrCast(&raw));
            var wide: c.GhosttyCellWide = c.GHOSTTY_CELL_WIDE_NARROW;
            _ = c.ghostty_cell_get(raw, c.GHOSTTY_CELL_DATA_WIDE, @ptrCast(&wide));
            if (wide == c.GHOSTTY_CELL_WIDE_SPACER_TAIL or wide == c.GHOSTTY_CELL_WIDE_SPACER_HEAD) continue;
            var utf8: c.GhosttyBuffer = .{};
            const query = c.ghostty_render_state_row_cells_get(row_cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, @ptrCast(&utf8));
            if (query != c.GHOSTTY_SUCCESS and query != c.GHOSTTY_OUT_OF_SPACE) return error.SearchUnavailable;
            if (text.items.len + @max(1, utf8.len) > 32 * 1024 * 1024) return error.SearchTooLarge;
            const start = text.items.len;
            if (utf8.len == 0) {
                try text.append(allocator, ' ');
            } else {
                try text.resize(allocator, start + utf8.len);
                utf8.ptr = text.items.ptr + start;
                utf8.cap = utf8.len;
                if (c.ghostty_render_state_row_cells_get(row_cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, @ptrCast(&utf8)) != c.GHOSTTY_SUCCESS) return error.SearchUnavailable;
            }
            var style: c.GhosttyStyle = .{ .size = @sizeOf(c.GhosttyStyle) };
            if (c.ghostty_render_state_row_cells_get(row_cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, @ptrCast(&style)) != c.GHOSTTY_SUCCESS) return error.SearchUnavailable;
            var fg = packColor(style.fg_color, colors);
            var bg = packColor(style.bg_color, colors);
            if (style.inverse) {
                const old = fg;
                fg = if (bg == 0) rgba(colors.background) else bg;
                bg = if (old == 0) rgba(colors.foreground) else old;
            }
            if (style.invisible) fg = if (bg == 0) rgba(colors.background) else bg;
            try spans.append(allocator, .{ .start = @intCast(start), .end = @intCast(text.items.len), .row = @intCast(rows.items.len), .col = col, .width = if (wide == c.GHOSTTY_CELL_WIDE_WIDE) 2 else 1, .color = fg, .bg = bg, .flags = @as(u32, @intFromBool(style.bold)) | (@as(u32, @intFromBool(style.italic)) << 1) | (@as(u32, @intFromBool(style.underline != 0)) << 2) });
            if (utf8.len > 0 or wraps or bg != 0 or style.inverse or style.underline != 0) {
                text_end = text.items.len;
                spans_end = spans.items.len;
            }
        }
        text.shrinkRetainingCapacity(text_end);
        spans.shrinkRetainingCapacity(spans_end);
        const screen_row: i64 = @as(i64, @intCast(bar.offset)) + y;
        if (screen_row < 0 or screen_row >= bar.total) return error.InvalidSearchProjection;
        try rows.append(allocator, .{ .id = id.bits, .logical_id = logical_id, .screen_row = @intCast(screen_row), .start = @intCast(row_start), .end = @intCast(text_end) });
    }
    if (rows.items.len != bar.total) return error.IncompleteSearchProjection;
    const owned_text = try text.toOwnedSlice(allocator);
    errdefer allocator.free(owned_text);
    const owned_rows = try rows.toOwnedSlice(allocator);
    errdefer allocator.free(owned_rows);
    return .{ .source_version = adapter.version, .alternate_screen = native_view.alternate(adapter.terminal), .text = owned_text, .rows = owned_rows, .spans = try spans.toOwnedSlice(allocator) };
}

fn rgba(value: c.GhosttyColorRgb) u32 {
    return (@as(u32, value.r) << 24) | (@as(u32, value.g) << 16) | (@as(u32, value.b) << 8) | 255;
}
fn packColor(color: c.GhosttyStyleColor, colors: c.GhosttyRenderStateColors) u32 {
    return switch (color.tag) {
        c.GHOSTTY_STYLE_COLOR_PALETTE => rgba(colors.palette[color.value.palette]),
        c.GHOSTTY_STYLE_COLOR_RGB => rgba(color.value.rgb),
        else => 0,
    };
}
