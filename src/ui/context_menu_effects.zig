const std = @import("std");
const menus = @import("context_menus.zig");

pub const Effect = union(enum) { none, copied, pasted, exported, open_tab, open_window, edit_host, history, reconnect, close_session, toggle_timestamp, search, ask_ai, confirm_required };

pub fn classify(action: menus.Action, allowed: bool) Effect {
    if (!allowed) return .confirm_required;
    return switch (action) {
        .ask_ai => .ask_ai,
        .copy => .copied,
        .paste => .pasted,
        .toggle_block_selection => .none,
        .toggle_timestamp => .toggle_timestamp,
        .history => .history,
        .search => .search,
        .export_selection => .exported,
        .new_tab => .open_tab,
        .new_window => .open_window,
        .clone_host, .edit_host => .edit_host,
        .pin_host, .move_group => .none,
        .delete_host => .confirm_required,
        .reconnect => .reconnect,
        .close_session => .close_session,
        .rename_tab, .open_theme, .close_others => .none,
        .clone_session => .open_tab,
        .view_jump_chain => .none,
        .export_session => .exported,
    };
}

test "menu action effects keep destructive actions behind confirmation" {
    try std.testing.expectEqual(Effect.open_tab, classify(.new_tab, true));
    try std.testing.expectEqual(Effect.reconnect, classify(.reconnect, true));
    try std.testing.expectEqual(Effect.confirm_required, classify(.delete_host, true));
    try std.testing.expectEqual(Effect.exported, classify(.export_selection, true));
    try std.testing.expectEqual(Effect.confirm_required, classify(.copy, false));
}
