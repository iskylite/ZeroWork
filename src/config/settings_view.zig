const std = @import("std");
const model = @import("settings_model.zig");
const pages = @import("settings_pages.zig");
const values = @import("settings_values.zig");

pub const KeyView = struct { key: []const u8, value: values.Value, selected: bool };
pub const Snapshot = struct { page_name: []const u8, description: []const u8, dirty: bool, keys: []const KeyView };

pub fn snapshot(allocator: std.mem.Allocator, settings: model.Model) !Snapshot {
    var keys_buffer: [32]pages.ConfigKey = undefined;
    const selected_keys = settings.pageKeys(&keys_buffer);
    const views = try allocator.alloc(KeyView, selected_keys.len);
    for (selected_keys, 0..) |key, index| {
        views[index] = .{ .key = key.key, .value = values.read(settings.value, key.section, key.key) orelse return error.UnknownKey, .selected = index == settings.key_index };
    }
    const page = settings.page();
    return .{ .page_name = page.name, .description = page.description, .dirty = settings.dirty, .keys = views };
}

test "settings snapshot projects selected page and values" {
    var settings: model.Model = .{};
    settings.selectPage(4);
    settings.selectKey(1);
    const view = try snapshot(std.testing.allocator, settings);
    defer std.testing.allocator.free(view.keys);
    try std.testing.expectEqualStrings("AI 辅助", view.page_name);
    try std.testing.expectEqual(@as(usize, 6), view.keys.len);
    try std.testing.expectEqualStrings("permission_mode", view.keys[1].key);
    try std.testing.expect(view.keys[1].selected);
}
