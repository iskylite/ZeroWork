//! Commands observed at native OSC 133 boundaries. Input text is copied from
//! Ghostty's retained B-to-C range, never from a submitted-input draft or echo parser.
const std = @import("std");
const c = @import("generated_ghostty_vt");
const native_view = @import("ghostty_view.zig");
const model = @import("snapshot.zig");
const Point = @import("viewport.zig").Point;
const ExecutionId = @import("../host/identity.zig").ExecutionId;
const max_commands = 512;
const max_command_bytes = 16 * 1024;

const Anchor = struct {
    native: c.GhosttyTrackedGridRef = null,
    after: u2 = 0,

    fn deinit(self: *Anchor) void {
        c.ghostty_tracked_grid_ref_free(self.native);
        self.* = .{};
    }
    fn at(terminal: c.GhosttyTerminal, point: Point, after: bool) Anchor {
        var anchor: Anchor = .{ .after = @intFromBool(after) };
        const native: c.GhosttyPoint = .{ .tag = c.GHOSTTY_POINT_TAG_SCREEN, .value = .{ .coordinate = .{ .x = point.col, .y = point.row } } };
        if (c.ghostty_terminal_grid_ref_track(terminal, native, &anchor.native) != c.GHOSTTY_SUCCESS) return .{};
        if (after) {
            const ref = native_view.gridRef(terminal, point) catch return anchor;
            var cell: c.GhosttyCell = 0;
            var wide: c.GhosttyCellWide = c.GHOSTTY_CELL_WIDE_NARROW;
            if (c.ghostty_grid_ref_cell(&ref, &cell) == c.GHOSTTY_SUCCESS) _ = c.ghostty_cell_get(cell, c.GHOSTTY_CELL_DATA_WIDE, @ptrCast(&wide));
            if (wide == c.GHOSTTY_CELL_WIDE_WIDE) anchor.after = 2;
        }
        return anchor;
    }
    fn resolve(self: Anchor, terminal: c.GhosttyTerminal, cols: u16) ?Point {
        if (self.native == null or native_view.alternate(terminal) or !c.ghostty_tracked_grid_ref_has_value(self.native)) return null;
        var point: c.GhosttyPointCoordinate = .{};
        if (c.ghostty_tracked_grid_ref_point(self.native, c.GHOSTTY_POINT_TAG_SCREEN, &point) != c.GHOSTTY_SUCCESS) return null;
        var result: Point = .{ .space = .screen, .row = point.y, .col = point.x + self.after };
        // A gap following the last cell of a wrapped row is the next row's
        // beginning. Keeping the preceding cell tracked survives native reflow.
        if (result.col >= cols) {
            const ref = native_view.gridRef(terminal, .{ .space = .screen, .row = result.row, .col = 0 }) catch return null;
            var row: c.GhosttyRow = 0;
            var wraps = false;
            if (c.ghostty_grid_ref_row(&ref, &row) != c.GHOSTTY_SUCCESS) return null;
            _ = c.ghostty_row_get(row, c.GHOSTTY_ROW_DATA_WRAP, @ptrCast(&wraps));
            if (wraps) {
                result.row += 1;
                result.col = 0;
            }
        }
        return result;
    }
};
const Entry = struct {
    value: model.Command,
    input_start: Anchor = .{},
    input_end: Anchor = .{},
    output_start: Anchor = .{},
    started_ns: i128,

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        if (self.value.command) |text| allocator.free(text);
        self.input_start.deinit();
        self.input_end.deinit();
        self.output_start.deinit();
    }
};

fn cursor(terminal: c.GhosttyTerminal, rows: u16) ?Point {
    var x: u16 = 0;
    var y: u16 = 0;
    var total: usize = 0;
    if (c.ghostty_terminal_get(terminal, c.GHOSTTY_TERMINAL_DATA_CURSOR_X, @ptrCast(&x)) != c.GHOSTTY_SUCCESS or
        c.ghostty_terminal_get(terminal, c.GHOSTTY_TERMINAL_DATA_CURSOR_Y, @ptrCast(&y)) != c.GHOSTTY_SUCCESS or
        c.ghostty_terminal_get(terminal, c.GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, @ptrCast(&total)) != c.GHOSTTY_SUCCESS) return null;
    return .{ .space = .screen, .row = @intCast(total -| rows + y), .col = x };
}
fn pendingWrap(terminal: c.GhosttyTerminal) bool {
    var pending = false;
    _ = c.ghostty_terminal_get(terminal, c.GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP, @ptrCast(&pending));
    return pending;
}
fn less(a: Point, b: Point) bool {
    return a.row < b.row or a.row == b.row and a.col < b.col;
}
fn elapsedMs(started_ns: i128, now_ns: i128) ?u64 {
    if (started_ns <= 0 or now_ns < started_ns) return null;
    return @intCast(@min(@divTrunc(now_ns - started_ns, std.time.ns_per_ms), std.math.maxInt(u64)));
}

pub const Store = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    pending_input: Anchor = .{},
    active_id: ?u64 = null,
    next_id: u64 = 1,
    truncated: bool = false,
    pending_ai: ?struct { id: ExecutionId, command: []u8 } = null,
    observer: ?@import("engine.zig").CommandObserver = null,

    pub fn deinit(self: *Store) void {
        self.pending_input.deinit();
        self.clearAiSubmission();
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    pub fn registerAiSubmission(self: *Store, execution_id: ExecutionId, command: []const u8) !void {
        if (self.pending_ai != null) return error.AiSubmissionPending;
        const text = std.mem.trimEnd(u8, command, "\r\n");
        if (text.len > max_command_bytes) return error.CommandTooLarge;
        self.pending_ai = .{ .id = execution_id, .command = try self.allocator.dupe(u8, text) };
    }
    fn clearAiSubmission(self: *Store) void {
        if (self.pending_ai) |pending| self.allocator.free(pending.command);
        self.pending_ai = null;
    }
    pub fn cancelAiSubmission(self: *Store, execution_id: ExecutionId) void {
        if (self.pending_ai) |pending| if (pending.id.eql(execution_id)) self.clearAiSubmission();
    }

    /// A replacement shell cannot supply completion evidence for its predecessor.
    /// Keep the observed commands and locations, but discard every open pairing.
    pub fn abandon(self: *Store, terminal: c.GhosttyTerminal, cols: u16) void {
        self.pending_input.deinit();
        self.clearAiSubmission();
        self.active_id = null;
        for (self.entries.items) |*entry| if (entry.value.state == .running) {
            entry.value.state = .unknown;
            if (self.observer) |observer| observer.changed(observer.context, projected(entry.*, terminal, cols));
        };
    }

    pub fn observe(self: *Store, terminal: c.GhosttyTerminal, rows: u16, cols: u16, kind: @FieldType(model.Event, "kind"), shell_command: []const u8, exit_code: ?i32, wall_ms: i64, monotonic_ns: i128) void {
        // Full-screen programs cannot create shell history, and their semantic
        // markers must not close a command belonging to the primary screen.
        if (native_view.alternate(terminal)) return;
        switch (kind) {
            .cwd, .prompt_start => {},
            .input_start => {
                const point = cursor(terminal, rows) orelse return;
                // PS2 carries another B, but it belongs to the same command.
                // Read the native row's semantic prompt kind rather than
                // treating the continuation prompt's text as shell input.
                const ref = native_view.gridRef(terminal, point) catch return;
                var row: c.GhosttyRow = 0;
                var semantic: c.GhosttyRowSemanticPrompt = c.GHOSTTY_ROW_SEMANTIC_NONE;
                if (c.ghostty_grid_ref_row(&ref, &row) == c.GHOSTTY_SUCCESS) _ = c.ghostty_row_get(row, c.GHOSTTY_ROW_DATA_SEMANTIC_PROMPT, @ptrCast(&semantic));
                if (self.pending_input.native != null and semantic == c.GHOSTTY_ROW_SEMANTIC_PROMPT_CONTINUATION) return;
                self.pending_input.deinit();
                self.pending_input = Anchor.at(terminal, point, pendingWrap(terminal));
            },
            .output_start => self.start(terminal, rows, cols, shell_command, wall_ms, monotonic_ns),
            .command_end => {
                self.pending_input.deinit();
                const id = self.active_id orelse return;
                self.active_id = null;
                for (self.entries.items) |*entry| if (entry.value.id == id) {
                    entry.value.end_ms = wall_ms;
                    entry.value.elapsed_ms = elapsedMs(entry.started_ns, monotonic_ns);
                    entry.value.exit_code = exit_code;
                    entry.value.state = if (exit_code) |code| if (code == 0) .succeeded else .failed else .unknown;
                    if (self.observer) |observer| observer.changed(observer.context, projected(entry.*, terminal, cols));
                    break;
                };
            },
        }
    }

    fn start(self: *Store, terminal: c.GhosttyTerminal, rows: u16, cols: u16, shell_command: []const u8, wall_ms: i64, monotonic_ns: i128) void {
        defer self.clearAiSubmission();
        // An unpaired D must never finish an older command after a new C failed
        // to be retained. Clear the active association before any allocation.
        self.active_id = null;
        var input_start = self.pending_input;
        self.pending_input = .{};
        defer input_start.deinit();
        if (self.next_id == std.math.maxInt(u64)) {
            self.truncated = true;
            return;
        }
        const id = self.next_id;
        self.next_id += 1;
        var value: model.Command = .{ .id = id, .start_ms = wall_ms };
        const output_point = cursor(terminal, rows);
        var output_start: Anchor = .{};
        defer output_start.deinit();
        if (output_point) |point| output_start = Anchor.at(terminal, point, pendingWrap(terminal));
        var input_end: Anchor = .{};
        defer input_end.deinit();
        if (shell_command.len != 0) {
            if (shell_command.len <= max_command_bytes) value.command = self.allocator.dupe(u8, std.mem.trimEnd(u8, shell_command, "\r\n")) catch failed: {
                self.truncated = true;
                break :failed null;
            } else self.truncated = true;
        } else if (input_start.resolve(terminal, cols)) |start_point| {
            if (output_start.resolve(terminal, cols)) |end_point| {
                const captured = captureInput(terminal, cols, start_point, end_point, self.allocator) catch failed: {
                    self.truncated = true;
                    break :failed null;
                };
                if (captured) |text| value.command = text;
            }
        }
        defer if (value.command) |text| self.allocator.free(text);
        if (self.pending_ai) |pending| if (value.command) |text| {
            if (std.mem.eql(u8, pending.command, text)) value.ai_execution_id = pending.id;
        };
        // The input range ends at the last actual input cell rather than at a
        // following output line. Native semantic tags avoid prompt/echo guesses.
        if (input_start.resolve(terminal, cols)) |first| if (output_start.resolve(terminal, cols)) |last| {
            if (lastInputCell(terminal, cols, first, last)) |point| input_end = Anchor.at(terminal, point, true);
        };
        self.entries.ensureUnusedCapacity(self.allocator, 1) catch {
            self.truncated = true;
            return;
        };
        if (self.entries.items.len == max_commands) {
            var oldest = self.entries.orderedRemove(0);
            oldest.deinit(self.allocator);
            self.truncated = true;
        }
        self.entries.appendAssumeCapacity(.{ .value = value, .started_ns = monotonic_ns, .input_start = input_start, .input_end = input_end, .output_start = output_start });
        value.command = null;
        input_start = .{};
        input_end = .{};
        output_start = .{};
        self.active_id = id;
        if (self.observer) |observer| observer.changed(observer.context, projected(self.entries.items[self.entries.items.len - 1], terminal, cols));
    }

    pub fn capture(self: *Store, terminal: c.GhosttyTerminal, cols: u16, allocator: std.mem.Allocator) ![]const model.Command {
        const now_ns = @import("../platform/realtime.zig").monotonicNs();
        const commands = try allocator.alloc(model.Command, self.entries.items.len);
        var count: usize = 0;
        errdefer {
            for (commands[0..count]) |command| if (command.command) |text| allocator.free(text);
            allocator.free(commands);
        }
        for (self.entries.items, commands) |entry, *command| {
            command.* = projected(entry, terminal, cols);
            if (command.state == .running) command.elapsed_ms = elapsedMs(entry.started_ns, now_ns);
            command.command = if (entry.value.command) |text| try allocator.dupe(u8, text) else null;
            count += 1;
        }
        return commands;
    }
};

fn projected(entry: Entry, terminal: c.GhosttyTerminal, cols: u16) model.Command {
    var command = entry.value;
    if (entry.input_start.resolve(terminal, cols)) |point| {
        command.screen_row = point.row;
        command.col = point.col;
    }
    if (entry.input_end.resolve(terminal, cols)) |point| {
        command.input_end_row = point.row;
        command.input_end_col = point.col;
    }
    if (entry.output_start.resolve(terminal, cols)) |point| {
        command.output_start_row = point.row;
        command.output_start_col = point.col;
    }
    return command;
}

/// Last real native input cell in the half-open B/C range, including literal
/// trailing spaces. Output padding and continuation prompts are not input.
fn lastInputCell(terminal: c.GhosttyTerminal, cols: u16, start: Point, end: Point) ?Point {
    if (less(end, start) or end.row - start.row > max_command_bytes) return null;
    var row = end.row;
    var budget: usize = 0;
    while (true) {
        var col: u16 = if (row == end.row) @min(end.col, cols) else cols;
        const first: u16 = if (row == start.row) start.col else 0;
        while (col > first) {
            col -= 1;
            budget += 1;
            if (budget > max_command_bytes) return null;
            const ref = native_view.gridRef(terminal, .{ .space = .screen, .row = row, .col = col }) catch return null;
            var cell: c.GhosttyCell = 0;
            var has_text = false;
            var semantic: c.GhosttyCellSemanticContent = 0;
            if (c.ghostty_grid_ref_cell(&ref, &cell) != c.GHOSTTY_SUCCESS) return null;
            _ = c.ghostty_cell_get(cell, c.GHOSTTY_CELL_DATA_HAS_TEXT, @ptrCast(&has_text));
            _ = c.ghostty_cell_get(cell, c.GHOSTTY_CELL_DATA_SEMANTIC_CONTENT, @ptrCast(&semantic));
            if (has_text and semantic == c.GHOSTTY_CELL_SEMANTIC_INPUT) return .{ .space = .screen, .row = row, .col = col };
        }
        if (row == start.row) break;
        row -= 1;
    }
    return null;
}

fn captureInput(terminal: c.GhosttyTerminal, cols: u16, start: Point, end: Point, allocator: std.mem.Allocator) !?[]u8 {
    if (less(end, start)) return null;
    // A B/C pair with no retained input cells is an actual empty command only
    // when both boundaries identify the same native gap.
    const last = lastInputCell(terminal, cols, start, end) orelse {
        if (start.row == end.row and start.col == end.col) return try allocator.alloc(u8, 0);
        return null;
    };
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var row = start.row;
    var budget: usize = 0;
    var previous_wraps = true;
    while (row <= last.row) : (row += 1) {
        if (row > start.row and !previous_wraps) {
            if (output.items.len == max_command_bytes) return error.CopyTooLarge;
            try output.append(allocator, '\n');
        }
        var raw_row: c.GhosttyRow = 0;
        const row_ref = try native_view.gridRef(terminal, .{ .space = .screen, .row = row, .col = 0 });
        if (c.ghostty_grid_ref_row(&row_ref, &raw_row) != c.GHOSTTY_SUCCESS) return error.SelectionUnavailable;
        previous_wraps = false;
        _ = c.ghostty_row_get(raw_row, c.GHOSTTY_ROW_DATA_WRAP, @ptrCast(&previous_wraps));
        const first_col: u16 = if (row == start.row) @min(start.col, cols) else 0;
        const end_col: u16 = if (row == last.row) last.col + 1 else cols;
        var span_start: ?u16 = null;
        var span_end: u16 = 0;
        for (first_col..end_col) |index| {
            budget += 1;
            if (budget > max_command_bytes) return error.CopyTooLarge;
            const col: u16 = @intCast(index);
            const ref = try native_view.gridRef(terminal, .{ .space = .screen, .row = row, .col = col });
            var cell: c.GhosttyCell = 0;
            var has_text = false;
            var semantic: c.GhosttyCellSemanticContent = 0;
            if (c.ghostty_grid_ref_cell(&ref, &cell) != c.GHOSTTY_SUCCESS) return error.SelectionUnavailable;
            _ = c.ghostty_cell_get(cell, c.GHOSTTY_CELL_DATA_HAS_TEXT, @ptrCast(&has_text));
            _ = c.ghostty_cell_get(cell, c.GHOSTTY_CELL_DATA_SEMANTIC_CONTENT, @ptrCast(&semantic));
            if (!has_text) continue;
            if (semantic == c.GHOSTTY_CELL_SEMANTIC_INPUT) {
                if (span_start == null) span_start = col;
                span_end = col;
            } else if (span_start) |first| {
                try appendInputSpan(&output, allocator, terminal, row, first, span_end);
                span_start = null;
            }
        }
        if (span_start) |first| try appendInputSpan(&output, allocator, terminal, row, first, span_end);
    }
    output.shrinkRetainingCapacity(std.mem.trimEnd(u8, output.items, "\r\n").len);
    return try output.toOwnedSlice(allocator);
}

fn appendInputSpan(output: *std.ArrayList(u8), allocator: std.mem.Allocator, terminal: c.GhosttyTerminal, row: u32, first: u16, last: u16) !void {
    const text = try formatInputSpan(terminal, .{ .space = .screen, .row = row, .col = first }, .{ .space = .screen, .row = row, .col = last }, allocator, max_command_bytes - output.items.len);
    defer allocator.free(text);
    try output.appendSlice(allocator, text);
}

fn formatInputSpan(terminal: c.GhosttyTerminal, start: Point, end: Point, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
    var selected: c.GhosttySelection = .{ .size = @sizeOf(c.GhosttySelection), .start = try native_view.gridRef(terminal, start), .end = try native_view.gridRef(terminal, end), .rectangle = false };
    const options: c.GhosttyTerminalSelectionFormatOptions = .{ .size = @sizeOf(c.GhosttyTerminalSelectionFormatOptions), .emit = c.GHOSTTY_FORMATTER_FORMAT_PLAIN, .unwrap = true, .trim = false, .selection = &selected };
    var needed: usize = 0;
    const query = c.ghostty_terminal_selection_format_buf(terminal, options, null, 0, &needed);
    if (query != c.GHOSTTY_SUCCESS and query != c.GHOSTTY_OUT_OF_SPACE) return error.SelectionUnavailable;
    if (needed > max_bytes) return error.CopyTooLarge;
    var text = try allocator.alloc(u8, needed);
    errdefer allocator.free(text);
    var written: usize = 0;
    if (c.ghostty_terminal_selection_format_buf(terminal, options, text.ptr, text.len, &written) != c.GHOSTTY_SUCCESS) return error.SelectionUnavailable;
    if (written != text.len) text = try allocator.realloc(text, written);
    return text;
}
