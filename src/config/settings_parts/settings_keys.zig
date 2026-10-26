const std = @import("std");
const ui = @import("ui");
const binding = @import("../settings_content_view.zig");
const keys = @import("../keybindings.zig");
const controls = @import("settings_controls.zig");
const S = controls.S;

pub fn mountContent(cx: *ui.Cx, bound: *binding.Binding) !*ui.Node {
    const page = try controls.Page.create(cx, bound, "settings.keys");
    const query = bound.controller.search_query;
    if (binding.matches(query, "页签 分栏 新建 关闭 序号 直达 上一个 下一个 最近使用 split tab")) {
        const section = try page.section("页签与分栏", "16 个动作 · 点击快捷键录制", ui.icons.keyboard, 4, "settings.keys.tabs", null);
        for (keys.rows[0..5]) |row| for (row.actions) |action| {
            try shortcutRow(cx, bound, section.body, actionLabel(action), &.{action});
        };
    }
    if (binding.matches(query, "终端 应用 复制 粘贴 搜索 补全 采纳 快速连接 立即重连 侧栏 AI 上传 广播 terminal")) {
        const section = try page.section("终端与应用", "11 个动作 · Control 与 Tab 保留给远端", ui.icons.terminal, 5, "settings.keys.terminal", null);
        for (keys.rows[5..]) |row| for (row.actions) |action| {
            try shortcutRow(cx, bound, section.body, actionLabel(action), &.{action});
        };
    }
    return page.finish();
}

fn shortcutRow(cx: *ui.Cx, bound: *binding.Binding, parent: *ui.Node, label: []const u8, actions: []const keys.Action) !void {
    const query = bound.controller.search_query;
    const section_id = if (parent.parent) |item| item.meta.ownership.meta.test_id orelse "" else "";
    const section_title = if (std.mem.eql(u8, section_id, "settings.keys.tabs")) "页签与分栏" else "终端与应用";
    var matched = binding.matches(query, label) or binding.matches(query, section_title) or binding.matches(query, "快捷键");
    for (actions) |action| {
        var buffer: [96]u8 = undefined;
        if (binding.matches(query, @tagName(action)) or binding.matches(query, try chordText(bound.controller.model.value.keys.get(action), &buffer))) matched = true;
    }
    if (!matched) return;
    const row = try ui.boxStyled(cx, S.fieldRow, .{});
    row.meta.ownership.meta.test_id = try controls.stableId(bound.scope, "settings.key.row.", @tagName(actions[0]));
    const labels = try ui.boxStyled(cx, S.fieldLabel, .{});
    try labels.appendChild(cx.allocator, try ui.textStyled(cx, S.label, label));
    if (actions[0] == .recent_tab or actions[0] == .accept_completion) {
        try labels.appendChild(cx.allocator, try ui.text(cx, "保留给应用，不可修改", .{ .font_size = 11, .line_height = 16.0 / 11.0, .color = S.theme.current().fg_2 }));
    }
    try row.appendChild(cx.allocator, labels);
    const group = try ui.boxStyled(cx, S.shortcutGroup, .{});
    for (actions) |action| {
        const fixed = action == .recent_tab or action == .accept_completion;
        const click = try bound.scope.allocator.create(Click);
        click.* = .{ .bound = bound, .action = action };
        try bound.scope.onCleanup(Click, click, Click.cleanup);
        var buffer: [96]u8 = undefined;
        const text = try chordText(bound.controller.model.value.keys.get(action), &buffer);
        const tooltip = try ui.widgets.Tooltip(.{ .text = if (fixed) "此快捷键不可修改" else "点击录制此动作的快捷键", .open_delay_ms = 450 }).mount(bound.scope, cx);
        const node = try ui.widgets.Button(.{ .label = try controls.owned(bound.scope, text), .a11y_label = if (fixed) "此快捷键不可修改" else @tagName(action), .variant = .secondary, .disabled = fixed or bound.controller.state() == .saving, .on_click = cx.on(Click, click, Click.run), .base_style = shortcutStyle(), .hover_style = S.buttonHover() }).mount(bound.scope, cx);
        click.node = node;
        node.meta.ownership.meta.test_id = try controls.stableId(bound.scope, "settings.key.", @tagName(action));
        try tooltip.trigger.appendChild(cx.allocator, node);
        try group.appendChild(cx.allocator, tooltip.wrapper);
    }
    try row.appendChild(cx.allocator, group);
    try parent.appendChild(cx.allocator, row);
}

fn shortcutStyle() S.ButtonStyle {
    var style = S.shortcutButton(110, false);
    style.height = .{ .px = 30.5 };
    style.padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 8 };
    style.font_size = 12;
    style.font_weight = 400;
    style.corner_radius = 7;
    return style;
}

fn actionLabel(action: keys.Action) []const u8 {
    return switch (action) {
        .new_tab => "新建页签",
        .close_tab => "关闭页签",
        .tab_1 => "直达第 1 个页签",
        .tab_2 => "直达第 2 个页签",
        .tab_3 => "直达第 3 个页签",
        .tab_4 => "直达第 4 个页签",
        .tab_5 => "直达第 5 个页签",
        .tab_6 => "直达第 6 个页签",
        .tab_7 => "直达第 7 个页签",
        .tab_8 => "直达第 8 个页签",
        .tab_9 => "直达第 9 个页签",
        .previous_tab => "上一个页签",
        .next_tab => "下一个页签",
        .recent_tab => "最近使用的页签",
        .split_vertical => "垂直分栏",
        .split_horizontal => "水平分栏",
        .copy => "复制",
        .paste => "粘贴",
        .search => "搜索当前终端",
        .completion => "打开补全菜单",
        .accept_completion => "采纳补全",
        .quick_connect => "快速连接",
        .reconnect => "立即重连",
        .sidebar => "显示或隐藏侧栏",
        .ai => "AI 运维助手",
        .upload => "上传面板",
        .broadcast => "广播输入",
    };
}

const Click = struct {
    bound: *binding.Binding,
    action: keys.Action,
    node: *ui.Node = undefined,
    fn cleanup(self: *Click) void {
        self.bound.scope.allocator.destroy(self);
    }
    fn run(self: *Click) void {
        if (self.bound.controller.state() == .saving or self.action == .recent_tab or self.action == .accept_completion) return;
        self.bound.hooks.request_edit(self.bound.hooks.context, .{ .section = "keys", .key = @tagName(self.action) }, self.node);
    }
};

fn chordText(chord: keys.Chord, buffer: []u8) ![]const u8 {
    var name_buffer: [32]u8 = undefined;
    const name = switch (chord.key) {
        .@"return" => "↩",
        .tab => "Tab",
        .space => "Space",
        .delete => "⌫",
        .escape => "Esc",
        .forward_delete => "⌦",
        .left => "←",
        .right => "→",
        .down => "↓",
        .up => "↑",
        .slash => "/",
        .minus => "-",
        .equal => "=",
        .left_bracket => "[",
        .right_bracket => "]",
        .period => ".",
        .comma => ",",
        .semicolon => ";",
        .quote => "'",
        .backslash => "\\",
        .grave => "`",
        .page_up => "PageUp",
        .page_down => "PageDown",
        .unknown => "?",
        else => blk: {
            const raw = @tagName(chord.key);
            for (raw, 0..) |char, index| name_buffer[index] = std.ascii.toUpper(char);
            break :blk name_buffer[0..raw.len];
        },
    };
    return std.fmt.bufPrint(buffer, "{s}{s}{s}{s}{s}", .{ if (chord.command) "⌘" else "", if (chord.control) "⌃" else "", if (chord.shift) "⇧" else "", if (chord.option) "⌥" else "", name });
}
