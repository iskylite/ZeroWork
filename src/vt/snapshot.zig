//! Owned VT projection. Every value comes from the existing engine; none of
//! these types parses output or predicts shell state.
const std = @import("std");
const Cursor = @import("engine.zig").Cursor;
const Width = @import("cell.zig").Width;

pub const Modes = struct {
    application_cursor: bool = false,
    application_keypad: bool = false,
    ignore_keypad_with_numlock: bool = false,
    backarrow_key: bool = false,
    alt_esc_prefix: bool = false,
    bracketed_paste: bool = false,
    alternate_screen: bool = false,
    mouse_tracking: enum { none, x10, normal, button, any } = .none,
    mouse_format: enum { x10, utf8, sgr, urxvt, sgr_pixels } = .x10,
    focus_events: bool = false,
    alternate_scroll: bool = false,
    wraparound: bool = true,
    origin: bool = false,
    insert: bool = false,
    linefeed: bool = false,
    keyboard_disabled: bool = false,
    kitty_keyboard_flags: u8 = 0,
    grapheme_clusters: bool = false,
    reverse_colors: bool = false,
    synchronized_output: bool = false,
    in_band_resize: bool = false,
    paste_events: bool = false,
    cursor_visible: bool = true,
    cursor_blinking: bool = true,
};
pub const Color = union(enum) { default, ansi: u4, indexed: u8, rgb: u24 };
pub const Cell = struct {
    width: Width = .single,
    grapheme_start: u32 = 0,
    grapheme_len: u32 = 0,
    foreground: Color = .default,
    background: Color = .default,
    underline_color: Color = .default,
    attributes: u16 = 0,
    underline: u8 = 0,
    semantic: u8 = 0,
};
pub const RowId = [2]u64;
pub const Row = struct {
    /// Ghostty render-row ids are never reused for a different row.
    id: RowId,
    viewport_y: u16,
    cell_start: u32,
    cell_count: u16,
    wraps: bool,
    continuation: bool,
    /// Unknown when the logical start lies above this captured viewport.
    logical_start_id: ?RowId,
    dirty: bool,
    semantic_prompt: u8,
    logical_id: ?u64 = null,
    received_wallclock_ms: ?i64 = null,
    submitted_wallclock_ms: ?i64 = null,
};
pub const ScrollbackRange = struct { total_rows: u64 = 0, viewport_offset: u64 = 0, viewport_rows: u64 = 0 };
pub const Colors = struct { foreground: u24, background: u24, cursor: ?u24, palette: [256]u24 };
pub const Event = struct {
    sequence: u64,
    kind: enum { cwd, prompt_start, input_start, output_start, command_end },
    text: []const u8,
    exit_code: ?i32 = null,
};
pub const Projection = struct {
    version: u64,
    style_version: u64,
    mode_revision: u64,
    modes: Modes,
    colors: Colors,
    cursor: Cursor,
    active_cursor: Cursor,
    cols: u16,
    rows: u16,
    visible_rows: []const Row,
    cells: []const Cell,
    graphemes: []const u8,
    scrollback: ScrollbackRange,
    reported_cwd: ?[]const u8 = null,
    at_prompt: bool = false,
    events: []const Event = &.{},
    events_truncated: bool = false,
    metadata_truncated: bool = false,

    pub fn deinit(self: *Projection, allocator: std.mem.Allocator) void {
        allocator.free(self.visible_rows);
        allocator.free(self.cells);
        allocator.free(self.graphemes);
        if (self.reported_cwd) |cwd| allocator.free(cwd);
        for (self.events) |event| allocator.free(event.text);
        allocator.free(self.events);
        self.* = undefined;
    }
    pub fn clone(self: Projection, allocator: std.mem.Allocator) !Projection {
        var result = self;
        result.visible_rows = try allocator.dupe(Row, self.visible_rows);
        errdefer allocator.free(result.visible_rows);
        result.cells = try allocator.dupe(Cell, self.cells);
        errdefer allocator.free(result.cells);
        result.graphemes = try allocator.dupe(u8, self.graphemes);
        errdefer allocator.free(result.graphemes);
        result.reported_cwd = if (self.reported_cwd) |cwd| try allocator.dupe(u8, cwd) else null;
        errdefer if (result.reported_cwd) |cwd| allocator.free(cwd);
        const events = try allocator.alloc(Event, self.events.len);
        var count: usize = 0;
        errdefer {
            for (events[0..count]) |event| allocator.free(event.text);
            allocator.free(events);
        }
        for (self.events, 0..) |event, i| {
            events[i] = event;
            events[i].text = try allocator.dupe(u8, event.text);
            count += 1;
        }
        result.events = events;
        return result;
    }
    pub fn grapheme(self: Projection, cell: Cell) []const u8 {
        return self.graphemes[cell.grapheme_start..][0..cell.grapheme_len];
    }
};
