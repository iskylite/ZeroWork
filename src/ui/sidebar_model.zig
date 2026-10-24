const std = @import("std");

pub const Asset = struct { id: u32, name: []const u8, host: []const u8, group: []const u8 = "" };

pub const Model = struct {
    allocator: std.mem.Allocator,
    assets: std.ArrayList(Asset) = .empty,
    filtered: std.ArrayList(usize) = .empty,
    collapsed: bool = false,
    user_collapsed: ?bool = null,
    committed_collapsed: ?bool = null,

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
        return if (self.collapsed) 48 else 224;
    }

    pub fn updateForWindow(self: *Model, window_width: f32) void {
        self.collapsed = self.user_collapsed orelse (window_width < 1100);
    }

    /// Consume committed settings only. The default false retains automatic
    /// responsive layout until a manual choice is made; an actual saved change
    /// then shares the same override as the sidebar controls.
    pub fn applyCommittedPreference(self: *Model, value: bool, window_width: f32) void {
        if (self.committed_collapsed) |previous| {
            if (previous != value) self.user_collapsed = value;
        } else if (value) self.user_collapsed = true;
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
    try std.testing.expectEqual(@as(f32, 48), model.width());
    model.user_collapsed = null;
    model.updateForWindow(1200);
    try std.testing.expectEqual(@as(f32, 224), model.width());
    model.updateForWindow(800);
    try std.testing.expectEqual(@as(f32, 48), model.width());
}

test "explicit sidebar preference wins over automatic resize" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    model.updateForWindow(1099);
    try std.testing.expect(model.collapsed);
    model.toggleCollapsed();
    model.updateForWindow(860);
    try std.testing.expect(!model.collapsed);
    model.toggleCollapsed();
    model.updateForWindow(1440);
    try std.testing.expect(model.collapsed);
}

test "committed sidebar preference applies at startup and Save without replacing a manual choice on resize" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    model.applyCommittedPreference(false, 860);
    try std.testing.expect(model.collapsed);
    try std.testing.expectEqual(@as(?bool, null), model.user_collapsed);
    model.applyCommittedPreference(false, 1440);
    try std.testing.expect(!model.collapsed);
    model.applyCommittedPreference(true, 1440);
    try std.testing.expect(model.collapsed);
    model.applyCommittedPreference(false, 860);
    try std.testing.expect(!model.collapsed);
    model.toggleCollapsed();
    model.applyCommittedPreference(false, 1440);
    try std.testing.expect(model.collapsed);
    try std.testing.expectEqual(@as(?bool, false), model.committed_collapsed);

    var restored = Model.init(std.testing.allocator);
    defer restored.deinit();
    restored.applyCommittedPreference(true, 1440);
    try std.testing.expect(restored.collapsed);
    restored.applyCommittedPreference(true, 860);
    try std.testing.expect(restored.collapsed);
}
