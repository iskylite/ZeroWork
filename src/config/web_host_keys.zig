//! Decide which physical key events leave a focused native web page for the
//! workspace. Text editing and terminal-only actions remain with WebKit.
const std = @import("std");
const keys = @import("keybindings.zig");

pub fn isHostKey(map: keys.Map, key: anytype, mods: anytype) bool {
    const code = keys.fromKey(key);
    const configured_action = map.match(key, mods);
    if (configured_action == .notes_float) return true;
    if (configured_action == .notes_directory) return false;
    // These chords keep their native editor meaning even when a terminal
    // shortcut was assigned to the same physical key.
    if (mods.super and !mods.ctrl) switch (code) {
        .a, .c, .v, .x, .z => return false,
        .left, .right, .up, .down, .home, .end, .page_up, .page_down, .delete, .forward_delete => return false,
        else => {},
    };
    // Recent-tab switching deliberately bypasses Map.match's remote Control /
    // Tab exclusion. Shift traverses the same list in the opposite direction.
    const recent = map.get(.recent_tab);
    if (code == recent.key and mods.super == recent.command and
        mods.ctrl == recent.control and mods.alt == recent.option) return true;
    if (configured_action) |action| return switch (action) {
        .copy, .paste, .search, .completion, .accept_completion => false,
        else => true,
    };
    // Reserved workspace commands have no configurable action entry.
    return mods.super and !mods.ctrl and !mods.alt and switch (code) {
        .l, .n, .comma => !mods.shift,
        .r, .b => mods.shift,
        else => false,
    };
}

const Mods = struct { super: bool = false, ctrl: bool = false, alt: bool = false, shift: bool = false };

test "focused web page keeps configured workspace and recent-tab shortcuts" {
    const map: keys.Map = .{};
    for ([_]keys.KeyCode{ .t, .w, .@"1", .@"2", .@"3", .@"4", .@"5", .@"6", .@"7", .@"8", .@"9", .l, .k, .r, .b, .j, .u, .d }) |key| {
        try std.testing.expect(isHostKey(map, key, Mods{ .super = true }));
    }
    try std.testing.expect(isHostKey(map, keys.KeyCode.tab, Mods{ .ctrl = true }));
    try std.testing.expect(isHostKey(map, keys.KeyCode.tab, Mods{ .ctrl = true, .shift = true }));
    try std.testing.expect(!isHostKey(map, keys.KeyCode.tab, Mods{}));
    try std.testing.expect(!isHostKey(map, keys.KeyCode.tab, Mods{ .super = true, .ctrl = true }));
    try std.testing.expect(!isHostKey(map, keys.KeyCode.tab, Mods{ .alt = true, .ctrl = true }));
    var customized = map;
    try customized.set(.new_tab, .{ .key = .f6, .shift = true });
    try std.testing.expect(isHostKey(customized, keys.KeyCode.f6, Mods{ .super = true, .shift = true }));
    try std.testing.expect(!isHostKey(customized, keys.KeyCode.t, Mods{ .super = true }));
    try std.testing.expect(isHostKey(map, keys.KeyCode.t, Mods{ .super = true }));
}

test "focused web page preserves editing selection navigation and composition keys" {
    const map: keys.Map = .{};
    for ([_]keys.KeyCode{ .a, .c, .v, .x, .z, .left, .right, .up, .down, .home, .end, .page_up, .page_down, .delete, .forward_delete, .f, .semicolon }) |key| {
        try std.testing.expect(!isHostKey(map, key, Mods{ .super = true }));
        try std.testing.expect(!isHostKey(map, key, Mods{ .super = true, .shift = true }));
    }
    for ([_]keys.KeyCode{ .a, .n, .i, .@"return", .escape, .space, .right, .unknown }) |key| {
        try std.testing.expect(!isHostKey(map, key, Mods{}));
        try std.testing.expect(!isHostKey(map, key, Mods{ .ctrl = true }));
        try std.testing.expect(!isHostKey(map, key, Mods{ .alt = true }));
    }
    var customized = map;
    try customized.set(.new_tab, .{ .key = .a });
    try std.testing.expect(!isHostKey(customized, keys.KeyCode.a, Mods{ .super = true }));
}

test "focused web page hands off the exact configured notes float shortcut" {
    var map: keys.Map = .{};
    const with_option: Mods = .{ .super = true, .alt = true };
    try std.testing.expect(isHostKey(map, keys.KeyCode.n, with_option));
    try std.testing.expect(!isHostKey(map, keys.KeyCode.b, with_option));
    try map.set(.notes_float, .{ .key = .z, .option = true });
    try std.testing.expect(isHostKey(map, keys.KeyCode.z, with_option));
    try std.testing.expect(!isHostKey(map, keys.KeyCode.z, Mods{ .super = true }));
    try std.testing.expect(!isHostKey(map, keys.KeyCode.n, with_option));
}
