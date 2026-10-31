//! Native input and selection for TerminalSurface. No shell or VT parser.
const std = @import("std");
const ui = @import("ui");
const terminal = @import("../host/terminal_service.zig");
const Surface = @import("terminal_surface.zig").Surface;
const absolute = @import("terminal_surface.zig").absolute;
const ascii_bytes: [128]u8 = blk: {
    var value: [128]u8 = undefined;
    for (&value, 0..) |*byte, i| byte.* = @intCast(i);
    break :blk value;
};
const Time = extern struct { sec: c_int, min: c_int, hour: c_int, day: c_int, month: c_int, year: c_int, week_day: c_int, year_day: c_int, daylight: c_int, offset: c_long, zone: ?[*:0]const u8 };
extern "c" fn localtime_r(*const c_long, *Time) ?*Time;
pub fn localTimestamp(out: *[8]u8, wall_ms: i64) ![]const u8 {
    const seconds: c_long = @intCast(@divFloor(wall_ms, 1000));
    var time: Time = undefined;
    if (localtime_r(&seconds, &time) == null) return error.TimestampUnavailable;
    if (time.hour < 0 or time.hour > 23 or time.min < 0 or time.min > 59 or time.sec < 0 or time.sec > 60) return error.TimestampUnavailable;
    out.* = .{ @intCast(48 + @divTrunc(time.hour, 10)), @intCast(48 + @mod(time.hour, 10)), ':', @intCast(48 + @divTrunc(time.min, 10)), @intCast(48 + @mod(time.min, 10)), ':', @intCast(48 + @divTrunc(time.sec, 10)), @intCast(48 + @mod(time.sec, 10)) };
    return out;
}
pub fn localDateTimestamp(out: *[19]u8, wall_ms: i64) ![]const u8 {
    const seconds: c_long = @intCast(@divFloor(wall_ms, 1000));
    var time: Time = undefined;
    if (localtime_r(&seconds, &time) == null) return error.TimestampUnavailable;
    const year = time.year + 1900;
    if (year < 0 or year > 9999) return error.TimestampUnavailable;
    return std.fmt.bufPrint(out, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ @as(u32, @intCast(year)), @as(u32, @intCast(time.month + 1)), @as(u32, @intCast(time.day)), @as(u32, @intCast(time.hour)), @as(u32, @intCast(time.min)), @as(u32, @intCast(time.sec)) });
}
pub fn onKey(self: *Surface, key: ui.events.KeyCode, modifiers: ui.events.Modifiers) ui.events.EventResult {
    if (self.preedit.len != 0) return .stop;
    if (self.pending_paste != null or self.paste_requested != null) {
        if (key == .escape) cancelPaste(self) else if (key == .@"return") approvePaste(self);
        return .stop;
    }
    if (modifiers.super) {
        if (key == .c) {
            const selected = hasSelection(self) catch |err| {
                self.showError(err);
                return .stop;
            };
            if (selected) copySelection(self) catch |err| self.showError(err) else enqueueKey(self, .{ .key = .c, .modifiers = .{ .control = true }, .utf8 = "c", .unshifted_codepoint = 'c' }) catch |err| self.showError(err);
            return .stop;
        }
        if (key == .v) {
            pasteClipboard(self);
            return .stop;
        }
        return .ignored;
    }
    if (self.snapshot == null or self.snapshot.?.read_only) return .stop;
    const mapped = keyFrom(key) orelse return .ignored;
    // Printable text comes only through the native text client. Modified
    // shortcuts and non-text keys use Ghostty's actual mode-aware encoder.
    if (!modifiers.ctrl and !modifiers.alt and isPrintable(key)) return .ignored;
    const ascii = asciiFor(key);
    // The mailbox owns queued bytes; avoid storing this stack slice in a key.
    // Control-letter encoding needs only the stable physical key/codepoint.
    enqueueKey(self, .{ .key = mapped, .modifiers = mods(modifiers), .unshifted_codepoint = ascii, .utf8 = if (modifiers.alt and ascii > 0 and ascii < 128) ascii_bytes[ascii..][0..1] else "" }) catch |err| self.showError(err);
    return .stop;
}
fn enqueueKey(self: *Surface, event: terminal.KeyEvent) !void {
    if (self.control_grant != null) return error.TerminalControlled;
    if (self.snapshot == null or self.snapshot.?.read_only) return error.ReadOnlyTerminal;
    if (self.pending.items.len >= 256) return error.InputQueueFull;
    if (self.timing) |trace| trace.begin(self.next_input + self.pending.items.len);
    try self.pending.append(self.cx.allocator, .{ .key = event });
    try self.pump();
}
pub fn onEvent(self: *Surface, event: ui.events.Event) ui.events.EventResult {
    switch (event) {
        .key_down => |key| {
            if (key.key == .unknown) if (numpadFromRaw(key.raw_keycode)) |mapped| {
                if (self.preedit.len == 0) enqueueKey(self, .{ .key = mapped, .modifiers = mods(key.modifiers) }) catch |err| self.showError(err);
                return .stop;
            };
        },
        .key_up => |key| {
            if (self.snapshot != null and self.snapshot.?.projection.modes.kitty_keyboard_flags & 2 != 0 and self.preedit.len == 0) {
                if (numpadFromRaw(key.raw_keycode) orelse keyFrom(key.key)) |mapped| enqueueKey(self, .{ .key = mapped, .action = .release, .modifiers = mods(key.modifiers), .unshifted_codepoint = asciiFor(key.key) }) catch |err| self.showError(err);
            }
        },
        .text_input => |value| {
            if (self.preedit.len == 0 and self.pending_paste == null and self.paste_requested == null) self.queueText(value.text) catch |err| self.showError(err);
            return .stop;
        },
        .ime_preedit => |value| {
            if (self.snapshot != null and !self.snapshot.?.read_only and self.pending_paste == null and self.paste_requested == null) {
                self.setPreedit(value.text);
                const cursor = @min(value.cursor_utf8_offset, self.preedit.len);
                if (std.unicode.utf8ValidateSlice(self.preedit[0..cursor])) self.preedit_cursor = @intCast(cursor);
            }
            return .stop;
        },
        .ime_commit => |value| {
            self.setPreedit("");
            if (self.pending_paste == null and self.paste_requested == null) self.queueText(value.text) catch |err| self.showError(err);
            return .stop;
        },
        .blur => {
            self.setPreedit("");
            if (self.dragging) self.cx.releasePointerCapture();
            self.dragging = false;
            if (self.modal_open == null or !self.modal_open.?.get()) cancelPaste(self);
            return .ignored;
        },
        .double_click => |mouse| {
            if (mouse.button != .left or mouse.modifiers.alt or reportsMouse(self)) return .ignored;
            selectWord(self, mouse.x, mouse.y) catch |err| {
                if (err == error.StaleProjection) {
                    self.force_snapshot = true;
                    self.cx.requestRedraw();
                } else self.showError(err);
            };
            return .stop;
        },
        .mouse_down => |mouse| {
            self.cx.setFocus(self.host);
            if (reportsMouse(self) and !mouse.modifiers.alt) {
                const button: @FieldType(terminal.MouseEvent, "button") = switch (mouse.button) {
                    .left => .left,
                    .right => .right,
                    .middle => .middle,
                };
                mouseReport(self, .press, button, mouse.x, mouse.y, mouse.modifiers) catch |err| self.showError(err);
                self.mouse_reporting = true;
                self.reported_button = button;
                self.cx.setPointerCapture(self.host);
                return .stop;
            }
            switch (mouse.button) {
                .right => {
                    pasteClipboard(self);
                    return .stop;
                },
                .middle => {
                    if (self.menu_handler) |handler| {
                        handler.request(handler.context, self.owner, mouse.x, mouse.y);
                        return .stop;
                    }
                    return .ignored;
                },
                .left => {},
            }
            clearSelection(self);
            self.rectangle = mouse.modifiers.alt;
            // A focus click does not select text. Only create versioned anchors
            // once the pointer actually drags, avoiding stale-frame errors on clicks.
            self.drag_origin = .{ .x = mouse.x, .y = mouse.y };
            self.dragging = true;
            self.cx.setPointerCapture(self.host);
            return .stop;
        },
        .mouse_move => |mouse| {
            if (self.mouse_reporting or (reportsMouse(self) and self.snapshot.?.projection.modes.mouse_tracking == .any)) {
                mouseReport(self, .motion, if (self.mouse_reporting) self.reported_button else .none, mouse.x, mouse.y, mouse.modifiers) catch |err| self.showError(err);
                return .stop;
            }
            if (self.dragging) {
                if (self.selection == null) {
                    if (@abs(mouse.x - self.drag_origin.x) < 3 and @abs(mouse.y - self.drag_origin.y) < 3) return .stop;
                    beginSelection(self, self.drag_origin.x, self.drag_origin.y) catch |err| {
                        if (err == error.StaleProjection) {
                            self.force_snapshot = true;
                            self.cx.requestRedraw();
                        } else self.showError(err);
                        return .stop;
                    };
                }
                updateSelection(self, mouse.x, mouse.y) catch |err| self.showError(err);
                return .stop;
            }
        },
        .mouse_up => |mouse| {
            if (!self.mouse_reporting and mouse.button != .left) return .ignored;
            defer self.cx.releasePointerCapture();
            if (self.mouse_reporting) {
                mouseReport(self, .release, self.reported_button, mouse.x, mouse.y, mouse.modifiers) catch |err| self.showError(err);
                self.mouse_reporting = false;
                self.reported_button = .none;
            }
            if (self.dragging) {
                if (self.selection == null) {
                    self.dragging = false;
                    return .stop;
                }
                updateSelection(self, mouse.x, mouse.y) catch |err| {
                    self.dragging = false;
                    self.showError(err);
                    return .stop;
                };
                self.dragging = false;
                const selected = hasSelection(self) catch |err| {
                    self.showError(err);
                    return .stop;
                };
                if (selected) copySelection(self) catch |err| self.showError(err);
            }
            return .stop;
        },
        .scroll => |wheel| {
            self.scrollbar_until = self.cx.frame_time_ms + 900;
            if (self.snapshot == null) return .stop;
            if (!self.snapshot.?.projection.modes.alternate_screen and (!reportsMouse(self) or wheel.modifiers.alt)) {
                self.pending_scroll -= wheel.dy;
                self.force_snapshot = true;
                self.cx.requestRedraw();
                return .stop;
            }
            // Zenit preserves AppKit's positive-up delta (as ScrollArea does);
            // Ghostty viewport deltas and terminal wheel encodings use up < 0.
            self.wheel_remainder -= wheel.dy / self.options.row_height;
            const delta: i32 = @intFromFloat(@trunc(self.wheel_remainder));
            if (delta == 0) return .stop;
            self.wheel_remainder -= @floatFromInt(delta);
            {
                if (reportsMouse(self) and !wheel.modifiers.alt) {
                    var count: u32 = @intCast(@min(@abs(delta), 64));
                    while (count > 0) : (count -= 1) mouseReport(self, .press, if (delta < 0) .four else .five, wheel.x, wheel.y, wheel.modifiers) catch |err| self.showError(err);
                } else if (self.snapshot.?.projection.modes.alternate_scroll) {
                    var count: u32 = @intCast(@min(@abs(delta), 64));
                    while (count > 0) : (count -= 1) enqueueKey(self, .{ .key = if (delta < 0) .arrow_up else .arrow_down }) catch |err| self.showError(err);
                }
            }
            return .stop;
        },
        else => {},
    }
    return .ignored;
}
fn reportsMouse(self: *Surface) bool {
    return self.control_grant == null and self.snapshot != null and !self.snapshot.?.read_only and self.snapshot.?.projection.modes.mouse_tracking != .none;
}
fn mouseReport(self: *Surface, action: @FieldType(terminal.MouseEvent, "action"), button: @FieldType(terminal.MouseEvent, "button"), x: f32, y: f32, modifiers: ui.events.Modifiers) !void {
    if (self.control_grant != null) return error.TerminalControlled;
    if (self.snapshot == null or self.pending.items.len >= 256) return error.InputQueueFull;
    const rect = self.root.globalRect();
    const value = self.snapshot.?;
    try self.pending.append(self.cx.allocator, .{ .mouse = .{ .input_sequence = self.next_input, .mode_revision = value.projection.mode_revision, .geometry_revision = value.geometry_revision, .event = .{ .action = action, .button = button, .modifiers = mods(modifiers), .x = @max(0, x - rect.x - self.contentPadding().left - self.bodyX()), .y = @max(0, y - rect.y - self.contentPadding().top), .screen_width = @intFromFloat(@as(f32, @floatFromInt(value.projection.cols)) * self.options.cell_width), .screen_height = @intFromFloat(@as(f32, @floatFromInt(value.projection.rows)) * self.options.row_height), .cell_width = @intFromFloat(@max(1, self.options.cell_width)), .cell_height = @intFromFloat(@max(1, self.options.row_height)), .any_button_pressed = self.mouse_reporting } } });
    try self.pump();
}
fn pointAt(self: *Surface, x: f32, y: f32) !terminal.Point {
    const snapshot = self.snapshot orelse return error.SnapshotUnavailable;
    // Native pointer and text-input-client points are window logical values.
    // Layout rects are parent-local; include the pane's ancestor offsets once.
    const rect = self.root.globalRect();
    const local_y = y - rect.y - self.contentPadding().top;
    var row: u32 = 0;
    for (snapshot.projection.visible_rows) |line| {
        const top = self.presentationY(line.viewport_y);
        if (local_y < top - line.presentation.before * 0.5 and line.viewport_y > 0) break;
        row = line.viewport_y;
        if (local_y < top + self.options.row_height) break;
    }
    const shift = snapshot.projection.visible_rows[row].presentation.shift_x;
    var col: u16 = @intFromFloat(std.math.clamp(@floor((x - rect.x - self.contentPadding().left - self.bodyX() - shift) / self.options.cell_width + 0.5), 0, @as(f32, @floatFromInt(snapshot.projection.cols))));
    for (snapshot.projection.visible_rows) |line| if (line.viewport_y == row and col < line.cell_count) {
        if (snapshot.projection.cells[line.cell_start + col].width == .wide_tail and col > 0) col -= 1;
    };
    return .{ .row = row, .col = col, .source_version = snapshot.projection.version };
}
fn beginSelection(self: *Surface, x: f32, y: f32) !void {
    const point = try pointAt(self, x, y);
    const start = try self.service.createAnchor(point);
    errdefer self.releaseAnchorLater(start);
    const end = try self.service.createAnchor(point);
    self.selection = .{ .start = start, .end = end, .rectangle = self.rectangle };
    self.force_snapshot = true;
}
// File names and paths are uninterrupted terminal tokens. Punctuation such as
// '.', '-', '+', and '/' is deliberately retained; only whitespace separates.
fn wordBoundary(projection: terminal.Projection, row: usize, col: u16) bool {
    const line = projection.visible_rows[row];
    if (col >= line.cell_count) return true;
    const cell = projection.cells[line.cell_start + col];
    if (cell.width == .wide_tail) return false;
    const text = projection.grapheme(cell);
    if (text.len == 0) return true;
    const cp = std.unicode.utf8Decode(text[0 .. std.unicode.utf8ByteSequenceLength(text[0]) catch return true]) catch return true;
    return switch (cp) {
        0...32, 0x7f, 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}
fn selectWord(self: *Surface, x: f32, y: f32) !void {
    const projection = (self.snapshot orelse return error.SnapshotUnavailable).projection;
    if (projection.visible_rows.len == 0) return;
    // Drag selection rounds to the closest boundary; a double click targets
    // the cell under the pointer, including its right half.
    const point = try pointAt(self, x - self.options.cell_width * 0.5, y);
    var first_row: usize = point.row;
    var first_col = point.col;
    if (wordBoundary(projection, first_row, first_col)) return;
    var last_row = first_row;
    var last_col = first_col;
    while (true) {
        if (first_col > 0) {
            if (wordBoundary(projection, first_row, first_col - 1)) break;
            first_col -= 1;
        } else {
            if (first_row == 0 or !projection.visible_rows[first_row].continuation or !projection.visible_rows[first_row - 1].wraps) break;
            const previous = projection.visible_rows[first_row - 1];
            if (previous.cell_count == 0 or wordBoundary(projection, first_row - 1, previous.cell_count - 1)) break;
            first_row -= 1;
            first_col = previous.cell_count - 1;
        }
    }
    while (true) {
        last_col += 1;
        const line = projection.visible_rows[last_row];
        if (last_col < line.cell_count) {
            if (wordBoundary(projection, last_row, last_col)) break;
        } else {
            if (!line.wraps or last_row + 1 >= projection.visible_rows.len or !projection.visible_rows[last_row + 1].continuation or wordBoundary(projection, last_row + 1, 0)) break;
            last_row += 1;
            last_col = 0;
        }
    }
    const anchors = blk: {
        const start = try self.service.createAnchor(.{ .row = @intCast(first_row), .col = first_col, .source_version = projection.version });
        errdefer self.releaseAnchorLater(start);
        const end = try self.service.createAnchor(.{ .row = @intCast(last_row), .col = last_col, .source_version = projection.version });
        break :blk .{ .start = start, .end = end };
    };
    clearSelection(self);
    self.selection = .{ .start = anchors.start, .end = anchors.end, .rectangle = false };
    try renderSelection(self);
    self.cx.requestRedraw();
    try copySelection(self);
}
fn updateSelection(self: *Surface, x: f32, y: f32) !void {
    const previous = self.selection orelse return;
    const end = self.service.createAnchor(try pointAt(self, x, y)) catch |err| {
        if (err == error.StaleProjection) self.force_snapshot = true;
        return err;
    };
    self.selection.?.end = end;
    self.releaseAnchorLater(previous.end);
    try renderSelection(self);
    self.cx.requestRedraw();
}
pub fn clearSelection(self: *Surface) void {
    if (self.selection) |selection| {
        self.releaseAnchorLater(selection.start);
        self.releaseAnchorLater(selection.end);
    }
    self.selection = null;
    if (self.dragging) self.cx.releasePointerCapture();
    self.dragging = false;
    for (self.rows.items) |row| row.selected.setDisplay(.none);
}
const ResolvedSelection = struct { selection: terminal.Selection, start: terminal.AnchorPosition, end: terminal.AnchorPosition };
fn resolveSelection(self: *Surface) !?ResolvedSelection {
    const selection = self.selection orelse return null;
    const start = (self.service.resolveAnchor(selection.start) catch |err| {
        if (err == error.WorkerBusy) {
            self.force_snapshot = true;
            return err;
        }
        clearSelection(self);
        return null;
    }) orelse {
        clearSelection(self);
        return null;
    };
    const end = (self.service.resolveAnchor(selection.end) catch |err| {
        if (err == error.WorkerBusy) {
            self.force_snapshot = true;
            return err;
        }
        clearSelection(self);
        return null;
    }) orelse {
        clearSelection(self);
        return null;
    };
    if (start.alternate_screen != end.alternate_screen or (self.snapshot != null and start.alternate_screen != self.snapshot.?.projection.modes.alternate_screen)) {
        clearSelection(self);
        return null;
    }
    const collapsed = if (selection.rectangle) start.col == end.col else start.row == end.row and start.col == end.col;
    if (collapsed) {
        if (!self.dragging) clearSelection(self);
        return null;
    }
    return .{ .selection = selection, .start = start, .end = end };
}
pub fn hasSelection(self: *Surface) !bool {
    const selected = try resolveSelection(self);
    return selected != null;
}
pub fn renderSelection(self: *Surface) !void {
    for (self.rows.items) |row| row.selected.setDisplay(.none);
    const selected = (resolveSelection(self) catch |err| {
        if (err == error.WorkerBusy) return;
        return err;
    }) orelse return;
    const selection = selected.selection;
    const start = selected.start;
    const end = selected.end;
    const snapshot = self.snapshot orelse return;
    if (start.source_version != snapshot.projection.version or end.source_version != snapshot.projection.version) {
        self.force_snapshot = true;
        return;
    }
    var a = start;
    var b = end;
    if (b.row < a.row or (b.row == a.row and b.col < a.col)) std.mem.swap(terminal.AnchorPosition, &a, &b);
    const offset = snapshot.projection.scrollback.viewport_offset;
    for (self.rows.items, 0..) |row, index| {
        const absolute_row = offset + index;
        if (absolute_row < a.row or absolute_row > b.row) continue;
        const left = if (selection.rectangle) @min(a.col, b.col) else if (absolute_row == a.row) a.col else 0;
        const right = if (selection.rectangle) @max(a.col, b.col) else if (absolute_row == b.row) b.col else snapshot.projection.cols;
        if (right <= left) continue;
        try absolute(self.cx, row.selected, self.bodyX() + row.layout.shift_x + @as(f32, @floatFromInt(left)) * self.options.cell_width, 0, @as(f32, @floatFromInt(right - left)) * self.options.cell_width, self.options.row_height);
        row.selected.setDisplay(.flex);
    }
}
pub fn copySelection(self: *Surface) !void {
    const text = (try copySelectionText(self, self.cx.allocator)) orelse return error.NoSelection;
    defer self.cx.allocator.free(text);
    try self.copySelectionToClipboard(text);
}
pub fn copySelectionText(self: *Surface, allocator: std.mem.Allocator) !?[]u8 {
    const selected = (try resolveSelection(self)) orelse return null;
    return self.service.selectionText(selected.selection, allocator, 1024 * 1024) catch |err| {
        if (err != error.WorkerBusy) clearSelection(self);
        return err;
    };
}
pub fn pasteClipboard(self: *Surface) void {
    // A gesture during a busy worker asks the user to retry; it must not stage
    // an unseen paste that executes after the interaction has ended.
    _ = self.service.status() catch |err| {
        self.showError(err);
        return;
    };
    const text = (ui.platform_services.clipboardGetTextAllocChecked(self.cx.system_sdk, self.cx.allocator) catch |err| {
        self.showError(err);
        return;
    }) orelse return;
    defer self.cx.allocator.free(text);
    if (text.len > 1024 * 1024) {
        self.showError(error.PasteTooLarge);
        return;
    }
    requestPaste(self, text) catch |err| self.showError(err);
}
pub fn requestPaste(self: *Surface, text: []const u8) !void {
    if (self.control_grant != null) return error.TerminalControlled;
    if (self.enhancement) |handler| if (handler.text(handler.context, text)) return;
    if (self.pending_paste != null or self.paste_requested != null) return error.PendingPaste;
    if ((terminal.PastePolicy{}).inspect(text) == .reject) return error.InvalidPaste;
    // Freeze bytes immediately; preparation may retry while worker owns VT.
    const copy = try self.cx.allocator.dupe(u8, text);
    self.paste_requested = copy;
    self.broadcast_paste_stamp = if (self.shell_observer) |observer| observer.paste_stamp(observer.context, self.owner) else 0;
    try pumpPaste(self);
}
pub fn pumpPaste(self: *Surface) !void {
    if (self.control_grant != null) {
        cancelPaste(self);
        return;
    }
    if (self.paste_requested) |bytes| {
        if (self.pending.items.len > 0) return;
        self.pending_paste = self.service.preparePaste(self.cx.allocator, bytes) catch |err| {
            if (err == error.WorkerBusy) return;
            self.cx.allocator.free(bytes);
            self.paste_requested = null;
            return err;
        };
        self.cx.allocator.free(bytes);
        self.paste_requested = null;
        if (self.pending_paste.?.requires_confirmation) try showPasteModal(self) else self.paste_confirmed = true;
    }
    if (self.pending_paste) |paste| {
        if (!self.paste_confirmed) return;
        if (self.shell_observer) |observer| if (self.broadcast_paste_stamp != observer.paste_stamp(observer.context, self.owner)) {
            cancelPaste(self);
            return error.StaleMode;
        };
        const admitted = self.service.commitPaste(paste, self.next_input, self.paste_confirmed) catch |err| {
            if (err == error.WorkerBusy or err == error.InputQueueFull or err == error.ReceiptQueueFull) return;
            cancelPaste(self);
            return err;
        };
        if (admitted.queued_bytes > 0) self.noteUserInputAccepted();
        if (self.shell_observer) |observer| observer.accepted(observer.context, self.owner, self.next_input, .{ .paste = paste.text });
        self.next_input = try std.math.add(u64, self.next_input, 1);
        cancelPaste(self);
    }
}
pub fn cancelPaste(self: *Surface) void {
    if (self.pending_paste) |*paste| paste.deinit(self.cx.allocator);
    self.pending_paste = null;
    if (self.paste_requested) |bytes| self.cx.allocator.free(bytes);
    self.paste_requested = null;
    self.paste_confirmed = false;
    if (self.modal_open) |open| open.set(false);
}
fn approvePaste(self: *Surface) void {
    self.paste_confirmed = true;
    if (self.modal_open) |open| open.set(false);
    pumpPaste(self) catch |err| self.showError(err);
}
fn cancelClick(self: *Surface) void {
    cancelPaste(self);
    self.cx.setFocus(self.host);
}
fn approveClick(self: *Surface) void {
    approvePaste(self);
    self.cx.setFocus(self.host);
}
fn modalChanged(self: *Surface, open: bool) void {
    if (!open and !self.paste_confirmed) cancelPaste(self);
}
fn showPasteModal(self: *Surface) !void {
    if (self.modal == null) {
        const scope = try ui.Scope.init(self.cx.allocator, null, self.cx.owner);
        errdefer scope.dispose();
        const open = try scope.createSignal(bool, false);
        const modal = try ui.widgets.Modal(.{ .open = open, .width = 480, .max_height = 520, .close_on_overlay = false, .on_open_change = self.cx.on(Surface, self, modalChanged) }).mount(scope, self.cx);
        const heading = try ui.box(self.cx, .{ .width = .fill(), .direction = .row, .align_items = .center, .gap = 8, .flex_shrink = 0 }, .{});
        heading.meta.ownership.meta.test_id = "terminal.paste.heading";
        try heading.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.clipboard_paste, @import("app_theme.zig").current().warn_ink, .{ .width = .{ .px = 18 }, .height = .{ .px = 18 }, .flex_shrink = 0 }));
        try heading.appendChild(self.cx.allocator, try ui.text(self.cx, "确认多行粘贴", .{ .font_size = 15, .font_weight = 700, .color = @import("app_theme.zig").current().fg_1 }));
        try modal.body.appendChild(self.cx.allocator, heading);
        try modal.body.appendChild(self.cx.allocator, try ui.text(self.cx, "以下原文将插入当前终端。广播开启时，也会发送给已批准的接收终端；换行可能提交命令，尾部不会额外追加回车。", .{ .font_size = 12, .wrap = .word }));
        const scroll = try ui.widgets.ScrollArea(.{ .height = 260, .direction = .vertical }).mount(scope, self.cx);
        const text = try ui.text(self.cx, "", .{ .font_size = 12, .use_monospace_font = true, .wrap = .word });
        try scroll.content.appendChild(self.cx.allocator, text);
        try modal.body.appendChild(self.cx.allocator, scroll.container);
        const buttons = try ui.hstack(self.cx, .{ .gap = 8 }, .{});
        try buttons.appendChild(self.cx.allocator, try ui.widgets.Button(.{ .label = "取消", .on_click = self.cx.on(Surface, self, cancelClick) }).mount(scope, self.cx));
        try buttons.appendChild(self.cx.allocator, try ui.widgets.Button(.{ .label = "确认插入", .variant = .primary, .on_click = self.cx.on(Surface, self, approveClick) }).mount(scope, self.cx));
        try modal.body.appendChild(self.cx.allocator, buttons);
        if (!modal.portaled) try self.host.appendChild(self.cx.allocator, modal.overlay);
        self.modal_scope = scope;
        self.modal_open = open;
        self.modal = modal;
        self.modal_text = text;
    }
    try self.modal_text.?.setTextContent(self.cx.allocator, self.pending_paste.?.text);
    self.modal_open.?.set(true);
}
pub fn buildDocument(self: *Surface) !void {
    self.document.clearRetainingCapacity();
    const snapshot = self.snapshot orelse return;
    for (snapshot.projection.visible_rows) |row| {
        const cells = snapshot.projection.cells[row.cell_start..][0..row.cell_count];
        for (cells, 0..) |cell, col| {
            if (cell.width == .wide_tail) continue;
            if (row.viewport_y == snapshot.projection.cursor.row and col == snapshot.projection.cursor.col) {
                self.caret_byte = @intCast(self.document.items.len);
                try self.document.appendSlice(self.cx.allocator, self.preedit);
            }
            const text = snapshot.projection.grapheme(cell);
            try self.document.appendSlice(self.cx.allocator, if (text.len > 0) text else " ");
        }
        if (snapshot.projection.cursor.row == row.viewport_y and snapshot.projection.cursor.col >= row.cell_count) {
            self.caret_byte = @intCast(self.document.items.len);
            try self.document.appendSlice(self.cx.allocator, self.preedit);
        }
        if (@as(usize, row.viewport_y) + 1 < snapshot.projection.visible_rows.len) try self.document.append(self.cx.allocator, '\n');
    }
}
pub fn frameForRange(self: *Surface, start: u32, _: u32, out: *ui.types.A11yRect) bool {
    const snapshot = self.snapshot orelse return false;
    const rect = self.root.globalRect();
    var row: u32 = snapshot.projection.cursor.row;
    var col: f32 = @floatFromInt(snapshot.projection.cursor.col);
    if (start >= self.caret_byte and start <= self.caret_byte + self.preedit.len) {
        const count = @min(start - self.caret_byte, self.preedit.len);
        if (std.unicode.utf8ValidateSlice(self.preedit[0..count])) col += self.measured(self.preedit[0..count]) / self.options.cell_width;
    } else {
        var offset: usize = 0;
        for (snapshot.projection.visible_rows) |line| {
            const cells = snapshot.projection.cells[line.cell_start..][0..line.cell_count];
            for (cells, 0..) |cell, index| {
                if (cell.width == .wide_tail) continue;
                const len = @max(@as(usize, 1), snapshot.projection.grapheme(cell).len);
                if (start >= offset and start < offset + len) {
                    row = line.viewport_y;
                    col = @floatFromInt(index);
                    break;
                }
                offset += len;
            }
            offset += 1;
        }
    }
    out.* = .{ .x = rect.x + self.contentPadding().left + self.bodyX() + col * self.options.cell_width, .y = rect.y + self.contentPadding().top + self.presentationY(row), .width = self.options.cell_width, .height = self.options.row_height };
    return true;
}
pub fn rangeAtPoint(self: *Surface, x: f32, y: f32, start: *u32, end: *u32) bool {
    const point = pointAt(self, x, y) catch return false;
    var offset: u32 = 0;
    const snapshot = self.snapshot orelse return false;
    for (snapshot.projection.visible_rows) |row| {
        for (snapshot.projection.cells[row.cell_start..][0..row.cell_count], 0..) |cell, col| {
            if (cell.width == .wide_tail) continue;
            const len: u32 = @intCast(@max(@as(usize, 1), snapshot.projection.grapheme(cell).len));
            if (row.viewport_y == point.row and col >= point.col) {
                start.* = offset;
                end.* = offset + len;
                return true;
            }
            offset += len;
        }
        offset += 1;
    }
    return false;
}
fn mods(value: ui.events.Modifiers) @import("../vt/input_event.zig").Modifiers {
    return .{ .shift = value.shift, .control = value.ctrl, .alt = value.alt, .super = value.super };
}
fn isPrintable(key: ui.events.KeyCode) bool {
    return asciiFor(key) != 0 or key == .space;
}
fn asciiFor(key: ui.events.KeyCode) u21 {
    return switch (key) {
        .a => 'a',
        .b => 'b',
        .c => 'c',
        .d => 'd',
        .e => 'e',
        .f => 'f',
        .g => 'g',
        .h => 'h',
        .i => 'i',
        .j => 'j',
        .k => 'k',
        .l => 'l',
        .m => 'm',
        .n => 'n',
        .o => 'o',
        .p => 'p',
        .q => 'q',
        .r => 'r',
        .s => 's',
        .t => 't',
        .u => 'u',
        .v => 'v',
        .w => 'w',
        .x => 'x',
        .y => 'y',
        .z => 'z',
        .@"0" => '0',
        .@"1" => '1',
        .@"2" => '2',
        .@"3" => '3',
        .@"4" => '4',
        .@"5" => '5',
        .@"6" => '6',
        .@"7" => '7',
        .@"8" => '8',
        .@"9" => '9',
        .space => ' ',
        .slash => '/',
        .minus => '-',
        .equal => '=',
        .left_bracket => '[',
        .right_bracket => ']',
        .period => '.',
        .comma => ',',
        .semicolon => ';',
        .quote => '\'',
        .backslash => '\\',
        .grave => '`',
        else => 0,
    };
}
fn keyFrom(key: ui.events.KeyCode) ?@import("../vt/input_event.zig").Key {
    return switch (key) {
        .@"return" => .enter,
        .delete => .backspace,
        .forward_delete => .delete,
        .left => .arrow_left,
        .right => .arrow_right,
        .up => .arrow_up,
        .down => .arrow_down,
        .home => .home,
        .end => .end,
        .page_up => .page_up,
        .page_down => .page_down,
        .escape => .escape,
        .tab => .tab,
        .space => .space,
        .@"0" => .digit_0,
        .@"1" => .digit_1,
        .@"2" => .digit_2,
        .@"3" => .digit_3,
        .@"4" => .digit_4,
        .@"5" => .digit_5,
        .@"6" => .digit_6,
        .@"7" => .digit_7,
        .@"8" => .digit_8,
        .@"9" => .digit_9,
        .left_bracket => .bracket_left,
        .right_bracket => .bracket_right,
        .grave => .backquote,
        else => std.meta.stringToEnum(@import("../vt/input_event.zig").Key, @tagName(key)),
    };
}
fn numpadFromRaw(code: u16) ?@import("../vt/input_event.zig").Key {
    return switch (code) {
        65 => .numpad_decimal,
        67 => .numpad_multiply,
        69 => .numpad_add,
        75 => .numpad_divide,
        76 => .numpad_enter,
        78 => .numpad_subtract,
        81 => .numpad_equal,
        82 => .numpad_0,
        83 => .numpad_1,
        84 => .numpad_2,
        85 => .numpad_3,
        86 => .numpad_4,
        87 => .numpad_5,
        88 => .numpad_6,
        89 => .numpad_7,
        91 => .numpad_8,
        92 => .numpad_9,
        else => null,
    };
}
