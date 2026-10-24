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
        const section = try page.section("页签与分栏", "16 个动作", ui.icons.panels_top_left, 4, "settings.keys.tabs", null);
        for (keys.rows[0..5], 0..) |row, index| try shortcutRow(cx, bound, section.body, switch (index) {
            0 => "新建 / 关闭页签",
            3 => "最近使用",
            4 => "垂直 / 水平分栏",
            else => row.label,
        }, row.actions);
    }
    if (binding.matches(query, "终端 应用 复制 粘贴 搜索 补全 采纳 快速连接 立即重连 侧栏 AI 上传 广播 terminal")) {
        const section = try page.section("终端与应用", "11 个动作", ui.icons.terminal, 5, "settings.keys.terminal", null);
        for (keys.rows[5..]) |row| try shortcutRow(cx, bound, section.body, row.label, row.actions);
    }
    return page.finish();
}

fn shortcutRow(cx: *ui.Cx, bound: *binding.Binding, parent: *ui.Node, label: []const u8, actions: []const keys.Action) !void {
    const row = try ui.boxStyled(cx, S.fieldRow, .{});
    const title = try ui.textStyled(cx, S.label, label);
    title.style.width = .fill();
    title.style.flex = 1;
    title.setStyleInline(cx.allocator, .{ .min_width = 0 });
    try row.appendChild(cx.allocator, title);
    const group = try ui.boxStyled(cx, S.shortcutGroup, .{});
    for (actions) |action| {
        const fixed = action == .recent_tab or action == .accept_completion;
        const click = try bound.scope.allocator.create(Click);
        click.* = .{ .bound = bound, .action = action };
        try bound.scope.onCleanup(Click, click, Click.cleanup);
        var buffer: [96]u8 = undefined;
        const text = try chordText(bound.controller.model.value.keys.get(action), &buffer);
        const tooltip = try ui.widgets.Tooltip(.{ .text = if (fixed) "此快捷键不可修改" else "点击录制此动作的快捷键", .open_delay_ms = 450 }).mount(bound.scope, cx);
        const node = try ui.widgets.Button(.{ .label = try controls.owned(bound.scope, text), .a11y_label = if (fixed) "此快捷键不可修改" else @tagName(action), .variant = .secondary, .disabled = bound.controller.state() == .saving, .on_click = cx.on(Click, click, Click.run), .base_style = S.shortcutButton(if (actions.len == 9) 32 else if (action == .recent_tab) 206 else 100, actions.len == 9), .hover_style = S.buttonHover() }).mount(bound.scope, cx);
        click.node = node;
        node.meta.ownership.meta.test_id = try controls.stableId(bound.scope, "settings.key.", @tagName(action));
        try tooltip.trigger.appendChild(cx.allocator, node);
        try group.appendChild(cx.allocator, tooltip.wrapper);
    }
    try row.appendChild(cx.allocator, group);
    try parent.appendChild(cx.allocator, row);
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
