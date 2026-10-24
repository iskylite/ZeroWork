//! Public SDK model -> real HWND menu -> native command -> targeted SDK event.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const Sdk = @FieldType(App, "sdk");
const Model = @import("zenit_reflection").params(@TypeOf(Sdk.setMenuModel))[1].type.?;
const MenuNode = std.meta.Elem(@FieldType(Model, "nodes"));
extern "user32" fn GetMenu(*anyopaque) callconv(.winapi) ?*anyopaque;
extern "user32" fn GetSubMenu(*anyopaque, c_int) callconv(.winapi) ?*anyopaque;
extern "user32" fn GetMenuItemID(*anyopaque, c_int) callconv(.winapi) u32;
extern "user32" fn GetMenuState(*anyopaque, u32, u32) callconv(.winapi) u32;
extern "user32" fn GetMenuStringW(*anyopaque, u32, [*]u16, c_int, u32) callconv(.winapi) c_int;
extern "user32" fn SendMessageW(*anyopaque, u32, usize, isize) callconv(.winapi) isize;
extern fn zenit_win_menu_clear(*anyopaque) c_int;
extern fn zenit_windows_contract_keyboard_isolated(*anyopaque) c_int;
extern fn zenit_windows_contract_key(*anyopaque, u16, u32, c_int) c_int;
var stage: []const u8 = "initial";
extern fn zenit_win_menu_translate(*anyopaque, *anyopaque) c_int;
extern "user32" fn GetKeyboardState([*]u8) callconv(.winapi) c_int;
extern "user32" fn SetKeyboardState([*]const u8) callconv(.winapi) c_int;
const Message = extern struct { hwnd: *anyopaque, message: u32, wparam: usize, lparam: isize, time: u32 = 0, x: i32 = 0, y: i32 = 0, private: u32 = 0 };
fn shortcut(app: *App) !void {
    var original: [256]u8 = undefined;
    try require(GetKeyboardState(&original) != 0);
    defer _ = SetKeyboardState(&original);
    var pressed = @as([256]u8, @splat(0));
    pressed[0x11] = 0x80;
    pressed[0xa2] = 0x80;
    try require(SetKeyboardState(&pressed) != 0);
    var message = Message{ .hwnd = app.win.getNativeSurfaceHandle(), .message = 0x100, .wparam = 'S', .lparam = 1 };
    try require(zenit_win_menu_translate(message.hwnd, &message) != 0);
}
fn require(ok: bool) !void {
    if (!ok) {
        std.log.err("menu stage: {s}", .{stage});
        return error.MenuContractFailed;
    }
}
fn menuEvents(app: *App, expected: ?u64) !void {
    _ = try app.sdk.pump(0);
    var count: usize = 0;
    for (app.sdk.events()) |event| if (event == .menu_command) {
        count += 1;
        try require(event.menu_command.command_id == expected and event.menu_command.window_id == app.windowId());
    };
    try require(count == @as(usize, if (expected != null) 1 else 0));
}
pub fn run(app: *App) !void {
    const owner = app.win.getNativeSurfaceHandle();
    const size = app.win.getSize();
    const was_isolated = zenit_windows_contract_keyboard_isolated(owner) != 0;
    defer app.win.setKeyboardIsolated(was_isolated);
    app.win.setKeyboardIsolated(false);
    defer {
        _ = zenit_win_menu_clear(owner);
        app.win.setSize(size[0], size[1]);
    }
    try require(app.sdk.capabilities.menu_bar);
    const command: u64 = 0x123456789abcdef0;
    var nodes = [_]MenuNode{
        .{ .id = 1, .kind = .menu, .label = "文件 & 中文 😀" },
        .{ .id = 2, .parent_id = 1, .kind = .item, .label = "保存", .command_id = command, .key_equivalent = "s", .modifiers = .{ .ctrl = true }, .checked = true },
        .{ .id = 3, .parent_id = 1, .kind = .item, .label = "禁用", .command_id = 3, .enabled = false },
        .{ .id = 4, .parent_id = 1, .kind = .separator },
        .{ .id = 5, .parent_id = 1, .kind = .menu, .label = "子菜单" },
        .{ .id = 6, .parent_id = 5, .kind = .item, .label = "复制", .role = .copy },
    };
    try app.sdk.setMenuModel(.{ .nodes = &nodes });
    stage = "native labels and states";
    const root = GetMenu(owner) orelse return error.MissingMenu;
    const menu = GetSubMenu(root, 0) orelse return error.MissingSubmenu;
    var text: [128]u16 = undefined;
    const len = GetMenuStringW(root, 0, &text, text.len, 0x400);
    const label = try std.unicode.utf16LeToUtf8Alloc(app.allocator, text[0..@intCast(len)]);
    defer app.allocator.free(label);
    try require(std.mem.eql(u8, label, "文件 && 中文 😀"));
    try require(GetMenuState(menu, 0, 0x400) & 8 != 0 and GetMenuState(menu, 1, 0x400) & 3 != 0);
    const shortcut_len = GetMenuStringW(menu, 0, &text, text.len, 0x400);
    const shortcut_label = try std.unicode.utf16LeToUtf8Alloc(app.allocator, text[0..@intCast(shortcut_len)]);
    defer app.allocator.free(shortcut_label);
    try require(std.mem.eql(u8, shortcut_label, "保存\tCtrl+S"));
    stage = "disabled and 64-bit command";
    const old_id = GetMenuItemID(menu, 0);
    _ = SendMessageW(owner, 0x111, GetMenuItemID(menu, 1), 0);
    try menuEvents(app, null);
    _ = SendMessageW(owner, 0x111, old_id, 0);
    try menuEvents(app, command);
    stage = "native accelerator translation";
    try shortcut(app);
    try menuEvents(app, command);
    if (@import("zenit_app").test_harness.enabled) {
        stage = "isolated native keyboard and owned injection";
        app.win.setKeyboardIsolated(true);
        try shortcut(app);
        try menuEvents(app, null);
        _ = SendMessageW(owner, 0x104, 0x73, 1 << 29); // Alt+F4 must not close.
        _ = SendMessageW(owner, 0x100, 'X', 1);
        _ = SendMessageW(owner, 0x102, 'x', 1);
        _ = SendMessageW(owner, 0x10d, 0, 0); // IME start must not mutate state.
        _ = SendMessageW(owner, 0x10f, 0, 0); // IME composition.
        _ = SendMessageW(owner, 0x10e, 0, 0); // IME end.
        _ = try app.sdk.pump(0);
        for (app.sdk.events()) |event| switch (event) {
            .key, .text_input, .ime_preedit, .ime_commit, .window_close_requested => return error.IsolationLeak,
            else => {},
        };
        try require(zenit_windows_contract_key(owner, 0x87, 0, 1) != 0);
        _ = try app.sdk.pump(0);
        var owned_keys: usize = 0;
        for (app.sdk.events()) |event| {
            if (event == .key) owned_keys += 1;
            app.processTestContractEvent(event);
        }
        try require(owned_keys == 1);
        _ = SendMessageW(owner, 0x111, old_id, 0); // Programmatic menu remains available.
        try menuEvents(app, command);
        app.win.setKeyboardIsolated(false);
        try shortcut(app);
        try menuEvents(app, command);
    }
    // Failed installation must preserve the committed menu and command map.
    stage = "atomic rejected role";
    nodes[5].role = .services;
    if (app.sdk.setMenuModel(.{ .nodes = &nodes })) |_| return error.AcceptedInertRole else |err| try require(err == error.NotSupported);
    try require(GetMenu(owner) == root);
    nodes[5].role = .copy;
    _ = SendMessageW(owner, 0x111, old_id, 0); // pending old command must be discarded
    stage = "replacement and stale commands";
    nodes[1].command_id = command + 1;
    try app.sdk.setMenuModel(.{ .nodes = &nodes });
    try menuEvents(app, null);
    _ = SendMessageW(owner, 0x111, old_id, 0);
    try menuEvents(app, null);
    const new_menu = GetSubMenu(GetMenu(owner).?, 0).?;
    _ = SendMessageW(owner, 0x111, GetMenuItemID(new_menu, 0), 0);
    try menuEvents(app, command + 1);
    stage = "native edit action";
    const submenu = GetSubMenu(new_menu, 3).?;
    _ = SendMessageW(owner, 0x111, GetMenuItemID(submenu, 0), 0);
    _ = try app.sdk.pump(0);
    var down = false;
    var up = false;
    for (app.sdk.events()) |event| if (event == .key and event.key.keycode == 'C' and event.key.modifiers.ctrl) {
        if (event.key.pressed) down = true else up = true;
    };
    try require(down and up);
    app.win.setSize(size[0], size[1]);
    stage = "client size with menu";
    const with_menu = app.win.getSize();
    try require(with_menu[0] == size[0] and with_menu[1] == size[1]);
}

const old_command: u64 = 0x123456789abcdef0;
const new_command: u64 = old_command + 1;
const disabled_command: u64 = old_command + 2;
pub const Live = struct {
    app: *App,
    panel: *ui.Node,
    status: *ui.Node,
    old_count: u32 = 0,
    new_count: u32 = 0,
    disabled_count: u32 = 0,
    old_native: u32 = 0,
    buffer: [96]u8 = undefined,

    fn refresh(self: *@This()) void {
        const text = std.fmt.bufPrint(&self.buffer, "old={d} new={d} disabled={d}", .{ self.old_count, self.new_count, self.disabled_count }) catch unreachable;
        self.status.setText(.{ .content = text, .font_size = 18, .color = ui.Color.WHITE });
    }
    fn failed(self: *@This(), err: anyerror) void {
        std.log.err("live menu: {s}", .{@errorName(err)});
        self.status.setText(.{ .content = "live-menu=FAIL", .font_size = 18, .color = ui.Color.WHITE });
    }
    fn model(self: *@This(), command: u64) !void {
        const nodes = [_]MenuNode{
            .{ .id = 1, .kind = .menu, .label = "Native commands" },
            .{ .id = 2, .parent_id = 1, .kind = .item, .label = "Apply", .command_id = command, .key_equivalent = "s", .modifiers = .{ .ctrl = true } },
            .{ .id = 3, .parent_id = 1, .kind = .item, .label = "Disabled", .command_id = disabled_command, .enabled = false },
        };
        const size = self.app.win.getSize();
        try self.app.sdk.setMenuModel(.{ .nodes = &nodes });
        self.app.win.setSize(size[0], size[1]);
    }
    pub fn install(self: *@This()) void {
        self.panel.setDisplay(.flex);
        self.old_count = 0;
        self.new_count = 0;
        self.disabled_count = 0;
        self.model(old_command) catch |err| {
            self.failed(err);
            return;
        };
        const menu = GetSubMenu(GetMenu(self.app.win.getNativeSurfaceHandle()).?, 0).?;
        self.old_native = GetMenuItemID(menu, 0);
        self.refresh();
    }
    fn send(self: *@This(), id: u32) void {
        _ = SendMessageW(self.app.win.getNativeSurfaceHandle(), 0x111, id, 0);
        // Deliberately no SDK pump, handleCommand, action dispatch or refresh.
        // The normal App loop must deliver the event and update visible state.
    }
    pub fn fire(self: *@This()) void {
        self.send(self.old_native);
    }
    pub fn accelerator(self: *@This()) void {
        if (GetMenu(self.app.win.getNativeSurfaceHandle()) == null) return;
        shortcut(self.app) catch |err| self.failed(err);
    }
    pub fn disabled(self: *@This()) void {
        const root = GetMenu(self.app.win.getNativeSurfaceHandle()) orelse return;
        const menu = GetSubMenu(root, 0) orelse return;
        self.send(GetMenuItemID(menu, 1));
    }
    pub fn replace(self: *@This()) void {
        self.model(new_command) catch |err| {
            self.failed(err);
            return;
        };
        self.send(self.old_native);
    }
    pub fn fireNew(self: *@This()) void {
        const root = GetMenu(self.app.win.getNativeSurfaceHandle()) orelse return;
        const menu = GetSubMenu(root, 0) orelse return;
        self.send(GetMenuItemID(menu, 0));
    }
    pub fn clear(self: *@This()) void {
        const size = self.app.win.getSize();
        if (zenit_win_menu_clear(self.app.win.getNativeSurfaceHandle()) == 0) {
            self.failed(error.ClearFailed);
            return;
        }
        self.app.win.setSize(size[0], size[1]);
        self.send(self.old_native);
    }
    fn action(action_: ui.actions.Action, context: ?*anyopaque) ui.events.EventResult {
        const self: *@This() = @ptrCast(@alignCast(context orelse return .ignored));
        if (std.mem.eql(u8, action_.name, "old")) self.old_count += 1 else if (std.mem.eql(u8, action_.name, "new")) self.new_count += 1 else if (std.mem.eql(u8, action_.name, "disabled")) self.disabled_count += 1 else return .ignored;
        self.refresh();
        return .handled;
    }
};
pub fn mountLive(app: *App, cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node) !*Live {
    const panel = try ui.box(cx, .{ .display = .none, .width = .{ .grow = .{} }, .height = .{ .px = 110 }, .direction = .column, .gap = 12 }, .{});
    try parent.appendChild(cx.allocator, panel);
    const status = try ui.text(cx, "old=0 new=0 disabled=0", .{ .font_size = 18, .color = ui.Color.WHITE });
    status.meta.ownership.meta.test_id = "menu.live.status";
    try panel.appendChild(cx.allocator, status);
    const state = try cx.bindState(Live, .{ .app = app, .panel = panel, .status = status });
    panel.behavior.interaction.key_context = "win-menu-live";
    panel.behavior.events.on_action = Live.action;
    panel.behavior.events.action_context = state;
    cx.bindCommandAction(old_command, .{ .context = "win-menu-live", .name = "old" });
    cx.bindCommandAction(new_command, .{ .context = "win-menu-live", .name = "new" });
    cx.bindCommandAction(disabled_command, .{ .context = "win-menu-live", .name = "disabled" });
    const row = try ui.box(cx, .{ .width = .{ .grow = .{} }, .direction = .row, .gap = 8 }, .{});
    try panel.appendChild(cx.allocator, row);
    const specs = .{
        .{ "Fire", "menu.live.fire", Live.fire },             .{ "Shortcut", "menu.live.shortcut", Live.accelerator },
        .{ "Disabled", "menu.live.disabled", Live.disabled }, .{ "Replace", "menu.live.replace", Live.replace },
        .{ "New", "menu.live.new", Live.fireNew },            .{ "Clear", "menu.live.clear", Live.clear },
    };
    inline for (specs) |spec| {
        const button = try ui.widgets.Button(.{ .label = spec[0], .on_click = cx.on(Live, state, spec[2]) }).mount(scope, cx);
        button.meta.ownership.meta.test_id = spec[1];
        try row.appendChild(cx.allocator, button);
    }
    return state;
}
