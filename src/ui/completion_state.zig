const std = @import("std");

/// Local completion interaction state; Tab is deliberately never consumed.
pub const State = struct {
    suggestion: ?[]const u8 = null,
    menu_open: bool = false,

    pub const Key = enum { right, escape, tab, menu, other };
    pub const Action = enum { accept, dismiss, open_menu, passthrough };

    pub fn key(self: *State, input: Key) Action {
        return switch (input) {
            .right => if (self.suggestion != null) .accept else .passthrough,
            .escape => if (self.suggestion != null or self.menu_open) blk: {
                self.suggestion = null;
                self.menu_open = false;
                break :blk .dismiss;
            } else .passthrough,
            .menu => blk: {
                self.menu_open = true;
                break :blk .open_menu;
            },
            .tab, .other => .passthrough,
        };
    }
};

test "right accepts ghost text while tab always passes through" {
    var state: State = .{ .suggestion = " status" };
    try std.testing.expectEqual(State.Action.accept, state.key(.right));
    try std.testing.expectEqual(State.Action.passthrough, state.key(.tab));
    try std.testing.expectEqual(State.Action.dismiss, state.key(.escape));
    try std.testing.expect(state.suggestion == null);
}
