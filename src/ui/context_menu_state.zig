const std = @import("std");
const menus = @import("context_menus.zig");

pub const Trigger = enum { terminal_middle_click, terminal_right_click, host_right_click, session_banner, tab_right_click };
pub const Input = enum { up, down, enter, escape, click_outside };
pub const State = struct {
    open: ?menus.Kind = null,
    selected_index: usize = 0,
    context: menus.Context = .{},

    pub fn dismiss(self: *State) void {
        self.open = null;
        self.selected_index = 0;
    }

    pub fn show(self: *State, kind: menus.Kind, context: menus.Context) void {
        self.open = kind;
        self.context = context;
        // Session-ended menus force their own flag so .reconnect enables.
        if (kind == .session_ended) self.context.session_ended = true;
        self.selected_index = firstEnabled(kind, self.context);
    }

    /// Keyboard selection skips disabled rows entirely: they are not
    /// reachable via ↑↓ (matching the mockups' disabled styling). Ring
    /// search stops after one full cycle (all-disabled case keeps the
    /// current index).
    pub fn move(self: *State, delta: i32) void {
        const kind = self.open orelse return;
        const list = menus.items(kind, self.context);
        if (list.len == 0) return;
        const n: i32 = @intCast(list.len);
        var index: i32 = @intCast(self.selected_index);
        var hops: i32 = 0;
        while (hops < n) : (hops += 1) {
            index = @mod(index + delta, n);
            if (menus.isEnabled(list[@intCast(index)].action, self.context)) break;
        }
        self.selected_index = @intCast(index);
    }

    pub fn selected(self: State) ?menus.Action {
        const kind = self.open orelse return null;
        const list = menus.items(kind, self.context);
        if (self.selected_index >= list.len) return null;
        return list[self.selected_index].action;
    }

    pub fn selectedEnabled(self: State) bool {
        const action = self.selected() orelse return false;
        return menus.isEnabled(action, self.context);
    }

    pub fn handle(self: *State, input: Input) ?menus.Action {
        if (self.open == null) return null;
        switch (input) {
            .up => self.move(-1),
            .down => self.move(1),
            .escape, .click_outside => self.dismiss(),
            .enter => {
                const action = self.selected() orelse return null;
                if (!self.selectedEnabled()) return null;
                self.dismiss();
                return action;
            },
        }
        return null;
    }

    fn firstEnabled(kind: menus.Kind, context: menus.Context) usize {
        const list = menus.items(kind, context);
        for (list, 0..) |item, index| {
            if (menus.isEnabled(item.action, context)) return index;
        }
        return 0;
    }
};

pub fn kindFor(trigger: Trigger) menus.Kind {
    return switch (trigger) {
        .terminal_middle_click, .terminal_right_click => .terminal,
        .host_right_click => .host_asset,
        .session_banner => .session_ended,
        .tab_right_click => .tab,
    };
}

test "menu trigger routing keeps contexts separate" {
    try std.testing.expectEqual(menus.Kind.terminal, kindFor(.terminal_middle_click));
    try std.testing.expectEqual(menus.Kind.terminal, kindFor(.terminal_right_click));
    try std.testing.expectEqual(menus.Kind.host_asset, kindFor(.host_right_click));
    try std.testing.expectEqual(menus.Kind.session_ended, kindFor(.session_banner));
    try std.testing.expectEqual(menus.Kind.tab, kindFor(.tab_right_click));
}

test "menu state wraps selection and dismisses" {
    var state: State = .{};
    state.show(.host_asset, .{});
    try std.testing.expectEqual(menus.Action.new_tab, state.selected().?);
    try std.testing.expect(state.selectedEnabled());
    state.move(-1);
    try std.testing.expectEqual(menus.Action.delete_host, state.selected().?);
    state.move(1);
    try std.testing.expectEqual(menus.Action.new_tab, state.selected().?);
    state.dismiss();
    try std.testing.expect(state.selected() == null);
}

test "menu input commits enabled action and ignores disabled action" {
    var state: State = .{};
    // Opening skips disabled AI/copy rows and highlights Paste. A stale/direct
    // selection of the disabled Copy row still cannot commit it.
    state.show(.terminal, .{});
    try std.testing.expectEqual(menus.Action.paste, state.selected().?);
    state.selected_index = 1;
    try std.testing.expect(state.handle(.enter) == null);
    try std.testing.expect(state.open != null);
    state.show(.host_asset, .{});
    try std.testing.expectEqual(menus.Action.new_tab, state.handle(.enter).?);
    try std.testing.expect(state.open == null);
    state.show(.host_asset, .{});
    _ = state.handle(.escape);
    try std.testing.expect(state.open == null);
}

test "keyboard selection skips disabled rows" {
    var state: State = .{};
    // Terminal menu without selection: ask_ai/copy/export disabled.
    state.show(.terminal, .{});
    try std.testing.expect(state.selectedEnabled());
    try std.testing.expectEqual(menus.Action.paste, state.selected().?);
    // Wrapping ↑ from paste must not land on a disabled action.
    state.move(-1);
    try std.testing.expect(state.selectedEnabled());
}

test "close-others disabled with a single tab" {
    var state: State = .{};
    state.show(.tab, .{ .multi_tabs = false });
    var hops: usize = 0;
    while (hops < 9) : (hops += 1) state.move(1);
    try std.testing.expect(state.selected() != menus.Action.close_others);
}

test "keyboard menus never select or execute actions hidden by the shared snapshot" {
    const owner: @import("../host/identity.zig").SessionHandle = .{ .session_id = @fromBackingInt(5) };
    const services = [_]@import("../host/capability_snapshot.zig").ServiceState{.{ .key = .{ .name = "lifecycle" }, .declared = true, .available = true, .authorized = true, .revision = 1 }};
    var state: State = .{};
    state.show(.tab, .{ .multi_tabs = true, .has_saved_connection = true, .capability_snapshot = .{ .owner = owner, .revision = 1, .services = &services } });
    for (0..12) |_| {
        try std.testing.expect(state.selectedEnabled());
        try std.testing.expect(menus.isVisible(state.selected().?, state.context));
        try std.testing.expect(state.selected().? != .clone_session);
        try std.testing.expect(state.selected().? != .view_jump_chain);
        try std.testing.expect(state.selected().? != .export_session);
        state.move(1);
    }
    for (menus.items(.tab, state.context), 0..) |item, index| {
        if (menus.isVisible(item.action, state.context)) continue;
        state.selected_index = index;
        try std.testing.expect(state.handle(.enter) == null);
        try std.testing.expect(state.open != null);
    }
}
