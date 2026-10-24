const std = @import("std");
const menus = @import("context_menus.zig");
const state = @import("context_menu_state.zig");
const anchor = @import("overlay_anchor.zig");

pub const ItemView = struct { action: menus.Action, label: []const u8, shortcut: ?[]const u8, enabled: bool, separator_before: bool, danger: bool, selected: bool };
pub const Snapshot = struct { visible: bool, kind: ?menus.Kind, rect: anchor.Rect, items: []const ItemView };

pub fn snapshot(allocator: std.mem.Allocator, menu_state: state.State, pane: anchor.Rect, window: anchor.Size) !Snapshot {
    const kind = menu_state.open orelse return .{ .visible = false, .kind = null, .rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 }, .items = &.{} };
    const context: menus.Context = .{ .has_selection = menu_state.has_selection, .session_ended = kind == .session_ended };
    const source = menus.items(kind, context);
    const views = try allocator.alloc(ItemView, source.len);
    for (source, 0..) |item, index| views[index] = .{ .action = item.action, .label = item.label, .shortcut = item.shortcut, .enabled = menus.isEnabled(item.action, context), .separator_before = item.separator_before, .danger = item.danger, .selected = index == menu_state.selected_index };
    return .{ .visible = true, .kind = kind, .rect = anchor.place(.pane_center, pane, .{ .width = 260, .height = @floatFromInt(source.len * 32) }, window, 8), .items = views };
}

test "menu snapshot projects selection, disabled actions and clamped rect" {
    var menu_state: state.State = .{};
    menu_state.show(.terminal, false);
    const views = try snapshot(std.testing.allocator, menu_state, .{ .x = 0, .y = 0, .width = 400, .height = 300 }, .{ .width = 420, .height = 320 });
    defer std.testing.allocator.free(views.items);
    try std.testing.expect(views.visible);
    try std.testing.expectEqual(menus.Action.ask_ai, views.items[0].action);
    try std.testing.expect(!views.items[0].enabled);
    try std.testing.expect(views.items[0].selected);
    try std.testing.expect(views.rect.x >= 8 and views.rect.y >= 8);
}
