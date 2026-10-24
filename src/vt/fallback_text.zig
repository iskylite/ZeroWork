const std = @import("std");
const Cell = @import("cell.zig").Cell;
const PageList = @import("pagelist.zig").PageList;
const engine = @import("engine.zig");

/// Small deterministic fallback adapter for plain UTF-8/text fixtures.
/// It is not a full VT parser; production escape/OSC semantics remain an explicit gate.
pub const Adapter = struct {
    allocator: std.mem.Allocator,
    pages: PageList,
    current: std.ArrayList(Cell),
    dirty: [1]u32 = .{0},
    cursor_row: u32 = 0,
    cursor_col: u16 = 0,

    pub fn init(allocator: std.mem.Allocator, cols: u16, scrollback: u32) !Adapter {
        return .{ .allocator = allocator, .pages = try PageList.init(allocator, cols, scrollback), .current = .empty };
    }
    pub fn deinit(self: *Adapter) void {
        self.current.deinit(self.allocator);
        self.pages.deinit();
        self.* = undefined;
    }
    pub fn feed(self: *Adapter, bytes: []const u8) !engine.FeedResult {
        for (bytes) |byte| switch (byte) {
            '\n' => {
                _ = try self.pages.appendLine(self.current.items, 0);
                self.current.clearRetainingCapacity();
                self.cursor_row += 1;
                self.cursor_col = 0;
            },
            '\r' => self.cursor_col = 0,
            0x20...0x7e => {
                try self.current.append(self.allocator, Cell.fromCodepoint(byte));
                self.cursor_col += 1;
            },
            else => {},
        };
        return .{ .dirty_pages = &self.dirty, .cursor_moved = bytes.len != 0, .bell = std.mem.indexOfScalar(u8, bytes, 7) != null };
    }
    pub fn resize(_: *Adapter, _: u16, _: u16) !void {}
    pub fn snapshot(self: *Adapter) engine.Snapshot {
        return .{ .cols = self.pages.cols, .rows = @intCast(self.pages.max_scrollback), .cursor = .{ .row = self.cursor_row, .col = self.cursor_col }, .page_versions = self.pages.versions, .scroll_offset = 0 };
    }
    pub fn lineAt(self: *Adapter, row: u64) ?engine.LineView {
        return self.pages.lineAt(row);
    }
    pub fn selectionText(_: *Adapter, _: engine.Selection, _: engine.CopyMode, allocator: std.mem.Allocator) ![]u8 {
        return allocator.dupe(u8, "");
    }
    pub fn setOscCallback(_: *Adapter, _: ?engine.OscCallback) void {}
};

test "fallback adapter feeds plain text into PageList" {
    var adapter = try Adapter.init(std.testing.allocator, 8, 16);
    defer adapter.deinit();
    const result = try adapter.feed("hello\n");
    try std.testing.expect(result.cursor_moved);
    const line_text = try textFromLine(adapter.pages.lineAt(0).?, std.testing.allocator);
    defer std.testing.allocator.free(line_text);
    try std.testing.expectEqualStrings("hello   ", line_text);
}

test "fallback adapter ignores control bytes and tracks bell" {
    var adapter = try Adapter.init(std.testing.allocator, 8, 8);
    defer adapter.deinit();
    const result = try adapter.feed("a\x07\x1b[31mb\n");
    try std.testing.expect(result.bell);
    const line_text = try textFromLine(adapter.pages.lineAt(0).?, std.testing.allocator);
    defer std.testing.allocator.free(line_text);
    try std.testing.expectEqualStrings("a[31mb  ", line_text);
}

fn textFromLine(line: @import("pagelist.zig").LineView, allocator: std.mem.Allocator) ![]u8 {
    var out = try allocator.alloc(u8, line.cells.len);
    for (line.cells, 0..) |cell, i| out[i] = @intCast(cell.codepoint);
    return out;
}
