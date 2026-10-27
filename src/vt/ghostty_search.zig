//! Ghostty's public overscan snapshot supplies stable row ids and real cell
//! graphemes for the complete retained screen without moving its viewport.
const std = @import("std");
const c = @import("generated_ghostty_vt");
const search = @import("search_snapshot.zig");
const native_view = @import("ghostty_view.zig");

// The overscan state is strictly temporary. Its thousands of row/cell
// allocations share a reusable page-backed arena. Idle pages are reclaimable;
// they must not accumulate in libc's small/large malloc caches per rebuild.
const SnapshotArena = struct {
    fn get(ctx: ?*anyopaque) std.mem.Allocator {
        const arena: *std.heap.ArenaAllocator = @ptrCast(@alignCast(ctx.?));
        return arena.allocator();
    }
    fn alloc(ctx: ?*anyopaque, len: usize, alignment: u8, address: usize) callconv(.c) ?*anyopaque {
        return get(ctx).rawAlloc(len, @fromBackingInt(@intCast(alignment)), address);
    }
    fn resize(ctx: ?*anyopaque, memory: ?*anyopaque, len: usize, alignment: u8, next: usize, address: usize) callconv(.c) bool {
        return get(ctx).rawResize(@as([*]u8, @ptrCast(memory.?))[0..len], @fromBackingInt(@intCast(alignment)), next, address);
    }
    fn remap(ctx: ?*anyopaque, memory: ?*anyopaque, len: usize, alignment: u8, next: usize, address: usize) callconv(.c) ?*anyopaque {
        return get(ctx).rawRemap(@as([*]u8, @ptrCast(memory.?))[0..len], @fromBackingInt(@intCast(alignment)), next, address);
    }
    fn free(ctx: ?*anyopaque, memory: ?*anyopaque, len: usize, alignment: u8, address: usize) callconv(.c) void {
        get(ctx).rawFree(@as([*]u8, @ptrCast(memory.?))[0..len], @fromBackingInt(@intCast(alignment)), address);
    }
    const vtable: c.GhosttyAllocatorVtable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
};

/// Decode the bulk row view using the linked library's published manifest,
/// never fixed bit positions. Unknown layouts keep the public getter path.
const CellLayout = struct {
    const Field = struct {
        lsb: u8,
        width: u8,
        fn valid(self: Field, max_width: u8) bool {
            return self.width > 0 and self.width <= max_width and @as(u16, self.lsb) + self.width <= 64;
        }
        fn read(self: Field, raw: u64) u64 {
            return (raw >> @as(u6, @intCast(self.lsb))) & ((@as(u64, 1) << @as(u6, @intCast(self.width))) - 1);
        }
    };
    wide: Field,
    tag: Field,
    style: Field,
    codepoint: Field,
    fn load() ?CellLayout {
        const Arm = struct { bits: struct { codepoint: Field } };
        const Descriptor = struct {
            kind: []const u8,
            size: u8,
            bits: struct { wide: Field, content_tag: Field, style_id: Field, content: struct { lsb: u8, arms: struct { CODEPOINT: Arm, CODEPOINT_GRAPHEME: Arm } } },
        };
        const Manifest = struct { schema: u32, types: struct { GhosttyCell: Descriptor } };
        const json = c.ghostty_type_json();
        if (json == null) return null;
        var parsed = std.json.parseFromSlice(Manifest, std.heap.c_allocator, std.mem.span(json), .{ .ignore_unknown_fields = true }) catch return null;
        defer parsed.deinit();
        const d = parsed.value.types.GhosttyCell;
        if (parsed.value.schema != 1 or d.size != @sizeOf(c.GhosttyCell) or !std.mem.eql(u8, d.kind, "packed")) return null;
        var cp = d.bits.content.arms.CODEPOINT.bits.codepoint;
        if (!std.meta.eql(cp, d.bits.content.arms.CODEPOINT_GRAPHEME.bits.codepoint) or @as(u16, cp.lsb) + d.bits.content.lsb > 63) return null;
        cp.lsb += d.bits.content.lsb;
        const layout: CellLayout = .{ .wide = d.bits.wide, .tag = d.bits.content_tag, .style = d.bits.style_id, .codepoint = cp };
        if (!layout.wide.valid(8) or !layout.tag.valid(8) or !layout.style.valid(16) or !layout.codepoint.valid(32)) return null;
        return layout;
    }
};

pub fn capture(adapter: anytype, allocator: std.mem.Allocator) !search.Document {
    return captureRange(adapter, allocator, 0, null);
}
pub fn captureRange(adapter: anytype, allocator: std.mem.Allocator, start_row: u32, max_rows: ?u16) !search.Document {
    var bar: c.GhosttyTerminalScrollbar = .{};
    if (c.ghostty_terminal_get(adapter.terminal, c.GHOSTTY_TERMINAL_DATA_SCROLLBAR, @ptrCast(&bar)) != c.GHOSTTY_SUCCESS) return error.SearchUnavailable;
    const below = bar.total -| bar.offset -| bar.len;
    if (max_rows) |limit| if (below != 0 or start_row > bar.offset or bar.total -| start_row > limit) return error.FullSearchRequired;
    if (bar.offset -| start_row > std.math.maxInt(u16) or below > std.math.maxInt(u16) or @as(u64, bar.total - start_row) * adapter.cols > 8 * 1024 * 1024) return error.SearchTooLarge;
    const arena = adapter.search_scratch.begin();
    defer adapter.search_scratch.end();
    const native_allocator: c.GhosttyAllocator = .{ .ctx = arena, .vtable = &SnapshotArena.vtable };
    var state: c.GhosttyRenderState = null;
    if (c.ghostty_render_state_new(&native_allocator, &state) != c.GHOSTTY_SUCCESS) return error.OutOfMemory;
    defer c.ghostty_render_state_free(state);
    const overscan: c.GhosttyRenderStateOverscan = .{ .above = @intCast(bar.offset -| start_row), .below = @intCast(below) };
    if (c.ghostty_render_state_set(state, c.GHOSTTY_RENDER_STATE_OPTION_OVERSCAN, @ptrCast(&overscan)) != c.GHOSTTY_SUCCESS) return error.SearchUnavailable;
    // A second render state consumes native dirty flags. Force the display's
    // own state dirty before the next capture so search cannot hide damage.
    const dirty: c.GhosttyRenderStateDirty = c.GHOSTTY_RENDER_STATE_DIRTY_FULL;
    defer _ = c.ghostty_render_state_set(adapter.render_state, c.GHOSTTY_RENDER_STATE_OPTION_DIRTY, @ptrCast(&dirty));
    if (c.ghostty_render_state_update(state, adapter.terminal) != c.GHOSTTY_SUCCESS) return error.SearchUnavailable;
    var iterator: c.GhosttyRenderStateRowIterator = null;
    if (c.ghostty_render_state_row_iterator_new(&native_allocator, &iterator) != c.GHOSTTY_SUCCESS) return error.OutOfMemory;
    defer c.ghostty_render_state_row_iterator_free(iterator);
    if (c.ghostty_render_state_get(state, c.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, @ptrCast(&iterator)) != c.GHOSTTY_SUCCESS) return error.SearchUnavailable;
    var row_cells: c.GhosttyRenderStateRowCells = null;
    if (c.ghostty_render_state_row_cells_new(&native_allocator, &row_cells) != c.GHOSTTY_SUCCESS) return error.OutOfMemory;
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
    const layout = CellLayout.load();
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
        var raw_cells: c.GhosttyCellsView = .{};
        if (c.ghostty_render_state_row_get(iterator, c.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS_RAW, @ptrCast(&raw_cells)) != c.GHOSTTY_SUCCESS) return error.SearchUnavailable;
        var columns = raw_cells.len;
        if (!wraps) if (layout) |decoder| {
            while (columns > 0) : (columns -= 1) {
                const raw = raw_cells.ptr[columns - 1];
                if (decoder.tag.read(raw) != c.GHOSTTY_CELL_CONTENT_CODEPOINT or decoder.codepoint.read(raw) != 0 or decoder.style.read(raw) != 0 or decoder.wide.read(raw) != c.GHOSTTY_CELL_WIDE_NARROW) break;
            }
        };
        var previous_style_id: ?u16 = null;
        var previous_style: c.GhosttyStyle = undefined;
        var col: u16 = 0;
        while (col < columns) : (col += 1) {
            const raw = raw_cells.ptr[col];
            var wide: c.GhosttyCellWide = c.GHOSTTY_CELL_WIDE_NARROW;
            var codepoint: u32 = 0;
            var tag: c.GhosttyCellContentTag = 0;
            var style_id: u16 = 0;
            if (layout) |decoder| {
                wide = @intCast(decoder.wide.read(raw));
                codepoint = @intCast(decoder.codepoint.read(raw));
                tag = @intCast(decoder.tag.read(raw));
                style_id = @intCast(decoder.style.read(raw));
            } else {
                const keys = [_]c.GhosttyCellData{ c.GHOSTTY_CELL_DATA_WIDE, c.GHOSTTY_CELL_DATA_CODEPOINT, c.GHOSTTY_CELL_DATA_CONTENT_TAG, c.GHOSTTY_CELL_DATA_STYLE_ID };
                const values = [_]?*anyopaque{ @ptrCast(&wide), @ptrCast(&codepoint), @ptrCast(&tag), @ptrCast(&style_id) };
                if (c.ghostty_cell_get_multi(raw, keys.len, &keys, @constCast(&values), null) != c.GHOSTTY_SUCCESS) return error.SearchUnavailable;
            }
            if (wide == c.GHOSTTY_CELL_WIDE_SPACER_TAIL or wide == c.GHOSTTY_CELL_WIDE_SPACER_HEAD) continue;
            var utf8: c.GhosttyBuffer = .{};
            const start = text.items.len;
            if (tag == c.GHOSTTY_CELL_CONTENT_CODEPOINT and codepoint < 0x80) {
                utf8.len = @intFromBool(codepoint != 0);
                try text.append(allocator, if (codepoint == 0) ' ' else @intCast(codepoint));
            } else {
                if (c.ghostty_render_state_row_cells_select(row_cells, col) != c.GHOSTTY_SUCCESS) return error.SearchUnavailable;
                const query = c.ghostty_render_state_row_cells_get(row_cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, @ptrCast(&utf8));
                if (query != c.GHOSTTY_SUCCESS and query != c.GHOSTTY_OUT_OF_SPACE) return error.SearchUnavailable;
                if (utf8.len == 0) {
                    try text.append(allocator, ' ');
                } else {
                    try text.resize(allocator, start + utf8.len);
                    utf8.ptr = text.items.ptr + start;
                    utf8.cap = utf8.len;
                    if (c.ghostty_render_state_row_cells_get(row_cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, @ptrCast(&utf8)) != c.GHOSTTY_SUCCESS) return error.SearchUnavailable;
                }
            }
            if (text.items.len > 32 * 1024 * 1024) return error.SearchTooLarge;
            var style: c.GhosttyStyle = .{ .size = @sizeOf(c.GhosttyStyle) };
            // Style ids are page-local; reuse only within this physical row.
            // Background-only cells carry color in their content and must
            // still resolve it individually even when their style id is zero.
            const reusable_style = tag == c.GHOSTTY_CELL_CONTENT_CODEPOINT or tag == c.GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME;
            const same_style = reusable_style and previous_style_id == style_id;
            if (same_style) {
                style = previous_style;
            } else {
                if (c.ghostty_render_state_row_cells_select(row_cells, col) != c.GHOSTTY_SUCCESS) return error.SearchUnavailable;
                if (c.ghostty_render_state_row_cells_get(row_cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, @ptrCast(&style)) != c.GHOSTTY_SUCCESS) return error.SearchUnavailable;
                previous_style_id = if (reusable_style) style_id else null;
                previous_style = style;
            }
            var fg = packColor(style.fg_color, colors);
            var bg = packColor(style.bg_color, colors);
            if (style.inverse) {
                const old = fg;
                fg = if (bg == 0) rgba(colors.background) else bg;
                bg = if (old == 0) rgba(colors.foreground) else old;
            }
            if (style.invisible) fg = if (bg == 0) rgba(colors.background) else bg;
            const previous = if (spans.items.len > spans_start) &spans.items[spans.items.len - 1] else null;
            if (same_style and tag == c.GHOSTTY_CELL_CONTENT_CODEPOINT and (codepoint == 0 or codepoint >= 0x20 and codepoint < 0x7f) and wide == c.GHOSTTY_CELL_WIDE_NARROW and previous != null and previous.?.ascii_run and previous.?.end == start and previous.?.col + previous.?.width == col) {
                // The native style identity already proves equality. Avoid
                // constructing/comparing a full style value per ASCII cell.
                previous.?.end = @intCast(text.items.len);
                previous.?.width += 1;
            } else {
                try search.appendSpan(allocator, &spans, text.items, .{ .start = @intCast(start), .end = @intCast(text.items.len), .row = @intCast(rows.items.len), .col = col, .width = if (wide == c.GHOSTTY_CELL_WIDE_WIDE) 2 else 1, .color = fg, .bg = bg, .flags = @as(u32, @intFromBool(style.bold)) | (@as(u32, @intFromBool(style.italic)) << 1) | (@as(u32, @intFromBool(style.underline != 0)) << 2), .native_cell = nativeStyle(style) });
            }
            if (utf8.len > 0 or wraps or bg != 0 or style.inverse or style.underline != 0 or style.overline or style.strikethrough) {
                text_end = text.items.len;
                spans_end = spans.items.len;
            }
        }
        text.shrinkRetainingCapacity(text_end);
        spans.shrinkRetainingCapacity(spans_end);
        // A trailing blank can have extended an existing ASCII run, so trim
        // that run as well as the array before publishing its byte bounds.
        if (spans.items.len > spans_start) {
            const tail = &spans.items[spans.items.len - 1];
            if (tail.ascii_run and tail.end > text_end) {
                tail.width -= @intCast(tail.end - text_end);
                tail.end = @intCast(text_end);
            }
        }
        const screen_row: i64 = @as(i64, @intCast(bar.offset)) + y;
        if (screen_row < 0 or screen_row >= bar.total) return error.InvalidSearchProjection;
        try rows.append(allocator, .{ .id = id.bits, .logical_id = logical_id, .screen_row = @intCast(screen_row), .start = @intCast(row_start), .end = @intCast(text_end) });
    }
    if (rows.items.len != bar.total - start_row) return error.IncompleteSearchProjection;
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

// Preserve the full terminal style for pixel-scroll rows outside the live
// viewport. The legacy text/search flags intentionally cover only three bits.
fn styleColor(value: c.GhosttyStyleColor) @import("snapshot.zig").Color {
    return switch (value.tag) {
        c.GHOSTTY_STYLE_COLOR_PALETTE => if (value.value.palette < 16) .{ .ansi = @intCast(value.value.palette) } else .{ .indexed = value.value.palette },
        c.GHOSTTY_STYLE_COLOR_RGB => .{ .rgb = (@as(u24, value.value.rgb.r) << 16) | (@as(u24, value.value.rgb.g) << 8) | value.value.rgb.b },
        else => .default,
    };
}
fn nativeStyle(style: c.GhosttyStyle) @import("snapshot.zig").Cell {
    return .{
        .foreground = styleColor(style.fg_color),
        .background = styleColor(style.bg_color),
        .underline_color = styleColor(style.underline_color),
        .underline = @intCast(style.underline),
        .attributes = (@as(u16, @intFromBool(style.bold)) << 0) | (@as(u16, @intFromBool(style.italic)) << 1) | (@as(u16, @intFromBool(style.underline != 0)) << 2) | (@as(u16, @intFromBool(style.blink)) << 3) | (@as(u16, @intFromBool(style.inverse)) << 4) | (@as(u16, @intFromBool(style.strikethrough)) << 5) | (@as(u16, @intFromBool(style.faint)) << 6) | (@as(u16, @intFromBool(style.invisible)) << 7) | (@as(u16, @intFromBool(style.overline)) << 8),
    };
}

test "search snapshot bulk manifest decoder matches the native cell getters" {
    const a = std.testing.allocator;
    const decoder = CellLayout.load() orelse return error.UnsupportedCellLayout;
    var adapter = try @import("ghostty_adapter.zig").Adapter.init(a, 3, 80);
    defer adapter.destroy();
    _ = try adapter.feed("abc\x1b[31mred界e\u{301}👩‍💻\x1b[44m   \x1b[0m");
    var iterator: c.GhosttyRenderStateRowIterator = null;
    try std.testing.expectEqual(c.GHOSTTY_SUCCESS, c.ghostty_render_state_row_iterator_new(null, &iterator));
    defer c.ghostty_render_state_row_iterator_free(iterator);
    try std.testing.expectEqual(c.GHOSTTY_SUCCESS, c.ghostty_render_state_get(adapter.render_state, c.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, @ptrCast(&iterator)));
    while (c.ghostty_render_state_row_iterator_next(iterator)) {
        var cells: c.GhosttyCellsView = .{};
        try std.testing.expectEqual(c.GHOSTTY_SUCCESS, c.ghostty_render_state_row_get(iterator, c.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS_RAW, @ptrCast(&cells)));
        for (cells.ptr[0..cells.len]) |raw| {
            var cp: u32 = 0;
            var wide: c.GhosttyCellWide = 0;
            var tag: c.GhosttyCellContentTag = 0;
            var style_id: u16 = 0;
            _ = c.ghostty_cell_get(raw, c.GHOSTTY_CELL_DATA_CODEPOINT, @ptrCast(&cp));
            _ = c.ghostty_cell_get(raw, c.GHOSTTY_CELL_DATA_WIDE, @ptrCast(&wide));
            _ = c.ghostty_cell_get(raw, c.GHOSTTY_CELL_DATA_CONTENT_TAG, @ptrCast(&tag));
            _ = c.ghostty_cell_get(raw, c.GHOSTTY_CELL_DATA_STYLE_ID, @ptrCast(&style_id));
            if (tag == c.GHOSTTY_CELL_CONTENT_CODEPOINT or tag == c.GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME) try std.testing.expectEqual(cp, decoder.codepoint.read(raw));
            try std.testing.expectEqual(wide, decoder.wide.read(raw));
            try std.testing.expectEqual(tag, decoder.tag.read(raw));
            try std.testing.expectEqual(style_id, decoder.style.read(raw));
        }
    }
}
