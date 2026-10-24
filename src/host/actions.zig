//! Stable business actions shared by shortcuts, tab menus and @ commands.
//! This catalog contains no handlers: callers must supply live capability and
//! owner checks before dispatching through the owning controller.
const std = @import("std");
const keys = @import("../config/keybindings.zig");
const capability_snapshot = @import("capability_snapshot.zig");
const identity = @import("identity.zig");

pub const Chord = keys.Chord;

/// Explicit values and action_id strings are independent of labels/table order.
pub const ActionId = enum(u16) {
    open_session_chooser = 1,
    request_close = 2,
    tab_1 = 3,
    tab_2 = 4,
    tab_3 = 5,
    tab_4 = 6,
    tab_5 = 7,
    tab_6 = 8,
    tab_7 = 9,
    tab_8 = 10,
    tab_9 = 11,
    previous_tab = 12,
    next_tab = 13,
    recent_tab = 14,
    split_vertical = 15,
    split_horizontal = 16,
    copy = 17,
    paste = 18,
    search_terminal = 19,
    open_completion = 20,
    accept_completion = 21,
    quick_connect = 22,
    reconnect = 23,
    toggle_sidebar = 24,
    toggle_ai = 25,
    upload = 26,
    toggle_broadcast = 27,
    rename_tab = 28,
    create_sibling_session = 29,
    duplicate_session = 30,
    edit_connection = 31,
    open_route_details = 32,
    open_theme_chooser = 33,
    export_record = 34,
    close_other_tabs = 35,
    download = 36,
    join_group = 37,
    toggle_pin = 38,
    toggle_timestamp = 39,
    open_history = 40,
    toggle_socks = 41,
    open_command_help = 42,
    open_saved_connection = 43,
    create_temporary_ssh_session = 44,
    create_local_session = 45,
    request_close_window = 46,
};

pub const Capability = enum { terminal, session_factory, connection, saved_connection, route, transfer, groups, recording, ai, appearance, forward };
pub const Capabilities = struct {
    terminal: bool = false,
    session_factory: bool = false,
    connection: bool = false,
    saved_connection: bool = false,
    route: bool = false,
    transfer: bool = false,
    groups: bool = false,
    recording: bool = false,
    ai: bool = false,
    appearance: bool = false,
    forward: bool = false,

    pub fn has(self: Capabilities, capability: Capability) bool {
        return switch (capability) {
            inline else => |kind| @field(self, @tagName(kind)),
        };
    }
};

pub const Scope = enum { app, tab, terminal, text_input, trusted_prompt };
pub const Rule = struct {
    scope: Scope = .app,
    capabilities: []const Capability = &.{},
    needs_selection: bool = false,
    needs_group: bool = false,
    needs_other_tabs: bool = false,
    needs_writable: bool = false,
};

pub const Descriptor = struct {
    id: ActionId,
    action_id: []const u8,
    label: []const u8,
    default_chord: ?Chord = null,
    /// Only these 27 entries appear in the factory settings table.
    shortcut_action: ?keys.Action = null,
    /// Ctrl-Tab and Right are fixed context boundaries, not recordable keys.
    fixed_input_boundary: bool = false,
    rule: Rule = .{},
    unsupported_reason: []const u8 = "当前内容不支持此动作",
};

fn shortcut(id: ActionId, action_id: []const u8, label: []const u8, legacy: keys.Action, rule: Rule) Descriptor {
    return .{
        .id = id,
        .action_id = action_id,
        .label = label,
        .default_chord = (keys.Map{}).get(legacy),
        .shortcut_action = legacy,
        .fixed_input_boundary = legacy == .recent_tab or legacy == .accept_completion,
        .rule = rule,
        .unsupported_reason = if (id == .upload) "上传需要当前会话的传输能力" else "当前内容不支持此动作",
    };
}

pub const descriptors = [_]Descriptor{
    shortcut(.open_session_chooser, "workspace.new_session", "新建会话", .new_tab, .{}),
    shortcut(.request_close, "workspace.request_close", "断开并关闭", .close_tab, .{ .scope = .tab }),
    shortcut(.tab_1, "workspace.tab_1", "第 1 个页签", .tab_1, .{ .scope = .tab }),
    shortcut(.tab_2, "workspace.tab_2", "第 2 个页签", .tab_2, .{ .scope = .tab }),
    shortcut(.tab_3, "workspace.tab_3", "第 3 个页签", .tab_3, .{ .scope = .tab }),
    shortcut(.tab_4, "workspace.tab_4", "第 4 个页签", .tab_4, .{ .scope = .tab }),
    shortcut(.tab_5, "workspace.tab_5", "第 5 个页签", .tab_5, .{ .scope = .tab }),
    shortcut(.tab_6, "workspace.tab_6", "第 6 个页签", .tab_6, .{ .scope = .tab }),
    shortcut(.tab_7, "workspace.tab_7", "第 7 个页签", .tab_7, .{ .scope = .tab }),
    shortcut(.tab_8, "workspace.tab_8", "第 8 个页签", .tab_8, .{ .scope = .tab }),
    shortcut(.tab_9, "workspace.tab_9", "第 9 个页签", .tab_9, .{ .scope = .tab }),
    shortcut(.previous_tab, "workspace.previous_tab", "前一个页签", .previous_tab, .{ .scope = .tab }),
    shortcut(.next_tab, "workspace.next_tab", "后一个页签", .next_tab, .{ .scope = .tab }),
    shortcut(.recent_tab, "workspace.recent_tab", "最近使用的页签", .recent_tab, .{ .scope = .tab }),
    shortcut(.split_vertical, "workspace.split_vertical", "垂直分栏", .split_vertical, .{ .scope = .terminal, .capabilities = &.{ .terminal, .session_factory } }),
    shortcut(.split_horizontal, "workspace.split_horizontal", "水平分栏", .split_horizontal, .{ .scope = .terminal, .capabilities = &.{ .terminal, .session_factory } }),
    shortcut(.copy, "input.copy", "复制", .copy, .{ .scope = .text_input, .needs_selection = true }),
    shortcut(.paste, "input.paste", "粘贴", .paste, .{ .scope = .text_input, .needs_writable = true }),
    shortcut(.search_terminal, "terminal.search", "搜索当前终端", .search, .{ .scope = .terminal, .capabilities = &.{.terminal} }),
    shortcut(.open_completion, "terminal.open_completion", "打开候选", .completion, .{ .scope = .trusted_prompt, .capabilities = &.{.terminal}, .needs_writable = true }),
    shortcut(.accept_completion, "terminal.accept_completion", "采纳候选", .accept_completion, .{ .scope = .trusted_prompt, .capabilities = &.{.terminal}, .needs_writable = true }),
    shortcut(.quick_connect, "connection.quick_connect", "快捷连接", .quick_connect, .{}),
    shortcut(.reconnect, "connection.reconnect", "立即重连", .reconnect, .{ .scope = .tab, .capabilities = &.{.connection} }),
    shortcut(.toggle_sidebar, "workspace.toggle_sidebar", "切换侧栏", .sidebar, .{}),
    shortcut(.toggle_ai, "assistant.toggle", "AI 助手", .ai, .{ .scope = .tab, .capabilities = &.{.ai} }),
    shortcut(.upload, "transfer.upload", "上传", .upload, .{ .scope = .tab, .capabilities = &.{.transfer} }),
    shortcut(.toggle_broadcast, "group.toggle_broadcast", "切换广播", .broadcast, .{ .scope = .terminal, .capabilities = &.{ .terminal, .groups }, .needs_group = true }),
    .{ .id = .rename_tab, .action_id = "workspace.rename_tab", .label = "重命名页签", .default_chord = .{ .key = .r, .shift = true }, .rule = .{ .scope = .tab } },
    .{ .id = .create_sibling_session, .action_id = "session.create_sibling", .label = "新建同类会话", .rule = .{ .scope = .tab, .capabilities = &.{.session_factory} } },
    .{ .id = .duplicate_session, .action_id = "session.duplicate", .label = "镜像复制会话", .rule = .{ .scope = .terminal, .capabilities = &.{ .terminal, .session_factory } } },
    .{ .id = .edit_connection, .action_id = "connection.edit", .label = "编辑主机配置", .rule = .{ .scope = .tab, .capabilities = &.{.saved_connection} }, .unsupported_reason = "当前会话没有可编辑的已保存连接" },
    .{ .id = .open_route_details, .action_id = "connection.route_details", .label = "通信链路", .rule = .{ .scope = .tab, .capabilities = &.{.route} }, .unsupported_reason = "当前会话没有 SSH 通信链路" },
    .{ .id = .open_theme_chooser, .action_id = "appearance.choose_theme", .label = "全局主题", .rule = .{ .capabilities = &.{.appearance} } },
    .{ .id = .export_record, .action_id = "record.export", .label = "导出记录", .rule = .{ .scope = .tab, .capabilities = &.{.recording} } },
    .{ .id = .close_other_tabs, .action_id = "workspace.close_other_tabs", .label = "关闭其他页签", .rule = .{ .scope = .tab, .needs_other_tabs = true } },
    .{ .id = .download, .action_id = "transfer.download", .label = "下载", .rule = .{ .scope = .tab, .capabilities = &.{.transfer} }, .unsupported_reason = "下载需要当前会话的传输能力" },
    .{ .id = .join_group, .action_id = "group.join", .label = "加入或离开终端组", .rule = .{ .scope = .terminal, .capabilities = &.{ .terminal, .groups } } },
    .{ .id = .toggle_pin, .action_id = "group.toggle_pin", .label = "组内置顶", .rule = .{ .scope = .terminal, .capabilities = &.{ .terminal, .groups }, .needs_group = true } },
    .{ .id = .toggle_timestamp, .action_id = "terminal.toggle_timestamp", .label = "切换终端时间列", .rule = .{ .scope = .terminal, .capabilities = &.{.terminal} } },
    .{ .id = .open_history, .action_id = "record.open_history", .label = "打开只读历史页", .rule = .{ .scope = .tab, .capabilities = &.{.recording} } },
    .{ .id = .toggle_socks, .action_id = "forward.toggle_socks", .label = "切换 SOCKS5", .rule = .{ .scope = .tab, .capabilities = &.{.forward} }, .unsupported_reason = "SOCKS5 需要当前 SSH 会话的转发能力" },
    .{ .id = .open_command_help, .action_id = "command.help", .label = "应用指令帮助" },
    .{ .id = .open_saved_connection, .action_id = "connection.open_saved", .label = "连接已保存主机", .rule = .{ .capabilities = &.{.session_factory} } },
    .{ .id = .create_temporary_ssh_session, .action_id = "session.create_temporary_ssh", .label = "创建临时 SSH 会话", .rule = .{ .capabilities = &.{.session_factory} } },
    .{ .id = .create_local_session, .action_id = "session.create_local", .label = "创建本地会话", .rule = .{ .capabilities = &.{.session_factory} }, .unsupported_reason = "本地会话适配器尚未接入" },
    .{ .id = .request_close_window, .action_id = "window.request_close", .label = "关闭工作区窗口" },
};

pub const factory_shortcuts = blk: {
    var result: [27]ActionId = undefined;
    var index: usize = 0;
    for (descriptors) |item| if (item.shortcut_action != null) {
        result[index] = item.id;
        index += 1;
    };
    if (index != result.len) @compileError("factory shortcut count must remain 27");
    break :blk result;
};

/// The nine rows of V0.1.1 §5.4, in prototype order.
pub const tab_menu = [_]ActionId{ .rename_tab, .create_sibling_session, .duplicate_session, .edit_connection, .open_route_details, .open_theme_chooser, .export_record, .close_other_tabs, .request_close };

pub const AppCommand = struct { name: []const u8, action: ActionId };
/// @@ is a literal escape; it deliberately has no business action.
pub const app_commands = [_]AppCommand{
    .{ .name = "@up", .action = .upload },
    .{ .name = "@dl", .action = .download },
    .{ .name = "@ai", .action = .toggle_ai },
    .{ .name = "@new", .action = .create_sibling_session },
    .{ .name = "@dup", .action = .duplicate_session },
    .{ .name = "@grp", .action = .join_group },
    .{ .name = "@pin", .action = .toggle_pin },
    .{ .name = "@sync", .action = .toggle_broadcast },
    .{ .name = "@ts", .action = .toggle_timestamp },
    .{ .name = "@log", .action = .open_history },
    .{ .name = "@socks", .action = .toggle_socks },
    .{ .name = "@theme", .action = .open_theme_chooser },
    .{ .name = "@help", .action = .open_command_help },
};

pub fn descriptor(id: ActionId) *const Descriptor {
    for (&descriptors) |*item| if (item.id == id) return item;
    unreachable;
}

pub fn findById(action_id: []const u8) ?ActionId {
    for (descriptors) |item| if (std.mem.eql(u8, item.action_id, action_id)) return item.id;
    return null;
}

pub fn fromShortcutAction(action: keys.Action) ActionId {
    for (descriptors) |item| if (item.shortcut_action == action) return item.id;
    unreachable;
}

/// Resolves metadata only. In particular Right/Copy must still pass evaluate
/// and the caller's focused editor/terminal arbitration before consuming input.
pub fn fromShortcut(chord: Chord) ?ActionId {
    for (descriptors) |item| if (item.default_chord) |candidate| {
        if (candidate.eql(chord)) return item.id;
    };
    return null;
}

/// Input is the parsed command name; payload parsing belongs to V0.1.5.
pub fn fromAppCommand(name: []const u8) ?ActionId {
    for (app_commands) |item| if (std.ascii.eqlIgnoreCase(item.name, name)) return item.action;
    return null;
}

pub const InputContext = enum { none, editor, terminal, trusted_prompt };
pub const Context = struct {
    capability_snapshot: ?capability_snapshot.Snapshot = null,
    capability_owner: ?identity.SessionHandle = null,
    observed_capability_revision: ?u64 = null,
    has_tab: bool = false,
    terminal_owner: bool = false,
    input: InputContext = .none,
    has_selection: bool = false,
    in_group: bool = false,
    has_other_tabs: bool = false,
    writable: bool = false,
    supported: Capabilities = .{},
    ready: Capabilities = .{},
    lifecycle_allows: bool = true,
    permission_granted: bool = false,
    handler_ready: bool = false,
};

/// Required service names belong to the action catalog, so menu rows,
/// shortcuts and programmatic ingress consume the same declaration.
pub fn requirements(id: ActionId) []const @import("plugin_services.zig").ServiceKey {
    return switch (id) {
        .split_vertical, .split_horizontal, .search_terminal, .open_completion, .accept_completion, .toggle_broadcast, .duplicate_session, .join_group, .toggle_pin, .toggle_timestamp, .open_history, .export_record => &.{.{ .name = "terminal" }},
        .upload, .download => &.{.{ .name = "transfer" }},
        .open_route_details => &.{.{ .name = "route" }},
        .toggle_socks => &.{.{ .name = "forward" }},
        .toggle_ai => &.{.{ .name = "lifecycle" }},
        else => &.{},
    };
}
pub fn project(id: ActionId, snapshot: capability_snapshot.Snapshot) capability_snapshot.Projection {
    const required = requirements(id);
    return snapshot.project(.{ .action_id = descriptor(id).action_id, .scope = if (required.len == 0) .application else .session, .required_services = required });
}
fn serviceCapability(value: Capability) bool {
    return switch (value) {
        .terminal, .transfer, .route, .groups, .recording, .forward => true,
        else => false,
    };
}

pub const Cause = enum { target_missing, context_unavailable, unsupported, service_not_ready, selection_empty, group_required, no_other_tabs, read_only, lifecycle_blocked, permission_denied, handler_not_ready };
pub const Unavailable = struct { cause: Cause, reason: []const u8 };

/// null means available. Descriptor support, live bindings, lifecycle,
/// permission and the actual handler are independent, mandatory gates.
pub fn evaluate(id: ActionId, context: Context) ?Unavailable {
    const item = descriptor(id);
    const rule = item.rule;
    if (context.capability_snapshot) |snapshot| {
        if (context.capability_owner) |owner| if (!owner.eql(snapshot.owner)) return .{ .cause = .lifecycle_blocked, .reason = "会话能力所属对象已变化" };
        if (context.observed_capability_revision) |revision| if (revision != snapshot.revision) return .{ .cause = .lifecycle_blocked, .reason = "会话能力已变化，请重新执行" };
        const projected = project(id, snapshot);
        if (!projected.visible) return .{ .cause = .unsupported, .reason = projected.reason };
        if (!projected.enabled) return .{ .cause = .service_not_ready, .reason = projected.reason };
    }
    if (rule.scope != .app and rule.scope != .text_input and !context.has_tab) return .{ .cause = .target_missing, .reason = "目标页签已不存在或尚未选择" };
    switch (rule.scope) {
        .app, .tab => {},
        .terminal => if (!context.terminal_owner) return .{ .cause = .context_unavailable, .reason = "此动作需要终端会话" },
        .text_input => if (context.input == .none) return .{ .cause = .context_unavailable, .reason = "当前没有可处理文本的编辑器或终端" },
        .trusted_prompt => if (!context.terminal_owner or context.input != .trusted_prompt) return .{ .cause = .context_unavailable, .reason = "候选仅在可信提示符编辑状态可用" },
    }
    for (rule.capabilities) |capability| {
        if (context.capability_snapshot != null and serviceCapability(capability)) continue;
        if (!context.supported.has(capability)) return .{ .cause = .unsupported, .reason = item.unsupported_reason };
    }
    for (rule.capabilities) |capability| {
        if (context.capability_snapshot != null and serviceCapability(capability)) continue;
        if (!context.ready.has(capability)) return .{ .cause = .service_not_ready, .reason = "所需服务尚未就绪" };
    }
    if (rule.needs_selection and !context.has_selection) return .{ .cause = .selection_empty, .reason = "当前没有选中的文本" };
    if (rule.needs_group and !context.in_group) return .{ .cause = .group_required, .reason = "当前终端尚未加入组" };
    if (rule.needs_other_tabs and !context.has_other_tabs) return .{ .cause = .no_other_tabs, .reason = "没有其他可关闭的页签" };
    if (rule.needs_writable and !context.writable) return .{ .cause = .read_only, .reason = "当前输入目标不可写" };
    if (!context.lifecycle_allows) return .{ .cause = .lifecycle_blocked, .reason = "当前生命周期暂不允许此动作" };
    if (!context.permission_granted) return .{ .cause = .permission_denied, .reason = "当前权限不允许此动作" };
    if (!context.handler_ready) return .{ .cause = .handler_not_ready, .reason = "此动作的处理器尚未接入" };
    return null;
}

test "factory actions preserve 27 defaults and two fixed input boundaries" {
    try std.testing.expectEqual(@as(usize, 27), factory_shortcuts.len);
    var fixed: usize = 0;
    for (factory_shortcuts) |id| {
        const item = descriptor(id);
        const legacy = item.shortcut_action.?;
        try std.testing.expect(item.default_chord.?.eql((keys.Map{}).get(legacy)));
        try std.testing.expectEqual(id, fromShortcutAction(legacy));
        if (item.fixed_input_boundary) fixed += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), fixed);
    try std.testing.expect(descriptor(.recent_tab).fixed_input_boundary);
    try std.testing.expect(descriptor(.accept_completion).fixed_input_boundary);
}

test "session factories do not require an existing tab" {
    const context: Context = .{ .supported = .{ .session_factory = true }, .ready = .{ .session_factory = true }, .permission_granted = true, .handler_ready = true };
    try std.testing.expect(evaluate(.open_saved_connection, context) == null);
    try std.testing.expect(evaluate(.create_temporary_ssh_session, context) == null);
    try std.testing.expectEqual(Cause.target_missing, evaluate(.create_sibling_session, context).?.cause);
    try std.testing.expect(descriptor(.create_local_session).default_chord == null);
}

test "mirror menu and app command share identity without stealing split keys" {
    try std.testing.expectEqual(@as(usize, 9), tab_menu.len);
    try std.testing.expectEqual(@as(usize, 13), app_commands.len);
    try std.testing.expectEqual(ActionId.duplicate_session, tab_menu[2]);
    try std.testing.expectEqual(ActionId.duplicate_session, fromAppCommand("@dup").?);
    try std.testing.expect(descriptor(.duplicate_session).default_chord == null);
    try std.testing.expectEqual(ActionId.split_vertical, fromShortcut(.{ .key = .d }).?);
    try std.testing.expectEqual(ActionId.split_horizontal, fromShortcut(.{ .key = .d, .shift = true }).?);
    try std.testing.expectEqual(ActionId.rename_tab, fromShortcut(.{ .key = .r, .shift = true }).?);
    try std.testing.expectEqual(ActionId.request_close, tab_menu[8]);
    try std.testing.expectEqual(ActionId.open_theme_chooser, tab_menu[5]);
    try std.testing.expectEqual(tab_menu[5], fromAppCommand("@THEME").?);
    try std.testing.expect(fromAppCommand("@@") == null);
    try std.testing.expect(fromAppCommand("@missing") == null);
}

test "catalog has unique stable ids and chords across every source" {
    for (descriptors, 0..) |item, index| {
        try std.testing.expectEqual(item.id, findById(item.action_id).?);
        for (descriptors[index + 1 ..]) |other| {
            try std.testing.expect(item.id != other.id);
            try std.testing.expect(!std.mem.eql(u8, item.action_id, other.action_id));
            if (item.default_chord) |chord| if (other.default_chord) |other_chord| try std.testing.expect(!chord.eql(other_chord));
        }
    }
}

test "metadata support never implies a live handler or permission" {
    var context: Context = .{ .has_tab = true, .terminal_owner = true, .supported = .{ .terminal = true, .transfer = true } };
    try std.testing.expectEqual(Cause.service_not_ready, evaluate(.upload, context).?.cause);
    context.ready = context.supported;
    try std.testing.expectEqual(Cause.permission_denied, evaluate(.upload, context).?.cause);
    context.permission_granted = true;
    try std.testing.expectEqual(Cause.handler_not_ready, evaluate(.upload, context).?.cause);
    context.handler_ready = true;
    try std.testing.expect(evaluate(.upload, context) == null);
    context.lifecycle_allows = false;
    try std.testing.expectEqual(Cause.lifecycle_blocked, evaluate(.upload, context).?.cause);
}

test "unsupported commands explain required capability and input stays contextual" {
    var context: Context = .{ .has_tab = true, .terminal_owner = true, .supported = .{ .terminal = true }, .ready = .{ .terminal = true }, .permission_granted = true, .handler_ready = true, .writable = true };
    for ([_]ActionId{ .upload, .download, .toggle_socks }) |id| {
        const unavailable = evaluate(id, context).?;
        try std.testing.expectEqual(Cause.unsupported, unavailable.cause);
        try std.testing.expect(unavailable.reason.len != 0);
    }
    try std.testing.expectEqual(Cause.context_unavailable, evaluate(.accept_completion, context).?.cause);
    context.input = .terminal;
    try std.testing.expectEqual(Cause.context_unavailable, evaluate(.accept_completion, context).?.cause);
    context.input = .trusted_prompt;
    try std.testing.expect(evaluate(.accept_completion, context) == null);
    context.input = .editor;
    try std.testing.expect(evaluate(.paste, context) == null);
    try std.testing.expectEqual(Cause.selection_empty, evaluate(.copy, context).?.cause);
    context.has_selection = true;
    try std.testing.expect(evaluate(.copy, context) == null);
}

test "target and group gates do not imply another owner can handle the action" {
    var context: Context = .{ .permission_granted = true, .handler_ready = true };
    try std.testing.expectEqual(Cause.target_missing, evaluate(.rename_tab, context).?.cause);
    context.has_tab = true;
    try std.testing.expectEqual(Cause.no_other_tabs, evaluate(.close_other_tabs, context).?.cause);
    context.has_other_tabs = true;
    try std.testing.expect(evaluate(.close_other_tabs, context) == null);
    context.terminal_owner = true;
    context.supported = .{ .terminal = true };
    // Even an unready Local terminal cannot gain a missing SSH capability.
    try std.testing.expectEqual(Cause.unsupported, evaluate(.upload, context).?.cause);
    context.supported.groups = true;
    context.ready = context.supported;
    try std.testing.expectEqual(Cause.group_required, evaluate(.toggle_pin, context).?.cause);
    context.in_group = true;
    try std.testing.expect(evaluate(.toggle_pin, context) == null);
}

test "capability projection supports nonterminal AI and transfer and rejects old revisions" {
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(71) };
    var states = [_]capability_snapshot.ServiceState{
        .{ .key = .{ .name = "lifecycle" }, .declared = true, .available = true, .authorized = true, .revision = 8 },
        .{ .key = .{ .name = "transfer" }, .declared = true, .available = true, .authorized = true, .revision = 8 },
    };
    var context: Context = .{ .has_tab = true, .terminal_owner = false, .supported = .{ .ai = true }, .ready = .{ .ai = true }, .permission_granted = true, .handler_ready = true, .capability_owner = owner, .observed_capability_revision = 8, .capability_snapshot = .{ .owner = owner, .revision = 8, .services = &states } };
    try std.testing.expect(evaluate(.toggle_ai, context) == null);
    try std.testing.expect(evaluate(.upload, context) == null);
    try std.testing.expect(evaluate(.download, context) == null);
    try std.testing.expect(!project(.toggle_broadcast, context.capability_snapshot.?).visible);
    states[1].authorized = false;
    states[1].reason = "传输权限已撤销";
    try std.testing.expectEqual(Cause.service_not_ready, evaluate(.upload, context).?.cause);
    try std.testing.expectEqualStrings("传输权限已撤销", evaluate(.upload, context).?.reason);
    context.capability_snapshot.?.revision = 9;
    try std.testing.expectEqual(Cause.lifecycle_blocked, evaluate(.upload, context).?.cause);
}
