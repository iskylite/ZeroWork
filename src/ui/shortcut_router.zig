const std = @import("std");

pub const Action = enum { ignore, copy_selection, cancel_selection, next_tab, previous_tab, select_tab, toggle_sidebar, quick_connect, send_terminal };
pub const Modifiers = struct { primary: bool = false, control: bool = false, shift: bool = false, alternate: bool = false };
pub const Key = enum { c, b, k, escape, tab, one, two, three, four, five, six, seven, eight, nine, left, right, up, down, other };

pub fn classify(key: Key, modifiers: Modifiers) Action {
    if (modifiers.primary and key == .c and !modifiers.control) return .copy_selection;
    if (key == .escape and !modifiers.primary) return .cancel_selection;
    if (modifiers.primary and key == .b) return .toggle_sidebar;
    if (modifiers.primary and key == .k) return .quick_connect;
    if (modifiers.primary) {
        return switch (key) {
            .one, .two, .three, .four, .five, .six, .seven, .eight, .nine => .select_tab,
            .tab => .next_tab,
            else => .ignore,
        };
    }
    if (modifiers.control and key == .tab) return .next_tab;
    return if (key == .other) .send_terminal else .send_terminal;
}

test "shortcut classifier reserves app copy and tab switching" {
    try std.testing.expectEqual(Action.copy_selection, classify(.c, .{ .primary = true }));
    try std.testing.expectEqual(Action.select_tab, classify(.three, .{ .primary = true }));
    try std.testing.expectEqual(Action.next_tab, classify(.tab, .{ .control = true }));
    try std.testing.expectEqual(Action.cancel_selection, classify(.escape, .{}));
    try std.testing.expectEqual(Action.toggle_sidebar, classify(.b, .{ .primary = true }));
    try std.testing.expectEqual(Action.quick_connect, classify(.k, .{ .primary = true }));
}
