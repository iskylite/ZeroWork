const std = @import("std");

/// Session-local state controlled by the terminal's @ commands.  These values
/// deliberately do not mutate the persisted application settings: they apply
/// only to the currently open terminal session.
pub const Theme = enum { default, dark_pro, solarized_dark, dracula, catppuccin_mocha };

pub const State = struct {
    theme: Theme = .default,
    timestamp_gutter: bool = false,
    broadcast: bool = false,
    block_selection: bool = false,

    pub const ApplyResult = enum { changed, unchanged, invalid_theme };

    pub fn applyTheme(self: *State, name: ?[]const u8) ApplyResult {
        const next = parseTheme(name) orelse return .invalid_theme;
        if (next == self.theme) return .unchanged;
        self.theme = next;
        return .changed;
    }

    pub fn applyTimestamp(self: *State, enabled: bool) ApplyResult {
        if (self.timestamp_gutter == enabled) return .unchanged;
        self.timestamp_gutter = enabled;
        return .changed;
    }

    pub fn applyBroadcast(self: *State, enabled: bool) ApplyResult {
        if (self.broadcast == enabled) return .unchanged;
        self.broadcast = enabled;
        return .changed;
    }

    /// Fan-out is permitted only after the sender accepted the input in a
    /// live session. Queue failure is represented by accepted=false.
    pub fn allowsBroadcast(self: State, accepted: bool, connected: bool, read_only: bool, modified: bool) bool {
        return self.broadcast and accepted and connected and !read_only and !modified;
    }

    pub fn applyBlockSelection(self: *State, enabled: bool) ApplyResult {
        if (self.block_selection == enabled) return .unchanged;
        self.block_selection = enabled;
        return .changed;
    }
};

pub fn parseTheme(name: ?[]const u8) ?Theme {
    const text = name orelse return .default;
    if (text.len == 0 or std.ascii.eqlIgnoreCase(text, "default") or std.ascii.eqlIgnoreCase(text, "sauber")) return .default;
    if (std.ascii.eqlIgnoreCase(text, "dark-pro") or std.ascii.eqlIgnoreCase(text, "dark_pro")) return .dark_pro;
    if (std.ascii.eqlIgnoreCase(text, "solarized-dark") or std.ascii.eqlIgnoreCase(text, "solarized_dark")) return .solarized_dark;
    if (std.ascii.eqlIgnoreCase(text, "dracula")) return .dracula;
    if (std.ascii.eqlIgnoreCase(text, "catppuccin-mocha") or std.ascii.eqlIgnoreCase(text, "catppuccin_mocha")) return .catppuccin_mocha;
    return null;
}

test "session local command state accepts design themes and default reset" {
    var state = State{};
    try std.testing.expectEqual(State.ApplyResult.changed, state.applyTheme("dark-pro"));
    try std.testing.expectEqual(Theme.dark_pro, state.theme);
    try std.testing.expectEqual(State.ApplyResult.unchanged, state.applyTheme("dark_pro"));
    try std.testing.expectEqual(State.ApplyResult.changed, state.applyTheme(null));
    try std.testing.expectEqual(Theme.default, state.theme);
    try std.testing.expectEqual(State.ApplyResult.invalid_theme, state.applyTheme("not-a-theme"));
}

test "timestamp and broadcast switches are idempotent" {
    var state = State{};
    try std.testing.expectEqual(State.ApplyResult.changed, state.applyTimestamp(true));
    try std.testing.expectEqual(State.ApplyResult.unchanged, state.applyTimestamp(true));
    try std.testing.expectEqual(State.ApplyResult.changed, state.applyBroadcast(true));
    try std.testing.expect(state.broadcast);
}

test "broadcast gate rejects failed source, modifiers, history and ended sessions" {
    var state = State{};
    try std.testing.expect(!state.allowsBroadcast(true, true, false, false));
    _ = state.applyBroadcast(true);
    try std.testing.expect(state.allowsBroadcast(true, true, false, false));
    try std.testing.expect(!state.allowsBroadcast(false, true, false, false));
    try std.testing.expect(!state.allowsBroadcast(true, false, false, false));
    try std.testing.expect(!state.allowsBroadcast(true, true, true, false));
    try std.testing.expect(!state.allowsBroadcast(true, true, false, true));
    _ = state.applyBroadcast(false);
    try std.testing.expect(!state.allowsBroadcast(true, true, false, false));
}
