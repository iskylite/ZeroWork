//! Copy Ghostty's render state, including data that the legacy text frame
//! cannot represent. The caller serializes this with all terminal mutations.
const std = @import("std");
const c = @import("generated_ghostty_vt");
const model = @import("snapshot.zig");

pub fn mode(terminal: c.GhosttyTerminal, number: u16, ansi: bool) bool {
    var value: c.GhosttyTerminalModeConfig = .{ .mode = c.ghostty_mode_new(number, ansi), .value = false };
    return c.ghostty_terminal_get(terminal, c.GHOSTTY_TERMINAL_DATA_MODE, @ptrCast(&value)) == c.GHOSTTY_SUCCESS and value.value;
}
pub fn modes(terminal: c.GhosttyTerminal) model.Modes {
    var active: c.GhosttyTerminalScreen = c.GHOSTTY_TERMINAL_SCREEN_PRIMARY;
    var kitty: u8 = 0;
    _ = c.ghostty_terminal_get(terminal, c.GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, @ptrCast(&active));
    _ = c.ghostty_terminal_get(terminal, c.GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, @ptrCast(&kitty));
    return .{
        .application_cursor = mode(terminal, 1, false),
        .application_keypad = mode(terminal, 66, false),
        .ignore_keypad_with_numlock = mode(terminal, 1035, false),
        .backarrow_key = mode(terminal, 67, false),
        .alt_esc_prefix = mode(terminal, 1036, false),
        .bracketed_paste = mode(terminal, 2004, false),
        .alternate_screen = active == c.GHOSTTY_TERMINAL_SCREEN_ALTERNATE,
        .mouse_tracking = if (mode(terminal, 1003, false)) .any else if (mode(terminal, 1002, false)) .button else if (mode(terminal, 1000, false)) .normal else if (mode(terminal, 9, false)) .x10 else .none,
        .mouse_format = if (mode(terminal, 1016, false)) .sgr_pixels else if (mode(terminal, 1006, false)) .sgr else if (mode(terminal, 1015, false)) .urxvt else if (mode(terminal, 1005, false)) .utf8 else .x10,
        .focus_events = mode(terminal, 1004, false),
        .alternate_scroll = mode(terminal, 1007, false),
        .wraparound = mode(terminal, 7, false),
        .origin = mode(terminal, 6, false),
        .insert = mode(terminal, 4, true),
        .linefeed = mode(terminal, 20, true),
        .keyboard_disabled = mode(terminal, 2, true),
        .kitty_keyboard_flags = kitty,
        .grapheme_clusters = mode(terminal, 2027, false),
        .reverse_colors = mode(terminal, 5, false),
        .synchronized_output = mode(terminal, 2026, false),
        .in_band_resize = mode(terminal, 2048, false),
        .paste_events = mode(terminal, 5522, false),
        .cursor_visible = mode(terminal, 25, false),
        .cursor_blinking = mode(terminal, 12, false),
    };
}
fn color(value: c.GhosttyStyleColor) model.Color {
    return switch (value.tag) {
        c.GHOSTTY_STYLE_COLOR_PALETTE => if (value.value.palette < 16) .{ .ansi = @intCast(value.value.palette) } else .{ .indexed = value.value.palette },
        c.GHOSTTY_STYLE_COLOR_RGB => .{ .rgb = rgb(value.value.rgb) },
        else => .default,
    };
}
fn rgb(value: c.GhosttyColorRgb) u24 {
    return (@as(u24, value.r) << 16) | (@as(u24, value.g) << 8) | value.b;
}

pub fn capture(adapter: anytype, allocator: std.mem.Allocator) !model.Projection {
    const scalar = adapter.snapshotLocked();
    var rows: std.ArrayList(model.Row) = .empty;
    defer rows.deinit(allocator);
    var cells: std.ArrayList(model.Cell) = .empty;
    defer cells.deinit(allocator);
    var graphemes: std.ArrayList(u8) = .empty;
    defer graphemes.deinit(allocator);
    try rows.ensureTotalCapacity(allocator, scalar.rows);
    try cells.ensureTotalCapacity(allocator, @as(usize, scalar.rows) * scalar.cols);
    var iterator: c.GhosttyRenderStateRowIterator = null;
    if (c.ghostty_render_state_row_iterator_new(null, &iterator) != c.GHOSTTY_SUCCESS) return error.GhosttyProjectionFailed;
    defer c.ghostty_render_state_row_iterator_free(iterator);
    if (c.ghostty_render_state_get(adapter.render_state, c.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, @ptrCast(&iterator)) != c.GHOSTTY_SUCCESS) return error.GhosttyProjectionFailed;
    var row_cells: c.GhosttyRenderStateRowCells = null;
    if (c.ghostty_render_state_row_cells_new(null, &row_cells) != c.GHOSTTY_SUCCESS) return error.GhosttyProjectionFailed;
    defer c.ghostty_render_state_row_cells_free(row_cells);
    var logical_start: ?model.RowId = null;
    while (c.ghostty_render_state_row_iterator_next(iterator)) {
        var y: i32 = 0;
        if (c.ghostty_render_state_row_get(iterator, c.GHOSTTY_RENDER_STATE_ROW_DATA_VIEWPORT_Y, @ptrCast(&y)) != c.GHOSTTY_SUCCESS or y < 0 or y >= scalar.rows) continue;
        var row_id: c.GhosttyRenderStateRowId = .{};
        var dirty = false;
        var raw_row: c.GhosttyRow = 0;
        if (c.ghostty_render_state_row_get(iterator, c.GHOSTTY_RENDER_STATE_ROW_DATA_ID, @ptrCast(&row_id)) != c.GHOSTTY_SUCCESS) return error.RowIdentityUnavailable;
        _ = c.ghostty_render_state_row_get(iterator, c.GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, @ptrCast(&dirty));
        _ = c.ghostty_render_state_row_get(iterator, c.GHOSTTY_RENDER_STATE_ROW_DATA_RAW, @ptrCast(&raw_row));
        var wraps = false;
        var continuation = false;
        var semantic: c.GhosttyRowSemanticPrompt = c.GHOSTTY_ROW_SEMANTIC_NONE;
        _ = c.ghostty_row_get(raw_row, c.GHOSTTY_ROW_DATA_WRAP, @ptrCast(&wraps));
        _ = c.ghostty_row_get(raw_row, c.GHOSTTY_ROW_DATA_WRAP_CONTINUATION, @ptrCast(&continuation));
        _ = c.ghostty_row_get(raw_row, c.GHOSTTY_ROW_DATA_SEMANTIC_PROMPT, @ptrCast(&semantic));
        if (!continuation) logical_start = row_id.bits;
        const start = cells.items.len;
        var container = row_cells;
        if (c.ghostty_render_state_row_get(iterator, c.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, @ptrCast(&container)) != c.GHOSTTY_SUCCESS) return error.GhosttyProjectionFailed;
        while (c.ghostty_render_state_row_cells_next(container)) {
            var cell: model.Cell = .{};
            var raw: c.GhosttyCell = 0;
            _ = c.ghostty_render_state_row_cells_get(container, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, @ptrCast(&raw));
            var wide: c.GhosttyCellWide = c.GHOSTTY_CELL_WIDE_NARROW;
            var cell_semantic: c.GhosttyCellSemanticContent = 0;
            _ = c.ghostty_cell_get(raw, c.GHOSTTY_CELL_DATA_WIDE, @ptrCast(&wide));
            _ = c.ghostty_cell_get(raw, c.GHOSTTY_CELL_DATA_SEMANTIC_CONTENT, @ptrCast(&cell_semantic));
            cell.width = switch (wide) {
                c.GHOSTTY_CELL_WIDE_WIDE => .wide_lead,
                c.GHOSTTY_CELL_WIDE_SPACER_TAIL => .wide_tail,
                else => .single,
            };
            cell.semantic = @intCast(cell_semantic);
            var style: c.GhosttyStyle = .{ .size = @sizeOf(c.GhosttyStyle) };
            if (c.ghostty_render_state_row_cells_get(container, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, @ptrCast(&style)) != c.GHOSTTY_SUCCESS) return error.GhosttyProjectionFailed;
            cell.foreground = color(style.fg_color);
            cell.background = color(style.bg_color);
            cell.underline_color = color(style.underline_color);
            cell.underline = @intCast(style.underline);
            cell.attributes = (@as(u16, @intFromBool(style.bold)) << 0) | (@as(u16, @intFromBool(style.italic)) << 1) | (@as(u16, @intFromBool(style.underline != 0)) << 2) | (@as(u16, @intFromBool(style.blink)) << 3) | (@as(u16, @intFromBool(style.inverse)) << 4) | (@as(u16, @intFromBool(style.strikethrough)) << 5) | (@as(u16, @intFromBool(style.faint)) << 6) | (@as(u16, @intFromBool(style.invisible)) << 7) | (@as(u16, @intFromBool(style.overline)) << 8);
            var content: c.GhosttyCellContentTag = 0;
            _ = c.ghostty_cell_get(raw, c.GHOSTTY_CELL_DATA_CONTENT_TAG, @ptrCast(&content));
            if (content == c.GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE) {
                var index: c.GhosttyColorPaletteIndex = 0;
                _ = c.ghostty_cell_get(raw, c.GHOSTTY_CELL_DATA_COLOR_PALETTE, @ptrCast(&index));
                cell.background = if (index < 16) .{ .ansi = @intCast(index) } else .{ .indexed = index };
            } else if (content == c.GHOSTTY_CELL_CONTENT_BG_COLOR_RGB) {
                var value: c.GhosttyColorRgb = .{};
                _ = c.ghostty_cell_get(raw, c.GHOSTTY_CELL_DATA_COLOR_RGB, @ptrCast(&value));
                cell.background = .{ .rgb = rgb(value) };
            }
            var utf8: c.GhosttyBuffer = .{};
            const query = c.ghostty_render_state_row_cells_get(container, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, @ptrCast(&utf8));
            if (query != c.GHOSTTY_SUCCESS and query != c.GHOSTTY_OUT_OF_SPACE) return error.GhosttyProjectionFailed;
            cell.grapheme_start = @intCast(graphemes.items.len);
            cell.grapheme_len = @intCast(utf8.len);
            if (utf8.len > 0) {
                try graphemes.resize(allocator, graphemes.items.len + utf8.len);
                utf8.ptr = graphemes.items.ptr + cell.grapheme_start;
                utf8.cap = utf8.len;
                if (c.ghostty_render_state_row_cells_get(container, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, @ptrCast(&utf8)) != c.GHOSTTY_SUCCESS) return error.GhosttyProjectionFailed;
            }
            try cells.append(allocator, cell);
        }
        try rows.append(allocator, .{ .id = row_id.bits, .viewport_y = @intCast(y), .cell_start = @intCast(start), .cell_count = @intCast(cells.items.len - start), .wraps = wraps, .continuation = continuation, .logical_start_id = logical_start, .dirty = dirty, .semantic_prompt = @intCast(semantic) });
    }
    var bar: c.GhosttyTerminalScrollbar = .{};
    _ = c.ghostty_terminal_get(adapter.terminal, c.GHOSTTY_TERMINAL_DATA_SCROLLBAR, @ptrCast(&bar));
    var at_prompt = false;
    _ = c.ghostty_terminal_get(adapter.terminal, c.GHOSTTY_TERMINAL_DATA_CURSOR_AT_PROMPT, @ptrCast(&at_prompt));
    var cursor = scalar.cursor;
    var native_colors: c.GhosttyRenderStateColors = .{ .size = @sizeOf(c.GhosttyRenderStateColors) };
    if (c.ghostty_render_state_get(adapter.render_state, c.GHOSTTY_RENDER_STATE_DATA_COLORS, @ptrCast(&native_colors)) != c.GHOSTTY_SUCCESS) return error.GhosttyProjectionFailed;
    var colors: model.Colors = .{ .foreground = rgb(native_colors.foreground), .background = rgb(native_colors.background), .cursor = if (native_colors.cursor_has_value) rgb(native_colors.cursor) else null, .palette = undefined };
    for (native_colors.palette, 0..) |value, i| colors.palette[i] = rgb(value);
    // Ghostty render colors already apply DECSCNM. Our transport-neutral
    // projection keeps logical defaults plus the reverse_colors mode so the
    // common renderer can invert explicit palette/RGB cells consistently too.
    if (mode(adapter.terminal, 5, false)) std.mem.swap(u24, &colors.foreground, &colors.background);
    var native_cursor: c.GhosttyRenderStateCursor = .{ .size = @sizeOf(c.GhosttyRenderStateCursor) };
    if (c.ghostty_render_state_get(adapter.render_state, c.GHOSTTY_RENDER_STATE_DATA_CURSOR, @ptrCast(&native_cursor)) == c.GHOSTTY_SUCCESS) {
        cursor.visible = native_cursor.viewport_has_value and native_cursor.visible;
        cursor.blinking = native_cursor.blinking;
        cursor.shape = switch (native_cursor.visual_style) {
            c.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR => .bar,
            c.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE => .underline,
            c.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW => .hollow,
            else => .block,
        };
        if (native_cursor.viewport_has_value) {
            cursor.row = native_cursor.viewport_y;
            cursor.col = native_cursor.viewport_x;
            cursor.wide_tail = native_cursor.wide_tail;
        }
    }
    var projection: model.Projection = .{ .version = scalar.version, .style_version = scalar.style_version, .mode_revision = scalar.mode_revision, .modes = scalar.modes, .colors = colors, .cursor = cursor, .active_cursor = scalar.cursor, .cols = scalar.cols, .rows = scalar.rows, .visible_rows = try rows.toOwnedSlice(allocator), .cells = &.{}, .graphemes = &.{}, .scrollback = .{ .total_rows = bar.total, .viewport_offset = bar.offset, .viewport_rows = bar.len }, .at_prompt = at_prompt };
    errdefer projection.deinit(allocator);
    projection.cells = try cells.toOwnedSlice(allocator);
    projection.graphemes = try graphemes.toOwnedSlice(allocator);
    projection.reported_cwd = if (adapter.cwd_owned) |cwd| try allocator.dupe(u8, cwd) else null;
    projection.events = events: {
        const events = try allocator.alloc(model.Event, adapter.events.items.len);
        var count: usize = 0;
        errdefer {
            for (events[0..count]) |event| allocator.free(event.text);
            allocator.free(events);
        }
        for (adapter.events.items, 0..) |event, i| {
            events[i] = event;
            events[i].text = try allocator.dupe(u8, event.text);
            count += 1;
        }
        break :events events;
    };
    projection.events_truncated = adapter.events_truncated;
    adapter.row_metadata.annotate(adapter.terminal, @constCast(projection.visible_rows), bar.offset);
    projection.metadata_truncated = adapter.row_metadata.truncated;
    projection.commands = try adapter.command_metadata.capture(adapter.terminal, scalar.cols, allocator);
    projection.commands_truncated = adapter.command_metadata.truncated;
    return projection;
}
