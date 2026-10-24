//! Shared selection model for DataTable / Table / VirtualList / Tree.
//!
//! Multi-select interaction across list components (Cmd/Ctrl click toggle, Shift click range,
//! anchor semantics) would diverge if written per component, so it is a pure-logic model:
//! touches no nodes or framework state beyond an allocator, independently testable.
//!
//! Index semantics are defined by the caller (DataTable uses 'filtered row order', Tree uses
//! flat_index); the model only knows usize.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Selection mode. New component props default `.none`, existing caller behavior unchanged
/// (new default-value field in props struct non-breaking per docs/API_STABILITY.md).
pub const SelectionMode = enum(u8) {
    /// Not selectable (default, matches pre-multi-select behavior)
    none,
    /// Single-select: selecting new row deselects old
    single,
    /// Multi-select: Cmd/Ctrl toggle, Shift select range
    multi,
};

/// Click modifier key intent
pub const ClickIntent = struct {
    /// Cmd (macOS) / Ctrl toggle single row, keep other selected
    toggle: bool = false,
    /// Shift, continuous range from anchor to this row
    range: bool = false,
};

/// Bitmap selection set. Capacity fixed at init (= data row count), no per-row alloc.
pub const SelectionModel = struct {
    mode: SelectionMode = .none,
    /// one bit per row
    bits: []u64 = &.{},
    len: usize = 0,
    /// Shift range anchor (last non-range click row)
    anchor: ?usize = null,
    /// Last clicked row (keyboard nav start)
    lead: ?usize = null,
    selected_count: usize = 0,

    pub fn init(allocator: Allocator, mode: SelectionMode, len: usize) !SelectionModel {
        const words = (len + 63) / 64;
        const bits = try allocator.alloc(u64, words);
        @memset(bits, 0);
        return .{ .mode = mode, .bits = bits, .len = len };
    }

    pub fn deinit(self: *SelectionModel, allocator: Allocator) void {
        allocator.free(self.bits);
        self.bits = &.{};
        self.len = 0;
    }

    /// Row count change (filter/page/data replace) rebuild capacity and clear selection.
    pub fn resize(self: *SelectionModel, allocator: Allocator, new_len: usize) !void {
        const words = (new_len + 63) / 64;
        if (words != self.bits.len) {
            const bits = try allocator.realloc(self.bits, words);
            self.bits = bits;
        }
        @memset(self.bits, 0);
        self.len = new_len;
        self.selected_count = 0;
        self.anchor = null;
        self.lead = null;
    }

    pub fn isSelected(self: *const SelectionModel, index: usize) bool {
        if (index >= self.len) return false;
        return (self.bits[index / 64] & (@as(u64, 1) << @intCast(index % 64))) != 0;
    }

    /// Direct set-bit (don't touch anchor): component derives selection set from external data
    /// source
    pub fn setSelected(self: *SelectionModel, index: usize, on: bool) void {
        self.setBit(index, on);
    }

    fn setBit(self: *SelectionModel, index: usize, on: bool) void {
        if (index >= self.len) return;
        const w = index / 64;
        const mask = @as(u64, 1) << @intCast(index % 64);
        const was = (self.bits[w] & mask) != 0;
        if (on == was) return;
        if (on) {
            self.bits[w] |= mask;
            self.selected_count += 1;
        } else {
            self.bits[w] &= ~mask;
            self.selected_count -= 1;
        }
    }

    pub fn clear(self: *SelectionModel) void {
        @memset(self.bits, 0);
        self.selected_count = 0;
    }

    /// Programmatic select single row (equiv no modifier click)
    pub fn select(self: *SelectionModel, index: usize) void {
        self.applyClick(index, .{});
    }

    /// Core interaction: apply one (modifier-keyed) click to selection set.
    ///
    /// Semantics align Finder / NSTableView:
    ///   - single mode: any modifier ignored, always select only clicked row
    ///   - multi + toggle: toggle row, rest unchanged; move anchor to row
    ///   - multi + range: clear then select [anchor, index] closed interval; anchor **unchanged**
    ///     (so successive Shift clicks redraw range from same anchor, not cumulative)
    ///   - multi no modifier: clear then select row; move anchor to row
    pub fn applyClick(self: *SelectionModel, index: usize, intent: ClickIntent) void {
        if (self.mode == .none or index >= self.len) return;
        self.lead = index;

        if (self.mode == .single) {
            self.clear();
            self.setBit(index, true);
            self.anchor = index;
            return;
        }

        if (intent.range) {
            const a = self.anchor orelse index;
            const lo = @min(a, index);
            const hi = @max(a, index);
            self.clear();
            var i = lo;
            while (i <= hi) : (i += 1) self.setBit(i, true);
            // Anchor stays: Shift multiple clicks redraw range, not accumulate
            if (self.anchor == null) self.anchor = index;
            return;
        }

        if (intent.toggle) {
            self.setBit(index, !self.isSelected(index));
            self.anchor = index;
            return;
        }

        self.clear();
        self.setBit(index, true);
        self.anchor = index;
    }

    /// Select all (multi only)
    pub fn selectAll(self: *SelectionModel) void {
        if (self.mode != .multi) return;
        var i: usize = 0;
        while (i < self.len) : (i += 1) self.setBit(i, true);
    }

    /// Write selected row indices to out, return count written (truncate if out too small).
    pub fn collect(self: *const SelectionModel, out: []usize) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.len and n < out.len) : (i += 1) {
            if (self.isSelected(i)) {
                out[n] = i;
                n += 1;
            }
        }
        return n;
    }

    /// First selected row (null if none selected)
    pub fn first(self: *const SelectionModel) ?usize {
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            if (self.isSelected(i)) return i;
        }
        return null;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "SelectionModel: none 模式忽略一切点击" {
    var m = try SelectionModel.init(testing.allocator, .none, 10);
    defer m.deinit(testing.allocator);
    m.applyClick(3, .{});
    m.applyClick(4, .{ .toggle = true });
    try testing.expectEqual(@as(usize, 0), m.selected_count);
}

test "SelectionModel: single 模式选中新行取消旧行（修饰键无效）" {
    var m = try SelectionModel.init(testing.allocator, .single, 10);
    defer m.deinit(testing.allocator);
    m.applyClick(3, .{});
    try testing.expect(m.isSelected(3));
    try testing.expectEqual(@as(usize, 1), m.selected_count);

    // even with toggle, single only keeps one row
    m.applyClick(7, .{ .toggle = true });
    try testing.expect(!m.isSelected(3));
    try testing.expect(m.isSelected(7));
    try testing.expectEqual(@as(usize, 1), m.selected_count);
}

test "SelectionModel: multi + Cmd 切换，其余保留" {
    var m = try SelectionModel.init(testing.allocator, .multi, 10);
    defer m.deinit(testing.allocator);
    m.applyClick(1, .{});
    m.applyClick(3, .{ .toggle = true });
    m.applyClick(5, .{ .toggle = true });
    try testing.expectEqual(@as(usize, 3), m.selected_count);
    try testing.expect(m.isSelected(1) and m.isSelected(3) and m.isSelected(5));

    // click 3 again -> deselect, rest unchanged
    m.applyClick(3, .{ .toggle = true });
    try testing.expect(!m.isSelected(3));
    try testing.expect(m.isSelected(1) and m.isSelected(5));
    try testing.expectEqual(@as(usize, 2), m.selected_count);
}

test "SelectionModel: multi + Shift 选连续区间（含反向）" {
    var m = try SelectionModel.init(testing.allocator, .multi, 20);
    defer m.deinit(testing.allocator);
    m.applyClick(5, .{}); // anchor = 5
    m.applyClick(9, .{ .range = true });
    try testing.expectEqual(@as(usize, 5), m.selected_count); // 5..9
    for (5..10) |i| try testing.expect(m.isSelected(i));

    // reverse Shift: anchor still 5, range redrawn 2..5
    m.applyClick(2, .{ .range = true });
    try testing.expectEqual(@as(usize, 4), m.selected_count);
    for (2..6) |i| try testing.expect(m.isSelected(i));
    try testing.expect(!m.isSelected(9)); // previous range cleared, not cumulative
}

test "SelectionModel: 无修饰点击清空其余" {
    var m = try SelectionModel.init(testing.allocator, .multi, 10);
    defer m.deinit(testing.allocator);
    m.applyClick(1, .{});
    m.applyClick(2, .{ .toggle = true });
    m.applyClick(8, .{}); // no modifier -> only 8 remains
    try testing.expectEqual(@as(usize, 1), m.selected_count);
    try testing.expect(m.isSelected(8));
}

test "SelectionModel: selectAll / collect / first" {
    var m = try SelectionModel.init(testing.allocator, .multi, 5);
    defer m.deinit(testing.allocator);
    m.selectAll();
    try testing.expectEqual(@as(usize, 5), m.selected_count);
    try testing.expectEqual(@as(?usize, 0), m.first());

    m.clear();
    m.applyClick(1, .{});
    m.applyClick(4, .{ .toggle = true });
    var buf: [8]usize = undefined;
    const n = m.collect(&buf);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualSlices(usize, &.{ 1, 4 }, buf[0..n]);
    try testing.expectEqual(@as(?usize, 1), m.first());

    // selectAll no-op in single mode
    var s = try SelectionModel.init(testing.allocator, .single, 5);
    defer s.deinit(testing.allocator);
    s.selectAll();
    try testing.expectEqual(@as(usize, 0), s.selected_count);
}

test "SelectionModel: 跨 64 行边界的区间选择" {
    var m = try SelectionModel.init(testing.allocator, .multi, 200);
    defer m.deinit(testing.allocator);
    m.applyClick(60, .{});
    m.applyClick(130, .{ .range = true });
    try testing.expectEqual(@as(usize, 71), m.selected_count);
    try testing.expect(m.isSelected(60) and m.isSelected(64) and m.isSelected(130));
    try testing.expect(!m.isSelected(59) and !m.isSelected(131));
}

test "SelectionModel: resize 重建容量并清空" {
    var m = try SelectionModel.init(testing.allocator, .multi, 10);
    defer m.deinit(testing.allocator);
    m.applyClick(3, .{});
    try testing.expectEqual(@as(usize, 1), m.selected_count);

    try m.resize(testing.allocator, 300);
    try testing.expectEqual(@as(usize, 0), m.selected_count);
    try testing.expectEqual(@as(usize, 300), m.len);
    try testing.expect(m.anchor == null);
    m.applyClick(250, .{});
    try testing.expect(m.isSelected(250));

    try m.resize(testing.allocator, 5);
    try testing.expectEqual(@as(usize, 5), m.len);
    try testing.expectEqual(@as(usize, 0), m.selected_count);
}

test "SelectionModel: 越界索引安全" {
    var m = try SelectionModel.init(testing.allocator, .multi, 4);
    defer m.deinit(testing.allocator);
    m.applyClick(99, .{});
    try testing.expectEqual(@as(usize, 0), m.selected_count);
    try testing.expect(!m.isSelected(99));
}
