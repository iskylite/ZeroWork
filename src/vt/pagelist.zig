const std = @import("std");
const Cell = @import("cell.zig").Cell;

pub const rows_per_page: u32 = 1024;

pub const LineView = struct {
    abs_row: u64,
    cells: []const Cell,
    received_at_ms: i64,
};

pub const Snapshot = struct {
    cols: u16,
    first_row: u64,
    next_row: u64,
    page_versions: []const u64,
};

const Page = struct {
    id: u64 = std.math.maxInt(u64),
    version: u64 = 0,
    cells: []Cell,
    received_at_ms: [rows_per_page]i64 = @splat(0),
};

/// A fixed-slot page ring. All page slabs are allocated during init so the
/// append hot path and snapshots perform no allocation.
pub const PageList = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    max_scrollback: u32,
    slots: []?*Page,
    versions: []u64,
    first_row: u64 = 0,
    next_row: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, cols: u16, max_scrollback: u32) !PageList {
        if (cols == 0 or max_scrollback == 0) return error.InvalidDimensions;
        // A retained line range can straddle one more physical page than its
        // line-count quotient, so keep one transition slot for the partial head.
        const quotient = std.math.divCeil(u32, max_scrollback, rows_per_page) catch return error.InvalidDimensions;
        const page_count = std.math.add(u32, quotient, 1) catch return error.InvalidDimensions;
        const slots = try allocator.alloc(?*Page, page_count);
        @memset(slots, null);
        errdefer allocator.free(slots);
        var initialized: usize = 0;
        errdefer for (slots[0..initialized]) |maybe_page| if (maybe_page) |page| {
            allocator.free(page.cells);
            allocator.destroy(page);
        };
        for (slots) |*slot| {
            const page = try allocator.create(Page);
            errdefer allocator.destroy(page);
            const cell_count = std.math.mul(usize, @as(usize, rows_per_page), @as(usize, cols)) catch return error.InvalidDimensions;
            const cells = try allocator.alloc(Cell, cell_count);
            @memset(cells, Cell.blank());
            page.* = .{ .cells = cells };
            slot.* = page;
            initialized += 1;
        }
        const versions = try allocator.alloc(u64, page_count);
        @memset(versions, 0);
        return .{ .allocator = allocator, .cols = cols, .max_scrollback = max_scrollback, .slots = slots, .versions = versions };
    }

    pub fn deinit(self: *PageList) void {
        for (self.slots) |maybe_page| if (maybe_page) |page| self.destroyPage(page);
        self.allocator.free(self.slots);
        self.allocator.free(self.versions);
        self.* = undefined;
    }

    pub fn appendLine(self: *PageList, cells: []const Cell, received_at_ms: i64) !u64 {
        if (cells.len > self.cols) return error.LineTooWide;
        const abs_row = self.next_row;
        const page_id = abs_row / rows_per_page;
        const row_index: usize = @intCast(abs_row % rows_per_page);
        const page = self.ensurePage(page_id);
        const start = row_index * self.cols;
        const row_cells = page.cells[start .. start + self.cols];
        @memset(row_cells, Cell.blank());
        @memcpy(row_cells[0..cells.len], cells);
        page.received_at_ms[row_index] = received_at_ms;
        page.version +%= 1;
        self.versions[@intCast(page_id % self.slots.len)] = page.version;
        self.next_row += 1;
        self.first_row = self.next_row -| self.max_scrollback;
        return abs_row;
    }

    pub fn lineAt(self: *const PageList, abs_row: u64) ?LineView {
        if (abs_row < self.first_row or abs_row >= self.next_row) return null;
        const page_id = abs_row / rows_per_page;
        const page = self.slots[@intCast(page_id % self.slots.len)].?;
        if (page.id != page_id) return null;
        const row_index: usize = @intCast(abs_row % rows_per_page);
        const start = row_index * self.cols;
        return .{ .abs_row = abs_row, .cells = page.cells[start .. start + self.cols], .received_at_ms = page.received_at_ms[row_index] };
    }

    pub fn snapshot(self: *const PageList) Snapshot {
        return .{ .cols = self.cols, .first_row = self.first_row, .next_row = self.next_row, .page_versions = self.versions };
    }

    fn ensurePage(self: *PageList, page_id: u64) *Page {
        const slot_index: usize = @intCast(page_id % self.slots.len);
        const page = self.slots[slot_index].?;
        if (page.id != page_id) {
            page.id = page_id;
            page.version +%= 1;
            @memset(&page.received_at_ms, 0);
            @memset(page.cells, Cell.blank());
        }
        return page;
    }

    fn destroyPage(self: *PageList, page: *Page) void {
        self.allocator.free(page.cells);
        self.allocator.destroy(page);
    }
};

test "page list rejects invalid dimensions" {
    try std.testing.expectError(error.InvalidDimensions, PageList.init(std.testing.allocator, 0, 1));
    try std.testing.expectError(error.InvalidDimensions, PageList.init(std.testing.allocator, 1, 0));
}

test "page list preserves timestamps and blanks short lines" {
    var list = try PageList.init(std.testing.allocator, 4, 2048);
    defer list.deinit();
    const input = [_]Cell{ Cell.fromCodepoint('o'), Cell.fromCodepoint('k') };
    const row = try list.appendLine(&input, 42);
    const line = list.lineAt(row).?;
    try std.testing.expectEqual(@as(i64, 42), line.received_at_ms);
    try std.testing.expectEqual(@as(u21, 'o'), line.cells[0].codepoint);
    try std.testing.expectEqual(@as(u21, ' '), line.cells[3].codepoint);
}

test "page ring enforces exact scrollback line bound" {
    var list = try PageList.init(std.testing.allocator, 1, 1025);
    defer list.deinit();
    const input = [_]Cell{Cell.fromCodepoint('x')};
    for (0..2050) |i| _ = try list.appendLine(&input, @intCast(i));
    try std.testing.expectEqual(@as(u64, 1025), list.snapshot().first_row);
    try std.testing.expect(list.lineAt(1024) == null);
    try std.testing.expectEqual(@as(i64, 2049), list.lineAt(2049).?.received_at_ms);
}

test "partial head page survives transition into a new page" {
    var list = try PageList.init(std.testing.allocator, 1, 10);
    defer list.deinit();
    const input = [_]Cell{Cell.fromCodepoint('x')};
    for (0..1025) |i| _ = try list.appendLine(&input, @intCast(i));
    try std.testing.expect(list.lineAt(1014) == null);
    try std.testing.expectEqual(@as(i64, 1015), list.lineAt(1015).?.received_at_ms);
    try std.testing.expectEqual(@as(i64, 1024), list.lineAt(1024).?.received_at_ms);
}

test "page versions change when a slot is reused" {
    var list = try PageList.init(std.testing.allocator, 1, 1024);
    defer list.deinit();
    const input = [_]Cell{Cell.fromCodepoint('x')};
    for (0..2048) |_| _ = try list.appendLine(&input, 1);
    const before = list.snapshot().page_versions[0];
    _ = try list.appendLine(&input, 2);
    try std.testing.expect(list.snapshot().page_versions[0] > before);
}

test "append and snapshot allocate nothing after init" {
    var list = try PageList.init(std.testing.allocator, 2, 1024);
    defer list.deinit();
    const input = [_]Cell{ Cell.fromCodepoint('o'), Cell.fromCodepoint('k') };

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const original = list.allocator;
    list.allocator = failing.allocator();
    defer list.allocator = original;

    for (0..2048) |i| _ = try list.appendLine(&input, @intCast(i));
    _ = list.snapshot();
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
}
