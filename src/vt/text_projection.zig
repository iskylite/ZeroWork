const std = @import("std");
const VtEngine = @import("engine.zig").VtEngine;
const Cell = @import("cell.zig").Cell;

/// Projects the visible VT grid into owned UTF-8 text for TerminalViewNode.
pub fn renderVisibleText(engine: VtEngine, allocator: std.mem.Allocator) ![]u8 {
    return renderVisibleTextWithGutter(engine, allocator, .{});
}

/// Projects viewport text with an optional timestamp prefix per line.
/// The default keeps the historical no-gutter rendering contract.
pub fn renderVisibleTextWithGutter(engine: VtEngine, allocator: std.mem.Allocator, gutter: @import("../ui/timestamp_gutter.zig").Gutter) ![]u8 {
    const snapshot = engine.snapshot();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    for (0..snapshot.rows) |row_index| {
        const line = engine.lineAt(snapshot.scroll_offset + row_index) orelse {
            if (row_index + 1 < snapshot.rows) try output.append(allocator, '\n');
            continue;
        };
        var plain_list: std.ArrayList(u8) = .empty;
        defer plain_list.deinit(allocator);
        try appendTrimmedLine(&plain_list, allocator, line.cells);
        if (gutter.enabled) {
            var line_buffer: [4096]u8 = undefined;
            const rendered = try @import("../ui/timestamp_gutter.zig").prefixLine(gutter, &line_buffer, line.received_at_ms, plain_list.items);
            try output.appendSlice(allocator, rendered);
        } else {
            try output.appendSlice(allocator, plain_list.items);
        }
        if (row_index + 1 < snapshot.rows) try output.append(allocator, '\n');
    }
    return output.toOwnedSlice(allocator);
}

fn appendTrimmedLine(output: *std.ArrayList(u8), allocator: std.mem.Allocator, cells: []const Cell) !void {
    var end = cells.len;
    while (end > 0 and isBlank(cells[end - 1])) end -= 1;
    for (cells[0..end]) |cell| {
        if (cell.width == .wide_tail) continue;
        var bytes: [4]u8 = undefined;
        const codepoint: u21 = if (cell.codepoint == 0) ' ' else cell.codepoint;
        const count = std.unicode.utf8Encode(codepoint, &bytes) catch {
            try output.appendSlice(allocator, "�");
            continue;
        };
        try output.appendSlice(allocator, bytes[0..count]);
    }
}

fn isBlank(cell: Cell) bool {
    return cell.width == .wide_tail or cell.codepoint == 0 or cell.codepoint == ' ';
}

fn blankCells() [12]Cell {
    var cells: [12]Cell = undefined;
    for (&cells) |*cell| cell.* = Cell.blank();
    return cells;
}

const FakeEngine = struct {
    cells: [12]Cell = blankCells(),
    versions: [1]u64 = .{1},
    pub fn destroy(_: *FakeEngine) void {}
    pub fn feed(_: *FakeEngine, _: []const u8) !@import("engine.zig").FeedResult {
        return .{ .dirty_pages = &.{}, .cursor_moved = false, .bell = false };
    }
    pub fn resize(_: *FakeEngine, _: u16, _: u16) !void {}
    pub fn snapshot(self: *FakeEngine) @import("engine.zig").Snapshot {
        return .{ .cols = 4, .rows = 3, .cursor = .{}, .page_versions = &self.versions, .scroll_offset = 0 };
    }
    pub fn lineAt(self: *FakeEngine, row: u64) ?@import("engine.zig").LineView {
        if (row >= 3) return null;
        const start: usize = @intCast(row * 4);
        return .{ .abs_row = row, .cells = self.cells[start .. start + 4], .received_at_ms = 0 };
    }
    pub fn selectionText(_: *FakeEngine, _: @import("engine.zig").Selection, _: @import("engine.zig").CopyMode, allocator: std.mem.Allocator) ![]u8 {
        return allocator.dupe(u8, "");
    }
    pub fn setOscCallback(_: *FakeEngine, _: ?@import("engine.zig").OscCallback) void {}
};

test "visible text projection can prefix timestamp gutter" {
    var fake: FakeEngine = .{};
    fake.cells[0] = Cell.fromCodepoint('A');
    const text = try renderVisibleTextWithGutter(VtEngine.from(FakeEngine, &fake), std.testing.allocator, .{ .enabled = true });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "[0.000]  A"));
}

test "visible text projection trims cells and encodes unicode" {
    var fake: FakeEngine = .{};
    fake.cells[0] = Cell.fromCodepoint('A');
    fake.cells[1] = Cell.fromCodepoint(' ');
    fake.cells[4] = Cell.fromCodepoint('界');
    fake.cells[5].width = .wide_tail;
    fake.cells[8] = Cell.fromCodepoint('Z');
    const text = try renderVisibleText(VtEngine.from(FakeEngine, &fake), std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("A\n界\nZ", text);
}
