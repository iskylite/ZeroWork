const std = @import("std");
const engine = @import("../vt/engine.zig");

/// UI-thread selection state. Coordinates are normalized before copy requests;
/// the VT engine remains worker-owned and is queried through its public contract.
pub const Point = struct { row: u64, col: u16 };

pub const CellMetrics = struct {
    origin_x: f32,
    origin_y: f32,
    cell_width: f32,
    cell_height: f32,
    cols: u16,

    pub fn pointAt(self: CellMetrics, x: f32, y: f32) Point {
        const safe_width = if (self.cell_width > 0) self.cell_width else 1;
        const safe_height = if (self.cell_height > 0) self.cell_height else 1;
        const raw_col: i32 = @intFromFloat(@max(0, @floor((x - self.origin_x) / safe_width)));
        const raw_row: i64 = @intFromFloat(@max(0, @floor((y - self.origin_y) / safe_height)));
        const col = @min(@as(u16, @intCast(@max(0, raw_col))), self.cols);
        return .{ .row = @intCast(@max(0, raw_row)), .col = col };
    }
};

pub const SelectionState = struct {
    anchor: ?Point = null,
    active: ?Point = null,
    /// True only while the left button is held down. mouse_up ends the drag
    /// but keeps the endpoints so the selection stays copyable; without this
    /// flag, plain mouse moves after release keep mutating the selection.
    dragging: bool = false,

    pub fn begin(self: *SelectionState, point: Point) void {
        self.anchor = point;
        self.active = point;
        self.dragging = true;
    }

    pub fn update(self: *SelectionState, point: Point) void {
        if (!self.dragging) return;
        self.anchor = self.anchor orelse point;
        self.active = point;
    }

    /// Ends the drag gesture. The selected range (if any) is kept for copy.
    pub fn endDrag(self: *SelectionState) void {
        self.dragging = false;
    }

    /// A click without movement: anchor and active coincide, so the selection
    /// is empty and should be cleared rather than highlighted.
    pub fn isCollapsed(self: SelectionState) bool {
        const first = self.anchor orelse return true;
        const second = self.active orelse return true;
        return first.row == second.row and first.col == second.col;
    }

    pub fn clear(self: *SelectionState) void {
        self.* = .{};
    }

    pub fn isActive(self: SelectionState) bool {
        return self.anchor != null and self.active != null;
    }

    pub fn copyText(self: SelectionState, vt: engine.VtEngine, allocator: std.mem.Allocator) !?[]u8 {
        const selection = self.normalized() orelse return null;
        return try vt.selectionText(selection, .plain, allocator);
    }

    pub fn normalized(self: SelectionState) ?engine.Selection {
        const first = self.anchor orelse return null;
        const second = self.active orelse return null;
        const a_before_b = first.row < second.row or (first.row == second.row and first.col <= second.col);
        const start = if (a_before_b) first else second;
        const end = if (a_before_b) second else first;
        return .{ .start_row = start.row, .start_col = start.col, .end_row = end.row, .end_col = end.col };
    }
};

test "pixel coordinates map to clamped terminal cells" {
    const metrics: CellMetrics = .{ .origin_x = 10, .origin_y = 20, .cell_width = 8, .cell_height = 16, .cols = 80 };
    try std.testing.expectEqual(Point{ .row = 2, .col = 3 }, metrics.pointAt(35, 60));
    try std.testing.expectEqual(Point{ .row = 0, .col = 0 }, metrics.pointAt(-100, -100));
    try std.testing.expectEqual(Point{ .row = 0, .col = 80 }, metrics.pointAt(1000, 20));
}

test "selection copy uses normalized VT contract" {
    const Mock = struct {
        pub fn destroy(_: *@This()) void {}
        pub fn feed(_: *@This(), _: []const u8) !engine.FeedResult {
            return .{ .dirty_pages = &.{}, .cursor_moved = false, .bell = false };
        }
        pub fn resize(_: *@This(), _: u16, _: u16) !void {}
        pub fn snapshot(_: *@This()) engine.Snapshot {
            return .{ .cols = 80, .rows = 24, .cursor = .{}, .page_versions = &.{}, .scroll_offset = 0 };
        }
        pub fn lineAt(_: *@This(), _: u64) ?engine.LineView {
            return null;
        }
        pub fn selectionText(_: *@This(), selection: engine.Selection, _: engine.CopyMode, allocator: std.mem.Allocator) ![]u8 {
            if (selection.start_row != 2 or selection.end_row != 8) return error.BadSelection;
            return allocator.dupe(u8, "copied");
        }
        pub fn setOscCallback(_: *@This(), _: ?engine.OscCallback) void {}
    };
    var mock: Mock = .{};
    var state: SelectionState = .{};
    state.begin(.{ .row = 8, .col = 4 });
    state.update(.{ .row = 2, .col = 9 });
    const copied = (try state.copyText(engine.VtEngine.from(Mock, &mock), std.testing.allocator)).?;
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("copied", copied);
}

test "selection state normalizes reverse drag and clears" {
    var state: SelectionState = .{};
    state.begin(.{ .row = 8, .col = 4 });
    state.update(.{ .row = 2, .col = 9 });
    const selected = state.normalized().?;
    try std.testing.expectEqual(@as(u64, 2), selected.start_row);
    try std.testing.expectEqual(@as(u16, 9), selected.start_col);
    try std.testing.expectEqual(@as(u64, 8), selected.end_row);
    try std.testing.expectEqual(@as(u16, 4), selected.end_col);
    state.clear();
    try std.testing.expect(!state.isActive());
}

test "drag ends at mouse up while later hover moves are inert" {
    var state: SelectionState = .{};
    state.begin(.{ .row = 1, .col = 1 });
    state.update(.{ .row = 5, .col = 2 });
    state.endDrag();
    try std.testing.expect(state.isActive());
    try std.testing.expect(!state.dragging);
    // Plain hover after release must not mutate the committed selection.
    state.update(.{ .row = 40, .col = 40 });
    const selected = state.normalized().?;
    try std.testing.expectEqual(@as(u64, 5), selected.end_row);
    try std.testing.expectEqual(@as(u16, 2), selected.end_col);
}

test "collapsed click selections report as empty" {
    var state: SelectionState = .{};
    try std.testing.expect(state.isCollapsed());
    state.begin(.{ .row = 3, .col = 7 });
    try std.testing.expect(state.isCollapsed());
    state.update(.{ .row = 3, .col = 9 });
    try std.testing.expect(!state.isCollapsed());
}
