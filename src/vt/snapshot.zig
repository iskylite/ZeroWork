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
    /// UI composite document metadata; never sent to the VT parser.
    presentation: @import("../ui/terminal_record_geometry.zig").Layout = .{},
    application_record_id: u64 = 0,
    application_kind: u8 = 0,
    application_state: u8 = 0,
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
pub const CommandState = enum { running, succeeded, failed, unknown };
/// One observed OSC 133 C event, including repeated command lines. Coordinates
/// are current primary-screen positions, resolved from Ghostty tracked refs;
/// null means that the location was evicted, reset, or is not the active screen.
pub const Command = struct {
    id: u64,
    ai_execution_id: ?@import("../host/identity.zig").ExecutionId = null,
    /// Null means that neither the shell nor the retained native input range
    /// supplied a complete command. An observed empty command stays an empty slice.
    command: ?[]const u8 = null,
    start_ms: i64,
    end_ms: ?i64 = null,
    /// Monotonic duration, independent of wall-clock changes. Running projection
    /// copies refresh it on each capture without changing terminal revisions;
    /// the C observer leaves it null and D fixes the final measured duration.
    elapsed_ms: ?u64 = null,
    exit_code: ?i32 = null,
    state: CommandState = .running,
    screen_row: ?u32 = null,
    col: ?u16 = null,
    input_end_row: ?u32 = null,
    input_end_col: ?u16 = null,
    output_start_row: ?u32 = null,
    output_start_col: ?u16 = null,
};
pub const Projection = struct {
    output_sequence: u64 = 0,
    bell_count: u64 = 0,
    theme_revision: u64 = 0,
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
    commands: []const Command = &.{},
    commands_truncated: bool = false,

    pub fn deinit(self: *Projection, allocator: std.mem.Allocator) void {
        allocator.free(self.visible_rows);
        allocator.free(self.cells);
        allocator.free(self.graphemes);
        if (self.reported_cwd) |cwd| allocator.free(cwd);
        for (self.events) |event| allocator.free(event.text);
        allocator.free(self.events);
        for (self.commands) |command| if (command.command) |text| allocator.free(text);
        allocator.free(self.commands);
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
        const commands = try allocator.alloc(Command, self.commands.len);
        var command_count: usize = 0;
        errdefer {
            for (commands[0..command_count]) |command| if (command.command) |text| allocator.free(text);
            allocator.free(commands);
        }
        for (self.commands, 0..) |command, i| {
            commands[i] = command;
            commands[i].command = if (command.command) |text| try allocator.dupe(u8, text) else null;
            command_count += 1;
        }
        result.commands = commands;
        return result;
    }
    pub fn grapheme(self: Projection, cell: Cell) []const u8 {
        return self.graphemes[cell.grapheme_start..][0..cell.grapheme_len];
    }
};
