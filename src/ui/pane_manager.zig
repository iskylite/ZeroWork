const std = @import("std");

pub const Orientation = enum { horizontal, vertical };
pub const Pane = struct { id: u32, session_id: u32, group_id: ?u32 = null, group_color: u32 = 0xffffffff, weight: f32 = 1.0 };
pub const Tab = struct { id: u32, panes: []Pane, active_pane: usize = 0 };

pub const Rect = struct { x: f32, y: f32, width: f32, height: f32 };

pub const Manager = struct {
    allocator: std.mem.Allocator,
    tabs: std.ArrayList(Tab) = .empty,
    active_tab: usize = 0,
    recent_tab: ?usize = null,
    next_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) Manager {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Manager) void {
        for (self.tabs.items) |tab| self.allocator.free(tab.panes);
        self.tabs.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn newTab(self: *Manager, session_id: u32) !u32 {
        const panes = try self.allocator.alloc(Pane, 1);
        panes[0] = .{ .id = self.next_id, .session_id = session_id };
        self.next_id += 1;
        const id = self.next_id;
        self.next_id += 1;
        try self.tabs.append(self.allocator, .{ .id = id, .panes = panes });
        self.recent_tab = if (self.tabs.items.len > 1) self.active_tab else null;
        self.active_tab = self.tabs.items.len - 1;
        return id;
    }

    pub fn active(self: *Manager) ?*Tab {
        if (self.tabs.items.len == 0) return null;
        return &self.tabs.items[self.active_tab];
    }

    pub fn selectTab(self: *Manager, index: usize) !void {
        if (index >= self.tabs.items.len) return error.InvalidTab;
        self.recent_tab = if (self.active_tab == index) self.recent_tab else self.active_tab;
        self.active_tab = index;
    }

    pub fn splitActive(self: *Manager, session_id: u32, orientation: Orientation) !u32 {
        _ = orientation;
        const tab = self.active() orelse return error.NoActiveTab;
        const next = try self.allocator.realloc(tab.panes, tab.panes.len + 1);
        tab.panes = next;
        const pane_id = self.next_id;
        self.next_id += 1;
        tab.panes[tab.panes.len - 1] = .{ .id = pane_id, .session_id = session_id, .weight = 1.0 / @as(f32, @floatFromInt(tab.panes.len)) };
        const previous_weight = 1.0 / @as(f32, @floatFromInt(tab.panes.len));
        for (tab.panes[0 .. tab.panes.len - 1]) |*pane| pane.weight = previous_weight;
        tab.active_pane = tab.panes.len - 1;
        return pane_id;
    }

    pub fn selectRecentTab(self: *Manager) !void {
        const recent = self.recent_tab orelse return error.NoRecentTab;
        if (recent >= self.tabs.items.len) {
            self.recent_tab = null;
            return error.NoRecentTab;
        }
        const previous = self.active_tab;
        self.active_tab = recent;
        self.recent_tab = previous;
    }

    pub fn layout(self: *const Manager, width: f32, height: f32, gap: f32, orientation: Orientation, out: []Rect) !void {
        const tab = self.tabs.items[self.active_tab];
        if (out.len < tab.panes.len) return error.BufferTooSmall;
        const usable = if (tab.panes.len > 1) (if (orientation == .horizontal) width else height) - gap * @as(f32, @floatFromInt(tab.panes.len - 1)) else if (orientation == .horizontal) width else height;
        var cursor: f32 = 0;
        for (tab.panes, 0..) |pane, index| {
            const extent = usable * pane.weight;
            out[index] = if (orientation == .horizontal) .{ .x = cursor, .y = 0, .width = extent, .height = height } else .{ .x = 0, .y = cursor, .width = width, .height = extent };
            cursor += extent + gap;
        }
    }

    pub fn closeActivePane(self: *Manager) !void {
        const tab = self.active() orelse return error.NoActiveTab;
        if (tab.panes.len <= 1) return self.closeActiveTab();
        const removed = tab.active_pane;
        std.mem.copyForwards(Pane, tab.panes[removed .. tab.panes.len - 1], tab.panes[removed + 1 ..]);
        tab.panes = try self.allocator.realloc(tab.panes, tab.panes.len - 1);
        tab.active_pane = @min(removed, tab.panes.len - 1);
        for (tab.panes) |*pane| pane.weight = 1.0 / @as(f32, @floatFromInt(tab.panes.len));
    }

    pub fn closeActiveTab(self: *Manager) !void {
        if (self.tabs.items.len == 0) return error.NoActiveTab;
        const index = self.active_tab;
        self.allocator.free(self.tabs.items[index].panes);
        _ = self.tabs.orderedRemove(index);
        if (self.tabs.items.len == 0) {
            self.active_tab = 0;
            return;
        }
        self.active_tab = @min(index, self.tabs.items.len - 1);
        self.recent_tab = null;
    }
};

test "pane metadata carries group color" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    _ = try manager.newTab(1);
    manager.active().?.panes[0].group_id = 7;
    manager.active().?.panes[0].group_color = 0xff00ffff;
    try std.testing.expectEqual(@as(?u32, 7), manager.active().?.panes[0].group_id);
}

test "MRU selection swaps active and recent tabs" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    _ = try manager.newTab(1);
    _ = try manager.newTab(2);
    try manager.selectTab(0);
    try manager.selectRecentTab();
    try std.testing.expectEqual(@as(usize, 1), manager.active_tab);
    try manager.selectRecentTab();
    try std.testing.expectEqual(@as(usize, 0), manager.active_tab);
}

test "pane layout respects orientation gap and weights" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    _ = try manager.newTab(1);
    _ = try manager.splitActive(2, .horizontal);
    var rects: [2]Rect = undefined;
    try manager.layout(1000, 400, 20, .horizontal, &rects);
    try std.testing.expectEqual(@as(f32, 0), rects[0].x);
    try std.testing.expectEqual(@as(f32, 490), rects[0].width);
    try std.testing.expectEqual(@as(f32, 510), rects[1].x);
}

test "pane split normalizes weights and close removes pane" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    _ = try manager.newTab(1);
    _ = try manager.splitActive(2, .horizontal);
    _ = try manager.splitActive(3, .vertical);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), manager.active().?.panes[0].weight, 0.001);
    try manager.closeActivePane();
    try std.testing.expectEqual(@as(usize, 2), manager.active().?.panes.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), manager.active().?.panes[0].weight, 0.001);
}

test "closing final pane closes tab" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    _ = try manager.newTab(1);
    try manager.closeActivePane();
    try std.testing.expect(manager.active() == null);
}

test "tab manager creates selects and splits panes" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    _ = try manager.newTab(1);
    try manager.selectTab(0);
    const pane = try manager.splitActive(2, .vertical);
    try std.testing.expectEqual(@as(usize, 2), manager.active().?.panes.len);
    try std.testing.expectEqual(pane, manager.active().?.panes[1].id);
}
