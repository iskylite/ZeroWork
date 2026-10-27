const std = @import("std");

pub const default_width: f32 = 238;
pub const minimum_width: f32 = 220;
pub const maximum_width: f32 = 480;

pub const Asset = struct { id: u32, name: []const u8, host: []const u8, group: []const u8 = "" };

pub const Model = struct {
    allocator: std.mem.Allocator,
    assets: std.ArrayList(Asset) = .empty,
    filtered: std.ArrayList(usize) = .empty,
    collapsed: bool = false,
    expanded_width: f32 = default_width,
    initial_width_pending: bool = true,
    user_collapsed: ?bool = null,
    committed_collapsed: ?bool = null,
    session_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Model {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Model) void {
        self.assets.deinit(self.allocator);
        self.filtered.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn add(self: *Model, asset: Asset) !void {
        try self.assets.append(self.allocator, asset);
    }

    pub fn search(self: *Model, query: []const u8) ![]const usize {
        self.filtered.clearRetainingCapacity();
        for (self.assets.items, 0..) |asset, index| {
            if (query.len == 0 or containsFold(asset.name, query) or containsFold(asset.host, query) or containsFold(asset.group, query)) try self.filtered.append(self.allocator, index);
        }
        return self.filtered.items;
    }

    pub fn toggleCollapsed(self: *Model) void {
        self.collapsed = !self.collapsed;
        self.user_collapsed = self.collapsed;
    }
    pub fn width(self: Model) f32 {
        return if (self.collapsed) 0 else self.expanded_width;
    }

    pub fn alignInitialWidth(self: *Model, local_right: f32, sidebar_left: f32, window_width: f32) bool {
        if (!self.initial_width_pending or !std.math.isFinite(local_right) or local_right <= sidebar_left) return false;
        const maximum = @min(maximum_width, @max(minimum_width, window_width - 480));
        const target_width = std.math.clamp(local_right - sidebar_left, minimum_width, maximum);
        self.initial_width_pending = false;
        const changed = @abs(target_width - self.expanded_width) > 0.5;
        self.expanded_width = target_width;
        return changed;
    }

    /// Session changes never override the user's sidebar choice.
    pub fn setSessionCount(self: *Model, count: usize) bool {
        self.session_count = count;
        return false;
    }
    pub fn updateForWindow(self: *Model, _: f32) void {
        self.collapsed = self.user_collapsed orelse false;
    }

    /// Startup follows the session default. A later explicit settings Save
    /// shares the same current-window choice as the sidebar controls.
    pub fn applyCommittedPreference(self: *Model, value: bool, window_width: f32) void {
        if (self.committed_collapsed) |previous| {
            if (previous != value) self.user_collapsed = value;
        }
        self.committed_collapsed = value;
        self.updateForWindow(window_width);
    }
};

fn containsFold(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    for (haystack[0 .. haystack.len - needle.len + 1], 0..) |_, index| {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

test "sidebar searches assets by name host and group" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    try model.add(.{ .id = 1, .name = "prod-db", .host = "10.0.0.4", .group = "production" });
    try model.add(.{ .id = 2, .name = "staging", .host = "10.0.0.5", .group = "qa" });
    try std.testing.expectEqual(@as(usize, 1), (try model.search("10.0.0.4")).len);
    try std.testing.expectEqual(@as(usize, 1), (try model.search("QA")).len);
    model.toggleCollapsed();
    try std.testing.expectEqual(@as(f32, 0), model.width());
}

test "sidebar sessions and resize preserve the explicit visibility choice" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    model.applyCommittedPreference(true, 860);
    try std.testing.expect(!model.collapsed);
    try std.testing.expect(!model.setSessionCount(1));
    model.updateForWindow(860);
    try std.testing.expect(!model.collapsed);
    model.toggleCollapsed();
    try std.testing.expect(!model.setSessionCount(0));
    model.updateForWindow(1440);
    try std.testing.expect(model.collapsed);
    model.applyCommittedPreference(false, 1440);
    try std.testing.expect(!model.collapsed);
    try std.testing.expectEqual(default_width, model.width());
}

test "sidebar initial width aligns once and preserves a later manual width" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    try std.testing.expectEqual(default_width, model.width());
    try std.testing.expect(model.alignInitialWidth(402, 4, 1440));
    try std.testing.expectEqual(@as(f32, 398), model.width());
    model.expanded_width = 275;
    try std.testing.expect(!model.alignInitialWidth(242, 4, 1440));
    try std.testing.expectEqual(@as(f32, 275), model.width());

    var narrow = Model.init(std.testing.allocator);
    defer narrow.deinit();
    try std.testing.expect(narrow.alignInitialWidth(600, 4, 860));
    try std.testing.expectEqual(@as(f32, 380), narrow.width());
}
