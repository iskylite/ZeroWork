const std = @import("std");
const VtEngine = @import("engine.zig").VtEngine;
const Cell = @import("cell.zig").Cell;
const cell_mod = @import("cell.zig");

/// Projects the visible VT grid into owned UTF-8 text for TerminalViewNode,
/// plus one style span per run of cells sharing the same ANSI attributes.
/// Byte offsets in spans refer to the returned text.
///
/// "Default" style: the Ghostty adapter leaves fg/bg unset (Cell defaults)
/// when the remote did not specify an explicit RGB color. Both the unset
/// default (0xFFFFFFFF / 0x000000FF) and the normalized 0 form are treated
/// as "inherit base theme style".
pub const StyledText = struct {
    text: []u8,
    spans: []Span,
};

/// One run of same-style cells. color/bg use the adapter's packed form
/// (0xRRGGBBAA); is_default_color() decides span inheritance.
pub const Span = struct {
    start: u32,
    end: u32,
    color: u32 = 0,
    bg: u32 = 0,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
};

pub fn isDefaultColor(packed_rgba: u32) bool {
    return packed_rgba == 0 or packed_rgba == 0xFFFFFFFF or packed_rgba == 0x000000FF;
}

pub fn renderVisibleTextStyled(engine: VtEngine, allocator: std.mem.Allocator) !StyledText {
    const snapshot = engine.snapshot();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var spans: std.ArrayList(Span) = .empty;
    errdefer spans.deinit(allocator);

    for (0..snapshot.rows) |row_index| {
        const line = engine.lineAt(snapshot.scroll_offset + row_index) orelse {
            if (row_index + 1 < snapshot.rows) try output.append(allocator, '\n');
            continue;
        };
        // Trim trailing blanks (same contract as the plain projection).
        var end = line.cells.len;
        while (end > 0 and isBlank(line.cells[end - 1])) end -= 1;
        var run: ?Span = null;
        for (line.cells[0..end]) |cell| {
            if (cell.width == .wide_tail) continue; // tail merges into the lead cell
            const cell_style = styleOf(cell);
            if (run) |r| {
                if (!sameStyle(r, cell_style)) {
                    // Style break: flush the old run, start a new one (or none).
                    if (!isDefaultSpan(r)) try appendSpan(&spans, allocator, r);
                    run = null;
                }
            }
            if (run == null and !isDefaultStyle(cell_style)) {
                run = Span{
                    .start = @intCast(output.items.len),
                    .end = @intCast(output.items.len),
                    .color = cell_style.color,
                    .bg = cell_style.bg,
                    .bold = cell_style.bold,
                    .italic = cell_style.italic,
                    .underline = cell_style.underline,
                };
            }
            var bytes: [4]u8 = undefined;
            const codepoint: u21 = if (cell.codepoint == 0) ' ' else cell.codepoint;
            const count = std.unicode.utf8Encode(codepoint, &bytes) catch {
                try output.appendSlice(allocator, "\u{FFFD}");
                if (run != null) run.?.end = @intCast(output.items.len);
                continue;
            };
            try output.appendSlice(allocator, bytes[0..count]);
            if (run != null) run.?.end = @intCast(output.items.len);
        }
        if (run) |r| {
            if (!isDefaultSpan(r)) try appendSpan(&spans, allocator, r);
        }
        if (row_index + 1 < snapshot.rows) try output.append(allocator, '\n');
    }
    return .{ .text = try output.toOwnedSlice(allocator), .spans = try spans.toOwnedSlice(allocator) };
}

fn appendSpan(spans: *std.ArrayList(Span), allocator: std.mem.Allocator, span: Span) !void {
    if (spans.items.len >= 1024) return; // bound worst-case style thrash
    try spans.append(allocator, span);
}

const CellStyle = struct { color: u32, bg: u32, bold: bool, italic: bool, underline: bool };

fn styleOf(cell: Cell) CellStyle {
    return .{
        .color = cell.fg,
        .bg = cell.bg,
        .bold = cell.attrs & cell_mod.attrMask(.bold) != 0,
        .italic = cell.attrs & cell_mod.attrMask(.italic) != 0,
        .underline = cell.attrs & cell_mod.attrMask(.underline) != 0,
    };
}

fn sameStyle(a: Span, b: CellStyle) bool {
    return a.color == b.color and a.bg == b.bg and a.bold == b.bold and a.italic == b.italic and a.underline == b.underline;
}

fn isDefaultStyle(style: CellStyle) bool {
    return isDefaultColor(style.color) and isDefaultColor(style.bg) and !style.bold and !style.italic and !style.underline;
}

fn isDefaultSpan(span: Span) bool {
    return isDefaultColor(span.color) and isDefaultColor(span.bg) and !span.bold and !span.italic and !span.underline;
}

fn isBlank(cell: Cell) bool {
    return cell.width == .wide_tail or cell.codepoint == 0 or cell.codepoint == ' ';
}

// ── Tests ──────────────────────────────────────────────────────────────

const FakeEngine = struct {
    cells: [12]Cell = blankCells(),
    versions: [1]u64 = .{1},

    fn blankCells() [12]Cell {
        var cells: [12]Cell = undefined;
        for (&cells) |*cell| cell.* = Cell.blank();
        return cells;
    }

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

test "styled projection emits one span per color run" {
    var fake: FakeEngine = .{};
    fake.cells[0] = Cell.fromCodepoint('O');
    fake.cells[0].fg = 0xFF0000FF; // red
    fake.cells[1] = Cell.fromCodepoint('K');
    fake.cells[1].fg = 0xFF0000FF; // red continues the run
    fake.cells[2] = Cell.fromCodepoint('!');
    fake.cells[2].fg = 0x00FF00FF; // green run
    fake.cells[2].attrs |= cell_mod.attrMask(.bold);
    const styled = try renderVisibleTextStyled(VtEngine.from(FakeEngine, &fake), std.testing.allocator);
    defer {
        std.testing.allocator.free(styled.text);
        std.testing.allocator.free(styled.spans);
    }
    try std.testing.expectEqualStrings("OK!\n\n", styled.text);
    try std.testing.expectEqual(@as(usize, 2), styled.spans.len);
    try std.testing.expectEqual(@as(u32, 0), styled.spans[0].start);
    try std.testing.expectEqual(@as(u32, 2), styled.spans[0].end);
    try std.testing.expectEqual(0xFF0000FF, styled.spans[0].color);
    try std.testing.expectEqual(@as(u32, 2), styled.spans[1].start);
    try std.testing.expectEqual(@as(u32, 3), styled.spans[1].end);
    try std.testing.expect(styled.spans[1].bold);
}

test "styled projection omits default-attribute cells" {
    var fake: FakeEngine = .{};
    fake.cells[0] = Cell.fromCodepoint('a'); // fg stays 0xFFFFFFFF default
    const styled = try renderVisibleTextStyled(VtEngine.from(FakeEngine, &fake), std.testing.allocator);
    defer {
        std.testing.allocator.free(styled.text);
        std.testing.allocator.free(styled.spans);
    }
    try std.testing.expectEqualStrings("a\n\n", styled.text);
    try std.testing.expectEqual(@as(usize, 0), styled.spans.len);
}

test "styled projection keeps background-only runs as spans" {
    var fake: FakeEngine = .{};
    fake.cells[0] = Cell.fromCodepoint('x');
    fake.cells[0].bg = 0x333333FF; // highlighted background, default fg
    const styled = try renderVisibleTextStyled(VtEngine.from(FakeEngine, &fake), std.testing.allocator);
    defer {
        std.testing.allocator.free(styled.text);
        std.testing.allocator.free(styled.spans);
    }
    try std.testing.expectEqualStrings("x\n\n", styled.text);
    try std.testing.expectEqual(@as(usize, 1), styled.spans.len);
    try std.testing.expectEqual(0x333333FF, styled.spans[0].bg);
    try std.testing.expect(isDefaultColor(styled.spans[0].color));
}
