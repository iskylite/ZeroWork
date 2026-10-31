const std = @import("std");
const actions = @import("../host/actions.zig");
const capabilities = @import("../host/capability_snapshot.zig");

pub const Kind = enum { terminal, host_asset, session_ended, tab };
pub const Action = enum {
    ask_ai,
    copy,
    paste,
    upload_file,
    download_file,
    toggle_block_selection,
    toggle_timestamp,
    history,
    command_history,
    search,
    export_selection,
    new_tab,
    new_window,
    reuse_connection,
    clone_host,
    edit_host,
    pin_host,
    move_group,
    delete_host,
    reconnect,
    close_session,
    // Tab (page) context menu, mockup-tab-context.
    rename_tab,
    tab_color,
    clone_session,
    view_jump_chain,
    open_theme,
    export_session,
    close_others,
    start_background_socks,
    manage_background_socks,
};

pub const Item = struct {
    action: Action,
    label: []const u8,
    icon: []const u8 = "•",
    shortcut: ?[]const u8 = null,
    separator_before: bool = false,
    danger: bool = false,
};

pub fn isVisible(action: Action, context: Context) bool {
    if (context.has_saved_connection) |saved| if (!saved and action == .edit_host) return false;
    if (context.capability_snapshot) |snapshot| if (catalogAction(action)) |id| return actions.project(id, snapshot).visible;
    return true;
}
pub fn projection(action: Action, context: Context) ?capabilities.Projection {
    const snapshot = context.capability_snapshot orelse return null;
    return actions.project(catalogAction(action) orelse return null, snapshot);
}
/// The menu maps labels to the shared business catalog, never maintains a
/// second provider/capability table of its own.
fn catalogAction(action: Action) ?actions.ActionId {
    return switch (action) {
        .ask_ai => .toggle_ai,
        .copy => .copy,
        .paste => .paste,
        .upload_file => .upload,
        .download_file => .download,
        .toggle_block_selection, .search => .search_terminal,
        .toggle_timestamp => .toggle_timestamp,
        .history => .open_history,
        .command_history => .open_history,
        .export_selection, .export_session => .export_record,
        .new_tab, .reuse_connection => .create_sibling_session,
        .edit_host => .edit_connection,
        .reconnect => .reconnect,
        .close_session => .request_close,
        .rename_tab => .rename_tab,
        .clone_session => .duplicate_session,
        .view_jump_chain => .open_route_details,
        .open_theme => .open_theme_chooser,
        .close_others => .close_other_tabs,
        .start_background_socks, .manage_background_socks => .toggle_socks,
        else => null,
    };
}
pub fn isEnabled(action: Action, context: Context) bool {
    if (!isVisible(action, context)) return false;
    if (projection(action, context)) |value| if (!value.enabled) return false;
    return switch (action) {
        .new_window => context.new_window_available,
        .reuse_connection => context.reuse_connection_available and !context.session_ended,
        .ask_ai, .copy, .export_selection => context.has_selection,
        .reconnect => context.session_ended,
        .paste => !context.read_only,
        .upload_file, .download_file => (context.capability_snapshot != null or context.transfer_available) and !context.read_only and !context.session_ended,
        .close_others => context.multi_tabs,
        .start_background_socks => context.background_socks and !context.background_active,
        .manage_background_socks => context.background_socks and context.background_active,
        else => true,
    };
}

pub const Context = struct {
    capability_snapshot: ?capabilities.Snapshot = null,
    has_saved_connection: ?bool = null,
    new_window_available: bool = false,
    reuse_connection_available: bool = false,
    local_session: bool = false,
    read_only: bool = false,
    has_selection: bool = false,
    session_ended: bool = false,
    /// Tab menu: "关闭其他页签" needs more than one open tab.
    multi_tabs: bool = false,
    transfer_available: bool = false,
    background_socks: bool = false,
    background_active: bool = false,
};

pub fn items(kind: Kind, context: Context) []const Item {
    return switch (kind) {
        .terminal => if (context.local_session) &local_terminal else if (context.has_selection) &terminal_selection else &terminal_empty,
        .host_asset => if (context.background_socks) (if (context.background_active) &host_background_active else &host_background_available) else &host_asset,
        .session_ended => if (context.local_session) &local_tab else &session_ended,
        .tab => if (context.local_session) &local_tab else &tab_menu,
    };
}

/// Tab (page) context menu — mockup-tab-context: session lifecycle and
/// per-tab configuration; deliberately disjoint from terminal text actions.
const tab_menu = [_]Item{
    .{ .action = .rename_tab, .label = "重命名页签", .icon = "pencil", .shortcut = "⌘⇧R" },
    .{ .action = .tab_color, .label = "页签颜色", .icon = "palette" },
    .{ .action = .new_tab, .label = "新标签连接", .icon = "plus" },
    .{ .action = .reuse_connection, .label = "复用连接", .icon = "copy" },
    .{ .action = .new_window, .label = "新窗口连接", .icon = "app-window" },
    .{ .action = .edit_host, .label = "编辑主机配置", .icon = "settings" },
    .{ .action = .view_jump_chain, .label = "通信链路", .icon = "network" },
    .{ .action = .open_theme, .label = "全局主题", .icon = "palette" },
    .{ .action = .export_session, .label = "导出记录", .icon = "download" },
    .{ .action = .close_others, .label = "关闭其他页签", .icon = "x" },
    .{ .action = .close_session, .label = "断开并关闭", .icon = "⏻", .shortcut = "⌘W", .danger = true },
};

// Mount delivered Local services only; never inherit remote asset operations.
const local_tab = [_]Item{
    .{ .action = .new_tab, .label = "新建本地会话", .icon = "plus" },
    .{ .action = .clone_session, .label = "复制会话与目录", .icon = "copy" },
    .{ .action = .rename_tab, .label = "重命名", .icon = "pencil", .shortcut = "⌘⇧R" },
    .{ .action = .tab_color, .label = "页签颜色", .icon = "palette" },
    .{ .action = .command_history, .label = "命令历史", .icon = "list-restart", .shortcut = "⇧⌘B" },
    .{ .action = .history, .label = "当前会话历史", .icon = "history" },
    .{ .action = .search, .label = "搜索终端", .icon = "search", .shortcut = "⌘F" },
    .{ .action = .export_session, .label = "导出会话记录", .icon = "download" },
    .{ .action = .close_session, .label = "关闭本地会话", .icon = "x", .shortcut = "⌘W", .danger = true },
};
const local_terminal = [_]Item{
    .{ .action = .copy, .label = "复制选区", .icon = "copy", .shortcut = "⌘C" },
    .{ .action = .paste, .label = "粘贴", .icon = "clipboard", .shortcut = "⌘V / 右键" },
    .{ .action = .toggle_block_selection, .label = "矩形选择：⌥ + 拖拽", .icon = "text-select", .separator_before = true },
    .{ .action = .toggle_timestamp, .label = "时间戳", .icon = "clock" },
    .{ .action = .open_theme, .label = "全局主题", .icon = "palette" },
    .{ .action = .command_history, .label = "命令历史", .icon = "list-restart", .shortcut = "⇧⌘B" },
    .{ .action = .history, .label = "当前会话历史", .icon = "history" },
    .{ .action = .search, .label = "在终端中搜索", .icon = "search", .shortcut = "⌘F", .separator_before = true },
    .{ .action = .export_selection, .label = "导出选中内容…", .icon = "download" },
};

test "local menus expose current local capabilities without remote or future operations" {
    for ([_]Kind{ .tab, .session_ended }) |kind| {
        const list = items(kind, .{ .local_session = true });
        try std.testing.expectEqual(@as(usize, 9), list.len);
        try std.testing.expectEqual(Action.new_tab, list[0].action);
        try std.testing.expectEqual(Action.clone_session, list[1].action);
        try std.testing.expect(list[1].shortcut == null);
        try std.testing.expectEqual(Action.tab_color, list[3].action);
        try std.testing.expectEqual(Action.command_history, list[4].action);
        try std.testing.expectEqual(Action.history, list[5].action);
        try std.testing.expectEqual(Action.search, list[6].action);
        try std.testing.expectEqual(Action.export_session, list[7].action);
        for (list) |item| try std.testing.expect(item.action != .edit_host and item.action != .view_jump_chain and item.action != .reconnect);
    }
    const context: Context = .{ .local_session = true };
    try std.testing.expect(!isEnabled(.copy, context));
    try std.testing.expect(isEnabled(.paste, context));
    try std.testing.expect(!isEnabled(.paste, .{ .local_session = true, .read_only = true }));
    try std.testing.expect(isEnabled(.copy, .{ .local_session = true, .read_only = true, .has_selection = true }));
    try std.testing.expect(!isEnabled(.export_selection, context));
    const terminal = items(.terminal, context);
    try std.testing.expectEqual(Action.command_history, terminal[5].action);
    try std.testing.expectEqual(Action.history, terminal[6].action);
    try std.testing.expectEqual(Action.search, terminal[7].action);
    try std.testing.expectEqual(Action.export_selection, terminal[8].action);
}

test "new-window action stays unavailable until shared application host supports it" {
    try std.testing.expect(!isEnabled(.new_window, .{}));
    try std.testing.expect(isEnabled(.new_window, .{ .new_window_available = true }));
}

const terminal_selection = [_]Item{
    .{ .action = .ask_ai, .label = "问 AI（附选中输出）", .icon = "✨", .shortcut = "⌘J" },
    .{ .action = .copy, .label = "复制", .icon = "⧉", .shortcut = "⌘C" },
    .{ .action = .paste, .label = "粘贴", .icon = "📋", .shortcut = "⌘V" },
    .{ .action = .upload_file, .label = "上传文件", .icon = "upload" },
    .{ .action = .download_file, .label = "下载文件", .icon = "download" },
    .{ .action = .toggle_block_selection, .label = "矩形块选模式", .icon = "▭", .shortcut = "⌥+拖拽", .separator_before = true },
    .{ .action = .toggle_timestamp, .label = "时间戳侧栏", .icon = "🕐", .shortcut = "@ts" },
    .{ .action = .command_history, .label = "命令历史", .icon = "list-restart", .shortcut = "⇧⌘B" },
    .{ .action = .history, .label = "历史回溯", .icon = "📜", .shortcut = "@log" },
    .{ .action = .search, .label = "在终端中搜索", .icon = "🔍", .shortcut = "⌘F", .separator_before = true },
    .{ .action = .export_selection, .label = "导出选中内容…", .icon = "⇪" },
};

const terminal_empty = [_]Item{
    .{ .action = .ask_ai, .label = "问 AI（附选中输出）", .icon = "✨", .shortcut = "⌘J" },
    .{ .action = .copy, .label = "复制", .icon = "⧉", .shortcut = "⌘C" },
    .{ .action = .paste, .label = "粘贴", .icon = "📋", .shortcut = "⌘V" },
    .{ .action = .upload_file, .label = "上传文件", .icon = "upload" },
    .{ .action = .download_file, .label = "下载文件", .icon = "download" },
    .{ .action = .toggle_block_selection, .label = "矩形块选模式", .icon = "▭", .shortcut = "⌥+拖拽", .separator_before = true },
    .{ .action = .toggle_timestamp, .label = "时间戳侧栏", .icon = "🕐", .shortcut = "@ts" },
    .{ .action = .command_history, .label = "命令历史", .icon = "list-restart", .shortcut = "⇧⌘B" },
    .{ .action = .history, .label = "历史回溯", .icon = "📜", .shortcut = "@log" },
    .{ .action = .search, .label = "在终端中搜索", .icon = "🔍", .shortcut = "⌘F", .separator_before = true },
    .{ .action = .export_selection, .label = "导出选中内容…", .icon = "⇪" },
};

const host_asset = [_]Item{
    .{ .action = .new_tab, .label = "新标签连接", .icon = "▶", .shortcut = "双击同效" },
    .{ .action = .new_window, .label = "新窗口连接", .icon = "🗔" },
    .{ .action = .clone_host, .label = "复制配置（克隆主机）", .icon = "⧉", .separator_before = true },
    .{ .action = .edit_host, .label = "修改连接配置…", .icon = "✏️" },
    .{ .action = .history, .label = "查看历史会话日志", .icon = "📜" },
    .{ .action = .pin_host, .label = "置顶到分组首位", .icon = "📌" },
    .{ .action = .move_group, .label = "移动分组 ▸", .icon = "📁", .separator_before = true },
    .{ .action = .delete_host, .label = "删除主机", .icon = "🗑", .danger = true },
};
const host_background_available = host_asset[0..2].* ++ [_]Item{.{ .action = .start_background_socks, .label = "仅开启 SOCKS5 转发", .icon = "plug-zap" }} ++ host_asset[2..].*;
const host_background_active = host_asset[0..2].* ++ [_]Item{.{ .action = .manage_background_socks, .label = "管理后台转发", .icon = "plug-zap" }} ++ host_asset[2..].*;

test "background SOCKS menu exposes only saved SSH capability and original background management" {
    const absent = items(.host_asset, .{});
    for (absent) |item| try std.testing.expect(item.action != .start_background_socks and item.action != .manage_background_socks);
    const available = items(.host_asset, .{ .background_socks = true });
    try std.testing.expectEqual(Action.start_background_socks, available[2].action);
    try std.testing.expect(isEnabled(available[2].action, .{ .background_socks = true }));
    const active = items(.host_asset, .{ .background_socks = true, .background_active = true });
    try std.testing.expectEqual(Action.manage_background_socks, active[2].action);
    try std.testing.expect(!isEnabled(.start_background_socks, .{ .background_socks = true, .background_active = true }));
}

const session_ended = [_]Item{
    .{ .action = .reconnect, .label = "重新连接", .icon = "↻", .shortcut = "" },
    .{ .action = .history, .label = "回溯历史 @log", .icon = "📜" },
    .{ .action = .close_session, .label = "关闭", .icon = "✕", .separator_before = true },
};

test "menu actions respect selection and session context" {
    try std.testing.expect(!isEnabled(.copy, .{}));
    try std.testing.expect(isEnabled(.copy, .{ .has_selection = true }));
    try std.testing.expect(!isEnabled(.reconnect, .{}));
    try std.testing.expect(isEnabled(.reconnect, .{ .session_ended = true }));
}

test "context menus keep terminal and host actions separate" {
    const terminal = items(.terminal, .{});
    const host = items(.host_asset, .{});
    try std.testing.expectEqual(@as(usize, 11), terminal.len);
    try std.testing.expectEqual(Action.copy, terminal[1].action);
    try std.testing.expectEqual(Action.new_tab, host[0].action);
    try std.testing.expect(host[7].danger);
    try std.testing.expectEqual(Action.reconnect, items(.session_ended, .{ .session_ended = true })[0].action);
}

test "tab menu carries session lifecycle actions, disjoint from text ops" {
    const tab = items(.tab, .{});
    try std.testing.expectEqual(@as(usize, 11), tab.len);
    try std.testing.expectEqual(Action.rename_tab, tab[0].action);
    // Terminal text operations never appear on the tab menu (zero-overlap rule).
    for (tab) |item| {
        try std.testing.expect(item.action != .copy);
        try std.testing.expect(item.action != .paste);
        try std.testing.expect(item.action != .search);
    }
    // Danger styling on disconnect+close.
    try std.testing.expect(tab[10].danger);
    try std.testing.expectEqual(Action.close_session, tab[10].action);
    // "Close others" requires multiple open tabs.
    try std.testing.expect(!isEnabled(.close_others, .{ .multi_tabs = false }));
    try std.testing.expect(isEnabled(.close_others, .{ .multi_tabs = true }));
}

test "SSH connection actions are confined to the tab menu" {
    const tab = items(.tab, .{});
    try std.testing.expectEqual(Action.new_tab, tab[2].action);
    try std.testing.expectEqual(Action.reuse_connection, tab[3].action);
    try std.testing.expectEqual(Action.new_window, tab[4].action);
    for ([_]Context{ .{}, .{ .has_selection = true }, .{ .local_session = true } }) |context| {
        for (items(.terminal, context)) |item| {
            try std.testing.expect(item.action != .new_tab and item.action != .reuse_connection and item.action != .new_window);
        }
    }
    try std.testing.expect(!isEnabled(.reuse_connection, .{}));
    try std.testing.expect(isEnabled(.reuse_connection, .{ .reuse_connection_available = true }));
    try std.testing.expect(!isEnabled(.reuse_connection, .{ .reuse_connection_available = true, .session_ended = true }));
}
