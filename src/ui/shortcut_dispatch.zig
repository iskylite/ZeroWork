const std = @import("std");
const router = @import("shortcut_router.zig");
const Manager = @import("pane_manager.zig").Manager;

pub fn dispatch(manager: *Manager, action: router.Action, tab_index: ?usize) !bool {
    switch (action) {
        .next_tab, .previous_tab => try manager.selectRecentTab(),
        .select_tab => try manager.selectTab(tab_index orelse return error.MissingTabIndex),
        .ignore, .send_terminal, .copy_selection, .cancel_selection, .toggle_sidebar, .quick_connect => return false,
    }
    return true;
}

test "shortcut dispatcher selects direct and MRU tabs" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    _ = try manager.newTab(1);
    _ = try manager.newTab(2);
    try std.testing.expect(try dispatch(&manager, .select_tab, 0));
    try std.testing.expectEqual(@as(usize, 0), manager.active_tab);
    try std.testing.expect(try dispatch(&manager, .next_tab, null));
    try std.testing.expectEqual(@as(usize, 1), manager.active_tab);
    try std.testing.expect(!(try dispatch(&manager, .send_terminal, null)));
}
